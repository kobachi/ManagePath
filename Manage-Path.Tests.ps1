# Pester 3/4 構文。実行: Invoke-Pester .\Manage-Path.Tests.ps1 (管理者権限は不要。レジストリ書き込みはモックする)
$scriptPath = Join-Path $PSScriptRoot 'Manage-Path.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

# param ブロック、-Force の設定 (if)、末尾のディスパッチ (try) を除いた定義部だけを読み込む
$defs = $ast.EndBlock.Statements | Where-Object {
    $_ -isnot [System.Management.Automation.Language.TryStatementAst] -and
    $_ -isnot [System.Management.Automation.Language.IfStatementAst]
}
. ([scriptblock]::Create(($defs | ForEach-Object { $_.Extent.Text }) -join "`n"))

# 関数を直接呼ぶテストで確認プロンプトが出ないようにする (ConfirmImpact 自体は下のテストで検証)
$ConfirmPreference = 'None'

Describe 'ConfirmImpact' {
    foreach ($name in 'Invoke-RemoveAction', 'Invoke-CleanAction', 'Invoke-RestoreAction') {
        It "$name は既定で確認を求める (ConfirmImpact = High)" {
            $attr = (Get-Command $name).ScriptBlock.Attributes |
                Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
            $attr.ConfirmImpact | Should Be 'High'
        }
    }

    It 'スクリプトに -Force パラメーターがあり、確認スキップの処理がある' {
        $ast.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'Force' | Should Be $true
        (Get-Content -LiteralPath $scriptPath -Raw).Contains('$ConfirmPreference = ''None''') | Should Be $true
    }
}

Describe 'Scope と Format の既定値' {
    It 'スクリプト入口は User / Table を既定値にする' {
        $scope = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Scope' }
        $format = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Format' }
        $scope.DefaultValue.Value | Should Be 'User'
        $format.DefaultValue.Value | Should Be 'Table'
    }

    foreach ($name in 'Invoke-ListAction', 'Invoke-AddAction', 'Invoke-RemoveAction', 'Invoke-CleanAction', 'Invoke-RestoreAction') {
        It "$name は User / Table を既定値にする" {
            $function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
            $parameters = $function.Body.ParamBlock.Parameters
            $scope = $parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Scope' }
            $format = $parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Format' }
            $scope.DefaultValue.Value | Should Be 'User'
            $format.DefaultValue.Value | Should Be 'Table'
        }
    }
}

Describe 'Get-ComparablePath' {
    It '末尾の \ と引用符を除去する' {
        Get-ComparablePath -Path '"C:\Tools\bin\"' | Should Be 'C:\Tools\bin'
    }
    It '環境変数を展開する' {
        $env:MP_TEST_DIR = 'C:\Java'
        Get-ComparablePath -Path '%MP_TEST_DIR%\bin' | Should Be 'C:\Java\bin'
        Remove-Item Env:\MP_TEST_DIR
    }
}

Describe 'ConvertTo-PathEntries' {
    It '空要素を無視し Exists を判定する' {
        $e = @(ConvertTo-PathEntries -Scope User -RawValue ";$env:SystemRoot;;C:\no\such\dir_mp;")
        $e.Count | Should Be 2
        $e[0].Exists | Should Be $true
        $e[1].Exists | Should Be $false
        $e[1].Index | Should Be 1
    }
}

