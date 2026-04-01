# REST API Reference

AgentGov exposes a REST API for external agents (MCP servers, third-party integrations) to interact with the governance framework.

**Base URL:** `https://<your-instance>.salesforce.com/services/apexrest/agentgov`

**Authentication:** All requests require a valid Salesforce OAuth 2.0 bearer token in the `Authorization` header.

---

## POST /register

Registers a new AI agent in the governance framework.

### Request

```
POST /services/apexrest/agentgov/register
Content-Type: application/json
Authorization: Bearer <access_token>
```

**Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `agentName` | String | Yes | Display name of the agent |
| `agentType` | String | Yes | `Agentforce`, `MCP_External`, `Custom_Apex`, or `Flow_Based` |
| `description` | String | No | Description of the agent's purpose |
| `apiKey` | String | No | API key for subsequent authorize calls |
| `ownerEmail` | String | No | Contact email for the agent owner |

### Response (201 Created)

```json
{
  "success": true,
  "registrationId": "a0B5g00000XXXXXXXX",
  "registrationNumber": "REG-0001",
  "status": "Inactive",
  "message": "Agent registered successfully. Call activateAgent to enable."
}
```

### curl Example

```bash
curl -X POST \
  https://myinstance.salesforce.com/services/apexrest/agentgov/register \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agentName": "Lead Enrichment Agent",
    "agentType": "MCP_External",
    "description": "Enriches leads with firmographic data via Clearbit API",
    "apiKey": "mcp-lead-enrichment-abc123",
    "ownerEmail": "data-team@yourcompany.com"
  }'
```

### Error Responses

| Status | Error Code | Cause |
|--------|-----------|-------|
| 400 | `INVALID_INPUT` | Missing `agentName` or invalid `agentType` |
| 500 | (none) | Unexpected server error |

---

## POST /authorize

Authorizes an agent action by running the full governance pipeline: circuit breaker check, policy evaluation, budget consumption, and conflict detection.

This is the primary endpoint for external agents. Call this before every action.

### Request

```
POST /services/apexrest/agentgov/authorize
Content-Type: application/json
Authorization: Bearer <access_token>
```

**Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `apiKey` | String | Yes | The API key provided during registration |
| `objectName` | String | Yes | Salesforce object API name (e.g., `Lead`, `Case`) |
| `operation` | String | Yes | Operation type: `Query`, `Create`, `Update`, `Delete`, `Upsert`, `API_Call`, or `Flow_Trigger` |
| `recordId` | String | No | Specific record ID (enables conflict detection) |

### Response (200 OK)

```json
{
  "authorized": true,
  "agentId": "a0B5g00000XXXXXXXX",
  "budgetStatus": "Normal",
  "remainingBudget": {
    "apiCalls": 9842,
    "soqlQueries": 4991,
    "dmlOperations": 2987
  },
  "conflict": {
    "detected": false,
    "resolution": null
  }
}
```

### curl Example

```bash
curl -X POST \
  https://myinstance.salesforce.com/services/apexrest/agentgov/authorize \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "apiKey": "mcp-lead-enrichment-abc123",
    "objectName": "Lead",
    "operation": "Update",
    "recordId": "00Q5g00000YYYYYYYY"
  }'
```

### Error Responses

| Status | Error Code | Cause |
|--------|-----------|-------|
| 400 | `INVALID_INPUT` | Missing `apiKey` |
| 403 | `AGENT_NOT_ACTIVE` | Agent exists but is not Active |
| 403 | `POLICY_VIOLATION` | Action denied by policy configuration |
| 404 | `AGENT_NOT_FOUND` | No agent found with the provided API key |
| 409 | `RECORD_LOCKED` | Record is locked by a higher-priority agent |
| 429 | `BUDGET_EXCEEDED` | Daily governor budget exhausted for the relevant limit type |
| 503 | `CIRCUIT_BREAKER_OPEN` | Agent's circuit breaker is OPEN (temporarily disabled) |

