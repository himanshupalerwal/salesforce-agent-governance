/**
 * @description Tests for the per-request correlation id and timing.
 */
@IsTest
private class AgentGovRequestContextTest {
    @IsTest
    static void aRequestKeepsTheCallersIdOrGetsAGeneratedOne() {
        AgentGovRequestContext.begin('caller-supplied-id');
        Assert.areEqual('caller-supplied-id', AgentGovRequestContext.getCorrelationId());
        Assert.isTrue(AgentGovRequestContext.elapsedMs() >= 0);

        AgentGovRequestContext.begin(null);
        Assert.areEqual(36, AgentGovRequestContext.getCorrelationId().length(), 'A UUID is generated');

        AgentGovRequestContext.begin('x'.repeat(300));
        Assert.areEqual(255, AgentGovRequestContext.getCorrelationId().length(), 'Held to the field length');
    }

    @IsTest
    static void outsideARequestThereIsNoIdOrDuration() {
        AgentGovRequestContext.reset();
        Assert.isNull(AgentGovRequestContext.getCorrelationId());
        Assert.isNull(AgentGovRequestContext.elapsedMs());
    }

    @IsTest
    static void ensureBegunDoesNotRestartARequestInProgress() {
        AgentGovRequestContext.begin('outer');
        AgentGovRequestContext.ensureBegun('inner');
        Assert.areEqual('outer', AgentGovRequestContext.getCorrelationId());

        AgentGovRequestContext.reset();
        AgentGovRequestContext.ensureBegun('inner');
        Assert.areEqual('inner', AgentGovRequestContext.getCorrelationId());
    }
}
