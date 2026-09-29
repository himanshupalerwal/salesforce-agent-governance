/**
 * Setup checklist for the AgentGov console: whether governance is on, whether alerts reach an
 * administrator, the three background jobs and when each runs next, and any policy problems,
 * with a button that schedules the jobs.
 *
 * AgentGovAdminController.getSetupStatus and scheduleJobs both require the
 * AgentGov_Operate_Agents custom permission on the server; the console shows this tab only to
 * people who hold it.
 */
import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSetupStatus from '@salesforce/apex/AgentGovAdminController.getSetupStatus';
import scheduleJobs from '@salesforce/apex/AgentGovAdminController.scheduleJobs';
import {
    combineErrors,
    describeError,
    formatDateTime,
    formatTime,
    pillClass,
    refreshedMessage,
    restoreFocus
} from 'c/agentGovUtils';
import { canOperate } from 'c/agentGovAdminActions';

const JOB_PURPOSES = {
    'AgentGov Daily Reset': "Starts each agent's budget afresh at midnight.",
    'AgentGov Health Check': 'Every hour: moves cooled-down breakers to half-open and closes idle sessions.',
    'AgentGov Cleanup': 'Sundays at 02:00: purges audit rows, sessions, conflicts, and budgets past retention.'
};

function checkView(key, state, label) {
    const views = {
        done: { icon: 'utility:success', variant: 'success', stateText: 'Done' },
        action: { icon: 'utility:warning', variant: 'warning', stateText: 'Needs action' },
        info: { icon: 'utility:info', variant: undefined, stateText: 'Information' }
    };
    return { key, label, ...views[state] };
}

export default class AgentGovSetupStatus extends LightningElement {
    status;
    wiredStatus;
    errors = {};
    lastUpdated;
    announcement = '';
    refreshing = false;
    scheduling = false;

    @wire(getSetupStatus)
    handleStatus(result) {
        this.wiredStatus = result;
        if (result.error) {
            this.setError('load', result.error);
            this.status = undefined;
        } else if (result.data !== undefined) {
            this.clearError('load');
            this.status = result.data || undefined;
            this.lastUpdated = new Date();
        }
    }

    /**
     * Reloads the setup status.
     * @returns {Promise}
     */
    @api
    async refresh() {
        if (!this.wiredStatus) {
            return;
        }
        try {
            await refreshApex(this.wiredStatus);
            this.clearError('refresh');
            this.lastUpdated = new Date();
        } catch (error) {
            this.setError('refresh', error);
        }
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

    async handleSchedule(event) {
        const trigger = event.currentTarget;
        this.scheduling = true;
        let message;
        try {
            const outcome = await scheduleJobs();
            const succeeded = !!(outcome && outcome.success);
            message = (outcome && outcome.message) || 'The background jobs could not be scheduled.';
            this.dispatchEvent(
                new ShowToastEvent({
                    title: succeeded ? 'Jobs scheduled' : 'Jobs not scheduled',
                    message,
                    variant: succeeded ? 'success' : 'error'
                })
            );
            if (succeeded) {
                await this.refresh();
            }
        } catch (error) {
            message = describeError(error);
            this.dispatchEvent(new ShowToastEvent({ title: 'Jobs not scheduled', message, variant: 'error' }));
        } finally {
            this.scheduling = false;
        }
        this.announcement = message;
        await Promise.resolve();
        restoreFocus(trigger, this.refs.heading);
    }

    // --- View state ---

    get isLoading() {
        return !this.wiredStatus || (this.wiredStatus.data === undefined && this.wiredStatus.error === undefined);
    }

    get hasStatus() {
        return !!this.status;
    }

    get errorMessage() {
        return combineErrors(this.errors);
    }

    get canSchedule() {
        return canOperate;
    }

    get scheduleDisabled() {
        return this.scheduling || !canOperate;
    }

    get scheduleLabel() {
        return this.scheduling ? 'Scheduling…' : 'Schedule jobs';
    }

    get refreshLabel() {
        return this.refreshing ? 'Refreshing…' : 'Refresh';
    }

    get lastUpdatedLabel() {
        return this.lastUpdated ? `Updated ${formatTime(this.lastUpdated, { seconds: true })}` : '';
    }

    get jobs() {
        return ((this.status && this.status.jobs) || []).map((job) => ({
            name: job.name,
            purpose: JOB_PURPOSES[job.name] || '',
            scheduledText: job.scheduled ? 'Scheduled' : 'Not scheduled',
            stateClass: `${pillClass(job.scheduled ? 'success' : 'warning')} job-state`,
            nextRun: job.scheduled && job.nextFireTime ? formatDateTime(job.nextFireTime) : '—',
            cron: job.cronExpression || '—'
        }));
    }

    get policyProblems() {
        return ((this.status && this.status.policyProblems) || []).map((problem, index) => ({
            key: `problem-${index}`,
            text: problem
        }));
    }

    get hasPolicyProblems() {
        return this.policyProblems.length > 0;
    }

    get checks() {
        const status = this.status;
        const jobs = status.jobs || [];
        const scheduled = jobs.filter((job) => job.scheduled).length;
        const problems = (status.policyProblems || []).length;
        return [
            status.governanceEnabled
                ? checkView('governance', 'done', 'Governance is on.')
                : checkView(
                      'governance',
                      'action',
                      'Governance is off. Agents are not governed until it is turned on in AgentGov Settings.'
                  ),
            status.adminEmailConfigured
                ? checkView('email', 'done', 'Alerts are emailed to an administrator.')
                : checkView(
                      'email',
                      'action',
                      'No administrator email is set, so alerts are recorded in the action log but not emailed.'
                  ),
            checkView(
                'owners',
                'info',
                status.notifyAgentOwners
                    ? "Agent owners are emailed about their own agents' alerts."
                    : 'Agent owners are not emailed about alerts.'
            ),
            checkView(
                'idle',
                'info',
                `A session ends after ${status.sessionIdleMinutes} ${status.sessionIdleMinutes === 1 ? 'minute' : 'minutes'} without activity.`
            ),
            scheduled === jobs.length && jobs.length > 0
                ? checkView('jobs', 'done', 'All background jobs are scheduled.')
                : checkView('jobs', 'action', `${scheduled} of ${jobs.length} background jobs are scheduled.`),
            problems === 0
                ? checkView('policies', 'done', 'No policy problems found.')
                : checkView(
                      'policies',
                      'action',
                      problems === 1 ? '1 policy problem needs fixing.' : `${problems} policy problems need fixing.`
                  )
        ];
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
