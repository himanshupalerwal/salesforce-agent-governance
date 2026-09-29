import { createElement } from 'lwc';
import AgentGovDashboard from 'c/agentGovDashboard';
import getAllRegistrations from '@salesforce/apex/AgentGovDashboardController.getAllRegistrations';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovDashboardController.getAllTodaysBudgets';
import getRecentConflictLogs from '@salesforce/apex/AgentGovDashboardController.getRecentConflictLogs';
import getTodaysActionCount from '@salesforce/apex/AgentGovDashboardController.getTodaysActionCount';
import getActiveSessions from '@salesforce/apex/AgentGovDashboardController.getActiveSessions';
import getTrippedCircuitBreakerCount from '@salesforce/apex/AgentGovDashboardController.getTrippedCircuitBreakerCount';
import { refreshApex } from '@salesforce/apex';
import { subscribe, unsubscribe } from 'lightning/empApi';
import { ShowToastEventName } from 'lightning/platformShowToastEvent';
import { getNavigateCalledWith } from 'lightning/navigation';

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
jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getRecentConflictLogs',
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
    '@salesforce/apex/AgentGovDashboardController.getActiveSessions',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getTrippedCircuitBreakerCount',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const AGENTS = [
    { Id: 'a1', Agent_Name__c: 'Agent 1', Status__c: 'Active' },
    { Id: 'a2', Agent_Name__c: 'Agent 2', Status__c: 'Inactive' }
];
const BUDGETS = [
    {
        Id: 'b1',
        Agent_Registration__r: { Agent_Name__c: 'Agent 1' },
        Budget_Status__c: 'Warning',
        API_Calls_Allocated__c: 100,
        API_Calls_Consumed__c: 50,
        SOQL_Queries_Allocated__c: 100,
        SOQL_Queries_Consumed__c: 50,
        DML_Operations_Allocated__c: 100,
        DML_Operations_Consumed__c: 50
    }
];
const CONFLICTS = [
    {
        Id: 'c1',
        Agent_1__r: { Agent_Name__c: 'Agent 1' },
        Agent_2__r: { Agent_Name__c: 'Agent 2' },
        Object_Name__c: 'Account',
        Conflict_Type__c: 'Concurrent_Write',
        Resolution__c: 'Agent1_Won',
        Severity__c: 'High',
        Timestamp__c: '2026-09-15T10:00:00.000Z'
    }
];

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

function emitAll({
    agents = AGENTS,
    budgets = BUDGETS,
    conflicts = CONFLICTS,
    sessions = [],
    actions = 7,
    tripped = 1
} = {}) {
    getAllRegistrations.emit(agents);
    getAllTodaysBudgets.emit(budgets);
    getRecentConflictLogs.emit(conflicts);
    getTodaysActionCount.emit(actions);
    getActiveSessions.emit(sessions);
    getTrippedCircuitBreakerCount.emit(tripped);
}

