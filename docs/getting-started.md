# Getting Started

Two runbooks. **Part 1** is everything the person installing AgentGov does, once.
**Part 2** is everything the administrator running it does afterwards. Each step says what
it does and how to confirm it worked.

Installing into an org that already runs AgentGov v1.1 or v1.2? Follow
[Upgrading from v1.2](#upgrading-from-v12) or [Upgrading from v1.1](#upgrading-from-v11)
instead of deploying straight away. The scheduled jobs must be removed before you deploy,
because Salesforce refuses to deploy a class that a scheduled job uses.

---

## Prerequisites

| Requirement    | Detail                                                                                                |
| -------------- | ----------------------------------------------------------------------------------------------------- |
| Salesforce org | Summer '26 (API 67.0) or later. Enterprise, Unlimited, Performance, or Developer Edition.             |
| Permissions    | System Administrator, or a profile that can deploy metadata and assign permission sets.               |
| Salesforce CLI | Version 2.x. [Install guide](https://developer.salesforce.com/tools/salesforcecli)                    |
| Git            | To clone the repository.                                                                              |
| Node.js        | Version 20 or later, only if you intend to run the Lightning component tests or the end-to-end suite. |

Check the CLI and pick the org you are installing into:

```bash
sf version
sf org login web --alias agentgov --set-default
```

For a first look, use a scratch org instead; Step 1 shows how, once you have the source.

---

# Part 1: Installing

## Step 1. Get the source

```bash
git clone https://github.com/himanshupalerwal/salesforce-agent-governance.git
cd salesforce-agent-governance
```

To install into a scratch org, authorize the Dev Hub that creates it once, then create the org
from the project you just cloned:

```bash
sf org login web --alias devhub --set-default-dev-hub
sf org create scratch --definition-file config/project-scratch-def.json \
  --alias agentgov --duration-days 30 --set-default
```

The scratch org definition enables Agentforce, so you can build agents alongside the
framework.

## Step 2. Deploy

```bash
sf project deploy start --source-dir force-app --target-org agentgov
```

This deploys 238 components: five custom objects, one custom setting, two custom metadata
types, and two platform events, with their fields and list views; five custom metadata records
(the three limit configurations and two example policies); the Apex classes and triggers; the
Lightning Web Components; three Lightning pages (the console, the agent record page, and the
session record page); page layouts and two compact layouts; tabs; the app; four permission
sets, one permission set group, and three custom permissions; and a report folder and a
dashboard folder.

**Confirm it worked.** The command reports `Status: Succeeded` with a component count. A
failed deploy applies nothing, so fix the reported error and run it again.

## Step 3. Assign a permission set

This is the step that decides who can see anything. Assign yourself the administrator set:

```bash
sf org assign permset --name AgentGov_Admin --target-org agentgov
```

AgentGov ships five ways to grant access. Give each person or integration one of them;
`AgentGov_Responder` is the exception, added on top of `AgentGov_User`:

| Grant                | Give it to                                             | What it allows                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| -------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `AgentGov_Admin`     | Administrators who configure and operate the framework | Full access, including Modify All, to the five AgentGov custom objects. The API key fields, the framework's computed fields, and most action and conflict log fields are read-only; usage, circuit breaker, and session fields stay editable for corrections. All tabs; all Apex classes; the `AgentGov_Admin_Access` custom permission that allows reading any agent through the REST API; and both console permissions: `AgentGov_Operate_Agents` and `AgentGov_Manage_Keys` |
| `AgentGov_User`      | People who only need to watch the dashboards           | Read-only on the AgentGov objects and every field the dashboards show, all tabs, and the dashboard controller. The API key and key hash fields are deliberately excluded                                                                                                                                                                                                                                                                                                       |
| `AgentGov_Responder` | On-call staff, together with `AgentGov_User`           | The console's actions on agents (reset breakers, activate and deactivate, end sessions, credit budgets, schedule jobs) through `AgentGov_Operate_Agents`, without the right to rotate API keys                                                                                                                                                                                                                                                                                 |
| `AgentGov_Agent`     | The Salesforce user an AI agent runs as                | The two REST resources and nothing else. The framework records its own bookkeeping in system mode, so this user needs no access to AgentGov objects                                                                                                                                                                                                                                                                                                                            |
| `AgentGov_Operators` | Administrators, as a single assignment                 | A permission set group containing `AgentGov_Admin` and `AgentGov_User`                                                                                                                                                                                                                                                                                                                                                                                                         |

```bash
# The group, if you prefer one assignment for administrators
sf org assign permset --name AgentGov_Operators --target-org agentgov
```

**Confirm it worked.** Open the App Launcher and find the **AgentGov** app. Its navigation bar
shows Home and six tabs: AgentGov Dashboard, Agent Registrations, Governor Budgets, Agent
Sessions, Agent Action Logs, and Agent Conflict Logs. AgentGov Dashboard is the console, which
says there are no agents yet.

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
blank and no administrator email is sent, though agent owners are still emailed about their own
agents when **Notify Agent Owners** is checked. Every alert is recorded in the action log
either way.

**Confirm it worked.** The Custom Settings page shows your record at the organization level.

## Step 5. Schedule the background jobs

Three jobs keep state moving. Nothing breaks without them, because budgets are created on
first use and breakers recover when an agent next calls. Schedule them anyway so the
dashboards stay accurate and logs do not grow without limit.

```bash
sf apex run --file scripts/setup/schedule-jobs.apex --target-org agentgov
```

The **Schedule jobs** button on the console's Setup tab does the same. Running either again
replaces the jobs rather than duplicating them.

| Job                   | Runs            | Does                                                                                                                      |
| --------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------- |
| AgentGov Daily Reset  | Midnight daily  | Creates today's budget row for every active agent                                                                         |
| AgentGov Health Check | Hourly          | Moves OPEN circuit breakers to HALF_OPEN after their cooldown, and closes sessions that are idle or have run for 24 hours |
| AgentGov Cleanup      | Sunday at 02:00 | Deletes logs, conflicts, finished sessions, and budget rows past their retention, with a summary per object               |

**Confirm it worked.** The console's Setup tab, or Setup, **Scheduled Jobs**, lists all three
with a next run time.

> **Before you next deploy.** Salesforce refuses to deploy an Apex class that a scheduled
> job refers to. When you upgrade AgentGov later, remove the jobs first and schedule them
> again afterwards. The script works whichever AgentGov version is installed:
>
> ```bash
> sf apex run --file scripts/setup/unschedule-jobs.apex --target-org agentgov
> ```

## Step 6. Load the sample data (optional)

Populates the dashboards so you can see the framework working before registering anything
real.

```bash
sf apex run --file scripts/setup/load-sample-data.apex --target-org agentgov
```

This creates five agents, today's budgets, five sessions (three of them live), 25 action logs,
three alerts, and three conflict logs. The sample agents use fixed API keys, `agk_sample_lead_enrichment_001` through
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

One run removes at most 1,500 rows of each kind and removes the agents only once none of their
rows remain, so after heavy use of the sample agents, run it again until it returns 0.

> **`deleteAll()` is a different method.** It removes **every** AgentGov row in the org,
> including real agents, budgets and the entire audit trail. It exists for resetting a scratch
> org. Never run it against an org that holds anything you want to keep. It purges in bounded
> passes, so repeat it until it returns 0.

**Confirm it worked.** The console's Overview shows five agents, one of them needing attention
for a half-open breaker, three live sessions, budget bars, and three recent alerts. Its
Conflicts tab lists three conflicts. The **Agent Registrations** tab's **All** list view shows
the five agents with their type, status, breaker state, and priority, and opening one shows its
sessions, budgets, action logs, and conflicts beside its governance panel.

## Step 7. Verify the install

```bash
sf apex run test --target-org agentgov --test-level RunLocalTests \
  --code-coverage --result-format human --wait 30
```

Every test must pass and org-wide coverage must be at least 85%, which is what CI enforces in
a scratch org that holds only AgentGov. `RunLocalTests` runs every local test in the org, so
in an org with Apex of its own, run the AgentGov test classes instead and judge the coverage
of the AgentGov classes.
The suite currently reports 358 tests and about 94% coverage. A failure means the deploy is
incomplete.

In a scratch org you can also run the end-to-end suite, which drives the deployed
framework over real HTTP and in a browser. See the [Testing Guide](testing-guide.md).

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
    'Account Research Agent',                   // name shown on the console
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
    'Warehouse Sync MCP Agent', AgentGovConstants.AGENT_TYPE_MCP_EXTERNAL,
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
wins a record conflict: the lower number wins.

Budgets are consumed in the ways described in the README under _How Budget Tracking Works_:
the governed proxy charges one DML operation per record submitted and one SOQL query per
query, `AgentGovContext` measures Apex usage, `/authorize` with `/report` lets an agent
declare and then add its own usage, Register Agent Action charges one unit per authorized
request, and Report Agent Usage charges what a Flow reports.

## Write the access policies

Policies live in **Setup → Custom Metadata Types → AgentGov Policy → Manage Records**. Each
record answers one question: for this agent type, on this object, for this operation, allowed
or denied?

Two ship as examples. MCP agents may query Accounts with a 200-record cap, and may not delete
them.

Rules worth knowing before you write your own:

- Policies are default-allow and deny-wins. An action that no policy matches is **allowed**,
  and any matching deny refuses it, even when an allow matches too. A deny-all policy (object
  `*`, operation `*`) therefore refuses every action, including the ones you allow.
- To restrict an agent type, add deny policies for the specific objects and operations it must
  not use. An allow policy never refuses anything, so an allow list ("only these objects")
  cannot be written with allow policies.
- `Field_Restrictions__c` and `Max_Records_Per_Transaction__c` on matching allow policies apply
  only to requests made through the proxy. A request naming a restricted field is refused, not
  quietly trimmed. A `/query` limit above the cap is reduced to the cap, and a write with more
  records than the cap is refused with `POLICY_VIOLATION`. Register Agent Action and
  `/authorize` use only the allow or deny decision.
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
with the warning, throttle, and block percentages. Edit those records rather than adding more;
only one active record per limit type is used. Defaults are 80, 90, and 95. A budget's status
is the most severe status across all three limit types. Warning and Throttled raise an alert
and still allow requests; Blocked or Exhausted denies every operation until a credit or the
next budget day, which starts at midnight in the org's default time zone.

## Watch it run

- **AgentGov Dashboard** is the console. Overview shows what needs attention, live sessions,
  budget usage, and alerts; Agents, Activity, and Conflicts list them in full; Setup checks the
  installation. It refreshes by itself when agents act, and people with the console
  permissions act on agents from it.
- **An agent's record page** shows its state, usage, credentials, actions, and recent
  activity above the record details.
- **Agent Action Logs** records every action, including denials. Rows with the action type
  `System` are the framework reporting about itself: alert delivery failures, purge
  summaries, and unhandled REST errors with their correlation id.
- **Alert emails** go to `Admin_Notification_Email__c`, and to each affected agent's owner
  when `Notify_Agent_Owners__c` is checked, whenever a budget crosses a threshold or a circuit
  breaker trips.
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

To stop an agent, deactivate it (above, or **Deactivate** in the console). A deactivated
agent is refused by the REST API (`/authorize`, `/report`, and `/rotate-key`), by every proxy
endpoint, by the Register Agent Action and Report Agent Usage Flow actions, and by
`AgentGovContext`. Apex that calls `AgentGovCircuitBreaker`, `AgentGovPolicyEngine`, or
`AgentGovBudgetManager` directly must check the agent's `Status__c` itself, and Log Agent
Action records rows for any agent.

**Is Enabled** in AgentGov Settings does the opposite, and does not stop anything. Unchecking it
is an emergency bypass: every entry point (REST, the proxy, the Flow actions, and
`AgentGovContext`) skips the circuit breaker, policy, budget, and conflict checks and charges
nothing. Every action is allowed, whatever the agent's breaker or budget state, except that a
deactivated agent is still refused. Use it only to unblock a migration. The audit trail keeps
recording, so you can see what ran during the window.

## Connect an external or MCP agent

The [MCP Integration Guide](mcp-integration-guide.md) walks through the External Client App,
the integration user, and exposing the governed proxy as MCP tools. The
[REST API Reference](rest-api-reference.md) documents every endpoint, the response envelope,
and the error codes.

---

## Upgrading from v1.2

1. Remove the scheduled jobs, because Salesforce refuses to deploy a class a scheduled job
   uses:

   ```bash
   sf apex run --file scripts/setup/unschedule-jobs.apex --target-org agentgov
   ```

   The script also removes copies you scheduled under names of your own, such as a second
   health check at half past the hour, because those block the deploy too. Its log lists every
   job it removed.

2. Deploy this version.
3. Give on-call staff `AgentGov_Responder`, together with `AgentGov_User`, if they should act
   on agents from the console; on its own it opens nothing. `AgentGov_Admin` already includes
   both new console permissions.
4. Schedule the jobs again:

   ```bash
   sf apex run --file scripts/setup/schedule-jobs.apex --target-org agentgov
   ```

   Then recreate any copies of your own that step 1 listed.

Read the **Breaking and behavior changes** in [CHANGELOG.md](../CHANGELOG.md) first. The ones
most likely to affect you: sessions now open and close automatically, budget days follow the
org's time zone, and a user bound to several agents must send a key.

## Upgrading from v1.1

Follow these steps instead of the v1.2 steps above; they include everything those steps do.
`npm run e2e:upgrade` rehearses the whole path in a scratch org.

1. **If your org ever created duplicate daily budget rows, run this first.** v1.2 adds a
   unique key to budget rows. It deploys over existing duplicates, but a later write to a
   duplicate row is rejected once the other row of its pair carries the key. The script merges
   each duplicate group into its oldest row; run it again until it reports that none remain.

   ```bash
   sf apex run --file scripts/migrate/dedupe-budgets.apex --target-org agentgov
   ```

2. **Clear the scheduled jobs.** Salesforce refuses to deploy an Apex class that a scheduled
   job refers to, and a v1.1 install following this guide will have three of them. Remove
   them, including any copies you scheduled under names of your own:

   ```bash
   sf apex run --file scripts/setup/unschedule-jobs.apex --target-org agentgov
   ```

3. Deploy and assign permission sets as in Part 1, and give on-call staff
   `AgentGov_Responder` together with `AgentGov_User` if they should act on agents from the
   console. Schedule the jobs again afterwards using the command in Part 1, Step 5, and
   recreate any copies of your own that step 2 listed.

4. Move any remaining plaintext API keys to hashed storage. Keys are also upgraded
   automatically the first time each agent connects, so this is optional but tidy.

   ```bash
   sf apex run --file scripts/migrate/hash-api-keys.apex --target-org agentgov
   ```

5. Update your REST clients. These changes break v1.1 callers:
   - `/agentgov-proxy/query` no longer accepts SOQL. Send `objectName`, `fields`, and
     optional `where`, `orderBy`, and `limit`.
   - Responses use one envelope: `success` and `correlationId` beside the payload, and on an
     error `errorCode`, `message`, and `timestamp`. A proxy write reports its per-record
     outcome in `allSucceeded`, not the top-level `success`.
   - `GET /budget/{id}` and `GET /health/{id}` answer only the agent itself or a holder of
     `AgentGov_Admin_Access`.
   - `/report` no longer credits unused pre-authorization back, refuses negative counts, and
     requires an active agent. `/authorize` refuses an unknown `operation` and an `amount`
     below 1.
   - A caller-supplied API key must be at least 24 characters.

   One more is a deprecation rather than a break: send the API key in the `X-AgentGov-Key`
   header. The body `apiKey` still works until v1.4, and every successful response to a
   request that used it carries a `deprecation` notice.

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
