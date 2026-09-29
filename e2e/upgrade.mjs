#!/usr/bin/env node
/**
 * Upgrade test. Installs an earlier AgentGov release in a temporary scratch org, seeds the data
 * an org on that release can hold, follows the documented upgrade steps to the working tree, and
 * checks the result. It is the only honest test of the upgrade steps and migration scripts, which
 * run once, against production data, around the deploy.
 *
 *   --from v1.1  Duplicate daily budgets and plaintext API keys, through the dedupe and
 *                key-hashing migrations. The default.
 *   --from v1.2  Keys v1.2 issued, a day of v1.2 traffic, the duplicate sessions v1.2 allowed,
 *                and the jobs its guide scheduled plus a copy under an administrator's own name.
 *
 * Usage:
 *   npm run e2e:upgrade                       from v1.1, temporary org, deleted afterwards
 *   npm run e2e:upgrade -- --from v1.2        from v1.2
 *   npm run e2e:upgrade -- --keep             keep the org for inspection
 *   npm run e2e:upgrade -- --dev-hub <alias>  Dev Hub for the temporary org
 *   npm run e2e:upgrade -- --skip-api-suite   stop after the upgrade checks
 */
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { runApiSuite } from './api.mjs';
import { ensure, printTable, redact, saveResults, Suite } from './lib/checks.mjs';
import { Org, quote, REPO_ROOT, sf, sfJsonText, sleep } from './lib/sf.mjs';
import { localDate, prepareOrg } from './setup.mjs';

// Releases the test can start from. v1.1 was not tagged, so it is named by its last commit.
const RELEASES = { 'v1.1': '2e38077', 'v1.2': 'v1.2.0' };

const { values: options } = parseArgs({
    options: {
        from: { type: 'string', default: 'v1.1' },
        keep: { type: 'boolean', default: false },
        'dev-hub': { type: 'string' },
        'skip-api-suite': { type: 'boolean', default: false }
    }
});
if (!RELEASES[options.from]) {
    console.error(`--from must be one of: ${Object.keys(RELEASES).join(', ')}`);
    process.exit(2);
}

const runId = Date.now().toString(36);
const targetOrg = `agentgov-upgrade-${runId}`;
const step = (message) => console.log(`\n> ${message}`);

function runApexFile(path) {
    const result = sf(['apex', 'run', '--file', path, '--target-org', targetOrg]);
    if (!result.result?.success) {
        throw new Error(`${path} failed: ${result.result?.exceptionMessage ?? result.result?.compileProblem}`);
    }
    return result.result.logs ?? '';
}

/**
 * Extracts a released version into a temporary SFDX project, without touching the repo. The
 * release's own sfdx-project.json is kept, so it deploys at the API version it was built for.
 */
function extractRelease(ref) {
    const dir = mkdtempSync(join(tmpdir(), 'agentgov-release-'));
    const archive = execFileSync(
        'git',
        ['-C', REPO_ROOT, 'archive', '--format=tar', ref, 'force-app', 'sfdx-project.json'],
        { maxBuffer: 256 * 1024 * 1024 }
    );
    execFileSync('tar', ['-x', '-C', dir], { input: archive });
    // Jest specs sit inside the component folders and are never deployable, so the extracted
    // project ignores them as this repository's own .forceignore does.
    writeFileSync(join(dir, '.forceignore'), '**/__tests__/**\n**/lwc/jsconfig.json\n');
    return dir;
}

function deployFrom(dir) {
    const out = sfJsonText(
        [
            'project',
            'deploy',
            'start',
            '--source-dir',
            'force-app',
            '--target-org',
            targetOrg,
            '--wait',
            '30',
            // Scratch orgs track source per project. The old release is deployed from a separate
            // folder, so the CLI sees every component as a conflict with this project; installers'
            // orgs have no source tracking, so ignoring it matches a real upgrade.
            '--ignore-conflicts'
        ],
        dir
    );
    const envelope = JSON.parse(out || '{}');
    const result = Array.isArray(envelope.result) ? undefined : envelope.result;
    if (result?.status !== 'Succeeded') {
        const failures = (result?.files ?? [])
            .filter((file) => file.error)
            .map((file) => `${file.fullName}: ${file.error}`);
        throw new Error(`Deploy failed: ${envelope.message ?? ''}\n${failures.slice(0, 15).join('\n')}`);
    }
    return result.numberComponentsDeployed;
}

