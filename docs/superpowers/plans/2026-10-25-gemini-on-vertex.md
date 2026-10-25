# Gemini On Vertex AI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** docs-sync-check と renovate-major-review の共通 workflow を、Bedrock の Claude から Vertex AI の Gemini（`run-gemini-cli`）に切り替え、呼び出し側の prompt を合わせて直す。

**Architecture:** モデルを呼ぶ job の Claude の step を `google-github-actions/run-gemini-cli` に置き換え、直接の Workload Identity Federation で Vertex AI に入る。モデルの最終回答（JSON object）は新しい script `scripts/gemini-output/parse.sh` で検証し、今の `structured_output` と同じ形の job output にする。後続の job（`report` / `post`）は変えない。

**Tech Stack:** GitHub Actions、`google-github-actions/run-gemini-cli` v0.1.22、Gemini CLI 0.63.0、bash + jq、yq（`scripts/workflows/test.sh` の検証）

**Spec:** `docs/superpowers/specs/2026-10-25-gemini-on-vertex-design.md`

## Global Constraints

- action: `google-github-actions/run-gemini-cli@f77273f4c914e4bf38440cf36a0369cb64a37489 # v0.1.22`、`gemini_cli_version: '0.63.0'`
- 認証: `gcp_workload_identity_provider: 'projects/237641919067/locations/global/workloadIdentityPools/github-actions/providers/github'`、`gcp_project_id: 'panicboat-platform-github'`、`gcp_location: 'global'`、`gcp_token_format: ''`、`use_vertex_ai: 'true'`
- モデル: docs-sync-check は `gemini-3.5-flash-lite`、renovate-major-review は `gemini-3.8-flash`
- step の env: `GEMINI_CLI_TRUST_WORKSPACE: 'true'`、`GEMINI_SANDBOX: 'false'`、`GH_TOKEN: ${{ github.token }}`
- settings に `"security": {"environmentVariableRedaction": {"allowed": ["GH_TOKEN"]}}` を入れる
- job の `permissions`・`environment`・`timeout-minutes` は今のまま。`id-token: write` は GCP の認証に使う
- 出力の検証: `body` は 1〜60,000 文字の文字列、docs-sync-check は `passed` が boolean
- commit は `git commit -s`、`Co-Authored-By` を付けない、message は英語。コメントは 1 行で why を書く（AGENTS.md）
- `panicboat/.github` の PR のタイトルは `feat!:` で始める（呼び出し側の prompt の出力の形が変わる破壊的変更）
- merge・release・呼び出し側の固定 SHA の切り替えはユーザーが行う。Claude は Draft PR までを作る

## Review Focus

