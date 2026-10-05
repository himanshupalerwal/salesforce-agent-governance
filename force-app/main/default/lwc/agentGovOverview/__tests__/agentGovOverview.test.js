import { createElement } from 'lwc';
import AgentGovOverview from 'c/agentGovOverview';
import getAgentSummaries from '@salesforce/apex/AgentGovDashboardController.getAgentSummaries';
import getActiveSessions from '@salesforce/apex/AgentGovDashboardController.getActiveSessions';
import getRecentAlerts from '@salesforce/apex/AgentGovDashboardController.getRecentAlerts';
import getTodaysActionCount from '@salesforce/apex/AgentGovDashboardController.getTodaysActionCount';
import getUsageHistory from '@salesforce/apex/AgentGovDashboardController.getUsageHistory';
import resetBreakers from '@salesforce/apex/AgentGovAdminController.resetBreakers';
import endSessions from '@salesforce/apex/AgentGovAdminController.endSessions';
import AgentGovCreditModal from 'c/agentGovCreditModal';
import LightningConfirm from 'lightning/confirm';
import { refreshApex } from '@salesforce/apex';
import { subscribe } from 'lightning/empApi';
import { getNavigateCalledWith, resetNavigation } from 'lightning/navigation';
import { ShowToastEventName } from 'lightning/platformShowToastEvent';
import { formatTime } from 'c/agentGovUtils';

jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getAgentSummaries',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getActiveSessions',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getRecentAlerts',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getTodaysActionCount',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getUsageHistory',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock('@salesforce/apex/AgentGovAdminController.resetBreakers', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/AgentGovAdminController.endSessions', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('c/agentGovCreditModal', () => ({ __esModule: true, default: { open: jest.fn() } }));

const COOLDOWN = new Date(Date.now() + 10 * 60 * 1000).toISOString();
const SUMMARIES = [
    {
        id: 'a1',
        name: 'Order Sync Agent',
        status: 'Blocked',
        breakerState: 'OPEN',
        cooldownUntil: COOLDOWN,
        failureCount: 3,
        budgetStatus: 'Normal',
        peakUsagePercent: 0.5
    },
    {
        id: 'a2',
        name: 'Lead Enrichment Agent',
        status: 'Active',
        breakerState: 'CLOSED',
        budgetStatus: 'Normal',
        peakUsagePercent: 12.4,
        liveSessionId: 's1'
    },
    {
        id: 'a3',
        name: 'Case Triage Agent',
        status: 'Active',
        breakerState: 'CLOSED',
        budgetStatus: 'Exhausted',
        peakUsagePercent: 100
    },
    { id: 'a4', name: 'Breaker Probe Agent', status: 'Active', breakerState: 'HALF_OPEN', failureCount: 1 }
];
const SESSIONS = [
    {
        Id: 's1',
        Agent_Registration__c: 'a2',
        Agent_Registration__r: { Agent_Name__c: 'Lead Enrichment Agent' },
        Session_Start__c: '2026-09-28T10:00:00.000Z',
        Last_Activity__c: '2026-09-28T10:05:00.000Z',
        Actions_Count__c: 3,
        API_Calls_Used__c: 2,
        SOQL_Queries_Used__c: 1,
        DML_Statements_Used__c: 0
    }
];
const ALERTS = [
    {
        Id: 'l1',
        CreatedDate: '2026-09-28T10:06:00.000Z',
        Timestamp__c: '2026-09-28T10:06:00.000Z',
        Agent_Registration__c: 'a1',
        Agent_Registration__r: { Agent_Name__c: 'Order Sync Agent' },
        Details__c: 'Breaker open: 3 failures reached the threshold of 3.'
    },
    { Id: 'l2', CreatedDate: '2026-09-28T09:00:00.000Z', Details__c: 'An alert that names no agent' }
];

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

function emitAll({ summaries = SUMMARIES, sessions = SESSIONS, alerts = ALERTS, actions = 42 } = {}) {
    getAgentSummaries.emit(summaries);
    getActiveSessions.emit(sessions);
    getRecentAlerts.emit(alerts);
    getTodaysActionCount.emit(actions);
    getUsageHistory.emit([]);
}

