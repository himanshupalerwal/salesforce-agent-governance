# Changelog

All notable changes to AgentGov are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

[1.2.0]: https://github.com/himanshupalerwal/salesforce-agent-governance/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/himanshupalerwal/salesforce-agent-governance/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/himanshupalerwal/salesforce-agent-governance/releases/tag/v1.0.0

## [1.2.0] - 2026-09-18

Platform modernization and security hardening for Summer '26. Read the
**Breaking and behavior changes** section before upgrading an existing org.

### Breaking and behavior changes

- **API version 67.0.** Every component now targets Summer '26. Database operations run in
  user mode by default on this version, so the framework declares its access mode
  explicitly everywhere: its own bookkeeping runs in system mode through `AgentGovSelector`
  and the new `AgentGovDml`, and everything done on an agent's behalf runs in user mode.
  `WITH SECURITY_ENFORCED`, which Salesforce removed in 67.0, is gone.
- **Proxy `/query` takes a structured request instead of SOQL text.** Send `objectName`,
  `fields`, and optional `where`, `orderBy`, and `limit`. A `query` property is rejected with
  a 400 and a migration hint. Relationship paths and subqueries cannot be expressed, values
  are always bound, and the query runs in user mode.
- **Budgets deny when any limit type is Blocked or Exhausted.** Budget status is now the most
  severe status across API calls, SOQL queries, and DML operations, and every consumption
  path (including `AgentGovContext`, `/report`, and the Report Agent Usage action) denies the
  request when the status is Blocked or Exhausted. Previously only the single-type overload
  denied, and only for the limit type being consumed.
- **`/report` no longer credits budget back.** It previously reconciled `actual` against a
  caller-supplied `preAuthorized` figure and credited the difference, which let any agent
  clear its own consumption by under-reporting usage or over-stating what it had reserved.
  Both numbers come from the caller in the same request and the framework keeps no record of
  what was reserved, so the credit could not be verified. Usage beyond the pre-authorized
  amount is still charged; unused pre-authorization is simply not refunded. Budget
  corrections are an administrative action through `AgentGovBudgetManager.creditBudget`.
  Negative counts are now rejected with `INVALID_INPUT`, and `/report` requires an active
  agent, which it previously did not check at all.
- **`/report` accepts an optional `success` flag** and returns `circuitBreakerState`. This is
  how an agent that uses `/authorize` reports the outcome of its work. Without it a tripped
  breaker could never be closed from REST, because `recordSuccess()` and `recordFailure()`
  are Apex-only and `/authorize` refused the Throttled status a HALF_OPEN breaker carries.
- **`/authorize` admits Throttled agents.** Throttled is the status a breaker in HALF_OPEN
  carries; the breaker still decides whether a given call is the single admitted probe.
  Refusing Throttled here left a REST agent permanently locked out after its breaker tripped.
- **`/authorize` validates `operation`** against the supported operations and rejects an
  `amount` below 1.
- **Caller-supplied API keys must be at least 24 characters.** The stored, dashboard-readable
  `API_Key_Prefix__c` holds the first 12 characters of a key, so a shorter key placed its
  whole secret in a readable field. Generated keys are unaffected.
- **`Is_Enabled__c` now means what it says.** Unchecking it bypasses the circuit breaker,
  budgets, and conflict detection as well as the policy engine, so an emergency bypass
  actually unblocks a migration. It no longer suspends the audit trail: activity that happens
  while governance is off is exactly what an administrator needs recorded.
- **`GET /budget/{id}` and `GET /health/{id}` are guarded.** The caller must be the agent in
  question (by key or user binding) or hold the new `AgentGov_Admin_Access` custom
  permission.
- **REST responses use one envelope.** Success responses carry `success`, `correlationId`,
  and the payload; error responses carry `success`, `errorCode`, `message`, `correlationId`,
  and `timestamp`. Proxy write responses replace the top-level `success` flag that reflected
  per-record outcomes with `allSucceeded`. Unexpected exceptions return a generic message
  and a correlation id instead of the exception text.
