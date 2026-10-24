# Shared Workflows Design

## Intent

monorepo と platform には、同じか酷似した GitHub Actions の workflow と scripts が並んでいる。
ほとんど同じものが 2 つあると、片方だけ直し忘れ、二重にあること自体も気持ち悪い（ユーザーの言葉）。
実際に、コピー後に scripts の中身がずれ、release-please の PR を除外する条件が片方にだけある。
workflow と scripts の正本を `panicboat/.github` の 1 か所に置き、各リポジトリはそれを呼ぶだけにする。

## Goals

- 両リポジトリで共通する処理の正本を `panicboat/.github` に 1 つだけ置く。
- 片方のリポジトリにしかない汎用的な処理（container の build・cleanup、renovate-major-review、docs-sync-check、helmfile の hydrate）も `panicboat/.github` に置く。
- 正本を直したら、Renovate の更新 PR で各リポジトリに届き、取り込み忘れが起きない。
- 各リポジトリの `workflow-config.yaml` を見れば、どの stack にどの処理が走るか分かる。

## Non-goals

- `deploy-dystopia-lambda.yaml` は集約しない。
  - トリガーの paths から build の手順まで dystopia 専用で、集約しても dystopia 専用の workflow が置き場を変えるだけになるため（ユーザー決定）。
- 汎用化した処理を、今使っていないリポジトリから呼ぶようにはしない（呼び出し用 workflow を足さない）。
  - 例えば platform で docs-sync-check を、monorepo で renovate-major-review を動かすには、Bedrock の OIDC subject と GitHub environment を足す別の作業が要る。
- deploy-actions の composite action（label-dispatcher・label-resolver）は動かさない。

## Anti-goals

- 共通版を直したのに、呼び出し側の CI を通らないまま全リポジトリに効く状態にはしない。
  - そのため `@main` 参照ではなく SHA 固定と Renovate を選んだ（ユーザー決定）。
- 同じ stack 名が、リポジトリによって別の処理を指す状態を残さない。
- 切り替えの途中で、必須チェックが満たせず PR を merge できない期間を作らない。

## Current State

2026-10-25 時点の `origin/main` で比べた結果。

- 中身が完全に同じもの
  - `lint-actions.yml`・`semantic-pull-request.yml`（deploy-actions とも、先頭のコメント 1 行を除いて同じ）
  - `release--plan.yaml`・`reusable--terragrunt-runner.yaml`
- コメントや description の文言だけが違うもの
  - `release--please.yaml`・`release--deploy.yaml`・`test-terragrunt-release.yaml`
- わずかに違うもの
  - `label-base-deploy--dispatcher.yaml` は、platform にだけ `if: ${{ !startsWith(github.head_ref, 'release-please--') }}` がある。
  - `ci-gatekeeper.yaml` は、除外する workflow 名（monorepo は `Docs Sync Check`、platform は `Renovate Major Review`）だけが違う。
- 骨格だけが共通のもの
  - `label-base-deploy--resolver.yaml` は、monorepo が terragrunt・container・kubernetes（kustomize overlay の diff）を、platform が terragrunt・kubernetes（helmfile の hydrate と diff）を扱う。
  - `reusable--kubernetes-builder.yaml` は、monorepo が `inputs.path` の overlay を、platform が `kubernetes/manifests/{environment}/{service}` を diff する。
- 中身がずれた scripts
  - `.github/scripts/terragrunt-release/` は、monorepo 版がパスのテンプレートと `--all` に対応し、platform 版は `aws/{service}` を前提にしている。
- 片方にしかないもの
  - monorepo: `reusable--container-builder.yaml`・`release--build.yaml`・`cleanup-container-image.yaml`・`docs-sync-check.yaml`（scripts と prompt を含む）・`deploy-dystopia-lambda.yaml`
  - platform: `reusable--kubernetes-hydrator.yaml`・`renovate-major-review.yaml`（scripts `kubernetes-hydrate/` と prompt を含む）
- `panicboat/.github` には、issue テンプレートと PR テンプレートがすでにある（panicboat/.github#1）。

## Decisions

ユーザーが決めたこと。

- 正本の置き場は `panicboat/.github` にする。
  - deploy-actions は、デプロイを取りまとめる汎用ツールキットとして公開しており、PR タイトル検査や gatekeeper のような panicboat 専用の CI を入れると役割と名前がずれるため。
