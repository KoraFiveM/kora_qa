-- Friendly key names -> GTA control ids (pad 0) for `I press the {string} key`.
-- The client watches these controls (enabled or disabled) while the step is
-- current; keys not listed here can't be auto-verified and fall back to Done.
-- Default keyboard bindings; a player who rebinds a game control won't match.

QAKeys = QAKeys or {}

QAKeys.controls = {
    E = { 38, 51 }, F = { 23, 75 }, G = { 47, 58 }, H = { 74 }, K = { 311 }, L = { 182, 7 },
    M = { 244 }, N = { 249 }, X = { 73, 105 }, Z = { 20, 48 }, Y = { 246 }, B = { 29 },
    Q = { 44 }, R = { 45, 80 }, T = { 245 }, C = { 26, 79 }, U = { 303 }, V = { 0 }, W = { 32 },
    A = { 34 }, S = { 33 }, D = { 35 }, P = { 199 },
    TAB = { 37 }, ALT = { 19 }, LALT = { 19 }, SPACE = { 22, 76 }, ENTER = { 191, 201, 18 },
    BACKSPACE = { 177, 194 }, ESC = { 200, 322 }, ESCAPE = { 200, 322 },
    SHIFT = { 21 }, LSHIFT = { 21 }, CTRL = { 36 }, LCTRL = { 36 }, CAPSLOCK = { 137 },
    F1 = { 288 }, F2 = { 289 }, F3 = { 170 }, F5 = { 166 }, F6 = { 167 }, F7 = { 168 },
    F9 = { 56 }, F10 = { 57 }, F11 = { 344 },
    UP = { 172 }, DOWN = { 173 }, LEFT = { 174 }, RIGHT = { 175 },
    PAGEUP = { 10 }, PAGEDOWN = { 11 }, HOME = { 213 }, DELETE = { 178 }, INSERT = { 121 },
    ['1'] = { 157 }, ['2'] = { 158 }, ['3'] = { 160 }, ['4'] = { 164 }, ['5'] = { 165 },
    ['`'] = { 243 }, TILDE = { 243 },
    MOUSE1 = { 24 }, LMB = { 24 }, MOUSE2 = { 25 }, RMB = { 25 },
}

---Upper-cases and resolves aliases ("left alt" -> "ALT"). Returns nil for junk.
---The rules live in shared/catalog.lua (QACatalog.normalizeKey) so the panel's
---validator vectors cover them.
function QAKeys.normalize(name)
    return QACatalog.normalizeKey(name)
end

---Control ids for a key, or nil when it can't be watched.
function QAKeys.controlsFor(name)
    local key = QAKeys.normalize(name)
    return key and QAKeys.controls[key] or nil
end

return QAKeys
