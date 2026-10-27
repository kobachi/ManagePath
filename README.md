# Manage-Path

Windows のユーザーパス／システムパスを管理または整理する PowerShell スクリプトです。
パスはレジストリから未展開のまま読み書きするため、`%SystemRoot%` などの環境変数表記を保ちます。

## 動作要件

- Windows PowerShell 5.1 以降
- 管理者として実行

## 共通パラメーター

### `-Scope`

操作対象のパスを指定します。既定値は `User` です。

| 値 | 対象 |
| --- | --- |
| `User` | 現在のユーザーパス |
| `Machine` | システムパス |
| `All` | 現在のユーザーパスとシステムパスの両方 |

- Add、Remove、Restore の対象は、`User` か `Machine` です。
- `All` は `List` と `Clean` で使用可能です。

### `-Format`

パス一覧の出力形式を指定します。既定値は `Table` です。

| 値 | 内容 |
| --- | --- |
| `Table` | スコープ、Index、存在状態、パスを表示 |
| `Json` | パスエントリを JSON で出力 |
| `Object` | パスエントリを PowerShell オブジェクトとして出力。パイプライン処理向け |

```powershell
# ユーザーパスを JSON で表示
.\Manage-Path.ps1 -Scope User -Format Json

# 存在しないパスエントリを抽出
.\Manage-Path.ps1 -Format Object | Where-Object { -not $_.Exists }
```

## 実行可能な操作

実行する操作は第1位置引数として指定しす（例: `Manage-Path.ps1 Add ...`）。
省略した場合は既定の `List` を実行します。`-Action` 引数でも指定できます。

### List

パスとディレクトリの存在状態を一覧表示します。
`-Scope All` を指定するとユーザーパスとシステムパスを両方表示します。
空のパス要素は表示されません。

```powershell
# 既定のユーザーパスを表形式で表示
.\Manage-Path.ps1

# ユーザーパスとシステムパスを JSON で表示
.\Manage-Path.ps1 -Scope All -Format Json
```


### Add

パスを追加します。
`-Path` は必須です。
`-Position` で追加位置を選択でき、既定値は `Append` です。

| パラメーター | 指定可能な値 | 説明 |
| --- | --- | --- |
| `-Path` | パス文字列 | 追加するディレクトリ。`;` は指定不可 |
| `-Position` | `Append` / `Prepend` | 末尾 / 先頭に追加 |

- 環境変数は `%VAR%` の表記のまま保存しますが、指定スコープから参照できる変数でなければなりません。
	- PowerShell では `%VAR%` をシングルクォートで囲んでください。
	- `cmd.exe` から実行すると、PowerShell に渡る前に `%VAR%` が展開されることがあります。
- 空のパス、無効なパス文字、整合しない `%` はエラーです。
- 存在しないディレクトリや相対パスは警告を出しますが追加されます。
- 正規化後に同じパスが既に登録済みの場合は警告し、変更しません。

```powershell
# ユーザーパスの末尾に追加
.\Manage-Path.ps1 Add -Scope User -Path 'C:\Tools\bin'

# %JAVA_HOME% 表記を保ち、システムパスの先頭に追加
.\Manage-Path.ps1 Add -Scope Machine -Path '%JAVA_HOME%\bin' -Position Prepend

# 変更せず、実行内容を確認
.\Manage-Path.ps1 Add -Scope User -Path '%LOCALAPPDATA%\Programs\Foo' -WhatIf
```

### Remove

パスを削除します。
`-Path` は必須です。
`Scope` は `User` または `Machine` を指定します。

`-Path` 指定は以下のバリエーションを自動吸収します。

- 大文字小文字や末尾の `\` などの表記揺れ
- 環境変数を展開した後のパスと一致

また、`-Path` にワイルドカード `*` を含めると一致する複数エントリをすべて削除します。

```powershell
# 指定した環境変数表記と、展開後に同じパスになる項目を削除
.\Manage-Path.ps1 Remove -Scope User -Path '%JAVA_HOME%\bin'

# C:\Tools 配下で任意の名前に一致する項目をすべて削除
.\Manage-Path.ps1 Remove -Scope User -Path 'C:\Tools\*' -WhatIf

# 確認プロンプトを省略して削除
.\Manage-Path.ps1 Remove -Scope User -Path 'C:\Tools\old' -Force
```

### Clean

パスを整理します。
`-Duplicate` と `-NonExist` の少なくとも一方が必要です。

| オプション | 動作 |
| --- | --- |
| `-Duplicate` | 重複エントリを削除。展開後のパスで比較し、大文字小文字、末尾の `\`、`.` / `..`、利用可能な8.3短縮名の違いを無視 |
| `-NonExist` | 参照不能な環境変数を含むエントリ、または固定ドライブ上でディレクトリが確実に存在しないエントリを削除 |

### -Duplicate 

- 重複時は環境変数（`%VAR%`）を含む表記を優先して残し、同じ条件なら先頭を残します。
- `-NonExist` で削除対象になるエントリは重複の残存候補になりません。
- `-Scope User -Duplicate` ではシステムパスと重複するユーザーパスも削除します。

### -NonExist

- `-NonExist` で存在を確実に判定できるのは固定ドライブ上のディレクトリです。
- 相対パス、UNC、ネットワーク / リムーバブル / 光学ドライブ、未接続ドライブ、アクセス拒否、リパースポイント、不- 正なパスなど判定できないものは警告を出して残します。
- 未定義変数や、対象スコープから参照できない変数は削除対象です。

各スコープの処理結果を `Scope`、`Status`、`RemovedCount`、`Removed`、`Backup`、`Error` を持つオブジェクトとして返します。`Status` は `NoChange`、`Changed`、`Skipped`、`Failed` のいずれかです。`-Scope All` では片方が失敗してももう一方を処理し、最後に失敗と変更済みスコープをエラーとして報告します。

```powershell
# ユーザーパスの重複だけを整理（システムパスとの重複もユーザー側から除去）
.\Manage-Path.ps1 Clean -Scope User -Duplicate

# User と Machine の重複、および存在しない項目を整理
.\Manage-Path.ps1 Clean -Scope All -Duplicate -NonExist

# 変更せず削除候補を確認
.\Manage-Path.ps1 Clean -Scope All -Duplicate -NonExist -WhatIf
```

### Restore

バックアップ JSON からパスを復元します。`Scope` は `User` または `Machine` のみ指定できます。

| パラメーター | 説明 |
| --- | --- |
| `-BackupFile` | バックアップファイル名またはフルパス。省略すると指定スコープの最新バックアップを使用 |

- バックアップは `%ProgramData%\PathManager\Backup` に保存されます。
- ファイルはこのフォルダー直下にある必要があり、所有者と書き込み権限が信頼できる場合にのみ復元されます。
- 復元前の現在値も自動でバックアップされます。
- 指定スコープとバックアップのスコープが異なる場合は復元できません。

```powershell
# ユーザーパスを最新のバックアップから復元
.\Manage-Path.ps1 Restore -Scope User

# ファイル名を指定してシステムパスを復元
.\Manage-Path.ps1 Restore -Scope Machine -BackupFile '20260101-120000-Machine.json' -WhatIf
```
