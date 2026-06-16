#!/usr/bin/env bash
set -euo pipefail

INDEX="${1:-}"
PORT="${2:-}"
IP="${3:-}"

BASE_SERVER="/etc/openvpn/server/server.conf"
HOST="$(hostname -s)"

if [[ -z "$INDEX" || -z "$PORT" ]]; then
  echo "Usage: $0 <index> <port> [public_ip]"
  echo "Example: $0 2 1195"
  exit 1
fi

SERVER_NAME="server${INDEX}"
NEW_SERVER="/etc/openvpn/server/${SERVER_NAME}.conf"

BASE_CLIENT=""
for f in \
  "/root/${HOST}-1.ovpn" \
  "/root/${HOST}.1.ovpn" \
  "/root/${HOST}1.ovpn"
do
  if [[ -f "$f" ]]; then
    BASE_CLIENT="$f"
    break
  fi
done

if [[ -z "$BASE_CLIENT" ]]; then
  echo "ERROR: base client config not found"
  echo "Tried:"
  echo "  /root/${HOST}-1.ovpn"
  echo "  /root/${HOST}.1.ovpn"
  echo "  /root/${HOST}1.ovpn"
  exit 1
fi

NEW_CLIENT="/root/${HOST}-${INDEX}.ovpn"

VPN_OCTET=$((7 + INDEX))
VPN_NET="10.${VPN_OCTET}.0.0"
VPN_CIDR="10.${VPN_OCTET}.0.0/24"
VPN_MASK="255.255.255.0"
TABLE=$((100 + INDEX))

[[ -f "$BASE_SERVER" ]] || { echo "ERROR: no $BASE_SERVER"; exit 1; }
[[ ! -f "$NEW_SERVER" ]] || { echo "ERROR: exists: $NEW_SERVER"; exit 1; }
[[ ! -f "$NEW_CLIENT" ]] || { echo "ERROR: exists: $NEW_CLIENT"; exit 1; }

if [[ -z "$IP" ]]; then
  echo "Available public IPv4 addresses:"
  mapfile -t IPS < <(
    ip -4 -o addr show scope global \
      | awk '{print $4}' \
      | cut -d/ -f1 \
      | grep -Ev '^(10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)'
  )

  [[ "${#IPS[@]}" -gt 0 ]] || { echo "ERROR: no public IPv4 found"; exit 1; }

  for i in "${!IPS[@]}"; do
    echo "$((i+1))) ${IPS[$i]}"
  done

  read -rp "Choose IP number: " CHOICE
  IP="${IPS[$((CHOICE-1))]}"
fi

DEV="$(
  ip -4 -o addr show scope global \
    | awk -v ip="$IP" '$4 ~ "^"ip"/" {print $2; exit}'
)"

[[ -n "$DEV" ]] || { echo "ERROR: IP $IP not found on this server"; exit 1; }

GATEWAY="$(
  ip route show default dev "$DEV" \
    | awk '/default/ {print $3; exit}'
)"

if [[ -z "$GATEWAY" ]]; then
  GATEWAY="$(
    ip route show default \
      | awk '/default/ {print $3; exit}'
  )"
fi

[[ -n "$GATEWAY" ]] || { echo "ERROR: cannot detect gateway"; exit 1; }

echo "Creating:"
echo "  server:     $NEW_SERVER"
echo "  client:     $NEW_CLIENT"
echo "  base client:$BASE_CLIENT"
echo "  IP:         $IP"
echo "  dev:        $DEV"
echo "  gateway:    $GATEWAY"
echo "  port:       $PORT"
echo "  subnet:     $VPN_CIDR"
echo "  table:      $TABLE"
echo

cp "$BASE_SERVER" "$NEW_SERVER"

if grep -qE '^[[:space:]]*local[[:space:]]+' "$NEW_SERVER"; then
  sed -i -E "s|^[[:space:]]*local[[:space:]]+.*|local $IP|" "$NEW_SERVER"
else
  sed -i "1ilocal $IP" "$NEW_SERVER"
fi

if grep -qE '^[[:space:]]*port[[:space:]]+' "$NEW_SERVER"; then
  sed -i -E "s|^[[:space:]]*port[[:space:]]+.*|port $PORT|" "$NEW_SERVER"
else
  echo "port $PORT" >> "$NEW_SERVER"
fi

sed -i -E "s|^[[:space:]]*server[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+|server $VPN_NET $VPN_MASK|" "$NEW_SERVER"

if grep -qE '^[[:space:]]*ifconfig-pool-persist[[:space:]]+' "$NEW_SERVER"; then
  sed -i -E "s|^[[:space:]]*ifconfig-pool-persist[[:space:]]+.*|ifconfig-pool-persist ipp${INDEX}.txt|" "$NEW_SERVER"
fi

if grep -qE '^[[:space:]]*status[[:space:]]+' "$NEW_SERVER"; then
  sed -i -E "s|^[[:space:]]*status[[:space:]]+.*|status /var/log/openvpn/status${INDEX}.log|" "$NEW_SERVER"
fi

cp "$BASE_CLIENT" "$NEW_CLIENT"

sed -i -E "s|^[[:space:]]*remote[[:space:]]+[^[:space:]]+[[:space:]]+[0-9]+|remote $IP $PORT|" "$NEW_CLIENT"

ip route replace default via "$GATEWAY" dev "$DEV" table "$TABLE"

ip rule show | grep -q "from $IP lookup $TABLE" || \
  ip rule add from "$IP" table "$TABLE"

ip rule show | grep -q "from $VPN_CIDR lookup $TABLE" || \
  ip rule add from "$VPN_CIDR" table "$TABLE"

iptables -t nat -C POSTROUTING -s "$VPN_CIDR" -o "$DEV" -j SNAT --to-source "$IP" 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "$VPN_CIDR" -o "$DEV" -j SNAT --to-source "$IP"

systemctl daemon-reload

echo
echo "Done."
echo
echo "Start:"
echo "  systemctl start openvpn-server@${SERVER_NAME}"
echo
echo "Enable autostart:"
echo "  systemctl enable openvpn-server@${SERVER_NAME}"
echo
echo "Client:"
echo "  $NEW_CLIENT"
