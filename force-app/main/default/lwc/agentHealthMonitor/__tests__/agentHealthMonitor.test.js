import { createElement } from 'lwc';
import AgentHealthMonitor from 'c/agentHealthMonitor';
import getAllRegistrations from '@salesforce/apex/AgentGovDashboardController.getAllRegistrations';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovDashboardController.getAllTodaysBudgets';
import { refreshApex } from '@salesforce/apex';
import { subscribe } from 'lightning/empApi';

jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getAllRegistrations',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getAllTodaysBudgets',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const REGISTRATIONS = [
    {
        Id: 'a1',
        Agent_Name__c: 'Healthy Agent',
        Agent_Type__c: 'Agentforce',
        Status__c: 'Active',
        Circuit_Breaker_State__c: 'CLOSED',
        Priority__c: 1,
        Failure_Count__c: 0,
        Last_Active__c: '2026-09-15T10:00:00.000Z'
    },
    {
        Id: 'a2',
        Agent_Name__c: 'Tripped Agent',
        Agent_Type__c: 'Custom_Apex',
        Status__c: 'Blocked',
        Circuit_Breaker_State__c: 'OPEN',
        Priority__c: 5,
        Failure_Count__c: 4
    }
];
const BUDGETS = [
    {
        Id: 'b1',
        Agent_Registration__c: 'a1',
        API_Calls_Allocated__c: 100,
        API_Calls_Consumed__c: 90,
        SOQL_Queries_Allocated__c: 100,
        SOQL_Queries_Consumed__c: 90,
        DML_Operations_Allocated__c: 100,
        DML_Operations_Consumed__c: 90
    }
];

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-agent-health-monitor', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function mount() {
        const element = createElement('c-agent-health-monitor', { is: AgentHealthMonitor });
        document.body.appendChild(element);
        return element;
    }

    it('renders one card per agent with breaker state, budget bar, and failures', async () => {
        const element = mount();
        expect(element.shadowRoot.querySelector('lightning-spinner')).not.toBeNull();

        getAllRegistrations.emit(REGISTRATIONS);
        getAllTodaysBudgets.emit(BUDGETS);
        await flushPromises();

        const cards = element.shadowRoot.querySelectorAll('.agent-card');
        expect(cards.length).toBe(2);
        expect(cards[0].querySelector('.breaker-state').textContent).toBe('CLOSED');
        const bar = cards[0].querySelector('[role="progressbar"]');
        expect(bar.getAttribute('aria-valuenow')).toBe('90');
        expect(bar.querySelector('.progress-bar').classList.contains('bar-warning')).toBe(true);
        expect(cards[0].querySelector('.failure-count')).toBeNull();
        expect(cards[1].querySelector('.failure-count').textContent.trim()).toBe('Failures: 4');
        expect(cards[1].querySelector('lightning-icon').alternativeText).toBe('Circuit breaker OPEN');
        expect(cards[1].querySelector('lightning-icon').variant).toBe('error');
        expect(cards[0].querySelector('lightning-icon').variant).toBe('success');
        expect(cards[1].querySelector('.slds-theme_error').textContent).toBe('Blocked');
    });

    it('shows the empty state and the error message', async () => {
        const element = mount();
        getAllRegistrations.emit([]);
        getAllTodaysBudgets.emit([]);
        await flushPromises();
        expect(element.shadowRoot.querySelector('.empty-state')).not.toBeNull();

        getAllRegistrations.error({ message: 'No access' });
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('No access');
    });

    it('refreshes both wires on click and on platform events', async () => {
        const element = mount();
        getAllRegistrations.emit(REGISTRATIONS);
        getAllTodaysBudgets.emit(BUDGETS);
        await flushPromises();

        element.shadowRoot.querySelector('lightning-button').click();
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(2);

        subscribe.mock.calls[0][2]({ data: {} });
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(4);
    });

    it('coalesces overlapping refreshes and surfaces refresh failures', async () => {
        const element = mount();
        getAllRegistrations.emit(REGISTRATIONS);
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
        expect(refreshApex).toHaveBeenCalledTimes(2);
        refreshApex.mockImplementation(() => Promise.resolve());
        release();
        await flushPromises();
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(4);

        refreshApex.mockRejectedValueOnce(new Error('Refresh failed'));
        button.click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('Refresh failed');
    });

    it('tolerates a failed subscription', async () => {
        subscribe.mockRejectedValueOnce(new Error('streaming unavailable'));
        const element = mount();
        getAllRegistrations.emit([]);
        getAllTodaysBudgets.emit([]);
        await flushPromises();

        expect(element.shadowRoot.querySelector('.empty-state')).not.toBeNull();
    });
});
