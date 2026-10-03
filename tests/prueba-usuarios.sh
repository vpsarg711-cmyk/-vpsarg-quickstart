#!/usr/bin/env bash
# Pruebas de laboratorio de las cuentas SSH (Fase 2C y etapa 3B).
# SOLO para una máquina o contenedor de laboratorio con QuickStart instalado:
# instala sshpass, crea y borra cuentas de prueba, inicia un sshd extra en
# 127.0.0.1:2223 (sin contraseñas, por línea de comandos) y entra por SSH de verdad,
# directo y a través de PDirect-C (TCP 80).
# No reinicia UDPGW ni toca sshd_config ni /etc/shells: se verifica al final.
# Uso: sudo bash tests/prueba-usuarios.sh
# shellcheck disable=SC2016
set -uo pipefail

PASS=0
FAILS=0
PW='Prueba-2c.Clave'      # contraseña de laboratorio
PW2='Otra-2c.Clave'
OUT=/tmp/usuarios.out
TUN=""

ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
pid_of() { systemctl show -p MainPID --value "$1"; }
u() { vpsarg-usuarios "$@" > "$OUT" 2>&1; }
has() { grep -q -- "$1" "$OUT"; }
expire() { getent shadow "$1" | cut -d: -f8; }
journal_has() { journalctl -t vpsarg-panel -o cat | grep -q -- "$1"; }
state_of() { vpsarg-usuarios listar | awk -v u="$1" '$1==u{print $3}'; }
sessions_of() { vpsarg-usuarios listar | awk -v u="$1" '$1==u{print $(NF-1)}'; }
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
         -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1
         -o ConnectTimeout=10)

# Abre un túnel ssh -N -L 19000 -> 127.0.0.1:22 como lo usaría una app.
# tunnel USUARIO CLAVE [directo|pdirect] [PUERTO_SSH]
tunnel() {
  local via="${3:-directo}" port="${4:-22}" proxy=()
  [[ "$via" == pdirect ]] && proxy=(-o "ProxyCommand=python3 /tmp/pd-proxy.py")
  SSHPASS="$2" sshpass -e ssh "${SSHOPTS[@]}" "${proxy[@]}" -p "$port" -N -o ExitOnForwardFailure=yes \
    -L 127.0.0.1:19000:127.0.0.1:22 "$1@127.0.0.1" >/dev/null 2>&1 &
  TUN=$!
}
# Éxito: el túnel queda abierto y por el puerto 19000 responde SSH.
login_ok() {
  local _
  tunnel "$@"
  for _ in $(seq 30); do
    if timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/19000 && IFS= read -r -t 2 l <&3 && [[ "$l" == SSH-* ]]' 2>/dev/null; then
      return 0
    fi
    kill -0 "$TUN" 2>/dev/null || return 1
    sleep 0.5
  done
  return 1
}
# wait_sessions USUARIO N: espera (hasta 70 s) a que el listado cuente N sesiones; deja WAITED en segundos.
wait_sessions() {
  local i
  for i in $(seq 0 140); do
    [[ "$(sessions_of "$1")" == "$2" ]] && { WAITED=$((i / 2)); return 0; }
    sleep 0.5
  done
  WAITED=70
  return 1
}
close_tunnel() { [[ -n "$TUN" ]] && kill "$TUN" 2>/dev/null; wait "$TUN" 2>/dev/null; TUN=""; }
# Segunda sesión, sin túnel: bg_session USUARIO CLAVE (deja el PID en BG).
bg_session() {
  SSHPASS="$2" sshpass -e ssh "${SSHOPTS[@]}" -N "$1@127.0.0.1" >/dev/null 2>&1 &
  BG=$!
}
uid_procs() { pgrep -u "$1" 2>/dev/null | wc -l; }
TODAY=$(( $(date +%s) / 86400 ))
day() { date -u -d "@$(( $1 * 86400 ))" +%F; }
# Rechazo: ssh termina solo con error antes de 20 s (124 = quedó conectado).
login_fails() {
  local via="${3:-directo}" port="${4:-22}" proxy=() rc
  [[ "$via" == pdirect ]] && proxy=(-o "ProxyCommand=python3 /tmp/pd-proxy.py")
  SSHPASS="$2" timeout 20 sshpass -e ssh "${SSHOPTS[@]}" "${proxy[@]}" -p "$port" -N "$1@127.0.0.1" >/dev/null 2>&1
  rc=$?
  ((rc != 0 && rc != 124))
}
sums() {
  sha256sum /etc/ssh/sshd_config /etc/shells /etc/vpsarg-pdirect.conf \
    /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service \
    /usr/local/bin/pdirect-c /opt/badvpn/badvpn-udpgw
  find /etc/ssh/sshd_config.d -type f -exec sha256sum {} + 2>/dev/null
}

