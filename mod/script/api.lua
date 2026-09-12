-- The seam the bridge talks to. Every call returns a JSON string, because RCON
-- hands back exactly what rcon.print writes and nothing more.

local Body = require("script.body")
local Senses = require("script.senses")

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