const suite = new Suite('upgrade');
const admin = new Org(targetOrg);

// Each upgrade step depends on the one before it, so the rehearsal stops at the first failure
// instead of reporting failures that only follow from it.
async function upgradeStep(id, title, body) {
    await suite.check(id, title, body);
    if (!suite.results.at(-1).ok) {
        throw new Error(`${id} failed, so the steps after it were not run`);
    }
}

// --- From v1.1 ----------------------------------------------------------------------------------

const keys = {
    alpha: `legacy-key-alpha-${runId}-0001`,
    beta: `legacy-key-beta-${runId}-00001`,
    short: 'short-key'
};

// Data only a v1.1 org can hold: duplicate budget rows, which v1.2 made impossible, and API
// keys stored in plaintext. The duplicates for Alpha add up to the block threshold.
const SEED_V1_1 = `
List<AgentGov_Registration__c> agents = new List<AgentGov_Registration__c>();
for (List<String> spec : new List<List<String>>{
    new List<String>{ 'Upgrade Alpha', 'MCP_External', '${keys.alpha}' },
    new List<String>{ 'Upgrade Beta', 'Flow_Based', '${keys.beta}' },
    new List<String>{ 'Upgrade Short', 'Custom_Apex', '${keys.short}' }
}) {
    agents.add(new AgentGov_Registration__c(Agent_Name__c = spec[0], Agent_Type__c = spec[1], API_Key__c = spec[2],
        Status__c = 'Active', Priority__c = 5, Circuit_Breaker_State__c = 'CLOSED', Failure_Count__c = 0,
        Daily_API_Budget__c = 100, Daily_SOQL_Budget__c = 100, Daily_DML_Budget__c = 100));
}
insert agents;
Date today = Date.today();
List<AgentGov_Budget__c> rows = new List<AgentGov_Budget__c>();
List<List<Object>> specs = new List<List<Object>>{
    new List<Object>{ agents[0].Id, today, 30, 0 },
    new List<Object>{ agents[0].Id, today, 40, 0 },
    new List<Object>{ agents[0].Id, today, 25, 0 },
    new List<Object>{ agents[1].Id, today.addDays(-1), 0, 10 },
    new List<Object>{ agents[1].Id, today.addDays(-1), 0, 5 },
    new List<Object>{ agents[2].Id, today, 1, 0 }
};
for (List<Object> spec : specs) {
    rows.add(new AgentGov_Budget__c(Agent_Registration__c = (Id) spec[0], Budget_Date__c = (Date) spec[1],
        API_Calls_Allocated__c = 100, API_Calls_Consumed__c = (Integer) spec[2],
        SOQL_Queries_Allocated__c = 100, SOQL_Queries_Consumed__c = (Integer) spec[3],
        DML_Operations_Allocated__c = 100, DML_Operations_Consumed__c = 0, Budget_Status__c = 'Normal'));
}
insert rows;
`;

async function budgetRows() {
    return admin.query(
        "SELECT Agent_Registration__r.Agent_Name__c, Budget_Date__c, API_Calls_Consumed__c, SOQL_Queries_Consumed__c, Budget_Status__c FROM AgentGov_Budget__c WHERE Agent_Registration__r.Agent_Name__c LIKE 'Upgrade %' ORDER BY Agent_Registration__r.Agent_Name__c, Budget_Date__c"
    );
}

