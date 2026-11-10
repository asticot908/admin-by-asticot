-- Admin by Asticot v1.0.1 : mod unique (a installer sur CHAQUE PC : joueur et hote).
--  * ID admin : l'ID FIXE (MY_ID) remplace le 1er admin de la liste, l'ID du compte Steam
--    qui lance le jeu (detecte automatiquement) remplace le 2e, et un 2e ID FIXE (THIRD_ID)
--    remplace le 3e -- les trois se protegent mutuellement, aucun n'ecrase les autres.
--  * Force Admin / Admin Cheat (et GM.Cheat cote hote).
--  * Log des actions du panneau debug (Page Up / Page Down / R / fleches).
--  * Touches F1-F7 : lancer / arreter / reinitialiser la partie, soin, spawn d'objet.
--  * F8 : etat | F9 : reapplique les ID.
--  * J : recharge l'arme en main au maximum de munitions | K : diagnostic de l'arme.
-- Usage prevu : lobbies prives entre tes propres comptes.

local TAG = "[ADMIN] "
local VERSION = "1.0.1" -- incrementee a chaque session de travail
print(TAG .. "Admin by Asticot v" .. VERSION .. " charge\n")

-- Table partagee : chaque section du mod y enregistre ses commandes et son statut, pour le pont
-- de fichiers avec le launcher externe (voir tout en bas du fichier, section PONT).
local BRIDGE_COMMANDS = {}
local BRIDGE_STATUS_PROVIDERS = {}

-- ===== REGLAGES =====
local MY_ID             = "76561199784972417" -- variante 1 : ID FIXE (ton Steam ID 64)
local USE_FIXED_ID      = true  -- variante 1 : ecrire MY_ID dans la liste des admins
local USE_AUTO_ID       = true  -- variante 2 : detecter automatiquement le compte Steam connecte sur ce PC
local THIRD_ID          = "76561199639774585" -- variante 3 : 2e ID FIXE (remplace le 3e admin de base)
local USE_THIRD_ID      = true  -- variante 3 : ecrire THIRD_ID dans la liste des admins
local FIXED_SLOT        = 1     -- position (a partir de 1) de l'ID fixe dans la liste
local AUTO_SLOT         = 2     -- position de l'ID detecte automatiquement
local THIRD_SLOT        = 3     -- position du 2e ID fixe
local FORCE_ADMIN_FLAGS = true  -- true = force "Admin" et "Admin Cheat" a true (aussi juste avant chaque action Debug)
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

-- Fonctions internes a surveiller (pour voir ce que chaque touche declenche reellement, y compris la mort)
local EXTRA_MEC = {
    "Death", "Net Death", "Take Damage", "Hit Health", "Respawn", "Force End",
    "Reset Player", "Net Reset Player", "Request Heal Reset", "Heal Reset",
    "Net Cheat Start Game", "Net Cheat End Game", "Net Cheat Clear Game",
    "Net Cheat DebugSpawn", "Cheat Net Spawn NewItem", "Force Menu", "Set Preset", "Debug Mic",
}
local EXTRA_GM = { "Start Game", "End Game", "Kick All Players", "Death in Lobby", "Stop Game Timer" }

local last_action, last_time = "aucune", 0
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

-- Lit la liste d'IDs sous forme de table Lua
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

-- ===== IDENTIFIANTS ADMIN (2 variantes, combinables) =====
-- Variante 1 : ID FIXE (MY_ID, ecrit dans le fichier).
-- Variante 2 : ID AUTOMATIQUE = compte Steam actuellement connecte sur ce PC
--              (lu dans Steam\config\loginusers.vdf, entree "MostRecent" = 1).
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

