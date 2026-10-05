/**
 * Drives realistic traffic through a deployed AgentGov so its console shows activity the
 * framework produced itself, rather than rows inserted directly. The UI suite checks the console
 * against this traffic, and drives it itself when a run leaves this suite out.
 *
 * The demo agents keep fixed names so repeated runs update the same agents. Each run issues them
 * fresh keys and starts them from a clean state for the day.
 */
import { randomBytes } from 'node:crypto';
import { ensure, Suite } from './lib/checks.mjs';
import { quote } from './lib/sf.mjs';

// The names differ from the sample data's (AgentGovSampleData), so a run in an org that loaded
// it never reuses a sample agent, which would replace its documented key, reset its state and
// priority, and delete its recent budget rows.
export const DEMO_AGENTS = [
    { name: 'Contact Enrichment Agent', type: 'MCP_External', priority: 2 },
    { name: 'Case Triage Agent', type: 'Custom_Apex', priority: 3, dailyApiBudget: 100 },
    { name: 'Order Sync Agent', type: 'MCP_External', priority: 4 },
    { name: 'Renewal Forecast Flow', type: 'Flow_Based', priority: 5 }
];

/**
 * Returns the demo agents with usable keys, registering any that do not exist yet.
 * @returns {Promise<Record<string, { id: string, key: string }>>}
 */
export async function ensureDemoAgents(admin) {
    const names = DEMO_AGENTS.map((agent) => quote(agent.name)).join(', ');
    const existing = await admin.query(
        `SELECT Id, Agent_Name__c FROM AgentGov_Registration__c WHERE Agent_Name__c IN (${names})`
    );
    const byName = new Map(existing.map((row) => [row.Agent_Name__c, row.Id]));
    const agents = {};
    for (const demo of DEMO_AGENTS) {
        const key = `agk_${randomBytes(32).toString('hex')}`;
        let id = byName.get(demo.name);
        if (!id) {
            const response = await admin.apexRest('POST', '/agentgov/register', {
                body: {
                    agentName: demo.name,
                    agentType: demo.type,
                    description: 'Demonstration agent driven by e2e/traffic.mjs',
                    ownerEmail: 'owner@example.com',
                    apiKey: key
                }
            });
            if (response.status !== 201) {
                throw new Error(`Could not register ${demo.name}: ${response.status} ${JSON.stringify(response.body)}`);
            }
            id = response.body.registrationId;
        } else {
            // Only the hash of a key is stored, so an existing demo agent gets a new key for this run.
            await admin.apex(
                `AgentGov_Registration__c registration = new AgentGov_Registration__c(Id = '${id}');\n` +
                    `AgentGovRestAuth.applyKey(registration, '${key}');\nupdate registration;`
            );
        }
        agents[demo.name] = { id, key };
    }

    // Start each run from a clean day: active, breaker closed, today's budget reset.
    const ids = Object.values(agents).map((agent) => quote(agent.id));
    await admin.apex(`
        List<AgentGov_Registration__c> demo = [SELECT Id, Agent_Name__c FROM AgentGov_Registration__c WHERE Id IN (${ids.join(', ')})];
        for (AgentGov_Registration__c registration : demo) {
            registration.Status__c = 'Active';
            registration.Circuit_Breaker_State__c = 'CLOSED';
            registration.Failure_Count__c = 0;
            registration.Cooldown_Until__c = null;
            registration.Agent_User__c = null;
        }
        update demo;
        delete [SELECT Id FROM AgentGov_Budget__c WHERE Agent_Registration__c IN (${ids.join(', ')}) AND Budget_Date__c >= YESTERDAY];
    `);
    for (const demo of DEMO_AGENTS) {
        const fields = [`Priority__c = ${demo.priority}`];
        if (demo.dailyApiBudget) {
            fields.push(`Daily_API_Budget__c = ${demo.dailyApiBudget}`);
        }
        await admin.apex(`update new AgentGov_Registration__c(Id = '${agents[demo.name].id}', ${fields.join(', ')});`);
    }
    return agents;
}

/**
 * Trips an agent's circuit breaker by reporting failed outcomes, as a failing downstream would.
 */
export async function tripBreaker(admin, agent, failures = 3) {
    for (let attempt = 0; attempt < failures; attempt++) {
        await admin.apexRest('POST', '/agentgov/report', {
            headers: { 'X-AgentGov-Key': agent.key },
            body: { actual: { apiCalls: 0 }, success: false }
        });
    }
}

export async function runTrafficSuite(context) {
    const { admin, runId } = context;
    const suite = new Suite('traffic');
    const agents = await ensureDemoAgents(admin);
    // Shared with the UI suite, which needs the keys issued for this run.
    context.demoAgents = agents;
    const as = (name) => ({
        'X-AgentGov-Key': agents[name].key,
        'X-Correlation-Id': `demo-${runId}-${name.split(' ')[0]}`
    });
    const post = (name, path, body) => admin.apexRest('POST', path, { headers: as(name), body });

    await suite.check('T1', 'Demo traffic flows through the proxy, /authorize and Register Agent Action', async () => {
        const statuses = [];
        const lead = 'Contact Enrichment Agent';
        statuses.push(
            (await post(lead, '/agentgov-proxy/query', { objectName: 'Account', fields: ['Id', 'Name'], limit: 5 }))
                .status
        );
        statuses.push(
            (
                await post(lead, '/agentgov-proxy/create', {
                    objectName: 'Account',
                    records: [{ Name: `Demo Prospect ${runId} A` }, { Name: `Demo Prospect ${runId} B` }]
                })
            ).status
        );
        // Forbidden by the shipped MCP policy, so the console has a denial to show.
        const created = await admin.query(`SELECT Id FROM Account WHERE Name = 'Demo Prospect ${runId} A' LIMIT 1`);
        statuses.push(
            (await post(lead, '/agentgov-proxy/delete', { objectName: 'Account', ids: [created[0]?.Id] })).status
        );

        const triage = 'Case Triage Agent';
        statuses.push(
            (await post(triage, '/agentgov/authorize', { objectName: 'Case', operation: 'API_Call', amount: 85 }))
                .status
        );

        const flow = agents['Renewal Forecast Flow'];
        const batch = await admin.action(
            'AgentGovRegisterAction',
            Array.from({ length: 25 }, () => ({
                registrationId: flow.id,
                actionType: 'Query',
                objectName: 'Opportunity'
            }))
        );
        statuses.push(batch.status);

        const expected = [200, 200, 403, 200, 200];
        ensure(
            statuses.every((status, index) => status === expected[index]),
            `statuses ${statuses.join(', ')}; expected ${expected.join(', ')}`
        );
    });

    await suite.check('T2', 'A failing agent trips its circuit breaker', async () => {
        await tripBreaker(admin, agents['Order Sync Agent']);
        const [row] = await admin.query(
            `SELECT Circuit_Breaker_State__c FROM AgentGov_Registration__c WHERE Id = '${agents['Order Sync Agent'].id}'`
        );
        ensure(row.Circuit_Breaker_State__c === 'OPEN', `breaker is ${row.Circuit_Breaker_State__c}`);
    });

    return suite.results;
}
