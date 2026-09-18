/**
 * @description Creates demonstration data so the dashboard has something to show right
 *              after installation. Run from anonymous Apex: AgentGovSampleData.createAll();
 *              The sample agents receive fixed API keys (listed in docs/getting-started.md)
 *              which are stored hashed, exactly as real keys are.
 *
 *              Security posture: with sharing. Intended to be run by an administrator from
 *              anonymous Apex, so plain DML in the running user's context is appropriate.
 */
public with sharing class AgentGovSampleData {
    /**
     * @description Rows removed per object in one run. Five objects are purged per run, so
     *              this is sized so that five full batches stay inside the 10,000-row DML
     *              limit for a single transaction.
     */
    private static final Integer DELETE_BATCH_SIZE = 1500;

    /** @description Fixed keys for the sample agents, in the order the agents are created. */
    public static final List<String> SAMPLE_API_KEYS = new List<String>{
        'agk_sample_lead_enrichment_001',
        'agk_sample_case_routing_002',
        'agk_sample_data_sync_003',
        'agk_sample_opp_scoring_004',
        'agk_sample_email_campaign_005'
    };

    /**
     * @description Creates settings, five agents, today's budgets, sessions, action logs, and conflicts.
     * @return A one-line summary of what was created
     */
    public static String createAll() {
        // The sample keys are fixed and API_Key_Hash__c is unique, so a second run would fail
        // with a raw DUPLICATE_VALUE. Say so plainly instead, and point at the cleanup.
        Set<String> sampleHashes = new Set<String>();
        for (String sampleKey : SAMPLE_API_KEYS) {
            sampleHashes.add(AgentGovRestAuth.hashKey(sampleKey));
        }
        if ([SELECT COUNT() FROM AgentGov_Registration__c WHERE API_Key_Hash__c IN :sampleHashes] > 0) {
            return 'AgentGov: sample data is already loaded. Run AgentGovSampleData.deleteSampleData() first to reload it.';
        }

        AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
        if (settings == null || settings.Id == null) {
            settings = new AgentGov_Settings__c(
                Is_Enabled__c = true,
                Default_Agent_Priority__c = AgentGovConstants.DEFAULT_AGENT_PRIORITY,
                Circuit_Breaker_Failure_Threshold__c = AgentGovConstants.DEFAULT_CB_FAILURE_THRESHOLD,
                Circuit_Breaker_Cooldown_Minutes__c = AgentGovConstants.DEFAULT_CB_COOLDOWN_MINUTES,
                Log_Retention_Days__c = AgentGovConstants.DEFAULT_LOG_RETENTION_DAYS,
                Enable_Conflict_Detection__c = true,
                Enable_Real_Time_Events__c = true,
                Max_Concurrent_Agents__c = AgentGovConstants.DEFAULT_MAX_CONCURRENT_AGENTS
            );
            upsert settings;
        }

        List<AgentGov_Registration__c> agents = new List<AgentGov_Registration__c>{
            agent(
                'Lead Enrichment Agent',
                AgentGovConstants.AGENT_TYPE_AGENTFORCE,
                AgentGovConstants.STATUS_ACTIVE,
                2,
                10000,
                5000,
                3000,
                'Enriches incoming leads with firmographic data from external APIs.'
            ),
            agent(
                'Case Routing Agent',
                AgentGovConstants.AGENT_TYPE_AGENTFORCE,
                AgentGovConstants.STATUS_ACTIVE,
                1,
                5000,
                8000,
                4000,
                'Routes incoming cases to the appropriate support queue based on AI analysis.'
            ),
            agent(
                'Data Sync MCP Agent',
                AgentGovConstants.AGENT_TYPE_MCP_EXTERNAL,
                AgentGovConstants.STATUS_ACTIVE,
                3,
                15000,
                3000,
                5000,
                'External MCP server that synchronizes data between Salesforce and the data warehouse.'
            ),
            agent(
                'Opportunity Scoring Agent',
                AgentGovConstants.AGENT_TYPE_CUSTOM_APEX,
                AgentGovConstants.STATUS_THROTTLED,
                4,
                8000,
                6000,
                2000,
                'Scores opportunities based on historical win/loss patterns and engagement data.'
            ),
            agent(
                'Email Campaign Agent',
                AgentGovConstants.AGENT_TYPE_FLOW_BASED,
                AgentGovConstants.STATUS_ACTIVE,
                5,
                20000,
                2000,
                1000,
                'Flow-based agent that manages email campaign sends and tracks engagement.'
            )
        };
        agents[3].Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN;
        agents[3].Failure_Count__c = 3;
        agents[3].Last_Failure__c = DateTime.now().addHours(-1);
        agents[3].Cooldown_Until__c = DateTime.now().addMinutes(15);
        for (Integer i = 0; i < agents.size(); i++) {
            AgentGovRestAuth.applyKey(agents[i], SAMPLE_API_KEYS[i]);
        }
        insert agents;

        Date today = Date.today();
        List<AgentGov_Budget__c> budgets = new List<AgentGov_Budget__c>{
            budget(agents[0].Id, today, 10000, 4200, 5000, 2100, 3000, 1350, AgentGovConstants.BUDGET_NORMAL),
            budget(agents[1].Id, today, 5000, 4100, 8000, 5600, 4000, 3200, AgentGovConstants.BUDGET_WARNING),
            budget(agents[2].Id, today, 15000, 13800, 3000, 900, 5000, 4600, AgentGovConstants.BUDGET_THROTTLED),
            budget(agents[3].Id, today, 8000, 1600, 6000, 1200, 2000, 400, AgentGovConstants.BUDGET_NORMAL),
            budget(agents[4].Id, today, 20000, 8000, 2000, 800, 1000, 450, AgentGovConstants.BUDGET_NORMAL)
        };
        insert budgets;

        List<AgentGov_Session__c> sessions = new List<AgentGov_Session__c>();
        for (Integer i = 0; i < agents.size(); i++) {
            sessions.add(
                new AgentGov_Session__c(
                    Agent_Registration__c = agents[i].Id,
                    Session_Start__c = DateTime.now().addHours(-i - 1),
                    Status__c = i < 3 ? AgentGovConstants.SESSION_ACTIVE : AgentGovConstants.SESSION_COMPLETED,
                    Session_End__c = i >= 3 ? DateTime.now().addMinutes(-30) : null,
                    API_Calls_Used__c = 120 * (i + 1),
                    SOQL_Queries_Used__c = 45 * (i + 1),
                    DML_Statements_Used__c = 20 * (i + 1),
                    Actions_Count__c = 12 * (i + 1)
                )
            );
        }
        insert sessions;

        List<AgentGov_Action_Log__c> logs = new List<AgentGov_Action_Log__c>();
        List<String> actionTypes = new List<String>{
            AgentGovConstants.ACTION_QUERY,
            AgentGovConstants.ACTION_CREATE,
            AgentGovConstants.ACTION_UPDATE,
            AgentGovConstants.ACTION_DELETE,
            AgentGovConstants.ACTION_API_CALL
        };
        List<String> objects = new List<String>{ 'Account', 'Contact', 'Lead', 'Opportunity', 'Case' };
        for (Integer i = 0; i < 25; i++) {
            Integer agentIndex = Math.mod(i, agents.size());
            logs.add(
                new AgentGov_Action_Log__c(
                    Agent_Registration__c = agents[agentIndex].Id,
                    Agent_Session__c = sessions[agentIndex].Id,
                    Action_Type__c = actionTypes[Math.mod(i, actionTypes.size())],
                    Object_Name__c = objects[Math.mod(i, objects.size())],
                    Status__c = Math.mod(i, 7) == 0
                        ? AgentGovConstants.ACTION_FAILURE
                        : AgentGovConstants.ACTION_SUCCESS,
                    Timestamp__c = DateTime.now().addMinutes(-i * 5),
                    Execution_Time_Ms__c = 40 + 17 * i
                )
            );
        }
        insert logs;

        List<AgentGov_Conflict_Log__c> conflicts = new List<AgentGov_Conflict_Log__c>{
            conflict(
                agents[0].Id,
                agents[2].Id,
                '001000000000001',
                'Account',
                AgentGovConstants.CONFLICT_CONCURRENT_WRITE,
                AgentGovConstants.RESOLUTION_AGENT1_WON,
                AgentGovConstants.SEVERITY_HIGH,
                -2,
                'Both agents attempted to update the Account billing address at the same time.'
            ),
            conflict(
                agents[1].Id,
                agents[4].Id,
                '500000000000001',
                'Case',
                AgentGovConstants.CONFLICT_PRIORITY_OVERRIDE,
                AgentGovConstants.RESOLUTION_AGENT1_WON,
                AgentGovConstants.SEVERITY_MEDIUM,
                -5,
                'Case Routing Agent (priority 1) overrode Email Campaign Agent (priority 5) for case assignment.'
            ),
            conflict(
                agents[2].Id,
                agents[3].Id,
                '006000000000001',
                'Opportunity',
                AgentGovConstants.CONFLICT_LOCK_CONTENTION,
                AgentGovConstants.RESOLUTION_QUEUED,
                AgentGovConstants.SEVERITY_LOW,
                -8,
                'Data Sync MCP Agent queued while Opportunity Scoring Agent completed its update.'
            )
        };
        insert conflicts;

        return 'AgentGov sample data: created ' +
            agents.size() +
            ' agents, ' +
            budgets.size() +
            ' budgets, ' +
            sessions.size() +
            ' sessions, ' +
            logs.size() +
            ' action logs, ' +
            conflicts.size() +
            ' conflict logs.';
    }

    /**
     * @description Deletes only the demonstration records this class created, identified by
     *              the fixed sample keys, along with their budgets, sessions, logs and
     *              conflicts. Real agents registered in the org are left untouched.
     *
     *              This is what the install guide points people at. deleteAll() removes every
     *              AgentGov row in the org, which is not what someone clearing a demo wants.
     * @return The number of rows removed
     */
    public static Integer deleteSampleData() {
        Set<String> hashes = new Set<String>();
        for (String sampleKey : SAMPLE_API_KEYS) {
            hashes.add(AgentGovRestAuth.hashKey(sampleKey));
        }
        List<AgentGov_Registration__c> sampleAgents = [
            SELECT Id
            FROM AgentGov_Registration__c
            WHERE API_Key_Hash__c IN :hashes
        ];
        if (sampleAgents.isEmpty()) {
            return 0;
        }
        Set<Id> agentIds = new Map<Id, AgentGov_Registration__c>(sampleAgents).keySet();

        Integer removed = 0;
        removed += purge(
            [SELECT Id FROM AgentGov_Action_Log__c WHERE Agent_Registration__c IN :agentIds LIMIT :DELETE_BATCH_SIZE]
        );
        removed += purge(
            [
                SELECT Id
                FROM AgentGov_Conflict_Log__c
                WHERE Agent_1__c IN :agentIds OR Agent_2__c IN :agentIds
                LIMIT :DELETE_BATCH_SIZE
            ]
        );
        removed += purge(
            [SELECT Id FROM AgentGov_Session__c WHERE Agent_Registration__c IN :agentIds LIMIT :DELETE_BATCH_SIZE]
        );
        removed += purge(
            [SELECT Id FROM AgentGov_Budget__c WHERE Agent_Registration__c IN :agentIds LIMIT :DELETE_BATCH_SIZE]
        );
        removed += purge(sampleAgents);
        return removed;
    }

    /**
     * @description Deletes EVERY AgentGov row in the org, not only the sample records.
     *              Use deleteSampleData() to clear a demonstration; this is the blunt
     *              instrument for resetting a scratch org.
     *
     *              Each pass is capped at DELETE_BATCH_SIZE rows so a single run cannot
     *              exceed the DML row limit in an org that has accumulated a real action log.
     *              Re-run it until it reports nothing left to delete.
     * @return The number of rows removed by this run
     */
    public static Integer deleteAll() {
        Integer removed = 0;
        removed += purge([SELECT Id FROM AgentGov_Action_Log__c LIMIT :DELETE_BATCH_SIZE]);
        removed += purge([SELECT Id FROM AgentGov_Conflict_Log__c LIMIT :DELETE_BATCH_SIZE]);
        removed += purge([SELECT Id FROM AgentGov_Session__c LIMIT :DELETE_BATCH_SIZE]);
        removed += purge([SELECT Id FROM AgentGov_Budget__c LIMIT :DELETE_BATCH_SIZE]);
        removed += purge([SELECT Id FROM AgentGov_Registration__c LIMIT :DELETE_BATCH_SIZE]);
        return removed;
    }

    private static Integer purge(List<SObject> records) {
        if (records.isEmpty()) {
            return 0;
        }
        delete records;
        return records.size();
    }

    private static AgentGov_Registration__c agent(
        String name,
        String type,
        String status,
        Integer priority,
        Integer apiBudget,
        Integer soqlBudget,
        Integer dmlBudget,
        String description
    ) {
        return new AgentGov_Registration__c(
            Agent_Name__c = name,
            Agent_Type__c = type,
            Status__c = status,
            Priority__c = priority,
            Daily_API_Budget__c = apiBudget,
            Daily_SOQL_Budget__c = soqlBudget,
            Daily_DML_Budget__c = dmlBudget,
            Circuit_Breaker_State__c = AgentGovConstants.CB_CLOSED,
            Failure_Count__c = 0,
            Owner_Email__c = 'agentgov-owner@example.com',
            Description__c = description
        );
    }

    private static AgentGov_Budget__c budget(
        Id registrationId,
        Date budgetDate,
        Integer apiAllocated,
        Integer apiConsumed,
        Integer soqlAllocated,
        Integer soqlConsumed,
        Integer dmlAllocated,
        Integer dmlConsumed,
        String status
    ) {
        return new AgentGov_Budget__c(
            Agent_Registration__c = registrationId,
            Budget_Date__c = budgetDate,
            API_Calls_Allocated__c = apiAllocated,
            API_Calls_Consumed__c = apiConsumed,
            SOQL_Queries_Allocated__c = soqlAllocated,
            SOQL_Queries_Consumed__c = soqlConsumed,
            DML_Operations_Allocated__c = dmlAllocated,
            DML_Operations_Consumed__c = dmlConsumed,
            Budget_Status__c = status
        );
    }

    private static AgentGov_Conflict_Log__c conflict(
        Id agent1Id,
        Id agent2Id,
        String recordId,
        String objectName,
        String conflictType,
        String resolution,
        String severity,
        Integer hoursAgo,
        String details
    ) {
        return new AgentGov_Conflict_Log__c(
            Agent_1__c = agent1Id,
            Agent_2__c = agent2Id,
            Record_Id__c = recordId,
            Object_Name__c = objectName,
            Conflict_Type__c = conflictType,
            Resolution__c = resolution,
            Severity__c = severity,
            Timestamp__c = DateTime.now().addHours(hoursAgo),
            Details__c = details
        );
    }
}
