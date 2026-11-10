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

    resource function post invocations(InvocationRequest request, http:Headers headers,
            string? agent_session_id) returns InvocationOk|http:InternalServerError {
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
