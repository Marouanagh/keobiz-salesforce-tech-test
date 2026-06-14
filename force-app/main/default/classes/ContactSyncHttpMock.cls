/**
 * Reusable HttpCalloutMock for the contact synchronisation callout.
 *
 * It can return any status code/body so tests can exercise both the happy path
 * (200) and the documented error paths (400/401/404). It also captures the last
 * request so tests can assert on the method, headers and payload that were sent.
 */
@IsTest
public class ContactSyncHttpMock implements HttpCalloutMock {

    private final Integer statusCode;
    private final String body;

    public HttpRequest lastRequest { get; private set; }

    public ContactSyncHttpMock() {
        this(200, 'OK');
    }

    public ContactSyncHttpMock(Integer statusCode, String body) {
        this.statusCode = statusCode;
        this.body = body;
    }

    public HttpResponse respond(HttpRequest request) {
        this.lastRequest = request;

        HttpResponse response = new HttpResponse();
        response.setStatusCode(statusCode);
        response.setBody(body);
        response.setHeader('Content-Type', 'application/json');
        return response;
    }
}
