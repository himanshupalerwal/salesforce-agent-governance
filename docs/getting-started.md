# Getting Started

This guide walks you through setting up AgentGov from scratch and registering your first governed agent.

---

## Prerequisites

- **Salesforce CLI** (`sf`) version 2.x or later -- [Install Guide](https://developer.salesforce.com/tools/salesforcecli)
- **Git** -- [Install Guide](https://git-scm.com/downloads)
- A **Salesforce Dev Hub** org (for scratch orgs) or a **Developer Edition** / sandbox org
- **System Administrator** profile or equivalent permissions in the target org

Verify your CLI installation:

```bash
sf version
# Should output: @salesforce/cli/2.x.x ...
```

---

## Step 1: Clone the Repository

```bash
git clone https://github.com/himanshupalerwal/salesforce-agent-governance.git
cd salesforce-agent-governance
```

---

## Step 2: Create a Scratch Org (Recommended)

If you have a Dev Hub configured:

```bash
# Authenticate to your Dev Hub (if not already done)
sf org login web --set-default-dev-hub --alias my-devhub

# Create a scratch org
sf org create scratch \
  --definition-file config/project-scratch-def.json \
  --alias agentgov-dev \
  --duration-days 30 \
  --set-default

# Verify the org was created
sf org list
```

If you prefer to use an existing sandbox or Developer Edition org:

```bash
sf org login web --alias agentgov-dev --set-default
```

---

## Step 3: Deploy the Source

```bash
sf project deploy start --source-dir force-app --target-org agentgov-dev
```

This deploys all Custom Objects, Custom Metadata Types, Custom Settings, Platform Events, Apex classes, permission sets, and other metadata.

---

## Step 4: Assign Permission Sets

AgentGov ships with two permission sets:

- **AgentGov_Admin** -- Full access to all objects, fields, and Apex classes
- **AgentGov_User** -- Read access to registrations and budgets, execute invocable actions

Assign the admin permission set to your user:

```bash
sf org assign permset --name AgentGov_Admin --target-org agentgov-dev
```

---

## Step 5: Load Sample Data (Optional)

AgentGov includes a sample data script that creates example agents, policies, and limit configurations:

```bash
sf apex run --file scripts/setup/load-sample-data.apex --target-org agentgov-dev
```

This creates:

- 3 sample agent registrations (Lead Enrichment Agent, Case Routing Agent, Opportunity Scoring Agent)
- Default limit configurations for API_Calls, SOQL_Queries, and DML_Operations
- Sample policies for each agent type

---

## Step 6: Configure Custom Settings

Open Setup in your org and navigate to **Custom Settings > AgentGov Settings**. Click **Manage** and then **New** (or edit the default org-level record).

Recommended initial settings:

| Setting | Value |
|---------|-------|
| Is Enabled | Checked |
| Default Agent Priority | 5 |
| Max Concurrent Agents | 10 |
| Circuit Breaker Failure Threshold | 5 |
| Circuit Breaker Cooldown Minutes | 30 |
| Log Retention Days | 90 |
| Enable Conflict Detection | Checked |
| Enable Real Time Events | Checked |

If you skip this step, the framework uses these same values as defaults.

---

## Step 7: Schedule Background Jobs

Open the Developer Console or run these via `sf apex run`:

```apex
// Daily budget reset at midnight
System.schedule('AgentGov Daily Reset', '0 0 0 * * ?', new AgentGovDailyReset());

// Hourly health check
System.schedule('AgentGov Health Check', '0 0 * * * ?', new AgentGovHealthCheck());

// Weekly log cleanup (Sunday at 2 AM)
System.schedule('AgentGov Cleanup', '0 0 2 ? * SUN', new AgentGovCleanup());
```

---

## Step 8: Open the Org

```bash
sf org open --target-org agentgov-dev
```

Navigate to the **AgentGov Registrations** tab to see registered agents, or proceed to register your first agent programmatically.

---

## Step 9: Register Your First Agent

Open the Developer Console (or execute via `sf apex run`) and run:

```apex
// Register a new agent
AgentGov_Registration__c agent = AgentGovRegistryService.registerAgent(
    'Lead Enrichment Agent',        // Name
    'Agentforce',                   // Type
    'Enriches leads with firmographic data from Clearbit',  // Description
    'key-lead-enrichment-2024',     // API Key (for REST access)
    'admin@yourcompany.com'         // Owner email
);
System.debug('Registered agent ID: ' + agent.Id);
System.debug('Agent status: ' + agent.Status__c);
// Output: Agent status: Inactive

// Activate the agent
AgentGovRegistryService.activateAgent(agent.Id);
System.debug('Agent is now Active');

// Check budget
AgentGovBudgetManager.BudgetResult budget = AgentGovBudgetManager.checkBudget(agent.Id);
System.debug('Budget status: ' + budget.budgetStatus);
System.debug('API calls remaining: ' + budget.apiCallsRemaining);
// Output: Budget status: Normal
// Output: API calls remaining: 10000

// Start a session
AgentGov_Session__c session = AgentGovRegistryService.startSession(agent.Id);
System.debug('Session started: ' + session.Id);

// Option A: Use AgentGovContext for automatic tracking (Apex agents)
AgentGovContext.startTracking(agent.Id);
List<Account> accts = [SELECT Id, Name FROM Account LIMIT 10]; // 1 SOQL
update accts; // 1 DML
AgentGovBudgetManager.BudgetResult result = AgentGovContext.stopTracking();
// Budget consumed by ACTUAL delta (1 SOQL + 1 DML), not hardcoded 1
System.debug('Budget status after real tracking: ' + result.budgetStatus);

// Option B: Manual budget consumption (self-reported)
AgentGovBudgetManager.consumeBudget(agent.Id, 'SOQL_Queries', 1);

// End the session
AgentGovRegistryService.endSession(session.Id);
System.debug('Session ended');
```

### For External/MCP Agents: Use the Proxy API

Instead of calling Salesforce's standard REST API directly, external agents should use the **Governed Proxy API** which tracks actual operations:

```bash
# Create records through the proxy — budget consumed by actual record count
curl -X POST https://yourinstance.salesforce.com/services/apexrest/agentgov-proxy/create \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"apiKey":"your-key","objectName":"Lead","records":[
    {"FirstName":"John","LastName":"Doe","Company":"Acme"}
  ]}'
```

See the [REST API Reference](rest-api-reference.md) for all proxy endpoints.

---

## What's Next?

- [Configuration Guide](configuration-guide.md) -- Fine-tune settings, policies, and limits
- [API Reference](api-reference.md) -- Full Apex method documentation
- [REST API Reference](rest-api-reference.md) -- Integrate external agents
- [Flow Integration](flow-integration.md) -- Use AgentGov in Salesforce Flows
- [MCP Integration Guide](mcp-integration-guide.md) -- Connect MCP servers
- [Architecture](architecture.md) -- Deep dive into system design
