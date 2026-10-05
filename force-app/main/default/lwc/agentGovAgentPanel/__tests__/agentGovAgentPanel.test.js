import { createElement } from 'lwc';
import AgentGovAgentPanel from 'c/agentGovAgentPanel';
import getAgentSummary from '@salesforce/apex/AgentGovDashboardController.getAgentSummary';
import getActionLogs from '@salesforce/apex/AgentGovDashboardController.getActionLogs';
import getUsageHistory from '@salesforce/apex/AgentGovDashboardController.getUsageHistory';
import resetBreakers from '@salesforce/apex/AgentGovAdminController.resetBreakers';
import LightningConfirm from 'lightning/confirm';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { registerRefreshHandler, unregisterRefreshHandler } from 'lightning/refresh';
import { subscribe } from 'lightning/empApi';
import { getNavigateCalledWith, resetNavigation } from 'lightning/navigation';
import { formatTime } from 'c/agentGovUtils';

jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getAgentSummary',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getActionLogs',
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

const COOLDOWN = new Date(Date.now() + 10 * 60 * 1000).toISOString();
const TRIPPED = {
    id: 'a1',
    name: 'Order Sync Agent',
    status: 'Blocked',
    breakerState: 'OPEN',
    cooldownUntil: COOLDOWN,
    failureCount: 3,
    budgetStatus: 'Warning',
    peakUsagePercent: 85,
    apiUsagePercent: 85,
    soqlUsagePercent: 12.5,
    dmlUsagePercent: 0,
    liveSessionId: 's1',
    sessionActions: 7,
    apiKeyPrefix: 'agk_01234567',
    apiKeyLastRotated: '2026-09-20T09:00:00.000Z',
    boundToUser: true,
    agentType: 'MCP_External',
    priority: 4,
    lastActive: new Date(Date.now() - 5 * 60 * 1000).toISOString()
};

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

function text(node) {
    return node.textContent.replace(/\s+/g, ' ').trim();
}

