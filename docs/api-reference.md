# Apex API Reference

The public Apex surface of the AgentGov framework, by class, with each class's security
posture; the **Security model** section of the README explains the reasoning. Methods that
exist only so that framework classes can call one another are listed briefly as framework
plumbing and may change without notice. The REST endpoints are documented in the
[REST API Reference](rest-api-reference.md).

The service classes enforce no agent status of their own. Apart from
`AgentGovRegistryService.startSession` and `AgentGovContext.startTracking`, they act on any
registration they are given, so Apex that calls them directly must check `Status__c` itself,
as the framework's entry points do.

---

## AgentGovRegistryService

`inherited sharing`. Registrations, credentials, and sessions. Reads go through
`AgentGovSelector` and writes through `AgentGovDml`, both in system mode, so an integration
user can register itself without access to AgentGov objects.

| Method                                                                                                    | Returns                          | Notes                                                                                                                                                                                                                                                                                                                                                        |
| --------------------------------------------------------------------------------------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `registerAgent(String agentName, String agentType, String description, String apiKey, String ownerEmail)` | `AgentGov_Registration__c`       | New agents start `Inactive`, with the default priority from settings and daily budgets from `AgentGov_Limit_Config__mdt` or the built-in defaults. `agentType` is a stored value, such as `MCP_External`. A supplied key of at least 24 characters is stored as a hash; pass `null` to issue one later. Returns the saved row, with its registration number. |
| `issueApiKey(Id registrationId)`                                                                          | `String`                         | Generates a new key, stores its hash and prefix, and returns the plaintext once. Replaces any previous key.                                                                                                                                                                                                                                                  |
| `bindAgentUser(Id registrationId, Id userId)`                                                             | `AgentGov_Registration__c`       | Binds the user an agent runs as; REST calls by that user need no key while it is bound to this registration alone. A user bound to several must send the key. Pass `null` to unbind.                                                                                                                                                                         |
| `activateAgent(Id registrationId)`                                                                        | `AgentGov_Registration__c`       | Throws `MAX_CONCURRENT_AGENTS` when the agent is not already Active and the org's limit of Active agents is reached.                                                                                                                                                                                                                                         |
| `activateAgents(Set<Id> registrationIds)`                                                                 | `List<AgentGov_Registration__c>` | Bulk. Agents already Active are left as they are, the limit applies to the batch as a whole, and Ids that name no registration are skipped. Returns the registrations found.                                                                                                                                                                                 |
| `deactivateAgent(Id registrationId)`                                                                      | `AgentGov_Registration__c`       | The per-agent kill switch: the agent is refused at every governed entry point, and each of its active sessions ends as Terminated, `Agent_Deactivated`.                                                                                                                                                                                                      |
| `deactivateAgents(Set<Id> registrationIds)`                                                               | `List<AgentGov_Registration__c>` | Bulk form. Returns the registrations found.                                                                                                                                                                                                                                                                                                                  |
| `startSession(Id registrationId)`                                                                         | `AgentGov_Session__c`            | Requires an Active agent; a Throttled or Blocked one is refused with `AGENT_NOT_ACTIVE`. Ends the agent's current session first (Completed, `Ended_By_Caller`). Sessions also open automatically.                                                                                                                                                            |
| `endSession(Id sessionId)`                                                                                | `AgentGov_Session__c`            | Completed, `Ended_By_Caller`. An already-ended session is returned unchanged; an Id that names no session throws `AGENT_NOT_FOUND`.                                                                                                                                                                                                                          |
| `terminateSessions(Set<Id> sessionIds)`                                                                   | `List<AgentGov_Session__c>`      | Administrator end: Terminated, `Ended_By_Administrator`. Returns the sessions it ended; sessions already ended are left out.                                                                                                                                                                                                                                 |
| `getAgent(Id registrationId)`                                                                             | `AgentGov_Registration__c`       | `null` when not found.                                                                                                                                                                                                                                                                                                                                       |

Throws `AgentGovException` with `INVALID_INPUT` (blank name, unknown type, a supplied key that
is shorter than 24 characters or already in use, or a value the database rejects, such as a
malformed owner email), `AGENT_NOT_FOUND`, `AGENT_NOT_ACTIVE`, or `MAX_CONCURRENT_AGENTS`.

---

## AgentGovBudgetManager

`inherited sharing`. Daily budgets per agent; reads go through `AgentGovSelector` and writes
through `AgentGovDml`, both in system mode. A budget's status is the most severe status across
the three limit types, and Blocked and Exhausted deny every operation. Budget days follow the
org's default time zone.

### Types

