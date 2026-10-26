# Claude Subscription With Bedrock Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** docs-sync-check と renovate-major-review を、subscription の OAuth token（AWS Secrets Manager から取得）で動かし、動かせないときは Bedrock でやり直す形にして、v3.1.0 として出す。本番で動いたら、古い environment と Console の WIF を片付ける。

**Architecture:** Claude を動かす job を `internal--claude-code-action.yaml` にまとめ、2 つの共通 workflow はそれを `$/` で呼ぶ。internal の job は environment `claude-code-action` で AWS の role を assume し、権限を絞った session で token を取り出して subscription で動かし、失敗の種類に応じて Bedrock でやり直す。AWS の role と secret は platform の `aws/github-oidc-auth` で作る。

**Tech Stack:** GitHub Actions、`anthropics/claude-code-action` v1.0.262、`aws-actions/configure-aws-credentials` v6.3.0、bash + jq、yq（`scripts/workflows/test.sh`）、OpenTofu + Terragrunt（`tofu test`）

**Spec:** `docs/superpowers/specs/2026-10-26-claude-subscription-oauth-design.md`

## Global Constraints

- action: `anthropics/claude-code-action@925afb53776cf1a2b738c6bdbed37b4d4000ef13 # v1.0.262`、`aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0`（他の action も、今の workflow と同じ SHA を使う）
- environment: `claude-code-action`（monorepo と platform で同じ）
- role: `arn:aws:iam::559744160976:role/github-oidc-auth-master-github-actions-claude-code-role`。信頼する subject は `repo:panicboat/monorepo:environment:claude-code-action` と `repo:panicboat/platform:environment:claude-code-action` だけ
- secret: `github-oidc-auth-master-claude-code-oauth-token`（ap-northeast-1）。Terraform は中身を持たない
- Bedrock: region `us-east-1`、モデルは docs-sync-check が `global.anthropic.claude-haiku-4-5-20251001-v1:0`、renovate-major-review が `global.anthropic.claude-sonnet-4-6`、`ANTHROPIC_DEFAULT_HAIKU_MODEL` は `global.anthropic.claude-haiku-4-5-20251001-v1:0`
- subscription のモデルと上限は今のまま: docs-sync-check は `claude-haiku-5-5`・`0.5`、renovate-major-review は `claude-sonnet-5-5`・`5`
- `--tools`・`--allowedTools`・`--settings '{"permissions":{"blockReadsOutsideWorkingDirectories":true}}'`・`--json-schema`・`--disallowedTools` の共通部分（`Write,Edit,NotebookEdit,Agent,WebSearch,Read(//home/runner/work/_temp/**),Read(./.git/**)`）は、今の 2 つの workflow の値を変えない。docs-sync-check の `--disallowedTools` にはさらに `Bash,WebFetch`
- AWS の credentials は `output-env-credentials: 'false'` で出し、使う step の `env` にだけ渡す。token は step の output でだけ渡し、`$GITHUB_ENV` に書かない
- fallback のときにコメントの末尾に足す行（そのまま使う）: `> ⚠️ subscription で動かせなかったため、Bedrock（\`<bedrock-model>\`）で実行しました。`
- `panicboat/.github` の PR のタイトルは `feat:`（v3.1.0）
- commit は `git commit -s`、`Co-Authored-By` を付けない、message は英語。コメントは 1 行で why を書き、タスクへの言及をしない（AGENTS.md）
- 試走用の PR・ブランチ・worktree は、試走が終わったその場で閉じて消す

## Review Focus

- token の取り出しが失敗する（secret が空・権限不足） → Bedrock でやり直し、コメントの末尾に fallback の行が付く（Task 2 のテスト、Task 4 の試走）
- subscription の実行が費用の上限・turn の上限で止まる → Bedrock に切り替えず、「判定できませんでした」になる（Task 2 のテスト）
- 実行ログがない・`result` がない失敗 → Bedrock に切り替える（Task 2 のテスト）
- renovate-major-review と同じ設定のモデルが、Bash で AWS の credentials や token を読む → 拒否されるか空（Task 4 の試走）
- token が job の log や後続の step の環境変数に出る → 出ない（Task 3 のテスト `test_token_stays_out_of_the_env`）

---

### Task 1: platform に role と secret を作る

