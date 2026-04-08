#!/bin/bash
set -euo pipefail

# ============================================================================
# AmneziaWG Full Setup: VPN Server + Tunnel
# ============================================================================
# Sets up an AmneziaWG VPN server and a tunnel to a second server.
# All VPN client traffic is routed through the tunnel (source-based routing).
# SSH and direct connections remain unaffected.
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
exec > >(tee -a "$LOG_FILE") 2>&1

_ts() { date '+%H:%M:%S'; }
log()  { echo -e "$(_ts) ${GREEN}[+]${NC} $*"; }
warn() { echo -e "$(_ts) ${YELLOW}[!]${NC} $*"; }
err()  { echo -e "$(_ts) ${RED}[x]${NC} $*" >&2; }
info() { echo -e "$(_ts) ${CYAN}[i]${NC} $*"; }

# --- Checks ---

if [[ $EUID -ne 0 ]]; then
    err "Run as root: sudo $0 $*"
    exit 1
fi

CONFIG_FILE=""
VPN_SUBNET=""
VPN_SUBNET_MANUAL=""
AWG_INTERFACE="awg0"
SERVER_INTERFACE="wg0"
SERVER_PORT=""
NO_SERVER=false
FORCE=false
VERBOSE=false
ROUTE_TABLE_NAME="via_tunnel"
ROUTE_TABLE_ID="200"
TEMP_CONFIG=""

cleanup_temp() {
    [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]] && rm -f "$TEMP_CONFIG"
}
trap cleanup_temp EXIT

usage() {
    echo "Usage: sudo $0 [config-file] [options]"
    echo ""
    echo "Sets up an AmneziaWG VPN server and a tunnel to a second server."
    echo "If config-file is omitted, you will be prompted to paste it."
    echo ""
    echo "Options:"
    echo "  --vpn-subnet CIDR    VPN client subnet (default: 10.8.1.0/24)"
    echo "  --server-port PORT   VPN server listen port (default: random)"
    echo "  --interface NAME     Tunnel interface name (default: awg0)"
    echo "  --no-server          Skip VPN server setup (tunnel only)"
    echo "  --verbose            Enable runtime logging to /var/log/amneziawg/"
    echo "  --force              Force rebuild of amneziawg binaries"
    echo "  --uninstall          Remove everything and exit"
    echo "  --status             Show diagnostic info and exit"
    echo "  --help               Show this help"
    echo ""
    echo "Examples:"
    echo "  sudo $0 client.conf"
    echo "  sudo $0 client.conf --server-port 51820"
    echo "  sudo $0 --status                 # check everything is working"
    echo "  sudo $0 --uninstall              # remove everything"
    exit 0
}

