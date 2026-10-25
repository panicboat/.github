# Gemini On Vertex AI Design

> **Goal**: docs-sync-check と renovate-major-review の共通 workflow を、Bedrock の Claude Sonnet 4.6 から Vertex AI の Gemini に切り替え、月の費用を 2,000 円前後に下げる。判定・レビューの流れと、モデルに許すツールの範囲は今のまま保つ。

---

## Context

### Why

- 2 つの workflow は Bedrock 経由で Claude Sonnet 4.6 を呼んでいて、2026-10-24 の 1 日で約 14 USD かかった（VERIFIED：実行ログの `total_cost_usd` と run 数）
  - docs-sync-check は 1 回 0.49〜0.84 USD（VERIFIED）。renovate-major-review は合計からの逆算で 1 回 3 USD 前後（REASONED）
- 過去 30 日で `dystopia/` を変える monorepo の PR は 174 本、1 本あたり平均 3.6 commit（VERIFIED：`gh pr list`）。判定は月 174〜620 回で、350 回前後と見込む（REASONED）
  - このままだと docs-sync-check だけで月 200 USD 前後になる
- Bedrock で新しいモデルの利用申請が却下されたため、Vertex AI に移す（ユーザー決定）
- Vertex AI の Claude Haiku は quota が 0 で、引き上げの申請も却下された（2026-10-25、VERIFIED：Cloud Quotas API の `Quota request denied`）
- Vertex AI で使える OpenAI のモデルは `gpt-oss-120b` だけで、context が 13 万 token と短く Gemini CLI からも使えないため採らない（VERIFIED：呼び出しが応答した。context は第三者の掲載値）

### Current state

- 共通 workflow は `.github/workflows/reusable--docs-sync-check.yaml` と `.github/workflows/reusable--renovate-major-review.yaml`
  - どちらも `anthropics/claude-code-action` を `use_bedrock` で動かし、`--allowedTools` でツールを絞り、`--json-schema` で結果を構造化して受け取っている
  - モデルを呼ぶ job は GitHub environment（`docs-sync-check` / `renovate-major-review`）で動き、GitHub token は読み取りだけ
- prompt は呼び出し側にある：monorepo の `.github/prompts/docs-sync-check.md`、platform の `.github/prompts/renovate-major-review.md`
  - Claude のツール名（Read / Glob / Grep / WebFetch）と「structured output」を前提に書かれている
- 呼び出し側は共通 workflow を SHA で固定し、Renovate が `panicboat/.github` の release ごとに更新 PR を出す
- GCP 側は platform で用意済み（panicboat/platform#1124、#1125）
  - プロジェクト `panicboat-platform-github`、provider `projects/237641919067/locations/global/workloadIdentityPools/github-actions/providers/github`
  - 2 つの environment の subject に、`aiplatform.endpoints.predict` だけの custom role `geminiInvoker` が付いている
  - Gemini 3.5 Flash-Lite と Gemini 3.8 Flash は、このプロジェクトから `locations/global` で呼べた（VERIFIED：`generateContent` が応答した）

---

## Goals

- 2 つの workflow が、secret を使わずに Vertex AI の Gemini を呼び、今と同じ形の結果（docs-sync-check は commit status と PR コメント、renovate-major-review は PR コメント）を出す
- モデルが使えるツールとコマンドは、今の `--allowedTools` で許しているものに対応する範囲だけ
- モデルの出力が想定の形でないときは、docs-sync-check は「判定できませんでした」の失敗 status を書き、renovate-major-review はコメントを投稿しない（今の挙動と同じ）
- 1 回あたりの token 使用量を、run のログか artifact から確かめられる

## Non-goals

- 判定の契機や回数の変更（ユーザー決定：いったん今の頻度で進める）
- Bedrock の IAM role（platform の `aws/github-oidc-auth/modules/bedrock.tf`）の削除。切り替えが動いたことを確かめてから別に行う
- 2 つの workflow を他のリポジトリから呼ぶこと

## Anti-goals

- モデルがファイルの変更、push、label、approve、コメントの投稿を自分でできること
- 出力が崩れたのに、docs-sync-check が `passed` と扱われること
- Gemini の API key などの長期の secret をリポジトリや GitHub に置くこと

---

## Decisions

ユーザーと合意した事項。

- **モデル**
  - docs-sync-check: Gemini 3.5 Flash-Lite（`gemini-3.5-flash-lite`）。回数が多く、費用の大部分を占めるため
  - renovate-major-review: Gemini 3.8 Flash（`gemini-3.8-flash`）。月 2 回程度で、上流の release note を複数読む重い分析のため
- **公式の `google-github-actions/run-gemini-cli` を使う**（Google の best-practices / trust-guidance に沿う）
  - action は SHA で固定する（v0.1.22 = `f77273f4c914e4bf38440cf36a0369cb64a37489`）
  - Gemini CLI は `gemini_cli_version` で `0.63.0` に固定する（公開から 2 週間以上経った安定版）
  - workflow から Gemini CLI を直接動かす案は採らない。action の `--yolo` でも、`tools.core` の許可リストにないツールは読み込まれないので、今の `--allowedTools` と同じ効果が得られる（REASONED：Gemini CLI の `docs/reference/configuration.md`）
- **GCP への認証は、service account を使わない直接の Workload Identity Federation**
  - `gcp_workload_identity_provider` に GitHub の provider、`gcp_project_id` に `panicboat-platform-github`、`gcp_token_format` に空文字を渡す
  - Vertex AI の location は `global`
