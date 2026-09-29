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
    adminEmailConfigured: false,
    notifyAgentOwners: false,
    sessionIdleMinutes: 30,
    jobs: JOBS,
    policyProblems: ['Policy MCP_Default names an unknown object: Acount.']
};
const READY = {
    governanceEnabled: true,
    adminEmailConfigured: true,
    notifyAgentOwners: true,
    sessionIdleMinutes: 15,
    jobs: JOBS.map((job) => ({ ...job, scheduled: true, nextFireTime: '2026-09-29T07:00:00.000Z' })),
    policyProblems: []
};

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
                'No administrator email is set, so alerts are recorded in the action log but not emailed.'
            ],
            ['Information:', 'Agent owners are not emailed about alerts.'],
            ['Information:', 'A session ends after 30 minutes without activity.'],
            ['Needs action:', '1 of 3 background jobs are scheduled.'],
            ['Needs action:', '1 policy problem needs fixing.']
        ]);
        const jobs = Array.from(element.shadowRoot.querySelectorAll('tr.job-row'));
        expect(jobs.map((row) => row.querySelector('.job-state').textContent)).toEqual([
            'Scheduled',
            'Not scheduled',
            'Not scheduled'
        ]);
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
            'Information:',
            'Information:',
            'Done:',
            'Needs action:'
        ]);
        expect(checklist(element)[5][1]).toBe('2 policy problems need fixing.');

        getSetupStatus.emit(READY);
        await flushPromises();
        expect(checklist(element)[5]).toEqual(['Done:', 'No policy problems found.']);
        expect(element.shadowRoot.querySelector('.no-problems')).not.toBeNull();
    });

    it('schedules the jobs, reports the outcome, and refreshes the checklist', async () => {
        const element = mount();
        getSetupStatus.emit(NEEDS_WORK);
        await flushPromises();
        const toasts = jest.fn();
        element.addEventListener(ShowToastEventName, toasts);
        scheduleJobs.mockResolvedValue({ success: true, message: 'The three background jobs are scheduled.' });
        const button = element.shadowRoot.querySelector('.schedule-button');
        const buttonFocus = jest.spyOn(button, 'focus');

        button.click();
        await flushPromises();

        expect(scheduleJobs).toHaveBeenCalledTimes(1);
        expect(toasts.mock.calls[0][0].detail).toEqual({
            title: 'Jobs scheduled',
            message: 'The three background jobs are scheduled.',
            variant: 'success'
        });
        expect(refreshApex).toHaveBeenCalledTimes(1);
        expect(element.shadowRoot.querySelector('.announcement').textContent).toBe(
            'The three background jobs are scheduled.'
        );
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
