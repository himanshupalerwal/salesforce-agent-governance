/**
 * Daily budget usage as an accessible table with an inline bar per day: one agent's usage on
 * its record page, or usage summed across every agent the viewer can see when no record is set.
 * The bar shows the day's peak usage, the most-used limit type as a share of its allocation.
 * Reads go through the cacheable, USER_MODE AgentGovDashboardController.getUsageHistory.
 */
import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getUsageHistory from '@salesforce/apex/AgentGovDashboardController.getUsageHistory';
import {
    budgetStatusView,
    clampPercent,
    describeError,
    formatDate,
    formatNumber,
    listenToAgentGovEvents,
    usageLevel
} from 'c/agentGovUtils';

const DEFAULT_DAYS = 7;
const MAX_DAYS = 90;
const WINDOW_CHOICES = [7, 30];

export default class AgentGovUsageHistory extends LightningElement {
    agentId = null;
    configuredDays = DEFAULT_DAYS;
    selectedDays = DEFAULT_DAYS;

    history = [];
    error;
    wiredHistory;

    /**
     * The agent whose usage to show. Without it, usage is summed across every visible agent.
     * @type {string}
     */
    @api
    get recordId() {
        return this.agentId || undefined;
    }
    set recordId(value) {
        this.agentId = value || null;
    }

    /**
     * Days shown at first, at most 90. The period can then be switched between this value and
     * the 7 and 30 day choices.
     * @type {number}
     */
    @api
    get days() {
        return this.configuredDays;
    }
    set days(value) {
        const parsed = parseInt(value, 10);
        this.configuredDays = parsed > 0 ? Math.min(parsed, MAX_DAYS) : DEFAULT_DAYS;
        this.selectedDays = this.configuredDays;
    }

    @wire(getUsageHistory, { registrationId: '$agentId', days: '$selectedDays' })
    handleHistory(result) {
        this.wiredHistory = result;
        if (result.error) {
            this.error = describeError(result.error);
            this.history = [];
        } else if (result.data !== undefined) {
            this.error = undefined;
            this.history = result.data || [];
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

    /**
     * Reloads the usage history.
     * @returns {Promise}
     */
    @api
    refresh() {
        if (!this.wiredHistory) {
            return Promise.resolve();
        }
        return refreshApex(this.wiredHistory).catch((error) => {
            this.error = describeError(error);
        });
    }

    handleWindowChange(event) {
        this.selectedDays = parseInt(event.detail.value, 10);
    }

    get isLoading() {
        return !this.wiredHistory || (this.wiredHistory.data === undefined && this.wiredHistory.error === undefined);
    }

    get windowOptions() {
        return Array.from(new Set([...WINDOW_CHOICES, this.configuredDays]))
            .sort((a, b) => a - b)
            .map((days) => ({ label: `${days} days`, value: String(days) }));
    }

    get selectedWindow() {
        return String(this.selectedDays);
    }

    get caption() {
        const scope = this.agentId ? 'this agent' : 'all agents you can see, added together';
        return `Daily usage over the last ${this.selectedDays} days for ${scope}. Peak usage is the most-used limit type as a share of its daily allocation.`;
    }

    get emptyMessage() {
        return `No budget usage recorded in the last ${this.selectedDays} days.`;
    }

    get hasHistory() {
        return this.history.length > 0;
    }

    get showStatus() {
        return this.history.some((day) => !!day.budgetStatus);
    }

    get rows() {
        const showStatus = this.showStatus;
        // Newest first, so the day that matters most is at the top.
        return [...this.history].reverse().map((day) => {
            const percent = clampPercent(day.peakUsagePercent);
            const status = budgetStatusView(day.budgetStatus);
            return {
                key: day.day,
                label: formatDate(day.day),
                apiCalls: formatNumber(day.apiCalls),
                soqlQueries: formatNumber(day.soqlQueries),
                dmlOperations: formatNumber(day.dmlOperations),
                percent,
                barStyle: `width: ${percent}%`,
                barClass: `ag-bar ag-bar_${usageLevel(percent)} history-fill bar-${usageLevel(percent)}`,
                showStatus,
                statusLabel: day.budgetStatus || 'None',
                statusPillClass: `${status.pillClass} status-label`
            };
        });
    }
}
