#!/usr/bin/env bash
# dispatch-review.sh — envia o PROMPT de tools/review-request.md para UM agente
# (pane tmux) e recolhe a resposta por polling do capture-pane.
# ---------------------------------------------------------------------------
# Opt-in, um alvo por invocacao. NUNCA envia para os dois. Nao ha loop de alvos.
#
# Corre isto NO LAPTOP (a mesma maquina onde vivem os panes tmux dos agentes).
# Um Claude Code na cloud nao consegue: send-keys e' local.
#
# Uso:
#   ./dispatch-review.sh <claude|deepcode> [-o saida.txt] [-i idle_seg] [-m max_seg]
#
# Antes de usar: cria/abre as sessoes tmux e ajusta o mapa TARGETS abaixo.
#   tmux new -A -s claude       # cria (ou liga a) a sessao 'claude'; corre la o teu Claude
#   tmux new -A -s deepcode     # idem para o deepcode
#   tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'
# ---------------------------------------------------------------------------
set -euo pipefail

# --- mapa de alvos: alias -> target tmux (sessao:janela.pane) ---------------
declare -A TARGETS=(
  [claude]="claude:0.0"
  [deepcode]="deepcode:0.0"
)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ="$HERE/review-request.md"
IDLE=20; MAX=1200; OUT=""

ALIASES="${!TARGETS[*]}"          # ex: "claude deepcode"
usage() {
  echo "Uso: $0 <${ALIASES// /|}> [-o saida.txt] [-i idle_seg] [-m max_seg]" >&2
  echo "  Um alvo. Nunca os dois. Edita o mapa TARGETS no topo do script." >&2
  exit 1
}

[ $# -ge 1 ] || usage
ALIAS="$1"; shift
while getopts "o:i:m:h" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    i) IDLE="$OPTARG" ;;
    m) MAX="$OPTARG" ;;
    h|*) usage ;;
  esac
done

# --- validacoes fail-closed ------------------------------------------------
[ -n "${TARGETS[$ALIAS]+x}" ] || { echo "ERRO: alvo desconhecido '$ALIAS'. Conhecidos: ${!TARGETS[*]}" >&2; exit 1; }
[ -f "$REQ" ] || { echo "ERRO: $REQ nao encontrado." >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "ERRO: tmux nao instalado neste laptop." >&2; exit 1; }

TARGET="${TARGETS[$ALIAS]}"
SESSION="${TARGET%%:*}"
tmux has-session -t "$SESSION" 2>/dev/null || {
  echo "ERRO: sessao tmux '$SESSION' inexistente." >&2
  echo "      cria com:  tmux new -A -s $SESSION   (e corre la o agente)" >&2
  exit 1
}
[ -z "$OUT" ] && OUT="$HERE/review-out-$ALIAS-$(date +%Y%m%d-%H%M%S).txt"

# --- extrai so a seccao PROMPT do review-request.md ----------------------
PROMPT_FILE="$(mktemp)"
trap 'rm -f "$PROMPT_FILE"' EXIT
awk '
  /^## PROMPT \(copiar a partir daqui\)/ { grab=1; next }
  /^--- \(fim do prompt\) ---/           { grab=0 }
  grab { print }
' "$REQ" > "$PROMPT_FILE"
[ -s "$PROMPT_FILE" ] || { echo "ERRO: nao consegui extrair a seccao PROMPT de $REQ." >&2; exit 1; }
LINHAS="$(wc -l < "$PROMPT_FILE")"

echo "-> alvo   : $ALIAS  ($TARGET)"
echo "-> prompt : $LINHAS linhas de $REQ"
echo "-> saida  : $OUT"
echo

# --- injecta (buffer -> paste, evita escaping do send-keys) --------------
tmux load-buffer -b review_pkg -- "$PROMPT_FILE"
tmux paste-buffer -b review_pkg -t "$TARGET"
tmux send-keys -t "$TARGET" Enter   # a maioria dos TUIs submete com Enter

echo "-> a aguardar resposta (estabiliza ao fim de ${IDLE}s sem mudanca; timeout ${MAX}s)"
start=$(date +%s); prev=""; stable=0
while :; do
  sleep 5
  cur="$(tmux capture-pane -p -S -10000 -t "$TARGET" 2>/dev/null || true)"
  if [ "$cur" = "$prev" ]; then stable=$((stable + 5)); else stable=0; prev="$cur"; fi
  now=$(date +%s); elapsed=$((now - start))
  printf '   ... %ss decorridos | estavel ha %ss\r' "$elapsed" "$stable"
  [ "$stable" -ge "$IDLE" ] && { echo; echo "-> saida estabilizou."; break; }
  [ "$elapsed" -ge "$MAX" ] && { echo; echo "-> timeout ${MAX}s; a capturar o que existe."; break; }
done

tmux capture-pane -p -S -10000 -t "$TARGET" > "$OUT"
echo "-> resposta guardada em: $OUT"
echo "   (TUIs que redesenham sem parar podem nunca 'estabilizar' -> baixa -i,"
echo "    ou captura a mao:  tmux capture-pane -p -S -10000 -t '$TARGET')"
