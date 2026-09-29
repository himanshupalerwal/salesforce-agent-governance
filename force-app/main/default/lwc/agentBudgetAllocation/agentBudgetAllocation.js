/**
 * Per-agent breakdown of today's budgets across the three limit types, with org-wide totals.
 * Refreshes on demand and on AgentGov platform events.
 */
import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovDashboardController.getAllTodaysBudgets';
import {
    budgetStatusView,
    combineErrors,
    describeError,
    followRecordLink,
    formatNumber,
    formatTime,
    listenToAgentGovEvents,
    percentOf,
    recordUrl,
    refreshedMessage,
    usageLevel
} from 'c/agentGovUtils';

const WARNING_PERCENT = 80;

export default class AgentBudgetAllocation extends NavigationMixin(LightningElement) {
    rawBudgets = [];
    lastUpdated;
    announcement = '';
    refreshing = false;
    errors = {};

    wiredBudgets;
    refreshInFlight = false;
    refreshQueued = false;
    manualRefreshPending = false;
    lastToastedError;

    @wire(getAllTodaysBudgets)
    handleBudgets(result) {
        this.wiredBudgets = result;
        if (result.error) {
            this.reportError('load', result.error);
            this.rawBudgets = [];
        } else if (result.data !== undefined) {
            this.clearError('load');
            this.rawBudgets = result.data || [];
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

    handleRefresh() {
        this.refresh({ manual: true });
    }

    handleRecordLink(event) {
        followRecordLink(this, event);
    }

    /**
     * Refreshes the budgets. A refresh requested while one is running is performed once the
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
            if (this.wiredBudgets) {
                await refreshApex(this.wiredBudgets);
            }
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
        return !this.wiredBudgets || (this.wiredBudgets.data === undefined && this.wiredBudgets.error === undefined);
    }

    get error() {
        return combineErrors(this.errors);
    }

    get refreshLabel() {
        return this.refreshing ? 'Refreshing…' : 'Refresh';
    }

    get lastUpdatedLabel() {
        return this.lastUpdated ? `Updated ${formatTime(this.lastUpdated, { seconds: true })}` : '';
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
            const status = budgetStatusView(budget.Budget_Status__c);
            return {
                ...budget,
                agentName,
                agentUrl: recordUrl(budget.Agent_Registration__c),
                api,
                soql,
                dml,
                isWarning: [api, soql, dml].some((limit) => limit.percent >= WARNING_PERCENT),
                statusLabel: budget.Budget_Status__c || 'Unknown',
                statusPillClass: `${status.pillClass} status-label`
            };
        });
    }

    get totalApiAllocated() {
        return formatNumber(this.rawBudgets.reduce((sum, budget) => sum + (budget.API_Calls_Allocated__c || 0), 0));
    }

    get totalSoqlAllocated() {
        return formatNumber(this.rawBudgets.reduce((sum, budget) => sum + (budget.SOQL_Queries_Allocated__c || 0), 0));
    }

    get totalDmlAllocated() {
        return formatNumber(
            this.rawBudgets.reduce((sum, budget) => sum + (budget.DML_Operations_Allocated__c || 0), 0)
        );
    }

    get hasBudgets() {
        return this.rawBudgets.length > 0;
    }

    limitView(agentName, label, consumed, allocated) {
        const percent = percentOf(consumed, allocated);
        return {
            consumed: formatNumber(consumed),
            allocated: formatNumber(allocated),
            percent,
            barStyle: `width: ${percent}%`,
            barClass: `ag-bar ag-bar_${usageLevel(percent)} progress-fill`,
            ariaLabel: `${agentName} ${label} ${percent} percent used`
        };
    }

    clearError(key) {
        if (this.errors[key]) {
            const remaining = { ...this.errors };
            delete remaining[key];
            this.errors = remaining;
        }
    }

    reportError(key, error) {
        const message = describeError(error);
        this.errors = { ...this.errors, [key]: message };
        if (message && message !== this.lastToastedError) {
            this.lastToastedError = message;
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Budget allocation could not load', message, variant: 'error' })
            );
        }
    }
}
