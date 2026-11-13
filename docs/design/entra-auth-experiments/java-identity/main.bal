import ballerina/http;
import ballerina/io;
import ballerina/jballerina.java;
import ballerina/os;

const SCOPE = "https://cognitiveservices.azure.com/.default";
const MOCK = "https://localhost:8443";

// Java azure-identity (the azure.storage.blob 1.0.0 jar set) behind a tiny interop shim.
function token(string kind, string scope, string caBundle, string authorityHost) returns string|error =
    @java:Method {'class: "exp.Identity"} external;

function report(string label, string|json|error result) {
    io:println(label, "\n    -> ", result is error ? "ERROR " + result.message() : result.toString());
}

public function main() returns error? {
    string bundle = os:getEnv("SSL_CERT_FILE");
    io:println("SSL_CERT_FILE set: ", bundle != "", "; IDENTITY_ENDPOINT: ", os:getEnv("IDENTITY_ENDPOINT"));

    // (a) service principal against an Entra-like endpoint whose TLS cert is signed by the "proxy" CA
    report("A1 client secret, azure-identity default HTTP client", token("secret", SCOPE, "", MOCK));
    report("A2 client secret, Netty client trusting SSL_CERT_FILE", token("secret", SCOPE, bundle, MOCK));
    // (a) App Service-style managed identity (the Foundry hosted-agent contract)
    report("A3 managed identity, default HTTP client", token("mi", SCOPE, "", ""));
    report("A4 managed identity, client trusting SSL_CERT_FILE", token("mi", SCOPE, bundle, ""));

    // (b) ballerina/http (its own Netty 4.2.18) in the same JVM, before and after azure-identity's reactor-netty
    http:Client c = check new (MOCK, secureSocket = {cert: bundle});
    json|error hello = c->get("/hello");
    report("B1 ballerina/http client over TLS in the same JVM", hello);
    report("B2 azure-identity again after ballerina/http", token("secret", SCOPE, bundle, MOCK));
}