# --- Argument parsing ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vpn-subnet)
            VPN_SUBNET_MANUAL="$2"
            shift 2
            ;;
        --server-port)
            SERVER_PORT="$2"
            shift 2
            ;;
        --interface)
            AWG_INTERFACE="$2"
            shift 2
            ;;
        --no-server)
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
        --uninstall)
            log "Uninstalling AmneziaWG..."
            echo ""

            # Stop and disable services
            for _svc in awg-quick@awg0 awg-quick@wg0; do
                if systemctl is-active "$_svc" &>/dev/null; then
                    log "Stopping $_svc..."
                    systemctl stop "$_svc" 2>/dev/null || true
                fi
                systemctl disable "$_svc" 2>/dev/null || true
            done

            # Remove configs
            if [[ -d /etc/amnezia/amneziawg ]]; then
                log "Removing /etc/amnezia/amneziawg/..."
                rm -rf /etc/amnezia/amneziawg
            fi

            # Remove systemd unit
            rm -f /etc/systemd/system/awg-quick@.service
            systemctl daemon-reload

            # Remove binaries
            rm -f /usr/local/bin/amneziawg-go /usr/local/bin/amneziawg-go-log /usr/local/bin/awg /usr/local/bin/awg-quick

            # Remove runtime logs
            rm -rf /var/log/amneziawg

            # Remove source dirs
            rm -rf /opt/amneziawg-go /opt/amneziawg-tools

            # Remove routing table entry
            if [[ -f /etc/iproute2/rt_tables ]]; then
                sed -i '/via_tunnel/d' /etc/iproute2/rt_tables
            fi

            # Clean up ip rules (best effort)
            ip rule del table via_tunnel 2>/dev/null || true

            log "Uninstall complete"
            info "ip_forward and /etc/sysctl.conf were left unchanged"
            info "Go (/usr/local/go) was left in place"
            exit 0
            ;;
        --status)
            echo ""
            echo "=== AmneziaWG Diagnostics ==="
            echo ""

            echo "-- Interfaces --"
            awg show 2>/dev/null || echo "  awg not installed or no interfaces up"
            echo ""

            echo "-- Services --"
            for _svc in awg-quick@wg0 awg-quick@awg0; do
                _state="$(systemctl is-active "$_svc" 2>/dev/null || true)"
                printf "  %-28s %s\n" "$_svc" "$_state"
            done
            echo ""

            echo "-- Routing --"
            echo "  ip rules:"
            ip rule show 2>/dev/null | grep -E '(via_tunnel|from)' | sed 's/^/    /'
            echo "  table via_tunnel:"
            ip route show table via_tunnel 2>/dev/null | sed 's/^/    /' || echo "    (empty or not found)"
            echo ""

            echo "-- Last 20 log lines: tunnel (awg0) --"
            if [[ -f /var/log/amneziawg/awg0.log ]]; then
                tail -20 /var/log/amneziawg/awg0.log
            else
                echo "  no log file (not started yet?)"
            fi
            echo ""

            echo "-- Last 20 log lines: server (wg0) --"
            if [[ -f /var/log/amneziawg/wg0.log ]]; then
                tail -20 /var/log/amneziawg/wg0.log
            else
                echo "  no log file (not started yet?)"
            fi
            echo ""

            echo "-- Connectivity --"
            _tunnel_ip="$(ip -4 -o addr show dev awg0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
            if [[ -n "$_tunnel_ip" ]]; then
                echo -n "  Exit IP (via tunnel): "
                curl -s4 --max-time 5 --interface "$_tunnel_ip" ifconfig.me 2>/dev/null || echo "FAILED"
            else
                echo "  Tunnel interface awg0 not up"
            fi
            echo ""

            echo "-- Log files --"
            echo "  Runtime:  /var/log/amneziawg/"
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

ENDPOINT_HOST="${PEER_ENDPOINT%%:*}"
ENDPOINT_PORT="${PEER_ENDPOINT##*:}"

info "Endpoint:    $ENDPOINT_HOST:$ENDPOINT_PORT"
info "Address:     $IFACE_ADDRESS"

# --- Detect default gateway and interface ---

DEFAULT_GW="$(ip route show default | awk '/default/ {print $3}' | head -1)"
DEFAULT_IFACE="$(ip route show default | awk '/default/ {print $5}' | head -1)"

if [[ -z "$DEFAULT_GW" || -z "$DEFAULT_IFACE" ]]; then
    err "Failed to detect default gateway / interface"
    exit 1
fi

info "Default GW:  $DEFAULT_GW via $DEFAULT_IFACE"

# --- Install dependencies ---

log "Installing dependencies..."

