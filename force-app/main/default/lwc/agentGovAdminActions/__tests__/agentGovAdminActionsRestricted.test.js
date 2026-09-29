import resetBreakers from '@salesforce/apex/AgentGovAdminController.resetBreakers';
import { actionsFor, canManageKeys, canOperate, isPermitted, runAgentAction } from 'c/agentGovAdminActions';

jest.mock('@salesforce/customPermission/AgentGov_Operate_Agents', () => ({ default: undefined }));
jest.mock('@salesforce/apex/AgentGovAdminController.resetBreakers', () => ({ default: jest.fn() }), {
    virtual: true
});

describe('c-agent-gov-admin-actions without AgentGov_Operate_Agents', () => {
    it('offers only key rotation, which has its own permission', () => {
        expect(canOperate).toBe(false);
        expect(canManageKeys).toBe(true);
        expect(isPermitted('reset')).toBe(false);
        expect(isPermitted('rotateKey')).toBe(true);
        const tripped = { id: 'a1', name: 'Order Sync Agent', status: 'Blocked', breakerState: 'OPEN' };
        expect(actionsFor(tripped).map((action) => action.name)).toEqual(['rotateKey']);
    });

    it('refuses to run an action the person may not use', async () => {
        const element = document.createElement('div');
        const result = await runAgentAction(element, 'reset', [{ id: 'a1', name: 'A', breakerState: 'OPEN' }]);
        expect(result).toEqual({ changed: false, message: '' });
        expect(resetBreakers).not.toHaveBeenCalled();
    });
});
