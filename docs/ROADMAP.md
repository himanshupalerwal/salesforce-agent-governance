# Roadmap

This document outlines planned features and improvements for AgentGov.

---

## v1.0 -- Core Framework (Released)

**Released: April 2026**

- Agent Registry with session tracking
- Governor Budget Manager with configurable thresholds
- Circuit Breaker pattern (CLOSED/OPEN/HALF_OPEN)
- Metadata-driven Policy Engine
- Priority-based Conflict Resolution
- REST API (register, authorize, budget, health)
- Invocable Actions for Flows
- LWC Dashboard with 4 monitoring components
- Platform Events for real-time alerts

---

## v1.1 -- Dynamic Budget Tracking (Released)

**Released: April 2026**

- **Governed Proxy API** — 5 CRUD endpoints that execute operations on behalf of agents with real budget tracking (budget = actual record count)
- **AgentGovContext** — Apex transaction measurement using `Limits` class for automatic SOQL/DML/callout tracking
- **POST /report** — Post-execution reporting with reconciliation and credit-back
- **Parameterized /authorize** — Optional `amount` parameter for pre-declared consumption
- **Multi-limit consumption** — `consumeBudget(Map)` for single-DML multi-type updates
- **Session counter updates** — Session fields now track actual resource usage
- **Report Agent Usage** invocable action for Flows
- **Enhanced Dashboard** — 6 summary cards, active sessions table, circuit breaker tripped count

---

## v1.2 -- Email Alerts & Platform Cache

**Target: Q3 2026**

- Custom email alert templates for budget warnings, circuit breaker trips, and policy violations
- Admin notification flows triggered by platform events
- Platform Cache integration for sub-millisecond budget reads
- Cache-first, database-fallback pattern (target: 0-1 SOQL per authorization)
- Daily digest email summarizing agent activity

---

## v1.3 -- Managed Package

**Target: Q4 2026**

- Package AgentGov as a Salesforce 2GP Managed Package
- AppExchange listing with free installation
- Namespace-prefixed components for conflict-free installation
- Post-install configuration wizard
- Automated test suite validation during install

---

## v2.0 -- AI-Powered Governance

**Target: 2027**

### Anomaly Detection
- ML model trained on historical agent behavior
- Automatic detection of unusual patterns (spike in API calls, unexpected object access)
- Proactive circuit breaker engagement before failures occur
- Risk scoring per agent based on behavior profile

### Predictive Budget Forecasting
- Forecast daily budget consumption based on historical patterns
- Auto-adjust budget allocations to prevent exhaustion
- "What-if" analysis for adding new agents

### Multi-Org Federation
- Central governance hub for multi-org Salesforce environments
- Cross-org agent policy synchronization
- Aggregated monitoring dashboard across orgs

### Advanced Conflict Resolution
- Cross-transaction conflict detection via Platform Cache locks
- Queue-based conflict resolution (FIFO with priority override)
- Automatic retry with configurable backoff

---

## Ideas Under Consideration

- **Agent-to-agent communication:** Structured messaging between agents for coordination
- **Cost tracking:** Map governor budget consumption to actual Salesforce API credit costs
- **Approval workflows:** Require human approval before high-risk actions
- **Custom policy functions:** Apex-based custom policy evaluators beyond metadata-driven rules
- **Trigger-based tracking:** Deploy triggers on key objects to count DML per agent user
- **Change Data Capture integration:** Independent verification of agent operations via CDC

---

## How to Contribute

We welcome contributions to any roadmap item. Check the [Contributing Guide](../CONTRIBUTING.md) for how to get started. If you want to work on a specific roadmap item, open a GitHub issue to discuss the approach before starting implementation.

---

## Version History

| Version | Date | Highlights |
|---------|------|------------|
| **v1.1.0** | April 2026 | Dynamic budget tracking -- Governed Proxy API, AgentGovContext, /report endpoint, enhanced dashboard |
| **v1.0.0** | April 2026 | Initial release -- Registry, Budget Manager, Circuit Breaker, Policy Engine, Conflict Resolver, REST API, Flow Actions, LWC Dashboard |
