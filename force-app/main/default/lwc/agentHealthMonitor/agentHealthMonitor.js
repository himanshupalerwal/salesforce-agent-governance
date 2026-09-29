/**
 * Health cards for every registered agent: status, circuit breaker state and when an open breaker
 * lets the agent retry, failures, and today's peak budget usage. Refreshes on demand and on
 * AgentGov platform events.
 */
import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllRegistrations from '@salesforce/apex/AgentGovDashboardController.getAllRegistrations';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovDashboardController.getAllTodaysBudgets';
import {
    agentStatusView,
    breakerView,
    combineErrors,
    describeError,
    followRecordLink,
    formatDateTime,
    formatTime,
    listenToAgentGovEvents,
    peakUsagePercent,
    recordUrl,
    refreshedMessage,
    usageLevel
} from 'c/agentGovUtils';

export default class AgentHealthMonitor extends NavigationMixin(LightningElement) {
    registrations = [];
    budgets = [];
    lastUpdated;
    announcement = '';
    refreshing = false;

    // One entry per wire, so a wire that loads does not hide another wire's failure.
    wireErrors = {};

    wiredRegistrations;
    wiredBudgets;
    refreshInFlight = false;
    refreshQueued = false;
    manualRefreshPending = false;
    lastToastedError;

    @wire(getAllRegistrations)
    handleRegistrations(result) {
        this.wiredRegistrations = result;
        this.registrations = this.settle('registrations', result);
    }

    @wire(getAllTodaysBudgets)
    handleBudgets(result) {
        this.wiredBudgets = result;
        this.budgets = this.settle('budgets', result);
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

    handleRefresh() {
        this.refresh({ manual: true });
    }

    handleRecordLink(event) {
        followRecordLink(this, event);
    }

    /**
     * Refreshes both wires. A refresh requested while one is running is performed once the
     * running one completes. A refresh the user asked for disables the button while it runs and
     * is announced when it completes.
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
                [this.wiredRegistrations, this.wiredBudgets].filter((wired) => wired).map((wired) => refreshApex(wired))
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
        return [this.wiredRegistrations, this.wiredBudgets].some(
            (wired) => !wired || (wired.data === undefined && wired.error === undefined)
        );
    }

    get error() {
        return combineErrors(this.wireErrors);
    }

    get refreshLabel() {
        return this.refreshing ? 'Refreshing…' : 'Refresh';
    }

    get lastUpdatedLabel() {
        return this.lastUpdated ? `Updated ${formatTime(this.lastUpdated, { seconds: true })}` : '';
    }

    get agents() {
        const usageByAgent = {};
        this.budgets.forEach((budget) => {
            if (budget.Agent_Registration__c) {
                usageByAgent[budget.Agent_Registration__c] = peakUsagePercent(budget);
            }
        });
        const now = Date.now();
        return this.registrations.map((registration) => {
            const breakerState = registration.Circuit_Breaker_State__c || 'CLOSED';
            const breaker = breakerView(breakerState, registration.Cooldown_Until__c, now);
            const budgetPercent = usageByAgent[registration.Id] || 0;
            return {
                ...registration,
                agentUrl: recordUrl(registration.Id),
                breakerState,
                breakerIcon: breaker.icon,
                breakerVariant: breaker.variant,
                breakerAltText: `Circuit breaker ${breakerState}`,
                breakerLabel: breaker.label,
                breakerPillClass: `${breaker.pillClass} breaker-state`,
                retryText: breaker.state === 'OPEN' ? breaker.detail : '',
                statusLabel: registration.Status__c || 'Unknown',
                statusPillClass: `${agentStatusView(registration.Status__c).pillClass} agent-status`,
                budgetPercent,
                budgetBarStyle: `width: ${budgetPercent}%`,
                budgetBarClass: `ag-bar ag-bar_${usageLevel(budgetPercent)} progress-bar`,
                budgetAriaLabel: `${registration.Agent_Name__c} peak budget usage today ${budgetPercent} percent`,
                hasFailures: (registration.Failure_Count__c || 0) > 0,
                lastActiveFormatted: registration.Last_Active__c ? formatDateTime(registration.Last_Active__c) : 'Never'
            };
        });
    }

    get hasAgents() {
        return this.registrations.length > 0;
    }

    settle(key, result) {
        if (result.error) {
            this.reportError(key, result.error);
            return [];
        }
        if (result.data !== undefined) {
            this.clearError(key);
            this.lastUpdated = new Date();
            return result.data || [];
        }
        return [];
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
            this.dispatchEvent(new ShowToastEvent({ title: 'Agent health could not load', message, variant: 'error' }));
        }
    }
}