echo "### Preparación"
if ! command -v sshpass >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass openssh-client >/dev/null
fi
check "sshpass disponible (solo para la prueba)" command -v sshpass
# Cliente para entrar por PDirect-C: manda el pedido HTTP, descarta las dos
# respuestas "HTTP/1.1 101" y después pasa los bytes de SSH tal cual.
cat > /tmp/pd-proxy.py <<'EOF'
import os, select, socket, sys
s = socket.create_connection(("127.0.0.1", 80))
s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n\r\n")
buf = b""
while buf.count(b"\r\n\r\n") < 2:
    d = s.recv(1)
    if not d:
        sys.exit(1)
    buf += d
while True:
    r, _, _ = select.select([0, s], [], [])
    if 0 in r:
        d = os.read(0, 65536)
        if not d:
            s.shutdown(socket.SHUT_WR)
        else:
            s.sendall(d)
    if s in r:
        d = s.recv(65536)
        if not d:
            break
        os.write(1, d)
EOF
mkdir -p /run/sshd
/usr/sbin/sshd -p 2223 -o PidFile=/run/sshd-2223.pid -o PasswordAuthentication=no
sleep 1
SUMS0="$(sums)"
UG_PID0="$(pid_of udpgw-7300)"
PD_PID0="$(pid_of pdirect-80)"
useradd -m externo   # cuenta ajena al panel
check "vpsarg-usuarios instalado" test -x /usr/local/sbin/vpsarg-usuarios
check "sshd principal acepta contraseñas en este laboratorio" bash -c '[[ "$(sshd -T | awk '"'"'$1=="passwordauthentication"{print $2}'"'"')" == yes ]]'

echo "### Permisos"
check "sin root: listar se niega" bash -c '! setpriv --reuid=65534 --regid=65534 --clear-groups /usr/local/sbin/vpsarg-usuarios listar >/dev/null 2>&1'
check "sin root: crear se niega y no crea nada" bash -c 'echo x1234567 | setpriv --reuid=65534 --regid=65534 --clear-groups /usr/local/sbin/vpsarg-usuarios crear sinroot >/dev/null 2>&1; ! getent passwd sinroot >/dev/null'
check "argumentos de más se rechazan" bash -c '! vpsarg-usuarios suspender a b >/dev/null 2>&1'

echo "### Nombres inválidos"
N0="$(getent passwd | wc -l)"
for name in Root 'a;id' '../x' '-x' 'a b' '$(id)' 'abcdefghijklmnopqrstuvwxyz012345' 'x/y' '' 'ñandu'; do
  check "rechaza el nombre '$name'" bash -c '! echo "$1" | vpsarg-usuarios crear "$2" >/dev/null 2>&1' _ "$PW" "$name"
done
check "no se creó ninguna cuenta" test "$(getent passwd | wc -l)" = "$N0"
check "registro: nombre no válido" journal_has "accion=crear usuario=- resultado=error motivo=\"nombre de usuario no válido"

