/**
 * @description Invocable action to log an agent action from Flows.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovLogAction {

    public class Request {
        @InvocableVariable(label='Agent Registration ID' required=true)
        public Id registrationId;
        @InvocableVariable(label='Action Type' required=true description='Query, Create, Update, Delete, Upsert, API_Call, Flow_Trigger')
        public String actionType;
        @InvocableVariable(label='Object Name')
        public String objectName;
        @InvocableVariable(label='Record ID')
        public String recordId;
        @InvocableVariable(label='Status' required=true description='Success, Failure, Denied, Throttled')
        public String status;
        @InvocableVariable(label='Details')
        public String details;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(label='Log Agent Action' description='Logs an action performed by an agent' category='AgentGov')
    public static List<Result> logAction(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result result = new Result();
            try {
                AgentGovTriggerHandler.logAction(
                    req.registrationId,
                    req.actionType,
                    req.objectName,
                    req.recordId,
                    req.status,
                    req.details
                );
                result.success = true;
            } catch (Exception e) {
                result.success = false;
                result.errorMessage = e.getMessage();
            }
            results.add(result);
        }
        return results;
    }
}
