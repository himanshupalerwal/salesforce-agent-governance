# Configuration Guide

This guide provides a complete reference for configuring AgentGov, including Custom Settings, Custom Metadata Types, and common configuration patterns.

---

## AgentGov_Settings__c (Custom Settings)

AgentGov uses a **Hierarchy Custom Setting** for org-level configuration. The framework reads only the organization-level defaults (`getOrgDefaults()`); values entered for a profile or a user are ignored.

### Accessing Settings

**Setup UI:** Setup > Custom Settings > AgentGov Settings > Manage

**Apex:**

```apex
AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
```

### Field Reference

| Field API Name                         | Type        | Default | Description                                                                                                                                                                                                                                                                                                                                                                                               |
| -------------------------------------- | ----------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Is_Enabled__c`                        | Checkbox    | `true`  | Governance on or off. When unchecked, every entry point (REST, the proxy, the Flow actions, and `AgentGovContext`) skips the circuit breaker, policy, budget, and conflict checks and charges nothing. Every action is allowed and audited, except that a deactivated agent is still refused. This is an emergency bypass for data migrations, not a way to stop agents. To stop an agent, deactivate it. |
| `Default_Agent_Priority__c`            | Number(2,0) | `5`     | Default priority assigned to newly registered agents. Priority decides record conflicts: the lower number wins. 1 (highest) to 10 (lowest) is a convention, not an enforced range; the field accepts any whole number of up to two digits.                                                                                                                                                                |
| `Max_Concurrent_Agents__c`             | Number(3,0) | `10`    | Maximum number of agents in Active status. It is checked when an agent is activated: activating beyond the limit throws an error. An agent that returns to Active when its tripped breaker closes is not checked, so the count can briefly exceed the limit.                                                                                                                                              |
| `Circuit_Breaker_Failure_Threshold__c` | Number(3,0) | `5`     | Number of consecutive failures before an agent's circuit breaker trips from CLOSED to OPEN.                                                                                                                                                                                                                                                                                                               |
| `Circuit_Breaker_Cooldown_Minutes__c`  | Number(5,0) | `30`    | Minutes an agent remains in OPEN state before a single probe request is admitted. A failed probe reopens the breaker for twice this value; it does not keep doubling on later failures. Every cooldown is capped at one day (1,440 minutes).                                                                                                                                                              |
| `Log_Retention_Days__c`                | Number(4,0) | `90`    | Days to keep action logs, conflict logs, and finished sessions. The AgentGovCleanup job deletes older rows, one object after another.                                                                                                                                                                                                                                                                     |
| `Budget_Retention_Days__c`             | Number(4,0) | `400`   | Days of daily budget rows to keep. They are the source of the console's usage history, so they are kept longer than logs by default.                                                                                                                                                                                                                                                                      |
| `Session_Idle_Minutes__c`              | Number(4,0) | `30`    | Minutes without governed activity after which an agent's session closes. The agent's next governed call opens a new session. Values outside 1 to 1440 fall back to 30.                                                                                                                                                                                                                                    |
| `Notify_Agent_Owners__c`               | Checkbox    | `false` | Email each affected agent's `Owner_Email__c` about its alerts, listing only that owner's agents, whether or not `Admin_Notification_Email__c` is set. Sent in the same single send as the administrator email.                                                                                                                                                                                            |
| `Enable_Conflict_Detection__c`         | Checkbox    | `true`  | Enables priority-based conflict detection between agents that claim the same record in one transaction, such as one Register Agent Action batch. When disabled, `checkForConflict()` always returns no conflict.                                                                                                                                                                                          |
| `Enable_Real_Time_Events__c`           | Checkbox    | `true`  | Enables publishing of Platform Events (AgentGov_Alert__e and AgentGov_Action_Event__e). When disabled, action logs are inserted directly and no alerts or emails are sent.                                                                                                                                                                                                                                |
| `Admin_Notification_Email__c`          | Email       | (none)  | Address that receives one email per delivered batch of alerts (budget thresholds, circuit breaker trips). Leave blank and no administrator email is sent; agent owners are still emailed when `Notify_Agent_Owners__c` is checked. Every alert is also recorded as an `Alert` row in the action log either way.                                                                                           |

### Example: Emergency Bypass

To suspend enforcement temporarily, for example during a data migration:

```apex
AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
settings.Is_Enabled__c = false;
upsert settings;
// Breaker, policy, budget and conflict checks are now skipped and nothing is charged.
// Every action is allowed and audited, except that deactivated agents are still refused.
```

Remember to re-enable after the migration:

```apex
AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
settings.Is_Enabled__c = true;
upsert settings;
```

---

## AgentGov_Limit_Config__mdt (Custom Metadata Type)

Defines threshold configurations for each type of governor limit. These thresholds set an agent's budget status for the day, which decides when budget alerts fire and when requests are denied. A Warning or Throttled status only raises an alert; requests are still allowed until the status reaches Blocked or Exhausted (100% used).

### Accessing Configurations

**Setup UI:** Setup > Custom Metadata Types > AgentGov Limit Config > Manage Records

**Apex:**

```apex
List<AgentGov_Limit_Config__mdt> configs = AgentGovSelector.getLimitConfigs();
AgentGov_Limit_Config__mdt apiConfig = AgentGovSelector.getLimitConfigByType('API_Calls');
```

### Field Reference

| Field API Name            | Type         | Description                                                                                                                                                |
| ------------------------- | ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Limit_Type__c`           | Text(100)    | The type of limit: `API_Calls`, `SOQL_Queries`, or `DML_Operations`                                                                                        |
| `Warning_Threshold__c`    | Number(3,0)  | Whole percentage at which the budget status becomes Warning and a Warning alert fires. Default: 80.                                                        |
| `Throttle_Threshold__c`   | Number(3,0)  | Whole percentage at which the budget status becomes Throttled and a Throttle alert fires. Requests are still allowed. Default: 90.                         |
| `Block_Threshold__c`      | Number(3,0)  | Whole percentage at which the budget status becomes Blocked, a Block alert fires, and further requests are denied. Default: 95.                            |
| `Default_Daily_Budget__c` | Number(10,0) | Default daily budget allocation for this limit type. Overridden by per-agent values on AgentGov_Registration__c.                                           |
| `Is_Active__c`            | Checkbox     | Whether this configuration is active. Inactive configs are ignored; with no active record for a type, built-in defaults equal to the shipped values apply. |