echo "### Crear"
check "rechaza contraseña corta" bash -c '! echo abc | vpsarg-usuarios crear ana >/dev/null 2>&1 && ! getent passwd ana >/dev/null'
check "rechaza contraseña con ':'" bash -c '! echo "abc:defgh" | vpsarg-usuarios crear ana >/dev/null 2>&1 && ! getent passwd ana >/dev/null'
check "rechaza contraseña vacía" bash -c '! vpsarg-usuarios crear ana </dev/null >/dev/null 2>&1 && ! getent passwd ana >/dev/null'
check "crear ana" bash -c 'echo "$1" | vpsarg-usuarios crear ana' _ "$PW"
check "ana existe con shell nologin" test "$(getent passwd ana | cut -d: -f7)" = /usr/sbin/nologin
check "ana es del grupo vpsarg-usuarios" bash -c 'id -nG ana | tr " " "\n" | grep -qx vpsarg-usuarios'
check "ana tiene directorio personal propio" test "$(stat -c %U "$(getent passwd ana | cut -d: -f6)")" = ana
check "ana tiene contraseña cifrada" bash -c '[[ "$(getent shadow ana | cut -d: -f2)" == \$* ]]'
check "ana sin vencimiento" test -z "$(expire ana)"
check "registro: crear ok" journal_has "accion=crear usuario=ana resultado=ok"
check "crear ana otra vez falla" bash -c '! echo "$1" | vpsarg-usuarios crear ana >/dev/null 2>&1' _ "$PW"
check "crear root falla" bash -c '! echo "$1" | vpsarg-usuarios crear root >/dev/null 2>&1' _ "$PW"
check "crear externo (cuenta ajena existente) falla" bash -c '! echo "$1" | vpsarg-usuarios crear externo >/dev/null 2>&1' _ "$PW"
check "listar: ana ACTIVO, límite 1, 0 sesiones, vence nunca" bash -c 'vpsarg-usuarios listar | grep -Eq "^ana +[0-9]+ +ACTIVO +1 +0 +nunca$"'
check "listar no muestra cuentas ajenas" bash -c '! vpsarg-usuarios listar | grep -Eq "^(root|externo) "'

echo "### Autenticación SSH real"
check "ana entra con usuario y contraseña (túnel -L)" login_ok ana "$PW"
check "listar cuenta 1 sesión de ana" test "$(sessions_of ana)" = 1
close_tunnel
check "ana entra a través de PDirect-C (TCP 80)" login_ok ana "$PW" pdirect
close_tunnel
# Con libevent 2.1.11 (Ubuntu 20.04) PDirect-C mantiene la conexión hacia SSH hasta su
# espera de 60 s después de que el cliente se va; en 22.04/24.04 se libera enseguida.
check "al cerrar el cliente, la sesión por PDirect-C se libera (hasta 70 s)" wait_sessions ana 0
echo "      sesión liberada en ${WAITED} s"
check "contraseña incorrecta: rechazada" login_fails ana "$PW2"
check "ana no obtiene una shell" bash -c 'out="$(SSHPASS="$1" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no ana@127.0.0.1 id 2>&1)"; [[ "$out" != *uid=* && "$out" == *"not available"* ]]' _ "$PW"

