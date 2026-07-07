#!/bin/bash
set -euo pipefail

# Owner-only by default: every file/dir we create (configs, keys, temp config,
# install log, config/log dirs, private bin dirs) holds or protects secrets.
# Binaries that must be executable are chmod'd explicitly.
umask 077

# ============================================================================
# AmneziaWG Full Setup: VPN Server + Tunnel
# ============================================================================
# Sets up an AmneziaWG VPN server and a tunnel to a second server.
# All VPN client traffic is routed through the tunnel (source-based routing).
# SSH and direct connections remain unaffected.
#
# With --client-only this machine becomes a plain AmneziaWG client instead:
# no VPN server, no chain -- all of this box's own traffic goes through the
# tunnel to Server B (full tunnel). SSH access is preserved automatically.
#
# Usage:
#   sudo ./install.sh [config-file] [options]
#
# config-file  -- AmneziaWG config for the tunnel to Server B (exported by
#                 the Amnezia app). If omitted, prompted interactively.
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Logging ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/awg-install.log"

: > "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true   # log tees the client config incl. keys
exec > >(tee -a "$LOG_FILE") 2>&1

_ts() { date '+%H:%M:%S'; }
log()  { echo -e "$(_ts) ${GREEN}[+]${NC} $*"; }
warn() { echo -e "$(_ts) ${YELLOW}[!]${NC} $*"; }
err()  { echo -e "$(_ts) ${RED}[x]${NC} $*" >&2; }
info() { echo -e "$(_ts) ${CYAN}[i]${NC} $*"; }

# --- Checks ---
# (root requirement is enforced below, after usage() is defined, so that
#  --help works for non-root users too)

CONFIG_FILE=""
VPN_SUBNET=""
VPN_SUBNET_MANUAL=""
AWG_INTERFACE="awg0"
SERVER_INTERFACE="wg0"
SERVER_PORT=""
NO_SERVER=false
CLIENT_ONLY=false
FORCE=false
VERBOSE=false
ROUTE_TABLE_NAME="via_tunnel"
ROUTE_TABLE_ID="200"
TEMP_CONFIG=""
AWG_LOG_DIR="/var/log/amneziawg"

# --- Stealth / mimicry: disguise the WHOLE tunnel as a legit service ---------
# With --mimic nothing on the box reads "awg", "wg" or "amnezia": the interfaces,
# config dir, systemd unit, binaries, logs, routing table and source dirs are all
# renamed after the chosen profile. Every name derives deterministically from the
# profile (see stealth_names/_profile_tokens), so --status/--uninstall can
# reconstruct them from a single fixed-location state file.
MIMIC_FLAG=false            # --mimic requested
MIMIC_UNMIMIC=false         # --unmimic requested
MIMIC_PROFILE="nginx"       # target profile (default)
KNOWN_PROFILES="nginx apache2 mysqld containerd systemd-timesyncd"
MIMIC_ENABLE=false          # final decision (computed after arg parsing)
STEALTH=false               # readability alias of MIMIC_ENABLE for this run
AWG_INTERFACE_USER_SET=false
PRIOR_PROFILE=""            # profile of an already-installed stealth setup, if any
PRIOR_IFACE=""              # the actual tunnel interface recorded for that setup
PRIOR_MODE=""               # recorded routing mode of that setup: chain|client

AWG_CONF_DIR="/etc/amnezia/amneziawg"       # config dir (legacy default)

# Runtime binary/unit/source names -- legacy defaults; stealth_names() overrides.
BIN_ENGINE="/usr/local/bin/amneziawg-go"          # userspace engine
BIN_CTL="/usr/local/bin/awg"                      # control tool (wg/awg)
BIN_QUICK="/usr/local/bin/awg-quick"              # bring-up script
BIN_LAUNCH="/usr/local/bin/amneziawg-go-launch"   # engine launch wrapper (if any)
SVC_NAME="awg-quick"                              # systemd template unit base
SVC_DESC="AmneziaWG Tunnel via awg-quick (%i)"    # unit Description=
AWG_GO_DIR="/opt/amneziawg-go"                    # engine source clone
AWG_TOOLS_DIR="/opt/amneziawg-tools"              # tools source clone

# Fixed, keyword-free state location so uninstall/status can find a renamed
# install without knowing its (renamed) paths. Holds the active profile.
STATE_DIR="/var/lib/misc"
MIMIC_STATE_FILE="${STATE_DIR}/.netd.state"
MIMIC_DECLINED_FILE="${STATE_DIR}/.netd.skip"
LEGACY_STATE_FILE="/etc/amnezia/amneziawg/.mimic"   # earlier layout (back-compat)

# Detect a prior install BEFORE we build anything (for the upgrade auto-offer),
# and pick up an already-active stealth profile so re-runs keep the disguise.
# State file format (one value per line): profile / tunnel-interface / mode.
_state_line() { sed -n "${2}p" "$1" 2>/dev/null | tr -d ' \t\r\n' || true; }
PREEXISTING_AWG=false
MIMIC_WAS_ACTIVE=false
if [[ -f "$MIMIC_STATE_FILE" ]]; then
    PRIOR_PROFILE="$(_state_line "$MIMIC_STATE_FILE" 1)"
    PRIOR_IFACE="$(_state_line "$MIMIC_STATE_FILE" 2)"
    PRIOR_MODE="$(_state_line "$MIMIC_STATE_FILE" 3)"
elif [[ -f "$LEGACY_STATE_FILE" ]]; then
    PRIOR_PROFILE="$(_state_line "$LEGACY_STATE_FILE" 1)"
fi
# Only treat the box as "previously stealthed" if we actually parsed a profile
# (an empty/truncated state file must NOT silently force the default profile).
if [[ -n "$PRIOR_PROFILE" ]]; then
    PREEXISTING_AWG=true; MIMIC_WAS_ACTIVE=true
    MIMIC_PROFILE="$PRIOR_PROFILE"
elif [[ -f /usr/local/bin/amneziawg-go || -d /etc/amnezia/amneziawg ]]; then
    PREEXISTING_AWG=true
fi

cleanup_temp() {
    local rc=$?    # preserve the script's real exit code across this EXIT trap
    [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]] && rm -f "$TEMP_CONFIG"
    return $rc
}
trap cleanup_temp EXIT

# ============================================================================
# Stealth naming helpers
# ============================================================================
# The persistent, externally visible process is the userspace engine (it owns
# the UDP socket, shows up in ps/top/ss). Under stealth we run it as a renamed
# copy so 'comm' reads e.g. "nginx", with a realistic argv[0], AND we rename
# every on-disk/interface/unit name after the profile. All names derive from the
# profile, so nothing reads awg/wg/amnezia. Nothing goes in $PATH, no ports of
# the real service are bound and no unit under its real name is installed, so a
# real nginx/etc. is never touched.

# Profile -> naming tokens (single source of truth). Sets IFB (interface base),
# DSL (dir slug), SVCB (service/dir base).
_profile_tokens() {
    case "$1" in
        nginx)              IFB=web;   DSL=nginx;      SVCB=nginx-cache ;;
        apache2)            IFB=web;   DSL=apache2;    SVCB=apache2-worker ;;
        mysqld)             IFB=db;    DSL=mysql;      SVCB=mysql-helper ;;
        containerd)         IFB=cni;   DSL=containerd; SVCB=containerd-shim ;;
        systemd-timesyncd)  IFB=tsync; DSL=systemd;    SVCB=systemd-timesync-helper ;;
        *)                  IFB=net;   DSL="$1";       SVCB="$1" ;;
    esac
}

# Profile -> disguised process name + argv[0] (what ps/top/ss show).
mimic_profile_vars() {
    MIMIC_NAME="$1"
    case "$1" in
        nginx)              MIMIC_ARGV0="nginx: worker process" ;;
        apache2)            MIMIC_ARGV0="/usr/sbin/apache2 -k start" ;;
        mysqld)             MIMIC_ARGV0="/usr/sbin/mysqld" ;;
        containerd)         MIMIC_ARGV0="/usr/bin/containerd" ;;
        systemd-timesyncd)  MIMIC_ARGV0="/lib/systemd/systemd-timesyncd" ;;
        *)                  MIMIC_ARGV0="$1" ;;
    esac
}

# Apply the full stealth naming scheme for a profile -- overrides every
# path/name variable the rest of the script uses. The tunnel interface can still
# be pinned with --interface.
stealth_names() {
    local IFB DSL SVCB
    _profile_tokens "$1"
    mimic_profile_vars "$1"
    [[ "${AWG_INTERFACE_USER_SET:-false}" == true ]] || AWG_INTERFACE="${IFB}0"
    SERVER_INTERFACE="${IFB}1"
    AWG_CONF_DIR="/etc/${SVCB}"
    AWG_LOG_DIR="/var/log/${SVCB}"
    ROUTE_TABLE_NAME="${IFB}rt"
    SVC_NAME="$SVCB"
    SVC_DESC="${MIMIC_NAME} worker (%i)"
    MIMIC_DIR="/usr/local/lib/${1}"
    MIMIC_BIN="${MIMIC_DIR}/${1}"
    BIN_ENGINE="$MIMIC_BIN"
    BIN_CTL="${MIMIC_DIR}/${DSL}-cfg"
    BIN_QUICK="${MIMIC_DIR}/${DSL}-svc"
    BIN_LAUNCH="${MIMIC_DIR}/${DSL}-run"
    AWG_GO_DIR="/opt/.cache/${DSL}-core"
    AWG_TOOLS_DIR="/opt/.cache/${DSL}-tools"
}

