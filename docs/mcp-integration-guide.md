# MCP Integration Guide

This guide explains how to connect Model Context Protocol (MCP) servers to AgentGov, enabling external AI models to operate under Salesforce governance.

---

## Overview

The Model Context Protocol (MCP) allows AI models to interact with external tools and data sources through a standardized interface. When an MCP server connects to Salesforce, AgentGov acts as a governance layer between the MCP server and the Salesforce platform.

**Without AgentGov:** MCP server makes Salesforce API calls directly, with no budget limits, no policy checks, and no conflict awareness.

**With AgentGov:** MCP server calls AgentGov's REST API before every Salesforce action. AgentGov checks the circuit breaker, evaluates policies, consumes budget, and detects conflicts -- then returns an authorization decision.

```
MCP Server → AgentGov REST API (/authorize) → Salesforce Action
```

---

## Step 1: Create a Connected App

Create a Connected App in Salesforce for server-to-server authentication.

1. Navigate to **Setup > App Manager > New Connected App**
2. Configure:
   - **Connected App Name:** AgentGov MCP Integration
   - **API (Enable OAuth Settings):** Checked
   - **Callback URL:** `https://login.salesforce.com/services/oauth2/callback` (not used for server-to-server)
   - **Selected OAuth Scopes:** `api`, `refresh_token`
   - **Enable Client Credentials Flow:** Checked (recommended for server-to-server)
3. Save and note the **Client ID** and **Client Secret**

---

## Step 2: Create a Dedicated Integration User

Create a Salesforce user for the MCP integration:

