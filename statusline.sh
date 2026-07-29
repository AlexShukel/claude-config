#!/usr/bin/env bash
# Claude Code custom status line.
# Reads session JSON on stdin, prints a single formatted line.
# Segments: model · dir · git (branch/dirty/ahead-behind) · node+pnpm · cost
input="$(cat)"

# Ensure node is available (nvm shells sometimes start without it on PATH).
if ! command -v node >/dev/null 2>&1; then
  [ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
fi

# --- Extract flat fields from the JSON via node (tab-separated) ---
# Usage-limit windows (5h + weekly) come from the LIVE `rate_limits` field on stdin,
# which Claude Code refreshes from the rate-limit headers of every API response.
# ~/.claude.json is only a launch-time snapshot, used until the first response lands.
# Pre-formats a compact usage string + severity, so bash only colorizes.
IFS=$'\t' read -r MODEL CURDIR COST LADD LDEL USAGE USAGE_SEV EFFORT < <(
  printf '%s' "$input" | node -e '
    const fs=require("fs"),path=require("path");
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      let j={};try{j=JSON.parse(d)}catch(e){}
      const m   = (j.model&&j.model.display_name)||"?";
      const dir = (j.workspace&&j.workspace.current_dir)||j.cwd||process.env.PWD||"";
      const c   = (j.cost&&j.cost.total_cost_usd)||0;
      const la  = (j.cost&&j.cost.total_lines_added)||0;
      const ld  = (j.cost&&j.cost.total_lines_removed)||0;
      const eff = (j.effort&&j.effort.level)||"";  // live session effort (if model supports it)

      // --- usage limits: live from stdin, disk snapshot only as a fallback ---
      let usage="", sev="ok";
      try {
        const now=Date.now();
        // resets_at is unix epoch SECONDS when live, an ISO string in the disk cache.
        const left=(v)=>{
          let target;
          if(typeof v==="number") target=v*1000;
          else if(typeof v==="string") target=Date.parse(v);
          else return "";
          const ms=target-now;
          if(!(ms>0)) return "now";
          const min=Math.floor(ms/60000), h=Math.floor(min/60), dd=Math.floor(h/24);
          if(dd>0) return dd+"d"+(h%24)+"h";
          if(h>0)  return h+"h"+(min%60)+"m";
          return min+"m";
        };

        let fh=null, sd=null, cached=false, age=0;
        const rl=j.rate_limits;
        if(rl&&(rl.five_hour||rl.seven_day)){
          // Live: updated on every API response, so this tracks the session in real time.
          if(rl.five_hour) fh={pct:rl.five_hour.used_percentage, at:rl.five_hour.resets_at};
          if(rl.seven_day) sd={pct:rl.seven_day.used_percentage, at:rl.seven_day.resets_at};
        } else {
          // No response yet this session (e.g. right after launch). Claude Code only
          // rewrites this snapshot on an explicit usage fetch, throttled to 5 min, so
          // it can lag badly — show it, but mark it as not-live.
          const home=process.env.HOME||require("os").homedir();
          const cfg=JSON.parse(fs.readFileSync(path.join(home,".claude.json"),"utf8"));
          const store=cfg.cachedUsageUtilization||{};
          const u=store.utilization||{};
          if(u.five_hour&&typeof u.five_hour.utilization==="number") fh={pct:u.five_hour.utilization, at:u.five_hour.resets_at};
          if(u.seven_day&&typeof u.seven_day.utilization==="number") sd={pct:u.seven_day.utilization, at:u.seven_day.resets_at};
          if(fh||sd){
            cached=true;
            if(typeof store.fetchedAtMs==="number") age=now-store.fetchedAtMs;
          }
        }

        const seg=(w)=>{
          if(!w||typeof w.pct!=="number") return null;
          const pct=Math.floor(w.pct);
          return {pct, s:pct+"% ↻"+left(w.at)};
        };
        const parts=[], a=seg(fh), b=seg(sd);
        let maxp=0;
        if(a){parts.push("5h "+a.s); maxp=Math.max(maxp,a.pct);}
        if(b){parts.push("wk "+b.s); maxp=Math.max(maxp,b.pct);}
        if(parts.length){
          usage=(cached?"~":"")+parts.join("  ");
          if(cached&&age>3600000) usage+=" (stale)";
          sev = maxp>=90?"crit":maxp>=75?"warn":"ok";
        }
      } catch(e){}

      process.stdout.write([m,dir,c,la,ld,usage,sev,eff].join("\t"));
    });
  ' 2>/dev/null
)
[ -z "$CURDIR" ] && CURDIR="$PWD"

