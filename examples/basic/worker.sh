#!/bin/sh
# Simule un worker de file d'attente.
i=0
echo "worker ${WORKER_NAME:-?} prêt"
while true; do
  i=$((i + 1))
  if [ $((i % 5)) -eq 0 ]; then
    printf '\033[1;33mjob #%d : lent (retry)\033[0m\n' "$i"
  else
    printf '\033[36mjob #%d\033[0m traité\n' "$i"
  fi
  sleep 1.5
done
