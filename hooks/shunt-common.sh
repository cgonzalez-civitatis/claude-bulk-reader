#!/usr/bin/env bash
# shunt-common.sh — resolución de estado compartida por los dos hooks.
#
# Precedencia (gana el primero):
#   1. Variables de entorno  SHUNT_OFF / SHUNT_MIN_LINES
#   2. Estado de la sesión   ~/.claude/shunt-state/<session_id>
#   3. Estado global         ~/.claude/shunt-state/global
#   4. Defaults              activo, 350 líneas
#
# El fichero de estado contiene "off" o un número de líneas.

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

  return 0   # sin esto, la condición anterior aborta un script con `set -e`
}