### Shipped Records

Three records ship with the framework, one per limit type, with these values. Edit them rather than creating new ones, and keep exactly one active record per limit type: the framework uses the first active record it finds for a type, in no defined order, so a second active record for the same type makes the values it applies arbitrary.

**API_Calls:**

```
Label:                API Calls
Limit Type:           API_Calls
Warning Threshold:    80
Throttle Threshold:   90
Block Threshold:      95
Default Daily Budget: 10000
Is Active:            true
```

**SOQL_Queries:**

```
Label:                SOQL Queries
Limit Type:           SOQL_Queries
Warning Threshold:    80
Throttle Threshold:   90
Block Threshold:      95
Default Daily Budget: 5000
Is Active:            true
```

**DML_Operations:**

```
Label:                DML Operations
Limit Type:           DML_Operations
Warning Threshold:    80
Throttle Threshold:   90
Block Threshold:      95
Default Daily Budget: 3000
Is Active:            true
```

### Example: Tighter Thresholds for API Calls

If API calls are your scarcest resource, lower the thresholds on the shipped `API_Calls` record:

```
Limit Type:         API_Calls
Warning Threshold:  60
Throttle Threshold: 75
Block Threshold:    85
```

This starts warning at 60% usage and blocks at 85%, giving you more headroom before hitting actual Salesforce limits.

---

## AgentGov_Policy__mdt (Custom Metadata Type)

Defines access control policies that determine what each agent type can do. Policies are evaluated by the `AgentGovPolicyEngine` when the proxy, REST `/authorize`, or Register Agent Action authorizes an action, and are skipped while `Is_Enabled__c` is unchecked.

### Accessing Policies

**Setup UI:** Setup > Custom Metadata Types > AgentGov Policy > Manage Records

**Apex:**

