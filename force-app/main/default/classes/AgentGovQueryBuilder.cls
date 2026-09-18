/**
 * @description Compiles the structured query accepted by the proxy /query endpoint into SOQL.
 *
 *              Agents do not send SOQL text. They send an object name, a list of fields, an
 *              optional list of field/operator/value conditions, an optional sort, and a
 *              limit. Every field must be a plain field API name that exists on the object,
 *              so relationship traversals and subqueries cannot be expressed at all; every
 *              operator comes from a fixed list; and every value is passed as a bind
 *              variable rather than concatenated. The resulting SOQL is executed in user
 *              mode, so the calling user's object, field, and sharing access apply.
 *
 *              Security posture: inherited sharing. The query itself always runs with
 *              AccessLevel.USER_MODE regardless of the caller's sharing context.
 */
public inherited sharing class AgentGovQueryBuilder {
    private static final Pattern FIELD_NAME_PATTERN = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*$');
    private static final String DIRECTION_ASC = 'ASC';
    private static final String DIRECTION_DESC = 'DESC';

    /** @description A single filter condition. */
    public class Condition {
        public String field;
        public String operator;
        public Object value;
    }

    /** @description Sort specification. */
    public class OrderBy {
        public String field;
        public String direction;
    }

    /** @description The parsed and validated request. */
    public class QueryRequest {
        public String objectName;
        public List<String> fields = new List<String>();
        public List<Condition> conditions = new List<Condition>();
        public OrderBy orderBy;
        public Integer limitCount;
    }

    /** @description The compiled query, ready to execute. */
    public class BuiltQuery {
        public String soql;
        public Map<String, Object> binds = new Map<String, Object>();
        public Set<String> referencedFields = new Set<String>();
        public Schema.DescribeSObjectResult describe;
        public Integer effectiveLimit;
    }

    /**
     * @description Parses the JSON body of a /query request.
     * @param body Parsed JSON body
     * @return The structured request
     * @throws AgentGovException INVALID_INPUT for a missing object, empty field list, or malformed clauses
     */
    public static QueryRequest parse(Map<String, Object> body) {
        if (body.containsKey('query')) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                AgentGovConstants.ERR_RAW_SOQL_UNSUPPORTED
            );
        }
        QueryRequest request = new QueryRequest();
        request.objectName = (String) body.get('objectName');
        if (String.isBlank(request.objectName)) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                AgentGovConstants.ERR_INVALID_OBJECT_NAME
            );
        }

        Object rawFields = body.get('fields');
        if (!(rawFields instanceof List<Object>) || ((List<Object>) rawFields).isEmpty()) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NO_FIELDS);
        }
        for (Object field : (List<Object>) rawFields) {
            request.fields.add(String.valueOf(field));
        }

        Object rawWhere = body.get('where');
        if (rawWhere != null) {
            if (!(rawWhere instanceof List<Object>)) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INVALID_INPUT,
                    'where must be a list of {field, op, value} objects.'
                );
            }
            for (Object rawCondition : (List<Object>) rawWhere) {
                if (!(rawCondition instanceof Map<String, Object>)) {
                    throw new AgentGovException(
                        AgentGovException.ErrorCode.INVALID_INPUT,
                        'Each where entry must be an object with field, op, and value.'
                    );
                }
                Map<String, Object> conditionMap = (Map<String, Object>) rawCondition;
                Condition condition = new Condition();
                condition.field = String.valueOf(conditionMap.get('field'));
                condition.operator = conditionMap.get('op') == null
                    ? null
                    : String.valueOf(conditionMap.get('op')).trim().toUpperCase();
                condition.value = conditionMap.get('value');
                request.conditions.add(condition);
            }
        }

        Object rawOrderBy = body.get('orderBy');
        if (rawOrderBy != null) {
            if (!(rawOrderBy instanceof Map<String, Object>)) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INVALID_INPUT,
                    'orderBy must be an object with field and direction.'
                );
            }
            Map<String, Object> orderMap = (Map<String, Object>) rawOrderBy;
            request.orderBy = new OrderBy();
            request.orderBy.field = String.valueOf(orderMap.get('field'));
            request.orderBy.direction = orderMap.get('direction') == null
                ? DIRECTION_ASC
                : String.valueOf(orderMap.get('direction')).trim().toUpperCase();
            // Validated, not coerced. Silently turning a typo into ASC returned a different
            // ordering than the caller asked for, unlike every other token the builder checks.
            if (request.orderBy.direction != DIRECTION_ASC && request.orderBy.direction != DIRECTION_DESC) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INVALID_INPUT,
                    'orderBy.direction must be ASC or DESC.'
                );
            }
        }

        if (body.get('limit') != null) {
            try {
                request.limitCount = Integer.valueOf(String.valueOf(body.get('limit')));
            } catch (Exception e) {
                throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, 'limit must be an integer.');
            }
            if (request.limitCount < 1) {
                throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, 'limit must be at least 1.');
            }
        }
        return request;
    }

    /**
     * @description Describes an object by API name.
     * @param objectName Object API name as supplied by the caller
     * @return The describe result
     * @throws AgentGovException INVALID_INPUT when the object does not exist or is not accessible
     */
    public static Schema.DescribeSObjectResult describe(String objectName) {
        if (String.isBlank(objectName) || !FIELD_NAME_PATTERN.matcher(objectName).matches()) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                AgentGovConstants.ERR_UNKNOWN_OBJECT + objectName
            );
        }
        try {
            // DEFERRED so the describe does not eagerly load every child relationship. The
            // builder needs the field map and the name, nothing else, and this runs on every
            // proxied request.
            return Schema.describeSObjects(new List<String>{ objectName }, SObjectDescribeOptions.DEFERRED)[0];
        } catch (Exception e) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                AgentGovConstants.ERR_UNKNOWN_OBJECT + objectName
            );
        }
    }

    /**
     * @description Compiles a validated request into SOQL with bind variables.
     * @param request The parsed request
     * @param describe The describe result for request.objectName
     * @param maxRecords Policy cap on rows, or null when the policy sets none
     * @return The compiled query
     * @throws AgentGovException INVALID_INPUT for unknown fields, unsupported operators, or bad values
     */
    public static BuiltQuery build(QueryRequest request, Schema.DescribeSObjectResult describe, Integer maxRecords) {
        Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();
        BuiltQuery built = new BuiltQuery();
        built.describe = describe;

        List<String> selectFields = new List<String>();
        for (String field : request.fields) {
            String apiName = resolveField(field, fieldMap, describe.getName());
            if (!built.referencedFields.contains(apiName)) {
                built.referencedFields.add(apiName);
                selectFields.add(apiName);
            }
        }

        List<String> whereClauses = new List<String>();
        Integer bindIndex = 0;
        for (Condition condition : request.conditions) {
            String apiName = resolveField(condition.field, fieldMap, describe.getName());
            built.referencedFields.add(apiName);
            if (condition.operator == null || !AgentGovConstants.QUERY_OPERATORS.contains(condition.operator)) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INVALID_INPUT,
                    AgentGovConstants.ERR_INVALID_OPERATOR + String.valueOf(condition.operator)
                );
            }
            Schema.DescribeFieldResult fieldDescribe = fieldMap.get(apiName.toLowerCase()).getDescribe();
            String bindName = 'b' + bindIndex++;
            if (condition.operator == 'IN' || condition.operator == 'NOT IN') {
                if (!(condition.value instanceof List<Object>)) {
                    throw new AgentGovException(
                        AgentGovException.ErrorCode.INVALID_INPUT,
                        AgentGovConstants.ERR_INVALID_IN_VALUE + apiName
                    );
                }
                built.binds.put(bindName, typedList((List<Object>) condition.value, fieldDescribe.getType()));
                whereClauses.add(apiName + ' ' + condition.operator + ' :' + bindName);
            } else {
                built.binds.put(bindName, convertFieldValue(condition.value, fieldDescribe.getType()));
                whereClauses.add(apiName + ' ' + condition.operator + ' :' + bindName);
            }
        }

        String orderClause = '';
        if (request.orderBy != null) {
            String apiName = resolveField(request.orderBy.field, fieldMap, describe.getName());
            built.referencedFields.add(apiName);
            String direction = request.orderBy.direction == DIRECTION_DESC ? DIRECTION_DESC : DIRECTION_ASC;
            orderClause = ' ORDER BY ' + apiName + ' ' + direction;
        }

        Integer requested = request.limitCount == null ? AgentGovConstants.DEFAULT_QUERY_LIMIT : request.limitCount;
        Integer cap = maxRecords == null
            ? AgentGovConstants.MAX_QUERY_LIMIT
            : Math.min(maxRecords, AgentGovConstants.MAX_QUERY_LIMIT);
        built.effectiveLimit = Math.min(requested, cap);

        built.soql =
            'SELECT ' +
            String.join(selectFields, ', ') +
            ' FROM ' +
            describe.getName() +
            (whereClauses.isEmpty() ? '' : ' WHERE ' + String.join(whereClauses, ' AND ')) +
            orderClause +
            ' LIMIT ' +
            built.effectiveLimit;
        return built;
    }

    /**
     * @description Executes a compiled query in user mode.
     * @param built The compiled query
     * @return Matching records
     * @throws AgentGovException ACCESS_DENIED when the calling user cannot read the object or a field
     */
    public static List<SObject> execute(BuiltQuery built) {
        try {
            return Database.queryWithBinds(built.soql, built.binds, AccessLevel.USER_MODE);
        } catch (QueryException e) {
            // Reported as an access failure deliberately. The object and every field name are
            // validated against describe before this point, so a query that still fails in
            // USER_MODE has been refused for access. Classifying by message text was tried and
            // reverted: user mode reports an object denial as "sObject type X is not
            // supported", which reads like malformed input and is not safely distinguishable.
            throw new AgentGovException(
                AgentGovException.ErrorCode.ACCESS_DENIED,
                String.format(
                    AgentGovConstants.ERR_FIELDS_NOT_ACCESSIBLE,
                    new List<String>{ 'read', built.describe.getName(), e.getMessage() }
                )
            );
        }
    }

    /**
     * @description Validates a caller-supplied field name and returns its canonical API name.
     * @param field Field name as supplied
     * @param fieldMap Field map of the target object
     * @param objectName Object API name, for error messages
     * @return The field's API name as defined on the object
     * @throws AgentGovException INVALID_INPUT when the name is malformed or unknown
     */
    public static String resolveField(String field, Map<String, Schema.SObjectField> fieldMap, String objectName) {
        if (String.isBlank(field) || !FIELD_NAME_PATTERN.matcher(field).matches()) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                String.format(AgentGovConstants.ERR_INVALID_FIELD_NAME, new List<String>{ String.valueOf(field) })
            );
        }
        Schema.SObjectField sObjectField = fieldMap.get(field.toLowerCase());
        if (sObjectField == null) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                String.format(AgentGovConstants.ERR_UNKNOWN_FIELD, new List<String>{ objectName, field })
            );
        }
        return sObjectField.getDescribe().getName();
    }

    /**
     * @description Converts a JSON list into a list of the Apex type a field expects. Bind
     *              variables for IN clauses must be typed lists; a generic object list is rejected
     *              by the query engine.
     * @param items Values as deserialized from JSON
     * @param fieldType The target field's display type
     * @return A typed list suitable for binding
     */
    public static Object typedList(List<Object> items, Schema.DisplayType fieldType) {
        switch on fieldType {
            when DATETIME {
                List<DateTime> values = new List<DateTime>();
                for (Object item : items) {
                    values.add((DateTime) convertFieldValue(item, fieldType));
                }
                return values;
            }
            when DATE {
                List<Date> values = new List<Date>();
                for (Object item : items) {
                    values.add((Date) convertFieldValue(item, fieldType));
                }
                return values;
            }
            when BOOLEAN {
                List<Boolean> values = new List<Boolean>();
                for (Object item : items) {
                    values.add((Boolean) convertFieldValue(item, fieldType));
                }
                return values;
            }
            when DOUBLE, CURRENCY, PERCENT, INTEGER {
                List<Decimal> values = new List<Decimal>();
                for (Object item : items) {
                    Object converted = convertFieldValue(item, fieldType);
                    values.add(converted == null ? null : Decimal.valueOf(String.valueOf(converted)));
                }
                return values;
            }
            when ID, REFERENCE {
                List<Id> values = new List<Id>();
                for (Object item : items) {
                    values.add((Id) convertFieldValue(item, fieldType));
                }
                return values;
            }
            when else {
                List<String> values = new List<String>();
                for (Object item : items) {
                    values.add(item == null ? null : String.valueOf(item));
                }
                return values;
            }
        }
    }

    /**
     * @description Converts a JSON value into the Apex type a field expects, so it can be bound
     *              in a query or assigned to a record.
     * @param rawValue Value as deserialized from JSON
     * @param fieldType The target field's display type
     * @return The converted value
     * @throws AgentGovException INVALID_INPUT when the value cannot be converted
     */
    public static Object convertFieldValue(Object rawValue, Schema.DisplayType fieldType) {
        if (rawValue == null) {
            return null;
        }
        String stringValue = String.valueOf(rawValue);
        try {
            switch on fieldType {
                when DATETIME {
                    return rawValue instanceof DateTime
                        ? (DateTime) rawValue
                        : (DateTime) JSON.deserialize('"' + stringValue + '"', DateTime.class);
                }
                when DATE {
                    return rawValue instanceof Date ? (Date) rawValue : Date.valueOf(stringValue);
                }
                when BOOLEAN {
                    return rawValue instanceof Boolean ? (Boolean) rawValue : Boolean.valueOf(stringValue);
                }
                when DOUBLE, CURRENCY, PERCENT {
                    return rawValue instanceof Decimal ? (Decimal) rawValue : Decimal.valueOf(stringValue);
                }
                when INTEGER {
                    return rawValue instanceof Integer ? (Integer) rawValue : Integer.valueOf(stringValue);
                }
                when ID, REFERENCE {
                    return Id.valueOf(stringValue);
                }
                when else {
                    return rawValue;
                }
            }
        } catch (Exception e) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                'Value "' + stringValue + '" is not valid for a ' + fieldType + ' field.'
            );
        }
    }
}
