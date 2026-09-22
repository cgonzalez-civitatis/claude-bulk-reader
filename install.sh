#!/usr/bin/env bash
# install.sh — instala el shunt de lecturas grandes para Claude Code.
#
#   ./install.sh              instala (hooks + subagente + wiring)
#   ./install.sh --uninstall  desinstala y restaura el settings.json previo
#
# Idempotente: reinstalar no duplica entradas en settings.json.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
DEST_SCRIPTS="$CLAUDE_DIR/scripts"
DEST_AGENTS="$CLAUDE_DIR/agents"
STAMP="$(date +%Y%m%d_%H%M%S)"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }

command -v jq >/dev/null || { red "Falta jq. Instálalo y reintenta."; exit 1; }

backup_settings() {
  [[ -f "$SETTINGS" ]] || return 0
  mkdir -p "$CLAUDE_DIR/backups"
  cp "$SETTINGS" "$CLAUDE_DIR/backups/settings.json.bak.$STAMP"
  info "Backup: ~/.claude/backups/settings.json.bak.$STAMP"
}

# Quita cualquier entrada previa del shunt (por ruta del comando).
strip_shunt() {
  jq '
    if .hooks.PreToolUse then
      .hooks.PreToolUse |= map(
        .hooks |= map(select((.command // "") | test("shunt-(file-size|bash-read)\\.sh$") | not))
      ) | .hooks.PreToolUse |= map(select((.hooks | length) > 0))
    else . end
  ' "$1"
}

if [[ "${1:-}" == "--uninstall" ]]; then
  [[ -f "$SETTINGS" ]] || { red "No hay $SETTINGS"; exit 1; }
  backup_settings
  tmp=$(mktemp); strip_shunt "$SETTINGS" > "$tmp"
  jq empty "$tmp" && mv "$tmp" "$SETTINGS"
  rm -f "$DEST_SCRIPTS/shunt-file-size.sh" "$DEST_SCRIPTS/shunt-bash-read.sh" "$DEST_AGENTS/bulk-reader.md"
  green "Shunt desinstalado."
  echo "Recuerda quitar a mano la sección del shunt de tu CLAUDE.md, si la añadiste."
  exit 0
fi

echo "Instalando el shunt de lecturas grandes"
mkdir -p "$DEST_SCRIPTS" "$DEST_AGENTS" "$CLAUDE_DIR"

install -m 0755 "$SRC/hooks/shunt-file-size.sh" "$DEST_SCRIPTS/shunt-file-size.sh"
install -m 0755 "$SRC/hooks/shunt-bash-read.sh" "$DEST_SCRIPTS/shunt-bash-read.sh"
info "Hooks -> $DEST_SCRIPTS/"

install -m 0644 "$SRC/agents/bulk-reader.md" "$DEST_AGENTS/bulk-reader.md"
info "Subagente -> $DEST_AGENTS/bulk-reader.md"

[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
backup_settings

tmp=$(mktemp)
strip_shunt "$SETTINGS" | jq \
  --arg f "$DEST_SCRIPTS/shunt-file-size.sh" \
  --arg b "$DEST_SCRIPTS/shunt-bash-read.sh" '
  .hooks //= {} | .hooks.PreToolUse //= [] |
  .hooks.PreToolUse += [
    {matcher:"Read", hooks:[{type:"command", command:$f}]},
    {matcher:"Bash", hooks:[{type:"command", command:$b}]}
  ]' > "$tmp"

if jq empty "$tmp" 2>/dev/null; then
  mv "$tmp" "$SETTINGS"
  info "settings.json actualizado (matchers Read y Bash)"
else
  rm -f "$tmp"; red "El settings.json resultante no era JSON válido. Nada modificado."; exit 1
fi

green "Listo."
echo
echo "Último paso, manual: copia el contenido de CLAUDE.md.example en tu"
echo "~/.claude/CLAUDE.md. Sin eso los hooks bloquean pero nadie sabe delegar."
echo
echo "Comprueba la instalación con:  ./test/test-hooks.sh"
