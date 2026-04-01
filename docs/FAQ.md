# Frequently Asked Questions

---

## General

### What is AgentGov?

AgentGov is a Salesforce-native governance framework for AI agents. It provides budget management, policy enforcement, conflict detection, circuit breaker protection, and real-time monitoring for any type of AI agent operating on the Salesforce platform.

### Why do I need agent governance?

As organizations deploy multiple AI agents (Agentforce, MCP-connected models, custom Apex bots, Flow automations), several risks emerge:

- **Resource exhaustion:** A single runaway agent can consume your entire org's daily API limits.
- **Data conflicts:** Two agents modifying the same record simultaneously can corrupt data.
- **Policy violations:** Agents may access or modify objects/fields they should not have access to.
- **Cascading failures:** One failing agent can trigger retries that overwhelm the platform.

AgentGov addresses all of these with a declarative, metadata-driven approach.

### Does AgentGov require any external services?

No. AgentGov is 100% Salesforce-native. It uses only standard Salesforce platform features: Apex classes, Custom Objects, Custom Metadata Types, Custom Settings, Platform Events, and Scheduled Jobs. No external APIs, no managed package dependencies, no infrastructure to maintain.

### What types of agents does AgentGov support?

AgentGov supports four agent types:

| Type | Description |
|------|-------------|
| `Agentforce` | Salesforce Agentforce AI agents |
| `MCP_External` | External AI models connected via MCP or REST |
| `Custom_Apex` | Custom Apex-based automation agents |
| `Flow_Based` | Salesforce Flow-based automation agents |

You can apply different policies and budgets to each type.

### What Salesforce editions are supported?

AgentGov requires editions that support Apex and Custom Metadata Types. This includes Enterprise Edition, Unlimited Edition, Performance Edition, and Developer Edition. It does not work on Essentials or Professional Edition.

---

## Budgets

### How do budgets work?

Each agent has a daily budget for three resource types: API Calls, SOQL Queries, and DML Operations. A new budget record is created each day. When an agent performs an action, the corresponding budget is decremented. If the budget crosses configured thresholds, the agent is warned, throttled, or blocked.

### When do budgets reset?

Budgets reset at midnight, triggered by the `AgentGovDailyReset` scheduled job. If this job is not scheduled, budgets will not reset automatically. New budget records are created for the new day; old records remain for historical analysis.

### Can I give different budgets to different agents?

Yes. Each agent's `AgentGov_Registration__c` record has `Daily_API_Budget__c`, `Daily_SOQL_Budget__c`, and `Daily_DML_Budget__c` fields. These override the defaults from `AgentGov_Limit_Config__mdt`.

### What happens when an agent exceeds its budget?

At 80% usage (configurable), a Warning platform event is fired. At 90%, a Throttle event fires. At 95%, the agent is Blocked and further requests are denied with a `BUDGET_EXCEEDED` error. At 100%, the budget is Exhausted.

### Does AgentGov track actual Salesforce governor limits?

No. AgentGov tracks a logical budget that you define -- it does not interact with Salesforce's built-in `Limits` class. The budget is a governance layer that you configure to stay safely within your org's actual limits.

---

## Circuit Breaker

### What is the circuit breaker?

The circuit breaker is a resilience pattern that automatically disables agents that are failing repeatedly. It has three states:

- **CLOSED:** Normal operation. Failures are counted.
- **OPEN:** Agent is blocked. All requests denied. Waiting for cooldown.
- **HALF_OPEN:** One test request is allowed. Success closes the breaker; failure re-opens it.

### How many failures before the circuit breaker trips?

By default, 5 consecutive failures. This is configurable via `AgentGov_Settings__c.Circuit_Breaker_Failure_Threshold__c`.

### What counts as a "failure"?

Any `AgentGovCircuitBreaker.recordFailure(agentId)` call counts as a failure. In the invocable action flow (`AgentGovRegisterAction`), failures are recorded automatically when non-budget exceptions occur. Budget exceeded errors do not count as circuit breaker failures (the agent is not "broken" -- it is just over budget).

### Can I manually reset a circuit breaker?

Yes:
```apex
AgentGovCircuitBreaker.resetBreaker(agentId);
```

### What is exponential backoff?

When an agent's test request (in HALF_OPEN state) fails, the circuit breaker re-opens with a doubled cooldown period. If the base cooldown is 30 minutes, subsequent trips will be 60 minutes, then 120 minutes, and so on. This prevents a persistently broken agent from consuming resources with frequent test requests.

---

## Policies

### How are policies evaluated?

Policies are matched in this order:
1. Find all policies where `Agent_Type__c` matches the agent's type or is `All`.
2. Within those, find policies where `Object_Name__c` and `Operation__c` match (exact or wildcard `*`).
3. If any matching policy has `Is_Allowed__c = false`, the action is denied (deny always wins).
4. If no policies match at all, the action is allowed by default.

### Can I restrict specific fields?

Yes. Set the `Field_Restrictions__c` field on a policy to a comma-separated list of field API names. The `PolicyResult` object will include these in the `restrictedFields` set. Your agent code is responsible for honoring these restrictions -- AgentGov does not automatically strip fields from DML operations.

### Do policies apply to REST API calls?

Yes. The `/authorize` endpoint runs the full policy evaluation pipeline.

---

## Conflicts

### How does conflict detection work?

AgentGov uses in-memory record locking within a single transaction. When an agent performs an action on a specific record, it acquires a lock. If another agent tries to act on the same record in the same transaction, a conflict is detected and resolved by priority (lower number = higher priority).

### Is conflict detection persistent across transactions?

No. The in-memory lock table (`Map<String, Id>`) exists only for the duration of a single Apex transaction. For cross-transaction conflict detection, consider using Salesforce's built-in record locking (`FOR UPDATE`) or optimistic concurrency with `LastModifiedDate` checks.

### Can I disable conflict detection?

Yes. Set `Enable_Conflict_Detection__c = false` in `AgentGov_Settings__c`. When disabled, `checkForConflict()` always returns `{hasConflict: false}`.

---

## REST API

### How do I authenticate REST API calls?

Use standard Salesforce OAuth 2.0 authentication. The recommended flow for server-to-server integration is the Client Credentials Flow or JWT Bearer Flow. Include the access token in the `Authorization: Bearer <token>` header.

### What is the difference between /register and /authorize?

- `/register` creates a new agent in the framework (one-time setup).
- `/authorize` runs the full governance pipeline for a specific action (called before every action).

### Can I use /authorize without a recordId?

Yes. If `recordId` is omitted, conflict detection is skipped. Policy evaluation and budget consumption still run.

---

## Performance

### Does AgentGov add latency?

AgentGov adds a small amount of latency for the governance checks (typically 10-50ms per authorize call). The `AgentGovSelector` caches frequently accessed data (settings, metadata, registrations) per transaction to minimize SOQL usage.

### How many SOQL queries does AgentGov consume per call?

In a typical `/authorize` call:
- 1 query for the registration (by API key)
- 1 query for today's budget (with FOR UPDATE)
- 0 queries for settings (cached)
- 0 queries for policies (cached from metadata)

Total: approximately 2 SOQL queries per authorization. Subsequent calls in the same transaction benefit from caching.

### Can AgentGov handle high concurrency?

Budget consumption uses `FOR UPDATE` to prevent race conditions on budget records. The in-memory lock table handles conflict detection within a single transaction. For true cross-transaction concurrency at scale, consider implementing additional locking mechanisms at the application layer.
