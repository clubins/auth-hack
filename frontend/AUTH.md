# Authenticating the Flutter app (auth core)

> **Stub.** This documents the auth-core wiring from `feat/flutter-auth-core`;
> the docs task finalizes it into full runbooks.

The app speaks standard OIDC (discovery, authorization code + PKCE, RS256 via
JWKS) through the [`oidc`](https://pub.dev/packages/oidc) package, with all
tokens, PKCE verifiers, and session state persisted by
[`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage)
behind `lib/auth/token_store.dart`'s `TokenStore` interface.

## Configuration (`--dart-define`)

| Define | Default (local compose) | Production |
| --- | --- | --- |
| `CLUBINS_ISSUER` | `http://localhost:3301/oidc` | `https://login.clubins.de/oidc` |
| `CLUBINS_CLIENT_ID` | `clubins-flutter` | `clubins-flutter` |
| `CLUBINS_AUDIENCE` | `https://api.clubins.de` | `https://api.clubins.de` |
| `CLUBINS_REDIRECT_URI` | `clubins://login-callback` | `clubins://login-callback` |
| `CLUBINS_POST_LOGOUT_REDIRECT_URI` | `clubins://logout-callback` | `clubins://logout-callback` |

```sh
flutter run --dart-define=CLUBINS_ISSUER=https://login.clubins.de/oidc
```

Plain http is only accepted on loopback issuers; everything else must be
https (fail-fast validation in `AuthConfig`).

Requested scopes: `openid profile email offline_access` plus the API-resource
venue scope `https://api.clubins.de/venues:read`. The `offline_access` scope
is what enables silent refresh.

## Redirect setup (scheme `clubins://`)

The oidc package signs users in with an **external user agent** (RFC 8252 —
system browser / custom tab, never an embedded WebView), so the OS must hand
the `clubins://login-callback` and `clubins://logout-callback` redirects back
to the app.

1. **Logto side:** register both URIs as redirect / post-logout redirect URIs
   on the `clubins-flutter` application (the `idp/` seed scripts do this —
   see `idp/`).
2. **Android** — `android/app/src/main/AndroidManifest.xml`, inside
   `<activity>`:

   ```xml
   <intent-filter>
       <action android:name="android.intent.action.VIEW" />
       <category android:name="android.intent.category.DEFAULT" />
       <category android:name="android.intent.category.BROWSABLE" />
       <data android:scheme="clubins" android:host="login-callback" />
   </intent-filter>
   <intent-filter>
       <action android:name="android.intent.action.VIEW" />
       <category android:name="android.intent.category.DEFAULT" />
       <category android:name="android.intent.category.BROWSABLE" />
       <data android:scheme="clubins" android:host="logout-callback" />
   </intent-filter>
   ```

3. **iOS** — `ios/Runner/Info.plist`:

   ```xml
   <key>CFBundleURLTypes</key>
   <array>
     <dict>
       <key>CFBundleURLName</key>
       <string>de.clubins.app</string>
       <key>CFBundleURLSchemes</key>
       <array>
         <string>clubins</string>
       </array>
     </dict>
   </array>
   ```

   Info.plist is not seeded yet (the Android/iOS platform folders land with
   the first device build); the snippets above are the target state.

## Test boundary

Unit tests run against a mocked HTTP IdP and mocked platform interface —
no real IdP and no network in CI. The browser hop itself (external user
agent → redirect) is exercised in device tests once the platform folders
above exist.