```apex
public class BudgetResult {
    public Boolean allowed;               // false when Blocked or Exhausted
    public String budgetStatus;           // Normal, Warning, Throttled, Blocked, Exhausted
    public Decimal apiCallsRemaining;     // negative once refused charges pass the allocation
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

Limit types are `API_Calls`, `SOQL_Queries`, and `DML_Operations`.

| Method                                                                                              | Notes                                                                                                                                                                                                                                                                                                                                                                                       |
| --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `checkBudget(Id registrationId)`                                                                    | Reads without consuming; creates today's row on first use. Throws `INVALID_INPUT` for a null Id and `AGENT_NOT_FOUND` for an unknown agent.                                                                                                                                                                                                                                                 |
| `checkBudgets(Set<Id> registrationIds)`                                                             | Bulk read. Throws `AGENT_NOT_FOUND` when any Id names no agent.                                                                                                                                                                                                                                                                                                                             |
| `consumeBudget(Id registrationId, String limitType, Integer amount)`                                | Charges one limit type and counts one action on the agent's session. Throws `BUDGET_EXCEEDED` when the resulting status is Blocked or Exhausted; the charge is written before the throw. Throws `INVALID_INPUT` for an unknown limit type.                                                                                                                                                  |
| `consumeBudget(Id registrationId, Map<String, Integer> consumption)`                                | Charges several limit types in one update. Same refusal rules.                                                                                                                                                                                                                                                                                                                              |
| `consumeBudget(Id registrationId, Map<String, Integer> consumption, Integer actionCount)`           | As above, recording `actionCount` actions on the agent's session; a usage report passes 0. An empty map reads the budget instead.                                                                                                                                                                                                                                                           |
| `consumeBudgets(Map<Id, Map<String, Integer>> consumptionByAgent)`                                  | Bulk charge: one locking query, one update, one alert publish. Never throws for a single agent; see `BatchOutcome`. Counts one action per agent.                                                                                                                                                                                                                                            |
| `consumeBudgets(Map<Id, Map<String, Integer>> consumptionByAgent, Map<Id, Integer> actionsByAgent)` | Bulk charge that records each agent's number of actions, for example 200 for a 200-request Flow batch.                                                                                                                                                                                                                                                                                      |
| `creditBudget(Id registrationId, String limitType, Integer amount)`                                 | Credits usage of one limit type back to today's row and re-evaluates the status, so a Blocked budget can recover. Usage never goes below zero, and a null or negative amount credits nothing. Today's row is created if needed and stays locked for the rest of the transaction. Throws `INVALID_INPUT` for a null Id or an unknown limit type, and `AGENT_NOT_FOUND` for an unknown agent. |
| `budgetDate()`                                                                                      | Today in the org's default time zone: the day budget rows are counted in, whoever the running user is.                                                                                                                                                                                                                                                                                      |
| `getRemainingBudget(Id registrationId)`                                                             | Alias of `checkBudget`, kept for compatibility.                                                                                                                                                                                                                                                                                                                                             |
| `createDailyBudget(Id registrationId)`                                                              | Creates today's row; returns the existing row when one already exists. Throws `AGENT_NOT_FOUND`.                                                                                                                                                                                                                                                                                            |
| `resetDailyBudgets()`                                                                               | Creates today's row for every Active agent; existing rows are left alone. Called by `AgentGovDailyReset`.                                                                                                                                                                                                                                                                                   |
| `defaultAllocation(String limitType, Integer fallback)`                                             | The daily allocation for an agent with no figure of its own: `Default_Daily_Budget__c` from the limit type's active `AgentGov_Limit_Config__mdt` record, or `fallback`.                                                                                                                                                                                                                     |
| `buildBudgetKey(Id registrationId, Date budgetDate)`                                                | The unique `Budget_Key__c` value.                                                                                                                                                                                                                                                                                                                                                           |
| `resolveStatus(Decimal usagePercent, Thresholds thresholds)`                                        | Pure threshold ladder: Exhausted from 100%, then Blocked, Throttled, and Warning at their thresholds.                                                                                                                                                                                                                                                                                       |
| `thresholdsFor(String limitType)`                                                                   | From the limit type's active `AgentGov_Limit_Config__mdt` record, with framework defaults of 80, 90, and 95. Tests can inject `thresholdOverrides`.                                                                                                                                                                                                                                         |

When a charge moves a budget to a more severe status, an `AgentGov_Alert__e` is published
through `AgentGovTriggerHandler.publishAlerts`, which raises nothing while
`Enable_Real_Time_Events__c` is unchecked. Every charge, a refused one included, is also added
to the agent's current session through `AgentGovSessionTracker`.

---

## AgentGovSessionTracker

`inherited sharing`. Keeps each agent's session current; reads go through `AgentGovSelector`
and writes through `AgentGovDml`, both in system mode. A session opens on the agent's first
governed action and closes after `Session_Idle_Minutes__c` without activity (a value outside 1
to 1440 counts as 30) or after 24 hours. The unique `Active_Session_Key__c` allows one active
session per agent; a transaction that loses the race to open one adds its usage to the winner's
session. A failure to record a session is written as a `System` row and never denies the
agent's action.

| Method                                                                                        | Notes                                                                                                                                                |
| --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `recordActivity(Map<Id, Map<String, Integer>> usageByAgent, Map<Id, Integer> actionsByAgent)` | Called by `consumeBudgets`. Opens, extends, or rolls over sessions, and refreshes `Last_Active__c` at most once a minute.                            |
| `currentSessionFor(Id registrationId)`                                                        | The session this transaction recorded the agent's activity in, or `null`.                                                                            |
| `startSession(Id registrationId)`                                                             | Ends the agent's active sessions (Completed, `Ended_By_Caller`) and opens a new one. `AgentGovRegistryService.startSession` checks the status first. |
| `endSessions(Set<Id> sessionIds, String status, String reason)`                               | Ends the given sessions now, with the status and `End_Reason__c` given; sessions already ended are left as they are. Returns the ones it ended.      |
| `endAllForAgents(Set<Id> registrationIds, String reason)`                                     | Ends every active session of the agents as Terminated. Used on deactivation.                                                                         |
| `closeStale(Integer maxRows)`                                                                 | Closes up to `maxRows` idle or over-long sessions, each at its last activity, and returns how many it closed. Called by the health check.            |

---

## AgentGovCircuitBreaker

`inherited sharing`. Reads go through `AgentGovSelector` and writes through `AgentGovDml`, both
in system mode, and every change to a breaker is made under a row lock on the registration.

- **CLOSED** admits every request. A failure adds one to `Failure_Count__c` and sets
  `Last_Failure__c`; at `Circuit_Breaker_Failure_Threshold__c` consecutive failures (5 by
  default) the breaker trips: it moves to OPEN, sets the agent's status to `Blocked`, sets
  `Cooldown_Until__c` one cooldown ahead (`Circuit_Breaker_Cooldown_Minutes__c`, 30 by
  default), and publishes an alert. A success clears the count and `Last_Failure__c`.
- **OPEN** refuses every request and ignores every outcome: no change to the count, no restart
  of the cooldown, no new alert. It leaves OPEN only once the cooldown has passed, when a
  request arrives (`allowRequest` moves it to HALF_OPEN and claims the probe) or the scheduled
  health check moves it to HALF_OPEN, or when someone resets it.
- **HALF_OPEN** sets the agent's status from `Blocked` to `Throttled` and admits a single probe
  request. A probe with no outcome within one cooldown is treated as abandoned, and the next
  request becomes the probe. A successful probe closes the breaker: the count goes to 0,
  `Last_Failure__c` is cleared, and the status returns to `Active`. A failed probe adds one to
  the count, sets `Last_Failure__c`, publishes an alert, and re-opens the breaker for twice the
  configured cooldown.

Every cooldown is capped at 1,440 minutes, and the doubling always applies to the configured
base, so it does not compound over repeated failed probes. A reset closes the breaker from any
state.

Outcomes come from three places in the framework: Log Agent Action (`Success` or `Failure`,
one outcome per agent per batch, with a `Failure` anywhere in the batch making it a failure;
`Denied` and `Throttled` count for nothing), the governed proxy (each request that runs), and
`POST /report` with `success`. None is recorded for a deactivated agent or while
`Is_Enabled__c` is unchecked, and Register Agent Action and `/authorize` record none, because
the work has not run yet. The methods below do not apply those rules themselves, and a trip
sets `Status__c` to `Blocked` whatever it was, so Apex that records outcomes directly must skip
deactivated agents and respect `Is_Enabled__c` as the framework's callers do.

| Method                                                               | Notes                                                                                                                                                                                                                         |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `allowRequest(Id registrationId)`                                    | Decides one request: `true` on a CLOSED breaker; on an OPEN one whose cooldown has passed, moves it to HALF_OPEN and claims the probe; on a HALF_OPEN one, claims the probe if none is outstanding. Throws `AGENT_NOT_FOUND`. |
| `allowRequests(Set<Id> registrationIds)`                             | Bulk form: one decision per agent, in one update. Ids that name no registration are absent from the result. Breakers that are not CLOSED are re-read under a lock.                                                            |
| `recordSuccess(Id registrationId)`                                   | HALF_OPEN → CLOSED, failures reset, status back to Active; on CLOSED clears the failure count. Ignored while OPEN.                                                                                                            |
| `recordFailure(Id registrationId)`                                   | Counts consecutive failures and trips at the threshold; a HALF_OPEN failure adds one and re-trips for twice the cooldown. Ignored while OPEN.                                                                                 |
| `recordOutcomes(Map<Id, Boolean> outcomes)`                          | Bulk form of the two above (`true` for a success), in one update. Ids that name no registration are ignored. A success for an agent last read as CLOSED with no failures changes nothing and takes no lock.                   |
| `getState(Id registrationId)`                                        | `CLOSED`, `OPEN`, or `HALF_OPEN`; an empty state reads as CLOSED. Throws `AGENT_NOT_FOUND`.                                                                                                                                   |
| `resetBreaker(Id registrationId)`                                    | Closes the breaker from any state: count, `Last_Failure__c`, cooldown and probe cleared, and a Blocked or Throttled agent back to Active. A deactivated agent stays Inactive. Throws `AGENT_NOT_FOUND`.                       |
| `resetBreakers(Set<Id> registrationIds)`                             | Bulk form, under a row lock. Returns the registrations found.                                                                                                                                                                 |
| `mayProbe(AgentGov_Registration__c registration)`                    | True when the breaker is HALF_OPEN, or OPEN with its cooldown served. Writes nothing; the REST and proxy status check uses it to let a Blocked agent reach the breaker.                                                       |
| `transitionToHalfOpen(List<AgentGov_Registration__c> registrations)` | Moves each row that is still OPEN with its cooldown served to HALF_OPEN, re-read under a lock, without claiming the probe. Used by the health check.                                                                          |

---

## AgentGovPolicyEngine

`inherited sharing`. Evaluates `AgentGov_Policy__mdt`, read through `AgentGovSelector` in
system mode so that a caller without access to the metadata cannot make policies disappear.

A policy applies to an agent when its `Agent_Type__c` names the agent's type by the stored
value (`MCP_External`) or the label shown on records (`MCP External`), in any letter case, or
is `All`; text that names no type matches no agent. Object and operation match in any letter
case, and `*` matches any. A policy with a blank object or operation is skipped. An explicit
deny beats any allow, and an operation no policy matches is allowed. Matching allow policies
contribute their field restrictions, which add up, and their record caps, of which the lowest
applies.

```apex
public class PolicyResult {
  public Boolean allowed;
  public String denialReason;
  public Integer maxRecords; // lowest cap among matching allow policies, or null
  public List<String> restrictedFields; // union of Field_Restrictions__c among matching allow policies
}
```

| Method                                                                    | Notes                                                                                                                                                                                                                                                                              |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `evaluatePolicy(Id registrationId, String objectName, String operation)`  | Returns an unrestricted allow while `Is_Enabled__c` is unchecked. Refuses, without throwing, an unknown agent (`Agent registration not found.`), a blank object, or a blank operation. A deny reads `Policy violation: Agent <name> is not authorized to <operation> on <object>.` |
| `isActionAllowed(Id registrationId, String objectName, String operation)` | Boolean convenience.                                                                                                                                                                                                                                                               |
| `allowAll()`                                                              | An unrestricted result: allowed, no field restrictions, no record cap.                                                                                                                                                                                                             |
| `assertFieldsAllowed(PolicyResult policy, Set<String> fieldNames)`        | Throws `POLICY_VIOLATION` naming every restricted field in the set, matched in any letter case.                                                                                                                                                                                    |
| `assertRecordCount(PolicyResult policy, Integer recordCount)`             | Throws `POLICY_VIOLATION` above `maxRecords`.                                                                                                                                                                                                                                      |
| `resolveAgentType(String named)`                                          | The stored agent type a policy's text names, `All`, or `null` when it names none.                                                                                                                                                                                                  |
| `appliesToAgentType(AgentGov_Policy__mdt policy, String agentType)`       | Whether the policy applies to agents of a stored type.                                                                                                                                                                                                                             |
| `validatePolicies()`                                                      | Lists configuration problems as text: a blank or unknown agent type, a blank object, and a blank or unknown operation, with names checked in any letter case. The console's Setup tab shows them.                                                                                  |

---

## AgentGovConflictResolver

`inherited sharing`. In-memory record claims for the current transaction, resolved by agent
priority (the lower number wins); conflict log rows are written through `AgentGovDml` in system
mode. Each REST or proxy request serves one agent, so in practice conflicts arise in a Register
Agent Action batch, or in Apex that runs several agents in one transaction. While
`Enable_Conflict_Detection__c` is unchecked, nothing is claimed or logged.

| Method                                                             | Notes                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `checkForConflict(Id agentId, String recordId, String objectName)` | Claims a free record for the agent. When another agent holds it, the one with the lower priority number takes it over and a tie leaves it with the holder; the clash, or an unknown agent on either side, is written to `AgentGov_Conflict_Log__c`. Returns a `ConflictResult` (`hasConflict`, `resolution`, `winningAgentId`, `message`). |
| `assertNoConflict(Id agentId, String recordId, String objectName)` | Throws `RECORD_LOCKED` when another agent keeps the record, including when either agent is unknown.                                                                                                                                                                                                                                        |
| `releaseRecord(Id agentId, String recordId, String objectName)`    | Releases the agent's claim.                                                                                                                                                                                                                                                                                                                |
| `isRecordLocked(String recordId, String objectName)`               | Whether any agent holds the record in this transaction.                                                                                                                                                                                                                                                                                    |
| `getLockHolder(String recordId, String objectName)`                | The holder's registration Id, or `null`.                                                                                                                                                                                                                                                                                                   |

Framework plumbing: `deferLogs()` and `flushLogs()` hold conflict log rows and write them in one
statement, for bulk callers.

---

## AgentGovContext

`inherited sharing`. Measures the SOQL queries, DML statements, and callouts an Apex agent
actually uses and charges them as SOQL queries, DML operations, and API calls. The charge and
the audit rows are written through `AgentGovBudgetManager` and `AgentGovTriggerHandler` in
system mode. Contexts nest: each agent is charged only for its own work, and the framework's
own bookkeeping is excluded from every enclosing context. No circuit breaker, policy, or
conflict check runs, and no breaker outcome is recorded. Each unit of work is recorded as one
`Apex` row with its measured usage, its own duration, and its outcome. While `Is_Enabled__c`
is unchecked, usage is measured and recorded but not charged.

| Method                                                      | Returns                              | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ----------------------------------------------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `startTracking(Id registrationId)`                          | `AgentGovContext`                    | Pushes a context. Throws `INVALID_INPUT` for a null Id and `AGENT_NOT_ACTIVE` for a deactivated agent; checks nothing else.                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `startTracking(Id registrationId, Id sessionId)`            | `AgentGovContext`                    | Same. The session Id is only returned by `getSessionId()`; usage is recorded against the agent's current session regardless.                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `stopTracking()`                                            | `AgentGovBudgetManager.BudgetResult` | Pops the innermost context and charges its measured usage; the `Apex` row is `Success`, or `Denied` when the charge is refused. Throws `INVALID_INPUT` when no context is active, `AGENT_NOT_FOUND` when the agent does not exist, and `BUDGET_EXCEEDED` when the charge leaves the budget Blocked or Exhausted. The charge and its row persist only if the caller catches the exception; otherwise the platform rolls them back with the transaction.                                                                                                                         |
| `executeGoverned(Id registrationId, AgentGovAction action)` | `AgentGovBudgetManager.BudgetResult` | Refuses as `startTracking` does before the action runs, then runs it under measurement and charges it as `stopTracking` does. If the action throws, its usage is still charged and its `Apex` row is a `Failure` carrying `<ExceptionType>: <message>`, followed by a note when the charge also took the agent over budget; then the action's own exception is rethrown unchanged. A `System` row is written only if the charge fails for another reason. If the caller lets the exception propagate, the charge and the row are rolled back with the rest of the transaction. |
| `getCurrentContext()`                                       | `AgentGovContext`                    | Innermost active context, or `null`. Triggers can use it to identify the acting agent.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `getRegistrationId()`, `getSessionId()`                     | `Id`                                 | Instance accessors.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |

The work goes in a class that implements `AgentGovContext.AgentGovAction`, whose one method is
`void execute()`:

```apex
public with sharing class LeadEnrichmentAgent {
  public static AgentGovBudgetManager.BudgetResult run(Id agentId) {
    return AgentGovContext.executeGoverned(agentId, new EnrichLeads());
  }

  private class EnrichLeads implements AgentGovContext.AgentGovAction {
    public void execute() {
      List<Lead> leads = [SELECT Id FROM Lead WHERE Status = 'Open - Not Contacted' LIMIT 100];
      for (Lead lead : leads) {
        lead.Status = 'Working - Contacted';
      }
      update leads;
    }
  }
}
```

---

## AgentGovRestAuth

`inherited sharing`. Resolves the calling agent for the REST resources. Reads go through
`AgentGovSelector` and the legacy key upgrade is written through `AgentGovDml`, both in system
mode.

| Method                                                                                                                                  | Notes                                                                                                                                                                                                                                                                           |
| --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `resolveRegistration(RestRequest request, Map<String, Object> body)`                                                                    | Header key (`X-AgentGov-Key`, or the legacy `X-AgentGov-API-Key`), then the deprecated body key, then the bound user. Upgrades legacy plaintext keys. Throws `AGENT_NOT_FOUND` when nothing resolves, or `ACCESS_DENIED` when a keyless user is bound to several registrations. |
| `requireActive(AgentGov_Registration__c registration, Boolean allowThrottled)`                                                          | Admits an Active agent, and a Throttled one when allowed; throws `AGENT_NOT_ACTIVE` otherwise. `/rotate-key` uses this form. Returns the registration.                                                                                                                          |
| `requireActive(AgentGov_Registration__c registration, Boolean allowThrottled, Boolean allowBlockedProbe)`                               | Also admits a Blocked agent when `allowBlockedProbe` is true. Governed calls pass true when `AgentGovCircuitBreaker.mayProbe` says a probe is due, or while governance is switched off.                                                                                         |
| `requireOwnerOrAdmin(AgentGov_Registration__c caller, Id targetRegistrationId)`                                                         | Throws `ACCESS_DENIED` unless the caller is the target or the running user holds `AgentGov_Admin_Access`. `caller` may be `null` for an administrator.                                                                                                                          |
| `hasAdminAccess()`                                                                                                                      | Whether the running user holds the `AgentGov_Admin_Access` custom permission.                                                                                                                                                                                                   |
| `generateKey()`, `hashKey(String apiKey)`, `keyPrefix(String apiKey)`, `applyKey(AgentGov_Registration__c registration, String apiKey)` | Key helpers: a new `agk_` key of 256 random bits, its SHA-256 digest in hex, its first 12 characters (`null` for a key shorter than 24), and `applyKey`, which sets the hash, prefix, and rotation time and clears `API_Key__c` without DML.                                    |
| `wasBodyKeyUsed()`                                                                                                                      | Whether the last resolution used the deprecated body credential.                                                                                                                                                                                                                |

Framework plumbing: `requireUsableKey(String apiKey)` throws `INVALID_INPUT` for a supplied key
shorter than 24 characters.

---

## AgentGovRestResponder

`inherited sharing`. Builds the REST envelope and reads the request values both REST resources
share. Its only write, the `System` row for an internal error, goes through
`AgentGovTriggerHandler` and `AgentGovDml` in system mode.

| Method                                                                                                  | Notes                                                                                                                                                                                       |
| ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `correlationId(RestRequest request)`                                                                    | The caller's `X-Correlation-Id`, its first 255 characters, or a generated UUID.                                                                                                             |
| `readString(Map<String, Object> body, String name)`                                                     | A text property of a parsed JSON body, or `null` when it is absent. Throws `INVALID_INPUT` (`<name> must be a JSON string.`) for any other JSON type.                                       |
| `success(RestResponse response, Integer statusCode, Map<String, Object> payload, String correlationId)` | Writes `success`, `correlationId`, and the payload, plus `deprecation` when the body key was used.                                                                                          |
| `error(RestResponse response, AgentGovException error, String correlationId)`                           | Writes the error envelope with the exception's HTTP status. For `INTERNAL_ERROR` it records the message as one `System` row under the correlation id and returns a generic message instead. |
| `notFound(RestResponse response, String path, String correlationId)`                                    | 404 `AGENT_NOT_FOUND` with `Endpoint not found: <path>`.                                                                                                                                    |
| `internalError(RestResponse response, Exception unexpected, String correlationId, Id registrationId)`   | Records the exception's type, message, and stack trace as one `System` row under the correlation id, linked to the agent when known, and writes a generic 500.                              |
| `remainingBudget(AgentGovBudgetManager.BudgetResult budget)`                                            | `apiCalls`, `soqlQueries`, and `dmlOperations` remaining, for a response payload.                                                                                                           |

---

## AgentGovQueryBuilder

`inherited sharing`. Compiles the proxy's structured query into SOQL with bind variables and
executes it with `AccessLevel.USER_MODE`, whatever the caller's sharing context. Its types are
`QueryRequest` (`objectName`, `fields`, `conditions`, `orderBy`, `limitCount`), `Condition`
(`field`, `operator`, `value`), `OrderBy` (`field`, `direction`), and `BuiltQuery` (`soql`,
`binds`, `referencedFields`, `describe`, `effectiveLimit`).

| Method                                                                                     | Notes                                                                                                                                                                                                                                                              |
| ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `parse(Map<String, Object> body)`                                                          | Validates the request shape and refuses a `query` property. Throws `INVALID_INPUT`.                                                                                                                                                                                |
| `describe(String objectName)`                                                              | Throws `INVALID_INPUT` for an unknown object.                                                                                                                                                                                                                      |
| `build(QueryRequest request, Schema.DescribeSObjectResult describe, Integer maxRecords)`   | Resolves every field and operator, refuses a condition on a field that cannot be filtered, a sort on a field that cannot be sorted, and `LIKE` on a field that does not hold a single text value, converts the values, and caps the limit. Throws `INVALID_INPUT`. |
| `applyRecordCap(BuiltQuery built, Integer maxRecords)`                                     | Lowers the limit to a record cap, such as a policy's. Never raises it, and never above 2,000.                                                                                                                                                                      |
| `assertReadable(BuiltQuery built)`                                                         | Throws `ACCESS_DENIED`, naming the object or the fields, when the running user may not read the object or a field the query selects, filters on, or sorts by. The proxy calls it before charging.                                                                  |
| `execute(BuiltQuery built)`                                                                | Runs `Database.queryWithBinds` in user mode. A query the database refuses throws `ACCESS_DENIED` when a fresh describe finds something the user may not read, and otherwise `INVALID_INPUT` (`The query on <object> could not be run as written. …`).              |
| `resolveField(String field, Map<String, Schema.SObjectField> fieldMap, String objectName)` | The field's API name as defined on the object. Throws `INVALID_INPUT` for a malformed or unknown name.                                                                                                                                                             |
| `convertFieldValue(Object rawValue, Schema.DisplayType fieldType)`                         | Converts a JSON value to the field's Apex type; a text-like field takes any scalar as text. Throws `INVALID_INPUT` for a JSON object or list, or a value the type cannot take. Shared with the proxy's write handlers.                                             |
| `typedList(List<Object> items, Schema.DisplayType fieldType)`                              | A typed list for an `IN` or `NOT IN` bind.                                                                                                                                                                                                                         |

---

## AgentGovSelector

`without sharing`, every query `WITH SYSTEM_MODE`. Reads the framework's own records and
metadata for the framework, whoever triggered the action, with per-transaction caching of
settings, metadata, and registrations. Not for presenting data to people; see
`AgentGovDashboardController`.

- **Settings and metadata**: `getSettings()` (framework defaults when no org-level record
  exists), `isFrameworkEnabled()`, `isRealTimeEventsEnabled()`, `getOrgTimeZone()`,
  `getLimitConfigs()`, `getLimitConfigByType(String)`, `getPolicies()`,
  `getPoliciesForAgentType(String)`.
- **Registrations**: `getRegistrationById(Id)`, `getRegistrationsByIds(Set<Id>)`,
  `getRegistrationsForUpdate(Set<Id>)` (row lock), `getRegistrationByApiKeyHash(String)`,
  `getRegistrationByLegacyApiKey(String)`, `getRegistrationIdsByAgentUser(Id)` (up to two,
  most recently modified first), `getRegistrationByAgentUser(Id)` (the most recently modified
  when a user is bound to several; REST refuses such a user rather than pick one),
  `cacheRegistration(AgentGov_Registration__c)`, `getActiveRegistrations()`,
  `getActiveAgentCount()`, `getOpenAgentsPastCooldown()`.
- **Budgets**: `getTodaysBudget(Id)`, `getTodaysBudgets(Set<Id>)`,
  `getTodaysBudgetForUpdate(Id)`, `getTodaysBudgetsForUpdate(Set<Id>)`.
- **Sessions**: `getActiveSession(Id)`, `getActiveSessionsByAgent(Set<Id>)`,
  `getActiveSessionsForUpdate(Set<Id>)`, `getAllActiveSessionsForUpdate(Set<Id>)`,
  `getSessionsForUpdate(Set<Id>)`, `getSessionById(Id)`,
  `getStaleSessions(DateTime, DateTime, Integer)`, and `getOrphanedSessions(Integer)`, which is
  kept for callers written against v1.2.
- **Other**: `getScheduledJobs(List<String>)`, `getRecentActionLogs(Id, Integer)`,
  `clearCache()`.

## AgentGovDml

`without sharing`, every DML statement in `AccessLevel.SYSTEM_MODE`; platform events are
published as the running user. The only place the framework writes its own records; nothing
done on an agent's behalf against customer data goes through it.

- `insertRecords(List<SObject>, Boolean allOrNone)`, `updateRecords(...)`, and
  `deleteRecords(...)` return the results; `insertRecord(SObject)` and `updateRecord(SObject)`
  throw on failure.
- `publishEvents(List<SObject>)` publishes as the running user. A user without Create on the
  event gets failed save results rather than an exception, and `AgentGovTriggerHandler` then
  writes the rows, or delivers the alerts, directly.
- `assertAllSucceeded(List<Database.SaveResult>, String context)` throws `INTERNAL_ERROR`
  describing the first failure.
- `isDuplicateValueFailure(Database.SaveResult)`, `isDuplicateValueFailure(DmlException)`,
  `isRejectedValueFailure(DmlException)`, and `describeErrors(List<Database.Error>)` classify
  and describe failures.

## AgentGovDashboardController

`with sharing`, every query `WITH USER_MODE`, and every method `@AuraEnabled(cacheable=true)`.
Read-only data for the console and the dashboards, showing each viewer only what they may see.

| Method                                                                                                                                                                     | Notes                                                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `getAllRegistrations()`                                                                                                                                                    | Every registration the viewer can see, by name, up to 2,000.                                                                                                                                                                                                                    |
| `getAllTodaysBudgets()`                                                                                                                                                    | Today's budget rows, by the org's calendar, up to 2,000.                                                                                                                                                                                                                        |
| `getRecentConflictLogs(Integer limitCount)`                                                                                                                                | Newest first; 50 by default, at most 200.                                                                                                                                                                                                                                       |
| `getTodaysActionCount()`                                                                                                                                                   | Action-log rows written since midnight in the org's time zone, leaving out `Alert` and `Admin` rows.                                                                                                                                                                            |
| `getActiveSessions()`                                                                                                                                                      | Live sessions only: active, used within the idle window, and under 24 hours old. Most recently active first, up to 200.                                                                                                                                                         |
| `getTrippedCircuitBreakerCount()`                                                                                                                                          | Agents whose breaker is OPEN.                                                                                                                                                                                                                                                   |
| `getAgentSummaries()`, `getAgentSummary(Id registrationId)`                                                                                                                | An `AgentSummary` per agent: status, breaker, today's usage, the agent's own live session, its key prefix and rotation time, `hasApiKey` (true also for a key with no stored prefix), and `boundToUser`. `getAgentSummary` returns `null` when the viewer cannot see the agent. |
| `getActionLogs(Id registrationId, String status, String actionType, Integer windowHours, String correlationId, DateTime beforeCreatedDate, Id beforeId, Integer pageSize)` | An `ActionLogPage` (`rows`, `hasMore`), filtered and paged on `CreatedDate` and `Id`; 50 rows by default, at most 200.                                                                                                                                                          |
| `getUsageHistory(Id registrationId, Integer days)`                                                                                                                         | One `UsageDay` per day, oldest first; 7 days by default, at most 90. Pass `null` for the whole org.                                                                                                                                                                             |
| `getRecentAlerts(Integer limitCount)`                                                                                                                                      | `Alert` rows, newest first; 10 by default, at most 100.                                                                                                                                                                                                                         |

A read the viewer lacks access for fails with an `AuraHandledException` that names the
permission set to ask for.

## AgentGovAdminController

`with sharing`, reads `WITH USER_MODE`. The console's actions:

| Method                                                              | Returns               | Notes                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `resetBreakers(List<Id> registrationIds)`                           | `List<ActionOutcome>` | Closes the breakers and reactivates the agents they had blocked.                                                                                                                                                                                                                                                                                                                                 |
| `activateAgents(List<Id> registrationIds)`                          | `List<ActionOutcome>` | Subject to the concurrent-agent limit. An agent already active is left as it is (`The agent was already active.`) and gets no audit row.                                                                                                                                                                                                                                                         |
| `deactivateAgents(List<Id> registrationIds)`                        | `List<ActionOutcome>` | Ends their sessions; each is refused at every governed entry point until it is activated again. An agent already inactive is left as it is and gets no audit row.                                                                                                                                                                                                                                |
| `endSessions(List<Id> sessionIds)`                                  | `List<ActionOutcome>` | The agents keep working, and their next governed call opens a new session. A session that had already ended is left as it is (`The session had already ended.`) and gets no audit row.                                                                                                                                                                                                           |
| `creditBudget(Id registrationId, String limitType, Integer amount)` | `ActionOutcome`       | Credits usage back to today's budget, today being the org's day. The outcome and the audit row say how much was actually credited: usage never goes below zero, so crediting 40 API calls to an agent that used 30 reads `Credited 30 API calls to today's budget, bringing its API call usage to zero.` When nothing of the limit type was used today, nothing changes and the outcome says so. |
| `rotateApiKey(Id registrationId)`                                   | `IssuedKey`           | Needs `AgentGov_Manage_Keys` rather than `AgentGov_Operate_Agents`. Returns the new key once; the audit row records only its prefix.                                                                                                                                                                                                                                                             |
| `scheduleJobs()`                                                    | `ActionOutcome`       | Runs `AgentGovJobScheduler.scheduleAll()`, so the jobs run as the current user, in that user's time zone.                                                                                                                                                                                                                                                                                        |
| `getSetupStatus()`                                                  | `SetupStatus`         | Cacheable. Whether governance and real-time events are on, whether an alert email is set, whether owners are notified, the session idle window in force, the jobs and their next runs, and the problems `AgentGovPolicyEngine.validatePolicies()` reports.                                                                                                                                       |

