#!/bin/sh
# Ouvre une couleur, ne la ferme que 4 s plus tard : sert à vérifier qu'un `logs -f`
# lancé entre-temps restaure bien la couleur après le préfixe.
printf '\033[1;35mviolet A\n'
sleep 4
printf 'violet B\033[0m\n'
sleep 3600
