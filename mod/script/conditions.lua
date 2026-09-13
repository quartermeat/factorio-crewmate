-- The small checks that let a directive, or a personality with an opinion, decide
-- what to do next without asking anyone. Every one is a question about the world
-- or the agent's own pockets, answerable on the spot.

local Hands = require("script.hands")
local Works = require("script.works")

-- Conditions: the small checks that let a directive decide what to do next
-- without asking anyone. Every one of them is a question about the world or the
-- agent's own pockets, answerable on the spot.
local Conditions = {}

local CONDITIONS = {}

CONDITIONS.carrying = function(plan, body, test)
  local item = test.item
  local count = Hands.carrying(body, item)
  if test.at_least then return count >= test.at_least, string.format("%d %s", count, item) end
  if test.less_than then return count < test.less_than, string.format("%d %s", count, item) end
  return count > 0, string.format("%d %s", count, item)
end

CONDITIONS.exists = function(plan, body, test)
  local found = body.surface.count_entities_filtered
  {
    name = test.entity,
    position = body.position,
    radius = test.within or 64,
    force = body.force,
  }
  if test.at_least then return found >= test.at_least, tostring(found) end
  return found > 0, tostring(found)
end

CONDITIONS.resource_within = function(plan, body, test)
  local found = Works.find_resource(body, test.resource, test.within or 128)
  return found ~= nil, found and string.format("%.0f tiles", found.distance) or "none"
end

function Conditions.hold(plan, body, condition)
  if not condition then return true end
  for name, test in pairs(condition) do
    local check = CONDITIONS[name]
    if not check then return false, "I do not know how to check " .. name end
    local ok_, detail = check(plan, body, test)
    if not ok_ then return false, detail end
  end
  return true
end


return Conditions
