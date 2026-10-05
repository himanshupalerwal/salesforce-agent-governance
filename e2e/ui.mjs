/**
 * Browser checks. Opens the AgentGov app in headless Chromium and checks what the people who
 * operate the framework can see and do, after traffic.mjs has produced real activity: the
 * administrator, an on-call responder who may act on agents but not handle keys, and a
 * read-only user.
 *
 * Each login link comes from `sf org open --url-only`. It is single-use, is passed straight to
 * the browser, and is never printed or written anywhere.
 */
import { randomBytes } from 'node:crypto';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { ensure, Suite } from './lib/checks.mjs';
import { quote, sf, waitFor } from './lib/sf.mjs';
import { ensureDemoAgents, runTrafficSuite, tripBreaker } from './traffic.mjs';

const screenshotDir = join(dirname(fileURLToPath(import.meta.url)), 'results', 'screenshots');
const RENDER_TIMEOUT_MS = 60000;

// People who use the console with less than full access, holding the permission sets the
// getting-started guide gives them. Each is a real user of the org, signed in through the CLI
// as the administrator is.
const CONSOLE_ROLES = {
    responder: { permissionSets: ['AgentGov_User', 'AgentGov_Responder'], lastName: 'E2E Responder' },
    viewer: { permissionSets: ['AgentGov_User'], lastName: 'E2E Viewer' }
};

/**
 * Returns the CLI alias, user Id, and a newly generated password of the org's user for a console
 * role, creating the user on first use and resetting its password on every call. A Platform
 * licence is enough, since AgentGov is built from custom objects.
 */
async function ensureConsoleUser(admin, role) {
    const alias = `${admin.targetOrg}-${role}`;
    const { permissionSets, lastName } = CONSOLE_ROLES[role];
    let username = sf(['org', 'display', '--target-org', alias], { allowFail: true }).result?.username;
    if (username) {
        // A user from an earlier run keeps its role's permission sets; one already assigned is
        // reported as a duplicate, which is fine.
        const assign = ['org', 'assign', 'permset', '--target-org', admin.targetOrg, '--on-behalf-of', username];
        sf([...assign, ...permissionSets.flatMap((name) => ['--name', name])], { allowFail: true });
    } else {
        const dir = mkdtempSync(join(tmpdir(), 'agentgov-user-'));
        const definition = join(dir, 'user.json');
        writeFileSync(
            definition,
            JSON.stringify({
                LastName: lastName,
                Email: `${role}@example.com`,
                profileName: 'Standard Platform User',
                permsets: permissionSets
            })
        );
        try {
            const created = sf([
                'org',
                'create',
                'user',
                '--target-org',
                admin.targetOrg,
                '--set-alias',
                alias,
                '--definition-file',
                definition
            ]);
            username = created.result.fields.username;
        } finally {
            rmSync(dir, { recursive: true, force: true });
        }
    }
    const [user] = await admin.query(`SELECT Id FROM User WHERE Username = ${quote(username)}`);
    // A fresh password, set now and held only in memory, is what the first browser login's
    // change-password page asks for. The CLI's remembered one can be out of date.
    const generated = sf([
        'org',
        'generate',
        'password',
        '--on-behalf-of',
        username,
        '--target-org',
        admin.targetOrg
    ]).result;
    const password = Array.isArray(generated) ? generated[0]?.password : generated?.password;
    return { alias, id: user.Id, password };
}

