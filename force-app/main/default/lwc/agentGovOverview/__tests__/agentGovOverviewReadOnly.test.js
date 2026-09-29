import { createElement } from 'lwc';
import AgentGovOverview from 'c/agentGovOverview';
import getAgentSummaries from '@salesforce/apex/AgentGovDashboardController.getAgentSummaries';
import getActiveSessions from '@salesforce/apex/AgentGovDashboardController.getActiveSessions';
import getRecentAlerts from '@salesforce/apex/AgentGovDashboardController.getRecentAlerts';
import getTodaysActionCount from '@salesforce/apex/AgentGovDashboardController.getTodaysActionCount';

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

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-agent-gov-overview without AgentGov_Operate_Agents', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows the same information but no controls that change agents', async () => {
        const element = createElement('c-agent-gov-overview', { is: AgentGovOverview });
        document.body.appendChild(element);
        getAgentSummaries.emit([
            { id: 'a1', name: 'Order Sync Agent', status: 'Blocked', breakerState: 'OPEN' },
            { id: 'a3', name: 'Case Triage Agent', status: 'Active', budgetStatus: 'Blocked', peakUsagePercent: 96 }
        ]);
        getActiveSessions.emit([
            { Id: 's1', Agent_Registration__c: 'a3', Agent_Registration__r: { Agent_Name__c: 'Case Triage Agent' } }
        ]);
        getRecentAlerts.emit([]);
        getTodaysActionCount.emit(0);
        await flushPromises();

        expect(element.shadowRoot.querySelectorAll('tr.attention-row').length).toBe(2);
        expect(element.shadowRoot.querySelector('.reset-button')).toBeNull();
        expect(element.shadowRoot.querySelector('.credit-button')).toBeNull();
        expect(element.shadowRoot.querySelector('tr.session-row')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.end-session-button')).toBeNull();
    });
});
