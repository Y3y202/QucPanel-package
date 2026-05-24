#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="QucPanel"
SERVICE_NAME="qucpanel.service"
DEFAULT_INSTALL_DIR="/opt/qucpanel"
DEFAULT_BIND_HOST="0.0.0.0"
DEFAULT_PACKAGE_BASE_URL="https://github.com/Y3y202/QucPanel-package/releases/latest/download"

INSTALL_DIR="${QUCPANEL_HOME:-$DEFAULT_INSTALL_DIR}"
PANEL_BIND="${QUCPANEL_BIND:-}"
PACKAGE_BASE_URL="${QUCPANEL_PACKAGE_BASE_URL:-$DEFAULT_PACKAGE_BASE_URL}"
PACKAGE_ARCH="${QUCPANEL_PACKAGE_ARCH:-}"
INSTALL_MODE="${QUCPANEL_INSTALL_MODE:-auto}"
BIND_EXPLICIT=0
if [[ -n "${QUCPANEL_BIND:-}" ]]; then
  BIND_EXPLICIT=1
fi
ADMIN_USERNAME="${QUCPANEL_ADMIN_USERNAME:-}"
ADMIN_PASSWORD="${QUCPANEL_ADMIN_PASSWORD:-}"
SKIP_FRONTEND_BUILD="${SKIP_FRONTEND_BUILD:-0}"
SKIP_BACKEND_BUILD="${SKIP_BACKEND_BUILD:-0}"
NO_START="${NO_START:-0}"

SCRIPT_DIR=""
SOURCE_ROOT=""
WORK_DIR=""
DIST_DIR=""
BACKEND_BIN=""
CLI_BIN=""

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  sudo bash install.sh [OPTIONS]

Examples:
  sudo bash install.sh
  sudo bash install.sh --mode source
  sudo bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Y3y202/QucPanel-package/master/install.sh)"

Options:
  --install-dir PATH       Install directory, default: /opt/qucpanel
  --bind ADDR:PORT         Panel bind address, default: random 10000-50000 on fresh install
  --admin-username VALUE   Initial panel username for a fresh database
  --admin-password VALUE   Initial panel password for a fresh database
  --mode MODE              Install mode: auto, source, package
  --package-url URL        Package base URL for binary install mode
  --package-arch ARCH      Package architecture override, e.g. amd64
  --skip-frontend-build    Reuse existing dist/ in source mode
  --skip-backend-build     Reuse existing backend release binaries in source mode
  --no-start               Install files and systemd unit without starting service
  -h, --help               Show this help

Environment:
  QUCPANEL_HOME
  QUCPANEL_BIND
  QUCPANEL_ADMIN_USERNAME
  QUCPANEL_ADMIN_PASSWORD
  QUCPANEL_PACKAGE_BASE_URL
  QUCPANEL_PACKAGE_ARCH
  QUCPANEL_INSTALL_MODE
  QUCPANEL_SOURCE_DIR
  SKIP_FRONTEND_BUILD=1
  SKIP_BACKEND_BUILD=1
EOF
}

log() {
  printf '[%s] %s\n' "$APP_NAME" "$*"
}

