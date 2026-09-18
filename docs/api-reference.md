# Apex API Reference

Public Apex surface of the AgentGov framework, by class. Every class states its security
posture; see the **Security model** section of the README for the reasoning.

---

## AgentGovRegistryService

`inherited sharing`. Registrations, credentials, and sessions.

| Method                                                                                                    | Returns                    | Notes                                                                                                       |
| --------------------------------------------------------------------------------------------------------- | -------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `registerAgent(String agentName, String agentType, String description, String apiKey, String ownerEmail)` | `AgentGov_Registration__c` | New agents start `Inactive`. A supplied key is stored as a hash; pass `null` to issue one later.            |
| `issueApiKey(Id registrationId)`                                                                          | `String`                   | Generates a new key, stores its hash and prefix, and returns the plaintext once. Replaces any previous key. |
| `bindAgentUser(Id registrationId, Id userId)`                                                             | `AgentGov_Registration__c` | Binds the user an agent runs as; REST calls by that user need no key. Pass `null` to unbind.                |
| `activateAgent(Id registrationId)`                                                                        | `AgentGov_Registration__c` | Throws `MAX_CONCURRENT_AGENTS` when the org limit is reached.                                               |
| `deactivateAgent(Id registrationId)`                                                                      | `AgentGov_Registration__c` | Terminates the active session, if any.                                                                      |
| `startSession(Id registrationId)`                                                                         | `AgentGov_Session__c`      | Requires an Active agent.                                                                                   |
| `endSession(Id sessionId)`                                                                                | `AgentGov_Session__c`      |                                                                                                             |
| `getAgent(Id registrationId)`                                                                             | `AgentGov_Registration__c` | `null` when not found.                                                                                      |

Throws `AgentGovException` with `INVALID_INPUT` (blank name, unknown type), `AGENT_NOT_FOUND`,
`AGENT_NOT_ACTIVE`, or `MAX_CONCURRENT_AGENTS`.

---

## AgentGovBudgetManager

`inherited sharing`. Daily budgets per agent. A budget's status is the most severe status
across the three limit types; Blocked and Exhausted deny every operation.

### Types

```apex
public class BudgetResult {
    public Boolean allowed;               // false when Blocked or Exhausted
    public String budgetStatus;           // Normal, Warning, Throttled, Blocked, Exhausted
    public Decimal apiCallsRemaining;
    public Decimal soqlQueriesRemaining;
    public Decimal dmlOperationsRemaining;
    public Decimal apiUsagePercent;
    public Decimal soqlUsagePercent;
    public Decimal dmlUsagePercent;
}

public class Thresholds { public Decimal warning; public Decimal throttle; public Decimal block; }

public class BatchOutcome {
    public Map<Id, BudgetResult> results;          // agents that were charged and remain allowed
    public Map<Id, AgentGovException> failures;    // agents whose request must be denied
}
```

### Methods

| Method                                                               | Notes                                                                                                                                    |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `checkBudget(Id registrationId)`                                     | Reads without consuming; creates today's row on first use.                                                                               |
| `checkBudgets(Set<Id> registrationIds)`                              | Bulk read. Throws `AGENT_NOT_FOUND` for an unknown Id.                                                                                   |
| `consumeBudget(Id registrationId, String limitType, Integer amount)` | Charges one limit type. Throws `BUDGET_EXCEEDED` when the resulting status is Blocked or Exhausted; the row is written before the throw. |
| `consumeBudget(Id registrationId, Map<String, Integer> consumption)` | Charges several limit types in one update. Same denial semantics.                                                                        |
| `consumeBudgets(Map<Id, Map<String, Integer>> consumptionByAgent)`   | Bulk charge: one locking query, one update, one alert publish. Never throws for a single agent; see `BatchOutcome`.                      |
| `creditBudget(Id registrationId, String limitType, Integer amount)`  | Credits usage back and re-evaluates the status, so a Blocked budget can recover.                                                         |
| `getRemainingBudget(Id registrationId)`                              | Alias of `checkBudget`.                                                                                                                  |
| `createDailyBudget(Id registrationId)`                               | Creates today's row; returns the existing row when one already exists.                                                                   |
| `resetDailyBudgets()`                                                | Creates today's row for every Active agent; existing rows are left alone.                                                                |
| `buildBudgetKey(Id registrationId, Date budgetDate)`                 | The unique `Budget_Key__c` value.                                                                                                        |
| `resolveStatus(Decimal usagePercent, Thresholds thresholds)`         | Pure threshold ladder.                                                                                                                   |
| `thresholdsFor(String limitType)`                                    | From `AgentGov_Limit_Config__mdt`, with framework defaults. Tests can inject `thresholdOverrides`.                                       |