-- Chaque racine Steam essayee est notee ici (trouvee ou non), pour pouvoir le dire dans la console
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

    -- 1. a partir du chemin de CE fichier (si l'environnement le fournit)
    pcall(function()
        local src = debug.getinfo(1, "S").source or ""
        src = src:gsub("^@", ""):gsub("\\", "/")
        local root = src:match("^(.-)/[Ss]team[Aa]pps/")
        add(root)
    end)
    -- 2. variables d'environnement Windows courantes
    pcall(function()
        local pf86 = os.getenv("ProgramFiles(x86)")
        if pf86 then add(pf86:gsub("\\", "/") .. "/Steam") end
    end)
    pcall(function()
        local pf = os.getenv("ProgramFiles")
        if pf then add(pf:gsub("\\", "/") .. "/Steam") end
    end)
    pcall(function()
        local drive = os.getenv("SystemDrive") -- ex: "C:"
        if drive then add(drive .. "/SteamLibrary") end
    end)
    -- 3. emplacements standards
    add("C:/Program Files (x86)/Steam")
    add("C:/Program Files/Steam")
    add("D:/Steam")
    add("D:/SteamLibrary")
    add("E:/Steam")

    return roots
end

-- Essaie plusieurs ecritures de cle, Valve n'est pas toujours coherent sur la casse
local MOSTRECENT_PATTERNS = {
    '"[Mm]ost[Rr]ecent"%s*"1"',
    '"MostRecent"%s*"1"',
    '"mostrecent"%s*"1"',
}

local function detect_steam_id()
    local candidates = {} -- tous les comptes valides trouves, avec leur statut MostRecent
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
            -- le fichier a ete trouve : pas la peine de regarder les autres racines
            break
        end
    end

    if #candidates == 0 then
        return nil, any_file_found and "fichier trouve mais aucun compte Steam valide dedans" or "fichier introuvable a tous les emplacements essayes"
    end

    for _, cand in ipairs(candidates) do
        if cand.recent then return cand.id, nil, candidates end
    end
    -- aucun compte marque "le plus recent" : si un seul compte existe, on le prend quand meme
    if #candidates == 1 then
        return candidates[1].id, "un seul compte trouve, pris par defaut (aucun marque comme actif)", candidates
    end
    return nil, #candidates .. " comptes trouves mais aucun marque comme actif", candidates
end

local AUTO_ID = nil
if USE_AUTO_ID then
    local okd, a, b, c = pcall(detect_steam_id)
    if okd and a then
        AUTO_ID = a
        print(TAG .. "ID Steam detecte automatiquement : " .. a .. (b and (" (" .. b .. ")") or "") .. "\n")
    else
        local reason = okd and b or tostring(a)
        print(TAG .. "detection automatique impossible : " .. tostring(reason) .. "\n")
        for _, t in ipairs(tried_paths) do
            print(TAG .. "  essaye : " .. t.path .. " -> " .. (t.found and ("trouve, " .. t.size .. " octets") or "introuvable") .. "\n")
        end
        if okd and c then
            for _, cand in ipairs(c) do
                print(TAG .. "  compte trouve dans le fichier : " .. cand.id .. " (" .. cand.name .. ") actif=" .. tostring(cand.recent) .. "\n")
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

-- protected peut etre un seul ID (string) ou une liste d'IDs (table) a ne jamais ecraser
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

-- Ecrit un ID dans "Ultimate Admins" s'il n'y est pas, sans ecraser les autres ID (protected)
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

    -- methode A puis methode B, avec verification a chaque fois
    pcall(function() gi["Ultimate Admins"][idx] = id end)
    local now = read_list(gi["Ultimate Admins"])
    if now[idx] ~= id then
        pcall(function() gi["Ultimate Admins"][idx]:set(id) end)
        now = read_list(gi["Ultimate Admins"])
    end

    if now[idx] == id then
        print(string.format("%sID %s (%s) place en position %d (ancien : %s)\n", TAG, label, id, idx, tostring(old)))
    else
        fail_count = fail_count + 1
        if fail_count <= 3 then
            print(TAG .. "ECHEC du placement de l'ID " .. label .. " (liste inchangee)\n")
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
        place_id(gi, third, THIRD_SLOT, { fixed, auto }, "fixe 2")
    end
end

local function force_flags(gi)
    pcall(function() gi["Admin"] = true end)
    pcall(function() gi["Admin Cheat"] = true end)
end

-- Met MY_ID dans la liste si absent, et force les flags si demande
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
        parts[#parts + 1] = "Mon ID present=" .. tostring(has_my_id(read_list(gi["Ultimate Admins"])))
        if AUTO_ID then parts[#parts + 1] = "ID auto present=" .. tostring(list_has(read_list(gi["Ultimate Admins"]), AUTO_ID)) end
        if USE_THIRD_ID then parts[#parts + 1] = "ID fixe 2 present=" .. tostring(list_has(read_list(gi["Ultimate Admins"]), THIRD_ID)) end
    else
        parts[#parts + 1] = "MainGI introuvable"
    end
    -- Mec du joueur local (via le PlayerController), sinon le premier Mec trouve
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
        parts[#parts + 1] = "Mec introuvable"
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
                    extra = " | objet=" .. nm
                end
                print(string.format("%s   -> %s.%s%s | %.0f ms apres l'action %s\n", TAG, who, n, extra, dt, last_action))
            end)
        end)
        if not ok then
            print(TAG .. "hook impossible : " .. who .. "." .. n .. " -> " .. tostring(err) .. "\n")
        end
    end
end

-- Hooks sur MainGI : on remet ton ID juste avant les moments ou le jeu pourrait relire la liste
local function register_gi()
    for _, n in ipairs(GI_FUNCS) do
        local ok, err = pcall(function()
            RegisterHook(GI_BASE .. n, function(self) ensure_admin() end)
        end)
        if not ok then
            print(TAG .. "hook MainGI impossible : " .. n .. " -> " .. tostring(err) .. "\n")
        end
    end
end

-- Hooks sur le personnage et le controleur : log des actions et des touches
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
            print(TAG .. "hook IMPOSSIBLE : " .. label .. " -> " .. tostring(err) .. "\n")
        end
    end

    local ok, err = pcall(function()
        RegisterHook(pcPath .. ":" .. PC_ANYKEY, function(self, Key)
            local k = key_name(Key)
            if not k:find("^Mouse") and not k:find("^Gamepad") then
                print(string.format("%sTOUCHE %s\n", TAG, k))
            end
        end)
    end)
    if not ok then
        print(TAG .. "hook AnyKey IMPOSSIBLE -> " .. tostring(err) .. "\n")
    end
    hook_extra(mecPath, EXTRA_MEC, "Mec")
    local gmPath = class_path("GM_C")
    if gmPath then
        hook_extra(gmPath, EXTRA_GM, "GM")
    else
        print(TAG .. "GM_C introuvable (normal si tu n'es pas l'hote)\n")
    end
    print(TAG .. "hooks d'entree enregistres. Etat : " .. snapshot() .. "\n")
end

local function try_register()
    if not gi_registered and get_gi() then
        gi_registered = true
        register_gi()
        ensure_admin()
        print(TAG .. "MainGI trouve, hooks admin enregistres. Etat : " .. snapshot() .. "\n")
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

print(TAG .. "mod charge (ID configure : " .. MY_ID .. ")\n")

-- Boucle : enregistre les hooks des que possible, puis re-verifie la liste toutes les 2 s
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
        print(TAG .. "Pont -> ID reappliques\n")
    end)
end
BRIDGE_STATUS_PROVIDERS[#BRIDGE_STATUS_PROVIDERS + 1] = function() return snapshot() end

-- ===================== PANNEAU F1-F7 =====================
do
-- AdminPanel : remplace le panneau admin casse par des touches F1-F7 qui appellent directement
-- les fonctions "Cheat" du jeu (trouvees dans Mec.hpp). A utiliser dans un lobby prive, en tant qu'hote.
--
--  F1 : lancer la partie          (Net Cheat Start Game)
--  F2 : arreter la partie         (Net Cheat End Game)
--  F3 : reinitialiser la partie   (Net Cheat Clear Game)
--  F4 : soin / reset de la vie    (Request Heal Reset)
--  F5 : faire apparaitre l'objet selectionne devant toi
--  F6 : objet suivant dans la liste
--  F7 : afficher la liste des objets dans la console

local TAG = "[PANEL] "
local items, item_index = {}, 1

-- Le Mec du joueur local (via le PlayerController)
local function get_mec()
    local ok, pc = pcall(FindFirstOf, "PC_C")
    if not ok or not pc or not pc:IsValid() then return nil end
    local ok2, mec = pcall(function() return pc["Mec Ref"] end)
    if ok2 and mec and mec:IsValid() then return mec end
    return nil
end

-- Le mode de jeu n'existe que chez l'hote : on active son drapeau "Cheat"
local function enable_cheat()
    local ok, gm = pcall(FindFirstOf, "GM_C")
    if ok and gm and gm:IsValid() then
        pcall(function() gm["Cheat"] = true end)
        return true
    end
    return false
end

-- Appelle une fonction du jeu (les noms contiennent des espaces) et log le resultat
local function call(obj, name, ...)
    local args = { ... }
    local ok, err = pcall(function()
        local fn = obj[name]
        fn(obj, table.unpack(args))
    end)
    if ok then
        print(TAG .. name .. " : appel OK\n")
    else
        print(TAG .. "ERREUR sur " .. name .. " : " .. tostring(err) .. "\n")
    end
    return ok
end

local function command(label, fname)
    ExecuteInGameThread(function()
        local mec = get_mec()
        if not mec then
            print(TAG .. label .. " : personnage introuvable (es-tu en partie ?)\n")
            return
        end
        if not enable_cheat() then
            print(TAG .. "mode de jeu (GM_C) introuvable : es-tu bien l'hote du lobby ?\n")
        end
        print(TAG .. label .. "\n")
        call(mec, fname)
    end)
end

-- Liste des objets (assets de donnees d'items deja charges en memoire)
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
    print(TAG .. #items .. " objet(s) trouve(s)\n")
end

local function spawn_item()
    local mec = get_mec()
    if not mec then print(TAG .. "personnage introuvable\n") return end
    if #items == 0 then load_items() end
    if #items == 0 then
        print(TAG .. "aucun objet dans la liste (FindAllOf n'a rien retourne)\n")
        return
    end
    enable_cheat()
    local it = items[item_index]

    local loc = { X = 0, Y = 0, Z = 0 }
    local fwd = { X = 1, Y = 0, Z = 0 }
    pcall(function()
        local l = mec:K2_GetActorLocation()
        local f = mec:GetActorForwardVector()
        fwd = { X = f.X, Y = f.Y, Z = 0 }
        loc = { X = l.X + f.X * 150, Y = l.Y + f.Y * 150, Z = l.Z + 40 }
    end)

    print(TAG .. "spawn de : " .. it.name .. "\n")
    call(mec, "Cheat Net Spawn NewItem", loc, { X = 0, Y = 0, Z = 0 }, fwd, it.obj, {})
end

-- Garde le drapeau Cheat du mode de jeu actif
LoopAsync(2000, function()
    ExecuteInGameThread(enable_cheat)
    return false
end)

print(TAG .. "mod charge : commandes disponibles via le launcher externe (plus de touches F1-F7)\n")

BRIDGE_COMMANDS["START_GAME"] = function() command("Pont -> lancer la partie", "Net Cheat Start Game") end
BRIDGE_COMMANDS["END_GAME"] = function() command("Pont -> arreter la partie", "Net Cheat End Game") end
BRIDGE_COMMANDS["RESET_GAME"] = function() command("Pont -> reinitialiser la partie", "Net Cheat Clear Game") end
BRIDGE_COMMANDS["HEAL"] = function() command("Pont -> soin / reset vie", "Request Heal Reset") end
BRIDGE_COMMANDS["SPAWN_ITEM"] = function() ExecuteInGameThread(spawn_item) end
BRIDGE_COMMANDS["NEXT_ITEM"] = function()
    ExecuteInGameThread(function()
        if #items == 0 then load_items() end
        if #items == 0 then return end
        item_index = (item_index % #items) + 1
        print(TAG .. "objet selectionne (pont) : " .. items[item_index].name .. "\n")
    end)
end
BRIDGE_STATUS_PROVIDERS[#BRIDGE_STATUS_PROVIDERS + 1] = function()
    if #items == 0 then return "Objet selectionne : (liste non chargee, F7 ou bouton Suivant)" end
    local it = items[item_index]
    return "Objet selectionne : " .. (it and it.name or "?") .. " (" .. item_index .. "/" .. #items .. ")"
end
end

-- ===================== MUNITIONS (J) =====================
-- J : recharge l'arme en main au maximum de munitions
-- K : affiche dans la console les proprietes de l'arme et de son etat (diagnostic)
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

-- Parcourt les proprietes d'une classe et de ses parents (on s'arrete aux classes du moteur)
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

-- Structure (type) d'une propriete de type struct du Mec, ex. "Hand State"
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
    if not mec then print(TAG .. "personnage introuvable (es-tu en partie ?)\n") return end
    local it = hand_item(mec)
    if not it then print(TAG .. "rien en main\n") return end
    print(TAG .. "objet en main : " .. item_name(it) .. "\n")

    print(TAG .. "--- proprietes de l'objet ---\n")
    each_class_prop(it:GetClass(), function(p)
        local name, ptype = pinfo(p)
        local val = "?"
        pcall(function() val = tostring(it[name]) end)
        print(string.format("%s  %s (%s) = %s\n", TAG, name, ptype, val))
    end)

    print(TAG .. "--- etat de l'objet (Hand State) ---\n")
    local st = struct_of(mec, "Hand State")
    if not st then
        print(TAG .. "  structure introuvable\n")
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
-- D'apres l'inspection reelle (K) : le chargeur maximum est le champ exact "Capacity" sur l'objet,
-- et la valeur actuelle est le champ "Value" dans "Hand State" (nom technique Value_<hash>, commun a tous les objets).

local function refill(quiet)
    local mec = get_mec()
    if not mec then
        if not quiet then print(TAG .. "personnage introuvable (es-tu en partie ?)\n") end
        return
    end
    local it = hand_item(mec)
    if not it then
        if not quiet then print(TAG .. "rien en main\n") end
        return
    end

    -- 1. valeur maximale : d'abord le champ exact "Capacity", sinon on retombe sur la recherche par mots-cles
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
            print(TAG .. "valeur maximale introuvable pour " .. item_name(it) .. " : fais K et envoie-moi les lignes [AMMO]\n")
        end
        return
    end

    -- 2. champ des munitions dans l'etat de l'objet (Hand State)
    local st = struct_of(mec, "Hand State")
    if not st then
        if not quiet then print(TAG .. "structure Hand State introuvable\n") end
        return
    end
    local fields = {}
    pcall(function()
        st:ForEachProperty(function(p)
            local name, ptype = pinfo(p)
            local l = name:lower()
            -- "Value_<hash>" est le champ generique utilise par le jeu pour la valeur courante
            -- (munitions actuelles pour une arme). On le prend en priorite, sinon les mots-cles habituels.
            if NUMERIC[ptype] and (l:find("^value") or has_any(l, AMMO_WORDS)) then
                fields[#fields + 1] = { name = name, ptype = ptype }
            end
        end)
    end)
    if #fields == 0 then
        if not quiet then
            print(TAG .. "aucun champ de munitions dans l'etat de " .. item_name(it) .. " (cet objet n'a peut-etre pas de munitions)\n")
        end
        return
    end

    -- 3. ecriture puis verification (en mode silencieux, on n'ecrit que si la valeur a change,
    -- pour que les munitions illimitees ne spamment pas la console en continu)
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
            print(string.format("%s%s : %s = %s (maximum lu dans %s = %s)\n", TAG, item_name(it), f.name, after, best_name, tostring(best)))
        end
    end

    -- 4. rafraichit l'affichage des munitions
    pcall(function() mec["Set Ammo"](mec) end)
end

-- ----- Munitions illimitees (V) : reapplique le maximum en continu tant que c'est active -----
local unlimited_ammo = false

local ok3, err3 = pcall(function()
    RegisterKeyBind(Key.V, function()
        unlimited_ammo = not unlimited_ammo
        print(TAG .. "munitions illimitees : " .. (unlimited_ammo and "activees" or "desactivees") .. "\n")
        if unlimited_ammo then ExecuteInGameThread(function() refill() end) end
    end)
end)
if ok3 then
    print(TAG .. "touche V enregistree (munitions illimitees)\n")
else
    print(TAG .. "ECHEC enregistrement touche V -> " .. tostring(err3) .. "\n")
end

LoopAsync(50, function()
    if unlimited_ammo then
        ExecuteInGameThread(function() refill(true) end)
    end
    return false -- on continue indefiniment
end)

-- Chaque enregistrement est protege : si l'API attendue n'existe pas sur cette version
-- d'UE4SS, on le voit dans la console au lieu d'un echec silencieux.
local ok1, err1 = pcall(function()
    RegisterKeyBind(Key.J, function() ExecuteInGameThread(refill) end)
end)
if ok1 then
    print(TAG .. "touche J enregistree (recharge au maximum)\n")
else
    print(TAG .. "ECHEC enregistrement touche J -> " .. tostring(err1) .. "\n")
end

-- Diagnostic sur K plutot que Ctrl+J : evite de dependre de l'API des touches modificatrices,
-- qui n'est peut-etre pas la cause du probleme mais qu'on ecarte par prudence.
local ok2, err2 = pcall(function()
    RegisterKeyBind(Key.K, function() ExecuteInGameThread(dump) end)
end)
if ok2 then
    print(TAG .. "touche K enregistree (diagnostic)\n")
else
    print(TAG .. "ECHEC enregistrement touche K -> " .. tostring(err2) .. "\n")
end

print(TAG .. "J : recharge au maximum | K : diagnostic | V : munitions illimitees\n")

BRIDGE_COMMANDS["REFILL_AMMO"] = function() ExecuteInGameThread(refill) end
BRIDGE_COMMANDS["AMMO_DIAG"] = function() ExecuteInGameThread(dump) end
BRIDGE_COMMANDS["TOGGLE_UNLIMITED"] = function()
    unlimited_ammo = not unlimited_ammo
    print(TAG .. "munitions illimitees (pont) : " .. (unlimited_ammo and "activees" or "desactivees") .. "\n")
    if unlimited_ammo then ExecuteInGameThread(function() refill() end) end
end
BRIDGE_STATUS_PROVIDERS[#BRIDGE_STATUS_PROVIDERS + 1] = function()
    return "Munitions illimitees : " .. (unlimited_ammo and "ON" or "OFF")
end
end

-- ===================== PRISE / DEPLACEMENT D'UN JOUEUR =====================
-- Mains levees (touche de reddition du jeu) + clic droit sur un joueur : le saisit.
-- Un deuxieme clic droit : le relache. Fonctionnalite experimentale, voir les limites
-- expliquees avec ce mod : ca doit etre fait depuis le PC qui heberge pour etre vu par tout
-- le monde, et le deplacement peut etre saccade car le jeu gere aussi son propre mouvement.
do
local TAG = "[GRAB] "

local function get_mec_pc()
    local ok, pc = pcall(FindFirstOf, "PC_C")
    if not ok or not pc or not pc:IsValid() then return nil, nil end
    local ok2, mec = pcall(function() return pc["Mec Ref"] end)
    if ok2 and mec and mec:IsValid() then return mec, pc end
    return nil, pc
end

-- Variante mise en cache : evite de refaire une recherche FindFirstOf("PC_C") (cout engine)
-- a chaque frame dans les boucles rapides (grab). Le PC/perso du joueur local ne change pas
-- d'une frame a l'autre, donc on ne revalide que leur validite (IsValid), peu couteux.
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
local cached_cam = nil -- evite de rechercher la camera a chaque appel (elle ne change pas d'une frame a l'autre)

local function get_camera_manager(pc)
    if cached_cam and cached_cam.IsValid and cached_cam:IsValid() then return cached_cam, nil end
    cached_cam = nil

    -- essai 1 : fonction native
    local ok1, cam1 = pcall(function() return pc:GetPlayerCameraManager() end)
    if ok1 and cam1 and cam1.IsValid and cam1:IsValid() then cached_cam = cam1; return cam1, nil end
    -- essai 2 : propriete directe (le nom Unreal habituel pour cette reference)
    local ok2, cam2 = pcall(function() return pc.PlayerCameraManager end)
    if ok2 and cam2 and cam2.IsValid and cam2:IsValid() then cached_cam = cam2; return cam2, nil end
    local reasons = "essai 1 (GetPlayerCameraManager) -> " ..
        (ok1 and "objet invalide ou nil" or tostring(cam1)) ..
        " | essai 2 (PlayerCameraManager) -> " ..
        (ok2 and "objet invalide ou nil" or tostring(cam2))
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
local grabYaw = 0.0 -- orientation figee au moment de la saisie (evite de la relire chaque frame)
local trace_error_shown = false
local shape_debug_count = 0

-- Au lieu d'un tir de rayon physique (qui depend de reglages de collision propres au jeu,
-- et qui ne touchait rien), on prend simplement le joueur le plus proche de la direction
-- du viseur, par calcul de position. Plus simple, et independant de ces reglages.
local MAX_ANGLE_COS = 0.90 -- ~25 degres de tolerance autour du viseur
local MAX_DISTANCE = 1000

local function find_target()
    local mec, pc = get_mec_pc()
    if not mec or not pc then print(TAG .. "personnage introuvable\n") return nil end

    local loc, rot, cerr = camera_loc_rot(pc)
    if not loc then print(TAG .. "camera : " .. tostring(cerr) .. "\n") return nil end
    local fwd = forward_from_rot(rot)

    local ok, all = pcall(FindAllOf, "Mec_C")
    if not ok or not all then
        print(TAG .. "liste des joueurs introuvable\n")
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
        print(TAG .. "personne dans le viseur (" .. checked .. " joueur(s) regarde(s))\n")
        return nil
    end
    print(TAG .. "trouve : " .. bestName .. " a " .. math.floor(bestDist) .. " unites\n")
    return best
end

-- Deplace reellement la cible en reseau : K2_SetActorLocation seul ne bouge que ce que TOI tu
-- vois localement. Il faut aussi ecrire la propriete "Net Location", qui est le champ replique
-- que le jeu utilise pour synchroniser la position aupres des autres clients. C'est ce que fait
-- la commande "bring" de DexAdditions (via Fur.TeleportMec) -- technique reprise ici.
local vel_error_shown = false

-- Annule la vitesse de la cible : si elle garde une vitesse residuelle (meme nulle mais recalculee
-- par son CharacterMovementComponent a partir de ce que SON client envoie), ca alimente le
-- "rebond" vers sa position d'origine a chaque tick.
local function zero_velocity(actor)
    local zero = { X = 0, Y = 0, Z = 0 }
    local ok1 = pcall(function() actor.Velocity = zero end)
    local ok2 = pcall(function() actor.CharacterMovement.Velocity = zero end)
    if not ok1 and not ok2 and not vel_error_shown then
        vel_error_shown = true
        print(TAG .. "info : impossible d'annuler la vitesse (actor.Velocity et CharacterMovement.Velocity ont echoue)\n")
    end
end

-- Vrai systeme de teleportation du jeu (trouve dans le dump Mec.hpp) : Net Request TP / Request TP
-- / All TP, toutes avec la signature (FVector Location, float Orientation). C'est le mecanisme
-- que le jeu utilise lui-meme (probablement pour le spawn), donc normalement deja bien synchronise
-- en reseau -- contrairement a notre ecriture brute de position.
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

    -- On essaie d'abord la fonction serveur directe (on est host), puis les deux autres.
    for _, name in ipairs({ "Net Request TP", "Request TP", "All TP" }) do
        if try(name) then
            if tp_fn_used ~= name then
                tp_fn_used = name
                print(TAG .. "utilise la fonction native : " .. name .. "\n")
            end
            return true
        end
    end

    -- Repli si aucune des 3 fonctions natives ne marche : ancienne methode brute.
    local ok1 = pcall(function() actor:K2_SetActorLocation(pos, false, {}, true) end)
    local ok2 = pcall(function() actor["Net Location"] = pos end)
    zero_velocity(actor)

    if not tp_diag_shown then
        tp_diag_shown = true
        print(TAG .. "aucune fonction TP native n'a marche -> " .. table.concat(attempts, " | ") .. "\n")
    end
    return ok1 and ok2
end

local lastSentLoc = nil

-- Detection par clic (toggle) : mecanisme stable utilise depuis le debut de la session, jamais
-- en cause dans un plantage. On a tente une detection "hold" via IsInputKeyDown interrogee en
-- boucle (40x/seconde) : le rapport de crash a montre un plantage natif reproductible a
-- l'interieur meme de UE4SS, appele en boucle depuis le Tick -- tres probablement cette fonction
-- mal utilisee. On revient donc a ce systeme eprouve.
local function start_grab(mec)
    if not hands_up(mec) then return end -- condition : mains levees pour saisir
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
        print(TAG .. "saisi : " .. name .. "\n")
    end
end

local function release_grab()
    if not grabbing then return end
    local released = "?"
    pcall(function() released = grabbing:GetFName():ToString() end)
    grabbing = nil
    lastSentLoc = nil
    print(TAG .. "relache : " .. released .. "\n")
end

local function on_right_click()
    local mec = get_mec_pc_cached()
    if not mec then return end
    if grabbing then release_grab() else start_grab(mec) end
end

local grabDistance = 150
local GRAB_DIST_MIN, GRAB_DIST_MAX, GRAB_DIST_STEP = 80, 500, 20

-- UE4SS ne peut pas se brancher sur la molette (pas de code de touche pour elle), donc la
-- distance se regle avec P (eloigner) / M (rapprocher).
RegisterKeyBind(Key.P, function()
    grabDistance = math.min(GRAB_DIST_MAX, grabDistance + GRAB_DIST_STEP)
    print(TAG .. "distance de saisie : " .. grabDistance .. "\n")
end)
RegisterKeyBind(Key.M, function()
    grabDistance = math.max(GRAB_DIST_MIN, grabDistance - GRAB_DIST_STEP)
    print(TAG .. "distance de saisie : " .. grabDistance .. "\n")
end)
print(TAG .. "raccourcis distance prets : P = eloigner, M = rapprocher (actuel : " .. grabDistance .. ")\n")

local MOVE_THRESHOLD = 3 -- unites ; en dessous, on ne renvoie pas la commande (evite de spammer le reseau)

local function moved_enough(a, b)
    if not b then return true end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return (dx * dx + dy * dy + dz * dz) > (MOVE_THRESHOLD * MOVE_THRESHOLD)
end

LoopAsync(25, function()
    if grabbing then
        if not grabbing:IsValid() then
            print(TAG .. "la cible a disparu, relache automatique\n")
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

local function class_path(short)
    local ok, obj = pcall(FindFirstOf, short)
    if not ok or not obj or not obj:IsValid() then return nil end
    local ok2, full = pcall(function() return obj:GetClass():GetFullName() end)
    if not ok2 or not full then return nil end
    return full:match("^%S+%s+(.+)$") or full
end

local listening = false
LoopAsync(1000, function()
    if listening then return true end
    local pcPath = class_path("PC_C")
    if not pcPath then return false end
    listening = true
    local ok, err = pcall(function()
        RegisterHook(pcPath .. ":InpActEvt_AnyKey_K2Node_InputKeyEvent_0", function(self, KeyParam)
            local ok2, k = pcall(function() return KeyParam:get().KeyName:ToString() end)
            if ok2 and k == "RightMouseButton" then on_right_click() end
        end)
    end)
    if ok then print(TAG .. "ecoute du clic droit activee\n")
    else print(TAG .. "ECHEC ecoute clic droit -> " .. tostring(err) .. "\n") end
    return true
end)

print(TAG .. "mod charge : mains levees + clic droit sur un joueur pour le saisir, reclic pour relacher\n")

BRIDGE_COMMANDS["GRAB_DIST_PLUS"] = function()
    grabDistance = math.min(GRAB_DIST_MAX, grabDistance + GRAB_DIST_STEP)
    print(TAG .. "distance de saisie (pont) : " .. grabDistance .. "\n")
end
BRIDGE_COMMANDS["GRAB_DIST_MINUS"] = function()
    grabDistance = math.max(GRAB_DIST_MIN, grabDistance - GRAB_DIST_STEP)
    print(TAG .. "distance de saisie (pont) : " .. grabDistance .. "\n")
end
BRIDGE_COMMANDS["GRAB_RELEASE"] = function()
    if grabbing then
        grabbing = nil
        lastSentLoc = nil
        print(TAG .. "Pont -> relache\n")
    end
end
BRIDGE_STATUS_PROVIDERS[#BRIDGE_STATUS_PROVIDERS + 1] = function()
    if grabbing then
        local nm = "?"
        pcall(function() nm = grabbing:GetFName():ToString() end)
        return "Grab : " .. nm .. " (distance " .. grabDistance .. ")"
    end
    return "Grab : aucune cible"
end
end

-- ===================== PONT EXTERNE (launcher .exe) =====================
-- Echange par fichiers avec le launcher externe : pas besoin de sockets, juste un dossier
-- partage que le launcher et le mod lisent/ecrivent chacun de leur cote.
local BRIDGE_DIR = (os.getenv("LOCALAPPDATA") or "C:\\ProgramData") .. "\\AdminByAsticot\\bridge\\"
local CMD_FILE = BRIDGE_DIR .. "command.txt"
local STATUS_FILE = BRIDGE_DIR .. "status.txt"
local BTAG = "[PONT] "

pcall(function() os.execute('mkdir "' .. BRIDGE_DIR .. '" 2> NUL') end)

local function read_bridge_command()
    local f = io.open(CMD_FILE, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    content = content and content:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if content == "" then return nil end
    -- vide le fichier tout de suite pour ne pas executer deux fois la meme commande
    local fw = io.open(CMD_FILE, "w")
    if fw then fw:write("") fw:close() end
    return content
end

LoopAsync(150, function()
    local cmd = read_bridge_command()
    if cmd then
        local fn = BRIDGE_COMMANDS[cmd]
        if fn then
            print(BTAG .. "commande recue : " .. cmd .. "\n")
            local ok, err = pcall(fn)
            if not ok then print(BTAG .. "ERREUR sur " .. cmd .. " -> " .. tostring(err) .. "\n") end
        else
            print(BTAG .. "commande inconnue : " .. cmd .. "\n")
        end
    end
    return false
end)

local status_loop_logged = false
local status_ok_logged = false
local status_err_logged = false

LoopAsync(1000, function()
    if not status_loop_logged then
        status_loop_logged = true
        print(BTAG .. "boucle statut demarree\n")
    end
    ExecuteInGameThread(function()
        local lines = {}
        for _, provider in ipairs(BRIDGE_STATUS_PROVIDERS) do
            local ok, text = pcall(provider)
            if ok and text then lines[#lines + 1] = text end
        end
        local f, ferr = io.open(STATUS_FILE, "w")
        if f then
            f:write(table.concat(lines, "\n"))
            f:close()
            if not status_ok_logged then
                status_ok_logged = true
                print(BTAG .. "statut ecrit dans " .. STATUS_FILE .. "\n")
            end
        elseif not status_err_logged then
            status_err_logged = true
            print(BTAG .. "ERREUR : impossible d'ecrire " .. STATUS_FILE .. " -> " .. tostring(ferr) .. "\n")
        end
    end)
    return false
end)

print(BTAG .. "pont actif (" .. BRIDGE_DIR .. ")\n")
