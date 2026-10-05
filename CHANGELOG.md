# Changelog

All notable changes to AgentGov are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

[1.3.0]: https://github.com/himanshupalerwal/salesforce-agent-governance/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/himanshupalerwal/salesforce-agent-governance/compare/2e38077...v1.2.0
[1.1.0]: https://github.com/himanshupalerwal/salesforce-agent-governance/compare/a2c85b9...2e38077
[1.0.0]: https://github.com/himanshupalerwal/salesforce-agent-governance/commit/a2c85b9

## [1.3.0] - Unreleased

Makes what v1.2 shipped work for real agents, proves it end to end in a real org, and turns
the dashboard into a console an administrator can act from. An audit before this release found
features that never engaged outside of tests: sessions were never opened, execution time was
never recorded, and conflict detection could never fire. Those are
fixed here, and the Agentforce-native work planned for this release moves to v1.4.

Read **Breaking and behavior changes** before upgrading, then follow **Upgrading from v1.2**.

### Upgrading from v1.2

1. Remove the scheduled jobs: `sf apex run --file scripts/setup/unschedule-jobs.apex`. The
   platform refuses to deploy a class that a scheduled job uses. The script also removes
   copies you scheduled under names of your own, such as a second health check at half past
   the hour, and its log lists every job it removed.
2. Deploy.
3. Assign `AgentGov_Responder`, together with `AgentGov_User`, to on-call staff who should act
   on agents without handling API keys; on its own it opens nothing. `AgentGov_Admin` already
   includes both new custom permissions.
4. Schedule the jobs again: `sf apex run --file scripts/setup/schedule-jobs.apex`, or, with
   `AgentGov_Operate_Agents`, use **Schedule jobs** on the console's Setup tab. Recreate any
   copies of your own that step 1 listed.

Orgs upgrading straight from v1.1 run `scripts/migrate/dedupe-budgets.apex` before step 2 and
`scripts/migrate/hash-api-keys.apex` after it, as for v1.2. `npm run e2e:upgrade -- --from v1.2`
rehearses this path in a scratch org, and `npm run e2e:upgrade` the path from v1.1.

### Breaking and behavior changes

- **Sessions open and close automatically.** Nothing in v1.2 opened a session for a real
  agent, so the Active Sessions panel was always empty. Every governed action now records its
  usage and action count on the agent's current session. A session closes after
  `Session_Idle_Minutes__c` (default 30) without activity, or after 24 hours, and the agent's
  next action opens a new one. `Actions_Count__c` counts actions: a 200-request Flow batch adds
  200, where v1.2 added 1, and usage reports add none.
- **One active session per agent.** The new unique `Active_Session_Key__c` enforces it.
  `startSession` now ends the agent's current session before opening a new one, where v1.2
  created a second active session.
- **Idle sessions end at their last activity.** The health check closes idle sessions, and
  sessions open for 24 hours, as Completed, with `Session_End__c` at the last activity and
  `End_Reason__c` set to Idle or Max_Duration; v1.2 marked them Terminated when the check ran.
  Sessions v1.2 left open have no recorded activity and close at their start. Terminated now
  means ended by an administrator or by deactivation.
- **Budget days follow the org's time zone.** v1.2 dated a budget row with the calling user's
  today, so an agent called by users in different time zones was charged to two different days
  at the same moment, each with a full allocation. Budget rows are now dated in the org's
  default time zone, and each day starts at the org's midnight.
- **A user bound to more than one registration must send a key.** Keyless authentication
  through `Agent_User__c` used to pick whichever bound registration was edited last. It now
  fails with 403 and asks for the `X-AgentGov-Key` header.
- **Report Agent Usage refuses negative counts** instead of ignoring them, as `/report` does.
- **A deactivated agent is refused in Flow and Apex, as it was over REST.** Register Agent
  Action returns `authorized` false with a `denialReason`, and Report Agent Usage returns
  `allowed` false with an `errorMessage` and charges nothing. `AgentGovContext.startTracking`
  throws `AgentGovException` with `AGENT_NOT_ACTIVE`, so Apex that tracks work for an agent
  that may be deactivated catches it or checks the agent's status first.
