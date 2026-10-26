#!/usr/bin/env bash
# Installs Longarm's rendezvous server and relay on this machine, without Docker. Run as root from
# a copy of the repository, after installing Node.js 22.6 or later and coturn (see README.md):
#
#   sudo LONGARM_DOMAIN=longarm.example.com PUBLIC_IP=203.0.113.7 PRIVATE_IP=10.0.0.5 deploy/install.sh
#
# PRIVATE_IP only when the cloud provider puts the machine behind NAT (Oracle Cloud does).
# HTTPS goes through nginx with certbot if nginx is already running here, otherwise Caddy; set
# PROXY=nginx, caddy or none to choose. NODE is the node binary, if sudo can't find it. Running it
# again updates the code and keeps the existing secret.
set -euo pipefail

: "${LONGARM_DOMAIN:?set LONGARM_DOMAIN}" "${PUBLIC_IP:?set PUBLIC_IP}"
PORT="${PORT:-47910}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
fail() { echo "$*" >&2; exit 1; }

node="${NODE:-$(command -v node || true)}"
[ -x "$node" ] || fail "Node.js isn't on root's PATH: pass NODE=\$(command -v node)"
"$node" -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 6) ? 0 : 1)' \
  || fail "Node.js 22.6 or later is needed (found $("$node" -v))"
npm="$(dirname "$node")/npm"
command -v turnserver >/dev/null || fail "coturn isn't installed (apt install coturn, or dnf install coturn from EPEL)"

proxy="${PROXY:-}"
if [ -z "$proxy" ]; then
  if systemctl is-active --quiet nginx; then proxy=nginx; else proxy=caddy; fi
fi
case "$proxy" in
  nginx) command -v certbot >/dev/null || fail "certbot isn't installed (it gets the TLS certificate for nginx)" ;;
  caddy) command -v caddy >/dev/null || fail "Caddy isn't installed (see README.md), or set PROXY=nginx" ;;
  none) ;;
  *) fail "PROXY must be nginx, caddy or none" ;;
esac

id longarm >/dev/null 2>&1 || useradd --system --home-dir /opt/longarm --shell /usr/sbin/nologin longarm

# The relay's secret is shared with the rendezvous server: made once, kept on updates.
mkdir -p /etc/longarm
if [ ! -f /etc/longarm/turn-secret ]; then
  (umask 077 && openssl rand -hex 32 > /etc/longarm/turn-secret)
fi
secret="$(cat /etc/longarm/turn-secret)"

echo "Installing the rendezvous server in /opt/longarm/server (port $PORT, local only)"
mkdir -p /opt/longarm/server
cp -r "$repo/server/src" "$repo/server/package.json" "$repo/server/package-lock.json" /opt/longarm/server/
(cd /opt/longarm/server && PATH="$(dirname "$node"):$PATH" "$npm" ci --omit=dev --silent)
cat > /etc/longarm/rendezvous.env <<ENV
HOST=127.0.0.1
PORT=${PORT}
TRUST_PROXY=1
TURN_URLS=turn:${LONGARM_DOMAIN}:3478?transport=udp,turn:${LONGARM_DOMAIN}:3478?transport=tcp
TURN_SECRET=${secret}
ENV
chgrp longarm /etc/longarm/rendezvous.env
chmod 640 /etc/longarm/rendezvous.env
sed "s|/usr/bin/env node|$node|" "$here/longarm-rendezvous.service" > /etc/systemd/system/longarm-rendezvous.service
command -v restorecon >/dev/null && restorecon -R /opt/longarm /etc/systemd/system/longarm-rendezvous.service

echo "Configuring the relay"
if [ -d /etc/coturn ]; then turn_conf=/etc/coturn/turnserver.conf; else turn_conf=/etc/turnserver.conf; fi
external="$PUBLIC_IP${PRIVATE_IP:+/$PRIVATE_IP}"
[ -f "$turn_conf" ] && [ ! -f "$turn_conf.before-longarm" ] && cp "$turn_conf" "$turn_conf.before-longarm"
sed -e "s|LONGARM_DOMAIN|$LONGARM_DOMAIN|" -e "s|TURN_SECRET|$secret|" -e "s|EXTERNAL_IP|$external|" \
  "$here/turnserver.conf" > "$turn_conf"
turn_group="$(stat -c %G "$(dirname "$turn_conf")" 2>/dev/null || echo root)"
for group in coturn turnserver; do getent group "$group" >/dev/null && turn_group="$group"; done
chgrp "$turn_group" "$turn_conf"
chmod 640 "$turn_conf"
if [ -f /etc/default/coturn ]; then
  sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
fi

if systemctl is-active --quiet firewalld; then
  echo "Opening the relay's ports in firewalld"
  firewall-cmd --quiet --permanent --add-port=3478/udp --add-port=3478/tcp --add-port=49160-49200/udp
  firewall-cmd --quiet --reload
fi

systemctl daemon-reload
systemctl enable --now longarm-rendezvous coturn
systemctl restart longarm-rendezvous coturn

case "$proxy" in
  nginx)
    echo "Adding $LONGARM_DOMAIN to nginx, with a certificate from certbot"
    site=/etc/nginx/conf.d/longarm.conf
    if [ ! -f "$site" ]; then
      sed -e "s|LONGARM_DOMAIN|$LONGARM_DOMAIN|" -e "s|LONGARM_PORT|$PORT|" "$here/nginx.conf" > "$site"
      nginx -t || { rm -f "$site"; fail "nginx didn't accept the new site; nothing changed"; }
      systemctl reload nginx
      certbot --nginx --non-interactive --redirect -d "$LONGARM_DOMAIN"
    else
      echo "  $site exists already: left as it is"
    fi
    ;;
  caddy)
    echo "Configuring HTTPS for $LONGARM_DOMAIN with Caddy"
    sed -e "s|LONGARM_DOMAIN|$LONGARM_DOMAIN|" -e "s|LONGARM_PORT|$PORT|" "$here/Caddyfile" > /etc/caddy/Caddyfile
    systemctl enable --now caddy
    systemctl restart caddy
    ;;
esac

echo "Done. Check: curl https://$LONGARM_DOMAIN/health"
echo "Point Longarm at wss://$LONGARM_DOMAIN/v1 (Mac menu → Internet Server…)"
