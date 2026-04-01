/**
 * @description Creates sample data for the AgentGov framework.
 *              Run after installation to populate the dashboard with demo data.
 *              Execute: AgentGovSampleData.createAll();
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovSampleData {

    public static void createAll() {
        // Create settings if not exist
        AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
        if (settings == null || settings.Id == null) {
            settings = new AgentGov_Settings__c(
                Is_Enabled__c = true,
                Default_Agent_Priority__c = 5,
                Circuit_Breaker_Failure_Threshold__c = 5,
                Circuit_Breaker_Cooldown_Minutes__c = 30,
                Log_Retention_Days__c = 90,
                Enable_Conflict_Detection__c = true,
                Enable_Real_Time_Events__c = true,
                Max_Concurrent_Agents__c = 10
            );
            upsert settings;
        }

        // Create sample agent registrations
        List<AgentGov_Registration__c> agents = new List<AgentGov_Registration__c>{
            new AgentGov_Registration__c(
                Agent_Name__c = 'Lead Enrichment Agent',
                Agent_Type__c = 'Agentforce',
                Status__c = 'Active',
                Priority__c = 2,
                Daily_API_Budget__c = 10000,
                Daily_SOQL_Budget__c = 5000,
                Daily_DML_Budget__c = 3000,
                Circuit_Breaker_State__c = 'CLOSED',
                Failure_Count__c = 0,
                Owner_Email__c = 'admin@example.com',
                Description__c = 'Enriches incoming leads with firmographic data from external APIs.',
                API_Key__c = 'agentgov-lead-enrichment-001'
            ),
            new AgentGov_Registration__c(
                Agent_Name__c = 'Case Routing Agent',
                Agent_Type__c = 'Agentforce',
                Status__c = 'Active',
                Priority__c = 1,
                Daily_API_Budget__c = 5000,
                Daily_SOQL_Budget__c = 8000,
                Daily_DML_Budget__c = 4000,
                Circuit_Breaker_State__c = 'CLOSED',
                Failure_Count__c = 0,
                Owner_Email__c = 'admin@example.com',
                Description__c = 'Routes incoming cases to the appropriate support queue based on AI analysis.',
                API_Key__c = 'agentgov-case-routing-002'
            ),
            new AgentGov_Registration__c(
                Agent_Name__c = 'Data Sync MCP Agent',
                Agent_Type__c = 'MCP_External',
                Status__c = 'Active',
                Priority__c = 3,
                Daily_API_Budget__c = 15000,
                Daily_SOQL_Budget__c = 3000,
                Daily_DML_Budget__c = 5000,
                Circuit_Breaker_State__c = 'CLOSED',
                Failure_Count__c = 0,
                Owner_Email__c = 'integrations@example.com',
                Description__c = 'External MCP server that synchronizes data between Salesforce and the data warehouse.',
                API_Key__c = 'agentgov-data-sync-003'
            ),
            new AgentGov_Registration__c(
                Agent_Name__c = 'Opportunity Scoring Agent',
                Agent_Type__c = 'Custom_Apex',
                Status__c = 'Throttled',
                Priority__c = 4,
                Daily_API_Budget__c = 8000,
                Daily_SOQL_Budget__c = 6000,
                Daily_DML_Budget__c = 2000,
                Circuit_Breaker_State__c = 'HALF_OPEN',
                Failure_Count__c = 3,
                Last_Failure__c = DateTime.now().addHours(-1),
                Cooldown_Until__c = DateTime.now().addMinutes(15),
                Owner_Email__c = 'datascience@example.com',
                Description__c = 'Scores opportunities based on historical win/loss patterns and engagement data.',
                API_Key__c = 'agentgov-opp-scoring-004'
            ),
            new AgentGov_Registration__c(
                Agent_Name__c = 'Email Campaign Agent',
                Agent_Type__c = 'Flow_Based',
                Status__c = 'Active',
                Priority__c = 5,
                Daily_API_Budget__c = 20000,
                Daily_SOQL_Budget__c = 2000,
                Daily_DML_Budget__c = 1000,
                Circuit_Breaker_State__c = 'CLOSED',
                Failure_Count__c = 0,
                Owner_Email__c = 'marketing@example.com',
                Description__c = 'Flow-based agent that manages email campaign sends and tracks engagement.',
                API_Key__c = 'agentgov-email-campaign-005'
            )
        };
        insert agents;

        // Create today's budgets with varying consumption
        Date today = Date.today();
        List<AgentGov_Budget__c> budgets = new List<AgentGov_Budget__c>{
            new AgentGov_Budget__c(Agent_Registration__c = agents[0].Id, Budget_Date__c = today, API_Calls_Allocated__c = 10000, API_Calls_Consumed__c = 4200, SOQL_Queries_Allocated__c = 5000, SOQL_Queries_Consumed__c = 2100, DML_Operations_Allocated__c = 3000, DML_Operations_Consumed__c = 1350, Budget_Status__c = 'Normal'),
            new AgentGov_Budget__c(Agent_Registration__c = agents[1].Id, Budget_Date__c = today, API_Calls_Allocated__c = 5000, API_Calls_Consumed__c = 4100, SOQL_Queries_Allocated__c = 8000, SOQL_Queries_Consumed__c = 5600, DML_Operations_Allocated__c = 4000, DML_Operations_Consumed__c = 3200, Budget_Status__c = 'Warning'),
            new AgentGov_Budget__c(Agent_Registration__c = agents[2].Id, Budget_Date__c = today, API_Calls_Allocated__c = 15000, API_Calls_Consumed__c = 13800, SOQL_Queries_Allocated__c = 3000, SOQL_Queries_Consumed__c = 900, DML_Operations_Allocated__c = 5000, DML_Operations_Consumed__c = 4600, Budget_Status__c = 'Throttled'),
            new AgentGov_Budget__c(Agent_Registration__c = agents[3].Id, Budget_Date__c = today, API_Calls_Allocated__c = 8000, API_Calls_Consumed__c = 1600, SOQL_Queries_Allocated__c = 6000, SOQL_Queries_Consumed__c = 1200, DML_Operations_Allocated__c = 2000, DML_Operations_Consumed__c = 400, Budget_Status__c = 'Normal'),
            new AgentGov_Budget__c(Agent_Registration__c = agents[4].Id, Budget_Date__c = today, API_Calls_Allocated__c = 20000, API_Calls_Consumed__c = 8000, SOQL_Queries_Allocated__c = 2000, SOQL_Queries_Consumed__c = 800, DML_Operations_Allocated__c = 1000, DML_Operations_Consumed__c = 450, Budget_Status__c = 'Normal')
        };
        insert budgets;

        // Create sessions
        List<AgentGov_Session__c> sessions = new List<AgentGov_Session__c>();
        for (Integer i = 0; i < agents.size(); i++) {
            sessions.add(new AgentGov_Session__c(
                Agent_Registration__c = agents[i].Id,
                Session_Start__c = DateTime.now().addHours(-i - 1),
                Status__c = i < 3 ? 'Active' : 'Completed',
                Session_End__c = i >= 3 ? DateTime.now().addMinutes(-30) : null,
                API_Calls_Used__c = Math.round(Math.random() * 500),
                SOQL_Queries_Used__c = Math.round(Math.random() * 200),
                DML_Statements_Used__c = Math.round(Math.random() * 100),
                Actions_Count__c = Math.round(Math.random() * 50)
            ));
        }
        insert sessions;

        // Create sample action logs
        List<AgentGov_Action_Log__c> logs = new List<AgentGov_Action_Log__c>();
        List<String> actionTypes = new List<String>{'Query', 'Create', 'Update', 'Delete', 'API_Call'};
        List<String> objects = new List<String>{'Account', 'Contact', 'Lead', 'Opportunity', 'Case'};

        for (Integer i = 0; i < 25; i++) {
            Integer agentIdx = Math.mod(i, agents.size());
            logs.add(new AgentGov_Action_Log__c(
                Agent_Registration__c = agents[agentIdx].Id,
                Agent_Session__c = sessions[agentIdx].Id,
                Action_Type__c = actionTypes[Math.mod(i, actionTypes.size())],
                Object_Name__c = objects[Math.mod(i, objects.size())],
                Status__c = Math.mod(i, 7) == 0 ? 'Failure' : 'Success',
                Timestamp__c = DateTime.now().addMinutes(-i * 5),
                Execution_Time_Ms__c = Math.round(Math.random() * 500 + 10)
            ));
        }
        insert logs;

        // Create sample conflict logs
        List<AgentGov_Conflict_Log__c> conflicts = new List<AgentGov_Conflict_Log__c>{
            new AgentGov_Conflict_Log__c(
                Agent_1__c = agents[0].Id,
                Agent_2__c = agents[2].Id,
                Record_Id__c = '001000000000001',
                Object_Name__c = 'Account',
                Conflict_Type__c = 'Concurrent_Write',
                Resolution__c = 'Agent1_Won',
                Severity__c = 'High',
                Timestamp__c = DateTime.now().addHours(-2),
                Details__c = 'Both agents attempted to update Account billing address simultaneously.'
            ),
            new AgentGov_Conflict_Log__c(
                Agent_1__c = agents[1].Id,
                Agent_2__c = agents[4].Id,
                Record_Id__c = '500000000000001',
                Object_Name__c = 'Case',
                Conflict_Type__c = 'Priority_Override',
                Resolution__c = 'Agent1_Won',
                Severity__c = 'Medium',
                Timestamp__c = DateTime.now().addHours(-5),
                Details__c = 'Case Routing Agent (priority 1) overrode Email Campaign Agent (priority 5) for case assignment.'
            ),
            new AgentGov_Conflict_Log__c(
                Agent_1__c = agents[2].Id,
                Agent_2__c = agents[3].Id,
                Record_Id__c = '006000000000001',
                Object_Name__c = 'Opportunity',
                Conflict_Type__c = 'Lock_Contention',
                Resolution__c = 'Queued',
                Severity__c = 'Low',
                Timestamp__c = DateTime.now().addHours(-8),
                Details__c = 'Data Sync MCP Agent queued while Opportunity Scoring Agent completed its update.'
            )
        };
        insert conflicts;

        System.debug('AgentGov Sample Data: Created ' + agents.size() + ' agents, ' + budgets.size() + ' budgets, ' + sessions.size() + ' sessions, ' + logs.size() + ' action logs, ' + conflicts.size() + ' conflict logs.');
    }

    /** @description Deletes all AgentGov sample data. */
    public static void deleteAll() {
        delete [SELECT Id FROM AgentGov_Action_Log__c];
        delete [SELECT Id FROM AgentGov_Conflict_Log__c];
        delete [SELECT Id FROM AgentGov_Session__c];
        delete [SELECT Id FROM AgentGov_Budget__c];
        delete [SELECT Id FROM AgentGov_Registration__c];
    }
}
