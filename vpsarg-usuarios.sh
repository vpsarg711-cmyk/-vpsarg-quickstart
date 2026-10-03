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
LOCK="/run/vpsarg-usuarios.lock"
SHELL_NOLOGIN="/usr/sbin/nologin"
LOG_TAG="vpsarg-panel"
NAME_RE='^[a-z_][a-z0-9_-]{0,30}$'
PASS_MIN=6
PASS_MAX=128

usage() {
  cat <<'EOF'
Uso:
  sudo vpsarg-usuarios listar
  sudo vpsarg-usuarios ver USUARIO
  sudo vpsarg-usuarios crear USUARIO        (pide la contraseña sin mostrarla)
  sudo vpsarg-usuarios suspender USUARIO    (chage -E 0 y cierra sus sesiones SSH)
  sudo vpsarg-usuarios reactivar USUARIO    (restaura el vencimiento anterior)
  sudo vpsarg-usuarios eliminar USUARIO     (cierra sus sesiones y userdel -r)
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
  elif [[ -n "$exp" ]] && ((exp < $(today))); then
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
  printf '%-20s %-7s %-22s %-8s %s\n' USUARIO UID ESTADO SESIONES VENCE
  [[ -n "$members" ]] || { echo "(no hay cuentas)"; return 0; }
  while IFS= read -r user; do
    managed "$user" || continue
    exp="$(shadow_field "$user" 8)"
    if [[ "$exp" == 0 ]]; then exp="$(saved_expiry "$user" || true)"; fi
    printf '%-20s %-7s %-22s %-8s %s\n' "$user" "$(id -u "$user")" "$(user_state "$user")" \
      "$(session_pids "$user" | wc -l)" "$(days_to_date "$exp")"
  done <<<"$members"
  echo
  echo "SESIONES = sesiones SSH autenticadas (por SSH directo, PDirect-C o HCR)."
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
  echo "Home:      $(getent passwd "$user" | cut -d: -f6)"
  echo "Shell:     $(getent passwd "$user" | cut -d: -f7)"
  pids="$(session_pids "$user" | tr '\n' ' ')"
  echo "Sesiones:  $(session_pids "$user" | wc -l)${pids:+ (PID $pids)}"
}

cmd_crear() {
  local user="$1" rc=0
  valid_name "$user" || fail crear "-" "nombre de usuario no válido (minúsculas, números, _ o -; máximo 31; empieza con letra o _)"
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
  log "accion=crear usuario=$user resultado=ok"
  echo "Cuenta $user creada (shell $SHELL_NOLOGIN, grupo $GROUP)."
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
  if [[ -n "$saved" ]] && ((saved < $(today))); then
    echo "AVISO: ese vencimiento ya pasó; la cuenta sigue sin poder entrar." >&2
  fi
}

cmd_eliminar() {
  local user="$1"
  require_managed eliminar "$user"
  close_sessions "$user" || fail eliminar "$user" "no se pudieron cerrar sus sesiones SSH; no se eliminó"
  # El aviso de "mail spool not found" es normal: estas cuentas no tienen correo.
  userdel -r "$user" 2> >(grep -v "mail spool" >&2) || fail eliminar "$user" "userdel -r falló"
  set_saved "$user"
  log "accion=eliminar usuario=$user resultado=ok"
  echo "Cuenta $user eliminada (con su directorio personal)."
}

main() {
  local action="${1:-}"
  case "$action" in
    listar) (($# == 1)) || { usage; exit 1; } ;;
    ver|crear|suspender|reactivar|eliminar) (($# == 2)) || { usage; exit 1; } ;;
    -h|--help|ayuda) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  [[ ${EUID} -eq 0 ]] || { echo "Usá sudo: sudo vpsarg-usuarios $action" >&2; exit 1; }
  exec 9>"$LOCK"
  flock -w 10 9 || { echo "ERROR: otra operación de usuarios está en curso." >&2; exit 1; }
  case "$action" in
    listar) cmd_listar ;;
    ver) cmd_ver "$2" ;;
    crear) cmd_crear "$2" ;;
    suspender) cmd_suspender "$2" ;;
    reactivar) cmd_reactivar "$2" ;;
    eliminar) cmd_eliminar "$2" ;;
  esac
}

main "$@"
