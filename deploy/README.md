# Deploying Longarm's internet services

Connecting at home needs nothing here. Over the internet, the phone and Mac need two small
services, both installed by `install.sh` here, without Docker (about 100 MB of memory in all):

- **Rendezvous** (`../server`, Node.js under systemd): the phone and Mac each keep a WebSocket to
  it and exchange their connection setup through it, signed end to end so it can't tamper with
  them. Then they connect directly. It never sees the screen, input or audio.
- **Relay** ([coturn](https://github.com/coturn/coturn)): for the networks where a direct
  connection is impossible (some mobile carriers, strict NATs). It carries the connection still
  end-to-end encrypted, and refuses to relay into private networks.
- **[Caddy](https://caddyserver.com)** in front of the rendezvous, for HTTPS with a certificate
  it gets and renews by itself.

Any Linux machine with a public address will do; a small cloud VM is plenty. These steps are for
Ubuntu or Debian.

## 1. Open the ports

| Port | Protocol | For |
|---|---|---|
| 80, 443 | TCP | Rendezvous over HTTPS (80 only for the certificate) |
| 3478 | UDP and TCP | Relay |
| 49160–49200 | UDP | Relay traffic |

Open them in the cloud provider's firewall (on Oracle Cloud: the subnet's security list) and on
the machine itself. Oracle's Ubuntu images also block them in iptables:

```bash
sudo iptables -I INPUT -p tcp -m multiport --dports 80,443,3478 -j ACCEPT
sudo iptables -I INPUT -p udp -m multiport --dports 3478,49160:49200 -j ACCEPT
sudo netfilter-persistent save
```

## 2. Install Node.js 24, coturn and Caddy

Node.js 24 from [nodejs.org](https://nodejs.org/en/download) (Ubuntu's own package is older),
coturn from the distribution, and Caddy from [its apt repository](https://caddyserver.com/docs/install#debian-ubuntu-raspbian):

```bash
sudo apt install coturn
```

## 3. Install Longarm's services

You need a name pointing at the machine. Without a domain of your own,
`<ip-with-dashes>.sslip.io` works, e.g. `203-0-113-7.sslip.io` for 203.0.113.7. `PRIVATE_IP` is
only for providers that put the machine behind NAT (`ip -4 addr` shows it; Oracle Cloud does).

```bash
sudo LONGARM_DOMAIN=longarm.example.com PUBLIC_IP=203.0.113.7 PRIVATE_IP=10.0.0.5 deploy/install.sh
curl https://longarm.example.com/health   # ok
```

It creates a `longarm` system user, puts the server in `/opt/longarm/server`, makes the relay's
secret once (`/etc/longarm/turn-secret`), and writes the coturn and Caddy configs. Then point
Longarm at `wss://<your name>/v1` on the Mac.

If the machine already runs a web server, skip Caddy: proxy `/v1` (with WebSocket upgrades) and
`/health` to `127.0.0.1:8080` from it instead.

## Updating

```bash
git pull && sudo LONGARM_DOMAIN=… PUBLIC_IP=… deploy/install.sh
```

Logs: `journalctl -u longarm-rendezvous -u coturn -f`.
