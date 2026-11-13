#!/usr/bin/env bash

VERSION="1.1.0"

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
DIM=$'\033[2m'
RESET=$'\033[0m'

SITES_DIR="${VALIDATE_REPOS_DIR:-${HOME}/Sites}"
FILTER=""
VERBOSE=false

usage() {
  cat <<EOF
Usage: validate-local-repos [options] [dir]
Pulls every git repo directly under dir (default: \$VALIDATE_REPOS_DIR, else ~/Sites).
Options:
  -v, --verbose       Show raw git output
  --only-errors       Show only repos with errors
  --only-updated      Show only repos that pulled new commits
  -h, --help          Show this help
  --version           Show version
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)    VERBOSE=true ;;
    --only-errors)   FILTER="errors" ;;
    --only-updated)  FILTER="updated" ;;
    -h|--help)       usage; exit 0 ;;
    --version)       echo "$VERSION"; exit 0 ;;
    -*) printf "Unknown option: %s\n" "$1" >&2; usage; exit 2 ;;
    *)               SITES_DIR="$1" ;;
  esac
  shift
done

if [[ ! -d "$SITES_DIR" ]]; then
  printf "Not a directory: %s\n" "$SITES_DIR" >&2
  exit 2
fi
SITES_DIR="${SITES_DIR%/}"

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes"

clean_error() {
  local msg="$1"
  if [[ "$msg" == *"no tracking information"* ]] || [[ "$msg" == *"no such ref was fetched"* ]]; then
    echo "no upstream tracking branch"
  elif [[ "$msg" == *"divergent branches"* ]] || [[ "$msg" == *"Need to specify how to reconcile"* ]]; then
    echo "divergent branches (needs rebase/merge config)"
  elif [[ "$msg" == *"Repository not found"* ]] || [[ "$msg" == *"repository"*"not found"* ]]; then
    echo "repository not found"
  elif [[ "$msg" == *"Authentication failed"* ]] || [[ "$msg" == *"authentication required"* ]] || [[ "$msg" == *"could not read Username"* ]] || [[ "$msg" == *"do not authenticate"* ]]; then
    echo "authentication failed"
  elif [[ "$msg" == *"would clobber existing tag"* ]]; then
    echo "tag conflict"
  elif [[ "$msg" == *"Could not read from remote"* ]]; then
    echo "remote not accessible"
  else
    # Prefer a fatal: line, then an error: line, else the last non-empty line.
    # Capture into vars first: piping grep|head|sed makes the pipeline exit 0
    # even when grep matches nothing, so a trailing `|| echo` never fires.
    local fatal_line error_line
    fatal_line=$(grep -i "^fatal:" <<< "$msg" | head -1 | sed 's/^[Ff]atal: //')
    error_line=$(grep -i "^error:" <<< "$msg" | head -1 | sed 's/^[Ee]rror: //')
    if [[ -n "$fatal_line" ]]; then
      echo "$fatal_line"
    elif [[ -n "$error_line" ]]; then
      echo "$error_line"
    else
      grep -v '^[[:space:]]*$' <<< "$msg" | tail -1
    fi
  fi
}

# Pass 1: local-only scan for column widths + launch background fetches
max_name=4
max_branch=6
dirs=()
fetch_pids=()
fetch_files=()

