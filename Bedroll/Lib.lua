-- Lib.lua: the few helpers Bedroll needs, so it runs on its own. They mirror the author's shared library (AlcCore,
-- 2026-11-06), cut down to what Bedroll calls:
--   secret values (Value, Num, Read): in combat the client hands addons "secret" values that Lua may not compare or
--     do arithmetic on; these return nil for them
--   error isolation (Safe): every way into Bedroll's code runs under xpcall; the first error goes to the game's error
--     handler (BugSack shows it), repeats are counted, and after 20 that part switches itself off until /reload
--   timers, scripts, a throttled OnUpdate, a guarded event registration
--   combat state from the regen events, and Defer: a secure change (showing the button) waits for combat to end
--   OnLoad (saved variables are ready), a bag count that is read again only when the bags change
local ADDON, ns = ...
local L = {}
ns.L = L

--------------------------------------------------------------------- secret values
local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end
L.IsSecret = IsSecret

-- the value when Lua may use it, else nil (always exactly one return)
function L.Value(v)
	if v ~= nil and not IsSecret(v) then return v end
	return nil
end

-- a readable number, else nil
function L.Num(v)
	if v == nil or IsSecret(v) or type(v) ~= "number" then return nil end
	return v
end

-- pcall(fn, ...) and Value() in one: the first return when the call worked and it is readable, else nil
function L.Read(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if not ok then return nil end
	return L.Value(v)
end

--------------------------------------------------------------------- error isolation
local MAX_ERRORS = 20
local errors = {}
L.errors = errors

local function report(label, err)
	local e = errors[label]
	if not e then
		e = { count = 0, first = tostring(err) }
		errors[label] = e
	end
	e.count = e.count + 1
	if e.count == 1 then
		local handler = geterrorhandler and geterrorhandler()
		if handler then pcall(handler, ADDON .. ": " .. label .. ": " .. tostring(err)) end
	elseif e.count == MAX_ERRORS then
		e.off = true
		print("|cffc8a2ff" .. ADDON .. "|r: " .. label .. " failed " .. MAX_ERRORS .. " times and is off until /reload.")
	end
end

-- the game's xpcall passes extra arguments on; plain Lua 5.1's does not (the test harness runs that)
local XPCALL_ARGS = select(2, xpcall(function(a) return a end, function() end, true)) == true

function L.Safe(label, fn)
	local function trace(err) return debugstack and (tostring(err) .. "\n" .. debugstack(2, 6, 0)) or tostring(err) end
	return function(...)
		local e = errors[label]
		if e and e.off then return end
		local ok, err
		if XPCALL_ARGS then
			ok, err = xpcall(fn, trace, ...)
		else
			local n, args = select("#", ...), { ... }
			ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, trace)
		end
		if not ok then report(label, err) end
	end
end

--------------------------------------------------------------------- timers, scripts, events
function L.After(seconds, fn, label)
	local safe = L.Safe(label or "timer", fn)
	if C_Timer and C_Timer.After then C_Timer.After(seconds, safe) else safe() end
end

function L.Script(frame, script, fn, label)
	frame:SetScript(script, L.Safe(label or script, fn))
end

-- fn at most once per `seconds` while the frame is shown (hide the frame to stop it)
function L.Every(frame, seconds, fn, label)
	local elapsed = 0
	local safe = L.Safe(label or "OnUpdate", fn)
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed < seconds then return end
		elapsed = 0
		safe()
	end)
end

-- RegisterEvent / RegisterUnitEvent (units given) that never throws: an event a patch removed is skipped
function L.Register(frame, event, ...)
	local valid = C_EventUtils and C_EventUtils.IsEventValid
	if valid then
		local ok, v = pcall(valid, event)   -- guard: a client whose test throws
		if ok and v == false then return false end
	end
	local ok
	if select("#", ...) > 0 then ok = pcall(frame.RegisterUnitEvent, frame, event, ...)   -- guard: unknown events throw
	else ok = pcall(frame.RegisterEvent, frame, event) end                                 -- guard: as above
	return ok
end

--------------------------------------------------------------------- combat
-- from the regen events: on this client the lockdown query did not report true when the events fired
local inCombat = false
if UnitAffectingCombat then
	local ok, v = pcall(UnitAffectingCombat, "player")   -- guard: legacy global
	if ok and v == true then inCombat = true end
