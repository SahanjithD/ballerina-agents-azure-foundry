import ballerina/io;

// Variant A: no discriminator (aws.auth style). MI and CLI configs have only optional fields.
type MiA record {| string clientId?; |};
type CliA record {| string tenantId?; |};
type SecretA record {| string tenantId; string clientId; string clientSecret; |};
const DEFAULT_CREDENTIAL = "DEFAULT_CREDENTIAL";
type AuthA SecretA|MiA|CliA|DEFAULT_CREDENTIAL;

// Variant B: each record carries a required singleton discriminator.
type MiB record {| "managedIdentity" 'type; string clientId?; |};
type CliB record {| "azureCli" 'type; string tenantId?; |};
type SecretB record {| "clientSecret" 'type; string tenantId; string clientId; string clientSecret; |};
type AuthB SecretB|MiB|CliB|DEFAULT_CREDENTIAL;

configurable AuthA a1 = ?;   // {}                -> which member?
configurable AuthA a2 = ?;   // {clientId = "x"}  -> MI?
configurable AuthA a3 = ?;   // {tenantId = "t"}  -> CLI?
configurable AuthA a4 = ?;   // "DEFAULT_CREDENTIAL"
configurable AuthB b1 = ?;   // {type = "azureCli"}
configurable AuthB b2 = ?;   // {type = "managedIdentity", clientId = "x"}

function kindA(AuthA v) returns string => v is SecretA ? "SecretA" : v is MiA ? "MiA" : v is CliA ? "CliA" : "DEFAULT";
function kindB(AuthB v) returns string => v is SecretB ? "SecretB" : v is MiB ? "MiB" : v is CliB ? "CliB" : "DEFAULT";

public function main() {
    io:println("TOML a1 {}                  -> ", kindA(a1));
    io:println("TOML a2 {clientId}          -> ", kindA(a2));
    io:println("TOML a3 {tenantId}          -> ", kindA(a3));
    io:println("TOML a4 \"DEFAULT_CREDENTIAL\" -> ", kindA(a4));
    io:println("TOML b1 {type=azureCli}     -> ", kindB(b1));
    io:println("TOML b2 {type=managedIdentity, clientId} -> ", kindB(b2));
    AuthA lit = {tenantId: "t"};
    io:println("code literal {tenantId: \"t\"} -> ", kindA(lit));
}
