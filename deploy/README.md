# Deploying Longarm's internet services

Connecting at home needs nothing here. Over the internet, the phone and Mac need two small
services, both installed by `install.sh` here, without Docker (about 100 MB of memory in all):

- **Rendezvous** (`../server`, Node.js under systemd): the phone and Mac each keep a WebSocket to
  it and exchange their connection setup through it, signed end to end so it can't tamper with
  them. Then they connect directly. It never sees the screen, input or audio.
- **Relay** ([coturn](https://github.com/coturn/coturn)): for the networks where a direct
  connection is impossible (some mobile carriers, strict NATs). It carries the connection still
  end-to-end encrypted, and refuses to relay into private networks.
- **HTTPS** in front of the rendezvous: the machine's nginx with a certbot certificate if it
  already runs one, otherwise [Caddy](https://caddyserver.com), which gets and renews its own.

Any Linux machine with a public address will do; a small cloud VM is plenty. It works on
Debian/Ubuntu and on Oracle Linux / RHEL, and next to whatever else the machine already serves.

## 1. Open the ports

| Port | Protocol | For |
|---|---|---|
| 80, 443 | TCP | Rendezvous over HTTPS (80 only for the certificate) |
| 3478 | UDP and TCP | Relay |
| 49160–49200 | UDP | Relay traffic |

Open them in the cloud provider's firewall (on Oracle Cloud: the subnet's security list, as
ingress rules from 0.0.0.0/0). On the machine itself, `install.sh` opens them in firewalld if
that's running; with plain iptables (Oracle's Ubuntu images) add them yourself:

```bash
sudo iptables -I INPUT -p tcp -m multiport --dports 80,443,3478 -j ACCEPT
sudo iptables -I INPUT -p udp -m multiport --dports 3478,49160:49200 -j ACCEPT
sudo netfilter-persistent save
```

## 2. Install what it runs on

- **Node.js 22.6 or later** ([nodejs.org](https://nodejs.org/en/download); distributions often ship older).
- **coturn**: `sudo apt install coturn`, or `sudo dnf install coturn` with EPEL enabled.
- **HTTPS**: if the machine already runs nginx, `install.sh` adds the server as one more site and
  gets its certificate with certbot. Otherwise install [Caddy](https://caddyserver.com/docs/install),
  which does that by itself.

## 3. Install Longarm's services

You need a name pointing at the machine: an A record for a subdomain of yours (DNS only, not
proxied), or without a domain `<ip-with-dashes>.sslip.io`, e.g. `203-0-113-7.sslip.io`.
`PRIVATE_IP` is only for providers that put the machine behind NAT (`ip -4 addr` shows it;
Oracle Cloud does).

```bash
sudo NODE=$(command -v node) LONGARM_DOMAIN=longarm.example.com PUBLIC_IP=203.0.113.7 PRIVATE_IP=10.0.0.5 deploy/install.sh
curl https://longarm.example.com/health   # ok
```

It creates a `longarm` system user, puts the server in `/opt/longarm/server` (listening on
127.0.0.1:47910 only), makes the relay's secret once (`/etc/longarm/turn-secret`), writes the
coturn config (keeping any old one as `.before-longarm`) and the nginx site or Caddy config. Then
point Longarm at `wss://<your name>/v1` on the Mac.

## Updating

```bash
sudo NODE=$(command -v node) LONGARM_DOMAIN=… PUBLIC_IP=… PRIVATE_IP=… deploy/install.sh
```

Logs: `journalctl -u longarm-rendezvous -u coturn -f`.
