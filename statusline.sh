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

# Ensure node is available (nvm shells sometimes start without it on PATH).
if ! command -v node >/dev/null 2>&1; then
  [ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
fi

# --- extract fields (node, so this works on machines without jq) ---
# Usage-limit windows come from the LIVE `rate_limits` field on stdin, which
# Claude Code refreshes from the rate-limit headers of every API response.
# It is absent until the first response of a session; only then do we fall back
# to ~/.claude.json, which is just a launch-time snapshot (its sole writer is the
# explicit usage fetch, itself throttled to 5 minutes), so flag it as not-live.
# resets_at values are normalised to unix epoch seconds for time_left().
# Fields are \x1f-separated, not tab: with an all-whitespace IFS bash collapses
# runs of separators, so empty fields would vanish and shift every later value.
IFS=$'\x1f' read -r model effort fast \
                  ctx_used_pct ctx_size ctx_tokens \
                  sess_pct sess_reset week_pct week_reset \
                  cached stale _end < <(
  printf '%s' "$input" | node -e '
    const fs=require("fs"),path=require("path");
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      let j={};try{j=JSON.parse(d)}catch(e){}
      const num  = (v)=>typeof v==="number"&&Number.isFinite(v);
      const one  = (v)=>num(v)?String(Math.round(v*10)/10):"";      // 37.42 -> "37.4"
      const secs = (v)=>{                                            // -> epoch seconds
        if(num(v)) return String(Math.round(v));
        if(typeof v==="string"){const t=Date.parse(v);return Number.isNaN(t)?"":String(Math.round(t/1000));}
        return "";
      };

      const model  = (j.model&&j.model.display_name)||"?";
      const effort = (j.effort&&j.effort.level)||"";
      const fast   = j.fast_mode===true?"true":"false";

      const cw = j.context_window||{};
      const ctxPct    = one(cw.used_percentage);
      const ctxSize   = num(cw.context_window_size)?String(cw.context_window_size):"";
      const ctxTokens = String((num(cw.total_input_tokens)?cw.total_input_tokens:0)
                             + (num(cw.total_output_tokens)?cw.total_output_tokens:0));

      let fh=null, sd=null, cached="", stale="";
      const rl=j.rate_limits;
      if(rl&&(rl.five_hour||rl.seven_day)){
        if(rl.five_hour) fh={pct:rl.five_hour.used_percentage, at:rl.five_hour.resets_at};
        if(rl.seven_day) sd={pct:rl.seven_day.used_percentage, at:rl.seven_day.resets_at};
      } else {
        try {
          const home=process.env.HOME||require("os").homedir();
          const cfg=JSON.parse(fs.readFileSync(path.join(home,".claude.json"),"utf8"));
          const store=cfg.cachedUsageUtilization||{};
          const u=store.utilization||{};
          if(u.five_hour&&num(u.five_hour.utilization)) fh={pct:u.five_hour.utilization, at:u.five_hour.resets_at};
          if(u.seven_day&&num(u.seven_day.utilization)) sd={pct:u.seven_day.utilization, at:u.seven_day.resets_at};
          if(fh||sd){
            cached="1";
            if(num(store.fetchedAtMs)&&Date.now()-store.fetchedAtMs>3600000) stale="1";
          }
        } catch(e){}
      }

      process.stdout.write([
        model, effort, fast,
        ctxPct, ctxSize, ctxTokens,
        fh?one(fh.pct):"", fh?secs(fh.at):"",
        sd?one(sd.pct):"", sd?secs(sd.at):"",
        cached, stale, "."
      ].join("\x1f"));
    });
  ' 2>/dev/null
)
[ -z "$model" ] && model="?"

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

# A leading ~ marks limits read from the launch-time snapshot rather than live.
mark=""
[ -n "$cached" ] && mark="~"

# Session (5h) usage limit + countdown to reset
if [ -n "$sess_pct" ]; then
  c=$(pct_color "$sess_pct")
  out="${out}${SEP}${DIM}${mark}5h${RESET} ${c}${sess_pct}%${RESET}"
  left=$(time_left "$sess_reset")
  [ -n "$left" ] && out="${out} ${DIM}⟳${left}${RESET}"
fi

# Weekly (7d) usage limit
if [ -n "$week_pct" ]; then
  c=$(pct_color "$week_pct")
  out="${out}${SEP}${DIM}${mark}7d${RESET} ${c}${week_pct}%${RESET}"
fi

# Snapshot older than an hour: say so rather than showing numbers that look live.
[ -n "$stale" ] && out="${out} ${DIM}(stale)${RESET}"

printf '%b' "$out"