echo "### Suspender"
HASH0="$(getent shadow ana | cut -d: -f2)"
login_ok ana "$PW"
check "sesión abierta antes de suspender" test "$(sessions_of ana)" = 1
check "suspender ana" u suspender ana
check "informa la sesión cerrada" has "Sesiones SSH cerradas: 1"
check "el túnel abierto se cerró" bash -c "sleep 1; ! kill -0 $TUN 2>/dev/null"
close_tunnel
check "vencimiento 0 (chage -E 0)" test "$(expire ana)" = 0
check "estado SUSPENDIDO" test "$(state_of ana)" = SUSPENDIDO
check "vencimiento anterior guardado (vacío = nunca)" grep -qx "ana:" /etc/vpsarg/usuarios-suspendidos
check "archivo de suspendidos 0600" test "$(stat -c %a /etc/vpsarg/usuarios-suspendidos)" = 600
check "la contraseña no se tocó" test "$(getent shadow ana | cut -d: -f2)" = "$HASH0"
check "suspendida: no entra directo" login_fails ana "$PW"
check "suspendida: no entra por PDirect-C" login_fails ana "$PW" pdirect
check "registro: suspender ok" journal_has "accion=suspender usuario=ana resultado=ok"
check "suspender otra vez: sin cambios" bash -c 'vpsarg-usuarios suspender ana | grep -q "ya estaba suspendida" && grep -qx "ana:" /etc/vpsarg/usuarios-suspendidos'

echo "### Reactivar"
check "reactivar ana" u reactivar ana
check "sin vencimiento otra vez" test -z "$(expire ana)"
check "estado ACTIVO" test "$(state_of ana)" = ACTIVO
check "se borró el vencimiento guardado" bash -c '! grep -q "^ana:" /etc/vpsarg/usuarios-suspendidos'
check "la contraseña sigue igual" test "$(getent shadow ana | cut -d: -f2)" = "$HASH0"
check "ana entra otra vez" login_ok ana "$PW"
close_tunnel

echo "### Etapa 3B: crear con vencimiento y límite"
check "límite por defecto 1 (ana)" grep -qx "ana:1" /etc/vpsarg/limites
check "archivo de límites 0600" test "$(stat -c %a /etc/vpsarg/limites)" = 600
check "crear dani con 30 días y límite 2" bash -c 'echo "$1" | vpsarg-usuarios crear dani 30 2' _ "$PW"
check "dani vence en 30 días" test "$(expire dani)" = $((TODAY + 30))
check "límite de dani 2" grep -qx "dani:2" /etc/vpsarg/limites
check "listar: dani ACTIVO, límite 2, vence en 30 días" bash -c 'vpsarg-usuarios listar | grep -Eq "^dani +[0-9]+ +ACTIVO +2 +0 +$1$"' _ "$(day $((TODAY + 30)))"
check "registro: crear con vencimiento y límite" journal_has "accion=crear usuario=dani resultado=ok vence=$(day $((TODAY + 30))) limite=2"
for args in "0" "3651" "x" "30 100" "30 -1" "30 x"; do
  # shellcheck disable=SC2086
  check "crear rechaza días/límite '$args'" bash -c '! echo "$1" | vpsarg-usuarios crear eva $2 >/dev/null 2>&1 && ! getent passwd eva >/dev/null' _ "$PW" "$args"
done
check "crear con límite 0 = sin límite" bash -c 'echo "$1" | vpsarg-usuarios crear eva 5 0 >/dev/null && vpsarg-usuarios listar | grep -Eq "^eva +[0-9]+ +ACTIVO +- +0 "' _ "$PW"
check "eliminar eva" u eliminar eva

