# .github

panicboat アカウントのリポジトリで共有する GitHub の設定を置くリポジトリ。

## Community Health Files

ここにある issue テンプレートと PR テンプレートは、自前のテンプレートを持たないリポジトリで既定として使われる。
リポジトリが自前の `.github/ISSUE_TEMPLATE/` を持つと、ここの issue テンプレートはフォルダごと使われない。

## Shared Workflows

`.github/workflows/reusable--*.yaml` は、panicboat の他のリポジトリから呼び出す共通の workflow。
呼び出し側は `uses: panicboat/.github/.github/workflows/<file>@<sha> # vX.Y.Z` と書いて、release の commit SHA に固定する。
固定した SHA は Renovate が更新する。
`.github/workflows/internal--*.yaml` は、共通の workflow の中からだけ呼ぶ workflow で、他のリポジトリからは呼ばない。

```yaml
jobs:
  lint:
    permissions:
      contents: read
    uses: panicboat/.github/.github/workflows/reusable--lint-actions.yaml@<sha> # vX.Y.Z
```

- 呼び出す job は、呼ばれる workflow が必要とする権限を `permissions` で付ける。
  - 複数の stack をまとめる workflow は job の `permissions` を宣言しない。
  - 呼び出し側が、そのリポジトリで使う stack の分だけを付ける。
- 共通の workflow から別の共通の workflow を呼ぶときは、`uses: $/.github/workflows/<file>` と書く。
  - `$/` は呼び出し元の workflow と同じ commit に解決される。
  - 入れ子の workflow が、呼び出し側の固定とずれない。
- `scripts/` の script は、`job.workflow_repository` を `job.workflow_sha` で `.shared-workflows/` に checkout して実行する。
  - 呼び出し側が固定した workflow と同じ commit の script を使うため。
- このリポジトリは public のままにする。
  - 呼び出し側が、自分の `GITHUB_TOKEN` でこのリポジトリを checkout するため。

## Renovate Preset

`default.json` は、panicboat のリポジトリで共通の Renovate 設定を持つ。
各リポジトリは `extends` にこの preset を書き、そのリポジトリ固有の rule だけを自分の `renovate.json` に残す。

- 他のリポジトリは `"extends": ["github>panicboat/.github"]` と書く。
  - Renovate の docs が、別のリポジトリに置いた preset の参照として示す書式。
- このリポジトリは `"extends": ["local>panicboat/.github"]` と書く。
  - `local>` は、対象のリポジトリと同じ platform にある preset を参照する書式。
  - github.com では `github>` と同じに解決される。
- `panicboat/.github` への参照は、`minimumReleaseAge` を待たずに更新する。
  - 共通の workflow は panicboat 自身が release するので、公開から日を置いて様子を見る理由がない。
