# Apex API Reference

Complete reference for all public Apex methods in the AgentGov framework.

---

## AgentGovRegistryService

Service layer for managing AI agent registrations and sessions.

### registerAgent

Registers a new AI agent in the framework.

```apex
public static AgentGov_Registration__c registerAgent(
    String agentName,
    String agentType,
    String description,
    String apiKey,
    String ownerEmail
)
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `agentName` | String | Yes | Display name of the agent |
| `agentType` | String | Yes | One of: `Agentforce`, `MCP_External`, `Custom_Apex`, `Flow_Based` |
| `description` | String | No | Human-readable description of the agent's purpose |
| `apiKey` | String | No | API key for REST API authentication (required for external agents) |
| `ownerEmail` | String | No | Contact email for the agent owner |

**Returns:** `AgentGov_Registration__c` -- The created registration record with Status = `Inactive`.

**Throws:**
- `AgentGovException(INVALID_INPUT)` -- if `agentName` is blank or `agentType` is not a valid type.

**Example:**
```apex
AgentGov_Registration__c agent = AgentGovRegistryService.registerAgent(
    'Lead Enrichment Agent',
    'Agentforce',
    'Enriches leads with firmographic data',
    'key-lead-enrichment-001',
    'admin@yourcompany.com'
);
// agent.Status__c == 'Inactive'
// agent.Circuit_Breaker_State__c == 'CLOSED'
// agent.Priority__c == 5 (or org default)
```

---

### activateAgent

Activates a registered agent, making it eligible to perform governed actions.

```apex
public static AgentGov_Registration__c activateAgent(Id registrationId)
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `registrationId` | Id | Yes | The agent registration record ID |

**Returns:** `AgentGov_Registration__c` -- The updated registration record with Status = `Active`.

**Throws:**
- `AgentGovException(AGENT_NOT_FOUND)` -- if the registration ID does not exist.
- `AgentGovException(MAX_CONCURRENT_AGENTS)` -- if the org has reached the max concurrent active agents limit.

---

### deactivateAgent

Deactivates an agent and terminates any active sessions.

```apex
public static AgentGov_Registration__c deactivateAgent(Id registrationId)
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `registrationId` | Id | Yes | The agent registration record ID |

**Returns:** `AgentGov_Registration__c` -- The updated registration record with Status = `Inactive`.

**Side effects:** Any active session for this agent is terminated (Status set to `Terminated`, Session_End set to now).

---

### startSession

Starts a new session for an active agent.

```apex
public static AgentGov_Session__c startSession(Id registrationId)
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `registrationId` | Id | Yes | The agent registration record ID |

**Returns:** `AgentGov_Session__c` -- The created session record with Status = `Active`.

**Throws:**
- `AgentGovException(AGENT_NOT_FOUND)` -- if the registration ID does not exist.
- `AgentGovException(AGENT_NOT_ACTIVE)` -- if the agent is not in Active status.

---

### endSession

Ends an active session.

```apex
public static AgentGov_Session__c endSession(Id sessionId)
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `sessionId` | Id | Yes | The session record ID |

**Returns:** `AgentGov_Session__c` -- The updated session record with Status = `Completed` and Session_End set.

---

### getAgent

Gets agent details by ID.

```apex
public static AgentGov_Registration__c getAgent(Id registrationId)
```

**Returns:** `AgentGov_Registration__c` or `null` if not found.

---

## AgentGovBudgetManager

Manages governor limit budgets for AI agents.

### BudgetResult (Inner Class)

```apex
public class BudgetResult {
    public Boolean allowed;              // Whether the agent has budget
    public String budgetStatus;          // Normal, Warning, Throttled, Blocked, Exhausted
    public Decimal apiCallsRemaining;    // Remaining API call budget
    public Decimal soqlQueriesRemaining; // Remaining SOQL query budget
    public Decimal dmlOperationsRemaining; // Remaining DML operation budget
    public Decimal apiUsagePercent;      // API usage as percentage (0-100)
    public Decimal soqlUsagePercent;     // SOQL usage as percentage (0-100)
    public Decimal dmlUsagePercent;      // DML usage as percentage (0-100)
}
```

### checkBudget

Checks if an agent has budget remaining. **Does not consume budget.**

```apex
public static BudgetResult checkBudget(Id registrationId)
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `registrationId` | Id | Yes | The agent registration ID |

