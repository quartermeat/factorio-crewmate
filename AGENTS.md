# Agent guide: crewmate

## Layout

- `mod/` is the Factorio mod, symlinked into `~/.factorio/mods/crewmate_0.1.0`.
  `mod/script/body.lua` owns the character and its movement, `senses.lua` owns
  everything it can report, `api.lua` is the RCON-facing seam.
- `bridge/` is a single-package Go program, stdlib only.

## Conventions

- Every remote interface call returns a JSON string shaped `{ok, result}` or
  `{ok=false, error}`. Add new calls through `guarded()` so a Lua error comes back
  as a message instead of a dropped RCON reply.
- The body must stay a real character: no cheat mode, no indestructible flag, no
  teleporting where walking would do. Anything that would embarrass a human
  player should embarrass this one.
- Keep the mod side free of anything that only works with a player attached
  (`build_from_cursor`, cursor stacks, GUIs): there is no player behind this body.

## Testing

Nothing here needs a graphical client except screenshots:

    export CREWMATE_RCON_PASSWORD=test
    bridge/crewmate serve -save ~/.factorio/saves/fast-forward-fleet.zip &
    bridge/crewmate call status

The server writes to `~/.local/share/factorio-crewmate`, never `~/.factorio`, so
it can run while the real game is open.