Every method checks `AgentGov_Operate_Agents` on the server first, or `AgentGov_Manage_Keys`
for `rotateApiKey`. The actions that take records accept at most 200 and read them in user
mode, so they act only on records the user can see, and every change is recorded as an `Admin`
action-log row in the same transaction, all or nothing. Operational failures are returned as
outcomes with `success = false`, as is a record the user cannot see
(`Not found, or you do not have access to it.`). A missing permission, an empty or oversized
selection, an invalid credit, or no access to the object at all throws an
`AuraHandledException`.

## AgentGovJobScheduler

`inherited sharing`. Schedules AgentGov's three background jobs with the documented
schedules; the job lookup goes through `AgentGovSelector`. Scheduling needs a user allowed to
schedule Apex, and the jobs run as that user, in that user's time zone.

| Method            | Returns           | Notes                                                                                                                                                                                                                          |
| ----------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `scheduleAll()`   | `List<Id>`        | Schedules the three jobs, replacing any already scheduled under the three AgentGov names; a copy scheduled under another name is left in place. Returns the new jobs' Ids. Schedule after a deploy, not before.                |
| `unscheduleAll()` | `Integer`         | Removes the jobs scheduled under the three AgentGov names and returns how many it removed. Before a deploy, run `scripts/setup/unschedule-jobs.apex` instead, which also finds copies under other names by the class they run. |
| `getJobStatus()`  | `List<JobStatus>` | Whether each job is scheduled, its cron expression, and its next run, in the documented order.                                                                                                                                 |

