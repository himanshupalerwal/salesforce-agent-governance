/**
 * @description Tests for AgentGovRegistryService: registration, credentials, activation, and sessions.
 */
@IsTest
private class AgentGovRegistryServiceTest {
    /** @description A caller-supplied key long enough that its stored prefix does not reveal it. */
    private static final String SUPPLIED_KEY = 'agk_registry_service_test_key_001';

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void registerStoresHashedKeyAndStartsInactive() {
        Test.startTest();
        AgentGov_Registration__c reg = AgentGovRegistryService.registerAgent(
            'New Agent',
            'Agentforce',
            'Test description',
            SUPPLIED_KEY,
            'owner@example.com'
        );
        Test.stopTest();

        AgentGov_Registration__c stored = [
            SELECT Agent_Name__c, Status__c, API_Key__c, API_Key_Hash__c, API_Key_Prefix__c
            FROM AgentGov_Registration__c
            WHERE Id = :reg.Id
        ];
        Assert.areEqual('New Agent', stored.Agent_Name__c);
        Assert.areEqual(AgentGovConstants.STATUS_INACTIVE, stored.Status__c);
        Assert.isNull(stored.API_Key__c, 'Plaintext keys are never stored');
        Assert.areEqual(AgentGovRestAuth.hashKey(SUPPLIED_KEY), stored.API_Key_Hash__c);
        // The prefix is readable by dashboard users, so it must never be the whole key.
        Assert.areEqual(
            SUPPLIED_KEY.substring(0, AgentGovConstants.API_KEY_IDENTIFIER_LENGTH),
            stored.API_Key_Prefix__c,
            'Only the identifying prefix is stored'
        );
        Assert.isTrue(
            stored.API_Key_Prefix__c.length() < SUPPLIED_KEY.length(),
            'The stored prefix is shorter than the key it identifies'
        );
    }

    @IsTest
    static void registerRejectsAKeyShortEnoughToBeRevealedByItsPrefix() {
        Test.startTest();
        try {
            AgentGovRegistryService.registerAgent('Short Key Agent', 'Agentforce', null, 'key-001', null);
            Assert.fail('A key shorter than the minimum must be refused');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
        }
        Test.stopTest();

        Assert.areEqual(
            0,
            [SELECT COUNT() FROM AgentGov_Registration__c WHERE Agent_Name__c = 'Short Key Agent'],
            'No registration is created when the key is refused'
        );
    }

    @IsTest
    static void registerRejectsInvalidInput() {
        try {
            AgentGovRegistryService.registerAgent('', 'Agentforce', null, null, null);
            Assert.fail('Blank name must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
        }
        try {
            AgentGovRegistryService.registerAgent('Agent', 'InvalidType', null, null, null);
            Assert.fail('Unknown type must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
        }
    }

    @IsTest
    static void issueApiKeyReplacesPreviousKey() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistrationWithApiKey(
            'Keyed',
            'Agentforce',
            'first'
        );

        String issued = AgentGovRegistryService.issueApiKey(reg.Id);

        AgentGov_Registration__c stored = [
            SELECT API_Key_Hash__c, API_Key_Last_Rotated__c
            FROM AgentGov_Registration__c
            WHERE Id = :reg.Id
        ];
        Assert.areEqual(AgentGovRestAuth.hashKey(issued), stored.API_Key_Hash__c);
        Assert.areNotEqual(AgentGovRestAuth.hashKey('first'), stored.API_Key_Hash__c);
        Assert.isNotNull(stored.API_Key_Last_Rotated__c);
    }

    @IsTest
    static void bindAgentUser() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Bound', 'Agentforce', true);

        AgentGovRegistryService.bindAgentUser(reg.Id, UserInfo.getUserId());

        Assert.areEqual(
            UserInfo.getUserId(),
            [SELECT Agent_User__c FROM AgentGov_Registration__c WHERE Id = :reg.Id].Agent_User__c
        );
    }

    @IsTest
    static void activateAndDeactivate() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Test', 'Agentforce', false);
        reg.Status__c = AgentGovConstants.STATUS_INACTIVE;
        insert reg;

        AgentGov_Registration__c activated = AgentGovRegistryService.activateAgent(reg.Id);
        Assert.areEqual(AgentGovConstants.STATUS_ACTIVE, activated.Status__c);
        Assert.isNotNull(activated.Last_Active__c);

        AgentGovTestDataFactory.createSession(reg.Id, true);
        AgentGov_Registration__c deactivated = AgentGovRegistryService.deactivateAgent(reg.Id);
        Assert.areEqual(AgentGovConstants.STATUS_INACTIVE, deactivated.Status__c);
        Assert.areEqual(
            AgentGovConstants.SESSION_TERMINATED,
            [SELECT Status__c FROM AgentGov_Session__c WHERE Agent_Registration__c = :reg.Id].Status__c,
            'Deactivation ends the active session'
        );
    }

    @IsTest
    static void unknownAgentIsRejected() {
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';
        try {
            AgentGovRegistryService.activateAgent(unknownId);
            Assert.fail('Unknown agent must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.AGENT_NOT_FOUND, e.getErrorCode());
        }
        Assert.isNull(AgentGovRegistryService.getAgent(unknownId));
    }

    @IsTest
    static void sessionsStartAndEnd() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Test', 'Agentforce', true);

        AgentGov_Session__c session = AgentGovRegistryService.startSession(reg.Id);
        Assert.areEqual(AgentGovConstants.SESSION_ACTIVE, session.Status__c);

        AgentGov_Session__c ended = AgentGovRegistryService.endSession(session.Id);
        Assert.areEqual(AgentGovConstants.SESSION_COMPLETED, ended.Status__c);
        Assert.isNotNull(ended.Session_End__c);

        try {
            AgentGovRegistryService.endSession(null);
            Assert.fail('Unknown session must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovConstants.ERR_SESSION_NOT_ACTIVE, e.getMessage());
        }
    }

    @IsTest
    static void inactiveAgentCannotStartSession() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Test', 'Agentforce', false);
        reg.Status__c = AgentGovConstants.STATUS_INACTIVE;
        insert reg;

        try {
            AgentGovRegistryService.startSession(reg.Id);
            Assert.fail('Inactive agents cannot start sessions');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.AGENT_NOT_ACTIVE, e.getErrorCode());
        }
    }

    @IsTest
    static void concurrentAgentLimitIsEnforced() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Max_Concurrent_Agents__c = 1;
        update settings;
        AgentGovSelector.clearCache();
        AgentGovTestDataFactory.createRegistration('Agent 1', 'Agentforce', true);
        AgentGov_Registration__c second = AgentGovTestDataFactory.createRegistration('Agent 2', 'Custom_Apex', false);
        second.Status__c = AgentGovConstants.STATUS_INACTIVE;
        insert second;

        try {
            AgentGovRegistryService.activateAgent(second.Id);
            Assert.fail('The concurrent limit must be enforced');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.MAX_CONCURRENT_AGENTS, e.getErrorCode());
        }
    }
}