Describe 'Invoke-CleanAction' {
    $existing = Join-Path $env:TEMP 'mp_test_existing'
    New-Item -ItemType Directory -Path $existing -Force | Out-Null
    $missing = Join-Path $env:TEMP 'mp_test_missing_dir'

    function Set-FakePath([string]$User, [string]$Machine) {
        $script:fake = @{ User = $User; Machine = $Machine }
    }

    Mock Get-RawPathValue {
        [pscustomobject]@{ Scope = $Scope; Value = $script:fake[$Scope]; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    }
    Mock Set-RawPathValue { }
    Mock Export-PathBackup { 'dummy.json' }
    Mock Send-EnvironmentChangeNotification { }
    Mock Invoke-ListAction { }
    Mock Write-Host { }

    It 'フラグ未指定はエラー' {
        { Invoke-CleanAction -Scope User -Format Table } | Should Throw
    }

    It '-Duplicate: 変数を含む表記があれば、先頭でなくてもそれを残して他を削除する' {
        $env:MP_TEST_DIR = $existing
        Set-FakePath -User "$existing;%MP_TEST_DIR%;$($existing.ToUpper())\;C:\Other" -Machine ''
        Invoke-CleanAction -Scope User -Format Table -Duplicate
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'User' -and $Value -eq '%MP_TEST_DIR%;C:\Other'
        }
        Remove-Item Env:\MP_TEST_DIR
    }

    It '-Duplicate: 変数を含む表記が複数あればその先頭を残す' {
        $env:MP_TEST_DIR = $existing
        $env:MP_TEST_DIR2 = $existing
        Set-FakePath -User "%MP_TEST_DIR2%;$existing;%MP_TEST_DIR%" -Machine ''
        Invoke-CleanAction -Scope User -Format Table -Duplicate
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq '%MP_TEST_DIR2%' }
        Remove-Item Env:\MP_TEST_DIR, Env:\MP_TEST_DIR2
    }

    It '-Duplicate: 変数を含む表記が -NonExist で削除される場合はリテラルを残す' {
        Set-FakePath -User "$existing;%MP_UNDEFINED_VAR_XYZ%" -Machine ''
        Invoke-CleanAction -Scope User -Format Table -Duplicate -NonExist
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'User' -and $Value -eq $existing
        }
    }

    It '-Scope User -Duplicate: Machine にある項目を User 側から削除し Machine は変更しない' {
        Set-FakePath -User "$existing;C:\OnlyUser" -Machine "C:\Windows;$existing"
        Invoke-CleanAction -Scope User -Format Table -Duplicate
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'User' -and $Value -eq 'C:\OnlyUser'
        }
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It -ParameterFilter { $Scope -eq 'Machine' }
    }

    It '-Scope All -Duplicate: Machine にある項目を User 側から削除し、Machine は変更しない' {
        Set-FakePath -User "$existing;C:\OnlyUser" -Machine "$existing"
        Invoke-CleanAction -Scope All -Format Table -Duplicate
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'User' -and $Value -eq 'C:\OnlyUser'
        }
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It -ParameterFilter { $Scope -eq 'Machine' }
    }

    It '-Scope All -Duplicate: Machine 内の重複を整理した後の内容と User を比較する (Machine を先に処理)' {
        $script:order = @()
        Mock Set-RawPathValue { $script:order += $Scope; $script:written = $Value }
        Set-FakePath -User "$existing" -Machine "$existing;$existing"
        Invoke-CleanAction -Scope All -Format Table -Duplicate
        ($script:order -join ',') | Should Be 'Machine,User'
    }

    It '-NonExist: 存在しないディレクトリと未定義変数を削除する' {
        Set-FakePath -User "$existing;$missing;%MP_UNDEFINED_VAR_XYZ%\bin" -Machine ''
        Invoke-CleanAction -Scope User -Format Table -NonExist
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'User' -and $Value -eq $existing
        }
    }

    It '-NonExist: UNC・相対パス・存在しないドライブは判定不能として残す' {
        $unused = [char[]]'ZYXWVUTSRQ' | Where-Object { -not (Test-Path "$($_):\") } | Select-Object -First 1
        Set-FakePath -User "\\no-such-host-mp\share;.\relative;$($unused):\tools;$missing" -Machine ''
        Invoke-CleanAction -Scope User -Format Table -NonExist -WarningAction SilentlyContinue
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'User' -and $Value -eq "\\no-such-host-mp\share;.\relative;$($unused):\tools"
        }
    }

    It '-NonExist のみでは重複を削除しない' {
        Set-FakePath -User "$existing;$existing" -Machine ''
        Invoke-CleanAction -Scope User -Format Table -NonExist
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
    }

    It '削除対象なしなら書き込まない' {
        Set-FakePath -User "$existing" -Machine ''
        Invoke-CleanAction -Scope User -Format Table -Duplicate -NonExist
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
    }

    It '-WhatIf では書き込まずバックアップも作らない' {
        Set-FakePath -User "$existing;$existing" -Machine ''
        Invoke-CleanAction -Scope User -Format Table -Duplicate -WhatIf
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
        Assert-MockCalled Export-PathBackup -Exactly 0 -Scope It
    }

    Remove-Item $existing -Force -Recurse
}

