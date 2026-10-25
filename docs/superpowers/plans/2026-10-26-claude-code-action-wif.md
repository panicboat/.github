# Claude Code Action With WIF Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** docs-sync-check と renovate-major-review を、Gemini（v2.0.0）から `claude-code-action`（Anthropic の Workload Identity Federation、買ったクレジット）に戻し、v3.0.0 として出す。本番で動いたら、Gemini と Bedrock の resource を片付ける。

**Architecture:** 2 つの共通 workflow の Gemini の step を `claude-code-action` に置き換える。PR の情報の事前取得（`.review-context/`）は残す。結果は `--json-schema` の structured output で受け取り、token が混ざっていないかを確かめてから後続の job に渡す。

**Tech Stack:** GitHub Actions、`anthropics/claude-code-action` v1.0.262、bash + jq、yq（`scripts/workflows/test.sh`）

**Spec:** `docs/superpowers/specs/2026-10-26-claude-code-action-wif-design.md`

## Global Constraints

- action: `anthropics/claude-code-action@925afb53776cf1a2b738c6bdbed37b4d4000ef13 # v1.0.262`
- 入力: `anthropic_federation_rule_id: fdrl_01EFTG7Y8vWedXu5dyKHk9VP`、`anthropic_organization_id: 3e6cc666-1654-4da0-9d46-3abb52bc7288`、`anthropic_service_account_id: svac_01XpqeHTNpHPf7zZSQXgck3S`、`anthropic_workspace_id: wrkspc_01Pn5wRk8fQ8vXGsUGzH66wv`、`github_token: ${{ github.token }}`
- モデルと上限: docs-sync-check は `--model claude-haiku-5-5 --max-budget-usd 0.5`、renovate-major-review は `--model claude-sonnet-5-5 --max-budget-usd 5`
- 両方に `--settings '{"permissions":{"blockReadsOutsideWorkingDirectories":true}}'`
- `--disallowedTools` の共通部分: `Write,Edit,NotebookEdit,Agent,WebSearch,Read(//home/runner/work/_temp/**),Read(./.git/**)`。docs-sync-check はさらに `Bash,WebFetch`
- `--allowedTools`: docs-sync-check は書かない。renovate-major-review は `WebFetch,Bash(helm repo add:*),Bash(helm repo update:*),Bash(helm pull:*),Bash(helm show:*)`
- `--json-schema`: docs-sync-check は `{"type":"object","properties":{"passed":{"type":"boolean"},"body":{"type":"string","minLength":1,"maxLength":60000}},"required":["passed","body"]}`、renovate-major-review は `{"type":"object","properties":{"body":{"type":"string","minLength":1,"maxLength":60000}},"required":["body"]}`
- `CLAUDE_CODE_ENTRYPOINT` などの識別子を変えない
- `panicboat/.github` の PR のタイトルは `feat!:`（v3.0.0）
- commit は `git commit -s`、`Co-Authored-By` を付けない、message は英語。コメントは 1 行で why を書き、タスクへの言及をしない（AGENTS.md）
- merge・release・本番の resource の削除はユーザーが行う。試走用の PR・ブランチ・worktree は、試走が終わったその場で閉じて消す

## Review Focus

- モデルが `body` に GitHub の token を書く → output を空にし、docs-sync-check は「判定できませんでした」になる（Task 1 のテスト）
- `structured_output` が空（action の失敗、上限で停止） → output を空にする（Task 1 のテスト）
- `/home/runner/work/_temp` の token のファイルを `Read`・`cat`・`git diff /dev/null` で読む → 拒否される（Task 3 の試走）
- `.git/config` を読む → 拒否される（Task 3 の試走）
- 作業ディレクトリの中の `Read` と `helm show` → 通る（Task 3 の試走）

---

### Task 1: docs-sync-check を `claude-code-action` に切り替える

**Files:**
- Create: `scripts/review-output/check.sh`、`scripts/review-output/check.test.sh`
- Modify: `.github/workflows/reusable--docs-sync-check.yaml`（先頭のコメント、`judge` job）、`scripts/workflows/test.sh`
- Delete: `scripts/gemini-output/`

**Interfaces:**
- Produces: `bash scripts/review-output/check.sh <docs-sync|review>`。env `STRUCTURED_OUTPUT`（action の `structured_output`）と `GITHUB_TOKEN_VALUE` を読み、正しく token を含まなければ compact な JSON を stdout に出して exit 0、それ以外は `::warning::` と exit 1
- Produces: `judge` の outputs `passed`・`body`（`steps.check.outputs.*`）

- [ ] **Step 1: `check.test.sh` を書く**（`decide.test.sh` と同じ形）

