#!/bin/sh
# Simule une API : une ligne de log colorée par requête (vert, jaune, rouge).
i=0
while true; do
  i=$((i + 1))
  ms=$((i * 7 % 90 + 10))
  case $((i % 4)) in
    0) printf '\033[31m500\033[0m GET  /checkout     \033[2m%dms\033[0m\n' "$ms" ;;
    1) printf '\033[32m200\033[0m GET  /users        \033[2m%dms\033[0m\n' "$ms" ;;
    2) printf '\033[32m200\033[0m POST /login        \033[2m%dms\033[0m\n' "$ms" ;;
    3) printf '\033[33m404\033[0m GET  /favicon.ico  \033[2m%dms\033[0m\n' "$ms" ;;
  esac
  sleep 1
done
