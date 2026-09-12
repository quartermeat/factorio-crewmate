-- The seam the bridge talks to. Every call returns a JSON string, because RCON
-- hands back exactly what rcon.print writes and nothing more.

local Body = require("script.body")
local Senses = require("script.senses")
local Hands = require("script.hands")
local Plan = require("script.plan")

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
    local surface = body and body.surface or game.surfaces.nauvis
    local centre = argument.position or (body and body.position) or {x = 0, y = 0}
    local radius = math.min(argument.radius or 48, 128)
    local force = game.forces.player

    local spots = {}
    for x = centre.x - radius, centre.x + radius, 1 do
      for y = centre.y - radius, centre.y + radius, 1 do
        for _, direction in pairs({defines.direction.north, defines.direction.east,
                                   defines.direction.south, defines.direction.west}) do
          if #spots < (argument.limit or 8) and surface.can_place_entity
          {
            name = "offshore-pump", position = {x = x, y = y}, direction = direction,
            force = force, build_check_type = defines.build_check_type.manual,
          } then
            -- can_place_entity answers for the snapped position, not the one it
            -- was asked about: a pump sits on half tiles. Put a ghost down to
            -- find out where the game actually means, then take it away again.
            local ghost = surface.create_entity
            {
              name = "entity-ghost", inner_name = "offshore-pump",
              position = {x = x, y = y}, direction = direction, force = force,
            }
            if ghost then
              spots[#spots + 1] = {position = {x = ghost.position.x, y = ghost.position.y}, direction = direction}
              ghost.destroy()
            end
          end
        end
      end
    end
    return ok({spots = spots, searched = centre, radius = radius})
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
commands.add_command("crew", "Crewmate status, or /crew come to call it over.", function(command)
  local player = game.get_player(command.player_index)
  if not player then return end
  if command.parameter == "come" then
    if not Body.get() then Body.ensure(player.force) end
    interface.follow({player = player.index})
    player.print("[Crewmate] on my way.")
    return
  end
  local state = Senses.status()
  player.print(state.body and state.body.missing and "[Crewmate] no body in the world."
    or string.format("[Crewmate] %s at %.0f,%.0f, %s.",
      state.body.surface, state.body.position.x, state.body.position.y, state.body.doing))
end)

script.on_init(function()
  storage.crew = {}
end)

-- A body that outlives a save/load is the whole point, but a save made before
-- the mod was added will not have one yet.
script.on_configuration_changed(function()
  storage.crew = storage.crew or {}
end)

return interface
