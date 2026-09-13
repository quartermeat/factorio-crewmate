-- The seam the bridge talks to. Every call returns a JSON string, because RCON
-- hands back exactly what rcon.print writes and nothing more.

local Body = require("script.body")
local Senses = require("script.senses")
local Hands = require("script.hands")
local Plan = require("script.plan")
local Works = require("script.works")
local Craft = require("script.craft")

local function ok(value)
  return helpers.table_to_json({ok = true, result = value or {}})
end

local function fail(message)
  return helpers.table_to_json({ok = false, error = message})
end

local function guarded(handler)
  return function(argument)
    local success, value = pcall(handler, argument or {})
    if not success then return fail(tostring(value)) end
    return value
  end
end

local interface =
{
  status = guarded(function()
    return ok(Senses.status())
  end),

  look = guarded(function(argument)
    return ok(Senses.look(argument.radius))
  end),

  hear = guarded(function()
    return ok(Senses.hear())
  end),

  say = guarded(function(argument)
    local message = argument.message
    if not message or message == "" then return fail("nothing to say") end
    game.print(string.format("[color=%f,%f,%f][%s][/color] %s",
      Body.COLOR.r, Body.COLOR.g, Body.COLOR.b, Body.NAME, message))
    return ok({said = message})
  end),

  spawn = guarded(function(argument)
    local surface = game.get_surface(argument.surface or "nauvis")
    if not surface then return fail("no such surface: " .. tostring(argument.surface)) end
    local position = argument.position
    if not position then
      local player = argument.player and game.get_player(argument.player) or game.connected_players[1]
      position = player and player.position or {x = 0, y = 0}
      surface = player and player.surface or surface
    end
    local body, err = Body.spawn(surface, position, game.forces.player)
    if not body then return fail(err) end
    return ok({position = body.position, surface = body.surface.name})
  end),

  walk_to = guarded(function(argument)
    if not Body.get() then return fail("no body in the world; spawn one first") end
    if not (argument.x and argument.y) then return fail("walk_to needs x and y") end
    Body.walk_to({x = argument.x, y = argument.y})
    return ok({walking_to = {x = argument.x, y = argument.y}})
  end),

  follow = guarded(function(argument)
    if not Body.get() then return fail("no body in the world; spawn one first") end
    local player = game.get_player(argument.player or 1)
    if not player then return fail("no such player: " .. tostring(argument.player)) end
    Body.follow(player)
    return ok({following = player.name})
  end),

  halt = guarded(function()
    Body.halt()
    return ok({stopped = true})
  end),

  -- Directives arrive compiled by the bridge: the mod never reads files, because
  -- a Factorio mod cannot.
  run_plan = guarded(function(argument)
    local plan, err = Plan.start(argument)
    if not plan then return fail(err) end
    return ok({name = plan.name, steps = #plan.steps})
  end),

  plan_status = guarded(function()
    return ok(Plan.status())
  end),

  cancel_plan = guarded(function()
    return ok({cancelled = Plan.cancel()})
  end),

  -- What a directive would cost, before starting it: the blueprint's own bill of
  -- materials, checked against what the body is carrying.
  blueprint_needs = guarded(function(argument)
    local body = Body.get()
    if not body then return fail("no body in the world") end
    local needs, err = Hands.blueprint_cost(argument.blueprint)
    if not needs then return fail(err) end
    for _, extra in pairs(argument.supplies or {}) do
      needs[#needs + 1] = extra
    end
    return ok({needs = needs, missing = Hands.missing(body, needs)})
  end),

  -- Where an offshore pump could actually go near a point: water edges are the
  -- one thing a directive cannot assume.
  pump_spots = guarded(function(argument)
    local body = Body.get()
    if not body then return fail("no body in the world") end
    local centre = argument.position or body.position
    local spots = Works.pump_spots(body, centre, argument.radius, argument.limit)
    return ok({spots = spots, searched = centre, radius = argument.radius or 64})
  end),

  -- The game cannot read the directive files, so /crew do leaves a request here
  -- and the bridge, which is already running, picks it up and compiles it.
  take_requests = guarded(function()
    local state = storage.crew or {}
    local pending = state.requests or {}
    state.requests = {}
    return ok({requests = pending})
  end),

  -- ...and the bridge tells the game what it knows how to do, so /crew do can
  -- list the directives without leaving the game.
  set_catalogue = guarded(function(argument)
    storage.crew = storage.crew or {}
    storage.crew.catalogue = argument.directives or {}
    return ok({known = #(argument.directives or {})})
  end),

  -- The same queue /crew do writes to, reachable from outside the game as well.
  request = guarded(function(argument)
    if not argument.directive then return fail("which directive?") end
    storage.crew = storage.crew or {}
    storage.crew.requests = storage.crew.requests or {}
    table.insert(storage.crew.requests, {
      directive = argument.directive,
      player = argument.player or "bridge",
      parameters = argument.parameters,
    })
    return ok({queued = argument.directive})
  end),

  -- Where the nearest patch of something is, without committing to anything.
  find_resource = guarded(function(argument)
    local body = Body.get()
    if not body then return fail("no body in the world") end
    local found, err = Works.find_resource(body, argument.resource or "coal", argument.radius)
    if not found then return fail(err) end
    return ok(found)
  end),

  relabel = guarded(function()
    Body.relabel()
    return ok({name = Body.NAME})
  end),

  craftable = guarded(function(argument)
    local body = Body.get()
    if not body then return fail("no body in the world") end
    local listed, total = Craft.craftable(body, argument.limit)
    return ok({craftable = listed, total = total})
  end),

  catalogue = guarded(function()
    return ok({directives = (storage.crew or {}).catalogue or {}})
  end),

  carrying = guarded(function()
    local body = Body.get()
    if not body then return fail("no body in the world") end
    local inventory = body.get_main_inventory()
    local carried = {}
    for _, item in pairs(inventory and inventory.get_contents() or {}) do
      carried[#carried + 1] = {name = item.name, count = item.count}
    end
    return ok({carrying = carried, reach = body.build_distance})
  end),

  screenshot = guarded(function(argument)
    local shot = Senses.screenshot(argument)
    if shot.error then return fail(shot.error) end
    return ok(shot)
  end),
}

remote.add_interface("crewmate", interface)

-- Same thing from inside the game, so the mod is testable without the bridge.
local function normalise(name)
  return (name or ""):lower():gsub("%s+", "-")
end

-- Handing things over. A player cannot open another character's inventory, so
-- this is the honest substitute: your items, moved from your pockets to its.
local function hand_over(player, parameter)
  local body = Body.get()
  if not body then
    player.print("[Crew] I have no body here -- /crew come first.")
    return
  end
  local name, count = parameter:match("^(%S+)%s*(%d*)$")
  name = normalise(name)
  if not name or not prototypes.item[name] then
    player.print("[Crew] I do not know an item called '" .. tostring(name) .. "'.")
    return
  end

  local inventory = player.get_main_inventory()
  local available = inventory and inventory.get_item_count(name) or 0
  if available == 0 then
    player.print("[Crew] you are not carrying any " .. name .. ".")
    return
  end
  local wanted = tonumber(count) or available
  wanted = math.min(wanted, available)

  local moved = body.insert{name = name, count = wanted}
  if moved == 0 then
    player.print("[Crew] my pockets are full.")
    return
  end
  inventory.remove{name = name, count = moved}
  player.print(string.format("[Crew] thanks -- %d %s.", moved, name))
end

local function hand_back(player, parameter)
  local body = Body.get()
  if not body then return end
  local inventory = body.get_main_inventory()
  if not inventory then return end
  local name = normalise((parameter or ""):match("^%S+") or "")
  local given = 0
  for _, stack in pairs(inventory.get_contents()) do
    if name == "" or stack.name == name then
      local moved = player.insert{name = stack.name, count = stack.count}
      inventory.remove{name = stack.name, count = moved}
      given = given + moved
    end
  end
  player.print(string.format("[Crew] handed back %d items.", given))
end

-- /crew do queues a directive by name. Nothing here knows what the directives
-- are; the bridge polls for these and does the rest.
-- Whether the game has unlocked everything a directive depends on. The recipes
-- carry the answer already: a recipe is disabled until its research is done.
local function unlocked(force, entry)
  for _, recipe in pairs(entry.requires or {}) do
    local known = force.recipes[recipe]
    if not known or not known.enabled then return false, recipe end
  end
  return true
end

local function request_directive(player, parameter, parameters)
  storage.crew = storage.crew or {}
  local catalogue = storage.crew.catalogue or {}

  local name = normalise((parameter or ""):match("^%S+") or "")
  if name == "" then
    if #catalogue == 0 then
      player.print("[Crew] I have no directives loaded -- is the bridge running?")
      return
    end
    local locked = {}
    player.print("[Crew] I know how to:")
    for _, entry in pairs(catalogue) do
      local available, missing = unlocked(player.force, entry)
      if available then
        player.print(string.format("  /crew do %s  --  %s", entry.name, entry.title or ""))
      else
        locked[#locked + 1] = string.format("%s (needs %s)", entry.name, missing)
      end
    end
    if #locked > 0 then
      player.print("[Crew] not yet: " .. table.concat(locked, ", "))
    end
    return
  end

  local known = false
  for _, entry in pairs(catalogue) do
    if entry.name == name then
      known = true
      local available, missing = unlocked(player.force, entry)
      if not available then
        player.print(string.format("[Crew] %s needs %s, which is not unlocked yet.", name, missing))
        return
      end
    end
  end
  if not known and #catalogue > 0 then
    player.print("[Crew] I do not know a directive called '" .. name .. "'. Try /crew do.")
    return
  end

  storage.crew.requests = storage.crew.requests or {}
  table.insert(storage.crew.requests,
    {directive = name, player = player.name, tick = game.tick, parameters = parameters})
  player.print("[Crew] right -- " .. name .. ". Give me a moment to work out where.")
end

-- /crew mine coal 200 is /crew do mine-coal with an amount: the common case
-- deserves the shorter sentence.
-- What people actually type, against what the game calls it.
local ORE_NAMES =
{
  iron = "iron-ore",
  copper = "copper-ore",
  ["iron-ore"] = "iron-ore",
  ["copper-ore"] = "copper-ore",
  coal = "coal",
  stone = "stone",
  wood = "wood",
  tree = "wood",
  trees = "wood",
}

local function request_mining(player, parameter)
  local resource, amount = parameter:match("^(%S*)%s*(%d*)$")
  resource = normalise(resource or "")
  if resource == "" then
    player.print("[Crew] mine what? Try /crew mine iron 200. I know coal, iron, copper, stone and wood.")
    return
  end

  local parameters = {}
  if tonumber(amount) then parameters.amount = tonumber(amount) end

  local wanted = ORE_NAMES[resource] or resource
  local catalogue = (storage.crew or {}).catalogue or {}
  for _, entry in pairs(catalogue) do
    if entry.name == "mine-" .. wanted then
      return request_directive(player, "mine-" .. wanted, parameters)
    end
  end

  -- Anything else minable still works: gather takes the name straight.
  parameters.resource = wanted
  player.print("[Crew] no set job for " .. wanted .. "; I will go and dig some anyway.")
  request_directive(player, "gather", parameters)
end

-- /crew make stone-furnace 2, or /crew make furnace: short names people use for
-- the handful of things worth hand-making early.
local ITEM_NAMES =
{
  furnace = "stone-furnace",
  ["stone-furnace"] = "stone-furnace",
  smelter = "stone-furnace",
  chest = "wooden-chest",
  box = "wooden-chest",
  belt = "transport-belt",
  inserter = "inserter",
  drill = "burner-mining-drill",
  ["burner-drill"] = "burner-mining-drill",
  axe = "iron-axe",
  pole = "small-electric-pole",
  pipe = "pipe",
  lab = "lab",
}

local function request_making(player, parameter)
  local item, count = parameter:match("^(%S*)%s*(%d*)$")
  item = normalise(item or "")
  if item == "" then
    -- Same manners as /crew do with nothing after it: say what is on offer.
    local body = Body.get()
    if not body then
      player.print("[Crew] I have no body here -- /crew come first.")
      return
    end
    local listed, total = Craft.craftable(body, 24)
    player.print(string.format("[Crew] I can make %d things by hand from what I can dig up:", total))
    for _, entry in pairs(listed) do
      player.print(string.format("  /crew make %s  --  %s", entry.name, entry.needs))
    end
    if total > #listed then
      player.print(string.format("  ...and %d more; name any of them.", total - #listed))
    end
    player.print("[Crew] short names work too: furnace, chest, belt, pole, drill.")
    return
  end
  local parameters = {item = ITEM_NAMES[item] or item}
  if tonumber(count) then parameters.count = tonumber(count) end
  request_directive(player, "make", parameters)
end

local HELP =
{
  "/crew            -- where I am and what I am doing",
  "/crew come       -- spawn me if needed and follow you",
  "/crew stop       -- stand still and drop whatever directive I am on",
  "/crew take <item> [n]  -- hand me some of your items",
  "/crew give [item]      -- hand them back",
  "/crew do [directive]   -- list directives, or carry one out",
  "/crew mine <ore> [n]   -- go and hand-mine some ore",
  "/crew make [thing] [n] -- list what I can make, or make one",
}

local function run_command(command)
  local player = game.get_player(command.player_index)
  if not player then return end
  local parameter = command.parameter or ""
  local verb, rest = parameter:match("^(%S*)%s*(.*)$")

  if verb == "help" then
    for _, line in pairs(HELP) do player.print(line) end
    return
  end

  if verb == "come" then
    if not Body.get() then Body.ensure(player.force) end
    interface.follow({player = player.index})
    player.print("[Crew] on my way.")
    return
  end

  if verb == "stop" then
    Plan.cancel()
    Body.halt()
    player.print("[Crew] stopped.")
    return
  end

  if verb == "take" then return hand_over(player, rest) end
  if verb == "give" then return hand_back(player, rest) end
  if verb == "do" then return request_directive(player, rest) end
  if verb == "mine" then return request_mining(player, rest) end
  if verb == "make" then return request_making(player, rest) end

  local state = Senses.status()
  if state.body and state.body.missing then
    player.print("[Crew] no body in the world -- /crew come.")
    return
  end
  player.print(string.format("[Crew] %s at %.0f,%.0f, %s.",
    state.body.surface, state.body.position.x, state.body.position.y, state.body.doing))
  local plan = Plan.status()
  if plan.state and plan.state ~= "idle" then
    player.print(string.format("[Crew] directive %s: %s, step %d of %d%s",
      plan.name, plan.state, plan.step or 0, plan.steps or 0,
      plan.error and (" -- " .. plan.error) or ""))
  end
end

-- Two names for the same thing: /agent is what it is, /crew is what the fingers
-- already know.
commands.add_command("crew", "Crew: /crew help for what it understands.", run_command)
commands.add_command("agent", "Crew, under its other name.", run_command)

script.on_init(function()
  storage.crew = {}
end)

-- A body that outlives a save/load is the whole point, but a save made before
-- the mod was added will not have one yet.
-- A sign saying "mining coal 28/100" outlives the directive that drew it if the
-- server stops mid-job, and then hangs over him forever afterwards.
local function tidy_up()
  storage.crew = storage.crew or {}
  Body.relabel() -- picks up a rename, among anything else that changed
  local plan = Plan.status()
  if plan.state ~= "running" then Body.sign(nil) end
end

script.on_configuration_changed(tidy_up)

-- Deliberately NOT script.on_load: registering an event handler there leaves the
-- client with a different set of registrations than the save recorded, and
-- Factorio refuses the join with a script-event-mismatch. The tidying happens on
-- the first tick of the handler that is always registered instead -- see plan.lua.
Plan.on_first_tick(tidy_up)

return interface
