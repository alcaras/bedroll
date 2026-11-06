-- Bedroll: the Cozy Sleeping Bag's Well-Rested buff, standalone (Lib.lua holds its helpers). Was AlcSleepingBag
-- (2026-11-06: "help me minmax the buff for this and track how much i have etc and how much time i have to rest to get
-- max buff and remind (when out of combat) to use it again"; "ideally some way to see a 3m countdowner"); renamed and
-- made standalone the same day to be shared.
--
-- What the client's tables say (DB2, build 1.60.1.70790):
--   item 211527 Cozy Sleeping Bag -> spell 429961 Unroll Bag: 15 s cast, 1 h cooldown, the bag lasts 20 min
--   spell 429960 Well-Rested Tracking Aura: on you while you are on a bag (anyone's); every 60 s it casts
--   spell 429959 Well-Rested: +1% XP per stack (quest and kill XP), 3 stacks, 2 h; each stack refreshes the 2 h.
-- So 3/3 takes 3 minutes from nothing, but ONE minute in the bag while you still have 3/3 gives a fresh 2 h. The
-- cheap way to keep 3% up: refresh before it falls off (the reminder shows LEAD minutes before), 15 s + 1 min instead
-- of 15 s + 3 min. The 1 h cooldown is never the limit (the buff lasts 2 h).
--
-- The countdown: a thin line above the character while you are on a bag: the stacks above it, the time to 3/3 with a
-- fresh 2 h right of it, a notch per stack. Gone when it is full (one chat line and a chime: you can get up).
-- In the bag = the tracking aura on you; the client hides it from addons (a hidden aura), so: resting. Being on
-- the bag rests you as an inn does, sitting or standing too (the user, in game: "rested = you're on it"); next to it
-- does not. The bag cannot be unrolled in an inn or city, so a resting stretch after your unroll, or one a stack
-- lands in, is the bag's. After your unroll and until you are on it, the line says "Get on the bag".
--
-- The reminder: the bag's own button (a secure item button, click = unroll), out of combat only (a secure state driver
-- hides it in combat), when the bag is ready and the buff is missing, below 3/3 or under LEAD minutes left. Not in an
-- inn or city (the bag cannot be unrolled there), mounted, on a taxi, dead, or at the level cap.
--
-- The XP the buff gave: every XP gain while it is up, times stacks / (100 + stacks); per character, about.
--
-- /bedroll            status
-- /bedroll on | off   everything; remind on | off; lead <minutes>; test (a 15 s countdown)
local ADDON, ns = ...
local L = ns.L

local ITEM = 211527           -- Cozy Sleeping Bag
local UNROLL = 429961         -- its spell: Unroll Bag
local BUFF = 429959           -- Well-Rested
local TRACK = 429960          -- Well-Rested Tracking Aura (in a bag)
local MAX_STACKS = 3
local TICK_S = 60             -- a stack per minute in the bag
local BUFF_S = 7200           -- the buff's 2 h
local BAG_S = 1200            -- the bag's 20 min
local CAST_S = 15             -- the unroll's cast
local GRACE = 5               -- seconds a stack may come late
local GCD = 1.5               -- a cooldown this short is the global one, not the bag's
local SOUND_KIT = 8960        -- READY_CHECK: one soft chime at 3/3
local TEST_S = 15             -- /bedroll test: 3 stacks in 15 s

-- Every number that is visible on screen.
local LAYOUT = {
	strata    = "LOW",            -- panels draw over it
	-- the countdown line, above the character
	width     = 300,
	lineH     = 4,
	y         = 190,
	track     = { 0.15, 0.15, 0.15, 0.8 },
	fill      = { 0.6, 0.6, 0.6, 0.85 },
	full      = { 0.45, 0.8, 0.45, 0.9 },   -- at 3/3
	fillTex   = "Interface\\Buttons\\WHITE8X8",
	spark     = "Interface\\CastingBar\\UI-CastingBar-Spark",
	sparkW    = 14,
	sparkH    = 16,
	notch     = { 0, 0, 0, 0.9 },
	notchW    = 2,
	font      = "GameFontHighlight",        -- the time, right of the line
	labelFont = "GameFontNormal",           -- the stacks, above it
	textGap   = 6,
	labelGap  = 3,
	doneHold  = 4,                          -- seconds the full line stays
	tick      = 0.1,
	-- the reminder button, above the line
	button    = 36,
	buttonY   = 240,
	buttonFont = "GameFontHighlightSmall",  -- stacks and time left under it
	buttonGap = 2,
	icon      = 133662,                     -- the bag's icon (Item.csv)
}
ns.LAYOUT = LAYOUT

local P = L.Printer("Bedroll", "c8a2ff")
local db, cdb

L.OnLoad(function()
	if type(BedrollDB) ~= "table" then BedrollDB = {} end
	db = L.Fill(BedrollDB, { enabled = true, remind = true, lead = 10, trackSeen = false, chars = {} })
	db._schema = 1
	ns.db = db
end)

--------------------------------------------------------------------- reading the game
local buff = { stacks = 0, expires = 0 }   -- expires in GetTime(); stacks 0 = none
local lastTick                              -- GetTime() of the buff's last (re)application
local trackOn = false                       -- the tracking aura read on you
local unrolledAt                            -- GetTime() of your own unroll

local function Aura(id)
	local get = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
	if not get then return nil end
	local ok, a = pcall(get, id)   -- guard: can throw on this client
	if ok and type(a) == "table" then return a end
end

-- out of combat only: in combat the fields are secret (and nobody rests there)
local function Read()
	if L.InCombat() then return end
	local a = Aura(BUFF)
	local exp = a and L.Num(a.expirationTime)
	if exp and exp > 0 then
		local n = L.Num(a.applications)
		buff.stacks = math.max(1, math.min(MAX_STACKS, n or 1))   -- one stack may read 0
		buff.expires = exp
		lastTick = exp - (L.Num(a.duration) or BUFF_S)       -- every stack refreshes the 2 h
	elseif not a then
		buff.stacks, buff.expires = 0, 0
	end
	trackOn = Aura(TRACK) ~= nil
	if trackOn and db and not db.trackSeen then db.trackSeen = true end
end

local function Stacks(now)
	if buff.stacks > 0 and buff.expires > now then return buff.stacks end
	return 0
end

local function Left(now) return math.max(0, buff.expires - now) end

-- On the bag = resting (the user, in game 2026-11-06: "being on the bag gives you rested"; standing next to it does
-- not). An inn or a city rests you too, but the bag cannot be unrolled there: a resting stretch is the bag's when it
-- began after your own unroll (within the bag's 20 min), you were resting at your unroll, or a stack landed in it.
-- Getting up ends the resting at once (PLAYER_UPDATE_RESTING), so the line goes when you do.
local restingSince   -- GetTime() the resting began; nil = not resting
local bagRest        -- this resting stretch is a bag's

local function IsRestingNow()
	local ok, r = pcall(IsResting)   -- guard: legacy global
	return ok and L.Value(r) == true
end

local function ReadRest(now)
	if IsRestingNow() then
		if not restingSince then
			restingSince = now
			bagRest = (unrolledAt ~= nil and now - unrolledAt < BAG_S)
				or (lastTick ~= nil and now - lastTick <= TICK_S + GRACE)   -- a /reload on the bag
		end
	else
		restingSince, bagRest = nil, false
	end
end

local function InBag(now)
	if trackOn then return true end
	if db and db.trackSeen then return false end   -- the client shows the aura: its absence is the answer
	return restingSince ~= nil and bagRest == true
end

-- after your own unroll, until you are on the bag (or WAIT_S passes): the line says so
local WAIT_S = 90
local function Waiting(now)
	return unrolledAt ~= nil and now - unrolledAt <= WAIT_S and not InBag(now)
end

local function Fresh(now) return Stacks(now) > 0 and Left(now) >= BUFF_S - TICK_S - GRACE end

-- stacks still to come for 3/3 with a fresh 2 h
local function Needed(now)
	local need = MAX_STACKS - Stacks(now)
	if need < 1 and not Fresh(now) then need = 1 end
	return math.max(0, need)
end

local function MaxLevel()
	local lv, cap = L.Read(UnitLevel, "player"), L.Read(GetMaxPlayerLevel)
	return type(lv) == "number" and type(cap) == "number" and lv >= cap
end

local function CooldownLeft(now)
	local get = C_Container and C_Container.GetItemCooldown
	if not get then return 0 end
	local ok, start, dur = pcall(get, ITEM)   -- guard: can throw on this client
	start, dur = ok and L.Num(start), ok and L.Num(dur)
	if not (start and dur) or start == 0 or dur <= GCD then return 0 end
	return math.max(0, start + dur - now)
end

local function HaveBag() return L.Count(ITEM) > 0 end

local function Clock(s)
	s = math.max(0, math.floor(s + 0.5))
	if s >= 3600 then return ("%d:%02d:%02d"):format(math.floor(s / 3600), math.floor(s / 60) % 60, s % 60) end
	return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end
ns.Clock = Clock

local function Short(s)
	s = math.max(0, math.floor(s + 0.5))
	if s >= 3600 then return ("%dh%02d"):format(math.floor(s / 3600), math.floor(s / 60) % 60) end
	return ("%dm"):format(math.ceil(s / 60))
end

--------------------------------------------------------------------- the countdown line
local line = CreateFrame("Frame", "BedrollLine", UIParent)
line:SetSize(LAYOUT.width, LAYOUT.lineH)
line:SetPoint("CENTER", UIParent, "CENTER", 0, LAYOUT.y)
line:SetFrameStrata(LAYOUT.strata)
line:Hide()

local bg = line:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(unpack(LAYOUT.track))

local bar = CreateFrame("StatusBar", nil, line)
bar:SetAllPoints()
bar:SetStatusBarTexture(LAYOUT.fillTex)
bar:SetStatusBarColor(unpack(LAYOUT.fill))
bar:SetMinMaxValues(0, 1)
bar:SetValue(0)

local spark = bar:CreateTexture(nil, "OVERLAY")
spark:SetTexture(LAYOUT.spark)
spark:SetBlendMode("ADD")
spark:SetSize(LAYOUT.sparkW, LAYOUT.sparkH)

local notches = {}
for i = 1, MAX_STACKS - 1 do
	local n = bar:CreateTexture(nil, "OVERLAY")
	n:SetColorTexture(unpack(LAYOUT.notch))
	n:SetSize(LAYOUT.notchW, LAYOUT.lineH)
	n:Hide()
	notches[i] = n
end

local timeText = bar:CreateFontString(nil, "OVERLAY", LAYOUT.font)
timeText:SetPoint("LEFT", line, "RIGHT", LAYOUT.textGap, 0)
timeText:SetJustifyH("LEFT")

local label = bar:CreateFontString(nil, "OVERLAY", LAYOUT.labelFont)
label:SetPoint("BOTTOM", line, "TOP", 0, LAYOUT.labelGap)

-- one stay in a bag: { start, done, doneAt, test }
local stay

-- draw: share of the way, stacks now, seconds to 3/3, stacks the whole stay takes (for the notches)
local function Draw(share, stacks, left, ticks, done)
	share = math.max(0, math.min(1, share))
	bar:SetValue(share)
	bar:SetStatusBarColor(unpack(done and LAYOUT.full or LAYOUT.fill))
	spark:ClearAllPoints()
	spark:SetPoint("CENTER", line, "LEFT", LAYOUT.width * share, 0)
	spark:SetShown(not done)
	for i, n in ipairs(notches) do
		local show = ticks and ticks > 1 and i < ticks
		if show then
			n:ClearAllPoints()
			n:SetPoint("CENTER", line, "LEFT", LAYOUT.width * i / ticks, 0)
		end
		n:SetShown(show and true or false)
	end
	if done then
		label:SetText(("Well-Rested %d/%d: %d%% XP for %s"):format(stacks, MAX_STACKS, stacks, Clock(BUFF_S)))
		timeText:SetText("")
	else
		label:SetText(("Well-Rested %d/%d"):format(stacks, MAX_STACKS))
		timeText:SetText(Clock(left))
	end
end

-- the next stack: a minute after the last one, else a minute after you got on it
local function NextTick(now)
	local n
	if lastTick and lastTick >= stay.start - TICK_S then n = lastTick + TICK_S end
	if not n or n < now - GRACE then
		n = stay.start + TICK_S
		while n < now - GRACE do n = n + TICK_S end
	end
	return math.max(n, now)
end

-- unrolled, not on it yet
local function DrawWaiting()
	bar:SetValue(0)
	bar:SetStatusBarColor(unpack(LAYOUT.fill))
	spark:Hide()
	for _, n in ipairs(notches) do n:Hide() end
	label:SetText("Get on the bag: a stack a minute")
	timeText:SetText("")
end

local function Finish(now)
	stay.done, stay.doneAt = true, now
	if PlaySound then pcall(PlaySound, SOUND_KIT) end   -- guard: a sound kit a patch removed
	P(("Well-Rested %d/%d: %d%% XP for %s. You can get up."):format(MAX_STACKS, MAX_STACKS, MAX_STACKS, Clock(BUFF_S)))
end

local Update   -- below

local function Tick()
	local now = GetTime()
	if not stay then line:Hide() return end
	if stay.test then
		local e = now - stay.start
		local stacks = math.min(MAX_STACKS, math.floor(e / (TEST_S / MAX_STACKS)))
		if e >= TEST_S + LAYOUT.doneHold then stay = nil line:Hide() return end
		Draw(e / TEST_S, stacks, TEST_S - e, MAX_STACKS, e >= TEST_S)
		return
	end
	if stay.waiting then
		if L.InCombat() or not Waiting(now) then
			Update()
			if stay and stay.waiting then stay = nil line:Hide() end
			return
		end
		DrawWaiting()
		return
	end
	if L.InCombat() or not InBag(now) then stay = nil line:Hide() Update() return end
	if stay.done then
		if now - stay.doneAt >= LAYOUT.doneHold then line:Hide() end
		Draw(1, Stacks(now), 0, nil, true)
		return
	end
	local need = Needed(now)
	if need == 0 then Finish(now) Draw(1, Stacks(now), 0, nil, true) return end
	local endAt = NextTick(now) + (need - 1) * TICK_S
	stay.endAt = endAt
	local total = endAt - stay.start
	local ticks = math.max(1, math.floor(total / TICK_S + 0.5))
	Draw(total > 0 and (now - stay.start) / total or 0, Stacks(now), endAt - now, ticks, false)
end
L.Every(line, LAYOUT.tick, Tick, "countdown")

--------------------------------------------------------------------- the reminder button
local holder = CreateFrame("Frame", "BedrollHolder", UIParent)
holder:SetSize(LAYOUT.button, LAYOUT.button)
holder:SetPoint("CENTER", UIParent, "CENTER", 0, LAYOUT.buttonY)
holder:SetFrameStrata(LAYOUT.strata)
if RegisterStateDriver then
	pcall(RegisterStateDriver, holder, "visibility", "[combat] hide; show")   -- guard: as AlcConsumables' cards
end

local button = CreateFrame("Button", "BedrollButton", holder, "SecureActionButtonTemplate")
button:SetAllPoints()
button:RegisterForClicks("LeftButtonUp")
button:SetAttribute("useOnKeyDown", false)   -- up-clicks only (docs: the template acts on the CVar's phase)
button:SetAttribute("type", "item")
button:SetAttribute("item", "item:" .. ITEM)
button:Hide()

local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetAllPoints()
icon:SetTexture(LAYOUT.icon)
icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

local buttonText = button:CreateFontString(nil, "OVERLAY", LAYOUT.buttonFont)
buttonText:SetPoint("TOP", button, "BOTTOM", 0, -LAYOUT.buttonGap)

local function Status(now)
	local s = Stacks(now)
	if s == 0 then return "no Well-Rested" end
	return ("Well-Rested %d/%d (%d%%), %s left"):format(s, MAX_STACKS, s, Clock(Left(now)))
end

-- what a stay takes from here: the unroll and the minutes to 3/3 with a fresh 2 h
local function Plan(now)
	local need = math.max(1, Needed(now))
	return ("%d s unroll + %d min rest"):format(CAST_S, need)
end

local function XPLine()
	local b = cdb and cdb.bonus or 0
	return ("about %d XP from the buff this session, %d in all"):format(math.floor(ns.sessionBonus + 0.5),
		math.floor(b + 0.5))
end

L.Script(button, "OnEnter", function(self)
	if not GameTooltip then return end
	local now = GetTime()
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine("Cozy Sleeping Bag", 1, 0.82, 0)
	GameTooltip:AddLine(Status(now), 1, 1, 1)
	GameTooltip:AddLine("Click: unroll. To 3/3 with a fresh 2 h: " .. Plan(now) .. ".", 0.8, 0.8, 0.8, true)
	GameTooltip:AddLine(XPLine() .. ".", 0.7, 0.7, 0.7, true)
	GameTooltip:Show()
end, "tooltip")
L.Script(button, "OnLeave", function() if GameTooltip then GameTooltip:Hide() end end, "tooltip")

-- why the reminder shows (nil = it does not)
local function Want(now)
	if not (db and db.enabled and db.remind) then return nil end
	if MaxLevel() or not HaveBag() or CooldownLeft(now) > 0 or InBag(now) then return nil end
	local function yes(fn) local ok, v = pcall(fn, "player") return ok and L.Value(v) == true end   -- guard: legacy globals
	if (IsResting and yes(IsResting)) or (IsMounted and yes(IsMounted)) or (UnitOnTaxi and yes(UnitOnTaxi))
		or (UnitIsDeadOrGhost and yes(UnitIsDeadOrGhost)) then
		return nil
	end
	local s = Stacks(now)
	if s == 0 then return "none" end
	if s < MAX_STACKS or Left(now) <= (db.lead or 10) * 60 then
		return ("%d/%d %s"):format(s, MAX_STACKS, Short(Left(now)))
	end
	return nil
end

-- the next moment the answer may change by the clock alone: the bag's cooldown, the lead, the buff's end
local gen = 0
local function Schedule(now)
	gen = gen + 1
	local mine, soon = gen, nil
	local function at(t) if t and t > now and (not soon or t < soon) then soon = t end end
	at(now + CooldownLeft(now))
	if Stacks(now) > 0 then
		at(buff.expires - (db and db.lead or 10) * 60)
		at(buff.expires)
	end
	-- the "get on the bag" prompt runs out by the clock
	if unrolledAt then at(unrolledAt + WAIT_S) end
	if soon then
		L.After(soon - now + 0.1, function() if mine == gen then Update() end end, "schedule")
	end
end

local shownWant
local function ShowButton(want)
	if want then buttonText:SetText(want) end
	local show = want ~= nil
	if show == shownWant then return end
	shownWant = show
	L.Defer("button", function() button:SetShown(show) end)
end

--------------------------------------------------------------------- putting it together
Update = function()
	if not db then return end
	local now = GetTime()
	if L.InCombat() then return end   -- the state driver hides the button; the line hides itself
	ReadRest(now)
	local on = db.enabled and not MaxLevel()
	if on and InBag(now) then
		-- the stay starts when you got on it: the first stack comes a minute later
		if not stay or stay.test or stay.waiting then stay = { start = restingSince or now } end
		if not stay.done or now - stay.doneAt < LAYOUT.doneHold then line:Show() end
	elseif on and Waiting(now) then
		if not stay or not stay.waiting then stay = { start = now, waiting = true } end
		line:Show()
	elseif stay and not stay.test then
		if stay.waiting and unrolledAt and now - unrolledAt > WAIT_S then
			P("you're not on the bag yet: stand or sit on it (next to it gives nothing).")
		end
		stay = nil
		line:Hide()
	end
	ShowButton(Want(now))
	Schedule(now)
end
ns.Update = Update

-- a stack landing while you rest: this resting stretch is a bag's (a group mate's bag: no unroll of yours)
local function OnAura()
	if L.InCombat() then return end
	local before = lastTick
	Read()
	if lastTick and lastTick ~= before and restingSince then bagRest = true end
	Update()
end

--------------------------------------------------------------------- XP from the buff
ns.sessionBonus = 0
local lastXP, lastMax, leaving
local function OnXP()
	if leaving then return end   -- logout readings are empty
	local xp, max = L.Read(UnitXP, "player"), L.Read(UnitXPMax, "player")
	if type(xp) ~= "number" or type(max) ~= "number" then return end
	if lastXP then
		local gain = xp - lastXP
		if gain < 0 and lastMax then gain = (lastMax - lastXP) + xp end   -- a level between the readings
		local s = Stacks(GetTime())
		if gain > 0 and s > 0 and cdb then
			local b = gain * s / (100 + s)
			ns.sessionBonus = ns.sessionBonus + b
			cdb.bonus = (cdb.bonus or 0) + b
		end
	end
	lastXP, lastMax = xp, max
end

--------------------------------------------------------------------- events
local ev = CreateFrame("Frame")
L.Register(ev, "UNIT_AURA", "player")
L.Register(ev, "UNIT_SPELLCAST_SUCCEEDED", "player")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD", "PLAYER_XP_UPDATE",
	"PLAYER_LEVEL_UP", "BAG_UPDATE_COOLDOWN", "PLAYER_UPDATE_RESTING", "PLAYER_MOUNT_DISPLAY_CHANGED",
	"PLAYER_CONTROL_GAINED", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
	L.Register(ev, e)
end
L.Script(ev, "OnEvent", function(_, event, unit, _, spellID)
	if event == "UNIT_AURA" then
		OnAura()
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if L.Num(spellID) == UNROLL then
			unrolledAt = GetTime()
			if restingSince then bagRest = true end   -- resting already: you're on it (no inn lets you unroll)
			Read()
			Update()
		end
	elseif event == "PLAYER_LOGIN" then
		cdb = db.chars[L.CharKey()] or { bonus = 0 }
		db.chars[L.CharKey()] = cdb
		Read()
		OnXP()
		Update()
	elseif event == "PLAYER_ENTERING_WORLD" then
		leaving = false
		lastXP = nil       -- a fresh reading after the loading screen
		unrolledAt = nil   -- zoning despawns the bag
		restingSince, bagRest = nil, false   -- read again (a /reload on the bag: a stack in the last minute)
		Read()
		OnXP()
		Update()
	elseif event == "PLAYER_LEAVING_WORLD" then
		leaving = true
	elseif event == "PLAYER_XP_UPDATE" or event == "PLAYER_LEVEL_UP" then
		OnXP()
		if event == "PLAYER_LEVEL_UP" then Update() end
	else
		Update()
	end
end, "events")

L.OnCombatChanged(function(inCombat)
	if inCombat then
		if stay and not stay.test then stay = nil line:Hide() end
	else
		Read()
		Update()
	end
end, "combat")
L.OnBagsChanged(function() Update() end)

--------------------------------------------------------------------- slash
local function Say()
	local now = GetTime()
	local cd = CooldownLeft(now)
	local bag = not HaveBag() and "no bag in your bags" or cd > 0 and ("bag on cooldown, " .. Clock(cd)) or "bag ready"
	P(("%s; %s."):format(Status(now), bag))
	if stay and not stay.test and not stay.done and stay.endAt then
		P(("in a bag: 3/3 with a fresh 2 h in %s."):format(Clock(stay.endAt - now)))
	else
		P(("to 3/3 with a fresh 2 h: %s."):format(Plan(now)))
	end
	P(XPLine() .. (". reminder %s, %d min before it ends%s."):format(db.remind and "on" or "off", db.lead,
		db.enabled and "" or " (all off)"))
end

local commands = {
	on = function() db.enabled = true Update() P("on.") end,
	off = function() db.enabled = false stay = nil line:Hide() Update() P("off.") end,
	remind = function(arg)
		if arg == "on" or arg == "off" then db.remind = (arg == "on") end
		Update()
		P("reminder " .. (db.remind and "on." or "off."))
	end,
	lead = function(arg)
		local n = tonumber(arg)
		if n and n >= 0 and n <= 120 then db.lead = math.floor(n) end
		Update()
		P(("the reminder shows %d min before Well-Rested ends."):format(db.lead))
	end,
	test = function()
		stay = { start = GetTime(), test = true }
		line:Show()
		P(("test: a %d s countdown above the character."):format(TEST_S))
	end,
	[""] = Say,
	status = Say,
}
SLASH_BEDROLL1 = "/bedroll"
SlashCmdList.BEDROLL = L.Safe("slash", function(msg)
	local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	local fn = commands[cmd]
	if fn then fn(arg) else P("/bedroll [status] | on | off | remind on|off | lead <min> | test") end
end)
