# Changelog

## [3.3.0](https://github.com/panicboat/.github/compare/v3.2.0...v3.3.0) (2026-10-29)


### Features

* diff the production kustomizations of a release against the previous release ([#32](https://github.com/panicboat/.github/issues/32)) ([42d9ab0](https://github.com/panicboat/.github/commit/42d9ab07b66ef9eb05b0c1b29f3e7ef4cfbc47cc))

## [3.2.0](https://github.com/panicboat/.github/compare/v3.1.1...v3.2.0) (2026-10-28)


### Features

* decide release environments by name and tag release images with the release tag ([#30](https://github.com/panicboat/.github/issues/30)) ([338a6ed](https://github.com/panicboat/.github/commit/338a6ed260d9675f9cc1eeae2434f9149df4ff85))

## [3.1.1](https://github.com/panicboat/.github/compare/v3.1.0...v3.1.1) (2026-10-27)


### Code Refactoring

* read the Claude Code OAuth token from the renamed secret ([#26](https://github.com/panicboat/.github/issues/26)) ([894c03f](https://github.com/panicboat/.github/commit/894c03f6e3834388f395e408857c2c2bbcf1fb48))

## [3.1.0](https://github.com/panicboat/.github/compare/v3.0.0...v3.1.0) (2026-10-26)


### Features

* run the review workflows on the Claude subscription with a Bedrock fallback ([#23](https://github.com/panicboat/.github/issues/23)) ([97ad567](https://github.com/panicboat/.github/commit/97ad567225c8e45c1793e93b1593e2f57525dfc6))

## [3.0.0](https://github.com/panicboat/.github/compare/v2.0.0...v3.0.0) (2026-10-25)


### ⚠ BREAKING CHANGES

* run the review workflows on claude-code-action with Anthropic WIF ([#19](https://github.com/panicboat/.github/issues/19))

### Features

* run the review workflows on claude-code-action with Anthropic WIF ([#19](https://github.com/panicboat/.github/issues/19)) ([99b55bb](https://github.com/panicboat/.github/commit/99b55bb63e680058fa11ae2a94e6b4c2afada285))

## [2.0.0](https://github.com/panicboat/.github/compare/v1.0.0...v2.0.0) (2026-10-25)


### ⚠ BREAKING CHANGES

* run the review workflows on Gemini on Vertex AI ([#18](https://github.com/panicboat/.github/issues/18))

### Features

* run the review workflows on Gemini on Vertex AI ([#18](https://github.com/panicboat/.github/issues/18)) ([773b533](https://github.com/panicboat/.github/commit/773b533887fb3b85116c66e7b065c9c92a8f4118))


### Code Refactoring

* mark the workflows called only by other shared workflows as internal ([#8](https://github.com/panicboat/.github/issues/8)) ([039db6a](https://github.com/panicboat/.github/commit/039db6ae38348ae2d1d21f70d02ead890342dd9b))
* mark the workflows triggered by this repository's own events as self ([#9](https://github.com/panicboat/.github/issues/9)) ([f3cdedc](https://github.com/panicboat/.github/commit/f3cdedcd48266cb4606cca55d9c1cc12f474de44))


### Miscellaneous Chores

* **.github/workflows:** update anthropics/claude-code-action action to v1.0.262 ([#10](https://github.com/panicboat/.github/issues/10)) ([c1215e0](https://github.com/panicboat/.github/commit/c1215e055ac897cd6b23cd07a940c399e5398bb2))
* **.github/workflows:** update aquaproj/aqua-installer action to v4.1.1 ([#11](https://github.com/panicboat/.github/issues/11)) ([81729f5](https://github.com/panicboat/.github/commit/81729f5f1423066320c2f4af64714d65c73316d0))
* **.github/workflows:** update dependency aqua to v2.65.2 ([#14](https://github.com/panicboat/.github/issues/14)) ([af7e58d](https://github.com/panicboat/.github/commit/af7e58daa9ec949662e77183d627a9cf6a0d78d1))
* **.github/workflows:** update docker/login-action action to v4.7.0 ([#15](https://github.com/panicboat/.github/issues/15)) ([ea70e91](https://github.com/panicboat/.github/commit/ea70e912dba3ac871eeec7f31dec8d6e6124bebb))
* **.github/workflows:** update int128/diff-action action to v2.42.0 ([#16](https://github.com/panicboat/.github/issues/16)) ([8d748a5](https://github.com/panicboat/.github/commit/8d748a59f5a0075e16a46f8655d1c068f83e0865))
* **.github/workflows:** update int128/wait-for-workflows-action action to v1.110.0 ([#17](https://github.com/panicboat/.github/issues/17)) ([174900f](https://github.com/panicboat/.github/commit/174900f0ce51448a4cc96971ecebacbad7324eea))
* **.github/workflows:** update stefanzweifel/git-auto-commit-action action to v7.2.1 ([#12](https://github.com/panicboat/.github/issues/12)) ([f557521](https://github.com/panicboat/.github/commit/f557521b68417798b2e281906c48a2b5fc4be537))
* **.github/workflows:** update zgosalvez/github-actions-ensure-sha-pinned-actions action to v5.0.11 ([#13](https://github.com/panicboat/.github/issues/13)) ([ad96759](https://github.com/panicboat/.github/commit/ad967590f00c51e03ac0e3cb24ad5ba1b0f2612d))
* drop the one-time release-as from the release-please config ([#6](https://github.com/panicboat/.github/issues/6)) ([b88f9c2](https://github.com/panicboat/.github/commit/b88f9c238083f02f5cc7ff1f61544d1821cf915e))

## 1.0.0 (2026-10-24)


### Features

* add the default issue and pull request templates ([#1](https://github.com/panicboat/.github/issues/1)) ([aa1857c](https://github.com/panicboat/.github/commit/aa1857c514b200cf2ad56095f26073eba3b61bd1))
* add the shared workflows, scripts, and renovate preset ([#3](https://github.com/panicboat/.github/issues/3)) ([aa670c1](https://github.com/panicboat/.github/commit/aa670c113e3d748ecd892faad12ef2dcc848eb3c))