end
function L.InCombat() return inCombat end

-- the protected-action lockdown: the global InCombatLockdown where it exists, else C_RestrictedActions' (the two
-- moved between builds), else the regen state alone
local function Lockdown()
	if inCombat then return true end
	local fn = InCombatLockdown or (C_RestrictedActions and C_RestrictedActions.InCombatLockdown)
	if fn then
		local ok, v = pcall(fn)   -- guard: as above
		if ok and v == false then return false end
		if ok and v == true then return true end
	end
	return false
end

local combatSubs = {}
function L.OnCombatChanged(fn, label) combatSubs[#combatSubs + 1] = L.Safe(label or "combat", fn) end

-- fn now when out of lockdown, else once when combat ends (the last fn per key wins)
local deferred, deferOrder = {}, {}
function L.Defer(key, fn)
	if not Lockdown() then
		fn()
		return true
	end
	if not deferred[key] then deferOrder[#deferOrder + 1] = key end
	deferred[key] = fn
	return false
end

local function RunDeferred()
	if Lockdown() then return end
	local order = deferOrder
	deferOrder = {}
	for _, key in ipairs(order) do
		local fn = deferred[key]
		deferred[key] = nil
		if fn then L.Safe("deferred " .. key, fn)() end
	end
end

--------------------------------------------------------------------- loading, bags
local loadFns, bagFns = {}, {}
function L.OnLoad(fn) loadFns[#loadFns + 1] = L.Safe("OnLoad", fn) end
function L.OnBagsChanged(fn) bagFns[#bagFns + 1] = L.Safe("bags", fn) end

local counts = {}   -- itemID -> count, until the bags change
function L.Count(itemID)
	if counts[itemID] then return counts[itemID] end
	local C = C_Container
	local n = 0
	if C and C.GetContainerNumSlots and C.GetContainerItemInfo then
		for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 do
			local ok, slots = pcall(C.GetContainerNumSlots, bag)   -- guard: a bag id the client refuses
			slots = ok and L.Num(slots) or 0
			for slot = 1, slots do
				local okI, info = pcall(C.GetContainerItemInfo, bag, slot)   -- guard: as above
				if okI and type(info) == "table" and L.Value(info.itemID) == itemID then
					n = n + (L.Num(info.stackCount) or 1)
				end
			end
		end
	end
	counts[itemID] = n
	return n
end

local pending = false
local function BagsChanged()
	counts = {}
	if pending then return end
	pending = true
	L.After(0, function()
		pending = false
		for _, f in ipairs(bagFns) do f() end
	end, "bags")
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "BAG_UPDATE_DELAYED",
	"PLAYER_ENTERING_WORLD" }) do
	L.Register(ev, e)
end
ev:SetScript("OnEvent", L.Safe("events", function(_, event, name)
	if event == "ADDON_LOADED" then
		if name ~= ADDON then return end
		for _, f in ipairs(loadFns) do f() end
	elseif event == "PLAYER_REGEN_DISABLED" then
		inCombat = true
		for _, f in ipairs(combatSubs) do f(true) end
	elseif event == "PLAYER_REGEN_ENABLED" then
		inCombat = false
		RunDeferred()
		for _, f in ipairs(combatSubs) do f(false) end
	else
		BagsChanged()
	end
end))

--------------------------------------------------------------------- the rest
-- "Name-Realm" (UnitName's first value: on Forever the second is the surname); the last readable one while the name
-- is secret
local lastKey
function L.CharKey()
	local name = UnitName and L.Value((UnitName("player")))
	local realm = GetRealmName and L.Value((GetRealmName()))
	if type(name) == "string" and name ~= "" then
		lastKey = name .. "-" .. tostring(realm or "?")
		return lastKey
	end
	return lastKey or ("?-" .. tostring(realm or "?"))
end

-- missing keys from the defaults, nested; what is saved wins
function L.Fill(t, defaults)
	for k, v in pairs(defaults) do
		if t[k] == nil then
			if type(v) == "table" then
				t[k] = {}
				L.Fill(t[k], v)
			else
				t[k] = v
			end
		elseif type(v) == "table" and type(t[k]) == "table" then
			L.Fill(t[k], v)
		end
	end
	return t
end

function L.Printer(name, colour)
	local prefix = "|cff" .. colour .. name .. "|r: "
	return function(msg) print(prefix .. msg) end
end
