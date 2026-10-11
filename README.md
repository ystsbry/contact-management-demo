# お問い合わせ管理システム

別サイト（HP）のフォームから届く問い合わせを受け付け、スタッフが管理画面からメールで返信し、対応状況を管理するシステム。お客様とのやり取りはメールで完結し、お客様からの返信メールはシステムが受信して該当の問い合わせに自動で紐付ける。

| 成果物 | 内容 |
|---|---|
| 受付 API | HP のフォームから呼ばれる公開 API（Go / Lambda） |
| 管理画面 | スタッフ向け SPA（React / TypeScript / Vite） |
| メール基盤 | Amazon SES による送信・受信と、受信メールの紐付け処理 |

AWS（ap-northeast-1）上に Terraform で構築し、GitHub Actions から OIDC でデプロイする。リソース名のプレフィックスは `contact`。

## ドキュメント

要件定義と設計は `.docs/contact-management/` にある。

- `index.html` をブラウザで開くと、サイドバー付きで全ページを読める（例: `xdg-open .docs/contact-management/index.html`、macOS は `open`）。
- 同じ内容を Markdown でも置いている。

| ファイル | 内容 |
|---|---|
| `00_tldr.md` | 要約 |
| `01_scope-and-decisions.md` | 前提・スコープ・決定事項 |
| `02_functional-requirements.md` | 機能要件 |
| `03_architecture.md` | 技術スタック、AWS 構成、リポジトリ構成、IaC と CI/CD |
| `04_data-model.md` | データモデル（DynamoDB 単一テーブル） |
| `05_email-flow.md` | メール送受信（SES） |
| `06_api.md` | API |
| `07_screens-and-notifications.md` | 画面と通知 |
| `08_security-and-operations.md` | セキュリティ・運用・実装計画 |

## リポジトリ構成

「（予定）」は設計上の配置で、まだ存在しない。

```
.github/workflows/           CI/CD（下記）
.docs/contact-management/    要件定義・設計ドキュメント
Makefile                     Lambda のビルド（make lambda-build / make clean）
backend/                     （予定）Go。cmd/api と cmd/inbound が Lambda のエントリ
frontend/                    （予定）React + TypeScript + Vite の SPA
infra/
  bootstrap/                 state バケット、GitHub OIDC、CI 用 IAM ロール。管理者がローカルから一度だけ apply する
  envs/dev/                  （予定）dev 環境のルートモジュール（backend.tf、main.tf、terraform.tfvars）
  envs/prod/                 （予定）prod 環境のルートモジュール
  modules/{data,auth,api,mail,web}/  （予定）用途別モジュール
dist/                        make lambda-build の出力（api.zip、inbound.zip）。コミットしない
```

## CI/CD

| ワークフロー | きっかけ | 内容 | AWS ロール |
|---|---|---|---|
| `ci-backend.yml` | `backend/**` を変更する PR、main への push | `go vet`、`go test -race`、`make lambda-build` | なし |
| `ci-frontend.yml` | `frontend/**` を変更する PR、main への push | `npm ci`、lint / typecheck / test（スクリプトがあれば）、build | なし |
| `ci-infra.yml` | `infra/**`、`backend/**`、`Makefile` を変更する PR | `terraform fmt -check`、validate（bootstrap と各環境）、各環境の `terraform plan`。plan の結果を環境ごとに PR コメントへ投稿し、再実行時は同じコメントを更新する | plan ロール |
| `deploy.yml` | main への push（`backend/`、`frontend/`、`infra/envs/`、`infra/modules/` の変更）で dev。`workflow_dispatch` で dev / prod を選択 | Lambda ビルド → `terraform apply` → output 取得 → SPA ビルド → `aws s3 sync` → CloudFront 無効化 | deploy ロール |

