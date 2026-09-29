# Flow Integration Guide

AgentGov provides five invocable actions that can be used directly in Salesforce Flow Builder. This guide explains how to use each one and provides common patterns.

All five actions are bulk-safe: a Flow that submits 200 requests in one batch causes a fixed handful of queries and DML statements, not one set per request.

---

## Available Invocable Actions

All actions appear in Flow Builder under the **AgentGov** category when you add an Action element. The tables below give each variable's label as Flow Builder shows it; a formula or merge field refers to an output by its API name, such as `{!Register_Agent_Action.authorized}`, as the examples do.

| Action Label              | Apex Class               | Description                                                      |
| ------------------------- | ------------------------ | ---------------------------------------------------------------- |
| **Register Agent Action** | `AgentGovRegisterAction` | All-in-one: checks policy, consumes budget, logs action          |
| **Check Agent Budget**    | `AgentGovCheckBudget`    | Read-only budget status check                                    |
| **Get Agent Status**      | `AgentGovGetStatus`      | Health and circuit breaker state                                 |
| **Log Agent Action**      | `AgentGovLogAction`      | Records an action for audit logging                              |
| **Report Agent Usage**    | `AgentGovReportUsage`    | Reports actual resource consumption for accurate budget tracking |

---

## Register Agent Action (All-in-One)

This is the most commonly used action. It runs the full governance pipeline in a single call:

1. Checks if the framework is enabled. While it is not (`Is_Enabled__c` unchecked), every request is authorized with Budget Status `Bypassed` and audited, except that a deactivated agent is still refused.
2. Refuses a deactivated agent, and an action type it does not recognise
3. Validates the circuit breaker state, admitting a single probe while the breaker is half-open
4. Evaluates policies for the agent type, object, and operation
5. Resolves record conflicts between agents in the batch
6. Consumes governor budget and records the requests on the agent's session
7. Logs every request, authorized or refused
8. Records a success on the circuit breaker for each authorized request

Register Agent Action runs before the Flow does its work, so it can only record that the request was admitted. Log Agent Action reports the status it logs: a `Failure` counts as a failure and a `Success` as a success, so a Flow that logs the outcome of its work trips its breaker after the configured number of failures and closes a half-open one with its next success. One batch is one outcome per agent, and a failure anywhere in the batch counts as a failure. `Denied` and `Throttled` count for nothing, Report Agent Usage records no outcome, and nothing is recorded for a deactivated agent or while governance is switched off.

### Input Variables

| Variable              | Type | Required | Description                                                                                                                                              |
| --------------------- | ---- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Agent Registration ID | Id   | Yes      | The agent's registration record ID                                                                                                                       |
| Action Type           | Text | Yes      | `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`, or `Flow_Trigger`                                                                           |
| Object Name           | Text | Yes      | Salesforce object API name (e.g., `Lead`, `Case`)                                                                                                        |
| Record ID             | Text | No       | The specific record being acted upon                                                                                                                     |
| Correlation ID        | Text | No       | Stored on the audit rows so they can be traced, for example `{!$Flow.InterviewGuid}`. Flow runs batched into one transaction share the first id supplied |

### Output Variables

| Variable      | Type    | Description                                     |
| ------------- | ------- | ----------------------------------------------- |
| Authorized    | Boolean | `true` if the action is allowed                 |
| Budget Status | Text    | `Normal`, `Warning`, `Throttled`, or `Bypassed` |
| Denial Reason | Text    | Reason for denial (empty if authorized)         |

When several requests in one batch belong to the same agent and their combined consumption would exceed its budget, every request for that agent is denied, so the outcome does not depend on the order of the batch.

When several agents in one batch name the same record, the agent with the best priority (the lowest number) keeps the record and the others are refused with a reason that names the winner, including an agent that claimed the record first and was then overridden. Between agents of equal priority, the request that comes first in the batch keeps the record. Every agent is registered with `Default_Agent_Priority__c` (5 unless changed), so set priorities on the agents whose order matters. Each conflict is recorded in the Conflict Log.

### Example: Record-Triggered Flow with Governance

**Scenario:** A Flow-based agent automatically updates Cases when they are created. Before processing, it checks governance.

1. **Trigger:** Record-Triggered Flow on Case (After Create)
2. **Action:** Register Agent Action
   - Agent Registration ID: `{!$Label.AgentGov_Case_Router_Agent_Id}` (store the Id in a Custom Label or Custom Setting so it is not hardcoded in the Flow)
   - Action Type: `Update`
   - Object Name: `Case`
   - Record ID: `{!$Record.Id}`