async function upgradeFromV11() {
    await upgradeStep('V1', 'AgentGov v1.1 installs in a current scratch org', async () => {
        const deployed = deployFrom(extractRelease(RELEASES['v1.1']));
        ensure(deployed > 0, 'nothing was deployed');
        sf(['org', 'assign', 'permset', '--name', 'AgentGov_Admin', '--target-org', targetOrg]);
    });

    await upgradeStep('V2', 'A v1.1 org holding duplicate budgets and plaintext keys is seeded', async () => {
        await admin.apex(SEED_V1_1);
        ensure((await budgetRows()).length === 6, 'the seed did not create six budget rows');
    });

    await upgradeStep(
        'V3',
        'The dedupe script leaves one budget row per agent and day, with usage summed',
        async () => {
            runApexFile('scripts/migrate/dedupe-budgets.apex');
            const rows = await budgetRows();
            ensure(rows.length === 3, `${rows.length} rows remain, expected 3`);
            const alpha = rows.find((row) => row.Agent_Registration__r?.Agent_Name__c === 'Upgrade Alpha') ?? rows[0];
            ensure(
                alpha.API_Calls_Consumed__c === 95,
                `Alpha's merged API usage is ${alpha.API_Calls_Consumed__c}, expected 95`
            );
            ensure(
                alpha.Budget_Status__c === 'Blocked',
                `Alpha's merged status is ${alpha.Budget_Status__c}, expected Blocked`
            );
            const beta = rows.find((row) => row.SOQL_Queries_Consumed__c === 15);
            ensure(beta, "Beta's two rows were not merged into one with 15 queries");
        }
    );

    await upgradeStep('V4', 'Running the dedupe script again changes nothing', async () => {
        const logs = runApexFile('scripts/migrate/dedupe-budgets.apex');
        ensure(/no duplicate budget rows found/i.test(logs), 'the second run did not report a clean ledger');
        ensure((await budgetRows()).length === 3, 'the row count changed');
    });

    await upgradeStep('V5', 'This version deploys over the migrated v1.1 org', async () => {
        runApexFile('scripts/setup/unschedule-jobs.apex');
        const deployed = deployFrom(REPO_ROOT);
        ensure(deployed > 0, 'nothing was deployed');
    });

    await upgradeStep('V6', 'The key migration replaces every plaintext key with its hash', async () => {
        runApexFile('scripts/migrate/hash-api-keys.apex');
        const rows = await admin.query(
            "SELECT Agent_Name__c, API_Key__c, API_Key_Hash__c, API_Key_Prefix__c FROM AgentGov_Registration__c WHERE Agent_Name__c LIKE 'Upgrade %'"
        );
        ensure(
            rows.every((row) => row.API_Key__c == null && row.API_Key_Hash__c),
            'a plaintext key remains'
        );
        const short = rows.find((row) => row.Agent_Name__c === 'Upgrade Short');
        ensure(short.API_Key_Prefix__c == null, 'a key too short to truncate safely was given a prefix');
    });

    await upgradeStep('V7', 'Every migrated budget row accepts the one-row-per-day key', async () => {
        await admin.apex(
            "update [SELECT Id FROM AgentGov_Budget__c WHERE Agent_Registration__r.Agent_Name__c LIKE 'Upgrade %'];"
        );
        const unkeyed = await admin.query('SELECT Id FROM AgentGov_Budget__c WHERE Budget_Key__c = null');
        ensure(unkeyed.length === 0, `${unkeyed.length} budget rows have no key`);
    });

    await upgradeStep('V8', 'A key issued under v1.1 still authenticates after the upgrade', async () => {
        const [alpha] = await admin.query(
            "SELECT Id FROM AgentGov_Registration__c WHERE Agent_Name__c = 'Upgrade Alpha'"
        );
        const response = await admin.apexRest('GET', `/agentgov/budget/${alpha.Id}`, {
            headers: { 'X-AgentGov-Key': keys.alpha }
        });
        ensure(
            response.status === 200 && response.body.budgetStatus === 'Blocked',
            `${response.status} ${JSON.stringify(response.body)}`
        );
    });
}

// --- From v1.2 ----------------------------------------------------------------------------------

