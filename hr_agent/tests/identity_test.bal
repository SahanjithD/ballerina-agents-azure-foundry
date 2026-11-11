import ballerina/test;

const NOW = 1800000000;

@test:Config {}
function parsesExpiresOnAsString() returns error? {
    AccessToken token = check parseTokenResponse({access_token: "t", expires_on: "1800003600", token_type: "Bearer"}, NOW);
    test:assertEquals(token, {token: "t", expiresOn: 1800003600});
}

@test:Config {}
function parsesExpiresOnAsNumber() returns error? {
    AccessToken token = check parseTokenResponse({access_token: "t", expires_on: 1800003600}, NOW);
    test:assertEquals(token.expiresOn, 1800003600);
}

@test:Config {}
function fallsBackToExpiresIn() returns error? {
    AccessToken token = check parseTokenResponse({access_token: "t", expires_in: "3600"}, NOW);
    test:assertEquals(token.expiresOn, NOW + 3600);
}

@test:Config {}
function rejectsIncompleteTokenResponses() {
    json[] bodies = [
        {expires_on: "1800003600"},
        {access_token: "", expires_on: "1800003600"},
        {access_token: "t"},
        {access_token: "t", expires_on: "soon"},
        "not an object"
    ];
    foreach json body in bodies {
        test:assertTrue(parseTokenResponse(body, NOW) is error, "expected an error");
    }
}

@test:Config {}
function refreshesFiveMinutesBeforeExpiry() {
    AccessToken token = {token: "t", expiresOn: NOW + 3600};
    test:assertFalse(needsRefresh(token, NOW));
    test:assertFalse(needsRefresh(token, NOW + 3600 - 301));
    test:assertTrue(needsRefresh(token, NOW + 3600 - 300));
    test:assertTrue(needsRefresh(token, NOW + 4000));
}

@test:Config {}
function splitsEndpointIntoOriginAndPath() returns error? {
    test:assertEquals(check splitUrl("https://res.services.ai.azure.com/openai/v1"), ["https://res.services.ai.azure.com", "/openai/v1"]);
    test:assertEquals(check splitUrl("https://res.services.ai.azure.com/openai/v1/"), ["https://res.services.ai.azure.com", "/openai/v1"]);
    test:assertEquals(check splitUrl("http://localhost:9000"), ["http://localhost:9000", ""]);
    test:assertTrue(splitUrl("res.services.ai.azure.com/openai/v1") is error);
    test:assertEquals(check hostOf("https://res.services.ai.azure.com"), "res.services.ai.azure.com");
}

@test:Config {}
function keyModeWhenNoManagedIdentityVariables() {
    // bal test runs without IDENTITY_ENDPOINT / IDENTITY_HEADER, like a local run.
    test:assertEquals(managedIdentityConfig(), ());
}
