/**
 * Shared helpers for the AgentGov Lightning Web Components: error reduction, budget and circuit
 * breaker presentation, date formatting in the viewer's locale and time zone, record links, and
 * the one platform-event subscription that every AgentGov component on a page shares. This is a
 * service module with no template.
 */
import { subscribe, unsubscribe, onError, isEmpEnabled } from 'lightning/empApi';
import { NavigationMixin } from 'lightning/navigation';
import LOCALE from '@salesforce/i18n/locale';
import TIME_ZONE from '@salesforce/i18n/timeZone';

export const ALERT_CHANNEL = '/event/AgentGov_Alert__e';
export const ACTION_CHANNEL = '/event/AgentGov_Action_Event__e';
export const REGISTRATION_OBJECT = 'AgentGov_Registration__c';

// Busy agents publish many events a second. However many arrive, listeners are called at most
// once per interval, so a burst of activity costs each component one refresh every five
// seconds, not one per event.
export const EVENT_REFRESH_INTERVAL_MS = 5000;

// Replay id -1 delivers only events published after the subscription is created.
const REPLAY_NEW_EVENTS_ONLY = -1;

const BUDGET_STATUS_VIEWS = {
    Normal: { icon: 'utility:success', variant: 'success', badgeClass: 'slds-badge slds-theme_success' },
    Warning: { icon: 'utility:warning', variant: 'warning', badgeClass: 'slds-badge slds-theme_warning' },
    Throttled: { icon: 'utility:clock', variant: 'warning', badgeClass: 'slds-badge slds-theme_warning' },
    Blocked: { icon: 'utility:ban', variant: 'error', badgeClass: 'slds-badge slds-theme_error' },
    Exhausted: { icon: 'utility:error', variant: 'error', badgeClass: 'slds-badge slds-theme_error' }
};
const NEUTRAL_STATUS_VIEW = { icon: 'utility:info', variant: undefined, badgeClass: 'slds-badge' };

// Classes of the state pills in c/agentGovStyles, by icon variant.
const PILL_CLASSES = {
    success: 'ag-pill ag-pill_success',
    warning: 'ag-pill ag-pill_warning',
    error: 'ag-pill ag-pill_error',
    info: 'ag-pill ag-pill_info'
};
const NEUTRAL_PILL_CLASS = 'ag-pill ag-pill_neutral';

const AGENT_STATUS_VARIANTS = { Active: 'success', Throttled: 'warning', Blocked: 'error' };

const ALERT_VARIANTS = {
    Warning: 'warning',
    Throttled: 'warning',
    Blocked: 'error',
    Exhausted: 'error',
    'Breaker open': 'error'
};

// Units of the usage maps that Report and Apex rows record as JSON, singular and plural.
const USAGE_UNITS = {
    apiCalls: ['API call', 'API calls'],
    soqlQueries: ['SOQL query', 'SOQL queries'],
    dmlOperations: ['DML operation', 'DML operations'],
    API_Calls: ['API call', 'API calls'],
    SOQL_Queries: ['SOQL query', 'SOQL queries'],
    DML_Operations: ['DML operation', 'DML operations']
};
const ATTENTION_BUDGET_STATUSES = ['Blocked', 'Exhausted'];

const BREAKER_VIEWS = {
    CLOSED: { label: 'Closed', icon: 'utility:success', variant: 'success', rank: 0 },
    HALF_OPEN: { label: 'Half-open', icon: 'utility:warning', variant: 'warning', rank: 1 },
    OPEN: { label: 'Open', icon: 'utility:error', variant: 'error', rank: 2 }
};

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
 * Reduces an error to one line of text for an alert, a toast, or a live region.
 * @param {Error|Object|Array} error
 * @returns {string}
 */
export function describeError(error) {
    return reduceErrors(error).join('. ');
}

/**
 * Joins the distinct messages of a map of errors keyed by source, such as one entry per wire,
 * so one source recovering does not hide another source's failure.
 * @param {Object<string, string>} errorsBySource
 * @returns {string}
 */
