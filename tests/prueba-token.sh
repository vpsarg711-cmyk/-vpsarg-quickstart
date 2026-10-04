#!/usr/bin/env bash
# Pruebas del token único y del instalador completo (install.sh con el servicio de autorización).
# SOLO para un contenedor de laboratorio LIMPIO (sin QuickStart), con:
#   - el servicio de autorización de laboratorio en VPSARG_LAB_AUTH_URL (http://127.0.0.1:PUERTO)
#     y su línea de comandos en lab-auth (vpsarg-autorizacion.py --db ...);
#   - el binario HCR en /opt/hcr/hcr-server y los binarios de BHTTP en VPSARG_LAB_BHTTP_DIR.
# Rechaza tokens, provoca faltantes, conflictos y fallos a mitad de la instalación, comprueba
# la reversión y termina con una instalación completa. NUNCA en una VPS real.
# Uso: sudo bash tests/prueba-token.sh /ruta/al/repo
# shellcheck disable=SC2016
set -uo pipefail

REPO="${1:?Uso: sudo bash tests/prueba-token.sh /ruta/al/repo}"
[[ -e /.dockerenv ]] || { echo "Solo en el contenedor de laboratorio." >&2; exit 1; }
: "${VPSARG_LAB_AUTH_URL:?}" "${VPSARG_LAB_BHTTP_DIR:?}"
command -v lab-auth >/dev/null || { echo "Falta lab-auth." >&2; exit 1; }
W=/tmp/prueba-token
rm -rf "$W"; mkdir -p "$W/src"
FILES=(install.sh pdirect.c vpsarg-puertos.sh vpsarg-hcr.sh vpsarg-bhttp.sh vpsarg-panel.sh vpsarg-usuarios.sh vpsarg-token.sh)
for f in "${FILES[@]}"; do cp "$REPO/$f" "$W/src/"; done
export VPSARG_SRC_DIR="$W/src"
PASS=0
FAILS=0
ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
listening() { [[ -n "$(ss -Hltn "sport = :$1")" ]]; }
export -f listening
UNITS=(pdirect-80 udpgw-7300 hcr-8880 bhttp-server bhttp-shim)
# new_token: emite un token de laboratorio; deja el token en T y su id en ID.
new_token() {
  local out
  out="$(lab-auth emitir --nota prueba 2>&1)"
  T="$(tail -n 1 <<<"$out")"
  ID="$(sed -n 's/^ID: \([^ ]*\) .*/\1/p' <<<"$out")"
}
db_state() { lab-auth ver "$1" | awk '$1=="estado"{print $2}'; }
# Cambios directos en la base del servicio de laboratorio (para preparar casos).
db_exec() { python3 -c 'import sqlite3,sys; c=sqlite3.connect("/root/lab-auth.db"); c.execute(sys.argv[1], sys.argv[2:]); c.commit()' "$@"; }

# Todo lo que una corrida rechazada o revertida no debe cambiar (sin contar paquetes apt).
state() {
  local f u
  for f in /usr/local/bin/pdirect-c /etc/vpsarg-pdirect.conf /opt/badvpn/badvpn-udpgw /usr/local/sbin/vpsarg-puertos \
           /usr/local/sbin/vpsarg-hcr /usr/local/sbin/vpsarg-bhttp /usr/local/sbin/vpsarg /usr/local/sbin/vpsarg-usuarios \
           /etc/vpsarg-servicios.conf /etc/vpsarg-hcr.conf /usr/local/lib/vpsarg/hcr-server /etc/vpsarg-bhttp.conf \
           /usr/local/lib/vpsarg/bhttp-server /usr/local/lib/vpsarg/bhttp-shim /etc/vpsarg/instalacion \
           /etc/systemd/system/{pdirect-80,udpgw-7300,hcr-8880,bhttp-server,bhttp-shim}.service; do
    if [[ -e "$f" ]]; then echo "$f $(sha256sum < "$f" | cut -c1-16)"; else echo "$f no existe"; fi
  done
  for u in "${UNITS[@]}"; do
    echo "$u $(systemctl is-active "$u" 2>/dev/null) $(systemctl is-enabled "$u" 2>/dev/null)"
  done
  for f in /opt/badvpn /usr/local/lib/vpsarg /etc/vpsarg; do [[ -d "$f" ]] && echo "carpeta $f"; done
  echo "escuchan: $(for p in 80 7300 8880 8001 18022; do listening "$p" && printf '%s ' "$p"; done)"
  echo "temporales: $(find /tmp -maxdepth 1 -name 'tmp.*' -newer "$W/marca" | wc -l)"
  echo "marca de instalación en curso: $(test -e /run/vpsarg-instalacion && echo sí || echo no)"
}