3. **Decision:** Is Authorized?
   - If `{!Register_Agent_Action.authorized}` = true: Proceed with case routing logic
   - If `{!Register_Agent_Action.authorized}` = false: Create a Task for admin review with `{!Register_Agent_Action.denialReason}`

---

## Check Agent Budget

A read-only check that does not consume budget. Use this when you need to know budget status before committing to an expensive operation.

### Input Variables

| Variable              | Type | Required | Description                        |
| --------------------- | ---- | -------- | ---------------------------------- |
| Agent Registration ID | Id   | Yes      | The agent's registration record ID |

### Output Variables

| Variable                 | Type    | Description                                                 |
| ------------------------ | ------- | ----------------------------------------------------------- |
| Has Budget               | Boolean | `true` unless the budget status is `Blocked` or `Exhausted` |
| Budget Status            | Text    | `Normal`, `Warning`, `Throttled`, `Blocked`, or `Exhausted` |
| API Calls Remaining      | Number  | Remaining daily API call budget                             |
| SOQL Queries Remaining   | Number  | Remaining daily SOQL query budget                           |
| DML Operations Remaining | Number  | Remaining daily DML operation budget                        |
| Error Message            | Text    | Error details if the check failed                           |

### Example: Pre-Check Before Batch Processing

**Scenario:** A Scheduled Flow runs hourly and processes leads in bulk. Before starting, it checks if the agent has sufficient budget.

1. **Get Records:** Query for unprocessed leads (limit 200)
2. **Action:** Check Agent Budget
   - Agent Registration ID: `{!varLeadEnrichmentAgentId}`
3. **Decision:** Has enough budget?
   - If `{!Check_Agent_Budget.hasBudget}` = true AND `{!Check_Agent_Budget.dmlOperationsRemaining}` >= `{!varLeadCount}`: Proceed with bulk processing
   - If budget insufficient: Skip this run, optionally send notification

---

## Get Agent Status

Retrieves the health status of an agent, including circuit breaker state. Use this for monitoring dashboards or before delegating work to an agent.

### Input Variables

| Variable              | Type | Required | Description                        |
| --------------------- | ---- | -------- | ---------------------------------- |
| Agent Registration ID | Id   | Yes      | The agent's registration record ID |

### Output Variables

| Variable              | Type    | Description                                            |
| --------------------- | ------- | ------------------------------------------------------ |
| Agent Name            | Text    | The agent's display name                               |
| Agent Status          | Text    | `Active`, `Inactive`, `Throttled`, or `Blocked`        |
| Circuit Breaker State | Text    | `CLOSED`, `OPEN`, or `HALF_OPEN`                       |
| Is Healthy            | Boolean | `true` if Status = Active AND Circuit Breaker = CLOSED |
| Failure Count         | Number  | Current consecutive failure count                      |
| Error Message         | Text    | Error details if the check failed                      |

### Example: Agent Health Gate

**Scenario:** Before routing a Case to an AI agent, verify the agent is healthy.

1. **Action:** Get Agent Status
   - Agent Registration ID: `{!varCaseRoutingAgentId}`
2. **Decision:** Is agent healthy?
   - If `{!Get_Agent_Status.isHealthy}` = true: Route case to the AI agent
   - If not healthy: Route case to a human queue instead

---

## Log Agent Action

Records an agent action for audit purposes without running governance checks. Use this when you have already performed governance checks separately, or for logging informational events.

### Input Variables

| Variable              | Type   | Required | Description                                                                                 |
| --------------------- | ------ | -------- | ------------------------------------------------------------------------------------------- |
| Agent Registration ID | Id     | Yes      | The agent's registration record ID                                                          |
| Action Type           | Text   | Yes      | `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`, or `Flow_Trigger`              |
| Object Name           | Text   | No       | Salesforce object API name                                                                  |
| Record ID             | Text   | No       | The specific record acted upon                                                              |
| Status                | Text   | Yes      | `Success`, `Failure`, `Denied`, or `Throttled`                                              |
| Details               | Text   | No       | Additional context or error details                                                         |
| Execution Time (ms)   | Number | No       | How long the action took, when the Flow measured it                                         |
| Correlation ID        | Text   | No       | Stored on the audit row; Flow runs batched into one transaction share the first id supplied |

A `Failure` logged here counts toward the agent's circuit breaker, and a `Success` clears its run of failures or closes a half-open breaker. `Denied` and `Throttled` are recorded for audit only.

