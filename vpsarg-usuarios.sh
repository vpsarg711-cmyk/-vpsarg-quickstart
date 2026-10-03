#!/usr/bin/env bash
# VPS ARG QuickStart - cuentas SSH de los usuarios finales
# Las cuentas son usuarios Linux normales (usuario + contraseña SSH) del grupo
# vpsarg-usuarios. Solo se administran las cuentas de ese grupo con UID >= 1000.
# No modifica /etc/ssh/sshd_config ni /etc/shells. Las contraseñas nunca se
# muestran, no van en la línea de comandos y no se registran.
set -Eeuo pipefail

GROUP="vpsarg-usuarios"
STATE_DIR="/etc/vpsarg"
SUSPENDED="$STATE_DIR/usuarios-suspendidos"   # usuario:vencimiento_anterior
LIMITS="$STATE_DIR/limites"                    # usuario:máximo de conexiones (0 = sin límite)
LOCK="/run/vpsarg-usuarios.lock"
SHELL_NOLOGIN="/usr/sbin/nologin"
LOG_TAG="vpsarg-panel"
NAME_RE='^[a-z_][a-z0-9_-]{0,30}$'
PASS_MIN=6
PASS_MAX=128
DAYS_MAX=3650
LIMIT_DEFAULT=1
LIMIT_MAX=99

usage() {
  cat <<'EOF'
Uso:
  sudo vpsarg-usuarios listar
  sudo vpsarg-usuarios ver USUARIO
  sudo vpsarg-usuarios crear USUARIO [DÍAS] [LÍMITE]
                                            (pide la contraseña sin mostrarla; sin DÍAS no vence;
                                             LÍMITE por defecto 1, 0 = sin límite)
  sudo vpsarg-usuarios renovar USUARIO DÍAS  (suma DÍAS desde hoy o desde el vencimiento, el mayor)
  sudo vpsarg-usuarios vencimiento USUARIO AAAA-MM-DD|nunca
  sudo vpsarg-usuarios clave USUARIO        (cambia la contraseña; pide la nueva sin mostrarla)
  sudo vpsarg-usuarios limite USUARIO [N]   (muestra o cambia el máximo de conexiones; 0 = sin límite)
  sudo vpsarg-usuarios suspender USUARIO    (chage -E 0 y cierra sus sesiones SSH)
  sudo vpsarg-usuarios reactivar USUARIO    (restaura el vencimiento anterior)
  sudo vpsarg-usuarios eliminar USUARIO     (cierra sus sesiones y userdel -r)

Vencimiento: la cuenta no puede entrar desde el día indicado (inclusive). Las sesiones ya
abiertas siguen hasta que se desconecten. El límite se guarda pero todavía no se aplica.
EOF
}

log() {
  logger -t "$LOG_TAG" -- "admin=${SUDO_USER:-root} $*" 2>/dev/null || true
}

# fail ACCIÓN USUARIO MENSAJE: registra el error y termina.
fail() {
  log "accion=$1 usuario=$2 resultado=error motivo=\"$3\""
  echo "ERROR: $3" >&2
  exit 1
}

valid_name() {
  [[ "$1" =~ $NAME_RE ]]
}

# Cuenta administrada: existe, UID >= 1000 (no nobody) y es del grupo.
managed() {
  local uid
  uid="$(getent passwd "$1" | cut -d: -f3)" || return 1
  [[ "$uid" =~ ^[0-9]+$ ]] && ((uid >= 1000 && uid != 65534)) || return 1
  id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUP"
}

require_managed() {
  local action="$1" user="$2"
  valid_name "$user" || fail "$action" "-" "nombre de usuario no válido"
  getent passwd "$user" >/dev/null || fail "$action" "$user" "el usuario $user no existe"
  managed "$user" || fail "$action" "$user" "$user no es una cuenta administrada por VPS ARG (grupo $GROUP)"
}

shadow_field() {
  getent shadow "$1" | cut -d: -f"$2"
}

today() {
  echo $(( $(date +%s) / 86400 ))
}

# ACTIVO, SUSPENDIDO, VENCIDO o CONTRASEÑA BLOQUEADA.
user_state() {
  local exp pw
  exp="$(shadow_field "$1" 8)"
  pw="$(shadow_field "$1" 2)"
  if [[ "$exp" == 0 ]]; then
    echo "SUSPENDIDO"
  elif [[ -n "$exp" ]] && ((exp <= $(today))); then
    echo "VENCIDO"
  elif [[ "$pw" == '!'* || "$pw" == '*'* ]]; then
    echo "CONTRASEÑA BLOQUEADA"
  else
    echo "ACTIVO"
  fi
}