Describe 'Get-DirectoryStatus' {
    It '存在するディレクトリは Exists' {
        Get-DirectoryStatus -Path $env:SystemRoot | Should Be 'Exists'
    }
    It '固定ドライブ上の存在しないパスは Missing' {
        Get-DirectoryStatus -Path (Join-Path $env:SystemRoot 'mp_no_such_dir') | Should Be 'Missing'
    }
    It 'UNC は Unknown' {
        Get-DirectoryStatus -Path '\\no-such-host-mp\share' | Should Be 'Unknown'
    }
    It '相対パスは Unknown' {
        Get-DirectoryStatus -Path '.\relative' | Should Be 'Unknown'
    }
    It '不正な文字を含むパスは Unknown' {
        Get-DirectoryStatus -Path 'C:\a|b' | Should Be 'Unknown'
    }
}

Describe 'Test-BackupFileTrusted' {
    It '一般ユーザーが書き込める TEMP 上のファイルは信頼しない' {
        $f = Join-Path $env:TEMP 'mp_untrusted.json'
        Set-Content -LiteralPath $f -Value '{}'
        Test-BackupFileTrusted -File $f | Should Be $false
        Remove-Item $f -Force
    }
}

Describe 'Invoke-RestoreAction' {
    $bdir = Join-Path $env:TEMP 'mp_test_backup'
    New-Item -ItemType Directory -Path $bdir -Force | Out-Null

    function New-FakeBackup([string]$Name, [string]$Scope, [string]$Value, [string]$Kind = 'ExpandString') {
        $f = Join-Path $bdir $Name
        [pscustomobject]@{ Scope = $Scope; Date = 'x'; User = 'u'; Kind = $Kind; Value = $Value } |
            ConvertTo-Json | Set-Content -LiteralPath $f -Encoding UTF8
        $f
    }

    Mock Get-BackupDirectory { $bdir }
    Mock Test-BackupFileTrusted { $true }
    Mock Get-RawPathValue { [pscustomobject]@{ Scope = $Scope; Value = 'C:\Current'; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString } }
    Mock Set-RawPathValue { }
    Mock Export-PathBackup { 'dummy.json' }
    Mock Send-EnvironmentChangeNotification { }
    Mock Invoke-ListAction { }
    Mock Write-Host { }

    $null = New-FakeBackup '20260101-000000-User.json' 'User' 'C:\Old1'
    $null = New-FakeBackup '20260102-000000-User.json' 'User' '%SystemRoot%;C:\Old2'
    $null = New-FakeBackup '20260103-000000-Machine.json' 'User' 'C:\Wrong'
    $null = New-FakeBackup '20260104-000000-Machine.json' 'Machine' 'C:\M' 'Binary'

    It '指定したファイルから復元し、復元前の値もバックアップする' {
        Invoke-RestoreAction -Scope User -BackupFile '20260101-000000-User.json' -Format Table
        Assert-MockCalled Export-PathBackup -Exactly 1 -Scope It
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'User' -and $Value -eq 'C:\Old1'
        }
    }

    It '省略時はスコープの最新を使う' {
        Invoke-RestoreAction -Scope User -Format Table
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq '%SystemRoot%;C:\Old2' }
    }

    It 'Scope 不一致はエラー' {
        { Invoke-RestoreAction -Scope Machine -BackupFile '20260103-000000-Machine.json' -Format Table } | Should Throw
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
    }

    It 'Kind が不正ならエラー' {
        { Invoke-RestoreAction -Scope Machine -BackupFile '20260104-000000-Machine.json' -Format Table } | Should Throw
    }

    It 'バックアップフォルダー外のファイルはエラー' {
        $out = Join-Path $env:TEMP 'mp_outside.json'
        '{}' | Set-Content -LiteralPath $out
        { Invoke-RestoreAction -Scope User -BackupFile $out -Format Table } | Should Throw
        Remove-Item $out -Force
    }

    It 'ACL が信頼できないファイルはエラー' {
        Mock Test-BackupFileTrusted { $false }
        { Invoke-RestoreAction -Scope User -Format Table } | Should Throw
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
    }

    It 'Scope All はエラー' {
        { Invoke-RestoreAction -Scope All -Format Table } | Should Throw
    }

    It '-WhatIf では書き込まない' {
        Mock Test-BackupFileTrusted { $true }
        Invoke-RestoreAction -Scope User -Format Table -WhatIf
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
        Assert-MockCalled Export-PathBackup -Exactly 0 -Scope It
    }

    Remove-Item $bdir -Force -Recurse
}

