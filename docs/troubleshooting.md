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

**Cause 3: API key mismatch.** The `/authorize` endpoint looks up agents by `apiKey`, not by ID. Verify the API key matches exactly:
```apex
// Check what API key is stored
AgentGov_Registration__c agent = [
    SELECT Id, API_Key__c FROM AgentGov_Registration__c WHERE Id = :agentId
];
System.debug('Stored API key: ' + agent.API_Key__c);
```

**Cause 4: Field-Level Security.** The integration user's profile or permission set must have read access to all AgentGov_Registration__c fields. All queries use `WITH SECURITY_ENFORCED`, which throws an error if FLS is not granted.

Solution: Assign the **AgentGov_User** or **AgentGov_Admin** permission set to the integration user.

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

**Cause 2: Job failed silently.** Check the Apex Jobs page in Setup for failures. The `resetDailyBudgets` method uses `Database.insert(newBudgets, false)` which allows partial success -- check debug logs for errors.

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

Remember: exponential backoff doubles the cooldown on each re-trip. After 3 trips with a 30-minute base, the cooldown is 120 minutes (30 -> 60 -> 120).

**Cause 3: The `allowRequest()` method also transitions to HALF_OPEN.** If no requests are being made to the agent, the transition only happens via the health check scheduled job.

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

**Cause 4: Transaction rollback.** If the transaction that fires the event is rolled back (e.g., due to a DML exception after the event was published), the event may not be delivered. AgentGov uses `EventBus.publish()` which commits independently, but verify your calling code does not have outer transaction issues.

---

## Permission Errors

### Symptom
`INSUFFICIENT_ACCESS` or `FIELD_NOT_ACCESSIBLE` errors when calling AgentGov methods.

### Solution

AgentGov uses `WITH SECURITY_ENFORCED` on all SOQL queries and `with sharing` on all classes. The running user must have:

1. **Object-level access** to all AgentGov custom objects (Registration, Session, Budget, Action Log, Conflict Log)
2. **Field-level access** to all fields on those objects
3. **Read access** to Custom Metadata Types (Limit Config, Policy)
4. **Create/Edit access** to Platform Events (Alert, Action Event)

Assign the appropriate permission set:
- **AgentGov_Admin**: Full CRUD on all objects
- **AgentGov_User**: Read access to registrations/budgets, execute invocable actions

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

**Cause 1: Multiple budget records for the same day.** This can happen if `createDailyBudget` is called manually while the auto-creation logic also runs. Check:
```apex
List<AgentGov_Budget__c> todaysBudgets = [
    SELECT Id, Budget_Date__c, API_Calls_Consumed__c
    FROM AgentGov_Budget__c
    WHERE Agent_Registration__c = :agentId
    AND Budget_Date__c = TODAY
];
System.debug('Budget records for today: ' + todaysBudgets.size());
```
There should be exactly one. Delete duplicates if found.

**Cause 2: Race condition.** Budget consumption uses `FOR UPDATE` to lock the record, but if two calls happen in separate transactions before the budget record exists, two records may be created. The framework handles this by checking and creating atomically, but extremely high concurrency can cause edge cases.

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

If `Is_Enabled__c` is `false` or the settings record does not exist, the framework defaults to enabled but the `evaluatePolicy` method will skip checks if the flag is explicitly false.

Also verify Custom Settings exist:
```apex
AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
System.debug('Settings ID: ' + settings.Id);
// If Id is null, no org-level record exists -- create one
```
