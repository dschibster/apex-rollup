/**
 * Big caveat here - this class can only be used with lookup relationships. The larger Rollup framework
 * accepts and even welcomes text-based keys being used, but here we accept that text-based keys
 * are likely niche, anyway, and that people looking to make use of a grandchild -> grandparent (or greater!)
 * rollup are likely operating using lookups anyway
 */
public without sharing class RollupRelationshipFieldFinder {
  private final Rollup__mdt metadata;
  private final List<String> originalParts;
  private final Traversal traversal;
  private final SObjectType ultimateParent;
  private final RollupControl__mdt rollupControl;
  private final Map<Id, SObject> oldRecords;
  private final Set<String> uniqueFinalFieldNames;
  private final Map<String, List<String>> relationshipNameToWhereClauses;

  private String calcItemWhereClause;
  private List<SObject> recommencementRecords;
  private List<SObject> records;
  private List<String> relationshipParts;
  private Boolean isFirstRun = true;
  private String currentRelationshipName;

  private static final Integer MAX_FOREIGN_KEY_RELATIONSHIP_HOPS = 5;

  public RollupRelationshipFieldFinder(
    RollupControl__mdt rollupControl,
    Rollup__mdt rollupMetadata,
    Set<String> uniqueFinalFieldNames,
    SObjectType ultimateParent,
    Map<Id, SObject> oldRecords
  ) {
    this.traversal = new Traversal(this);
    this.metadata = rollupMetadata;
    this.relationshipParts = this.getRelationshipParts();
    this.rollupControl = rollupControl;
    this.ultimateParent = ultimateParent;
    this.oldRecords = oldRecords;
    this.uniqueFinalFieldNames = uniqueFinalFieldNames;
    this.calcItemWhereClause = rollupMetadata.CalcItemWhereClause__c;

    this.originalParts = new List<String>(this.relationshipParts);
    this.relationshipNameToWhereClauses = new Map<String, List<String>>();
  }

  private class CombinedHierarchy {
    private List<Id> oldHierarchy;
    private List<Id> currentHierarchy;
  }

  public class Traversal {
    private Boolean isFinished = false;
    private Boolean isAbortedEarly = false;

    private final Map<Id, SObject> finalParentIdToRecords = new Map<Id, SObject>();
    private final Map<Id, SObject> lookupIdToFinalRecords = new Map<Id, SObject>();
    private Map<Id, List<Id>> lookupIdMap = new Map<Id, List<Id>>();
    private final Map<Id, List<Id>> hierarchy = new Map<Id, List<Id>>();
    private final RollupRelationshipFieldFinder finder;

    private Traversal(RollupRelationshipFieldFinder finder) {
      this.finder = finder;
    }

    public Boolean getIsFinished() {
      return this.isFinished || this.isAbortedEarly;
    }

    public SObject retrieveParent(Id descendantId) {
      return this.lookupIdToFinalRecords.get(descendantId);
    }

    public List<SObject> getAllParents() {
      if (this.isAbortedEarly) {
        return new List<SObject>();
      }
      // not ideal, but because multiple parents can be tied to different descendants ...
      return new List<SObject>(new Set<SObject>(this.lookupIdToFinalRecords.values()));
    }

    public void recommence() {
      this.finder.getParents(this.finder.recommencementRecords);
    }

    public Map<String, Rollup.CalcItemBag> getParentLookupToRecords() {
      Map<String, Rollup.CalcItemBag> parentToLookupRecords = new Map<String, Rollup.CalcItemBag>();
      if (this.isAbortedEarly) {
        return parentToLookupRecords;
      }
      for (SObject record : this.finder.records) {
        SObject parentRecord = this.retrieveParent(record.Id);
        if (parentRecord == null) {
          continue;
        }
        if (parentToLookupRecords.containsKey(parentRecord.Id)) {
          parentToLookupRecords.get(parentRecord.Id).add(record);
        } else {
          parentToLookupRecords.put(parentRecord.Id, new Rollup.CalcItemBag(new List<SObject>{ record }));
        }
      }
      return parentToLookupRecords;
    }

    public Boolean isUltimatelyReparented(SObject record, String relationshipFieldName) {
      Id currentLookupId = (Id) record.get(relationshipFieldName);
      Id oldLookupId = (Id) (this.finder.oldRecords.containsKey(record.Id)
        ? this.finder.oldRecords.get(record.Id).get(relationshipFieldName)
        : currentLookupId);
      if (currentLookupId == oldLookupId) {
        return false;
      } else if (currentLookupId == null || oldLookupId == null) {
        // this is pretty cut and dry. if we are moving from having a lookup to not having one, or vice versa, it's a reparenting
        return true;
      }
      CombinedHierarchy combinedHierarchy = this.getHierarchy(record, relationshipFieldName);
      if (combinedHierarchy.currentHierarchy?.size() > 0 && combinedHierarchy.oldHierarchy?.size() > 0) {
        // the last Ids present in the chain have to match, otherwise it's a reparenting
        return combinedHierarchy.currentHierarchy[combinedHierarchy.currentHierarchy.size() - 1] !=
          combinedHierarchy.oldHierarchy[combinedHierarchy.oldHierarchy.size() - 1];
      } else {
        // if there was only one hop, we can just compare the Ids. This comparison has to be last
        // because it's possible (as explained below, where the hierarchy is created)
        // that only the intermediate lookup fields have changed, and not the ultimate
        // parent (which is what gets checked above).
        // only if that isn't the case can we do the simple comparison below
        return currentLookupId != oldLookupId;
      }
    }

    public Id getOldLookupId(SObject record, String relationshipFieldName) {
      CombinedHierarchy combinedHierarchy = this.getHierarchy(record, relationshipFieldName);
      return combinedHierarchy.oldHierarchy?.isEmpty() == false ? combinedHierarchy.currentHierarchy[0] : null;
    }

    private CombinedHierarchy getHierarchy(SObject record, String relationshipFieldName) {
      Id currentLookupId = (Id) record.get(relationshipFieldName);
      Id oldLookupId = (Id) (this.finder.oldRecords.containsKey(record.Id)
        ? this.finder.oldRecords.get(record.Id).get(relationshipFieldName)
        : currentLookupId);
      CombinedHierarchy combinedHierarchy = new CombinedHierarchy();
      combinedHierarchy.currentHierarchy = this.hierarchy.get(currentLookupId);
      combinedHierarchy.oldHierarchy = this.hierarchy.get(oldLookupId);
      return combinedHierarchy;
    }
  }

  public Traversal getParents(List<SObject> records) {
    if (records.isEmpty() || (this.relationshipParts.isEmpty() && this.metadata.RollupToUltimateParent__c == false)) {
      this.traversal.isFinished = true;
      return this.traversal;
    } else if (Rollup.hasExceededCurrentRollupLimits(this.rollupControl) && this.isFirstRun == false) {
      // we pop fields off of the list while recursively iterating
      // which means we need to re-add the last field used if we are stopping
      // due to limits
      this.relationshipParts.add(0, this.currentRelationshipName);
      return this.traversal;
    }

    // even before the recursion begins, the List won't be strongly typed
    SObjectType baseSObjectType = records[0].getSObjectType();

    // if we're only going one relationship up, we need to validate that the
    // parent's relationship name doesn't differ from its SObject name
    if (this.relationshipParts.size() == 1 && this.isFirstRun) {
      SObjectField parentField = this.getField(baseSObjectType.getDescribe().fields.getMap(), this.ultimateParent.getDescribe().getName());
      this.relationshipParts.add(0, parentField.getDescribe().getName());
    }

    if (baseSObjectType == this.ultimateParent && this.isFinishedWithHierarchyTraversal(records)) {
      this.retrieveAdditionalHierarchyRecords(records, this.traversal.hierarchy.keySet());
      this.prepFinishedObject(records);
      return this.traversal;
    } else {
      return this.recurseThroughObjectChain(records, baseSObjectType);
    }
  }

  private List<String> getRelationshipParts() {
    List<String> localParts = String.isNotBlank(this.metadata.GrandparentRelationshipFieldPath__c)
      ? this.metadata.GrandparentRelationshipFieldPath__c.split('\\.')
      : new List<String>();

    if (localParts.isEmpty() && this.metadata.RollupToUltimateParent__c) {
      String relationshipName = this.replaceLastInString(this.metadata.LookupFieldOnCalcItem__c, '__c', '__r');
      relationshipName = this.replaceLastInString(relationshipName, 'Id', '');
      localParts.add(relationshipName);
      localParts.add(this.metadata.UltimateParentLookup__c);
    }

    return localParts;
  }

  private String replaceLastInString(String target, String occurrence, String replacement) {
    Integer endingIndex = target.lastIndexOf(occurrence);
    return endingIndex > -1 ? target.removeEnd(occurrence) + replacement : target;
  }

  private SObjectField getField(Map<String, SObjectField> fieldMap, String relationshipPart) {
    for (String key : fieldMap.keySet()) {
      SObjectField field = fieldMap.get(key);
      if (field.getDescribe().getRelationshipName() == relationshipPart) {
        return field;
      } else if (field.getDescribe().getName() == relationshipPart) {
        return field;
      } else if (field.getDescribe().isNamePointing()) {
        for (SObjectType potentialMatch : field.getDescribe().getReferenceTo()) {
          if (potentialMatch.getDescribe().getName() == relationshipPart) {
            return field;
          }
        }
      }
    }
    // effectively a throw; if there's no match, nothing else will work
    return null;
  }

  private Set<Id> getDescendantIds(Id lookupId, Set<Id> descendantIds) {
    Boolean hasMatch = this.traversal.lookupIdMap.containsKey(lookupId);
    if (hasMatch) {
      List<Id> extraIds = this.traversal.lookupIdMap.get(lookupId);
      for (Id descendantId : extraIds) {
        descendantIds.addAll(this.getDescendantIds(descendantId, descendantIds));
      }
      return descendantIds;
    }
    descendantIds.add(lookupId);
    return descendantIds;
  }

  private void prepFinishedObject(List<SObject> records) {
    this.traversal.isFinished = true;
    this.populateFinalRecordsMapping(records);
    this.relationshipParts = this.originalParts; // reset to initial state in case outer method is re-called
    this.traversal.lookupIdMap.clear(); // try to spare the heap
  }

  private Boolean isFinishedWithHierarchyTraversal(List<SObject> records) {
    if (this.metadata.RollupToUltimateParent__c != true) {
      return true;
    }

    Boolean allRecordsAreTopOfHierarchy = true;
    List<SObject> finishedRecords = new List<SObject>();
    for (Integer index = records.size() - 1; index >= 0; index--) {
      SObject record = records[index];
      SObject parentRecord = this.getPotentialUltimateParent(record);

      if (parentRecord.get(this.metadata.UltimateParentLookup__c) == null) {
        finishedRecords.add(parentRecord);
        records.remove(index);
      } else {
        // hot-swap out the record for the last parent record it was possible to retrieve
        records[index] = parentRecord;
        allRecordsAreTopOfHierarchy = false;
      }
    }
    this.populateFinalRecordsMapping(finishedRecords);

    return allRecordsAreTopOfHierarchy;
  }

  private SObject getPotentialUltimateParent(SObject childRecord) {
    Map<String, Schema.SObjectField> fieldMap = childRecord.getSObjectType().getDescribe().fields.getMap();
    this.currentRelationshipName = this.relationshipParts.size() == 1
      ? this.relationshipParts[0]
      : this.currentRelationshipName;
    SObjectField lookupField = this.getField(fieldMap, this.currentRelationshipName);
    String relationshipName = lookupField.getDescribe().getRelationshipName();
    if (childRecord.get(this.metadata.UltimateParentLookup__c) != null && childRecord.getPopulatedFieldsAsMap().containsKey(relationshipName)) {
      SObject intermediateParent = childRecord.getSObject(relationshipName);
      this.trackTraversalIds(childRecord.Id, intermediateParent.Id, lookupField, null);
      return this.getPotentialUltimateParent(intermediateParent);
    }
    return childRecord;
  }

  @SuppressWarnings('PMD.ApexSOQLInjection')
  private Traversal recurseThroughObjectChain(List<SObject> records, SObjectType baseSObjectType) {
    this.populateRelationshipNameToWhereClauses(baseSObjectType);

    // cache the latest records through in case we need to continue later
    this.recommencementRecords = records;
    this.currentRelationshipName = baseSObjectType != this.ultimateParent ? this.relationshipParts.remove(0) : this.metadata.UltimateParentLookup__c;
    Map<String, SObjectField> fieldMap = baseSObjectType.getDescribe().fields.getMap();
    SObjectField field = this.getField(fieldMap, this.currentRelationshipName);

    Set<Id> objIds = new Set<Id>();
    Id firstId;
    for (SObject record : records) {
      Id lookupId = (Id) record.get(field);
      if (firstId == null && String.isNotBlank(lookupId)) {
        firstId = lookupId;
      }
      this.trackTraversalIds(record.Id, lookupId, field, objIds);
    }
    // no matter how far up the chain we are, if we arrive at a point where there are no records, we're done
    if (firstId == null) {
      this.prepFinishedObject(records);
      this.traversal.isAbortedEarly = true;
      return this.traversal;
    }

    String nextFieldToLookup = this.relationshipParts[0].replace('__r', '__c');
    SObjectType nextSObjectType = firstId.getSObjectType();
    Map<String, SObjectField> nextFieldMap = nextSObjectType.getDescribe().fields.getMap();
    SObjectField nextFieldToken = this.getField(nextFieldMap, nextFieldToLookup);

    Set<String> fieldNames = new Set<String>();
    if (nextSObjectType == this.ultimateParent) {
      fieldNames.addAll(this.uniqueFinalFieldNames);
      if (this.metadata.RollupToUltimateParent__c == true) {
        this.populateHierarchicalLookupFields(fieldNames, this.getField(nextFieldMap, this.metadata.UltimateParentLookup__c));
      }
    } else {
      fieldNames.add(nextFieldToken.getDescribe().getName());
    }
    if (fieldNames.contains('Id') == false) {
      fieldNames.add('Id');
    }

    // NB - we only support one route through polymorphic fields such as Task.WhoId and Task.WhatId for this sort of thing
    String query = this.appendAdditionalWhereClauses(
      RollupQueryBuilder.Current.getQuery(nextSObjectType, new List<String>(fieldNames), 'Id', '='),
      currentRelationshipName,
      nextFieldMap
    );

    // recurse through till we get to the top/bottom of the chain
    if (this.isFirstRun) {
      this.records = records;
      this.isFirstRun = false;
    }
    return this.getParents(Database.query(query));
  }

  private void populateRelationshipNameToWhereClauses(Schema.SObjectType sObjectType) {
    if (String.isNotBlank(this.calcItemWhereClause)) {
      RollupEvaluator.WhereFieldEvaluator eval = RollupEvaluator.getWhereEval(this.calcItemWhereClause, sObjectType);
      List<String> whereClauses = eval.getWhereClauses();
      // we have to reconstitute the where clause conditions later, which requires them to be in the right order
      new WhereClauseSorter(this.calcItemWhereClause).sort(whereClauses);
      for (String whereClause : whereClauses) {
        // each where clause should begin with the field name:
        // "AccountId = 'someId'" - so by splitting on the space,
        // we would get the AccountId, for example
        List<String> splitWhereClause = whereClause.split(' ');
        String key;
        if (splitWhereClause.size() > 1) {
          String fieldName = splitWhereClause[0];
          // the filtering has already been done for base fields, so we only need to do relationship ones
          if (fieldName.contains('.')) {
            // the relationship name is the string immediately preceeding the last period
            List<String> relationshipNames = fieldName.split('\\.');
            Integer keyIndex = relationshipNames.size() >= 2 ? relationshipNames.size() - 2 : relationshipNames.size() - 1;
            key = relationshipNames[keyIndex];
          }
        }
        if (key != null) {
          // the +1 is for the period following the key
          String whereClauseForRelation = whereClause.substring(whereClause.indexOf(key) + key.length() + 1);

          if (this.relationshipNameToWhereClauses.containsKey(key)) {
            this.relationshipNameToWhereClauses.get(key).add(whereClauseForRelation);
          } else {
            this.relationshipNameToWhereClauses.put(key, new List<String>{ whereClauseForRelation });
          }
        }
      }
    }
  }

  private String appendAdditionalWhereClauses(String query, String relationshipName, Map<String, SObjectField> fieldMap) {
    // for calc item where clauses, try to append the conditions sensibly
    List<String> whereClauses = this.relationshipNameToWhereClauses.containsKey(relationshipName)
      ? this.relationshipNameToWhereClauses.get(relationshipName)
      : new List<String>();

    String concatDelim = '';
    for (Integer index = 0; index < whereClauses.size(); index++) {
      String whereClause = whereClauses[index];
      // this is safe because "populateRelationshipNameToWhereClauses" does the same check
      String fieldName = whereClause.split(' ')[0];
      if (fieldMap.containsKey(fieldName) == false) {
        continue;
      }

      if (index == 0) {
        query += ' AND ';
      }
      Boolean isOr = this.calcItemWhereClause.indexOfIgnoreCase(whereClause + ' or ') >= 0;
      Boolean isNestedConditionalStart =
        this.calcItemWhereClause.indexOfIgnoreCase('(' + relationshipName + '.' + whereClause) > 0 ||
        this.calcItemWhereClause.indexOfIgnoreCase('(' + whereClause) > 0;
      Boolean isNestedConditoonalEnd = this.calcItemWhereClause.indexOfIgnoreCase(whereClause + ')') >= 0;
      String whereClauseToUse = isNestedConditionalStart ? '(' + whereClause : whereClause;

      if (isNestedConditoonalEnd) {
        whereClauseToUse += ')';
      }
      concatDelim = isOr ? ' OR ' : ' AND ';
      query += whereClauseToUse + concatDelim;
    }

    return query.removeEnd(concatDelim).trim();
  }

  private void trackTraversalIds(Id recordId, Id lookupId, Schema.SObjectField field, Set<Id> lookupIds) {
    if (String.isNotBlank(lookupId)) {
      lookupIds?.add(lookupId);

      if (this.traversal.lookupIdMap.containsKey(lookupId)) {
        this.traversal.lookupIdMap.get(lookupId).add(recordId);
      } else {
        this.traversal.lookupIdMap.put(lookupId, new List<Id>{ recordId });
      }

      if (this.isFirstRun && field != null) {
        // we need to keep track of potentially reparented lookups to aid with the note below
        if (this.oldRecords.containsKey(recordId)) {
          Id oldLookupId = (Id) this.oldRecords.get(recordId).get(field);
          if (String.isNotBlank(oldLookupId) && oldLookupId != lookupId) {
            lookupIds.add(oldLookupId);
            this.traversal.hierarchy.put(oldLookupId, new List<Id>{ oldLookupId });
          }
        }
        this.traversal.hierarchy.put(lookupId, new List<Id>{ lookupId });
      } else if (this.traversal.hierarchy.containsKey(recordId)) {
        // track the hierarchy of objects to help in determining whether or not something
        // has ultimately been reparented
        // for example:
        // * Child 1 -> Parent 1 -> Grandparent 1 could be updated to
        // * Child 1 -> Parent 2 -> Grandparent 1
        // this would "traditionally" be a reparenting situation, but if we are skipping
        // the intermediate objects for a rollup and the end result is the same, we need
        // to avoid reporting false positives like this one
        this.traversal.hierarchy.get(recordId).add(lookupId);
      } else {
        this.traversal.hierarchy.put(recordId, new List<Id>{ lookupId });
      }
    }
  }

  private void populateHierarchicalLookupFields(Set<String> queryFieldNames, Schema.SObjectField hierarchyToken) {
    // we need to re-query the other fields at each hierarchy stage
    List<String> copiedFieldNamesPerRelationship = new List<String>(queryFieldNames);
    String relationshipName = hierarchyToken.getDescribe().getRelationshipName();
    String hierarchyName = hierarchyToken.getDescribe().getName();
    queryFieldNames.add(hierarchyToken.getDescribe().getName());
    for (Integer index = 0; index < MAX_FOREIGN_KEY_RELATIONSHIP_HOPS; index++) {
      String baseOfHierarchy = relationshipName.repeat(index).replace(relationshipName, relationshipName + '.');
      String repeatedHierarchy = baseOfHierarchy + hierarchyName;
      queryFieldNames.add(repeatedHierarchy);

      // now add the other fields required per relationship level
      for (String fieldName : copiedFieldNamesPerRelationship) {
        queryFieldNames.add(baseOfHierarchy + fieldName);
      }
    }
  }

  private void retrieveAdditionalHierarchyRecords(List<SObject> records, Set<Id> objIds) {
    String whereClause = 'Id != :records';
    if (this.metadata.RollupToUltimateParent__c == false) {
      return;
    } else if (records.isEmpty()) {
      List<SObject> otherMatchingParentRecords = this.performQuery(
        this.ultimateParent,
        new List<String>{ this.metadata.UltimateParentLookup__c, 'Id' },
        this.metadata.UltimateParentLookup__c,
        '=',
        objIds,
        whereClause,
        records
      );
      if (otherMatchingParentRecords.isEmpty() == false) {
        this.retrieveAdditionalHierarchyRecords(otherMatchingParentRecords, objIds);
      }
    } else {
      Set<Id> additionalParentIds = new Set<Id>();
      for (SObject otherMatchingParent : records) {
        additionalParentIds.add(otherMatchingParent.Id);
        this.trackTraversalIds(otherMatchingParent.Id, (Id) otherMatchingParent.get(this.metadata.UltimateParentLookup__c), null, additionalParentIds);
      }
      List<SObject> otherPotentialParents = this.performQuery(
        this.ultimateParent,
        new List<String>{ this.metadata.UltimateParentLookup__c, 'Id' },
        this.metadata.UltimateParentLookup__c,
        '=',
        additionalParentIds,
        whereClause,
        records
      );
      if (otherPotentialParents.isEmpty()) {
        this.retrieveAdditionalCalcItems();
      } else {
        this.retrieveAdditionalHierarchyRecords(otherPotentialParents, additionalParentIds);
      }
    }
  }

  private List<SObject> performQuery(
    SObjectType sObjectType,
    List<String> queryFields,
    String lookupfield,
    String equality,
    Set<Id> objIds,
    String whereClause,
    List<SObject> records
  ) {
    return Database.query(RollupQueryBuilder.Current.getQuery(sObjectType, queryFields, lookupfield, equality, whereClause));
  }

  @SuppressWarnings('PMD.ApexSOQLInjection, PMD.UnusedLocalVariable')
  private void retrieveAdditionalCalcItems() {
    if (this.records?.isEmpty() == false) {
      SObjectType childType = this.records[0].getSObjectType();
      Set<String> queryFields = new Set<String>{
        this.metadata.LookupFieldOnCalcItem__c,
        this.metadata.RollupFieldOnCalcItem__c,
        this.metadata.OrderByFirstLast__c,
        this.metadata.UltimateParentLookup__c
      };
      queryFields.addAll(RollupEvaluator.getWhereEval(this.metadata.CalcItemWhereClause__c, childType).getQueryFields());
      String query = RollupQueryBuilder.Current.getQuery(childType, new List<String>(queryFields), this.metadata.LookupFieldOnCalcItem__c, '=');
      query += '\nAND Id != :records';
      Set<Id> objIds = this.traversal.hierarchy.keySet();
      List<SObject> additionalCalcItems = Database.query(query);
      this.records.addAll(additionalCalcItems);
      for (SObject additionalCalcItem : additionalCalcItems) {
        Id parentId = (Id) additionalCalcItem.get(this.metadata.LookupFieldOnCalcItem__c);
        if (this.traversal.hierarchy.containsKey(parentId)) {
          List<Id> potentialLinkedLookupIds = this.traversal.hierarchy.get(parentId);
          for (Id potentialLinkedLookupId : potentialLinkedLookupIds) {
            if (potentialLinkedLookupId != parentId && this.traversal.finalParentIdToRecords.containsKey(potentialLinkedLookupId)) {
              SObject ultimateParentRecord = this.traversal.finalParentIdToRecords.get(potentialLinkedLookupId);
              this.traversal.lookupIdToFinalRecords.put(additionalCalcItem.Id, ultimateParentRecord);
            }
          }
        }
      }
    }
  }

  private void populateFinalRecordsMapping(List<SObject> records) {
    for (SObject record : records) {
      Set<Id> descendantIds = this.getDescendantIds(record.Id, new Set<Id>());
      for (Id descendantId : descendantIds) {
        if (descendantId != record.Id) {
          this.traversal.lookupIdToFinalRecords.put(descendantId, record);
          this.traversal.finalParentIdToRecords.put(record.Id, record);
        }
      }
    }
  }

  private class WhereClauseSorter extends RollupComparer {
    private final String fullWhereClause;
    public WhereClauseSorter(String fullWhereClause) {
      this.fullWhereClause = fullWhereClause;
    }

    public override Integer compare(Object o1, Object o2) {
      Integer returnVal = 0;

      if (o1 instanceof String && o2 instanceof String) {
        String first = (String) o1;
        String second = (String) o2;

        Integer whereFirstIs = this.fullWhereClause.indexOf(first);
        Integer whereSecondIs = this.fullWhereClause.indexOf(second);

        if (whereFirstIs > whereSecondIs) {
          returnVal = this.moveTowardFrontOfList;
        } else if (whereSecondIs > whereFirstIs) {
          returnVal = this.moveTowardBackOfList;
        }
      }

      return returnVal;
    }
  }
}
