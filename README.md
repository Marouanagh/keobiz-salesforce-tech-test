# Keobiz — Salesforce Tech Test

Apex solution triggered on `Account` update. No Flow/Process Builder.

## What it does

When `Account.MissionStatus__c` changes to `canceled`:

- **(a)** Sets `MissionCanceledDate__c` to today
- **(b)** Checks every contact linked to that account via `AccountContactRelation` — if **all** of a contact's accounts are canceled, sets `Contact.IsActive__c = false`
- **(c)** Sends the deactivated contacts to the sync API via `PATCH`

## Files

| File | Role |
|---|---|
| `AccountTrigger.trigger` | Entry point — routes `before`/`after update` to handler |
| `AccountTriggerHandler.cls` | `before`: stamps date in-memory. `after`: collects canceled accounts |
| `ContactDeactivationService.cls` | Checks all relations per contact, deactivates, triggers sync |
| `ContactSyncQueueable.cls` | Async wrapper so the callout runs outside the trigger transaction |
| `ContactSyncService.cls` | Builds JSON payload, sends `PATCH`, logs non-200 responses |
| `AccountTriggerHandlerTest.cls` | End-to-end tests via DML (includes 200-account bulk test) |
| `ContactSyncServiceTest.cls` | Unit tests for HTTP method, headers, payload shape, error codes |
| `ContactSyncHttpMock.cls` | `HttpCalloutMock` used by both test classes |

## API

```
PATCH https://fxyozmgb2xs5iogcheotxi6hoa0jdhiz.lambda-url.eu-central-1.on.aws
Authorization: salesforceAuthToken
Content-Type: application/json

[{ "id": "<contactId>", "is_active": false }, ...]
```

## Notes

- The trigger only fires on records **transitioning into** `canceled` — re-saving an already-canceled account does nothing.
- All SOQL/DML is set-based (no queries in loops) — safe at 200 accounts per transaction.
- Endpoint and token are constants for this exercise. In production they'd live in a Named Credential.

## Deploy

```bash
sf project deploy start --source-dir force-app
sf apex run test --class-names AccountTriggerHandlerTest ContactSyncServiceTest --result-format human --wait 10
```
