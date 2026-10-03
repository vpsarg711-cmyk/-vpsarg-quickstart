#!/usr/bin/env bash
# Pruebas de laboratorio del panel vpsarg (Fase 2B).
# SOLO para una máquina o contenedor de laboratorio con QuickStart instalado y HCR
# sin instalar: inicia un sshd extra en 127.0.0.1:2222, instala y desinstala HCR
# y maneja el menú enviándole respuestas por la entrada estándar.
# No reinicia UDPGW ni toca sshd_config: ambos se verifican al final.
# Uso: sudo bash tests/prueba-panel.sh /ruta/al/hcr-server
# shellcheck disable=SC2016
set -uo pipefail

SRC="${1:?Uso: sudo bash tests/prueba-panel.sh /ruta/al/hcr-server}"
OUT=/tmp/panel.out
PASS=0
FAILS=0

ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
listening() { [[ -n "$(ss -Hltn "sport = :$1")" ]]; }
pid_of() { systemctl show -p MainPID --value "$1"; }
hcr_arg() { tr '\0' '\n' < "/proc/$(pid_of hcr-8880)/cmdline" | grep -A1 -x -- "$1" | tail -n 1; }
pd_port() { tr '\0' '\n' < "/proc/$(pid_of pdirect-80)/cmdline" | sed -n 2p; }
# Maneja el menú: panel "respuestas separadas por \n". Termina cuando se acaba la entrada.
panel() { printf "%b" "$1" | timeout 60 vpsarg > "$OUT" 2>&1; }
has() { grep -q -- "$1" "$OUT"; }
state_line() { vpsarg estado | grep -- "$1" | awk '{print $2, $3}'; }
journal_has() { journalctl -t vpsarg-panel -o cat | grep -q -- "$1"; }
sums() {
  sha256sum /etc/ssh/sshd_config /etc/passwd /etc/shells /etc/vpsarg-pdirect.conf \
    /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service \
    /usr/local/bin/pdirect-c /opt/badvpn/badvpn-udpgw
  find /etc/ssh/sshd_config.d -type f -exec sha256sum {} + 2>/dev/null
}

echo "### Preparación"
install -d -m 0755 /opt/hcr
install -o root -g root -m 0755 "$SRC" /opt/hcr/hcr-server
mkdir -p /run/sshd
/usr/sbin/sshd -p 2222 -o PidFile=/run/sshd-2222.pid
sleep 1
SUMS0="$(sums)"
UG_PID0="$(pid_of udpgw-7300)"
UG_EXEC0="$(systemctl show -p ExecStart --value udpgw-7300 | sed 's/ ; pid=.*//; s/start_time=.*//')"
check "panel instalado en /usr/local/sbin/vpsarg" test -x /usr/local/sbin/vpsarg
check "HCR no instalado al empezar" bash -c '! systemctl cat hcr-8880 >/dev/null 2>&1'

echo "### Vistas sin cambios"
check "sin sudo se niega" bash -c '! setpriv --reuid=65534 --regid=65534 --clear-groups /usr/local/sbin/vpsarg estado >/dev/null 2>&1'
check "subcomando desconocido falla" bash -c '! vpsarg borrar >/dev/null 2>&1'
check "PDirect-C ACTIVO" test "$(state_line PDirect-C)" = "ACTIVO 80"
check "UDPGW ACTIVO" test "$(state_line UDPGW)" = "UDPGW ACTIVO"
check "HCR NO INSTALADO" bash -c 'vpsarg estado | grep "^HCR" | grep -q "NO INSTALADO"'
check "sin colores fuera de una terminal" bash -c '! vpsarg estado | grep -q $'"'"'\e'"'"''
check "puertos: sshd 22 y PDirect-C -> 22" bash -c 'o="$(vpsarg puertos)"; grep -q "sshd, solo lectura) *22" <<<"$o" && grep -q "TCP 80 -> 127.0.0.1:22" <<<"$o"'
check "puertos: 80 y 7300 en escucha" bash -c 'o="$(vpsarg puertos)"; grep -q "TCP 80: sí" <<<"$o" && grep -q "TCP 7300: sí" <<<"$o"'
check "conexiones: UDPGW muestra --max-clients 3 como conexiones TCP" \
  bash -c 'vpsarg conexiones | grep "^BadVPN UDPGW" | grep -q "max-clients: 3 conexiones TCP"'