export function combineErrors(errorsBySource) {
    return Array.from(new Set(Object.values(errorsBySource || {}).filter((message) => !!message))).join('. ');
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
 * Usage of a budget's most-used limit type, as a rounded percentage clamped to 100. The server
 * decides Budget_Status__c from the same usage, but compares unrounded percentages with each
 * limit type's own thresholds, so a bar drawn from this figure can disagree with the status
 * beside it within half a percent of a threshold, or when the limit types' thresholds differ.
 * @param {Object} budget An AgentGov_Budget__c record
 * @returns {number}
 */
export function peakUsagePercent(budget) {
    if (!budget) {
        return 0;
    }
    return Math.max(
        percentOf(budget.API_Calls_Consumed__c, budget.API_Calls_Allocated__c),
        percentOf(budget.SOQL_Queries_Consumed__c, budget.SOQL_Queries_Allocated__c),
        percentOf(budget.DML_Operations_Consumed__c, budget.DML_Operations_Allocated__c)
    );
}

/**
 * Rounds a percentage computed by the server and clamps it to 0..100 for display.
 * @param {number} value
 * @returns {number}
 */
export function clampPercent(value) {
    const number = Number(value);
    if (!Number.isFinite(number) || number <= 0) {
        return 0;
    }
    return Math.min(100, Math.round(number));
}

/**
 * Presentation of a budget status: icon, icon variant, badge class, and state pill class.
 * Every status the framework writes has its own entry; anything else is shown neutrally.
 * @param {string} status
 * @returns {{label: string, icon: string, variant: string, badgeClass: string, pillClass: string}}
 */
export function budgetStatusView(status) {
    const view = BUDGET_STATUS_VIEWS[status] || NEUTRAL_STATUS_VIEW;
    return { label: status || '', ...view, pillClass: pillClass(view.variant) };
}

/**
 * Class of a state pill for an icon variant: success, warning, error, info, or neutral.
 * @param {string} variant
 * @returns {string}
 */
export function pillClass(variant) {
    return PILL_CLASSES[variant] || NEUTRAL_PILL_CLASS;
}

/**
 * Readable name of an agent type, such as "Custom Apex" for Custom_Apex.
 * @param {string} agentType
 * @returns {string}
 */
export function agentTypeLabel(agentType) {
    return (agentType || '').replace(/_/g, ' ');
}

/**
 * Presentation of an agent's registration status as a pill.
 * @param {string} status Active, Inactive, Throttled, or Blocked
 * @returns {{label: string, pillClass: string}}
 */
export function agentStatusView(status) {
    return { label: status || 'Unknown', pillClass: pillClass(AGENT_STATUS_VARIANTS[status]) };
}

/**
 * Presentation of a circuit breaker: label, icon, variant, a severity rank for sorting, a
 * detail line, and the state pill class. An open breaker's detail says when the agent may retry.
 * @param {string} state CLOSED, OPEN, or HALF_OPEN
 * @param {string} cooldownUntil When the open breaker's cooldown ends
 * @param {number} [now] Current time in milliseconds
 * @returns {{state: string, label: string, icon: string, variant: string, rank: number, detail: string, isTripped: boolean, pillClass: string}}
 */
export function breakerView(state, cooldownUntil, now = Date.now()) {
    const key = BREAKER_VIEWS[state] ? state : 'CLOSED';
    let detail = '';
    if (key === 'OPEN') {
        detail = retryText(cooldownUntil, now);
    } else if (key === 'HALF_OPEN') {
        detail = 'Next request is a trial';
    }
    return {
        state: key,
        ...BREAKER_VIEWS[key],
        detail,
        isTripped: key !== 'CLOSED',
        pillClass: pillClass(BREAKER_VIEWS[key].variant)
    };
}

/**
 * Says when an agent with an open circuit breaker may retry.
 * @param {string} cooldownUntil
 * @param {number} [now] Current time in milliseconds
 * @returns {string}
 */
export function retryText(cooldownUntil, now = Date.now()) {
    const until = toDate(cooldownUntil);
    if (!until) {
        return '';
    }
    return until.getTime() > now ? `Can retry at ${formatCompactDateTime(until, now)}` : 'Can retry now';
}

/**
 * Whether an agent summary needs an operator: its breaker is not closed, or today's budget is
 * Blocked or Exhausted.
 * @param {{breakerState: string, budgetStatus: string}} agent
 * @returns {boolean}
 */
export function needsAttention(agent) {
    const breaker = agent && agent.breakerState ? agent.breakerState : 'CLOSED';
    return breaker !== 'CLOSED' || ATTENTION_BUDGET_STATUSES.includes(agent && agent.budgetStatus);
}

/**
 * Reads an Alert row's details as a pill label, its variant, and a sentence. Alert rows lead
 * with a short label, as in "Blocked: API calls at 95% of today's budget (95 of 100)."; other
 * text is shown whole under the label Alert.
 * @param {string} details
 * @returns {{label: string, variant: string, pillClass: string, text: string}}
 */
export function alertView(details) {
    const text = String(details || '').trim();
    let label = 'Alert';
    let sentence = text;
    const colon = text.indexOf(': ');
    if (colon > 0 && colon <= 20) {
        label = text.slice(0, colon);
        sentence = text.slice(colon + 2);
    }
    const variant = ALERT_VARIANTS[label] || 'info';
    return { label, variant, pillClass: pillClass(variant), text: sentence };
}

/**
 * Turns the usage map that Report and Apex rows record as JSON into a sentence, such as
 * "Used 3 SOQL queries, 1 DML operation". Details that are not such a map are returned as they
 * are.
 * @param {string} details
 * @returns {string}
 */
export function describeDetails(details) {
    const text = String(details || '').trim();
    if (!text.startsWith('{')) {
        return text;
    }
    let usage;
    try {
        usage = JSON.parse(text);
    } catch {
        return text;
    }
    const parts = Object.entries(usage || {})
        .filter(([unit, amount]) => USAGE_UNITS[unit] && Number(amount) > 0)
        .map(([unit, amount]) => `${formatNumber(amount)} ${USAGE_UNITS[unit][Number(amount) === 1 ? 0 : 1]}`);
    if (!parts.length) {
        return Object.keys(usage || {}).some((unit) => USAGE_UNITS[unit]) ? 'No usage' : text;
    }
    return `Used ${parts.join(', ')}`;
}

/**
 * Shortens a long generated identifier, such as a UUID correlation id, to its first eight
 * characters. Ids up to 20 characters, which callers often choose to be readable, stay whole.
 * @param {string} value
 * @returns {string}
 */
export function shortId(value) {
    const text = value ? String(value) : '';
    return text.length > 20 ? `${text.slice(0, 8)}\u2026` : text;
}

// --- Dates ---

const formatters = new Map();
let numberFormat;

function toDate(value) {
    if (value === null || value === undefined || value === '') {
        return null;
    }
    const date = value instanceof Date ? value : new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
}

function formatter(options) {
    const key = JSON.stringify(options);
    if (!formatters.has(key)) {
        formatters.set(key, createFormatter(options));
    }
    return formatters.get(key);
}

function createFormatter(options) {
    const zoned = { timeZone: TIME_ZONE, ...options };
    // The locale and time zone come from the user's Salesforce settings. Intl rejects the rare
    // value it does not know, and one bad setting must not blank every date on the page.
    try {
        return new Intl.DateTimeFormat(LOCALE, zoned);
    } catch {
        try {
            return new Intl.DateTimeFormat(LOCALE, options);
        } catch {
            return new Intl.DateTimeFormat(undefined, options);
        }
    }
}

/**
 * Formats a date-time in the viewer's Salesforce locale and time zone.
 * @param {string|number|Date} value
 * @param {{seconds?: boolean}} [options] Include seconds, for audit rows
 * @returns {string}
 */
export function formatDateTime(value, { seconds = false } = {}) {
    const date = toDate(value);
    return date ? formatter({ dateStyle: 'medium', timeStyle: seconds ? 'medium' : 'short' }).format(date) : '';
}

/**
 * Formats the time of day in the viewer's Salesforce locale and time zone.
 * @param {string|number|Date} value
 * @param {{seconds?: boolean}} [options]
 * @returns {string}
 */
export function formatTime(value, { seconds = false } = {}) {
    const date = toDate(value);
    return date ? formatter({ timeStyle: seconds ? 'medium' : 'short' }).format(date) : '';
}

/**
 * Formats a date-time as a time alone when it falls on the viewer's current day, and as a date
 * and time otherwise.
 * @param {string|number|Date} value
 * @param {number} [now] Current time in milliseconds
 * @param {{seconds?: boolean}} [options] Include seconds, for audit rows
 * @returns {string}
 */
export function formatCompactDateTime(value, now = Date.now(), { seconds = false } = {}) {
    const date = toDate(value);
    if (!date) {
        return '';
    }
    const day = formatter({ dateStyle: 'short' });
    return day.format(date) === day.format(new Date(now))
        ? formatTime(date, { seconds })
        : formatDateTime(date, { seconds });
}

let relativeFormat;

function relativeFormatter() {
    if (!relativeFormat) {
        try {
            relativeFormat = new Intl.RelativeTimeFormat(LOCALE, { numeric: 'auto' });
        } catch {
            relativeFormat = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });
        }
    }
    return relativeFormat;
}

