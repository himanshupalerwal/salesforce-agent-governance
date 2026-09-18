/**
 * Overview dashboard: summary tiles, per-agent budget usage, active sessions, and recent
 * conflicts. Data arrives through cacheable wires; the component refreshes them when the
 * user asks or when an AgentGov platform event announces new activity.
 */
import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllRegistrations from '@salesforce/apex/AgentGovDashboardController.getAllRegistrations';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovDashboardController.getAllTodaysBudgets';
import getRecentConflictLogs from '@salesforce/apex/AgentGovDashboardController.getRecentConflictLogs';
import getTodaysActionCount from '@salesforce/apex/AgentGovDashboardController.getTodaysActionCount';
import getActiveSessions from '@salesforce/apex/AgentGovDashboardController.getActiveSessions';
import getTrippedCircuitBreakerCount from '@salesforce/apex/AgentGovDashboardController.getTrippedCircuitBreakerCount';
import {
    reduceErrors,
    usageLevel,
    percentOf,
    formatDateTime,
    subscribeToAgentGovEvents,
    unsubscribeFromAgentGovEvents,
    onStreamingError
} from 'c/agentGovUtils';

const CONFLICT_ROWS = 10;
const STATUS_BADGE = {
    Normal: 'slds-badge slds-theme_success',
    Warning: 'slds-badge slds-theme_warning',
    Throttled: 'slds-badge slds-theme_warning',
    Blocked: 'slds-badge slds-theme_error',
    Exhausted: 'slds-badge slds-theme_error'
};
const SEVERITY_BADGE = {
    High: 'slds-badge badge-high',
    Medium: 'slds-badge badge-medium',
    Low: 'slds-badge badge-low'
};

export default class AgentGovDashboard extends LightningElement {
    conflictLimit = CONFLICT_ROWS;

    agents = [];
    budgets = [];
    conflicts = [];
    sessions = [];
    actionsToday = 0;
    trippedBreakers = 0;
    error;
    liveUpdates = false;

    wiredAgents;
    wiredBudgets;
    wiredConflicts;
    wiredActionCount;
    wiredSessions;
    wiredTripped;

    subscriptions = [];
    refreshInFlight = false;
    refreshQueued = false;
    lastToastedError;

    @wire(getAllRegistrations)
    handleAgents(result) {
        this.wiredAgents = result;
        this.agents = this.settle(result, []);
    }

    @wire(getAllTodaysBudgets)
    handleBudgets(result) {
        this.wiredBudgets = result;
        this.budgets = this.settle(result, []).map((budget) => this.decorateBudget(budget));
    }

    @wire(getRecentConflictLogs, { limitCount: '$conflictLimit' })
    handleConflicts(result) {
        this.wiredConflicts = result;
        this.conflicts = this.settle(result, []).map((conflict) => ({
            ...conflict,
            agent1Name: conflict.Agent_1__r ? conflict.Agent_1__r.Agent_Name__c : 'Unknown',
            agent2Name: conflict.Agent_2__r ? conflict.Agent_2__r.Agent_Name__c : 'Unknown',
            severityClass: SEVERITY_BADGE[conflict.Severity__c] || 'slds-badge',
            formattedTime: formatDateTime(conflict.Timestamp__c)
        }));
    }

    @wire(getTodaysActionCount)
    handleActionCount(result) {
        this.wiredActionCount = result;
        this.actionsToday = this.settle(result, 0);
    }

    @wire(getActiveSessions)
    handleSessions(result) {
        this.wiredSessions = result;
        this.sessions = this.settle(result, []).map((session) => ({
            ...session,
            agentName: session.Agent_Registration__r ? session.Agent_Registration__r.Agent_Name__c : 'Unknown',
            formattedStart: formatDateTime(session.Session_Start__c)
        }));
    }

    @wire(getTrippedCircuitBreakerCount)
    handleTripped(result) {
        this.wiredTripped = result;
        this.trippedBreakers = this.settle(result, 0);
    }

