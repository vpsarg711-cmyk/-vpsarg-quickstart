#!/usr/bin/env bash
# Pruebas de laboratorio de las cuentas SSH (Fase 2C).
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
close_tunnel() { [[ -n "$TUN" ]] && kill "$TUN" 2>/dev/null; wait "$TUN" 2>/dev/null; TUN=""; }
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
check "listar: ana ACTIVO, 0 sesiones, vence nunca" bash -c 'vpsarg-usuarios listar | grep -Eq "^ana +[0-9]+ +ACTIVO +0 +nunca$"'
check "listar no muestra cuentas ajenas" bash -c '! vpsarg-usuarios listar | grep -Eq "^(root|externo) "'

echo "### Autenticación SSH real"
check "ana entra con usuario y contraseña (túnel -L)" login_ok ana "$PW"
check "listar cuenta 1 sesión de ana" test "$(sessions_of ana)" = 1
close_tunnel
check "ana entra a través de PDirect-C (TCP 80)" login_ok ana "$PW" pdirect
close_tunnel
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
printf '2\n1\nbeto\n%s\n\n0\n0\n' "$PW" | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: crear beto" bash -c 'getent passwd beto >/dev/null && id -nG beto | grep -qw vpsarg-usuarios'
check "panel: beto entra" login_ok beto "$PW"
check "estado: beto figura conectado con 1 sesión" bash -c 'vpsarg sistema | grep -qE "^  beto +1$"'
check "estado: cuenta 1 usuario conectado" bash -c 'vpsarg sistema | grep -q "^Usuarios conectados: 1 · sesiones SSH: 1$"'
close_tunnel
check "estado: beto ya no figura conectado" bash -c 'sleep 1; ! vpsarg sistema | grep -qE "^  beto "'
printf '2\n1\nB;ad\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: nombre inválido" has "Nombre no válido"
printf '2\n3\nbeto\nn\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: responder n no suspende" test -z "$(expire beto)"
printf '2\n3\nbeto\ns\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: suspender beto" test "$(expire beto)" = 0
check "panel: el listado muestra SUSPENDIDO" has "beto .*SUSPENDIDO"
printf '2\n4\nbeto\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: reactivar beto" test -z "$(expire beto)"
printf '2\n5\nbeto\nbetx\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: confirmación distinta no elimina" bash -c 'getent passwd beto >/dev/null'
printf '2\n5\nbeto\nbeto\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: eliminar beto" bash -c '! getent passwd beto >/dev/null'

echo "### Lo que no debe cambiar"
userdel -r externo >/dev/null 2>&1
check "no quedan cuentas de prueba" bash -c '! getent passwd ana beto carla externo >/dev/null'
check "contraseñas fuera del registro" bash -c '! journalctl -o cat | grep -qF -e "$1" -e "$2"' _ "$PW" "$PW2"
check "contraseñas fuera de /etc/vpsarg y /var/log" bash -c '! grep -rqF -e "$1" /etc/vpsarg /var/log 2>/dev/null' _ "$PW"
check "UDPGW no se reinició (PID $UG_PID0)" test "$(pid_of udpgw-7300)" = "$UG_PID0"
check "PDirect-C no se reinició (PID $PD_PID0)" test "$(pid_of pdirect-80)" = "$PD_PID0"
check "sshd_config, sshd_config.d, shells, unidades, binarios y conf de PDirect-C iguales" test "$(sums)" = "$SUMS0"

kill "$(cat /run/sshd-2223.pid)" 2>/dev/null
echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
