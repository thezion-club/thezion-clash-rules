# AGENTS.md
Same file in every project. Project-specific rules go in project.md, not here.

## Memory files
| File | Holds | Lifetime |
|--|--|--|
| `project.md` | Structure, rules, decisions, long-term memory | Permanent; update when a decision is made or a todo.md item closes |
| `context.md` | Current chat only: work in progress, open questions. No decided items | Reset to the template below before each commit |
| `todo.md` | Project-level unfinished work (features, fixes, setup, questions). Not day-to-day tasks | Removed when the host agent verifies it done |
| `memories/task-state.md` | Checkpoint of the day-to-day task or job in progress | Overwritten as work moves; `Job: none` when idle |
| `memories/task-todo.md` | Day-to-day follow-ups from tasks and runs | Removed when done |

Other files in `memories/` are project reference data, listed in project.md. If project.md names other files for task state or task todo, use those.

## Session start
Read project.md, context.md, todo.md and the task state and task todo files.

## todo.md workflow
Format: `- [ ] <item> – <owner> – since YYYY-MM-DD`
1. Any agent may mark an item done: `- [x] <item> – done YYYY-MM-DD by <agent>: <evidence>`. Agents never delete items.
2. The host agent (main chat) checks the evidence. If verified, remove the line and record any lasting result in project.md. If not, set it back to `[ ]` with a short note.

## Before each commit
1. Move decided items from context.md to project.md, and lasting open items to todo.md or the task todo file.
2. Close verified `[x]` items in todo.md.
3. Reset context.md to this template:
```
# Context (short-term memory)
Current chat only. Reset to this template before each commit (see AGENTS.md).

## In progress
- None.
```
`.githooks/pre-commit` blocks a commit while context.md has any list item other than `- None.` (enabled with `git config core.hooksPath .githooks`).
