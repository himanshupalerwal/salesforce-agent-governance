/**
 * @description Tests for the system-mode data layer.
 */
@IsTest
private class AgentGovDmlTest {
    @IsTest
    static void insertsUpdatesAndDeletesInSystemMode() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('DML Agent', 'Agentforce', false);

        AgentGovDml.insertRecord(reg);
        Assert.isNotNull(reg.Id);

        reg.Agent_Name__c = 'Renamed';
        AgentGovDml.updateRecord(reg);
        Assert.areEqual(
            'Renamed',
            [SELECT Agent_Name__c FROM AgentGov_Registration__c WHERE Id = :reg.Id].Agent_Name__c
        );

        List<Database.DeleteResult> deleted = AgentGovDml.deleteRecords(new List<SObject>{ reg }, true);
        Assert.isTrue(deleted[0].isSuccess());
        Assert.areEqual(0, [SELECT COUNT() FROM AgentGov_Registration__c]);

        Assert.isTrue(AgentGovDml.insertRecords(null, true).isEmpty());
        Assert.isTrue(AgentGovDml.updateRecords(new List<SObject>(), true).isEmpty());
        Assert.isTrue(AgentGovDml.deleteRecords(null, true).isEmpty());
        Assert.isTrue(AgentGovDml.publishEvents(null).isEmpty());
    }

    @IsTest
    static void failuresAreDescribedAndAsserted() {
        AgentGov_Registration__c missingName = new AgentGov_Registration__c(
            Agent_Type__c = 'Agentforce',
            Status__c = 'Active'
        );

        List<Database.SaveResult> results = AgentGovDml.insertRecords(new List<SObject>{ missingName }, false);

        Assert.isFalse(results[0].isSuccess());
        Assert.isFalse(AgentGovDml.isDuplicateValueFailure(results[0]), 'A required-field failure is not a duplicate');
        Assert.isTrue(AgentGovDml.describeErrors(results[0].getErrors()).contains('REQUIRED_FIELD_MISSING'));
        try {
            AgentGovDml.assertAllSucceeded(results, 'Test insert');
            Assert.fail('Failures must be raised');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INTERNAL_ERROR, e.getErrorCode());
            Assert.isTrue(e.getMessage().startsWith('Test insert failed'));
        }
    }

    @IsTest
    static void duplicateValueFailureIsRecognised() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Dup Agent', 'Agentforce', true);
        AgentGovTestDataFactory.createBudget(reg.Id, true);

        List<Database.SaveResult> results = AgentGovDml.insertRecords(
            new List<SObject>{ AgentGovTestDataFactory.createBudget(reg.Id, false) },
            false
        );

        Assert.isFalse(results[0].isSuccess());
        Assert.isTrue(AgentGovDml.isDuplicateValueFailure(results[0]));
    }

    @IsTest
    static void publishesEvents() {
        List<Database.SaveResult> results = AgentGovDml.publishEvents(
            new List<SObject>{
                new AgentGov_Alert__e(Agent_Name__c = 'x', Alert_Type__c = AgentGovConstants.ALERT_WARNING)
            }
        );
        Assert.isTrue(results[0].isSuccess());
    }
}