echo "### Etapa 3B: renovar y vencimiento"
check "renovar dani 10: suma desde su vencimiento" bash -c 'vpsarg-usuarios renovar dani 10 >/dev/null && [[ "$(getent shadow dani | cut -d: -f8)" == "$1" ]]' _ $((TODAY + 40))
check "renovar ana 5 (sin vencimiento): desde hoy" bash -c 'vpsarg-usuarios renovar ana 5 >/dev/null && [[ "$(getent shadow ana | cut -d: -f8)" == "$1" ]]' _ $((TODAY + 5))
check "registro: renovar ok" journal_has "accion=renovar usuario=dani resultado=ok vence=$(day $((TODAY + 40)))"
check "renovar rechaza días inválidos" bash -c '! vpsarg-usuarios renovar dani 0 >/dev/null 2>&1 && ! vpsarg-usuarios renovar dani abc >/dev/null 2>&1 && [[ "$(getent shadow dani | cut -d: -f8)" == "$1" ]]' _ $((TODAY + 40))
check "renovar root y externo se niega" bash -c '! vpsarg-usuarios renovar root 5 >/dev/null 2>&1 && ! vpsarg-usuarios renovar externo 5 >/dev/null 2>&1 && [[ -z "$(getent shadow externo | cut -d: -f8)" ]]'
check "vencimiento dani 2030-01-15" bash -c 'vpsarg-usuarios vencimiento dani 2030-01-15 >/dev/null && [[ "$(getent shadow dani | cut -d: -f8)" == $(( $(date -u -d 2030-01-15 +%s) / 86400 )) ]]'
check "vencimiento ana nunca" bash -c 'vpsarg-usuarios vencimiento ana nunca >/dev/null && [[ -z "$(getent shadow ana | cut -d: -f8)" ]]'
check "vencimiento rechaza fecha inválida, hoy o pasada" bash -c 'for d in 2030-02-30 2030-1-1 "$(date -u +%F)" 2020-01-01 mañana; do vpsarg-usuarios vencimiento dani "$d" >/dev/null 2>&1 && exit 1; done; true'
login_ok dani "$PW"
chage -E "$TODAY" dani   # simula que hoy es el día del vencimiento
check "el día del vencimiento: estado VENCIDO" test "$(state_of dani)" = VENCIDO
check "vencida: la sesión abierta sigue" bash -c "sleep 2; kill -0 $TUN 2>/dev/null"
check "vencida: no entra una conexión nueva" login_fails dani "$PW"
close_tunnel
check "renovar una cuenta vencida: desde hoy" bash -c 'vpsarg-usuarios renovar dani 3 >/dev/null && [[ "$(getent shadow dani | cut -d: -f8)" == "$1" ]] && [[ "$(vpsarg-usuarios listar | awk "\$1==\"dani\"{print \$3}")" == ACTIVO ]]' _ $((TODAY + 3))
check "renovada: entra otra vez" login_ok dani "$PW"
close_tunnel
check "suspender dani" u suspender dani
check "suspendida: renovar guarda el vencimiento sin reactivarla" bash -c 'vpsarg-usuarios renovar dani 7 >/dev/null && [[ "$(getent shadow dani | cut -d: -f8)" == 0 ]] && grep -qx "dani:$1" /etc/vpsarg/usuarios-suspendidos' _ $((TODAY + 10))
check "reactivar aplica el vencimiento renovado" bash -c 'vpsarg-usuarios reactivar dani >/dev/null && [[ "$(getent shadow dani | cut -d: -f8)" == "$1" ]]' _ $((TODAY + 10))

echo "### Etapa 3B: cambiar contraseña"
HASHD="$(getent shadow dani | cut -d: -f2)"
check "clave rechaza una contraseña corta" bash -c '! echo abc | vpsarg-usuarios clave dani >/dev/null 2>&1 && [[ "$(getent shadow dani | cut -d: -f2)" == "$1" ]]' _ "$HASHD"
check "clave de root y externo se niega" bash -c '! echo "$1" | vpsarg-usuarios clave root >/dev/null 2>&1 && ! echo "$1" | vpsarg-usuarios clave externo >/dev/null 2>&1' _ "$PW2"
login_ok dani "$PW"
check "cambiar la contraseña de dani" bash -c 'echo "$1" | vpsarg-usuarios clave dani >/dev/null' _ "$PW2"
check "la contraseña cambió" bash -c '[[ "$(getent shadow dani | cut -d: -f2)" != "$1" ]]' _ "$HASHD"
check "cambiar la contraseña no cierra la sesión abierta" bash -c "kill -0 $TUN 2>/dev/null"
close_tunnel
check "la contraseña vieja ya no entra" login_fails dani "$PW"
check "la nueva entra" login_ok dani "$PW2"
close_tunnel
check "registro: clave ok sin la contraseña" bash -c 'journalctl -t vpsarg-panel -o cat | grep -q "accion=clave usuario=dani resultado=ok" && ! journalctl -o cat | grep -qF "$1"' _ "$PW2"