- **`AgentGov_User` is read-only.** It no longer grants edit access on registrations; it
  grants the dashboard controller and read access to every field the dashboards show.
- **Dashboard Apex moved.** The `@AuraEnabled` methods that lived on `AgentGovSelector` now
  live on `AgentGovDashboardController` and run in user mode. Custom components that
  imported them must change their import path.
- **`AgentGovContext.executeGoverned` no longer swallows exceptions.** The action's exception
  propagates after the measured usage has been charged.

### Deprecated

- **`apiKey` in the request body.** Send the key in the `X-AgentGov-Key` header instead. Body
  keys still work and every such response carries a `deprecation` message. Removal is
  planned for v1.3.
- **`AgentGov_Registration__c.API_Key__c`.** Keys are stored as a SHA-256 hash in
  `API_Key_Hash__c`. The old field is read only to upgrade keys created by earlier releases
  and is cleared on first use. Removal is planned for v1.3.

### Added

- **Hashed API keys with server-side issuance.** `POST /register` without a key returns a
  freshly generated key once; `POST /rotate-key` issues a replacement. Only the hash and a
  short identifying prefix (`API_Key_Prefix__c`) are stored, with `API_Key_Last_Rotated__c`.
- **Agent User binding.** `Agent_User__c` links a registration to the user an agent runs as
  (an Agentforce Agent User or an External Client App integration user). Calls made by that
  user authenticate without any key. `AgentGovRegistryService.bindAgentUser` sets it.
- **`AgentGov_Agent` permission set** for the user an agent runs as: access to the REST
  classes only, because bookkeeping no longer needs object access.
- **`AgentGov_Operators` permission set group** and the `AgentGov_Admin_Access` custom
  permission.
- **Structured query builder** (`AgentGovQueryBuilder`) with typed bind variables, a
  per-policy record cap, and a framework maximum of 2,000 rows.
- **Policy enforcement of field restrictions and record caps.**
  `AgentGov_Policy__mdt.Field_Restrictions__c` and `Max_Records_Per_Transaction__c` are now
  enforced by the proxy; restricted fields are denied rather than silently dropped.
- **Conflict detection in the proxy** for update, upsert, and delete.
- **Unique daily budget key** (`Budget_Key__c`, populated by `AgentGovBudgetTrigger`) so two
  concurrent first-of-day requests can no longer create two budget rows.
- **Single-probe half-open circuit breaker.** Only one request is admitted while a breaker
  is HALF_OPEN (`Half_Open_Probe_At__c`); the doubled retry cooldown is capped at one day.
- **Administrator alert emails.** `AgentGov_Alert__e` events are emailed to
  `Admin_Notification_Email__c`.
- **Audit trail completeness.** Log rows the database rejects are re-inserted as `System`
  entries carrying the original values; publish failures fall back to direct inserts; the
  purge job records a summary; unhandled REST errors are logged with their correlation id.
  The action-log `Action Type` picklist gains `Report` and `System`.
- **Bulk-safe invocable actions.** All five Flow actions handle 200 requests with a handful
  of queries and DML statements. Report Agent Usage gains `Budget Allowed` and `Error
Message` outputs; Check Agent Budget reports unknown agents per request.
- **Public helpers added while hardening.** `AgentGovCircuitBreaker.mayProbe` reports whether an
  agent is entitled to a probe without writing anything, so a status check can defer to the
  breaker. `AgentGovRestAuth.requireUsableKey` rejects a caller-supplied key too short for its
  stored prefix to stay non-revealing. `AgentGovBudgetManager.defaultAllocation` exposes the
  configured daily default. `AgentGovTriggerHandler.buildFrameworkEvent` and
  `recordFrameworkEvents` let a caller report many failures in one statement.
  `AgentGovSampleData.deleteSampleData` removes only the demonstration records.
- **Bulk service APIs**: `AgentGovBudgetManager.consumeBudgets` and `checkBudgets`,
  `AgentGovCircuitBreaker.allowRequests` and `recordOutcomes`,
  `AgentGovSelector.getRegistrationsByIds` and related lookups.
