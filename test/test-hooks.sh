#!/usr/bin/env bash
# test-hooks.sh — matriz de casos contra los dos hooks del shunt.
# Usa los scripts del repo, no los instalados, salvo que pases --installed.

set -uo pipefail

if [[ "${1:-}" == "--installed" ]]; then
  DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts"
else
  DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
fi
BASH_HOOK="$DIR/shunt-bash-read.sh"
READ_HOOK="$DIR/shunt-file-size.sh"
for h in "$BASH_HOOK" "$READ_HOOK"; do
  [[ -x "$h" ]] || { echo "No encuentro $h"; exit 1; }
done

command -v jq >/dev/null || { echo "Falta jq"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
seq 1 500 > "$TMP/big.java"
seq 1 100 > "$TMP/small.java"

pass=0; fail=0
chk() { # $1=esperado $2=obtenido $3=descripción
  if [[ "$1" == "$2" ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$3"
  else fail=$((fail+1)); printf '  FALLA %s (esperaba %s, obtuvo %s)\n' "$3" "$1" "$2"; fi
}
runb() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | "$BASH_HOOK" >/dev/null 2>&1; echo $?; }
runr() { jq -nc --argjson o "$2" --argjson l "$3" --arg p "$1" \
           '{tool_input:({file_path:$p} + (if $o==null then {} else {offset:$o} end)
                                        + (if $l==null then {} else {limit:$l} end))}' \
         | "$READ_HOOK" >/dev/null 2>&1; echo $?; }

echo "Hook de Bash — deben bloquear (2)"
chk 2 "$(runb "cat $TMP/big.java")"                    "cat archivo grande"
chk 2 "$(runb "head -500 $TMP/big.java")"              "head -500"
chk 2 "$(runb "head -n 400 $TMP/big.java")"            "head -n 400"
chk 2 "$(runb "sed -n '1,400p' $TMP/big.java")"        "sed -n rango amplio"
chk 2 "$(runb "nl $TMP/big.java")"                     "nl"
chk 2 "$(runb "tail -n 400 $TMP/big.java")"            "tail -n 400"
chk 2 "$(runb "cat $TMP/small.java $TMP/big.java")"    "varios archivos, uno grande"
chk 2 "$(runb "cd /tmp && cat $TMP/big.java")"         "tras &&"

echo "Hook de Bash — deben pasar (0)"
chk 0 "$(runb "cat $TMP/small.java")"                  "archivo pequeño"
chk 0 "$(runb "head -50 $TMP/big.java")"               "head acotado"
chk 0 "$(runb "head $TMP/big.java")"                   "head sin flags (10 líneas)"
chk 0 "$(runb "sed -n '10,60p' $TMP/big.java")"        "sed rango corto"
chk 0 "$(runb "sed -n '42p' $TMP/big.java")"           "sed una línea"
chk 0 "$(runb "cat $TMP/big.java | grep 42")"          "pipe a filtro"
chk 0 "$(runb "cat $TMP/big.java > $TMP/out.txt")"     "redirección"
chk 0 "$(runb "cat > $TMP/w.java <<EOF")"              "heredoc (escritura)"
chk 0 "$(runb "grep foo $TMP/big.java")"               "grep"
chk 0 "$(runb "wc -l $TMP/big.java")"                  "wc"
chk 0 "$(runb "git status")"                           "comando no lector"
chk 0 "$(runb "cat /no/existe.java")"                  "archivo inexistente"
chk 0 "$(SHUNT_OFF=1 runb "cat $TMP/big.java")"        "SHUNT_OFF=1"

echo "Hook de Read"
chk 2 "$(runr "$TMP/big.java" null null)"              "lectura completa de archivo grande"
chk 0 "$(runr "$TMP/big.java" 10 40)"                  "lectura parcial con offset/limit"
chk 0 "$(runr "$TMP/small.java" null null)"            "archivo pequeño"
chk 0 "$(runr "/no/existe.java" null null)"            "archivo inexistente"

echo "Estado por sesión y global"
export SHUNT_STATE_DIR="$TMP/state"; mkdir -p "$SHUNT_STATE_DIR"
SID="test-session"
runbs() { jq -nc --arg c "$1" --arg s "$SID" '{session_id:$s,tool_input:{command:$c}}' \
            | "$BASH_HOOK" >/dev/null 2>&1; echo $?; }
BIG="cat $TMP/big.java"   # 500 líneas: bloquea con el umbral por defecto

chk 2 "$(runbs "$BIG")"                            "sin estado: bloquea"
echo off > "$SHUNT_STATE_DIR/$SID"
chk 0 "$(runbs "$BIG")"                            "sesión off: pasa"
echo 600 > "$SHUNT_STATE_DIR/$SID"
chk 0 "$(runbs "$BIG")"                            "sesión umbral 600: pasa"
echo 100 > "$SHUNT_STATE_DIR/$SID"
chk 2 "$(runbs "$BIG")"                            "sesión umbral 100: bloquea"
rm -f "$SHUNT_STATE_DIR/$SID"
echo off > "$SHUNT_STATE_DIR/global"
chk 0 "$(runbs "$BIG")"                            "global off: pasa"
echo on > "$SHUNT_STATE_DIR/$SID"
chk 2 "$(runbs "$BIG")"                            "sesión on pisa global off"
chk 0 "$(SHUNT_OFF=1 runbs "$BIG")"                "SHUNT_OFF del entorno pisa todo"
echo basura > "$SHUNT_STATE_DIR/$SID"
chk 2 "$(runbs "$BIG")"                            "estado corrupto: se ignora"
rm -f "$SHUNT_STATE_DIR/$SID" "$SHUNT_STATE_DIR/global"
unset SHUNT_STATE_DIR

echo "Exención por tipo de agente"
runa() { jq -nc --arg c "$1" --arg a "$2" \
           '{tool_input:{command:$c}} + (if $a=="" then {} else {agent_type:$a} end)' \
         | "$BASH_HOOK" >/dev/null 2>&1; echo $?; }
runra() { jq -nc --arg p "$1" --arg a "$2" \
            '{tool_input:{file_path:$p}} + (if $a=="" then {} else {agent_type:$a} end)' \
          | "$READ_HOOK" >/dev/null 2>&1; echo $?; }

chk 2 "$(runa "cat $TMP/big.java" "")"              "sesión principal: bloquea"
chk 0 "$(runa "cat $TMP/big.java" "bulk-reader")"   "bulk-reader exento (Bash)"
chk 0 "$(runra "$TMP/big.java" "bulk-reader")"      "bulk-reader exento (Read)"
chk 2 "$(runa "cat $TMP/big.java" "general-purpose")" "subagente trabajador: sigue bloqueado"
chk 2 "$(runa "cat $TMP/big.java" "Explore")"       "Explore: sigue bloqueado"
chk 0 "$(SHUNT_EXEMPT_AGENTS=Explore runa "cat $TMP/big.java" "Explore")" "lista de exentos configurable"
chk 2 "$(SHUNT_EXEMPT_AGENTS=Explore runa "cat $TMP/big.java" "bulk-reader")" "lista a medida excluye al resto"

echo
echo "$pass ok, $fail fallos"
[[ $fail -eq 0 ]]
