/**
 * Focused unit tests for the callout layer: payload shape, request metadata and
 * handling of the documented HTTP status codes (200/400/401/404).
 */
@IsTest
private class ContactSyncServiceTest {

    private static List<Contact> insertContacts() {
        List<Contact> contacts = new List<Contact>{
            new Contact(LastName = 'A', IsActive__c = false),
            new Contact(LastName = 'B', IsActive__c = false)
        };
        insert contacts;
        return contacts;
    }

    @IsTest
    static void buildsExpectedPayloadAndRequest() {
        List<Contact> contacts = insertContacts();
        ContactSyncHttpMock mock = new ContactSyncHttpMock(200, 'OK');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Integer status = ContactSyncService.sync(contacts);
        Test.stopTest();

        Assert.areEqual(200, status, 'Happy path should return 200');
        Assert.areEqual('PATCH', mock.lastRequest.getMethod());
        Assert.areEqual('application/json', mock.lastRequest.getHeader('Content-Type'));
        Assert.areEqual('salesforceAuthToken', mock.lastRequest.getHeader('Authorization'));

        List<Object> payload = (List<Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        Assert.areEqual(2, payload.size(), 'Both contacts must be in the payload');
        Map<String, Object> first = (Map<String, Object>) payload[0];
        Assert.isTrue(first.containsKey('id'), 'Each entry must have an id');
        Assert.isTrue(first.containsKey('is_active'), 'Each entry must have is_active');
        Assert.areEqual(false, first.get('is_active'), 'Status must reflect the contact value');
    }

    @IsTest
    static void returnsNullForEmptyInputWithoutCallout() {
        Test.setMock(HttpCalloutMock.class, new ContactSyncHttpMock(200, 'OK'));

        Test.startTest();
        Integer status = ContactSyncService.sync(new List<Contact>());
        Test.stopTest();

        Assert.isNull(status, 'No callout and no status for an empty list');
    }

    @IsTest
    static void surfacesErrorStatusCodes() {
        List<Contact> contacts = insertContacts();

        // 401 - Bad authorization is one of the documented error responses.
        Test.setMock(HttpCalloutMock.class, new ContactSyncHttpMock(401, 'Bad authorization'));

        Test.startTest();
        Integer status = ContactSyncService.sync(contacts);
        Test.stopTest();

        Assert.areEqual(401, status, 'The service should return the remote error status');
    }
}
