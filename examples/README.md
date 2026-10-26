# Exemples et tests

Trois scénarios prêts à lancer. Aucun ne demande npm ou autre : seulement `sh`,
et `python3` pour le serveur HTTP de `basic/`.

## Préparation

```sh
zig build                      # depuis la racine du dépôt
export PATH="$PWD/zig-out/bin:$PATH"
```

Chaque dossier d'exemple a son propre démon et son propre `.pm`, donc on peut les
lancer l'un après l'autre sans qu'ils se mélangent. Termine toujours par `zvisor down`.

## 1. `basic/` : trois processus

```sh
cd examples/basic
zvisor up                  # web, api, worker démarrent
zvisor                     # tableau d'état
zvisor logs -f             # les trois mélangés, avec le préfixe « nom | » coloré
```

À observer : les codes `200` en vert, `404` en jaune, `500` en rouge de l'API, et les
jobs cyan du worker. Puis, dans un autre terminal ouvert dans le même dossier :

```sh
zvisor logs api -f         # un seul processus : sortie brute, sans préfixe
zvisor restart worker      # nouveau PID, compteur de relances inchangé
zvisor stop api            # état « stopped »
zvisor up                  # relance api, « web unchanged » pour les autres
curl -s localhost:8000 | head -3
zvisor down
```

Le port se change avec `PORT=9000 zvisor up`.

## 2. `colors/` : les couleurs ne doivent pas être tronquées

```sh
cd examples/colors
zvisor up
zvisor logs colors         # style, 16/256 couleurs, truecolor, unicode
zvisor logs                # avec préfixes : le bloc violet doit rester violet
zvisor down
```

Le bloc « début du bloc violet » ouvre une couleur sur une ligne et ne la ferme que
trois lignes plus tard. En vue globale, le préfixe `colors |` est inséré à chaque
ligne, et la couleur doit être réappliquée juste après : les lignes 1 et 2 restent
violettes, la 3 repasse en normal.

Pour relire le fichier de log brut avec les couleurs : `less -R .pm/logs/colors.log`.

## 3. `crashy/` : pannes et arrêts forcés

```sh
cd examples/crashy
zvisor up
zvisor                     # flaky passe en « restarting », steady reste « running »
zvisor logs flaky          # voir « exited with code 1 », « restarting in 2s », 4s, 8s…
zvisor stop stubborn       # ignore SIGTERM : prend ~5 s, puis SIGKILL
zvisor restart flaky       # sort de l'état « failed » (après 6 plantages rapides)
zvisor down
```

## Test automatique

```sh
examples/smoke.sh              # ~20 s
FULL=1 examples/smoke.sh       # ajoute le test SIGKILL (~7 s de plus)
examples/smoke.sh /chemin/vers/zvisor
```

Le script copie les exemples dans un dossier temporaire, joue les trois scénarios,
vérifie le résultat (processus lancés, couleurs intactes, restauration après le
préfixe, isolation entre dossiers, relance automatique, arrêt propre) et nettoie
tout. Code de sortie `0` si tout passe. Variable utile : `PORT` (par défaut 18765)
si ce port est déjà pris.

Un `.pm` créé dans `examples/` n'est jamais commité : il contient son propre
`.gitignore`.
