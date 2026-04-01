# Architecture Overview

This document describes the architecture of the AgentGov framework, including system context, component design, data model, and request lifecycle.

---

## System Context

```mermaid
C4Context
    title AgentGov System Context

    Person(admin, "Salesforce Admin", "Configures agents, policies, and limits")
    Person(dev, "Developer", "Builds agents and integrations")

    System(agentgov, "AgentGov Framework", "Salesforce-native governance for AI agents")

    System_Ext(agentforce, "Agentforce", "Salesforce native AI agents")
    System_Ext(mcp, "MCP Server", "External AI model via MCP protocol")
    System_Ext(external, "External System", "Third-party APIs and services")

    Rel(admin, agentgov, "Configures via Setup UI")
    Rel(dev, agentgov, "Integrates via Apex / REST")
    Rel(agentforce, agentgov, "Registers actions via Apex / Invocable")
    Rel(mcp, agentgov, "Registers actions via REST API")
    Rel(agentgov, external, "Monitors callouts to")
```

---

## Component Diagram

```mermaid
flowchart TB
    subgraph EntryPoints["Entry Points"]
        REST["AgentGovRestApi\n(REST Resource)"]
        INV["Invocable Actions\n(Flow Integration)"]
        APEX["Direct Apex\n(Custom Code)"]
    end

    subgraph CoreServices["Core Services"]
        REG["AgentGovRegistryService\nAgent registration, activation,\nsession management"]
        BM["AgentGovBudgetManager\nBudget allocation, consumption,\nthreshold alerts"]
        CB["AgentGovCircuitBreaker\nHealth monitoring,\nfailure tracking, auto-disable"]
        PE["AgentGovPolicyEngine\nAccess control evaluation,\nfield restrictions"]
        CR["AgentGovConflictResolver\nRecord locking,\npriority-based resolution"]
    end

    subgraph DataLayer["Data Access Layer"]
        SEL["AgentGovSelector\nCentralized SOQL,\ncaching, security enforcement"]
    end

    subgraph BackgroundJobs["Background Jobs"]
        DR["AgentGovDailyReset\n(Schedulable)"]
        HC["AgentGovHealthCheck\n(Schedulable)"]
        CL["AgentGovCleanup\n(Batchable)"]
    end

    subgraph SharedInfra["Shared Infrastructure"]
        CONST["AgentGovConstants\nAll constants and\nerror messages"]
        EX["AgentGovException\nTyped error codes\nwith HTTP mappings"]
        TH["AgentGovTriggerHandler\nAction logging"]
    end

    REST --> REG
    REST --> BM
    REST --> CB
    REST --> PE
    REST --> CR

    INV --> REG
    INV --> BM
    INV --> CB
    INV --> PE

    APEX --> REG
    APEX --> BM
    APEX --> CB
    APEX --> PE
    APEX --> CR

    REG --> SEL
    BM --> SEL
    CB --> SEL
    PE --> SEL
    CR --> SEL

    DR --> BM
    HC --> SEL
    CL --> SEL

    REG -.-> CONST
    BM -.-> CONST
    CB -.-> CONST
    PE -.-> CONST
    CR -.-> CONST
```

### Component Responsibilities

| Component | Responsibility |
|-----------|---------------|
| **AgentGovRegistryService** | Agent CRUD, activation/deactivation, session lifecycle |
| **AgentGovBudgetManager** | Daily budget creation, consumption tracking, threshold alerts via platform events |
| **AgentGovCircuitBreaker** | CLOSED/OPEN/HALF_OPEN state machine, failure counting, cooldown with exponential backoff |
| **AgentGovPolicyEngine** | Metadata-driven policy evaluation, wildcard matching, field restrictions |
| **AgentGovConflictResolver** | In-memory record locking, priority-based conflict resolution, conflict logging |
| **AgentGovSelector** | All SOQL queries, per-transaction caching, `WITH SECURITY_ENFORCED` |
| **AgentGovRestApi** | REST endpoints for external agent integration |
| **AgentGovConstants** | Centralized string literals, default values, valid type sets |
| **AgentGovException** | Typed exceptions with error codes mapped to HTTP status codes |

---

## Data Model

