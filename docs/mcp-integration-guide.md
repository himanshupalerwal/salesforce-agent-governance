# MCP Integration Guide

This guide explains how to put an external agent that speaks the Model Context Protocol
(MCP) under AgentGov governance. It covers the recommended setup on today's platform:
an External Client App for OAuth, a dedicated integration user bound to an AgentGov
registration, and the governed proxy as the tool surface the MCP server exposes.

---

## How the pieces fit

```
MCP client (a desktop app, an IDE, a custom host)
        │  MCP
        ▼
Your MCP server ──── OAuth 2.0 (External Client App) ────▶ Salesforce
        │                                                    │
        │  POST /agentgov-proxy/<endpoint>                   │
        └──────────────────────────────────────────────────▶ AgentGov
                                                             ├─ identify the agent, check its status
                                                             ├─ validate the whole request
                                                             ├─ circuit breaker
                                                             ├─ policy (operation, record cap, fields)
                                                             ├─ conflicts (writes to existing records)
                                                             ├─ the user's access, in user mode
                                                             ├─ budget (1 SOQL per query, 1 DML per record)
                                                             ├─ execution in user mode
                                                             └─ breaker outcome and audit log
```

The MCP server never sends SOQL and never touches the standard REST API directly. Each tool
it exposes maps to one proxy endpoint, `/query`, `/create`, `/update`, `/delete` or `/upsert`,
so every tool call is governed. A query is charged one SOQL query however many rows it
returns, and a write one DML operation per record submitted, including records the database
then rejects. The [REST API Reference](rest-api-reference.md#the-governed-proxy-agentgov-proxy)
describes each step.

If your org is on Enterprise Edition or above, Salesforce Hosted MCP Servers can expose
Apex invocable actions and Flows as MCP tools directly; wrapping those actions with
AgentGov's governance pipeline is on the roadmap for v1.4. The approach in this guide works
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
4. Register the agent and bind the user. Run as an administrator, in Execute Anonymous, with
   the integration user's username in the first line:

```apex
Id integrationUserId = [SELECT Id FROM User WHERE Username = 'mcp.integration@example.com' LIMIT 1].Id;

AgentGov_Registration__c agent = AgentGovRegistryService.registerAgent(
    'Data Sync MCP Agent',
    AgentGovConstants.AGENT_TYPE_MCP_EXTERNAL,
    'Synchronizes accounts between Salesforce and the data warehouse',
    null, // no API key: the user binding is the credential
    'integrations@example.com'
);
AgentGovRegistryService.bindAgentUser(agent.Id, integrationUserId);
AgentGovRegistryService.activateAgent(agent.Id);
```

Once bound, every REST call the integration user makes is attributed to this registration
without any key. If your server must serve several agents through one user, give each
registration its own key instead (`AgentGovRegistryService.issueApiKey(agent.Id)`) and send
it in the `X-AgentGov-Key` header. A keyless call from a user bound to more than one
registration is refused with `ACCESS_DENIED`, because the login alone cannot say which agent
is calling.

---

## Step 3: Add policies and budgets

Policies live in `AgentGov_Policy__mdt`. A typical set for an external agent:

```
MCP_External_Account_Read      Agent Type: MCP_External   Object: Account   Operation: Query    Allowed: true   Max Records: 200
MCP_External_Account_Update    Agent Type: MCP_External   Object: Account   Operation: Update   Allowed: true   Field Restrictions: AnnualRevenue, Phone
MCP_External_Account_Delete    Agent Type: MCP_External   Object: Account   Operation: Delete   Allowed: false
```

The first and the last ship with AgentGov as examples. The agent type may be written as the
stored value or the label shown on records (`MCP_External` or `MCP External`), in any letter
case, or `All`.

The proxy enforces all three dimensions: an operation that is denied returns
`POLICY_VIOLATION`; a request that reads or writes a restricted field is denied rather
than silently trimmed; a write with more records than the cap is rejected with
`POLICY_VIOLATION` before anything is charged or written. A query is capped rather than
rejected: `/query` returns at most the cap's number of rows, never more than 2,000, and
succeeds with 200.

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
    "additionalProperties": false,
    "properties": {
      "objectName": { "type": "string", "description": "Object API name, such as Account" },
      "fields": {
        "type": "array",
        "minItems": 1,
        "items": { "type": "string" },
        "description": "Field API names on that object; relationship paths are not accepted"
      },
      "where": {
        "type": "array",
        "description": "Conditions, combined with AND",
        "items": {
          "type": "object",
          "required": ["field", "op", "value"],
          "properties": {
            "field": { "type": "string" },
            "op": { "type": "string", "enum": ["=", "!=", "<", "<=", ">", ">=", "LIKE", "IN", "NOT IN"] },
            "value": { "description": "A string, number, boolean or null; an array of them for IN and NOT IN" }
          }
        }
      },
      "orderBy": {
        "type": "object",
        "required": ["field"],
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
  if (body.success !== true) {
    // AgentGov's own refusals carry errorCode, message, and correlationId; the message is safe
    // to show the model. Anything else comes from the platform, such as an expired token.
    const detail = body.errorCode
      ? `${body.errorCode}: ${body.message} (correlationId ${body.correlationId})`
      : `HTTP ${response.status}: ${JSON.stringify(body)}`;
    throw new Error(detail);
  }
  return body.records;
}
```

Define `salesforce_create`, `salesforce_update`, `salesforce_delete`, and
`salesforce_upsert` the same way against `/create`, `/update`, `/delete`, and `/upsert`.
Send an `X-Correlation-Id` so a denied or failed tool call can be matched to its audit row.
A call refused with 400 `INVALID_INPUT`, or whose credential does not resolve to an agent,
is not charged and leaves no audit row; its `message` says what to correct.

---

## Step 5: Handle governance outcomes

| `errorCode`            | What the server should do                                                                                                                                                                                                                                                                                                                             |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BUDGET_EXCEEDED`      | Stop calling. Once the budget is Blocked or Exhausted, every governed call is refused, whatever it would cost, and each refused call still adds its own units to the ledger. The budget renews at midnight in the org's default time zone; an administrator can credit usage back sooner with **Credit budget** in the console.                       |
| `AGENT_NOT_ACTIVE`     | The agent is deactivated, or its circuit breaker tripped and set it to `Blocked`. Back off: a Blocked agent is admitted again once the cooldown has passed, when the next request becomes the breaker's single probe. A deactivated agent stays refused until an administrator activates it.                                                          |
| `CIRCUIT_BREAKER_OPEN` | Back off. The breaker admits a single probe request and another request already holds it, or the breaker is OPEN while the agent was set back to Active by hand. Retry after the probe has settled or the cooldown has passed.                                                                                                                        |
| `POLICY_VIOLATION`     | Do not retry; tell the model which operation, field, or record count was refused.                                                                                                                                                                                                                                                                     |
| `ACCESS_DENIED`        | The integration user lacks the object, field, or delete access the call needs, and the message names what is missing; an administrator must grant it. Nothing was charged. The same code is returned for a keyless call from a user bound to more than one registration. Granting access does not fix that; send the agent's key in `X-AgentGov-Key`. |
| `AGENT_NOT_FOUND`      | Fix the configuration; do not retry. The credential no longer resolves to an agent: the user's binding was removed, or the key was rotated or never existed. The same code answers a path AgentGov does not serve.                                                                                                                                    |
| `INVALID_INPUT`        | Fix the arguments; the message names the field, operator, or value at fault. Nothing was charged or logged, and the call did not reach the circuit breaker.                                                                                                                                                                                           |
| `INTERNAL_ERROR`       | Report the `correlationId` to an administrator; the details are in one `System` row in the action log. Everything the request wrote, budget charges included, was rolled back before that row was recorded, so a retry cannot create anything twice.                                                                                                  |

The proxy does not return `RECORD_LOCKED` in practice. Conflicts are detected between agents
within one transaction, in practice a Register Agent Action batch in Flow, and each proxy
request serves one agent in its own transaction. Two agents that write the same record through
separate requests are not stopped by AgentGov, so coordinate them in your server where that
matters. Locking across requests is on the roadmap for v2.0.

Successful writes return per-record results, so partial failures (a validation rule, a
duplicate rule) are visible to the model without failing the whole call.

---

## Monitoring

- The **AgentGov** app's **AgentGov Dashboard** tab opens the console: agents, budgets,
  breaker state, sessions, activity, and conflicts. It updates when AgentGov platform events
  arrive, and on **Refresh**.
- **`AgentGov_Action_Log__c`**: each governed proxy call, with status `Success`, `Failure`, or
  `Denied`, plus `System` rows for framework-level problems such as unhandled errors. A call
  refused with 400 `INVALID_INPUT`, or whose credential does not resolve to an agent, leaves no
  row.
- **Platform events** `AgentGov_Alert__e` (budget thresholds, breaker trips) and
  `AgentGov_Action_Event__e` (logged actions). Both are published only while
  `Enable_Real_Time_Events__c` is checked; with it unchecked, action-log rows are written
  directly and no alerts are raised. Events are published as the calling user, and
  `AgentGov_Agent` deliberately grants no access to them, so an integration user with only that
  permission set publishes neither: its action-log rows are written directly, and its alerts
  are recorded as `Alert` rows and emailed directly, with one `System` row noting that they
  could not be published. The action log, not the event stream, is therefore the complete
  record, and such activity reaches an open console on its next refresh. Subscribe from a
  Streaming API client or a Flow, and set `Admin_Notification_Email__c` in AgentGov Settings to
  receive alert emails.

---

## Security checklist

- Store the ECA consumer secret and any API keys in a secret manager; never in code.
- Prefer the user binding over API keys. When keys are unavoidable, send them only in the
  `X-AgentGov-Key` header and rotate them with `POST /services/apexrest/agentgov/rotate-key`,
  or with **Rotate key** in the console, which needs the AgentGov Manage Keys permission.
- Keep the integration user's data access to the minimum the agent needs; the proxy
  enforces exactly that access.
- Use `Max_Records_Per_Transaction__c` and `Field_Restrictions__c` on policies to bound what
  a single tool call can do.
- Watch the `System` rows in the action log; they surface delivery failures and unhandled
  errors with their correlation ids.
