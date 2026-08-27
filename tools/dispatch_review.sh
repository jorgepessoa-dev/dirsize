#!/usr/bin/env bash
# dispatch_review.sh
# ---------------------------------------------------------------------------
# Envia um prompt para o pane tmux de um agente (TUI: deepcode, deepseek,
# gemini-cli, etc.) e recolhe a resposta por polling do capture-pane.
# E' o MESMO padrao usado no droplet do trading-advisor (send-keys + capture-pane),
# mas para correres TU no laptop, onde os agentes locais vivem.
#
# Corre isto no laptop (mesma maquina onde tens os panes tmux dos agentes).
# Um Claude Code a correr na cloud NAO consegue fazer isto: send-keys e' local.
#
# Uso:
#   ./dispatch_review.sh -t <target-tmux> -p <ficheiro-prompt> -o <ficheiro-saida> [-i idle_seg] [-m max_seg]
#
# Exemplos:
#   # descobre os alvos:  tmux ls   e   tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'
#   ./dispatch_review.sh -t deepseek:0.0 -p prompt.txt -o out_deepseek.txt
#   ./dispatch_review.sh -t gemini:0.0   -p prompt.txt -o out_gemini.txt
#
# Nota: 'prompt.txt' deve conter APENAS a seccao "PROMPT" do REVIEW_REQUEST.md
#       (a partir de "Es um revisor senior..."). Injetar markdown com muitas
#       linhas em branco pode fazer alguns TUIs submeterem cedo.
# ---------------------------------------------------------------------------
set -euo pipefail

usage() {
  echo "Uso: $0 -t <target-tmux> -p <ficheiro-prompt> -o <ficheiro-saida> [-i idle_seg] [-m max_seg]" >&2
  exit 1
}

TARGET=""; PROMPT=""; OUT=""; IDLE=20; MAX=1200
while getopts "t:p:o:i:m:h" opt; do
  case "$opt" in
    t) TARGET="$OPTARG" ;;
    p) PROMPT="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    i) IDLE="$OPTARG" ;;
    m) MAX="$OPTARG" ;;
    h|*) usage ;;
  esac
done

[ -n "$TARGET" ] && [ -n "$PROMPT" ] && [ -n "$OUT" ] || usage
[ -f "$PROMPT" ] || { echo "ERRO: ficheiro de prompt nao encontrado: $PROMPT" >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "ERRO: tmux nao instalado neste laptop." >&2; exit 1; }

# valida a sessao (parte antes do ':')
SESSION="${TARGET%%:*}"
tmux has-session -t "$SESSION" 2>/dev/null || {
  echo "ERRO: sessao tmux '$SESSION' inexistente. Ve 'tmux ls'." >&2; exit 1;
}

echo "-> a injetar prompt em '$TARGET' ..."
# Injecao multiline fiavel via buffer (evita problemas de escaping do send-keys).
tmux load-buffer -b review_pkg -- "$PROMPT"
tmux paste-buffer -b review_pkg -t "$TARGET"
# submete (a maioria dos TUIs usa Enter; se o teu usa Ctrl+Enter, ajusta aqui)
tmux send-keys -t "$TARGET" Enter

echo "-> a aguardar resposta (estabiliza ao fim de ${IDLE}s sem mudanca; timeout ${MAX}s) ..."
start=$(date +%s)
prev=""; stable=0
while :; do
  sleep 5
  cur="$(tmux capture-pane -p -S -10000 -t "$TARGET" 2>/dev/null || true)"
  if [ "$cur" = "$prev" ]; then
    stable=$((stable + 5))
  else
    stable=0; prev="$cur"
  fi
  now=$(date +%s); elapsed=$((now - start))
  printf '   ... %ss decorridos | estavel ha %ss\r' "$elapsed" "$stable"
  if [ "$stable" -ge "$IDLE" ]; then echo; echo "-> saida estabilizou."; break; fi
  if [ "$elapsed" -ge "$MAX" ]; then echo; echo "-> timeout ${MAX}s; a capturar o que existe."; break; fi
done

tmux capture-pane -p -S -10000 -t "$TARGET" > "$OUT"
echo "-> resposta guardada em: $OUT"
echo "   (revê o ficheiro: TUIs que redesenham constantemente podem nunca 'estabilizar' —"
echo "    nesse caso baixa -i ou captura manualmente com: tmux capture-pane -p -S -10000 -t '$TARGET')"
