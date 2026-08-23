# Changelog

## [1.1.0](https://github.com/jhbruhn/eiermann/compare/v1.0.0...v1.1.0) (2026-08-23)


### Features

* **auth:** sign in through an identity provider ([5317004](https://github.com/jhbruhn/eiermann/commit/531700460c5f2de3e34a5b4e52119685f001d934))


### Bug Fixes

* **auth:** let a sign-in through an identity provider create its account ([d252263](https://github.com/jhbruhn/eiermann/commit/d252263f9f819ad301c186fde3db126bd14ee6e4))

## [1.0.0](https://github.com/jhbruhn/eiermann/compare/v0.1.0...v1.0.0) (2026-08-23)


### ⚠ BREAKING CHANGES

* zurück auf Flutter 3.44.3, zugvogel-Pin auf 030c35a
* **areas:** Ein Client, der pins_need_review nicht senken kann, kann einen Bereich nach einem Fotowechsel nicht mehr aus der Warnung holen.
* **nests:** nest_state — the dossier's nest list in one query
* **spots:** the pin is the location, the address is a label
* **hooks:** hooks no longer send user-facing messages. A client that displayed `message` must map `data` keys to its own strings.

### Features

* **android:** signed APKs in the release job, universal and per ABI ([ad87804](https://github.com/jhbruhn/eiermann/commit/ad878045a4290ff8261ad939ba8fbc8616f79d66))
* **app:** one account menu and a management hub, after federfall ([0ca72e3](https://github.com/jhbruhn/eiermann/commit/0ca72e34733326cddf7dc07063447d1cac475ce4))
* **areas:** Area model and AreasRepository ([5d17b85](https://github.com/jhbruhn/eiermann/commit/5d17b858aee8af29292e295a99bbf6a542c57081))
* **areas:** Bereichsfoto aufnehmen, zuschneiden, hochladen ([efce069](https://github.com/jhbruhn/eiermann/commit/efce069dd47c1d8b164a5a3b7950b58041cbecad))
* **areas:** der Fotowechsel ist ein Prüfdurchlauf, kein Feld-Update ([be857ae](https://github.com/jhbruhn/eiermann/commit/be857ae4992b10204499eb1e76c3b3ac7e84a08c))
* **areas:** die Pins stehen auch auf dem Vorschaufoto im Dossier ([3b17cf9](https://github.com/jhbruhn/eiermann/commit/3b17cf9436f6fb7ce4b0f653bcfd4ab6395a7991))
* **audit:** who changed what, and what it used to say ([0abe583](https://github.com/jhbruhn/eiermann/commit/0abe58332095c153ed33a10906586abb075b548e))
* **auth:** OIDC als optionaler Pfad — Mock-Provider, Umgebungsdoku, Hook ([9174100](https://github.com/jhbruhn/eiermann/commit/91741001cc48dfb82ccb575520c91fd5fabdf862))
* **backend:** areas, nests, the protected-species guard, delete-effect registry ([f000c40](https://github.com/jhbruhn/eiermann/commit/f000c4052aaaa3d74f5f22b78a0a9023362d1d79))
* **backend:** species_labels — das Vokabular waechst aus dem Gebrauch ([2f5bf88](https://github.com/jhbruhn/eiermann/commit/2f5bf88b50f02c442f6a64fc98faa359beb3aa2f))
* **backend:** spots, contacts and the overview view ([0f48d52](https://github.com/jhbruhn/eiermann/commit/0f48d52c6f853a4698665e75520c3827fdf1559a))
* **backend:** the Spot lifecycle, enforced by a hook ([4940c0b](https://github.com/jhbruhn/eiermann/commit/4940c0b6110110cf2e39ed507e66abd24693a12c))
* **backend:** the visit transaction and the rhythm — Phase 04's cut ([8f55233](https://github.com/jhbruhn/eiermann/commit/8f55233d9d91ee01571434dd917c8a84c2c18b50))
* **data:** spot repositories, with a keyset the view can actually resume ([425a640](https://github.com/jhbruhn/eiermann/commit/425a640f36efb5aba9fcbb5e9682621e44a3070e))
* **findings:** bauliche Veraenderung bietet das Schliessen an — danach ([adc6d25](https://github.com/jhbruhn/eiermann/commit/adc6d25667e73ba4ff68a3fa65793c19c08b0807))
* **findings:** Funde im Besuchsablauf — im selben Body wie die Pruefungen ([d7ff66a](https://github.com/jhbruhn/eiermann/commit/d7ff66a7d94d5b3f807602cc99d2edc9c40e1855))
* **history:** eine Chronologie — Besuche, Pruefungen, Funde, plus die Zahl ([205a9bb](https://github.com/jhbruhn/eiermann/commit/205a9bba1c8e8273cf312275570544c45823be2f))
* **hooks:** refuse with a code, let the client write the sentence ([fa3cc32](https://github.com/jhbruhn/eiermann/commit/fa3cc322998dd08135a3e55f14fbbd5f781a9252))
* **l10n:** every string exists in both languages, and a sweep keeps it that way ([c4dfd0a](https://github.com/jhbruhn/eiermann/commit/c4dfd0a6f7f2745f2e03ab4f6fb933628bcff393))
* **models:** Spot, SpotContact and SpotOverview ([4b8d908](https://github.com/jhbruhn/eiermann/commit/4b8d908a99af5425511c19e04b6185e822586640))
* **nav:** Karte, Liste und Dashboard als Ziele einer adaptiven Leiste ([4bfa99f](https://github.com/jhbruhn/eiermann/commit/4bfa99f411679ec6b030b61ce720c3e007587a43))
* **nests:** die Nestliste im Dossier — Inhalt und Alter, dringend zuerst ([3a0d50d](https://github.com/jhbruhn/eiermann/commit/3a0d50daf81f21f9f118dbe9c0251b78c56b780e))
* **nests:** eigenes Nestfoto — und ein Weg hinein, der keinen Pin braucht ([ec1046c](https://github.com/jhbruhn/eiermann/commit/ec1046c3c8ca2e81971108d47874374e76b9ed80))
* **nests:** Nest model and NestsRepository ([26092e2](https://github.com/jhbruhn/eiermann/commit/26092e26db3a631be4a44fc80030dcb7efe258da))
* **nests:** nest_state — the dossier's nest list in one query ([46fcba0](https://github.com/jhbruhn/eiermann/commit/46fcba04975e3992e7a4c96dbf1cf10432a369fd))
* **nests:** Pins setzen und verschieben, auf dem Bereichsfoto ([9836585](https://github.com/jhbruhn/eiermann/commit/9836585109750896d79736309fa45e58488bf2c3))
* **nests:** refuse a pin on a Bereich that has no photo ([2769042](https://github.com/jhbruhn/eiermann/commit/2769042303a7260d6c03f48d21d7e90c7a15a8f5))
* **reports:** die Berichtstabelle steht einmal, drei Rahmungen lesen sie ([ba3695f](https://github.com/jhbruhn/eiermann/commit/ba3695fae101c9d3a9b265a66670facc895866c7))
* **reports:** Statistikscreen und Export — der Client aggregiert nichts ([9e44138](https://github.com/jhbruhn/eiermann/commit/9e4413806d242d3bc64997a40a1dd82b23f46fba))
* **rhythm:** eine Zeile sagt den Tageszaehler, nicht den Rangnamen ([6da444e](https://github.com/jhbruhn/eiermann/commit/6da444eb11816770acde492dbefaebdd9a1c0b10))
* **rhythm:** the numbers behind every due date are editable ([2efbec1](https://github.com/jhbruhn/eiermann/commit/2efbec1bf9938dbe896699cbb1a168211364ef74))
* **species:** Artbezeichnung als Freitext, mit Vorschlaegen aus dem Gebrauch ([fb74ec8](https://github.com/jhbruhn/eiermann/commit/fb74ec82c8cda1779c2065a3da050026ca8378f2))
* **spots:** a paused Spot comes back by itself ([352f379](https://github.com/jhbruhn/eiermann/commit/352f379ee1fa6c37cccd455058534d024fe50b41))
* **spots:** a pin, and the difference between guessing it and standing there ([955ffec](https://github.com/jhbruhn/eiermann/commit/955ffec502056b7e69fa299eb5da115e13de8ece))
* **spots:** Erkundungsfunnel als eigener Screen, nach Stufe gruppiert ([e514071](https://github.com/jhbruhn/eiermann/commit/e514071c0816f3ed07691f9986a86f808478fff9))
* **spots:** geocoding through our own proxy, and a way to configure it ([82e1fd0](https://github.com/jhbruhn/eiermann/commit/82e1fd0394c7b610eca99b7d46d4d30e7e4e54e6))
* **spots:** Karte mit Filterchips, entprellter Suche und "in meiner Nähe" ([f4deff1](https://github.com/jhbruhn/eiermann/commit/f4deff1c10472104505afa5c674a44bd9e9f0105))
* **spots:** placing a pin fills the address fields that are still empty ([c4627f9](https://github.com/jhbruhn/eiermann/commit/c4627f9daeb0763816d4395a60e6793903e3887a))
* **spots:** the handover half — one tap to the access note, and a way out for a wrong number ([f2b5f00](https://github.com/jhbruhn/eiermann/commit/f2b5f0043c4b13cea25babc26d2c97e42e8855ea))
* **spots:** the list, the dossier and the two sheets ([22ff63e](https://github.com/jhbruhn/eiermann/commit/22ff63e99d6183ad924d8f8b3049c168458b3040))
* **spots:** the map — one query, urgency in colour and shape, clustering that earns its place ([9529fcb](https://github.com/jhbruhn/eiermann/commit/9529fcbb2bd493987f08d4081455db139bfe9c37))
* **spots:** the phase chip offers the moves, and the dialogs collect the reason ([152512c](https://github.com/jhbruhn/eiermann/commit/152512c5ce8ad2c58ea52720bf9a579dc28a4344))
* **spots:** the pin is the location, the address is a label ([1edabb4](https://github.com/jhbruhn/eiermann/commit/1edabb4ab059a8e6bdc2a822acf3a16ebb1aa27d))
* **spots:** the pin picker opens where the person is standing ([e55d5cd](https://github.com/jhbruhn/eiermann/commit/e55d5cd60c489aea75c753ec334579335f11e420))
* **spots:** the Spot list can be narrowed to one urgency rank ([a388022](https://github.com/jhbruhn/eiermann/commit/a3880222bc3d33879e2e919970d7c27cb773eb5a))
* **team:** invite, admit, end access — the same logic as federfall ([b5b1e1f](https://github.com/jhbruhn/eiermann/commit/b5b1e1fc258ad28b7bfb23ff3d1739dd720f2746))
* the Phase 01 foundation — app, schema, hooks, and a green rule suite ([67e42b8](https://github.com/jhbruhn/eiermann/commit/67e42b890f0e095af866e8240779549e4e1251f9))
* **tours:** Phase 05 — "Tour 1 starten" funktioniert wortwörtlich ([e58c0b4](https://github.com/jhbruhn/eiermann/commit/e58c0b498c6c17462b689aa9dd9ecc831c6c9d36))
* **visits:** das Uebersichtsfoto ist die Arbeitsflaeche im Besuchsablauf ([a222ba4](https://github.com/jhbruhn/eiermann/commit/a222ba447b0396d455ed9e5a7f3f222c71b793de))
* **visits:** Phase 04 ist durch — Gelege, Besuch, Rhythmus in der Hand ([39d3e8e](https://github.com/jhbruhn/eiermann/commit/39d3e8e7a6172511d4c2616f1888555dbb080e28))


### Bug Fixes

* **docker:** the shipped image had no way in on its first boot ([752f9a0](https://github.com/jhbruhn/eiermann/commit/752f9a02e2d1fa886685ff8a183bdfdc39417f34))
* **hooks:** the geocode proxy never worked, and nothing noticed ([ff774a6](https://github.com/jhbruhn/eiermann/commit/ff774a69f55d08a54662c54ac29548813f663131))
* **ios:** the three usage descriptions without which the app crashes ([b1c9e75](https://github.com/jhbruhn/eiermann/commit/b1c9e75f93fd191e6fdcbaab50d3df26277c8f9e))
* **rhythm:** das Faelligkeitsfenster ist ein Viertel des Intervalls, keine Woche ([bcee980](https://github.com/jhbruhn/eiermann/commit/bcee980c7281d6e1aa8b02732efaf9c2df12da63))
* **spots:** a phase change re-derives the due date ([e0c01d1](https://github.com/jhbruhn/eiermann/commit/e0c01d1d967207b36e8b826e114726b33b3fc4b3))
* **spots:** a Spot added from the map now appears on the map ([90a130b](https://github.com/jhbruhn/eiermann/commit/90a130b70e4f4f0c558606227f19e545aed3c126))
* **spots:** the edit sheet now says WHY a save was refused ([e5d8d8b](https://github.com/jhbruhn/eiermann/commit/e5d8d8b3c659e72f99786ba73e69b10439dce0cc))
* **web:** no character and no font family the app does not serve itself ([59c6746](https://github.com/jhbruhn/eiermann/commit/59c6746a50f839965dfed8b04b5500fd1e039cca))


### Reverts

* **feld:** the field handbook belongs to a human, not to me ([736138b](https://github.com/jhbruhn/eiermann/commit/736138bfbc39e92bc32f7078c40a077ab11779d5))


### Build System

* zurück auf Flutter 3.44.3, zugvogel-Pin auf 030c35a ([785450f](https://github.com/jhbruhn/eiermann/commit/785450f4891e396330d7b108fb44dc9e7f6147fb))
