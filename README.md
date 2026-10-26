# Pilotage NRR - SideCare

Application Rails 8.1 / Ruby 3.3.12 / PostgreSQL.

## Export des augmentations vers Analytics

`GET /api/internal/renewal-uplifts?campaign_year=2026` expose uniquement les
produits au statut **Augmenté**, avec leur taux négocié en pourcentage et les
champs de rapprochement entreprise / risque / collège / assureur. La campagne
doit correspondre à `AppSetting.annee_en_cours` ; les tarifs visent l’année
suivante. Aucun compte utilisateur ni ARR individuel n’est exporté.

Avec `include_in_progress=true`, les lignes confirmées restent dans `rows` ;
les produits **En cours** sont exportés séparément dans `inProgressRows` pour
la projection. `weighting` donne les ARR et gains agrégés par statut du tableau
NRR non filtré, afin d’expliquer sa moyenne sur une base constante. Les autres
statuts ne sont jamais exportés sous forme de lignes de contrat. L’export
sans ce paramètre conserve son format et son périmètre initiaux.

La route utilise un jeton dédié `ANALYTICS_RENEWAL_UPLIFTS_TOKEN`, configuré
uniquement sur Scalingo et transmis par Analytics dans l’en-tête Bearer.
Sans jeton configuré ou valide, elle répond 401. Elle ne permet aucune écriture.

## Connexion Google SSO

Le SSO Google utilise Devise et OmniAuth. Il retrouve le compte AM existant par
son adresse Google vérifiée. Le compte doit être actif et appartenir au Google
Workspace autorisé. Aucun compte n’est créé automatiquement ; les portefeuilles
et les droits administrateur existants sont conservés. Google est le seul moyen
de connexion ; les formulaires et la route de
connexion par mot de passe sont supprimés, ainsi que la stratégie Devise associée.

### Configuration Scalingo / Google Cloud

1. Utiliser le client dédié « SideCare Pilotage AM », de type « Application Web »,
   dans le projet Google Cloud `dogwood-method-256009`. Son identifiant est
   `26577008682-fgbvemqkplm21hmub9ck9ob0l8qafhu2.apps.googleusercontent.com`.
   Il autorise uniquement cette redirection :
   `https://ai-pilotage-am.osc-fr1.scalingo.io/users/auth/google_oauth2/callback`.
2. Configurer `AUTH_GOOGLE_ID` et `AUTH_GOOGLE_SECRET` sur Scalingo, puis redémarrer
   l’application. Ces noms reprennent ceux d’ai-finance-auto. Ne jamais committer
   les valeurs. Rails utilise son `SECRET_KEY_BASE` existant pour les sessions ;
   `AUTH_SECRET` d’auto-finance n’est pas nécessaire.
3. `AUTH_ALLOWED_DOMAIN` vaut `sidecare.com` par défaut. La réponse Google est
   contrôlée côté serveur (domaine Workspace et adresse vérifiée).
4. Facultatif : `AUTH_ALLOWED_EMAILS`, liste séparée par des virgules, restreint
   davantage l’accès. Si elle est absente ou vide, seuls les comptes AM actifs
   déjà présents sont autorisés. La liste Finance n’est pas recopiée.
5. Vérifier que chaque compte AM porte exactement son adresse Google principale.

Sans les deux identifiants OAuth, la connexion reste indisponible avec un message
explicite. Configurer et vérifier le client Google avant de déployer cette version.
Aucune migration de base de données n’est requise. Les anciennes sessions sont
invalidées : les utilisateurs doivent se reconnecter avec Google.
Le flux demande uniquement `openid,email,profile`, sans accès Drive/Gmail ni
stockage de jeton Google. Le démarrage utilise un POST protégé contre les CSRF ;
OmniAuth contrôle le paramètre OAuth `state` au retour.

### Validation

```sh
bundle install
RAILS_ENV=test bin/rails db:test:prepare
bin/rails test test/integration/google_sso_test.rb
bin/rails test
```

Les tests SSO utilisent des réponses Google simulées, sans vrais identifiants.
Après déploiement, vérifier avec un compte AM autorisé, un compte non autorisé,
et la déconnexion. L’aller-retour Google réel nécessite la configuration OAuth.

