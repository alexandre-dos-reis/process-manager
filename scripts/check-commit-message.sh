#!/bin/sh
# Vérifie qu'un message de commit suit Conventional Commits (https://www.conventionalcommits.org).
#
#   scripts/check-commit-message.sh "feat(logs): add --since"      (message en argument)
#   scripts/check-commit-message.sh -f .git/COMMIT_EDITMSG         (message dans un fichier)
#
# Format de la première ligne :  type(scope)!: description
#   types : feat fix perf refactor docs test build ci chore style revert
#   scope et « ! » (changement cassant) sont facultatifs ; description : 1 à 100 caractères.
# Les merges (« Merge ... ») et les « fixup!/squash! » sont ignorés.

if [ "$1" = "-f" ]; then
  subject=$(sed -n '1p' "$2")
else
  subject=$(printf '%s\n' "$1" | sed -n '1p')
fi

case "$subject" in
  "Merge "* | "fixup! "* | "squash! "*) exit 0 ;;
esac

if printf '%s\n' "$subject" | grep -Eq '^(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([a-z0-9._/-]+\))?!?: [^ ].{0,99}$'; then
  exit 0
fi

cat >&2 <<MSG
Message de commit refusé : « $subject »

Il doit suivre Conventional Commits :  type(scope)!: description
  types   : feat fix perf refactor docs test build ci chore style revert
  exemples: feat(logs): add --since
            fix: keep colors after a restart
            feat!: rename the state directory
MSG
exit 1
