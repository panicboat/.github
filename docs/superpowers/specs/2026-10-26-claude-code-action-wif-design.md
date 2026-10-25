# Claude Code Action With Workload Identity Federation Design

> **Goal**: docs-sync-check と renovate-major-review を、Vertex AI の Gemini（v2.0.0）から `claude-code-action` の Claude に戻す。認証は Anthropic の Workload Identity Federation、支払いは Console で買ったクレジットにし、月の費用を 3,000 円以内に収める。

---

## Context

### Why

- Gemini（v2.0.0）は動いたが、判定の誤りに気付きにくいことを避けたいため、Claude に戻したい（ユーザー）
- Bedrock では新しいモデルの利用申請が却下され、Vertex AI の Claude Haiku も quota の申請が却下された
- Claude Max 5x の毎月の API クレジットは、`claude-code-action` には使えない
  - Help Center の FAQ「Runs started by the Claude Code GitHub Action ... count as Claude Code usage, so API credits don't cover them, even with `-p`」（[API credits for Max and Team plans](https://support.claude.com/en/articles/17154008)）
  - 試走でも、API key・Workload Identity Federation のどちらでも `Credit balance is too low` だった（VERIFIED：panicboat/monorepo#1772）
- Agent SDK を自前で動かせば Max のクレジットで払えた（VERIFIED：panicboat/monorepo#1773）が、PR の中身から守る境界を自前で保守する負担が大きいため、採らない（ユーザー決定。Alternatives Considered）
- 買ったクレジットなら `claude-code-action` は動く（masutaka/actions#71 の報告）

### Current state

- 共通 workflow（v2.0.0）は `google-github-actions/run-gemini-cli` で Gemini を動かしている
  - PR の情報は、モデルを動かす前の step で `.review-context/pull-request.json` と `.review-context/diff.patch` に書き出している
  - モデルの最終回答は `scripts/gemini-output/parse.sh` で検証している
- 呼び出し側の prompt（monorepo の `.github/prompts/docs-sync-check.md`、platform の `.github/prompts/renovate-major-review.md`）は、Gemini CLI のツール名と「最終回答は JSON object 1 つ」の指示になっている
- Console の Workload Identity Federation は作成済みで、`claude-code-action` からの token の交換が成功している（VERIFIED：Console の認証イベント）
  - issuer `github-actions`、rule `github-workloads`（`fdrl_01EFTG7Y8vWedXu5dyKHk9VP`）、service account `github-ci-caller`（`svac_01XpqeHTNpHPf7zZSQXgck3S`）、organization `3e6cc666-1654-4da0-9d46-3abb52bc7288`、workspace `wrkspc_01Pn5wRk8fQ8vXGsUGzH66wv`（Default）
  - 条件: subject `repo:panicboat/*`、claim `repository_owner = panicboat` と `event_name = pull_request`、CEL `claims.sub in ["repo:panicboat/monorepo:environment:docs-sync-check", "repo:panicboat/platform:environment:renovate-major-review"]`、scope `workspace:developer`、token の有効期間 10 分

---

## Goals

- 2 つの workflow が `claude-code-action` で Claude を呼び、今と同じ形の結果（docs-sync-check は commit status と PR コメント、renovate-major-review は PR コメント）を出す
- Anthropic への認証に、長期の secret を使わない
- モデルが使えるツールは、読み取りのツールと許可したコマンドだけで、作業ディレクトリの外のファイルを読めない
- 月の費用が 3,000 円以内

## Non-goals

- 判定の契機や回数の変更
- 2 つの workflow を他のリポジトリから呼ぶこと

## Anti-goals

- クレジットの対象に見せるために、`CLAUDE_CODE_ENTRYPOINT` などの識別子を変えること（claude-code-action#1901 の回避策）
- モデルが OIDC token のファイルや GitHub の token を読み、コメントや WebFetch で外に出せること
- 出力が崩れたのに、docs-sync-check が `passed` と扱われること
- API key をリポジトリや GitHub の secret に置くこと

---

## Decisions

ユーザーと合意した事項。