The jobs are `AgentGov Daily Reset` (`0 0 0 * * ?`, midnight), `AgentGov Health Check`
(`0 0 * * * ?`, hourly), and `AgentGov Cleanup` (`0 0 2 ? * SUN`, Sunday at 02:00).

## AgentGovRequestContext

`inherited sharing`; touches no data. The correlation id and start time of the current request,
for the audit trail. The REST and proxy endpoints call `begin(String)` with the caller's
`X-Correlation-Id`, and the console calls it with none, so an id is generated. The invocable
actions call `ensureBegun(String)` with the first Correlation ID input in their batch, so every
AgentGov action in one transaction uses the id of the first one that ran. `getCorrelationId()`
and `elapsedMs()` return `null` outside a request.

Rows written during a request carry its correlation id: the agent's action rows, which
`AgentGovTriggerHandler.buildEvent` also stamps with the time elapsed so far, `System` rows,
and the console's `Admin` rows. `Alert` rows carry no correlation id and no duration, and rows
written outside a request, by a scheduled job or by Apex that began none, carry no correlation
id.

## AgentGovTriggerHandler

`inherited sharing`. Writes the audit trail and delivers alerts; all writes go through
`AgentGovDml`, and the platform-event triggers that call it run in system mode by platform
rule.

| Method                                                                                                                                                      | Notes                                                                                                                                                                                                                                                                                                  |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `logAction(Id registrationId, String actionType, String objectName, String recordId, String status, String details)`                                        | Records one action. An overload adds `String errorMessage`.                                                                                                                                                                                                                                            |
| `buildEvent(Id registrationId, String agentName, String actionType, String objectName, String recordId, String status, String details)`                     | Builds an `AgentGov_Action_Event__e` without publishing it. It carries the request's correlation id, its elapsed time, and the agent's current session; a denial or failure also carries its reason as the row's error message.                                                                        |
| `logActions(List<AgentGov_Action_Event__e> events)`                                                                                                         | Records many actions with one publish. The rows are written directly instead while `Enable_Real_Time_Events__c` is unchecked or when the publish is refused. A row the database rejects, such as one whose action type is not in the picklist, is kept as a `System` row carrying the original values. |
| `publishAlerts(List<AgentGov_Alert__e> alerts)`                                                                                                             | Publishes alerts for the alert trigger to deliver, and does nothing while `Enable_Real_Time_Events__c` is unchecked. Alerts the publish refuses, as when the running user may not publish, are delivered at once through `handleAlerts`, and one `System` row notes the refusal.                       |
| `handleAlerts(List<AgentGov_Alert__e> alerts)`                                                                                                              | Records each alert as an `Alert` row, then emails the batch to `Admin_Notification_Email__c` and, when `Notify_Agent_Owners__c` is checked, to each owner, listing only that owner's agents.                                                                                                           |
| `recordFrameworkEvent(Id registrationId, String status, String details, String errorMessage)`                                                               | Writes one `System` row about the framework itself, best effort.                                                                                                                                                                                                                                       |
| `buildFrameworkEvent(Id registrationId, String status, String details, String errorMessage)`, `recordFrameworkEvents(List<AgentGov_Action_Log__c> entries)` | The same in bulk: build the rows, then insert them in one statement.                                                                                                                                                                                                                                   |

