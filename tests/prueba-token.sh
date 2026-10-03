#!/usr/bin/env bash
# Pruebas del token de instalación (install.sh y vpsarg-hcr instalar).
# SOLO para un contenedor de laboratorio con QuickStart ya instalado y el binario HCR
# en /opt/hcr/hcr-server: genera una clave de prueba, la pone en una COPIA del
# verificador, oculta openssl un momento, instala y desinstala HCR y reinstala
# QuickStart (reinicia PDirect-C y UDPGW). NUNCA en una VPS real.
# Uso: sudo bash tests/prueba-token.sh /ruta/al/repo
# shellcheck disable=SC2016
set -uo pipefail

REPO="${1:?Uso: sudo bash tests/prueba-token.sh /ruta/al/repo}"
[[ "$(systemd-detect-virt 2>/dev/null)" == docker ]] || { echo "Solo en el contenedor de laboratorio." >&2; exit 1; }
W=/tmp/prueba-token
rm -rf "$W"; mkdir -p "$W/src"
cp "$REPO"/{install.sh,pdirect.c,vpsarg-puertos.sh,vpsarg-hcr.sh,vpsarg-panel.sh,vpsarg-usuarios.sh,vpsarg-token.sh} "$W/src/"
EMIT="$REPO/herramientas/emitir-token.sh"
USED=/etc/vpsarg/tokens-usados
PASS=0
FAILS=0
ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
pid_of() { systemctl show -p MainPID --value "$1"; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
hcr_absent() { ! systemctl cat hcr-8880 >/dev/null 2>&1 && ! test -e /etc/vpsarg-hcr.conf && ! test -e /usr/local/lib/vpsarg/hcr-server; }
tok() { bash "$EMIT" emitir "$KEY" "$1" "${3:-$TODAY}" "$2"; }   # tok ID ALCANCE [VENCE]

# Todo lo que una corrida rechazada no debe cambiar.
state() {
  sha256sum /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service \
    /usr/local/bin/pdirect-c /opt/badvpn/badvpn-udpgw /etc/vpsarg-pdirect.conf /etc/vpsarg-servicios.conf \
    /usr/local/sbin/vpsarg-puertos /usr/local/lib/vpsarg/token.sh 2>&1
  echo "pdirect PID=$(pid_of pdirect-80) udpgw PID=$(pid_of udpgw-7300)"
  echo "hcr: unidad=$(systemctl cat hcr-8880 >/dev/null 2>&1 && echo sí || echo no) conf=$(sha256sum /etc/vpsarg-hcr.conf 2>/dev/null | cut -c1-16) bin=$(test -e /usr/local/lib/vpsarg/hcr-server && echo sí || echo no) activo=$(systemctl is-active hcr-8880)"
  echo "tokens usados: $(sha256sum "$USED" 2>/dev/null | cut -c1-16)"
  echo "paquetes: $(dpkg-query -W -f '${Package} ${Version}\n' | sha256sum | cut -c1-16)"
  echo "apt listas: $(find /var/lib/apt/lists -maxdepth 1 -type f -newer "$W/marca" | wc -l)"
  echo "temporales: $(find /tmp -maxdepth 1 -name 'tmp.*' -newer "$W/marca" | wc -l)"
  echo "copias: $(find /var/backups/vpsarg -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
}

# Firma un contenido arbitrario con la clave KEY (para armar tokens a medida).
sign_raw() {
  local payload
  payload="$(printf '%s' "$1" | b64url)"
  echo "vpsarg1.$payload.$(printf 'vpsarg1.%s' "$payload" | openssl dgst -sha256 -sign "$KEY" | b64url)"
}

# assert_rejected NOMBRE MENSAJE: la última corrida se detuvo sin cambios.
assert_rejected() {
  local name="$1" msg="$2"
  check "$name: se detiene (rc=$RC)" test "$RC" -ne 0
  check "$name: dice \"$msg\"" grep -qF -- "$msg" "$W/$name.log"
  check "$name: dice que no se realizaron cambios" grep -q "No se realizaron cambios" "$W/$name.log"
  check "$name: sin cambios (archivos, servicios, HCR, apt, tokens usados)" diff <(echo "$BEFORE") <(state)
}
# install.sh sin terminal (con VPSARG_TOKEN).
rejected() {
  local name="$1" msg="$2" token="$3" script="${4:-$W/src/install.sh}"
  BEFORE="$(state)"
  VPSARG_TOKEN="$token" VPSARG_SRC_DIR="${script%/*}" setsid -w bash "$script" </dev/null > "$W/$name.log" 2>&1
  RC=$?
  assert_rejected "$name" "$msg"
}
# install.sh con terminal (responde SI a sobrescribir y Enter al puerto): para rechazos posteriores a esas preguntas.
rejected_tty() {
  local name="$1" msg="$2" token="$3"
  BEFORE="$(state)"
  install_tty "$name" "$token"
  assert_rejected "$name" "$msg"
}
# vpsarg-hcr instalar sin terminal (con VPSARG_TOKEN).
hcr_rejected() {
  local name="$1" msg="$2" token="$3"
  BEFORE="$(state)"
  VPSARG_TOKEN="$token" setsid -w vpsarg-hcr instalar </dev/null > "$W/$name.log" 2>&1
  RC=$?
  assert_rejected "$name" "$msg"
}
# install.sh con terminal: responde SI a sobrescribir y Enter al puerto SSH.
install_tty() {
  local name="$1" token="$2"
  # script no siempre devuelve el código del hijo cuando la entrada termina antes: se toma del log.
  VPSARG_TOKEN="$token" VPSARG_SRC_DIR="$W/src" script -qec "bash $W/src/install.sh; echo \"__rc=\$?\"" /dev/null \
    < <(printf 'SI\n\n') > "$W/$name.log" 2>&1
  RC="$(sed -n 's/^__rc=\([0-9]*\).*/\1/p' "$W/$name.log" | tail -n 1)"
  RC="${RC:-99}"
}

echo "### Preparación (contenedor)"
touch "$W/marca"; sleep 1
check "bash -n install.sh, vpsarg-token.sh, vpsarg-hcr.sh, emitir-token.sh" \
  bash -c 'for f; do bash -n "$f" || exit 1; done' _ "$W/src/install.sh" "$W/src/vpsarg-token.sh" "$W/src/vpsarg-hcr.sh" "$EMIT"
bash "$EMIT" clave "$W/clave" > "$W/clave.out" 2>&1
check "clave privada 0600" test "$(stat -c %a "$W/clave/vpsarg-token-privada.pem")" = 600
check "emitir-token no sobrescribe una clave existente" bash -c '! bash "$1" clave "$2" >/dev/null 2>&1' _ "$EMIT" "$W/clave"
bash "$EMIT" clave "$W/otra" >/dev/null 2>&1
KEY="$W/clave/vpsarg-token-privada.pem"
PUB="$(sed -n '/BEGIN PUBLIC KEY/,/END PUBLIC KEY/p' "$W/clave.out")"
python3 - "$W/src/vpsarg-token.sh" "$PUB" <<'PY'
import sys
p, pub = sys.argv[1], sys.argv[2]
s = open(p).read()
assert s.count('VPSARG_TOKEN_PUBKEY=""\n') == 1
open(p, 'w').write(s.replace('VPSARG_TOKEN_PUBKEY=""\n', 'VPSARG_TOKEN_PUBKEY="' + pub + '"\n'))
PY
mkdir -p "$W/sin-clave"; cp "$W/src/"* "$W/sin-clave/"; cp "$REPO/vpsarg-token.sh" "$W/sin-clave/"
TODAY="$(date -u +%F)"
YESTERDAY="$(date -u -d yesterday +%F)"
check "emitir: token con formato vpsarg1.datos.firma" bash -c '[[ "$1" =~ ^vpsarg1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]' _ "$(tok emitido base)"
check "emitir: rechaza fecha inválida" bash -c '! bash "$1" emitir "$2" x 2030-02-30 base >/dev/null 2>&1' _ "$EMIT" "$KEY"
check "emitir: rechaza id inválido" bash -c '! bash "$1" emitir "$2" "a b" 2030-01-01 base >/dev/null 2>&1' _ "$EMIT" "$KEY"
check "emitir: rechaza alcance inválido" bash -c '! bash "$1" emitir "$2" x 2030-01-01 todo >/dev/null 2>&1' _ "$EMIT" "$KEY"
check "QuickStart activo y binario HCR disponible" bash -c 'systemctl is-active --quiet pdirect-80 udpgw-7300 && test -f /opt/hcr/hcr-server'
vpsarg-hcr desinstalar >/dev/null 2>&1
check "HCR desinstalado para empezar" hcr_absent
rm -f "$USED"

echo "### install.sh: tokens rechazados antes de cualquier cambio"
rejected sin-token "Falta el token de instalación" ""
rejected formato "no tiene un formato válido" "no-es-un-token"
rejected largo "no tiene un formato válido" "vpsarg1.$(head -c 1100 /dev/zero | tr '\0' A).AAAA"
rejected otra-clave "La firma del token no es válida" "$(bash "$EMIT" emitir "$W/otra/vpsarg-token-privada.pem" lab-001 "$TODAY" base)"
rejected vencido "venció el $YESTERDAY" "$(tok lab-001 base "$YESTERDAY")"
GOOD="$(tok lab-001 base)"
ALT="$(printf 'id=lab-999\nvence=%s\nalcance=base,hcr' "$TODAY" | b64url)"
rejected alterado "La firma del token no es válida" "vpsarg1.$ALT.${GOOD##*.}"
rejected firma-cortada "La firma del token no es válida" "${GOOD%?????}"
rejected dato-desconocido "datos desconocidos" "$(sign_raw "id=lab-001"$'\n'"vence=$TODAY"$'\n'"admin=1")"
rejected sin-vencimiento "fecha de vencimiento válida" "$(sign_raw "id=lab-001")"
rejected fecha-invalida "fecha de vencimiento válida" "$(sign_raw "id=lab-001"$'\n'"vence=2030-13-01")"
rejected id-invalido "no tiene un id válido" "$(sign_raw "id=a;b"$'\n'"vence=$TODAY")"
rejected nota-invalida "nota no válida" "$(sign_raw "id=lab-001"$'\n'"vence=$TODAY"$'\n'"nota=\$(id)")"
rejected alcance-invalido "alcance no válido" "$(sign_raw "id=lab-001"$'\n'"vence=$TODAY"$'\n'"alcance=todo")"
rejected sin-clave-publica "no tiene configurada la clave pública" "$GOOD" "$W/sin-clave/install.sh"
mv /usr/bin/openssl /usr/bin/openssl.oculto
rejected sin-openssl "Falta openssl" "$GOOD"
mv /usr/bin/openssl.oculto /usr/bin/openssl
check "openssl restaurado" command -v openssl
mv /opt/hcr/hcr-server /opt/hcr/hcr-server.oculto
rejected hcr-sin-binario "El token incluye HCR pero falta /opt/hcr/hcr-server" "$(tok lab-hcr-1 base,hcr)"
mv /opt/hcr/hcr-server.oculto /opt/hcr/hcr-server
cp -p /opt/hcr/hcr-server "$W/hcr-original"; printf x >> /opt/hcr/hcr-server
rejected_tty hcr-binario-distinto "sha256 de /opt/hcr/hcr-server no coincide" "$(tok lab-hcr-1 base,hcr)"
cp -p "$W/hcr-original" /opt/hcr/hcr-server

echo "### install.sh con token solo base (escrito en la terminal, sin eco)"
BASE_UNITS="$(sha256sum /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service /usr/local/bin/pdirect-c /etc/vpsarg-pdirect.conf)"
( while sleep 0.2; do ps -eo args; done > "$W/ps.txt" 2>/dev/null ) &
PSMON=$!
# El token se escribe recién cuando aparece el pedido (como una persona), y después SI y Enter.
( sleep 3; printf '%s\n' "$GOOD"; sleep 2; printf 'SI\n\n' ) | VPSARG_SRC_DIR="$W/src" script -qec "bash $W/src/install.sh; echo \"__rc=\$?\"" /dev/null > "$W/base.log" 2>&1
RC="$(sed -n 's/^__rc=\([0-9]*\).*/\1/p' "$W/base.log" | tail -n 1)"
kill "$PSMON" 2>/dev/null; wait "$PSMON" 2>/dev/null
check "token base: instalación rc=0 (rc=$RC)" test "$RC" = 0
check "informa el token válido con su alcance" bash -c 'grep -q "Token válido: lab-001, alcance base, vence el $1" "$2"' _ "$TODAY" "$W/base.log"
check "el token no aparece en la salida (lectura sin eco)" bash -c '! grep -qF -- "${1#vpsarg1.}" "$2"' _ "$GOOD" "$W/base.log"
check "el token no aparece en la lista de procesos durante la instalación" bash -c '! grep -qF -- "${1#vpsarg1.}" "$2"' _ "$GOOD" "$W/ps.txt"
check "PDirect-C y UDPGW activos" systemctl is-active --quiet pdirect-80 udpgw-7300
check "unidades, binario de PDirect-C y destino iguales a los de antes" diff <(echo "$BASE_UNITS") <(sha256sum /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service /usr/local/bin/pdirect-c /etc/vpsarg-pdirect.conf)
check "token base: HCR NO se instala" hcr_absent
check "verificador instalado en /usr/local/lib/vpsarg/token.sh" test -r /usr/local/lib/vpsarg/token.sh
check "tokens usados: 0600 y con el id (sin el token)" bash -c '[[ "$(stat -c %a "$1")" == 600 ]] && grep -q "^id=lab-001 uso=base vence=$2 " "$1" && ! grep -qF "${3#vpsarg1.}" "$1"' _ "$USED" "$TODAY" "$GOOD"
check "registro en el journal con el id" bash -c 'journalctl -t vpsarg-instalador -o cat | grep -q "token_id=lab-001 uso=base"'
rejected reusar-base "El token lab-001 ya se usó en esta VPS" "$GOOD"

echo "### vpsarg-hcr instalar exige un token con HCR, no usado"
hcr_rejected hcr-sin-token "Falta el token de instalación" ""
hcr_rejected hcr-token-base "El token no incluye HCR" "$(tok lab-base-2 base)"
hcr_rejected hcr-token-usado "El token lab-001 ya se usó en esta VPS" "$(sign_raw "id=lab-001"$'\n'"vence=$TODAY"$'\n'"alcance=base,hcr")"
hcr_rejected hcr-vencido "venció el $YESTERDAY" "$(tok lab-hcr-2 base,hcr "$YESTERDAY")"
BEFORE="$(state)"
vpsarg-hcr verificar > "$W/verificar.log" 2>&1
RC=$?
check "vpsarg-hcr verificar: OK sin token (rc=$RC)" grep -q "OK: HCR se puede instalar" "$W/verificar.log"
check "vpsarg-hcr verificar no cambia nada" diff <(echo "$BEFORE") <(state)
PD0="$(pid_of pdirect-80)"; UG0="$(pid_of udpgw-7300)"
HCR2="$(tok lab-hcr-2 base,hcr)"
VPSARG_TOKEN="$HCR2" setsid -w vpsarg-hcr instalar </dev/null > "$W/hcr-instalar.log" 2>&1
check "token con HCR: vpsarg-hcr instalar funciona (rc=$?)" systemctl is-active --quiet hcr-8880
check "HCR: id registrado como usado" grep -q "^id=lab-hcr-2 uso=hcr " "$USED"
check "HCR: PDirect-C y UDPGW no se reiniciaron" test "$(pid_of pdirect-80) $(pid_of udpgw-7300)" = "$PD0 $UG0"
check "HCR: huella de PDirect-C y UDPGW igual" diff <(echo "$BASE_UNITS") <(sha256sum /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service /usr/local/bin/pdirect-c /etc/vpsarg-pdirect.conf)
check "HCR: estado, detener e iniciar no piden token" bash -c 'vpsarg-hcr estado </dev/null >/dev/null && vpsarg-hcr detener </dev/null >/dev/null && vpsarg-hcr iniciar </dev/null >/dev/null'
vpsarg-hcr desinstalar >/dev/null 2>&1
hcr_rejected hcr-reusar "El token lab-hcr-2 ya se usó en esta VPS" "$HCR2"
check "HCR sigue sin instalar tras el rechazo" hcr_absent

echo "### install.sh con token base,hcr: base y HCR en la misma corrida"
HCR3="$(tok lab-hcr-3 base,hcr)"
install_tty completo "$HCR3"
check "token base,hcr: instalación rc=0 (rc=$RC)" test "$RC" = 0
check "token base,hcr: HCR activo" systemctl is-active --quiet hcr-8880
check "token base,hcr: HCR sin root y en 8880 -> 127.0.0.1:22" bash -c 'p=$(systemctl show -p MainPID --value hcr-8880); [[ "$(ps -o uid= -p "$p" | tr -d " ")" != 0 ]] && ss -Hltnp "sport = :8880" | grep -q "pid=$p," && tr "\0" " " < /proc/$p/cmdline | grep -q -- "-target 127.0.0.1:22 "'
check "token base,hcr: id registrado para hcr y para base" bash -c 'grep -q "^id=lab-hcr-3 uso=hcr " "$1" && grep -q "^id=lab-hcr-3 uso=base " "$1"' _ "$USED"
check "token base,hcr: unidades, PDirect-C y destino iguales" diff <(echo "$BASE_UNITS") <(sha256sum /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service /usr/local/bin/pdirect-c /etc/vpsarg-pdirect.conf)
check "el token no aparece en journal, /var/log, /etc ni /usr/local" bash -c 'for t; do ! journalctl -o cat | grep -qF -- "${t#vpsarg1.}" && ! grep -rqF -- "${t#vpsarg1.}" /var/log /etc /usr/local 2>/dev/null || exit 1; done' _ "$GOOD" "$HCR2" "$HCR3"
vpsarg-hcr desinstalar >/dev/null 2>&1
hcr_rejected hcr-reusar-completo "El token lab-hcr-3 ya se usó en esta VPS" "$HCR3"

echo "### Después de instalar, nada consulta el token"
check "PDirect-C, UDPGW y las cuentas no leen el token" bash -c '! grep -l -e VPSARG_TOKEN -e token.sh -e tokens-usados /usr/local/sbin/vpsarg /usr/local/sbin/vpsarg-puertos /usr/local/sbin/vpsarg-usuarios /usr/local/bin/pdirect-c 2>/dev/null | grep -q .'
check "unidades sin referencias al token" bash -c '! grep -qi token /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service'

rm -rf "$W/clave" "$W/otra"
echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
