import { createElement } from 'lwc';
import AgentGovAgentList from 'c/agentGovAgentList';
import getAgentSummaries from '@salesforce/apex/AgentGovDashboardController.getAgentSummaries';
import resetBreakers from '@salesforce/apex/AgentGovAdminController.resetBreakers';
import activateAgents from '@salesforce/apex/AgentGovAdminController.activateAgents';
import LightningConfirm from 'lightning/confirm';
import { refreshApex } from '@salesforce/apex';
import { subscribe } from 'lightning/empApi';

jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getAgentSummaries',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock('@salesforce/apex/AgentGovAdminController.resetBreakers', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/AgentGovAdminController.activateAgents', () => ({ default: jest.fn() }), {
    virtual: true
});

const COOLDOWN = new Date(Date.now() + 10 * 60 * 1000).toISOString();
const AGENTS = [
    {
        id: 'a1',
        name: 'Order Sync Agent',
        agentType: 'MCP_External',
        status: 'Blocked',
        breakerState: 'OPEN',
        cooldownUntil: COOLDOWN,
        failureCount: 3,
        priority: 4,
        lastActive: '2026-09-28T10:00:00.000Z',
        budgetStatus: 'Normal',
        peakUsagePercent: 2
    },
    {
        id: 'a2',
        name: 'lead Enrichment Agent',
        agentType: 'MCP_External',
        status: 'Active',
        breakerState: 'CLOSED',
        failureCount: 0,
        priority: 2,
        lastActive: '2026-09-28T11:00:00.000Z',
        budgetStatus: 'Warning',
        peakUsagePercent: 85.2
    },
    {
        id: 'a3',
        name: 'Case Triage Agent',
        agentType: 'Custom_Apex',
        status: 'Active',
        breakerState: 'CLOSED',
        priority: null,
        budgetStatus: 'Exhausted',
        peakUsagePercent: 100
    },
    {
        id: 'a4',
        name: 'Renewal Forecast Flow',
        agentType: 'Flow_Based',
        status: 'Inactive',
        breakerState: 'HALF_OPEN',
        priority: 5
    }
];

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

function names(element) {
    return element.shadowRoot.querySelector('lightning-datatable').data.map((row) => row.name);
}

function rowActionsFor(element, id) {
    const datatable = element.shadowRoot.querySelector('lightning-datatable');
    const column = datatable.columns.find((candidate) => candidate.type === 'action');
    const row = datatable.data.find((candidate) => candidate.id === id);
    const done = jest.fn();
    column.typeAttributes.rowActions(row, done);
    return done.mock.calls[0][0];
}