echo "### Etapa 3B: límite de conexiones (se guarda; se aplica en 3C)"
check "limite dani muestra 2" bash -c 'vpsarg-usuarios limite dani | grep -q "límite 2"'
check "limite dani 5" bash -c 'vpsarg-usuarios limite dani 5 >/dev/null && grep -qx "dani:5" /etc/vpsarg/limites'
check "limite rechaza 100, -1 y texto" bash -c 'for n in 100 -1 x; do vpsarg-usuarios limite dani "$n" >/dev/null 2>&1 && exit 1; done; grep -qx "dani:5" /etc/vpsarg/limites'
check "limite de root y externo se niega" bash -c '! vpsarg-usuarios limite root 2 >/dev/null 2>&1 && ! vpsarg-usuarios limite externo 2 >/dev/null 2>&1 && ! grep -q "^\(root\|externo\):" /etc/vpsarg/limites'
login_ok dani "$PW2"
bg_session dani "$PW2"
check "dos sesiones de dani" wait_sessions dani 2
check "bajar el límite a 1 no cierra ninguna sesión" bash -c "vpsarg-usuarios limite dani 1 >/dev/null; sleep 2; kill -0 $TUN 2>/dev/null && kill -0 $BG 2>/dev/null"
check "Estado marca a dani 2/1 EXCEDE" bash -c 'vpsarg sistema | grep -qE "^  dani +2/1  EXCEDE$"'
kill "$BG" 2>/dev/null; wait "$BG" 2>/dev/null
check "limite dani 0 = sin límite" bash -c 'vpsarg-usuarios limite dani 0 >/dev/null && vpsarg-usuarios limite dani | grep -q "sin límite" && vpsarg-usuarios listar | grep -Eq "^dani +[0-9]+ +ACTIVO +- "'
check "registro: limite ok" journal_has "accion=limite usuario=dani resultado=ok limite=0"

echo "### Etapa 3B: eliminar justo después de una sesión (systemd --user)"
login_ok ana "$PW"          # sesión de otra cuenta que tiene que seguir
ANA_TUN="$TUN"
TUN=""
login_ok dani "$PW2"
DUID="$(id -u dani)"
close_tunnel
check "eliminar dani enseguida de cerrar su sesión" u eliminar dani
check "dani no existe y no quedan procesos de su UID" bash -c '! getent passwd dani >/dev/null && [[ $(pgrep -u "$1" | wc -l) == 0 ]]' _ "$DUID"
check "se borró su límite" bash -c '! grep -q "^dani:" /etc/vpsarg/limites'
check "la sesión de ana siguió abierta" bash -c "kill -0 $ANA_TUN 2>/dev/null && [[ \$(vpsarg-usuarios listar | awk '\$1==\"ana\"{print \$(NF-1)}') == 1 ]]"
check "externo sigue intacto" bash -c 'getent passwd externo >/dev/null'
TUN="$ANA_TUN"
close_tunnel
check "reactivar otra vez: sin cambios" bash -c 'vpsarg-usuarios reactivar ana | grep -q "no estaba suspendida"'
chage -E 2030-01-01 ana
check "con vencimiento 2030-01-01: suspender" u suspender ana
check "guarda 2030-01-01" grep -qx "ana:$(( $(date -u -d 2030-01-01 +%s) / 86400 ))" /etc/vpsarg/usuarios-suspendidos
check "ver muestra la fecha que se restaurará" bash -c 'vpsarg-usuarios ver ana | grep -q "al reactivar: 2030-01-01"'
check "reactivar restaura 2030-01-01" bash -c 'vpsarg-usuarios reactivar ana >/dev/null && [[ "$(chage -l ana | grep -i "account expires")" == *2030* ]]'
check "ana entra con el vencimiento restaurado" login_ok ana "$PW"
close_tunnel
chage -E 0 ana
check "suspendida fuera del panel: reactivar avisa y deja sin vencimiento" \
  bash -c 'vpsarg-usuarios reactivar ana 2>&1 | grep -q "no hay vencimiento guardado" && [[ -z "$(getent shadow ana | cut -d: -f8)" ]]'

