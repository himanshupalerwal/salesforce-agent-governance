import { createElement } from 'lwc';
import AgentConflictViewer from 'c/agentConflictViewer';
import getRecentConflictLogs from '@salesforce/apex/AgentGovSelector.getRecentConflictLogs';

jest.mock(
    '@salesforce/apex/AgentGovSelector.getRecentConflictLogs',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

describe('c-agent-conflict-viewer', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders datatable with conflicts', async () => {
        getRecentConflictLogs.mockResolvedValue([
            {
                Id: '1',
                Agent_1__r: { Agent_Name__c: 'Agent A' },
                Agent_2__r: { Agent_Name__c: 'Agent B' },
                Object_Name__c: 'Account',
                Conflict_Type__c: 'Concurrent_Write',
                Resolution__c: 'Agent1_Won',
                Severity__c: 'High',
                Timestamp__c: new Date().toISOString()
            }
        ]);

        const element = createElement('c-agent-conflict-viewer', { is: AgentConflictViewer });
        document.body.appendChild(element);

        await Promise.resolve();
        await Promise.resolve();

        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        expect(datatable).toBeTruthy();
    });

    it('shows empty state', async () => {
        getRecentConflictLogs.mockResolvedValue([]);

        const element = createElement('c-agent-conflict-viewer', { is: AgentConflictViewer });
        document.body.appendChild(element);

        await Promise.resolve();
        await Promise.resolve();

        const emptyMsg = element.shadowRoot.querySelector('.slds-text-align_center');
        expect(emptyMsg).toBeTruthy();
    });
});