describe('c-agent-gov-agent-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        refreshApex.mockImplementation(() => Promise.resolve());
        LightningConfirm.open.mockImplementation(() => Promise.resolve(true));
    });

    async function mount(filter) {
        const element = createElement('c-agent-gov-agent-list', { is: AgentGovAgentList });
        if (filter) {
            element.filter = filter;
        }
        document.body.appendChild(element);
        getAgentSummaries.emit(AGENTS);
        await flushPromises();
        return element;
    }

    it('shows every agent with readable state, sorted by name', async () => {
        const element = await mount();
        const datatable = element.shadowRoot.querySelector('lightning-datatable');

        expect(names(element)).toEqual([
            'Case Triage Agent',
            'lead Enrichment Agent',
            'Order Sync Agent',
            'Renewal Forecast Flow'
        ]);
        expect(datatable.columns.map((column) => column.label)).toEqual([
            'Agent',
            'Type',
            'Status',
            'Breaker',
            'Peak usage today',
            'Last active',
            'Failures',
            'Priority',
            undefined
        ]);
        const order = datatable.data.find((row) => row.id === 'a1');
        expect(order.recordUrl).toBe('/lightning/r/AgentGov_Registration__c/a1/view');
        expect(order.agentTypeLabel).toBe('MCP External');
        expect(order.breakerText).toMatch(/^Open\. Can retry at /);
        expect(order.peakText).toBe('2% (Normal)');
        const renewal = datatable.data.find((row) => row.id === 'a4');
        expect(renewal.breakerText).toBe('Half-open. Next request is a trial');
        expect(renewal.peakText).toBe('No usage today');
        expect(renewal.lastActiveText).toBe('Never');
        expect(datatable.hideCheckboxColumn).toBe(false);
        expect(element.shadowRoot.querySelector('.summary').textContent).toBe('Showing 4 of 4 agents.');
    });

    it('filters by state, from the filter property and from the buttons', async () => {
        const element = await mount('tripped');
        expect(names(element)).toEqual(['Order Sync Agent']);

        element.filter = 'attention';
        await flushPromises();
        expect(names(element)).toEqual(['Case Triage Agent', 'Order Sync Agent', 'Renewal Forecast Flow']);

        const filterChange = jest.fn();
        element.addEventListener('filterchange', filterChange);
        const radio = element.shadowRoot.querySelector('lightning-radio-group');
        radio.dispatchEvent(new CustomEvent('change', { detail: { value: 'inactive' } }));
        await flushPromises();
        expect(names(element)).toEqual(['Renewal Forecast Flow']);
        expect(filterChange.mock.calls[0][0].detail).toEqual({ filter: 'inactive' });

        radio.dispatchEvent(new CustomEvent('change', { detail: { value: 'active' } }));
        await flushPromises();
        expect(names(element)).toEqual(['Case Triage Agent', 'lead Enrichment Agent']);

        element.filter = 'bogus';
        await flushPromises();
        expect(element.filter).toBe('all');
        expect(names(element).length).toBe(4);
    });

    it('searches by name, type, or status, and says when nothing matches', async () => {
        const element = await mount();
        const search = element.shadowRoot.querySelector('lightning-input.search');

        search.dispatchEvent(new CustomEvent('change', { detail: { value: 'flow' } }));
        await flushPromises();
        expect(names(element)).toEqual(['Renewal Forecast Flow']);

        search.dispatchEvent(new CustomEvent('change', { detail: { value: 'BLOCKED' } }));
        await flushPromises();
        expect(names(element)).toEqual(['Order Sync Agent']);

        search.dispatchEvent(new CustomEvent('change', { detail: { value: 'nothing like this' } }));
        await flushPromises();
        expect(element.shadowRoot.querySelector('lightning-datatable')).toBeNull();
        expect(element.shadowRoot.querySelector('.no-match')).not.toBeNull();

        // A drill-down from the console starts from a clean search.
        element.filter = 'tripped';
        await flushPromises();
        expect(names(element)).toEqual(['Order Sync Agent']);
    });

    it('clears the search on a drill-down that names the filter already selected', async () => {
        const element = await mount('attention');
        const search = element.shadowRoot.querySelector('lightning-input.search');
        search.dispatchEvent(new CustomEvent('change', { detail: { value: 'flow' } }));
        await flushPromises();
        expect(names(element)).toEqual(['Renewal Forecast Flow']);

        // The console sends the same filter again with a new focus request.
        element.filter = 'attention';
        element.focusRequest = 1;
        await flushPromises();
        expect(names(element)).toEqual(['Case Triage Agent', 'Order Sync Agent', 'Renewal Forecast Flow']);
        expect(element.shadowRoot.querySelector('lightning-input.search').value).toBe('');
    });

    it('sorts each column by its underlying value, with blanks last', async () => {
        const element = await mount();
        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        const sort = async (fieldName, sortDirection) => {
            datatable.dispatchEvent(new CustomEvent('sort', { detail: { fieldName, sortDirection } }));
            await flushPromises();
            return names(element);
        };

        expect(await sort('peakText', 'desc')).toEqual([
            'Case Triage Agent',
            'lead Enrichment Agent',
            'Order Sync Agent',
            'Renewal Forecast Flow'
        ]);
        expect(await sort('lastActiveText', 'desc')).toEqual([
            'lead Enrichment Agent',
            'Order Sync Agent',
            'Case Triage Agent',
            'Renewal Forecast Flow'
        ]);
        expect(await sort('priority', 'asc')).toEqual([
            'lead Enrichment Agent',
            'Order Sync Agent',
            'Renewal Forecast Flow',
            'Case Triage Agent'
        ]);
        expect(await sort('priority', 'desc')).toEqual([
            'Renewal Forecast Flow',
            'Order Sync Agent',
            'lead Enrichment Agent',
            'Case Triage Agent'
        ]);
        expect(await sort('breakerText', 'desc')).toEqual([
            'Order Sync Agent',
            'Renewal Forecast Flow',
            'Case Triage Agent',
            'lead Enrichment Agent'
        ]);
        expect(await sort('recordUrl', 'desc')).toEqual([
            'Renewal Forecast Flow',
            'Order Sync Agent',
            'lead Enrichment Agent',
            'Case Triage Agent'
        ]);
        expect(datatable.sortedBy).toBe('recordUrl');
        expect(datatable.sortedDirection).toBe('desc');
        expect(await sort('agentTypeLabel', 'asc')).toEqual([
            'Case Triage Agent',
            'Renewal Forecast Flow',
            'lead Enrichment Agent',
            'Order Sync Agent'
        ]);
    });

    it('offers row actions that match each agent state', async () => {
        const element = await mount();

        expect(rowActionsFor(element, 'a1').map((action) => action.label)).toEqual([
            'Reset breaker',
            'Activate',
            'Deactivate',
            'Credit budget',
            'Rotate key'
        ]);
        expect(rowActionsFor(element, 'a2').map((action) => action.label)).toEqual([
            'Deactivate',
            'Credit budget',
            'Rotate key'
        ]);
        expect(rowActionsFor(element, 'a4').map((action) => action.label)).toEqual([
            'Reset breaker',
            'Activate',
            'Rotate key'
        ]);
    });

    it('runs a row action after confirmation and refreshes', async () => {
        const element = await mount();
        resetBreakers.mockResolvedValue([{ recordId: 'a1', success: true, message: 'Circuit breaker closed.' }]);
        const datatable = element.shadowRoot.querySelector('lightning-datatable');

        datatable.dispatchEvent(
            new CustomEvent('rowaction', { detail: { action: { name: 'reset' }, row: { id: 'a1' } } })
        );
        await flushPromises();
        await flushPromises();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        expect(resetBreakers).toHaveBeenCalledWith({ registrationIds: ['a1'] });
        expect(refreshApex).toHaveBeenCalledTimes(1);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe(
            'Order Sync Agent: Circuit breaker closed.'
        );

        datatable.dispatchEvent(
            new CustomEvent('rowaction', { detail: { action: { name: 'none' }, row: { id: 'a1' } } })
        );
        await flushPromises();
        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
    });

    it('acts on the selected agents together and then clears the selection', async () => {
        const element = await mount();
        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        const bulkLabels = () =>
            Array.from(element.shadowRoot.querySelectorAll('.bulk-button')).map((button) => [
                button.label,
                button.disabled
            ]);

        expect(bulkLabels()).toEqual([
            ['Reset breakers', true],
            ['Activate', true],
            ['Deactivate', true]
        ]);

        const selected = datatable.data.filter((row) => ['a1', 'a2', 'a4'].includes(row.id));
        datatable.dispatchEvent(new CustomEvent('rowselection', { detail: { selectedRows: selected } }));
        await flushPromises();
        expect(bulkLabels()).toEqual([
            ['Reset breakers (2)', false],
            ['Activate (2)', false],
            ['Deactivate (2)', false]
        ]);
        expect([...datatable.selectedRows]).toEqual(['a2', 'a1', 'a4']);
        expect(element.shadowRoot.querySelector('.summary').textContent).toBe('Showing 4 of 4 agents, 3 selected.');

        activateAgents.mockResolvedValue([
            { recordId: 'a1', success: true, message: 'Agent activated.' },
            { recordId: 'a4', success: true, message: 'Agent activated.' }
        ]);
        const heading = element.shadowRoot.querySelector('.agents-heading');
        const headingFocus = jest.spyOn(heading, 'focus');
        element.shadowRoot.querySelector('.bulk-button[data-action="activate"]').click();
        await flushPromises();
        await flushPromises();

        expect(activateAgents).toHaveBeenCalledWith({ registrationIds: ['a1', 'a4'] });
        expect([...datatable.selectedRows]).toEqual([]);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe('Activate: 2 of 2 agents done.');
        // The button is disabled once the selection is cleared, so focus moves to the heading.
        expect(headingFocus).toHaveBeenCalled();
    });

    it('moves focus to its heading when the console asks', async () => {
        const element = await mount();
        const heading = element.shadowRoot.querySelector('.agents-heading');
        const headingFocus = jest.spyOn(heading, 'focus');

        element.focusRequest = 1;
        await flushPromises();
        expect(headingFocus).toHaveBeenCalledTimes(1);
        expect(element.focusRequest).toBe(1);

        element.focusRequest = 1;
        await flushPromises();
        expect(headingFocus).toHaveBeenCalledTimes(1);
    });

    it('refreshes on request and on platform events, and reports failures', async () => {
        const element = await mount();
        const button = element.shadowRoot.querySelector('.refresh-button');

        button.click();
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(1);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toMatch(/^Refreshed\./);
        expect(element.shadowRoot.querySelector('.last-updated').textContent).toMatch(/^Updated /);

        subscribe.mock.calls[0][2]({ data: {} });
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(2);

        refreshApex.mockRejectedValueOnce({ body: { message: 'Refresh failed' } });
        button.click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe('Refresh failed');
    });

    it('coalesces a refresh requested while one is running', async () => {
        const element = await mount();
        const pending = [];
        refreshApex.mockImplementation(() => new Promise((resolve) => pending.push(resolve)));

        element.refresh();
        element.refresh();
        expect(refreshApex).toHaveBeenCalledTimes(1);
        refreshApex.mockImplementation(() => Promise.resolve());
        pending.forEach((resolve) => resolve());
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(2);
    });

    it('shows the empty state, and the load error', async () => {
        const element = createElement('c-agent-gov-agent-list', { is: AgentGovAgentList });
        document.body.appendChild(element);
        expect(element.shadowRoot.querySelector('.ag-skeleton')).not.toBeNull();

        getAgentSummaries.emit([]);
        await flushPromises();
        expect(element.shadowRoot.querySelector('.no-agents')).not.toBeNull();

        getAgentSummaries.error({ message: 'No access' });
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe('No access');
    });
});
