# Roadmap

This document outlines planned features and improvements for AgentGov.

---

## v1.1 -- Email Alert Templates

**Target: Q2 2025**

- Custom email alert templates for budget warnings, circuit breaker trips, and policy violations
- Admin notification flows triggered by platform events
- Configurable alert recipients per agent (using Owner_Email__c)
- Daily digest email summarizing agent activity and budget consumption
- Slack integration via outbound message or Flow

---

## v1.2 -- Platform Cache & LWC Dashboard

**Target: Q3 2025**

### Platform Cache Integration
- Move budget checks to Platform Cache for sub-millisecond reads
- Cache-first, database-fallback pattern for budget consumption
- Reduced SOQL consumption per authorization call (target: 0-1 queries)
- Configurable cache TTL per data type

### LWC Monitoring Dashboard
- Real-time agent status dashboard (Lightning Web Component)
- Budget consumption gauges per agent
- Circuit breaker state visualization
- Action log timeline with filtering
- Conflict resolution history
- Streaming API subscription for live updates via platform events
- Embeddable in any Lightning page or App Builder

---

## v1.3 -- Managed Package

**Target: Q4 2025**

- Package AgentGov as a Salesforce 2GP Managed Package
- AppExchange listing with free installation
- Namespace-prefixed components for conflict-free installation
- Upgrade path from source-deployed version
- Post-install configuration wizard (custom setup flow)
- Automated test suite validation during install

---

## v2.0 -- AI-Powered Governance

**Target: 2026**

### Anomaly Detection
- Machine learning model trained on historical agent behavior
- Automatic detection of unusual patterns (spike in API calls, unexpected object access)
- Proactive circuit breaker engagement before failures occur
- Risk scoring per agent based on behavior profile

### Predictive Budget Forecasting
- Forecast daily budget consumption based on historical patterns
- Auto-adjust budget allocations to prevent exhaustion
- Recommendations for optimal budget distribution across agents
- "What-if" analysis for adding new agents

### Multi-Org Federation
- Central governance hub for multi-org Salesforce environments
- Cross-org agent policy synchronization
- Aggregated monitoring dashboard across orgs
- Shared agent registry with federated identity

### Advanced Conflict Resolution
- Cross-transaction conflict detection via Platform Cache locks
- Queue-based conflict resolution (FIFO with priority override)
- Automatic retry with configurable backoff
- Conflict resolution strategies: priority, timestamp, merge

---

## Ideas Under Consideration

These are features we are exploring but have not committed to a release:

- **Agent-to-agent communication:** Structured messaging between agents for coordination
- **Cost tracking:** Map governor budget consumption to actual Salesforce API credit costs
- **Approval workflows:** Require human approval before an agent performs high-risk actions (Delete on Account, bulk updates)
- **Custom policy functions:** Allow Apex-based custom policy evaluators beyond metadata-driven rules
- **Sandbox refresh automation:** Auto-deploy AgentGov configuration to refreshed sandboxes
- **Event-driven architecture:** Replace polling-based health checks with event-driven state transitions

---

## How to Contribute

We welcome contributions to any roadmap item. Check the [Contributing Guide](../CONTRIBUTING.md) for how to get started. If you want to work on a specific roadmap item, open a GitHub issue to discuss the approach before starting implementation.

---

## Version History

| Version | Date | Highlights |
|---------|------|------------|
| **v1.0.0** | January 2025 | Initial release -- Registry, Budget Manager, Circuit Breaker, Policy Engine, Conflict Resolver, REST API, Flow Invocable Actions, Platform Events |