- **Register Agent Action resolves record conflicts.** When several agents in one batch name
  the same record, the agent with the best priority keeps it and the others are refused with
  the reason, whatever the order of the requests; between agents of equal priority, the earlier
  request keeps it. This is the only entry point where two agents
  meet in one transaction, so v1.2's conflict detection could never fire. The refusal message
  no longer says the request was queued; there is no queue.
- **Retention covers every framework object.** `AgentGovCleanup` now also purges conflict logs
  and finished sessions older than `Log_Retention_Days__c`, and budget rows older than the new
  `Budget_Retention_Days__c` (default 400). v1.2 kept them indefinitely. The job runs one
  object after another and writes one summary row per object.
- **Budget percentages show the busiest limit.** `agentGovDashboard` averaged the three limit
  types and `agentHealthMonitor` summed them, so one page showed two numbers for one agent. Both
  now show peak usage, the figure the budget status is decided on.
- **The Active Sessions panel lists live sessions only**: active and used within the idle window.
- **The AgentGov Dashboard tab opens the console.** The `AgentGov_Dashboard` page holds
  `agentGovConsole` in place of the four v1.2 components, which stay available in App Builder
  for pages of your own. Agent Registration records open the new `AgentGov_Agent_Record_Page`,
  assigned as the org default: the agent panel above the record details, with a header showing
  the agent's name, status, type, priority, and breaker state (the new
  `AgentGov_Agent_Highlights` compact layout). An org that assigned a record page of its own
  assigns it again after the deploy.
- **Edit is the only action on AgentGov records.** The Agent Registration, Governor Budget, and
  Agent Session layouts now list Edit as their only Lightning action, and the action log and
  conflict log layouts none, so Delete, Clone, Change Owner, and the org's global actions such
  as New Contact leave the record header on every record page, including one of your own. Add
  them back to the layouts if you use them.
- **Agent sessions no longer allow activities.** A session record has no activity timeline, and
  tasks and events can no longer be related to sessions.
- **Alert emails are written as sentences.** Each line now reads, for example, "Support
  Agent - Blocked: API calls at 95% of today's budget (95 of 100). 2026-09-28 14:05 GMT", where
  v1.2 wrote "<type> alert for agent <name>: <limit> at <percent>% (<used> of <allocated>) at
  <time>". Mail rules or parsers that read the old wording need updating.
- **During the emergency bypass, an agent whose breaker tripped is admitted over REST and the
  proxy**, as the Flow actions already admitted it. v1.2 refused it with `AGENT_NOT_ACTIVE`
  until its cooldown ended, so the switch meant to let work through left it blocked. While
  `Is_Enabled__c` is unchecked, only a deactivated agent is refused.
- **Agent traffic writes more.** Each unit of work measured by `AgentGovContext` writes an
  `Apex` row, each Report Agent Usage request that reports usage writes a `Report` row, and
  each agent's registration is updated with `Last_Active__c` at most once a minute. Allow for
  the added log storage and event volume, and for automation on registrations that now runs on
  agent traffic.
- **`subscribeToAgentGovEvents` is throttled.** The function in `c/agentGovUtils` still works,
  but now shares the page's one subscription and calls back at most every five seconds with
  the latest event. Custom components that need every event subscribe through
  `lightning/empApi` directly.
- **Flow outcomes reach the circuit breaker through Log Agent Action.** A row logged with the
  status `Failure` now counts as a failure and one with `Success` as a success, one outcome per
  agent per batch. A Flow that authorizes with Register Agent Action, does the work, and logs how
  it went therefore trips its breaker after the configured threshold, and the outcome it logs for
  a probe closes or re-opens a half-open breaker, as `/report` does for REST agents. v1.2 wrote
  the row and moved nothing, so a Flow-only agent could never trip its breaker. `Denied` and
  `Throttled` still count for nothing, and nothing is recorded for a deactivated agent or during
  the emergency bypass. A Flow that logs `Failure` rows for events that are not the agent's own
  failures should log them as `Denied` instead.