- モデルが JSON の前後に説明文を付けた、または ```` ```json ```` で囲んだ → 囲みは取り除いて読み、説明文が付いたものは不正として扱う（Task 1 のテスト）
- `passed` が文字列の `"true"` → boolean でないので不正（Task 1 のテスト）
- `body` が 60,000 文字を超える → 不正（Task 1 のテスト）
- Gemini CLI が途中で失敗し `summary` が空 → 不正として output を空にし、docs-sync-check は失敗 status になる（Task 1 のテストと Task 2 の `report` の既存の分岐）
- 許可していないコマンド（例: `gh pr comment`）をモデルが呼ぶ → 拒否される（Task 4 の試走で、実行ログの tool 呼び出しを確かめる）

---

### Task 1: モデルの最終回答を検証する script

**Files:**
- Create: `scripts/gemini-output/parse.sh`
- Test: `scripts/gemini-output/parse.test.sh`

**Interfaces:**
- Produces: `bash scripts/gemini-output/parse.sh <docs-sync|review>`。stdin にモデルの最終回答の文字列を受け取り、正しければ compact な JSON（docs-sync は `{"passed":<bool>,"body":<string>}`、review は `{"body":<string>}`）を stdout に出して exit 0。不正なら `::warning::` を stderr に出して exit 1

- [ ] **Step 1: テストを書く**

`decide.test.sh` と同じ形の `check <name> <mode> <input> <expected_exit> <expected_stdout>`。

```bash
check accepts_docs_sync_object docs-sync '{"passed":true,"body":"## Docs Sync Check"}' 0 '{"passed":true,"body":"## Docs Sync Check"}'
check accepts_failed_verdict docs-sync '{"passed":false,"body":"x"}' 0 '{"passed":false,"body":"x"}'
check strips_json_code_fence docs-sync $'```json\n{"passed":true,"body":"x"}\n```' 0 '{"passed":true,"body":"x"}'
check rejects_text_around_json docs-sync $'Here is the result:\n{"passed":true,"body":"x"}' 1 ''
check rejects_string_passed docs-sync '{"passed":"true","body":"x"}' 1 ''
check rejects_missing_passed docs-sync '{"body":"x"}' 1 ''
check rejects_empty_body docs-sync '{"passed":true,"body":""}' 1 ''
check rejects_body_over_60000 docs-sync "{\"passed\":true,\"body\":\"$(printf 'a%.0s' $(seq 60001))\"}" 1 ''
check rejects_empty_response docs-sync '' 1 ''
check accepts_review_object review '{"body":"## Renovate Major Update Review"}' 0 '{"body":"## Renovate Major Update Review"}'
check drops_extra_fields review '{"body":"x","passed":true}' 0 '{"body":"x"}'
check rejects_unknown_mode other '{"body":"x"}' 1 ''
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bash scripts/gemini-output/parse.test.sh`
Expected: `parse.sh` がないため全件 FAIL、exit 1

- [ ] **Step 3: `parse.sh` を実装する**

先頭と末尾の空白を除き、全体が 1 つの code fence（```` ```json ```` または ```` ``` ````）ならその中身だけにしてから `jq` で検証する。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bash scripts/gemini-output/parse.test.sh`
Expected: 全件 PASS、exit 0。`self--test-scripts.yaml` の `scripts/*/*.test.sh` に一致するので CI でも走る

- [ ] **Step 5: Commit**

```bash
git add scripts/gemini-output
git commit -s -m "feat: validate the final answer of Gemini as the review output"
```

---

### Task 2: docs-sync-check を Gemini に切り替える

**Files:**
- Modify: `.github/workflows/reusable--docs-sync-check.yaml`（先頭のコメント、`scope` の status 文言、`judge` job）
- Test: `scripts/workflows/test.sh`

**Interfaces:**
- Consumes: Task 1 の `parse.sh docs-sync`
- Produces: `judge` job の outputs `passed`・`body`（今と同じ名前。`report` job は変えない）

- [ ] **Step 1: テストを書く**

`scripts/workflows/test.sh` に追加する。

```bash
test_docs_sync_judge_uses_gemini_on_vertex() {
    local wf="${workflows_dir}/reusable--docs-sync-check.yaml"
    assert_eq "google-github-actions/run-gemini-cli@f77273f4c914e4bf38440cf36a0369cb64a37489" "$(yq '.jobs.judge.steps[] | select(.id == "gemini") | .uses' "${wf}")"
    assert_eq "gemini-3.5-flash-lite" "$(yq '.jobs.judge.steps[] | select(.id == "gemini") | .with.gemini_model' "${wf}")"
    assert_eq "" "$(yq '.jobs.judge.steps[] | select(.with.role-to-assume) | .name' "${wf}")"
}

test_docs_sync_judge_allows_only_read_tools() {
    local wf="${workflows_dir}/reusable--docs-sync-check.yaml"
    assert_eq '["read_file","glob","grep_search","run_shell_command(gh pr view)","run_shell_command(gh pr diff)","run_shell_command(git diff)","run_shell_command(git log)","run_shell_command(git show)"]' \
        "$(yq '.jobs.judge.steps[] | select(.id == "gemini") | .with.settings' "${wf}" | jq -c '.tools.core')"
}

test_docs_sync_status_does_not_name_a_model() {
    assert_eq "0" "$(grep -c 'Claude' "${workflows_dir}/reusable--docs-sync-check.yaml" || true)"
}
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bash scripts/workflows/test.sh`
Expected: 追加した 3 件が FAIL、既存は PASS

