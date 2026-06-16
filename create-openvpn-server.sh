#!/usr/bin/env bash
set -euo pipefail

BASE_SERVER="/etc/openvpn/server/server.conf"
HOST="$(hostname -s)"

[[ -f "$BASE_SERVER" ]] || { echo "ERROR: no $BASE_SERVER"; exit 1; }

if [[ "$#" -gt 0 ]]; then
  echo "Arguments are ignored. Please answer the prompts below."
  echo
fi

prompt_positive_number() {
  local prompt="$1"
  local value=""

  while true; do
    read -rp "$prompt" value

    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
      echo "$value"
      return
    fi

    echo "ERROR: enter a positive number" >&2
  done
}

get_default_port() {
  awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$BASE_SERVER"
}

prompt_port() {
  local default_port="$1"
  local value=""
  local prompt="OpenVPN port"

  if [[ -n "$default_port" ]]; then
    prompt="$prompt [$default_port]"
  fi

  prompt="$prompt: "

  while true; do
    read -rp "$prompt" value

    if [[ -z "$value" && -n "$default_port" ]]; then
      echo "$default_port"
      return
    fi

    if [[ "$value" =~ ^[1-9][0-9]*$ && "$value" -le 65535 ]]; then
      echo "$value"
      return
    fi

    echo "ERROR: enter a port from 1 to 65535" >&2
  done
}

choose_base_client() {
  local found=()
  local f=""
  local choice=""

  for f in \
    "/root/${HOST}-1.ovpn" \
    "/root/${HOST}_1.ovpn" \
    "/root/${HOST}.1.ovpn" \
    "/root/${HOST}1.ovpn" \
    "./${HOST}-1.ovpn" \
    "./${HOST}_1.ovpn" \
    "./${HOST}.1.ovpn" \
    "./${HOST}1.ovpn"
  do
    if [[ -f "$f" ]]; then
      echo "$f"
      return
    fi
  done

  while IFS= read -r f; do
    found+=("$f")
  done < <(find . /root -maxdepth 1 -type f -name '*.ovpn' 2>/dev/null | sort -u)

  if [[ "${#found[@]}" -eq 0 ]]; then
    echo "ERROR: base client config not found" >&2
    echo "Tried:" >&2
    echo "  /root/${HOST}-1.ovpn" >&2
    echo "  /root/${HOST}_1.ovpn" >&2
    echo "  /root/${HOST}.1.ovpn" >&2
    echo "  /root/${HOST}1.ovpn" >&2
    echo "  ./${HOST}-1.ovpn" >&2
    echo "  ./${HOST}_1.ovpn" >&2
    echo "  ./${HOST}.1.ovpn" >&2
    echo "  ./${HOST}1.ovpn" >&2
    exit 1
  fi

  echo "Available client configs:" >&2
  for i in "${!found[@]}"; do
    echo "$((i+1))) ${found[$i]}" >&2
  done

  while true; do
    printf "Choose base client config number: " >&2
    read -r choice

    if [[ "$choice" =~ ^[1-9][0-9]*$ && "$choice" -le "${#found[@]}" ]]; then
      echo "${found[$((choice-1))]}"
      return
    fi

    echo "ERROR: choose a number from 1 to ${#found[@]}" >&2
  done
}

INDEX="$(prompt_positive_number "Server index: ")"
DEFAULT_PORT="$(get_default_port)"
PORT="$(prompt_port "$DEFAULT_PORT")"
IP=""

SERVER_NAME="server${INDEX}"
NEW_SERVER="/etc/openvpn/server/${SERVER_NAME}.conf"

BASE_CLIENT="$(choose_base_client)"

NEW_CLIENT="/root/${HOST}-${INDEX}.ovpn"

VPN_OCTET=$((7 + INDEX))
VPN_NET="10.${VPN_OCTET}.0.0"
VPN_CIDR="10.${VPN_OCTET}.0.0/24"
VPN_MASK="255.255.255.0"
TABLE=$((100 + INDEX))

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

  while true; do
    read -rp "Choose IP number: " CHOICE

    if [[ "$CHOICE" =~ ^[1-9][0-9]*$ && "$CHOICE" -le "${#IPS[@]}" ]]; then
      IP="${IPS[$((CHOICE-1))]}"
      break
    fi

    echo "ERROR: choose a number from 1 to ${#IPS[@]}"
  done
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
