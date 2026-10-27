#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows の環境変数のパス (ユーザー / システム) を管理するスクリプト。

.DESCRIPTION
    現状の実装済みアクション:
        - List : ユーザーパス (既定) または指定スコープのパス一覧を取得・表示する
            - Add  : パスにエントリを追加する (%VAR% は展開せず、そのまま保存)
               参照する環境変数が存在しない場合はエラーにする
    - Remove : パスからエントリを削除する。環境変数を指定した場合は、
                 %VAR% 表記そのものに加え、展開後のパスと一致するエントリも削除する
    - Clean : パスを整理する。-Duplicate で重複エントリ、-NonExist で存在しないエントリを削除する
                (詳細は .PARAMETER Duplicate / NonExist と .NOTES)。スコープごとの結果
                (Scope / Status / RemovedCount / Removed / Backup / Error) をオブジェクトで返す。
                -Scope All で一方のスコープが失敗しても残りを処理し、最後に失敗したスコープと
                変更済みのスコープを示すエラーで終了する (終了コード 1)
    - Restore : バックアップ JSON からパスを復元する (変更系アクションは事前に自動でバックアップ)

    拡張方針 (編集機能の追加を前提とした構成):
      1. レジストリ アクセス層   : Get-RawPathValue / Set-RawPathValue
      2. 変換層                  : ConvertTo-PathEntries / ConvertFrom-PathEntries
      3. 操作層 (Invoke-*Action) : アクションごとに 1 関数。新しいアクションはここに追加する
      4. ディスパッチ            : 末尾の switch と param の ValidateSet に追記するだけ

    パスは [Environment]::GetEnvironmentVariable ではなくレジストリから直接読む。
    理由: GetEnvironmentVariable は %VAR% を展開済みで返すため、書き戻し時に
          元の未展開表記 (例: %SystemRoot%\system32) と値の型 (REG_EXPAND_SZ) が失われる。

.PARAMETER Action
    実行する操作。List (既定) / Add / Remove / Clean / Restore。

.PARAMETER Scope
    対象スコープ。User (既定) / Machine / All。

.PARAMETER Format
    出力形式。Table (既定) / Json / Object。

.EXAMPLE
    .\Manage-Path.ps1
    ユーザーパスを表形式で表示する。

.EXAMPLE
    .\Manage-Path.ps1 -Scope Machine -Format Json
    システムパスを JSON で出力する。

.EXAMPLE
    .\Manage-Path.ps1 -Format Object | Where-Object { -not $_.Exists }
    存在しないディレクトリを指しているパスエントリを抽出する。

.PARAMETER Path
    Add で追加 / Remove で削除するパス。%VAR% 形式の環境変数を含められる。
    Add: 展開されずにそのまま保存される。参照する環境変数が存在しない場合はエラー。
    Remove: %VAR% 表記のエントリと、展開後に同じパスになるエントリの両方を削除する。* は任意の文字列に一致する。

.PARAMETER Duplicate
    Clean で重複エントリを削除する。展開後・大文字小文字・末尾の '\'・'.' '..'・8.3 短縮名を無視して判定する。
    残すのは、変数 (%VAR%) を含む表記があればその先頭、なければ先頭のエントリ。
    User の処理 (-Scope User / All) では、システムパスに残る項目もユーザーパス側から削除する (システムパスは変更しない)。
    -Scope All では Machine → User の順に処理する。

.PARAMETER NonExist
    Clean で存在しないエントリを削除する。「存在しない」の定義は .NOTES を参照。

.PARAMETER BackupFile
    Restore で復元するバックアップ (%ProgramData%\PathManager\Backup 内のファイル名またはフルパス)。
    省略時は -Scope (User / Machine 必須) の最新。所有者・アクセス権が信頼できないファイルは拒否する。

.PARAMETER Force
    Remove / Clean / Restore は既定で実行前に確認プロンプトを表示する。-Force でプロンプトをスキップする
    (非対話実行用)。-WhatIf と併用した場合は実行せず内容だけ表示する。

.PARAMETER Position
    Add の挿入位置。Append (末尾、既定) / Prepend (先頭)。

.EXAMPLE
    .\Manage-Path.ps1 -Action Add -Scope Machine -Path 'C:\Tools\bin'

.EXAMPLE
    .\Manage-Path.ps1 -Action Add -Scope User -Path '%JAVA_HOME%\bin' -Position Prepend
    PowerShell ではシングルクォートで囲む。cmd.exe 経由で呼ぶ場合は cmd 側で
    %VAR% が展開されてしまうため注意。

.EXAMPLE
    .\Manage-Path.ps1 -Action Add -Scope User -Path '%LOCALAPPDATA%\Programs\Foo' -WhatIf
    変更せず、実行内容だけを確認する。

.EXAMPLE
    .\Manage-Path.ps1 -Action Remove -Scope User -Path '%JAVA_HOME%\bin'
    パス上の '%JAVA_HOME%\bin' と、JAVA_HOME 展開後の 'C:\Java\bin' などを両方削除する。

.EXAMPLE
    .\Manage-Path.ps1 -Action Clean -Scope All -Duplicate -NonExist -WhatIf
    重複と存在しないエントリを削除する場合の対象を、変更せずに確認する。

.EXAMPLE
    .\Manage-Path.ps1 -Action Clean -Scope User -Duplicate -Force
    ユーザーパスの重複 (システムパスとの重複を含む) を、確認プロンプトなしで削除する。

.EXAMPLE
    .\Manage-Path.ps1 -Action Restore -Scope User
    ユーザーパスを最新のバックアップから復元する (復元前の値もバックアップされる)。

