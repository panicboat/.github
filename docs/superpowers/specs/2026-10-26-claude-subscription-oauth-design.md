# Claude Subscription With Bedrock Fallback Design

> **Goal**: docs-sync-check と renovate-major-review の `claude-code-action` を、Console のクレジット（Anthropic の Workload Identity Federation）から、ユーザーの Claude subscription（Max 5x）の OAuth token で動かす形にする。subscription で動かせないときだけ Bedrock でやり直す。

---

## Context

### Why

- 費用の管理を subscription 1 本にまとめたい（ユーザー）
  - Console の Workload Identity Federation の設定は消したい（ユーザー）
- OAuth token を各リポジトリの secret に置きたくない（ユーザー）
- environment を workflow ごとに管理するのは手間なので、せめてリポジトリごとにしたい（ユーザー）
- subscription の 5 時間枠を使い切ったときや token の失効で判定が止まるのは避けたいので、Bedrock に切り替えたい（ユーザー）

### Current state

- 共通 workflow（v3.0.0）は、Console の Workload Identity Federation で `claude-code-action` を動かしている（`docs/superpowers/specs/2026-10-26-claude-code-action-wif-design.md`）
  - docs-sync-check は `claude-haiku-5-5`、renovate-major-review は `claude-sonnet-5-5`
  - environment は docs-sync-check が `docs-sync-check`（monorepo）、renovate-major-review が `renovate-major-review`（platform）
  - モデルに見せるツール（`--tools`）、deny rule、renovate-major-review の secret の scrub（bubblewrap）、`check.sh` は、試走で効くことを確かめてある
- AWS の Bedrock の role（`github-oidc-auth-master-github-actions-bedrock-role`）は platform#1184 で消した。消す前の定義は `aws/github-oidc-auth/modules/bedrock.tf`（platform の `9ca1613~1`）にある
- master アカウント（559744160976）の Bedrock で呼べる Claude は `claude-haiku-4-5` と `claude-sonnet-4-6`。`claude-haiku-5-5`・`claude-sonnet-5-5`・`claude-sonnet-5` は `not available for this account`（VERIFIED：us-east-1 で `aws bedrock-runtime converse`）

---

## Goals

- 2 つの workflow が、subscription の OAuth token で Claude を呼び、今と同じ形の結果を出す
- OAuth token は AWS Secrets Manager の 1 か所にだけ置き、job は GitHub の OIDC で AWS に入って取り出す
- subscription で動かせなかったとき（5 時間枠の上限、token の失効、API の障害）は、同じ job の中で Bedrock でやり直す
- environment は、両リポジトリで共通の `claude-code-action` 1 つにする

## Non-goals

- 判定の契機や回数、prompt、出力の形の変更
- token の自動更新（約 1 年ごとに手で差し替える）

## Anti-goals

- OAuth token が、tfstate・リポジトリ・GitHub の secret・job の log・後続の step の環境変数に残ること
- 費用の上限（`--max-budget-usd`）で止まった実行や、`check.sh` が弾いた出力を Bedrock でやり直して、費用を重ねること
- 今の権限の絞り方（`--tools`、deny rule、scrub、`check.sh`）を緩めること
- plan / apply の role を、`claude-code-action` の environment の job から assume できること

---

## Decisions

ユーザーと合意した事項。

- **支払いは subscription の OAuth token**（`claude_code_oauth_token`）。5 時間枠を使うことは了承済み
- **token は AWS Secrets Manager**（master アカウント）に置く
- **environment は `claude-code-action`**（monorepo と platform で同じ名前）
- **fallback は Bedrock**。費用の上限で止まったときは切り替えない
- **Console の Workload Identity Federation の設定は消す**
- 作業は worktree で行い、spec と plan は commit する

---

## Design

### AWS（platform の `aws/github-oidc-auth`、master）

- **Claude の判断**: 消した Bedrock の role を作り直し、Secrets Manager の権限もこの role に足して、1 つの role にまとめる
  - 名前: `github-oidc-auth-master-github-actions-claude-code-role`
  - 信頼する subject: `repo:panicboat/monorepo:environment:claude-code-action` と `repo:panicboat/platform:environment:claude-code-action` だけ（`aud` は `sts.amazonaws.com`）
  - 権限:
    - 下の secret の `secretsmanager:GetSecretValue`
    - Bedrock の `InvokeModel`・`InvokeModelWithResponseStream`（`global.anthropic.claude-haiku-4-5-20251001-v1:0` と `global.anthropic.claude-sonnet-4-6` の inference profile と、その先の foundation model。消す前の `bedrock.tf` と同じ形）
