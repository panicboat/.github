# Shared Workflows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** monorepo・platform・deploy-actions の重複 workflow と scripts の正本を `panicboat/.github` に集約し、各リポジトリは SHA 固定で呼ぶだけにする。

**Architecture:** `panicboat/.github` に `reusable--*.yaml` と `scripts/` を置き、release-please で `vX.Y.Z` を付ける。共通の workflow 同士は `$/.github/workflows/...` で呼び合い、scripts は `job.workflow_repository`@`job.workflow_sha` を checkout して実行する。各リポジトリには `on:`・concurrency・permissions・入力だけを持つ呼び出し用 workflow を残す。

**Tech Stack:** GitHub Actions（reusable workflow、`$/` 参照）、bash・yq・jq、release-please、Renovate、Terragrunt（platform の `github/` stack）

**Spec:** `docs/superpowers/specs/2026-10-25-shared-workflows-design.md`

## Global Constraints

- 文書の本文は日本語、見出し・識別子・コード内コメント・commit message は英語。コメントは 1 行で、Why not だけを書く（AGENTS.md）。
- commit は `git commit -s`。`Co-Authored-By` は付けない。PR は `gh pr create --draft`、タイトルは Conventional Commits の英語、本文は `panicboat/.github` の PR テンプレートの見出しに従い 1 文 1 行。
- action の `uses:` はすべて full commit SHA に `# vX.Y.Z` を添える（lint-actions が検査する）。action の SHA とバージョンは、移す元のファイルに書かれているものをそのまま使う。
- 共通の workflow のファイル名: 今 `reusable--` で始まるものはその名前のまま、それ以外は `reusable--<今のファイル名の拡張子を除いた部分>.yaml`。各リポジトリの呼び出し用 workflow のファイル名と `name:` は今のまま。
- 共通の workflow から別の共通の workflow を呼ぶときは `uses: $/.github/workflows/<file>`（`@ref` なし）。各リポジトリからは `uses: panicboat/.github/.github/workflows/<file>@<sha> # vX.Y.Z`。
- scripts は `panicboat/.github` の `scripts/<group>/` に置く。共通の workflow は呼び出し元を checkout したあと、`actions/checkout` で `repository: ${{ job.workflow_repository }}`・`ref: ${{ job.workflow_sha }}`・`path: .shared-workflows` を checkout し、`bash .shared-workflows/scripts/...` で実行する。
- scripts が呼び出し元のファイル（`workflow-config.yaml`・`aws/`・`kubernetes/` など）を探すときは、作業ディレクトリ（呼び出し元の checkout）を基準にし、スクリプト自身の場所を基準にしない。
- 複数の stack をまとめる workflow（resolver と、resolver から呼ばれる terragrunt-runner・container-builder・kubernetes-builder・kubernetes-hydrator）の job は `permissions` を宣言しない。呼び出し側の job が、そのリポジトリで使う stack の分だけを付ける。
  - 呼ばれた側が呼び出し側より強い権限を宣言すると、その job を使わないリポジトリでも workflow が起動時に失敗するため。
  - 1 つの用途だけの workflow（docs-sync-check・renovate-major-review）は、job ごとの最小権限を今どおり宣言し、呼び出し側はその和を付ける。
- GitHub App は、入力 `app-id`（呼び出し側は `${{ vars.APP_ID }}`）と secret `private-key`（呼び出し側は `${{ secrets.APP_PRIVATE_KEY }}`）で渡す。
- stack 名: monorepo の `kubernetes` → `kustomize`、platform の `kubernetes` → `helmfile`。`terragrunt`・`container` はそのまま。
- `deploy-dystopia-lambda.yaml` は monorepo に残し、中の `uses: ./.github/workflows/reusable--terragrunt-runner.yaml` を共通版の参照に替える。
- 汎用化した docs-sync-check と renovate-major-review は、今使っているリポジトリ（docs-sync-check は monorepo、renovate-major-review は platform）からだけ呼ぶ。
- Renovate preset は `panicboat/.github` の `default.json`。`panicboat/.github` への参照の更新には `minimumReleaseAge` を待たせない（設計者の判断）。

