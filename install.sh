
#!/usr/bin/env bash
set -Eeuo pipefail

# VPS ARG QuickStart
# Instalador base para Ubuntu 22.04/24.04.
# No modifica SSH ni instala componentes de terceros
# cuya fuente todavía no haya sido configurada.

RAW="https://raw.githubusercontent.com/vpsarg711-cmyk/-vpsarg-quickstart/main"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if [[ ${EUID} -ne 0 ]]; then
    echo "Ejecutá como root: sudo bash install.sh"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "No se pudo identificar el sistema operativo."
    exit 1
fi

. /etc/os-release

if [[ "$ID" != "ubuntu" ]]; then
    echo "Este instalador está preparado para Ubuntu."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Falta curl. Instalalo antes de continuar."
    exit 1
fi

echo "======================================"
echo "       VPS ARG QuickStart"
echo "======================================"
echo "Sistema detectado: $PRETTY_NAME"
echo
echo "Este instalador instalará el controlador."
echo "Todavía no instalará PDirect-C ni BadVPN."
echo "No modificará SSH ni reiniciará servicios."
echo

echo "Descargando el controlador..."

curl -fsSL --retry 3 "$RAW/vpsarg-puertos.sh" -o "$TMP"

if ! bash -n "$TMP"; then
    echo "ERROR: el controlador descargado tiene errores de sintaxis."
    exit 1
fi

install -o root -g root -m 0755 "$TMP" /usr/local/sbin/vpsarg-puertos

echo
echo "Controlador instalado en:"
echo "/usr/local/sbin/vpsarg-puertos"
echo
echo "IMPORTANTE:"
echo "El controlador administra servicios existentes."
echo "Todavía falta automatizar la instalación de los programas"
echo "y la creación de sus unidades systemd."
echo
echo "VPS ARG QuickStart: instalación base finalizada."
