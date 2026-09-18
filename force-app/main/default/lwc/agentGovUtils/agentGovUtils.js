/**
 * Shared helpers for the AgentGov Lightning Web Components: error reduction, usage
 * classification, date formatting, and the platform-event subscription that keeps the
 * dashboards live. This is a service module with no template.
 */
import { subscribe, unsubscribe, onError, isEmpEnabled } from 'lightning/empApi';

export const ALERT_CHANNEL = '/event/AgentGov_Alert__e';
export const ACTION_CHANNEL = '/event/AgentGov_Action_Event__e';

// Replay id -1 delivers only events published after the subscription is created.
const REPLAY_NEW_EVENTS_ONLY = -1;

/**
 * Flattens the many shapes a Lightning error can take into a list of messages.
 * Handles wire/imperative Apex errors, UI API errors, and plain JavaScript errors.
 * @param {Error|Object|Array} errors
 * @returns {string[]}
 */
export function reduceErrors(errors) {
    if (!Array.isArray(errors)) {
        errors = [errors];
    }
    return errors
        .filter((error) => !!error)
        .map((error) => {
            if (Array.isArray(error.body)) {
                return error.body.map((e) => e.message);
            }
            if (error.body && Array.isArray(error.body.pageErrors) && error.body.pageErrors.length) {
                return error.body.pageErrors.map((e) => e.message);
            }
            if (error.body && typeof error.body.message === 'string') {
                return error.body.message;
            }
            if (typeof error.message === 'string') {
                return error.message;
            }
            return error.statusText || 'Unknown error';
        })
        .reduce((all, current) => all.concat(current), [])
        .filter((message) => !!message);
}

/**
 * Classifies a usage percentage for styling: normal, warning, or danger.
 * @param {number} value
 * @returns {'normal'|'warning'|'danger'}
 */
export function usageLevel(value) {
    // These match the framework's own default thresholds in AgentGovConstants: Warning at
    // 80, Throttled at 90, Blocked at 95. Using different numbers here made the bar colour
    // contradict the status label printed next to it.
    if (value >= 95) {
        return 'danger';
    }
    if (value >= 80) {
        return 'warning';
    }
    return 'normal';
}

/**
 * Rounded percentage of consumed over allocated, clamped to 100. A zero allocation with any
 * consumption is reported as 100, matching the Apex budget rule.
 * @param {number} consumed
 * @param {number} allocated
 * @returns {number}
 */
export function percentOf(consumed, allocated) {
    const used = consumed || 0;
    const total = allocated || 0;
    if (total <= 0) {
        // Mirrors the Apex rule: a zero allocation means the limit type is not available to
        // this agent, so any consumption at all is full usage.
        return used > 0 ? 100 : 0;
    }
    // Clamped to 100. Consumption that crossed a limit is persisted before the denial, so
    // the raw ratio can exceed 100 and would otherwise drive aria-valuenow past its declared
    // aria-valuemax and stretch a progress bar beyond its track.
    return Math.min(100, Math.round((used / total) * 100));
}

/**
 * Formats an ISO date-time for display in the viewer's locale.
 * @param {string} value
 * @returns {string}
 */
export function formatDateTime(value) {
    return value ? new Date(value).toLocaleString() : '';
}

/**
 * Subscribes to both AgentGov platform-event channels so a component can refresh when
 * agents act or alerts fire. Resolves to the subscriptions, or to an empty list when the
 * streaming API is unavailable for this user.
 * @param {(event: Object) => void} onEvent
 * @returns {Promise<Object[]>}
 */
export async function subscribeToAgentGovEvents(onEvent) {
    const enabled = await isEmpEnabled();
    if (!enabled) {
        return [];
    }
    // allSettled, not all: if one channel is refused the other may still have succeeded, and
    // Promise.all would discard that subscription with no way left to release it.
    const settled = await Promise.allSettled(
        [ALERT_CHANNEL, ACTION_CHANNEL].map((channel) => subscribe(channel, REPLAY_NEW_EVENTS_ONLY, onEvent))
    );
    return settled.filter((result) => result.status === 'fulfilled').map((result) => result.value);
}

/**
 * Releases subscriptions created by subscribeToAgentGovEvents.
 * @param {Object[]} subscriptions
 * @returns {Promise<Object[]>}
 */
export function unsubscribeFromAgentGovEvents(subscriptions) {
    return Promise.all((subscriptions || []).map((subscription) => unsubscribe(subscription)));
}

/**
 * Registers a handler for streaming errors so a component can show that live updates stopped.
 * @param {(error: Object) => void} handler
 */
export function onStreamingError(handler) {
    onError(handler);
}
