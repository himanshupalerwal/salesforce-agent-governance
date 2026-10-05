# Testing Guide

AgentGov is tested at three levels. Each proves something the others cannot.

| Level            | Command                      | Runs where          | Proves                                                                                     |
| ---------------- | ---------------------------- | ------------------- | ------------------------------------------------------------------------------------------ |
| Apex tests       | `sf apex run test`           | Any org, in-process | Each class behaves correctly when called directly, including bulk and security rules       |
| Jest tests       | `npm run test:unit:coverage` | Your machine        | Each Lightning component renders and reacts correctly against mocked data                  |
| End-to-end suite | `npm run e2e`                | A real scratch org  | The assembled, deployed system works when driven from outside Apex, the way callers use it |

The Jest tests run on every pull request. The Apex tests need the `SFDX_AUTH_URL` Dev Hub secret:
CI runs them when the repository has it and skips them otherwise, including on pull requests from
forks, which receive no secrets. The end-to-end suite is what a release is judged by: a feature is
done when its end-to-end checks pass in a real org.

---

## The end-to-end suite

The suite lives in `e2e/`. It calls framework Apex directly only where an administrator would,
for example to activate an agent, or where an Apex agent would, measuring its work with
`AgentGovContext` from anonymous Apex. Everything else goes through the same doors a real caller
uses:

- REST and proxy endpoints over real HTTP, with agent keys in the `X-AgentGov-Key` header
- Flow actions through the REST actions endpoint, `/services/data/vXX.X/actions/custom/apex/...`
- A restricted, API-only agent user on the `Minimum Access - API Only Integrations` profile
  with nothing but the shipped `AgentGov_Agent` permission set
- The console, in headless Chromium, as three people: the administrator, an on-call
  responder with `AgentGov_User` and `AgentGov_Responder`, and a read-only user with only
  `AgentGov_User`. The suite creates the last two on first use, on Salesforce Platform
  licences, and completes the new-password page that a user's first browser login shows.

Every API call is made by the Salesforce CLI itself, mostly with `sf api request rest`, so access
and refresh tokens stay in the CLI's own credential store: from CLI 2.136.8, the CLI output the
suite reads holds none (the suite runs the CLI without `SF_TEMP_SHOW_SECRETS`, which would reveal
them). The browser checks are the one exception to the CLI making every call. Each login link
comes from `sf org open --url-only`, is single-use, and is handed straight to Chromium, which then
calls the org itself. That link, and the password the CLI generates for each console user's first
login, are held only in memory: the suite never prints them or writes them to disk.

### Running it

```bash
npm ci
npx playwright install chromium     # once, for the browser checks

npm run e2e                                   # new scratch org, deleted afterwards
npm run e2e -- --target-org <alias>           # an existing scratch org
npm run e2e -- --target-org <alias> --no-deploy --suites api
npm run e2e:upgrade                           # rehearse an upgrade from v1.1
npm run e2e:upgrade -- --from v1.2            # rehearse an upgrade from v1.2
npm run e2e:compare -- <before.json> <after.json>
```

The suite refuses to run against anything but a scratch org, because it changes the org-wide
AgentGov Settings and scheduled jobs below and does not put them back:

- `Circuit_Breaker_Failure_Threshold__c` is 3, and `Circuit_Breaker_Cooldown_Minutes__c` and
  `Session_Idle_Minutes__c` are 1, so breakers trip after three failures and the time-based
  checks finish in about a minute and a half.
- `Admin_Notification_Email__c` is cleared and `Notify_Agent_Owners__c` unchecked, so no alert
  email is sent. The suite raises alerts on purpose, and mailing each one would reach a real inbox
  and spend the org's daily email allowance.
- `Is_Enabled__c`, `Enable_Real_Time_Events__c` and `Enable_Conflict_Detection__c` are checked,
  and `Max_Concurrent_Agents__c` is 500.
- The AgentGov scheduled jobs are removed, including copies scheduled under other names, by any
  run that deploys or includes the api suite: the deploy step and check I3 both run
  `scripts/setup/unschedule-jobs.apex`. Nothing schedules them again, so the org stays deployable.

After a run in an org you keep using, restore your own settings, including the alert email, and
schedule the jobs again with `scripts/setup/schedule-jobs.apex`, recreating any copies of your
own, for example before the walkthrough below.

Results are printed as a table and saved under `e2e/results/`, which is not committed. A run that
stops early, because a suite could not go on, prints the results of the suites that finished and
saves nothing. Compare two runs to see exactly which checks a change fixed or broke:

```text
Fixed: failed before, pass now (25)
  api:B7   The agent's activity opened a session
  api:K3   The budget day follows the org's time zone, not the caller's
  ...
```

### What the checks cover

