# Épreuve technique Salesforce — Keobiz

Solution **100 % Apex**, déclenchée par un **Trigger** sur `Account`, sans aucune
fonctionnalité no-code (pas de Flow / Process Builder), **bulkifiée pour 200
entreprises** par transaction.

## Le problème

Lorsque le champ `Account.MissionStatus__c` passe à `canceled`, il faut :

- **(a)** renseigner `Account.MissionCanceledDate__c` avec la date du jour ;
- **(b)** pour chaque contact lié (via `AccountContactRelation`), si **toutes**
  ses entreprises sont annulées, passer son `Contact.IsActive__c` à `false` ;
- **(c)** synchroniser les contacts modifiés avec le serveur distant via l'API
  bulk `PATCH` fournie.

## Architecture

Le code suit le pattern **« un seul trigger par objet + classe handler »**, puis
une séparation en couches (orchestration / logique métier / appel distant) pour
que chaque responsabilité soit testable isolément.

```
AccountTrigger (before & after update)
        │
        ▼
AccountTriggerHandler
        │  before → (a) stamp MissionCanceledDate__c en mémoire
        │  after  → délègue les comptes nouvellement annulés
        ▼
ContactDeactivationService
        │  (b) détermine les contacts dont TOUTES les entreprises sont annulées
        │      et passe IsActive__c = false
        ▼
ContactSyncQueueable  (asynchrone, Database.AllowsCallouts)
        ▼
ContactSyncService    (c) construit le payload et envoie le PATCH bulk
```

| Fichier | Rôle |
|---|---|
| `triggers/AccountTrigger.trigger` | Point d'entrée, ne fait que router le contexte. |
| `classes/AccountTriggerHandler.cls` | Orchestration par contexte (before/after). |
| `classes/ContactDeactivationService.cls` | Règle métier « toutes les entreprises annulées » + DML contacts. |
| `classes/ContactSyncQueueable.cls` | Exécution asynchrone de l'appel distant. |
| `classes/ContactSyncService.cls` | Construction du payload JSON et appel HTTP `PATCH`. |
| `classes/ContactSyncHttpMock.cls` | Mock `HttpCalloutMock` réutilisable pour les tests. |
| `classes/AccountTriggerHandlerTest.cls` | Tests bout-en-bout (via DML sur le trigger). |
| `classes/ContactSyncServiceTest.cls` | Tests unitaires de la couche d'appel. |
| `objects/.../*.field-meta.xml` | Définition des 3 champs personnalisés. |
| `remoteSiteSettings/...` | Autorisation de l'endpoint pour le callout. |

## Choix de conception

- **`before update` pour la date (a).** Renseigner `MissionCanceledDate__c` sur
  l'enregistrement en cours de sauvegarde se fait en mémoire dans le contexte
  `before`, ce qui évite une instruction DML supplémentaire et tout risque de
  récursion.

- **`after update` pour les contacts (b).** Les enregistrements sont déjà
  persistés, donc une requête SOQL sur `AccountContactRelation` renvoie bien le
  statut `canceled` à jour des comptes concernés.

- **Détection « nouvellement annulé ».** On compare `Trigger.new` à
  `Trigger.oldMap` : on n'agit que sur les comptes qui *passent* à `canceled`.
  La logique est ainsi **idempotente** (un re-save d'un compte déjà annulé ne
  redéclenche rien).

- **Règle « toutes les entreprises annulées ».** Pour chaque contact candidat on
  relit **toutes** ses relations (pas seulement celles des comptes qui viennent
  d'être annulés) : un contact encore rattaché à une entreprise active reste
  actif.

- **Seuls les contacts encore actifs sont mis à jour.** On filtre sur
  `IsActive__c = true` pour éviter des DML et des callouts inutiles.

- **Callout asynchrone via `Queueable`.** Un trigger ne peut pas faire de callout
  de façon synchrone (a fortiori après un DML). `Queueable` (plutôt que
  `@future`) permet de passer une liste typée et implémente
  `Database.AllowsCallouts`.

- **Bulkification.** Aucune SOQL/DML/`enqueueJob` dans une boucle ; tout est
  basé sur des `Set`/`Map`. Le nombre de requêtes est constant quel que soit le
  volume → conforme à l'exigence des 200 entreprises.

- **Configuration de l'endpoint / token.** Exposés en constantes dans
  `ContactSyncService` pour garder l'exercice auto-suffisant et lisible. **En
  production**, l'idéal est un **Named Credential** (endpoint + auth) ou un
  **Custom Metadata Type / Custom Setting** protégé, afin de ne jamais coder en
  dur un secret et de rendre l'environnement configurable sans déploiement.

## Gestion des réponses de l'API

`ContactSyncService.sync(...)` renvoie le code HTTP. En cas de réponse différente
de `200` (les `400` / `401` / `404` documentés), l'erreur est journalisée avec un
message explicite (statut + corps). Dans une vraie mise en production, ce point
brancherait un mécanisme de retry et/ou un objet de log d'erreurs.

## Tests

- `AccountTriggerHandlerTest` : scénario nominal (un contact tout-annulé devient
  inactif, un contact encore lié à un compte actif reste actif), vérification de
  la date, idempotence, et **test bulk sur 200 comptes**. Les callouts sont
  simulés via `ContactSyncHttpMock` et s'exécutent au `Test.stopTest()`.
- `ContactSyncServiceTest` : forme exacte du payload (`id` / `is_active`),
  en-têtes (`PATCH`, `Authorization`, `Content-Type`), liste vide sans callout,
  et remontée des codes d'erreur.

## Déploiement

Projet au format Salesforce DX.

```bash
# Déployer la source
sf project deploy start --source-dir force-app

# Lancer les tests Apex
sf apex run test --code-coverage --result-format human --wait 10
```

Le `manifest/package.xml` liste l'ensemble des composants si un déploiement par
manifeste est préféré.
