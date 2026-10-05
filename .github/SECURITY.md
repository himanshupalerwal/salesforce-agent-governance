# Security Policy

## Reporting a vulnerability

Please do not open a public GitHub issue for security vulnerabilities.

Use GitHub's private vulnerability reporting on this repository (Security tab → Report a
vulnerability) and include:

1. A description of the vulnerability
2. Steps to reproduce
3. The potential impact
4. A suggested fix, if you have one

Reports are acknowledged within 48 hours.

## Supported versions

| Version | Supported           |
| ------- | ------------------- |
| 1.3.x   | Yes                 |
| 1.2.x   | Security fixes only |
| 1.1.x   | No                  |
| 1.0.x   | No                  |

Support for 1.1.x ended with the release of v1.3.

## How AgentGov handles security

- **Access modes.** The framework's own records are read and written in system mode so an
  agent's user needs no access to AgentGov objects. Everything done on an agent's behalf
  against customer data runs in user mode, so the calling user's object permissions,
  field-level security, and sharing rules apply. See the **Security model** section of the
  README.
- **No SOQL from callers.** The proxy `/query` endpoint compiles a structured request into
  SOQL with bound values; relationship paths and subqueries cannot be expressed.
- **Credentials.** API keys are stored only as SHA-256 hashes. Prefer binding the agent's
  Salesforce user to its registration so the OAuth identity is the credential.
- **Errors.** An unexpected REST or proxy error (HTTP 500) never includes exception text or a
  stack trace. Everything the request wrote is rolled back, and the response carries a
  correlation id that finds the logged detail in the action log. Every other error is worded by the
  framework: a proxy `ACCESS_DENIED` names the object, or the fields, the calling user may
  not reach. The exception is a write's per-record result: each record the database rejects
  carries the database's own message in `results[].errors`, so the caller can correct it.

## Recommendations for production

- Authenticate REST callers through an External Client App (Connected Apps can no longer be
  created in most orgs) and bind the integration user to its registration.
- Send API keys in the `X-AgentGov-Key` header, never in URLs or logs, and rotate them with
  `POST /rotate-key`.
- Assign `AgentGov_Agent` to the users agents run as, `AgentGov_User` to people who need
  the dashboards, `AgentGov_User` plus `AgentGov_Responder` to on-call staff who act on
  agents from the console, and `AgentGov_Admin` (or the `AgentGov_Operators` group) only to
  administrators. Key rotation stays with holders of `AgentGov_Manage_Keys`, which
  `AgentGov_Admin` includes and `AgentGov_Responder` does not.
- Keep `Admin_Notification_Email__c` set and `Enable_Real_Time_Events__c` checked so budget
  and circuit-breaker alerts reach someone. With real-time events off, no alert is recorded or
  emailed.
- Review `AgentGov_Action_Log__c` entries with the `System` action type; they record
  delivery failures and unhandled errors.
