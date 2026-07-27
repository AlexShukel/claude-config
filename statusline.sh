#!/usr/bin/env bash
# Claude Code status line: usage limits · model/effort · context window
# Reads the status line JSON from stdin (see: code.claude.com/docs/en/statusline)

input=$(cat)

# --- ANSI colors ---
DIM='\033[2m'; RESET='\033[0m'
CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; BLUE='\033[34m'
SEP="${DIM} · ${RESET}"

# Pick a color for a 0-100 usage percentage.
pct_color() { # $1 = percent (may be float/empty)
  local p=${1%.*}; [ -z "$p" ] && { printf '%s' "$DIM"; return; }
  if   [ "$p" -ge 90 ]; then printf '%s' "$RED"
  elif [ "$p" -ge 70 ]; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

# Time remaining until a unix-epoch timestamp, e.g. "2h13m", "47m", "<1m".
time_left() { # $1 = unix epoch seconds (resets_at)
  local target=$1 now diff h m
  [ -z "$target" ] && return
  now=$(date +%s)
  diff=$(( target - now ))
  [ "$diff" -le 0 ] && { printf 'now'; return; }
  h=$(( diff / 3600 )); m=$(( (diff % 3600) / 60 ))
  if   [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '<1m'; fi
}

# Compact a token count: 16234 -> 16k, 1500000 -> 1.5M
human() { # $1 = integer tokens
  local n=$1; [ -z "$n" ] && { printf '?'; return; }
  if   [ "$n" -ge 1000000 ]; then awk "BEGIN{printf \"%.1fM\", $n/1000000}"
  elif [ "$n" -ge 1000 ];    then printf '%dk' $(( n / 1000 ))
  else printf '%d' "$n"; fi
}

# --- extract fields ---
model=$(jq -r '.model.display_name // "?"'        <<<"$input")
effort=$(jq -r '.effort.level // empty'           <<<"$input")
fast=$(jq -r '.fast_mode // false'                <<<"$input")

ctx_used_pct=$(jq -r '.context_window.used_percentage // empty | (.*10|round)/10'   <<<"$input")
ctx_size=$(jq -r '.context_window.context_window_size // empty'                <<<"$input")
ctx_tokens=$(jq -r '((.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0))' <<<"$input")

sess_pct=$(jq -r '.rate_limits.five_hour.used_percentage // empty | (.*10|round)/10' <<<"$input")
sess_reset=$(jq -r '.rate_limits.five_hour.resets_at // empty'      <<<"$input")
week_pct=$(jq -r '.rate_limits.seven_day.used_percentage // empty | (.*10|round)/10' <<<"$input")

# --- build segments ---
out=""

# Model + effort (+ fast flag)
seg="${CYAN}${model}${RESET}"
[ -n "$effort" ] && seg="${seg}${DIM}:${RESET}${BLUE}${effort}${RESET}"
[ "$fast" = "true" ] && seg="${seg} ${YELLOW}⚡${RESET}"
out="$seg"

# Context window
if [ -n "$ctx_used_pct" ] && [ -n "$ctx_size" ]; then
  c=$(pct_color "$ctx_used_pct")
  out="${out}${SEP}${DIM}ctx${RESET} ${c}${ctx_used_pct}%${RESET} ${DIM}($(human "$ctx_tokens")/$(human "$ctx_size"))${RESET}"
fi

# Session (5h) usage limit + countdown to reset
if [ -n "$sess_pct" ]; then
  c=$(pct_color "$sess_pct")
  out="${out}${SEP}${DIM}5h${RESET} ${c}${sess_pct}%${RESET}"
  left=$(time_left "$sess_reset")
  [ -n "$left" ] && out="${out} ${DIM}⟳${left}${RESET}"
fi

# Weekly (7d) usage limit
if [ -n "$week_pct" ]; then
  c=$(pct_color "$week_pct")
  out="${out}${SEP}${DIM}7d${RESET} ${c}${week_pct}%${RESET}"
fi

printf '%b' "$out"