- **Register Agent Action no longer records a success when it authorizes.** It counted every
  authorization as a success before the work had run, so the probe it admitted closed a
  half-open breaker before its work was done. With Log Agent Action outcomes now counted, it
  would also have cleared the failures a Flow logged before each authorization, and the breaker
  could never trip. A Flow that authorizes but never logs an outcome now leaves its probe
  unresolved: it is admitted one request per cooldown period until it logs a success or someone
  resets the breaker.
- **An open circuit breaker ignores outcomes.** An outcome reported while the breaker is OPEN is
  ignored until the cooldown ends and a probe is admitted, or the breaker is reset. In v1.2 a
  failure sent to `/report` after the cooldown, before a probe was admitted, re-tripped the
  breaker and raised another alert; counted the same way, the failures a Flow logs while it is
  refused would have held its breaker open indefinitely. A failed probe now also counts toward
  `Failure_Count__c` and sets `Last_Failure__c`.
- **The governed proxy validates the whole request before it consults the circuit breaker or the
  policy.** An unknown object or field, a value a field cannot hold, the same record Id twice, a
  filter or sort a field does not support, or more than 10,000 records or Ids is refused with
  400 `INVALID_INPUT`. Such a refusal is never charged, leaves no audit row, and no longer uses
  up a half-open breaker's single probe, which a malformed request used to claim, leaving the
  agent's next requests refused for a whole cooldown.
- **A `/query` the calling user may not read is refused before it is charged.** The object and
  every field the query selects, filters on, or sorts by are checked in user mode first, as
  writes already were; the refusal is 403 `ACCESS_DENIED` with an audit row, and the SOQL unit
  is no longer charged. A query the database still refuses for another reason answers 400
  `INVALID_INPUT` instead of `ACCESS_DENIED`.
- **`/delete` checks the user's delete permission before charging.** A user without it is
  refused with 403 `ACCESS_DENIED` and an audit row; v1.2 charged the request, reported a
  failure for every record, and counted it against the circuit breaker.
- **`/authorize` refuses a `recordId` that is not a Salesforce record Id** with 400
  `INVALID_INPUT`, before anything is charged. A longer value used to turn the request's audit
  row into a rejected `System` row.
- **Removal of both deprecated credentials moves to v1.4.** The body `apiKey` and the
  `API_Key__c` field stay for now; the deprecation notice and the field's description say so.

### Added

- **The AgentGov Console** (`agentGovConsole`), a single component with Overview, Agents,
  Activity, and Conflicts tabs, and a Setup tab for holders of `AgentGov_Operate_Agents`.
  Overview shows what needs attention, including tripped breakers with when they may retry and a
  **Reset breaker** button, plus live sessions, recent alerts, and 14-day usage. Agents lists
  every agent with search, filters, sorting, row actions, and bulk reset, activate, and
  deactivate. Activity is the action log with filters for status, action type, time window, and
  correlation id, showing each row's reason and duration. Setup is a checklist of governance,
  real-time events (it warns when they are off, since no alert is then raised or emailed), alert
  email, the session idle window in force, the three jobs, and policy problems, with a
  **Schedule jobs** button. Actions are shown only to people with the matching custom
  permission, confirmed before they run, and reported with their outcome. Key figures are tiles
  that open the matching list, states are labelled pills, lists load behind placeholders so the
  page does not jump, times read "5 minutes ago" with the exact time on hover, and long tables
  scroll inside their frame with the header pinned. The shared look is one stylesheet,
  `c/agentGovStyles`.
- **An agent panel** (`agentGovAgentPanel`) for the Agent Registration record page, headed by
  the agent's name and its state: breaker state and retry time, today's usage, the live session,
  credential details, the actions, recent activity, and usage history. A rotated key is shown
  once in a dialog and cleared when it closes.