echo "### Errores de SSH"
check "en un sshd sin contraseñas (2223) ana no entra" login_fails ana "$PW" directo 2223
mkdir -p /tmp/sshd-falso
cat > /tmp/sshd-falso/sshd <<'EOF'
#!/bin/bash
# sshd de prueba: informa PasswordAuthentication no sin tocar la configuración real.
/usr/sbin/sshd "$@" | sed 's/^passwordauthentication .*/passwordauthentication no/'
EOF
chmod 0755 /tmp/sshd-falso/sshd
check "crear con PasswordAuthentication no: avisa" \
  bash -c 'echo "$1" | PATH=/tmp/sshd-falso:$PATH vpsarg-usuarios crear carla 2>&1 | grep -q "SSH no acepta contraseñas"' _ "$PW"
check "el panel avisa en Usuarios" bash -c 'printf "2\n\n0\n" | PATH=/tmp/sshd-falso:$PATH timeout 30 vpsarg 2>&1 | grep -q "AVISO: SSH no acepta contraseñas"'
check "vpsarg ssh informa PasswordAuthentication no" bash -c 'PATH=/tmp/sshd-falso:$PATH vpsarg ssh | grep -q "PasswordAuthentication no"'
vpsarg-usuarios eliminar carla >/dev/null 2>&1

echo "### Usuario inexistente y cuentas ajenas"
for a in ver suspender reactivar eliminar; do
  check "$a noexiste falla" bash -c 'vpsarg-usuarios "$1" noexiste 2>&1 | grep -q "no existe"' _ "$a"
  check "$a externo se niega" bash -c 'vpsarg-usuarios "$1" externo 2>&1 | grep -q "no es una cuenta administrada"' _ "$a"
  check "$a root se niega" bash -c 'vpsarg-usuarios "$1" root 2>&1 | grep -q "no es una cuenta administrada"' _ "$a"
done
check "externo sigue intacto" bash -c 'getent passwd externo >/dev/null && [[ -z "$(getent shadow externo | cut -d: -f8)" ]]'

echo "### Eliminar"
login_ok ana "$PW"
check "eliminar ana con una sesión abierta" u eliminar ana
check "cerró la sesión" has "Sesiones SSH cerradas: 1"
close_tunnel
check "ana ya no existe" bash -c '! getent passwd ana >/dev/null'
check "su directorio personal se borró" test ! -e /home/ana
check "registro: eliminar ok" journal_has "accion=eliminar usuario=ana resultado=ok"
check "eliminar otra vez falla" bash -c '! vpsarg-usuarios eliminar ana >/dev/null 2>&1'

