import { LightningElement } from 'lwc';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovSelector.getAllTodaysBudgets';

export default class AgentBudgetAllocation extends LightningElement {
    budgets = [];
    error;
    isLoading = true;
    totalApiAllocated = 0;
    totalSoqlAllocated = 0;
    totalDmlAllocated = 0;

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        this.isLoading = true;
        try {
            const data = await getAllTodaysBudgets();
            let totalApi = 0;
            let totalSoql = 0;
            let totalDml = 0;

            this.budgets = (data || []).map(b => {
                const apiAllocated = b.API_Calls_Allocated__c || 0;
                const soqlAllocated = b.SOQL_Queries_Allocated__c || 0;
                const dmlAllocated = b.DML_Operations_Allocated__c || 0;
                const apiConsumed = b.API_Calls_Consumed__c || 0;
                const soqlConsumed = b.SOQL_Queries_Consumed__c || 0;
                const dmlConsumed = b.DML_Operations_Consumed__c || 0;

                totalApi += apiAllocated;
                totalSoql += soqlAllocated;
                totalDml += dmlAllocated;

                const apiPercent = apiAllocated > 0 ? Math.round((apiConsumed / apiAllocated) * 100) : 0;
                const soqlPercent = soqlAllocated > 0 ? Math.round((soqlConsumed / soqlAllocated) * 100) : 0;
                const dmlPercent = dmlAllocated > 0 ? Math.round((dmlConsumed / dmlAllocated) * 100) : 0;

                return {
                    ...b,
                    agentName: b.Agent_Registration__r ? b.Agent_Registration__r.Agent_Name__c : 'Unknown',
                    apiAllocated, apiConsumed, apiPercent,
                    apiBarStyle: `width: ${apiPercent}%`,
                    apiBarClass: this.getBarClass(apiPercent),
                    soqlAllocated, soqlConsumed, soqlPercent,
                    soqlBarStyle: `width: ${soqlPercent}%`,
                    soqlBarClass: this.getBarClass(soqlPercent),
                    dmlAllocated, dmlConsumed, dmlPercent,
                    dmlBarStyle: `width: ${dmlPercent}%`,
                    dmlBarClass: this.getBarClass(dmlPercent),
                    isWarning: apiPercent >= 80 || soqlPercent >= 80 || dmlPercent >= 80,
                    statusIcon: b.Budget_Status__c === 'Normal' ? 'utility:success' : (b.Budget_Status__c === 'Warning' ? 'utility:warning' : 'utility:error')
                };
            });

            this.totalApiAllocated = totalApi;
            this.totalSoqlAllocated = totalSoql;
            this.totalDmlAllocated = totalDml;
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

    getBarClass(percent) {
        if (percent >= 90) return 'progress-fill bar-danger';
        if (percent >= 70) return 'progress-fill bar-warning';
        return 'progress-fill bar-normal';
    }

    get hasBudgets() {
        return this.budgets.length > 0;
    }
}