    connectedCallback() {
        this.connected = true;
        onStreamingError(() => {
            this.liveUpdates = false;
        });
        subscribeToAgentGovEvents(() => this.refresh())
            .then((subscriptions) => {
                if (!this.connected) {
                    // The component was destroyed before subscribe resolved. Release the
                    // subscriptions now, because disconnectedCallback already ran against an
                    // empty list and nothing else will ever unsubscribe them.
                    unsubscribeFromAgentGovEvents(subscriptions);
                    return;
                }
                this.subscriptions = subscriptions;
                this.liveUpdates = subscriptions.length > 0;
            })
            .catch(() => {
                this.liveUpdates = false;
            });
    }

    disconnectedCallback() {
        this.connected = false;
        unsubscribeFromAgentGovEvents(this.subscriptions);
        this.subscriptions = [];
    }

    handleRefresh() {
        this.refresh();
    }

    /**
     * Refreshes every wire. Overlapping requests are coalesced: a refresh requested while
     * one is running is performed once the running one completes.
     */
    async refresh() {
        if (this.refreshInFlight) {
            this.refreshQueued = true;
            return;
        }
        this.refreshInFlight = true;
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
        } catch (error) {
            this.reportError(error);
        } finally {
            this.refreshInFlight = false;
            if (this.refreshQueued) {
                this.refreshQueued = false;
                this.refresh();
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

    get totalAgents() {
        return this.agents.length;
    }

    get activeAgents() {
        return this.agents.filter((agent) => agent.Status__c === 'Active').length;
    }

    get activeSessions() {
        return this.sessions.length;
    }

    get conflictsDetected() {
        return this.conflicts.length;
    }

    get avgBudgetUtilization() {
        if (this.budgets.length === 0) {
            return 0;
        }
        const total = this.budgets.reduce((sum, budget) => sum + budget.avgPercent, 0);
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

    get trippedBreakersClass() {
        return this.trippedBreakers > 0
            ? 'slds-text-heading_large slds-text-color_error'
            : 'slds-text-heading_large slds-text-color_success';
    }

    get liveUpdatesLabel() {
        return this.liveUpdates ? 'Live updates on' : 'Live updates off';
    }

    // --- Private helpers ---

    settle(result, fallback) {
        if (result.error) {
            this.reportError(result.error);
            return fallback;
        }
        if (result.data !== undefined) {
            this.error = undefined;
            return result.data === null ? fallback : result.data;
        }
        return fallback;
    }

    decorateBudget(budget) {
        const apiPercent = percentOf(budget.API_Calls_Consumed__c, budget.API_Calls_Allocated__c);
        const soqlPercent = percentOf(budget.SOQL_Queries_Consumed__c, budget.SOQL_Queries_Allocated__c);
        const dmlPercent = percentOf(budget.DML_Operations_Consumed__c, budget.DML_Operations_Allocated__c);
        const avgPercent = Math.round((apiPercent + soqlPercent + dmlPercent) / 3);
        const agentName = budget.Agent_Registration__r ? budget.Agent_Registration__r.Agent_Name__c : 'Unknown';
        return {
            ...budget,
            agentName,
            apiPercent,
            soqlPercent,
            dmlPercent,
            avgPercent,
            statusClass: STATUS_BADGE[budget.Budget_Status__c] || 'slds-badge',
            barStyle: `width: ${avgPercent}%`,
            barClass: `slds-progress-bar__value bar-${usageLevel(avgPercent)}`,
            ariaLabel: `${agentName} average budget usage ${avgPercent} percent`
        };
    }

    reportError(error) {
        const message = reduceErrors(error).join('. ');
        this.error = message;
        if (message && message !== this.lastToastedError) {
            this.lastToastedError = message;
            this.dispatchEvent(
                new ShowToastEvent({ title: 'AgentGov dashboard could not load', message, variant: 'error' })
            );
        }
    }
}