## Review Focus

1. 呼び出し元のファイルを、スクリプトの場所ではなく呼び出し元の checkout から読むこと。`.shared-workflows/scripts/terragrunt-release/release-targets.sh <service>` を platform の作業ツリーで実行すると、platform の `workflow-config.yaml` の target が返る（Task 1 のテスト）。
2. `.shared-workflows/` が呼び出し元に commit されないこと。hydrator の自動 commit は `kubernetes/manifests/<env>/` だけを対象にする（Task 4 で `file_pattern` を変えない）。
3. resolver の各 stack の job は、その stack の target があるときだけ動き、他の stack の target が来ても失敗しないこと。monorepo の PR で `helmfile` の job が skip され、platform の PR で `container`・`kustomize` の job が skip される（Task 9・10 の PR の checks で確認）。
4. 自前の `$/` 参照と self checkout が、`panicboat/.github` 自身の PR（呼び出し元と呼ばれる側が同じリポジトリ）でも、別リポジトリからの呼び出しでも、同じ commit を指すこと（Task 3 と Task 9 の PR で、`.shared-workflows` の HEAD が `job.workflow_sha` と一致することを step のログで確認）。
5. lint-actions（`zgosalvez/github-actions-ensure-sha-pinned-actions`）が `$/` の参照を SHA 未固定と誤判定しないこと（Task 3 の PR で check が通ることを確認。誤判定するなら、その action の allowlist に `$/` を足す）。

---

## Repository: panicboat/.github

作業は `panicboat/.github` に worktree を作って行う（`git worktree add -b feat/shared-workflows .worktrees/feat-shared-workflows origin/main`）。Task 1〜7 はこのブランチに積み、1 つの Draft PR にする。

### Task 1: terragrunt-release scripts

**Files:**
- Create: `scripts/terragrunt-release/{release-service.sh,release-targets.sh,check-release-configs.sh,validate-apply-trigger.sh,test.sh}`（monorepo の `origin/main:.github/scripts/terragrunt-release/` を元にする）

**Interfaces:**
- Produces:
  - `release-service.sh --tag <tag> | --branch <branch>` → stdout にサービス名（今と同じ）
  - `release-targets.sh <service> [config_path] | --all [config_path]` → stdout に target の JSON 配列（今の monorepo 版と同じ形。`config_path` の既定は `workflow-config.yaml`）
  - `check-release-configs.sh [config_path]` → 問題があれば `::error::` を出して exit 1
  - `validate-apply-trigger.sh [config_path]` → `apply_trigger` が `merge`/`release` 以外、または terragrunt の `production` が `release` でなければ `::error::` を出して exit 1

- [ ] **Step 1: monorepo 版の 5 ファイルを `scripts/terragrunt-release/` に写し、`bash scripts/terragrunt-release/test.sh` が通ることを確認する**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: exit 0

- [ ] **Step 2: platform の配置で失敗するテストを `test.sh` に足す**

fixture は `aws/{service}/{environment}`・`github/{service}/{environment}` のパスを持ち、`master`・`develop` が `merge`、`production` が `release` の `workflow-config.yaml` と、`aws/vpc/{master,develop,production}/` のディレクトリと、次の `aws/vpc/release-please-config.json` を作る。
- `test_check_release_configs_accepts_service_root_package`: package が `aws/vpc`、`exclude-paths` が `["aws/vpc/master", "aws/vpc/develop"]` で exit 0
- `test_check_release_configs_rejects_missing_exclude_path`: `exclude-paths` が `["aws/vpc/master"]` で exit 1、stderr に `aws/vpc/develop` を含む
- `test_check_release_configs_accepts_product_service_package`: monorepo 形（`{product}/{service}/infrastructure/aws/{environment}`、package `dystopia/frontend`、`exclude-paths` `["dystopia/frontend/infrastructure/aws/develop"]`）で exit 0
- `test_validate_apply_trigger_rejects_merge_production`: terragrunt の `production` が `merge` で exit 1、stderr に `production` を含む