const JOB_NAMES = ['AgentGov Daily Reset', 'AgentGov Health Check', 'AgentGov Cleanup'];

// A second health check at half past the hour: Apex cron cannot express "every 30 minutes" in
// one job, so administrators add a copy under a name of their own. It blocks the deploy just as
// the documented jobs do.
const ADMIN_JOB = 'Half-hourly governance check';

// The jobs exactly as the v1.2 guide scheduled them, plus the administrator's copy.
const SCHEDULE_V1_2 = `
System.schedule('AgentGov Daily Reset', '0 0 0 * * ?', new AgentGovDailyReset());
System.schedule('AgentGov Health Check', '0 0 * * * ?', new AgentGovHealthCheck());
System.schedule('AgentGov Cleanup', '0 0 2 ? * SUN', new AgentGovCleanup());
System.schedule('${ADMIN_JOB}', '0 30 * * * ?', new AgentGovHealthCheck());
`;

const used = (row) =>
    (row.API_Calls_Consumed__c ?? 0) + (row.SOQL_Queries_Consumed__c ?? 0) + (row.DML_Operations_Consumed__c ?? 0);

// Salesforce writes offsets as +0000; the colon form parses the same in every JavaScript engine.
const instant = (value) => (value ? Date.parse(value.replace(/([+-]\d{2})(\d{2})$/, '$1:$2')) : NaN);
const sameInstant = (a, b) => a != null && b != null && instant(a) === instant(b);

async function registerUnderV12(name, agentType) {
    const response = await admin.apexRest('POST', '/agentgov/register', {
        body: {
            agentName: name,
            agentType,
            description: 'Registered under v1.2 by the upgrade test',
            ownerEmail: 'owner@example.com'
        }
    });
    ensure(
        response.status === 201 && response.body?.apiKey,
        `registering ${name}: ${response.status} ${JSON.stringify(response.body)}`
    );
    return { name, id: response.body.registrationId, key: response.body.apiKey };
}

async function authorizeQuery(agent) {
    const response = await admin.apexRest('POST', '/agentgov/authorize', {
        headers: { 'X-AgentGov-Key': agent.key },
        body: { objectName: 'Account', operation: 'Query' }
    });
    ensure(
        response.status === 200 && response.body?.authorized === true,
        `${agent.name} was refused: ${response.status} ${JSON.stringify(response.body)}`
    );
}

async function setIdleMinutes(minutes) {
    await admin.apex(`
        AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
        if (settings.Id == null) {
            settings.SetupOwnerId = UserInfo.getOrganizationId();
        }
        settings.Session_Idle_Minutes__c = ${minutes};
        upsert settings;
    `);
}

function budgetRowsOf(agent) {
    return admin.query(
        `SELECT Id, Budget_Date__c, API_Calls_Consumed__c, SOQL_Queries_Consumed__c, DML_Operations_Consumed__c FROM AgentGov_Budget__c WHERE Agent_Registration__c = ${quote(agent.id)}`
    );
}

function sessionsOf(...agents) {
    return admin.query(
        `SELECT Id, Agent_Registration__c, Status__c, End_Reason__c, Session_Start__c, Session_End__c, Last_Activity__c, Active_Session_Key__c, Actions_Count__c FROM AgentGov_Session__c WHERE Agent_Registration__c IN (${agents.map((agent) => quote(agent.id)).join(', ')})`
    );
}

async function scheduledJobs(names) {
    return admin.query(
        `SELECT CronJobDetail.Name FROM CronTrigger WHERE CronJobDetail.Name IN (${names.map(quote).join(', ')})`
    );
}