# install_run NOMBRE TOKEN [RESPUESTAS] [SCRIPT]: corre install.sh. Con RESPUESTAS usa una terminal
# (script) y escribe esas respuestas; sin RESPUESTAS corre sin terminal (valores por defecto).
install_run() {
  local name="$1" token="$2" answers="${3:-}" script="${4:-$W/src/install.sh}"
  if [[ -n "$answers" ]]; then
    # script no siempre devuelve el código del hijo cuando la entrada termina antes: se toma del log.
    VPSARG_TOKEN="$token" VPSARG_SRC_DIR="${script%/*}" script -qec "bash $script; echo \"__rc=\$?\"" /dev/null \
      < <(printf '%b' "$answers") > "$W/$name.log" 2>&1
    RC="$(sed -n 's/^__rc=\([0-9]*\).*/\1/p' "$W/$name.log" | tail -n 1)"
    RC="${RC:-99}"
  else
    VPSARG_TOKEN="$token" VPSARG_SRC_DIR="${script%/*}" setsid -w bash "$script" </dev/null > "$W/$name.log" 2>&1
    RC=$?
  fi
}

# rejected NOMBRE MENSAJE TOKEN [RESPUESTAS] [SCRIPT]: se detiene antes de cambiar nada.
rejected() {
  local name="$1" msg="$2" token="$3" before
  before="$(state)"
  install_run "$name" "$token" "${4:-}" "${5:-$W/src/install.sh}"
  check "$name: se detiene (rc=$RC)" test "$RC" -ne 0
  check "$name: dice \"$msg\"" grep -qF -- "$msg" "$W/$name.log"
  check "$name: sin cambios (archivos, servicios, puertos, temporales)" diff <(echo "$before") <(state)
}

# aborted NOMBRE MENSAJE [RESPUESTAS]: con token válido falta algo obligatorio;
# nada cambia y el token queda disponible.
aborted() {
  local name="$1" msg="$2" answers="${3:-}" tok id
  new_token; tok="$T"; id="$ID"
  rejected "$name" "$msg" "$tok" "$answers"
  check "$name: dice que no hubo cambios" grep -qE "Instalación abortada sin cambios|No se realizaron cambios|No se instaló ningún componente" "$W/$name.log"
  check "$name: el token no se consumió y quedó disponible" test "$(db_state "$id")" = emitido
}

echo "### Preparación (contenedor limpio)"
touch "$W/marca"; sleep 1
check "sin QuickStart instalado" bash -c '! systemctl cat pdirect-80 >/dev/null 2>&1 && ! test -e /usr/local/sbin/vpsarg'
check "servicio de autorización de laboratorio responde" bash -c 'curl -fsS "$VPSARG_LAB_AUTH_URL/v1/salud" | grep -q true'
check "bash -n de los scripts" bash -c 'for f in "$@"; do [[ "$f" == *.sh ]] && { bash -n "$f" || exit 1; }; done; exit 0' _ "${FILES[@]/#/$W/src/}"
CLEAN="$(state)"

