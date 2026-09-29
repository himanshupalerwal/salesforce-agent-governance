# Contributing to AgentGov

Thank you for your interest in contributing to AgentGov! This document provides guidelines and instructions for contributing to this project.

## Table of Contents

- [Reporting Bugs](#reporting-bugs)
- [Suggesting Features](#suggesting-features)
- [Development Setup](#development-setup)
- [Security Model](#security-model)
- [Everyday Commands](#everyday-commands)
- [Pull Request Process](#pull-request-process)
- [Code Style Guidelines](#code-style-guidelines)
- [Test Requirements](#test-requirements)
- [Release Checklist](#release-checklist)
- [Things That Are Easy to Get Wrong](#things-that-are-easy-to-get-wrong)

## Reporting Bugs

If you find a bug, please open an issue using the [Bug Report template](https://github.com/himanshupalerwal/salesforce-agent-governance/issues/new?template=bug_report.md). Include as much detail as possible:

- A clear, descriptive title prefixed with `[BUG]`
- Steps to reproduce the issue
- Expected behavior vs. actual behavior
- Your environment (Salesforce edition, API version, browser)
- Screenshots or error logs if available

## Suggesting Features

Feature requests are welcome! Please use the [Feature Request template](https://github.com/himanshupalerwal/salesforce-agent-governance/issues/new?template=feature_request.md) and include:

- A clear description of the feature
- The problem it solves or the use case it addresses
- Any proposed implementation approach
- Whether you are willing to work on it

## Development Setup

### Prerequisites

- Salesforce CLI (`sf`) installed and up to date
- A Salesforce DevHub-enabled org
- Git
- Node.js 20+ (for LWC testing)
- Visual Studio Code with Salesforce Extension Pack (recommended)

### Getting Started

1. **Fork and clone the repository:**

   ```bash
   git clone https://github.com/<your-username>/salesforce-agent-governance.git
   cd salesforce-agent-governance
   ```

2. **Authenticate with your DevHub:**

   ```bash
   sf org login web -d -a DevHub
   ```

3. **Run the setup script:**

   ```bash
   ./scripts/setup/create-scratch-org.sh
   ```

   This will create a scratch org, deploy the source, assign permission sets, and load sample data.

4. **Install Node dependencies (lint, formatting, LWC tests):**

   ```bash
   npm ci
   ```

5. **Start developing!** Make changes in `force-app/` and push to your scratch org:

   ```bash
   sf project deploy start -o AgentGov
   ```

## Security Model

This is the rule that matters most. The framework runs at API 67.0, where database operations
default to user mode, and AgentGov splits its work deliberately:

| Code path                                                                                                                                   | Sharing             | Access mode       | Why                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AgentGovSelector`, `AgentGovDml`, `AgentGovCleanup`                                                                                        | `without sharing`   | `SYSTEM_MODE`     | The framework's own ledger (registrations, budgets, sessions, logs, policies) must be readable and writable regardless of who triggered the governed action. Agent Users and integration users normally hold no access to AgentGov objects. Custom metadata is read here too, so a caller without metadata access cannot make policies disappear. |
| `AgentGovProxyApi`                                                                                                                          | `with sharing`      | `USER_MODE`       | Everything done on an agent's behalf against customer data respects the calling user's CRUD, FLS, and sharing. Queries are compiled by `AgentGovQueryBuilder` from a structured request and executed with bind variables; SOQL text from callers is never accepted.                                                                               |
| `AgentGovDashboardController`                                                                                                               | `with sharing`      | `USER_MODE`       | Dashboards show people only what they may see.                                                                                                                                                                                                                                                                                                    |
| `AgentGovAdminController`                                                                                                                   | `with sharing`      | `USER_MODE` reads | Console actions. Each method checks `AgentGov_Operate_Agents` (or `AgentGov_Manage_Keys` for key rotation) on the server first, reads its target records in user mode so people act only on agents they can see, writes through the service classes, and records an `Admin` action-log row in the same transaction, all or nothing.               |
| Service classes (`BudgetManager`, `CircuitBreaker`, `PolicyEngine`, `RegistryService`, `SessionTracker`, `Context`, `TriggerHandler`, jobs) | `inherited sharing` | none directly     | They touch no data themselves; all reads go through the selector and all writes through `AgentGovDml`.                                                                                                                                                                                                                                            |

Never add a bare SOQL or DML statement to a service class. Never read customer data in
system mode. Never return raw exception text to a REST caller; use `AgentGovRestResponder`.

Two conventions follow from it. Strings and defaults live in `AgentGovConstants`, and errors
are `AgentGovException` with an `ErrorCode`, which maps to the REST HTTP status. And
everything is bulk first: invocable actions and service methods accept collections and issue
one query and one DML per object per transaction.

## Everyday Commands

```bash
npm ci                         # toolchain
npm run lint                   # ESLint over LWC, Jest mocks and the e2e suite
npm run prettier:verify        # formatting check (npm run prettier to fix)
npm run test:unit:coverage     # Jest for the Lightning components

sf project deploy start --source-dir force-app --target-org AgentGov
sf org assign permset --name AgentGov_Admin --target-org AgentGov
sf apex run test --test-level RunLocalTests --code-coverage --result-format human --wait 30 --target-org AgentGov
sf apex run --file scripts/setup/load-sample-data.apex --target-org AgentGov
sf apex run --file scripts/setup/schedule-jobs.apex --target-org AgentGov   # unschedule-jobs.apex before any deploy
```

```bash
npm run e2e -- --target-org AgentGov          # end-to-end suite against a real org (docs/testing-guide.md)
npm run e2e:upgrade                           # upgrade rehearsal from v1.1 in a temporary org
npm run e2e:upgrade -- --from v1.2            # the same from v1.2
npm run e2e:compare -- <before.json> <after.json>
```

A feature is done when its end-to-end checks pass in a real scratch org, not when its Apex
and Jest tests pass. Add or extend a check in `e2e/` for every behaviour a caller or an
administrator can observe.

```bash
sf code-analyzer run --workspace force-app --config-file code-analyzer.yml --view detail --severity-threshold 2
```

CI runs lint, the Prettier check, Jest and Salesforce Code Analyzer on every push, and the
Apex tests with the 85% coverage gate when its secret is set. It does not run the end-to-end
suite. Three notes on the analyzer job:

- The **PMD and CPD engines need a JDK 11 or later**. CI installs Temurin 21; without a
  local JDK those engines report themselves as uninstantiable, which the analyzer counts as
  a Critical violation. Install a JDK to reproduce the CI result locally.
- CI fails on any violation at **High severity or above**; `--severity-threshold 2` is what
  makes the command exit non-zero. The security rules that matter for this framework are
  elevated into that band in `code-analyzer.yml`: SOQL injection is Critical, and CRUD/FLS
  and sharing violations are High, so they stop the build.
- **Moderate findings are reported but do not gate.** They are mostly method-complexity and
  parameter-count advisories across the core services, plus hardcoded Ids in test classes.
  Reducing them is on the roadmap. Do not raise the threshold without doing that work first:
  a gate the codebase cannot pass gets switched off, which is how this one sat inert for a
  release.

The Apex job needs the `SFDX_AUTH_URL` repository secret and is skipped without it.

## Pull Request Process

1. **Create a feature branch** from `main`:

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** and ensure they follow the code style guidelines below.

3. **Write or update tests** to cover your changes. All tests must pass. Every behavior a
   caller or an administrator can observe also needs a check in `e2e/`: a feature is done when
   its end-to-end checks pass in a real scratch org, not when its Apex and Jest tests pass.

4. **Run tests locally** in your scratch org, including the end-to-end suite:

   ```bash
   sf apex run test -o AgentGov -l RunLocalTests -r human -w 10
   npm run e2e -- --target-org AgentGov
   ```

   See the [Testing Guide](docs/testing-guide.md) for what the suite needs and what each check
   proves.

5. **Push your branch** and open a Pull Request against `main`.

6. **Fill out the PR template** completely, including:
   - Description of changes
   - Type of change
   - Testing performed
   - All checklist items confirmed

7. **Address review feedback** promptly. A maintainer will review your PR and may request changes.

8. PRs require at least one approving review before merging.

## Code Style Guidelines

Follow standard Apex conventions to keep the codebase consistent and readable.

### Naming Conventions

- **Classes:** PascalCase with the `AgentGov` prefix (e.g., `AgentGovBudgetManager`)
- **Methods:** camelCase (e.g., `calculateRiskScore`)
- **Variables:** camelCase (e.g., `registrationList`)
- **Constants:** UPPER_SNAKE_CASE (e.g., `MAX_RETRY_COUNT`)
- **Test classes:** Suffix with `Test` (e.g., `AgentGovBudgetManagerTest`)
- **Custom objects:** `AgentGov_` prefix with `__c` suffix (e.g., `AgentGov_Registration__c`)
- **Custom fields:** capitalized words joined by underscores, with the `__c` suffix (e.g., `Is_Enabled__c`, `Circuit_Breaker_State__c`)

### Code Practices

- **No SOQL or DML inside loops.** Use collections and bulk patterns.
- **No hardcoded IDs.** Use Custom Metadata, Custom Settings, or describe calls.
- **Use meaningful variable and method names.** Avoid abbreviations.
- **Add comments** only where the reason is not obvious (a locking choice, a security decision, a fixed bug), in one or two plain sentences. No version tags, no chatty notes, no commented-out code.
- **Keep methods short and focused.** Each method should do one thing.
- **State the security posture of every class.** Framework bookkeeping reads through `AgentGovSelector` and writes through `AgentGovDml` (system mode); anything on an agent's behalf runs in user mode; service classes are `inherited sharing` and never issue SOQL or DML directly. See [Security Model](#security-model) for the full rules.
- **Never execute anything a caller sends.** Queries are compiled from structured input with bound values.
- **Deny loudly.** Errors are `AgentGovException` with an `ErrorCode`. Never return raw exception text to a REST caller: `AgentGovRestResponder` logs an unexpected error under a correlation id and returns only that id. Framework-level failures become `System` rows in the action log; there is no `System.debug` in production paths.
- **Document intent.** ApexDoc on every class and public method in the existing `@description` / `@param` / `@return` style; inline comments only where the reason is not obvious.
- **Avoid global access modifiers** unless building a managed package API.

### LWC Conventions

- Use camelCase for component names and properties.
- Keep components small and composable.
- Use `@wire` with `refreshApex` for cacheable Apex, `lwc:if` for conditionals, and the shared `c/agentGovUtils` module for errors, subscriptions, and formatting.
- Import the shared stylesheet at the top of each component's CSS (`@import 'c/agentGovStyles';`) and use its state pills, key figure tiles, loading placeholders, and empty states rather than restyling them.
- Style with SLDS 2 global styling hooks and SLDS 1 fallbacks; never hardcode colors.
- Keep progress bars and alerts accessible (`role`, `aria-*`, `alternative-text`).
- Include JSDoc comments for public API properties and methods.

## Test Requirements

- **Org-wide Apex coverage of 85% or higher**, and no class below that; Jest thresholds are enforced by `npm run test:unit:coverage`. CI enforces the org-wide figure on this repository's branches when the `SFDX_AUTH_URL` secret is configured. Pull requests from forks never receive that secret, so the Apex job is skipped for them: fork contributors run the Apex tests with coverage in their own scratch org.
- **Use the `Assert` class** (`Assert.areEqual`, `Assert.isTrue`, `Assert.fail`), never `System.assert*`.
- **Every PR must include tests** that cover the new or modified functionality.
- **Test both positive and negative scenarios**, including bulk operations (200+ records).
- **Use `@TestSetup`** methods to create reusable test data.
- **Do not use `SeeAllData=true`** unless absolutely necessary and justified.
- **Assert meaningful outcomes**, not just the absence of exceptions.
- **Test trigger handlers** with single and bulk record operations.
- **Prove security behavior with a restricted user**: `AgentGovTestDataFactory.createRestrictedUser(...)` under `System.runAs`.
- **Add an end-to-end check in `e2e/`** for every behavior a caller or an administrator can observe.
- Run `npm run lint`, `npm run prettier:verify`, `npm run test:unit:coverage`, `sf apex run test -l RunLocalTests --code-coverage`, and `npm run e2e -- --target-org <scratch-alias>` before submitting. All of them must pass.

## Release Checklist

1. Update `CHANGELOG.md` (Keep a Changelog format; breaking and behaviour changes get
   their own subsection) and `docs/ROADMAP.md`. Replace `Unreleased` in the version heading
   with the release date.
2. Run `npm run e2e` against a new scratch org and `npm run e2e:upgrade`; both must pass.
3. Bump `version` in `package.json` to match the tag.
4. Tag `vX.Y.Z`; the release workflow verifies the version, attaches the deployable
   archive, and publishes the CHANGELOG section as the release notes.

## Things That Are Easy to Get Wrong

- Fields on permission sets: required fields and master-detail fields must not be listed,
  and lookups must be. The permission sets are the only way non-admins get access, because
  fields deployed through the Metadata API are not visible to any profile by default.
- `FOR UPDATE` with `WITH SYSTEM_MODE` is used for budgets and breaker rows; keep the
  locking query in the selector so the lock scope stays obvious.
- Platform-event triggers run in their own execution context. Tests that need to observe a
  side effect (for example an email) call the handler directly.
- `Budget_Key__c` is unique. Orgs upgrading from v1.1 must run
  `scripts/migrate/dedupe-budgets.apex` before deploying if they ever produced duplicates.
- `Active_Session_Key__c` is unique, so an agent can have one active session. Tests and seed
  data must not insert two active sessions for one agent; end the first or use a second agent.
- Scheduled jobs block the deploy of every class they use. Run
  `scripts/setup/unschedule-jobs.apex` before deploying and `schedule-jobs.apex` after.
- Budget days are counted in the org's time zone (`AgentGovBudgetManager.budgetDate()`), never
  with `Date.today()`, which is the running user's day.
- The `Assert` class rejects a null failure message. Do not pass a value that is null when the
  assertion succeeds, such as a denial reason, as the message.
- Do not put org usernames, instance URLs, emails, or personal names into code, configs,
  docs, or commit messages. CI authenticates only through a repository secret.

## Questions?

If you have questions about contributing, feel free to open a discussion or reach out by opening an issue with the `question` label.

Thank you for helping make AgentGov better!

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By taking part you agree to uphold it.
