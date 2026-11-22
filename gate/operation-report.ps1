#requires -Version 5.1
# Журнал операций гейта.

function Read-PublishConfig {
    # config.psd1 и config.site.psd1 - как в run.ps1: ключа нет в config.psd1 или он там пустой - из config.site.psd1.
    param([string]$Path)
    $read = Import-PowerShellDataFile -LiteralPath $Path
    $sitePath = Join-Path $PSScriptRoot 'config.site.psd1'
    if (Test-Path -LiteralPath $sitePath) {
        $site = Import-PowerShellDataFile -LiteralPath $sitePath
        foreach ($siteKey in @($site.Keys)) {
            $ownEmpty = $false
            if ($read.ContainsKey($siteKey)) {
                $own = $read[$siteKey]
                $ownEmpty = ($null -eq $own) -or (($own -is [array]) -and @($own).Count -eq 0) -or (($own -is [string]) -and $own -eq '')
            }
            if (-not $read.ContainsKey($siteKey) -or $ownEmpty) { $read[$siteKey] = $site[$siteKey] }
        }
    }
    return $read
}

function Get-PublishSetting {
    param([hashtable]$Settings, [string]$Key, $Default)
    if ($Settings.ContainsKey($Key) -and $null -ne $Settings[$Key] -and [string]$Settings[$Key] -ne '') { return $Settings[$Key] }
    return $Default
}

function Read-PublishSecretFile {
    # Пароль из файла DPAPI; не читается - пусто (секрет, которого гейт сам не прочтёт, в журнал не попадёт).
    param([string]$PassFile)
    $path = $PassFile
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $PSScriptRoot $path }
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $encrypted = [string](Get-Content -LiteralPath $path -Raw)
        if (-not $encrypted.Trim()) { return '' }
        $credential = New-Object System.Management.Automation.PSCredential('secret', (ConvertTo-SecureString -String $encrypted.Trim()))
        return $credential.GetNetworkCredential().Password
    }
    catch { return '' }
}

function Get-PublishSecrets {
    # Чего не должно быть в выложенных файлах: токен GitHub, пароли из файлов *PassFile (и у пользователей вроде
    # CanaryUsers - PassFile в таблице), код разрешения входа UnlockCode. Name - имя настройки, значение не выводится.
    param([hashtable]$Settings, [string]$Token)
    $found = New-Object System.Collections.Generic.List[object]
    if ($Token) { $found.Add([pscustomobject]@{ Name = 'GitHubTokenPassFile'; Value = $Token }) }
    foreach ($key in @($Settings.Keys | Sort-Object)) {
        $value = $Settings[$key]
        if ($key -like '*PassFile' -and $value -is [string] -and $value) {
            $found.Add([pscustomobject]@{ Name = $key; Value = (Read-PublishSecretFile $value) })
        }
        foreach ($item in @($value)) {
            if ($item -is [hashtable] -and $item.ContainsKey('PassFile') -and [string]$item['PassFile']) {
                $found.Add([pscustomobject]@{ Name = ('{0}.PassFile' -f $key); Value = (Read-PublishSecretFile ([string]$item['PassFile'])) })
            }
        }
    }
    $unlock = [string](Get-PublishSetting $Settings 'UnlockCode' '')
    if ($unlock) { $found.Add([pscustomobject]@{ Name = 'UnlockCode'; Value = $unlock }) }
    $long = New-Object System.Collections.Generic.List[object]
    # Короткий числовой код (например, «0») закрывается в реквизитах соединения; иначе исчезнут счётчики и версии.
    foreach ($item in @($found | Sort-Object { ([string]$_.Value).Length } -Descending)) {
        if ($item.Value -and -not ($item.Name -eq 'UnlockCode' -and $item.Value -eq '0')) { $long.Add($item) }
    }
    # Запятая - чтобы пустой список или список из одного не развернулся при возврате.
    return , $long
}

function Protect-GateReportText {
    # Командная строка 1С, строка соединения и заголовок HTTP могут содержать и незнакомые гейту значения.
    param([string]$Text, $Secrets = @(), [string[]]$LiteralValues = @())
    $safe = [regex]::Replace($Text, '(?i)(/(?:UC|P)\s*)"[^"\r\n]*"', '$1"***"')
    $safe = [regex]::Replace($safe, '(?i)(\b(?:Pwd|Password|UC|UnlockCode)\s*=\s*)(?:"(?:[^"\r\n]|"")*"|[^;\s]+)', '$1"***"')
    $safe = [regex]::Replace($safe, '(?i)(\bAuthorization\s*:\s*(?:Bearer|Basic)\s+)\S+', '$1***')
    $safe = [regex]::Replace($safe, '(?i)([?&](?:access_token|token|password)=)[^&\s]+', '$1***')
    $safe = [regex]::Replace($safe, '(?i)(/(?:UC|P)\s+)(?![/\-"*])[^\s;]+', '$1***')
    $safe = [regex]::Replace($safe, '(?i)(/UC)(?![\s"*])[^\s;]+', '$1***')
    $safe = [regex]::Replace($safe, '(?i)(код разрешения(?: входа)?\s*[:=]\s*)0(?=\W|$)', '$1***')
    foreach ($value in $LiteralValues) { if ($value) { $safe = $safe.Replace($value, '***') } }
    foreach ($secret in $Secrets) {
        $safe = $safe.Replace([string]$secret.Value, '***')
    }
    return $safe
}