fail() {
  printf '[%s] ERROR: %s\n' "$APP_NAME" "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      [[ $# -ge 2 ]] || fail "--install-dir requires a value"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --bind)
      [[ $# -ge 2 ]] || fail "--bind requires a value"
      PANEL_BIND="$2"
      BIND_EXPLICIT=1
      shift 2
      ;;
    --admin-password)
      [[ $# -ge 2 ]] || fail "--admin-password requires a value"
      ADMIN_PASSWORD="$2"
      shift 2
      ;;
    --admin-username)
      [[ $# -ge 2 ]] || fail "--admin-username requires a value"
      ADMIN_USERNAME="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || fail "--mode requires a value"
      INSTALL_MODE="$2"
      shift 2
      ;;
    --package-url)
      [[ $# -ge 2 ]] || fail "--package-url requires a value"
      PACKAGE_BASE_URL="$2"
      shift 2
      ;;
    --package-arch)
      [[ $# -ge 2 ]] || fail "--package-arch requires a value"
      PACKAGE_ARCH="$2"
      shift 2
      ;;
    --skip-frontend-build)
      SKIP_FRONTEND_BUILD=1
      shift
      ;;
    --skip-backend-build)
      SKIP_BACKEND_BUILD=1
      shift
      ;;
    --no-start)
      NO_START=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

if [[ "$(uname -s)" != "Linux" ]]; then
  fail "This installer only supports Linux"
fi

if [[ "$(id -u)" -ne 0 ]]; then
  fail "Please run as root, for example: sudo bash install.sh"
fi

if [[ "$INSTALL_DIR" != /* ]]; then
  fail "--install-dir must be an absolute path"
fi

if [[ "$INSTALL_DIR" =~ [[:space:]] ]]; then
  fail "--install-dir must not contain whitespace"
fi

if [[ "$INSTALL_DIR" == "/" || "$INSTALL_DIR" == "/opt" || "$INSTALL_DIR" == "/usr" ]]; then
  fail "Refusing to install directly into high-risk directory: $INSTALL_DIR"
fi

ENV_FILE="/etc/default/qucpanel"
DB_PATH="$INSTALL_DIR/qucpanel.db"

random_uint32() {
  od -An -N4 -tu4 /dev/urandom | tr -d '[:space:]'
}

random_chars() {
  local charset="$1"
  local length="$2"
  local value=""
  while [[ "${#value}" -lt "$length" ]]; do
    value+="$(
      LC_ALL=C tr -dc "$charset" </dev/urandom | head -c "$((length - ${#value}))" || true
    )"
  done
  printf '%s' "$value"
}

generate_panel_port() {
  local raw
  raw="$(random_uint32)"
  printf '%s' "$((10000 + raw % 40001))"
}

generate_password() {
  local upper lower digit special rest
  upper="$(random_chars 'A-Z' 1)"
  lower="$(random_chars 'a-z' 1)"
  digit="$(random_chars '0-9' 1)"
  special="$(random_chars '@#%+=_-' 1)"
  rest="$(random_chars 'A-Za-z0-9@#%+=_-' 14)"
  printf '%s' "${upper}${lower}${digit}${special}${rest}"
}

generate_username() {
  printf 'qp%s' "$(random_chars 'a-z0-9' 10)"
}

load_existing_bind() {
  if [[ -f "$ENV_FILE" ]]; then
    awk -F= '/^QUCPANEL_BIND=/{print $2; exit}' "$ENV_FILE"
  fi
}

resolve_panel_bind() {
  if [[ -n "$PANEL_BIND" ]]; then
    printf '%s' "$PANEL_BIND"
    return 0
  fi

  if [[ "$fresh_db" == "1" ]]; then
    printf '%s:%s' "$DEFAULT_BIND_HOST" "$(generate_panel_port)"
    return 0
  fi

  local existing_bind
  existing_bind="$(load_existing_bind || true)"
  if [[ -n "$existing_bind" ]]; then
    printf '%s' "$existing_bind"
    return 0
  fi
  printf '%s:%s' "$DEFAULT_BIND_HOST" "10000"
}

fresh_db=0
if [[ ! -f "$DB_PATH" ]]; then
  fresh_db=1
fi

if [[ "$fresh_db" == "1" ]]; then
  if [[ -z "$ADMIN_USERNAME" ]]; then
    ADMIN_USERNAME="$(generate_username)"
  fi
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="$(generate_password)"
  fi
fi

PANEL_BIND="$(resolve_panel_bind)"

parse_bind() {
  local value="$1"
  if [[ "$value" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    BIND_HOST="${BASH_REMATCH[1]}"
    BIND_PORT="${BASH_REMATCH[2]}"
  elif [[ "$value" =~ ^([^:]+):([0-9]+)$ ]]; then
    BIND_HOST="${BASH_REMATCH[1]}"
    BIND_PORT="${BASH_REMATCH[2]}"
  else
    fail "--bind must be HOST:PORT. For IPv6, use [::]:10000"
  fi

  if (( BIND_PORT < 10000 || BIND_PORT > 50000 )); then
    fail "--bind port must be between 10000 and 50000"
  fi
}

parse_bind "$PANEL_BIND"
PACKAGE_BASE_URL="${PACKAGE_BASE_URL%/}"

panel_probe_host() {
  case "$BIND_HOST" in
    "0.0.0.0")
      printf '127.0.0.1'
      ;;
    "::")
      printf '[::1]'
      ;;
    *:*)
      printf '[%s]' "$BIND_HOST"
      ;;
    *)
      printf '%s' "$BIND_HOST"
      ;;
  esac
}

wait_for_panel() {
  if ! command -v curl >/dev/null 2>&1; then
    sleep 2
    return 0
  fi

  local probe_url="http://$(panel_probe_host):${BIND_PORT}/api/health"
  for _ in $(seq 1 30); do
    if curl --max-time 2 -fsS "$probe_url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  systemctl --no-pager --full status "$SERVICE_NAME" -n 30 || true
  fail "Service started but health check failed: $probe_url"
}

resolve_script_dir() {
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  fi
}

discover_source_root() {
  local candidate
  for candidate in "${QUCPANEL_SOURCE_DIR:-}" "$PWD" "$SCRIPT_DIR"; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate/package.json" && -f "$candidate/backend/Cargo.toml" ]]; then
      SOURCE_ROOT="$candidate"
      return 0
    fi
  done
  return 1
}

resolve_package_arch() {
  if [[ -n "$PACKAGE_ARCH" ]]; then
    printf '%s' "$PACKAGE_ARCH"
    return 0
  fi

  case "$(uname -m)" in
    x86_64|amd64)
      printf 'amd64'
      ;;
    aarch64|arm64)
      printf 'arm64'
      ;;
    *)
      fail "Unsupported architecture: $(uname -m)"
      ;;
  esac
}

download_file() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
    return 0
  fi
  fail "Missing required command: curl or wget"
}

prepare_source_payload() {
  discover_source_root || fail "Source tree not found. Set QUCPANEL_SOURCE_DIR or use --mode package"

  local backend_dir
  backend_dir="$SOURCE_ROOT/backend"
  DIST_DIR="$SOURCE_ROOT/dist"

  if [[ "$SKIP_FRONTEND_BUILD" != "1" ]]; then
    need_command npm
    log "Building frontend"
    (cd "$SOURCE_ROOT" && npm ci && npm run build)
  else
    log "Skipping frontend build"
  fi

  [[ -f "$DIST_DIR/index.html" ]] || fail "dist/index.html not found; build frontend first or remove --skip-frontend-build"

  if [[ "$SKIP_BACKEND_BUILD" != "1" ]]; then
    need_command cargo
    log "Building backend and qucpl"
    (cd "$backend_dir" && cargo build --release --bin qucpanel-backend --bin qucpl)
  else
    log "Skipping backend build"
  fi

  BACKEND_BIN="$backend_dir/target/release/qucpanel-backend"
  CLI_BIN="$backend_dir/target/release/qucpl"
  [[ -x "$BACKEND_BIN" ]] || fail "backend binary not found: $BACKEND_BIN"
  [[ -x "$CLI_BIN" ]] || fail "qucpl binary not found: $CLI_BIN"
}

prepare_package_payload() {
  need_command tar
  local arch dist_archive backend_archive backend_root local_dist local_backend
  arch="$(resolve_package_arch)"
  WORK_DIR="$(mktemp -d /tmp/qucpanel-install.XXXXXX)"
  dist_archive="$WORK_DIR/qucpanel-dist.tar.gz"
  backend_archive="$WORK_DIR/qucpanel-linux-${arch}.tar.gz"
  DIST_DIR="$WORK_DIR/dist"
  backend_root="$WORK_DIR/backend"
  mkdir -p "$DIST_DIR" "$backend_root"

  local_dist=""
  local_backend=""
  if [[ -n "$SCRIPT_DIR" ]]; then
    if [[ -f "$SCRIPT_DIR/qucpanel-dist.tar.gz" ]]; then
      local_dist="$SCRIPT_DIR/qucpanel-dist.tar.gz"
    fi
    if [[ -f "$SCRIPT_DIR/qucpanel-linux-${arch}.tar.gz" ]]; then
      local_backend="$SCRIPT_DIR/qucpanel-linux-${arch}.tar.gz"
    fi
  fi

  if [[ -n "$local_dist" ]]; then
    log "Using local frontend package $local_dist"
    cp "$local_dist" "$dist_archive"
  else
    log "Downloading frontend package from $PACKAGE_BASE_URL"
    download_file "$PACKAGE_BASE_URL/qucpanel-dist.tar.gz" "$dist_archive"
  fi

  if [[ -n "$local_backend" ]]; then
    log "Using local backend package $local_backend"
    cp "$local_backend" "$backend_archive"
  else
    log "Downloading backend package from $PACKAGE_BASE_URL"
    download_file "$PACKAGE_BASE_URL/qucpanel-linux-${arch}.tar.gz" "$backend_archive"
  fi

  tar -xzf "$dist_archive" -C "$DIST_DIR"
  tar -xzf "$backend_archive" -C "$backend_root"

  BACKEND_BIN="$(find "$backend_root" -type f -name qucpanel-backend | head -n 1 || true)"
  CLI_BIN="$(find "$backend_root" -type f -name qucpl | head -n 1 || true)"

  [[ -f "$DIST_DIR/index.html" ]] || fail "Package dist is missing index.html"
  [[ -x "$BACKEND_BIN" ]] || fail "Package backend is missing qucpanel-backend"
  [[ -x "$CLI_BIN" ]] || fail "Package backend is missing qucpl"
}

resolve_script_dir
need_command install
need_command systemctl

case "$INSTALL_MODE" in
  auto)
    if discover_source_root; then
      INSTALL_MODE="source"
    else
      INSTALL_MODE="package"
    fi
    ;;
  source|package)
    ;;
  *)
    fail "--mode must be one of: auto, source, package"
    ;;
esac

if [[ "$INSTALL_MODE" == "source" ]]; then
  prepare_source_payload
else
  prepare_package_payload
fi

BIN_DIR="$INSTALL_DIR/bin"
STATIC_DIR="$INSTALL_DIR/dist"
BACKUP_DIR="$INSTALL_DIR/backups"
DATABASE_DIR="$INSTALL_DIR/databases"
LOG_DIR="$INSTALL_DIR/logs"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
CLI_LINK="/usr/local/bin/qucpl"

log "Creating install directories under $INSTALL_DIR"
install -d -m 0755 "$BIN_DIR" "$STATIC_DIR" "$BACKUP_DIR" "$DATABASE_DIR" "$LOG_DIR"

log "Installing binaries"
install -m 0755 "$BACKEND_BIN" "$BIN_DIR/qucpanel-backend"
install -m 0755 "$CLI_BIN" "$BIN_DIR/qucpl"
rm -f "$CLI_LINK"
ln -s "$BIN_DIR/qucpl" "$CLI_LINK"

log "Installing frontend assets"
tmp_static="${STATIC_DIR}.new"
rm -rf "$tmp_static"
install -d -m 0755 "$tmp_static"
cp -a "$DIST_DIR/." "$tmp_static/"
rm -rf "$STATIC_DIR"
mv "$tmp_static" "$STATIC_DIR"

log "Writing environment file $ENV_FILE"
cat >"$ENV_FILE" <<EOF
QUCPANEL_HOME=$INSTALL_DIR
QUCPANEL_DB=$DB_PATH
QUCPANEL_STATIC_DIR=$STATIC_DIR
QUCPANEL_BIND=$PANEL_BIND
QUCPANEL_BACKUP_DIR=$BACKUP_DIR
QUCPANEL_DATABASE_DIR=$DATABASE_DIR
EOF
chmod 0644 "$ENV_FILE"

if [[ "$fresh_db" == "1" ]]; then
  log "Initializing database"
  QUCPL_SKIP_RESTART=1 \
  QUCPANEL_HOME="$INSTALL_DIR" \
  QUCPANEL_DB="$DB_PATH" \
  QUCPANEL_STATIC_DIR="$STATIC_DIR" \
  QUCPANEL_BIND="$PANEL_BIND" \
  QUCPANEL_BACKUP_DIR="$BACKUP_DIR" \
  QUCPANEL_DATABASE_DIR="$DATABASE_DIR" \
  QUCPANEL_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    "$BIN_DIR/qucpl" restore >/dev/null

  QUCPL_SKIP_RESTART=1 \
  QUCPANEL_HOME="$INSTALL_DIR" \
  QUCPANEL_DB="$DB_PATH" \
  QUCPANEL_STATIC_DIR="$STATIC_DIR" \
  QUCPANEL_BIND="$PANEL_BIND" \
  QUCPANEL_BACKUP_DIR="$BACKUP_DIR" \
  QUCPANEL_DATABASE_DIR="$DATABASE_DIR" \
    "$BIN_DIR/qucpl" update username "$ADMIN_USERNAME" >/dev/null
else
  log "Existing database detected; keeping current users and settings"
  QUCPL_SKIP_RESTART=1 \
  QUCPANEL_HOME="$INSTALL_DIR" \
  QUCPANEL_DB="$DB_PATH" \
  QUCPANEL_STATIC_DIR="$STATIC_DIR" \
  QUCPANEL_BIND="$PANEL_BIND" \
  QUCPANEL_BACKUP_DIR="$BACKUP_DIR" \
  QUCPANEL_DATABASE_DIR="$DATABASE_DIR" \
    "$BIN_DIR/qucpl" restore >/dev/null
fi

log "Writing systemd unit $SERVICE_FILE"
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=QucPanel Backend
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=-$ENV_FILE
Environment=QUCPANEL_BIND=$PANEL_BIND
ExecStart=$BIN_DIR/qucpanel-backend
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$SERVICE_FILE"

systemctl daemon-reload

if [[ "$BIND_EXPLICIT" == "1" ]]; then
  log "Syncing requested bind address into panel settings"
  QUCPL_SKIP_RESTART=1 \
  QUCPANEL_HOME="$INSTALL_DIR" \
  QUCPANEL_DB="$DB_PATH" \
  QUCPANEL_STATIC_DIR="$STATIC_DIR" \
  QUCPANEL_BIND="$PANEL_BIND" \
  QUCPANEL_BACKUP_DIR="$BACKUP_DIR" \
  QUCPANEL_DATABASE_DIR="$DATABASE_DIR" \
    "$BIN_DIR/qucpl" update port "$BIND_PORT" >/dev/null

  if [[ "$BIND_HOST" == "::" ]]; then
    QUCPL_SKIP_RESTART=1 \
    QUCPANEL_HOME="$INSTALL_DIR" \
    QUCPANEL_DB="$DB_PATH" \
    QUCPANEL_STATIC_DIR="$STATIC_DIR" \
    QUCPANEL_BIND="$PANEL_BIND" \
    QUCPANEL_BACKUP_DIR="$BACKUP_DIR" \
    QUCPANEL_DATABASE_DIR="$DATABASE_DIR" \
      "$BIN_DIR/qucpl" listen-ip ipv6 >/dev/null
  elif [[ "$BIND_HOST" == "0.0.0.0" ]]; then
    QUCPL_SKIP_RESTART=1 \
    QUCPANEL_HOME="$INSTALL_DIR" \
    QUCPANEL_DB="$DB_PATH" \
    QUCPANEL_STATIC_DIR="$STATIC_DIR" \
    QUCPANEL_BIND="$PANEL_BIND" \
    QUCPANEL_BACKUP_DIR="$BACKUP_DIR" \
    QUCPANEL_DATABASE_DIR="$DATABASE_DIR" \
      "$BIN_DIR/qucpl" listen-ip ipv4 >/dev/null
  else
    log "Keeping existing listen IP setting; qucpl listen-ip currently supports ipv4/ipv6 wildcard only"
  fi
fi

systemctl enable "$SERVICE_NAME" >/dev/null

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${BIND_PORT}/tcp" >/dev/null || true
fi

if [[ "$NO_START" == "1" ]]; then
  log "Installed without starting service"
else
  log "Starting service"
  systemctl restart "$SERVICE_NAME"
  wait_for_panel
fi

host="$BIND_HOST"
if [[ "$host" == "0.0.0.0" || "$host" == "::" ]]; then
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$host" ]] || host="127.0.0.1"
fi
if [[ "$host" == *:* ]]; then
  host="[$host]"
fi

log "Installation complete"
printf '  Mode: %s\n' "$INSTALL_MODE"
printf '  Service: %s\n' "$SERVICE_NAME"
printf '  CLI: %s\n' "$CLI_LINK"
printf '  Data: %s\n' "$INSTALL_DIR"
printf '  URL: http://%s:%s\n' "$host" "$BIND_PORT"
if [[ "$fresh_db" == "1" ]]; then
  printf '  Username: %s\n' "$ADMIN_USERNAME"
  printf '  Password: %s\n' "$ADMIN_PASSWORD"
fi
printf '  Next: qucpl status\n'
