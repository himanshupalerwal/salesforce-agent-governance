import { createElement } from 'lwc';
import AgentGovConsole from 'c/agentGovConsole';

jest.mock('@salesforce/customPermission/AgentGov_Operate_Agents', () => ({ default: undefined }));
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

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-agent-gov-console without AgentGov_Operate_Agents', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('leaves out the Setup tab and refuses to open it by drill-down', async () => {
        const element = createElement('c-agent-gov-console', { is: AgentGovConsole });
        document.body.appendChild(element);
        await flushPromises();

        const labels = Array.from(element.shadowRoot.querySelectorAll('lightning-tab')).map((tab) => tab.label);
        expect(labels).toEqual(['Overview', 'Agents', 'Activity', 'Conflicts']);
        expect(element.shadowRoot.querySelector('c-agent-gov-setup-status')).toBeNull();

        element.shadowRoot
            .querySelector('c-agent-gov-overview')
            .dispatchEvent(new CustomEvent('drilldown', { detail: { tab: 'setup' } }));
        await flushPromises();
        expect(element.shadowRoot.querySelector('lightning-tabset').activeTabValue).toBe('overview');
    });
});
