# Crewmate

A scripted agent that plays Factorio alongside you. Not a puppet of your
character and not a god-mode console script: a `character` entity standing in
your world with a nametag over its head -- **Crew** -- that walks, talks, watches
the factory and builds. It runs directives: small jobs written as data, chained by
conditions it checks itself. A person or a model can give it one, but neither is
in the loop while it works.

## Why it works this way

Factorio ships a headless *server* but no headless client, so a genuine second
player is impossible without a second machine, a second licence and a screen for
it to draw on. A scripted character body is the closest honest equivalent: same
entity type a player controls, same hit points, same inventory, same reach.

The alternative — a script that conjures entities wherever it likes — would make
a worse companion. Something that can only act where it is standing, using items
it is actually carrying, is a teammate whose behaviour you can predict, catch out,
and argue with.

## Principles

- **Fair play.** No cheat mode, no indestructible flag, no teleporting where
  walking would do, nothing spawned from nothing. If it would embarrass a human
  player, it should embarrass this one.
- **Legible.** Everything it does happens somewhere you could have watched it
  happen, and it says what it is doing in chat.
- **No surprises.** It does not redesign your base because it thinks it knows
  better. Standing orders are explicit and narrow.
- **Reversible.** Anything it builds, you can deconstruct; anything it changes
  should be traceable to the instruction that caused it.

## Shape

    mod/       Factorio mod: the body, its senses, and the RCON-facing interface
    bridge/    Go binary: hosts the server, speaks RCON, serves MCP over stdio
    scripts/   setup

The mod exposes a `crewmate` remote interface where every call returns
`{ok, result}` or `{ok=false, error}` as JSON. The bridge turns those into MCP
tools, which is what Claude Code actually calls.

## Setup

    python3 scripts/setup.py

Links the mod into `~/.factorio/mods`, builds the bridge, and writes an RCON
password to `~/.config/crewmate/env`. It prints the one command you run yourself:

    claude mcp add crewmate --scope user -- <repo>/bridge/crewmate mcp

## Playing

### From inside the game

`/crew` and `/crew` are the same command.

    /crew                  where it is and what it is doing
    /crew come             spawn it if needed, and follow you
    /crew take <item> [n]  hand it some of your items
    /crew give [item]      have it hand them back
    /crew do               list the directives it knows
    /crew do <directive>   carry one out
    /crew mine <ore> [n]   go and hand-mine some ore
    /crew stop             stand still, drop the current directive

`/crew take` exists because Factorio has no way to put items into another
character's inventory -- you cannot open one the way you open a chest. It moves
your own items across, which is the honest version of handing them over.

`/crew do` cannot read the directive files itself, so the mod queues the request
and the bridge -- already running alongside the server -- notices it, compiles the
directive and sets it going. A loop, not a conversation.


    bridge/crewmate serve -save ~/.factorio/saves/your-save.zip
    bridge/crewmate stop      # stops that server and nothing else

Then join from the game: Multiplayer → Connect to address → `127.0.0.1`. In game,
`/crew come` puts a body next to you; `/crew` says where it is and what it thinks
it is doing.

The server keeps its own write-data directory (`~/.local/share/factorio-crewmate`)
because the graphical game holds an exclusive lock on `~/.factorio` while you
play. It loads mods from `~/.factorio/mods`, so client and server agree without
you managing two mod sets.

## Driving it by hand

    bridge/crewmate call status
    bridge/crewmate call look '{"radius":48}'
    bridge/crewmate call say '{"message":"the north smelter is browning out"}'
    bridge/crewmate call walk_to '{"x":120,"y":-40}'
    bridge/crewmate exec "/sc rcon.print(game.tick)"

## Directives

A directive is a goal written down as data: what to build, what sort of site it
needs, what it costs, and the steps to get there. `directives/coal-to-power.json`
is the worked example -- an offshore pump, a boiler and three steam engines on the
nearest shore, with the boiler loaded.

    bridge/crewmate directive list
    bridge/crewmate directive show coal-to-power
    bridge/crewmate directive run coal-to-power '{"coal": 200}'

