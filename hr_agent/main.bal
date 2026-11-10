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
service / on new http:Listener(8088) {

    resource function get readiness() returns http:Ok => {body: {status: "ready"}};

    resource function post invocations(http:Request req, http:Headers headers, string? agent_session_id)
            returns InvocationOk|http:BadRequest|http:InternalServerError {
        InvocationRequest|error request = parseInvocation(req);
        if request is error {
            return <http:BadRequest>{body: {message: request.message()}};
        }
        string sessionId = resolveSessionId(agent_session_id, request?.sessionId);
        logSessionContext(sessionId, agent_session_id, headers);

        string? employeeId = request?.employeeId;
        string query = employeeId is string
            ? string `[Employee ID: ${employeeId}] ${request.message}`
            : request.message;

        string|ai:Error answer = hrAgent.run(query, sessionId);
        if answer is ai:Error {
            log:printError("Agent run failed", answer, sessionId = sessionId);
            return <http:InternalServerError>{body: {message: "The HR assistant could not process the request"}};
        }
        return <InvocationOk>{body: {response: answer, sessionId}};
    }
}

// Accepts `{"message": ...}`, `{"input": ...}` (what the Foundry playground sends) or a plain-text body.
isolated function parseInvocation(http:Request req) returns InvocationRequest|error {
    string body = (check req.getTextPayload()).trim();
    json|error payload = body.fromJsonString();
    if payload is string {
        body = payload.trim();
    } else if payload is map<json> {
        json message = payload["message"] ?: payload["input"];
        if message !is string || message.trim() == "" {
            return error("Request must have a non-empty 'message' or 'input' string");
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
        return error("Request must be a JSON object, a JSON string or plain text");
    }
    if body == "" {
        return error("Request body is empty");
    }
    return {message: body};
}

// Picks the key for the agent's conversation memory.
// In Foundry each sandbox serves exactly one session, so the platform's session ID comes first.
// The `agent_session_id` query parameter should match it there, and is the fallback when the env var
// isn't set. The request-body `sessionId` only matters when running locally, outside Foundry.
isolated function resolveSessionId(string? querySessionId, string? bodySessionId) returns string {
    string platformSessionId = os:getEnv("FOUNDRY_AGENT_SESSION_ID");
    if platformSessionId != "" {
        if querySessionId is string && querySessionId != "" && querySessionId != platformSessionId {
            log:printWarn("Query session ID differs from the platform session ID; using the platform one",
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

// Logs which session identifiers reach the container, to check what Foundry actually forwards.
// Logs header names only, not values, because some platform headers identify the caller.
isolated function logSessionContext(string sessionId, string? querySessionId, http:Headers headers) {
    string[] agentHeaders = from string name in headers.getHeaderNames()
        where name.toLowerAscii().startsWith("x-agent")
        select name;
    log:printInfo("Invocation received", sessionId = sessionId,
            platformSessionId = os:getEnv("FOUNDRY_AGENT_SESSION_ID"),
            querySessionId = querySessionId ?: "", agentHeaders = agentHeaders);
}

// Logs environment variable names (never values) at startup, to see what the Foundry sandbox provides,
// e.g. managed-identity variables for keyless model access.
final string[] envNames = logEnvNames();

function logEnvNames() returns string[] {
    string[] names = os:listEnv().keys().sort();
    log:printInfo("Environment variable names", names = names);
    return names;
}
