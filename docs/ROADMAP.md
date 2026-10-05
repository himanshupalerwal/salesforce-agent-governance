# Roadmap

This document is the single source of truth for what has shipped and what is planned.
Dates are targets, not commitments. Contributions toward any item are welcome; open an
issue to discuss the approach before starting.

---

## v1.0 — Core Framework (Released April 2026)

- Agent registry with session tracking
- Governor budget manager with configurable thresholds
- Circuit breaker pattern (CLOSED / OPEN / HALF_OPEN)
- Metadata-driven policy engine
- Priority-based conflict resolution
- REST API (register, authorize, budget, health)
- Invocable actions for Flows
- LWC dashboard with four monitoring components
- Platform events for real-time alerts

## v1.1 — Dynamic Budget Tracking (Released April 2026)

- Governed Proxy API: five CRUD endpoints that execute on behalf of agents and charge
  budget by the real record count
- `AgentGovContext`: transaction measurement for Apex agents using the `Limits` class
- `POST /report` with reconciliation and credit-back
- Parameterized `/authorize` (`amount`)
- Multi-limit consumption in one update
- Session counters, the Report Agent Usage action, and an enhanced dashboard

## v1.2 — Summer '26 Ready (Released September 2026)

Platform modernization and security hardening. See `CHANGELOG.md` for the full list.

- API 67.0 with an explicit system-mode / user-mode split
- Structured proxy queries with bound values (no SOQL text from callers)
- CRUD and field-level security enforcement on every proxied operation, plus policy field
  restrictions and record caps
- Hashed API keys, server-side key issuance and rotation, and Agent User binding
- Unique daily budget rows, persisted overage, single-probe half-open breakers
- Administrator alert emails and a complete audit trail (rejected rows kept as `System`
  entries, purge summaries, correlation ids on REST errors)
- Bulk-safe invocable actions
- Live dashboards with `@wire`, platform-event refresh, ARIA, and SLDS 2 styling hooks
- Prettier, ESLint, Jest thresholds, Code Analyzer, scratch-org Apex tests in CI, Dependabot,
  a release workflow, and migration scripts

---

## v1.3 — Make It Work (In progress)

v1.3 was planned as the Agentforce-native release. An audit before starting found features
that had shipped but never engaged for real agents: no session was ever opened, execution
time was never recorded, and conflict detection could never fire.
Building Agentforce integration on top of that would have compounded it, so this release
repairs the foundation first and proves it in a real org. The Agentforce-native items move
unchanged to v1.4. The Apex test job in CI still runs only once the repository's
`SFDX_AUTH_URL` secret is configured; until then the end-to-end suite in a real scratch org is
what proves each change.

- Automatic sessions: one run per agent, closed after an idle window, with a guard that allows
  one active session per agent
- Complete audit rows: correlation id, duration, session, and reason on every row a governed
  request writes; alert history; rows for Apex units and usage reports; refusals recorded on
  REST, the proxy, and the Flow actions
- Deactivation refused on every governed entry point, the emergency bypass applied the same
  way on each, and a request that fails unexpectedly undone, charges included
- Budget days counted in the org's time zone
- Record conflicts resolved inside Register Agent Action batches
- Retention for every framework object, and one-step job scheduling
- An actionable console: agent list with row and bulk actions, activity log, usage history,
  agent record page, setup checklist, and permission-gated, audited administrative actions,
  with one shared look: state pills, placeholders while loading, and tables that scroll in
  their own frame
- Alert rows and credits worded for the people who read them
- An end-to-end suite that drives a real scratch org as an administrator, a responder and a
  read-only user, including upgrade rehearsals from v1.1 and v1.2

---

## Engineering debt

- **Reduce Code Analyzer Moderate findings.** 180 remain, chiefly method complexity and long
  parameter lists across the core services (the query builder, budget manager, session
  tracker, trigger handler, circuit breaker, policy engine, admin controller and proxy), and
  hardcoded Ids in test classes. CI gates at High today; the goal is to clear these and raise the gate to
  Moderate.

---

## v1.4 — Agentforce-Native (Target: Q1 2027)

- **Action and credit budgets.** A fourth limit type for agent actions, with an optional
  cost per action so the dashboard can show estimated Flex Credit spend per agent per day.
- **Governed Agentforce action.** A generic invocable action, compatible with Agentforce
  Builder, that resolves the registration from the running Agent User, runs the governance
  pipeline, and invokes a target Flow or Apex action. Shipped with a sample Agent Script
  agent so the repository demonstrates governance inside a real agent.
- **Hosted MCP exposure.** Metadata and a walkthrough for exposing the governed actions
  through a Salesforce Hosted MCP Server behind an External Client App, so external MCP
  clients get governance without the REST proxy.
- **Observability import.** A scheduled job that reads the Data 360 AI usage data model,
  when present, and reconciles action and token usage into AgentGov budgets. (Correlation ids
  on action logs shipped early, in v1.3.)
- **Platform Cache** for registration, policy, and limit-configuration reads.
- **Removal** of the deprecated body `apiKey` credential and the `API_Key__c` field, which
  orgs upgrading straight from v1.1 still need for their first connection.

## v2.0 — Advanced Governance (Target: 2027)

- **Human-in-the-loop approvals** for operations a policy marks as high risk, with an
  "awaiting approval" pipeline outcome.
- **Audit immutability.** A Big Object archive with a hash chain instead of hard-delete
  cleanup.
- **Cross-transaction conflict detection** through Platform Cache locks, with queued
  resolution and configurable retry.
- **Second-generation package** with a namespace, an AppExchange listing, and a post-install
  wizard.
- **Anomaly detection and forecasting**: behavior profiles per agent, proactive breaker
  engagement, and budget forecasts.
- **Multi-org federation** with a central governance hub.

---

## Ideas under consideration

- Agent-to-agent coordination messages
- Custom Apex policy evaluators beyond metadata rules
- Trigger-based attribution of DML to agent users
- Change Data Capture reconciliation of agent operations

---

## Version history

| Version | Date           | Highlights                                                                             |
| ------- | -------------- | -------------------------------------------------------------------------------------- |
| 1.3.0   | Unreleased     | Sessions, complete audit trail, actionable console, end-to-end suite                   |
| 1.2.0   | September 2026 | API 67.0, hardened proxy and auth, atomic budgets, live dashboards, CI and tooling     |
| 1.1.0   | April 2026     | Governed Proxy API, `AgentGovContext`, `/report`, enhanced dashboard                   |
| 1.0.0   | April 2026     | Registry, budgets, circuit breaker, policies, conflicts, REST, Flow actions, dashboard |