```apex
List<AgentGov_Policy__mdt> policies = AgentGovSelector.getPolicies();
List<AgentGov_Policy__mdt> agentforcePolicies =
    AgentGovSelector.getPoliciesForAgentType('Agentforce');
```

### Field Reference

| Field API Name                   | Type         | Description                                                                                                                                                                                          |
| -------------------------------- | ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Agent_Type__c`                  | Text(100)    | Agent type: the stored value (`Agentforce`, `MCP_External`, `Custom_Apex`, `Flow_Based`) or the label shown on records (MCP External, Custom Apex, Flow Based), in any letter case, or `All`         |
| `Object_Name__c`                 | Text(255)    | Salesforce object API name (e.g., `Lead`, `Case`, `Account`) or `*` for all objects                                                                                                                  |
| `Operation__c`                   | Text(100)    | Operation: `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`, `Flow_Trigger`, or `*` for all operations                                                                                    |
| `Is_Allowed__c`                  | Checkbox     | `true` = allow, `false` = deny. **Explicit deny always overrides allow.**                                                                                                                            |
| `Field_Restrictions__c`          | Long Text    | Comma-separated list of field API names the agent may neither read nor write through the proxy (e.g., `SSN__c,CreditCard__c`). A request that names one is denied, not trimmed.                      |
| `Max_Records_Per_Transaction__c` | Number(10,0) | Maximum records per proxy request, and the cap on `/query` results: a larger `/query` limit is reduced to it, and a larger write is denied. If multiple allow policies match, the lowest value wins. |
| `Description__c`                 | Long Text    | Human-readable description of the policy's purpose                                                                                                                                                   |

### Policy Evaluation Rules

1. Policies are matched by `Agent_Type__c`, against the registration's stored agent type (`MCP_External`) or its label (`MCP External`), in any letter case, or `All` for every type. Text that names no agent type matches no agent, and the policy validation below reports it.
2. Within matching policies, `Object_Name__c` and `Operation__c` are checked, in any letter case, or match anything with the `*` wildcard.
3. **Explicit deny overrides explicit allow.** If any matching policy has `Is_Allowed__c = false`, the action is denied, even when an allow policy also matches.
4. If no policies match, the action is **allowed by default**.
5. Field restrictions and max records are collected from all matching allow policies, and only requests made through the proxy are held to them. Register Agent Action and `/authorize` use only the allow or deny decision. Apex that calls `AgentGovPolicyEngine.evaluatePolicy` directly can enforce them with `AgentGovPolicyEngine.assertFieldsAllowed` and `assertRecordCount`.
6. `Operation__c` must be one of the action types, in any letter case (`Query` or `query`, not `Read`); `AgentGovPolicyEngine.validatePolicies()` reports anything else.

Rules 3 and 4 make policies default-allow and deny-wins. An allow policy never refuses an action, so it cannot restrict an agent on its own, and an allow list ("only these objects") cannot be expressed. Restrict an agent type with deny policies for the objects and operations it must not use.

### Common Policy Patterns

#### Stop Agentforce agents from deleting records or changing Opportunities

Allow records cannot say "write only to Lead and Case": an action that no policy matches is allowed, and a wildcard deny for writes would refuse Lead and Case too, because a deny wins over any allow. Name what must be refused instead, with deny records for the objects and operations involved.

```
Record 1: Agentforce_No_Delete
  Agent Type:  Agentforce
  Object:      *
  Operation:   Delete
  Is Allowed:  false
  Description: Agentforce agents never delete records

Record 2: Agentforce_No_Opportunity_Create
  Agent Type:  Agentforce
  Object:      Opportunity
  Operation:   Create
  Is Allowed:  false

Record 3: Agentforce_No_Opportunity_Update
  Agent Type:  Agentforce
  Object:      Opportunity
  Operation:   Update
  Is Allowed:  false

Record 4: Agentforce_No_Opportunity_Upsert
  Agent Type:  Agentforce
  Object:      Opportunity
  Operation:   Upsert
  Is Allowed:  false