# Remove every artifact of a naming scheme. Arg: a profile, or "legacy".
# Best-effort and idempotent: safe to call for a scheme that isn't installed.
# Arg 1: profile or "legacy". Arg 2 (optional): an extra/pinned tunnel interface
# that isn't the profile default (from --interface, recorded in the state file).
teardown_scheme() {
    local scheme="$1" extra_if="${2:-}" IFB DSL SVCB
    local ift ifs cdir ldir rt svc be bc bq bl sgo stools libdir i
    if [[ "$scheme" == legacy ]]; then
        ift=awg0; ifs=wg0; cdir=/etc/amnezia/amneziawg; ldir=/var/log/amneziawg
        rt=via_tunnel; svc=awg-quick; libdir=""
        be=/usr/local/bin/amneziawg-go; bc=/usr/local/bin/awg; bq=/usr/local/bin/awg-quick
        bl=/usr/local/bin/amneziawg-go-launch
        sgo=/opt/amneziawg-go; stools=/opt/amneziawg-tools
        rm -f /usr/local/bin/amneziawg-go-log   # very old wrapper name
    else
        _profile_tokens "$scheme"
        ift="${IFB}0"; ifs="${IFB}1"; cdir="/etc/${SVCB}"; ldir="/var/log/${SVCB}"
        rt="${IFB}rt"; svc="$SVCB"; libdir="/usr/local/lib/${scheme}"
        be="${libdir}/${scheme}"; bc="${libdir}/${DSL}-cfg"
        bq="${libdir}/${DSL}-svc"; bl="${libdir}/${DSL}-run"
        sgo="/opt/.cache/${DSL}-core"; stools="/opt/.cache/${DSL}-tools"
    fi
    # Restore /etc/resolv.conf from a surviving client-only backup BEFORE we
    # delete the config dir (awg-quick's PostDown may not have run on uninstall).
    if [[ -e "$cdir/.resolv.bak" || -L "$cdir/.resolv.bak" ]]; then
        rm -f /etc/resolv.conf 2>/dev/null || true
        cp -a "$cdir/.resolv.bak" /etc/resolv.conf 2>/dev/null || true
    fi
    # Interfaces to remove: profile-derived server + tunnel, plus any recorded
    # pinned tunnel interface that differs from the defaults.
    local ifaces=("$ifs" "$ift")
    [[ -n "$extra_if" && "$extra_if" != "$ift" && "$extra_if" != "$ifs" ]] && ifaces+=("$extra_if")
    for i in "${ifaces[@]}"; do
        systemctl stop "${svc}@${i}" 2>/dev/null || true
        systemctl disable "${svc}@${i}" 2>/dev/null || true
        ip link del "$i" 2>/dev/null || true    # userspace tun may linger
    done
    rm -f "/etc/systemd/system/${svc}@.service"
    for _n in $(seq 20); do ip rule del table "$rt" 2>/dev/null || break; done  # remove all rules -> table (bounded)
    ip route flush table "$rt" 2>/dev/null || true
    [[ -f /etc/iproute2/rt_tables ]] && sed -i "/[[:space:]]${rt}\$/d" /etc/iproute2/rt_tables 2>/dev/null || true
    rm -rf "$cdir" "$ldir" "$sgo" "$stools"
    rm -f "$be" "$bc" "$bq" "$bl"
    [[ -n "$libdir" ]] && rmdir "$libdir" 2>/dev/null || true
    # drop the now-empty parent dir too, but only if empty (the Amnezia app may
    # keep unrelated content under /etc/amnezia or /opt/.cache -- leave those).
    if [[ "$scheme" == legacy ]]; then
        rmdir /etc/amnezia 2>/dev/null || true
    else
        rmdir /opt/.cache 2>/dev/null || true
    fi
}

# Record (or clear) the active-scheme state file at the fixed location.
record_scheme() {
    local mode=chain
    [[ "$CLIENT_ONLY" == true ]] && mode=client
    if [[ "$STEALTH" == true ]]; then
        mkdir -p "$STATE_DIR"
        # line1=profile, line2=actual tunnel interface, line3=mode (so uninstall/
        # status/re-runs can reconstruct a pinned --interface and the routing mode)
        { echo "$MIMIC_PROFILE"; echo "$AWG_INTERFACE"; echo "$mode"; } > "$MIMIC_STATE_FILE"
        rm -f "$MIMIC_DECLINED_FILE"     # enabling clears any prior "declined"
    else
        rm -f "$MIMIC_STATE_FILE"        # keep any "declined" marker so we don't re-nag
    fi
    rm -f "$LEGACY_STATE_FILE"
}

# Move existing server + client configs from an OLD scheme's dir into the
# current AWG_CONF_DIR, so keys survive a rename (a server switch would otherwise
# regenerate keys and break existing clients). WireGuard configs don't embed the
# interface name, so only the filename changes. Arg: old profile, or "legacy".
migrate_configs() {
    local scheme="$1" IFB DSL SVCB oldcdir oldsrv cf
    if [[ "$scheme" == legacy ]]; then
        oldcdir=/etc/amnezia/amneziawg; oldsrv=wg0
    else
        _profile_tokens "$scheme"; oldcdir="/etc/${SVCB}"; oldsrv="${IFB}1"
    fi
    [[ "$oldcdir" == "$AWG_CONF_DIR" || ! -d "$oldcdir" ]] && return 0
    mkdir -p "$AWG_CONF_DIR"
    [[ -f "$oldcdir/${oldsrv}.conf" ]] && \
        mv -f "$oldcdir/${oldsrv}.conf" "$AWG_CONF_DIR/${SERVER_INTERFACE}.conf" 2>/dev/null || true
    for cf in "$oldcdir"/client*.conf; do
        [[ -f "$cf" ]] && mv -f "$cf" "$AWG_CONF_DIR/" 2>/dev/null || true
    done
}

# Decide WG_QUICK_USERSPACE_IMPLEMENTATION (-> AWG_GO_IMPL) from VERBOSE and
# STEALTH, writing the engine launch wrapper when logging and/or an argv[0]
# rewrite is needed; otherwise the engine binary is run directly. Uses the
# already-resolved BIN_ENGINE / BIN_LAUNCH paths. Sets global AWG_GO_IMPL.
resolve_userspace_impl() {
    local argv0=""
    [[ "$STEALTH" == true ]] && argv0="$MIMIC_ARGV0"

    rm -f /usr/local/bin/amneziawg-go-log      # very old wrapper name

    if [[ "$VERBOSE" == true || -n "$argv0" ]]; then
        [[ "$VERBOSE" == true ]] && { mkdir -p "$AWG_LOG_DIR"; log "Verbose mode: runtime logs -> $AWG_LOG_DIR/"; }
        mkdir -p "$(dirname "$BIN_LAUNCH")"
        {
            echo "#!/bin/bash"
            echo "# Auto-generated launcher for the userspace engine."
            echo "IFACE=\"\${1:-unknown}\""
            if [[ "$VERBOSE" == true ]]; then
                echo "LOG=\"${AWG_LOG_DIR}/\${IFACE}.log\""
                echo "echo \"[\$(date)] engine starting: \$IFACE\" >> \"\$LOG\""
                echo "export LOG_LEVEL=verbose"
            fi
            if [[ -n "$argv0" && "$VERBOSE" == true ]]; then
                echo "exec -a \"${argv0}\" \"${BIN_ENGINE}\" \"\$@\" >> \"\$LOG\" 2>&1"
            elif [[ -n "$argv0" ]]; then
                echo "exec -a \"${argv0}\" \"${BIN_ENGINE}\" \"\$@\""
            else
                echo "exec \"${BIN_ENGINE}\" \"\$@\" >> \"\$LOG\" 2>&1"
            fi
        } > "$BIN_LAUNCH"
        chmod 755 "$BIN_LAUNCH"
        AWG_GO_IMPL="$BIN_LAUNCH"
    else
        # No wrapper needed -- run the engine directly and remove any stale
        # wrapper from a previous --verbose run (else it lingers on disk and the
        # unit still references the current AWG_GO_IMPL).
        rm -f "$BIN_LAUNCH"
        AWG_GO_IMPL="$BIN_ENGINE"
        log "Runtime logging disabled (use --verbose to enable)"
    fi
}

# Write the systemd template unit. Uses SVC_NAME/SVC_DESC/BIN_QUICK/AWG_CONF_DIR
# and passes a full config path so awg-quick works from any (renamed) location.
write_awg_service() {
    log "Creating systemd service (${SVC_NAME}@)..."

    if [[ ! -x "$BIN_QUICK" ]]; then
        warn "Bring-up script not found at ${BIN_QUICK} -- the service may fail to start."
    fi

    cat > "/etc/systemd/system/${SVC_NAME}@.service" << SVCEOF
[Unit]
Description=${SVC_DESC}
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=${AWG_GO_IMPL}
ExecStart=${BIN_QUICK} up ${AWG_CONF_DIR}/%i.conf
ExecStop=${BIN_QUICK} down ${AWG_CONF_DIR}/%i.conf

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
}

# Restart whichever units of the current scheme are up (standalone toggle path).
restart_active_awg() {
    local reason="$1" svc
    for svc in "${SVC_NAME}@${SERVER_INTERFACE}" "${SVC_NAME}@${AWG_INTERFACE}"; do
        if systemctl is-active "$svc" &>/dev/null; then
            log "${reason}: restarting ${svc}..."
            systemctl restart "$svc" 2>/dev/null || warn "Restart failed: $svc (try: systemctl restart $svc)"
        fi
    done
}

usage() {
    echo "Usage: sudo $0 [config-file] [options]"
    echo ""
    echo "Sets up an AmneziaWG VPN server and a tunnel to a second server."
    echo "If config-file is omitted, you will be prompted to paste it."
    echo ""
    echo "Options:"
    echo "  --client-only        This box becomes a plain AWG client: no VPN"
    echo "                       server, no chain -- all of its own traffic goes"
    echo "                       through the tunnel to Server B (full tunnel)."
    echo "                       SSH access is preserved automatically."
    echo "  --vpn-subnet CIDR    VPN client subnet (default: 10.8.1.0/24)"
    echo "  --server-port PORT   VPN server listen port (default: random)"
    echo "  --interface NAME     Tunnel interface name (default: awg0)"
    echo "  --no-server          Skip VPN server setup (tunnel only)"
    echo "  --verbose            Enable runtime logging to /var/log/amneziawg/"
    echo "  --force              Force rebuild of binaries"
    echo "  --mimic [PROFILE]    Full stealth: rename the process, interfaces,"
    echo "                       config dir, systemd unit, binaries, logs and"
    echo "                       routing table after PROFILE so nothing reads"
    echo "                       awg/wg/amnezia. Never touches a real service of"
    echo "                       that name. Profiles: nginx (default), apache2,"
    echo "                       mysqld, containerd, systemd-timesyncd."
    echo "  --unmimic            Remove the disguise; restore standard names."
    echo "  --uninstall          Remove everything and exit"
    echo "  --status             Show diagnostic info and exit"
    echo "  --help               Show this help"
    echo ""
    echo "Examples:"
    echo "  sudo $0 client.conf"
    echo "  sudo $0 client.conf --client-only   # route THIS box through Server B"
    echo "  sudo $0 client.conf --server-port 51820"
    echo "  sudo $0 client.conf --mimic          # full stealth, disguised as nginx"
    echo "  sudo $0 client.conf --mimic apache2  # ... or as apache2"
    echo "  sudo $0 client.conf --unmimic        # remove the disguise"
    echo "  sudo $0 --status                 # check everything is working"
    echo "  sudo $0 --uninstall              # remove everything"
    exit 0
}