- **`claude-code-action` を使い、Console で買ったクレジットで払う**
  - ユーザーが Console でクレジットを買う。auto-reload はオフにする
  - 予備: クレジットで問題が出たら、ユーザーの subscription の OAuth token（`claude_code_oauth_token`）に切り替える（ユーザー了承。5 時間枠に影響する）
- **認証は Workload Identity Federation**。上の Console の設定をそのまま使う。ID は識別子なので共通 workflow に直接書く
- **モデル**: docs-sync-check は `claude-haiku-5-5`、renovate-major-review は `claude-sonnet-5-5`
- **GCP の土台（プロジェクト、pool `terragrunt`、`gcp/billing`）は残し、Gemini 用の resource だけ消す**

---

## Design

### Workflow

- action: `anthropics/claude-code-action@925afb53776cf1a2b738c6bdbed37b4d4000ef13 # v1.0.262`（v1.0.0 の共通 workflow と同じ固定。以後は Renovate が更新する）
- 入力: `anthropic_federation_rule_id`・`anthropic_organization_id`・`anthropic_service_account_id`・`anthropic_workspace_id`、`github_token: ${{ github.token }}`（読み取りだけ）、`prompt`（今の 2 行）、`claude_args`
- `claude_args`: `--model`、`--json-schema`（v1.0.0 と同じ schema）、`--allowedTools`
- 結果: `steps.claude.outputs.structured_output` から `passed` / `body` を取り出す（v1.0.0 と同じ）。`scripts/gemini-output/` は消す
- PR の情報の事前取得（`.review-context/`）は今のまま残す
- 実行ログ（`execution_file`）を 7 日間 artifact に残す（v1.0.0 と同じ）

### Tool allowlist

