import ballerina/http;
import ballerina/lang.runtime;
import ballerina/log;
import ballerina/os;
import ballerina/time;
import ballerina/url;

// Keyless model access in Foundry. The sandbox exposes an App Service-style managed-identity endpoint
// (IDENTITY_ENDPOINT + IDENTITY_HEADER, no IDENTITY_SERVER_THUMBPRINT), which azure-identity's
// ManagedIdentityCredential serves with AppServiceCredential:
//   GET {IDENTITY_ENDPOINT}?api-version=2019-08-01&resource=<resource>&client_id=<id>
//   X-IDENTITY-HEADER: {IDENTITY_HEADER}
// The client ID is FOUNDRY_AGENT_INSTANCE_CLIENT_ID, as in Microsoft's Agent Framework hosted samples.

const COGNITIVE_SERVICES_RESOURCE = "https://cognitiveservices.azure.com";
const IDENTITY_API_VERSION = "2019-08-01";
const TOKEN_REFRESH_MARGIN_SECONDS = 300;

// ballerinax/ai.azure only sends an `api-key` header, so in identity mode it talks to this local hop, which
// swaps that header for the agent identity's bearer token.
const MODEL_PROXY_HOST = "127.0.0.1";
const MODEL_PROXY_PORT = 8089;
const PLACEHOLDER_API_KEY = "replaced-by-agent-identity-token";

type ManagedIdentityConfig record {|
    string endpoint;
    string header;
    string clientId;
|};

type AccessToken record {|
    string token;
    int expiresOn;
|};

// Returns the managed-identity settings when running in a Foundry sandbox, or `()` elsewhere.
isolated function managedIdentityConfig() returns ManagedIdentityConfig? {
    string endpoint = os:getEnv("IDENTITY_ENDPOINT");
    string header = os:getEnv("IDENTITY_HEADER");
    if endpoint == "" || header == "" {
        return ();
    }
    return {endpoint, header, clientId: os:getEnv("FOUNDRY_AGENT_INSTANCE_CLIENT_ID")};
}

// Fetches tokens for one resource from the managed-identity endpoint and caches them until shortly before
// they expire. Token values are never logged.
isolated class ManagedIdentityTokenProvider {
    private final http:Client identityClient;
    private final string requestPath;
    private final string identityHeader;
    private AccessToken? cached = ();

    isolated function init(ManagedIdentityConfig config, string 'resource) returns error? {
        self.identityClient = check new (config.endpoint, check clientConfigFor(config.endpoint));
        string query = string `?api-version=${IDENTITY_API_VERSION}&resource=${check url:encode('resource, "UTF-8")}`;
        if config.clientId != "" {
            query += string `&client_id=${check url:encode(config.clientId, "UTF-8")}`;
        }
        self.requestPath = query;
        self.identityHeader = config.header;
    }

    isolated function token() returns string|error {
        lock {
            int now = time:utcNow()[0];
            AccessToken? current = self.cached;
            if current is AccessToken && !needsRefresh(current, now) {
                return current.token;
            }
            AccessToken fresh = check self.fetch(now);
            self.cached = fresh;
            log:printInfo("Fetched agent identity token", expiresInSeconds = fresh.expiresOn - now);
            return fresh.token;
        }
    }

    private isolated function fetch(int now) returns AccessToken|error {
        http:Response res = check self.identityClient->get(self.requestPath, {"X-IDENTITY-HEADER": self.identityHeader});
        if res.statusCode != http:STATUS_OK {
            // The body can describe the failure but never holds a token on error; log only the status.
            return error(string `Managed identity endpoint returned HTTP ${res.statusCode}`);
        }
        return parseTokenResponse(check res.getJsonPayload(), now);
    }
}

