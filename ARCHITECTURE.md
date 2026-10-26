# Architecture

zvisor est **un seul binaire qui joue deux rôles** : un *démon* qui possède les
processus, et un *client* (la CLI) qui lui envoie des ordres par socket Unix.
C'est le modèle de supervisor (`supervisord` + `supervisorctl`), avec un protocole
texte minimal à la place de XML-RPC.

```
  zvisor add web ...                                   .pm/
  zvisor logs -f      ┌──────────────┐  socket Unix   ├── sock
  zvisor ls     ────► │   client     │ ─────────────► ├── daemon.log
                      │ (main.zig)   │ ◄───────────── └── logs/web.log
                      └──────────────┘   réponse
                                                  ┌─────────────────────────┐
                                                  │ démon (daemon.zig)      │
                                                  │ boucle poll() unique    │
                                                  │                         │
                                                  │  Proc "web" ◄─► PTY ◄─► sh -c "..."
                                                  │  Proc "api" ◄─► PTY ◄─► sh -c "..."
                                                  └─────────────────────────┘
```

## Fichiers

| Fichier | Rôle |
|---|---|
| `src/main.zig` | Client : parsing de la CLI, lecture du Procfile, démarrage automatique du démon, envoi de la requête, affichage de la réponse. Aiguille aussi `zvisor daemon` vers le démon. |
| `src/daemon.zig` | Démon : état des processus, PTY, boucle d'événements, commandes, tampon de sortie, formatage des préfixes. |
| `src/common.zig` | Utilitaires partagés : tampon d'octets extensible (`Buf`), concaténation de chemins, recherche du dossier `.pm`, connexion au socket. |
| `src/sys.zig` | Déclarations libc écrites à la main (`forkpty`, `poll`, sockets, `waitpid`…) et constantes Linux/macOS. |

Le code évite volontairement la stdlib de Zig pour tout ce qui touche au système
(processus, fichiers, sockets) : cette partie évolue vite d'une version à l'autre,
alors que libc est stable. La stdlib reste utilisée pour le formatage, les tranches
et les listes.

## Où vit l'état

Un dossier **`.pm` dans le répertoire courant** (jamais dans le home) :

```
.pm/
├── sock          socket Unix du démon
├── daemon.log    stdout/stderr du démon
├── logs/         <nom>.log (sortie brute) et <nom>.log.1 après rotation
└── .gitignore    contient "*" : le dossier ne se commit jamais
```

- Le dossier est créé en `0700` : c'est lui qui protège le socket. Quiconque peut
  écrire dans le socket peut exécuter des commandes, donc ne le rends pas accessible
  à d'autres utilisateurs.
- `homeDir()` choisit le dossier : `$ZVISOR_HOME` s'il est défini ; sinon le `.pm` le plus
  proche (cwd puis parents) qui contient un `sock` ; sinon `./.pm`. Résultat : **un
  démon par projet**, et les commandes de lecture marchent depuis un sous-dossier.
- Les chemins de socket Unix sont limités à ~108 octets. `connectIn` fait donc un
  `chdir` dans `.pm` et se connecte à `"sock"` en chemin relatif. Le démon fait de
  même : il ne change plus de dossier courant après son démarrage.

## Vie d'une commande

1. Le client calcule `home`, puis `connectIn(home)`.
2. Si le socket ne répond pas : pour `add` et `up` il lance le démon (voir plus bas) ;
   pour les autres commandes il affiche une erreur (ou « no processes » pour `ls`).
3. Il envoie une requête, puis lit la réponse jusqu'à la fermeture de la connexion
   et la recopie telle quelle sur stdout (stderr si c'est une erreur).
4. Code de sortie : `1` si la réponse commence par `E`, `0` sinon.

### Démarrage du démon

Le client fait `fork()`. L'enfant : `setsid()` (se détache du terminal), redirige
stdin vers `/dev/null` et stdout/stderr vers `daemon.log`, puis `execve` sur
lui-même (`/proc/self/exe`) avec `daemon <home>`. Le client réessaie ensuite la
connexion jusqu'à 5 s. Côté démon : création de `.pm`, test d'un démon déjà présent
(connexion qui réussit → il quitte), suppression d'un `sock` périmé, `bind`/`listen`,
sockets non bloquants et `FD_CLOEXEC`, `SIGPIPE` ignoré, `SIGTERM`/`SIGINT` → arrêt propre.

### Protocole

Requête : `u32` little-endian (longueur) puis une suite de chaînes terminées par `\0`.
Les deux premières sont toujours le **verbe** et un drapeau **couleur** (`1`/`0`,
vrai si stdout du client est un terminal et que `NO_COLOR` est absent).

| Verbe | Arguments suivants |
|---|---|
| `add` | `cwd`, `cols`, `rows`, `restart` (0/1), `replace` (0/1), `n`, `n` × (`nom`, `commande`), puis l'environnement du client (`K=V`…) |
| `start` `stop` `restart` `rm` | cible (`nom` ou `all`) |
| `logs` | cible (vide ou `all` = tous), nombre de lignes, `follow` (0/1) |
| `ls`, `down`, `ping` | aucun |

Réponse : **un octet de statut** (`O` ou `E`) suivi du texte, éventuellement coloré.
Le démon ferme la connexion une fois la réponse envoyée, sauf pour `logs -f` (flux
continu) et `down` (reste ouverte jusqu'à l'arrêt complet).

`up` n'a pas de verbe propre : le client lit le Procfile (`nom: commande`, `#` pour
les commentaires) et envoie un seul `add` avec `replace=1` et `cwd` = dossier du Procfile.
Si une définition identique tourne déjà, le démon répond « unchanged » ; si elle a
changé, il redémarre le processus.

