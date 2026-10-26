# Helpers shared by test/*.sh (sourced, not executed).
#
#   Binary: $ZPAWN, else the first argument of the calling script, else ../zig-out/bin/zpawn.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZPAWN:-${1:-$ROOT/zig-out/bin/zpawn}}
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
CLEAN_DIRS=""

# Stops every daemon started under $TMP, then removes it.
cleanup() {
  for d in $CLEAN_DIRS; do
    [ -d "$d" ] && (cd "$d" && "$Z" down >/dev/null 2>&1)
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# watch DIR : make sure a daemon started in DIR is stopped at the end.
watch() { CLEAN_DIRS="$CLEAN_DIRS $1"; }

# check "description" 'condition shell' [tries of 0.5 s]
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

# Instant check, for things that must hold right now (exit codes, messages).
now() {
  if eval "$2" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '  ECHEC %s\n' "$1"
    fail=$((fail + 1))
  fi
}

state_of() { "$Z" ls | awk -v n="$1" '$2==n{print $3}'; }
pid_of() { "$Z" ls | awk -v n="$1" '$2==n{print $4}'; }

summary() {
  echo
  echo "$pass réussis, $fail échecs"
  [ "$fail" -eq 0 ]
}
