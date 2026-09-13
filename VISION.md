# What Crewmate is

Crewmate is an embodied automation runtime for Factorio. It turns an intention
from a person or a software agent into fair, visible, persistent work carried out
by **Crew**, a character who exists in the same world as the player.

Crew is not the language model. The model may understand a new goal, choose a
known job, or help when one fails. The work itself belongs to deterministic
scripts running with the game. Crew keeps walking, mining, crafting and building
after the conversation ends, and the world remains the source of truth about
whether the job succeeded.

The aim is a teammate whose competence can grow without making its behaviour
mysterious. You should be able to watch Crew work, inspect its state, interrupt
it, understand a failure and run the same job again.

## The operating model

Responsibility moves down through six layers:

| Layer | Responsibility |
| --- | --- |
| Person | Gives intent, boundaries and permission for consequential work |
| Planner | Translates an unfamiliar goal into known capabilities and handles exceptions |
| Automaton | Pursues one explicit outcome through conditions, loops and other automata |
| Skills | Perform reusable operations such as finding, walking, mining, crafting and building |
| Body | Enforces position, reach, inventory, health and the passage of game time |
| Factorio world | Supplies the authoritative state and the evidence that an outcome exists |

The planner can be a person, a language model or another program. Replacing it
must not change the meaning of the lower layers. No particular model owns Crew's
identity or is required to keep routine work moving.

## Directives are automaton scripts

The files currently called **directives** are Crewmate's automaton scripts. Each
one should have one legible outcome, observe the world for itself and finish in a
structured state: `done`, `blocked`, `failed` or `cancelled`.

An automaton may use conditions, loops and smaller automata. This makes a large
goal a composition of independently useful jobs rather than one enormous script:

```text
bootstrap-electric-mining
├── acquire-starting-materials
├── establish-steam-power
├── build-coal-mining
├── connect-coal-to-boiler
└── verify-stable-power
```

The children remain callable on their own. The parent coordinates their outcomes
and passes named results between them. It does not copy their internal steps.

As the format matures, an automaton's contract should make these facts explicit:

- inputs and defaults;
- required items, capabilities and world conditions;
- named observations or locations it produces;
- the world condition that proves success;
- bounded retry and recovery behaviour;
- side effects a person may care about;
- the evidence returned when it finishes or stops.

Waiting should mean waiting for a condition in the world, not sleeping for an
arbitrary duration. Repeating a completed automaton should detect the existing
result and either return success or extend it deliberately. A save/load, bridge
restart or model disconnect should not erase work or make its state unknowable.

## What makes Crew a teammate

Crew occupies space. It must travel to a job, carry the materials, reach the
thing it acts on, spend the required time and live with what it built. Those
constraints are the substance of the project: they make help predictable and
give success meaning.

Crew also communicates. Long work announces what is happening and exposes
progress. A blocked job names the missing item, unreachable place or unmet
condition. Silence is not a valid running state because it is indistinguishable
from broken automation.

The person remains in authority. Standing orders are narrow, consequential
expansion is visible, current work can be stopped, and changes remain traceable
and reversible where the game permits it.

## What it is not

Crewmate is not:

- a remote control for the player's character;
- an omniscient factory optimizer acting from outside the world;
- a chat session that must choose every movement and placement;
- a cheat interface that creates items, ignores reach or teleports past work;
- a model-specific integration whose abilities disappear with one client.

The MCP bridge is a control and observation interface. It lets a model use Crew,
but it is not where Crew's durable behaviour should live.

## The long-term test

The project succeeds when a person can state a meaningful end goal, Crew can
assemble and run a chain of understandable automata, and the person can leave it
working without leaving a model reasoning about every tick.

When the chain finishes, success should be visible in the factory and supported
by machine-readable evidence. When it cannot finish, it should stop safely and
explain the smallest decision or resource needed to continue.