/**
 * Says how long ago a moment was, such as "5 minutes ago", in the viewer's language. A moment
 * up to a minute ahead, as a server clock slightly ahead of the browser's can produce, reads
 * "now".
 * Moments a day or more ago, and moments more than a minute ahead, are shown as a time alone
 * when they fall on the viewer's current day and as a date and time otherwise.
 * @param {string|number|Date} value
 * @param {number} [now] Current time in milliseconds
 * @returns {string}
 */
export function formatRelativeTime(value, now = Date.now()) {
    const date = toDate(value);
    if (!date) {
        return '';
    }
    const seconds = Math.round((now - date.getTime()) / 1000);
    if (seconds < -60 || seconds >= 86400) {
        return formatCompactDateTime(date, now);
    }
    if (seconds < 45) {
        return relativeFormatter().format(0, 'second');
    }
    if (seconds < 3600) {
        return relativeFormatter().format(-Math.max(1, Math.round(seconds / 60)), 'minute');
    }
    return relativeFormatter().format(-Math.round(seconds / 3600), 'hour');
}

/**
 * Formats a calendar date such as an Apex Date ('2026-09-15'). Calendar dates carry no time
 * zone, so they are formatted in UTC; the viewer's zone would move them to the previous day
 * west of Greenwich.
 * @param {string} value
 * @returns {string}
 */
