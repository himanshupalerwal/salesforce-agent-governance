/**
 * Table of recent conflicts between agents. Refreshes on demand and on AgentGov platform events.
 */
import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getRecentConflictLogs from '@salesforce/apex/AgentGovDashboardController.getRecentConflictLogs';
import {
    reduceErrors,
    formatDateTime,
    subscribeToAgentGovEvents,
    unsubscribeFromAgentGovEvents
} from 'c/agentGovUtils';

const ROWS = 50;
const COLUMNS = [
    { label: 'Time', fieldName: 'formattedTime', type: 'text', sortable: false },
    { label: 'Agent 1', fieldName: 'agent1Name', type: 'text' },
    { label: 'Agent 2', fieldName: 'agent2Name', type: 'text' },
    { label: 'Object', fieldName: 'Object_Name__c', type: 'text' },
    { label: 'Record', fieldName: 'Record_Id__c', type: 'text' },
    { label: 'Type', fieldName: 'Conflict_Type__c', type: 'text' },
    { label: 'Resolution', fieldName: 'Resolution__c', type: 'text' },
    {
        label: 'Severity',
        fieldName: 'Severity__c',
        type: 'text',
        cellAttributes: { class: { fieldName: 'severityCellClass' } }
    }
];

export default class AgentConflictViewer extends LightningElement {
    columns = COLUMNS;
    rowLimit = ROWS;
    conflicts = [];
    error;

    wiredConflicts;
    subscriptions = [];
    refreshInFlight = false;
    refreshQueued = false;
    lastToastedError;

    @wire(getRecentConflictLogs, { limitCount: '$rowLimit' })
    handleConflicts(result) {
        this.wiredConflicts = result;
        if (result.error) {
            this.reportError(result.error);
            this.conflicts = [];
        } else if (result.data !== undefined) {
            this.error = undefined;
            this.conflicts = (result.data || []).map((conflict) => ({
                ...conflict,
                agent1Name: conflict.Agent_1__r ? conflict.Agent_1__r.Agent_Name__c : 'Unknown',
                agent2Name: conflict.Agent_2__r ? conflict.Agent_2__r.Agent_Name__c : 'Unknown',
                formattedTime: formatDateTime(conflict.Timestamp__c),
                severityCellClass: conflict.Severity__c === 'High' ? 'slds-text-color_error' : ''
            }));
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
            if (this.wiredConflicts) {
                await refreshApex(this.wiredConflicts);
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
        return (
            !this.wiredConflicts || (this.wiredConflicts.data === undefined && this.wiredConflicts.error === undefined)
        );
    }

    get hasConflicts() {
        return this.conflicts.length > 0;
    }

    get conflictCount() {
        return this.conflicts.length;
    }

    reportError(error) {
        const message = reduceErrors(error).join('. ');
        this.error = message;
        if (message && message !== this.lastToastedError) {
            this.lastToastedError = message;
            this.dispatchEvent(new ShowToastEvent({ title: 'Conflicts could not load', message, variant: 'error' }));
        }
    }
}