- [ ] **Step 3: workflow を書き換える**

- `judge` job から AWS の credential の step と Claude の step を外し、`id: gemini` の `run-gemini-cli` の step を置く（Global Constraints の値。`prompt` は今と同じ 2 行、`upload_artifacts: 'true'`）
- その後ろに `id: parse` の step を置き、`summary` を `parse.sh docs-sync` に渡す。成功したら `passed` と `body` を step output に書き、失敗したら何も書かない
- `judge` の outputs を `steps.parse.outputs.*` に向ける
- token の使用量を job summary に書く step（`if: ${{ !cancelled() }}`、`gemini-artifacts/stdout.log` の `.stats` を `jq` で出す。ファイルがなければ何もしない）
- 今の `Upload execution log` の step は外す（`upload_artifacts` が代わる）
- `scope` の status の文言を `AI が判定しています` にし、先頭のコメントを Gemini on Vertex AI に直す

- [ ] **Step 4: テストと lint を通す**

Run: `bash scripts/workflows/test.sh && aqua exec -- actionlint .github/workflows/reusable--docs-sync-check.yaml`
Expected: 全件 PASS、actionlint の出力なし

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/reusable--docs-sync-check.yaml scripts/workflows/test.sh
git commit -s -m "feat!: judge docs sync with Gemini on Vertex AI"
```

---

### Task 3: renovate-major-review を Gemini に切り替える

**Files:**
- Modify: `.github/workflows/reusable--renovate-major-review.yaml`（先頭のコメント、`review` job）
- Test: `scripts/workflows/test.sh`

**Interfaces:**
- Consumes: Task 1 の `parse.sh review`
- Produces: `review` job の output `body`（今と同じ名前。`post` job は変えない）

- [ ] **Step 1: テストを書く**

```bash
test_renovate_review_uses_gemini_on_vertex() {
    local wf="${workflows_dir}/reusable--renovate-major-review.yaml"
    assert_eq "google-github-actions/run-gemini-cli@f77273f4c914e4bf38440cf36a0369cb64a37489" "$(yq '.jobs.review.steps[] | select(.id == "gemini") | .uses' "${wf}")"
    assert_eq "gemini-3.8-flash" "$(yq '.jobs.review.steps[] | select(.id == "gemini") | .with.gemini_model' "${wf}")"
    assert_eq "" "$(yq '.jobs.review.steps[] | select(.with.role-to-assume) | .name' "${wf}")"
}

test_renovate_review_allows_only_read_tools() {
    local wf="${workflows_dir}/reusable--renovate-major-review.yaml"
    assert_eq '["read_file","glob","grep_search","web_fetch","run_shell_command(gh pr view)","run_shell_command(gh pr diff)","run_shell_command(gh api)","run_shell_command(git diff)","run_shell_command(git log)","run_shell_command(git show)","run_shell_command(helm repo add)","run_shell_command(helm repo update)","run_shell_command(helm pull)","run_shell_command(helm show)"]' \
        "$(yq '.jobs.review.steps[] | select(.id == "gemini") | .with.settings' "${wf}" | jq -c '.tools.core')"
}
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bash scripts/workflows/test.sh`
Expected: 追加した 2 件が FAIL

- [ ] **Step 3: workflow を書き換える**

Task 2 Step 3 と同じ置き換え（`parse.sh review`、output は `body` だけ）。`render` job と `post` job は変えない。aqua の setup は helm を使うので残す。

- [ ] **Step 4: テストと lint を通す**

Run: `bash scripts/workflows/test.sh && aqua exec -- actionlint .github/workflows/reusable--renovate-major-review.yaml`
Expected: 全件 PASS、actionlint の出力なし

- [ ] **Step 5: Commit して Draft PR を作る**

```bash
git add .github/workflows/reusable--renovate-major-review.yaml scripts/workflows/test.sh
git commit -s -m "feat!: review Renovate major updates with Gemini on Vertex AI"
git push -u origin HEAD
gh pr create --draft --title "feat!: run the review workflows on Gemini on Vertex AI" --body-file <本文>
```

本文は `.github/pull_request_template.md` の見出しに従う。

---

### Task 4: monorepo の prompt を直し、docs-sync-check を試走する

**Files（monorepo の worktree `.worktrees/feat-gemini-on-vertex`、ブランチ `feat/gemini-on-vertex`）:**
- Modify: `.github/prompts/docs-sync-check.md`（ツール名と `## Output`）
- Modify: `.github/workflows/docs-sync-check.yaml`（`uses:` の SHA を Task 3 の HEAD に）