**Files（platform の worktree `.worktrees/feat-claude-code-role`、ブランチ `feat/claude-code-role`）:**
- Create: `aws/github-oidc-auth/modules/claude_code.tf`、`aws/github-oidc-auth/modules/tests/claude_code_role.tftest.hcl`
- Modify: `aws/github-oidc-auth/modules/variables.tf`、`outputs.tf`、`master/env.hcl`、`master/terragrunt.hcl`

**Interfaces:**
- Produces: variable `claude_code_oidc_subjects`（`list(string)`、既定 `[]`。空なら何も作らない）、`claude_code_bedrock_models`（`list(string)`、`global.` を除いた model ID）
- Produces: `aws_iam_role.claude_code`（`count`）、`aws_iam_role_policy.claude_code`、`aws_secretsmanager_secret.claude_code_oauth_token`、output `claude_code_role_arn`・`claude_code_oauth_token_secret_arn`
- 中身の形は、消す前の `bedrock.tf`（`git show 9ca16133941679c9afa89194ac089c0ed30df462~1:aws/github-oidc-auth/modules/bedrock.tf`）に、secret の `GetSecretValue` の statement を足したもの

- [ ] **Step 1: テストを書く**（消す前の `bedrock_role.tftest.hcl` と同じ mock と変数）
  - `skips_claude_code_role_by_default`: `length(aws_iam_role.claude_code) == 0`、`length(aws_secretsmanager_secret.claude_code_oauth_token) == 0`
  - `creates_claude_code_role_for_listed_subjects`（`claude_code_oidc_subjects` に上の 2 つの subject、`claude_code_bedrock_models = ["anthropic.claude-haiku-4-5-20251001-v1:0", "anthropic.claude-sonnet-4-6"]`）:
    - role の名前が `github-oidc-auth-master-github-actions-claude-code-role`
    - trust の `sub` が `var.claude_code_oidc_subjects` と同じ、`aud` が `sts.amazonaws.com`
    - secret の名前が `github-oidc-auth-master-claude-code-oauth-token`
    - policy の Bedrock の 2 つの statement が、消す前のテストと同じ形（2 モデル分）
    - policy の残りの statement が `secretsmanager:GetSecretValue` だけで、Resource が secret の ARN だけ
- [ ] **Step 2: 失敗を確かめる** — Run: `cd aws/github-oidc-auth/modules && aqua exec -- tofu init -backend=false -input=false >/dev/null && aqua exec -- tofu test` / Expected: FAIL
- [ ] **Step 3: `claude_code.tf`・variables・outputs を書き、`master/env.hcl` に 2 つの値、`master/terragrunt.hcl` に入力を足す**
- [ ] **Step 4: テストと plan** — Run: `aqua exec -- tofu test`（Expected: pass）、`cd ../master && TG_TF_PATH=tofu aqua exec -- terragrunt plan -lock=false`（Expected: `3 to add, 0 to change, 0 to destroy`：role・policy・secret）。生成された `.terraform` などは `git clean -fdX -- aws/github-oidc-auth` で消す
- [ ] **Step 5: commit・push・Draft PR・merge** — `git commit -s -m "feat: add the claude-code role and the OAuth token secret for the review workflows"`。CI の plan（master は 3 to add、develop は No changes）を確かめて merge し、apply の log で `Apply complete! Resources: 3 added` を確かめる。worktree とブランチを消す

---

### Task 2: fallback を決める script

**Files（`panicboat/.github` の worktree `.worktrees/feat-claude-subscription-oauth`）:**
- Create: `scripts/review-output/fallback.sh`、`scripts/review-output/fallback.test.sh`

**Interfaces:**
- Produces: `bash scripts/review-output/fallback.sh`。env `TOKEN_OUTCOME`（`steps.token.outcome`）、`CLAUDE_OUTCOME`（`steps.claude.outcome`）、`EXECUTION_FILE`（`steps.claude.outputs.execution_file`、空でもよい）を読み、`GITHUB_OUTPUT` の形で 2 行を stdout に出す: `fallback=<true|false>` と `reason=<token-unavailable|subscription-failed|>`。exit は常に 0