- [ ] **Step 3: テストが失敗することを確認する**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: 上の 2 つの accepts のうち `service_root_package` と、`rejects_merge_production` が FAIL

- [ ] **Step 4: `check-release-configs.sh` の package と `exclude-paths` の求め方を変え、`validate-apply-trigger.sh` に production の検査を足す**

package は、target の元になったパステンプレートの先頭から `{service}` までのセグメントに値を入れたパス。`exclude-paths` は、同じ package に属する target のうち `apply_trigger` が `release` でない環境の `working_directory`。`/infrastructure/` を前提にする処理は消す。

- [ ] **Step 5: テストが通ることを確認する**

Run: `bash scripts/terragrunt-release/test.sh`
Expected: exit 0

- [ ] **Step 6: 両リポジトリの実物に対して通ることを確認する**

Run: `(cd <platform の origin/main を展開した dir> && bash <worktree>/scripts/terragrunt-release/check-release-configs.sh && bash <worktree>/scripts/terragrunt-release/validate-apply-trigger.sh)`、monorepo でも同じ
Expected: どちらも exit 0

- [ ] **Step 7: Commit**（`feat: add the terragrunt release scripts`）

### Task 2: kubernetes-hydrate and docs-sync-check scripts, and their CI

**Files:**
- Create: `scripts/kubernetes-hydrate/`（platform の `origin/main:.github/scripts/kubernetes-hydrate/` を tests ごと）
- Create: `scripts/docs-sync-check/{decide.sh,decide.test.sh}`（monorepo から）
- Create: `scripts/release-please/{find-configs.sh,find-configs.test.sh}`
- Create: `.github/workflows/test-scripts.yaml`

**Interfaces:**
- Produces:
  - `decide.sh` は環境変数 `SCOPE_PATTERN`（`grep -E` の正規表現。必須）で対象のファイルを判定する。それ以外の入出力は今と同じ
  - `find-configs.sh` → stdout に `release-please-config.json` のあるディレクトリの JSON 配列。ルートの設定は `"."`
  - `test-scripts.yaml`: `pull_request` と main への `push` で、`scripts/*/test.sh`・`scripts/*/*.test.sh`・`scripts/kubernetes-hydrate/tests/*.test.sh` を全部実行する。job 名 `Test scripts`

- [ ] **Step 1: `decide.test.sh` に `SCOPE_PATTERN='^platform/'` で `dystopia/` だけの変更が `skip-unchanged` になるテストを足し、失敗を確認する**

Run: `bash scripts/docs-sync-check/decide.test.sh`
Expected: FAIL

- [ ] **Step 2: `decide.sh` の `'^dystopia/'` を `SCOPE_PATTERN` に替え、既存のテストには `SCOPE_PATTERN='^dystopia/'` を渡す。通ることを確認する**

Run: `bash scripts/docs-sync-check/decide.test.sh`
Expected: exit 0

- [ ] **Step 3: `find-configs.test.sh` を書く**

- `test_finds_nested_configs`: `a/release-please-config.json`・`b/c/release-please-config.json` → `["a","b/c"]`
- `test_finds_root_config`: ルートだけ → `["."]`
- `test_finds_none`: なし → `[]`

- [ ] **Step 4: 失敗を確認し、`git ls-files` を使って `find-configs.sh` を実装し、通ることを確認する**

Run: `bash scripts/release-please/find-configs.test.sh`
Expected: 実装前 FAIL、実装後 exit 0

- [ ] **Step 5: kubernetes-hydrate の tests を実行して通ることを確認する**

Run: `for t in scripts/kubernetes-hydrate/tests/*.test.sh; do bash "$t"; done`
Expected: exit 0

- [ ] **Step 6: `test-scripts.yaml` を書き、Commit**（`feat: add the kubernetes hydrate, docs sync check, and release-please scripts`）

### Task 3: PR checks and gatekeeper

**Files:**
- Create: `.github/workflows/reusable--lint-actions.yaml`・`reusable--semantic-pull-request.yaml`・`reusable--ci-gatekeeper.yaml`・`reusable--label-base-deploy--dispatcher.yaml`
- Create: `.github/workflows/lint-actions.yml`・`semantic-pull-request.yml`・`ci-gatekeeper.yaml`（このリポジトリ自身の呼び出し用。`uses: ./.github/workflows/...`）

