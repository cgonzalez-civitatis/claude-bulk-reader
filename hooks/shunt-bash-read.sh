#!/usr/bin/env bash
# shunt-bash-read.sh — Claude Code PreToolUse/Bash hook
# Complementa a shunt-file-size.sh: intercepta volcados de archivos grandes
# hechos por shell (cat/head/tail/sed -n/nl/bat) en lugar de por la tool Read.
#
# Filosofía: bloquear SOLO el volcado íntegro al contexto. Todo lo que ya viene
# acotado o filtrado (pipe, redirección, head -50, sed -n '10,60p') pasa.
# Reads stdin JSON from Claude Code hook framework.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shunt-common.sh
. "$SCRIPT_DIR/shunt-common.sh"

# Consumimos stdin siempre y primero: salir antes de leerlo provoca SIGPIPE
# en el proceso que nos escribe el payload.
input=$(cat)

shunt_agent_exempt "$(echo "$input" | jq -r '.agent_type // ""')" && exit 0

shunt_resolve "$(echo "$input" | jq -r '.session_id // ""')"
(( SHUNT_ACTIVE )) || exit 0

command=$(echo "$input" | jq -r '.tool_input.command // ""')
[[ -z "$command" ]] && exit 0

# Heredoc => es escritura (cat > f <<EOF), no lectura.
echo "$command" | grep -qP '<<' && exit 0
# Redirección a archivo => la salida no llega al contexto.
echo "$command" | grep -qP '(^|[^0-9<>])>>?[[:space:]]*[^&[:space:]]' && exit 0
# Pipe => la salida pasa por un filtro y llega reducida.
echo "$command" | grep -qP '\|' && exit 0

# Rutas que sí merece la pena volcar enteras aunque sean largas.
path_exempt() {
  echo "$1" | grep -qiP '(CLAUDE\.md|MEMORY\.md|/\.claude/|\.env)'
}

blocked_file=""
blocked_lines=0

check_segment() {
  local seg want="" cmd n range a b tok
  seg=$(echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -z "$seg" ]] && return 0

  # Comando base, saltando asignaciones de entorno y sudo.
  cmd=$(echo "$seg" | grep -oP '^(?:(?:[A-Za-z_][A-Za-z0-9_]*=\S*|sudo)\s+)*\K\S+' || true)
  cmd="${cmd##*/}"

  case "$cmd" in
    cat|bat|nl|less|more)
      want=-1 ;;                                    # vuelca el archivo entero
    head|tail)
      n=$(echo "$seg" | grep -oP '(?:^|\s)-(?:n\s*|)\K[0-9]+' | head -1 || true)
      want=${n:-10} ;;                              # sin -n, el default son 10
    sed)
      echo "$seg" | grep -qP '(^|\s)-n(\s|$)' || return 0
      range=$(echo "$seg" | grep -oP '[0-9]+\s*,\s*[0-9]+\s*p' | head -1 || true)
      [[ -z "$range" ]] && return 0                 # sed -n '42p' u otra cosa: pasa
      a=$(echo "${range%%,*}" | tr -dc 0-9)
      b=$(echo "${range#*,}"  | tr -dc 0-9)
      want=$(( b - a + 1 )) ;;
    *)
      return 0 ;;
  esac

  # Si la lectura ya viene acotada por debajo del umbral, pasa.
  [[ "$want" != "-1" ]] && (( want <= MIN_LINES )) && return 0

  # Busca argumentos que sean archivos reales.
  local first=1
  for tok in $seg; do
    if (( first )); then first=0; continue; fi
    [[ "$tok" == -* ]] && continue
    tok="${tok%\"}"; tok="${tok#\"}"; tok="${tok%\'}"; tok="${tok#\'}"
    [[ -f "$tok" ]] || continue
    path_exempt "$tok" && continue
    local lines
    lines=$(wc -l < "$tok" 2>/dev/null || echo 0)
    if (( lines > MIN_LINES )); then
      blocked_file="$tok"; blocked_lines="$lines"
      return 1
    fi
  done
  return 0
}

# Trocea por ; && || y evalúa cada comando por separado.
while IFS= read -r segment; do
  check_segment "$segment" || break
done < <(echo "$command" | sed -E 's/(\|\||&&|;)/\n/g')

if [[ -n "$blocked_file" ]]; then
  cat >&2 <<MSG
Volcado completo bloqueado: ${blocked_file} tiene ${blocked_lines} líneas (umbral: ${MIN_LINES}).

Elige una de estas vías:
  1. Delega en el subagente 'bulk-reader' (Haiku) con la pregunta concreta.
     Devuelve solo el extracto, con referencias ruta:línea.
  2. Acota la lectura: sed -n 'A,Bp', head -N, o un rango por debajo del umbral.
  3. Filtra: grep/rg sobre el archivo, o un pipe que reduzca la salida.

Para desactivar el shunt en esta sesión:  shunt off
MSG
  exit 2
fi

exit 0
