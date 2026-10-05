/**
 * Overview tab of the AgentGov console, also placeable on its own: key figures, the agents that
 * need attention, live sessions, today's budget usage, recent alerts, and fourteen days of
 * org-wide usage. In the console, selecting a key figure fires a drilldown event naming the
 * console tab and agent filter to open. Placed on its own, the overview leaves out the controls
 * that open another tab, because nothing on such a page answers them.
 *
 * Reads go through the cacheable, USER_MODE methods of AgentGovDashboardController, so people see
 * only the agents they may see. Actions go through c/agentGovAdminActions, which asks for
 * confirmation and reports the outcome; their controls are shown only to people with the custom
 * permission, and the server checks it again.
 */
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getAgentSummaries from '@salesforce/apex/AgentGovDashboardController.getAgentSummaries';
import getActiveSessions from '@salesforce/apex/AgentGovDashboardController.getActiveSessions';
import getRecentAlerts from '@salesforce/apex/AgentGovDashboardController.getRecentAlerts';
import getTodaysActionCount from '@salesforce/apex/AgentGovDashboardController.getTodaysActionCount';
import {
    alertView,
    breakerView,
    budgetStatusView,
    clampPercent,
    combineErrors,
    describeError,
    followRecordLink,
    formatDateTime,
    formatNumber,
    formatRelativeTime,
    formatTime,
    listenToAgentGovEvents,
    listenToClock,
    needsAttention,
    recordUrl,
    refreshedMessage,
    restoreFocus,
    usageLevel
} from 'c/agentGovUtils';
import { isPermitted, runAgentAction } from 'c/agentGovAdminActions';

const ALERT_ROWS = 8;
// The overview shows the few rows that matter most and links to the full list for the rest.
const ATTENTION_ROWS = 5;
const SESSION_ROWS = 8;
const USAGE_ROWS = 8;
const HISTORY_DAYS = 14;
const BUDGET_ATTENTION_RANK = { Exhausted: 2, Blocked: 1 };

function isSettled(wired) {
    return !!wired && (wired.data !== undefined || wired.error !== undefined);
}

function agentNameOf(record) {
    return record && record.Agent_Registration__r ? record.Agent_Registration__r.Agent_Name__c : 'Unknown';
}

export default class AgentGovOverview extends NavigationMixin(LightningElement) {
    /**
     * Whether the page hosting the overview opens the tabs that its key figures and list links
     * name in their drilldown events. The AgentGov console sets it; elsewhere those controls are
     * left out.
     * @type {boolean}
     */
    @api canDrillDown = false;

    alertLimit = ALERT_ROWS;
    historyDays = HISTORY_DAYS;

    summaries = [];
    sessions = [];
    alerts = [];
    actionsToday = 0;

    wiredSummaries;
    wiredSessions;
    wiredAlerts;
    wiredActionCount;

    wireErrors = {};
    lastUpdated;
    now = Date.now();
    announcement = '';
    refreshing = false;
    actionInProgress = false;
    refreshInFlight = false;
    refreshQueued = false;
    manualRefreshPending = false;

    @wire(getAgentSummaries)
    handleSummaries(result) {
        this.wiredSummaries = result;
        this.summaries = this.settle('summaries', result, []);
    }

    @wire(getActiveSessions)
    handleSessions(result) {
        this.wiredSessions = result;
        this.sessions = this.settle('sessions', result, []);
    }

    @wire(getRecentAlerts, { limitCount: '$alertLimit' })
    handleAlerts(result) {
        this.wiredAlerts = result;
        this.alerts = this.settle('alerts', result, []);
    }

    @wire(getTodaysActionCount)
    handleActionCount(result) {
        this.wiredActionCount = result;
        this.actionsToday = this.settle('actionCount', result, 0);
    }

    connectedCallback() {
        this.releaseEvents = listenToAgentGovEvents(() => this.refresh());
        this.releaseClock = listenToClock((now) => {
            this.now = now;
        });
    }

    disconnectedCallback() {
        if (this.releaseEvents) {
            this.releaseEvents();
            this.releaseEvents = undefined;
        }
        if (this.releaseClock) {
            this.releaseClock();
            this.releaseClock = undefined;
        }
    }

    // --- Refresh ---

    handleRefresh() {
        this.refresh({ manual: true });
    }

