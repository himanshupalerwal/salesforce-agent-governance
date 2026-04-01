import { createElement } from 'lwc';
import AgentGovDashboard from 'c/agentGovDashboard';
import getAllRegistrations from '@salesforce/apex/AgentGovSelector.getAllRegistrations';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovSelector.getAllTodaysBudgets';
import getRecentConflictLogs from '@salesforce/apex/AgentGovSelector.getRecentConflictLogs';

jest.mock(
    '@salesforce/apex/AgentGovSelector.getAllRegistrations',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGovSelector.getAllTodaysBudgets',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGovSelector.getRecentConflictLogs',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('c-agent-gov-dashboard', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders component', async () => {
        getAllRegistrations.mockResolvedValue([
            { Id: '1', Agent_Name__c: 'Agent 1', Status__c: 'Active' },
            { Id: '2', Agent_Name__c: 'Agent 2', Status__c: 'Inactive' }
        ]);
        getAllTodaysBudgets.mockResolvedValue([]);
        getRecentConflictLogs.mockResolvedValue([]);

        const element = createElement('c-agent-gov-dashboard', { is: AgentGovDashboard });
        document.body.appendChild(element);

        await flushPromises();

        const title = element.shadowRoot.querySelector('.slds-page-header__title');
        expect(title).toBeTruthy();
        expect(title.textContent).toBe('AgentGov Dashboard');
    });

    it('shows loading spinner initially', () => {
        getAllRegistrations.mockResolvedValue([]);
        getAllTodaysBudgets.mockResolvedValue([]);
        getRecentConflictLogs.mockResolvedValue([]);

        const element = createElement('c-agent-gov-dashboard', { is: AgentGovDashboard });
        document.body.appendChild(element);

        const spinner = element.shadowRoot.querySelector('lightning-spinner');
        expect(spinner).toBeTruthy();
    });

    it('handles error gracefully', async () => {
        getAllRegistrations.mockRejectedValue(new Error('Test error'));
        getAllTodaysBudgets.mockResolvedValue([]);
        getRecentConflictLogs.mockResolvedValue([]);

        const element = createElement('c-agent-gov-dashboard', { is: AgentGovDashboard });
        document.body.appendChild(element);

        await flushPromises();

        const errorEl = element.shadowRoot.querySelector('.slds-notify_alert');
        expect(errorEl).toBeTruthy();
    });
});
