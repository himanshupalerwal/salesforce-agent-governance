# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in AgentGov, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please email the maintainer directly with:

1. Description of the vulnerability
2. Steps to reproduce
3. Potential impact
4. Suggested fix (if any)

We will acknowledge your report within 48 hours and work with you to understand and address the issue.

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | Yes       |

## Security Best Practices

When using AgentGov in production:

- Use Salesforce Connected App OAuth for REST API authentication (not just API keys)
- Restrict `AgentGov_Admin` permission set to trusted administrators only
- Monitor `AgentGov_Alert__e` platform events for suspicious activity
- Regularly review `AgentGov_Action_Log__c` for unauthorized actions
- Keep the `API_Key__c` field values confidential
