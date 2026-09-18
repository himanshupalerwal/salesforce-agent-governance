/**
 * @description Read-only Apex controller for the AgentGov Lightning Web Components.
 *
 *              Security posture: with sharing, and every query runs WITH USER_MODE.
 *              The dashboards present framework data to people, so they must show only
 *              what the viewing user is allowed to see. This is the opposite choice from
 *              AgentGovSelector, which reads on behalf of the framework itself.
 *
 *              Every method is cacheable so components can use @wire and refreshApex.
 */
public with sharing class AgentGovDashboardController {
    /** @description Returns every agent registration the viewer can see. */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Registration__c> getAllRegistrations() {
        try {
            return [
                SELECT
                    Id,
                    Name,
                    Agent_Name__c,
                    Agent_Type__c,
                    Status__c,
                    Owner_Email__c,
                    Priority__c,
                    Daily_API_Budget__c,
                    Daily_SOQL_Budget__c,
                    Daily_DML_Budget__c,
                    Last_Active__c,
                    Circuit_Breaker_State__c,
                    Failure_Count__c,
                    Last_Failure__c,
                    Cooldown_Until__c
                FROM AgentGov_Registration__c
                WITH USER_MODE
                ORDER BY Agent_Name__c
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /** @description Returns today's budgets with the owning agent's name. */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Budget__c> getAllTodaysBudgets() {
        Date today = Date.today();
        try {
            return [
                SELECT
                    Id,
                    Agent_Registration__c,
                    Agent_Registration__r.Agent_Name__c,
                    Budget_Date__c,
                    API_Calls_Allocated__c,
                    API_Calls_Consumed__c,
                    SOQL_Queries_Allocated__c,
                    SOQL_Queries_Consumed__c,
                    DML_Operations_Allocated__c,
                    DML_Operations_Consumed__c,
                    Budget_Status__c
                FROM AgentGov_Budget__c
                WHERE Budget_Date__c = :today
                WITH USER_MODE
                ORDER BY Agent_Registration__r.Agent_Name__c
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Returns the most recent conflict logs.
     * @param limitCount Maximum number of rows to return
     */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Conflict_Log__c> getRecentConflictLogs(Integer limitCount) {
        Integer rowLimit = limitCount == null || limitCount < 1 ? 50 : limitCount;
        try {
            return [
                SELECT
                    Id,
                    Agent_1__c,
                    Agent_2__c,
                    Record_Id__c,
                    Object_Name__c,
                    Conflict_Type__c,
                    Resolution__c,
                    Severity__c,
                    Timestamp__c,
                    Details__c,
                    Agent_1__r.Agent_Name__c,
                    Agent_2__r.Agent_Name__c
                FROM AgentGov_Conflict_Log__c
                WITH USER_MODE
                ORDER BY Timestamp__c DESC
                LIMIT :rowLimit
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /** @description Counts the actions logged today. */
    @AuraEnabled(cacheable=true)
    public static Integer getTodaysActionCount() {
        try {
            return [
                SELECT COUNT()
                FROM AgentGov_Action_Log__c
                WHERE Timestamp__c = TODAY
                WITH USER_MODE
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /** @description Returns active sessions with their resource usage and agent name. */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Session__c> getActiveSessions() {
        try {
            return [
                SELECT
                    Id,
                    Agent_Registration__c,
                    Agent_Registration__r.Agent_Name__c,
                    Session_Start__c,
                    Status__c,
                    API_Calls_Used__c,
                    SOQL_Queries_Used__c,
                    DML_Statements_Used__c,
                    Actions_Count__c
                FROM AgentGov_Session__c
                WHERE Status__c = :AgentGovConstants.SESSION_ACTIVE
                WITH USER_MODE
                ORDER BY Session_Start__c DESC
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /** @description Counts agents whose circuit breaker is OPEN. */
    @AuraEnabled(cacheable=true)
    public static Integer getTrippedCircuitBreakerCount() {
        try {
            return [
                SELECT COUNT()
                FROM AgentGov_Registration__c
                WHERE Circuit_Breaker_State__c = :AgentGovConstants.CB_OPEN
                WITH USER_MODE
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Converts a user-mode access failure into a message the component can show.
     *              The platform message names the inaccessible object or field, which is
     *              exactly what an administrator needs in order to fix the permission set.
     *              User mode raises SecurityException when the object itself is out of reach
     *              and QueryException when a field is, so both are treated as access failures;
     *              anything else is re-thrown so a real defect is not disguised as a
     *              permission problem.
     * @param failure The exception raised by the query
     * @return An exception carrying a message the Lightning component can display
     */
    private static AuraHandledException toAuraException(Exception failure) {
        if (!(failure instanceof QueryException) && !(failure instanceof SecurityException)) {
            throw failure;
        }
        String message =
            'You do not have access to some AgentGov data. Ask an administrator for the AgentGov User permission set. (' +
            failure.getMessage() +
            ')';
        AuraHandledException aura = new AuraHandledException(message);
        // AuraHandledException hides its constructor message from clients unless it is set explicitly.
        aura.setMessage(message);
        return aura;
    }
}
