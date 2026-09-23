#!/usr/bin/env bash
# shunt-common.sh — resolución de estado compartida por los dos hooks.
#
# Precedencia (gana el primero):
#   1. Variables de entorno  SHUNT_OFF / SHUNT_MIN_LINES / SHUNT_MAX_BYTES
#   2. Estado de la sesión   ~/.claude/shunt-state/<session_id>
#   3. Estado global         ~/.claude/shunt-state/global
#   4. Defaults              activo, 350 líneas o 24 KB
#
# El fichero de estado contiene "off" o un número de líneas.
# El umbral en bytes solo se ajusta por entorno: existe para los ficheros de
# pocas líneas muy largas (Markdown de planes), que el de líneas no ve.

SHUNT_STATE_DIR="${SHUNT_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/shunt-state}"

# Agentes exentos: los que SON el destinatario de la delegación. Bloquearles no
# les hace delegar (no tienen a quién), solo les hace trocear el fichero, que
# cuesta más que leerlo entero. Su contexto además se destruye al terminar.
# Los subagentes "trabajadores" NO van aquí: su contexto les dura toda la tarea
# y sí pueden delegar, así que el shunt les sirve igual que a la sesión principal.
SHUNT_EXEMPT_AGENTS="${SHUNT_EXEMPT_AGENTS:-bulk-reader}"

# shunt_agent_exempt <agent_type> -> 0 si está exento
shunt_agent_exempt() {
  local t="${1:-}" a
  [[ -z "$t" ]] && return 1          # sin agent_type = sesión principal
  local IFS=,
  for a in $SHUNT_EXEMPT_AGENTS; do
    [[ "${a// /}" == "$t" ]] && return 0
  done
  return 1
}

# shunt_resolve <session_id> -> exporta SHUNT_ACTIVE (0/1) y MIN_LINES
shunt_resolve() {
  local sid="${1:-}" state=""
  MIN_LINES=350
  MAX_BYTES=24576
  SHUNT_ACTIVE=1

  # 3. global, luego 2. sesión (la sesión pisa al global)
  [[ -r "$SHUNT_STATE_DIR/global" ]] && state=$(<"$SHUNT_STATE_DIR/global")
  if [[ -n "$sid" && -r "$SHUNT_STATE_DIR/$sid" ]]; then
    state=$(<"$SHUNT_STATE_DIR/$sid")
  fi
  state="${state//[[:space:]]/}"

  case "$state" in
    off)         SHUNT_ACTIVE=0 ;;
    on|"")       ;;
    *[!0-9]*)    ;;                       # basura: ignorar
    *)           MIN_LINES="$state" ;;
  esac

  # 1. el entorno manda sobre todo
  [[ "${SHUNT_OFF:-0}" == "1" ]] && SHUNT_ACTIVE=0
  [[ -n "${SHUNT_MIN_LINES:-}" ]] && MIN_LINES="$SHUNT_MIN_LINES"
  [[ -n "${SHUNT_MAX_BYTES:-}" ]] && MAX_BYTES="$SHUNT_MAX_BYTES"

  return 0   # sin esto, la condición anterior aborta un script con `set -e`
}

# shunt_file_over <path> -> 0 si supera algún umbral; deja FILE_LINES, FILE_BYTES
shunt_file_over() {
  FILE_LINES=$(wc -l < "$1" 2>/dev/null || echo 0)
  FILE_BYTES=$(wc -c < "$1" 2>/dev/null || echo 0)
  (( FILE_LINES > MIN_LINES || FILE_BYTES > MAX_BYTES ))
}

# Texto de umbral para los mensajes de bloqueo.
shunt_limits() { echo "${MIN_LINES} líneas o $(( MAX_BYTES / 1024 )) KB"; }
