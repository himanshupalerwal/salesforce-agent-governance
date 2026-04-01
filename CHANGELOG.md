# Changelog

All notable changes to AgentGov will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-04-01

### Added
- **Governed Proxy API** (`AgentGovProxyApi.cls`) — 5 new REST endpoints (`/query`, `/create`, `/update`, `/delete`, `/upsert`) that execute CRUD operations on behalf of agents. Budget consumed by **actual record count**, not hardcoded 1.
- **AgentGovContext** — Transaction-level measurement wrapper for Apex agents. Uses `Limits.getQueries()`, `Limits.getDMLStatements()`, and `Limits.getCallouts()` to measure actual resource consumption automatically.
- **POST /agentgov/report** — Post-execution reporting endpoint. Agents report actual consumption after execution. Supports reconciliation against pre-authorized amounts with automatic credit-back.
- **Multi-limit budget consumption** — New `consumeBudget(Id, Map<String, Integer>)` method consumes multiple limit types in a single DML operation.
- **Budget credit** — New `creditBudget()` method reduces consumed amounts for reconciliation.
- **Session counter updates** — Session fields (`API_Calls_Used__c`, `SOQL_Queries_Used__c`, `DML_Statements_Used__c`) are now updated during budget consumption.
- **Report Agent Usage** invocable action (`AgentGovReportUsage.cls`) for Flows to report actual usage.

### Changed
- **POST /agentgov/authorize** now accepts optional `amount` parameter (default 1, backward compatible).
- Dynamic field type conversion in proxy API handles DateTime, Date, Boolean, Decimal, and Integer fields from JSON.

## [1.0.0] - 2026-04-01

### Added

- **Agent Registry** — Register, activate, deactivate, and manage AI agents (`AgentGov_Registration__c`)
- **Session Tracking** — Track agent sessions with resource consumption (`AgentGov_Session__c`)
- **Governor Budget Manager** — Daily budget allocation and consumption tracking per agent (`AgentGov_Budget__c`)
  - Configurable thresholds via `AgentGov_Limit_Config__mdt` (Warning at 80%, Throttle at 90%, Block at 95%)
  - Auto-create daily budgets on demand
  - Platform event alerts (`AgentGov_Alert__e`) when thresholds are crossed
- **Agent Conflict Resolver** — Priority-based conflict resolution when agents compete for the same record
  - In-memory record locking
  - Conflict logging (`AgentGov_Conflict_Log__c`)
- **Circuit Breaker Pattern** — Automatic agent health monitoring
  - Three states: CLOSED (normal), OPEN (blocked), HALF_OPEN (testing recovery)
  - Configurable failure thresholds and cooldown periods
  - Exponential backoff on retry failures
- **Agent Policy Engine** — Custom Metadata-driven access control
  - Object-level, field-level, and operation-level policies (`AgentGov_Policy__mdt`)
  - Deny-overrides-allow evaluation logic
  - Policy validation utility
- **Audit Trail** — Complete action logging via platform events
  - Async logging via `AgentGov_Action_Event__e` for minimal transaction overhead
  - `AgentGov_Action_Log__c` for persistent audit trail
- **REST API** — External agent integration endpoints
  - `POST /agentgov/register` — Register external agents
  - `POST /agentgov/authorize` — Authorize and log agent actions
  - `GET /agentgov/budget/{agentId}` — Check remaining budget
  - `GET /agentgov/health/{agentId}` — Check agent health
- **Invocable Actions** — Flow-friendly actions
  - Check Agent Budget
  - Log Agent Action
  - Get Agent Status
  - Register Agent Action (all-in-one)
- **Scheduled Jobs**
  - `AgentGovDailyReset` — Reset daily budgets at midnight
  - `AgentGovCleanup` — Purge old action logs based on retention settings
  - `AgentGovHealthCheck` — Transition circuit breakers and close orphaned sessions
- **LWC Dashboard** — Real-time monitoring
  - `agentGovDashboard` — Summary cards, budget usage bars, conflict table
  - `agentHealthMonitor` — Agent cards with circuit breaker status
  - `agentBudgetAllocation` — Detailed budget breakdown per agent
  - `agentConflictViewer` — Conflict log datatable
- **Sample Data** — `AgentGovSampleData.createAll()` populates demo agents and activity
- **Permission Sets** — `AgentGov_Admin` and `AgentGov_User`
- **Lightning App** — `AgentGov` app with custom tabs and dashboard page
- **Comprehensive Documentation** — Architecture, getting started, configuration, API reference, REST API, Flow integration, MCP integration, troubleshooting, and FAQ