Describe 'Invoke-AddAction' {
    function Set-FakePath([string]$Value) { $script:fake = $Value }

    Mock Get-RawPathValue {
        [pscustomobject]@{ Scope = $Scope; Value = $script:fake; Kind = [Microsoft.Win32.RegistryValueKind]::String }
    }
    Mock Set-RawPathValue { }
    Mock Export-PathBackup { 'dummy.json' }
    Mock Send-EnvironmentChangeNotification { }
    Mock Invoke-ListAction { }
    Mock Write-Host { }

    It '既定 (Append) で末尾に追加し、元の Kind を渡す' {
        Set-FakePath 'C:\A;C:\B'
        Invoke-AddAction -Scope User -Path 'C:\New' -Position Append -Format Table -WarningAction SilentlyContinue
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'User' -and $Value -eq 'C:\A;C:\B;C:\New' -and $Kind -eq 'String'
        }
        Assert-MockCalled Export-PathBackup -Exactly 1 -Scope It
    }

    It 'Prepend で先頭に追加する' {
        Set-FakePath 'C:\A;C:\B'
        Invoke-AddAction -Scope Machine -Path 'C:\New' -Position Prepend -Format Table -WarningAction SilentlyContinue
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'Machine' -and $Value -eq 'C:\New;C:\A;C:\B'
        }
    }

    It '空のパスにも追加できる' {
        Set-FakePath ''
        Invoke-AddAction -Scope User -Path 'C:\New' -Position Append -Format Table -WarningAction SilentlyContinue
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq 'C:\New' }
    }

    It '%VAR% は展開せずそのまま保存する' {
        Set-FakePath 'C:\A'
        Invoke-AddAction -Scope User -Path '%SystemRoot%\Tools' -Position Append -Format Table -WarningAction SilentlyContinue
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq 'C:\A;%SystemRoot%\Tools' }
    }

    It '前後の空白と引用符は取り除いて保存する' {
        Set-FakePath 'C:\A'
        Invoke-AddAction -Scope User -Path '  "C:\Quoted"  ' -Position Append -Format Table -WarningAction SilentlyContinue
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq 'C:\A;C:\Quoted' }
    }

    It '存在しないディレクトリは警告のみで追加する' {
        Set-FakePath 'C:\A'
        Invoke-AddAction -Scope User -Path 'C:\no\such\dir_mp' -Position Append -Format Table -WarningVariable w -WarningAction SilentlyContinue
        @($w).Count | Should BeGreaterThan 0
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq 'C:\A;C:\no\such\dir_mp' }
    }

    It '重複 (大文字小文字・末尾 \ 違い) は警告して書き込まない' {
        Set-FakePath 'C:\Tools\Bin'
        Invoke-AddAction -Scope User -Path 'c:\tools\bin\' -Position Append -Format Table -WarningVariable w -WarningAction SilentlyContinue
        @($w).Count | Should Be 1
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
    }

    It '重複 (展開後に同じパス) は書き込まない' {
        $env:MP_TEST_DIR = 'C:\Java'
        Set-FakePath 'C:\Java\bin'
        Invoke-AddAction -Scope User -Path '%MP_TEST_DIR%\bin' -Position Append -Format Table -WarningAction SilentlyContinue
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
        Remove-Item Env:\MP_TEST_DIR
    }

    It '未定義の環境変数を含む場合はエラー' {
        Set-FakePath 'C:\A'
        { Invoke-AddAction -Scope User -Path '%MP_UNDEFINED_VAR_XYZ%\bin' -Position Append -Format Table } | Should Throw
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
    }

    It '不正な入力 (空 / ; を含む / % 不整合) はエラー' {
        Set-FakePath 'C:\A'
        { Invoke-AddAction -Scope User -Path '   ' -Position Append -Format Table } | Should Throw
        { Invoke-AddAction -Scope User -Path 'C:\a;C:\b' -Position Append -Format Table } | Should Throw
        { Invoke-AddAction -Scope User -Path 'C:\50%off' -Position Append -Format Table } | Should Throw
        { Invoke-AddAction -Scope User -Path 'C:\Tools\*' -Position Append -Format Table } | Should Throw
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
    }

    It 'Scope All はエラー' {
        { Invoke-AddAction -Scope All -Path 'C:\New' -Position Append -Format Table } | Should Throw
    }

    It '-WhatIf では書き込まずバックアップも作らない' {
        Set-FakePath 'C:\A'
        Invoke-AddAction -Scope User -Path 'C:\New' -Position Append -Format Table -WhatIf -WarningAction SilentlyContinue
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
        Assert-MockCalled Export-PathBackup -Exactly 0 -Scope It
    }
}

