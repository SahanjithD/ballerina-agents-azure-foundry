import ballerina/ai;
import ballerina/http;
import ballerina/log;
import ballerina/os;

// Foundry hosted-agent contract: plain HTTP on 8088, GET /readiness and POST /invocations.
service / on new http:Listener(8088) {

    resource function get readiness() returns http:Ok => {body: {status: "ready"}};

    resource function post invocations(InvocationRequest request)
            returns InvocationResponse|http:InternalServerError {
        string sessionId = request?.sessionId ?: platformSessionId();
        string? employeeId = request?.employeeId;
        string query = employeeId is string
            ? string `[Employee ID: ${employeeId}] ${request.message}`
            : request.message;

        string|ai:Error answer = hrAgent.run(query, sessionId);
        if answer is ai:Error {
            log:printError("Agent run failed", answer, sessionId = sessionId);
            return {body: {message: "The HR assistant could not process the request"}};
        }
        return {response: answer, sessionId};
    }
}

isolated function platformSessionId() returns string {
    string sessionId = os:getEnv("FOUNDRY_AGENT_SESSION_ID");
    return sessionId == "" ? "default" : sessionId;
}
