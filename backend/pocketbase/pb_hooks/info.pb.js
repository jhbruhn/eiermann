/// <reference path="../pb_data/types.d.ts" />

// eiermann — from zugvogel's template. The library holds the reasoning.
//
// Unauthenticated identity & capability discovery. zv_info.js holds the payload
// and every reason behind it; the route path has to name the service, which is
// what makes the two apps' backends distinguishable.

routerAdd(
  "GET",
  "/api/eiermann/info",
  (e) =>
    require(`${__hooks}/zv_info.js`).respond(e, {
      service: "eiermann",
      envPrefix: "EIERMANN",
      defaultName: "Eiermann",
      // A Zugvogel instance is invite-only; users are created by supervisors.
      selfSignup: false,
    }),
  // Unauthenticated: the client hits this before any login exists.
);