- **Nested `AgentGovContext` tracking**, with each agent charged only for its own work.
- **Field history tracking** on registrations (status, breaker state, key rotation, agent
  user) and budgets (status). New **Agent Sessions** tab in the app.
- **Live dashboards.** The Lightning components use `@wire` with `refreshApex`, subscribe to
  the AgentGov platform events, coalesce overlapping refreshes, toast errors, carry ARIA
  attributes on progress bars and alerts, and style with SLDS 2 global styling hooks.
- **Tooling and CI**: Prettier with the Apex plugin, ESLint 9 flat config, Jest coverage
  thresholds, Salesforce Code Analyzer v5, an Apex test job in a disposable scratch org,
  Dependabot, a tag-driven release workflow, an Agentforce-capable scratch org definition,
  `CLAUDE.md`, and a `.editorconfig`.
- **Migration scripts** `scripts/migrate/hash-api-keys.apex` and
  `scripts/migrate/dedupe-budgets.apex`.

### Fixed

- `/authorize` never validated `objectName`. A policy names the object it governs, so omitting
  the field made every object-scoped policy inapplicable and the request was allowed. An agent
  could be authorized for an operation a deny policy forbids by leaving one field out. The
  endpoint now requires it, and the policy engine denies a blank object or operation rather
  than treating it as matching nothing.
- `POST /agentgov/rotate-key` had no status check, so a deactivated or blocked agent could still
  mint a working credential. Deactivating an agent whose key had leaked did not contain the leak.
- `AgentGov_Agent` no longer carries platform-event permissions. On a platform event, Create
  cannot be granted without Read, and Read is subscribe access, which would have let the user an
  agent runs as watch every other agent's activity in real time. The framework now falls back to
  writing the audit rows directly in system mode when a publish is refused, so the trail stays
  complete without granting that access.
- Internal errors returned their raw text to REST callers. `AgentGovDml` collects platform status
  codes, validation-rule messages and field API names into the exception message, and those
  reached the caller verbatim. The detail is now written to the action log under the correlation
  id and the response carries a generic message, which is what this class already promised.
- `POST /agentgov/report` serialized the caller's entire payload into the audit log, and a report
  of zero usage costs no budget, so it was an uncapped way to write arbitrary text into the
  governance ledger. Only the three recognized counters are recorded.
- `recordOutcomes` read breaker state without a row lock, so a success recorded by one
  transaction could overwrite a trip written by a concurrent failure and lose the tally.
- Removing the agent user's platform-event permissions stopped alerts reaching an
  administrator: the alert trigger never fires when the publish is refused, so no email was
  sent for any alert raised on a REST call. A refused publish now delivers the email directly.
- `/authorize` matched `objectName` as the caller sent it, so a value the describe accepts but
  a policy does not, such as one with surrounding whitespace, skipped an object-scoped rule.
  It is now resolved through describe before the policy is evaluated.
- A circuit-breaker refusal on `/authorize` and a report that exceeded its budget both left no
  audit entry, while every other denial wrote one.
- `/delete` called the conflict resolver directly and so kept enforcing conflicts during an
  emergency bypass, unlike the other proxy handlers.
- Session-counter failures were reported one database statement at a time, so a systemic
  failure across a large batch exhausted the statement limit and rolled the batch back.
- `AgentGovRegistryService.registerAgent` ignored the configured default daily budget and used
  the built-in constant, so the v1.2 change to honour `Default_Daily_Budget__c` only applied to
  budget rows, not to newly registered agents.
- `AgentGovSampleData.createAll()` failed with a raw duplicate-value error on a second run, and
  `deleteAll()` could exceed the row limit because each of its five passes was sized
  independently. A new `deleteSampleData()` removes only the demonstration records, which is
  what the install guide now points at.
- `endSession` re-stamped the end time of a session that had already finished.
- An unrecognised `orderBy.direction` was silently treated as ascending.
- The dedupe migration applied the API_Calls thresholds to all three limit types when
  recomputing a merged status, and ignored whether a limit configuration was active.