describe('c-agent-gov-agent-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        refreshApex.mockImplementation(() => Promise.resolve());
        LightningConfirm.open.mockImplementation(() => Promise.resolve(true));
        resetNavigation();
    });

    async function mount(summary = TRIPPED) {
        const element = createElement('c-agent-gov-agent-panel', { is: AgentGovAgentPanel });
        element.recordId = 'a1';
        document.body.appendChild(element);
        await flushPromises();
        expect(getAgentSummary.getLastConfig()).toEqual({ registrationId: 'a1' });
        getAgentSummary.emit(summary);
        getActionLogs.emit({ rows: [], hasMore: false });
        getUsageHistory.emit([]);
        await flushPromises();
        return element;
    }

    it("shows the agent's breaker, usage, session, and credentials", async () => {
        const element = await mount();
        const root = element.shadowRoot;

        expect(root.querySelector('.status-pill').textContent).toBe('Blocked');
        expect(root.querySelector('.status-pill').classList.contains('ag-pill_error')).toBe(true);
        expect(root.querySelector('.breaker-label').textContent).toBe('Open');
        expect(root.querySelector('.breaker-detail').textContent).toBe(`Can retry at ${formatTime(COOLDOWN)}`);
        expect(root.querySelector('.failure-count').textContent).toBe('3');
        expect(text(root.querySelector('.budget-status'))).toBe('Warning, peak 85% of the daily allocation');
        const bars = Array.from(root.querySelectorAll('.usage-bar [role="progressbar"]'));
        expect(bars.map((bar) => bar.getAttribute('aria-valuenow'))).toEqual(['85', '13', '0']);
        expect(bars[0].getAttribute('aria-label')).toBe("API calls: 85 percent of today's allocation used");
        expect(text(root.querySelector('.live-session'))).toBe('Open the live session, 7 actions so far.');
        expect(root.querySelector('.key-prefix').textContent).toBe('agk_01234567…');
        expect(root.querySelector('.key-rotated').textContent).not.toBe('Never');
        expect(root.querySelector('.bound-user').textContent).toBe('Yes');

        root.querySelector('.live-session a').click();
        expect(getNavigateCalledWith().pageReference.attributes).toEqual({
            recordId: 's1',
            objectApiName: 'AgentGov_Session__c',
            actionName: 'view'
        });
    });

    it('names the agent in its header, with its state as pills', async () => {
        const element = await mount();
        const root = element.shadowRoot;

        expect(text(root.querySelector('.panel-heading'))).toBe('Order Sync Agent');
        expect(text(root.querySelector('.panel-subtitle'))).toBe('MCP External · Priority 4 · Active 5 minutes ago');
        const pills = Array.from(root.querySelectorAll('.state-strip .ag-pill')).map((pill) => text(pill));
        expect(pills).toEqual(['Blocked', 'Breaker open', 'Budget warning', 'Session live']);
    });

    it('embeds the recent activity and usage history of the same agent', async () => {
        const element = await mount();
        const activity = element.shadowRoot.querySelector('c-agent-gov-activity-log');
        const history = element.shadowRoot.querySelector('c-agent-gov-usage-history');
        expect(activity.recordId).toBe('a1');
        expect(history.recordId).toBe('a1');
        expect(activity.shadowRoot.querySelector('.log-heading').textContent).toBe('Recent activity');
        expect(getActionLogs.getLastConfig().registrationId).toBe('a1');
        expect(getUsageHistory.getLastConfig().registrationId).toBe('a1');
    });

    it('offers the actions that fit the state, most urgent first', async () => {
        const element = await mount();
        const buttons = Array.from(element.shadowRoot.querySelectorAll('.action-button'));
        expect(buttons.map((button) => button.label)).toEqual([
            'Reset breaker',
            'Activate',
            'Deactivate',
            'Credit budget',
            'Rotate key',
            'End session'
        ]);
        expect(buttons[0].variant).toBe('brand');
        expect(buttons[1].variant).toBe('neutral');
    });

    it('resets the breaker, reloads the page data, and returns focus to the button', async () => {
        const element = await mount();
        resetBreakers.mockResolvedValue([{ recordId: 'a1', success: true, message: 'Circuit breaker closed.' }]);
        const button = element.shadowRoot.querySelector('.action-button[data-action="reset"]');
        const buttonFocus = jest.spyOn(button, 'focus');

        button.click();
        await flushPromises();
        await flushPromises();

        expect(resetBreakers).toHaveBeenCalledWith({ registrationIds: ['a1'] });
        // The summary, the activity log, and the usage history.
        expect(refreshApex).toHaveBeenCalledTimes(3);
        expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([{ recordId: 'a1' }]);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe(
            'Order Sync Agent: Circuit breaker closed.'
        );
        expect(buttonFocus).toHaveBeenCalled();
    });

    it('does not reload anything when the action is cancelled', async () => {
        LightningConfirm.open.mockResolvedValueOnce(false);
        const element = await mount();
        element.shadowRoot.querySelector('.action-button[data-action="reset"]').click();
        await flushPromises();
        expect(resetBreakers).not.toHaveBeenCalled();
        expect(notifyRecordUpdateAvailable).not.toHaveBeenCalled();
    });

    it('says plainly when there is no usage, session, or key', async () => {
        const element = await mount({
            id: 'a1',
            name: 'Quiet Agent',
            status: 'Inactive',
            breakerState: 'CLOSED',
            boundToUser: false
        });
        const root = element.shadowRoot;
        expect(root.querySelector('.breaker-detail')).toBeNull();
        expect(root.querySelector('.no-budget').textContent).toBe('No usage recorded today.');
        // A deactivated agent is refused before anything opens a session.
        expect(root.querySelector('.no-session').textContent).toBe('No live session. The agent is deactivated.');
        expect(root.querySelector('.key-prefix').textContent).toBe('No key issued');
        expect(root.querySelector('.key-rotated').textContent).toBe('Never');
        expect(root.querySelector('.bound-user').textContent).toBe('No');
        expect(root.querySelector('.failure-count').textContent).toBe('0');
    });

    it('shows a key with no stored prefix as issued, and counts one action in the singular', async () => {
        const element = await mount({
            ...TRIPPED,
            apiKeyPrefix: null,
            hasApiKey: true,
            sessionActions: 1
        });
        const root = element.shadowRoot;
        expect(root.querySelector('.key-prefix').textContent).toBe(
            'Issued, with no prefix stored. Rotate it to get one.'
        );
        expect(text(root.querySelector('.live-session'))).toBe('Open the live session, 1 action so far.');
    });

    it('says the next governed action opens a session for an agent that is not deactivated', async () => {
        const element = await mount({
            id: 'a1',
            name: 'Quiet Agent',
            status: 'Active',
            breakerState: 'CLOSED',
            hasApiKey: false
        });
        expect(element.shadowRoot.querySelector('.no-session').textContent).toBe(
            "No live session. The agent's next governed action opens one."
        );
        expect(element.shadowRoot.querySelector('.key-prefix').textContent).toBe('No key issued');
    });

    it('explains an agent it cannot load, and shows a load error', async () => {
        const element = await mount(null);
        expect(element.shadowRoot.querySelector('.not-found')).not.toBeNull();

        getAgentSummary.error({ message: 'No access to agents' });
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe(
            'No access to agents'
        );
    });

    it('refreshes on request, on page refresh, and on platform events', async () => {
        const element = await mount();
        expect(registerRefreshHandler).toHaveBeenCalledTimes(1);

        element.shadowRoot.querySelector('.refresh-button').click();
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(3);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toMatch(/^Refreshed\./);

        const pageRefresh = registerRefreshHandler.mock.calls[0][1];
        await expect(pageRefresh.call(element)).resolves.toBe(true);

        refreshApex.mockClear();
        subscribe.mock.calls[0][2]({ data: {} });
        await flushPromises();
        // The panel refreshes its summary; the embedded components refresh themselves.
        expect(refreshApex).toHaveBeenCalledTimes(3);

        refreshApex.mockRejectedValueOnce({ body: { message: 'Refresh failed' } });
        element.shadowRoot.querySelector('.refresh-button').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe('Refresh failed');

        document.body.removeChild(element);
        expect(unregisterRefreshHandler).toHaveBeenCalledTimes(1);
    });
});
