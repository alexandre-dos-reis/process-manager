#!/bin/sh
# Test de fumée de bout en bout, sur une copie des exemples dans un dossier temporaire.
#
#   examples/smoke.sh [chemin/vers/zvisor]     (défaut : ../zig-out/bin/zvisor)
#   FULL=1 examples/smoke.sh                   ajoute le test SIGKILL (~7 s de plus)
#
# Prérequis : python3 (pour le serveur HTTP de basic/).

HERE=$(cd "$(dirname "$0")" && pwd)
Z=${1:-$HERE/../zig-out/bin/zvisor}
if [ ! -x "$Z" ]; then
  echo "binaire introuvable : $Z (lance d'abord : zig build)" >&2
  exit 2
fi
export Z
export PORT=${PORT:-18765}
ESC=$(printf '\033')
TMP=$(mktemp -d)
pass=0
fail=0

cleanup() {
  for d in basic colors crashy; do
    [ -d "$TMP/$d" ] && (cd "$TMP/$d" && "$Z" down >/dev/null 2>&1)
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

cp -R "$HERE/basic" "$HERE/colors" "$HERE/crashy" "$TMP"/

# check "description" 'condition shell' [essais de 0,5 s]
check() {
  tries=${3:-20}
  n=0
  while [ "$n" -lt "$tries" ]; do
    if eval "$2" >/dev/null 2>&1; then
      printf '  ok    %s\n' "$1"
      pass=$((pass + 1))
      return
    fi
    sleep 0.5
    n=$((n + 1))
  done
  printf '  ECHEC %s\n' "$1"
  fail=$((fail + 1))
}

state_of() { "$Z" ls | awk -v n="$1" '$2==n{print $3}'; }
pid_of() { "$Z" ls | awk -v n="$1" '$2==n{print $4}'; }

echo "== basic : 3 processus"
cd "$TMP/basic" || exit 2
mkdir -p sub
"$Z" up >/dev/null
check "3 processus en cours" '[ "$("$Z" ls | grep -c running)" = 3 ]'
check "le serveur HTTP répond" 'curl -fs "http://127.0.0.1:$PORT/" -o /dev/null'
check "dossier .pm créé avec logs et .gitignore" '[ -f .pm/.gitignore ] && [ -f .pm/logs/api.log ]'
check "couleurs intactes (ESC[32m...ESC[0m)" '"$Z" logs api -n 50 | grep -q "${ESC}\[32m200${ESC}\[0m"'
check "préfixe « api | » en vue globale" '"$Z" logs -n 10 | grep -q "api  *|"'
check "fonctionne depuis un sous-dossier" '(cd sub && "$Z" ls | grep -q web)'
check "un autre dossier est isolé" '(cd "$TMP" && "$Z" ls | grep -q "daemon not running")'
before=$(pid_of worker)
"$Z" restart worker >/dev/null
check "restart change le PID" '[ "$(pid_of worker)" != "$before" ] && [ "$(pid_of worker)" != - ]'
"$Z" stop api >/dev/null
check "stop met api à l'arrêt" '[ "$(state_of api)" = stopped ]'
check "up relance api et laisse web intact" '"$Z" up | grep -q "web .*unchanged"'
check "api tourne de nouveau" '[ "$(state_of api)" = running ]'
"$Z" rm worker >/dev/null
check "rm supprime worker" '! "$Z" ls | grep -q worker'
"$Z" down >/dev/null
check "down supprime le socket" '[ ! -S .pm/sock ]'

echo "== colors : séquences ANSI"
cd "$TMP/colors" || exit 2
"$Z" up >/dev/null
sleep 1
"$Z" logs -f -n 0 >"$TMP/follow.out" 2>&1 &
FOLLOW=$!
check "truecolor intact" '"$Z" logs colors -n 80 | grep -q "${ESC}\[48;2;"'
check "256 couleurs intactes" '"$Z" logs colors -n 80 | grep -q "${ESC}\[48;5;"'
check "unicode intact" '"$Z" logs colors -n 80 | grep -q "漢字"'
check "couleur multi-lignes restaurée après le préfixe" '"$Z" logs -n 80 | grep "ligne 2" | grep -q "${ESC}\[1;35mligne 2"'
check "couleur ouverte avant l'abonnement restaurée (logs -f tardif)" 'grep -q "${ESC}\[1;35mviolet B" "$TMP/follow.out"'
kill "$FOLLOW" 2>/dev/null
"$Z" down >/dev/null

echo "== crashy : pannes"
cd "$TMP/crashy" || exit 2
"$Z" up >/dev/null
check "flaky est relancé automatiquement" '[ "$(state_of flaky)" = restarting ]' 30
check "steady reste en vie" '[ "$(state_of steady)" = running ]'
if [ "${FULL:-0}" = 1 ]; then
  "$Z" stop stubborn >/dev/null
  check "stubborn tué par SIGKILL après le délai" '[ "$(state_of stubborn)" = stopped ]' 24
fi
"$Z" down >/dev/null
check "down propre : plus de démon" '"$Z" ls | grep -q "daemon not running"'

echo
echo "$pass réussis, $fail échecs"
[ "$fail" -eq 0 ]
