/**
 * The AgentGov action log, newest first: every governed action, denial, alert, and console
 * action, with filters for status, action type, time window, and correlation id. The reason for
 * a failure or denial is shown in the row. Rows are paged by keyset (CreatedDate, Id), so
 * "Load more" stays fast on a large log. With a recordId it shows one agent's rows under the
 * heading "Recent activity".
 *
 * The first page is wired, so refreshApex and platform events keep it current; later pages are
 * fetched on request and kept when the first page refreshes. Reads go through the cacheable,
 * USER_MODE AgentGovDashboardController.getActionLogs.
 */
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getActionLogs from '@salesforce/apex/AgentGovDashboardController.getActionLogs';
import {
    alertView,
    combineErrors,
    describeDetails,
    describeError,
    followRecordLink,
    formatCompactDateTime,
    formatDateTime,
    formatNumber,
    formatTime,
    listenToAgentGovEvents,
    pillClass,
    recordUrl,
    refreshedMessage,
    shortId
} from 'c/agentGovUtils';

const LOG_OBJECT = 'AgentGov_Action_Log__c';
// The table scrolls inside its own frame, so a page of this size keeps the tab short.
const CONSOLE_PAGE_SIZE = 50;
const RECORD_PAGE_SIZE = 25;
const DEFAULT_WINDOW_HOURS = 24;
const MAX_REASON_LENGTH = 500;

const ACTION_TYPE_LABELS = {
    Query: 'Query',
    Create: 'Create',
    Update: 'Update',
    Delete: 'Delete',
    Upsert: 'Upsert',
    API_Call: 'API call',
    Flow_Trigger: 'Flow trigger',
    Report: 'Report',
    Apex: 'Apex',
    Alert: 'Alert',
    Admin: 'Admin',
    System: 'System'
};
// The comboboxes use ALL for "no filter", because an empty value shows the placeholder instead
// of the option's label; the Apex method takes a blank value to mean no filter.
const ALL = 'all';
const STATUS_OPTIONS = [
    { label: 'All statuses', value: ALL },
    { label: 'Success', value: 'Success' },
    { label: 'Failure', value: 'Failure' },
    { label: 'Denied', value: 'Denied' },
    { label: 'Throttled', value: 'Throttled' }
];
const TYPE_OPTIONS = [
    { label: 'All action types', value: ALL },
    ...Object.keys(ACTION_TYPE_LABELS).map((value) => ({ label: ACTION_TYPE_LABELS[value], value }))
];
const WINDOW_OPTIONS = [
    { label: 'Last hour', value: '1' },
    { label: 'Last 24 hours', value: '24' },
    { label: 'Last 7 days', value: '168' },
    { label: 'Last 30 days', value: '720' }
];
const STATUS_VARIANTS = { Success: 'success', Failure: 'error', Denied: 'error', Throttled: 'warning' };

// Newest first, as the server pages: CreatedDate descending, then Id descending. CreatedDate
// arrives in one ISO format, so comparing the strings compares the instants.
function compareRows(a, b) {
    if (a.CreatedDate !== b.CreatedDate) {
        return a.CreatedDate < b.CreatedDate ? 1 : -1;
    }
    if (a.Id === b.Id) {
        return 0;
    }
    return a.Id < b.Id ? 1 : -1;
}

function mergeRows(first, second) {
    const byId = new Map();
    [...first, ...second].forEach((row) => {
        if (!byId.has(row.Id)) {
            byId.set(row.Id, row);
        }
    });
    return Array.from(byId.values()).sort(compareRows);
}

// Alert rows read as their label and sentence; usage reports as a sentence rather than JSON.
function describeReason(row) {
    if (row.Action_Type__c === 'Alert') {
        const alert = alertView(row.Details__c);
        return alert.text ? `${alert.label}: ${alert.text}` : '';
    }
    return describeDetails(row.Details__c);
}

function shorten(text) {
    return text.length > MAX_REASON_LENGTH ? `${text.slice(0, MAX_REASON_LENGTH)}…` : text;
}

export default class AgentGovActivityLog extends NavigationMixin(LightningElement) {
    statusOptions = STATUS_OPTIONS;
    typeOptions = TYPE_OPTIONS;
    windowOptions = WINDOW_OPTIONS;

    agentId = null;
    focusToken = 0;
    focusPending = false;
    pageSize = CONSOLE_PAGE_SIZE;
    statusFilter = '';
    typeFilter = '';
    windowHours = DEFAULT_WINDOW_HOURS;
    correlationFilter = '';
    correlationDraft = '';