- [ ] **Step 1: 上限で止まったときの `subtype` を確かめる** — 手元で `claude -p "Count from 1 to 500, one number per line." --max-budget-usd 0.0001 --output-format json` と `--max-turns 1` の版を動かし、`subtype` の値を記録する。Expected: `error_max_budget_usd` と `error_max_turns`（違えば、その値で下のテストを書き、ledger に Ruling を残す）。出力の JSON を fixture に縮めて使う
- [ ] **Step 2: テストを書く**（`check.test.sh` と同じ形）
  - `falls_back_when_the_token_is_unavailable`: `TOKEN_OUTCOME=failure` → `fallback=true`、`reason=token-unavailable`
  - `keeps_a_successful_subscription_run`: `success` / `success` → `fallback=false`
  - `falls_back_when_the_run_fails_without_a_log`: `success` / `failure` / 空 → `true`、`subscription-failed`
  - `falls_back_when_the_log_has_no_result`: ログが `[]` → `true`
  - `falls_back_on_an_error_result`: 最後の `result` の `subtype` が `error_during_execution` → `true`
  - `keeps_a_budget_stop`: `error_max_budget_usd` → `false`
  - `keeps_a_turn_stop`: `error_max_turns` → `false`
  - `reads_the_last_result`: `result` が 2 つで最後が `error_max_budget_usd` → `false`
- [ ] **Step 3: 失敗を確かめる** — Run: `bash scripts/review-output/fallback.test.sh` / Expected: FAIL
- [ ] **Step 4: 書いて通す** — Expected: PASS（全件）
- [ ] **Step 5: commit** — `git commit -s -m "feat: decide when the review falls back to Bedrock"`

---

### Task 3: internal workflow と、2 つの共通 workflow の切り替え

**Files:**
- Create: `.github/workflows/internal--claude-code-action.yaml`（`name: 'Internal - Claude Code Action'`）
- Modify: `.github/workflows/reusable--docs-sync-check.yaml`（`judge`）、`.github/workflows/reusable--renovate-major-review.yaml`（`review`）、`scripts/workflows/test.sh`

**Interfaces:**
- Consumes: Task 2 の `fallback.sh`、既存の `check.sh <docs-sync|review>`
- Produces: `internal--claude-code-action.yaml` の `workflow_call`
  - inputs（すべて `type: string`、`setup-aqua` だけ `boolean`）: `prompt-path`、`output-kind`（`docs-sync` か `review`）、`model`、`bedrock-model`、`tools`、`allowed-tools`（既定 `''`）、`extra-disallowed-tools`（既定 `''`）、`max-budget-usd`、`allowed-bots`（既定 `''`）、`checkout-ref`（既定 `''`）、`download-artifact-name`（既定 `''`）、`download-artifact-path`（既定 `''`）、`setup-aqua`（既定 `false`）、`execution-log-name`
  - outputs: `body`、`passed`、`backend`（`subscription` か `bedrock`）
  - job `claude`: `environment: claude-code-action`、`timeout-minutes: 30`、permissions `contents: read`・`pull-requests: read`・`id-token: write`
- step の id（この順）: `fetch-pull-request` → `aws-secrets` → `token` → `claude` → `fallback` → `aws-bedrock` → `claude-bedrock` → `check`（あとに cost の summary と artifact の upload）
- 呼び出し側の値:
  - docs-sync-check: `output-kind: docs-sync`、`model: claude-haiku-5-5`、`bedrock-model: global.anthropic.claude-haiku-4-5-20251001-v1:0`、`tools: Read,Glob,Grep`、`extra-disallowed-tools: Bash,WebFetch`、`max-budget-usd: '0.5'`、`checkout-ref: ${{ github.event.pull_request.head.sha }}`、`execution-log-name: docs-sync-check-execution`
  - renovate-major-review: `output-kind: review`、`model: claude-sonnet-5-5`、`bedrock-model: global.anthropic.claude-sonnet-4-6`、`tools: Read,Glob,Grep,Bash,WebFetch`、`allowed-tools: WebFetch,Bash(helm repo add:*),Bash(helm repo update:*),Bash(helm pull:*),Bash(helm show:*)`、`max-budget-usd: '5'`、`allowed-bots: renovate`、`download-artifact-name: render-diff`、`download-artifact-path: .render-diff`、`setup-aqua: true`、`execution-log-name: renovate-major-review-execution`