1. Create a user with the **Salesforce API Only** profile (or a custom profile with API access)
2. Assign the **AgentGov_User** permission set
3. Associate this user with the Connected App (under the Connected App's Manage settings, set the Run As user)

---

## Step 3: Register the MCP Agent

Register your MCP agent with AgentGov. You can do this via the REST API or via Apex:

### Via REST API

```bash
# First, obtain an OAuth token
ACCESS_TOKEN=$(curl -s -X POST https://login.salesforce.com/services/oauth2/token \
  -d "grant_type=client_credentials" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" | jq -r '.access_token')

# Register the agent
curl -X POST \
  https://myinstance.salesforce.com/services/apexrest/agentgov/register \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agentName": "Lead Enrichment MCP Agent",
    "agentType": "MCP_External",
    "description": "MCP server that enriches leads with firmographic data",
    "apiKey": "mcp-lead-enrichment-unique-key-123",
    "ownerEmail": "mcp-admin@yourcompany.com"
  }'
```

Save the returned `registrationId`. You also need to activate the agent via Apex (or create an admin Flow to do this):

```apex
AgentGovRegistryService.activateAgent('a0B5g00000XXXXXXXX');
```

---

## Step 4: Configure the MCP Server

In your MCP server configuration, add a tool that calls AgentGov before every Salesforce action.

### Example: Node.js MCP Server

```javascript
// agentgov-client.js
class AgentGovClient {
  constructor(instanceUrl, accessToken, apiKey) {
    this.instanceUrl = instanceUrl;
    this.accessToken = accessToken;
    this.apiKey = apiKey;
  }

  async authorize(objectName, operation, recordId = null) {
    const body = {
      apiKey: this.apiKey,
      objectName,
      operation,
      ...(recordId && { recordId })
    };

    const response = await fetch(
      `${this.instanceUrl}/services/apexrest/agentgov/authorize`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${this.accessToken}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(body)
      }
    );

    const result = await response.json();

    if (!response.ok) {
      throw new Error(
        `AgentGov denied: ${result.error} (${result.errorCode})`
      );
    }

    return result;
  }

  async checkBudget(agentId) {
    const response = await fetch(
      `${this.instanceUrl}/services/apexrest/agentgov/budget/${agentId}`,
      {
        headers: { 'Authorization': `Bearer ${this.accessToken}` }
      }
    );
    return response.json();
  }

  async checkHealth(agentId) {
    const response = await fetch(
      `${this.instanceUrl}/services/apexrest/agentgov/health/${agentId}`,
      {
        headers: { 'Authorization': `Bearer ${this.accessToken}` }
      }
    );
    return response.json();
  }
}
```

### Example: MCP Tool Definition

```javascript
// In your MCP server tool definitions
const tools = [
  {
    name: 'update_lead',
    description: 'Update a lead record in Salesforce',
    inputSchema: {
      type: 'object',
      properties: {
        recordId: { type: 'string', description: 'Lead record ID' },
        fields: { type: 'object', description: 'Fields to update' }
      },
      required: ['recordId', 'fields']
    },
    handler: async ({ recordId, fields }) => {
      // Step 1: Authorize via AgentGov
      const auth = await agentGovClient.authorize('Lead', 'Update', recordId);

      if (!auth.authorized) {
        return { error: 'Action not authorized by governance framework' };
      }

      // Step 2: Perform the actual Salesforce update
      const result = await salesforceClient.update('Lead', recordId, fields);

      return {
        success: true,
        budgetStatus: auth.budgetStatus,
        remainingBudget: auth.remainingBudget
      };
    }
  }
];
```

### Example: Python MCP Server

```python
import requests

class AgentGovClient:
    def __init__(self, instance_url, access_token, api_key):
        self.instance_url = instance_url
        self.headers = {
            'Authorization': f'Bearer {access_token}',
            'Content-Type': 'application/json'
        }
        self.api_key = api_key

    def authorize(self, object_name, operation, record_id=None):
        payload = {
            'apiKey': self.api_key,
            'objectName': object_name,
            'operation': operation,
        }
        if record_id:
            payload['recordId'] = record_id

        resp = requests.post(
            f'{self.instance_url}/services/apexrest/agentgov/authorize',
            headers=self.headers,
            json=payload
        )

        if resp.status_code != 200:
            data = resp.json()
            raise Exception(
                f"AgentGov denied: {data.get('error')} ({data.get('errorCode')})"
            )

        return resp.json()

    def check_health(self, agent_id):
        resp = requests.get(
            f'{self.instance_url}/services/apexrest/agentgov/health/{agent_id}',
            headers=self.headers
        )
        return resp.json()
```

---

## Step 5: Error Handling

Your MCP server should handle AgentGov errors gracefully. The most common error scenarios:

| HTTP Status | Error Code | Action |
|-------------|-----------|--------|
| 429 | `BUDGET_EXCEEDED` | Stop making requests for this agent today. Check budget endpoint for details. |
| 503 | `CIRCUIT_BREAKER_OPEN` | The agent has been disabled due to repeated failures. Check health endpoint for cooldown time. Retry after `cooldownUntil`. |
| 403 | `POLICY_VIOLATION` | The agent is not allowed to perform this action. Review policies in Salesforce Setup. |
| 409 | `RECORD_LOCKED` | Another agent with higher priority is working on this record. Retry later or skip this record. |

### Recommended Error Handling Pattern

```javascript
async function governedAction(objectName, operation, recordId, action) {
  try {
    const auth = await agentGovClient.authorize(objectName, operation, recordId);
    return await action();
  } catch (error) {
    if (error.message.includes('BUDGET_EXCEEDED')) {
      console.log('Budget exhausted. Pausing agent until tomorrow.');
      return { skipped: true, reason: 'budget_exceeded' };
    }
    if (error.message.includes('CIRCUIT_BREAKER_OPEN')) {
      const health = await agentGovClient.checkHealth(agentId);
      console.log(`Agent blocked until: ${health.cooldownUntil}`);
      return { skipped: true, reason: 'circuit_breaker', retryAfter: health.cooldownUntil };
    }
    if (error.message.includes('RECORD_LOCKED')) {
      console.log('Record locked by another agent. Skipping.');
      return { skipped: true, reason: 'record_locked' };
    }
    throw error;  // Re-throw unexpected errors
  }
}
```

---

## Step 6: Monitoring

Use the health and budget endpoints to build monitoring into your MCP server:

```javascript
// Periodic health check (e.g., every 5 minutes)
setInterval(async () => {
  const health = await agentGovClient.checkHealth(agentId);
  console.log(`Agent status: ${health.status}, CB: ${health.circuitBreakerState}`);

  if (health.circuitBreakerState === 'OPEN') {
    console.warn('Circuit breaker is OPEN. Agent is disabled.');
    // Pause processing or switch to fallback
  }
}, 5 * 60 * 1000);

// Budget check before batch operations
const budget = await agentGovClient.checkBudget(agentId);
if (budget.remaining.dmlOperations < recordsToProcess) {
  console.warn('Insufficient DML budget for batch. Reducing batch size.');
  recordsToProcess = Math.floor(budget.remaining.dmlOperations * 0.9);
}
```

---

## Security Considerations

1. **API Key Storage:** Store the AgentGov API key securely (environment variables, secrets manager). Never hardcode it.
2. **OAuth Token Rotation:** Refresh OAuth tokens before they expire. Use the refresh token flow or short-lived tokens from the client credentials flow.
3. **Network Security:** All communication should use HTTPS. Consider IP restrictions on the Connected App.
4. **Principle of Least Privilege:** Create policies that allow only the specific objects and operations your MCP agent needs. Use the `MCP_External` agent type for targeted policy control.
