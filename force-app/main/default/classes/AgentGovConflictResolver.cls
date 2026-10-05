/**
 * @description Detects and resolves contention when more than one agent works on the same
 *              record within a transaction, using agent priority (lower number wins).
 *
 *              The lock table is held in memory for the current transaction, so this class
 *              catches agents that collide inside one request: a Register Agent Action batch
 *              in which several agents claim the same record, or Apex that runs several agents
 *              in one transaction. Each REST or proxy request serves a single agent, so two
 *              separate requests never meet here. Detection across transactions is on the
 *              roadmap and will be built on Platform Cache.
 *
 *              Security posture: inherited sharing. Conflict logs are written through
 *              AgentGovDml in system mode.
 */
public inherited sharing class AgentGovConflictResolver {
    private static Map<String, Id> recordLocks = new Map<String, Id>();
    private static Boolean deferring = false;
    private static List<AgentGov_Conflict_Log__c> pendingLogs = new List<AgentGov_Conflict_Log__c>();

    /**
     * @description Holds conflict log rows until flushLogs is called, so a bulk caller that
     *              checks many records writes all of their conflicts in one statement. Without
     *              it, a batch with many conflicts would issue one insert per conflict.
     */
    public static void deferLogs() {
        deferring = true;
    }

    /** @description Writes any held conflict log rows in one statement and stops holding them. */
    public static void flushLogs() {
        deferring = false;
        if (pendingLogs.isEmpty()) {
            return;
        }
        List<AgentGov_Conflict_Log__c> toInsert = pendingLogs;
        pendingLogs = new List<AgentGov_Conflict_Log__c>();
        AgentGovDml.assertAllSucceeded(AgentGovDml.insertRecords(toInsert, false), 'Conflict log');
    }

    /** @description Result of a conflict check. */
    public class ConflictResult {
        @AuraEnabled
        public Boolean hasConflict;
        @AuraEnabled
        public String resolution;
        @AuraEnabled
        public Id winningAgentId;
        @AuraEnabled
        public String message;
    }

    /**
     * @description Claims a record for an agent in this transaction and resolves a clash by
     *              priority. A free record is claimed and a record the agent already holds stays
     *              its own. When another agent holds it, the agent with the lower priority number
     *              takes it over and a tie leaves it with the holder; the clash, or an unknown
     *              agent on either side, is recorded in the conflict log. Nothing is claimed or
     *              recorded while conflict detection is switched off.
     * @param agentId The agent attempting the action
     * @param recordId The record being acted upon
     * @param objectName The object API name
     * @return The resolution; winningAgentId identifies who may proceed when there is a conflict
     */
    public static ConflictResult checkForConflict(Id agentId, String recordId, String objectName) {
        ConflictResult result = new ConflictResult();
        result.hasConflict = false;
        if (AgentGovSelector.getSettings().Enable_Conflict_Detection__c == false) {
            result.message = 'Conflict detection is disabled.';
            return result;
        }

        String lockKey = objectName + ':' + recordId;
        if (!recordLocks.containsKey(lockKey)) {
            recordLocks.put(lockKey, agentId);
            return result;
        }
        Id lockHolderId = recordLocks.get(lockKey);
        if (lockHolderId == agentId) {
            return result;
        }

        result.hasConflict = true;
        AgentGov_Registration__c currentAgent = AgentGovSelector.getRegistrationById(agentId);
        AgentGov_Registration__c lockHolder = AgentGovSelector.getRegistrationById(lockHolderId);
        if (currentAgent == null || lockHolder == null) {
            result.resolution = AgentGovConstants.RESOLUTION_FAILED;
            result.message = AgentGovConstants.ERR_AGENT_NOT_FOUND;
            // A lookup cannot point at a registration that does not exist, so the unknown
            // side is recorded in the details instead of the lookup field.
            logConflict(
                currentAgent == null ? null : agentId,
                lockHolder == null ? null : lockHolderId,
                recordId,
                objectName,
                AgentGovConstants.CONFLICT_LOCK_CONTENTION,
                AgentGovConstants.RESOLUTION_FAILED,
                AgentGovConstants.SEVERITY_HIGH,
                'Unknown agent Id: ' + (currentAgent == null ? agentId : lockHolderId)
            );
            return result;
        }

        Decimal currentPriority = currentAgent.Priority__c != null
            ? currentAgent.Priority__c
            : AgentGovConstants.DEFAULT_AGENT_PRIORITY;
        Decimal holderPriority = lockHolder.Priority__c != null
            ? lockHolder.Priority__c
            : AgentGovConstants.DEFAULT_AGENT_PRIORITY;

        if (currentPriority < holderPriority) {
            recordLocks.put(lockKey, agentId);
            result.winningAgentId = agentId;
            result.resolution = AgentGovConstants.RESOLUTION_AGENT1_WON;
            result.message =
                'Agent ' +
                currentAgent.Agent_Name__c +
                ' (priority ' +
                currentPriority +
                ') overrides ' +
                lockHolder.Agent_Name__c +
                ' (priority ' +
                holderPriority +
                ').';
            logConflict(
                agentId,
                lockHolderId,
                recordId,
                objectName,
                AgentGovConstants.CONFLICT_PRIORITY_OVERRIDE,
                AgentGovConstants.RESOLUTION_AGENT1_WON,
                AgentGovConstants.SEVERITY_MEDIUM,
                result.message
            );
        } else {
            result.winningAgentId = lockHolderId;
            result.resolution = AgentGovConstants.RESOLUTION_AGENT2_WON;
            // Reported as refused rather than queued: there is no queue, so nothing will retry
            // the request on the caller's behalf.
            result.message =
                'Record locked by ' +
                lockHolder.Agent_Name__c +
                ' (priority ' +
                holderPriority +
                '). The request from ' +
                currentAgent.Agent_Name__c +
                ' was refused.';
            logConflict(
                agentId,
                lockHolderId,
                recordId,
                objectName,
                AgentGovConstants.CONFLICT_CONCURRENT_WRITE,
                AgentGovConstants.RESOLUTION_AGENT2_WON,
                AgentGovConstants.SEVERITY_MEDIUM,
                result.message
            );
        }
        return result;
    }

    /**
     * @description Checks for a conflict and throws when another agent wins the record.
     * @param agentId The agent attempting the action
     * @param recordId The record being acted upon
     * @param objectName The object API name
     * @throws AgentGovException RECORD_LOCKED when another agent keeps the record because its priority is better or equal, or when either agent is unknown
     */
    public static void assertNoConflict(Id agentId, String recordId, String objectName) {
        ConflictResult result = checkForConflict(agentId, recordId, objectName);
        if (result.hasConflict && result.winningAgentId != agentId) {
            throw new AgentGovException(AgentGovException.ErrorCode.RECORD_LOCKED, result.message);
        }
    }

    /**
     * @description Releases a lock held by an agent.
     * @param agentId The agent releasing the lock
     * @param recordId The record to unlock
     * @param objectName The object API name
     */
    public static void releaseRecord(Id agentId, String recordId, String objectName) {
        String lockKey = objectName + ':' + recordId;
        if (recordLocks.containsKey(lockKey) && recordLocks.get(lockKey) == agentId) {
            recordLocks.remove(lockKey);
        }
    }

    /**
     * @description Checks whether a record is locked in this transaction.
     * @param recordId The record to check
     * @param objectName The object API name
     * @return True when locked
     */
    public static Boolean isRecordLocked(String recordId, String objectName) {
        return recordLocks.containsKey(objectName + ':' + recordId);
    }

    /**
     * @description Returns the agent holding a record's lock.
     * @param recordId The record to check
     * @param objectName The object API name
     * @return The lock holder's registration Id, or null
     */
    public static Id getLockHolder(String recordId, String objectName) {
        return recordLocks.get(objectName + ':' + recordId);
    }

    /** @description Clears all in-memory locks. For tests only. */
    @TestVisible
    private static void clearAllLocks() {
        recordLocks.clear();
    }

    private static void logConflict(
        Id agent1Id,
        Id agent2Id,
        String recordId,
        String objectName,
        String conflictType,
        String resolution,
        String severity,
        String details
    ) {
        AgentGov_Conflict_Log__c entry = new AgentGov_Conflict_Log__c(
            Agent_1__c = agent1Id,
            Agent_2__c = agent2Id,
            Record_Id__c = recordId,
            Object_Name__c = objectName,
            Conflict_Type__c = conflictType,
            Resolution__c = resolution,
            Severity__c = severity,
            Timestamp__c = DateTime.now(),
            Details__c = details
        );
        if (deferring) {
            pendingLogs.add(entry);
            return;
        }
        AgentGovDml.assertAllSucceeded(AgentGovDml.insertRecords(new List<SObject>{ entry }, false), 'Conflict log');
    }
}
