import ballerina/ai;
import ballerina/http;
import ballerina/log;
import ballerina/os;

// Foundry hosted-agent contract: plain HTTP on 8088, GET /readiness and POST /invocations.
//
// Conversation continuity: Foundry picks the sandbox for each call from the `agent_session_id`
// query parameter on the Foundry endpoint, before the request reaches this container. Callers must
// send the same `agent_session_id` on every call of a conversation. Without it, Foundry creates a new
// session, and the agent starts with an empty memory no matter which ID this code picks.
service http:InterceptableService / on new http:Listener(8088) {

    public function createInterceptors() returns [RequestIdInterceptor, PlatformHeadersInterceptor,
            PlatformErrorInterceptor] => [new, new, new];

    resource function get readiness() returns http:Ok => {body: {status: "ready"}};

    resource function get invocations/docs/openapi\.json() returns json => invocationsOpenApi;

    resource function post invocations(http:Request req, http:Headers headers, string? agent_session_id)
            returns InvocationOk|http:BadRequest|http:InternalServerError {
        InvocationRequest|InvalidRequestError request = parseInvocation(req);
        if request is InvalidRequestError {
            return errorResponse(request);
        }
        string|SessionMismatchError sessionId = resolveSessionId(os:getEnv("FOUNDRY_AGENT_SESSION_ID"),
                agent_session_id, request?.sessionId);
        if sessionId is SessionMismatchError {
            log:printWarn("Rejected invocation with a mismatched session ID", sessionId);
            return errorResponse(sessionId);
        }
        logSessionContext(sessionId, agent_session_id, headers);

        string? employeeId = request?.employeeId;
        string query = employeeId is string
            ? string `[Employee ID: ${employeeId}] ${request.message}`
            : request.message;

        string|ai:Error answer = hrAgent.run(query, sessionId);
        if answer is ai:Error {
            log:printError("Agent run failed", answer, sessionId = sessionId, errorSource = errorSource(answer));
            return errorResponse(answer);
        }
        return <InvocationOk>{headers: {[SESSION_ID_HEADER]: sessionId}, body: {response: answer, sessionId}};
    }
}

// Accepts `{"message": ...}`, `{"input": ...}` (what the Foundry playground sends) or a plain-text body.
isolated function parseInvocation(http:Request req) returns InvocationRequest|InvalidRequestError {
    string|error text = req.getTextPayload();
    if text is error {
        return error InvalidRequestError("Request body could not be read: " + text.message(), text);
    }
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
        json sessionId = payload["sessionId"];
        if sessionId is string {
            request.sessionId = sessionId;
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

// Picks the key for the agent's conversation memory.
// In Foundry each sandbox serves exactly one session, so the platform's session ID comes first, and a
// different `agent_session_id` is rejected, as Microsoft's Agent Framework host does. Outside Foundry the
// query parameter, then the request-body `sessionId` (local testing only), then "default" are used.
isolated function resolveSessionId(string platformSessionId, string? querySessionId, string? bodySessionId)
        returns string|SessionMismatchError {
    if platformSessionId != "" {
        if querySessionId is string && querySessionId != "" && querySessionId != platformSessionId {
            return error SessionMismatchError("agent_session_id doesn't match this sandbox's session",
                    platformSessionId = platformSessionId, querySessionId = querySessionId);
        }
        return platformSessionId;
    }
    if querySessionId is string && querySessionId != "" {
        return querySessionId;
    }
    if bodySessionId is string && bodySessionId != "" {
        return bodySessionId;
    }
    return "default";
}

// Logs which session identifiers reach the container, to check what Foundry actually forwards, and
// whether W3C trace context arrives so container spans can join the platform's invoke_agent trace.
// Logs header names only, not values, because some platform headers identify the caller.
isolated function logSessionContext(string sessionId, string? querySessionId, http:Headers headers) {
    string[] agentHeaders = from string name in headers.getHeaderNames()
        where name.toLowerAscii().startsWith("x-agent")
        select name;
    log:printInfo("Invocation received", sessionId = sessionId,
            platformSessionId = os:getEnv("FOUNDRY_AGENT_SESSION_ID"),
            querySessionId = querySessionId ?: "", agentHeaders = agentHeaders,
            traceparent = headers.hasHeader("traceparent"), tracestate = headers.hasHeader("tracestate"));
}

// Logs environment variable names (never values) at startup, to see what the Foundry sandbox provides,
// e.g. managed-identity variables for keyless model access.
final string[] envNames = logEnvNames();

function logEnvNames() returns string[] {
    string[] names = os:listEnv().keys().sort();
    log:printInfo("Environment variable names", names = names);
    return names;
}
