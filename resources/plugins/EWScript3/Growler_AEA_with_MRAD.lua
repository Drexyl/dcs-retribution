-- Script by _Timberwolf_
-- Contact me on the forums under that name, or on Discord @timberwolf8831
-- https://forum.dcs.world/topic/385186-ea-18g-style-electronic-warfare-script-v2/

-------------------------------------------------------------------------------------------------------------------------------------------------------------
-- DCS Retribution changes (EW Script 3.0 plugin)
--
--  * Options are read at runtime from the global AEA_options table (filled by ewscript3_config.lua from the
--    Retribution plugin settings). Missing options fall back to the upstream values, so the script still
--    works stand-alone in a hand-made mission.
--  * Debug logging to dcs.log ("[EWS3]" prefix) behind DEBUG_LOG / DEBUG_VERBOSE, optional in-game debug
--    messages to the jammer's coalition behind DEBUG_MESSAGES. The per-player MESSAGES=DEBUG menu still works.
--  * Public API for mission generators:
--      AEA_RegisterJammer(unitName, {loadout="2xALQ99", ai=true|false, gated=true|false, maxTargets=n})
--      AEA_SetArmed(unitName, true|false)   -- mission window (JOIN->SPLIT, RACETRACK START->END)
--      AEA_RegisterSelfProtect(unitName, {gen=1|2|3, pod="AN/ALQ-184 ECM", ai=true|false})
--    The "[EA-18G]" unit name prefix is kept as a fallback (players, and AI when ai_enabled).
--  * AI controller: AI jammers transmit only while armed (mission window) AND while the protected package is
--    lit up (an enemy radar is tracking a friendly aircraft near the jammer) or under missile threat, then go
--    quiet after ai_hold_sec. Power is managed against the JMRS heat model.
--  * Fixes: only ENEMY emitters/aircraft/missiles are affected (upstream also hit friendlies); missile
--    disruption only applies to radar-guided (active / semi-active) missiles, not ARMs, IR missiles or bombs;
--    band bias works (S-BAND/X-BAND vs S/X mismatch); removed undefined variables (target, isShip,
--    burnThroughNm) and the duplicated band resist block; a SAM is only released from WEAPON HOLD once its
--    latest suppression has expired; emitter scans are cached and shared between jammers; the RWR only lists
--    enemy radars that are actually emitting.
--  * ALQ-249 (NGJ-MB): more simultaneous targets (up to 9), single ALQ-249 loadouts, and mid-band (S) ECCM /
--    hold / burn-through bonuses; NGJ-only loadouts are slightly weaker against X-band fire-control radars.
--  * Self-protection jammers (defensive ECM pods / internal suites): track breaks on radars tracking the
--    carrier and a missile defeat roll for radar missiles aimed at the carrier. See SELF-PROTECTION JAMMERS.
-------------------------------------------------------------------------------------------------------------------------------------------------------------

-- CONFIG (Lua-only)
local DEBUG_TO_ALL = false   -- if true, debug prints to ALL players (use carefully)

local NAME_PREFIX = "[EA-18G]"

local HEARTBEAT_SEC = 15
local NORM_STATUS_REFRESH_SEC = 6

local EA_TICK_SEC = 2.0
local SCAN_EVERY_N_TICKS = 2         -- scan every 2 EA ticks (i.e., every 4 seconds)
local MAX_EMITTERS_CONSIDERED = 180  -- hard cap to prevent huge missions from spiking

local MISSILE_DISRUPT_DELAY_MAX = 5.0

local AIR_EFFECT_RANGE_NM = 30
local AIR_EVENT_COOLDOWN = 20
local AIR_MAX_EVENTS_PER_TICK = 2

local PREFIX_SCAN_SEC = 10           -- fallback scan for "[EA-18G]" named units
local AI_STATUS_LOG_SEC = 30         -- periodic AI status line in dcs.log (DEBUG_LOG)
local AI_HEAT_LOW = 70               -- AI drops to LOW power at/above this heat
local AI_HEAT_HIGH_MAX = 70          -- AI only uses HIGH power below this heat

-- Runtime options (see ewscript3_config.lua / plugin.json)
AEA_options = AEA_options or {}

local OPTION_DEFAULTS = {
  players_enabled = true,
  ai_enabled = true,
  ai_window_gating = true,
  ai_jam_search = false,
  ai_protect_radius_nm = 25,
  ai_hold_sec = 30,
  range_multiplier = 0.7,           -- scales JAMMING ranges only (not missile disrupt)
  missile_disrupt_chance = 0.50,
  missile_disrupt_nm = 10,
  air_effects = true,
  spj_enabled = true,               -- self-protection jammers (WeaponType.JAMMER pods / internal ECM)
  spj_players = true,
  spj_missile_chance = 0.25,        -- scaled by pod generation (x0.6 / x1.0 / x1.4)
  spj_missile_nm = 5,
  DEBUG_LOG = false,
  DEBUG_MESSAGES = false,
  DEBUG_VERBOSE = false,
}

local function opt(key)
  local v = AEA_options[key]
  if v == nil then return OPTION_DEFAULTS[key] end
  return v
end

local _rand = nil
do
  if type(math) == "table" and type(math.random) == "function" then
    _rand = function() return math.random() end
  else
    local seed = tonumber(timer.getTime() or 1) or 1
    _rand = function()
      seed = (1103515245 * seed + 12345) % 2147483648
      return seed / 2147483648
    end
  end
end

local function randf(a, b) return a + _rand() * (b - a) end

