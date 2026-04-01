# Configuration Guide

This guide provides a complete reference for configuring AgentGov, including Custom Settings, Custom Metadata Types, and common configuration patterns.

---

## AgentGov_Settings__c (Custom Settings)

AgentGov uses a **Hierarchy Custom Setting** for org-level configuration. This allows different values at the org, profile, and user levels.

### Accessing Settings

**Setup UI:** Setup > Custom Settings > AgentGov Settings > Manage

**Apex:**
```apex
AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
```

### Field Reference

| Field API Name | Type | Default | Description |
|----------------|------|---------|-------------|
| `Is_Enabled__c` | Checkbox | `true` | Master kill switch. When unchecked, the entire governance framework is bypassed and all actions are allowed without checks. Useful during data migrations or emergency situations. |
| `Default_Agent_Priority__c` | Number(2,0) | `5` | Default priority assigned to newly registered agents. Priority is used for conflict resolution -- lower numbers mean higher priority. Range: 1 (highest) to 10 (lowest). |
| `Max_Concurrent_Agents__c` | Number(4,0) | `10` | Maximum number of agents that can be in Active status simultaneously. Prevents overwhelming the org with too many concurrent agents. Attempts to activate beyond this limit throw an error. |
| `Circuit_Breaker_Failure_Threshold__c` | Number(3,0) | `5` | Number of consecutive failures before an agent's circuit breaker trips from CLOSED to OPEN. |
| `Circuit_Breaker_Cooldown_Minutes__c` | Number(4,0) | `30` | Minutes an agent remains in OPEN state before transitioning to HALF_OPEN for a test request. Doubles on each re-trip (exponential backoff). |
| `Log_Retention_Days__c` | Number(4,0) | `90` | Number of days to retain Action Log records. The AgentGovCleanup batch job deletes records older than this. |
| `Enable_Conflict_Detection__c` | Checkbox | `true` | Enables in-memory record locking and priority-based conflict detection. When disabled, `checkForConflict()` always returns no conflict. |
| `Enable_Real_Time_Events__c` | Checkbox | `true` | Enables publishing of Platform Events (AgentGov_Alert__e and AgentGov_Action_Event__e). Disable if you do not need real-time monitoring and want to reduce event bus usage. |

### Example: Emergency Bypass

To temporarily disable all governance checks (e.g., during a data migration):

```apex
AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
settings.Is_Enabled__c = false;
upsert settings;
// All governance checks are now bypassed
```

Remember to re-enable after the migration:

```apex
AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
settings.Is_Enabled__c = true;
upsert settings;
```

---

## AgentGov_Limit_Config__mdt (Custom Metadata Type)

Defines threshold configurations for each type of governor limit. These thresholds determine when budget alerts fire and when agents get throttled or blocked.

### Accessing Configurations

**Setup UI:** Setup > Custom Metadata Types > AgentGov Limit Config > Manage Records

**Apex:**
```apex
List<AgentGov_Limit_Config__mdt> configs = AgentGovSelector.getLimitConfigs();
AgentGov_Limit_Config__mdt apiConfig = AgentGovSelector.getLimitConfigByType('API_Calls');
```

### Field Reference

| Field API Name | Type | Description |
|----------------|------|-------------|
| `Limit_Type__c` | Text(50) | The type of limit: `API_Calls`, `SOQL_Queries`, or `DML_Operations` |
| `Warning_Threshold__c` | Number(5,2) | Percentage at which a Warning alert is fired. Default: 80. |
| `Throttle_Threshold__c` | Number(5,2) | Percentage at which the agent is throttled and a Throttle alert fires. Default: 90. |
| `Block_Threshold__c` | Number(5,2) | Percentage at which the agent is blocked and further requests are denied. Default: 95. |
| `Default_Daily_Budget__c` | Number(10,0) | Default daily budget allocation for this limit type. Overridden by per-agent values on AgentGov_Registration__c. |
| `Is_Active__c` | Checkbox | Whether this configuration is active. Inactive configs are ignored. |

### Recommended Configuration

Create three records:

**API_Calls_Config:**
```
Label:              API Calls Config
Limit Type:         API_Calls
Warning Threshold:  80
Throttle Threshold: 90
Block Threshold:    95
Default Daily Budget: 10000
Is Active:          true
```

**SOQL_Queries_Config:**
```
Label:              SOQL Queries Config
Limit Type:         SOQL_Queries
Warning Threshold:  80
Throttle Threshold: 90
Block Threshold:    95
Default Daily Budget: 5000
Is Active:          true
```

**DML_Operations_Config:**
```
Label:              DML Operations Config
Limit Type:         DML_Operations
Warning Threshold:  80
Throttle Threshold: 90
Block Threshold:    95
Default Daily Budget: 3000
Is Active:          true
```

