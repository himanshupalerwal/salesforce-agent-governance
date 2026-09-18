# Contributing to AgentGov

Thank you for your interest in contributing to AgentGov! This document provides guidelines and instructions for contributing to this project.

## Table of Contents

- [Reporting Bugs](#reporting-bugs)
- [Suggesting Features](#suggesting-features)
- [Development Setup](#development-setup)
- [Pull Request Process](#pull-request-process)
- [Code Style Guidelines](#code-style-guidelines)
- [Test Requirements](#test-requirements)

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

## Pull Request Process

1. **Create a feature branch** from `main`:

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** and ensure they follow the code style guidelines below.

3. **Write or update tests** to cover your changes. All tests must pass.

4. **Run tests locally** in your scratch org:

   ```bash
   sf apex run test -o AgentGov -l RunLocalTests -r human -w 10
   ```

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
- **Custom fields:** PascalCase with `__c` suffix (e.g., `Risk_Score__c`)

### Code Practices

- **No SOQL or DML inside loops.** Use collections and bulk patterns.
- **No hardcoded IDs.** Use Custom Metadata, Custom Settings, or describe calls.
- **Use meaningful variable and method names.** Avoid abbreviations.
- **Add comments** for complex logic, but prefer self-documenting code.
- **Keep methods short and focused.** Each method should do one thing.
- **State the security posture of every class.** Framework bookkeeping reads through `AgentGovSelector` and writes through `AgentGovDml` (system mode); anything on an agent's behalf runs in user mode; service classes are `inherited sharing` and never issue SOQL or DML directly. See `CLAUDE.md` for the full rules.
- **Never execute anything a caller sends.** Queries are compiled from structured input with bound values.
- **Deny loudly.** Errors are `AgentGovException` with an `ErrorCode`; REST callers never see exception text. Framework-level failures become `System` rows in the action log; there is no `System.debug` in production paths.
- **Document intent.** ApexDoc on every class and public method in the existing `@description` / `@param` / `@return` style; inline comments only where the reason is not obvious.
- **Avoid global access modifiers** unless building a managed package API.

### LWC Conventions

- Use camelCase for component names and properties.
- Keep components small and composable.
- Use `@wire` with `refreshApex` for cacheable Apex, `lwc:if` for conditionals, and the shared `c/agentGovUtils` module for errors, subscriptions, and formatting.
- Style with SLDS 2 global styling hooks and SLDS 1 fallbacks; never hardcode colors.
- Keep progress bars and alerts accessible (`role`, `aria-*`, `alternative-text`).
- Include JSDoc comments for public API properties and methods.

## Test Requirements

- **Org-wide Apex coverage of 85% or higher** (CI enforces it) and no class below that; Jest thresholds are enforced by `npm run test:unit:coverage`.
- **Use the `Assert` class** (`Assert.areEqual`, `Assert.isTrue`, `Assert.fail`), never `System.assert*`.
- **Every PR must include tests** that cover the new or modified functionality.
- **Test both positive and negative scenarios**, including bulk operations (200+ records).
- **Use `@TestSetup`** methods to create reusable test data.
- **Do not use `SeeAllData=true`** unless absolutely necessary and justified.
- **Assert meaningful outcomes**, not just the absence of exceptions.
- **Test trigger handlers** with single and bulk record operations.
- **Prove security behavior with a restricted user**: `AgentGovTestDataFactory.createRestrictedUser(...)` under `System.runAs`.
- Run `npm run lint`, `npm run prettier:verify`, `npm run test:unit:coverage`, and `sf apex run test -l RunLocalTests --code-coverage` before submitting.

## Questions?

If you have questions about contributing, feel free to open a discussion or reach out by opening an issue with the `question` label.

Thank you for helping make AgentGov better!

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By taking part you agree to uphold it.