```bash
check accepts_docs_sync docs-sync '{"passed":true,"body":"x"}' tok 0 '{"passed":true,"body":"x"}'
check accepts_review review '{"body":"x"}' tok 0 '{"body":"x"}'
check rejects_empty_output docs-sync '' tok 1 ''
check rejects_body_with_token docs-sync '{"passed":true,"body":"leak tok here"}' tok 1 ''
check rejects_string_passed docs-sync '{"passed":"true","body":"x"}' tok 1 ''
check rejects_missing_body review '{}' tok 1 ''
check rejects_unknown_mode other '{"body":"x"}' tok 1 ''
check ignores_empty_token review '{"body":"x"}' '' 0 '{"body":"x"}'
```

- [ ] **Step 2: 失敗を確かめる** — Run: `bash scripts/review-output/check.test.sh` / Expected: FAIL

- [ ] **Step 3: `check.sh` を実装する**（`jq` で形と型を確かめ、`body` に `GITHUB_TOKEN_VALUE` が含まれれば拒否。空の token は無視）

- [ ] **Step 4: workflow のテストを書き換える**

`scripts/workflows/test.sh` の Gemini 用のテスト（`test_docs_sync_judge_uses_gemini_on_vertex`・`test_docs_sync_judge_allows_only_read_tools`・`test_gemini_steps_get_no_github_token`・`test_gemini_steps_record_tool_calls`）を消し、`test_review_jobs_fetch_the_pull_request_before_gemini` を `..._before_the_model` にして step id を `claude` にする。足すもの:

```bash
test_docs_sync_judge_runs_claude_code_action() {
    # uses が Global Constraints の action、with.anthropic_federation_rule_id が fdrl_01EFTG7Y8vWedXu5dyKHk9VP
    # claude_args に '--model claude-haiku-5-5'、'--max-budget-usd 0.5'、'blockReadsOutsideWorkingDirectories'、'Read(//home/runner/work/_temp/**)'、'Read(./.git/**)'
    # claude_args に '--allowedTools' がない
    # run-gemini-cli・configure-aws-credentials を使う step がない
}
```

- [ ] **Step 5: workflow を書き換える**

`judge` job の順番: Checkout（PR head）→ Fetch pull request（今のまま）→ `id: claude` の `claude-code-action`（Global Constraints の入力と `claude_args`、prompt は今の 2 行）→ Checkout shared workflows → `id: check` で `check.sh docs-sync`（成功時に `passed` と `body` をランダムな delimiter で `GITHUB_OUTPUT` に書く）→ token の使用量（`execution_file` の最後の `result` の `total_cost_usd` と `num_turns`）を job summary に書く → Upload execution log（`execution_file`、7 日）。`scope` の status の文言は今のまま（`AI が判定しています`）。`scripts/gemini-output/` を消し、`grep -rn gemini-output` を 0 件にする。

- [ ] **Step 6: テストを通す** — Run: `bash scripts/review-output/check.test.sh && bash scripts/workflows/test.sh && aqua exec -- actionlint -oneline .github/workflows/reusable--docs-sync-check.yaml` / Expected: 全件 PASS。actionlint は `job.workflow_repository` / `job.workflow_sha` の既知のエラー以外なし

- [ ] **Step 7: Commit** — `git commit -s -m "feat!: judge docs sync with claude-code-action and Anthropic WIF"`

---

### Task 2: renovate-major-review を切り替え、Draft PR を作る

**Files:**
- Modify: `.github/workflows/reusable--renovate-major-review.yaml`、`scripts/workflows/test.sh`

- [ ] **Step 1〜6:** Task 1 と同じ形（`check.sh review`、Global Constraints の renovate-major-review の値、テスト `test_renovate_review_runs_claude_code_action`。`--allowedTools` が Global Constraints どおりであることも確かめる）。aqua の setup は helm のために残す
- [ ] **Step 7: Commit、push、Draft PR** — `git commit -s -m "feat!: review Renovate major updates with claude-code-action and Anthropic WIF"`、`git push -u origin HEAD`、`gh pr create --draft --title "feat!: run the review workflows on claude-code-action with Anthropic WIF"`（本文は `.github/pull_request_template.md` の見出しに従う）

---

### Task 3: monorepo の prompt を直し、試走する

**Files（monorepo の worktree `.worktrees/feat-claude-code-action-wif`、ブランチ `feat/claude-code-action-wif`）:**
- Modify: `.github/prompts/docs-sync-check.md`（`read_file` / `glob` / `grep_search` を `Read` / `Glob` / `Grep` に、`## Output` を structured output で返す指示に。`.review-context/` を読む指示は残す）
- Modify: `.github/workflows/docs-sync-check.yaml`（`uses:` を Task 2 の HEAD の SHA に、先頭のコメントを Claude に）

