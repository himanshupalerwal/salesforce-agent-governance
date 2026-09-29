import LightningConfirm from 'lightning/confirm';
import { ShowToastEventName } from 'lightning/platformShowToastEvent';
import resetBreakers from '@salesforce/apex/AgentGovAdminController.resetBreakers';
import activateAgents from '@salesforce/apex/AgentGovAdminController.activateAgents';
import deactivateAgents from '@salesforce/apex/AgentGovAdminController.deactivateAgents';
import endSessions from '@salesforce/apex/AgentGovAdminController.endSessions';
import rotateApiKey from '@salesforce/apex/AgentGovAdminController.rotateApiKey';
import AgentGovKeyModal from 'c/agentGovKeyModal';
import AgentGovCreditModal from 'c/agentGovCreditModal';
import {
    actionLabel,
    actionsFor,
    canManageKeys,
    canOperate,
    eligibleAgents,
    isPermitted,
    runAgentAction,
    MAX_SELECTION
} from 'c/agentGovAdminActions';

jest.mock('@salesforce/apex/AgentGovAdminController.resetBreakers', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/AgentGovAdminController.activateAgents', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/AgentGovAdminController.deactivateAgents', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/AgentGovAdminController.endSessions', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/AgentGovAdminController.rotateApiKey', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('c/agentGovKeyModal', () => ({ __esModule: true, default: { open: jest.fn() } }));
jest.mock('c/agentGovCreditModal', () => ({ __esModule: true, default: { open: jest.fn() } }));

const TRIPPED = { id: 'a1', name: 'Order Sync Agent', status: 'Blocked', breakerState: 'OPEN' };
const HEALTHY = {
    id: 'a2',
    name: 'Lead Enrichment Agent',
    status: 'Active',
    breakerState: 'CLOSED',
    budgetStatus: 'Normal',
    liveSessionId: 's2'
};
const INACTIVE = { id: 'a3', name: 'Renewal Forecast Flow', status: 'Inactive', breakerState: 'HALF_OPEN' };

function host() {
    const element = document.createElement('div');
    element.toasts = [];
    element.addEventListener(ShowToastEventName, (event) => element.toasts.push(event.detail));
    return element;
}

describe('c-agent-gov-admin-actions', () => {
    afterEach(() => {
        jest.clearAllMocks();
        LightningConfirm.open.mockImplementation(() => Promise.resolve(true));
    });

    it('offers each action only for agents it applies to', () => {
        expect(canOperate).toBe(true);
        expect(canManageKeys).toBe(true);
        expect(isPermitted('reset')).toBe(true);
        expect(isPermitted('unknown')).toBe(false);
        expect(actionsFor(TRIPPED).map((action) => action.name)).toEqual([
            'reset',
            'activate',
            'deactivate',
            'rotateKey'
        ]);
        expect(actionsFor(HEALTHY).map((action) => action.name)).toEqual([
            'deactivate',
            'credit',
            'rotateKey',
            'endSession'
        ]);
        expect(actionsFor(HEALTHY, { exclude: ['rotateKey'] }).map((action) => action.label)).toEqual([
            'Deactivate',
            'Credit budget',
            'End session'
        ]);
        expect(eligibleAgents('activate', [TRIPPED, HEALTHY, INACTIVE])).toEqual([TRIPPED, INACTIVE]);
        expect(actionLabel('reset')).toBe('Reset breaker');
        expect(actionLabel('reset', { bulk: true })).toBe('Reset breakers');
    });

    it('confirms a reset, runs it, and reports the outcome', async () => {
        const element = host();
        resetBreakers.mockResolvedValue([{ recordId: 'a1', success: true, message: 'Circuit breaker closed.' }]);

        const result = await runAgentAction(element, 'reset', [TRIPPED]);

        expect(LightningConfirm.open).toHaveBeenCalledWith(
            expect.objectContaining({ label: 'Reset circuit breaker?', theme: 'warning' })
        );
        expect(LightningConfirm.open.mock.calls[0][0].message).toContain('Order Sync Agent');
        expect(resetBreakers).toHaveBeenCalledWith({ registrationIds: ['a1'] });
        expect(result).toEqual({ changed: true, message: 'Order Sync Agent: Circuit breaker closed.' });
        expect(element.toasts).toEqual([
            { title: 'Circuit breaker reset', message: 'Order Sync Agent: Circuit breaker closed.', variant: 'success' }
        ]);
    });

    it('does nothing when the person cancels the confirmation', async () => {
        const element = host();
        LightningConfirm.open.mockResolvedValueOnce(false);
        const result = await runAgentAction(element, 'deactivate', [HEALTHY]);
        expect(result).toEqual({ changed: false, cancelled: true, message: '' });
        expect(deactivateAgents).not.toHaveBeenCalled();
        expect(element.toasts).toEqual([]);
    });

    it('runs a bulk action on the eligible agents and lists the failures', async () => {
        const element = host();
        activateAgents.mockResolvedValue([
            { recordId: 'a1', success: true, message: 'Agent activated.' },
            { recordId: 'a3', success: false, message: 'Maximum concurrent agent limit reached.' }
        ]);
        const result = await runAgentAction(element, 'activate', [TRIPPED, HEALTHY, INACTIVE]);

        // Activation is not disruptive, so there is no confirmation.
        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(activateAgents).toHaveBeenCalledWith({ registrationIds: ['a1', 'a3'] });
        expect(result.changed).toBe(true);
        expect(element.toasts[0]).toEqual({
            title: 'Activate',
            message:
                'Activate: 1 of 2 agents done. Not done: Renewal Forecast Flow (Maximum concurrent agent limit reached.).',
            variant: 'warning'
        });
    });

    it('reports a bulk action where nothing succeeded as an error', async () => {
        const element = host();
        const failures = Array.from({ length: 5 }, (item, index) => ({
            recordId: `x${index}`,
            success: false,
            message: 'Not found, or you do not have access to it.'
        }));
        deactivateAgents.mockResolvedValue(failures);
        const agents = failures.map((failure) => ({ id: failure.recordId, name: `Agent ${failure.recordId}` }));

        const result = await runAgentAction(element, 'deactivate', agents);

        expect(result.changed).toBe(false);
        expect(element.toasts[0].variant).toBe('error');
        expect(element.toasts[0].message).toContain('0 of 5 agents done');
        expect(element.toasts[0].message).toContain('and 2 more');
    });

    it('reports a single failed outcome, and an unknown agent in a bulk result', async () => {
        const element = host();
        resetBreakers.mockResolvedValueOnce([
            { recordId: 'a1', success: false, message: 'Not found, or you do not have access to it.' }
        ]);
        await runAgentAction(element, 'reset', [TRIPPED]);
        expect(element.toasts[0]).toEqual({
            title: 'Circuit breaker not reset',
            message: 'Order Sync Agent: Not found, or you do not have access to it.',
            variant: 'error'
        });

        resetBreakers.mockResolvedValueOnce([
            { recordId: 'a1', success: true, message: 'Circuit breaker closed.' },
            { recordId: 'zz', success: false, message: 'Gone.' }
        ]);
        await runAgentAction(element, 'reset', [TRIPPED, INACTIVE]);
        expect(element.toasts[1].message).toContain('An agent (Gone.)');
    });

    it('turns a thrown server error into an error toast', async () => {
        const element = host();
        resetBreakers.mockRejectedValue({
            body: { message: 'You need the AgentGov Operate Agents permission to do this.' }
        });
        const result = await runAgentAction(element, 'reset', [TRIPPED]);
        expect(result).toEqual({
            changed: false,
            message: 'You need the AgentGov Operate Agents permission to do this.'
        });
        expect(element.toasts[0].variant).toBe('error');
        expect(element.toasts[0].title).toBe('Circuit breaker not reset');
    });

    it('tells the person when no selected agent is eligible, or too many are selected', async () => {
        const element = host();
        let result = await runAgentAction(element, 'reset', [HEALTHY]);
        expect(result.changed).toBe(false);
        expect(element.toasts[0].variant).toBe('info');

        const many = Array.from({ length: MAX_SELECTION + 1 }, (item, index) => ({
            id: `a${index}`,
            name: `Agent ${index}`,
            status: 'Inactive'
        }));
        result = await runAgentAction(element, 'activate', many);
        expect(result.message).toBe(`Select at most ${MAX_SELECTION} agents for one action.`);
        expect(activateAgents).not.toHaveBeenCalled();

        expect(await runAgentAction(element, 'unknown', [HEALTHY])).toEqual({ changed: false, message: '' });
    });

    it('ends a live session by its session id', async () => {
        const element = host();
        endSessions.mockResolvedValue([{ recordId: 's2', success: true, message: 'Session ended.' }]);
        const result = await runAgentAction(element, 'endSession', [HEALTHY]);
        expect(endSessions).toHaveBeenCalledWith({ sessionIds: ['s2'] });
        expect(result.message).toBe('Lead Enrichment Agent: Session ended.');
    });

    it('shows a new API key once in the dialog and never in a toast', async () => {
        const element = host();
        const secret = 'agk_0123456789abcdef0123456789abcdef';
        rotateApiKey.mockResolvedValue({ success: true, apiKey: secret, apiKeyPrefix: 'agk_01234567' });
        AgentGovKeyModal.open.mockResolvedValue('done');

        const result = await runAgentAction(element, 'rotateKey', [HEALTHY, TRIPPED]);

        expect(rotateApiKey).toHaveBeenCalledWith({ registrationId: 'a2' });
        expect(AgentGovKeyModal.open).toHaveBeenCalledWith(
            expect.objectContaining({ apiKey: secret, agentName: 'Lead Enrichment Agent', size: 'small' })
        );
        expect(result.changed).toBe(true);
        expect(JSON.stringify(element.toasts)).not.toContain(secret);
        expect(result.message).not.toContain(secret);
        expect(element.toasts[0].message).toContain('agk_01234567');
    });

    it('reports a key that could not be issued without opening the dialog', async () => {
        const element = host();
        rotateApiKey.mockResolvedValueOnce({ success: false, message: 'The API key could not be replaced.' });
        let result = await runAgentAction(element, 'rotateKey', [HEALTHY]);
        expect(AgentGovKeyModal.open).not.toHaveBeenCalled();
        expect(result.changed).toBe(false);
        expect(element.toasts[0]).toMatchObject({ title: 'API key not replaced', variant: 'error' });

        rotateApiKey.mockResolvedValueOnce(undefined);
        result = await runAgentAction(element, 'rotateKey', [HEALTHY]);
        expect(result.message).toBe('Lead Enrichment Agent: The API key could not be replaced.');
    });

    it('credits a budget through its dialog, and does nothing when the dialog is dismissed', async () => {
        const element = host();
        AgentGovCreditModal.open.mockResolvedValueOnce({
            success: true,
            message: "Credited 50 API calls to today's budget."
        });
        let result = await runAgentAction(element, 'credit', [HEALTHY]);
        expect(AgentGovCreditModal.open).toHaveBeenCalledWith(
            expect.objectContaining({ registrationId: 'a2', agentName: 'Lead Enrichment Agent' })
        );
        expect(result).toEqual({
            changed: true,
            message: "Lead Enrichment Agent: Credited 50 API calls to today's budget."
        });
        expect(LightningConfirm.open).not.toHaveBeenCalled();

        AgentGovCreditModal.open.mockResolvedValueOnce(undefined);
        result = await runAgentAction(element, 'credit', [HEALTHY]);
        expect(result).toEqual({ changed: false, cancelled: true, message: '' });
        expect(element.toasts.length).toBe(1);
    });
});
