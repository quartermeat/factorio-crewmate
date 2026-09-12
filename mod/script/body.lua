-- The body: a character entity with no player attached. It walks, it can be
-- hurt, and it dies like anyone else's character -- the only difference is that
-- its intentions arrive over RCON instead of from a keyboard.

local Body = {}

local NAME = "Claude"
local COLOR = {r = 0.85, g = 0.55, b = 0.30}
local ARRIVAL = 1.5      -- tiles; close enough to call it arrived
local FOLLOW_GAP = 4     -- tiles; how far behind a player it trails
local STUCK_TICKS = 90   -- no progress for this long means try another way
local RESPAWN_DELAY = 60 * 10

local function crew()
  storage.crew = storage.crew or {}
  return storage.crew
end

local function label(body)
  local state = crew()
  if state.label and rendering.get_object_by_id(state.label) then
    rendering.get_object_by_id(state.label).destroy()
  end
  local object = rendering.draw_text
  {
    text = NAME,
    surface = body.surface,
    target = {entity = body, offset = {0, -2.4}},
    color = COLOR,
    scale = 1.2,
    alignment = "center",
    scale_with_zoom = false,
  }
  state.label = object.id
end

function Body.get()
  local state = crew()
  if state.body and state.body.valid then return state.body end
  return nil
end

function Body.spawn(surface, position, force)
  local state = crew()
  if state.body and state.body.valid then state.body.destroy() end

  local spot = surface.find_non_colliding_position("character", position, 32, 0.5) or position
  local body = surface.create_entity{name = "character", position = spot, force = force}
  if not body then return nil, "no room to spawn a character there" end

  body.color = COLOR
  state.body = body
  state.goal = nil
  state.follow = nil
  state.stuck_since = nil
  state.last_position = body.position
  label(body)
  return body
end

function Body.ensure(force)
  local body = Body.get()
  if body then return body end
  local surface = game.surfaces.nauvis
  local position = {x = 0, y = 0}
  for _, player in pairs(game.connected_players) do
    if player.character then
      surface, position = player.surface, player.position
      break
    end
  end
  return Body.spawn(surface, position, force or game.forces.player)
end

function Body.walk_to(position)
  local state = crew()
  state.goal = {x = position.x, y = position.y}
  state.follow = nil
  state.stuck_since = nil
end

function Body.follow(player)
  local state = crew()
  state.follow = player and player.index or nil
  state.goal = nil
  state.stuck_since = nil
end

function Body.halt()
  local state = crew()
  state.goal = nil
  state.follow = nil
  local body = Body.get()
  if body then body.walking_state = {walking = false} end
end

-- Eight-way steering. Good enough to cross a base; it is not a path finder, so
-- the stuck check below is what gets it around a wall.
local DIRECTIONS =
{
  {dx =  0, dy = -1, direction = defines.direction.north},
  {dx =  1, dy = -1, direction = defines.direction.northeast},
  {dx =  1, dy =  0, direction = defines.direction.east},
  {dx =  1, dy =  1, direction = defines.direction.southeast},
  {dx =  0, dy =  1, direction = defines.direction.south},
  {dx = -1, dy =  1, direction = defines.direction.southwest},
  {dx = -1, dy =  0, direction = defines.direction.west},
  {dx = -1, dy = -1, direction = defines.direction.northwest},
}

local function heading(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  local best, best_dot = DIRECTIONS[1], -math.huge
  local length = math.sqrt(dx * dx + dy * dy)
  if length == 0 then return best.direction end
  for _, candidate in pairs(DIRECTIONS) do
    local dot = (dx / length) * candidate.dx + (dy / length) * candidate.dy
    if dot > best_dot then best, best_dot = candidate, dot end
  end
  return best.direction
end

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function target_of(state)
  if state.follow then
    local player = game.get_player(state.follow)
    if player and player.connected and player.character then
      return player.position, FOLLOW_GAP, player.surface
    end
    state.follow = nil
    return nil
  end
  if state.goal then return state.goal, ARRIVAL end
  return nil
end

local function step(state, body)
  local target, gap, surface = target_of(state)
  if not target then
    body.walking_state = {walking = false}
    return
  end
  if surface and surface ~= body.surface then
    body.walking_state = {walking = false}
    return
  end
  if distance(body.position, target) <= gap then
    body.walking_state = {walking = false}
    state.goal = nil
    state.stuck_since = nil
    return
  end

  local direction = heading(body.position, target)
  -- Sidestep when pinned against something: rotate the heading rather than
  -- grinding into the obstacle forever.
  if state.stuck_since and game.tick - state.stuck_since > STUCK_TICKS then
    direction = (direction + 2) % 16
    state.stuck_since = game.tick
  end
  body.walking_state = {walking = true, direction = direction}

  if state.last_position and distance(body.position, state.last_position) < 0.05 then
    state.stuck_since = state.stuck_since or game.tick
  else
    state.stuck_since = nil
  end
  state.last_position = {x = body.position.x, y = body.position.y}
end

script.on_event(defines.events.on_tick, function()
  local state = crew()
  local body = Body.get()
  if body then
    step(state, body)
  elseif state.respawn_at and game.tick >= state.respawn_at then
    state.respawn_at = nil
    local body, err = Body.ensure()
    game.print(body and ("[" .. NAME .. "] back on my feet.") or ("[" .. NAME .. "] cannot respawn: " .. err))
  end
end)

script.on_event(defines.events.on_entity_died, function(event)
  local state = crew()
  if state.body and event.entity == state.body then
    state.body = nil
    state.respawn_at = game.tick + RESPAWN_DELAY
    game.print("[" .. NAME .. "] I died. Back in ten seconds.")
  end
end, {{filter = "name", name = "character"}})

Body.NAME = NAME
Body.COLOR = COLOR
return Body
