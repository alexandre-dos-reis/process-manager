# Changelog

## [0.2.0](https://github.com/alexandre-dos-reis/zpawn/compare/v0.1.0...v0.2.0) (2026-10-27)


### Features

* **config:** add `tty: false` to run a process on a pipe instead of a PTY ([ddf9d5c](https://github.com/alexandre-dos-reis/zpawn/commit/ddf9d5c7b9057608b76bef46cf84e14ab5afce4f))
* **config:** add `tty: false` to run a process on a pipe instead of a PTY ([544c5d7](https://github.com/alexandre-dos-reis/zpawn/commit/544c5d73befd3358981282ba8ee73ae041cc7b59))


### Bug Fixes

* **logs:** say how a process ended when the stop was deliberate ([eb69320](https://github.com/alexandre-dos-reis/zpawn/commit/eb69320b98e5323970932fe7a25a5aea7636c3b5))

## [0.1.0](https://github.com/alexandre-dos-reis/zpawn/releases/tag/v0.1.0) (2026-10-26)


### Features

* **config:** add an optional health command to services ([1d65fc2](https://github.com/alexandre-dos-reis/zpawn/commit/1d65fc2ddab20ff5609f0551967ab1d3447a8d00))
* **config:** add depends_on with a waiting state ([3908c7d](https://github.com/alexandre-dos-reis/zpawn/commit/3908c7dd337c2d66204af8059761ab712ec9c5b3))


### Performance Improvements

* **daemon:** raise the in-memory log history to 512 KiB per process ([8dddf1b](https://github.com/alexandre-dos-reis/zpawn/commit/8dddf1be914d43e056af6cb74a688187afc31b03))


### Miscellaneous Chores

* prepare the first release ([ec75568](https://github.com/alexandre-dos-reis/zpawn/commit/ec755686db0c49c049a9a6a729a7e0d55ba2c2e6))
