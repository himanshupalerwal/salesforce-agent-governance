/**
 * Every agent the viewer can see, in a sortable table with a search box and a filter (all, needs
 * attention, tripped, active, inactive) that the console can also set through the filter
 * property. Row actions follow each agent's state and the viewer's permissions, and people who
 * may operate agents can select several rows to reset, activate, or deactivate them together.
 *
 * Reads go through the cacheable, USER_MODE AgentGovDashboardController.getAgentSummaries.
 * Actions go through c/agentGovAdminActions, which confirms disruptive actions and reports each
 * outcome; the server checks the permissions again.
 */
import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getAgentSummaries from '@salesforce/apex/AgentGovDashboardController.getAgentSummaries';
import {
    agentTypeLabel,
    breakerView,
    budgetStatusView,
    clampPercent,
    combineErrors,
    describeError,
    formatDateTime,
    formatNumber,
    formatTime,
    listenToAgentGovEvents,
    needsAttention,
    recordUrl,
    refreshedMessage,
    restoreFocus
} from 'c/agentGovUtils';
import {
    MAX_SELECTION,
    actionLabel,
    actionsFor,
    canOperate,
    eligibleAgents,
    isPermitted,
    runAgentAction
} from 'c/agentGovAdminActions';

const FILTER_OPTIONS = [
    { label: 'All', value: 'all' },
    { label: 'Needs attention', value: 'attention' },
    { label: 'Tripped', value: 'tripped' },
    { label: 'Active', value: 'active' },
    { label: 'Inactive', value: 'inactive' }
];
const FILTER_TESTS = {
    all: () => true,
    attention: (agent) => needsAttention(agent),
    tripped: (agent) => agent.breakerState === 'OPEN',
    active: (agent) => agent.status === 'Active',
    inactive: (agent) => agent.status === 'Inactive'
};
const STATUS_ICONS = {
    Active: 'utility:success',
    Inactive: 'utility:pause',
    Throttled: 'utility:clock',
    Blocked: 'utility:ban'
};
const BULK_ACTIONS = ['reset', 'activate', 'deactivate'];
const NO_ACTIONS = [{ label: 'No actions available', name: 'none', disabled: true }];
const FRAMED_ROWS = 12;

// Each sortable column sorts on a raw value rather than the text it shows, so dates sort by
// time, the breaker by severity, and usage by number.
const SORT_KEYS = {
    recordUrl: 'nameKey',
    agentTypeLabel: 'agentTypeLabel',
    status: 'status',
    breakerText: 'breakerRank',
    peakText: 'peakValue',
    lastActiveText: 'lastActiveTime',
    failureCount: 'failureCount',
    priority: 'priority'
};

function rowActions(row, doneCallback) {
    const actions = actionsFor(row).map((action) => ({ label: action.label, name: action.name }));
    doneCallback(actions.length ? actions : NO_ACTIONS);
}

function buildColumns() {
    const columns = [
        {
            label: 'Agent',
            fieldName: 'recordUrl',
            type: 'url',
            sortable: true,
            typeAttributes: { label: { fieldName: 'name' }, target: '_self', tooltip: { fieldName: 'name' } }
        },
        { label: 'Type', fieldName: 'agentTypeLabel', type: 'text', sortable: true },
        {
            label: 'Status',
            fieldName: 'status',
            type: 'text',
            sortable: true,
            cellAttributes: { iconName: { fieldName: 'statusIcon' } }
        },
        {
            label: 'Breaker',
            fieldName: 'breakerText',
            type: 'text',
            sortable: true,
            wrapText: true,
            cellAttributes: { iconName: { fieldName: 'breakerIcon' } }
        },
        {
            label: 'Peak usage today',
            fieldName: 'peakText',
            type: 'text',
            sortable: true,
            cellAttributes: { iconName: { fieldName: 'budgetIcon' } }
        },
        { label: 'Last active', fieldName: 'lastActiveText', type: 'text', sortable: true },
        {
            label: 'Failures',
            fieldName: 'failureCount',
            type: 'number',
            sortable: true,
            cellAttributes: { alignment: 'left' }
        },
        {
            label: 'Priority',
            fieldName: 'priority',
            type: 'number',
            sortable: true,
            cellAttributes: { alignment: 'left' }
        }
    ];
    if (canOperate || isPermitted('rotateKey')) {
        columns.push({ type: 'action', typeAttributes: { rowActions } });
    }
    return columns;
}

