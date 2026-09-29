import { createElement } from 'lwc';
import AgentGovConsole from 'c/agentGovConsole';

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
jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getActionLogs',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getRecentConflictLogs',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGovAdminController.getSetupStatus',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-agent-gov-console', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    async function mount() {
        const element = createElement('c-agent-gov-console', { is: AgentGovConsole });
        document.body.appendChild(element);
        await flushPromises();
        return element;
    }

    function tabs(element) {
        return Array.from(element.shadowRoot.querySelectorAll('lightning-tab'));
    }

    it('says it is connecting until live updates report their state', async () => {
        const element = createElement('c-agent-gov-console', { is: AgentGovConsole });
        document.body.appendChild(element);
        expect(element.shadowRoot.querySelector('.live-status').textContent).toBe('Connecting…');
        await flushPromises();
        expect(element.shadowRoot.querySelector('.live-status').textContent).toBe('Live');
    });

    it('opens on the overview with every tab, Setup included for operators', async () => {
        const element = await mount();
        expect(element.shadowRoot.querySelector('h1').textContent).toBe('AgentGov Console');
        expect(tabs(element).map((tab) => tab.label)).toEqual(['Overview', 'Agents', 'Activity', 'Conflicts', 'Setup']);
        expect(element.shadowRoot.querySelector('lightning-tabset').activeTabValue).toBe('overview');
        expect(element.shadowRoot.querySelector('c-agent-gov-setup-status')).not.toBeNull();
        const live = element.shadowRoot.querySelector('.live-status');
        expect(live.textContent).toBe('Live');
        expect(live.classList.contains('ag-live_on')).toBe(true);
    });

    it('opens the agent list with the filter a key figure names, and moves focus there', async () => {
        const element = await mount();
        const overview = element.shadowRoot.querySelector('c-agent-gov-overview');
        const list = element.shadowRoot.querySelector('c-agent-gov-agent-list');

        overview.dispatchEvent(new CustomEvent('drilldown', { detail: { tab: 'agents', filter: 'tripped' } }));
        await flushPromises();

        expect(element.shadowRoot.querySelector('lightning-tabset').activeTabValue).toBe('agents');
        expect(list.filter).toBe('tripped');
        expect(list.focusRequest).toBe(1);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe(
            'Agents tab, showing agents with a tripped circuit breaker.'
        );

        overview.dispatchEvent(new CustomEvent('drilldown', { detail: { tab: 'agents', filter: 'nonsense' } }));
        await flushPromises();
        expect(list.filter).toBe('all');
        expect(list.focusRequest).toBe(2);
    });

    it('opens the activity tab, and ignores an unknown tab', async () => {
        const element = await mount();
        const overview = element.shadowRoot.querySelector('c-agent-gov-overview');

        overview.dispatchEvent(new CustomEvent('drilldown', { detail: { tab: 'activity' } }));
        await flushPromises();
        expect(element.shadowRoot.querySelector('lightning-tabset').activeTabValue).toBe('activity');
        expect(element.shadowRoot.querySelector('c-agent-gov-activity-log').focusRequest).toBe(1);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe('Activity tab.');

        overview.dispatchEvent(new CustomEvent('drilldown', { detail: { tab: 'elsewhere' } }));
        overview.dispatchEvent(new CustomEvent('drilldown'));
        await flushPromises();
        expect(element.shadowRoot.querySelector('lightning-tabset').activeTabValue).toBe('activity');

        overview.dispatchEvent(new CustomEvent('drilldown', { detail: { tab: 'conflicts' } }));
        await flushPromises();
        expect(element.shadowRoot.querySelector('lightning-tabset').activeTabValue).toBe('conflicts');
    });

    it('follows the tab the person selects and the filter they choose in the list', async () => {
        const element = await mount();
        const agentsTab = tabs(element)[1];
        agentsTab.dispatchEvent(new CustomEvent('active'));
        await flushPromises();
        expect(element.shadowRoot.querySelector('lightning-tabset').activeTabValue).toBe('agents');

        const list = element.shadowRoot.querySelector('c-agent-gov-agent-list');
        list.dispatchEvent(new CustomEvent('filterchange', { detail: { filter: 'inactive' } }));
        await flushPromises();
        expect(list.filter).toBe('inactive');
    });
});