for dir in "$SITES_DIR"/*/; do
  [[ -d "$dir/.git" ]] || continue
  git -C "$dir" remote | grep -q . || continue
  branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)
  [[ -z "$branch" ]] && branch="(detached)"
  dirs+=("$dir")
  name=$(basename "$dir")
  [[ ${#name} -gt $max_name ]] && max_name=${#name}
  [[ ${#branch} -gt $max_branch ]] && max_branch=${#branch}
  fetch_file=$(mktemp)
  fetch_files+=("$fetch_file")
  git -C "$dir" fetch --all >"$fetch_file" 2>&1 &
  fetch_pids+=($!)
done

# Print header
printf "${DIM}%-${max_name}s  %-${max_branch}s  %s  %s${RESET}\n" "REPO" "BRANCH" " " "STATUS"
printf "${DIM}%s  %s  %s  %s${RESET}\n" \
  "$(printf '%0.s-' $(seq 1 $max_name))" \
  "$(printf '%0.s-' $(seq 1 $max_branch))" \
  "-" \
  "------"

n_current=0
n_updated=0
n_attention=0
n_errors=0

# status: current | updated | attention | error
print_row() {
  local name="$1" branch="$2" status="$3" msg="$4" verbose_out="${5:-}"
  local symbol color
  case "$status" in
    current|updated) symbol="${GREEN}✓${RESET}"; color="$GREEN" ;;
    attention)       symbol="${YELLOW}⚠${RESET}"; color="$YELLOW" ;;
    error)           symbol="${RED}✗${RESET}";   color="$RED" ;;
  esac
  case "$FILTER" in
    errors)  [[ "$status" != "error" ]]   && return ;;
    updated) [[ "$status" != "updated" ]] && return ;;
  esac
  printf "%-${max_name}s  ${BLUE}%-${max_branch}s${RESET}  %b  %b%s%b\n" \
    "$name" "$branch" "$symbol" "$color" "$msg" "$RESET"
  if [[ "$VERBOSE" == true && -n "$verbose_out" ]]; then
    while IFS= read -r line; do
      printf "  ${DIM}%s${RESET}\n" "$line"
    done <<< "$verbose_out"
  fi
}

local_changes() {
  local dir="$1"
  local status_out untracked modified out=""
  status_out=$(git -C "$dir" status --porcelain 2>/dev/null)
  [[ -z "$status_out" ]] && { echo ""; return; }
  untracked=$(printf '%s\n' "$status_out" | awk '/^\?\?/{c++} END{print c+0}')
  modified=$(printf '%s\n' "$status_out" | awk '!/^\?\?/{c++} END{print c+0}')
  [[ "$modified" -gt 0 ]] && out+=" [uncommitted]"
  [[ "$untracked" -gt 0 ]] && out+=" [${untracked} untracked]"
  echo "$out"
}

# Pass 2: wait for each fetch, compute ahead/behind, pull if appropriate
for i in "${!dirs[@]}"; do
  dir="${dirs[$i]}"
  name=$(basename "$dir")
  branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)
  [[ -z "$branch" ]] && branch="(detached)"

  wait "${fetch_pids[$i]}"
  fetch_exit=$?
  fetch_output=$(cat "${fetch_files[$i]}")
  rm -f "${fetch_files[$i]}"

  if [[ $fetch_exit -ne 0 ]]; then
    # A remote with refs that differ only in case can't be fully stored on a
    # case-insensitive filesystem (macOS) with git's 'files' backend. The
    # tracked branch still fetches fine, so flag it as attention and still
    # fast-forward, rather than failing the whole repo.
    # (Permanent fix: migrate the repo to the reftable backend.)
    if [[ "$fetch_output" == *"only differ in casing"* || "$fetch_output" == *"case-insensitive filesystem"* ]]; then
      ff_changes=$(local_changes "$dir")
      pulled=""
      if git -C "$dir" rev-parse "@{u}" >/dev/null 2>&1; then
        behind=$(git -C "$dir" rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)
        if [[ "$behind" -gt 0 && -z "$ff_changes" ]]; then
          git -C "$dir" pull --ff-only >/dev/null 2>&1 && pulled=", pulled ${behind}"
        fi
      fi
      ((n_attention++))
      print_row "$name" "$branch" "attention" "case-colliding ref skipped${pulled}${ff_changes}" "$fetch_output"
      continue
    fi
    ((n_errors++))
    print_row "$name" "$branch" "error" "fetch: $(clean_error "$fetch_output")" "$fetch_output"
    continue
  fi

  if [[ "$branch" == "(detached)" ]]; then
    ((n_attention++))
    changes=$(local_changes "$dir")
    print_row "$name" "$branch" "attention" "detached HEAD${changes}"
    continue
  fi

  # Check upstream exists
  if ! git -C "$dir" rev-parse "@{u}" >/dev/null 2>&1; then
    ((n_attention++))
    changes=$(local_changes "$dir")
    print_row "$name" "$branch" "attention" "no upstream set${changes}"
    continue
  fi

  ahead_behind=$(git -C "$dir" rev-list --left-right --count "HEAD...@{u}" 2>/dev/null)
  ahead="${ahead_behind%$'\t'*}"
  behind="${ahead_behind#*$'\t'}"
  ahead="${ahead:-0}"
  behind="${behind:-0}"

  changes=$(local_changes "$dir")

  if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
    ((n_current++))
    print_row "$name" "$branch" "current" "up to date${changes}"

  elif [[ "$ahead" -gt 0 && "$behind" -eq 0 ]]; then
    ((n_attention++))
    print_row "$name" "$branch" "attention" "↑ ${ahead} ahead${changes}"

  elif [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then
    ((n_attention++))
    print_row "$name" "$branch" "attention" "↕ ${ahead} ahead, ${behind} behind${changes}"

  elif [[ "$ahead" -eq 0 && "$behind" -gt 0 ]]; then
    if [[ -n "$changes" ]]; then
      ((n_attention++))
      print_row "$name" "$branch" "attention" "↓ ${behind} behind${changes}"
    else
      pull_output=$(git -C "$dir" pull --ff-only 2>&1)
      pull_exit=$?
      if [[ $pull_exit -ne 0 ]]; then
        ((n_errors++))
        print_row "$name" "$branch" "error" "pull: $(clean_error "$pull_output")" "$pull_output"
      else
        ((n_updated++))
        print_row "$name" "$branch" "updated" "✓ pulled ${behind} commit(s)" "$pull_output"
      fi
    fi
  fi
done

# Summary
total=$(( n_current + n_updated + n_attention + n_errors ))
printf "\n${DIM}%s${RESET}\n" "$(printf '%0.s-' $(seq 1 $(( max_name + max_branch + 12 ))))"
printf "total: %d  ${GREEN}✓${RESET} %d up to date  ${GREEN}✓${RESET} %d pulled  ${YELLOW}⚠${RESET} %d attention  ${RED}✗${RESET} %d errors\n" \
  "$total" "$n_current" "$n_updated" "$n_attention" "$n_errors"
