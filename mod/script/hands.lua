-- Hands: the only way the companion changes the world. Everything here is bound
-- by the same two rules a player is -- it must be standing close enough, and it
-- must be carrying the item -- so a directive that cannot be honestly carried
-- out fails with a reason instead of conjuring the result.

local Body = require("script.body")

local Hands = {}

local DIRECTIONS =
{
  north = defines.direction.north,
  northeast = defines.direction.northeast,
  east = defines.direction.east,
  southeast = defines.direction.southeast,
  south = defines.direction.south,
  southwest = defines.direction.southwest,
  west = defines.direction.west,
  northwest = defines.direction.northwest,
}

function Hands.direction(name)
  if name == nil then return defines.direction.north end
  return DIRECTIONS[name] or defines.direction.north
end

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Build range, not an arbitrary constant: whatever this character could reach if
-- a person were holding it.
function Hands.within_reach(body, position)
  return distance(body.position, position) <= body.build_distance
end

function Hands.item_for(entity_name)
  local prototype = prototypes.entity[entity_name]
  if not prototype then return nil, "no such entity: " .. tostring(entity_name) end
  local items = prototype.items_to_place_this
  if not items or #items == 0 then return nil, entity_name .. " is not something you can place" end
  return items[1].name
end

function Hands.carrying(body, item)
  local inventory = body.get_main_inventory()
  if not inventory then return 0 end
  return inventory.get_item_count(item)
end

function Hands.place(body, argument)
  local position = {x = argument.x, y = argument.y}
  local direction = Hands.direction(argument.direction)

  local item, err = Hands.item_for(argument.entity)
  if not item then return nil, err end
  if Hands.carrying(body, item) < 1 then
    return nil, string.format("I have no %s", item)
  end
  if not Hands.within_reach(body, position) then
    return nil, "out of reach"
  end

  local surface = body.surface
  local existing = surface.find_entities_filtered
  {
    name = argument.entity,
    position = position,
    radius = 0.5,
  }[1]
  if existing then return existing end

  if not surface.can_place_entity
  {
    name = argument.entity,
    position = position,
    direction = direction,
    force = body.force,
    build_check_type = defines.build_check_type.manual,
  } then
    return nil, string.format("cannot place %s at %.1f,%.1f -- something is in the way",
      argument.entity, position.x, position.y)
  end

  local built = surface.create_entity
  {
    name = argument.entity,
    position = position,
    direction = direction,
    force = body.force,
    raise_built = true,
  }
  if not built then return nil, "the game refused to place " .. argument.entity end

  body.get_main_inventory().remove{name = item, count = 1}
  return built
end

function Hands.insert(body, argument)
  local position = {x = argument.x, y = argument.y}
  if not Hands.within_reach(body, position) then return nil, "out of reach" end

  local target = body.surface.find_entities_filtered{position = position, radius = 1.5, force = body.force}[1]
  if not target then
    return nil, string.format("nothing at %.1f,%.1f to put %s into", position.x, position.y, argument.item)
  end

  local carried = Hands.carrying(body, argument.item)
  if carried < 1 then return nil, string.format("I have no %s", argument.item) end

  local wanted = math.min(argument.count or carried, carried)
  local moved = target.insert{name = argument.item, count = wanted}
  if moved == 0 then
    return nil, string.format("%s will not take %s", target.name, argument.item)
  end
  body.get_main_inventory().remove{name = argument.item, count = moved}
  return target, nil, moved
end

-- Wires two poles together. Copper wire between poles is free in the sense that
-- the game does not charge for it either.
function Hands.connect(body, argument)
  local first = body.surface.find_entities_filtered
  {
    position = {x = argument.from_x, y = argument.from_y}, radius = 1.5, force = body.force,
  }[1]
  local second = body.surface.find_entities_filtered
  {
    position = {x = argument.to_x, y = argument.to_y}, radius = 1.5, force = body.force,
  }[1]
  if not (first and second) then return nil, "one of the two things to connect is not there" end

  local source = first.get_wire_connector(defines.wire_connector_id.pole_copper, true)
  local target = second.get_wire_connector(defines.wire_connector_id.pole_copper, true)
  if not (source and target) then return nil, "those are not both power poles" end
  if not source.connect_to(target, false, defines.wire_origin.player) then
    return nil, "too far apart to wire together"
  end
  return first
