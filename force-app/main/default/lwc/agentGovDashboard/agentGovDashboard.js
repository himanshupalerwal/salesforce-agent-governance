/**
 * Overview dashboard: summary tiles, per-agent budget usage, active sessions, and recent
 * conflicts. Data arrives through cacheable wires; the component refreshes them when the
 * user asks or when an AgentGov platform event announces new activity.
 */
import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllRegistrations from '@salesforce/apex/AgentGovDashboardController.getAllRegistrations';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovDashboardController.getAllTodaysBudgets';
import getRecentConflictLogs from '@salesforce/apex/AgentGovDashboardController.getRecentConflictLogs';
import getTodaysActionCount from '@salesforce/apex/AgentGovDashboardController.getTodaysActionCount';
import getActiveSessions from '@salesforce/apex/AgentGovDashboardController.getActiveSessions';
import getTrippedCircuitBreakerCount from '@salesforce/apex/AgentGovDashboardController.getTrippedCircuitBreakerCount';
import {
    budgetStatusView,
    combineErrors,
    describeError,
    followRecordLink,
    formatDateTime,
    formatNumber,
    formatTime,
    listenToAgentGovEvents,
    peakUsagePercent,
    percentOf,
    pillClass,
    recordUrl,
    refreshedMessage,
    usageLevel
} from 'c/agentGovUtils';

const CONFLICT_ROWS = 10;
const SEVERITY_VARIANTS = { High: 'error', Medium: 'warning', Low: 'neutral' };

function agentNameOf(relationship) {
    return relationship ? relationship.Agent_Name__c : 'Unknown';
}

export default class AgentGovDashboard extends NavigationMixin(LightningElement) {
    conflictLimit = CONFLICT_ROWS;

    agents = [];
    budgets = [];
    conflicts = [];
    sessions = [];
    actionsToday = 0;
    trippedBreakers = 0;
    liveUpdates = false;
    lastUpdated;
    announcement = '';
    refreshing = false;

    // One entry per wire, so a wire that loads does not hide another wire's failure.
    wireErrors = {};

    wiredAgents;
    wiredBudgets;
    wiredConflicts;
    wiredActionCount;
    wiredSessions;
    wiredTripped;

    refreshInFlight = false;
    refreshQueued = false;
    manualRefreshPending = false;
    lastToastedError;

    @wire(getAllRegistrations)
    handleAgents(result) {
        this.wiredAgents = result;
        this.agents = this.settle('agents', result, []);
    }

    @wire(getAllTodaysBudgets)
    handleBudgets(result) {
        this.wiredBudgets = result;
        this.budgets = this.settle('budgets', result, []).map((budget) => this.decorateBudget(budget));
    }

    @wire(getRecentConflictLogs, { limitCount: '$conflictLimit' })
    handleConflicts(result) {
        this.wiredConflicts = result;
        this.conflicts = this.settle('conflicts', result, []).map((conflict) => ({
            ...conflict,
            agent1Name: agentNameOf(conflict.Agent_1__r),
            agent1Url: recordUrl(conflict.Agent_1__c),
            agent2Name: agentNameOf(conflict.Agent_2__r),
            agent2Url: recordUrl(conflict.Agent_2__c),
            severityPillClass: `${pillClass(SEVERITY_VARIANTS[conflict.Severity__c])} severity-label`,
            formattedTime: formatDateTime(conflict.Timestamp__c)
        }));
    }

    @wire(getTodaysActionCount)
    handleActionCount(result) {
        this.wiredActionCount = result;
        this.actionsToday = this.settle('actionCount', result, 0);
    }

    @wire(getActiveSessions)
    handleSessions(result) {
        this.wiredSessions = result;
        this.sessions = this.settle('sessions', result, []).map((session) => ({
            ...session,
            agentName: agentNameOf(session.Agent_Registration__r),
            agentUrl: recordUrl(session.Agent_Registration__c),
            formattedStart: formatDateTime(session.Session_Start__c),
            formattedLastActivity: formatDateTime(session.Last_Activity__c),
            apiCalls: formatNumber(session.API_Calls_Used__c),
            soqlQueries: formatNumber(session.SOQL_Queries_Used__c),
            dmlStatements: formatNumber(session.DML_Statements_Used__c),
            actions: formatNumber(session.Actions_Count__c)
        }));
    }

    @wire(getTrippedCircuitBreakerCount)
    handleTripped(result) {
        this.wiredTripped = result;
        this.trippedBreakers = this.settle('tripped', result, 0);
    }

    connectedCallback() {
        this.releaseEvents = listenToAgentGovEvents(
            () => this.refresh(),
            (live) => {
                this.liveUpdates = live;
            }
        );
    }

    disconnectedCallback() {
        if (this.releaseEvents) {
            this.releaseEvents();
            this.releaseEvents = undefined;
        }
    }

    handleRefresh() {
        this.refresh({ manual: true });
    }

    handleRecordLink(event) {
        followRecordLink(this, event);
    }

