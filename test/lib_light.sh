# Variante de lib.sh pour les tests qui n'ont pas besoin du binaire zpawn.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
pass=0
fail=0
trap 'rm -rf "$TMP"' EXIT INT TERM

now() {
  if eval "$2" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '  ECHEC %s\n' "$1"
    fail=$((fail + 1))
  fi
}

summary() {
  echo
  echo "$pass réussis, $fail échecs"
  [ "$fail" -eq 0 ]
}