    /**
     * Refreshes every wire. A refresh requested while one is running is performed once the
     * running one completes. A manual refresh also refreshes the usage history and is announced.
     * @param {{manual?: boolean}} [options]
     */
    async refresh({ manual = false } = {}) {
        if (manual) {
            this.refreshing = true;
            this.manualRefreshPending = true;
        }
        if (this.refreshInFlight) {
            this.refreshQueued = true;
            return;
        }
        this.refreshInFlight = true;
        const announce = this.manualRefreshPending;
        this.manualRefreshPending = false;
        try {
            const pending = [this.wiredSummaries, this.wiredSessions, this.wiredAlerts, this.wiredActionCount]
                .filter((wired) => wired)
                .map((wired) => refreshApex(wired));
            const history = this.refs ? this.refs.history : undefined;
            if (announce && history) {
                pending.push(history.refresh());
            }
            await Promise.all(pending);
            this.clearError('refresh');
            this.lastUpdated = new Date();
            this.now = Date.now();
            if (announce) {
                this.announcement = refreshedMessage(this.lastUpdated);
            }
        } catch (error) {
            this.setError('refresh', error);
        } finally {
            this.refreshInFlight = false;
            if (this.refreshQueued) {
                this.refreshQueued = false;
                this.refresh();
            } else {
                this.refreshing = false;
            }
        }
    }

    // --- Actions ---

    handleKpiSelect(event) {
        const kpi = this.kpis.find((item) => item.key === event.currentTarget.dataset.key);
        if (kpi && kpi.tab) {
            this.dispatchEvent(new CustomEvent('drilldown', { detail: { tab: kpi.tab, filter: kpi.filter } }));
        }
    }

    handleViewAttention() {
        this.dispatchEvent(new CustomEvent('drilldown', { detail: { tab: 'agents', filter: 'attention' } }));
    }

    handleRecordLink(event) {
        followRecordLink(this, event);
    }

    handleReset(event) {
        const trigger = event.currentTarget;
        this.runAction('reset', this.findAgent(trigger.dataset.id), trigger, this.refs.attentionHeading);
    }

    handleCredit(event) {
        const trigger = event.currentTarget;
        this.runAction('credit', this.findAgent(trigger.dataset.id), trigger, this.refs.attentionHeading);
    }

    handleEndSession(event) {
        const trigger = event.currentTarget;
        const session = this.sessions.find((row) => row.Id === trigger.dataset.id);
        if (session) {
            const agent = { id: session.Agent_Registration__c, name: agentNameOf(session), liveSessionId: session.Id };
            this.runAction('endSession', agent, trigger, this.refs.sessionsHeading);
        }
    }

    async runAction(name, agent, trigger, fallback) {
        if (!agent || this.actionInProgress) {
            return;
        }
        this.actionInProgress = true;
        let result;
        try {
            result = await runAgentAction(this, name, [agent]);
        } catch (error) {
            result = { changed: false, message: describeError(error) };
        } finally {
            this.actionInProgress = false;
        }
        if (result.changed) {
            await this.refresh();
        }
        if (result.message) {
            this.announcement = result.message;
        }
        // Let the refreshed rows render first: the button may be gone once the agent no longer
        // needs attention, and focus then moves to the section heading.
        await Promise.resolve();
        restoreFocus(trigger, fallback);
    }

    findAgent(id) {
        return this.summaries.find((agent) => agent.id === id);
    }

    // --- View state ---

    get summariesLoaded() {
        return isSettled(this.wiredSummaries);
    }

    get sessionsLoaded() {
        return isSettled(this.wiredSessions);
    }

    get alertsLoaded() {
        return isSettled(this.wiredAlerts);
    }

    get errorMessage() {
        return combineErrors(this.wireErrors);
    }

    get refreshLabel() {
        return this.refreshing ? 'Refreshing…' : 'Refresh';
    }

    get statusLine() {
        return this.lastUpdated ? `Updated ${formatTime(this.lastUpdated, { seconds: true })}` : 'Loading';
    }

