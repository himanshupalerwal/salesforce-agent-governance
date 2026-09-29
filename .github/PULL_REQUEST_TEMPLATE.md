## Description

What this change does and why.

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Enhancement
- [ ] Refactoring
- [ ] Documentation
- [ ] Test coverage

## Testing

How you verified the change (Apex tests, Jest, the end-to-end suite, manual steps in a scratch org).

## Checklist

- [ ] Every class states its sharing keyword and access mode; framework bookkeeping goes through `AgentGovSelector` and `AgentGovDml`, and nothing reads customer data in system mode
- [ ] No bare SOQL or DML in service classes; no SOQL text accepted from callers
- [ ] Strings and defaults live in `AgentGovConstants`; errors are `AgentGovException` with an `ErrorCode`
- [ ] No SOQL or DML inside loops; invocable actions stay bulk-safe
- [ ] No hardcoded record Ids, org usernames, instance URLs, or email addresses
- [ ] ApexDoc on every new or changed class and public method
- [ ] Tests use the `Assert` class and `AgentGovTestDataFactory`, and assert behavior
- [ ] `npm run lint`, `npm run prettier:verify`, and `npm run test:unit:coverage` pass
- [ ] Apex tests pass in a scratch org with coverage at or above 85%
- [ ] Every new behavior a caller or an administrator can observe has a check in `e2e/`
- [ ] `npm run e2e -- --target-org <scratch-alias>` passes
- [ ] `CHANGELOG.md` and the relevant docs are updated