### Output Variables

| Variable      | Type    | Description                                  |
| ------------- | ------- | -------------------------------------------- |
| Success       | Boolean | `true` if the action was logged successfully |
| Error Message | Text    | Error details if logging failed              |

---

## Common Patterns

### Pattern 1: Governed Screen Flow

A Screen Flow that lets a user trigger an AI agent action:

1. Screen: User selects action and target record
2. Action: Get Agent Status (verify health)
3. Decision: Healthy?
4. Action: Check Agent Budget (verify budget)
5. Decision: Has budget?
6. Action: Register Agent Action (authorize and log)
7. Decision: Authorized?
8. Custom logic: Perform the agent's work
9. Action: Log Agent Action (log completion)

### Pattern 2: Fallback to Human

When an agent is blocked or over budget, fall back to a human:

1. Action: Register Agent Action
2. Decision: Authorized?
   - Yes: Agent processes automatically
   - No: Create Task assigned to human queue with denial reason

### Pattern 3: Multi-Agent Orchestration

When a Flow needs to choose between multiple agents:

1. Action: Get Agent Status (Agent A)
2. Action: Get Agent Status (Agent B)
3. Decision: Which agent is healthy?
   - Both healthy: Check budgets, use the one with more remaining
   - Only A healthy: Use Agent A
   - Only B healthy: Use Agent B
   - Neither healthy: Escalate to human

---

## Report Agent Usage (Dynamic Budget Tracking)

Use this action after your Flow performs operations to report **actual** resource consumption. This enables accurate budget tracking instead of the default 1-unit-per-action estimate.

```
Flow Element: Action — "Report Agent Usage"
Input:
  - Agent Registration ID: {!varAgentId}
  - API Calls Used: 3           (Number — actual API calls made)
  - SOQL Queries Used: 5        (Number — actual queries executed)
  - DML Statements Used: 2      (Number — actual DML operations)
  - Correlation ID: {!$Flow.InterviewGuid}   (Text, optional)

Output:
  - Budget Status → {!varBudgetStatus}          (Text)
  - Budget Allowed → {!varBudgetAllowed}        (Boolean, false when the report is refused or leaves the budget Blocked or Exhausted)
  - API Calls Remaining → {!varApiRemaining}    (Number)
  - SOQL Queries Remaining → {!varSoqlRemaining} (Number)
  - DML Operations Remaining → {!varDmlRemaining} (Number)
  - Error Message → {!varErrorMessage}          (Text, set when the report is refused or the budget is exceeded)
```

Usage reported for the same agent by several requests in one batch is summed and charged once.

A report is refused, and nothing is charged, when the Agent Registration ID is missing or names no agent, when the agent is deactivated (`Agent is not in Active status.`), or when a count is negative (`Usage counts must not be negative.`). While governance is switched off (`Is_Enabled__c` unchecked) nothing is charged either, and the Flow receives the agent's current budget.

**Pattern: Post-Operation Reporting**

```
1. Register Agent Action (pre-authorize with budget=1)
2. Flow performs actual operations (creates 10 records, queries 5 times)
3. Report Agent Usage (reports actual: dmlStatementsUsed=10, soqlQueriesUsed=5)
4. The reported usage is charged ON TOP of anything already charged in step 1
```

> **Report Agent Usage is additive, not a reconciliation.** Unlike the REST `/report`
> endpoint, which accepts a `preAuthorized` figure and charges only the excess, this action
> has no pre-authorization input: every unit of an accepted report is added to the agent's
> consumption.
> The sequence above therefore charges 1 DML at step 1 and a further 10 at step 3, for 11
> against 10 records of real work.
>
> If you want the reported figures to be the whole charge, skip the pre-authorization: call
> **Check Agent Budget** to confirm headroom, do the work, then report the actual usage.

---

## Tips

- Store agent registration IDs in Custom Labels or Custom Settings for easy maintenance.
- Prefer running Flow-based agents as a dedicated user bound to the registration (`Agent_User__c`); the framework records its bookkeeping in system mode, so that user needs only the `AgentGov_Agent` permission set for REST calls and no access to AgentGov objects for Flow actions.
- Use the `Register Agent Action` for most cases -- it handles the full governance pipeline in one call.
- Use `Check Agent Budget` separately only when you need to make decisions based on remaining budget amounts.
- `Denial Reason` (Register Agent Action) and `Error Message` (the other actions) say why a request was refused, so display or log them. The actions do not catch unexpected errors, which fault the Flow, so give each AgentGov action a fault path.
