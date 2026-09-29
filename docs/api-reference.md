# Apex API Reference

Public Apex surface of the AgentGov framework, by class. Every class states its security
posture; see the **Security model** section of the README for the reasoning.

---

## AgentGovRegistryService

`inherited sharing`. Registrations, credentials, and sessions.

| Method                                                                                                    | Returns                          | Notes                                                                                                                                                                                |
| --------------------------------------------------------------------------------------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `registerAgent(String agentName, String agentType, String description, String apiKey, String ownerEmail)` | `AgentGov_Registration__c`       | New agents start `Inactive`. A supplied key of at least 24 characters is stored as a hash; pass `null` to issue one later. Returns the saved row, with its registration number.      |
| `issueApiKey(Id registrationId)`                                                                          | `String`                         | Generates a new key, stores its hash and prefix, and returns the plaintext once. Replaces any previous key.                                                                          |
| `bindAgentUser(Id registrationId, Id userId)`                                                             | `AgentGov_Registration__c`       | Binds the user an agent runs as; REST calls by that user need no key while it is bound to this registration alone. A user bound to several must send the key. Pass `null` to unbind. |
| `activateAgent(Id registrationId)`                                                                        | `AgentGov_Registration__c`       | Throws `MAX_CONCURRENT_AGENTS` when the org limit is reached.                                                                                                                        |
| `activateAgents(Set<Id> registrationIds)`                                                                 | `List<AgentGov_Registration__c>` | Bulk. The concurrent-agent limit applies to the batch as a whole.                                                                                                                    |
| `deactivateAgent(Id registrationId)`                                                                      | `AgentGov_Registration__c`       | Ends every active session of the agent.                                                                                                                                              |
| `deactivateAgents(Set<Id> registrationIds)`                                                               | `List<AgentGov_Registration__c>` | Per-agent kill switch, in bulk: refused on every entry point, and every active session ends.                                                                                         |
| `startSession(Id registrationId)`                                                                         | `AgentGov_Session__c`            | Requires an Active agent. Ends the agent's current session first. Sessions also open automatically.                                                                                  |
| `endSession(Id sessionId)`                                                                                | `AgentGov_Session__c`            | Completed, `Ended_By_Caller`. An already-ended session is returned unchanged.                                                                                                        |
| `terminateSessions(Set<Id> sessionIds)`                                                                   | `List<AgentGov_Session__c>`      | Administrator end: Terminated, `Ended_By_Administrator`.                                                                                                                             |
| `getAgent(Id registrationId)`                                                                             | `AgentGov_Registration__c`       | `null` when not found.                                                                                                                                                               |

Throws `AgentGovException` with `INVALID_INPUT` (blank name, unknown type, a supplied key that
is shorter than 24 characters or already in use, or a value the database rejects, such as a
malformed owner email), `AGENT_NOT_FOUND`, `AGENT_NOT_ACTIVE`, or `MAX_CONCURRENT_AGENTS`.

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

| Method                                                                                              | Notes                                                                                                                                            |
| --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `checkBudget(Id registrationId)`                                                                    | Reads without consuming; creates today's row on first use.                                                                                       |
| `checkBudgets(Set<Id> registrationIds)`                                                             | Bulk read. Throws `AGENT_NOT_FOUND` for an unknown Id.                                                                                           |
| `consumeBudget(Id registrationId, String limitType, Integer amount)`                                | Charges one limit type. Throws `BUDGET_EXCEEDED` when the resulting status is Blocked or Exhausted; the row is written before the throw.         |
| `consumeBudget(Id registrationId, Map<String, Integer> consumption)`                                | Charges several limit types in one update. Same denial semantics.                                                                                |
| `consumeBudget(Id registrationId, Map<String, Integer> consumption, Integer actionCount)`           | As above, recording `actionCount` governed actions on the agent's session. A usage report passes 0.                                              |
| `consumeBudgets(Map<Id, Map<String, Integer>> consumptionByAgent)`                                  | Bulk charge: one locking query, one update, one alert publish. Never throws for a single agent; see `BatchOutcome`. Counts one action per agent. |
| `consumeBudgets(Map<Id, Map<String, Integer>> consumptionByAgent, Map<Id, Integer> actionsByAgent)` | Bulk charge that records each agent's number of governed actions, for example 200 for a 200-request Flow batch.                                  |
| `budgetDate()`                                                                                      | Today in the org's time zone: the day budget rows are counted in, whoever the running user is.                                                   |
| `creditBudget(Id registrationId, String limitType, Integer amount)`                                 | Credits usage back and re-evaluates the status, so a Blocked budget can recover.                                                                 |
| `getRemainingBudget(Id registrationId)`                                                             | Alias of `checkBudget`.                                                                                                                          |
| `createDailyBudget(Id registrationId)`                                                              | Creates today's row; returns the existing row when one already exists.                                                                           |
| `resetDailyBudgets()`                                                                               | Creates today's row for every Active agent; existing rows are left alone.                                                                        |
| `buildBudgetKey(Id registrationId, Date budgetDate)`                                                | The unique `Budget_Key__c` value.                                                                                                                |
| `resolveStatus(Decimal usagePercent, Thresholds thresholds)`                                        | Pure threshold ladder.                                                                                                                           |
| `thresholdsFor(String limitType)`                                                                   | From `AgentGov_Limit_Config__mdt`, with framework defaults. Tests can inject `thresholdOverrides`.                                               |