function toRow(agent, now) {
    const breaker = breakerView(agent.breakerState, agent.cooldownUntil, now);
    const budget = budgetStatusView(agent.budgetStatus);
    const peak = clampPercent(agent.peakUsagePercent);
    const lastActive = agent.lastActive ? new Date(agent.lastActive).getTime() : 0;
    return {
        ...agent,
        recordUrl: recordUrl(agent.id),
        nameKey: (agent.name || '').toLowerCase(),
        agentTypeLabel: agentTypeLabel(agent.agentType),
        statusIcon: STATUS_ICONS[agent.status] || 'utility:info',
        breakerText: breaker.detail ? `${breaker.label}. ${breaker.detail}` : breaker.label,
        breakerIcon: breaker.icon,
        breakerRank: breaker.rank,
        peakText: agent.budgetStatus ? `${peak}% (${agent.budgetStatus})` : 'No usage today',
        peakValue: agent.budgetStatus ? Number(agent.peakUsagePercent) || 0 : -1,
        budgetIcon: agent.budgetStatus ? budget.icon : undefined,
        lastActiveText: lastActive ? formatDateTime(agent.lastActive) : 'Never',
        lastActiveTime: lastActive,
        failureCount: agent.failureCount || 0
    };
}

function compareValues(left, right) {
    if (typeof left === 'string' || typeof right === 'string') {
        return String(left).localeCompare(String(right));
    }
    if (left === right) {
        return 0;
    }
    return left < right ? -1 : 1;
}

export default class AgentGovAgentList extends LightningElement {
    filterOptions = FILTER_OPTIONS;
    columns = buildColumns();
    maxSelection = MAX_SELECTION;

    currentFilter = 'all';
    focusToken = 0;
    focusPending = false;
    searchTerm = '';
    sortedBy = 'recordUrl';
    sortDirection = 'asc';
    selectedIds = [];

    rows = [];
    wiredAgents;
    errors = {};
    lastUpdated;
    announcement = '';
    refreshing = false;
    actionInProgress = false;
    refreshInFlight = false;
    refreshQueued = false;

    /**
     * Which agents to show: all, attention, tripped, active, or inactive. Setting it clears the
     * search and the selection, so a drill-down always shows the whole matching set.
     * @type {string}
     */
    @api
    get filter() {
        return this.currentFilter;
    }
    set filter(value) {
        const next = FILTER_TESTS[value] ? value : 'all';
        if (next !== this.currentFilter) {
            this.currentFilter = next;
            this.searchTerm = '';
            this.selectedIds = [];
        }
    }