function text(node) {
    return node.textContent.replace(/\s+/g, ' ').trim();
}

describe('c-agent-gov-overview', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        refreshApex.mockImplementation(() => Promise.resolve());
        LightningConfirm.open.mockImplementation(() => Promise.resolve(true));
        resetNavigation();
    });

    // The console hosts the overview with drill-downs; on its own page it has none.
    function mount({ canDrillDown = true } = {}) {
        const element = createElement('c-agent-gov-overview', { is: AgentGovOverview });
        element.canDrillDown = canDrillDown;
        document.body.appendChild(element);
        return element;
    }

    it('shows loading placeholders, then key figures as a description list', async () => {
        const element = mount();
        expect(element.shadowRoot.querySelector('.ag-skeleton')).not.toBeNull();
        expect(element.shadowRoot.querySelector('[aria-busy="true"]')).not.toBeNull();
        emitAll();
        await flushPromises();

        const labels = Array.from(element.shadowRoot.querySelectorAll('.kpi-label')).map((node) => text(node));
        const values = Array.from(element.shadowRoot.querySelectorAll('dd.kpi-value')).map((node) => text(node));
        expect(labels).toEqual([
            'Agents',
            'Active',
            'Need attention',
            'Breakers tripped',
            'Live sessions',
            'Actions today'
        ]);
        expect(values).toEqual(['4', '3', '3', '1', '1', '42']);
        expect(element.shadowRoot.querySelector('[data-key="tripped"] dd').classList.contains('kpi-value_alert')).toBe(
            true
        );
        expect(element.shadowRoot.querySelector('[data-key="tripped"]').classList.contains('ag-kpi_alert')).toBe(true);
        expect(element.shadowRoot.querySelector('[data-key="total"]').classList.contains('ag-kpi_alert')).toBe(false);
        expect(element.shadowRoot.querySelector('.ag-skeleton')).toBeNull();
        expect(text(element.shadowRoot.querySelector('.status-line'))).toMatch(/^Updated /);
    });

    it('drills down from a key figure to the matching agent filter or tab', async () => {
        const element = mount();
        emitAll();
        await flushPromises();
        const drilldown = jest.fn();
        element.addEventListener('drilldown', drilldown);

        element.shadowRoot.querySelector('.kpi-action button[data-key="tripped"]').click();
        element.shadowRoot.querySelector('.kpi-action button[data-key="actions"]').click();
        const viewAttention = Array.from(element.shadowRoot.querySelectorAll('lightning-button')).find(
            (button) => button.label === 'Open in agent list'
        );
        viewAttention.click();

        expect(drilldown.mock.calls.map((call) => call[0].detail)).toEqual([
            { tab: 'agents', filter: 'tripped' },
            { tab: 'activity', filter: undefined },
            { tab: 'agents', filter: 'attention' }
        ]);
        // Active Sessions has no drill-down: its list is on this page.
        expect(element.shadowRoot.querySelector('.kpi-action button[data-key="sessions"]')).toBeNull();
    });

    it('lists agents that need attention, most severe first, with when an open breaker can retry', async () => {
        const element = mount();
        emitAll();
        await flushPromises();

        const rows = Array.from(element.shadowRoot.querySelectorAll('tr.attention-row'));
        expect(rows.map((row) => row.querySelector('.agent-link').textContent)).toEqual([
            'Order Sync Agent',
            'Breaker Probe Agent',
            'Case Triage Agent'
        ]);
        const [open, halfOpen, exhausted] = rows;
        expect(text(open)).toContain(`Can retry at ${formatTime(COOLDOWN)}`);
        expect(open.querySelector('.breaker-label').textContent).toBe('Open');
        expect(Array.from(open.querySelectorAll('lightning-button')).map((button) => button.label)).toEqual([
            'Reset breaker'
        ]);
        expect(text(halfOpen)).toContain('Next request is a trial');
        expect(text(halfOpen.querySelector('.budget-text'))).toBe('No usage today');
        expect(Array.from(exhausted.querySelectorAll('lightning-button')).map((button) => button.label)).toEqual([
            'Credit budget'
        ]);
        expect(exhausted.querySelector('.budget-text .ag-pill').textContent).toBe('Exhausted');
        expect(exhausted.querySelector('.budget-text .ag-pill').classList.contains('ag-pill_error')).toBe(true);
        expect(text(exhausted.querySelector('.budget-text .ag-meta'))).toBe('100% used');
        expect(open.querySelector('.breaker-label').classList.contains('ag-pill_error')).toBe(true);
        expect(text(element.shadowRoot.querySelector('.attention-card h2'))).toBe('Needs attention (3)');
    });

    it('resets a breaker after confirmation, refreshes, and returns focus to the section heading', async () => {
        const element = mount();
        emitAll();
        await flushPromises();
        const toasts = jest.fn();
        element.addEventListener(ShowToastEventName, toasts);
        resetBreakers.mockResolvedValue([{ recordId: 'a1', success: true, message: 'Circuit breaker closed.' }]);
        const recovered = SUMMARIES.map((agent) => {
            if (agent.id !== 'a1') {
                return agent;
            }
            return { ...agent, breakerState: 'CLOSED', status: 'Active', cooldownUntil: null };
        });
        refreshApex.mockImplementation(() => {
            getAgentSummaries.emit(recovered);
            return Promise.resolve();
        });
        const heading = element.shadowRoot.querySelector('.attention-card h2');
        const headingFocus = jest.spyOn(heading, 'focus');

        element.shadowRoot.querySelector('tr.attention-row .reset-button').click();
        await flushPromises();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        expect(resetBreakers).toHaveBeenCalledWith({ registrationIds: ['a1'] });
        expect(toasts.mock.calls[0][0].detail.variant).toBe('success');
        expect(refreshApex).toHaveBeenCalledTimes(4);
        expect(
            Array.from(element.shadowRoot.querySelectorAll('tr.attention-row .agent-link')).map(
                (link) => link.textContent
            )
        ).toEqual(['Breaker Probe Agent', 'Case Triage Agent']);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe(
            'Order Sync Agent: Circuit breaker closed.'
        );
        // The button that opened the confirmation is gone, so focus goes to the heading.
        expect(headingFocus).toHaveBeenCalled();
    });

    it('returns focus to the button when the confirmation is cancelled', async () => {
        LightningConfirm.open.mockResolvedValueOnce(false);
        const element = mount();
        emitAll();
        await flushPromises();
        const button = element.shadowRoot.querySelector('tr.attention-row .reset-button');
        const buttonFocus = jest.spyOn(button, 'focus');

        button.click();
        await flushPromises();

        expect(resetBreakers).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
        expect(buttonFocus).toHaveBeenCalled();
    });

    it('credits a blocked budget through the credit dialog', async () => {
        AgentGovCreditModal.open.mockResolvedValue({ success: true, message: 'Credited 10 API calls.' });
        const element = mount();
        emitAll();
        await flushPromises();

        element.shadowRoot.querySelector('.credit-button').click();
        await flushPromises();

        expect(AgentGovCreditModal.open).toHaveBeenCalledWith(expect.objectContaining({ registrationId: 'a3' }));
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe(
            'Case Triage Agent: Credited 10 API calls.'
        );
    });

    it('shows the five most severe agents that need attention and links to the rest', async () => {
        const tripped = Array.from({ length: 7 }, (_, index) => ({
            id: `t${index}`,
            name: `Tripped Agent ${index}`,
            status: 'Blocked',
            breakerState: 'OPEN',
            cooldownUntil: COOLDOWN,
            failureCount: 3
        }));
        const element = mount();
        emitAll({ summaries: tripped });
        await flushPromises();
        const drilldown = jest.fn();
        element.addEventListener('drilldown', drilldown);

        expect(element.shadowRoot.querySelectorAll('tr.attention-row').length).toBe(5);
        expect(text(element.shadowRoot.querySelector('.attention-card h2'))).toBe('Needs attention (7)');
        const more = element.shadowRoot.querySelector('.more-attention');
        expect(more.label).toBe('Show all 7 agents that need attention');
        more.click();
        expect(drilldown.mock.calls[0][0].detail).toEqual({ tab: 'agents', filter: 'attention' });
    });

    it('leaves out the controls that open another tab when it is placed on its own page', async () => {
        const tripped = Array.from({ length: 6 }, (_, index) => ({
            id: `t${index}`,
            name: `Tripped Agent ${index}`,
            status: 'Blocked',
            breakerState: 'OPEN',
            cooldownUntil: COOLDOWN,
            budgetStatus: 'Normal',
            peakUsagePercent: index
        }));
        const busy = Array.from({ length: 4 }, (_, index) => ({
            id: `b${index}`,
            name: `Busy Agent ${index}`,
            status: 'Active',
            breakerState: 'CLOSED',
            budgetStatus: 'Normal',
            peakUsagePercent: 50 + index
        }));
        const element = mount({ canDrillDown: false });
        emitAll({ summaries: [...tripped, ...busy] });
        await flushPromises();
        const root = element.shadowRoot;

        expect(root.querySelectorAll('.kpi-action').length).toBe(0);
        expect(root.querySelectorAll('.ag-kpi_action').length).toBe(0);
        expect(root.querySelector('.open-attention')).toBeNull();
        expect(root.querySelector('.more-attention')).toBeNull();
        expect(root.querySelector('.more-attention-text').textContent).toBe('And 1 more agent needs attention.');
        // Ten agents have a budget today and eight bars are shown, without a link to the rest.
        expect(root.querySelectorAll('li.usage-row').length).toBe(8);
        expect(root.querySelector('.more-usage')).toBeNull();
        // Links to an agent's own record page work anywhere.
        expect(root.querySelector('tr.attention-row .agent-link')).not.toBeNull();
    });

    it('links to the full agent list when the console hosts it and more agents have a budget than it shows', async () => {
        const busy = Array.from({ length: 9 }, (_, index) => ({
            id: `b${index}`,
            name: `Busy Agent ${index}`,
            status: 'Active',
            breakerState: 'CLOSED',
            budgetStatus: 'Normal',
            peakUsagePercent: 50 + index
        }));
        const element = mount();
        emitAll({ summaries: busy });
        await flushPromises();
        const drilldown = jest.fn();
        element.addEventListener('drilldown', drilldown);

        element.shadowRoot.querySelector('.more-usage').click();
        expect(drilldown.mock.calls[0][0].detail).toEqual({ tab: 'agents', filter: 'all' });
    });

    it('lists live sessions with the agents running them, and ends one on request', async () => {
        const element = mount();
        emitAll();
        await flushPromises();

        const card = element.shadowRoot.querySelector('section.sessions-card');
        expect(text(card.querySelector('h2'))).toBe('Live sessions (1)');
        const row = card.querySelector('tr.session-row');
        expect(row.querySelector('.agent-link').textContent).toBe('Lead Enrichment Agent');
        expect(row.querySelector('.agent-link').getAttribute('href')).toBe(
            '/lightning/r/AgentGov_Registration__c/a2/view'
        );

        endSessions.mockResolvedValue([{ recordId: 's1', success: true, message: 'Session ended.' }]);
        row.querySelector('.end-session-button').click();
        await flushPromises();
        expect(endSessions).toHaveBeenCalledWith({ sessionIds: ['s1'] });
    });

    it('keeps the live sessions card with an empty state when no session is live', async () => {
        const element = mount();
        emitAll({ sessions: [], alerts: [], summaries: [] });
        await flushPromises();

        expect(element.shadowRoot.querySelector('section.sessions-card')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.sessions-empty')).not.toBeNull();
        expect(text(element.shadowRoot.querySelector('.alerts-empty .ag-empty__text'))).toBe(
            'Alerts are raised when a budget crosses a threshold or a circuit breaker trips, while real-time events are on in AgentGov Settings.'
        );
        expect(text(element.shadowRoot.querySelector('.attention-empty .ag-empty__title'))).toBe('No agents yet');
        expect(element.shadowRoot.querySelector('.usage-empty')).not.toBeNull();
    });

    it("shows today's usage by peak and the recent alerts", async () => {
        const element = mount();
        emitAll();
        await flushPromises();

        const usage = Array.from(element.shadowRoot.querySelectorAll('li.usage-row'));
        expect(usage.map((row) => row.querySelector('.agent-link').textContent)).toEqual([
            'Case Triage Agent',
            'Lead Enrichment Agent',
            'Order Sync Agent'
        ]);
        const bar = usage[1].querySelector('[role="progressbar"]');
        expect(bar.getAttribute('aria-valuenow')).toBe('12');
        expect(bar.getAttribute('aria-label')).toBe('Lead Enrichment Agent peak budget usage today 12 percent');
        expect(text(usage[0].querySelector('.usage-status'))).toBe('100%');
        expect(usage[0].querySelector('.ag-pill').textContent).toBe('Exhausted');

        const alerts = Array.from(element.shadowRoot.querySelectorAll('li.alert-row'));
        expect(alerts.length).toBe(2);
        // An alert is shown as its label in a pill and a plain sentence.
        expect(alerts[0].querySelector('.ag-pill').textContent).toBe('Breaker open');
        expect(alerts[0].querySelector('.alert-text').textContent).toBe('3 failures reached the threshold of 3.');
        expect(alerts[0].querySelector('.agent-link').textContent).toBe('Order Sync Agent');
        expect(alerts[1].querySelector('.agent-link')).toBeNull();
    });

    it('opens an agent record page from its name', async () => {
        const element = mount();
        emitAll();
        await flushPromises();

        element.shadowRoot.querySelector('section.sessions-card .agent-link').click();

        expect(getNavigateCalledWith().pageReference).toEqual({
            type: 'standard__recordPage',
            attributes: { recordId: 'a2', objectApiName: 'AgentGov_Registration__c', actionName: 'view' }
        });
    });

    it('shows a failing source without hiding the others, and clears it when it recovers', async () => {
        const element = mount();
        getAgentSummaries.error({ message: 'No access to agents' });
        getActiveSessions.emit(SESSIONS);
        getRecentAlerts.emit(ALERTS);
        getTodaysActionCount.emit(1);
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe(
            'No access to agents'
        );
        expect(element.shadowRoot.querySelector('tr.session-row')).not.toBeNull();

        getAgentSummaries.emit(SUMMARIES);
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();
    });

    it('refreshes on request with visible feedback, the usage history included, and announces it', async () => {
        const element = mount();
        emitAll();
        await flushPromises();
        const pending = [];
        refreshApex.mockImplementation(
            () =>
                new Promise((resolve) => {
                    pending.push(resolve);
                })
        );
        const button = element.shadowRoot.querySelector('.refresh-button');

        button.click();
        await flushPromises();
        expect(button.disabled).toBe(true);
        expect(button.label).toBe('Refreshing…');
        // Four wires of its own plus the usage history's.
        expect(refreshApex).toHaveBeenCalledTimes(5);

        refreshApex.mockImplementation(() => Promise.resolve());
        pending.forEach((resolve) => resolve());
        await flushPromises();
        await flushPromises();
        expect(button.disabled).toBe(false);
        expect(button.label).toBe('Refresh');
        expect(element.shadowRoot.querySelector('.announcement').textContent).toMatch(
            /^Refreshed\. Last updated .+\.$/
        );
    });

    it('refreshes on platform events and reports a failed refresh', async () => {
        const element = mount();
        emitAll();
        await flushPromises();

        refreshApex.mockRejectedValueOnce({ body: { message: 'Refresh failed' } });
        subscribe.mock.calls[0][2]({ data: { payload: {} } });
        await flushPromises();

        expect(refreshApex).toHaveBeenCalled();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe('Refresh failed');
    });
});
