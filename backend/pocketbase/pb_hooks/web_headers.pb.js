/// <reference path="../pb_data/types.d.ts" />

// eiermann — from zugvogel's template. The library holds the reasoning.
//
// Security headers for the SPA and for uploaded files. zv_web_headers.js holds
// the policy and the reasoning — including why the CSP is load-bearing for the
// web build's token storage and not merely defence in depth.

routerUse((e) =>
  require(`${__hooks}/zv_web_headers.js`).apply(e, { envPrefix: "EIERMANN" }),
);
