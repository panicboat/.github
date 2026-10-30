# .github

panicboat アカウントのリポジトリで共有する GitHub の設定を置くリポジトリ。

## Community Health Files

ここにある issue テンプレートと PR テンプレートは、自前のテンプレートを持たないリポジトリで既定として使われる。リポジトリが自前の `.github/ISSUE_TEMPLATE/` を持つと、ここの issue テンプレートはフォルダごと使われない。

## Shared Workflows

`.github/workflows/` の workflow は、ファイル名の接頭辞で呼び出し元を区別している。`reusable--` は panicboat の他のリポジトリから呼び出す共通の workflow で、`internal--` は共通の workflow の中からだけ呼ぶ。`self--` はこのリポジトリ自身のイベントで動く。`internal--` と `self--` を他のリポジトリから呼ぶことはない。

呼び出し側は release の commit SHA に固定して `uses:` を書き、固定した SHA は Renovate が更新する。呼び出す job には、呼ばれる workflow が必要とする権限を `permissions` で付ける。複数の stack をまとめる workflow は job の `permissions` を宣言しないので、呼び出し側が、そのリポジトリで使う stack の分だけを付ける。

```yaml
jobs:
  lint:
    permissions:
      contents: read
    uses: panicboat/.github/.github/workflows/reusable--lint-actions.yaml@<sha> # vX.Y.Z
```

共通の workflow から別の共通の workflow を呼ぶときは、`uses: $/.github/workflows/<file>` と書く。`$/` は呼び出し元の workflow と同じ commit に解決されるので、入れ子の workflow が呼び出し側の固定とずれない。

`scripts/` の script も同じ commit のものを使う必要がある。そのため workflow は `job.workflow_repository` を `job.workflow_sha` で `.shared-workflows/` に checkout して、そこから script を実行する。

呼び出し側は自分の `GITHUB_TOKEN` でこのリポジトリを checkout するので、このリポジトリは public のままにする。

## Renovate Preset

`default.json` は、panicboat のリポジトリで共通の Renovate 設定を持つ。各リポジトリは `extends` にこの preset を書き、そのリポジトリ固有の rule だけを自分の `renovate.json` に残す。

他のリポジトリは `"extends": ["github>panicboat/.github"]` と書く。これは、別のリポジトリに置いた preset を参照する書式として Renovate の docs が示しているものだ。このリポジトリは `"extends": ["local>panicboat/.github"]` と書く。`local>` は対象のリポジトリと同じ platform にある preset を参照する書式で、github.com では `github>` と同じに解決される。

`panicboat/.github` への参照は `minimumReleaseAge` を待たずに更新する。共通の workflow は panicboat 自身が release するので、公開から日を置いて様子を見る理由がないためだ。
