/**
 * Prepares a scratch org for the end-to-end suite: deploys the working tree, grants the
 * administrator the AgentGov_Admin permission set, applies test settings, and provides a
 * restricted agent user that holds nothing beyond the shipped AgentGov_Agent permission set.
 *
 * Refuses to touch anything but a scratch org, because it changes org-wide settings.
 */
import { randomBytes } from 'node:crypto';
import { Org, sf } from './lib/sf.mjs';

export const AGENT_USER_PREFIX = 'agentgov-e2e-agent-';
const AGENT_USER_PROFILE = 'Minimum Access - API Only Integrations';

// Two zones more than 24 hours apart: at any moment at least one of them is on a different
// calendar day from the org, which lets a check prove whose "today" a budget row uses.
const FAR_TIME_ZONES = ['Pacific/Kiritimati', 'Pacific/Pago_Pago'];

function step(message) {
    console.log(`\n> ${message}`);
}

/** Returns the calendar date (YYYY-MM-DD) that it currently is in the given IANA time zone. */
export function localDate(timeZone, at = new Date()) {
    return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(at);
}

function assertScratchOrg(targetOrg) {
    const display = sf(['org', 'display', '--target-org', targetOrg]).result;
    if (!display.expirationDate && !display.devHubId) {
        throw new Error(`${targetOrg} is not a scratch org. The end-to-end suite only runs against scratch orgs.`);
    }
    return display;
}

function deploy(targetOrg) {
    const result = sf(
        ['project', 'deploy', 'start', '--source-dir', 'force-app', '--target-org', targetOrg, '--wait', '30'],
        {
            allowFail: true
        }
    );
    if (result.result?.status !== 'Succeeded') {
        const failures = (result.result?.files ?? [])
            .filter((file) => file.error)
            .map((file) => `${file.fullName}: ${file.error}`);
        throw new Error(`Deploy failed:\n${failures.join('\n') || result.message}`);
    }
    return result.result.numberComponentsDeployed;
}

function assignPermissionSet(targetOrg, name, onBehalfOf) {
    const args = ['org', 'assign', 'permset', '--name', name, '--target-org', targetOrg];
    if (onBehalfOf) {
        args.push('--on-behalf-of', onBehalfOf);
    }
    const result = sf(args, { allowFail: true });
    const failures = result.result?.failures ?? [];
    // Re-running setup finds the assignment already in place, which is the state we want.
    const unexpected = failures.filter((failure) => !/duplicate/i.test(failure.message ?? ''));
    if (result.status !== 0 && (unexpected.length || !failures.length)) {
        throw new Error(
            `Permission set ${name} could not be assigned: ${JSON.stringify(unexpected) || result.message}`
        );
    }
}

const SETTINGS_APEX = `
AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
if (settings.Id == null) {
    settings.SetupOwnerId = UserInfo.getOrganizationId();
}
settings.Is_Enabled__c = true;
settings.Enable_Real_Time_Events__c = true;
settings.Enable_Conflict_Detection__c = true;
settings.Circuit_Breaker_Failure_Threshold__c = 3;
settings.Circuit_Breaker_Cooldown_Minutes__c = 1;
settings.Max_Concurrent_Agents__c = 500;
// A run triggers alerts on purpose. Alert email is off while it runs, so the suite mails no
// one and cannot use up the org's daily email allowance, which the Apex tests also need.
settings.Admin_Notification_Email__c = null;
Map<String, Schema.SObjectField> fields = Schema.SObjectType.AgentGov_Settings__c.fields.getMap();
if (fields.containsKey('notify_agent_owners__c')) {
    settings.put('Notify_Agent_Owners__c', false);
}
if (fields.containsKey('session_idle_minutes__c')) {
    settings.put('Session_Idle_Minutes__c', 1);
}
upsert settings;
`;