Describe 'Invoke-RemoveAction' {
    function Set-FakePath([string]$Value) { $script:fake = $Value }

    Mock Get-RawPathValue {
        [pscustomobject]@{ Scope = $Scope; Value = $script:fake; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    }
    Mock Set-RawPathValue { }
    Mock Export-PathBackup { 'dummy.json' }
    Mock Send-EnvironmentChangeNotification { }
    Mock Invoke-ListAction { }
    Mock Write-Host { }

    It '同じ表記のエントリを削除する (大文字小文字・末尾 \ は無視)' {
        Set-FakePath 'C:\A;C:\Tools\Bin;C:\B'
        Invoke-RemoveAction -Scope User -Path 'c:\tools\bin\' -Format Table
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'User' -and $Value -eq 'C:\A;C:\B' -and $Kind -eq 'ExpandString'
        }
        Assert-MockCalled Export-PathBackup -Exactly 1 -Scope It
    }

    It '引用符付きのエントリも削除する' {
        Set-FakePath 'C:\A;"C:\Quoted"'
        Invoke-RemoveAction -Scope User -Path 'C:\Quoted' -Format Table
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq 'C:\A' }
    }

    It '-Path が %VAR% のとき、展開後に一致するエントリも削除する' {
        $env:MP_TEST_DIR = 'C:\Java'
        Set-FakePath 'C:\Java\bin;C:\Other;%MP_TEST_DIR%\bin'
        Invoke-RemoveAction -Scope User -Path '%MP_TEST_DIR%\bin' -Format Table
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq 'C:\Other' }
        Remove-Item Env:\MP_TEST_DIR
    }

    It '-Path が展開済みパスのとき、%VAR% 表記のエントリも削除する' {
        $env:MP_TEST_DIR = 'C:\Java'
        Set-FakePath '%MP_TEST_DIR%\bin;C:\Other'
        Invoke-RemoveAction -Scope User -Path 'C:\Java\bin' -Format Table
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq 'C:\Other' }
        Remove-Item Env:\MP_TEST_DIR
    }

    It '未定義の環境変数を含む -Path でも、表記一致のエントリを削除できる' {
        Set-FakePath '%MP_UNDEFINED_VAR_XYZ%\bin;C:\Keep'
        Invoke-RemoveAction -Scope User -Path '%MP_UNDEFINED_VAR_XYZ%\bin' -Format Table
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq 'C:\Keep' }
    }

    It '該当なしは警告して書き込まない' {
        Set-FakePath 'C:\A;C:\B'
        Invoke-RemoveAction -Scope User -Path 'C:\None' -Format Table -WarningVariable w -WarningAction SilentlyContinue
        @($w).Count | Should Be 1
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
        Assert-MockCalled Export-PathBackup -Exactly 0 -Scope It
    }

    It '部分一致のエントリは削除しない' {
        Set-FakePath 'C:\Tools\bin2;C:\Tools'
        Invoke-RemoveAction -Scope User -Path 'C:\Tools\bin' -Format Table -WarningAction SilentlyContinue
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
    }

    It '* で一致する複数のエントリを削除し、似た別パスは残す' {
        Set-FakePath 'C:\A;C:\Tools\bin;C:\Tools\SDK;C:\Toolshed;C:\B'
        Invoke-RemoveAction -Scope User -Path 'C:\Tools\*' -Format Table
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'User' -and $Value -eq 'C:\A;C:\Toolshed;C:\B'
        }
    }

    It '* 以外のワイルドカード記号は文字どおり扱う' {
        Set-FakePath 'C:\Tools\a1;C:\Tools\[ab]1'
        Invoke-RemoveAction -Scope User -Path 'C:\Tools\[ab]*' -Format Table
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Value -eq 'C:\Tools\a1'
        }
    }

    It '最後の 1 件を削除すると空文字列を書き込む' {
        Set-FakePath 'C:\Only'
        Invoke-RemoveAction -Scope Machine -Path 'C:\Only' -Format Table
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'Machine' -and $Value -eq ''
        }
    }

    It '不正な入力 (空 / ; を含む) はエラー' {
        Set-FakePath 'C:\A'
        { Invoke-RemoveAction -Scope User -Path '' -Format Table } | Should Throw
        { Invoke-RemoveAction -Scope User -Path 'C:\a;C:\b' -Format Table } | Should Throw
    }

    It 'Scope All はエラー' {
        { Invoke-RemoveAction -Scope All -Path 'C:\A' -Format Table } | Should Throw
    }

    It '-WhatIf では書き込まずバックアップも作らない' {
        Set-FakePath 'C:\A;C:\B'
        Invoke-RemoveAction -Scope User -Path 'C:\A' -Format Table -WhatIf
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
        Assert-MockCalled Export-PathBackup -Exactly 0 -Scope It
    }
}