- [ ] **Step 1: prompt と workflow を直し、Draft PR を作る**
- [ ] **Step 2: 試走用のブランチを作る**（Step 1 のブランチから）
  - `dystopia/docs/` を 1 行変える
  - 使い捨ての workflow `.github/workflows/permission-trial.yaml` を足す: environment `docs-sync-check`、`claude-code-action` を renovate-major-review と同じ `claude_args`（`--model claude-haiku-5-5 --max-budget-usd 0.5` にする）で動かし、prompt で次を順に試させ、結果を 1 行ずつ報告させる
    - 拒否されるべき: `Read /home/runner/work/_temp/claude-workload-identity/identity-token`、`cat /etc/passwd`、`git diff /dev/null /home/runner/work/_temp/claude-workload-identity/identity-token`、`Read .git/config`
    - 通るべき: `Read README.md`、`helm show chart oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack`（または別の public な chart）
- [ ] **Step 3: 試走用の PR を作り、結果を確かめる**

Expected:
- `Docs Sync Check` の status が `success` か `failure`、PR に `## Docs Sync Check` のコメント、job summary の `total_cost_usd` が 0.5 USD 未満
- permission-trial の実行ログで、拒否されるべき 4 つが拒否（`permission_denials` に出るか、ツールの結果がエラー）、通るべき 2 つが成功
- 拒否されるべきものが 1 つでも通ったら、試走を止めてユーザーに報告する（設定を足して、もう一度試す）

- [ ] **Step 4: 試走用の PR を閉じ、ブランチと worktree を消す** — `gh pr close <n> --delete-branch`、`git worktree remove`、`git branch -D`。`git worktree list` と GitHub のブランチ一覧に残っていないことを確かめる

---

### Task 4: platform の prompt を直す

**Files（platform の worktree `.worktrees/feat-claude-code-action-wif`）:**
- Modify: `.github/prompts/renovate-major-review.md`（`read_file` / `grep_search` / `web_fetch` を `Read` / `Grep` / `WebFetch` に、helm は Bash で実行すると書く、展開先を `helm-charts/<v>` に、`## Output` を structured output に）
- Modify: `.github/workflows/renovate-major-review.yaml`（`uses:` を Task 2 の HEAD の SHA に、先頭のコメントを Claude に）

- [ ] **Step 1: 直して Draft PR を作る**（試走は merge 後。本文にその手順を書く）

---

### Task 5: ユーザーに渡し、merge 後に renovate-major-review を試す

- [ ] **Step 1: 渡す内容** — 3 つの Draft PR、試走の結果（status・コメント・費用・拒否の確認）、merge の順番（`panicboat/.github` → release-please の PR（v3.0.0）→ monorepo と platform の `uses:` を v3.0.0 の SHA に差し替えて merge）、spend limit の付け方
- [ ] **Step 2: merge 後の試走** — platform の Renovate の major PR が `MERGEABLE` であることを確かめてから、`📈 major-update` を外して付け直す。Expected: `Renovate Major Update Review` のコメントが upsert される

---

### Task 6: Gemini 用の GCP の resource を消す（Task 5 の確認後）

**Files（platform の新しい worktree）:**
- Delete: `gcp/workload-identity/modules/vertex.tf`、`gcp/workload-identity/modules/tests/vertex.tftest.hcl`
- Modify: `gcp/workload-identity/modules/variables.tf`（`gemini_oidc_subjects`）、`outputs.tf`（`github_workload_identity_provider_name`）、`main.tf`（`aiplatform.googleapis.com`、apply role の `roles/iam.roleAdmin`）、`master/terragrunt.hcl`（`gemini_oidc_subjects`）、`modules/tests/workload_identity.tftest.hcl`（期待値）

- [ ] **Step 1: テストの期待値を先に直し、失敗を確かめる** — Run: `cd gcp/workload-identity/modules && aqua exec -- tofu test` / Expected: FAIL
- [ ] **Step 2: 消してテストを通す** — Expected: pass。手元の `make plan ENV=master` が削除だけ
- [ ] **Step 3: Draft PR を作る**。GCP の土台は消さない

---

### Task 7: Bedrock の IAM role を消す（Task 5 の確認後）

**Files（platform の新しい worktree）:**
- Delete: `aws/github-oidc-auth/modules/bedrock.tf`、`aws/github-oidc-auth/modules/tests/bedrock_role.tftest.hcl`
- Modify: `aws/github-oidc-auth/modules/variables.tf`、`master/terragrunt.hcl`、`master/env.hcl`（`bedrock_models`・`bedrock_oidc_subjects`）

- [ ] **Step 1: 参照を洗い出す** — Run: `git grep -n bedrock -- aws` / Expected: 消す対象だけ
- [ ] **Step 2: 消して、`tofu test` と `make plan ENV=master` を確かめる** — Expected: pass、Bedrock の role と policy の削除だけ
- [ ] **Step 3: Draft PR を作る**

---

### Task 8: 作ったものが残っていないことを確かめる

- [ ] **Step 1:** 3 つのリポジトリの `git worktree list`・`git branch`・GitHub のブランチ一覧・open の PR と、scratchpad と `$TMPDIR` に、この作業で作ったものが残っていないことを確かめる。残っていれば一覧にしてユーザーに確認し、消す
