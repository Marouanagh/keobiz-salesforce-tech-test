# Keobiz — Épreuve technique Salesforce

## Architecture

Le code suit le pattern **un trigger par objet + handler**, avec une séparation en trois couches :

```
AccountTrigger
    ├── before update → AccountTriggerHandler  (stamp de la date, sans DML supplémentaire)
    └── after update  → AccountTriggerHandler
                            └── ContactDeactivationService  (logique métier + DML contacts)
                                    └── ContactSyncQueueable  (job asynchrone)
                                            └── ContactSyncService  (appel HTTP)
```

## Choix techniques

**`before` pour la date** — la valeur est écrite directement sur l'enregistrement en mémoire, sans DML supplémentaire.

**Détection "nouvellement annulé"** — on compare `Trigger.new` à `Trigger.oldMap` pour n'agir que sur les comptes qui *passent* à `canceled`. Un re-save d'un compte déjà annulé ne redéclenche rien.

**Relecture de toutes les relations** — pour vérifier qu'un contact a bien *toutes* ses entreprises annulées, on relit l'ensemble de ses `AccountContactRelation`, pas uniquement celles des comptes concernés par le trigger. Un contact encore lié à une entreprise active reste actif.

**Queueable pour le callout** — Salesforce interdit les callouts synchrones après un DML dans la même transaction. Le job `Queueable` (plutôt que `@future`) permet de passer une liste typée et implémente `Database.AllowsCallouts`.

**Bulkification** — aucune SOQL/DML dans une boucle. Le nombre de requêtes est constant quel que soit le volume, ce qui garantit le respect des governor limits sur 200 comptes.