    /**
     * Moves focus to the list's heading after the next render whenever the value changes. The
     * console increments it when a key figure opens this tab, so keyboard focus follows the
     * person to the list instead of staying on the hidden overview.
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

    @wire(getAgentSummaries)
    handleAgents(result) {
        this.wiredAgents = result;
        if (result.error) {
            this.setError('load', result.error);
            this.rows = [];
        } else if (result.data !== undefined) {
            this.clearError('load');
            const now = Date.now();
            this.rows = (result.data || []).map((agent) => toRow(agent, now));
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
     * Reloads the agents. A refresh requested while one is running runs once it completes.
     * @returns {Promise}
     */
    @api
    async refresh() {
        if (this.refreshInFlight) {
            this.refreshQueued = true;
            return;
        }
        this.refreshInFlight = true;
        try {
            if (this.wiredAgents) {
                await refreshApex(this.wiredAgents);
            }
            this.clearError('refresh');
            this.lastUpdated = new Date();
        } catch (error) {
            this.setError('refresh', error);
        } finally {
            this.refreshInFlight = false;
            if (this.refreshQueued) {
                this.refreshQueued = false;
                this.refresh();
            }
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

    handleFilterChange(event) {
        this.currentFilter = FILTER_TESTS[event.detail.value] ? event.detail.value : 'all';
        this.selectedIds = [];
        this.dispatchEvent(new CustomEvent('filterchange', { detail: { filter: this.currentFilter } }));
    }

    handleSearch(event) {
        this.searchTerm = event.detail.value || '';
        this.selectedIds = [];
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortDirection = event.detail.sortDirection === 'desc' ? 'desc' : 'asc';
    }

    handleRowSelection(event) {
        this.selectedIds = (event.detail.selectedRows || []).map((row) => row.id);
    }

    handleRowAction(event) {
        const { action, row } = event.detail;
        const agent = this.rows.find((candidate) => candidate.id === row.id);
        if (agent && action.name !== 'none') {
            this.runAction(action.name, [agent], null);
        }
    }

    handleBulkAction(event) {
        this.runAction(event.currentTarget.dataset.action, this.selectedAgents, event.currentTarget);
    }

    async runAction(name, agents, trigger) {
        if (this.actionInProgress) {
            return;
        }
        this.actionInProgress = true;
        let result;
        try {
            result = await runAgentAction(this, name, agents);
        } catch (error) {
            result = { changed: false, message: describeError(error) };
        } finally {
            this.actionInProgress = false;
        }
        if (result.changed) {
            this.selectedIds = [];
            await this.refresh();
        }
        if (result.message) {
            this.announcement = result.message;
        }
        // Let the refreshed rows render before moving focus. A bulk button is disabled once the
        // selection is cleared, and a row's action menu can be re-created by the refresh, so
        // focus falls back to the heading rather than being lost.
        await Promise.resolve();
        if (trigger || !this.template.activeElement) {
            restoreFocus(trigger, this.refs.heading);
        }
    }

    // --- View state ---

    get isLoading() {
        return !this.wiredAgents || (this.wiredAgents.data === undefined && this.wiredAgents.error === undefined);
    }

    get errorMessage() {
        return combineErrors(this.errors);
    }

    get visibleRows() {
        const test = FILTER_TESTS[this.currentFilter] || FILTER_TESTS.all;
        const term = this.searchTerm.trim().toLowerCase();
        const matches = this.rows.filter(
            (row) =>
                test(row) &&
                (!term ||
                    [row.name, row.agentTypeLabel, row.status].some((value) =>
                        (value || '').toLowerCase().includes(term)
                    ))
        );
        const key = SORT_KEYS[this.sortedBy] || 'nameKey';
        const direction = this.sortDirection === 'desc' ? -1 : 1;
        return matches.sort((a, b) => {
            const left = a[key];
            const right = b[key];
            const leftBlank = left === null || left === undefined;
            const rightBlank = right === null || right === undefined;
            if (leftBlank !== rightBlank) {
                // Blank values sort last in either direction.
                return leftBlank ? 1 : -1;
            }
            return (leftBlank ? 0 : compareValues(left, right) * direction) || a.nameKey.localeCompare(b.nameKey);
        });
    }

    get selectedAgents() {
        const selected = new Set(this.selectedIds);
        return this.visibleRows.filter((row) => selected.has(row.id));
    }

    get hasAgents() {
        return this.rows.length > 0;
    }

    get hasVisibleRows() {
        return this.visibleRows.length > 0;
    }

    get hideCheckboxes() {
        return !canOperate;
    }

    get showBulkActions() {
        return canOperate;
    }

    get bulkActions() {
        const selected = this.selectedAgents;
        return BULK_ACTIONS.filter((name) => isPermitted(name)).map((name) => {
            const count = eligibleAgents(name, selected).length;
            const label = actionLabel(name, { bulk: true });
            return {
                name,
                label: count ? `${label} (${count})` : label,
                disabled: count === 0 || this.actionInProgress
            };
        });
    }

    get summary() {
        const total = this.rows.length;
        const shown = this.visibleRows.length;
        const agents = total === 1 ? 'agent' : 'agents';
        const selected = this.selectedAgents.length;
        return `Showing ${shown} of ${total} ${agents}${selected ? `, ${selected} selected` : ''}.`;
    }

    get refreshLabel() {
        return this.refreshing ? 'Refreshing…' : 'Refresh';
    }

    get lastUpdatedLabel() {
        return this.lastUpdated ? `Updated ${formatTime(this.lastUpdated, { seconds: true })}` : '';
    }

    get agentCount() {
        return formatNumber(this.rows.length);
    }

    // A long list scrolls inside a frame with its header pinned, so the page stays short.
    get tableFrameClass() {
        return this.visibleRows.length > FRAMED_ROWS ? 'ag-datatable-frame table-frame' : 'table-frame';
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
