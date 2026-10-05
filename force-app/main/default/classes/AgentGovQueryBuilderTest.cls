/**
 * @description Tests for AgentGovQueryBuilder: parsing, validation, SOQL compilation with
 *              bind variables, limits and record caps, value conversion, the read-access check,
 *              and how a query the database refuses is classified.
 */
@IsTest
private class AgentGovQueryBuilderTest {
    private static Map<String, Object> body(String objectName, List<String> fields) {
        return new Map<String, Object>{ 'objectName' => objectName, 'fields' => fields };
    }

    private static Map<String, Object> withCondition(
        Map<String, Object> request,
        String field,
        String op,
        Object value
    ) {
        request.put(
            'where',
            new List<Object>{ new Map<String, Object>{ 'field' => field, 'op' => op, 'value' => value } }
        );
        return request;
    }

    private static void expectInvalidWith(Map<String, Object> request, String expectedMessage) {
        try {
            build(request, null);
            Assert.fail('Must be rejected: ' + expectedMessage);
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode(), e.getMessage());
            Assert.areEqual(expectedMessage, e.getMessage());
        }
    }

    private static AgentGovQueryBuilder.BuiltQuery build(Map<String, Object> request, Integer maxRecords) {
        AgentGovQueryBuilder.QueryRequest parsed = AgentGovQueryBuilder.parse(request);
        return AgentGovQueryBuilder.build(parsed, AgentGovQueryBuilder.describe(parsed.objectName), maxRecords);
    }

    private static void expectInvalid(Map<String, Object> request, String because) {
        try {
            build(request, null);
            Assert.fail(because);
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode(), because);
        }
    }

    @IsTest
    static void compilesSelectWhereOrderAndLimitWithBinds() {
        Map<String, Object> request = body('Account', new List<String>{ 'Id', 'name', 'Name' });
        request.put(
            'where',
            new List<Object>{
                new Map<String, Object>{ 'field' => 'Name', 'op' => 'like', 'value' => 'Acme%' },
                new Map<String, Object>{
                    'field' => 'Industry',
                    'op' => 'in',
                    'value' => new List<Object>{ 'Energy', 'Retail' }
                }
            }
        );
        request.put('orderBy', new Map<String, Object>{ 'field' => 'Name', 'direction' => 'desc' });
        request.put('limit', 25);

        AgentGovQueryBuilder.BuiltQuery built = build(request, null);

        Assert.areEqual(
            'SELECT Id, Name FROM Account WHERE Name LIKE :b0 AND Industry IN :b1 ORDER BY Name DESC LIMIT 25',
            built.soql
        );
        Assert.areEqual('Acme%', built.binds.get('b0'));
        Assert.areEqual(2, ((List<Object>) built.binds.get('b1')).size());
        Assert.areEqual(new Set<String>{ 'Id', 'Name', 'Industry' }, built.referencedFields);
        Assert.areEqual(25, built.effectiveLimit);
        Assert.areEqual(0, AgentGovQueryBuilder.execute(built).size(), 'The compiled query runs');
    }

    @IsTest
    static void limitIsCappedByPolicyAndByMaximum() {
        Map<String, Object> request = body('Account', new List<String>{ 'Id' });
        Assert.areEqual(
            AgentGovConstants.DEFAULT_QUERY_LIMIT,
            build(request, null).effectiveLimit,
            'Default when none requested'
        );

        request.put('limit', 10000);
        Assert.areEqual(
            AgentGovConstants.MAX_QUERY_LIMIT,
            build(request, null).effectiveLimit,
            'Never above the framework maximum'
        );
        Assert.areEqual(50, build(request, 50).effectiveLimit, 'Never above the policy cap');
    }

    @IsTest
    static void rejectsMalformedRequests() {
        expectInvalid(new Map<String, Object>{ 'query' => 'SELECT Id FROM Account' }, 'raw SOQL');
        expectInvalid(body('', new List<String>{ 'Id' }), 'blank object');
        expectInvalid(body('Account', new List<String>()), 'no fields');
        expectInvalid(body('Account', new List<String>{ 'Owner.Name' }), 'relationship path');
        expectInvalid(body('Account', new List<String>{ 'Nope__c' }), 'unknown field');
        expectInvalid(body('No_Such_Object__c', new List<String>{ 'Id' }), 'unknown object');
        expectInvalid(body('Account; DELETE', new List<String>{ 'Id' }), 'object name with punctuation');

        Map<String, Object> badOperator = body('Account', new List<String>{ 'Id' });
        badOperator.put(
            'where',
            new List<Object>{ new Map<String, Object>{ 'field' => 'Name', 'op' => 'INCLUDES', 'value' => 'x' } }
        );
        expectInvalid(badOperator, 'unsupported operator');

        Map<String, Object> scalarIn = body('Account', new List<String>{ 'Id' });
        scalarIn.put(
            'where',
            new List<Object>{ new Map<String, Object>{ 'field' => 'Name', 'op' => 'IN', 'value' => 'x' } }
        );
        expectInvalid(scalarIn, 'IN needs a list');

        Map<String, Object> badWhere = body('Account', new List<String>{ 'Id' });
        badWhere.put('where', 'Name = 1');
        expectInvalid(badWhere, 'where must be a list');

        Map<String, Object> badLimit = body('Account', new List<String>{ 'Id' });
        badLimit.put('limit', 0);
        expectInvalid(badLimit, 'limit below one');

        Map<String, Object> badOrder = body('Account', new List<String>{ 'Id' });
        badOrder.put('orderBy', 'Name');
        expectInvalid(badOrder, 'orderBy must be an object');
    }

    @IsTest
    static void convertsJsonValuesToFieldTypes() {
        Assert.areEqual(
            Date.newInstance(2026, 9, 15),
            AgentGovQueryBuilder.convertFieldValue('2026-09-15', Schema.DisplayType.DATE)
        );
        Assert.isInstanceOfType(
            AgentGovQueryBuilder.convertFieldValue('2026-09-15T10:00:00.000Z', Schema.DisplayType.DATETIME),
            DateTime.class
        );
        Assert.areEqual(true, AgentGovQueryBuilder.convertFieldValue('true', Schema.DisplayType.BOOLEAN));
        Assert.areEqual(12.5, AgentGovQueryBuilder.convertFieldValue('12.5', Schema.DisplayType.CURRENCY));
        Assert.areEqual(7, AgentGovQueryBuilder.convertFieldValue('7', Schema.DisplayType.INTEGER));
        Assert.areEqual('text', AgentGovQueryBuilder.convertFieldValue('text', Schema.DisplayType.STRING));
        Assert.isNull(AgentGovQueryBuilder.convertFieldValue(null, Schema.DisplayType.STRING));
        try {
            AgentGovQueryBuilder.convertFieldValue('not-a-date', Schema.DisplayType.DATE);
            Assert.fail('An unconvertible value must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
        }
    }

    @IsTest
    static void dateConditionsAreBoundWithConvertedTypes() {
        Map<String, Object> request = body('Account', new List<String>{ 'Id' });
        request.put(
            'where',
            new List<Object>{
                new Map<String, Object>{ 'field' => 'CreatedDate', 'op' => '>=', 'value' => '2026-01-01T00:00:00.000Z' }
            }
        );

        AgentGovQueryBuilder.BuiltQuery built = build(request, null);

        Assert.isInstanceOfType(built.binds.get('b0'), DateTime.class);
        Assert.areEqual(0, AgentGovQueryBuilder.execute(built).size());
    }

    @IsTest
    static void typedListsAreBuiltForEveryBoundFieldType() {
        // IN clauses must bind a list of the field's own type; a generic object list is
        // rejected by the query engine.
        Assert.isInstanceOfType(
            AgentGovQueryBuilder.typedList(new List<Object>{ 'a', 'b' }, Schema.DisplayType.STRING),
            List<String>.class
        );
        Assert.isInstanceOfType(
            AgentGovQueryBuilder.typedList(new List<Object>{ '2026-09-15' }, Schema.DisplayType.DATE),
            List<Date>.class
        );
        Assert.isInstanceOfType(
            AgentGovQueryBuilder.typedList(new List<Object>{ '2026-09-15T10:00:00.000Z' }, Schema.DisplayType.DATETIME),
            List<DateTime>.class
        );
        Assert.isInstanceOfType(
            AgentGovQueryBuilder.typedList(new List<Object>{ 'true', 'false' }, Schema.DisplayType.BOOLEAN),
            List<Boolean>.class
        );
        Assert.isInstanceOfType(
            AgentGovQueryBuilder.typedList(new List<Object>{ '1.5' }, Schema.DisplayType.CURRENCY),
            List<Decimal>.class
        );
        Assert.isInstanceOfType(
            AgentGovQueryBuilder.typedList(new List<Object>{ UserInfo.getUserId() }, Schema.DisplayType.ID),
            List<Id>.class
        );
        Assert.areEqual(
            1,
            ((List<String>) AgentGovQueryBuilder.typedList(new List<Object>{ null }, Schema.DisplayType.STRING)).size()
        );
    }

    @IsTest
    static void notInAndAscendingOrderCompile() {
        Map<String, Object> request = body('Account', new List<String>{ 'Id' });
        request.put(
            'where',
            new List<Object>{
                new Map<String, Object>{
                    'field' => 'Industry',
                    'op' => 'NOT IN',
                    'value' => new List<Object>{ 'Energy' }
                }
            }
        );
        request.put('orderBy', new Map<String, Object>{ 'field' => 'Name' });

        AgentGovQueryBuilder.BuiltQuery built = build(request, null);

        Assert.isTrue(built.soql.contains('Industry NOT IN :b0'), built.soql);
        Assert.isTrue(built.soql.contains('ORDER BY Name ASC'), 'Ascending is the default direction');
    }

    @IsTest
    static void executeSurfacesAccessFailuresAsAccessDenied() {
        AgentGovTestDataFactory.createSettings();
        User restricted = AgentGovTestDataFactory.createRestrictedUser(new List<String>());
        AgentGovQueryBuilder.BuiltQuery built = build(body('AgentGov_Registration__c', new List<String>{ 'Id' }), null);

        System.runAs(restricted) {
            try {
                AgentGovQueryBuilder.execute(built);
                Assert.fail('A user without access must be refused');
            } catch (AgentGovException e) {
                Assert.areEqual(AgentGovException.ErrorCode.ACCESS_DENIED, e.getErrorCode());
                // The refusal is worded by the framework and names what was refused, never the
                // platform's own message, which describes internals.
                Assert.isTrue(
                    e.getMessage().contains('not permitted to read AgentGov_Registration__c'),
                    e.getMessage()
                );
                Assert.isFalse(
                    e.getMessage().containsIgnoreCase('sObject type') ||
                        e.getMessage().containsIgnoreCase('not supported') ||
                        e.getMessage().containsIgnoreCase('exception'),
                    'Platform text leaked: ' + e.getMessage()
                );
            }
        }
    }

    @IsTest
    static void blankAndMalformedFieldNamesAreRejected() {
        Map<String, Schema.SObjectField> fields = Account.SObjectType.getDescribe().fields.getMap();
        for (String candidate : new List<String>{ null, '', ' ', '1Field', 'Name;DROP' }) {
            try {
                AgentGovQueryBuilder.resolveField(candidate, fields, 'Account');
                Assert.fail('Must be rejected: ' + candidate);
            } catch (AgentGovException e) {
                Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
            }
        }
        Assert.areEqual(
            'Name',
            AgentGovQueryBuilder.resolveField('name', fields, 'Account'),
            'Matching is case-insensitive'
        );
    }

    @IsTest
    static void conditionsAndSortsTheDatabaseCannotRunAreRefusedWhileCompiling() {
        // Account.Description is a long text area: it can be neither filtered nor sorted.
        expectInvalidWith(
            withCondition(body('Account', new List<String>{ 'Id' }), 'Description', '=', 'x'),
            String.format(AgentGovConstants.ERR_FIELD_NOT_FILTERABLE, new List<String>{ 'Account', 'Description' })
        );

        Map<String, Object> sorted = body('Account', new List<String>{ 'Id' });
        sorted.put('orderBy', new Map<String, Object>{ 'field' => 'description' });
        expectInvalidWith(
            sorted,
            String.format(AgentGovConstants.ERR_FIELD_NOT_SORTABLE, new List<String>{ 'Account', 'Description' })
        );

        expectInvalidWith(
            withCondition(body('Account', new List<String>{ 'Id' }), 'NumberOfEmployees', 'LIKE', '1%'),
            String.format(AgentGovConstants.ERR_LIKE_NOT_TEXT, new List<String>{ 'Account', 'NumberOfEmployees' })
        );
        expectInvalidWith(
            withCondition(body('Account', new List<String>{ 'Id' }), 'OwnerId', 'like', '005%'),
            String.format(AgentGovConstants.ERR_LIKE_NOT_TEXT, new List<String>{ 'Account', 'OwnerId' })
        );

        AgentGovQueryBuilder.BuiltQuery picklistLike = build(
            withCondition(body('Account', new List<String>{ 'Id' }), 'Industry', 'LIKE', 'Ener%'),
            null
        );
        Assert.areEqual(0, AgentGovQueryBuilder.execute(picklistLike).size(), 'LIKE on a picklist runs');
    }

    @IsTest
    static void valuesForTextFieldsAreUsedAsText() {
        Assert.areEqual('12345', AgentGovQueryBuilder.convertFieldValue(12345, Schema.DisplayType.STRING));
        Assert.areEqual('true', AgentGovQueryBuilder.convertFieldValue(true, Schema.DisplayType.PICKLIST));
        Assert.areEqual('12.5', AgentGovQueryBuilder.convertFieldValue(12.5, Schema.DisplayType.PHONE));
        Assert.areEqual(
            new List<String>{ '1', 'two' },
            (List<String>) AgentGovQueryBuilder.typedList(new List<Object>{ 1, 'two' }, Schema.DisplayType.EMAIL)
        );

        insert new Account(Name = '12345');
        AgentGovQueryBuilder.BuiltQuery built = build(
            withCondition(body('Account', new List<String>{ 'Id', 'Name' }), 'Name', '=', 12345),
            null
        );
        Assert.areEqual('12345', built.binds.get('b0'), 'The number is bound as text');
        Assert.areEqual(1, AgentGovQueryBuilder.execute(built).size(), 'A number matches the text it is written as');
    }

    @IsTest
    static void aJsonObjectOrListIsNeverAFieldValue() {
        for (
            Schema.DisplayType fieldType : new List<Schema.DisplayType>{
                Schema.DisplayType.STRING,
                Schema.DisplayType.BOOLEAN,
                Schema.DisplayType.DATE,
                Schema.DisplayType.ID
            }
        ) {
            for (Object value : new List<Object>{ new Map<String, Object>{ 'a' => 1 }, new List<Object>{ 'a' } }) {
                try {
                    AgentGovQueryBuilder.convertFieldValue(value, fieldType);
                    Assert.fail('Must be rejected for a ' + fieldType + ' field: ' + JSON.serialize(value));
                } catch (AgentGovException e) {
                    Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
                    Assert.areEqual(
                        String.format(
                            AgentGovConstants.ERR_VALUE_NOT_SCALAR,
                            new List<String>{ String.valueOf(fieldType) }
                        ),
                        e.getMessage()
                    );
                }
            }
        }
        expectInvalidWith(
            withCondition(
                body('Account', new List<String>{ 'Id' }),
                'Name',
                'IN',
                new List<Object>{ new Map<String, Object>{ 'nested' => true } }
            ),
            String.format(AgentGovConstants.ERR_VALUE_NOT_SCALAR, new List<String>{ 'STRING' })
        );
    }

    @IsTest
    static void timeValuesAreConverted() {
        Assert.areEqual(
            Time.newInstance(10, 30, 0, 0),
            AgentGovQueryBuilder.convertFieldValue('10:30:00.000Z', Schema.DisplayType.TIME)
        );
        Assert.isInstanceOfType(
            AgentGovQueryBuilder.typedList(new List<Object>{ '08:00:00.000Z' }, Schema.DisplayType.TIME),
            List<Time>.class
        );
        try {
            AgentGovQueryBuilder.convertFieldValue('half past ten', Schema.DisplayType.TIME);
            Assert.fail('A value that is not a time must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
        }
        // BusinessHours.MondayStartTime is a standard Time field every org has.
        AgentGovQueryBuilder.BuiltQuery built = build(
            withCondition(body('BusinessHours', new List<String>{ 'Id' }), 'MondayStartTime', '>=', '00:00:00.000Z'),
            null
        );
        Assert.isInstanceOfType(built.binds.get('b0'), Time.class);
        AgentGovQueryBuilder.execute(built);
    }

    @IsTest
    static void aRecordCapLowersTheLimitButNeverRaisesIt() {
        Map<String, Object> request = body('Account', new List<String>{ 'Id' });
        request.put('limit', 500);
        AgentGovQueryBuilder.BuiltQuery built = build(request, null);
        Assert.areEqual(500, built.effectiveLimit);
        Assert.isTrue(built.soql.endsWith(' LIMIT 500'), built.soql);

        AgentGovQueryBuilder.applyRecordCap(built, 50);
        Assert.areEqual(50, built.effectiveLimit);
        Assert.areEqual('SELECT Id FROM Account LIMIT 50', built.soql);

        AgentGovQueryBuilder.applyRecordCap(built, 100);
        AgentGovQueryBuilder.applyRecordCap(built, null);
        Assert.areEqual(50, built.effectiveLimit, 'A later, larger cap does not raise the limit');
        Assert.areEqual('SELECT Id FROM Account LIMIT 50', built.soql);
        Assert.areEqual(0, AgentGovQueryBuilder.execute(built).size());
    }

    @IsTest
    static void assertReadableRefusesWhatTheUserCannotRead() {
        AgentGovTestDataFactory.createSettings();
        User noAccess = AgentGovTestDataFactory.createRestrictedUser(new List<String>());
        // AgentGov_User reads registrations but not the stored key hash.
        User reader = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_User' });
        AgentGovQueryBuilder.BuiltQuery selectsHash = build(
            body('AgentGov_Registration__c', new List<String>{ 'Id', 'Agent_Name__c', 'API_Key_Hash__c' }),
            null
        );
        AgentGovQueryBuilder.BuiltQuery filtersOnHash = build(
            withCondition(body('AgentGov_Registration__c', new List<String>{ 'Id' }), 'API_Key_Hash__c', '=', 'x'),
            null
        );
        AgentGovQueryBuilder.BuiltQuery readable = build(
            body('AgentGov_Registration__c', new List<String>{ 'Id', 'Agent_Name__c' }),
            null
        );

        System.runAs(noAccess) {
            expectAccessDenied(
                readable,
                String.format(
                    AgentGovConstants.ERR_OBJECT_NOT_ACCESSIBLE,
                    new List<String>{ 'read', 'AgentGov_Registration__c' }
                )
            );
        }
        System.runAs(reader) {
            AgentGovQueryBuilder.assertReadable(readable);
            String hashRefused = String.format(
                AgentGovConstants.ERR_FIELDS_NOT_ACCESSIBLE,
                new List<String>{ 'read', 'AgentGov_Registration__c', 'API_Key_Hash__c' }
            );
            expectAccessDenied(selectsHash, hashRefused);
            expectAccessDenied(filtersOnHash, hashRefused);
        }
    }

    private static void expectAccessDenied(AgentGovQueryBuilder.BuiltQuery built, String expectedMessage) {
        try {
            AgentGovQueryBuilder.assertReadable(built);
            Assert.fail('Must be refused: ' + expectedMessage);
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.ACCESS_DENIED, e.getErrorCode());
            Assert.areEqual(expectedMessage, e.getMessage());
        }
    }

    @IsTest
    static void aQueryTheDatabaseRefusesForAnotherReasonIsInvalidInput() {
        // Boolean fields take only = and !=, which the builder leaves to the database.
        AgentGovQueryBuilder.BuiltQuery built = build(
            withCondition(body('Account', new List<String>{ 'Id' }), 'IsDeleted', '<', true),
            null
        );
        try {
            AgentGovQueryBuilder.execute(built);
            Assert.fail('The database refuses the query');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
            Assert.areEqual(
                String.format(AgentGovConstants.ERR_QUERY_NOT_RUN, new List<String>{ 'Account' }),
                e.getMessage()
            );
        }
    }

    @IsTest
    static void anObjectNameThatIsNotTextIsRefused() {
        try {
            AgentGovQueryBuilder.parse(
                new Map<String, Object>{ 'objectName' => 42, 'fields' => new List<String>{ 'Id' } }
            );
            Assert.fail('A number is not an object name');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
            Assert.areEqual(
                String.format(AgentGovConstants.ERR_NOT_A_STRING, new List<String>{ 'objectName' }),
                e.getMessage()
            );
        }
    }
}
