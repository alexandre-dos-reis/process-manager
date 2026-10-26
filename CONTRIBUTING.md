# Contribuer

## Messages de commit : Conventional Commits

Les commits suivent [Conventional Commits](https://www.conventionalcommits.org) :

```
type(scope)!: description
```

Types : `feat` (nouvelle fonctionnalité), `fix` (correction), `perf`, `refactor`, `docs`,
`test`, `build`, `ci`, `chore`, `style`, `revert`. `scope` et `!` (changement cassant)
sont facultatifs. Exemples : `feat(logs): add --since`, `fix: keep colors after restart`,
`feat!: rename the state directory`.

- En local : `git config core.hooksPath .githooks` active un hook qui refuse les mauvais
  messages (`scripts/check-commit-message.sh`).
- Sur GitHub : le workflow `ci` refuse une PR dont un commit ou le titre ne respecte pas
  le format.

## Versions et releases

La version vit à **un seul endroit** : `.version` dans `build.zig.zon` (`build.zig` la
lit, `zpawn --version` l'affiche). On ne la modifie jamais à la main.

[release-please](https://github.com/googleapis/release-please) lit les commits de `main` :
`fix` → patch, `feat` → minor (tant qu'on est en 0.x, un `feat!` reste en minor), et ouvre
une PR « chore(main): release x.y.z » avec le `CHANGELOG.md` et le bump de version.
Fusionner cette PR crée le tag et la release GitHub ; le job `binaries` y attache les
archives Linux (x86_64 et aarch64, statiques) et `SHA256SUMS`.

## Tests

```sh
test/run.sh          # build + unitaires + CLI + exemples
sh test/commit_messages.sh
```
