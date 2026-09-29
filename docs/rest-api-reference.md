# REST API Reference

AgentGov exposes two Apex REST resources for agents that run outside the org: the
**governance API** at `/services/apexrest/agentgov` (register, authorize, report, rotate a
key, read budget and health) and the **governed proxy** at
`/services/apexrest/agentgov-proxy` (query and CRUD executed on the agent's behalf, with
budget charged by the real record count).

---

## Authentication

Every call needs two things: a Salesforce session and an agent identity.

**1. A Salesforce OAuth 2.0 access token** in the `Authorization: Bearer <token>` header.
Obtain it through an External Client App (Connected Apps can no longer be created in most
orgs). The user the token belongs to must hold the `AgentGov_Agent` permission set, which
grants the two REST classes and nothing else; the framework records its own bookkeeping in
system mode.

**2. An agent identity**, resolved in this order:

| Credential                             | How                                                                                                                        | Status                                                                |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `X-AgentGov-Key` header                | The agent's API key. The legacy header name `X-AgentGov-API-Key` is accepted as an alias.                                  | Recommended for external agents                                       |
| `apiKey` in the JSON body              | Same key, in the body.                                                                                                     | **Deprecated**; responses carry a `deprecation` note; removed in v1.4 |
| No key, user bound to the registration | The token's user is set in `Agent_User__c` on the registration. Intended for Agentforce Agent Users and integration users. | Recommended when the agent has its own Salesforce user                |

Keys are never stored; only a SHA-256 hash and a short prefix are kept. A key created by a
release before v1.2 is upgraded to hashed storage the first time it is presented.

An agent authenticated by its Salesforce user rather than a key must be bound to exactly one
registration. A user bound to several is refused with `ACCESS_DENIED` (403) and must send
`X-AgentGov-Key`, because the login alone cannot say which agent is calling.

---

## Response envelope

Every response is JSON and carries a `correlationId`. Send your own in the
`X-Correlation-Id` request header and it is echoed back; otherwise one is generated. The id
is also returned as a response header, and every action-log row the request produces stores it
in `Correlation_Id__c`, so a request can be traced to its audit rows. Those rows also record
how long the request had taken and, for a refusal or failure, the reason.

**Success**

```json
{
  "success": true,
  "correlationId": "5f1c1a2e-...",
  "...endpoint payload..."
}
```

**Error**

```json
{
  "success": false,
  "errorCode": "BUDGET_EXCEEDED",
  "message": "Governor budget exceeded for limit type: DML_Operations",
  "correlationId": "5f1c1a2e-...",
  "timestamp": "2026-09-15T10:00:00.000Z"
}
```

