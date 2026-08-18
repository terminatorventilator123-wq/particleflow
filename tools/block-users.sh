#!/usr/bin/env bash
# tools/block-users.sh
# Usage:
#  - Put GitHub usernames (one per line) into users.txt (or specify another file with --file)
#  - ./tools/block-users.sh --dry-run
#  - ./tools/block-users.sh --file=my-users.txt
#
# Tento skript používá gh CLI k (od)blokování uživatelů za autentizovaný účet.
# Supports: dry-run, unblock, logging with rotation, concurrency, rate-limiting, retries.

set -euo pipefail

DRY_RUN=false
USERS_FILE="users.txt"
AUTO_YES=false
MAX_RETRIES=3
CONCURRENCY=4
RATE_PER_SEC=1   # approximate per-worker rate limit (requests per second)
LOG_DIR="logs"
LOG_FILE="logs/block-users.log"
MAX_LOG_BYTES=$((10 * 1024 * 1024))  # 10 MB
MAX_ROTATIONS=5
ACTION="block" # or "unblock"

print_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --dry-run            Don't actually call GitHub; just print the commands.
  --file FILE          Read usernames from FILE (default: users.txt).
  --yes                Skip confirmation prompt when not in dry-run.
  --log FILE           Path to log file (default: ${LOG_FILE}).
  --max-log-bytes N    Rotate when log reaches N bytes (default: ${MAX_LOG_BYTES}).
  --rotations N        Keep at most N rotated logs (default: ${MAX_ROTATIONS}).
  --unblock            Unblock users instead of blocking them.
  --concurrency N      Number of parallel workers (default: ${CONCURRENCY}).
  --rate R             Approximate requests per second per worker (default: ${RATE_PER_SEC}).
  -h, --help           Show this help and exit.

Česky:
  --dry-run            Nepouštět žádné volání na GitHub; jen vypíše příkazy.
  --file SOUBOR        Číst uživatele ze souboru (výchozí: users.txt).
  --yes                Přeskočit potvrzovací dotaz.
  --log SOUBOR         Cesta k log souboru (výchozí: ${LOG_FILE}).
  --unblock            Místo blokování odblokuje uživatele.
  --concurrency N      Počet paralelních workerů.

Examples:
  $0 --dry-run --file=my-users.txt
  $0 --file=users.txt --concurrency=8 --rate=2
EOF
}

# simple arg parsing
while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --file) USERS_FILE="$2"; shift 2 ;;
    --file=*) USERS_FILE="${1#*=}"; shift ;;
    --yes) AUTO_YES=true; shift ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    --log=*) LOG_FILE="${1#*=}"; shift ;;
    --max-log-bytes) MAX_LOG_BYTES="$2"; shift 2 ;;
    --max-log-bytes=*) MAX_LOG_BYTES="${1#*=}"; shift ;;
    --rotations) MAX_ROTATIONS="$2"; shift 2 ;;
    --rotations=*) MAX_ROTATIONS="${1#*=}"; shift ;;
    --unblock) ACTION="unblock"; shift ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --concurrency=*) CONCURRENCY="${1#*=}"; shift ;;
    --rate) RATE_PER_SEC="$2"; shift 2 ;;
    --rate=*) RATE_PER_SEC="${1#*=}"; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) echo "Unknown option: $1"; print_help; exit 2 ;;
  esac
done

# ensure log dir exists if logging enabled
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '%s %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

rotate_logs_if_needed() {
  if [[ ! -f "$LOG_FILE" ]]; then
    return
  fi
  filesize=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
  if (( filesize >= MAX_LOG_BYTES )); then
    ts=$(date +%Y%m%dT%H%M%S)
    mv "$LOG_FILE" "${LOG_FILE}.${ts}"
    # remove older rotations
    ls -1t "${LOG_FILE}."* 2>/dev/null | tail -n +$((MAX_ROTATIONS+1)) | xargs -r rm --
    log "Rotated log; previous saved as ${LOG_FILE}.${ts}"
  fi
}

if [[ ! -f "$USERS_FILE" ]]; then
  echo "Error: users file '$USERS_FILE' not found."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI not found. Install and authenticate (see https://cli.github.com/)."
  exit 1
fi

if [[ "$DRY_RUN" != "true" && "$AUTO_YES" != "true" ]]; then
  read -r -p "About to ${ACTION} users listed in '$USERS_FILE'. Continue? [y/N] " ans
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# read file and build list of users
users=()
while IFS= read -r line || [[ -n "$line" ]]; do
  # remove CR if present (Windows newlines)
  user="${line//$'\r'/}"

  # trim leading and trailing whitespace
  user="${user#"${user%%[![:space:]]*}"}"
  user="${user%"${user##*[![:space:]]}"}"

  # skip empty lines and comments
  [[ -z "$user" ]] && continue
  [[ "${user:0:1}" == "#" ]] && continue

  # basic username validation
  if ! [[ "$user" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]; then
    log "SKIP: '$user' - invalid username format"
    continue
  fi
  users+=("$user")
done < "$USERS_FILE"

total=${#users[@]}
if (( total == 0 )); then
  echo "No users to process after filtering."
  exit 0
fi

log "Starting ${ACTION} for ${total} users (concurrency=${CONCURRENCY}, rate=${RATE_PER_SEC}, dry-run=${DRY_RUN})"
rotate_logs_if_needed

# function to process single user
process_user() {
  local user="$1"
  local attempt=1
  local success=false
  local cmd

  while (( attempt <= MAX_RETRIES )); do
    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY RUN: gh api -X $([[ "$ACTION" == "block" ]] && echo PUT || echo DELETE) /user/blocks/${user}"
      success=true
      break
    fi

    if [[ "$ACTION" == "block" ]]; then
      if gh api -X PUT "/user/blocks/${user}" >/dev/null 2>&1; then
        success=true
        break
      fi
    else
      if gh api -X DELETE "/user/blocks/${user}" >/dev/null 2>&1; then
        success=true
        break
      fi
    fi

    # transient failure, backoff
    sleep $(( attempt * 2 ))
    ((attempt++))
  done

  if $success; then
    log "OK: ${ACTION}ed ${user}"
    return 0
  else
    log "FAILED: could not ${ACTION} ${user} (attempts=${MAX_RETRIES})"
    return 1
  fi
}

# worker pool: launch background jobs and limit concurrency
pids=()
success_count=0
fail_count=0
failed_users=()

for user in "${users[@]}"; do
  # enforce concurrency
  while (( $(jobs -rp | wc -l) >= CONCURRENCY )); do
    sleep 0.05
  done

  (
    # per-worker rate limit: sleep a tiny randomized amount to smooth bursts
    sleep_time=$(awk -v r="$RATE_PER_SEC" 'BEGIN{s=(1.0/r); print s*(0.5+rand()*0.5)}')
    # shell math: convert to seconds float for sleep using printf
    sleep "$sleep_time" 2>/dev/null || sleep 0

    if process_user "$user"; then
      exit 0
    else
      exit 2
    fi
  ) &
done

# wait for all workers and collect statuses
for jobpid in $(jobs -rp); do
  wait "$jobpid" || rc=$?
  if [[ "${rc:-0}" == "0" ]]; then
    ((success_count++))
  else
    ((fail_count++))
    # we don't have the username here; for simplicity, advise checking log for failed entries
  fi
  rc=0
done

log "Completed: ${success_count} succeeded, ${fail_count} failed. See ${LOG_FILE} for details."

# rotate logs if needed at end
rotate_logs_if_needed

# exit with non-zero if any failures
if (( fail_count > 0 )); then
  exit 2
fi