    get kpis() {
        const agents = this.summaries;
        const attention = agents.filter((agent) => needsAttention(agent)).length;
        const tripped = agents.filter((agent) => agent.breakerState === 'OPEN').length;
        return [
            {
                key: 'total',
                label: 'Agents',
                icon: 'utility:people',
                value: agents.length,
                actionLabel: 'View all agents',
                tab: 'agents',
                filter: 'all'
            },
            {
                key: 'active',
                label: 'Active',
                icon: 'utility:success',
                value: agents.filter((agent) => agent.status === 'Active').length,
                actionLabel: 'View active agents',
                tab: 'agents',
                filter: 'active'
            },
            {
                key: 'attention',
                label: 'Need attention',
                icon: 'utility:warning',
                value: attention,
                actionLabel: 'Review these agents',
                tab: 'agents',
                filter: 'attention',
                alert: attention > 0
            },
            {
                key: 'tripped',
                label: 'Breakers tripped',
                icon: 'utility:error',
                value: tripped,
                actionLabel: 'Review tripped breakers',
                tab: 'agents',
                filter: 'tripped',
                alert: tripped > 0
            },
            { key: 'sessions', label: 'Live sessions', icon: 'utility:clock', value: this.sessions.length },
            {
                key: 'actions',
                label: 'Actions today',
                icon: 'utility:trending',
                value: this.actionsToday,
                actionLabel: 'View recent activity',
                tab: 'activity'
            }
        ].map((kpi) => {
            const actionLabel = this.canDrillDown ? kpi.actionLabel : undefined;
            return {
                ...kpi,
                actionLabel,
                displayValue: formatNumber(kpi.value),
                tileClass: `ag-kpi kpi-tile${actionLabel ? ' ag-kpi_action' : ''}${kpi.alert ? ' ag-kpi_alert' : ''}`,
                valueClass: `ag-kpi__value kpi-value${kpi.alert ? ' kpi-value_alert' : ''}`
            };
        });
    }

    get attentionRows() {
        const now = this.now;
        const canReset = isPermitted('reset');
        const canCredit = isPermitted('credit');
        return this.summaries
            .filter((agent) => needsAttention(agent))
            .map((agent) => {
                const breaker = breakerView(agent.breakerState, agent.cooldownUntil, now);
                const budget = budgetStatusView(agent.budgetStatus);
                const budgetAttention = BUDGET_ATTENTION_RANK[agent.budgetStatus] || 0;
                return {
                    id: agent.id,
                    name: agent.name,
                    url: recordUrl(agent.id),
                    breakerLabel: breaker.label,
                    breakerPillClass: `${breaker.pillClass} breaker-label`,
                    breakerDetail: breaker.detail,
                    hasBudget: !!agent.budgetStatus,
                    budgetLabel: budget.label,
                    budgetPillClass: budget.pillClass,
                    budgetUsed: `${clampPercent(agent.peakUsagePercent)}% used`,
                    failures: formatNumber(agent.failureCount),
                    showReset: canReset && breaker.isTripped,
                    showCredit: canCredit && budgetAttention > 0,
                    rank: breaker.rank * 10 + budgetAttention
                };
            })
            .sort((a, b) => b.rank - a.rank || a.name.localeCompare(b.name));
    }

    get visibleAttentionRows() {
        return this.attentionRows.slice(0, ATTENTION_ROWS);
    }

    get hasAttention() {
        return this.attentionCount > 0;
    }

    get attentionCount() {
        return this.summaries.filter((agent) => needsAttention(agent)).length;
    }

    // With no agents registered, "all clear" would be true but unhelpful; say how agents arrive.
    get attentionEmpty() {
        if (this.summaries.length === 0) {
            return {
                icon: 'utility:people',
                variant: undefined,
                title: 'No agents yet',
                text: 'Agents appear here once they are registered over the REST API, from Apex, or with New on the Agent Registrations tab.'
            };
        }
        return {
            icon: 'utility:success',
            variant: 'success',
            title: 'All clear',
            text: 'Every circuit breaker is closed and no budget is blocked or exhausted.'
        };
    }

    get attentionCountClass() {
        return this.attentionCount > 0 ? 'ag-count ag-count_alert' : 'ag-count';
    }

    get showAttentionLink() {
        return this.canDrillDown && this.hasAttention;
    }

    get moreAttention() {
        return this.attentionCount > ATTENTION_ROWS;
    }

    get moreAttentionLabel() {
        return `Show all ${formatNumber(this.attentionCount)} agents that need attention`;
    }