Claude Code の permissions の仕組み（VERIFIED：[Configure permissions](https://code.claude.com/docs/en/permissions)）に合わせて、次のように絞る。

- `Read`・`Glob`・`Grep` は `--allowedTools` に書かない
  - 作業ディレクトリの中の読み取りは、もともと承認なしで動く。外の読み取りは承認が要り、非対話の実行では拒否される
  - 素の `Read` を許可リストに書くと、外の読み取りまで自動で許可してしまい、`$RUNNER_TEMP` にある OIDC token のファイルを読める
- `--settings` で `permissions.blockReadsOutsideWorkingDirectories: true` にする。読み取り専用の Bash コマンド（`cat` など）は承認なしで動くため
- `--disallowedTools` に `Read(//home/runner/work/_temp/**)` と `Read(./.git/**)` を入れる。deny rule は `cat` などの Bash のコマンドと、そこを指す symlink にも効く
  - `_temp` には、action が書く OIDC token と、交換した Anthropic の token の cache がある
  - `.git/config` には、action が `x-access-token:<github.token>` を書き込む（`src/github/operations/git-config.ts`）
- `--disallowedTools` で、使わないツール（`Write`・`Edit`・`NotebookEdit`・`Agent`・`WebSearch`、docs-sync-check ではさらに `Bash`・`WebFetch`）をモデルから見えなくする
- renovate-major-review の `--allowedTools` は `WebFetch`、`Bash(helm repo add:*)`、`Bash(helm repo update:*)`、`Bash(helm pull:*)`、`Bash(helm show:*)`
- `git` と `gh` は許さない。`git diff /dev/null <file>` で任意のファイルを読め、`--output` で書けるため（v2.0.0 の最終レビュー）。PR の情報は `.review-context/` で足りる
- **Claude の判断**: renovate-major-review の Bash では、読み取り専用のコマンド（`echo` など）が許可リストの外でも動くので、環境変数の GitHub の token（`GH_TOKEN`）は見えうる。この token は読み取り専用で job の終わりに失効するので、見えること自体は許容し、外に出す経路を下の Output の検査で止める。Anthropic の credential は上の deny rule と設定で守る
- renovate-major-review の `helm` は、PR が commit した chart の symlink をたどって外のファイルを表示できる（Agent SDK 版の検討で VERIFIED）。renovate-major-review は自分のリポジトリの Renovate の PR だけを扱い、Renovate は版の数字しか変えないので、許容する

### Output

- docs-sync-check: `{"passed": boolean, "body": string}`、renovate-major-review: `{"body": string}`（v1.0.0 と同じ `--json-schema`）
- **Claude の判断**: 投稿の前に、`body` に `github.token` の値が含まれていないかを workflow の step で確かめ、含まれていれば output を空にする（docs-sync-check は「判定できませんでした」になる）
- 実行ログの `total_cost_usd` を job summary に書く

### Cost

- ユーザーが Console で Default workspace に月 20 USD の spend limit を付ける。上限に達すると API が止まり、docs-sync-check は「判定できませんでした」になる（`docs-check-approved` ラベルで通せる）
- **Claude の判断**: `--max-turns` で 1 回あたりの上限を付ける。値は試走の実績（turn 数）の数倍にする

### Prompts

- 呼び出し側の prompt を、次の点だけ直す
  - ツール名を Claude Code のもの（`Read`・`Glob`・`Grep`・`WebFetch`、helm は Bash）にする
  - `## Output` を、structured output で返す指示（v1.0.0 の形）にする
  - renovate-major-review の chart の展開先は `helm-charts/<v>`（作業ディレクトリの中）にする
- PR の情報を `.review-context/` から読む指示と、判定・レビューの基準は変えない

### Rollout

- prompt に求める出力の形が変わるので、`feat!:` として v3.0.0 にする
- 呼び出し側では、固定する SHA の更新と prompt の修正を同じ PR に入れる
- merge の前に、monorepo の試走用の PR（release 前のブランチの commit を `uses:` に指定）で docs-sync-check を動かす。試走用の PR・ブランチ・worktree は、その場で消す
- 同じ試走用のブランチに、renovate-major-review と同じ許可の設定で動く使い捨ての workflow を足し、拒否と許可を確かめる
  - 拒否: `_temp` の token のファイル、`/etc/passwd`、`.git/config` を `Read`・`cat`・`git diff /dev/null <file>` で読ませる
  - 許可: 作業ディレクトリの中のファイルを `Read` で読み、`helm show chart <repo>/<chart>` を実行する
  - 環境は `docs-sync-check` を使う（Console の rule の CEL が受け付ける subject）。終わったらすぐ消す
- renovate-major-review は merge 後に試す。Renovate の major PR が main と conflict していないことを確かめてから、label を付け直す

### Cleanup

切り替えが本番で動いたことを確かめてから行う。

1. GCP の Gemini 用の resource を消す（platform の `gcp/workload-identity/modules/vertex.tf` と関連の変数・output・API・`roles/iam.roleAdmin`）
2. AWS の Bedrock の IAM role を消す（platform の `aws/github-oidc-auth/modules/bedrock.tf` と関連の変数）
3. この作業で作った worktree・ブランチ・試走用の PR が残っていないことを確かめる

---

## Alternatives Considered

- **Agent SDK を自前の script で動かす（Max のクレジットで払える）**: 作り始めたが、PR の中身から守る境界の保守が重いので採らない。検討で分かったこと:
  - `settingSources` を省略すると、PR の `.claude/settings.json`（hook）と `CLAUDE.md` を読み込む
  - `permissionMode: 'dontAsk'` でも、承認の要らない操作（読み取り専用の Bash など）は動く
  - path の判定は、Claude Code の `trim()` と `~` の展開を考えないと、`~/work/_temp/...` に届く
  - `helm` は、flag（`--repository-config` など）・glob の展開・PR が commit した chart の symlink・Unicode の空白・`--` で、作業ディレクトリの外を読み書きできる
- **Gemini（v2.0.0）のまま**: 動くが、判定の誤りに気付きにくいことを避けたい（ユーザー）
- **OSS の action（`dceoy/opencode-action`、`alibaba/open-code-review`）**: 認証が API key 前提で、出力の形（合否の commit status）も合わない

---

## Open Questions For The Builder

- `claude-code-action` の `claude_args` で `--settings` に JSON を渡せるか（渡せなければ action の `settings` 入力を使う）
