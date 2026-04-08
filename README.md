# Amnezia-to-Amnezia: AWG tunnel between servers

One-script setup: installs an AmneziaWG VPN server on Server A, builds a tunnel to Server B, and routes all VPN client traffic through Server B. SSH and direct access to Server A stay unaffected.

```
                         AmneziaWG tunnel
  Clients --> [ Server A (Amnezia VPN) ] ===========> [ Server B ] --> Internet
                  |           |                            |
                  |           +-- MASQUERADE on awg0       +-- NAT (masquerade)
                  |           +-- source-based routing
                  |
                  +-- SSH / direct access
                      via default gateway
```

## Quick start

1. On Server B: set up an AmneziaWG server (via the Amnezia app) and export a client config
2. Copy the client config to Server A
3. Run:

```bash
curl -sLo awg-install.sh https://raw.githubusercontent.com/william-aqn/amnezia-to-amnezia/main/install.sh && sudo bash awg-install.sh client.conf
```

Or without a file (paste config interactively):

```bash
curl -sLo awg-install.sh https://raw.githubusercontent.com/william-aqn/amnezia-to-amnezia/main/install.sh && sudo bash awg-install.sh
```

<details>
<summary>wget alternative</summary>

```bash
wget -qO awg-install.sh https://raw.githubusercontent.com/william-aqn/amnezia-to-amnezia/main/install.sh && sudo bash awg-install.sh client.conf
```
</details>

The script will:
- Build AmneziaWG from source
- Set up a VPN server on Server A (generate keys, AWG obfuscation params, open firewall port)
- Create a tunnel from Server A to Server B with NAT
- Configure source-based routing (only VPN client traffic goes through the tunnel)
- Start both services and enable them on boot
- Print a ready-to-use client config for the Amnezia app

## Requirements

**Server A** (where the script runs):
- Debian / Ubuntu (or other apt-based distro)
- Root access

**Server B** (exit node):
- AmneziaWG server (configured via the Amnezia app)
- ip_forward and NAT enabled (see [Server B setup](#server-b-setup))

## Usage

```
sudo ./install.sh [config-file] [options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--vpn-subnet CIDR` | `10.8.1.0/24` | VPN client subnet |
| `--server-port PORT` | random | VPN server listen port |
| `--interface NAME` | `awg0` | Tunnel interface name |
| `--verbose` | | Enable runtime logging to /var/log/amneziawg/ |
| `--no-server` | | Skip VPN server setup (tunnel only) |
| `--force` | | Force rebuild of amneziawg binaries |
| `--status` | | Show diagnostic info and exit |
| `--uninstall` | | Remove everything and exit |

If `config-file` is omitted, you will be prompted to paste it.

## What the script does

1. Parses AmneziaWG config for tunnel to Server B (Jc, S1-S4, H1-H4, I1-I5)
2. Installs dependencies (Go >= 1.21, git, make, gcc)
3. Builds `amneziawg-go` and `amneziawg-tools` from source
4. Enables `net.ipv4.ip_forward`
5. **Sets up VPN server** on Server A:
   - Generates server/client key pairs and AWG obfuscation parameters
   - Creates server config with FORWARD rules (`iptables -I`)
   - Opens firewall port (UFW auto-detected)
   - Generates a client config for the Amnezia app
6. **Sets up tunnel** from Server A to Server B:
   - `Table = off` -- prevents awg-quick from overriding system routing
   - Source-based routing: only VPN client traffic goes through the tunnel
   - `MASQUERADE` on awg0 -- rewrites client src IP to tunnel IP for Server B
   - FORWARD rules inserted before UFW (`iptables -I FORWARD 1`)
   - Creates routing table `via_tunnel` (#200)
7. Creates systemd services and starts everything

## How traffic flows

```
1. Client (10.8.1.2) connects to Server A wg0
2. ip rule: from 10.8.1.0/24 -> table via_tunnel
3. table via_tunnel: default dev awg0
4. MASQUERADE on awg0: src 10.8.1.2 -> tunnel IP (e.g. 10.8.1.5)
5. Packet goes through AWG tunnel to Server B
6. Server B does NAT and forwards to internet
7. Reply comes back the same path
```

SSH and direct connections use the main routing table -- unaffected.

## Re-running the script / adding clients

The script is safe to re-run. On repeat runs it detects the existing setup:

- **Existing server found** (our config, Amnezia Docker, running wg/awg interfaces) -- skips server creation, reads subnet from existing config
- **Client management** -- if the server was created by this script, you get an interactive menu:

```
[i] Client configs found:
    1) client1.conf
    2) client2.conf
    n) Create new client

Show existing or create new? [1]:
```

  - Pick a number to display that client's config (for import into the Amnezia app)
  - Enter `n` to generate a new client (new keys, new IP, peer added to server, service restarted)
- **Tunnel config** is always regenerated from the provided config file
- Use `--force` to rebuild amneziawg binaries from latest source

## Tunnel management

```bash
# Status of all interfaces
awg show

# Restart tunnel / server
sudo systemctl restart awg-quick@awg0
sudo systemctl restart awg-quick@wg0

# Verify exit IP (should show server B IP)
curl --interface <tunnel-ip> -4 ifconfig.me
```

## Server B setup

Server B must forward traffic from the AWG tunnel to the internet. If server B is configured via the Amnezia app, NAT is usually already enabled. If not, run on server B:

```bash
# Enable forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

# NAT for tunnel traffic (replace eth0 with your external interface)
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i awg0 -j ACCEPT
iptables -A FORWARD -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

To persist rules across reboots:

```bash
apt install -y iptables-persistent
netfilter-persistent save
```

## Logs & diagnostics

Run the built-in diagnostic:

```bash
sudo ./install.sh --status
```

Shows interfaces, services, routing rules, recent logs, and tests tunnel connectivity.

```bash
# Enable verbose runtime logging
sudo ./install.sh client.conf --verbose

# View runtime logs (only with --verbose)
tail -f /var/log/amneziawg/awg0.log     # tunnel live
tail -f /var/log/amneziawg/wg0.log      # VPN server live

# Install log (always saved next to the script)
cat awg-install.log

# Disable verbose logging (re-run without --verbose)
sudo ./install.sh client.conf
```

## Troubleshooting

**Tunnel does not come up / no handshake**
- `sudo ./install.sh --status` -- check services and handshake
- Check endpoint: `ping <server-B-ip>`
- Check port: `nc -zuv <ip> <port>`
- Check config: `cat /etc/amnezia/amneziawg/awg0.conf`

**Clients can't connect to Server A**
- Check server: `awg show wg0`
- Check firewall: `ss -ulnp | grep <port>` and `ufw status`
- If UFW is active, ensure the port is open: `ufw allow <port>/udp`

**Client connected but no traffic**
- Check tunnel handshake: `awg show awg0` (latest handshake should be recent)
- Check routing: `ip rule show` and `ip route show table via_tunnel`
- Check FORWARD rules: `iptables -L FORWARD -n -v | head -10` (wg0/awg0 ACCEPT should be at the top, before UFW)
- Check NAT: `iptables -t nat -L POSTROUTING -n` (should have MASQUERADE on awg0)
- Check NAT on Server B

**SSH drops after starting tunnel**
- Ensure tunnel config has `Table = off`
- Check: `grep Table /etc/amnezia/amneziawg/awg0.conf`

**Reinstall / update**
- Re-run the script -- it's safe, server config is preserved
- `--force` to rebuild binaries from latest source
- `--uninstall` to remove everything

**Build fails**
- Ensure git, make, gcc: `apt install -y git make gcc`
- Check Go: `go version` (need >= 1.21)
