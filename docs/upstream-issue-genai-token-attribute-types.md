# Draft issue: GenAI token-usage span attributes are exported as strings

**Target:** https://github.com/ballerina-platform/ballerina-library/issues (labels: `module/ai`, `module/observe`)
**Related:** ballerina-platform/ballerina-library#8280 (merging AI tracing with the observability APIs)
**Status:** draft, not filed

---

## Title

`ballerina/ai`: `gen_ai.usage.*_tokens` span attributes are exported as strings instead of integers

## Description

`ballerina/ai` records token usage on GenAI spans with the OpenTelemetry GenAI attribute names
(`gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`), but the values reach the exporter as
**strings**. The OpenTelemetry GenAI semantic conventions define both attributes as `int`. Backends that
aggregate spans by attribute type can't sum the values without casting them, for example the Azure Monitor
exporter, which puts numeric attributes in `customMeasurements`.

### Root cause

`ballerina/observe` only accepts string tag values:

```ballerina
// ballerina/observe 1.8.0, natives.bal (same on main)
public isolated function addTagToSpan(string tagKey, string tagValue, int spanId = -1) returns error?
```

`ballerina/ai` converts every non-string value before calling it:

```ballerina
// ballerina/ai 1.16.1, modules/ai.observe/observe.bal:200
error? result = observe:addTagToSpan(key, value is string ? value : value.toJsonString(), spanId);
```

`addInputTokenCount(int count)` and `addOutputTokenCount(int count)` (`llm-spans.bal:147-156`) take an `int`,
but the value ends up as a string attribute. The same affects `gen_ai.request.temperature` (a double) and
`http.status_code` on the HTTP spans.

### Steps to reproduce

1. Ballerina 2201.14.0, `ballerina/ai` 1.16.1, `ballerinax/ai.azure` 1.5.1, `observabilityIncluded = true`,
   with tracing configured as follows:
   ```toml
   [ballerina.observe]
   tracingEnabled = true
   tracingProvider = "otel"
   [ballerina.otel]
   tracesEndpoint = "http://localhost:4317"
   ```
2. Run an OpenTelemetry Collector with the `debug` exporter at `verbosity: detailed`.
3. Call `ai:Agent.run(...)` once.

**Actual output** (collector debug output for the `chat <model>` span):

```
-> gen_ai.operation.name: Str(chat)
-> gen_ai.usage.input_tokens: Str(565)
-> gen_ai.usage.output_tokens: Str(21)
```

**Expected output:**

```
-> gen_ai.usage.input_tokens: Int(565)
-> gen_ai.usage.output_tokens: Int(21)
```

### Suggested fix

1. `ballerina/observe`: add typed variants (or widen the parameter) so that native code can set an OTel
   attribute with its real type. For example:
   ```ballerina
   public isolated function addTagToSpan(string tagKey, string|int|float|boolean tagValue, int spanId = -1)
           returns error?
   ```
   The native side then calls `Span.setAttribute(String, long)`, `(String, double)` or `(String, boolean)`.
2. `ballerina/ai`: in `BaseSpanImp.addTag`, pass `int`, `float` and `boolean` values through unchanged, and
   only JSON-encode structured values such as messages and tools.

### Workaround

Use an OpenTelemetry Collector `transform` processor to cast the attributes:

```yaml
processors:
  transform/genai_types:
    trace_statements:
      - set(span.attributes["gen_ai.usage.input_tokens"], Int(span.attributes["gen_ai.usage.input_tokens"])) where span.attributes["gen_ai.usage.input_tokens"] != nil
      - set(span.attributes["gen_ai.usage.output_tokens"], Int(span.attributes["gen_ai.usage.output_tokens"])) where span.attributes["gen_ai.usage.output_tokens"] != nil
```

### Environment

- Ballerina 2201.14.0 (Swan Lake Update 14), Java 25 runtime (eclipse-temurin:25-jre, linux/amd64)
- `ballerina/ai` 1.16.1, `ballerina/observe` 1.8.0, `ballerinax/ai.azure` 1.5.1
- OpenTelemetry Collector 0.164.0 (custom build: otlp receiver, debug and azure_monitor exporters)
