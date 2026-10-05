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
        Assert.isTrue(
            [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Action_Type__c = :AgentGovConstants.ACTION_ALERT] > 0,
            'Sample alerts are created, so the console shows recent alerts'
        );
    }

    @IsTest
    static void sampleSessionsIncludeLiveOnesTheConsoleLists() {
        Test.startTest();
        AgentGovSampleData.createAll();
        Test.stopTest();

        DateTime idleCutoff = DateTime.now().addMinutes(-AgentGovConstants.DEFAULT_SESSION_IDLE_MINUTES);
        Integer live = [
            SELECT COUNT()
            FROM AgentGov_Session__c
            WHERE Status__c = :AgentGovConstants.SESSION_ACTIVE AND Last_Activity__c > :idleCutoff
        ];
        Assert.isTrue(live > 0, 'Sample data shows live sessions on the console, not sessions already idle');
        Assert.areEqual(
            0,
            [
                SELECT COUNT()
                FROM AgentGov_Session__c
                WHERE Status__c != :AgentGovConstants.SESSION_ACTIVE AND Session_End__c = NULL
            ],
            'Every finished sample session has an end time'
        );
    }

    @IsTest
    static void sampleConflictsAreOnesTheResolverRecords() {
        Test.startTest();
        AgentGovSampleData.createAll();
        Test.stopTest();

        // The only combinations AgentGovConflictResolver writes, so the demonstration shows
        // outcomes a real org can produce.
        Set<String> recorded = new Set<String>{
            String.join(
                new List<String>{
                    AgentGovConstants.CONFLICT_PRIORITY_OVERRIDE,
                    AgentGovConstants.RESOLUTION_AGENT1_WON,
                    AgentGovConstants.SEVERITY_MEDIUM
                },
                '/'
            ),
            String.join(
                new List<String>{
                    AgentGovConstants.CONFLICT_CONCURRENT_WRITE,
                    AgentGovConstants.RESOLUTION_AGENT2_WON,
                    AgentGovConstants.SEVERITY_MEDIUM
                },
                '/'
            ),
            String.join(
                new List<String>{
                    AgentGovConstants.CONFLICT_LOCK_CONTENTION,
                    AgentGovConstants.RESOLUTION_FAILED,
                    AgentGovConstants.SEVERITY_HIGH
                },
                '/'
            )
        };
        List<AgentGov_Conflict_Log__c> conflicts = [
            SELECT Conflict_Type__c, Resolution__c, Severity__c, Agent_1__r.Priority__c, Agent_2__r.Priority__c
            FROM AgentGov_Conflict_Log__c
        ];
        Assert.isFalse(conflicts.isEmpty(), 'Sample conflicts are created');
        for (AgentGov_Conflict_Log__c conflict : conflicts) {
            String outcome = String.join(
                new List<String>{ conflict.Conflict_Type__c, conflict.Resolution__c, conflict.Severity__c },
                '/'
            );
            Assert.isTrue(recorded.contains(outcome), 'The resolver never records ' + outcome);
            if (conflict.Resolution__c == AgentGovConstants.RESOLUTION_AGENT1_WON) {
                Assert.isTrue(
                    conflict.Agent_1__r.Priority__c < conflict.Agent_2__r.Priority__c,
                    'An override goes to the agent with the better priority: ' + outcome
                );
            } else if (conflict.Resolution__c == AgentGovConstants.RESOLUTION_AGENT2_WON) {
                Assert.isTrue(
                    conflict.Agent_2__r.Priority__c <= conflict.Agent_1__r.Priority__c,
                    'A refused request comes from an agent with no better priority than the holder: ' + outcome
                );
            }
        }
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

        Assert.areEqual(
            0,
            [SELECT COUNT() FROM AgentGov_Registration__c],
            'Running the cleanup on an empty org is not an error'
        );
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

        // The install guide points people at this, so it must never remove an agent that is
        // not part of the sample data.
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

        // The sample keys are fixed and the hash is unique, so without this check a second run
        // would fail with a raw DUPLICATE_VALUE from the database.
        Assert.isTrue(
            second.containsIgnoreCase('already loaded'),
            'The second run explains itself instead of throwing: ' + second
        );
    }

    @IsTest
    static void deleteSampleDataLeavesNoLogRowWithoutItsAgent() {
        AgentGovSampleData.createAll();
        AgentGov_Registration__c busiest = [
            SELECT Id
            FROM AgentGov_Registration__c
            WHERE API_Key_Hash__c = :AgentGovRestAuth.hashKey(AgentGovSampleData.SAMPLE_API_KEYS[0])
        ];
        // More action log rows than one run removes, as a heavily used sample agent collects.
        List<AgentGov_Action_Log__c> history = new List<AgentGov_Action_Log__c>();
        for (Integer i = 0; i < 1500; i++) {
            history.add(
                new AgentGov_Action_Log__c(
                    Agent_Registration__c = busiest.Id,
                    Action_Type__c = AgentGovConstants.ACTION_QUERY,
                    Status__c = AgentGovConstants.ACTION_SUCCESS,
                    Timestamp__c = DateTime.now()
                )
            );
        }
        insert history;

        Test.startTest();
        Integer firstRun = AgentGovSampleData.deleteSampleData();
        Integer agentsAfterFirstRun = [SELECT COUNT() FROM AgentGov_Registration__c];
        Integer secondRun = AgentGovSampleData.deleteSampleData();
        Integer thirdRun = AgentGovSampleData.deleteSampleData();
        Test.stopTest();

        // Deleting an agent clears the lookups of its remaining log rows, after which no run
        // could find them, so the agents stay until their rows are gone.
        Assert.isTrue(firstRun > 0, 'The first run removes a capped batch');
        Assert.areEqual(
            AgentGovSampleData.SAMPLE_API_KEYS.size(),
            agentsAfterFirstRun,
            'The agents stay while rows of theirs remain'
        );
        Assert.isTrue(secondRun > 0, 'The second run removes the rest and the agents');
        Assert.areEqual(0, thirdRun, 'A third run finds nothing');
        Assert.areEqual(0, [SELECT COUNT() FROM AgentGov_Action_Log__c], 'No log row is left behind');
        Assert.areEqual(0, [SELECT COUNT() FROM AgentGov_Registration__c], 'The sample agents are gone');
    }

    @IsTest
    static void sampleAgentsWereLastActiveWhenTheirSessionsLastSawActivity() {
        Test.startTest();
        AgentGovSampleData.createAll();
        Test.stopTest();

        for (AgentGov_Session__c session : [
            SELECT Last_Activity__c, Agent_Registration__r.Agent_Name__c, Agent_Registration__r.Last_Active__c
            FROM AgentGov_Session__c
        ]) {
            Long apartMs = Math.abs(
                session.Agent_Registration__r.Last_Active__c.getTime() - session.Last_Activity__c.getTime()
            );
            Assert.isTrue(
                apartMs < 60000,
                session.Agent_Registration__r.Agent_Name__c +
                    ' was last active ' +
                    apartMs +
                    ' ms away from its session\'s last activity'
            );
        }
    }
}