check "conexiones: no presenta límites como usuarios" bash -c '! vpsarg conexiones | grep -i "usuario" | grep -qv "no usuarios"'
check "conexiones: cuenta una conexión TCP abierta al 7300" \
  bash -c 'exec 3<>/dev/tcp/127.0.0.1/7300; sleep 0.5; vpsarg conexiones | grep "^BadVPN UDPGW" | grep -q " 7300 *1 "'
check "recursos: muestra PDirect-C y UDPGW con su PID" \
  bash -c 'o="$(vpsarg recursos)"; grep -q "^PDirect-C *$(systemctl show -p MainPID --value pdirect-80) " <<<"$o" && grep -q "^BadVPN UDPGW *$(systemctl show -p MainPID --value udpgw-7300) " <<<"$o"'
check "ssh: informa PasswordAuthentication según sshd -T" \
  bash -c 'pa="$(sshd -T | awk '"'"'$1=="passwordauthentication"{print $2}'"'"')"; vpsarg ssh | grep -q "PasswordAuthentication $pa"'
panel "3\n\n6\n\n0\n"
check "Usuarios SSH y Ancho de banda figuran como pendientes" bash -c '[[ $(grep -c "^Pendiente" '"$OUT"') == 2 ]]'
check "el menú termina al cerrarse la entrada" bash -c 'printf "" | timeout 10 vpsarg >/dev/null 2>&1'

echo "### Entradas inválidas"
panel "abc\n9\n;id\n2\n1\n80; touch /tmp/inyectado\n\n1\n\$(touch /tmp/inyectado)\n\n1\n99999\n\n1\n-1\n\n0\n0\n"
check "rechaza puertos SSH inválidos (4 intentos)" test "$(grep -c "Puerto no válido" "$OUT")" = 4
check "rechaza opciones de menú inválidas" has "Opción inválida"
check "nada se ejecutó desde la entrada" test ! -e /tmp/inyectado
check "PDirect-C sigue en 22" test "$(pd_port)" = 22
panel "2\n2\n0\n0\n"
check "cambiar puerto de HCR sin HCR instalado lo informa" has "HCR no está instalado"

echo "### HCR desde el panel"
panel "4\n1\nn\n\n0\n0\n"
check "responder n no instala" bash -c '! systemctl cat hcr-8880 >/dev/null 2>&1'
check "el menú HCR avisa que no está validado para producción" has "no está validado para producción"
panel "4\n1\ns\n\n0\n0\n"
check "instalar HCR" systemctl is-active --quiet hcr-8880
check "HCR ACTIVO en 8880" test "$(state_line '^HCR')" = "ACTIVO 8880"
check "registro: instalar ok" journal_has "accion=instalar servicio=hcr-8880 resultado=ok"
check "HCR sin root" test "$(ps -o uid= -p "$(pid_of hcr-8880)" | tr -d ' ')" != 0
check "HCR 32/16" bash -c '[[ "$(tr "\0" " " < /proc/$(systemctl show -p MainPID --value hcr-8880)/cmdline)" == *"-max-sessions 32 -max-sessions-per-ip 16"* ]]'
check "conexiones: HCR límite 2048 conexiones TCP" bash -c 'vpsarg conexiones | grep "^HCR" | grep -q "límite: 2048 conexiones TCP"'

echo "### Servicios"
P1="$(pid_of hcr-8880)"
panel "1\n2\n3\nn\n0\n0\n"
check "responder n a detener no detiene" test "$(pid_of hcr-8880)" = "$P1"
panel "1\n2\n3\ns\n\n0\n0\n"
check "detener HCR" bash -c '! systemctl is-active --quiet hcr-8880'
check "estado DETENIDO" test "$(state_line '^HCR')" = "DETENIDO 8880"
check "registro: detener ok" journal_has "accion=detener servicio=hcr-8880 resultado=ok"
panel "1\n1\n3\n\n0\n0\n"
check "iniciar HCR" systemctl is-active --quiet hcr-8880
P2="$(pid_of hcr-8880)"
panel "1\n3\n3\ns\n\n0\n0\n"
check "reiniciar HCR cambia el PID" bash -c "[[ \"\$(systemctl show -p MainPID --value hcr-8880)\" != $P2 ]]"
panel "1\n5\n3\ns\n\n0\n0\n"
check "deshabilitar HCR" bash -c '! systemctl is-enabled --quiet hcr-8880'
panel "1\n4\n3\n\n0\n0\n"
check "habilitar HCR" bash -c 'systemctl is-enabled --quiet hcr-8880 && systemctl is-active --quiet hcr-8880'
check "servicio fuera de rango no hace nada" bash -c 'printf "1\n2\n7\n0\n0\n" | timeout 30 vpsarg >/dev/null 2>&1; systemctl is-active --quiet hcr-8880'

