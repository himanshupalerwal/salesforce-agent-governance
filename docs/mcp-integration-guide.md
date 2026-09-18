# MCP Integration Guide

This guide explains how to put an external agent that speaks the Model Context Protocol
(MCP) under AgentGov governance. It covers the recommended setup on today's platform:
an External Client App for OAuth, a dedicated integration user bound to an AgentGov
registration, and the governed proxy as the tool surface the MCP server exposes.

---

## How the pieces fit

```
MCP client (Claude, an IDE, a custom host)
        │  MCP
        ▼
Your MCP server ──── OAuth 2.0 (External Client App) ────▶ Salesforce
        │                                                    │
        │  POST /agentgov-proxy/query|create|update|delete   │
        └──────────────────────────────────────────────────▶ AgentGov
                                                             ├─ circuit breaker
                                                             ├─ policy (object, operation, fields, record cap)
                                                             ├─ conflict detection
                                                             ├─ field-level security (user mode)
                                                             ├─ budget (charged by real record count)
                                                             └─ audit log
```

The MCP server never sends SOQL and never touches the standard REST API directly. Each
tool it exposes maps to one proxy endpoint, so every tool call is governed and charged by
what it actually did.

If your org is on Enterprise Edition or above, Salesforce Hosted MCP Servers can expose
Apex invocable actions and Flows as MCP tools directly; wrapping those actions with
AgentGov's governance pipeline is on the roadmap for v1.3. The approach in this guide works
on any edition that supports Apex.

---

## Step 1: Create an External Client App

Connected App creation is disabled by default in orgs on Spring '26 and later, so use an
External Client App (ECA).

1. **Setup → App Manager → New External Client App**.
2. Enable OAuth and choose the flow that fits your server:
   - **Client Credentials** for a server-to-server integration with a dedicated run-as user.
   - **JWT Bearer** if you prefer a certificate-based flow.
3. Select the `api` scope (add `refresh_token` if you use a refresh flow).
4. In the OAuth policies, set the **run-as user** to the integration user created in step 2.
5. Note the consumer key and secret; store them in your server's secret manager.

---

## Step 2: Create the integration user and bind it to a registration

1. Create a user with a minimal profile (for example **Minimum Access - Salesforce**) and
   API access.
2. Assign the **`AgentGov_Agent`** permission set. It grants the AgentGov REST classes and
   nothing else; the framework records its own bookkeeping in system mode, so the user
   needs no access to AgentGov objects.
3. Grant the user access to the **customer data** the agent should work with (objects,
   fields, sharing). The proxy runs in user mode, so this is where you decide what the agent
   can touch. Least privilege applies.
4. Register the agent and bind the user. Run as an administrator:

```apex
AgentGov_Registration__c agent = AgentGovRegistryService.registerAgent(
    'Data Sync MCP Agent',
    AgentGovConstants.AGENT_TYPE_MCP_EXTERNAL,
    'Synchronizes accounts between Salesforce and the data warehouse',
    null,                             // no API key: the user binding is the credential
    'integrations@example.com'
);
AgentGovRegistryService.bindAgentUser(agent.Id, integrationUserId);
AgentGovRegistryService.activateAgent(agent.Id);
```

Once bound, every REST call the integration user makes is attributed to this registration
without any key. If your server must serve several agents through one user, give each
registration its own key instead (`AgentGovRegistryService.issueApiKey(agent.Id)`) and send
it in the `X-AgentGov-Key` header.

---

## Step 3: Add policies and budgets

Policies live in `AgentGov_Policy__mdt`. A typical set for an external agent:

```
MCP_External_Account_Read      Agent Type: MCP_External   Object: Account   Operation: Query    Allowed: true   Max Records: 200
MCP_External_Account_Update    Agent Type: MCP_External   Object: Account   Operation: Update   Allowed: true   Field Restrictions: AnnualRevenue, Phone
MCP_External_Account_Delete    Agent Type: MCP_External   Object: Account   Operation: Delete   Allowed: false
```

The proxy enforces all three dimensions: an operation that is denied returns
`POLICY_VIOLATION`; a request that reads or writes a restricted field is denied rather
than silently trimmed; a request over the record cap is rejected before anything runs.

