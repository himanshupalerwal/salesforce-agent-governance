import { createElement } from 'lwc';
import AgentGovUsageHistory from 'c/agentGovUsageHistory';
import getUsageHistory from '@salesforce/apex/AgentGovDashboardController.getUsageHistory';
import { refreshApex } from '@salesforce/apex';
import { subscribe } from 'lightning/empApi';

jest.mock(
    '@salesforce/apex/AgentGovDashboardController.getUsageHistory',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const ORG_HISTORY = [
    { day: '2026-09-26', apiCalls: 1200, soqlQueries: 300, dmlOperations: 20, peakUsagePercent: 45.6 },
    { day: '2026-09-27', apiCalls: 9800, soqlQueries: 10, dmlOperations: 0, peakUsagePercent: 97.2 }
];
const AGENT_HISTORY = [
    {
        day: '2026-09-27',
        apiCalls: 85,
        soqlQueries: 0,
        dmlOperations: 0,
        peakUsagePercent: 85,
        budgetStatus: 'Warning'
    },
    { day: '2026-09-28', apiCalls: 3, soqlQueries: 1, dmlOperations: 0, peakUsagePercent: 3 }
];

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-agent-gov-usage-history', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        refreshApex.mockImplementation(() => Promise.resolve());
    });

    function mount(properties = {}) {
        const element = createElement('c-agent-gov-usage-history', { is: AgentGovUsageHistory });
        Object.assign(element, properties);
        document.body.appendChild(element);
        return element;
    }

    it('shows org-wide usage per day, newest first, as an accessible table with bars', async () => {
        const element = mount({ days: '14' });
        expect(element.shadowRoot.querySelector('.ag-skeleton')).not.toBeNull();
        await flushPromises();
        expect(getUsageHistory.getLastConfig()).toEqual({ registrationId: null, days: 14 });
        getUsageHistory.emit(ORG_HISTORY);
        await flushPromises();

        const rows = Array.from(element.shadowRoot.querySelectorAll('tr.history-row'));
        expect(rows.map((row) => row.querySelector('th').textContent)).toEqual(['Sun, Sep 27', 'Sat, Sep 26']);
        expect(rows[0].querySelector('.api-calls').textContent).toBe('9,800');
        expect(rows[0].querySelector('.peak-value').textContent).toBe('97%');
        const fill = rows[0].querySelector('.history-fill');
        expect(fill.style.width).toBe('97%');
        expect(fill.classList.contains('bar-danger')).toBe(true);
        expect(rows[0].querySelector('.history-track').getAttribute('aria-hidden')).toBe('true');
        expect(element.shadowRoot.querySelector('caption').textContent).toContain('all agents you can see');
        // The org-wide history has no status of its own, so the column is left out.
        expect(element.shadowRoot.querySelector('.status-label')).toBeNull();
        expect(element.days).toBe(14);
        expect(element.recordId).toBeUndefined();
    });

    it("switches the period, including the configured one, for one agent's history", async () => {
        const element = mount({ recordId: 'a1' });
        await flushPromises();
        const radio = element.shadowRoot.querySelector('lightning-radio-group');
        expect(radio.options.map((option) => option.value)).toEqual(['7', '30']);
        expect(radio.value).toBe('7');
        expect(getUsageHistory.getLastConfig()).toEqual({ registrationId: 'a1', days: 7 });

        radio.dispatchEvent(new CustomEvent('change', { detail: { value: '30' } }));
        await flushPromises();
        expect(getUsageHistory.getLastConfig()).toEqual({ registrationId: 'a1', days: 30 });

        getUsageHistory.emit(AGENT_HISTORY);
        await flushPromises();
        const statuses = Array.from(element.shadowRoot.querySelectorAll('.status-label')).map(
            (label) => label.textContent
        );
        expect(statuses).toEqual(['None', 'Warning']);
        expect(element.shadowRoot.querySelector('caption').textContent).toContain('for this agent');
    });

    it('caps the period at 90 days and falls back to 7 for a bad value', () => {
        const element = mount({ days: 400 });
        expect(element.days).toBe(90);
        element.days = 'soon';
        expect(element.days).toBe(7);
    });

    it('shows an empty state and a load error', async () => {
        const element = mount();
        getUsageHistory.emit([]);
        await flushPromises();
        expect(element.shadowRoot.querySelector('.empty-state').textContent).toBe(
            'No budget usage recorded in the last 7 days.'
        );

        getUsageHistory.error({ message: 'No access to budgets' });
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe(
            'No access to budgets'
        );
    });

    it('refreshes when asked and on platform events, and reports a failed refresh', async () => {
        const element = mount();
        getUsageHistory.emit(ORG_HISTORY);
        await flushPromises();
        await element.refresh();
        expect(refreshApex).toHaveBeenCalledTimes(1);

        subscribe.mock.calls[0][2]({ data: {} });
        await flushPromises();
        expect(refreshApex).toHaveBeenCalledTimes(2);

        refreshApex.mockRejectedValueOnce({ body: { message: 'Refresh failed' } });
        await element.refresh();
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe('Refresh failed');
    });
});