# --help must work without root, so handle it before the root check.
for _arg in "$@"; do
    [[ "$_arg" == "--help" || "$_arg" == "-h" ]] && usage
done

if [[ $EUID -ne 0 ]]; then
    err "Run as root: sudo $0 $*"
    exit 1
fi

# --- Argument parsing ---

# Fail cleanly (not with a cryptic "$2: unbound variable" under set -u) when a
# value-taking option is given without its value.
_need_val() { [[ -n "${2:-}" ]] || { err "Option $1 requires a value"; exit 1; }; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vpn-subnet)
            _need_val "$1" "${2:-}"
            VPN_SUBNET_MANUAL="$2"
            shift 2
            ;;
        --server-port)
            _need_val "$1" "${2:-}"
            SERVER_PORT="$2"
            shift 2
            ;;
        --interface)
            _need_val "$1" "${2:-}"
            AWG_INTERFACE="$2"
            AWG_INTERFACE_USER_SET=true   # don't let stealth_names override it
            shift 2
            ;;
        --no-server)
            NO_SERVER=true
            shift
            ;;
        --client-only|--client)
            CLIENT_ONLY=true
            NO_SERVER=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --mimic)
            MIMIC_FLAG=true
            # Optional profile argument -- only consume the next token if it is
            # a known profile keyword, so it never swallows the config file.
            case "${2:-}" in
                nginx|apache2|mysqld|containerd|systemd-timesyncd)
                    MIMIC_PROFILE="$2"; shift 2 ;;
                *)
                    shift ;;
            esac
            ;;
        --unmimic)
            MIMIC_UNMIMIC=true
            shift
            ;;
        --uninstall)
            log "Uninstalling..."
            echo ""
            # Tear down the recorded scheme first (with its pinned interface, if
            # any), then EVERY known profile + legacy -- so a renamed install is
            # removed even if the state file was lost. teardown_scheme is
            # idempotent/best-effort, so no-op schemes cost nothing.
            if [[ -n "$PRIOR_PROFILE" ]]; then
                log "Removing recorded scheme '${PRIOR_PROFILE}'..."
                teardown_scheme "$PRIOR_PROFILE" "$PRIOR_IFACE"
            fi
            for _p in $KNOWN_PROFILES; do
                [[ "$_p" == "$PRIOR_PROFILE" ]] && continue
                teardown_scheme "$_p"
            done
            log "Removing legacy layout (if any)..."
            teardown_scheme legacy

            rm -f "$MIMIC_STATE_FILE" "$MIMIC_DECLINED_FILE" "$LEGACY_STATE_FILE"
            systemctl daemon-reload

            log "Uninstall complete"
            info "ip_forward and /etc/sysctl.conf were left unchanged"
            info "Go (/usr/local/go) was left in place"
            exit 0
            ;;
        --status)
            # Read-only diagnostic: never let a no-match grep or empty pipeline
            # abort it early under errexit/pipefail.
            set +e +o pipefail
            # Resolve the active naming scheme so we report the right names.
            _dstealth=false
            MIMIC_NAME="amneziawg-go"
            if [[ -n "$PRIOR_PROFILE" ]]; then
                stealth_names "$PRIOR_PROFILE"; _dstealth=true
                # honour a recorded pinned --interface over the profile default
                [[ -n "$PRIOR_IFACE" ]] && AWG_INTERFACE="$PRIOR_IFACE"
            fi

            echo ""
            echo "=== Diagnostics ==="
            echo ""

            echo "-- Scheme --"
            if [[ "$_dstealth" == true ]]; then
                echo "  stealth: ENABLED (profile: ${PRIOR_PROFILE}, mode: ${PRIOR_MODE:-unknown})"
                echo "  process:   ${MIMIC_NAME}      interfaces: ${AWG_INTERFACE} / ${SERVER_INTERFACE}"
                echo "  config:    ${AWG_CONF_DIR}    unit: ${SVC_NAME}@"
                echo "  engine:    ${BIN_ENGINE}"
                echo "  (nothing here reads awg/wg/amnezia)"
            else
                echo "  stealth: disabled (legacy names: awg0/wg0, /etc/amnezia/amneziawg)"
            fi
            echo ""

            echo "-- Interfaces --"
            "$BIN_CTL" show 2>/dev/null || echo "  control tool not installed or no interfaces up"
            echo ""

            echo "-- Services --"
            for _svc in "${SVC_NAME}@${SERVER_INTERFACE}" "${SVC_NAME}@${AWG_INTERFACE}"; do
                _state="$(systemctl is-active "$_svc" 2>/dev/null || true)"
                printf "  %-34s %s\n" "$_svc" "$_state"
            done
            echo ""

            echo "-- Process (as the OS sees it) --"
            if command -v pgrep >/dev/null 2>&1; then
                # The kernel truncates 'comm' to 15 chars, so match on that prefix
                # (e.g. systemd-timesyncd -> systemd-timesyn).
                pgrep -a -x "${MIMIC_NAME:0:15}" 2>/dev/null | sed 's/^/  /' || echo "  ('${MIMIC_NAME}' not running)"
            fi
            echo ""

            echo "-- Routing --"
            echo "  ip rules:"
            ip rule show 2>/dev/null | grep -E "(${ROUTE_TABLE_NAME}|from)" | sed 's/^/    /'
            echo "  table ${ROUTE_TABLE_NAME}:"
            ip route show table "$ROUTE_TABLE_NAME" 2>/dev/null | sed 's/^/    /' || echo "    (empty or not found)"
            echo ""

            for _if in "$AWG_INTERFACE" "$SERVER_INTERFACE"; do
                echo "-- Last 20 log lines: ${_if} --"
                if [[ -f "${AWG_LOG_DIR}/${_if}.log" ]]; then
                    tail -20 "${AWG_LOG_DIR}/${_if}.log"
                else
                    echo "  no log file (verbose off or not started?)"
                fi
                echo ""
            done

            echo "-- Connectivity --"
            _tunnel_ip="$(ip -4 -o addr show dev "$AWG_INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
            if [[ -n "$_tunnel_ip" ]]; then
                echo -n "  Exit IP (via tunnel): "
                curl -s4 --max-time 5 --interface "$_tunnel_ip" ifconfig.me 2>/dev/null || echo "FAILED"
            else
                echo "  Tunnel interface ${AWG_INTERFACE} not up"
            fi
            echo ""

            echo "-- Log files --"
            echo "  Runtime:  ${AWG_LOG_DIR}/"
            [[ -f "${SCRIPT_DIR}/awg-install.log" ]] && echo "  Install:  ${SCRIPT_DIR}/awg-install.log"
            exit 0
            ;;
        --help|-h)
            usage
            ;;
        -*)
            err "Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "$CONFIG_FILE" ]]; then
                CONFIG_FILE="$1"
            else
                err "Extra argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

# --- Changing the disguise needs the config -------------------------------
# Full stealth renames interfaces, config dir, unit and binaries, so the tunnel
# must be regenerated under the new names. --mimic/--unmimic therefore require
# your config (and the same mode flags you first used).
if [[ -z "$CONFIG_FILE" && ( "$MIMIC_FLAG" == true || "$MIMIC_UNMIMIC" == true ) ]]; then
    err "Changing the disguise regenerates the tunnel under new names -- re-run with your config."
    info "e.g. sudo $0 client.conf --mimic       (add --client-only if that's how you set it up)"
    info "     sudo $0 client.conf --unmimic"
    exit 1
fi

# --- Config file: from argument or interactive input ---

if [[ -n "$CONFIG_FILE" && ! -f "$CONFIG_FILE" ]]; then
    err "File not found: $CONFIG_FILE"
    exit 1
fi

if [[ -z "$CONFIG_FILE" ]]; then
    echo ""
    info "No config file specified."
    info "Paste your AmneziaWG config below, then press Ctrl+D on an empty line:"
    echo ""
    TEMP_CONFIG="${SCRIPT_DIR}/awg-client-$$.conf"
    cat > "$TEMP_CONFIG"
    echo ""
    if [[ ! -s "$TEMP_CONFIG" ]]; then
        err "Empty config, nothing to do"
        exit 1
    fi
    CONFIG_FILE="$TEMP_CONFIG"
    log "Config received ($(wc -l < "$CONFIG_FILE") lines)"
fi

# --- Stealth decision (may prompt) ---
# Decide whether this run ends up disguised. Explicit flags win; an already-
# stealthed install stays stealthed across re-runs; and on an upgrade (awg was
# installed but never disguised) we proactively offer it. PRIOR_PROFILE and
# MIMIC_PROFILE were already resolved from the state file at startup.
if [[ "$MIMIC_UNMIMIC" == true ]]; then
    MIMIC_ENABLE=false
elif [[ "$MIMIC_FLAG" == true ]]; then
    MIMIC_ENABLE=true
elif [[ "$MIMIC_WAS_ACTIVE" == true ]]; then
    MIMIC_ENABLE=true                       # keep the disguise across re-runs
elif [[ "$PREEXISTING_AWG" == true && -t 0 && ! -f "$MIMIC_DECLINED_FILE" ]]; then
    # Upgrade path: awg was already installed and stealth was never set up.
    echo ""
    warn "Existing AmneziaWG installation detected."
    info "Stealth mode disguises the WHOLE tunnel as a legit service: the process,"
    info "interfaces, config dir, unit, binaries and logs are all renamed after"
    info "'${MIMIC_PROFILE}', so nothing reads awg/wg/amnezia. It never touches a real"
    info "${MIMIC_PROFILE} (private paths, no ports/units of it are used)."
    echo ""
    echo -n "Enable stealth now (disguise everything as ${MIMIC_PROFILE})? [y/N]: "
    _ans=""
    read -r _ans || true
    case "$_ans" in
        y|Y|yes|YES|Yes)
            MIMIC_ENABLE=true
            MIMIC_FLAG=true
            log "Stealth will be enabled (profile: ${MIMIC_PROFILE})"
            ;;
        *)
            MIMIC_ENABLE=false
            mkdir -p "$(dirname "$MIMIC_DECLINED_FILE")"
            : > "$MIMIC_DECLINED_FILE"
            info "Skipping stealth (won't ask again). Enable later: sudo $0 <config> --mimic"
            ;;
    esac