describe('c-agent-gov-dashboard', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function mount() {
        const element = createElement('c-agent-gov-dashboard', { is: AgentGovDashboard });
        document.body.appendChild(element);
        return element;
    }

    it('shows loading placeholders until every wire has resolved', async () => {
        const element = mount();
        expect(element.shadowRoot.querySelector('.ag-skeleton')).not.toBeNull();
        expect(element.shadowRoot.querySelector('[aria-busy="true"]')).not.toBeNull();

        getAllRegistrations.emit(AGENTS);
        await flushPromises();
        expect(element.shadowRoot.querySelector('.ag-skeleton')).not.toBeNull();

        emitAll();
        await flushPromises();
        expect(element.shadowRoot.querySelector('.ag-skeleton')).toBeNull();
        expect(element.shadowRoot.querySelector('[aria-busy="true"]')).toBeNull();
    });

    it('computes summary tiles and budget bars from wired data', async () => {
        const element = mount();
        emitAll();
        await flushPromises();

        const values = Array.from(element.shadowRoot.querySelectorAll('.kpi-value')).map((el) => el.textContent);
        expect(values).toEqual(['2', '1', '7', '0', '50%', '1']);
        // One breaker is tripped, so its tile is marked as an alert and the others are not.
        expect(element.shadowRoot.querySelector('[data-key="tripped"]').classList.contains('ag-kpi_alert')).toBe(true);
        expect(element.shadowRoot.querySelector('[data-key="tripped"] lightning-icon').variant).toBe('error');
        expect(element.shadowRoot.querySelector('[data-key="total"]').classList.contains('ag-kpi_alert')).toBe(false);

        const bar = element.shadowRoot.querySelector('.budget-row [role="progressbar"]');
        expect(bar.getAttribute('aria-valuenow')).toBe('50');
        // The bar shows the most-used limit, the figure the server decides the status on.
        expect(bar.getAttribute('aria-label')).toBe('Agent 1 peak budget usage 50 percent');
        const fill = bar.querySelector('.usage-fill');
        expect(fill.style.width).toBe('50%');
        expect(fill.classList.contains('ag-bar_normal')).toBe(true);
        const status = element.shadowRoot.querySelector('.budget-status');
        expect(status.textContent).toBe('Warning');
        expect(status.classList.contains('ag-pill_warning')).toBe(true);
        const severity = element.shadowRoot.querySelector('.severity-label');
        expect(severity.textContent).toBe('High');
        expect(severity.classList.contains('ag-pill_error')).toBe(true);
    });

    it('renders empty states when there is no data', async () => {
        const element = mount();
        emitAll({ agents: [], budgets: [], conflicts: [], actions: 0, tripped: 0 });
        await flushPromises();

        const emptyStates = Array.from(element.shadowRoot.querySelectorAll('.empty-state'));
        // The Active Sessions card stays on the page with an empty state instead of disappearing.
        expect(emptyStates.map((el) => el.querySelector('.ag-empty__text').textContent.trim())).toEqual([
            'No budget data available for today.',
            'No agent has a live session right now.',
            'No conflicts detected.'
        ]);
        expect(emptyStates.map((el) => el.querySelector('.ag-empty__title').textContent.trim())).toEqual([
            'No usage yet today',
            'No live sessions',
            'All clear'
        ]);
        expect(element.shadowRoot.querySelector('[data-key="tripped"]').classList.contains('ag-kpi_alert')).toBe(false);
    });

    it('shows the error and toasts once when a wire fails', async () => {
        const element = mount();
        const toastHandler = jest.fn();
        element.addEventListener(ShowToastEventName, toastHandler);

        getAllRegistrations.error({ message: 'Boom' });
        getAllTodaysBudgets.error({ message: 'Boom' });
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"] h2').textContent).toBe('Boom');
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
    });

    it('subscribes to both platform-event channels and refreshes on an event', async () => {
        const element = mount();
        emitAll();
        await flushPromises();

        expect(subscribe).toHaveBeenCalledTimes(2);
        expect(subscribe.mock.calls.map((call) => call[0]).sort()).toEqual([
            '/event/AgentGov_Action_Event__e',
            '/event/AgentGov_Alert__e'
        ]);
        const live = element.shadowRoot.querySelector('[aria-live="polite"]');
        expect(live.textContent).toBe('Live updates on');
        expect(live.classList.contains('ag-live_on')).toBe(true);

        const onEvent = subscribe.mock.calls[0][2];
        onEvent({ data: { payload: {} } });
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(6);

        document.body.removeChild(element);
        expect(unsubscribe).toHaveBeenCalledTimes(2);
    });

    it('refreshes every wire when the Refresh button is clicked', async () => {
        const element = mount();
        emitAll();
        await flushPromises();

        element.shadowRoot.querySelector('lightning-button').click();
        await flushPromises();

        expect(refreshApex).toHaveBeenCalledTimes(6);
    });

    it('coalesces refresh requests that arrive while one is running', async () => {
        const element = mount();
        emitAll();
        await flushPromises();
        let release;
        const gate = new Promise((resolve) => {
            release = resolve;
        });
        refreshApex.mockImplementation(() => gate);

        const button = element.shadowRoot.querySelector('lightning-button');
        button.click();
        button.click();
        button.click();
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(6);

        refreshApex.mockImplementation(() => Promise.resolve());
        release();
        await flushPromises();
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(12);
    });

    it('stays live when only one channel fails to subscribe', async () => {
        subscribe.mockRejectedValueOnce(new Error('streaming unavailable'));
        const element = mount();
        emitAll();
        await flushPromises();

        // One channel refusing must not discard the subscription that succeeded on the other,
        // which Promise.all used to do, leaving it impossible to unsubscribe.
        expect(element.shadowRoot.querySelector('[aria-live="polite"]').textContent).toBe('Live updates on');
    });

    it('reports live updates as off when every channel fails to subscribe', async () => {
        subscribe.mockRejectedValue(new Error('streaming unavailable'));
        const element = mount();
        emitAll();
        await flushPromises();

        const live = element.shadowRoot.querySelector('[aria-live="polite"]');
        expect(live.textContent).toBe('Live updates off');
        expect(live.classList.contains('ag-live_on')).toBe(false);
    });

    it('shows an error when a refresh fails', async () => {
        const element = mount();
        emitAll();
        await flushPromises();
        refreshApex.mockRejectedValueOnce({ body: { message: 'Refresh failed' } });

        element.shadowRoot.querySelector('lightning-button').click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"] h2').textContent).toBe('Refresh failed');
    });
    it('keeps showing a failed wire after another wire loads', async () => {
        const element = mount();
        getAllRegistrations.error({ message: 'No access to registrations' });
        await flushPromises();
        getAllTodaysBudgets.emit(BUDGETS);
        getRecentConflictLogs.emit(CONFLICTS);
        getTodaysActionCount.emit(1);
        getActiveSessions.emit([]);
        getTrippedCircuitBreakerCount.emit(0);
        await flushPromises();

        // settle() used to clear the error whenever any wire succeeded.
        expect(element.shadowRoot.querySelector('[role="alert"] h2').textContent).toBe('No access to registrations');

        getAllRegistrations.emit(AGENTS);
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();
    });

    it('draws each budget bar from the most-used limit, as the server decides the status', async () => {
        const element = mount();
        emitAll({
            budgets: [
                {
                    Id: 'b2',
                    Agent_Registration__c: 'a1',
                    Agent_Registration__r: { Agent_Name__c: 'Agent 1' },
                    Budget_Status__c: 'Throttled',
                    API_Calls_Allocated__c: 100,
                    API_Calls_Consumed__c: 90,
                    SOQL_Queries_Allocated__c: 100,
                    SOQL_Queries_Consumed__c: 0,
                    DML_Operations_Allocated__c: 100,
                    DML_Operations_Consumed__c: 0
                }
            ]
        });
        await flushPromises();

        const bar = element.shadowRoot.querySelector('.budget-row [role="progressbar"]');
        // An average of the three limits would have said 30 beside a Throttled status.
        expect(bar.getAttribute('aria-valuenow')).toBe('90');
        expect(bar.querySelector('.usage-fill').classList.contains('ag-bar_warning')).toBe(true);
        expect(element.shadowRoot.querySelector('.budget-status').classList.contains('ag-pill_warning')).toBe(true);
        const values = Array.from(element.shadowRoot.querySelectorAll('.kpi-value')).map((el) => el.textContent);
        expect(values[4]).toBe('90%');
    });

    it('lists live sessions with their agents and last activity, linked to the agent', async () => {
        const element = mount();
        emitAll({
            sessions: [
                {
                    Id: 's1',
                    Agent_Registration__c: 'a1',
                    Agent_Registration__r: { Agent_Name__c: 'Agent 1' },
                    Session_Start__c: '2026-09-15T10:00:00.000Z',
                    Last_Activity__c: '2026-09-15T10:05:00.000Z',
                    API_Calls_Used__c: 3,
                    SOQL_Queries_Used__c: 1,
                    DML_Statements_Used__c: 0,
                    Actions_Count__c: 4
                }
            ]
        });
        await flushPromises();

        const link = element.shadowRoot.querySelector('tbody th[scope="row"] a');
        expect(link.textContent).toBe('Agent 1');
        expect(link.getAttribute('href')).toBe('/lightning/r/AgentGov_Registration__c/a1/view');
        link.click();
        expect(getNavigateCalledWith().pageReference.attributes.recordId).toBe('a1');
        // API calls, SOQL queries, DML statements, and actions, in column order.
        const counts = Array.from(link.closest('tr').querySelectorAll('td.ag-num')).map((el) => el.textContent);
        expect(counts).toEqual(['3', '1', '0', '4']);
    });

    it('shows that a refresh is running, then when the data was last updated', async () => {
        const element = mount();
        emitAll();
        await flushPromises();
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
        expect(button.label).toBe('Refresh');
        expect(element.shadowRoot.querySelector('.last-updated').textContent).toMatch(/^Updated /);
        const announcement = element.shadowRoot.querySelector('.announcement');
        expect(announcement.getAttribute('aria-live')).toBe('polite');
        expect(announcement.textContent).toMatch(/^Refreshed\. Last updated .+\.$/);
    });
});
