-- Directives arrive here already compiled: a flat list of steps with absolute
-- positions. The mod's job is only to carry them out honestly -- walk there,
-- reach for it, admit when it cannot -- and to keep a record of what happened.

local Body = require("script.body")
local Hands = require("script.hands")
local Works = require("script.works")

local Plan = {}

local STEP_TIMEOUT = 60 * 60       -- a minute of no progress before a step gives up
local BUILD_TIMEOUT = 60 * 60 * 4  -- building a whole site is allowed to take longer
local TICK_RATE = 15

local function crew()
  storage.crew = storage.crew or {}
  return storage.crew
end

local function announce(message)
  game.print(string.format("[color=%f,%f,%f][%s][/color] %s",
    Body.COLOR.r, Body.COLOR.g, Body.COLOR.b, Body.NAME, message))
end

local function record(plan, outcome, detail)
  plan.log[#plan.log + 1] = {step = plan.index, outcome = outcome, detail = detail, tick = game.tick}
end

local function fail(plan, reason)
  Body.sign(nil)
  plan.state = "failed"
  plan.error = reason
  record(plan, "failed", reason)
  Body.halt()
  announce(string.format("stopped at step %d of %d: %s", plan.index, #plan.steps, reason))
end

local function finish(plan)
  plan.state = "done"
  announce(string.format("%s: done, %d steps.", plan.name, #plan.steps))
end

local function advance(plan)
  plan.index = plan.index + 1
  plan.step_started = game.tick
  if plan.index > #plan.steps then finish(plan) end
end

-- Walk into range before reaching for something. Returns true when the body is
-- close enough to act this tick.
local function approach(body, position)
  if Hands.within_reach(body, position) then
    Body.halt()
    return true
  end
  Body.walk_to(position)
  return false
end

-- Marks are positions a directive works out as it goes -- where the coal turned
-- out to be, where the drill row ended up -- so later steps can refer to them by
-- name instead of carrying coordinates a file could not have known.
local function mark(plan, name, value)
  plan.marks = plan.marks or {}
  plan.marks[name] = value
end

local function marked(plan, name)
  return plan.marks and plan.marks[name]
end

local function site_of(plan, body, padding)
  local anchor = plan.anchor or body.position
  padding = padding or 64
  return {{anchor.x - padding, anchor.y - padding}, {anchor.x + padding, anchor.y + padding}}
end

-- Marked-out work refers to things that may not be built yet, so a ghost counts.
local function find_thing(plan, body, name, padding)
  local area = site_of(plan, body, padding or 96)
  local built = body.surface.find_entities_filtered{name = name, area = area, force = body.force, limit = 1}[1]
  if built then return built end
  for _, candidate in pairs(body.surface.find_entities_filtered{name = "entity-ghost", area = area, force = body.force}) do
    if candidate.ghost_name == name then return candidate end
  end
end

-- Conditions: the small checks that let a directive decide what to do next
-- without asking anyone. Every one of them is a question about the world or the
-- agent's own pockets, answerable on the spot.
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

local function holds(plan, body, condition)
  if not condition then return true end
  for name, test in pairs(condition) do
    local check = CONDITIONS[name]
    if not check then return false, "I do not know how to check " .. name end
    local ok_, detail = check(plan, body, test)
    if not ok_ then return false, detail end
  end
  return true
end

local HANDLERS = {}

-- Labels and jumps: enough control flow to loop "mine a bit, check, mine again"
-- without anything outside the game deciding anything.
HANDLERS.label = function(plan, body, step)
  advance(plan)
end

HANDLERS.jump = function(plan, body, step)
  local target = step.to
  for index, candidate in pairs(plan.steps) do
    if candidate["do"] == "label" and candidate.name == target then
      plan.index = index
      plan.step_started = game.tick
      plan.jumps = (plan.jumps or 0) + 1
      if plan.jumps > (step.limit or 500) then
        return fail(plan, "this directive is going round in circles")
      end
      return
    end
  end
  fail(plan, "there is no label called " .. tostring(target))
end

HANDLERS.say = function(plan, body, step)
  announce(step.message or "")
  advance(plan)
end

HANDLERS.goto_position = function(plan, body, step)
  if type(step.at) == "string" then
    local place = marked(plan, step.at)
    if not place then return fail(plan, "I have not found " .. step.at .. " yet") end
    step.x, step.y = place.x, place.y
  end
  local target = {x = step.x, y = step.y}
  local dx, dy = body.position.x - target.x, body.position.y - target.y
  if math.sqrt(dx * dx + dy * dy) <= (step.within or 3) then
    Body.halt()
    advance(plan)
    return
  end
  Body.walk_to(target)
end

HANDLERS.place = function(plan, body, step)
  if not approach(body, {x = step.x, y = step.y}) then return end
  local built, err = Hands.place(body, step)
  if not built then
    if step.optional then
      record(plan, "skipped", err)
      advance(plan)
      return
    end
    return fail(plan, err)
  end
  record(plan, "placed", step.entity)
  advance(plan)
end

local function target_of(plan, body, step)
  if not step.into then return {x = step.x, y = step.y} end
  local site = plan.site or
  {
    {body.position.x - 32, body.position.y - 32},
    {body.position.x + 32, body.position.y + 32},
  }
  local candidates = body.surface.find_entities_filtered{name = step.into, area = site, force = body.force}
  local closest, closest_gap
  for _, candidate in pairs(candidates) do
    local dx, dy = candidate.position.x - body.position.x, candidate.position.y - body.position.y
    local gap = dx * dx + dy * dy
    if not closest_gap or gap < closest_gap then closest, closest_gap = candidate, gap end
  end
  return closest and closest.position
end

HANDLERS.insert = function(plan, body, step)
  local position = target_of(plan, body, step)
  if not position then return fail(plan, "there is no " .. tostring(step.into) .. " here to fill") end
  step.x, step.y = position.x, position.y
  if not approach(body, position) then return end
  local target, err, moved = Hands.insert(body, step)
  if not target then
    if step.optional then
      record(plan, "skipped", err)
      advance(plan)
      return
    end
    return fail(plan, err)
  end
  record(plan, "inserted", string.format("%d %s", moved, step.item))
  advance(plan)
end

HANDLERS.connect = function(plan, body, step)
  if not approach(body, {x = step.from_x, y = step.from_y}) then return end
  local connected, err = Hands.connect(body, step)
  if not connected then
    if step.optional then
      record(plan, "skipped", err)
      advance(plan)
      return
    end
    return fail(plan, err)
  end
  record(plan, "connected", "poles")
  advance(plan)
end

-- Two steps make a blueprint real: stamp it as ghosts, then walk the site
-- building them until none are left.
-- Stamping is a map-view action: a player marks out a blueprint from anywhere,
-- and only building it needs boots on the ground.
local DIRECTION_NAMES = {[0] = "north", [4] = "east", [8] = "south", [12] = "west"}

HANDLERS.stamp = function(plan, body, step)
  -- "at" may name a mark that an earlier step worked out.
  if type(step.at) == "string" then
    local site = marked(plan, step.at)
    if not site then return fail(plan, "I have not found " .. step.at .. " yet") end
    step.x, step.y = site.x, site.y
    step.direction = DIRECTION_NAMES[site.direction] or step.direction
  end
  local stamped, err = Hands.stamp_aligned(body, step)
  if not stamped then return fail(plan, err) end
  plan.anchor = {x = step.x, y = step.y}
  plan.site =
  {
    {step.x - (step.radius or 32), step.y - (step.radius or 32)},
    {step.x + (step.radius or 32), step.y + (step.radius or 32)},
  }
  record(plan, "stamped", string.format("%d ghosts", stamped.ghosts))
  advance(plan)
end

-- Build the site one ghost at a time, nearest first. A ghost the body cannot get
-- to within a reasonable time is set aside rather than allowed to wedge the
-- whole directive: the step finishes with what got built and says what did not,
-- which is what an unattended loop should do.
local REACH_ATTEMPT = 60 * 20

HANDLERS.build_ghosts = function(plan, body, step)
  local site = plan.site or site_of(plan, body, 128)
  plan.unreachable = plan.unreachable or {}

  local built, reason, position, key = Hands.build_nearest_ghost(body, site, plan.unreachable, plan.anchor)
  if built == false then
    Body.halt()
    plan.reaching = nil
    local left = 0
    for _ in pairs(plan.unreachable) do left = left + 1 end
    if reason == "unreachable" and left > 0 then
      record(plan, "gave up", string.format("%d pieces I could not get to or place", left))
      announce(string.format("built what I could; %d pieces I could not get to or place.", left))
    else
      record(plan, "built", "site clear")
    end
    advance(plan)
    return
  end

  if not built then
    if reason == "walking" or reason == "standing" then
      local where = string.format("%.1f,%.1f", position.x, position.y)
      if reason == "walking" then
        if plan.reaching and plan.reaching.key == where then
          if game.tick - plan.reaching.since > REACH_ATTEMPT then
            plan.unreachable[where] = true
            plan.reaching = nil
            record(plan, "skipped", "could not reach " .. where)
            -- Setting one aside is progress: it is the step moving on, not
            -- the step stalling.
            plan.step_started = game.tick
            return
          end
        else
          plan.reaching = {key = where, since = game.tick}
        end
      end
      Body.walk_to(position)
      return
    end
    -- Something took the spot since it was marked out: set that one aside and
    -- carry on rather than abandoning the job.
    if key then
      plan.unreachable[key] = true
      record(plan, "skipped", reason)
      plan.step_started = game.tick
      return
    end
    return fail(plan, reason)
  end

  plan.reaching = nil
  plan.step_started = game.tick -- progress; do not time out mid-site
  record(plan, "built", built)
end

HANDLERS.find_resource = function(plan, body, step)
  local found, err = Works.find_resource(body, step.resource, step.radius, step.kind)
  if not found then return fail(plan, err) end
  -- Two marks: the near edge, which is where to walk, and the centre, which is
  -- where a row of drills wants to sit.
  mark(plan, step.as or step.resource, found.position)
  mark(plan, (step.as or step.resource) .. "_centre", found.centre)
  record(plan, "found", string.format("%s %.0f tiles away", step.resource, found.distance))
  if found.distance < 2 then
    announce(string.format("standing on the %s already -- %d tiles of it.", step.resource, found.tiles))
  else
    announce(string.format("nearest %s is %.0f tiles away, %d tiles of it.", step.resource, found.distance, found.tiles))
  end
  advance(plan)
end

-- Pick the site for a blueprint at run time: the shore nearest the coal, rather
-- than the shore nearest wherever the body happened to be standing.
HANDLERS.find_site = function(plan, body, step)
  local near = step.near and marked(plan, step.near) or body.position
  if not near then return fail(plan, "I do not know where to look for " .. tostring(step.what)) end
  local spots = Works.pump_spots(body, near, step.radius, 1)
  if #spots == 0 then
    return fail(plan, string.format("no %s within %d tiles of there", step.what or "site", step.radius or 64))
  end
  mark(plan, step.as or "site", {x = spots[1].position.x, y = spots[1].position.y, direction = spots[1].direction})
  record(plan, "found", step.what or "site")
  advance(plan)
end

HANDLERS.drill_row = function(plan, body, step)
  local patch = marked(plan, step.patch or "coal")
  if not patch then return fail(plan, "I have not found that patch yet") end
  local row, err = Works.drill_row(body, {
    patch = patch, resource = step.resource, count = step.count, drill = step.drill,
  })
  if not row then return fail(plan, err) end
  mark(plan, (step.as or "drills") .. "_lane_from", row.lane.from)
  mark(plan, (step.as or "drills") .. "_lane_to", row.lane.to)
  mark(plan, step.as or "drills", row.lane.from)
  plan.site = nil -- the site now spans both ends of the job
  record(plan, "marked out", string.format("%d drills", row.drills))
  advance(plan)
end

HANDLERS.belt_line = function(plan, body, step)
  local from = marked(plan, step.from)
  if not from then return fail(plan, "I do not know where to start the belt") end
  local target = find_thing(plan, body, step.to, step.search)
  if not target then return fail(plan, "there is no " .. tostring(step.to) .. " to belt into") end
  local run, err = Works.belt_line(body, {
    from = from, target = target, belt = step.belt, inserter = step.inserter, limit = step.limit,
  })
  if not run then return fail(plan, err) end
  record(plan, "marked out", string.format("%d belt tiles", run.length))
  advance(plan)
end

HANDLERS.pole_line = function(plan, body, step)
  local from = marked(plan, step.from)
  local to = marked(plan, step.to)
  if not from then
    local entity = find_thing(plan, body, step.from, step.search)
    from = entity and entity.position
  end
  if not (from and to) then return fail(plan, "I do not know where to run the poles between") end
  local run = Works.pole_line(body, {from = from, to = to, pole = step.pole, spacing = step.spacing})
  record(plan, "marked out", string.format("%d poles", run.poles))
  advance(plan)
end

-- Check the job actually did what it was for. An unattended loop that reports
-- "done" when the wire never reached is worse than one that admits it.
HANDLERS.check_power = function(plan, body, step)
  local area = site_of(plan, body, step.search or 160)
  local source = body.surface.find_entities_filtered{name = step.from, area = area, force = body.force}[1]
  local consumers = body.surface.find_entities_filtered{name = step.to, area = area, force = body.force}
  if not source or #consumers == 0 then
    return fail(plan, string.format("cannot check the wiring: no %s or no %s got built",
      tostring(step.from), tostring(step.to)))
  end
  local connected, total = 0, #consumers
  for _, consumer in pairs(consumers) do
    if consumer.electric_network_id and source.electric_network_id
      and consumer.electric_network_id == source.electric_network_id then
      connected = connected + 1
    end
  end
  if connected == 0 then
    return fail(plan, string.format("the %s are not on the %s's network -- the pole run did not join up",
      step.to, step.from))
  end
  record(plan, "checked", string.format("%d of %d %s powered", connected, total, step.to))
  if connected < total then
    announce(string.format("%d of the %d %s are not powered yet.", total - connected, total, step.to))
  end
  advance(plan)
end

-- Mine until it is carrying enough, or until the patch runs out. Progress keeps
-- the step alive, so a long dig does not look like a stall.
HANDLERS.mine = function(plan, body, step)
  local resource = step.resource or "coal"
  local kind = step.kind -- "type" for things like trees, which have many names
  local target = step.amount or 100

  -- A type search -- "tree" rather than "wood" -- cannot know what it yields
  -- until it has found one, and asking the inventory for "tree" is an error.
  local item = step.item
  if not item then
    if kind == "type" then
      local sample = Works.find_resource(body, resource, step.radius or 64, kind)
      local entity = sample and body.surface.find_entities_filtered
        {position = sample.position, radius = 1, type = resource, limit = 1}[1]
      if not entity then
        return fail(plan, "there is no " .. resource .. " around here")
      end
      item = Hands.product_of(entity)
    else
      item = Hands.product_of(resource)
    end
  end
  local carried = Hands.carrying(body, item)

  if carried >= target then
    Body.sign(nil)
    Hands.stop_mining(body)
    Body.halt()
    record(plan, "mined", string.format("%d %s", carried, item))
    announce(string.format("got %d %s.", carried, item))
    advance(plan)
    return
  end

  -- Always swing at the closest ore to where it is standing, widening the search
  -- only when the near ones are gone.
  plan.mine_skip = plan.mine_skip or {}
  local closest = Works.nearest_minable(body, resource, kind, step.radius or 64, plan.mine_skip)

  if not closest then
    Body.sign(nil)
    Hands.stop_mining(body)
    Body.halt()
    if carried == 0 then
      return fail(plan, "there is no " .. resource .. " around here I can get to")
    end
    record(plan, "mined", string.format("%d %s, then the patch ran out", carried, item))
    announce(string.format("patch is gone; I got %d %s.", carried, item))
    advance(plan)
    return
  end

  local reached, reason, position = Hands.reach_ore(body, closest)
  if not reached then
    if reason == "walking" then
      Body.sign(nil)
      Hands.stop_mining(body)
      -- Walking towards it is progress. A patch a couple of hundred tiles away
      -- is a long stroll, and a stroll is not a stall.
      local dx, dy = position.x - body.position.x, position.y - body.position.y
      local gap = math.sqrt(dx * dx + dy * dy)
      local key = string.format("%.1f,%.1f", position.x, position.y)
      if not plan.mine_gap or gap < plan.mine_gap - 1 then
        plan.mine_gap, plan.mine_towards, plan.mine_since = gap, key, game.tick
        plan.step_started = game.tick
      elseif plan.mine_towards == key and game.tick - (plan.mine_since or game.tick) > 60 * 15 then
        -- Fifteen seconds of no ground gained: that one is behind water or a
        -- cliff. Give up on it specifically and try the next nearest.
        plan.mine_skip[key] = true
        plan.mine_gap, plan.mine_towards, plan.mine_since = nil, nil, nil
        plan.step_started = game.tick
        record(plan, "skipped", "could not get to " .. key)
        return
      end
      Body.sign(string.format("walking to the %s  %.0f tiles", item, gap))
      Body.walk_to(position)
      return
    end
    return fail(plan, reason)
  end
  plan.mine_gap = nil
  Body.halt()

  -- Say how long this is going to take, once, and then how it is going. Three
  -- minutes of silent standing looks exactly like three minutes of being stuck.
  local interval_ticks = Hands.mining_ticks(closest)
  if not plan.mine_started then
    plan.mine_started = true
    plan.mine_announced = carried
    local seconds = math.floor((target - carried) * interval_ticks / 60)
    announce(string.format("digging %d %s -- about %d:%02d at hand-mining speed.",
      target - carried, item, math.floor(seconds / 60), seconds % 60))
  end
  if carried - (plan.mine_announced or 0) >= math.max(10, math.floor(target / 4)) then
    plan.mine_announced = carried
    announce(string.format("%d of %d %s.", carried, target, item))
  end
  Body.sign(string.format("mining %s  %d/%d", item, carried, target))

  -- One swing per the ore's own mining time, so a hundred coal takes as long as
  -- a hundred coal should.
  if plan.mine_next and game.tick < plan.mine_next then return end
  plan.mine_next = game.tick + interval_ticks

  local mined, why = Hands.mine_one(body, closest)
  if not mined then
    Hands.stop_mining(body)
    return fail(plan, why)
  end
  plan.step_started = game.tick
end

HANDLERS.wait = function(plan, body, step)
  if game.tick - plan.step_started >= (step.ticks or 60) then advance(plan) end
end

function Plan.start(argument)
  local body = Body.get()
  if not body then return nil, "no body in the world; spawn one first" end

  local steps = argument.steps or {}
  if #steps == 0 then return nil, "that directive has no steps" end

  local short = Hands.missing(body, argument.requires or {})
  if #short > 0 then
    local list = {}
    for _, entry in pairs(short) do
      list[#list + 1] = string.format("%s x%d (have %d)", entry.name, entry.need, entry.have)
    end
    return nil, "I am short of " .. table.concat(list, ", ")
  end

  local state = crew()
  state.plan =
  {
    name = argument.name or "directive",
    steps = steps,
    index = 1,
    state = "running",
    log = {},
    started = game.tick,
    step_started = game.tick,
  }
  announce(string.format("starting %s: %d steps.", state.plan.name, #steps))
  return state.plan
end

function Plan.cancel()
  Body.sign(nil)
  local plan = crew().plan
  if plan and plan.state == "running" then
    plan.state = "cancelled"
    Body.halt()
    announce("cancelled " .. plan.name .. ".")
    return true
  end
  return false
end

function Plan.status()
  local plan = crew().plan
  if not plan then return {state = "idle"} end
  local step = plan.steps[plan.index]
  return
  {
    name = plan.name,
    state = plan.state,
    step = plan.index,
    steps = #plan.steps,
    doing = step and step["do"] or nil,
    error = plan.error,
    elapsed = game.tick - plan.started,
    log = plan.log,
  }
end

-- Anything that needs doing once after a load hangs off the tick handler that is
-- always registered, because registering a new one on load breaks multiplayer.
local once = {}
local done_once = false

function Plan.on_first_tick(action)
  once[#once + 1] = action
end

script.on_nth_tick(TICK_RATE, function()
  if not done_once then
    done_once = true
    for _, action in pairs(once) do pcall(action) end
  end
  local plan = crew().plan
  if not plan or plan.state ~= "running" then return end

  local body = Body.get()
  if not body then return fail(plan, "I lost my body") end

  local step = plan.steps[plan.index]
  local budget = STEP_TIMEOUT
  if step and step["do"] == "build_ghosts" then budget = BUILD_TIMEOUT end
  if game.tick - plan.step_started > budget then
    local where = ""
    if step and step["do"] == "build_ghosts" then
      local ghosts = body.surface.find_entities_filtered{name = "entity-ghost", force = body.force, area = plan.site}
      local nearest
      for _, ghost in pairs(ghosts) do
        local dx, dy = ghost.position.x - body.position.x, ghost.position.y - body.position.y
        local gap = math.sqrt(dx * dx + dy * dy)
        if not nearest or gap < nearest.gap then
          nearest = {gap = gap, name = ghost.ghost_name, x = ghost.position.x, y = ghost.position.y}
        end
      end
      if nearest then
        where = string.format(" -- %d ghosts left, nearest is a %s %.0f tiles away at %.0f,%.0f (I reach %d) and I am at %.0f,%.0f",
          #ghosts, nearest.name, nearest.gap, nearest.x, nearest.y, body.build_distance, body.position.x, body.position.y)
      else
        where = " -- no ghosts left to build, which should have finished the step"
      end
    elseif step and step["do"] == "mine" then
      where = string.format(" -- I am at %.0f,%.0f%s", body.position.x, body.position.y,
        plan.mine_gap and string.format(" and still %.0f tiles short of it", plan.mine_gap) or "")
    elseif step and step.x then
      local dx, dy = body.position.x - step.x, body.position.y - step.y
      where = string.format(" -- I am %.0f tiles from %.0f,%.0f and not getting closer",
        math.sqrt(dx * dx + dy * dy), step.x, step.y)
    end
    return fail(plan, string.format("step %d (%s) took too long%s",
      plan.index, step and step["do"] or "?", where))
  end

  if not step then return finish(plan) end

  local handler = HANDLERS[step["do"] == "goto" and "goto_position" or step["do"]]
  if not handler then return fail(plan, "I do not know how to " .. tostring(step["do"])) end

  -- A step with an unmet condition is simply not this step's turn.
  local met, detail = holds(plan, body, step["when"])
  if not met then
    record(plan, "skipped", string.format("%s (%s)", step["do"], tostring(detail)))
    advance(plan)
    return
  end

  local ok, err = pcall(handler, plan, body, step)
  if not ok then fail(plan, tostring(err)) end
end)

return Plan
