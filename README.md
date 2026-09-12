# Crewmate

An AI-controlled companion that plays Factorio with you. Not a puppet of your
character and not a god-mode console script: a `character` entity standing in
your world with a nametag over its head, that walks, talks, watches the factory,
and — as it grows — builds. Its instructions arrive over RCON from a language
model instead of from a keyboard, and it is otherwise bound by the same rules you
are.

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

    bridge/crewmate serve -save ~/.factorio/saves/your-save.zip

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
- **v0.3 — hands.** Build, mine, craft and haul, limited to its reach and its own
  inventory, ghosts first so you see what it intends before it happens.
- **v0.4 — a sense of place.** Remembers the base: named areas, what it built,
  what it was asked to leave alone.
- **v0.5 — initiative.** Standing orders it acts on — keep turrets fed, fix the
  brownout, extend the smelter row — and the judgement to ask first when a job is
  bigger than the order.
- **v0.6 — manners.** An audit log of every action, per-player permissions, and an
  undo that actually works.

## Testing

    cd bridge && go test ./...                              # fast, no game needed
    CREWMATE_INTEGRATION=1 go test -run Integration -v       # generates a map, hosts it, drives the body

The integration test needs a Factorio install and takes about seven seconds. It
runs against a throwaway map in a temp directory and never touches `~/.factorio`.

## Gotchas worth knowing

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
