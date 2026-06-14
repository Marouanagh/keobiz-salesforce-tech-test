/**
 * Builds the payload and performs the bulk PATCH callout that synchronises the
 * activity status of contacts with the remote server.
 *
 * Payload (per the API spec):
 *   [ { "id": "<contactId>", "is_active": <boolean> }, ... ]
 *
 * NOTE on configuration:
 *   The endpoint and the authorization token are exposed as constants here for
 *   the sake of a self-contained, reviewable exercise. In production they should
 *   live in a Named Credential (endpoint + auth) or a protected Custom Metadata
 *   Type / Custom Setting so secrets are never hard-coded and the environment is
 *   configurable without a deployment.
 */
public with sharing class ContactSyncService {

    @TestVisible
    private static final String ENDPOINT =
        'https://fxyozmgb2xs5iogcheotxi6hoa0jdhiz.lambda-url.eu-central-1.on.aws';

    @TestVisible
    private static final String AUTH_TOKEN = 'salesforceAuthToken';

    private static final String HTTP_METHOD = 'PATCH';
    private static final Integer SUCCESS_STATUS = 200;

    /** Serializable representation of a single entry of the request body. */
    public class SyncItem {
        public String id;
        public Boolean is_active;

        public SyncItem(Id contactId, Boolean isActive) {
            this.id = contactId;
            this.is_active = isActive;
        }
    }

    /**
     * Sends the activity status of the given contacts to the remote server.
     * Returns the HTTP status code so callers/tests can assert on the outcome.
     */
    public static Integer sync(List<Contact> contacts) {
        if (contacts == null || contacts.isEmpty()) {
            return null;
        }

        List<SyncItem> payload = buildPayload(contacts);

        HttpRequest request = new HttpRequest();
        request.setEndpoint(ENDPOINT);
        request.setMethod(HTTP_METHOD);
        request.setHeader('Authorization', AUTH_TOKEN);
        request.setHeader('Content-Type', 'application/json');
        request.setBody(JSON.serialize(payload));

        HttpResponse response = new Http().send(request);
        Integer statusCode = response.getStatusCode();

        if (statusCode != SUCCESS_STATUS) {
            // The remote contract documents 400/401/404. We surface the failure
            // with a clear, debuggable message rather than failing silently.
            // (In production this would feed a retry mechanism / error log object.)
            System.debug(LoggingLevel.ERROR,
                'Contact synchronisation failed. HTTP ' + statusCode
                + ' - ' + response.getStatus()
                + ' - body: ' + response.getBody());
        }
        return statusCode;
    }

    private static List<SyncItem> buildPayload(List<Contact> contacts) {
        List<SyncItem> items = new List<SyncItem>();
        for (Contact c : contacts) {
            items.add(new SyncItem(c.Id, c.IsActive__c));
        }
        return items;
    }
}
