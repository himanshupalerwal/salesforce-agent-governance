// AgentGov pre-deployment step for orgs upgrading from v1.1: merge duplicate daily budget rows.
//
// v1.2 adds a unique key (Budget_Key__c) that guarantees one Governor Budget row per
// agent per day. Orgs running an earlier release under concurrent load may already hold
// duplicates. The field itself deploys cleanly over them, because existing rows get a null
// key and nulls do not collide; the failure comes later, when the trigger stamps a key onto
// two rows that share an agent and a date and the second write is rejected. This script
// merges each duplicate group into its oldest row, summing the consumed counters and
// re-evaluating the status from the merged totals, then deletes the extras.
//
// Run it BEFORE deploying v1.2 or any later release. It is safe to run more than once.
//
// The work is bounded so it cannot exceed a governor limit in a large org. The aggregate query
// that finds duplicate groups is charged one query row per group it returns, and returns at most
// GROUP_LIMIT of them. The detail query is filtered by both agent and date, which combine as a
// cross-product and can match rows that are not duplicates, so it is capped at DETAIL_ROW_LIMIT
// rows and keeps only the rows of duplicate groups, at most MERGE_ROW_LIMIT per run. Re-run the
// script until it reports that no duplicates remain.
//
// Run with: sf apex run --file scripts/migrate/dedupe-budgets.apex --target-org <alias>

Integer GROUP_LIMIT = 500;
Integer DETAIL_ROW_LIMIT = 40000;
Integer MERGE_ROW_LIMIT = 5000;

// Only groups that actually contain duplicates are returned, so the query rows this costs track
// the number of duplicates rather than the size of the ledger.
List<AggregateResult> duplicateGroups = [
    SELECT Agent_Registration__c agentId, Budget_Date__c budgetDate
    FROM AgentGov_Budget__c
    GROUP BY Agent_Registration__c, Budget_Date__c
    HAVING COUNT(Id) > 1
    LIMIT :GROUP_LIMIT
];

if (duplicateGroups.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'AgentGov: no duplicate budget rows found. Safe to deploy.');
    return;
}

Set<Id> agentIds = new Set<Id>();
Set<Date> budgetDates = new Set<Date>();
Set<String> duplicateKeys = new Set<String>();
for (AggregateResult duplicateGroup : duplicateGroups) {
    Id agentId = (Id) duplicateGroup.get('agentId');
    Date budgetDate = (Date) duplicateGroup.get('budgetDate');
    agentIds.add(agentId);
    budgetDates.add(budgetDate);
    duplicateKeys.add(String.valueOf(agentId) + '_' + String.valueOf(budgetDate));
}

// Thresholds come from configuration when it exists, per limit type, so the recomputed status
// matches what the running framework would decide. Each limit type carries its own thresholds;
// applying the API_Calls values to all three would mislabel the merged rows. Inactive
// configurations are ignored, as the framework ignores them.
Map<String, List<Decimal>> thresholdsByType = new Map<String, List<Decimal>>{
    'API_Calls' => new List<Decimal>{ 80, 90, 95 },
    'SOQL_Queries' => new List<Decimal>{ 80, 90, 95 },
    'DML_Operations' => new List<Decimal>{ 80, 90, 95 }
};
for (AgentGov_Limit_Config__mdt limitConfig : [
    SELECT Limit_Type__c, Warning_Threshold__c, Throttle_Threshold__c, Block_Threshold__c
    FROM AgentGov_Limit_Config__mdt
    WHERE Is_Active__c = TRUE
]) {
    if (!thresholdsByType.containsKey(limitConfig.Limit_Type__c)) {
        continue;
    }
    List<Decimal> current = thresholdsByType.get(limitConfig.Limit_Type__c);
    thresholdsByType.put(
        limitConfig.Limit_Type__c,
        new List<Decimal>{
            limitConfig.Warning_Threshold__c != null ? limitConfig.Warning_Threshold__c : current[0],
            limitConfig.Throttle_Threshold__c != null ? limitConfig.Throttle_Threshold__c : current[1],
            limitConfig.Block_Threshold__c != null ? limitConfig.Block_Threshold__c : current[2]
        }
    );
}

