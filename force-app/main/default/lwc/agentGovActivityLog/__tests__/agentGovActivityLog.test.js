import { createElement } from 'lwc';
import AgentGovActivityLog from 'c/agentGovActivityLog';
import getActionLogs from '@salesforce/apex/AgentGovDashboardController.getActionLogs';
import { refreshApex } from '@salesforce/apex';
import { subscribe } from 'lightning/empApi';
import { getNavigateCalledWith, resetNavigation } from 'lightning/navigation';

jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getActionLogs',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

function row(id, createdDate, fields = {}) {
    return {
        Id: id,
        CreatedDate: createdDate,
        Timestamp__c: createdDate,
        Agent_Registration__c: 'a1',
        Agent_Registration__r: { Agent_Name__c: 'Lead Enrichment Agent' },
        Action_Type__c: 'Query',
        Status__c: 'Success',
        Object_Name__c: 'Account',
        Execution_Time_Ms__c: 1234,
        ...fields
    };
}

const DENIED = row('l3', '2026-09-28T10:03:00.000+0000', {
    Action_Type__c: 'Delete',
    Status__c: 'Denied',
    Record_Id__c: '001000000000001AAA',
    Error_Message__c: 'Policy violation: Agent Lead Enrichment Agent is not authorized to Delete on Account.',
    Details__c: 'ignored when an error message is present',
    Correlation_Id__c: 'demo-run-Lead'
});
const FIRST_PAGE = [
    DENIED,
    row('l2', '2026-09-28T10:02:00.000+0000', {
        Action_Type__c: 'API_Call',
        Details__c: 'x'.repeat(600),
        Execution_Time_Ms__c: null
    }),
    row('l1', '2026-09-28T10:01:00.000+0000', {
        Action_Type__c: 'Admin',
        Status__c: 'Custom',
        Agent_Registration__c: null,
        Agent_Registration__r: null
    })
];

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-agent-gov-activity-log', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        refreshApex.mockImplementation(() => Promise.resolve());
        resetNavigation();
    });

    async function mount(recordId) {
        const element = createElement('c-agent-gov-activity-log', { is: AgentGovActivityLog });
        if (recordId) {
            element.recordId = recordId;
        }
        document.body.appendChild(element);
        await flushPromises();
        return element;
    }

    function rows(element) {
        return Array.from(element.shadowRoot.querySelectorAll('tr.log-row'));
    }

    it('reads usage reports and alerts as sentences, and shortens a generated request id', async () => {
        const element = await mount();
        getActionLogs.emit({
            rows: [
                row('r1', '2026-09-28T10:05:00.000+0000', {
                    Action_Type__c: 'Report',
                    Details__c: '{"dmlOperations":null,"soqlQueries":2,"apiCalls":0}',
                    Correlation_Id__c: '79cd10be-3dde-4a59-a412-09622542986e'
                }),
                row('r2', '2026-09-28T10:04:00.000+0000', {
                    Action_Type__c: 'Alert',
                    Details__c:
                        'Block alert for agent Order Sync Agent: Circuit_Breaker at 100.00% (3.0 of 3.0) at 2026-09-28 17:16:32'
                })
            ],
            hasMore: false
        });
        await flushPromises();

        const [report, alert] = rows(element);
        expect(report.querySelector('.reason').textContent).toBe('Used 2 SOQL queries');
        const request = report.querySelector('.correlation-button');
        expect(request.textContent.trim()).toBe('Request 79cd10be…');
        expect(request.title).toBe('Show only the rows of request 79cd10be-3dde-4a59-a412-09622542986e');
        expect(request.dataset.correlation).toBe('79cd10be-3dde-4a59-a412-09622542986e');
        expect(alert.querySelector('.reason').textContent).toBe('Breaker open: 3 failures reached the threshold of 3.');
    });

    it('shows the newest rows with the reason for a denial as text in the row', async () => {
        const element = await mount();
        expect(element.shadowRoot.querySelector('.ag-skeleton')).not.toBeNull();
        expect(getActionLogs.getLastConfig()).toEqual({
            registrationId: null,
            status: '',
            actionType: '',
            windowHours: 24,
            correlationId: '',
            beforeCreatedDate: null,
            beforeId: null,
            pageSize: 50
        });
        getActionLogs.emit({ rows: FIRST_PAGE, hasMore: false });
        await flushPromises();

        expect(element.shadowRoot.querySelector('.log-heading').textContent).toBe('Activity log');
        const [denied, apiCall, admin] = rows(element);
        expect(denied.querySelector('.reason').textContent).toBe(
            'Policy violation: Agent Lead Enrichment Agent is not authorized to Delete on Account.'
        );
        expect(denied.querySelector('.log-status').textContent).toBe('Denied');
        expect(denied.querySelector('.log-status').classList.contains('ag-pill_error')).toBe(true);
        expect(denied.querySelector('.log-agent .agent-link').textContent).toBe('Lead Enrichment Agent');
        expect(denied.querySelector('.log-record').textContent).toBe('001000000000001AAA');
        expect(denied.querySelector('.log-duration').textContent).toBe('1,234');
        expect(denied.querySelector('.correlation-button').textContent.trim()).toBe('Request demo-run-Lead');
        expect(apiCall.querySelector('.log-action').textContent).toBe('API call');
        expect(apiCall.querySelector('.reason').textContent).toBe(`${'x'.repeat(500)}…`);
        expect(apiCall.querySelector('.log-duration').textContent).toBe('');
        expect(admin.querySelector('.log-agent .agent-link')).toBeNull();
        expect(admin.querySelector('.log-status').classList.contains('ag-pill_neutral')).toBe(true);
        expect(element.shadowRoot.querySelector('.summary').textContent).toBe('Showing 3 rows.');
        expect(element.shadowRoot.querySelector('.load-more')).toBeNull();
    });

    it("shows one agent's rows under Recent activity on its record page", async () => {
        const element = await mount('a1');
        expect(getActionLogs.getLastConfig()).toMatchObject({ registrationId: 'a1', pageSize: 25 });
        getActionLogs.emit({ rows: [DENIED], hasMore: false });
        await flushPromises();

        expect(element.recordId).toBe('a1');
        expect(element.shadowRoot.querySelector('.log-heading').textContent).toBe('Recent activity');
        expect(element.shadowRoot.querySelector('.log-agent')).toBeNull();
        expect(element.shadowRoot.querySelector('.summary').textContent).toBe('Showing 1 row.');
    });

    it('passes every filter to the server and clears them together', async () => {
        const element = await mount();
        getActionLogs.emit({ rows: FIRST_PAGE, hasMore: false });
        await flushPromises();
        const change = (selector, value) =>
            element.shadowRoot.querySelector(selector).dispatchEvent(new CustomEvent('change', { detail: { value } }));

        change('.status-filter', 'Denied');
        change('.type-filter', 'Delete');
        change('.window-filter', '168');
        await flushPromises();
        expect(getActionLogs.getLastConfig()).toMatchObject({
            status: 'Denied',
            actionType: 'Delete',
            windowHours: 168
        });
        // Rows of the previous query are replaced by loading placeholders until the new page arrives.
        expect(element.shadowRoot.querySelector('.ag-skeleton')).not.toBeNull();

        const correlation = element.shadowRoot.querySelector('.correlation-filter');
        correlation.dispatchEvent(new CustomEvent('change', { detail: { value: ' demo-run-Lead ' } }));
        correlation.dispatchEvent(new CustomEvent('commit'));
        await flushPromises();
        expect(getActionLogs.getLastConfig().correlationId).toBe('demo-run-Lead');

        getActionLogs.emit({ rows: [DENIED], hasMore: false });
        await flushPromises();
        element.shadowRoot.querySelector('.clear-filters').click();
        await flushPromises();
        expect(getActionLogs.getLastConfig()).toMatchObject({
            status: '',
            actionType: '',
            windowHours: 24,
            correlationId: ''
        });

        change('.status-filter', 'all');
        change('.type-filter', 'all');
        change('.window-filter', 'not a number');
        await flushPromises();
        expect(getActionLogs.getLastConfig()).toMatchObject({ status: '', actionType: '', windowHours: 24 });
    });

    it('follows one request from its correlation id, and drops the filter when the field is cleared', async () => {
        const element = await mount();
        getActionLogs.emit({ rows: FIRST_PAGE, hasMore: false });
        await flushPromises();

        element.shadowRoot.querySelector('.correlation-button').click();
        await flushPromises();
        expect(getActionLogs.getLastConfig().correlationId).toBe('demo-run-Lead');
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe(
            'Showing the rows of request demo-run-Lead.'
        );

        element.shadowRoot
            .querySelector('.correlation-filter')
            .dispatchEvent(new CustomEvent('change', { detail: { value: '' } }));
        await flushPromises();
        expect(getActionLogs.getLastConfig().correlationId).toBe('');
    });

    it('loads older rows by keyset and keeps them when the newest page refreshes', async () => {
        const element = await mount();
        getActionLogs.emit({ rows: FIRST_PAGE, hasMore: true });
        await flushPromises();
        getActionLogs.mockResolvedValueOnce({
            rows: [row('l0', '2026-09-28T09:59:00.000+0000'), row('l1', '2026-09-28T10:01:00.000+0000')],
            hasMore: false
        });

        element.shadowRoot.querySelector('.load-more').click();
        await flushPromises();

        expect(getActionLogs).toHaveBeenCalledWith({
            registrationId: null,
            status: '',
            actionType: '',
            windowHours: 24,
            correlationId: '',
            beforeCreatedDate: '2026-09-28T10:01:00.000+0000',
            beforeId: 'l1',
            pageSize: 50
        });
        expect(rows(element).length).toBe(4);
        expect(element.shadowRoot.querySelector('.load-more')).toBeNull();
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe('Loaded 2 more rows.');

        // A refresh of the newest page adds new rows above the ones already loaded.
        getActionLogs.emit({ rows: [row('l4', '2026-09-28T10:04:00.000+0000'), DENIED], hasMore: true });
        await flushPromises();
        expect(rows(element).map((tr) => tr.getAttribute('data-id') || tr.querySelector('a').dataset.recordId)).toEqual(
            ['l4', 'l3', 'l2', 'l1', 'l0']
        );
    });

    it('announces a single loaded row, and reports a failed page', async () => {
        const element = await mount();
        getActionLogs.emit({ rows: FIRST_PAGE, hasMore: true });
        await flushPromises();

        getActionLogs.mockResolvedValueOnce({ rows: [row('l0', '2026-09-28T09:59:00.000+0000')], hasMore: true });
        element.shadowRoot.querySelector('.load-more').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe('Loaded 1 more row.');
        expect(element.shadowRoot.querySelector('.summary').textContent).toBe(
            'Showing the newest 4 rows. Older rows are available.'
        );

        getActionLogs.mockRejectedValueOnce({ body: { message: 'Query timed out' } });
        element.shadowRoot.querySelector('.load-more').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe('Query timed out');
    });

    it('discards an older page that arrives after the filters changed', async () => {
        const element = await mount();
        getActionLogs.emit({ rows: FIRST_PAGE, hasMore: true });
        await flushPromises();
        let resolvePage;
        getActionLogs.mockImplementationOnce(
            () =>
                new Promise((resolve) => {
                    resolvePage = resolve;
                })
        );

        element.shadowRoot.querySelector('.load-more').click();
        element.shadowRoot
            .querySelector('.status-filter')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'Failure' } }));
        resolvePage({ rows: [row('l0', '2026-09-28T09:59:00.000+0000')], hasMore: false });
        await flushPromises();
        getActionLogs.emit({ rows: [], hasMore: false });
        await flushPromises();

        expect(rows(element).length).toBe(0);
        expect(element.shadowRoot.querySelector('.empty-state')).not.toBeNull();
    });

    it('shows a load error in place of rows from another query', async () => {
        const element = await mount();
        getActionLogs.error({ message: 'No access to the action log' });
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe(
            'No access to the action log'
        );
        expect(element.shadowRoot.querySelector('.ag-skeleton')).toBeNull();
        expect(rows(element).length).toBe(0);
    });

    it('refreshes on request and on platform events', async () => {
        const element = await mount();
        getActionLogs.emit({ rows: FIRST_PAGE, hasMore: false });
        await flushPromises();

        element.shadowRoot.querySelector('.refresh-button').click();
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(1);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toMatch(/^Refreshed\./);

        subscribe.mock.calls[0][2]({ data: {} });
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(2);

        refreshApex.mockRejectedValueOnce({ body: { message: 'Refresh failed' } });
        element.shadowRoot.querySelector('.refresh-button').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe('Refresh failed');
    });

    it('opens the agent and the log row from their links, and takes focus when asked', async () => {
        const element = await mount();
        getActionLogs.emit({ rows: FIRST_PAGE, hasMore: false });
        await flushPromises();

        rows(element)[0].querySelector('.log-time a').click();
        expect(getNavigateCalledWith().pageReference.attributes).toEqual({
            recordId: 'l3',
            objectApiName: 'AgentGov_Action_Log__c',
            actionName: 'view'
        });
        rows(element)[0].querySelector('.agent-link').click();
        expect(getNavigateCalledWith().pageReference.attributes.recordId).toBe('a1');

        const heading = element.shadowRoot.querySelector('.log-heading');
        const headingFocus = jest.spyOn(heading, 'focus');
        element.focusRequest = 2;
        await flushPromises();
        expect(headingFocus).toHaveBeenCalledTimes(1);
        expect(element.focusRequest).toBe(2);
    });
});