Describe 'Get-ComparablePath (正規化)' {
    It "'.' と '..' を解消する" {
        Get-ComparablePath -Path 'C:\Tools\.\x\..\bin' | Should Be 'C:\Tools\bin'
    }
    It "'/' 区切りを '\' に統一する" {
        Get-ComparablePath -Path 'C:/Tools/bin/' | Should Be 'C:\Tools\bin'
    }
    It 'ドライブルートの末尾 \ は残す' {
        Get-ComparablePath -Path 'C:\' | Should Be 'C:\'
        Get-ComparablePath -Path 'C:\.\' | Should Be 'C:\'
    }
    It 'UNC の末尾 \ を除去し、. / .. を解消する' {
        Get-ComparablePath -Path '\\host\share\a\..\b\' | Should Be '\\host\share\b'
    }
    It '相対パスと未定義変数を含むパスはカレントに依存させない' {
        Get-ComparablePath -Path '.\a\..\b' | Should Be '.\a\..\b'
        Get-ComparablePath -Path '%MP_UNDEFINED_VAR_XYZ%\a\..\b' | Should Be '%MP_UNDEFINED_VAR_XYZ%\a\..\b'
    }
    It '不正な文字を含むパスでも例外にならない' {
        { Get-ComparablePath -Path 'C:\a|b\..\c' } | Should Not Throw
    }
    It '8.3 短縮名を長い名前と同一視する (短縮名が有効な環境のみ)' {
        $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($env:ProgramFiles).ShortPath
        if ($short.Contains('~')) {
            Get-ComparablePath -Path $short | Should Be (Get-ComparablePath -Path $env:ProgramFiles)
        }
    }
    It '存在しない短縮名風のパスは変更しない' {
        Get-ComparablePath -Path 'C:\NOSUCH~1\bin' | Should Be 'C:\NOSUCH~1\bin'
    }
    It 'Add の重複判定で .. を含む表記を同一と見なす' {
        $env:MP_TEST_DIR = 'C:\Java'
        $script:fake = 'C:\Java\bin'
        Mock Get-RawPathValue { [pscustomobject]@{ Scope = $Scope; Value = $script:fake; Kind = [Microsoft.Win32.RegistryValueKind]::String } }
        Mock Set-RawPathValue { }
        Mock Export-PathBackup { 'dummy.json' }
        Mock Send-EnvironmentChangeNotification { }
        Mock Invoke-ListAction { }
        Mock Write-Host { }
        Invoke-AddAction -Scope User -Path 'C:\Java\lib\..\bin' -Position Append -Format Table -WarningAction SilentlyContinue
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
        Remove-Item Env:\MP_TEST_DIR
    }
}