- **Standalone building blocks** for App Builder: `agentGovOverview`, `agentGovAgentList`,
  `agentGovActivityLog`, `agentGovUsageHistory`, and `agentGovSetupStatus`. Placed on a page of
  its own, `agentGovOverview` leaves out the links that open the console's tabs.
- **Administrative actions** through `AgentGovAdminController`: reset circuit breakers,
  activate and deactivate agents, end sessions, credit budgets, rotate API keys, and schedule
  the background jobs. Two new custom permissions gate them on the server,
  `AgentGov_Operate_Agents` and `AgentGov_Manage_Keys`, and the new `AgentGov_Responder`
  permission set grants the first without the second. Each action records an `Admin` row in
  the action log in the same transaction, so a change never stands without its audit row. A
  credit says in the console's message and its row how much it actually credited: usage never
  goes below zero, so crediting 40 API calls to an agent that has used 30 reads "Credited 30 API
  calls to today's budget, bringing its API call usage to zero.", and a limit type with no usage
  today is refused. An agent already in the requested state, or a session that had already
  ended, is left as it is and gets no audit row.
- **Complete audit rows.** Every row a governed request writes for an agent now carries the
  request's correlation id (the new `Correlation_Id__c`, indexed), how long the request had
  taken, the session the work was recorded in, and, for a refusal or failure, the reason.
  `AgentGov_Action_Event__e` gains the matching `Correlation_Id__c`, `Session_Id__c`,
  `Execution_Time_Ms__c`, and `Error_Message__c` fields, which subscribers now receive.
  `/authorize` and the proxy's write endpoints return `sessionId`; `/query` does not, nor does
  `/authorize` during the emergency bypass. Register Agent Action, Log Agent Action, and Report
  Agent Usage accept an optional **Correlation ID** input; a batch stores the first one it
  receives on every row it writes, so a bulk Flow passing `{!$Flow.InterviewGuid}` traces the
  batch, not each interview. Log Agent Action also accepts an optional **Execution Time (ms)**.
- **Alert history.** Every delivered alert is recorded as an `Alert` row, whether or not anyone
  is configured to receive email. Its `Details__c` is a sentence led by a short label, for
  example "Blocked: API calls at 95% of today's budget (95 of 100)." or "Breaker open: 3
  failures reached the threshold of 3."; the agent is the row's `Agent_Registration__c` and
  the time its `Timestamp__c`. The new `Notify_Agent_Owners__c` setting also emails the Owner
  Email (`Owner_Email__c`) of each affected agent, listing only that address's agents, in the
  same single send.
- **Audit rows for Apex agents and Flow usage reports.** Each unit of work measured by
  `AgentGovContext` is recorded as an `Apex` row with its usage and duration, and each Report
  Agent Usage request that reports usage as a `Report` row.
- **One-step job scheduling.** `AgentGovJobScheduler.scheduleAll()` schedules the three jobs
  with the documented schedules and replaces rather than duplicates them.
  `scripts/setup/schedule-jobs.apex` wraps it, and the self-contained
  `scripts/setup/unschedule-jobs.apex` clears the jobs before a deploy. It finds them by the
  class they run as well as by name, so a copy scheduled under another name cannot block the
  deploy.
- **Session fields** `Last_Activity__c`, `End_Reason__c`, and `Duration_Minutes__c`, and
  **`Peak_Usage_Percent__c`** on budgets for sorting and reporting by the busiest limit.
- **Read methods for the console** on `AgentGovDashboardController`: `getAgentSummaries`,
  `getAgentSummary`, `getActionLogs` (filtered, and paged on the indexed `CreatedDate` and
  `Id`), `getUsageHistory`
  (daily usage from the budget rows the framework already keeps), and `getRecentAlerts`. A
  summary's `hasApiKey` reports a key with no stored prefix, which the agent panel shows as
  issued, and each summary carries the agent's own live session.