echo "### Token rechazado antes de cualquier cambio"
rejected sin-token "Falta el token de instalación" ""
rejected formato "no tiene un formato válido" "no-es-un-token"
rejected inexistente "El token no es válido" "vpsarg_$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=' | cut -c1-43)"
new_token; lab-auth revocar "$ID" >/dev/null
rejected revocado "El token fue revocado" "$T"
new_token; db_exec "UPDATE tokens SET vence=? WHERE id=?" "$(date -u -d yesterday +%F)" "$ID"
rejected vencido "El token venció" "$T"
new_token
curl -fsS -H 'Content-Type: application/json' --data-binary "{\"token\":\"$T\",\"hostname\":\"otra-vps\"}" "$VPSARG_LAB_AUTH_URL/v1/reservar" >/dev/null
rejected en-uso "reservado por otra instalación en curso" "$T"
check "en-uso: la reserva de la otra VPS sigue" test "$(db_state "$ID")" = reservado
new_token
VPSARG_LAB_AUTH_URL=http://127.0.0.1:1 rejected servicio-caido "No se pudo contactar el servicio de autorización" "$T"
VPSARG_LAB_AUTH_URL="" rejected sin-servicio "no tiene configurado el servicio de autorización" "$T"
VPSARG_LAB_AUTH_URL=http://servidor.ejemplo rejected sin-https "debe usar https" "$T"
check "esos 3 rechazos no tocaron el token" test "$(db_state "$ID")" = emitido

echo "### Falta un componente obligatorio: se detiene antes de cambiar nada y libera el token"
mv /opt/hcr/hcr-server /opt/hcr/hcr-server.oculto
aborted hcr-falta "HCR requerido pero no disponible"
mv /opt/hcr/hcr-server.oculto /opt/hcr/hcr-server
cp -p /opt/hcr/hcr-server "$W/hcr-original"; printf x >> /opt/hcr/hcr-server
aborted hcr-modificado "sha256 de /opt/hcr/hcr-server no coincide"
cp -p "$W/hcr-original" /opt/hcr/hcr-server
check "HCR restaurado" cmp -s /opt/hcr/hcr-server "$W/hcr-original"
mkdir -p "$W/bh-falta" "$W/bh-mod"
cp -p "$VPSARG_LAB_BHTTP_DIR/bhttp-server" "$W/bh-falta/"
cp -p "$VPSARG_LAB_BHTTP_DIR/bhttp-server" "$VPSARG_LAB_BHTTP_DIR/bhttp-shim" "$W/bh-mod/"; printf x >> "$W/bh-mod/bhttp-server"
VPSARG_LAB_BHTTP_DIR="$W/bh-falta" aborted bhttp-falta "BHTTP requerido pero falta bhttp-shim"
VPSARG_LAB_BHTTP_DIR="$W/bh-mod" aborted bhttp-modificado "El sha256 de bhttp-server no coincide"
python3 -m http.server 8001 --bind 0.0.0.0 >/dev/null 2>&1 & WEB=$!
for _ in $(seq 20); do listening 8001 && break; sleep 0.3; done
aborted bhttp-puerto-ocupado "El puerto TCP 8001 ya está en uso por otro programa"
check "bhttp-puerto-ocupado: no detuvo el programa del 8001" kill -0 "$WEB"
kill "$WEB"; wait "$WEB" 2>/dev/null
python3 -m http.server 8880 --bind 0.0.0.0 >/dev/null 2>&1 & WEB=$!
for _ in $(seq 20); do listening 8880 && break; sleep 0.3; done
aborted hcr-puerto-ocupado "El puerto TCP 8880 ya está en uso por otro programa"
kill "$WEB"; wait "$WEB" 2>/dev/null
aborted bhttp-mismo-puerto-que-hcr "ya es el de HCR" '\n8880\n'
aborted bhttp-puerto-reservado "ya lo usa otro protocolo" '\n7300\n'
aborted cancelar "Cancelado" '2299\nn\n'

echo "### Fallo de la compilación: no queda nada instalado y el token vuelve a estar disponible"
mkdir -p "$W/falso"; printf '#!/bin/sh\necho "cmake de prueba: falla" >&2\nexit 1\n' > "$W/falso/cmake"; chmod 0755 "$W/falso/cmake"
PATH="$W/falso:$PATH" aborted compilacion "falló el paso: compilar BadVPN UDPGW. No se instaló ningún componente de VPS ARG"

