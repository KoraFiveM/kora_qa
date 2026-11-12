fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'kora_qa'
author 'Jamie'
version '0.1.0'
description 'In-game Gherkin test runner for the QA panel (replaces kora_lib-playground /test and /fb)'

dependency 'kora_lib'
dependency 'kora_core'

-- This resource ships its own example scenario (see tests/self.feature).
qa_feature 'tests/*.feature'

shared_scripts {
    '@kora_lib/init.lua',
    'config.lua',
    'shared/keys.lua',
    'shared/catalog.lua',
}

-- steps.json is read server-side only (LoadResourceFile); the client gets
-- everything it renders from the server.
client_scripts {
    'client/exec.lua',
    'client/ui.lua',
}

server_scripts {
    'server/util.lua',
    'server/panel.lua',
    'server/registry.lua',
    'server/game.lua',
    'server/steps.lua',
    'server/runs.lua',
    'server/engine.lua',
    'server/observers.lua',
    'server/main.lua',
    'server/upload.js',
}