    rows = [];
    hasMore = false;
    extraPagesLoaded = false;
    rowsKey;
    wiredFirstPage;

    errors = {};
    lastUpdated;
    announcement = '';
    refreshing = false;
    loadingMore = false;

    /**
     * The agent whose rows to show. Without it, every agent's rows are shown.
     * @type {string}
     */
    @api
    get recordId() {
        return this.agentId || undefined;
    }
    set recordId(value) {
        this.agentId = value || null;
        this.pageSize = value ? RECORD_PAGE_SIZE : CONSOLE_PAGE_SIZE;
    }

    /**
     * Moves focus to the log's heading after the next render whenever the value changes. The
     * console increments it when a key figure opens this tab.
     * @type {number}
     */
    @api
    get focusRequest() {
        return this.focusToken;
    }
    set focusRequest(value) {
        if (value && value !== this.focusToken) {
            this.focusPending = true;
        }
        this.focusToken = value;
    }

    @wire(getActionLogs, {
        registrationId: '$agentId',
        status: '$statusFilter',
        actionType: '$typeFilter',
        windowHours: '$windowHours',
        correlationId: '$correlationFilter',
        beforeCreatedDate: null,
        beforeId: null,
        pageSize: '$pageSize'
    })
    handleFirstPage(result) {
        this.wiredFirstPage = result;
        const key = this.queryKey;
        if (result.error) {
            this.setError('load', result.error);
            if (this.rowsKey !== key) {
                this.rows = [];
                this.hasMore = false;
                this.rowsKey = key;
            }
            return;
        }
        if (result.data) {
            this.clearError('load');
            const fresh = result.data.rows || [];
            if (key === this.rowsKey && this.extraPagesLoaded) {
                // A refresh of the first page. Rows are never edited, so the pages already
                // loaded stay valid: new rows are merged in above them.
                this.rows = mergeRows(fresh, this.rows);
            } else {
                this.rows = fresh;
                this.hasMore = !!result.data.hasMore;
                this.extraPagesLoaded = false;
                this.rowsKey = key;
            }
            this.lastUpdated = new Date();
        }
    }

    connectedCallback() {
        this.releaseEvents = listenToAgentGovEvents(() => this.refresh());
    }

    disconnectedCallback() {
        if (this.releaseEvents) {
            this.releaseEvents();
            this.releaseEvents = undefined;
        }
    }

    renderedCallback() {
        if (this.focusPending && this.refs && this.refs.heading) {
            this.focusPending = false;
            this.refs.heading.focus();
        }
    }

    /**
     * Reloads the newest rows, keeping any older pages already loaded.
     * @returns {Promise}
     */
    @api
    async refresh() {
        if (!this.wiredFirstPage) {
            return;
        }
        try {
            await refreshApex(this.wiredFirstPage);
            this.clearError('refresh');
            this.lastUpdated = new Date();
        } catch (error) {
            this.setError('refresh', error);
        }
    }

    async handleRefresh() {
        this.refreshing = true;
        try {
            await this.refresh();
            if (!this.errors.refresh) {
                this.announcement = refreshedMessage(this.lastUpdated);
            }
        } finally {
            this.refreshing = false;
        }
    }

    handleStatusChange(event) {
        this.statusFilter = event.detail.value === ALL ? '' : event.detail.value;
    }

    handleTypeChange(event) {
        this.typeFilter = event.detail.value === ALL ? '' : event.detail.value;
    }

    handleWindowChange(event) {
        this.windowHours = parseInt(event.detail.value, 10) || DEFAULT_WINDOW_HOURS;
    }

    handleCorrelationInput(event) {
        this.correlationDraft = event.detail.value || '';
        if (!this.correlationDraft) {
            this.correlationFilter = '';
        }
    }

    handleCorrelationCommit() {
        this.correlationFilter = this.correlationDraft.trim();
    }

    handleCorrelationClick(event) {
        this.correlationFilter = event.currentTarget.dataset.correlation;
        this.correlationDraft = this.correlationFilter;
        this.announcement = `Showing the rows of request ${this.correlationFilter}.`;
    }

    handleClearFilters() {
        this.statusFilter = '';
        this.typeFilter = '';
        this.windowHours = DEFAULT_WINDOW_HOURS;
        this.correlationFilter = '';
        this.correlationDraft = '';
    }