echo "### Fallo a mitad de la instalación (sistema limpio): se revierte todo"
mkdir -p "$W/falla-bhttp"; cp "$W/src/"* "$W/falla-bhttp/"
python3 - "$W/falla-bhttp/vpsarg-bhttp.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
a = "cmd_instalar() {\n  require_authorized\n"
assert a in s
open(p, "w").write(s.replace(a, a + '  fail "falla de prueba en la instalación de BHTTP"\n'))
PY
new_token
install_run falla-limpio "$T" "" "$W/falla-bhttp/install.sh"
check "falla-limpio: termina con error (rc=$RC)" test "$RC" -ne 0
check "falla-limpio: informa el paso que falló" grep -q "falló la instalación en el paso: instalar BHTTP" "$W/falla-limpio.log"
check "falla-limpio: informa la reversión completa" grep -q "Reversión completa" "$W/falla-limpio.log"
check "falla-limpio: el sistema quedó como antes (nada de VPS ARG instalado)" diff <(echo "$CLEAN") <(state)
check "falla-limpio: ningún puerto de VPS ARG abierto" \
  bash -c '[[ -z "$(ss -Hltn "( sport = :80 or sport = :7300 or sport = :8880 or sport = :8001 or sport = :18022 )")" ]]'
check "falla-limpio: el token no se consumió y quedó disponible" test "$(db_state "$ID")" = emitido

echo "### Instalación completa con el token (escrito en la terminal, sin eco)"
new_token
( while sleep 0.2; do ps -eo args; done > "$W/ps.txt" 2>/dev/null ) &
PSMON=$!
( sleep 3; printf '%s\n' "$T"; sleep 2; printf '\n\n' ) | script -qec "bash $W/src/install.sh; echo \"__rc=\$?\"" /dev/null > "$W/completa.log" 2>&1
RC="$(sed -n 's/^__rc=\([0-9]*\).*/\1/p' "$W/completa.log" | tail -n 1)"
kill "$PSMON" 2>/dev/null; wait "$PSMON" 2>/dev/null
check "instalación completa rc=0 (rc=${RC:-?})" test "${RC:-99}" = 0
for u in "${UNITS[@]}"; do
  check "$u activo y habilitado" bash -c "systemctl is-active --quiet $u && systemctl is-enabled --quiet $u"
done
for p in 80 7300 8880 8001; do check "escucha en TCP $p" listening "$p"; done
check "bhttp-server solo en 127.0.0.1:18022" bash -c '[[ "$(ss -Hltn "sport = :18022" | awk "{print \$4}")" == 127.0.0.1:18022 ]]'
check "HCR y BHTTP apuntan al mismo SSH que PDirect-C (22)" \
  bash -c 'grep -qx HCR_SSH_PORT=22 /etc/vpsarg-hcr.conf && grep -qx BHTTP_SSH_PORT=22 /etc/vpsarg-bhttp.conf && grep -qx SSH_PORT=22 /etc/vpsarg-pdirect.conf'
check "token consumido en el servicio" test "$(db_state "$ID")" = consumido
check "informa que el token se consumió" grep -q "Token $ID consumido" "$W/completa.log"
check "registro local 0600 con el id y estado instalada (sin el token)" \
  bash -c '[[ "$(stat -c %a /etc/vpsarg/instalacion)" == 600 ]] && grep -qx "token_id=$1" /etc/vpsarg/instalacion && grep -qx estado=instalada /etc/vpsarg/instalacion && ! grep -qF "$2" /etc/vpsarg/instalacion' _ "$ID" "$T"
check "el token no aparece en la salida (lectura sin eco)" bash -c '! grep -qF -- "${1#vpsarg_}" "$2"' _ "$T" "$W/completa.log"
check "el token no aparece en la lista de procesos" bash -c '! grep -qF -- "${1#vpsarg_}" "$2"' _ "$T" "$W/ps.txt"
check "el token no aparece en journal, /var/log, /etc, /usr/local ni /var/backups" \
  bash -c '! journalctl -o cat | grep -qF -- "${1#vpsarg_}" && ! grep -rqF -- "${1#vpsarg_}" /var/log /etc /usr/local /var/backups 2>/dev/null' _ "$T"
