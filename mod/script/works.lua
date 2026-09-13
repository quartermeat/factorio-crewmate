-- The parts of a directive that no blueprint can hold still for: where the coal
-- is, how many drills fit on it, and how long the belt and pole runs have to be
-- to join two things the map put wherever it liked.
--
-- Everything here only marks out ghosts. Building them is still the body's job,
-- item by item, which is what keeps the result honest.

local Hands = require("script.hands")

local Works = {}

local function tile_centre(value)
  return math.floor(value) + 0.5
end

-- can_place_entity ignores ghosts, so two steps marking out work in the same
-- place both succeed and then whichever gets built first blocks the other. Check
-- the footprint for existing ghosts as well.
local function footprint(name, position, direction)
  local prototype = prototypes.entity[name]
  local width, height = 1, 1
  if prototype then width, height = prototype.tile_width, prototype.tile_height end
  if direction == defines.direction.east or direction == defines.direction.west then
    width, height = height, width
  end
  return
  {
    {position.x - width / 2 + 0.01, position.y - height / 2 + 0.01},
    {position.x + width / 2 - 0.01, position.y + height / 2 - 0.01},
  }
end

local function ghost(surface, force, name, position, direction)
  direction = direction or defines.direction.north
  if not surface.can_place_entity
  {
    name = name, position = position, direction = direction,
    force = force, build_check_type = defines.build_check_type.manual,
  } then
    return nil
  end
  if surface.count_entities_filtered{name = "entity-ghost", area = footprint(name, position, direction)} > 0 then
    return nil
  end
  return surface.create_entity
  {
    name = "entity-ghost", inner_name = name, position = position,
    direction = direction or defines.direction.north, force = force,
  }
end