    /**
     * Refreshes every wire. Overlapping requests are coalesced: a refresh requested while
     * one is running is performed once the running one completes. A refresh the user asked
     * for disables the button while it runs and is announced when it completes.
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
            await Promise.all(
                [
                    this.wiredAgents,
                    this.wiredBudgets,
                    this.wiredConflicts,
                    this.wiredActionCount,
                    this.wiredSessions,
                    this.wiredTripped
                ]
                    .filter((wired) => wired)
                    .map((wired) => refreshApex(wired))
            );
            this.clearError('refresh');
            this.lastUpdated = new Date();
            if (announce) {
                this.announcement = refreshedMessage(this.lastUpdated);
            }
        } catch (error) {
            this.reportError('refresh', error);
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

    get isLoading() {
        return [
            this.wiredAgents,
            this.wiredBudgets,
            this.wiredConflicts,
            this.wiredActionCount,
            this.wiredSessions,
            this.wiredTripped
        ].some((wired) => !wired || (wired.data === undefined && wired.error === undefined));
    }

    get error() {
        return combineErrors(this.wireErrors);
    }

    get totalAgents() {
        return this.agents.length;
    }

    get activeAgents() {
        return this.agents.filter((agent) => agent.Status__c === 'Active').length;
    }

    get activeSessions() {
        return this.sessions.length;
    }

    /** Average over today's budgets of each budget's peak usage. */
    get avgBudgetUtilization() {
        if (this.budgets.length === 0) {
            return 0;
        }
        const total = this.budgets.reduce((sum, budget) => sum + budget.peakPercent, 0);
        return Math.round(total / this.budgets.length);
    }

    get hasBudgets() {
        return this.budgets.length > 0;
    }

    get hasConflicts() {
        return this.conflicts.length > 0;
    }

    get hasSessions() {
        return this.sessions.length > 0;
    }

    get kpis() {
        return [
            {
                key: 'total',
                label: 'Total agents',
                icon: 'utility:people',
                value: formatNumber(this.totalAgents)
            },
            {
                key: 'active',
                label: 'Active agents',
                icon: 'utility:success',
                value: formatNumber(this.activeAgents)
            },
            {
                key: 'actions',
                label: 'Actions today',
                icon: 'utility:trending',
                value: formatNumber(this.actionsToday)
            },
            {
                key: 'sessions',
                label: 'Active sessions',
                icon: 'utility:clock',
                value: formatNumber(this.activeSessions)
            },
            {
                key: 'budget',
                label: 'Avg peak budget used',
                icon: 'utility:chart',
                value: `${this.avgBudgetUtilization}%`
            },
            {
                key: 'tripped',
                label: 'Circuit breakers tripped',
                icon: 'utility:error',
                value: formatNumber(this.trippedBreakers),
                alert: this.trippedBreakers > 0
            }
        ].map((kpi) => ({
            ...kpi,
            tileClass: `ag-kpi kpi-tile${kpi.actionLabel ? ' ag-kpi_action' : ''}${kpi.alert ? ' ag-kpi_alert' : ''}`,
            iconVariant: kpi.alert ? 'error' : undefined
        }));
    }

    get liveUpdatesLabel() {
        return this.liveUpdates ? 'Live updates on' : 'Live updates off';
    }

    get liveUpdatesClass() {
        return `ag-meta ag-live slds-m-right_small${this.liveUpdates ? ' ag-live_on' : ''}`;
    }

    get refreshLabel() {
        return this.refreshing ? 'Refreshing…' : 'Refresh';
    }

    get lastUpdatedLabel() {
        return this.lastUpdated ? `Updated ${formatTime(this.lastUpdated, { seconds: true })}` : '';
    }

    // --- Private helpers ---

    settle(key, result, fallback) {
        if (result.error) {
            this.reportError(key, result.error);
            return fallback;
        }
        if (result.data !== undefined) {
            this.clearError(key);
            this.lastUpdated = new Date();
            return result.data === null ? fallback : result.data;
        }
        return fallback;
    }

    decorateBudget(budget) {
        const apiPercent = percentOf(budget.API_Calls_Consumed__c, budget.API_Calls_Allocated__c);
        const soqlPercent = percentOf(budget.SOQL_Queries_Consumed__c, budget.SOQL_Queries_Allocated__c);
        const dmlPercent = percentOf(budget.DML_Operations_Consumed__c, budget.DML_Operations_Allocated__c);
        const peakPercent = peakUsagePercent(budget);
        const agentName = agentNameOf(budget.Agent_Registration__r);
        return {
            ...budget,
            agentName,
            agentUrl: recordUrl(budget.Agent_Registration__c),
            apiPercent,
            soqlPercent,
            dmlPercent,
            peakPercent,
            statusPillClass: `${budgetStatusView(budget.Budget_Status__c).pillClass} budget-status`,
            barStyle: `width: ${peakPercent}%`,
            barClass: `ag-bar ag-bar_${usageLevel(peakPercent)} usage-fill`,
            ariaLabel: `${agentName} peak budget usage ${peakPercent} percent`
        };
    }

    clearError(key) {
        if (this.wireErrors[key]) {
            const remaining = { ...this.wireErrors };
            delete remaining[key];
            this.wireErrors = remaining;
        }
    }

    reportError(key, error) {
        const message = describeError(error);
        this.wireErrors = { ...this.wireErrors, [key]: message };
        if (message && message !== this.lastToastedError) {
            this.lastToastedError = message;
            this.dispatchEvent(
                new ShowToastEvent({ title: 'AgentGov dashboard could not load', message, variant: 'error' })
            );
        }
    }
}
