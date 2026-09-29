import {
    reduceErrors,
    describeError,
    combineErrors,
    usageLevel,
    percentOf,
    peakUsagePercent,
    clampPercent,
    budgetStatusView,
    breakerView,
    retryText,
    needsAttention,
    formatDateTime,
    formatTime,
    formatCompactDateTime,
    formatDate,
    formatNumber,
    refreshedMessage,
    recordUrl,
    recordPageReference,
    followRecordLink,
    restoreFocus,
    subscribeToAgentGovEvents,
    unsubscribeFromAgentGovEvents,
    ALERT_CHANNEL,
    ACTION_CHANNEL
} from 'c/agentGovUtils';
import { subscribe, unsubscribe, isEmpEnabled } from 'lightning/empApi';
import { NavigationMixin } from 'lightning/navigation';

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('agentGovUtils', () => {
    afterEach(() => {
        jest.clearAllMocks();
    });

    it('reduces every error shape to messages', () => {
        expect(reduceErrors({ body: { message: 'apex' } })).toEqual(['apex']);
        expect(reduceErrors({ body: [{ message: 'a' }, { message: 'b' }] })).toEqual(['a', 'b']);
        expect(reduceErrors({ body: { pageErrors: [{ message: 'page' }] } })).toEqual(['page']);
        expect(reduceErrors(new Error('plain'))).toEqual(['plain']);
        expect(reduceErrors([null, { statusText: 'Gone' }])).toEqual(['Gone']);
        expect(reduceErrors({})).toEqual(['Unknown error']);
        expect(describeError({ body: [{ message: 'a' }, { message: 'b' }] })).toBe('a. b');
    });

    it('combines per-source errors without repeating a message', () => {
        expect(combineErrors({ agents: 'Boom', budgets: 'Boom', sessions: 'Other' })).toBe('Boom. Other');
        expect(combineErrors({ agents: '' })).toBe('');
        expect(combineErrors(undefined)).toBe('');
    });

    it('classifies usage and computes percentages', () => {
        // Thresholds mirror AgentGovConstants: Warning 80, Throttled 90, Blocked 95.
        expect(usageLevel(0)).toBe('normal');
        expect(usageLevel(79)).toBe('normal');
        expect(usageLevel(80)).toBe('warning');
        expect(usageLevel(90)).toBe('warning');
        expect(usageLevel(95)).toBe('danger');
        expect(percentOf(1, 3)).toBe(33);
        // A zero allocation means the limit type is not available to this agent, so any
        // consumption at all is full usage. This mirrors AgentGovBudgetManager.evaluate.
        expect(percentOf(5, 0)).toBe(100);
        expect(percentOf(0, 0)).toBe(0);
        expect(percentOf(undefined, undefined)).toBe(0);
        // Overage is persisted before a denial, so the raw ratio can exceed 100.
        expect(percentOf(150, 100)).toBe(100);
    });

    it('reports the peak of the three limits, as the server decides the budget status', () => {
        const budget = {
            API_Calls_Allocated__c: 100,
            API_Calls_Consumed__c: 10,
            SOQL_Queries_Allocated__c: 100,
            SOQL_Queries_Consumed__c: 91,
            DML_Operations_Allocated__c: 100,
            DML_Operations_Consumed__c: 0
        };
        // An average would say 34 and a sum-based ratio 34; the status is decided on 91.
        expect(peakUsagePercent(budget)).toBe(91);
        expect(peakUsagePercent({ ...budget, DML_Operations_Allocated__c: 0, DML_Operations_Consumed__c: 1 })).toBe(
            100
        );
        expect(peakUsagePercent({})).toBe(0);
        expect(peakUsagePercent(undefined)).toBe(0);
    });

    it('rounds and clamps server percentages for display', () => {
        expect(clampPercent(85.4)).toBe(85);
        expect(clampPercent(150)).toBe(100);
        expect(clampPercent(-3)).toBe(0);
        expect(clampPercent(null)).toBe(0);
        expect(clampPercent('not a number')).toBe(0);
    });

    it('maps every budget status to its own icon and anything else to a neutral one', () => {
        const icons = ['Normal', 'Warning', 'Throttled', 'Blocked', 'Exhausted'].map(
            (status) => budgetStatusView(status).icon
        );
        expect(new Set(icons).size).toBe(5);
        expect(budgetStatusView('Blocked')).toEqual({
            label: 'Blocked',
            icon: 'utility:ban',
            variant: 'error',
            badgeClass: 'slds-badge slds-theme_error',
            pillClass: 'ag-pill ag-pill_error'
        });
        expect(budgetStatusView('Bypassed')).toEqual({
            label: 'Bypassed',
            icon: 'utility:info',
            variant: undefined,
            badgeClass: 'slds-badge',
            pillClass: 'ag-pill ag-pill_neutral'
        });
        expect(budgetStatusView(undefined).label).toBe('');
    });

    it('describes breakers, including when an open breaker lets the agent retry', () => {
        const now = Date.parse('2026-09-28T10:00:00.000Z');
        const open = breakerView('OPEN', '2026-09-28T10:30:00.000Z', now);
        expect(open).toMatchObject({ state: 'OPEN', label: 'Open', variant: 'error', rank: 2, isTripped: true });
        expect(open.detail).toBe(`Can retry at ${formatTime('2026-09-28T10:30:00.000Z')}`);
        expect(breakerView('OPEN', '2026-09-28T09:00:00.000Z', now).detail).toBe('Can retry now');
        expect(breakerView('OPEN', null, now).detail).toBe('');
        expect(breakerView('HALF_OPEN', null, now)).toMatchObject({
            label: 'Half-open',
            detail: 'Next request is a trial',
            isTripped: true
        });
        expect(breakerView('CLOSED')).toMatchObject({ label: 'Closed', detail: '', isTripped: false });
        expect(breakerView(undefined).state).toBe('CLOSED');
        expect(retryText('not a date', now)).toBe('');
        // A cooldown that ends on another day shows the date as well as the time.
        expect(retryText('2026-09-30T10:30:00.000Z', now)).toBe(
            `Can retry at ${formatDateTime('2026-09-30T10:30:00.000Z')}`
        );
    });

    it('flags agents whose breaker is not closed or whose budget is blocked or exhausted', () => {
        expect(needsAttention({ breakerState: 'OPEN' })).toBe(true);
        expect(needsAttention({ breakerState: 'HALF_OPEN' })).toBe(true);
        expect(needsAttention({ breakerState: 'CLOSED', budgetStatus: 'Exhausted' })).toBe(true);
        expect(needsAttention({ breakerState: 'CLOSED', budgetStatus: 'Blocked' })).toBe(true);
        expect(needsAttention({ breakerState: 'CLOSED', budgetStatus: 'Throttled' })).toBe(false);
        expect(needsAttention({})).toBe(false);
        expect(needsAttention(undefined)).toBe(false);
    });

    it('formats dates in the Salesforce locale and time zone, and tolerates blanks', () => {
        // Jest supplies en-US and America/Los_Angeles for the @salesforce/i18n imports.
        expect(formatDateTime(null)).toBe('');
        expect(formatDateTime('not a date')).toBe('');
        expect(formatDateTime('2026-09-15T10:00:00.000Z')).toBe(
            new Intl.DateTimeFormat('en-US', {
                dateStyle: 'medium',
                timeStyle: 'short',
                timeZone: 'America/Los_Angeles'
            }).format(new Date('2026-09-15T10:00:00.000Z'))
        );
        expect(formatDateTime('2026-09-15T10:00:00.000Z')).toMatch(/Sep 15, 2026.*3:00\sAM/);
        expect(formatDateTime(new Date('2026-09-15T10:00:05.000Z'), { seconds: true })).toMatch(/3:00:05\sAM/);
        expect(formatTime('2026-09-15T10:00:00.000Z')).toMatch(/^3:00\sAM$/);
        expect(formatTime(undefined)).toBe('');
        // Calendar dates carry no zone: 15 September stays 15 September west of Greenwich.
        expect(formatDate('2026-09-15')).toBe('Tue, Sep 15');
        expect(formatDate('')).toBe('');
        expect(formatCompactDateTime('')).toBe('');
        const now = Date.parse('2026-09-15T18:00:00.000Z');
        expect(formatCompactDateTime('2026-09-15T19:00:00.000Z', now)).toMatch(/^12:00\sPM$/);
        expect(formatNumber(12345)).toBe('12,345');
        expect(formatNumber(undefined)).toBe('0');
        expect(refreshedMessage(new Date('2026-09-15T10:00:05.000Z'))).toMatch(
            /^Refreshed\. Last updated 3:00:05\sAM\.$/
        );
    });

    it('builds record links and follows them inside Lightning Experience', () => {
        expect(recordUrl('a01000000000001AAA')).toBe('/lightning/r/AgentGov_Registration__c/a01000000000001AAA/view');
        expect(recordUrl('a02000000000001AAA', 'AgentGov_Session__c')).toBe(
            '/lightning/r/AgentGov_Session__c/a02000000000001AAA/view'
        );
        expect(recordUrl(undefined)).toBeUndefined();
        expect(recordPageReference('a01000000000001AAA')).toEqual({
            type: 'standard__recordPage',
            attributes: {
                recordId: 'a01000000000001AAA',
                objectApiName: 'AgentGov_Registration__c',
                actionName: 'view'
            }
        });

        const component = { [NavigationMixin.Navigate]: jest.fn() };
        const link = { dataset: { recordId: 'a01000000000001AAA', object: 'AgentGov_Action_Log__c' } };
        const click = { currentTarget: link, button: 0, preventDefault: jest.fn() };
        followRecordLink(component, click);
        expect(click.preventDefault).toHaveBeenCalled();
        expect(component[NavigationMixin.Navigate]).toHaveBeenCalledWith(
            recordPageReference('a01000000000001AAA', 'AgentGov_Action_Log__c')
        );

        // A click with a modifier key is left to the browser, which opens a new tab.
        const newTab = { currentTarget: link, button: 0, metaKey: true, preventDefault: jest.fn() };
        followRecordLink(component, newTab);
        expect(newTab.preventDefault).not.toHaveBeenCalled();
        followRecordLink(component, { currentTarget: { dataset: {} }, preventDefault: jest.fn() });
        expect(component[NavigationMixin.Navigate]).toHaveBeenCalledTimes(1);
    });

    it('returns focus to the element that opened a dialog, or to the fallback', () => {
        const preferred = document.createElement('button');
        const fallback = document.createElement('h2');
        document.body.append(preferred, fallback);
        const preferredFocus = jest.spyOn(preferred, 'focus');
        const fallbackFocus = jest.spyOn(fallback, 'focus');

        restoreFocus(preferred, fallback);
        expect(preferredFocus).toHaveBeenCalledTimes(1);

        preferred.disabled = true;
        restoreFocus(preferred, fallback);
        expect(fallbackFocus).toHaveBeenCalledTimes(1);

        preferred.remove();
        preferred.disabled = false;
        restoreFocus(preferred, fallback);
        expect(fallbackFocus).toHaveBeenCalledTimes(2);
        expect(() => restoreFocus(undefined, undefined)).not.toThrow();
        fallback.remove();
    });

    it('keeps the v1.2 subscription helpers working on top of the shared subscription', async () => {
        const onEvent = jest.fn();
        const handles = await subscribeToAgentGovEvents(onEvent);
        expect(handles.length).toBe(1);
        // One subscription per channel, made with the shared dispatcher rather than per caller.
        expect(subscribe).toHaveBeenCalledTimes(2);
        expect(subscribe).toHaveBeenCalledWith(ALERT_CHANNEL, -1, expect.any(Function));
        expect(subscribe).toHaveBeenCalledWith(ACTION_CHANNEL, -1, expect.any(Function));

        subscribe.mock.calls[0][2]({ data: { payload: {} } });
        expect(onEvent).toHaveBeenCalledTimes(1);

        await unsubscribeFromAgentGovEvents(handles);
        expect(unsubscribe).toHaveBeenCalledTimes(2);

        // Subscriptions made directly with lightning/empApi are still released through it.
        await unsubscribeFromAgentGovEvents([{ id: 'raw' }]);
        expect(unsubscribe).toHaveBeenLastCalledWith({ id: 'raw' });
        await unsubscribeFromAgentGovEvents(undefined);

        isEmpEnabled.mockResolvedValueOnce(false);
        expect(await subscribeToAgentGovEvents(onEvent)).toEqual([]);
        await flushPromises();
    });
});