-- The nearest patch of something. Searched in widening rings rather than one big
-- sweep: find_entities_filtered with a limit returns whatever it comes across
-- first, not the closest, so a wide search can walk straight past the patch you
-- are standing on.
-- `what` is a prototype name for ore, or a type such as "tree" when the thing
-- being looked for comes in a hundred different named varieties.
function Works.find_resource(body, what, radius, kind)
  local surface = body.surface
  local reach = radius or 128
  local found

  local rings = {8, 16, 32, 64, 128, 192, 256, 384, 512}
  for _, ring in pairs(rings) do
    if ring <= reach then
      local filter = {position = body.position, radius = ring}
      if kind == "type" then filter.type = what else filter.name = what end
      local candidates = surface.find_entities_filtered(filter)
      if #candidates > 0 then
        found = candidates
        break
      end
    end
  end
  -- One last look at exactly the distance asked for, so an odd reach is not
  -- rounded down to the ring below it.
  if not found then
    local filter = {position = body.position, radius = reach}
    if kind == "type" then filter.type = what else filter.name = what end
    local candidates = surface.find_entities_filtered(filter)
    if #candidates > 0 then found = candidates end
  end

  if not found then
    -- Say what is actually out there. Nothing within reach usually means the map
    -- beyond it has never been generated, and no amount of searching finds ore in
    -- chunks that do not exist yet.
    local wider = {position = body.position, radius = 1000}
    if kind == "type" then wider.type = what else wider.name = what end
    local distant = surface.find_entities_filtered(wider)
    if #distant > 0 then
      local nearest
      for _, entity in pairs(distant) do
        local dx, dy = entity.position.x - body.position.x, entity.position.y - body.position.y
        local gap = math.sqrt(dx * dx + dy * dy)
        if not nearest or gap < nearest then nearest = gap end
      end
      return nil, string.format("no %s within %d tiles; the nearest I can see is %.0f tiles away -- ask for a bigger reach",
        what, reach, nearest)
    end
    return nil, string.format("no %s within %d tiles, and none anywhere I have seen -- the map that way may not be explored yet",
      what, reach)
  end

  local nearest, nearest_gap
  for _, entity in pairs(found) do
    local dx, dy = entity.position.x - body.position.x, entity.position.y - body.position.y
    local gap = dx * dx + dy * dy
    if not nearest_gap or gap < nearest_gap then nearest, nearest_gap = entity, gap end
  end

  -- The centre of the patch is worth knowing for laying drills across it; for
  -- walking over and digging, the near edge is the sensible destination.
  local patch = surface.find_entities_filtered
  {
    position = nearest.position, radius = 24,
    name = kind ~= "type" and what or nil,
    type = kind == "type" and what or nil,
  }
  local sum_x, sum_y = 0, 0
  for _, entity in pairs(patch) do
    sum_x, sum_y = sum_x + entity.position.x, sum_y + entity.position.y
  end

  return
  {
    position = {x = nearest.position.x, y = nearest.position.y},
    centre = {x = math.floor(sum_x / #patch) + 0.5, y = math.floor(sum_y / #patch) + 0.5},
    tiles = #patch,
    distance = math.sqrt(nearest_gap),
  }
end

-- The nearest thing worth swinging at, ignoring any the agent has already given
-- up on reaching. Rings again, so a big patch does not mean scanning thousands
-- of tiles every time.
function Works.nearest_minable(body, what, kind, radius, skip)
  local surface = body.surface
  for _, ring in pairs({8, 16, 32, 64, 128, 192, 256}) do
    if ring <= (radius or 128) + 32 then
      local filter = {position = body.position, radius = math.min(ring, radius or 128)}
      if kind == "type" then filter.type = what else filter.name = what end
      local best, best_gap
      for _, candidate in pairs(surface.find_entities_filtered(filter)) do
        local key = string.format("%.1f,%.1f", candidate.position.x, candidate.position.y)
        if not (skip and skip[key]) then
          local dx, dy = candidate.position.x - body.position.x, candidate.position.y - body.position.y
          local gap = dx * dx + dy * dy
          if not best_gap or gap < best_gap then best, best_gap = candidate, gap end
        end
      end
      if best then return best end
    end
  end
end

local function ore_under(surface, name, centre)
  return surface.count_entities_filtered
  {
    name = name,
    area = {{centre.x - 1.5, centre.y - 1.5}, {centre.x + 1.5, centre.y + 1.5}},
  }
end

-- Somewhere an offshore pump would actually go, nearest first. The ghost probe is
-- there because can_place_entity answers for the snapped position rather than the
-- one it was asked about, and a pump sits on half tiles.
function Works.pump_spots(body, centre, radius, limit)
  local surface, force = body.surface, body.force
  radius = math.min(radius or 64, 160)
  limit = limit or 8
  local spots = {}
  for ring = 1, radius do
    for x = centre.x - ring, centre.x + ring do
      for y = centre.y - ring, centre.y + ring do
        if math.abs(x - centre.x) == ring or math.abs(y - centre.y) == ring then
          for _, direction in pairs({defines.direction.north, defines.direction.east,
                                     defines.direction.south, defines.direction.west}) do
            if #spots < limit and surface.can_place_entity
            {
              name = "offshore-pump", position = {x = x, y = y}, direction = direction,
              force = force, build_check_type = defines.build_check_type.manual,
            } then
              local probe = surface.create_entity
              {
                name = "entity-ghost", inner_name = "offshore-pump",
                position = {x = x, y = y}, direction = direction, force = force,
              }
              if probe then
                spots[#spots + 1] =
                {
                  position = {x = probe.position.x, y = probe.position.y},
                  direction = direction,
                }
                probe.destroy()
              end
            end
          end
        end
      end
    end
    if #spots >= limit then break end
  end
  return spots
end

-- A row of drills facing north, with a clear lane above them for the belt their
-- output drops onto. The row is slid around the patch to find the line with the
-- most ore under it.
function Works.drill_row(body, argument)
  local surface, force = body.surface, body.force
  local drill = argument.drill or "electric-mining-drill"
  local resource = argument.resource or "coal"
  local wanted = argument.count or 4
  local patch = argument.patch

  local best
  for dy = -8, 8 do
    local y = tile_centre(patch.y) + dy
    for shift = -6, 6 do
      local row = {}
      for index = 0, wanted - 1 do
        local x = tile_centre(patch.x) + shift + index * 3
        local centre = {x = x, y = y}
        if ore_under(surface, resource, centre) >= 5
          and surface.can_place_entity
          {
            name = drill, position = centre, direction = defines.direction.north,
            force = force, build_check_type = defines.build_check_type.manual,
          }
          and surface.can_place_entity
          {
            name = "transport-belt", position = {x = x, y = y - 2}, force = force,
            build_check_type = defines.build_check_type.manual,
          }
        then
          row[#row + 1] = centre
        else
          break -- the row has to be unbroken for one belt to serve it
        end
      end
      if #row > (best and #best or 0) then best = row end
    end
  end

  if not best or #best == 0 then
    return nil, string.format("no room for a drill on that %s patch", resource)
  end

  local ghosts = {}
  for _, centre in pairs(best) do
    local placed = ghost(surface, force, drill, centre, defines.direction.north)
    if placed then ghosts[#ghosts + 1] = placed end
  end

  -- Poles under the row, on the side away from the belt, so every drill is inside
  -- somebody's supply area rather than only the one nearest the pole run.
  local poles = {}
  for index, centre in pairs(best) do
    if index == 1 or index % 2 == 1 or index == #best then
      local spot = {x = centre.x, y = centre.y + 2}
      if ghost(surface, force, argument.pole or "medium-electric-pole", spot) then
        poles[#poles + 1] = spot
      end
    end
  end

  local first, last = best[1], best[#best]
  return
  {
    drills = #ghosts,
    poles = poles,
    lane = {
      from = {x = first.x, y = first.y - 2},
      to = {x = last.x, y = last.y - 2},
    },
  }
end

-- A belt from the drills' lane to something that burns what is on it, ending in
-- an inserter that faces the target. Two straight runs, never a diagonal.
function Works.belt_line(body, argument)
  local surface, force = body.surface, body.force
  local belt = argument.belt or "transport-belt"
  local target = argument.target
  if not (target and target.valid) then return nil, "nothing to belt towards" end

  local from = argument.from
  local limit = argument.limit or 80

  -- Approach the target from whichever side the belt is coming from.
  local box = target.bounding_box
  local sides =
  {
    {x = tile_centre(target.position.x), y = math.floor(box.left_top.y) - 0.5, direction = defines.direction.south},
    {x = tile_centre(target.position.x), y = math.floor(box.right_bottom.y) + 0.5, direction = defines.direction.north},
    {x = math.floor(box.left_top.x) - 0.5, y = tile_centre(target.position.y), direction = defines.direction.east},
    {x = math.floor(box.right_bottom.x) + 0.5, y = tile_centre(target.position.y), direction = defines.direction.west},
  }

  local inserter, feed
  for _, side in pairs(sides) do
    local behind =
    {
      x = side.x + (side.direction == defines.direction.east and -1 or side.direction == defines.direction.west and 1 or 0),
      y = side.y + (side.direction == defines.direction.south and -1 or side.direction == defines.direction.north and 1 or 0),
    }
    if not inserter and surface.can_place_entity
    {
      name = argument.inserter or "inserter", position = side, direction = side.direction,
      force = force, build_check_type = defines.build_check_type.manual,
    } then
      inserter = {position = side, direction = side.direction}
      feed = behind
    end
  end
  if not inserter then return nil, "nowhere to put an inserter against the " .. target.name end

  -- Run along x first, then along y, so the corner is a single turn.
  local path = {}
  local x, y = from.x, from.y
  local steps = 0
  while math.abs(x - feed.x) > 0.01 and steps < limit do
    local direction = x < feed.x and defines.direction.east or defines.direction.west
    path[#path + 1] = {position = {x = x, y = y}, direction = direction}
    x = x + (x < feed.x and 1 or -1)
    steps = steps + 1
  end
  while math.abs(y - feed.y) > 0.01 and steps < limit do
    local direction = y < feed.y and defines.direction.south or defines.direction.north
    path[#path + 1] = {position = {x = x, y = y}, direction = direction}
    y = y + (y < feed.y and 1 or -1)
    steps = steps + 1
  end
  if steps >= limit then
    return nil, string.format("that is more than %d tiles of belt away; too far to be worth it", limit)
  end
  path[#path + 1] = {position = {x = feed.x, y = feed.y}, direction = path[#path] and path[#path].direction or defines.direction.east}

  local ghosts = 0
  for _, entry in pairs(path) do
    if ghost(surface, force, belt, entry.position, entry.direction) then ghosts = ghosts + 1 end
  end
  if ghost(surface, force, argument.inserter or "inserter", inserter.position, inserter.direction) then
    ghosts = ghosts + 1
  end
  return {belts = ghosts, length = #path}
end

-- Poles close enough together to carry power the whole way.
function Works.pole_line(body, argument)
  local surface, force = body.surface, body.force
  local pole = argument.pole or "medium-electric-pole"
  local spacing = argument.spacing or 7
  local from, to = argument.from, argument.to

  local dx, dy = to.x - from.x, to.y - from.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length < 1 then return {poles = 0} end
  local steps = math.ceil(length / spacing)

  local placed, last_spot = 0, {x = from.x, y = from.y}
  for index = 1, steps do
    local at =
    {
      x = tile_centre(from.x + dx * index / steps),
      y = tile_centre(from.y + dy * index / steps),
    }
    -- Nudge around anything in the way rather than giving up on the run.
    local found = false
    for ring = 0, 3 do
      for dx = -ring, ring do
        for dy = -ring, ring do
          if not found and (math.abs(dx) == ring or math.abs(dy) == ring or ring == 0) then
            local spot = {x = at.x + dx, y = at.y + dy}
            local gap = math.sqrt((spot.x - last_spot.x) ^ 2 + (spot.y - last_spot.y) ^ 2)
            -- Wire reach for a medium pole is 9: a gap wider than that is a
            -- broken run, which is worse than a pole in a slightly odd place.
            if gap <= (argument.reach or 8)
              and surface.count_entities_filtered{name = pole, position = spot, radius = 1.5} == 0
              and ghost(surface, force, pole, spot) then
              placed = placed + 1
              last_spot = spot
              found = true
            end
          end
        end
      end
    end
  end
  return {poles = placed}
end

return Works
