#requires -Version 5.1
<#
.SYNOPSIS
    Обновление рабочей базы расширениями из тестовой.

.DESCRIPTION
    .\deploy.ps1
        Показать итог последнего прогона гейта и что из этого следует, сравнить расширения тестовой
        и рабочей базы и предложить обновить: все изменённые или выбранные.

    .\deploy.ps1 -StatusOnly
        Только показать итог гейта и сравнение, ничего не обновлять.

    .\deploy.ps1 -Rollback
        Откатить рабочую базу: список прошлых обновлений, подробности, откат к состоянию до выбранного
        (или сразу к состоянию до последнего) из резервных копий; потом можно подтянуть то же в temp.

    .\deploy.ps1 -PullExtensions / -PullProcessings
        Положить в inbox расширения (внешние обработки) рабочей базы, которые отличаются от temp.

    Внешние обработки и отчёты справочника «Дополнительные отчёты и обработки» сравниваются так же:
    изменённые и новые в temp можно обновить вместе с расширениями или отдельно («Обновить только
    внешние обработки»: без блокировок рабочей базы, без обновления конфигурации БД). Записывает их
    «Выполнить после обновления» в режиме regepf; прежняя версия сохраняется до записи - это откат.

    .\deploy.ps1 -NoDump
        Ничего не делает: сравнение теперь по хеш-суммам через внешнее соединение, без выгрузки.
        Ключ оставлен, чтобы старые ярлыки не ломались.

    Порядок обновления: проверка открытого конфигуратора и сеансов рабочей базы (как в гейте), блокировка
    регламентных заданий на время обновления, резервные копии расширений, загрузка новых версий
    из тестовой базы, обновление конфигурации БД, лёгкий прогон без записи в базу (канареечный вход,
    проверка применимости, самопроверка только на чтение), отчёт об изменениях в базу знаний.

.NOTES
    Версия 00000000.000000.
    На деле ещё не выполнялся.
#>
[CmdletBinding()]
param(
    [string]$Config = '',
    [switch]$StatusOnly,
    [switch]$NoDump,
    # Откат рабочей базы к состоянию до одного из прошлых обновлений.
    [switch]$Rollback,
    # Взять из рабочей в inbox расширения или внешние обработки, которые отличаются от temp.
    [switch]$PullExtensions,
    [switch]$PullProcessings,
    # Папка канала интерфейса ci.exe: его задаёт сам ci.exe (или run.ps1 из ci.exe), руками не нужен.
    [string]$UiChannel = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($UiChannel) {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    # Полосы Write-Progress PowerShell рисует прямо в консоли, поверх экрана ci.exe.
    $ProgressPreference = 'SilentlyContinue'
}

# Блокировки рабочей базы. С начала подготовки рабочей базы (после подтверждения) обе - регламентных заданий
# и начала сеансов - в конце обязательно снимаются, кто бы их ни поставил: при удачном обновлении, при сбое,
# при остановке и по Ctrl+C. Тестовую базу это не касается. Исключение - чужая блокировка сеансов с другим кодом:
# с ней скрипт останавливается до обновления и её не трогает.
$script:ProdLocksArmed = $false
$script:KeepForeignSessionLock = $false
$script:SessionLockCode = ''

trap {
    Write-Host ''
    Write-Host ("Остановлено: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ([string]$_.FullyQualifiedErrorId -ne [string]$_.Exception.Message -and $null -ne $_.InvocationInfo) {
        Write-Host ("  {0}" -f ($_.InvocationInfo.PositionMessage -split "`r?`n")[0]) -ForegroundColor DarkGray
    }
    if ($script:ProdLocksArmed) {
        try { Clear-ProdLocks } catch { Write-Host ("Блокировки снять не получилось: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
    }
    exit 1
}

$Root = $PSScriptRoot
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$TestBasePattern = 'temp|test|copy|tmp|dev|sandbox|stand|тест|копи|стенд|песочниц'
$SelfCheckLineRegex = New-Object System.Text.RegularExpressions.Regex('^\d\d:\d\d:\d\d \[(ОК|ОШИБКА|ВНИМАНИЕ|ПРОПУСК|ИНФО)\]\s*(.*)$')
$SelfCheckIndent = '                    '

#region Общие функции

function Resolve-RootPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $Root $Path)
}

function Get-Setting {
    param([hashtable]$Table, [string]$Key, $Default)
    if ($Table.ContainsKey($Key) -and $null -ne $Table[$Key]) { return $Table[$Key] }
    return $Default
}

function Write-RunLog {
    param([string]$Text)
    $stamp = Get-Date -Format 'HH:mm:ss'
    [System.IO.File]::AppendAllText($script:RunLogPath, ("{0} {1}`r`n" -f $stamp, $Text), $Utf8Bom)
}

function Write-Line {
    # Строка в консоль и в run.log.
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    Write-RunLog $Text
}

function Get-PlainPassword {
    param([string]$PassFile)
    if ([string]::IsNullOrWhiteSpace($PassFile)) { return '' }
    $path = Resolve-RootPath $PassFile
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Нет файла пароля: $path. Создай его: .\run.ps1 -SavePassword `"$PassFile`""
    }
    $encrypted = (Get-Content -LiteralPath $path -Raw).Trim()
    $secure = ConvertTo-SecureString -String $encrypted
    $credential = New-Object System.Management.Automation.PSCredential('user', $secure)
    return $credential.GetNetworkCredential().Password
}

function Get-ConnectionArgs {
    # Строка соединения с базой кластера. Код разрешения входа - если в базе стоит блокировка сеансов.
    param([string]$BaseName, [string]$User, [string]$Password)
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add(('/S"{0}\{1}"' -f $script:Server, $BaseName))
    if (-not [string]::IsNullOrEmpty($script:UnlockCode)) { $list.Add(('/UC"{0}"' -f $script:UnlockCode)) }
    if (-not [string]::IsNullOrEmpty($User)) {
        $list.Add(('/N"{0}"' -f $User))
        if (-not [string]::IsNullOrEmpty($Password)) { $list.Add(('/P"{0}"' -f $Password)) }
    }
    return $list.ToArray()
}

function Get-MaskedLine {
    param([string]$Line)
    return [regex]::Replace([regex]::Replace($Line, '/P"[^"]*"', '/P"***"'), '/UC"[^"]*"', '/UC"***"')
}

function Invoke-V8 {
    # Запускает 1С и ждёт завершения не дольше таймаута. По таймауту процесс снимается.
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec, [string]$Title = '')
    $argLine = $Arguments -join ' '
    Write-RunLog ("> {0} {1}" -f (Split-Path -Leaf $Exe), (Get-MaskedLine $argLine))
    if ($Title) {
        Write-Host ("  ...  {0}: начато в {1}, жду не дольше {2} мин" -f $Title, (Get-Date -Format 'HH:mm:ss'), [int]($TimeoutSec / 60)) -ForegroundColor DarkGray
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $Exe -ArgumentList $argLine -PassThru
    $null = $process.Handle
    # Строка хода (ui.ps1): полоса по прогнозу из статистики (stats.ps1) или бегающий блок.
    $finished = Wait-UiProcess -Process $process -Watch $watch -TimeoutSec $TimeoutSec -Title $Title -Expected (Get-StatPlan $Title)
    $exitCode = $null
    if ($finished) { $process.WaitForExit(); $exitCode = $process.ExitCode }
    else { try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { } }
    $watch.Stop()
    $seconds = [int]$watch.Elapsed.TotalSeconds
    Write-RunLog ("  код={0} таймаут={1} секунд={2}" -f $exitCode, (-not $finished), $seconds)
    if ($Title) {
        $statStatus = 'FAIL'
        if (-not $finished) { $statStatus = 'TIMEOUT' } elseif ($exitCode -eq 0) { $statStatus = 'OK' }
        Add-StatFact -Title $Title -Seconds $watch.Elapsed.TotalSeconds -Status $statStatus
    }
    return [pscustomobject]@{ ExitCode = $exitCode; TimedOut = (-not $finished); Seconds = $seconds }
}

function Read-V8Log {
    # Лог 1С бывает и в UTF-8, и в cp1251: определяем по содержимому.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return @() }
    $text = $null
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    else {
        try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
        catch { $text = [System.Text.Encoding]::GetEncoding(1251).GetString($bytes) }
    }
    return @($text -split "`r?`n")
}

function Invoke-Designer {
    # Пакетный конфигуратор указанной базы. Лог - в папке запуска.
    param([string]$BaseName, [string[]]$Command, [string]$LogName, [int]$TimeoutSec, [string]$Title = '')
    $user = $script:TempUser
    $password = $script:TempPassword
    if ($BaseName -ieq $script:ProdBase) { $user = $script:ProdUser; $password = $script:ProdPassword }
    $logPath = Join-Path $script:RunDir $LogName
    $argList = @('DESIGNER') + @(Get-ConnectionArgs -BaseName $BaseName -User $user -Password $password) +
        @('/DisableStartupDialogs', '/DisableStartupMessages') + $Command + @('/Out', ('"{0}"' -f $logPath))
    $result = Invoke-V8 -Exe $script:V8 -Arguments $argList -TimeoutSec $TimeoutSec -Title $Title
    $lines = @(Read-V8Log $logPath)
    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        TimedOut = $result.TimedOut
        Seconds  = $result.Seconds
        Log      = $logPath
        Lines    = $lines
        Text     = (($lines | Where-Object { $_ }) -join ' ')
    }
}

function Read-KeyValueFile {
    param([string]$Path)
    $table = @{}
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return $table }
    $lines = @()
    try { $lines = @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) } catch { return $table }
    foreach ($line in $lines) {
        if ($null -eq $line) { continue }
        $clean = $line.TrimStart([char]0xFEFF)
        $position = $clean.IndexOf('=')
        if ($position -le 0) { continue }
        $table[$clean.Substring(0, $position).Trim()] = $clean.Substring($position + 1)
    }
    return $table
}

