import { createElement } from 'lwc';
import AgentHealthMonitor from 'c/agentHealthMonitor';
import getAllRegistrations from '@salesforce/apex/AgentGovSelector.getAllRegistrations';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovSelector.getAllTodaysBudgets';

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

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('c-agent-health-monitor', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders component without errors', async () => {
        getAllRegistrations.mockResolvedValue([
            {
                Id: '1',
                Agent_Name__c: 'Test Agent',
                Agent_Type__c: 'Agentforce',
                Status__c: 'Active',
                Circuit_Breaker_State__c: 'CLOSED',
                Priority__c: 1,
                Failure_Count__c: 0
            }
        ]);
        getAllTodaysBudgets.mockResolvedValue([]);

        const element = createElement('c-agent-health-monitor', { is: AgentHealthMonitor });
        document.body.appendChild(element);

        await flushPromises();

        const card = element.shadowRoot.querySelector('lightning-card');
        expect(card).toBeTruthy();
    });

    it('shows loading spinner initially', () => {
        getAllRegistrations.mockResolvedValue([]);
        getAllTodaysBudgets.mockResolvedValue([]);

        const element = createElement('c-agent-health-monitor', { is: AgentHealthMonitor });
        document.body.appendChild(element);

        const spinner = element.shadowRoot.querySelector('lightning-spinner');
        expect(spinner).toBeTruthy();
    });
});