function Save-GateReportJson {
    # Состояние меняется целиком: при обрыве остаётся предыдущая либо следующая версия.
    param([string]$Path, $Value)
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Value -Depth 8 -Compress), [Text.UTF8Encoding]::new($true))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($tmp, $Path) }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

function New-GateLaunchMetadata {
    param([string]$Operation)
    $version = ('Версия 00000000.000000.' -split ' ')[1].TrimEnd('.')
    return [ordered]@{ operation = $Operation; started = [datetime]::UtcNow.ToString('o'); user = [Environment]::UserName; gateVersion = $version }
}

function Get-GateReportRoot {
    param([hashtable]$Settings)
    $path = [string](Get-PublishSetting $Settings 'RunsDir' 'runs')
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $PSScriptRoot $path }
    return $path
}

function Start-GateOperation {
    param([string]$Operation, [string]$Config = '', $Launch = $null)
    try {
        if (-not $Config) { $Config = Join-Path $PSScriptRoot 'config.psd1' }
        elseif (-not [IO.Path]::IsPathRooted($Config)) { $Config = Join-Path $PSScriptRoot $Config }
        if (-not [IO.File]::Exists($Config)) { return }
        $settings = Read-PublishConfig $Config
        $repo = [string](Get-PublishSetting $settings 'RunReportRepo' '')
        if (-not $repo) { return }
        # Досылаем из того же профиля. Ошибка старого отчёта не мешает завести новый.
        try { & (Join-Path $PSScriptRoot 'publish.ps1') -Pending -Config $Config } catch { Write-Warning 'Не удалось проверить очередь отчётов.' }
        if ($null -eq $Launch) { $Launch = New-GateLaunchMetadata $Operation }
        $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
        $dir = Join-Path (Join-Path (Get-GateReportRoot $settings) 'operations') $id
        [void][IO.Directory]::CreateDirectory($dir)
        $pidStamp = '{0}|{1}' -f $PID, (Get-Process -Id $PID).StartTime.ToString('o')
        [IO.File]::WriteAllText((Join-Path $dir 'pid.txt'), $pidStamp)
        $secrets = Get-PublishSecrets -Settings $settings -Token ''
        $Launch['repo'] = $repo
        Save-GateReportJson (Join-Path $dir 'operation.json') $Launch
        $publisher = $null
        if ($Operation -eq 'update-gate') {
            # Установщик может заменить publish.ps1 более ранней версией до записи итога.
            $publisher = (Get-Command (Join-Path $PSScriptRoot 'publish.ps1')).ScriptBlock
        }
        return [pscustomobject]@{ Publisher = $publisher; Dir = $dir; Config = $Config; Launch = $Launch; Secrets = $secrets; Done = $false }
    } catch { Write-Warning 'Не удалось открыть журнал операции для отправки в GitHub.' }
}

function Add-GateOperationLine {
    param($Context, [string]$Text)
    if ($null -eq $Context -or $Context.Done -or -not $Text) { return }
    try {
        $safe = Protect-GateReportText $Text $Context.Secrets
        [IO.File]::AppendAllText((Join-Path $Context.Dir 'summary.txt'), $safe + [Environment]::NewLine, [Text.UTF8Encoding]::new($true))
    } catch { Write-Warning 'Не удалось дополнить журнал операции для GitHub.' }
}

function Move-GateOperationToRun {
    # Продолжение стало обычным прогоном. При обрыве между записями -Pending проверит обе стороны ссылки.
    param($Context, [string]$RunDir)
    if ($null -eq $Context) { return }
    try {
        $id = Split-Path -Leaf $RunDir
        if ($id -notmatch '^\d{8}-\d{6}$') { throw 'не тот идентификатор прогона' }
        $Context.Launch['origin'] = Split-Path -Leaf $Context.Dir
        Save-GateReportJson (Join-Path $Context.Dir 'forward.json') @{ run = $id }
        Save-GateReportJson (Join-Path $RunDir 'run-launch.json') $Context.Launch
        $Context.Done = $true
    } catch { Write-Warning 'Не удалось привязать отчёт о продолжении к папке прогона.' }
}

function Complete-GateOperation {
    param($Context, [string]$Outcome, [string]$Text = '')
    if ($null -eq $Context -or $Context.Done) { return }
    try {
        Add-GateOperationLine $Context $Text
        Save-GateReportJson (Join-Path $Context.Dir 'result.json') @{ outcome = $Outcome; ended = [datetime]::UtcNow.ToString('o') }
        $Context.Done = $true
        if ($null -ne $Context.Publisher) { & $Context.Publisher -OperationDir $Context.Dir -Config $Context.Config -OperationHelpersLoaded }
        else { & (Join-Path $PSScriptRoot 'publish.ps1') -OperationDir $Context.Dir -Config $Context.Config }
    } catch { Write-Warning 'Итог операции не отправлен. Очередь будет проверена при следующем запуске.' }
}
