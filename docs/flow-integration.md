# Flow Integration Guide

AgentGov provides four invocable actions that can be used directly in Salesforce Flow Builder. This guide explains how to use each one and provides common patterns.

---

## Available Invocable Actions

All actions appear in Flow Builder under the **AgentGov** category when you add an Action element.

| Action Label | Apex Class | Description |
|-------------|-----------|-------------|
| **Register Agent Action** | `AgentGovRegisterAction` | All-in-one: checks policy, consumes budget, logs action |
| **Check Agent Budget** | `AgentGovCheckBudget` | Read-only budget status check |
| **Get Agent Status** | `AgentGovGetStatus` | Health and circuit breaker state |
| **Log Agent Action** | `AgentGovLogAction` | Records an action for audit logging |

---

## Register Agent Action (All-in-One)

This is the most commonly used action. It runs the full governance pipeline in a single call:

1. Checks if the framework is enabled
2. Validates the circuit breaker state
3. Evaluates policies for the agent type, object, and operation
4. Consumes governor budget
5. Logs the action
6. Records success/failure for the circuit breaker

### Input Variables

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| Agent Registration ID | Id | Yes | The agent's registration record ID |
| Action Type | Text | Yes | `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`, or `Flow_Trigger` |
| Object Name | Text | Yes | Salesforce object API name (e.g., `Lead`, `Case`) |
| Record ID | Text | No | The specific record being acted upon |

### Output Variables

| Variable | Type | Description |
|----------|------|-------------|
| Authorized | Boolean | `true` if the action is allowed |
| Budget Status | Text | `Normal`, `Warning`, `Throttled`, or `Framework disabled - bypassed` |
| Denial Reason | Text | Reason for denial (empty if authorized) |

### Example: Record-Triggered Flow with Governance

**Scenario:** A Flow-based agent automatically updates Cases when they are created. Before processing, it checks governance.

1. **Trigger:** Record-Triggered Flow on Case (After Create)
2. **Action:** Register Agent Action
   - Agent Registration ID: `{!$CustomMetadata.AgentGov_Config.Case_Router_Agent_Id}`
   - Action Type: `Update`
   - Object Name: `Case`
   - Record ID: `{!$Record.Id}`
3. **Decision:** Is Authorized?
   - If `{!Register_Agent_Action.Authorized}` = true: Proceed with case routing logic
   - If `{!Register_Agent_Action.Authorized}` = false: Create a Task for admin review with `{!Register_Agent_Action.Denial Reason}`

---

## Check Agent Budget

A read-only check that does not consume budget. Use this when you need to know budget status before committing to an expensive operation.

### Input Variables

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| Agent Registration ID | Id | Yes | The agent's registration record ID |

### Output Variables

| Variable | Type | Description |
|----------|------|-------------|
| Has Budget | Boolean | `true` if the agent has budget remaining |
| Budget Status | Text | `Normal`, `Warning`, `Throttled`, `Blocked`, or `Exhausted` |
| API Calls Remaining | Number | Remaining daily API call budget |
| SOQL Queries Remaining | Number | Remaining daily SOQL query budget |
| DML Operations Remaining | Number | Remaining daily DML operation budget |
| Error Message | Text | Error details if the check failed |

### Example: Pre-Check Before Batch Processing

**Scenario:** A Scheduled Flow runs hourly and processes leads in bulk. Before starting, it checks if the agent has sufficient budget.

1. **Get Records:** Query for unprocessed leads (limit 200)
2. **Action:** Check Agent Budget
   - Agent Registration ID: `{!varLeadEnrichmentAgentId}`
3. **Decision:** Has enough budget?
   - If `{!Check_Agent_Budget.Has Budget}` = true AND `{!Check_Agent_Budget.DML Operations Remaining}` >= `{!varLeadCount}`: Proceed with bulk processing
   - If budget insufficient: Skip this run, optionally send notification

---

## Get Agent Status

Retrieves the health status of an agent, including circuit breaker state. Use this for monitoring dashboards or before delegating work to an agent.

### Input Variables

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| Agent Registration ID | Id | Yes | The agent's registration record ID |

### Output Variables

| Variable | Type | Description |
|----------|------|-------------|
| Agent Name | Text | The agent's display name |
| Agent Status | Text | `Active`, `Inactive`, `Throttled`, or `Blocked` |
| Circuit Breaker State | Text | `CLOSED`, `OPEN`, or `HALF_OPEN` |
| Is Healthy | Boolean | `true` if Status = Active AND Circuit Breaker = CLOSED |
| Failure Count | Number | Current consecutive failure count |
| Error Message | Text | Error details if the check failed |

### Example: Agent Health Gate

**Scenario:** Before routing a Case to an AI agent, verify the agent is healthy.

1. **Action:** Get Agent Status
   - Agent Registration ID: `{!varCaseRoutingAgentId}`
2. **Decision:** Is agent healthy?
   - If `{!Get_Agent_Status.Is Healthy}` = true: Route case to the AI agent
   - If not healthy: Route case to a human queue instead

---

## Log Agent Action

Records an agent action for audit purposes without running governance checks. Use this when you have already performed governance checks separately, or for logging informational events.

### Input Variables

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| Agent Registration ID | Id | Yes | The agent's registration record ID |
| Action Type | Text | Yes | `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`, or `Flow_Trigger` |
| Object Name | Text | No | Salesforce object API name |
| Record ID | Text | No | The specific record acted upon |
| Status | Text | Yes | `Success`, `Failure`, `Denied`, or `Throttled` |
| Details | Text | No | Additional context or error details |

### Output Variables

| Variable | Type | Description |
|----------|------|-------------|
| Success | Boolean | `true` if the action was logged successfully |
| Error Message | Text | Error details if logging failed |

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

## Tips

- Store agent registration IDs in Custom Metadata, Custom Labels, or Custom Settings for easy maintenance.
- Use the `Register Agent Action` for most cases -- it handles the full governance pipeline in one call.
- Use `Check Agent Budget` separately only when you need to make decisions based on remaining budget amounts.
- The `Error Message` output variable captures exception details -- always display or log it when an action fails.