| Code                   | HTTP | Meaning                                                                                                                                                                                                                                  |
| ---------------------- | ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `INVALID_INPUT`        | 400  | Missing or malformed request data, unknown object or field, unsupported operator                                                                                                                                                         |
| `AGENT_NOT_FOUND`      | 404  | No credential resolved to a registration, or an unknown path                                                                                                                                                                             |
| `AGENT_NOT_ACTIVE`     | 403  | The agent is deactivated (`Inactive`) or `Blocked`. A tripped circuit breaker sets `Blocked`, and the agent is admitted again once the cooldown has passed. Throttled agents are admitted                                                |
| `ACCESS_DENIED`        | 403  | The calling user lacks access to the requested data, is not allowed to read another agent, or calls without a key while bound to more than one registration                                                                              |
| `POLICY_VIOLATION`     | 403  | Denied by an `AgentGov_Policy__mdt` record, a restricted field, or a write over the record cap                                                                                                                                           |
| `BUDGET_EXCEEDED`      | 429  | The budget is Blocked or Exhausted                                                                                                                                                                                                       |
| `RECORD_LOCKED`        | 409  | A higher-priority agent holds the record in the same transaction. Not returned over REST today; see [Conflict detection](#conflict-detection)                                                                                            |
| `CIRCUIT_BREAKER_OPEN` | 503  | The breaker is HALF_OPEN and its single probe is already taken, or it is OPEN while the agent's status was set back to Active by hand                                                                                                    |
| `INTERNAL_ERROR`       | 500  | An unexpected failure. Everything the request wrote, budget charges included, is rolled back before the error row is recorded, so a retry cannot create anything twice. The details are logged under the `correlationId`, never returned |

`MAX_CONCURRENT_AGENTS` is not returned by any REST endpoint. Only activating an agent raises
it, through `AgentGovRegistryService.activateAgent` or `activateAgents` in Apex, or
**Activate** in the console.

---

## POST /agentgov/register

Registers an agent. No agent credential is required. New agents start `Inactive`; an
administrator activates them with `AgentGovRegistryService.activateAgent` or with **Activate**
in the console.

**Body**

| Field         | Type   | Required | Description                                                                                                                             |
| ------------- | ------ | -------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `agentName`   | String | Yes      | Display name                                                                                                                            |
| `agentType`   | String | Yes      | `Agentforce`, `MCP_External`, `Custom_Apex`, or `Flow_Based`                                                                            |
| `description` | String | No       | Purpose of the agent                                                                                                                    |
| `apiKey`      | String | No       | A key of your choosing, at least 24 characters and not in use by another agent. Omit it and AgentGov generates one and returns it once. |
| `ownerEmail`  | String | No       | Contact for the agent's owner, a valid email address                                                                                    |

The request is refused with `INVALID_INPUT` (400) when `agentName` is blank, `agentType` is not
one of the four types, a supplied `apiKey` is shorter than 24 characters or already in use, or
the database rejects a value, such as a malformed `ownerEmail`. Nothing is created.

**Response (201)** when the key was generated:

```json
{
  "success": true,
  "correlationId": "...",
  "registrationId": "a0B...",
  "registrationNumber": "AGT-0007",
  "status": "Inactive",
  "apiKey": "agk_3f9c...e2",
  "apiKeyPrefix": "agk_3f9c8a1b",
  "message": "Agent registered. Store the apiKey now; only its hash is kept and it cannot be retrieved later. Activate the agent to enable it."
}
```

When you supplied a key, the response carries `apiKeyPrefix` but not the key.

```bash
curl -X POST "$INSTANCE/services/apexrest/agentgov/register" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"agentName":"Lead Enrichment Agent","agentType":"MCP_External","ownerEmail":"owner@example.com"}'
```

---

## POST /agentgov/authorize

Runs the governance pipeline for one intended action and pre-charges the budget: circuit
breaker, policy, and budget. The agent then performs the action itself.

**Body**

| Field        | Type    | Required | Description                                                                                                                 |
| ------------ | ------- | -------- | --------------------------------------------------------------------------------------------------------------------------- |
| `objectName` | String  | Yes      | Object API name                                                                                                             |
| `operation`  | String  | Yes      | `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`, or `Flow_Trigger`                                              |
| `recordId`   | String  | No       | Record the action targets, stored on the audit row. See [Conflict detection](#conflict-detection)                           |
| `amount`     | Integer | No       | Units to pre-charge (default 1, minimum 1). `Query` charges SOQL, `API_Call` charges API calls, everything else charges DML |

**Response (200)**

```json
{
  "success": true,
  "correlationId": "...",
  "authorized": true,
  "agentId": "a0B...",
  "sessionId": "a0D...",
  "budgetStatus": "Normal",
  "remainingBudget": { "apiCalls": 9842, "soqlQueries": 4991, "dmlOperations": 2987 },
  "conflict": { "detected": false, "resolution": null }
}
```

`sessionId` is the agent's current session. Sessions open and close automatically: a session
collects one run of an agent's governed activity and closes after `Session_Idle_Minutes__c`
without activity (default 30) or after 24 hours, and the next call opens a new one.

`conflict` is present when `recordId` was sent, and reports `detected` as `false` for a REST
caller; see [Conflict detection](#conflict-detection).

Active and Throttled agents are admitted. When an agent's circuit breaker trips, the agent is
set to `Blocked` and refused with `AGENT_NOT_ACTIVE` (403) until the cooldown has passed. The
next request then moves the breaker to HALF_OPEN and is admitted as its single probe; other
requests are refused with `CIRCUIT_BREAKER_OPEN` (503) until the probe's outcome is reported
through `/report`. A probe that reports nothing within one cooldown period is treated as
abandoned, and the next request becomes the probe.

When `Is_Enabled__c` is unchecked (the emergency bypass), `/authorize` skips the circuit
breaker, policy, conflict and budget checks and charges nothing. `operation`, `objectName` and
`amount` are still validated and the call is still audited. The only agent refused is a
deactivated one, with `AGENT_NOT_ACTIVE`. The response reads the budget rather than charging
it, carries `"governanceEnabled": false`, and has no `sessionId` and no `conflict`. Clients
should keep reading `authorized`.

```json
{
  "success": true,
  "correlationId": "...",
  "authorized": true,
  "agentId": "a0B...",
  "budgetStatus": "Normal",
  "remainingBudget": { "apiCalls": 9842, "soqlQueries": 4991, "dmlOperations": 2987 },
  "governanceEnabled": false
}
```

```bash
curl -X POST "$INSTANCE/services/apexrest/agentgov/authorize" \
  -H "Authorization: Bearer $TOKEN" -H "X-AgentGov-Key: $AGENT_KEY" -H "Content-Type: application/json" \
  -d '{"objectName":"Lead","operation":"Update","recordId":"00Q...","amount":10}'
```

Denials are written to the action log with status `Denied`, including refusals of an agent that
is inactive or whose circuit breaker has tripped.

---

## POST /agentgov/report

Reports what the agent actually consumed and, optionally, the outcome of the work. The agent
is admitted on the same terms as for `/authorize`.

Only usage **beyond** what was already pre-authorized is charged. Unused pre-authorization is
**not** credited back: both figures come from the caller in the same request and the framework
keeps no record of what an agent reserved, so honouring a credit would let any agent clear its
own ledger. Budget corrections are an administrative action through
`AgentGovBudgetManager.creditBudget`. The agent is denied with `BUDGET_EXCEEDED` if the
reported usage leaves the budget Blocked or Exhausted.

All counts must be zero or positive. A negative figure is rejected with `INVALID_INPUT` (400).

**Body**

| Field           | Type    | Required | Description                                                                                                    |
| --------------- | ------- | -------- | -------------------------------------------------------------------------------------------------------------- |
| `actual`        | Object  | Yes      | `apiCalls`, `soqlQueries`, `dmlOperations` actually used                                                       |
| `preAuthorized` | Object  | No       | The same keys as `actual`, holding what `/authorize` pre-charged for this work. Only usage above it is charged |
| `success`       | Boolean | No       | Outcome of the work, reported to the circuit breaker                                                           |

```bash
curl -X POST "$INSTANCE/services/apexrest/agentgov/report" \
  -H "Authorization: Bearer $TOKEN" -H "X-AgentGov-Key: $AGENT_KEY" -H "Content-Type: application/json" \
  -d '{"actual":{"dmlOperations":7,"soqlQueries":2},"preAuthorized":{"dmlOperations":10},"success":true}'
```

Sending `success` is how an agent that uses `/authorize` closes a circuit breaker it tripped.
A breaker in HALF_OPEN admits one probe; reporting `true` closes it and returns the agent to
Active, and reporting `false` re-opens it with a doubled cooldown.

While `Is_Enabled__c` is unchecked, a report charges nothing, `success` is not passed to the
circuit breaker, and the response carries the current budget. The report is still audited.

**Response (200)**: `budgetStatus`, `remainingBudget`, and `circuitBreakerState`.

---

## POST /agentgov/rotate-key

Issues a replacement API key for the calling agent. The previous key stops working
immediately. Authenticate with the current key or the bound user. Active and Throttled agents
may rotate their key; any other status is refused with `AGENT_NOT_ACTIVE`, so deactivating an
agent whose key has leaked also stops the holder from issuing a new one. An administrator can
rotate a key with **Rotate key** in the console, which needs the AgentGov Manage Keys
permission.

**Response (200)**

```json
{
  "success": true,
  "correlationId": "...",
  "apiKey": "agk_...",
  "apiKeyPrefix": "agk_9d2e4b7c",
  "rotatedAt": "2026-09-15T10:00:00.000Z",
  "message": "Store the new apiKey now; the previous key no longer authenticates."
}
```

---

## GET /agentgov/budget/{registrationId}

Returns the agent's budget for today, counted in the org's time zone, creating the row if this
is the first read of the day. The caller must be that agent (key header or bound user) or hold the
`AgentGov_Admin_Access` custom permission.

**Response (200)**

```json
{
  "success": true,
  "correlationId": "...",
  "agentId": "a0B...",
  "budgetStatus": "Warning",
  "allowed": true,
  "remaining": { "apiCalls": 1580, "soqlQueries": 920, "dmlOperations": 450 },
  "usagePercent": { "apiCalls": 84.2, "soqlQueries": 81.6, "dmlOperations": 85.0 }
}
```

## GET /agentgov/health/{registrationId}

Returns status and circuit breaker state, with the same access rule as `/budget`.

```json
{
  "success": true,
  "correlationId": "...",
  "agentId": "a0B...",
  "agentName": "Lead Enrichment Agent",
  "status": "Active",
  "circuitBreakerState": "CLOSED",
  "failureCount": 0,
  "lastFailure": null,
  "cooldownUntil": null,
  "lastActive": "2026-09-15T09:58:12.000Z"
}
```

---

## The governed proxy: /agentgov-proxy

The proxy executes operations on the agent's behalf, so budget is charged by the real
record count. Every endpoint runs: authentication and status check → circuit breaker → policy
(object, operation, field restrictions, record cap) → budget → execution in user mode → audit
log → breaker outcome.

The proxy admits agents on the same terms as `/authorize`: Active and Throttled agents (a
Throttled agent is one whose breaker is probing recovery), and a Blocked agent whose breaker
cooldown has passed, as the breaker's single probe. A deactivated agent, or a Blocked one inside
its cooldown, is refused with `AGENT_NOT_ACTIVE`.

Everything runs in **user mode**: the token's user must have the object permissions,
field-level security, and sharing access for the data involved. Where access is checked
depends on the endpoint:

- `/create`, `/update` and `/upsert` check object and field access before charging. Missing
  access returns `ACCESS_DENIED`, naming the object or the fields the user may not reach, in
  the framework's own words; nothing is charged and no record is written.
- `/query` charges its one SOQL unit and then runs the query in user mode, so a query refused
  with `ACCESS_DENIED` still costs that unit. Its message names the object or the fields that
  were refused.
- `/delete` has no access pre-check. Its DML units are charged before the delete runs in user
  mode.

A write with more records than the policy's record cap is rejected with `POLICY_VIOLATION`
before anything is charged or any record is written. A query is capped instead: see `limit`
below. Writes that carry Ids are
also checked for conflicts, but a proxy request serves one agent, so it is never refused because
of another agent's request; see [Conflict detection](#conflict-detection).

Each governed call leaves an action-log row with status `Success`, `Failure` (every record in a
write failed), or `Denied`. A request refused with `INVALID_INPUT` (400), or whose credential
does not resolve to an agent, leaves no row. A request that fails with a 500 is rolled back and
leaves only a `System` row under its correlation id.

While `Is_Enabled__c` is unchecked, the proxy skips the circuit breaker, policy (including field
restrictions and record caps), conflict and budget checks, charges nothing, and records no
breaker outcome. The calling user's own access still applies, and the only agent refused is a
deactivated one. No session activity is recorded, so write responses carry a `null`
`sessionId`.

### POST /agentgov-proxy/query

Runs a structured query. SOQL text is not accepted; a `query` property returns 400.

**Body**

| Field        | Type    | Required | Description                                                                                                                                                                                                                           |
| ------------ | ------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `objectName` | String  | Yes      | Object API name                                                                                                                                                                                                                       |
| `fields`     | Array   | Yes      | Field API names on that object. Relationship paths (`Owner.Name`) and subqueries are not accepted.                                                                                                                                    |
| `where`      | Array   | No       | Conditions `{ "field", "op", "value" }`, combined with AND. Operators: `=`, `!=`, `<`, `<=`, `>`, `>=`, `LIKE`, `IN`, `NOT IN`. `IN`/`NOT IN` take an array. Values are bound, never concatenated, and converted to the field's type. |
| `orderBy`    | Object  | No       | `{ "field", "direction" }` with `ASC` (default) or `DESC`                                                                                                                                                                             |
| `limit`      | Integer | No       | Rows to return. Default 200. The query returns at most the smallest of this value, the policy's record cap, and 2,000; a larger value is lowered, not refused.                                                                        |

```bash
curl -X POST "$INSTANCE/services/apexrest/agentgov-proxy/query" \
  -H "Authorization: Bearer $TOKEN" -H "X-AgentGov-Key: $AGENT_KEY" -H "Content-Type: application/json" \
  -d '{
    "objectName": "Account",
    "fields": ["Id", "Name", "Industry"],
    "where": [
      { "field": "Industry", "op": "IN", "value": ["Energy", "Retail"] },
      { "field": "CreatedDate", "op": ">=", "value": "2026-01-01T00:00:00.000Z" }
    ],
    "orderBy": { "field": "Name", "direction": "ASC" },
    "limit": 50
  }'
```

**Response (200)**: `totalSize`, `records`, `budgetStatus`, `remainingBudget`. A query
response has no `sessionId`. One SOQL query is charged, before the query runs, whatever the
number of rows.

### POST /agentgov-proxy/create

**Body**: `objectName`, `records` (array of objects keyed by field API name). Unknown
fields are rejected with 400; an `attributes` key is ignored so records copied from a
query response can be resubmitted. Charges one DML unit per record.

**Response (200)**

```json
{
  "success": true,
  "correlationId": "...",
  "allSucceeded": true,
  "recordsProcessed": 3,
  "recordsSucceeded": 3,
  "results": [
    { "success": true, "id": "001..." },
    { "success": true, "id": "001..." },
    { "success": true, "id": "001..." }
  ],
  "sessionId": "a0D...",
  "budgetStatus": "Normal",
  "remainingBudget": { "apiCalls": 10000, "soqlQueries": 5000, "dmlOperations": 2997 }
}
```

Per-record failures appear as `{ "success": false, "errors": ["..."] }`; the HTTP status
stays 200 because the request itself was processed. Every write endpoint returns this shape,
including `sessionId`, the agent's current session as on `/authorize`.

### POST /agentgov-proxy/update

**Body**: `objectName`, `records`; every record must carry an `Id` that belongs to
`objectName`.

### POST /agentgov-proxy/delete

**Body**: `objectName`, `ids` (array). Each Id must belong to `objectName`.

### POST /agentgov-proxy/upsert

**Body**: `objectName`, `records`, optional `externalIdField` (must be an External ID
field). Results include `created` per record.

---

## Conflict detection

AgentGov detects conflicts between agents that work on the same record within one transaction,
and resolves them by priority (the lower number wins). In practice that is a Register Agent
Action batch in Flow in which several agents name the same record. Each REST or proxy request
serves one agent in its own transaction, so a REST caller is never refused with
`RECORD_LOCKED` because of another agent's request, and two agents writing the same record
through separate requests are not stopped by AgentGov. Locking across requests is on the
roadmap for v2.0.

---

## Rate limiting

AgentGov enforces daily budgets per agent. It does not support per-minute rate limits.
Salesforce's own API limits still apply to the OAuth session.
