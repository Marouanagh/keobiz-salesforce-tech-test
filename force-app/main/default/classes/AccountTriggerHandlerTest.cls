@IsTest
private class AccountTriggerHandlerTest {

    private static final String ACTIVE   = 'active';
    private static final String CANCELED = 'canceled';

    private static Account buildAccount(String name, String status) {
        return new Account(Name = name, MissionStatus__c = status);
    }

    /**
     * Scenario:
     *  - contact1 primary account = accA, also linked to accB
     *    → both get canceled → becomes inactive
     *  - contact2 primary account = accA, also linked to accC
     *    → accC stays active → contact2 stays active
     *
     * A Contact inserted without AccountId is "private" and cannot be linked
     * via AccountContactRelation. Setting AccountId makes it non-private;
     * Salesforce auto-creates the primary ACR — we only add secondary ones manually.
     */
    @IsTest
    static void deactivatesContactOnlyWhenAllAccountsCanceled() {
        Account accA = buildAccount('Acc A', ACTIVE);
        Account accB = buildAccount('Acc B', ACTIVE);
        Account accC = buildAccount('Acc C', ACTIVE);
        insert new List<Account>{ accA, accB, accC };

        // Primary account set so contacts are not private
        Contact contact1 = new Contact(LastName = 'Contact One', IsActive__c = true, AccountId = accA.Id);
        Contact contact2 = new Contact(LastName = 'Contact Two', IsActive__c = true, AccountId = accA.Id);
        insert new List<Contact>{ contact1, contact2 };

        // Salesforce already created ACR(accA, contact1) and ACR(accA, contact2).
        // Only add the secondary relationships.
        insert new List<AccountContactRelation>{
            new AccountContactRelation(AccountId = accB.Id, ContactId = contact1.Id),
            new AccountContactRelation(AccountId = accC.Id, ContactId = contact2.Id)
        };

        ContactSyncHttpMock mock = new ContactSyncHttpMock(200, 'OK');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        accA.MissionStatus__c = CANCELED;
        accB.MissionStatus__c = CANCELED;
        update new List<Account>{ accA, accB };
        Test.stopTest();

        // (a) cancellation date stamped on canceled accounts only
        Map<Id, Account> accounts = new Map<Id, Account>([
            SELECT Id, MissionCanceledDate__c FROM Account
            WHERE Id IN :new List<Id>{ accA.Id, accB.Id, accC.Id }
        ]);
        Assert.areEqual(Date.today(), accounts.get(accA.Id).MissionCanceledDate__c, 'Acc A should be stamped');
        Assert.areEqual(Date.today(), accounts.get(accB.Id).MissionCanceledDate__c, 'Acc B should be stamped');
        Assert.isNull(accounts.get(accC.Id).MissionCanceledDate__c, 'Acc C was not canceled');

        // (b) only contact1 became inactive
        Map<Id, Contact> contacts = new Map<Id, Contact>([
            SELECT Id, IsActive__c FROM Contact
            WHERE Id IN :new List<Id>{ contact1.Id, contact2.Id }
        ]);
        Assert.isFalse(contacts.get(contact1.Id).IsActive__c, 'Contact 1 has all accounts canceled -> inactive');
        Assert.isTrue(contacts.get(contact2.Id).IsActive__c,  'Contact 2 still has active account -> stays active');

        // (c) exactly one contact (contact1) was synchronised
        Assert.isNotNull(mock.lastRequest, 'A synchronisation callout should have been sent');
        Assert.areEqual('PATCH', mock.lastRequest.getMethod(), 'API contract requires PATCH');
        Assert.areEqual('salesforceAuthToken', mock.lastRequest.getHeader('Authorization'), 'Auth token must match');

        List<Object> payload = (List<Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        Assert.areEqual(1, payload.size(), 'Only contact1 should be synchronised');
        Map<String, Object> entry = (Map<String, Object>) payload[0];
        Assert.areEqual(contact1.Id, (String) entry.get('id'), 'Payload must carry the contact Id');
        Assert.areEqual(false, entry.get('is_active'), 'Payload must carry is_active = false');
    }

    /**
     * Re-saving an already-canceled account must not re-trigger downstream
     * actions (idempotency): no contact change, no callout.
     */
    @IsTest
    static void doesNothingWhenStatusWasAlreadyCanceled() {
        Account acc = buildAccount('Already Canceled', CANCELED);
        insert acc;

        Contact c = new Contact(LastName = 'Still Active', IsActive__c = true, AccountId = acc.Id);
        insert c;

        ContactSyncHttpMock mock = new ContactSyncHttpMock(200, 'OK');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        acc.Name = 'Already Canceled - renamed';
        update acc;
        Test.stopTest();

        Contact reloaded = [SELECT IsActive__c FROM Contact WHERE Id = :c.Id];
        Assert.isTrue(reloaded.IsActive__c, 'Contact must stay active when status did not change');
        Assert.isNull(mock.lastRequest, 'No callout expected when status did not change to canceled');
    }

    /**
     * Bulk safety: 200 accounts each with their own contact, all canceled in one
     * DML. Every contact must be deactivated within governor limits.
     */
    @IsTest
    static void handlesTwoHundredAccountsInBulk() {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 200; i++) {
            accounts.add(buildAccount('Bulk Acc ' + i, ACTIVE));
        }
        insert accounts;

        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < 200; i++) {
            contacts.add(new Contact(LastName = 'Bulk Contact ' + i, IsActive__c = true, AccountId = accounts[i].Id));
        }
        insert contacts;

        Test.setMock(HttpCalloutMock.class, new ContactSyncHttpMock(200, 'OK'));

        Test.startTest();
        for (Account acc : accounts) {
            acc.MissionStatus__c = CANCELED;
        }
        update accounts;
        Test.stopTest();

        Integer activeRemaining = [
            SELECT COUNT() FROM Contact WHERE Id IN :contacts AND IsActive__c = true
        ];
        Assert.areEqual(0, activeRemaining, 'All 200 contacts should be deactivated');
    }
}
