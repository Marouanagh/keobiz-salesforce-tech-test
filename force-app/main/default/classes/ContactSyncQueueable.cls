/**
 * Asynchronous wrapper around the contact synchronisation callout.
 *
 * Why Queueable?
 *  - A trigger runs synchronously and cannot perform a callout right after a DML
 *    in the same transaction. We therefore defer the callout to an async job.
 *  - Queueable (over @future) lets us pass a strongly-typed list of records and
 *    chain/observe the job easily, and supports Database.AllowsCallouts.
 */
public with sharing class ContactSyncQueueable implements Queueable, Database.AllowsCallouts {

    private final List<Contact> contactsToSync;

    public ContactSyncQueueable(List<Contact> contactsToSync) {
        this.contactsToSync = contactsToSync;
    }

    /**
     * Convenience entry point. Nothing is enqueued for an empty list so we never
     * waste an async job.
     */
    public static void enqueue(List<Contact> contactsToSync) {
        if (contactsToSync != null && !contactsToSync.isEmpty()) {
            System.enqueueJob(new ContactSyncQueueable(contactsToSync));
        }
    }

    public void execute(QueueableContext context) {
        ContactSyncService.sync(contactsToSync);
    }
}
