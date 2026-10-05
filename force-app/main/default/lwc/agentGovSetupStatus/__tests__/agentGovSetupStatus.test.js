import { createElement } from 'lwc';
import AgentGovSetupStatus from 'c/agentGovSetupStatus';
import getSetupStatus from '@salesforce/apex/AgentGovAdminController.getSetupStatus';
import scheduleJobs from '@salesforce/apex/AgentGovAdminController.scheduleJobs';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEventName } from 'lightning/platformShowToastEvent';

jest.mock(
    '@salesforce/apex/AgentGovAdminController.getSetupStatus',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock('@salesforce/apex/AgentGovAdminController.scheduleJobs', () => ({ default: jest.fn() }), {
    virtual: true
});

const JOBS = [
    {
        name: 'AgentGov Daily Reset',
        scheduled: true,
        cronExpression: '0 0 0 * * ?',
        nextFireTime: '2026-09-29T07:00:00.000Z'
    },
    { name: 'AgentGov Health Check', scheduled: false },
    { name: 'AgentGov Cleanup', scheduled: false }
];
const NEEDS_WORK = {
    governanceEnabled: false,
    realTimeEventsEnabled: false,
    adminEmailConfigured: false,
    notifyAgentOwners: false,
    sessionIdleMinutes: 30,
    jobs: JOBS,
    policyProblems: ['Policy MCP_Default names an unknown object: Acount.']
};
const READY = {
    governanceEnabled: true,
    realTimeEventsEnabled: true,
    adminEmailConfigured: true,
    notifyAgentOwners: true,
    sessionIdleMinutes: 15,
    jobs: JOBS.map((job) => ({ ...job, scheduled: true, nextFireTime: '2026-09-29T07:00:00.000Z' })),
    policyProblems: []
};
const SCHEDULED_MESSAGE =
    'The three background jobs are scheduled to run as you, in your time zone, replacing those already scheduled.';

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-agent-gov-setup-status', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        refreshApex.mockImplementation(() => Promise.resolve());
    });

    function mount() {
        const element = createElement('c-agent-gov-setup-status', { is: AgentGovSetupStatus });
        document.body.appendChild(element);
        return element;
    }

    function checklist(element) {
        return Array.from(element.shadowRoot.querySelectorAll('li.check')).map((item) => [
            item.querySelector('.slds-assistive-text').textContent,
            item.querySelector('.check-label').textContent
        ]);
    }

    it('lists what still needs doing, with a state in words as well as an icon', async () => {
        const element = mount();
        expect(element.shadowRoot.querySelector('.ag-skeleton')).not.toBeNull();
        getSetupStatus.emit(NEEDS_WORK);
        await flushPromises();

        expect(checklist(element)).toEqual([
            ['Needs action:', 'Governance is off. Agents are not governed until it is turned on in AgentGov Settings.'],
            [
                'Needs action:',
                'Real-time events are off in AgentGov Settings, so no alerts are raised or emailed and the console does not update by itself.'
            ],
            ['Needs action:', 'No administrator email is set.'],
            ['Information:', 'Agent owners are not emailed about alerts.'],
            ['Information:', 'A session ends after 30 minutes without activity, or after 24 hours.'],
            ['Needs action:', '1 of 3 background jobs are scheduled.'],
            ['Needs action:', '1 policy problem needs fixing.']
        ]);
        const jobs = Array.from(element.shadowRoot.querySelectorAll('tr.job-row'));
        expect(jobs.map((row) => row.querySelector('.job-state').textContent)).toEqual([
            'Scheduled',
            'Not scheduled',
            'Not scheduled'
        ]);
        expect(jobs.map((row) => row.querySelector('td.slds-cell-wrap').textContent)).toEqual([
            "Creates today's budget row for every active agent ahead of first use. Budgets start afresh each day in the org's time zone whether or not this runs.",
            'Every hour: moves cooled-down breakers to half-open and closes sessions that are idle or have run for 24 hours.',
            'Sundays at 02:00: purges audit rows, sessions, conflicts, and budgets past retention.'
        ]);
        expect(element.shadowRoot.querySelector('.schedule-help').textContent.trim()).toBe(
            'Schedule jobs replaces the jobs in this table with new ones that run as you, in your time zone.'
        );
        expect(jobs[0].querySelector('.job-next').textContent).not.toBe('—');
        expect(jobs[1].querySelector('.job-next').textContent).toBe('—');
        expect(element.shadowRoot.querySelector('.policy-problem').textContent).toBe(
            'Policy MCP_Default names an unknown object: Acount.'
        );
    });

    it('shows a ready org as done', async () => {
        const element = mount();
        getSetupStatus.emit({ ...READY, policyProblems: ['One', 'Two'] });
        await flushPromises();
        expect(checklist(element).map((item) => item[0])).toEqual([
            'Done:',
            'Done:',
            'Done:',
            'Information:',
            'Information:',
            'Done:',
            'Needs action:'
        ]);
        expect(
            checklist(element)
                .slice(1, 5)
                .map((item) => item[1])
        ).toEqual([
            'Real-time events are on, so alerts are raised and recorded.',
            'Alerts are emailed to an administrator.',
            "Agent owners are emailed about their own agents' alerts.",
            'A session ends after 15 minutes without activity, or after 24 hours.'
        ]);
        expect(checklist(element)[6][1]).toBe('2 policy problems need fixing.');

        getSetupStatus.emit(READY);
        await flushPromises();
        expect(checklist(element)[6]).toEqual(['Done:', 'No policy problems found.']);
        expect(element.shadowRoot.querySelector('.no-problems').textContent).toBe(
            'No problems found in the policy records.'
        );
    });

    it('says whom alerts reach, and that none are sent while real-time events are off', async () => {
        const element = mount();
        const alerting = () =>
            checklist(element)
                .filter((item, index) => index === 2 || index === 3)
                .map((item) => item.join(' '));

        getSetupStatus.emit({ ...READY, adminEmailConfigured: false });
        await flushPromises();
        expect(alerting()).toEqual([
            'Needs action: No administrator email is set. Alerts are recorded in the action log and emailed only to the owners of the agents concerned.',
            "Information: Agent owners are emailed about their own agents' alerts."
        ]);

        getSetupStatus.emit({ ...READY, adminEmailConfigured: false, notifyAgentOwners: false });
        await flushPromises();
        expect(alerting()).toEqual([
            'Needs action: No administrator email is set, so alerts are recorded in the action log but not emailed.',
            'Information: Agent owners are not emailed about alerts.'
        ]);

        getSetupStatus.emit({ ...READY, realTimeEventsEnabled: false, sessionIdleMinutes: 1 });
        await flushPromises();
        expect(checklist(element)[1][0]).toBe('Needs action:');
        expect(alerting()).toEqual([
            'Information: An administrator email is set. Alerts are emailed to it once real-time events are on.',
            "Information: Agent owners are emailed about their own agents' alerts once real-time events are on."
        ]);
        expect(checklist(element)[4][1]).toBe('A session ends after 1 minute without activity, or after 24 hours.');
    });

    it('schedules the jobs, reports the outcome, and refreshes the checklist', async () => {
        const element = mount();
        getSetupStatus.emit(NEEDS_WORK);
        await flushPromises();
        const toasts = jest.fn();
        element.addEventListener(ShowToastEventName, toasts);
        scheduleJobs.mockResolvedValue({ success: true, message: SCHEDULED_MESSAGE });
        const button = element.shadowRoot.querySelector('.schedule-button');
        const buttonFocus = jest.spyOn(button, 'focus');

        button.click();
        await flushPromises();

        expect(scheduleJobs).toHaveBeenCalledTimes(1);
        expect(toasts.mock.calls[0][0].detail).toEqual({
            title: 'Jobs scheduled',
            message: SCHEDULED_MESSAGE,
            variant: 'success'
        });
        expect(refreshApex).toHaveBeenCalledTimes(1);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe(SCHEDULED_MESSAGE);
        expect(buttonFocus).toHaveBeenCalled();
    });

    it('reports a scheduling failure and a refused request', async () => {
        const element = mount();
        getSetupStatus.emit(NEEDS_WORK);
        await flushPromises();
        const toasts = jest.fn();
        element.addEventListener(ShowToastEventName, toasts);

        scheduleJobs.mockResolvedValueOnce({ success: false });
        element.shadowRoot.querySelector('.schedule-button').click();
        await flushPromises();
        expect(toasts.mock.calls[0][0].detail).toMatchObject({
            title: 'Jobs not scheduled',
            message: 'The background jobs could not be scheduled.',
            variant: 'error'
        });
        expect(refreshApex).not.toHaveBeenCalled();

        scheduleJobs.mockRejectedValueOnce({
            body: { message: 'You need the AgentGov Operate Agents permission to do this.' }
        });
        element.shadowRoot.querySelector('.schedule-button').click();
        await flushPromises();
        expect(toasts.mock.calls[1][0].detail.message).toBe(
            'You need the AgentGov Operate Agents permission to do this.'
        );
    });

    it('refreshes on request and shows load and refresh errors', async () => {
        const element = mount();
        getSetupStatus.error({ message: 'You need the AgentGov Operate Agents permission to do this.' });
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe(
            'You need the AgentGov Operate Agents permission to do this.'
        );

        getSetupStatus.emit(READY);
        await flushPromises();
        element.shadowRoot.querySelector('.refresh-button').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('.announcement').textContent).toMatch(/^Refreshed\./);
        expect(element.shadowRoot.querySelector('.last-updated').textContent).toMatch(/^Updated /);

        refreshApex.mockRejectedValueOnce({ body: { message: 'Refresh failed' } });
        element.shadowRoot.querySelector('.refresh-button').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('[role="alert"] .error-message').textContent).toBe('Refresh failed');
    });
});