Daily budgets come from the registration (`Daily_API_Budget__c`, `Daily_SOQL_Budget__c`,
`Daily_DML_Budget__c`). See the configuration guide for thresholds.

---

## Step 4: Expose the proxy as MCP tools

Give the MCP server one tool per proxy endpoint and let the model fill in the structured
arguments. Because `/query` takes an object name, a field list, and typed conditions rather
than SOQL, the tool schema is straightforward and the model cannot express anything the
policy engine cannot check.

```json
{
  "name": "salesforce_query",
  "description": "Read records from Salesforce under AgentGov governance.",
  "inputSchema": {
    "type": "object",
    "required": ["objectName", "fields"],
    "properties": {
      "objectName": { "type": "string" },
      "fields": { "type": "array", "items": { "type": "string" } },
      "where": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["field", "op", "value"],
          "properties": {
            "field": { "type": "string" },
            "op": { "type": "string", "enum": ["=", "!=", "<", "<=", ">", ">=", "LIKE", "IN", "NOT IN"] },
            "value": {}
          }
        }
      },
      "orderBy": {
        "type": "object",
        "properties": { "field": { "type": "string" }, "direction": { "type": "string", "enum": ["ASC", "DESC"] } }
      },
      "limit": { "type": "integer", "minimum": 1, "maximum": 2000 }
    }
  }
}
```

The tool handler forwards the arguments to the proxy unchanged:

```javascript
async function salesforceQuery(args, session) {
  const response = await fetch(`${session.instanceUrl}/services/apexrest/agentgov-proxy/query`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${session.accessToken}`,
      'Content-Type': 'application/json',
      'X-Correlation-Id': session.traceId
    },
    body: JSON.stringify(args)
  });
  const body = await response.json();
  if (!body.success) {
    // errorCode is one of the documented codes; message is safe to show the model.
    throw new Error(`${body.errorCode}: ${body.message} (correlationId ${body.correlationId})`);
  }
  return body.records;
}
```

Define `salesforce_create`, `salesforce_update`, `salesforce_delete`, and
`salesforce_upsert` the same way against `/create`, `/update`, `/delete`, and `/upsert`.
Send an `X-Correlation-Id` so a denied or failed tool call can be matched to its audit row.

---

## Step 5: Handle governance outcomes

| `errorCode`            | What the server should do                                                            |
| ---------------------- | ------------------------------------------------------------------------------------ |
| `BUDGET_EXCEEDED`      | Stop for the day, or fall back to a lower-cost plan. The budget resets at midnight.  |
| `CIRCUIT_BREAKER_OPEN` | Back off. The breaker probes recovery after the cooldown; retrying sooner is denied. |
| `POLICY_VIOLATION`     | Do not retry; tell the model which operation, field, or record count was refused.    |
| `ACCESS_DENIED`        | The integration user lacks object or field access; an administrator must grant it.   |
| `RECORD_LOCKED`        | Another agent holds the record; retry later or work on other records.                |
| `INTERNAL_ERROR`       | Report the `correlationId` to an administrator; the details are in the action log.   |

Successful writes return per-record results, so partial failures (a validation rule, a
duplicate rule) are visible to the model without failing the whole call.

---

## Monitoring

- **AgentGov Dashboard** app: budgets, breaker state, sessions, conflicts, live-updating.
- **`AgentGov_Action_Log__c`**: every proxy call with status `Success`, `Failure`, or
  `Denied`, plus `System` rows for framework-level problems.
- **Platform events** `AgentGov_Alert__e` (budget thresholds, breaker trips) and
  `AgentGov_Action_Event__e` (every action). Subscribe from a Streaming API client or a
  Flow, and set `Admin_Notification_Email__c` in AgentGov Settings to receive alert emails.

---

## Security checklist

- Store the ECA consumer secret and any API keys in a secret manager; never in code.
- Prefer the user binding over API keys. When keys are unavoidable, send them only in the
  `X-AgentGov-Key` header and rotate them with `POST /rotate-key`.
- Keep the integration user's data access to the minimum the agent needs; the proxy
  enforces exactly that access.
- Use `Max_Records_Per_Transaction__c` and `Field_Restrictions__c` on policies to bound what
  a single tool call can do.
- Watch the `System` rows in the action log; they surface delivery failures and unhandled
  errors with their correlation ids.
