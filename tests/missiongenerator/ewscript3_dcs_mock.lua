-- Minimal DCS scripting environment mock used by test_ewscript3_lua.py (EW Script 3.0 plugin)
LOG = {}
ROE = {}       -- [unitName] = last ROE value
DESTROYED = {}
OUT = {}
local now = 0
local scheduled = {}

env = {
  info = function(s) LOG[#LOG+1] = s end,
  warning = function(s) LOG[#LOG+1] = "WARN " .. s end,
}
timer = {
  getTime = function() return now end,
  scheduleFunction = function(f, arg, t) scheduled[#scheduled+1] = {f=f, arg=arg, t=t} end,
}
function advance(sec)
  local target = now + sec
  while true do
    local idx, best = nil, nil
    for i, s in ipairs(scheduled) do
      if s.t <= target and (best == nil or s.t < best.t) then idx, best = i, s end
    end
    if not idx then break end
    table.remove(scheduled, idx)
    now = best.t
    local nt = best.f(best.arg, now)
    if nt then scheduled[#scheduled+1] = {f=best.f, arg=best.arg, t=nt} end
  end
  now = target
end

coalition = { side = {NEUTRAL=0, RED=1, BLUE=2} }
Group = { Category = {AIRPLANE=0, HELICOPTER=1, GROUND=2, SHIP=3} }
Unit = { Category = {AIRPLANE=0, HELICOPTER=1}, SensorType = {RADAR=1} }
Object = { Category = {UNIT=1, WEAPON=2}, getCategory = function(o) return o._objcat end }
Weapon = { Category = {SHELL=0, MISSILE=1, ROCKET=2, BOMB=3},
           GuidanceType = {INS=1, IR=2, RADAR_ACTIVE=3, RADAR_SEMI_ACTIVE=4, RADAR_PASSIVE=5} }
AI = { Option = {
  Ground = { id = {ROE=0}, val = {ROE = {OPEN_FIRE=2, WEAPON_HOLD=4}} },
  Naval  = { id = {ROE=0}, val = {ROE = {OPEN_FIRE=2, WEAPON_HOLD=4}} },
  Air    = { id = {ROE=0}, val = {ROE = {OPEN_FIRE=2, WEAPON_HOLD=4}} },
}}
world = { event = {S_EVENT_SHOT=1}, handlers = {} }
function world.addEventHandler(h) world.handlers[#world.handlers+1] = h end
trigger = { action = {
  outText = function(t) OUT[#OUT+1] = "ALL " .. t end,
  outTextForUnit = function(id, t) OUT[#OUT+1] = "UNIT" .. id .. " " .. t end,
  outTextForCoalition = function(c, t) OUT[#OUT+1] = "COAL" .. c .. " " .. t end,
}}
missionCommands = {
  addSubMenuForGroup = function(gid, name, parent) return {name} end,
  addCommandForGroup = function() end,
}
coord = { LOtoLL = function(p) return p.x / 111000, p.z / 111000 end }
math.atan2 = math.atan2 or math.atan

local groups = {}  -- [side][cat] = {group,...}
local unitsByName = {}
local nextId = 1

local UnitMT = {}
UnitMT.__index = UnitMT
function UnitMT:isExist() return self._alive end
function UnitMT:isActive() return true end
function UnitMT:getName() return self._name end
function UnitMT:getID() return self._id end
function UnitMT:getTypeName() return self._type end
function UnitMT:getDesc() return {typeName=self._type, category=self._desccat, attributes=self._attr} end
function UnitMT:getCoalition() return self._side end
function UnitMT:getPoint() return self._pos end
function UnitMT:getPosition() return {x={x=1, y=0, z=0}, p=self._pos} end
function UnitMT:getGroup() return self._group end
function UnitMT:getPlayerName() return self._player end
function UnitMT:hasAttribute(a) return self._attr[a] == true end
function UnitMT:hasSensors() return self._radar ~= nil end
function UnitMT:getRadar() return self._radarOn == true, self._tracked end
function UnitMT:getController()
  local u = self
  return { setOption = function(_, id, val) ROE[u._name] = val end }
end
function UnitMT:destroy() self._alive = false; DESTROYED[#DESTROYED+1] = self._name end
function UnitMT:getTarget() return self._target end

local GroupMT = {}
GroupMT.__index = GroupMT
function GroupMT:getUnits() return self._units end
function GroupMT:getName() return self._name end
function GroupMT:getID() return self._id end
function GroupMT:getCategory() return self._cat end
function GroupMT:isExist() return true end

function addGroup(side, cat, name, unitDefs)
  local g = setmetatable({_name=name, _id=nextId, _cat=cat, _units={}}, GroupMT)
  nextId = nextId + 1
  for _, d in ipairs(unitDefs) do
    local u = setmetatable({
      _name=d.name, _id=nextId, _type=d.type, _side=side, _pos=d.pos, _group=g, _alive=true,
      _attr=d.attr or {}, _player=d.player, _radar=d.radar, _radarOn=d.radarOn, _tracked=d.tracked,
      _desccat=(cat == Group.Category.AIRPLANE and 0) or (cat == Group.Category.SHIP and 3) or 2,
      _objcat=Object.Category.UNIT,
    }, UnitMT)
    nextId = nextId + 1
    g._units[#g._units+1] = u
    unitsByName[d.name] = u
  end
  groups[side] = groups[side] or {}
  groups[side][cat] = groups[side][cat] or {}
  table.insert(groups[side][cat], g)
  return g
end

coalition.getGroups = function(side, cat) return (groups[side] or {})[cat] or {} end
Unit.getByName = function(n) local u = unitsByName[n]; if u and u._alive then return u end; return nil end
U = function(n) return unitsByName[n] end

function makeWeapon(name, side, typeName, guidance, pos, target)
  local w = setmetatable({_name=name, _type=typeName, _side=side, _pos=pos, _alive=true, _target=target,
    _objcat=Object.Category.WEAPON, _attr={}}, UnitMT)
  w.getDesc = function() return {category=Weapon.Category.MISSILE, guidance=guidance, typeName=typeName} end
  unitsByName[name] = w
  return w
end

function fireShot(initiator, weapon)
  for _, h in ipairs(world.handlers) do h:onEvent({id=world.event.S_EVENT_SHOT, initiator=initiator, weapon=weapon}) end
end
