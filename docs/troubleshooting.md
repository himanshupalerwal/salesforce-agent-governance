# Troubleshooting

Common issues and their solutions when working with AgentGov.

---

## "Agent not registered" Errors

### Symptom

REST API returns `404` with error code `AGENT_NOT_FOUND`, or Apex throws `AgentGovException` with the same code.

### Causes and Solutions

**Cause 1: Agent was never registered.**

```apex
// Verify the agent exists
AgentGov_Registration__c agent = AgentGovRegistryService.getAgent(agentId);
System.debug(agent); // null means not registered
```

**Cause 2: No credential resolved.** REST calls identify the agent by the `X-AgentGov-Key` header, the deprecated `apiKey` body property, or the user bound through `Agent_User__c`. Keys are stored only as hashes, so you cannot read a stored key back; compare prefixes instead:

```apex
AgentGov_Registration__c agent = [
    SELECT Id, API_Key_Prefix__c, API_Key_Last_Rotated__c, Agent_User__c
    FROM AgentGov_Registration__c
    WHERE Id = :agentId
];
System.debug('Key prefix: ' + agent.API_Key_Prefix__c + ', bound user: ' + agent.Agent_User__c);
```

If the key is lost, issue a new one with `AgentGovRegistryService.issueApiKey(agentId)` or **Rotate key** on the agent's record page, which needs the AgentGov Manage Keys permission. `POST /rotate-key` works only for an agent that can still authenticate, by its current key or its bound user.

**Cause 3: The OAuth user cannot reach the endpoint.** The user the token belongs to needs the **AgentGov_Agent** permission set (class access to the REST resources). It does not need access to AgentGov objects; the framework records its bookkeeping in system mode.

---

## "Agent is not in Active status" Errors

### Symptom

A REST or proxy call returns error code `AGENT_NOT_ACTIVE`, `AgentGovContext.startTracking` throws it, or a Flow action refuses with `Agent is not in Active status.` (as Register Agent Action's Denial Reason or Report Agent Usage's Error Message).

### Solution

Agents are created in `Inactive` status. You must explicitly activate them:

```apex
AgentGovRegistryService.activateAgent(agentId);
```

Check current status:

```apex
AgentGov_Registration__c agent = AgentGovRegistryService.getAgent(agentId);
System.debug('Status: ' + agent.Status__c);
// Possible values: Active, Inactive, Throttled, Blocked
```

If the agent is `Blocked`, its circuit breaker tripped, and REST and the proxy refuse it until the cooldown ends. `Throttled` means the breaker is half-open. Only the circuit breaker sets these two statuses; budget limits never change an agent's status. See the "Circuit Breaker Stuck in OPEN" section below.

---

## Budget Not Resetting

### Symptom

Agent runs out of budget and does not recover the next day.

### How a new day starts

Each day's budget row is created by the agent's first governed call that day, with or without the `AgentGovDailyReset` job. The job only creates the rows at midnight so that they show on the console before agents start work. Days follow the org's default time zone (Setup → Company Information), not the calling user's.

### Causes and Solutions

**Cause 1: The day has not turned in the org's time zone.** An allocation renews at the org's midnight, which can be hours away from the caller's. Check the day the framework is charging:

```apex
System.debug('Budget day: ' + AgentGovBudgetManager.budgetDate());
```

**Cause 2: The refusal is not about the budget.** Only `BUDGET_EXCEEDED` is a budget refusal. `CIRCUIT_BREAKER_OPEN` and `AGENT_NOT_ACTIVE` come from the circuit breaker or the agent's status, which a new day does not reset; see the sections on those.

**Cause 3: The daily allocation is smaller than a day's work.** Raise the agent's `Daily_API_Budget__c`, `Daily_SOQL_Budget__c`, or `Daily_DML_Budget__c`. To let an agent finish today, use **Credit budget** on the console, which gives back usage on today's row and records who did it.

---

## Circuit Breaker Stuck in OPEN

### Symptom

Agent is blocked and the circuit breaker is not transitioning to HALF_OPEN even after the cooldown period.

### Causes and Solutions

