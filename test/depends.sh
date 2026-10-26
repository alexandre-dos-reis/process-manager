#!/bin/sh
# Tests de bout en bout de `depends_on` : attente, chaîne, dépendance qui échoue, erreurs de config.
#
#   test/depends.sh [chemin/vers/zpawn]
. "$(dirname "$0")/lib.sh"

D="$TMP/deps"
mkdir -p "$D"
watch "$D"
cd "$D" || exit 2

cat >setup.sh <<'SH'
sleep 2
echo "setup terminé"
SH
cat >badsetup.sh <<'SH'
sleep 1
echo "setup raté" >&2
exit 3
SH

echo "== attente d'un script ponctuel"
cat >zpawn.yaml <<'YAML'
processes:
  setup:
    cmd: sh ./setup.sh
    restart: false
  app:
    cmd: sleep 600
    depends_on: [setup]
  late:
    cmd: sleep 600
    depends_on:
      - app
  free: sleep 600
YAML
"$Z" up -d >up.out 2>&1
now "up -d annonce l'attente" 'grep -q "app .*waiting for setup" up.out'
now "la chaîne attend aussi (late attend app)" 'grep -q "late .*waiting" up.out'
now "ls montre l'état waiting" '[ "$(state_of app)" = waiting ] && [ "$(state_of late)" = waiting ]'
now "un service sans dépendance démarre tout de suite" '[ "$(state_of free)" = running ]'
now "le script ponctuel tourne" '[ "$(state_of setup)" = running ]'
now "logs : la raison de l'attente est notée" '"$Z" logs app | grep -q "waiting for setup"'
check "app démarre quand setup a fini avec succès" '[ "$(state_of app)" = running ]' 20
check "late démarre ensuite (chaîne)" '[ "$(state_of late)" = running ]' 20
now "setup reste terminé (exited 0), pas relancé" '"$Z" ls | grep "setup" | grep -q "exited (0)"'
"$Z" down >/dev/null

echo "== dépendance sur un service (restart: true)"
cat >zpawn.yaml <<'YAML'
processes:
  db: sleep 600
  web:
    cmd: sleep 600
    depends_on: [db]
YAML
"$Z" up -d >/dev/null
check "web démarre dès que db tourne" '[ "$(state_of db)" = running ] && [ "$(state_of web)" = running ]'
"$Z" down >/dev/null

echo "== dépendance qui échoue"
cat >zpawn.yaml <<'YAML'
processes:
  setup:
    cmd: sh ./badsetup.sh
    restart: false
  app:
    cmd: sleep 600
    depends_on: [setup]
YAML
"$Z" up -d >/dev/null
check "app passe en failed" '[ "$(state_of app)" = failed ]' 20
now "le message nomme la dépendance fautive" '"$Z" logs app | grep -q "setup failed"'
now "setup montre son code de sortie" '"$Z" ls | grep setup | grep -q "exited (3)"'
sed -i 's/exit 3/exit 0/' badsetup.sh
"$Z" restart setup >/dev/null
check "après correction, restart de la dépendance puis du dépendant" '"$Z" restart app >/dev/null 2>&1; [ "$(state_of app)" = running ]' 20
"$Z" down >/dev/null

echo "== kill d'un service en attente"
cat >zpawn.yaml <<'YAML'
processes:
  setup:
    cmd: sh ./setup.sh
    restart: false
  app:
    cmd: sleep 600
    depends_on: [setup]
YAML
"$Z" up -d >/dev/null
now "app attend" '[ "$(state_of app)" = waiting ]'
"$Z" kill app >/dev/null
now "kill met app à l'arrêt" '[ "$(state_of app)" = stopped ]'
sleep 3
now "app ne démarre pas toute seule après coup" '[ "$(state_of app)" = stopped ]'
"$Z" restart app >/dev/null
now "restart démarre app (setup est terminé)" '[ "$(state_of app)" = running ]'
"$Z" down >/dev/null

echo "== restart d'une dépendance déjà satisfaite"
"$Z" up -d >/dev/null
check "tout est en place" '[ "$(state_of app)" = running ]' 20
now "up -d relancé : app unchanged" '"$Z" up -d | grep -q "app .*unchanged"'
"$Z" down >/dev/null

echo "== erreurs de configuration"
printf 'processes:\n  a:\n    cmd: ls\n    depends_on: [ghost]\n' > bad1.yaml
now "dépendance inconnue" '"$Z" up -d -f bad1.yaml 2>&1 | grep -q "unknown process .ghost."'
printf 'processes:\n  a:\n    cmd: ls\n    depends_on: [b]\n  b:\n    cmd: ls\n    depends_on: [a]\n' > bad2.yaml
now "cycle" '"$Z" up -d -f bad2.yaml 2>&1 | grep -q "cycle"'
now "aucune erreur de config ne lance de démon" '[ ! -S .zpawn/sock ]'

summary
