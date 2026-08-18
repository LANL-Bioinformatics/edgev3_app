#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="2026.07.21"

############################
# Paths & logging
############################
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="$APP_DIR/docker_images"
LOG_DIR="$APP_DIR/logs"
LOG_FILE="$LOG_DIR/edgev3.log"
SECRETS_DIR="$APP_DIR/data/secrets"
SERVER_ENV_FILE="$APP_DIR/data/webapp_server.env"
SERVER_ENV_TEMPLATE="$APP_DIR/data/webapp_server.env.example"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

timestamp() { date +"[%Y-%m-%d %H:%M:%S]"; }
log() { echo "$(timestamp) $*"; }

############################
# Global flags & option parsing
############################
DRY_RUN=false
SHOW_HELP=false
SHOW_VERSION=false
ARCH="amd64"

ARGS=()
for arg in "$@"; do
  case "$arg" in
    --arch)        
      ARCH="${2:-}";
      shift 2 
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --help|-h)
      SHOW_HELP=true
      ;;
    --version|-V)
      SHOW_VERSION=true
      ;;
    -*)
      echo "ERROR: Unknown option '$arg'" >&2
      echo >&2
      usage >&2 || true
      exit 2
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

# Safe positional reset with set -u
if [ "${#ARGS[@]}" -gt 0 ]; then
  set -- "${ARGS[@]}"
else
  set --
fi

# Export default platform for docker commands
export DOCKER_DEFAULT_PLATFORM="linux/$ARCH"

############################
# Helpers
############################
run_cmd() {
  if $DRY_RUN; then
    log "[DRY-RUN] $*"
  else
    log "Running: $*"
    eval "$@"
  fi
}