```mermaid
erDiagram
    AgentGov_Registration__c {
        Id Id PK
        String Agent_Name__c
        String Agent_Type__c
        String Status__c
        String Description__c
        String API_Key__c
        String Owner_Email__c
        Decimal Priority__c
        Decimal Daily_API_Budget__c
        Decimal Daily_SOQL_Budget__c
        Decimal Daily_DML_Budget__c
        String Circuit_Breaker_State__c
        Decimal Failure_Count__c
        DateTime Last_Failure__c
        DateTime Cooldown_Until__c
        DateTime Last_Active__c
    }

    AgentGov_Session__c {
        Id Id PK
        Id Agent_Registration__c FK
        DateTime Session_Start__c
        DateTime Session_End__c
        String Status__c
        Decimal API_Calls_Used__c
        Decimal SOQL_Queries_Used__c
        Decimal DML_Statements_Used__c
        Decimal Actions_Count__c
    }

    AgentGov_Budget__c {
        Id Id PK
        Id Agent_Registration__c FK
        Date Budget_Date__c
        Decimal API_Calls_Allocated__c
        Decimal API_Calls_Consumed__c
        Decimal SOQL_Queries_Allocated__c
        Decimal SOQL_Queries_Consumed__c
        Decimal DML_Operations_Allocated__c
        Decimal DML_Operations_Consumed__c
        String Budget_Status__c
    }

    AgentGov_Action_Log__c {
        Id Id PK
        Id Agent_Registration__c FK
        String Action_Type__c
        String Object_Name__c
        String Record_Id__c
        String Status__c
        String Error_Message__c
        Decimal Execution_Time_Ms__c
        DateTime Timestamp__c
    }

    AgentGov_Conflict_Log__c {
        Id Id PK
        Id Agent_1__c FK
        Id Agent_2__c FK
        String Record_Id__c
        String Object_Name__c
        String Conflict_Type__c
        String Resolution__c
        String Severity__c
        DateTime Timestamp__c
        String Details__c
    }

    AgentGov_Settings__c {
        Boolean Is_Enabled__c
        Decimal Default_Agent_Priority__c
        Decimal Max_Concurrent_Agents__c
        Decimal Circuit_Breaker_Failure_Threshold__c
        Decimal Circuit_Breaker_Cooldown_Minutes__c
        Decimal Log_Retention_Days__c
        Boolean Enable_Conflict_Detection__c
        Boolean Enable_Real_Time_Events__c
    }

    AgentGov_Limit_Config__mdt {
        String Limit_Type__c
        Decimal Warning_Threshold__c
        Decimal Throttle_Threshold__c
        Decimal Block_Threshold__c
        Decimal Default_Daily_Budget__c
        Boolean Is_Active__c
    }

    AgentGov_Policy__mdt {
        String Agent_Type__c
        String Object_Name__c
        String Operation__c
        Boolean Is_Allowed__c
        String Field_Restrictions__c
        Decimal Max_Records_Per_Transaction__c
        String Description__c
    }

    AgentGov_Registration__c ||--o{ AgentGov_Session__c : "has sessions"
    AgentGov_Registration__c ||--o{ AgentGov_Budget__c : "has budgets"
    AgentGov_Registration__c ||--o{ AgentGov_Action_Log__c : "has action logs"
    AgentGov_Registration__c ||--o{ AgentGov_Conflict_Log__c : "involved in conflicts"
```

### Relationships

- **Registration to Session**: One-to-many. Each agent can have many sessions over time, but only one active session at a time.
- **Registration to Budget**: One-to-many. One budget record per agent per day.
- **Registration to Action Log**: One-to-many. Every action performed by an agent creates a log record.
- **Registration to Conflict Log**: Many-to-many via Agent_1__c and Agent_2__c lookup fields.

---

## Request Lifecycle Sequence Diagram

