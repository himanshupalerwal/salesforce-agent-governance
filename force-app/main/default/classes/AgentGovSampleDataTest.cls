/**
 * @description Tests for AgentGovSampleData, the demonstration data loader.
 *
 *              The class ships in the package and is run by administrators from anonymous
 *              Apex, so it carries the same coverage obligation as the rest of the framework.
 *              These tests assert the shape of what it creates rather than exact counts, so
 *              adding another sample agent does not break them.
 */
@IsTest
private class AgentGovSampleDataTest {
    @IsTest
    static void createAllPopulatesEveryObject() {
        Test.startTest();
        String summary = AgentGovSampleData.createAll();
        Test.stopTest();

        Assert.isNotNull(summary, 'createAll returns a summary of what it wrote');
        Assert.isTrue([SELECT COUNT() FROM AgentGov_Registration__c] > 0, 'Sample agents are created');
        Assert.isTrue([SELECT COUNT() FROM AgentGov_Budget__c] > 0, 'Sample budgets are created');
        Assert.isTrue([SELECT COUNT() FROM AgentGov_Session__c] > 0, 'Sample sessions are created');
        Assert.isTrue([SELECT COUNT() FROM AgentGov_Action_Log__c] > 0, 'Sample action logs are created');
        Assert.isTrue([SELECT COUNT() FROM AgentGov_Conflict_Log__c] > 0, 'Sample conflicts are created');
    }

    @IsTest
    static void sampleKeysAreStoredOnlyAsHashes() {
        Test.startTest();
        AgentGovSampleData.createAll();
        Test.stopTest();

        // The documented sample keys must behave exactly like real ones: hashed, never
        // retrievable, and long enough that the stored prefix does not reveal them.
        for (AgentGov_Registration__c registration : [
            SELECT API_Key__c, API_Key_Hash__c, API_Key_Prefix__c
            FROM AgentGov_Registration__c
            WHERE API_Key_Hash__c != NULL
        ]) {
            Assert.isNull(registration.API_Key__c, 'No sample agent stores a plaintext key');
            Assert.areEqual(64, registration.API_Key_Hash__c.length(), 'The stored hash is a SHA-256 digest in hex');
            Assert.isTrue(
                registration.API_Key_Prefix__c.length() <= AgentGovConstants.API_KEY_IDENTIFIER_LENGTH,
                'The stored prefix never exceeds the identifier length'
            );
        }

        for (String sampleKey : AgentGovSampleData.SAMPLE_API_KEYS) {
            Assert.isTrue(
                sampleKey.length() >= AgentGovConstants.API_KEY_MINIMUM_LENGTH,
                'Every documented sample key clears the minimum key length: ' + sampleKey
            );
        }
    }

    @IsTest
    static void aSampleKeyAuthenticatesTheAgentItBelongsTo() {
        Test.startTest();
        AgentGovSampleData.createAll();
        Test.stopTest();

        String firstKey = AgentGovSampleData.SAMPLE_API_KEYS[0];
        List<AgentGov_Registration__c> matched = [
            SELECT Id
            FROM AgentGov_Registration__c
            WHERE API_Key_Hash__c = :AgentGovRestAuth.hashKey(firstKey)
        ];
        Assert.areEqual(1, matched.size(), 'The documented sample key resolves to exactly one agent');
    }

    @IsTest
    static void deleteAllRemovesEverythingCreateAllWrote() {
        AgentGovSampleData.createAll();

        Test.startTest();
        AgentGovSampleData.deleteAll();
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM AgentGov_Action_Log__c], 'Action logs are removed');
        Assert.areEqual(0, [SELECT COUNT() FROM AgentGov_Conflict_Log__c], 'Conflict logs are removed');
        Assert.areEqual(0, [SELECT COUNT() FROM AgentGov_Session__c], 'Sessions are removed');
        Assert.areEqual(0, [SELECT COUNT() FROM AgentGov_Budget__c], 'Budgets are removed');
        Assert.areEqual(0, [SELECT COUNT() FROM AgentGov_Registration__c], 'Registrations are removed');
    }

    @IsTest
    static void deleteAllOnAnEmptyOrgIsSafe() {
        Test.startTest();
        AgentGovSampleData.deleteAll();
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM AgentGov_Registration__c], 'Running the cleanup twice is not an error');
    }

    @IsTest
    static void deleteSampleDataRemovesOnlyTheDemonstrationAgents() {
        AgentGovSampleData.createAll();
        AgentGov_Registration__c real = AgentGovTestDataFactory.createRegistration(
            'A Real Agent',
            AgentGovConstants.AGENT_TYPE_AGENTFORCE,
            true
        );
        AgentGovTestDataFactory.createBudget(real.Id, true);

        Test.startTest();
        Integer removed = AgentGovSampleData.deleteSampleData();
        Test.stopTest();

        // The install guide points people at this. Wiping an org's real agents because
        // somebody cleared a demo would be unforgivable.
        Assert.isTrue(removed > 0, 'The demonstration records are removed');
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM AgentGov_Registration__c],
            'Only the agent that was not part of the sample data survives'
        );
        Assert.areEqual('A Real Agent', [SELECT Agent_Name__c FROM AgentGov_Registration__c LIMIT 1].Agent_Name__c);
        Assert.areEqual(1, [SELECT COUNT() FROM AgentGov_Budget__c], 'The real agent keeps its budget row');
    }

    @IsTest
    static void deleteSampleDataOnAnOrgWithNoSamplesIsSafe() {
        AgentGovTestDataFactory.createRegistration('Only Real', AgentGovConstants.AGENT_TYPE_AGENTFORCE, true);

        Test.startTest();
        Integer removed = AgentGovSampleData.deleteSampleData();
        Test.stopTest();

        Assert.areEqual(0, removed, 'Nothing is removed when no sample agents exist');
        Assert.areEqual(1, [SELECT COUNT() FROM AgentGov_Registration__c], 'The real agent is untouched');
    }

    @IsTest
    static void createAllRunTwiceReportsRatherThanFailing() {
        AgentGovSampleData.createAll();

        Test.startTest();
        String second = AgentGovSampleData.createAll();
        Test.stopTest();

        // The sample keys are fixed and the hash is unique, so a second run used to fail with
        // a raw DUPLICATE_VALUE from the database.
        Assert.isTrue(
            second.containsIgnoreCase('already loaded'),
            'The second run explains itself instead of throwing: ' + second
        );
    }
}
