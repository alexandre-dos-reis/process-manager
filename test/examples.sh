#!/bin/sh
# Rejoue les trois scénarios de examples/ (copiés dans un dossier temporaire).
#
#   test/examples.sh [chemin/vers/zpawn]
#   FULL=1 test/examples.sh                    ajoute le test SIGKILL (~7 s de plus)
#
# Prérequis : python3 (serveur HTTP de basic/).
. "$(dirname "$0")/lib.sh"

cp -R "$ROOT/examples/basic" "$ROOT/examples/colors" "$ROOT/examples/crashy" "$TMP"/
for d in basic colors crashy; do watch "$TMP/$d"; done

echo "== basic : 3 processus"
cd "$TMP/basic" || exit 2
"$Z" up -d >/dev/null
check "3 processus en cours" '[ "$("$Z" ls | grep -c running)" = 3 ]'
check "le serveur HTTP répond" 'curl -fs "http://127.0.0.1:$PORT/" -o /dev/null'
check "dossier .zpawn créé avec logs et .gitignore" '[ -f .zpawn/.gitignore ] && [ -f .zpawn/logs/api.log ]'
check "couleurs intactes (ESC[32m...ESC[0m)" '"$Z" logs api -n 50 | grep -q "${ESC}\[32m200${ESC}\[0m"'
check "préfixe « api | » en vue globale" '"$Z" logs -n 10 | grep -q "api  *|"'
check "env du YAML transmis au worker" '"$Z" logs worker -n 50 | grep -q "worker billing"'
now "un autre dossier est isolé" '(cd "$TMP" && "$Z" ls | grep -q "daemon not running")'
"$Z" kill api >/dev/null
check "kill met api à l'arrêt" '[ "$(state_of api)" = stopped ]'
now "up -d relance api et laisse web intact" '"$Z" up -d | grep -q "web .*unchanged"'
check "api tourne de nouveau" '[ "$(state_of api)" = running ]'
"$Z" down >/dev/null
check "down supprime le socket" '[ ! -S .zpawn/sock ]'

echo "== colors : séquences ANSI"
cd "$TMP/colors" || exit 2
"$Z" up -d >/dev/null
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
"$Z" up -d >/dev/null
check "flaky est relancé automatiquement" '[ "$(state_of flaky)" = restarting ]' 30
check "steady reste en vie" '[ "$(state_of steady)" = running ]'
if [ "${FULL:-0}" = 1 ]; then
  "$Z" kill stubborn >/dev/null
  check "stubborn tué par SIGKILL après le délai" '[ "$(state_of stubborn)" = stopped ]' 24
fi
"$Z" down >/dev/null
check "down propre : plus de démon" '"$Z" ls | grep -q "daemon not running"'

summary