- **Public Apex added for integrators**: `AgentGovSessionTracker` and `AgentGovRequestContext`;
  `AgentGovRegistryService.activateAgents`, `deactivateAgents`, and `terminateSessions`;
  `AgentGovCircuitBreaker.resetBreakers`; `AgentGovBudgetManager.budgetDate` and the
  `consumeBudget` and `consumeBudgets` overloads that take an action count;
  `AgentGovPolicyEngine.resolveAgentType` and `appliesToAgentType`;
  `AgentGovQueryBuilder.applyRecordCap` and `assertReadable`; and
  `AgentGovRestResponder.readString`. `docs/api-reference.md` describes each.
- **An end-to-end test suite** in `e2e/` that drives a real scratch org the way its callers do:
  REST and proxy calls over HTTP, Flow actions through the REST actions endpoint, a restricted
  API-only agent user, and the console in a headless browser as an administrator, an on-call
  responder and a read-only user, with every single-agent console action checked by its effect
  on the org, and the emergency bypass checked over REST, through the proxy, and in Flow.
  `npm run e2e` runs it against a new scratch org, `npm run e2e:upgrade` rehearses an upgrade
  from v1.1, including both migration scripts, `npm run e2e:upgrade -- --from v1.2` an upgrade
  from v1.2, including the duplicate sessions and custom-named jobs a v1.2 org can hold, and
  `npm run e2e:compare` lines up two runs check by check.

### Changed

- **The v1.2 dashboard components take the console's look.** `agentGovDashboard`,
  `agentHealthMonitor`, and `agentBudgetAllocation` show states as labelled pills, totals as
  tiles with grouped digits, and placeholders while they load. They read the same Apex methods;
  what they show and how they refresh changed only as described under **Breaking and behavior
  changes** and **Fixed**.
- **Salesforce's own pages show the framework's data properly.** Each object's tab, its
  Recently Viewed list, its **All** list view, lookup dialogs, and search results now show the
  columns that matter (an agent's name, type, status, breaker state, priority, and last
  activity; a session's status, start, last activity, and end reason; a budget's date, status,
  and peak usage; a log's action, status, object, and time; a conflict's agents, object,
  outcome, and severity), where v1.2 showed only the record number. The related lists on an
  agent's record page carry those columns too, newest first. The page layouts include every
  v1.3 field: the three new settings, a session's last activity, end reason, and duration, a
  budget's peak usage, and a log's correlation id. Session records open the new
  `AgentGov_Session_Record_Page`, assigned as the org default: the session's details with its
  action log beside them, headed by its agent, status, start, and end reason (the new
  `AgentGov_Session_Highlights` compact layout).
- **Picklists read as words on Salesforce's own pages.** Record details, list views, and reports
  now show Custom Apex, MCP External, Flow Based, Closed, Open, Half-Open, API Call, Flow
  Trigger, Agent 1 Won, and Agent 2 Won rather than the stored values or the old "Agent1 Won"
  and "Agent2 Won" labels. The stored values are unchanged, so code, integrations, and reports
  that filter on them are unaffected.
- **A policy may name its agent type by the label shown on records.** Policies matched only the
  stored value, such as `MCP_External`, so a deny policy written with the label an agent's
  record now shows, MCP External, matched no agent and the action it forbade stayed allowed. The
  `Agent_Type__c` of a policy now matches the stored value or the label, in any letter case, or
  `All`, and the console's Setup tab lists a policy whose agent type is blank or names no type.
- **Actions today counts agent activity only.** The overview's figure (`getTodaysActionCount`)
  leaves out the `Alert` and `Admin` rows this release adds, and `getRecentConflictLogs` returns
  at most 200 rows.
- **The session field `DML_Statements_Used__c` is labelled DML Operations Used**, matching the
  `DML_Operations` budget unit it records. The API name is unchanged, so reports, list views,
  and integrations keep working.
