# データモデル（DynamoDB）

単一テーブル設計。テーブル名は環境ごとに `contact-<env>`。

## テーブルとインデックス

| 名前 | パーティションキー | ソートキー | 用途 |
|---|---|---|---|
| テーブル本体 | `PK` | `SK` | 問い合わせ単位でメッセージ・メモ・イベントをまとめる |
| `GSI1` | `GSI1PK` | `GSI1SK` | 問い合わせの新しい順一覧 |
| `GSI2` | `GSI2PK` | `GSI2SK` | 同一メールアドレスの履歴 |

- 課金モード: オンデマンド。
- ポイントインタイムリカバリ: 有効。
- TTL 属性: `ttl`（重複排除用の項目にだけ設定）。

## 項目一覧

| 項目 | PK | SK | GSI1PK / GSI1SK | GSI2PK / GSI2SK | 主な属性 |
|---|---|---|---|---|---|
| 問い合わせ | `INQ#000123` | `META` | `INQ` / `<createdAt>#000123` | `CUST#<email>` / `<createdAt>` | `receiptNo`, `status`, `source`, `categoryId`, `customerName`, `customerEmail`, `customerPhone`, `subject`, `excerpt`, `assigneeId`, `needsReply`, `lastCustomerMessageAt`, `lastStaffReplyAt`, `closedAt`, `createdAt`, `updatedAt` |
| メッセージ | `INQ#000123` | `MSG#<createdAt>#<id>` | | | `direction`, `channel`, `fromEmail`, `toEmail`, `subject`, `bodyText`, `messageId`, `inReplyTo`, `sesMessageId`, `rawS3Key`, `attachmentCount`, `sentByUserId`, `createdAt` |
| 内部メモ | `INQ#000123` | `NOTE#<createdAt>#<id>` | | | `userId`, `body`, `createdAt` |
| イベント | `INQ#000123` | `EVT#<createdAt>#<id>` | | | `type`, `actorUserId`, `payload`, `createdAt` |
| 種別 | `CATEGORY` | `CAT#<id>` | | | `name`, `sortOrder`, `isActive` |
| ユーザー | `USER` | `USER#<cognitoSub>` | | | `name`, `email`, `role`, `isActive`, `createdAt` |
| メール設定 | `SETTINGS` | `MAIL` | | | `fromName`, `autoReplySubject`, `autoReplyBody`, `notifyTo`, `signature` |
| 採番カウンタ | `COUNTER` | `RECEIPT` | | | `value` |
| Message-ID 索引 | `MSGID#<messageId>` | `META` | | | `receiptNo` |
| 受信重複排除 | `SESMSG#<sesMessageId>` | `META` | | | `ttl`（30 日） |
| 送信重複排除 | `SUBMIT#<sha256(email + body)>` | `META` | | | `receiptNo`, `ttl`（5 分） |

列挙値:

| 属性 | 値 |
|---|---|
| `status` | `OPEN`（未対応）, `IN_PROGRESS`（対応中）, `REPLIED`（返信済み）, `CLOSED`（完了） |
| `source` | `WEB_FORM`, `EMAIL` |
| `direction` | `INBOUND`, `OUTBOUND` |
| `channel` | `WEB_FORM`, `EMAIL` |
| `type`（イベント） | `CREATED`, `STATUS_CHANGED`, `ASSIGNED`, `UNASSIGNED`, `REPLY_SENT`, `CUSTOMER_REPLIED`, `AUTO_REPLY_SENT` |
| `role` | `ADMIN`, `AGENT` |

`<id>` は ULID（時刻順にソートできる）。`<createdAt>` は ISO 8601 の UTC。

設計上のポイント:

- 問い合わせの ID は受付番号そのもの（`000123`）。URL も `/inquiries/INQ-000123`。
- フォーム送信の本文も最初のメッセージ（`INBOUND` / `WEB_FORM`）として保存する。タイムラインが 1 つの Query で組める。
- `needsReply` は「お客様の最新メッセージに未返信」を表す派生フラグ。受信時に `true`、返信送信時に `false` にする。一覧の絞り込みとダッシュボードの件数に使う。
- `excerpt` は最初のメッセージの冒頭 200 文字。一覧表示用。
- ユーザーの認証情報は Cognito が持つ。DynamoDB の項目は表示名とロールの写し。

## アクセスパターン

| 操作 | 方法 |
|---|---|
| 一覧（新しい順） | `GSI1` を `GSI1PK = INQ` で Query、降順。ステータス・種別・担当者・要返信は FilterExpression。ページングは `LastEvaluatedKey` |
| ダッシュボードの件数 | `GSI1` を `Select = COUNT` で Query（未対応、要返信、自分の担当の 3 回） |
| キーワード検索 | テーブルを Scan し、`META` 項目の氏名・メール・受付番号・件名・抜粋と、`MSG#` 項目の本文を `contains` で絞る。ヒットした受付番号で `META` をまとめて取得 |
| 詳細 | `PK = INQ#000123` を Query。`META`、`MSG#`、`NOTE#`、`EVT#` が 1 回で取れる |
| 同一顧客の履歴 | `GSI2` を `GSI2PK = CUST#<email>` で Query |
| 受付番号で取得 | `GetItem(INQ#000123, META)` |
| In-Reply-To での紐付け | `GetItem(MSGID#<messageId>, META)` |
| 種別一覧 | `PK = CATEGORY` を Query |
| ユーザー一覧 | `PK = USER` を Query |
| 設定 | `GetItem(SETTINGS, MAIL)` |

## 受付番号の採番

`COUNTER / RECEIPT` に対して `UpdateItem` の `ADD value :one` を `ReturnValues = UPDATED_NEW` で実行し、返った値を 6 桁ゼロ埋めする。アトミックなので重複しない。

## 冪等性・重複排除

| 場面 | 方法 |
|---|---|
| フォームの二重送信 | `SUBMIT#<hash>` を `attribute_not_exists(PK)` 条件で PutItem。失敗したら既存項目の `receiptNo` を返す |
| 受信メールの再配信 | `SESMSG#<sesMessageId>` を条件付き PutItem。処理の最後に書き、成功した場合だけ通知を送る |
| 受信処理の途中失敗と再実行 | メッセージとイベントの SK を SES の `messageId` から決定的に作り、再実行では同じ項目を上書きする |

## サイズ制限への対応

- DynamoDB の項目上限は 400 KB。受信メールの `bodyText` は 100 KB で切り詰め、HTML は保存しない。原本は S3（`rawS3Key`）にあるので失われない。
- フォーム本文は 5,000 文字までなので問題ない。