```mermaid
sequenceDiagram
    participant Agent as AI Agent
    participant REST as AgentGovRestApi
    participant CB as CircuitBreaker
    participant PE as PolicyEngine
    participant BM as BudgetManager
    participant CR as ConflictResolver
    participant SEL as Selector
    participant EVT as Platform Events

    Agent->>REST: POST /authorize (apiKey, object, operation, recordId)
    REST->>SEL: getRegistrationByApiKey(apiKey)
    SEL-->>REST: Registration record

    alt Agent not found or not active
        REST-->>Agent: 403/404 Error
    end

    REST->>CB: allowRequest(agentId)
    CB->>SEL: getRegistrationById(agentId)
    SEL-->>CB: Registration (with CB state)

    alt Circuit Breaker OPEN
        CB-->>REST: false
        REST-->>Agent: 503 Circuit Breaker Open
    end

    CB-->>REST: true

    REST->>PE: evaluatePolicy(agentId, object, operation)
    PE->>SEL: getPoliciesForAgentType(type)
    SEL-->>PE: Matching policies

    alt Policy Violation
        PE-->>REST: {allowed: false, reason: "..."}
        REST->>EVT: Publish Action Event (DENIED)
        REST-->>Agent: 403 Policy Violation
    end

    PE-->>REST: {allowed: true}

    REST->>BM: consumeBudget(agentId, limitType, 1)
    BM->>SEL: getTodaysBudgetForUpdate(agentId)
    SEL-->>BM: Budget record (locked)
    BM->>BM: Calculate usage percentage

    alt Budget Exceeded
        BM->>EVT: Publish Alert (BLOCK)
        BM-->>REST: AgentGovException
        REST-->>Agent: 429 Budget Exceeded
    end

    BM-->>REST: BudgetResult

    REST->>CR: checkForConflict(agentId, recordId, object)
    CR->>CR: Check in-memory lock table

    alt Record Locked by Higher Priority
        CR->>CR: Log conflict
        CR-->>REST: {hasConflict: true, winner: otherAgent}
        REST-->>Agent: 409 Record Locked
    end

    CR-->>REST: {hasConflict: false}

    REST->>EVT: Publish Action Event (SUCCESS)
    REST-->>Agent: 200 {authorized: true, budget: {...}}
```

---

## Circuit Breaker State Machine

```mermaid
stateDiagram-v2
    [*] --> CLOSED

    CLOSED --> CLOSED : recordSuccess()
    CLOSED --> CLOSED : recordFailure() [count < threshold]
    CLOSED --> OPEN : recordFailure() [count >= threshold]

    OPEN --> OPEN : allowRequest() → false
    OPEN --> HALF_OPEN : allowRequest() [cooldown elapsed]

    HALF_OPEN --> CLOSED : recordSuccess() → reset failures
    HALF_OPEN --> OPEN : recordFailure() → 2x cooldown

    note right of CLOSED
        Normal operation.
        Failure count tracked.
        All requests pass through.
    end note

    note right of OPEN
        Agent blocked.
        Status set to Blocked.
        Cooldown timer running.
    end note

    note left of HALF_OPEN
        One test request allowed.
        Status set to Throttled.
        Success closes breaker.
        Failure re-opens with
        doubled cooldown.
    end note
```

### State Transitions

| From | To | Trigger | Side Effects |
|------|----|---------|--------------|
| CLOSED | OPEN | `recordFailure()` when `Failure_Count__c >= threshold` | Status set to Blocked, Cooldown_Until__c set, Alert event fired |
| OPEN | HALF_OPEN | `allowRequest()` when `DateTime.now() >= Cooldown_Until__c` | Status set to Throttled |
| HALF_OPEN | CLOSED | `recordSuccess()` | Failure count reset to 0, Status set to Active |
| HALF_OPEN | OPEN | `recordFailure()` | Cooldown doubled (exponential backoff) |

---

## Design Principles

1. **Security First**: All SOQL uses `WITH SECURITY_ENFORCED`. All classes use `with sharing`. FLS is enforced at the selector layer.

2. **Bulkification**: All invocable actions accept and return `List<>`. Budget operations use `FOR UPDATE` to prevent race conditions.

3. **Caching**: The `AgentGovSelector` caches settings, metadata, and registration records per transaction to minimize SOQL consumption.

4. **Fail-Safe Defaults**: If Custom Settings are not configured, sensible defaults are used (from `AgentGovConstants`). If the framework is disabled, all actions are allowed.

5. **Separation of Concerns**: Entry points (REST, Invocable, Apex) are thin wrappers. Business logic lives in service classes. Data access is centralized in the Selector.

6. **Observability**: Platform Events provide real-time visibility. Action Logs and Conflict Logs provide historical audit trails. Budget status is always available via API.