- ディレクトリがまだ無い間は `paths` フィルタで走らない。`ci-infra` と `deploy` は `backend/go.mod` が無ければ Lambda ビルドを、`frontend/package-lock.json` が無ければ SPA の手順を飛ばす。`deploy` は `infra/envs/<env>/` が無ければジョブごと飛ばす。
- `ci-infra` の plan は `infra/envs/` 配下で `*.tf` を持つディレクトリを自動で対象にする。fork からの PR では OIDC を使えないため validate までで止まる。
- plan ロールは state に書き込めないので、PR の plan は `-lock=false` で実行する（読み取りのみ）。
- `deploy` は同じ環境への実行を直列にする（`concurrency`）。prod は main ブランチからのみ実行でき、GitHub Environment の required reviewers の承認を待つ。
- Terraform は 1.13 系、Go は `backend/go.mod` の版、Node.js は 24 を使う。

### frontend の npm スクリプト

CI は次のスクリプトを呼ぶ。`lint`、`typecheck`、`test` は無ければ飛ばす。

| スクリプト | 例 |
|---|---|
| `lint` | `eslint .` |
| `typecheck` | `tsc -b` |
| `test` | `vitest run` |
| `build` | `tsc -b && vite build`（出力は `frontend/dist/`、ハッシュ付きファイルは `dist/assets/`） |

### S3 への配置とキャッシュ

| 対象 | Cache-Control | 備考 |
|---|---|---|
| `assets/*`（ハッシュ付き） | `public, max-age=31536000, immutable` | 古いファイルは削除しない（配置前に開いた画面が参照するため） |
| `index.html`、その他 | `no-cache` | `index.html` は assets の後に置き換える |

最後に CloudFront の `/*` を無効化する。

## Lambda のビルド

```sh
make lambda-build   # dist/api.zip、dist/inbound.zip を作る
make clean          # dist/ を削除
```

- `backend/cmd/api` と `backend/cmd/inbound` を `CGO_ENABLED=0 GOOS=linux GOARCH=arm64`、`-trimpath -buildvcs=false -ldflags="-s -w" -tags lambda.norpc` でビルドし、`bootstrap` という名前で zip に入れる（ランタイム `provided.al2023`、arm64）。
- zip 内のファイルの mtime と権限を固定しているので、同じソースと同じ Go のバージョンなら zip のハッシュは毎回同じになる。PR の plan に Lambda の差分が出るのはコードが変わったときだけ。
- `zip` コマンドが必要（Ubuntu: `sudo apt install zip`）。

## 初回セットアップ

前提: AWS の管理者権限を持つ認証情報、Terraform 1.11 以上（CI と揃えるなら 1.13 系）、AWS CLI。

### 1. bootstrap を apply する（管理者がローカルで一度だけ）

```sh
cd infra/bootstrap
terraform init
terraform apply
# アカウントに GitHub の OIDC プロバイダが既にある場合:
# terraform apply -var create_oidc_provider=false
terraform output
```

作られるもの:

| リソース | 内容 |
|---|---|
| `contact-tfstate-<アカウント ID>` | Terraform state 用 S3 バケット。バージョニング、SSE-S3、パブリックアクセスブロック、TLS 必須、`prevent_destroy` |
| GitHub OIDC プロバイダ | `token.actions.githubusercontent.com`（`create_oidc_provider = false` なら既存を参照） |
| `contact-github-deploy` | deploy ロール。GitHub Environment `dev` / `prod` のジョブのみ引き受け可。PowerUserAccess ＋ `contact-*` の IAM ロール・ポリシー操作と PassRole |
| `contact-github-plan` | plan ロール。`pull_request` のジョブのみ引き受け可。ReadOnlyAccess ＋ state の読み取り ＋ SSM 経由の `kms:Decrypt` |

- envs / modules で作る IAM ロール・ポリシーは名前を `contact-` で始めること（deploy ロールはそれ以外を作れない）。ただし `contact-github-` は bootstrap 用に予約しており、deploy ロールからは操作できない。
- bootstrap の state は最初はローカル（`infra/bootstrap/terraform.tfstate`、コミットしない）。失くさないよう、次の手順でバケットへ移すことを勧める。

```sh
# versions.tf の backend "s3" ブロックのコメントを外し、bucket を state_bucket_name に置き換えてから
terraform init -migrate-state
```