.NOTES
    「現ユーザー」は管理者として昇格したプロセスのユーザー (HKCU) を指す。
    標準ユーザーとは別の管理者アカウントで昇格した場合、そのアカウントの HKCU が対象になる。

    Clean -NonExist で「存在しない」と見なすもの:
    - そのスコープのパスから参照できない環境変数 (未定義、システムパスから見たユーザー専用変数) を含むエントリ
      - 固定ドライブ上で、ディレクトリが確実に存在しないエントリ
    次は存在を判定できないため、警告して残す: 相対パス、UNC、固定ドライブ以外、未接続のドライブ、
    アクセス拒否、リパースポイント、不正な文字を含むパス。
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('List', 'Add', 'Remove', 'Clean', 'Restore')]
    [string]$Action = 'List',

    [ValidateSet('User', 'Machine', 'All')]
    [string]$Scope = 'User',

    [ValidateSet('Table', 'Json', 'Object')]
    [string]$Format = 'Table',

    # --- Add 用 ---
    [string]$Path,

    [ValidateSet('Append', 'Prepend')]
    [string]$Position = 'Append',

    # --- Clean 用 (少なくとも 1 つ指定) ---
    [switch]$Duplicate,
    [switch]$NonExist,

    # --- Restore 用 (ファイル名またはフルパス。省略時はスコープの最新) ---
    [string]$BackupFile,

    # 確認プロンプトを表示せずに実行する (Remove / Clean / Restore)。-WhatIf は引き続き有効
    [switch]$Force
)

Set-StrictMode -Version Latest
if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }   # 関数側の ShouldProcess にも動的スコープで引き継がれる
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# スコープ定義 (レジストリ上の保存場所)
#   新しいスコープや操作を足してもここを参照するだけで済むようにする
# ---------------------------------------------------------------------------
$script:ScopeDefinitions = [ordered]@{
    User    = @{
        Label   = 'ユーザー'
        Hive    = [Microsoft.Win32.Registry]::CurrentUser
        SubKey  = 'Environment'
    }
    Machine = @{
        Label   = 'システム'
        Hive    = [Microsoft.Win32.Registry]::LocalMachine
        SubKey  = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    }
}

$script:ValueName = 'Path'

# ---------------------------------------------------------------------------
# 共通ヘルパー
# ---------------------------------------------------------------------------
function Resolve-TargetScopes {
    <# 'All' を実スコープ名の配列に解決する #>
    param([Parameter(Mandatory)][string]$Scope)

    if ($Scope -eq 'All') { return @($script:ScopeDefinitions.Keys) }
    return @($Scope)
}

# ---------------------------------------------------------------------------
# 1. レジストリ アクセス層
# ---------------------------------------------------------------------------
function Get-RawPathValue {
    <#
    .SYNOPSIS
        指定スコープのパスを未展開のまま、値の型 (Kind) とともに取得する。
    .OUTPUTS
        PSCustomObject: Scope, Value (未展開文字列), Kind (ExpandString / String)
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope
    )

    $def = $script:ScopeDefinitions[$Scope]
    $key = $def.Hive.OpenSubKey($def.SubKey, $false)   # 読み取り専用
    if ($null -eq $key) {
        throw "レジストリキーを開けません: $($def.SubKey) ($Scope)"
    }

    try {
        $names = $key.GetValueNames()
        if ($names -notcontains $script:ValueName) {
            # 値が未作成の場合 (ユーザーパスでは普通にあり得る)
            return [pscustomobject]@{
                Scope = $Scope
                Value = ''
                Kind  = [Microsoft.Win32.RegistryValueKind]::ExpandString
            }
        }

        $kind  = $key.GetValueKind($script:ValueName)
        $value = $key.GetValue(
            $script:ValueName,
            '',
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )

        [pscustomobject]@{
            Scope = $Scope
            Value = [string]$value
            Kind  = $kind
        }
    }
    finally {
        $key.Dispose()
    }
}

function Set-RawPathValue {
    <#
    .SYNOPSIS
        指定スコープのパスを未展開のままレジストリへ書き込む。
    .NOTES
        %VAR% を含む値を REG_SZ で保存すると展開されないため、その場合は
        REG_EXPAND_SZ に切り替える。それ以外は元の Kind を維持する。
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,

        [Microsoft.Win32.RegistryValueKind]$Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    )

    if ($Value -match '%[^%]+%') {
        $Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    }

    $def = $script:ScopeDefinitions[$Scope]
    $key = $def.Hive.OpenSubKey($def.SubKey, $true)   # 書き込みオープン
    if ($null -eq $key) {
        throw "レジストリキーを書き込みで開けません: $($def.SubKey) ($Scope)"
    }

    try {
        $key.SetValue($script:ValueName, $Value, $Kind)
    }
    finally {
        $key.Dispose()
    }
}

function Get-BackupDirectory {
    Join-Path (Join-Path $env:ProgramData 'PathManager') 'Backup'
}