- **The sample data reads like real traffic.** Its three live sessions show as live, its
  escalated budgets and tripped breaker come with the alerts the framework would have raised,
  failed actions carry a reason, every row is created in time order, and its budgets are dated
  in the org's day, as the framework's own are. Its conflicts are ones the resolver records, in
  its words: v1.2's sample included a request that was queued, which the framework never does.
- **The contributor conventions live in `CONTRIBUTING.md`**: the security model, the everyday
  commands, the release checklist, and the list of things that are easy to get wrong, so one
  document says how the code is worked on.
- **The guides were checked line by line against the code** and corrected where they had
  drifted. Among other things: the Flow examples refer to outputs by their API names, and the
  Flow patterns send every request through Register Agent Action instead of skipping an agent
  Get Agent Status reports as unhealthy, which kept a tripped agent from ever being probed; the
  policy examples achieve the restrictions they describe (policies allow by default and a
  matching deny always wins); troubleshooting finds an error's detail by its correlation id and
  covers an unknown endpoint path, an unreported probe, and agent users that cannot publish
  events; the architecture's request lifecycles and circuit breaker state machine follow the
  code, including the reset from any state; the Apex, REST, and MCP references give the order of
  every request pipeline, every validation message, and what is charged and audited; and the
  documented limits of conflict detection, Flow breaker outcomes, and the emergency bypass match
  what the framework does.

### Fixed

- **Alerts raised by a user who cannot publish platform events reached no one.** That includes
  agent and integration users and the users Flows run as. The platform refuses such a publish
  with a failed result rather than an exception, and only an exception triggered the direct
  delivery added in v1.2. Refused alerts are now recorded as `Alert` rows and emailed directly,
  and one `System` row notes the refusal.
- Register Agent Action recorded a request with an unrecognised or blank action type as a
  `System` failure row with no agent. The row is now linked to the agent, with action type
  `System`, status `Denied`, and the reason, as REST records one.
- When work run through `AgentGovContext.executeGoverned` threw and also took the agent over
  budget, its `Apex` row became `Denied` and lost the work's error, and a `System` row with no
  agent wrongly said the usage could not be charged. The row is now a `Failure` that keeps the
  work's error and notes the budget.
- The health check could move a breaker to HALF_OPEN just after a failed probe re-opened it,
  skipping the new cooldown. It now re-checks the cooldown under the row lock.
- A healthy agent's successful proxy request or `/report` no longer locks its registration after
  its session, which could deadlock with a deactivation or a new session for the same agent.
- `/query` treats a number or boolean sent for a text field as text, and accepts time values. A
  filter on a field that cannot be filtered, a sort on one that cannot be sorted, and LIKE on a
  field that is not text answer 400 before anything is charged, instead of 403 or 500.
- A body value of the wrong JSON type, a record value a field cannot hold, a read-only field
  such as `CreatedDate`, or the same record Id twice in one write answered 500; each now answers
  400 naming the problem.
- An unexpected REST or proxy error wrote two `System` rows, one of them empty; it now writes
  one.
- `validatePolicies()`, and so the console's Setup tab, reported an operation written in another
  letter case, such as `delete`, as invalid, although evaluation accepted it.
- `deleteSampleData()` removed the sample agents even when log rows remained beyond its per-run
  cap, leaving those rows with no agent. It now removes the agents only once none of their rows
  remain; run it until it returns 0.
- `scripts/migrate/dedupe-budgets.apex` held every row of its agent-and-date search in memory,
  which could exceed the heap limit when duplicates span many agents and dates, and it reported
  that no duplicates remained when its capped search had stopped short. It now keeps only
  duplicate rows, merges at most 5,000 per run, and asks to be run again whenever a run reaches
  a limit.
- The descriptions shown in Setup match what the framework does: the `AgentGov_Admin` set and
  the `AgentGov_Operators` group name the console permissions they grant, including key
  rotation; a policy's record cap and field restrictions apply only through the governed proxy;
  settings are read at org level only; and the fields for event publishing, thresholds,
  retention, the circuit breaker, the conflict log's agents, and the action log say what they
  hold. Fields and the example policies that had no description now have one.