Alerts (`AgentGov_Alert__e`) are published when a budget moves to a more severe status.
Session counters on the active session are updated with every charge.

---

## AgentGovCircuitBreaker

`inherited sharing`. CLOSED → OPEN → HALF_OPEN → CLOSED. Only one probe request is admitted
while HALF_OPEN; a probe that never reports within one cooldown period is treated as
abandoned. A failed probe re-trips with a doubled cooldown, capped at one day.

| Method                                                 | Notes                                                                              |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| `allowRequest(Id registrationId)`                      | Throws `AGENT_NOT_FOUND`. Performs OPEN → HALF_OPEN when the cooldown has elapsed. |
| `allowRequests(Set<Id> registrationIds)`               | Bulk decision; unknown Ids are absent from the result. Locks non-CLOSED rows.      |
| `recordSuccess(Id registrationId)`                     | HALF_OPEN → CLOSED, failures reset, status back to Active.                         |
| `recordFailure(Id registrationId)`                     | Counts failures; trips at the threshold; a HALF_OPEN failure re-trips immediately. |
| `recordOutcomes(Map<Id, Boolean> outcomes)`            | Bulk form of the two above.                                                        |
| `getState(Id registrationId)`                          | `CLOSED`, `OPEN`, or `HALF_OPEN`.                                                  |
| `resetBreaker(Id registrationId)`                      | Manual close.                                                                      |
| `transitionToHalfOpen(List<AgentGov_Registration__c>)` | Used by the health check job.                                                      |

---

## AgentGovPolicyEngine

`inherited sharing`. Evaluates `AgentGov_Policy__mdt`. Explicit deny beats allow; no match
means allow.

```apex
public class PolicyResult {
  public Boolean allowed;
  public String denialReason;
  public Integer maxRecords; // lowest cap among matching allow policies, or null
  public List<String> restrictedFields; // union of Field_Restrictions__c among matching allow policies
}
```

| Method                                                                    | Notes                                                                 |
| ------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `evaluatePolicy(Id registrationId, String objectName, String operation)`  | Object and operation matching is case-insensitive; `*` is a wildcard. |
| `isActionAllowed(Id registrationId, String objectName, String operation)` | Boolean convenience.                                                  |
| `assertFieldsAllowed(PolicyResult policy, Set<String> fieldNames)`        | Throws `POLICY_VIOLATION` naming any restricted field in the set.     |
| `assertRecordCount(PolicyResult policy, Integer recordCount)`             | Throws `POLICY_VIOLATION` above `maxRecords`.                         |
| `validatePolicies()`                                                      | Lists configuration problems in the policy records.                   |

---

## AgentGovConflictResolver

`inherited sharing`. In-memory record locks for the current transaction, resolved by agent
priority (lower number wins). Every conflict is written to `AgentGov_Conflict_Log__c`.

| Method                                                             | Notes                                                                                  |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| `checkForConflict(Id agentId, String recordId, String objectName)` | Returns a `ConflictResult` (`hasConflict`, `resolution`, `winningAgentId`, `message`). |
| `assertNoConflict(Id agentId, String recordId, String objectName)` | Throws `RECORD_LOCKED` when another agent wins.                                        |
| `releaseRecord(Id agentId, String recordId, String objectName)`    |                                                                                        |
| `isRecordLocked(String recordId, String objectName)`               |                                                                                        |
| `getLockHolder(String recordId, String objectName)`                |                                                                                        |

---

## AgentGovContext

`inherited sharing`. Measures the SOQL, DML, and callouts an Apex agent actually uses and
charges them. Contexts nest; each agent is charged only for its own work, and the
framework's own bookkeeping is excluded from the enclosing context.

