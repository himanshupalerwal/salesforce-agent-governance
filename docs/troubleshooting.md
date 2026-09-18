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

**Cause 2: Wrong ID format.** Ensure you are using the 18-character Salesforce ID, not a 15-character ID in REST calls.

**Cause 3: No credential resolved.** REST calls identify the agent by the `X-AgentGov-Key` header, the deprecated `apiKey` body property, or the user bound through `Agent_User__c`. Keys are stored only as hashes, so you cannot read a stored key back; compare prefixes instead:

```apex
AgentGov_Registration__c agent = [
    SELECT Id, API_Key_Prefix__c, API_Key_Last_Rotated__c, Agent_User__c
    FROM AgentGov_Registration__c
    WHERE Id = :agentId
];
System.debug('Key prefix: ' + agent.API_Key_Prefix__c + ', bound user: ' + agent.Agent_User__c);
```

If the key is lost, issue a new one with `AgentGovRegistryService.issueApiKey(agentId)` or `POST /rotate-key`.

**Cause 4: The OAuth user cannot reach the endpoint.** The user the token belongs to needs the **AgentGov_Agent** permission set (class access to the REST resources). It does not need access to AgentGov objects; the framework records its bookkeeping in system mode.

---

## "Agent is not in Active status" Errors

### Symptom

Error code `AGENT_NOT_ACTIVE` when calling `/authorize` or starting a session.

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

If the agent is `Blocked`, it was disabled by the circuit breaker. See the "Circuit Breaker Stuck in OPEN" section below.

---

## Budget Not Resetting

### Symptom

Agent runs out of budget and does not recover the next day.

### Causes and Solutions

**Cause 1: Scheduled job not configured.**
The `AgentGovDailyReset` job must be scheduled to run at midnight:

```apex
System.schedule('AgentGov Daily Reset', '0 0 0 * * ?', new AgentGovDailyReset());
```

Verify it is scheduled:

```apex
List<CronTrigger> jobs = [
    SELECT Id, CronJobDetail.Name, State, NextFireTime
    FROM CronTrigger
    WHERE CronJobDetail.Name = 'AgentGov Daily Reset'
];
System.debug(jobs);
```

**Cause 2: Job failed.** Check the Apex Jobs page in Setup. The reset raises an exception for any failure other than a row that already exists, so a failed run is visible there.

**Cause 3: Agent is not Active.** Budget reset only creates records for Active agents. If the agent was deactivated before midnight, it will not get a new budget.

**Workaround:** Manually create a budget for today:

```apex
AgentGovBudgetManager.createDailyBudget(agentId);
```

---

## Circuit Breaker Stuck in OPEN

### Symptom

Agent is blocked and the circuit breaker is not transitioning to HALF_OPEN even after the cooldown period.

### Causes and Solutions

**Cause 1: Health check job not scheduled.**
The `AgentGovHealthCheck` job transitions OPEN breakers to HALF_OPEN when their cooldown expires:

```apex
System.schedule('AgentGov Health Check', '0 0 * * * ?', new AgentGovHealthCheck());
```

**Cause 2: Cooldown has not actually elapsed.** Check the cooldown timestamp:

```apex
AgentGov_Registration__c agent = AgentGovRegistryService.getAgent(agentId);
System.debug('Cooldown until: ' + agent.Cooldown_Until__c);
System.debug('Current time:   ' + DateTime.now());
System.debug('CB State:       ' + agent.Circuit_Breaker_State__c);
```

Remember: a failed probe doubles the cooldown, capped at one day.

**Cause 3: The breaker is HALF_OPEN and the probe is outstanding.** Only one request is admitted while HALF_OPEN; others are denied until that probe reports an outcome or one cooldown period passes (`Half_Open_Probe_At__c` shows when it was admitted). If no requests reach the agent at all, the OPEN → HALF_OPEN transition happens through the health check job.

**Manual Reset:**

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

When no settings record exists the framework defaults to enabled. When `Is_Enabled__c` is explicitly `false`, the circuit breaker, policy engine, budget consumption and conflict detection are all bypassed and every action is allowed. Auditing continues throughout, so the action log still shows what ran during the bypass.

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

The exception details are never returned to the caller. They are written to the action log as a `System` entry. Look it up by the correlation id:

```apex
List<AgentGov_Action_Log__c> entries = [
    SELECT Details__c, Error_Message__c, Timestamp__c
    FROM AgentGov_Action_Log__c
    WHERE Action_Type__c = 'System' AND Details__c LIKE '%<correlationId>%'
];
```

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
in progress** in Setup → Deployment Settings, or cancel the jobs, deploy, and schedule them
again:

```apex
for (CronTrigger t : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE 'AgentGov%']) {
    System.abortJob(t.Id);
}
```

The framework keeps working while the jobs are cancelled. Budgets are created on first use
and circuit breakers recover when an agent next calls; only the daily reset, the hourly
health check, and the weekly purge pause.