- The v1.2 dashboard (`agentGovDashboard`) said "Live updates off" while it was still
  connecting.
- `scripts/setup/create-scratch-org.sh` opens the AgentGov console; it opened an address
  Lightning cannot show.
- **Deactivating an agent refuses it on every governed entry point.** The Flow actions Register
  Agent Action and Report Agent Usage, and `AgentGovContext` in Apex, still accepted a
  deactivated agent whose circuit breaker was closed; only REST and the proxy refused it.
  Register Agent Action and Report Agent Usage audit each refusal, `AgentGovContext.startTracking`
  throws without writing a row, and the refusal holds during the emergency bypass too.
- **An unexpected error undoes the request's work.** When a REST or proxy request failed after
  writing, the records it had created and the budget it had charged stayed saved while the
  caller received a 500, so a retry could create them twice. The request now rolls back to where
  it started, and only the error is recorded. This covers an internal failure the framework
  raises itself, such as a ledger update that fails after the write, as well as an unexpected
  exception.
- **`POST /register` returned `registrationNumber` as null.** It now returns the saved
  registration's number, such as `AGT-0007`.
- **A registration value the database rejects answered 500.** A malformed `ownerEmail`, or text
  too long for its field, now answers 400 `INVALID_INPUT` naming the field, and nothing is saved.
- **`Is_Enabled__c` is described as what it is.** The documentation called it a master kill
  switch that stops every agent. Unchecking it does the opposite: an emergency bypass that skips
  the checks and allows every action except a deactivated agent's. The docs now say so and point
  to deactivation for stopping an agent.
- The alert email tests pass in an org that has used its daily email allowance, as a busy
  sandbox can. They failed there, which could stop a deployment's test run; they now check that
  a send the org refuses is recorded as a delivery failure.
- `Last_Active__c` now follows each agent's activity. v1.2 set it only on activation, so the
  dashboard showed agents that had run all day as never active.
- A request refused because the agent's circuit breaker had tripped, or because the agent was
  inactive, left no audit row. Refusals of `/authorize`, `/report`, and the proxy are now
  recorded.
- Report Agent Usage answered "Agent registration not found" for real agents while the
  emergency bypass was on. It now returns their budget.
- `Execution_Time_Ms__c` was never written; it is now set on every agent action row a request
  produces.
- `getTodaysActionCount` filtered on a field that is not indexed and would time out on a large
  log; it now counts by `CreatedDate` across the org's day. Dashboard reads are bounded.
- The four dashboard components: three of them leaked their live-update subscriptions when
  removed from a page before subscribing finished, and all four now share one subscription with
  throttled refreshes; the budget totals row broke at phone width; one failing data load could
  hide another's error; timestamps ignored the user's Salesforce locale and time zone; statuses
  other than Normal and Warning showed the error icon; the Active Sessions panel disappeared when
  empty; and refreshing gave no feedback. The dashboard's budget tile is now **Avg peak budget
  used**, open breakers show when the agent may retry, and agent names link to their records.
- Tests no longer depend on the Dev Hub's time zone. The restricted test user no longer falls
  back silently to the more privileged Standard User profile, the proxy record-cap test now
  proves the cap, and scheduling tests assert the scheduled expression instead of a non-null Id.

### Security

- A refused `/rotate-key`, for example from a deactivated agent whose key has leaked, now leaves
  a `Denied` audit row, as refusals of the other POST endpoints do.
- Console actions are checked against a custom permission on the server before anything is
  read, act only on agents the user can see in user mode, and are audited in the same
  transaction. `AgentGov_Admin_Access`, which grants read access over REST, grants no action.
- A rotated key is returned once to the person who rotated it. Only its hash is stored, and the
  audit row records its prefix.
- An `ACCESS_DENIED` refusal from the proxy is worded by the framework and names the object,
  or the fields, the calling user may not reach. v1.2 repeated the platform's own exception
  message, which describes internals a REST caller should not see.

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
  written contributor conventions, and a `.editorconfig`.
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