### Error Response Format

```json
{
  "error": "Human-readable error message",
  "errorCode": "BUDGET_EXCEEDED"
}
```

---

## GET /budget/{agentId}

Returns the current budget status for an agent, including remaining allocations and usage percentages.

### Request

```
GET /services/apexrest/agentgov/budget/{agentId}
Authorization: Bearer <access_token>
```

**Path Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `agentId` | String | The agent registration record ID (18-character Salesforce ID) |

### Response (200 OK)

```json
{
  "agentId": "a0B5g00000XXXXXXXX",
  "budgetStatus": "Warning",
  "allowed": true,
  "remaining": {
    "apiCalls": 1580,
    "soqlQueries": 920,
    "dmlOperations": 450
  },
  "usagePercent": {
    "apiCalls": 84.2,
    "soqlQueries": 81.6,
    "dmlOperations": 85.0
  }
}
```

### curl Example

```bash
curl -X GET \
  https://myinstance.salesforce.com/services/apexrest/agentgov/budget/a0B5g00000XXXXXXXX \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

### Error Responses

| Status | Error Code | Cause |
|--------|-----------|-------|
| 400 | `INVALID_INPUT` | Missing or blank agent ID |
| 404 | `AGENT_NOT_FOUND` | Agent registration not found |

---

## GET /health/{agentId}

Returns the health status of an agent, including circuit breaker state, failure count, and timing information.

### Request

```
GET /services/apexrest/agentgov/health/{agentId}
Authorization: Bearer <access_token>
```

**Path Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `agentId` | String | The agent registration record ID (18-character Salesforce ID) |

### Response (200 OK)

```json
{
  "agentId": "a0B5g00000XXXXXXXX",
  "agentName": "Lead Enrichment Agent",
  "status": "Active",
  "circuitBreakerState": "CLOSED",
  "failureCount": 2,
  "lastFailure": "2025-01-15T14:30:00.000Z",
  "cooldownUntil": null,
  "lastActive": "2025-01-15T16:45:00.000Z"
}
```

### curl Example

```bash
curl -X GET \
  https://myinstance.salesforce.com/services/apexrest/agentgov/health/a0B5g00000XXXXXXXX \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

### Health Status Interpretation

| Status | Circuit Breaker | Meaning |
|--------|----------------|---------|
| Active | CLOSED | Healthy -- fully operational |
| Active | HALF_OPEN | Recovering -- one test request allowed |
| Throttled | HALF_OPEN | Recovering from a circuit breaker trip |
| Blocked | OPEN | Unhealthy -- all requests denied until cooldown |
| Inactive | CLOSED | Administratively deactivated |

### Error Responses

| Status | Error Code | Cause |
|--------|-----------|-------|
| 400 | `INVALID_INPUT` | Missing or blank agent ID |
| 404 | `AGENT_NOT_FOUND` | Agent registration not found |

---

## Authentication

All REST endpoints require a valid Salesforce OAuth 2.0 access token. The recommended flow for server-to-server integration is the **OAuth 2.0 JWT Bearer Flow** or the **Client Credentials Flow**.

### Obtaining an Access Token (Client Credentials)

```bash
curl -X POST https://login.salesforce.com/services/oauth2/token \
  -d "grant_type=client_credentials" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET"
```

### Using the Token

Include it in the `Authorization` header on every request:

```
Authorization: Bearer <access_token>
```

The connected app user must have the **AgentGov_Admin** or **AgentGov_User** permission set assigned.

---

## Rate Limiting

AgentGov does not impose its own rate limiting on REST API calls. However, Salesforce platform limits apply:

- **Concurrent API requests:** 25 per org (or per user, depending on edition)
- **Total API requests:** Based on your org's API request limit

AgentGov's budget system tracks governor limits (SOQL, DML, API callouts) consumed by agents, not the number of REST API calls to AgentGov itself.
