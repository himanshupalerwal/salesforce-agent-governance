# Frequently Asked Questions

---

## General

### What is AgentGov?

AgentGov is a Salesforce-native governance framework for AI agents. It provides budget management, policy enforcement, conflict detection, circuit breaker protection, and real-time monitoring for any type of AI agent operating on the Salesforce platform.

### Why do I need agent governance?

As organizations deploy multiple AI agents (Agentforce, MCP-connected models, custom Apex bots, Flow automations), several risks emerge:

- **Resource exhaustion:** A single runaway agent can consume your entire org's daily API limits.
- **Data conflicts:** Two agents modifying the same record can overwrite each other's changes.
- **Policy violations:** Agents may access or modify objects/fields they should not have access to.
- **Cascading failures:** One failing agent can trigger retries that overwhelm the platform.

AgentGov addresses these with a declarative, metadata-driven approach. Its conflict detection covers agents that claim the same record within one transaction, which in practice means a Register Agent Action batch in Flow. Separate REST or proxy requests never conflict with each other, and locking across requests is on the roadmap.

### Does AgentGov require any external services?

No. AgentGov is 100% Salesforce-native. It uses only standard Salesforce platform features: Apex classes, Custom Objects, Custom Metadata Types, Custom Settings, Platform Events, and Scheduled Jobs. No external APIs, no managed package dependencies, no infrastructure to maintain.

### What types of agents does AgentGov support?

AgentGov supports four agent types:

| Type           | Description                                  |
| -------------- | -------------------------------------------- |
| `Agentforce`   | Salesforce Agentforce AI agents              |
| `MCP_External` | External AI models connected via MCP or REST |
| `Custom_Apex`  | Custom Apex-based automation agents          |
| `Flow_Based`   | Salesforce Flow-based automation agents      |

Policies can differ by type: each policy names the agent type it applies to, by the value above or the label shown on records (such as `MCP External`), or `All`. Budgets do not depend on the type. They are set per agent, through the daily budget fields on its registration, and fall back to the default for each limit type in `AgentGov_Limit_Config__mdt`.

### What Salesforce editions are supported?

AgentGov requires editions that support Apex and Custom Metadata Types. This includes Enterprise Edition, Unlimited Edition, Performance Edition, and Developer Edition. It does not work on Essentials or Professional Edition.

### How do I stop an agent?

Deactivate it, with **Deactivate** in the console or `AgentGovRegistryService.deactivateAgent(agentId)` in Apex. A deactivated agent is refused by REST, the proxy, Register Agent Action, Report Agent Usage and `AgentGovContext`. Apex that calls the service classes directly must check the agent's `Status__c` itself, and Log Agent Action records rows for any agent.

### What does unchecking `Is_Enabled__c` do?

It turns on the emergency bypass; it stops nothing. While `Is_Enabled__c` is unchecked, every entry point skips the circuit breaker, policy, budget and conflict checks and charges nothing, so every action is allowed and audited, except that a deactivated agent is still refused. Only AgentGov's own checks are skipped: the proxy still reads and writes with the calling user's access. Use it only to unblock urgent work such as a data migration, and check it again afterwards.

---

## Budgets

### How do budgets work?

Each agent has a daily budget for three resource types: API Calls, SOQL Queries, and DML Operations. A new budget record is created each day. When an agent performs an action, the corresponding budget is decremented. As usage crosses the configured thresholds, the budget's status becomes Warning and then Throttled, each raising an alert while requests are still allowed, and then Blocked or Exhausted, when further requests are denied.

### When do budgets reset?

A budget row is created per agent per day on first use, so an agent is never blocked by yesterday's usage even with no job scheduled. Days are counted in the org's default time zone, whoever the calling user is, so a new day starts at the org's midnight for every agent. The `AgentGovDailyReset` job creates the day's rows for active agents up front, which keeps the dashboards populated before any agent acts. It runs at midnight in the time zone of the user who scheduled it, so schedule it as a user in the org's time zone. Old rows remain for the console's usage history until `Budget_Retention_Days__c` (default 400) passes.

### What is a session?

A session is one run of an agent's governed activity. It opens on the agent's first governed call, collects that run's usage and action count, and closes after `Session_Idle_Minutes__c` (default 30) without activity, or after 24 hours. The next call opens a new session. Nothing needs to start or end sessions, although `AgentGovRegistryService.startSession` and `endSession` exist for callers that want explicit boundaries, and an administrator can end one from the console.

