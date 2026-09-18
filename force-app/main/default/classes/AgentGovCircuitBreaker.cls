/**
 * @description Implements the circuit breaker pattern for agent health.
 *
 *              States: CLOSED (normal) -> OPEN (blocked after repeated failures) ->
 *              HALF_OPEN (one probe request allowed after the cooldown) -> CLOSED on a
 *              successful probe, or back to OPEN with a doubled cooldown on a failed one.
 *
 *              Only one probe is admitted while a breaker is HALF_OPEN. The probe is claimed
 *              under a row lock by stamping Half_Open_Probe_At__c, so concurrent requests
 *              cannot all slip through the half-open window. A probe that never reports an
 *              outcome within one cooldown period is treated as abandoned and a new probe
 *              may be admitted.
 *
 *              Security posture: inherited sharing. Reads go through AgentGovSelector and
 *              writes through AgentGovDml, both of which run in system mode.
 */
public inherited sharing class AgentGovCircuitBreaker {
    /**
     * @description Checks whether an agent may make a request.
     * @param registrationId The agent registration Id
     * @return True when the request is allowed
     * @throws AgentGovException AGENT_NOT_FOUND when the registration does not exist
     */
    public static Boolean allowRequest(Id registrationId) {
        Map<Id, Boolean> decisions = allowRequests(new Set<Id>{ registrationId });
        if (!decisions.containsKey(registrationId)) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_FOUND,
                AgentGovConstants.ERR_AGENT_NOT_FOUND
            );
        }
        return decisions.get(registrationId);
    }

    /**
     * @description Checks several agents at once, performing any OPEN to HALF_OPEN transitions
     *              and probe claims in a single update.
     * @param registrationIds Agent registration Ids
     * @return Map of registration Id to decision; Ids with no registration are absent
     */
    public static Map<Id, Boolean> allowRequests(Set<Id> registrationIds) {
        Map<Id, Boolean> decisions = new Map<Id, Boolean>();
        Map<Id, AgentGov_Registration__c> registrations = AgentGovSelector.getRegistrationsByIds(registrationIds);
        Set<Id> needLock = new Set<Id>();
        for (AgentGov_Registration__c registration : registrations.values()) {
            if (stateOf(registration) == AgentGovConstants.CB_CLOSED) {
                decisions.put(registration.Id, true);
            } else {
                needLock.add(registration.Id);
            }
        }
        if (needLock.isEmpty()) {
            return decisions;
        }

        // Breakers that are not CLOSED are re-read under a row lock so that exactly one
        // transaction performs the transition or claims the probe.
        DateTime now = DateTime.now();
        Integer probeWindowMinutes = cooldownMinutes(false);
        List<AgentGov_Registration__c> changed = new List<AgentGov_Registration__c>();
        for (AgentGov_Registration__c registration : AgentGovSelector.getRegistrationsForUpdate(needLock).values()) {
            String state = stateOf(registration);
            if (state == AgentGovConstants.CB_CLOSED) {
                decisions.put(registration.Id, true);
            } else if (state == AgentGovConstants.CB_OPEN) {
                if (registration.Cooldown_Until__c != null && now >= registration.Cooldown_Until__c) {
                    moveToHalfOpen(registration);
                    registration.Half_Open_Probe_At__c = now;
                    changed.add(registration);
                    decisions.put(registration.Id, true);
                } else {
                    decisions.put(registration.Id, false);
                }
            } else {
                Boolean probeAvailable =
                    registration.Half_Open_Probe_At__c == null ||
                    registration.Half_Open_Probe_At__c.addMinutes(probeWindowMinutes) <= now;
                if (probeAvailable) {
                    registration.Half_Open_Probe_At__c = now;
                    changed.add(registration);
                }
                decisions.put(registration.Id, probeAvailable);
            }
        }
        persist(changed);
        return decisions;
    }

    /**
     * @description Records a successful action. A HALF_OPEN breaker closes.
     * @param registrationId The agent registration Id
     */
    public static void recordSuccess(Id registrationId) {
        recordOutcomes(new Map<Id, Boolean>{ registrationId => true });
    }

    /**
     * @description Records a failed action. Failures accumulate until the breaker trips;
     *              a failed HALF_OPEN probe re-trips it with a longer cooldown.
     * @param registrationId The agent registration Id
     */
    public static void recordFailure(Id registrationId) {
        recordOutcomes(new Map<Id, Boolean>{ registrationId => false });
    }

    /**
     * @description Records outcomes for several agents in one update.
     * @param outcomes Map of registration Id to true for success or false for failure
     */
    public static void recordOutcomes(Map<Id, Boolean> outcomes) {
        if (outcomes == null || outcomes.isEmpty()) {
            return;
        }
        // Read under a row lock. This is a read-modify-write on the failure tally and the
        // breaker state: without the lock a success recorded by one transaction can overwrite
        // a trip written by a concurrent failure, silently reverting it and losing the count.
        Map<Id, AgentGov_Registration__c> registrations = AgentGovSelector.getRegistrationsForUpdate(outcomes.keySet());
        Integer threshold = failureThreshold();
        DateTime now = DateTime.now();
        List<AgentGov_Registration__c> changed = new List<AgentGov_Registration__c>();
        List<AgentGov_Alert__e> alerts = new List<AgentGov_Alert__e>();

        for (AgentGov_Registration__c registration : registrations.values()) {
            Boolean succeeded = outcomes.get(registration.Id) == true;
            String state = stateOf(registration);
            if (succeeded) {
                if (state == AgentGovConstants.CB_HALF_OPEN) {
                    close(registration);
                    changed.add(registration);
                } else if (registration.Failure_Count__c != null && registration.Failure_Count__c > 0) {
                    // The threshold counts CONSECUTIVE failures, so a success has to clear the
                    // tally. Without this a long-lived agent accumulates unrelated failures
                    // over months and trips a breaker that no outage caused.
                    registration.Failure_Count__c = 0;
                    registration.Last_Failure__c = null;
                    changed.add(registration);
                }
                continue;
            }
            if (state == AgentGovConstants.CB_HALF_OPEN) {
                trip(registration, true, alerts);
                changed.add(registration);
                continue;
            }
            registration.Failure_Count__c =
                (registration.Failure_Count__c != null ? registration.Failure_Count__c : 0) + 1;
            registration.Last_Failure__c = now;
            if (registration.Failure_Count__c >= threshold) {
                trip(registration, false, alerts);
            }
            changed.add(registration);
        }
        persist(changed);
        AgentGovTriggerHandler.publishAlerts(alerts);
    }

    /**
     * @description Returns the current breaker state for an agent.
     * @param registrationId The agent registration Id
     * @return CLOSED, OPEN, or HALF_OPEN
     * @throws AgentGovException AGENT_NOT_FOUND when the registration does not exist
     */
    public static String getState(Id registrationId) {
        return stateOf(requireRegistration(registrationId));
    }

    /**
     * @description Manually closes a breaker and reactivates a blocked agent.
     * @param registrationId The agent registration Id
     * @throws AgentGovException AGENT_NOT_FOUND when the registration does not exist
     */
    public static void resetBreaker(Id registrationId) {
        AgentGov_Registration__c registration = requireRegistration(registrationId);
        close(registration);
        persist(new List<AgentGov_Registration__c>{ registration });
    }

    /**
     * @description Moves OPEN breakers whose cooldown has elapsed to HALF_OPEN. Used by the
     *              scheduled health check so agents recover even when nobody calls them.
     * @param registrations Registrations to transition
     */
    public static void transitionToHalfOpen(List<AgentGov_Registration__c> registrations) {
        if (registrations == null || registrations.isEmpty()) {
            return;
        }
        Set<Id> ids = new Set<Id>();
        for (AgentGov_Registration__c registration : registrations) {
            ids.add(registration.Id);
        }

        // Re-read under a row lock and re-check the state. The caller's rows were read without
        // a lock, so a request may have claimed the probe in between; writing the stale row
        // back would clear Half_Open_Probe_At__c and admit a second concurrent probe.
        List<AgentGov_Registration__c> changed = new List<AgentGov_Registration__c>();
        for (AgentGov_Registration__c registration : AgentGovSelector.getRegistrationsForUpdate(ids).values()) {
            if (stateOf(registration) == AgentGovConstants.CB_OPEN) {
                moveToHalfOpen(registration);
                changed.add(registration);
            }
        }
        persist(changed);
    }

    /**
     * @description Reports whether this agent is entitled to attempt a probe, WITHOUT writing
     *              anything.
     *
     *              Tripping sets Status__c to Blocked, and a Blocked agent is refused at
     *              authentication before any breaker code runs, which left an agent that only
     *              speaks REST locked out until the scheduled health check happened to run.
     *              The status check consults this so such a caller is allowed through to the
     *              breaker itself.
     *
     *              This deliberately performs no DML. An earlier version transitioned the
     *              breaker here, from an unlocked read, and cleared Half_Open_Probe_At__c as
     *              it did so: two requests arriving as the cooldown expired could each wipe
     *              the other's probe claim and both be admitted. The OPEN to HALF_OPEN
     *              transition and the probe claim belong together, under the row lock that
     *              allowRequests already takes.
     * @param registration The agent to test
     * @return True when the breaker is HALF_OPEN, or OPEN with its cooldown served
     */
    public static Boolean mayProbe(AgentGov_Registration__c registration) {
        if (registration == null) {
            return false;
        }
        String state = stateOf(registration);
        if (state == AgentGovConstants.CB_HALF_OPEN) {
            return true;
        }
        return state == AgentGovConstants.CB_OPEN &&
            registration.Cooldown_Until__c != null &&
            DateTime.now() >= registration.Cooldown_Until__c;
    }

    // --- Private helpers ---

    private static String stateOf(AgentGov_Registration__c registration) {
        return registration.Circuit_Breaker_State__c != null
            ? registration.Circuit_Breaker_State__c
            : AgentGovConstants.CB_CLOSED;
    }

    private static AgentGov_Registration__c requireRegistration(Id registrationId) {
        AgentGov_Registration__c registration = AgentGovSelector.getRegistrationById(registrationId);
        if (registration == null) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_FOUND,
                AgentGovConstants.ERR_AGENT_NOT_FOUND
            );
        }
        return registration;
    }

    private static void moveToHalfOpen(AgentGov_Registration__c registration) {
        registration.Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN;
        registration.Half_Open_Probe_At__c = null;
        if (registration.Status__c == AgentGovConstants.STATUS_BLOCKED) {
            registration.Status__c = AgentGovConstants.STATUS_THROTTLED;
        }
    }

    private static void close(AgentGov_Registration__c registration) {
        registration.Circuit_Breaker_State__c = AgentGovConstants.CB_CLOSED;
        registration.Failure_Count__c = 0;
        registration.Last_Failure__c = null;
        registration.Cooldown_Until__c = null;
        registration.Half_Open_Probe_At__c = null;
        if (
            registration.Status__c == AgentGovConstants.STATUS_THROTTLED ||
            registration.Status__c == AgentGovConstants.STATUS_BLOCKED
        ) {
            registration.Status__c = AgentGovConstants.STATUS_ACTIVE;
        }
    }

    private static void trip(AgentGov_Registration__c registration, Boolean isRetry, List<AgentGov_Alert__e> alerts) {
        registration.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        registration.Status__c = AgentGovConstants.STATUS_BLOCKED;
        registration.Cooldown_Until__c = DateTime.now().addMinutes(cooldownMinutes(isRetry));
        registration.Half_Open_Probe_At__c = null;
        alerts.add(
            new AgentGov_Alert__e(
                Agent_Id__c = registration.Id,
                Agent_Name__c = registration.Agent_Name__c,
                Alert_Type__c = AgentGovConstants.ALERT_BLOCK,
                Limit_Type__c = AgentGovConstants.ALERT_LIMIT_CIRCUIT_BREAKER,
                Current_Usage__c = registration.Failure_Count__c,
                Budget_Allocated__c = failureThreshold(),
                Usage_Percentage__c = 100,
                Timestamp__c = DateTime.now()
            )
        );
    }

    private static Integer cooldownMinutes(Boolean isRetry) {
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        Integer base = settings.Circuit_Breaker_Cooldown_Minutes__c != null
            ? (Integer) settings.Circuit_Breaker_Cooldown_Minutes__c
            : AgentGovConstants.DEFAULT_CB_COOLDOWN_MINUTES;
        Integer minutes = isRetry ? base * AgentGovConstants.CB_RETRY_COOLDOWN_MULTIPLIER : base;
        return Math.min(minutes, AgentGovConstants.CB_MAX_COOLDOWN_MINUTES);
    }

    private static Integer failureThreshold() {
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        return settings.Circuit_Breaker_Failure_Threshold__c != null
            ? (Integer) settings.Circuit_Breaker_Failure_Threshold__c
            : AgentGovConstants.DEFAULT_CB_FAILURE_THRESHOLD;
    }

    private static void persist(List<AgentGov_Registration__c> changed) {
        if (changed.isEmpty()) {
            return;
        }
        AgentGovDml.assertAllSucceeded(AgentGovDml.updateRecords(changed, false), 'Circuit breaker update');
        for (AgentGov_Registration__c registration : changed) {
            AgentGovSelector.cacheRegistration(registration);
        }
    }
}