| Method                                                      | Notes                                                                                                                      |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `startTracking(Id registrationId)`                          | Pushes a context.                                                                                                          |
| `startTracking(Id registrationId, Id sessionId)`            | Same, with a session.                                                                                                      |
| `stopTracking()`                                            | Pops the innermost context and charges its delta. Throws `BUDGET_EXCEEDED` when the charge exhausts the budget.            |
| `executeGoverned(Id registrationId, AgentGovAction action)` | Runs the action under measurement. If the action throws, the measured usage is still charged and the exception propagates. |
| `getCurrentContext()`                                       | Innermost active context, or `null`.                                                                                       |
| `getRegistrationId()`, `getSessionId()`                     | Instance accessors.                                                                                                        |

```apex
AgentGovBudgetManager.BudgetResult result = AgentGovContext.executeGoverned(agentId, new EnrichLeads());

private class EnrichLeads implements AgentGovContext.AgentGovAction {
    public void execute() {
        List<Lead> leads = [SELECT Id FROM Lead WHERE Status = 'Open' LIMIT 100];
        for (Lead lead : leads) {
            lead.Status = 'Working';
        }
        update leads;
    }
}
```

---

## AgentGovRestAuth

`inherited sharing`. Resolves the calling agent for the REST resources.

| Method                                                                                                | Notes                                                                                                                |
| ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `resolveRegistration(RestRequest request, Map<String, Object> body)`                                  | Header key, then deprecated body key, then the bound user. Upgrades legacy plaintext keys. Throws `AGENT_NOT_FOUND`. |
| `requireActive(AgentGov_Registration__c registration, Boolean allowThrottled)`                        | Throws `AGENT_NOT_ACTIVE`.                                                                                           |
| `requireOwnerOrAdmin(AgentGov_Registration__c caller, Id targetRegistrationId)`                       | Throws `ACCESS_DENIED` unless the caller is the target or holds `AgentGov_Admin_Access`.                             |
| `hasAdminAccess()`                                                                                    | Custom permission check.                                                                                             |
| `generateKey()`, `hashKey(String)`, `keyPrefix(String)`, `applyKey(AgentGov_Registration__c, String)` | Key helpers; `applyKey` sets the hash, prefix, and rotation time and clears `API_Key__c` without DML.                |
| `wasBodyKeyUsed()`                                                                                    | Whether the last resolution used the deprecated body credential.                                                     |

---

## AgentGovRestResponder

`inherited sharing`. Builds the REST envelope: `success(...)`, `error(...)`, `notFound(...)`,
`internalError(...)` (logs the exception under the correlation id and returns a generic
message), `correlationId(RestRequest)`, and `remainingBudget(BudgetResult)`.

---

## AgentGovQueryBuilder

`inherited sharing`. Compiles the proxy's structured query into SOQL with bind variables and
executes it in user mode.

| Method                                                                                   | Notes                                                                                 |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `parse(Map<String, Object> body)`                                                        | Validates the request shape; rejects a `query` property.                              |
| `describe(String objectName)`                                                            | Throws `INVALID_INPUT` for an unknown object.                                         |
| `build(QueryRequest request, Schema.DescribeSObjectResult describe, Integer maxRecords)` | Produces `BuiltQuery` (`soql`, `binds`, `referencedFields`, `effectiveLimit`).        |
| `execute(BuiltQuery built)`                                                              | `Database.queryWithBinds` in `USER_MODE`; access failures become `ACCESS_DENIED`.     |
| `resolveField(...)`, `convertFieldValue(...)`, `typedList(...)`                          | Field validation and JSON-to-Apex conversion, shared with the proxy's write handlers. |

---

## AgentGovSelector

`without sharing`, all queries `WITH SYSTEM_MODE`. Reads the framework's own records and
metadata on behalf of the framework, with per-transaction caching of settings, metadata,
and registrations. Not for presenting data to people; see `AgentGovDashboardController`.

Key methods: `getSettings()`, `isFrameworkEnabled()`, `isRealTimeEventsEnabled()`,
`getLimitConfigs()`, `getLimitConfigByType(String)`, `getPolicies()`,
`getPoliciesForAgentType(String)`, `getRegistrationById(Id)`, `getRegistrationsByIds(Set<Id>)`,
`getRegistrationsForUpdate(Set<Id>)`, `getRegistrationByApiKeyHash(String)`,
`getRegistrationByLegacyApiKey(String)`, `getRegistrationByAgentUser(Id)`,
`cacheRegistration(AgentGov_Registration__c)`, `getActiveRegistrations()`,
`getActiveAgentCount()`, `getOpenAgentsPastCooldown()`, `getTodaysBudget(Id)`,
`getTodaysBudgets(Set<Id>)`, `getTodaysBudgetForUpdate(Id)`, `getTodaysBudgetsForUpdate(Set<Id>)`,
`getActiveSession(Id)`, `getActiveSessionsByAgent(Set<Id>)`, `getSessionById(Id)`,
`getOrphanedSessions(Integer)`, `getRecentActionLogs(Id, Integer)`, `clearCache()`.

