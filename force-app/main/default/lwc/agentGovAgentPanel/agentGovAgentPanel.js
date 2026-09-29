/**
 * Governance panel for an agent's record page: circuit breaker state and cooldown, today's usage
 * of each limit, the live session, the credentials (key prefix, last rotation, user binding), and
 * the actions the viewer may take, followed by the agent's recent activity and usage history.
 *
 * Reads go through the cacheable, USER_MODE AgentGovDashboardController.getAgentSummary. Actions
 * go through c/agentGovAdminActions; afterwards the panel tells Lightning Data Service that the
 * record changed, so the highlights panel and record detail on the same page reload too.
 */
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { registerRefreshHandler, unregisterRefreshHandler } from 'lightning/refresh';
import getAgentSummary from '@salesforce/apex/AgentGovDashboardController.getAgentSummary';
import {
    agentStatusView,
    agentTypeLabel,
    breakerView,
    budgetStatusView,
    clampPercent,
    combineErrors,
    describeError,
    followRecordLink,
    formatDateTime,
    formatNumber,
    formatRelativeTime,
    formatTime,
    listenToAgentGovEvents,
    listenToClock,
    recordUrl,
    refreshedMessage,
    restoreFocus,
    usageLevel
} from 'c/agentGovUtils';
import { actionsFor, runAgentAction } from 'c/agentGovAdminActions';

const SESSION_OBJECT = 'AgentGov_Session__c';
const LIMITS = [
    { key: 'api', label: 'API calls', field: 'apiUsagePercent' },
    { key: 'soql', label: 'SOQL queries', field: 'soqlUsagePercent' },
    { key: 'dml', label: 'DML operations', field: 'dmlUsagePercent' }
];

export default class AgentGovAgentPanel extends NavigationMixin(LightningElement) {
    @api recordId;

    summary;
    wiredSummary;
    errors = {};
    lastUpdated;
    announcement = '';
    refreshing = false;
    actionInProgress = false;
    now = Date.now();

    @wire(getAgentSummary, { registrationId: '$recordId' })
    handleSummary(result) {
        this.wiredSummary = result;
        if (result.error) {
            this.setError('load', result.error);
            this.summary = undefined;
        } else if (result.data !== undefined) {
            this.clearError('load');
            this.summary = result.data || undefined;
            this.lastUpdated = new Date();
        }
    }

    connectedCallback() {
        this.releaseEvents = listenToAgentGovEvents(() => this.refreshSummary());
        this.releaseClock = listenToClock((now) => {
            this.now = now;
        });
        this.refreshHandlerId = registerRefreshHandler(this, this.handlePageRefresh);
    }

    disconnectedCallback() {
        if (this.releaseEvents) {
            this.releaseEvents();
            this.releaseEvents = undefined;
        }
        if (this.releaseClock) {
            this.releaseClock();
            this.releaseClock = undefined;
        }
        if (this.refreshHandlerId !== undefined) {
            unregisterRefreshHandler(this.refreshHandlerId);
            this.refreshHandlerId = undefined;
        }
    }

    /**
     * Reloads the panel, the activity log, and the usage history.
     * @returns {Promise}
     */
    @api
    async refresh() {
        const children = this.refs ? [this.refs.activity, this.refs.history].filter((child) => child) : [];
        await Promise.all([this.refreshSummary(), ...children.map((child) => child.refresh())]);
    }

    handlePageRefresh() {
        return this.refresh().then(() => true);
    }

    async handleRefresh() {
        this.refreshing = true;
        try {
            await this.refresh();
            if (!this.errors.refresh) {
                this.announcement = refreshedMessage(this.lastUpdated);
            }
        } finally {
            this.refreshing = false;
        }
    }

    async refreshSummary() {
        if (!this.wiredSummary) {
            return;
        }
        try {
            await refreshApex(this.wiredSummary);
            this.clearError('refresh');
            this.lastUpdated = new Date();
        } catch (error) {
            this.setError('refresh', error);
        }
    }

    handleRecordLink(event) {
        followRecordLink(this, event);
    }

