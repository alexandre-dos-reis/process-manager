# zpawn

Un gestionnaire de processus minimaliste en Zig, sur le modèle client/serveur de
supervisor (un démon + une CLI qui lui parle par socket Unix), en plus simple.

- **Un seul binaire** : `zpawn daemon` et le client sont le même exécutable.
- **Le démon se lance tout seul** à la première commande `add` ou `up`.
- **Les couleurs ne sont jamais tronquées** : chaque processus tourne dans un PTY,
  donc il croit écrire dans un terminal et garde ses couleurs. Les octets sont
  stockés et renvoyés tels quels, sans filtrage ni réécriture.
- Redémarrage automatique avec backoff, arrêt propre (SIGTERM puis SIGKILL après 5 s,
  sur tout le groupe de processus), logs en mémoire et sur disque.

Le fonctionnement interne est décrit dans [ARCHITECTURE.md](ARCHITECTURE.md).
Des scénarios à lancer (3 processus, couleurs, pannes) et un test automatique sont dans
[examples/](examples/README.md).

## Compiler

```sh
zig build                       # défaut : ReleaseSmall, strippé, musl statique sous Linux (~270 Ko)
zig build -Doptimize=fast       # plus rapide, un peu plus gros (debug | safe | fast | small)
# résultat : zig-out/bin/zpawn
```

Testé avec Zig 0.17.0 sous Linux. Le code contient des constantes pour macOS
mais **n'y a pas été testé**.

## Utilisation

```sh
zpawn add web python3 -m http.server 8000   # définit et démarre
zpawn add --cwd ~/app --no-restart job "make build | tee build.log"
zpawn up                                    # lit ./zpawn.yaml (ou zpawn.yml, ou un chemin)
zpawn                                       # ou `zpawn ls` : tableau d'état coloré
zpawn logs web -f                           # sortie brute, couleurs intactes
zpawn logs -f                               # tous les processus, préfixe « nom | » coloré
zpawn logs web -n 500
zpawn restart web | stop web | start web | rm web   (ou `all`)
zpawn down                                  # arrête tout et quitte le démon
```

Règle de quoting : un seul argument après le nom est exécuté tel quel par `sh -c`
(les pipes, `&&`, variables fonctionnent) ; plusieurs arguments sont protégés
individuellement.

`zpawn up` relance seulement ce qui a changé (« unchanged » sinon).

### Le fichier `zpawn.yaml`

```yaml
processes:
  web: "python3 -m http.server ${PORT:-8000}"   # forme courte : juste la commande
  worker:
    cmd: sh ./worker.sh        # obligatoire
    cwd: ./jobs                # facultatif, relatif au fichier (défaut : son dossier)
    restart: false             # facultatif, défaut true
    env:                       # facultatif, s'ajoute à l'environnement du client
      WORKER_NAME: billing
```

Entoure la commande de guillemets (`"…"` ou `'…'`) dès qu'elle contient `{`, `}`, `"`,
`#` ou `: `. Les blocs `|` et `>` ne sont pas gérés par le parseur. Les clés inconnues
sont refusées avec un message qui indique la ligne.

Le YAML est lu **par le client uniquement** (bibliothèque
[zig-yaml](vendor/zig-yaml/README.md), copiée dans `vendor/`) : le démon ne l'embarque
pas dans son fonctionnement et son empreinte mémoire ne change pas.

## Où sont les données

Rien n'est écrit dans le home. L'état est dans un dossier **`.pm` du répertoire
courant** : `sock`, `daemon.log`, `logs/<nom>.log` (sortie brute avec couleurs,
rotation à 10 Mo → `.log.1`) et un `.gitignore` interne (`*`) pour ne pas le
committer. Pour relire un log avec couleurs : `less -R .pm/logs/web.log`.

- Il y a **un démon par projet** : deux dossiers différents = deux gestionnaires
  indépendants.
- Comme git, `zpawn` remonte les dossiers parents pour trouver un `.pm` actif :
  `zpawn ls` fonctionne depuis un sous-dossier du projet. `add` / `up` créent
  `.pm` dans le dossier où tu les lances s'il n'y en a pas.
- `$ZPAWN_HOME` force un autre emplacement.

## Limites connues

- Les commandes sont exécutées par `/bin/sh -c`, avec l'environnement du client
  qui a fait `add`/`up` (PATH inclus).
- Pas d'`attach` interactif (envoi de touches au processus) pour l'instant.
- Après 6 plantages rapides d'affilée (< 3 s), un processus passe en `failed`
  jusqu'à un `restart` manuel.
- Le préfixe `nom |` est ajouté à chaque ligne en mode « tous les processus » ;
  la couleur active est réappliquée après le préfixe. Les lignes de plusieurs
  processus qui se mélangent au milieu d'une ligne ne sont pas réordonnées.
