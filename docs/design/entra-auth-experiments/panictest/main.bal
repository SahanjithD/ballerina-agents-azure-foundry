import ballerina/http;
import ballerina/io;

public function main() {
    io:println("before init");
    http:Client|error c = new ("http://localhost:9191", {
        auth: {tokenUrl: "http://localhost:9199/token", clientId: "id", clientSecret: "sec"}
    });
    io:println("after init, returned error? ", c is error);
}
