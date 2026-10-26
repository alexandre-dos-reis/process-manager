# Exemples et tests

Trois scénarios prêts à lancer. Aucun ne demande npm ou autre : seulement `sh`,
et `python3` pour le serveur HTTP de `basic/`.

## Préparation

```sh
zig build                      # depuis la racine du dépôt
export PATH="$PWD/zig-out/bin:$PATH"
```

Chaque dossier d'exemple a son propre démon et son propre `.zpawn`, donc on peut les
lancer l'un après l'autre sans qu'ils se mélangent. Termine toujours par `zpawn down` (ou lance `zpawn up` sans `-d` et fais Ctrl-C).

## 1. `basic/` : trois processus

```sh
cd examples/basic
zpawn up -d               # web, api, worker démarrent en arrière-plan
zpawn                     # tableau d'état
zpawn logs -f             # les trois mélangés, avec le préfixe « nom | » coloré
```

À observer : les codes `200` en vert, `404` en jaune, `500` en rouge de l'API, et les
jobs cyan du worker. Puis, dans un autre terminal ouvert dans le même dossier :

```sh
zpawn logs api -f         # un seul processus : sortie brute, sans préfixe
zpawn restart worker      # nouveau PID, compteur de relances inchangé
zpawn kill api            # état « stopped »
zpawn up -d               # relance api, « web unchanged » pour les autres
curl -s localhost:8000 | head -3
zpawn down
```

Le port se change avec `PORT=9000 zpawn up -d`.

## 0. `node/` : une vraie appli Node

Il faut `node` (aucun `npm install` : tout utilise la bibliothèque standard).

```sh
cd examples/node
zpawn up                   # attaché : migrate, api et worker défilent, Ctrl-C arrête
```

Dans un autre terminal :

```sh
curl localhost:3000/api/time
curl localhost:3000/nope        # 404 en jaune dans les logs
curl localhost:3000/api/boom    # 500 en rouge + stack sur stderr
zpawn logs api                  # sortie brute de l'API seule
zpawn kill api                  # SIGTERM : « arrêt en douceur... serveur fermé »
zpawn restart api
```

`migrate` est un script ponctuel (`restart: false`) : il passe à `exited` et reste ainsi.
`PORT=4000 zpawn up` change le port de l'API ; `api` et `worker` reçoivent chacun leurs
variables (`NODE_ENV`, `QUEUE`) depuis le YAML.

## 2. `colors/` : les couleurs ne doivent pas être tronquées

```sh
cd examples/colors
zpawn up -d
zpawn logs colors         # style, 16/256 couleurs, truecolor, unicode
zpawn logs                # avec préfixes : le bloc violet doit rester violet
zpawn down
```

Le bloc « début du bloc violet » ouvre une couleur sur une ligne et ne la ferme que
trois lignes plus tard. En vue globale, le préfixe `colors |` est inséré à chaque
ligne, et la couleur doit être réappliquée juste après : les lignes 1 et 2 restent
violettes, la 3 repasse en normal.

Pour relire le fichier de log brut avec les couleurs : `less -R .zpawn/logs/colors.log`.

## 3. `crashy/` : pannes et arrêts forcés

```sh
cd examples/crashy
zpawn up -d
zpawn                     # flaky passe en « restarting », steady reste « running »
zpawn logs flaky          # voir « exited with code 1 », « restarting in 2s », 4s, 8s…
zpawn kill stubborn       # ignore SIGTERM : prend ~5 s, puis SIGKILL
zpawn restart flaky       # sort de l'état « failed » (après 6 plantages rapides)
zpawn down
```

## Mesurer CPU et RAM

```sh
examples/bench.sh                    # Linux uniquement (lit /proc), ~40 s
NOLOG=1 examples/bench.sh            # même mesure sans écriture de logs sur disque
```

Il rapporte, pour le démon : réveils par seconde et CPU au repos, RAM, temps d'un
`zpawn ls`, puis le CPU par Mo de sortie traité quand un processus écrit en continu
(sans suiveur, avec `logs -f flood`, avec `logs -f` global).

## Tests automatiques

Ils sont dans [`../test/`](../test/README.md) : `test/run.sh` lance tout,
`test/examples.sh` rejoue les trois scénarios ci-dessus.

Un `.zpawn` créé dans `examples/` n'est jamais commité : il contient son propre
`.gitignore`.
