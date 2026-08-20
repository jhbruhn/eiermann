# Eiermann

Gelegemanagement für Stadttauben — the field app for replacing eggs with dummies
in city pigeon nests, and for knowing which roof to climb next.

It exists to solve three problems that a WhatsApp thread cannot: nobody knows the
last state of a nest, a **Halbgelege** (a partial clutch — one real egg still in
the nest after a swap) gets forgotten, and handing a route to somebody else is
painful. See `docs/concept.html` for the full concept and `docs/concept-digest.md`
for the implementation digest.

## Running it

```bash
# The backend, on 8091 (8090 is often taken by a sibling project's stack)
EIERMANN_PORT=8091 docker compose up -d

# The app against it
cd apps/eiermann
flutter run --dart-define-from-file=dart_defines/development.json \
            --target lib/main_development.dart
```

The dev stack bootstraps a coordinator — `dev@eiermann.local` /
`DevPass12345!` — so a fresh `docker compose up` is immediately usable. Those
credentials are in a committed file; never use them anywhere real.

## Layout

```
apps/eiermann/          the Flutter app (android, ios, linux, web)
packages/eiermann_models/   domain models + PocketBase mappers, pure Dart
packages/eiermann_data/     the repository layer, pure Dart
backend/pocketbase/
  pb_migrations/        the schema. A migration is a historical fact — never edited
  pb_hooks/             this app's hooks, plus the shared zv_* libraries
  tests/                the rule suite, against a live throwaway instance
```

The generic half of all of this — the repository base, the PocketBase
connection, the shared widgets, the hook libraries — lives in
[zugvogel](https://github.com/jhbruhn/zugvogel) and is pinned by commit hash.
What stays here is what knows about eggs.

## Testing

```bash
flutter analyze                              # the whole workspace, from the root
(cd apps/eiermann && flutter test)
(cd packages/eiermann_models && dart test)
backend/pocketbase/tests/run.sh              # rule + hook suite, needs docker
```

The rule suite is the one to run before touching anything about access. It builds
a throwaway PocketBase, applies the migrations and asserts the security model —
including the privilege escalations that the access rules alone cannot prevent.

## Licence

AGPL-3.0. See `LICENSE`.