echo "### Desde el menú del panel"
printf '2\n1\nbeto\n\n\n%s\n\n0\n0\n' "$PW" | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: crear beto" bash -c 'getent passwd beto >/dev/null && id -nG beto | grep -qw vpsarg-usuarios'
check "panel: por defecto vence en 30 días y límite 1" bash -c '[[ "$(getent shadow beto | cut -d: -f8)" == "$1" ]] && grep -qx "beto:1" /etc/vpsarg/limites' _ $((TODAY + 30))
check "panel: beto entra" login_ok beto "$PW"
check "estado: beto figura conectado 1/1" bash -c 'vpsarg sistema | grep -qE "^  beto +1/1$"'
check "estado: cuenta 1 usuario conectado" bash -c 'vpsarg sistema | grep -q "^Usuarios conectados: 1 · sesiones SSH: 1$"'
close_tunnel
check "estado: beto ya no figura conectado" bash -c 'sleep 1; ! vpsarg sistema | grep -qE "^  beto "'
printf '2\n1\nB;ad\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: nombre inválido" has "Nombre no válido"
printf '2\n1\ncora\nabc\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: días inválidos no crean la cuenta" bash -c 'grep -q "Días no válidos" '"$OUT"' && ! getent passwd cora >/dev/null'
printf '2\n1\ncora\n0\n3\n%s\n\n0\n0\n' "$PW" | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: crear con 0 días (no vence) y límite 3" bash -c '[[ -z "$(getent shadow cora | cut -d: -f8)" ]] && grep -qx "cora:3" /etc/vpsarg/limites'
printf '2\n3\nbeto\n15\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: renovar beto 15 días" test "$(expire beto)" = $((TODAY + 45))
printf '2\n4\nbeto\nnunca\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: vencimiento nunca" test -z "$(expire beto)"
printf '2\n4\nbeto\n15/01/2030\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: fecha con otro formato se rechaza" bash -c 'grep -q "Fecha no válida" '"$OUT"' && [[ -z "$(getent shadow beto | cut -d: -f8)" ]]'
HASHB="$(getent shadow beto | cut -d: -f2)"
printf '2\n5\nbeto\n%s\n\n0\n0\n' "$PW2" | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: cambiar contraseña" bash -c '[[ "$(getent shadow beto | cut -d: -f2)" != "$1" ]] && ! grep -qF "$2" '"$OUT"'' _ "$HASHB" "$PW2"
check "panel: entra con la nueva contraseña" login_ok beto "$PW2"
close_tunnel
printf '2\n6\nbeto\n10\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: cambiar límite a 10" bash -c 'grep -q "límite 1" '"$OUT"' && grep -qx "beto:10" /etc/vpsarg/limites'
printf '2\n6\nbeto\nx\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: límite inválido se rechaza" bash -c 'grep -q "Límite no válido" '"$OUT"' && grep -qx "beto:10" /etc/vpsarg/limites'
printf '2\n7\nbeto\nn\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: responder n no suspende" test -z "$(expire beto)"
printf '2\n7\nbeto\ns\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: suspender beto" test "$(expire beto)" = 0
check "panel: el listado muestra SUSPENDIDO" has "beto .*SUSPENDIDO"
printf '2\n8\nbeto\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: reactivar beto" test -z "$(expire beto)"
printf '2\n9\nbeto\nbetx\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: confirmación distinta no elimina" bash -c 'getent passwd beto >/dev/null'
printf '2\n9\nbeto\nbeto\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: eliminar beto" bash -c '! getent passwd beto >/dev/null'
printf '2\n9\ncora\ncora\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: eliminar cora" bash -c '! getent passwd cora >/dev/null && ! grep -q "^cora:" /etc/vpsarg/limites'

echo "### Lo que no debe cambiar"
userdel -r externo >/dev/null 2>&1
check "no quedan cuentas de prueba" bash -c '! getent passwd ana beto carla cora dani eva externo >/dev/null'
check "contraseñas fuera del registro" bash -c '! journalctl -o cat | grep -qF -e "$1" -e "$2"' _ "$PW" "$PW2"
check "contraseñas fuera de /etc/vpsarg y /var/log" bash -c '! grep -rqF -e "$1" /etc/vpsarg /var/log 2>/dev/null' _ "$PW"
check "UDPGW no se reinició (PID $UG_PID0)" test "$(pid_of udpgw-7300)" = "$UG_PID0"
check "PDirect-C no se reinició (PID $PD_PID0)" test "$(pid_of pdirect-80)" = "$PD_PID0"
check "sshd_config, sshd_config.d, shells, unidades, binarios y conf de PDirect-C iguales" test "$(sums)" = "$SUMS0"

kill "$(cat /run/sshd-2223.pid)" 2>/dev/null
echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
