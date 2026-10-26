#!/bin/sh
# Tests de bout en bout de `health:` (commande de santé) avec depends_on.
#
#   test/health.sh [chemin/vers/zpawn]
. "$(dirname "$0")/lib.sh"

D="$TMP/health"
mkdir -p "$D"
watch "$D"
cd "$D" || exit 2

# The "slow" checks are scripts whose sleep duration is computed, and the patterns used to look
# for leftovers are computed too, so that nothing (not even a shell command line that embeds
# this file) contains the literal text pgrep searches for.
printf 'exec sleep $((31000 + 337))\n' > slow1.sh
printf 'exec sleep $((31000 + 338))\n' > slow2.sh
SLOW1="sleep $((31000 + 337))"
SLOW2="sleep $((31000 + 338))"

echo "== un service devient healthy, son dépendant démarre"
cat >zpawn.yaml <<'YAML'
processes:
  db:
    cmd: sleep 600
    health:
      cmd: test -f ready.flag
      interval: 1
  app:
    cmd: sleep 600
    depends_on: [db]
YAML
"$Z" up -d >up.out 2>&1
now "db démarre mais n'est pas prêt : starting" '[ "$(state_of db)" = starting ]'
now "app attend db" '[ "$(state_of app)" = waiting ] && grep -q "app .*waiting for db" up.out'
sleep 2.5
now "tant que le check échoue, app attend toujours" '[ "$(state_of app)" = waiting ]'
touch ready.flag
check "db passe healthy" '[ "$(state_of db)" = healthy ]' 12
check "app démarre ensuite" '[ "$(state_of app)" = running ]' 12
now "logs : la note healthy est écrite" '"$Z" logs db | grep -q "healthy"'
rm ready.flag
sleep 3
now "après succès, on ne revérifie plus (readiness, pas monitoring)" '[ "$(state_of db)" = healthy ]'
"$Z" restart db >/dev/null
check "restart de db : repasse par starting puis unhealthy/healthy selon le check" '[ "$(state_of db)" = starting ]'
touch ready.flag
check "db redevient healthy" '[ "$(state_of db)" = healthy ]' 12
now "up -d relancé : db unchanged" '"$Z" up -d | grep -q "db .*unchanged"'
"$Z" down >/dev/null

echo "== le check échoue trop de fois : unhealthy, le dépendant échoue"
rm -f ready.flag
cat >zpawn.yaml <<'YAML'
processes:
  db:
    cmd: sleep 600
    health:
      cmd: "false"
      interval: 1
      retries: 3
  app:
    cmd: sleep 600
    depends_on: [db]
YAML
"$Z" up -d >/dev/null
check "db devient unhealthy après 3 échecs" '[ "$(state_of db)" = unhealthy ]' 20
check "app passe en failed" '[ "$(state_of app)" = failed ]' 10
now "le message nomme db" '"$Z" logs app | grep -q "db failed"'
now "db reste en vie (on ne la tue pas)" '"$Z" ls | grep db | grep -q "unhealthy"'
"$Z" down >/dev/null

echo "== le check hérite du dossier et de l'env du service"
mkdir -p sub
cat >zpawn.yaml <<'YAML'
processes:
  db:
    cmd: sleep 600
    cwd: ./sub
    env:
      EXPECTED: yes-it-is
    health: 'test "$EXPECTED" = yes-it-is && test "$(basename "$PWD")" = sub'
YAML
"$Z" up -d >/dev/null
check "env et cwd du service visibles dans le check" '[ "$(state_of db)" = healthy ]' 12
"$Z" down >/dev/null

echo "== timeout : un check trop lent est tué"
cat >zpawn.yaml <<'YAML'
processes:
  db:
    cmd: sleep 600
    health:
      cmd: sh ./slow1.sh
      interval: 1
      timeout: 1
      retries: 2
YAML
"$Z" up -d >/dev/null
check "check trop lent : unhealthy" '[ "$(state_of db)" = unhealthy ]' 20
check "le check lent a été tué" '! pgrep -f "$SLOW1" >/dev/null'
"$Z" down >/dev/null

echo "== kill du service pendant un check : pas de processus orphelin"
cat >zpawn.yaml <<'YAML'
processes:
  db:
    cmd: sleep 600
    health:
      cmd: sh ./slow2.sh
      interval: 1
      timeout: 60
YAML
"$Z" up -d >/dev/null
check "le check est en cours" 'pgrep -f "$SLOW2" >/dev/null' 10
"$Z" kill db >/dev/null
check "kill : le check disparaît avec le service" '! pgrep -f "$SLOW2" >/dev/null' 10
now "db arrêtée" '[ "$(state_of db)" = stopped ]'
"$Z" down >/dev/null

echo "== erreurs de configuration"
printf 'processes:\n  m:\n    cmd: ls\n    restart: false\n    health: ls\n' > bad.yaml
now "health refusé sur un script ponctuel" '"$Z" up -d -f bad.yaml 2>&1 | grep -q "only for long-running"'
printf 'processes:\n  a:\n    cmd: ls\n    health:\n      cmd: ls\n      interval: 0\n' > bad.yaml
now "interval invalide" '"$Z" up -d -f bad.yaml 2>&1 | grep -q "health.interval"'

summary
