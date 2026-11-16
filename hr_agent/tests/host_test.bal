import ballerina/ai;
import ballerina/http;
import ballerina/test;

// parseInvocation

@test:Config {}
function parsesMessageWithEmployee() returns error? {
    InvocationRequest request = check parseInvocation({message: "hi", employeeId: "E1001"}.toJsonString());
    test:assertEquals(request, {message: "hi", employeeId: "E1001"});
}

@test:Config {}
function parsesInputAlias() returns error? {
    InvocationRequest request = check parseInvocation({input: "hi"}.toJsonString());
    test:assertEquals(request, {message: "hi"});
}

@test:Config {}
function parsesJsonStringAndPlainText() returns error? {
    test:assertEquals(check parseInvocation("\"hi there\""), {message: "hi there"});
    test:assertEquals(check parseInvocation("  plain text  "), {message: "plain text"});
}

@test:Config {}
function rejectsInvalidBodies() {
    string[] bodies = ["{}", {message: "   "}.toJsonString(), {message: 42}.toJsonString(), "[1, 2]", ""];
    foreach string body in bodies {
        test:assertTrue(parseInvocation(body) is InvalidRequestError, "expected an InvalidRequestError: " + body);
    }
}

// errorSource

@test:Config {}
function requestErrorsComeFromTheUser() {
    test:assertEquals(errorSource(error InvalidRequestError("bad body")), USER);
}

@test:Config {}
function modelErrorsComeFromUpstream() {
    test:assertEquals(errorSource(error ai:LlmConnectionError("connect failed")), UPSTREAM);
    // How Agent.run reports a model failure: a plain ai:Error caused by an ai:LlmError.
    ai:Error wrapped = error ai:Error("Unable to obtain valid answer from the agent",
            error ai:LlmInvalidResponseError("bad response"));
    test:assertEquals(errorSource(wrapped), UPSTREAM);
}

@test:Config {}
function otherErrorsComeFromThePlatform() {
    test:assertEquals(errorSource(error("unexpected")), PLATFORM);
    test:assertEquals(errorSource(error ai:Error("agent failed", error("tool bug"))), PLATFORM);
}

// Over HTTP (paths that don't call the model): the FoundryListener's contract plus this service's errors.

final http:Client agentClient = check new ("http://localhost:8088");

@test:Config {}
function readinessHasPlatformHeaders() returns error? {
    http:Response res = check agentClient->get("/readiness");
    test:assertEquals(res.statusCode, 200);
    test:assertTrue((check res.getHeader("x-platform-server")).startsWith("ballerinax-ai.azure/"));
    test:assertTrue((check res.getHeader("x-request-id")).length() > 0);
}

@test:Config {}
function requestIdIsEchoed() returns error? {
    http:Response res = check agentClient->get("/readiness", {"x-request-id": "req-123"});
    test:assertEquals(check res.getHeader("x-request-id"), "req-123");
}

@test:Config {}
function badBodyIsAUserError() returns error? {
    http:Response res = check agentClient->post("/invocations?agent_session_id=s1", {},
            {"x-request-id": "req-400"});
    test:assertEquals(res.statusCode, 400);
    test:assertEquals(check res.getHeader(ERROR_SOURCE_HEADER), USER);
    test:assertEquals(check res.getHeader("x-request-id"), "req-400");
    test:assertEquals(check res.getHeader("x-agent-session-id"), "s1");
}

@test:Config {}
function openApiDocumentIsServed() returns error? {
    json doc = check agentClient->get("/invocations/docs/openapi.json");
    test:assertEquals(check doc.openapi, "3.0.3");
    test:assertTrue((check doc.paths) is map<json>);
}
