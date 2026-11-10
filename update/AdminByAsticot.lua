-- Admin by Asticot v1.1.2: single mod (install on EVERY PC, both players and host).
--  * Admin IDs: the fixed ID (MY_ID) replaces the first admin slot; the Steam account
--    launching the game (automatically detected) replaces the second; another fixed ID
--    (THIRD_ID) fills the third. The three protected IDs never overwrite one another.
--  * Force Admin / Admin Cheat (and GM.Cheat on the host).
--  * Log debug-panel actions (Page Up / Page Down / R / arrow keys).
--  * Game shortcuts F1-F7: start, stop, reset, heal and other game actions.
--  * F8: status | F9: reapply admin IDs.
--  * J: refill a held game item | K: diagnostic information.
-- Intended for private sessions involving your own accounts.

local TAG = "[ADMIN] "
local VERSION = "1.1.2" -- increase this number for each update
print(TAG .. "Admin by Asticot v" .. VERSION .. " loaded\n")

-- Shared tables: each module section registers its commands and status providers
-- for the file bridge to the external launcher (see EXTERNAL BRIDGE at the end).
local BRIDGE_COMMANDS = {}
local BRIDGE_STATUS_PROVIDERS = {}
local ITEM_CATALOG_PROVIDER = nil
local GRAB_SET_HELD = nil

-- ===== SETTINGS =====
local MY_ID             = "76561199784972417" -- mode 1: fixed Steam ID 64
local USE_FIXED_ID      = true  -- mode 1: insert MY_ID in the admin list
local USE_AUTO_ID       = true  -- mode 2: automatically detect the Steam account on this PC
local THIRD_ID          = "76561199639774585" -- mode 3: second fixed ID (third admin slot)
local USE_THIRD_ID      = true  -- mode 3: insert THIRD_ID in the admin list
local FIXED_SLOT        = 1     -- position of the fixed ID (1-based)
local AUTO_SLOT         = 2     -- position of the detected ID
local THIRD_SLOT        = 3     -- position of the second fixed ID
local FORCE_ADMIN_FLAGS = true  -- force Admin and Admin Cheat flags before debug actions
-- ====================

local MEC_FUNCS = {
    "InpActEvt_IA_DebugMenu_K2Node_EnhancedInputActionEvent_35",
    "InpActEvt_IA_DebugHeal_K2Node_EnhancedInputActionEvent_34",
    "InpActEvt_IA_DebugUp_K2Node_EnhancedInputActionEvent_33",
    "InpActEvt_IA_DebugDown_K2Node_EnhancedInputActionEvent_32",
    "InpActEvt_IA_DebugLeft_K2Node_EnhancedInputActionEvent_31",
    "InpActEvt_IA_DebugRight_K2Node_EnhancedInputActionEvent_30",
    "InpActEvt_IA_DebugBackward_K2Node_EnhancedInputActionEvent_29",
    "InpActEvt_IA_DebugForward_K2Node_EnhancedInputActionEvent_28",
    "InpActEvt_IA_DebugHUD_K2Node_EnhancedInputActionEvent_27",
    "InpActEvt_IA_NavigationUp_K2Node_EnhancedInputActionEvent_6",
    "InpActEvt_IA_NavigationDown_K2Node_EnhancedInputActionEvent_5",
    "InpActEvt_IA_Surrender_K2Node_EnhancedInputActionEvent_13",
    "InpActEvt_IA_Info_K2Node_EnhancedInputActionEvent_12",
    "InpActEvt_IA_HUD_K2Node_EnhancedInputActionEvent_0",
}
local PC_ANYKEY = "InpActEvt_AnyKey_K2Node_InputKeyEvent_0"

local GI_BASE  = "/Game/Gameplay/MainGI.MainGI_C:"
local GI_FUNCS = { "Check Server Datas", "Datas Found", "Join Session", "Start Screen" }

-- Internal functions to monitor in order to identify real key actions.
local EXTRA_MEC = {
    "Death", "Net Death", "Take Damage", "Hit Health", "Respawn", "Force End",
    "Reset Player", "Net Reset Player", "Request Heal Reset", "Heal Reset",
    "Net Cheat Start Game", "Net Cheat End Game", "Net Cheat Clear Game",
    "Net Cheat DebugSpawn", "Cheat Net Spawn NewItem", "Force Menu", "Set Preset", "Debug Mic",
}
local EXTRA_GM = { "Start Game", "End Game", "Kick All Players", "Death in Lobby", "Stop Game Timer" }

local last_action, last_time = "none", 0
local registered, gi_registered = false, false
local fail_count = 0

local function get_gi()
    local ok, gi = pcall(FindFirstOf, "MainGI_C")
    if ok and gi and gi:IsValid() then return gi end
    return nil
end

local function class_path(short)
    local ok, obj = pcall(FindFirstOf, short)
    if not ok or not obj or not obj:IsValid() then return nil end
    local ok2, full = pcall(function() return obj:GetClass():GetFullName() end)
    if not ok2 or not full then return nil end
    return full:match("^%S+%s+(.+)$") or full
end

local function arr_count(obj, prop)
    local ok, n = pcall(function() return obj[prop]:GetArrayNum() end)
    if ok then return tostring(n) end
    return "?"
end

