/**
 * Per-agent breakdown of today's budgets across the three limit types, with org-wide totals.
 * Refreshes on demand and on AgentGov platform events.
 */
import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovDashboardController.getAllTodaysBudgets';
import {
    reduceErrors,
    usageLevel,
    percentOf,
    subscribeToAgentGovEvents,
    unsubscribeFromAgentGovEvents
} from 'c/agentGovUtils';

const STATUS_ICON = { Normal: 'utility:success', Warning: 'utility:warning' };
const WARNING_PERCENT = 80;

export default class AgentBudgetAllocation extends LightningElement {
    rawBudgets = [];
    error;

    wiredBudgets;
    subscriptions = [];
    refreshInFlight = false;
    refreshQueued = false;
    lastToastedError;

    @wire(getAllTodaysBudgets)
    handleBudgets(result) {
        this.wiredBudgets = result;
        if (result.error) {
            this.reportError(result.error);
            this.rawBudgets = [];
        } else if (result.data !== undefined) {
            this.error = undefined;
            this.rawBudgets = result.data || [];
        }
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
            if (this.wiredBudgets) {
                await refreshApex(this.wiredBudgets);
            }
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
        return !this.wiredBudgets || (this.wiredBudgets.data === undefined && this.wiredBudgets.error === undefined);
    }

    get budgets() {
        return this.rawBudgets.map((budget) => {
            const agentName = budget.Agent_Registration__r ? budget.Agent_Registration__r.Agent_Name__c : 'Unknown';
            const api = this.limitView(
                agentName,
                'API calls',
                budget.API_Calls_Consumed__c,
                budget.API_Calls_Allocated__c
            );
            const soql = this.limitView(
                agentName,
                'SOQL queries',
                budget.SOQL_Queries_Consumed__c,
                budget.SOQL_Queries_Allocated__c
            );
            const dml = this.limitView(
                agentName,
                'DML operations',
                budget.DML_Operations_Consumed__c,
                budget.DML_Operations_Allocated__c
            );
            return {
                ...budget,
                agentName,
                api,
                soql,
                dml,
                isWarning: [api, soql, dml].some((limit) => limit.percent >= WARNING_PERCENT),
                statusIcon: STATUS_ICON[budget.Budget_Status__c] || 'utility:error',
                statusAltText: `Budget status ${budget.Budget_Status__c}`
            };
        });
    }

    get totalApiAllocated() {
        return this.rawBudgets.reduce((sum, budget) => sum + (budget.API_Calls_Allocated__c || 0), 0);
    }

    get totalSoqlAllocated() {
        return this.rawBudgets.reduce((sum, budget) => sum + (budget.SOQL_Queries_Allocated__c || 0), 0);
    }

    get totalDmlAllocated() {
        return this.rawBudgets.reduce((sum, budget) => sum + (budget.DML_Operations_Allocated__c || 0), 0);
    }

    get hasBudgets() {
        return this.rawBudgets.length > 0;
    }

    limitView(agentName, label, consumed, allocated) {
        const percent = percentOf(consumed, allocated);
        return {
            consumed: consumed || 0,
            allocated: allocated || 0,
            percent,
            barStyle: `width: ${percent}%`,
            barClass: `progress-fill bar-${usageLevel(percent)}`,
            ariaLabel: `${agentName} ${label} ${percent} percent used`
        };
    }

    reportError(error) {
        const message = reduceErrors(error).join('. ');
        this.error = message;
        if (message && message !== this.lastToastedError) {
            this.lastToastedError = message;
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Budget allocation could not load', message, variant: 'error' })
            );
        }
    }
}