**Interfaces:**
- Produces:
  - `reusable--lint-actions.yaml`: 入力なし
  - `reusable--semantic-pull-request.yaml`: 入力 `app-id`、secret `private-key`
  - `reusable--ci-gatekeeper.yaml`: 入力 `exclude-workflow-names`（string、改行区切り、既定 `''`）
  - `reusable--label-base-deploy--dispatcher.yaml`: 入力 `app-id`・`config-path`（既定 `workflow-config.yaml`）、secret `private-key`。job に `if: ${{ !startsWith(github.head_ref, 'release-please--') }}`

- [ ] **Step 1: 4 つの reusable を、元のファイルの job を移して書く（dispatcher は platform 版、他は monorepo 版を元にする）**
- [ ] **Step 2: このリポジトリの呼び出し用 3 つを書く（gatekeeper の除外は空）**
- [ ] **Step 3: actionlint を実行する**

Run: `actionlint .github/workflows/*.y*ml`
Expected: 今回足したファイルにエラーなし（`$/` を actionlint が解釈できずにエラーにする場合は、その行だけ記録して次へ進む）

- [ ] **Step 4: Commit**（`feat: add the shared pull request checks and gatekeeper`）

### Task 4: Deploy stacks

**Files:**
- Create: `.github/workflows/reusable--terragrunt-runner.yaml`（platform 版をそのまま）
- Create: `.github/workflows/reusable--container-builder.yaml`（monorepo 版から job の `permissions` を消す）
- Create: `.github/workflows/reusable--kubernetes-builder.yaml`
- Create: `.github/workflows/reusable--kubernetes-hydrator.yaml`（platform 版から job の `permissions` を消し、scripts を self checkout から実行する）
- Create: `.github/workflows/reusable--label-base-deploy--resolver.yaml`

**Interfaces:**
- Consumes: Task 1 の `validate-apply-trigger.sh`、Task 2 の `scripts/kubernetes-hydrate/`
- Produces:
  - `reusable--kubernetes-builder.yaml`: 入力 `service-name`・`environment`・`kustomization-directory`・`app-id`、secret `private-key`。head は `ref: ${{ github.head_ref }}`・`fetch-depth: 0` で checkout し（hydrate の commit を含めるため）、`int128/kustomize-action` は monorepo 版の SHA（v1.196.0）を使う。`if: inputs.kustomization-directory != ''`
  - `reusable--label-base-deploy--resolver.yaml`: 入力 `app-id`・`config-path`（既定 `workflow-config.yaml`）、secret `private-key`。job:
    - `resolve`（今と同じ。`Validate apply_trigger` は `.shared-workflows/scripts/terragrunt-release/validate-apply-trigger.sh "${{ inputs.config-path }}"`）
    - `deploy-terragrunt`（`stack: terragrunt`、今の式のまま。`terragrunt-shared` の除外は持たない）
    - `deploy-container`（`stack: container`、monorepo 版のまま）
    - `deploy-kustomize`（`stack: kustomize`、PR のときだけ、`kustomization-directory: matrix.target.working_directory`）
    - `helmfile-targets-group`・`deploy-helmfile-hydrate`・`deploy-helmfile`（platform 版の kubernetes の 3 job を `helmfile` に読み替え、`deploy-helmfile` は `kustomization-directory: kubernetes/manifests/<env>/<service>`）
    - `deployment-summary`（全 job の結果を出す。存在しない output の参照は消す）
  - 子の workflow はすべて `uses: $/.github/workflows/<file>`

- [ ] **Step 1: 5 つのファイルを書く**
- [ ] **Step 2: actionlint を実行する**（Task 3 Step 3 と同じ基準）
- [ ] **Step 3: Commit**（`feat: add the shared deploy stacks and resolver`）

### Task 5: Release workflows

