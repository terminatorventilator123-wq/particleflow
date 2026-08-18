#!/usr/bin/env bash
# tools/block-users.sh
# Usage:
#  - Put GitHub usernames (one per line) into users.txt (or specify another file with --file)
#  - ./tools/block-users.sh --dry-run
#  - ./tools/block-users.sh --file=my-users.txt
#
# This script uses the `gh` CLI to block users on behalf of the authenticated account.
# It validates usernames, skips blank/comment lines, supports dry-run, retries transient failures,
# and prints a summary at the end.

set -euo pipefail

DRY_RUN=false
USERS_FILE="users.txt"
AUTO_YES=false
MAX_RETRIES=3

# simple arg parsing
while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --file) USERS_FILE="$2"; shift 2 ;;
    --file=*) USERS_FILE="${1#*=}"; shift ;;
    --yes) AUTO_YES=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--dry-run] [--file FILE] [--yes]
  --dry-run     Don't actually call GitHub; just print the commands.
  --file FILE   Read usernames from FILE (default: users.txt).
  --yes         Skip confirmation prompt when not in dry-run.
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
done

if [[ ! -f "$USERS_FILE" ]]; then
  echo "Error: users file '$USERS_FILE' not found."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI not found. Install and authenticate (see https://cli.github.com/)."
  exit 1
fi

if [[ "$DRY_RUN" != "true" && "$AUTO_YES" != "true" ]]; then
  read -r -p "About to block users listed in '$USERS_FILE'. Continue? [y/N] " ans
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

success_count=0
fail_count=0
failed_users=()

# read file safe for lines without trailing newline
while IFS= read -r line || [[ -n "$line" ]]; do
  # remove CR if present (Windows newlines)
  user="${line//$'\r'/}"

  # trim leading and trailing whitespace (but preserve internal spaces if any)
  user="${user#"${user%%[![:space:]]*}"}"
  user="${user%"${user##*[![:space:]]}"}"

  # skip empty lines and comments
  [[ -z "$user" ]] && continue
  [[ "${user:0:1}" == "#" ]] && continue

  # basic username validation: conservative (alphanum and hyphen, first char not hyphen, max 39)
  if ! [[ "$user" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]; then
    printf 'SKIP: "%s" - invalid username format\n' "$user"
    continue
  fi

  printf 'Blocking %s ... ' "$user"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf 'DRY RUN: gh api -X PUT /user/blocks/%s\n' "$user"
    ((success_count++))
    continue
  fi

  # attempt with retries for transient failures
  attempt=1
  blocked=false
  while (( attempt <= MAX_RETRIES )); do
    if gh api -X PUT "/user/blocks/$user" >/dev/null 2>&1; then
      blocked=true
      break
    else
      # backoff before retrying
      if (( attempt < MAX_RETRIES )); then
        sleep $(( attempt * 2 ))
      fi
    fi
    ((attempt++))
  done

  if [[ "$blocked" == "true" ]]; then
    echo "OK"
    ((success_count++))
  else
    echo "FAILED (see output or check token/permissions)"
    failed_users+=("$user")
    ((fail_count++))
  fi
done < "$USERS_FILE"

printf '\nSummary: %d succeeded, %d failed\n' "$success_count" "$fail_count"
if (( fail_count > 0 )); then
  echo "Failed users:"
  for u in "${failed_users[@]}"; do
    echo " - $u"
  done
fi

# Note: gh must be authenticated with a token that has permissions to manage blocking for your account.
# If you see failures, check 'gh auth status' and GitHub docs for the appropriate token permissions.
