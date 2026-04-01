import { LightningElement } from 'lwc';
import getAllRegistrations from '@salesforce/apex/AgentGovSelector.getAllRegistrations';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovSelector.getAllTodaysBudgets';

export default class AgentHealthMonitor extends LightningElement {
    agents = [];
    error;
    isLoading = true;

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        this.isLoading = true;
        try {
            const [registrations, budgets] = await Promise.all([
                getAllRegistrations(),
                getAllTodaysBudgets()
            ]);

            const budgetMap = {};
            (budgets || []).forEach(b => {
                if (b.Agent_Registration__c) {
                    const totalAllocated = (b.API_Calls_Allocated__c || 0)
                        + (b.SOQL_Queries_Allocated__c || 0)
                        + (b.DML_Operations_Allocated__c || 0);
                    const totalConsumed = (b.API_Calls_Consumed__c || 0)
                        + (b.SOQL_Queries_Consumed__c || 0)
                        + (b.DML_Operations_Consumed__c || 0);
                    budgetMap[b.Agent_Registration__c] = totalAllocated > 0
                        ? Math.round((totalConsumed / totalAllocated) * 100) : 0;
                }
            });

            this.agents = (registrations || []).map(reg => {
                const cbState = reg.Circuit_Breaker_State__c || 'CLOSED';
                const budgetPercent = budgetMap[reg.Id] || 0;
                return {
                    ...reg,
                    cbState,
                    cbClass: this.getCbClass(cbState),
                    cbIcon: this.getCbIcon(cbState),
                    statusBadgeClass: this.getStatusBadgeClass(reg.Status__c),
                    budgetPercent,
                    budgetBarStyle: `width: ${budgetPercent}%`,
                    budgetBarClass: this.getBudgetBarClass(budgetPercent),
                    lastActiveFormatted: reg.Last_Active__c
                        ? new Date(reg.Last_Active__c).toLocaleString()
                        : 'Never'
                };
            });

            this.error = undefined;
        } catch (err) {
            this.error = err.body ? err.body.message : err.message;
        } finally {
            this.isLoading = false;
        }
    }

    handleRefresh() {
        this.loadData();
    }

    getCbClass(state) {
        const map = {
            CLOSED: 'cb-closed',
            OPEN: 'cb-open',
            HALF_OPEN: 'cb-half-open'
        };
        return map[state] || 'cb-closed';
    }

    getCbIcon(state) {
        const map = {
            CLOSED: 'utility:success',
            OPEN: 'utility:error',
            HALF_OPEN: 'utility:warning'
        };
        return map[state] || 'utility:success';
    }

    getStatusBadgeClass(status) {
        const map = {
            Active: 'slds-badge slds-theme_success',
            Inactive: 'slds-badge',
            Throttled: 'slds-badge slds-theme_warning',
            Blocked: 'slds-badge slds-theme_error'
        };
        return map[status] || 'slds-badge';
    }

    getBudgetBarClass(percent) {
        if (percent >= 90) return 'progress-bar bar-danger';
        if (percent >= 70) return 'progress-bar bar-warning';
        return 'progress-bar bar-normal';
    }

    get hasAgents() {
        return this.agents.length > 0;
    }
}