| Group | Claims checked                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| A     | Registration returns a one-time key; only its hash is stored; inactive and unknown agents are refused; a deactivated agent is refused by REST `/authorize`, the proxy's `/query`, Register Agent Action, Report Agent Usage and `AgentGovContext.startTracking`, and is charged nothing; a registration value the database rejects, such as a malformed owner email, is refused with 400 naming the field, and nothing is saved; a body value of the wrong JSON type and an `/authorize` `recordId` that is not a record Id answer 400, not 500, and charge nothing; and a deactivated agent's refused `/rotate-key` leaves a Denied audit row and its key in place                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| B     | A proxy write creates the records, charges the budget by record count, and leaves an audit row carrying the correlation id, the duration, and the session; an update or delete naming the same record twice, a `/query` filter or sort the field does not support, LIKE on a number field, and a record value that is an object or sets a read-only field answer 400 and charge nothing, while a number sent for a text field and a time value are accepted                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| C     | Budgets escalate through Warning, Throttled and Blocked, each escalation is recorded as an alert, and the block is audited                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| D     | Failures open the circuit breaker; refusals while it is open are audited; after the cooldown one probe is admitted and closes it; the health check moves a cooled-down breaker to half-open; a malformed request leaves a half-open breaker's probe for the next request                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| E     | Policies refuse forbidden operations, a 205-record write is governed in one call, a policy's record cap limits real query results, and a deny policy that names the agent type by the label shown on records is enforced                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| F     | Two agents claiming one record in the same Flow batch are resolved by priority, and the conflict is logged                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| G     | Every Flow action works over the REST actions endpoint, a 200-request batch is charged and counted, Apex units measured by `AgentGovContext` are audited, and three failures logged from Flow trip the agent's breaker, also when each follows a Register Agent Action authorization; a failure logged while the breaker is open does not push back its retry, and after the cooldown Register Agent Action admits one probe, which the logged outcome closes; an unrecognised action type is refused and audited against the agent; and Apex work that fails and also exhausts the budget keeps its own error on its audit row                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| H     | Sessions open on first use, never duplicate under concurrent calls, close after the idle window at their last activity, and are closed by the health check; ten simultaneous calls are each charged and counted exactly once                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| I     | One call schedules the three jobs without duplicates, and the unschedule script clears them so a new version can be deployed                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| J     | Retention purges old logs, conflicts, finished sessions and budget rows, and keeps recent ones                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| K     | The agent user cannot read AgentGov data directly, authenticates by its binding, is refused records it may not create (and the refusal is audited), is charged to the org's day, and must send a key when bound to two agents; a `/query` or `/delete` the agent user may not make is refused with 403 before anything is charged, and audited; and a breaker the agent user's own failures trip is still recorded as an alert, though the user cannot publish events                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| L     | With `Is_Enabled__c` unchecked, an agent whose breaker tripped is authorized, and the proxy lets it write, charges nothing and audits the write; a deactivated agent is still refused over REST and in Flow; the bypass leaves the tripped breaker as it was, and with governance back on the agent is refused again                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| T     | Demo traffic flows through the proxy's `/query`, `/create` and `/delete`, REST `/authorize` and Register Agent Action, and failed outcomes reported to `/report` trip an agent's circuit breaker                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| U     | The console lists the agents and live sessions, shows when a tripped agent may retry, opens an agent's record page with its activity, and filters the activity log to Denied to show a refused request's reason. Every single-agent action is proven by its effect on the org: a breaker reset, deactivating an agent (refused at once) and activating it again, rotating a key (shown once; the old key is refused, the new one works, and the audit row does not hold it), ending a live session (the next call opens a new one), and crediting a budget, each with its audit row; crediting more than was used credits only what was used. The reset and deactivate confirmations say what they change, and the saved key screenshot hides the key. The Setup tab shows the session idle window in force and warns when real-time events are off, and an agent's page shows a key with no stored prefix as issued and says a deactivated agent has no session because it is deactivated. A responder resets a breaker, is recorded as the audit row's creator, and is never offered key rotation, a read-only user sees no control that changes anything, and in a narrow window the panels stack without overflowing |

### The upgrade rehearsal

`npm run e2e:upgrade` creates a scratch org, installs v1.1 from the repository history, and
seeds the data only a v1.1 org can hold: duplicate daily budget rows and plaintext API keys. It
then follows the documented upgrade path and checks each step:

1. `scripts/migrate/dedupe-budgets.apex` merges the duplicates, sums their usage and recomputes
   the status, and a second run changes nothing.
2. `scripts/setup/unschedule-jobs.apex` runs, then this version deploys over the migrated org.
3. `scripts/migrate/hash-api-keys.apex` replaces every plaintext key with its hash, without a
   prefix for keys too short to truncate safely.
4. Every migrated budget row accepts the one-row-per-day key, and a key issued under v1.1 still
   authenticates.
5. The full API suite then runs against the upgraded org.

