/// <reference path="../pb_data/types.d.ts" />

// eiermann — from zugvogel's template. The library holds the reasoning.
//
// App settings, SMTP, trusted proxy and users-collection auth, all from the
// environment. zv_settings.js holds the reasoning, including the PKCE default
// that must not be written explicitly.

onBootstrap((e) => {
  // Let core finish bootstrapping (settings loaded) before touching them.
  e.next();
  require(`${__hooks}/zv_settings.js`).apply(e, {
    envPrefix: "EIERMANN",
    defaultName: "Eiermann",
  });
});
