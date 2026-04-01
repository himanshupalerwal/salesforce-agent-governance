import { LightningElement } from 'lwc';
import getAllRegistrations from '@salesforce/apex/AgentGovSelector.getAllRegistrations';
import getAllTodaysBudgets from '@salesforce/apex/AgentGovSelector.getAllTodaysBudgets';
import getRecentConflictLogs from '@salesforce/apex/AgentGovSelector.getRecentConflictLogs';
import getTodaysActionCount from '@salesforce/apex/AgentGovSelector.getTodaysActionCount';
import getActiveSessions from '@salesforce/apex/AgentGovSelector.getActiveSessions';
import getTrippedCircuitBreakerCount from '@salesforce/apex/AgentGovSelector.getTrippedCircuitBreakerCount';

export default class AgentGovDashboard extends LightningElement {
    agents = [];
    budgets = [];
    conflicts = [];
    sessions = [];
    totalAgents = 0;
    activeAgents = 0;
    actionsToday = 0;
    activeSessions = 0;
    trippedBreakers = 0;
    conflictsDetected = 0;
    avgBudgetUtilization = 0;
    error;
    isLoading = true;

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        this.isLoading = true;
        try {
            const [allAgents, budgets, conflicts, actionCount, sessions, trippedCount] = await Promise.all([
                getAllRegistrations(),
                getAllTodaysBudgets(),
                getRecentConflictLogs({ limitCount: 10 }),
                getTodaysActionCount(),
                getActiveSessions(),
                getTrippedCircuitBreakerCount()
            ]);

            this.agents = allAgents || [];
            this.totalAgents = this.agents.length;
            this.activeAgents = this.agents.filter(a => a.Status__c === 'Active').length;
            this.actionsToday = actionCount || 0;
            this.sessions = sessions || [];
            this.activeSessions = this.sessions.length;
            this.trippedBreakers = trippedCount || 0;

            this.budgets = (budgets || []).map(b => {
                const apiPercent = b.API_Calls_Allocated__c > 0
                    ? Math.round((b.API_Calls_Consumed__c / b.API_Calls_Allocated__c) * 100) : 0;
                const soqlPercent = b.SOQL_Queries_Allocated__c > 0
                    ? Math.round((b.SOQL_Queries_Consumed__c / b.SOQL_Queries_Allocated__c) * 100) : 0;
                const dmlPercent = b.DML_Operations_Allocated__c > 0
                    ? Math.round((b.DML_Operations_Consumed__c / b.DML_Operations_Allocated__c) * 100) : 0;
                const avgPercent = Math.round((apiPercent + soqlPercent + dmlPercent) / 3);
                return {
                    ...b,
                    agentName: b.Agent_Registration__r ? b.Agent_Registration__r.Agent_Name__c : 'Unknown',
                    apiPercent, soqlPercent, dmlPercent, avgPercent,
                    statusClass: this.getStatusClass(b.Budget_Status__c),
                    barStyle: `width: ${avgPercent}%`,
                    barClass: `slds-progress-bar__value ${this.getBarClass(avgPercent)}`
                };
            });

            if (this.budgets.length > 0) {
                const totalPercent = this.budgets.reduce((sum, b) => sum + b.avgPercent, 0);
                this.avgBudgetUtilization = Math.round(totalPercent / this.budgets.length);
            }

            this.conflicts = (conflicts || []).map(c => ({
                ...c,
                agent1Name: c.Agent_1__r ? c.Agent_1__r.Agent_Name__c : 'Unknown',
                agent2Name: c.Agent_2__r ? c.Agent_2__r.Agent_Name__c : 'Unknown',
                severityClass: `slds-badge ${this.getSeverityClass(c.Severity__c)}`,
                formattedTime: c.Timestamp__c ? new Date(c.Timestamp__c).toLocaleString() : ''
            }));
            this.conflictsDetected = this.conflicts.length;

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

    getStatusClass(status) {
        const map = {
            Normal: 'slds-theme_success', Warning: 'slds-theme_warning',
            Throttled: 'slds-theme_warning', Blocked: 'slds-theme_error',
            Exhausted: 'slds-theme_error'
        };
        return map[status] || '';
    }

    getBarClass(percent) {
        if (percent >= 90) return 'slds-progress-bar__value_success bar-danger';
        if (percent >= 70) return 'slds-progress-bar__value_success bar-warning';
        return 'slds-progress-bar__value_success bar-normal';
    }

    getSeverityClass(severity) {
        const map = { High: 'badge-high', Medium: 'badge-medium', Low: 'badge-low' };
        return map[severity] || '';
    }

    get hasAgents() { return this.agents.length > 0; }
    get hasBudgets() { return this.budgets.length > 0; }
    get hasConflicts() { return this.conflicts.length > 0; }
    get hasSessions() { return this.sessions.length > 0; }
    get trippedBreakersClass() {
        return this.trippedBreakers > 0 ? 'slds-text-heading_large slds-text-color_error' : 'slds-text-heading_large slds-text-color_success';
    }
}