Nothing about running one involves a language model. The bridge finds a site, the
mod carries the steps out on its own clock, and an agent is only worth involving
when the companion stops and says why. That is the intended shape of the whole
project: **scripted loops do the work; the model is the fallback, not the engine.**

### What a directive looks like

```json
{
  "name": "coal-to-power",
  "anchor": {"find": "pump_spot", "radius": 64,
             "describe": "a stretch of shore an offshore pump will fit on"},
  "blueprint": "0eNqV...",
  "align": "offshore-pump",
  "parameters": {"coal": {"default": 100}},
  "supplies": [{"name": "coal", "count": "$coal"}],
  "steps": [
    {"do": "say", "message": "Found a shore..."},
    {"do": "stamp", "at": "anchor", "align": "offshore-pump", "radius": 24},
    {"do": "build_ghosts"},
    {"do": "insert", "into": "boiler", "item": "coal", "count": "$coal"}
  ]
}
```

Layout comes from a **blueprint string**, because Factorio already solves geometry
and fluid alignment and nothing hand-written will match it. Positions in steps are
avoided where possible: `insert` names an entity (`"into": "boiler"`) and the mod
finds the one it just built.

The verbs are `say`, `goto`, `stamp`, `build_ghosts`, `insert`, `place`,
`connect`, `wait`, and the ones that work things out at run time:

| verb | what it does |
| --- | --- |
| `find_resource` | nearest patch of an ore, remembered as a named mark |
| `find_site` | somewhere a thing will actually fit, near a mark -- a shore for a pump |
| `drill_row` | the longest unbroken row of drills that has ore under it, with a belt lane and poles |
| `belt_line` | a two-leg belt run from a mark to an entity, ending in an inserter facing it |
| `pole_line` | poles close enough together to carry power the whole way |
| `check_power` | confirms two things ended up on the same electric network |
| `mine` | hand-mines a patch until it is carrying enough, or the patch runs out |
| `make` | expands a recipe to raw materials and splices the digging into the plan |
| `craft` | hand-crafts, waiting on the crafting queue |

### The starting materials

Everything a starting kit can take out of the ground by hand has a job of its own:

    /crew mine coal 200
    /crew mine iron 100      iron-ore
    /crew mine copper        copper-ore
    /crew mine stone
    /crew mine wood          chopped from the nearest trees
    /crew make furnace       makes it, digging up what it needs first

Each is a thin wrapper over `gather`, which takes the resource as a parameter, so
adding one is four lines of JSON rather than any new code. Anything else minable
still works -- `/crew mine uranium-ore` goes through `gather` directly.

### Making things

    /crew make                lists what it can make, and what each would take
    /crew make furnace        works out it needs 5 stone, digs it, crafts it
    /crew make chest 4
    /crew make belt 20

`make` is a want, not a plan. Given a thing and a count it expands the recipe down
to raw materials, spends whatever is already in its pockets on the way down, and
then **rewrites the plan**: the digging it turns out to need is spliced in ahead of
the crafting. The plan is data, so a step can write more steps.

`/crew make` on its own answers honestly for the moment it is asked: empty-handed
on Nauvis that is two things, a stone furnace and a wooden chest, because
everything else wants a plate and a plate wants a furnace. Hand it two hundred
iron plates and the same question offers nine.

Only recipes a pair of hands can do. Anything wanting a furnace or an assembler is
refused before a shovel is lifted, and the refusal names what it was short of:

    iron-chest needs 8 iron-plate, and I cannot make those by hand

### Only what this game has unlocked

Neither list offers anything the tech tree has not reached. For crafting the game
already answers that -- `LuaRecipe.enabled` is per force and false until the
research is done -- so nothing here reimplements it. Directives declare the
recipes they depend on:

