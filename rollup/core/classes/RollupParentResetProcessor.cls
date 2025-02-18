public inherited sharing class RollupParentResetProcessor extends RollupFullBatchRecalculator {
  @TestVisible
  private static Integer maxQueryRows = Limits.getLimitQueryRows() / 2;

  private without sharing class QueueableResetProcessor implements System.Queueable {
    private final RollupParentResetProcessor processor;
    private final Integer batchChunkSize;
    private QueueableResetProcessor(RollupParentResetProcessor processor, Integer batchChunkSize) {
      this.processor = processor;
      this.batchChunkSize = batchChunkSize;
    }

    public void execute(QueueableContext qc) {
      Database.executeBatch(this.processor, this.batchChunkSize);
    }
  }

  public RollupParentResetProcessor(
    List<Rollup__mdt> matchingMeta,
    SObjectType calcItemType,
    String queryString,
    Set<Id> recordIds,
    InvocationPoint invokePoint
  ) {
    super(getRefinedQueryString(queryString, matchingMeta), invokePoint, matchingMeta, calcItemType, recordIds);
    this.overridesRunCalc = true;
    this.isNoOp = false;
  }

  public override String runCalc() {
    this.isProcessed = true;
    Integer countOfItems = Database.countQuery(this.queryString.replaceFirst('SELECT.+\n', 'SELECT Count()\n'));
    Boolean isOverLimit = countOfItems > maxQueryRows;
    if (isOverLimit && System.isBatch() == false) {
      // avoids: System.AsyncException: Database.executeBatch cannot be called from a batch start, batch execute, or future method
      this.startAsyncWork();
    } else if (isOverLimit && Limits.getLimitQueueableJobs() > Limits.getQueueableJobs()) {
      // avoids System.LimitException: Too many queueable jobs added to the queue: { output of Limits.getQueueableJobs() }
      // down the rabbit hole we go again
      this.swapToQueueableToStartBatch();
    } else {
      List<SObject> parentItems = Database.query(this.queryString);
      this.execute(null, parentItems);
    }

    return 'No process Id';
  }

  public override void execute(Database.BatchableContext bc, List<SObject> calcItems) {
    for (SObject parentItem : calcItems) {
      for (Rollup__mdt rollupMeta : this.rollupInfo) {
        parentItem.put(rollupMeta.RollupFieldOnLookupObject__c, null);
      }
    }
    this.getDML().doUpdate(calcItems);
  }

  protected override String getTypeName() {
    return RollupParentResetProcessor.class.getName();
  }

  private void swapToQueueableToStartBatch() {
    System.enqueueJob(new QueueableResetProcessor(this, this.rollupControl.BatchChunkSize__c.intValue()));
  }

  private static String getRefinedQueryString(String localQueryString, List<Rollup__mdt> matchingMeta) {
    if (matchingMeta.isEmpty() == false) {
      localQueryString += '\nAND (';
    }
    for (Rollup__mdt meta : matchingMeta) {
      localQueryString += meta.RollupFieldOnLookupObject__c + ' != null OR ';
    }
    return localQueryString.removeEnd(' OR ') + ')';
  }
}