export function formatDate(value) {
    const date = toDate(value);
    return date ? formatter({ weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' }).format(date) : '';
}

/**
 * Formats a count with the viewer's digit grouping. Blank values are shown as 0.
 * @param {number} value
 * @returns {string}
 */
export function formatNumber(value) {
    const number = Number(value);
    if (!numberFormat) {
        try {
            numberFormat = new Intl.NumberFormat(LOCALE, { maximumFractionDigits: 0 });
        } catch {
            numberFormat = new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 });
        }
    }
    return numberFormat.format(Number.isFinite(number) ? number : 0);
}

/**
 * Text for a live region after a refresh the user asked for.
 * @param {Date} when
 * @returns {string}
 */
export function refreshedMessage(when) {
    return `Refreshed. Last updated ${formatTime(when, { seconds: true })}.`;
}

// --- Clock ---

// Relative times such as "5 minutes ago" are recomputed on this beat while the page is open.
export const CLOCK_INTERVAL_MS = 30000;

const clock = { listeners: new Set(), timer: null };

/**
 * Calls the listener with the current time every half minute, so that relative times on the
 * page stay true while nobody touches it. Every component shares one timer, which stops when
 * the last listener leaves.
 * @param {function(number): void} onTick
 * @returns {function(): void} Stops the calls
 */
export function listenToClock(onTick) {
    clock.listeners.add(onTick);
    if (!clock.timer) {
        // A page-wide timer is the only way to age a relative time; it is cleared below.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        clock.timer = setInterval(() => {
            const now = Date.now();
            clock.listeners.forEach((listener) => listener(now));
        }, CLOCK_INTERVAL_MS);
    }
    return () => {
        clock.listeners.delete(onTick);
        if (clock.listeners.size === 0 && clock.timer) {
            clearInterval(clock.timer);
            clock.timer = null;
        }
    };
}

// --- Record links ---

