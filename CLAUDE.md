# Working on AgentGov

AgentGov is a Salesforce-native governance framework for AI agents: budgets, policies,
circuit breakers, conflict detection, and an audit trail, delivered as Apex, custom
objects, platform events, and Lightning Web Components. This file records the conventions
that keep the project consistent. Read it before changing code.

## Security model (the rule that matters most)

The framework runs at API 67.0, where database operations default to user mode. AgentGov
splits its work deliberately:

| Code path                                                                                                                 | Sharing             | Access mode   | Why                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------------------------------------------------------- | ------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AgentGovSelector`, `AgentGovDml`, `AgentGovCleanup`                                                                      | `without sharing`   | `SYSTEM_MODE` | The framework's own ledger (registrations, budgets, sessions, logs, policies) must be readable and writable regardless of who triggered the governed action. Agent Users and integration users normally hold no access to AgentGov objects. Custom metadata is read here too, so a caller without metadata access cannot make policies disappear. |
| `AgentGovProxyApi`                                                                                                        | `with sharing`      | `USER_MODE`   | Everything done on an agent's behalf against customer data respects the calling user's CRUD, FLS, and sharing. Queries are compiled by `AgentGovQueryBuilder` from a structured request and executed with bind variables; SOQL text from callers is never accepted.                                                                               |
| `AgentGovDashboardController`                                                                                             | `with sharing`      | `USER_MODE`   | Dashboards show people only what they may see.                                                                                                                                                                                                                                                                                                    |
| Service classes (`BudgetManager`, `CircuitBreaker`, `PolicyEngine`, `RegistryService`, `Context`, `TriggerHandler`, jobs) | `inherited sharing` | none directly | They touch no data themselves; all reads go through the selector and all writes through `AgentGovDml`.                                                                                                                                                                                                                                            |

Never add a bare SOQL or DML statement to a service class. Never read customer data in
system mode. Never return raw exception text to a REST caller; use `AgentGovRestResponder`.

## Code conventions

- ApexDoc on every class and public method, in the existing `@description` / `@param` /
  `@return` style. Class headers state the class's responsibility and its security posture.
- Inline comments only where the reason is not obvious (a locking choice, a security
  decision, a fixed bug), phrased in one or two plain sentences. No version tags, no
  chatty notes, no commented-out code, no references to AI tooling.
- No `System.debug` in production paths. Framework-level failures are recorded as `System`
  rows in the action log through `AgentGovTriggerHandler.recordFrameworkEvent`.
- Strings and defaults live in `AgentGovConstants`. Errors are `AgentGovException` with an
  `ErrorCode`, which maps to the REST HTTP status.
- Bulk first: invocable actions and service methods accept collections and issue one query
  and one DML per object per transaction.
- Tests use the `Assert` class, `AgentGovTestDataFactory`, and assert behaviour, not
  execution. Security behaviour is proven with a restricted user from the factory
  (`createRestrictedUser`) under `System.runAs`.
- LWCs use `@wire` with `refreshApex`, `lwc:if`, SLDS 2 global styling hooks with SLDS 1
  fallbacks, ARIA on progress bars and alerts, and the shared `c/agentGovUtils` module.
- Prettier (with the Apex plugin) and ESLint are the formatters of record. Run
  `npm run prettier` and `npm run lint` before committing.

## Everyday commands

```bash
npm ci                         # toolchain
npm run lint                   # ESLint over LWC and mocks
npm run prettier:verify        # formatting check (prettier to fix)
npm run test:unit:coverage     # Jest for the Lightning components

sf org create scratch --definition-file config/project-scratch-def.json --alias agentgov-dev --duration-days 7 --set-default
sf project deploy start --source-dir force-app
sf org assign permset --name AgentGov_Admin
sf apex run test --test-level RunLocalTests --code-coverage --result-format human --wait 30
sf apex run --file scripts/setup/load-sample-data.apex
```

```bash
sf code-analyzer run --workspace force-app --config-file code-analyzer.yml --view detail
```

CI runs the same steps plus Salesforce Code Analyzer. Two notes on that job:

- The **PMD and CPD engines need a JDK 11 or later**. CI installs Temurin 21; without a
  local JDK those engines report themselves as uninstantiable, which the analyzer counts as
  a Critical violation. Install a JDK to reproduce the CI result locally.
- CI fails on any violation at **High severity or above**. The security rules that matter for
  this framework are elevated into that band in `code-analyzer.yml`: SOQL injection is
  Critical, and CRUD/FLS and sharing violations are High, so they stop the build.
- **Moderate findings are reported but do not gate.** They are complexity and parameter-count
  advisories on the budget ladder, the breaker state machine and the policy matcher, plus
  hardcoded Ids in test classes. Reducing them is on the roadmap. Do not raise the threshold
  without doing that work first: a gate the codebase cannot pass gets switched off, which is
  how this one sat inert for a release.

The Apex job needs the `SFDX_AUTH_URL` repository secret and is skipped without it.

## Release checklist

1. Update `CHANGELOG.md` (Keep a Changelog format; breaking and behaviour changes get
   their own subsection) and `docs/ROADMAP.md`.
2. Bump `version` in `package.json` to match the tag.
3. Tag `vX.Y.Z`; the release workflow verifies the version, attaches the deployable
   archive, and publishes the CHANGELOG section as the release notes.

## Things that are easy to get wrong

- Fields on permission sets: required fields and master-detail fields must not be listed,
  and lookups must be. The permission sets are the only way non-admins get access, because
  fields deployed through the Metadata API are not visible to any profile by default.
- `FOR UPDATE` with `WITH SYSTEM_MODE` is used for budgets and breaker rows; keep the
  locking query in the selector so the lock scope stays obvious.
- Platform-event triggers run in their own execution context. Tests that need to observe a
  side effect (for example an email) call the handler directly.
- `Budget_Key__c` is unique. Orgs upgrading from v1.1 must run
  `scripts/migrate/dedupe-budgets.apex` before deploying if they ever produced duplicates.
- Do not put org usernames, instance URLs, emails, or personal names into code, configs,
  docs, or commit messages. CI authenticates only through a repository secret.
