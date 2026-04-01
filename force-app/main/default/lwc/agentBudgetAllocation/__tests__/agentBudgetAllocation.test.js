import { createElement } from 'lwc';
import AgentBudgetAllocation from 'c/agentBudgetAllocation';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovSelector.getAllTodaysBudgets';

jest.mock(
    '@salesforce/apex/AgentGovSelector.getAllTodaysBudgets',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

describe('c-agent-budget-allocation', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders budget cards', async () => {
        getAllTodaysBudgets.mockResolvedValue([
            {
                Id: '1',
                Agent_Registration__c: 'a00001',
                Agent_Registration__r: { Agent_Name__c: 'Test Agent' },
                API_Calls_Allocated__c: 10000,
                API_Calls_Consumed__c: 5000,
                SOQL_Queries_Allocated__c: 5000,
                SOQL_Queries_Consumed__c: 2500,
                DML_Operations_Allocated__c: 3000,
                DML_Operations_Consumed__c: 1500,
                Budget_Status__c: 'Normal'
            }
        ]);

        const element = createElement('c-agent-budget-allocation', { is: AgentBudgetAllocation });
        document.body.appendChild(element);

        await Promise.resolve();
        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('.budget-card');
        expect(cards.length).toBe(1);
    });

    it('shows empty state', async () => {
        getAllTodaysBudgets.mockResolvedValue([]);

        const element = createElement('c-agent-budget-allocation', { is: AgentBudgetAllocation });
        document.body.appendChild(element);

        await Promise.resolve();
        await Promise.resolve();

        const emptyMsg = element.shadowRoot.querySelector('.slds-text-align_center');
        expect(emptyMsg).toBeTruthy();
    });
});