/**
 * Relative Lightning URL of a record's page, used as the href of record links.
 * @param {string} recordId
 * @param {string} [objectApiName]
 * @returns {string|undefined} Undefined when there is no record Id
 */
export function recordUrl(recordId, objectApiName = REGISTRATION_OBJECT) {
    return recordId ? `/lightning/r/${objectApiName}/${recordId}/view` : undefined;
}

/**
 * Page reference for a record's page.
 * @param {string} recordId
 * @param {string} [objectApiName]
 * @returns {Object}
 */
export function recordPageReference(recordId, objectApiName = REGISTRATION_OBJECT) {
    return { type: 'standard__recordPage', attributes: { recordId, objectApiName, actionName: 'view' } };
}

/**
 * Follows a record link inside Lightning Experience. The link carries the record Id in
 * data-record-id and, for objects other than the registration, the object in data-object.
 * Clicks with a modifier key are left to the browser so they can still open a new tab.
 * @param {Object} component A component that extends NavigationMixin
 * @param {Event} event The click
 */
export function followRecordLink(component, event) {
    const link = event.currentTarget;
    const recordId = link && link.dataset ? link.dataset.recordId : undefined;
    if (!recordId || event.button > 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
        return;
    }
    event.preventDefault();
    component[NavigationMixin.Navigate](recordPageReference(recordId, link.dataset.object || REGISTRATION_OBJECT));
}

/**
 * Moves focus to the preferred element when it is still on the page and enabled, and otherwise
 * to the fallback, typically a heading with tabindex="-1". Used after a dialog closes, when the
 * button that opened it may have been removed or disabled by the refresh that followed.
 * @param {HTMLElement} preferred
 * @param {HTMLElement} fallback
 */
export function restoreFocus(preferred, fallback) {
    const target = preferred && preferred.isConnected && !preferred.disabled ? preferred : fallback;
    if (target && typeof target.focus === 'function') {
        target.focus();
    }
}

// --- Platform events ---

// One subscription pair per page, shared by every AgentGov component and reference counted by
// its listeners. state is 'idle' (nothing subscribed), 'opening' (subscribe in flight), or
// 'open' (settled; subscriptions is empty when streaming is unavailable to this user).
const shared = {
    state: 'idle',
    opening: null,
    subscriptions: [],
    listeners: new Set(),
    live: false,
    timer: null,
    pendingEvent: null,
    errorHandlers: new Set(),
    errorHandlerRegistered: false
};

function deliver(message) {
    Array.from(shared.listeners).forEach((listener) => {
        try {
            listener.onEvent(message);
        } catch {
            // One component failing to refresh must not stop the others from refreshing.
        }
    });
}

function startInterval() {
    // Timers are how a throttle works; the interval is cleared when the last listener leaves.
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    shared.timer = setTimeout(() => {
        shared.timer = null;
        if (shared.pendingEvent) {
            const message = shared.pendingEvent;
            shared.pendingEvent = null;
            deliver(message);
            startInterval();
        }
    }, EVENT_REFRESH_INTERVAL_MS);
}

function receive(message) {
    if (shared.timer) {
        shared.pendingEvent = message;
        return;
    }
    deliver(message);
    startInterval();
}

function stopInterval() {
    clearTimeout(shared.timer);
    shared.timer = null;
    shared.pendingEvent = null;
}

function notifyStatus(listener) {
    if (shared.listeners.has(listener) && listener.onStatusChange) {
        listener.onStatusChange(shared.live);
    }
}

function handleStreamingError(error) {
    shared.live = false;
    Array.from(shared.listeners).forEach((listener) => notifyStatus(listener));
    Array.from(shared.errorHandlers).forEach((handler) => handler(error));
}

function registerErrorHandler() {
    if (!shared.errorHandlerRegistered) {
        onError(handleStreamingError);
        shared.errorHandlerRegistered = true;
    }
}