## Estimation de l'ARR des upsells

Les upsells ne reposent plus sur un montant fixe par salarié. L'application
normalise le SIRET/SIREN des produits existants du client, le rattache au BO via
Bonus Tracker, puis conserve le montant et les métadonnées renvoyés par son
moteur primes/ARR.

Configurer les deux variables suivantes avec le même secret interne que dans
Bonus Tracker :

```text
BONUS_TRACKER_UPSELL_ESTIMATOR_URL=https://<bonus-tracker>/api/internal/upsell-arr-estimate
BONUS_TRACKER_INTERNAL_TOKEN=<secret partagé>
```

Après la migration et la configuration, recalculer les lignes existantes avec
`bin/rails upsell_arr:refresh`. Une ligne non rattachée ou non valorisable est
affichée comme indisponible ; aucune moyenne fixe de secours n'est appliquée.

## Attribution portefeuille depuis la BI

La rubrique « Attribution portefeuille » prépare la campagne suivante à partir
de la BI (onglet par défaut). L'onglet « données brutes » conserve la campagne
en cours telle que saisie dans l'outil, jusqu'à sa clôture dans l'Historique.

- Un compte est un company set, ou un user pro rattaché à aucun set. Son AM est
  le responsable AM du company set s'il existe, sinon celui du user pro. Il est
  rapproché d'un utilisateur de l'outil par son e-mail ; un AM inconnu de
  l'outil apparaît en « Hors outil ».
- L'ARR est la commission SideCare (primes HT × taux de commission total) des
  contrats internes santé et prévoyance actifs, sur la facturation du T1 2026
  annualisée. Un contrat non facturé au T1 est annualisé sur ses trois derniers
  mois facturés depuis.
- « Comptes sans AM » liste les comptes sans AM de plus de 2 000 € d'ARR ; sous
  5 000 €, seulement ceux qui ont au moins un produit santé standard
  (`offer_kind` différent de 3, « sur mesure »).

La requête est dans `app/services/bi_portfolio_query.sql`. `BiPortfolioSyncJob`
la rejoue chaque jour à 11h et 17h (heure de Paris, `config/recurring.yml`,
exécuté par le process `worker`) et remplace la table `bi_accounts`. Un admin
peut aussi lancer « Synchroniser maintenant » depuis la page.

Variables Scalingo :

```text
BI_BIGQUERY_CREDENTIALS_JSON=<clé JSON du compte de service>
BI_BIGQUERY_PROJECT_ID=dogwood-method-256009   # défaut
BI_BIGQUERY_DATASET=BI_EU                      # défaut
BI_BIGQUERY_LOCATION=EU                        # défaut
```

Le compte de service n'a besoin que des rôles « BigQuery Data Viewer » sur le
dataset `BI_EU` et « BigQuery Job User » sur le projet.

Le compte dédié à cette application est
`pilotage-am-bi@dogwood-method-256009.iam.gserviceaccount.com`. Sa clé est
conservée dans `BI_BIGQUERY_CREDENTIALS_JSON` sur Scalingo, jamais dans Git.
La configuration Google Sheets utilise ses propres variables et reste indépendante.

### Déploiement et vérification

L'application Scalingo `ai-pilotage-am` se déploie par son dépôt Git direct ;
aucun lien GitHub automatique n'est configuré. Après validation et fusion :

```sh
git pull --ff-only origin main
git push scalingo main
scalingo --app ai-pilotage-am scale worker:1
scalingo --app ai-pilotage-am ps
```

Le hook `postdeploy` du `Procfile` applique les migrations avec
`bin/rails db:prepare` avant que Scalingo ne bascule le trafic vers la nouvelle
version. Un échec de migration fait échouer le déploiement. Vérifier
que `web` et `worker` sont tous deux démarrés, puis ouvrir « Attribution
portefeuille » et lancer « Synchroniser maintenant ». Le message de succès
doit indiquer le nombre de comptes importés et la page afficher la date de
dernière synchronisation. Le worker exécute ensuite les tâches de 11 h et
17 h, heure de Paris.