**Cause 1: Health check job not scheduled, and the agent has not called since the cooldown.**
The `AgentGovHealthCheck` job moves OPEN breakers to HALF_OPEN once their cooldown expires. Without it, a breaker moves only when the agent next calls. Schedule the jobs with `sf apex run --file scripts/setup/schedule-jobs.apex`, or **Schedule jobs** on the console's Setup tab.

**Cause 2: Cooldown has not actually elapsed.** Check the cooldown timestamp:

```apex
AgentGov_Registration__c agent = AgentGovRegistryService.getAgent(agentId);
System.debug('Cooldown until: ' + agent.Cooldown_Until__c);
System.debug('Current time:   ' + DateTime.now());
System.debug('CB State:       ' + agent.Circuit_Breaker_State__c);
```

Remember: a failed probe reopens the breaker for twice the configured cooldown, at most one day. The longer cooldown does not compound over repeated failed probes.

**Cause 3: The breaker is HALF_OPEN and the probe is outstanding.** Only one request is admitted while HALF_OPEN; others are denied until that probe reports an outcome or one cooldown period passes (`Half_Open_Probe_At__c` shows when it was admitted). If no requests reach the agent at all, the OPEN → HALF_OPEN transition happens through the health check job.

**Manual Reset:** use **Reset breaker** on the console, which records who reset it, or from Apex:

```apex
AgentGovCircuitBreaker.resetBreaker(agentId);
System.debug('Circuit breaker manually reset to CLOSED');
```

---

## Platform Event Delivery Issues

### Symptom

Alerts and action events are not appearing in subscribers (LWC, Streaming API, etc.).

### Causes and Solutions

**Cause 1: Real-time events are disabled.**

```apex
AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
System.debug('Events enabled: ' + settings.Enable_Real_Time_Events__c);
```

Set to `true` if disabled:

```apex
settings.Enable_Real_Time_Events__c = true;
upsert settings;
```

**Cause 2: Event delivery limits.** Salesforce has limits on platform event delivery. Check Setup > Platform Events > Event Delivery for usage.

**Cause 3: Subscriber not configured correctly.** For Streaming API, verify you are subscribing to the correct channel:

- Alerts: `/event/AgentGov_Alert__e`
- Actions: `/event/AgentGov_Action_Event__e`

**Cause 4: Transaction rollback.** Both AgentGov events are declared `PublishAfterCommit`, so they are delivered only once the publishing transaction commits. If that transaction rolls back, for example because of a later DML exception, the event is never delivered and no log row is written for it. Check the calling code for an exception after the publish.

---

## Permission Errors

### Symptom

`INSUFFICIENT_ACCESS` or `FIELD_NOT_ACCESSIBLE` errors when calling AgentGov methods.

### Solution

Which access is needed depends on who is calling:

- **The user an agent runs as** needs only the **AgentGov_Agent** permission set. Framework bookkeeping runs in system mode, so no access to AgentGov objects is required. Access to the _customer data_ the agent works with is separate and is enforced in user mode by the proxy: an `ACCESS_DENIED` response names the object or fields the user cannot reach.
- **People using the dashboards** need **AgentGov_User** (read-only) or **AgentGov_Admin**. The dashboard controller runs in user mode and reports the missing permission set in its error message.
- **On-call staff** who reset breakers, pause agents, end sessions, and credit budgets from the console need **AgentGov_User** plus **AgentGov_Responder**. Responder grants the AgentGov Operate Agents permission but not AgentGov Manage Keys, so key rotation stays with administrators. A console action attempted without the permission fails with `You need the AgentGov Operate Agents permission to do this.` or `You need the AgentGov Manage Keys permission to rotate API keys.`
- **Administrators** need **AgentGov_Admin**, or the **AgentGov_Operators** group.

```bash
sf org assign permset --name AgentGov_Admin --target-org your-org
```

---

## "Maximum concurrent agent limit reached" Error

### Symptom

Error code `MAX_CONCURRENT_AGENTS` when activating an agent.

### Solution

The org has reached the configured limit for simultaneous Active agents.

Check current active count:

```apex
Integer activeCount = [SELECT COUNT() FROM AgentGov_Registration__c WHERE Status__c = 'Active'];
System.debug('Active agents: ' + activeCount);

AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
System.debug('Max allowed: ' + settings.Max_Concurrent_Agents__c);
```

Options:

1. Deactivate agents that are no longer needed
2. Increase the `Max_Concurrent_Agents__c` setting

---

## Budget Consumption Not Tracking Correctly

### Symptom

Budget numbers seem off or do not match expected usage.

### Causes and Solutions

**Cause 1: The budget status is driven by another limit type.** A budget's status is the most severe status across API calls, SOQL queries, and DML operations. An agent that has exhausted its DML budget is denied SOQL as well; the denial message names the limit type responsible.

**Cause 2: Denied attempts are recorded.** Consumption that crosses the block or exhaustion line is written before the denial is returned, so a Blocked agent that keeps retrying shows consumption above its allocation. This is intentional: the ledger records attempts.

Duplicate budget rows for one agent and day cannot exist since v1.2; `Budget_Key__c` is unique and concurrent first-of-day requests are serialized on it.

---

## Framework is Not Enforcing Anything

### Symptom

All actions are allowed regardless of policies, budgets, or circuit breaker state.

### Solution

Check if the framework is enabled:

```apex
System.debug('Framework enabled: ' + AgentGovSelector.isFrameworkEnabled());

AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
System.debug('Is_Enabled__c: ' + settings.Is_Enabled__c);
```

When no settings record exists the framework defaults to enabled. When `Is_Enabled__c` is explicitly `false`, the circuit breaker, policy engine, budget consumption and conflict detection are bypassed and actions are allowed, with two exceptions: a deactivated agent is still refused everywhere, and over REST and the proxy an agent that its circuit breaker left `Blocked` is refused until the cooldown ends. Auditing continues throughout, so the action log still shows what ran during the bypass.

Also verify Custom Settings exist:

```apex
AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
System.debug('Settings ID: ' + settings.Id);
// If Id is null, no org-level record exists -- create one
```

---

## "Internal error. Quote the correlationId" Responses

### Symptom

A REST call returns HTTP 500 with `errorCode` `INTERNAL_ERROR` and a `correlationId`.

### Solution

The request's writes and budget charges were undone, so retrying it cannot create anything twice. The exception details are never returned to the caller. They are written to the action log as a `System` entry. Look it up by the correlation id:

```apex
List<AgentGov_Action_Log__c> entries = [
    SELECT Details__c, Error_Message__c, Timestamp__c
    FROM AgentGov_Action_Log__c
    WHERE Action_Type__c = 'System' AND Correlation_Id__c = '<correlationId>'
];
```

The console's Activity tab finds the same rows: paste the id into **Correlation id**.

`Error_Message__c` holds the exception type, message, and stack trace. `System` entries also record alert delivery failures, session counter failures, and purge summaries, so reviewing them periodically is worthwhile.

---

## Deployment Fails While Scheduled Jobs Exist

### Symptom

`sf project deploy start` fails on many Apex classes at once with a message ending "You can
bypass this error by allowing deployments with Apex jobs in the Deployment Settings page in
Setup."

### Cause

Salesforce will not replace an Apex class that a scheduled job holds a reference to. The
three AgentGov jobs refer to most of the framework, so scheduling them makes later upgrades
fail until you clear them.

### Solution

Either tick **Allow deployments of components when corresponding Apex jobs are pending or
in progress** in Setup → Deployment Settings, or remove the jobs, deploy, and schedule them
again:

```bash
sf apex run --file scripts/setup/unschedule-jobs.apex --target-org <alias>
sf project deploy start --source-dir force-app --target-org <alias>
sf apex run --file scripts/setup/schedule-jobs.apex --target-org <alias>
```

The unschedule script is self-contained, so it works whichever AgentGov version is installed.
It also removes copies scheduled under other names, which block the deploy just the same, and
its log lists every job it removed so that you can recreate your own copies afterwards.

The framework keeps working while the jobs are cancelled. Budgets are created on first use
and circuit breakers recover when an agent next calls; only the daily reset, the hourly
health check, and the weekly purge pause.