fi

STEALTH="$MIMIC_ENABLE"

# Resolve the naming scheme for THIS run, then migrate off any other scheme that
# is currently on disk (preserving keys) so both old and new never run at once.
if [[ "$STEALTH" == true ]]; then
    TARGET_SCHEME="$MIMIC_PROFILE"
    stealth_names "$MIMIC_PROFILE"
else
    TARGET_SCHEME="legacy"
fi

_old_schemes=()
if [[ "$TARGET_SCHEME" != legacy ]] && { [[ -d /etc/amnezia/amneziawg ]] || [[ -f /usr/local/bin/amneziawg-go ]]; }; then
    _old_schemes+=("legacy")
fi
[[ -n "$PRIOR_PROFILE" && "$PRIOR_PROFILE" != "$TARGET_SCHEME" ]] && _old_schemes+=("$PRIOR_PROFILE")

if [[ ${#_old_schemes[@]} -gt 0 ]]; then
    for _os in "${_old_schemes[@]}"; do
        warn "Migrating layout: ${_os} -> ${TARGET_SCHEME} (keys preserved, old names removed)..."
        migrate_configs "$_os"
        # Pass the recorded pinned interface only when tearing down the profile it
        # belongs to (the recorded scheme), so a --interface tunnel isn't orphaned.
        if [[ "$_os" == "$PRIOR_PROFILE" ]]; then
            teardown_scheme "$_os" "$PRIOR_IFACE"
        else
            teardown_scheme "$_os"
        fi
    done
fi

# --- Config parsing ---

log "Parsing config: $CONFIG_FILE"

parse_config() {
    local file="$1"
    local section=""

    # Interface fields
    IFACE_ADDRESS=""
    IFACE_DNS=""
    IFACE_PRIVATE_KEY=""
    IFACE_JC=""
    IFACE_JMIN=""
    IFACE_JMAX=""
    IFACE_S1=""
    IFACE_S2=""
    IFACE_S3=""
    IFACE_S4=""
    IFACE_H1=""
    IFACE_H2=""
    IFACE_H3=""
    IFACE_H4=""
    IFACE_I1=""
    IFACE_I2=""
    IFACE_I3=""
    IFACE_I4=""
    IFACE_I5=""

    # Peer fields
    PEER_PUBLIC_KEY=""
    PEER_PRESHARED_KEY=""
    PEER_ALLOWED_IPS=""
    PEER_ENDPOINT=""
    PEER_KEEPALIVE=""

    while IFS= read -r line; do
        # Strip \r and leading/trailing whitespace
        line="$(echo "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == "[Interface]" ]]; then
            section="interface"
            continue
        elif [[ "$line" == "[Peer]" ]]; then
            section="peer"
            continue
        fi

        key="$(echo "$line" | cut -d'=' -f1 | sed 's/[[:space:]]*$//')"
        value="$(echo "$line" | cut -d'=' -f2- | sed 's/^[[:space:]]*//')"

        if [[ "$section" == "interface" ]]; then
            case "$key" in
                Address)       IFACE_ADDRESS="$value" ;;
                DNS)           IFACE_DNS="$value" ;;
                PrivateKey)    IFACE_PRIVATE_KEY="$value" ;;
                Jc)            IFACE_JC="$value" ;;
                Jmin)          IFACE_JMIN="$value" ;;
                Jmax)          IFACE_JMAX="$value" ;;
                S1)            IFACE_S1="$value" ;;
                S2)            IFACE_S2="$value" ;;
                S3)            IFACE_S3="$value" ;;
                S4)            IFACE_S4="$value" ;;
                H1)            IFACE_H1="$value" ;;
                H2)            IFACE_H2="$value" ;;
                H3)            IFACE_H3="$value" ;;
                H4)            IFACE_H4="$value" ;;
                I1)            IFACE_I1="$value" ;;
                I2)            IFACE_I2="$value" ;;
                I3)            IFACE_I3="$value" ;;
                I4)            IFACE_I4="$value" ;;
                I5)            IFACE_I5="$value" ;;
            esac
        elif [[ "$section" == "peer" ]]; then
            case "$key" in
                PublicKey)          PEER_PUBLIC_KEY="$value" ;;
                PresharedKey)       PEER_PRESHARED_KEY="$value" ;;
                AllowedIPs)         PEER_ALLOWED_IPS="$value" ;;
                Endpoint)           PEER_ENDPOINT="$value" ;;
                PersistentKeepalive) PEER_KEEPALIVE="$value" ;;
            esac
        fi
    done < "$file"
}

parse_config "$CONFIG_FILE"

# Validation
if [[ -z "$IFACE_PRIVATE_KEY" || -z "$PEER_PUBLIC_KEY" || -z "$PEER_ENDPOINT" ]]; then
    err "Incomplete config: PrivateKey, PublicKey and Endpoint are required"
    exit 1
fi

# Split host:port, handling a bracketed IPv6 literal ([2001:db8::1]:51820).
if [[ "$PEER_ENDPOINT" == \[*\]:* ]]; then
    ENDPOINT_HOST="${PEER_ENDPOINT#\[}"; ENDPOINT_HOST="${ENDPOINT_HOST%%\]:*}"
    ENDPOINT_PORT="${PEER_ENDPOINT##*\]:}"
else
    ENDPOINT_HOST="${PEER_ENDPOINT%%:*}"
    ENDPOINT_PORT="${PEER_ENDPOINT##*:}"
fi

