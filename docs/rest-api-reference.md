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
| `apiKey` in the JSON body              | Same key, in the body.                                                                                                     | **Deprecated**; responses carry a `deprecation` note; removed in v1.3 |
| No key, user bound to the registration | The token's user is set in `Agent_User__c` on the registration. Intended for Agentforce Agent Users and integration users. | Recommended when the agent has its own Salesforce user                |

Keys are never stored; only a SHA-256 hash and a short prefix are kept. A key created by a
release before v1.2 is upgraded to hashed storage the first time it is presented.

---

## Response envelope

Every response is JSON and carries a `correlationId`. Send your own in the
`X-Correlation-Id` request header and it is echoed back; otherwise one is generated. The id
is also returned as a response header.

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

| Code                    | HTTP | Meaning                                                                                      |
| ----------------------- | ---- | -------------------------------------------------------------------------------------------- |
| `INVALID_INPUT`         | 400  | Missing or malformed request data, unknown object or field, unsupported operator             |
| `AGENT_NOT_FOUND`       | 404  | No credential resolved to a registration, or an unknown path                                 |
| `AGENT_NOT_ACTIVE`      | 403  | The agent exists but is not Active (the proxy also admits Throttled agents)                  |
| `ACCESS_DENIED`         | 403  | The calling user lacks access to the requested data, or is not allowed to read another agent |
| `POLICY_VIOLATION`      | 403  | Denied by an `AgentGov_Policy__mdt` record, a restricted field, or a record cap              |
| `BUDGET_EXCEEDED`       | 429  | The budget is Blocked or Exhausted                                                           |
| `MAX_CONCURRENT_AGENTS` | 429  | The org's concurrent active-agent limit is reached                                           |
| `RECORD_LOCKED`         | 409  | A higher-priority agent holds the record in this transaction                                 |
| `CIRCUIT_BREAKER_OPEN`  | 503  | The agent's circuit breaker is OPEN                                                          |
| `INTERNAL_ERROR`        | 500  | An unexpected failure; the details are logged under the `correlationId`, never returned      |

---

## POST /agentgov/register

Registers an agent. No agent credential is required. New agents start `Inactive`; an
administrator activates them with `AgentGovRegistryService.activateAgent`.

**Body**

| Field         | Type   | Required | Description                                                                     |
| ------------- | ------ | -------- | ------------------------------------------------------------------------------- |
| `agentName`   | String | Yes      | Display name                                                                    |
| `agentType`   | String | Yes      | `Agentforce`, `MCP_External`, `Custom_Apex`, or `Flow_Based`                    |
| `description` | String | No       | Purpose of the agent                                                            |
| `apiKey`      | String | No       | A key of your choosing. Omit it and AgentGov generates one and returns it once. |
| `ownerEmail`  | String | No       | Contact for the agent's owner                                                   |

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

Runs the governance pipeline for one intended action and pre-charges the budget:
circuit breaker, policy, conflict detection (when a `recordId` is given), and budget. The
conflict check runs before the charge, so a request refused with `RECORD_LOCKED` costs the
agent nothing. The agent then performs the action itself.

**Body**

| Field        | Type    | Required | Description                                                                                                                 |
| ------------ | ------- | -------- | --------------------------------------------------------------------------------------------------------------------------- |
| `objectName` | String  | Yes      | Object API name                                                                                                             |
| `operation`  | String  | Yes      | `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`, or `Flow_Trigger`                                              |
| `recordId`   | String  | No       | Record the action targets; enables conflict detection                                                                       |
| `amount`     | Integer | No       | Units to pre-charge (default 1, minimum 1). `Query` charges SOQL, `API_Call` charges API calls, everything else charges DML |

**Response (200)**

```json
{
  "success": true,
  "correlationId": "...",
  "authorized": true,
  "agentId": "a0B...",
  "budgetStatus": "Normal",
  "remainingBudget": { "apiCalls": 9842, "soqlQueries": 4991, "dmlOperations": 2987 },
  "conflict": { "detected": false, "resolution": null }
}
```

When `Is_Enabled__c` is unchecked the same shape is returned with `"governanceEnabled": false`.
Nothing is charged and no check is run, so `remainingBudget` reflects a read rather than a
consumption. Clients should keep reading `authorized`.

A breaker whose cooldown has elapsed reopens itself when the request arrives, so the call becomes
the single admitted probe. Inside the cooldown the agent is still refused with
`AGENT_NOT_ACTIVE` (403).

```bash
curl -X POST "$INSTANCE/services/apexrest/agentgov/authorize" \
  -H "Authorization: Bearer $TOKEN" -H "X-AgentGov-Key: $AGENT_KEY" -H "Content-Type: application/json" \
  -d '{"objectName":"Lead","operation":"Update","recordId":"00Q...","amount":10}'
```