### Can I give different budgets to different agents?

Yes. Each agent's `AgentGov_Registration__c` record has `Daily_API_Budget__c`, `Daily_SOQL_Budget__c`, and `Daily_DML_Budget__c` fields. These override the defaults from `AgentGov_Limit_Config__mdt`.

### What happens when an agent exceeds its budget?

At 80% usage (configurable), a Warning platform event is fired. At 90%, a Throttle event fires. At 95%, the budget is Blocked and further requests are denied with a `BUDGET_EXCEEDED` error. At 100%, the budget is Exhausted. The status is the most severe status across the three limit types, so an agent that has exhausted one type is denied every operation until a credit or the daily reset. The consumption that crossed the line is recorded before the denial is returned.

### Does AgentGov track actual Salesforce governor limits?

Yes — AgentGov provides three tiers of budget tracking:

1. **Automatic (Apex agents):** `AgentGovContext` uses the Salesforce `Limits` class to measure actual SOQL queries, DML statements, and callouts consumed during execution. Budget is decremented by the real measured delta.
2. **Proxy-based (External/MCP agents):** The Governed Proxy API (`/agentgov-proxy/*`) executes CRUD operations on behalf of agents. A write is charged one DML operation per record it processes, and a query is charged one SOQL query however many rows it returns.
3. **Self-reported (backward compatible):** The `/authorize` endpoint accepts an optional `amount` parameter. Agents can also call `/report` after execution to reconcile actual vs. pre-authorized consumption.

### What is the Governed Proxy API?

Instead of external agents calling Salesforce's standard REST API directly (which AgentGov cannot intercept), agents call the Proxy API endpoints (`/agentgov-proxy/query`, `/create`, `/update`, `/delete`, `/upsert`). The proxy runs the full governance pipeline and then executes the operation, so a write is charged by the actual number of records, not a hardcoded 1. A query is charged one SOQL query, whatever the number of rows it returns.

---

## Circuit Breaker

### What is the circuit breaker?

The circuit breaker is a resilience pattern that automatically disables agents that are failing repeatedly. It has three states:

- **CLOSED:** Normal operation. Consecutive failures are counted, and a success clears the count.
- **OPEN:** Agent is blocked. All requests are denied until the cooldown has passed, and outcomes reported meanwhile are ignored.
- **HALF_OPEN:** Exactly one probe request is admitted; others are denied until its outcome is reported, or until the configured cooldown passes without one. Success closes the breaker; failure re-opens it with a doubled cooldown, capped at one day.

### How many failures before the circuit breaker trips?

By default, 5 consecutive failures. This is configurable via `AgentGov_Settings__c.Circuit_Breaker_Failure_Threshold__c`.

### What counts as a "failure"?

An outcome reported as failed. The proxy records a failure when every record in a write fails, a `/report` call with `"success": false` records one for the calling agent, and Log Agent Action records one for a `Failure` row. Apex can record one with `AgentGovCircuitBreaker.recordFailure(agentId)`. Governance denials (policy, budget, conflict) are not failures: the agent is not broken, it was refused. While the breaker is OPEN, reported outcomes are ignored.

In Flow, an agent follows Register Agent Action, then the work, then Log Agent Action with `Success` or `Failure`, as a REST agent calls `/authorize`, does the work, and calls `/report`. Register Agent Action records no outcome, because the work has not run yet, and Report Agent Usage records none. Log Agent Action records one outcome per agent per batch, and a `Failure` anywhere in the batch makes it a failure. Logged failures are what trip the breaker at the threshold, and the outcome logged for the request admitted as the probe after the cooldown is what closes the breaker or re-opens it. Log work that was refused as `Denied`, which counts for nothing, not as `Failure`.

### Can I manually reset a circuit breaker?

Yes, with **Reset breaker** on the console, which records who reset it, or from Apex:

```apex
AgentGovCircuitBreaker.resetBreaker(agentId);
```

A reset closes the breaker from any state and returns a Blocked or Throttled agent to Active.

### How does the retry cooldown grow?

When an agent's probe request (in HALF_OPEN state) fails, the circuit breaker re-opens with twice the configured base cooldown rather than the base itself. It is a fixed doubling, not a compounding backoff: each failed probe sets a cooldown of twice the base, never longer, and outcomes reported while the breaker is OPEN are ignored, so they cannot push the retry back. The result is capped at one day, which only binds if the base cooldown is set above twelve hours. Once the cooldown has passed, the breaker moves to HALF_OPEN on the agent's next request through `/authorize`, the proxy or Register Agent Action, or when the hourly health check runs.

