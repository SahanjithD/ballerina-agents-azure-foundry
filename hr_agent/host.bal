import ballerina/ai;
import ballerina/http;
import ballerina/observe;
import ballerina/uuid;

// Response headers that Microsoft's azure-ai-agentserver host sets, mirrored here.
const PLATFORM_SERVER_HEADER = "x-platform-server";
const REQUEST_ID_HEADER = "x-request-id";
const SESSION_ID_HEADER = "x-agent-session-id";
const ERROR_SOURCE_HEADER = "x-platform-error-source";

// `{name}/{version} ({language}/{version})`. Keep the versions in sync with Ballerina.toml (a test checks this).
const HOST_NAME = "bal-foundry-host";
const HOST_VERSION = "0.1.0";
const BALLERINA_VERSION = "2201.14.0";
const PLATFORM_SERVER = HOST_NAME + "/" + HOST_VERSION + " (ballerina/" + BALLERINA_VERSION + ")";

const REQUEST_ID_KEY = "requestId";

# Who caused a failed request: the caller (`user`), a dependency such as the model (`upstream`), or this
# service itself (`platform`).
enum ErrorSource {
    USER = "user",
    UPSTREAM = "upstream",
    PLATFORM = "platform"
}

# The request body couldn't be read as an invocation.
type InvalidRequestError distinct error;

# The `agent_session_id` query parameter doesn't match the sandbox's platform session ID.
type SessionMismatchError distinct error;

// Remembers the request ID before the resource runs, so the response interceptor can echo it.
service class RequestIdInterceptor {
    *http:RequestInterceptor;

    resource function 'default [string... path](http:RequestContext ctx, http:Request req)
            returns http:NextService|error? {
        ctx.set(REQUEST_ID_KEY, requestIdFor(req));
        return ctx.next();
    }
}

// Adds the platform headers to every response, including errors.
service class PlatformHeadersInterceptor {
    *http:ResponseInterceptor;

    remote function interceptResponse(http:RequestContext ctx, http:Response res) returns http:NextService|error? {
        addPlatformHeaders(ctx, res);
        return ctx.next();
    }
}

// Runs when the framework turns an error into a response (e.g. no matching resource), so those responses
// get the platform headers too.
service class PlatformErrorInterceptor {
    *http:ResponseErrorInterceptor;

    remote function interceptResponseError(http:RequestContext ctx, http:Response res, error err)
            returns http:Response {
        addPlatformHeaders(ctx, res);
        return res;
    }
}

isolated function addPlatformHeaders(http:RequestContext ctx, http:Response res) {
    res.setHeader(PLATFORM_SERVER_HEADER, PLATFORM_SERVER);
    if !res.hasHeader(REQUEST_ID_HEADER) {
        string requestId = ctx.hasKey(REQUEST_ID_KEY) ? ctx.get(REQUEST_ID_KEY).toString() : uuid:createType4AsString();
        res.setHeader(REQUEST_ID_HEADER, requestId);
    }
    if res.statusCode >= 400 && !res.hasHeader(ERROR_SOURCE_HEADER) {
        res.setHeader(ERROR_SOURCE_HEADER, res.statusCode < 500 ? USER : PLATFORM);
    }
}

// Echoes the caller's `x-request-id`; otherwise uses the trace ID, then a new UUID.
isolated function requestIdFor(http:Request req) returns string {
    string|http:HeaderNotFoundError requestId = req.getHeader(REQUEST_ID_HEADER);
    if requestId is string && requestId.trim() != "" {
        return requestId;
    }
    string? traceId = observe:getSpanContext()["traceId"];
    if traceId is string && traceId != "" && traceId != "00000000000000000000000000000000" {
        return traceId;
    }
    return uuid:createType4AsString();
}

isolated function errorSource(error err) returns ErrorSource {
    if err is InvalidRequestError || err is SessionMismatchError {
        return USER;
    }
    // Agent.run wraps model failures in a plain ai:Error, with the ai:LlmError as its cause.
    error? current = err;
    while current is error {
        if current is ai:LlmError {
            return UPSTREAM;
        }
        current = current.cause();
    }
    return PLATFORM;
}

isolated function errorResponse(error err) returns http:BadRequest|http:InternalServerError {
    ErrorSource errSource = errorSource(err);
    map<string> headers = {[ERROR_SOURCE_HEADER]: errSource};
    if errSource == USER {
        return <http:BadRequest>{headers, body: {message: err.message()}};
    }
    return <http:InternalServerError>{headers, body: {message: "The HR assistant could not process the request"}};
}