check "registro en el journal con el id" bash -c 'journalctl -t vpsarg-instalador -o cat | grep -q "token_id=$1 resultado=instalada"' _ "$ID"
check "no queda la marca de instalación en curso" test ! -e /run/vpsarg-instalacion
check "el instalador no deja el cliente del token en la VPS" test ! -e /usr/local/lib/vpsarg/token.sh
check "ninguna parte instalada lee el token" \
  bash -c '! grep -l -e VPSARG_TOKEN -e token.sh /usr/local/sbin/vpsarg* /etc/systemd/system/{pdirect-80,udpgw-7300,hcr-8880,bhttp-server,bhttp-shim}.service 2>/dev/null | grep -q .'
rejected reusar "El token ya se usó en otra instalación" "$T"
check "reusar: sigue consumido" test "$(db_state "$ID")" = consumido

echo "### Reinstalar encima con un token nuevo (con otro puerto de BHTTP)"
new_token
install_run reinstalar "$T" 'SI\n\n8005\n'
check "reinstalar: rc=0 (rc=$RC)" test "$RC" = 0
check "reinstalar: BHTTP en 8005 y ya no en 8001" bash -c 'listening 8005 && ! listening 8001 && grep -qx BHTTP_PORT=8005 /etc/vpsarg-bhttp.conf'
check "reinstalar: token consumido" test "$(db_state "$ID")" = consumido
vpsarg-bhttp puerto 8001 >/dev/null
check "vuelta a 8001 con vpsarg-bhttp puerto" listening 8001

echo "### Fallo a mitad de una reinstalación: vuelve la instalación anterior, funcionando"
mkdir -p "$W/falla-hcr"; cp "$W/src/"* "$W/falla-hcr/"
python3 - "$W/falla-hcr/vpsarg-hcr.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
a = "cmd_instalar() {\n  require_authorized\n"
assert a in s
open(p, "w").write(s.replace(a, a + '  fail "falla de prueba en la instalación de HCR"\n'))
PY
FULL="$(state)"
new_token
install_run falla-reinstalar "$T" 'SI\n\n\n' "$W/falla-hcr/install.sh"
check "falla-reinstalar: termina con error (rc=$RC)" test "$RC" -ne 0
check "falla-reinstalar: informa el paso que falló" grep -q "falló la instalación en el paso: instalar HCR" "$W/falla-reinstalar.log"
check "falla-reinstalar: informa la reversión completa" grep -q "Reversión completa" "$W/falla-reinstalar.log"
sleep 2
check "falla-reinstalar: archivos, servicios y puertos como antes" diff <(echo "$FULL") <(state)
check "falla-reinstalar: el controlador de HCR es el de antes (no el de prueba)" \
  bash -c '! grep -q "falla de prueba" /usr/local/sbin/vpsarg-hcr'
check "falla-reinstalar: el token no se consumió" test "$(db_state "$ID")" = emitido
check "falla-reinstalar: PDirect-C llega a SSH" timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/80; printf "GET / HTTP/1.1\r\nHost: x\r\n\r\n" >&3; for _ in 1 2 3 4 5 6 7 8; do IFS= read -r -t 4 l <&3 || exit 1; [[ "$l" == SSH-* ]] && exit 0; done; exit 1'
install_run reintento "$T" 'SI\n\n\n'
check "el mismo token sirve para reintentar después de la reversión (rc=$RC)" test "$RC" = 0
check "reintento: token consumido" test "$(db_state "$ID")" = consumido

echo "### Componentes sueltos sin instalación autorizada"
mv /etc/vpsarg/instalacion "$W/instalacion"
check "vpsarg-hcr instalar se niega" bash -c 'vpsarg-hcr instalar 2>&1 | grep -q "HCR se instala con install.sh y un token"'
check "vpsarg-bhttp instalar se niega" bash -c 'vpsarg-bhttp instalar 2>&1 | grep -q "BHTTP se instala con install.sh y un token"'
mv "$W/instalacion" /etc/vpsarg/instalacion

rm -rf "$W/falso" "$W/bh-mod" "$W/bh-falta"
echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