async function openChannels() {
    let enabled = false;
    try {
        enabled = await isEmpEnabled();
    } catch {
        enabled = false;
    }
    if (!enabled) {
        return [];
    }
    registerErrorHandler();
    // allSettled, not all: if one channel is refused the other may still have succeeded, and
    // Promise.all would discard that subscription with no way left to release it.
    const settled = await Promise.allSettled(
        [ALERT_CHANNEL, ACTION_CHANNEL].map(
            (channel) => new Promise((resolve) => resolve(subscribe(channel, REPLAY_NEW_EVENTS_ONLY, receive)))
        )
    );
    return settled.filter((result) => result.status === 'fulfilled' && result.value).map((result) => result.value);
}

function closeChannels(subscriptions) {
    subscriptions.forEach((subscription) => {
        // A failed unsubscribe leaves nothing on this side to clean up.
        new Promise((resolve) => resolve(unsubscribe(subscription))).catch(() => {});
    });
}

function open() {
    if (shared.state === 'idle') {
        shared.state = 'opening';
        shared.opening = openChannels()
            .catch(() => [])
            .then((subscriptions) => {
                shared.opening = null;
                if (shared.listeners.size === 0) {
                    // Every component left while the subscription was being made, so none of them
                    // can release it any more. This is the only place that race is handled.
                    shared.state = 'idle';
                    closeChannels(subscriptions);
                    return;
                }
                shared.state = 'open';
                shared.subscriptions = subscriptions;
                shared.live = subscriptions.length > 0;
            });
    }
    return shared.opening || Promise.resolve();
}

function release(listener) {
    if (!shared.listeners.delete(listener) || shared.listeners.size > 0) {
        return;
    }
    stopInterval();
    if (shared.state !== 'open') {
        // Still opening: the open in flight sees there are no listeners and releases its result.
        return;
    }
    const subscriptions = shared.subscriptions;
    shared.state = 'idle';
    shared.subscriptions = [];
    shared.live = false;
    closeChannels(subscriptions);
}

/**
 * Calls onEvent when agents act or alerts fire, at most once per EVENT_REFRESH_INTERVAL_MS
 * and with the latest event when several arrived. Every AgentGov component on the page shares
 * one subscription to the two channels: the first listener creates it and the last one to
 * leave releases it. Call the returned function from disconnectedCallback.
 * @param {(event: Object) => void} onEvent
 * @param {(live: boolean) => void} [onStatusChange] Told whether live updates are on, once the
 *        subscription settles and whenever streaming fails
 * @returns {() => void} Releases the listener; calling it again does nothing
 */
export function listenToAgentGovEvents(onEvent, onStatusChange) {
    const listener = { onEvent, onStatusChange };
    shared.listeners.add(listener);
    open().then(() => notifyStatus(listener));
    return () => release(listener);
}

/**
 * Listens to both AgentGov platform-event channels through the page's shared subscription, so
 * the callback runs at most once every EVENT_REFRESH_INTERVAL_MS (five seconds), with the
 * latest event when several arrived; the others are not delivered. Kept for code written
 * against v1.2; new code uses listenToAgentGovEvents, and code that needs every event
 * subscribes through lightning/empApi directly. Resolves to a handle list for
 * unsubscribeFromAgentGovEvents, or to an empty list when streaming is unavailable to this user.
 * @param {(event: Object) => void} onEvent
 * @returns {Promise<Object[]>}
 */
export function subscribeToAgentGovEvents(onEvent) {
    const handle = { release: listenToAgentGovEvents(onEvent) };
    return open().then(() => {
        if (!shared.live) {
            handle.release();
            return [];
        }
        return [handle];
    });
}

/**
 * Releases what subscribeToAgentGovEvents returned. Subscriptions made directly with
 * lightning/empApi are passed to its unsubscribe, as before.
 * @param {Object[]} subscriptions
 * @returns {Promise<Object[]>}
 */
export function unsubscribeFromAgentGovEvents(subscriptions) {
    return Promise.all(
        (subscriptions || []).map((subscription) => {
            if (subscription && typeof subscription.release === 'function') {
                subscription.release();
                return subscription;
            }
            return unsubscribe(subscription);
        })
    );
}

/**
 * Registers a handler for streaming errors so a component can show that live updates stopped.
 * Listeners of listenToAgentGovEvents are told through their status callback instead.
 * @param {(error: Object) => void} handler
 */
export function onStreamingError(handler) {
    shared.errorHandlers.add(handler);
    registerErrorHandler();
}