echo "### Puertos"
panel "2\n2\n8080\ns\n\n0\n0\n"
check "cambiar HCR a 8080" bash -c 'ss -Hltn "sport = :8080" | grep -q . && ! ss -Hltn "sport = :8880" | grep -q .'
check "registro: puerto-hcr 8080 ok" journal_has "accion=puerto-hcr valor=8080 resultado=ok"
panel "2\n2\n80\ns\n\n0\n0\n"
check "HCR en 80 se rechaza y queda en 8080" bash -c 'grep -qx HCR_PORT=8080 /etc/vpsarg-hcr.conf && ss -Hltn "sport = :8080" | grep -q .'
check "registro: el rechazo queda como error" journal_has "accion=puerto-hcr valor=80 resultado=error"
panel "2\n2\n8880\ns\n\n0\n0\n"
check "HCR vuelve a 8880" listening 8880
panel "2\n1\n2222\ns\n\n0\n0\n"
check "puerto-ssh 2222: PDirect-C" test "$(pd_port)" = 2222
check "puerto-ssh 2222: HCR" test "$(hcr_arg -target)" = 127.0.0.1:2222
check "puertos avisa que sshd no escucha en 2222 según su configuración" bash -c 'vpsarg puertos | grep -q "AVISO: PDirect-C apunta a 2222"'
panel "2\n1\n22\ns\n\n0\n0\n"
check "puerto-ssh 22: PDirect-C y HCR" bash -c "[[ \"\$(tr '\\0' '\\n' < /proc/\$(systemctl show -p MainPID --value pdirect-80)/cmdline | sed -n 2p)\" == 22 ]] && grep -qx HCR_SSH_PORT=22 /etc/vpsarg-hcr.conf"
check "registro: puerto-ssh ok" journal_has "accion=puerto-ssh valor=22 resultado=ok"

echo "### Diagnóstico"
panel "5\n1\n\n2\n\n3\n\n5\n\n6\n\n0\n0\n"
check "conexiones, recursos y SSH desde el menú" bash -c 'grep -q "CONEXIONES TCP ESTABLECIDAS" '"$OUT"' && grep -q "DESCRIPTORES" '"$OUT"' && grep -q "PasswordAuthentication" '"$OUT"''
B="$(find /var/backups/vpsarg -maxdepth 1 -name '*-panel' | sort | tail -n 1)"
check "copia de configuración creada" test -n "$B"
check "la copia incluye confs y unidades" bash -c "for f in vpsarg-pdirect.conf vpsarg-hcr.conf vpsarg-servicios.conf pdirect-80.service udpgw-7300.service hcr-8880.service; do test -f '$B/'\$f || exit 1; done"
check "la copia es privada (0700)" test "$(stat -c %a "$B")" = 700

echo "### Desinstalar HCR desde el panel"
panel "4\n2\ns\n\n0\n0\n"
check "desinstalar HCR" bash -c '! systemctl cat hcr-8880 >/dev/null 2>&1 && ! test -e /etc/vpsarg-hcr.conf'
check "HCR NO INSTALADO otra vez" bash -c 'vpsarg estado | grep "^HCR" | grep -q "NO INSTALADO"'

echo "### Lo que no debe cambiar"
check "UDPGW no se reinició (PID $UG_PID0)" test "$(pid_of udpgw-7300)" = "$UG_PID0"
check "ExecStart de UDPGW igual" test "$(systemctl show -p ExecStart --value udpgw-7300 | sed 's/ ; pid=.*//; s/start_time=.*//')" = "$UG_EXEC0"
check "sshd_config, sshd_config.d, passwd, shells, unidades, binarios y conf de PDirect-C iguales" test "$(sums)" = "$SUMS0"
check "no quedan procesos del panel" bash -c '! pgrep -f /usr/local/sbin/vpsarg\$ >/dev/null'
check "PDirect-C sigue en 80 y llega a SSH" bash -c 'timeout 6 bash -c '"'"'exec 3<>/dev/tcp/127.0.0.1/80 || exit 1; printf "GET / HTTP/1.1\r\nHost: x\r\n\r\n" >&3; for _ in 1 2 3 4 5 6 7 8; do IFS= read -r -t 4 l <&3 || exit 1; [[ "$l" == SSH-* ]] && exit 0; done; exit 1'"'"''
check "el registro del panel no tiene contraseñas" bash -c '! journalctl -t vpsarg-panel -o cat | grep -qi "pass\|contraseña"'

kill "$(cat /run/sshd-2222.pid)" 2>/dev/null
echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
