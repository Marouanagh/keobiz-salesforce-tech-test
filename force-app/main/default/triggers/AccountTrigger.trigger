/**
 * Single trigger on Account. Keeps no logic of its own: it only dispatches the
 * relevant context to AccountTriggerHandler. This "one trigger per object +
 * handler" pattern keeps the order of execution predictable and the logic
 * testable in isolation.
 */
trigger AccountTrigger on Account (before update, after update) {
    if (Trigger.isUpdate) {
        if (Trigger.isBefore) {
            // (a) Stamp the cancellation date in-memory before save (no extra DML).
            AccountTriggerHandler.handleBeforeUpdate(Trigger.new, Trigger.oldMap);
        } else if (Trigger.isAfter) {
            // (b) + (c) Propagate to contacts and synchronise once the records are persisted.
            AccountTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}
