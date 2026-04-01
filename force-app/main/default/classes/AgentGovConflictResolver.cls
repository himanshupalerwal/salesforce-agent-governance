/**
 * @description Detects and resolves conflicts when multiple AI agents attempt
 *              to modify the same record simultaneously. Uses priority-based resolution.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovConflictResolver {

    // In-memory lock table for the current transaction
    private static Map<String, Id> recordLocks = new Map<String, Id>();

    /**
     * @description Result of a conflict check.
     */
    public class ConflictResult {
        @AuraEnabled public Boolean hasConflict;
        @AuraEnabled public String resolution;
        @AuraEnabled public Id winningAgentId;
        @AuraEnabled public String message;
    }

    /**
     * @description Checks if a record is locked by another agent and resolves based on priority.
     * @param agentId The agent attempting the action
     * @param recordId The record being acted upon
     * @param objectName The API name of the object
     * @return ConflictResult with resolution details
     */
    public static ConflictResult checkForConflict(Id agentId, String recordId, String objectName) {
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        if (settings.Enable_Conflict_Detection__c == false) {
            ConflictResult result = new ConflictResult();
            result.hasConflict = false;
            result.message = 'Conflict detection is disabled.';
            return result;
        }

        String lockKey = objectName + ':' + recordId;
        ConflictResult result = new ConflictResult();

        if (!recordLocks.containsKey(lockKey)) {
            // No conflict — lock it for this agent
            result.hasConflict = false;
            recordLocks.put(lockKey, agentId);
            return result;
        }

        Id lockHolderId = recordLocks.get(lockKey);
        if (lockHolderId == agentId) {
            // Same agent — no conflict
            result.hasConflict = false;
            return result;
        }

        // Conflict detected — resolve by priority
        result.hasConflict = true;
        AgentGov_Registration__c currentAgent = AgentGovSelector.getRegistrationById(agentId);
        AgentGov_Registration__c lockHolder = AgentGovSelector.getRegistrationById(lockHolderId);

        if (currentAgent == null || lockHolder == null) {
            result.resolution = AgentGovConstants.RESOLUTION_FAILED;
            result.message = AgentGovConstants.ERR_AGENT_NOT_FOUND;
            logConflict(agentId, lockHolderId, recordId, objectName,
                AgentGovConstants.CONFLICT_LOCK_CONTENTION, AgentGovConstants.RESOLUTION_FAILED, AgentGovConstants.SEVERITY_HIGH);
            return result;
        }

        Decimal currentPriority = currentAgent.Priority__c != null ? currentAgent.Priority__c : AgentGovConstants.DEFAULT_AGENT_PRIORITY;
        Decimal holderPriority = lockHolder.Priority__c != null ? lockHolder.Priority__c : AgentGovConstants.DEFAULT_AGENT_PRIORITY;

        // Lower number = higher priority
        if (currentPriority < holderPriority) {
            // Current agent wins — override the lock
            recordLocks.put(lockKey, agentId);
            result.winningAgentId = agentId;
            result.resolution = AgentGovConstants.RESOLUTION_AGENT1_WON;
            result.message = 'Agent ' + currentAgent.Agent_Name__c + ' (priority ' + currentPriority + ') overrides '
                + lockHolder.Agent_Name__c + ' (priority ' + holderPriority + ').';
            logConflict(agentId, lockHolderId, recordId, objectName,
                AgentGovConstants.CONFLICT_PRIORITY_OVERRIDE, AgentGovConstants.RESOLUTION_AGENT1_WON, AgentGovConstants.SEVERITY_MEDIUM);
        } else {
            // Lock holder wins — current agent is queued
            result.winningAgentId = lockHolderId;
            result.resolution = AgentGovConstants.RESOLUTION_AGENT2_WON;
            result.message = 'Record locked by ' + lockHolder.Agent_Name__c + ' (priority ' + holderPriority
                + '). Agent ' + currentAgent.Agent_Name__c + ' queued.';
            logConflict(agentId, lockHolderId, recordId, objectName,
                AgentGovConstants.CONFLICT_CONCURRENT_WRITE, AgentGovConstants.RESOLUTION_AGENT2_WON, AgentGovConstants.SEVERITY_MEDIUM);
        }

        return result;
    }

    /**
     * @description Releases a record lock held by an agent.
     * @param agentId The agent releasing the lock
     * @param recordId The record to unlock
     * @param objectName The API name of the object
     */
    public static void releaseRecord(Id agentId, String recordId, String objectName) {
        String lockKey = objectName + ':' + recordId;
        if (recordLocks.containsKey(lockKey) && recordLocks.get(lockKey) == agentId) {
            recordLocks.remove(lockKey);
        }
    }

    /**
     * @description Checks if a record is currently locked.
     * @param recordId The record to check
     * @param objectName The API name of the object
     * @return True if the record is locked
     */
    public static Boolean isRecordLocked(String recordId, String objectName) {
        return recordLocks.containsKey(objectName + ':' + recordId);
    }

    /**
     * @description Gets the agent ID that holds the lock on a record.
     * @param recordId The record to check
     * @param objectName The API name of the object
     * @return The agent registration ID holding the lock, or null
     */
    public static Id getLockHolder(String recordId, String objectName) {
        return recordLocks.get(objectName + ':' + recordId);
    }

    /**
     * @description Clears all in-memory locks. For testing only.
     */
    @TestVisible
    private static void clearAllLocks() {
        recordLocks.clear();
    }

    private static void logConflict(Id agent1Id, Id agent2Id, String recordId, String objectName, String conflictType, String resolution, String severity) {
        try {
            AgentGov_Conflict_Log__c log = new AgentGov_Conflict_Log__c(
                Agent_1__c = agent1Id,
                Agent_2__c = agent2Id,
                Record_Id__c = recordId,
                Object_Name__c = objectName,
                Conflict_Type__c = conflictType,
                Resolution__c = resolution,
                Severity__c = severity,
                Timestamp__c = DateTime.now()
            );
            insert log;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AgentGov: Failed to log conflict: ' + e.getMessage());
        }
    }
}
