import { createElement } from 'lwc';
import AgentBudgetAllocation from 'c/agentBudgetAllocation';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovDashboardController.getAllTodaysBudgets';
import { refreshApex } from '@salesforce/apex';

jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getAllTodaysBudgets',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const BUDGETS = [
    {
        Id: 'b1',
        Agent_Registration__c: 'a1',
        Agent_Registration__r: { Agent_Name__c: 'Test Agent' },
        API_Calls_Allocated__c: 10000,
        API_Calls_Consumed__c: 5000,
        SOQL_Queries_Allocated__c: 5000,
        SOQL_Queries_Consumed__c: 4500,
        DML_Operations_Allocated__c: 3000,
        DML_Operations_Consumed__c: 2100,
        Budget_Status__c: 'Throttled'
    },
    {
        Id: 'b2',
        Agent_Registration__c: 'a2',
        Agent_Registration__r: { Agent_Name__c: 'Idle Agent' },
        API_Calls_Allocated__c: 100,
        API_Calls_Consumed__c: 0,
        SOQL_Queries_Allocated__c: 100,
        SOQL_Queries_Consumed__c: 0,
        DML_Operations_Allocated__c: 100,
        DML_Operations_Consumed__c: 0,
        Budget_Status__c: 'Normal'
    }
];

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-agent-budget-allocation', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function mount() {
        const element = createElement('c-agent-budget-allocation', { is: AgentBudgetAllocation });
        document.body.appendChild(element);
        return element;
    }

    it('computes totals, per-limit usage, and bar levels', async () => {
        const element = mount();
        getAllTodaysBudgets.emit(BUDGETS);
        await flushPromises();

        expect(element.shadowRoot.querySelector('.total-api').textContent).toBe('10100');
        expect(element.shadowRoot.querySelector('.total-soql').textContent).toBe('5100');
        expect(element.shadowRoot.querySelector('.total-dml').textContent).toBe('3100');

        const cards = element.shadowRoot.querySelectorAll('.budget-card');
        expect(cards.length).toBe(2);
        expect(cards[0].querySelector('.usage-api').textContent).toBe('5000 / 10000 (50%)');
        expect(cards[0].querySelector('.usage-soql').textContent).toBe('4500 / 5000 (90%)');
        expect(cards[0].querySelector('.usage-dml').textContent).toBe('2100 / 3000 (70%)');
        const bars = cards[0].querySelectorAll('.progress-fill');
        expect(bars[0].classList.contains('bar-normal')).toBe(true);
        expect(bars[1].classList.contains('bar-warning')).toBe(true);
        expect(bars[2].classList.contains('bar-normal')).toBe(true);
        expect(bars[1].style.width).toBe('90%');
        expect(cards[0].querySelector('[role="progressbar"]').getAttribute('aria-label')).toBe(
            'Test Agent API calls 50 percent used'
        );
        expect(cards[0].querySelector('lightning-icon').iconName).toBe('utility:error');
        expect(cards[1].querySelector('lightning-icon').iconName).toBe('utility:success');
    });

    it('shows the empty state and errors', async () => {
        const element = mount();
        getAllTodaysBudgets.emit([]);
        await flushPromises();
        expect(element.shadowRoot.querySelector('.empty-state')).not.toBeNull();

        getAllTodaysBudgets.error({ message: 'Offline' });
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('Offline');
    });

    it('refreshes the wire on click and reports a failed refresh', async () => {
        const element = mount();
        getAllTodaysBudgets.emit(BUDGETS);
        await flushPromises();
        const button = element.shadowRoot.querySelector('lightning-button');

        button.click();
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(1);

        refreshApex.mockRejectedValueOnce(new Error('Refresh failed'));
        button.click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('Refresh failed');
    });

    it('coalesces overlapping refreshes', async () => {
        const element = mount();
        getAllTodaysBudgets.emit(BUDGETS);
        await flushPromises();
        let release;
        const gate = new Promise((resolve) => {
            release = resolve;
        });
        refreshApex.mockImplementation(() => gate);
        const button = element.shadowRoot.querySelector('lightning-button');

        button.click();
        button.click();
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(1);
        refreshApex.mockImplementation(() => Promise.resolve());
        release();
        await flushPromises();
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(2);
    });
});