-- Read the ID list as a Lua table.
local function read_list(arr)
    local t = {}
    pcall(function()
        arr:ForEach(function(i, e)
            local ok, s = pcall(function() return e:get():ToString() end)
            t[#t + 1] = ok and s or "?"
        end)
    end)
    return t
end

local function has_my_id(list)
    for _, s in ipairs(list) do
        if s == MY_ID then return true end
    end
    return false
end

-- ===== ADMIN IDENTIFIERS (two modes can be combined) =====
-- Mode 1: fixed ID (MY_ID, written to the admin list).
-- Mode 2: automatic ID = Steam account currently signed in on this computer
--         (read from Steam\config\loginusers.vdf, MostRecent = 1).
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

-- Record each Steam path checked, whether or not it exists, for diagnostics.
local tried_paths = {}

local function steam_roots()
    local roots = {}
    local seen = {}
    local function add(r)
        if r and r ~= "" and not seen[r] then
            seen[r] = true
            roots[#roots + 1] = r
        end
    end

-- 1. The path of this script (when provided by the runtime).
    pcall(function()
        local src = debug.getinfo(1, "S").source or ""
        src = src:gsub("^@", ""):gsub("\\", "/")
        local root = src:match("^(.-)/[Ss]team[Aa]pps/")
        add(root)
    end)
-- 2. Common Windows environment variables.
    pcall(function()
        local pf86 = os.getenv("ProgramFiles(x86)")
        if pf86 then add(pf86:gsub("\\", "/") .. "/Steam") end
    end)
    pcall(function()
        local pf = os.getenv("ProgramFiles")
        if pf then add(pf:gsub("\\", "/") .. "/Steam") end
    end)
    pcall(function()
local drive = os.getenv("SystemDrive") -- e.g. "C:"
        if drive then add(drive .. "/SteamLibrary") end
    end)
-- 3. Standard installation locations.
    add("C:/Program Files (x86)/Steam")
    add("C:/Program Files/Steam")
    add("D:/Steam")
    add("D:/SteamLibrary")
    add("E:/Steam")

    return roots
end

-- Try several key spellings because Valve may change capitalization.
local MOSTRECENT_PATTERNS = {
    '"[Mm]ost[Rr]ecent"%s*"1"',
    '"MostRecent"%s*"1"',
    '"mostrecent"%s*"1"',
}

local function detect_steam_id()
local candidates = {} -- valid account entries found, including their MostRecent flag
    local any_file_found = false

    for _, root in ipairs(steam_roots()) do
        local path = root .. "/config/loginusers.vdf"
        local c = read_file(path)
        tried_paths[#tried_paths + 1] = { path = path, found = (c ~= nil), size = c and #c or 0 }

        if c then
            any_file_found = true
            for id, body in c:gmatch('"(%d+)"%s*(%b{})') do
                if id:match("^7656119%d%d%d%d%d%d%d%d%d%d$") then
                    local is_recent = false
                    for _, pat in ipairs(MOSTRECENT_PATTERNS) do
                        if body:find(pat) then is_recent = true break end
                    end
                    local name = body:match('"[Pp]erson[Aa][Nn]ame"%s*"([^"]*)"') or "?"
                    candidates[#candidates + 1] = { id = id, recent = is_recent, name = name }
                end
            end
-- A matching file was found; do not check other Steam roots.
            break
        end
    end

    if #candidates == 0 then
        return nil, any_file_found and "file found, but no valid Steam account inside" or "file not found in any checked location"
    end

    for _, cand in ipairs(candidates) do
        if cand.recent then return cand.id, nil, candidates end
    end
-- If none is marked most recent, select the only available account as a fallback.
    if #candidates == 1 then
        return candidates[1].id, "only one account found; selected by default (none marked active)", candidates
    end
    return nil, #candidates .. " accounts found, but none marked active", candidates
end

local AUTO_ID = nil
if USE_AUTO_ID then
    local okd, a, b, c = pcall(detect_steam_id)
    if okd and a then
        AUTO_ID = a
        print(TAG .. "Steam ID automatically detected: " .. a .. (b and (" (" .. b .. ")") or "") .. "\n")
    else
        local reason = okd and b or tostring(a)
        print(TAG .. "automatic detection failed: " .. tostring(reason) .. "\n")
        for _, t in ipairs(tried_paths) do
            print(TAG .. "  checked: " .. t.path .. " -> " .. (t.found and ("found, " .. t.size .. " bytes") or "not found") .. "\n")
        end
        if okd and c then
            for _, cand in ipairs(c) do
                print(TAG .. "  account found in file: " .. cand.id .. " (" .. cand.name .. ") active=" .. tostring(cand.recent) .. "\n")
            end
        end
    end
end

local function list_has(list, id)
    for _, s in ipairs(list) do
        if s == id then return true end
    end
    return false
end

-- protected can be one ID (string) or a list of IDs that may not be overwritten.
local function is_protected(val, protected)
    if protected == nil then return false end
    if type(protected) == "table" then
        for _, p in ipairs(protected) do
            if p and val == p then return true end
        end
        return false
    end
    return val == protected
end

-- Insert an ID into Ultimate Admins if missing, preserving all protected entries.
local function place_id(gi, id, slot, protected, label)
    local list = read_list(gi["Ultimate Admins"])
    if #list == 0 or list_has(list, id) then return end

    local idx = math.min(slot, #list)
    local tries = 0
    while is_protected(list[idx], protected) and tries < #list do
        idx = (idx % #list) + 1
        tries = tries + 1
    end
    local old = list[idx]

-- Try method A followed by method B, verifying the result each time.
    pcall(function() gi["Ultimate Admins"][idx] = id end)
    local now = read_list(gi["Ultimate Admins"])
    if now[idx] ~= id then
        pcall(function() gi["Ultimate Admins"][idx]:set(id) end)
        now = read_list(gi["Ultimate Admins"])
    end

    if now[idx] == id then
        print(string.format("%sID %s (%s) set at position %d (previous: %s)\n", TAG, label, id, idx, tostring(old)))
    else
        fail_count = fail_count + 1
        if fail_count <= 3 then
            print(TAG .. "FAILED to set ID " .. label .. " (list unchanged)\n")
        end
    end
end

local function ensure_ids(gi)
    local fixed = USE_FIXED_ID and MY_ID or nil
    local auto  = USE_AUTO_ID and AUTO_ID or nil
    local third = USE_THIRD_ID and THIRD_ID or nil

    if fixed then place_id(gi, fixed, FIXED_SLOT, { auto, third }, "fixe") end
    if auto and auto ~= fixed then place_id(gi, auto, AUTO_SLOT, { fixed, third }, "auto") end
    if third and third ~= fixed and third ~= auto then
        place_id(gi, third, THIRD_SLOT, { fixed, auto }, "second fixed")
    end
end

local function force_flags(gi)
    pcall(function() gi["Admin"] = true end)
    pcall(function() gi["Admin Cheat"] = true end)
end

-- Insert MY_ID when missing and set the flags if requested.
local function ensure_admin()
    local gi = get_gi()
    if not gi then return end

    ensure_ids(gi)

    if FORCE_ADMIN_FLAGS then force_flags(gi) end
end

local function snapshot()
    local parts = {}
    local gi = get_gi()
    if gi then
        local a, c = "?", "?"
        pcall(function() a = tostring(gi["Admin"]) end)
        pcall(function() c = tostring(gi["Admin Cheat"]) end)
        parts[#parts + 1] = "Admin=" .. a
        parts[#parts + 1] = "Admin Cheat=" .. c
        parts[#parts + 1] = "Ultimate Admins=" .. arr_count(gi, "Ultimate Admins")
        parts[#parts + 1] = "My ID present=" .. tostring(has_my_id(read_list(gi["Ultimate Admins"])))
        if AUTO_ID then parts[#parts + 1] = "Auto ID present=" .. tostring(list_has(read_list(gi["Ultimate Admins"]), AUTO_ID)) end
        if USE_THIRD_ID then parts[#parts + 1] = "Second fixed ID present=" .. tostring(list_has(read_list(gi["Ultimate Admins"]), THIRD_ID)) end
    else
        parts[#parts + 1] = "MainGI not found"
    end
-- Local player character via the player controller, otherwise the first found.
    local mec = nil
    local okp, pc = pcall(FindFirstOf, "PC_C")
    if okp and pc and pc:IsValid() then
        local okm, m = pcall(function() return pc["Mec Ref"] end)
        if okm and m and m:IsValid() then mec = m end
    end
    if not mec then
        local ok2, m2 = pcall(FindFirstOf, "Mec_C")
        if ok2 and m2 and m2:IsValid() then mec = m2 end
    end
    if mec then
        local idx, dm = "?", "?"
        pcall(function() idx = tostring(mec["DebugSpawn Index"]) end)
        pcall(function() dm = tostring(mec["DebugMenu"]) end)
        parts[#parts + 1] = "Debug Items=" .. arr_count(mec, "Debug Items")
        parts[#parts + 1] = "DebugSpawn Index=" .. idx
        parts[#parts + 1] = "DebugMenu=" .. dm
        parts[#parts + 1] = "Admin Items=" .. arr_count(mec, "Admin Items")
    else
        parts[#parts + 1] = "Mec not found"
    end
    return table.concat(parts, " | ")
end

local function key_name(p)
    local ok, res = pcall(function() return p:get().KeyName:ToString() end)
    if ok and res then return res end
    return "?"
end

local function hook_extra(path, names, who)
    for _, n in ipairs(names) do
        local ok, err = pcall(function()
            RegisterHook(path .. ":" .. n, function(self, ...)
                local dt = (os.clock() - last_time) * 1000
                local extra = ""
                if n == "Net Cheat DebugSpawn" or n == "Cheat Net Spawn NewItem" then
                    local params = { ... }
                    local nm = "?"
                    pcall(function() nm = params[4]:get():GetFName():ToString() end)
                    extra = " | item=" .. nm
                end
                print(string.format("%s   -> %s.%s%s | %.0f ms after action %s\n", TAG, who, n, extra, dt, last_action))
            end)
        end)
        if not ok then
            print(TAG .. "hook failed: " .. who .. "." .. n .. " -> " .. tostring(err) .. "\n")
        end
    end
end

-- MainGI hooks: restore IDs before the game could read the admin list again.
local function register_gi()
    for _, n in ipairs(GI_FUNCS) do
        local ok, err = pcall(function()
            RegisterHook(GI_BASE .. n, function(self) ensure_admin() end)
        end)
        if not ok then
            print(TAG .. "MainGI hook failed: " .. n .. " -> " .. tostring(err) .. "\n")
        end
    end
end

-- Player-character and controller hooks: log input actions.
local function register_input(mecPath, pcPath)
    print(TAG .. "Mec_C = " .. mecPath .. "\n")
    print(TAG .. "PC_C  = " .. pcPath .. "\n")

    for _, fname in ipairs(MEC_FUNCS) do
        local label = fname:match("IA_(%w+)_K2Node") or fname
        local ok, err = pcall(function()
            RegisterHook(mecPath .. ":" .. fname, function(self)
                if FORCE_ADMIN_FLAGS and label:find("^Debug") then
                    local g = get_gi()
                    if g then force_flags(g) end
                end
                last_action, last_time = label, os.clock()
                print(string.format("%sACTION %s | %s\n", TAG, label, snapshot()))
            end)
        end)
        if not ok then
            print(TAG .. "hook FAILED: " .. label .. " -> " .. tostring(err) .. "\n")
        end
    end

    local ok, err = pcall(function()
        RegisterHook(pcPath .. ":" .. PC_ANYKEY, function(self, Key)
            local k = key_name(Key)
            if not k:find("^Mouse") and not k:find("^Gamepad") then
                print(string.format("%sKEY %s\n", TAG, k))
            end
        end)
    end)
    if not ok then
        print(TAG .. "AnyKey hook FAILED -> " .. tostring(err) .. "\n")
    end
    hook_extra(mecPath, EXTRA_MEC, "Mec")
    local gmPath = class_path("GM_C")
    if gmPath then
        hook_extra(gmPath, EXTRA_GM, "GM")
    else
        print(TAG .. "GM_C not found (normal if you are not the host)\n")
    end
    print(TAG .. "input hooks registered. Status: " .. snapshot() .. "\n")
end

local function try_register()
    if not gi_registered and get_gi() then
        gi_registered = true
        register_gi()
        ensure_admin()
        print(TAG .. "MainGI found, admin hooks registered. Status: " .. snapshot() .. "\n")
    end
    if not registered then
        local mecPath = class_path("Mec_C")
        local pcPath = class_path("PC_C")
        if mecPath and pcPath then
            registered = true
            register_input(mecPath, pcPath)
        end
    end
end

print(TAG .. "mod loaded (configured ID: " .. MY_ID .. ")\n")

-- Register hooks as soon as possible, then recheck the admin list every 2 seconds.
LoopAsync(2000, function()
    ExecuteInGameThread(function()
        try_register()
        ensure_admin()
    end)
    return false
end)

BRIDGE_COMMANDS["REAPPLY_IDS"] = function()
    ExecuteInGameThread(function()
        ensure_admin()
        print(TAG .. "Bridge -> admin IDs reapplied\n")
    end)
end
BRIDGE_STATUS_PROVIDERS[#BRIDGE_STATUS_PROVIDERS + 1] = function() return snapshot() end

-- ===================== GAME COMMANDS (F1-F7) =====================
do
-- Admin panel commands: invoke the game functions directly.
-- Intended for private lobbies hosted by the player.
--
--  F1: start game
--  F2: end game
--  F3: reset game
--  F4: heal / reset health
--  F5: spawn the selected game item
--  F6: select the next item
--  F7: print the item list in the console

local TAG = "[PANEL] "
local items, item_index = {}, 1

-- Local player character obtained via the player controller.
local function get_mec()
    local ok, pc = pcall(FindFirstOf, "PC_C")
    if not ok or not pc or not pc:IsValid() then return nil end
    local ok2, mec = pcall(function() return pc["Mec Ref"] end)
    if ok2 and mec and mec:IsValid() then return mec end
    return nil
end

-- Only the host has a game-mode object; enable its Cheat flag.
local function enable_cheat()
    local ok, gm = pcall(FindFirstOf, "GM_C")
    if ok and gm and gm:IsValid() then
        pcall(function() gm["Cheat"] = true end)
        return true
    end
    return false
end

-- Invoke a game function (names can contain spaces), then log the result.
local function call(obj, name, ...)
    local args = { ... }
    local ok, err = pcall(function()
        local fn = obj[name]
        fn(obj, table.unpack(args))
    end)
    if ok then
        print(TAG .. name .. " : call OK\n")
    else
        print(TAG .. "ERROR in " .. name .. " : " .. tostring(err) .. "\n")
    end
    return ok
end

local function command(label, fname)
    ExecuteInGameThread(function()
        local mec = get_mec()
        if not mec then
            print(TAG .. label .. " : player character not found (are you in a game?)\n")
            return
        end
        if not enable_cheat() then
            print(TAG .. "game mode (GM_C) not found: are you the lobby host?\n")
        end
        print(TAG .. label .. "\n")
        call(mec, fname)
    end)
end

-- Game item assets already loaded in memory.
local function load_items()
    items = {}
    local ok, all = pcall(FindAllOf, "Data_Item_C")
    if ok and all then
        for _, o in ipairs(all) do
            if o:IsValid() then
                local nm = "?"
                pcall(function() nm = o:GetFName():ToString() end)
                if not nm:find("^Default__") then
                    items[#items + 1] = { obj = o, name = nm }
                end
            end
        end
    end
    if item_index > #items then item_index = 1 end
    -- Stable selection within this scan; every command uses a validated index.
    table.sort(items, function(a, b)
        if a.name == b.name then return tostring(a.obj) < tostring(b.obj) end
        return a.name:lower() < b.name:lower()
    end)
    print(TAG .. #items .. " item(s) found\n")
end

local function choose_item(raw)
    local index = tonumber(raw)
    if not index or index % 1 ~= 0 or index < 1 or index > #items then
        print(TAG .. "invalid item index: " .. tostring(raw) .. " (refresh the item list)\n")
        return false
    end
    item_index = index
    print(TAG .. "selected item: " .. items[item_index].name .. "\n")
    return true
end

-- Called only on the Unreal game thread by the bridge. Never use object pointers
-- from the catalog in the launcher; only validated indices are transmitted.
ITEM_CATALOG_PROVIDER = function()
    load_items()
    local lines = {}
    for i, it in ipairs(items) do
        local name = tostring(it.name):gsub("[%c]", " ")
        lines[#lines + 1] = tostring(i) .. "\t" .. name
    end
    return lines
end

-- Exact game item asset paths from the user's DexAdditions / _FurAPI reference.
-- AdminByAsticot does not load or depend on FurAPI itself.
local ITEM_ALIAS_PATHS = {
    ["RIFLE"]        = "/Game/Items/Guns/Rifle/DA_Rifle.DA_Rifle",
    ["RIFLE_D"]      = "/Game/Items/Guns/Rifle/DA_RifleDefault.DA_RifleDefault",
    ["PISTOL"]       = "/Game/Items/Guns/Pistol/DA_Pistol.DA_Pistol",
    ["PISTOL_D"]     = "/Game/Items/Guns/Pistol/DA_PistolDefault.DA_PistolDefault",
    ["SMG"]          = "/Game/Items/Guns/SMG/DA_SMG.DA_SMG",
    ["SMG_D"]        = "/Game/Items/Guns/SMG/DA_SMGDefault.DA_SMGDefault",
    ["SHOTGUN"]      = "/Game/Items/Guns/Shotgun/DA_Shotgun.DA_Shotgun",
    ["SHOTGUN_D"]    = "/Game/Items/Guns/Shotgun/DA_ShotgunDefault.DA_ShotgunDefault",
    ["REVOLVER"]     = "/Game/Items/Guns/Revolver/DA_Revolver.DA_Revolver",
    ["REV_D"]        = "/Game/Items/Guns/Revolver/DA_RevolverDefault.DA_RevolverDefault",
    ["SHORTY"]       = "/Game/Items/Guns/Shorty/DA_Shorty.DA_Shorty",
    ["SHORTY_D"]     = "/Game/Items/Guns/Shorty/DA_ShortyDefault.DA_ShortyDefault",

    ["GRENADE"]      = "/Game/Items/Grenade/Item/DA_Grenade.DA_Grenade",
    ["GRENADE_D"]    = "/Game/Items/Data_Grenade.Default__Data_Grenade_C",

    ["C4"]           = "/Game/Items/Melee/C4/DA_C4.DA_C4",
    ["DETONATOR"]    = "/Game/Items/Special/Detonator/DA_Detonator.DA_Detonator",
    ["KNIFE"]        = "/Game/Items/Melee/Knife/DA_Knife.DA_Knife",
    ["SCALPEL"]      = "/Game/Items/FieldItems/Scalpel/DA_Scalpel.DA_Scalpel",

    ["FISH"]         = "/Game/Items/Melee/Fish/DA_Fish.DA_Fish",
    ["COD"]          = "/Game/Items/Melee/Fish/DA_Fish.DA_Fish",
    ["TUNA"]         = "/Game/Items/Melee/Fish/DA_Fish.DA_Fish",
    ["SALMON"]       = "/Game/Items/Melee/Fish/DA_Fish.DA_Fish",
    ["LOBSTER"]      = "/Game/Items/Melee/Fish/DA_Fish.DA_Fish",
    ["SHRIMP"]       = "/Game/Items/Melee/Pizusshi/DA_Pizzushi.DA_Pizzushi",
    ["PIZZUSHI"]     = "/Game/Items/Melee/Pizusshi/DA_Pizzushi.DA_Pizzushi",

    ["BATTERY"]      = "/Game/Items/Melee/Battery/DA_Battery.DA_Battery",
    ["FUSE"]         = "/Game/Items/Melee/Fuze/DA_Fuse.DA_Fuse",
    ["SCREW"]        = "/Game/Items/Melee/ScrewDriver/DA_ScrewDriver.DA_ScrewDriver",
    ["VENT"]         = "/Game/Items/Melee/VentFilter/DA_VentFilter.DA_VentFilter",
    ["BOTTLE"]       = "/Game/Items/Melee/GazBottle/DA_GazBottle.DA_GazBottle",
    ["PACKAGE"]      = "/Game/Items/Melee/Package/DA_Package.DA_Package",
    ["CONTAINER"]    = "/Game/Items/Melee/SampleContainer/DA_Container.DA_Container",
    ["SAMPLE"]       = "/Game/Items/Melee/ProcessedSample/DA_Sample.DA_Sample",
    ["RICE"]         = "/Game/Items/Melee/Rice/DA_Rice.DA_Rice",
    
    ["REZ"]          = "/Game/Items/Melee/Rez/DA_Rez.DA_Rez",
    ["CARD"]         = "/Game/Items/Melee/AccessCard/DA_AccessCard.DA_AccessCard",

    ["COOKIE"]       = "/Game/Items/FieldItems/Cookie/DA_Cookie.DA_Cookie",
    ["POPSICLE"]     = "/Game/Items/FieldItems/Popsicle/DA_Popsicle.DA_Popsicle",
    ["EGG"]          = "/Game/Items/Melee/EasterEgg/DA_EasterEgg.DA_EasterEgg",
    ["MUSIC"]        = "/Game/Items/Melee/Music/DA_Music.DA_Music",
    ["DISK"]         = "/Game/Items/Melee/HardDrive/DA_HardDrive.DA_HardDrive",

    ["ITEM"]         = "/Game/Items/Data_Item.Default__Data_Item_C",
    ["CONSUMABLE_D"] = "/Game/Items/Data_Consumable.Default__Data_Consumable_C",

    ["PENCIL"]       = "/Game/Items/FieldItems/Pencil/DA_Pencil.DA_Pencil",
    ["MARKER"]       = "/Game/Items/FieldItems/Marker/DA_Marker_Office.DA_Marker_Office",
    ["TAPE"]         = "/Game/Items/FieldItems/TapeRoll/DA_TapeRoll.DA_TapeRoll",
    ["MOUSE"]        = "/Game/Items/FieldItems/ComputerMouse/DA_ComputerMouse.DA_ComputerMouse",
    ["FOODCAN"]      = "/Game/Items/FieldItems/FoodCan/DA_FoodCan.DA_FoodCan",
    ["JERRICAN"]     = "/Game/Items/FieldItems/Jerrican/DA_Jerrican.DA_Jerrican",
    
    ["MED_A"]        = "/Game/Items/FieldItems/Medication/DA_Medication_A.DA_Medication_A",
    ["MED_B1"]       = "/Game/Items/FieldItems/Medication/DA_Medication_B1.DA_Medication_B1",
    
    ["MACHINEPART_A"]= "/Game/Items/FieldItems/MachinePart/DA_MachinePart_A.DA_MachinePart_A",
    ["MACHINEPART_B"]= "/Game/Items/FieldItems/MachinePart/DA_MachinePart_B.DA_MachinePart_B",
    ["MACHINEPART_C"]= "/Game/Items/FieldItems/MachinePart/DA_MachinePart_C.DA_MachinePart_C",
    ["MACHINEPART_D"]= "/Game/Items/FieldItems/MachinePart/DA_MachinePart_D.DA_MachinePart_D",
    
    ["MUG"]          = "/Game/Items/FieldItems/Mug/DA_Mug.DA_Mug",
    ["CANE"]         = "/Game/Items/Melee/SugarCane/DA_CandyCane.DA_CandyCane",
}

-- Item state field names are taken from DexAdditions / _FurAPI (not guessed).
local ITEM_VALUE_FIELD = "Value_8_5511228644AD6F4D6D0589BD4438C32F"
local ITEM_TIME_FIELD = "Time_15_AFBBFC834F820A0E18A707A477B6D3FE"

-- Names from the live catalog are preferred. A known DexAdditions alias
-- (e.g. RIFLE, RIFLE_D, REV_D) can also resolve an asset without loading
-- the entire catalog, as long as the actual asset is available in the game.
local function resolve_named_item(raw_name)
    local name = tostring(raw_name or ""):match("^%s*(.-)%s*$")
    if name == "" or #name > 128 or name:find("[%c]") then
        print(TAG .. "invalid item name\n")
        return nil
    end

    local upper = name:upper()
    if #items == 0 then load_items() end
    for _, it in ipairs(items) do
        if it.name:upper() == upper then return it end
    end

    local path = ITEM_ALIAS_PATHS[upper]
    if path then
        local asset = nil
        local ok = pcall(function()
            asset = StaticFindObject(path) or FindObject(nil, path, 0, 0)
        end)
        if ok and asset then
            local is_valid, valid = pcall(function() return asset:IsValid() end)
            if is_valid and valid then return {obj = asset, name = name} end
        end
    end

    -- An item may have been loaded after the last catalog scan.
    load_items()
    for _, it in ipairs(items) do
        if it.name:upper() == upper then return it end
    end
    print(TAG .. "item not found: " .. name .. " (try Refresh item list)\n")
    return nil
end

local function valid_item_value(raw)
    local value = tonumber(raw)
    if not value or value ~= math.floor(value) or value < 0 or value > 2147483647 then
        print(TAG .. "invalid item value (expected integer 0..2147483647): " .. tostring(raw) .. "\n")
        return nil
    end
    return value
end

local function spawn_item(explicit_item, item_value)
    local mec = get_mec()
    if not mec then print(TAG .. "player character not found\n") return end
    local it = explicit_item
    if not it then
        if #items == 0 then load_items() end
        if #items == 0 then
            print(TAG .. "no items in list (FindAllOf returned nothing)\n")
            return
        end
        it = items[item_index]
    end
    enable_cheat()

    local loc = { X = 0, Y = 0, Z = 0 }
    local fwd = { X = 1, Y = 0, Z = 0 }
    pcall(function()
        local l = mec:K2_GetActorLocation()
        local f = mec:GetActorForwardVector()
        fwd = { X = f.X, Y = f.Y, Z = 0 }
        loc = { X = l.X + f.X * 150, Y = l.Y + f.Y * 150, Z = l.Z + 40 }
    end)

    local state = {}
    if item_value ~= nil then
        state[ITEM_VALUE_FIELD] = item_value
        state[ITEM_TIME_FIELD] = 0
    end
    print(TAG .. "spawning: " .. it.name ..
        (item_value ~= nil and (" | value=" .. item_value) or "") .. "\n")
    call(mec, "Cheat Net Spawn NewItem", loc, { X = 0, Y = 0, Z = 0 }, fwd, it.obj, state)
end

-- Keep the host game-mode Cheat flag enabled.
LoopAsync(2000, function()
    ExecuteInGameThread(enable_cheat)
    return false
end)

print(TAG .. "mod loaded: commands available through the external launcher (F1-F7 no longer used)\n")

BRIDGE_COMMANDS["START_GAME"] = function() command("Bridge -> start game", "Net Cheat Start Game") end
BRIDGE_COMMANDS["END_GAME"] = function() command("Bridge -> end game", "Net Cheat End Game") end
BRIDGE_COMMANDS["RESET_GAME"] = function() command("Bridge -> reset game", "Net Cheat Clear Game") end
BRIDGE_COMMANDS["HEAL"] = function() command("Bridge -> heal / reset health", "Request Heal Reset") end
BRIDGE_COMMANDS["SPAWN_ITEM"] = function(arg)
    ExecuteInGameThread(function()
        if arg and arg ~= "" then
            if #items == 0 then load_items() end
            if not choose_item(arg) then return end
        end
        spawn_item()
    end)
end
-- New typed-name spawn protocol: SPAWN_NAMED_ITEM:<name><TAB><value>
-- Keep SPAWN_ITEM:<index> untouched for older launchers and the legacy button.
BRIDGE_COMMANDS["SPAWN_NAMED_ITEM"] = function(arg)
    local name, raw_value = tostring(arg or ""):match("^(.-)\t([^\t]+)$")
    if not name then
        print(TAG .. "usage: spawn <item_name> <value> (example: spawn RIFLE 9)\n")
        return
    end
    local value = valid_item_value(raw_value)
    if value == nil then return end
    ExecuteInGameThread(function()
        local it = resolve_named_item(name)
        if it then spawn_item(it, value) end
    end)
end
BRIDGE_COMMANDS["SELECT_ITEM"] = function(arg)
    ExecuteInGameThread(function()
        if #items == 0 then load_items() end
        choose_item(arg)
    end)
end
BRIDGE_COMMANDS["NEXT_ITEM"] = function()
    ExecuteInGameThread(function()
        if #items == 0 then load_items() end
        if #items == 0 then return end
        item_index = (item_index % #items) + 1
        print(TAG .. "selected item (bridge): " .. items[item_index].name .. "\n")
    end)
end
BRIDGE_STATUS_PROVIDERS[#BRIDGE_STATUS_PROVIDERS + 1] = function()
    if #items == 0 then return "Selected item: (list not loaded; use Next Item)" end
    local it = items[item_index]
    return "Selected item: " .. (it and it.name or "?") .. " (" .. item_index .. "/" .. #items .. ")"
end
end

-- ===================== ITEM STATE (J) =====================
-- J: reset the selected in-game item state.
-- K: print in-game item and state information for diagnostics.
do
local TAG = "[AMMO] "

local function get_mec()
    local ok, pc = pcall(FindFirstOf, "PC_C")
    if not ok or not pc or not pc:IsValid() then return nil end
    local ok2, mec = pcall(function() return pc["Mec Ref"] end)
    if ok2 and mec and mec:IsValid() then return mec end
    return nil
end

local NUMERIC = {
    IntProperty = true, Int64Property = true, UInt32Property = true,
    FloatProperty = true, DoubleProperty = true,
}

local function pinfo(p)
    local name, ptype = "?", "?"
    pcall(function() name = p:GetFName():ToString() end)
    pcall(function() ptype = p:GetClass():GetFName():ToString() end)
    return name, ptype
end

-- Walk the properties of a class and its parents (stop at engine classes).
local function each_class_prop(cls, cb)
    local depth = 0
    while cls and depth < 8 do
        local okv, valid = pcall(function() return cls:IsValid() end)
        if not okv or not valid then break end
        local full = ""
        pcall(function() full = cls:GetFullName() end)
        if full:find("/Script/", 1, true) then break end
        pcall(function() cls:ForEachProperty(function(p) cb(p) end) end)
        local ok, sup = pcall(function() return cls:GetSuperStruct() end)
        if not ok then break end
        cls = sup
        depth = depth + 1
    end
end

-- Find the struct type for a property on the player character (e.g. Hand State).
local function struct_of(mec, propname)
    local st = nil
    pcall(function()
        mec:GetClass():ForEachProperty(function(p)
            local n = p:GetFName():ToString()
            if n == propname then st = p:GetStruct() end
        end)
    end)
    return st
end

local function hand_item(mec)
    local ok, it = pcall(function() return mec["Hand Item"] end)
    if ok and it and it:IsValid() then return it end
    return nil
end

local function item_name(it)
    local nm = "?"
    pcall(function() nm = it:GetFName():ToString() end)
    return nm
end

local function dump()
    local mec = get_mec()
    if not mec then print(TAG .. "player character not found (are you in a game?)\n") return end
    local it = hand_item(mec)
    if not it then print(TAG .. "nothing equipped\n") return end
    print(TAG .. "equipped item: " .. item_name(it) .. "\n")

    print(TAG .. "--- item properties ---\n")
    each_class_prop(it:GetClass(), function(p)
        local name, ptype = pinfo(p)
        local val = "?"
        pcall(function() val = tostring(it[name]) end)
        print(string.format("%s  %s (%s) = %s\n", TAG, name, ptype, val))
    end)

    print(TAG .. "--- item state (Hand State) ---\n")
    local st = struct_of(mec, "Hand State")
    if not st then
        print(TAG .. "  structure not found\n")
        return
    end
    pcall(function()
        st:ForEachProperty(function(p)
            local name, ptype = pinfo(p)
            local val = "?"
            pcall(function() val = tostring(mec["Hand State"][name]) end)
            print(string.format("%s  %s (%s) = %s\n", TAG, name, ptype, val))
        end)
    end)
end

local function has_any(s, words)
    for _, w in ipairs(words) do
        if s:find(w, 1, true) then return true end
    end
    return false
end

local AMMO_WORDS = { "ammo", "bullet", "round", "munition", "mag", "clip" }
local MAX_WORDS  = { "max", "mag", "clip", "capacity", "size" }
-- Diagnostic findings: the item exposes its maximum value in Capacity;
-- the current state is Value in Hand State (technical field Value_<hash>).

local function refill(quiet)
    local mec = get_mec()
    if not mec then
        if not quiet then print(TAG .. "player character not found (are you in a game?)\n") end
        return
    end
    local it = hand_item(mec)
    if not it then
        if not quiet then print(TAG .. "nothing equipped\n") end
        return
    end

-- 1. Maximum: prefer the exact Capacity field; otherwise search by keywords.
    local best, best_name = nil, nil
    pcall(function()
        local v = tonumber(it["Capacity"])
        if v and v > 0 then best, best_name = v, "Capacity" end
    end)
    if not best then
        each_class_prop(it:GetClass(), function(p)
            local name, ptype = pinfo(p)
            if NUMERIC[ptype] then
                local l = name:lower()
                if has_any(l, AMMO_WORDS) and has_any(l, MAX_WORDS) then
                    local ok, v = pcall(function() return tonumber(it[name]) end)
                    if ok and v and v > 0 and (not best or v > best) then
                        best, best_name = v, name
                    end
                end
            end
        end)
    end
    if not best then
        if not quiet then
            print(TAG .. "maximum value not found for " .. item_name(it) .. " : press K and inspect the [AMMO] lines\n")
        end
        return
    end

-- 2. Current item state in the Hand State struct.
    local st = struct_of(mec, "Hand State")
    if not st then
        if not quiet then print(TAG .. "Hand State structure not found\n") end
        return
    end
    local fields = {}
    pcall(function()
        st:ForEachProperty(function(p)
            local name, ptype = pinfo(p)
            local l = name:lower()
-- Value_<hash> is a generic game field used for the item current value.
-- Prefer it when available, with keyword lookup as fallback.
            if NUMERIC[ptype] and (l:find("^value") or has_any(l, AMMO_WORDS)) then
                fields[#fields + 1] = { name = name, ptype = ptype }
            end
        end)
    end)
    if #fields == 0 then
        if not quiet then
            print(TAG .. "no ammo field found in the state of " .. item_name(it) .. " (this item may not use ammo)\n")
        end
        return
    end

-- 3. Write and verify, staying quiet when the state has not changed
-- to avoid repeatedly filling the console.
    for _, f in ipairs(fields) do
        local value = best
        if f.ptype == "IntProperty" or f.ptype == "Int64Property" or f.ptype == "UInt32Property" then
            value = math.floor(best)
        end
        if quiet then
            local current = nil
            pcall(function() current = tonumber(mec["Hand State"][f.name]) end)
            if current ~= value then
                pcall(function() mec["Hand State"][f.name] = value end)
            end
        else
            pcall(function() mec["Hand State"][f.name] = value end)
            local after = "?"
            pcall(function() after = tostring(mec["Hand State"][f.name]) end)
            print(string.format("%s%s : %s = %s (maximum read from %s = %s)\n", TAG, item_name(it), f.name, after, best_name, tostring(best)))
        end
    end

-- 4. Refresh the game item display.
    pcall(function() mec["Set Ammo"](mec) end)
end

-- ----- Continuous item-state option (V): refresh while enabled -----
local unlimited_ammo = false

local ok3, err3 = pcall(function()
    RegisterKeyBind(Key.V, function()
        unlimited_ammo = not unlimited_ammo
        print(TAG .. "unlimited ammo: " .. (unlimited_ammo and "enabled" or "disabled") .. "\n")
        if unlimited_ammo then ExecuteInGameThread(function() refill() end) end
    end)
end)
if ok3 then
    print(TAG .. "V key registered (unlimited ammo)\n")
else
    print(TAG .. "FAILED to register V key -> " .. tostring(err3) .. "\n")
end

LoopAsync(50, function()
    if unlimited_ammo then
        ExecuteInGameThread(function() refill(true) end)
    end
return false -- keep the async loop running
end)

-- Protect each key registration. If the API is missing in this UE4SS version,
-- report an explicit console error instead of failing silently.
local ok1, err1 = pcall(function()
    RegisterKeyBind(Key.J, function() ExecuteInGameThread(refill) end)
end)
if ok1 then
    print(TAG .. "J key registered (refill to maximum)\n")
else
    print(TAG .. "FAILED to register J key -> " .. tostring(err1) .. "\n")
end

-- K for diagnostics instead of Ctrl+J: avoid depending on modifier-key APIs,
-- which may not be related to the issue but are excluded as a precaution.
local ok2, err2 = pcall(function()
    RegisterKeyBind(Key.K, function() ExecuteInGameThread(dump) end)
end)
if ok2 then
    print(TAG .. "K key registered (diagnostics)\n")
else
    print(TAG .. "FAILED to register K key -> " .. tostring(err2) .. "\n")
end

print(TAG .. "J: refill ammo | K: diagnostics | V: unlimited ammo\n")

BRIDGE_COMMANDS["REFILL_AMMO"] = function() ExecuteInGameThread(refill) end
BRIDGE_COMMANDS["AMMO_DIAG"] = function() ExecuteInGameThread(dump) end
BRIDGE_COMMANDS["TOGGLE_UNLIMITED"] = function()
    unlimited_ammo = not unlimited_ammo
    print(TAG .. "unlimited ammo (bridge): " .. (unlimited_ammo and "enabled" or "disabled") .. "\n")
    if unlimited_ammo then ExecuteInGameThread(function() refill() end) end
end
BRIDGE_STATUS_PROVIDERS[#BRIDGE_STATUS_PROVIDERS + 1] = function()
    return "Unlimited ammo: " .. (unlimited_ammo and "ON" or "OFF")
end
end

-- ===================== PLAYER INTERACTION =====================
-- Raise hands using the game action, then right-click a player to select them.
-- A second right-click releases the selection. This experimental feature
-- is most reliable on the host; clients may show different movement because
-- the game also controls each player character position.
do
local TAG = "[GRAB] "

local function get_mec_pc()
    local ok, pc = pcall(FindFirstOf, "PC_C")
    if not ok or not pc or not pc:IsValid() then return nil, nil end
    local ok2, mec = pcall(function() return pc["Mec Ref"] end)
    if ok2 and mec and mec:IsValid() then return mec, pc end
    return nil, pc
end

-- Cache this lookup to avoid repeatedly calling FindFirstOf(PC_C) per frame.
-- The local player controller and character remain the same between frames,
-- so checking IsValid is sufficient and less expensive.
local cached_pc, cached_mec = nil, nil

local function get_mec_pc_cached()
    if cached_pc and cached_pc.IsValid and cached_pc:IsValid()
        and cached_mec and cached_mec.IsValid and cached_mec:IsValid() then
        return cached_mec, cached_pc
    end
    cached_mec, cached_pc = get_mec_pc()
    return cached_mec, cached_pc
end

local function hands_up(mec)
    local ok, v = pcall(function() return mec["HandsUp"] end)
    return ok and v == true
end

local ksl = nil
local function get_ksl()
    if ksl then return ksl end
    local ok1, helpers = pcall(require, "UEHelpers")
    if ok1 and helpers and helpers.GetKismetSystemLibrary then
        local ok2, obj = pcall(helpers.GetKismetSystemLibrary)
        if ok2 and obj and obj.IsValid and obj:IsValid() then ksl = obj end
    end
    if not ksl then
        local ok3, obj2 = pcall(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
        if ok3 and obj2 and obj2.IsValid and obj2:IsValid() then ksl = obj2 end
    end
    return ksl
end

local camera_debug_shown = false
local cached_cam = nil -- cache the camera reference between calls

local function get_camera_manager(pc)
    if cached_cam and cached_cam.IsValid and cached_cam:IsValid() then return cached_cam, nil end
    cached_cam = nil

-- Attempt 1: native function.
    local ok1, cam1 = pcall(function() return pc:GetPlayerCameraManager() end)
    if ok1 and cam1 and cam1.IsValid and cam1:IsValid() then cached_cam = cam1; return cam1, nil end
-- Attempt 2: direct property (typical Unreal Engine reference name).
    local ok2, cam2 = pcall(function() return pc.PlayerCameraManager end)
    if ok2 and cam2 and cam2.IsValid and cam2:IsValid() then cached_cam = cam2; return cam2, nil end
    local reasons = "attempt 1 (GetPlayerCameraManager) -> " ..
        (ok1 and "invalid or nil object" or tostring(cam1)) ..
        " | attempt 2 (PlayerCameraManager) -> " ..
        (ok2 and "invalid or nil object" or tostring(cam2))
    return nil, reasons
end

local function camera_loc_rot(pc)
    local cam, cerr = get_camera_manager(pc)
    if not cam then return nil, nil, cerr end

    local okL, loc = pcall(function() return cam:GetCameraLocation() end)
    local okR, rot = pcall(function() return cam:GetCameraRotation() end)
    if okL and okR then return loc, rot, nil end

    local reasons = "GetCameraLocation -> " .. (okL and "ok" or tostring(loc)) ..
        " | GetCameraRotation -> " .. (okR and "ok" or tostring(rot))
    return nil, nil, reasons
end

local function forward_from_rot(rot)
    local rad = math.pi / 180
    local yaw = rot.Yaw * rad
    local pitch = rot.Pitch * rad
    return { X = math.cos(pitch) * math.cos(yaw), Y = math.cos(pitch) * math.sin(yaw), Z = math.sin(pitch) }
end

local grabbing = nil
local grabYaw = 0.0 -- orientation captured once when selecting the target
local trace_error_shown = false
local shape_debug_count = 0

-- Instead of a collision-based raycast (which depends on game collision setup),
-- select the character nearest to the crosshair direction using positions.
-- This is simpler and does not depend on the collision configuration.
local MAX_ANGLE_COS = 0.90 -- angular tolerance around the crosshair
local MAX_DISTANCE = 1000

local function find_target()
    local mec, pc = get_mec_pc()
    if not mec or not pc then print(TAG .. "player character not found\n") return nil end

    local loc, rot, cerr = camera_loc_rot(pc)
    if not loc then print(TAG .. "camera: " .. tostring(cerr) .. "\n") return nil end
    local fwd = forward_from_rot(rot)

    local ok, all = pcall(FindAllOf, "Mec_C")
    if not ok or not all then
        print(TAG .. "player list not found\n")
        return nil
    end

    local best, bestDot, bestName, bestDist = nil, MAX_ANGLE_COS, nil, nil
    local checked = 0
    for _, cand in ipairs(all) do
        local okv, valid = pcall(function() return cand:IsValid() end)
        if okv and valid and cand ~= mec then
            local nm = "?"
            pcall(function() nm = cand:GetFName():ToString() end)
            if not nm:find("^Default__") then
                local okl, cloc = pcall(function() return cand:K2_GetActorLocation() end)
                if okl and cloc then
                    checked = checked + 1
                    local dx, dy, dz = cloc.X - loc.X, cloc.Y - loc.Y, cloc.Z - loc.Z
                    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if dist > 1 and dist < MAX_DISTANCE then
                        local dot = (dx * fwd.X + dy * fwd.Y + dz * fwd.Z) / dist
                        if dot > bestDot then
                            bestDot, best, bestName, bestDist = dot, cand, nm, dist
                        end
                    end
                end
            end
        end
    end

    if not best then
        print(TAG .. "no player under crosshair (" .. checked .. " player(s) checked)\n")
        return nil
    end
    print(TAG .. "found: " .. bestName .. " at " .. math.floor(bestDist) .. " units\n")
    return best
end

-- Replication: a local actor-position change may be visible only to this client.
-- The game also uses the replicated Net Location property to synchronize
-- player positions with other clients.
-- This is similar to another mod's synchronization approach.
local vel_error_shown = false

-- Avoid retaining residual velocity that would move the target back.
-- CharacterMovementComponent also receives updates from the target client,
-- so the position can appear to bounce between updates.
local function zero_velocity(actor)
    local zero = { X = 0, Y = 0, Z = 0 }
    local ok1 = pcall(function() actor.Velocity = zero end)
    local ok2 = pcall(function() actor.CharacterMovement.Velocity = zero end)
    if not ok1 and not ok2 and not vel_error_shown then
        vel_error_shown = true
        print(TAG .. "info: could not reset velocity (actor.Velocity and CharacterMovement.Velocity failed)\n")
    end
end

-- Native game position-management functions discovered in Mec.hpp:
-- Net Request TP, Request TP and All TP (FVector Location, float Orientation).
-- These functions may offer better synchronization than direct property
-- writes because they belong to the game itself.
local tp_fn_used = nil
local tp_diag_shown = false

local function teleport_mec(actor, pos, yaw)
    yaw = yaw or 0.0

    local attempts = {}

    local function try(name)
        local ok, err = pcall(function()
            actor[name](actor, pos, yaw)
        end)
        attempts[#attempts + 1] = name .. ":" .. (ok and "OK" or tostring(err))
        return ok
    end

-- Attempt the host function first, then the other options.
    for _, name in ipairs({ "Net Request TP", "Request TP", "All TP" }) do
        if try(name) then
            if tp_fn_used ~= name then
                tp_fn_used = name
                print(TAG .. "using native function: " .. name .. "\n")
            end
            return true
        end
    end

-- Fallback to the previous direct-property method if native calls fail.
    local ok1 = pcall(function() actor:K2_SetActorLocation(pos, false, {}, true) end)
    local ok2 = pcall(function() actor["Net Location"] = pos end)
    zero_velocity(actor)

    if not tp_diag_shown then
        tp_diag_shown = true
        print(TAG .. "no native teleport function worked -> " .. table.concat(attempts, " | ") .. "\n")
    end
    return ok1 and ok2
end

local lastSentLoc = nil

-- HOLD mode: launcher writes grab_hold.txt only while the game window has
-- focus and the right mouse button is physically held. This deliberately avoids
-- the game-thread IsInputKeyDown polling that previously caused crashes.
local function start_grab(mec)
if not hands_up(mec) then return end -- only select when hands are raised
    local target = find_target()
    if target then
        grabbing = target
        grabYaw = 0.0
        pcall(function()
            local rot = target:K2_GetActorRotation()
            if rot and rot.Yaw then grabYaw = rot.Yaw end
        end)
        local name = "?"
        pcall(function() name = target:GetFName():ToString() end)
        print(TAG .. "grabbed: " .. name .. "\n")
    end
end

local function release_grab()
    if not grabbing then return end
    local released = "?"
    pcall(function() released = grabbing:GetFName():ToString() end)
    grabbing = nil
    lastSentLoc = nil
    print(TAG .. "released: " .. released .. "\n")
end

local grabInputHeld = false
GRAB_SET_HELD = function(held)
    if held == grabInputHeld then return end
    grabInputHeld = held
    if not held then
        if grabbing then
            grabbing = nil
            lastSentLoc = nil
            print(TAG .. "released (right mouse button up)\n")
        end
    else
        ExecuteInGameThread(function()
            if not grabInputHeld then return end
            local mec = get_mec_pc_cached()
            if mec then start_grab(mec) end
        end)
    end
end

local grabDistance = 150
local GRAB_DIST_MIN, GRAB_DIST_MAX, GRAB_DIST_STEP = 80, 500, 20

-- UE4SS cannot reliably hook the mouse wheel in this setup.
-- Use P and M to adjust the distance.
RegisterKeyBind(Key.P, function()
    grabDistance = math.min(GRAB_DIST_MAX, grabDistance + GRAB_DIST_STEP)
    print(TAG .. "grab distance: " .. grabDistance .. "\n")
end)
RegisterKeyBind(Key.M, function()
    grabDistance = math.max(GRAB_DIST_MIN, grabDistance - GRAB_DIST_STEP)
    print(TAG .. "grab distance: " .. grabDistance .. "\n")
end)
print(TAG .. "distance shortcuts ready: P = farther, M = closer (current: " .. grabDistance .. ")\n")

local MOVE_THRESHOLD = 3 -- distance threshold below which updates are not sent

local function moved_enough(a, b)
    if not b then return true end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return (dx * dx + dy * dy + dz * dz) > (MOVE_THRESHOLD * MOVE_THRESHOLD)
end

LoopAsync(25, function()
    if grabbing then
        if not grabbing:IsValid() then
            print(TAG .. "target disappeared, released automatically\n")
            grabbing = nil
            lastSentLoc = nil
        else
            local mec, pc = get_mec_pc_cached()
            if mec then
                local loc, rot = camera_loc_rot(pc)
                if loc then
                    local fwd = forward_from_rot(rot)
                    local newLoc = { X = loc.X + fwd.X * grabDistance, Y = loc.Y + fwd.Y * grabDistance, Z = loc.Z + fwd.Z * grabDistance - 80 }
                    if moved_enough(newLoc, lastSentLoc) then
                        teleport_mec(grabbing, newLoc, grabYaw)
                        lastSentLoc = newLoc
                    end
                end
            end
        end
    end
    return false
end)

print(TAG .. "HOLD grab enabled: raise hands and hold right mouse in the game; release to let go\n")

BRIDGE_COMMANDS["GRAB_DIST_PLUS"] = function()
    grabDistance = math.min(GRAB_DIST_MAX, grabDistance + GRAB_DIST_STEP)
    print(TAG .. "grab distance (bridge): " .. grabDistance .. "\n")
end
BRIDGE_COMMANDS["GRAB_DIST_MINUS"] = function()
    grabDistance = math.max(GRAB_DIST_MIN, grabDistance - GRAB_DIST_STEP)
    print(TAG .. "grab distance (bridge): " .. grabDistance .. "\n")
end
BRIDGE_COMMANDS["GRAB_RELEASE"] = function()
    if grabbing then
        grabbing = nil
        lastSentLoc = nil
        print(TAG .. "Bridge -> released\n")
    end
end
BRIDGE_STATUS_PROVIDERS[#BRIDGE_STATUS_PROVIDERS + 1] = function()
    if grabbing then
        local nm = "?"
        pcall(function() nm = grabbing:GetFName():ToString() end)
        return "Grab: " .. nm .. " (distance " .. grabDistance .. ")"
    end
    return "Grab: no target"
end
end

-- ===================== EXTERNAL BRIDGE (launcher .exe) =====================
-- Communication uses files under the Windows user's LOCALAPPDATA directory.
-- The launcher creates the bridge folder before installing this mod.
-- No sockets, extra Lua packages or shell commands are required.
local BTAG = "[BRIDGE] "

local function env(name)
    if type(os) ~= "table" or type(os.getenv) ~= "function" then return nil end
    local ok, value = pcall(os.getenv, name)
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end

-- On some UE4SS setups LOCALAPPDATA may be missing from the Lua environment.
-- Resolve the same Windows folder as Environment.SpecialFolder.LocalApplicationData.
local function find_bridge_directory()
    local candidates = {}
    local function add(path)
        if path and path ~= "" then
            candidates[#candidates + 1] = path:gsub("[/\\]+$", "") .. "\\AdminByAsticot\\bridge\\"
        end
    end
    add(env("LOCALAPPDATA"))
    local profile = env("USERPROFILE")
    if profile then add(profile .. "\\AppData\\Local") end
    local roaming = env("APPDATA")
    if roaming then add(roaming .. "\\..\\Local") end
    for _, dir in ipairs(candidates) do
        -- The launcher creates the directory. Test write access with a harmless file.
        local check = io.open(dir .. "command.txt", "a")
        if check then
            check:close()
            return dir
        end
    end
    print(BTAG .. "ERROR: bridge directory is missing or not writable. " ..
          "Open the launcher first so it can create %LOCALAPPDATA%\\AdminByAsticot\\bridge\\.\\n")
    return candidates[1]  -- retry each heartbeat; a late launcher launch may create it
end

local BRIDGE_DIR = find_bridge_directory()
local CMD_FILE = BRIDGE_DIR and (BRIDGE_DIR .. "command.txt") or nil
local STATUS_FILE = BRIDGE_DIR and (BRIDGE_DIR .. "status.txt") or nil
local ITEMS_FILE = BRIDGE_DIR and (BRIDGE_DIR .. "items.txt") or nil
local GRAB_HELD_FILE = BRIDGE_DIR and (BRIDGE_DIR .. "grab_hold.txt") or nil

local status_ok_logged = false
local write_error = nil
local cached_status = ""
local snapshot_pending = false
local snapshot_requested_at = 0

local function write_status()
    if not STATUS_FILE then return false end
    -- Heartbeat does not depend on the Unreal game thread running in menus.
    local f, err = io.open(STATUS_FILE, "w")
    if not f then
        if write_error ~= tostring(err) then
            write_error = tostring(err)
            print(BTAG .. "ERROR: cannot write status.txt to " .. STATUS_FILE .. ": " .. write_error .. "\n")
        end
        return false
    end
    local msg = "Bridge connected - AdminByAsticot v" .. VERSION
    if cached_status ~= "" then msg = msg .. "\n" .. cached_status end
    f:write(msg)
    f:close()
    write_error = nil
    if not status_ok_logged then
        status_ok_logged = true
        print(BTAG .. "status written to " .. STATUS_FILE .. "\n")
    end
    return true
end

-- Write the first status immediately so the launcher can detect the bridge
-- before joining a game; repeat every second to refresh the file timestamp.
write_status()

local function read_bridge_command()
    if not CMD_FILE then return nil end
    local f = io.open(CMD_FILE, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    content = content and content:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if content == "" then return nil end
    -- Consume the command once. Command names remain unchanged.
    local cleared = io.open(CMD_FILE, "w")
    if not cleared then
        print(BTAG .. "ERROR: cannot clear command.txt (will retry)\n")
        return nil
    end
    cleared:write("")
    cleared:close()
    return content
end

-- The catalog is requested explicitly by the launcher, not guessed or hard-coded.
BRIDGE_COMMANDS["LIST_ITEMS"] = function()
    if not ITEM_CATALOG_PROVIDER then return end
    ExecuteInGameThread(function()
        local lines = ITEM_CATALOG_PROVIDER()
        if not ITEMS_FILE then return end
        local f, err = io.open(ITEMS_FILE, "w")
        if not f then
            print(BTAG .. "cannot write items.txt: " .. tostring(err) .. "\n")
            return
        end
        f:write(table.concat(lines, "\n"))
        f:close()
        print(BTAG .. "item catalog updated (" .. #lines .. ")\n")
    end)
end

-- A persistent input-state file prevents short mouse-release events from being
-- lost when the single-command bridge is busy with another command.
local lastGrabHeld = false
LoopAsync(60, function()
    if GRAB_HELD_FILE and GRAB_SET_HELD then
        local held = false
        local f = io.open(GRAB_HELD_FILE, "r")
        if f then
            local keyState = f:read("*l") or ""
            local updated = tonumber(f:read("*l") or "")
            f:close()
            -- Fail safe: a dead launcher cannot leave HOLD mode enabled forever.
            -- Both timestamps originate on this computer (UTC epoch seconds).
            local now = type(os.time) == "function" and os.time() or 0
            held = keyState == "1" and updated ~= nil and now > 0
                and updated <= now + 1 and (now - updated) <= 2
        end
        if held ~= lastGrabHeld then
            lastGrabHeld = held
            GRAB_SET_HELD(held)
        end
    end
    return false
end)

LoopAsync(150, function()
    local cmd = read_bridge_command()
    if cmd then
        -- Exactly one optional colon separates the command from its argument.
        local name, arg = cmd:match("^([A-Z_]+):?(.*)$")
        local fn = name and BRIDGE_COMMANDS[name] or nil
        if fn then
            print(BTAG .. "command received: " .. cmd .. "\n")
            local ok, err = pcall(fn, arg)
            if not ok then print(BTAG .. "ERROR in " .. cmd .. ": " .. tostring(err) .. "\n") end
        else
            print(BTAG .. "unknown command: " .. cmd .. "\n")
        end
    end
    return false
end)

local heartbeat_logged = false
LoopAsync(1000, function()
    if not heartbeat_logged then
        heartbeat_logged = true
        print(BTAG .. "status loop started\n")
    end
    -- Status providers interact with Unreal objects and therefore must run
    -- on the game thread. A delayed snapshot MUST NOT block the heartbeat.
    if not snapshot_pending then
        snapshot_pending = true
        snapshot_requested_at = os.time and os.time() or 0
        local ok, err = pcall(ExecuteInGameThread, function()
            local lines = {}
            for _, provider in ipairs(BRIDGE_STATUS_PROVIDERS) do
                local good, result = pcall(provider)
                if good and result then lines[#lines + 1] = result end
            end
            cached_status = table.concat(lines, "\n")
            snapshot_pending = false
        end)
        if not ok then
            snapshot_pending = false
            print(BTAG .. "cannot schedule game status snapshot: " .. tostring(err) .. "\n")
        end
    end
    -- If a game-thread callback never runs, keep the heartbeat live instead.
    if snapshot_pending and type(os.time) == "function" and
            snapshot_requested_at > 0 and os.time() - snapshot_requested_at > 15 then
        snapshot_pending = false
    end
    write_status()
    return false
end)

print(BTAG .. "bridge active (" .. tostring(BRIDGE_DIR) .. ")\n")
