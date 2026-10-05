# REST API Reference

AgentGov exposes two Apex REST resources for agents that run outside the org: the
**governance API** at `/services/apexrest/agentgov` (register, authorize, report, rotate a
key, read budget and health) and the **governed proxy** at
`/services/apexrest/agentgov-proxy` (queries and record changes executed on the agent's behalf,
with the calling user's access). The proxy charges one SOQL query per query and one DML
operation per record submitted, so what an agent is charged never depends on what it says it
did.

---

## Authentication

Every call needs a Salesforce session. Every call except `/register` also needs an agent
identity, which `GET /budget` and `GET /health` waive for a caller who holds the
`AgentGov_Admin_Access` custom permission.

**1. A Salesforce OAuth 2.0 access token** in the `Authorization: Bearer <token>` header.
Obtain it through an External Client App (Connected Apps can no longer be created in most
orgs). The token's user needs access to the two REST classes: the `AgentGov_Agent` permission
set for the user an agent runs as, which grants those two classes and nothing else, or
`AgentGov_Admin` for an administrator. The framework records its own bookkeeping in system
mode, so the agent's user needs no access to AgentGov objects. Without access to the classes,
the platform refuses the call before AgentGov runs, and the response is the platform's own
error, with no AgentGov `errorCode` or `correlationId`.

**2. An agent identity**, resolved in this order:

| Credential                             | How                                                                                                                                | Status                                                                           |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `X-AgentGov-Key` header                | The agent's API key. The legacy header name `X-AgentGov-API-Key` is accepted as an alias. Header names are not case-sensitive.     | Recommended for external agents                                                  |
| `apiKey` in the JSON body              | Same key, in the body of a POST. Read only when no key header is sent.                                                             | **Deprecated**; successful responses carry a `deprecation` note; removed in v1.4 |
| No key, user bound to the registration | The token's user is set in `Agent_User__c` on exactly one registration. Intended for Agentforce Agent Users and integration users. | Recommended when the agent has its own Salesforce user                           |

A key that matches no registration is refused with `AGENT_NOT_FOUND` (404) and the message
`Agent not registered. Call /register first.`; a call with no key from a user bound to no
registration gets `AGENT_NOT_FOUND` with `Authentication required. …`. The GET endpoints
answer both with `ACCESS_DENIED` instead, unless the caller holds `AgentGov_Admin_Access`; see
[GET /agentgov/budget](#get-agentgovbudgetregistrationid).

Keys are never stored; only a SHA-256 hash and a short prefix are kept. A key created by a
release before v1.2 is upgraded to hashed storage the first time it is presented.

An agent authenticated by its Salesforce user rather than a key must be bound to exactly one
registration. A user bound to several is refused with `ACCESS_DENIED` (403) and must send
`X-AgentGov-Key`, because the login alone cannot say which agent is calling.

---

## Response envelope

Every response AgentGov writes is JSON and carries a `correlationId`. Send your own in the
`X-Correlation-Id` request header (the first 255 characters are kept) and it is echoed back;
otherwise one is generated. The id is also returned in the `X-Correlation-Id` response header.

The id ties a request to its audit rows. Every action-log row the request writes for the
agent's call stores it in `Correlation_Id__c`, together with how long the request had taken
(`Execution_Time_Ms__c`), the session its usage was recorded against, if any, and, for a
refusal or failure, the reason. A `System` row the request writes, such as the one for an
unexpected error, stores the id as well. `Alert` rows raised by the request carry neither the
id nor a duration; find them by agent and time.

**Success.** The endpoint's own fields sit beside `success` and `correlationId`. A request
authenticated with the deprecated body `apiKey` also gets `deprecation`. For example, the
complete response to a `/report` call that sent its key in the body:

```json
{
  "success": true,
  "correlationId": "5f1c1a2e-...",
  "budgetStatus": "Normal",
  "remainingBudget": { "apiCalls": 10000, "soqlQueries": 4989, "dmlOperations": 2990 },
  "circuitBreakerState": "CLOSED",
  "deprecation": "Passing apiKey in the request body is deprecated and will be removed in v1.4. Send it in the X-AgentGov-Key header instead."
}
```

**Error.** Every refusal or failure AgentGov returns has this shape. Only errors carry
`timestamp`, and they never carry `deprecation`:

```json
{
  "success": false,
  "errorCode": "BUDGET_EXCEEDED",
  "message": "Governor budget exceeded for limit type: DML_Operations",
  "correlationId": "5f1c1a2e-...",
  "timestamp": "2026-09-15T10:00:00.000Z"
}
```

| Code                   | HTTP | Returned when                                                                                                                                                                                                                                                                                                        |
| ---------------------- | ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `INVALID_INPUT`        | 400  | The request is malformed; [Validation errors](#validation-errors) lists every message. Nothing is charged, no audit row is written, and the circuit breaker is not consulted                                                                                                                                         |
| `ACCESS_DENIED`        | 403  | The calling user may not read or change the data a proxy request names (`The agent user is not permitted to …`); a GET names another agent, or carries no credential that resolves to an agent, and the caller lacks `AgentGov_Admin_Access`; or no key was sent and the user is bound to more than one registration |
| `AGENT_NOT_ACTIVE`     | 403  | `Agent is not in Active status.` The agent is deactivated (`Inactive`), or `Blocked` by its circuit breaker and still inside the cooldown. `/rotate-key` also refuses a `Blocked` agent after the cooldown                                                                                                           |
| `POLICY_VIOLATION`     | 403  | An `AgentGov_Policy__mdt` record denies the operation; through the proxy, also a restricted field or a write over the record cap                                                                                                                                                                                     |
| `AGENT_NOT_FOUND`      | 404  | On a POST, no credential resolved to a registration; on a GET by a holder of `AgentGov_Admin_Access`, the registration in the path does not exist; or the path is not one AgentGov serves (`Endpoint not found: <path>`)                                                                                             |
| `RECORD_LOCKED`        | 409  | Another agent holds the record in the same transaction. Not returned over REST in practice; see [Conflict detection](#conflict-detection)                                                                                                                                                                            |
| `BUDGET_EXCEEDED`      | 429  | The charge left the budget Blocked or Exhausted. A budget's status is the worst across its three limit types, so every governed call is then refused, whatever it would charge, and the message names the limit type responsible. The refused request's own units stay recorded                                      |
| `INTERNAL_ERROR`       | 500  | An unexpected failure; see [Unexpected errors](#unexpected-errors). The message is always `Internal error. Quote the correlationId when reporting this problem.`                                                                                                                                                     |
| `CIRCUIT_BREAKER_OPEN` | 503  | `Circuit breaker is OPEN. Agent is temporarily disabled.` The breaker is HALF_OPEN and its single probe is already taken, or it is OPEN while the agent's status was set back to Active by hand                                                                                                                      |

`MAX_CONCURRENT_AGENTS` is not returned by any REST endpoint. Only activating an agent raises
it, through `AgentGovRegistryService.activateAgent` or `activateAgents` in Apex, or
**Activate** in the console.

### Validation errors

A request refused with 400 `INVALID_INPUT` is answered with one of these messages. Angle
brackets stand for the value from the request.

| Endpoints                       | Message                                                                                                                                                                                                               |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Every POST                      | `Request body must be a JSON object.`                                                                                                                                                                                 |
| Every POST                      | `<name> must be a JSON string.` for a text property sent as another JSON type: every `/register` field, `objectName`, `operation` and `recordId` on `/authorize`, and `objectName` and `externalIdField` on the proxy |
| `/register`                     | `Agent name is required.`                                                                                                                                                                                             |
| `/register`                     | `Invalid agent type specified.`                                                                                                                                                                                       |
| `/register`                     | `apiKey must be at least 24 characters.`                                                                                                                                                                              |
| `/register`                     | `The registration could not be created with the values supplied.` (the key is already in use; the message does not say so, so the endpoint cannot be used to probe for keys)                                          |
| `/register`                     | `The registration could not be created: the value for <field> is not valid.`, such as a malformed `ownerEmail`                                                                                                        |
| `/authorize`                    | `operation is required and must be one of: ` followed by the seven operations                                                                                                                                         |
| `/authorize`, proxy             | `Object name is required.`                                                                                                                                                                                            |
| `/authorize`, proxy             | `Unknown or inaccessible object: <name>`                                                                                                                                                                              |
| `/authorize`                    | `amount must be an integer.` or `amount must be at least 1.`                                                                                                                                                          |
| `/authorize`, GET, proxy writes | `Invalid record Id: <value>`: not a 15- or 18-character Salesforce Id, or, in a GET path, not an agent registration's Id                                                                                              |
| `/report`                       | `actual usage data is required.`                                                                                                                                                                                      |
| `/report`                       | `<counter> must be an integer.` or `<counter> must not be negative.`                                                                                                                                                  |
| Proxy                           | `Unknown field for <object>: <field>`                                                                                                                                                                                 |
| Proxy                           | `Invalid field name: <field>. Only simple field API names are accepted; relationship paths and subqueries are not.`                                                                                                   |
| Proxy                           | `Value "<value>" is not valid for a <TYPE> field.`                                                                                                                                                                    |
| Proxy                           | `A JSON object or list is not a valid value for a <TYPE> field.`                                                                                                                                                      |
| `/query`                        | `Raw SOQL is no longer accepted by /query. …`, for a body with a `query` property                                                                                                                                     |
| `/query`                        | `At least one field is required.`                                                                                                                                                                                     |
| `/query`                        | `where must be a list of {field, op, value} objects.` or `Each where entry must be an object with field, op, and value.`                                                                                              |
| `/query`                        | `Unsupported operator: <op>`                                                                                                                                                                                          |
| `/query`                        | `IN and NOT IN require a list of values for field: <field>`                                                                                                                                                           |
| `/query`                        | `Field <field> on <object> cannot be used in a where condition.`                                                                                                                                                      |
| `/query`                        | `LIKE works only on single-value text fields, and <field> on <object> is not one.`                                                                                                                                    |
| `/query`                        | `orderBy must be an object with field and direction.` or `orderBy.direction must be ASC or DESC.`                                                                                                                     |
| `/query`                        | `Field <field> on <object> cannot be used to order results.`                                                                                                                                                          |
| `/query`                        | `limit must be an integer.` or `limit must be at least 1.`                                                                                                                                                            |
| `/query`                        | `The query on <object> could not be run as written. …`: the database refused the query, for example an operator its field type does not support                                                                       |
| `/create`, `/update`, `/upsert` | `At least one record is required.` or `Each record must be a JSON object.`                                                                                                                                            |
| `/update`                       | `Every record must include an Id for this operation.`                                                                                                                                                                 |
| `/delete`                       | `At least one record Id is required.`                                                                                                                                                                                 |
| Proxy writes                    | `Record Id <id> does not belong to object <object>.`                                                                                                                                                                  |
| Proxy writes                    | `Record Id <id> appears more than once in this request.`, also when one Id is sent in its 15- and its 18-character form                                                                                               |
| Proxy writes                    | `A request may carry at most 10000 records; <n> were submitted.`                                                                                                                                                      |
| Proxy writes                    | `Field <field> on <object> cannot be set to the value supplied.`: a value the field cannot hold, or a field no request may set, such as a formula field or `CreatedDate`                                              |
| `/upsert`                       | `externalIdField must be an External ID field: <field>`                                                                                                                                                               |

---

## What is charged and what is audited

A request is charged only once every check before the charge has passed, and the charge is the
last check:

| Request         | Charged                                                                                                                           | Actions counted on the session |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| `/authorize`    | `amount` units (default 1): SOQL queries for `Query`, API calls for `API_Call`, DML operations for every other operation          | One                            |
| `/report`       | The usage in `actual` beyond `preAuthorized`, counter by counter                                                                  | None                           |
| Proxy `/query`  | One SOQL query, however many rows it returns                                                                                      | One                            |
| Proxy writes    | One DML operation per record, or per Id for `/delete`, charged before the write runs, so records the database rejects still count | One                            |
| Everything else | Nothing                                                                                                                           | None                           |

Whatever is charged is also added to the usage of the agent's current session.

Nothing is charged for a request refused before the charge: bad input, a credential that does
not resolve, or a refusal by the status check, the circuit breaker, a policy, a conflict or an
access check. Nothing is charged for a `/query` the database refuses as invalid, for a POST
that fails with 500, which is rolled back, or for any call while `Is_Enabled__c` is unchecked.

When the charge itself leaves the budget Blocked or Exhausted, the request is refused with
`BUDGET_EXCEEDED`, and its own units stay recorded on today's budget and on the agent's
session, so the ledger shows the attempt. Every governed call after that is refused too, and
each refused call still adds its units. The budget renews at midnight in the org's default
time zone; an administrator can credit usage back sooner with **Credit budget** in the console
or `AgentGovBudgetManager.creditBudget`.

Rows written to the action log (`AgentGov_Action_Log__c`):

| Request       | Rows                                                                                                                                                                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/register`   | None                                                                                                                                                                                                                                        |
| `/authorize`  | `Success` for an authorization, `Denied` for a refusal by the status check, the circuit breaker, a policy, a conflict or the budget. The action type is the requested operation, or `System` when a refused request named no recognised one |
| `/report`     | A `Report` row: `Success` with the three counters reported, or `Denied` for a refusal by the status check or the budget                                                                                                                     |
| `/rotate-key` | A `Denied` `System` row for a refusal. A successful rotation writes no row; the registration records it in `API_Key_Last_Rotated__c`                                                                                                        |
| GET           | None                                                                                                                                                                                                                                        |
| Proxy         | A row for the operation: `Success`, `Failure` when every record in a write failed, or `Denied` for a refusal by the status check, the circuit breaker, a policy, a conflict, an access check or the budget                                  |

A request refused with 400, one whose credential does not resolve to an agent, and one for a
path AgentGov does not serve leave no row.

### Unexpected errors

A POST that fails unexpectedly is rolled back to a savepoint taken when the request began, so
everything it wrote, record changes and budget charges included, is undone and a retry cannot
create anything twice. Exactly one `System` row with status `Failure` is then written under
the request's correlation id, holding the detail of the failure: for an exception, its type,
message and stack trace. The caller receives 500 `INTERNAL_ERROR` with a generic message and
that correlation id, never the detail. A GET that fails unexpectedly is answered and logged the
same way but is not rolled back, so a budget row it created for the day stays.

Refusals are answered normally and keep their audit rows.

---

## POST /agentgov/register

Registers an agent. No agent credential is required. New agents start `Inactive`; an
administrator activates them with `AgentGovRegistryService.activateAgent` or with **Activate**
in the console. Registration is not audited.

**Body**

| Field         | Type   | Required | Description                                                                                                                             |
| ------------- | ------ | -------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `agentName`   | String | Yes      | Display name                                                                                                                            |
| `agentType`   | String | Yes      | `Agentforce`, `MCP_External`, `Custom_Apex`, or `Flow_Based`                                                                            |
| `description` | String | No       | Purpose of the agent                                                                                                                    |
| `apiKey`      | String | No       | A key of your choosing, at least 24 characters and not in use by another agent. Omit it and AgentGov generates one and returns it once. |
| `ownerEmail`  | String | No       | Contact for the agent's owner, a valid email address                                                                                    |

Every field must be a JSON string. The request is refused with `INVALID_INPUT` (400) when
`agentName` is blank, `agentType` is not one of the four types, a supplied `apiKey` is shorter
than 24 characters or already in use, or the database rejects a value, such as a malformed
`ownerEmail`. Nothing is created.

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

When you supplied a key, the response carries `apiKeyPrefix` but not the key, and the message
`Agent registered. The supplied apiKey is stored as a hash. Activate the agent to enable it.`

```bash
curl -X POST "$INSTANCE/services/apexrest/agentgov/register" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"agentName":"Lead Enrichment Agent","agentType":"MCP_External","ownerEmail":"owner@example.com"}'
```

---

## POST /agentgov/authorize

Runs the governance pipeline for one intended action and pre-charges its budget. The agent then
performs the action itself and reports how it went with [`/report`](#post-agentgovreport).

A body that is not a JSON object is refused with 400 before anything else runs. The other
steps run in this order, and a refusal ends the request:

1. **Identify the agent**, as in [Authentication](#authentication). A credential that does not
   resolve gets 404 `AGENT_NOT_FOUND`, or 403 `ACCESS_DENIED` for a user bound to several
   registrations. No row is written.
2. **Status check.** Active and Throttled agents pass. A Blocked agent passes once its circuit
   breaker's cooldown has passed, so that the breaker can admit it as its probe, and at any time
   while governance is switched off. A deactivated (`Inactive`) agent never passes. Refused
   with 403 `AGENT_NOT_ACTIVE` and a `Denied` row.
3. **Validation** of the body below. Refused with 400 `INVALID_INPUT`: nothing is charged, no
   row is written, and the circuit breaker is not consulted.
4. **Circuit breaker.** Refused with 503 `CIRCUIT_BREAKER_OPEN` and a `Denied` row.
5. **Policy** for the object and operation. Refused with 403 `POLICY_VIOLATION` and a `Denied`
   row.
6. **Conflict**, when `recordId` is sent. A refusal would be 409 `RECORD_LOCKED` with a
   `Denied` row, which a REST caller does not meet in practice; see
   [Conflict detection](#conflict-detection).
7. **Budget.** Charges `amount` units. When the charge leaves the budget Blocked or Exhausted,
   the request is refused with 429 `BUDGET_EXCEEDED` and a `Denied` row, and the units stay
   charged.
8. **Audit and answer**: a `Success` row, and 200.

**Body**

| Field        | Type    | Required | Description                                                                                                                                          |
| ------------ | ------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `objectName` | String  | Yes      | API name of an object in the org                                                                                                                     |
| `operation`  | String  | Yes      | `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`, or `Flow_Trigger`                                                                       |
| `recordId`   | String  | No       | The 15- or 18-character Id of the record the action targets, stored on the audit row. See [Conflict detection](#conflict-detection)                  |
| `amount`     | Integer | No       | Units to pre-charge (default 1, minimum 1). `Query` charges SOQL queries, `API_Call` charges API calls, every other operation charges DML operations |

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

```bash
curl -X POST "$INSTANCE/services/apexrest/agentgov/authorize" \
  -H "Authorization: Bearer $TOKEN" -H "X-AgentGov-Key: $AGENT_KEY" -H "Content-Type: application/json" \
  -d '{"objectName":"Lead","operation":"Update","recordId":"00Q5g00000Lx3QZEAZ","amount":10}'
```

**Circuit breaker.** When an agent's circuit breaker trips, the agent is set to `Blocked` and
refused with `AGENT_NOT_ACTIVE` (403) until the cooldown has passed. The next request then
moves the breaker to HALF_OPEN, which sets the agent to `Throttled`, and is admitted as its
single probe. The scheduled health check can make that move first, and then the next request
is the probe. Other requests are refused with `CIRCUIT_BREAKER_OPEN` (503) while the probe is
outstanding. The probe is resolved by the outcome the agent reports with `/report` and
`"success"`: `true` closes the breaker and returns the agent to `Active`, and `false` re-opens
it for twice the configured cooldown, at most one day. A probe with no reported outcome within
one configured cooldown, including one whose request a policy or the budget then refused, is
treated as abandoned, and the next request becomes the probe. Authorizing records no outcome
itself, because the work has not run yet.

**Emergency bypass.** When `Is_Enabled__c` is unchecked, `/authorize` skips the circuit
breaker, policy, conflict and budget steps and charges nothing. The body is still validated and
the call is still audited, as a `Success` row. The only agent refused is a deactivated one,
with `AGENT_NOT_ACTIVE`. The response reads the budget rather than charging it, carries
`"governanceEnabled": false`, and has no `sessionId` and no `conflict`. Clients should keep
reading `authorized`.

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

---

## POST /agentgov/report

Reports what the agent actually consumed and, optionally, how the work went. The agent passes
the same status check as for `/authorize`, and a refusal is audited as a `Denied` `Report` row.

Only usage **beyond** what was already pre-authorized is charged. Unused pre-authorization is
**not** credited back: both figures come from the caller in the same request and the framework
keeps no record of what an agent reserved, so honouring a credit would let any agent clear its
own ledger. Budget corrections are an administrative action: **Credit budget** in the console,
or `AgentGovBudgetManager.creditBudget`.

When the charge leaves the budget Blocked or Exhausted, the report is refused with
`BUDGET_EXCEEDED` (429): the reported usage stays charged, the report is audited as a `Denied`
row, and its `success` value is not passed to the circuit breaker. Otherwise the report is
audited as a `Success` row that records the three counters, including a report that charges
nothing.

Every count must be a whole number, zero or more. A negative or non-numeric count is refused
with `INVALID_INPUT` (400), and nothing is charged or audited.

**Body**

| Field           | Type    | Required | Description                                                                                                          |
| --------------- | ------- | -------- | -------------------------------------------------------------------------------------------------------------------- |
| `actual`        | Object  | Yes      | `apiCalls`, `soqlQueries`, `dmlOperations` actually used. A counter that is left out is not charged                  |
| `preAuthorized` | Object  | No       | The same keys as `actual`, holding what `/authorize` pre-charged for this work. Only usage above it is charged       |
| `success`       | Boolean | No       | How the work went, reported to the circuit breaker. Only a JSON `true` or `false` counts; any other value is ignored |

```bash
curl -X POST "$INSTANCE/services/apexrest/agentgov/report" \
  -H "Authorization: Bearer $TOKEN" -H "X-AgentGov-Key: $AGENT_KEY" -H "Content-Type: application/json" \
  -d '{"actual":{"dmlOperations":7,"soqlQueries":2},"preAuthorized":{"dmlOperations":10},"success":true}'
```

**Response (200)**

```json
{
  "success": true,
  "correlationId": "...",
  "budgetStatus": "Normal",
  "remainingBudget": { "apiCalls": 10000, "soqlQueries": 4989, "dmlOperations": 2990 },
  "circuitBreakerState": "CLOSED"
}
```

Sending `success` is how an agent that uses `/authorize` tells its circuit breaker how the
work went, and `circuitBreakerState` in the response shows the result:

- On a CLOSED breaker, `false` adds one to the agent's run of consecutive failures and trips
  the breaker at the configured threshold (5 by default); `true` clears the run.
- On a HALF_OPEN breaker, the outcome resolves the probe: `true` closes the breaker and returns
  the agent to `Active`, and `false` re-opens it for twice the configured cooldown, at most one
  day.
- On an OPEN breaker the outcome is ignored, so a report neither extends nor ends a cooldown.
  The breaker leaves OPEN only when a request is admitted as its probe after the cooldown, when
  the health check moves it to HALF_OPEN, or when an administrator resets it.

While `Is_Enabled__c` is unchecked, a report charges nothing, `success` is not passed to the
circuit breaker, and the response carries the current budget. The report is still audited.

---

## POST /agentgov/rotate-key

Issues a replacement API key for the calling agent. The previous key stops working
immediately. Authenticate with the current key or the bound user.

Only an `Active` or `Throttled` agent may rotate its key, also while governance is switched
off. Any other status is refused with `AGENT_NOT_ACTIVE` (403) and audited as a `Denied`
`System` row (`Key rotation refused: Agent is not in Active status.`), so deactivating an agent
whose key has leaked also stops the holder from issuing a new one. A successful rotation
writes no action-log row; the registration records the new prefix and the time in
`API_Key_Last_Rotated__c`. An administrator can rotate a key with **Rotate key** in the
console, which needs the AgentGov Manage Keys permission and records an `Admin` row.

```bash
curl -X POST "$INSTANCE/services/apexrest/agentgov/rotate-key" \
  -H "Authorization: Bearer $TOKEN" -H "X-AgentGov-Key: $AGENT_KEY"
```

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
is the first read of the day. A read charges nothing, applies no status check, and writes no
audit row, so a deactivated or Blocked agent can still read its own budget.

The path must hold an agent registration Id, or the request is refused with 400 `INVALID_INPUT`
(`Invalid record Id: <value>`). A GET takes the agent's key only from the key header, or
identifies the agent by its bound user, and answers as follows:

- The agent named in the path, and any holder of the `AgentGov_Admin_Access` custom
  permission, gets the budget. A holder of the permission needs no agent credential.
- Without the permission, a caller identified as another agent gets 403 `ACCESS_DENIED`
  (`Access denied. Only the agent itself or a user with the AgentGov_Admin_Access custom permission can read this resource.`),
  and a caller whose credential resolves to no agent, or who sends none, gets 403
  `ACCESS_DENIED` (`Authentication required. …`).
- A holder of the permission who names a registration that does not exist gets 404
  `AGENT_NOT_FOUND`.

```bash
curl "$INSTANCE/services/apexrest/agentgov/budget/$AGENT_ID" \
  -H "Authorization: Bearer $TOKEN" -H "X-AgentGov-Key: $AGENT_KEY"
```

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

`allowed` is `false` once the budget is Blocked or Exhausted. A figure in `remaining` can be
negative, because a refused request's units stay recorded.

## GET /agentgov/health/{registrationId}

Returns status and circuit breaker state, with the same access rules as `/budget`.

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

`failureCount` is the agent's current run of consecutive failures, and `cooldownUntil` is when
an OPEN breaker may admit its probe.

---

## The governed proxy: /agentgov-proxy

The proxy executes queries and record changes on the agent's behalf in **user mode**: the
token's user must have the object permissions, field-level security, and sharing access for
the data involved, and a query returns only the rows that user can see.

Every endpoint runs these steps in order, and a refusal ends the request:

1. **Path and body.** A path other than `/query`, `/create`, `/update`, `/delete` and `/upsert`
   gets 404 `AGENT_NOT_FOUND` before anything else runs, and a body that is not a JSON object
   gets 400.
2. **Identify the agent**, as for `/authorize`: 404 `AGENT_NOT_FOUND`, or 403 `ACCESS_DENIED`
   for a user bound to several registrations. No row is written.
3. **Status check**, as for `/authorize`: Active and Throttled agents pass, a Blocked agent
   passes once its breaker's cooldown has passed or while governance is switched off, and a
   deactivated agent never does. Refused with 403 `AGENT_NOT_ACTIVE`.
4. **Validation of the whole request**: the body, the object, every field name and value, the
   operators and clauses, record Ids, repeated Ids, `externalIdField`, and the maximum of
   10,000 records or Ids per request. Refused with 400 `INVALID_INPUT`: nothing is charged, no
   row is written, and the circuit breaker is not consulted, so a malformed request never uses
   up a half-open breaker's probe.
5. **Circuit breaker.** Refused with 503 `CIRCUIT_BREAKER_OPEN`.
6. **Policy**: the operation's allow or deny, then the record cap, then field restrictions on
   every field the request reads or writes. Refused with 403 `POLICY_VIOLATION`. A write with
   more records than the cap is refused; a query's limit is lowered to the cap instead.
7. **Conflicts**, for `/update`, `/upsert` and `/delete` of records that carry Ids. A refusal
   would be 409 `RECORD_LOCKED`, which a proxy caller does not meet in practice; see
   [Conflict detection](#conflict-detection).
8. **Access check**, before anything is charged. Refused with 403 `ACCESS_DENIED` and a message
   in the framework's own words that names the object, or the fields, the user may not reach:
   - `/query`: read access to the object and to every field the query selects, filters on or
     sorts by (`The agent user is not permitted to read Account.`);
   - `/create`, `/update`, `/upsert`: create, edit or upsert access to the object and to every
     field written (`The agent user is not permitted to update these fields on Account: Phone`);
   - `/delete`: delete permission on the object (`The agent user is not permitted to delete Account.`).
9. **Budget.** `/query` charges one SOQL query, and a write one DML operation per record or
   Id. When the charge leaves the budget Blocked or Exhausted, the request is refused with 429
   `BUDGET_EXCEEDED` and the units stay charged.
10. **Execution** in user mode. A write reports each record's result: a record the database
    rejects, for a validation rule, a duplicate rule, or missing sharing access, appears with its
    errors and stays charged. A query the database still refuses as invalid is undone to before
    step 5 and refused with 400 `INVALID_INPUT` (`The query on <object> could not be run as written. …`):
    nothing is charged, no row is written, and a half-open breaker's probe stays free.
11. **Breaker outcome.** A query that runs is a success. A write is a success when any record
    was saved, and a failure when none was.
12. **Audit and answer**: a `Success` row, or `Failure` when every record in a write failed;
    a write's row also carries the first error any record met. Then 200.

A refusal at steps 3 and 5 to 9 is audited as a `Denied` row with the reason, and records no
breaker outcome. The proxy admits a Blocked agent whose cooldown has passed as the breaker's
single probe, as `/authorize` does, and resolves the probe itself with the outcome at step 11.
A probe whose request is refused at steps 6 to 9 stays claimed until one configured cooldown
has passed, and then the next request becomes the probe.

**Emergency bypass.** While `Is_Enabled__c` is unchecked, steps 5 to 7 are skipped, the budget
is read rather than charged, and no breaker outcome is recorded. Validation and the calling
user's access still apply, the only agent refused at the status check is a deactivated one, and
every call is still audited. No session activity is recorded, so write responses carry a `null`
`sessionId`.

### POST /agentgov-proxy/query

Runs a structured query. SOQL text is not accepted; a `query` property returns 400.

**Body**

| Field        | Type    | Required | Description                                                                                                                                                                         |
| ------------ | ------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `objectName` | String  | Yes      | Object API name                                                                                                                                                                     |
| `fields`     | Array   | Yes      | Field API names on that object. Relationship paths (`Owner.Name`) and subqueries are not accepted.                                                                                  |
| `where`      | Array   | No       | Conditions `{ "field", "op", "value" }`, combined with AND. Operators: `=`, `!=`, `<`, `<=`, `>`, `>=`, `LIKE`, `IN`, `NOT IN`, in any letter case. `IN` and `NOT IN` take an array |
| `orderBy`    | Object  | No       | `{ "field", "direction" }` with `ASC` (default) or `DESC`                                                                                                                           |
| `limit`      | Integer | No       | Rows to return. Default 200. The query returns at most the smallest of this value, the policy's record cap, and 2,000; a larger value is lowered, not refused.                      |

Values are passed as bind variables, never concatenated into the query, and are converted to
the field's type:

- Text, text area, picklist, multi-select picklist, combobox, email, phone, URL and encrypted
  text: the value is used as text, so a JSON number or boolean is matched as its text.
- Date: `"2026-01-31"`. Date/time: ISO 8601, such as `"2026-01-01T00:00:00.000Z"`. Time:
  `"09:30:00.000Z"`.
- Number, currency and percent: a number; a whole number for an integer field.
- Checkbox: a JSON `true` or `false`. Text is not refused but read as a boolean, so a value
  such as `"yes"` reads as false.
- Id and lookup: a 15- or 18-character Id.
- `null` matches an empty field.

A JSON object or list is never a value. `IN` and `NOT IN` take a list, whose items are
converted the same way.

A condition's field must be filterable and a sort's field sortable, and `LIKE` works only on
single-value text fields: text, text area, picklist, combobox, email, phone, URL and encrypted
text. Such a request is refused with 400 while it is validated, before anything is charged.

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

**Response (200)**

```json
{
  "success": true,
  "correlationId": "...",
  "totalSize": 1,
  "records": [
    {
      "attributes": { "type": "Account", "url": "/services/data/v67.0/sobjects/Account/001..." },
      "Id": "001...",
      "Name": "Acme Energy",
      "Industry": "Energy"
    }
  ],
  "budgetStatus": "Normal",
  "remainingBudget": { "apiCalls": 10000, "soqlQueries": 4999, "dmlOperations": 3000 }
}
```

A query response has no `sessionId`.

### POST /agentgov-proxy/create

**Body**: `objectName`, `records` (array of objects keyed by field API name). Unknown fields
are refused with 400, and an `attributes` key is ignored so records copied from a query
response can be resubmitted. Values are converted as for `/query`; a value a field cannot hold,
or a field no request may set, such as a formula field or `CreatedDate`, is refused with 400.
Charges one DML operation per record.

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

Per-record failures appear as `{ "success": false, "errors": ["..."] }`, carrying the database's
own message; the HTTP status stays 200 because the request itself was processed. Every write
endpoint returns this shape, including `sessionId`, the agent's current session as on
`/authorize`.

### POST /agentgov-proxy/update

**Body**: `objectName`, `records`; every record must carry an `Id` that belongs to
`objectName`, and no Id may appear twice.

### POST /agentgov-proxy/delete

**Body**: `objectName`, `ids` (array). Each Id must belong to `objectName` and appear once.
The calling user needs delete permission on the object, or the request is refused with
`ACCESS_DENIED` before anything is charged. Each result carries the record's `id`.

### POST /agentgov-proxy/upsert

**Body**: `objectName`, `records`, and an optional `externalIdField`: an External ID field, or
another field the platform can match records on, such as `Id`. Without it, records that carry
an `Id` are updated and the others are created. No Id may appear twice. Each result carries
`created`, which is `true` for a record that was inserted.

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