apt-get update -qq
apt-get install -y -qq git make gcc golang >/dev/null 2>&1 || {
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
    if [[ ! -f "$GO_TAR_PATH" ]]; then
        wget -q "https://go.dev/dl/$GO_TAR" -O "$GO_TAR_PATH" 2>/dev/null || {
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

# --- Build amneziawg-go ---

AWG_GO_DIR="/opt/amneziawg-go"
AWG_TOOLS_DIR="/opt/amneziawg-tools"

if [[ ! -f /usr/local/bin/amneziawg-go || "$FORCE" == true ]]; then
    [[ "$FORCE" == true ]] && log "Force rebuilding amneziawg-go..."
    log "Building amneziawg-go..."

    if [[ -d "$AWG_GO_DIR" ]]; then
        cd "$AWG_GO_DIR" && git pull -q
    else
        git clone -q https://github.com/amnezia-vpn/amneziawg-go.git "$AWG_GO_DIR"
    fi

    cd "$AWG_GO_DIR"
    [[ "$FORCE" == true ]] && make clean 2>/dev/null || true
    make -j"$(nproc)" 2>&1 | tail -3
    cp amneziawg-go /usr/local/bin/
    chmod +x /usr/local/bin/amneziawg-go
    log "amneziawg-go built and installed"
else
    log "amneziawg-go already installed (use --force to rebuild)"
fi

# --- Build amneziawg-tools (awg) ---

if [[ ! -f /usr/local/bin/awg || "$FORCE" == true ]]; then
    [[ "$FORCE" == true ]] && log "Force rebuilding amneziawg-tools..."
    log "Building amneziawg-tools..."

    if [[ -d "$AWG_TOOLS_DIR" ]]; then
        cd "$AWG_TOOLS_DIR" && git pull -q
    else
        git clone -q https://github.com/amnezia-vpn/amneziawg-tools.git "$AWG_TOOLS_DIR"
    fi

    cd "$AWG_TOOLS_DIR/src"
    [[ "$FORCE" == true ]] && make clean 2>/dev/null || true
    make -j"$(nproc)" 2>&1 | tail -3
    cp wg /usr/local/bin/awg
    chmod +x /usr/local/bin/awg

    # Also copy wg-quick with awg support
    if [[ -f "$AWG_TOOLS_DIR/src/wg-quick/linux.bash" ]]; then
        cp "$AWG_TOOLS_DIR/src/wg-quick/linux.bash" /usr/local/bin/awg-quick
        chmod +x /usr/local/bin/awg-quick
    fi

    log "awg (amneziawg-tools) built and installed"
else
    log "awg already installed (use --force to rebuild)"
fi

# --- Enable IP forwarding ---

log "Enabling ip_forward..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q '^net.ipv4.ip_forward\s*=\s*1' /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi

# --- VPN Server Setup ---

AWG_CONF_DIR="/etc/amnezia/amneziawg"
mkdir -p "$AWG_CONF_DIR"

SERVER_CONF="$AWG_CONF_DIR/${SERVER_INTERFACE}.conf"
CLIENT_CONF_FILE=""
SERVER_CREATED=false

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
        /etc/wireguard/wg*.conf \
        /etc/amnezia/amneziawg/*.conf; do
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
    log "VPN server setup skipped (--no-server)"
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
            echo ""
            echo -n "Show existing or create new? [1]: "
            read -r CLIENT_CHOICE
            CLIENT_CHOICE="${CLIENT_CHOICE:-1}"
        else
            CLIENT_CHOICE="n"
        fi

        if [[ "$CLIENT_CHOICE" == "n" || "$CLIENT_CHOICE" == "N" ]]; then
            # --- Create new client ---
            # Find next client number
            NEXT_NUM=1
            while [[ -f "$AWG_CONF_DIR/client${NEXT_NUM}.conf" ]]; do
                ((NEXT_NUM++))
            done

            # Read AWG params from server config
            _get() { grep -iP "^\s*$1\s*=" "$SERVER_CONF" | head -1 | sed 's/.*=\s*//' | tr -d ' '; }
            SRV_PRIVATE="$(_get PrivateKey)"
            SRV_PUBLIC="$(echo "$SRV_PRIVATE" | awg pubkey)"
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
            NEW_CLI_PRIVATE="$(awg genkey)"
            NEW_CLI_PUBLIC="$(echo "$NEW_CLI_PRIVATE" | awg pubkey)"
            NEW_CLI_PSK="$(awg genpsk)"

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
            systemctl restart awg-quick@${SERVER_INTERFACE} 2>/dev/null || true

            log "Created client${NEXT_NUM}: $CLIENT_CONF_FILE (IP: ${NEW_CLIENT_IP})"
        else
            # Show existing client config
            _idx=$(( CLIENT_CHOICE - 1 ))
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
    SRV_PRIVATE="$(awg genkey)"
    SRV_PUBLIC="$(echo "$SRV_PRIVATE" | awg pubkey)"
    CLI_PRIVATE="$(awg genkey)"
    CLI_PUBLIC="$(echo "$CLI_PRIVATE" | awg pubkey)"
    CLI_PSK="$(awg genpsk)"

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

PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT

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

    SERVER_CREATED=true
    log "VPN server config: $SERVER_CONF"
    log "Client config:     $CLIENT_CONF_FILE"
fi

info "VPN subnet:  $VPN_SUBNET"

# --- Create routing table ---

if ! grep -q "$ROUTE_TABLE_NAME" /etc/iproute2/rt_tables 2>/dev/null; then
    echo "$ROUTE_TABLE_ID $ROUTE_TABLE_NAME" >> /etc/iproute2/rt_tables
    log "Routing table '$ROUTE_TABLE_NAME' (#$ROUTE_TABLE_ID) created"
else
    log "Routing table '$ROUTE_TABLE_NAME' already exists"
fi

# --- Generate tunnel config (Server A -> Server B) ---

AWG_CONF="$AWG_CONF_DIR/${AWG_INTERFACE}.conf"

log "Generating tunnel config: $AWG_CONF"

cat > "$AWG_CONF" << AWGEOF
[Interface]
Address = ${IFACE_ADDRESS}
PrivateKey = ${IFACE_PRIVATE_KEY}
Table = off
AWGEOF

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
cat >> "$AWG_CONF" << AWGEOF

# Route to endpoint via real gateway (prevent tunnel loop)
PostUp = ip route add ${ENDPOINT_HOST}/32 via ${DEFAULT_GW} dev ${DEFAULT_IFACE} 2>/dev/null || true

# Default via tunnel -- separate routing table only
PostUp = ip route add default dev %i table ${ROUTE_TABLE_NAME}

# VPN client traffic -> through tunnel
PostUp = ip rule add from ${VPN_SUBNET} table ${ROUTE_TABLE_NAME} priority 10

PostDown = ip rule del from ${VPN_SUBNET} table ${ROUTE_TABLE_NAME} priority 10 2>/dev/null || true
PostDown = ip route del default dev %i table ${ROUTE_TABLE_NAME} 2>/dev/null || true
PostDown = ip route del ${ENDPOINT_HOST}/32 via ${DEFAULT_GW} dev ${DEFAULT_IFACE} 2>/dev/null || true

[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
AWGEOF

if [[ -n "$PEER_PRESHARED_KEY" ]]; then
    echo "PresharedKey = ${PEER_PRESHARED_KEY}" >> "$AWG_CONF"
fi

cat >> "$AWG_CONF" << AWGEOF
AllowedIPs = ${PEER_ALLOWED_IPS}
Endpoint = ${PEER_ENDPOINT}
AWGEOF

if [[ -n "$PEER_KEEPALIVE" ]]; then
    echo "PersistentKeepalive = ${PEER_KEEPALIVE}" >> "$AWG_CONF"
fi

chmod 600 "$AWG_CONF"

# --- Create logging wrapper for amneziawg-go ---

AWG_LOG_DIR="/var/log/amneziawg"
AWG_GO_IMPL="amneziawg-go"

if [[ "$VERBOSE" == true ]]; then
    mkdir -p "$AWG_LOG_DIR"
    log "Verbose mode: runtime logs -> $AWG_LOG_DIR/"

    cat > /usr/local/bin/amneziawg-go-log << LOGEOF
#!/bin/bash
IFACE="\${1:-unknown}"
LOG="${AWG_LOG_DIR}/\${IFACE}.log"
echo "[\$(date)] amneziawg-go starting: \$IFACE" >> "\$LOG"
export LOG_LEVEL=verbose
exec /usr/local/bin/amneziawg-go "\$@" >> "\$LOG" 2>&1
LOGEOF
    chmod +x /usr/local/bin/amneziawg-go-log
    AWG_GO_IMPL="amneziawg-go-log"
else
    log "Runtime logging disabled (use --verbose to enable)"
fi

# --- Create systemd service ---

log "Creating systemd service..."

cat > "/etc/systemd/system/awg-quick@.service" << SVCEOF
[Unit]
Description=AmneziaWG Tunnel via awg-quick (%i)
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=${AWG_GO_IMPL}
ExecStart=/usr/local/bin/awg-quick up %i
ExecStop=/usr/local/bin/awg-quick down %i

[Install]
WantedBy=multi-user.target
SVCEOF

# If awg-quick was not compiled, use fallback wrapper via wg-quick
if [[ ! -f /usr/local/bin/awg-quick ]]; then
    warn "awg-quick not found, creating wrapper..."

    cat > /usr/local/bin/awg-quick << WRAPEOF
#!/bin/bash
# Wrapper: uses standard wg-quick with userspace amneziawg-go
export WG_QUICK_USERSPACE_IMPLEMENTATION=${AWG_GO_IMPL}
export WG=/usr/local/bin/awg

# wg-quick expects configs in /etc/wireguard or full path
ACTION="\$1"
IFACE="\$2"

if [[ -f "/etc/amnezia/amneziawg/\${IFACE}.conf" ]]; then
    exec wg-quick "\$ACTION" "/etc/amnezia/amneziawg/\${IFACE}.conf"
elif [[ -f "\$IFACE" ]]; then
    exec wg-quick "\$ACTION" "\$IFACE"
else
    echo "Config not found for \$IFACE"
    exit 1
fi
WRAPEOF
    chmod +x /usr/local/bin/awg-quick
fi

systemctl daemon-reload

# --- Start services ---

if [[ "$SERVER_CREATED" == true ]]; then
    log "Starting VPN server (${SERVER_INTERFACE})..."
    systemctl enable --now awg-quick@${SERVER_INTERFACE} 2>/dev/null || {
        warn "Failed to start VPN server, try manually: systemctl start awg-quick@${SERVER_INTERFACE}"
    }
fi

log "Starting tunnel (${AWG_INTERFACE})..."
systemctl enable --now awg-quick@${AWG_INTERFACE} 2>/dev/null || {
    warn "Failed to start tunnel, try manually: systemctl start awg-quick@${AWG_INTERFACE}"
}

# --- Show results ---

echo ""
echo "============================================================================"
log "Installation complete!"
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
echo -e "${CYAN}Tunnel to Server B:${NC}"
info "Config:     $AWG_CONF"
info "Interface:  $AWG_INTERFACE"
info "Endpoint:   $ENDPOINT_HOST:$ENDPOINT_PORT"
info "Route table: $ROUTE_TABLE_NAME (#$ROUTE_TABLE_ID)"

echo ""
echo -e "${CYAN}Management:${NC}"
echo ""
echo "  awg show                                  # all interfaces"
echo "  systemctl status  awg-quick@${AWG_INTERFACE}       # tunnel status"
echo "  systemctl restart awg-quick@${AWG_INTERFACE}       # restart tunnel"
echo ""
echo "  # Verify (should show server B IP):"
echo "  curl --interface ${IFACE_ADDRESS%/*} -4 ifconfig.me"

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
    echo "============================================================================"
    echo ""
    info "Import this config into the Amnezia app to connect."
    info "Or scan the QR code (if qrencode is installed):"
    echo "  qrencode -t ansiutf8 < $CLIENT_CONF_FILE"
fi

echo ""
echo -e "${YELLOW}Notes:${NC}"
echo "  - SSH and direct connections to this server are NOT affected"
echo "  - All VPN client traffic (${VPN_SUBNET}) goes through Server B"
echo ""