import ballerina/ai;
import ballerina/log;
import ballerina/os;
import ballerinax/ai.azure;

// Required on legacy (non-/v1) endpoints; ignored on /v1 endpoints.
const DEFAULT_API_VERSION = "2024-10-21";

final azure:OpenAiModelProvider model = check createModel();

final ai:Agent hrAgent = check new (
    systemPrompt = {
        role: "HR Assistant",
        instructions: string `You help employees with HR questions: their profile, leave balances, leave requests,
            public holidays and company policies.

            - Always use the tools to look up data. Never invent employee details, balances or policies.
            - If the message starts with [Employee ID: ...], that is the employee you are talking to.
              Otherwise ask for their employee ID before looking up personal data.
            - Before applying for leave, confirm the leave type and dates with the employee.
            - Leave requests are created as PENDING_APPROVAL; say that their manager will review it.
            - Keep answers short and friendly.`
    },
    model = model,
    tools = [getEmployeeProfile, getLeaveBalance, applyForLeave, listLeaveRequests, getCompanyHolidays,
        searchHrPolicies]
);

// Foundry's sandbox sends outbound HTTPS through a TLS-inspecting egress proxy and points SSL_CERT_FILE at
// a CA bundle that includes the proxy's CA. Java doesn't read SSL_CERT_FILE, so hand the bundle to the
// client explicitly; without it the TLS handshake to the model fails.
isolated function createModel() returns azure:OpenAiModelProvider|error {
    string endpoint = check requiredEnv("AZURE_OPENAI_ENDPOINT");
    string apiKey = check requiredEnv("AZURE_OPENAI_KEY");
    string deployment = check requiredEnv("MODEL_DEPLOYMENT_NAME");
    string apiVersion = os:getEnv("AZURE_OPENAI_API_VERSION") == "" ? DEFAULT_API_VERSION : os:getEnv("AZURE_OPENAI_API_VERSION");

    string caBundle = os:getEnv("SSL_CERT_FILE");
    if caBundle == "" {
        return new (endpoint, apiKey, deployment, apiVersion);
    }
    log:printInfo("Trusting CA bundle from SSL_CERT_FILE", path = caBundle);
    return new (endpoint, apiKey, deployment, apiVersion, secureSocket = {cert: caBundle});
}

isolated function requiredEnv(string name) returns string|error {
    string value = os:getEnv(name);
    if value == "" {
        return error(string `Environment variable ${name} is not set`);
    }
    return value;
}