days_to_date() {
  if [[ -z "$1" ]]; then echo "nunca"; else date -u -d "@$(( $1 * 86400 ))" +%F; fi
}

# PIDs de las sesiones SSH autenticadas del usuario: procesos sshd con su UID.
session_pids() {
  local uid
  uid="$(id -u "$1")"
  { ps -o pid=,comm= -u "$uid" 2>/dev/null || true; } | awk '$2=="sshd" || $2=="sshd-session" {print $1}'
}

# Cierra las sesiones con SIGTERM y espera hasta 5 s. Devuelve 1 si queda alguna.
close_sessions() {
  local user="$1" pids _
  mapfile -t pids < <(session_pids "$user")
  ((${#pids[@]})) || return 0
  kill -TERM "${pids[@]}" 2>/dev/null || true
  for _ in $(seq 10); do
    [[ -z "$(session_pids "$user")" ]] && { echo "Sesiones SSH cerradas: ${#pids[@]}."; return 0; }
    sleep 0.5
  done
  return 1
}

saved_expiry() {
  [[ -r "$SUSPENDED" ]] || return 1
  grep -m1 "^$1:" "$SUSPENDED" | cut -d: -f2
}

# set_saved USUARIO [VALOR]: guarda (o borra, sin VALOR) el vencimiento anterior.
set_saved() {
  local tmp
  install -d -m 0700 "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/.usuarios.XXXXXX")"
  if [[ -r "$SUSPENDED" ]]; then grep -v "^$1:" "$SUSPENDED" > "$tmp" || true; fi
  (($# == 2)) && printf '%s:%s\n' "$1" "$2" >> "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$SUSPENDED"
}

# get_limit USUARIO: máximo guardado; vacío si no tiene (cuentas anteriores a 3B = sin límite).
get_limit() {
  [[ -r "$LIMITS" ]] || return 0
  sed -n "s/^$1:\([0-9]*\)$/\1/p" "$LIMITS" | tail -n 1
}

# set_limit USUARIO [N]: guarda (o borra, sin N) el máximo de conexiones.
set_limit() {
  local tmp
  install -d -m 0700 "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/.limites.XXXXXX")"
  if [[ -r "$LIMITS" ]]; then grep -v "^$1:" "$LIMITS" > "$tmp" || true; fi
  (($# == 2)) && printf '%s:%s\n' "$1" "$2" >> "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$LIMITS"
}

limit_text() {
  local l
  l="$(get_limit "$1")"
  if [[ -z "$l" || "$l" == 0 ]]; then echo "sin límite"; else echo "$l"; fi
}

valid_days() {
  [[ "$1" =~ ^[1-9][0-9]{0,3}$ ]] && (($1 <= DAYS_MAX))
}

valid_limit() {
  [[ "$1" =~ ^(0|[1-9][0-9]?)$ ]] && (($1 <= LIMIT_MAX))
}

# Días desde 1970 de una fecha AAAA-MM-DD válida (UTC, como /etc/shadow).
date_to_days() {
  local secs
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  secs="$(date -u -d "$1" +%s 2>/dev/null)" || return 1
  [[ "$(date -u -d "@$secs" +%F)" == "$1" ]] || return 1
  echo $((secs / 86400))
}

# Espera a que no quede ningún proceso del UID. Si solo queda el administrador de
# sesión de systemd de esa cuenta (user@UID.service), lo detiene: es exclusivo de la
# cuenta y sigue vivo unos segundos después de cerrar la última sesión.
release_uid() {
  local uid="$1" i
  for i in $(seq 20); do
    pgrep -u "$uid" >/dev/null 2>&1 || return 0
    if ((i == 4)) && systemctl is-active --quiet "user@$uid.service" 2>/dev/null; then
      systemctl stop "user@$uid.service" 2>/dev/null || true
    fi
    sleep 0.5
  done
  ! pgrep -u "$uid" >/dev/null 2>&1
}

ssh_password_note() {
  local pa
  pa="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
  case "$pa" in
    yes) ;;
    no) echo "AVISO: SSH no acepta contraseñas (PasswordAuthentication no). La cuenta no podrá entrar con usuario y contraseña hasta que el administrador lo cambie; este programa no modifica sshd_config." >&2 ;;
    *) echo "AVISO: no se pudo leer la configuración de SSH (sshd -T)." >&2 ;;
  esac
}

read_password() {
  # Deja la contraseña en PASS. Con terminal la pide dos veces sin eco.
  local again
  PASS=""
  if [[ -t 0 ]]; then
    read -r -s -p "Contraseña: " PASS || PASS=""; echo >&2
    read -r -s -p "Repetila: " again || again=""; echo >&2
    [[ "$PASS" == "$again" ]] || { PASS=""; return 2; }
  else
    IFS= read -r PASS || [[ -n "$PASS" ]] || return 1
  fi
  ((${#PASS} >= PASS_MIN && ${#PASS} <= PASS_MAX)) || return 1
  [[ "$PASS" != *[[:cntrl:]]* && "$PASS" != *:* ]] || return 1
}

# ------------------------------------------------------------------ acciones
cmd_listar() {
  local members user exp
  members="$(getent group "$GROUP" | cut -d: -f4 | tr ',' '\n' | sort || true)"
  printf '%-20s %-7s %-22s %-11s %-8s %s\n' USUARIO UID ESTADO LÍMITE SESIONES VENCE
  [[ -n "$members" ]] || { echo "(no hay cuentas)"; return 0; }
  while IFS= read -r user; do
    managed "$user" || continue
    exp="$(shadow_field "$user" 8)"
    if [[ "$exp" == 0 ]]; then exp="$(saved_expiry "$user" || true)"; fi
    printf '%-20s %-7s %-22s %-11s %-8s %s\n' "$user" "$(id -u "$user")" "$(user_state "$user")" \
      "$(limit_text "$user" | sed 's/sin límite/-/')" "$(session_pids "$user" | wc -l)" "$(days_to_date "$exp")"
  done <<<"$members"
  echo
  echo "SESIONES = sesiones SSH autenticadas (por SSH directo, PDirect-C o HCR)."
  echo "LÍMITE = máximo de conexiones guardado (- = sin límite); todavía no se aplica."
  echo "VENCE = desde ese día la cuenta no puede entrar. El consumo todavía no se mide."
}

cmd_ver() {
  local user="$1" exp saved pids
  require_managed ver "$user"
  exp="$(shadow_field "$user" 8)"
  echo "Usuario:   $user (UID $(id -u "$user"))"
  echo "Estado:    $(user_state "$user")"
  if [[ "$exp" == 0 ]]; then
    saved="$(saved_expiry "$user" || true)"
    echo "Vence:     suspendida (al reactivar: $(days_to_date "$saved"))"
  else
    echo "Vence:     $(days_to_date "$exp")"
  fi
  echo "Límite:    $(limit_text "$user") (todavía no se aplica)"
  echo "Home:      $(getent passwd "$user" | cut -d: -f6)"
  echo "Shell:     $(getent passwd "$user" | cut -d: -f7)"
  pids="$(session_pids "$user" | tr '\n' ' ')"
  echo "Sesiones:  $(session_pids "$user" | wc -l)${pids:+ (PID $pids)}"
}

cmd_crear() {
  local user="$1" days="${2:-}" limit="${3:-$LIMIT_DEFAULT}" rc=0 exp=""
  valid_name "$user" || fail crear "-" "nombre de usuario no válido (minúsculas, números, _ o -; máximo 31; empieza con letra o _)"
  if [[ -n "$days" ]]; then
    valid_days "$days" || fail crear "$user" "días no válidos (1 a $DAYS_MAX)"
    exp=$(( $(today) + days ))
  fi
  valid_limit "$limit" || fail crear "$user" "límite no válido (0 a $LIMIT_MAX; 0 = sin límite)"
  getent passwd "$user" >/dev/null && fail crear "$user" "el usuario $user ya existe"
  getent group "$user" >/dev/null && fail crear "$user" "ya existe un grupo llamado $user"
  [[ -x "$SHELL_NOLOGIN" ]] || fail crear "$user" "no existe $SHELL_NOLOGIN"
  ssh_password_note
  read_password || rc=$?
  if ((rc == 2)); then fail crear "$user" "las contraseñas no coinciden"; fi
  if ((rc != 0)); then fail crear "$user" "contraseña no válida ($PASS_MIN a $PASS_MAX caracteres, sin ':' ni caracteres de control)"; fi
  if ! getent group "$GROUP" >/dev/null; then
    groupadd --system "$GROUP" || fail crear "$user" "no se pudo crear el grupo $GROUP"
    log "accion=crear-grupo grupo=$GROUP resultado=ok"
  fi
  if ! useradd -m -k /dev/null -s "$SHELL_NOLOGIN" -G "$GROUP" "$user"; then
    PASS=""
    fail crear "$user" "useradd falló"
  fi
  # La contraseña va por la entrada estándar de chpasswd (printf es interno de bash).
  if ! printf '%s:%s\n' "$user" "$PASS" | chpasswd; then
    PASS=""
    userdel -r "$user" >/dev/null 2>&1 || true
    fail crear "$user" "chpasswd falló; se eliminó la cuenta a medio crear"
  fi
  PASS=""
  if [[ -n "$exp" ]] && ! chage -E "$exp" "$user"; then
    userdel -r "$user" >/dev/null 2>&1 || true
    fail crear "$user" "chage -E falló; se eliminó la cuenta a medio crear"
  fi
  set_limit "$user" "$limit"
  log "accion=crear usuario=$user resultado=ok vence=$(days_to_date "$exp") limite=$limit"
  echo "Cuenta $user creada (shell $SHELL_NOLOGIN, grupo $GROUP)."
  echo "Vence: $(days_to_date "$exp") · Límite: $(limit_text "$user")."
}

# set_expiry ACCIÓN USUARIO DÍAS_DESDE_1970|"": aplica el vencimiento, o lo guarda si está suspendida.
set_expiry() {
  local action="$1" user="$2" new="$3"
  if [[ "$(shadow_field "$user" 8)" == 0 ]]; then
    set_saved "$user" "$new"
    log "accion=$action usuario=$user resultado=ok vence=$(days_to_date "$new") suspendida=si"
    echo "$user sigue suspendida. Al reactivarla vencerá: $(days_to_date "$new")."
  else
    chage -E "${new:--1}" "$user" || fail "$action" "$user" "chage -E falló"
    log "accion=$action usuario=$user resultado=ok vence=$(days_to_date "$new")"
    echo "$user vence: $(days_to_date "$new")."
  fi
}

cmd_renovar() {
  local user="$1" days="$2" cur base
  require_managed renovar "$user"
  valid_days "$days" || fail renovar "$user" "días no válidos (1 a $DAYS_MAX)"
  cur="$(shadow_field "$user" 8)"
  [[ "$cur" == 0 ]] && cur="$(saved_expiry "$user" || true)"
  base="$(today)"
  [[ -n "$cur" ]] && ((cur > base)) && base="$cur"
  set_expiry renovar "$user" $((base + days))
}

cmd_vencimiento() {
  local user="$1" when="$2" new=""
  require_managed vencimiento "$user"
  if [[ "$when" != nunca ]]; then
    new="$(date_to_days "$when")" || fail vencimiento "$user" "fecha no válida (AAAA-MM-DD o nunca)"
    ((new > $(today))) || fail vencimiento "$user" "la fecha tiene que ser posterior a hoy (para cortar el acceso, suspendé la cuenta)"
  fi
  set_expiry vencimiento "$user" "$new"
}

cmd_clave() {
  local user="$1" rc=0
  require_managed clave "$user"
  ssh_password_note
  read_password || rc=$?
  if ((rc == 2)); then fail clave "$user" "las contraseñas no coinciden"; fi
  if ((rc != 0)); then fail clave "$user" "contraseña no válida ($PASS_MIN a $PASS_MAX caracteres, sin ':' ni caracteres de control)"; fi
  if ! printf '%s:%s\n' "$user" "$PASS" | chpasswd; then
    PASS=""
    fail clave "$user" "chpasswd falló; la contraseña no cambió"
  fi
  PASS=""
  log "accion=clave usuario=$user resultado=ok"
  echo "Contraseña de $user cambiada. Las sesiones abiertas siguen."
}

cmd_limite() {
  local user="$1" limit="${2:-}"
  require_managed limite "$user"
  if [[ -z "$limit" ]]; then
    echo "$user: límite $(limit_text "$user"), sesiones actuales $(session_pids "$user" | wc -l)."
    return 0
  fi
  valid_limit "$limit" || fail limite "$user" "límite no válido (0 a $LIMIT_MAX; 0 = sin límite)"
  set_limit "$user" "$limit"
  log "accion=limite usuario=$user resultado=ok limite=$limit"
  echo "$user: límite $(limit_text "$user"). No se cierra ninguna sesión abierta."
}

cmd_suspender() {
  local user="$1" exp
  require_managed suspender "$user"
  exp="$(shadow_field "$user" 8)"
  if [[ "$exp" == 0 ]]; then
    log "accion=suspender usuario=$user resultado=sin-cambios motivo=\"ya estaba suspendida\""
    echo "$user ya estaba suspendida. Sin cambios."
  else
    set_saved "$user" "$exp"
    if ! chage -E 0 "$user"; then
      set_saved "$user"
      fail suspender "$user" "chage -E 0 falló"
    fi
    log "accion=suspender usuario=$user resultado=ok vencimiento_anterior=$(days_to_date "$exp")"
    echo "$user suspendida (chage -E 0). Vencimiento anterior guardado: $(days_to_date "$exp")."
  fi
  if ! close_sessions "$user"; then
    fail suspender "$user" "la cuenta quedó suspendida pero siguen sesiones abiertas (PID $(session_pids "$user" | tr '\n' ' '))"
  fi
}

cmd_reactivar() {
  local user="$1" exp saved
  require_managed reactivar "$user"
  exp="$(shadow_field "$user" 8)"
  if [[ "$exp" != 0 ]]; then
    log "accion=reactivar usuario=$user resultado=sin-cambios motivo=\"no estaba suspendida\""
    echo "$user no estaba suspendida. Sin cambios."
    return 0
  fi
  if ! saved="$(saved_expiry "$user")"; then
    saved=""
    echo "AVISO: no hay vencimiento guardado para $user (no se suspendió desde VPS ARG); queda sin vencimiento." >&2
  fi
  chage -E "${saved:--1}" "$user" || fail reactivar "$user" "chage -E falló"
  set_saved "$user"
  log "accion=reactivar usuario=$user resultado=ok vencimiento=$(days_to_date "$saved")"
  echo "$user reactivada. Vence: $(days_to_date "$saved")."
  if [[ -n "$saved" ]] && ((saved <= $(today))); then
    echo "AVISO: ese vencimiento ya pasó; la cuenta sigue sin poder entrar." >&2
  fi
}

cmd_eliminar() {
  local user="$1"
  require_managed eliminar "$user"
  close_sessions "$user" || fail eliminar "$user" "no se pudieron cerrar sus sesiones SSH; no se eliminó"
  release_uid "$(id -u "$user")" \
    || fail eliminar "$user" "siguen procesos de la cuenta (PID $(pgrep -u "$(id -u "$user")" | tr '\n' ' ')); no se eliminó"
  # El aviso de "mail spool not found" es normal: estas cuentas no tienen correo.
  userdel -r "$user" 2> >(grep -v "mail spool" >&2) || fail eliminar "$user" "userdel -r falló"
  set_saved "$user"
  set_limit "$user"
  log "accion=eliminar usuario=$user resultado=ok"
  echo "Cuenta $user eliminada (con su directorio personal)."
}

main() {
  local action="${1:-}"
  case "$action" in
    listar) (($# == 1)) || { usage; exit 1; } ;;
    ver|suspender|reactivar|eliminar|clave) (($# == 2)) || { usage; exit 1; } ;;
    crear) (($# >= 2 && $# <= 4)) || { usage; exit 1; } ;;
    limite) (($# == 2 || $# == 3)) || { usage; exit 1; } ;;
    renovar|vencimiento) (($# == 3)) || { usage; exit 1; } ;;
    -h|--help|ayuda) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  [[ ${EUID} -eq 0 ]] || { echo "Usá sudo: sudo vpsarg-usuarios $action" >&2; exit 1; }
  exec 9>"$LOCK"
  flock -w 10 9 || { echo "ERROR: otra operación de usuarios está en curso." >&2; exit 1; }
  case "$action" in
    listar) cmd_listar ;;
    ver) cmd_ver "$2" ;;
    crear) cmd_crear "$2" "${3:-}" "${4:-}" ;;
    renovar) cmd_renovar "$2" "$3" ;;
    vencimiento) cmd_vencimiento "$2" "$3" ;;
    clave) cmd_clave "$2" ;;
    limite) cmd_limite "$2" "${3:-}" ;;
    suspender) cmd_suspender "$2" ;;
    reactivar) cmd_reactivar "$2" ;;
    eliminar) cmd_eliminar "$2" ;;
  esac
}

main "$@"
