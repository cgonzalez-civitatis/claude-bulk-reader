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
  rm -f "$DEST_SCRIPTS/shunt-file-size.sh" "$DEST_SCRIPTS/shunt-bash-read.sh" \
        "$DEST_SCRIPTS/shunt-common.sh" "$DEST_AGENTS/bulk-reader.md"
  rm -f "$HOME/.local/bin/shunt" "$DEST_SCRIPTS/shunt"
  rm -rf "$CLAUDE_DIR/shunt-state"
  green "Shunt desinstalado."
  echo "Recuerda quitar a mano la sección del shunt de tu CLAUDE.md, si la añadiste."
  exit 0
fi

echo "Instalando el shunt de lecturas grandes"
mkdir -p "$DEST_SCRIPTS" "$DEST_AGENTS" "$CLAUDE_DIR"

install -m 0755 "$SRC/hooks/shunt-file-size.sh" "$DEST_SCRIPTS/shunt-file-size.sh"
install -m 0755 "$SRC/hooks/shunt-bash-read.sh" "$DEST_SCRIPTS/shunt-bash-read.sh"
install -m 0644 "$SRC/hooks/shunt-common.sh"    "$DEST_SCRIPTS/shunt-common.sh"
info "Hooks -> $DEST_SCRIPTS/"

# El CLI va a un directorio del PATH si lo hay, para poder escribir `shunt off`.
CLI_DEST=""
case ":$PATH:" in
  *":$HOME/.local/bin:"*) CLI_DEST="$HOME/.local/bin" ;;
  *":$HOME/bin:"*)        CLI_DEST="$HOME/bin" ;;
esac
if [[ -n "$CLI_DEST" ]]; then
  mkdir -p "$CLI_DEST"; install -m 0755 "$SRC/bin/shunt" "$CLI_DEST/shunt"
  info "CLI -> $CLI_DEST/shunt  (ya en tu PATH)"
else
  install -m 0755 "$SRC/bin/shunt" "$DEST_SCRIPTS/shunt"
  info "CLI -> $DEST_SCRIPTS/shunt"
  CLI_WARN=1
fi

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
if [[ "${CLI_WARN:-0}" == "1" ]]; then
  echo
  echo "Nota: ningún directorio de tu PATH servía para el CLI. Para poder escribir"
  echo "  shunt off   en vez de la ruta completa, añade a tu shell:"
  echo "    export PATH=\"$DEST_SCRIPTS:\$PATH\""
fi
