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

4. **Install Node dependencies (for LWC tests):**

   ```bash
   npm install
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

- **Classes:** PascalCase (e.g., `AgentGovernanceService`)
- **Methods:** camelCase (e.g., `calculateRiskScore`)
- **Variables:** camelCase (e.g., `registrationList`)
- **Constants:** UPPER_SNAKE_CASE (e.g., `MAX_RETRY_COUNT`)
- **Test classes:** Suffix with `Test` (e.g., `AgentGovernanceServiceTest`)
- **Custom objects:** PascalCase with `__c` suffix (e.g., `Agent_Registration__c`)
- **Custom fields:** PascalCase with `__c` suffix (e.g., `Risk_Score__c`)

### Code Practices

- **No SOQL or DML inside loops.** Use collections and bulk patterns.
- **No hardcoded IDs.** Use Custom Metadata, Custom Settings, or describe calls.
- **Use meaningful variable and method names.** Avoid abbreviations.
- **Add comments** for complex logic, but prefer self-documenting code.
- **Keep methods short and focused.** Each method should do one thing.
- **Use `with sharing`** by default. Only use `without sharing` when explicitly required and documented.
- **Handle exceptions gracefully.** Log errors using a consistent pattern.
- **Avoid global access modifiers** unless building a managed package API.

### LWC Conventions

- Use camelCase for component names and properties.
- Keep components small and composable.
- Use `@wire` for data access where possible.
- Include JSDoc comments for public API properties and methods.

## Test Requirements

- **Minimum 90% code coverage** for all Apex classes. Aim for 95%+.
- **Every PR must include tests** that cover the new or modified functionality.
- **Test both positive and negative scenarios**, including bulk operations (200+ records).
- **Use `@TestSetup`** methods to create reusable test data.
- **Do not use `SeeAllData=true`** unless absolutely necessary and justified.
- **Assert meaningful outcomes**, not just the absence of exceptions.
- **Test trigger handlers** with single and bulk record operations.
- Run `sf apex run test -l RunLocalTests` and confirm all tests pass before submitting.

## Questions?

If you have questions about contributing, feel free to open a discussion or reach out by opening an issue with the `question` label.

Thank you for helping make AgentGov better!