- 各リポジトリは正本を SHA で固定して参照し、`panicboat/.github` の release ごとに Renovate が更新 PR を出す。
  - minor と patch は、各リポジトリの既存の Renovate 設定で自動 merge される。
- 範囲は、resolver と kubernetes-builder を含めて、両リポジトリで重複するものすべてと、片方にしかない汎用的なものすべて。
  - container まわり（container-builder・release--build・cleanup-container-image）と release まわり（please・plan・deploy・build）を含む。
- `deploy-dystopia-lambda.yaml` は monorepo に残す。
- kubernetes の 2 種類の処理は、`workflow-config.yaml` の stack 名を分けて区別する。
  - monorepo の `kubernetes` は kustomize overlay の diff、platform の `kubernetes` は helmfile の hydrate と diff を指している。
- PR テンプレートは 1 ファイルのままにする。

## Design

### Distribution

- `panicboat/.github` は release-please でリポジトリ全体に 1 つのバージョン（`vX.Y.Z`）を付ける。
- 各リポジトリの呼び出しは `uses: panicboat/.github/.github/workflows/<name>.yaml@<sha> # vX.Y.Z` の形にする。
  - lint-actions（SHA 固定の検査）をそのまま満たす。
- Renovate の github-actions manager が、この参照の SHA とコメントのバージョンを更新する PR を出す。

### Caller Workflows

- 各リポジトリの `.github/workflows/` には、トリガー（`on:`）・concurrency・権限・入力だけを書いた呼び出し用の workflow を残す。
  - GitHub が実行するのは、そのリポジトリにある workflow だけだから。
- リポジトリ固有の値は、呼び出すときの入力で渡す。
  - 例: gatekeeper の除外リスト、cleanup するサービスの一覧、docs-sync-check の対象パスと prompt のパス。

### Self Checkout

- 共通の workflow は、呼び出し元を checkout したあと、`${{ job.workflow_repository }}` を `${{ job.workflow_sha }}` で別のパスに checkout し、そこにある scripts を実行する。
  - reusable workflow の中の `actions/checkout` は呼び出し元を取ってくるので、`bash .github/scripts/...` のままでは呼び出し元の scripts が走るため。
  - 呼び出し元が固定した 1 つの SHA で、workflow と scripts が揃う。
- prompt のように中身がリポジトリ固有のものは、呼び出し元のファイルを読む。

### Stack Names

- monorepo の `kubernetes` stack を `kustomize` に、platform の `kubernetes` stack を `helmfile` に改名する。
- 共通の resolver は stack ごとに job を持ち、各 job は targets にその stack があるときだけ動く。
  - `terragrunt`: terragrunt-runner で、PR では plan、main への push では `apply_trigger: merge` の target だけ apply する。
  - `container`: container-builder で build と push をする。
  - `kustomize`: PR で overlay の kustomize diff をコメントする。
  - `helmfile`: PR で hydrate して manifest を commit し、hydrate 後の manifest の diff をコメントする。
- stack 名を参照している箇所（各リポジトリの `workflow-config.yaml`・README の図・`terragrunt-release/test.sh` の fixture）も書き換える。
  - deploy-actions は stack 名を固定で書いていない（`git grep` で確認済み）。

### Scripts

- `terragrunt-release/` は monorepo 版を元に統一する。
  - `release-targets.sh` はパスのテンプレートを読むので、platform の `aws/{service}/{environment}` と `github/{service}/{environment}` も同じ実装で扱える。
- `check-release-configs.sh` は、release-please の package と `exclude-paths` をパスのテンプレートから求める形に直す。
  - monorepo 版は package を `working_directory` の `/infrastructure/` で切って求めていて、platform の配置では失敗する（builder check で platform の `origin/main` に対して実行して確認済み）。
  - package は、パスのテンプレートの先頭から `{service}` までにあたるパスにする（monorepo は `dystopia/frontend`、platform は `aws/vpc`）。
  - `exclude-paths` は、release 以外の環境の `working_directory` にする（monorepo は `dystopia/frontend/infrastructure/aws/develop`、platform は `aws/vpc/master` と `aws/vpc/develop`）。
  - この規則は、両リポジトリの今の `release-please-config.json` と一致するので、どちらの配置も変えない。
- scripts の単体テスト（`terragrunt-release/test.sh`・`docs-sync-check/decide.test.sh`・`kubernetes-hydrate/tests/`）は `panicboat/.github` の CI で実行する。
- 各リポジトリの設定の検証（`validate-apply-trigger.sh`・`check-release-configs.sh` を自分の `workflow-config.yaml` に対して実行すること、production が `release` であることの確認）は、各リポジトリの呼び出し用 workflow から共通の workflow を呼んで行う。

