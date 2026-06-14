/**
 * Orchestrates the Account update trigger.
 *
 * Responsibilities:
 *  - before update : stamp MissionCanceledDate__c on accounts that have just
 *                    been moved to the "canceled" status.
 *  - after  update : hand the set of newly-canceled accounts over to the
 *                    ContactDeactivationService, which deactivates the relevant
 *                    contacts and triggers the remote synchronisation.
 *
 * Everything is set-based so the trigger is safe on 200 accounts in a single
 * transaction.
 */
public with sharing class AccountTriggerHandler {

    @TestVisible
    private static final String STATUS_CANCELED = 'canceled';

    /**
     * (a) Set the cancellation date on accounts whose mission has just been
     * canceled. Done in the "before" context so the value is written as part of
     * the current DML - no additional update statement required.
     */
    public static void handleBeforeUpdate(List<Account> newAccounts, Map<Id, Account> oldMap) {
        Date today = Date.today();
        for (Account acc : newAccounts) {
            if (isNewlyCanceled(acc, oldMap.get(acc.Id))) {
                acc.MissionCanceledDate__c = today;
            }
        }
    }

    /**
     * (b) + (c) Collect the accounts that have just been canceled and delegate
     * the contact deactivation / synchronisation to the service layer.
     */
    public static void handleAfterUpdate(List<Account> newAccounts, Map<Id, Account> oldMap) {
        Set<Id> canceledAccountIds = new Set<Id>();
        for (Account acc : newAccounts) {
            if (isNewlyCanceled(acc, oldMap.get(acc.Id))) {
                canceledAccountIds.add(acc.Id);
            }
        }

        if (!canceledAccountIds.isEmpty()) {
            ContactDeactivationService.deactivateContactsAndSync(canceledAccountIds);
        }
    }

    /**
     * A record is "newly canceled" when it moved INTO the canceled status during
     * this update. Records that were already canceled are ignored so the logic
     * is idempotent and re-saves don't re-trigger the downstream actions.
     */
    private static Boolean isNewlyCanceled(Account newAcc, Account oldAcc) {
        return newAcc.MissionStatus__c == STATUS_CANCELED
            && (oldAcc == null || oldAcc.MissionStatus__c != STATUS_CANCELED);
    }
}
