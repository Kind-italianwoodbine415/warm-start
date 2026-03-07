# warm-start

<p align="center">
  <img src="image.png" alt="warm-start" width="600" />
</p>

automatic project intelligence for claude code, every session starts warm

## the problem

every claude code session starts cold, claude spends the first few minutes running `git status`, grepping around, reading files it has read fifty times before, after context compaction mid-session it loses orientation and does it all over again, this burns context window and your time on pure rediscovery

## the fix

a `SessionStart` hook that gathers project state and injects it directly into claude's context, it fires on new sessions, resumes, `/clear`, and critically, after every compaction, claude never starts blind

in about 1.4 seconds it collects:

- **git state** - branch, last commit, uncommitted changes with file list, upstream sync, stash count, merge/rebase detection
- **recent activity** - commits from the last 7 days, active branches
- **stack detection** - Node/Python/Rust/Go/Ruby/Java, framework (Next, React, Vue, Svelte, Angular, Rails), package manager (npm/pnpm/yarn/bun/uv/poetry)
- **key commands** - test, build, dev, lint extracted from package.json with the correct package manager
- **project structure** - top-level directories with file counts, skipped during compaction to save tokens
- **open PRs** - your PRs via `gh` CLI if available
- **custom learnings** - project-specific notes you persist across sessions

## install

requires `jq`, that is the only dependency

```
git clone https://github.com/chiefautism/warm-start.git
cd warm-start
bash install.sh
```

this does three things:

1. copies `warm-start.sh` to `~/.claude/scripts/`
2. installs a `/warm` skill to `~/.claude/skills/warm/`
3. adds a `SessionStart` hook to `~/.claude/settings.json`

no shell aliases, no wrappers, no background processes, it uses the hook system that already exists in claude code

## usage

it is automatic, open any project with `claude` and the context is already there, no action required

manual refresh mid-session:

```
/warm
```

use this after switching branches, pulling changes, or whenever context feels stale

per-project learnings:

create `.claude/warm-learnings.md` in any project to persist notes across sessions

```markdown
- build requires NODE_ENV=development or tests fail
- auth module uses strategy pattern, implementations in src/auth/strategies/
- run migrations with: pnpm db:migrate
- the legacy API is in src/api/v1/, do not modify without checking with the team
```

this file is read on every session start and included in the context brief

## example output

what claude sees when you open a svelte project:

```
# Project Intelligence (auto-generated)
Session: startup | 2026-03-07 20:33

## Git State
Branch: `main`
Last commit: lowercase (77d ago)
Working tree: 3 modified, 17 untracked
- package.json
- tsconfig.json
- yarn.lock
- src/App.svelte
- src/components/Header/Header.svelte
  ... and 15 more

## Stack
Svelte, TypeScript, Node (bun)

Key commands:
build: `bun run build` (vite build)
dev: `bun run dev` (vite)
check: `bun run check` (svelte-check --tsconfig ./tsconfig.json)

## Top-level Directories
- public/ (60 files)
- src/ (38 files)
```

after compaction, a leaner version re-fires automatically with git state and stack info, skipping structure and PRs to save tokens

## how it works

claude code has a `SessionStart` hook event, any text or JSON returned from the hook gets injected as context that claude can see and reason about, the hook fires on four triggers:

| trigger   | when                          | what warm-start does                              |
|-----------|-------------------------------|---------------------------------------------------|
| `startup` | new session                   | full brief: git, stack, structure, PRs, learnings |
| `resume`  | resumed session               | full brief                                        |
| `clear`   | after `/clear`                | full brief                                        |
| `compact` | after context compaction      | lean brief: git + stack only, saves tokens        |

the script outputs JSON with an `additionalContext` field per the SessionStart hook spec, no files are modified in your project, nothing is written to disk during the hook, it only reads

## files

```
~/.claude/scripts/warm-start.sh    - the hook script
~/.claude/skills/warm/SKILL.md     - /warm slash command
~/.claude/settings.json            - hook registration (SessionStart)
```

## uninstall

remove the hook entry from `~/.claude/settings.json` under `hooks.SessionStart`, then delete the script and skill:

```
rm ~/.claude/scripts/warm-start.sh
rm -r ~/.claude/skills/warm
```

## why this exists

the biggest bottleneck in a claude code session is not intelligence, it is context, claude is powerful but starts every session knowing nothing about your project, CLAUDE.md helps with stable conventions but it is static, auto-memory saves random notes but it is unstructured

what was missing is dynamic, zero-maintenance context injection that adapts to your current project state every single time, the kind of briefing a senior engineer would want before picking up someone else's work, what branch, what changed, what is the stack, what commands work, what should i know

now it happens automatically in 1.4 seconds, and it re-fires after compaction so long sessions do not degrade