- [ ] **Step 1: `scripts/workflows/test.sh` を書き直す**（今の Claude の step を見るテストを、internal を見るテストに置き換える。`test_docs_sync_status_does_not_name_a_model` は残す）
  - `test_claude_job_runs_in_the_claude_code_action_environment`: environment が `claude-code-action`、permissions が上の 3 つだけ
  - `test_claude_job_orders_its_steps`: 上の id の並び
  - `test_claude_step_uses_the_subscription_token`: `with.claude_code_oauth_token` が `${{ steps.token.outputs.token }}`。`anthropic_api_key` と `anthropic_*_id` がない
  - `test_claude_steps_keep_the_permission_settings`: `claude` と `claude-bedrock` の両方の `claude_args` に、`blockReadsOutsideWorkingDirectories`・`--tools "${{ inputs.tools }}"`・共通の `--disallowedTools`・`--max-budget-usd ${{ inputs.max-budget-usd }}` がある
  - `test_bedrock_step_runs_only_on_fallback`: `claude-bedrock` と `aws-bedrock` の `if` が `steps.fallback.outputs.fallback == 'true'` を含み、`use_bedrock` が `'true'`、`--model ${{ inputs.bedrock-model }}`、`ANTHROPIC_DEFAULT_HAIKU_MODEL` が Global Constraints の値
  - `test_aws_credentials_stay_out_of_the_job_env`: `configure-aws-credentials` の step が 2 つで、どちらも `output-env-credentials: 'false'`・`output-credentials: 'true'`・`inline-session-policy` がある。`aws-secrets` の policy は `secretsmanager:GetSecretValue` だけ、`aws-bedrock` の policy は `bedrock:InvokeModel` と `bedrock:InvokeModelWithResponseStream` だけ
  - `test_token_stays_out_of_the_env`: `token` の step の `run` に `::add-mask::` があり、`GITHUB_ENV` がない。`continue-on-error` が `true`
  - `test_claude_job_scrubs_secrets_when_bash_is_enabled`: bubblewrap の step の `if` と、両方の claude の step の `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` が `contains(inputs.tools, 'Bash')` に従う
  - `test_review_jobs_call_the_claude_job`: `judge` と `review` の `uses` が `$/.github/workflows/internal--claude-code-action.yaml`、`with` が上の呼び出し側の値と同じ
- [ ] **Step 2: 失敗を確かめる** — Run: `bash scripts/workflows/test.sh` / Expected: 新しいテストが FAIL
- [ ] **Step 3: internal workflow を書き、2 つの共通 workflow の job を呼び出しに置き換える**
  - `token` の step: `aws-secrets` の output の credentials を `env` に入れ、`aws secretsmanager get-secret-value --region ap-northeast-1 --secret-id github-oidc-auth-master-claude-code-oauth-token --query SecretString --output text` の値を `::add-mask::` してから、ランダムな delimiter で `GITHUB_OUTPUT` の `token` に書く
  - `check` の step: `backend` に応じて `steps.claude-bedrock.outputs.structured_output` か `steps.claude.outputs.structured_output` を `check.sh ${{ inputs.output-kind }}` に渡す。`backend` が `bedrock` なら body の末尾に Global Constraints の行を足し、`::warning::` と job summary に `reason` を書く
  - cost の summary と artifact の upload は、`claude` と `claude-bedrock` の実行ログの両方を扱う
  - 古い `judge` / `review` job の step（Checkout から Upload まで）は消す
- [ ] **Step 4: テスト** — Run: `bash scripts/review-output/check.test.sh && bash scripts/review-output/fallback.test.sh && bash scripts/workflows/test.sh && aqua exec -- actionlint -oneline .github/workflows/internal--claude-code-action.yaml .github/workflows/reusable--docs-sync-check.yaml .github/workflows/reusable--renovate-major-review.yaml` / Expected: 全件 PASS。actionlint は main と同じ `job.workflow_*` の指摘だけ
- [ ] **Step 5: commit・push・Draft PR** — `git commit -s -m "feat: run the review workflows on the Claude subscription with a Bedrock fallback"`、`gh pr create --draft --title "feat: run the review workflows on the Claude subscription with a Bedrock fallback"`（本文は `.github/pull_request_template.md` に従う）

---

### Task 4: monorepo で試走する

**Files（monorepo の worktree `.worktrees/trial-claude-subscription-oauth`、ブランチ `trial/claude-subscription-oauth`。試走が終わったら消す）:**
- Modify: `.github/workflows/docs-sync-check.yaml`（`uses:` を Task 3 の HEAD の SHA に）、`dystopia/docs/README.md`（1 行）
- Create: `.github/workflows/permission-trial.yaml`、`.github/prompts/permission-trial.md`