Denials are written to the action log with status `Denied`.

---

## POST /agentgov/report

Reports what the agent actually consumed and, optionally, the outcome of the work.

Only usage **beyond** what was already pre-authorized is charged. Unused pre-authorization is
**not** credited back: both figures come from the caller in the same request and the framework
keeps no record of what an agent reserved, so honouring a credit would let any agent clear its
own ledger. Budget corrections are an administrative action through
`AgentGovBudgetManager.creditBudget`. The agent is denied with `BUDGET_EXCEEDED` if the
reported usage leaves the budget Blocked or Exhausted.

All counts must be zero or positive. A negative figure is rejected with `INVALID_INPUT` (400).

**Body**

| Field           | Type    | Required | Description                                                 |
| --------------- | ------- | -------- | ----------------------------------------------------------- |
| `actual`        | Object  | Yes      | `apiCalls`, `soqlQueries`, `dmlOperations` actually used    |
| `preAuthorized` | Object  | No       | The same keys as sent to `/authorize`; caps what is charged |
| `success`       | Boolean | No       | Outcome of the work, reported to the circuit breaker        |

```bash
curl -X POST "$INSTANCE/services/apexrest/agentgov/report" \
  -H "Authorization: Bearer $TOKEN" -H "X-AgentGov-Key: $AGENT_KEY" -H "Content-Type: application/json" \
  -d '{"actual":{"dmlOperations":7,"soqlQueries":2},"preAuthorized":{"dmlOperations":10},"success":true}'
```

Sending `success` is how an agent that uses `/authorize` closes a circuit breaker it tripped.
A breaker in HALF_OPEN admits one probe; reporting `true` closes it and returns the agent to
Active, and reporting `false` re-opens it with a doubled cooldown.

**Response (200)**: `budgetStatus`, `remainingBudget`, and `circuitBreakerState`.

---

## POST /agentgov/rotate-key

Issues a replacement API key for the calling agent. The previous key stops working
immediately. Authenticate with the current key or the bound user.

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

Returns the agent's budget for today, creating the row if this is the first read of the
day. The caller must be that agent (key header or bound user) or hold the
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
record count. Every endpoint runs: authentication → circuit breaker → policy (object,
operation, field restrictions, record cap) → conflict detection (for writes with Ids) →
field-level security check → budget → execution → audit log → breaker outcome.

Everything runs in **user mode**: the token's user must have the object permissions,
field-level security, and sharing access for the data involved. Missing access returns
`ACCESS_DENIED` naming the fields, before anything is written. Active and Throttled agents
may call the proxy (a Throttled agent is one whose breaker is probing recovery).

### POST /agentgov-proxy/query

Runs a structured query. SOQL text is not accepted; a `query` property returns 400.

**Body**

| Field        | Type    | Required | Description                                                                                                                                                                                                                           |
| ------------ | ------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `objectName` | String  | Yes      | Object API name                                                                                                                                                                                                                       |
| `fields`     | Array   | Yes      | Field API names on that object. Relationship paths (`Owner.Name`) and subqueries are not accepted.                                                                                                                                    |
| `where`      | Array   | No       | Conditions `{ "field", "op", "value" }`, combined with AND. Operators: `=`, `!=`, `<`, `<=`, `>`, `>=`, `LIKE`, `IN`, `NOT IN`. `IN`/`NOT IN` take an array. Values are bound, never concatenated, and converted to the field's type. |
| `orderBy`    | Object  | No       | `{ "field", "direction" }` with `ASC` (default) or `DESC`                                                                                                                                                                             |
| `limit`      | Integer | No       | Rows to return. Default 200; never more than the policy's record cap or 2,000.                                                                                                                                                        |

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

**Response (200)**: `totalSize`, `records`, `budgetStatus`, `remainingBudget`. One SOQL
query is charged.

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
  "budgetStatus": "Normal",
  "remainingBudget": { "apiCalls": 10000, "soqlQueries": 5000, "dmlOperations": 2997 }
}
```

Per-record failures appear as `{ "success": false, "errors": ["..."] }`; the HTTP status
stays 200 because the request itself was processed.

### POST /agentgov-proxy/update

**Body**: `objectName`, `records`; every record must carry an `Id` that belongs to
`objectName`. Records held by a higher-priority agent in the same transaction return
`RECORD_LOCKED`.

### POST /agentgov-proxy/delete

**Body**: `objectName`, `ids` (array). Each Id must belong to `objectName`.

### POST /agentgov-proxy/upsert

**Body**: `objectName`, `records`, optional `externalIdField` (must be an External ID
field). Results include `created` per record.

---

## Rate limiting

AgentGov enforces daily budgets per agent, not per-minute rate limits. Salesforce's own
API limits still apply to the OAuth session. Per-minute limits are on the roadmap.