```json
"requires_recipes": ["offshore-pump", "boiler", "steam-engine", "medium-electric-pole"]
```

and `/crew do` shows the rest under "not yet", naming the recipe that is missing,
rather than letting you start a job that cannot finish.

### Deciding what to do next

Any step can carry a `when`, and a directive can jump:

```json
{"do": "label", "name": "check"},
{"do": "include", "directive": "mine-coal", "parameters": {"amount": "$amount"},
 "when": {"carrying": {"item": "coal", "less_than": "$amount"}}},
{"do": "jump", "to": "check",
 "when": {"carrying": {"item": "coal", "less_than": "$amount"}}}
```

That is `stock-coal` in full: look in your pockets, dig if short, look again,
stop when you are not. The conditions are `carrying`, `exists` and
`resource_within` -- questions about the world or its own inventory, answerable on
the spot, with nothing consulted outside the game.

`include` pulls another directive's steps in where it stands, so small reliable
jobs add up into bigger ones without any of them knowing about the others. A
parameter written `"$amount"` at an include site keeps pointing at the including
directive's value, so numbers flow down.

Parameters carry strings as well as numbers, which is what lets one directive
serve five materials. `"kind": "type"` searches by entity type rather than name,
for things like trees that come in a hundred named varieties.

Marks are how a directive refers to things it could not have known: `find_resource`
writes one, `drill_row` and `belt_line` read them. `insert` names an entity
(`"into": "boiler"`) rather than a position, and the mod finds the one it built.

`coal-power-loop` is the whole bootstrap: find coal, find the shore nearest *it*,
build a steam block, put drills on the coal, belt them back to the boiler, run
poles between the two, load the boiler, and then check that the drills really are
on the engines' network before claiming to be done. The mod cannot read files -- Factorio gives runtime scripts
no way to -- so the bridge compiles a directive into absolute steps and hands the
whole thing over in one call.

### Things learned the hard way

- `create_entities_from_blueprint_string` **only works in menu simulations**, and
  returns nothing useful. Ghosts are placed individually instead, positioned
  relative to the directive's anchor entity, which also removes any question of
  where the game would have centred the blueprint.
- Build the **far end of a site first**. Nearest-first walls the body in behind
  its own machines -- a row of steam engines is as solid as a fence -- and it
  cannot reach the last few ghosts.
- A ghost the body genuinely cannot get to is set aside, not allowed to wedge the
  directive: the step finishes with what got built and says what did not.
- Walking uses the game's pathfinder, with a generous goal radius: shoreline goals
  are often tiles a character cannot stand on, and a path that ends near one is
  just as good.
- `can_place_entity` ignores ghosts, so two steps can mark out work in the same
  place and whichever is built first blocks the other. Marking checks footprints
  for existing ghosts as well.
- A player who builds where they stand gets shoved aside; a scripted revive just
  fails. The body steps off a footprint before building it.
- A directive that reports "done" when the pole run never joined up is worse than
  one that admits it, which is what `check_power` is for.
- Hand-craftability is **not** `category == "crafting"`. In Space Age a transport
  belt is category `"pressing"` and hands can still make one. The character
  prototype's `crafting_categories` is the only correct answer.
- Only a `resource` has an `amount`. Asking a tree for one is an error, not a
  nil, so ore comes up a unit at a time while a tree comes up whole.
- Ore behind water or a cliff will never be reached, and walking at it forever
  looks identical to working. Fifteen seconds without gaining ground sets that
  one aside and tries the next nearest.
- A character with no player attached will not hold the **mining animation**
  either: the engine clears `mining_state` every tick and re-asserting it does not
  stick. It says what it is doing in text above its head instead, because standing
  motionless while ore quietly disappears looks exactly like being stuck.