async function upgradeFromV12() {
    // The sessions v1.2 left open, by role, and the budget row v1.2 started today.
    const legacy = {};
    let gamma;
    let delta;
    let today;
    let startedRow;

    await upgradeStep('W1', 'AgentGov v1.2.0 installs in a current scratch org', async () => {
        const deployed = deployFrom(extractRelease(RELEASES['v1.2']));
        ensure(deployed > 0, 'nothing was deployed');
        sf(['org', 'assign', 'permset', '--name', 'AgentGov_Admin', '--target-org', targetOrg]);
    });

    await upgradeStep(
        'W2',
        "A v1.2 org is seeded through v1.2 itself: issued keys, a day's traffic, the duplicate sessions it allowed, and its guide's jobs",
        async () => {
            await admin.apex(`
                AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
                if (settings.Id == null) {
                    settings.SetupOwnerId = UserInfo.getOrganizationId();
                }
                settings.Is_Enabled__c = true;
                upsert settings;
            `);
            // v1.2 dated budgets in the running user's time zone and v1.3 uses the org's, so the
            // two are aligned here to make "the row v1.2 started today" one date in both.
            await admin.apex(`
                User me = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
                me.TimeZoneSidKey = [SELECT TimeZoneSidKey FROM Organization].TimeZoneSidKey;
                update me;
            `);
            gamma = await registerUnderV12('Upgrade Gamma', 'MCP_External');
            delta = await registerUnderV12('Upgrade Delta', 'Custom_Apex');
            await admin.apex(
                `AgentGovRegistryService.activateAgent('${gamma.id}');\nAgentGovRegistryService.activateAgent('${delta.id}');`
            );
            for (let i = 0; i < 3; i++) {
                await authorizeQuery(gamma);
            }

            // Gamma's sessions were opened by a caller that never ended them and have been idle
            // for hours, one for more than a day. Delta's two come from calling v1.2's
            // startSession twice, which opened a second session without ending the first.
            await admin.apex(`
                DateTime now = DateTime.now();
                List<AgentGov_Session__c> sessions = new List<AgentGov_Session__c>();
                for (Integer hoursAgo : new List<Integer>{ 26, 6, 5 }) {
                    sessions.add(new AgentGov_Session__c(Agent_Registration__c = '${gamma.id}',
                        Session_Start__c = now.addHours(-hoursAgo), Status__c = 'Active', API_Calls_Used__c = 0,
                        SOQL_Queries_Used__c = 0, DML_Statements_Used__c = 0, Actions_Count__c = 0));
                }
                insert sessions;
            `);
            await admin.apex(`AgentGovRegistryService.startSession('${delta.id}');`);
            await sleep(1500);
            await admin.apex(`AgentGovRegistryService.startSession('${delta.id}');`);
            await admin.apex(SCHEDULE_V1_2);

            const sessions = await admin.query(
                `SELECT Id, Agent_Registration__c FROM AgentGov_Session__c WHERE Status__c = 'Active' ORDER BY Session_Start__c`
            );
            const gammaSessions = sessions.filter((session) => session.Agent_Registration__c === gamma.id);
            const deltaSessions = sessions.filter((session) => session.Agent_Registration__c === delta.id);
            ensure(
                gammaSessions.length === 3 && deltaSessions.length === 2,
                `${gammaSessions.length} active sessions for Gamma and ${deltaSessions.length} for Delta, expected 3 and 2`
            );
            [legacy.gammaDayOld, legacy.gammaOlder, legacy.gammaNewest] = gammaSessions.map((session) => session.Id);
            [legacy.deltaFirst, legacy.deltaSecond] = deltaSessions.map((session) => session.Id);

            const [org] = await admin.query('SELECT TimeZoneSidKey FROM Organization');
            today = localDate(org.TimeZoneSidKey);
            startedRow = (await budgetRowsOf(gamma)).find((row) => row.Budget_Date__c === today);
            ensure(startedRow && used(startedRow) > 0, `v1.2 recorded no usage for Gamma on ${today}`);
            const jobs = await scheduledJobs([...JOB_NAMES, ADMIN_JOB]);
            ensure(jobs.length === 4, `${jobs.length} jobs scheduled, expected 4`);
        }
    );

    await upgradeStep(
        'W3',
        "The unschedule step removes every AgentGov job, including the administrator's own copy, and names it",
        async () => {
            const logs = runApexFile('scripts/setup/unschedule-jobs.apex');
            ensure(
                logs.includes(ADMIN_JOB),
                "the log does not name the administrator's job, so they would not know to recreate it"
            );
            const jobs = await scheduledJobs([...JOB_NAMES, ADMIN_JOB]);
            ensure(jobs.length === 0, `${jobs.length} jobs are still scheduled`);
        }
    );

    await upgradeStep('W4', 'This version deploys over the v1.2 org', async () => {
        ensure(deployFrom(REPO_ROOT) > 0, 'nothing was deployed');
    });

    await upgradeStep(
        'W5',
        "After the deploy, v1.2's administrators hold the new console permissions, the responder set exists, and one command schedules each job once",
        async () => {
            await admin.apex(`
                Assert.isTrue(FeatureManagement.checkPermission('AgentGov_Operate_Agents'), 'AgentGov_Admin lacks AgentGov_Operate_Agents');
                Assert.isTrue(FeatureManagement.checkPermission('AgentGov_Manage_Keys'), 'AgentGov_Admin lacks AgentGov_Manage_Keys');
            `);
            const responder = await admin.query("SELECT Id FROM PermissionSet WHERE Name = 'AgentGov_Responder'");
            ensure(responder.length === 1, 'the AgentGov_Responder permission set is missing');
            runApexFile('scripts/setup/schedule-jobs.apex');
            runApexFile('scripts/setup/schedule-jobs.apex');
            const jobs = await scheduledJobs(JOB_NAMES);
            ensure(jobs.length === 3, `${jobs.length} jobs after scheduling twice, expected 3`);
        }
    );

    await upgradeStep(
        'W6',
        'A key v1.2 issued still authenticates, and its request is charged to the budget row v1.2 started today',
        async () => {
            // Four hours, so the sessions v1.2 opened minutes ago count as live however long the
            // deploy took; the checks below then have one right answer.
            await setIdleMinutes(240);
            await authorizeQuery(gamma);
            const rows = await budgetRowsOf(gamma);
            const days = rows.map((row) => row.Budget_Date__c);
            ensure(new Set(days).size === days.length, 'Gamma has two budget rows for one day');
            const row = rows.find((candidate) => candidate.Budget_Date__c === today);
            ensure(
                row?.Id === startedRow.Id,
                'the request opened a new budget row instead of continuing the one v1.2 started'
            );
            ensure(used(row) > used(startedRow), 'the request was not charged');
        }
    );

    await upgradeStep(
        'W7',
        "Each agent's next action leaves it one live session holding the one-active key, without errors",
        async () => {
            await authorizeQuery(delta);
            const sessions = await sessionsOf(gamma, delta);
            const byId = new Map(sessions.map((session) => [session.Id, session]));
            const legacyIds = new Set(Object.values(legacy));

            // Gamma's newest v1.2 session had been idle for five hours: it closes at its start,
            // its only recorded activity, and a new session carries the action and the key.
            const idle = byId.get(legacy.gammaNewest);
            ensure(
                idle.Status__c === 'Completed' && idle.End_Reason__c === 'Idle',
                `Gamma's idle v1.2 session is ${idle.Status__c} (${idle.End_Reason__c})`
            );
            ensure(
                sameInstant(idle.Session_End__c, idle.Session_Start__c),
                "Gamma's idle v1.2 session did not end at its start"
            );
            const opened = sessions.filter(
                (session) => session.Agent_Registration__c === gamma.id && !legacyIds.has(session.Id)
            );
            ensure(
                opened.length === 1 &&
                    opened[0].Status__c === 'Active' &&
                    opened[0].Active_Session_Key__c === gamma.id &&
                    opened[0].Actions_Count__c === 1,
                `Gamma's new session: ${JSON.stringify(opened)}`
            );

            // Delta's second v1.2 session is live, so the action extends it and it takes the key.
            const extended = byId.get(legacy.deltaSecond);
            ensure(
                extended.Status__c === 'Active' &&
                    extended.Active_Session_Key__c === delta.id &&
                    extended.Actions_Count__c === 1 &&
                    extended.Last_Activity__c,
                `Delta's live v1.2 session: ${JSON.stringify(extended)}`
            );
            ensure(
                sessions.filter((session) => session.Agent_Registration__c === delta.id).length === 2,
                'a new session was opened for Delta although one was live'
            );

            // The sessions the actions did not touch are left for the health check.
            for (const id of [legacy.gammaDayOld, legacy.gammaOlder, legacy.deltaFirst]) {
                const untouched = byId.get(id);
                ensure(
                    untouched.Status__c === 'Active' && !untouched.Active_Session_Key__c,
                    `v1.2 session ${id} changed: ${JSON.stringify(untouched)}`
                );
            }
            const failures = await admin.query(
                "SELECT Error_Message__c FROM AgentGov_Action_Log__c WHERE Action_Type__c = 'System' AND Status__c = 'Failure'"
            );
            ensure(
                failures.length === 0,
                `framework failures were recorded: ${failures.map((failure) => failure.Error_Message__c).join(' | ')}`
            );
        }
    );

    await upgradeStep(
        'W8',
        'The health check closes every session v1.2 left open, each at its last known activity',
        async () => {
            await setIdleMinutes(1);
            await sleep(75 * 1000);
            await admin.apex('new AgentGovHealthCheck().execute(null);');
            const sessions = await sessionsOf(gamma, delta);
            const open = sessions.filter((session) => session.Status__c === 'Active');
            ensure(open.length === 0, `${open.length} sessions are still active`);
            ensure(
                sessions.every((session) => !session.Active_Session_Key__c),
                'a closed session kept the one-active key'
            );
            for (const session of sessions) {
                ensure(
                    sameInstant(session.Session_End__c, session.Last_Activity__c ?? session.Session_Start__c),
                    `session ${session.Id} ended at ${session.Session_End__c}, not at its last activity`
                );
            }
            const dayOld = sessions.find((session) => session.Id === legacy.gammaDayOld);
            ensure(dayOld.End_Reason__c === 'Max_Duration', `the day-old session closed as ${dayOld.End_Reason__c}`);
            const others = sessions.filter((session) => session.Id !== legacy.gammaDayOld);
            ensure(
                others.every((session) => session.End_Reason__c === 'Idle'),
                'a session closed for a reason other than idleness'
            );
        }
    );
}

