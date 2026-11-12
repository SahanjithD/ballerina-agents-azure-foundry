import ballerina/http;
import ballerina/io;
import ballerina/oauth2;
import ballerina/lang.runtime;

isolated int tokenCalls = 0;
isolated int apiCalls = 0;
isolated int expiresIn = 2;

function tokenCount() returns int {
    lock {
        return tokenCalls;
    }
}

function apiCount() returns int {
    lock {
        return apiCalls;
    }
}

http:Service tokenSvc = service object {
    resource function post token(http:Request req) returns json|error {
        int n;
        lock {
            tokenCalls += 1;
            n = tokenCalls;
        }
        string body = check req.getTextPayload();
        string|http:HeaderNotFoundError authz = req.getHeader("Authorization");
        string|http:HeaderNotFoundError ct = req.getHeader("Content-Type");
        io:println(string `[token-endpoint] call #${n} Content-Type=${ct is string ? ct : "-"} Authorization=${authz is string ? authz : "-"}`);
        io:println(string `[token-endpoint]   body=${body}`);
        runtime:sleep(0.5); // widen race window
        int exp;
        lock {
            exp = expiresIn;
        }
        return {access_token: string `tok-${n}`, token_type: "Bearer", expires_in: exp};
    }
};

http:Service apiSvc = service object {
    resource function get ok(http:Request req) returns string {
        lock {
            apiCalls += 1;
        }
        string|http:HeaderNotFoundError a = req.getHeader("Authorization");
        return a is string ? a : "-";
    }
    resource function get unauthorized(http:Request req) returns http:Unauthorized {
        lock {
            apiCalls += 1;
        }
        string|http:HeaderNotFoundError a = req.getHeader("Authorization");
        io:println(string `[api] /unauthorized got Authorization=${a is string ? a : "-"}`);
        return {body: "nope"};
    }
};

public function main() returns error? {
    http:Listener tl = check new (9190);
    check tl.attach(tokenSvc, "/");
    check tl.'start();
    runtime:registerListener(tl);
    http:Listener al = check new (9191);
    check al.attach(apiSvc, "/");
    check al.'start();
    runtime:registerListener(al);

    io:println("\n=== E1: client_credentials + scopes + optionalParams(client_assertion) + POST_BODY_BEARER");
    http:Client c1 = check new ("http://localhost:9191", {
        auth: {
            tokenUrl: "http://localhost:9190/token",
            clientId: "my-client-id",
            clientSecret: "dummy",
            scopes: "https://cognitiveservices.azure.com/.default",
            optionalParams: {
                "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                "client_assertion": "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln"
            },
            credentialBearer: oauth2:POST_BODY_BEARER
        }
    });
    io:println(string `token calls right after http:Client init (no request yet): ${tokenCount()}`);

    io:println("\n=== E2: default credentialBearer (AUTH_HEADER_BEARER), scopes as array");
    http:Client _ = check new ("http://localhost:9191", {
        auth: {
            tokenUrl: "http://localhost:9190/token",
            clientId: "my-client-id",
            clientSecret: "s3cr+t&x=1",
            scopes: ["https://cognitiveservices.azure.com/.default"]
        }
    });

    io:println("\n=== E3: JwtBearerGrantConfig (no client id/secret)");
    http:Client _ = check new ("http://localhost:9191", {
        auth: {
            tokenUrl: "http://localhost:9190/token",
            assertion: "eyJ.assertion.sig",
            scopes: "https://cognitiveservices.azure.com/.default"
        }
    });

    io:println("\n=== E4: 20 concurrent requests on c1 while token valid");
    int before = tokenCount();
    future<string|error>[] fs = [];
    foreach int i in 0 ..< 20 {
        future<string|error> f = start callOk(c1);
        fs.push(f);
    }
    string[] seen = [];
    foreach var f in fs {
        string|error r = wait f;
        if r is string && seen.indexOf(r) is () {
            seen.push(r);
        } else if r is error {
            io:println("error: ", r.message());
        }
    }
    io:println(string `token fetches during burst: ${tokenCount() - before}; distinct Authorization headers seen by API: ${seen.toString()}`);

    io:println("\n=== E5: wait 3s (token expires_in=2), then 20 concurrent requests");
    runtime:sleep(3);
    before = tokenCount();
    fs = [];
    foreach int i in 0 ..< 20 {
        future<string|error> f = start callOk(c1);
        fs.push(f);
    }
    seen = [];
    foreach var f in fs {
        string|error r = wait f;
        if r is string && seen.indexOf(r) is () {
            seen.push(r);
        } else if r is error {
            io:println("error: ", r.message());
        }
    }
    io:println(string `token fetches during burst after expiry: ${tokenCount() - before}; distinct Authorization headers: ${seen.toString()}`);

    io:println("\n=== E6: 401 from API (token still valid) - any refetch/retry?");
    lock {
        expiresIn = 3600;
    }
    runtime:sleep(3);
    string _ = check c1->get("/ok"); // refresh to a long-lived token
    before = tokenCount();
    int apiBefore = apiCount();
    http:Response|error r401 = c1->get("/unauthorized");
    io:println(string `result: ${r401 is http:Response ? r401.statusCode.toString() : (<error>r401).message()}; api calls=${apiCount() - apiBefore}; token fetches=${tokenCount() - before}`);
    r401 = c1->get("/unauthorized");
    io:println(string `second call: api calls total=${apiCount() - apiBefore}; token fetches=${tokenCount() - before}`);

    io:println("\n=== E7: retryConfig statusCodes=[401] count=2");
    http:Client c7 = check new ("http://localhost:9191", {
        auth: {tokenUrl: "http://localhost:9190/token", clientId: "id", clientSecret: "sec"},
        retryConfig: {count: 2, interval: 0.1, statusCodes: [401]}
    });
    before = tokenCount();
    apiBefore = apiCount();
    http:Response|error r7 = c7->get("/unauthorized");
    io:println(string `result: ${r7 is http:Response ? r7.statusCode.toString() : (<error>r7).message()}; api calls=${apiCount() - apiBefore}; token fetches=${tokenCount() - before}`);

    io:println("\n=== E8: empty clientSecret");
    http:Client|error c8 = trap new ("http://localhost:9191", {
        auth: {tokenUrl: "http://localhost:9190/token", clientId: "id", clientSecret: ""}
    });
    io:println(c8 is error ? "init failed: " + c8.message() + " | detail: " + c8.detail().toString() : "init ok");

    io:println("\n=== E9: token endpoint unreachable at init");
    http:Client|error c9 = trap new ("http://localhost:9191", {
        auth: {tokenUrl: "http://localhost:9199/token", clientId: "id", clientSecret: "sec"}
    });
    io:println(c9 is error ? "init failed (trapped): " + c9.message() : "init ok");

    io:println("\n=== E10: BearerTokenConfig is static");
    http:Client c10 = check new ("http://localhost:9191", {auth: {token: "static-abc"}});
    string s10 = check c10->get("/ok");
    io:println("API saw: ", s10);

    check tl.gracefulStop();
    check al.gracefulStop();
}

function callOk(http:Client c) returns string|error {
    return c->get("/ok");
}