- A character with no player attached **ignores `mining_state`** -- that logic
  lives in the player controller. Digging is scripted instead, but paced by the
  game's own numbers: the ore's mining time over the character's mining speed, one
  unit at a time, and the patch depletes exactly as it would by hand.

## Iterating

Mods cannot be reloaded live in multiplayer — `game.reload_mods()` is documented
as doing nothing there, and measurably does nothing — so picking up an edit means
bouncing the server. That is cheaper than it sounds: save, stop, start and ready
again measures about **1.6 seconds** on a small world. Connected clients drop to
the menu and reconnect.

    bridge/crewmate serve -save <save> -watch mod

watches the mod directory and does the whole cycle itself on every edit. Leave
`-watch` off when someone is actually playing, or their game bounces every time
you touch a file.

Bridge changes are a rebuild (`go build -o crewmate .`); the MCP server is
started by Claude Code, so a rebuilt binary needs a reconnect on that side.

Data-stage changes — `info.json`, prototypes — need a full restart of the client
too, but this mod has no data stage, so that rarely comes up.

## Where this is going

- **v0.1 — a body.** Spawns, walks, follows, dies and comes back. *Done.*
- **v0.2 — senses worth trusting.** Status, surroundings, chat both ways,
  screenshots, and a test suite that runs the whole thing against a real game.
  *Done.*
- **v0.3 — iteration.** A watch mode that restarts the server on every mod edit,
  since multiplayer cannot reload mods live. *Done.*
- **v0.4 — hands and directives.** Goals defined in data files, carried out
  unsupervised: reach-limited building from its own inventory, ghosts first.
  *Done.*
- **v0.5 — the bootstrap loop.** Coal to steam to electric mining, marked out and
  built unattended, and checked afterwards. *Done.*
- **v0.6 — in-game control.** Give and supply a directive without leaving the
  game. *Done.*
- **v0.7 — scripted decisions.** Conditions, labels, jumps and composition, so a
  directive decides its own next step. *Done.*
- **v0.8 — making things.** Recipes expanded to raw materials, with the gathering
  worked out and inserted by the agent itself. *Done.*
- **v0.9 — a sense of place.** Remembers the base: named areas, what it built,
  what it was asked to leave alone.
- **v0.10 — initiative.** Standing orders it acts on — keep turrets fed, fix the
  brownout, extend the smelter row — and the judgement to ask first when a job is
  bigger than the order.
- **v0.11 — manners.** An audit log of every action, per-player permissions, and an
  undo that actually works.

## Testing

    cd bridge && go test ./...                              # fast, no game needed
    CREWMATE_INTEGRATION=1 go test -run Integration -v       # generates a map, hosts it, drives the body

The integration test needs a Factorio install and takes about seven seconds. It
runs against a throwaway map in a temp directory and never touches `~/.factorio`.

## Gotchas worth knowing

- **Never register an event handler in `script.on_load`.** The client ends up with
  a different set of registrations than the save recorded, and every join fails
  with `script-event-mismatch` -- which a player reads as "this mod is not
  multiplayer safe". Work that needs doing once after a load hangs off a handler
  that is always registered.
- Stop a server with `crewmate stop`, not by killing whatever matches
  `start-server`: the pattern also matches test servers and any other game you
  have running.

- The first console command on a save answers Factorio's "this disables
  achievements" prompt instead of running, and says so only in the server log. The
  bridge repeats a silent command once, which is what the prompt wants.
- Single-player has no RCON. Hosting is not optional.
- A headless server cannot render, so screenshots are taken by a joined graphical
  client (`by_player`) and fail cleanly when nobody is connected.
- Hosting a save rewrites `~/.factorio/mods/mod-list.json` to match what that save
  needs, so loading an old world can quietly re-enable a mod you turned off. Check
  the list after hosting something unusual.
- Lua has one table type, so an empty list and an empty map both arrive as `{}`.
  The bridge rewrites empty objects to `[]` so a field's type does not depend on
  whether the factory happens to be busy.