- [ ] **Step 1: fallback の経路** — secret が空のまま試走用の PR（Draft）を作る。Expected: `Docs Sync Check` の status が `success` か `failure`、コメントの末尾に fallback の行、job summary に `token-unavailable`、Bedrock の実行ログの init の `model` が `global.anthropic.claude-haiku-4-5-20251001-v1:0`
- [ ] **Step 2: 権限** — `permission-trial.yaml` は internal workflow を `uses: panicboat/.github/.github/workflows/internal--claude-code-action.yaml@<Task 3 の SHA>` で、renovate-major-review と同じ入力（`output-kind: review`、`prompt-path: .github/prompts/permission-trial.md`）で呼ぶ。prompt は `echo $AWS_ACCESS_KEY_ID`・`echo $AWS_SESSION_TOKEN`・`echo $CLAUDE_CODE_OAUTH_TOKEN`・`echo $HOME`・`Read README.md` を 1 回ずつ試させ、出力の文字数だけを返させる。Expected: AWS と token の 3 つは拒否か 0 文字、`$HOME` と `README.md` は通る。拒否されるべきものが 1 つでも通ったら、試走を止めてユーザーに報告する
- [ ] **Step 3: token を入れてもらう** — ユーザーに次を案内し、終わるまで待つ
  - `claude setup-token` で token を発行し、表示された token を clipboard にコピーする
  - `pbpaste | aws secretsmanager put-secret-value --region ap-northeast-1 --secret-id github-oidc-auth-master-claude-code-oauth-token --secret-string file:///dev/stdin`
  - 確認（値は読まない）: `aws secretsmanager describe-secret --region ap-northeast-1 --secret-id github-oidc-auth-master-claude-code-oauth-token --query 'VersionIdsToStages'` に `AWSCURRENT` がある
- [ ] **Step 4: subscription の経路** — 試走用の PR を空の commit で動かし直す。Expected: status とコメント（fallback の行なし）、実行ログの init の `model` が `claude-haiku-5-5`、Bedrock の step が skip
- [ ] **Step 5: 片付け** — `gh pr close <n> --delete-branch`、`git worktree remove`、`git branch -D`。`git worktree list` と GitHub のブランチ一覧に残っていないことを確かめる

---

### Task 5: release と呼び出し側の切り替え

**Files（monorepo と platform の worktree `.worktrees/feat-claude-subscription-oauth`）:**
- Modify: monorepo `.github/workflows/docs-sync-check.yaml`、platform `.github/workflows/renovate-major-review.yaml`（`uses:` を v3.1.0 の SHA に）

- [ ] **Step 1:** Task 3 の PR を merge し、release-please の PR（v3.1.0）を merge する。`git rev-parse v3.1.0^{commit}` で SHA を取る
- [ ] **Step 2:** 2 つの呼び出し側の `uses:` を `<SHA> # v3.1.0` にし、`git commit -s -m "chore: pin <workflow> to the v3.1.0 release of the shared workflows"`、Draft PR、CI を確かめて merge する
- [ ] **Step 3: renovate-major-review を試す** — platform の Renovate の major PR で、`merge_commit_sha` の `renovate-major-review.yaml` が `# v3.1.0` を指すことを確かめ（古ければ Renovate の rebase のチェックボックスで更新する）、`📈 major-update` を付け直す。Expected: レビューのコメントが upsert され、実行ログの init の `model` が `claude-sonnet-5-5`、`tools` が `Bash,Glob,Grep,Read,StructuredOutput,WebFetch`
- [ ] **Step 4:** 呼び出し側の worktree とブランチを消す

---

### Task 6: 片付け

- [ ] **Step 1: 古い environment を消す** — `gh api -X DELETE repos/panicboat/monorepo/environments/docs-sync-check`、`gh api -X DELETE repos/panicboat/platform/environments/renovate-major-review`。`gh api repos/panicboat/<repo>/environments --jq '.environments[].name'` に残っていないことを確かめる
- [ ] **Step 2: Console の WIF をユーザーに消してもらう** — Console → Settings → Workload identity で、rule `github-workloads`、service account `github-ci-caller`、issuer `github-actions` の順に消す手順を案内する
- [ ] **Step 3: 残り物の確認** — 3 つのリポジトリの `git worktree list`・`git branch`・GitHub のブランチ一覧・open の PR と、scratchpad と `$TMPDIR` に、この作業で作ったものが残っていないことを確かめる。残っていれば消す
