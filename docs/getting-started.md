# Getting Started

Two runbooks. **Part 1** is everything the person installing AgentGov does, once.
**Part 2** is everything the administrator running it does afterwards. Each step says what
it does and how to confirm it worked.

Installing into an org that already runs AgentGov v1.1? Read
[Upgrading from v1.1](#upgrading-from-v11) first; one step must happen before you deploy.

---

## Prerequisites

| Requirement    | Detail                                                                                    |
| -------------- | ----------------------------------------------------------------------------------------- |
| Salesforce org | Summer '26 (API 67.0) or later. Enterprise, Unlimited, Performance, or Developer Edition. |
| Permissions    | System Administrator, or a profile that can deploy metadata and assign permission sets.   |
| Salesforce CLI | Version 2.x. [Install guide](https://developer.salesforce.com/tools/salesforcecli)        |
| Git            | To clone the repository.                                                                  |
| Node.js        | Version 20 or later, only if you intend to run the Lightning component tests.             |

Check the CLI and pick the org you are installing into:

```bash
sf version
sf org login web --alias agentgov --set-default
```

Prefer a scratch org for a first look:

```bash
sf org create scratch --definition-file config/project-scratch-def.json \
  --alias agentgov --duration-days 30 --set-default
```

The scratch org definition enables Agentforce, so you can build agents alongside the
framework.

---

# Part 1: Installing

## Step 1. Get the source

```bash
git clone https://github.com/himanshupalerwal/salesforce-agent-governance.git
cd salesforce-agent-governance
```

## Step 2. Deploy

```bash
sf project deploy start --source-dir force-app --target-org agentgov
```

This deploys 198 components: five custom objects, one custom setting, two custom metadata
types, two platform events, the Apex classes and triggers, the Lightning Web Components and
the dashboard page, page layouts, tabs, the app, three permission sets, one permission set
group, and one custom permission.

**Confirm it worked.** The command reports `Status: Succeeded` with a component count. A
failed deploy applies nothing, so fix the reported error and run it again.

## Step 3. Assign a permission set

This is the step that decides who can see anything. Assign yourself the administrator set:

```bash
sf org assign permset --name AgentGov_Admin --target-org agentgov
```

AgentGov ships four ways to grant access. Give each person or integration exactly one:

| Grant                | Give it to                                             | What it allows                                                                                                                                                                      |
| -------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AgentGov_Admin`     | Administrators who configure and operate the framework | Read and write on every AgentGov object and field, all tabs, all Apex classes, and the `AgentGov_Admin_Access` custom permission that allows reading any agent through the REST API |
| `AgentGov_User`      | People who only need to watch the dashboards           | Read-only on the AgentGov objects and every field the dashboards show, all tabs, and the dashboard controller. The API key and key hash fields are deliberately excluded            |
| `AgentGov_Agent`     | The Salesforce user an AI agent runs as                | The two REST resources and nothing else. The framework records its own bookkeeping in system mode, so this user needs no access to AgentGov objects                                 |
| `AgentGov_Operators` | Administrators, as a single assignment                 | A permission set group containing `AgentGov_Admin` and `AgentGov_User`                                                                                                              |

```bash
# The group, if you prefer one assignment for administrators
sf org assign permset --name AgentGov_Operators --target-org agentgov
```

**Confirm it worked.** Open the App Launcher and find the **AgentGov** app. It has six tabs:
Dashboard, Agent Registrations, Governor Budgets, Agent Sessions, Agent Action Logs, and
Agent Conflict Logs.

```bash
sf org open --target-org agentgov --path lightning/n/AgentGov_Dashboard
```

## Step 4. Create the settings record

AgentGov falls back to sensible defaults when no settings record exists, so it works
immediately. Creating the record lets you change behavior and turn on alert emails.

In Setup, go to **Custom Settings**, click **Manage** next to **AgentGov Settings**, then
**New** at the organization level. Or from the CLI:

```bash
sf apex run --target-org agentgov <<'APEX'
AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
settings.Is_Enabled__c = true;
settings.Admin_Notification_Email__c = 'agentgov-alerts@your-company.example';
upsert settings;
APEX
```

Every field and its default is documented in the
[Configuration Guide](configuration-guide.md). The one worth setting now is **Admin
Notification Email**, because budget and circuit breaker alerts are emailed to it. Leave it
blank and no emails are sent.

**Confirm it worked.** The Custom Settings page shows your record at the organization level.

## Step 5. Schedule the background jobs

Three jobs keep state moving. Nothing breaks without them, because budgets are created on
first use and breakers recover when an agent next calls. Schedule them anyway so the
dashboards stay accurate and logs do not grow without limit.

```bash
sf apex run --target-org agentgov <<'APEX'
System.schedule('AgentGov Daily Reset', '0 0 0 * * ?', new AgentGovDailyReset());
System.schedule('AgentGov Health Check', '0 0 * * * ?', new AgentGovHealthCheck());
System.schedule('AgentGov Cleanup', '0 0 2 ? * SUN', new AgentGovCleanup());
APEX
```

| Job                   | Runs            | Does                                                                               |
| --------------------- | --------------- | ---------------------------------------------------------------------------------- |
| AgentGov Daily Reset  | Midnight daily  | Creates today's budget row for every active agent                                  |
| AgentGov Health Check | Hourly          | Moves OPEN circuit breakers to HALF_OPEN after their cooldown, ends stale sessions |
| AgentGov Cleanup      | Sunday at 02:00 | Deletes action logs older than the retention period and records a summary          |

**Confirm it worked.** Setup, **Scheduled Jobs** lists all three with a next run time.

> **Before you next deploy.** Salesforce refuses to deploy an Apex class that a scheduled
> job refers to. When you upgrade AgentGov later, either tick **Allow deployments of
> components when corresponding Apex jobs are pending or in progress** in Setup →
> Deployment Settings, or cancel the jobs first and schedule them again afterwards:
>
> ```bash
> sf apex run --target-org agentgov <<'APEX'
> for (CronTrigger t : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE 'AgentGov%']) {
>     System.abortJob(t.Id);
> }
> APEX
> ```

## Step 6. Load the sample data (optional)

Populates the dashboards so you can see the framework working before registering anything
real.

```bash
sf apex run --file scripts/setup/load-sample-data.apex --target-org agentgov
```

This creates five agents, today's budgets, sessions, 25 action logs, and three conflict
logs. The sample agents use fixed API keys, `agk_sample_lead_enrichment_001` through
`agk_sample_email_campaign_005`, stored hashed exactly as real keys are. They exist so you
can try the REST endpoints in a sandbox or scratch org. **Never load sample data into
production.**

Remove it at any time. This deletes only the five demonstration agents and their records;
anything you registered yourself is left alone:

```bash
sf apex run --target-org agentgov <<'APEX'
AgentGovSampleData.deleteSampleData(); // returns the number of rows removed
APEX
```

> **`deleteAll()` is a different method.** It removes **every** AgentGov row in the org,
> including real agents, budgets and the entire audit trail. It exists for resetting a scratch
> org. Never run it against an org that holds anything you want to keep. It purges in bounded
> passes, so repeat it until it returns 0.

**Confirm it worked.** The AgentGov Dashboard shows five agents, budget bars, active
sessions, and a conflict table.

## Step 7. Verify the install

```bash
sf apex run test --target-org agentgov --test-level RunLocalTests \
  --code-coverage --result-format human --wait 30
```

Every test must pass and org-wide coverage must be at least 85%, which is what CI enforces.
The suite currently reports 237 tests and about 92% coverage. Every test must pass; a failure
means the deploy is incomplete.

---

# Part 2: Administering

## Register your first agent

An agent needs a registration before the framework will let it do anything. Registrations
start `Inactive`; activating one is a deliberate act.

Choose how the agent will identify itself. **Binding a Salesforce user is preferred**: the
OAuth identity becomes the credential, so there is no key to store, rotate, or leak. Use an
API key only when the agent has no Salesforce user of its own.

### Option A: bind the agent's Salesforce user (preferred)

For an Agentforce Agent User, or an integration user behind an External Client App.

```bash
sf apex run --target-org agentgov <<'APEX'
AgentGov_Registration__c agent = AgentGovRegistryService.registerAgent(
    'Lead Enrichment Agent',                    // name shown on the dashboards
    AgentGovConstants.AGENT_TYPE_AGENTFORCE,    // Agentforce, MCP_External, Custom_Apex, Flow_Based
    'Enriches leads with firmographic data',    // description
    null,                                       // no API key
    'owner@your-company.example'                // who to contact about this agent
);
AgentGovRegistryService.bindAgentUser(agent.Id, '005XXXXXXXXXXXXXXX');  // the agent's user Id
AgentGovRegistryService.activateAgent(agent.Id);
System.debug(LoggingLevel.ERROR, 'Registration Id: ' + agent.Id);
APEX
```

Then assign that user the `AgentGov_Agent` permission set, plus whatever access to customer
data the agent legitimately needs. The proxy enforces exactly that access and no more.

### Option B: issue an API key

```bash
sf apex run --target-org agentgov <<'APEX'
AgentGov_Registration__c agent = AgentGovRegistryService.registerAgent(
    'Data Sync MCP Agent', AgentGovConstants.AGENT_TYPE_MCP_EXTERNAL,
    'Synchronises accounts with the data warehouse', null, 'integrations@your-company.example'
);
String apiKey = AgentGovRegistryService.issueApiKey(agent.Id);
AgentGovRegistryService.activateAgent(agent.Id);
System.debug(LoggingLevel.ERROR, 'Registration Id: ' + agent.Id);
System.debug(LoggingLevel.ERROR, 'API key, store it now: ' + apiKey);
APEX
```

**The key is shown once.** Only a SHA-256 hash and a short prefix are stored, so it cannot be
recovered. If it is lost, issue a new one and the old key stops working immediately:

```bash
sf apex run --target-org agentgov <<'APEX'
System.debug(LoggingLevel.ERROR, AgentGovRegistryService.issueApiKey('a0BXXXXXXXXXXXXXXX'));
APEX
```

Agents can also rotate their own key through `POST /agentgov/rotate-key`.

## Set the agent's budget

Open the agent's record and edit the **Budget Configuration** section. Defaults are 10,000
API calls, 5,000 SOQL queries, and 3,000 DML operations per day. **Priority** decides who
wins a record conflict, where 1 is the highest.

Budgets are consumed in three ways, described in the README under _How Budget Tracking
Works_: the governed proxy counts real records, `AgentGovContext` measures Apex usage, and
`/authorize` with `/report` lets an agent declare and then reconcile its own usage.

## Write the access policies

Policies live in **Setup → Custom Metadata Types → AgentGov Policy → Manage Records**. Each
record answers one question: for this agent type, on this object, for this operation, allowed
or denied?

Two ship as examples. MCP agents may query Accounts with a 200-record cap, and may not delete
them.

Rules worth knowing before you write your own:

- An explicit deny always beats an allow.
- If nothing matches, the action is **allowed**. Add a deny-all policy first if you want the
  opposite posture.
- `Field_Restrictions__c` and `Max_Records_Per_Transaction__c` are enforced by the proxy. A
  request naming a restricted field is refused, not quietly trimmed.
- `Operation__c` must be one of `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`,
  `Flow_Trigger`, or `*`. `Read` is not an operation and will never match.

Check your policies after editing:

```bash
sf apex run --target-org agentgov <<'APEX'
List<String> issues = AgentGovPolicyEngine.validatePolicies();
System.debug(LoggingLevel.ERROR, issues.isEmpty() ? 'All policies valid' : String.join(issues, '\n'));
APEX
```

## Tune the limit thresholds

**Setup → Custom Metadata Types → AgentGov Limit Config** holds one record per limit type
with the warning, throttle, and block percentages. Defaults are 80, 90, and 95. A budget's
status is the most severe status across all three limit types, and Blocked or Exhausted
denies every operation until a credit or the daily reset.

## Watch it run

- **AgentGov Dashboard** shows agents, budgets, sessions, and conflicts, and refreshes by
  itself when agents act.
- **Agent Action Logs** records every action, including denials. Rows with the action type
  `System` are the framework reporting about itself: alert delivery failures, purge
  summaries, and unhandled REST errors with their correlation id.
- **Alert emails** go to `Admin_Notification_Email__c` whenever a budget crosses a threshold
  or a circuit breaker trips.
- **Platform events** `AgentGov_Alert__e` and `AgentGov_Action_Event__e` are available to any
  subscriber, including Flows and Streaming API clients.

## Intervene

```bash
sf apex run --target-org agentgov <<'APEX'
Id agentId = 'a0BXXXXXXXXXXXXXXX';

// An agent is blocked and you have fixed the cause
AgentGovCircuitBreaker.resetBreaker(agentId);

// An agent hit its budget and needs to keep working today
AgentGovBudgetManager.creditBudget(agentId, AgentGovConstants.LIMIT_DML_OPERATIONS, 500);

// Stop one agent
AgentGovRegistryService.deactivateAgent(agentId);
APEX
```

To stop **every** agent at once, uncheck **Is Enabled** in AgentGov Settings. That is the
master kill switch: policy, budget, circuit-breaker and conflict checks are all bypassed and
actions are allowed, so use it to unblock a migration, not as a security control. The audit
trail keeps recording while the switch is off, so you can still see what ran during the window.

## Connect an external or MCP agent

The [MCP Integration Guide](mcp-integration-guide.md) walks through the External Client App,
the integration user, and exposing the governed proxy as MCP tools. The
[REST API Reference](rest-api-reference.md) documents every endpoint, the response envelope,
and the error codes.

---

## Upgrading from v1.1

1. **If your org ever created duplicate daily budget rows, run this first.** v1.2 adds a
   unique key that cannot deploy while duplicates exist.

   ```bash
   sf apex run --file scripts/migrate/dedupe-budgets.apex --target-org agentgov
   ```

2. **Clear the scheduled jobs.** Salesforce refuses to deploy an Apex class that a scheduled
   job refers to, and a v1.1 install following this guide will have three of them. Either tick
   **Allow deployments of components when corresponding Apex jobs are pending or in progress**
   in Setup, Deployment Settings, or cancel them and schedule them again after the deploy:

   ```bash
   sf apex run --target-org agentgov <<'APEX'
   for (CronTrigger t : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE 'AgentGov%']) {
       System.abortJob(t.Id);
   }
   APEX
   ```

3. Deploy v1.2 and assign permission sets as in Part 1. Re-schedule the jobs afterwards using
   the commands in Part 1, Step 5.

4. Move any remaining plaintext API keys to hashed storage. Keys are also upgraded
   automatically the first time each agent connects, so this is optional but tidy.

   ```bash
   sf apex run --file scripts/migrate/hash-api-keys.apex --target-org agentgov
   ```

5. Update your REST clients. Two changes break v1.1 callers:
   - Send the API key in the `X-AgentGov-Key` header. The body `apiKey` still works and every
     response says so, but it is removed in v1.3.
   - `/agentgov-proxy/query` no longer accepts SOQL. Send `objectName`, `fields`, and
     optional `where`, `orderBy`, and `limit`.

   [CHANGELOG.md](../CHANGELOG.md) lists every behavior change.

---

## Where to go next

| Document                                          | Covers                                            |
| ------------------------------------------------- | ------------------------------------------------- |
| [Configuration Guide](configuration-guide.md)     | Every setting, limit config, and policy field     |
| [REST API Reference](rest-api-reference.md)       | Endpoints, authentication, envelope, error codes  |
| [Apex API Reference](api-reference.md)            | Every public class and method                     |
| [Flow Integration](flow-integration.md)           | The five invocable actions and common patterns    |
| [MCP Integration Guide](mcp-integration-guide.md) | Putting an external or MCP agent under governance |
| [Architecture](architecture.md)                   | Security model, components, request lifecycles    |
| [Troubleshooting](troubleshooting.md)             | Symptoms, causes, and fixes                       |
