import {
    listenToAgentGovEvents,
    onStreamingError,
    EVENT_REFRESH_INTERVAL_MS,
    ALERT_CHANNEL,
    ACTION_CHANNEL
} from 'c/agentGovUtils';
import { subscribe, unsubscribe, onError, isEmpEnabled } from 'lightning/empApi';

// The shared subscription lives at module level, so every spec releases what it registers.
// Timers are faked, so pending promises are flushed with the real setImmediate, which runs
// only once every queued microtask has run.
const { setImmediate: realSetImmediate } = jest.requireActual('timers');
const settle = () => new Promise((resolve) => realSetImmediate(resolve));

function deferred() {
    let resolve;
    const promise = new Promise((done) => {
        resolve = done;
    });
    return { promise, resolve };
}

describe('agentGovUtils shared platform-event subscription', () => {
    let streamingErrorHandler;

    beforeEach(() => {
        jest.useFakeTimers();
    });

    afterEach(() => {
        jest.clearAllTimers();
        jest.useRealTimers();
        subscribe.mockReset();
        subscribe.mockImplementation((channel) => Promise.resolve({ id: `subscription-${channel}`, channel }));
        unsubscribe.mockClear();
        isEmpEnabled.mockReset();
        isEmpEnabled.mockImplementation(() => Promise.resolve(true));
    });

    it('subscribes once for every listener on the page and releases with the last one', async () => {
        const first = jest.fn();
        const second = jest.fn();
        const firstStatus = jest.fn();
        const releaseFirst = listenToAgentGovEvents(first, firstStatus);
        const releaseSecond = listenToAgentGovEvents(second);
        await settle();

        expect(subscribe).toHaveBeenCalledTimes(2);
        expect(subscribe.mock.calls.map((call) => call[0]).sort()).toEqual([ACTION_CHANNEL, ALERT_CHANNEL]);
        expect(firstStatus).toHaveBeenCalledWith(true);
        // The streaming error handler is registered once, when the first subscription is made.
        expect(onError).toHaveBeenCalledTimes(1);
        streamingErrorHandler = onError.mock.calls[0][0];

        subscribe.mock.calls[0][2]({ data: { payload: {} } });
        expect(first).toHaveBeenCalledTimes(1);
        expect(second).toHaveBeenCalledTimes(1);

        releaseFirst();
        expect(unsubscribe).not.toHaveBeenCalled();
        releaseFirst();
        expect(unsubscribe).not.toHaveBeenCalled();
        releaseSecond();
        expect(unsubscribe).toHaveBeenCalledTimes(2);
    });

    it('releases a subscription that settles after every listener has already left', async () => {
        const pending = deferred();
        subscribe.mockImplementation((channel) => pending.promise.then(() => ({ id: channel })));
        const status = jest.fn();
        const release = listenToAgentGovEvents(jest.fn(), status);
        await settle();
        release();
        expect(unsubscribe).not.toHaveBeenCalled();

        pending.resolve();
        await settle();
        // Nothing else would ever release it, so the shared module does.
        expect(unsubscribe).toHaveBeenCalledTimes(2);
        expect(status).not.toHaveBeenCalled();
    });

    it('keeps a subscription that settles after a new listener arrived', async () => {
        const pending = deferred();
        subscribe.mockImplementation((channel) => pending.promise.then(() => ({ id: channel })));
        const releaseFirst = listenToAgentGovEvents(jest.fn());
        await settle();
        releaseFirst();
        const second = jest.fn();
        const secondStatus = jest.fn();
        const releaseSecond = listenToAgentGovEvents(second, secondStatus);

        pending.resolve();
        await settle();
        expect(subscribe).toHaveBeenCalledTimes(2);
        expect(unsubscribe).not.toHaveBeenCalled();
        expect(secondStatus).toHaveBeenCalledWith(true);

        releaseSecond();
        expect(unsubscribe).toHaveBeenCalledTimes(2);
    });

    it('refreshes at most once per interval however many events arrive', async () => {
        const listener = jest.fn();
        const release = listenToAgentGovEvents(listener);
        await settle();
        const receive = subscribe.mock.calls[0][2];

        receive({ data: { n: 1 } });
        expect(listener).toHaveBeenCalledTimes(1);
        receive({ data: { n: 2 } });
        receive({ data: { n: 3 } });
        expect(listener).toHaveBeenCalledTimes(1);

        jest.advanceTimersByTime(EVENT_REFRESH_INTERVAL_MS - 1);
        expect(listener).toHaveBeenCalledTimes(1);
        jest.advanceTimersByTime(1);
        // One trailing call, with the latest event.
        expect(listener).toHaveBeenCalledTimes(2);
        expect(listener).toHaveBeenLastCalledWith({ data: { n: 3 } });

        // The trailing call starts a new interval, so an event right after it waits too.
        receive({ data: { n: 4 } });
        expect(listener).toHaveBeenCalledTimes(2);
        jest.advanceTimersByTime(EVENT_REFRESH_INTERVAL_MS);
        expect(listener).toHaveBeenCalledTimes(3);

        // A quiet interval ends without a call, and the next event is delivered at once.
        jest.advanceTimersByTime(EVENT_REFRESH_INTERVAL_MS);
        expect(listener).toHaveBeenCalledTimes(3);
        receive({ data: { n: 5 } });
        expect(listener).toHaveBeenCalledTimes(4);

        release();
    });

    it('drops a pending event when the last listener leaves', async () => {
        const listener = jest.fn();
        const release = listenToAgentGovEvents(listener);
        await settle();
        const receive = subscribe.mock.calls[0][2];
        receive({});
        receive({});
        release();
        jest.advanceTimersByTime(EVENT_REFRESH_INTERVAL_MS);
        expect(listener).toHaveBeenCalledTimes(1);
    });

    it('keeps delivering to the other listeners when one of them throws', async () => {
        const failing = jest.fn(() => {
            throw new Error('refresh failed');
        });
        const healthy = jest.fn();
        const releaseFailing = listenToAgentGovEvents(failing);
        const releaseHealthy = listenToAgentGovEvents(healthy);
        await settle();
        subscribe.mock.calls[0][2]({});
        expect(healthy).toHaveBeenCalledTimes(1);
        releaseFailing();
        releaseHealthy();
    });

    it('reports live updates as off when streaming is unavailable, without subscribing', async () => {
        isEmpEnabled.mockResolvedValue(false);
        const status = jest.fn();
        const release = listenToAgentGovEvents(jest.fn(), status);
        await settle();
        expect(subscribe).not.toHaveBeenCalled();
        expect(status).toHaveBeenCalledWith(false);

        // A second component joining later is told the same, without another attempt.
        const lateStatus = jest.fn();
        const releaseLate = listenToAgentGovEvents(jest.fn(), lateStatus);
        await settle();
        expect(lateStatus).toHaveBeenCalledWith(false);
        expect(isEmpEnabled).toHaveBeenCalledTimes(1);
        release();
        releaseLate();
        expect(unsubscribe).not.toHaveBeenCalled();
    });

    it('treats a failing availability check as streaming being unavailable', async () => {
        isEmpEnabled.mockRejectedValue(new Error('no streaming'));
        const status = jest.fn();
        const release = listenToAgentGovEvents(jest.fn(), status);
        await settle();
        expect(status).toHaveBeenCalledWith(false);
        release();
    });

    it('stays live on one channel when the other is refused, and releases only that one', async () => {
        subscribe.mockImplementationOnce(() => Promise.reject(new Error('refused')));
        subscribe.mockImplementationOnce(() => {
            throw new Error('thrown synchronously');
        });
        const status = jest.fn();
        const release = listenToAgentGovEvents(jest.fn(), status);
        await settle();
        expect(status).toHaveBeenCalledWith(false);
        release();
        expect(unsubscribe).not.toHaveBeenCalled();

        subscribe.mockImplementationOnce(() => Promise.reject(new Error('refused')));
        const liveStatus = jest.fn();
        const releaseLive = listenToAgentGovEvents(jest.fn(), liveStatus);
        await settle();
        expect(liveStatus).toHaveBeenCalledWith(true);
        releaseLive();
        expect(unsubscribe).toHaveBeenCalledTimes(1);
    });

    it('tells every listener and error handler when streaming fails', async () => {
        const status = jest.fn();
        const errorHandler = jest.fn();
        onStreamingError(errorHandler);
        const release = listenToAgentGovEvents(jest.fn(), status);
        await settle();
        expect(status).toHaveBeenLastCalledWith(true);

        streamingErrorHandler({ error: 'connection lost' });
        expect(status).toHaveBeenLastCalledWith(false);
        expect(errorHandler).toHaveBeenCalledWith({ error: 'connection lost' });
        release();
    });

    it('ignores an unsubscribe failure', async () => {
        unsubscribe.mockImplementationOnce(() => Promise.reject(new Error('already gone')));
        unsubscribe.mockImplementationOnce(() => {
            throw new Error('thrown synchronously');
        });
        const release = listenToAgentGovEvents(jest.fn());
        await settle();
        expect(() => release()).not.toThrow();
        await settle();
        expect(unsubscribe).toHaveBeenCalledTimes(2);
    });
});
