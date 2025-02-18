@IsTest
private class RollupFieldInitializerTests {
  @IsTest
  static void shouldReturnDefaultForNumberFields() {
    RollupFieldInitializer initializer = RollupFieldInitializer.Current;

    System.assertEquals(0, initializer.getDefaultValue(Campaign.NumberSent), 'double');
    System.assertEquals(0, initializer.getDefaultValue(Account.AnnualRevenue), 'currency');
    System.assertEquals(0, initializer.getDefaultValue(Account.NumberOfEmployees), 'integer');
    System.assertEquals(0, initializer.getDefaultValue(Opportunity.Probability), 'percent');
  }

  @IsTest
  static void shouldReturnDefaultsForDates() {
    RollupFieldInitializer initializer = RollupFieldInitializer.Current;

    System.assertEquals(initializer.defaultDateTime, initializer.getDefaultValue(Task.ReminderDatetime), 'datetime');
    System.assertEquals(initializer.defaultDateTime.dateGmt(), initializer.getDefaultValue(Opportunity.CloseDate), 'date');
    System.assertEquals(initializer.defaultDateTime.timeGmt(), initializer.getDefaultValue(BusinessHours.MondayStartTime), 'time');
  }

  @IsTest
  static void shouldReturnDefaultsForStrings() {
    RollupFieldInitializer initializer = RollupFieldInitializer.Current;

    System.assertEquals('', initializer.getDefaultValue(Account.Id), 'Id');
    System.assertEquals('', initializer.getDefaultValue(Task.Description), 'text area');
    System.assertEquals('', initializer.getDefaultValue(Account.Name), 'string');
    System.assertEquals('', initializer.getDefaultValue(Account.Website), 'website');
    System.assertEquals('', initializer.getDefaultValue(Account.Phone), 'phone');
    System.assertEquals('', initializer.getDefaultValue(Contact.Email), 'email');
    System.assertEquals('', initializer.getDefaultValue(Contact.AccountId), 'reference');
    System.assertEquals(
      Task.Subject.getDescribe().getDefaultValue() != null ? Task.Subject.getDescribe().getDefaultValue() : '',
      initializer.getDefaultValue(Task.Subject),
      'combobox'
    );
  }

  @IsTest
  static void shouldReturnDefaultsForPicklist() {
    List<Schema.PicklistEntry> picklistEntries = Account.Industry.getDescribe().getPicklistValues();
    if (picklistEntries.isEmpty()) {
      return;
    }

    RollupFieldInitializer initializer = RollupFieldInitializer.Current;
    System.assertEquals(picklistEntries[0].getValue(), initializer.getDefaultValue(Account.Industry));

    // multi-select
    picklistEntries = QuickText.Channel.getDescribe().getPicklistValues();
    if (picklistEntries.isEmpty()) {
      return;
    }

    System.assertEquals(picklistEntries[0].getValue(), initializer.getDefaultValue(QuickText.Channel));
  }

  @IsTest
  static void shouldReturnAdditionalInfoAboutPicklistFields() {
    RollupFieldInitializer.PicklistController picklistController = new RollupFieldInitializer.PicklistController(Lead.Status.getDescribe());

    System.assertEquals(true, picklistController.isPicklist());
    System.assertEquals(false, picklistController.isMultiSelectPicklist());

    List<Schema.PicklistEntry> picklistEntries = Lead.Status.getDescribe().getPicklistValues();
    if (picklistEntries.size() < 2) {
      return;
    }

    String firstValue = picklistEntries[0].getValue();
    String secondValue = picklistEntries[1].getValue();
    System.assertEquals(true, picklistController.isTrueFor(firstValue, secondValue, Rollup.Op.MIN));
    System.assertEquals(true, picklistController.isTrueFor(secondValue, firstValue, Rollup.Op.MAX));
    System.assertEquals(true, picklistController.isTrueFor('b', 'a', Rollup.Op.MAX));

    System.assertEquals(picklistController.maximumIntegerValue, picklistController.getRank('a', Rollup.Op.MIN));
    System.assertEquals(picklistController.minimumIntegerValue, picklistController.getRank('a', Rollup.Op.MAX));
  }

  @IsTest
  static void shouldReturnSafeDefaultsForNonPicklistValues() {
    RollupFieldInitializer.PicklistController picklistController = new RollupFieldInitializer.PicklistController(Account.Name.getDescribe());

    System.assertEquals('', picklistController.getDefaultValue(Account.Name));
    System.assertEquals(false, picklistController.isTrueFor('one', 'two', Rollup.Op.MAX));
  }

  @IsTest
  static void shouldThrowForUnhandledTypes() {
    RollupFieldInitializer initializer = RollupFieldInitializer.Current;

    Exception ex;
    try {
      initializer.getDefaultValue(Attachment.Body);
    } catch (Exception e) {
      ex = e;
    }

    System.assertNotEquals(null, ex, 'Exception should have been thrown');
  }
}
