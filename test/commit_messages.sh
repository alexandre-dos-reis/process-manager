#!/bin/sh
# Teste scripts/check-commit-message.sh : messages acceptés et refusés.
#
#   test/commit_messages.sh
. "$(dirname "$0")/lib_light.sh"

C="$ROOT/scripts/check-commit-message.sh"

for m in \
  "feat: add up -d" \
  "fix(daemon): keep output after exit" \
  "feat(cli)!: remove the add command" \
  "chore(main): release 0.2.0" \
  "docs: update README" \
  "refactor(config.zig): simplify cwd join" \
  "Merge branch 'main' into feature" \
  "fixup! feat: add up -d"; do
  now "accepté : $m" "\"$C\" \"\$m\""
done

for m in \
  "Add a new command" \
  "feature: add up -d" \
  "feat:no space" \
  "feat: " \
  "feat(Scope): uppercase scope" \
  "fix : space before colon" \
  "" \
  "feat: $(printf 'x%.0s' $(seq 1 120))"; do
  now "refusé : ${m:-<vide>}" "! \"$C\" \"\$m\" 2>/dev/null"
done

printf 'feat: from a file\n\nbody line\n' > "$TMP/msg"
now "-f lit la première ligne du fichier" "\"$C\" -f \"$TMP/msg\""
printf 'oops\n' > "$TMP/msg"
now "-f refuse un fichier mal formé" "! \"$C\" -f \"$TMP/msg\" 2>/dev/null"

summary
