# セキュリティ・運用・実装計画

## セキュリティ

| 対象 | 対策 |
|---|---|
| 公開 API | Turnstile 検証、WAF のレート制限、API Gateway のスロットリング、リクエストサイズ上限、入力検証。本文は常にテキストとして扱い、画面ではエスケープして表示 |
| CORS | API Gateway の CORS 設定で HP のオリジンのみ許可 |
| CloudFront の迂回 | CloudFront が API Gateway へのリクエストに共有シークレットのヘッダを付け、Lambda api で検証する。直接 API Gateway を叩かれても拒否できる |
| 管理 API | API Gateway の JWT オーソライザー。管理者限定の操作はハンドラでも `cognito:groups` を確認 |
| 認証基盤 | Cognito。パスワードポリシー（8 文字以上、英数記号）、セルフサインアップ無効。MFA は第 2 段階 |
| SPA の配信 | S3 は非公開、CloudFront の OAC からのみ読める。HTTPS のみ。セキュリティヘッダ（HSTS、X-Content-Type-Options、frame-ancestors）をレスポンスヘッダポリシーで付与 |
| 受信メール | SES のスパム・ウイルス判定が `FAIL` なら破棄。HTML 本文は保存も表示もしない |
| シークレット | Turnstile シークレット、共有シークレットは SSM SecureString。コードや環境変数に平文で置かない |
| ログ | 本文、メールアドレス、電話番号をログに出さない。CloudWatch Logs の保持期間を設定 |
| データ保護 | DynamoDB と S3 はデフォルト暗号化。ポイントインタイムリカバリ有効 |

## IAM 権限（最小権限）

| 主体 | 許可 |
|---|---|
| Lambda api | DynamoDB テーブルと GSI の読み書き、`ses:SendEmail`（送信元アドレスに限定）、`ssm:GetParameter`（対象パラメータのみ）、Cognito の `AdminCreateUser` / `AdminAddUserToGroup` / `AdminRemoveUserFromGroup` / `AdminDisableUser` / `AdminEnableUser` / `AdminResetUserPassword` / `AdminGetUser`（対象ユーザープールのみ） |
| Lambda inbound | 受信メールバケットの `s3:GetObject`、DynamoDB テーブルの読み書き、`ses:SendEmail` |
| SES（受信ルール） | 受信メールバケットへの `s3:PutObject`、Lambda inbound の `lambda:InvokeFunction` |
| CloudFront | SPA バケットへの `s3:GetObject`（OAC） |
| GitHub Actions（deploy ロール） | Environment dev / prod のジョブが OIDC で引き受け。PowerUserAccess + `contact-*` の IAM ロール・ポリシー操作と PassRole（`contact-github-*` は拒否） |
| GitHub Actions（plan ロール） | pull_request のジョブが OIDC で引き受け。ReadOnlyAccess + state の読み取り + SSM 経由の `kms:Decrypt` |

## 監視・ログ

| 項目 | 内容 |
|---|---|
| Lambda のエラー | CloudWatch アラーム（エラー数 > 0）→ SNS → 通知先アドレス |
| 受信処理の失敗 | Lambda inbound の失敗先を SQS デッドレターキューにし、キューの滞留をアラーム |
| SES の送信失敗 | バウンス・苦情イベントを SNS で通知先アドレスへ |
| API のエラー率 | API Gateway の 5xx をアラーム |
| ログ | 構造化ログ（JSON）。リクエスト ID と受付番号を必ず含める |

## コストの目安

月数十件、スタッフ数人の利用では、Lambda、API Gateway、DynamoDB、S3、CloudFront、SES、Cognito はいずれも無料枠内かごく少額に収まる。固定費として意識するのは次の 2 つ。

| 項目 | 備考 |
|---|---|
| AWS WAF | Web ACL とルールごとの月額が発生する。レート制限を API Gateway のスロットリングだけで代替すれば省ける ⚠️要確認 |
| Route 53 | ホストゾーンの月額 |

## 実装順序

| 順 | 内容 | 完了の目安 |
|---|---|---|
| 0 | bootstrap と CI/CD の雛形（済み）: state バケット、OIDC ロール、ワークフロー 4 本、Makefile | PR で plan、main で dev へのデプロイが走る |
| 1 | Terraform で基盤を作る: DynamoDB、Cognito、S3 + CloudFront、API Gateway + Lambda api の疎通 | `GET /api/admin/me` が認証付きで返る |
| 2 | Go: store 層、種別 API、公開の受付 API、Turnstile、採番、重複排除 | HP 相当のフォームから登録でき、受付番号が返る |
| 3 | SES 送信: 自動返信とスタッフ通知 | 受付時にメールが 2 通届く |
| 4 | SPA: ログイン（初回パスワード変更、再設定）、レイアウト、一覧、詳細の閲覧 | 登録した問い合わせを画面で見られる |
| 5 | 管理 API と画面: ステータス、担当者、内部メモ、返信送信 | 画面から返信メールを送れる |
| 6 | SES 受信: 受信ドメイン、受信ルール、Lambda inbound、紐付け、お客様返信の通知 | お客様の返信がタイムラインに載る |
| 7 | 設定画面: 種別、ユーザー（Cognito 連携）、メール設定 | 管理者が運用設定を変えられる |
| 8 | ダッシュボード、WAF、監視、デッドレターキュー、CI/CD | 本番運用できる |

## 未決事項（⚠️要確認）

| 項目 | 内容 | 影響 |
|---|---|---|
| DB の選択 | DynamoDB を前提にした。RDB を希望する場合は Aurora Serverless v2 + Data API に差し替える | データモデルと store 層 |
| ドメイン | 送信元、受信用、管理画面のドメイン名。Route 53 でホストするか | SES と CloudFront の設定 |
| SES 受信リージョン | 東京リージョンでの受信エンドポイントを実環境で確認 | 受信ドメインの MX |
| SES のスレッドヘッダ | Simple 形式で `In-Reply-To` / `References` が付くか。付かなければ Raw 形式 | 送信実装 |
| SES の Message-ID 形式 | 返却される `MessageId` と実際のヘッダ値の対応 | `MSGID#` 索引の照合 |
| WAF | レートルールの最小閾値と月額。スロットリングのみで代替するか | 公開 API の保護とコスト |
| 受信メール原本の保持期間 | S3 ライフサイクルの日数 | 個人情報の保持方針 |
| 認証を Cognito にしてよいか | 自前実装（bcrypt + JWT）も可能だが、Cognito の方が実装量が少ない | 認証基盤全体 |
| deploy ロールの権限 | PowerUserAccess + `contact-*` の IAM 操作で実質管理者に近い。Permissions Boundary の導入を検討 | CI の権限 |
| plan ロールの読み取り範囲 | 同一リポジトリの PR から state と SSM SecureString を読める。PR を出せる人を限定する | CI の権限 |
| prod 承認時に plan が見えない | 承認がジョブ開始時に求められる。plan ジョブと apply ジョブの分離を検討 | deploy.yml |
| SES の受信ルールセット | 有効なルールセットはアカウント・リージョンごとに 1 つ。dev / prod を同一アカウントに置く場合の持ち方 | mail モジュール |
| GitHub の required reviewers | 非公開リポジトリでは有料プランが必要 | prod の保護設定 |
