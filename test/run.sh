#!/bin/sh
# Lance toute la batterie : tests unitaires Zig, puis tests de bout en bout.
#
#   test/run.sh                 rapide
#   FULL=1 test/run.sh          avec le test SIGKILL
#
# Il compile d'abord (zig build). Variable utile : PORT (défaut 18765).
cd "$(dirname "$0")/.." || exit 2
ZIG=${ZIG:-zig}
command -v "$ZIG" >/dev/null 2>&1 || ZIG="python3 -m ziglang"
rc=0

echo "######## build"
$ZIG build || exit 1
echo "######## tests unitaires (test/config_test.zig)"
$ZIG build test --summary all || rc=1
echo "######## messages de commit (test/commit_messages.sh)"
sh test/commit_messages.sh || rc=1
echo "######## tests CLI (test/cli.sh)"
sh test/cli.sh || rc=1
echo "######## depends_on (test/depends.sh)"
sh test/depends.sh || rc=1
echo "######## exemples (test/examples.sh)"
sh test/examples.sh || rc=1

echo
[ "$rc" -eq 0 ] && echo "TOUT PASSE" || echo "DES TESTS ONT ÉCHOUÉ"
exit "$rc"