async function openApp(targetOrg, browser, path, { viewport = { width: 1440, height: 1000 }, password } = {}) {
    const { result } = sf(['org', 'open', '--target-org', targetOrg, '--url-only', '--path', path]);
    const context = await browser.newContext({ viewport });
    const page = await context.newPage();
    await page.goto(result.url, { waitUntil: 'domcontentloaded', timeout: 120000 });
    await completeFirstLogin(page, password);
    try {
        await page.waitForURL(/\/lightning\//, { timeout: 120000 });
    } catch (error) {
        // Says where the login stopped, by path and title only, so a failure can be diagnosed
        // without the session or the host appearing in the results.
        const stoppedAt = `${new URL(page.url()).pathname} ("${await page.title().catch(() => '')}")`;
        mkdirSync(screenshotDir, { recursive: true });
        await page.screenshot({ path: join(screenshotDir, `login-stopped-${targetOrg}.png`) }).catch(() => {});
        throw new Error(`the login as ${targetOrg} did not reach Lightning; it stopped at ${stoppedAt}`, {
            cause: error
        });
    }
    return { context, page };
}

/**
 * Takes a browser login through the pages Salesforce can show before the app, in whatever order
 * they come, until a Lightning page loads or the time runs out. A user's first login asks for a
 * new password and a security question, however the password was set; the suite's own console
 * users answer it once, with the password ensureConsoleUser has just set and values that live
 * only in memory, so nothing is printed or saved. Any user may also be shown a one-time notice
 * of scheduled maintenance, which is dismissed.
 */
async function completeFirstLogin(page, current) {
    const newPassword = page.locator('#newpassword');
    const maintenanceNotice = page.getByText('Got it', { exact: true }).first();
    const deadline = Date.now() + 120000;
    let passwordChanged = false;
    while (Date.now() < deadline) {
        if (/^\/lightning\//.test(new URL(page.url()).pathname)) {
            return;
        }
        // Answered once only: a page still showing the form is waited out, not filled in again.
        if (!passwordChanged && (await newPassword.isVisible().catch(() => false))) {
            if (!current) {
                throw new Error('the first login asks for a new password, and none was set for this user');
            }
            const fresh = `Ag1${randomBytes(18).toString('hex')}`;
            // The page enables its button from key events, so the values are typed rather than set.
            await page.locator('#currentpassword').pressSequentially(current);
            await newPassword.pressSequentially(fresh);
            await page.locator('#confirmpassword').pressSequentially(fresh);
            await page.locator('#question').selectOption({ index: 1 });
            await page.locator('#answer').pressSequentially(randomBytes(8).toString('hex'));
            await page.locator('#password-button').click({ timeout: 15000 });
            passwordChanged = true;
            await page.waitForLoadState('domcontentloaded').catch(() => {});
            continue;
        }
        if (await maintenanceNotice.isVisible().catch(() => false)) {
            await maintenanceNotice.click();
            await page.waitForLoadState('domcontentloaded').catch(() => {});
            continue;
        }
        await page.waitForTimeout(1000);
    }
}

/**
 * Opens the row menu of an agent on the console's Agents tab. Returns the menu's labels, or null
 * when the list offers no actions at all. With `choose`, clicks that item and leaves it to the
 * caller to confirm; otherwise the menu is closed again.
 */
async function agentRowMenu(page, agentName, { choose } = {}) {
    await page.getByRole('tab', { name: 'Agents', exact: true }).first().click({ timeout: RENDER_TIMEOUT_MS });
    // Scoped to the agent list: the console's other tabs keep their own tables in the page.
    const row = page.locator('c-agent-gov-agent-list tr').filter({ hasText: agentName }).first();
    await row.waitFor({ timeout: RENDER_TIMEOUT_MS });
    const menuButton = row.getByRole('button', { name: /show actions/i });
    if ((await menuButton.count()) === 0) {
        return null;
    }
    await menuButton.first().click();
    const items = page.getByRole('menuitem');
    await items.first().waitFor({ timeout: 15000 });
    const labels = (await items.allInnerTexts()).map((label) => label.trim()).filter(Boolean);
    if (choose) {
        // Matched exactly, so that Activate never picks Deactivate.
        await page.getByRole('menuitem', { name: choose, exact: true }).click();
    } else {
        await page.keyboard.press('Escape');
    }
    return labels;
}

/**
 * Types an amount into the credit dialog the way a person does, once the dialog has finished
 * opening, and checks the field holds it. Filling the field the instant it appeared could be
 * lost, leaving the dialog to refuse an empty amount.
 */
async function enterAmount(page, dialog, amount) {
    const input = dialog.locator('input[name="amount"]');
    await input.waitFor({ timeout: 15000 });
    await page.waitForTimeout(1000);
    await input.click();
    await input.pressSequentially(amount);
    await input.press('Tab');
    const held = (await input.inputValue()).replace(/\D/g, '');
    ensure(held === amount, `the amount field holds "${held}", not ${amount}`);
}

// Disruptive actions ask for confirmation in a dialog that opens a moment after the click.
async function confirmDialog(page) {
    const confirm = page.getByRole('button', { name: 'OK', exact: true }).last();
    await confirm.waitFor({ timeout: 15000 });
    await confirm.click();
}

async function consolePath(admin) {
    const tabs = await admin.query(
        "SELECT Name FROM TabDefinition WHERE Name IN ('AgentGov_Console', 'AgentGov_Dashboard')"
    );
    const names = new Set(tabs.map((tab) => tab.Name));
    return names.has('AgentGov_Console') ? '/lightning/n/AgentGov_Console' : '/lightning/n/AgentGov_Dashboard';
}

export async function runUiSuite(context) {
    const { admin, targetOrg } = context;
    const suite = new Suite('ui');
    mkdirSync(screenshotDir, { recursive: true });
    if (!context.demoAgents) {
        await runTrafficSuite(context);
    }
    const agents = context.demoAgents ?? (await ensureDemoAgents(admin));
    const orderSync = agents['Order Sync Agent'];

    // The e2e settings use a one-minute cooldown and idle window; the browser needs longer than
    // that to open the app and look, so both are widened while it does. Sessions are judged live
    // against the current setting, so the demo traffic's sessions count as live again.
    await admin.apex(`
        AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
        settings.Circuit_Breaker_Cooldown_Minutes__c = 10;
        settings.Session_Idle_Minutes__c = 30;
        update settings;
        AgentGovCircuitBreaker.resetBreaker('${orderSync.id}');
    `);
    await tripBreaker(admin, orderSync);

    const authorizeWith = (key) =>
        admin.apexRest('POST', '/agentgov/authorize', {
            headers: { 'X-AgentGov-Key': key },
            body: { objectName: 'Account', operation: 'Query' }
        });
    const adminRows = (agent) =>
        admin.query(
            `SELECT Id, Details__c, CreatedById FROM AgentGov_Action_Log__c WHERE Agent_Registration__c = '${agent.id}' AND Action_Type__c = 'Admin' ORDER BY CreatedDate DESC`
        );
    const registration = async (agent) =>
        (
            await admin.query(
                `SELECT Status__c, Circuit_Breaker_State__c FROM AgentGov_Registration__c WHERE Id = '${agent.id}'`
            )
        )[0];
    const statusOf = async (agent) => (await registration(agent)).Status__c;
    const breakerOf = async (agent) => (await registration(agent)).Circuit_Breaker_State__c;
    // Console actions finish on the server a moment after the click.
    const soon = { timeoutMs: 20000, intervalMs: 2000 };
    const attentionRow = (page, agentName) =>
        page.locator('c-agent-gov-overview tr.attention-row').filter({ hasText: agentName }).first();

    const browser = await chromium.launch();
    const path = await consolePath(admin);
    const shot = async (page, name, options = {}) =>
        page.screenshot({ path: join(screenshotDir, `${name}.png`), fullPage: true, ...options });
    try {
        const { page } = await openApp(targetOrg, browser, path);

        await suite.check('U1', 'The AgentGov console opens and lists the demo agents', async () => {
            await page.getByText('Contact Enrichment Agent').first().waitFor({ timeout: RENDER_TIMEOUT_MS });
            await page.waitForTimeout(3000);
            await shot(page, 'console-overview');
        });

        await suite.check('U2', 'Live sessions are listed with the agents running them', async () => {
            const card = page
                .locator('article, section')
                .filter({ hasText: /Live sessions/i })
                .last();
            await card.waitFor({ timeout: 15000 });
            const text = await card.innerText();
            ensure(
                /Contact Enrichment Agent|Case Triage Agent|Renewal Forecast Flow/.test(text),
                'no demo agent listed'
            );
        });

        await suite.check('U3', 'A tripped breaker shows when the agent may retry', async () => {
            const row = attentionRow(page, 'Order Sync Agent');
            await row.waitFor({ timeout: 15000 });
            ensure(
                /retry|cooldown/i.test(await row.innerText()),
                'no retry or cooldown time next to the tripped agent'
            );
        });

        await suite.check('U4', 'An administrator can reset a tripped breaker from the console', async () => {
            const auditBefore = (await adminRows(orderSync)).length;
            await attentionRow(page, 'Order Sync Agent')
                .getByRole('button', { name: 'Reset breaker', exact: true })
                .click({ timeout: 15000 });
            // The confirmation says what a reset changes and what it leaves in force.
            const confirmation = page.getByText(/its failure count is cleared/).first();
            await confirmation.waitFor({ timeout: 15000 });
            ensure(
                /A deactivated agent stays deactivated, and today's budget limits still apply\./.test(
                    await confirmation.innerText()
                ),
                'the confirmation does not say that deactivation and budget limits still apply'
            );
            await confirmDialog(page);
            ensure(
                await waitFor(async () => (await breakerOf(orderSync)) === 'CLOSED', soon),
                `the breaker is still ${await breakerOf(orderSync)}`
            );
            ensure((await adminRows(orderSync)).length > auditBefore, 'the reset left no Admin audit row');
            await shot(page, 'console-after-reset');
        });

        await suite.check('U5', "Clicking an agent opens its record page with the agent's activity", async () => {
            await page.getByRole('link', { name: 'Contact Enrichment Agent' }).first().click({ timeout: 15000 });
            await page.waitForURL(/\/lightning\/r\/AgentGov_Registration__c\//, { timeout: RENDER_TIMEOUT_MS });
            // Scoped to the panel: Lightning keeps the console page it came from, hidden, in the DOM.
            await page
                .locator('c-agent-gov-agent-panel')
                .getByText(/recent activity/i)
                .first()
                .waitFor({ timeout: RENDER_TIMEOUT_MS });
            await page.waitForTimeout(3000);
            await shot(page, 'agent-record-page');
        });

        await suite.check(
            'U6',
            'Filtering the activity log to Denied shows a refused request with its reason',
            async () => {
                const { page: logPage } = await openApp(targetOrg, browser, path);
                await logPage
                    .getByRole('tab', { name: 'Activity', exact: true })
                    .first()
                    .click({ timeout: RENDER_TIMEOUT_MS });
                const log = logPage.locator('c-agent-gov-activity-log');
                await log.getByRole('combobox', { name: 'Status' }).click({ timeout: RENDER_TIMEOUT_MS });
                await log.getByRole('option', { name: 'Denied', exact: true }).click();
                await log
                    .getByText(/policy violation/i)
                    .first()
                    .waitFor({ timeout: RENDER_TIMEOUT_MS });
                const statuses = await log.locator('tr.log-row .log-status').allInnerTexts();
                ensure(
                    statuses.length > 0 && statuses.every((status) => status.trim() === 'Denied'),
                    `the filtered rows are ${[...new Set(statuses)].join(', ')}`
                );
                await shot(logPage, 'activity-log');
            }
        );

        await suite.check(
            'U7',
            "A responder resets a breaker from the console, is recorded as the audit row's creator, and is never offered key rotation",
            async () => {
                const responder = await ensureConsoleUser(admin, 'responder');
                await tripBreaker(admin, orderSync);
                const { page: responderPage } = await openApp(responder.alias, browser, path, {
                    password: responder.password
                });
                const labels = await agentRowMenu(responderPage, 'Order Sync Agent');
                ensure(labels, 'the responder is offered no actions on the agent list');
                ensure(
                    labels.some((label) => /reset breaker/i.test(label)),
                    `the menu offers ${labels.join(', ')}, without Reset breaker`
                );
                ensure(!labels.some((label) => /rotate key/i.test(label)), 'the responder is offered key rotation');
                await agentRowMenu(responderPage, 'Order Sync Agent', { choose: 'Reset breaker' });
                await confirmDialog(responderPage);
                ensure(
                    await waitFor(async () => (await breakerOf(orderSync)) === 'CLOSED', soon),
                    `the breaker is still ${await breakerOf(orderSync)}`
                );
                const [audit] = await adminRows(orderSync);
                ensure(
                    audit?.CreatedById === responder.id,
                    'the latest Admin audit row was not created by the responder'
                );
                await shot(responderPage, 'console-responder');
            }
        );

        await suite.check('U8', 'A read-only user sees the agents but no control that changes anything', async () => {
            const viewer = await ensureConsoleUser(admin, 'viewer');
            await tripBreaker(admin, orderSync);
            const { page: viewerPage } = await openApp(viewer.alias, browser, path, { password: viewer.password });
            await attentionRow(viewerPage, 'Order Sync Agent').waitFor({ timeout: RENDER_TIMEOUT_MS });
            const actionButtons = /reset breakers?|activate|rotate key|credit budget|end sessions?|schedule jobs/i;
            ensure(
                (await viewerPage.getByRole('button', { name: actionButtons }).count()) === 0,
                'the overview shows an action button'
            );
            ensure((await agentRowMenu(viewerPage, 'Order Sync Agent')) === null, 'the agent list offers actions');
            ensure((await viewerPage.getByRole('checkbox').count()) === 0, 'the agent list offers row selection');
            ensure(
                (await viewerPage.getByRole('button', { name: actionButtons }).count()) === 0,
                'the agent list shows an action button'
            );
            ensure((await viewerPage.getByRole('tab', { name: 'Setup' }).count()) === 0, 'the Setup tab is shown');
            await shot(viewerPage, 'console-read-only');
        });

        await suite.check(
            'U9',
            'In a narrow window the console reflows: side-by-side panels stack and no tab overflows its width',
            async () => {
                const { page: narrow } = await openApp(targetOrg, browser, path, {
                    viewport: { width: 600, height: 1000 }
                });
                await narrow.getByText('Contact Enrichment Agent').first().waitFor({ timeout: RENDER_TIMEOUT_MS });
                await narrow.waitForTimeout(3000);
                const panels = narrow.locator('c-agent-gov-overview .overview-split > section');
                const boxes = [];
                for (let i = 0; i < (await panels.count()); i++) {
                    boxes.push(await panels.nth(i).boundingBox());
                }
                ensure(
                    boxes.length >= 2 && boxes.every((box) => box && Math.abs(box.x - boxes[0].x) < 2),
                    `the ${boxes.length} side-by-side panels did not stack`
                );
                await shot(narrow, 'console-narrow');
                for (const tab of ['Overview', 'Agents', 'Activity']) {
                    await narrow.getByRole('tab', { name: tab, exact: true }).first().click();
                    await narrow.waitForTimeout(2000);
                    const frame = await narrow
                        .locator('c-agent-gov-console .slds-tabs_default')
                        .first()
                        .evaluate((element) => ({
                            right: element.getBoundingClientRect().right,
                            scrollWidth: element.scrollWidth,
                            clientWidth: element.clientWidth,
                            viewport: element.ownerDocument.documentElement.clientWidth
                        }));
                    ensure(
                        frame.scrollWidth <= frame.clientWidth + 1 && frame.right <= frame.viewport + 1,
                        `the ${tab} tab overflows: ${JSON.stringify(frame)}`
                    );
                }
            }
        );

        // --- The console's other actions, each proven by its effect on the org ---------------

        let consolePage;

        await suite.check(
            'U10',
            'An administrator deactivates an agent from the console, which refuses it at once, then activates it again; both changes are audited',
            async () => {
                ({ page: consolePage } = await openApp(targetOrg, browser, path));
                const agent = agents['Renewal Forecast Flow'];
                const auditBefore = (await adminRows(agent)).length;
                await agentRowMenu(consolePage, 'Renewal Forecast Flow', { choose: 'Deactivate' });
                // The confirmation says where the agent is refused rather than claiming every entry point.
                await consolePage
                    .getByText(/will be refused wherever it asks to act or to report usage/)
                    .first()
                    .waitFor({ timeout: 15000 });
                await confirmDialog(consolePage);
                ensure(
                    await waitFor(async () => (await statusOf(agent)) === 'Inactive', soon),
                    'the agent is still active'
                );
                const refused = await authorizeWith(agent.key);
                ensure(refused.status === 403, `the deactivated agent got ${refused.status}`);
                // The list refreshes itself after an action, so the row now offers Activate.
                await consolePage
                    .locator('c-agent-gov-agent-list tr')
                    .filter({ hasText: 'Renewal Forecast Flow' })
                    .filter({ hasText: 'Inactive' })
                    .first()
                    .waitFor({ timeout: RENDER_TIMEOUT_MS });
                await agentRowMenu(consolePage, 'Renewal Forecast Flow', { choose: 'Activate' });
                ensure(
                    await waitFor(async () => (await statusOf(agent)) === 'Active', soon),
                    'the agent was not activated again'
                );
                const admitted = await authorizeWith(agent.key);
                ensure(admitted.status === 200, `the reactivated agent got ${admitted.status}`);
                ensure((await adminRows(agent)).length >= auditBefore + 2, 'the two changes were not both audited');
            }
        );

        await suite.check(
            'U11',
            'Rotating a key from the console shows the new key once; the old key is refused, the new one works, and the audit row does not hold it',
            async () => {
                const agent = agents['Case Triage Agent'];
                const oldKey = agent.key;
                await agentRowMenu(consolePage, 'Case Triage Agent', { choose: 'Rotate key' });
                await confirmDialog(consolePage);
                const keyField = consolePage.locator('input.key-input');
                await keyField.waitFor({ timeout: RENDER_TIMEOUT_MS });
                const newKey = await keyField.inputValue();
                ensure(newKey && newKey !== oldKey, 'no new key was shown');
                agent.key = newKey;
                // The key works until the agent's key is rotated again, so the saved image covers it.
                await shot(consolePage, 'console-new-key', { mask: [keyField] });
                await consolePage.getByRole('button', { name: 'Done', exact: true }).click();
                await keyField.waitFor({ state: 'detached', timeout: 15000 });
                const refused = await authorizeWith(oldKey);
                ensure(refused.status === 404, `the old key got ${refused.status}`);
                const admitted = await authorizeWith(newKey);
                ensure(admitted.status === 200, `the new key got ${admitted.status}`);
                const [audit] = await adminRows(agent);
                ensure(audit, 'the rotation was not audited');
                ensure(!String(audit.Details__c).includes(newKey), 'the audit row holds the whole key');
            }
        );

        await suite.check(
            'U12',
            "Ending a live session from the console closes it and is audited, and the agent's next call opens a new one",
            async () => {
                const agent = agents['Contact Enrichment Agent'];
                const liveSession = async () =>
                    (
                        await admin.query(
                            `SELECT Id FROM AgentGov_Session__c WHERE Agent_Registration__c = '${agent.id}' AND Status__c = 'Active'`
                        )
                    )[0];
                const live = await liveSession();
                ensure(live, 'the agent has no live session to end');
                const auditBefore = (await adminRows(agent)).length;
                await agentRowMenu(consolePage, 'Contact Enrichment Agent', { choose: 'End session' });
                await confirmDialog(consolePage);
                const ended = await waitFor(async () => {
                    const [session] = await admin.query(
                        `SELECT Status__c, End_Reason__c FROM AgentGov_Session__c WHERE Id = '${live.Id}'`
                    );
                    return session.Status__c === 'Active' ? null : session;
                }, soon);
                ensure(
                    ended?.Status__c === 'Terminated' && ended.End_Reason__c === 'Ended_By_Administrator',
                    `the session is ${ended?.Status__c ?? 'still Active'} (${ended?.End_Reason__c})`
                );
                const audits = await adminRows(agent);
                ensure(
                    audits.length === auditBefore + 1 && String(audits[0].Details__c).includes(live.Id),
                    `ending the session was not audited: ${audits[0]?.Details__c}`
                );
                ensure(
                    (await authorizeWith(agent.key)).status === 200,
                    'the agent could not act after its session ended'
                );
                const next = await liveSession();
                ensure(next && next.Id !== live.Id, 'the next call did not open a new session');
            }
        );

        await suite.check(
            'U13',
            'Crediting a budget from the console gives the usage back, and the credit is audited',
            async () => {
                const agent = agents['Case Triage Agent'];
                const apiCallsUsed = async () =>
                    (
                        await admin.query(
                            `SELECT API_Calls_Consumed__c FROM AgentGov_Budget__c WHERE Agent_Registration__c = '${agent.id}' ORDER BY Budget_Date__c DESC LIMIT 1`
                        )
                    )[0]?.API_Calls_Consumed__c ?? 0;
                const before = await apiCallsUsed();
                ensure(before >= 10, `the agent has used ${before} API calls, too few to credit 10`);
                const auditBefore = (await adminRows(agent)).length;
                await agentRowMenu(consolePage, 'Case Triage Agent', { choose: 'Credit budget' });
                const dialog = consolePage.getByRole('dialog').last();
                await enterAmount(consolePage, dialog, '10');
                await dialog.getByRole('button', { name: 'Credit budget', exact: true }).click();
                const after = await waitFor(async () => {
                    const used = await apiCallsUsed();
                    return used < before ? used : null;
                }, soon);
                ensure(after === before - 10, `usage went from ${before} to ${after}, expected ${before - 10}`);
                ensure((await adminRows(agent)).length === auditBefore + 1, 'the credit was not audited');
            }
        );

        await suite.check(
            'U14',
            'Crediting more than an agent has used credits only what it used, and the audit row says so',
            async () => {
                const agent = agents['Case Triage Agent'];
                // One more governed API call, so there is usage to credit whatever U13 left.
                const charged = await admin.apexRest('POST', '/agentgov/authorize', {
                    headers: { 'X-AgentGov-Key': agent.key },
                    body: { objectName: 'Case', operation: 'API_Call' }
                });
                ensure(charged.status === 200, `the agent's API call got ${charged.status}`);
                const apiCallsUsed = async () =>
                    (
                        await admin.query(
                            `SELECT API_Calls_Consumed__c FROM AgentGov_Budget__c WHERE Agent_Registration__c = '${agent.id}' ORDER BY Budget_Date__c DESC LIMIT 1`
                        )
                    )[0]?.API_Calls_Consumed__c ?? 0;
                const before = await apiCallsUsed();
                ensure(before >= 1, `the agent has used ${before} API calls`);
                const auditBefore = (await adminRows(agent)).length;
                await agentRowMenu(consolePage, 'Case Triage Agent', { choose: 'Credit budget' });
                const dialog = consolePage.getByRole('dialog').last();
                await enterAmount(consolePage, dialog, '1000000');
                await dialog.getByRole('button', { name: 'Credit budget', exact: true }).click();
                if (!(await waitFor(async () => (await apiCallsUsed()) === 0, soon))) {
                    // Says what the dialog shows, such as an error the server returned.
                    const shown = (await dialog.isVisible().catch(() => false))
                        ? (await dialog.innerText()).replace(/\s+/g, ' ').trim()
                        : 'the dialog had closed';
                    ensure(false, `usage went from ${before} to ${await apiCallsUsed()}, not zero; ${shown}`);
                }
                const audits = await adminRows(agent);
                ensure(audits.length === auditBefore + 1, 'the credit was not audited');
                const expected = new RegExp(
                    `^Credited ${before} API calls? to today's budget, bringing its API call usage to zero ` +
                        '\\(a credit of 1000000 was requested\\)\\.'
                );
                ensure(expected.test(audits[0].Details__c), `the audit row reads "${audits[0].Details__c}"`);
            }
        );

        // --- What the console says about the org's setup and an agent's key ---------------------

        await suite.check(
            'U15',
            'The Setup tab shows the session idle window in force, and warns that no alerts are raised while real-time events are off',
            async () => {
                // An idle window outside 1 to 1440 minutes, which the framework replaces with the
                // 30-minute default, and real-time events off.
                await admin.apex(`
                    AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
                    settings.Session_Idle_Minutes__c = 0;
                    settings.Enable_Real_Time_Events__c = false;
                    update settings;
                `);
                try {
                    const { page: setupPage } = await openApp(targetOrg, browser, path);
                    await setupPage
                        .getByRole('tab', { name: 'Setup', exact: true })
                        .first()
                        .click({ timeout: RENDER_TIMEOUT_MS });
                    const setup = setupPage.locator('c-agent-gov-setup-status');
                    await setup.locator('li.check').first().waitFor({ timeout: RENDER_TIMEOUT_MS });
                    const lines = (await setup.locator('.check-label').allInnerTexts()).map((line) => line.trim());
                    const listed = lines.join(' | ');
                    ensure(
                        lines.includes('A session ends after 30 minutes without activity, or after 24 hours.'),
                        `the checklist does not show the idle window in force: ${listed}`
                    );
                    ensure(
                        lines.some((line) => line.startsWith('Real-time events are off in AgentGov Settings')),
                        `the checklist does not say that real-time events are off: ${listed}`
                    );
                    ensure(
                        !lines.some((line) => /alerts are (recorded|emailed)/i.test(line)),
                        `the checklist says alerts are recorded or emailed while none are raised: ${listed}`
                    );
                    ensure(
                        /replaces the jobs in this table/.test(await setup.locator('.schedule-help').innerText()),
                        'the Setup tab does not say that Schedule jobs replaces the jobs'
                    );
                    await shot(setupPage, 'console-setup-events-off');
                } finally {
                    // Back to the values this suite runs with.
                    await admin.apex(`
                        AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
                        settings.Session_Idle_Minutes__c = 30;
                        settings.Enable_Real_Time_Events__c = true;
                        update settings;
                    `);
                }
            }
        );

        await suite.check(
            'U16',
            "An agent's page shows a key with no stored prefix as issued, and says a deactivated agent has no session because it is deactivated",
            async () => {
                // A plaintext key from before keys were hashed, which an upgraded org holds until
                // the agent next connects: it works, and no prefix is stored for it.
                const name = `E2E Legacy Key ${randomBytes(3).toString('hex')}`;
                await admin.apex(`
                    insert new AgentGov_Registration__c(
                        Agent_Name__c = ${quote(name)},
                        Agent_Type__c = 'Custom_Apex',
                        Status__c = 'Inactive',
                        API_Key__c = ${quote(`legacy-${randomBytes(8).toString('hex')}`)}
                    );
                `);
                const [legacy] = await admin.query(
                    `SELECT Id FROM AgentGov_Registration__c WHERE Agent_Name__c = ${quote(name)}`
                );
                ensure(legacy, `${name} was not created`);
                try {
                    const { page: agentPage } = await openApp(
                        targetOrg,
                        browser,
                        `/lightning/r/AgentGov_Registration__c/${legacy.Id}/view`
                    );
                    const panel = agentPage.locator('c-agent-gov-agent-panel');
                    const key = panel.locator('.key-prefix');
                    await key.waitFor({ timeout: RENDER_TIMEOUT_MS });
                    const keyText = (await key.innerText()).trim();
                    ensure(
                        keyText === 'Issued, with no prefix stored. Rotate it to get one.',
                        `the API key reads "${keyText}"`
                    );
                    const sessionText = (await panel.locator('.no-session').innerText()).trim();
                    ensure(
                        sessionText === 'No live session. The agent is deactivated.',
                        `the live session reads "${sessionText}"`
                    );
                } finally {
                    await admin.apex(`delete [SELECT Id FROM AgentGov_Registration__c WHERE Id = '${legacy.Id}'];`);
                }
            }
        );
    } finally {
        await browser.close();
        await admin.apex(`
            AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
            settings.Circuit_Breaker_Cooldown_Minutes__c = 1;
            settings.Session_Idle_Minutes__c = 1;
            update settings;
        `);
    }
    return suite.results;
}
