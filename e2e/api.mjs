/**
 * API scenarios. Each one drives the deployed framework over real HTTP the way its callers do,
 * then checks the records the framework left behind. Nothing here calls Apex methods directly
 * except where an administrator would (activating an agent, running a scheduled job now).
 */
import { createHash, randomBytes } from 'node:crypto';
import { ensure, Suite } from './lib/checks.mjs';
import { quote, sf, sleep, waitFor } from './lib/sf.mjs';
import { localDate } from './setup.mjs';

// The e2e settings make both the breaker cooldown and the session idle window one minute.
const COOL_DOWN_WAIT_MS = 75 * 1000;
const ASYNC_TIMEOUT_MS = 45 * 1000;

const JOB_NAMES = ['AgentGov Daily Reset', 'AgentGov Health Check', 'AgentGov Cleanup'];

/**
 * Runs every API scenario and returns the check results.
 * @param {{ admin, agentUser, orgTimeZone, runId: string }} context From setup.prepareOrg plus a run id
 */
export async function runApiSuite({ admin, agentUser, orgTimeZone, runId }) {
    const suite = new Suite('api');
    const correlation = (label) => `e2e-${runId}-${label}`;

    // --- Helpers ---------------------------------------------------------------------------

    async function register(label, agentType = 'Custom_Apex') {
        const response = await admin.apexRest('POST', '/agentgov/register', {
            body: {
                agentName: `E2E ${label} ${runId}`,
                agentType,
                description: 'Created by the end-to-end suite',
                ownerEmail: 'owner@example.com'
            }
        });
        if (response.status !== 201) {
            throw new Error(`register ${label}: ${response.status} ${JSON.stringify(response.body)}`);
        }
        return { label, id: response.body.registrationId, key: response.body.apiKey, response };
    }

    async function activate(...agents) {
        await admin.apex(agents.map((agent) => `AgentGovRegistryService.activateAgent('${agent.id}');`).join('\n'));
    }

    async function setFields(agent, fields) {
        const assignments = Object.entries(fields)
            .map(([name, value]) => `${name} = ${typeof value === 'string' ? quote(value) : value}`)
            .join(', ');
        await admin.apex(`update new AgentGov_Registration__c(Id = '${agent.id}', ${assignments});`);
    }

    function headersFor(agent, correlationId) {
        const headers = { 'X-AgentGov-Key': agent.key };
        if (correlationId) {
            headers['X-Correlation-Id'] = correlationId;
        }
        return headers;
    }

    const authorize = (agent, body, correlationId) =>
        admin.apexRest('POST', '/agentgov/authorize', { headers: headersFor(agent, correlationId), body });
    const proxy = (agent, path, body, correlationId) =>
        admin.apexRest('POST', `/agentgov-proxy${path}`, { headers: headersFor(agent, correlationId), body });
    const reportOutcome = (agent, success) =>
        admin.apexRest('POST', '/agentgov/report', {
            headers: headersFor(agent),
            body: { actual: { apiCalls: 0 }, success }
        });
    const health = (agent) => admin.apexRest('GET', `/agentgov/health/${agent.id}`);

    async function optionalFields(sobject, names) {
        const present = await admin.fieldNames(sobject);
        return names.filter((name) => present.has(name));
    }

    async function requireField(sobject, name) {
        ensure((await admin.fieldNames(sobject)).has(name), `${sobject}.${name} does not exist`);
    }

    async function auditRows(agent, where = '') {
        const extra = await optionalFields('AgentGov_Action_Log__c', ['Correlation_Id__c']);
        const fields = [
            'Id',
            'Action_Type__c',
            'Status__c',
            'Object_Name__c',
            'Record_Id__c',
            'Details__c',
            'Error_Message__c',
            'Execution_Time_Ms__c',
            'Agent_Session__c',
            'Timestamp__c',
            ...extra
        ];
        return admin.query(
            `SELECT ${fields.join(', ')} FROM AgentGov_Action_Log__c WHERE Agent_Registration__c = '${agent.id}'` +
                `${where ? ` AND ${where}` : ''} ORDER BY Timestamp__c ASC`
        );
    }

    // Audit rows are written by a platform-event trigger after the request commits.
    async function waitForAudit(agent, where, count = 1) {
        const rows = await waitFor(
            async () => {
                const found = await auditRows(agent, where);
                return found.length >= count ? found : null;
            },
            { timeoutMs: ASYNC_TIMEOUT_MS }
        );
        return rows ?? [];
    }

    async function sessionsOf(agent) {
        const extra = await optionalFields('AgentGov_Session__c', ['Last_Activity__c', 'End_Reason__c']);
        return admin.query(
            `SELECT Id, Status__c, Session_Start__c, Session_End__c, Actions_Count__c, API_Calls_Used__c, ` +
                `SOQL_Queries_Used__c, DML_Statements_Used__c${extra.map((name) => `, ${name}`).join('')} ` +
                `FROM AgentGov_Session__c WHERE Agent_Registration__c = '${agent.id}' ORDER BY Session_Start__c ASC`
        );
    }

    async function latestBudget(agent) {
        const [row] = await admin.query(
            `SELECT Id, Budget_Date__c, Budget_Status__c, API_Calls_Consumed__c, SOQL_Queries_Consumed__c, ` +
                `DML_Operations_Consumed__c FROM AgentGov_Budget__c WHERE Agent_Registration__c = '${agent.id}' ` +
                `ORDER BY Budget_Date__c DESC LIMIT 1`
        );
        return row;
    }

    async function registrationOf(agent) {
        const [row] = await admin.query(
            `SELECT Status__c, Circuit_Breaker_State__c, Cooldown_Until__c, Last_Active__c ` +
                `FROM AgentGov_Registration__c WHERE Id = '${agent.id}'`
        );
        return row;
    }

    const describeResponse = (response) => `${response.status} ${JSON.stringify(response.body).slice(0, 300)}`;
    const outputOf = (response, index = 0) => response.body?.[index]?.outputValues ?? {};

    // --- A. Registration and credentials -----------------------------------------------------

    let writer;
    await suite.check(
        'A1',
        'Registering an agent over REST returns 201, its registration number, a one-time key and an Inactive agent',
        async () => {
            writer = await register('Writer');
            ensure(writer.key?.startsWith('agk_'), `expected an agk_ key, got ${writer.key}`);
            ensure(writer.response.body.status === 'Inactive', `new agent status ${writer.response.body.status}`);
            const [saved] = await admin.query(`SELECT Name FROM AgentGov_Registration__c WHERE Id = '${writer.id}'`);
            ensure(
                writer.response.body.registrationNumber === saved.Name,
                `returned registration number ${writer.response.body.registrationNumber}, saved as ${saved.Name}`
            );
        }
    );

    await suite.check('A2', 'Only the SHA-256 hash and a short prefix of the key are stored', async () => {
        const [row] = await admin.query(
            `SELECT API_Key__c, API_Key_Hash__c, API_Key_Prefix__c FROM AgentGov_Registration__c WHERE Id = '${writer.id}'`
        );
        ensure(row.API_Key__c == null, 'the plaintext key column is populated');
        ensure(
            row.API_Key_Hash__c === createHash('sha256').update(writer.key).digest('hex'),
            'the stored hash is not the SHA-256 of the issued key'
        );
        ensure(row.API_Key_Prefix__c === writer.key.slice(0, 12), `stored prefix ${row.API_Key_Prefix__c}`);
    });

    await suite.check('A3', 'An inactive agent is refused', async () => {
        const response = await authorize(writer, { objectName: 'Account', operation: 'Query' });
        ensure(response.status === 403 && response.body.errorCode === 'AGENT_NOT_ACTIVE', describeResponse(response));
    });

    await suite.check('A4', 'An unknown key is refused without exposing internal detail', async () => {
        const stranger = { key: `agk_${randomBytes(32).toString('hex')}` };
        const response = await authorize(stranger, { objectName: 'Account', operation: 'Query' });
        ensure(response.status === 404 && response.body.errorCode === 'AGENT_NOT_FOUND', describeResponse(response));
        ensure(!/exception|stack|\.cls|line \d+/i.test(JSON.stringify(response.body)), 'the error leaks internals');
    });

    await suite.check('A5', 'An activated agent is authorized', async () => {
        await activate(writer);
        const response = await authorize(writer, { objectName: 'Account', operation: 'Query' }, correlation('A5'));
        ensure(response.status === 200 && response.body.authorized === true, describeResponse(response));
    });

    const retired = await register('Retired');
    await activate(retired);
    await suite.check(
        'A6',
        'A deactivated agent is refused on every entry point: REST, the proxy, the Flow actions, and Apex',
        async () => {
            await admin.apex(`AgentGovRegistryService.deactivateAgent('${retired.id}');`);
            const refusals = [];
            const rest = await authorize(retired, { objectName: 'Account', operation: 'Query' });
            refusals.push(['REST /authorize', rest.status === 403]);
            const proxied = await proxy(retired, '/query', { objectName: 'Account', fields: ['Id'], limit: 1 });
            refusals.push(['proxy /query', proxied.status === 403]);
            const flow = outputOf(
                await admin.action('AgentGovRegisterAction', [
                    { registrationId: retired.id, actionType: 'Query', objectName: 'Account' }
                ])
            );
            refusals.push(['Register Agent Action', flow.authorized === false]);
            const report = outputOf(
                await admin.action('AgentGovReportUsage', [{ registrationId: retired.id, apiCallsUsed: 1 }])
            );
            refusals.push(['Report Agent Usage', report.allowed === false]);
            let apexRefused = false;
            try {
                await admin.apex(`AgentGovContext.startTracking('${retired.id}');`);
            } catch (error) {
                apexRefused = /not in Active status/i.test(error.message);
            }
            refusals.push(['AgentGovContext', apexRefused]);
            const admitted = refusals.filter(([, refused]) => !refused).map(([entry]) => entry);
            ensure(admitted.length === 0, `still admitted by: ${admitted.join(', ')}`);
            const budget = await latestBudget(retired);
            const charged = budget
                ? (budget.API_Calls_Consumed__c ?? 0) +
                  (budget.SOQL_Queries_Consumed__c ?? 0) +
                  (budget.DML_Operations_Consumed__c ?? 0)
                : 0;
            ensure(charged === 0, `a deactivated agent was charged ${charged} units`);
        }
    );

    await suite.check(
        'A7',
        'A registration value the database rejects is refused with 400 and nothing is saved',
        async () => {
            const agentName = `E2E Bad Email ${runId}`;
            const response = await admin.apexRest('POST', '/agentgov/register', {
                body: { agentName, agentType: 'Custom_Apex', ownerEmail: 'not-an-email' }
            });
            ensure(response.status === 400 && response.body.errorCode === 'INVALID_INPUT', describeResponse(response));
            ensure(
                /Owner Email/.test(response.body.message ?? ''),
                `the message names no field: ${response.body.message}`
            );
            const saved = await admin.query(
                `SELECT Id FROM AgentGov_Registration__c WHERE Agent_Name__c = ${quote(agentName)}`
            );
            ensure(saved.length === 0, `${saved.length} registration(s) saved`);
        }
    );

    // --- B. A governed write through the proxy ----------------------------------------------

    const createCorrelation = correlation('B1');
    let createResponse;
    let accountIds = [];
    await suite.check('B1', 'A proxy create writes the records', async () => {
        createResponse = await proxy(
            writer,
            '/create',
            {
                objectName: 'Account',
                records: [{ Name: `E2E Account ${runId} 1` }, { Name: `E2E Account ${runId} 2` }]
            },
            createCorrelation
        );
        ensure(createResponse.status === 200, describeResponse(createResponse));
        accountIds = createResponse.body.results.filter((result) => result.success).map((result) => result.id);
        ensure(accountIds.length === 2, `${accountIds.length} of 2 records reported created`);
        const rows = await admin.query(`SELECT Id FROM Account WHERE Id IN (${accountIds.map(quote).join(', ')})`);
        ensure(rows.length === 2, `${rows.length} of 2 Accounts exist in the org`);
    });

    await suite.check('B2', "The response carries the caller's correlation id", async () => {
        ensure(
            createResponse?.body?.correlationId === createCorrelation,
            `body has ${createResponse?.body?.correlationId}`
        );
        ensure(
            createResponse.headers['x-correlation-id'] === createCorrelation,
            `header has ${createResponse.headers['x-correlation-id']}`
        );
    });

    await suite.check('B3', 'The budget is charged by the number of records written', async () => {
        const budget = await latestBudget(writer);
        ensure(
            budget?.DML_Operations_Consumed__c === 2,
            `DML consumed ${budget?.DML_Operations_Consumed__c}, expected 2`
        );
    });

    let createLog;
    await suite.check('B4', 'The write leaves an audit row', async () => {
        [createLog] = await waitForAudit(writer, "Action_Type__c = 'Create' AND Status__c = 'Success'");
        ensure(createLog, 'no Create/Success audit row appeared');
    });

    await suite.check('B5', 'The audit row carries the request correlation id', async () => {
        await requireField('AgentGov_Action_Log__c', 'Correlation_Id__c');
        ensure(createLog, 'no audit row to inspect');
        ensure(createLog.Correlation_Id__c === createCorrelation, `stored ${createLog.Correlation_Id__c}`);
    });

    await suite.check('B6', 'The audit row records how long the call took', async () => {
        ensure(createLog, 'no audit row to inspect');
        ensure(createLog.Execution_Time_Ms__c != null, 'Execution_Time_Ms__c is empty');
    });

    let writerSession;
    await suite.check('B7', "The agent's activity opened a session", async () => {
        const open = (await sessionsOf(writer)).filter((session) => session.Status__c === 'Active');
        ensure(open.length === 1, `${open.length} active sessions, expected 1`);
        writerSession = open[0];
    });

    await suite.check('B8', 'The session counts the actions and the usage', async () => {
        ensure(writerSession, 'no session to inspect');
        ensure(
            writerSession.Actions_Count__c === 2,
            `Actions_Count__c is ${writerSession.Actions_Count__c}, expected 2 (one authorize, one create)`
        );
        ensure(
            writerSession.SOQL_Queries_Used__c === 1 && writerSession.DML_Statements_Used__c === 2,
            `SOQL ${writerSession.SOQL_Queries_Used__c}, DML ${writerSession.DML_Statements_Used__c}; expected 1 and 2`
        );
    });

    await suite.check('B9', 'The audit row links to that session', async () => {
        ensure(createLog && writerSession, 'nothing to compare');
        ensure(createLog.Agent_Session__c === writerSession.Id, `linked to ${createLog.Agent_Session__c}`);
    });

    // --- C. Budget escalation ----------------------------------------------------------------

    const budgetAgent = await register('Budget');
    await setFields(budgetAgent, { Daily_API_Budget__c: 20 });
    await activate(budgetAgent);
    const spend = (amount) =>
        authorize(budgetAgent, { objectName: 'Account', operation: 'API_Call', amount }, correlation(`C-${amount}`));

    await suite.check('C1', '16 of 20 API calls puts the budget at Warning, still allowed', async () => {
        const response = await spend(16);
        ensure(response.status === 200 && response.body.budgetStatus === 'Warning', describeResponse(response));
    });

    await suite.check('C2', '18 of 20 puts it at Throttled, still allowed', async () => {
        const response = await spend(2);
        ensure(response.status === 200 && response.body.budgetStatus === 'Throttled', describeResponse(response));
    });

    await suite.check('C3', '19 of 20 crosses the block threshold and is refused with 429', async () => {
        const response = await spend(1);
        ensure(response.status === 429 && response.body.errorCode === 'BUDGET_EXCEEDED', describeResponse(response));
        const budget = await latestBudget(budgetAgent);
        ensure(budget.Budget_Status__c === 'Blocked', `budget status ${budget.Budget_Status__c}`);
    });

    await suite.check('C4', 'The refusal is audited', async () => {
        const [denied] = await waitForAudit(budgetAgent, "Status__c = 'Denied'");
        ensure(denied, 'no Denied audit row appeared');
        ensure(/budget exceeded/i.test(denied.Details__c ?? ''), `details: ${denied.Details__c}`);
    });

    await suite.check('C5', 'Each escalation is recorded as an alert (Warning, Throttle, Block)', async () => {
        const alerts = await waitForAudit(budgetAgent, "Action_Type__c = 'Alert'", 3);
        ensure(alerts.length === 3, `${alerts.length} alert rows recorded, expected 3`);
    });

    // --- D. Circuit breaker, first half: trip two agents -------------------------------------

    const breakerA = await register('Breaker A');
    const breakerB = await register('Breaker B');
    await activate(breakerA, breakerB);

    await suite.check('D1', 'Three failed outcomes open the breaker and block the agent', async () => {
        for (const agent of [breakerA, breakerB]) {
            for (let attempt = 0; attempt < 3; attempt++) {
                const response = await reportOutcome(agent, false);
                ensure(
                    response.status === 200,
                    `report ${attempt + 1} for ${agent.label}: ${describeResponse(response)}`
                );
            }
        }
        const state = await health(breakerA);
        ensure(
            state.body.circuitBreakerState === 'OPEN' && state.body.status === 'Blocked',
            `breaker ${state.body.circuitBreakerState}, status ${state.body.status}`
        );
    });

    await suite.check('D2', 'An agent with an open breaker is refused', async () => {
        const response = await authorize(breakerA, { objectName: 'Account', operation: 'Query' });
        ensure(response.status === 403 || response.status === 503, describeResponse(response));
    });

    await suite.check('D3', 'That refusal is audited', async () => {
        const [denied] = await waitForAudit(breakerA, "Status__c = 'Denied'");
        ensure(denied, 'no Denied audit row appeared for the refused request');
    });

    // --- E. Policy, bulk writes and the record cap -------------------------------------------

    const mcp = await register('MCP', 'MCP_External');
    await activate(mcp);

    await suite.check('E1', 'An operation a policy forbids is refused with 403 and nothing is deleted', async () => {
        ensure(accountIds.length, 'no Account from B1 to target');
        const response = await proxy(mcp, '/delete', { objectName: 'Account', ids: [accountIds[0]] });
        ensure(response.status === 403 && response.body.errorCode === 'POLICY_VIOLATION', describeResponse(response));
        const rows = await admin.query(`SELECT Id FROM Account WHERE Id = '${accountIds[0]}'`);
        ensure(rows.length === 1, 'the Account was deleted anyway');
    });

    await suite.check('E2', 'The policy refusal is audited', async () => {
        const [denied] = await waitForAudit(mcp, "Status__c = 'Denied' AND Action_Type__c = 'Delete'");
        ensure(denied, 'no Denied/Delete audit row appeared');
    });

    await suite.check('E3', 'A 205-record create is governed and charged in one call', async () => {
        const before = (await latestBudget(writer))?.DML_Operations_Consumed__c ?? 0;
        const records = Array.from({ length: 205 }, (_, index) => ({ Name: `E2E Bulk ${runId} ${index}` }));
        const response = await proxy(writer, '/create', { objectName: 'Account', records });
        ensure(response.status === 200 && response.body.recordsSucceeded === 205, describeResponse(response));
        const after = (await latestBudget(writer))?.DML_Operations_Consumed__c;
        ensure(after - before === 205, `DML consumed rose by ${after - before}, expected 205`);
    });

    await suite.check('E4', "A policy's record cap limits query results end to end", async () => {
        const response = await proxy(mcp, '/query', { objectName: 'Account', fields: ['Id', 'Name'], limit: 1000 });
        ensure(response.status === 200, describeResponse(response));
        ensure(
            response.body.totalSize === 200,
            `returned ${response.body.totalSize} rows; the shipped policy caps at 200`
        );
    });

    // --- F. Conflicts between agents in one transaction --------------------------------------

    const flowA = await register('Flow A', 'Flow_Based');
    const flowB = await register('Flow B', 'Flow_Based');
    await setFields(flowA, { Priority__c: 1 });
    await setFields(flowB, { Priority__c: 5 });
    await activate(flowA, flowB);

    let conflictResponse;
    await suite.check(
        'F1',
        'Two agents claiming one record in the same Flow batch: the higher priority wins',
        async () => {
            ensure(accountIds[1], 'no Account from B1 to contend for');
            conflictResponse = await admin.action('AgentGovRegisterAction', [
                { registrationId: flowA.id, actionType: 'Update', objectName: 'Account', recordId: accountIds[1] },
                { registrationId: flowB.id, actionType: 'Update', objectName: 'Account', recordId: accountIds[1] }
            ]);
            ensure(conflictResponse.status === 200, describeResponse(conflictResponse));
            const winner = outputOf(conflictResponse, 0);
            const loser = outputOf(conflictResponse, 1);
            ensure(
                winner.authorized === true,
                `priority 1 agent: authorized=${winner.authorized} ${winner.denialReason ?? ''}`
            );
            ensure(loser.authorized === false, `priority 5 agent: authorized=${loser.authorized}`);
        }
    );

    await suite.check('F2', 'The conflict is logged', async () => {
        const rows = await admin.query(
            `SELECT Agent_1__c, Agent_2__c, Resolution__c FROM AgentGov_Conflict_Log__c WHERE Record_Id__c = '${accountIds[1]}'`
        );
        ensure(rows.length >= 1, 'no conflict log row for the contested record');
    });

    // --- G. Flow actions over the REST actions endpoint --------------------------------------

    await suite.check('G1', 'Register Agent Action authorizes a Flow request and audits it', async () => {
        const response = await admin.action('AgentGovRegisterAction', [
            { registrationId: flowA.id, actionType: 'Query', objectName: 'Account' }
        ]);
        ensure(outputOf(response).authorized === true, describeResponse(response));
        const [row] = await waitForAudit(flowA, "Action_Type__c = 'Query' AND Status__c = 'Success'");
        ensure(row, 'no audit row for the Flow request');
    });

    await suite.check('G2', 'Check Budget reports the remaining budget', async () => {
        const output = outputOf(await admin.action('AgentGovCheckBudget', [{ registrationId: flowA.id }]));
        ensure(output.hasBudget === true && typeof output.soqlQueriesRemaining === 'number', JSON.stringify(output));
    });

    await suite.check('G3', 'Get Status reports a healthy agent', async () => {
        const output = outputOf(await admin.action('AgentGovGetStatus', [{ registrationId: flowA.id }]));
        ensure(
            output.agentStatus === 'Active' && output.circuitBreakerState === 'CLOSED' && output.isHealthy === true,
            JSON.stringify(output)
        );
    });

    await suite.check('G4', 'Log Action writes an audit row', async () => {
        const output = outputOf(
            await admin.action('AgentGovLogAction', [
                {
                    registrationId: flowA.id,
                    actionType: 'Flow_Trigger',
                    objectName: 'Account',
                    status: 'Success',
                    details: `Logged by the end-to-end suite ${runId}`
                }
            ])
        );
        ensure(output.success === true, JSON.stringify(output));
        const [row] = await waitForAudit(flowA, "Action_Type__c = 'Flow_Trigger'");
        ensure(row, 'no Flow_Trigger audit row appeared');
    });

    await suite.check('G5', 'Report Usage charges the budget and is audited', async () => {
        const before = (await latestBudget(flowA))?.API_Calls_Consumed__c ?? 0;
        const output = outputOf(
            await admin.action('AgentGovReportUsage', [{ registrationId: flowA.id, apiCallsUsed: 3 }])
        );
        ensure(output.allowed === true, JSON.stringify(output));
        const after = (await latestBudget(flowA))?.API_Calls_Consumed__c;
        ensure(after - before === 3, `API calls consumed rose by ${after - before}, expected 3`);
        const [row] = await waitForAudit(flowA, "Action_Type__c = 'Report'");
        ensure(row, 'the usage report left no audit row');
    });

    await suite.check('G6', 'Report Usage rejects negative usage instead of ignoring it', async () => {
        const before = (await latestBudget(flowA))?.API_Calls_Consumed__c;
        const output = outputOf(
            await admin.action('AgentGovReportUsage', [{ registrationId: flowA.id, apiCallsUsed: -5 }])
        );
        const after = (await latestBudget(flowA))?.API_Calls_Consumed__c;
        ensure(after === before, `consumption changed from ${before} to ${after}`);
        ensure(Boolean(output.errorMessage), `negative usage was accepted silently: ${JSON.stringify(output)}`);
    });

    await suite.check('G7', 'A 200-request Flow batch is authorized and charged in one call', async () => {
        const before = (await latestBudget(flowB))?.SOQL_Queries_Consumed__c ?? 0;
        const inputs = Array.from({ length: 200 }, () => ({
            registrationId: flowB.id,
            actionType: 'Query',
            objectName: 'Account'
        }));
        const response = await admin.action('AgentGovRegisterAction', inputs);
        ensure(response.status === 200, describeResponse(response));
        const authorized = response.body.filter((entry) => entry.outputValues?.authorized === true).length;
        ensure(authorized === 200, `${authorized} of 200 requests authorized`);
        const after = (await latestBudget(flowB))?.SOQL_Queries_Consumed__c;
        ensure(after - before === 200, `SOQL consumed rose by ${after - before}, expected 200`);
    });

    await suite.check('G8', "The batch's 200 actions are counted on the agent's session", async () => {
        const open = (await sessionsOf(flowB)).filter((session) => session.Status__c === 'Active');
        ensure(open.length === 1, `${open.length} active sessions`);
        ensure(
            open[0].Actions_Count__c >= 200,
            `Actions_Count__c is ${open[0].Actions_Count__c}, expected at least 200`
        );
    });

    const apexAgent = await register('Apex Unit');
    await activate(apexAgent);
    await suite.check('G9', 'Work measured by AgentGovContext in Apex is charged and audited', async () => {
        await admin.apex(
            `AgentGovContext.startTracking('${apexAgent.id}');\n` +
                'List<Account> accounts = [SELECT Id FROM Account LIMIT 1];\n' +
                'AgentGovContext.stopTracking();'
        );
        const budget = await latestBudget(apexAgent);
        ensure(budget?.SOQL_Queries_Consumed__c >= 1, `SOQL consumed ${budget?.SOQL_Queries_Consumed__c}`);
        const [row] = await waitForAudit(apexAgent, '');
        ensure(row, 'the measured unit of work left no audit row');
    });

    const flowC = await register('Flow C', 'Flow_Based');
    await activate(flowC);
    await suite.check('G10', "Three failures logged from Flow trip the agent's circuit breaker", async () => {
        for (let attempt = 1; attempt <= 3; attempt++) {
            const response = await admin.action('AgentGovLogAction', [
                {
                    registrationId: flowC.id,
                    actionType: 'Update',
                    objectName: 'Account',
                    status: 'Failure',
                    details: `attempt ${attempt} failed`
                }
            ]);
            ensure(outputOf(response).success === true, describeResponse(response));
        }
        const state = await registrationOf(flowC);
        ensure(
            state.Circuit_Breaker_State__c === 'OPEN' && state.Status__c === 'Blocked',
            `breaker ${state.Circuit_Breaker_State__c}, status ${state.Status__c}`
        );
        const refused = outputOf(
            await admin.action('AgentGovRegisterAction', [
                { registrationId: flowC.id, actionType: 'Query', objectName: 'Account' }
            ])
        );
        ensure(refused.authorized === false, 'the tripped agent was still authorized');
    });

    // --- H. Sessions, first half -------------------------------------------------------------

    const sessionAgent = await register('Session');
    const reaperAgent = await register('Reaper');
    const raceAgent = await register('Race');
    await activate(sessionAgent, reaperAgent, raceAgent);

    await suite.check('H1', 'A governed call opens a session', async () => {
        const response = await authorize(sessionAgent, { objectName: 'Account', operation: 'Query' });
        ensure(response.status === 200, describeResponse(response));
        await authorize(reaperAgent, { objectName: 'Account', operation: 'Query' });
        const open = (await sessionsOf(sessionAgent)).filter((session) => session.Status__c === 'Active');
        ensure(open.length === 1, `${open.length} active sessions, expected 1`);
    });

    await suite.check('H2', 'Five simultaneous first calls open exactly one session', async () => {
        const responses = await Promise.all(
            Array.from({ length: 5 }, () => authorize(raceAgent, { objectName: 'Account', operation: 'Query' }))
        );
        ensure(
            responses.every((response) => response.status === 200),
            responses.map((r) => r.status).join(', ')
        );
        const open = (await sessionsOf(raceAgent)).filter((session) => session.Status__c === 'Active');
        ensure(open.length === 1, `${open.length} active sessions after 5 concurrent calls, expected 1`);
    });

    // Calls that wait on the same budget row must neither lose nor double-count work: each one's
    // charge and action is recorded exactly once.
    await suite.check('H5', 'Ten simultaneous calls are each charged and counted exactly once', async () => {
        const totals = async () => {
            const budget = await latestBudget(raceAgent);
            const sessions = await sessionsOf(raceAgent);
            return {
                queries: budget?.SOQL_Queries_Consumed__c ?? 0,
                actions: sessions.reduce((sum, session) => sum + (session.Actions_Count__c ?? 0), 0)
            };
        };
        const before = await totals();
        const responses = await Promise.all(
            Array.from({ length: 10 }, () => authorize(raceAgent, { objectName: 'Account', operation: 'Query' }))
        );
        ensure(
            responses.every((response) => response.status === 200),
            responses.map((r) => r.status).join(', ')
        );
        const after = await totals();
        ensure(
            after.queries - before.queries === 10,
            `the budget was charged ${after.queries - before.queries} queries for 10 calls`
        );
        ensure(
            after.actions - before.actions === 10,
            `the sessions counted ${after.actions - before.actions} actions for 10 calls`
        );
    });

    // --- I. Scheduling -----------------------------------------------------------------------

    async function scheduledJobs() {
        return admin.query(
            `SELECT CronJobDetail.Name, CronExpression FROM CronTrigger WHERE CronJobDetail.Name IN (${JOB_NAMES.map(quote).join(', ')})`
        );
    }

    await suite.check('I1', 'One call schedules the three background jobs', async () => {
        await admin.apex('AgentGovJobScheduler.scheduleAll();');
        const jobs = await scheduledJobs();
        ensure(
            jobs.length === 3,
            `${jobs.length} jobs scheduled: ${jobs.map((job) => job.CronJobDetail.Name).join(', ')}`
        );
    });

    await suite.check('I2', 'Scheduling again does not create duplicates', async () => {
        await admin.apex('AgentGovJobScheduler.scheduleAll();');
        const jobs = await scheduledJobs();
        ensure(jobs.length === 3, `${jobs.length} jobs after a second run`);
    });

    // Scheduled jobs block the deploy of every class they use, so the suite also proves the
    // documented way to remove them before an upgrade, and leaves the org deployable.
    await suite.check('I3', 'The unschedule script removes the jobs so a new version can be deployed', async () => {
        const result = sf([
            'apex',
            'run',
            '--file',
            'scripts/setup/unschedule-jobs.apex',
            '--target-org',
            admin.targetOrg
        ]);
        ensure(result.result?.success === true, `the script failed: ${result.result?.exceptionMessage}`);
        const jobs = await scheduledJobs();
        ensure(jobs.length === 0, `${jobs.length} jobs remain scheduled`);
    });

    // --- J. Retention, first half: seed old and recent rows, start the purge ----------------

    const retentionAgent = await register('Retention');
    const marker = `E2E_Retention_${runId}`;
    let purgeStarted;
    await suite.check('J0', 'Old and recent rows can be seeded and the cleanup job started', async () => {
        await admin.apex(`
            Id agentId = '${retentionAgent.id}';
            DateTime longAgo = DateTime.now().addDays(-200);
            insert new List<AgentGov_Action_Log__c>{
                new AgentGov_Action_Log__c(Agent_Registration__c = agentId, Action_Type__c = 'System', Status__c = 'Success', Object_Name__c = '${marker}_old', Timestamp__c = longAgo),
                new AgentGov_Action_Log__c(Agent_Registration__c = agentId, Action_Type__c = 'System', Status__c = 'Success', Object_Name__c = '${marker}_new', Timestamp__c = DateTime.now())
            };
            insert new List<AgentGov_Conflict_Log__c>{
                new AgentGov_Conflict_Log__c(Agent_1__c = agentId, Agent_2__c = agentId, Object_Name__c = '${marker}_old', Record_Id__c = 'old', Conflict_Type__c = 'Concurrent_Write', Resolution__c = 'Agent1_Won', Severity__c = 'Medium', Timestamp__c = longAgo),
                new AgentGov_Conflict_Log__c(Agent_1__c = agentId, Agent_2__c = agentId, Object_Name__c = '${marker}_new', Record_Id__c = 'new', Conflict_Type__c = 'Concurrent_Write', Resolution__c = 'Agent1_Won', Severity__c = 'Medium', Timestamp__c = DateTime.now())
            };
            insert new AgentGov_Session__c(Agent_Registration__c = agentId, Status__c = 'Completed', Session_Start__c = longAgo, Session_End__c = longAgo.addHours(1));
            insert new AgentGov_Budget__c(Agent_Registration__c = agentId, Budget_Date__c = Date.today().addDays(-500), Budget_Status__c = 'Normal', API_Calls_Allocated__c = 1, SOQL_Queries_Allocated__c = 1, DML_Operations_Allocated__c = 1, API_Calls_Consumed__c = 0, SOQL_Queries_Consumed__c = 0, DML_Operations_Consumed__c = 0);
            insert new AgentGov_Budget__c(Agent_Registration__c = agentId, Budget_Date__c = Date.today(), Budget_Status__c = 'Normal', API_Calls_Allocated__c = 1, SOQL_Queries_Allocated__c = 1, DML_Operations_Allocated__c = 1, API_Calls_Consumed__c = 0, SOQL_Queries_Consumed__c = 0, DML_Operations_Consumed__c = 0);
        `);
        // Two minutes of slack so a local clock ahead of the server cannot hide the job.
        purgeStarted = new Date(Date.now() - 120000).toISOString();
        await admin.apex('Database.executeBatch(new AgentGovCleanup());');
    });

    // --- K. Security: a restricted agent user ------------------------------------------------

    const bound = await register('Bound');
    await activate(bound);
    await admin.apex(`AgentGovRegistryService.bindAgentUser('${bound.id}', '${agentUser.id}');`);
    const asAgentUser = (path, body) => agentUser.org.apexRest('POST', path, { body });

    await suite.check('K1', 'The agent user cannot read AgentGov records directly', async () => {
        let refused = false;
        try {
            await agentUser.org.query('SELECT Id FROM AgentGov_Registration__c LIMIT 1');
        } catch (error) {
            refused = /INVALID_TYPE|not supported/i.test(error.message);
        }
        ensure(refused, 'the agent user could query AgentGov_Registration__c');
    });

    await suite.check('K2', 'An agent bound to its Salesforce user authenticates without a key', async () => {
        const response = await asAgentUser('/agentgov/authorize', { objectName: 'Account', operation: 'Query' });
        ensure(response.status === 200 && response.body.authorized === true, describeResponse(response));
    });

    await suite.check('K3', "The budget day follows the org's time zone, not the caller's", async () => {
        const budget = await latestBudget(bound);
        const orgDay = localDate(orgTimeZone);
        ensure(budget, 'no budget row');
        ensure(
            budget.Budget_Date__c === orgDay,
            `budget dated ${budget.Budget_Date__c}; the org's today is ${orgDay}, the caller's (${agentUser.timeZone}) is ${localDate(agentUser.timeZone)}`
        );
    });

    await suite.check('K4', 'The proxy refuses to create records the agent user may not create', async () => {
        const name = `E2E Forbidden ${runId}`;
        const response = await asAgentUser('/agentgov-proxy/create', {
            objectName: 'Account',
            records: [{ Name: name }]
        });
        ensure(response.status >= 400 && response.status < 500, describeResponse(response));
        const rows = await admin.query(`SELECT Id FROM Account WHERE Name = ${quote(name)}`);
        ensure(rows.length === 0, 'the Account was created anyway');
        ensure(
            response.body.errorCode === 'ACCESS_DENIED',
            `refused with ${response.body.errorCode} rather than ACCESS_DENIED`
        );
        const message = String(response.body.message ?? '');
        ensure(/not permitted to create Account/.test(message), `unexpected wording: ${message}`);
        ensure(!/exception|sObject type|not supported/i.test(message), `platform text leaked: ${message}`);
    });

    await suite.check('K5', 'That refusal is audited', async () => {
        const [denied] = await waitForAudit(bound, "Status__c = 'Denied' AND Action_Type__c = 'Create'");
        ensure(denied, 'no Denied/Create audit row appeared for the agent user');
    });

    const twin = await register('Bound Twin');
    await activate(twin);
    await suite.check('K6', 'A user bound to two agents is refused rather than silently matched to one', async () => {
        await admin.apex(`AgentGovRegistryService.bindAgentUser('${twin.id}', '${agentUser.id}');`);
        try {
            const response = await asAgentUser('/agentgov/authorize', { objectName: 'Account', operation: 'Query' });
            ensure(response.status === 403, `a keyless call with two bindings returned ${describeResponse(response)}`);
        } finally {
            await admin.apex(`AgentGovRegistryService.bindAgentUser('${twin.id}', null);`);
        }
    });

    // --- L. The emergency bypass ----------------------------------------------------------------

    const setGovernance = (enabled) =>
        admin.apex(
            `AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();\n` +
                `settings.Is_Enabled__c = ${enabled};\nupsert settings;`
        );
    const bypassed = await register('Bypassed');
    const benched = await register('Benched');
    await activate(bypassed, benched);
    for (let attempt = 0; attempt < 3; attempt++) {
        await reportOutcome(bypassed, false);
    }
    // Tripped for real, then held inside its cooldown so the checks below do not race the clock.
    await admin.apex(
        `update new AgentGov_Registration__c(Id = '${bypassed.id}', Cooldown_Until__c = DateTime.now().addHours(1));\n` +
            `AgentGovRegistryService.deactivateAgent('${benched.id}');`
    );
    await setGovernance(false);
    try {
        await suite.check(
            'L1',
            'During the emergency bypass an agent whose breaker tripped is authorized',
            async () => {
                const state = await registrationOf(bypassed);
                ensure(state.Status__c === 'Blocked', `the agent is ${state.Status__c}, not tripped`);
                const response = await authorize(bypassed, { objectName: 'Account', operation: 'Query' });
                ensure(
                    response.status === 200 &&
                        response.body.authorized === true &&
                        response.body.governanceEnabled === false,
                    describeResponse(response)
                );
            }
        );

        await suite.check('L2', 'The proxy lets it write, charges nothing, and audits the write', async () => {
            const name = `E2E Bypass Account ${runId}`;
            const response = await proxy(bypassed, '/create', { objectName: 'Account', records: [{ Name: name }] });
            ensure(response.status === 200, describeResponse(response));
            const created = await admin.query(`SELECT Id FROM Account WHERE Name = ${quote(name)}`);
            ensure(created.length === 1, `${created.length} accounts created`);
            const budget = await latestBudget(bypassed);
            ensure(
                (budget?.DML_Operations_Consumed__c ?? 0) === 0,
                `charged ${budget?.DML_Operations_Consumed__c} DML`
            );
            const [audited] = await waitForAudit(bypassed, "Action_Type__c = 'Create' AND Status__c = 'Success'");
            ensure(audited, 'the write made during the bypass has no audit row');
        });

        await suite.check('L3', 'A deactivated agent is still refused, over REST and in Flow', async () => {
            const rest = await authorize(benched, { objectName: 'Account', operation: 'Query' });
            ensure(rest.status === 403 && rest.body.errorCode === 'AGENT_NOT_ACTIVE', describeResponse(rest));
            const flow = outputOf(
                await admin.action('AgentGovRegisterAction', [
                    { registrationId: benched.id, actionType: 'Query', objectName: 'Account' }
                ])
            );
            ensure(flow.authorized === false, `Register Agent Action authorized it: ${JSON.stringify(flow)}`);
        });

        await suite.check('L4', 'The bypass leaves the tripped breaker as it was', async () => {
            const state = await registrationOf(bypassed);
            ensure(
                state.Circuit_Breaker_State__c === 'OPEN' && state.Status__c === 'Blocked',
                `breaker ${state.Circuit_Breaker_State__c}, status ${state.Status__c}`
            );
        });
    } finally {
        await setGovernance(true);
    }

    await suite.check('L5', 'With governance back on, the tripped agent is refused again', async () => {
        const response = await authorize(bypassed, { objectName: 'Account', operation: 'Query' });
        ensure(response.status === 403 && response.body.errorCode === 'AGENT_NOT_ACTIVE', describeResponse(response));
    });

    // --- Wait out the one-minute cooldown and idle window ------------------------------------

    console.log(`  waiting ${COOL_DOWN_WAIT_MS / 1000}s for the breaker cooldown and the session idle window`);
    await sleep(COOL_DOWN_WAIT_MS);

    // --- B. Last activity, after the wait ----------------------------------------------------

    await suite.check('B10', "An agent's last-active time follows its activity", async () => {
        const response = await authorize(writer, { objectName: 'Account', operation: 'Query' });
        ensure(response.status === 200, describeResponse(response));
        const serverNow = new Date(response.headers.date).getTime();
        const lastActive = new Date((await registrationOf(writer)).Last_Active__c).getTime();
        ensure(
            serverNow - lastActive < 15000,
            `Last_Active__c is ${Math.round((serverNow - lastActive) / 1000)}s older than the call`
        );
    });

    // --- H. Sessions, second half ------------------------------------------------------------

    await suite.check(
        'H3',
        'After the idle window the next call starts a new session and closes the old one',
        async () => {
            const response = await authorize(sessionAgent, { objectName: 'Account', operation: 'Query' });
            ensure(response.status === 200, describeResponse(response));
            const all = await sessionsOf(sessionAgent);
            const open = all.filter((session) => session.Status__c === 'Active');
            const closed = all.filter((session) => session.Status__c === 'Completed');
            ensure(
                open.length === 1 && closed.length === 1,
                `${open.length} active and ${closed.length} completed sessions`
            );
            const endedAt = new Date(closed[0].Session_End__c).getTime();
            const callAt = new Date(response.headers.date).getTime();
            ensure(
                callAt - endedAt > 45000,
                'the old session was closed at the time of the new call, not at its last activity'
            );
        }
    );

    // --- D. Circuit breaker, second half -----------------------------------------------------

    await suite.check('D4', 'After the cooldown one probe request is admitted', async () => {
        const response = await authorize(breakerA, { objectName: 'Account', operation: 'Query' });
        ensure(response.status === 200 && response.body.authorized === true, describeResponse(response));
    });

    await suite.check('D5', 'A successful probe closes the breaker and reactivates the agent', async () => {
        await reportOutcome(breakerA, true);
        const state = await health(breakerA);
        ensure(
            state.body.circuitBreakerState === 'CLOSED' && state.body.status === 'Active',
            `breaker ${state.body.circuitBreakerState}, status ${state.body.status}`
        );
    });

    await admin.apex('new AgentGovHealthCheck().execute(null);');

    await suite.check('D6', 'The health check moves a cooled-down breaker to half-open', async () => {
        const row = await registrationOf(breakerB);
        ensure(row.Circuit_Breaker_State__c === 'HALF_OPEN', `breaker is ${row.Circuit_Breaker_State__c}`);
    });

    await suite.check('H4', 'The health check closes a session that has gone idle', async () => {
        const all = await sessionsOf(reaperAgent);
        ensure(all.length === 1, `${all.length} sessions for the idle agent`);
        ensure(all[0].Status__c === 'Completed', `its session is ${all[0].Status__c}`);
    });

    // --- J. Retention, second half ------------------------------------------------------------

    const purgeFinished = await waitFor(
        async () => {
            const pending = await admin.query(
                // Only batch runs: the weekly scheduled Cleanup job stays Queued until Sunday.
                `SELECT Id FROM AsyncApexJob WHERE ApexClass.Name = 'AgentGovCleanup' AND JobType = 'BatchApex' ` +
                    `AND CreatedDate >= ${purgeStarted?.replace(/\.\d+Z$/, 'Z') ?? '2000-01-01T00:00:00Z'} ` +
                    `AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')`
            );
            return pending.length === 0;
        },
        { timeoutMs: 120000, intervalMs: 5000 }
    );

    async function remaining(sobject, where) {
        return (await admin.query(`SELECT Id FROM ${sobject} WHERE ${where}`)).length;
    }

    await suite.check('J1', 'Old audit rows are purged and recent ones kept', async () => {
        ensure(purgeFinished, 'the cleanup job did not finish within two minutes');
        const old = await remaining('AgentGov_Action_Log__c', `Object_Name__c = '${marker}_old'`);
        const recent = await remaining('AgentGov_Action_Log__c', `Object_Name__c = '${marker}_new'`);
        ensure(old === 0 && recent === 1, `old rows left: ${old}, recent rows left: ${recent}`);
    });

    await suite.check('J2', 'Old finished sessions are purged', async () => {
        const old = await remaining('AgentGov_Session__c', `Agent_Registration__c = '${retentionAgent.id}'`);
        ensure(old === 0, `${old} old session(s) left`);
    });

    await suite.check('J3', 'Old conflict logs are purged and recent ones kept', async () => {
        const old = await remaining('AgentGov_Conflict_Log__c', `Object_Name__c = '${marker}_old'`);
        const recent = await remaining('AgentGov_Conflict_Log__c', `Object_Name__c = '${marker}_new'`);
        ensure(old === 0 && recent === 1, `old rows left: ${old}, recent rows left: ${recent}`);
    });

    await suite.check('J4', 'Budget rows past their retention are purged and current ones kept', async () => {
        const old = await remaining(
            'AgentGov_Budget__c',
            `Agent_Registration__c = '${retentionAgent.id}' AND Budget_Date__c < LAST_N_DAYS:400`
        );
        // The row was seeded as today; yesterday is accepted too, for a run that crosses midnight.
        const current = await remaining(
            'AgentGov_Budget__c',
            `Agent_Registration__c = '${retentionAgent.id}' AND Budget_Date__c = LAST_N_DAYS:1`
        );
        ensure(old === 0 && current === 1, `old rows left: ${old}, current rows left: ${current}`);
    });

    return suite.results;
}