### 2. 各環境の backend.tf を書く

`terraform output backend_config_examples` の内容を `infra/envs/<env>/backend.tf` に置く。state のキーは `envs/<env>/terraform.tfstate`（plan ロールが読めるのは `envs/` 配下のみ）。

### 3. GitHub を設定する

Settings → Secrets and variables → Actions、および Settings → Environments で設定する。

| 種別 | 名前 | 値 |
|---|---|---|
| Repository variable | `AWS_PLAN_ROLE_ARN` | bootstrap の `plan_role_arn` |
| Environment `dev` の variable | `AWS_DEPLOY_ROLE_ARN` | bootstrap の `deploy_role_arn` |
| Environment `prod` の variable | `AWS_DEPLOY_ROLE_ARN` | bootstrap の `deploy_role_arn` |

Environment の保護設定:

| Environment | 設定 |
|---|---|
| `dev` | Deployment branches は main（`workflow_dispatch` で他ブランチから試したい場合は制限しない） |
| `prod` | Required reviewers を設定、Prevent self-review を有効、Deployment branches を main のみ |

GitHub の Secret は不要（AWS は OIDC、アプリのシークレットは SSM に置くため）。

### 4. 初回デプロイ（dev）

`infra/envs/dev/` を main に入れると `deploy.yml` が dev へデプロイする。手動なら Actions → deploy → Run workflow で `dev` を選ぶ。

### 5. SSM パラメータの値を入れる

Terraform はパラメータを作るが、値はダミーで作成して `ignore_changes` で管理外にする。初回 apply の後に人が値を上書きする。

```sh
aws ssm put-parameter --overwrite --type SecureString \
  --name /contact/dev/turnstile/secret-key --value '<Turnstile のシークレットキー>'
```

| パラメータ名 | 内容 | 投入 |
|---|---|---|
| `/contact/<env>/turnstile/secret-key` | Cloudflare Turnstile のシークレットキー（環境ごと。dev はテスト用キーでもよい） | 人が手で入れる |
| `/contact/<env>/origin-verify/secret` | CloudFront → API Gateway の共有シークレット | Terraform が `random_password` で生成するので不要 |

### 6. SES / Route 53 の前提

envs / modules を実装・apply する前に決めておく。

- ドメイン名（送信元、受信用、管理画面）と、Route 53 でホストするか（未決事項）。Route 53 でホストする場合はホストゾーンを用意し、レジストラの NS を向ける。
- CloudFront のカスタムドメイン用の ACM 証明書は us-east-1 に必要（web モジュールのプロバイダエイリアス）。
- SES は初期状態がサンドボックス。dev では送信先アドレスを検証しておく。prod の前に本番アクセス（送信制限の解除）を申請する。
- SES 受信の ap-northeast-1 での利用可否と受信エンドポイント（`inbound-smtp.ap-northeast-1.amazonaws.com`）を確認する。
- SES の有効な受信ルールセットはアカウント・リージョンごとに 1 つ。dev と prod を同じアカウントに置く場合は、ルールセットの持ち方を mail モジュールで決める。

## Terraform output の契約

`deploy.yml` は `terraform output -json` から次の値を読む。各環境のルートモジュール（`infra/envs/<env>/`）はこれらを output として公開すること。無い場合はデプロイが失敗する。

| output | 用途 |
|---|---|
| `spa_bucket_name` | SPA を配置する S3 バケット名 |
| `cloudfront_distribution_id` | キャッシュ無効化の対象ディストリビューション ID |
| `cognito_user_pool_id` | SPA のビルド時に `VITE_COGNITO_USER_POOL_ID` として渡す |
| `cognito_client_id` | SPA のビルド時に `VITE_COGNITO_CLIENT_ID` として渡す |

Lambda の zip はリポジトリ直下の `dist/` に出力される。ルートモジュールからは例えば `"${path.root}/../../../dist/api.zip"` を `filename` に、その `filebase64sha256()` を `source_code_hash` に渡す。
