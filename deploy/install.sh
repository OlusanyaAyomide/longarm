#!/usr/bin/env bash
# Installs Longarm's rendezvous server and relay on this machine, without Docker. Run as root from
# a checkout of the repository, after installing Node.js 24, coturn and Caddy (see README.md):
#
#   sudo LONGARM_DOMAIN=longarm.example.com PUBLIC_IP=203.0.113.7 PRIVATE_IP=10.0.0.5 deploy/install.sh
#
# PRIVATE_IP only when the cloud provider puts the machine behind NAT (Oracle Cloud does). Running
# it again updates the code and keeps the existing secret.
set -euo pipefail

: "${LONGARM_DOMAIN:?set LONGARM_DOMAIN}" "${PUBLIC_IP:?set PUBLIC_IP}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"

node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
[ "$node_major" -ge 24 ] || { echo "Node.js 24 or later is needed (found: $(node -v 2>/dev/null || echo none))" >&2; exit 1; }
command -v turnserver >/dev/null || { echo "coturn isn't installed: apt install coturn" >&2; exit 1; }
command -v caddy >/dev/null || { echo "Caddy isn't installed (see README.md)" >&2; exit 1; }

id longarm >/dev/null 2>&1 || useradd --system --home-dir /opt/longarm --shell /usr/sbin/nologin longarm

# The relay's secret is shared with the rendezvous server: made once, kept on updates.
mkdir -p /etc/longarm
if [ ! -f /etc/longarm/turn-secret ]; then
  (umask 077 && openssl rand -hex 32 > /etc/longarm/turn-secret)
fi
secret="$(cat /etc/longarm/turn-secret)"

echo "Installing the rendezvous server in /opt/longarm/server"
mkdir -p /opt/longarm/server
cp -r "$repo/server/src" "$repo/server/package.json" "$repo/server/package-lock.json" /opt/longarm/server/
(cd /opt/longarm/server && npm ci --omit=dev --silent)
cat > /etc/longarm/rendezvous.env <<ENV
HOST=127.0.0.1
PORT=8080
TRUST_PROXY=1
TURN_URLS=turn:${LONGARM_DOMAIN}:3478?transport=udp,turn:${LONGARM_DOMAIN}:3478?transport=tcp
TURN_SECRET=${secret}
ENV
chgrp longarm /etc/longarm/rendezvous.env
chmod 640 /etc/longarm/rendezvous.env
install -m 644 "$here/longarm-rendezvous.service" /etc/systemd/system/longarm-rendezvous.service

echo "Configuring the relay"
external="$PUBLIC_IP${PRIVATE_IP:+/$PRIVATE_IP}"
sed -e "s|LONGARM_DOMAIN|$LONGARM_DOMAIN|" -e "s|TURN_SECRET|$secret|" -e "s|EXTERNAL_IP|$external|" \
  "$here/turnserver.conf" > /etc/turnserver.conf
chgrp turnserver /etc/turnserver.conf 2>/dev/null || true
chmod 640 /etc/turnserver.conf
if [ -f /etc/default/coturn ]; then
  sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
fi

echo "Configuring HTTPS for $LONGARM_DOMAIN"
sed "s|LONGARM_DOMAIN|$LONGARM_DOMAIN|" "$here/Caddyfile" > /etc/caddy/Caddyfile

systemctl daemon-reload
systemctl enable --now longarm-rendezvous coturn caddy
systemctl restart longarm-rendezvous coturn caddy

echo "Done. Check: curl https://$LONGARM_DOMAIN/health"
echo "Point Longarm at wss://$LONGARM_DOMAIN/v1"
