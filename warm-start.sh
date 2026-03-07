#!/usr/bin/env bash
# warm-start.sh - Project Intelligence for Claude Code
# SessionStart hook that gathers project state and injects it as context.
# Fires on: new sessions, resumes, /clear, and compaction.
#
# Output: JSON with additionalContext for the SessionStart hook.
# Target execution time: < 2 seconds.

set -uo pipefail

# Read hook input from stdin (JSON with session_id, source, cwd, etc.)
HOOK_INPUT=""
if [ ! -t 0 ]; then
  HOOK_INPUT=$(cat)
fi

SESSION_SOURCE=$(echo "$HOOK_INPUT" | jq -r '.source // "startup"' 2>/dev/null || echo "startup")
PROJECT_DIR=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(pwd)"
fi

cd "$PROJECT_DIR" 2>/dev/null || exit 0

# ── Helpers ──────────────────────────────────────────────────────────────

brief=""

emit() {
  brief+="$1"$'\n'
}

emit_section() {
  brief+=$'\n'"## $1"$'\n'
}

# Run a command with a timeout (default 2s). Return empty on failure.
timed() {
  timeout 2 "$@" 2>/dev/null || true
}

# Relative time description from unix timestamp
relative_time() {
  local now ts diff
  now=$(date +%s)
  ts=$1
  diff=$((now - ts))
  if [ $diff -lt 60 ]; then echo "${diff}s ago"
  elif [ $diff -lt 3600 ]; then echo "$((diff / 60))m ago"
  elif [ $diff -lt 86400 ]; then echo "$((diff / 3600))h ago"
  else echo "$((diff / 86400))d ago"; fi
}

# ── Git Intelligence ─────────────────────────────────────────────────────

gather_git() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    return
  fi

  local branch head_msg head_ts head_rel stash_count
  branch=$(git branch --show-current 2>/dev/null || echo "detached")

  # Last commit info
  head_msg=$(git log -1 --format='%s' 2>/dev/null || echo "")
  head_ts=$(git log -1 --format='%ct' 2>/dev/null || echo "")
  head_rel=""
  if [ -n "$head_ts" ] && [ "$head_ts" != "" ]; then
    head_rel=$(relative_time "$head_ts")
  fi

  emit_section "Git State"
  emit "Branch: \`$branch\`"
  if [ -n "$head_msg" ]; then
    emit "Last commit: $head_msg ($head_rel)"
  fi

  # Uncommitted changes
  local status_output changed staged untracked
  status_output=$(git status --porcelain 2>/dev/null || echo "")
  if [ -n "$status_output" ]; then
    changed=$(echo "$status_output" | grep -c '^ M\|^MM\|^ D' || true)
    staged=$(echo "$status_output" | grep -c '^M \|^A \|^D \|^R ' || true)
    untracked=$(echo "$status_output" | grep -c '^??' || true)
    local parts=()
    [ "$staged" -gt 0 ] && parts+=("$staged staged")
    [ "$changed" -gt 0 ] && parts+=("$changed modified")
    [ "$untracked" -gt 0 ] && parts+=("$untracked untracked")
    emit "Working tree: $(IFS=', '; echo "${parts[*]}")"

    # List the actual changed files (max 15)
    local changed_files
    changed_files=$(echo "$status_output" | head -15 | awk '{print $2}' | sed 's/^/- /')
    emit "$changed_files"
    local total_changes
    total_changes=$(echo "$status_output" | wc -l | tr -d ' ')
    if [ "$total_changes" -gt 15 ]; then
      emit "- ... and $((total_changes - 15)) more"
    fi
  else
    emit "Working tree: clean"
  fi

  # Stashes
  stash_count=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
  if [ "$stash_count" -gt 0 ]; then
    emit "Stashes: $stash_count"
  fi

  # Recent commits (last 7 days, max 10)
  local recent_log
  recent_log=$(timed git log --oneline --no-decorate --since="7 days ago" -10 2>/dev/null)
  if [ -n "$recent_log" ]; then
    emit_section "Recent Commits (7d)"
    emit "$recent_log"
  fi

  # Branches with recent activity
  local active_branches
  active_branches=$(timed git branch --sort=-committerdate --format='%(refname:short) (%(committerdate:relative))' -5 2>/dev/null | head -5)
  if [ -n "$active_branches" ] && [ "$(echo "$active_branches" | wc -l | tr -d ' ')" -gt 1 ]; then
    emit_section "Active Branches"
    emit "$active_branches"
  fi

  # Merge/rebase state
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null)
  if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
    emit_section "REBASE IN PROGRESS"
  elif [ -f "$git_dir/MERGE_HEAD" ]; then
    emit_section "MERGE IN PROGRESS"
  elif [ -f "$git_dir/CHERRY_PICK_HEAD" ]; then
    emit_section "CHERRY-PICK IN PROGRESS"
  fi

  # Upstream status
  local upstream
  upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo "")
  if [ -n "$upstream" ]; then
    local ahead behind
    ahead=$(git rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo "0")
    behind=$(git rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo "0")
    if [ "$ahead" -gt 0 ] || [ "$behind" -gt 0 ]; then
      local sync_parts=()
      [ "$ahead" -gt 0 ] && sync_parts+=("$ahead ahead")
      [ "$behind" -gt 0 ] && sync_parts+=("$behind behind")
      emit "Upstream ($upstream): $(IFS=', '; echo "${sync_parts[*]}")"
    fi
  fi
}

