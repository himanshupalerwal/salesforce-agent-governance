// Loads demonstration data for the AgentGov dashboards.
// Run with: sf apex run --file scripts/setup/load-sample-data.apex --target-org <alias>
System.debug(LoggingLevel.INFO, AgentGovSampleData.createAll());
