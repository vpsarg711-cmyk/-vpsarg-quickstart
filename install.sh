
#!/usr/bin/env bash
set -Eeuo pipefail

# VPS ARG QuickStart - instalador
RAW="https://raw.githubusercontent.com/vpsarg711-cmyk/-vpsarg-quickstart/main"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if [[ $EUID -ne 0 ]]; then
    echo "Ejecutá: sudo bash install.sh"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Falta curl. Instalalo primero."
    exit 1
fi

echo "Descargando el controlador VPS ARG QuickStart..."

curl -fsSL --retry 3 "$RAW/vpsarg-puertos.sh" -o "$TMP"

if ! bash -n "$TMP"; then
    echo "ERROR: el archivo descargado tiene errores de sintaxis."
    exit 1
fi

echo "Instalando el comando..."
bash "$TMP" instalar

echo "Instalación del comando finalizada."
echo "Comprobá los servicios con:"
echo "sudo vpsarg-puertos estado"
