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

-- Only what a pair of hands can make. Which categories those are is not a guess:
-- the character prototype says so, and in Space Age the answer is wider than
-- "crafting" -- a transport belt is category "pressing" and hands can still make
-- one.
local function hand_categories()
  local character = prototypes.entity["character"]
  return (character and character.crafting_categories) or {crafting = true}
end

local function by_hand(recipe)
  return recipe.enabled and not recipe.hidden and hand_categories()[recipe.category] ~= nil
end

local function hand_recipe(force, item)
  local recipe = force.recipes[item]
  if recipe and by_hand(recipe) then return recipe end
  for _, candidate in pairs(force.recipes) do
    if by_hand(candidate) then
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

-- Everything it could actually make from scratch: a hand recipe whose ingredients
-- bottom out in things it knows how to dig up. Anything wanting a plate is left
-- out, because wanting a plate means wanting a furnace.
function Craft.craftable(body, limit)
  local force = body.force
  local listed = {}

  -- What it is carrying counts: hand it fifty iron plates and the list of things
  -- it can make grows, which is the honest answer to "what can you make".
  local carried = {}
  local inventory = body.get_main_inventory()
  for _, stack in pairs(inventory and inventory.get_contents() or {}) do
    carried[stack.name] = (carried[stack.name] or 0) + stack.count
  end

  for _, recipe in pairs(force.recipes) do
    if by_hand(recipe) then
      local product = recipe.products[1]
      if product and product.type == "item" then
        local stock = {}
        for name, amount in pairs(carried) do stock[name] = amount end

        local raw, blocked = {}, {}
        expand(force, stock, product.name, 1, raw, blocked, 0)
        if next(blocked) == nil then
          local parts = {}
          for material, amount in pairs(raw) do
            parts[#parts + 1] = string.format("%d %s", amount, material)
          end
          table.sort(parts)
          listed[#listed + 1] =
          {
            name = product.name,
            needs = #parts > 0 and table.concat(parts, ", ") or "nothing more -- I have the parts",
            ready = #parts == 0,
          }
        end
      end
    end
  end

  table.sort(listed, function(a, b) return a.name < b.name end)
  if limit and #listed > limit then
    local trimmed = {}
    for index = 1, limit do trimmed[index] = listed[index] end
    return trimmed, #listed
  end
  return listed, #listed
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
