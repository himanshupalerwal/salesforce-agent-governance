/**
 * Table of recent conflicts between agents. Refreshes on demand and on AgentGov platform events.
 */
import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getRecentConflictLogs from '@salesforce/apex/AgentGovDashboardController.getRecentConflictLogs';
import {
    combineErrors,
    describeError,
    formatDateTime,
    formatTime,
    listenToAgentGovEvents,
    recordUrl,
    refreshedMessage
} from 'c/agentGovUtils';

const ROWS = 50;
const FRAMED_ROWS = 12;
const COLUMNS = [
    { label: 'Time', fieldName: 'formattedTime', type: 'text', sortable: false },
    {
        label: 'Agent 1',
        fieldName: 'agent1Url',
        type: 'url',
        typeAttributes: { label: { fieldName: 'agent1Name' }, target: '_self' }
    },
    {
        label: 'Agent 2',
        fieldName: 'agent2Url',
        type: 'url',
        typeAttributes: { label: { fieldName: 'agent2Name' }, target: '_self' }
    },
    { label: 'Object', fieldName: 'Object_Name__c', type: 'text' },
    { label: 'Record', fieldName: 'Record_Id__c', type: 'text' },
    { label: 'Type', fieldName: 'typeLabel', type: 'text' },
    { label: 'Outcome', fieldName: 'outcome', type: 'text', wrapText: true },
    {
        label: 'Severity',
        fieldName: 'Severity__c',
        type: 'text',
        cellAttributes: { class: { fieldName: 'severityCellClass' } }
    }
];

// "Concurrent_Write" reads as "Concurrent write".
function sentenceCase(value) {
    const words = (value || '').replace(/_/g, ' ').toLowerCase();
    return words.charAt(0).toUpperCase() + words.slice(1);
}

// Names the agent that went ahead, which Resolution__c records only as Agent1_Won or Agent2_Won.
function outcomeOf(conflict) {
    const agent1 = conflict.Agent_1__r ? conflict.Agent_1__r.Agent_Name__c : 'Agent 1';
    const agent2 = conflict.Agent_2__r ? conflict.Agent_2__r.Agent_Name__c : 'Agent 2';
    if (conflict.Resolution__c === 'Agent1_Won') {
        return `${agent1} went ahead`;
    }
    if (conflict.Resolution__c === 'Agent2_Won') {
        return `${agent2} went ahead`;
    }
    return sentenceCase(conflict.Resolution__c);
}

export default class AgentConflictViewer extends LightningElement {
    columns = COLUMNS;
    rowLimit = ROWS;
    conflicts = [];
    lastUpdated;
    announcement = '';
    refreshing = false;
    errors = {};

    wiredConflicts;
    refreshInFlight = false;
    refreshQueued = false;
    manualRefreshPending = false;
    lastToastedError;

    @wire(getRecentConflictLogs, { limitCount: '$rowLimit' })
    handleConflicts(result) {
        this.wiredConflicts = result;
        if (result.error) {
            this.reportError('load', result.error);
            this.conflicts = [];
        } else if (result.data !== undefined) {
            this.clearError('load');
            this.lastUpdated = new Date();
            this.conflicts = (result.data || []).map((conflict) => ({
                ...conflict,
                agent1Name: conflict.Agent_1__r ? conflict.Agent_1__r.Agent_Name__c : 'Unknown',
                agent1Url: recordUrl(conflict.Agent_1__c),
                agent2Name: conflict.Agent_2__r ? conflict.Agent_2__r.Agent_Name__c : 'Unknown',
                agent2Url: recordUrl(conflict.Agent_2__c),
                formattedTime: formatDateTime(conflict.Timestamp__c),
                typeLabel: sentenceCase(conflict.Conflict_Type__c),
                outcome: outcomeOf(conflict),
                severityCellClass: conflict.Severity__c === 'High' ? 'slds-text-color_error' : ''
            }));
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

    /**
     * Refreshes the conflicts. A refresh requested while one is running is performed once the
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
            if (this.wiredConflicts) {
                await refreshApex(this.wiredConflicts);
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
        return (
            !this.wiredConflicts || (this.wiredConflicts.data === undefined && this.wiredConflicts.error === undefined)
        );
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

    get hasConflicts() {
        return this.conflicts.length > 0;
    }

    get conflictCount() {
        return this.conflicts.length;
    }

    // A long list scrolls inside a frame with its header pinned, so the tab stays short.
    get tableFrameClass() {
        return this.conflicts.length > FRAMED_ROWS ? 'ag-datatable-frame' : '';
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
            this.dispatchEvent(new ShowToastEvent({ title: 'Conflicts could not load', message, variant: 'error' }));
        }
    }
}
