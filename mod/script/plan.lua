-- Directives arrive here already compiled: a flat list of steps with absolute
-- positions. The mod's job is only to carry them out honestly -- walk there,
-- reach for it, admit when it cannot -- and to keep a record of what happened.

local Body = require("script.body")
local Hands = require("script.hands")

local Plan = {}

local STEP_TIMEOUT = 60 * 60 -- a minute per step before it gives up
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

local HANDLERS = {}

HANDLERS.say = function(plan, body, step)
  announce(step.message or "")
  advance(plan)
end

HANDLERS.goto_position = function(plan, body, step)
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
HANDLERS.stamp = function(plan, body, step)
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
  local site = plan.site or
  {
    {body.position.x - 32, body.position.y - 32},
    {body.position.x + 32, body.position.y + 32},
  }
  plan.unreachable = plan.unreachable or {}

  local built, reason, position = Hands.build_nearest_ghost(body, site, plan.unreachable, plan.anchor)
  if built == false then
    Body.halt()
    plan.reaching = nil
    local left = 0
    for _ in pairs(plan.unreachable) do left = left + 1 end
    if reason == "unreachable" and left > 0 then
      record(plan, "gave up", string.format("%d ghosts I could not get to", left))
      announce(string.format("built what I could reach; %d pieces are somewhere I cannot walk to.", left))
    else
      record(plan, "built", "site clear")
    end
    advance(plan)
    return
  end

  if not built then
    if reason == "walking" then
      local key = string.format("%.1f,%.1f", position.x, position.y)
      if plan.reaching and plan.reaching.key == key then
        if game.tick - plan.reaching.since > REACH_ATTEMPT then
          plan.unreachable[key] = true
          plan.reaching = nil
          record(plan, "skipped", "could not reach " .. key)
          return
        end
      else
        plan.reaching = {key = key, since = game.tick}
      end
      Body.walk_to(position)
      return
    end
    return fail(plan, reason)
  end

  plan.reaching = nil
  plan.step_started = game.tick -- progress; do not time out mid-site
  record(plan, "built", built)
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

script.on_nth_tick(TICK_RATE, function()
  local plan = crew().plan
  if not plan or plan.state ~= "running" then return end

  local body = Body.get()
  if not body then return fail(plan, "I lost my body") end

  if game.tick - plan.step_started > STEP_TIMEOUT then
    local step = plan.steps[plan.index]
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
    elseif step and step.x then
      local dx, dy = body.position.x - step.x, body.position.y - step.y
      where = string.format(" -- I am %.0f tiles from %.0f,%.0f and not getting closer",
        math.sqrt(dx * dx + dy * dy), step.x, step.y)
    end
    return fail(plan, string.format("step %d (%s) took too long%s",
      plan.index, step and step["do"] or "?", where))
  end

  local step = plan.steps[plan.index]
  if not step then return finish(plan) end

  local handler = HANDLERS[step["do"] == "goto" and "goto_position" or step["do"]]
  if not handler then return fail(plan, "I do not know how to " .. tostring(step["do"])) end

  local ok, err = pcall(handler, plan, body, step)
  if not ok then fail(plan, tostring(err)) end
end)

return Plan
