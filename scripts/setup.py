#!/usr/bin/env python3
"""Idempotent setup for crewmate: mod symlink, built bridge, RCON password.

Everything here is safe to re-run. Registering the MCP server with Claude Code is
left as a command for you to run, since the agent does not edit its own config.
"""

import os
import secrets
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MODS = Path.home() / ".factorio" / "mods"
LINK = MODS / "crewmate_0.1.0"
ENV = Path.home() / ".config" / "crewmate" / "env"


def link_mod() -> None:
    MODS.mkdir(parents=True, exist_ok=True)
    target = REPO / "mod"
    if LINK.is_symlink() and LINK.resolve() == target:
        print(f"mod already linked: {LINK}")
        return
    if LINK.exists() or LINK.is_symlink():
        LINK.unlink()
    LINK.symlink_to(target)
    print(f"linked {LINK} -> {target}")


def build_bridge() -> None:
    subprocess.run(["go", "build", "-o", "crewmate", "."], cwd=REPO / "bridge", check=True)
    print(f"built {REPO / 'bridge' / 'crewmate'}")


def write_password() -> str:
    if ENV.exists():
        for line in ENV.read_text().splitlines():
            if line.startswith("CREWMATE_RCON_PASSWORD="):
                print(f"rcon password already set in {ENV}")
                return line.split("=", 1)[1]
    ENV.parent.mkdir(parents=True, exist_ok=True)
    password = secrets.token_urlsafe(24)
    ENV.write_text(f"CREWMATE_RCON_PASSWORD={password}\n")
    ENV.chmod(0o600)
    print(f"wrote a new rcon password to {ENV}")
    return password


def main() -> int:
    link_mod()
    build_bridge()
    write_password()
    binary = REPO / "bridge" / "crewmate"
    print(
        "\nRegister the MCP server with Claude Code by running:\n\n"
        f"  claude mcp add crewmate --scope user -- {binary} mcp\n\n"
        "The bridge reads the password from that file, so nothing secret goes in\n"
        "Claude Code's config. Then host a game:\n\n"
        f"  {binary} serve -save ~/.factorio/saves/fast-forward-fleet.zip\n\n"
        "and join it from the game at 127.0.0.1."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