Describe 'Invoke-CleanAction (変数の参照可否)' {
    $existing = Join-Path $env:TEMP 'mp_test_existing2'
    New-Item -ItemType Directory -Path $existing -Force | Out-Null

    function Set-FakePath([string]$User, [string]$Machine) {
        $script:fake = @{ User = $User; Machine = $Machine }
    }

    Mock Get-RawPathValue {
        [pscustomobject]@{ Scope = $Scope; Value = $script:fake[$Scope]; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    }
    Mock Set-RawPathValue { }
    Mock Export-PathBackup { 'dummy.json' }
    Mock Send-EnvironmentChangeNotification { }
    Mock Invoke-ListAction { }
    Mock Write-Host { }

    It '-Duplicate: システムパスではユーザー専用変数を展開しない (リテラルと同一視しない)' {
        Mock Test-EnvironmentVariableDefined { $Scope -eq 'User' }
        $env:MP_TEST_DIR = $existing
        Set-FakePath -User '' -Machine "%MP_TEST_DIR%;$existing"
        Invoke-CleanAction -Scope Machine -Format Table -Duplicate
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It
        Remove-Item Env:\MP_TEST_DIR
    }

    It '-Duplicate: ユーザーパスでは同じ変数を展開して同一視する' {
        Mock Test-EnvironmentVariableDefined { $true }
        $env:MP_TEST_DIR = $existing
        Set-FakePath -User "$existing;%MP_TEST_DIR%" -Machine ''
        Invoke-CleanAction -Scope User -Format Table -Duplicate
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq '%MP_TEST_DIR%' }
        Remove-Item Env:\MP_TEST_DIR
    }

    It '-Scope All -Duplicate -NonExist: Machine 側で削除される項目とは重複扱いにせず User 側を残す' {
        Mock Test-EnvironmentVariableDefined { $Scope -eq 'User' }
        $env:MP_TEST_DIR = $existing
        Set-FakePath -User '%MP_TEST_DIR%' -Machine '%MP_TEST_DIR%'
        Invoke-CleanAction -Scope All -Format Table -Duplicate -NonExist
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter {
            $Scope -eq 'Machine' -and $Value -eq ''
        }
        Assert-MockCalled Set-RawPathValue -Exactly 0 -Scope It -ParameterFilter { $Scope -eq 'User' }
        Remove-Item Env:\MP_TEST_DIR
    }

    Remove-Item $existing -Force -Recurse
}

