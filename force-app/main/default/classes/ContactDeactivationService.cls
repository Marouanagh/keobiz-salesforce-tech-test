/**
 * Business logic that decides which contacts must become inactive when one or
 * more of their accounts are canceled, then persists the change and kicks off
 * the remote synchronisation.
 *
 * Rule (exercise point b): a contact becomes inactive when ALL of the accounts
 * related to it (through AccountContactRelation) are in the "canceled" status.
 *
 * The whole method is set-based and uses a bounded number of SOQL/DML
 * statements regardless of how many accounts/contacts are involved, so it stays
 * within governor limits for the 200-account requirement.
 */
public with sharing class ContactDeactivationService {

    private static final String STATUS_CANCELED = 'canceled';

    /**
     * Entry point called from the after-update context of the Account trigger.
     *
     * @param canceledAccountIds ids of the accounts that have just been canceled.
     */
    public static void deactivateContactsAndSync(Set<Id> canceledAccountIds) {
        // 1. Find the contacts attached to the freshly-canceled accounts.
        Set<Id> candidateContactIds = findRelatedContactIds(canceledAccountIds);
        if (candidateContactIds.isEmpty()) {
            return;
        }

        // 2. For every candidate, check whether ALL of its accounts are canceled.
        Set<Id> contactsToDeactivate = findContactsWithAllAccountsCanceled(candidateContactIds);
        if (contactsToDeactivate.isEmpty()) {
            return;
        }

        // 3. Flip only the contacts that are still marked active (avoids useless
        //    DML and useless callouts for contacts already inactive).
        List<Contact> updatedContacts = deactivateActiveContacts(contactsToDeactivate);
        if (updatedContacts.isEmpty()) {
            return;
        }

        // 4. Synchronise the changed contacts with the remote server. The callout
        //    is performed asynchronously because callouts are not allowed in the
        //    synchronous trigger context (and after a DML in the same transaction).
        ContactSyncQueueable.enqueue(updatedContacts);
    }

    /** Contacts directly related to the given accounts via AccountContactRelation. */
    private static Set<Id> findRelatedContactIds(Set<Id> accountIds) {
        Set<Id> contactIds = new Set<Id>();
        for (AccountContactRelation acr : [
            SELECT ContactId
            FROM AccountContactRelation
            WHERE AccountId IN :accountIds
        ]) {
            contactIds.add(acr.ContactId);
        }
        return contactIds;
    }

    /**
     * Among the candidate contacts, return those for which every related account
     * is canceled. We re-read ALL relations of each candidate (not only those on
     * the canceled accounts) so a contact still linked to an active account is
     * correctly kept active.
     */
    private static Set<Id> findContactsWithAllAccountsCanceled(Set<Id> contactIds) {
        // true  => so far every related account is canceled
        // false => at least one related account is still active
        Map<Id, Boolean> allCanceledByContact = new Map<Id, Boolean>();

        for (AccountContactRelation acr : [
            SELECT ContactId, Account.MissionStatus__c
            FROM AccountContactRelation
            WHERE ContactId IN :contactIds
        ]) {
            Boolean accountCanceled = acr.Account.MissionStatus__c == STATUS_CANCELED;
            Boolean current = allCanceledByContact.get(acr.ContactId);
            if (current == null) {
                allCanceledByContact.put(acr.ContactId, accountCanceled);
            } else if (current && !accountCanceled) {
                allCanceledByContact.put(acr.ContactId, false);
            }
        }

        Set<Id> result = new Set<Id>();
        for (Id contactId : allCanceledByContact.keySet()) {
            if (allCanceledByContact.get(contactId) == true) {
                result.add(contactId);
            }
        }
        return result;
    }

    /** Set IsActive__c = false on the contacts that are still active, and persist. */
    private static List<Contact> deactivateActiveContacts(Set<Id> contactIds) {
        List<Contact> toUpdate = new List<Contact>();
        for (Contact c : [
            SELECT Id, IsActive__c
            FROM Contact
            WHERE Id IN :contactIds AND IsActive__c = true
        ]) {
            c.IsActive__c = false;
            toUpdate.add(c);
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        return toUpdate;
    }
}