- secret: `github-oidc-auth-master-claude-code-oauth-token`（ap-northeast-1）
  - 値は key-value の JSON（`{"CLAUDE_CODE_OAUTH_TOKEN": "<token>"}`）にする（ユーザー）。項目を足せるようにするため
  - **Claude の判断**: Terraform で作るのは中身が空の secret だけにする。値（`aws_secretsmanager_secret_version`）を Terraform で持つと tfstate に平文が残るため
  - 値はユーザーが `claude setup-token` で発行し、`aws secretsmanager put-secret-value` で入れる。shell の履歴に残らないよう、値はファイルか標準入力から渡す（手順は plan に書く）
- テストは `aws/github-oidc-auth/modules/tests/` に、消す前の `bedrock_role.tftest.hcl` と同じ形で書く

### Workflow（panicboat/.github）

- Claude を動かす job を、internal の reusable workflow `internal--claude-code-action.yaml` にまとめる（ユーザー）
  - 既存の `internal--*.yaml` と同じく、共通 workflow の中から `$/` で呼び、他のリポジトリからは呼ばない
  - docs-sync-check は `scope` → `judge`（internal を呼ぶ）→ `report`、renovate-major-review は `render` → `review`（internal を呼ぶ）→ `post` にする
  - **Claude の判断**: 入力は次のとおり。値は今の 2 つの workflow の値をそのまま渡す
    - prompt の path、出力の種類（`docs-sync` か `review`。`--json-schema` と `check.sh` の mode を決める）
    - subscription のモデル、Bedrock のモデル、`--tools`、`--allowedTools`、`--max-budget-usd`
    - 準備: checkout の ref（docs-sync-check は PR の head、renovate-major-review は既定）、取得する artifact の名前（renovate-major-review の `render-diff`。空なら取らない）、aqua を入れるか
    - 実行ログの artifact の名前
  - 出力: `body`、`passed`（`docs-sync` のときだけ）、動いた方（`subscription` か `bedrock`）
  - **Claude の判断**: `--tools` に `Bash` があるときだけ、bubblewrap を入れて `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` を有効にする
  - environment `claude-code-action` と job の権限（`contents: read`、`pull-requests: read`、`id-token: write`）は internal の中に書く
- internal の job の流れ:
  1. Checkout・Fetch pull request（`.review-context/`）・artifact の取得・aqua・bubblewrap（入力に応じて）
  2. `configure-aws-credentials` で上の role を assume する（`output-env-credentials: false`、`output-credentials: true`、`inline-session-policy` で secret の `GetSecretValue` だけに絞る）
     - **Claude の判断**: AWS の credentials を `$GITHUB_ENV` に出さず、使う step の `env` にだけ渡す。1 つの role は token も読めるので、claude の step の環境変数に残すと、renovate-major-review のモデルが Bash で credentials を使って token を取り出せうるため
  3. Secrets Manager から token を取り出す（`continue-on-error: true`）
     - **Claude の判断**: token は step の output で `claude-code-action` の `claude_code_oauth_token` 入力にだけ渡し、`$GITHUB_ENV` には書かない
       - 後続の step の環境変数に入ると、fallback の step で CLI が OAuth を優先したり、scrub の対象外の名前のままモデルに見えたりしうるため
     - 取り出した直後に `::add-mask::` で log から隠す
  4. `id: claude`: subscription で動かす（今の `claude_args` のまま。WIF の 4 入力を `claude_code_oauth_token` に置き換える）。`continue-on-error: true`
  5. `id: claude-bedrock`: 下の条件のときだけ、`use_bedrock: 'true'` でもう一度動かす
     - その直前に role を `inline-session-policy` で Bedrock の `InvokeModel` だけに絞って assume し直し、その credentials をこの step の `env` にだけ渡す（**Claude の判断**: fallback の step でも token を読めないようにするため）
     - `claude_args` は `--model` 以外を今と同じにする
     - `--model` は docs-sync-check が `global.anthropic.claude-haiku-4-5-20251001-v1:0`、renovate-major-review が `global.anthropic.claude-sonnet-4-6`
     - `ANTHROPIC_DEFAULT_HAIKU_MODEL` に、role が許すモデルを入れる（v1.0.0 と同じく、裏で Haiku を呼ぶ処理が許可外のモデルに行かないように）
     - AWS の region は us-east-1（Secrets Manager は ap-northeast-1 なので、取り出す step では region を明示する）
  6. `check.sh` に、成功した方の `structured_output` を渡す
  7. 費用の job summary と、実行ログの artifact は、動いた step の分をすべて残す