# --- Colors ---
DIM=$'\e[2m'; RESET=$'\e[0m'
C_MODEL=$'\e[38;5;170m'   # purple
C_DIR=$'\e[38;5;39m'      # blue
C_GIT=$'\e[38;5;114m'     # green
C_DIRTY=$'\e[38;5;215m'   # orange
C_NODE=$'\e[38;5;107m'    # olive
C_COST=$'\e[38;5;180m'    # tan
C_USE_OK=$'\e[38;5;73m'   # teal   (<75%)
C_USE_WARN=$'\e[38;5;179m' # amber (75-89%)
C_USE_CRIT=$'\e[38;5;203m' # red   (>=90%)
SEP="${DIM} · ${RESET}"

# --- Directory (basename) ---
DIRNAME="$(basename "$CURDIR")"

# --- Git ---
GIT_SEG=""
if branch="$(git -C "$CURDIR" symbolic-ref --short HEAD 2>/dev/null)" || \
   branch="$(git -C "$CURDIR" rev-parse --short HEAD 2>/dev/null)"; then
  dirty=""
  [ -n "$(git -C "$CURDIR" status --porcelain 2>/dev/null)" ] && dirty="${C_DIRTY}●${RESET}"
  track=""
  if counts="$(git -C "$CURDIR" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)"; then
    behind="${counts%%	*}"; ahead="${counts##*	}"
    [ "$ahead" != "0" ]  && track="${track} ${DIM}↑${ahead}${RESET}"
    [ "$behind" != "0" ] && track="${track} ${DIM}↓${behind}${RESET}"
  fi
  GIT_SEG="${SEP}${C_GIT} ${branch}${RESET}${dirty:+ $dirty}${track}"
fi

# --- Node / pnpm ---
NODE_SEG=""
if nv="$(node -v 2>/dev/null)"; then
  nv="${nv#v}"; nv="${nv%.*}"   # 22.14.0 -> 22.14
  pv="$(pnpm -v 2>/dev/null)"
  NODE_SEG="${SEP}${C_NODE}node ${nv}${RESET}${pv:+${DIM} pnpm ${pv}${RESET}}"
fi

# --- Cost / lines ---
COST_SEG=""
costfmt="$(printf '%.2f' "${COST:-0}" 2>/dev/null || echo 0.00)"
if [ "$costfmt" != "0.00" ] || [ "${LADD:-0}" != "0" ] || [ "${LDEL:-0}" != "0" ]; then
  lines=""
  [ "${LADD:-0}" != "0" ] && lines="${lines} ${DIM}+${LADD}${RESET}"
  [ "${LDEL:-0}" != "0" ] && lines="${lines} ${DIM}-${LDEL}${RESET}"
  COST_SEG="${SEP}${C_COST}\$${costfmt}${RESET}${lines}"
fi

# --- Usage limits (5h session + weekly) ---
USE_SEG=""
if [ -n "$USAGE" ]; then
  case "$USAGE_SEV" in
    crit) uc="$C_USE_CRIT" ;;
    warn) uc="$C_USE_WARN" ;;
    *)    uc="$C_USE_OK" ;;
  esac
  USE_SEG="${SEP}${uc}${USAGE}${RESET}"
fi

# --- Model (+ live effort level) ---
MODEL_SEG="${C_MODEL} ${MODEL}${RESET}"
[ -n "$EFFORT" ] && MODEL_SEG="${MODEL_SEG}${DIM} ⚡${EFFORT}${RESET}"

# --- Emit ---
printf '%b%b%b%b%b%b\n' \
  "${MODEL_SEG}" \
  "${SEP}${C_DIR} ${DIRNAME}${RESET}" \
  "${GIT_SEG}" \
  "${NODE_SEG}" \
  "${USE_SEG}" \
  "${COST_SEG}"