---

## Policies

### How are policies evaluated?

Policies are matched in this order:

1. Find all policies where `Agent_Type__c` matches the agent's type or is `All`. The type may be given as the stored value (`MCP_External`) or the label shown on records (`MCP External`), in any letter case.
2. Within those, find policies where `Object_Name__c` and `Operation__c` match (by name in any letter case, or wildcard `*`).
3. If any matching policy has `Is_Allowed__c = false`, the action is denied (deny always wins).
4. If no policies match at all, the action is allowed by default.

A policy whose `Agent_Type__c`, `Object_Name__c` or `Operation__c` is blank, or whose agent type names no type, applies to no agent. The console's Setup tab lists such policies as problems.

### Can I restrict specific fields?

Yes. Set the `Field_Restrictions__c` field on a policy to a comma-separated list of field API names. The proxy endpoints enforce them: a request that reads or writes a restricted field is denied with `POLICY_VIOLATION`, not silently trimmed. Apex callers enforce them with `AgentGovPolicyEngine.assertFieldsAllowed`.

### Do policies apply to REST API calls?

Yes. `/authorize` and every proxy endpoint run the full policy evaluation, and the proxy additionally enforces field restrictions and record caps.

---

## Conflicts

### How does conflict detection work?

AgentGov uses in-memory record locking within a single transaction. When an agent performs an action on a specific record, it acquires a lock. If another agent tries to act on the same record in the same transaction, a conflict is detected and resolved by priority (lower number = higher priority).

Two agents meet in one transaction when a Register Agent Action batch holds requests from several agents for the same record, or when Apex runs several agents in one transaction. Each REST or proxy request serves a single agent in its own transaction, so two separate requests never conflict here.

### Is conflict detection persistent across transactions?

No. The in-memory lock table (`Map<String, Id>`) exists only for the duration of a single Apex transaction. For cross-transaction conflict detection, consider using Salesforce's built-in record locking (`FOR UPDATE`) or optimistic concurrency with `LastModifiedDate` checks.

### Can I disable conflict detection?

Yes. Set `Enable_Conflict_Detection__c = false` in `AgentGov_Settings__c`. When disabled, `checkForConflict()` always returns `{hasConflict: false}`.

---

## REST API

### How do I authenticate REST API calls?

Two layers. First, a Salesforce OAuth 2.0 access token from an External Client App (Connected Apps can no longer be created in most orgs), in the `Authorization: Bearer <token>` header; the token's user needs the `AgentGov_Agent` permission set. Second, the agent identity: the `X-AgentGov-Key` header, or nothing at all when the token's user is bound to exactly one registration through `Agent_User__c`. A user bound to several registrations must send the key, because the login alone cannot say which agent is calling; a call without it is refused with 403. Keys are stored only as SHA-256 hashes. See the REST API reference.

### What is the difference between /register and /authorize?

- `/register` creates a new agent in the framework (one-time setup).
- `/authorize` runs the full governance pipeline for a specific action (called before every action).

### Can I use /authorize without a recordId?

Yes. If `recordId` is omitted, conflict detection is skipped. Policy evaluation and budget consumption still run.

---

## Performance

### Does AgentGov add latency?

AgentGov adds a small amount of latency for the governance checks (typically 10-50ms per authorize call). The `AgentGovSelector` caches frequently accessed data (settings, metadata, registrations, the org's time zone) per transaction to minimize SOQL usage.

### How many SOQL queries does AgentGov consume per call?

In a typical `/authorize` call:

- 1 query to resolve the registration (by key hash or bound user) and 1 to load it
- 1 query for the policy metadata and 1 for the limit configuration (both cached for the rest of the transaction)
- 1 query for the org's time zone, which dates the budget day (cached for the rest of the transaction)
- 1 locking query for today's budget, plus 1 for the active session counters

Around six or seven queries on a cold transaction, most of them cached afterwards. The Flow actions are bulk-safe: 200 requests in one batch cost the same handful of queries.

### Can AgentGov handle high concurrency?

Budget consumption locks the budget row with `FOR UPDATE`, and the unique `Budget_Key__c` guarantees that two transactions racing to create the day's first budget cannot both succeed. The half-open circuit breaker admits one probe at a time under the same kind of lock. Conflict detection between agents is still per transaction; cross-transaction locks are on the roadmap.