Alerts (`AgentGov_Alert__e`) are published when a budget moves to a more severe status.
Every charge is also recorded on the agent's current session through `AgentGovSessionTracker`.

---

## AgentGovSessionTracker

`inherited sharing`. Keeps each agent's session current. A session opens on the agent's first
governed action and closes after `Session_Idle_Minutes__c` without activity or after 24 hours.
The unique `Active_Session_Key__c` allows one active session per agent; a transaction that
loses the race to open one adds its usage to the winner's session.

| Method                                                                                         | Notes                                                                                           |
| ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `recordActivity(Map<Id, Map<String, Integer>> usage, Map<Id, Integer> actions)`                | Called by `consumeBudgets`. Opens, extends, or rolls over sessions; refreshes `Last_Active__c`. |
| `currentSessionFor(Id registrationId)`                                                         | The session this transaction recorded the agent's activity in, or `null`.                       |
| `startSession(Id)`, `endSessions(Set<Id>, String, String)`, `endAllForAgents(Set<Id>, String)` | Explicit boundaries, used by `AgentGovRegistryService` and the console.                         |
| `closeStale(Integer maxRows)`                                                                  | Closes idle and over-long sessions at their last activity. Called by the health check.          |

---

## AgentGovCircuitBreaker

`inherited sharing`. CLOSED → OPEN → HALF_OPEN → CLOSED. Only one probe request is admitted
while HALF_OPEN; a probe that never reports within one cooldown period is treated as
abandoned. A failed probe re-trips with twice the configured cooldown, capped at one day; the
longer cooldown does not compound over repeated failed probes.

| Method                                                 | Notes                                                                                 |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| `allowRequest(Id registrationId)`                      | Throws `AGENT_NOT_FOUND`. Performs OPEN → HALF_OPEN when the cooldown has elapsed.    |
| `allowRequests(Set<Id> registrationIds)`               | Bulk decision; unknown Ids are absent from the result. Locks non-CLOSED rows.         |
| `recordSuccess(Id registrationId)`                     | HALF_OPEN → CLOSED, failures reset, status back to Active.                            |
| `recordFailure(Id registrationId)`                     | Counts failures; trips at the threshold; a HALF_OPEN failure re-trips immediately.    |
| `recordOutcomes(Map<Id, Boolean> outcomes)`            | Bulk form of the two above.                                                           |
| `getState(Id registrationId)`                          | `CLOSED`, `OPEN`, or `HALF_OPEN`.                                                     |
| `resetBreaker(Id registrationId)`                      | Manual close.                                                                         |
| `resetBreakers(Set<Id> registrationIds)`               | Bulk manual close that reactivates blocked agents; returns the registrations found.   |
| `mayProbe(AgentGov_Registration__c registration)`      | True when the breaker is HALF_OPEN, or OPEN with its cooldown served. Writes nothing. |
| `transitionToHalfOpen(List<AgentGov_Registration__c>)` | Used by the health check job.                                                         |

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
| `startTracking(Id registrationId)`                          | Pushes a context. Throws `AGENT_NOT_ACTIVE` for a deactivated agent.                                                       |
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

| Method                                                                                                | Notes                                                                                                                                                                                          |
| ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `resolveRegistration(RestRequest request, Map<String, Object> body)`                                  | Header key, then deprecated body key, then the bound user. Upgrades legacy plaintext keys. Throws `AGENT_NOT_FOUND`, or `ACCESS_DENIED` when a keyless user is bound to several registrations. |
| `requireActive(AgentGov_Registration__c registration, Boolean allowThrottled)`                        | Throws `AGENT_NOT_ACTIVE`.                                                                                                                                                                     |
| `requireOwnerOrAdmin(AgentGov_Registration__c caller, Id targetRegistrationId)`                       | Throws `ACCESS_DENIED` unless the caller is the target or holds `AgentGov_Admin_Access`.                                                                                                       |
| `hasAdminAccess()`                                                                                    | Custom permission check.                                                                                                                                                                       |
| `generateKey()`, `hashKey(String)`, `keyPrefix(String)`, `applyKey(AgentGov_Registration__c, String)` | Key helpers; `applyKey` sets the hash, prefix, and rotation time and clears `API_Key__c` without DML.                                                                                          |
| `wasBodyKeyUsed()`                                                                                    | Whether the last resolution used the deprecated body credential.                                                                                                                               |

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
`getTodaysActionCount()`, `getActiveSessions()` (live sessions only),
`getTrippedCircuitBreakerCount()`, `getAgentSummaries()`, `getAgentSummary(Id)`,
`getActionLogs(Id, String, String, Integer, String, DateTime, Id, Integer)` (filtered, paged on
`CreatedDate` and `Id`), `getUsageHistory(Id, Integer)` (daily usage; `null` for the whole
org), and `getRecentAlerts(Integer)`. Access failures surface as an `AuraHandledException`
that names the permission set to ask for.

