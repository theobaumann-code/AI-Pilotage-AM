# Pilotage NRR — SideCare

Application Rails 8.1 / Ruby 3.3.12 / PostgreSQL.

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
