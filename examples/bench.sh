#!/bin/sh
# Mesure la consommation du DÉMON (Linux uniquement : lit /proc).
#
#   examples/bench.sh [chemin/vers/zpawn]
#
# Mesures :
#   - repos : CPU, réveils/s et RAM avec les 3 processus de basic/
#   - client : temps moyen d'un `zpawn ls`
#   - flot  : un processus qui écrit sans arrêt de la sortie colorée, sans suiveur,
#             avec `logs -f flood`, puis avec `logs -f` (vue globale préfixée).
#             On rapporte le CPU du démon par Mo de sortie traité, et la RAM finale.

HERE=$(cd "$(dirname "$0")" && pwd)
Z=${1:-$HERE/../zig-out/bin/zpawn}
[ -x "$Z" ] || { echo "binaire introuvable : $Z" >&2; exit 2; }
export Z PORT=${PORT:-18766}
TMP=$(mktemp -d)
TICK=$(getconf CLK_TCK)
IDLE_SECS=${IDLE_SECS:-10}
FLOOD_SECS=${FLOOD_SECS:-5}

cleanup() { (cd "$TMP/basic" 2>/dev/null && "$Z" down >/dev/null 2>&1); rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
cp -R "$HERE/basic" "$TMP"/
cd "$TMP/basic" || exit 2

dpid() { pgrep -f "daemon $TMP/basic/.pm" | head -1; }
ticks() { awk '{print $14 + $15}' "/proc/$1/stat"; }
ctxt() { awk '/voluntary_ctxt_switches/ && !/nonvoluntary/ {print $2}' "/proc/$1/status"; }
rss() { awk '/VmRSS/ {print $2}' "/proc/$1/status"; }
hwm() { awk '/VmHWM/ {print $2}' "/proc/$1/status"; }

# NOLOG=1 : on remplace .pm/logs par un fichier, donc le démon ne peut pas écrire de log disque.
if [ "${NOLOG:-0}" = 1 ]; then mkdir .pm && : >.pm/logs; fi
"$Z" up -d >/dev/null
sleep 3
P=$(dpid)
[ -n "$P" ] || { echo "démon introuvable" >&2; exit 2; }

echo "binaire : $Z ($(wc -c <"$Z" | awk '{printf "%.1f", $1/1048576}') Mo)"
echo

# --- repos
t0=$(ticks "$P"); c0=$(ctxt "$P")
sleep "$IDLE_SECS"
t1=$(ticks "$P"); c1=$(ctxt "$P")
awk -v t="$((t1 - t0))" -v tick="$TICK" -v s="$IDLE_SECS" -v c="$((c1 - c0))" 'BEGIN {
  printf "repos (3 processus, %ds) : CPU %.2f ms/s, %.1f réveils/s\n", s, t / tick * 1000 / s, c / s }'
printf 'RAM au repos : %s Ko\n' "$(rss "$P")"

# --- latence du client
n=50
s0=$(date +%s%N)
i=0
while [ "$i" -lt "$n" ]; do "$Z" ls >/dev/null; i=$((i + 1)); done
s1=$(date +%s%N)
awk -v a="$s0" -v b="$s1" -v n="$n" 'BEGIN { printf "client : %.2f ms par `zpawn ls`\n", (b - a) / n / 1e6 }'

# --- flot de sortie
# le processus « flood » est ajouté au YAML de la copie, puis `up -d` le démarre
cat >flood.sh <<'SH'
exec yes "$(printf '\033[32mhello world, this is colored output\033[0m')"
SH
printf '  flood: sh ./flood.sh\n' >>zpawn.yaml
"$Z" up -d >/dev/null
sleep 1
"$Z" kill flood >/dev/null; sleep 1

# Octets écrits par tout le groupe de processus d'un processus (via /proc/PID/io).
group_wchar() {
  for q in $(pgrep -g "$1"); do awk '/^wchar/ {print $2}' "/proc/$q/io" 2>/dev/null; done |
    awk '{s += $1} END {print s + 0}'
}

run_flood() { # $1 = libellé ; le suiveur éventuel est lancé par l'appelant
  "$Z" restart flood >/dev/null
  sleep 1
  g=$("$Z" ls | awk '$2=="flood" {print $4}')
  w0=$(group_wchar "$g"); t0=$(ticks "$P")
  sleep "$FLOOD_SECS"
  w1=$(group_wchar "$g"); t1=$(ticks "$P")
  "$Z" kill flood >/dev/null
  awk -v l="$1" -v t="$((t1 - t0))" -v tick="$TICK" -v s="$FLOOD_SECS" -v b="$((w1 - w0))" 'BEGIN {
    mb = b / 1048576
    printf "flot %-24s : %6.1f Mo/s, CPU démon %5.0f ms/s, %6.0f ms par Mo\n", l, mb / s, t / tick * 1000 / s, (mb > 0 ? t / tick * 1000 / mb : 0) }'
  sleep 2
}

run_flood "sans suiveur"

"$Z" logs flood -f -n 0 >/dev/null 2>&1 &
F1=$!
sleep 0.5
run_flood "logs -f flood (brut)"
kill "$F1" 2>/dev/null; wait "$F1" 2>/dev/null

"$Z" logs -f -n 0 >/dev/null 2>&1 &
F2=$!
sleep 0.5
run_flood "logs -f (préfixé)"
kill "$F2" 2>/dev/null; wait "$F2" 2>/dev/null

sleep 1
printf 'RAM après les flots : %s Ko (pic %s Ko)\n' "$(rss "$P")" "$(hwm "$P")"
