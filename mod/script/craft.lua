-- Working backwards from a thing to the ground it comes out of.
--
-- Asked to make a stone furnace, the agent needs to know it wants five stone,
-- how much of that it is already carrying, and that the rest has to be dug up
-- first. The answer is not a decision made elsewhere: it is arithmetic over the
-- recipes the game already has.

local Hands = require("script.hands")

local Craft = {}

-- What the agent can get for itself, and how.
Craft.MINEABLE =
{
  ["iron-ore"] = {resource = "iron-ore"},
  ["copper-ore"] = {resource = "copper-ore"},
  coal = {resource = "coal"},
  stone = {resource = "stone"},
  wood = {resource = "tree", kind = "type"},
}

-- Only what a pair of hands can make: anything wanting a furnace or an
-- assembler is somebody else's problem, and saying so is more use than failing
-- halfway through.
local function hand_recipe(force, item)
  local recipe = force.recipes[item]
  if recipe and recipe.enabled and not recipe.hidden and recipe.category == "crafting" then
    return recipe
  end
  for _, candidate in pairs(force.recipes) do
    if candidate.enabled and not candidate.hidden and candidate.category == "crafting" then
      for _, product in pairs(candidate.products) do
        if product.name == item and (product.amount or 1) > 0 then return candidate end
      end
    end
  end
end

local function product_count(recipe, item)
  for _, product in pairs(recipe.products) do
    if product.name == item then
      return product.amount or ((product.amount_min or 1) + (product.amount_max or 1)) / 2
    end
  end
  return 1
end

-- Expand a want into raw materials, spending what is already carried on the way
-- down. `stock` is consumed as it goes, so ten iron plates in a pocket are not
-- counted twice.
local function expand(force, stock, item, count, raw, blocked, depth)
  if depth > 8 then return end

  local have = stock[item] or 0
  local used = math.min(have, count)
  stock[item] = have - used
  local remaining = count - used
  if remaining <= 0 then return end

  if Craft.MINEABLE[item] then
    raw[item] = (raw[item] or 0) + remaining
    return
  end

  local recipe = hand_recipe(force, item)
  if not recipe then
    blocked[item] = (blocked[item] or 0) + remaining
    return
  end

  local per = product_count(recipe, item)
  local batches = math.ceil(remaining / per)
  for _, ingredient in pairs(recipe.ingredients) do
    if ingredient.type == "item" then
      expand(force, stock, ingredient.name, ingredient.amount * batches, raw, blocked, depth + 1)
    else
      blocked[ingredient.name] = (blocked[ingredient.name] or 0) + ingredient.amount * batches
    end
  end
end

-- What making `count` of `item` would take, given what the body is carrying.
function Craft.requirements(body, item, count)
  local force = body.force
  if not hand_recipe(force, item) then
    return nil, string.format("%s is not something I can make by hand", item)
  end

  local stock = {}
  local inventory = body.get_main_inventory()
  for _, stack in pairs(inventory and inventory.get_contents() or {}) do
    stock[stack.name] = (stock[stack.name] or 0) + stack.count
  end

  local raw, blocked = {}, {}
  expand(force, stock, item, count, raw, blocked, 0)

  local needed, short = {}, {}
  for name, amount in pairs(raw) do
    needed[#needed + 1] = {name = name, count = amount, mine = Craft.MINEABLE[name]}
  end
  for name, amount in pairs(blocked) do
    short[#short + 1] = {name = name, count = amount}
  end
  table.sort(needed, function(a, b) return a.name < b.name end)
  table.sort(short, function(a, b) return a.name < b.name end)
  return {item = item, count = count, mine = needed, cannot_make = short}
end

-- Craft what is already payable for; returns how many were started.
function Craft.begin(body, item, count)
  local recipe = hand_recipe(body.force, item)
  if not recipe then return 0, string.format("%s is not something I can make by hand", item) end
  local started = body.begin_crafting{count = count, recipe = recipe.name, silent = true}
  return started
end

function Craft.busy(body)
  local queue = body.crafting_queue
  return queue ~= nil and #queue > 0
end

function Craft.carrying(body, item)
  return Hands.carrying(body, item)
end

return Craft