- The release archive omitted `scripts/`, although the documentation bundled beside it tells
  the reader to run the migration scripts.
- The policy `Operation__c` help text shown in Setup named `Read`, which the engine never
  matches, and omitted four operations that it does.
- The bulk Flow path reused one circuit-breaker decision for every request an agent had in the
  batch, so a half-open agent admitted all 200 records instead of the single probe the
  framework documents. Only the first request per probing agent now gets through.
- The half-open reopen check performed an unlocked read-modify-write that blanked the probe
  claim, so two requests arriving as the cooldown expired could each wipe the other's claim and
  both be admitted. The check is now read-only; the transition and the probe claim happen
  together under the row lock that already existed.
- The scheduled health check transitioned breakers from rows read without a lock, which could
  overwrite a probe another transaction had just claimed. It now re-reads under the lock.
- The `Is_Enabled__c` bypass still charged budget on both reporting paths and still let the
  proxy trip the breaker, so an emergency bypass could deny an agent with `BUDGET_EXCEEDED` or
  strand it as Blocked. The bypass now covers `/report`, the Report Agent Usage action, and
  breaker recording.
- `AgentGovCleanup` read the retention period in its constructor, and scheduled Apex serializes
  the instance, so an already-scheduled purge ignored every later change to the setting. It is
  now resolved when the job runs.
- The Lightning components orphaned their platform-event subscriptions when destroyed before
  the subscribe promise settled, and a failure on one channel discarded the subscription that
  had succeeded on the other.
- `percentOf` reported 0% for a zero allocation where the Apex rule treats any consumption
  against a zero allocation as full usage.
- The half-open recovery path did not actually work. Tripping leaves an agent `Blocked`, and a
  Blocked agent was refused at authentication before any circuit-breaker code could run, so the
  transition to HALF_OPEN never happened over REST and the agent stayed locked out until the
  scheduled health check ran, or forever if it was never scheduled. A breaker whose cooldown has
  elapsed now reopens itself at the start of a request, and that request becomes the probe.
- The `Is_Enabled__c` bypass was incomplete in the proxy and in `AgentGovContext`. It skipped the
  breaker and the policy engine but not budget consumption or conflict detection, so an emergency
  bypass still refused writes with `BUDGET_EXCEEDED` or `RECORD_LOCKED`. Usage is now measured and
  reported but not charged while the switch is off.
- The Register Agent Action wrote no audit entry at all while governance was bypassed, which is
  the window an administrator most needs recorded.
- The `/authorize` bypass response used `allowed` instead of the documented `authorized` and
  omitted `agentId` and `remainingBudget`, so a well-behaved client read the bypass as a denial.
  It now keeps the documented shape and adds `governanceEnabled`.
- Keys inherited from v1.1 still had their whole value written into the dashboard-readable
  `API_Key_Prefix__c` by the lazy upgrade and by the migration script, which the minimum-length
  rule did not cover because neither path can refuse a key without locking the agent out. A key
  too short to truncate safely now gets no prefix at all.
- The alert email was capped by number of alerts but not by length, so a batch of long agent names
  could still overrun the plain text limit and lose the notification.
- Registering with an API key already in use failed the unique index and surfaced as HTTP 500,
  which both misreported a caller error and let an unauthenticated caller test whether a given key
  was already registered. It is now a 400 with a message that does not distinguish the two cases.
- `AgentGovContext.executeGoverned` could replace the action's own exception with a
  bookkeeping error. The post-failure charge caught only `AgentGovException`, so anything else
  thrown while charging escaped and hid the real cause from the agent.
- `/authorize` charged the budget before checking for a record conflict, so an agent refused
  because another agent held the record had already paid for the request. The conflict check
  now runs first, matching the proxy and the documented pipeline order.
- An unrecognized action type on the Register Agent Action produced no audit entry, while
  every other denial branch in the same method wrote one.
