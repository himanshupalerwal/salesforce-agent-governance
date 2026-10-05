import {
    alertView,
    agentStatusView,
    breakerView,
    budgetStatusView,
    describeDetails,
    formatRelativeTime,
    listenToClock,
    CLOCK_INTERVAL_MS,
    pillClass,
    shortId
} from 'c/agentGovUtils';

jest.mock('@salesforce/i18n/locale', () => ({ default: 'en-US' }), { virtual: true });
jest.mock('@salesforce/i18n/timeZone', () => ({ default: 'America/New_York' }), { virtual: true });

const NOW = Date.parse('2026-09-28T16:00:00.000Z');

describe('agentGovUtils presentation helpers', () => {
    describe('alertView', () => {
        it('splits a current alert into its label and sentence', () => {
            const view = alertView("Blocked: API calls at 95% of today's budget (95 of 100).");
            expect(view.label).toBe('Blocked');
            expect(view.text).toBe("API calls at 95% of today's budget (95 of 100).");
            expect(view.variant).toBe('error');
            expect(view.pillClass).toBe('ag-pill ag-pill_error');
        });

        it('gives a throttled budget a warning and an open breaker an error', () => {
            const throttled = alertView("Throttled: SOQL queries at 90% of today's budget (18 of 20).");
            expect(throttled.label).toBe('Throttled');
            expect(throttled.variant).toBe('warning');
            const breaker = alertView('Breaker open: 3 failures reached the threshold of 3.');
            expect(breaker.label).toBe('Breaker open');
            expect(breaker.text).toBe('3 failures reached the threshold of 3.');
            expect(breaker.variant).toBe('error');
        });

        it('shows other text whole, as an informational alert', () => {
            const view = alertView('Something the framework reported');
            expect(view.label).toBe('Alert');
            expect(view.text).toBe('Something the framework reported');
            expect(view.pillClass).toBe('ag-pill ag-pill_info');
            expect(alertView(null).text).toBe('');
            // A colon further in than a label would reach is part of the sentence.
            const long = 'Block alert for agent Order Sync Agent: Circuit_Breaker at 100.00% (3.0 of 3.0)';
            expect(alertView(long)).toMatchObject({ label: 'Alert', text: long });
        });
    });

    describe('describeDetails', () => {
        it('turns a reported usage map into a sentence, in singular and plural', () => {
            expect(describeDetails('{"apiCalls":2,"soqlQueries":1,"dmlOperations":null}')).toBe(
                'Used 2 API calls, 1 SOQL query'
            );
            expect(describeDetails('{"SOQL_Queries":3,"DML_Operations":1}')).toBe(
                'Used 3 SOQL queries, 1 DML operation'
            );
        });

        it('says so when a usage report carried no usage', () => {
            expect(describeDetails('{"dmlOperations":null,"soqlQueries":null,"apiCalls":0}')).toBe('No usage');
        });

        it('leaves text, other JSON and malformed JSON as they are', () => {
            expect(describeDetails('Circuit breaker reset from the console.')).toBe(
                'Circuit breaker reset from the console.'
            );
            expect(describeDetails('{"other":1}')).toBe('{"other":1}');
            expect(describeDetails('{not json')).toBe('{not json');
            expect(describeDetails(undefined)).toBe('');
        });
    });

    describe('formatRelativeTime', () => {
        it('says how long ago a recent moment was', () => {
            expect(formatRelativeTime(NOW - 10 * 1000, NOW)).toBe('now');
            expect(formatRelativeTime(NOW - 60 * 1000, NOW)).toBe('1 minute ago');
            expect(formatRelativeTime(NOW - 5 * 60 * 1000, NOW)).toBe('5 minutes ago');
            expect(formatRelativeTime(NOW - 3 * 3600 * 1000, NOW)).toBe('3 hours ago');
        });

        it('reads "now" up to a minute ahead, and dates a moment a day or more ago or later today', () => {
            expect(formatRelativeTime(NOW + 30 * 1000, NOW)).toBe('now');
            expect(formatRelativeTime(NOW - 2 * 86400 * 1000, NOW)).toBe('Sep 26, 2026, 12:00 PM');
            // Later on the viewer's current day, the time alone.
            expect(formatRelativeTime(NOW + 3600 * 1000, NOW)).toBe('1:00 PM');
            expect(formatRelativeTime(NOW + 2 * 86400 * 1000, NOW)).toBe('Sep 30, 2026, 12:00 PM');
        });

        it('is blank for a missing or invalid value', () => {
            expect(formatRelativeTime(null, NOW)).toBe('');
            expect(formatRelativeTime('not a date', NOW)).toBe('');
        });
    });

    describe('pills', () => {
        it('maps each icon variant to a pill, and anything else to neutral', () => {
            expect(pillClass('success')).toBe('ag-pill ag-pill_success');
            expect(pillClass('warning')).toBe('ag-pill ag-pill_warning');
            expect(pillClass('error')).toBe('ag-pill ag-pill_error');
            expect(pillClass('info')).toBe('ag-pill ag-pill_info');
            expect(pillClass(undefined)).toBe('ag-pill ag-pill_neutral');
        });

        it('gives budget, breaker and agent states the pill of their severity', () => {
            expect(budgetStatusView('Blocked').pillClass).toBe('ag-pill ag-pill_error');
            expect(budgetStatusView('Normal').pillClass).toBe('ag-pill ag-pill_success');
            expect(budgetStatusView('Unknown').pillClass).toBe('ag-pill ag-pill_neutral');
            expect(breakerView('OPEN', null, NOW).pillClass).toBe('ag-pill ag-pill_error');
            expect(breakerView('HALF_OPEN', null, NOW).pillClass).toBe('ag-pill ag-pill_warning');
            expect(agentStatusView('Active')).toEqual({ label: 'Active', pillClass: 'ag-pill ag-pill_success' });
            expect(agentStatusView('Inactive').pillClass).toBe('ag-pill ag-pill_neutral');
            expect(agentStatusView('Throttled').pillClass).toBe('ag-pill ag-pill_warning');
            expect(agentStatusView('Blocked').pillClass).toBe('ag-pill ag-pill_error');
            expect(agentStatusView(undefined).label).toBe('Unknown');
        });
    });

    describe('shortId', () => {
        it('shortens a long generated id to its first eight characters and keeps readable ones', () => {
            expect(shortId('79cd10be-3dde-4a59-a412-09622542986e')).toBe('79cd10be…');
            expect(shortId('demo-run-Lead')).toBe('demo-run-Lead');
            expect(shortId(null)).toBe('');
        });
    });

    describe('listenToClock', () => {
        afterEach(() => {
            jest.useRealTimers();
        });

        it('ticks every listener on one shared timer and stops when the last one leaves', () => {
            jest.useFakeTimers();
            const first = jest.fn();
            const second = jest.fn();
            const stopFirst = listenToClock(first);
            const stopSecond = listenToClock(second);
            jest.advanceTimersByTime(CLOCK_INTERVAL_MS);
            expect(first).toHaveBeenCalledTimes(1);
            expect(second).toHaveBeenCalledTimes(1);
            expect(jest.getTimerCount()).toBe(1);

            stopFirst();
            jest.advanceTimersByTime(CLOCK_INTERVAL_MS);
            expect(first).toHaveBeenCalledTimes(1);
            expect(second).toHaveBeenCalledTimes(2);

            stopSecond();
            expect(jest.getTimerCount()).toBe(0);
        });
    });
});