**Returns:** `BudgetResult` with current budget status and remaining amounts.

**Behavior:** If no budget record exists for today, one is automatically created using the agent's configured daily budgets.

---

### consumeBudget

Consumes budget for an agent action. Fires alerts at configured thresholds.

```apex
public static BudgetResult consumeBudget(Id registrationId, String limitType, Integer amount)
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `registrationId` | Id | Yes | The agent registration ID |
| `limitType` | String | Yes | `API_Calls`, `SOQL_Queries`, or `DML_Operations` |
| `amount` | Integer | Yes | The amount to consume (typically 1) |

**Returns:** `BudgetResult` after consumption.

**Throws:**
- `AgentGovException(BUDGET_EXCEEDED)` -- if consumption would exceed 100% or the block threshold.

**Side effects:**
- Budget record updated with new consumed amount.
- Budget status transitions: Normal -> Warning -> Throttled -> Blocked -> Exhausted.
- Platform events fired at each threshold crossing (if enabled).
- Uses `FOR UPDATE` on the budget record to prevent race conditions.

---

### getRemainingBudget

Alias for `checkBudget`. Returns remaining budget without consuming.

```apex
public static BudgetResult getRemainingBudget(Id registrationId)
```

---

### createDailyBudget

Creates a daily budget record for an agent using defaults from the registration.

```apex
public static AgentGov_Budget__c createDailyBudget(Id registrationId)
```

**Returns:** The created `AgentGov_Budget__c` record.

---

### resetDailyBudgets

Resets daily budgets for all active agents. Called by the `AgentGovDailyReset` scheduled job.

```apex
public static void resetDailyBudgets()
```

---

## AgentGovCircuitBreaker

Implements the Circuit Breaker pattern for AI agent health monitoring.

### allowRequest

Checks if an agent is allowed to make a request based on circuit breaker state.

```apex
public static Boolean allowRequest(Id registrationId)
```

**Returns:** `true` if the request is allowed (CLOSED or HALF_OPEN state), `false` if blocked (OPEN state with cooldown not yet elapsed).

**Side effects:** If the circuit breaker is OPEN and the cooldown has elapsed, automatically transitions to HALF_OPEN.

---

### recordSuccess

Records a successful action. In HALF_OPEN state, resets the circuit breaker to CLOSED.

```apex
public static void recordSuccess(Id registrationId)
```

**Side effects in HALF_OPEN state:**
- Circuit breaker state set to CLOSED
- Failure count reset to 0
- Agent status restored to Active (if it was Throttled or Blocked)

---

### recordFailure

Records a failed action. Increments failure count and trips the breaker if the threshold is exceeded.

```apex
public static void recordFailure(Id registrationId)
```

**Side effects:**
- Failure count incremented.
- If failure count >= threshold: state transitions to OPEN, agent status set to Blocked, cooldown timer set, alert event fired.
- In HALF_OPEN state: immediately transitions back to OPEN with doubled cooldown (exponential backoff).

---

### getState

Gets the current circuit breaker state.

```apex
public static String getState(Id registrationId)
```

**Returns:** `CLOSED`, `OPEN`, or `HALF_OPEN`.

---

### resetBreaker

Manually resets a circuit breaker to CLOSED state.

```apex
public static void resetBreaker(Id registrationId)
```

**Side effects:** Failure count reset to 0, cooldown cleared, agent status restored to Active if it was Blocked.

---

## AgentGovPolicyEngine

Evaluates agent policies before actions are executed.

### PolicyResult (Inner Class)

```apex
public class PolicyResult {
    public Boolean allowed;             // Whether the action is allowed
    public String denialReason;         // Human-readable denial reason (if denied)
    public Integer maxRecords;          // Maximum records per transaction (if set)
    public Set<String> restrictedFields; // Set of restricted field API names
}
```

### evaluatePolicy

Evaluates whether an agent is allowed to perform an action.

```apex
public static PolicyResult evaluatePolicy(Id registrationId, String objectName, String operation)
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `registrationId` | Id | Yes | The agent registration ID |
| `objectName` | String | Yes | Salesforce object API name (e.g., `Lead`, `Case`) |
| `operation` | String | Yes | `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`, or `Flow_Trigger` |

**Returns:** `PolicyResult` with evaluation details.