## AgentGovDml

`without sharing`, all statements in `AccessLevel.SYSTEM_MODE`. The only place the framework
writes its own records: `insertRecords`, `insertRecord`, `updateRecords`, `updateRecord`,
`deleteRecords`, `publishEvents`, `assertAllSucceeded`, `isDuplicateValueFailure`,
`describeErrors`.

## AgentGovDashboardController

`with sharing`, all queries `WITH USER_MODE`, every method `@AuraEnabled(cacheable=true)`:
`getAllRegistrations()`, `getAllTodaysBudgets()`, `getRecentConflictLogs(Integer)`,
`getTodaysActionCount()`, `getActiveSessions()`, `getTrippedCircuitBreakerCount()`. Access
failures surface as an `AuraHandledException` that names the permission set to ask for.

## AgentGovTriggerHandler

`inherited sharing`. Audit trail and alert delivery: `logAction(...)`, `buildEvent(...)`,
`logActions(List<AgentGov_Action_Event__e>)`, `publishAlerts(List<AgentGov_Alert__e>)`,
`handleActionEvents(...)`, `handleAlerts(...)`, `populateBudgetKeys(...)`,
`recordFrameworkEvent(Id, String, String, String)`.

---

## Invocable actions

All five actions are bulk-safe. See the Flow integration guide for inputs and outputs.

| Class                    | Label                 |
| ------------------------ | --------------------- |
| `AgentGovRegisterAction` | Register Agent Action |
| `AgentGovCheckBudget`    | Check Agent Budget    |
| `AgentGovGetStatus`      | Get Agent Status      |
| `AgentGovLogAction`      | Log Agent Action      |
| `AgentGovReportUsage`    | Report Agent Usage    |

## Jobs

| Class                 | Type                                | Purpose                                                            |
| --------------------- | ----------------------------------- | ------------------------------------------------------------------ |
| `AgentGovDailyReset`  | `Schedulable`                       | Creates today's budget for every Active agent                      |
| `AgentGovHealthCheck` | `Schedulable`                       | OPEN → HALF_OPEN after cooldown; terminates orphaned sessions      |
| `AgentGovCleanup`     | `Database.Batchable`, `Schedulable` | Purges action logs older than the retention period; logs a summary |

## AgentGovException

`ErrorCode` values a caller can actually receive: `AGENT_NOT_FOUND`, `AGENT_NOT_ACTIVE`,
`ACCESS_DENIED`, `BUDGET_EXCEEDED`, `CIRCUIT_BREAKER_OPEN`, `POLICY_VIOLATION`,
`RECORD_LOCKED`, `MAX_CONCURRENT_AGENTS`, `INVALID_INPUT`, `INTERNAL_ERROR`.
`getHttpStatusCode()` maps them to the REST status.

The enum also declares `FRAMEWORK_DISABLED`, `AGENT_BLOCKED` and `BUDGET_THROTTLED`. Nothing
constructs them today: a disabled framework allows the request rather than refusing it, and a
blocked or throttled agent is refused as `AGENT_NOT_ACTIVE` or `BUDGET_EXCEEDED`. They are
kept so the enum stays stable for callers that already switch on it, and are candidates for
removal in a future major version. Do not write code that waits for them.

## AgentGovConstants

Picklist values, defaults, REST contract strings, and error messages. Notable additions in
v1.2: `REST_HEADER_API_KEY`, `REST_HEADER_CORRELATION_ID`, `CUSTOM_PERMISSION_ADMIN_ACCESS`,
`ACTION_SYSTEM`, `QUERY_OPERATORS`, `DEFAULT_QUERY_LIMIT`, `MAX_QUERY_LIMIT`,
`CB_MAX_COOLDOWN_MINUTES`, `ORPHAN_SESSION_HOURS`.
