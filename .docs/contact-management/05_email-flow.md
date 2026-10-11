# メール送受信（SES）

## ドメインとアドレス

| 用途 | 例 | 設定 |
|---|---|---|
| 送信元（From） | `support@example.com` | SES で `example.com` を検証。Easy DKIM、SPF、DMARC を設定 |
| 返信先（Reply-To） | `inquiry+INQ-000123@reply.example.com` | `reply.example.com` の MX を SES の受信エンドポイントに向ける |
| 管理画面 | `https://admin.example.com` | CloudFront。通知メール内のリンク先 |

⚠️要確認: 実際のドメイン名と、Route 53 でホストするか。

⚠️要確認: SES の受信は東京リージョンで利用できると 2023 年 9 月に発表されている。受信エンドポイント（`inbound-smtp.ap-northeast-1.amazonaws.com`）は実環境で確認する。

SES は初期状態がサンドボックスのため、本番前に送信制限の解除申請が必要。

## 送信

SES v2 の `SendEmail`（Simple 形式）を使う。

| 項目 | 値 |
|---|---|
| From | `{fromName} <support@example.com>` |
| To | お客様のメールアドレス |
| ReplyToAddresses | `inquiry+INQ-000123@reply.example.com` |
| Subject | `[INQ-000123] {件名}` |
| Headers | `In-Reply-To` と `References` に、直近に受信したお客様メッセージの Message-ID（あれば） |

- SES が返す `MessageId` を `sesMessageId` に保存する。実際の `Message-ID` ヘッダは `<MessageId@email.amazonses.com>` の形になる ⚠️要確認（リージョンにより末尾が異なる可能性があるため実送信で確認）。
- 保存した Message-ID は `MSGID#` 索引にも登録し、お客様の返信の `In-Reply-To` と照合できるようにする。
- ⚠️要確認: SES v2 の Simple 形式ではカスタムヘッダを指定できるが、`In-Reply-To` / `References` が実際に付くかは実送信で確認する。付かない場合は Raw 形式で送る。
- スタッフ返信は本文の末尾に設定の署名を付ける。
- 送信後、メッセージ（`OUTBOUND` / `EMAIL`）とイベント `REPLY_SENT` を保存し、ステータスを 返信済み、`needsReply` を `false` にする。

## 自動返信

- フォーム受付時に送る。本文は設定値をテンプレートとし、`{{name}}`、`{{receiptNumber}}`、`{{body}}` を置換する。
- Reply-To は受信用アドレスにする。お客様が自動返信に返信しても紐付く。
- メール起点の新規問い合わせには自動返信を送らない（自動応答同士のループを避ける）。

## 受信の仕組み

1. `reply.example.com` 宛のメールが SES に届く。
2. 受信ルール（ルールセット）が順に実行される。
   1. S3 アクション: 原本（MIME）を受信メールバケットの `raw/<messageId>` に保存。
   2. Lambda アクション: Lambda inbound を非同期で起動。イベントにはヘッダの要約と、スパム・ウイルス・SPF・DKIM の判定結果が含まれる。
3. Lambda inbound が原本を S3 から取得して解析する。

Lambda の非同期起動は失敗時に 2 回再試行される。最終的に失敗したイベントは SQS のデッドレターキューに送り、CloudWatch アラームで気付けるようにする。

## 受信 Lambda の処理手順

1. `receipt.virusVerdict` または `receipt.spamVerdict` が `FAIL` なら記録だけして終了。
2. S3 から原本を取得し、MIME を解析する（`jhillyerd/enmime`）。テキスト本文、HTML 本文、ヘッダ、添付件数を得る。
3. 自動応答なら終了。判定は `Auto-Submitted` が `no` 以外、`X-Auto-Response-Suppress` あり、`Precedence` が `bulk` / `auto_reply` / `junk`、または From が自分の送信元アドレス。
4. 紐付け先を決める（次節）。
5. 紐付け先が無ければ、メール起点の新規問い合わせを作る。`source = EMAIL`、種別なし、件名はメールの件名、氏名は From の表示名（無ければローカル部）。受付番号を採番する。
6. メッセージ（`INBOUND` / `EMAIL`、`rawS3Key` 付き）を保存する。SK は `MSG#<受信日時>#<sesMessageId>` で決定的に作る。
7. 問い合わせの `lastCustomerMessageAt` と `needsReply = true` を更新し、ステータスが 返信済み / 完了 なら、担当者ありで 対応中、なしで 未対応 に戻す。イベント `CUSTOMER_REPLIED`（新規なら `CREATED`）を記録する。
8. 受信メールの Message-ID を `MSGID#` 索引に登録する。
9. `SESMSG#<sesMessageId>` を条件付きで書く。成功したら通知メール（担当者、未割当なら通知先）を送る。既に存在していたら通知しない。
10. 途中で失敗したらエラーを返し、Lambda の再試行に任せる。書き込みキーが決定的なので再実行しても二重にならない。

## 紐付けルール

次の順で探し、最初に見つかったものを採用する。

| 順 | 手がかり | 方法 |
|---|---|---|
| 1 | 宛先アドレス | To / Cc に `inquiry+INQ-xxxxxx@reply.example.com` があれば、その受付番号 |
| 2 | 件名 | `INQ-\d{6}` にマッチすれば、その受付番号 |
| 3 | スレッドヘッダ | `In-Reply-To` / `References` の各 Message-ID を `MSGID#` 索引で引く |
| 4 | なし | メール起点の新規問い合わせ |

受付番号が見つかっても該当の問い合わせが存在しない場合は、新規扱いにする。

## 自動応答・ループ・重複

| 問題 | 対策 |
|---|---|
| 不在通知などの自動応答を取り込む | ヘッダで判定して破棄 |
| 自動返信と相手の自動応答がループする | メール起点の新規問い合わせには自動返信を送らない。From が自分のアドレスなら破棄 |
| SES / Lambda の再試行で二重登録 | 決定的なキーと `SESMSG#` の条件付き書き込み |
| スパム | SES の判定が `FAIL` なら破棄。受信アドレスは Reply-To としてのみ使い、公開しない |

## 添付ファイル

- MVP では添付の内容を保存・表示しない。`attachmentCount` を記録し、画面に「添付 n 件（原本を保管）」と出す。
- 原本は S3 にあるので、第 2 段階で添付の取り出しを実装すれば過去分も参照できる。
- 原本の保持期間は S3 ライフサイクルで設定する ⚠️要確認（期間）。

## バウンス・苦情

- SES の設定セットでバウンスと苦情のイベントを SNS に送り、通知先アドレスへメール購読する。MVP では自動処理しない。
