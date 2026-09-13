-- A personality is a bias, not a brain: which research it leans on, and what it
-- does with itself when nobody has asked for anything. It lives in a data file
-- like a directive, and everything it decides is decided here, in the game, on
-- the game's own clock.

local Body = require("script.body")
local Conditions = require("script.conditions")

local Personality = {}

local ORDER_GAP = 60 * 30 -- never volunteer more than twice a minute

local function crew()
  storage.crew = storage.crew or {}
  return storage.crew
end

function Personality.known()
  return crew().personalities or {}
end

-- Two slots, and they are not equal: the primary decides, the secondary fills in
-- when the primary has nothing to say. A Sparks who scouts between jobs is a
-- different crewmate from a Scout who keeps the lights on.
function Personality.slots()
  local state = crew()
  state.personality = state.personality or {}
  return state.personality
end

local function find(name)
  for _, entry in pairs(Personality.known()) do
    if entry.name == name then return entry end
  end
end

function Personality.current()
  return find(Personality.slots().primary or "")
end

function Personality.second()
  return find(Personality.slots().secondary or "")
end

-- Primary first, then secondary: the order everything else here reads them in.
function Personality.both()
  local order = {}
  local primary, secondary = Personality.current(), Personality.second()
  if primary then order[#order + 1] = primary end
  if secondary and (not primary or secondary.name ~= primary.name) then
    order[#order + 1] = secondary
  end
  return order
end

function Personality.adopt(name, slot)
  local entry = find(name)
  if not entry then return nil end
  local slots = Personality.slots()
  slots[slot or "primary"] = name
  if slot ~= "secondary" and slots.secondary == name then slots.secondary = nil end
  local state = crew()
  state.research_said, state.orders_at = nil, nil
  return entry
end

function Personality.forget(slot)
  local slots = Personality.slots()
  if slot then
    slots[slot] = nil
  else
    slots.primary, slots.secondary = nil, nil
  end
end

-- Walk up a technology's prerequisites to the first thing that can actually be
-- researched now. A path in a file can name the destination and skip the middle.
local function researchable(force, name, depth)
  local technology = force.technologies[name]
  if not technology or technology.researched or not technology.enabled then return nil end
  if depth > 12 then return nil end
  for _, prerequisite in pairs(technology.prerequisites) do
    if not prerequisite.researched then
      local earlier = researchable(force, prerequisite.name, depth + 1)
      if earlier then return earlier end
      return nil -- a prerequisite that cannot be researched blocks this branch
    end
  end
  return technology
end

-- Put the next thing on its path into an empty research queue, and say why.
--
-- Some of the early tree is not queueable at all: in Space Age steam power is
-- unlocked by crafting fifty iron plates, not by researching anything. Those get
-- said out loud rather than silently skipped -- knowing the next step is a job for
-- somebody is the whole point of having an opinion about research.
local function trigger_of(technology)
  local prototype = prototypes.technology[technology.name]
  return prototype and prototype.research_trigger
end

local function describe_trigger(trigger)
  if trigger.type == "craft-item" then
    return string.format("crafting %d %s", trigger.count or 1, trigger.item and trigger.item.name or "something")
  elseif trigger.type == "mine-entity" then
    return string.format("mining %s", trigger.entity or "something")
  elseif trigger.type == "craft-fluid" then
    return string.format("making %d %s", trigger.amount or 1, trigger.fluid or "fluid")
  elseif trigger.type == "build-entity" then
    return string.format("building %s", trigger.entity and trigger.entity.name or "something")
  end
  return "doing something in particular"
end

function Personality.steer_research(force)
  if force.current_research or not force.research_enabled then return end
  local state = crew()

  for _, personality in ipairs(Personality.both()) do
    for _, wanted in ipairs(personality.research_path or {}) do
      local technology = researchable(force, wanted, 0)
      if technology then
        local trigger = trigger_of(technology)
        if trigger then
          local said = state.research_said
          if said ~= technology.name then
            state.research_said = technology.name
            Body.say(string.format("%s unlocks by %s, not by research -- that is the next step.",
              technology.name, describe_trigger(trigger)))
          end
        elseif force.add_research(technology.name) then
          if state.research_said ~= technology.name then
            state.research_said = technology.name
            local why = technology.name == wanted and "" or (" -- on the way to " .. wanted)
            Body.say(string.format("researching %s%s.", technology.name, why))
          end
          return technology.name
        end
      end
    end
  end
end

-- When nothing has been asked of it, do what it would do anyway. The order is
-- queued like any other request, so the same path runs it.
function Personality.standing_orders(force, plan_running)
  if plan_running then return end

  local state = crew()
  if state.orders_at and game.tick - state.orders_at < ORDER_GAP then return end

  for _, personality in ipairs(Personality.both()) do
    for _, order in ipairs(personality.standing_orders or {}) do
      local due = not order.every or not state.order_last or not state.order_last[order.directive]
        or game.tick - state.order_last[order.directive] >= order.every * 60
      -- A standing order is a condition as much as a timer: Sparks only goes for
      -- coal when it is short of coal.
      local body = Body.get()
      local wanted = false
      if body then wanted = Conditions.hold({}, body, order["when"]) end
      if due and wanted then
        state.order_last = state.order_last or {}
        state.order_last[order.directive] = game.tick
        state.orders_at = game.tick
        state.requests = state.requests or {}
        table.insert(state.requests, {
          directive = order.directive,
          parameters = order.parameters,
          player = personality.name,
          standing = true,
        })
        return order.directive
      end
    end
  end
end

return Personality
