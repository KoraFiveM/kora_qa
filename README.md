# kora_qa

In-game runner for Gherkin test scenarios, backed by the QA panel
(`kora-qa-panel`). Replaces kora_lib-playground's `/test` and `/fb`.
Contracts: `/home/DevTestingKora/kora/QA-CONTRACTS.md` (§5 game API, §6 formats, §8 Kora.qa).

## Server config

```
set kora_qa_enabled 1                                   # default 0: inert
set kora_qa_panel_url "http://127.0.0.1:47620/qa/game"  # default
set kora_qa_secret "<KORA_QA_GAME_SECRET>"              # use `set`, never `sets`
add_ace group.admin kora_qa.tester allow                # optional: access without the panel
```

Testers: anyone the panel's `GET /tester` allows, or with the `kora_qa.tester`
ACE, or kora_lib permission level `mod`+ (`Config.access`). Caps live in
`config.lua` (`Config.caps`) and are posted to the panel with the registry.

## In game

`F9` or `/qa` opens the runner: **Scenarios** (filter by resource/tag),
**Run** (steps with live status, Set up / Run all setup, Done / Pass / Fail,
Dispute on automatic results, Report the failure, Can't run this, Abort),
**Report issue** (freeform, replaces `/fb`), **Retests**, **My runs**.
While a run is active a compact steps overlay stays on screen.
Shortcuts: `/qa setup | done | pass | fail <text> | skip | abort | hud | report`.

Every setup is executed server-side from the scenario the panel served,
re-validated against the caps, logged with the run id, and undone when the run
ends (items, money, job/gang/duty, metadata, spawned entities, lock state,
time/weather, position).

## Writing scenarios

`<resource>/tests/*.feature`, opted in with `qa_feature 'tests/*.feature'` in
the fxmanifest. The step library is `shared/steps.json` (id, pattern, kind,
args with caps, example). Anything the library can't express: `When I manually: …`
/ `Then I confirm: …`.

Step library v2 (from the legacy conversion's unmapped phrases) adds, among others:
`I press the "F7" key` (auto for common keys via game controls, see `shared/keys.lua`; other keys → Done),
engine on/off (setup, `I turn the engine on|off`, `the vehicle engine should be running|off`),
`the chat should show "…"` (kora_chat client events), `the HUD should be visible|hidden`,
`the seatbelt indicator should be on|off`, `the minimap should be visible|hidden`,
`the "<app id>" app should be open`, progress bar / text UI / notification title & type checks,
`the server console should show "…"`, metadata deltas, `the "<mark>" mark fires with "<field>" = "<value>"`
and `… mark fires within N seconds`. Things kora_qa can't read are explicit manual Pass/Fail steps:
`the HUD should show "…"`, `the F8 console should show "…"`, `the F8 console should show no errors`.

Real AppShell app ids and menu titles (static scan of every resource) are in
`shared/ui-ids.json` — use them with `the "<id>" app opens` / `the "<id>" app should be open`
and `a menu titled "<title>" opens` (e.g. MDT `qbmdt:terminal`, job roster `qbmultijob:roster`).

Places ("the fishing zone", "the crypto exchange", "the police duty point"): add a location
alias with a radius to that resource's `tests/qa.lua` and use `I am at "<alias>"` (setup),
`I go to "<alias>"` (observed) or `I should be at "<alias>"` (check).

Aliases: `<resource>/tests/qa.lua` returns plain tables (sandboxed, no globals):

```lua
return {
    locations = { pier = { x = -1850.5, y = -1231.2, z = 13.0, h = 90.0, r = 6.0 } },
    vehicles = { boat = 'dinghy' }, peds = { buyer = 'a_m_y_business_01' }, props = { crate = 'prop_box_wood02a' },
    fixtures = { ready = { steps = { { step = 'items.have', args = { 1, 'fishingrod' } } } } },
}
```

Scenarios look names up in their own resource, then kora_qa's `tests/qa.lua`;
`"resource:name"` is explicit.

## Hooks

- `Kora.qa.mark('fishing:caught', data)` (client or server) → `When the "fishing:caught" mark fires`.
- kora_lib reports notifications, AppShell/menu opens, progress bars, text UI,
  `Kora.callback` results and `Kora.commands` use for active testers automatically.
- kora_target marks `target:option` ({label, name, resource}) when an option is selected,
  which completes `When I select the "<label>" target option`.
- Custom steps (server): `exports.kora_qa:registerStep({ id = 'fishing.rod', pattern = 'I have a fishing rod ready',
  kind = 'setup', side = 'server', description = '…', args = {}, setup = function(src, params) return true, 'detail', undoData end,
  revert = function(src, undoData) end })`. Checks: `check = function(src, params) return ok, actual, expected end`.

## Panel ⇄ server

- Outbound (server only): `PerformHttpRequest` with `Authorization: Bearer <kora_qa_secret>`;
  screenshots are captured with `Kora.screenshot.requestClient` into `queue/shots/`
  and streamed by `server/upload.js`. Undeliverable results go to `queue/*.json`
  and are replayed in order when the panel answers again.
- Inbound: `POST http://127.0.0.1:30120/kora_qa/ctl` (loopback + bearer):
  `restart <name>` (`ensure`, never kora_qa/protected), `notify <discordId>`, `reload`.

## Tests

`test/run.sh` — syntax-checks every Lua file and runs the plain-Lua smoke tests
(uses kora_lib's `test/harness.lua` + `test/mocks.lua`; `KORA_LIB_TEST` overrides the path).