- `AgentGov_Limit_Config__mdt.Default_Daily_Budget__c` was shipped, documented as the default
  daily allocation, and queried, but never read. New budget rows fell back to a hard-coded
  constant, so changing the metadata had no effect. It now drives the allocation.
- The administrator alert email listed every alert in a delivered batch with no cap. A large
  batch exceeded the 32,000-character plain text limit and the send failed, losing the
  notification. The email now lists the first 100 and summarises the rest.
- `AgentGovSampleData.deleteAll()` issued five unbounded deletes and failed on the DML row
  limit in any org holding a real action log. It now purges in bounded passes and returns the
  number of rows removed.
- The Lightning progress bars used 70 and 90 as their color thresholds while the framework
  warns at 80, throttles at 90, and blocks at 95, so the bar color contradicted the status
  beside it. Percentages are also clamped to 100, which persisted overage could previously
  exceed and push past a progress bar's declared maximum.
- The circuit breaker counted lifetime failures instead of consecutive ones. A success on a
  closed breaker never cleared the tally, so a healthy long-lived agent accumulated unrelated
  failures and eventually tripped for no reason. The field, the README, the FAQ, the Flow
  guide, and the configuration guide all described it as consecutive.
- `consumeBudgets` queried one registration at a time from inside its per-agent loop when
  building escalation alerts, so a large Flow batch of distinct agents crossing a threshold
  together could exceed the SOQL limit. The registrations are now fetched once.
- Budget alerts could fail to publish when usage passed 999.99% of an allocation, because
  `AgentGov_Alert__e.Usage_Percentage__c` is `Number(5,2)`. The reported figure is clamped;
  the exact usage remains on the budget row.
- The Code Analyzer job in CI never failed the build. `sf code-analyzer run` only exits
  non-zero when `--severity-threshold` is supplied, and it was not, so every Moderate, High,
  and Critical violation passed silently.
- `AgentGovSampleData` shipped with no test class and therefore no coverage, contradicting
  the project's own "no class below 85%" rule.
- Consumption that pushed a budget past 100% was never written back, so the overage was
  lost.
- The shipped `MCP External Account Read` policy used the operation `Read`, which the engine
  never matched; it now uses `Query`.
- `AgentGovReportUsage`, `/report`, and `AgentGovContext` could not block an agent because
  the multi-limit consumption path never denied.
- `creditBudget` used hardcoded thresholds and could not lower a Blocked status.
- Null consumption counters caused a null pointer exception on the single-type path.
- Sessions, breaker updates, health-check transitions, and alert publishing silently
  discarded partial failures.
- `Report` actions could not be written to the action log because the value was missing
  from the picklist.
- The scratch-org setup script passed the org duration to the wrong flag.
- Circuit-breaker writes cleared the whole selector cache instead of refreshing one record.
- Conflicts involving an unknown agent failed to log because a lookup pointed at a
  non-existent record.

### Security

- Removed SOQL injection and policy bypass in the proxy `/query` endpoint.
- Closed a budget-forgery hole in `POST /agentgov/report`: any agent could zero its own
  consumption, and its Blocked status with it, by reporting negative usage or an inflated
  pre-authorization. The endpoint also accepted requests from suspended agents. See
  **Breaking and behavior changes**.
- `AgentGov_User`, the read-only dashboard permission set, no longer grants read on
  `API_Key__c` or `API_Key_Hash__c`. In an org upgraded from v1.1 the first still holds live
  plaintext keys until each agent next authenticates, so every dashboard viewer could read
  and reuse any agent's credential. No dashboard displays either field.
- Caller-supplied API keys shorter than 24 characters are refused, so the stored prefix can
  never contain the entire key.
- Added CRUD and field-level security enforcement to every proxied read and write.
- Replaced plaintext API key storage with SHA-256 hashes.
- Stopped echoing exception messages and stack traces to REST callers.
- Permission sets now grant Apex class access explicitly and include the lookup fields the
  dashboards read; required fields are no longer listed. `AgentGov_Action_Event__e` and
  `AgentGov_Alert__e` are granted too, without which the live dashboards silently never
  refresh for anyone who is not a System Administrator.

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