-- UTIL
local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function startsWith(s, prefix)
  return s ~= nil and string.sub(s, 1, #prefix) == prefix
end

local function nmToM(nm) return nm * 1852 end
local function mToNm(m) return m / 1852 end

local function dist2D(a, b)
  local dx = a.x - b.x
  local dz = a.z - b.z
  return math.sqrt(dx*dx + dz*dz)
end

local function bearingDeg(fromPt, toPt)
  local dx = toPt.x - fromPt.x
  local dz = toPt.z - fromPt.z
  local brg = math.deg(math.atan2(dx, dz))
  if brg < 0 then brg = brg + 360 end
  return brg
end

local function getHeadingDeg(unit)
  local ok, pos = pcall(function() return unit:getPosition() end)
  if (not ok) or (not pos) or (not pos.x) then return 0 end
  local fwd = pos.x
  local hdg = math.deg(math.atan2(fwd.x, fwd.z))
  if hdg < 0 then hdg = hdg + 360 end
  return hdg
end

local function enemySide(side)
  if side == coalition.side.BLUE then return coalition.side.RED end
  if side == coalition.side.RED then return coalition.side.BLUE end
  return nil
end

local function safeName(obj)
  local ok, n = pcall(function() return obj:getName() end)
  if ok and n then return tostring(n) end
  return "?"
end

local function safeTypeName(obj)
  local ok, n = pcall(function() return obj:getTypeName() end)
  if ok and n then return tostring(n) end
  return "?"
end

local function safeGroupName(u)
  local ok, n = pcall(function()
    local g = u:getGroup()
    return g and g:getName()
  end)
  if ok and n then return tostring(n) end
  return "?"
end

local function unitExists(u)
  if not u then return false end
  local ok, ex = pcall(function() return u:isExist() end)
  return ok and ex
end

local function isPlayerUnit(u)
  local ok, p = pcall(function() return u:getPlayerName() end)
  return ok and p ~= nil
end

-- LOGGING
local function fmt(text, ...)
  if select("#", ...) == 0 then return tostring(text) end
  local ok, s = pcall(string.format, text, ...)
  if ok then return s end
  return tostring(text)
end

local function aeaLog(text, ...)
  if not opt("DEBUG_LOG") then return end
  env.info("[EWS3] " .. fmt(text, ...))
end

local function aeaLogV(text, ...)
  if not (opt("DEBUG_LOG") and opt("DEBUG_VERBOSE")) then return end
  env.info("[EWS3] " .. fmt(text, ...))
end

local function aeaWarn(text, ...)
  env.warning("[EWS3] " .. fmt(text, ...))
end

local AEA = {
  jammers = {},           -- [unitName] = state
  trackedMissiles = {},   -- [tostring(weapon)] = {weapon=, side=, target=, typeName=, launcher=}
  missileRolls = {},      -- [key] = true once rolled
  suppressed = {},        -- [targetKey] = {["until"] =sec, lastSet=sec}
  airCooldown = {},       -- [airUnitName] = nextAllowedTime
  emitterCache = {},      -- [side] = {t=sec, jam={}, threat={}}
  airCache = {},          -- [side] = {t=sec, units={}}  radar-equipped AI aircraft
  selfProtect = {},       -- [unitName] = self-protection jammer state (see SELF-PROTECTION JAMMERS)
}

local DEFAULTS = {
  xmit = false,
  overhtProtection = false,  -- (unused) legacy; overheat handled automatically

  rwr = false,           -- ALQ-218 message toggle, independent of XMIT

  power = "NORM",       -- LOW / NORM / HIGH
  band  = "BOTH",       -- BOTH / S-BAND / X-BAND
  maxTargets = 6,       -- 2 / 4 / 6
  dir   = "AUTO",       -- AUTO / FORWARD / LEFT / RIGHT / AFT

  messages = "NORM",    -- LOW / NORM / DEBUG
  loadout  = "2xALQ99", -- default
}

-- Messages are only shown to human pilots (outTextForUnit on an AI unit is pointless).
local function msgToUnit(unit, text, seconds)
  if not unit then return end
  pcall(function()
    if unit:isExist() and unit:getPlayerName() ~= nil then
      trigger.action.outTextForUnit(unit:getID(), text, seconds or 5)
    end
  end)
end

-- true if any debug output is wanted for this jammer (used to skip building debug strings)
local function isDebug(st)
  return (st and st.messages == "DEBUG") or opt("DEBUG_LOG") or opt("DEBUG_MESSAGES") or DEBUG_TO_ALL
end

local function isDebugV(st)
  return (st and st.messages == "DEBUG") or opt("DEBUG_VERBOSE") or DEBUG_TO_ALL
end

local function unitKey(u)
  if not u then return "nil" end
  local ok, id = pcall(function() return u:getID() end)
  if ok and id then return tostring(id) end
  local ok2, name = pcall(function() return u:getName() end)
  if ok2 and name then return tostring(name) end
  return tostring(u)
end

local function dbgOut(st, unit, text, seconds, toCoalition)
  local line = "[AEA] DBG " .. text
  if st and st.messages == "DEBUG" then msgToUnit(unit, line, seconds or 3) end
  if DEBUG_TO_ALL then trigger.action.outText(line, seconds or 3) end
  if toCoalition and st and st.coalition then
    pcall(function()
      trigger.action.outTextForCoalition(st.coalition, "[EWS3] " .. tostring(st.unitName) .. ": " .. text, seconds or 5)
    end)
  end
end

-- Event-level debug: dcs.log (DEBUG_LOG), coalition messages (DEBUG_MESSAGES), player DEBUG menu.
local function dbg(st, unit, text, seconds)
  aeaLog("%s: %s", st and st.unitName or "?", text)
  dbgOut(st, unit, text, seconds, opt("DEBUG_MESSAGES"))
end

-- Verbose, throttled debug: dcs.log (DEBUG_LOG + DEBUG_VERBOSE), player DEBUG menu,
-- coalition messages only when DEBUG_MESSAGES and DEBUG_VERBOSE are both on.
local function dbgThrottle(st, unit, key, minSec, text)
  st._dbgT = st._dbgT or {}
  local now = timer.getTime()
  local last = st._dbgT[key] or -1e9
  if (now - last) >= (minSec or 1.0) then
    st._dbgT[key] = now
    aeaLogV("%s: %s", st.unitName or "?", text)
    dbgOut(st, unit, text, 3, opt("DEBUG_MESSAGES") and opt("DEBUG_VERBOSE"))
  end
end


local function statusLine(st)
  if not st.xmit then return "[AEA] OFF" end

  local dirStatus = st.dir
  if st.dir == "AUTO" then
    local a = st._autoDir or "FORWARD"
    local short = (a == "FORWARD" and "FWD") or (a == "LEFT" and "L") or (a == "RIGHT" and "R") or (a == "AFT" and "AFT") or "FWD"
    dirStatus = "AUTO " .. short
  end

  local used = st.usedTargets or 0
  local maxT = st.maxTargets or 0

  local hot = ""
  if (st.heat or 0) >= 70 then hot = " | JMRS HOT" end

  local mrad = ""
  if (st.usedTargets or 0) > 0 then mrad = " | MRAD" end

  return string.format("[AEA] XMIT | PWR %s | BAND %s | TGT %d/%d | DIR %s%s%s",
    st.power, st.band, used, maxT, dirStatus, hot, mrad)
end

local function emitConfirm(st, unit, text)
  if (st.messages == "NORM" or st.messages == "DEBUG") and st.xmit then return end
  msgToUnit(unit, text, 4)
end

local function pushStatus(st, unit)
  if (st.messages == "NORM" or st.messages == "DEBUG") and st.xmit then
    msgToUnit(unit, statusLine(st), 5)
  end
end

local function heartbeat(st, unit)
  if st.messages ~= "LOW" then return end
  if st.xmit then
    local dirStatus = st.dir
    if st.dir == "AUTO" then
      local a = st._autoDir or "FORWARD"
      local short = (a == "FORWARD" and "FWD") or (a == "LEFT" and "L") or (a == "RIGHT" and "R") or (a == "AFT" and "AFT") or "FWD"
      dirStatus = "AUTO " .. short
    end
    msgToUnit(unit, string.format("[AEA] STATUS - XMIT | PWR %s | BAND %s | TGT %d | DIR %s",
      st.power, st.band, st.maxTargets, dirStatus), 4)
  else
    msgToUnit(unit, "[AEA] STATUS - OFF", 3)
  end
end

-- eff: jamming range factor, heat: (informational) heat factor
-- Retribution additions:
--   maxT    : default / AI number of simultaneously jammed groups
--   menuMax : largest MAX TARGETS value offered in the player menu
--   ngj     : number of ALQ-249 Mid Band (NGJ-MB) pods, alq99 : number of ALQ-99 pods
-- The NGJ-MB is a GaN AESA with several independently steered beams and much higher ERP than the ALQ-99,
-- so NGJ loadouts jam more groups at once and get mid-band bonuses (see ngjMods).
local LOADOUTS = {
  ["1xALQ99"]          = {eff=0.85, heat=1.10, maxT=2, menuMax=6, ngj=0, alq99=1},
  ["2xALQ99"]          = {eff=1.00, heat=1.00, maxT=4, menuMax=6, ngj=0, alq99=2},
  ["3xALQ99"]          = {eff=1.10, heat=1.15, maxT=6, menuMax=6, ngj=0, alq99=3},
  ["1xALQ249"]         = {eff=1.00, heat=0.95, maxT=4, menuMax=6, ngj=1, alq99=0},
  ["1xALQ249_1xALQ99"] = {eff=1.10, heat=1.00, maxT=4, menuMax=6, ngj=1, alq99=1},
  ["1xALQ249_2xALQ99"] = {eff=1.15, heat=1.05, maxT=6, menuMax=9, ngj=1, alq99=2},
  ["2xALQ249"]         = {eff=1.15, heat=0.90, maxT=6, menuMax=9, ngj=2, alq99=0},
  ["2xALQ249_1xALQ99"] = {eff=1.20, heat=1.00, maxT=9, menuMax=9, ngj=2, alq99=1},
}

-- NGJ-MB modifiers against an emitter in `band` ("S" = search / acquisition, "X" = fire control).
-- The ALQ-249 Mid Band covers the S/C band: there it resists ECCM better, holds longer and burns through
-- later. X-band fire-control radars are covered by the ALQ-99 (high band) pods, so an NGJ-only loadout
-- is slightly weaker against them.
local function ngjMods(loadout, band)
  local lo = LOADOUTS[loadout]
  local ngj = (lo and lo.ngj) or 0
  if ngj <= 0 then return {resistAdd=0.0, holdMul=1.0, burnMul=1.0} end
  if band == "S" then
    return {resistAdd=-math.min(0.08, 0.04 * ngj), holdMul=1.10, burnMul=0.80}
  end
  if (lo.alq99 or 0) == 0 then
    return {resistAdd=0.05, holdMul=1.0, burnMul=1.0}
  end
  return {resistAdd=0.0, holdMul=1.0, burnMul=1.0}
end

local function powerMods(power)
  if power == "LOW" then
    return {holdMul=0.75, intervalMul=1.25, resistAdd=0.10, rangeMul=0.90}
  elseif power == "HIGH" then
    return {holdMul=1.25, intervalMul=0.80, resistAdd=-0.10, rangeMul=1.10}
  end
  return {holdMul=1.00, intervalMul=1.00, resistAdd=0.00, rangeMul=1.00}
end

local function targetCountMods(maxTargets)
  if maxTargets == 2 then return {holdMul=1.20, resistAdd=-0.05}
  elseif maxTargets == 6 then return {holdMul=0.92, resistAdd=0.04}
  elseif maxTargets == 9 then return {holdMul=0.82, resistAdd=0.08}
  elseif maxTargets == 12 then return {holdMul=0.72, resistAdd=0.12}
  end
  return {holdMul=1.00, resistAdd=0.00}
end

local function altitudeMul(altM)
  if altM < 1500 then return 0.75
  elseif altM < 6000 then return 1.00
  else return 1.20
  end
end

local TIER = {
  [0] = {holdMin=6, holdMax=10, interval=5, resist=0.10},
  [1] = {holdMin=4, holdMax=7,  interval=4, resist=0.20},
  [2] = {holdMin=2, holdMax=5,  interval=3, resist=0.35},
  [3] = {holdMin=1, holdMax=3,  interval=2, resist=0.50},
}

local function getEccmTierForUnit(u)
  local tn = ""
  pcall(function() tn = u:getTypeName() or "" end)
  tn = string.lower(tn)

  if string.find(tn, "s-300") or string.find(tn, "sa-10") or string.find(tn, "sa10") or
     string.find(tn, "sa-20") or string.find(tn, "sa20") or
     string.find(tn, "sa-21") or string.find(tn, "sa21") or
     string.find(tn, "patriot") or string.find(tn, "s-400") then
    return 3
  end
  if string.find(tn, "buk") or string.find(tn, "sa-11") or string.find(tn, "sa11") or
     string.find(tn, "sa-17") or string.find(tn, "sa17") or string.find(tn, "sa-15") or string.find(tn, "tor") then
    return 2
  end
  if string.find(tn, "kub") or string.find(tn, "sa-6") or string.find(tn, "sa6") or
     string.find(tn, "osa") or string.find(tn, "sa-8") or string.find(tn, "sa8") or
     string.find(tn, "hawk") then
    return 1
  end
  return 1
end

local function burnThroughNmForTier(tier)
  if tier == 3 then return 18 end
  if tier == 2 then return 22 end
  if tier == 1 then return 26 end
  return (30) * opt("range_multiplier")
end

local function maxJamRangeNm(jammerAltM, loadEff, power)
  local pm = powerMods(power)
  local base = 70 -- tune
  return (base * altitudeMul(jammerAltM) * loadEff * pm.rangeMul) * opt("range_multiplier")
end

local function shipMaxJamRangeNm(jammerAltM, hasNgj, power)
  local pm = powerMods(power)
  local base = hasNgj and 60 or 40 -- NM cap before modifiers
  return (base * clamp(0.85 + (altitudeMul(jammerAltM) - 1.0) * 0.5, 0.80, 1.15) * pm.rangeMul) * opt("range_multiplier")
end

local function dirBiasMultiplier(st, relBearingDeg)
  local d = st.dir
  if d == "AUTO" and st._autoDir and st._autoDir ~= "AUTO" then d = st._autoDir end
  if d == "AUTO" then return 1.0 end
  if d == "FORWARD" then
    return (relBearingDeg <= 60 or relBearingDeg >= 300) and 1.25 or 0.85
  elseif d == "AFT" then
    return (relBearingDeg >= 120 and relBearingDeg <= 240) and 1.25 or 0.85
  elseif d == "RIGHT" then
    return (relBearingDeg >= 30 and relBearingDeg <= 150) and 1.25 or 0.85
  elseif d == "LEFT" then
    return (relBearingDeg >= 210 and relBearingDeg <= 330) and 1.25 or 0.85
  end
  return 1.0
end

-- Selected band ("BOTH" / "S-BAND" / "X-BAND") -> "S" / "X" / nil (both)
local function selectedBandCode(st)
  local b = st.band
  if b == "S-BAND" or b == "S" then return "S" end
  if b == "X-BAND" or b == "X" then return "X" end
  return nil
end

local function bandBiasMultiplier(st, band)
  local sel = selectedBandCode(st)
  if not sel then return 1.0 end
  if sel == band then return 1.25 end
  return 0.80
end

local function safeHasAttribute(u, attr)
  local ok, res = pcall(function() return u:hasAttribute(attr) end)
  return ok and res
end

local function isShipUnit(u)
  local isShip = false
  pcall(function()
    local g = u:getGroup()
    if g and g:getCategory() == Group.Category.SHIP then isShip = true end
  end)
  return isShip
end

-- Emitters that the JMRS can suppress (upstream definition: SAM radars and ships)
local function unitIsEmitter(u)
  if not unitExists(u) then return false end
  if isShipUnit(u) then return true end
  if safeHasAttribute(u, "SAM SR") or safeHasAttribute(u, "SAM TR") or safeHasAttribute(u, "SAM STR") then
    return true
  end
  return false
end

-- Emitters the ALQ-218 can hear (adds early warning radars)
local function unitIsThreatEmitter(u)
  if unitIsEmitter(u) then return true end
  return safeHasAttribute(u, "EWR")
end

local function classifyBand(u)
  if safeHasAttribute(u, "SAM SR") then return "S" end
  if safeHasAttribute(u, "SAM TR") or safeHasAttribute(u, "SAM STR") then return "X" end
  return "X"
end

-- Scan the emitters belonging to `side` (the jammer's enemy). Cached for 1s and shared by all jammers.
--   .jam    = units the JMRS can suppress
--   .threat = units the ALQ-218 can detect (jam list + EWRs)
local function scanEmitters(side)
  if not side then return {jam={}, threat={}} end
  local now = timer.getTime()
  local cache = AEA.emitterCache[side]
  if cache and (now - cache.t) < 1.0 then return cache end

  local jam, threat = {}, {}

  local function scanCat(cat)
    local ok, groups = pcall(function() return coalition.getGroups(side, cat) end)
    if not ok or not groups then return end
    for _,g in ipairs(groups) do
      local okU, units = pcall(function() return g:getUnits() end)
      if okU and units then
        for _,u in ipairs(units) do
          if u and unitIsThreatEmitter(u) then
            threat[#threat+1] = u
            if #jam < MAX_EMITTERS_CONSIDERED and unitIsEmitter(u) then
              jam[#jam+1] = u
            end
          end
        end
      end
      if #threat >= MAX_EMITTERS_CONSIDERED * 2 then return end
    end
  end

  scanCat(Group.Category.GROUND)
  scanCat(Group.Category.SHIP)

  cache = {t=now, jam=jam, threat=threat}
  AEA.emitterCache[side] = cache
  return cache
end

-- Is the unit's radar emitting? (nil if the API can't tell)
local function radarState(u)
  local ok, active, tracked = pcall(function() return u:getRadar() end)
  if not ok then return nil, nil end
  return active, tracked
end


-- ALQ-218 / RWR (situational awareness only)
local RWR_TICK_SEC = 6.0        -- evaluation interval
local RWR_MAX_SEARCH_UNITS = 300
local RWR_MAX_CONTACTS = 10  -- C1..C10

local RWR_CLOSE_FRAC = 0.70     -- within this: no ~ and 1nm resolution
local RWR_ID_FRAC    = 1.00     -- within ID range: show SA-XX instead of UKN

local RWR_THREAT_DB = {
  { key="SA-21", match={"S-400","SA-21","40N6","92H6","91N6","96L6","S_400","SA21"}, detectNm=160, idNm=105 },
  { key="SA-20", match={"S-300PMU","S-300PMU2","S-300PMU1","SA-20","64H6E2","92H6E","30N6E","54K6","54K6E2","5P85","S_300PMU","PMU2","PMU1"}, detectNm=150, idNm=95 },
  { key="SA-12", match={"S-300V","S-300VM","S-300V4","9S32","9S32ME","9S19","9S19M2","9S15","9S15M2","9A82","9A83","9A82ME","9A83ME","S_300V","S300V","Antey"}, detectNm=145, idNm=90 },
  { key="SA-10", match={"S-300PS","S-300PT","S-300","SA-10","64H6E","30N6","5P85","S_300","S300"}, detectNm=140, idNm=85 },
  { key="SA-5",  match={"S-200","SA-5"}, detectNm=170, idNm=110 },
  { key="PATRIOT", match={"Patriot","MIM-104"}, detectNm=140, idNm=90 },

  -- Retribution: "9A310M"/"BUK" matched the SA-11 launcher (9A310M1) as SA-17
  { key="SA-17", match={"Buk-M2","SA-17","BUK-M2","Buk M1-2","9A310M1-2"}, detectNm=120, idNm=75 },
  { key="SA-11", match={"Buk","SA-11","BUK","9A310"}, detectNm=110, idNm=70 },
  { key="SA-2", match={"HQ-2","V759","SA-2","S-75"}, detectNm=120, idNm=75 },
  { key="SA-3", match={"V-601","V-601P","5P73","SA-3","S-125"}, detectNm=95, idNm=60 },
  { key="SA-6",  match={"Kub","SA-6"}, detectNm=90,  idNm=55 },
  { key="HAWK",  match={"Hawk"}, detectNm=80, idNm=50 },

  { key="SA-22", match={"Pantsir","Pantsir-S1","SA-22","96K6"}, detectNm=65, idNm=40 },
  { key="SA-15", match={"Tor","SA-15"}, detectNm=60, idNm=35 },
  { key="SA-8",  match={"Osa","SA-8"}, detectNm=55, idNm=30 },
  { key="SA-19", match={"Tunguska","SA-19"}, detectNm=55, idNm=30 },
  { key="SA-13", match={"Strela-10","SA-13"}, detectNm=45, idNm=25 },
  { key="SA-9",  match={"Strela-1","SA-9"}, detectNm=40, idNm=22 },

  { key="SHIP", match={"ship","Ship"}, detectNm=140, idNm=90 },
}

local function rwrRoundTo(x, step)
  if step <= 0 then return x end
  return math.floor((x / step) + 0.5) * step
end


local function bearing_geo_deg(fromPoint, toPoint)
  local lat1, lon1 = coord.LOtoLL(fromPoint)
  local lat2, lon2 = coord.LOtoLL(toPoint)

  local phi1 = math.rad(lat1)
  local phi2 = math.rad(lat2)
  local dLon = math.rad(lon2 - lon1)

  local y = math.sin(dLon) * math.cos(phi2)
  local x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(dLon)

  local brg = math.deg(math.atan2(y, x))
  brg = (brg + 360) % 360
  return brg
end


local function rwrClassify(unit)
  if not unit then return "UKN", 70, 40 end

  local typeName = ""
  local cat = nil
  pcall(function()
    local d = unit:getDesc()
    typeName = d and d.typeName or ""
    cat = d and d.category or nil
  end)

  if (cat == "SHIP") or (cat == 3) then
    return "SHIP", 140, 90
  end

  for _,t in ipairs(RWR_THREAT_DB) do
    for _,pat in ipairs(t.match) do
      if typeName ~= "" and string.find(typeName, pat, 1, true) then
        return t.key, t.detectNm, t.idNm
      end
    end
  end

  local ok, d = pcall(function() return unit:getDesc() end)
  if ok and d and d.attributes then
    local a = d.attributes
    if a["EWR"] then return "EWR", 160, 110 end
    if a["SAM SR"] then return "SAM", 110, 65 end
    if a["SAM TR"] or a["SAM STR"] then return "SAM", 90, 55 end
  end

  return "UKN", 70, 40
end

-- ALQ-218 detection range (NM) of an emitter, scaled by the jammer altitude
local function rwrDetectNm(ownAltM, u)
  local name, det, id = rwrClassify(u)
  local altFt = (ownAltM or 0) * 3.28084
  local altMult = 1.0 + math.min(0.25, math.max(0.0, (altFt - 5000) / 60000))
  return det * altMult, id * altMult, name
end

local function rwrLineForUnit(st, ownPt, u)
  local okP, tgtPt = pcall(function() return u:getPoint() end)
  if not okP or not tgtPt then return nil, nil end

  local rngNm = mToNm(dist2D(ownPt, tgtPt))
  local det, id, name = rwrDetectNm(ownPt.y, u)

  if rngNm > det then return nil, nil end

  local brg = bearing_geo_deg(ownPt, tgtPt)

  local closeNm = id * RWR_CLOSE_FRAC
  local idNm = id * RWR_ID_FRAC

  local show = "UKN"
  local approxB = true
  local approxR = true

  if rngNm <= idNm then
    show = name
  end
  if rngNm <= closeNm then
    approxB = false
    approxR = false
  end

  local bOut = brg
  local rOut = rngNm

  if approxB then bOut = rwrRoundTo(brg, 10) end
  if approxR then
    rOut = (rngNm > 60) and rwrRoundTo(rngNm, 10) or rwrRoundTo(rngNm, 5)
  else
    rOut = math.floor(rngNm + 0.5)
  end

  local bStr = string.format("%d°", math.floor(bOut + 0.5))
  local rStr = string.format("%dnm", math.floor(rOut + 0.5))
  if approxB then bStr = "~" .. bStr end
  if approxR then rStr = "~" .. rStr end

  return string.format("[AEA] RWR: %s %s %s", show, bStr, rStr), rngNm
end


local function runRWR(now, unit, st)
  if not st.rwr then return end
  if not unitExists(unit) then return end
  local interval = RWR_TICK_SEC
  if st.messages == "LOW" then interval = HEARTBEAT_SEC end
  if now < (st.nextRwrTick or 0) then return end
  st.nextRwrTick = now + interval

  local ownPt = unit:getPoint()
  local emitters = scanEmitters(enemySide(st.coalition)).threat

  local byGroup = {}

  local searched = 0
  for _,e in ipairs(emitters) do
    if unitExists(e) then
      searched = searched + 1
      if searched > RWR_MAX_SEARCH_UNITS then break end

      local activeOk, isAct = pcall(function() return e:isActive() end)
      local radarOn = radarState(e)
      -- an RWR only hears radars that are emitting (radarOn == nil -> API unavailable, assume emitting)
      if (activeOk and (not isAct)) or radarOn == false then
      else
        local gName = safeGroupName(e)

        local line, rng = rwrLineForUnit(st, ownPt, e)
        if line and rng then
          local cur = byGroup[gName]
          if (not cur) or (rng < cur.rng) then
            byGroup[gName] = { line=line, rng=rng }
          end
        end
      end
    end
  end

  local contacts = {}
  for _,v in pairs(byGroup) do
    table.insert(contacts, v)
  end

  if #contacts == 0 then
    st.rwrLastMsg = ""
    return
  end

  table.sort(contacts, function(a,b) return a.rng < b.rng end)

  local n = math.min(RWR_MAX_CONTACTS or 10, #contacts)

  -- Keep the JMRS status line synced with RWR picture
  if st.messages == "LOW" then
    heartbeat(st, unit)
    st.lastHeartbeat = now
  else
    pushStatus(st, unit)
    st.lastStatusPush = now
  end

  for i=1,n do
    local msg = contacts[i].line
    msg = string.gsub(msg, "%[AEA%] RWR:", string.format("[AEA] RWR C%d:", i))
    msgToUnit(unit, msg, 5)
  end

  st.rwrLastMsg = contacts[1].line
end


-- ROE SAFE SETTERS
local function safeSetWeaponHold(unit)
  local ok = pcall(function()
    local grp = unit:getGroup()
    local cat = grp and grp:getCategory()
    local ctrl = unit:getController()
    if not ctrl then return end

    if cat == Group.Category.SHIP then
      if AI and AI.Option and AI.Option.Naval and AI.Option.Naval.id and AI.Option.Naval.val then
        ctrl:setOption(AI.Option.Naval.id.ROE, AI.Option.Naval.val.ROE.WEAPON_HOLD)
      else
        ctrl:setOption(AI.Option.Ground.id.ROE, AI.Option.Ground.val.ROE.WEAPON_HOLD)
      end
    else
      ctrl:setOption(AI.Option.Ground.id.ROE, AI.Option.Ground.val.ROE.WEAPON_HOLD)
    end
  end)
  return ok
end

local function safeSetOpenFire(unit)
  local ok = pcall(function()
    local grp = unit:getGroup()
    local cat = grp and grp:getCategory()
    local ctrl = unit:getController()
    if not ctrl then return end

    if cat == Group.Category.SHIP then
      if AI and AI.Option and AI.Option.Naval and AI.Option.Naval.id and AI.Option.Naval.val then
        ctrl:setOption(AI.Option.Naval.id.ROE, AI.Option.Naval.val.ROE.OPEN_FIRE)
      else
        ctrl:setOption(AI.Option.Ground.id.ROE, AI.Option.Ground.val.ROE.OPEN_FIRE)
      end
    else
      ctrl:setOption(AI.Option.Ground.id.ROE, AI.Option.Ground.val.ROE.OPEN_FIRE)
    end
  end)
  return ok
end

local function targetKey(u)
  return tostring(u)
end

local function shouldPulseTarget(now, u)
  local k = targetKey(u)
  local st = AEA.suppressed[k]
  if not st then return true end
  if now < (st.lastSet or 0) + 1.0 then return false end
  return true
end

local function markPulsed(now, u, holdFor)
  local k = targetKey(u)
  local prev = AEA.suppressed[k]
  local untilT = now + holdFor
  -- never shorten an existing (longer) suppression from another jammer
  if prev and prev["until"] and prev["until"] > untilT then untilT = prev["until"] end
  AEA.suppressed[k] = {["until"] = untilT, lastSet = now}
  return untilT
end

-- Back to OPEN FIRE at untilT, unless a later suppression (from any jammer) is still running.
local function scheduleRelease(target, untilT)
  timer.scheduleFunction(function(param, t)
    local u = param
    local k = targetKey(u)
    local s = AEA.suppressed[k]
    if s and s["until"] and s["until"] > t + 0.05 then return nil end
    if unitExists(u) then
      safeSetOpenFire(u)
    end
    AEA.suppressed[k] = nil
    return nil
  end, target, untilT)
end

local function scoreEmitter(jammerUnit, st, emitter)
  local jp = jammerUnit:getPoint()
  local ep = emitter:getPoint()
  local rangeNm = mToNm(dist2D(jp, ep))

  local tier = getEccmTierForUnit(emitter)
  local band = classifyBand(emitter)
  local burn = burnThroughNmForTier(tier) * ngjMods(st.loadout, band).burnMul
  local loadEff = (LOADOUTS[st.loadout] or {eff=1.0}).eff
  local maxR = maxJamRangeNm(jp.y or 0, loadEff, st.power)
  if isShipUnit(emitter) then
    local hasNgj = (st.loadout and string.find(st.loadout, "ALQ249")) ~= nil
    local shipCap = shipMaxJamRangeNm(jp.y or 0, hasNgj, st.power)
    if shipCap < maxR then maxR = shipCap end
  end


  if rangeNm > maxR then return nil end

  local rangeScore = 1.0
  if rangeNm <= burn then
    rangeScore = 0.25
  else
    local mid = burn + (maxR - burn) * 0.55
    local d = math.abs(rangeNm - mid)
    rangeScore = clamp(1.0 - (d / (maxR - burn)), 0.30, 1.0)
  end

  local bandMul = bandBiasMultiplier(st, band)

  local hdg = getHeadingDeg(jammerUnit)
  local brg = bearingDeg(jp, ep)
  local rel = (brg - hdg) % 360
  local dirMul = dirBiasMultiplier(st, rel)

  local tierMul = (tier == 3 and 0.90) or (tier == 2 and 0.95) or 1.0

  local score = rangeScore * bandMul * dirMul * tierMul

  return {unit=emitter, score=score, rangeNm=rangeNm, tier=tier, burn=burn, maxR=maxR}
end

local function pulseSuppression(now, jammerUnit, st, target, rangeNm)
  if not shouldPulseTarget(now, target) then return end

  st.eccmBlock = st.eccmBlock or {}
  local tier = getEccmTierForUnit(target)
  local tBand = classifyBand(target)
  local selBand = selectedBandCode(st)
  local isShip = isShipUnit(target)
  local tkey = unitKey(target)
  local blkUntil = st.eccmBlock[tkey] or 0
  if blkUntil and now < blkUntil then
    if isDebugV(st) then
      dbgThrottle(st, jammerUnit, "eccmblk:"..tkey, 2.0, string.format("ECCM REACQ %.1fs (band=%s)", blkUntil - now, tostring(tBand)))
    end
    return
  end
  local base = TIER[tier]
  if not base then return end

  local pm = powerMods(st.power)
  local tm = targetCountMods(st.maxTargets)
  local nm = ngjMods(st.loadout, tBand)

  local holdMin = base.holdMin * pm.holdMul * tm.holdMul * nm.holdMul
  local holdMax = base.holdMax * pm.holdMul * tm.holdMul * nm.holdMul

  local burn = burnThroughNmForTier(tier) * nm.burnMul
  local loadEff = (LOADOUTS[st.loadout] or {eff=1.0}).eff
  local maxR = maxJamRangeNm((jammerUnit:getPoint().y or 0), loadEff, st.power)

  local t01 = 0
  if maxR > burn then
    t01 = clamp((rangeNm - burn) / (maxR - burn), 0, 1)
  end

  local bandMatch = (selBand ~= nil) and (tBand == selBand)
  local bandMismatch = (selBand ~= nil) and (tBand ~= selBand)

  local resist = clamp(base.resist + pm.resistAdd + tm.resistAdd + nm.resistAdd + (1 - t01) * 0.25, 0.05, 0.95)
  if bandMatch then
    resist = clamp(resist - 0.10, 0, 0.95)
  elseif bandMismatch then
    resist = clamp(resist + 0.06, 0, 0.95)
  end
  resist = clamp(resist + 0.08, 0, 0.95)

  local roll = _rand()
  if roll < resist then
    local blockMin, blockMax = 4, 6
    if tier == 2 then blockMin, blockMax = 6, 9 end
    if tier >= 3 then blockMin, blockMax = 7, 10 end
    if isShip then blockMin, blockMax = blockMin + 1, blockMax + 2 end

    if bandMatch then
      blockMin = math.max(1, blockMin - 1)
      blockMax = math.max(2, blockMax - 1)
    elseif bandMismatch then
      blockMin = blockMin + 1
      blockMax = blockMax + 2
    end

    if burn and burn > 0 and rangeNm <= (burn * 0.6) then
      blockMin = math.max(1, math.floor(blockMin * 0.7))
      blockMax = math.max(blockMin + 1, math.floor(blockMax * 0.7))
    end

    local block = randf(blockMin, blockMax)

    if _rand() < 0.08 then
      block = randf(15, 18)
    end
    st.eccmBlock[tkey] = now + block
    if isDebugV(st) then
      dbgThrottle(st, jammerUnit, "eccmres:"..tkey, 2.0,
        string.format("ECCM RESIST %s (%s) roll=%.2f<thr=%.2f -> REACQ %.1fs (tier=%d sel=%s tgt=%s match=%s)",
          safeTypeName(target), safeGroupName(target), roll, resist, block, tier, tostring(st.band), tostring(tBand),
          (selBand == nil and "N/A" or tostring(bandMatch))))
    end
    return
  end

  local hold = randf(holdMin, holdMax)
  local okHold = safeSetWeaponHold(target)
  if not okHold then return end
  if isDebugV(st) then
    dbgThrottle(st, jammerUnit, "sup:"..tkey, 2.0, string.format("SUPPRESS OK %s (%s) tier=%d hold=%.1fs rng=%.1fNM",
      safeTypeName(target), safeGroupName(target), tier, hold, rangeNm or -1))
  end
  st.stats = st.stats or {}
  st.stats.suppress = (st.stats.suppress or 0) + 1

  scheduleRelease(target, markPulsed(now, target, hold))
end

local function runJamming(now, jammerUnit, st)
  if not st.xmit then return end
  if not unitExists(jammerUnit) then return end
  if isDebugV(st) then dbgThrottle(st, jammerUnit, "ea_tick", 2.0, "EA tick running") end

  st._tickCount = (st._tickCount or 0) + 1
  if (st._tickCount % SCAN_EVERY_N_TICKS) ~= 0 then return end

  local emitters = scanEmitters(enemySide(st.coalition)).jam
  if isDebugV(st) then dbgThrottle(st, jammerUnit, "scan", 4.0, "SCAN emitters=" .. tostring(#emitters)) end

  local groupMap = {} -- [groupName] = {units={}, bestScore, bestUnit, minRangeNm}
  for _,e in ipairs(emitters) do
    if unitExists(e) then
      local s = scoreEmitter(jammerUnit, st, e)
      if s then
        local gname = safeGroupName(e)
        local gm = groupMap[gname]
        if not gm then
          gm = {groupName=gname, units={}, bestScore=s.score, bestUnit=s.unit, minRangeNm=s.rangeNm}
          groupMap[gname] = gm
        end
        gm.units[#gm.units+1] = s.unit
        if s.score > (gm.bestScore or -1e9) then
          gm.bestScore = s.score
          gm.bestUnit = s.unit
        end
        if s.rangeNm < (gm.minRangeNm or 1e9) then
          gm.minRangeNm = s.rangeNm
        end
      end
    end
  end

  local scored = {}
  for _,gm in pairs(groupMap) do
    scored[#scored+1] = {groupName=gm.groupName, units=gm.units, unit=gm.bestUnit, score=gm.bestScore, rangeNm=gm.minRangeNm}
  end

  table.sort(scored, function(a,b) return a.score > b.score end)

  if st.dir == "AUTO" and scored[1] and unitExists(scored[1].unit) then
    local jp = jammerUnit:getPoint()
    local ep = scored[1].unit:getPoint()
    local hdg = getHeadingDeg(jammerUnit)
    local brg = bearingDeg(jp, ep)
    local rel = (brg - hdg) % 360
    if rel <= 45 or rel >= 315 then st._autoDir = "FORWARD"
    elseif rel > 45 and rel <= 135 then st._autoDir = "LEFT"
    elseif rel > 135 and rel <= 225 then st._autoDir = "AFT"
    else st._autoDir = "RIGHT" end
    if isDebugV(st) then dbgThrottle(st, jammerUnit, "autodir", 6.0, "AUTO DIR -> " .. tostring(st._autoDir)) end
  end

  local n = math.min(st.maxTargets or 6, #scored)
  st.usedTargets = n
  if isDebugV(st) then dbgThrottle(st, jammerUnit, "pick", 4.0, "PICK groups=" .. tostring(n) .. " (max=" .. tostring(st.maxTargets) .. ")") end

  for i=1,n do
    local t = scored[i]
    if isDebugV(st) then
      dbgThrottle(st, jammerUnit, "grp_"..t.groupName, 6.0,
        string.format("GROUP #%d %s rng=%.1fNM score=%.2f units=%d",
          i, t.groupName or "?", t.rangeNm or -1, t.score or -1, t.units and #t.units or 0))
    end
    if t.units then
      for _,u in ipairs(t.units) do
        if unitExists(u) then
          pulseSuppression(now, jammerUnit, st, u, t.rangeNm)
        end
      end
    else
      pulseSuppression(now, jammerUnit, st, t.unit, t.rangeNm)
    end
  end

  if isDebug(st) and (now - (st._dbgLast or 0)) >= 10 then
    st._dbgLast = now
    local names = {}
    for i=1,n do names[#names+1] = scored[i].groupName end
    aeaLog("%s: JAM %d/%d groups in range [%s] pwr=%s heat=%.0f%%", st.unitName, n, #scored,
      table.concat(names, ", "), tostring(st.power), st.heat or 0)
    if st.messages == "DEBUG" then
      msgToUnit(jammerUnit, string.format("[AEA] DBG SCAN %d / JAM %d", #scored, n), 3)
    end
  end
end


-- MISSILES

local WEAPON_CAT_MISSILE = (Weapon and Weapon.Category and Weapon.Category.MISSILE) or 1
local GT = (Weapon and Weapon.GuidanceType) or {}
local GT_RADAR_ACTIVE = GT.RADAR_ACTIVE or 3
local GT_RADAR_SEMI_ACTIVE = GT.RADAR_SEMI_ACTIVE or 4

-- Only active / semi-active radar homing missiles can be defeated by the jammer.
-- Anti-radiation (RADAR_PASSIVE), IR, TV, laser guided weapons and bombs are ignored.
local function isRadarGuided(weapon)
  local ok, d = pcall(function() return weapon:getDesc() end)
  if not ok or not d then return false end
  if d.category ~= WEAPON_CAT_MISSILE then return false end
  return d.guidance == GT_RADAR_ACTIVE or d.guidance == GT_RADAR_SEMI_ACTIVE
end

local function missileKey(w) return tostring(w) end

local function anyJammers()
  return next(AEA.jammers) ~= nil or next(AEA.selfProtect) ~= nil
end

-- Friendly (to the jammer) aircraft within the protected radius of the jammer.
local function isProtectedAircraft(st, jp, obj)
  if not obj then return false end
  local ok, res = pcall(function()
    if not obj:isExist() then return false end
    if obj:getCoalition() ~= st.coalition then return false end
    if Object.getCategory(obj) ~= Object.Category.UNIT then return false end
    local d = obj:getDesc()
    if not d or (d.category ~= Unit.Category.AIRPLANE and d.category ~= Unit.Category.HELICOPTER) then return false end
    return dist2D(jp, obj:getPoint()) <= nmToM(opt("ai_protect_radius_nm"))
  end)
  return ok and res
end

local function missileLaunchWarningAll(m)
  -- ALQ-218 style "launch" message (no defeat), enemy launches only
  for uname, st in pairs(AEA.jammers) do
    if st.rwr and st.coalition and st.coalition ~= m.side then
      local u = Unit.getByName(uname)
      if unitExists(u) then
        local jp = u:getPoint()
        local okW, wp = pcall(function() return m.weapon:getPoint() end)
        if okW and wp then
          local brg = bearingDeg(jp, wp)
          local rng = mToNm(dist2D(jp, wp))
          msgToUnit(u, string.format("[AEA] MSL LAUNCH - %03d° - %.0f NM", math.floor(brg + 0.5), rng), 4)
        end
      end
    end
  end
end

local function scheduleMissileKill(weapon, now)
  local delay = randf(0.0, MISSILE_DISRUPT_DELAY_MAX)
  timer.scheduleFunction(function(param, t)
    local w = param
    if unitExists(w) then
      pcall(function() w:destroy() end)
    end
    return nil
  end, weapon, now + delay)
end

local AEA_EventHandler = {}
function AEA_EventHandler:onEvent(e)
  if not e or e.id ~= world.event.S_EVENT_SHOT then return end
  if not anyJammers() then return end
  if not unitExists(e.weapon) then return end
  if not isRadarGuided(e.weapon) then return end

  local side = nil
  pcall(function() side = e.initiator:getCoalition() end)
  if not side then pcall(function() side = e.weapon:getCoalition() end) end
  local target = nil
  pcall(function() target = e.weapon:getTarget() end)

  local key = missileKey(e.weapon)
  local m = {
    weapon = e.weapon,
    side = side,
    target = target,
    typeName = safeTypeName(e.weapon),
    launcher = e.initiator and safeTypeName(e.initiator) or "?",
    targetName = target and safeName(target) or "unknown",
  }
  AEA.trackedMissiles[key] = m

  aeaLogV("SHOT %s by %s (side %s) at %s", m.typeName, m.launcher, tostring(side), m.targetName)

  missileLaunchWarningAll(m)
end
world.addEventHandler(AEA_EventHandler)

local function runMissileDisruption(now, jammerUnit, st)
  if not st.xmit then return end

  local jp = jammerUnit:getPoint()
  local rangeM = nmToM(opt("missile_disrupt_nm"))
  local chance = opt("missile_disrupt_chance")
  for key, m in pairs(AEA.trackedMissiles) do
    local w = m.weapon
    if unitExists(w) then
      if m.side ~= st.coalition and not AEA.missileRolls[key] then
        local wp = w:getPoint()
        local nearJammer = dist2D(jp, wp) <= rangeM
        local nearTarget = false
        if m.target and isProtectedAircraft(st, jp, m.target) then
          local okT, tp = pcall(function() return m.target:getPoint() end)
          nearTarget = okT and tp and dist2D(tp, wp) <= rangeM
        end
        if nearJammer or nearTarget then
          AEA.missileRolls[key] = true
          local roll = _rand()
          local rngNm = mToNm(dist2D(jp, wp))
          if isDebug(st) then
            dbg(st, jammerUnit, string.format("MSL ROLL %s -> %s rng=%.1fNM roll=%.2f thr=%.2f", m.typeName, m.targetName, rngNm, roll, chance), 3)
          end
          if roll <= chance then
            if isDebug(st) then dbg(st, jammerUnit, "MSL DISRUPT scheduled (0-5s delay)", 3) end
            scheduleMissileKill(w, now)
          else
            if isDebug(st) then dbg(st, jammerUnit, "MSL DISRUPT failed (pilot must defend)", 3) end
          end
        end
      end
    else
      AEA.trackedMissiles[key] = nil
      AEA.missileRolls[key] = nil
    end
  end
end

local function cleanupMissiles()
  for key, m in pairs(AEA.trackedMissiles) do
    if not unitExists(m.weapon) then
      AEA.trackedMissiles[key] = nil
      AEA.missileRolls[key] = nil
    end
  end
end

local function safeSetAirHold(airUnit)
  local ok = pcall(function()
    local ctrl = airUnit:getController()
    if not ctrl then return end
    ctrl:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
  end)
  return ok
end

local function safeSetAirOpen(airUnit)
  local ok = pcall(function()
    local ctrl = airUnit:getController()
    if not ctrl then return end
    ctrl:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.OPEN_FIRE)
  end)
  return ok
end

local function hasRadar(u)
  local ok, res = pcall(function() return u:hasSensors(Unit.SensorType.RADAR) end)
  if ok then return res end
  return true
end

local function runAircraftEffects(now, jammerUnit, st)
  if not st.xmit then return end
  if not opt("air_effects") then return end
  local side = enemySide(st.coalition)
  if not side then return end
  local jp = jammerUnit:getPoint()

  local events = 0

  local ok, groups = pcall(function() return coalition.getGroups(side, Group.Category.AIRPLANE) end)
  if ok and groups then
    for _,g in ipairs(groups) do
      local okU, units = pcall(function() return g:getUnits() end)
      if okU and units then
        for _,u in ipairs(units) do
          if unitExists(u) and (not isPlayerUnit(u)) and hasRadar(u) then
            local up = u:getPoint()
            local rngNm = mToNm(dist2D(jp, up))
            if rngNm <= AIR_EFFECT_RANGE_NM then
              local uname = u:getName()
              local nextOk = AEA.airCooldown[uname] or 0
              if now >= nextOk then
                local base = 0.06
                if st.power == "LOW" then base = 0.04 end
                if st.power == "HIGH" then base = 0.08 end

                if _rand() < base then
                  if safeSetAirHold(u) then
                    local hold = randf(2.0, 4.0)
                    if isDebug(st) then dbg(st, jammerUnit, string.format("AIR EFFECT on %s (%s) hold %.1fs rng=%.1fNM", uname, safeTypeName(u), hold, rngNm), 3) end
                    timer.scheduleFunction(function(param, t)
                      local au = param
                      if unitExists(au) then safeSetAirOpen(au) end
                      return nil
                    end, u, now + hold)

                    AEA.airCooldown[uname] = now + AIR_EVENT_COOLDOWN
                    events = events + 1
                    if events >= AIR_MAX_EVENTS_PER_TICK then return end
                  end
                end
              end
            end
          end
        end
      end
      if events >= AIR_MAX_EVENTS_PER_TICK then return end
    end
  end
end

local function updateHeat(now, jammerUnit, st)

  st.heat = st.heat or 0
  st.lockoutUntil = st.lockoutUntil or 0
  st.eccmBlock = st.eccmBlock or {}
  st.throttleWarned = st.throttleWarned or false

  local HEAT_RATES = {
    ["1xALQ99"]          = {LOW=0.10,  NORM=0.20,  HIGH=0.30},
    ["2xALQ99"]          = {LOW=0.02,  NORM=0.06,  HIGH=0.10},
    ["3xALQ99"]          = {LOW=0.00,  NORM=0.045, HIGH=0.075},
    -- Retribution: single ALQ-249 fits, interpolated between the upstream entries
    ["1xALQ249"]         = {LOW=0.05,  NORM=0.12,  HIGH=0.18},
    ["1xALQ249_1xALQ99"] = {LOW=0.01,  NORM=0.05,  HIGH=0.08},
    ["1xALQ249_2xALQ99"] = {LOW=0.00,  NORM=0.045, HIGH=0.07},
    ["2xALQ249"]         = {LOW=-0.005, NORM=0.0375, HIGH=0.05},
    ["2xALQ249_1xALQ99"] = {LOW=0.005, NORM=0.05,  HIGH=0.07},
  }

  local r = HEAT_RATES[st.loadout] or HEAT_RATES["2xALQ99"]
  local p = st.power or "NORM"
  local rate = 0.0

  if st.xmit then
    rate = (r[p] or r.NORM or 0.06)

    if (st.maxTargets or 0) >= 9 then
      rate = rate * 1.20
    elseif st.maxTargets == 6 then
      rate = rate * 1.10
    elseif st.maxTargets == 2 then
      rate = rate * 0.95
    end
  else
    rate = -0.30
  end

  -- upstream tuning: applied once per second (updateAll) with EA_TICK_SEC as the factor
  st.heat = clamp(st.heat + rate * EA_TICK_SEC, 0, 100)

  if isDebugV(st) then
    dbgThrottle(st, jammerUnit, "heat", 10.0,
      string.format("HEAT %.1f%% (xmit=%s pwr=%s load=%s rate=%.3f/s)",
        st.heat, tostring(st.xmit), tostring(st.power), tostring(st.loadout), rate))
  end

  if st.xmit and st.heat >= 90 then
    if st.power ~= "LOW" then
      st.power = "LOW"
      if isDebug(st) then dbg(st, jammerUnit, string.format("JMRS THROTTLE -> LOW (heat %.0f%%)", st.heat)) end
    end
    if not st.throttleWarned then
      msgToUnit(jammerUnit, "[AEA] JMRS THROTTLE", 3)
      st.throttleWarned = true
    end
  elseif st.heat < 85 then
    st.throttleWarned = false
  end

  if st.xmit and st.heat >= 100 then
    st.xmit = false
    st.lockoutUntil = now + 120
    msgToUnit(jammerUnit, "[AEA] JMRS OVERHT", 4)
    msgToUnit(jammerUnit, "[AEA] JMRS COOLING 120s", 4)
    emitConfirm(st, jammerUnit, "[AEA] OFF")
    if isDebug(st) then dbg(st, jammerUnit, "JMRS OVERHEAT - XMIT OFF, cooling 120s") end
  end

  if st.lockoutUntil and now < st.lockoutUntil then
    st.xmit = false
  end
end

local function maxTargetsForLoadout(loadout)
  local lo = LOADOUTS[loadout]
  return (lo and lo.maxT) or 4
end

local function ensureJammerState(name)
  if AEA.jammers[name] then return AEA.jammers[name] end

  local st = {}
  for k,v in pairs(DEFAULTS) do st[k] = v end
  st.unitName = name
  st.lastHeartbeat = 0
  st.lastStatusPush = 0
  st.nextEaTick = 0
  st.nextRwrTick = 0
  st.rwrLastMsg = ""
  st.lockoutUntil = 0
  st.menusBuilt = false
  st.overheatWarned = false
  st.heat = 0
  st.eccmBlock = {}
  st._tickCount = 0
  st.ai = false
  st.gated = false
  st.armed = false
  st.aiState = nil
  st.lastThreatTime = nil
  st.stats = {suppress=0}
  AEA.jammers[name] = st
  return st
end

local function buildMenusForUnit(unit, st)
  local gid = unit:getGroup():getID()
  local root = missionCommands.addSubMenuForGroup(gid, "AEA MENU")

  -- JMRS
  local jmrs = missionCommands.addSubMenuForGroup(gid, "JMRS", root)
  missionCommands.addCommandForGroup(gid, "XMIT", jmrs, function()
    local now = timer.getTime()
    if st.lockoutUntil and now < st.lockoutUntil then
      msgToUnit(unit, string.format("[AEA] JMRS COOLING %.0fs", st.lockoutUntil - now), 4)
      return
    end
    st.xmit = true
    emitConfirm(st, unit, "[AEA] XMIT")
    pushStatus(st, unit)
    if isDebug(st) then dbg(st, unit, "XMIT command received", 3) end
  end)
  missionCommands.addCommandForGroup(gid, "OFF", jmrs, function()
    st.xmit = false
    emitConfirm(st, unit, "[AEA] OFF")
    if isDebug(st) then dbg(st, unit, "OFF command received", 3) end
  end)


  local rwr = missionCommands.addSubMenuForGroup(gid, "TJSR/RWR", root)
  missionCommands.addCommandForGroup(gid, "ON", rwr, function()
    st.rwr = true
    emitConfirm(st, unit, "[AEA] RWR: ON")
  end)
  missionCommands.addCommandForGroup(gid, "OFF", rwr, function()
    st.rwr = false
    emitConfirm(st, unit, "[AEA] RWR: OFF")
  end)

  local pri = missionCommands.addSubMenuForGroup(gid, "PRIORITIES", root)
  missionCommands.addCommandForGroup(gid, "RESET TO DEFAULT", pri, function()
    st.power = DEFAULTS.power
    st.band = DEFAULTS.band
    st.maxTargets = DEFAULTS.maxTargets
    st.dir = DEFAULTS.dir
    emitConfirm(st, unit, "[AEA] DEFAULTS")
    pushStatus(st, unit)
  end)

  local pwr = missionCommands.addSubMenuForGroup(gid, "POWER", pri)
  for _,p in ipairs({"LOW","NORM","HIGH"}) do
    missionCommands.addCommandForGroup(gid, p, pwr, function()
      st.power = p
      emitConfirm(st, unit, "[AEA] POWER: " .. p)
      pushStatus(st, unit)
    end)
  end

  local band = missionCommands.addSubMenuForGroup(gid, "BAND", pri)
  missionCommands.addCommandForGroup(gid, "BOTH", band, function()
    st.band = "BOTH"
    emitConfirm(st, unit, "[AEA] BAND: BOTH")
    pushStatus(st, unit)
  end)
  missionCommands.addCommandForGroup(gid, "S-BAND", band, function()
    st.band = "S-BAND"
    emitConfirm(st, unit, "[AEA] BAND: S-BAND")
    pushStatus(st, unit)
  end)
  missionCommands.addCommandForGroup(gid, "X-BAND", band, function()
    st.band = "X-BAND"
    emitConfirm(st, unit, "[AEA] BAND: X-BAND")
    pushStatus(st, unit)
  end)

  local mt = missionCommands.addSubMenuForGroup(gid, "MAX TARGETS", pri)
  -- Retribution: 9 targets for NGJ (multi-beam AESA) loadouts; the choice is re-checked against the
  -- loadout selected at the time the option is picked.
  for _,n in ipairs({2, 4, 6, 9}) do
    missionCommands.addCommandForGroup(gid, tostring(n), mt, function()
      local lo = LOADOUTS[st.loadout]
      if n > ((lo and lo.menuMax) or 6) then
        msgToUnit(unit, "[AEA] MAX TARGETS 9 needs 2x ALQ-249 or 1x ALQ-249 + 2x ALQ-99", 4)
        return
      end
      st.maxTargets = n
      emitConfirm(st, unit, "[AEA] MAX TARGETS: " .. tostring(n))
      pushStatus(st, unit)
    end)
  end

  local dir = missionCommands.addSubMenuForGroup(gid, "DIRECTION BIAS", pri)
  for _,d in ipairs({"AUTO","FORWARD","LEFT","RIGHT","AFT"}) do
    missionCommands.addCommandForGroup(gid, d, dir, function()
      st.dir = d
      emitConfirm(st, unit, "[AEA] DIRECTION: " .. d)
      pushStatus(st, unit)
    end)
  end

  local scr = missionCommands.addSubMenuForGroup(gid, "SCRIPT", root)
  local msg = missionCommands.addSubMenuForGroup(gid, "MESSAGES", scr)
  for _,m in ipairs({"LOW","NORM","DEBUG"}) do
    missionCommands.addCommandForGroup(gid, m, msg, function()
      st.messages = m
      emitConfirm(st, unit, "[AEA] MESSAGES: " .. m)
      pushStatus(st, unit)
    end)
  end

  local lo = missionCommands.addSubMenuForGroup(gid, "LOADOUT", scr)
  local loadoutOptions = {
    {"1x ALQ-99", "1xALQ99"},
    {"2x ALQ-99", "2xALQ99"},
    {"3x ALQ-99", "3xALQ99"},
    {"1x ALQ-249", "1xALQ249"},
    {"1x ALQ-249, 1x ALQ-99", "1xALQ249_1xALQ99"},
    {"1x ALQ-249, 2x ALQ-99", "1xALQ249_2xALQ99"},
    {"2x ALQ-249", "2xALQ249"},
    {"2x ALQ-249, 1x ALQ-99", "2xALQ249_1xALQ99"},
  }
  for _,opt_ in ipairs(loadoutOptions) do
    missionCommands.addCommandForGroup(gid, opt_[1], lo, function()
      st.loadout = opt_[2]
      local menuMax = LOADOUTS[st.loadout].menuMax or 6
      if (st.maxTargets or 0) > menuMax then st.maxTargets = menuMax end
      emitConfirm(st, unit, "[AEA] LOADOUT: " .. opt_[1])
      pushStatus(st, unit)
    end)
  end
end


-- PUBLIC API

-- Register a jammer aircraft by unit name.
--   cfg.loadout    : one of the LOADOUTS keys (default "2xALQ99")
--   cfg.ai         : true for AI controlled jammers, false for player slots
--   cfg.gated      : AI only - if true the jammer is only armed between AEA_SetArmed(name, true/false)
--   cfg.maxTargets : AI only - max simultaneously jammed groups (default from loadout)
function AEA_RegisterJammer(unitName, cfg)
  if type(unitName) ~= "string" then return end
  cfg = cfg or {}
  local ai = cfg.ai and true or false
  if ai and not opt("ai_enabled") then
    aeaLog("%s: AI jammers disabled - not registered", unitName)
    return
  end
  if (not ai) and not opt("players_enabled") then
    aeaLog("%s: player AEA menu disabled - not registered", unitName)
    return
  end

  local st = ensureJammerState(unitName)
  st.ai = ai
  AEA.selfProtect[unitName] = nil   -- the AEA jammer covers its own aircraft
  if cfg.loadout and LOADOUTS[cfg.loadout] then
    st.loadout = cfg.loadout
  elseif cfg.loadout then
    aeaWarn("%s: unknown loadout '%s', using %s", unitName, tostring(cfg.loadout), st.loadout)
  end
  if ai then
    st.gated = cfg.gated ~= false
    st.maxTargets = tonumber(cfg.maxTargets) or maxTargetsForLoadout(st.loadout)
    st.band = "BOTH"
    st.dir = "AUTO"
    st.power = "NORM"
    st.rwr = false
    st.xmit = false
  end
  aeaLog("%s: registered (%s) loadout=%s maxTargets=%s gated=%s", unitName, ai and "AI" or "player",
    tostring(st.loadout), tostring(st.maxTargets), tostring(st.gated))
end

-- Arm / disarm an AI jammer (mission window, called from waypoint actions).
function AEA_SetArmed(unitName, armed)
  local st = AEA.jammers[unitName]
  if not st then
    aeaLog("%s: AEA_SetArmed(%s) ignored - not a registered jammer", tostring(unitName), tostring(armed))
    return
  end
  armed = armed and true or false
  if st.armed ~= armed then
    st.armed = armed
    local u = Unit.getByName(unitName)
    dbg(st, u, armed and "ARMED (mission window open)" or "DISARMED (mission window closed)")
  end
end


-- AI CONTROLLER

-- Looks for a reason to transmit. Returns threat(bool), reason(string), missileThreat(bool)
local function detectThreat(now, unit, st)
  local jp = unit:getPoint()
  local protectM = nmToM(opt("ai_protect_radius_nm"))

  -- 1. Radar guided enemy missile in flight against the package
  for _, m in pairs(AEA.trackedMissiles) do
    if m.side ~= st.coalition and unitExists(m.weapon) then
      local threatened = false
      if m.target then
        threatened = isProtectedAircraft(st, jp, m.target)
      else
        local okW, wp = pcall(function() return m.weapon:getPoint() end)
        threatened = okW and wp and dist2D(jp, wp) <= protectM
      end
      if threatened then
        return true, string.format("MISSILE %s (from %s) at %s", m.typeName, m.launcher, m.targetName), true
      end
    end
  end

  -- 2. Enemy radar tracking a protected aircraft ("lit up"), or (optional) active search radar
  local searchReason = nil
  local emitters = scanEmitters(enemySide(st.coalition)).threat
  for _, e in ipairs(emitters) do
    if unitExists(e) then
      local okP, ep = pcall(function() return e:getPoint() end)
      if okP and ep then
        local detNm, _, cls = rwrDetectNm(jp.y, e)
        if mToNm(dist2D(jp, ep)) <= detNm then
          local active, tracked = radarState(e)
          if active then
            if tracked and isProtectedAircraft(st, jp, tracked) then
              return true, string.format("LIT UP by %s %s (%s) tracking %s", cls, safeTypeName(e), safeGroupName(e), safeName(tracked)), false
            end
            if (not searchReason) and opt("ai_jam_search") then
              searchReason = string.format("SEARCH radar %s %s (%s) active", cls, safeTypeName(e), safeGroupName(e))
            end
          end
        end
      end
    end
  end
  if searchReason then return true, searchReason, false end

  return false, nil, false
end

local function setAIXmit(st, unit, on, reason)
  if st.xmit == on then return end
  st.xmit = on
  st.aiState = on and "XMIT" or "QUIET"
  dbg(st, unit, string.format("%s - %s (heat %.0f%%)", on and "XMIT ON" or "XMIT OFF", reason or "?", st.heat or 0))
end

local function runAIController(now, unit, st)
  local gating = opt("ai_window_gating")
  local armed = (not st.gated) or (not gating) or st.armed

  if not armed then
    if st.xmit then setAIXmit(st, unit, false, "outside mission window") end
    st.aiState = "DISARMED"
    return
  end
  if st.aiState == nil or st.aiState == "DISARMED" then st.aiState = st.xmit and "XMIT" or "QUIET" end

  local threat, reason, missile = detectThreat(now, unit, st)
  if threat then
    if reason ~= st.threatReason then
      if isDebug(st) then dbg(st, unit, "THREAT: " .. tostring(reason)) end
      st.threatReason = reason
    end
    st.lastThreatTime = now
  end
  if missile then st.missileThreatUntil = now + EA_TICK_SEC * 2 end

  local hold = opt("ai_hold_sec")
  local wantXmit = st.lastThreatTime ~= nil and (now - st.lastThreatTime) <= hold

  if now < (st.lockoutUntil or 0) then
    if wantXmit and isDebug(st) then
      dbgThrottle(st, unit, "lockout", 20.0, string.format("JMRS COOLING %.0fs - cannot XMIT", st.lockoutUntil - now))
    end
    wantXmit = false
  end

  if wantXmit and not st.xmit then
    setAIXmit(st, unit, true, st.threatReason)
  elseif (not wantXmit) and st.xmit then
    if now < (st.lockoutUntil or 0) then
      setAIXmit(st, unit, false, "JMRS overheat lockout")
    else
      setAIXmit(st, unit, false, string.format("no threat for %ds", math.floor(hold)))
    end
    st.threatReason = nil
  end

  -- Power management against the JMRS heat model
  local heat = st.heat or 0
  local desired = "NORM"
  if heat >= AI_HEAT_LOW then
    desired = "LOW"
  elseif (st.missileThreatUntil or 0) > now and heat < AI_HEAT_HIGH_MAX then
    desired = "HIGH"
  end
  if desired ~= st.power then
    if isDebug(st) then dbg(st, unit, string.format("POWER %s -> %s (heat %.0f%%)", tostring(st.power), desired, heat)) end
    st.power = desired
  end
end


-- SELF-PROTECTION JAMMERS (Retribution)
--
-- Defensive ECM pods (ALQ-131, ALQ-184, ALQ-164, L005, Sky Shadow, ...) and internal self-protection suites
-- only protect the aircraft carrying them. They run automatically (like a real DECM in AUTO):
--   * Track break: when an enemy radar is tracking THIS aircraft and the aircraft is outside the (longer)
--     self-protection burn-through range, deception jamming can briefly break the track (short WEAPON HOLD
--     on that radar's group / on the enemy fighter). Lower ERP than the AEA jammer: shorter holds, more ECCM
--     resistance, burn-through further out.
--   * Missile defeat: one roll per enemy active / semi-active radar missile aimed at THIS aircraft once it is
--     within spj_missile_nm.
-- There is no stand-off jamming, no search radar jamming and no protection of other aircraft.
-- DCS limitation: SAM ROE is set per group, so a track break also pauses that SAM group's other engagements.

local SPJ_GEN = {
  [1] = {resistAdd=0.20, holdMul=0.5, missileMul=0.6},  -- before 1985: analogue noise / deception
  [2] = {resistAdd=0.12, holdMul=0.6, missileMul=1.0},  -- 1985-1995
  [3] = {resistAdd=0.05, holdMul=0.7, missileMul=1.4},  -- after 1995 / internal suites (DRFM)
}
local SPJ_BURN_MUL = 1.6        -- self-protection burn-through range vs. the AEA burn-through range
local SPJ_TRACKER_COOLDOWN = 8  -- s between track breaks on the same radar
local SPJ_AIR_SCAN_NM = 60      -- enemy fighters considered as trackers

local function scanAir(side)
  if not side then return {} end
  local now = timer.getTime()
  local cache = AEA.airCache[side]
  if cache and (now - cache.t) < 2.0 then return cache.units end
  local units = {}
  local ok, groups = pcall(function() return coalition.getGroups(side, Group.Category.AIRPLANE) end)
  if ok and groups then
    for _,g in ipairs(groups) do
      local okU, us = pcall(function() return g:getUnits() end)
      if okU and us then
        for _,u in ipairs(us) do
          if unitExists(u) and (not isPlayerUnit(u)) and hasRadar(u) then units[#units+1] = u end
        end
      end
    end
  end
  AEA.airCache[side] = {t=now, units=units}
  return units
end

local function isSameObject(a, b)
  if not a or not b then return false end
  if a == b then return true end
  local na, nb = safeName(a), safeName(b)
  return na ~= "?" and na == nb
end

-- Enemy radars currently tracking `unit`: list of {unit=, air=bool, rangeNm=}
local function spjTrackers(unit, sp)
  local up = unit:getPoint()
  local side = enemySide(sp.coalition)
  local out = {}
  for _,e in ipairs(scanEmitters(side).threat) do
    if unitExists(e) then
      local okP, ep = pcall(function() return e:getPoint() end)
      if okP and ep then
        local rng = mToNm(dist2D(up, ep))
        local det = rwrDetectNm(up.y, e)
        if rng <= det then
          local active, tracked = radarState(e)
          if active and isSameObject(tracked, unit) then
            out[#out+1] = {unit=e, air=false, rangeNm=rng}
          end
        end
      end
    end
  end
  for _,a in ipairs(scanAir(side)) do
    local okP, ap = pcall(function() return a:getPoint() end)
    if okP and ap then
      local rng = mToNm(dist2D(up, ap))
      if rng <= SPJ_AIR_SCAN_NM then
        local active, tracked = radarState(a)
        if active and isSameObject(tracked, unit) then
          out[#out+1] = {unit=a, air=true, rangeNm=rng}
        end
      end
    end
  end
  return out
end

local function spjTrackBreak(now, unit, sp, tr)
  local g = SPJ_GEN[sp.gen] or SPJ_GEN[2]
  local e = tr.unit
  local key = unitKey(e)
  if now < (sp.cooldown[key] or 0) then return end

  if tr.air then
    local uname = safeName(e)
    if now < (AEA.airCooldown[uname] or 0) then return end
    -- airborne fire-control radars: tier 1 ECCM, burn-through 8 NM
    local burn = 8
    if tr.rangeNm <= burn then return end
    local t01 = clamp((tr.rangeNm - burn) / burn, 0, 1)
    local resist = clamp(TIER[1].resist + g.resistAdd + (1 - t01) * 0.25, 0.05, 0.95)
    local roll = _rand()
    if roll < resist then
      aeaLogV("%s: SPJ ECCM RESIST %s (air) roll=%.2f<thr=%.2f rng=%.1fNM", sp.unitName, safeTypeName(e), roll, resist, tr.rangeNm)
      return
    end
    if safeSetAirHold(e) then
      -- AEA air effect hold (2-4 s), scaled by generation relative to gen 2
      local hold = clamp(randf(2.0, 4.0) * g.holdMul / SPJ_GEN[2].holdMul, 2.0, 6.0)
      timer.scheduleFunction(function(param, t)
        if unitExists(param) then safeSetAirOpen(param) end
        return nil
      end, e, now + hold)
      AEA.airCooldown[uname] = now + AIR_EVENT_COOLDOWN
      sp.cooldown[key] = now + SPJ_TRACKER_COOLDOWN
      sp.stats.breaks = sp.stats.breaks + 1
      if isDebug(sp) then
        dbg(sp, unit, string.format("SPJ TRACK BREAK %s (%s, air) hold=%.1fs rng=%.1fNM", uname, safeTypeName(e), hold, tr.rangeNm), 3)
      end
    end
    return
  end

  if not shouldPulseTarget(now, e) then return end
  local tier = getEccmTierForUnit(e)
  local base = TIER[tier]
  if not base then return end
  local burn = burnThroughNmForTier(tier) * SPJ_BURN_MUL
  if tr.rangeNm <= burn then
    if isDebugV(sp) then
      dbgThrottle(sp, unit, "spjburn:" .. key, 10.0, string.format("SPJ BURNED THROUGH by %s (%s) rng=%.1fNM <= %.1fNM",
        safeTypeName(e), safeGroupName(e), tr.rangeNm, burn))
    end
    return
  end
  local t01 = clamp((tr.rangeNm - burn) / burn, 0, 1)
  local resist = clamp(base.resist + g.resistAdd + (1 - t01) * 0.25, 0.05, 0.95)
  local roll = _rand()
  if roll < resist then
    if isDebugV(sp) then
      dbgThrottle(sp, unit, "spjres:" .. key, 4.0, string.format("SPJ ECCM RESIST %s (%s) roll=%.2f<thr=%.2f tier=%d rng=%.1fNM",
        safeTypeName(e), safeGroupName(e), roll, resist, tier, tr.rangeNm))
    end
    return
  end
  if not safeSetWeaponHold(e) then return end
  local hold = clamp(randf(base.holdMin, base.holdMax) * g.holdMul, 2.0, 6.0)
  scheduleRelease(e, markPulsed(now, e, hold))
  sp.cooldown[key] = now + SPJ_TRACKER_COOLDOWN
  sp.stats.breaks = sp.stats.breaks + 1
  if isDebug(sp) then
    dbg(sp, unit, string.format("SPJ TRACK BREAK %s (%s) tier=%d hold=%.1fs rng=%.1fNM",
      safeTypeName(e), safeGroupName(e), tier, hold, tr.rangeNm), 3)
  end
end

local function spjMissileDefeat(now, unit, sp)
  local g = SPJ_GEN[sp.gen] or SPJ_GEN[2]
  local up = unit:getPoint()
  local rangeM = nmToM(opt("spj_missile_nm"))
  local chance = clamp(opt("spj_missile_chance") * g.missileMul, 0, 1)
  for key, m in pairs(AEA.trackedMissiles) do
    if m.side ~= sp.coalition and not AEA.missileRolls[key] and isSameObject(m.target, unit) and unitExists(m.weapon) then
      local okW, wp = pcall(function() return m.weapon:getPoint() end)
      if okW and wp and dist2D(up, wp) <= rangeM then
        AEA.missileRolls[key] = true
        local roll = _rand()
        local hit = roll <= chance
        if isDebug(sp) then
          dbg(sp, unit, string.format("SPJ MSL ROLL %s (from %s) rng=%.1fNM roll=%.2f thr=%.2f -> %s", m.typeName, m.launcher,
            mToNm(dist2D(up, wp)), roll, chance, hit and "DEFEATED" or "not defeated"), 3)
        end
        if hit then
          sp.stats.missiles = sp.stats.missiles + 1
          scheduleMissileKill(m.weapon, now)
        end
      end
    end
  end
end

local function updateSelfProtect(now, unit, sp)
  if now < sp.nextTick then return end
  sp.nextTick = now + EA_TICK_SEC

  local trackers = spjTrackers(unit, sp)
  if #trackers > 0 then
    if not sp.active then
      sp.active = true
      local t = trackers[1].unit
      dbg(sp, unit, string.format("SPJ ON - tracked by %s (%s)%s", safeTypeName(t), safeGroupName(t),
        #trackers > 1 and string.format(" +%d more", #trackers - 1) or ""))
    end
    for _,tr in ipairs(trackers) do spjTrackBreak(now, unit, sp, tr) end
  elseif sp.active then
    sp.active = false
    dbg(sp, unit, "SPJ OFF - no longer tracked")
  end

  spjMissileDefeat(now, unit, sp)
end

-- Register a self-protection jammer.
--   cfg.gen : 1 / 2 / 3 (pod generation, see SPJ_GEN)
--   cfg.pod : pod name (logging only)
--   cfg.ai  : true for AI aircraft
function AEA_RegisterSelfProtect(unitName, cfg)
  if type(unitName) ~= "string" then return end
  cfg = cfg or {}
  if not opt("spj_enabled") then
    aeaLog("%s: self-protection jammers disabled - not registered", unitName)
    return
  end
  if (not cfg.ai) and not opt("spj_players") then
    aeaLog("%s: self-protection for players disabled - not registered", unitName)
    return
  end
  if AEA.jammers[unitName] then
    aeaLog("%s: already an AEA jammer - self-protection not registered", unitName)
    return
  end
  local gen = tonumber(cfg.gen) or 2
  if not SPJ_GEN[gen] then gen = 2 end
  AEA.selfProtect[unitName] = {
    unitName = unitName, gen = gen, pod = tostring(cfg.pod or "ECM"), ai = cfg.ai and true or false,
    nextTick = 0, cooldown = {}, stats = {breaks=0, missiles=0}, active = false,
  }
  aeaLog("%s: registered self-protection (%s) pod=%s gen=%d", unitName, cfg.ai and "AI" or "player",
    tostring(cfg.pod or "ECM"), gen)
end


-- MAIN LOOP

local nextPrefixScan = 0

-- Fallback for hand-made missions: units named "[EA-18G]..." register themselves.
local function prefixScan()
  for _,coal in ipairs({coalition.side.BLUE, coalition.side.RED}) do
    local ok, groups = pcall(function() return coalition.getGroups(coal, Group.Category.AIRPLANE) end)
    if ok and groups then
      for _,g in ipairs(groups) do
        local okU, units = pcall(function() return g:getUnits() end)
        if okU and units then
          for _,u in ipairs(units) do
            if unitExists(u) then
              local uname = u:getName()
              if startsWith(uname, NAME_PREFIX) and not AEA.jammers[uname] then
                if isPlayerUnit(u) then
                  AEA_RegisterJammer(uname, {ai=false})
                elseif opt("ai_enabled") then
                  AEA_RegisterJammer(uname, {ai=true, gated=false})
                end
              end
            end
          end
        end
      end
    end
  end
end

local function updatePlayer(now, u, st)
  if not st.menusBuilt then
    buildMenusForUnit(u, st)
    st.menusBuilt = true
    aeaLog("%s: player %s - AEA menu built (loadout %s)", st.unitName, tostring(u:getPlayerName()), tostring(st.loadout))
  end

  -- ALQ-218 / RWR
  runRWR(now, u, st)

  if st.messages == "LOW" and (now - st.lastHeartbeat) >= HEARTBEAT_SEC then
    heartbeat(st, u)
    st.lastHeartbeat = now
  end

  if (st.messages == "NORM" or st.messages == "DEBUG") and st.xmit and (now - st.lastStatusPush) >= NORM_STATUS_REFRESH_SEC then
    pushStatus(st, u)
    st.lastStatusPush = now
  end

  updateHeat(now, u, st)

  if now >= st.nextEaTick then
    st.nextEaTick = now + EA_TICK_SEC
    runJamming(now, u, st)
    runMissileDisruption(now, u, st)
    runAircraftEffects(now, u, st)
  end
end

local function updateAI(now, u, st)
  updateHeat(now, u, st)

  if now >= st.nextEaTick then
    st.nextEaTick = now + EA_TICK_SEC
    runAIController(now, u, st)
    runJamming(now, u, st)
    runMissileDisruption(now, u, st)
    runAircraftEffects(now, u, st)
  end

  if opt("DEBUG_LOG") and (now - (st._aiStatusLog or -1e9)) >= AI_STATUS_LOG_SEC then
    st._aiStatusLog = now
    aeaLog("%s: status state=%s armed=%s gated=%s xmit=%s pwr=%s heat=%.0f%% tgt=%d/%d suppressions=%d",
      st.unitName, tostring(st.aiState), tostring(st.armed), tostring(st.gated), tostring(st.xmit),
      tostring(st.power), st.heat or 0, st.usedTargets or 0, st.maxTargets or 0, (st.stats and st.stats.suppress) or 0)
  end
end

local function updateAll(_, now)
  local ok, err = pcall(function()
    if now >= nextPrefixScan then
      nextPrefixScan = now + PREFIX_SCAN_SEC
      prefixScan()
    end

    for uname, st in pairs(AEA.jammers) do
      local u = Unit.getByName(uname)
      if unitExists(u) then
        if not st.alive then
          st.alive = true
          pcall(function() st.coalition = u:getCoalition() end)
          aeaLog("%s: jammer active (%s, coalition %s)", uname, safeTypeName(u), tostring(st.coalition))
        end
        if st.ai then
          if not isPlayerUnit(u) then updateAI(now, u, st) end
        elseif isPlayerUnit(u) then
          updatePlayer(now, u, st)
        end
      elseif st.alive then
        st.alive = false
        st.xmit = false
        aeaLog("%s: jammer no longer exists", uname)
      end
    end

    for uname, sp in pairs(AEA.selfProtect) do
      local u = Unit.getByName(uname)
      if unitExists(u) then
        if not sp.alive then
          sp.alive = true
          pcall(function() sp.coalition = u:getCoalition() end)
          aeaLog("%s: self-protection active (%s, coalition %s)", uname, safeTypeName(u), tostring(sp.coalition))
        end
        updateSelfProtect(now, u, sp)
      elseif sp.alive then
        sp.alive = false
        sp.active = false
        aeaLog("%s: self-protected aircraft no longer exists (track breaks=%d, missiles defeated=%d)",
          uname, sp.stats.breaks, sp.stats.missiles)
      end
    end

    cleanupMissiles()
  end)
  if not ok then
    aeaWarn("update error: %s", tostring(err))
  end

  return now + 1
end

-- read-only access for tests / debugging
AEA_Internals = {LOADOUTS = LOADOUTS, ngjMods = ngjMods, SPJ_GEN = SPJ_GEN, state = AEA}

timer.scheduleFunction(updateAll, nil, timer.getTime() + 1)
env.info("[EWS3] EA-18G AEA script loaded (EW Script 3.0)")
