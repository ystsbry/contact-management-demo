# アーキテクチャ

## 技術スタック

| 領域 | 採用 | 補足 |
|---|---|---|
| フロントエンド | React + TypeScript + Vite。React Router、TanStack Query | S3 + CloudFront で配信する SPA |
| バックエンド | Go（`provided.al2023`、arm64）。chi ルーター | API 用 Lambda 1 つと、メール受信用 Lambda 1 つ |
| API 公開 | API Gateway（HTTP API） | JWT オーソライザー、CORS、スロットリングを担う |
| DB | DynamoDB（単一テーブル） | VPC 不要。アイドルコストなし。⚠️要確認（RDB 希望なら差し替え） |
| 認証 | Cognito User Pool | グループ `admin` / `agent` でロールを表す |
| メール | Amazon SES | 送信と受信。受信は S3 保存 + Lambda 起動 |
| Bot 対策 | Cloudflare Turnstile | 無料。reCAPTCHA への差し替えも容易 |
| 配信・保護 | CloudFront + AWS WAF | SPA と API を同一ドメインで配信。WAF でレート制限 |
| シークレット | SSM Parameter Store（SecureString） | Turnstile シークレットなど |
| IaC | Terraform（HCL） | 環境ごとのルートモジュール + 用途別モジュール。状態は S3 バックエンド |
| CI/CD | GitHub Actions | OIDC で AWS に認証 |

Go の Lambda 実装は `aws-lambda-go` と `aws-lambda-go-api-proxy`（chi アダプタ）を使い、同じルーターをローカルでは `net/http` でそのまま起動する。

## AWS 構成

```
お客様（HP） ──POST /api/public/*──▶ CloudFront ──▶ API Gateway ──▶ Lambda api（Go） ──▶ DynamoDB
スタッフ    ──GET  /*──────────────▶ CloudFront ──▶ S3（SPA）
スタッフ    ──/api/admin/*─────────▶ CloudFront ──▶ API Gateway（JWT 検証: Cognito）──▶ Lambda api
Lambda api ──▶ SES（送信）──▶ お客様 / スタッフ
お客様の返信 ──MX──▶ SES 受信ルール ──▶ S3（原本）＋ Lambda inbound（Go）──▶ DynamoDB、SES（通知）
```

| コンポーネント | 役割 |
|---|---|
| CloudFront | 単一ドメインで SPA と API を配信。`/api/*` を API Gateway へ、それ以外を S3 へ振り分ける。WAF を付ける |
| S3（SPA） | ビルド済み SPA。OAC で CloudFront からのみ読める |
| API Gateway（HTTP API） | ルーティング、CORS、スロットリング、`/api/admin/*` の JWT オーソライザー |
| Lambda api（Go） | 公開 API と管理 API の全ルートを 1 つの関数で処理 |
| Lambda inbound（Go） | SES が受信したメールを解析し、問い合わせに紐付ける |
| DynamoDB | すべての業務データ |
| Cognito | スタッフの認証。ユーザー管理 API の呼び出し先 |
| SES | 送信（自動返信、スタッフ返信、通知）と受信（返信メール） |
| S3（受信メール） | 受信メールの原本（MIME）。ライフサイクルで一定期間後に削除 ⚠️要確認（期間） |
| SSM Parameter Store | Turnstile シークレットなどの設定値 |
| WAF | 公開 API へのレート制限 |

## リクエストの流れ

受付（HP から）:

1. HP が Turnstile のトークン付きで `POST /api/public/inquiries` を呼ぶ。
2. CloudFront → WAF（レート制限）→ API Gateway → Lambda api。
3. Lambda api が Turnstile を検証し、バリデーションと重複判定をして DynamoDB に保存する。
4. SES で自動返信をお客様へ、通知をスタッフへ送る。
5. 受付番号を返す。

管理画面:

1. スタッフが SPA でログインする。SPA は Cognito とやり取りしてトークンを得る。
2. SPA は `Authorization: Bearer <アクセストークン>` を付けて `/api/admin/*` を呼ぶ。
3. API Gateway の JWT オーソライザーがトークンを検証する。Lambda api はクレームの `cognito:groups` でロールを判定する。

メール受信:

1. お客様が返信すると、受信ドメインの MX により SES が受け取る。
2. SES の受信ルールが原本を S3 に保存し、Lambda inbound を非同期で起動する。
3. Lambda inbound が原本を解析し、紐付けと保存、通知を行う。

## リポジトリ構成