Describe 'Get-ReferencedVariableNames' {
    It '参照している変数名を重複なしで返す' {
        $n = @(Get-ReferencedVariableNames -Path '%A%\x\%B%\%a%')
        $n.Count | Should Be 2
        $n -contains 'A' | Should Be $true
        $n -contains 'B' | Should Be $true
    }
    It '変数を含まなければ空' {
        @(Get-ReferencedVariableNames -Path 'C:\Tools').Count | Should Be 0
    }
}

Describe 'Save-PathChange' {
    Mock Export-PathBackup { 'dummy.json' }
    Mock Set-RawPathValue { }
    Mock Send-EnvironmentChangeNotification { }
    Mock Invoke-ListAction { }
    Mock Write-Host { }

    $raw = [pscustomobject]@{ Scope = 'User'; Value = 'C:\A'; Kind = [Microsoft.Win32.RegistryValueKind]::String }

    It 'Kind 省略時は元の Kind で書き込み、バックアップ・通知・一覧表示を行う' {
        Save-PathChange -Scope User -Raw $raw -Value 'C:\B' -Format Table -Message 'm'
        Assert-MockCalled Export-PathBackup -Exactly 1 -Scope It
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Value -eq 'C:\B' -and $Kind -eq 'String' }
        Assert-MockCalled Send-EnvironmentChangeNotification -Exactly 1 -Scope It
        Assert-MockCalled Invoke-ListAction -Exactly 1 -Scope It
    }

    It 'Kind 指定時はその Kind で書き込む' {
        Save-PathChange -Scope User -Raw $raw -Value 'C:\B' -Format Table -Message 'm' -Kind ExpandString
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Kind -eq 'ExpandString' }
    }
}

Describe 'Invoke-CleanAction (結果出力とエラー処理)' {
    function Set-FakePath([string]$User, [string]$Machine) {
        $script:fake = @{ User = $User; Machine = $Machine }
    }

    Mock Get-RawPathValue {
        [pscustomobject]@{ Scope = $Scope; Value = $script:fake[$Scope]; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    }
    Mock Set-RawPathValue { }
    Mock Export-PathBackup { 'dummy.json' }
    Mock Send-EnvironmentChangeNotification { }
    Mock Invoke-ListAction { }
    Mock Write-Host { }

    It 'スコープごとの結果オブジェクトを返す (Changed / NoChange)' {
        Set-FakePath -User 'C:\A;C:\A' -Machine 'C:\M'
        $r = @(Invoke-CleanAction -Scope All -Format Table -Duplicate)
        $r.Count | Should Be 2
        $r[0].Scope | Should Be 'Machine'
        $r[0].Status | Should Be 'NoChange'
        $r[1].Scope | Should Be 'User'
        $r[1].Status | Should Be 'Changed'
        $r[1].RemovedCount | Should Be 1
        $r[1].Removed[0].Path | Should Be 'C:\A'
        $r[1].Backup | Should Be 'dummy.json'
    }

    It '-WhatIf では Skipped になり Backup は空' {
        Set-FakePath -User 'C:\A;C:\A' -Machine ''
        $r = @(Invoke-CleanAction -Scope User -Format Table -Duplicate -WhatIf)
        $r[0].Status | Should Be 'Skipped'
        $r[0].RemovedCount | Should Be 1
        $r[0].Backup | Should Be $null
    }

    It '片方のスコープが失敗しても残りを処理し、失敗と変更済みスコープを含むエラーを投げる' {
        Mock Set-RawPathValue { if ($Scope -eq 'Machine') { throw 'boom' } }
        Set-FakePath -User 'C:\A;C:\A' -Machine 'C:\M;C:\M'
        $msg = $null
        try { Invoke-CleanAction -Scope All -Format Table -Duplicate -WarningAction SilentlyContinue | Out-Null }
        catch { $msg = $_.Exception.Message }
        $msg | Should Match 'Machine \(boom\)'
        $msg | Should Match '変更済み: User'
        Assert-MockCalled Set-RawPathValue -Exactly 1 -Scope It -ParameterFilter { $Scope -eq 'User' }
    }
}