end

-- Stamping a blueprint gives the layout the game's own geometry -- fluid boxes
-- line up, rotations are right -- and leaves ghosts, which the body then has to
-- walk over and build one at a time out of its own pockets.
function Hands.stamp(body, argument)
  local ghosts = body.surface.create_entities_from_blueprint_string
  {
    string = argument.blueprint,
    position = {x = argument.x, y = argument.y},
    force = body.force,
    direction = Hands.direction(argument.direction),
  }
  if not ghosts or #ghosts == 0 then
    return nil, "that blueprint placed nothing here -- the ground may be unsuitable"
  end

  local needed = {}
  for _, ghost in pairs(ghosts) do
    if ghost.valid and ghost.name == "entity-ghost" then
      local item = Hands.item_for(ghost.ghost_name)
      if item then needed[item] = (needed[item] or 0) + 1 end
    end
  end

  local shopping = {}
  for item, count in pairs(needed) do
    shopping[#shopping + 1] = {name = item, count = count}
  end
  return {ghosts = #ghosts, needs = shopping}
end

-- Put a blueprint down so that one named entity in it lands exactly on a chosen
-- spot, facing a chosen way -- the offshore pump on the shore we found, say.
--
-- Importing the string into a temporary blueprint gives the entity positions the
-- game itself will use, relative to the blueprint's centre, so the stamp position
-- is arithmetic rather than guesswork. Trial stamping does not work here: at the
-- wrong offset the pump has no shore and never appears as a ghost at all.
local function blueprint_entities(blueprint)
  local inventory = game.create_inventory(1)
  inventory[1].set_stack{name = "blueprint"}
  if inventory[1].import_stack(blueprint) ~= 0 then
    inventory.destroy()
    return nil, "that blueprint string will not import"
  end
  local entities = inventory[1].get_blueprint_entities()
  inventory.destroy()
  return entities
end

local function rotate(offset, rotation)
  if rotation == defines.direction.east then return {x = -offset.y, y = offset.x} end
  if rotation == defines.direction.south then return {x = -offset.x, y = -offset.y} end
  if rotation == defines.direction.west then return {x = offset.y, y = -offset.x} end
  return {x = offset.x, y = offset.y}
end

local function unrotate(offset, rotation)
  return rotate(offset, (16 - rotation) % 16)
end

-- Ghosts are placed one at a time rather than by stamping the string: the
-- surface method that stamps a blueprint only works in menu simulations, and it
-- hands back nothing to check. Doing it by hand also removes the question of
-- where the game would have centred the blueprint -- every entity is positioned
-- relative to the anchor entity, which goes exactly where it was asked to.
function Hands.stamp_aligned(body, argument)
  local surface = body.surface
  local wanted = {x = argument.x, y = argument.y}
  local facing = Hands.direction(argument.direction)

  local entities, err = blueprint_entities(argument.blueprint)
  if not entities then return nil, err end

  local anchor
  for _, entity in pairs(entities) do
    if entity.name == argument.entity then anchor = entity break end
  end
  if not anchor then
    return nil, string.format("this blueprint has no %s to line up on", tostring(argument.entity))
  end

  local rotation = (facing - (anchor.direction or defines.direction.north)) % 16
  if rotation % 4 ~= 0 then rotation = defines.direction.north end

  local planned = {}
  for _, entity in pairs(entities) do
    local offset = rotate(
      {x = entity.position.x - anchor.position.x, y = entity.position.y - anchor.position.y},
      rotation)
    planned[#planned + 1] =
    {
      name = entity.name,
      position = {x = wanted.x + offset.x, y = wanted.y + offset.y},
      direction = ((entity.direction or defines.direction.north) + rotation) % 16,
    }
  end

  -- Check the whole layout before committing to any of it, so a shore that only
  -- half fits leaves nothing behind to tidy up.
  for _, entry in pairs(planned) do
    if not surface.can_place_entity
    {
      name = entry.name, position = entry.position, direction = entry.direction,
      force = body.force, build_check_type = defines.build_check_type.manual,
    } then
      return nil, string.format("%s does not fit at %.1f,%.1f", entry.name, entry.position.x, entry.position.y)
    end
  end

  local ghosts = {}
  for _, entry in pairs(planned) do
    local ghost = surface.create_entity
    {
      name = "entity-ghost", inner_name = entry.name, position = entry.position,
      direction = entry.direction, force = body.force,
    }
    if not ghost then
      for _, placed in pairs(ghosts) do
        if placed.valid then placed.destroy() end
      end
      return nil, "could not put down a ghost for " .. entry.name
    end
    ghosts[#ghosts + 1] = ghost
  end
  return Hands.shopping_list(ghosts)
end

-- What a blueprint would cost, read straight out of the blueprint: no ghosts, no
-- side effects, so it is safe to ask before committing to anything.
function Hands.blueprint_cost(blueprint)
  local entities, err = blueprint_entities(blueprint)
  if not entities then return nil, err end
  local needed = {}
  for _, entity in pairs(entities) do
    local item = Hands.item_for(entity.name)
    if item then needed[item] = (needed[item] or 0) + 1 end
  end
  local list = {}
  for item, count in pairs(needed) do list[#list + 1] = {name = item, count = count} end
  return list
end

function Hands.shopping_list(ghosts)
  local needed, count = {}, 0
  for _, ghost in pairs(ghosts) do
    if ghost.valid and ghost.name == "entity-ghost" then
      count = count + 1
      local item = Hands.item_for(ghost.ghost_name)
      if item then needed[item] = (needed[item] or 0) + 1 end
    end
  end
  local list = {}
  for item, wanted in pairs(needed) do list[#list + 1] = {name = item, count = wanted} end
  return {ghosts = count, needs = list}
end

-- Build the nearest ghost that is in reach. Returns the ghost's name on success,
-- nil plus a reason when it cannot, and false when there is nothing left to do.
function Hands.ghost_key(ghost)
  return string.format("%.1f,%.1f", ghost.position.x, ghost.position.y)
end

-- Build the far end of a site first. Nearest-first walls the body in behind the
-- machines it has just built -- a row of steam engines is as solid as a fence --
-- and it ends up unable to reach the last few ghosts.
function Hands.build_nearest_ghost(body, area, skip, away_from)
  local ghosts = body.surface.find_entities_filtered
  {
    name = "entity-ghost",
    force = body.force,
    area = area,
  }
  if #ghosts == 0 then return false end

  local closest, best
  for _, ghost in pairs(ghosts) do
    if not (skip and skip[Hands.ghost_key(ghost)]) then
      -- Rank by distance from the anchor when there is one, so the site is built
      -- from its far end back; otherwise just take the nearest.
      local rank
      if away_from then
        rank = -distance(away_from, ghost.position)
      else
        rank = distance(body.position, ghost.position)
      end
      if not best or rank < best then
        closest, best = ghost, rank
      end
    end
  end
  if not closest then return false, "unreachable", #ghosts end

  if not Hands.within_reach(body, closest.position) then
    return nil, "walking", closest.position
  end

  local name = closest.ghost_name
  local item = Hands.item_for(name)
  if not item then return nil, "cannot build a " .. tostring(name) end
  if Hands.carrying(body, item) < 1 then return nil, "I have no " .. item end

  local _, built = closest.revive{raise_revive = true}
  if not built then return nil, "the game refused to build the " .. name end
  body.get_main_inventory().remove{name = item, count = 1}
  return name
end

-- What the body is carrying, as a directive's shopping list would describe it.
function Hands.missing(body, required)
  local short = {}
  for _, entry in pairs(required) do
    local carried = Hands.carrying(body, entry.name)
    if carried < entry.count then
      short[#short + 1] = {name = entry.name, need = entry.count, have = carried}
    end
  end
  return short
end

return Hands
