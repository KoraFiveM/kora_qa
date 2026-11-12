-- kora_qa configuration. Shared with the client, so nothing secret lives here:
-- the panel URL and the shared secret are read server-side from convars.
--
--   set kora_qa_enabled 1                       -- default 0: the resource stays inert
--   set kora_qa_panel_url "http://127.0.0.1:47620/qa/game"
--   set kora_qa_secret "<KORA_QA_GAME_SECRET>"  -- never `sets`/replicated
--   add_ace group.admin kora_qa.tester allow    -- optional: in-game tester access without the panel

Config = Config or {}

Config.convars = {
    enabled = 'kora_qa_enabled',
    panelUrl = 'kora_qa_panel_url',
    secret = 'kora_qa_secret',
}
Config.defaultPanelUrl = 'http://127.0.0.1:47620/qa/game'

Config.command = 'qa'
Config.keybind = 'F9'

-- Who may run scenarios. A player is allowed when ANY of these holds:
--   * the panel says so (GET /tester?discordId=, cached for accessCacheSeconds)
--   * the ACE `ace` (e.g. add_ace group.admin kora_qa.tester allow)
--   * kora_lib permission level >= `level` (ACE prefix `prefix`, like kora_admin)
Config.access = {
    ace = 'kora_qa.tester',
    level = 'mod',
    levels = { 'god', 'admin', 'mod', 'user' },
    prefix = 'qbcore',
    adminLevel = 'admin', -- what @needs:admin requires
    accessCacheSeconds = 300,
}

-- Safety caps. Posted to the panel with the registry (validated at scan) and
-- re-validated by kora_qa right before every setup executes.
-- Arrays may be empty; itemAllow = nil means "any item not on itemDeny".
Config.caps = {
    maxItemCount = 50,
    maxMoney = 100000,
    maxEntities = 6,          -- spawned vehicles + peds + props per run
    maxWaitSeconds = 120,
    itemDeny = {},
    itemAllow = nil,
    modelDeny = { 'rhino', 'hydra', 'lazer', 'khanjali', 'oppressor', 'oppressor2', 'apc' },
    -- Commands kora_qa may run FOR the tester ("Run it for me"). The tester can
    -- always type any command themselves (their own permissions apply).
    allowCommands = {},
    accounts = { 'cash', 'bank', 'crypto' },
    metadataDeny = { 'jailitems', 'phone', 'licences', 'callsign', 'fingerprint', 'walletid', 'criminalrecord', 'citizenid' },
    weather = { 'CLEAR', 'EXTRASUNNY', 'CLOUDS', 'OVERCAST', 'RAIN', 'CLEARING', 'THUNDER', 'SMOG', 'FOGGY', 'XMAS', 'SNOW', 'SNOWLIGHT', 'BLIZZARD', 'HALLOWEEN', 'NEUTRAL' },
    inventoryTypes = { 'player', 'trunk', 'glovebox', 'stash', 'shop', 'drop', 'container', 'otherplayer' },
}

Config.run = {
    checkTimeoutMs = 8000,      -- auto-checks keep re-evaluating this long before failing
    checkIntervalMs = 500,
    clientExecTimeoutMs = 15000,
    setupCooldownMs = 750,
    teleportToleranceM = 12.0,
    defaultLocationRadius = 5.0,
    spawnDistance = 4.0,
    maxTimeline = 300,
    maxConsoleLines = 200,
}

Config.report = {
    screenshot = true,
    screenshotEncoding = 'jpg',
    screenshotQuality = 0.82,
    screenshotMaxWidth = 1280,
    screenshotMaxHeight = 720,
    screenshotTimeoutMs = 15000,
    noteMax = 2000,
    titleMax = 120,
}

Config.panel = {
    timeoutMs = 10000,
    scenarioRefreshSeconds = 300,
    queueFlushSeconds = 60,
    retestReminderDelaySeconds = 90,
}

-- Resources the ctl `restart` command refuses (kora_qa is always refused).
-- Matches the panel's PROTECTED_RESOURCES default; the panel checks first.
Config.protectedResources = { 'monitor', 'kora_qa' }

-- Runner app id (AppShell) — opens of this app are not recorded as test events.
Config.appId = 'kora_qa:runner'
