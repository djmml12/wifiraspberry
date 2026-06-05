#!/usr/bin/env bash
set -euo pipefail

# ── colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

die()  { echo -e "${RED}Error: $*${RESET}" >&2; exit 1; }
ok()   { echo -e "${GREEN}✓ $*${RESET}"; }
info() { echo -e "${CYAN}▸ $*${RESET}"; }

[[ $EUID -eq 0 ]] && die "No ejecutes como root. Corre como tu usuario; el script usa sudo donde hace falta."

# ── usuario actual (para darle permisos de admin de impresoras) ───────────────
CUPS_USER="${SUDO_USER:-$USER}"

# ── instalar CUPS ─────────────────────────────────────────────────────────────
info "Actualizando índice de paquetes..."
sudo apt-get update -qq

info "Instalando CUPS y utilidades..."
sudo apt-get install -y cups cups-client cups-bsd avahi-daemon
ok "CUPS instalado"

# ── permisos: agregar usuario al grupo lpadmin ────────────────────────────────
info "Agregando '$CUPS_USER' al grupo lpadmin..."
sudo usermod -aG lpadmin "$CUPS_USER"
ok "Usuario '$CUPS_USER' puede administrar impresoras"

# ── habilitar administración remota ───────────────────────────────────────────
info "Habilitando acceso remoto a la interfaz web (puerto 631)..."

# cupsctl: escuchar en todas las interfaces y permitir admin remota
sudo cupsctl --remote-admin --remote-any --share-printers

# Asegurar que cupsd escuche en todas las IPs (no solo localhost)
CUPSD_CONF=/etc/cups/cupsd.conf
if grep -qE '^\s*Listen\s+localhost:631' "$CUPSD_CONF"; then
  sudo sed -i 's/^\(\s*\)Listen localhost:631/\1Port 631/' "$CUPSD_CONF"
fi
if ! grep -qE '^\s*(Port\s+631|Listen\s+\*:631|Listen\s+0\.0\.0\.0:631)' "$CUPSD_CONF"; then
  echo "Port 631" | sudo tee -a "$CUPSD_CONF" >/dev/null
fi

# Permitir acceso a la red local en los bloques <Location>
sudo python3 - "$CUPSD_CONF" <<'PYEOF'
import sys, re
path = sys.argv[1]
text = open(path).read()

# Dentro de cada <Location ...> ... </Location>, asegurar "Allow @LOCAL"
def patch(block):
    body = block.group(0)
    if 'Allow @LOCAL' in body or 'Allow all' in body:
        return body
    # insertar Allow @LOCAL después de la línea "Order ..." si existe,
    # o justo antes de </Location>
    if re.search(r'\n\s*Order\b', body):
        body = re.sub(r'(\n(\s*)Order[^\n]*)', r'\1\n\2Allow @LOCAL', body, count=1)
    else:
        body = re.sub(r'(\n\s*)(</Location>)', r'\1  Allow @LOCAL\1\2', body, count=1)
    return body

text = re.sub(r'<Location[^>]*>.*?</Location>', patch, text, flags=re.DOTALL)
open(path, 'w').write(text)
PYEOF

ok "Administración remota habilitada"

# ── reiniciar y habilitar el servicio ─────────────────────────────────────────
info "Habilitando CUPS al arranque y reiniciando el servicio..."
sudo systemctl enable cups
sudo systemctl restart cups
sleep 2

if systemctl is-active --quiet cups; then
  ok "Servicio CUPS activo"
else
  die "CUPS no arrancó. Revisa: sudo systemctl status cups"
fi

# ── firewall (si ufw está activo, abrir 631) ──────────────────────────────────
if command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
  info "Abriendo puerto 631 en ufw..."
  sudo ufw allow 631/tcp >/dev/null
  ok "Puerto 631 abierto en firewall"
fi

# ── mostrar datos de acceso ───────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
HN=$(hostname)

echo ""
echo -e "${BOLD}════════════════════════════════════════════════${RESET}"
ok "CUPS listo"
echo -e "${BOLD}════════════════════════════════════════════════${RESET}"
echo ""
echo -e "Administra las impresoras desde otra PC en la red local:"
echo ""
echo -e "  ${BOLD}${CYAN}http://${IP}:631${RESET}"
echo -e "  ${BOLD}${CYAN}http://${HN}.local:631${RESET}"
echo ""
echo -e "Para agregar una impresora:"
echo -e "  1. Abre la URL → ${BOLD}Administration → Add Printer${RESET}"
echo -e "  2. Usuario/contraseña = tu login de Linux (${BOLD}$CUPS_USER${RESET})"
echo -e "  3. Elige la impresora USB → en el driver selecciona ${BOLD}Raw${RESET}"
echo -e "     (Raw deja pasar los bytes ESC/POS sin reinterpretarlos)"
echo ""
echo -e "${YELLOW}Nota:${RESET} algunos navegadores piden aceptar el certificado"
echo -e "autofirmado de CUPS. Acéptalo para continuar."
echo ""
echo -e "Luego, en el POS configura la CUPS URL como:"
echo -e "  ${BOLD}http://${IP}:631/printers/NOMBRE_DE_LA_IMPRESORA${RESET}"
echo ""
