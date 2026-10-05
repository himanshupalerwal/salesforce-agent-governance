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

const pillVariantOf = (pill) => Array.from(pill.classList).find((name) => name.startsWith('ag-pill_'));

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

        // Figures are grouped in the viewer's locale, en-US under Jest.
        expect(element.shadowRoot.querySelector('.total-api').textContent).toBe('10,100');
        expect(element.shadowRoot.querySelector('.total-soql').textContent).toBe('5,100');
        expect(element.shadowRoot.querySelector('.total-dml').textContent).toBe('3,100');

        const cards = element.shadowRoot.querySelectorAll('.budget-card');
        expect(cards.length).toBe(2);
        expect(cards[0].querySelector('.usage-api').textContent).toBe('5,000 / 10,000 (50%)');
        expect(cards[0].querySelector('.usage-soql').textContent).toBe('4,500 / 5,000 (90%)');
        expect(cards[0].querySelector('.usage-dml').textContent).toBe('2,100 / 3,000 (70%)');
        const bars = cards[0].querySelectorAll('.progress-fill');
        expect(bars[0].classList.contains('ag-bar_normal')).toBe(true);
        expect(bars[1].classList.contains('ag-bar_warning')).toBe(true);
        expect(bars[2].classList.contains('ag-bar_normal')).toBe(true);
        expect(bars[1].style.width).toBe('90%');
        expect(cards[0].querySelector('[role="progressbar"]').getAttribute('aria-label')).toBe(
            'Test Agent API calls 50 percent used'
        );
        // Throttled is a warning; it used to fall through to the error presentation.
        expect(pillVariantOf(cards[0].querySelector('.status-label'))).toBe('ag-pill_warning');
        expect(pillVariantOf(cards[1].querySelector('.status-label'))).toBe('ag-pill_success');
        expect(cards[0].querySelector('.budget-status .slds-assistive-text').textContent).toBe('Budget status');
    });

    it('shows the empty state and errors', async () => {
        const element = mount();
        expect(element.shadowRoot.querySelector('[aria-busy="true"] .ag-skeleton')).not.toBeNull();
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
    it('shows every budget status as a pill of its severity, and anything else as a neutral one', async () => {
        const element = mount();
        const statuses = ['Normal', 'Warning', 'Throttled', 'Blocked', 'Exhausted', 'Bypassed'];
        getAllTodaysBudgets.emit(
            statuses.map((status, index) => ({
                ...BUDGETS[1],
                Id: `b${index}`,
                Budget_Status__c: status
            }))
        );
        await flushPromises();

        const pills = Array.from(element.shadowRoot.querySelectorAll('.budget-card')).map((card) =>
            card.querySelector('.status-label')
        );
        expect(pills.map(pillVariantOf)).toEqual([
            'ag-pill_success',
            'ag-pill_warning',
            'ag-pill_warning',
            'ag-pill_error',
            'ag-pill_error',
            'ag-pill_neutral'
        ]);
        // The status is written out as well, so it does not depend on the pill's colour.
        expect(pills.map((pill) => pill.textContent)).toEqual(statuses);
    });

    it('puts the three totals in the shared responsive tile grid', async () => {
        const element = mount();
        getAllTodaysBudgets.emit(BUDGETS);
        await flushPromises();

        // The shared tile grid fits as many columns as the width allows, down to one.
        ['.total-api', '.total-soql', '.total-dml'].forEach((selector) => {
            const tile = element.shadowRoot.querySelector(selector).parentElement;
            expect(tile.classList.contains('ag-kpi')).toBe(true);
            expect(tile.parentElement.classList.contains('ag-kpi-grid')).toBe(true);
        });
    });

    it('shows refresh progress and links agents to their records', async () => {
        const element = mount();
        getAllTodaysBudgets.emit(BUDGETS);
        await flushPromises();
        expect(element.shadowRoot.querySelector('.budget-card h3 a').getAttribute('href')).toBe(
            '/lightning/r/AgentGov_Registration__c/a1/view'
        );

        const pending = [];
        refreshApex.mockImplementation(() => new Promise((resolve) => pending.push(resolve)));
        const button = element.shadowRoot.querySelector('lightning-button');
        button.click();
        await flushPromises();
        expect(button.disabled).toBe(true);
        refreshApex.mockImplementation(() => Promise.resolve());
        pending.forEach((resolve) => resolve());
        await flushPromises();
        expect(button.label).toBe('Refresh');
        expect(element.shadowRoot.querySelector('.announcement').textContent).toMatch(/^Refreshed\./);
    });
});
