// Served at GET /invocations/docs/openapi.json: describes the custom JSON this agent accepts on /invocations.
final readonly & json invocationsOpenApi = {
    openapi: "3.0.3",
    info: {
        title: "HR agent invocations",
        version: HOST_VERSION,
        description: "Foundry hosted-agent Invocations endpoint for the Ballerina HR assistant."
    },
    paths: {
        "/invocations": {
            post: {
                summary: "Ask the HR assistant a question",
                parameters: [
                    {
                        name: "agent_session_id",
                        "in": "query",
                        required: false,
                        description: "Session to continue. Must match the sandbox's session ID when running in Foundry.",
                        schema: {'type: "string"}
                    }
                ],
                requestBody: {
                    required: true,
                    content: {
                        "application/json": {
                            schema: {
                                oneOf: [
                                    {"$ref": "#/components/schemas/InvocationRequest"},
                                    {"$ref": "#/components/schemas/InputRequest"},
                                    {'type: "string", description: "The message as a JSON string"}
                                ]
                            }
                        },
                        "text/plain": {
                            schema: {'type: "string", description: "The message as plain text"}
                        }
                    }
                },
                responses: {
                    "200": {
                        description: "The assistant's answer",
                        headers: {
                            "x-agent-session-id": {
                                description: "The session ID used for the conversation memory",
                                schema: {'type: "string"}
                            }
                        },
                        content: {"application/json": {schema: {"$ref": "#/components/schemas/InvocationResponse"}}}
                    },
                    "400": {"$ref": "#/components/responses/Error"},
                    "500": {"$ref": "#/components/responses/Error"}
                }
            }
        }
    },
    components: {
        schemas: {
            InvocationRequest: {
                'type: "object",
                required: ["message"],
                properties: {
                    message: {'type: "string", description: "The question for the HR assistant"},
                    employeeId: {'type: "string", description: "ID of the employee asking, e.g. E1001"},
                    sessionId: {'type: "string", description: "Conversation ID for local testing; ignored in Foundry"}
                }
            },
            InputRequest: {
                'type: "object",
                required: ["input"],
                properties: {
                    input: {'type: "string", description: "The question (what the Foundry playground sends)"},
                    employeeId: {'type: "string"}
                }
            },
            InvocationResponse: {
                'type: "object",
                required: ["response", "sessionId"],
                properties: {
                    response: {'type: "string"},
                    sessionId: {'type: "string"}
                }
            },
            Error: {
                'type: "object",
                required: ["message"],
                properties: {message: {'type: "string"}}
            }
        },
        responses: {
            Error: {
                description: "The request failed",
                headers: {
                    "x-platform-error-source": {
                        description: "user (bad request), upstream (a dependency such as the model failed) " +
                            "or platform (a fault in this service)",
                        schema: {'type: "string", 'enum: ["user", "upstream", "platform"]}
                    }
                },
                content: {"application/json": {schema: {"$ref": "#/components/schemas/Error"}}}
            }
        }
    }
};