`npm run e2e:upgrade -- --from v1.2` does the same from the v1.2.0 tag. The v1.2 org is seeded
through v1.2 itself: agents registered over its REST API with the keys it issued, a day's first
traffic, the duplicate sessions its `startSession` allowed, and the three jobs from its guide plus
a second health check at half past the hour under an administrator's own name. Sessions a caller
opened hours ago and never ended are inserted directly, back-dated. Checks W1 to W8 then prove
that:

1. The unschedule script removes all four jobs and names the administrator's copy in its log.
2. This version deploys over the v1.2 org, v1.2's administrators hold the new console
   permissions, and one command schedules each job once.
3. A key v1.2 issued still authenticates, and its request is charged to the budget row v1.2
   started that day.
4. Each agent's next action leaves it one live session holding the one-active key. An idle
   v1.2 session closes at its last known activity and a new one opens; a live one is extended.
5. The health check closes every session v1.2 left open, each at its last known activity.
6. The full API suite then runs against the upgraded org.

Each step depends on the one before it, so the rehearsal stops at the first failure, prints the
steps it ran, and saves no results file. `--keep`
leaves the org for inspection, and `--dev-hub <alias>` names the Dev Hub when the CLI has no
default one.

### Scratch-org limits

A Developer Edition Dev Hub allows few active and daily scratch orgs. Reuse one long-lived org
with `--target-org` while developing, and keep the temporary-org runs for the final check.

---

## Checking it by hand

The suite proves each behaviour; this walkthrough is for seeing it yourself. Use an org that has
followed [Getting Started](getting-started.md) through Step 6, so it holds the sample data, and do
the walkthrough within about 20 minutes of loading it, on the same day. The sample's three live
sessions were last active 2, 6 and 10 minutes before it was loaded, and the console lists only
sessions active within the default 30-minute idle window. Its budgets are dated the day it was
loaded, in the org's time zone. If more time has passed or the day has changed, delete and reload
the sample data first:

```bash
sf apex run --target-org <alias> <<'APEX'
AgentGovSampleData.deleteSampleData();
APEX
sf apex run --file scripts/setup/load-sample-data.apex --target-org <alias>
```

Then open the console:

```bash
sf org open --target-org <alias> --path lightning/n/AgentGov_Dashboard
```

| #   | Do                                                                                                                                                                        | You should see                                                                                                                                                |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Look at the Overview                                                                                                                                                      | Five agents, four active, one needing attention, three live sessions, and **Live** at the end of the tab bar                                                  |
| 2   | Select the **Need attention** tile                                                                                                                                        | The Agents tab, filtered to Opportunity Scoring Agent                                                                                                         |
| 3   | Back on the Overview, find Opportunity Scoring Agent under **Needs attention**                                                                                            | A **Half-open** breaker, "Next request is a trial", and a **Reset breaker** button                                                                            |
| 4   | Select **Reset breaker**, then **OK**                                                                                                                                     | A confirmation that the breaker closed, and the agent leaves **Needs attention**                                                                              |
| 5   | Read **Budget usage today** and **Recent alerts**                                                                                                                         | Data Sync MCP Agent Throttled at 92% and Case Routing Agent at Warning, with three alerts that read as sentences under a label                                |
| 6   | On **Agents**, select **All** under **Show** (step 2 left it on Needs attention), open Case Routing Agent's row menu, choose **Credit budget**, and credit 1000 API calls | A confirmation; on the agent's record page its API calls fall from 82% to 62%                                                                                 |
| 7   | Open any agent's row menu, choose **Rotate key**, then **OK**                                                                                                             | A dialog showing the new key once, with **Copy**. After **Done** the key cannot be shown again                                                                |
| 8   | On **Activity**, set **Status** to **Failure**                                                                                                                            | Only failed rows, each with its reason                                                                                                                        |
| 9   | Clear the filters and select the **Request** link on one of your Admin rows                                                                                               | Only the rows of that request, found by its correlation id                                                                                                    |
| 10  | Select an agent's name                                                                                                                                                    | Its record page: the name in the header, state pills, usage, breaker, live session, credentials, actions, recent activity, and usage history                  |
| 11  | Open **Conflicts**                                                                                                                                                        | Three conflicts, each naming the agent that went ahead                                                                                                        |
| 12  | Open **Setup**                                                                                                                                                            | A checklist that is green once the jobs are scheduled and an administrator email is set (an end-to-end run clears it), and the three jobs with their next run |
| 13  | Make the browser window narrow                                                                                                                                            | Panels stack, and nothing scrolls sideways                                                                                                                    |
| 14  | Optionally, sign in as a user who has only `AgentGov_User`                                                                                                                | The same data, with no action buttons, row menus, checkboxes, or Setup tab                                                                                    |

Every change in steps 4, 6, and 7 also appears on **Activity** as an `Admin` row. The row's text
names no one: select its time to open its record page, where **Created By** is the person who made
the change.

`deleteSampleData()` finds the sample agents by their fixed keys, so a sample agent whose key you
rotate in step 7 is left behind when you delete or reload the sample data. To avoid that, rotate
the key of an agent you registered yourself.
