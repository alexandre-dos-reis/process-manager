#!/bin/sh
# Banc d'essai des couleurs : styles, 16/256 couleurs, truecolor, couleur ouverte
# sur plusieurs lignes, barre de progression avec \r, unicode.

printf '\033[1mStyles :\033[0m \033[1mgras\033[0m \033[2mdim\033[0m \033[3mitalique\033[0m \033[4msouligné\033[0m \033[7minversé\033[0m\n'

printf '16 couleurs : '
for c in 30 31 32 33 34 35 36 37 90 91 92 93 94 95 96 97; do printf '\033[%dm##\033[0m' "$c"; done
printf '\n'

printf '256 couleurs : '
i=16
while [ "$i" -le 231 ]; do printf '\033[48;5;%dm \033[0m' "$i"; i=$((i + 3)); done
printf '\n'

printf 'Truecolor : '
i=0
while [ "$i" -lt 256 ]; do printf '\033[48;2;%d;80;%dm \033[0m' "$i" $((255 - i)); i=$((i + 6)); done
printf '\n'

# Une couleur ouverte sur la ligne 1 et fermée sur la ligne 3 : avec le préfixe
# « colors | », la ligne 2 doit rester violette.
printf '\033[1;35mdébut du bloc violet\n'
printf 'ligne 2 toujours violette\n'
printf 'ligne 3 \033[0mfin du bloc\n'

printf 'Unicode : é à ü 漢字 🚀\n'

# Barre de progression réécrite avec \r
i=0
while [ "$i" -le 20 ]; do
  bar=$(printf '%*s' "$i" '' | tr ' ' '#')
  printf '\r[%-20s] %3d%%' "$bar" $((i * 5))
  i=$((i + 1))
  sleep 0.05
done
printf '\n'

while true; do
  printf '\033[2mheartbeat %s\033[0m\n' "$(date +%T)"
  sleep 3
done