# The endpoint host is untrusted config input that gets written into a root-run
# PostUp (chain mode). Reject anything but IP/hostname characters so it cannot
# smuggle shell metacharacters into that command.
if [[ ! "$ENDPOINT_HOST" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    err "Endpoint host contains unexpected characters: '$ENDPOINT_HOST'"
    exit 1
fi
if [[ ! "$ENDPOINT_PORT" =~ ^[0-9]+$ ]]; then
    err "Endpoint port is not numeric: '$ENDPOINT_PORT'"
    exit 1
fi

# Resolve to an IP literal. In chain mode `Table = off` means awg-quick does NOT
# pin the endpoint route for us -- our /32 PostUp route is the only thing keeping
# the encrypted handshake off the tunnel, so a non-IP there both fails silently
# and (previously) could be a hostname. Require a real IP in chain mode.
_is_ip() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { [[ "$1" == *:* ]] && [[ "$1" =~ ^[0-9a-fA-F:]+$ ]]; }; }
ENDPOINT_ADDR="$ENDPOINT_HOST"
if ! _is_ip "$ENDPOINT_ADDR" && command -v getent >/dev/null 2>&1; then
    # '|| true': a failed lookup makes the pipeline non-zero (pipefail), which
    # would otherwise abort the whole script here under set -e.
    _resolved="$(getent ahostsv4 "$ENDPOINT_HOST" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    [[ -z "${_resolved:-}" ]] && _resolved="$(getent ahostsv6 "$ENDPOINT_HOST" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    [[ -n "${_resolved:-}" ]] && ENDPOINT_ADDR="$_resolved"
fi
if [[ "$CLIENT_ONLY" != true ]] && ! _is_ip "$ENDPOINT_ADDR"; then
    err "Chain mode requires the endpoint as an IP address (or a resolvable host)."
    err "Could not resolve '$ENDPOINT_HOST'. Put the IP in the config's Endpoint,"
    err "fix DNS, or use --client-only (awg-quick resolves the endpoint itself there)."
    exit 1
fi

info "Endpoint:    $ENDPOINT_HOST:$ENDPOINT_PORT"
[[ "$ENDPOINT_ADDR" != "$ENDPOINT_HOST" ]] && info "Endpoint IP: $ENDPOINT_ADDR (resolved)"
info "Address:     $IFACE_ADDRESS"

# --- Detect default gateway and interface ---

DEFAULT_GW="$(ip route show default | awk '/default/ {print $3}' | head -1)"
DEFAULT_IFACE="$(ip route show default | awk '/default/ {print $5}' | head -1)"

if [[ -z "$DEFAULT_GW" || -z "$DEFAULT_IFACE" ]]; then
    err "Failed to detect default gateway / interface"
    exit 1
fi

info "Default GW:  $DEFAULT_GW via $DEFAULT_IFACE"

# The address we are SSH'd in FROM, so --client-only can keep that reply path on
# the main table and not lock us out. sudo does NOT pass SSH_CONNECTION/SSH_CLIENT
# through by default, so fall back to the utmp record (`who am i`).
SSH_CLIENT_IP=""
for _src in "$(echo "${SSH_CONNECTION:-}" | awk '{print $1}')" \
            "$(echo "${SSH_CLIENT:-}" | awk '{print $1}')" \
            "$(who am i 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p')"; do
    if [[ -n "${_src:-}" ]]; then SSH_CLIENT_IP="$_src"; break; fi
done
SSH_CLIENT_IP4=""; SSH_CLIENT_IP6=""
if [[ "$SSH_CLIENT_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    SSH_CLIENT_IP4="$SSH_CLIENT_IP"
elif [[ "$SSH_CLIENT_IP" == *:* && "$SSH_CLIENT_IP" =~ ^[0-9a-fA-F:]+$ ]]; then
    SSH_CLIENT_IP6="$SSH_CLIENT_IP"
fi

# ALL global addresses on the box: reply traffic from any of them must stay on
# the main table (the SSH ingress may not be on the default interface).
mapfile -t LOCAL_IPS4 < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u)
mapfile -t LOCAL_IPS6 < <(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u)
LOCAL_IP="${LOCAL_IPS4[0]:-}"     # first global v4, kept for status/messages

# Does this host have a global IPv6 address? (decides ::/0 full tunnel)
HAS_IPV6=false
[[ ${#LOCAL_IPS6[@]} -gt 0 ]] && HAS_IPV6=true

# --- Install dependencies ---

log "Installing dependencies..."

apt-get update -qq
apt-get install -y -qq git make gcc golang qrencode >/dev/null 2>&1 || {
    warn "golang from repo might be outdated, checking version..."
}

# Check Go version (need >= 1.21)
GO_VERSION="$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+' || echo '0.0')"
GO_MAJOR="${GO_VERSION%%.*}"
GO_MINOR="${GO_VERSION##*.}"

if [[ "$GO_MAJOR" -lt 1 ]] || [[ "$GO_MAJOR" -eq 1 && "$GO_MINOR" -lt 21 ]]; then
    warn "Go $GO_VERSION is too old, installing a newer version..."

    GO_TAR="go1.22.5.linux-amd64.tar.gz"
    GO_TAR_PATH="${SCRIPT_DIR}/$GO_TAR"
    # Discard a cached archive that is truncated/corrupt (e.g. an interrupted
    # earlier download or an HTML error page), else every re-run fails at `tar`.
    if [[ -f "$GO_TAR_PATH" ]] && ! gzip -t "$GO_TAR_PATH" 2>/dev/null; then
        warn "Cached Go archive is corrupt -- re-downloading."
        rm -f "$GO_TAR_PATH"
    fi
    if [[ ! -f "$GO_TAR_PATH" ]]; then
        wget -q "https://go.dev/dl/$GO_TAR" -O "$GO_TAR_PATH" 2>/dev/null || {
            rm -f "$GO_TAR_PATH"    # don't leave a partial file for the next run
            err "Failed to download Go. Install manually: https://go.dev/dl/"
            exit 1
        }
    fi
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$GO_TAR_PATH"
    export PATH="/usr/local/go/bin:$PATH"
    log "Go $(go version) installed"
else
    log "Go $GO_VERSION -- OK"
fi

export PATH="/usr/local/go/bin:$PATH"

# --- Build amneziawg-go (engine) ---
# Install to the (possibly stealth) BIN_ENGINE path; sources live in AWG_GO_DIR.
# For stealth the engine file is named after the profile so its process 'comm'
# reads e.g. "nginx" (amneziawg-go re-execs via /proc/self/exe on daemonize, so
# the on-disk name is what shows up).

mkdir -p "$(dirname "$BIN_ENGINE")"

if [[ ! -f "$BIN_ENGINE" || "$FORCE" == true ]]; then
    [[ "$FORCE" == true ]] && log "Force rebuilding engine..."
    log "Building userspace engine..."

    if [[ -d "$AWG_GO_DIR/.git" ]]; then
        cd "$AWG_GO_DIR" && git pull -q
    else
        rm -rf "$AWG_GO_DIR"
        git clone -q https://github.com/amnezia-vpn/amneziawg-go.git "$AWG_GO_DIR"
    fi

    cd "$AWG_GO_DIR"
    [[ "$FORCE" == true ]] && make clean 2>/dev/null || true
    make -j"$(nproc)" 2>&1 | tail -3
    cp -f amneziawg-go "$BIN_ENGINE"
    chmod 755 "$BIN_ENGINE"
    log "Engine built and installed -> $BIN_ENGINE"
else
    log "Engine already installed (use --force to rebuild)"
fi

# --- Build amneziawg-tools (control tool + bring-up script) ---

if [[ ! -f "$BIN_CTL" || ! -f "$BIN_QUICK" || "$FORCE" == true ]]; then
    [[ "$FORCE" == true ]] && log "Force rebuilding tools..."
    log "Building control tools..."

    if [[ -d "$AWG_TOOLS_DIR/.git" ]]; then
        cd "$AWG_TOOLS_DIR" && git pull -q
    else
        rm -rf "$AWG_TOOLS_DIR"
        git clone -q https://github.com/amnezia-vpn/amneziawg-tools.git "$AWG_TOOLS_DIR"
    fi

    cd "$AWG_TOOLS_DIR/src"
    [[ "$FORCE" == true ]] && make clean 2>/dev/null || true
    make -j"$(nproc)" 2>&1 | tail -3
    cp -f wg "$BIN_CTL"
    chmod 755 "$BIN_CTL"

    # Bring-up script (awg-quick). Install to BIN_QUICK.
    if [[ -f "$AWG_TOOLS_DIR/src/wg-quick/linux.bash" ]]; then
        cp -f "$AWG_TOOLS_DIR/src/wg-quick/linux.bash" "$BIN_QUICK"
        chmod 755 "$BIN_QUICK"
        if [[ "$STEALTH" == true ]]; then
            # The script hardcodes calls to the control command `awg`. Inject a
            # shell function right after the shebang so every `awg ...` routes to
            # our renamed control binary -- no file named `awg` need exist.
            sed -i "1a awg() { \"${BIN_CTL}\" \"\$@\"; }" "$BIN_QUICK"
        fi
    fi

    log "Control tools built and installed"
else
    log "Control tools already installed (use --force to rebuild)"
fi

# Stealth: the upstream source trees carry keyword file names (amneziawg-go, wg,
# wg-quick). The binaries are installed, so drop the sources. (Re-runs skip the
# build since the engine exists; use --force to rebuild.)
if [[ "$STEALTH" == true ]]; then
    rm -rf "$AWG_GO_DIR" "$AWG_TOOLS_DIR"
    rmdir /opt/.cache 2>/dev/null || true
fi

# Ensure the control tool is callable below (key generation). Full paths are used
# via $BIN_CTL, but keep /usr/local/bin on PATH for the legacy layout.
export PATH="/usr/local/bin:$PATH"

# --- Enable IP forwarding ---
# Only needed when this box forwards traffic for others (VPN server / chain).
# A plain client (--client-only) routes only its own traffic, so skip it.

if [[ "$CLIENT_ONLY" == true ]]; then
    log "Client-only mode: skipping ip_forward (not forwarding for others)"
else
    log "Enabling ip_forward..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    if ! grep -q '^net.ipv4.ip_forward\s*=\s*1' /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi
fi

# --- VPN Server Setup ---
# AWG_CONF_DIR is already resolved (legacy default or stealth-renamed).
mkdir -p "$AWG_CONF_DIR"

SERVER_CONF="$AWG_CONF_DIR/${SERVER_INTERFACE}.conf"
CLIENT_CONF_FILE=""
SERVER_CREATED=false

# Mode reconciliation: if this run is client-only but a previous CHAIN install of
# the SAME scheme left a VPN server + source-routing behind, remove it now --
# otherwise a live VPN server and a full-tunnel client would coexist on one box.
if [[ "$CLIENT_ONLY" == true ]]; then
    if [[ -f "$SERVER_CONF" ]] || systemctl is-active "${SVC_NAME}@${SERVER_INTERFACE}" &>/dev/null; then
        warn "Client-only requested but a chain-mode VPN server exists -- removing it..."
        systemctl stop "${SVC_NAME}@${SERVER_INTERFACE}" 2>/dev/null || true
        systemctl disable "${SVC_NAME}@${SERVER_INTERFACE}" 2>/dev/null || true
        ip link del "$SERVER_INTERFACE" 2>/dev/null || true
        rm -f "$SERVER_CONF" "$AWG_CONF_DIR"/client*.conf
        for _n in $(seq 20); do ip rule del table "$ROUTE_TABLE_NAME" 2>/dev/null || break; done
        ip route flush table "$ROUTE_TABLE_NAME" 2>/dev/null || true
        [[ -f /etc/iproute2/rt_tables ]] && sed -i "/[[:space:]]${ROUTE_TABLE_NAME}\$/d" /etc/iproute2/rt_tables 2>/dev/null || true
    fi
fi

# Determine VPN subnet
VPN_SUBNET="${VPN_SUBNET_MANUAL:-10.8.1.0/24}"

# Detect existing VPN server: our config, Amnezia Docker, other wg/awg configs
detect_existing_server() {
    local addr conf_file iface

    # 1. Our own config from a previous run
    if [[ -f "$SERVER_CONF" ]]; then
        addr="$(grep -iP '^\s*Address\s*=' "$SERVER_CONF" | head -1 | sed 's/.*=\s*//' | tr -d ' ')"
        if [[ -n "$addr" ]]; then
            echo "config:$SERVER_CONF:$addr"
            return 0
        fi
    fi

    # 2. Amnezia Docker container configs (common paths)
    for conf_file in \
        /opt/amnezia/amneziawg/*.conf \
        /etc/amnezia/amneziawg/*.conf \
        /var/lib/docker/volumes/amnezia-*/_data/*.conf \
        /etc/wireguard/wg*.conf; do
        [[ -f "$conf_file" ]] || continue
        # Skip our tunnel config
        [[ "$conf_file" == *"/${AWG_INTERFACE}.conf" ]] && continue
        [[ "$conf_file" == "$SERVER_CONF" ]] && continue
        # Server config has ListenPort, client config does not
        grep -qiP '^\s*ListenPort\s*=' "$conf_file" 2>/dev/null || continue
        addr="$(grep -iP '^\s*Address\s*=' "$conf_file" | head -1 | sed 's/.*=\s*//' | tr -d ' ')"
        if [[ -n "$addr" ]]; then
            echo "config:$conf_file:$addr"
            return 0
        fi
    done

    # 3. Running wg/awg interfaces
    for iface in $(ip -o link show 2>/dev/null | grep -oP '(?<=: )(wg|awg)\S+(?=:)' || true); do
        [[ "$iface" == "$AWG_INTERFACE" ]] && continue
        addr="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -1)"
        if [[ -n "$addr" && "$addr" == */* ]]; then
            echo "iface:$iface:$addr"
            return 0
        fi
    done

    return 1
}

if [[ "$NO_SERVER" == true ]]; then
    if [[ "$CLIENT_ONLY" == true ]]; then
        log "Client-only mode: this box will route its own traffic through Server B"
    else
        log "VPN server setup skipped (--no-server)"
    fi
elif EXISTING="$(detect_existing_server)"; then
    EXISTING_TYPE="${EXISTING%%:*}"
    EXISTING_REST="${EXISTING#*:}"
    EXISTING_SRC="${EXISTING_REST%%:*}"
    EXISTING_ADDR="${EXISTING_REST#*:}"

    if [[ "$EXISTING_TYPE" == "config" ]]; then
        log "Existing VPN server found: $EXISTING_SRC"
    else
        log "Existing VPN interface found: $EXISTING_SRC ($EXISTING_ADDR)"
    fi

    # Adopting the subnet is intended for chaining OUR / an Amnezia server. If the
    # detected server is an unrelated third-party WireGuard config, adopting its
    # subnet would route/NAT that server's clients through our tunnel -- warn so
    # the operator can pin an explicit --vpn-subnet instead.
    if [[ "$EXISTING_SRC" != "$SERVER_CONF" && "$EXISTING_SRC" == /etc/wireguard/* ]]; then
        warn "Detected a third-party WireGuard server ($EXISTING_SRC)."
        warn "Its subnet will be chained through this tunnel. Pass --vpn-subnet to override."
    fi
    if [[ -z "$VPN_SUBNET_MANUAL" ]]; then
        EXISTING_IP="${EXISTING_ADDR%/*}"
        VPN_SUBNET="${EXISTING_IP%.*}.0/24"
        log "VPN subnet from existing server: $VPN_SUBNET"
    fi

    # Client management (only for our own server config)
    if [[ "$EXISTING_SRC" == "$SERVER_CONF" ]]; then
        # Find existing client configs
        EXISTING_CLIENTS=()
        for _cf in "$AWG_CONF_DIR"/client*.conf; do
            [[ -f "$_cf" ]] && EXISTING_CLIENTS+=("$_cf")
        done

        echo ""
        if [[ ${#EXISTING_CLIENTS[@]} -gt 0 ]]; then
            info "Client configs found:"
            for _i in "${!EXISTING_CLIENTS[@]}"; do
                echo "    $((_i+1))) $(basename "${EXISTING_CLIENTS[$_i]}")"
            done
            echo "    n) Create new client"
            echo "    s) Skip -- just (re)generate the tunnel, leave clients alone"
            echo ""
            if [[ -t 0 ]]; then
                echo -n "Show existing, create new, or skip? [s]: "
                read -r CLIENT_CHOICE || true    # EOF (Ctrl-D) -> fall through to default
                CLIENT_CHOICE="${CLIENT_CHOICE:-s}"
            else
                CLIENT_CHOICE="s"
                info "Non-interactive run -- skipping client management"
            fi
        else
            CLIENT_CHOICE="n"
        fi

        if [[ "$CLIENT_CHOICE" == "s" || "$CLIENT_CHOICE" == "S" ]]; then
            log "Skipping client management -- only the tunnel will be (re)generated"
        elif [[ "$CLIENT_CHOICE" == "n" || "$CLIENT_CHOICE" == "N" ]]; then
            # --- Create new client ---
            # Find next client number
            NEXT_NUM=1
            while [[ -f "$AWG_CONF_DIR/client${NEXT_NUM}.conf" ]]; do
                ((NEXT_NUM++))
            done

            # Read AWG params from server config
            _get() { grep -iP "^\s*$1\s*=" "$SERVER_CONF" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \r'; }
            SRV_PRIVATE="$(_get PrivateKey)"
            SRV_PUBLIC="$(echo "$SRV_PRIVATE" | "$BIN_CTL" pubkey)"
            SRV_PORT="$(_get ListenPort)"
            SRV_JC="$(_get Jc)"
            SRV_JMIN="$(_get Jmin)"
            SRV_JMAX="$(_get Jmax)"
            SRV_S1="$(_get S1)"
            SRV_S2="$(_get S2)"
            SRV_H1="$(_get H1)"
            SRV_H2="$(_get H2)"
            SRV_H3="$(_get H3)"
            SRV_H4="$(_get H4)"

            # New client IP: base + NEXT_NUM + 1 (server=.1, client1=.2, client2=.3, ...)
            NEW_CLIENT_IP="${VPN_SUBNET%.*/*}.$(( NEXT_NUM + 1 ))"

            # Generate keys
            NEW_CLI_PRIVATE="$("$BIN_CTL" genkey)"
            NEW_CLI_PUBLIC="$(echo "$NEW_CLI_PRIVATE" | "$BIN_CTL" pubkey)"
            NEW_CLI_PSK="$("$BIN_CTL" genpsk)"

            # Detect public IP
            PUBLIC_IP="$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null \
                || curl -s4 --max-time 5 icanhazip.com 2>/dev/null \
                || echo 'YOUR_SERVER_IP')"

            # Append peer to server config
            cat >> "$SERVER_CONF" << PEEREOF

[Peer]
PublicKey = ${NEW_CLI_PUBLIC}
PresharedKey = ${NEW_CLI_PSK}
AllowedIPs = ${NEW_CLIENT_IP}/32
PEEREOF

            # Create client config
            CLIENT_CONF_FILE="$AWG_CONF_DIR/client${NEXT_NUM}.conf"
            cat > "$CLIENT_CONF_FILE" << NEWCLIEOF
[Interface]
Address = ${NEW_CLIENT_IP}/32
DNS = 1.1.1.1, 1.0.0.1
PrivateKey = ${NEW_CLI_PRIVATE}
Jc = ${SRV_JC}
Jmin = ${SRV_JMIN}
Jmax = ${SRV_JMAX}
S1 = ${SRV_S1}
S2 = ${SRV_S2}
H1 = ${SRV_H1}
H2 = ${SRV_H2}
H3 = ${SRV_H3}
H4 = ${SRV_H4}

[Peer]
PublicKey = ${SRV_PUBLIC}
PresharedKey = ${NEW_CLI_PSK}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${PUBLIC_IP}:${SRV_PORT}
PersistentKeepalive = 25
NEWCLIEOF
            chmod 600 "$CLIENT_CONF_FILE"

            # Reload server to pick up new peer
            systemctl restart "${SVC_NAME}@${SERVER_INTERFACE}" 2>/dev/null || true

            log "Created client${NEXT_NUM}: $CLIENT_CONF_FILE (IP: ${NEW_CLIENT_IP})"
        else
            # Show existing client config. Validate numeric first -- arithmetic on
            # a non-numeric string is fatal under set -u.
            if [[ "$CLIENT_CHOICE" =~ ^[0-9]+$ ]]; then
                _idx=$(( CLIENT_CHOICE - 1 ))
            else
                _idx=-1
            fi
            if [[ $_idx -ge 0 && $_idx -lt ${#EXISTING_CLIENTS[@]} ]]; then
                CLIENT_CONF_FILE="${EXISTING_CLIENTS[$_idx]}"
                log "Selected: $(basename "$CLIENT_CONF_FILE")"
            else
                warn "Invalid choice, showing first client"
                CLIENT_CONF_FILE="${EXISTING_CLIENTS[0]}"
            fi
        fi
    fi
else
    log "Setting up AmneziaWG VPN server..."

    SUBNET_BASE="${VPN_SUBNET%/*}"
    SUBNET_MASK="${VPN_SUBNET#*/}"
    SERVER_ADDRESS="${SUBNET_BASE%.*}.1/${SUBNET_MASK}"
    FIRST_CLIENT_IP="${SUBNET_BASE%.*}.2"

    # Pick server port
    if [[ -z "$SERVER_PORT" ]]; then
        SERVER_PORT="$(shuf -i 20000-65000 -n 1)"
    fi

    # Generate keys
    SRV_PRIVATE="$("$BIN_CTL" genkey)"
    SRV_PUBLIC="$(echo "$SRV_PRIVATE" | "$BIN_CTL" pubkey)"
    CLI_PRIVATE="$("$BIN_CTL" genkey)"
    CLI_PUBLIC="$(echo "$CLI_PRIVATE" | "$BIN_CTL" pubkey)"
    CLI_PSK="$("$BIN_CTL" genpsk)"

    # Generate AWG obfuscation parameters
    AWG_JC="$(shuf -i 3-8 -n 1)"
    AWG_JMIN="$(shuf -i 50-150 -n 1)"
    AWG_JMAX="$(shuf -i 500-1000 -n 1)"
    AWG_S1="$(shuf -i 15-150 -n 1)"
    AWG_S2="$(shuf -i 15-150 -n 1)"
    AWG_H1="$(shuf -i 1-2147483647 -n 1)"
    AWG_H2="$(shuf -i 1-2147483647 -n 1)"
    AWG_H3="$(shuf -i 1-2147483647 -n 1)"
    AWG_H4="$(shuf -i 1-2147483647 -n 1)"

    # Detect public IP of this server
    PUBLIC_IP="$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null \
        || curl -s4 --max-time 5 icanhazip.com 2>/dev/null \
        || echo 'YOUR_SERVER_IP')"

    info "Server port: $SERVER_PORT"
    info "Public IP:   $PUBLIC_IP"

    # Create server config
    cat > "$SERVER_CONF" << SRVEOF
[Interface]
Address = ${SERVER_ADDRESS}
ListenPort = ${SERVER_PORT}
PrivateKey = ${SRV_PRIVATE}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

PostUp = iptables -I FORWARD 1 -i %i -j ACCEPT
PostUp = iptables -I FORWARD 1 -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT

[Peer]
PublicKey = ${CLI_PUBLIC}
PresharedKey = ${CLI_PSK}
AllowedIPs = ${FIRST_CLIENT_IP}/32
SRVEOF
    chmod 600 "$SERVER_CONF"

    # Generate client config
    CLIENT_CONF_FILE="$AWG_CONF_DIR/client1.conf"
    cat > "$CLIENT_CONF_FILE" << CLIFEOF
[Interface]
Address = ${FIRST_CLIENT_IP}/32
DNS = 1.1.1.1, 1.0.0.1
PrivateKey = ${CLI_PRIVATE}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

[Peer]
PublicKey = ${SRV_PUBLIC}
PresharedKey = ${CLI_PSK}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${PUBLIC_IP}:${SERVER_PORT}
PersistentKeepalive = 25
CLIFEOF
    chmod 600 "$CLIENT_CONF_FILE"

    # Open firewall port
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        log "Opening UFW port ${SERVER_PORT}/udp..."
        ufw allow "${SERVER_PORT}/udp" >/dev/null 2>&1
    fi

    SERVER_CREATED=true
    log "VPN server config: $SERVER_CONF"
    log "Client config:     $CLIENT_CONF_FILE"
fi

if [[ "$CLIENT_ONLY" != true ]]; then
    info "VPN subnet:  $VPN_SUBNET"
fi

# --- Create routing table (source-based routing -- chain mode only) ---

if [[ "$CLIENT_ONLY" != true ]]; then
    if ! grep -q "$ROUTE_TABLE_NAME" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "$ROUTE_TABLE_ID $ROUTE_TABLE_NAME" >> /etc/iproute2/rt_tables
        log "Routing table '$ROUTE_TABLE_NAME' (#$ROUTE_TABLE_ID) created"
    else
        log "Routing table '$ROUTE_TABLE_NAME' already exists"
    fi
fi

# --- Generate tunnel config (Server A -> Server B) ---

AWG_CONF="$AWG_CONF_DIR/${AWG_INTERFACE}.conf"

# Remember the current config so we can tell whether it actually changed
# (e.g. a new client.conf was provided) and restart the tunnel only if so.
AWG_CONF_OLD_HASH=""
[[ -f "$AWG_CONF" ]] && AWG_CONF_OLD_HASH="$(sha256sum "$AWG_CONF" 2>/dev/null | awk '{print $1}')"

log "Generating tunnel config: $AWG_CONF"

# [Interface] header.
#   chain mode:        Table = off  -- we do source-based routing ourselves
#   client-only mode:  no Table     -- awg-quick auto-creates the full-tunnel
#                                       default route (AllowedIPs = 0.0.0.0/0)
{
    echo "[Interface]"
    echo "Address = ${IFACE_ADDRESS}"
    echo "PrivateKey = ${IFACE_PRIVATE_KEY}"
    if [[ "$CLIENT_ONLY" != true ]]; then
        echo "Table = off"
    fi
} > "$AWG_CONF"

# DNS through the tunnel (client-only, avoids DNS leaks). awg-quick applies the
# DNS = directive via the `resolvconf` command; if it's missing we manage
# /etc/resolv.conf ourselves in PostUp/PostDown below.
DNS_VIA_DIRECTIVE=false
if [[ "$CLIENT_ONLY" == true && -n "$IFACE_DNS" ]] && command -v resolvconf &>/dev/null; then
    echo "DNS = ${IFACE_DNS}" >> "$AWG_CONF"
    DNS_VIA_DIRECTIVE=true
fi

# Add AmneziaWG parameters (non-empty only)
for param in Jc:IFACE_JC Jmin:IFACE_JMIN Jmax:IFACE_JMAX \
             S1:IFACE_S1 S2:IFACE_S2 S3:IFACE_S3 S4:IFACE_S4 \
             H1:IFACE_H1 H2:IFACE_H2 H3:IFACE_H3 H4:IFACE_H4 \
             I1:IFACE_I1 I2:IFACE_I2 I3:IFACE_I3 I4:IFACE_I4 I5:IFACE_I5; do
    pname="${param%%:*}"
    pvar="${param##*:}"
    pval="${!pvar}"
    if [[ -n "$pval" ]]; then
        echo "$pname = $pval" >> "$AWG_CONF"
    fi
done

# --- Routing rules (PostUp / PostDown) ---
if [[ "$CLIENT_ONLY" == true ]]; then
    # Client-only: awg-quick installs the full-tunnel default route + endpoint
    # protection (AllowedIPs = 0.0.0.0/0). We add rules so inbound sessions (SSH)
    # survive: reply traffic from ANY local address -- and to the admin source --
    # stays on the main table. Added in PreUp (before the tunnel routing) so there
    # is no window. IPv6 rules too when ::/0 is routed.
    {
        echo ""
        echo "# Keep inbound connections (SSH, etc.) on the real link -- no lockout"
    } >> "$AWG_CONF"
    _ssh_rules=0
    if [[ -n "$SSH_CLIENT_IP4" ]]; then
        echo "PreUp = ip rule add to ${SSH_CLIENT_IP4} table main priority 90 2>/dev/null || true" >> "$AWG_CONF"
        echo "PostDown = ip rule del to ${SSH_CLIENT_IP4} table main priority 90 2>/dev/null || true" >> "$AWG_CONF"
        _ssh_rules=1
    fi
    for _lip in ${LOCAL_IPS4[@]+"${LOCAL_IPS4[@]}"}; do
        echo "PreUp = ip rule add from ${_lip} table main priority 100 2>/dev/null || true" >> "$AWG_CONF"
        echo "PostDown = ip rule del from ${_lip} table main priority 100 2>/dev/null || true" >> "$AWG_CONF"
        _ssh_rules=1
    done
    if [[ "$HAS_IPV6" == true ]]; then
        if [[ -n "$SSH_CLIENT_IP6" ]]; then
            echo "PreUp = ip -6 rule add to ${SSH_CLIENT_IP6} table main priority 90 2>/dev/null || true" >> "$AWG_CONF"
            echo "PostDown = ip -6 rule del to ${SSH_CLIENT_IP6} table main priority 90 2>/dev/null || true" >> "$AWG_CONF"
        fi
        for _lip6 in ${LOCAL_IPS6[@]+"${LOCAL_IPS6[@]}"}; do
            echo "PreUp = ip -6 rule add from ${_lip6} table main priority 100 2>/dev/null || true" >> "$AWG_CONF"
            echo "PostDown = ip -6 rule del from ${_lip6} table main priority 100 2>/dev/null || true" >> "$AWG_CONF"
        done
    fi
    [[ "$_ssh_rules" == 0 ]] && warn "No local/SSH address detected -- SSH-preservation rules NOT written; you could be locked out (keep a console open)."

    # DNS: if resolvconf is absent, point /etc/resolv.conf at the tunnel DNS
    # ourselves. Back up ONCE, preserving a systemd-resolved symlink; restore on
    # down. Backup lives in the (renamed) config dir -- keyword-free, and cleaned
    # up (and restored) by teardown_scheme even if PostDown never runs.
    if [[ -n "$IFACE_DNS" && "$DNS_VIA_DIRECTIVE" != true ]]; then
        DNS_WRITE=""
        for _d in $(echo "$IFACE_DNS" | tr ',' ' '); do
            if _is_ip "$_d"; then
                DNS_WRITE+="echo nameserver $_d; "   # IP-only: value goes into a root-run command
            else
                warn "Ignoring non-IP DNS entry from config: '$_d'"
            fi
        done
        if [[ -n "$DNS_WRITE" ]]; then
            _bak="${AWG_CONF_DIR}/.resolv.bak"
            {
                echo "PreUp = if [ ! -e ${_bak} ] && [ ! -L ${_bak} ]; then cp -a /etc/resolv.conf ${_bak} 2>/dev/null || true; fi"
                echo "PostUp = rm -f /etc/resolv.conf; { ${DNS_WRITE}} > /etc/resolv.conf 2>/dev/null || true"
                echo "PostDown = if [ -e ${_bak} ] || [ -L ${_bak} ]; then rm -f /etc/resolv.conf; cp -a ${_bak} /etc/resolv.conf 2>/dev/null; rm -f ${_bak}; fi"
            } >> "$AWG_CONF"
        fi
    fi
else
    cat >> "$AWG_CONF" << AWGEOF

# Route to endpoint via real gateway (prevent tunnel loop)
PostUp = ip route add ${ENDPOINT_ADDR}/32 via ${DEFAULT_GW} dev ${DEFAULT_IFACE} 2>/dev/null || true

# Default via tunnel -- separate routing table only (replace = idempotent, so a
# stale entry from an unclean teardown does not abort bring-up under set -e)
PostUp = ip route replace default dev %i table ${ROUTE_TABLE_NAME}

# VPN client traffic -> through tunnel (guarded so a leftover rule cannot abort)
PostUp = ip rule add from ${VPN_SUBNET} table ${ROUTE_TABLE_NAME} priority 10 2>/dev/null || true

# Allow forwarding through tunnel
PostUp = iptables -I FORWARD 1 -i %i -j ACCEPT
PostUp = iptables -I FORWARD 1 -o %i -j ACCEPT

# NAT: rewrite client src IP to tunnel IP so Server B accepts it
PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE

PostDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE 2>/dev/null || true
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true
PostDown = ip rule del from ${VPN_SUBNET} table ${ROUTE_TABLE_NAME} priority 10 2>/dev/null || true
PostDown = ip route del default dev %i table ${ROUTE_TABLE_NAME} 2>/dev/null || true
PostDown = ip route del ${ENDPOINT_ADDR}/32 via ${DEFAULT_GW} dev ${DEFAULT_IFACE} 2>/dev/null || true
AWGEOF
fi

# --- [Peer] ---
{
    echo ""
    echo "[Peer]"
    echo "PublicKey = ${PEER_PUBLIC_KEY}"
} >> "$AWG_CONF"

if [[ -n "$PEER_PRESHARED_KEY" ]]; then
    echo "PresharedKey = ${PEER_PRESHARED_KEY}" >> "$AWG_CONF"
fi

# AllowedIPs: full tunnel in client-only mode (route everything through Server B)
if [[ "$CLIENT_ONLY" == true ]]; then
    if [[ "$HAS_IPV6" == true ]]; then
        echo "AllowedIPs = 0.0.0.0/0, ::/0" >> "$AWG_CONF"
    else
        echo "AllowedIPs = 0.0.0.0/0" >> "$AWG_CONF"
    fi
else
    echo "AllowedIPs = ${PEER_ALLOWED_IPS}" >> "$AWG_CONF"
fi

echo "Endpoint = ${PEER_ENDPOINT}" >> "$AWG_CONF"

if [[ -n "$PEER_KEEPALIVE" ]]; then
    echo "PersistentKeepalive = ${PEER_KEEPALIVE}" >> "$AWG_CONF"
elif [[ "$CLIENT_ONLY" == true ]]; then
    # Keep the tunnel alive through NAT so the box stays connected
    echo "PersistentKeepalive = 25" >> "$AWG_CONF"
fi

chmod 600 "$AWG_CONF"

# Did the tunnel config actually change vs the previous run?
AWG_CONF_NEW_HASH="$(sha256sum "$AWG_CONF" 2>/dev/null | awk '{print $1}')"
AWG_CONF_CHANGED=true
if [[ -n "$AWG_CONF_OLD_HASH" && "$AWG_CONF_OLD_HASH" == "$AWG_CONF_NEW_HASH" ]]; then
    AWG_CONF_CHANGED=false
fi

# --- Resolve userspace engine (verbose/mimicry) + write systemd service ---

# Signature of the current service unit + launch wrapper, so we can tell whether
# the engine settings (mimicry on/off, profile, verbose) actually changed and
# restart a running tunnel only when they did.
_svc_sig() {
    { cat "/etc/systemd/system/${SVC_NAME}@.service" 2>/dev/null; \
      cat "$BIN_LAUNCH" 2>/dev/null; } \
        | sha256sum 2>/dev/null | awk '{print $1}' || true
}
OLD_SVC_SIG="$(_svc_sig)"

resolve_userspace_impl      # sets AWG_GO_IMPL + engine launch wrapper
write_awg_service           # writes the ${SVC_NAME}@ unit, daemon-reload
record_scheme               # persist (or clear) the active-scheme state file

SERVICE_ENV_CHANGED=false
[[ "$(_svc_sig)" != "$OLD_SVC_SIG" ]] && SERVICE_ENV_CHANGED=true

# --- Start services ---

# Bring up the VPN server whenever a server config exists for this scheme and we
# are not in --no-server/--client-only mode. This must NOT be gated on
# SERVER_CREATED: after a stealth migration the server config is *moved* into the
# new scheme (so detect_existing_server sees it as pre-existing, SERVER_CREATED
# stays false), yet the renamed unit still needs to be enabled+started -- else the
# server silently never comes up and all clients drop.
if [[ "$NO_SERVER" != true && -f "$SERVER_CONF" ]]; then
    if systemctl is-active "${SVC_NAME}@${SERVER_INTERFACE}" &>/dev/null; then
        systemctl enable "${SVC_NAME}@${SERVER_INTERFACE}" &>/dev/null || true
        if [[ "$SERVICE_ENV_CHANGED" == true ]]; then
            log "Engine settings changed -- restarting VPN server (${SERVER_INTERFACE})..."
            systemctl restart "${SVC_NAME}@${SERVER_INTERFACE}" 2>/dev/null || \
                warn "Failed to restart VPN server, try manually: systemctl restart ${SVC_NAME}@${SERVER_INTERFACE}"
        fi
    else
        log "Starting VPN server (${SERVER_INTERFACE})..."
        systemctl enable --now "${SVC_NAME}@${SERVER_INTERFACE}" 2>/dev/null || \
            warn "Failed to start VPN server, try manually: systemctl start ${SVC_NAME}@${SERVER_INTERFACE}"
    fi
fi

if systemctl is-active "${SVC_NAME}@${AWG_INTERFACE}" &>/dev/null; then
    # Already running -- restart only if the tunnel config OR the engine
    # settings (stealth/verbose) actually changed.
    systemctl enable "${SVC_NAME}@${AWG_INTERFACE}" &>/dev/null || true
    if [[ "$AWG_CONF_CHANGED" == true || "$SERVICE_ENV_CHANGED" == true ]]; then
        log "Config/engine changed -- restarting tunnel (${AWG_INTERFACE})..."
        systemctl restart "${SVC_NAME}@${AWG_INTERFACE}" 2>/dev/null || {
            warn "Failed to restart tunnel, try manually: systemctl restart ${SVC_NAME}@${AWG_INTERFACE}"
        }
    else
        log "Tunnel config unchanged -- ${AWG_INTERFACE} already up, not restarting"
    fi
else
    log "Starting tunnel (${AWG_INTERFACE})..."
    systemctl enable --now "${SVC_NAME}@${AWG_INTERFACE}" 2>/dev/null || {
        warn "Failed to start tunnel, try manually: systemctl start ${SVC_NAME}@${AWG_INTERFACE}"
    }
fi

# Verify the interfaces actually came up. The units are Type=oneshot
# RemainAfterExit, so they report 'active' even if the interface never
# established -- check the links directly so the final banner is honest.
TUNNEL_OK=true
if ! ip link show "$AWG_INTERFACE" &>/dev/null; then
    TUNNEL_OK=false
    warn "Tunnel interface ${AWG_INTERFACE} did not come up -- bring-up likely failed."
    warn "Diagnose: journalctl -u ${SVC_NAME}@${AWG_INTERFACE} -n50 ; sudo $0 --status"
fi
if [[ "$NO_SERVER" != true && -f "$SERVER_CONF" ]] && ! ip link show "$SERVER_INTERFACE" &>/dev/null; then
    TUNNEL_OK=false
    warn "VPN server interface ${SERVER_INTERFACE} did not come up -- clients cannot connect."
    warn "Diagnose: journalctl -u ${SVC_NAME}@${SERVER_INTERFACE} -n50 ; sudo $0 --status"
fi

# --- Show results ---

echo ""
echo "============================================================================"
if [[ "$TUNNEL_OK" == true ]]; then
    log "Installation complete!"
else
    warn "Installation finished WITH ERRORS -- the tunnel is not up (see warnings above)."
fi
echo "============================================================================"

if [[ "$SERVER_CREATED" == true ]]; then
    echo ""
    echo -e "${CYAN}VPN Server:${NC}"
    info "Config:     $SERVER_CONF"
    info "Interface:  $SERVER_INTERFACE"
    info "Port:       $SERVER_PORT"
    info "Subnet:     $VPN_SUBNET"
fi

echo ""
if [[ "$CLIENT_ONLY" == true ]]; then
    echo -e "${CYAN}Tunnel (this box -> Server B):${NC}"
else
    echo -e "${CYAN}Tunnel to Server B:${NC}"
fi
info "Config:     $AWG_CONF"
info "Interface:  $AWG_INTERFACE"
info "Endpoint:   $ENDPOINT_HOST:$ENDPOINT_PORT"
if [[ "$CLIENT_ONLY" == true ]]; then
    info "Mode:       client-only (full tunnel -- all of this box's traffic)"
else
    info "Route table: $ROUTE_TABLE_NAME (#$ROUTE_TABLE_ID)"
fi

if [[ "$STEALTH" == true ]]; then
    echo ""
    echo -e "${CYAN}Stealth (disguised as ${MIMIC_PROFILE}):${NC}"
    info "Process:    '${MIMIC_ARGV0}' (name: ${MIMIC_NAME})"
    info "Interface:  ${AWG_INTERFACE} (tunnel)"
    [[ "$CLIENT_ONLY" != true ]] && info "            ${SERVER_INTERFACE} (VPN server)"
    info "Config dir: ${AWG_CONF_DIR}"
    info "Unit:       ${SVC_NAME}@${AWG_INTERFACE}"
    info "Engine:     ${BIN_ENGINE}"
    info "Nothing on this box reads awg/wg/amnezia."
fi

echo ""
echo -e "${CYAN}Management:${NC}"
echo ""
echo "  ${BIN_CTL} show                            # interfaces (control tool)"
echo "  systemctl status  ${SVC_NAME}@${AWG_INTERFACE}"
echo "  systemctl restart ${SVC_NAME}@${AWG_INTERFACE}"
if [[ "$STEALTH" == true ]]; then
    echo "  sudo $0 <config> --unmimic       # drop the '${MIMIC_PROFILE}' disguise"
else
    echo "  sudo $0 <config> --mimic         # full stealth (disguise as nginx)"
fi
echo ""
if [[ "$CLIENT_ONLY" == true ]]; then
    echo "  # Verify (should show Server B's IP):"
    echo "  curl -4 ifconfig.me"
else
    echo "  # Verify (should show server B IP):"
    echo "  curl --interface ${IFACE_ADDRESS%/*} -4 ifconfig.me"
fi

echo ""
echo -e "${CYAN}Logs & diagnostics:${NC}"
echo ""
echo "  sudo $0 --status                           # full diagnostic"
echo "  cat ${LOG_FILE}                  # install log"
if [[ "$VERBOSE" == true ]]; then
    echo "  tail -f ${AWG_LOG_DIR}/${AWG_INTERFACE}.log        # tunnel runtime (live)"
    echo "  tail -f ${AWG_LOG_DIR}/${SERVER_INTERFACE}.log         # VPN server runtime (live)"
    echo ""
    echo "  # To disable verbose logging, re-run without --verbose"
else
    echo ""
    echo "  # To enable runtime logging, re-run with --verbose"
fi

if [[ -n "$CLIENT_CONF_FILE" && -f "$CLIENT_CONF_FILE" ]]; then
    echo ""
    echo "============================================================================"
    echo -e "${GREEN}Client config for Amnezia app:${NC} $CLIENT_CONF_FILE"
    echo "============================================================================"
    echo ""
    cat "$CLIENT_CONF_FILE"
    echo ""
    if command -v qrencode &>/dev/null; then
        echo "============================================================================"
        echo ""
        info "QR code (for standard WireGuard apps):"
        echo ""
        qrencode -t ansiutf8 < "$CLIENT_CONF_FILE"
        echo ""
    fi
    echo "============================================================================"
    echo ""
    warn "Amnezia app does NOT support QR/text import for AmneziaWG configs."
    info "To import: save the config above to a .conf file on your device,"
    info "then use 'Import' -> 'File' in the Amnezia app."
fi

echo ""
echo -e "${YELLOW}Notes:${NC}"
if [[ "$CLIENT_ONLY" == true ]]; then
    echo "  - ALL of this box's outbound traffic now goes through Server B"
    if [[ -n "$SSH_CLIENT_IP" || -n "$LOCAL_IP" ]]; then
        echo "  - SSH access is preserved (inbound connections stay on the real link)"
    fi
    echo "  - Server B must masquerade/NAT the tunnel traffic (see README: Server B setup)"
else
    echo "  - SSH and direct connections to this server are NOT affected"
    echo "  - All VPN client traffic (${VPN_SUBNET}) goes through Server B"
fi
if [[ "$STEALTH" == true ]]; then
    echo "  - Stealth ON: interfaces, config dir, unit, binaries and logs are all"
    echo "    renamed after '${MIMIC_PROFILE}' -- nothing reads awg/wg/amnezia."
    echo "  - A real ${MIMIC_PROFILE} (if installed) is untouched (private paths, no ports)."
    echo "  - Manage with: ${BIN_CTL} show   and   systemctl ... ${SVC_NAME}@${AWG_INTERFACE}"
fi
echo ""