    get moreAttentionText() {
        const more = this.attentionCount - ATTENTION_ROWS;
        return `And ${formatNumber(more)} more ${more === 1 ? 'agent needs' : 'agents need'} attention.`;
    }

    get sessionRows() {
        const canEnd = isPermitted('endSession');
        const now = this.now;
        return this.sessions.map((session) => ({
            id: session.Id,
            agentId: session.Agent_Registration__c,
            agentName: agentNameOf(session),
            url: recordUrl(session.Agent_Registration__c),
            started: formatRelativeTime(session.Session_Start__c, now),
            startedExact: formatDateTime(session.Session_Start__c),
            lastActivity: formatRelativeTime(session.Last_Activity__c, now),
            lastActivityExact: formatDateTime(session.Last_Activity__c),
            actions: formatNumber(session.Actions_Count__c),
            apiCalls: formatNumber(session.API_Calls_Used__c),
            soqlQueries: formatNumber(session.SOQL_Queries_Used__c),
            dmlStatements: formatNumber(session.DML_Statements_Used__c),
            showEnd: canEnd
        }));
    }

    get visibleSessionRows() {
        return this.sessionRows.slice(0, SESSION_ROWS);
    }

    get hasSessions() {
        return this.sessions.length > 0;
    }

    get sessionCount() {
        return formatNumber(this.sessions.length);
    }

    get moreSessions() {
        return this.sessions.length > SESSION_ROWS;
    }

    get moreSessionsLabel() {
        const more = this.sessions.length - SESSION_ROWS;
        return `And ${formatNumber(more)} more live ${more === 1 ? 'session' : 'sessions'}, listed on each agent's page.`;
    }

    get showSessionActions() {
        return isPermitted('endSession');
    }

    get usageRows() {
        return this.summaries
            .filter((agent) => !!agent.budgetStatus)
            .map((agent) => {
                const percent = clampPercent(agent.peakUsagePercent);
                const status = budgetStatusView(agent.budgetStatus);
                return {
                    id: agent.id,
                    name: agent.name,
                    url: recordUrl(agent.id),
                    percent,
                    sortValue: Number(agent.peakUsagePercent) || 0,
                    barStyle: `width: ${percent}%`,
                    barClass: `ag-bar ag-bar_${usageLevel(percent)} usage-fill`,
                    ariaLabel: `${agent.name} peak budget usage today ${percent} percent`,
                    statusLabel: status.label,
                    statusPillClass: status.pillClass
                };
            })
            .sort((a, b) => b.sortValue - a.sortValue || a.name.localeCompare(b.name))
            .slice(0, USAGE_ROWS);
    }

    get hasUsage() {
        return this.usageRows.length > 0;
    }

    get usageTruncated() {
        return this.summaries.filter((agent) => !!agent.budgetStatus).length > USAGE_ROWS;
    }

    get showUsageLink() {
        return this.canDrillDown && this.usageTruncated;
    }

    get alertRows() {
        const now = this.now;
        return this.alerts.map((alert) => {
            const view = alertView(alert.Details__c);
            const when = alert.Timestamp__c || alert.CreatedDate;
            return {
                id: alert.Id,
                label: view.label,
                pillClass: view.pillClass,
                text: view.text,
                time: formatRelativeTime(when, now),
                exactTime: formatDateTime(when),
                agentId: alert.Agent_Registration__c,
                agentName: agentNameOf(alert),
                url: recordUrl(alert.Agent_Registration__c),
                hasAgent: !!alert.Agent_Registration__c
            };
        });
    }

    get hasAlerts() {
        return this.alerts.length > 0;
    }

    // --- Private helpers ---

    settle(key, result, fallback) {
        if (result.error) {
            this.setError(key, result.error);
            return fallback;
        }
        if (result.data !== undefined) {
            this.clearError(key);
            this.lastUpdated = new Date();
            return result.data === null ? fallback : result.data;
        }
        return fallback;
    }

    setError(key, error) {
        this.wireErrors = { ...this.wireErrors, [key]: describeError(error) };
    }

    clearError(key) {
        if (this.wireErrors[key]) {
            const remaining = { ...this.wireErrors };
            delete remaining[key];
            this.wireErrors = remaining;
        }
    }
}
