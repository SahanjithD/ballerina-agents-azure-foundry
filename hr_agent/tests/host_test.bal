import ballerina/ai;
import ballerina/http;
import ballerina/io;
import ballerina/test;

// resolveSessionId

@test:Config {}
function platformSessionIdIsUsedWhenQueryMatches() {
    test:assertEquals(resolveSessionId("plat-1", "plat-1", "body-1"), "plat-1");
}

@test:Config {}
function platformSessionIdIsUsedWhenQueryIsMissingOrEmpty() {
    test:assertEquals(resolveSessionId("plat-1", (), "body-1"), "plat-1");
    test:assertEquals(resolveSessionId("plat-1", "", ()), "plat-1");
}

@test:Config {}
function mismatchedQuerySessionIdIsRejected() {
    string|SessionMismatchError result = resolveSessionId("plat-1", "other", ());
    test:assertTrue(result is SessionMismatchError);
}

@test:Config {}
function querySessionIdIsUsedOutsideFoundry() {
    test:assertEquals(resolveSessionId("", "query-1", "body-1"), "query-1");
}

@test:Config {}
function bodySessionIdIsTheLocalFallback() {
    test:assertEquals(resolveSessionId("", (), "body-1"), "body-1");
    test:assertEquals(resolveSessionId("", "", "body-1"), "body-1");
}

@test:Config {}
function defaultSessionIdWhenNothingIsGiven() {
    test:assertEquals(resolveSessionId("", (), ()), "default");
    test:assertEquals(resolveSessionId("", "", ""), "default");
}

// parseInvocation

@test:Config {}
function parsesMessageWithEmployeeAndSession() returns error? {
    InvocationRequest request = check parseInvocation(jsonRequest({message: "hi", employeeId: "E1001", sessionId: "s1"}));
    test:assertEquals(request, {message: "hi", employeeId: "E1001", sessionId: "s1"});
}

@test:Config {}
function parsesInputAlias() returns error? {
    InvocationRequest request = check parseInvocation(jsonRequest({input: "hi"}));
    test:assertEquals(request, {message: "hi"});
}

@test:Config {}
function parsesJsonStringAndPlainText() returns error? {
    test:assertEquals(check parseInvocation(jsonRequest("hi there")), {message: "hi there"});
    http:Request req = new;
    req.setTextPayload("  plain text  ");
    test:assertEquals(check parseInvocation(req), {message: "plain text"});
}

@test:Config {}
function rejectsInvalidBodies() {
    http:Request empty = new;
    empty.setTextPayload("");
    (InvocationRequest|InvalidRequestError)[] results = [
        parseInvocation(jsonRequest({})),
        parseInvocation(jsonRequest({message: "   "})),
        parseInvocation(jsonRequest({message: 42})),
        parseInvocation(jsonRequest([1, 2])),
        parseInvocation(empty)
    ];
    foreach InvocationRequest|InvalidRequestError result in results {
        test:assertTrue(result is InvalidRequestError, "expected an InvalidRequestError");
    }
}

// errorSource

@test:Config {}
function requestErrorsComeFromTheUser() {
    test:assertEquals(errorSource(error InvalidRequestError("bad body")), USER);
    test:assertEquals(errorSource(error SessionMismatchError("mismatch")), USER);
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

// x-platform-server must reflect Ballerina.toml.

@test:Config {}
function platformServerMatchesBallerinaToml() returns error? {
    string toml = check io:fileReadString("Ballerina.toml");
    test:assertTrue(toml.includes(string `version = "${HOST_VERSION}"`), "HOST_VERSION differs from Ballerina.toml");
    test:assertTrue(toml.includes(string `distribution = "${BALLERINA_VERSION}"`),
            "BALLERINA_VERSION differs from Ballerina.toml");
    test:assertEquals(PLATFORM_SERVER, "bal-foundry-host/" + HOST_VERSION + " (ballerina/" + BALLERINA_VERSION + ")");
}

// Headers over HTTP (paths that don't call the model).

final http:Client agentClient = check new ("http://localhost:8088");

@test:Config {}
function readinessHasPlatformHeadersAndGeneratedRequestId() returns error? {
    http:Response res = check agentClient->get("/readiness");
    test:assertEquals(res.statusCode, 200);
    test:assertEquals(check res.getHeader(PLATFORM_SERVER_HEADER), PLATFORM_SERVER);
    test:assertTrue((check res.getHeader(REQUEST_ID_HEADER)).length() > 0);
}

@test:Config {}
function requestIdIsEchoed() returns error? {
    http:Response res = check agentClient->get("/readiness", {[REQUEST_ID_HEADER]: "req-123"});
    test:assertEquals(check res.getHeader(REQUEST_ID_HEADER), "req-123");
}

@test:Config {}
function requestIdFallsBackToTheTraceparentTraceId() returns error? {
    http:Response res = check agentClient->get("/readiness",
            {"traceparent": "00-c8f7a64bded47651f39fed6f883c13f4-41e18d4355c7b58d-01"});
    test:assertEquals(check res.getHeader(REQUEST_ID_HEADER), "c8f7a64bded47651f39fed6f883c13f4");
}

@test:Config {}
function malformedTraceparentIsIgnored() {
    test:assertEquals(traceIdFromTraceparent("00-c8f7a64bded47651f39fed6f883c13f4-41e18d4355c7b58d-01"),
            "c8f7a64bded47651f39fed6f883c13f4");
    test:assertEquals(traceIdFromTraceparent("00-00000000000000000000000000000000-41e18d4355c7b58d-01"), ());
    test:assertEquals(traceIdFromTraceparent("not-a-traceparent"), ());
    test:assertEquals(traceIdFromTraceparent("00-C8F7A64BDED47651F39FED6F883C13F4-41e18d4355c7b58d-01"), ());
}

@test:Config {}
function badBodyIsAUserError() returns error? {
    http:Response res = check agentClient->post("/invocations", {}, {[REQUEST_ID_HEADER]: "req-400"});
    test:assertEquals(res.statusCode, 400);
    test:assertEquals(check res.getHeader(ERROR_SOURCE_HEADER), USER);
    test:assertEquals(check res.getHeader(PLATFORM_SERVER_HEADER), PLATFORM_SERVER);
    test:assertEquals(check res.getHeader(REQUEST_ID_HEADER), "req-400");
}

@test:Config {}
function unknownRouteGetsPlatformHeaders() returns error? {
    http:Response res = check agentClient->get("/no-such-route");
    test:assertEquals(res.statusCode, 404);
    test:assertEquals(check res.getHeader(PLATFORM_SERVER_HEADER), PLATFORM_SERVER);
    test:assertEquals(check res.getHeader(ERROR_SOURCE_HEADER), USER);
}

@test:Config {}
function openApiDocumentIsServed() returns error? {
    json doc = check agentClient->get("/invocations/docs/openapi.json");
    test:assertEquals(check doc.openapi, "3.0.3");
    test:assertTrue((check doc.paths) is map<json>);
}

isolated function jsonRequest(json payload) returns http:Request {
    http:Request req = new;
    req.setJsonPayload(payload);
    return req;
}