    async handleAction(event) {
        const trigger = event.currentTarget;
        if (!this.summary || this.actionInProgress) {
            return;
        }
        this.actionInProgress = true;
        let result;
        try {
            result = await runAgentAction(this, trigger.dataset.action, [this.summary]);
        } catch (error) {
            result = { changed: false, message: describeError(error) };
        } finally {
            this.actionInProgress = false;
        }
        if (result.changed) {
            await this.refresh();
            // The highlights panel and record detail read the record through Lightning Data
            // Service, which does not see changes made by Apex until it is told about them.
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        }
        if (result.message) {
            this.announcement = result.message;
        }
        await Promise.resolve();
        restoreFocus(trigger, this.refs.heading);
    }

    // --- View state ---

    get isLoading() {
        return !this.wiredSummary || (this.wiredSummary.data === undefined && this.wiredSummary.error === undefined);
    }

    get hasSummary() {
        return !!this.summary;
    }

    get errorMessage() {
        return combineErrors(this.errors);
    }

    get refreshLabel() {
        return this.refreshing ? 'Refreshing…' : 'Refresh';
    }

    get lastUpdatedLabel() {
        return this.lastUpdated ? `Updated ${formatTime(this.lastUpdated, { seconds: true })}` : '';
    }

    get heading() {
        return this.summary ? this.summary.name : 'Governance';
    }

    get subtitle() {
        if (!this.summary) {
            return 'Governance';
        }
        const { agentType, priority, lastActive } = this.summary;
        const parts = [agentTypeLabel(agentType)];
        if (priority !== null && priority !== undefined) {
            parts.push(`Priority ${formatNumber(priority)}`);
        }
        if (lastActive) {
            parts.push(`Active ${formatRelativeTime(lastActive, this.now)}`);
        }
        return parts.filter((part) => part).join(' · ');
    }

    get breaker() {
        return breakerView(this.summary.breakerState, this.summary.cooldownUntil, this.now);
    }

    get statusPillClass() {
        return `${agentStatusView(this.summary.status).pillClass} status-pill`;
    }

    get breakerPillClass() {
        return this.breaker.pillClass;
    }

    get breakerPillLabel() {
        return `Breaker ${this.breaker.label.toLowerCase()}`;
    }

    get breakerLabelClass() {
        return `${this.breaker.pillClass} breaker-label`;
    }

    get budgetPillLabel() {
        return `Budget ${this.budget.label.toLowerCase()}`;
    }

    get failureCount() {
        return formatNumber(this.summary.failureCount);
    }

    get hasBudget() {
        return !!this.summary.budgetStatus;
    }

    get budget() {
        const view = budgetStatusView(this.summary.budgetStatus);
        return { ...view, peak: clampPercent(this.summary.peakUsagePercent) };
    }

    get usageBars() {
        return LIMITS.map((limit) => {
            const percent = clampPercent(this.summary[limit.field]);
            return {
                key: limit.key,
                label: limit.label,
                percent,
                barStyle: `width: ${percent}%`,
                barClass: `ag-bar ag-bar_${usageLevel(percent)} usage-fill`,
                ariaLabel: `${limit.label}: ${percent} percent of today's allocation used`
            };
        });
    }

    get hasSession() {
        return !!this.summary.liveSessionId;
    }

    get session() {
        return {
            id: this.summary.liveSessionId,
            url: recordUrl(this.summary.liveSessionId, SESSION_OBJECT),
            actions: formatNumber(this.summary.sessionActions)
        };
    }

    get keyPrefix() {
        return this.summary.apiKeyPrefix ? `${this.summary.apiKeyPrefix}…` : 'No key issued';
    }

    get keyLastRotated() {
        return this.summary.apiKeyLastRotated ? formatDateTime(this.summary.apiKeyLastRotated) : 'Never';
    }

    get boundToUser() {
        return this.summary.boundToUser ? 'Yes' : 'No';
    }

    get actions() {
        return actionsFor(this.summary).map((action) => ({
            ...action,
            variant: action.name === 'reset' ? 'brand' : 'neutral',
            disabled: this.actionInProgress
        }));
    }

    get hasActions() {
        return this.actions.length > 0;
    }

    // --- Private helpers ---

    setError(key, error) {
        this.errors = { ...this.errors, [key]: describeError(error) };
    }

    clearError(key) {
        if (this.errors[key]) {
            const remaining = { ...this.errors };
            delete remaining[key];
            this.errors = remaining;
        }
    }
}
