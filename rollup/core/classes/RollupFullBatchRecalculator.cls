public inherited sharing virtual class RollupFullBatchRecalculator extends RollupAsyncProcessor.FullRecalcProcessor implements Database.Stateful {
  private final Map<String, Rollup.CalcItemBag> statefulLookupToCalcItems;

  public RollupFullBatchRecalculator(
    String queryString,
    InvocationPoint invokePoint,
    List<Rollup__mdt> rollupInfo,
    SObjectType calcItemType,
    Set<Id> recordIds
  ) {
    super(queryString, invokePoint, rollupInfo, calcItemType, recordIds);
    this.statefulLookupToCalcItems = new Map<String, Rollup.CalcItemBag>();
  }

  public override Database.QueryLocator start(Database.BatchableContext bc) {
    this.isProcessed = true;
    // note - if the optional where clause was appended to the passed in query string, this.recordIds is also
    // used as a bind variable
    return Database.getQueryLocator(this.queryString);
  }

  public virtual override void execute(Database.BatchableContext bc, List<SObject> calcItems) {
    RollupLogger.Instance.log('starting full batch recalc run:', this, LoggingLevel.DEBUG);
    /**
     * this batch class is a glorified "for loop" for the calc items, dispatching
     * them to the overall Rollup framework while breaking us out of the query limits
     * it has to be it's own class - Database.Batchable does not support inner classes
     * being batched, even if the inner class is just extending the functionality of its
     * parent class
     */
    this.getDelegatedFullRecalcRollup(this.rollupInfo, calcItems, this).runCalc();
    RollupLogger.Instance.save();
  }

  public override void finish(Database.BatchableContext bc) {
    RollupLogger.Instance.log(this.getTypeName() + ' finished', LoggingLevel.DEBUG);
    RollupLogger.Instance.save();
  }

  protected virtual override String getTypeName() {
    return RollupFullBatchRecalculator.class.getName();
  }

  protected override String startAsyncWork() {
    return this.startBatchProcessor();
  }

  protected override void retrieveAdditionalCalcItems(Map<String, Rollup.CalcItemBag> lookupToCalcItems, RollupAsyncProcessor rollup) {
    RollupLogger.Instance.log(this.getTypeName() + ' checking on cached calc items ...', LoggingLevel.FINE);
    Map<String, Rollup.CalcItemBag> local = new Map<String, Rollup.CalcItemBag>();
    for (String lookupKey : lookupToCalcItems.keySet()) {
      Rollup.CalcItemBag bag = lookupToCalcItems.get(lookupKey);
      if (bag.hasQueriedForAdditionalItems == false && this.statefulLookupToCalcItems.containsKey(lookupKey)) {
        lookupToCalcItems.remove(lookupKey);
      } else {
        local.put(lookupKey, bag);
      }
      lookupToCalcItems.put(lookupKey, bag);
    }

    super.retrieveAdditionalCalcItems(local, rollup);

    for (String lookupKey : local.keySet()) {
      this.statefulLookupToCalcItems.put(lookupKey, local.get(lookupKey));
    }
  }
}
