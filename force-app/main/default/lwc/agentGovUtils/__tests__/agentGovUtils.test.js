import {
    reduceErrors,
    usageLevel,
    percentOf,
    formatDateTime,
    subscribeToAgentGovEvents,
    unsubscribeFromAgentGovEvents,
    ALERT_CHANNEL,
    ACTION_CHANNEL
} from 'c/agentGovUtils';
import { subscribe, unsubscribe, isEmpEnabled } from 'lightning/empApi';

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

    it('formats dates and tolerates blanks', () => {
        expect(formatDateTime(null)).toBe('');
        expect(formatDateTime('2026-09-15T10:00:00.000Z')).not.toBe('');
    });

    it('subscribes to both channels when streaming is enabled and to none otherwise', async () => {
        const onEvent = jest.fn();
        const subscriptions = await subscribeToAgentGovEvents(onEvent);
        expect(subscriptions.length).toBe(2);
        expect(subscribe).toHaveBeenCalledWith(ALERT_CHANNEL, -1, onEvent);
        expect(subscribe).toHaveBeenCalledWith(ACTION_CHANNEL, -1, onEvent);

        await unsubscribeFromAgentGovEvents(subscriptions);
        expect(unsubscribe).toHaveBeenCalledTimes(2);

        isEmpEnabled.mockResolvedValueOnce(false);
        expect(await subscribeToAgentGovEvents(onEvent)).toEqual([]);
    });
});
