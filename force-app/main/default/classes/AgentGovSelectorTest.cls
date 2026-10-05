/**
 * @description Tests for AgentGovSelector: settings defaults, caching, and the bulk lookups.
 */
@IsTest
private class AgentGovSelectorTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Test Agent', 'Agentforce', true);
        AgentGovTestDataFactory.createSession(reg.Id, true);
        AgentGovTestDataFactory.createBudget(reg.Id, true);
    }

    private static AgentGov_Registration__c primaryAgent() {
        return [SELECT Id FROM AgentGov_Registration__c WHERE Agent_Name__c = 'Test Agent'];
    }

    @IsTest
    static void settingsAreReadAndDefaultedWhenAbsent() {
        Assert.isTrue(AgentGovSelector.getSettings().Is_Enabled__c);
        Assert.isTrue(AgentGovSelector.isFrameworkEnabled());
        Assert.isTrue(AgentGovSelector.isRealTimeEventsEnabled());

        delete [SELECT Id FROM AgentGov_Settings__c];
        AgentGovSelector.clearCache();

        AgentGov_Settings__c defaults = AgentGovSelector.getSettings();
        Assert.isNull(defaults.Id, 'Defaults are not persisted');
        Assert.areEqual(AgentGovConstants.DEFAULT_MAX_CONCURRENT_AGENTS, defaults.Max_Concurrent_Agents__c);
    }

    @IsTest
    static void metadataIsReadInSystemMode() {
        // The user holds no access to the custom metadata types. A user-mode read would hand
        // the policy engine nothing to enforce, so the shipped records must still come back.
        User restricted = AgentGovTestDataFactory.createRestrictedUser(new List<String>());

        System.runAs(restricted) {
            AgentGovSelector.clearCache();
            Assert.isFalse(AgentGovSelector.getLimitConfigs().isEmpty(), 'Shipped limit configurations are visible');
            Assert.isNotNull(
                AgentGovSelector.getLimitConfigByType(AgentGovConstants.LIMIT_API_CALLS),
                'The limit type field is readable'
            );
            Assert.isNull(AgentGovSelector.getLimitConfigByType('Bogus'), 'An unknown limit type has no configuration');
            Assert.isFalse(AgentGovSelector.getPolicies().isEmpty(), 'Shipped policies are visible');
            Assert.isFalse(
                AgentGovSelector.getPoliciesForAgentType(AgentGovConstants.AGENT_TYPE_MCP_EXTERNAL).isEmpty(),
                'The agent type field is readable, so the shipped MCP External policies apply'
            );
        }
    }

    @IsTest
    static void registrationsAreCachedAndLoadedInBulk() {
        Id agentId = primaryAgent().Id;
        AgentGov_Registration__c other = AgentGovTestDataFactory.createRegistration('Other', 'Custom_Apex', true);

        Test.startTest();
        AgentGovSelector.getRegistrationById(agentId);
        Integer afterFirst = Limits.getQueries();
        AgentGovSelector.getRegistrationById(agentId);
        Integer afterSecond = Limits.getQueries();
        Map<Id, AgentGov_Registration__c> both = AgentGovSelector.getRegistrationsByIds(
            new Set<Id>{ agentId, other.Id, null }
        );
        Test.stopTest();

        Assert.areEqual(afterFirst, afterSecond, 'The second read is served from cache');
        Assert.areEqual(2, both.size());
        Assert.isNull(AgentGovSelector.getRegistrationById(null));
    }

    @IsTest
    static void registrationsCanBeLockedForUpdate() {
        Map<Id, AgentGov_Registration__c> locked = AgentGovSelector.getRegistrationsForUpdate(
            new Set<Id>{ primaryAgent().Id }
        );
        Assert.areEqual(1, locked.size());
        Assert.isTrue(AgentGovSelector.getRegistrationsForUpdate(new Set<Id>()).isEmpty());
    }

    @IsTest
    static void lookupsByHashLegacyKeyAndUser() {
        AgentGov_Registration__c hashed = AgentGovTestDataFactory.createRegistrationWithApiKey(
            'Hashed',
            'Agentforce',
            'k1'
        );
        AgentGov_Registration__c legacy = AgentGovTestDataFactory.createRegistrationWithLegacyKey(
            'Legacy',
            'Agentforce',
            'k2'
        );
        AgentGov_Registration__c bound = AgentGovTestDataFactory.createRegistration('Bound', 'Agentforce', false);
        bound.Agent_User__c = UserInfo.getUserId();
        insert bound;

        Assert.areEqual(hashed.Id, AgentGovSelector.getRegistrationByApiKeyHash(AgentGovRestAuth.hashKey('k1')).Id);
        Assert.isNull(AgentGovSelector.getRegistrationByApiKeyHash(''));
        Assert.areEqual(legacy.Id, AgentGovSelector.getRegistrationByLegacyApiKey('k2').Id);
        Assert.isNull(AgentGovSelector.getRegistrationByLegacyApiKey(null));
        Assert.areEqual(bound.Id, AgentGovSelector.getRegistrationByAgentUser(UserInfo.getUserId()).Id);
        Assert.isNull(AgentGovSelector.getRegistrationByAgentUser(null));
    }

    @IsTest
    static void cacheRegistrationReplacesCachedCopy() {
        AgentGov_Registration__c reg = primaryAgent();
        AgentGovSelector.getRegistrationById(reg.Id);
        reg.Agent_Name__c = 'Renamed In Memory';

        AgentGovSelector.cacheRegistration(reg);

        Assert.areEqual('Renamed In Memory', AgentGovSelector.getRegistrationById(reg.Id).Agent_Name__c);
    }

    @IsTest
    static void activeRegistrationsAndCounts() {
        Assert.areEqual(1, AgentGovSelector.getActiveRegistrations().size());
        Assert.areEqual(1, AgentGovSelector.getActiveAgentCount());
    }

    @IsTest
    static void budgetsAreReadWithAndWithoutLock() {
        Id agentId = primaryAgent().Id;
        Assert.isNotNull(AgentGovSelector.getTodaysBudget(agentId));
        Assert.isNotNull(AgentGovSelector.getTodaysBudgetForUpdate(agentId));
        Assert.isTrue(AgentGovSelector.getTodaysBudgets(new Set<Id>()).isEmpty());
        Assert.isTrue(AgentGovSelector.getTodaysBudgetsForUpdate(null).isEmpty());
    }

    @IsTest
    static void sessionsAreReadByAgentAndById() {
        Id agentId = primaryAgent().Id;
        AgentGov_Session__c active = AgentGovSelector.getActiveSession(agentId);
        Assert.isNotNull(active);
        Assert.areEqual(active.Id, AgentGovSelector.getSessionById(active.Id).Id);
        Assert.isNull(AgentGovSelector.getSessionById(null));
        Assert.isTrue(AgentGovSelector.getActiveSessionsByAgent(new Set<Id>()).isEmpty());

        // Orphan detection is time-based, so the session is aged explicitly rather than
        // relying on the difference between the setup and test transactions. It belongs to a
        // second agent because an agent can have only one active session.
        AgentGov_Registration__c second = AgentGovTestDataFactory.createRegistration('Second', 'Agentforce', true);
        AgentGov_Session__c stale = AgentGovTestDataFactory.createSession(second.Id, false);
        stale.Session_Start__c = DateTime.now().addHours(-48);
        insert stale;
        List<AgentGov_Session__c> orphans = AgentGovSelector.getOrphanedSessions(24);
        Assert.areEqual(1, orphans.size(), 'Only the session older than the cutoff is orphaned');
        Assert.areEqual(stale.Id, orphans[0].Id);
    }

    @IsTest
    static void openAgentsPastCooldownAndRecentLogs() {
        AgentGov_Registration__c reg = primaryAgent();
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        reg.Cooldown_Until__c = DateTime.now().addMinutes(-5);
        update reg;
        AgentGov_Session__c session = AgentGovSelector.getActiveSession(reg.Id);
        AgentGovTestDataFactory.createActionLog(
            reg.Id,
            session.Id,
            AgentGovConstants.ACTION_QUERY,
            AgentGovConstants.ACTION_SUCCESS,
            true
        );

        Assert.areEqual(1, AgentGovSelector.getOpenAgentsPastCooldown().size());
        Assert.areEqual(1, AgentGovSelector.getRecentActionLogs(reg.Id, 10).size());
    }
}
