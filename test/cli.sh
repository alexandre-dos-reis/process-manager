#!/bin/sh
# Tests de bout en bout de chaque commande : init, up, up -d, down, kill, restart, logs, ls.
#
#   test/cli.sh [chemin/vers/zpawn]
#
# Prérequis : python3 (serveur HTTP du fichier généré par `init`).
. "$(dirname "$0")/lib.sh"

P="$TMP/proj"
mkdir -p "$P"
watch "$P"
cd "$P" || exit 2

echo "== aide et erreurs d'usage"
now "--version" '"$Z" --version | grep -q "^zpawn "'
now "-h liste les commandes" '"$Z" -h | grep -q "kill" && "$Z" -h | grep -q "up \[-d\]"'
now "la commande add n'existe plus" '! "$Z" -h | grep -q " add "'
"$Z" bogus >/dev/null 2>&1; rc=$?
now "commande inconnue : code 2" '[ "$rc" = 2 ]'
now "commande inconnue : message" '"$Z" bogus 2>&1 | grep -q "unknown command .bogus."'
"$Z" add web "sleep 1" >/dev/null 2>&1; rc=$?
now "zpawn add est refusé" '[ "$rc" = 2 ]'
now "option inconnue : message" '"$Z" up --nope 2>&1 | grep -q "Invalid argument"'
now "up -h décrit --detach" '"$Z" up -h | grep -q -- "--detach"'
now "kill -h décrit SERVICE" '"$Z" kill -h | grep -q "SERVICE"'
now "up sans fichier : message clair" '"$Z" up 2>&1 | grep -q "zpawn init"'
now "aucun démon créé par une erreur" '[ ! -S .pm/sock ]'
now "ls sans démon" '"$Z" ls | grep -q "daemon not running"'
now "kill sans démon : message" '"$Z" kill 2>&1 | grep -q "no daemon running"'

echo "== init"
now "init crée zpawn.yaml" '"$Z" init | grep -q created && [ -f zpawn.yaml ]'
now "init refuse d'écraser" '"$Z" init 2>&1 | grep -q "already exists"'
echo "# marqueur" >> zpawn.yaml
now "init --force réécrit" '"$Z" init --force >/dev/null && ! grep -q marqueur zpawn.yaml'
now "le fichier généré est valide" 'grep -q "^processes:" zpawn.yaml'

echo "== up -d"
start=$(date +%s)
"$Z" up -d >up1.out 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
now "rend la main (code 0, < 5 s)" '[ "$rc" = 0 ] && [ "$elapsed" -lt 5 ]'
now "annonce web et worker" 'grep -q "web .*started" up1.out && grep -q "worker .*started" up1.out'
check "2 processus en cours" '[ "$("$Z" ls | grep -c running)" = 2 ]'
check "le serveur HTTP répond" 'curl -fs "http://127.0.0.1:$PORT/" -o /dev/null'
now "dossier .pm avec .gitignore" '[ -f .pm/.gitignore ]'
now "up -d relancé : unchanged" '"$Z" up -d | grep -c unchanged | grep -q 2'
now "sans argument : tableau d'état" '"$Z" | grep -q worker'
now "depuis un sous-dossier" 'mkdir -p sub && (cd sub && "$Z" ls | grep -q web)'
now "up -f chemin explicite" 'printf "processes:\n  extra: sleep 600\n" > "$TMP/other.yaml" && "$Z" up -d -f "$TMP/other.yaml" | grep -q "extra .*started"'
now "up -f YAML invalide : erreur lisible" 'printf "processes:\n  x:\n    nope: 1\n" > "$TMP/bad.yaml"; "$Z" up -d -f "$TMP/bad.yaml" 2>&1 | grep -q "unknown key .nope."'
now "up -f fichier absent" '"$Z" up -d -f "$TMP/absent.yaml" 2>&1 | grep -q "cannot read"'
"$Z" kill extra >/dev/null

