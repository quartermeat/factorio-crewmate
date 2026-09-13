-- Senses: everything the crewmate can report about the world, shaped into
-- plain tables that the bridge turns into JSON.

local Body = require("script.body")

local Senses = {}

local CHAT_HISTORY = 50
local LOOK_LIMIT = 60
local STATUS_SAMPLE = 2000

local PROBLEM_STATUSES =
{
  no_power = true,
  low_power = true,
  no_fuel = true,
  no_ingredients = true,
  item_ingredient_shortage = true,
  fluid_ingredient_shortage = true,
  full_output = true,
  no_minable_resources = true,
  missing_required_fluid = true,
  missing_science_packs = true,
  no_ammo = true,
  not_connected_to_rail = true,
  frozen = true,
}

local status_names = {}
for name, value in pairs(defines.entity_status) do status_names[value] = name end

local function crew()
  storage.crew = storage.crew or {}
  return storage.crew
end

function Senses.remember_chat(player_name, message)
  local state = crew()
  state.chat = state.chat or {}
  table.insert(state.chat, {tick = game.tick, who = player_name, message = message})
  while #state.chat > CHAT_HISTORY do table.remove(state.chat, 1) end
end

-- Chat is drained rather than read: each call returns what has been said since
-- the last one, so the agent is not re-reading old lines every poll.
function Senses.hear()
  local state = crew()
  local heard = state.chat or {}
  state.chat = {}
  return {tick = game.tick, heard = heard}
end

local function inventory_of(entity)
  local contents = {}
  local inventory = entity.get_main_inventory()
  if not inventory then return contents end
  for _, item in pairs(inventory.get_contents()) do
    contents[#contents + 1] = {name = item.name, count = item.count, quality = item.quality}
  end
  return contents
end

local function top_flows(counts, limit)
  local items = {}
  for name, count in pairs(counts) do
    items[#items + 1] = {name = name, count = count}
  end
  table.sort(items, function(a, b) return a.count > b.count end)
  local top = {}
  for index = 1, math.min(limit, #items) do top[index] = items[index] end
  return top
end

-- Machine trouble, counted directly off entity status rather than off player
-- alerts, so it works on a server with nobody logged in.
local function troubles(surface, force)
  local machines = surface.find_entities_filtered
  {
    type = {"assembling-machine", "furnace", "mining-drill", "lab", "ammo-turret", "boiler", "reactor"},
    force = force,
    limit = STATUS_SAMPLE,
  }
  local tally, total = {}, 0
  for _, machine in pairs(machines) do
    local status = status_names[machine.status]
    if status and PROBLEM_STATUSES[status] then
      tally[status] = (tally[status] or 0) + 1
      total = total + 1
    end
  end
  local problems = {}
  for status, count in pairs(tally) do problems[#problems + 1] = {status = status, count = count} end
  table.sort(problems, function(a, b) return a.count > b.count end)
  return {sampled = #machines, affected = total, problems = problems}
end

function Senses.status()
  local force = game.forces.player
  local body = Body.get()
  local surface = body and body.surface or game.surfaces.nauvis

  local players = {}
  for _, player in pairs(game.connected_players) do
    players[#players + 1] =
    {
      name = player.name,
      surface = player.surface.name,
      position = player.position,
      health = player.character and player.character.health or nil,
    }
  end

  local research = nil
  if force.current_research then
    research =
    {
      name = force.current_research.name,
      progress = math.floor(force.research_progress * 1000) / 10,
      queued = #force.research_queue,
    }
  end

  local items = force.get_item_production_statistics(surface)
  local state = crew()

  return
  {
    tick = game.tick,
    body = body and
    {
      surface = body.surface.name,
      position = body.position,
      health = body.health,
      max_health = body.max_health,
      sign = Body.showing(),
      walking = body.walking_state and body.walking_state.walking or false,
      doing = state.follow and ("following " .. (game.get_player(state.follow) and game.get_player(state.follow).name or "?"))
              or state.goal and string.format("walking to %.0f,%.0f", state.goal.x, state.goal.y)
              or "idle",
      inventory = inventory_of(body),
    } or {missing = true, respawn_in = state.respawn_at and (state.respawn_at - game.tick) or nil},
    players = players,
    research = research,
    pollution = math.floor(surface.get_total_pollution()),
    produced_last_minute = top_flows(items.output_counts, 12),
    consumed_last_minute = top_flows(items.input_counts, 12),
    machines = troubles(surface, force),
    platforms = (function()
      local list = {}
      for _, platform in pairs(force.platforms or {}) do
        if platform.valid then
          list[#list + 1] =
          {
            name = platform.name,
            location = platform.space_location and platform.space_location.name or "in transit",
            speed = math.floor((platform.speed or 0) * 100) / 100,
          }
        end
      end
      return list
    end)(),
  }
end

-- Looking around: what is actually near the body, as counts plus the closest
-- handful of each interesting thing.
function Senses.look(radius)
  local body = Body.get()
  if not body then return {error = "no body in the world"} end
  radius = math.min(radius or 32, 128)

  local surface = body.surface
  local found = surface.find_entities_filtered{position = body.position, radius = radius}
  local counts, notable = {}, {}
  for _, entity in pairs(found) do
    if entity ~= body and entity.name ~= "character-corpse" then
      counts[entity.name] = (counts[entity.name] or 0) + 1
      if #notable < LOOK_LIMIT and entity.type ~= "simple-entity" and entity.type ~= "tree" then
        notable[#notable + 1] =
        {
          name = entity.name,
          type = entity.type,
          position = {x = math.floor(entity.position.x * 10) / 10, y = math.floor(entity.position.y * 10) / 10},
          status = entity.status and status_names[entity.status] or nil,
          health = entity.health and entity.max_health and entity.health < entity.max_health
                   and math.floor(entity.health) or nil,
        }
      end
    end
  end

  local summary = {}
  for name, count in pairs(counts) do summary[#summary + 1] = {name = name, count = count} end
  table.sort(summary, function(a, b) return a.count > b.count end)

  local resources = {}
  for _, patch in pairs(surface.find_entities_filtered{position = body.position, radius = radius, type = "resource"}) do
    resources[patch.name] = (resources[patch.name] or 0) + patch.amount
  end

  return
  {
    from = body.position,
    radius = radius,
    counts = summary,
    notable = notable,
    resources = resources,
  }
end

-- A real screenshot has to be rendered by a graphical client: a headless server
-- has no renderer, so this asks a connected player's game to take it.
function Senses.screenshot(options)
  options = options or {}
  local body = Body.get()
  local player = game.get_player(options.player or 1)
  if not player or not player.connected then
    return {error = "no connected player to render the shot; a graphical client must be joined"}
  end
  local position = options.position or (body and body.position) or player.position
  local path = options.path or "crewmate/view.png"
  game.take_screenshot
  {
    by_player = player,
    surface = body and body.surface or player.surface,
    position = position,
    resolution = {options.width or 1280, options.height or 720},
    zoom = options.zoom or 0.6,
    show_entity_info = true,
    show_gui = false,
    hide_clouds = true,
    path = path,
  }
  return {rendered_by = player.name, position = position, path = "script-output/" .. path}
end

script.on_event(defines.events.on_console_chat, function(event)
  local player = event.player_index and game.get_player(event.player_index)
  Senses.remember_chat(player and player.name or "server", event.message)
end)

return Senses
