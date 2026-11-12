import ballerina/http;
import ballerina/io;
import ballerinax/azure.openai.chat;

// Echoes the auth-related headers the server receives.
service class Echo {
    *http:Service;
    resource function post chat/completions(http:Request req) returns json {
        string[] names = ["api-key", "authorization"];
        map<string> seen = {};
        foreach string n in names {
            string|http:HeaderNotFoundError v = req.getHeader(n);
            seen[n] = v is string ? (v == "" ? "<empty>" : v) : "<absent>";
        }
        io:println("  server saw: ", seen);
        return {id: "x", 'object: "chat.completion", created: 0, model: "m", choices: []};
    }
}

function call(string label, chat:ConnectionConfig cfg, map<string> headers) {
    io:println(label);
    chat:Client|error c = new (cfg, "http://localhost:9091");
    if c is error { io:println("  init error: ", c.message()); return; }
    chat:InlineResponse200|error r = c->/chat/completions.post({model: "m", messages: [{role: "user"}]}, headers);
    if r is error { io:println("  call error: ", r.message()); }
}

public function main() returns error? {
    http:Listener l = check new (9091);
    check l.attach(new Echo(), "/");
    check l.'start();
    call("1) auth=api-key 'K', no extra headers", {auth: {api\-key: "K"}, httpVersion: http:HTTP_1_1}, {});
    call("2) auth=api-key '', per-call Authorization", {auth: {api\-key: ""}, httpVersion: http:HTTP_1_1}, {"Authorization": "Bearer PER-CALL"});
    call("3) auth=BearerTokenConfig 'STATIC', per-call Authorization", {auth: {token: "STATIC"}, httpVersion: http:HTTP_1_1}, {"Authorization": "Bearer PER-CALL"});
    call("4) auth=BearerTokenConfig 'STATIC', no extra headers", {auth: {token: "STATIC"}, httpVersion: http:HTTP_1_1}, {});
    return error("done (exit)");
}
