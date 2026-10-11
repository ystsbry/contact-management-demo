# API 仕様

## 共通

- ベースパス: `/api`。CloudFront が API Gateway へ転送する。
- 形式: JSON。日時は ISO 8601（UTC）。
- 公開 API（`/api/public/*`）は認証なし。CORS は HP のオリジンのみ許可。
- 管理 API（`/api/admin/*`）は Cognito のアクセストークンが必要。管理画面と同一オリジンのため CORS 不要。
- Go 側は chi で 1 つのルーターにまとめ、API Gateway のプロキシ統合で受ける。

## 認証（Cognito）

| 項目 | 設計 |
|---|---|
| ユーザープール | メールアドレスをユーザー名にする。セルフサインアップ無効。管理者が作成 |
| グループ | `admin`、`agent`。トークンの `cognito:groups` に入る |
| アプリクライアント | シークレットなし（SPA）。SRP 認証とリフレッシュを有効。アクセストークン 1 時間、リフレッシュトークン 30 日 |
| SPA 側 | `aws-amplify` の Auth で `signIn`、初回の `NEW_PASSWORD_REQUIRED` チャレンジ、`resetPassword`、`updatePassword` を扱う |
| API Gateway | `/api/admin/*` に JWT オーソライザー。発行者はユーザープール、対象はアプリクライアント ID |
| Go 側 | `requestContext.authorizer.jwt.claims` から `sub` と `cognito:groups` を読み、管理者限定の操作はハンドラでロールを確認する |
| 無効化 | Cognito で `AdminDisableUser`。発行済みアクセストークンは最長 1 時間有効なので、Lambda api でも `USER#` 項目の `isActive` を確認する |

ユーザー管理の操作は Lambda api から Cognito の管理 API を呼ぶ。

| 操作 | Cognito API | DynamoDB |
|---|---|---|
| 追加 | `AdminCreateUser`（招待メール送信）+ `AdminAddUserToGroup` | `USER#` 項目を作成 |
| ロール変更 | グループの付け替え | `role` を更新 |
| 無効化 / 再有効化 | `AdminDisableUser` / `AdminEnableUser` | `isActive` を更新 |
| パスワードリセット | `AdminResetUserPassword`（確認コードをメール） | なし |
| 自分のパスワード変更 | SPA から直接 `ChangePassword` | なし |

## 公開 API

### `GET /api/public/categories`

```json
200 [{ "id": "01J...", "name": "製品について" }]
```

有効な種別を表示順で返す。

### `POST /api/public/inquiries`

リクエスト:

```json
{
  "name": "山田 太郎",
  "email": "taro@example.com",
  "phone": "090-0000-0000",
  "categoryId": "01J...",
  "body": "お問い合わせ本文",
  "turnstileToken": "..."
}
```

| 結果 | ステータス | ボディ |
|---|---|---|
| 成功 | 201 | `{ "receiptNumber": "INQ-000123" }` |
| バリデーションエラー | 400 | `{ "error": { "code": "validation_error", "fields": { "email": "メールアドレスの形式が正しくありません" } } }` |
| Turnstile 検証失敗 | 403 | `{ "error": { "code": "captcha_failed" } }` |
| レート制限（WAF） | 429 | WAF の既定レスポンス |

バリデーション:

| 項目 | ルール |
|---|---|
| name | 必須、100 文字以内 |
| email | 必須、メール形式、254 文字以内 |
| phone | 任意、数字とハイフンのみ、20 文字以内 |
| categoryId | 必須、有効な種別の ID |
| body | 必須、5,000 文字以内 |
| turnstileToken | 必須 |

サーバ側の処理順: Turnstile 検証 → バリデーション → 重複判定（`SUBMIT#` 項目）→ 採番 → 保存（問い合わせ、最初のメッセージ、イベント）→ 自動返信 → スタッフ通知 → 201。

メール送信に失敗しても保存は成功として 201 を返し、失敗はログとイベントに残す。

## 管理 API

すべて要認証。「管理者」と書いたものは `admin` グループのみ。

| メソッド | パス | 内容 |
|---|---|---|
| GET | `/api/admin/me` | 自分の表示名、メール、ロール |
| GET | `/api/admin/dashboard` | 未対応件数、要返信件数、自分の担当件数、直近 10 件 |
| GET | `/api/admin/inquiries` | 一覧。クエリ: `status`, `categoryId`, `assigneeId`, `needsReply`, `q`, `cursor`, `limit`（既定 20、最大 100） |
| GET | `/api/admin/inquiries/{receiptNo}` | 詳細。問い合わせ、メッセージ、メモ、イベント、同一メールの過去問い合わせ |
| PATCH | `/api/admin/inquiries/{receiptNo}/status` | `{ "status": "CLOSED" }` |
| PATCH | `/api/admin/inquiries/{receiptNo}/assignee` | `{ "assigneeId": "..." }`。`null` で解除 |
| POST | `/api/admin/inquiries/{receiptNo}/replies` | `{ "body": "..." }`。メール送信して履歴に保存 |
| POST | `/api/admin/inquiries/{receiptNo}/notes` | `{ "body": "..." }` |
| GET | `/api/admin/categories` | 無効も含めて全件 |
| POST | `/api/admin/categories` | 管理者。`{ "name": "...", "sortOrder": 1 }` |
| PATCH | `/api/admin/categories/{id}` | 管理者。名称、表示順、有効/無効 |
| GET | `/api/admin/users` | 担当者選択にも使うため全員が呼べる |
| POST | `/api/admin/users` | 管理者。`{ "name": "...", "email": "...", "role": "AGENT" }` |
| PATCH | `/api/admin/users/{id}` | 管理者。名前、ロール、有効/無効 |
| POST | `/api/admin/users/{id}/reset-password` | 管理者 |
| GET | `/api/admin/settings/mail` | 管理者 |
| PUT | `/api/admin/settings/mail` | 管理者 |

一覧のレスポンス:

```json
{
  "items": [
    {
      "receiptNo": "INQ-000123",
      "status": "OPEN",
      "categoryName": "製品について",
      "customerName": "山田 太郎",
      "customerEmail": "taro@example.com",
      "excerpt": "本文の冒頭…",
      "assignee": { "id": "...", "name": "佐藤" },
      "needsReply": true,
      "createdAt": "2026-10-11T01:23:45Z"
    }
  ],
  "nextCursor": "eyJ..."
}
```

## エラー形式

```json
{ "error": { "code": "validation_error", "message": "入力内容を確認してください", "fields": { "body": "必須です" } } }
```

| ステータス | code |
|---|---|
| 400 | `validation_error` |
| 401 | `unauthorized`（API Gateway が返す） |
| 403 | `forbidden`, `captcha_failed` |
| 404 | `not_found` |
| 409 | `conflict`（同時更新の競合など） |
| 500 | `internal_error` |

## ページング

`cursor` は DynamoDB の `LastEvaluatedKey` を Base64 にしたもの。クライアントは `nextCursor` をそのまま次のリクエストに渡す。キーワード検索（`q`）は Scan のため、同じ方式で続きを取得する。