generate_random_hex() {
  local byte_count="${1:-32}"

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$byte_count"
  elif [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
    od -An -N "$byte_count" -tx1 /dev/urandom | tr -d ' \n'
  else
    log "FATAL: openssl or /dev/urandom with od is required to generate secrets" >&2
    exit 1
  fi
}

generate_random_web_admin_password() {
  # Keep 128 bits of random entropy while guaranteeing every character class
  # required by the EDGEv3 login form and API validators.
  printf 'Aa1!%s' "$(generate_random_hex 16)"
}

web_admin_password_meets_policy() {
  local password="$1"

  [[ ${#password} -ge 8 ]] &&
    [[ "$password" =~ [A-Z] ]] &&
    [[ "$password" =~ [a-z] ]] &&
    [[ "$password" =~ [0-9] ]] &&
    [[ "$password" =~ [^A-Za-z0-9[:space:]] ]]
}

generate_random_six_digit_code() {
  local random_hex code

  while :; do
    random_hex="$(generate_random_hex 4)"
    printf -v code '%06d' "$((16#$random_hex % 1000000))"
    if [[ "$code" != "000000" ]]; then
      printf '%s' "$code"
      return
    fi
  done
}

set_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"
  local tmp_file="${file}.tmp.$$"

  (
    umask 077
    awk -v key="$key" -v value="$value" '
      index($0, key "=") == 1 {
        if (!found) {
          print key "=" value
          found = 1
        }
        next
      }
      { print }
      END {
        if (!found) {
          print key "=" value
        }
      }
    ' "$file" > "$tmp_file"
  )
  chmod 600 "$tmp_file"
  mv "$tmp_file" "$file"
}

normalize_secret_file() {
  local file="$1"
  local value tmp_file

  # mongodb/mongodb-community-server's Python entrypoint reads *_FILE values
  # verbatim. A trailing newline therefore becomes part of the MongoDB
  # username/password and causes SCRAM user creation to fail.
  value="$(tr -d '\r\n' < "$file")"
  if [[ -z "$value" ]]; then
    log "FATAL: Runtime secret is empty after normalization: $file"
    exit 1
  fi

  tmp_file="${file}.tmp.$$"
  (
    umask 077
    printf '%s' "$value" > "$tmp_file"
  )
  chmod 600 "$tmp_file"
  mv "$tmp_file" "$file"
}

prepare_runtime_config() {
  local -a secret_names=(
    mongo_root_user.txt
    mongo_root_pass.txt
    mongo_app_user.txt
    mongo_app_pass.txt
    mongo_admin_user.txt
    mongo_admin_pass.txt
  )
  local -a web_admin_secret_names=(
    edgev3_admin_password.txt
    edgev3_admin_code.txt
  )
  local existing_count=0
  local web_admin_existing_count=0
  local secret_name secret_path
  local mongo_root_pass mongo_app_user mongo_app_pass mongo_admin_pass
  local edgev3_admin_password edgev3_admin_code
  local jwt_secret current_jwt

  if $DRY_RUN; then
    log "[DRY-RUN] Would create missing runtime secrets and synchronize $SERVER_ENV_FILE"
    return
  fi

  mkdir -p "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"

  for secret_name in "${secret_names[@]}"; do
    secret_path="$SECRETS_DIR/$secret_name"
    if [[ -s "$secret_path" ]]; then
      ((existing_count += 1))
    fi
  done

  if (( existing_count == 0 )); then
    log "Generating MongoDB credentials for first start..."
    mongo_root_pass="$(generate_random_hex 32)"
    mongo_app_pass="$(generate_random_hex 32)"
    mongo_admin_pass="$(generate_random_hex 32)"
    (
      umask 077
      printf '%s' 'root' > "$SECRETS_DIR/mongo_root_user.txt"
      printf '%s' "$mongo_root_pass" > "$SECRETS_DIR/mongo_root_pass.txt"
      printf '%s' 'edgev3_app' > "$SECRETS_DIR/mongo_app_user.txt"
      printf '%s' "$mongo_app_pass" > "$SECRETS_DIR/mongo_app_pass.txt"
      printf '%s' 'edgev3_admin' > "$SECRETS_DIR/mongo_admin_user.txt"
      printf '%s' "$mongo_admin_pass" > "$SECRETS_DIR/mongo_admin_pass.txt"
    )
  elif (( existing_count != ${#secret_names[@]} )); then
    log "FATAL: MongoDB secrets are only partially initialized."
    log "Restore the missing files, or remove all files in $SECRETS_DIR and run init to create a new database with new credentials."
    exit 1
  else
    log "Using existing MongoDB credentials."
  fi

  for secret_name in "${web_admin_secret_names[@]}"; do
    secret_path="$SECRETS_DIR/$secret_name"
    if [[ -s "$secret_path" ]]; then
      ((web_admin_existing_count += 1))
    fi
  done

  if (( web_admin_existing_count == 0 )); then
    log "Generating the initial EDGEv3 web administrator credentials..."
    edgev3_admin_password="$(generate_random_web_admin_password)"
    edgev3_admin_code="$(generate_random_six_digit_code)"
    (
      umask 077
      printf '%s' "$edgev3_admin_password" > "$SECRETS_DIR/edgev3_admin_password.txt"
      printf '%s' "$edgev3_admin_code" > "$SECRETS_DIR/edgev3_admin_code.txt"
    )
    log "Initial admin login: admin@my.edge"
    log "Initial admin password saved to $SECRETS_DIR/edgev3_admin_password.txt"
  elif (( web_admin_existing_count != ${#web_admin_secret_names[@]} )); then
    log "FATAL: EDGEv3 web administrator secrets are only partially initialized."
    log "Restore the missing file, or remove both edgev3_admin_*.txt files and start again to rotate the bootstrap credential."
    exit 1
  else
    edgev3_admin_password="$(tr -d '\r\n' < "$SECRETS_DIR/edgev3_admin_password.txt")"
    if web_admin_password_meets_policy "$edgev3_admin_password"; then
      log "Using existing EDGEv3 web administrator bootstrap credentials."
    else
      log "Existing EDGEv3 web administrator password does not meet the current password policy; rotating it."
      edgev3_admin_password="$(generate_random_web_admin_password)"
      (
        umask 077
        printf '%s' "$edgev3_admin_password" > "$SECRETS_DIR/edgev3_admin_password.txt"
      )
      log "Updated admin password saved to $SECRETS_DIR/edgev3_admin_password.txt"
    fi
  fi

  for secret_name in "${secret_names[@]}" "${web_admin_secret_names[@]}"; do
    normalize_secret_file "$SECRETS_DIR/$secret_name"
  done
  chmod 600 "$SECRETS_DIR"/*.txt

  mongo_app_user="$(tr -d '\r\n' < "$SECRETS_DIR/mongo_app_user.txt")"
  mongo_app_pass="$(tr -d '\r\n' < "$SECRETS_DIR/mongo_app_pass.txt")"
  if [[ ! "$mongo_app_user" =~ ^[A-Za-z0-9._~-]+$ ]] ||
     [[ ! "$mongo_app_pass" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    log "FATAL: MongoDB app credentials contain characters that are unsafe in DATABASE_HOST."
    exit 1
  fi

  if [[ ! -f "$SERVER_ENV_FILE" ]]; then
    [[ -f "$SERVER_ENV_TEMPLATE" ]] || {
      log "FATAL: Missing server environment template $SERVER_ENV_TEMPLATE"
      exit 1
    }
    log "Creating server environment for first start..."
    (
      umask 077
      cp "$SERVER_ENV_TEMPLATE" "$SERVER_ENV_FILE"
    )
  fi

  current_jwt="$(awk -F= '/^JWT_SECRET=/{print substr($0, index($0, "=") + 1); exit}' "$SERVER_ENV_FILE")"
  if [[ -z "$current_jwt" || "$current_jwt" == "__GENERATED_ON_FIRST_START__" ]]; then
    jwt_secret="$(generate_random_hex 32)"
    set_env_value "JWT_SECRET" "$jwt_secret" "$SERVER_ENV_FILE"
  fi

  set_env_value \
    "DATABASE_HOST" \
    "$mongo_app_user:$mongo_app_pass@mongodb" \
    "$SERVER_ENV_FILE"
  chmod 600 "$SERVER_ENV_FILE"
  log "Server DATABASE_HOST is synchronized with the MongoDB app credentials."
}

############################
# Image definitions
############################
IMAGES=(
    "nginx nginx_latest_$ARCH.tgz latest"
    "edgev3-nextflow edgev3-nextflow_20260721_$ARCH.tgz 20260721"
    "edgev3 edgev3_20260818_$ARCH.tgz 20260818"
    "edgev3-mongo edgev3-mongo_20260818_$ARCH.tgz 20260818"
)

############################
# Port checks
############################
check_port_free() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      log "FATAL: Port $port is already in use"
      lsof -iTCP:"$port" -sTCP:LISTEN
      exit 1
    fi
  elif command -v ss >/dev/null 2>&1; then
    if ss -ltn | awk '{print $4}' | grep -q ":$port$"; then
      log "FATAL: Port $port is already in use"
      ss -ltn | grep ":$port "
      exit 1
    fi
  fi
}

############################
# Sanity checks
############################
sanity_check() {
  local mode="${1:-}"
  log "Running environment sanity checks..."

  log "Platform: $DOCKER_DEFAULT_PLATFORM"

  command -v docker >/dev/null 2>&1 || { log "FATAL: docker not found"; exit 1; }
  docker info >/dev/null 2>&1 || { log "FATAL: Docker daemon not running"; exit 1; }

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  elif docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  else
    log "FATAL: docker-compose not available"
    exit 1
  fi
  export COMPOSE_CMD

  case "$mode" in
    init|start|restart)
      log "Checking required ports..."
      check_port_free 8080
      check_port_free 27017
      ;;
  esac
}

############################
# Version validation
############################
validate_versions() {
  log "Validating Docker image versions..."
  local entry image tarball tag
  for entry in "${IMAGES[@]}"; do
    image=${entry%% *}
    rest=${entry#* }
    tarball=${rest%% *}
    tag=${rest##* }
    docker image inspect "$image:$tag" >/dev/null 2>&1 || {
      log "FATAL: Missing or incorrect version $image:$tag"
      exit 1
    }
  done
}

############################
# Image import
############################
import_images() {
  log "Importing Docker images if needed..."
  local entry image tarball tag path rest
  for entry in "${IMAGES[@]}"; do
    image=${entry%% *}
    rest=${entry#* }
    tarball=${rest%% *}
    tag=${rest##* }
    path="$IMAGES_DIR/$tarball"

    [[ -f "$path" ]] || {
      log "FATAL: Missing image tarball $path"
      exit 1
    }

    if docker image inspect "$image:$tag" >/dev/null 2>&1; then
      log "✔ $image:$tag already present"
    else
      log "docker load $image:$tag from $path"
      run_cmd docker load -i "$path"
    fi
  done
}

############################
# Compose lifecycle
############################
init_spades() {
  log "Initializing SPADES (RESET volumes)"
  cd "$APP_DIR"
  prepare_runtime_config
  run_cmd $COMPOSE_CMD down -v
  run_cmd $COMPOSE_CMD up -d
}

start_spades() {
  log "Starting SPADES"
  cd "$APP_DIR"
  prepare_runtime_config
  run_cmd $COMPOSE_CMD up -d
}

stop_spades() {
  log "Stopping SPADES"
  cd "$APP_DIR"
  run_cmd $COMPOSE_CMD down
}

restart_spades() {
  log "Restarting SPADES"
  stop_spades
  start_spades
}

status_spades() {
  cd "$APP_DIR"
  $COMPOSE_CMD ps
}

############################
# Browser
############################
open_browser() {
  local URL="http://localhost:8080"
  if $DRY_RUN; then
    log "[DRY-RUN] Would open browser at $URL"
    return
  fi
  case "$(uname)" in
    Darwin) open "$URL" ;;
    Linux)  xdg-open "$URL" ;;
  esac
}

############################
# Usage
############################
usage() {
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Usage:
  $SCRIPT_NAME [--dry-run] [--help|-h] [--version|-V] <command>

Options:
  --dry-run           Show commands without executing
  --help, -h          Show this help message
  --version, -V       Show script version

Commands:
  check | import | init | start | stop | restart | status | open
EOF
}

############################
# Command validation
############################

if $SHOW_VERSION; then
  echo "$SCRIPT_NAME version $SCRIPT_VERSION"
  exit 0
fi

if $SHOW_HELP; then
  usage
  exit 0
fi

COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
  echo "ERROR: No command specified" >&2
  echo >&2
  usage >&2
  exit 2
fi

case "$COMMAND" in
  check)
    sanity_check
    validate_versions
    ;;
  import)
    sanity_check
    import_images
    ;;
  init)
    sanity_check init
    import_images
    validate_versions
    init_spades
    ;;
  start)
    sanity_check start
    validate_versions
    start_spades
    ;;
  stop)
    sanity_check
    stop_spades
    ;;
  restart)
    sanity_check restart
    validate_versions
    restart_spades
    ;;
  status)
    sanity_check
    status_spades
    ;;
  open)
    open_browser
    ;;
  *)
    echo "ERROR: Unknown command '$COMMAND'" >&2
    exit 2
    ;;
esac