```
backend/
  cmd/api/main.go            API 用 Lambda のエントリ（ローカルでは HTTP サーバとして起動）
  cmd/inbound/main.go        メール受信 Lambda のエントリ
  internal/handler/public    公開 API ハンドラ
  internal/handler/admin     管理 API ハンドラ
  internal/auth              JWT クレームからユーザー・ロールを取り出す
  internal/store             DynamoDB アクセス（単一テーブル）
  internal/inquiry           受付番号、ステータス遷移、紐付けなどのドメインロジック
  internal/mail              SES 送信、テンプレート、MIME 解析、通知
  internal/turnstile         Turnstile 検証
frontend/
  src/pages/                 Login, Dashboard, InquiryList, InquiryDetail, settings/*, Account
  src/api/                   fetch ラッパーと TanStack Query のフック
  src/auth/                  Cognito（aws-amplify の Auth）
infra/
  bootstrap/                 state バケット、GitHub OIDC プロバイダ、CI 用 IAM ロール。管理者がローカルから一度だけ apply
  envs/dev/                  dev 環境のルートモジュール（backend.tf、main.tf、terraform.tfvars）
  envs/prod/                 prod 環境のルートモジュール
  modules/data/              DynamoDB、受信メール S3
  modules/auth/              Cognito
  modules/api/               Lambda api、API Gateway
  modules/mail/              SES ドメイン、受信ルール、Lambda inbound
  modules/web/               S3、CloudFront、WAF（us-east-1 のプロバイダエイリアス）
.github/workflows/           CI/CD（ci-backend、ci-frontend、ci-infra、deploy）
Makefile                     Lambda のビルド（make lambda-build → dist/{api,inbound}.zip）
.docs/                       このドキュメント
```

## IaC と CI/CD

### Terraform

- Terraform（HCL）で定義する。用途別のモジュール（data / auth / api / mail / web）を、環境ごとのルートモジュール（`envs/dev`、`envs/prod`）から呼び出す。
- 状態ファイルは S3 バックエンド（`use_lockfile = true`、Terraform 1.11 以降）に置く。キーは `envs/<env>/terraform.tfstate`。
- `infra/bootstrap/` は state バケット、GitHub OIDC プロバイダ、CI 用 IAM ロールを作る。管理者がローカルから一度だけ apply する（state は最初ローカル。apply 後にバケットへ移行できる）。
- Go の Lambda は Terraform ではビルドしない。`make lambda-build` が `dist/api.zip` と `dist/inbound.zip` を作り（arm64、`provided.al2023`、mtime 固定で再現可能）、`aws_lambda_function` の `filename` と `source_code_hash` で参照する。
- SPA は Terraform の管理外。CI で `vite build` → `aws s3 sync` → CloudFront のキャッシュ無効化を行う。
- CloudFront 用の WAF と ACM 証明書は us-east-1 に作る必要があるため、web モジュールにプロバイダエイリアスを渡す。
- 環境は `dev` と `prod` の 2 つ（同じ AWS アカウントを前提）。ルートモジュールのディレクトリと `terraform.tfvars` で切り替える。

### GitHub Actions のワークフロー

| ワークフロー | きっかけ | 内容 | AWS ロール |
|---|---|---|---|
| `ci-backend.yml` | `backend/**` の PR / main push | `go vet`、`go test -race`、`make lambda-build` | なし |
| `ci-frontend.yml` | `frontend/**` の PR / main push | `npm ci`、lint / typecheck / test（あれば）、build | なし |
| `ci-infra.yml` | `infra/**`、`backend/**`、`Makefile` の PR | `terraform fmt -check`、validate、`infra/envs/*` ごとの `terraform plan`。結果を環境ごとに PR コメントへ投稿（再実行時は更新） | plan |
| `deploy.yml` | main push で dev。`workflow_dispatch` で dev / prod | Lambda ビルド → `terraform apply` → output 取得 → SPA ビルド → `aws s3 sync` → CloudFront 無効化 | deploy |

- ディレクトリがまだ無い間は `paths` フィルタで走らない。`backend/go.mod`、`frontend/package-lock.json`、`infra/envs/<env>/` が無い場合は該当手順を飛ばす。
- `deploy` は同じ環境への実行を `concurrency` で直列にする。prod は main からのみ実行でき、GitHub Environment の required reviewers の承認を待つ。
- S3 への配置は、ハッシュ付きの `assets/` を長期キャッシュで先に置き（古いものは削除しない）、`index.html` を `no-cache` で最後に置き換える。

### AWS への認証（OIDC）

アクセスキーは使わず、GitHub の OIDC トークンで IAM ロールを引き受ける。bootstrap が 2 つのロールを作る。

| ロール | 引き受けられるジョブ | 権限 |
|---|---|---|
| `contact-github-deploy` | Environment `dev` / `prod` を持つジョブ（`sub = repo:<repo>:environment:<env>`） | PowerUserAccess + `contact-*` の IAM ロール・ポリシー操作と PassRole。`contact-github-*` への IAM 操作は明示的に拒否 |
| `contact-github-plan` | `pull_request` イベントのジョブ（`sub = repo:<repo>:pull_request`） | ReadOnlyAccess + state の読み取り + SSM 経由の `kms:Decrypt`。plan は `-lock=false` |

