/**
 * End-to-end tests for the Account cancellation flow, driven through the trigger
 * (insert/update DML) rather than by calling the handler directly, so the whole
 * chain - trigger, handler, service, queueable, callout - is exercised.
 */
@IsTest
private class AccountTriggerHandlerTest {

    private static final String ACTIVE = 'active';
    private static final String CANCELED = 'canceled';

    /**
     * Helper: builds an Account with the given mission status.
     */
    private static Account buildAccount(String name, String status) {
        return new Account(Name = name, MissionStatus__c = status);
    }

    /**
     * Helper: links a contact to an account through AccountContactRelation.
     */
    private static AccountContactRelation link(Id accountId, Id contactId) {
        return new AccountContactRelation(AccountId = accountId, ContactId = contactId);
    }

    /**
     * Scenario:
     *  - contact1 is linked to accA + accB  -> both get canceled -> becomes inactive
     *  - contact2 is linked to accA + accC  -> accC stays active -> stays active
     *
     * Expectations:
     *  - the canceled accounts get today's MissionCanceledDate__c
     *  - only contact1 is deactivated
     *  - exactly one synchronisation callout is sent, containing only contact1
     */
    @IsTest
    static void deactivatesContactOnlyWhenAllAccountsCanceled() {
        Account accA = buildAccount('Acc A', ACTIVE);
        Account accB = buildAccount('Acc B', ACTIVE);
        Account accC = buildAccount('Acc C', ACTIVE);
        insert new List<Account>{ accA, accB, accC };

        Contact contact1 = new Contact(LastName = 'Contact One', IsActive__c = true);
        Contact contact2 = new Contact(LastName = 'Contact Two', IsActive__c = true);
        insert new List<Contact>{ contact1, contact2 };

        insert new List<AccountContactRelation>{
            link(accA.Id, contact1.Id),
            link(accB.Id, contact1.Id),
            link(accA.Id, contact2.Id),
            link(accC.Id, contact2.Id)
        };

        ContactSyncHttpMock mock = new ContactSyncHttpMock(200, 'OK');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        accA.MissionStatus__c = CANCELED;
        accB.MissionStatus__c = CANCELED;
        update new List<Account>{ accA, accB };
        Test.stopTest(); // async queueable (the callout) runs here

        // (a) cancellation date stamped on the canceled accounts
        Map<Id, Account> accounts = new Map<Id, Account>([
            SELECT Id, MissionCanceledDate__c FROM Account WHERE Id IN :new List<Id>{ accA.Id, accB.Id, accC.Id }
        ]);
        Assert.areEqual(Date.today(), accounts.get(accA.Id).MissionCanceledDate__c, 'Acc A should be stamped');
        Assert.areEqual(Date.today(), accounts.get(accB.Id).MissionCanceledDate__c, 'Acc B should be stamped');
        Assert.isNull(accounts.get(accC.Id).MissionCanceledDate__c, 'Acc C was not canceled');

        // (b) only contact1 became inactive
        Map<Id, Contact> contacts = new Map<Id, Contact>([
            SELECT Id, IsActive__c FROM Contact WHERE Id IN :new List<Id>{ contact1.Id, contact2.Id }
        ]);
        Assert.isFalse(contacts.get(contact1.Id).IsActive__c, 'Contact 1 has all accounts canceled -> inactive');
        Assert.isTrue(contacts.get(contact2.Id).IsActive__c, 'Contact 2 still has an active account -> active');

        // (c) exactly one contact (contact1) was synchronised
        Assert.isNotNull(mock.lastRequest, 'A synchronisation callout should have been sent');
        Assert.areEqual('PATCH', mock.lastRequest.getMethod(), 'API contract requires PATCH');
        Assert.areEqual('salesforceAuthToken', mock.lastRequest.getHeader('Authorization'), 'Auth token must be sent');

        List<Object> payload = (List<Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        Assert.areEqual(1, payload.size(), 'Only contact1 should be synchronised');
        Map<String, Object> entry = (Map<String, Object>) payload[0];
        Assert.areEqual(contact1.Id, (String) entry.get('id'), 'Payload must carry the contact id');
        Assert.areEqual(false, entry.get('is_active'), 'Payload must carry the new activity status');
    }

    /**
     * Re-saving an already-canceled account must not re-trigger the downstream
     * actions (idempotency): no contact change, no callout.
     */
    @IsTest
    static void doesNothingWhenStatusWasAlreadyCanceled() {
        Account acc = buildAccount('Already Canceled', CANCELED);
        insert acc;

        Contact c = new Contact(LastName = 'Still Active', IsActive__c = true);
        insert c;
        insert link(acc.Id, c.Id);

        ContactSyncHttpMock mock = new ContactSyncHttpMock(200, 'OK');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        acc.Name = 'Already Canceled - renamed'; // update that does NOT change the status
        update acc;
        Test.stopTest();

        Contact reloaded = [SELECT IsActive__c FROM Contact WHERE Id = :c.Id];
        Assert.isTrue(reloaded.IsActive__c, 'Contact must stay active when nothing newly canceled');
        Assert.isNull(mock.lastRequest, 'No callout expected when status did not change to canceled');
    }

    /**
     * Bulk safety: 200 accounts, each with its own contact, all canceled in a
     * single DML. Every contact must be deactivated within governor limits.
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
            contacts.add(new Contact(LastName = 'Bulk Contact ' + i, IsActive__c = true));
        }
        insert contacts;

        List<AccountContactRelation> relations = new List<AccountContactRelation>();
        for (Integer i = 0; i < 200; i++) {
            relations.add(link(accounts[i].Id, contacts[i].Id));
        }
        insert relations;

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