**Files:**
- Create: `.github/workflows/reusable--release--please.yaml`・`reusable--release--plan.yaml`・`reusable--release--deploy.yaml`・`reusable--release--build.yaml`・`reusable--test-terragrunt-release.yaml`
- Create: `.github/workflows/release--please.yaml`（このリポジトリ自身の release 用）
- Create: `release-please-config.json`・`release-please-manifest.json`（ルートに置く。名前は monorepo と同じ）

**Interfaces:**
- Consumes: Task 1 の scripts、Task 2 の `find-configs.sh`、Task 4 の `reusable--terragrunt-runner.yaml`・`reusable--container-builder.yaml`
- Produces:
  - `reusable--release--please.yaml`: 入力 `app-id`、secret `private-key`。discover は `find-configs.sh`。`config-file`・`manifest-file` は `<path>/release-please-config.json`（`"."` のときは `release-please-config.json`）
  - `reusable--release--plan.yaml`・`reusable--release--deploy.yaml`: 入力 `app-id`、secret `private-key`。今の job を移し、scripts は self checkout から、terragrunt-runner は `$/`
  - `reusable--release--build.yaml`: 入力 `app-id`、secret `private-key`。monorepo 版を移す
  - `reusable--test-terragrunt-release.yaml`: 入力なし。呼び出し元の `workflow-config.yaml` に `validate-apply-trigger.sh` と `check-release-configs.sh` を実行する。job 名 `Validate terragrunt release config`
  - このリポジトリの release: release type `simple`、package `.`、`include-component-in-tag: false`（タグは `vX.Y.Z`）、`bootstrap-sha` は Task 5 の commit の親

- [ ] **Step 1: 5 つの reusable とこのリポジトリの `release--please.yaml`・設定 2 ファイルを書く**
- [ ] **Step 2: actionlint を実行する**（Task 3 Step 3 と同じ基準）
- [ ] **Step 3: Commit**（`feat: add the shared release workflows`）

### Task 6: Maintenance and review workflows

**Files:**
- Create: `.github/workflows/reusable--cleanup-container-image.yaml`・`reusable--docs-sync-check.yaml`・`reusable--renovate-major-review.yaml`

**Interfaces:**
- Consumes: Task 2 の `decide.sh`・`decide.test.sh`・`render-diff.sh`
- Produces:
  - `reusable--cleanup-container-image.yaml`: 入力 `services`（JSON 配列の string）。matrix は `fromJson(inputs.services)`、summary の一覧も入力から出す
  - `reusable--docs-sync-check.yaml`: 入力 `scope-pattern`（例 `^dystopia/`）・`prompt-path`（例 `.github/prompts/docs-sync-check.md`）。`skip-unchanged` の説明文は `対象のパスに変更がありません`。environment は `docs-sync-check`、commit status の context は `Docs Sync Check` のまま
  - `reusable--renovate-major-review.yaml`: 入力 `prompt-path`（例 `.github/prompts/renovate-major-review.md`）。environment は `renovate-major-review`
  - 両方とも、job ごとの `permissions` と `timeout-minutes` は今のまま

- [ ] **Step 1: 3 つのファイルを書く**
- [ ] **Step 2: actionlint を実行する**（Task 3 Step 3 と同じ基準）
- [ ] **Step 3: Commit**（`feat: add the shared maintenance and review workflows`）

### Task 7: Renovate preset, README, and the first release

**Files:**
- Create: `default.json`（3 リポジトリの `renovate.json` に共通する部分。Global Constraints の `minimumReleaseAge` の rule を含む）
- Create: `.github/renovate.json`（`"extends": ["github>panicboat/.github"]`）
- Modify: `README.md`（Community Health Files に加えて、Shared Workflows と Renovate Preset の節を足す。呼び出し方の例を 1 つ載せる）

**Interfaces:**
- Produces: `extends: ["github>panicboat/.github"]` で読める preset

- [ ] **Step 1: 3 つの `renovate.json` の共通部分（`extends`・スケジュール・automerge の 3 rule・"Default: separate PRs per package"）を `default.json` に移す**
- [ ] **Step 2: preset を検証する**