**Behavior:**
- If the framework is disabled, always returns `{allowed: true}`.
- If no policies match, returns `{allowed: true}` (default allow).
- Explicit deny always overrides explicit allow.
- Field restrictions and max records are collected from all matching allow policies.

---

### isActionAllowed

Convenience method that returns only the boolean result.

```apex
public static Boolean isActionAllowed(Id registrationId, String objectName, String operation)
```

---

### validatePolicies

Validates all policy metadata records and returns any issues found.

```apex
public static List<String> validatePolicies()
```

**Returns:** List of validation error messages (empty if all valid).

---

## AgentGovConflictResolver

Detects and resolves conflicts when multiple agents access the same record.

### ConflictResult (Inner Class)

```apex
public class ConflictResult {
    public Boolean hasConflict;     // Whether a conflict was detected
    public String resolution;       // Agent1_Won, Agent2_Won, Queued, or Failed
    public Id winningAgentId;       // The agent ID that won the conflict
    public String message;          // Human-readable resolution message
}
```

### checkForConflict

Checks if a record is locked by another agent and resolves based on priority.

```apex
public static ConflictResult checkForConflict(Id agentId, String recordId, String objectName)
```

**Behavior:**
- If conflict detection is disabled, returns `{hasConflict: false}`.
- If the record is not locked, locks it for the requesting agent and returns no conflict.
- If the record is locked by the same agent, returns no conflict.
- If locked by a different agent, compares priorities (lower number = higher priority).
  - Higher-priority agent overrides the lock.
  - Lower-priority agent is queued.
- All conflicts are logged to `AgentGov_Conflict_Log__c`.

---

### releaseRecord

Releases a record lock held by an agent.

```apex
public static void releaseRecord(Id agentId, String recordId, String objectName)
```

---

### isRecordLocked

Checks if a record is currently locked.

```apex
public static Boolean isRecordLocked(String recordId, String objectName)
```

---

### getLockHolder

Gets the agent ID that holds the lock on a record.

```apex
public static Id getLockHolder(String recordId, String objectName)
```

**Returns:** The agent registration ID holding the lock, or `null`.

---

## AgentGovContext

Transaction-level measurement wrapper for Apex agents. Uses the `Limits` class to automatically measure actual SOQL, DML, and callout consumption.

### startTracking

Begins tracking resource consumption for an agent.

```apex
public static AgentGovContext startTracking(Id registrationId)
public static AgentGovContext startTracking(Id registrationId, Id sessionId)
```

### stopTracking

Stops tracking, calculates the delta, and consumes budget by actual measured amounts.

```apex
public static AgentGovBudgetManager.BudgetResult stopTracking()
```

### executeGoverned

Convenience method that wraps an action in start/stop tracking with proper try/finally.

```apex
public static AgentGovBudgetManager.BudgetResult executeGoverned(Id registrationId, AgentGovAction action)
```

**Example:**
```apex
AgentGovBudgetManager.BudgetResult result = AgentGovContext.executeGoverned(agentId, new MyAction());

private class MyAction implements AgentGovContext.AgentGovAction {
    public void execute() {
        List<Lead> leads = [SELECT Id FROM Lead WHERE Status = 'Open' LIMIT 100];
        for (Lead l : leads) { l.Status = 'Working'; }
        update leads;
    }
}
// Budget consumed by actual delta: 1 SOQL + 1 DML (not hardcoded 1)
```

### getCurrentContext

Returns the active tracking context (for trigger-based agent identification).

```apex
public static AgentGovContext getCurrentContext()
```

---

## AgentGovProxyApi

REST API that executes CRUD operations on behalf of agents with real budget tracking.

**URL Mapping:** `/agentgov-proxy/*`

Endpoints: `/query`, `/create`, `/update`, `/delete`, `/upsert`

Each endpoint authenticates via `apiKey`, runs the full governance pipeline, performs the operation, and consumes budget by **actual record count**. See [REST API Reference](rest-api-reference.md) for request/response formats.

---

## AgentGovReportUsage

Invocable action for Flows to report actual resource consumption.

```apex
@InvocableMethod(label='Report Agent Usage')
public static List<Result> reportUsage(List<Request> requests)
```

**Input:** `registrationId`, `apiCallsUsed`, `soqlQueriesUsed`, `dmlStatementsUsed`
**Output:** `budgetStatus`, `apiCallsRemaining`, `soqlQueriesRemaining`, `dmlOperationsRemaining`
