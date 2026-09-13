# Agent guide: crewmate

An AI-controlled Factorio companion: a mod that gives an agent a body, and a Go
bridge that lets one drive it. Read `README.md` for what it is and where it is
going; this file is how to work on it.

## Layout

- `mod/script/body.lua` — the character and its movement. Nothing in here may
  assume a player is attached: no cursor stacks, no GUIs, no `build_from_cursor`.
- `mod/script/senses.lua` — everything the companion can report. Must work on a
  server with nobody logged in, so prefer entity state over player alerts.
- `mod/script/api.lua` — the RCON-facing seam. New calls go through `guarded()`
  so a Lua error returns as a message instead of a dropped reply.
- `bridge/` — one Go package, stdlib only. `rcon.go` is the protocol, `game.go`
  the call convention, `mcp.go` the tool surface, `main.go` the CLI.

## The shape of the thing

The character is called **Agent**, not after any model, because a model is not
what drives it. Work belongs in scripted loops, not in a model's context. A directive runs from a
data file through the mod's own tick handler; nothing calls out to an agent to
decide the next step. When something goes wrong the runner stops, records why, and
says so in chat -- that is the point at which a person or an agent is worth
involving. Adding a feature that needs a model in the loop to work at all is
going the wrong way.

## Rules that matter

- Keep the body fair: no cheat mode, no indestructible flag, no conjuring items,
  no teleporting where walking would do. The point of the project is a companion
  bound by the same rules as the player.
- Every interface call returns `{ok, result}` or `{ok=false, error}`.
- A game-side failure is a tool result flagged `isError`, never a protocol error:
  the model should read the message and act on it.
- Prefer a condition to a decision made elsewhere. If a directive needs to know
  whether to do something, that belongs in `when`, not in a prompt.
- Directives are data. A new goal should be a new file in `directives/`, not new
  Lua. If it cannot be expressed in the existing verbs, add a verb.
- Layout belongs in blueprint strings, which the game generates and validates.
  Hand-written coordinates do not survive rotation or fluid alignment.
- New tools need a description that says what the answer is good for, not just
  what the function is called.

## Two script contexts

`/c` and `/sc` run in the **scenario's** script, not the mod's: `storage` there is
the scenario's, and the mod's own state is invisible. Anything that needs to see
mod state goes through `remote.call("crewmate", ...)`, tests included. This costs
an hour if you learn it the hard way.

## Testing

    cd bridge && go test ./...
    CREWMATE_INTEGRATION=1 go test -run Integration -v

The integration test creates its own map, mod directory and server in a temp
directory, so it can run while you are playing. Everything else is fast and
needs no game.

Iterating on mod code means restarting the server (~1.6s); `serve -watch mod`
automates it. Stop a headless server with SIGTERM, never SIGINT: with stdin at
EOF it takes SIGINT into a half-quit state where it answers RCON connections but
never replies, and then ignores SIGTERM too.

For poking at a live game by hand, `crewmate call <fn> '<json>'` and
`crewmate exec '<console command>'`.

## Versioning

`VERSION`, `mod/info.json` and the `version` constant in `bridge/main.go` move
together, and every commit carries a `vMAJOR.MINOR.PATCH:` subject and an
annotated tag. The mod is linked into `~/.factorio/mods/crewmate` without a
version suffix so a bump does not mean relinking.