function Set-ConfigSetting {
    # Значение настройки в config.psd1 - только в её строке, комментарии остаются; нет строки - добавляется
    # перед «}». Перед первой правкой - копия config.psd1.bak; не читается после правки - прежний файл обратно.
    param([string]$Path, [string]$Key, [string]$Literal)
    $text = [System.IO.File]::ReadAllText($Path)
    # Шаблон - в одинарных кавычках: в двойных PowerShell принял бы $(...) за вставку выражения и выполнил бы его.
    $valuePattern = '(?:''(?:[^'']|'''')*''|\$(?:true|false)|-?\d+|@\([^()\r\n]*\))'
    $found = [regex]::Matches($text, '(?m)^(?<lead>[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[ \t]*)' + $valuePattern)
    if ($found.Count -gt 1) { throw "в config.psd1 настройка $Key встречается $($found.Count) раза: поправь файл руками" }
    if ($found.Count -eq 1) {
        $match = $found[0]
        $text = $text.Substring(0, $match.Index) + $match.Groups['lead'].Value + $Literal + $text.Substring($match.Index + $match.Length)
    }
    else {
        $end = $text.LastIndexOf('}')
        if ($end -lt 0) { throw 'config.psd1: не нашёл закрывающую скобку' }
        $text = $text.Substring(0, $end).TrimEnd() + "`r`n`r`n    $Key = $Literal`r`n" + $text.Substring($end)
    }
    if (-not (Test-Path -LiteralPath ($Path + '.bak'))) { Copy-Item -LiteralPath $Path -Destination ($Path + '.bak') }
    $previous = [System.IO.File]::ReadAllBytes($Path)
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($true)))
    try { $null = Import-PowerShellDataFile -LiteralPath $Path }
    catch {
        [System.IO.File]::WriteAllBytes($Path, $previous)
        throw ("после правки config.psd1 не читается, вернул прежний: {0}" -f $_.Exception.Message)
    }
}

function ConvertTo-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

#endregion

#region Агент сервера 1С: сеансы и свойства базы

function Get-SessionAppName {
    param([string]$App)
    switch ($App) {
        'BackgroundJob' { return 'фоновое задание' }
        '1CV8C' { return 'тонкий клиент' }
        '1CV8' { return 'толстый клиент' }
        'Designer' { return 'конфигуратор' }
        'WebClient' { return 'веб-клиент' }
        'COMConnection' { return 'COM-соединение' }
        'WSConnection' { return 'веб-сервис' }
        'HTTPServiceConnection' { return 'HTTP-сервис' }
        'SrvrConsole' { return 'консоль кластера' }
        default { return $App }
    }
}

function Connect-ClusterAgent {
    $link = [pscustomobject]@{
        Connector       = $null
        Agent           = $null
        Clusters        = @()
        Errors          = @()
        ClusterUser     = [string](Get-Setting $cfg 'ClusterAdmin' '')
        ClusterPassword = [string](Get-PlainPassword ([string](Get-Setting $cfg 'ClusterAdminPassFile' '')))
    }
    $agentAddress = [string](Get-Setting $cfg 'ClusterAgent' '')
    if (-not $agentAddress) { $agentAddress = 'tcp://' + ($script:Server -split ':')[0] }
    try {
        $link.Connector = New-Object -ComObject V83.COMConnector
        $link.Agent = $link.Connector.ConnectAgent($agentAddress)
    }
    catch {
        $link.Errors = @(("не подключился к агенту сервера {0}: {1}" -f $agentAddress, $_.Exception.Message))
        return $link
    }
    $clusters = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($cluster in @($link.Agent.GetClusters())) {
        try { $link.Agent.Authenticate($cluster, $link.ClusterUser, $link.ClusterPassword); $clusters.Add($cluster) }
        catch { $errors.Add(("кластер {0}: не пустил ({1})" -f $cluster.HostName, $_.Exception.Message)) }
    }
    $link.Clusters = $clusters.ToArray()
    $link.Errors = $errors.ToArray()
    return $link
}

function Format-ClusterSession {
    param($Session)
    $text = "сеанс {0}: {1}, с {2}" -f $Session.SessionID, (Get-SessionAppName ([string]$Session.AppID)), $Session.StartedAt
    $user = ''
    $computer = ''
    try { $user = [string]$Session.userName } catch { $user = '' }
    try { $computer = [string]$Session.Host } catch { $computer = '' }
    if ($user) { $text += (", пользователь {0}" -f $user) }
    if ($computer) { $text += (", компьютер {0}" -f $computer) }
    return $text
}

function Get-BaseSessions {
    # Сеансы базы по данным агента: имя базы сравнивается целиком.
    param($Link, [string]$BaseName)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($message in @($Link.Errors)) { $list.Add([pscustomobject]@{ Text = $message; IsDesigner = $false; IsError = $true }) }
    foreach ($cluster in @($Link.Clusters)) {
        foreach ($session in @($Link.Agent.GetSessions($cluster))) {
            $sessionBase = ''
            try { $sessionBase = [string]$session.infoBase.Name } catch { continue }
            if ($sessionBase -ine $BaseName) { continue }
            $list.Add([pscustomobject]@{ Text = (Format-ClusterSession $session); IsDesigner = ([string]$session.AppID -eq 'Designer'); IsError = $false })
        }
    }
    return $list.ToArray()
}

function Stop-BaseSessions {
    # Завершает сеансы базы. Без -Designers конфигураторы не трогаются, с -Designers - только они.
    param($Link, [string]$BaseName, [switch]$Designers)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($message in @($Link.Errors)) { $lines.Add($message) }
    if ($null -eq $Link.Agent) { return $lines.ToArray() }
    foreach ($cluster in @($Link.Clusters)) {
        foreach ($session in @($Link.Agent.GetSessions($cluster))) {
            $sessionBase = ''
            try { $sessionBase = [string]$session.infoBase.Name } catch { continue }
            if ($sessionBase -ine $BaseName) { continue }
            $isDesigner = ([string]$session.AppID -eq 'Designer')
            if ([bool]$Designers -ne $isDesigner) { continue }
            $description = Format-ClusterSession $session
            try { $Link.Agent.TerminateSession($cluster, $session); $lines.Add(("{0} - завершён" -f $description)) }
            catch { $lines.Add(("{0} - не завершился: {1}" -f $description, $_.Exception.Message)) }
        }
    }
    foreach ($line in $lines) { Write-RunLog ('Завершение сеансов: ' + $line) }
    return $lines.ToArray()
}

function Get-BaseInfo {
    # Свойства базы в кластере через рабочий процесс: менять их можно только со входом в саму базу.
    param($Link, [string]$BaseName, [string]$User, [string]$Password)
    if ($null -eq $Link.Agent) { throw (@($Link.Errors) -join '; ') }
    foreach ($cluster in @($Link.Clusters)) {
        $processes = @($Link.Agent.GetWorkingProcesses($cluster) | Where-Object { [int]$_.Running -eq 1 })
        if ($processes.Count -eq 0) { continue }
        $process = $Link.Connector.ConnectWorkingProcess(("tcp://{0}:{1}" -f $processes[0].HostName, $processes[0].MainPort))
        $process.AuthenticateAdmin($Link.ClusterUser, $Link.ClusterPassword)
        $process.AddAuthentication($User, $Password)
        foreach ($infoBase in @($process.GetInfoBases())) {
            if ([string]$infoBase.Name -ieq $BaseName) { return [pscustomobject]@{ Process = $process; InfoBase = $infoBase } }
        }
    }
    throw ("в кластере не нашёл базу {0} или нет рабочего процесса" -f $BaseName)
}

function Read-BaseInfoAgain {
    param($Target, [string]$BaseName)
    foreach ($infoBase in @($Target.Process.GetInfoBases())) {
        if ([string]$infoBase.Name -ieq $BaseName) { return $infoBase }
    }
    throw ("база {0} пропала из списка баз кластера" -f $BaseName)
}

function Clear-ProdLocks {
    # Снимает с рабочей базы блокировку регламентных заданий и блокировку начала сеансов - обе, кто бы их
    # ни поставил (кроме чужой блокировки сеансов с другим кодом, см. KeepForeignSessionLock). Потом читает
    # свойства базы заново и проверяет. Не получилось - вторая попытка, потом красная строка с тем, что делать руками.
    if (-not $script:ProdLocksArmed) { return }
    $script:ProdLocksArmed = $false
    for ($try = 1; $try -le 2; $try++) {
        try {
            $target = Get-BaseInfo -Link (Connect-ClusterAgent) -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
            $infoBase = $target.InfoBase
            $changes = New-Object System.Collections.Generic.List[string]
            if ([bool]$infoBase.ScheduledJobsDenied) {
                $infoBase.ScheduledJobsDenied = $false
                $changes.Add('блокировку регламентных заданий')
            }
            if ([bool]$infoBase.SessionsDenied -and -not $script:KeepForeignSessionLock) {
                $infoBase.SessionsDenied = $false
                $infoBase.DeniedMessage = ''
                $infoBase.PermissionCode = ''
                $changes.Add('блокировку начала сеансов')
            }
            if ($changes.Count -gt 0) { $target.Process.UpdateInfoBase($infoBase) }
            $check = Read-BaseInfoAgain $target $script:ProdBase
            $left = New-Object System.Collections.Generic.List[string]
            if ([bool]$check.ScheduledJobsDenied) { $left.Add('регламентных заданий') }
            if ([bool]$check.SessionsDenied -and -not $script:KeepForeignSessionLock) { $left.Add('начала сеансов') }
            if ($left.Count -gt 0) { throw ('после записи всё ещё стоит блокировка ' + ($left -join ' и ')) }
            if ($changes.Count -gt 0) { Write-Line ("Снял с {0}: {1}. Проверил: блокировок нет." -f $script:ProdBase, ($changes -join ' и ')) 'Green' }
            else { Write-Line ("Блокировок на {0} нет." -f $script:ProdBase) 'Green' }
            if ($script:KeepForeignSessionLock) { Write-Line ("Чужую блокировку начала сеансов {0} не трогал." -f $script:ProdBase) 'Yellow' }
            return
        }
        catch {
            if ($try -lt 2) { Start-Sleep -Seconds 5; continue }
            Write-Line ("НЕ СНЯЛ блокировки {0}: {1}. Снять руками: консоль кластера - {0} - Свойства - убрать «Блокировка регламентных заданий включена» и «Блокировка начала сеансов включена»." -f $script:ProdBase, $_.Exception.Message) 'Red'
        }
    }
}

#endregion

#region Настройки

$configPath = $Config
if ([string]::IsNullOrWhiteSpace($configPath)) { $configPath = Join-Path $Root 'config.psd1' }
if (-not (Test-Path -LiteralPath $configPath)) { throw "Нет файла настроек: $configPath" }
$cfg = Import-PowerShellDataFile -LiteralPath $configPath

# Меню и вопросы (ui.ps1): из ci.exe их рисует ci.exe, без него - консоль. Нужны уже здесь: если в настройках
# чего-то не хватает, скрипт спрашивает и записывает в config.psd1.
. (Join-Path $Root 'ui.ps1')
Initialize-Ui -Channel $UiChannel

$script:Server = [string](Get-Setting $cfg 'Server' '')
$script:TempBase = [string](Get-Setting $cfg 'Base' '')
$script:ProdBase = [string](Get-Setting $cfg 'ProdBase' '')
$script:UnlockCode = [string](Get-Setting $cfg 'UnlockCode' '')
if (-not [string]::IsNullOrEmpty([string](Get-Setting $cfg 'File' ''))) { throw 'Скрипт обновления работает только с базами кластера: в config.psd1 заполнено File.' }
if (-not $script:Server -or -not $script:TempBase) { throw 'В config.psd1 не заполнены Server и Base.' }
if (-not $script:ProdBase) {
    # Рабочая база не задана: спросить один раз и записать в config.psd1 (и в ForbiddenBases, если её там нет).
    $forbiddenList = @(Get-Setting $cfg 'ForbiddenBases' @() | Where-Object { $_ })
    $guess = ''
    if ($forbiddenList.Count -eq 1) { $guess = [string]$forbiddenList[0] }
    if (-not (Test-UiCanAsk)) {
        if (-not $guess) { throw "В config.psd1 нет ProdBase - имени рабочей базы в кластере. Задай его: ci -> Настройки -> Базы -> ProdBase." }
        $script:ProdBase = $guess
    }
    else {
        while (-not $script:ProdBase) {
            $typed = Read-UiText -Prompt ("Имя рабочей базы в кластере {0} (запишу в config.psd1, больше не спрошу)" -f $script:Server) -Default $guess -CancelAsNull
            if ($null -eq $typed) { Write-Host 'Выход: рабочая база не задана.'; exit 0 }
            $script:ProdBase = $typed.Trim()
        }
        Set-ConfigSetting -Path $configPath -Key 'ProdBase' -Literal ("'" + $script:ProdBase.Replace("'", "''") + "'")
        if (@($forbiddenList | Where-Object { [string]$_ -ieq $script:ProdBase }).Count -eq 0) {
            $newList = @($forbiddenList) + @($script:ProdBase)
            Set-ConfigSetting -Path $configPath -Key 'ForbiddenBases' -Literal ('@(' + (@($newList | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', ') + ')')
            Write-Host ("Рабочая база {0} записана в config.psd1 (ProdBase) и добавлена в ForbiddenBases: гейт её не тронет." -f $script:ProdBase) -ForegroundColor Green
        }
        else { Write-Host ("Рабочая база {0} записана в config.psd1 (ProdBase)." -f $script:ProdBase) -ForegroundColor Green }
        $cfg = Import-PowerShellDataFile -LiteralPath $configPath
    }
}

# Защита от перепутанных баз. Тестовая должна быть похожа на тестовую, рабочая - нет; рабочая обязана стоять
# в ForbiddenBases: тогда гейт её не тронет.
if ($script:TempBase -notmatch $TestBasePattern) { throw "Тестовая база «$($script:TempBase)» не похожа на тестовую." }
if ($script:ProdBase -ieq $script:TempBase) { throw 'ProdBase и Base - одна и та же база.' }
if ($script:ProdBase -match $TestBasePattern) { throw "Рабочая база «$($script:ProdBase)» похожа по имени на тестовую: проверь ProdBase." }
$forbidden = @(Get-Setting $cfg 'ForbiddenBases' @() | Where-Object { $_ })
if (@($forbidden | Where-Object { [string]$_ -ieq $script:ProdBase }).Count -eq 0) {
    throw "Рабочей базы «$($script:ProdBase)» нет в ForbiddenBases: допиши её туда, иначе её мог бы тронуть гейт."
}

$binDir = [string](Get-Setting $cfg 'V8Bin' '')
$script:V8 = Join-Path $binDir '1cv8.exe'
$script:V8C = Join-Path $binDir '1cv8c.exe'
if (-not (Test-Path -LiteralPath $script:V8)) { throw "Не нашёл конфигуратор: $($script:V8)" }

$script:TempUser = [string](Get-Setting $cfg 'AdminUser' '')
$script:TempPassword = Get-PlainPassword ([string](Get-Setting $cfg 'AdminPassFile' ''))
# Пустые ProdAdminUser и ProdAdminPassFile - как у тестовой базы.
$script:ProdUser = [string](Get-Setting $cfg 'ProdAdminUser' '')
$prodPassFile = [string](Get-Setting $cfg 'ProdAdminPassFile' '')
if (-not $script:ProdUser) {
    $script:ProdUser = $script:TempUser
    if (-not $prodPassFile) { $prodPassFile = [string](Get-Setting $cfg 'AdminPassFile' '') }
}
$script:ProdPassword = Get-PlainPassword $prodPassFile

$deployExtensions = @(Get-Setting $cfg 'DeployExtensions' @() | Where-Object { $_ })
if ($deployExtensions.Count -eq 0) { $deployExtensions = @(Get-Setting $cfg 'Extensions' @() | Where-Object { $_ }) }
if ($deployExtensions.Count -eq 0) { throw 'В config.psd1 пустые DeployExtensions и Extensions: нечего обновлять.' }
$deniedFrom = [int](Get-Setting $cfg 'DeployDeniedFrom' 22)
$deniedTo = [int](Get-Setting $cfg 'DeployDeniedTo' 2)
$sessionLockHours = [int](Get-Setting $cfg 'SessionLockHours' 2)
if ($sessionLockHours -lt 1) { $sessionLockHours = 1 }
$prodSelfCheckForms = [bool](Get-Setting $cfg 'ProdSelfCheckForms' $false)
$prodSelfCheckTimeoutMin = [int](Get-Setting $cfg 'ProdSelfCheckTimeoutMin' 60)
$timeoutLoadSec = 60 * [int](Get-Setting $cfg 'TimeoutLoadMin' 30)
$timeoutUpdateSec = 60 * [int](Get-Setting $cfg 'TimeoutUpdateMin' 120)
$canaryEpf = Resolve-RootPath ([string](Get-Setting $cfg 'CanaryEpf' 'tools\Канарейка.epf'))
$selfCheckEpf = Resolve-RootPath ([string](Get-Setting $cfg 'SelfCheckEpf' 'tools\ВыполнитьПослеОбновления.epf'))
$canaryTimeoutSec = [int](Get-Setting $cfg 'CanaryTimeoutSec' 300)
$comTimeoutSec = [int](Get-Setting $cfg 'ComTimeoutSec' 300)
# Сколько ждать один сеанс записи внешней обработки в справочник (regepf, unregepf).
$processingTimeoutSec = [int](Get-Setting $cfg 'ProcessingTimeoutSec' 600)


# Статистика длительностей шагов: тот же журнал, что у гейта, база - рабочая (stats.ps1).
. (Join-Path $Root 'stats.ps1')
Initialize-Stats -Dir (Resolve-RootPath ([string](Get-Setting $cfg 'StatsDir' 'stats'))) -Source 'deploy' -Base $script:ProdBase `
    -Days ([int](Get-Setting $cfg 'StatsDays' 120)) -Platform ([regex]::Match($binDir, '\d+\.\d+\.\d+\.\d+').Value)

$deployRoot = Resolve-RootPath ([string](Get-Setting $cfg 'DeployDir' 'deploy'))
$mirrorRoot = Join-Path $deployRoot 'mirror'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:RunDir = Join-Path $deployRoot $runId
New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
$script:RunLogPath = Join-Path $script:RunDir 'run.log'
Set-StatRun $runId
$runsRoot = Resolve-RootPath ([string](Get-Setting $cfg 'RunsDir' 'runs'))

Write-Host ''
Write-Host ("Обновление рабочей базы {0} из {1}, запуск {2}" -f $script:ProdBase, $script:TempBase, $runId) -ForegroundColor Cyan
Write-Host ("Папка запуска: {0}" -f $script:RunDir)
Write-RunLog ("Запуск {0}: {1} -> {2}" -f $runId, $script:TempBase, $script:ProdBase)

#endregion

#region Выгрузки, сравнение, история обновлений (функции)

function Get-JsonValue {
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Update-Mirror {
    # Выгрузка расширения базы в файлы, в постоянную папку зеркала. Если выгрузка там уже есть - только
    # изменения (-update), не получилось - заново целиком.
    param([string]$BaseName, [string]$Extension)
    $dir = Join-Path (Join-Path $mirrorRoot $BaseName) $Extension
    $hasDump = Test-Path -LiteralPath (Join-Path $dir 'ConfigDumpInfo.xml')
    $logName = "dump_{0}_{1}.log" -f $BaseName, $Extension
    $command = @('/DumpConfigToFiles', ('"{0}"' -f $dir), '-Extension', $Extension)
    if ($hasDump) { $command += '-update' }
    else {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $result = Invoke-Designer -BaseName $BaseName -Command $command -LogName $logName -TimeoutSec $timeoutLoadSec -Title ("Выгрузить {0} из {1}" -f $Extension, $BaseName)
    if ($result.ExitCode -ne 0 -and $hasDump -and -not $result.TimedOut) {
        Remove-Item -LiteralPath $dir -Recurse -Force
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $result = Invoke-Designer -BaseName $BaseName -Command @('/DumpConfigToFiles', ('"{0}"' -f $dir), '-Extension', $Extension) `
            -LogName $logName -TimeoutSec $timeoutLoadSec -Title ("Выгрузить {0} из {1} целиком" -f $Extension, $BaseName)
    }
    $absent = ($result.ExitCode -ne 0 -and $result.Text -match 'не найден')
    if ($absent -and (Test-Path -LiteralPath $dir)) { Remove-Item -LiteralPath $dir -Recurse -Force }
    return [pscustomobject]@{
        Ok     = ($result.ExitCode -eq 0)
        Absent = $absent
        Dir    = $dir
        Detail = $result.Text
        Busy   = ($result.Text.Contains('уже работает конфигуратор') -or $result.Text.Contains('уже открыта Конфигуратором'))
    }
}

function Get-TreeHashes {
    # Файлы выгрузки и их хеши. ConfigDumpInfo.xml служебный, в сравнение не идёт.
    param([string]$Dir)
    $table = @{}
    if ([string]::IsNullOrEmpty($Dir) -or -not (Test-Path -LiteralPath $Dir)) { return $table }
    $prefixLength = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\').Length + 1
    $sha = [System.Security.Cryptography.SHA256]::Create()
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Recurse -File)) {
        $relative = $file.FullName.Substring($prefixLength).Replace('\', '/')
        if ($relative -eq 'ConfigDumpInfo.xml') { continue }
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $table[$relative] = [System.BitConverter]::ToString($sha.ComputeHash($bytes))
    }
    return $table
}

function Get-ExtensionVersion {
    param([string]$Dir)
    $path = Join-Path $Dir 'Configuration.xml'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        [xml]$document = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $node = $document.SelectSingleNode("/*[local-name()='MetaDataObject']/*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Version']")
        if ($null -ne $node) { return [string]$node.InnerText }
    }
    catch { }
    return ''
}

function Invoke-UiBackground {
    # Долгий вызов (внешнее соединение 1С) - в отдельном потоке, а в окне - строка хода с временем.
    # Не уложился в TimeoutSec - не ждём (поток бросается), Ok = $false. Ошибка внутри - Ok = $false и её текст.
    param([scriptblock]$Script, [object[]]$Arguments, [string]$Title, [int]$TimeoutSec)
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($Script.ToString())
    foreach ($argument in $Arguments) { [void]$shell.AddArgument($argument) }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $handle = $shell.BeginInvoke()
    $plan = Get-StatPlan $Title
    while (-not $handle.IsCompleted) {
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
            Complete-UiProgress
            try { [void]$shell.BeginStop($null, $null) } catch { }
            Add-StatFact -Title $Title -Seconds $watch.Elapsed.TotalSeconds -Status 'TIMEOUT'
            return [pscustomobject]@{ Ok = $false; Error = ("нет ответа за {0} с (настройка ComTimeoutSec)" -f $TimeoutSec); Result = $null }
        }
        Write-UiProgress -Title $Title -Elapsed $watch.Elapsed.TotalSeconds -Expected $plan
        Start-Sleep -Milliseconds 250
    }
    Complete-UiProgress
    $result = $null
    $errorText = ''
    try {
        $output = $shell.EndInvoke($handle)
        if ($output.Count -gt 0) { $result = $output[$output.Count - 1] }
        if ($result -is [System.Management.Automation.PSObject]) { $result = $result.BaseObject }
        if ($shell.Streams.Error.Count -gt 0) { $errorText = [string]$shell.Streams.Error[0] }
    }
    catch {
        $errorText = $_.Exception.Message
        if ($null -ne $_.Exception.InnerException) { $errorText = $_.Exception.InnerException.Message }
    }
    finally {
        $shell.Dispose()
        $runspace.Dispose()
    }
    $status = 'OK'
    if ($errorText) { $status = 'FAIL' }
    Add-StatFact -Title $Title -Seconds $watch.Elapsed.TotalSeconds -Status $status
    return [pscustomobject]@{ Ok = (-not $errorText); Error = $errorText; Result = $result }
}

function Get-ComConnectionLine {
    param([string]$BaseName, [string]$User, [string]$Password)
    $line = 'Srvr="{0}";Ref="{1}";' -f $script:Server, $BaseName
    if ($User) { $line += 'Usr="{0}";' -f $User.Replace('"', '""') }
    if ($Password) { $line += 'Pwd="{0}";' -f $Password.Replace('"', '""') }
    return $line
}

function Get-ExtensionStates {
    # Расширения базы через внешнее соединение (COM): имя, версия, хеш-сумма. Только чтение, конфигуратор
    # не нужен: работает и при пользователях в базе. Соединение идёт в фоне со строкой хода и таймаутом
    # ComTimeoutSec: первое внешнее соединение к большой базе бывает долгим. Не получилось - Ok = $false.
    param([string]$BaseName, [string]$User, [string]$Password)
    $reader = {
        param([string]$Line)
        $items = @{}
        $connector = New-Object -ComObject V83.COMConnector
        $connection = $connector.Connect($Line)
        try {
            $list = $connection.ConfigurationExtensions.Get($connection.NewObject('Structure'), $connection.ConfigurationExtensionsSource.Database)
            for ($i = 0; $i -lt [int]$list.Count(); $i++) {
                $extension = $list.Get($i)
                $hash = ''
                try { $hash = [string]$connection.Base64String($extension.HashSum) } catch { $hash = '' }
                $items[[string]$extension.Name] = [pscustomobject]@{ Version = [string]$extension.Version; Hash = $hash }
            }
        }
        finally {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($connection)
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($connector)
        }
        return $items
    }
    $call = Invoke-UiBackground -Script $reader -Arguments @((Get-ComConnectionLine $BaseName $User $Password)) `
        -Title ("Прочитать расширения {0}" -f $BaseName) -TimeoutSec $comTimeoutSec
    $message = $call.Error
    if ($Password -and $message) { $message = $message.Replace($Password, '***') }
    if (-not $call.Ok -or -not ($call.Result -is [hashtable])) {
        if (-not $message) { $message = 'внешнее соединение ничего не вернуло' }
        Write-RunLog ("Расширения {0} через COM не получены: {1}" -f $BaseName, $message)
        return [pscustomobject]@{ Ok = $false; Error = $message; Items = @{} }
    }
    Write-RunLog ("Расширения {0} через COM: {1}" -f $BaseName, (@($call.Result.Keys | Sort-Object) -join ', '))
    return [pscustomobject]@{ Ok = $true; Error = ''; Items = $call.Result }
}

function Get-MirrorHash {
    # Хеш-сумма расширения рабочей базы на момент последней выгрузки зеркала (hash.txt рядом с выгрузкой).
    param([string]$Dir)
    $file = Join-Path $Dir 'hash.txt'
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    return ([System.IO.File]::ReadAllText($file)).Trim()
}

function Save-MirrorHashes {
    # Запоминает хеш-суммы расширений рабочей базы рядом с её выгрузками: по ним «как есть» видит,
    # что в рабочую загрузили руками после прошлого раза.
    param([string[]]$Names)
    $states = Get-ExtensionStates -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
    if (-not $states.Ok) { return }
    foreach ($name in $Names) {
        $dir = Join-Path (Join-Path $mirrorRoot $script:ProdBase) $name
        if (-not $states.Items.ContainsKey($name) -or -not (Test-Path -LiteralPath $dir)) { continue }
        [System.IO.File]::WriteAllText((Join-Path $dir 'hash.txt'), $states.Items[$name].Hash)
    }
}

function Get-DeployHistory {
    # Обновления рабочей базы, после которых база осталась обновлённой (deploy.json, у старых запусков - summary.txt
    # и резервные копии в before\). Новые сверху.
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $deployRoot)) { return $list.ToArray() }
    foreach ($dir in @(Get-ChildItem -LiteralPath $deployRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending)) {
        $jsonFile = Join-Path $dir.FullName 'deploy.json'
        $record = $null
        if (Test-Path -LiteralPath $jsonFile) {
            try { $record = (Get-Content -LiteralPath $jsonFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { $record = $null }
            if ($null -eq $record -or [string](Get-JsonValue $record 'outcome' '') -ne 'updated') { continue }
            if ([string](Get-JsonValue $record 'base' '') -ne $script:ProdBase) { continue }
        }
        else {
            # Запуск до deploy.json: что откатывать, видно по резервным копиям before\<рабочая>_<расширение>_<дата>.cfe.
            $summaryFile = Join-Path $dir.FullName 'summary.txt'
            if (-not (Test-Path -LiteralPath $summaryFile)) { continue }
            $summaryText = [System.IO.File]::ReadAllText($summaryFile)
            if ($summaryText -notmatch 'Итог: обновлено') { continue }
            $extensionsList = @()
            foreach ($name in $deployExtensions) {
                $backupFile = @(Get-ChildItem -LiteralPath (Join-Path $dir.FullName 'before') -Filter ("{0}_{1}_*.cfe" -f $script:ProdBase, $name) -File -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($summaryText -match [regex]::Escape([string]$name)) {
                    $backupPath = ''
                    if ($backupFile.Count -gt 0) { $backupPath = 'before\' + $backupFile[0].Name }
                    $extensionsList += [pscustomobject]@{ name = [string]$name; status = ''; backup = $backupPath; oldVersion = ''; newVersion = '' }
                }
            }
            $record = [pscustomobject]@{ runId = $dir.Name; time = ([datetime]::ParseExact($dir.Name, 'yyyyMMdd-HHmmss', $null)).ToString('yyyy-MM-ddTHH:mm:ss')
                base = $script:ProdBase; mode = ''; outcome = 'updated'; rollbackOf = ''; user = ''; gate = $null; riskAccepted = $false; risks = @()
                extensions = $extensionsList; processings = @(); light = @(); article = '' }
        }
        $record | Add-Member -NotePropertyName Dir -NotePropertyValue $dir.FullName -Force
        $list.Add($record)
    }
    return $list.ToArray()
}

function Get-DeployModeText {
    param($Record)
    $mode = [string](Get-JsonValue $Record 'mode' '')
    $names = @{ '1' = 'все из temp'; '2' = 'выбранные из temp'; 'epf' = 'только внешние обработки'; 'asis' = 'как есть'; 'rollback' = 'откат' }
    if ($names.ContainsKey($mode)) { return $names[$mode] }
    return 'обновление'
}

function Get-DeployLabel {
    # Строка списка откатов: когда, сколько расширений и обработок, как обновляли, чем кончился лёгкий прогон.
    param($Record)
    $when = [datetime]::ParseExact([string]$Record.runId, 'yyyyMMdd-HHmmss', $null)
    $extCount = @(Get-JsonValue $Record 'extensions' @()).Count
    $epfCount = @(Get-JsonValue $Record 'processings' @()).Count
    $light = @(Get-JsonValue $Record 'light' @())
    $lightText = 'лёгкий прогон: нет данных'
    if ($light.Count -gt 0) {
        $bad = @($light | Where-Object { $_.status -eq 'FAIL' }).Count
        $warn = @($light | Where-Object { $_.status -eq 'WARN' }).Count
        if ($bad -gt 0) { $lightText = "лёгкий прогон: красного $bad" }
        elseif ($warn -gt 0) { $lightText = "лёгкий прогон: жёлтого $warn" }
        else { $lightText = 'лёгкий прогон: зелёный' }
    }
    $flag = ''
    if ([bool](Get-JsonValue $Record 'riskAccepted' $false)) { $flag = ', НЕСМОТРЯ НА ГЕЙТ' }
    return ("{0:dd.MM.yyyy HH:mm}  расширений {1}, обработок {2}  ({3}{4}; {5})" -f $when, $extCount, $epfCount, (Get-DeployModeText $Record), $flag, $lightText)
}

function Get-DeployDetailLines {
    # Подробно об обновлении: расширения и обработки раздельно, резервные копии, гейт, лёгкий прогон, что после.
    param($Record, [object[]]$History)
    $lines = New-Object System.Collections.Generic.List[string]
    $when = [datetime]::ParseExact([string]$Record.runId, 'yyyyMMdd-HHmmss', $null)
    $lines.Add(("Обновление {0} от {1:dd.MM.yyyy HH:mm} ({2})" -f $script:ProdBase, $when, (Get-DeployModeText $Record)))
    $user = [string](Get-JsonValue $Record 'user' '')
    if ($user) { $lines.Add("Выполнил: $user") }
    $rollbackOf = [string](Get-JsonValue $Record 'rollbackOf' '')
    if ($rollbackOf) { $lines.Add("Это был откат к состоянию до обновления $rollbackOf") }
    $lines.Add("Папка: $($Record.Dir)")
    $lines.Add('')

    $extensions = @(Get-JsonValue $Record 'extensions' @())
    $lines.Add(("РАСШИРЕНИЯ ({0})" -f $extensions.Count))
    if ($extensions.Count -eq 0) { $lines.Add('  нет') }
    foreach ($item in $extensions) {
        $versions = ''
        if ($item.oldVersion -or $item.newVersion) { $versions = ("  версия {0} -> {1}" -f $item.oldVersion, $item.newVersion) }
        $backupText = 'резервной копии нет: расширения до обновления не было, откатом не удаляется'
        if ($item.backup) {
            $backupPath = Join-Path $Record.Dir $item.backup
            if (Test-Path -LiteralPath $backupPath) { $backupText = "откат вернёт резервную копию $($item.backup)" }
            else { $backupText = "РЕЗЕРВНОЙ КОПИИ НЕТ НА ДИСКЕ: $($item.backup)" }
        }
        $lines.Add(("  - {0}{1}" -f $item.name, $versions))
        $lines.Add(("      {0}" -f $backupText))
    }
    $lines.Add('')
    $processings = @(Get-JsonValue $Record 'processings' @())
    $lines.Add(("ВНЕШНИЕ ОБРАБОТКИ ({0})" -f $processings.Count))
    if ($processings.Count -eq 0) { $lines.Add('  нет: в этом обновлении обработки не менялись') }
    foreach ($item in $processings) {
        $title = [string](Get-JsonValue $item 'title' '')
        $label = [string]$item.name
        if ($title) { $label = '{0} ({1})' -f $item.name, $title }
        $oldVersion = [string](Get-JsonValue $item 'oldVersion' '')
        $newVersion = [string](Get-JsonValue $item 'newVersion' '')
        if ($oldVersion -or $newVersion) { $label += ("  версия {0} -> {1}" -f $oldVersion, $newVersion) }
        $lines.Add(("  - {0}" -f $label))
        $backup = [string](Get-JsonValue $item 'backup' '')
        $file = [string](Get-JsonValue $item 'file' '')
        $backupText = 'прежней версии нет и новой не отмечена: откатом не трогается'
        if ([string](Get-JsonValue $item 'action' '') -eq 'unregister') {
            if ($file -and (Test-Path -LiteralPath (Join-Path $Record.Dir $file))) { $backupText = "была снята из справочника; откат запишет её снова из $file" }
            else { $backupText = 'была снята из справочника; файла для отката нет' }
        }
        elseif ($backup) {
            if (Test-Path -LiteralPath (Join-Path $Record.Dir $backup)) { $backupText = "откат вернёт прежнюю версию $backup" }
            else { $backupText = "РЕЗЕРВНОЙ КОПИИ НЕТ НА ДИСКЕ: $backup" }
        }
        elseif ([string](Get-JsonValue $item 'isNew' '') -eq 'yes') { $backupText = 'новая: откат снимет её из справочника (публикация «Отключена», пометка удаления)' }
        $lines.Add(("      {0}" -f $backupText))
    }
    $lines.Add('')

    $gate = Get-JsonValue $Record 'gate' $null
    if ($null -ne $gate) { $lines.Add(("Гейт перед обновлением: прогон {0}, вердикт {1}" -f (Get-JsonValue $gate 'run' ''), (Get-JsonValue $gate 'verdict' ''))) }
    if ([bool](Get-JsonValue $Record 'riskAccepted' $false)) {
        $lines.Add(("ОБНОВЛЯЛИ НЕСМОТРЯ НА ГЕЙТ: {0}" -f (@(Get-JsonValue $Record 'risks' @()) -join '; ')))
    }
    $light = @(Get-JsonValue $Record 'light' @())
    $lines.Add('Лёгкий прогон после обновления:')
    if ($light.Count -eq 0) { $lines.Add('  нет данных') }
    foreach ($item in $light) { $lines.Add(("  [{0}] {1}: {2}" -f $item.status, $item.name, $item.text)) }
    $article = [string](Get-JsonValue $Record 'article' '')
    if ($article) { $lines.Add("Отчёт: $article") }

    # Что было после: откат вернёт и их изменения по тем же расширениям.
    $names = @($extensions | ForEach-Object { [string]$_.name })
    $later = @($History | Where-Object { [string]$_.runId -gt [string]$Record.runId -and @(@(Get-JsonValue $_ 'extensions' @()) | Where-Object { $names -contains [string]$_.name }).Count -gt 0 })
    if ($later.Count -gt 0) {
        $lines.Add('')
        $lines.Add(("ПОСЛЕ ЭТОГО ТЕ ЖЕ РАСШИРЕНИЯ ОБНОВЛЯЛИ ЕЩЁ {0} РАЗ: откат уберёт и эти изменения" -f $later.Count))
        foreach ($item in $later) { $lines.Add(('  ' + (Get-DeployLabel $item))) }
    }
    return $lines.ToArray()
}

function Get-ExtensionData {
    # Расширение рабочей (или любой) базы в файл .cfe через внешнее соединение; не вышло - конфигуратором.
    param([string]$BaseName, [string]$User, [string]$Password, [string]$Name, [string]$Path)
    $connector = $null
    $connection = $null
    try {
        $connector = New-Object -ComObject V83.COMConnector
        $line = 'Srvr="{0}";Ref="{1}";' -f $script:Server, $BaseName
        if ($User) { $line += 'Usr="{0}";' -f $User.Replace('"', '""') }
        if ($Password) { $line += 'Pwd="{0}";' -f $Password.Replace('"', '""') }
        $connection = $connector.Connect($line)
        $list = $connection.ConfigurationExtensions.Get($connection.NewObject('Structure'), $connection.ConfigurationExtensionsSource.Database)
        for ($i = 0; $i -lt [int]$list.Count(); $i++) {
            $extension = $list.Get($i)
            if ([string]$extension.Name -ne $Name) { continue }
            $extension.GetData().Write($Path)
            break
        }
    }
    catch { Write-RunLog ("Расширение {0} из {1} через COM не получено: {2}" -f $Name, $BaseName, $_.Exception.Message) }
    finally {
        if ($null -ne $connection) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($connection) } catch { } }
        if ($null -ne $connector) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($connector) } catch { } }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
    if (Test-Path -LiteralPath $Path) { return $true }
    $result = Invoke-Designer -BaseName $BaseName -Command @('/DumpCfg', ('"{0}"' -f $Path), '-Extension', $Name) `
        -LogName ("pull_{0}.log" -f $Name) -TimeoutSec $timeoutLoadSec -Title ("Выгрузить {0} из {1}" -f $Name, $BaseName)
    return ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $Path))
}

function Export-Processings {
    # Внешние обработки и отчёты базы (справочник ДополнительныеОтчетыИОбработки, не помеченные на удаление)
    # в файлы папки Dir. Возвращает список: имя объекта, наименование, версия, файл, хеш файла.
    param([string]$BaseName, [string]$User, [string]$Password, [string]$Dir)
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $items = New-Object System.Collections.Generic.List[object]
    $connector = $null
    $connection = $null
    try {
        $connector = New-Object -ComObject V83.COMConnector
        $line = 'Srvr="{0}";Ref="{1}";' -f $script:Server, $BaseName
        if ($User) { $line += 'Usr="{0}";' -f $User.Replace('"', '""') }
        if ($Password) { $line += 'Pwd="{0}";' -f $Password.Replace('"', '""') }
        $connection = $connector.Connect($line)
        $query = $connection.NewObject('Query')
        $query.Text = 'ВЫБРАТЬ Спр.Наименование КАК Title, Спр.ИмяОбъекта КАК ObjName, Спр.Версия КАК Version, ' +
            'ПРЕДСТАВЛЕНИЕ(Спр.Вид) КАК Kind, Спр.ХранилищеОбработки КАК Storage ' +
            'ИЗ Справочник.ДополнительныеОтчетыИОбработки КАК Спр ГДЕ НЕ Спр.ПометкаУдаления'
        $selection = $query.Execute().Select()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        while ($selection.Next()) {
            $objName = [string]$selection.ObjName
            if (-not $objName) { continue }
            $extension = '.epf'
            if ([string]$selection.Kind -match 'тч[её]т') { $extension = '.erf' }
            $file = Join-Path $Dir ($objName + $extension)
            $data = $selection.Storage.Get()
            if ($null -eq $data) { continue }
            $data.Write($file)
            if (-not (Test-Path -LiteralPath $file)) { continue }
            $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($file)))
            $items.Add([pscustomobject]@{ ObjName = $objName; Title = [string]$selection.Title; Version = [string]$selection.Version; File = $file; Hash = $hash })
        }
        return [pscustomobject]@{ Ok = $true; Error = ''; Items = $items.ToArray() }
    }
    catch {
        $message = $_.Exception.Message
        if ($Password) { $message = $message.Replace($Password, '***') }
        return [pscustomobject]@{ Ok = $false; Error = $message; Items = $items.ToArray() }
    }
    finally {
        if ($null -ne $connection) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($connection) } catch { } }
        if ($null -ne $connector) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($connector) } catch { } }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Invoke-ProdClient {
    # Тонкий клиент рабочей базы с внешней обработкой; ждём файл $DoneFile не дольше $TimeoutSec.
    param([string]$Epf, [string]$Parameter, [string]$DoneFile, [int]$TimeoutSec, [string]$Title)
    $argList = @('ENTERPRISE') + @(Get-ConnectionArgs -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword) + @(
        '/DisableStartupDialogs', '/DisableStartupMessages', '/Execute', ('"{0}"' -f $Epf), ('/C"{0}"' -f $Parameter))
    $argLine = $argList -join ' '
    Write-RunLog ("> 1cv8c.exe {0}" -f (Get-MaskedLine $argLine))
    Write-Host ("  ...  {0}: начато в {1}, жду не дольше {2} мин" -f $Title, (Get-Date -Format 'HH:mm:ss'), [int]($TimeoutSec / 60)) -ForegroundColor DarkGray
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $script:V8C -ArgumentList $argLine -PassThru
    $null = $process.Handle
    # Строка хода. У самопроверки - настоящая полоса по заданиям: последняя часть журнала в папке итога.
    $outDir = Split-Path -Parent $DoneFile
    $nextLook = 0
    $done = -1
    $total = 0
    $detail = ''
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSec -and -not (Test-Path -LiteralPath $DoneFile) -and -not $process.HasExited) {
        if ($watch.Elapsed.TotalSeconds -ge $nextLook) {
            $nextLook = $watch.Elapsed.TotalSeconds + 3
            $last = @(Get-ChildItem -LiteralPath $outDir -Filter 'p*.txt' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^p\d{6}\.txt$' } | Sort-Object Name | Select-Object -Last 1)
            if ($last.Count -gt 0) {
                try {
                    $header = @{}
                    $blocks = New-Object System.Collections.Generic.List[string]
                    foreach ($line in [System.IO.File]::ReadAllLines($last[0].FullName, [System.Text.Encoding]::UTF8)) {
                        $clean = $line.TrimStart([char]0xFEFF)
                        if ($clean -eq '@@journal') { break }
                        $position = $clean.IndexOf('=')
                        if (-not $clean.StartsWith('@@') -or $position -le 2) { continue }
                        if ($clean.StartsWith('@@block=')) { $blocks.Add($clean.Substring($position + 1)); continue }
                        $header[$clean.Substring(2, $position - 2)] = $clean.Substring($position + 1)
                    }
                    if ($header.ContainsKey('n') -and $header.ContainsKey('total')) {
                        $done = [int]$header['n']
                        $total = [int]$header['total']
                        $detail = 'задание {0} из {1}: {2}' -f ($done + 1), $total, $header['title']
                    }
                    # Шаги самопроверки - вторым трубопроводом в ci.exe.
                    if ($blocks.Count -gt 0) { Send-UiSubPlan -Title $Title -Current ([string]$header['step']) -Task ([string]$header['title']) -Blocks $blocks.ToArray() }
                }
                catch { }
            }
        }
        Write-UiProgress -Title $Title -Elapsed $watch.Elapsed.TotalSeconds -Expected (Get-StatPlan $Title) -Done $done -Total $total -Detail $detail
        Start-Sleep -Milliseconds 250
    }
    Complete-UiProgress
    $done = Test-Path -LiteralPath $DoneFile
    if ($done) { if (-not $process.WaitForExit(60000)) { try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { } } }
    elseif (-not $process.HasExited) { try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { } }
    $statStatus = 'TIMEOUT'
    if ($done) { $statStatus = 'OK' }
    Add-StatFact -Title $Title -Seconds $watch.Elapsed.TotalSeconds -Status $statStatus -Size ([Math]::Max(0, $total))
    return [pscustomobject]@{ Done = $done; Seconds = [int]$watch.Elapsed.TotalSeconds }
}

function Invoke-ProdProcessing {
    # Один сеанс «Выполнить после обновления» на рабочей базе в режиме regepf или unregepf - тот же, что у гейта
    # на temp. regepf: записать обработку в справочник «Дополнительные отчёты и обработки» (элемент с тем же
    # именем объекта обновляется, иначе добавляется новый); прежняя версия до записи ложится в old.b64 папки
    # OutDir, без неё обработка не заменяется. File - сам .epf/.erf, TextFile - уже base64 (откат из old.b64).
    # unregepf: снять обработку - по имени объекта и ссылке элемента вместе.
    param([string]$Mode, [string]$OutDir, [string]$File = '', [string]$TextFile = '', [string]$Name, [string]$Ref = '', [string]$Title)
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($Mode)
    $parts.Add(("out={0}" -f $OutDir))
    $parts.Add(("name={0}" -f $Name))
    if ($Mode -eq 'regepf') {
        $newB64 = Join-Path $OutDir 'new.b64'
        if ($TextFile) { Copy-Item -LiteralPath $TextFile -Destination $newB64 -Force }
        else { [System.IO.File]::WriteAllText($newB64, [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($File)), [System.Text.Encoding]::ASCII) }
        $parts.Add(("file={0}" -f $newB64))
    }
    if ($Ref) { $parts.Add(("ref={0}" -f $Ref)) }
    $resultFile = Join-Path $OutDir 'result.txt'
    $client = Invoke-ProdClient -Epf $selfCheckEpf -Parameter ($parts.ToArray() -join ';') -DoneFile $resultFile -TimeoutSec $processingTimeoutSec -Title $Title
    $values = @{}
    $formErrors = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $resultFile) {
        foreach ($line in @([System.IO.File]::ReadAllLines($resultFile, [System.Text.Encoding]::UTF8))) {
            $clean = ([string]$line).TrimStart([char]0xFEFF)
            $position = $clean.IndexOf('=')
            if ($position -le 0) { continue }
            $key = $clean.Substring(0, $position).Trim()
            if ($key -eq 'formerror') { $formErrors.Add($clean.Substring($position + 1)); continue }
            if (-not $values.ContainsKey($key)) { $values[$key] = $clean.Substring($position + 1) }
        }
    }
    $oldFile = Join-Path $OutDir 'old.b64'
    $savedOld = ''
    if (Test-Path -LiteralPath $oldFile) { $savedOld = $oldFile }
    $message = [string](Get-Setting $values 'message' '')
    if (-not $client.Done) {
        $message = ("за {0} с итога нет: обработка «Выполнить после обновления» не открылась или не успела (старая сборка без режимов regepf и unregepf, окно при запуске, нет входа)" -f $client.Seconds)
    }
    return [pscustomobject]@{
        Done = $client.Done; Status = [string](Get-Setting $values 'status' ''); Message = $message; Values = $values
        FormErrors = $formErrors.ToArray(); OldB64 = $savedOld; Seconds = $client.Seconds; ResultFile = $resultFile
    }
}

function Compare-Processings {
    # Внешние обработки temp против рабочей: изменённые в temp и новые. Те, что есть только в рабочей,
    # не трогаются: скрипт обновления обработки из рабочей не удаляет.
    param($TempExport, $ProdExport)
    $prodByName = @{}
    foreach ($item in $ProdExport.Items) { $prodByName[$item.ObjName] = $item }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($TempExport.Items | Sort-Object ObjName)) {
        $prodItem = $null
        if ($prodByName.ContainsKey($item.ObjName)) { $prodItem = $prodByName[$item.ObjName] }
        if ($null -ne $prodItem -and $prodItem.Hash -eq $item.Hash) { continue }
        $entry = [pscustomobject]@{
            ObjName = $item.ObjName; Title = $item.Title; FileName = (Split-Path -Leaf $item.File); TempFile = $item.File
            TempVersion = $item.Version; ProdVersion = ''; ProdFile = ''; Status = 'new'; Text = 'новая: в рабочей её нет'
        }
        if ($null -ne $prodItem) {
            $entry.ProdVersion = $prodItem.Version
            $entry.ProdFile = $prodItem.File
            $entry.Status = 'changed'
            $entry.Text = ("изменена в temp (рабочая {0}, temp {1})" -f $prodItem.Version, $item.Version)
        }
        $list.Add($entry)
    }
    return , @($list.ToArray())
}

function Get-ProcessingDump {
    # Файл обработки -> выгрузка в файлы (для разницы в отчёте). Конфигуратор нужен любой базы: берётся temp.
    # Не вышло - пустая строка, отчёт будет без разницы по модулям.
    param([string]$File, [string]$Dir, [string]$Title)
    if (-not $File -or -not (Test-Path -LiteralPath $File)) { return '' }
    if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force }
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $rootXml = Join-Path $Dir ([System.IO.Path]::GetFileNameWithoutExtension($File) + '.xml')
    $result = Invoke-Designer -BaseName $script:TempBase -Command @('/DumpExternalDataProcessorOrReportToFiles', ('"{0}"' -f $rootXml), ('"{0}"' -f $File)) `
        -LogName ("epfdump_{0}.log" -f (Split-Path -Leaf $Dir)) -TimeoutSec $timeoutLoadSec -Title $Title
    if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $rootXml)) {
        Write-RunLog ("Выгрузка {0} в файлы не получилась: {1}" -f $File, $result.Text)
        return ''
    }
    return $Dir
}

function Get-ProcessingStepTitle {
    # Имя шага записи обработки: одно и то же в плане ci.exe, в строке хода и в статистике длительностей.
    param($Proc)
    if ($Proc.Action -eq 'unregister') { return ("Снять из справочника {0}" -f $Proc.ObjName) }
    return ("Записать в справочник {0}" -f $Proc.ObjName)
}

function Write-ProcessingBackup {
    # Прежняя версия обработки (old.b64 сеанса regepf) - в before\processings\ как резервная копия этого обновления,
    # и рядом обычным файлом, чтобы её можно было открыть или загрузить руками. Возвращает путь копии base64.
    param($Proc, [string]$OldB64)
    $dir = Join-Path $beforeDir 'processings'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $target = Join-Path $dir ($Proc.ObjName + '.b64')
    Copy-Item -LiteralPath $OldB64 -Destination $target -Force
    try {
        $plain = Join-Path $dir ('прежняя_' + $Proc.FileName)
        [System.IO.File]::WriteAllBytes($plain, [Convert]::FromBase64String([System.IO.File]::ReadAllText($OldB64).Trim()))
    }
    catch { Write-RunLog ("Прежняя версия {0} не раскодировалась: {1}" -f $Proc.ObjName, $_.Exception.Message) }
    return $target
}
#endregion

#region Подтянуть из рабочей

# Подтянуть из рабочей: расширения или внешние обработки, которые в рабочей не такие, как в temp, - в inbox.
# Дальше с ними работают как с любым обновлением в inbox: меню гейта, «Прогон с обновлением из inbox».
if ($PullExtensions -or $PullProcessings) {
    if (-not (Test-UiCanAsk)) { throw 'подтянуть из рабочей можно только из консоли или ci.exe' }
    $inboxRoot = Resolve-RootPath ([string](Get-Setting $cfg 'InboxDir' 'inbox'))
    $pullStamp = Get-Date -Format 'yyyyMMdd-HHmm'

    if ($PullExtensions) {
        Write-Host ''
        Write-Host ("ПОДТЯНУТЬ РАСШИРЕНИЯ ИЗ {0}" -f $script:ProdBase) -ForegroundColor Cyan
        Write-Host '  Читаю расширения обеих баз через внешнее соединение (только чтение).' -ForegroundColor DarkGray
        $tempStates = Get-ExtensionStates -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword
        $prodStates = Get-ExtensionStates -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
        if (-not $prodStates.Ok) { throw ("расширения {0} не прочитал: {1}" -f $script:ProdBase, $prodStates.Error) }
        if (-not $tempStates.Ok) { Write-Line ("  {0} не прочитал ({1}): покажу все расширения рабочей" -f $script:TempBase, $tempStates.Error) 'Yellow' }
        $differ = New-Object System.Collections.Generic.List[object]
        foreach ($name in @($prodStates.Items.Keys | Sort-Object)) {
            $prodItem = $prodStates.Items[$name]
            $text = ''
            if (-not $tempStates.Ok) { $text = 'сравнить не удалось' }
            elseif (-not $tempStates.Items.ContainsKey($name)) { $text = "в $($script:TempBase) нет" }
            elseif ($tempStates.Items[$name].Hash -ne $prodItem.Hash) { $text = ("в рабочей другое (рабочая {0}, temp {1})" -f $prodItem.Version, $tempStates.Items[$name].Version) }
            else { Write-Line ("  {0}: одинаковое" -f $name) 'Green'; continue }
            Write-Line ("  {0}: {1}" -f $name, $text) 'Yellow'
            $differ.Add([pscustomobject]@{ Name = $name; Text = $text })
        }
        if ($differ.Count -eq 0) { Write-Line 'Все расширения рабочей такие же, как в temp: подтягивать нечего.' 'Green'; exit 0 }
        $labels = @($differ | ForEach-Object { '{0}  {1}' -f $_.Name, $_.Text })
        $picked = Select-UiMany -Header ("Какие расширения взять из {0} в inbox" -f $script:ProdBase) -Items $labels -Preselected @(0..($differ.Count - 1))
        if ($null -eq $picked) { Write-Host 'Выход, ничего не брал.'; exit 0 }
        $targetDir = Join-Path $inboxRoot ("из_рабочей_{0}" -f $pullStamp)
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $taken = 0
        foreach ($index in $picked) {
            $name = $differ[$index].Name
            $file = Join-Path $targetDir ("{0}_{1}_{2}.cfe" -f $script:ProdBase, $name, (Get-Date -Format 'yyyyMMdd'))
            if (Get-ExtensionData -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword -Name $name -Path $file) {
                Write-Line ("[OK]   Взять {0} из {1}: {2}" -f $name, $script:ProdBase, $file) 'Green'
                $taken++
            }
            else { Write-Line ("[FAIL] Взять {0} из {1}: не получилось, см. run.log" -f $name, $script:ProdBase) 'Red' }
        }
        Write-Host ''
        Write-Line ("Положил в inbox: {0} из {1}, папка {2}." -f $taken, $picked.Count, $targetDir)
        Write-Line 'Дальше: меню гейта, «Прогон с обновлением из inbox» - они там в списке.'
        exit 0
    }

    Write-Host ''
    Write-Host ("ПОДТЯНУТЬ ВНЕШНИЕ ОБРАБОТКИ ИЗ {0}" -f $script:ProdBase) -ForegroundColor Cyan
    Write-Host '  Выгружаю обработки и отчёты справочника «Дополнительные отчёты и обработки» обеих баз (только чтение).' -ForegroundColor DarkGray
    $prodExport = Export-Processings -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword -Dir (Join-Path $script:RunDir 'processings\prod')
    $tempExport = Export-Processings -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword -Dir (Join-Path $script:RunDir 'processings\temp')
    if (-not $prodExport.Ok) { throw ("обработки {0} не выгрузил: {1}" -f $script:ProdBase, $prodExport.Error) }
    if (-not $tempExport.Ok) { Write-Line ("  {0} не выгрузил ({1}): покажу все обработки рабочей" -f $script:TempBase, $tempExport.Error) 'Yellow' }
    $tempByName = @{}
    foreach ($item in $tempExport.Items) { $tempByName[$item.ObjName] = $item }
    $differ = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($prodExport.Items | Sort-Object ObjName)) {
        $text = ''
        if (-not $tempExport.Ok) { $text = 'сравнить не удалось' }
        elseif (-not $tempByName.ContainsKey($item.ObjName)) { $text = "в $($script:TempBase) нет" }
        elseif ($tempByName[$item.ObjName].Hash -ne $item.Hash) { $text = ("в рабочей другая (рабочая {0}, temp {1})" -f $item.Version, $tempByName[$item.ObjName].Version) }
        else { continue }
        $differ.Add([pscustomobject]@{ Item = $item; Text = $text })
    }
    Write-Line ("  обработок в рабочей: {0}, отличаются от temp: {1}" -f $prodExport.Items.Count, $differ.Count)
    if ($differ.Count -eq 0) { Write-Line 'Все обработки рабочей такие же, как в temp: подтягивать нечего.' 'Green'; exit 0 }
    $labels = @($differ | ForEach-Object { '{0} ({1})  {2}' -f $_.Item.ObjName, $_.Item.Title, $_.Text })
    $picked = Select-UiMany -Header ("Какие обработки взять из {0} в inbox" -f $script:ProdBase) -Items $labels -Preselected @(0..($differ.Count - 1))
    if ($null -eq $picked) { Write-Host 'Выход, ничего не брал.'; exit 0 }
    $targetDir = Join-Path $inboxRoot ("обработки_из_рабочей_{0}" -f $pullStamp)
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    foreach ($index in $picked) {
        $item = $differ[$index].Item
        Copy-Item -LiteralPath $item.File -Destination $targetDir -Force
        Write-Line ("[OK]   Взять {0} из {1}" -f $item.ObjName, $script:ProdBase) 'Green'
    }
    Write-Host ''
    Write-Line ("Положил в inbox: {0}, папка {1}." -f $picked.Count, $targetDir)
    Write-Line 'Дальше: меню гейта, «Прогон с обновлением из inbox» - гейт запишет их в справочник temp и проверит.'
    exit 0
}

#endregion

#region Итог последнего прогона гейта

$rollbackOf = ''
# Внешние обработки этого запуска. Action: register - записать (Source - файл, SourceB64 - уже base64),
# unregister - снять по имени объекта и ссылке (Ref).
$selectedProcessings = @()
if ($Rollback) {
    # Откат рабочей базы: к состоянию до выбранного обновления, из его резервных копий. Дальше - обычный путь
    # обновления (блокировки, резервные копии текущего состояния, загрузка, обновление БД, лёгкий прогон, отчёт).
    if (-not (Test-UiCanAsk)) { throw 'откат рабочей базы только из консоли или ci.exe: без человека скрипт ничего не откатывает' }
    $ciLines = New-Object System.Collections.Generic.List[string]
    $advice = New-Object System.Collections.Generic.List[object]
    $gateRisks = New-Object System.Collections.Generic.List[string]
    $gateRedItems = New-Object System.Collections.Generic.List[string]
    $lastRun = $null
    $lastVerdict = $null
    $riskAccepted = $false

    $history = @(Get-DeployHistory)
    Write-Host ''
    Write-Host ("ОТКАТ {0}" -f $script:ProdBase) -ForegroundColor Cyan

    # Экран отката - всегда: сверху большая красная кнопка «Откатить последние изменения» (сразу из резервных
    # копий, снятых перед последним обновлением), под ней - последние обновления рабочей с результатами
    # лёгкого прогона. Обновлений ещё не было - экран так и говорит, кнопка ничего не делает.
    $target = $null
    while ($null -eq $target) {
        $items = New-Object System.Collections.Generic.List[string]
        $notes = @()
        if ($history.Count -gt 0) {
            $items.Add(("ОТКАТИТЬ ПОСЛЕДНИЕ ИЗМЕНЕНИЯ - к состоянию до обновления {0:dd.MM.yyyy HH:mm}" -f [datetime]::ParseExact([string]$history[0].runId, 'yyyyMMdd-HHmmss', $null)))
            foreach ($record in $history) { $items.Add((Get-DeployLabel $record)) }
            $notes += 'Выбери обновление, чтобы посмотреть подробно и откатить именно его.'
        }
        else {
            $items.Add('ОТКАТИТЬ ПОСЛЕДНИЕ ИЗМЕНЕНИЯ - не к чему: обновлений рабочей скриптом ещё не было')
            $notes += ("Обновлений {0} скриптом обновления ещё не было: резервных копий перед обновлением нет, откатывать не к чему." -f $script:ProdBase)
            $notes += 'Список появится после первого «Обновить рабочую базу» - каждое обновление сохраняет резервные копии и итог лёгкого прогона.'
        }
        $items.Add('Отмена')
        $index = Select-UiOne -Header ("Откат {0}: последние обновления" -f $script:ProdBase) -Items $items.ToArray() -Notes $notes -Danger @(0)
        if ($index -lt 0 -or $index -eq $items.Count - 1) { Write-Host 'Выход, ничего не откатывал.'; exit 0 }
        if ($history.Count -eq 0) { continue }
        if ($index -eq 0) { $target = $history[0]; break }
        # Подробно об обновлении - и две кнопки на том же экране: «Откатить» и «Отмена».
        $record = $history[$index - 1]
        $action = Select-UiOne -Header ("Обновление {0}" -f (Get-DeployLabel $record)) -Notes @(Get-DeployDetailLines -Record $record -History $history | ForEach-Object { if ($_) { $_ } else { ' ' } }) `
            -Items @('Откатить', 'Отмена') -Danger @(0)
        if ($action -eq 0) { $target = $record }
    }

    # Что вернётся: расширения обновления с резервной копией. Без копии (новые) откатом не удаляются.
    $selected = @()
    $skippedNew = @()
    foreach ($item in @(Get-JsonValue $target 'extensions' @())) {
        $backupPath = ''
        if ($item.backup) { $backupPath = Join-Path $target.Dir $item.backup }
        if (-not $backupPath) { $skippedNew += [string]$item.name; continue }
        if (-not (Test-Path -LiteralPath $backupPath)) { throw ("нет резервной копии {0}: откат {1} невозможен" -f $backupPath, $target.runId) }
        $name = [string]$item.name
        $selected += [pscustomobject]@{ Name = $name; Status = 'changed'; Text = 'откат'
            TempDir = (Join-Path (Join-Path $mirrorRoot $script:TempBase) $name); ProdDir = (Join-Path (Join-Path $mirrorRoot $script:ProdBase) $name)
            TempVersion = [string]$item.oldVersion; ProdVersion = [string]$item.newVersion; Changed = 0; SnapshotDir = ''; SnapshotTime = ''
            ProdPresent = $true; ProdText = ''; ProdChanged = -1; InTemp = $false
            Backup = ''; NewFile = $backupPath; Loaded = $false; OldDir = ''; NewDir = ''; RollbackDir = '' }
    }
    # Внешние обработки того обновления: прежняя версия записывается обратно, новая снимается из справочника.
    $skippedProcessings = @()
    foreach ($item in @(Get-JsonValue $target 'processings' @())) {
        $objName = [string](Get-JsonValue $item 'name' '')
        $fileName = [string](Get-JsonValue $item 'fileName' '')
        $backup = [string](Get-JsonValue $item 'backup' '')
        $ref = [string](Get-JsonValue $item 'ref' '')
        $action = [string](Get-JsonValue $item 'action' 'register')
        $entry = [pscustomobject]@{ ObjName = $objName; Title = [string](Get-JsonValue $item 'title' ''); FileName = $fileName; TempFile = ''
            TempVersion = [string](Get-JsonValue $item 'oldVersion' ''); ProdVersion = [string](Get-JsonValue $item 'newVersion' ''); ProdFile = ''
            Status = 'changed'; Text = 'откат'; Action = 'register'; Source = ''; SourceB64 = ''; Ref = '' }
        if ($action -eq 'unregister') {
            # Тот запуск снял обработку: откат записывает её снова из файла, который тогда сняли.
            $file = [string](Get-JsonValue $item 'file' '')
            if ($file -and (Test-Path -LiteralPath (Join-Path $target.Dir $file))) { $entry.Source = Join-Path $target.Dir $file; $selectedProcessings += $entry }
            else { $skippedProcessings += $objName }
            continue
        }
        if ($backup) {
            $backupPath = Join-Path $target.Dir $backup
            if (-not (Test-Path -LiteralPath $backupPath)) { throw ("нет резервной копии {0}: откат {1} невозможен" -f $backupPath, $target.runId) }
            $entry.SourceB64 = $backupPath
            $selectedProcessings += $entry
        }
        elseif ([string](Get-JsonValue $item 'isNew' '') -eq 'yes' -and $ref) {
            $entry.Action = 'unregister'
            $entry.Ref = $ref
            $entry.Status = 'new'
            $file = [string](Get-JsonValue $item 'file' '')
            if ($file) { $entry.TempFile = Join-Path $target.Dir $file }
            $selectedProcessings += $entry
        }
        else { $skippedProcessings += $objName }
    }
    if ($selected.Count -eq 0 -and $selectedProcessings.Count -eq 0) { Write-Line 'В этом обновлении нет ни расширений, ни обработок с резервной копией: откатывать нечего.' 'Yellow'; exit 0 }

    $returned = @(@($selected | ForEach-Object { $_.Name }) + @($selectedProcessings | Where-Object { $_.Action -eq 'register' } | ForEach-Object { $_.ObjName }))
    $question = "Точно откатить {0} к состоянию до обновления {1}? Вернутся: {2}." -f $script:ProdBase, (Get-DeployLabel $target), ($returned -join ', ')
    $removed = @($selectedProcessings | Where-Object { $_.Action -eq 'unregister' } | ForEach-Object { $_.ObjName })
    if ($removed.Count -gt 0) { $question += (" Снимутся из справочника новые обработки: {0}." -f ($removed -join ', ')) }
    if ($skippedNew.Count -gt 0) { $question += (" Новые в том обновлении ({0}) останутся: удалять их - руками." -f ($skippedNew -join ', ')) }
    if ($skippedProcessings.Count -gt 0) { $question += (" Обработки без резервной копии ({0}) останутся как есть." -f ($skippedProcessings -join ', ')) }
    $sure = Confirm-Ui -Question $question -Yes 'Да, откатить' -No 'Отмена'
    if ($sure -ne $true) { Write-Host 'Выход, ничего не откатывал.'; exit 0 }
    $mode = 'rollback'
    $rollbackOf = [string]$target.runId
    $ciLines.Add(("Откат к состоянию до обновления {0} ({1})." -f $target.runId, (Get-DeployLabel $target)))
    $rollbackNames = @(@($selected | ForEach-Object { $_.Name }) + @($selectedProcessings | ForEach-Object { $_.ObjName })) -join ', '
    Write-RunLog ("Откат к состоянию до {0}: {1}" -f $target.runId, $rollbackNames)
    Write-Host ''
    Write-Line ("Откатываю {0} к состоянию до {1}: {2}" -f $script:ProdBase, $target.runId, $rollbackNames) 'Cyan'
}
else {
    $lastRun = $null
    $lastVerdict = $null
    if (Test-Path -LiteralPath $runsRoot) {
        $candidates = @(Get-ChildItem -LiteralPath $runsRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending)
        foreach ($candidate in $candidates) {
            $verdictFile = Join-Path $candidate.FullName 'verdict.json'
            if (Test-Path -LiteralPath $verdictFile) {
                $lastRun = $candidate
                $lastVerdict = (Get-Content -LiteralPath $verdictFile -Raw -Encoding UTF8) | ConvertFrom-Json
                break
            }
        }
    }

    $ciLines = New-Object System.Collections.Generic.List[string]     # для отчёта
    $advice = New-Object System.Collections.Generic.List[object]      # рекомендации: Kind = do / dont / note
    # Итог гейта - справочно: обновлять или нет, решает человек. Но если гейта нет, он красный или его комплект
    # откатили - перед обновлением переспросить, а красное из гейта унести в отчёт с пометкой «проверить».
    $gateRisks = New-Object System.Collections.Generic.List[string]
    $gateRedItems = New-Object System.Collections.Generic.List[string]

    Write-Host ''
    Write-Host 'ПОСЛЕДНИЙ ПРОГОН ГЕЙТА' -ForegroundColor Cyan
    if ($null -eq $lastRun) {
        Write-Line '  прогонов гейта нет' 'Yellow'
        $ciLines.Add('Прогонов гейта нет.')
        $gateRisks.Add('прогонов гейта нет')
        $advice.Add([pscustomobject]@{ Kind = 'dont'; Text = 'не обновлять, пока комплект не прошёл гейт: .\run.cmd -Kit inbox\<дата>' })
    }
    else {
        $verdict = [string](Get-JsonValue $lastVerdict 'verdict' '')
        $decision = [string](Get-JsonValue $lastVerdict 'kitDecision' '')
        $kitText = [string](Get-JsonValue $lastVerdict 'kit' '')
        $runTime = [datetime]::ParseExact($lastRun.Name, 'yyyyMMdd-HHmmss', $null)
        $ageHours = [int]((Get-Date) - $runTime).TotalHours
        $verdictName = @{ GREEN = 'ЗЕЛЁНЫЙ'; YELLOW = 'ЖЁЛТЫЙ'; RED = 'КРАСНЫЙ' }
        $verdictText = $verdict
        if ($verdictName.ContainsKey($verdict)) { $verdictText = $verdictName[$verdict] }
        $color = 'Gray'
        if ($verdict -eq 'GREEN') { $color = 'Green' } elseif ($verdict -eq 'YELLOW') { $color = 'Yellow' } elseif ($verdict -eq 'RED') { $color = 'Red' }
        Write-Line ("  {0}, {1} ч назад, вердикт {2}" -f $lastRun.Name, $ageHours, $verdictText) $color
        $ciLines.Add(("Прогон гейта {0} ({1} ч до обновления): вердикт {2}." -f $lastRun.Name, $ageHours, $verdictText))
        if ($kitText) { Write-Line ("  комплект: {0}" -f $kitText); $ciLines.Add(("Комплект: {0}." -f $kitText)) }
        $decisionNames = @{ kept = 'оставлен в базе'; rolledBack = 'откачен'; rollbackFailed = 'откат прошёл не полностью' }
        if ($decision -and $decisionNames.ContainsKey($decision)) { Write-Line ("  комплект после вердикта: {0}" -f $decisionNames[$decision]) }

        $badSteps = @(@(Get-JsonValue $lastVerdict 'steps' @()) | Where-Object { $_.status -eq 'FAIL' -or $_.status -eq 'WARN' })
        foreach ($step in $badSteps) {
            $stepColor = 'Yellow'
            if ($step.status -eq 'FAIL') { $stepColor = 'Red' }
            Write-Line ("  [{0}] {1}" -f $step.status, $step.name) $stepColor
            $ciLines.Add(("[{0}] {1}" -f $step.status, $step.name))
        }

        # Короткая часть разбора прогона.
        $reportFile = Join-Path $lastRun.FullName 'report.txt'
        if (Test-Path -LiteralPath $reportFile) {
            $inShort = $false
            foreach ($line in @([System.IO.File]::ReadAllLines($reportFile, [System.Text.Encoding]::UTF8))) {
                if ($line -eq 'КОРОТКО') { $inShort = $true; Write-Host '  Разбор, коротко:'; continue }
                if ($inShort) {
                    if ([string]::IsNullOrWhiteSpace($line)) { break }
                    Write-Host ('  ' + $line)
                    $ciLines.Add($line.Trim())
                }
            }
        }

        # Красное из гейта: упавшие шаги и красные строки разбора.
        if ($verdict -eq 'RED') { $gateRisks.Add(("гейт {0} красный" -f $lastRun.Name)) }
        if ($decision -eq 'rolledBack' -or $decision -eq 'rollbackFailed') { $gateRisks.Add('комплект последнего прогона гейта откатили: в temp не то, что он проверял') }
        foreach ($step in @($badSteps | Where-Object { $_.status -eq 'FAIL' })) {
            $detail = [string](Get-JsonValue $step 'detail' '')
            if ($detail) { $gateRedItems.Add(("{0}: {1}" -f $step.name, $detail)) } else { $gateRedItems.Add([string]$step.name) }
        }
        if (Test-Path -LiteralPath $reportFile) {
            foreach ($line in @([System.IO.File]::ReadAllLines($reportFile, [System.Text.Encoding]::UTF8))) {
                if ($line.TrimStart().StartsWith('[КРАСН]') -and $gateRedItems.Count -lt 40) { $gateRedItems.Add($line.Trim()) }
            }
        }

        # Рекомендации по итогу прогона.
        if ($decision -eq 'rolledBack' -or $decision -eq 'rollbackFailed') {
            $advice.Add([pscustomobject]@{ Kind = 'dont'; Text = 'комплект последнего прогона откатили: в temp сейчас не то, что проверял гейт. Сначала прогон гейта заново' })
        }
        if ($verdict -eq 'GREEN') {
            $advice.Add([pscustomobject]@{ Kind = 'do'; Text = 'гейт зелёный: можно обновлять. Перед этим пройти сценарий проверки на temp, если он есть' })
        }
        elseif ($verdict -eq 'YELLOW') {
            $advice.Add([pscustomobject]@{ Kind = 'do'; Text = 'гейт жёлтый: посмотреть новое в report.txt. Если допустимо - обновлять' })
        }
        elseif ($verdict -eq 'RED') {
            $advice.Add([pscustomobject]@{ Kind = 'dont'; Text = 'гейт красный: не обновлять, пока ошибки не исправлены или не признаны неважными' })
        }
        if (@($badSteps | Where-Object { $_.status -eq 'FAIL' -and ([string]$_.name).StartsWith('Обновить конфигурацию БД') }).Count -gt 0) {
            $advice.Add([pscustomobject]@{ Kind = 'dont'; Text = 'в temp не прошло обновление конфигурации БД: расширение загружено, но к базе не применено и не проверено. Сначала довести гейт' })
        }
        if (@($badSteps | Where-Object { ([string]$_.name).StartsWith('Канареечный вход') -and $_.status -eq 'FAIL' }).Count -gt 0) {
            $advice.Add([pscustomobject]@{ Kind = 'dont'; Text = 'в temp не удался вход: в рабочей будет так же' })
        }
        if ($ageHours -gt 24) {
            $advice.Add([pscustomobject]@{ Kind = 'note'; Text = ("прогону {0} ч: если temp с тех пор меняли, сначала новый прогон гейта" -f $ageHours) })
        }
    }
    $advice.Add([pscustomobject]@{ Kind = 'dont'; Text = ("не обновлять с {0}:00 до {1:00}:00 и в рабочее время: обновлению нужен монопольный доступ к {2}" -f $deniedFrom, $deniedTo, $script:ProdBase) })

    #endregion

    #region Сравнение расширений temp и рабочей

    Write-Host ''
    Write-Host ("РАСШИРЕНИЯ: {0} ПРОТИВ {1}" -f $script:TempBase, $script:ProdBase) -ForegroundColor Cyan

    # Сравнение по хеш-суммам через COM: на этом шаге в рабочую базу конфигуратор не заходит. Выгрузки в файлы
    # (для отчёта об изменениях) - потом, внутри обновления, когда рабочая база уже заблокирована.
    Write-Host '  Читаю расширения обеих баз через внешнее соединение (только чтение).' -ForegroundColor DarkGray
    $tempStates = Get-ExtensionStates -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword
    $prodStates = Get-ExtensionStates -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
    if (-not $tempStates.Ok) { Write-Line ("  {0}: не прочитал - {1}" -f $script:TempBase, $tempStates.Error) 'Yellow' }
    if (-not $prodStates.Ok) { Write-Line ("  {0}: не прочитал - {1}" -f $script:ProdBase, $prodStates.Error) 'Yellow' }

    $extensions = New-Object System.Collections.Generic.List[object]
    foreach ($name in $deployExtensions) {
        $name = [string]$name
        $tempDir = Join-Path (Join-Path $mirrorRoot $script:TempBase) $name
        $prodDir = Join-Path (Join-Path $mirrorRoot $script:ProdBase) $name
        $entry = [pscustomobject]@{ Name = $name; Status = ''; Text = ''; TempDir = $tempDir; ProdDir = $prodDir; TempVersion = ''; ProdVersion = ''; Changed = 0
            SnapshotDir = ''; SnapshotTime = ''; ProdPresent = $false; ProdText = ''; ProdChanged = -1; InTemp = $false }

        $inTemp = $tempStates.Ok -and $tempStates.Items.ContainsKey($name)
        $inProd = $prodStates.Ok -and $prodStates.Items.ContainsKey($name)
        if ($inTemp) { $entry.TempVersion = $tempStates.Items[$name].Version }
        if ($inProd) { $entry.ProdVersion = $prodStates.Items[$name].Version }
        $entry.InTemp = $inTemp -or -not $tempStates.Ok
        $entry.ProdPresent = $inProd -or (-not $prodStates.Ok -and (Test-Path -LiteralPath (Join-Path $prodDir 'Configuration.xml')))

        # Что в рабочей поменялось с прошлого раза (для «как есть»): хеш сейчас против хеша при прошлой выгрузке.
        if ($inProd) {
            $savedHash = Get-MirrorHash $prodDir
            if (-not $savedHash) { $entry.ProdText = 'прежнего состояния рабочей нет: что изменилось в ней, не сравнить' }
            elseif ($savedHash -eq $prodStates.Items[$name].Hash) { $entry.ProdChanged = 0; $entry.ProdText = 'в рабочей без изменений с прошлого обновления' }
            else { $entry.ProdChanged = 1; $entry.ProdText = 'в рабочей изменено после прошлого обновления (загружали руками?)' }
        }

        if (-not $tempStates.Ok -or -not $prodStates.Ok) {
            $entry.Status = 'unknown'
            $entry.Text = 'сравнить не удалось (см. выше): можно обновить, отчёт покажет разницу'
        }
        elseif (-not $inTemp -and -not $inProd) { $entry.Status = 'absent'; $entry.Text = 'нет ни в temp, ни в рабочей' }
        elseif (-not $inTemp) { $entry.Status = 'noTemp'; $entry.Text = "в $($script:TempBase) нет" }
        elseif (-not $inProd) { $entry.Status = 'new'; $entry.Text = "есть только в $($script:TempBase), в рабочей его ещё нет" }
        elseif ($tempStates.Items[$name].Hash -and $tempStates.Items[$name].Hash -eq $prodStates.Items[$name].Hash) { $entry.Status = 'same'; $entry.Text = 'одинаковое' }
        else { $entry.Status = 'changed'; $entry.Text = "изменено в $($script:TempBase), в рабочей - прежнее" }
        $extensions.Add($entry)
    }

    $pending = @($extensions | Where-Object { $_.Status -eq 'changed' -or $_.Status -eq 'new' -or $_.Status -eq 'unknown' })
    $fromTemp = @($extensions | Where-Object { $_.InTemp -and $_.Status -ne 'noTemp' -and $_.Status -ne 'absent' })
    foreach ($entry in $extensions) {
        $color = 'Gray'
        if ($entry.Status -eq 'changed' -or $entry.Status -eq 'new' -or $entry.Status -eq 'unknown') { $color = 'Yellow' }
        if ($entry.Status -eq 'same') { $color = 'Green' }
        $versions = ''
        if ($entry.TempVersion -or $entry.ProdVersion) { $versions = (" (рабочая {0}, temp {1})" -f $entry.ProdVersion, $entry.TempVersion) }
        Write-Line ("  {0}: {1}{2}" -f $entry.Name, $entry.Text, $versions) $color
        if ($entry.ProdText) {
            $prodColor = 'DarkGray'
            if ($entry.ProdChanged -gt 0) { $prodColor = 'Yellow' }
            Write-Line ("      {0}" -f $entry.ProdText) $prodColor
        }
    }
    $asisCandidates = @($extensions | Where-Object { $_.ProdPresent })
    if (@($asisCandidates | Where-Object { $_.ProdChanged -gt 0 }).Count -gt 0) {
        $advice.Add([pscustomobject]@{ Kind = 'note'; Text = 'в рабочей конфигурации расширений есть изменения с прошлой выгрузки: если их загрузили руками - «Обновить как есть»' })
    }
    if ($pending.Count -eq 0) {
        $advice.Add([pscustomobject]@{ Kind = 'note'; Text = 'по хеш-суммам расширения в рабочей такие же, как в temp: обновлять нечего (загрузить всё равно можно - «Обновить выбранные»)' })
    }
    foreach ($entry in @($pending | Where-Object { $_.Status -eq 'new' })) {
        $advice.Add([pscustomobject]@{ Kind = 'note'; Text = ("{0} в рабочую придёт впервые: после загрузки проверить у него «Безопасный режим» и «Защиту от опасных действий»" -f $entry.Name) })
    }

    # Внешние обработки и отчёты: файлы из справочника обеих баз, сравнение по хешу файла. Только чтение.
    Write-Host ''
    Write-Host ("ВНЕШНИЕ ОБРАБОТКИ: {0} ПРОТИВ {1}" -f $script:TempBase, $script:ProdBase) -ForegroundColor Cyan
    Write-Host '  Выгружаю обработки и отчёты справочника «Дополнительные отчёты и обработки» обеих баз (только чтение).' -ForegroundColor DarkGray
    $processingsPending = @()
    $tempProcExport = Export-Processings -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword -Dir (Join-Path $script:RunDir 'processings\temp')
    $prodProcExport = Export-Processings -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword -Dir (Join-Path $script:RunDir 'processings\prod')
    if (-not $tempProcExport.Ok) { Write-Line ("  {0}: не выгрузил - {1}" -f $script:TempBase, $tempProcExport.Error) 'Yellow' }
    if (-not $prodProcExport.Ok) { Write-Line ("  {0}: не выгрузил - {1}" -f $script:ProdBase, $prodProcExport.Error) 'Yellow' }
    if ($tempProcExport.Ok -and $prodProcExport.Ok) {
        # Сравнить не удалось - обработки не предлагаются: вслепую в рабочую их не пишем.
        $processingsPending = Compare-Processings -TempExport $tempProcExport -ProdExport $prodProcExport
        Write-Line ("  в {0}: {1}, в {2}: {3}, изменены или новые в temp: {4}" -f $script:TempBase, $tempProcExport.Items.Count, $script:ProdBase, $prodProcExport.Items.Count, $processingsPending.Count)
        foreach ($proc in $processingsPending) { Write-Line ("  {0} ({1}): {2}" -f $proc.ObjName, $proc.Title, $proc.Text) 'Yellow' }
        if ($processingsPending.Count -gt 0 -and -not (Test-Path -LiteralPath $selfCheckEpf)) {
            $advice.Add([pscustomobject]@{ Kind = 'note'; Text = ("внешние обработки записывать нечем: нет {0} (SelfCheckEpf)" -f $selfCheckEpf) })
            $processingsPending = @()
        }
    }
    else {
        $advice.Add([pscustomobject]@{ Kind = 'note'; Text = 'внешние обработки сравнить не удалось: в этот раз они не обновляются' })
    }

    Write-Host ''
    Write-Host 'ЧТО ДАЛЬШЕ' -ForegroundColor Cyan
    foreach ($item in $advice) {
        $prefix = '  • '
        $color = 'Gray'
        if ($item.Kind -eq 'do') { $prefix = '  можно: '; $color = 'Green' }
        if ($item.Kind -eq 'dont') { $prefix = '  не советую: '; $color = 'Red' }
        Write-Line ($prefix + $item.Text) $color
    }

    if ($StatusOnly) {
        Write-Host ''
        Write-Host 'Только просмотр (-StatusOnly): ничего не обновляю.'
        exit 0
    }

    #endregion

    #region Что обновлять

    if (-not (Test-UiCanAsk)) { throw 'обновление рабочей базы только из консоли: без человека скрипт ничего не обновляет' }

    # Кнопки - всегда, что бы ни показал гейт и сравнение: решает человек.
    # «Все» - все необновлённые (изменённые в temp, новые, несравнённые); если таких нет - все из temp заново.
    # «Выбранные» - список необновленных, галочки ставит человек. Замечания гейта после «Обновить все»
    # сбрасываются (принимаются в эталон): они либо исправлены, либо неважны.
    $allTargets = @($pending)
    if ($allTargets.Count -eq 0) { $allTargets = @($fromTemp) }
    $modeMenu = New-Object System.Collections.Generic.List[object]
    $modeMenu.Add([pscustomobject]@{ Key = '1'; Label = ("Обновить все расширения из {0} в {1} ({2}); ошибки гейта сбросятся" -f $script:TempBase, $script:ProdBase, (@($allTargets | ForEach-Object { $_.Name }) -join ', ')) })
    $modeMenu.Add([pscustomobject]@{ Key = '2'; Label = 'Обновить выбранные расширения' })
    if ($processingsPending.Count -gt 0) {
        $modeMenu.Add([pscustomobject]@{ Key = 'epf'; Label = ("Обновить только внешние обработки ({0}): без блокировок рабочей и обновления конфигурации БД" -f $processingsPending.Count) })
    }
    $modeMenu.Add([pscustomobject]@{ Key = 'asis'; Label = 'Обновить как есть: ничего не загружать, только обновить конфигурацию БД (изменения уже загружены руками)' })
    $modeMenu.Add([pscustomobject]@{ Key = 'exit'; Label = 'Выход' })
    $modeNotes = @()
    if ($pending.Count -eq 0 -and $fromTemp.Count -gt 0) { $modeNotes += 'необновлённых нет: в рабочей всё как в temp. «Обновить все» загрузит их заново' }
    if ($fromTemp.Count -eq 0) { $modeNotes += 'в temp нет ни одного расширения из DeployExtensions: загружать из temp неоткуда' }
    $modeIndex = Select-UiOne -Header ("Обновление {0}" -f $script:ProdBase) -Items @($modeMenu | ForEach-Object { $_.Label }) -Notes $modeNotes
    if ($modeIndex -lt 0 -or $modeMenu[$modeIndex].Key -eq 'exit') { Write-Host 'Выход, ничего не обновлял.'; exit 0 }
    $mode = $modeMenu[$modeIndex].Key
    if (($mode -eq '1' -or $mode -eq '2') -and $fromTemp.Count -eq 0 -and $processingsPending.Count -eq 0) { Write-Host 'В temp нечего брать: выход, ничего не обновлял.'; exit 0 }

    $selected = @()
    if ($mode -eq '1') {
        $selected = @($allTargets)
    }
    elseif ($mode -eq 'epf') {
        $selected = @()
    }
    elseif ($mode -eq 'asis') {
        # Отмечены те, что изменились в рабочей с прошлой выгрузки; если таких нет или сравнить не с чем - все.
        if ($asisCandidates.Count -eq 0) { $asisCandidates = @($extensions) }
        $labels = @($asisCandidates | ForEach-Object { '{0}  {1}' -f $_.Name, (@($_.ProdText, 'в рабочей не найдено') | Where-Object { $_ } | Select-Object -First 1) })
        $preselected = @()
        for ($i = 0; $i -lt $asisCandidates.Count; $i++) { if ($asisCandidates[$i].ProdChanged -gt 0) { $preselected += $i } }
        if ($preselected.Count -eq 0) { $preselected = @(0..($asisCandidates.Count - 1)) }
        $picked = Select-UiMany -Header 'Каким расширениям обновить конфигурацию БД' -Items $labels -Preselected $preselected
        if ($null -eq $picked) { Write-Host 'Выход, ничего не обновлял.'; exit 0 }
        $selected = @($picked | Sort-Object | ForEach-Object { $asisCandidates[$_] })
    }
    else {
        # Список необновленных расширений; галочки ставит человек. Необновлённых нет - список всех из temp.
        $choices = @($pending)
        $header = ("Какие необновлённые расширения загрузить из {0} в {1}" -f $script:TempBase, $script:ProdBase)
        if ($choices.Count -eq 0) { $choices = @($fromTemp); $header = ("Необновлённых нет. Какие расширения загрузить из {0} в {1} заново" -f $script:TempBase, $script:ProdBase) }
        $labels = @($choices | ForEach-Object { '{0}  {1}' -f $_.Name, $_.Text })
        $picked = Select-UiMany -Header $header -Items $labels
        if ($null -eq $picked) { Write-Host 'Выход, ничего не обновлял.'; exit 0 }
        $selected = @($picked | Sort-Object | ForEach-Object { $choices[$_] })
    }

    # Внешние обработки - отдельным списком после расширений. «Все» и «Только обработки» - отмечены все,
    # «Выбранные» - ни одной. В «как есть» обработки не трогаются.
    if ($mode -ne 'asis' -and $processingsPending.Count -gt 0) {
        $procLabels = @($processingsPending | ForEach-Object { '{0} ({1})  {2}' -f $_.ObjName, $_.Title, $_.Text })
        $procPreselected = @()
        if ($mode -eq '1' -or $mode -eq 'epf') { $procPreselected = @(0..($processingsPending.Count - 1)) }
        $procPicked = Select-UiMany -Header ("Какие внешние обработки записать в {0}" -f $script:ProdBase) -Items $procLabels -Preselected $procPreselected
        if ($null -eq $procPicked) { Write-Host 'Выход, ничего не обновлял.'; exit 0 }
        $selectedProcessings = @($procPicked | Sort-Object | ForEach-Object { $processingsPending[$_] })
    }
    if ($selected.Count -eq 0 -and $selectedProcessings.Count -eq 0) { Write-Host 'Ничего не выбрано: выход, ничего не обновлял.'; exit 0 }
    foreach ($proc in $selectedProcessings) {
        $proc | Add-Member -NotePropertyName Action -NotePropertyValue 'register' -Force
        $proc | Add-Member -NotePropertyName Source -NotePropertyValue $proc.TempFile -Force
        $proc | Add-Member -NotePropertyName SourceB64 -NotePropertyValue '' -Force
        $proc | Add-Member -NotePropertyName Ref -NotePropertyValue '' -Force
    }

    # Что с чем сравнивает отчёт и чем откатывать. Из temp: было - рабочая, стало - temp, откат - резервная копия .cfe.
    # Как есть: было - прежняя выгрузка рабочей (до ручной загрузки), стало - рабочая сейчас, откат - загрузка
    # прежней выгрузки из файлов.
    foreach ($entry in $selected) {
        $entry | Add-Member -NotePropertyName Backup -NotePropertyValue '' -Force
        $entry | Add-Member -NotePropertyName NewFile -NotePropertyValue '' -Force
        $entry | Add-Member -NotePropertyName Loaded -NotePropertyValue $false -Force
        if ($mode -eq 'asis') {
            $entry | Add-Member -NotePropertyName OldDir -NotePropertyValue $entry.SnapshotDir -Force
            $entry | Add-Member -NotePropertyName NewDir -NotePropertyValue $entry.ProdDir -Force
            $entry | Add-Member -NotePropertyName RollbackDir -NotePropertyValue $entry.SnapshotDir -Force
        }
        else {
            $entry | Add-Member -NotePropertyName OldDir -NotePropertyValue $entry.ProdDir -Force
            $entry | Add-Member -NotePropertyName NewDir -NotePropertyValue $entry.TempDir -Force
            $entry | Add-Member -NotePropertyName RollbackDir -NotePropertyValue '' -Force
        }
    }

    # Порядок - как в DeployExtensions (нижний слой первым).
    Write-Host ''
    if ($mode -eq 'asis') { Write-Line ("Обновляю конфигурацию БД {0} как есть: {1}" -f $script:ProdBase, (@($selected | ForEach-Object { $_.Name }) -join ', ')) 'Cyan' }
    elseif ($selected.Count -gt 0) { Write-Line ("Обновляю в {0}: {1}" -f $script:ProdBase, (@($selected | ForEach-Object { $_.Name }) -join ', ')) 'Cyan' }
    if ($selectedProcessings.Count -gt 0) { Write-Line ("Внешние обработки в {0}: {1}" -f $script:ProdBase, (@($selectedProcessings | ForEach-Object { $_.ObjName }) -join ', ')) 'Cyan' }

    # Гейт красный, его нет или комплект откатили: переспросить. Да - едем, красное гейта уходит в отчёт.
    $riskAccepted = $false
    if ($gateRisks.Count -gt 0) {
        $question = "Обновить {0}, хотя {1}? Красное из гейта попадёт в отчёт с пометкой «проверить работоспособность»." -f $script:ProdBase, ($gateRisks -join '; ')
        $sure = Confirm-Ui -Question $question -Yes 'Да, обновлять' -No 'Нет, выйти'
        if ($sure -ne $true) { Write-Host 'Выход, ничего не обновлял.'; exit 0 }
        $riskAccepted = $true
        Write-RunLog ('Обновление несмотря на: ' + ($gateRisks -join '; '))
        Write-Line ("  Обновляю, несмотря на: {0}" -f ($gateRisks -join '; ')) 'Yellow'
    }
}

$hour = (Get-Date).Hour
$inDenied = $false
if ($deniedFrom -gt $deniedTo) { $inDenied = ($hour -ge $deniedFrom -or $hour -lt $deniedTo) }
else { $inDenied = ($hour -ge $deniedFrom -and $hour -lt $deniedTo) }
if ($inDenied) { throw ("сейчас {0}: с {1}:00 до {2}:00 рабочую базу не обновляем" -f (Get-Date -Format 'HH:mm'), $deniedFrom, $deniedTo) }

Write-Host ("  Это рабочая база. Чтобы продолжить, набери её имя ({0}) и Enter:" -f $script:ProdBase) -ForegroundColor Yellow
$typedName = Read-UiText -Prompt ("Это рабочая база. Чтобы продолжить, набери её имя ({0})" -f $script:ProdBase)
if ($typedName -cne $script:ProdBase) { throw 'имя базы набрано не так: обновление отменено' }
Write-RunLog 'Подтверждено именем базы'

#endregion

#region Подготовка рабочей базы

# План обновления для ci.exe: шаги, которые пойдут, если ничего не упадёт.
$planSteps = New-Object System.Collections.Generic.List[string]
if ($selected.Count -gt 0) { $planSteps.Add('Подготовка рабочей базы') }
foreach ($planEntry in $selected) {
    $planSteps.Add(("Выгрузить {0} из {1}" -f $planEntry.Name, $script:ProdBase))
    if ($mode -ne 'asis' -and $mode -ne 'rollback') { $planSteps.Add(("Выгрузить {0} из {1}" -f $planEntry.Name, $script:TempBase)) }
}
if ($mode -ne 'asis') {
    foreach ($planEntry in $selected) {
        if ($planEntry.ProdPresent) { $planSteps.Add(("Резервная копия {0}" -f $planEntry.Name)) }
        if ($mode -ne 'rollback') { $planSteps.Add(("Взять {0} из {1}" -f $planEntry.Name, $script:TempBase)) }
    }
    foreach ($planEntry in $selected) { $planSteps.Add(("Загрузить {0} в {1}" -f $planEntry.Name, $script:ProdBase)) }
}
foreach ($planEntry in $selected) { $planSteps.Add(("Обновить конфигурацию БД {0}" -f $planEntry.Name)) }
foreach ($planProc in $selectedProcessings) { $planSteps.Add((Get-ProcessingStepTitle $planProc)) }
if ($selected.Count -gt 0) {
    $planSteps.Add('Проверка применимости')
    $planSteps.Add('Канареечный вход')
    $planSteps.Add('Самопроверка на чтение')
}
$planSteps.Add('Статья в базу знаний')
Send-UiPlan -StepNames $planSteps.ToArray()

# Отсюда и до конца блокировки рабочей базы снимаются обязательно: в finally в конце скрипта (он выполняется
# и при exit, и по Ctrl+C) и в trap.
# Только внешние обработки - монопольный доступ не нужен: блокировки не ставятся и в конце не снимаются
# (снятие снимает и чужие блокировки), пользователи работают дальше.
$needExclusive = ($selected.Count -gt 0)
if ($needExclusive) { $script:ProdLocksArmed = $true }
try {

if ($needExclusive) {
    Write-Host ''
    Write-Host 'Подготовка рабочей базы:'
    $prepLink = Connect-ClusterAgent
    $prepTarget = $null
    try {
        $prepTarget = Get-BaseInfo -Link $prepLink -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
        if ([bool]$prepTarget.InfoBase.ScheduledJobsDenied) {
            Write-Line '  блокировка регламентных заданий уже стоит; в конце обновления сниму её'
        }
        else {
            $prepTarget.InfoBase.ScheduledJobsDenied = $true
            $prepTarget.Process.UpdateInfoBase($prepTarget.InfoBase)
            if (-not [bool](Read-BaseInfoAgain $prepTarget $script:ProdBase).ScheduledJobsDenied) { throw 'флажок не записался' }
            Write-Line '  поставил блокировку регламентных заданий на время обновления; в конце сниму' 'Green'
        }
    }
    catch {
        $prepTarget = $null
        Write-Line ("  блокировку регламентных заданий поставить не смог: {0}" -f $_.Exception.Message) 'Yellow'
        Write-Line '  без неё регламентное задание может сорвать обновление БД; блокировку сеансов тоже не поставить' 'Yellow'
    }

    # Открытый конфигуратор рабочей базы.
    $sessions = @(Get-BaseSessions $prepLink $script:ProdBase)
    foreach ($entry in @($sessions | Where-Object { $_.IsError })) { Write-Line ('  сеансы проверить не смог: ' + $entry.Text) 'Yellow' }
    $designers = @($sessions | Where-Object { -not $_.IsError -and $_.IsDesigner })
    if ($designers.Count -gt 0) {
        Write-Line ("  открыт конфигуратор {0}: закрой его, чтобы продолжить" -f $script:ProdBase) 'Yellow'
        foreach ($entry in $designers) { Write-Line ('    ' + $entry.Text) 'Yellow' }
        $answer = Read-UiChoice -Header ("Открыт конфигуратор {0}. Закрой его сам - скрипт увидит и продолжит, или:" -f $script:ProdBase) `
            -Keys @('1', '2') -Labels @('Закрыть отсюда (сеанс прерывается, несохранённые правки в нём пропадут)', 'Отмена') -CancelKey '2' -Poll {
            $now = @(Get-BaseSessions $prepLink $script:ProdBase)
            if (@($now | Where-Object { $_.IsError }).Count -eq 0 -and @($now | Where-Object { $_.IsDesigner }).Count -eq 0) { return 'closed' }
            return ''
        }
        if ($answer -eq '2') { throw ("открыт конфигуратор {0}, отмена по ответу" -f $script:ProdBase) }
        if ($answer -eq '1') {
            foreach ($line in @(Stop-BaseSessions -Link $prepLink -BaseName $script:ProdBase -Designers)) { Write-Line ('  ' + $line) }
            $left = @()
            for ($wait = 0; $wait -lt 10; $wait++) {
                Start-Sleep -Seconds 3
                $left = @(Get-BaseSessions $prepLink $script:ProdBase | Where-Object { -not $_.IsError -and $_.IsDesigner })
                if ($left.Count -eq 0) { break }
            }
            if ($left.Count -gt 0) { throw ("конфигуратор {0} за 30 секунд не закрылся" -f $script:ProdBase) }
        }
        Write-Line '  конфигуратор закрыт' 'Green'
    }

    function Set-ProdSessionLock {
        param($Target)
        if ($null -eq $Target) { Write-Line '  блокировку начала сеансов поставить не смог (нет входа в свойства базы): сеансы могут вернуться' 'Yellow'; return }
        $infoBase = $Target.InfoBase
        if ([bool]$infoBase.SessionsDenied) {
            $existing = [string]$infoBase.PermissionCode
            if ($existing -and $existing -ne $script:UnlockCode) {
                $script:KeepForeignSessionLock = $true
                throw ("в {0} уже стоит чужая блокировка сеансов с другим кодом: впиши его в UnlockCode или сними блокировку" -f $script:ProdBase)
            }
            Write-Line '  блокировка начала сеансов уже стоит (код тот же); в конце обновления сниму её'
            return
        }
        if ([string]::IsNullOrEmpty($script:UnlockCode)) { $script:UnlockCode = '123'; Write-Line '  UnlockCode пустой: код разрешения входа на этот запуск - 123' }
        $until = (Get-Date).AddHours($sessionLockHours)
        $infoBase.DeniedFrom = (Get-Date).AddMinutes(-30)
        $infoBase.DeniedTo = $until
        $infoBase.DeniedMessage = ("Идёт обновление расширений, база заблокирована до {0}" -f $until.ToString('HH:mm'))
        $infoBase.PermissionCode = $script:UnlockCode
        $infoBase.SessionsDenied = $true
        $Target.Process.UpdateInfoBase($infoBase)
        if (-not [bool](Read-BaseInfoAgain $Target $script:ProdBase).SessionsDenied) { throw 'блокировка сеансов не записалась' }
        $script:SessionLockCode = $script:UnlockCode
        Write-Line ("  поставил блокировку начала сеансов до {0}; сниму в конце" -f $until.ToString('HH:mm')) 'Green'
    }

    # Другие сеансы рабочей базы. Обновлению БД нужен монопольный доступ.
    $others = @(Get-BaseSessions $prepLink $script:ProdBase | Where-Object { -not $_.IsError -and -not $_.IsDesigner })
    if ($others.Count -eq 0) {
        Write-Line ("  в {0} других сеансов нет" -f $script:ProdBase) 'Green'
        Set-ProdSessionLock $prepTarget
    }
    else {
        Write-Line ("  в {0} есть сеансы: {1}" -f $script:ProdBase, $others.Count) 'Yellow'
        foreach ($entry in $others) { Write-Line ('    ' + $entry.Text) 'Yellow' }
        $script:LastSessionCount = $others.Count
        $answer = Read-UiChoice -Header ("В {0} есть сеансы: {1}. Можно дождаться, пока закончатся сами, или:" -f $script:ProdBase, $others.Count) `
            -Keys @('1', '2', '3') -CancelKey '2' -Labels @(
            'Продолжить так (обновление БД может упереться в монопольную блокировку)',
            'Выйти',
            ("Поставить блокировку начала сеансов на {0} ч, завершить сеансы и продолжить" -f $sessionLockHours)) -Poll {
            $now = @(Get-BaseSessions $prepLink $script:ProdBase)
            if (@($now | Where-Object { $_.IsError }).Count -gt 0) { return '' }
            if ($now.Count -eq 0) { return 'empty' }
            if ($now.Count -ne $script:LastSessionCount) {
                $script:LastSessionCount = $now.Count
                Write-Host ("  сеансов осталось: {0}" -f $now.Count) -ForegroundColor DarkGray
            }
            return ''
        }
        if ($answer -eq '2') { throw ("в {0} есть сеансы, выход по ответу" -f $script:ProdBase) }
        if ($answer -eq 'empty') { Write-Line '  сеансы закончились сами' 'Green'; Set-ProdSessionLock $prepTarget }
        if ($answer -eq '3') {
            Set-ProdSessionLock $prepTarget
            foreach ($line in @(Stop-BaseSessions -Link $prepLink -BaseName $script:ProdBase)) { Write-Line ('  ' + $line) }
        }
        if ($answer -eq '1') { Write-Line '  продолжаю с сеансами в базе' }
    }
}
else {
    Write-Host ''
    Write-Line ("Только внешние обработки: блокировки {0} не нужны, пользователи работают дальше." -f $script:ProdBase)
}

#endregion

#region Резервные копии, загрузка, обновление БД

$beforeDir = Join-Path $script:RunDir 'before'
$newDir = Join-Path $script:RunDir 'new'
New-Item -ItemType Directory -Path $beforeDir, $newDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd'
$failed = $false
$touched = New-Object System.Collections.Generic.List[object]
# Внешние обработки, которые этот запуск записал в справочник рабочей или снял оттуда (для отката и deploy.json).
$touchedProcessings = New-Object System.Collections.Generic.List[object]

# Выгрузки в файлы для отчёта об изменениях и для отката «как есть». Здесь рабочая база уже заблокирована
# нами, конфигуратору никто не мешает. Не выгрузилось - не беда: отчёт будет без разницы по объектам.
if ($selected.Count -gt 0) {
    Write-Host ''
    Write-Host 'Выгрузки для отчёта об изменениях:'
}
$snapshotRoot = Join-Path $script:RunDir 'prod-before'
foreach ($entry in $selected) {
    $prodTitle = "Выгрузить {0} из {1}" -f $entry.Name, $script:ProdBase
    if ($mode -eq 'asis') {
        # Было - выгрузка рабочей с прошлого обновления (до ручной загрузки), стало - рабочая сейчас.
        $entry.OldDir = ''
        $entry.RollbackDir = ''
        if (Test-Path -LiteralPath (Join-Path $entry.ProdDir 'Configuration.xml')) {
            $entry.SnapshotDir = Join-Path $snapshotRoot $entry.Name
            $entry.SnapshotTime = (Get-Item -LiteralPath (Join-Path $entry.ProdDir 'Configuration.xml')).LastWriteTime.ToString('dd.MM.yyyy HH:mm')
            New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
            Copy-Item -LiteralPath $entry.ProdDir -Destination $entry.SnapshotDir -Recurse -Force
            $entry.OldDir = $entry.SnapshotDir
            $entry.RollbackDir = $entry.SnapshotDir
        }
    }
    $dump = Update-Mirror -BaseName $script:ProdBase -Extension $entry.Name
    if ($dump.Ok) { Write-Line ("[OK]   {0}" -f $prodTitle) 'Green' }
    elseif ($dump.Absent) { Write-Line ("[OK]   {0}: в рабочей его нет" -f $prodTitle) 'Green' }
    else { Write-Line ("[WARN] {0}: {1}" -f $prodTitle, $dump.Detail) 'Yellow' }
    if ($mode -eq 'asis') {
        $entry.NewDir = ''
        if ($dump.Ok) { $entry.NewDir = $entry.ProdDir }
        continue
    }
    $entry.OldDir = ''
    if ($dump.Ok) { $entry.OldDir = $entry.ProdDir }
    # Откат: стало - резервная копия .cfe, её в файлы не выгрузить без загрузки; разница - по версиям.
    if ($mode -eq 'rollback') { $entry.NewDir = ''; continue }
    $tempTitle = "Выгрузить {0} из {1}" -f $entry.Name, $script:TempBase
    $dump = Update-Mirror -BaseName $script:TempBase -Extension $entry.Name
    $entry.NewDir = ''
    if ($dump.Ok) { $entry.NewDir = $entry.TempDir; Write-Line ("[OK]   {0}" -f $tempTitle) 'Green' }
    else { Write-Line ("[WARN] {0}: {1}" -f $tempTitle, $dump.Detail) 'Yellow' }
}

if ($mode -eq 'asis') {
    # Ничего не загружается: расширения уже в конфигурации рабочей. Откатывать - к прежней выгрузке.
    foreach ($entry in $selected) { $touched.Add($entry) }
    Write-Line '  загрузки нет: обновляю конфигурацию БД тем, что уже загружено в рабочую'
}
foreach ($entry in @($selected | Where-Object { $mode -ne 'asis' })) {
    if ($entry.ProdPresent) {
        $backup = Join-Path $beforeDir ("{0}_{1}_{2}.cfe" -f $script:ProdBase, $entry.Name, $stamp)
        $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/DumpCfg', ('"{0}"' -f $backup), '-Extension', $entry.Name) `
            -LogName ("backup_{0}.log" -f $entry.Name) -TimeoutSec $timeoutLoadSec -Title ("Резервная копия {0}" -f $entry.Name)
        if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $backup)) {
            Write-Line ("[FAIL] Резервная копия {0}: не сохранилась, {1}" -f $entry.Name, $result.Text) 'Red'
            $failed = $true; break
        }
        $entry.Backup = $backup
        Write-Line ("[OK]   Резервная копия {0}: before\{1}" -f $entry.Name, (Split-Path -Leaf $backup)) 'Green'
    }
    # Откат: грузится резервная копия выбранного обновления, из temp ничего не берётся.
    if ($mode -eq 'rollback') { Set-StatSize -Ext $entry.Name -Path $entry.NewFile; continue }

    $newFile = Join-Path $newDir ("{0}_{1}_{2}.cfe" -f $script:TempBase, $entry.Name, $stamp)
    $result = Invoke-Designer -BaseName $script:TempBase -Command @('/DumpCfg', ('"{0}"' -f $newFile), '-Extension', $entry.Name) `
        -LogName ("take_{0}.log" -f $entry.Name) -TimeoutSec $timeoutLoadSec -Title ("Взять {0} из {1}" -f $entry.Name, $script:TempBase)
    if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $newFile)) {
        Write-Line ("[FAIL] Взять {0} из {1}: не выгрузилось, {2}" -f $entry.Name, $script:TempBase, $result.Text) 'Red'
        $failed = $true; break
    }
    $entry.NewFile = $newFile
    Set-StatSize -Ext $entry.Name -Path $newFile
    Write-Line ("[OK]   Взять {0} из {1}: {2} с" -f $entry.Name, $script:TempBase, $result.Seconds) 'Green'
}

if (-not $failed -and $mode -ne 'asis') {
    foreach ($entry in $selected) {
        $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/LoadCfg', ('"{0}"' -f $entry.NewFile), '-Extension', $entry.Name) `
            -LogName ("load_{0}.log" -f $entry.Name) -TimeoutSec $timeoutLoadSec -Title ("Загрузить {0} в {1}" -f $entry.Name, $script:ProdBase)
        if ($result.ExitCode -eq 0 -or $result.TimedOut) { $entry.Loaded = $true; $touched.Add($entry) }
        if ($result.ExitCode -ne 0) {
            Write-Line ("[FAIL] Загрузить {0} в {1}: {2}" -f $entry.Name, $script:ProdBase, $result.Text) 'Red'
            $failed = $true; break
        }
        Write-Line ("[OK]   Загрузить {0} в {1}: {2} с" -f $entry.Name, $script:ProdBase, $result.Seconds) 'Green'
    }
}

# Конфигурация БД обновляется после загрузки всех расширений.
if (-not $failed) {
    foreach ($entry in $selected) {
        $attempt = 0
        while ($true) {
            $attempt++
            $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/UpdateDBCfg', '-Extension', $entry.Name) `
                -LogName ("update_{0}_{1}.log" -f $entry.Name, $attempt) -TimeoutSec $timeoutUpdateSec -Title ("Обновить конфигурацию БД {0}" -f $entry.Name)
            if ($result.ExitCode -eq 0) { break }
            $locked = (-not $result.TimedOut -and $result.Text.Contains('исключительной блокировки'))
            if (-not $locked) { break }
            Write-Line ("  обновлению БД {0} мешают сеансы {1}:" -f $entry.Name, $script:ProdBase) 'Yellow'
            $linkNow = Connect-ClusterAgent
            foreach ($item in @(Get-BaseSessions $linkNow $script:ProdBase)) { Write-Line ('    ' + $item.Text) 'Yellow' }
            $answer = Read-UiChoice -Header ("Обновлению БД {0} мешают сеансы {1}" -f $entry.Name, $script:ProdBase) -Keys @('1', '2', '3') -CancelKey '2' `
                -Labels @('Повторить (сначала убери мешающих сам)', 'Не повторять', 'Завершить сеансы (кроме конфигураторов) и сразу повторить')
            if ($answer -eq '2') { break }
            if ($answer -eq '3') { foreach ($line in @(Stop-BaseSessions -Link $linkNow -BaseName $script:ProdBase)) { Write-Line ('  ' + $line) } }
        }
        if ($result.ExitCode -ne 0) {
            Write-Line ("[FAIL] Обновить конфигурацию БД {0}: {1}" -f $entry.Name, $result.Text) 'Red'
            $failed = $true; break
        }
        Write-Line ("[OK]   Обновить конфигурацию БД {0}: {1} с" -f $entry.Name, $result.Seconds) 'Green'
    }
}

# Внешние обработки - после расширений и обновления БД: обработкам бывают нужны объекты из расширений.
# Пишет «Выполнить после обновления» (regepf) через БСП, как загрузка из файла в форме элемента; прежняя
# версия до записи ложится в before\processings\ - это откат. Подключение и формы проверяются там же.
if (-not $failed -and $selectedProcessings.Count -gt 0) {
    Write-Host ''
    Write-Host 'Внешние обработки:'
    $procRoot = Join-Path $script:RunDir 'epf'
    foreach ($proc in $selectedProcessings) {
        $title = Get-ProcessingStepTitle $proc
        $procDir = Join-Path $procRoot $proc.ObjName
        $proc | Add-Member -NotePropertyName Backup -NotePropertyValue '' -Force
        $proc | Add-Member -NotePropertyName RemovedFile -NotePropertyValue '' -Force
        $proc | Add-Member -NotePropertyName IsNew -NotePropertyValue '' -Force
        $proc | Add-Member -NotePropertyName OldVersion -NotePropertyValue $proc.ProdVersion -Force
        $proc | Add-Member -NotePropertyName NewVersion -NotePropertyValue $proc.TempVersion -Force
        $proc | Add-Member -NotePropertyName Problems -NotePropertyValue @() -Force

        if ($proc.Action -eq 'unregister') {
            # Снять новую обработку (откат). Файл того, что снимается, - в before\: откат этого отката запишет его снова.
            if ($proc.TempFile -and (Test-Path -LiteralPath $proc.TempFile)) {
                $removedDir = Join-Path $beforeDir 'processings'
                New-Item -ItemType Directory -Path $removedDir -Force | Out-Null
                $proc.RemovedFile = Join-Path $removedDir $proc.FileName
                Copy-Item -LiteralPath $proc.TempFile -Destination $proc.RemovedFile -Force
            }
            $session = Invoke-ProdProcessing -Mode 'unregepf' -OutDir $procDir -Name $proc.ObjName -Ref $proc.Ref -Title $title
            if (-not $session.Done -or $session.Status -ne 'done') {
                Write-Line ("[FAIL] {0}: {1}" -f $title, $session.Message) 'Red'
                $failed = $true; break
            }
            $touchedProcessings.Add($proc)
            Write-Line ("[OK]   {0}: публикация «Отключена», пометка удаления" -f $title) 'Green'
            continue
        }

        $session = Invoke-ProdProcessing -Mode 'regepf' -OutDir $procDir -File $proc.Source -TextFile $proc.SourceB64 -Name $proc.FileName -Title $title
        $values = $session.Values
        $proc.Ref = [string](Get-Setting $values 'ref' '')
        if ([string](Get-Setting $values 'objversion' '')) { $proc.NewVersion = [string](Get-Setting $values 'objversion' '') }
        if ([string](Get-Setting $values 'oldversion' '')) { $proc.OldVersion = [string](Get-Setting $values 'oldversion' '') }
        $isNewText = [string](Get-Setting $values 'isnew' '')
        if ($isNewText -eq '1') { $proc.IsNew = 'yes' } elseif ($isNewText -eq '0') { $proc.IsNew = 'no' }
        if ($session.OldB64) { $proc.Backup = Write-ProcessingBackup -Proc $proc -OldB64 $session.OldB64 }
        if (-not $session.Done) {
            # Итога нет: записалась ли обработка, неизвестно. Прежняя версия успела сохраниться - откат возможен.
            $touchedProcessings.Add($proc)
            Write-Line ("[FAIL] {0}: {1}" -f $title, $session.Message) 'Red'
            $failed = $true; break
        }
        if ($session.Status -ne 'done' -and -not $proc.Ref) {
            # Не записана: справочник не менялся.
            Write-Line ("[FAIL] {0}: не записана, {1}" -f $title, $session.Message) 'Red'
            $failed = $true; break
        }
        $touchedProcessings.Add($proc)
        $problems = New-Object System.Collections.Generic.List[string]
        if ($session.Status -ne 'done') { $problems.Add($session.Message) }
        if ([string](Get-Setting $values 'check' '') -eq 'error') { $problems.Add(("не подключилась после записи: {0}" -f (Get-Setting $values 'checkerror' ''))) }
        foreach ($formError in $session.FormErrors) { $problems.Add(("форма не создаётся: {0}" -f $formError)) }
        $proc.Problems = $problems.ToArray()
        $what = 'обновлена'
        if ($proc.IsNew -eq 'yes') { $what = 'добавлена новым элементом' }
        $detail = "{0}, версия {1} -> {2}, форм {3}" -f $what, $(if ($proc.OldVersion) { $proc.OldVersion } else { '-' }), $(if ($proc.NewVersion) { $proc.NewVersion } else { '-' }), (Get-Setting $values 'forms' '?')
        if ($problems.Count -gt 0) { Write-Line ("[WARN] {0}: {1}. {2}" -f $title, $detail, ($problems -join ' | ')) 'Yellow' }
        else { Write-Line ("[OK]   {0}: {1}; подключается, формы создаются" -f $title, $detail) 'Green' }
    }
}

function Invoke-ProdRollback {
    # Возвращает рабочую базу к резервным копиям: в обратном порядке; новое расширение удаляется по имени.
    # Сначала внешние обработки (их писали последними): прежняя версия - обратно в справочник, новая снимается,
    # снятая - записывается снова.
    $ok = $true
    $procList = @($touchedProcessings.ToArray())
    [array]::Reverse($procList)
    foreach ($proc in $procList) {
        $procDir = Join-Path (Join-Path $script:RunDir 'epf-rollback') $proc.ObjName
        $session = $null
        if ($proc.Action -eq 'unregister') {
            if ($proc.RemovedFile) {
                $session = Invoke-ProdProcessing -Mode 'regepf' -OutDir $procDir -File $proc.RemovedFile -Name $proc.FileName -Title ("Откат: записать снова {0}" -f $proc.ObjName)
            }
        }
        elseif ($proc.Backup) {
            $session = Invoke-ProdProcessing -Mode 'regepf' -OutDir $procDir -TextFile $proc.Backup -Name $proc.FileName -Title ("Откат: вернуть прежнюю {0}" -f $proc.ObjName)
        }
        elseif ($proc.IsNew -eq 'yes' -and $proc.Ref) {
            $session = Invoke-ProdProcessing -Mode 'unregepf' -OutDir $procDir -Name $proc.ObjName -Ref $proc.Ref -Title ("Откат: снять новую {0}" -f $proc.ObjName)
        }
        if ($null -eq $session) {
            Write-Line ("  откат {0}: откатывать не к чему (прежней версии нет, и новой она не отмечена)" -f $proc.ObjName) 'Yellow'
            $ok = $false
            continue
        }
        if ($session.Done -and $session.Status -eq 'done') { Write-Line ("  откат {0}: готово" -f $proc.ObjName) 'Green' }
        else { Write-Line ("  откат {0} не прошёл: {1}" -f $proc.ObjName, $session.Message) 'Red'; $ok = $false }
    }
    $list = @($touched.ToArray())
    [array]::Reverse($list)
    foreach ($entry in $list) {
        if ($entry.Backup) {
            $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/LoadCfg', ('"{0}"' -f $entry.Backup), '-Extension', $entry.Name) `
                -LogName ("rollback_load_{0}.log" -f $entry.Name) -TimeoutSec $timeoutLoadSec -Title ("Откат: вернуть {0}" -f $entry.Name)
            if ($result.ExitCode -eq 0) {
                $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/UpdateDBCfg', '-Extension', $entry.Name) `
                    -LogName ("rollback_update_{0}.log" -f $entry.Name) -TimeoutSec $timeoutUpdateSec -Title ("Откат: обновить БД {0}" -f $entry.Name)
            }
        }
        elseif ($entry.RollbackDir) {
            # «Как есть»: прежняя выгрузка рабочей в файлах загружается обратно.
            $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/LoadConfigFromFiles', ('"{0}"' -f $entry.RollbackDir), '-Extension', $entry.Name) `
                -LogName ("rollback_load_{0}.log" -f $entry.Name) -TimeoutSec $timeoutLoadSec -Title ("Откат: вернуть {0} из выгрузки {1}" -f $entry.Name, $entry.SnapshotTime)
            if ($result.ExitCode -eq 0) {
                $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/UpdateDBCfg', '-Extension', $entry.Name) `
                    -LogName ("rollback_update_{0}.log" -f $entry.Name) -TimeoutSec $timeoutUpdateSec -Title ("Откат: обновить БД {0}" -f $entry.Name)
            }
        }
        elseif ($entry.Status -ne 'new') {
            Write-Line ("  откат {0}: откатывать не к чему (прежней выгрузки нет)" -f $entry.Name) 'Yellow'
            $ok = $false
            continue
        }
        else {
            # Удаляется одно расширение по имени. Ключа -AllExtensions здесь нет.
            $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/DeleteCfg', '-Extension', $entry.Name) `
                -LogName ("rollback_delete_{0}.log" -f $entry.Name) -TimeoutSec $timeoutLoadSec -Title ("Откат: удалить новое {0}" -f $entry.Name)
        }
        if ($result.ExitCode -eq 0) { Write-Line ("  откат {0}: готово" -f $entry.Name) 'Green' }
        else { Write-Line ("  откат {0} не прошёл: {1}" -f $entry.Name, $result.Text) 'Red'; $ok = $false }
    }
    return $ok
}

$outcome = 'updated'
if ($failed) {
    $outcome = 'failed'
    if ($touched.Count -gt 0 -or $touchedProcessings.Count -gt 0) {
        Write-Host ''
        $touchedNames = @(@($touched | ForEach-Object { $_.Name }) + @($touchedProcessings | ForEach-Object { $_.ObjName })) -join ', '
        Write-Line ("Обновление не прошло, а в {0} уже загружено: {1}" -f $script:ProdBase, $touchedNames) 'Red'
        # Без ответа дальше не идём: решение важное.
        $rollbackNow = $null
        while ($null -eq $rollbackNow) {
            $rollbackNow = Confirm-Ui -Question 'Откатить? (к резервным копиям, а при «как есть» - к прежней выгрузке рабочей; Нет - оставить как есть)' -Yes 'Откатить' -No 'Оставить'
        }
        if ($rollbackNow) {
            if (Invoke-ProdRollback) { $outcome = 'rolledBack' } else { $outcome = 'rollbackFailed' }
        }
    }
}

#endregion

#region Лёгкий прогон без записи в базу

$light = New-Object System.Collections.Generic.List[object]   # Status OK/WARN/FAIL, Name, Text
$selfCheckErrors = New-Object System.Collections.Generic.List[string]

function Add-Light {
    param([string]$Status, [string]$Name, [string]$Text)
    $light.Add([pscustomobject]@{ Status = $Status; Name = $Name; Text = $Text })
    $color = 'Green'
    if ($Status -eq 'WARN') { $color = 'Yellow' }
    if ($Status -eq 'FAIL') { $color = 'Red' }
    Write-Line ("[{0,-4}] {1}: {2}" -f $Status, $Name, $Text) $color
}

if ($outcome -eq 'updated') {
    Write-Host ''
    Write-Host 'Лёгкий прогон (в базу ничего не пишется):'

    # Внешние обработки: подключение и формы проверил сам сеанс записи (regepf); здесь - его итог.
    if ($touchedProcessings.Count -gt 0) {
        $procProblems = @($touchedProcessings | Where-Object { @($_.Problems).Count -gt 0 })
        if ($procProblems.Count -gt 0) {
            Add-Light 'FAIL' 'Внешние обработки' (@($procProblems | ForEach-Object { '{0}: {1}' -f $_.ObjName, (@($_.Problems) -join ' | ') }) -join '; ')
        }
        else { Add-Light 'OK' 'Внешние обработки' ("записано {0}: подключаются, формы создаются" -f $touchedProcessings.Count) }
    }

    if ($selected.Count -eq 0) {
        # Расширения не менялись: проверка применимости, вход и самопроверка ничего нового не покажут.
        Write-Line '  расширения не менялись: проверка применимости, канареечный вход и самопроверка не нужны' 'DarkGray'
    }
    else {
        # Проверка применимости расширений: только чтение, конфигуратор.
        $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/CheckCanApplyConfigurationExtensions', '-AllExtensions') `
            -LogName 'checkcanapply.log' -TimeoutSec $timeoutLoadSec -Title 'Проверка применимости расширений'
        $applyLines = @($result.Lines | Where-Object { $_ -and $_.Trim() })
        if ($result.ExitCode -eq 0) { Add-Light 'OK' 'Проверка применимости' 'замечаний нет' }
        elseif ($result.ExitCode -eq 101) { Add-Light 'WARN' 'Проверка применимости' ("замечаний {0}, первое: {1}" -f $applyLines.Count, ($applyLines | Select-Object -First 1)) }
        else { Add-Light 'FAIL' 'Проверка применимости' ("не выполнилась: {0}" -f $result.Text) }

        # Канареечный вход: применились ли расширения в сеансе.
        if (Test-Path -LiteralPath $canaryEpf) {
            $canaryFile = Join-Path $script:RunDir 'canary.txt'
            $client = Invoke-ProdClient -Epf $canaryEpf -Parameter ("canary;out={0};wait=10" -f $canaryFile) -DoneFile $canaryFile -TimeoutSec $canaryTimeoutSec -Title 'Канареечный вход'
            if (-not $client.Done) { Add-Light 'FAIL' 'Канареечный вход' ("за {0} с результата нет" -f $client.Seconds) }
            else {
                $content = @(Get-Content -LiteralPath $canaryFile -Encoding UTF8)
                $notApplied = @($content | Where-Object { $_ -like 'ext=*|NOT_APPLIED' } | ForEach-Object { ($_.Substring(4) -split '\|')[0] })
                $status = @($content | Where-Object { $_ -like 'status=*' } | Select-Object -First 1)
                if ($status.Count -eq 0 -or ([string]$status[0]).Substring(7).Trim() -ne 'ok') { Add-Light 'FAIL' 'Канареечный вход' ($content -join ' | ') }
                elseif ($notApplied.Count -gt 0) { Add-Light 'FAIL' 'Канареечный вход' ("не применились в сеансе: {0}" -f ($notApplied -join ', ')) }
                else { Add-Light 'OK' 'Канареечный вход' ("вошёл за {0} с, расширения применились" -f $client.Seconds) }
            }
        }
        else { Add-Light 'WARN' 'Канареечный вход' "нет обработки $canaryEpf" }

        # Самопроверка только на чтение: write=0, post=0; формы - по настройке ProdSelfCheckForms.
        if (Test-Path -LiteralPath $selfCheckEpf) {
            $selfDir = Join-Path $script:RunDir 'selfcheck'
            New-Item -ItemType Directory -Path $selfDir -Force | Out-Null
            $parameter = "selfcheck;out={0};docs=3;write=0;post=0" -f $selfDir
            if (-not $prodSelfCheckForms) { $parameter += ';forms=0' }
            $resultFile = Join-Path $selfDir 'result.txt'
            $client = Invoke-ProdClient -Epf $selfCheckEpf -Parameter $parameter -DoneFile $resultFile -TimeoutSec (60 * $prodSelfCheckTimeoutMin) -Title 'Самопроверка на чтение'
            $resultTable = Read-KeyValueFile $resultFile
            $state = [string](Get-Setting $resultTable 'status' '')
            # Записи ОШИБКА из частей журнала.
            $journal = New-Object System.Collections.Generic.List[string]
            foreach ($file in @(Get-ChildItem -LiteralPath $selfDir -Filter 'p*.txt' -File | Where-Object { $_.Name -match '^p\d{6}\.txt$' } | Sort-Object Name)) {
                $inBody = $false
                foreach ($line in [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8)) {
                    if ($inBody) { $journal.Add($line); continue }
                    if ($line.TrimStart([char]0xFEFF) -eq '@@journal') { $inBody = $true }
                }
            }
            [System.IO.File]::WriteAllLines((Join-Path $script:RunDir 'selfcheck.journal.txt'), $journal.ToArray(), $Utf8Bom)
            $current = $null
            foreach ($line in $journal) {
                $found = $SelfCheckLineRegex.Match($line)
                if ($found.Success) {
                    if ($null -ne $current) { $selfCheckErrors.Add($current) }
                    $current = $null
                    if ($found.Groups[1].Value -ceq 'ОШИБКА') { $current = $found.Groups[2].Value.Trim() }
                    continue
                }
                if ($null -ne $current -and $line.StartsWith($SelfCheckIndent, [System.StringComparison]::Ordinal)) { $current = $current + ' ' + $line.Trim(); continue }
                if ($null -ne $current) { $selfCheckErrors.Add($current); $current = $null }
            }
            if ($null -ne $current) { $selfCheckErrors.Add($current) }
            $counts = "заданий без ошибок {0}, ошибок {1}, предупреждений {2}, пропущено {3}" -f (Get-Setting $resultTable 'ok' '?'), (Get-Setting $resultTable 'errors' '?'), (Get-Setting $resultTable 'warnings' '?'), (Get-Setting $resultTable 'skipped' '?')
            if (-not $client.Done) { Add-Light 'FAIL' 'Самопроверка на чтение' ("не закончилась за {0} мин; журнал - selfcheck.journal.txt" -f $prodSelfCheckTimeoutMin) }
            elseif ($state -eq 'refused') { Add-Light 'FAIL' 'Самопроверка на чтение' ("обработка отказалась: {0}. Нужна сборка с режимом «только чтение» для рабочей базы" -f (Get-Setting $resultTable 'message' '')) }
            elseif ($state -ne 'done') { Add-Light 'FAIL' 'Самопроверка на чтение' ("итог {0}: {1}" -f $state, (Get-Setting $resultTable 'message' '')) }
            elseif ($selfCheckErrors.Count -gt 0) { Add-Light 'WARN' 'Самопроверка на чтение' ($counts + '; ошибки перечислены в отчёте') }
            else { Add-Light 'OK' 'Самопроверка на чтение' $counts }
        }
        else { Add-Light 'WARN' 'Самопроверка на чтение' "нет обработки $selfCheckEpf" }
    }

    if (@($light | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) {
        Write-Host ''
        Write-Line 'Лёгкий прогон нашёл проблемы.' 'Red'
        $keepUpdate = $null
        while ($null -eq $keepUpdate) {
            $keepUpdate = Confirm-Ui -Question 'Оставить обновление в рабочей базе?' -Yes 'Оставить' -No 'Откатить'
        }
        if (-not $keepUpdate) {
            if (Invoke-ProdRollback) { $outcome = 'rolledBack' } else { $outcome = 'rollbackFailed' }
        }
    }
}

#endregion

#region Отчёт об изменениях

$objectTypeNames = @{
    Catalogs = 'Справочник'; Documents = 'Документ'; CommonModules = 'Общий модуль'; DataProcessors = 'Обработка'
    Reports = 'Отчёт'; InformationRegisters = 'Регистр сведений'; AccumulationRegisters = 'Регистр накопления'
    AccountingRegisters = 'Регистр бухгалтерии'; CalculationRegisters = 'Регистр расчёта'; Enums = 'Перечисление'
    Roles = 'Роль'; CommonForms = 'Общая форма'; Subsystems = 'Подсистема'; Constants = 'Константа'
    ScheduledJobs = 'Регламентное задание'; EventSubscriptions = 'Подписка на событие'; CommonCommands = 'Общая команда'
    CommonTemplates = 'Общий макет'; CommonPictures = 'Общая картинка'; HTTPServices = 'HTTP-сервис'; WebServices = 'Веб-сервис'
    DocumentJournals = 'Журнал документов'; ChartsOfCharacteristicTypes = 'План видов характеристик'
    ChartsOfAccounts = 'План счетов'; ChartsOfCalculationTypes = 'План видов расчёта'; BusinessProcesses = 'Бизнес-процесс'
    Tasks = 'Задача'; ExchangePlans = 'План обмена'; FilterCriteria = 'Критерий отбора'; DefinedTypes = 'Определяемый тип'
    FunctionalOptions = 'Функциональная опция'; FunctionalOptionsParameters = 'Параметр функциональных опций'
    SessionParameters = 'Параметр сеанса'; CommonAttributes = 'Общий реквизит'; CommandGroups = 'Группа команд'
    XDTOPackages = 'Пакет XDTO'; StyleItems = 'Элемент стиля'; Styles = 'Стиль'; Languages = 'Язык'
    DocumentNumerators = 'Нумератор'; Sequences = 'Последовательность'; SettingsStorages = 'Хранилище настроек'
}

function Get-ObjectKey {
    # Путь файла выгрузки -> объект метаданных и его часть.
    param([string]$Relative)
    $parts = $Relative.Split('/')
    if ($parts.Count -lt 2 -or -not $objectTypeNames.ContainsKey($parts[0])) {
        return [pscustomobject]@{ Object = 'Свойства расширения'; Part = $Relative }
    }
    $name = $parts[1]
    if ($name.EndsWith('.xml')) { $name = $name.Substring(0, $name.Length - 4) }
    $object = '{0}.{1}' -f $objectTypeNames[$parts[0]], $name
    $rest = ''
    if ($parts.Count -gt 2) { $rest = ($parts[2..($parts.Count - 1)] -join '/') }
    $part = switch -Regex ($rest) {
        '^$' { 'свойства объекта (реквизиты, состав)'; break }
        '^Ext/ObjectModule\.bsl$' { 'модуль объекта'; break }
        '^Ext/ManagerModule\.bsl$' { 'модуль менеджера'; break }
        '^Ext/RecordSetModule\.bsl$' { 'модуль набора записей'; break }
        '^Ext/Module\.bsl$' { 'модуль'; break }
        '^Ext/ValueManagerModule\.bsl$' { 'модуль менеджера значения'; break }
        '^Ext/CommandModule\.bsl$' { 'модуль команды'; break }
        '^Ext/Rights\.xml$' { 'права'; break }
        '^Ext/Predefined\.xml$' { 'предопределённые'; break }
        '^Forms/([^/]+)\.xml$' { 'форма {0}: свойства' -f $Matches[1]; break }
        '^Forms/([^/]+)/Ext/Form\.xml$' { 'форма {0}: элементы и реквизиты' -f $Matches[1]; break }
        '^Forms/([^/]+)/Ext/Form/Module\.bsl$' { 'форма {0}: модуль' -f $Matches[1]; break }
        '^Commands/([^/]+)/Ext/CommandModule\.bsl$' { 'команда {0}: модуль' -f $Matches[1]; break }
        '^Templates/([^/]+?)(\.xml|/.*)$' { 'макет {0}' -f $Matches[1]; break }
        default { $rest }
    }
    return [pscustomobject]@{ Object = $object; Part = [string]$part }
}

function Get-BslMethods {
    # Процедуры и функции модуля: имя -> текст и перехват (&Перед, &После, &Вместо, &ИзменениеИКонтроль).
    param([string]$Path)
    $methods = @{}
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return $methods }
    $current = $null
    $intercept = ''
    $buffer = $null
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $trim = $line.Trim()
        if ($null -eq $current) {
            $found = [regex]::Match($trim, '^&(Перед|После|Вместо|ИзменениеИКонтроль)\s*\(\s*"([^"]+)"')
            if ($found.Success) { $intercept = '&{0}("{1}")' -f $found.Groups[1].Value, $found.Groups[2].Value; continue }
            $found = [regex]::Match($trim, '^(?:Асинх\s+)?(Процедура|Функция)\s+([\w]+)\s*\(', 'IgnoreCase')
            if ($found.Success) {
                $current = $found.Groups[2].Value
                $buffer = New-Object System.Collections.Generic.List[string]
                $buffer.Add($trim)
            }
            continue
        }
        $buffer.Add($trim)
        if ($trim -match '^Конец(Процедуры|Функции)') {
            $methods[$current] = [pscustomobject]@{ Text = ($buffer -join "`n"); Intercept = $intercept }
            $current = $null
            $intercept = ''
        }
    }
    return $methods
}

function Get-AuthorMarks {
    # Новые пометки авторов (// ** ...): строки, которых не было в старом модуле.
    param([string]$OldPath, [string]$NewPath)
    $old = @{}
    if ($OldPath -and (Test-Path -LiteralPath $OldPath)) { foreach ($line in [System.IO.File]::ReadAllLines($OldPath, [System.Text.Encoding]::UTF8)) { $old[$line.Trim()] = $true } }
    $marks = New-Object System.Collections.Generic.List[string]
    if (-not $NewPath -or -not (Test-Path -LiteralPath $NewPath)) { return $marks.ToArray() }
    foreach ($line in [System.IO.File]::ReadAllLines($NewPath, [System.Text.Encoding]::UTF8)) {
        $trim = $line.Trim()
        if ($trim -match '^//\s*\*\*' -and -not $old.ContainsKey($trim) -and -not $marks.Contains($trim)) { $marks.Add($trim) }
    }
    return $marks.ToArray()
}

function Get-ExtensionChanges {
    # Что изменилось в расширении: объекты новые, удалённые, изменённые (по частям), процедуры модулей, пометки авторов.
    # KeyPrefix - для выгрузки внешней обработки: её файлы лежат без папки вида объекта, с ним они
    # читаются как объект «Обработка.<имя>» (модуль объекта, формы, макеты).
    param([string]$OldDir, [string]$NewDir, [string]$KeyPrefix = '')
    $oldHashes = Get-TreeHashes $OldDir
    $newHashes = Get-TreeHashes $NewDir
    $objects = @{}
    $marks = New-Object System.Collections.Generic.List[string]
    $allKeys = @(@($oldHashes.Keys) + @($newHashes.Keys) | Sort-Object -Unique)
    foreach ($relative in $allKeys) {
        $inOld = $oldHashes.ContainsKey($relative)
        $inNew = $newHashes.ContainsKey($relative)
        if ($inOld -and $inNew -and $oldHashes[$relative] -eq $newHashes[$relative]) { continue }
        $key = Get-ObjectKey ($KeyPrefix + $relative)
        if (-not $objects.ContainsKey($key.Object)) {
            $objects[$key.Object] = [pscustomobject]@{ Name = $key.Object; Added = $false; Removed = $false; Parts = (New-Object System.Collections.Generic.List[string]) }
        }
        $object = $objects[$key.Object]
        $isObjectFile = (($KeyPrefix + $relative) -match '^[^/]+/[^/]+\.xml$')
        if ($isObjectFile -and -not $inOld) { $object.Added = $true }
        if ($isObjectFile -and -not $inNew) { $object.Removed = $true }
        $partText = $key.Part
        if (-not $inOld) { $partText = $partText + ' - новое' }
        elseif (-not $inNew) { $partText = $partText + ' - удалено' }
        if ($relative.EndsWith('.bsl')) {
            $oldPath = ''
            if ($OldDir) { $oldPath = Join-Path $OldDir $relative.Replace('/', '\') }
            $newPath = Join-Path $NewDir $relative.Replace('/', '\')
            $oldMethods = Get-BslMethods $oldPath
            $newMethods = Get-BslMethods $newPath
            $methodNotes = New-Object System.Collections.Generic.List[string]
            foreach ($name in @($newMethods.Keys | Sort-Object)) {
                $label = $name
                if ($newMethods[$name].Intercept) { $label = '{0} ({1})' -f $name, $newMethods[$name].Intercept }
                if (-not $oldMethods.ContainsKey($name)) { $methodNotes.Add('+ ' + $label) }
                elseif ($oldMethods[$name].Text -ne $newMethods[$name].Text) { $methodNotes.Add('~ ' + $label) }
            }
            foreach ($name in @($oldMethods.Keys | Sort-Object)) { if (-not $newMethods.ContainsKey($name)) { $methodNotes.Add('- ' + $name) } }
            if ($methodNotes.Count -gt 0) { $partText = $partText + ': ' + ($methodNotes -join '; ') }
            elseif ($inOld -and $inNew) { $partText = $partText + ': изменения вне процедур (переменные, комментарии, области)' }
            foreach ($mark in @(Get-AuthorMarks $oldPath $newPath)) { if (-not $marks.Contains($mark)) { $marks.Add($mark) } }
        }
        $object.Parts.Add($partText)
    }
    return [pscustomobject]@{ Objects = @($objects.Values | Sort-Object Name); Marks = $marks.ToArray() }
}

$reportTitle = "Обновление расширений {0} от {1}" -f $script:ProdBase, (Get-Date -Format 'dd.MM.yyyy HH:mm')
if ($mode -eq 'asis') { $reportTitle = "Обновление конфигурации БД {0} как есть от {1}" -f $script:ProdBase, (Get-Date -Format 'dd.MM.yyyy HH:mm') }
if ($mode -eq 'epf') { $reportTitle = "Обновление внешних обработок {0} от {1}" -f $script:ProdBase, (Get-Date -Format 'dd.MM.yyyy HH:mm') }
if ($mode -eq 'rollback') { $reportTitle = "Откат расширений {0} к состоянию до обновления {1}, от {2}" -f $script:ProdBase, $rollbackOf, (Get-Date -Format 'dd.MM.yyyy HH:mm') }
$outcomeNames = @{ updated = 'обновлено'; failed = 'обновление не прошло'; rolledBack = 'обновление откачено'; rollbackFailed = 'откат прошёл не полностью' }
$html = New-Object System.Text.StringBuilder
[void]$html.Append('<html><head><meta charset="utf-8"></head><body>')
[void]$html.Append(('<h1>{0}</h1>' -f (ConvertTo-Html $reportTitle)))
if ($mode -eq 'asis') { [void]$html.Append('<p>Расширения загружены в конфигурацию рабочей базы руками; скрипт только обновил конфигурацию базы данных и проверил.</p>') }
[void]$html.Append(('<p>Из {0} в {1}. Итог: <b>{2}</b>. Выполнил: {3}. Папка запуска: {4}.</p>' -f (ConvertTo-Html $script:TempBase), (ConvertTo-Html $script:ProdBase), (ConvertTo-Html $outcomeNames[$outcome]), (ConvertTo-Html $env:USERNAME), (ConvertTo-Html $script:RunDir)))
if ($riskAccepted) {
    [void]$html.Append('<div style="border:2px solid #c0392b;padding:8px 12px;margin:10px 0;background:#fdecea">')
    [void]$html.Append(('<h2 style="color:#c0392b;margin-top:0">Обновлено несмотря на гейт: проверить работоспособность</h2><p>{0}.</p>' -f (ConvertTo-Html ($gateRisks -join '; '))))
    if ($gateRedItems.Count -gt 0) {
        [void]$html.Append('<p>Что гейт нашёл красного - проверить в рабочей базе в первую очередь:</p><ul>')
        foreach ($item in $gateRedItems) { [void]$html.Append(('<li>{0}</li>' -f (ConvertTo-Html $item))) }
        [void]$html.Append('</ul>')
    }
    else { [void]$html.Append('<p>Гейт не проверял этот комплект: проверить основные сценарии доработок руками.</p>') }
    [void]$html.Append('</div>')
}
[void]$html.Append('<h2>Гейт (справочно)</h2><ul>')
foreach ($line in $ciLines) { [void]$html.Append(('<li>{0}</li>' -f (ConvertTo-Html $line))) }
[void]$html.Append('</ul>')
[void]$html.Append('<h2>Лёгкий прогон после обновления</h2>')
if ($light.Count -eq 0) { [void]$html.Append('<p>Не выполнялся: обновление не прошло.</p>') }
else {
    [void]$html.Append('<ul>')
    foreach ($item in $light) { [void]$html.Append(('<li>[{0}] {1}: {2}</li>' -f $item.Status, (ConvertTo-Html $item.Name), (ConvertTo-Html $item.Text))) }
    [void]$html.Append('</ul>')
    if ($selfCheckErrors.Count -gt 0) {
        [void]$html.Append('<p>Ошибки самопроверки на чтение:</p><ul>')
        foreach ($line in @($selfCheckErrors | Select-Object -First 50)) { [void]$html.Append(('<li>{0}</li>' -f (ConvertTo-Html $line))) }
        if ($selfCheckErrors.Count -gt 50) { [void]$html.Append(('<li>и ещё {0}, см. selfcheck.journal.txt</li>' -f ($selfCheckErrors.Count - 50))) }
        [void]$html.Append('</ul>')
    }
}

foreach ($entry in $selected) {
    [void]$html.Append(('<h2>{0}</h2>' -f (ConvertTo-Html $entry.Name)))
    $oldVersion = ''
    if ($entry.OldDir -and (Test-Path -LiteralPath $entry.OldDir)) { $oldVersion = Get-ExtensionVersion $entry.OldDir }
    if (-not $entry.NewDir) {
        if ($mode -eq 'rollback') {
            [void]$html.Append(('<p>{0}</p>' -f (ConvertTo-Html ("Откат: версия {0} -> {1} (резервная копия из обновления {2})." -f $entry.ProdVersion, $entry.TempVersion, $rollbackOf))))
        }
        else { [void]$html.Append('<p>Выгрузка в файлы не получилась: разницы по объектам нет, см. run.log.</p>') }
        continue
    }
    $newVersion = Get-ExtensionVersion $entry.NewDir
    if (-not $entry.OldDir) {
        [void]$html.Append(('<p>Версия {0}. Прежней выгрузки рабочей нет: с чем сравнить, неизвестно, ниже - всё расширение как новое.</p>' -f (ConvertTo-Html $newVersion)))
    }
    elseif ($entry.Status -eq 'new' -and $mode -ne 'asis') { [void]$html.Append(('<p>{0}</p>' -f (ConvertTo-Html ('версия {0} - новое расширение' -f $newVersion)))) }
    else { [void]$html.Append(('<p>{0}</p>' -f (ConvertTo-Html ('версия {0} → {1}' -f $oldVersion, $newVersion)))) }
    if ($mode -eq 'asis' -and $entry.OldDir) {
        [void]$html.Append(('<p>Сравнение с выгрузкой рабочей от {0}.</p>' -f (ConvertTo-Html $entry.SnapshotTime)))
    }
    $changes = Get-ExtensionChanges -OldDir $entry.OldDir -NewDir $entry.NewDir
    $groups = @(
        @{ Title = 'Новые объекты'; Items = @($changes.Objects | Where-Object { $_.Added }) },
        @{ Title = 'Удалённые объекты'; Items = @($changes.Objects | Where-Object { $_.Removed }) },
        @{ Title = 'Изменённые объекты'; Items = @($changes.Objects | Where-Object { -not $_.Added -and -not $_.Removed }) }
    )
    foreach ($group in $groups) {
        if ($group.Items.Count -eq 0) { continue }
        [void]$html.Append(('<h3>{0}</h3><ul>' -f $group.Title))
        foreach ($object in $group.Items) {
            [void]$html.Append(('<li><b>{0}</b><ul>' -f (ConvertTo-Html $object.Name)))
            foreach ($part in $object.Parts) { [void]$html.Append(('<li>{0}</li>' -f (ConvertTo-Html $part))) }
            [void]$html.Append('</ul></li>')
        }
        [void]$html.Append('</ul>')
    }
    if ($changes.Marks.Count -gt 0) {
        [void]$html.Append('<h3>Пометки авторов в новом коде</h3><ul>')
        foreach ($mark in $changes.Marks) { [void]$html.Append(('<li>{0}</li>' -f (ConvertTo-Html $mark))) }
        [void]$html.Append('</ul>')
    }
}
# Внешние обработки: что записано и что поменялось по модулям и формам. Разница - по выгрузкам файлов
# обработок (старая - из справочника рабочей до обновления, новая - из temp), выгружает конфигуратор temp.
if ($touchedProcessings.Count -gt 0) {
    [void]$html.Append('<h2>Внешние обработки</h2>')
    foreach ($proc in $touchedProcessings) {
        $procTitle = $proc.ObjName
        if ($proc.Title) { $procTitle = '{0} ({1})' -f $proc.ObjName, $proc.Title }
        [void]$html.Append(('<h3>{0}</h3>' -f (ConvertTo-Html $procTitle)))
        if ($proc.Action -eq 'unregister') { [void]$html.Append('<p>Снята из справочника: публикация «Отключена», пометка удаления.</p>'); continue }
        $what = 'обновлена'
        if ($proc.IsNew -eq 'yes') { $what = 'добавлена новым элементом справочника' }
        [void]$html.Append(('<p>{0}</p>' -f (ConvertTo-Html ('{0}, версия {1} → {2}' -f $what, $proc.OldVersion, $proc.NewVersion))))
        if (@($proc.Problems).Count -gt 0) {
            [void]$html.Append('<p style="color:#c0392b">После записи:</p><ul>')
            foreach ($problem in @($proc.Problems)) { [void]$html.Append(('<li>{0}</li>' -f (ConvertTo-Html $problem))) }
            [void]$html.Append('</ul>')
        }
        if ($mode -eq 'rollback') { continue }
        $dumpRoot = Join-Path $script:RunDir 'epf-dump'
        $newDump = Get-ProcessingDump -File $proc.Source -Dir (Join-Path $dumpRoot ($proc.ObjName + '-new')) -Title ("Выгрузить в файлы {0} из temp" -f $proc.ObjName)
        if (-not $newDump) { [void]$html.Append('<p>Выгрузка обработки в файлы не получилась: разницы по модулям нет, см. run.log.</p>'); continue }
        $oldDump = ''
        if ($proc.ProdFile) { $oldDump = Get-ProcessingDump -File $proc.ProdFile -Dir (Join-Path $dumpRoot ($proc.ObjName + '-old')) -Title ("Выгрузить в файлы {0} из рабочей" -f $proc.ObjName) }
        $changes = Get-ExtensionChanges -OldDir $oldDump -NewDir $newDump -KeyPrefix 'DataProcessors/'
        if ($changes.Objects.Count -eq 0) { [void]$html.Append('<p>По выгрузке в файлы отличий нет: разница в самом файле (например, порядок или служебные данные).</p>') }
        else {
            [void]$html.Append('<ul>')
            foreach ($object in $changes.Objects) { foreach ($part in $object.Parts) { [void]$html.Append(('<li>{0}</li>' -f (ConvertTo-Html $part))) } }
            [void]$html.Append('</ul>')
        }
        if ($changes.Marks.Count -gt 0) {
            [void]$html.Append('<p>Пометки авторов в новом коде:</p><ul>')
            foreach ($mark in $changes.Marks) { [void]$html.Append(('<li>{0}</li>' -f (ConvertTo-Html $mark))) }
            [void]$html.Append('</ul>')
        }
    }
}

if ($mode -eq 'asis') { [void]$html.Append('<p>Обозначения: + новая процедура, ~ изменена, - удалена. Отчёт собран скриптом обновления по выгрузкам расширений в файлы: старая версия - прежняя выгрузка рабочей базы, новая - рабочая база сейчас.</p>') }
else { [void]$html.Append('<p>Обозначения: + новая процедура, ~ изменена, - удалена. Отчёт собран скриптом обновления по выгрузкам расширений в файлы: старая версия - из рабочей базы до обновления, новая - из тестовой.</p>') }
[void]$html.Append('</body></html>')
$articleFile = Join-Path $script:RunDir 'article.html'
[System.IO.File]::WriteAllText($articleFile, $html.ToString(), $Utf8Bom)
$articlesDir = Join-Path $deployRoot 'articles'
New-Item -ItemType Directory -Path $articlesDir -Force | Out-Null
Copy-Item -LiteralPath $articleFile -Destination (Join-Path $articlesDir ("{0}.html" -f $runId)) -Force
Write-Host ''
Write-Line ("Отчёт: {0}" -f $articleFile)

# Статья в базу знаний рабочей базы (справочник БЗ_СтатьиБазыЗнаний), если база не откачена к прежнему.
if ($outcome -eq 'updated' -and (Test-Path -LiteralPath $selfCheckEpf)) {
    $kbDir = Join-Path $script:RunDir 'kbarticle'
    New-Item -ItemType Directory -Path $kbDir -Force | Out-Null
    $kbResult = Join-Path $kbDir 'result.txt'
    $client = Invoke-ProdClient -Epf $selfCheckEpf -Parameter ("kbarticle;out={0};file={1};title={2}" -f $kbDir, $articleFile, $reportTitle) `
        -DoneFile $kbResult -TimeoutSec 600 -Title 'Статья в базу знаний'
    $kbTable = Read-KeyValueFile $kbResult
    if ($client.Done -and [string](Get-Setting $kbTable 'status' '') -eq 'done') {
        Write-Line ("[OK]   Статья в базу знаний: {0}" -f (Get-Setting $kbTable 'message' $reportTitle)) 'Green'
    }
    else {
        Write-Line ("[WARN] Статья в базу знаний: не записалась, {0}. Отчёт лежит в {1}, его можно вставить кнопкой обработки «Создать статью базы знаний»." -f (Get-Setting $kbTable 'message' 'нет результата'), $articleFile) 'Yellow'
    }
}

#endregion

#region Итог

if ($outcome -eq 'updated') {
    # Выгрузки рабочей базы - заново: следующее сравнение должно видеть новое состояние.
    if ($mode -ne 'asis') { foreach ($entry in $selected) { $null = Update-Mirror -BaseName $script:ProdBase -Extension $entry.Name } }
    # Хеш-суммы рабочей после обновления: следующий запуск по ним увидит ручную загрузку («как есть»).
    if ($selected.Count -gt 0) { Save-MirrorHashes -Names @($selected | ForEach-Object { $_.Name }) }
    # «Обновить все»: ошибки последнего прогона гейта сбрасываются - принимаются в эталон как известные
    # (они либо исправлены, либо неважны). Следующий прогон гейта покажет только новое.
    if ($mode -eq '1' -and $null -ne $lastRun) {
        Write-Line ("Сбрасываю ошибки прогона гейта {0}: принимаю в эталон как известные." -f $lastRun.Name)
        & (Join-Path $Root 'run.ps1') -AcceptBaseline $lastRun.FullName
    }
}

Clear-ProdLocks

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add($reportTitle)
$summary.Add(('Итог: ' + $outcomeNames[$outcome]))
$summary.Add(('Расширения: ' + (@($selected | ForEach-Object { $_.Name }) -join ', ')))
if ($selectedProcessings.Count -gt 0) { $summary.Add(('Внешние обработки: ' + (@($touchedProcessings | ForEach-Object { $_.ObjName }) -join ', '))) }
foreach ($item in $light) { $summary.Add(('[{0}] {1}: {2}' -f $item.Status, $item.Name, $item.Text)) }
$summary.Add(('Резервные копии: ' + $beforeDir))
[System.IO.File]::WriteAllLines((Join-Path $script:RunDir 'summary.txt'), $summary.ToArray(), $Utf8Bom)

# deploy.json - что было в этом обновлении: по нему список откатов (-Rollback) и подробности.
# Расширения и внешние обработки - отдельными списками. Резервные копии - пути от папки запуска.
$recordExtensions = @(foreach ($entry in $selected) {
        $backupRelative = ''
        if ($entry.Backup) { $backupRelative = 'before\' + (Split-Path -Leaf $entry.Backup) }
        $oldVersion = $entry.ProdVersion
        $newVersion = $entry.TempVersion
        if ($mode -eq 'asis') { $newVersion = $entry.ProdVersion; $oldVersion = '' }
        [ordered]@{ name = $entry.Name; status = $entry.Status; backup = $backupRelative; oldVersion = $oldVersion; newVersion = $newVersion }
    })
# Внешние обработки: что записано или снято. backup - прежняя версия в base64 (откат запишет её обратно),
# file - файл, который записан (или снят): по нему откат этого обновления снятую запишет снова.
$recordProcessings = @(foreach ($proc in $touchedProcessings) {
        $backupRelative = ''
        if ($proc.Backup) { $backupRelative = 'before\processings\' + (Split-Path -Leaf $proc.Backup) }
        $fileRelative = ''
        if ($proc.Action -eq 'unregister' -and $proc.RemovedFile) { $fileRelative = 'before\processings\' + (Split-Path -Leaf $proc.RemovedFile) }
        elseif ($proc.Source -and $proc.Source.StartsWith($script:RunDir + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $fileRelative = $proc.Source.Substring($script:RunDir.Length + 1) }
        $procStatus = 'OK'
        if (@($proc.Problems).Count -gt 0) { $procStatus = 'WARN' }
        [ordered]@{ name = $proc.ObjName; title = $proc.Title; fileName = $proc.FileName; action = $proc.Action; isNew = $proc.IsNew; ref = $proc.Ref
            oldVersion = $proc.OldVersion; newVersion = $proc.NewVersion; backup = $backupRelative; file = $fileRelative; status = $procStatus; problems = @($proc.Problems) }
    })
$recordGate = $null
if ($null -ne $lastRun) { $recordGate = [ordered]@{ run = $lastRun.Name; verdict = [string](Get-JsonValue $lastVerdict 'verdict' '') } }
$record = [ordered]@{
    runId        = $runId
    time         = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    base         = $script:ProdBase
    tempBase     = $script:TempBase
    user         = $env:USERNAME
    mode         = $mode
    outcome      = $outcome
    rollbackOf   = $rollbackOf
    gate         = $recordGate
    riskAccepted = $riskAccepted
    risks        = @($gateRisks)
    extensions   = $recordExtensions
    processings  = $recordProcessings
    light        = @(foreach ($item in $light) { [ordered]@{ status = $item.Status; name = $item.Name; text = $item.Text } })
    article      = $articleFile
}
[System.IO.File]::WriteAllText((Join-Path $script:RunDir 'deploy.json'), (ConvertTo-Json -InputObject $record -Depth 6), $Utf8Bom)

Write-Host ''
$finalColor = 'Green'
if ($outcome -ne 'updated') { $finalColor = 'Red' }
# План и факт по шагам: насколько прогноз длительности совпал (stats.ps1).
$statLines = @(Get-StatRunLines)
if ($statLines.Count -gt 0) {
    Write-Host ''
    Write-Host 'Длительность шагов, факт и план:'
    foreach ($line in $statLines) { Write-Host $line -ForegroundColor DarkGray }
}
Write-Line ("ИТОГ: {0}. Резервные копии: {1}" -f $outcomeNames[$outcome], $beforeDir) $finalColor
if ($riskAccepted -and $outcome -eq 'updated') {
    Write-Line ("ПРОВЕРИТЬ РАБОТОСПОСОБНОСТЬ: обновлено, хотя {0}." -f ($gateRisks -join '; ')) 'Red'
    foreach ($item in @($gateRedItems | Select-Object -First 15)) { Write-Line ("  [КРАСН] {0}" -f $item) 'Red' }
}

# После отката: то же состояние - в temp, чтобы temp и рабочая не разошлись. Берутся те же резервные копии,
# гейт идёт обычным прогоном с комплектом из них, без выбора.
if ($mode -eq 'rollback' -and $outcome -eq 'updated') {
    Write-Host ''
    $pullTemp = Confirm-Ui -Question ("База обновлена, подтянуть изменения в темп? (откатанные расширения выгружаются из {0} и гейт прогоняет их на {1} как обычно)" -f $script:ProdBase, $script:TempBase) -Yes 'Да, подтянуть' -No 'Нет'
    if ($pullTemp -eq $true) {
        # Выбора нет: берутся ровно те расширения, что откатывали, - выгрузкой из рабочей, какими они стали.
        $inboxRoot = Resolve-RootPath ([string](Get-Setting $cfg 'InboxDir' 'inbox'))
        $kitDir = Join-Path $inboxRoot ("из_рабочей_{0}" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
        New-Item -ItemType Directory -Path $kitDir -Force | Out-Null
        $taken = 0
        foreach ($entry in $selected) {
            $file = Join-Path $kitDir ("{0}_{1}_{2}.cfe" -f $script:ProdBase, $entry.Name, (Get-Date -Format 'yyyyMMdd'))
            if (Get-ExtensionData -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword -Name $entry.Name -Path $file) {
                Write-Line ("[OK]   Выгрузить {0} из {1} для temp" -f $entry.Name, $script:ProdBase) 'Green'
                $taken++
            }
            else {
                # Не выгрузилось - то же самое лежит в резервной копии, которую только что загрузили в рабочую.
                Copy-Item -LiteralPath $entry.NewFile -Destination $file -Force
                Write-Line ("[WARN] Выгрузить {0} из {1}: не вышло, беру загруженную резервную копию" -f $entry.Name, $script:ProdBase) 'Yellow'
                $taken++
            }
        }
        # Внешние обработки, возвращённые откатом, - в тот же комплект файлами: гейт запишет их в справочник temp.
        foreach ($proc in @($touchedProcessings | Where-Object { $_.Action -eq 'register' })) {
            $procFile = Join-Path $kitDir $proc.FileName
            try {
                if ($proc.SourceB64) { [System.IO.File]::WriteAllBytes($procFile, [Convert]::FromBase64String([System.IO.File]::ReadAllText($proc.SourceB64).Trim())) }
                else { Copy-Item -LiteralPath $proc.Source -Destination $procFile -Force }
                Write-Line ("[OK]   Внешняя обработка {0} для temp" -f $proc.ObjName) 'Green'
                $taken++
            }
            catch { Write-Line ("[WARN] Внешняя обработка {0} для temp: не получилась, {1}" -f $proc.ObjName, $_.Exception.Message) 'Yellow' }
        }
        foreach ($proc in @($touchedProcessings | Where-Object { $_.Action -eq 'unregister' })) {
            Write-Line ("[WARN] {0} снята из справочника рабочей; в temp её снять руками (гейт снимает только то, что записал сам)" -f $proc.ObjName) 'Yellow'
        }
        Write-Line ("Комплект для temp: {0}, файлов {1}. Запускаю гейт." -f $kitDir, $taken) 'Cyan'
        if ($UiChannel) { & (Join-Path $Root 'run.ps1') -Kit $kitDir -UiChannel $UiChannel } else { & (Join-Path $Root 'run.ps1') -Kit $kitDir }
    }
}
if ($outcome -eq 'updated') { exit 0 }
exit 1

}
finally {
    # Обязательное снятие блокировок рабочей базы. Если уже сняли выше - повторно ничего не делается.
    Clear-ProdLocks
}

#endregion
