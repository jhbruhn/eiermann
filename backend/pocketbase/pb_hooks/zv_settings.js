/// <reference path="../pb_data/types.d.ts" />

// App settings and users-collection auth, configured from the environment.
//
// Usage — an app registers it once, and owns nothing but its prefix:
//
//   onBootstrap((e) => {
//     e.next();  // let core finish bootstrapping before touching settings
//     require(`${__hooks}/zv_settings.js`).apply(e, {
//       envPrefix: "EIERMANN",
//       defaultName: "Eiermann",
//     });
//   });
//
// Every variable is read under the app's own prefix, e.g. `<P>_SMTP_HOST`,
// `<P>_OAUTH2_PROVIDERS`, `<P>_OAUTH2_<NAME>_CLIENT_ID`. Nothing here is
// domain: an operator configures mail, a proxy and identity providers the same
// way for either app, and the static brand name is set by migration.
//
// PocketBase runs each handler in an isolated JSVM context — which is why the
// app's wrapper builds its config literal INSIDE the handler.
//
// ── One PKCE detail is security-critical ────────────────────────────────────
// `pkce` is only set when the operator actually stated a preference.
// `ProviderConfig.PKCE` is a *bool: left unset, PocketBase keeps the provider's
// own default, which for generic OIDC is TRUE. Assigning `=== "true"`
// unconditionally wrote an explicit FALSE for every env-configured OIDC provider
// whose _PKCE var was merely absent — silently downgrading the framework
// default.
//
// That matters because mobile sign-in redirects to a CUSTOM SCHEME, which is not
// ownership-verified the way an App Link is: flutter_web_auth_2's exported
// CallbackActivity takes the redirect through ordinary system intent resolution
// on its non-AuthTab fallback path. Without PKCE nothing binds the authorization
// code to the app that started the flow, so another app on the device that
// claims the scheme can capture `code` and POST it to auth-with-oauth2 itself —
// PocketBase completes the exchange with the server-side client secret and hands
// back a session token for the victim's account. Account takeover, not just code
// disclosure.

/**
 * Applies the environment to app settings and the users collection.
 *
 * Call from onBootstrap AFTER `e.next()`, so core has loaded the settings.
 *
 * @param config {envPrefix, defaultName}
 */
function apply(e, config) {

  // PocketBase runs each handler in an isolated JSVM context — define every
  // helper the handler needs inside it.
  const prefix = String((config && config.envPrefix) || "");
  const defaultName = String((config && config.defaultName) || prefix);
  const logPrefix = prefix.toLowerCase() + ": ";
  const env = (k) => {
    const v = $os.getenv(prefix + "_" + k);
    return v && v !== "" ? v : "";
  };

  const settings = e.app.settings();
  let changed = false;

  // App URL — resolves {APP_URL} in email templates (e.g. the password-reset
  // link) and other absolute links. Without it mail points at localhost.
  const appURL = env("APP_URL");
  if (appURL && settings.meta.appURL !== appURL) {
    settings.meta.appURL = appURL;
    changed = true;
  }

  // SMTP — stays at PocketBase's disabled default unless a host is provided.
  const host = env("SMTP_HOST");
  if (host) {
    const port = parseInt(env("SMTP_PORT"), 10);
    settings.smtp.enabled = true;
    settings.smtp.host = host;
    settings.smtp.port = isNaN(port) ? 587 : port;
    settings.smtp.username = env("SMTP_USERNAME");
    settings.smtp.password = env("SMTP_PASSWORD");
    settings.smtp.tls = env("SMTP_TLS").toLowerCase() === "true";

    const senderAddress = env("SMTP_SENDER_ADDRESS");
    if (senderAddress) settings.meta.senderAddress = senderAddress;
    settings.meta.senderName =
      env("SMTP_SENDER_NAME") || settings.meta.appName || defaultName;
    changed = true;
  }

  // Trusted proxy — makes PB resolve the real client IP from the proxy's
  // forwarding header instead of the socket peer (the proxy itself), so
  // per-client-IP rate limits stay per client behind Caddy/nginx.
  const proxyHeaders = env("TRUSTED_PROXY_HEADERS")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s !== "");
  if (proxyHeaders.length > 0) {
    settings.trustedProxy.headers = proxyHeaders;
    settings.trustedProxy.useLeftmostIP =
      env("TRUSTED_PROXY_USE_LEFTMOST_IP").toLowerCase() === "true";
    changed = true;
  }

  if (changed) e.app.save(settings);

  // OAuth2 providers live on the users COLLECTION (not app settings). Register
  // any provider listed in <P>_OAUTH2_PROVIDERS whose client id + secret are
  // present. When the env lists providers it is the source of truth; leave it
  // unset to manage providers from the Admin UI instead.
  const providerNames = env("OAUTH2_PROVIDERS")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s !== "");

  const providers = [];
  for (const name of providerNames) {
    const up = name.toUpperCase();
    const clientId = env("OAUTH2_" + up + "_CLIENT_ID");
    const clientSecret = env("OAUTH2_" + up + "_CLIENT_SECRET");
    if (!clientId || !clientSecret) {
      e.app
        .logger()
        .warn(logPrefix + "oauth2 provider missing client id/secret", "provider", name);
      continue;
    }
    const p = { name: name, clientId: clientId, clientSecret: clientSecret };
    // Generic OIDC providers need the endpoint URLs; well-known ones don't.
    const authURL = env("OAUTH2_" + up + "_AUTH_URL");
    if (authURL) {
      p.authURL = authURL;
      p.tokenURL = env("OAUTH2_" + up + "_TOKEN_URL");
      p.userInfoURL = env("OAUTH2_" + up + "_USERINFO_URL");
      const displayName = env("OAUTH2_" + up + "_DISPLAY_NAME");
      if (displayName) p.displayName = displayName;
      // Only set `pkce` when the operator actually stated a preference.
      // `ProviderConfig.PKCE` is a *bool: left unset, PocketBase keeps the
      // provider's own default, which for generic OIDC is TRUE. Assigning
      // `=== "true"` unconditionally wrote an explicit FALSE for every
      // env-configured OIDC provider whose _PKCE var was merely absent —
      // silently downgrading the framework default.
      //
      // See the security note in this file's header for why that matters.
      const pkceEnv = env("OAUTH2_" + up + "_PKCE").toLowerCase();
      if (pkceEnv === "true" || pkceEnv === "false") {
        p.pkce = pkceEnv === "true";
      }
    }
    providers.push(p);
  }

  // Password auth can be turned OFF so OAuth2 is the only sign-in method (the
  // info endpoint then reports auth.password:false and the app hides the password
  // form). Default ON; only act when explicitly set, so we never silently lock an
  // operator out.
  const pwEnv = env("PASSWORD_AUTH").toLowerCase();
  const togglePassword = pwEnv === "true" || pwEnv === "false";

  if (providers.length === 0 && !togglePassword) {
    return; // nothing collection-level to apply
  }

  try {
    const users = e.app.findCollectionByNameOrId("users");
    if (providers.length > 0) {
      users.oauth2.enabled = true;
      users.oauth2.providers = providers;
    }
    if (togglePassword) {
      users.passwordAuth.enabled = pwEnv === "true";
    }
    e.app.save(users);
    e.app
      .logger()
      .info(
        logPrefix + "users auth configured from env",
        "oauth2Providers",
        providers.length,
        "passwordAuth",
        togglePassword ? pwEnv : "unchanged",
      );
  } catch (err) {
    e.app.logger().warn(logPrefix + "users auth config failed", "err", String(err));
  }
}

module.exports = { apply: apply };