- **fallback が動いたことを人に見せる**（ユーザー）
  - PR のコメントの末尾に、workflow が 1 行足す（例: `> ⚠️ subscription で動かせなかったため、Bedrock の claude-haiku-4-5 で判定しました。`）
    - **Claude の判断**: モデルではなく workflow の step で `check.sh` の後に足す。prompt と出力の形を変えずに済み、モデルの出力に左右されないため
  - Actions の実行画面に warning を出し、job summary にも、fallback した理由（token の取り出しの失敗か、`claude` の step の失敗か）を書く
- **fallback の条件**: 次のどちらか
  - token の取り出しが失敗した（値が未投入・権限不足・throttle など。**Claude の判断**: subscription で動かせない場合に当たるため）
  - `claude` の step が失敗し、かつ実行ログの最後の `result` が「費用の上限」や「turn の上限」で止まったものでない
  - 上限で止まったときの `subtype` の値は、実装のときに Agent SDK の型で確かめる
  - 実行ログがない、または `result` がない失敗（認証の失敗、5 時間枠の上限、API の障害など）は、切り替える側に倒す
  - `claude` の step が成功し、`check.sh` が出力を弾いたときは切り替えない
  - **Claude の判断**: 判定は単体テスト付きの script（`scripts/review-output/` の隣）に切り出し、internal の workflow から呼ぶ。上限で止まったときの実行ログは、手元の `claude -p --max-budget-usd` で実物を取ってテストの入力にする
- **Claude の判断**: 呼び出し側の入力は変わらないので、`feat:` として v3.1.0 にする

### Rollout

1. platform で role と secret を作り、apply する
2. 共通 workflow を直し、monorepo の試走用の PR（release 前のブランチの commit を `uses:` に指定）で、本物の共通 workflow を動かして確かめる。本番は v3.0.0（WIF）のままなので、secret の値を試走に使っても本番に影響しない
   - fallback: secret が空のまま docs-sync-check を動かすと、Bedrock でやり直して status とコメントが出る
   - 通常の経路: ユーザーが token を入れたあと、docs-sync-check が subscription で動き、status とコメントが出る
   - 権限: 使い捨ての workflow で renovate-major-review と同じ設定のモデルに、`echo $AWS_ACCESS_KEY_ID` など AWS の credentials と token を読ませ、拒否されるか空であることを確かめる
   - fallback しない場合（費用の上限）は、上の script のテストで確かめる
   - 試走用の PR・ブランチ・worktree は、その場で消す
3. release（v3.1.0）し、monorepo と platform の `uses:` を差し替えて merge する
4. renovate-major-review を、main と conflict していない Renovate の major PR で試す（merge ref が新しい main を含んでいることを確かめてから、label を付け直す）

### Cleanup

切り替えが本番で動いたことを確かめてから行う。

1. 古い environment（monorepo の `docs-sync-check`、platform の `renovate-major-review`）を消す
2. Console の Workload Identity Federation の設定（rule `github-workloads`、service account `github-ci-caller`、issuer `github-actions`）を消す。ユーザーが Console で行い、手順は plan に書く
3. この作業で作った worktree・ブランチ・試走用の PR が残っていないことを確かめる

---

## Alternatives Considered

- **OAuth token を各リポジトリの secret に置く**: 一番手早いが、置き場所が増えて更新が手間になるので採らない（ユーザー）
- **SSM Parameter Store（SecureString）**: 無料で役割もほぼ同じだが、既存に合わせて Secrets Manager にする（ユーザー）
- **GCP Secret Manager**: GitHub Actions から GCP に入る pool を消したばかりで、作り直しになるので採らない
- **fallback に Console のクレジット（WIF）を使う**: WIF の設定を消したいので採らない（ユーザー）
- **費用の上限で止まったときも fallback する**: 作業量が上限に収まらないなら Bedrock でも同じ所で止まり、費用だけが増えるので採らない（ユーザー）

---

## Open Questions For The Builder

- Agent SDK の `result` の `subtype` で、費用の上限と turn の上限を表す値
- `claude-code-action` が、5 時間枠の上限や認証の失敗で step を失敗させるか（`continue-on-error` と `steps.claude.outcome` で拾えるか）
