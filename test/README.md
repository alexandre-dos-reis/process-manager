# Tests

Aucun test n'est écrit dans `src/` : tout est ici.

| Fichier | Quoi | Lancer |
|---|---|---|
| `config_test.zig` | Tests unitaires du chargeur `zpawn.yaml` (forme courte/longue, `cwd`, `env`, `restart`, `depends_on`, cycles, ordre, guillemets, erreurs et leurs messages) | `zig build test` |
| `fmt_test.zig` | Préfixes et couleurs : début de ligne, `\r`, couleur ré-appliquée, reset, séquences coupées entre deux lectures, aucun octet perdu | `zig build test` |
| `ring_test.zig` | Historique circulaire : croissance, bouclage, plafond, comparaison avec une référence aléatoire | `zig build test` |
| `cli.sh` | Chaque commande de bout en bout : `init`, `up`, `up -d`, `up` attaché + Ctrl-C, `down`, `kill`, `restart`, `logs`, `ls`, codes de sortie et messages d'erreur | `test/cli.sh` |
| `health.sh` | Commandes de santé : starting/healthy, dépendant qui attend, unhealthy après N échecs, env et dossier du service, timeout, essai tué avec le service, erreurs de config | `test/health.sh` |
| `depends.sh` | `depends_on` de bout en bout : attente, chaîne, service ou script ponctuel, dépendance qui échoue, `kill` d'un processus en attente, erreurs de config | `test/depends.sh` |
| `examples.sh` | Les scénarios de `examples/` : 3 processus, couleurs intactes, restauration après préfixe, pannes et relances (`FULL=1` ajoute le SIGKILL) | `test/examples.sh` |
| `commit_messages.sh` | Le vérificateur Conventional Commits (`scripts/check-commit-message.sh`) : messages acceptés et refusés | `test/commit_messages.sh` |
| `lib.sh` | Fonctions partagées par les scripts (`check`, `now`, nettoyage des démons) | (sourcé) |
| `run.sh` | Tout, dans l'ordre : build, unitaires, CLI, exemples | `test/run.sh` |

Les scripts acceptent un chemin de binaire (`test/cli.sh /chemin/zpawn`) ou `$ZPAWN`.
Prérequis : `sh`, `python3` (serveur HTTP) et `curl`. `PORT` (défaut 18765) change le
port de test si besoin. Chaque script travaille dans un dossier temporaire et arrête
ses démons à la fin.