// Rows arrive oldest first, so a group that a limit cuts short still ends up merged into its
// oldest row: the rows this run does not reach are merged on the next one.
Map<String, List<AgentGov_Budget__c>> groups = new Map<String, List<AgentGov_Budget__c>>();
Integer rowsRead = 0;
Integer rowsHeld = 0;
for (AgentGov_Budget__c budget : [
    SELECT
        Id,
        Agent_Registration__c,
        Budget_Date__c,
        Budget_Status__c,
        API_Calls_Allocated__c,
        API_Calls_Consumed__c,
        SOQL_Queries_Allocated__c,
        SOQL_Queries_Consumed__c,
        DML_Operations_Allocated__c,
        DML_Operations_Consumed__c
    FROM AgentGov_Budget__c
    WHERE Agent_Registration__c IN :agentIds AND Budget_Date__c IN :budgetDates
    ORDER BY CreatedDate ASC
    LIMIT :DETAIL_ROW_LIMIT
]) {
    rowsRead++;
    String key = String.valueOf(budget.Agent_Registration__c) + '_' + String.valueOf(budget.Budget_Date__c);
    if (!duplicateKeys.contains(key)) {
        continue;
    }
    if (rowsHeld == MERGE_ROW_LIMIT) {
        break;
    }
    if (!groups.containsKey(key)) {
        groups.put(key, new List<AgentGov_Budget__c>());
    }
    groups.get(key).add(budget);
    rowsHeld++;
}

List<AgentGov_Budget__c> survivors = new List<AgentGov_Budget__c>();
List<AgentGov_Budget__c> extras = new List<AgentGov_Budget__c>();

for (List<AgentGov_Budget__c> duplicates : groups.values()) {
    if (duplicates.size() < 2) {
        continue;
    }
    AgentGov_Budget__c survivor = duplicates[0];
    for (Integer i = 1; i < duplicates.size(); i++) {
        AgentGov_Budget__c extra = duplicates[i];
        survivor.API_Calls_Consumed__c =
            (survivor.API_Calls_Consumed__c == null ? 0 : survivor.API_Calls_Consumed__c) +
            (extra.API_Calls_Consumed__c == null ? 0 : extra.API_Calls_Consumed__c);
        survivor.SOQL_Queries_Consumed__c =
            (survivor.SOQL_Queries_Consumed__c == null ? 0 : survivor.SOQL_Queries_Consumed__c) +
            (extra.SOQL_Queries_Consumed__c == null ? 0 : extra.SOQL_Queries_Consumed__c);
        survivor.DML_Operations_Consumed__c =
            (survivor.DML_Operations_Consumed__c == null ? 0 : survivor.DML_Operations_Consumed__c) +
            (extra.DML_Operations_Consumed__c == null ? 0 : extra.DML_Operations_Consumed__c);
        extras.add(extra);
    }

    // The status is recomputed from the merged totals, not carried over. Two rows that
    // were each comfortably Normal can be Blocked or Exhausted once added together, and
    // keeping the more severe stored value would understate the real usage.
    Map<String, List<Decimal>> usageByType = new Map<String, List<Decimal>>{
        'API_Calls' => new List<Decimal>{ survivor.API_Calls_Consumed__c, survivor.API_Calls_Allocated__c },
        'SOQL_Queries' => new List<Decimal>{ survivor.SOQL_Queries_Consumed__c, survivor.SOQL_Queries_Allocated__c },
        'DML_Operations' => new List<Decimal>{
            survivor.DML_Operations_Consumed__c,
            survivor.DML_Operations_Allocated__c
        }
    };
    Map<String, Integer> statusRank = new Map<String, Integer>{
        'Normal' => 0,
        'Warning' => 1,
        'Throttled' => 2,
        'Blocked' => 3,
        'Exhausted' => 4
    };
    String worstStatus = 'Normal';
    for (String limitType : usageByType.keySet()) {
        Decimal consumed = usageByType.get(limitType)[0] == null ? 0 : usageByType.get(limitType)[0];
        Decimal allocated = usageByType.get(limitType)[1] == null ? 0 : usageByType.get(limitType)[1];
        Decimal percent = allocated > 0 ? consumed.divide(allocated, 4) * 100 : (consumed > 0 ? 100 : 0);
        List<Decimal> t = thresholdsByType.get(limitType);
        String status;
        if (percent >= 100) {
            status = 'Exhausted';
        } else if (percent >= t[2]) {
            status = 'Blocked';
        } else if (percent >= t[1]) {
            status = 'Throttled';
        } else if (percent >= t[0]) {
            status = 'Warning';
        } else {
            status = 'Normal';
        }
        if (statusRank.get(status) > statusRank.get(worstStatus)) {
            worstStatus = status;
        }
    }
    survivor.Budget_Status__c = worstStatus;

    survivors.add(survivor);
}

// Extras are removed first so that stamping a key onto the survivor cannot collide with a
// row that is on its way out.
delete extras;
update survivors;

Boolean finished = duplicateGroups.size() < GROUP_LIMIT && rowsRead < DETAIL_ROW_LIMIT && rowsHeld < MERGE_ROW_LIMIT;
String remaining = finished
    ? ' No duplicates remain.'
    : ' This run reached one of its limits, so run this script again until it reports no duplicates.';
System.debug(
    LoggingLevel.INFO,
    'AgentGov: merged ' +
        extras.size() +
        ' duplicate budget row(s) into ' +
        survivors.size() +
        ' surviving row(s).' +
        remaining
);