Framework plumbing: `handleActionEvents(...)`, `populateBudgetKeys(...)`, and
`populateSessionKeys(...)` are called by the triggers.

---

## REST resources

| Class              | URL mapping         | Notes                                                                                                                                                                            |
| ------------------ | ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AgentGovRestApi`  | `/agentgov/*`       | `global with sharing`. Touches no customer data; framework bookkeeping runs in system mode through the service classes. `doPost()` and `doGet()` route the governance endpoints. |
| `AgentGovProxyApi` | `/agentgov-proxy/*` | `global with sharing`. Every query and DML statement on the agent's behalf runs with `AccessLevel.USER_MODE`. `doPost()` routes the proxy endpoints.                             |

See the [REST API Reference](rest-api-reference.md) for the endpoints.

## Invocable actions

All five are `with sharing`, and their framework bookkeeping runs in system mode through the
service classes. All are bulk-safe: each method takes a list of requests and returns the
results in the same order. See the [Flow integration guide](flow-integration.md) for inputs and
outputs.

| Class                    | Method                          | Label                 | Notes                                                                                                                                                                                                                                                                                                                          |
| ------------------------ | ------------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `AgentGovRegisterAction` | `registerAction(List<Request>)` | Register Agent Action | Refuses a deactivated agent, then runs the circuit breaker, policy, conflicts within the batch, and budget; records no breaker outcome. An unrecognised or blank action type is refused and audited as a `Denied` `System` row linked to the agent, or, during the emergency bypass, authorized with a `System` `Success` row. |
| `AgentGovCheckBudget`    | `checkBudget(List<Request>)`    | Check Agent Budget    | Reads the budget and consumes nothing.                                                                                                                                                                                                                                                                                         |
| `AgentGovGetStatus`      | `getStatus(List<Request>)`      | Get Agent Status      | Status and circuit breaker state.                                                                                                                                                                                                                                                                                              |
| `AgentGovLogAction`      | `logAction(List<Request>)`      | Log Agent Action      | Audits each action; `Success` and `Failure` are breaker outcomes, one per agent per batch.                                                                                                                                                                                                                                     |
| `AgentGovReportUsage`    | `reportUsage(List<Request>)`    | Report Agent Usage    | Charges the usage reported; records no breaker outcome.                                                                                                                                                                                                                                                                        |

## Jobs

| Class                 | Type and sharing                                       | Purpose                                                                                                                                                                                                                                                                                                                                                   |
| --------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AgentGovDailyReset`  | `Schedulable`, `inherited sharing`                     | Creates today's budget for every Active agent through `AgentGovBudgetManager.resetDailyBudgets()`.                                                                                                                                                                                                                                                        |
| `AgentGovHealthCheck` | `Schedulable`, `inherited sharing`                     | Moves OPEN breakers whose cooldown has passed to HALF_OPEN, and closes idle and over-long sessions, up to 9,000 a run.                                                                                                                                                                                                                                    |
| `AgentGovCleanup`     | `Database.Batchable`, `Schedulable`, `without sharing` | Purges action logs, conflict logs, and finished sessions older than `Log_Retention_Days__c`, then budget rows older than `Budget_Retention_Days__c`, one object per chained batch run, each with a summary `System` row. Its queries run `WITH SYSTEM_MODE` and its deletes go through `AgentGovDml`, so the purge covers every row whoever scheduled it. |

The no-argument constructor reads the retention settings when the job runs, and
`AgentGovCleanup(Integer retentionDays)` overrides the log retention. To purge at once, run
`Database.executeBatch(new AgentGovCleanup(), 2000);`.

## AgentGovSampleData

`with sharing`. Demonstration data for a new org. Its plain SOQL and DML run in user mode at
this API version, so the administrator who runs it from anonymous Apex needs `AgentGov_Admin`.
`scripts/setup/load-sample-data.apex` calls `createAll()`.

| Method               | Returns   | Notes                                                                                                                                                                                                                                                                                        |
| -------------------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `createAll()`        | `String`  | Creates settings when none exist, five agents with the fixed keys in `SAMPLE_API_KEYS`, today's budgets, sessions, action logs, alerts, and conflicts. Returns a one-line summary, or a message that the sample data is already loaded.                                                      |
| `deleteSampleData()` | `Integer` | Deletes the sample agents, found by their keys, and their rows; an agent whose key was rotated is no longer found. A run removes at most 1,500 rows of each kind and removes the agents only once none of their rows remain, so run it until it returns 0. Returns the rows the run removed. |
| `deleteAll()`        | `Integer` | Deletes every AgentGov row in the org, at most 1,500 of each object per run; run it until it returns 0.                                                                                                                                                                                      |

---

## AgentGovException

Touches no data and needs no sharing declaration. Carries an `ErrorCode`, which REST callers
receive with the HTTP status it maps to; the invocable actions return only the message to Flow.

| Member                                              | Notes                                                                                                                                                                                                                                               |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AgentGovException(ErrorCode code, String message)` | The message must be safe to return to a caller.                                                                                                                                                                                                     |
| `getErrorCode()`                                    | The code, or `null` for an exception created without one, such as `new AgentGovException('message')`.                                                                                                                                               |
| `getHttpStatusCode()`                               | 400 `INVALID_INPUT`; 403 `AGENT_NOT_ACTIVE`, `ACCESS_DENIED`, `POLICY_VIOLATION`; 404 `AGENT_NOT_FOUND`; 409 `RECORD_LOCKED`; 429 `BUDGET_EXCEEDED`, `MAX_CONCURRENT_AGENTS`; 503 `CIRCUIT_BREAKER_OPEN`; 500 for `INTERNAL_ERROR` and for no code. |

`ErrorCode` values a caller can actually receive: `AGENT_NOT_FOUND`, `AGENT_NOT_ACTIVE`,
`ACCESS_DENIED`, `BUDGET_EXCEEDED`, `CIRCUIT_BREAKER_OPEN`, `POLICY_VIOLATION`,
`RECORD_LOCKED`, `MAX_CONCURRENT_AGENTS`, `INVALID_INPUT`, `INTERNAL_ERROR`.

The enum also declares `FRAMEWORK_DISABLED`, `AGENT_BLOCKED`, and `BUDGET_THROTTLED`. Nothing
constructs them: a disabled framework allows the request rather than refusing it; over REST and
the proxy an agent its breaker left Blocked is refused as `AGENT_NOT_ACTIVE`, and a Blocked or
Exhausted budget as `BUDGET_EXCEEDED`; a Throttled agent passes the status check, and its
HALF_OPEN breaker admits one probe and refuses the rest with `CIRCUIT_BREAKER_OPEN`; and a
Throttled budget is not refused at all. They are kept so that code which already switches on
the enum keeps compiling, and are candidates for removal in a future major version. Do not
write code that waits for them.

## AgentGovConstants

Picklist values, defaults, REST contract strings, and error messages; touches no data and needs
no sharing declaration.

Added in v1.3:

- **Sessions**: the `End_Reason__c` values `SESSION_END_IDLE`, `SESSION_END_MAX_DURATION`,
  `SESSION_END_CALLER`, `SESSION_END_ADMINISTRATOR`, and `SESSION_END_DEACTIVATED`;
  `MAX_SESSION_HOURS` (24), `DEFAULT_SESSION_IDLE_MINUTES` (30), `MAX_SESSION_IDLE_MINUTES`
  (1440), `MAX_SESSIONS_CLOSED_PER_RUN` (9000), and `LAST_ACTIVE_REFRESH_SECONDS` (60).
- **Action log**: the action types `ACTION_ALERT`, `ACTION_APEX`, and `ACTION_ADMIN`, and the
  alert wording `ALERT_LABELS`, `ALERT_LABEL_BREAKER_OPEN`, and `LIMIT_LABELS`.
- **Console**: `CUSTOM_PERMISSION_OPERATE_AGENTS`, `CUSTOM_PERMISSION_MANAGE_KEYS`, and
  `MAX_ADMIN_BATCH` (200).
- **Jobs and retention**: `JOB_DAILY_RESET`, `JOB_HEALTH_CHECK`, `JOB_CLEANUP`,
  `CRON_DAILY_RESET`, `CRON_HEALTH_CHECK`, `CRON_CLEANUP`, and `DEFAULT_BUDGET_RETENTION_DAYS`
  (400).
- **Messages**: `ERR_AMBIGUOUS_AGENT_USER`, `ERR_NEGATIVE_USAGE`, `ERR_OBJECT_NOT_ACCESSIBLE`,
  `ERR_REGISTRATION_INVALID_VALUE`, `ERR_NOT_A_STRING`, `ERR_DUPLICATE_RECORD_ID`,
  `ERR_TOO_MANY_RECORDS`, `ERR_FIELD_NOT_FILTERABLE`, `ERR_FIELD_NOT_SORTABLE`,
  `ERR_LIKE_NOT_TEXT`, `ERR_VALUE_NOT_SCALAR`, `ERR_FIELD_NOT_SETTABLE`, `ERR_QUERY_NOT_RUN`,
  `ERR_KEY_ROTATION_REFUSED`, and the console's `ERR_OPERATE_PERMISSION`,
  `ERR_MANAGE_KEYS_PERMISSION`, `ERR_ADMIN_BATCH_TOO_LARGE`, `ERR_NOTHING_SELECTED`,
  `ERR_NO_RECORD_ACCESS`, and `ERR_INVALID_CREDIT`.

Legacy names, kept so that code written against earlier releases compiles:

- `ORPHAN_SESSION_HOURS` is the v1.2 name of `MAX_SESSION_HOURS`, with the same value.
- `REST_HEADER_API_KEY_LEGACY` is the legacy header name `X-AgentGov-API-Key`, still accepted
  as an alias of `REST_HEADER_API_KEY` (`X-AgentGov-Key`).

---

## Test support

`AgentGovTestDataFactory` is an `@IsTest` class, usable only from test code. It builds every
framework record, and `createRestrictedUser(List<String> permissionSetNames)` creates a user
with the Minimum Access profile and the given permission sets, for proving that code works
without access to AgentGov objects.
