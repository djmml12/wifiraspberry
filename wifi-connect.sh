#!/usr/bin/env bash
set -euo pipefail

# ── colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

die()  { echo -e "${RED}Error: $*${RESET}" >&2; exit 1; }
ok()   { echo -e "${GREEN}✓ $*${RESET}"; }
info() { echo -e "${CYAN}▸ $*${RESET}"; }

# ── detectar backend ─────────────────────────────────────────────────────────
if command -v nmcli &>/dev/null; then
  BACKEND=nmcli
elif command -v wpa_cli &>/dev/null; then
  BACKEND=wpa_cli
else
  die "No se encontró nmcli ni wpa_cli. Instala network-manager o wpasupplicant."
fi

info "Backend detectado: $BACKEND"

# ── detectar interfaz WiFi ───────────────────────────────────────────────────
if [[ $BACKEND == nmcli ]]; then
  IFACE=$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="wifi"{print $1; exit}')
else
  IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
fi

[[ -z "$IFACE" ]] && die "No se encontró interfaz WiFi."
info "Interfaz: $IFACE"

# ── escanear redes ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Escaneando redes WiFi...${RESET}"

if [[ $BACKEND == nmcli ]]; then
  # forzar re-scan y esperar 3s
  nmcli dev wifi rescan iface "$IFACE" 2>/dev/null || true
  sleep 3

  # leer SSIDs únicos (columna IN-USE, SSID, SIGNAL, SECURITY)
  mapfile -t NETWORKS < <(
    nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY dev wifi list iface "$IFACE" 2>/dev/null \
    | grep -v '^:$' \
    | awk -F: '!seen[$2]++ && $2!=""' \
    | sort -t: -k3 -rn
  )
else
  # wpa_cli scan
  wpa_cli -i "$IFACE" scan &>/dev/null || true
  sleep 3
  mapfile -t NETWORKS < <(
    wpa_cli -i "$IFACE" scan_results 2>/dev/null \
    | tail -n +2 \
    | awk 'NF>=5{$1=$2=$3=$4=""; gsub(/^ +/,""); print}' \
    | sort -u \
    | grep -v '^$'
  )
fi

[[ ${#NETWORKS[@]} -eq 0 ]] && die "No se encontraron redes. Verifica que el WiFi esté activo."

# ── mostrar menú ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Redes disponibles:${RESET}"
echo "────────────────────────────────────────"

if [[ $BACKEND == nmcli ]]; then
  for i in "${!NETWORKS[@]}"; do
    IFS=: read -r inuse ssid signal security <<< "${NETWORKS[$i]}"
    star=""
    [[ "$inuse" == "*" ]] && star="${GREEN}(conectada)${RESET} "
    printf "  ${BOLD}%2d)${RESET} %-30s %s${YELLOW}%s%%${RESET} %s\n" \
      "$((i+1))" "$ssid" "$star" "$signal" "$security"
  done
else
  for i in "${!NETWORKS[@]}"; do
    printf "  ${BOLD}%2d)${RESET} %s\n" "$((i+1))" "${NETWORKS[$i]}"
  done
fi

echo "────────────────────────────────────────"
echo ""

# ── selección ────────────────────────────────────────────────────────────────
while true; do
  read -rp "$(echo -e "${BOLD}Elige una red [1-${#NETWORKS[@]}]:${RESET} ")" CHOICE
  [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#NETWORKS[@]} )) && break
  echo -e "${RED}Opción inválida.${RESET}"
done

IDX=$((CHOICE-1))

if [[ $BACKEND == nmcli ]]; then
  IFS=: read -r _ SSID _ SECURITY <<< "${NETWORKS[$IDX]}"
else
  SSID="${NETWORKS[$IDX]}"
  SECURITY="WPA"
fi

echo ""
info "Red seleccionada: ${BOLD}$SSID${RESET}"

# ── pedir contraseña ─────────────────────────────────────────────────────────
PASSWORD=""
if [[ -z "$SECURITY" || "$SECURITY" == "--" ]]; then
  info "Red abierta, no se requiere contraseña."
else
  while true; do
    read -rsp "$(echo -e "${BOLD}Contraseña para '$SSID':${RESET} ")" PASSWORD
    echo ""
    [[ ${#PASSWORD} -ge 8 || ${#PASSWORD} -eq 0 ]] && break
    echo -e "${RED}La contraseña debe tener al menos 8 caracteres.${RESET}"
  done
fi

# ── conectar ─────────────────────────────────────────────────────────────────
echo ""
info "Conectando a ${BOLD}$SSID${RESET}..."

if [[ $BACKEND == nmcli ]]; then
  # Si ya existe un perfil guardado para este SSID, usarlo; si no, crear uno nuevo
  if nmcli connection show "$SSID" &>/dev/null; then
    if [[ -n "$PASSWORD" ]]; then
      nmcli connection modify "$SSID" wifi-sec.psk "$PASSWORD"
    fi
    nmcli connection up "$SSID" iface "$IFACE"
  else
    if [[ -n "$PASSWORD" ]]; then
      nmcli dev wifi connect "$SSID" password "$PASSWORD" iface "$IFACE"
    else
      nmcli dev wifi connect "$SSID" iface "$IFACE"
    fi
  fi

else
  # wpa_supplicant: agregar red a wpa_supplicant.conf
  CONF=/etc/wpa_supplicant/wpa_supplicant.conf

  # generar bloque de red
  if [[ -n "$PASSWORD" ]]; then
    NET_BLOCK=$(wpa_passphrase "$SSID" "$PASSWORD")
  else
    NET_BLOCK=$(printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n}' "$SSID")
  fi

  # eliminar entrada previa del mismo SSID si existe
  sudo python3 - "$SSID" "$CONF" <<'PYEOF'
import sys, re
ssid, path = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(
    r'\nnetwork=\{[^}]*ssid="' + re.escape(ssid) + r'"[^}]*\}',
    '', text, flags=re.DOTALL
)
open(path, 'w').write(text)
PYEOF

  echo "$NET_BLOCK" | sudo tee -a "$CONF" >/dev/null
  sudo wpa_cli -i "$IFACE" reconfigure &>/dev/null
  sleep 4
  sudo dhclient "$IFACE" &>/dev/null || true
fi

# ── verificar conexión ────────────────────────────────────────────────────────
echo ""
sleep 2
IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)

if [[ -n "$IP" ]]; then
  ok "Conectado a ${BOLD}$SSID${RESET}"
  ok "IP asignada: ${BOLD}$IP${RESET}"
  echo ""
  # ping rápido para confirmar salida
  if ping -c1 -W2 8.8.8.8 &>/dev/null; then
    ok "Internet disponible"
  else
    echo -e "${YELLOW}⚠ Sin acceso a internet (puede ser normal en red local cerrada)${RESET}"
  fi
else
  echo -e "${YELLOW}⚠ No se obtuvo IP todavía. Espera unos segundos y verifica con: ip addr show $IFACE${RESET}"
fi