## Le démon

### Boucle d'événements

Un seul thread, un seul `poll()` sur : le socket d'écoute, un tube interne, chaque
connexion client, et le côté maître du PTY de chaque processus.

**Le démon dort tant qu'il n'y a rien à faire** : pas de minuterie périodique. Le délai
du `poll()` est calculé à partir de la prochaine échéance (relance après plantage,
délai avant SIGKILL, échéance d'arrêt), ou infini s'il n'y en a aucune. Les signaux
`SIGCHLD` (un processus s'est terminé), `SIGTERM` et `SIGINT` écrivent un octet dans
le tube interne, ce qui réveille `poll()` (technique du « self-pipe »). Trois processus
silencieux entraînent donc **0 réveil**.

À chaque réveil :

1. arrêt demandé par signal ? → `beginShutdown` ;
2. accepter les nouvelles connexions ;
3. lire les requêtes des clients (et les exécuter dès qu'elles sont complètes) ;
4. lire la sortie des PTY ;
5. `tick` : `waitpid(WNOHANG)` seulement si `SIGCHLD` a été reçu, escalade SIGKILL,
   relances programmées ;
6. écrire les tampons de sortie des clients ;
7. `sweep` : fermer les connexions mortes, libérer les processus à supprimer.

Rien n'est libéré en plein milieu d'un tour : les suppressions sont marquées
(`dead`, `remove_when_dead`) puis traitées en 7, ce qui évite les pointeurs pendants.

### Processus

Chaque processus (`Proc`) est lancé avec **`forkpty`** : il reçoit un pseudo-terminal
comme stdin/stdout/stderr et devient chef de sa propre session et de son groupe.
Il tourne via `/bin/sh -c "<commande>"` (les pipes, `&&` et variables marchent),
dans le `cwd` demandé, avec l'**environnement du client** qui a fait `add`/`up`
(PATH inclus). `TERM` vaut `xterm-256color` s'il manque ou vaut `dumb`. La taille du
PTY est celle du terminal du client au moment de l'`add`.

États : `running`, `stopped`, `exited`, `backoff` (attente avant relance), `failed`.

- **Arrêt** : `SIGTERM` à tout le groupe (`kill(-pid)`), puis `SIGKILL` après 5 s si
  le processus s'accroche. Après la sortie du processus, un dernier `SIGTERM` au
  groupe nettoie d'éventuels processus orphelins qui garderaient un port ouvert.
- **Sortie spontanée** : si `autorestart` est actif, relance après `1 s × 2^n`
  (plafonné à 30 s). Un processus qui meurt en moins de 3 s compte comme « plantage
  rapide » ; au bout de 6 de suite il passe en `failed` jusqu'à un `start`/`restart`
  manuel. Un processus qui a tourné plus de 3 s remet le compteur à zéro.
- **`restart`** : arrêt, puis redémarrage quand la sortie est constatée
  (`restart_pending`). **`rm`** : arrêt, puis suppression au `sweep`.
- Chaque événement (démarrage, sortie, relance…) est écrit dans le flux du processus
  sous la forme d'une ligne grisée `[zvisor] …`, donc visible dans `logs`.

## Sortie et couleurs

Le but : ne jamais perdre ni abîmer une couleur. Comme le processus écrit dans un PTY,
il croit parler à un terminal et garde ses couleurs. Chaque morceau lu passe par
`emit()`, qui fait trois choses :

1. **Tampon mémoire** (`ring`) : historique circulaire de 128 Ko au plus par processus.
   Il démarre à 4 Ko et ne grossit que si le processus produit vraiment de la sortie ;
   quand il est plein, les octets les plus anciens sont écrasés (aucune recopie).
   `logs` extrait les N dernières lignes de ce tampon.
2. **Fichier** `.pm/logs/<nom>.log` : octets bruts (avec les séquences ANSI), rotation à
   10 Mo vers `.log.1`. À relire avec `less -R`.
3. **Abonnés** (`logs -f`) : les octets sont copiés dans le tampon d'envoi de chaque
   client concerné.

Deux modes de diffusion :

- **Un seul processus** (`logs web`) : octets **identiques** à ceux du PTY, aucune
  modification (y compris les `\r\n` produits par le terminal).
- **Tous les processus** (`logs`, `logs -f`) : on insère un préfixe `nom |` coloré en
  début de ligne. C'est le seul octet ajouté ; aucun octet n'est retiré ni modifié.

Le préfixe est géré par une petite machine à états (`Fmt`). Pour ne pas coûter de CPU
quand personne ne l'utilise, **elle ne tourne que si un `logs -f` en vue globale est
connecté** ; sinon le démon note que l'état est « périmé ». Quand un tel suiveur arrive,
l'état (début de ligne, couleur active) est reconstruit d'un coup en relisant
l'historique, avant que les nouveaux octets ne soient traités. La machine travaille
par blocs d'octets (elle ne copie que ce qui précède un préfixe) :

- Il n'est inséré qu'au **premier caractère imprimable** d'une ligne, pas avant une
  séquence d'échappement. Les séquences de début de ligne (couleurs, effacement…)
  restent donc devant le préfixe, comme à l'origine.
- Un `\r` isolé (barre de progression) compte aussi comme début de ligne, pour que
  le préfixe soit réécrit avec la ligne.
- Elle suit les séquences `SGR` (`ESC [ … m`) pour connaître la couleur **active**.
  Le préfixe commence par `ESC[0m` (pour ne pas être teinté par la ligne précédente),
  se termine par `ESC[0m`, puis **réapplique la couleur active**. Une couleur ouverte
  sur une ligne et fermée trois lignes plus tard reste donc correcte.
- Une séquence découpée entre deux lectures est reconstituée. Si l'état de couleur
  devient trop long (> 256 octets) il est abandonné : on perd la restauration, pas
  les octets.

## Connexions clients

Chaque connexion a un tampon d'entrée (la requête) et un tampon d'envoi non bloquant.
Le tampon d'entrée est libéré dès que la requête est traitée, et le tampon d'envoi dès
qu'il est vidé s'il a dépassé 64 Ko. Si un client lent laisse s'accumuler plus de 8 Mo,
il est déconnecté plutôt que de bloquer le démon ou de grossir sans limite. Une connexion
normale est fermée dès que la réponse est écrite (`close_after_flush`).

## Consommation

Mesures sur Linux avec `examples/bench.sh` (3 processus de `examples/basic`, binaire
`small`, musl statique) :

| | Valeur |
|---|---|
| Binaire | ~270 Ko |
| RAM du démon au repos | ~500 Ko |
| RAM après un flot de sortie de 5 s à ~50 Mo/s | ~900 Ko (pic 950 Ko) |
| Réveils avec des processus silencieux | 0 |
| CPU par Mo de sortie traité | ~5 à 7 ms (jusqu'à ~13 ms avec `logs -f` global) |
| Commande client (`zvisor ls`) | ~0,4 ms |

Ce qui fait ces chiffres : pas de minuterie (self-pipe), `waitpid` uniquement sur
`SIGCHLD`, formatage des couleurs seulement à la demande, historique circulaire à
croissance paresseuse, lectures du PTY regroupées en un seul traitement (jusqu'à 64 Ko)
et tampons de connexion libérés après usage. L'écriture des logs sur disque ajoute
environ 25 % de CPU sous un flot soutenu (rien au repos).

## Arrêt

`zvisor down` (ou `SIGTERM`/`SIGINT` sur le démon) envoie `SIGTERM` à tous les groupes,
attend leur sortie (au plus ~7 s, avec escalade SIGKILL), répond `daemon stopped` au
client qui a demandé l'arrêt, supprime `sock` et quitte. Les logs et `.gitignore`
restent dans `.pm`. Si le démon est tué brutalement (`SIGKILL`), les processus perdent
leur PTY et reçoivent `SIGHUP`.

## Limites et pistes

- Testé sur Linux. macOS : constantes et chemin de l'exécutable prévus, jamais testés.
- Pas d'`attach` interactif : il faudrait relayer l'entrée du terminal du client vers
  le PTY (mode brut côté client) et gérer le redimensionnement.
- Le redémarrage utilise la taille de terminal d'origine ; elle n'est pas mise à jour.
- Pas d'ordre global entre les lignes de plusieurs processus (pas d'horodatage stocké) :
  l'historique de `logs` affiche les processus l'un après l'autre, puis le direct
  est entrelacé.
- Un client déconnecté pendant `up` ne change rien : les ordres sont déjà exécutés.