**Interfaces:**
- Consumes: Task 1 の出力の形（`{"passed":<bool>,"body":<string>}`）、Task 3 の HEAD の SHA

- [ ] **Step 1: prompt を直す**

- `Read / Glob / Grep` を `read_file` / `glob` / `grep_search` に、`Glob` / `Read` の記述も同じく置き換える
- `## Output` を、最終回答を `{"passed": <boolean>, "body": <string>}` の JSON object 1 つだけにし、前後に文章や code fence を付けない、という指示にする（60,000 文字の上限の記述は残す）

- [ ] **Step 2: caller の SHA を差し替えて Draft PR を作る**

`uses:` を `panicboat/.github/.github/workflows/reusable--docs-sync-check.yaml@<Task 3 の HEAD>` にする（release までの試走用）。push して Draft PR を作る。

- [ ] **Step 3: 試走用の PR で判定させる**

Step 2 のブランチから、`dystopia/docs/` の 1 行を変える試走用のブランチを作り、Draft PR を作る（merge しない）。

Expected:
- `Docs Sync Check` の commit status が `pending` を経て `success` か `failure` になる
- PR に `## Docs Sync Check` で始まるコメントが付く
- job summary に token の使用量が出る
- 実行ログの artifact に、許可していないツールの呼び出しが成功した跡がない
- 権限不足（`aiplatform.*` の PERMISSION_DENIED）が出たら、platform の `gcp/workload-identity/modules/vertex.tf` の custom role に足す（ユーザーに相談する）

- [ ] **Step 4: 試走用の PR を閉じる**

`gh pr close <試走用 PR> --delete-branch`。

---

### Task 5: platform の prompt を直す

**Files（platform の worktree `.worktrees/feat-gemini-on-vertex`、ブランチ `feat/gemini-on-vertex`）:**
- Modify: `.github/prompts/renovate-major-review.md`（ツール名と `## Output`）
- Modify: `.github/workflows/renovate-major-review.yaml`（`uses:` の SHA を Task 3 の HEAD に）

**Interfaces:**
- Consumes: Task 1 の出力の形（`{"body":<string>}`）、Task 3 の HEAD の SHA

- [ ] **Step 1: prompt を直す**

- `Grep / Read` を `grep_search` / `read_file` に、`WebFetch` を `web_fetch` に置き換える
- `## Output` を、最終回答を `{"body": <string>}` の JSON object 1 つだけにし、前後に文章や code fence を付けない、という指示にする

- [ ] **Step 2: caller の SHA を差し替えて Draft PR を作る**

試走は merge 後に行う。renovate-major-review は Renovate が作った PR の merge commit の workflow で動くため、この PR が main に入るまで新しい版を通せない。

Expected（merge 後、ユーザーと行う）: open の Renovate の major PR から `📈 major-update` ラベルを外して付け直すと、`Renovate Major Update Review` のコメントが upsert される。

---

### Task 6: ユーザーに渡す

- [ ] **Step 1: 渡す内容をまとめる**

- `panicboat/.github` の Draft PR、monorepo・platform の Draft PR、試走の結果（status・コメント・token 数）
- merge の順番: `panicboat/.github` → release-please の PR（`v2.0.0`）→ monorepo と platform の PR の `uses:` を release の SHA に差し替えて merge
- platform の試走（Task 5 の Expected）