// --- Run ----------------------------------------------------------------------------------------

let results = [];
let exitCode = 1;

try {
    step(`Creating temporary scratch org ${targetOrg} to upgrade from ${options.from}`);
    const create = ['org', 'create', 'scratch', '--definition-file', 'config/project-scratch-def.json'];
    create.push('--alias', targetOrg, '--duration-days', '1', '--wait', '30');
    if (options['dev-hub']) {
        create.push('--target-dev-hub', options['dev-hub']);
    }
    sf(create);

    await (options.from === 'v1.2' ? upgradeFromV12() : upgradeFromV11());

    results = suite.results;
    if (!options['skip-api-suite'] && results.every((result) => result.ok)) {
        step('Running the full API suite against the upgraded org');
        const context = { ...(await prepareOrg({ targetOrg, deploy: false })), runId };
        results = results.concat(await runApiSuite(context));
    }
    const failures = printTable(results);
    const label = options.from === 'v1.1' ? 'upgrade' : `upgrade-${options.from}`;
    console.log(`Results saved to ${saveResults(results, { label, targetOrg: 'temporary', runId })}`);
    exitCode = failures === 0 ? 0 : 1;
} catch (error) {
    printTable(suite.results);
    console.error(`\nThe upgrade test stopped: ${redact(error.message)}`);
} finally {
    if (!options.keep) {
        step(`Deleting temporary scratch org ${targetOrg}`);
        sf(['org', 'delete', 'scratch', '--target-org', targetOrg, '--no-prompt'], { allowFail: true });
    }
}
process.exit(exitCode);
