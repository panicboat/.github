# Changelog

## [0.3.2](https://github.com/panicboat/.github/compare/v0.3.1...v0.3.2) (2026-11-05)


### Features

* automerge production updates except major and wait for the release age on shared workflows ([#55](https://github.com/panicboat/.github/issues/55)) ([551813c](https://github.com/panicboat/.github/commit/551813c407b791e07535608294c07eee5195d9f2))


### Miscellaneous Chores

* **.github/workflows:** update anthropics/claude-code-action action to v1.0.266 ([#57](https://github.com/panicboat/.github/issues/57)) ([01fb767](https://github.com/panicboat/.github/commit/01fb76788c36473c24aa7b1c2c425da847f01ec7))
* **.github/workflows:** update anthropics/claude-code-action action to v1.0.268 ([#63](https://github.com/panicboat/.github/issues/63)) ([3d65c6a](https://github.com/panicboat/.github/commit/3d65c6ad2a9d9f4533f61bec5ae0438d31fb9e6f))
* **.github/workflows:** update dependency aqua to v2.66.0 ([#61](https://github.com/panicboat/.github/issues/61)) ([f25e6f4](https://github.com/panicboat/.github/commit/f25e6f458047b3b1f24f0082849c44f50276b56c))
* **.github/workflows:** update int128/wait-for-workflows-action action to v1.111.0 ([#58](https://github.com/panicboat/.github/issues/58)) ([b4cb4d5](https://github.com/panicboat/.github/commit/b4cb4d5a48c648987464c3b463a444aa5d1ac013))
* **.github/workflows:** update panicboat/deploy-actions action to v0.3.0 ([#59](https://github.com/panicboat/.github/issues/59)) ([48b2d58](https://github.com/panicboat/.github/commit/48b2d58d58b4b247cb6606eece2143ff8fabc278))
* **.github/workflows:** update panicboat/deploy-actions action to v1 ([#60](https://github.com/panicboat/.github/issues/60)) ([db0d0e6](https://github.com/panicboat/.github/commit/db0d0e65cf2c06409937e480184548c9c2b14372))

## [0.3.1](https://github.com/panicboat/.github/compare/v0.3.0...v0.3.1) (2026-11-01)


### Miscellaneous Chores

* run Renovate overnight and remove the concurrent pull request limit ([#52](https://github.com/panicboat/.github/issues/52)) ([6421e89](https://github.com/panicboat/.github/commit/6421e89b8f838533f6a1fd31bdb63b2aa42c60b3))

## [0.3.0](https://github.com/panicboat/.github/compare/v0.2.1...v0.3.0) (2026-10-31)


### ⚠ BREAKING CHANGES

* drop the config-path input and fail on pull request lookup errors ([#49](https://github.com/panicboat/.github/issues/49))

### Features

* drop the config-path input and fail on pull request lookup errors ([#49](https://github.com/panicboat/.github/issues/49)) ([0fce505](https://github.com/panicboat/.github/commit/0fce505c8dd2dbf77023d5200c14be5591fd94a9))

## [0.2.1](https://github.com/panicboat/.github/compare/v0.2.0...v0.2.1) (2026-10-31)


### Bug Fixes

* harden release builds and helmfile hydration ([#48](https://github.com/panicboat/.github/issues/48)) ([5181a1c](https://github.com/panicboat/.github/commit/5181a1c0d8e3e338de79aa31736538dc2cb0b1b6))
* keep production dependency updates out of automerge ([#46](https://github.com/panicboat/.github/issues/46)) ([ffacddd](https://github.com/panicboat/.github/commit/ffacdddf66dbf6eaa69335c5d5eb98acd034ee6c))

## [0.2.0](https://github.com/panicboat/.github/compare/v0.1.2...v0.2.0) (2026-10-30)


### ⚠ BREAKING CHANGES

* remove the release config check ([#44](https://github.com/panicboat/.github/issues/44))

### Features

* remove the release config check ([#44](https://github.com/panicboat/.github/issues/44)) ([cf6babf](https://github.com/panicboat/.github/commit/cf6babff77e1895eb46e3c9ee6a6fba607f163d8))

## [0.1.2](https://github.com/panicboat/.github/compare/v0.1.1...v0.1.2) (2026-10-30)


### Bug Fixes

* skip the label resolver on a push without a pull request ([#42](https://github.com/panicboat/.github/issues/42)) ([77a55e4](https://github.com/panicboat/.github/commit/77a55e4792fe904c80be2033b1d4c4bd996421df))

## [0.1.1](https://github.com/panicboat/.github/compare/v0.1.0...v0.1.1) (2026-10-30)


### Bug Fixes

* resolve release targets for callers without a production environment ([#39](https://github.com/panicboat/.github/issues/39)) ([f722988](https://github.com/panicboat/.github/commit/f722988cf280d33ca9fc4432be5fe91360f28fb6))
