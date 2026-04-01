import { LightningElement } from 'lwc';
import getRecentConflictLogs from '@salesforce/apex/AgentGovSelector.getRecentConflictLogs';

const COLUMNS = [
    { label: 'Time', fieldName: 'formattedTime', type: 'text', sortable: true },
    { label: 'Agent 1', fieldName: 'agent1Name', type: 'text' },
    { label: 'Agent 2', fieldName: 'agent2Name', type: 'text' },
    { label: 'Object', fieldName: 'Object_Name__c', type: 'text' },
    { label: 'Record', fieldName: 'Record_Id__c', type: 'text' },
    { label: 'Type', fieldName: 'Conflict_Type__c', type: 'text' },
    { label: 'Resolution', fieldName: 'Resolution__c', type: 'text' },
    { label: 'Severity', fieldName: 'Severity__c', type: 'text', cellAttributes: { class: { fieldName: 'severityCellClass' } } }
];

export default class AgentConflictViewer extends LightningElement {
    columns = COLUMNS;
    conflicts = [];
    error;
    isLoading = true;

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        this.isLoading = true;
        try {
            const data = await getRecentConflictLogs({ limitCount: 50 });
            this.conflicts = (data || []).map(c => ({
                ...c,
                agent1Name: c.Agent_1__r ? c.Agent_1__r.Agent_Name__c : 'Unknown',
                agent2Name: c.Agent_2__r ? c.Agent_2__r.Agent_Name__c : 'Unknown',
                formattedTime: c.Timestamp__c ? new Date(c.Timestamp__c).toLocaleString() : '',
                severityCellClass: c.Severity__c === 'High' ? 'slds-text-color_error' : ''
            }));
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

    get hasConflicts() {
        return this.conflicts.length > 0;
    }

    get conflictCount() {
        return this.conflicts.length;
    }
}