Run: `npx --yes --package renovate renovate-config-validator default.json .github/renovate.json`（使った renovate の版を PR に書く）
Expected: 2 ファイルとも `Config validated successfully`

- [ ] **Step 3: README を書き、Commit**（`feat: add the shared renovate preset`）
- [ ] **Step 4: push して Draft PR を作り、checks を確認する**

Expected: `Ensure actions are pinned to SHAs`・`Validate PR title`・`CI Gatekeeper`・`Test scripts` が緑。Review Focus 4・5 をログで確認する

- [ ] **Step 5: ユーザーに次の 2 点を依頼して止まる**
  - `panicboat/.github` に repository variable `APP_ID` と secret `APP_PRIVATE_KEY` を設定し、App `panicboat-github-workflow-bot` の installation がこのリポジトリを含むことを確認する
  - PR を merge する
- [ ] **Step 6: merge 後、release-please の PR が開くことを確認し、ユーザーに merge を依頼して `v1.0.0` の tag の SHA を控える**

Run: `gh api repos/panicboat/.github/git/ref/tags/v1.0.0 -q .object.sha`
Expected: SHA が返る。以降の Task はこの SHA を `<sha>` として使う

---

## Repository: panicboat/platform（ruleset）

### Task 8: Relax required status checks

**Files:**
- Modify: `github/branch/master/monorepo.hcl`・`platform.hcl`・`deploy-actions.hcl`（`required_status_checks` から `CI Gatekeeper`・`Validate PR title`・`Ensure actions are pinned to SHAs` を消す。monorepo の `Docs Sync Check` は残す）

- [ ] **Step 1: 3 ファイルを直し、`terragrunt hcl fmt --check` を通す**
- [ ] **Step 2: Draft PR を作り、plan が 3 つの ruleset の `required_status_checks` の変更だけであることを tfcmt のコメントで確認する**
- [ ] **Step 3: ユーザーに merge を依頼し、apply の成功を確認する**

Run: `gh run list -R panicboat/platform --branch main --limit 3`
Expected: `Label Base Deploy - Resolver` が success

---

## Repository: panicboat/platform（切り替え）

### Task 9: Switch platform to the shared workflows

**Files:**
- Modify: `.github/workflows/{ci-gatekeeper,label-base-deploy--dispatcher,label-base-deploy--resolver,lint-actions,release--deploy,release--plan,release--please,renovate-major-review,semantic-pull-request,test-terragrunt-release}.y*ml`（呼び出し用にする）
- Delete: `.github/workflows/reusable--{kubernetes-builder,kubernetes-hydrator,terragrunt-runner}.yaml`・`.github/scripts/`
- Modify: `workflow-config.yaml`（`kubernetes` → `helmfile`）・`.github/renovate.json`（preset を extends し、固有の rule だけ残す）・`README.md`・`README-ja.md`（図の stack 名と workflow へのリンク）

**Interfaces:**
- Consumes: Task 3〜6 の reusable と入力、Task 7 の `<sha>`

- [ ] **Step 1: 呼び出し用 workflow を書く**

各ファイルは今の `name:`・`on:`・concurrency を残し、トップの `permissions` を呼び出し job に移して、job 1 つで共通版を呼ぶ。resolver の呼び出し job の permissions は `id-token: write`・`contents: write`・`pull-requests: write`。gatekeeper は `exclude-workflow-names: Renovate Major Review`。renovate-major-review は `prompt-path: .github/prompts/renovate-major-review.md`。

- [ ] **Step 2: stack 名・Renovate・README を直す**
- [ ] **Step 3: 古いパスの参照が残っていないことを確認する**

Run: `git grep -n -e '\.github/scripts' -e 'reusable--kubernetes' -e 'reusable--terragrunt-runner' -e '"stack":"kubernetes"' -- ':!docs/superpowers/**'`
Expected: 出力なし

- [ ] **Step 4: Draft PR を作り、checks を確認する**

PR に `gh pr edit <n> --add-label deploy:<service>` で、helmfile の component（例 `deploy:coredns`）と terragrunt の service（例 `deploy:vpc`）のラベルを 1 つずつ付け、helmfile の hydrate と diff、terragrunt の plan が共通版で動くことを確認する。
Review Focus 3・4 をここで確認する。