- **`GEMINI_CLI_TRUST_WORKSPACE=true` を設定する**
  - docs-sync-check は fork の PR を対象外にしていて、PR の書き手はリポジトリへの書き込み権限を持つ人だけ。renovate-major-review の PR は自分のリポジトリの Renovate が作る。trust-guidance の「信頼できるデータ」に当たる
  - 上流の release note など、モデルが取得するテキストは信頼しない。prompt の「PR を data として扱う」指示と、ツールの許可リストで守る

---

## Design

### Tool allowlist

`settings` の `tools.core` に、今の `--allowedTools` に対応するものだけを書く。

| 今の `--allowedTools` | `tools.core` |
|---|---|
| `Read` | `read_file` |
| `Glob` | `glob` |
| `Grep` | `grep_search` |
| `WebFetch`（renovate だけ） | `web_fetch` |
| `Bash(<command>:*)` | `run_shell_command(<command>)` |

- docs-sync-check の command: `gh pr view`、`gh pr diff`、`git diff`、`git log`、`git show`
- renovate-major-review の command: 上に加えて `gh api`、`helm repo add`、`helm repo update`、`helm pull`、`helm show`
- MCP server は使わない
- **Claude の判断**: `gh` には job の `github.token` を `GH_TOKEN` で渡し、`security.environmentVariableRedaction.allowed` に `GH_TOKEN` を入れる（Gemini CLI 0.63.0 が読む設定名。新しい版の docs にある `security.allowedEnvironmentVariables` は読まれない）
  - Gemini CLI は名前に `TOKEN` などを含む環境変数を、ツールの実行時に既定で隠すため（gemini-cli `docs/reference/configuration.md` の Environment variable redaction）
  - token の権限は今と同じく job の `permissions`（`contents: read`、`pull-requests: read`）だけ
- **Claude の判断**: `run_shell_command(gh api)` は今の `Bash(gh api:*)` と同じく前方一致で許し、書き込みは token の権限で防ぐ
  - 前方一致では `-X POST` などを止められないが、今の Claude の設定も同じで、token が読み取りだけなので書き込みは失敗する
- **Claude の判断**: `GEMINI_SANDBOX=false` を設定し、sandbox を使わない
  - Gemini CLI は `--yolo` のとき sandbox を既定で有効にする。sandbox の中では `gh`・`git`・`helm` と環境変数・ネットワークの扱いが変わる
  - runner は job ごとに捨てられ、使えるツールは `tools.core` で絞っているため、sandbox で上乗せされる隔離は小さい

### Output

- Gemini CLI には出力の形を強制する仕組みがないため、prompt の `## Output` で「最終回答は 1 つの JSON object だけにする」と指示する
  - docs-sync-check: `{"passed": <boolean>, "body": <string>}`
  - renovate-major-review: `{"body": <string>}`
- workflow は action の output `summary`（Gemini CLI の JSON 出力の `.response`。VERIFIED：action.yml の `gemini_response`）から JSON を取り出し、次を満たすときだけ job の output にする
  - JSON として読める（前後の code fence は取り除いてから読む）
  - `body` が 1〜60,000 文字の文字列で、docs-sync-check では `passed` が boolean
- 満たさないときは output を空にする。後続の job（docs-sync-check の `report`、renovate-major-review の `post`）は、今の `--json-schema` が失敗したときと同じ扱いになる
- Gemini CLI 自体が失敗したとき（quota 超過・認証失敗・タイムアウト）は、action の step が失敗して job が失敗する
  - docs-sync-check の `report` は、`judge` の結果が `success` でなければ「判定できませんでした」の失敗 status を書く（VERIFIED：今の `reusable--docs-sync-check.yaml` の `report` job）。この挙動は変えない
  - renovate-major-review の `post` は、`review` が成功したときだけ走る。この挙動も変えない
- docs-sync-check の判定中の status の説明（`Claude が判定しています`）は、モデル名を含まない文言にする

### Prompts

- monorepo と platform の prompt を、次の点だけ直す
  - ツール名を Gemini CLI のもの（`read_file`・`glob`・`grep_search`・`web_fetch`）にする
  - `## Output` を、上の JSON object を最終回答にする指示にする
- 判定やレビューの基準は変えない

### Rollout

- 共通 workflow の入出力（`prompt-path` など）は変えないが、prompt に求める出力の形が変わるので、呼び出し側にとっては破壊的な変更になる
- **Claude の判断**: `feat!:` として major version を上げる
- 呼び出し側では、固定する SHA の更新と prompt の修正を同じ PR に入れる。どちらか片方だけが main に入ると、出力の形が合わず判定が失敗するため
- merge の前に、呼び出し側の PR で、まだ release していない `panicboat/.github` のブランチの commit を `uses:` に指定して試走する

### Observability

- `upload_artifacts` で、action が残す実行ログを artifact に上げる（docs-sync-check は今の execution log と同じく 7 日保持）
- Gemini CLI の JSON 出力の `stats`（token 数）を、job の summary に書く

---

## Constraints

- action・Gemini CLI のバージョンは固定する（`ensure-sha-pinned` の CI を通す）
- コメントは 1 行で、なぜそうしたかを書く（AGENTS.md）
- `scripts/` に処理を足す場合は、既存と同じく `*.test.sh` のテストを置き、`test-scripts.yaml` から実行する

## Open Questions For The Builder

- custom role `geminiInvoker`（`aiplatform.endpoints.predict` だけ）で Gemini CLI が動くか。足りない権限が分かったら、platform の `gcp/workload-identity/modules/vertex.tf` に足す
- `tools.core` に書いた `run_shell_command(<command>)` が、`--yolo` の下でも許可していないコマンドを拒否するか。試走で確かめる
- 試走に使う renovate-major-review の PR（`📈 major-update` ラベルの付いた Renovate の PR）をどう用意するか