## AgentGovAdminController

`with sharing`. The console's actions: `resetBreakers(List<Id>)`, `activateAgents(List<Id>)`,
`deactivateAgents(List<Id>)`, `endSessions(List<Id>)`, `creditBudget(Id, String, Integer)`,
`rotateApiKey(Id)`, `scheduleJobs()`, and the cacheable `getSetupStatus()`. Each checks
`AgentGov_Operate_Agents` (or `AgentGov_Manage_Keys` for `rotateApiKey`) on the server, acts
only on records the user can read, accepts at most 200 records, and writes an `Admin`
action-log row in the same transaction. Operational failures are returned as outcomes with
`success = false`; permission and validation failures throw `AuraHandledException`.

## AgentGovJobScheduler

`inherited sharing`. `scheduleAll()` schedules the three jobs with the documented schedules,
replacing any AgentGov jobs already scheduled; `unscheduleAll()` removes them; and
`getJobStatus()` reports whether each is scheduled and its next run.

## AgentGovRequestContext

Per-request correlation id and timing for the audit trail. Entry points call `begin(String)`;
invocable actions call `ensureBegun(String)`. `getCorrelationId()` and `elapsedMs()` return
`null` outside a request.

## AgentGovTriggerHandler

`inherited sharing`. Audit trail and alert delivery: `logAction(...)`, `buildEvent(...)`,
`logActions(List<AgentGov_Action_Event__e>)`, `publishAlerts(List<AgentGov_Alert__e>)`,
`handleActionEvents(...)`, `handleAlerts(...)` (records each alert as an `Alert` row, then
emails the administrator and, when enabled, each agent's owner), `populateBudgetKeys(...)`,
`populateSessionKeys(...)`, and `recordFrameworkEvent(Id, String, String, String)`. Events
built by `buildEvent` carry the request's correlation id, its elapsed time, and the agent's
current session.

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

| Class                 | Type                                | Purpose                                                                                                             |
| --------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `AgentGovDailyReset`  | `Schedulable`                       | Creates today's budget for every Active agent                                                                       |
| `AgentGovHealthCheck` | `Schedulable`                       | OPEN → HALF_OPEN after cooldown; closes idle and over-long sessions                                                 |
| `AgentGovCleanup`     | `Database.Batchable`, `Schedulable` | Purges logs, conflicts, finished sessions, and old budget rows, one object per chained run, with a summary for each |

## AgentGovSampleData

`with sharing`. Demonstration data for a new org, run from anonymous Apex by an administrator
with `AgentGov_Admin`; its writes run in user mode. `scripts/setup/load-sample-data.apex` calls
`createAll()`.

| Method               | Returns   | Notes                                                                                                                                                              |
| -------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `createAll()`        | `String`  | Creates settings, five agents with the fixed keys in `SAMPLE_API_KEYS`, today's budgets, sessions, action logs, alerts, and conflicts. Returns a one-line summary. |
| `deleteSampleData()` | `Integer` | Deletes only the sample agents and their rows, found by their keys, so an agent whose key was rotated is no longer removed. Returns the rows removed.              |
| `deleteAll()`        | `Integer` | Deletes every AgentGov row in the org, capped per run; run it again until it returns 0.                                                                            |

Framework plumbing that is public only so other framework classes can call it, such as
`AgentGovConflictResolver.deferLogs()` and `flushLogs()` or
`AgentGovRestAuth.requireUsableKey()`, is not listed here and may change without notice.

## AgentGovException

`ErrorCode` values a caller can actually receive: `AGENT_NOT_FOUND`, `AGENT_NOT_ACTIVE`,
`ACCESS_DENIED`, `BUDGET_EXCEEDED`, `CIRCUIT_BREAKER_OPEN`, `POLICY_VIOLATION`,
`RECORD_LOCKED`, `MAX_CONCURRENT_AGENTS`, `INVALID_INPUT`, `INTERNAL_ERROR`.
`getHttpStatusCode()` maps them to the REST status.

The enum also declares `FRAMEWORK_DISABLED`, `AGENT_BLOCKED` and `BUDGET_THROTTLED`. Nothing
constructs them today: a disabled framework allows the request rather than refusing it; over
REST and the proxy an agent its breaker left Blocked is refused as `AGENT_NOT_ACTIVE` and a
Blocked or Exhausted budget as `BUDGET_EXCEEDED`; and a Throttled agent or budget is not
refused at all. They are
kept so the enum stays stable for callers that already switch on it, and are candidates for
removal in a future major version. Do not write code that waits for them.

## AgentGovConstants

Picklist values, defaults, REST contract strings, and error messages. Notable additions in
v1.2: `REST_HEADER_API_KEY`, `REST_HEADER_CORRELATION_ID`, `CUSTOM_PERMISSION_ADMIN_ACCESS`,
`ACTION_SYSTEM`, `QUERY_OPERATORS`, `DEFAULT_QUERY_LIMIT`, `MAX_QUERY_LIMIT`,
`CB_MAX_COOLDOWN_MINUTES`, `ORPHAN_SESSION_HOURS`.