// Parses the managed-identity response. `expires_on` (epoch seconds, a string or a number) is preferred,
// then `expires_in`, as azure-identity does.
isolated function parseTokenResponse(json body, int now) returns AccessToken|error {
    if body !is map<json> {
        return error("Managed identity response is not a JSON object");
    }
    json token = body["access_token"];
    if token !is string || token == "" {
        return error("Managed identity response has no access_token");
    }
    int? expiresOn = check toInt(body["expires_on"]);
    if expiresOn is () {
        int? expiresIn = check toInt(body["expires_in"]);
        if expiresIn is () {
            return error("Managed identity response has neither expires_on nor expires_in");
        }
        expiresOn = now + expiresIn;
    }
    return {token, expiresOn: <int>expiresOn};
}

isolated function needsRefresh(AccessToken token, int now) returns boolean =>
    now >= token.expiresOn - TOKEN_REFRESH_MARGIN_SECONDS;

isolated function toInt(json value) returns int?|error {
    if value is int {
        return value;
    }
    if value is string && value != "" {
        return int:fromString(value);
    }
    return ();
}

// Starts the local hop that forwards model calls to `modelEndpoint` with the agent identity's token, and
// returns the URL to give the model provider in place of the real endpoint.
isolated function startModelProxy(string modelEndpoint, ManagedIdentityTokenProvider tokens) returns string|error {
    [string, string] [origin, path] = check splitUrl(modelEndpoint);
    http:Client upstream = check new (origin, check clientConfigFor(origin));
    http:Listener proxyListener = check new (MODEL_PROXY_PORT, host = MODEL_PROXY_HOST);
    check proxyListener.attach(new ModelProxyService(upstream, tokens, check hostOf(origin)), "/");
    check proxyListener.'start();
    runtime:registerListener(proxyListener);
    log:printInfo("Model token proxy listening", address = string `${MODEL_PROXY_HOST}:${MODEL_PROXY_PORT}`,
            upstream = origin);
    return string `http://${MODEL_PROXY_HOST}:${MODEL_PROXY_PORT}${path}`;
}

isolated service class ModelProxyService {
    *http:Service;

    private final http:Client upstream;
    private final ManagedIdentityTokenProvider tokens;
    private final string upstreamHost;

    isolated function init(http:Client upstream, ManagedIdentityTokenProvider tokens, string upstreamHost) {
        self.upstream = upstream;
        self.tokens = tokens;
        self.upstreamHost = upstreamHost;
    }

    isolated resource function 'default [string... path](http:Request req) returns http:Response|error {
        string|error token = self.tokens.token();
        if token is error {
            log:printError("Could not get an agent identity token for the model call", token);
            return error("Agent identity token unavailable", token);
        }
        req.removeHeader("api-key");
        req.setHeader("Authorization", "Bearer " + token);
        req.setHeader("Host", self.upstreamHost);
        return self.upstream->forward(req.rawPath, req);
    }
}

// Trusts the sandbox's CA bundle (see agent.bal) for HTTPS targets.
isolated function clientConfigFor(string target) returns http:ClientConfiguration|error {
    string caBundle = os:getEnv("SSL_CERT_FILE");
    if target.startsWith("https://") && caBundle != "" {
        return {secureSocket: {cert: caBundle}};
    }
    return {};
}

// "https://host/openai/v1" -> ["https://host", "/openai/v1"]
isolated function splitUrl(string endpoint) returns [string, string]|error {
    string trimmed = endpoint.endsWith("/") ? endpoint.substring(0, endpoint.length() - 1) : endpoint;
    int? schemeEnd = trimmed.indexOf("://");
    if schemeEnd is () {
        return error(string `Not an absolute URL: ${trimmed}`);
    }
    int? pathStart = trimmed.indexOf("/", schemeEnd + 3);
    if pathStart is () {
        return [trimmed, ""];
    }
    return [trimmed.substring(0, pathStart), trimmed.substring(pathStart)];
}

isolated function hostOf(string origin) returns string|error {
    int? schemeEnd = origin.indexOf("://");
    if schemeEnd is () {
        return error(string `Not an absolute URL: ${origin}`);
    }
    return origin.substring(schemeEnd + 3);
}