### Permissions And Secrets

- 共通の workflow は `permissions` を宣言しない。
  - 呼び出す側の job が、そのリポジトリで必要な分だけを付ける。
  - 呼ばれた側が宣言すると、使わない stack の分まで全リポジトリが付ける必要が出るため。
- GitHub App の id と秘密鍵は、今と同じく入力（`app-id`）と secret（`private-key`）で明示的に渡す。
- Bedrock の role ARN は、全リポジトリで同じ master アカウントの role なので、共通の workflow に書いてよい。
  - OIDC の subject は呼び出し元のリポジトリと environment で決まるので、既存の 2 つの subject はそのまま使える。

### Required Status Checks

- reusable workflow を経由すると、check の名前は `<呼び出し側の job 名> / <呼ばれた側の job 名>` になる。
- platform の `github/branch/master/*.hcl` にある必須チェック（`CI Gatekeeper`・`Validate PR title`・`Ensure actions are pinned to SHAs`）を新しい名前に直す。
  - `Docs Sync Check` は workflow が書く commit status なので、名前は変わらない。
- ruleset は platform の PR を merge した後の apply でしか変わらず、`admin_bypass` は `false` なので、切り替え PR は古い名前を待ったまま merge できなくなる。
- そのため、切り替えの間だけ必須チェックを外す（ユーザー決定）。
  - 外す前と戻した後の platform の PR で、monorepo・platform・deploy-actions の 3 つの ruleset をまとめて変える。
  - 外している間は CI が落ちていても merge できるので、切り替え PR は check が通ったことを確かめてから merge する。

### Renovate Preset

- 3 リポジトリの `renovate.json` に共通する部分を、`panicboat/.github` の Renovate preset に移す。
- 各リポジトリの `renovate.json` は preset を `extends` し、リポジトリ固有の設定（monorepo の go.mod の custom manager、OpenTofu の `required_version` の扱いなど）だけを残す。

### Own CI Of .github

- `panicboat/.github` 自身も、共通の lint-actions・semantic-pull-request・gatekeeper を `./` で呼ぶ。
- release-please と、scripts の単体テストを持つ。
- branch ruleset を platform の `github/branch/master/` に足し、上の check を必須にする。

## Migration Order

1. `panicboat/.github` に共通の workflow・scripts・テスト・自身の CI・release-please・Renovate preset を入れ、最初の release を出す。
2. platform で、monorepo・platform・deploy-actions の必須チェックを外す。
3. platform を切り替える（呼び出し用 workflow、`helmfile` への改名、`renovate.json`）。
4. monorepo を切り替える（呼び出し用 workflow、`kustomize` への改名、`renovate.json`）。
5. deploy-actions の lint-actions と semantic-pull-request を切り替え、`renovate.json` を直す。
6. platform で、3 つのリポジトリの必須チェックを新しい名前で戻し、`panicboat/.github` の ruleset を足す。

- 各リポジトリの切り替えは、その PR 自身の CI で共通の workflow が動くことで確かめる。
- 6 の新しい名前は、3〜5 の PR に実際に出た check の名前から取る。

## Calls Made By Claude

ユーザーが確認していない、設計者の判断。

- dispatcher の release-please 除外条件は、両リポジトリで有効にする。
  - monorepo にも release--plan があり、除外しないと release-please の PR を deploy ラベルと release--plan で二重に plan するため。
- 共通の workflow のファイル名は、今の名前を基本にする。
  - 呼ばれる側は `reusable--<今の名前>`（例: `reusable--label-base-deploy--resolver.yaml`、`reusable--lint-actions.yaml`）にし、`panicboat/.github` 自身の呼び出し用 workflow と区別する。
  - 各リポジトリの呼び出し用 workflow は今のファイル名のままにする。
- platform の resolver にある `terragrunt-shared` stack の除外は、どの `workflow-config.yaml` にもない stack なので、移すときに消す。
- container-builder の runner は今と同じ `ubuntu-26.04-arm` にする。

## Left To The Builder

- 共通の workflow の入力の名前と粒度。
- 共通の resolver の job 構成（stack ごとの job の分け方、summary job の書き方）。
- Renovate preset のファイル名と、共通部分と固有部分の切り分けの細部。
- `panicboat/.github` の release-please の設定（release type、changelog の形）。
- 各リポジトリの README の図と説明の更新。