### Example: Aggressive Throttling for API Calls

If API calls are your scarcest resource, lower the thresholds:

```
Limit Type:         API_Calls
Warning Threshold:  60
Throttle Threshold: 75
Block Threshold:    85
```

This starts warning at 60% usage and blocks at 85%, giving you more headroom before hitting actual Salesforce limits.

---

## AgentGov_Policy__mdt (Custom Metadata Type)

Defines access control policies that determine what each agent type can do. Policies are evaluated by the `AgentGovPolicyEngine` before any action is authorized.

### Accessing Policies

**Setup UI:** Setup > Custom Metadata Types > AgentGov Policy > Manage Records

**Apex:**
```apex
List<AgentGov_Policy__mdt> policies = AgentGovSelector.getPolicies();
List<AgentGov_Policy__mdt> agentforcePolicies =
    AgentGovSelector.getPoliciesForAgentType('Agentforce');
```

### Field Reference

| Field API Name | Type | Description |
|----------------|------|-------------|
| `Agent_Type__c` | Text(50) | Agent type: `Agentforce`, `MCP_External`, `Custom_Apex`, `Flow_Based`, or `All` |
| `Object_Name__c` | Text(100) | Salesforce object API name (e.g., `Lead`, `Case`, `Account`) or `*` for all objects |
| `Operation__c` | Text(50) | Operation: `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`, `Flow_Trigger`, or `*` for all operations |
| `Is_Allowed__c` | Checkbox | `true` = allow, `false` = deny. **Explicit deny always overrides allow.** |
| `Field_Restrictions__c` | Long Text | Comma-separated list of field API names that are restricted (e.g., `SSN__c,CreditCard__c`) |
| `Max_Records_Per_Transaction__c` | Number(6,0) | Maximum records the agent can process in a single transaction. If multiple policies match, the lowest value wins. |
| `Description__c` | Long Text | Human-readable description of the policy's purpose |

### Policy Evaluation Rules

1. Policies are matched by `Agent_Type__c` (exact match or `All`).
2. Within matching policies, `Object_Name__c` and `Operation__c` are checked (exact match or `*` wildcard).
3. **Explicit deny overrides explicit allow.** If any matching policy has `Is_Allowed__c = false`, the action is denied.
4. If no policies match, the action is **allowed by default**.
5. Field restrictions and max records are collected from all matching allow policies.

### Common Policy Patterns

#### Allow Agentforce agents to read anything but only write to specific objects

```
Record 1: Agentforce_Read_All
  Agent Type:  Agentforce
  Object:      *
  Operation:   Query
  Is Allowed:  true

Record 2: Agentforce_Write_Lead
  Agent Type:  Agentforce
  Object:      Lead
  Operation:   *
  Is Allowed:  true

Record 3: Agentforce_Write_Case
  Agent Type:  Agentforce
  Object:      Case
  Operation:   *
  Is Allowed:  true
```

#### Block external MCP agents from deleting any records

```
Record: MCP_No_Delete
  Agent Type:  MCP_External
  Object:      *
  Operation:   Delete
  Is Allowed:  false
  Description: External agents must never delete records
```

#### Restrict sensitive fields for all agent types

```
Record: All_Restrict_PII
  Agent Type:  All
  Object:      Contact
  Operation:   *
  Is Allowed:  true
  Field Restrictions: SSN__c, Date_of_Birth__c, CreditCard__c
  Description: Restrict PII fields for all agent types
```

#### Limit transaction size for Flow-based agents

```
Record: Flow_Limit_Batch
  Agent Type:  Flow_Based
  Object:      *
  Operation:   *
  Is Allowed:  true
  Max Records Per Transaction: 200
  Description: Flow agents limited to 200 records per transaction
```

---

## Per-Agent Configuration

Beyond the org-level metadata, each agent has individual configuration on the `AgentGov_Registration__c` record:

| Field | Description |
|-------|-------------|
| `Priority__c` | Agent priority for conflict resolution (1 = highest, 10 = lowest) |
| `Daily_API_Budget__c` | Daily API call budget (overrides metadata default) |
| `Daily_SOQL_Budget__c` | Daily SOQL query budget (overrides metadata default) |
| `Daily_DML_Budget__c` | Daily DML operation budget (overrides metadata default) |

To give a critical agent a larger budget:

```apex
AgentGov_Registration__c agent = AgentGovRegistryService.getAgent(agentId);
agent.Daily_API_Budget__c = 50000;    // 5x the default
agent.Daily_SOQL_Budget__c = 25000;
agent.Daily_DML_Budget__c = 15000;
agent.Priority__c = 1;                // Highest priority
update agent;
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
- Blank Object_Name__c
- Blank Operation__c
- Invalid operation values (not in the valid set and not a wildcard)
