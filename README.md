# Pilotage NRR — SideCare

Application Rails 8.1 / Ruby 3.3.12 / PostgreSQL.

## Connexion Google SSO

Le SSO Google utilise Devise et OmniAuth. Il retrouve le compte AM existant par
son adresse Google vérifiée. Le compte doit être actif et appartenir au Google
Workspace autorisé. Aucun compte n’est créé automatiquement ; les portefeuilles
et les droits administrateur existants sont conservés. La connexion par mot de
passe reste disponible.

### Configuration Scalingo / Google Cloud

1. Créer un client OAuth Google de type « Application Web » (ou utiliser le client
   existant après ajout de cette URL) et autoriser exactement cette redirection :
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

Sans les deux identifiants OAuth, le bouton Google reste masqué et la connexion
par mot de passe fonctionne. Aucune migration de base de données n’est requise.
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