```

Agentforce agents can still query every object, Opportunity included, and write to every other object. Denying Opportunity with the operation `*` would refuse queries as well, because no allow policy can override a deny.

#### Block external MCP agents from deleting any records

```
Record: MCP_No_Delete
  Agent Type:  MCP_External
  Object:      *
  Operation:   Delete
  Is Allowed:  false
  Description: External agents must never delete records
```

#### Keep sensitive fields out of proxy requests

```
Record: All_Restrict_PII
  Agent Type:  All
  Object:      Contact
  Operation:   *
  Is Allowed:  true
  Field Restrictions: SSN__c, Date_of_Birth__c, CreditCard__c
  Description: Proxy requests may not read or write PII fields on Contact
```

A proxy request from any agent type that reads or writes one of these Contact fields is denied. Field restrictions apply only to requests made through the proxy: Register Agent Action and `/authorize` use only the allow or deny decision, so agents that act through the Flow actions or their own code are not limited by this record. Being an allow policy, it refuses nothing else.

#### Cap the size of proxy requests from external agents

```
Record: MCP_Limit_Batch
  Agent Type:  MCP_External
  Object:      *
  Operation:   *
  Is Allowed:  true
  Max Records Per Transaction: 200
  Description: External agents touch at most 200 records per proxy request
```

A proxy write with more than 200 records is denied with `POLICY_VIOLATION`, and a `/query` limit above 200 is reduced to 200. Record caps apply only to requests made through the proxy, so this kind of record does not limit Flow-based agents that use the Flow actions.

---

## Per-Agent Configuration

Beyond the org-level metadata, each agent has individual configuration on the `AgentGov_Registration__c` record:

| Field                                          | Description                                                                                                                                                                                                             |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Priority__c`                                  | Agent priority for conflict resolution; the lower number wins. 1 (highest) to 10 (lowest) is a convention, not an enforced range                                                                                        |
| `Daily_API_Budget__c`                          | Daily API call budget (overrides metadata default)                                                                                                                                                                      |
| `Daily_SOQL_Budget__c`                         | Daily SOQL query budget (overrides metadata default)                                                                                                                                                                    |
| `Daily_DML_Budget__c`                          | Daily DML operation budget (overrides metadata default)                                                                                                                                                                 |
| `Agent_User__c`                                | The Salesforce user the agent runs as. REST and proxy calls by that user need no key while this is the only registration bound to the user; a user bound to several registrations must send the `X-AgentGov-Key` header |
| `API_Key_Prefix__c`, `API_Key_Last_Rotated__c` | Read-only view of the current key (the key itself is stored only as a hash)                                                                                                                                             |

To give a critical agent a larger budget, raise its allocations. A day's budget row copies the agent's allocations when the row is created, so new values apply from the next budget day, which starts at midnight in the org's default time zone. Today's row keeps the allocations it was created with.

```apex
AgentGov_Registration__c agent = AgentGovRegistryService.getAgent(agentId);
agent.Daily_API_Budget__c = 50000;    // 5x the default, from the next budget day
agent.Daily_SOQL_Budget__c = 25000;
agent.Daily_DML_Budget__c = 15000;
agent.Priority__c = 1;                // Wins record conflicts against any agent with a larger number
update agent;
```

To give an agent more room today, credit its budget with **Credit budget** in the console or with `AgentGovBudgetManager.creditBudget`. A credit lowers today's recorded usage of one limit type, never below zero, and re-evaluates the budget status, so a Blocked budget can return to a lower status. The console action also records an `Admin` row in the action log.

```apex
AgentGovBudgetManager.creditBudget(agentId, AgentGovConstants.LIMIT_API_CALLS, 5000);
```

---

## Validating Configuration

The Policy Engine includes a validation method that checks all policy metadata records for common issues:

```apex
List<String> issues = AgentGovPolicyEngine.validatePolicies();
if (!issues.isEmpty()) {
    for (String issue : issues) {
        System.debug('Policy issue: ' + issue);
    }
} else {
    System.debug('All policies are valid.');
}
```

This checks for:

- Blank Agent_Type__c, or one that names no agent type (neither a stored value, a label, nor `All`)
- Blank Object_Name__c
- Blank Operation__c
- Invalid operation values (not in the valid set and not a wildcard)
