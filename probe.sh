#!/usr/bin/env bash
#
# probe.sh — check every public Palavir URL from wherever this runs, and write a
# machine-readable verdict.
#
# It exists to answer ONE question the ~95 Uptime Kuma monitors cannot: every one of
# those runs on docker01, inside the house, so "our internet died" and "the site died"
# produce the identical red. This runs on a GitHub runner instead.
#
# ⛔ A FAILED PROBE IS A FACT ABOUT THIS RUNNER UNTIL PROVEN OTHERWISE. Every target is
# retried, and a run in which EVERY target fails is reported as "prober" — GitHub's
# egress or DNS broke — not as nine simultaneous site outages. Same rule the tailnet
# watcher and the HA bridge use: a degraded collector must never publish a confident
# verdict about the world.
#
# Exit 0 = every target healthy (or prober-degraded, which is not the sites' fault).
# Exit 1 = at least one target down while others answered.   <- the real alarm
#
set -u

CONF="${1:-urls.json}"
OUT="${2:-status.json}"
ATTEMPTS="${PROBE_ATTEMPTS:-2}"
GAP="${PROBE_GAP:-6}"
TIMEOUT="${PROBE_TIMEOUT:-20}"

command -v jq >/dev/null || { echo "probe: jq is required" >&2; exit 2; }
[ -r "$CONF" ] || { echo "probe: cannot read $CONF" >&2; exit 2; }

# One target, up to $ATTEMPTS tries. Prints "<code> <seconds> <tries>".
# -L is deliberate: a 308 chain that lands on 200 is a healthy site, and several of
# these domains redirect apex -> www or http -> https.
probe_one() {
  local url="$1" code ms try out
  for try in $(seq 1 "$ATTEMPTS"); do
    out=$(curl -sS -o /dev/null -L --max-time "$TIMEOUT" \
            -w '%{http_code} %{time_total}' \
            -A 'palavir-status-probe (+https://github.com/joshmeee/palavir-status)' \
            "$url" 2>/dev/null) || out="000 0"
    code=${out%% *}; ms=${out##* }
    if [ "$code" != "000" ]; then echo "$code $ms $try"; return; fi
    [ "$try" -lt "$ATTEMPTS" ] && sleep "$GAP"
  done
  echo "000 0 $ATTEMPTS"
}

results='[]'
total=0; ok=0; unreachable=0

while IFS=$'\t' read -r name url expect; do
  [ -z "${name:-}" ] && continue
  total=$((total + 1))
  read -r code secs tries <<<"$(probe_one "$url")"

  # An expected-status list, not a hardcoded 200: a health endpoint is free to answer
  # 204, and a login page that answers 302 is not an outage.
  if jq -e --arg c "$code" 'map(tostring) | index($c) != null' >/dev/null 2>&1 <<<"$expect"; then
    good=true; ok=$((ok + 1))
  else
    good=false
    [ "$code" = "000" ] && unreachable=$((unreachable + 1))
  fi

  results=$(jq -c \
    --arg name "$name" --arg url "$url" --arg code "$code" \
    --argjson ms "$(awk -v s="$secs" 'BEGIN{printf "%d", s*1000}')" \
    --argjson tries "$tries" --argjson good "$good" \
    '. + [{name:$name, url:$url, code:($code|tonumber), ms:$ms, tries:$tries, ok:$good}]' \
    <<<"$results")
done < <(jq -r '.targets[] | [.name, .url, (.expect|tostring)] | @tsv' "$CONF")

down=$((total - ok))

# The degraded branch. If nothing at all answered, this runner could not reach the
# internet; publishing "all nine products are down" from that would be a lie that
# trains the red out of the wall.
if [ "$total" -gt 1 ] && [ "$unreachable" -eq "$total" ]; then
  verdict="prober"; exit_code=0
elif [ "$down" -gt 0 ]; then
  verdict="down"; exit_code=1
else
  verdict="ok"; exit_code=0
fi

jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg verdict "$verdict" \
  --arg vantage "${PROBE_VANTAGE:-github-actions}" \
  --arg run_url "${PROBE_RUN_URL:-}" \
  --argjson total "$total" --argjson ok "$ok" --argjson down "$down" \
  --argjson results "$results" \
  '{generated_at:$generated_at, vantage:$vantage, verdict:$verdict,
    total:$total, up:$ok, down:$down, run_url:$run_url,
    down_names:($results | map(select(.ok|not) | .name)),
    results:$results}' > "$OUT"

echo "probe: verdict=$verdict up=$ok/$total -> $OUT"
jq -r '.results[] | "  \(if .ok then "ok  " else "DOWN" end) \(.code|tostring|(. + "   ")[0:4]) \(.ms)ms  \(.name)"' "$OUT"
exit "$exit_code"
