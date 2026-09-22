#!/usr/bin/env bash
# shunt-file-size.sh — Claude Code PreToolUse/Read hook
# Redirige lecturas completas de archivos grandes hacia el subagente bulk-reader.
# Deja pasar lecturas parciales (offset/limit explícitos) para edición precisa.
# Reads stdin JSON from Claude Code hook framework.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shunt-common.sh
. "$SCRIPT_DIR/shunt-common.sh"

# Consumimos stdin siempre y primero: salir antes de leerlo provoca SIGPIPE
# en el proceso que nos escribe el payload.
input=$(cat)

shunt_agent_exempt "$(echo "$input" | jq -r '.agent_type // ""')" && exit 0

shunt_resolve "$(echo "$input" | jq -r '.session_id // ""')"
(( SHUNT_ACTIVE )) || exit 0
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')
offset=$(echo "$input"   | jq -r '.tool_input.offset // ""')
limit=$(echo "$input"    | jq -r '.tool_input.limit // ""')

[[ -z "$file_path" ]] && exit 0
[[ -f "$file_path" ]] || exit 0

# Lectura parcial explícita: es edición dirigida, se permite.
[[ -n "$offset" || -n "$limit" ]] && exit 0

# Binarios, imágenes, PDFs y notebooks: Read los trata aparte, no aplican.
if echo "$file_path" | grep -qiP '\.(png|jpe?g|gif|webp|pdf|ipynb|zip|jar|class|so|bin)$'; then
  exit 0
fi

# Archivos que sí merece la pena leer enteros aunque sean largos.
if echo "$file_path" | grep -qiP '(CLAUDE\.md|MEMORY\.md|/\.claude/|\.env)'; then
  exit 0
fi

lines=$(wc -l < "$file_path" 2>/dev/null || echo 0)

if (( lines > MIN_LINES )); then
  cat >&2 <<MSG
Lectura completa bloqueada: ${file_path} tiene ${lines} líneas (umbral: ${MIN_LINES}).

Elige una de estas dos vías:
  1. Delega en el subagente 'bulk-reader' (Haiku) con la pregunta concreta que
     necesitas responder. Te devolverá solo el extracto con referencias ruta:línea.
  2. Si ya sabes qué fragmento necesitas para editarlo, vuelve a llamar a Read
     con offset y limit explícitos — esas lecturas pasan sin bloqueo.

Para desactivar el shunt en esta sesión:  shunt off
MSG
  exit 2
fi

exit 0