echo "== logs"
check "logs SERVICE : sortie brute, sans préfixe" '"$Z" logs worker | grep -q "^working" && ! "$Z" logs worker | grep -q "worker  *|"'
now "logs sans service : préfixe « nom | »" '"$Z" logs | grep -q "worker  *|"'
now "logs -n limite les lignes" '[ "$("$Z" logs worker -n 1 | wc -l)" -le 1 ]'
now "logs : service inconnu" '"$Z" logs ghost 2>&1 | grep -q "no process named"'
"$Z" logs worker -f -n 0 >follow.out 2>&1 &
FOLLOW=$!
check "logs -f reçoit la suite en direct" '[ "$(grep -c working follow.out)" -ge 2 ]' 30
kill "$FOLLOW" 2>/dev/null

echo "== kill"
before_web=$(pid_of web)
"$Z" kill worker | grep -q stopping
check "kill SERVICE : worker arrêté" '[ "$(state_of worker)" = stopped ]'
now "kill SERVICE : web intact" '[ "$(state_of web)" = running ] && [ "$(pid_of web)" = "$before_web" ]'
now "kill d'un service inconnu" '"$Z" kill ghost 2>&1 | grep -q "no process named"'
"$Z" kill >/dev/null
check "kill sans argument : tout est arrêté" '[ "$(state_of web)" = stopped ] && [ "$(state_of worker)" = stopped ] && [ "$(state_of extra)" = stopped ]'
now "le démon reste en vie après kill" '"$Z" ls | grep -q web'

echo "== restart"
"$Z" restart worker >/dev/null
check "restart SERVICE démarre un service arrêté" '[ "$(state_of worker)" = running ]'
now "web toujours arrêté" '[ "$(state_of web)" = stopped ]'
old=$(pid_of worker)
"$Z" restart worker >/dev/null
check "restart change le PID" '[ "$(pid_of worker)" != "$old" ] && [ "$(pid_of worker)" != - ]'
"$Z" restart >/dev/null
check "restart sans argument : tout tourne" '[ "$(state_of web)" = running ] && [ "$(state_of worker)" = running ] && [ "$(state_of extra)" = running ]'
now "restart d'un service inconnu" '"$Z" restart ghost 2>&1 | grep -q "no process named"'

echo "== down"
"$Z" down >/dev/null
check "down : plus de démon" '"$Z" ls | grep -q "daemon not running"'
now "down : socket supprimé" '[ ! -S .pm/sock ]'
now "down sans démon : sans erreur" '"$Z" down >/dev/null 2>&1'

echo "== up attaché (Ctrl-C)"
"$Z" up >attached.out 2>&1 &
UP=$!
check "les services tournent" '[ "$("$Z" ls | grep -c running)" = 2 ]'
check "la sortie est diffusée au terminal" 'grep -q "worker  *|" attached.out' 20
now "up attaché ne rend pas la main" 'kill -0 "$UP"'
kill -INT "$UP"
check "Ctrl-C : la commande se termine" '! kill -0 "$UP" 2>/dev/null'
now "Ctrl-C : annonce l'arrêt" 'grep -q "stopping" attached.out'
check "Ctrl-C : tout est arrêté" '"$Z" ls | grep -q "daemon not running"'
check "Ctrl-C : le serveur HTTP est coupé" '! curl -fs "http://127.0.0.1:$PORT/" -o /dev/null'
wait "$UP"; rc=$?
now "Ctrl-C : code de sortie 0" '[ "$rc" = 0 ]'

echo "== up attaché : arrêt par down depuis un autre terminal"
"$Z" up >attached2.out 2>&1 &
UP=$!
check "services démarrés" '[ "$("$Z" ls | grep -c running)" = 2 ]'
"$Z" down >/dev/null
check "la commande attachée se termine d'elle-même" '! kill -0 "$UP" 2>/dev/null'

summary