- [ ] **Step 5: 出た check の名前を記録し、ユーザーに merge を依頼する**

Run: `gh pr view <n> --json statusCheckRollup -q '.statusCheckRollup[].name'`

---

## Repository: panicboat/monorepo

### Task 10: Switch monorepo to the shared workflows

**Files:**
- Modify: `.github/workflows/{ci-gatekeeper,cleanup-container-image,docs-sync-check,label-base-deploy--dispatcher,label-base-deploy--resolver,lint-actions,release--build,release--deploy,release--plan,release--please,semantic-pull-request,test-terragrunt-release}.y*ml`（呼び出し用にする）
- Modify: `.github/workflows/deploy-dystopia-lambda.yaml`（terragrunt-runner の参照だけ替える）
- Delete: `.github/workflows/reusable--{container-builder,kubernetes-builder,terragrunt-runner}.yaml`・`.github/scripts/`
- Modify: `workflow-config.yaml`（`kubernetes` → `kustomize`）・`.github/renovate.json`・`README.md`・`README-ja.md`

**Interfaces:**
- Consumes: Task 3〜6 の reusable と入力、Task 7 の `<sha>`

- [ ] **Step 1: 呼び出し用 workflow を書く**

resolver の呼び出し job の permissions は `id-token: write`・`contents: read`・`packages: write`・`pull-requests: write`。gatekeeper は `exclude-workflow-names: Docs Sync Check`。cleanup は `services: '["monolith","frontend","pennyworth"]'`。docs-sync-check は `scope-pattern: '^dystopia/'`・`prompt-path: .github/prompts/docs-sync-check.md`、呼び出し job の permissions は `contents: read`・`pull-requests: write`・`statuses: write`・`id-token: write`。

- [ ] **Step 2: stack 名・Renovate・README を直す**
- [ ] **Step 3: Task 9 Step 3 と同じ grep で古い参照がないことを確認する**
- [ ] **Step 4: Draft PR を作り、checks を確認する**

`gh pr edit <n> --add-label deploy:monolith` を付け、kustomize diff と terragrunt plan と container build が共通版で動くこと、Docs Sync Check の status が書かれることを確認する。

- [ ] **Step 5: 出た check の名前を記録し、ユーザーに merge を依頼する**

---

## Repository: panicboat/deploy-actions

### Task 11: Switch deploy-actions PR checks

**Files:**
- Modify: `.github/workflows/lint-actions.yml`・`semantic-pull-request.yml`（呼び出し用にする）
- Modify: `.github/renovate.json`（preset を extends する）

- [ ] **Step 1: 2 つの呼び出し用 workflow と `renovate.json` を書く**
- [ ] **Step 2: Draft PR を作り、2 つの check が緑になることと名前を記録し、ユーザーに merge を依頼する**

---

## Repository: panicboat/platform（ruleset を戻す）

### Task 12: Restore required status checks with the new names

**Files:**
- Modify: `github/branch/master/monorepo.hcl`・`platform.hcl`・`deploy-actions.hcl`（Task 9〜11 で記録した新しい名前を `required_status_checks` に入れる）
- Create: `github/branch/master/dot-github.hcl`（`Ensure actions are pinned to SHAs`・`Validate PR title`・`CI Gatekeeper`・`Test scripts` の新しい名前を必須にする）
- Modify: `github/branch/master/terragrunt.hcl`（`dot-github` を足す）

- [ ] **Step 1: 4 ファイルを書き、`terragrunt hcl fmt --check` を通す**
- [ ] **Step 2: Draft PR を作り、plan が 3 つの ruleset の変更と `dot-github` の ruleset の作成だけであることを確認する**
- [ ] **Step 3: ユーザーに merge を依頼し、apply の成功を確認する**
- [ ] **Step 4: 各リポジトリの直近の PR で、必須チェックが新しい名前で満たされていることを確認する**

Run: `gh api repos/panicboat/<repo>/rules/branches/main -q '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context'`
Expected: Task 9〜11 で記録した名前と一致する
