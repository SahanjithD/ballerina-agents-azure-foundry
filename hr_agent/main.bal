import ballerina/ai;
import ballerina/http;
import ballerina/log;
import ballerina/os;
import ballerinax/ai.azure;

// Foundry hosted agent on ai.azure's FoundryListener. The listener serves the container contract (plain HTTP on
// the PORT environment variable, else 8088), resolves the session and invocation IDs, and sets the platform
// response headers (x-platform-server, x-request-id, x-agent-session-id, x-agent-invocation-id). This service
// only holds the HR agent logic.
//
// Conversation continuity: Foundry picks the sandbox for each call from the `agent_session_id` query parameter
// on the Foundry endpoint. Callers send the same `agent_session_id` on every call of a conversation; the
// listener passes it in `ctx.sessionId`, which is the agent's memory key.
listener azure:FoundryListener foundryListener = new (openApiSpec = <map<json>>invocationsOpenApi);

service azure:FoundryInvocationService on foundryListener {

    // Readiness probe: cheap, never calls the model. `()` is 200 {"status":"healthy"}.
    resource function get readiness() {
    }

    // The declared `string` payload makes the listener hand over the raw body, so JSON and plain text both work.
    resource function post invocations(@http:Payload string body, azure:FoundryContext ctx)
            returns InvocationResponse|http:BadRequest|http:InternalServerError {
        InvocationRequest|InvalidRequestError request = parseInvocation(body);
        if request is InvalidRequestError {
            return errorResponse(request);
        }
        logSessionContext(ctx);

        string? employeeId = request?.employeeId;
        string query = employeeId is string
            ? string `[Employee ID: ${employeeId}] ${request.message}`
            : request.message;

        string|ai:Error answer = hrAgent.run(query, ctx.sessionId);
        if answer is ai:Error {
            log:printError("Agent run failed", answer, sessionId = ctx.sessionId, errorSource = errorSource(answer));
            return errorResponse(answer);
        }
        return {response: answer, sessionId: ctx.sessionId};
    }
}

# The request body couldn't be read as an invocation.
type InvalidRequestError distinct error;

# Who caused a failed request: the caller (`user`), a dependency such as the model (`upstream`), or this
# service itself (`platform`). Sent as `x-platform-error-source`; the listener keeps a value the service sets.
enum ErrorSource {
    USER = "user",
    UPSTREAM = "upstream",
    PLATFORM = "platform"
}

const ERROR_SOURCE_HEADER = "x-platform-error-source";

// Accepts `{"message": ...}`, `{"input": ...}` (what the Foundry playground sends), a JSON string or plain text.
isolated function parseInvocation(string text) returns InvocationRequest|InvalidRequestError {
    string body = text.trim();
    json|error payload = body.fromJsonString();
    if payload is string {
        body = payload.trim();
    } else if payload is map<json> {
        json message = payload["message"] ?: payload["input"];
        if message !is string || message.trim() == "" {
            return error InvalidRequestError("Request must have a non-empty 'message' or 'input' string");
        }
        InvocationRequest request = {message};
        json employeeId = payload["employeeId"];
        if employeeId is string {
            request.employeeId = employeeId;
        }
        return request;
    } else if payload is json {
        return error InvalidRequestError("Request must be a JSON object, a JSON string or plain text");
    }
    if body == "" {
        return error InvalidRequestError("Request body is empty");
    }
    return {message: body};
}

isolated function errorSource(error err) returns ErrorSource {
    if err is InvalidRequestError {
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

// Logs which session identifiers and platform headers reach the container (names and flags only, never values
// that identify the caller).
isolated function logSessionContext(azure:FoundryContext ctx) {
    log:printInfo("Invocation received", sessionId = ctx.sessionId, invocationId = ctx.invocationId,
            platformSessionId = ctx.agent.sessionId ?: "", agentVersion = ctx.agent.version ?: "",
            hasUserId = ctx.userId is string, hasCallId = ctx.callId is string,
            traceparent = ctx.trace.traceparent is string);
}

// Logs environment variable names (never values) at startup, to see what the Foundry sandbox provides.
final string[] envNames = logEnvNames();

function logEnvNames() returns string[] {
    string[] names = os:listEnv().keys().sort();
    log:printInfo("Environment variable names", names = names);
    return names;
}
