# Crewmate

An agent with a body in your Factorio game. Not a puppet of your character and
not a god-mode script: a plain `character` entity on the server that walks
around, can be hurt, dies like anyone else's, and takes its instructions over
RCON instead of from a keyboard.

Two halves:

- `mod/` — the Factorio mod. Spawns the body, steers it, and exposes senses
  (status, look, hear) through a `crewmate` remote interface.
- `bridge/` — a Go binary. Hosts the server, speaks RCON to it, and presents the
  whole thing to Claude Code as an MCP server.

## Setup

    python3 scripts/setup.py

That symlinks the mod into `~/.factorio/mods`, builds the bridge, writes an RCON
password to `~/.config/crewmate/env`, and prints the one command you need to run
yourself to register the MCP server with Claude Code.

## Playing

    set -a; . ~/.config/crewmate/env; set +a
    bridge/crewmate serve -save ~/.factorio/saves/your-save.zip

Then join from the game: Multiplayer → Connect to address → `127.0.0.1`.

The server keeps its own write-data directory (`~/.local/share/factorio-crewmate`)
because the graphical game holds an exclusive lock on `~/.factorio` while you
play. It loads mods from `~/.factorio/mods`, so client and server agree.

## Driving it by hand

    bridge/crewmate call status
    bridge/crewmate call look '{"radius":48}'
    bridge/crewmate call say '{"message":"power is browning out at the north smelter"}'
    bridge/crewmate call walk_to '{"x":120,"y":-40}'
    bridge/crewmate call follow '{"player":"quartermeat"}'

In game, `/crew` reports where it is and `/crew come` calls it over.

## What v0.1 can and cannot do

It has senses and legs: status, surroundings, chat both ways, walking, following,
and screenshots. It has no hands yet — no building, mining, or crafting. That is
v0.2, deliberately, so the thing can be watched before it can touch anything.

Screenshots need a graphical client joined. A headless server has no renderer, so
`screenshot` asks a connected player's game to draw it, and fails cleanly when
nobody is connected.

## Gotchas worth knowing

- The first console command on a save answers Factorio's "this disables
  achievements" prompt instead of running, and says so only in the server log.
  The bridge repeats a silent command once, which is what the prompt wants.
- Single-player has no RCON at all; hosting is not optional.
- `helpers.table_to_json` renders an empty Lua table as `{}`, so empty lists come
  back as objects rather than arrays.