function Test-TrustedSid {
    <# SYSTEM / Administrators / TrustedInstaller / CREATOR OWNER のみ信頼する #>
    param([Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid)

    $Sid.Value -in @(
        'S-1-5-18', 'S-1-5-32-544', 'S-1-3-0',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
}

function Initialize-BackupDirectory {
    <#
    .SYNOPSIS
        バックアップ保存先を作成し、SYSTEM / Administrators のみが書き込める ACL にする。
    .NOTES
        ProgramData 直下は標準ユーザーもフォルダーを作れるため、事前に作成された
        フォルダー (所有者が信頼できない) を使わずにエラーにする。
        上位 (PathManager) と Backup の両方に適用する。
    #>
    $root = Join-Path $env:ProgramData 'PathManager'
    $sidType = [System.Security.Principal.SecurityIdentifier]

    foreach ($d in @($root, (Get-BackupDirectory))) {
        if (-not [System.IO.Directory]::Exists($d)) {
            [void][System.IO.Directory]::CreateDirectory($d)
        }

        $acl   = Get-Acl -LiteralPath $d
        $owner = $acl.GetOwner($sidType)
        if (-not (Test-TrustedSid -Sid $owner)) {
            throw "バックアップフォルダーの所有者が信頼できません ($owner): $d。内容を確認して削除してから再実行してください。"
        }

        $acl.SetAccessRuleProtection($true, $false)   # 継承を無効化し、継承済み ACE は破棄
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        foreach ($sidText in 'S-1-5-18', 'S-1-5-32-544') {
            $sid  = New-Object $sidType $sidText
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $d -AclObject $acl
    }
}

function Test-BackupFileTrusted {
    <# バックアップファイルの所有者と書き込み権限がすべて信頼できる主体に限られているか #>
    param([Parameter(Mandatory)][string]$File)

    $sidType = [System.Security.Principal.SecurityIdentifier]
    $acl = Get-Acl -LiteralPath $File
    if (-not (Test-TrustedSid -Sid $acl.GetOwner($sidType))) { return $false }

    $write = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, Delete, ChangePermissions, TakeOwnership'
    foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        if (($rule.FileSystemRights -band $write) -ne 0 -and -not (Test-TrustedSid -Sid $rule.IdentityReference)) {
            return $false
        }
    }
    $true
}

function Export-PathBackup {
    <# 変更前のパス (未展開の値と Kind) を JSON でバックアップし、ファイルパスを返す。スコープごとに直近 50 世代を保持する #>
    param(
        [Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$Scope,
        [Parameter(Mandatory)]$Raw
    )

    Initialize-BackupDirectory
    $dir = Get-BackupDirectory

    $now  = Get-Date
    $file = Join-Path $dir ('{0:yyyyMMdd-HHmmss}-{1}.json' -f $now, $Scope)

    [pscustomobject]@{
        Scope = $Scope
        Date  = $now.ToString('o')
        User  = [Environment]::UserName
        Kind  = [string]$Raw.Kind
        Value = $Raw.Value
    } | ConvertTo-Json | Set-Content -LiteralPath $file -Encoding UTF8

    Get-ChildItem -LiteralPath $dir -Filter "*-$Scope.json" -File |
        Sort-Object Name -Descending |
        Select-Object -Skip 50 |
        Remove-Item -Force

    $file
}

function Read-PathBackup {
    <#
    .SYNOPSIS
        バックアップファイルを検証して読み込む (省略時はスコープの最新)。
    .NOTES
        ファイルはバックアップフォルダー直下にあり、信頼できる ACL であること、
        Scope / Kind / Value が妥当であることを確認する (改ざんされたバックアップをシステムパスに書かないため)。
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$Scope,
        [string]$BackupFile
    )

    $dir = [System.IO.Path]::GetFullPath((Get-BackupDirectory)).TrimEnd('\')

    if ([string]::IsNullOrWhiteSpace($BackupFile)) {
        $latest = Get-ChildItem -LiteralPath $dir -Filter "*-$Scope.json" -File -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latest) { throw "$Scope のバックアップがありません: $dir" }
        $full = $latest.FullName
    }
    else {
        if (-not [System.IO.Path]::IsPathRooted($BackupFile)) { $BackupFile = Join-Path $dir $BackupFile }
        $full = [System.IO.Path]::GetFullPath($BackupFile)
    }

    if (([System.IO.Path]::GetDirectoryName($full)).TrimEnd('\') -ine $dir) {
        throw "バックアップフォルダー外のファイルは使えません: $full"
    }
    if (-not [System.IO.File]::Exists($full)) { throw "バックアップファイルがありません: $full" }
    if (-not (Test-BackupFileTrusted -File $full)) {
        throw "バックアップファイルの所有者またはアクセス権が信頼できないため復元しません: $full"
    }

    $json = Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($json.Scope -ne $Scope) { throw "バックアップのスコープ ($($json.Scope)) が指定 ($Scope) と一致しません: $full" }
    if ($json.Kind -notin 'String', 'ExpandString') { throw "バックアップの Kind が不正です: $($json.Kind)" }
    if ($json.Value -isnot [string] -or $json.Value.Contains([char]0)) { throw "バックアップの Value が不正です: $full" }

    [pscustomobject]@{
        File  = $full
        Date  = $json.Date
        Kind  = [Microsoft.Win32.RegistryValueKind]$json.Kind
        Value = $json.Value
    }
}

function Send-EnvironmentChangeNotification {
    <# WM_SETTINGCHANGE をブロードキャストし、エクスプローラー等に環境変数の変更を通知する #>
    if (-not ('PathManager.NativeMethods' -as [type])) {
        Add-Type -Namespace PathManager -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }

    $result = [UIntPtr]::Zero
    $ret = [PathManager.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff,   # HWND_BROADCAST
        0x1A,             # WM_SETTINGCHANGE
        [UIntPtr]::Zero,
        'Environment',
        0x2,              # SMTO_ABORTIFHUNG
        5000,
        [ref]$result)

    if ($ret -eq [IntPtr]::Zero) {
        Write-Warning '環境変数の変更通知 (WM_SETTINGCHANGE) に失敗しました。サインアウトまたは再起動で反映されます。'
    }
}

function Test-RegistryEnvironmentVariable {
    <# 指定スコープの環境変数レジストリキーに、その名前の値が保存されているか #>
    param(
        [Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$Scope,
        [Parameter(Mandatory)][string]$Name
    )

    $def = $script:ScopeDefinitions[$Scope]
    $key = $def.Hive.OpenSubKey($def.SubKey, $false)
    if ($null -eq $key) { return $false }

    try {
        return ($key.GetValueNames() -contains $Name)   # -contains は大文字小文字を区別しない
    }
    finally {
        $key.Dispose()
    }
}

function Test-EnvironmentVariableDefined {
    <#
    .SYNOPSIS
        パス (指定スコープ) から %Name% として参照できる環境変数が存在するか判定する。
    .NOTES
        判定順:
          1. システム環境変数 (レジストリ) にあれば、どのスコープからも参照可能 -> 存在
             2. ユーザー環境変数 (レジストリ) のみにある場合、ユーザーパスからのみ参照可能
                 (システムパスからは参照できないため不在扱い)
          3. レジストリにない場合は、ログオン時に動的設定される変数
             (SystemRoot / ProgramFiles / USERPROFILE など) を含むプロセス環境で判定
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$Scope,
        [Parameter(Mandatory)][string]$Name
    )

    if (Test-RegistryEnvironmentVariable -Scope Machine -Name $Name) { return $true }
    if (Test-RegistryEnvironmentVariable -Scope User    -Name $Name) { return ($Scope -eq 'User') }
    return ($null -ne [Environment]::GetEnvironmentVariable($Name, 'Process'))
}

# ---------------------------------------------------------------------------
# 2. 変換層
# ---------------------------------------------------------------------------
function ConvertTo-PathEntries {
    <#
    .SYNOPSIS
        パス文字列を、1 エントリ 1 オブジェクトのリストに変換する。
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope,

        [AllowEmptyString()]
        [string]$RawValue = ''
    )

    $index = 0
    foreach ($segment in $RawValue.Split(';')) {
        $path = $segment.Trim()
        if ([string]::IsNullOrEmpty($path)) { continue }   # 空要素は無視

        # パスの項目は引用符で囲まれていることがあるので判定時のみ外す
        $normalized = $path.Trim('"')
        $expanded   = [Environment]::ExpandEnvironmentVariables($normalized)

        [pscustomobject]@{
            Scope        = $Scope
            Index        = $index
            Path         = $path                                   # 未展開 (書き戻し用の元データ)
            Expanded     = $expanded                               # 展開後
            HasVariable  = ($normalized -match '%[^%]+%')
            Exists       = [System.IO.Directory]::Exists($expanded)
        }
        $index++
    }
}

function ConvertFrom-PathEntries {
    <# 未展開のパス文字列の配列を、パス文字列 (';' 区切り) に変換する #>
    param(
        [AllowEmptyCollection()]
        [string[]]$Paths = @()
    )

    $Paths -join ';'
}

# ---------------------------------------------------------------------------
# 3. 取得 API (操作層から共通で使う)
# ---------------------------------------------------------------------------
function Get-PathEntries {
    <#
    .SYNOPSIS
        指定スコープのパスエントリを取得する。
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine', 'All')]
        [string]$Scope
    )

    foreach ($s in Resolve-TargetScopes -Scope $Scope) {
        $raw = Get-RawPathValue -Scope $s
        ConvertTo-PathEntries -Scope $s -RawValue $raw.Value
    }
}

# ---------------------------------------------------------------------------
# 4. 操作層 (アクションごとに 1 関数)
# ---------------------------------------------------------------------------
function Invoke-ListAction {
    param(
        [string]$Scope = 'User',
        [string]$Format = 'Table'
    )

    $entries = @(Get-PathEntries -Scope $Scope)

    switch ($Format) {
        'Object' {
            $entries
        }
        'Json' {
            $entries | ConvertTo-Json -Depth 3
        }
        'Table' {
            foreach ($s in Resolve-TargetScopes -Scope $Scope) {
                $label = $script:ScopeDefinitions[$s].Label
                $group = @($entries | Where-Object { $_.Scope -eq $s })

                Write-Host ''
                Write-Host ("=== {0}パス ({1} 件) ===" -f $label, $group.Count) -ForegroundColor Cyan

                if ($group.Count -eq 0) {
                    Write-Host '(エントリなし)'
                    continue
                }

                $group |
                    Format-Table -AutoSize -Property `
                        Index,
                        @{ Name = 'Exists'; Expression = { if ($_.Exists) { 'OK' } else { 'NG' } } },
                        Path |
                    Out-String -Width 4096 |
                    Write-Host
            }
        }
    }
}

function Get-LongPathName {
    <# 8.3 短縮名 (~ を含むパス) を、固定ドライブ上で実在する部分に限り長い名前へ戻す。失敗時は元のパスを返す #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not $Path.Contains('~')) { return $Path }

    try {
        # ネットワーク / リムーバブルドライブでの I/O 待ちを避ける
        $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($Path))
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed -or -not $drive.IsReady) { return $Path }

        if (-not ('PathManager.LongPath' -as [type])) {
            Add-Type -Namespace PathManager -Name LongPath -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetLongPathNameW(string lpszShortPath, System.Text.StringBuilder lpszLongPath, uint cchBuffer);
'@
        }

        $sb = [System.Text.StringBuilder]::new(32768)
        $n  = [PathManager.LongPath]::GetLongPathNameW($Path, $sb, [uint32]$sb.Capacity)
        if ($n -gt 0 -and $n -lt $sb.Capacity) { return $sb.ToString() }
    }
    catch { }

    $Path
}

function Get-ComparablePath {
    <#
    .SYNOPSIS
        重複判定用の比較キー。
    .NOTES
        引用符除去 → 環境変数展開 → '/' を '\' に統一。
        -Scope を指定した場合、そのスコープのパスから参照できない変数 (システムパスでのユーザー専用変数、未定義変数) は
        展開せず、%VAR% のまま比較する。
        ドライブ絶対パス / UNC のみ、'.' '..' の解消 (GetFullPath) と 8.3 短縮名の展開を行う。
        相対パスや未定義変数を含むパスはカレントディレクトリ依存になるため、これらは行わない。
        末尾の '\' は除去する (ドライブルート 'C:\' は残す)。
        シンボリックリンク / ジャンクションは別のパスとして扱い、解決しない。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('User', 'Machine')][string]$Scope
    )

    $p = $Path.Trim().Trim('"')
    $p = [regex]::Replace($p, '%([^%]+)%', [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $name = $m.Groups[1].Value
        if ($Scope -and -not (Test-EnvironmentVariableDefined -Scope $Scope -Name $name)) { return $m.Value }
        $v = [Environment]::GetEnvironmentVariable($name)
        if ($null -eq $v) { $m.Value } else { $v }
    })
    $p = $p.Replace('/', '\')

    if ($p -match '^([A-Za-z]:\\|\\\\)') {
        try {
            $p = Get-LongPathName -Path ([System.IO.Path]::GetFullPath($p))
        }
        catch { }   # 不正な文字を含む場合は正規化せずそのまま比較する
    }

    if ($p -match '^[A-Za-z]:\\$') { return $p }
    $p.TrimEnd('\')
}

function ConvertTo-NormalizedPathInput {
    <#
    .SYNOPSIS
        -Path の基本検証 (Add / Remove 共通)。正規化した文字列 (環境変数は未展開) を返す。
    .NOTES
        エラーにするもの:
          - 空 / ';' を含む / パスに使えない文字を含む
          - '%' の対応が取れていない
        環境変数の存在確認は含まない (Add のみ ConvertTo-ValidatedPathInput で行う)。
    #>
    param(
        [string]$Path,
        [switch]$AllowWildcard
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw '-Path の指定が必要です。'
    }

    $p = $Path.Trim().Trim('"').Trim()
    if ([string]::IsNullOrEmpty($p)) {
        throw '-Path の指定が必要です。'
    }
    if ($p.Contains(';')) {
        throw "-Path に ';' は含められません: $p"
    }
    $invalidPathChars = [System.IO.Path]::GetInvalidPathChars()
    if ($AllowWildcard) {
        $invalidPathChars = $invalidPathChars | Where-Object { $_ -ne '*' }
    }
    if ((-not $AllowWildcard -and $p.Contains('*')) -or $p.IndexOfAny([char[]]$invalidPathChars) -ge 0) {
        throw "-Path にパスで使用できない文字が含まれています: $p"
    }

    # %VAR% を取り除いたあとに '%' が残っていれば書式不正
    if ([regex]::Replace($p, '%[^%]+%', '').Contains('%')) {
        throw "環境変数の書式が不正です ('%' の対応が取れていません): $p"
    }

    $p
}

function ConvertTo-ValidatedPathInput {
    <#
    .SYNOPSIS
        Add の入力を検証し、パスに保存する文字列 (環境変数は未展開のまま) を返す。
    .NOTES
        基本検証 (ConvertTo-NormalizedPathInput) に加え、
        存在しない環境変数を参照している場合もエラーにする。
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$Scope,
        [string]$Path
    )

    $p = ConvertTo-NormalizedPathInput -Path $Path

    # 参照している環境変数がすべて存在することを確認
    $names = Get-ReferencedVariableNames -Path $p
    $missing = @($names | Where-Object { -not (Test-EnvironmentVariableDefined -Scope $Scope -Name $_) })
    if ($missing.Count -gt 0) {
        $list = ($missing | ForEach-Object { "%$_%" }) -join ', '
        throw "存在しない環境変数が含まれています: $list ($($script:ScopeDefinitions[$Scope].Label)パスから参照できる変数のみ使用可)"
    }

    $p
}

function Get-ReferencedVariableNames {
    <# パスエントリが %VAR% として参照している環境変数名 (重複なし) #>
    param([Parameter(Mandatory)][string]$Path)

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    @(
        [regex]::Matches($Path, '%([^%]+)%') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $seen.Add($_) }
    )
}

function Save-PathChange {
    <#
    .SYNOPSIS
        変更系アクション共通の実行部: バックアップ → 書き込み → 変更通知 → 結果表示。
    .NOTES
        呼び出し元の ShouldProcess を通した後に呼ぶこと。
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$Scope,
        [Parameter(Mandatory)]$Raw,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Format,
        [Parameter(Mandatory)][string]$Message,
        [Microsoft.Win32.RegistryValueKind]$Kind,
        [string]$BackupLabel = 'バックアップ',
        [ref]$BackupPath   # 作成したバックアップのパスを受け取りたいときに指定
    )

    if (-not $PSBoundParameters.ContainsKey('Kind')) { $Kind = $Raw.Kind }

    $backup = Export-PathBackup -Scope $Scope -Raw $Raw
    if ($PSBoundParameters.ContainsKey('BackupPath')) { $BackupPath.Value = $backup }
    Set-RawPathValue -Scope $Scope -Value $Value -Kind $Kind
    Send-EnvironmentChangeNotification

    Write-Host $Message -ForegroundColor Green
    Write-Host ("{0}: {1}" -f $BackupLabel, $backup)
    Write-Host '起動済みのターミナル/アプリには反映されません。開き直してください。'

    Invoke-ListAction -Scope $Scope -Format $Format
}

function Invoke-AddAction {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Scope = 'User',
        [string]$Path,
        [Parameter(Mandatory)][ValidateSet('Append', 'Prepend')][string]$Position,
        [string]$Format = 'Table'
    )

    # 編集は対象を 1 つに限定する (誤って両方に書き込まないため)
    if ($Scope -eq 'All') {
        throw 'Add では -Scope に User または Machine を指定してください。'
    }

    $newPath = ConvertTo-ValidatedPathInput -Scope $Scope -Path $Path
    $label   = $script:ScopeDefinitions[$Scope].Label

    $raw     = Get-RawPathValue -Scope $Scope
    $entries = @(ConvertTo-PathEntries -Scope $Scope -RawValue $raw.Value)

    # 重複チェック (展開後の値で、大文字小文字を区別せず比較)
    $newKey = Get-ComparablePath -Path $newPath -Scope $Scope
    $dup = $entries |
        Where-Object { (Get-ComparablePath -Path $_.Path -Scope $Scope) -ieq $newKey } |
        Select-Object -First 1
    if ($dup) {
        Write-Warning ("{0}パスには既に登録されています (Index {1}: {2})。変更しません。" -f $label, $dup.Index, $dup.Path)
        return
    }

    # 警告のみ (エラーにはしない)
    $expanded = [Environment]::ExpandEnvironmentVariables($newPath)
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        Write-Warning "絶対パスではありません: $expanded"
    }
    elseif (-not [System.IO.Directory]::Exists($expanded)) {
        Write-Warning "ディレクトリが存在しません: $expanded"
    }

    # 新しいパス文字列を組み立てる (既存エントリは未展開のまま保持)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $entries) { $paths.Add($e.Path) }
    if ($Position -eq 'Prepend') { $paths.Insert(0, $newPath) } else { $paths.Add($newPath) }
    $newValue = ConvertFrom-PathEntries -Paths $paths.ToArray()

    if ($newValue.Length -gt 2047) {
        Write-Warning ("パスの長さが {0} 文字になります。2048 文字を超えると一部のツールで正しく扱えません。" -f $newValue.Length)
    }

    $action = "'{0}' を{1}に追加" -f $newPath, $(if ($Position -eq 'Prepend') { '先頭' } else { '末尾' })
    if ($PSCmdlet.ShouldProcess("$($label)パス", $action)) {
        Save-PathChange -Scope $Scope -Raw $raw -Value $newValue -Format $Format `
            -Message ("{0}パスに追加しました: {1}" -f $label, $newPath)
    }
}

function Invoke-RemoveAction {
    <#
    .SYNOPSIS
        パスから該当エントリを削除する。
    .NOTES
          次のいずれかに該当するエントリをすべて削除する。
          1. 指定と同じ表記 (大文字小文字・末尾の '\' は無視)
             例: -Path '%JAVA_HOME%\bin' に対するパス上の '%JAVA_HOME%\bin'
          2. 環境変数を展開した結果が同じパス
             例: -Path '%JAVA_HOME%\bin' に対するパス上の 'C:\Java\bin'
                 (展開は現在のプロセス環境を使用。パス側の %VAR% も展開して比較する)
             3. -Path に '*' が含まれる場合、その位置で任意の文字列に一致するエントリ
                 '*' 以外のワイルドカード構文は解釈せず、文字どおり扱う
        Add と違い、存在しない環境変数を含む -Path でもエラーにしない
        (削除済みの変数を参照する古いエントリを消せるようにするため。1 の表記一致で削除される)。
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string]$Scope = 'User',
        [string]$Path,
        [string]$Format = 'Table'
    )

    if ($Scope -eq 'All') {
        throw 'Remove では -Scope に User または Machine を指定してください。'
    }

    $target         = ConvertTo-NormalizedPathInput -Path $Path -AllowWildcard
    $targetRaw      = $target.TrimEnd('\')
    $targetExpanded = Get-ComparablePath -Path $target -Scope $Scope
    $hasWildcard    = $target.Contains('*')
    if ($hasWildcard) {
        $targetRawPattern      = '^' + [regex]::Escape($targetRaw.Replace('/', '\')).Replace('\*', '.*') + '$'
        $targetExpandedPattern = '^' + [regex]::Escape($targetExpanded).Replace('\*', '.*') + '$'
    }
    $label          = $script:ScopeDefinitions[$Scope].Label

    $raw     = Get-RawPathValue -Scope $Scope
    $entries = @(ConvertTo-PathEntries -Scope $Scope -RawValue $raw.Value)

    $removed = [System.Collections.Generic.List[object]]::new()
    $kept    = [System.Collections.Generic.List[string]]::new()

    foreach ($e in $entries) {
        $entryRaw = $e.Path.Trim('"').TrimEnd('\')

        if ($hasWildcard -and (
            [regex]::IsMatch($entryRaw.Replace('/', '\'), $targetRawPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -or
            [regex]::IsMatch((Get-ComparablePath -Path $e.Path -Scope $Scope), $targetExpandedPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        )) {
            $reason = 'ワイルドカードに一致'
        }
        elseif ($entryRaw -ieq $targetRaw) {
            $reason = '表記が一致'
        }
        elseif ((Get-ComparablePath -Path $e.Path -Scope $Scope) -ieq $targetExpanded) {
            $reason = '展開後のパスが一致'
        }
        else {
            $kept.Add($e.Path)
            continue
        }

        $removed.Add([pscustomobject]@{ Index = $e.Index; Path = $e.Path; Reason = $reason })
    }

    if ($removed.Count -eq 0) {
        Write-Warning ("{0}パスに該当するエントリがありません: {1} (展開後: {2})。変更しません。" -f $label, $target, $targetExpanded)
        return
    }

    Write-Host ("削除対象 ({0} 件):" -f $removed.Count) -ForegroundColor Yellow
    foreach ($r in $removed) {
        Write-Host ("  [{0}] {1}  ({2})" -f $r.Index, $r.Path, $r.Reason)
    }

    $newValue = ConvertFrom-PathEntries -Paths $kept.ToArray()

    $action = "'{0}' に該当する {1} 件を削除" -f $target, $removed.Count
    if ($PSCmdlet.ShouldProcess("$($label)パス", $action)) {
        Save-PathChange -Scope $Scope -Raw $raw -Value $newValue -Format $Format `
            -Message ("{0}パスから {1} 件削除しました。" -f $label, $removed.Count)
    }
}

function Invoke-RestoreAction {
    <#
    .NOTES
        復元前に現在の値もバックアップする (復元自体も元に戻せる)。
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string]$Scope = 'User',
        [string]$BackupFile,
        [string]$Format = 'Table'
    )

    if ($Scope -eq 'All') {
        throw 'Restore では -Scope に User または Machine を指定してください。'
    }

    $label  = $script:ScopeDefinitions[$Scope].Label
    $backup = Read-PathBackup -Scope $Scope -BackupFile $BackupFile
    $raw    = Get-RawPathValue -Scope $Scope

    if ($raw.Value -ceq $backup.Value) {
        Write-Warning "$($label)パスはバックアップと同じ内容です。変更しません。"
        return
    }

    $before = @(ConvertTo-PathEntries -Scope $Scope -RawValue $raw.Value).Count
    $after  = @(ConvertTo-PathEntries -Scope $Scope -RawValue $backup.Value).Count
    Write-Host ("復元元: {0} ({1})" -f $backup.File, $backup.Date)
    Write-Host ("エントリ数: {0} -> {1}" -f $before, $after)

    if ($PSCmdlet.ShouldProcess("$($label)パス", "$($backup.File) から復元")) {
        Save-PathChange -Scope $Scope -Raw $raw -Value $backup.Value -Kind $backup.Kind -Format $Format `
            -Message ("{0}パスを復元しました。" -f $label) -BackupLabel '復元前の値のバックアップ'
    }
}

function Get-DirectoryStatus {
    <#
    .SYNOPSIS
        ディレクトリの存在を Exists / Missing / Unknown で返す。
    .NOTES
        Missing は「存在しないと確実に言える」場合のみ。次は Unknown (Clean で削除しない):
          相対パス、UNC、固定ドライブ以外 (ネットワーク / リムーバブル / 光学)、未接続・未準備のドライブ、
          アクセス拒否や I/O エラー、リパースポイント (リンク切れの可能性)、不正な文字を含むパス。
    #>
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Directory]::Exists($Path)) { return 'Exists' }

    try {
        if (-not [System.IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) { return 'Unknown' }

        $root  = [System.IO.Path]::GetPathRoot($Path)
        $drive = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -ieq $root } | Select-Object -First 1
        if ($null -eq $drive -or $drive.DriveType -ne [System.IO.DriveType]::Fixed -or -not $drive.IsReady) {
            return 'Unknown'
        }

        $attr = [System.IO.File]::GetAttributes($Path)
        if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { return 'Unknown' }
        return 'Missing'   # ファイルを指している場合もディレクトリとしては不在
    }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] {
        return 'Missing'
    }
    catch {
        return 'Unknown'
    }
}

function Get-CleanPlan {
    <#
    .SYNOPSIS
        1 スコープ分の Clean 計画 (削除するエントリと残すエントリ) を作る。書き込みはしない。
    .OUTPUTS
        PSCustomObject: Removed (Index / Path / Reason の配列), Kept (未展開のパス文字列の配列)
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$TargetScope,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory)]$MachineSeen,
        [switch]$Duplicate,
        [switch]$NonExist
    )

    $label   = $script:ScopeDefinitions[$TargetScope].Label
    $removed = [System.Collections.Generic.List[object]]::new()
    $kept    = [System.Collections.Generic.List[string]]::new()

    # 1 周目: 存在しないエントリ / Machine との重複を決める
    $reasons = @{}
    $keys    = @{}
    foreach ($e in $Entries) {
        $reason = $null

        if ($NonExist) {
            $undefined = @(Get-ReferencedVariableNames -Path $e.Path |
                Where-Object { -not (Test-EnvironmentVariableDefined -Scope $TargetScope -Name $_) })
            if ($undefined.Count -gt 0) {
                $reason = '未定義の環境変数: ' + (($undefined | ForEach-Object { "%$_%" }) -join ', ')
            }
            elseif (-not $e.Exists) {
                if ((Get-DirectoryStatus -Path $e.Expanded.Trim('"')) -eq 'Missing') {
                    $reason = 'ディレクトリが存在しない'
                }
                else {
                    Write-Warning ("{0}パス: 存在を判定できないため残します: {1}" -f $label, $e.Path)
                }
            }
        }

        if ($Duplicate) {
            $keys[$e.Index] = Get-ComparablePath -Path $e.Path -Scope $TargetScope
            if (-not $reason -and $MachineSeen.Contains($keys[$e.Index])) {
                $reason = 'システムパスと重複'
            }
        }

        $reasons[$e.Index] = $reason
    }

    # 2 周目: 全場所で残るエントリ同士の重複では、変数を含む表記を優先して残す (同格なら先頭)
    $winners = @{}
    if ($Duplicate) {
        foreach ($e in $Entries) {
            if ($reasons[$e.Index]) { continue }
            $k = $keys[$e.Index]
            if (-not $winners.ContainsKey($k) -or ($e.HasVariable -and -not $winners[$k].HasVariable)) {
                $winners[$k] = $e
            }
        }
    }

    foreach ($e in $Entries) {
        $reason = $reasons[$e.Index]

        if (-not $reason -and $Duplicate -and $winners[$keys[$e.Index]].Index -ne $e.Index) {
            $reason = '重複 (残すエントリ: {0})' -f $winners[$keys[$e.Index]].Path
        }

        if ($reason) {
            $removed.Add([pscustomobject]@{ Index = $e.Index; Path = $e.Path; Reason = $reason })
        }
        else {
            $kept.Add($e.Path)
        }
    }

    [pscustomobject]@{ Removed = $removed.ToArray(); Kept = $kept.ToArray() }
}

function Invoke-CleanAction {
    <#
    .NOTES
        User / Machine をそれぞれ独立に処理するが、User の処理ではシステムパスに残る項目と重複するユーザーパス側を削除する。
        -Scope All では Machine → User の順で処理し、Machine を整理した後の内容と比較する
        (Machine 側で削除される項目との重複で User 側も消えてしまうことを防ぐ)。
        重複は展開後・大文字小文字・末尾の '\' を無視して判定する。残すのは、変数 (%VAR%) を含む表記があればその先頭、
        なければ先頭のエントリ。削除するエントリ (-NonExist や Machine との重複) は残す候補にしない。
        -NonExist は、ディレクトリが確実に存在しない、またはそのスコープのパスから
        参照できない環境変数を含むエントリを削除する。存在を判定できないエントリ
        (Get-DirectoryStatus が Unknown) は警告を出して残す。
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string]$Scope = 'User',
        [string]$Format = 'Table',
        [switch]$Duplicate,
        [switch]$NonExist
    )

    if (-not $Duplicate -and -not $NonExist) {
        throw 'Clean では -Duplicate または -NonExist の少なくとも一方を指定してください。'
    }

    # Machine → User の順。User のシステムパスとの重複判定を、Machine を整理した後の内容と比べるため
    $machineKeys = $null
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($targetScope in @(Resolve-TargetScopes -Scope $Scope | Sort-Object { $_ -ne 'Machine' })) {
        # 片方のスコープが失敗してももう片方の処理を続け、結果をスコープごとに報告する
        try {
            $label   = $script:ScopeDefinitions[$targetScope].Label
            $raw     = Get-RawPathValue -Scope $targetScope
            $entries = @(ConvertTo-PathEntries -Scope $targetScope -RawValue $raw.Value)

            # User の処理では、システムパスに残る項目をユーザーパス側から削除する
            $machineSeen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            if ($Duplicate -and $targetScope -eq 'User') {
                if ($null -ne $machineKeys) {
                    $machineSeen = $machineKeys   # -Scope All: Machine 整理後の内容
                }
                else {
                    $machineRaw = Get-RawPathValue -Scope Machine
                    foreach ($m in ConvertTo-PathEntries -Scope Machine -RawValue $machineRaw.Value) {
                        [void]$machineSeen.Add((Get-ComparablePath -Path $m.Path -Scope Machine))
                    }
                }
            }

            $plan = Get-CleanPlan -TargetScope $targetScope -Entries $entries -MachineSeen $machineSeen `
                -Duplicate:$Duplicate -NonExist:$NonExist

            if ($Duplicate -and $targetScope -eq 'Machine') {
                $machineKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($k in $plan.Kept) { [void]$machineKeys.Add((Get-ComparablePath -Path $k -Scope Machine)) }
            }

            $result = [pscustomobject]@{
                PSTypeName   = 'PathManager.CleanResult'
                Scope        = $targetScope
                Status       = 'NoChange'   # NoChange / Changed / Skipped (-WhatIf ・確認で拒否) / Failed
                RemovedCount = $plan.Removed.Count
                Removed      = $plan.Removed
                Backup       = $null
                Error        = $null
            }

            if ($plan.Removed.Count -eq 0) {
                Write-Host ("{0}パス: 削除対象はありません。" -f $label)
                $results.Add($result)
                continue
            }

            Write-Host ("{0}パスの削除対象 ({1} 件):" -f $label, $plan.Removed.Count) -ForegroundColor Yellow
            foreach ($r in $plan.Removed) {
                Write-Host ("  [{0}] {1}  ({2})" -f $r.Index, $r.Path, $r.Reason)
            }

            $newValue = ConvertFrom-PathEntries -Paths $plan.Kept

            if ($PSCmdlet.ShouldProcess("$($label)パス", "$($plan.Removed.Count) 件を削除")) {
                $backupPath = $null
                Save-PathChange -Scope $targetScope -Raw $raw -Value $newValue -Format $Format `
                    -Message ("{0}パスから {1} 件削除しました。" -f $label, $plan.Removed.Count) `
                    -BackupPath ([ref]$backupPath)
                $result.Status = 'Changed'
                $result.Backup = $backupPath
            }
            else {
                $result.Status = 'Skipped'
            }
            $results.Add($result)
        }
        catch {
            Write-Warning ("{0}パスの整理に失敗しました: {1}" -f $script:ScopeDefinitions[$targetScope].Label, $_.Exception.Message)
            $results.Add([pscustomobject]@{
                PSTypeName   = 'PathManager.CleanResult'
                Scope        = $targetScope
                Status       = 'Failed'
                RemovedCount = 0
                Removed      = @()
                Backup       = $null
                Error        = $_.Exception.Message
            })
        }
    }

    # スコープごとの結果をパイプラインへ返す (自動化用)
    $results.ToArray()

    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    if ($failed.Count -gt 0) {
        $changed = @($results | Where-Object { $_.Status -eq 'Changed' } | ForEach-Object { $_.Scope })
        $msg = 'Clean が一部のスコープで失敗しました: ' + (($failed | ForEach-Object { '{0} ({1})' -f $_.Scope, $_.Error }) -join ', ')
        if ($changed.Count -gt 0) { $msg += '。変更済み: ' + ($changed -join ', ') }
        throw $msg
    }
}

# ---------------------------------------------------------------------------
# 5. ディスパッチ
# ---------------------------------------------------------------------------
try {
    switch ($Action) {
        'List' { Invoke-ListAction -Scope $Scope -Format $Format }
        'Add'  { Invoke-AddAction -Scope $Scope -Path $Path -Position $Position -Format $Format }
        'Remove' { Invoke-RemoveAction -Scope $Scope -Path $Path -Format $Format }
        'Clean' { Invoke-CleanAction -Scope $Scope -Format $Format -Duplicate:$Duplicate -NonExist:$NonExist }
        'Restore' { Invoke-RestoreAction -Scope $Scope -BackupFile $BackupFile -Format $Format }
    }
}
catch {
    Write-Error "処理に失敗しました: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
