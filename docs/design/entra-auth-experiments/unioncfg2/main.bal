import ballerina/io;

type DefaultCredentialConfig record {| "default" 'type; string managedIdentityClientId?; |};
type ManagedIdentityConfig record {| "managedIdentity" 'type; string clientId?; |};
type ClientSecretConfig record {| "clientSecret" 'type; string tenantId; string clientId; string clientSecret; |};
type CredentialConfig DefaultCredentialConfig|ManagedIdentityConfig|ClientSecretConfig;

configurable string|CredentialConfig k = ?;   // TOML string
configurable string|CredentialConfig m = ?;   // TOML table
configurable string|CredentialConfig d = {'type: "default"};  // default value, not in TOML

function kind(string|CredentialConfig v) returns string =>
    v is string ? "api key (string)" : v is ManagedIdentityConfig ? "ManagedIdentityConfig" :
    v is ClientSecretConfig ? "ClientSecretConfig" : "DefaultCredentialConfig";

public function main() {
    io:println("k = \"...\"                    -> ", kind(k));
    io:println("m = {type=\"managedIdentity\"} -> ", kind(m));
    io:println("d (default in code)          -> ", kind(d));
}
