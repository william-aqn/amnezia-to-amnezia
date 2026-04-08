# Amnezia-to-Amnezia: AWG tunnel between servers

One-script setup: installs an AmneziaWG VPN server on Server A, builds a tunnel to Server B, and routes all VPN client traffic through Server B. SSH and direct access to Server A stay unaffected.

```
                         AmneziaWG tunnel
  Clients --> [ Server A (Amnezia VPN) ] ===========> [ Server B ] --> Internet
                  |                                        |
                  +-- SSH / direct access                  +-- NAT (masquerade)
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
- Set up a VPN server on Server A (generate keys, AWG obfuscation params, client config)
- Create a tunnel from Server A to Server B
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
| `--no-server` | | Skip VPN server setup (tunnel only) |
| `--help` | | Show help |

If `config-file` is omitted, you will be prompted to paste it.

## What the script does

1. Parses AmneziaWG config for tunnel to Server B (Jc, S1-S4, H1-H4, I1-I5)
2. Installs dependencies (Go >= 1.21, git, make, gcc)
3. Builds `amneziawg-go` and `amneziawg-tools` from source
4. Enables `net.ipv4.ip_forward`
5. **Sets up VPN server** on Server A:
   - Generates server/client key pairs and AWG obfuscation parameters
   - Creates server config with FORWARD rules
   - Generates a client config for the Amnezia app
6. **Sets up tunnel** from Server A to Server B:
   - Source-based routing: only VPN client traffic goes through the tunnel
   - Creates routing table `via_tunnel` (#200)
7. Creates systemd services and starts everything

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
  - Enter `n` to generate a new client (new keys, new IP, peer added to server automatically)
- **Tunnel config** is always regenerated from the provided config file

## Tunnel management

```bash
# Status of all interfaces
awg show

# Restart tunnel
sudo systemctl restart awg-quick@awg0

# Restart VPN server
sudo systemctl restart awg-quick@wg0

# Logs
journalctl -u awg-quick@awg0 -e    # tunnel
journalctl -u awg-quick@wg0 -e     # VPN server

# Verify (should show server B IP)
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

## Troubleshooting

**Tunnel does not come up / no handshake**
- Check endpoint reachability: `ping <server-B-ip>`
- Check port is open: `nc -zuv <ip> <port>`
- Check config: `cat /etc/amneziawg/awg0.conf`
- Check logs: `journalctl -u awg-quick@awg0 -e`

**Clients can't connect to Server A**
- Check VPN server is running: `awg show wg0`
- Check firewall allows the server port: `ss -ulnp | grep <port>`
- Verify client config matches server AWG parameters

**Client traffic does not go through the tunnel**
- Check routing: `ip rule show` and `ip route show table via_tunnel`
- Check NAT on server B
- Verify VPN subnet matches: `awg show wg0` should show client IPs in the expected range

**SSH drops after starting**
- Should not happen (source-based routing only affects VPN client traffic)
- Check that VPN subnet doesn't overlap with your SSH connection
- Check rules: `ip rule show`

**Build fails**
- Ensure git, make, gcc are installed: `apt install -y git make gcc`
- Check Go version: `go version` (need >= 1.21)