    handleRecordLink(event) {
        followRecordLink(this, event);
    }

    async handleLoadMore() {
        const last = this.rows[this.rows.length - 1];
        if (!last || this.loadingMore) {
            return;
        }
        const key = this.queryKey;
        this.loadingMore = true;
        try {
            const page = await getActionLogs({
                registrationId: this.agentId,
                status: this.statusFilter,
                actionType: this.typeFilter,
                windowHours: this.windowHours,
                correlationId: this.correlationFilter,
                beforeCreatedDate: last.CreatedDate,
                beforeId: last.Id,
                pageSize: this.pageSize
            });
            if (key !== this.queryKey) {
                // The filters changed while the page loaded; it belongs to the old query.
                return;
            }
            const added = (page && page.rows) || [];
            this.rows = mergeRows(this.rows, added);
            this.hasMore = !!(page && page.hasMore);
            this.extraPagesLoaded = true;
            this.clearError('more');
            this.announcement = added.length === 1 ? 'Loaded 1 more row.' : `Loaded ${added.length} more rows.`;
        } catch (error) {
            this.setError('more', error);
        } finally {
            this.loadingMore = false;
        }
    }

    // --- View state ---

    get queryKey() {
        return [this.agentId, this.statusFilter, this.typeFilter, this.windowHours, this.correlationFilter].join('|');
    }

    get heading() {
        return this.agentId ? 'Recent activity' : 'Activity log';
    }

    get showAgentColumn() {
        return !this.agentId;
    }

    get errorMessage() {
        return combineErrors(this.errors);
    }

    get isLoading() {
        return !this.errors.load && this.rowsKey !== this.queryKey;
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get hasFilters() {
        return (
            !!this.statusFilter ||
            !!this.typeFilter ||
            !!this.correlationFilter ||
            this.windowHours !== DEFAULT_WINDOW_HOURS
        );
    }

    get selectedStatus() {
        return this.statusFilter || ALL;
    }

    get selectedType() {
        return this.typeFilter || ALL;
    }

    get selectedWindow() {
        return String(this.windowHours);
    }

    get refreshLabel() {
        return this.refreshing ? 'Refreshing…' : 'Refresh';
    }

    get loadMoreLabel() {
        return this.loadingMore ? 'Loading…' : 'Load more';
    }

    get lastUpdatedLabel() {
        return this.lastUpdated ? `Updated ${formatTime(this.lastUpdated, { seconds: true })}` : '';
    }

    get summary() {
        const count = this.rows.length === 1 ? '1 row' : `${this.rows.length} rows`;
        return this.hasMore ? `Showing the newest ${count}. Older rows are available.` : `Showing ${count}.`;
    }

    get displayRows() {
        const showAgent = this.showAgentColumn;
        const now = Date.now();
        return this.rows.map((row) => {
            const reason = row.Error_Message__c || describeReason(row);
            const duration = row.Execution_Time_Ms__c;
            const when = row.Timestamp__c || row.CreatedDate;
            const correlationId = row.Correlation_Id__c || '';
            return {
                id: row.Id,
                url: recordUrl(row.Id, LOG_OBJECT),
                time: formatCompactDateTime(when, now, { seconds: true }),
                exactTime: formatDateTime(when, { seconds: true }),
                showAgent,
                hasAgent: !!row.Agent_Registration__c,
                agentId: row.Agent_Registration__c,
                agentName: row.Agent_Registration__r ? row.Agent_Registration__r.Agent_Name__c : 'Unknown',
                agentUrl: recordUrl(row.Agent_Registration__c),
                action: ACTION_TYPE_LABELS[row.Action_Type__c] || row.Action_Type__c || '',
                status: row.Status__c || '',
                statusPillClass: `${pillClass(STATUS_VARIANTS[row.Status__c])} log-status`,
                objectName: row.Object_Name__c || '',
                recordId: row.Record_Id__c || '',
                duration: duration === null || duration === undefined ? '' : formatNumber(duration),
                reason: shorten(reason),
                correlationId,
                correlationLabel: shortId(correlationId),
                correlationTitle: `Show only the rows of request ${correlationId}`
            };
        });
    }

    // --- Private helpers ---

    setError(key, error) {
        this.errors = { ...this.errors, [key]: describeError(error) };
    }

    clearError(key) {
        if (this.errors[key]) {
            const remaining = { ...this.errors };
            delete remaining[key];
            this.errors = remaining;
        }
    }
}