# ── Stack Detection ──────────────────────────────────────────────────────

gather_stack() {
  local stack_parts=()
  local pkg_manager=""
  local scripts_info=""

  # Node.js ecosystem
  if [ -f "package.json" ]; then
    # Detect package manager
    if [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then pkg_manager="bun"
    elif [ -f "pnpm-lock.yaml" ]; then pkg_manager="pnpm"
    elif [ -f "yarn.lock" ]; then pkg_manager="yarn"
    elif [ -f "package-lock.json" ]; then pkg_manager="npm"
    else pkg_manager="npm"; fi

    # Detect framework from dependencies
    local deps
    deps=$(cat package.json)
    if echo "$deps" | jq -e '.dependencies.next // .devDependencies.next' &>/dev/null; then
      stack_parts+=("Next.js")
    elif echo "$deps" | jq -e '.dependencies.react // .devDependencies.react' &>/dev/null; then
      stack_parts+=("React")
    elif echo "$deps" | jq -e '.dependencies.vue // .devDependencies.vue' &>/dev/null; then
      stack_parts+=("Vue")
    elif echo "$deps" | jq -e '.dependencies.svelte // .devDependencies.svelte' &>/dev/null; then
      stack_parts+=("Svelte")
    elif echo "$deps" | jq -e '.dependencies["@angular/core"] // .devDependencies["@angular/core"]' &>/dev/null; then
      stack_parts+=("Angular")
    fi

    # TypeScript?
    if [ -f "tsconfig.json" ]; then
      stack_parts+=("TypeScript")
    else
      stack_parts+=("JavaScript")
    fi

    stack_parts+=("Node ($pkg_manager)")

    # Extract useful scripts
    local scripts
    scripts=$(echo "$deps" | jq -r '.scripts // {} | to_entries[] | "\(.key)=\(.value)"' 2>/dev/null | head -10)
    if [ -n "$scripts" ]; then
      # Pick the most useful ones
      local useful_scripts=()
      for key in test build dev start lint typecheck check format; do
        local val
        val=$(echo "$scripts" | grep "^${key}=" | head -1 | cut -d= -f2-)
        if [ -n "$val" ]; then
          useful_scripts+=("$key: \`$pkg_manager run $key\` ($val)")
        fi
      done
      if [ ${#useful_scripts[@]} -gt 0 ]; then
        scripts_info=$(printf '%s\n' "${useful_scripts[@]}")
      fi
    fi
  fi

  # Python
  if [ -f "pyproject.toml" ]; then
    stack_parts+=("Python (pyproject.toml)")
    if [ -f "uv.lock" ]; then stack_parts+=("uv")
    elif [ -f "poetry.lock" ]; then stack_parts+=("Poetry")
    elif [ -f "Pipfile.lock" ]; then stack_parts+=("Pipenv")
    fi
  elif [ -f "requirements.txt" ]; then
    stack_parts+=("Python (pip)")
  elif [ -f "setup.py" ]; then
    stack_parts+=("Python (setup.py)")
  fi

  # Rust
  if [ -f "Cargo.toml" ]; then
    stack_parts+=("Rust")
  fi

  # Go
  if [ -f "go.mod" ]; then
    local go_module
    go_module=$(head -1 go.mod | awk '{print $2}')
    stack_parts+=("Go ($go_module)")
  fi

  # Ruby
  if [ -f "Gemfile" ]; then
    stack_parts+=("Ruby")
    [ -f "config/routes.rb" ] && stack_parts+=("Rails")
  fi

  # Java/Kotlin
  if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
    stack_parts+=("Gradle")
  elif [ -f "pom.xml" ]; then
    stack_parts+=("Maven")
  fi

  # Docker
  if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ] || [ -f "compose.yml" ]; then
    stack_parts+=("Docker")
  fi

  if [ ${#stack_parts[@]} -gt 0 ]; then
    emit_section "Stack"
    local stack_str
    stack_str=$(IFS=', '; echo "${stack_parts[*]}")
    emit "$stack_str"
    if [ -n "$scripts_info" ]; then
      emit ""
      emit "**Key commands:**"
      emit "$scripts_info"
    fi
  fi
}

# ── Project Structure ────────────────────────────────────────────────────

gather_structure() {
  # Only on fresh starts in actual projects
  if [ "$SESSION_SOURCE" = "compact" ]; then return; fi
  if ! git rev-parse --is-inside-work-tree &>/dev/null && \
     ! [ -f "package.json" ] && ! [ -f "Cargo.toml" ] && ! [ -f "go.mod" ] && \
     ! [ -f "pyproject.toml" ] && ! [ -f "requirements.txt" ] && ! [ -f "Gemfile" ] && \
     ! [ -f "pom.xml" ] && ! [ -f "build.gradle" ] && ! [ -f "Makefile" ]; then
    return
  fi

  local top_dirs
  top_dirs=$(ls -d */ 2>/dev/null | head -20 | sed 's|/$||' | grep -v -E '^(node_modules|\.git|dist|build|\.next|__pycache__|\.venv|venv|target|\.cache|\.turbo|coverage)$' || true)
  if [ -n "$top_dirs" ]; then
    emit_section "Top-level Directories"
    local dir_listing=""
    while read -r d; do
      local count
      count=$(find "$d" -maxdepth 3 -type f 2>/dev/null | head -200 | wc -l | tr -d ' ')
      dir_listing+="- $d/ ($count files)"$'\n'
    done <<< "$top_dirs"
    emit "$dir_listing"
  fi
}

# ── Previous Session Learnings ───────────────────────────────────────────

gather_learnings() {
  local learnings_file="$PROJECT_DIR/.claude/warm-learnings.md"
  if [ -f "$learnings_file" ]; then
    local content
    content=$(head -50 "$learnings_file")
    if [ -n "$content" ]; then
      emit_section "Learnings from Previous Sessions"
      emit "$content"
    fi
  fi
}

# ── Open PRs (only if gh is available and fast) ──────────────────────────

gather_prs() {
  if ! command -v gh &>/dev/null; then return; fi
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then return; fi

  # Only on fresh starts
  if [ "$SESSION_SOURCE" = "compact" ]; then return; fi

  local prs
  prs=$(timeout 3 gh pr list --author @me --limit 5 --json number,title,headRefName,state \
    --jq '.[] | "- #\(.number) [\(.headRefName)] \(.title)"' 2>/dev/null || true)
  if [ -n "$prs" ]; then
    emit_section "Your Open PRs"
    emit "$prs"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────

emit "# Project Intelligence (auto-generated)"
emit "Session: $SESSION_SOURCE | $(date '+%Y-%m-%d %H:%M')"

gather_git
gather_stack
gather_structure
gather_learnings
gather_prs

# Output as SessionStart hook JSON
# The additionalContext field is injected into Claude's context.
jq -n --arg ctx "$brief" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
