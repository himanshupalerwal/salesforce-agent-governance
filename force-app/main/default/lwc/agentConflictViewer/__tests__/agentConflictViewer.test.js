import { createElement } from 'lwc';
import AgentConflictViewer from 'c/agentConflictViewer';
import getRecentConflictLogs from '@salesforce/apex/AgentGovDashboardController.getRecentConflictLogs';
import { refreshApex } from '@salesforce/apex';
import { subscribe } from 'lightning/empApi';

jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getRecentConflictLogs',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const CONFLICTS = [
    {
        Id: 'c1',
        Agent_1__r: { Agent_Name__c: 'Agent A' },
        Agent_2__r: { Agent_Name__c: 'Agent B' },
        Object_Name__c: 'Account',
        Conflict_Type__c: 'Concurrent_Write',
        Resolution__c: 'Agent1_Won',
        Severity__c: 'High',
        Timestamp__c: '2026-09-15T10:00:00.000Z'
    },
    {
        Id: 'c2',
        Object_Name__c: 'Case',
        Conflict_Type__c: 'Lock_Contention',
        Resolution__c: 'Queued',
        Severity__c: 'Low',
        Timestamp__c: null
    }
];

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-agent-conflict-viewer', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function mount() {
        const element = createElement('c-agent-conflict-viewer', { is: AgentConflictViewer });
        document.body.appendChild(element);
        return element;
    }

    it('maps conflicts into datatable rows with agent names and severity styling', async () => {
        const element = mount();
        getRecentConflictLogs.emit(CONFLICTS);
        await flushPromises();

        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        expect(datatable.data.length).toBe(2);
        expect(datatable.data[0].agent1Name).toBe('Agent A');
        expect(datatable.data[0].severityCellClass).toBe('slds-text-color_error');
        expect(datatable.data[1].agent1Name).toBe('Unknown');
        expect(datatable.data[1].formattedTime).toBe('');
        expect(datatable.data[1].severityCellClass).toBe('');
        expect(element.shadowRoot.querySelector('.conflict-count').textContent).toBe('2');
        expect(datatable.data[0].typeLabel).toBe('Concurrent write');
        expect(datatable.data[0].outcome).toBe('Agent A went ahead');
        expect(datatable.showRowNumberColumn).toBeFalsy();
    });

    it('shows the empty state and errors', async () => {
        const element = mount();
        getRecentConflictLogs.emit([]);
        await flushPromises();
        expect(element.shadowRoot.querySelector('.empty-state')).not.toBeNull();

        getRecentConflictLogs.error([{ message: 'first' }, { message: 'second' }]);
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('first. second');
    });

    it('refreshes on platform events', async () => {
        mount();
        getRecentConflictLogs.emit(CONFLICTS);
        await flushPromises();

        subscribe.mock.calls[0][2]({ data: {} });
        await flushPromises();

        expect(refreshApex).toHaveBeenCalledTimes(1);
    });

    it('coalesces overlapping refreshes and reports a failed refresh', async () => {
        const element = mount();
        getRecentConflictLogs.emit(CONFLICTS);
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

        refreshApex.mockRejectedValueOnce(new Error('Refresh failed'));
        button.click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('Refresh failed');
    });

    it('tolerates a failed subscription', async () => {
        subscribe.mockRejectedValueOnce(new Error('streaming unavailable'));
        const element = mount();
        getRecentConflictLogs.emit([]);
        await flushPromises();

        expect(element.shadowRoot.querySelector('.empty-state')).not.toBeNull();
    });
    it('links both agents to their record pages and shows refresh progress', async () => {
        const element = mount();
        getRecentConflictLogs.emit([{ ...CONFLICTS[0], Agent_1__c: 'a1', Agent_2__c: 'a2' }]);
        await flushPromises();

        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        const agentColumns = datatable.columns.filter((column) => column.type === 'url');
        expect(agentColumns.map((column) => column.label)).toEqual(['Agent 1', 'Agent 2']);
        expect(datatable.data[0].agent1Url).toBe('/lightning/r/AgentGov_Registration__c/a1/view');
        expect(datatable.data[0].agent2Url).toBe('/lightning/r/AgentGov_Registration__c/a2/view');

        const pending = [];
        refreshApex.mockImplementation(() => new Promise((resolve) => pending.push(resolve)));
        const button = element.shadowRoot.querySelector('lightning-button');
        button.click();
        await flushPromises();
        expect(button.disabled).toBe(true);
        expect(button.label).toBe('Refreshing…');
        refreshApex.mockImplementation(() => Promise.resolve());
        pending.forEach((resolve) => resolve());
        await flushPromises();
        expect(button.disabled).toBe(false);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toMatch(/^Refreshed\./);
        expect(element.shadowRoot.querySelector('.last-updated').textContent).toMatch(/^Updated /);
    });
});
