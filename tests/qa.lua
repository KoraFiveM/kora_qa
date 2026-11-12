-- kora_qa's shared aliases. Every resource may ship its own tests/qa.lua; a
-- scenario looks names up in its own resource first, then here, and
-- "resource:name" picks another resource's alias explicitly.
--
-- This file runs in a sandbox with NO globals (no vector3, no exports, no
-- functions from the game): return plain tables only.
return {
    locations = {
        -- x, y, z, h (heading) and r (radius in metres for "I go to"/"I should be at", default 5)
        legion_square = { x = 195.17, y = -933.77, z = 30.69, h = 144.5, r = 8.0 },
        legion_fountain = { x = 179.42, y = -963.23, z = 29.99, h = 330.0, r = 6.0 },
        pillbox_entrance = { x = 298.66, y = -584.42, z = 43.26, h = 70.0 },
    },
    vehicles = {
        test_car = 'sultan',
        test_bike = 'bati',
    },
    peds = {
        shopkeeper = 'mp_m_shopkeep_01',
    },
    props = {
        bench = 'prop_bench_01a',
    },
    fixtures = {
        -- A fixture is a list of setup steps by id + positional args (same caps apply).
        picnic = {
            description = 'Two waters, a sandwich and 500 cash',
            steps = {
                { step = 'items.have', args = { 2, 'water' } },
                { step = 'items.have', args = { 1, 'sandwich' } },
                { step = 'money.set', args = { 'cash', 500 } },
            },
        },
    },
}