// Earlier runs leave agents behind. They are deactivated and unbound so that the concurrent
// agent cap and the user bindings start from a known state.
const RETIRE_APEX = `
List<AgentGov_Registration__c> stale = [
    SELECT Id FROM AgentGov_Registration__c
    WHERE Agent_Name__c LIKE 'E2E %' AND (Status__c != 'Inactive' OR Agent_User__c != null)
    LIMIT 5000
];
for (AgentGov_Registration__c registration : stale) {
    registration.Status__c = 'Inactive';
    registration.Agent_User__c = null;
}
update stale;
`;

async function ensureAgentUser(admin, targetOrg) {
    const existing = await admin.query(
        `SELECT Id, Username FROM User WHERE Username LIKE '${AGENT_USER_PREFIX}%' AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1`
    );
    let username = existing[0]?.Username;
    if (username && sf(['org', 'display', '--target-org', username], { allowFail: true }).status !== 0) {
        // The user exists in the org but this machine's CLI holds no credential for it.
        username = undefined;
    }
    if (!username) {
        username = `${AGENT_USER_PREFIX}${randomBytes(4).toString('hex')}@example.com`;
        sf([
            'org',
            'create',
            'user',
            '--target-org',
            targetOrg,
            `username=${username}`,
            `profileName=${AGENT_USER_PROFILE}`,
            'lastName=AgentGov E2E Agent',
            'email=noreply@example.com'
        ]);
    }
    assignPermissionSet(targetOrg, 'AgentGov_Agent', username);
    const [user] = await admin.query(`SELECT Id FROM User WHERE Username = '${username}'`);
    return { username, id: user.Id };
}

/**
 * Prepares the org and returns handles for the administrator and the restricted agent user.
 * @param {{ targetOrg: string, deploy?: boolean }} options
 */
export async function prepareOrg({ targetOrg, deploy: shouldDeploy = true }) {
    step(`Checking that ${targetOrg} is a scratch org`);
    const display = assertScratchOrg(targetOrg);
    console.log(`  ok (expires ${display.expirationDate ?? 'unknown'})`);

    if (shouldDeploy) {
        // The documented upgrade procedure: scheduled jobs block the deploy of any class they
        // use, so they are removed first. The script works on every AgentGov version.
        step('Removing scheduled AgentGov jobs so the deploy is not blocked');
        sf(['apex', 'run', '--file', 'scripts/setup/unschedule-jobs.apex', '--target-org', targetOrg]);
        step('Deploying force-app');
        console.log(`  ${deploy(targetOrg)} components deployed`);
    }

    step('Granting the administrator AgentGov_Admin');
    assignPermissionSet(targetOrg, 'AgentGov_Admin');

    const admin = new Org(targetOrg);
    step('Applying end-to-end settings (breaker trips after 3 failures, 1 minute cooldown and idle window)');
    await admin.apex(SETTINGS_APEX);
    await admin.apex(RETIRE_APEX);

    step('Preparing the restricted agent user');
    const agentUser = await ensureAgentUser(admin, targetOrg);

    const [organization] = await admin.query('SELECT TimeZoneSidKey FROM Organization');
    const orgTimeZone = organization.TimeZoneSidKey;
    const orgToday = localDate(orgTimeZone);
    const userTimeZone = FAR_TIME_ZONES.find((zone) => localDate(zone) !== orgToday);
    const patched = await admin.rest('PATCH', `/services/data/v67.0/sobjects/User/${agentUser.id}`, {
        body: { TimeZoneSidKey: userTimeZone }
    });
    if (patched.status !== 204) {
        throw new Error(`Could not set the agent user's time zone: ${JSON.stringify(patched.body)}`);
    }
    console.log(`  ready; its time zone (${userTimeZone}) is on a different day from the org (${orgTimeZone})`);

    return {
        targetOrg,
        admin,
        orgTimeZone,
        agentUser: { ...agentUser, timeZone: userTimeZone, org: new Org(agentUser.username) }
    };
}