### GitHub 側の設定値

| 種別 | 名前 | 値 |
|---|---|---|
| Repository variable | `AWS_PLAN_ROLE_ARN` | bootstrap の output `plan_role_arn` |
| Environment variable（dev / prod） | `AWS_DEPLOY_ROLE_ARN` | bootstrap の output `deploy_role_arn` |
| Secret | なし | AWS は OIDC、アプリのシークレットは SSM に置くため不要 |

Environment `prod` には required reviewers と main のみのデプロイ制限を設定する。

### deploy.yml が期待する Terraform output

各環境のルートモジュールは次を output する。

| output | 用途 |
|---|---|
| `spa_bucket_name` | SPA の配置先 |
| `cloudfront_distribution_id` | キャッシュ無効化 |
| `cognito_user_pool_id` | SPA ビルド時の `VITE_COGNITO_USER_POOL_ID` |
| `cognito_client_id` | SPA ビルド時の `VITE_COGNITO_CLIENT_ID` |

初回セットアップの手順（bootstrap の apply、GitHub の設定、SSM パラメータの投入、SES / Route 53 の前提）は README に記載。

## ローカル開発

| 対象 | 方法 |
|---|---|
| バックエンド | `go run ./cmd/api` で `:8080` に HTTP サーバとして起動。Lambda アダプタは本番のみ |
| DynamoDB | DynamoDB Local（Docker）。テーブル作成スクリプトを用意する |
| フロントエンド | `vite dev`。`/api` を `:8080` にプロキシ |
| Cognito | ローカルエミュレータがないため、`dev` 環境のユーザープールを使う |
| SES 送信 | `dev` 環境の SES（サンドボックス）。検証済みアドレスにのみ送る |
| SES 受信 | ローカルでは再現できない。`dev` 環境にデプロイして確認する。Lambda inbound の単体テストは保存済みの MIME ファイルで行う |
| Turnstile | テスト用サイトキー（常に成功）を使う |

## 設定値・シークレット

Lambda api:

| 名前 | 用途 | 保管 |
|---|---|---|
| `TABLE_NAME` | DynamoDB テーブル名 | 環境変数 |
| `APP_URL` | 管理画面の URL。通知メールのリンクに使う | 環境変数 |
| `PUBLIC_SITE_ORIGIN` | HP のオリジン。CORS に使う | 環境変数 |
| `MAIL_FROM_ADDRESS` | 送信元アドレス | 環境変数 |
| `MAIL_REPLY_DOMAIN` | 返信先の受信ドメイン | 環境変数 |
| `COGNITO_USER_POOL_ID` | ユーザー管理 API の呼び出し先 | 環境変数 |
| `TURNSTILE_SECRET_PARAM` | Turnstile シークレットの SSM パラメータ名（`/contact/<env>/turnstile/secret-key`） | SSM SecureString。Terraform はダミー値で作成し `ignore_changes`、人が `put-parameter --overwrite` で投入 |
| `ORIGIN_VERIFY_PARAM` | CloudFront 経由であることを確認する共有シークレットの SSM パラメータ名（`/contact/<env>/origin-verify/secret`） | SSM SecureString。Terraform の `random_password` で生成 |

Lambda inbound:

| 名前 | 用途 |
|---|---|
| `TABLE_NAME` | DynamoDB テーブル名 |
| `INBOUND_BUCKET` | 受信メール原本のバケット |
| `APP_URL`、`MAIL_FROM_ADDRESS`、`MAIL_REPLY_DOMAIN` | 通知と紐付けに使う |

フロントエンド（ビルド時）:

| 名前 | 用途 |
|---|---|
| `VITE_COGNITO_USER_POOL_ID` | Cognito ユーザープール |
| `VITE_COGNITO_CLIENT_ID` | Cognito アプリクライアント |

API のベース URL は同一オリジンの `/api` 固定。

## DynamoDB を選んだ理由と代替

選んだ理由:

- Lambda から VPC なしで接続でき、NAT ゲートウェイや RDS Proxy が不要。
- 月数十件の規模ではほぼ無料枠に収まり、アイドルコストがない。
- 必要なアクセスパターンが限られており、単一テーブルで無理なく表せる。

割り切った点:

- 本文のキーワード検索はスキャンで行う。数千件までは問題ないが、増えた場合は OpenSearch などを検討する。
- 集計やレポートが必要になった場合は、DynamoDB Streams から集計テーブルや S3 へ流す。

RDB を希望する場合の代替 ⚠️要確認:

- Aurora Serverless v2（PostgreSQL）+ RDS Data API。Lambda から HTTPS で接続でき VPC 不要。ゼロスケール設定にすると未使用時のコンピュート課金はないが、再開時に十数秒かかる。
- データモデルは「データモデル」ページの項目をそのままテーブルに置き換えられる。
