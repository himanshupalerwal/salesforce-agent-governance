/**
 * Health cards for every registered agent: status, circuit breaker state, failures, and
 * today's combined budget usage. Refreshes on demand and on AgentGov platform events.
 */
import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllRegistrations from '@salesforce/apex/AgentGovDashboardController.getAllRegistrations';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovDashboardController.getAllTodaysBudgets';
import {
    reduceErrors,
    usageLevel,
    percentOf,
    formatDateTime,
    subscribeToAgentGovEvents,
    unsubscribeFromAgentGovEvents
} from 'c/agentGovUtils';

const BREAKER_ICON = { CLOSED: 'utility:success', OPEN: 'utility:error', HALF_OPEN: 'utility:warning' };
// lightning-icon variants colour the icon the way the active theme expects; SLDS 2 removed
// the icon colour styling hook and offers no replacement for it.
const BREAKER_VARIANT = { CLOSED: 'success', OPEN: 'error', HALF_OPEN: 'warning' };
const STATUS_BADGE = {
    Active: 'slds-badge slds-theme_success',
    Inactive: 'slds-badge',
    Throttled: 'slds-badge slds-theme_warning',
    Blocked: 'slds-badge slds-theme_error'
};

export default class AgentHealthMonitor extends LightningElement {
    registrations = [];
    budgets = [];
    error;

    wiredRegistrations;
    wiredBudgets;
    subscriptions = [];
    refreshInFlight = false;
    refreshQueued = false;
    lastToastedError;

    @wire(getAllRegistrations)
    handleRegistrations(result) {
        this.wiredRegistrations = result;
        this.registrations = this.settle(result);
    }

    @wire(getAllTodaysBudgets)
    handleBudgets(result) {
        this.wiredBudgets = result;
        this.budgets = this.settle(result);
    }

    connectedCallback() {
        this.connected = true;
        subscribeToAgentGovEvents(() => this.refresh())
            .then((subscriptions) => {
                this.subscriptions = subscriptions;
            })
            .catch(() => {
                this.subscriptions = [];
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

    async refresh() {
        if (this.refreshInFlight) {
            this.refreshQueued = true;
            return;
        }
        this.refreshInFlight = true;
        try {
            await Promise.all(
                [this.wiredRegistrations, this.wiredBudgets].filter((wired) => wired).map((wired) => refreshApex(wired))
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
        return [this.wiredRegistrations, this.wiredBudgets].some(
            (wired) => !wired || (wired.data === undefined && wired.error === undefined)
        );
    }

    get agents() {
        const usageByAgent = {};
        this.budgets.forEach((budget) => {
            if (budget.Agent_Registration__c) {
                const allocated =
                    (budget.API_Calls_Allocated__c || 0) +
                    (budget.SOQL_Queries_Allocated__c || 0) +
                    (budget.DML_Operations_Allocated__c || 0);
                const consumed =
                    (budget.API_Calls_Consumed__c || 0) +
                    (budget.SOQL_Queries_Consumed__c || 0) +
                    (budget.DML_Operations_Consumed__c || 0);
                usageByAgent[budget.Agent_Registration__c] = percentOf(consumed, allocated);
            }
        });
        return this.registrations.map((registration) => {
            const breakerState = registration.Circuit_Breaker_State__c || 'CLOSED';
            const budgetPercent = usageByAgent[registration.Id] || 0;
            return {
                ...registration,
                breakerState,
                breakerIcon: BREAKER_ICON[breakerState] || 'utility:success',
                breakerVariant: BREAKER_VARIANT[breakerState] || 'success',
                breakerAltText: `Circuit breaker ${breakerState}`,
                statusBadgeClass: STATUS_BADGE[registration.Status__c] || 'slds-badge',
                budgetPercent,
                budgetBarStyle: `width: ${budgetPercent}%`,
                budgetBarClass: `progress-bar bar-${usageLevel(budgetPercent)}`,
                budgetAriaLabel: `${registration.Agent_Name__c} budget used today ${budgetPercent} percent`,
                hasFailures: (registration.Failure_Count__c || 0) > 0,
                lastActiveFormatted: registration.Last_Active__c ? formatDateTime(registration.Last_Active__c) : 'Never'
            };
        });
    }

    get hasAgents() {
        return this.registrations.length > 0;
    }

    settle(result) {
        if (result.error) {
            this.reportError(result.error);
            return [];
        }
        if (result.data !== undefined) {
            this.error = undefined;
            return result.data || [];
        }
        return [];
    }

    reportError(error) {
        const message = reduceErrors(error).join('. ');
        this.error = message;
        if (message && message !== this.lastToastedError) {
            this.lastToastedError = message;
            this.dispatchEvent(new ShowToastEvent({ title: 'Agent health could not load', message, variant: 'error' }));
        }
    }
}
