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

    .\deploy.ps1 -ProdPreCheck
        Проверка рабочей базы перед обновлением: «Выполнить после обновления» в режиме precheck - то же, что кнопка
        «Проверка перед обновлением (только чтение)» в её форме. Что изменит загрузка комплекта и каких настроек
        не хватает. Рабочую только читает: ни блокировок, ни записи.

    .\deploy.ps1 -ComCheck
        Диагностика внешнего соединения (COM) с temp: что PowerShell видит у объектов 1С и каким способом читаются
        расширения конфигурации (версии, хеш-суммы). Только чтение, рабочую не трогает. Журнал - deploy\comcheck.

    .\deploy.ps1 -Prepare / -ApplyPrepared / -CancelPrepared
        Обновление в два приёма. -Prepare: резервные копии, взять из temp и загрузить новые версии расширений
        в конфигурацию рабочей базы - без обновления конфигурации БД, без блокировок и без завершения сеансов
        (пользователи работают на прежних версиях). -ApplyPrepared: сеансы, блокировки, обновление конфигурации
        БД, внешние обработки, проверки, отчёт. -CancelPrepared: вернуть расширения рабочей к применённым версиям.

    .\deploy.ps1 -GitExport / -GitImport
        Репозиторий расширений (ExtensionsRepo, раздел 5.23): выгрузить temp в git - ветка temp/<время> и pull
        request, включая первую выгрузку. Загрузить из git - проверка правок temp и обычный
        прогон гейта с тем, что изменилось в main. Рабочую базу не трогает.

    .\deploy.ps1 -CloseBase / -OpenBase [-LocksBase Prod|Temp]
        Закрыть базу для пользователей: предупредить (блокировка начала сеансов с времени через CloseWarnMinutes,
        10 минут), в это время запретить регламентные задания и завершить оставшиеся сеансы; конфигуратор - по
        вопросу. Блокировки остаются, пока базу не откроют: -OpenBase снимает только то, что поставило закрытие
        (deploy\close\closed-<база>.json). Только с человеком у экрана.

    Внешние обработки и отчёты справочника «Дополнительные отчёты и обработки» сравниваются так же:
    изменённые и новые в temp можно обновить вместе с расширениями или отдельно («Обновить только
    внешние обработки»: без блокировок рабочей базы, без обновления конфигурации БД). Записывает их
    «Выполнить после обновления» в режиме regepf; прежняя версия сохраняется до записи - это откат.

    .\deploy.ps1 -Delivery [-DeliveryUnattended] [-DeliveryId <номер>]
        Приёмка поставок подрядчика (раздел 5.26): файлы .cfe, .epf, .erf или папка комплекта из «Входящих» -
        реестр (оригинал, SHA-256), разбор в технической базе, объединение с main, pull request и CI, слияние
        проверенного SHA, загрузка в temp под блокировкой и прогон гейта. Рабочую базу не трогает.

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
    # Обновление в два приёма: подготовить (резервные копии и загрузка новых версий в конфигурацию рабочей без
    # обновления конфигурации БД - пользователи работают), обновить подготовленным, отменить подготовку.
    [switch]$Prepare,
    [switch]$ApplyPrepared,
    [switch]$CancelPrepared,
    # Взять из рабочей в inbox расширения или внешние обработки, которые отличаются от temp.
    [switch]$PullExtensions,
    [switch]$PullProcessings,
    # Показать состояние баз (блокировка начала сеансов, её даты и сообщение, блокировка регламентных, сеансы) и выйти.
    [switch]$BaseState,
    # Поставить или снять руками блокировку начала сеансов и блокировку регламентных заданий базы LocksBase
    # (Temp - тестовая, Prod - рабочая). Только с человеком: каждое изменение - его выбором, на рабочей - с подтверждением.
    [switch]$ManualLocks,
    # ** Хлебников С.Ю. 20261120 Закрыть базу LocksBase для пользователей (предупредить, через CloseWarnMinutes - запрет
    # входа и регламентных, завершить сеансы) и открыть её снова: снять то, что поставило закрытие.
    [switch]$CloseBase,
    [switch]$OpenBase,
    [ValidateSet('Temp', 'Prod')]
    [string]$LocksBase = 'Prod',
    # Сравнить temp и рабочую и показать разницу: расширения (по выгрузкам в файлы) или внешние обработки. Только чтение.
    [switch]$CompareExtensions,
    [switch]$CompareProcessings,
    # Проверка рабочей перед обновлением («Выполнить после обновления», режим precheck). Рабочую только читает.
    [switch]$ProdPreCheck,
    # Диагностика внешнего соединения (COM) с temp: каким способом читаются расширения. Только чтение, только temp.
    [switch]$ComCheck,
    # Снимок temp для прогона гейта (run.ps1 в конце проверок): хеш-суммы расширений и внешних обработок - в файл
    # JSON. По нему обновление рабочей сверяет, что в temp то, что проверял прогон. Только чтение, только temp.
    [string]$SnapshotTemp = '',
    # Репозиторий расширений (ExtensionsRepo): выгрузить temp в git или загрузить из git в temp. Рабочую не трогает.
    [switch]$GitExport,
    [switch]$GitImport,
    # Снимок внешних обработок рабочей в ветку prod репозитория расширений (ExtensionsProdBranch). Рабочую только читает.
    [switch]$GitProd,
    # Типовая конфигурация temp - в репозиторий TypicalRepo (только для чтения агентами), если её версия изменилась.
    # Делается и в конце -GitExport.
    [switch]$GitTypical,
    # С -GitImport: без человека (ночной прогон): правки temp - веткой и pull request, temp не трогается;
    # правок нет и main ушёл вперёд - прогон гейта с ним без вопросов (-OnNotGreen Keep).
    [switch]$GitUnattended,
    # С -GitImport: грузить только этот коммит main (полный SHA); main уже другой - не грузить.
    [string]$GitCommit = '',
    # Приёмка поставок подрядчика (раздел 5.26): «Входящие» -> разбор в технической базе -> объединение с git ->
    # pull request и CI -> загрузка проверенного SHA в temp -> гейт. DeliveryUnattended - без человека: решения
    # ждут, остальное идёт само. DeliveryId - только эта поставка.
    [switch]$Delivery,
    [switch]$DeliveryUnattended,
    [string]$DeliveryId = '',
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

# До входа в подготовку у этого запуска нет собственных блокировок.
$script:ProdLockState = $null
# ** Хлебников С.Ю. 20261120 Простой рабочей (#24): когда базу закрыли для пользователей и когда открыли снова.
$script:ProdClosedAt = $null
$script:ProdOpenedAt = $null
# Блокировка начала сеансов стояла до запуска (код тот же) и оставлена: после обновления база закрыта не нами.
$script:SessionLockKept = $false

trap {
    Write-Host ''
    Write-Host ("Остановлено: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ([string]$_.FullyQualifiedErrorId -ne [string]$_.Exception.Message -and $null -ne $_.InvocationInfo) {
        Write-Host ("  {0}" -f ($_.InvocationInfo.PositionMessage -split "`r?`n")[0]) -ForegroundColor DarkGray
    }
    if ($null -ne $script:ProdLockState) {
        try { Clear-ProdLocks } catch { Write-Host ("Блокировки снять не получилось: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
    }
    exit 1
}

$Root = $PSScriptRoot
. (Join-Path $Root 'cluster-target.ps1')
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$TestBasePattern = 'temp|test|copy|tmp|dev|sandbox|stand|тест|копи|стенд|песочниц'
$SelfCheckLineRegex = New-Object System.Text.RegularExpressions.Regex('^\d\d:\d\d:\d\d \[(ОК|ОШИБКА|ВНИМАНИЕ|ПРОПУСК|ИНФО)\]\s*(.*)$')
$SelfCheckIndent = '                    '

#region Общие функции

function Resolve-RootPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    # Явно корень скрипта: имена переменных PowerShell без учёта регистра, и локальная $root вызывающей функции
    # подменяла бы корень (было: токен для типовой искался в git\<репозиторий>\secrets).
    return (Join-Path $script:Root $Path)
}

function Get-Setting {
    param([hashtable]$Table, [string]$Key, $Default)
    if ($Table.ContainsKey($Key) -and $null -ne $Table[$Key]) { return $Table[$Key] }
    return $Default
}

# Значения, которые в выводе и журнале заменяются звёздочками целиком (Get-MaskedLine): код разрешения входа.
$script:MaskValues = @()

function Write-RunLog {
    param([string]$Text)
    $stamp = Get-Date -Format 'HH:mm:ss'
    [System.IO.File]::AppendAllText($script:RunLogPath, ("{0} {1}`r`n" -f $stamp, (Get-MaskedLine $Text)), $Utf8Bom)
}

function Write-Line {
    # Строка в консоль и в run.log.
    param([string]$Text, [string]$Color = 'Gray')
    $Text = Get-MaskedLine $Text
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
    param([string]$BaseName, [string]$User, [string]$Password, [switch]$NoUnlockCode)
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add(('/S"{0}\{1}"' -f $script:Server, $BaseName))
    if (-not $NoUnlockCode -and -not [string]::IsNullOrEmpty($script:UnlockCode)) { $list.Add(('/UC"{0}"' -f $script:UnlockCode)) }
    if (-not [string]::IsNullOrEmpty($User)) {
        $list.Add(('/N"{0}"' -f $User))
        if (-not [string]::IsNullOrEmpty($Password)) { $list.Add(('/P"{0}"' -f $Password)) }
    }
    return $list.ToArray()
}

function Get-MaskedLine {
    # Чувствительное - звёздочками, одной обработкой на консоль, run.log и всё, что из них собирается (отчёты, итог
    # в GitHub): пароль и код разрешения входа в ключах запуска 1С (/P, /UC) и в строке соединения (Pwd=, UC=) и
    # само значение UnlockCode, где бы оно ни встретилось, - если в нём шесть знаков и больше (короткий код вроде
    # «0» совпал бы с обычными цифрами текста; он закрыт в ключах и строке соединения).
    param([string]$Line)
    if (-not $Line) { return $Line }
    $masked = [regex]::Replace([regex]::Replace($Line, '/P"[^"]*"', '/P"***"'), '/UC"[^"]*"', '/UC"***"')
    $masked = [regex]::Replace($masked, '(?i)\b(Pwd|UC)="(?:[^"]|"")*"', '$1="***"')
    foreach ($secret in @($script:MaskValues)) { if ($secret) { $masked = $masked.Replace([string]$secret, '***') } }
    return $masked
}

function Invoke-V8 {
    # Запускает 1С и ждёт завершения не дольше таймаута. По таймауту процесс снимается.
    # NoResultLine - строку итога операции («готово за ...») напишет вызывающий: у него есть текст ошибки из лога 1С.
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec, [string]$Title = '', [switch]$NoResultLine)
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
        if (-not $NoResultLine) {
            $problem = ''
            if (-not $finished) { $problem = 'не уложилось в {0} мин, процесс снят' -f [int]($TimeoutSec / 60) }
            elseif ($exitCode -ne 0) { $problem = 'код {0}' -f $exitCode }
            $resultStatus = 'FAIL'
            if ($statStatus -eq 'OK') { $resultStatus = 'OK' }
            Write-UiOperationResult -Title $Title -Status $resultStatus -Seconds $seconds -Problem $problem
        }
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

function Test-DesignerBusy {
    # Пакетный конфигуратор не подключился: конфигурация базы открыта в другом конфигураторе.
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ($null -eq $line) { continue }
        if ($line.Contains('уже работает конфигуратор') -or $line.Contains('уже открыта Конфигуратором') -or $line.Contains('Ошибка блокировки информационной базы для конфигурирования')) { return $true }
    }
    return $false
}

function Resolve-DesignerBusy {
    # Конфигуратор базы открыт в другом сеансе - дальше идти нельзя, пока он открыт. Спрашиваем: закрыть отсюда
    # (только конфигураторы этой базы, имя - целиком) или ждать, пока закроют сами (опрос раз в 3 секунды).
    # Отмена - прогон завершается с записью «отменено пользователем». Без человека - $false (как раньше: ошибка шага).
    param([string]$BaseName, [string]$Title)
    if (-not (Test-UiCanAsk)) { return $false }
    $link = Connect-ClusterAgent
    $designers = @(Get-BaseSessions $link $BaseName | Where-Object { -not $_.IsError -and $_.IsDesigner })
    Write-Line ("  {0}: открыт конфигуратор {1} - дальше нельзя, пока он открыт" -f $Title, $BaseName) 'Yellow'
    foreach ($entry in $designers) { Write-Line ('    ' + $entry.Text) 'Yellow' }
    $answer = Read-UiChoice -Header ("Открыт конфигуратор {0}: «{1}» не может идти дальше. Закрой его сам - скрипт увидит и продолжит, или:" -f $BaseName, $Title) `
        -Keys @('1', '2') -Labels @('Закрыть отсюда (сеанс прерывается, несохранённые правки в нём пропадут)', 'Отмена (прогон завершится)') -CancelKey '2' -Poll {
        $now = @(Get-BaseSessions $link $BaseName)
        if (@($now | Where-Object { $_.IsError }).Count -eq 0 -and @($now | Where-Object { $_.IsDesigner }).Count -eq 0) { return 'closed' }
        return ''
    }
    if ($answer -eq '2') {
        Write-RunLog ("Отменено пользователем: открыт конфигуратор {0} ({1})" -f $BaseName, $Title)
        throw ("отменено пользователем: открыт конфигуратор {0}, «{1}» не выполнено" -f $BaseName, $Title)
    }
    if ($answer -eq '1') {
        foreach ($line in @(Stop-BaseSessions -Link $link -BaseName $BaseName -Designers)) { Write-Line ('  ' + $line) }
        for ($wait = 0; $wait -lt 10; $wait++) {
            Start-Sleep -Seconds 3
            if (@(Get-BaseSessions $link $BaseName | Where-Object { -not $_.IsError -and $_.IsDesigner }).Count -eq 0) { break }
        }
    }
    Write-Line ("  конфигуратор {0} закрыт, повторяю: {1}" -f $BaseName, $Title) 'Green'
    Write-RunLog ("Конфигуратор {0} закрыт ({1}), повтор: {2}" -f $BaseName, $answer, $Title)
    return $true
}

function Invoke-Designer {
    # Пакетный конфигуратор указанной базы. Лог - в папке запуска. База открыта в другом конфигураторе -
    # вопрос (Resolve-DesignerBusy) и повтор той же команды.
    param([string]$BaseName, [string[]]$Command, [string]$LogName, [int]$TimeoutSec, [string]$Title = '')
    $user = $script:TempUser
    $password = $script:TempPassword
    if ($BaseName -ieq $script:ProdBase) { $user = $script:ProdUser; $password = $script:ProdPassword }
    $logPath = Join-Path $script:RunDir $LogName
    $argList = @('DESIGNER') + @(Get-ConnectionArgs -BaseName $BaseName -User $user -Password $password) +
        @('/DisableStartupDialogs', '/DisableStartupMessages') + $Command + @('/Out', ('"{0}"' -f $logPath))
    while ($true) {
        if ($BaseName -ieq $script:ProdBase -and $Command[0] -in @('/LoadCfg', '/LoadConfigFromFiles', '/DeleteCfg', '/UpdateDBCfg')) {
            $null = Get-BaseInfo $deployLink $BaseName $user $password
        }
        $result = Invoke-V8 -Exe $script:V8 -Arguments $argList -TimeoutSec $TimeoutSec -Title $Title -NoResultLine
        $lines = @(Read-V8Log $logPath)
        if ($Title) {
            # Итог операции - сразу под её строкой «начато»: готово или нет, за сколько и что написал конфигуратор.
            $problem = ''
            if ($result.TimedOut) { $problem = 'не уложилось в {0} мин, процесс снят' -f [int]($TimeoutSec / 60) }
            elseif ($result.ExitCode -ne 0) { $problem = 'код {0}: {1}' -f $result.ExitCode, ((@($lines | Where-Object { $_ }) | Select-Object -First 3) -join ' ') }
            $resultStatus = 'OK'
            if ($problem) { $resultStatus = 'FAIL' }
            Write-UiOperationResult -Title $Title -Status $resultStatus -Seconds $result.Seconds -Problem $problem
        }
        if ($result.ExitCode -eq 0 -or $result.TimedOut -or -not (Test-DesignerBusy $lines)) { break }
        if (-not (Resolve-DesignerBusy -BaseName $BaseName -Title (Get-NonEmptyTitle $Title $LogName))) { break }
    }
    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        TimedOut = $result.TimedOut
        Seconds  = $result.Seconds
        Log      = $logPath
        Lines    = $lines
        Text     = (($lines | Where-Object { $_ }) -join ' ')
    }
}

function Get-NonEmptyTitle {
    param([string]$Title, [string]$Fallback)
    if ($Title) { return $Title }
    return $Fallback
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
        Server          = $script:Server
        Clusters        = @()
        Errors          = @()
        ClusterUser     = [string](Get-Setting $cfg 'ClusterAdmin' '')
        ClusterPassword = [string](Get-PlainPassword ([string](Get-Setting $cfg 'ClusterAdminPassFile' '')))
    }
    $agentAddress = [string](Get-Setting $cfg 'ClusterAgent' '')
    if (-not $agentAddress) { $agentAddress = 'tcp://' + ($script:Server -split ':')[0] }
    try {
        $link.Connector = New-V8Connector
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

function Get-SessionTarget {
    param($Link, [string]$BaseName)
    if ($BaseName -ieq $script:ProdBase) { return (Resolve-ClusterBase $Link $BaseName $script:ProdUser $script:ProdPassword) }
    if ($BaseName -ieq $script:TempBase) { return (Resolve-ClusterBase $Link $BaseName $script:TempUser $script:TempPassword) }
    throw ("База {0} отсутствует в текущем профиле." -f $BaseName)
}

function Get-BaseSessions {
    # Сеансы базы по данным агента: имя базы сравнивается целиком.
    param($Link, [string]$BaseName)
    $list = New-Object System.Collections.Generic.List[object]
    try {
        $target = Get-SessionTarget $Link $BaseName
        foreach ($session in @($Link.Agent.GetInfoBaseSessions($target.Cluster, $target.ShortBase))) {
            $list.Add([pscustomobject]@{ Text = (Format-ClusterSession $session); IsDesigner = ([string]$session.AppID -eq 'Designer'); IsError = $false })
        }
    }
    catch { $list.Add([pscustomobject]@{ Text = $_.Exception.Message; IsDesigner = $false; IsError = $true }) }
    return $list.ToArray()
}

function Stop-BaseSessions {
    # Завершает сеансы базы. Без -Designers конфигураторы не трогаются, с -Designers - только они.
    param($Link, [string]$BaseName, [switch]$Designers)
    $lines = New-Object System.Collections.Generic.List[string]
    $target = Get-SessionTarget $Link $BaseName
    foreach ($session in @($Link.Agent.GetInfoBaseSessions($target.Cluster, $target.ShortBase))) {
        $isDesigner = ([string]$session.AppID -eq 'Designer')
        if ([bool]$Designers -ne $isDesigner) { continue }
        $description = Format-ClusterSession $session
        try { $Link.Agent.TerminateSession($target.Cluster, $session); $lines.Add(("{0} - завершён" -f $description)) }
        catch { $lines.Add(("{0} - не завершился: {1}" -f $description, $_.Exception.Message)) }
    }
    foreach ($line in $lines) { Write-RunLog ('Завершение сеансов: ' + $line) }
    return $lines.ToArray()
}

function Get-BaseInfo {
    param($Link, [string]$BaseName, [string]$User, [string]$Password)
    return (Get-CurrentClusterBase $Link $BaseName $User $Password)
}

function Read-BaseInfoAgain {
    param($Target, [string]$BaseName)
    return (Read-ClusterBaseAgain $Target $BaseName)
}

function Wait-ProdWarnLock {
    # Вариант «Предупредить пользователей» в вопросе о сеансах: блокировка начала сеансов стоит с будущего
    # времени, пользователи видят предупреждение, а deploy делает то, что рабочую не меняет (выгрузки,
    # резервные копии, взять из temp). Загрузке и обновлению БД нужна закрытая база: здесь дождаться начала
    # блокировки (или пока все выйдут сами), дать клиентам закрыться самим, оставшиеся сеансы завершить.
    # Раньше времени (все вышли или «не ждать») начало блокировки переносится на сейчас - иначе в базу можно
    # было бы войти посреди обновления.
    $lockAt = [datetime]$script:WarnLockAt
    $script:WarnLockAt = $null
    # Клиенты БСП проверяют блокировку раз в минуту: после её начала - минута с запасом, чтобы закрылись сами,
    # но не дольше самого предупреждения.
    $graceSec = [Math]::Min(70, [Math]::Max(3, [int]($deployWarnMinutes * 60)))
    $script:WarnLockStart = $lockAt
    $script:WarnDeadline = $lockAt.AddSeconds($graceSec)
    $script:WarnLink = Connect-ClusterAgent
    $script:WarnShown = ''
    Write-Host ''
    Write-Host 'Закрытие рабочей базы:'
    $header = "Пользователи {0} предупреждены: в {1} база закрывается, в {2} оставшиеся сеансы deploy завершит сам; все выйдут раньше - продолжит сразу. Или:" -f `
        $script:ProdBase, $lockAt.ToString('HH:mm'), $script:WarnDeadline.ToString('HH:mm:ss')
    $answer = Read-UiChoice -Header $header -Dock -Keys @('1', '2') -CancelKey '2' -Labels @(
        'Не ждать: закрыть базу и завершить сеансы сейчас',
        'Отмена: в рабочую ничего не загружать, блокировки снять') -Poll {
        $list = @(Get-BaseSessions $script:WarnLink $script:ProdBase)
        $late = ((Get-Date) -ge $script:WarnDeadline)
        if (@($list | Where-Object { $_.IsError }).Count -gt 0) { if ($late) { return 'time' }; return '' }
        $users = @($list | Where-Object { -not $_.IsDesigner })
        if ($users.Count -eq 0) { return 'empty' }
        if ($late) { return 'time' }
        $minutesLeft = [int][Math]::Ceiling(($script:WarnLockStart - (Get-Date)).TotalMinutes)
        $shown = "база закрыта, сеансов осталось: {0}" -f $users.Count
        if ($minutesLeft -gt 0) { $shown = "до закрытия {0} мин, сеансов: {1}" -f $minutesLeft, $users.Count }
        if ($shown -ne $script:WarnShown) { $script:WarnShown = $shown; Write-Host ('  ' + $shown) -ForegroundColor DarkGray }
        return ''
    }
    if ($answer -eq '2') { throw ("обновление {0} отменено во время предупреждения пользователей: в рабочую ничего не загружено" -f $script:ProdBase) }
    if ($answer -eq 'empty') { Write-Line ("  в {0} сеансов не осталось" -f $script:ProdBase) 'Green' }
    if ($answer -eq 'time') { Write-Line ("  {0}: завершаю оставшиеся сеансы" -f (Get-Date -Format 'HH:mm')) }
    if ($script:ProdLockState.Expected.Count) {
        $target = Get-BaseInfo -Link $script:WarnLink -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
        $infoBase = Read-BaseInfoAgain $target $script:ProdBase
        if (-not (Test-GateSessionLock $script:ProdLockState $infoBase)) {
            throw 'блокировку начала сеансов изменили во время предупреждения пользователей'
        }
        if ((Get-Date) -lt $lockAt) {
            $until = [datetime]$script:WarnLockUntil
            $message = "Идёт обновление расширений, база заблокирована до {0}" -f $until.ToString('HH:mm')
            try { Set-GateSessionLock $script:ProdLockState $target ((Get-Date).AddMinutes(-30)) $until $script:UnlockCode $message { param($t) Read-BaseInfoAgain $t $script:ProdBase } }
            finally { Save-ProdLockFile }
            Write-Line '  блокировка начала сеансов действует с этой минуты' 'Green'
            Write-RunLog 'Начало блокировки сеансов перенесено на сейчас'
            $script:ProdClosedAt = Get-Date
        }
        else { $script:ProdClosedAt = $lockAt }
    }
    foreach ($line in @(Stop-BaseSessions -Link $script:WarnLink -BaseName $script:ProdBase)) { Write-Line ('  ' + $line) }
}

function Test-ProdPlainLogin {
    # ** Хлебников С.Ю. 20261120 Вход без кода разрешения (#2). «Проверил: блокировок нет» - это флажки в кластере;
    # здесь - сам вход, каким его увидит пользователь: тонкий клиент с «Канарейкой» без /UC. Только чтение.
    # Возвращает Status (OK, FAIL, WARN, SKIP) и Text. Исход обновления от него не зависит: расширения уже
    # обновлены (или откачены), не получился только вход.
    if ($script:SessionLockKept) {
        return [pscustomobject]@{ Status = 'SKIP'; Text = 'не проверял: блокировка начала сеансов стояла до обновления и оставлена, без кода в базу не войти' }
    }
    if ($plainLoginTimeoutSec -le 0) { return [pscustomobject]@{ Status = 'SKIP'; Text = 'не проверял: PlainLoginTimeoutSec = 0' } }
    if (-not (Test-Path -LiteralPath $canaryEpf)) { return [pscustomobject]@{ Status = 'WARN'; Text = "не проверял: нет обработки $canaryEpf" } }
    $plainFile = Join-Path $script:RunDir 'canary-plain.txt'
    try {
        $client = Invoke-ProdClient -Epf $canaryEpf -Parameter ("canary;out={0};wait=3" -f $plainFile) -DoneFile $plainFile `
            -TimeoutSec $plainLoginTimeoutSec -Title 'Вход без кода разрешения' -NoUnlockCode
    }
    catch { return [pscustomobject]@{ Status = 'FAIL'; Text = ("клиент не запустился: {0}" -f $_.Exception.Message) } }
    if ($client.Done) { return [pscustomobject]@{ Status = 'OK'; Text = ("вошёл за {0} с" -f $client.Seconds) } }
    # Не вошёл. Снятие блокировок - ещё раз (если прошлое не подтвердилось, оно повторится), и что в свойствах сейчас.
    Clear-ProdLocks
    $now = 'свойства базы прочитать не смог'
    try {
        $target = Get-BaseInfo -Link (Connect-ClusterAgent) -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
        if ([bool](Read-BaseInfoAgain $target $script:ProdBase).SessionsDenied) { $now = 'в свойствах базы блокировка начала сеансов стоит' }
        else { $now = 'в свойствах базы блокировки начала сеансов нет' }
    }
    catch { $now = ('свойства базы прочитать не смог: ' + $_.Exception.Message) }
    return [pscustomobject]@{ Status = 'FAIL'; Text = ("за {0} с не вошёл; {1}. Войди в {2} обычным ярлыком; не пускает - консоль кластера, свойства базы: снять «Блокировка начала сеансов включена»" -f $client.Seconds, $now, $script:ProdBase) }
}

function Get-ProdDowntimeText {
    # Сколько рабочая была закрыта для пользователей этим запуском: от начала блокировки сеансов до её снятия.
    if ($null -eq $script:ProdClosedAt -or $null -eq $script:ProdOpenedAt) { return '' }
    $span = [datetime]$script:ProdOpenedAt - [datetime]$script:ProdClosedAt
    if ($span.TotalSeconds -lt 0) { $span = [timespan]::Zero }
    return ("Простой {0}: {1} мин {2:00} с (вход закрыт в {3}, открыт в {4})" -f $script:ProdBase, [int][Math]::Floor($span.TotalMinutes), $span.Seconds,
        ([datetime]$script:ProdClosedAt).ToString('HH:mm:ss'), ([datetime]$script:ProdOpenedAt).ToString('HH:mm:ss'))
}

function Clear-ProdLocks {
    $state = $script:ProdLockState
    if ($null -eq $state -or (-not $state.Expected.Count -and -not $state.JobsSet)) { return }
    for ($try = 1; $try -le 2; $try++) {
        try {
            $target = Get-BaseInfo -Link (Connect-ClusterAgent) -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
            $released = Restore-GateLocks $state $target $true { param($t) Read-BaseInfoAgain $t $script:ProdBase }
            if ($released) { Write-Line ("Снял с {0}: {1}." -f $script:ProdBase, $released) 'Green' }
            # ** Хлебников С.Ю. 20261120 Простой (#24): считается, только если базу закрывал этот запуск и он же открыл.
            if ($released -and ([string]$released).Contains('начала сеансов') -and $null -ne $script:ProdClosedAt -and $null -eq $script:ProdOpenedAt) {
                $script:ProdOpenedAt = Get-Date
                $downtime = Get-ProdDowntimeText
                Write-Line ('  ' + $downtime)
                Write-RunLog $downtime
            }
            Save-ProdLockFile
            return
        }
        catch {
            if ($try -lt 2 -and ($state.Expected.Count -or $state.JobsSet)) { Start-Sleep -Seconds 5; continue }
            Write-Line ("НЕ СНЯЛ или не подтвердил снятие блокировок {0}: {1}. Проверь свойства базы в консоли кластера." -f $script:ProdBase, $_.Exception.Message) 'Red'
        }
        break
    }
    Save-ProdLockFile
}

# ** Хлебников С.Ю. 20261120 Блокировки этого запуска - в файле locks.json папки запуска (#29): что стояло до запуска
# (Before), что поставил он сам в том виде, в каком вернул кластер (Expected), ставил ли запрет регламентных (JobsSet),
# метка в сообщении. Снял всё - файла нет. Процесс погиб - по файлу при следующем запуске снимается только своё.
function ConvertTo-LockJson {
    # Настройки запрета сеансов -> для JSON: даты - строкой с точным временем ('o'), чтобы прочитать их назад без потерь.
    param($Settings)
    if ($null -eq $Settings) { return $null }
    $out = [ordered]@{}
    foreach ($key in @($Settings.Keys)) {
        $value = $Settings[$key]
        if ($value -is [datetime]) { $value = $value.ToString('o') }
        $out[$key] = $value
    }
    return $out
}

function ConvertFrom-LockJson {
    # Назад в hashtable для Test-GateSessionSettings / Restore-GateLocks.
    param($Settings)
    if ($null -eq $Settings) { return $null }
    $out = @{}
    foreach ($prop in $Settings.PSObject.Properties) {
        $value = $prop.Value
        if (($prop.Name -eq 'DeniedFrom' -or $prop.Name -eq 'DeniedTo') -and $null -ne $value -and [string]$value) {
            $value = [datetime]::Parse([string]$value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        elseif ($prop.Name -eq 'SessionsDenied') { $value = [bool]$value }
        elseif ($prop.Name -eq 'DeniedFrom' -or $prop.Name -eq 'DeniedTo') { $value = $null }
        $out[$prop.Name] = $value
    }
    return $out
}

function Save-ProdLockFile {
    $lockFile = Join-Path $script:RunDir 'locks.json'
    $state = $script:ProdLockState
    try {
        if ($null -eq $state -or (-not $state.Expected.Count -and -not $state.JobsSet)) {
            if (Test-Path -LiteralPath $lockFile) { Remove-Item -LiteralPath $lockFile -Force }
            return
        }
        $processStart = ''
        try { $processStart = (Get-Process -Id $PID).StartTime.ToString('yyyy-MM-ddTHH:mm:ss') } catch { $processStart = '' }
        # Цель - кластер и ИБ (как в журнале обновления): то же имя базы на другом кластере - не наша.
        $identity = ''
        if ($null -ne $deployTarget) { $identity = [string]$deployTarget.Identity }
        $record = [ordered]@{
            base = $script:ProdBase; target = $identity; pid = $PID; processStart = $processStart; marker = $state.Marker; jobsSet = [bool]$state.JobsSet
            before = (ConvertTo-LockJson $state.Before); expected = @(foreach ($one in $state.Expected) { ConvertTo-LockJson $one })
        }
        Save-DeployJournalFile -Path $lockFile -Record $record
    }
    catch { Write-RunLog ('locks.json не записался: ' + $_.Exception.Message) }
}

function Resolve-InterruptedLocks {
    # locks.json запусков, чей процесс уже не живёт: что из блокировок рабочей до сих пор их, и - по вопросу - снять
    # только своё (Restore-GateLocks возвращает запрет сеансов к параметрам до запуска). Чужое и изменённое не трогается.
    # Возвращает, у скольких запусков нашлись свои блокировки (снятые или оставленные).
    # ReadOnly (-StatusOnly: без deploy.lock) - только показать, ничего не снимать.
    param([switch]$ReadOnly)
    if (-not (Test-Path -LiteralPath $deployRoot)) { return 0 }
    $found = 0
    foreach ($dir in @(Get-ChildItem -LiteralPath $deployRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name)) {
        $lockFile = Join-Path $dir.FullName 'locks.json'
        if (-not (Test-Path -LiteralPath $lockFile)) { continue }
        if ($dir.FullName -eq $script:RunDir) { continue }
        $record = $null
        try { $record = (Get-Content -LiteralPath $lockFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { continue }
        if ([string](Get-JsonValue $record 'base' '') -ne $script:ProdBase) { continue }
        $lockPid = [int](Get-JsonValue $record 'pid' 0)
        if ($lockPid -gt 0) {
            $alive = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
            if ($null -ne $alive) {
                $startText = ''
                try { $startText = $alive.StartTime.ToString('yyyy-MM-ddTHH:mm:ss') } catch { $startText = '' }
                if (-not $startText -or $startText -eq [string](Get-JsonValue $record 'processStart' '')) { throw ("обновление {0} {1} ещё идёт (процесс {2}): дождись его конца" -f $script:ProdBase, $dir.Name, $lockPid) }
            }
        }
        $state = New-GateLockState
        $state.Marker = [string](Get-JsonValue $record 'marker' '')
        $state.JobsSet = [bool](Get-JsonValue $record 'jobsSet' $false)
        $state.Before = ConvertFrom-LockJson (Get-JsonValue $record 'before' $null)
        $state.Expected = @(foreach ($one in @(Get-JsonValue $record 'expected' @())) { ConvertFrom-LockJson $one })
        $target = Get-BaseInfo -Link (Connect-ClusterAgent) -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
        $savedTarget = [string](Get-JsonValue $record 'target' '')
        if (-not $savedTarget -or $savedTarget -cne [string]$target.Identity) {
            # Сверять нечего: другая цель или цель не записана. Файл остаётся - он про ту базу, где ставились блокировки.
            Write-Line ("  locks.json прерванного обновления {0}: кластер или ИБ не совпадает с текущим профилем {1}\{2} - не сверяю и не снимаю. Блокировки той базы - консоль кластера." -f $dir.Name, $script:Server, $script:ProdBase) 'Yellow'
            Write-RunLog ("locks.json {0}: цель «{1}» не совпала с текущей" -f $dir.Name, $savedTarget)
            continue
        }
        $now = Read-BaseInfoAgain $target $script:ProdBase
        $own = New-Object System.Collections.Generic.List[string]
        $foreign = New-Object System.Collections.Generic.List[string]
        if ($state.Expected.Count) {
            if ($null -ne $state.Before -and (Test-GateSessionLock $state $now)) { $own.Add('блокировка начала сеансов (поставил прерванный запуск; вернётся к параметрам до него)') }
            else {
                $state.Expected = @()
                if ([bool]$now.SessionsDenied) { $foreign.Add('блокировка начала сеансов стоит, но не та, что ставил прерванный запуск - не трогаю') }
            }
        }
        if ($state.JobsSet) {
            if ([bool]$now.ScheduledJobsDenied) { $own.Add('запрет регламентных заданий (ставил прерванный запуск; владельца у флага нет - если его с тех пор поставил кто-то другой, ответь «нет»)') }
            else { $state.JobsSet = $false }
        }
        Write-RunLog ("Блокировки прерванного обновления {0}: своих {1}, чужих {2}" -f $dir.Name, $own.Count, $foreign.Count)
        if ($own.Count -eq 0) {
            foreach ($line in $foreign) { Write-Line ('  ' + $line) 'Yellow' }
            Write-Line ("  блокировок прерванного обновления {0} на {1} нет" -f $dir.Name, $script:ProdBase) 'Green'
            if (-not $ReadOnly) { Remove-Item -LiteralPath $lockFile -Force }
            continue
        }
        Show-UiTitle -Text ("Прерванное обновление {0} оставило на {1} блокировки" -f $dir.Name, $script:ProdBase) -Kind 'bad' -More (@($own.ToArray()) + @($foreign.ToArray()))
        if ($ReadOnly) { Write-Line '  только просмотр: не снимаю. Снять - обычным запуском обновления рабочей.' 'Yellow'; continue }
        $found++
        if (-not (Test-UiCanAsk)) { Write-Line '  не снимаю: спросить некого. Снять - консоль кластера или deploy в меню гейта.' 'Yellow'; continue }
        $release = Confirm-Ui -Question ("Снять блокировки {0}, оставленные прерванным обновлением {1}: {2}?" -f $script:ProdBase, $dir.Name, ($own -join '; ')) -Yes 'Да, снять' -No 'Нет, оставить' -DefaultNo
        if ($release -ne $true) { Write-Line '  оставил как есть. Снять потом - этим же вопросом при следующем запуске или в консоли кластера.' 'Yellow'; continue }
        $released = Restore-GateLocks $state $target $true { param($t) Read-BaseInfoAgain $t $script:ProdBase }
        if ($released) { Write-Line ("Снял с {0}: {1} (оставило прерванное обновление {2})." -f $script:ProdBase, $released, $dir.Name) 'Green' }
        Write-RunLog ("Сняты блокировки прерванного обновления {0}: {1}" -f $dir.Name, $released)
        Remove-Item -LiteralPath $lockFile -Force
    }
    return $found
}
# ** Хлебников С.Ю. 20261120 конец

#endregion

#region Настройки

$configPath = $Config
if ([string]::IsNullOrWhiteSpace($configPath)) { $configPath = Join-Path $Root 'config.psd1' }
if (-not (Test-Path -LiteralPath $configPath)) { throw "Нет файла настроек: $configPath" }
# Дочерние запуски run.ps1 (принять в эталон, прогон после отката) - с тем же профилем, полным путём (#12).
$childConfig = @{}
if ($Config) { $childConfig['Config'] = (Resolve-Path -LiteralPath $configPath).Path }

function Read-DeployConfig {
    # config.psd1 и настройки площадки (config.site.psd1 из поставки) - так же, как в run.ps1: ключа нет в config.psd1
    # или он там пустой (@() или '') - берётся из config.site.psd1.
    $read = Import-PowerShellDataFile -LiteralPath $configPath
    $sitePath = Join-Path $Root 'config.site.psd1'
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

$cfg = Read-DeployConfig

# Меню и вопросы (ui.ps1): из ci.exe их рисует ci.exe, без него - консоль. Нужны уже здесь: если в настройках
# чего-то не хватает, скрипт спрашивает и записывает в config.psd1.
. (Join-Path $Root 'locks.ps1')
. (Join-Path $Root 'ui.ps1')
Initialize-Ui -Channel $UiChannel

$script:Server = [string](Get-Setting $cfg 'Server' '')
$script:TempBase = [string](Get-Setting $cfg 'Base' '')
$script:ProdBase = [string](Get-Setting $cfg 'ProdBase' '')
# Код разрешения входа: один и тот же для блокировки рабочей и для всех входов (конфигуратор, внешнее соединение). Пусто - 0.
$script:UnlockCode = [string](Get-Setting $cfg 'UnlockCode' '0')
if ([string]::IsNullOrWhiteSpace($script:UnlockCode)) { $script:UnlockCode = '0' }
if ($script:UnlockCode.Length -ge 6) { $script:MaskValues = @($script:MaskValues) + @($script:UnlockCode) }
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
        $cfg = Read-DeployConfig
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
# ** Хлебников С.Ю. 20261120 Базы - в шапку ci.exe (событие context): после того как рабочая точно определена.
if ($UiChannel) { Send-UiEvent @{ kind = 'context'; text = ('рабочая {0} · temp {1}' -f $script:ProdBase, $script:TempBase) } }

$binDir = [string](Get-Setting $cfg 'V8Bin' '')
$script:V8 = Join-Path $binDir '1cv8.exe'
$script:V8C = Join-Path $binDir '1cv8c.exe'
if (-not (Test-Path -LiteralPath $script:V8)) { throw "Не нашёл конфигуратор: $($script:V8)" }
# Подставной COM - только для тестов без 1С и только с подставной 1С: с настоящим 1cv8.exe скрипт отказывается,
# иначе подставной COM «не видел» бы сеансов и блокировок, а конфигуратор работал бы с настоящей рабочей базой.
$script:FakeComScript = ''
if ($env:CI_FAKE_COM) {
    $v8Info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($script:V8)
    if ($v8Info.CompanyName -or $v8Info.ProductName) { throw ("Задан CI_FAKE_COM (подставной COM для тестов), а {0} - настоящая 1С. Убери переменную CI_FAKE_COM." -f $script:V8) }
    $script:FakeComScript = Join-Path $Root 'test\fakecom.ps1'
    . $script:FakeComScript
}

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
# Тестовые расширения и движок тестов живут только в тестовой базе: в рабочую они не уходят никогда.
$unitOnly = @(@(Get-Setting $cfg 'UnitTestExtensions' @() | Where-Object { $_ }) + @([string](Get-Setting $cfg 'UnitTestEngine' 'YAXUNIT')) | Where-Object { $_ })
foreach ($name in $deployExtensions) {
    if (@($unitOnly | Where-Object { [string]$_ -ieq [string]$name }).Count -gt 0) {
        throw ("{0} - тестовое расширение (UnitTestExtensions или UnitTestEngine), а стоит в DeployExtensions/Extensions config.psd1: в рабочую тесты не уходят. Убери его оттуда." -f $name)
    }
}
$deniedFrom = [int](Get-Setting $cfg 'DeployDeniedFrom' 22)
$deniedTo = [int](Get-Setting $cfg 'DeployDeniedTo' 2)
# ** Хлебников С.Ю. 20261120 Часы обновления рабочей - из настроек (DeployDeniedFrom/To): подсказка, проверка перед
# подтверждением и повторно после него (пока ждали ответа, могло наступить запретное время), конец окна для прогноза.
function Test-DeployHourDenied {
    param([datetime]$At)
    if ($deniedFrom -eq $deniedTo) { return $false }
    if ($deniedFrom -gt $deniedTo) { return ($At.Hour -ge $deniedFrom -or $At.Hour -lt $deniedTo) }
    return ($At.Hour -ge $deniedFrom -and $At.Hour -lt $deniedTo)
}
function Get-DeployWindowText {
    # Когда рабочую обновлять можно: с конца запрета до его начала.
    if ($deniedFrom -eq $deniedTo) { return 'в любое время (DeployDeniedFrom = DeployDeniedTo)' }
    return ('с {0:00}:00 до {1:00}:00' -f $deniedTo, $deniedFrom)
}
function Get-DeployWindowEnd {
    # Когда кончится разрешённое окно, если сейчас оно идёт: ближайшее начало запрета. $null - запрета нет.
    param([datetime]$At)
    if ($deniedFrom -eq $deniedTo) { return $null }
    $end = $At.Date.AddHours($deniedFrom)
    if ($end -le $At) { $end = $end.AddDays(1) }
    return $end
}
# ** Хлебников С.Ю. 20261120 конец
$sessionLockHours = [int](Get-Setting $cfg 'SessionLockHours' 2)
if ($sessionLockHours -lt 1) { $sessionLockHours = 1 }
# Предупреждение пользователей рабочей перед обновлением: за сколько минут до начала блокировки сеансов.
# Клиенты БСП это время показывают предупреждение и в назначенный час закрываются сами, deploy тем
# временем делает выгрузки и резервные копии. 0 - без предупреждения.
$deployWarnMinutes = [double](Get-Setting $cfg 'DeployWarnMinutes' 10)
if ($deployWarnMinutes -lt 0) { $deployWarnMinutes = 0 }
$script:WarnLockAt = $null
$script:WarnLockUntil = $null
# ** Хлебников С.Ю. 20261120 Закрыть базу (-CloseBase): за сколько минут до закрытия предупреждать пользователей.
# 0 - варианта с предупреждением нет, только «закрыть сейчас».
$closeWarnMinutes = [double](Get-Setting $cfg 'CloseWarnMinutes' 10)
if ($closeWarnMinutes -lt 0) { $closeWarnMinutes = 0 }
$prodSelfCheckForms = [bool](Get-Setting $cfg 'ProdSelfCheckForms' $false)
$prodSelfCheckTimeoutMin = [int](Get-Setting $cfg 'ProdSelfCheckTimeoutMin' 60)
# Сколько ждать ответа на «оставить или откатить» после проверок на рабочей. Нет ответа - обновление
# остаётся: блокировки рабочей (сеансы, регламентные) не должны висеть до утра из-за вопроса. 0 - не спрашивать.
$deployKeepTimeoutMin = [int](Get-Setting $cfg 'DeployKeepTimeoutMin' 10)
if ($deployKeepTimeoutMin -lt 0) { $deployKeepTimeoutMin = 0 }
$timeoutLoadSec = 60 * [int](Get-Setting $cfg 'TimeoutLoadMin' 30)
$timeoutUpdateSec = 60 * [int](Get-Setting $cfg 'TimeoutUpdateMin' 120)
$canaryEpf = Resolve-RootPath ([string](Get-Setting $cfg 'CanaryEpf' 'tools\Канарейка.epf'))
$selfCheckEpf = Resolve-RootPath ([string](Get-Setting $cfg 'SelfCheckEpf' 'tools\ВыполнитьПослеОбновления.epf'))
$canaryTimeoutSec = [int](Get-Setting $cfg 'CanaryTimeoutSec' 300)
# ** Хлебников С.Ю. 20261120 Вход без кода разрешения после снятия блокировок (#2): сколько ждать, 0 - не проверять.
$plainLoginTimeoutSec = [int](Get-Setting $cfg 'PlainLoginTimeoutSec' 180)
if ($plainLoginTimeoutSec -lt 0) { $plainLoginTimeoutSec = 0 }
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
$viewOnly = ($BaseState -or $ManualLocks -or $CloseBase -or $OpenBase -or $CompareExtensions -or $CompareProcessings -or $ProdPreCheck -or $ComCheck -or $GitExport -or $GitImport -or $GitProd -or $GitTypical -or $Delivery)
if ($viewOnly) {
    # Показать состояние или сравнить - не запуск обновления: своей папки запуска нет (в истории обновлений его не видно),
    # журнал - в deploy\state\run.log, каждый раз заново.
    $viewName = 'state'
    if ($ManualLocks) { $viewName = 'locks' }
    # ** Хлебников С.Ю. 20261120 Закрыть и открыть базу: журнал - deploy\close\run.log, там же файл закрытия и history.log.
    if ($CloseBase -or $OpenBase) { $viewName = 'close' }
    if ($CompareExtensions) { $viewName = 'compare-ext' } elseif ($CompareProcessings) { $viewName = 'compare-epf' } elseif ($ProdPreCheck) { $viewName = 'precheck' } elseif ($ComCheck) { $viewName = 'comcheck' } elseif ($GitExport -or $GitImport -or $GitProd -or $GitTypical) { $viewName = 'git' } elseif ($Delivery) { $viewName = 'delivery' }
    $script:RunDir = Join-Path $deployRoot $viewName
    New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
    $script:RunLogPath = Join-Path $script:RunDir 'run.log'
    [System.IO.File]::WriteAllText($script:RunLogPath, '', $Utf8Bom)
}
else {
    $script:RunDir = Join-Path $deployRoot $runId
    New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
    $script:RunLogPath = Join-Path $script:RunDir 'run.log'
    Set-StatRun $runId
}
$runsRoot = Resolve-RootPath ([string](Get-Setting $cfg 'RunsDir' 'runs'))

if (-not $viewOnly) {
    Write-Host ''
    Write-Host ("Обновление рабочей базы {0} из {1}, запуск {2}" -f $script:ProdBase, $script:TempBase, $runId) -ForegroundColor Cyan
    Write-Host ("Папка запуска: {0}" -f $script:RunDir)
    Write-RunLog ("Запуск {0}: {1} -> {2}" -f $runId, $script:TempBase, $script:ProdBase)
}

#endregion

#region Выгрузки, сравнение, история обновлений (функции)

function Get-JsonValue {
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-SelfCheckEvidence {
    # Что проверил прогон, у которого нет снимка temp (рабочая не была настроена или прогон старый): база и хеш-суммы
    # расширений из сведений самопроверки «после» (selfcheck-after\tryN\info.txt, последняя целая попытка) - тот же
    # вид, что checkedState (#7). Обработок в этих сведениях нет: их совпадение не устанавливается.
    param([string]$Dir)
    $tries = @(Get-ChildItem -LiteralPath (Join-Path $Dir 'selfcheck-after') -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^try\d+$' } | Sort-Object { [int]$_.Name.Substring(3) } -Descending)
    foreach ($try in $tries) {
        $info = Join-Path $try.FullName 'info.txt'
        if (-not (Test-Path -LiteralPath $info)) { continue }
        $lines = @([System.IO.File]::ReadAllLines($info, [System.Text.Encoding]::UTF8) | ForEach-Object { $_.TrimStart([char]0xFEFF) })
        # Без fingerprint= сведения записаны не целиком.
        if (@($lines | Where-Object { $_.StartsWith('fingerprint=') }).Count -eq 0) { continue }
        $extensions = [ordered]@{}
        $base = ''
        foreach ($line in $lines) {
            if ($line.StartsWith('base=')) { $base = $line.Substring(5).Trim() }
            if (-not $line.StartsWith('ext=')) { continue }
            $parts = $line.Substring(4).Split('|')
            if ($parts.Count -ge 4 -and $parts[0].Trim()) { $extensions[$parts[0].Trim()] = [pscustomobject]@{ version = $parts[1]; hash = $parts[3].Trim() } }
        }
        return [pscustomobject]@{ ok = $true; base = $base; extensions = [pscustomobject]$extensions; processings = $null; fromSelfCheck = $true }
    }
    return $null
}

function Update-Mirror {
    # Выгрузка расширения базы в файлы, в постоянную папку зеркала. Если выгрузка там уже есть - только
    # изменения (-update), не получилось - заново целиком.
    param([string]$BaseName, [string]$Extension)
    return (Update-DumpDir -BaseName $BaseName -Extension $Extension -Dir (Join-Path (Join-Path $mirrorRoot $BaseName) $Extension))
}

function Update-DumpDir {
    # Выгрузка расширения базы в файлы в папку Dir: есть прежняя - только изменения (-update), иначе целиком.
    param([string]$BaseName, [string]$Extension, [string]$Dir)
    $dir = $Dir
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
        # .PSObject.BaseObject, а не .BaseObject: у хеш-таблицы точка ищет ключ, и под StrictMode это ошибка.
        if ($result -is [System.Management.Automation.PSObject]) { $result = $result.PSObject.BaseObject }
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

function New-V8Connector {
    # V83.COMConnector. В тестах без 1С (переменная CI_FAKE_COM - файл сценария) - подставной из test\fakecom.ps1.
    if ($script:FakeComScript) { return New-FakeComConnector $env:CI_FAKE_COM }
    return New-Object -ComObject V83.COMConnector
}

function Get-ComConnectionLine {
    param([string]$BaseName, [string]$User, [string]$Password)
    $line = 'Srvr="{0}";Ref="{1}";' -f $script:Server, $BaseName
    if ($User) { $line += 'Usr="{0}";' -f $User.Replace('"', '""') }
    if ($Password) { $line += 'Pwd="{0}";' -f $Password.Replace('"', '""') }
    # Код разрешения: в базу, заблокированную самим deploy (или с тем же кодом), внешнее соединение тоже входит.
    if ($script:UnlockCode) { $line += 'UC="{0}";' -f $script:UnlockCode.Replace('"', '""') }
    return $line
}

function Get-ExtensionStates {
    # Расширения базы через внешнее соединение (COM): имя, версия, хеш-сумма. Только чтение, конфигуратор
    # не нужен: работает и при пользователях в базе. Соединение идёт в фоне со строкой хода и таймаутом
    # ComTimeoutSec: первое внешнее соединение к большой базе бывает долгим. Не получилось - Ok = $false.
    param([string]$BaseName, [string]$User, [string]$Password)
    $reader = {
        # FakeScript и FakeFile - подставной COM тестов (см. New-V8Connector): в фоновом потоке функций скрипта нет.
        param([string]$Line, [string]$FakeScript, [string]$FakeFile)
        $items = @{}
        if ($FakeScript) { . $FakeScript; $connector = New-FakeComConnector $FakeFile }
        else { $connector = New-Object -ComObject V83.COMConnector }
        # Член объекта 1С. Настоящий COM - поздним связыванием (IDispatch) напрямую: PowerShell видит у объектов 1С
        # не всё - РасширенияКонфигурации у соединения приходило пустым, хотя Метаданные и запросы работали.
        # Arguments не $null - вызов метода (без параметров - @()). Параметры - без обёрток PowerShell: в массиве
        # они сами не снимаются, и 1С получила бы не свой объект. Запятая - чтобы коллекция 1С не развернулась
        # в элементы по дороге. Подставной COM тестов - обычные объекты PowerShell.
        $member = {
            param($Object, [string]$Name, [object[]]$Arguments = $null)
            if ($null -eq $Object) { throw ("нет объекта, у которого брать «{0}»" -f $Name) }
            if ([Runtime.InteropServices.Marshal]::IsComObject($Object)) {
                $flags = [System.Reflection.BindingFlags]::GetProperty
                $raw = $null
                if ($null -ne $Arguments) {
                    $flags = [System.Reflection.BindingFlags]::InvokeMethod
                    $raw = New-Object 'object[]' $Arguments.Count
                    for ($k = 0; $k -lt $Arguments.Count; $k++) { if ($null -ne $Arguments[$k]) { $raw[$k] = $Arguments[$k].PSObject.BaseObject } }
                }
                # Тип System.__ComObject - по имени: он внутренний, а позднее связывание идёт через него.
                $comType = [type]::GetType('System.__ComObject')
                if ($null -eq $comType) { $comType = $Object.GetType() }
                try { return , ($comType.InvokeMember($Name, $flags, $null, $Object, $raw)) }
                catch {
                    $memberError = $_.Exception
                    while ($null -ne $memberError.InnerException) { $memberError = $memberError.InnerException }
                    throw ("{0}: {1}" -f $Name, [string]$memberError.Message)
                }
            }
            if ($null -ne $Arguments) { return , ($Object.$Name.Invoke($Arguments)) }
            return , ($Object.$Name)
        }
        # Ошибка соединения - её текстом (блокировка сеансов, пароль), а не «null-valued expression» дальше.
        try { $connection = $connector.Connect($Line) }
        catch {
            $connectError = $_.Exception
            while ($null -ne $connectError.InnerException) { $connectError = $connectError.InnerException }
            throw ([string]$connectError.Message)
        }
        try {
            # Расширения из базы данных; не вышло (источник не виден через COM) - Получить() без параметров.
            # Каждый шаг проверяется: «пусто» говорит, на каком вызове, а не «null-valued expression».
            if ($null -eq $connection) { throw 'внешнее соединение не вернуло объект соединения' }
            $manager = $null
            $managerError = ''
            foreach ($managerName in @('ConfigurationExtensions', 'РасширенияКонфигурации')) {
                try { $manager = & $member $connection $managerName }
                catch { $manager = $null; $managerError = [string]$_.Exception.Message }
                if ($null -ne $manager) { break }
            }
            if ($null -eq $manager) {
                if (-not $managerError) { $managerError = 'свойство пустое' }
                throw ('РасширенияКонфигурации недоступны через внешнее соединение: {0} (диагностика - .\deploy.ps1 -ComCheck)' -f $managerError)
            }
            $list = $null
            $source = $null
            try { $source = & $member (& $member $connection 'ConfigurationExtensionsSource') 'Database' } catch { $source = $null }
            if ($null -ne $source) { try { $list = & $member $manager 'Get' @((& $member $connection 'NewObject' @('Structure')), $source) } catch { $list = $null } }
            if ($null -eq $list) { $list = & $member $manager 'Get' @() }
            if ($null -eq $list) { throw 'РасширенияКонфигурации.Получить() вернул пусто' }
            $count = [int](& $member $list 'Count' @())
            for ($i = 0; $i -lt $count; $i++) {
                $extension = & $member $list 'Get' @($i)
                $hash = ''
                try { $hash = [string](& $member $connection 'Base64String' @((& $member $extension 'HashSum'))) } catch { $hash = '' }
                $items[[string](& $member $extension 'Name')] = [pscustomobject]@{ Version = [string](& $member $extension 'Version'); Hash = $hash }
            }
        }
        finally {
            foreach ($comObject in @($connection, $connector)) {
                if ($null -ne $comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
            }
        }
        return $items
    }
    $call = Invoke-UiBackground -Script $reader -Arguments @((Get-ComConnectionLine $BaseName $User $Password), $script:FakeComScript, [string]$env:CI_FAKE_COM) `
        -Title ("Прочитать расширения {0}" -f $BaseName) -TimeoutSec $comTimeoutSec
    $message = $call.Error
    if ($Password -and $message) { $message = $message.Replace($Password, '***') }
    if (-not $call.Ok -or -not ($call.Result -is [hashtable])) {
        if (-not $message) { $message = 'внешнее соединение ничего не вернуло' }
        if (Test-SessionLockError $message) { $message = 'Начало сеанса с информационной базой запрещено' }
        Write-RunLog ("Расширения {0} через COM не получены: {1}" -f $BaseName, $message)
        return [pscustomobject]@{ Ok = $false; Error = $message; Items = @{} }
    }
    Write-RunLog ("Расширения {0} через COM: {1}" -f $BaseName, (@($call.Result.Keys | Sort-Object) -join ', '))
    return [pscustomobject]@{ Ok = $true; Error = ''; Items = $call.Result }
}

function Test-SessionLockError {
    # Ошибка входа - это блокировка начала сеансов с другим кодом разрешения (не тем, что в UnlockCode)?
    param([string]$Message)
    if (-not $Message) { return $false }
    return ($Message -match 'Начало сеанса с информационной базой запрещено|начало сеансов.*запрещено')
}

function Test-AuthError {
    # Ошибка входа - пользователь или пароль не подошли?
    param([string]$Message)
    if (-not $Message) { return $false }
    return ($Message -match 'не идентифицирован|Неправильное имя пользователя или пароль|не прошел аутентификацию|не прошёл аутентификацию')
}

function Assert-ProdOpen {
    # В рабочую не войти - дальше не идём: ни сравнить, ни обновить, а следующие соединения только ждут
    # таймаута. Причину - понятным текстом и что поправить.
    param($States)
    if ($States.Ok) { return }
    $text = ([string]$States.Error -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' '
    if (Test-SessionLockError $States.Error) {
        Write-Line ("  {0}: стоит блокировка начала сеансов, и код разрешения у неё не тот, что в UnlockCode: {1}" -f $script:ProdBase, $text) 'Red'
        Write-Line '  Если блокировку ставил ты - впиши её код в Настройки, Базы, UnlockCode и запусти снова. Или сними её в консоли кластера.' 'Red'
    }
    elseif (Test-AuthError $States.Error) {
        Write-Line ("  {0}: вход не прошёл - {1}" -f $script:ProdBase, $text) 'Red'
        Write-Line ("  Админ рабочей - Настройки, Пользователи и пароли: ProdAdminUser и ProdAdminPassFile (сейчас пользователь «{0}»). Пустые - берутся AdminUser и пароль temp." -f $script:ProdUser) 'Red'
    }
    else { return }
    Write-RunLog ("В рабочую не войти: {0}" -f $text)
    # Не авария, а состояние рабочей: выходим без «Остановлено», блокировок deploy к этому моменту не ставил.
    exit 2
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
            # Прерванное (после разбора при старте deploy - 'interrupted') тоже в списке: откат вернёт то, что успело.
            if ($null -eq $record -or @('updated', 'interrupted') -notcontains [string](Get-JsonValue $record 'outcome' '')) { continue }
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
    $names = @{ '1' = 'все из temp'; '2' = 'выбранные из temp'; 'epf' = 'только внешние обработки'; 'asis' = 'как есть'; 'rollback' = 'откат'; 'prepared' = 'подготовленным' }
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
    if ([string](Get-JsonValue $Record 'outcome' '') -eq 'interrupted') { $flag += ', ПРЕРВАНО' }
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
        $reasonText = [string](Get-JsonValue $Record 'riskReason' '')
        if (-not $reasonText) { $reasonText = 'не записана' }
        $lines.Add(("Причина выпуска: {0}" -f $reasonText))
    }
    $light = @(Get-JsonValue $Record 'light' @())
    $lines.Add('Лёгкий прогон после обновления:')
    if ($light.Count -eq 0) { $lines.Add('  нет данных') }
    foreach ($item in $light) { $lines.Add(("  [{0}] {1}: {2}" -f $item.status, $item.name, $item.text)) }
    $plainRecord = Get-JsonValue $Record 'plainLogin' $null
    if ($null -ne $plainRecord) { $lines.Add(("Вход без кода разрешения после снятия блокировок: [{0}] {1}" -f (Get-JsonValue $plainRecord 'status' ''), (Get-JsonValue $plainRecord 'text' ''))) }
    $downtimeRecord = Get-JsonValue $Record 'downtimeSec' $null
    if ($null -ne $downtimeRecord) {
        $lines.Add(("Простой базы: {0} мин {1:00} с (вход закрыт {2}, открыт {3})" -f [int][Math]::Floor([int]$downtimeRecord / 60), ([int]$downtimeRecord % 60),
                (Get-JsonValue $Record 'closedAt' ''), (Get-JsonValue $Record 'openedAt' '')))
    }
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
        $connector = New-V8Connector
        $connection = $connector.Connect((Get-ComConnectionLine $BaseName $User $Password))
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
    # All (для git, раздел 5.23) - все элементы с именем объекта, и помеченные на удаление, каждый файл - в папке
    # своей ссылки; ещё вид, пометка удаления, публикация, безопасный режим, ссылка, назначение; элемент без файла -
    # с File = ''.
    # Внешнее соединение - в фоне, со строкой хода и таймаутом (ComTimeoutSec, втрое: файлов бывает много):
    # раньше синхронный вызов вешал экран, и до кнопки остановки скрипт не доходил.
    param([string]$BaseName, [string]$User, [string]$Password, [string]$Dir, [switch]$All)
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $reader = {
        param([string]$Line, [string]$Dir, [string]$FakeScript, [string]$FakeFile, [bool]$All)
        if ($FakeScript) { . $FakeScript; $connector = New-FakeComConnector $FakeFile }
        else { $connector = New-Object -ComObject V83.COMConnector }
        $connection = $null
        $found = New-Object System.Collections.Generic.List[object]
        try {
            try { $connection = $connector.Connect($Line) }
            catch {
                $connectError = $_.Exception
                while ($null -ne $connectError.InnerException) { $connectError = $connectError.InnerException }
                throw ([string]$connectError.Message)
            }
            $query = $connection.NewObject('Query')
            $query.Text = 'ВЫБРАТЬ Спр.Наименование КАК Title, Спр.ИмяОбъекта КАК ObjName, Спр.Версия КАК Version, ' +
                'ПРЕДСТАВЛЕНИЕ(Спр.Вид) КАК Kind, Спр.ХранилищеОбработки КАК Storage ' +
                'ИЗ Справочник.ДополнительныеОтчетыИОбработки КАК Спр ГДЕ НЕ Спр.ПометкаУдаления'
            if ($All) {
                $query.Text = 'ВЫБРАТЬ Спр.Наименование КАК Title, Спр.ИмяОбъекта КАК ObjName, Спр.Версия КАК Version, ' +
                    'ПРЕДСТАВЛЕНИЕ(Спр.Вид) КАК Kind, Спр.ХранилищеОбработки КАК Storage, Спр.ПометкаУдаления КАК Deleted, ' +
                    'ПРЕДСТАВЛЕНИЕ(Спр.Публикация) КАК Use, Спр.БезопасныйРежим КАК SafeMode, Спр.Ссылка КАК Ref ' +
                    'ИЗ Справочник.ДополнительныеОтчетыИОбработки КАК Спр'
            }
            $selection = $query.Execute().Select()
            $sha = [System.Security.Cryptography.SHA256]::Create()
            while ($selection.Next()) {
                # Поля - по номеру (Получить(Индекс)) в порядке запроса: обращение по псевдониму через COM на
                # рабочей дало «The property 'ObjName' cannot be found».
                $title = [string]$selection.Get(0)
                $objName = [string]$selection.Get(1)
                $version = [string]$selection.Get(2)
                $kind = [string]$selection.Get(3)
                if (-not $objName) { continue }
                $extension = '.epf'
                if ($kind -match 'тч[её]т') { $extension = '.erf' }
                $file = Join-Path $Dir ($objName + $extension)
                $entry = $null
                if ($All) {
                    $refId = [string]$connection.String($selection.Get(8).UUID())
                    $entry = [pscustomobject]@{
                        ObjName = $objName; Title = $title; Version = $version; File = ''; Hash = ''; Kind = $kind
                        Deleted = [bool]$selection.Get(5); Use = [string]$selection.Get(6); SafeMode = [bool]$selection.Get(7); Ref = $refId
                        Targets = @(); TargetsError = ''
                    }
                    $found.Add($entry)
                    # Имена объектов у элементов справочника бывают одинаковые: каждый файл - в папке своей ссылки.
                    $refDir = Join-Path $Dir $refId
                    New-Item -ItemType Directory -Path $refDir -Force | Out-Null
                    $file = Join-Path $refDir ($objName + $extension)
                }
                $storage = $selection.Get(4)
                if ($null -eq $storage) { continue }
                $data = $storage.Get()
                if ($null -eq $data) { continue }
                $data.Write($file)
                if (-not (Test-Path -LiteralPath $file)) { continue }
                $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($file)))
                if ($All) { $entry.File = $file; $entry.Hash = $hash }
                else { $found.Add([pscustomobject]@{ ObjName = $objName; Title = $title; Version = $version; File = $file; Hash = $hash }) }
            }
            if ($All -and $found.Count -gt 0) {
                # Назначение (для каких объектов) - отдельным запросом: не прочиталось - остальное всё равно нужно.
                $targets = @{}
                $targetsError = ''
                try {
                    $targetQuery = $connection.NewObject('Query')
                    $targetQuery.Text = 'ВЫБРАТЬ Назн.Ссылка КАК Ref, Назн.ОбъектНазначения.ПолноеИмя КАК Target ' +
                        'ИЗ Справочник.ДополнительныеОтчетыИОбработки.Назначение КАК Назн'
                    $targetSelection = $targetQuery.Execute().Select()
                    while ($targetSelection.Next()) {
                        $refId = [string]$connection.String($targetSelection.Get(0).UUID())
                        $target = [string]$targetSelection.Get(1)
                        if (-not $target) { continue }
                        if (-not $targets.ContainsKey($refId)) { $targets[$refId] = New-Object System.Collections.Generic.List[string] }
                        if (-not $targets[$refId].Contains($target)) { $targets[$refId].Add($target) }
                    }
                }
                catch { $targetsError = [string]$_.Exception.Message }
                foreach ($entry in $found) {
                    if ($targetsError) { $entry.TargetsError = $targetsError }
                    elseif ($targets.ContainsKey($entry.Ref)) { $entry.Targets = @($targets[$entry.Ref] | Sort-Object) }
                }
            }
        }
        finally {
            foreach ($comObject in @($connection, $connector)) {
                if ($null -ne $comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
            }
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
        }
        return , @($found.ToArray())
    }
    $call = Invoke-UiBackground -Script $reader -Arguments @((Get-ComConnectionLine $BaseName $User $Password), $Dir, $script:FakeComScript, [string]$env:CI_FAKE_COM, [bool]$All) `
        -Title ("Выгрузить обработки {0}" -f $BaseName) -TimeoutSec ($comTimeoutSec * 3)
    $message = $call.Error
    if ($Password -and $message) { $message = $message.Replace($Password, '***') }
    if (-not $call.Ok) {
        if (-not $message) { $message = 'внешнее соединение ничего не вернуло' }
        Write-RunLog ("Обработки {0} через COM не выгружены: {1}" -f $BaseName, $message)
        return [pscustomobject]@{ Ok = $false; Error = $message; Items = @() }
    }
    $items = @($call.Result | Where-Object { $null -ne $_ })
    return [pscustomobject]@{ Ok = $true; Error = ''; Items = $items }
}

function Invoke-ProdClient {
    # Тонкий клиент рабочей базы с внешней обработкой; ждём файл $DoneFile не дольше $TimeoutSec.
    # StartFile - отметка «обработка открылась и поняла параметр запуска»: нет её за StartTimeoutSec - дальше не ждём
    # (вход не удался или сборка обработки этого режима не знает); в ответе Started.
    # NoUnlockCode - вход как у пользователя, без кода разрешения (/UC): проверка, что база открыта.
    param([string]$Epf, [string]$Parameter, [string]$DoneFile, [int]$TimeoutSec, [string]$Title, [string]$StartFile = '', [int]$StartTimeoutSec = 0, [switch]$NoUnlockCode)
    $argList = @('ENTERPRISE') + @(Get-ConnectionArgs -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword -NoUnlockCode:$NoUnlockCode) + @(
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
        if ($StartFile -and $StartTimeoutSec -gt 0 -and $watch.Elapsed.TotalSeconds -ge $StartTimeoutSec -and -not (Test-Path -LiteralPath $StartFile)) { break }
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
    $started = ($done -or -not $StartFile -or (Test-Path -LiteralPath $StartFile))
    return [pscustomobject]@{ Done = $done; Seconds = [int]$watch.Elapsed.TotalSeconds; Started = $started }
}

function Invoke-ProdProcessing {
    # Один сеанс «Выполнить после обновления» на рабочей базе в режиме regepf или unregepf - тот же, что у гейта
    # на temp. regepf: записать обработку в справочник «Дополнительные отчёты и обработки» (элемент с тем же
    # именем объекта обновляется, иначе добавляется новый); прежняя версия до записи ложится в old.b64 папки
    # OutDir, без неё обработка не заменяется. File - сам .epf/.erf, TextFile - уже base64 (откат из old.b64).
    # unregepf: снять обработку - по имени объекта и ссылке элемента вместе.
    param([string]$Mode, [string]$OutDir, [string]$File = '', [string]$TextFile = '', [string]$Name, [string]$Ref = '', [string]$Title)
    $null = Get-BaseInfo $deployLink $script:ProdBase $script:ProdUser $script:ProdPassword
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
            $entry.Text = ("отличается (рабочая {0}, temp {1})" -f $prodItem.Version, $item.Version)
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

#region Разница по выгрузкам в файлы (отчёт об изменениях, сравнение temp и рабочей)

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

#endregion

#region Состояние баз

function Format-LockDate {
    # Дата блокировки из кластера: пустая дата 1С (0001 или 0100 год) - «не задана».
    param($Value)
    if ($null -eq $Value) { return 'не задана' }
    try { $date = [datetime]$Value } catch { return [string]$Value }
    if ($date.Year -lt 1900) { return 'не задана' }
    return $date.ToString('dd.MM.yyyy HH:mm')
}

# ** Хлебников С.Ю. 20261120 Закрытие базы (-CloseBase/-OpenBase): что поставило закрытие - в deploy\close\closed-<база>.json
# (что стояло до него, что поставило оно само в том виде, как вернул кластер, ставило ли запрет регламентных, метка).
# Файл есть - база закрыта этим пунктом или закрытие оборвалось; -OpenBase снимает по нему только своё.
function Get-CloseFile {
    param([string]$BaseName)
    return (Join-Path (Join-Path $deployRoot 'close') ('closed-{0}.json' -f $BaseName))
}

function Read-CloseRecord {
    # Запись закрытия базы. Нет файла - $null; не читается - исключение: что стоит на базе от закрытия, неизвестно.
    param([string]$BaseName)
    $file = Get-CloseFile $BaseName
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { return ([System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json) }
    catch {
        throw ("файл закрытия {0} не читается ({1}): что поставило закрытие, неизвестно. Блокировки - «Блокировки рабочей базы» или консоль кластера, файл потом убрать руками" -f $file, $_.Exception.Message)
    }
}

function Get-OpenBaseHint {
    param([string]$BaseName)
    if ($BaseName -ieq $script:ProdBase) { return 'открыть - пункт меню гейта «Открыть рабочую базу» (deploy.ps1 -OpenBase)' }
    return 'открыть - deploy.ps1 -OpenBase -LocksBase Temp'
}

function Get-CloseRecordText {
    # Одной строкой: закрыта или закрытие оборвалось, когда и кем, до какого времени вход, запрещало ли регламентные.
    param($Record)
    $text = 'закрыта гейтом'
    if ([string](Get-JsonValue $Record 'status' '') -ne 'closed') { $text = 'закрытие гейтом не закончено' }
    $when = [string](Get-JsonValue $Record 'closedAt' '')
    if (-not $when) { $when = [string](Get-JsonValue $Record 'startedAt' '') }
    if ($when) { $text += (' ' + $when) }
    $by = [string](Get-JsonValue $Record 'by' '')
    if ($by) { $text += (', пользователь Windows ' + $by) }
    $until = [string](Get-JsonValue $Record 'until' '')
    if ($until) { $text += (', вход закрыт до ' + $until) }
    if ([bool](Get-JsonValue $Record 'jobsSet' $false)) { $text += ', регламентные задания запрещены' }
    return $text
}
# ** Хлебников С.Ю. 20261120 конец

function Show-BaseState {
    # Блокировки базы и сеансы - только чтение, ничего не меняется.
    param($Link, [string]$BaseName, [string]$User, [string]$Password)
    Write-Host ''
    Write-Line ("{0}" -f $BaseName) 'Cyan'
    # ** Хлебников С.Ю. 20261120 Закрыта ли база пунктом «Закрыть» (файл закрытия).
    try {
        $closeRecord = Read-CloseRecord $BaseName
        if ($null -ne $closeRecord) { Write-Line ('  {0}; {1}' -f (Get-CloseRecordText $closeRecord), (Get-OpenBaseHint $BaseName)) 'Yellow' }
    }
    catch { Write-Line ('  ' + $_.Exception.Message) 'Yellow' }
    try { $info = (Get-BaseInfo -Link $Link -BaseName $BaseName -User $User -Password $Password).InfoBase }
    catch { Write-Line ("  свойства базы в кластере не прочитал: {0}" -f $_.Exception.Message) 'Yellow'; $info = $null }
    if ($null -ne $info) {
        if ([bool]$info.SessionsDenied) {
            $now = Get-Date
            $fromText = Format-LockDate $info.DeniedFrom
            $toText = Format-LockDate $info.DeniedTo
            $active = $true
            try { if ($fromText -ne 'не задана' -and $now -lt [datetime]$info.DeniedFrom) { $active = $false } } catch { }
            try { if ($toText -ne 'не задана' -and $now -gt [datetime]$info.DeniedTo) { $active = $false } } catch { }
            $activeText = 'действует сейчас'
            if (-not $active) { $activeText = 'включена, но сейчас вне её срока' }
            Write-Line ("  Блокировка начала сеансов: ВКЛЮЧЕНА, {0}" -f $activeText) 'Red'
            Write-Line ("    с {0} по {1}" -f $fromText, $toText)
            if ([string]$info.DeniedMessage) { Write-Line ("    сообщение: {0}" -f ([string]$info.DeniedMessage).Trim()) }
            $code = [string]$info.PermissionCode
            if (-not $code) { Write-Line '    код разрешения: не задан (войти нельзя никому)' 'Yellow' }
            elseif ($code -eq $script:UnlockCode) { Write-Line '    код разрешения: тот же, что UnlockCode - гейт и deploy в неё войдут' 'Green' }
            else { Write-Line '    код разрешения: другой, не UnlockCode - гейт и deploy в неё не войдут' 'Yellow' }
        }
        else { Write-Line '  Блокировка начала сеансов: нет' 'Green' }
        if ([bool]$info.ScheduledJobsDenied) { Write-Line '  Блокировка регламентных заданий: ВКЛЮЧЕНА' 'Red' }
        else { Write-Line '  Блокировка регламентных заданий: нет' 'Green' }
    }
    $sessions = @(Get-BaseSessions $Link $BaseName)
    $errors = @($sessions | Where-Object { $_.IsError })
    foreach ($entry in $errors) { Write-Line ("  сеансы не прочитал: {0}" -f $entry.Text) 'Yellow' }
    $live = @($sessions | Where-Object { -not $_.IsError })
    if ($errors.Count -eq 0) {
        $designers = @($live | Where-Object { $_.IsDesigner })
        Write-Line ("  Сеансов: {0}, из них конфигураторов: {1}" -f $live.Count, $designers.Count)
        foreach ($entry in $designers) { Write-Line ('    ' + $entry.Text) 'Yellow' }
    }
}

if ($BaseState) {
    Write-Line ("СОСТОЯНИЕ БАЗ на {0}" -f (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')) 'Cyan'
    $stateLink = Connect-ClusterAgent
    Show-BaseState -Link $stateLink -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword
    Show-BaseState -Link $stateLink -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
    exit 0
}

function Get-NextClockTime {
    # Ближайшие часы:минуты не раньше чем через 10 минут: «до 02:00» днём - это ближайшая ночь.
    param([int]$Hour)
    $at = (Get-Date).Date.AddHours($Hour)
    if ($at -le (Get-Date).AddMinutes(10)) { $at = $at.AddDays(1) }
    return $at
}

function Invoke-ManualLocks {
    # Блокировки базы руками: показать, что стоит, и по выбору человека поставить или снять блокировку начала сеансов
    # и блокировку регламентных заданий. Сеансы не завершаются. Каждое изменение - запись свойств базы в кластере и
    # проверка повторным чтением; в журнале deploy\locks\run.log - кто что поменял.
    param([string]$Which)
    $baseName = $script:TempBase; $user = $script:TempUser; $password = $script:TempPassword
    if ($Which -eq 'Prod') { $baseName = $script:ProdBase; $user = $script:ProdUser; $password = $script:ProdPassword }
    $isProd = ($Which -eq 'Prod')
    if (-not (Test-UiCanAsk)) { throw 'блокировки руками - только с человеком у экрана: запусти из меню гейта' }
    # Пока идёт обновление рабочей (deploy.lock занят), блокировки руками не трогаются: обновление ведёт их само.
    $guard = $null
    try { $guard = [System.IO.File]::Open((Join-Path $deployRoot 'deploy.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'идёт обновление рабочей (deploy.lock занят другим запуском): блокировки руками не трогаю, дождись его конца' }
    try {
        Write-Line ("БЛОКИРОВКИ {0}" -f $baseName) 'Cyan'
        Write-RunLog ("Блокировки руками: {0}, пользователь Windows {1}" -f $baseName, [Environment]::UserName)
        while ($true) {
            $link = Connect-ClusterAgent
            Show-BaseState -Link $link -BaseName $baseName -User $user -Password $password
            $target = Get-BaseInfo -Link $link -BaseName $baseName -User $user -Password $password
            $info = Read-BaseInfoAgain $target $baseName
            $sessionsOn = [bool]$info.SessionsDenied
            $jobsOn = [bool]$info.ScheduledJobsDenied
            $keys = @('1', '2', '0')
            $labels = @('Поставить блокировку начала сеансов', 'Поставить блокировку регламентных заданий', 'Готово, выйти')
            if ($sessionsOn) { $labels[0] = 'Снять блокировку начала сеансов' }
            if ($jobsOn) { $labels[1] = 'Снять блокировку регламентных заданий' }
            # ** Хлебников С.Ю. 20261120 База закрыта пунктом «Закрыть»: открывать лучше им - снимется и его запрет регламентных.
            $lockNotes = New-Object System.Collections.Generic.List[string]
            $lockNotes.Add('Сеансы, которые уже открыты, не завершаются.')
            try {
                $closeRecord = Read-CloseRecord $baseName
                if ($null -ne $closeRecord) { $lockNotes.Add(('База {0}. Открывать лучше там же: снимется и запрет регламентных, поставленный закрытием; {1}.' -f (Get-CloseRecordText $closeRecord), (Get-OpenBaseHint $baseName))) }
            }
            catch { $lockNotes.Add($_.Exception.Message) }
            $answer = Read-UiChoice -Header ("Блокировки {0}: что сделать?" -f $baseName) -Keys $keys -Labels $labels -CancelKey '0' -DefaultKey '0' `
                -Notes $lockNotes.ToArray()
            if ($answer -ne '1' -and $answer -ne '2') { break }
            $done = ''
            if ($answer -eq '1' -and -not $sessionsOn) {
                $until1 = (Get-Date).AddHours(1); $until3 = (Get-Date).AddHours(3)
                $night = Get-NextClockTime 2; $morning = Get-NextClockTime 8
                $period = Read-UiChoice -Header ("Блокировка начала сеансов {0}: до какого времени?" -f $baseName) -Keys @('1', '2', '3', '4', '0') -Labels @(
                    ('на час, до {0}' -f $until1.ToString('HH:mm')), ('на 3 часа, до {0}' -f $until3.ToString('HH:mm')),
                    ('до {0}' -f $night.ToString('dd.MM HH:mm')), ('до {0}' -f $morning.ToString('dd.MM HH:mm')), 'Не ставить') -CancelKey '0' -DefaultKey '0'
                $until = $null
                switch ($period) { '1' { $until = $until1 } '2' { $until = $until3 } '3' { $until = $night } '4' { $until = $morning } }
                if ($null -eq $until) { continue }
                $code = $script:UnlockCode
                if ([string]::IsNullOrEmpty($code)) { $code = '123'; Write-Line '  UnlockCode пустой: код разрешения входа - 123 (как у обновления рабочей)' 'Yellow' }
                if ($isProd -and -not (Confirm-Ui -Question ("Закрыть вход в {0} до {1}? Новые сеансы не откроются (кроме входа с кодом разрешения), открытые останутся." -f $baseName, $until.ToString('dd.MM HH:mm')) -Yes 'Да, закрыть вход' -No 'Нет' -DefaultNo)) { continue }
                $from = (Get-Date).AddMinutes(-30)
                $info.DeniedFrom = $from.AddTicks(-($from.Ticks % [timespan]::TicksPerSecond))
                $info.DeniedTo = $until.AddTicks(-($until.Ticks % [timespan]::TicksPerSecond))
                $info.PermissionCode = $code
                $info.DeniedMessage = ('Технические работы, вход в программу закрыт до {0}' -f $until.ToString('dd.MM HH:mm'))
                $info.SessionsDenied = $true
                $null = $target.Process.UpdateInfoBase($info)
                $check = Read-BaseInfoAgain $target $baseName
                if (-not [bool]$check.SessionsDenied -or [string]$check.PermissionCode -cne $code) { throw 'запись блокировки начала сеансов не подтвердилась: проверь в консоли кластера' }
                $done = ('поставил блокировку начала сеансов до {0}' -f $until.ToString('dd.MM HH:mm'))
            }
            elseif ($answer -eq '1') {
                if ([string]$info.PermissionCode -cne [string]$script:UnlockCode) {
                    Write-Line '  код разрешения у этой блокировки не тот, что UnlockCode: её ставил не гейт (консоль кластера, админ)' 'Yellow'
                }
                if ($isProd -and -not (Confirm-Ui -Question ("Открыть вход в {0}? Блокировка начала сеансов будет снята." -f $baseName) -Yes 'Да, открыть вход' -No 'Нет' -DefaultNo)) { continue }
                $info.SessionsDenied = $false
                $null = $target.Process.UpdateInfoBase($info)
                if ([bool](Read-BaseInfoAgain $target $baseName).SessionsDenied) { throw 'снятие блокировки начала сеансов не подтвердилось: проверь в консоли кластера' }
                $done = 'снял блокировку начала сеансов'
            }
            elseif (-not $jobsOn) {
                if ($isProd -and -not (Confirm-Ui -Question ("Запретить регламентные задания {0}? Обмены и прочие задания не запустятся, пока запрет не снимут." -f $baseName) -Yes 'Да, запретить' -No 'Нет' -DefaultNo)) { continue }
                $info.ScheduledJobsDenied = $true
                $null = $target.Process.UpdateInfoBase($info)
                if (-not [bool](Read-BaseInfoAgain $target $baseName).ScheduledJobsDenied) { throw 'запрет регламентных заданий не подтвердился: проверь в консоли кластера' }
                $done = 'поставил блокировку регламентных заданий'
            }
            else {
                if ($isProd -and -not (Confirm-Ui -Question ("Снять запрет регламентных заданий {0}? Задания начнут запускаться по расписанию." -f $baseName) -Yes 'Да, снять' -No 'Нет' -DefaultNo)) { continue }
                $info.ScheduledJobsDenied = $false
                $null = $target.Process.UpdateInfoBase($info)
                if ([bool](Read-BaseInfoAgain $target $baseName).ScheduledJobsDenied) { throw 'снятие запрета регламентных заданий не подтвердилось: проверь в консоли кластера' }
                $done = 'снял блокировку регламентных заданий'
            }
            Write-Line ("  {0}: {1}" -f $baseName, $done) 'Green'
            Write-RunLog ("{0}: {1}" -f $baseName, $done)
            Write-Host ''
        }
    }
    finally { if ($null -ne $guard) { $guard.Dispose() } }
}

if ($ManualLocks) {
    Invoke-ManualLocks $LocksBase
    exit 0
}

# ** Хлебников С.Ю. 20261120 Закрыть базу для пользователей и открыть её (-CloseBase/-OpenBase). Закрытие: предупреждение
# (блокировка начала сеансов с времени через CloseWarnMinutes - клиенты БСП показывают предупреждение и в это время
# закрываются сами), в это время запрет регламентных заданий и завершение оставшихся сеансов, конфигуратор - по
# вопросу. Блокировки остаются до открытия - ради них пункт и нужен; что поставлено - в файле закрытия. Не дошло до
# завершения сеансов (отмена, ошибка) - всё, что успело поставить, снимается сразу. Открытие снимает только своё.
function Format-CloseMinutes {
    param([double]$Minutes)
    if ($Minutes -eq [Math]::Floor($Minutes)) { return ([string][int]$Minutes) }
    return $Minutes.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Save-CloseRecord {
    # Файл закрытия - заменой (обрыв посреди записи не портит прежний); своих блокировок не осталось - файл убирается.
    param([string]$BaseName, $State, $Info)
    $file = Get-CloseFile $BaseName
    if ($null -eq $State -or (-not $State.Expected.Count -and -not $State.JobsSet)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        return
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
    $record = [ordered]@{}
    foreach ($key in @($Info.Keys)) { $record[$key] = $Info[$key] }
    $record['marker'] = $State.Marker
    $record['jobsSet'] = [bool]$State.JobsSet
    $record['before'] = ConvertTo-LockJson $State.Before
    $record['expected'] = @(foreach ($one in $State.Expected) { ConvertTo-LockJson $one })
    $temp = $file + '.tmp'
    [System.IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $record -Depth 6), $Utf8Bom)
    # [NullString]::Value - без резервной копии: $null PowerShell передал бы пустой строкой.
    if (Test-Path -LiteralPath $file) { [System.IO.File]::Replace($temp, $file, [NullString]::Value) }
    else { [System.IO.File]::Move($temp, $file) }
}

function Get-CloseLockState {
    # Блокировки закрытия из его файла - в том виде, в каком их ждут Test-GateSessionLock и Restore-GateLocks.
    param($Record)
    $state = New-GateLockState
    $state.Marker = [string](Get-JsonValue $Record 'marker' '')
    $state.JobsSet = [bool](Get-JsonValue $Record 'jobsSet' $false)
    $state.Before = ConvertFrom-LockJson (Get-JsonValue $Record 'before' $null)
    $state.Expected = @(foreach ($one in @(Get-JsonValue $Record 'expected' @())) { ConvertFrom-LockJson $one })
    return $state
}

function Write-CloseHistory {
    # Закрытия и открытия баз - в deploy\close\history.log, не стирается (run.log папки пишется каждый раз заново).
    param([string]$Text)
    $file = Join-Path (Join-Path $deployRoot 'close') 'history.log'
    try { [System.IO.File]::AppendAllText($file, ("{0} {1}`r`n" -f (Get-Date -Format 'dd.MM.yyyy HH:mm:ss'), (Get-MaskedLine $Text)), $Utf8Bom) }
    catch { Write-RunLog ('history.log не записался: ' + $_.Exception.Message) }
}

function Wait-CloseWarning {
    # После предупреждения: ждать начала блокировки и ещё минуту (клиенты БСП проверяют её раз в минуту и закрываются
    # сами), все вышли раньше - сразу. Ответ: '1' - не ждать, '2' - отмена, 'empty' - вышли все, 'time' - время вышло.
    param([datetime]$LockAt)
    $graceSec = [Math]::Min(70, [Math]::Max(3, [int]($closeWarnMinutes * 60)))
    $script:CloseLockAt = $LockAt
    $script:CloseDeadline = $LockAt.AddSeconds($graceSec)
    $script:CloseLink = Connect-ClusterAgent
    $script:CloseShown = ''
    $header = "Пользователи {0} предупреждены: в {1} вход закрывается, в {2} оставшиеся сеансы завершу сам; все выйдут раньше - закрою сразу. Или:" -f `
        $script:CloseBaseName, $LockAt.ToString('HH:mm'), $script:CloseDeadline.ToString('HH:mm:ss')
    return (Read-UiChoice -Header $header -Dock -Keys @('1', '2') -CancelKey '2' -Labels @(
            'Не ждать: закрыть сейчас и завершить сеансы',
            'Отмена: снять предупреждение, базу не закрывать') -Poll {
            $list = @(Get-BaseSessions $script:CloseLink $script:CloseBaseName)
            $late = ((Get-Date) -ge $script:CloseDeadline)
            if (@($list | Where-Object { $_.IsError }).Count -gt 0) { if ($late) { return 'time' }; return '' }
            $users = @($list | Where-Object { -not $_.IsDesigner })
            if ($users.Count -eq 0) { return 'empty' }
            if ($late) { return 'time' }
            $minutesLeft = [int][Math]::Ceiling(($script:CloseLockAt - (Get-Date)).TotalMinutes)
            $shown = "вход закрыт, сеансов осталось: {0}" -f $users.Count
            if ($minutesLeft -gt 0) { $shown = "до закрытия {0} мин, сеансов: {1}" -f $minutesLeft, $users.Count }
            if ($shown -ne $script:CloseShown) { $script:CloseShown = $shown; Write-Host ('  ' + $shown) -ForegroundColor DarkGray }
            return ''
        })
}

function Get-UserSessions {
    # Сеансы базы, кроме конфигуратора. Failed - список не прочитан: пустой Users тогда не значит «никого нет»
    # (ревью #44). Что не прочиталось - в журнал и на экран.
    param($Link, [string]$BaseName)
    $all = @(Get-BaseSessions $Link $BaseName)
    $errors = @($all | Where-Object { $_.IsError })
    foreach ($entry in $errors) { Write-Line ('  сеансы не прочитал: ' + $entry.Text) 'Yellow' }
    return [pscustomobject]@{ Users = @($all | Where-Object { -not $_.IsError -and -not $_.IsDesigner }); Failed = ($errors.Count -gt 0) }
}

function Invoke-CloseBase {
    param([string]$Which)
    $baseName = $script:TempBase; $user = $script:TempUser; $password = $script:TempPassword
    if ($Which -eq 'Prod') { $baseName = $script:ProdBase; $user = $script:ProdUser; $password = $script:ProdPassword }
    $isProd = ($Which -eq 'Prod')
    # Для проверок внутри ожидания (Poll) и повторного чтения свойств: блок кода видит только переменные скрипта.
    $script:CloseBaseName = $baseName
    if (-not (Test-UiCanAsk)) { throw 'закрыть базу - только с человеком у экрана: запусти из меню гейта' }
    # Пока идёт обновление рабочей или блокировки руками (deploy.lock занят), базу не закрываю: блокировки ведут они.
    $guard = $null
    try { $guard = [System.IO.File]::Open((Join-Path $deployRoot 'deploy.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'deploy.lock занят другим запуском (обновление рабочей, блокировки руками): базу не закрываю, дождись его конца' }
    $state = $null
    $info = [ordered]@{}
    # Дошли до завершения сеансов - блокировки остаются, что бы ни случилось дальше; до того - снимаются в finally.
    $keep = $false
    try {
        Write-Line ("ЗАКРЫТЬ {0} ДЛЯ ПОЛЬЗОВАТЕЛЕЙ" -f $baseName) 'Cyan'
        Write-RunLog ("Закрыть базу: {0}, пользователь Windows {1}" -f $baseName, [Environment]::UserName)
        $record = Read-CloseRecord $baseName
        if ($null -ne $record) {
            Write-Line ("  {0} уже {1}; {2}" -f $baseName, (Get-CloseRecordText $record), (Get-OpenBaseHint $baseName)) 'Yellow'
            return
        }
        $link = Connect-ClusterAgent
        Show-BaseState -Link $link -BaseName $baseName -User $user -Password $password
        $target = Get-BaseInfo -Link $link -BaseName $baseName -User $user -Password $password
        $current = Read-BaseInfoAgain $target $baseName
        if ([bool]$current.SessionsDenied) {
            Write-Line ("  на {0} уже стоит блокировка начала сеансов: закрываю только базу без неё. Сними её («Блокировки рабочей базы» или консоль кластера) и закрой снова." -f $baseName) 'Yellow'
            return
        }

        $keys = New-Object System.Collections.Generic.List[string]
        $labels = New-Object System.Collections.Generic.List[string]
        if ($closeWarnMinutes -gt 0) { $keys.Add('1'); $labels.Add(("Предупредить пользователей и закрыть через {0} мин" -f (Format-CloseMinutes $closeWarnMinutes))) }
        $keys.Add('2'); $labels.Add('Закрыть сейчас, без предупреждения')
        $keys.Add('0'); $labels.Add('Отмена')
        $how = Read-UiChoice -Header ("Закрыть {0} для пользователей: когда?" -f $baseName) -Keys $keys.ToArray() -Labels $labels.ToArray() -CancelKey '0' -DefaultKey $keys[0] -Notes @(
            'В назначенное время вход закрывается (кроме входа с кодом разрешения), регламентные задания запрещаются, оставшиеся сеансы завершаются; конфигуратор - по вопросу.',
            ('Блокировки остаются, пока базу не откроют: {0}.' -f (Get-OpenBaseHint $baseName)))
        if ($how -ne '1' -and $how -ne '2') { Write-Line '  отмена: ничего не менял'; return }
        $warn = ($how -eq '1')
        $lockAt = Get-Date
        if ($warn) { $lockAt = $lockAt.AddSeconds($closeWarnMinutes * 60) }

        $until1 = $lockAt.AddHours(1); $until3 = $lockAt.AddHours(3)
        $night = Get-NextClockTime 2; $morning = Get-NextClockTime 8
        if ($night -le $lockAt.AddMinutes(30)) { $night = $night.AddDays(1) }
        if ($morning -le $lockAt.AddMinutes(30)) { $morning = $morning.AddDays(1) }
        $period = Read-UiChoice -Header ("Вход в {0} закрыть до какого времени?" -f $baseName) -Keys @('1', '2', '3', '4', '0') -Labels @(
            ('на час, до {0}' -f $until1.ToString('dd.MM HH:mm')), ('на 3 часа, до {0}' -f $until3.ToString('dd.MM HH:mm')),
            ('до {0}' -f $night.ToString('dd.MM HH:mm')), ('до {0}' -f $morning.ToString('dd.MM HH:mm')), 'Отмена') -CancelKey '0' -DefaultKey '2' -Notes @(
            'Открыть раньше - тем же меню. Срок - на случай, если забыть открыть: в это время вход откроется сам, а запрет регламентных заданий останется до «Открыть».')
        $until = $null
        switch ($period) { '1' { $until = $until1 } '2' { $until = $until3 } '3' { $until = $night } '4' { $until = $morning } }
        if ($null -eq $until) { Write-Line '  отмена: ничего не менял'; return }

        $whenText = 'Сейчас вход закроется'
        if ($warn) { $whenText = ('Сейчас пользователи увидят предупреждение, в {0} вход закроется' -f $lockAt.ToString('HH:mm')) }
        if ($isProd) {
            $question = "Закрыть {0}? {1} до {2} (кроме входа с кодом разрешения), регламентные задания будут запрещены, оставшиеся сеансы - завершены." -f `
                $baseName, $whenText, $until.ToString('dd.MM HH:mm')
            if (-not (Confirm-Ui -Question $question -Yes 'Да, закрыть' -No 'Нет' -DefaultNo)) { Write-Line '  отмена: ничего не менял'; return }
        }

        $state = New-GateLockState
        $info['base'] = $baseName
        $info['which'] = $Which
        $info['target'] = [string]$target.Identity
        $info['status'] = 'warning'
        $info['by'] = [Environment]::UserName
        $info['startedAt'] = (Get-Date).ToString('dd.MM.yyyy HH:mm:ss')
        $info['lockAt'] = $lockAt.ToString('dd.MM.yyyy HH:mm')
        $info['until'] = $until.ToString('dd.MM.yyyy HH:mm')
        $info['closedAt'] = ''
        $from = $lockAt
        $message = "Технические работы: в {0} программа закроется, вход будет закрыт до {1}. Сохраните работу и выйдите из программы до {0}." -f `
            $lockAt.ToString('HH:mm'), $until.ToString('dd.MM HH:mm')
        if (-not $warn) {
            # Сразу: начало на 30 минут раньше - часы сервера и этой машины могут расходиться.
            $from = $lockAt.AddMinutes(-30)
            $message = "Технические работы, вход в программу закрыт до {0}" -f $until.ToString('dd.MM HH:mm')
        }
        try { Set-GateSessionLock $state $target $from $until $script:UnlockCode $message { param($t) Read-BaseInfoAgain $t $script:CloseBaseName } }
        finally { Save-CloseRecord $baseName $state $info }
        if ($warn) {
            Write-Line ("  поставил блокировку начала сеансов с {0} до {1}: пользователи видят предупреждение, в {0} их программы закроются сами" -f $lockAt.ToString('HH:mm'), $until.ToString('dd.MM HH:mm')) 'Green'
            Write-RunLog ("Предупреждение пользователей {0}: блокировка начала сеансов с {1}" -f $baseName, $lockAt.ToString('HH:mm:ss'))
            $answer = Wait-CloseWarning $lockAt
            if ($answer -eq '2') { Write-Line '  закрытие отменено: снимаю предупреждение, база остаётся открытой' 'Yellow'; return }
            if ($answer -eq 'empty') { Write-Line ("  в {0} сеансов пользователей не осталось" -f $baseName) 'Green' }
            if ($answer -eq 'time') { Write-Line ("  {0}: время вышло" -f (Get-Date -Format 'HH:mm')) }
        }

        # Свойства - заново: за время ожидания соединение с агентом могло устареть, новое подтверждает ту же цель.
        $link = Connect-ClusterAgent
        $target = Get-BaseInfo -Link $link -BaseName $baseName -User $user -Password $password
        $current = Read-BaseInfoAgain $target $baseName
        if (-not (Test-GateSessionLock $state $current)) { throw 'блокировку начала сеансов изменили или сняли во время предупреждения: базу не закрываю' }
        # Регламентные - до завершения сеансов: иначе фоновые задания запустятся снова.
        $jobsNew = $false
        try { $jobsNew = Set-GateJobsLock $state $target { param($t) Read-BaseInfoAgain $t $script:CloseBaseName } }
        finally { Save-CloseRecord $baseName $state $info }
        if ($jobsNew) { Write-Line '  поставил блокировку регламентных заданий' 'Green' }
        else { Write-Line '  регламентные задания были запрещены до закрытия: так и оставляю, при открытии этот запрет не снимется' }
        if ($warn) {
            # Сообщение - уже не предупреждение, а «вход закрыт»: его видит тот, кто пробует войти. Все вышли раньше
            # или «не ждать» - начало блокировки ещё и переносится на сейчас, иначе до него в базу можно было бы войти.
            $early = ((Get-Date) -lt $lockAt)
            $from = $lockAt
            if ($early) { $from = (Get-Date).AddMinutes(-30) }
            $message = "Технические работы, вход в программу закрыт до {0}" -f $until.ToString('dd.MM HH:mm')
            try { Set-GateSessionLock $state $target $from $until $script:UnlockCode $message { param($t) Read-BaseInfoAgain $t $script:CloseBaseName } }
            finally { Save-CloseRecord $baseName $state $info }
            if ($early) { Write-Line '  блокировка начала сеансов действует с этой минуты' 'Green' }
        }

        $info['status'] = 'closed'
        $info['closedAt'] = (Get-Date).ToString('dd.MM.yyyy HH:mm:ss')
        Save-CloseRecord $baseName $state $info
        $keep = $true
        $jobsText = 'регламентные задания запрещены'
        if (-not $state.JobsSet) { $jobsText = 'регламентные задания были запрещены до закрытия' }
        Write-CloseHistory ("{0} закрыта: вход до {1}, {2}; пользователь Windows {3}" -f $baseName, $until.ToString('dd.MM.yyyy HH:mm'), $jobsText, [Environment]::UserName)

        # Сеансы, кроме конфигуратора: завершить; зависший клиент или фоновое задание может уйти не сразу - до трёх раз.
        # Список не прочитался - не «никого нет»: прочитать ещё раз, завершать - когда прочитался.
        $seen = Get-UserSessions $link $baseName
        $stopped = 0
        for ($try = 1; $try -le 3 -and ($seen.Failed -or $seen.Users.Count -gt 0); $try++) {
            if (-not $seen.Failed) {
                try {
                    foreach ($line in @(Stop-BaseSessions -Link $link -BaseName $baseName)) {
                        Write-Line ('  ' + $line)
                        if ($line.EndsWith(' - завершён')) { $stopped++ }
                    }
                }
                catch { Write-Line ('  завершить сеансы не смог: ' + $_.Exception.Message) 'Yellow' }
            }
            Start-Sleep -Seconds 3
            $seen = Get-UserSessions $link $baseName
        }
        $sessionsDone = (-not $seen.Failed -and $seen.Users.Count -eq 0)
        if ($seen.Failed) { Write-Line '  сеансы прочитать не смог: завершены ли все, не знаю' 'Yellow' }
        elseif ($seen.Users.Count -gt 0) {
            Write-Line ("  не завершились сеансы: {0}" -f $seen.Users.Count) 'Yellow'
            foreach ($entry in $seen.Users) { Write-Line ('    ' + $entry.Text) 'Yellow' }
        }
        $designers = @(Get-BaseSessions $link $baseName | Where-Object { -not $_.IsError -and $_.IsDesigner })
        if ($designers.Count -gt 0) {
            foreach ($entry in $designers) { Write-Line ('  конфигуратор: ' + $entry.Text) 'Yellow' }
            $script:CloseLink = $link
            $answer = Read-UiChoice -Header ("В {0} открыт конфигуратор. Закрой его сам - увижу и продолжу, или:" -f $baseName) -Keys @('1', '2') -CancelKey '2' -DefaultKey '2' -Labels @(
                'Закрыть отсюда (сеанс прерывается, несохранённые правки в нём пропадут)', 'Оставить конфигуратор открытым') -Poll {
                $now = @(Get-BaseSessions $script:CloseLink $script:CloseBaseName)
                if (@($now | Where-Object { $_.IsError }).Count -eq 0 -and @($now | Where-Object { $_.IsDesigner }).Count -eq 0) { return 'closed' }
                return ''
            }
            if ($answer -eq '1') { foreach ($line in @(Stop-BaseSessions -Link $link -BaseName $baseName -Designers)) { Write-Line ('  ' + $line) } }
            elseif ($answer -eq 'closed') { Write-Line '  конфигуратор закрыт' 'Green' }
            else { Write-Line '  конфигуратор оставил открытым' }
        }

        Write-Host ''
        if ($sessionsDone) {
            Write-Line ("{0} ЗАКРЫТА: вход закрыт до {1} (войти можно только с кодом разрешения UnlockCode), {2}, завершено сеансов: {3}." -f `
                $baseName, $until.ToString('dd.MM.yyyy HH:mm'), $jobsText, $stopped) 'Green'
        }
        else {
            # Вход закрыт, но что сеансов пользователей не осталось, не подтверждено: не зелёный итог и код возврата 1.
            $script:CloseUnconfirmed = $true
            Write-Line ("{0}: ВХОД ЗАКРЫТ до {1}, {2}, но сеансы пользователей завершены не все или не прочитаны (завершено: {3}). Проверь «Показать состояние баз»; оставшиеся - консоль кластера." -f `
                $baseName, $until.ToString('dd.MM.yyyy HH:mm'), $jobsText, $stopped) 'Yellow'
        }
        Write-Line ('  ' + (Get-OpenBaseHint $baseName) + '. Блокировки снимутся только те, что поставило закрытие.')
    }
    finally {
        if (-not $keep -and $null -ne $state -and ($state.Expected.Count -or $state.JobsSet)) {
            try {
                $undoTarget = Get-BaseInfo -Link (Connect-ClusterAgent) -BaseName $baseName -User $user -Password $password
                $released = Restore-GateLocks $state $undoTarget $true { param($t) Read-BaseInfoAgain $t $script:CloseBaseName }
                if ($released) { Write-Line ("  снял с {0}: {1} - база открыта, как была до закрытия" -f $baseName, $released) 'Green' }
                Write-RunLog ("Закрытие {0} не закончено, снято: {1}" -f $baseName, $released)
            }
            catch { Write-Line ("  НЕ СНЯЛ или не подтвердил снятие блокировок {0}: {1}. {2}; или консоль кластера." -f $baseName, $_.Exception.Message, (Get-OpenBaseHint $baseName)) 'Red' }
            try { Save-CloseRecord $baseName $state $info } catch { Write-Line ('  файл закрытия не записался: ' + $_.Exception.Message) 'Red' }
        }
        if ($null -ne $guard) { $guard.Dispose() }
    }
}

function Invoke-OpenBase {
    # Открыть базу, закрытую -CloseBase: по файлу закрытия снять только своё - блокировку начала сеансов (к параметрам
    # до закрытия, если её с тех пор не меняли) и запрет регламентных (если его ставило закрытие). Чужое не трогается.
    # На рабочей потом - вход без кода разрешения, как после обновления.
    param([string]$Which)
    $baseName = $script:TempBase; $user = $script:TempUser; $password = $script:TempPassword
    if ($Which -eq 'Prod') { $baseName = $script:ProdBase; $user = $script:ProdUser; $password = $script:ProdPassword }
    $isProd = ($Which -eq 'Prod')
    $script:CloseBaseName = $baseName
    if (-not (Test-UiCanAsk)) { throw 'открыть базу - только с человеком у экрана: запусти из меню гейта' }
    $guard = $null
    try { $guard = [System.IO.File]::Open((Join-Path $deployRoot 'deploy.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'deploy.lock занят другим запуском (обновление рабочей, блокировки руками, закрытие базы): дождись его конца' }
    try {
        Write-Line ("ОТКРЫТЬ {0} ДЛЯ ПОЛЬЗОВАТЕЛЕЙ" -f $baseName) 'Cyan'
        Write-RunLog ("Открыть базу: {0}, пользователь Windows {1}" -f $baseName, [Environment]::UserName)
        $record = Read-CloseRecord $baseName
        $link = Connect-ClusterAgent
        Show-BaseState -Link $link -BaseName $baseName -User $user -Password $password
        if ($null -eq $record) {
            Write-Line ("  {0} не закрывалась пунктом «Закрыть»: снимать нечего. Блокировки руками - «Блокировки рабочей базы»." -f $baseName) 'Yellow'
            return
        }
        $target = Get-BaseInfo -Link $link -BaseName $baseName -User $user -Password $password
        $savedTarget = [string](Get-JsonValue $record 'target' '')
        if (-not $savedTarget -or $savedTarget -cne [string]$target.Identity) {
            # Сверять нечего: файл про ту базу, где ставились блокировки, - он остаётся.
            Write-Line ("  файл закрытия {0} записан для другого кластера или ИБ, чем в текущем профиле {1}\{2}: не сверяю и не снимаю. Блокировки той базы - консоль кластера." -f (Get-CloseFile $baseName), $script:Server, $baseName) 'Yellow'
            Write-RunLog ("Файл закрытия: цель «{0}» не совпала с текущей" -f $savedTarget)
            return
        }
        $state = Get-CloseLockState $record
        $now = Read-BaseInfoAgain $target $baseName
        $own = New-Object System.Collections.Generic.List[string]
        if ($state.Expected.Count) {
            if ($null -ne $state.Before -and (Test-GateSessionLock $state $now)) { $own.Add('блокировку начала сеансов') }
            else {
                $state.Expected = @()
                if ([bool]$now.SessionsDenied) { Write-Line '  блокировка начала сеансов стоит, но не та, что ставило закрытие (её поменяли): не трогаю' 'Yellow' }
            }
        }
        if ($state.JobsSet) {
            if ([bool]$now.ScheduledJobsDenied) { $own.Add('запрет регламентных заданий') }
            else { $state.JobsSet = $false }
        }
        if ($own.Count -eq 0) {
            Write-Line ("  блокировок, поставленных закрытием, на {0} уже нет: убираю файл закрытия" -f $baseName) 'Green'
            Save-CloseRecord $baseName $null @{}
            Write-CloseHistory ("{0}: файл закрытия убран, блокировок закрытия на базе уже не было" -f $baseName)
            return
        }
        if ($isProd -and -not (Confirm-Ui -Question ("Открыть {0}: снять {1}?" -f $baseName, ($own -join ' и ')) -Yes 'Да, открыть' -No 'Нет' -DefaultNo)) {
            Write-Line '  оставил как есть: база закрыта'
            return
        }
        $released = Restore-GateLocks $state $target $true { param($t) Read-BaseInfoAgain $t $script:CloseBaseName }
        # Снятое подтверждено (иначе Restore-GateLocks остановился бы) - файл больше не нужен.
        Save-CloseRecord $baseName $null @{}
        if ($released) { Write-Line ("Снял с {0}: {1}." -f $baseName, $released) 'Green' }
        $lockReleased = ($released -and ([string]$released).Contains('начала сеансов'))
        $closedText = [string](Get-JsonValue $record 'closedAt' '')
        $closedAt = [datetime]::MinValue
        if ($lockReleased -and $closedText -and [datetime]::TryParseExact($closedText, 'dd.MM.yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$closedAt)) {
            $span = (Get-Date) - $closedAt
            if ($span.TotalSeconds -lt 0) { $span = [timespan]::Zero }
            Write-Line ("  Простой {0}: {1} ч {2:00} мин (вход закрыт {3}, открыт {4})" -f $baseName, [int][Math]::Floor($span.TotalHours), $span.Minutes, $closedText, (Get-Date -Format 'dd.MM.yyyy HH:mm:ss'))
        }
        Write-CloseHistory ("{0} открыта, снял: {1}; пользователь Windows {2}" -f $baseName, $released, [Environment]::UserName)
        if ($isProd -and $lockReleased) {
            $plainLogin = Test-ProdPlainLogin
            $plainColor = 'Green'
            if ($plainLogin.Status -eq 'FAIL') { $plainColor = 'Red' } elseif ($plainLogin.Status -ne 'OK') { $plainColor = 'Yellow' }
            Write-Line ("[{0}] Вход без кода разрешения: {1}" -f $plainLogin.Status, $plainLogin.Text) $plainColor
        }
    }
    finally { if ($null -ne $guard) { $guard.Dispose() } }
}

if ($CloseBase -and $OpenBase) { throw '-CloseBase и -OpenBase вместе не задаются: закрыть или открыть' }
if ($CloseBase) {
    $script:CloseUnconfirmed = $false
    Invoke-CloseBase $LocksBase
    if ($script:CloseUnconfirmed) { exit 1 }
    exit 0
}
if ($OpenBase) {
    Invoke-OpenBase $LocksBase
    exit 0
}
# ** Хлебников С.Ю. 20261120 конец

function Get-ToolSourceHash {
    # Отпечаток выгрузки обработки в файлы: <Имя>.xml и папка <Имя>, путь и хеш каждого файла.
    # Слово в слово та же функция в run.ps1 и deploy.ps1 (их сверяет тест deploy-prod-precheck): отпечаток один на оба скрипта.
    param([string]$Xml)
    $sourceRoot = Split-Path -Parent $Xml
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $files = @(Get-Item -LiteralPath $Xml)
    $dir = Join-Path $sourceRoot ([System.IO.Path]::GetFileNameWithoutExtension($Xml))
    if (Test-Path -LiteralPath $dir) { $files += @(Get-ChildItem -LiteralPath $dir -Recurse -File) }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($files | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
        $lines.Add(('{0}={1}' -f $relative, [System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($file.FullName))).Replace('-', '')))
    }
    return [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).Replace('-', '')
}

function Update-SelfCheckEpf {
    # Обработка самопроверки - из исходников поставки tools\src, как её собирает гейт перед прогоном (run.ps1,
    # Update-GateTools): после обновления гейта и до первого прогона на диске ещё прежняя сборка, а нужный режим мог
    # появиться только в новой. Собирает конфигуратор тестовой базы - рабочая для этого не открывается.
    # Не собралась - работаем с прежней.
    $xml = Join-Path (Resolve-RootPath 'tools\src') 'ВыполнитьПослеОбновления.xml'
    if (-not (Test-Path -LiteralPath $xml)) { return }
    $hash = Get-ToolSourceHash $xml
    $marker = $selfCheckEpf + '.source.txt'
    $built = ''
    if (Test-Path -LiteralPath $marker) { $built = ([System.IO.File]::ReadAllText($marker)).Trim() }
    if ((Test-Path -LiteralPath $selfCheckEpf) -and $built -eq $hash) { return }
    Write-Line '  обработка самопроверки собрана не из текущей поставки: собираю заново (конфигуратор тестовой базы)'
    $newFile = [System.IO.Path]::ChangeExtension($selfCheckEpf, '.new.epf')
    if (Test-Path -LiteralPath $newFile) { Remove-Item -LiteralPath $newFile -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $selfCheckEpf) -Force | Out-Null
    $result = Invoke-Designer -BaseName $script:TempBase -Command @('/LoadExternalDataProcessorOrReportFromFiles', ('"{0}"' -f $xml), ('"{0}"' -f $newFile)) `
        -LogName 'build_tool_ВыполнитьПослеОбновления.log' -TimeoutSec $timeoutLoadSec -Title 'Собрать обработку самопроверки из поставки'
    if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $newFile)) {
        Write-Line ("  обработка самопроверки из поставки не собралась (код {0}): {1}. Беру прежнюю." -f $result.ExitCode, $result.Text) 'Yellow'
        return
    }
    if (Test-Path -LiteralPath $selfCheckEpf) { Copy-Item -LiteralPath $selfCheckEpf -Destination ($selfCheckEpf + '.old') -Force }
    Move-Item -LiteralPath $newFile -Destination $selfCheckEpf -Force
    [System.IO.File]::WriteAllText($marker, $hash, (New-Object System.Text.UTF8Encoding($false)))
    Write-Line ("  обработка самопроверки собрана из поставки: {0} (прежняя - {0}.old)" -f $selfCheckEpf) 'Green'
}

# ** Хлебников С.Ю. 20261120 Снимок «что проверено» (#27): расширения - хеш-сумма конфигурации из базы, обработки -
# хеш файла справочника. Ошибка - в файле (ok = false), а не исключением: прогон гейта от снимка не зависит.
if ($SnapshotTemp) {
    $snapshot = [ordered]@{ time = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); base = $script:TempBase; ok = $false; error = ''; extensions = [ordered]@{}; processings = [ordered]@{} }
    try {
        $snapStates = Get-ExtensionStates -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword
        if (-not $snapStates.Ok) { throw ('расширения не прочитаны: ' + $snapStates.Error) }
        foreach ($snapName in @($snapStates.Items.Keys | Sort-Object)) {
            $snapItem = $snapStates.Items[$snapName]
            $snapshot.extensions[[string]$snapName] = [ordered]@{ version = [string]$snapItem.Version; hash = [string]$snapItem.Hash }
        }
        $snapExport = Export-Processings -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword -Dir (Join-Path $script:RunDir 'snapshot')
        if (-not $snapExport.Ok) { throw ('обработки не выгружены: ' + $snapExport.Error) }
        foreach ($snapProc in @($snapExport.Items | Sort-Object ObjName)) {
            $snapshot.processings[[string]$snapProc.ObjName] = [ordered]@{ version = [string]$snapProc.Version; hash = [string]$snapProc.Hash }
        }
        $snapshot.ok = $true
    }
    catch { $snapshot.error = [string]$_.Exception.Message }
    [System.IO.File]::WriteAllText($SnapshotTemp, (ConvertTo-Json -InputObject $snapshot -Depth 5), $Utf8Bom)
    exit 0
}
# ** Хлебников С.Ю. 20261120 конец

if ($ComCheck) {
    # Диагностика внешнего соединения с temp. Чтение расширений через COM на машине гейта не работало: соединение
    # есть, а РасширенияКонфигурации у него в PowerShell пусто (тесты этого не видят: в них COM подставной).
    # Здесь - каждая попытка добраться до расширений и что она вернула, потом - итог обычного чтения
    # (Get-ExtensionStates). Только чтение, только temp: рабочая не трогается.
    Write-Host ''
    Write-Line ("ПРОВЕРКА ВНЕШНЕГО СОЕДИНЕНИЯ С {0}, {1}" -f $script:TempBase, (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')) 'Cyan'
    Write-Line ("  PowerShell {0}, процесс {1}-битный; только чтение, {2} не трогаю" -f $PSVersionTable.PSVersion, ([IntPtr]::Size * 8), $script:ProdBase)
    $probe = {
        param([string]$Line, [string]$FakeScript, [string]$FakeFile)
        $report = New-Object System.Collections.Generic.List[string]
        function Add-Probe {
            # Одна попытка: что вернула или чем упала. Действие отдаёт значение через запятую (коллекция 1С цела).
            param([string]$Label, [scriptblock]$Action)
            $value = $null
            try {
                $value = & $Action
                $text = 'пусто'
                if ($null -ne $value) {
                    if ([Runtime.InteropServices.Marshal]::IsComObject($value)) { $text = 'объект COM' }
                    else {
                        $text = [string]$value
                        if ($text.Length -gt 90) { $text = $text.Substring(0, 90) + '...' }
                        $text = '{0} «{1}»' -f $value.GetType().Name, $text
                    }
                }
                $report.Add(('[{0}] {1}: {2}' -f $(if ($null -ne $value) { 'есть' } else { 'пусто' }), $Label, $text))
            }
            catch {
                $failure = $_.Exception
                while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
                $report.Add(('[ошибка] {0}: {1}' -f $Label, (([string]$failure.Message) -replace '\s+', ' ')))
                $value = $null
            }
            return , $value
        }
        $late = {
            # Позднее связывание (IDispatch) напрямую, мимо PowerShell.
            param($Object, [string]$Name, [object[]]$Arguments = $null)
            $flags = [System.Reflection.BindingFlags]::GetProperty
            $raw = $null
            if ($null -ne $Arguments) {
                $flags = [System.Reflection.BindingFlags]::InvokeMethod
                $raw = New-Object 'object[]' $Arguments.Count
                for ($k = 0; $k -lt $Arguments.Count; $k++) { if ($null -ne $Arguments[$k]) { $raw[$k] = $Arguments[$k].PSObject.BaseObject } }
            }
            $comType = [type]::GetType('System.__ComObject')
            if ($null -eq $comType) { $comType = $Object.GetType() }
            return , ($comType.InvokeMember($Name, $flags, $null, $Object, $raw))
        }
        if ($FakeScript) { . $FakeScript; $connector = New-FakeComConnector $FakeFile }
        else { $connector = New-Object -ComObject V83.COMConnector }
        $connection = $null
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            try { $connection = $connector.Connect($Line) }
            catch {
                $connectError = $_.Exception
                while ($null -ne $connectError.InnerException) { $connectError = $connectError.InnerException }
                $report.Add(('[ошибка] соединение: {0}' -f [string]$connectError.Message))
                return , $report.ToArray()
            }
            $report.Add(('[есть] соединение: за {0} с; объект COM: {1}' -f [int]$watch.Elapsed.TotalSeconds, [Runtime.InteropServices.Marshal]::IsComObject($connection)))
            try {
                $names = @($connection | Get-Member -ErrorAction Stop | ForEach-Object { [string]$_.Name })
                $about = @($names | Where-Object { $_ -match 'xtension|асширени|etadata|етаданн|NewObject' })
                $report.Add(('[есть] PowerShell видит у соединения членов: {0}; из нужных: {1}' -f $names.Count, $(if ($about.Count -gt 0) { $about -join ', ' } else { 'ни одного' })))
            }
            catch { $report.Add(('[ошибка] список членов соединения (Get-Member): {0}' -f [string]$_.Exception.Message)) }
            $conCom = [Runtime.InteropServices.Marshal]::IsComObject($connection)
            if (-not $conCom) { $report.Add('[есть] соединение - не объект COM (подставное): позднее связывание не проверяю') }
            $null = Add-Probe 'Метаданные.Версия, как видит PowerShell' { , $connection.Metadata.Version }
            if ($conCom) { $null = Add-Probe 'Метаданные.Версия, позднее связывание' { , (& $late (& $late $connection 'Metadata') 'Version') } }
            $managers = @(
                (Add-Probe 'менеджер, PowerShell: соединение.ConfigurationExtensions' { , $connection.ConfigurationExtensions }),
                (Add-Probe 'менеджер, PowerShell: соединение.РасширенияКонфигурации' { , $connection.'РасширенияКонфигурации' }),
                $(if ($conCom) { (Add-Probe 'менеджер, позднее связывание: ConfigurationExtensions' { , (& $late $connection 'ConfigurationExtensions') }) } else { $null }),
                $(if ($conCom) { (Add-Probe 'менеджер, позднее связывание: РасширенияКонфигурации' { , (& $late $connection 'РасширенияКонфигурации') }) } else { $null })
            )
            $manager = $null
            foreach ($candidate in $managers) { if ($null -ne $candidate) { $manager = $candidate; break } }
            if ($null -eq $manager) { $report.Add('[пусто] менеджер расширений не получен ни одним способом: дальше проверять нечем') }
            else {
                $isCom = [Runtime.InteropServices.Marshal]::IsComObject($manager)
                $lists = @(
                    (Add-Probe 'список, PowerShell: менеджер.Get()' { , $manager.Get() }),
                    $(if ($isCom) { (Add-Probe 'список, позднее связывание: Get()' { , (& $late $manager 'Get' @()) }) } else { $null }),
                    $(if ($isCom) { (Add-Probe 'список, позднее связывание: Получить()' { , (& $late $manager 'Получить' @()) }) } else { $null })
                )
                $list = $null
                foreach ($candidate in $lists) { if ($null -ne $candidate) { $list = $candidate; break } }
                if ($null -eq $list) { $report.Add('[пусто] список расширений не получен ни одним способом') }
                else {
                    $listCom = [Runtime.InteropServices.Marshal]::IsComObject($list)
                    $null = Add-Probe 'количество, PowerShell: список.Count()' { , $list.Count() }
                    if ($listCom) { $null = Add-Probe 'количество, позднее связывание: Count()' { , (& $late $list 'Count' @()) } }
                    $first = Add-Probe 'первое расширение, PowerShell: список.Get(0)' { , $list.Get(0) }
                    if ($null -eq $first -and $listCom) { $first = Add-Probe 'первое расширение, позднее связывание: Get(0)' { , (& $late $list 'Get' @(0)) } }
                    if ($null -ne $first) {
                        $firstCom = [Runtime.InteropServices.Marshal]::IsComObject($first)
                        $null = Add-Probe 'имя и версия, PowerShell' { , ('{0} {1}' -f $first.Name, $first.Version) }
                        if ($firstCom) { $null = Add-Probe 'имя и версия, позднее связывание' { , ('{0} {1}' -f (& $late $first 'Name'), (& $late $first 'Version')) } }
                        $null = Add-Probe 'хеш-сумма, PowerShell: соединение.Base64String(расширение.HashSum)' { , $connection.Base64String($first.HashSum) }
                        if ($firstCom) { $null = Add-Probe 'хеш-сумма, позднее связывание' { , (& $late $connection 'Base64String' @((& $late $first 'HashSum'))) } }
                    }
                }
                $null = Add-Probe 'источник «база данных», PowerShell: соединение.ConfigurationExtensionsSource.Database' { , $connection.ConfigurationExtensionsSource.Database }
                if ($isCom) { $null = Add-Probe 'источник «база данных», позднее связывание' { , (& $late (& $late $connection 'ConfigurationExtensionsSource') 'Database') } }
            }
        }
        finally {
            foreach ($comObject in @($connection, $connector)) {
                if ($null -ne $comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
            }
        }
        return , $report.ToArray()
    }
    $call = Invoke-UiBackground -Script $probe -Arguments @((Get-ComConnectionLine $script:TempBase $script:TempUser $script:TempPassword), $script:FakeComScript, [string]$env:CI_FAKE_COM) `
        -Title ("Проверить внешнее соединение с {0}" -f $script:TempBase) -TimeoutSec ($comTimeoutSec * 2)
    $probeLines = @()
    if ($call.Ok -and $null -ne $call.Result) { $probeLines = @($call.Result | ForEach-Object { [string]$_ }) }
    foreach ($line in $probeLines) {
        $color = 'Gray'
        if ($line.StartsWith('[ошибка]')) { $color = 'Red' } elseif ($line.StartsWith('[пусто]')) { $color = 'Yellow' } elseif ($line.StartsWith('[есть]')) { $color = 'Green' }
        if ($script:TempPassword) { $line = $line.Replace($script:TempPassword, '***') }
        Write-Line ('  ' + $line) $color
    }
    if (-not $call.Ok) {
        $probeError = [string]$call.Error
        if ($script:TempPassword -and $probeError) { $probeError = $probeError.Replace($script:TempPassword, '***') }
        Write-Line ("  проверка оборвалась: {0}" -f $probeError) 'Red'
    }
    Write-Host ''
    Write-Line 'Обычное чтение расширений (им пользуются сравнение и обновление):'
    $comStates = Get-ExtensionStates -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword
    if ($comStates.Ok) {
        foreach ($name in @($comStates.Items.Keys | Sort-Object)) { Write-Line ("  {0}: версия {1}, хеш-сумма {2}" -f $name, $(if ($comStates.Items[$name].Version) { [string]$comStates.Items[$name].Version } else { '?' }), $(if ($comStates.Items[$name].Hash) { 'есть' } else { 'нет' })) }
        Write-Line ("ИТОГ: расширения {0} через внешнее соединение читаются: {1}. В базе ничего не изменено. Журнал: {2}" -f $script:TempBase, $comStates.Items.Count, $script:RunLogPath) 'Green'
        exit 0
    }
    Write-Line ("  не прочитал: {0}" -f $comStates.Error) 'Red'
    Write-Line ("ИТОГ: расширения {0} через внешнее соединение не читаются - сравнение идёт по выгрузкам. В базе ничего не изменено. Журнал: {1}" -f $script:TempBase, $script:RunLogPath) 'Yellow'
    exit 1
}

if ($ProdPreCheck) {
    # Проверка рабочей перед обновлением: клиент рабочей базы с обработкой самопроверки в режиме precheck. Обработка
    # выполняет два шага - «Окружение» и «ПередОбновлением» (их пишет пакет сценариев базы) - и только читает.
    # Здесь - ни блокировок, ни завершения сеансов, ни конфигуратора рабочей.
    Write-Line ("ПРОВЕРКА {0} ПЕРЕД ОБНОВЛЕНИЕМ, {1}" -f $script:ProdBase, (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')) 'Cyan'
    Write-Line '  Только чтение: в базу ничего не пишется, блокировки не ставятся, сеансы не трогаются.'
    Update-SelfCheckEpf
    if (-not (Test-Path -LiteralPath $selfCheckEpf)) { throw ("нет обработки самопроверки: {0}" -f $selfCheckEpf) }
    $preDir = Join-Path $script:RunDir 'out'
    if (Test-Path -LiteralPath $preDir) { Remove-Item -LiteralPath $preDir -Recurse -Force }
    New-Item -ItemType Directory -Path $preDir -Force | Out-Null
    $preJournalCopy = Join-Path $script:RunDir 'precheck.txt'
    if (Test-Path -LiteralPath $preJournalCopy) { Remove-Item -LiteralPath $preJournalCopy -Force }
    $preTimeoutSec = 900
    $client = Invoke-ProdClient -Epf $selfCheckEpf -Parameter ("precheck;out={0}" -f $preDir) -DoneFile (Join-Path $preDir 'result.txt') `
        -TimeoutSec $preTimeoutSec -Title 'Проверка перед обновлением' -StartFile (Join-Path $preDir 'started.txt') -StartTimeoutSec $canaryTimeoutSec
    if (-not $client.Started) {
        throw ("обработка в {0} не начала проверку за {1} с. Либо вход не удался (пользователь, пароль, блокировка начала сеансов), либо обработка {2} собрана до появления этого режима: запусти любой прогон гейта - он пересоберёт её из поставки" -f $script:ProdBase, $canaryTimeoutSec, $selfCheckEpf)
    }
    if (-not $client.Done) { throw ("проверка не закончилась за {0} мин; что успела записать - в {1}" -f [int]($preTimeoutSec / 60), $preDir) }
    $preResult = Read-KeyValueFile (Join-Path $preDir 'result.txt')
    $preStatus = [string](Get-Setting $preResult 'status' '')
    if ($preStatus -ne 'done') { throw ("обработка ответила «{0}»: {1}" -f $preStatus, (Get-Setting $preResult 'message' '')) }
    $preJournal = Join-Path $preDir 'precheck.txt'
    if (-not (Test-Path -LiteralPath $preJournal)) { throw ("обработка ответила «done», а журнала проверки нет: {0}" -f $preJournal) }
    $preLines = @([System.IO.File]::ReadAllLines($preJournal, [System.Text.Encoding]::UTF8))
    [System.IO.File]::WriteAllLines($preJournalCopy, [string[]]$preLines, $Utf8Bom)
    # Журнал - на экран целиком: записи ОШИБКА красным, ВНИМАНИЕ жёлтым; строки продолжения - цветом своей записи.
    $preTagRegex = New-Object System.Text.RegularExpressions.Regex('^\s*(?:\d\d:\d\d:\d\d )?\[(ОК|ОШИБКА|ВНИМАНИЕ|ПРОПУСК|ИНФО)\]')
    $preCounts = @{ 'ОК' = 0; 'ОШИБКА' = 0; 'ВНИМАНИЕ' = 0; 'ПРОПУСК' = 0; 'ИНФО' = 0 }
    $preColor = 'Gray'
    Write-Host ''
    foreach ($line in $preLines) {
        $text = ([string]$line).TrimStart([char]0xFEFF)
        $found = $preTagRegex.Match($text)
        if ($found.Success) {
            $tag = $found.Groups[1].Value
            $preCounts[$tag] = $preCounts[$tag] + 1
            $preColor = 'Gray'
            if ($tag -ceq 'ОШИБКА') { $preColor = 'Red' } elseif ($tag -ceq 'ВНИМАНИЕ' -or $tag -ceq 'ПРОПУСК') { $preColor = 'Yellow' }
        }
        elseif ($text.StartsWith('===')) { $preColor = 'Cyan' }
        elseif (-not $text.StartsWith($SelfCheckIndent, [System.StringComparison]::Ordinal)) { $preColor = 'Gray' }
        Write-Line ('  ' + $text) $preColor
    }
    Write-Host ''
    $preTotal = 'ошибок {0}, предупреждений {1}, пропусков {2}' -f $preCounts['ОШИБКА'], $preCounts['ВНИМАНИЕ'], $preCounts['ПРОПУСК']
    $preTotalColor = 'Green'
    if ($preCounts['ОШИБКА'] -gt 0) { $preTotalColor = 'Red' } elseif ($preCounts['ВНИМАНИЕ'] + $preCounts['ПРОПУСК'] -gt 0) { $preTotalColor = 'Yellow' }
    Write-Line ("Проверка {0} перед обновлением: {1}. В базе ничего не изменено. Журнал: {2}" -f $script:ProdBase, $preTotal, $preJournalCopy) $preTotalColor
    exit 0
}

function Get-NonEmpty {
    param([string]$Value, [string]$Default)
    if ([string]::IsNullOrEmpty($Value)) { return $Default }
    return $Value
}

function Write-ChangeGroups {
    # Разница одного расширения или обработки: в консоль и в html. Было - рабочая, стало - temp.
    param($Changes, [System.Text.StringBuilder]$Html)
    $groups = @(
        @{ Title = 'Есть только в temp (новые)'; Items = @($Changes.Objects | Where-Object { $_.Added }) },
        @{ Title = 'Есть только в рабочей (в temp удалены)'; Items = @($Changes.Objects | Where-Object { $_.Removed }) },
        @{ Title = 'Отличаются'; Items = @($Changes.Objects | Where-Object { -not $_.Added -and -not $_.Removed }) }
    )
    foreach ($group in $groups) {
        if ($group.Items.Count -eq 0) { continue }
        Write-Line ("    {0}:" -f $group.Title) 'Yellow'
        [void]$Html.Append(('<h3>{0}</h3><ul>' -f (ConvertTo-Html $group.Title)))
        foreach ($object in $group.Items) {
            Write-Line ("      {0}" -f $object.Name)
            [void]$Html.Append(('<li><b>{0}</b><ul>' -f (ConvertTo-Html $object.Name)))
            foreach ($part in $object.Parts) {
                Write-Line ("        {0}" -f $part) 'DarkGray'
                [void]$Html.Append(('<li>{0}</li>' -f (ConvertTo-Html $part)))
            }
            [void]$Html.Append('</ul></li>')
        }
        [void]$Html.Append('</ul>')
    }
    if (@($Changes.Marks).Count -gt 0) {
        Write-Line '    Пометки авторов, которых нет в рабочей:' 'Yellow'
        [void]$Html.Append('<h3>Пометки авторов, которых нет в рабочей</h3><ul>')
        foreach ($mark in $Changes.Marks) { Write-Line ("      {0}" -f $mark) 'DarkGray'; [void]$Html.Append(('<li>{0}</li>' -f (ConvertTo-Html $mark))) }
        [void]$Html.Append('</ul>')
    }
}

if ($CompareExtensions) {
    # Расширения temp и рабочей: версии и хеши через COM (быстро), где отличаются или не прочитались -
    # выгрузка обеих баз в файлы (конфигуратор, только чтение; повторно - только изменения) и разница по
    # объектам и процедурам. Было - рабочая, стало - temp: то, что принесёт обновление.
    Write-Line ("СРАВНЕНИЕ РАСШИРЕНИЙ: {0} (было) и {1} (стало), {2}" -f $script:ProdBase, $script:TempBase, (Get-Date -Format 'dd.MM.yyyy HH:mm')) 'Cyan'
    $cmpTemp = Get-ExtensionStates -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword
    $cmpProd = Get-ExtensionStates -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
    if (-not $cmpTemp.Ok) { Write-Line ("  {0}: через COM не прочитал - {1}; сравню по выгрузкам" -f $script:TempBase, $cmpTemp.Error) 'Yellow' }
    if (-not $cmpProd.Ok) { Write-Line ("  {0}: через COM не прочитал - {1}; сравню по выгрузкам" -f $script:ProdBase, $cmpProd.Error) 'Yellow' }
    $cmpHtml = New-Object System.Text.StringBuilder
    [void]$cmpHtml.Append('<html><head><meta charset="utf-8"></head><body>')
    [void]$cmpHtml.Append(('<h1>Расширения: {0} и {1}, {2}</h1><p>Было - рабочая, стало - temp: то, что принесёт обновление.</p>' -f (ConvertTo-Html $script:ProdBase), (ConvertTo-Html $script:TempBase), (Get-Date -Format 'dd.MM.yyyy HH:mm')))
    $cmpDiffer = 0
    $cmpFailed = 0
    foreach ($name in $deployExtensions) {
        Write-Host ''
        $tempVersion = ''; $prodVersion = ''
        if ($cmpTemp.Ok -and $cmpTemp.Items.ContainsKey($name)) { $tempVersion = [string]$cmpTemp.Items[$name].Version }
        if ($cmpProd.Ok -and $cmpProd.Items.ContainsKey($name)) { $prodVersion = [string]$cmpProd.Items[$name].Version }
        $versions = "temp {0}, рабочая {1}" -f (Get-NonEmpty $tempVersion '?'), (Get-NonEmpty $prodVersion '?')
        if ($cmpTemp.Ok -and $cmpProd.Ok) {
            $inTemp = $cmpTemp.Items.ContainsKey($name); $inProd = $cmpProd.Items.ContainsKey($name)
            if (-not $inTemp -and -not $inProd) { Write-Line ("  {0}: нет ни в temp, ни в рабочей" -f $name) 'DarkGray'; continue }
            if ($inTemp -and $inProd -and $cmpTemp.Items[$name].Hash -and $cmpTemp.Items[$name].Hash -eq $cmpProd.Items[$name].Hash) {
                Write-Line ("  {0}: одинаковые ({1})" -f $name, $versions) 'Green'
                [void]$cmpHtml.Append(('<h2>{0}: одинаковые</h2><p>{1}</p>' -f (ConvertTo-Html $name), (ConvertTo-Html $versions)))
                continue
            }
        }
        Write-Line ("  {0}: {1} - выгружаю обе базы в файлы" -f $name, $versions) 'Cyan'
        $tempDump = Update-DumpDir -BaseName $script:TempBase -Extension $name -Dir (Join-Path (Join-Path $script:RunDir 'temp') $name)
        $prodDump = Update-DumpDir -BaseName $script:ProdBase -Extension $name -Dir (Join-Path (Join-Path $script:RunDir 'prod') $name)
        if (-not $tempDump.Ok -and -not $tempDump.Absent) { Write-Line ("    из {0} не выгрузил: {1}" -f $script:TempBase, $tempDump.Detail) 'Red'; $cmpFailed++; continue }
        if (-not $prodDump.Ok -and -not $prodDump.Absent) { Write-Line ("    из {0} не выгрузил: {1}" -f $script:ProdBase, $prodDump.Detail) 'Red'; $cmpFailed++; continue }
        [void]$cmpHtml.Append(('<h2>{0}</h2><p>{1}</p>' -f (ConvertTo-Html $name), (ConvertTo-Html $versions)))
        if ($tempDump.Absent) { Write-Line '    в temp его нет: обновление его не принесёт' 'Yellow'; [void]$cmpHtml.Append('<p>В temp его нет.</p>'); continue }
        if ($prodDump.Absent) { Write-Line '    в рабочей его нет: обновление добавит целиком' 'Yellow'; [void]$cmpHtml.Append('<p>В рабочей его нет: обновление добавит целиком.</p>') }
        $prodDir = ''
        if ($prodDump.Ok) { $prodDir = $prodDump.Dir }
        $changes = Get-ExtensionChanges -OldDir $prodDir -NewDir $tempDump.Dir
        if (@($changes.Objects).Count -eq 0) {
            Write-Line '    по выгрузкам отличий нет (разница только в служебных данных)' 'Green'
            [void]$cmpHtml.Append('<p>По выгрузкам отличий нет.</p>')
            continue
        }
        $cmpDiffer++
        Write-ChangeGroups -Changes $changes -Html $cmpHtml
    }
    [void]$cmpHtml.Append('<p>Обозначения: + новая процедура, ~ изменена, - удалена.</p></body></html>')
    $cmpFile = Join-Path $script:RunDir 'compare.html'
    [System.IO.File]::WriteAllText($cmpFile, $cmpHtml.ToString(), $Utf8Bom)
    Write-Host ''
    $cmpColor = 'Cyan'
    $cmpFailText = ''
    if ($cmpFailed -gt 0) { $cmpColor = 'Red'; $cmpFailText = (", НЕ СРАВНИЛИСЬ: {0} (см. выше)" -f $cmpFailed) }
    Write-Line ("Отличаются расширений: {0}{1}. Обозначения: + новая процедура, ~ изменена, - удалена. Отчёт: {2}" -f $cmpDiffer, $cmpFailText, $cmpFile) $cmpColor
    exit 0
}

if ($CompareProcessings) {
    # Внешние обработки справочника «Дополнительные отчёты и обработки» temp и рабочей: через COM (только
    # чтение), по имени объекта. Отличаются - выгрузка обоих файлов в файлы конфигуратором temp и разница
    # по модулям и формам. Было - рабочая, стало - temp.
    Write-Line ("СРАВНЕНИЕ ВНЕШНИХ ОБРАБОТОК: {0} (было) и {1} (стало), {2}" -f $script:ProdBase, $script:TempBase, (Get-Date -Format 'dd.MM.yyyy HH:mm')) 'Cyan'
    foreach ($side in @('temp', 'prod', 'dump')) { $sideDir = Join-Path $script:RunDir $side; if (Test-Path -LiteralPath $sideDir) { Remove-Item -LiteralPath $sideDir -Recurse -Force } }
    $tempList = Export-Processings -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword -Dir (Join-Path $script:RunDir 'temp')
    $prodList = Export-Processings -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword -Dir (Join-Path $script:RunDir 'prod')
    if (-not $tempList.Ok) { Write-Line ("  {0}: не выгрузил - {1}" -f $script:TempBase, $tempList.Error) 'Red' }
    if (-not $prodList.Ok) { Write-Line ("  {0}: не выгрузил - {1}" -f $script:ProdBase, $prodList.Error) 'Red' }
    if (-not $tempList.Ok -or -not $prodList.Ok) { exit 1 }
    $tempByName = @{}; foreach ($item in @($tempList.Items)) { $tempByName[[string]$item.ObjName] = $item }
    $prodByName = @{}; foreach ($item in @($prodList.Items)) { $prodByName[[string]$item.ObjName] = $item }
    $cmpHtml = New-Object System.Text.StringBuilder
    [void]$cmpHtml.Append('<html><head><meta charset="utf-8"></head><body>')
    [void]$cmpHtml.Append(('<h1>Внешние обработки: {0} и {1}, {2}</h1><p>Было - рабочая, стало - temp.</p>' -f (ConvertTo-Html $script:ProdBase), (ConvertTo-Html $script:TempBase), (Get-Date -Format 'dd.MM.yyyy HH:mm')))
    $same = 0; $differ = 0
    foreach ($name in @(@($tempByName.Keys) + @($prodByName.Keys) | Sort-Object -Unique)) {
        $inTemp = $tempByName.ContainsKey($name); $inProd = $prodByName.ContainsKey($name)
        if ($inTemp -and $inProd -and $tempByName[$name].Hash -eq $prodByName[$name].Hash) { $same++; continue }
        $differ++
        Write-Host ''
        if (-not $inProd) {
            Write-Line ("  {0} ({1}, версия {2}): есть только в temp" -f $name, $tempByName[$name].Title, (Get-NonEmpty $tempByName[$name].Version '-')) 'Yellow'
            [void]$cmpHtml.Append(('<h2>{0}: есть только в temp</h2><p>{1}, версия {2}</p>' -f (ConvertTo-Html $name), (ConvertTo-Html $tempByName[$name].Title), (ConvertTo-Html $tempByName[$name].Version)))
            continue
        }
        if (-not $inTemp) {
            Write-Line ("  {0} ({1}, версия {2}): есть только в рабочей" -f $name, $prodByName[$name].Title, (Get-NonEmpty $prodByName[$name].Version '-')) 'Yellow'
            [void]$cmpHtml.Append(('<h2>{0}: есть только в рабочей</h2><p>{1}, версия {2}</p>' -f (ConvertTo-Html $name), (ConvertTo-Html $prodByName[$name].Title), (ConvertTo-Html $prodByName[$name].Version)))
            continue
        }
        $versions = "temp {0}, рабочая {1}" -f (Get-NonEmpty $tempByName[$name].Version '-'), (Get-NonEmpty $prodByName[$name].Version '-')
        Write-Line ("  {0} ({1}): отличается, {2}" -f $name, $tempByName[$name].Title, $versions) 'Yellow'
        [void]$cmpHtml.Append(('<h2>{0}: отличается</h2><p>{1}, {2}</p>' -f (ConvertTo-Html $name), (ConvertTo-Html $tempByName[$name].Title), (ConvertTo-Html $versions)))
        $dumpRoot = Join-Path $script:RunDir 'dump'
        $newDump = Get-ProcessingDump -File $tempByName[$name].File -Dir (Join-Path $dumpRoot ($name + '-temp')) -Title ("Выгрузить в файлы {0} из temp" -f $name)
        $oldDump = Get-ProcessingDump -File $prodByName[$name].File -Dir (Join-Path $dumpRoot ($name + '-prod')) -Title ("Выгрузить в файлы {0} из рабочей" -f $name)
        if (-not $newDump -or -not $oldDump) { Write-Line '    в файлы не выгрузилась: разницы по модулям нет, см. run.log' 'Red'; continue }
        $changes = Get-ExtensionChanges -OldDir $oldDump -NewDir $newDump -KeyPrefix 'DataProcessors/'
        if (@($changes.Objects).Count -eq 0) { Write-Line '    по выгрузке отличий нет: разница в самом файле (служебные данные)' 'DarkGray'; continue }
        Write-ChangeGroups -Changes $changes -Html $cmpHtml
    }
    [void]$cmpHtml.Append('<p>Обозначения: + новая процедура, ~ изменена, - удалена.</p></body></html>')
    $cmpFile = Join-Path $script:RunDir 'compare.html'
    [System.IO.File]::WriteAllText($cmpFile, $cmpHtml.ToString(), $Utf8Bom)
    Write-Host ''
    Write-Line ("Обработок: одинаковых {0}, отличаются {1}. Отчёт: {2}" -f $same, $differ, $cmpFile) 'Cyan'
    exit 0
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
        Assert-ProdOpen $prodStates
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

#region Расширения и обработки в git

# Репозиторий расширений (ExtensionsRepo): то, что стоит в temp, - в git, и обратно. Раскладка: extensions/<имя> -
# выгрузка расширения в файлы, processings/<имя> - выгрузка внешней обработки или отчёта в файлы; ConfigDumpInfo.xml
# не хранится. Git на машине гейта не нужен: GitHub API (github.ps1), тот же токен GitHubTokenPassFile.
# Какому коммиту соответствует temp - git\<репозиторий>\state.json: по нему видно, правили ли temp после загрузки.

function Get-GitSetup {
    $repo = [string](Get-Setting $cfg 'ExtensionsRepo' '')
    if (-not $repo) { throw 'не задан репозиторий расширений: «Настройки - Обновление гейта и git», ExtensionsRepo' }
    $tokenFile = [string](Get-Setting $cfg 'GitHubTokenPassFile' '')
    if (-not $tokenFile) { throw 'нет токена GitHub: «Настройки - Обновление гейта и git», GitHubTokenPassFile' }
    $gh = New-GhContext -Repo $repo -Token ([string](Get-PlainPassword $tokenFile)).Trim()
    $root = Join-Path (Resolve-RootPath ([string](Get-Setting $cfg 'GitDir' 'git'))) ($repo.Split('/')[1])
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return [pscustomobject]@{
        Gh = $gh; Repo = $repo; Branch = [string](Get-Setting $cfg 'ExtensionsBranch' 'main')
        Root = $root; Work = (Join-Path $root 'work'); StatePath = (Join-Path $root 'state.json')
    }
}

function Read-GitState {
    # commit - чему соответствует temp; pending* - pull request с правками temp, ещё не слитый в main; actionsDone -
    # действия после обновления (actions/*.bsl), которые прогоны гейта выполнили в temp или нашли выполненными.
    param($Setup)
    $state = [ordered]@{ repo = $Setup.Repo; commit = ''; how = ''; run = ''; time = ''; pendingBranch = ''; pendingNumber = 0; pendingUrl = ''; pendingCommit = ''; actionsDone = @() }
    if (Test-Path -LiteralPath $Setup.StatePath) {
        try {
            $read = [System.IO.File]::ReadAllText($Setup.StatePath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            foreach ($name in @($state.Keys)) { if ($null -ne $read.PSObject.Properties[$name]) { $state[$name] = $read.$name } }
            $state['actionsDone'] = @(@($state['actionsDone']) | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }
        catch { Write-RunLog ("git: state.json не прочитан: {0}" -f $_.Exception.Message) }
    }
    if ([string]$state['repo'] -ne $Setup.Repo) {
        foreach ($name in @('commit', 'how', 'run', 'pendingBranch', 'pendingUrl', 'pendingCommit')) { $state[$name] = '' }
        $state['pendingNumber'] = 0
        $state['actionsDone'] = @()
        $state['repo'] = $Setup.Repo
    }
    return $state
}

function Save-GitState {
    param($Setup, $State)
    $State['time'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    [System.IO.File]::WriteAllText($Setup.StatePath, (ConvertTo-Json -InputObject $State), $Utf8Bom)
}

function Get-GitShort {
    param([string]$Sha)
    if ($Sha.Length -ge 7) { return $Sha.Substring(0, 7) }
    return $Sha
}

function Get-GitFolders {
    # Что ведётся в git: имена папок extensions/<имя> и processings/<имя> среди путей файлов. HasProcessings - в git
    # есть processings/ (папки или manifest.json): тогда ведутся все элементы справочника обработок.
    param([hashtable]$Files)
    $extensions = New-Object System.Collections.Generic.List[string]
    $processings = New-Object System.Collections.Generic.List[string]
    $hasProcessings = $false
    foreach ($path in @($Files.Keys)) {
        $parts = ([string]$path).Split('/')
        if ($parts[0] -eq 'processings' -and $parts.Count -ge 2) { $hasProcessings = $true }
        if ($parts.Count -lt 3) { continue }
        if ($parts[0] -eq 'extensions' -and -not $extensions.Contains($parts[1])) { $extensions.Add($parts[1]) }
        elseif ($parts[0] -eq 'processings' -and -not $processings.Contains($parts[1])) { $processings.Add($parts[1]) }
    }
    return [pscustomobject]@{ Extensions = @($extensions | Sort-Object); Processings = @($processings | Sort-Object); HasProcessings = $hasProcessings }
}

function Get-GitProcessingFolders {
    # Папка в processings/ для каждого элемента справочника обработок (ссылка -> папка). Основной элемент имени
    # объекта - тот, в который пишет загрузка (не помечен на удаление, используемый - первым, режим regepf), - в папке
    # <имя объекта>; остальные с тем же именем - в <имя объекта>~<8 знаков ссылки>, их «Загрузить из git» не грузит.
    param($Items)
    $folders = @{}
    foreach ($group in @($Items | Group-Object ObjName)) {
        $ordered = @($group.Group | Sort-Object @{ Expression = { [int][bool]$_.Deleted } }, @{ Expression = { if ([string]$_.Use -eq 'Используется') { 0 } else { 1 } } }, @{ Expression = { [string]$_.Ref } })
        for ($index = 0; $index -lt $ordered.Count; $index++) {
            $item = $ordered[$index]
            if ($index -eq 0 -and -not $item.Deleted) { $folders[[string]$item.Ref] = [string]$item.ObjName }
            else { $folders[[string]$item.Ref] = '{0}~{1}' -f $item.ObjName, ([string]$item.Ref).Substring(0, [Math]::Min(8, ([string]$item.Ref).Length)) }
        }
    }
    return $folders
}

function Get-GitProcessingManifest {
    # processings/manifest.json: что за элемент справочника за каждой папкой. Пишет гейт при выгрузке из temp; при
    # загрузке из git не читается, правкой temp не считается (версия и хеш меняются от самой загрузки).
    param($Items, [hashtable]$Folders)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[')
    $sorted = @($Items | Sort-Object @{ Expression = { [string]$Folders[[string]$_.Ref] } })
    for ($index = 0; $index -lt $sorted.Count; $index++) {
        $item = $sorted[$index]
        $folder = 'null'
        $file = 'null'
        $hash = 'null'
        if ($item.File) {
            $folder = ConvertTo-GhJsonString ([string]$Folders[[string]$item.Ref])
            $file = ConvertTo-GhJsonString (Split-Path -Leaf $item.File)
            $hash = ConvertTo-GhJsonString ('sha256:' + ([string]$item.Hash).Replace('-', '').ToLowerInvariant())
        }
        $targets = '[' + ((@($item.Targets) | Where-Object { $_ } | ForEach-Object { ConvertTo-GhJsonString ([string]$_) }) -join ', ') + ']'
        $fields = New-Object System.Collections.Generic.List[string]
        $fields.Add(('"folder": ' + $folder))
        $fields.Add(('"objectName": ' + (ConvertTo-GhJsonString ([string]$item.ObjName))))
        $fields.Add(('"title": ' + (ConvertTo-GhJsonString ([string]$item.Title))))
        $fields.Add(('"kind": ' + (ConvertTo-GhJsonString ([string]$item.Kind))))
        $fields.Add(('"version": ' + (ConvertTo-GhJsonString ([string]$item.Version))))
        $fields.Add(('"use": ' + (ConvertTo-GhJsonString ([string]$item.Use))))
        $fields.Add(('"safeMode": ' + ([string][bool]$item.SafeMode).ToLowerInvariant()))
        $fields.Add(('"deleted": ' + ([string][bool]$item.Deleted).ToLowerInvariant()))
        $fields.Add(('"ref": ' + (ConvertTo-GhJsonString ([string]$item.Ref))))
        $fields.Add(('"file": ' + $file))
        $fields.Add(('"fileHash": ' + $hash))
        if ($item.TargetsError) { $fields.Add(('"targets": null')); $fields.Add(('"targetsError": ' + (ConvertTo-GhJsonString ([string]$item.TargetsError)))) }
        else { $fields.Add(('"targets": ' + $targets)) }
        $tail = ''
        if ($index -lt $sorted.Count - 1) { $tail = ',' }
        $lines.Add('  {')
        $lines.Add(('    ' + ($fields -join (",`n    "))))
        $lines.Add(('  }' + $tail))
    }
    $lines.Add(']')
    return ($lines -join "`n") + "`n"
}

function Add-GitSnapshotFiles {
    # Файлы папки выгрузки -> путь в репозитории (Prefix + путь через /). ConfigDumpInfo.xml не берётся.
    param([hashtable]$Files, [string]$Dir, [string]$Prefix)
    $full = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Recurse -File)) {
        $relative = $file.FullName.Substring($full.Length + 1).Replace('\', '/')
        if ($relative -eq 'ConfigDumpInfo.xml') { continue }
        $Files[$Prefix + $relative] = $file.FullName
    }
}

function Get-TempSnapshot {
    # Выгрузить из temp расширения, которые ведутся в git, и (WithProcessings) все элементы справочника обработок
    # в рабочую папку git\<репозиторий>\work. Files: путь в репозитории -> файл на диске; Missing: чего в temp нет;
    # Prefixes: что выгрузилось (у обработок - вся processings/); Processings и Folders - элементы справочника и их папки.
    param($Setup, [string[]]$Extensions, [switch]$WithProcessings)
    $files = @{}
    $missing = New-Object System.Collections.Generic.List[string]
    $prefixes = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Extensions)) {
        $dump = Update-DumpDir -BaseName $script:TempBase -Extension $name -Dir (Join-Path (Join-Path $Setup.Work 'extensions') $name)
        if ($dump.Absent) { $missing.Add(('расширение ' + $name)); continue }
        if (-not $dump.Ok) { throw ("{0} из {1} не выгрузилось в файлы: {2}" -f $name, $script:TempBase, $dump.Detail) }
        Add-GitSnapshotFiles -Files $files -Dir $dump.Dir -Prefix ('extensions/' + $name + '/')
        $prefixes.Add(('extensions/' + $name + '/'))
    }
    $items = @()
    $folders = @{}
    $skipped = @()
    if ($WithProcessings) {
        $taken = Add-GitProcessingSnapshot -Files $files -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword `
            -Root (Join-Path $Setup.Work 'processings') -EpfDir (Join-Path $script:RunDir 'epf') -Source 'temp'
        $items = $taken.Items
        $folders = $taken.Folders
        $skipped = @($taken.Skipped)
        $prefixes.Add('processings/')
    }
    return [pscustomobject]@{ Files = $files; Missing = $missing.ToArray(); Prefixes = $prefixes.ToArray(); Processings = $items; Folders = $folders; Skipped = $skipped }
}

function Add-GitProcessingSnapshot {
    # Все элементы справочника обработок базы (внешнее соединение, только чтение) - выгрузкой в файлы в папку Root
    # (конфигуратор temp) и manifest.json; в Files - пути processings/... Возвращает Items и Folders.
    param([hashtable]$Files, [string]$BaseName, [string]$User, [string]$Password, [string]$Root, [string]$EpfDir, [string]$Source)
    if (Test-Path -LiteralPath $EpfDir) { Remove-Item -LiteralPath $EpfDir -Recurse -Force }
    $export = Export-Processings -BaseName $BaseName -User $User -Password $Password -Dir $EpfDir -All
    if (-not $export.Ok) { throw ("обработки {0} не выгрузил: {1}" -f $BaseName, $export.Error) }
    $items = @($export.Items)
    $folders = Get-GitProcessingFolders $items
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    # Выгрузка в файлы - запуск конфигуратора на каждый файл. Файл тот же, что в прошлый раз (хеш, тот же
    # конфигуратор), - выгрузка с прошлого раза: ночью и на каждой загрузке из git иначе ушли бы десятки минут.
    $cachePath = Join-Path (Split-Path -Parent $Root) 'processings.cache.json'
    $cache = @{}
    if (Test-Path -LiteralPath $cachePath) {
        try {
            $read = [System.IO.File]::ReadAllText($cachePath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            foreach ($property in $read.PSObject.Properties) { $cache[$property.Name] = [string]$property.Value }
        }
        catch { Write-RunLog ("git: {0} не прочитан, обработки выгружаю заново: {1}" -f $cachePath, $_.Exception.Message) }
    }
    $kept = [ordered]@{}
    $skipped = @()
    $dumpedCount = 0
    $withFile = @($items | Where-Object { $_.File } | Sort-Object @{ Expression = { [string]$folders[[string]$_.Ref] } })
    # Сколько выгружать конфигуратором (не с прошлого раза) - чтобы в строке хода было «N из M».
    $isFresh = { param($Entry) $entryFolder = [string]$folders[[string]$Entry.Ref]; ($cache.Contains($entryFolder) -and $cache[$entryFolder] -eq ('{0}|{1}' -f $Entry.Hash, $script:V8) -and (Test-Path -LiteralPath (Join-Path (Join-Path $Root $entryFolder) ($Entry.ObjName + '.xml')))) }
    $toDump = @($withFile | Where-Object { -not (& $isFresh $_) }).Count
    if ($toDump -gt 0) { Write-Line ("  обработок {0} с файлом {1}: выгрузить в файлы {2}, остальные - с прошлого раза" -f $BaseName, $withFile.Count, $toDump) }
    foreach ($item in $withFile) {
        $folder = [string]$folders[[string]$item.Ref]
        $dir = Join-Path $Root $folder
        $key = '{0}|{1}' -f $item.Hash, $script:V8
        if (-not (& $isFresh $item)) {
            $dumpedCount++
            $dumped = Get-ProcessingDump -File $item.File -Dir $dir -Title ("Выгрузить в файлы {0} из {1} ({2} из {3})" -f $folder, $Source, $dumpedCount, $toDump)
            if (-not $dumped) {
                # Принятая файлом целиком (binaries/manifest.json, тот же sha256) не выгружается в файлы - так и задумано.
                $itemSha = ([string]$item.Hash).Replace('-', '').ToLowerInvariant()
                if ($null -ne $script:GitBinaryShas -and $script:GitBinaryShas.ContainsKey($itemSha)) {
                    Write-RunLog ("git: {0} - принята файлом целиком (sha256 {1}), в файлы не выгружаю" -f $folder, $itemSha)
                    $skipped += $folder
                    continue
                }
                throw ("обработка {0} ({1}) из {2} не выгрузилась в файлы, см. run.log" -f $folder, $item.Title, $BaseName)
            }
        }
        $kept[$folder] = $key
        Add-GitSnapshotFiles -Files $Files -Dir $dir -Prefix ('processings/' + $folder + '/')
    }
    # Папки элементов, которых в справочнике больше нет, - долой из рабочей папки: иначе попали бы в сравнение.
    foreach ($old in @(Get-ChildItem -LiteralPath $Root -Directory)) { if (-not $kept.Contains($old.Name)) { Remove-Item -LiteralPath $old.FullName -Recurse -Force } }
    [System.IO.File]::WriteAllText($cachePath, (ConvertTo-Json -InputObject $kept), $Utf8Bom)
    $manifest = Join-Path $Root 'manifest.json'
    [System.IO.File]::WriteAllText($manifest, (Get-GitProcessingManifest -Items $items -Folders $folders), (New-Object System.Text.UTF8Encoding($false)))
    $Files['processings/manifest.json'] = $manifest
    Write-RunLog ("git: обработок {0} в справочнике {1}, с файлом {2}, выгружено конфигуратором {3}, остальные - с прошлого раза" -f $BaseName, $items.Count, $kept.Count, $dumpedCount)
    return [pscustomobject]@{ Items = $items; Folders = $folders; Skipped = $skipped }
}

function Read-GitJsonFile {
    # JSON-файл коммита (Files - Get-GhFiles этого коммита) как объект; нет файла или не разобрался - $null.
    param($Setup, [hashtable]$Files, [string]$Path)
    if (-not $Files.ContainsKey($Path)) { return $null }
    try {
        $bytes = Get-GhBlob -Gh $Setup.Gh -Sha ([string]$Files[$Path])
        $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes).TrimStart([char]0xFEFF)
        if (-not $text.Trim()) { return $null }
        return (ConvertFrom-Json -InputObject $text)
    }
    catch { Write-RunLog ("git: {0} не прочитан: {1}" -f $Path, $_.Exception.Message); return $null }
}

function Get-GitManifestRefs {
    # processings/manifest.json коммита: папка -> элемент справочника (ref, objectName, file). По ним загрузка пишет
    # обработку в свой элемент, а не в первый с тем же именем объекта.
    param($Setup, [hashtable]$Files)
    $refs = @{}
    $manifest = Read-GitJsonFile -Setup $Setup -Files $Files -Path 'processings/manifest.json'
    foreach ($item in @($manifest)) {
        if ($null -eq $item -or $null -eq $item.PSObject.Properties['folder'] -or -not [string]$item.folder) { continue }
        $refs[[string]$item.folder] = $item
    }
    return $refs
}

function Get-GitBinaries {
    # binaries/manifest.json коммита (раздел 5.26): обработки, принятые файлом целиком (защищённые, непрозрачные) -
    # папка -> запись (folder, objectName, file, sha256, ref). Файл - binaries/<папка>/<файл>, ставится только с этим sha256.
    param($Setup, [hashtable]$Files)
    $list = @{}
    $manifest = Read-GitJsonFile -Setup $Setup -Files $Files -Path 'binaries/manifest.json'
    foreach ($item in @($manifest)) {
        if ($null -eq $item -or $null -eq $item.PSObject.Properties['folder'] -or -not [string]$item.folder) { continue }
        $list[[string]$item.folder] = $item
    }
    return $list
}

function Initialize-GitBinaryShas {
    # sha256 файлов, принятых целиком (binaries/manifest.json данных коммитов): такие элементы справочника temp не
    # выгружаются в файлы (Add-GitProcessingSnapshot) и не считаются правкой temp.
    param($Setup, $FileSets)
    $script:GitBinaryShas = @{}
    foreach ($files in @($FileSets)) {
        if ($null -eq $files) { continue }
        $binaries = Get-GitBinaries -Setup $Setup -Files $files
        foreach ($folder in @($binaries.Keys)) { $script:GitBinaryShas[([string]$binaries[$folder].sha256).ToLowerInvariant()] = $folder }
    }
}

function Get-GitSkippedPaths {
    # Пути папок processings/<папка>/ коммита, которые выгрузка temp пропустила (обработка принята файлом целиком).
    param($Snapshot, [hashtable]$Files)
    $paths = @()
    foreach ($folder in @($Snapshot.Skipped)) {
        $prefix = 'processings/' + $folder + '/'
        $paths += @($Files.Keys | Where-Object { ([string]$_).StartsWith($prefix, [System.StringComparison]::Ordinal) })
    }
    return , @($paths)
}

function Test-GitPrefix {
    param([string]$Path, [string[]]$Prefixes)
    foreach ($prefix in @($Prefixes)) { if ($Path.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return $true } }
    return $false
}

function Compare-GitSnapshot {
    # Чем выгрузка temp отличается от файлов коммита - только в выгрузившихся папках. Path, Kind (add, change,
    # delete), File (файл на диске), Sha (git-хеш файла). Ignore - пути, которые не сравниваются.
    param([hashtable]$Local, [hashtable]$Remote, [string[]]$Prefixes, [string[]]$Ignore = @())
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($path in @($Local.Keys | Where-Object { @($Ignore) -notcontains $_ } | Sort-Object)) {
        $sha = Get-GitBlobSha ([System.IO.File]::ReadAllBytes($Local[$path]))
        if (-not $Remote.ContainsKey($path)) { $changes.Add([pscustomobject]@{ Path = $path; Kind = 'add'; File = $Local[$path]; Sha = $sha }) }
        elseif ([string]$Remote[$path] -ne $sha) { $changes.Add([pscustomobject]@{ Path = $path; Kind = 'change'; File = $Local[$path]; Sha = $sha }) }
    }
    foreach ($path in @($Remote.Keys | Where-Object { @($Ignore) -notcontains $_ } | Sort-Object)) {
        if ($Local.ContainsKey($path) -or -not (Test-GitPrefix $path $Prefixes)) { continue }
        $changes.Add([pscustomobject]@{ Path = $path; Kind = 'delete'; File = ''; Sha = '' })
    }
    return , @($changes.ToArray())
}

function Get-GitChangeLines {
    # По папкам: «extensions/X: изменено 2, новых 1, удалено 0».
    param($Changes)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($group in @($Changes | Group-Object { $parts = ([string]$_.Path).Split('/'); if ($parts.Count -ge 3) { $parts[0] + '/' + $parts[1] } else { [string]$_.Path } } | Sort-Object Name)) {
        $kinds = @($group.Group | ForEach-Object { $_.Kind })
        $lines.Add(("{0}: изменено {1}, новых {2}, удалено {3}" -f $group.Name, @($kinds | Where-Object { $_ -eq 'change' }).Count, @($kinds | Where-Object { $_ -eq 'add' }).Count, @($kinds | Where-Object { $_ -eq 'delete' }).Count))
    }
    return , @($lines.ToArray())
}

function Get-GitFileLines {
    # Изменения по файлам: «~ путь» (изменён), «+ путь» (новый), «- путь» (удалён); не больше Limit строк, остальное -
    # числом. Дополняет строки по папкам (Get-GitChangeLines): на экране видно не только сколько, но и что.
    param($Changes, [int]$Limit = 10)
    $lines = New-Object System.Collections.Generic.List[string]
    $list = @($Changes | Sort-Object Path)
    foreach ($change in @($list | Select-Object -First $Limit)) {
        $mark = '~'
        if ($change.Kind -eq 'add') { $mark = '+' } elseif ($change.Kind -eq 'delete') { $mark = '-' }
        $lines.Add(('{0} {1}' -f $mark, $change.Path))
    }
    if ($list.Count -gt $Limit) { $lines.Add(('... и ещё файлов: {0}' -f ($list.Count - $Limit))) }
    return , @($lines.ToArray())
}

function New-GitVerifiedCommit {
    # Коммит изменений поверх Parent и проверка: в дереве нового коммита каждый файл с тем же хешем, что на диске,
    # удалённых нет. Не сошлось - исключение, ветки не двигаются.
    param($Setup, [string]$Parent, $Changes, [string]$Message)
    $list = @($Changes | ForEach-Object {
            if ($_.Kind -eq 'delete') { [pscustomobject]@{ Path = $_.Path; Bytes = $null } }
            else { [pscustomobject]@{ Path = $_.Path; Bytes = [System.IO.File]::ReadAllBytes($_.File) } }
        })
    $sha = New-GhCommit -Gh $Setup.Gh -Parent $Parent -Changes $list -Message $Message
    $check = Get-GhFiles -Gh $Setup.Gh -Commit $sha
    $bad = @($Changes | Where-Object { ($_.Kind -eq 'delete' -and $check.ContainsKey($_.Path)) -or ($_.Kind -ne 'delete' -and [string]$check[$_.Path] -ne $_.Sha) })
    if ($bad.Count -gt 0) {
        throw ("коммит {0} не сошёлся с выгрузкой: файлов {1}, например {2}. Ветки не трогаю" -f (Get-GitShort $sha), $bad.Count, $bad[0].Path)
    }
    Write-RunLog ("git: коммит {0} поверх {1}, файлов {2}" -f $sha, $Parent, @($Changes).Count)
    return $sha
}

function Get-GitReadme {
    return (@(
            '# Расширения и внешние обработки',
            '',
            'Репозиторий ведёт гейт расширений: что стоит в тестовой базе - здесь, и обратно.',
            '',
            '- `extensions/<имя>/` - расширение конфигурации, выгрузка в файлы (конфигуратор, «Выгрузить конфигурацию в файлы»).',
            '- `processings/<имя>/` - внешняя обработка, отчёт или печатная форма из справочника «Дополнительные отчёты и обработки», выгрузка в файлы.',
            '  Ведутся все элементы справочника, и помеченные на удаление. У нескольких элементов с одним именем объекта основной (тот, в который',
            '  пишет загрузка: не помечен на удаление, используемый - первым) - в `processings/<имя>/`, остальные - в `processings/<имя>~<8 знаков ссылки>/`:',
            '  их гейт в базу не грузит.',
            '- `processings/manifest.json` - что за элемент за каждой папкой: наименование, вид, версия, публикация, безопасный режим, пометка удаления,',
            '  ссылка, хеш файла, назначение. Пишет гейт при выгрузке из тестовой базы; руками его править незачем - при загрузке он не читается.',
            '- `ConfigDumpInfo.xml` не хранится: конфигуратор меняет его при каждой выгрузке.',
            '',
            '`main` - то, что должно стоять в тестовой базе. Правки - веткой и pull request. В тестовую базу main загружает гейт',
            '(«Загрузить из git»: проверки, канарейка, самопроверка, тесты); правки, сделанные прямо в тестовой базе, гейт выгружает',
            'веткой `temp/<время>` и pull request («Выгрузить temp в git»).',
            '',
            'Концы строк git не трогает (`.gitattributes`: `* -text`): файлы байт в байт такие, как их выгружает конфигуратор.'
        ) -join "`n") + "`n"
}

function Select-GitTracked {
    # Первая выгрузка: что вести в git. Расширения - из Extensions (тестовые не берутся), отмечает человек; обработки -
    # да или нет: если да, то все элементы справочника temp. $null - отмена.
    param($Setup)
    $candidates = @(@(Get-Setting $cfg 'Extensions' @()) | Where-Object { $_ } | ForEach-Object { [string]$_ } |
            Where-Object { $name = $_; @($unitOnly | Where-Object { [string]$_ -ieq $name }).Count -eq 0 })
    if ($candidates.Count -eq 0) { throw 'в настройке Extensions нет расширений' }
    $picked = Select-UiMany -Header ("Первая выгрузка в {0}: какие расширения {1} вести в git" -f $Setup.Repo, $script:TempBase) -Items $candidates -Preselected @(0..($candidates.Count - 1)) `
        -Notes @('Вендорские и чужие расширения можно не брать: их обновления приходят файлами .cfe.')
    if ($null -eq $picked) { return $null }
    $extensions = @($picked | ForEach-Object { $candidates[$_] })
    $withProcessings = $false
    $epfDir = Join-Path $script:RunDir 'epf-list'
    $export = Export-Processings -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword -Dir $epfDir -All
    if (-not $export.Ok) { throw ("обработки {0} не прочитал: {1}" -f $script:TempBase, $export.Error) }
    $items = @($export.Items)
    if ($items.Count -gt 0) {
        $deleted = @($items | Where-Object { $_.Deleted }).Count
        $want = Confirm-Ui -Question ("Вести в git и внешние обработки, отчёты и печатные формы {0}? Все элементы справочника: {1}, из них помечены на удаление {2}. По папке на элемент и processings/manifest.json." -f $script:TempBase, $items.Count, $deleted) -Yes 'Да, все' -No 'Нет, только расширения'
        if ($null -eq $want) { return $null }
        $withProcessings = [bool]$want
    }
    return [pscustomobject]@{ Extensions = $extensions; Processings = @(); HasProcessings = $withProcessings }
}

function New-GitTempBranch {
    # Снимок temp поверх Base. Только новая ветка и PR. Отмечаем снимок в state.json после создания PR.
    # Открытый PR выгрузки, и снимок - поверх его же коммита: новый коммит в ту же ветку, второго PR нет.
    param($Setup, $State, [string]$Base, $Changes, [string]$Note = '')
    $stamp = Get-Date
    if ([int]$State['pendingNumber'] -gt 0 -and [string]$State['pendingBranch'] -and $Base -eq [string]$State['pendingCommit']) {
        $open = $null
        try { $open = Get-GhPull -Gh $Setup.Gh -Number ([int]$State['pendingNumber']) }
        catch { Write-RunLog ("git: pull request #{0} не прочитан, выгружаю новым: {1}" -f $State['pendingNumber'], $_.Exception.Message) }
        if ($null -ne $open -and $open.State -eq 'open' -and $open.HeadRef -eq [string]$State['pendingBranch'] -and $open.Head -eq $Base) {
            $sha = New-GitVerifiedCommit -Setup $Setup -Parent $Base -Changes $Changes -Message ("Правки {0} от {1}" -f $script:TempBase, $stamp.ToString('dd.MM.yyyy HH:mm'))
            Set-GhBranch -Gh $Setup.Gh -Branch $open.HeadRef -Sha $sha
            $comment = New-Object System.Collections.Generic.List[string]
            $comment.Add(("Ещё правки {0} от {1} (коммит {2}) - в этот же pull request, второго не открываю." -f $script:TempBase, $stamp.ToString('dd.MM.yyyy HH:mm'), $sha))
            foreach ($line in (Get-GitChangeLines $Changes)) { $comment.Add(('- ' + $line)) }
            try { Add-GhComment -Gh $Setup.Gh -Number $open.Number -Body ($comment -join "`n") }
            catch { Write-RunLog ("git: комментарий к pull request #{0} не записан: {1}" -f $open.Number, $_.Exception.Message) }
            $State['commit'] = $sha
            $State['how'] = 'export'
            $State['pendingCommit'] = $sha
            Save-GitState $Setup $State
            Write-Line ("Дописал в открытый pull request #{0} (ветка {1}): коммит {2}. Дождись CI для новой версии PR." -f $open.Number, $open.HeadRef, (Get-GitShort $sha)) 'Green'
            return [pscustomobject]@{ Branch = $open.HeadRef; Sha = $sha; Number = $open.Number; Url = $open.Url; Continued = $true }
        }
    }
    $branchName = 'temp/' + $stamp.ToString('yyyyMMdd-HHmmss')
    # Такая ветка уже есть (две выгрузки в одну секунду) - с номером.
    for ($suffix = 2; (Get-GhHead -Gh $Setup.Gh -Branch $branchName).Sha -and $suffix -lt 20; $suffix++) {
        $branchName = 'temp/{0}-{1}' -f $stamp.ToString('yyyyMMdd-HHmmss'), $suffix
    }
    $lines = Get-GitChangeLines $Changes
    $sha = New-GitVerifiedCommit -Setup $Setup -Parent $Base -Changes $Changes -Message ("Правки {0} от {1}" -f $script:TempBase, $stamp.ToString('dd.MM.yyyy HH:mm'))
    Set-GhBranch -Gh $Setup.Gh -Branch $branchName -Sha $sha -Create
    $body = New-Object System.Collections.Generic.List[string]
    $body.Add(("Правки, сделанные прямо в {0}, - выгружены гейтом («Выгрузить temp в git»)." -f $script:TempBase))
    $body.Add('')
    $body.Add(("Основа снимка: {0}. Коммит для проверки: {1}." -f $Base, $sha))
    $body.Add('Перед слиянием проверь разницу и дождись успешных проверок CI для текущей версии PR. Если проверок нет, оставь PR открытым.')
    $body.Add('')
    foreach ($line in $lines) { $body.Add(('- ' + $line)) }
    $body.Add('')
    $body.Add('<details><summary>Файлы</summary>')
    $body.Add('')
    foreach ($change in @($Changes | Select-Object -First 200)) {
        $mark = '~'
        if ($change.Kind -eq 'add') { $mark = '+' } elseif ($change.Kind -eq 'delete') { $mark = '-' }
        $body.Add(('    {0} {1}' -f $mark, $change.Path))
    }
    if (@($Changes).Count -gt 200) { $body.Add(('    … и ещё {0}' -f (@($Changes).Count - 200))) }
    $body.Add('')
    $body.Add('</details>')
    $title = "Правки temp {0}" -f $stamp.ToString('dd.MM.yyyy HH:mm')
    if ($Note) { $title += ' (' + $Note + ')' }
    try {
        $pull = New-GhPull -Gh $Setup.Gh -Head $branchName -Base $Setup.Branch -Title $title -Body ($body -join "`n")
    }
    catch {
        throw ("Снимок {0} в ветке {1}. Создание PR в {2} не подтверждено. Проверь открытые PR этой ветки на GitHub. Ошибка: {3}" -f $sha, $branchName, $Setup.Branch, $_.Exception.Message)
    }
    $State['commit'] = $sha
    $State['how'] = 'export'
    $State['pendingBranch'] = $branchName
    $State['pendingNumber'] = $pull.Number
    $State['pendingUrl'] = $pull.Url
    $State['pendingCommit'] = $sha
    Save-GitState $Setup $State
    Write-Line ("Выгрузил: ветка {0}, коммит {1}, pull request #{2}: {3}" -f $branchName, (Get-GitShort $sha), $pull.Number, $pull.Url) 'Green'
    Write-Line ("Проверь изменения и дождись зелёного CI в PR. Затем слей его в {0} через Create a merge commit и повтори «Загрузить из git»." -f $Setup.Branch)
    return [pscustomobject]@{ Branch = $branchName; Sha = $sha; Number = $pull.Number; Url = $pull.Url; Continued = $false }
}

function Invoke-GitExport {
    # Первая и последующие выгрузки идут одним путём: снимок в новой ветке и PR.
    param($Setup, $State)
    $head = Get-GhHead -Gh $Setup.Gh -Branch $Setup.Branch
    if (-not $head.Sha) { throw ("В {0} нет ветки {1} для PR. Создай её с начальным коммитом, настрой проверки PR и повтори выгрузку." -f $Setup.Repo, $Setup.Branch) }
    $base = $head.Sha
    if ([string]$State['commit']) { $base = [string]$State['commit'] }
    $baseFiles = Get-GhFiles -Gh $Setup.Gh -Commit $base
    $tracked = Get-GitFolders $baseFiles
    $bootstrap = (@($tracked.Extensions).Count -eq 0) -and -not $tracked.HasProcessings
    if ($bootstrap) {
        $tracked = Select-GitTracked $Setup
        if ($null -eq $tracked) { Write-Line 'Отмена: ничего не выгружал.'; return }
    }
    $processingsText = 'нет'
    if ($tracked.HasProcessings) { $processingsText = 'все из справочника' }
    Write-Line ("Выгружаю из {0} в файлы: расширения {1}; обработки {2}" -f $script:TempBase, (Get-NonEmpty (@($tracked.Extensions) -join ', ') 'нет'), $processingsText) 'Cyan'
    # Колонка шагов ci.exe: выгрузки расширений видны заранее, серыми (названия - заголовки самих операций).
    Send-UiPlan -StepNames @(@($tracked.Extensions) | ForEach-Object { 'Выгрузить {0} из {1}' -f $_, $script:TempBase }) -Operations
    Initialize-GitBinaryShas -Setup $Setup -FileSets @($baseFiles)
    $snapshot = Get-TempSnapshot -Setup $Setup -Extensions $tracked.Extensions -WithProcessings:$tracked.HasProcessings
    foreach ($item in $snapshot.Missing) { Write-Line ("  в {0} нет: {1} - в git остаётся как есть" -f $script:TempBase, $item) 'Yellow' }
    # Без @(): функция возвращает массив запятой, @() завернул бы его ещё раз.
    $changes = Compare-GitSnapshot -Local $snapshot.Files -Remote $baseFiles -Prefixes $snapshot.Prefixes -Ignore (Get-GitSkippedPaths $snapshot $baseFiles)
    if ($changes.Count -eq 0) {
        Write-Line ("{0} совпадает с git (коммит {1}): выгружать нечего." -f $script:TempBase, (Get-GitShort $base)) 'Green'
        if (-not [string]$State['commit'] -and $base) { $State['commit'] = $base; $State['how'] = 'export'; Save-GitState $Setup $State }
        return
    }
    foreach ($line in (Get-GitChangeLines $changes)) { Write-Line ('  ' + $line) }
    if ($bootstrap) {
        $repoFiles = [ordered]@{ 'README.md' = (Get-GitReadme); '.gitattributes' = "* -text`n" }
        foreach ($path in $repoFiles.Keys) {
            if ($baseFiles.ContainsKey($path)) { continue }
            $file = Join-Path $Setup.Root $path
            [System.IO.File]::WriteAllText($file, $repoFiles[$path], (New-Object System.Text.UTF8Encoding($false)))
            $changes += [pscustomobject]@{ Path = $path; Kind = 'add'; File = $file; Sha = (Get-GitBlobSha ([System.IO.File]::ReadAllBytes($file))) }
        }
    }
    $answer = Confirm-Ui -Question ("Выгрузить правки {0} веткой temp/<время> и открыть pull request в {1}?" -f $script:TempBase, $Setup.Branch) -Yes 'Выгрузить' -No 'Отмена'
    if (-not $answer) { Write-Line 'Отмена: ничего не выгружал.'; return }
    $null = New-GitTempBranch -Setup $Setup -State $State -Base $base -Changes $changes
}

function Get-GitFileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join @($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}

function Write-GitKitTarget {
    # <файл или папка комплекта>.gate.json: в какой элемент справочника писать (ref) и какой sha256 у файла ждать.
    # Его читает run.ps1 (New-KitProcessing): запись - режимом regepf с ref=, файл с другим хешем не ставится.
    param([string]$Path, [string]$Ref, [string]$Folder, [string]$Sha256)
    $record = [ordered]@{ ref = $Ref; folder = $Folder; sha256 = $Sha256 }
    [System.IO.File]::WriteAllText(($Path.TrimEnd('\', '/') + '.gate.json'), (ConvertTo-Json -InputObject $record), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-GitFolderPrint {
    # Отпечаток папки: её файлы и хеши одной строкой - сравнить папку в main с тем, что в temp.
    param([hashtable]$Shas, [string]$Prefix)
    return (@($Shas.Keys | Where-Object { ([string]$_).StartsWith($Prefix, [System.StringComparison]::Ordinal) } | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $Shas[$_] }) -join "`n")
}

function Save-GitImportResult {
    # Чем кончилась загрузка - для ночного прогона (nightly.ps1) и приёмки поставок (delivery.ps1): был ли прогон
    # гейта, какой, что сказать. Outcome - коротко для программ: drift (правки temp ушли в PR), pending (PR с
    # правками temp не слит), moved (main не тот коммит, что просили), same (temp уже на main), ran (прогон был),
    # loaded (temp теперь на main), partial (загрузилось не всё), rolledback, noverdict, nostart, cancel.
    param($Setup, [bool]$Ran, [string]$Run, [int]$Code, [string]$Note, [string]$Outcome = '', [string]$Commit = '')
    $record = [ordered]@{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); ran = $Ran; run = $Run; code = $Code; note = $Note; outcome = $Outcome; commit = $Commit }
    $script:GitImportLast = [pscustomobject]$record
    [System.IO.File]::WriteAllText((Join-Path $Setup.Root 'last-import.json'), (ConvertTo-Json -InputObject $record), $Utf8Bom)
}

function Test-GitSameAsHead {
    # Правка temp совпадает с main: так бывает, когда прежняя загрузка оборвалась на середине - часть объектов уже
    # стоит в temp в версии main. Это не правка temp: её не выгружать, а догрузить остальное.
    param($Change, [hashtable]$HeadFiles)
    if ($Change.Kind -eq 'delete') { return (-not $HeadFiles.ContainsKey([string]$Change.Path)) }
    return ($HeadFiles.ContainsKey([string]$Change.Path) -and [string]$HeadFiles[[string]$Change.Path] -eq [string]$Change.Sha)
}

function Invoke-GitImport {
    # «Загрузить из git»: правили ли temp после прошлой загрузки (выгрузка и сравнение с известным коммитом), не висят
    # ли правки temp в неслитом pull request, потом - обычный прогон гейта отдельным процессом с тем, что изменилось
    # в main. Правки temp можно сохранить веткой и PR. Загрузка после слияния - при следующем запуске.
    # Комплект оставлен и загрузилось всё - temp соответствует main. Unattended - без вопросов (ночью).
    # Возвращает код прогона.
    # ExpectCommit - грузить только этот коммит (приёмка поставки: проверенный SHA); main другой - не грузить.
    param($Setup, $State, [switch]$Unattended, [string]$ExpectCommit = '')
    Save-GitImportResult -Setup $Setup -Ran $false -Run '' -Code 0 -Note 'загрузка не закончилась' -Outcome 'nostart'
    $head = Get-GhHead -Gh $Setup.Gh -Branch $Setup.Branch
    if (-not $head.Sha) { throw ("в {0} ({1}) пусто: сначала «Выгрузить temp в git»" -f $Setup.Repo, $Setup.Branch) }
    if ($ExpectCommit -and $head.Sha -ne $ExpectCommit) {
        Write-Line ("{0} сейчас на {1}, а грузить велено {2}: не гружу." -f $Setup.Branch, (Get-GitShort $head.Sha), (Get-GitShort $ExpectCommit)) 'Yellow'
        Save-GitImportResult -Setup $Setup -Ran $false -Run '' -Code 0 -Note ('main не на ' + $ExpectCommit) -Outcome 'moved' -Commit $head.Sha
        return 0
    }
    $headFiles = Get-GhFiles -Gh $Setup.Gh -Commit $head.Sha
    $known = [string]$State['commit']
    $knownFiles = $headFiles
    if ($known -and $known -ne $head.Sha) {
        try { $knownFiles = Get-GhFiles -Gh $Setup.Gh -Commit $known }
        catch { Write-Line ("  коммита {0}, которому соответствовал temp, в {1} нет: сравниваю с {2}" -f (Get-GitShort $known), $Setup.Repo, $Setup.Branch) 'Yellow'; $known = ''; $knownFiles = $headFiles }
    }
    $knownName = Get-GitShort $known
    if (-not $known) { $knownName = ('{0} ({1})' -f $Setup.Branch, (Get-GitShort $head.Sha)) }
    $tracked = Get-GitFolders $knownFiles
    $withProcessings = $tracked.HasProcessings -or (Get-GitFolders $headFiles).HasProcessings
    Write-Line ("Проверяю, не правили ли {0} после прошлой загрузки: выгружаю и сравниваю с коммитом {1}" -f $script:TempBase, $knownName) 'Cyan'
    Initialize-GitBinaryShas -Setup $Setup -FileSets @($knownFiles, $headFiles)
    $snapshot = Get-TempSnapshot -Setup $Setup -Extensions $tracked.Extensions -WithProcessings:$withProcessings
    $skippedPaths = Get-GitSkippedPaths $snapshot $knownFiles
    # manifest.json правкой temp не считается: версия и хеш обработки меняются от самой загрузки из git. В ветку с
    # правками он идёт, если правки есть.
    $drift = Compare-GitSnapshot -Local $snapshot.Files -Remote $knownFiles -Prefixes $snapshot.Prefixes -Ignore (@('processings/manifest.json') + @($skippedPaths))
    # Совпадающее с main - не правка temp, а недогруженная прежняя загрузка (раздел 5.26: обрыв после первого объекта).
    $sameAsHead = @()
    if ($drift.Count -gt 0 -and $known -and $known -ne $head.Sha) {
        $sameAsHead = @($drift | Where-Object { Test-GitSameAsHead $_ $headFiles })
        if ($sameAsHead.Count -gt 0) {
            Write-Line ("  в {0} уже как в {1} (прежняя загрузка оборвалась?): {2} - это не правки, догружаю остальное" -f $script:TempBase, $Setup.Branch, (@($sameAsHead | ForEach-Object { $_.Path } | Select-Object -First 3) -join ', ')) 'Yellow'
            $drift = @($drift | Where-Object { -not (Test-GitSameAsHead $_ $headFiles) })
        }
    }
    if ($drift.Count -gt 0) {
        $drift = Compare-GitSnapshot -Local $snapshot.Files -Remote $knownFiles -Prefixes $snapshot.Prefixes -Ignore $skippedPaths
        if ($sameAsHead.Count -gt 0) { $drift = @($drift | Where-Object { -not (Test-GitSameAsHead $_ $headFiles) }) }
    }
    # Итог сверки - на экран и когда правок нет: иначе по выводу не понять, чем кончилась проверка.
    if ($drift.Count -eq 0) { Write-Line ("  правок нет: {0} совпадает с коммитом {1}" -f $script:TempBase, $knownName) 'Green' }
    if ($drift.Count -gt 0) {
        Write-Line ("В {0} есть правки, которых нет в git (коммит {1}):" -f $script:TempBase, $knownName) 'Yellow'
        foreach ($line in (Get-GitChangeLines $drift)) { Write-Line ('  ' + $line) 'Yellow' }
        foreach ($line in (Get-GitFileLines $drift)) { Write-Line ('    ' + $line) 'Yellow' }
        $driftBase = $known
        if (-not $driftBase) { $driftBase = $head.Sha }
        $saveDrift = $true
        if (-not $Unattended) {
            $choice = Select-UiOne -Header ("В {0} правки после прошлой загрузки из git: что делать?" -f $script:TempBase) -Items @(
                'Выгрузить правки temp в git (ветка и pull request), загрузку не делать',
                ('Загрузить {0} всё равно: правки temp пропадут' -f $Setup.Branch),
                'Отмена') -Danger @(1)
            if ($choice -ne 0 -and $choice -ne 1) { Write-Line ("Отмена: {0} не трогаю." -f $script:TempBase); Save-GitImportResult -Setup $Setup -Ran $false -Run '' -Code 0 -Note 'отмена' -Outcome 'cancel'; return 0 }
            $saveDrift = $choice -eq 0
        }
        if ($saveDrift) {
            $note = ''
            if ($Unattended) { $note = 'выгружено ночью' }
            $made = New-GitTempBranch -Setup $Setup -State $State -Base $driftBase -Changes $drift -Note $note
            Save-GitImportResult -Setup $Setup -Ran $false -Run '' -Code 0 -Note ("правки temp - веткой {0}, pull request #{1}; temp не трогал" -f $made.Branch, $made.Number) -Outcome 'drift' -Commit $made.Sha
            return 0
        }
        Write-Line ("Загружаю {0} поверх правок {1}: так решили." -f $Setup.Branch, $script:TempBase) 'Yellow'
    }
    elseif ([string]$State['pendingCommit'] -and -not (Test-GhContains -Gh $Setup.Gh -Branch '' -Head $head.Sha -Commit ([string]$State['pendingCommit']))) {
        if ($Unattended) {
            Write-Line ("Правки {0} из pull request #{1} ещё не в {2}: без человека {2} не гружу." -f $script:TempBase, $State['pendingNumber'], $Setup.Branch) 'Yellow'
            Save-GitImportResult -Setup $Setup -Ran $false -Run '' -Code 0 -Note ("pull request #{0} с правками temp не слит: main не грузил" -f $State['pendingNumber']) -Outcome 'pending' -Commit $head.Sha
            return 0
        }
        $choice = Select-UiOne -Header ("Правки {0} из pull request #{1} ещё не в {2}: загрузка {2} уберёт их из temp" -f $script:TempBase, $State['pendingNumber'], $Setup.Branch) -Items @(
            ('Загрузить {0} всё равно: правки из pull request уйдут из temp' -f $Setup.Branch),
            'Отмена: сначала слить pull request') -Danger @(0) -Notes @([string]$State['pendingUrl'])
        if ($choice -ne 0) { Write-Line ("Отмена: {0} не трогаю." -f $script:TempBase); return 0 }
    }
    # Что грузить: папки main, которые не такие, как в temp (в том числе новые).
    $localShas = @{}
    foreach ($path in @($snapshot.Files.Keys)) { $localShas[$path] = Get-GitBlobSha ([System.IO.File]::ReadAllBytes($snapshot.Files[$path])) }
    $headTracked = Get-GitFolders $headFiles
    $toLoad = New-Object System.Collections.Generic.List[object]
    foreach ($name in @($headTracked.Extensions)) {
        $prefix = 'extensions/' + $name + '/'
        if ((Get-GitFolderPrint $headFiles $prefix) -ne (Get-GitFolderPrint $localShas $prefix)) { $toLoad.Add([pscustomobject]@{ Kind = 'extension'; Name = $name; Prefix = $prefix; Ref = ''; Binary = $null }) }
    }
    # Элемент справочника каждой папки - из manifest.json main: запись идёт в него (regepf с ref=), а не в первый
    # элемент с тем же именем объекта. Обработки, принятые файлом целиком, - из binaries/ (раздел 5.26).
    $manifestRefs = Get-GitManifestRefs -Setup $Setup -Files $headFiles
    $binaries = Get-GitBinaries -Setup $Setup -Files $headFiles
    foreach ($name in @($headTracked.Processings)) {
        $prefix = 'processings/' + $name + '/'
        if ($binaries.ContainsKey($name)) { continue }
        if ((Get-GitFolderPrint $headFiles $prefix) -eq (Get-GitFolderPrint $localShas $prefix)) { continue }
        $ref = ''
        if ($manifestRefs.ContainsKey($name)) { $ref = [string]$manifestRefs[$name].ref }
        # <имя>~<ссылка> - не основной элемент с этим именем объекта: без ссылки из manifest.json загрузка писала бы в
        # основной - такую не гружу.
        if ($name.Contains('~') -and -not $ref) { Write-Line ("  {0}: в {1} не такая, как в {2}, но это не основной элемент справочника с этим именем и его ссылки нет в manifest.json - не гружу" -f $prefix.TrimEnd('/'), $Setup.Branch, $script:TempBase) 'Yellow'; continue }
        # Помеченный на удаление элемент не обновляется: запись в него - не то, что ждут от правки в git.
        if ($name.Contains('~') -and [bool](Get-UiField $manifestRefs[$name] 'deleted' $false)) { Write-Line ("  {0}: в {1} не такая, как в {2}, но это не основной элемент справочника с этим именем, он помечен на удаление - не гружу" -f $prefix.TrimEnd('/'), $Setup.Branch, $script:TempBase) 'Yellow'; continue }
        $toLoad.Add([pscustomobject]@{ Kind = 'processing'; Name = $name; Prefix = $prefix; Ref = $ref; Binary = $null })
    }
    foreach ($name in @($binaries.Keys | Sort-Object)) {
        $entry = $binaries[$name]
        $wanted = ([string]$entry.sha256).ToLowerInvariant()
        $ref = [string]$entry.ref
        if (-not $ref -and $manifestRefs.ContainsKey($name)) { $ref = [string]$manifestRefs[$name].ref }
        # Уже стоит - только если этот файл в той самой карточке (по ссылке; новая - по имени объекта), а не где-то в
        # справочнике: у одноимённых карточек может быть тот же файл.
        $inTemp = @($snapshot.Processings | Where-Object {
                ([string]$_.Hash).Replace('-', '').ToLowerInvariant() -eq $wanted -and $(if ($ref) { [string]$_.Ref -eq $ref } else { [string]$_.ObjName -eq [string]$entry.objectName }) })
        if ($inTemp.Count -gt 0) { continue }
        $toLoad.Add([pscustomobject]@{ Kind = 'binary'; Name = $name; Prefix = ('binaries/' + $name + '/'); Ref = $ref; Binary = $entry })
    }
    foreach ($name in @($tracked.Extensions | Where-Object { @($headTracked.Extensions) -notcontains $_ })) { Write-Line ("  в {0} больше нет расширения {1}: из {2} не убираю" -f $Setup.Branch, $name, $script:TempBase) 'Yellow' }
    foreach ($name in @($tracked.Processings | Where-Object { @($headTracked.Processings) -notcontains $_ })) { Write-Line ("  в {0} больше нет обработки {1}: из {2} не убираю" -f $Setup.Branch, $name, $script:TempBase) 'Yellow' }
    # Действия после обновления (раздел 5.24) - actions/*.bsl в main. В прогон идут все: выполненные обработка
    # пропускает по регистру. Прогон только ради действий - если есть файлы, которых нет среди выполненных в temp.
    $actionFiles = @(@($headFiles.Keys) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^actions/[^/]+\.bsl$' } | Sort-Object)
    $doneIds = @($State['actionsDone'])
    $newActions = @($actionFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } | Where-Object { $doneIds -notcontains $_ })
    if ($toLoad.Count -eq 0 -and $newActions.Count -eq 0) {
        Write-Line ("{0} уже совпадает с {1} (коммит {2}): загружать нечего." -f $script:TempBase, $Setup.Branch, (Get-GitShort $head.Sha)) 'Green'
        Set-GitLoaded -Setup $Setup -State $State -Commit $head.Sha -Run ''
        Save-GitImportResult -Setup $Setup -Ran $false -Run '' -Code 0 -Note ('temp уже на ' + $Setup.Branch) -Outcome 'same' -Commit $head.Sha
        return 0
    }
    $whatList = @($toLoad | ForEach-Object { if ($_.Kind -eq 'extension') { 'расширение ' + $_.Name } elseif ($_.Kind -eq 'binary') { 'обработка файлом целиком ' + $_.Name } else { 'обработка ' + $_.Name } })
    if ($newActions.Count -gt 0) { $whatList += ('действия после обновления ({0}): {1}' -f $newActions.Count, ($newActions -join ', ')) }
    $what = $whatList -join ', '
    # Что изменит загрузка - на экран до вопроса: файлы main против того, что в temp сейчас. Вопрос после ответа с
    # экрана уходит, а по выводу должно быть видно, что и почему грузилось.
    $incoming = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $toLoad) {
        foreach ($path in @($headFiles.Keys)) {
            if (-not ([string]$path).StartsWith($entry.Prefix, [System.StringComparison]::Ordinal)) { continue }
            if (-not $localShas.ContainsKey($path)) { $incoming.Add([pscustomobject]@{ Path = [string]$path; Kind = 'add' }) }
            elseif ([string]$localShas[$path] -ne [string]$headFiles[$path]) { $incoming.Add([pscustomobject]@{ Path = [string]$path; Kind = 'change' }) }
        }
        foreach ($path in @($localShas.Keys)) {
            if (([string]$path).StartsWith($entry.Prefix, [System.StringComparison]::Ordinal) -and -not $headFiles.ContainsKey($path)) { $incoming.Add([pscustomobject]@{ Path = [string]$path; Kind = 'delete' }) }
        }
    }
    foreach ($id in $newActions) { $incoming.Add([pscustomobject]@{ Path = ('actions/{0}.bsl' -f $id); Kind = 'add' }) }
    Write-Line ("Загрузка изменит в {0} ({1}, коммит {2}, против того, что в базе сейчас):" -f $script:TempBase, $Setup.Branch, (Get-GitShort $head.Sha)) 'Cyan'
    foreach ($line in (Get-GitChangeLines $incoming)) { Write-Line ('  ' + $line) }
    foreach ($line in (Get-GitFileLines $incoming)) { Write-Line ('    ' + $line) }
    if ($Unattended) { Write-Line ("Загружаю в {0} из {1} (коммит {2}): {3}" -f $script:TempBase, $Setup.Branch, (Get-GitShort $head.Sha), $what) 'Cyan' }
    else {
        $answer = Confirm-Ui -Question ("Загрузить в {0} из {1} (коммит {2}): {3} - прогоном гейта?" -f $script:TempBase, $Setup.Branch, (Get-GitShort $head.Sha), $what) -Yes 'Загрузить' -No 'Отмена'
        if (-not $answer) { Write-Line ("Отмена: {0} не трогаю." -f $script:TempBase); return 0 }
    }

    # Комплект: выгрузки изменившихся папок из main, каждая - своей папкой (гейт сам видит, что в ней), и действия -
    # папкой actions. Только действия - комплекта нет, прогон с -ActionsDir.
    $kitName = 'kit-{0}-{1}' -f (Get-GitShort $head.Sha), (Get-Date -Format 'yyyyMMdd-HHmmss')
    if ($toLoad.Count -eq 0) { $kitName = 'actions-{0}-{1}' -f (Get-GitShort $head.Sha), (Get-Date -Format 'yyyyMMdd-HHmmss') }
    $source = Join-Path $Setup.Root ($kitName + '-src')
    $kitDir = Join-Path $Setup.Root $kitName
    $prefixes = @($toLoad | ForEach-Object { $_.Prefix })
    if ($actionFiles.Count -gt 0) { $prefixes += 'actions/' }
    $count = Save-GhFiles -Gh $Setup.Gh -Commit $head.Sha -Prefixes $prefixes -Target $source -Expected $headFiles
    Write-RunLog ("git: из {0} скачано файлов {1} в {2}" -f (Get-GitShort $head.Sha), $count, $source)
    New-Item -ItemType Directory -Path $kitDir -Force | Out-Null
    foreach ($entry in $toLoad) {
        if ($entry.Kind -eq 'binary') {
            # Файл целиком: в корень комплекта под своим именем, рядом - что за элемент и какой sha256 ждём.
            $fileName = [string]$entry.Binary.file
            $from = Join-Path (Join-Path (Join-Path $source 'binaries') $entry.Name) $fileName
            $target = Join-Path $kitDir $fileName
            if (Test-Path -LiteralPath $target) { throw ("в комплекте два файла {0}: переименуй один в binaries/manifest.json" -f $fileName) }
            Move-Item -LiteralPath $from -Destination $target
            $actual = Get-GitFileSha256 $target
            if ($actual -ne ([string]$entry.Binary.sha256).ToLowerInvariant()) { throw ("binaries/{0}/{1}: sha256 {2}, а в manifest.json {3} - не гружу" -f $entry.Name, $fileName, $actual, $entry.Binary.sha256) }
            Write-GitKitTarget -Path $target -Ref $entry.Ref -Folder $entry.Name -Sha256 $actual
            continue
        }
        $folder = 'extensions'
        $target = Join-Path $kitDir $entry.Name
        if ($entry.Kind -eq 'processing') {
            $folder = 'processings'
            if (Test-Path -LiteralPath $target) { $target = Join-Path $kitDir ('epf_' + $entry.Name) }
        }
        Move-Item -LiteralPath (Join-Path (Join-Path $source $folder) $entry.Name) -Destination $target
        if ($entry.Kind -eq 'processing' -and $entry.Ref) { Write-GitKitTarget -Path $target -Ref $entry.Ref -Folder $entry.Name -Sha256 '' }
    }
    $actionsDir = ''
    if ($actionFiles.Count -gt 0) {
        $actionsDir = Join-Path $kitDir 'actions'
        New-Item -ItemType Directory -Path $actionsDir -Force | Out-Null
        foreach ($path in $actionFiles) { Move-Item -LiteralPath (Join-Path (Join-Path $source 'actions') ($path.Substring(8))) -Destination $actionsDir }
    }
    Remove-Item -LiteralPath $source -Recurse -Force

    # Прогон гейта - отдельным процессом (у run.ps1 свои trap и exit). Start-Process без перенаправления: процесс
    # пишет прямо в ту же консоль или в тот же канал ci.exe, вопросы задаёт сам. «& powershell.exe» внутри функции
    # забрал бы весь вывод в её результат - хода прогона не было бы видно.
    $quote = { param([string]$Text) '"' + $Text.Replace('"', '\"') + '"' }
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $quote (Join-Path $Root 'run.ps1')))
    if ($toLoad.Count -gt 0) { $runArgs += @('-Kit', (& $quote $kitDir)) }
    else { $runArgs += @('-ActionsDir', (& $quote $actionsDir)) }
    $runArgs += @('-KitSource', (& $quote ("git {0}@{1}" -f $Setup.Repo, [string]$head.Sha)), '-KitBranch', (& $quote $Setup.Branch))
    if ($Config) { $runArgs += @('-Config', (& $quote $Config)) }
    if ($UiChannel) { $runArgs += @('-UiChannel', (& $quote $UiChannel)) }
    # Без человека - как ночной прогон: вопросов нет, комплект остаётся (temp идёт за main, красное видно в итоге).
    if ($Unattended) {
        if ($toLoad.Count -gt 0) { $runArgs += @('-OnNotGreen', 'Keep') }
        $runArgs += @('-OnSessions', 'Continue')
    }
    $before = @{}
    if (Test-Path -LiteralPath $runsRoot) { foreach ($dir in @(Get-ChildItem -LiteralPath $runsRoot -Directory)) { $before[$dir.Name] = $true } }
    if ($toLoad.Count -gt 0) { Write-Line ("Прогон гейта с комплектом из git: {0}" -f $kitDir) 'Cyan' }
    else { Write-Line ("Прогон гейта с действиями после обновления из git: {0}" -f $actionsDir) 'Cyan' }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList ($runArgs -join ' ') -NoNewWindow -PassThru
    $null = $process.Handle
    $process.WaitForExit()
    $runCode = $process.ExitCode
    $fresh = @()
    if (Test-Path -LiteralPath $runsRoot) { $fresh = @(Get-ChildItem -LiteralPath $runsRoot -Directory | Where-Object { -not $before.ContainsKey($_.Name) -and $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name | Select-Object -Last 1) }
    if ($fresh.Count -eq 0) {
        Write-Line 'Прогон не начался: temp не трогал, состояние git не меняю.' 'Yellow'
        Save-GitImportResult -Setup $Setup -Ran $false -Run '' -Code $runCode -Note 'прогон гейта с комплектом из git не начался' -Outcome 'nostart' -Commit $head.Sha
        return $runCode
    }
    Save-GitImportResult -Setup $Setup -Ran $true -Run $fresh[0].Name -Code $runCode -Note ('загрузка из git, коммит ' + (Get-GitShort $head.Sha)) -Outcome 'ran' -Commit $head.Sha
    # Выполненные действия - в состояние при любом исходе: откат комплекта данных не возвращает, а выполненное
    # обработка всё равно не повторит. Упавшее и невыполненное - нет: следующая загрузка запустит их снова.
    $actionsResult = Join-Path $fresh[0].FullName 'actions.txt'
    $failedActions = @()
    if (Test-Path -LiteralPath $actionsResult) {
        $rows = @([System.IO.File]::ReadAllLines($actionsResult, [System.Text.Encoding]::UTF8) | ForEach-Object { $_.TrimStart([char]0xFEFF) } | Where-Object { $_.StartsWith('action=') })
        $doneNow = @($rows | ForEach-Object { $parts = $_.Substring(7).Split([char[]]@('|'), 3); if ($parts.Length -gt 1 -and ($parts[1] -eq 'done' -or $parts[1] -eq 'already')) { $parts[0] } })
        $failedActions = @($rows | ForEach-Object { $parts = $_.Substring(7).Split([char[]]@('|'), 3); if ($parts.Length -lt 2 -or ($parts[1] -ne 'done' -and $parts[1] -ne 'already')) { $parts[0] } })
        $knownDone = @($State['actionsDone'])
        $added = @($doneNow | Where-Object { $knownDone -notcontains $_ })
        if ($added.Count -gt 0) {
            $State['actionsDone'] = @(@($knownDone + $added) | Sort-Object -Unique)
            Save-GitState $Setup $State
        }
    }
    if ($newActions.Count -gt 0 -and -not (Test-Path -LiteralPath $actionsResult)) { $failedActions = $newActions }
    if ($failedActions.Count -gt 0) { Write-Line ("Действия после обновления не выполнены: {0} - следующая загрузка из git запустит их снова." -f ($failedActions -join ', ')) 'Yellow' }
    if ($toLoad.Count -eq 0) {
        # Только действия: расширения и обработки temp и так на main.
        Set-GitLoaded -Setup $Setup -State $State -Commit $head.Sha -Run $fresh[0].Name
        Save-GitImportResult -Setup $Setup -Ran $true -Run $fresh[0].Name -Code $runCode -Note 'только действия после обновления' -Outcome 'loaded' -Commit $head.Sha
        if ($failedActions.Count -eq 0) { Write-Line ("{0} на {1}, коммит {2}: действия после обновления выполнены (прогон {3})." -f $script:TempBase, $Setup.Branch, (Get-GitShort $head.Sha), $fresh[0].Name) 'Green' }
        return $runCode
    }
    $verdictFile = Join-Path $fresh[0].FullName 'verdict.json'
    if (-not (Test-Path -LiteralPath $verdictFile)) {
        Write-Line ("Прогон {0} без итога: состояние git не меняю, temp смотреть по прогону." -f $fresh[0].Name) 'Yellow'
        Save-GitImportResult -Setup $Setup -Ran $true -Run $fresh[0].Name -Code $runCode -Note 'прогон без итога' -Outcome 'noverdict' -Commit $head.Sha
        return $runCode
    }
    $result = [System.IO.File]::ReadAllText($verdictFile, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $decision = [string]$result.kitDecision
    # temp на main - только если загрузилось всё, что грузили: каждое расширение загружено и обновлено, каждая
    # обработка собрана и записана (loaded), и итог - этого прогона. Пропущенное после ошибки - тоже не загружено.
    $loadedItems = @(@($result.kitItems) + @($result.kitProcessings) | Where-Object { $null -ne $_ })
    $notLoaded = @($loadedItems | Where-Object { $null -eq $_.PSObject.Properties['loaded'] -or -not $_.loaded } | ForEach-Object { [string]$_.name })
    if ($loadedItems.Count -lt $toLoad.Count) { $notLoaded += ('в прогоне элементов {0} из {1}' -f $loadedItems.Count, $toLoad.Count) }
    $verdictRun = ''
    if ($null -ne $result.PSObject.Properties['runId']) { $verdictRun = [string]$result.runId }
    if ($verdictRun -ne $fresh[0].Name) { $notLoaded += ('итог другого прогона ({0})' -f $verdictRun) }
    if ($decision -eq 'rolledBack' -or $decision -eq 'rollbackFailed') {
        Write-Line ("Комплект из git откачен (прогон {0}): {1} - как до загрузки, состояние git не меняю." -f $fresh[0].Name, $script:TempBase) 'Yellow'
        Save-GitImportResult -Setup $Setup -Ran $true -Run $fresh[0].Name -Code $runCode -Note ('откат: ' + $decision) -Outcome 'rolledback' -Commit $head.Sha
    }
    elseif ($notLoaded.Count -gt 0) {
        Write-Line ("Загрузилось не всё ({0}): {1} не соответствует {2}, состояние git не меняю." -f ($notLoaded -join ', '), $script:TempBase, $Setup.Branch) 'Yellow'
        Save-GitImportResult -Setup $Setup -Ran $true -Run $fresh[0].Name -Code $runCode -Note ('загрузилось не всё: ' + ($notLoaded -join ', ')) -Outcome 'partial' -Commit $head.Sha
    }
    else {
        Set-GitLoaded -Setup $Setup -State $State -Commit $head.Sha -Run $fresh[0].Name
        Write-Line ("{0} теперь на {1}, коммит {2} (прогон {3}, вердикт {4})." -f $script:TempBase, $Setup.Branch, (Get-GitShort $head.Sha), $fresh[0].Name, $result.verdict) 'Green'
        Save-GitImportResult -Setup $Setup -Ran $true -Run $fresh[0].Name -Code $runCode -Note ('загрузка из git, коммит ' + (Get-GitShort $head.Sha)) -Outcome 'loaded' -Commit $head.Sha
    }
    return $runCode
}

function Get-GitProdReadme {
    # PROD.md ветки prod: что в ней и откуда. Без даты: иначе каждый снимок был бы «с правками».
    return (@(
            '# Ветка prod: что стоит в рабочей базе',
            '',
            ('Пишет только гейт («Снимок внешних обработок рабочей в git», deploy.ps1 -GitProd). Рабочую базу {0} он только читает' -f $script:ProdBase),
            ('(внешнее соединение, запрос к справочнику «Дополнительные отчёты и обработки»), в файлы выгружает конфигуратор тестовой базы {0}.' -f $script:TempBase),
            'Руками и агентами здесь ничего не правят.',
            '',
            '- `processings/` - внешние обработки, отчёты и печатные формы рабочей базы, раскладка как в `main`; `processings/manifest.json` - что за элементом каждой папки.',
            '- Расширений рабочей базы здесь пока нет.',
            '',
            'Разница с тестовой базой - сравнение веток `main...prod` на GitHub, папка `processings/`.'
        ) -join "`n") + "`n"
}

function Invoke-GitProdSnapshot {
    # Снимок внешних обработок рабочей в ветку prod: все элементы справочника (только чтение), выгрузка в файлы
    # конфигуратором temp, manifest.json, PROD.md. Ветки prod нет - создаётся от main без расширений. Main не трогает.
    param($Setup)
    $prodBranch = [string](Get-Setting $cfg 'ExtensionsProdBranch' 'prod')
    if ($prodBranch -eq 'main') { throw 'Для снимков рабочей укажи отдельную ветку в ExtensionsProdBranch (например, prod).' }
    if ($prodBranch -eq $Setup.Branch) { throw ("ExtensionsProdBranch и ExtensionsBranch - одна ветка ({0}): снимок рабочей затёр бы то, что должно стоять в temp" -f $prodBranch) }
    $main = Get-GhHead -Gh $Setup.Gh -Branch $Setup.Branch
    if (-not $main.Sha) { throw ("в {0} ({1}) пусто: сначала «Выгрузить temp в git»" -f $Setup.Repo, $Setup.Branch) }
    $prod = Get-GhHead -Gh $Setup.Gh -Branch $prodBranch
    $base = $prod.Sha
    if (-not $base) { $base = $main.Sha }
    $baseFiles = Get-GhFiles -Gh $Setup.Gh -Commit $base
    Write-Line ("Читаю внешние обработки {0} (только чтение) и выгружаю в файлы конфигуратором {1}" -f $script:ProdBase, $script:TempBase) 'Cyan'
    $files = @{}
    $work = Join-Path $Setup.Root 'work-prod'
    $taken = Add-GitProcessingSnapshot -Files $files -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword `
        -Root (Join-Path $work 'processings') -EpfDir (Join-Path $script:RunDir 'epf-prod') -Source 'рабочей'
    $readme = Join-Path $work 'PROD.md'
    [System.IO.File]::WriteAllText($readme, (Get-GitProdReadme), (New-Object System.Text.UTF8Encoding($false)))
    $files['PROD.md'] = $readme
    # Первый снимок - от main: расширений temp в ветке рабочей быть не должно.
    $prefixes = @('processings/', 'PROD.md')
    if (-not $prod.Sha) { $prefixes += 'extensions/' }
    $changes = Compare-GitSnapshot -Local $files -Remote $baseFiles -Prefixes $prefixes
    $withFile = @($taken.Items | Where-Object { $_.File }).Count
    Write-Line ("  в справочнике {0}: элементов {1}, с файлом {2}, помечены на удаление {3}" -f $script:ProdBase, @($taken.Items).Count, $withFile, @($taken.Items | Where-Object { $_.Deleted }).Count)
    if ($changes.Count -eq 0) {
        Write-Line ("Обработки {0} - те же, что в ветке {1} (коммит {2}): записывать нечего." -f $script:ProdBase, $prodBranch, (Get-GitShort $base)) 'Green'
        return
    }
    foreach ($line in (Get-GitChangeLines $changes)) { Write-Line ('  ' + $line) }
    $where = 'обновить ветку {0}' -f $prodBranch
    if (-not $prod.Sha) { $where = 'создать ветку {0} от {1} (без расширений)' -f $prodBranch, $Setup.Branch }
    $answer = Confirm-Ui -Question ("Записать снимок обработок {0} в git: {1}?" -f $script:ProdBase, $where) -Yes 'Записать' -No 'Отмена'
    if (-not $answer) { Write-Line 'Отмена: в git ничего не писал.'; return }
    $sha = New-GitVerifiedCommit -Setup $Setup -Parent $base -Changes $changes -Message ("Снимок внешних обработок {0} от {1}" -f $script:ProdBase, (Get-Date).ToString('dd.MM.yyyy HH:mm'))
    if ($prod.Sha) { Set-GhBranch -Gh $Setup.Gh -Branch $prodBranch -Sha $sha }
    else { Set-GhBranch -Gh $Setup.Gh -Branch $prodBranch -Sha $sha -Create }
    Write-Line ("Записал в {0} ({1}): коммит {2}. Разница с temp: https://github.com/{0}/compare/{3}...{1}" -f $Setup.Repo, $prodBranch, (Get-GitShort $sha), $Setup.Branch) 'Green'
}

function Get-ComConfigInfo {
    # Имя, синоним и версия основной конфигурации базы - внешним соединением (только чтение). Не вышло - Ok = $false.
    param([string]$BaseName, [string]$User, [string]$Password)
    $reader = {
        param([string]$Line, [string]$FakeScript, [string]$FakeFile)
        if ($FakeScript) { . $FakeScript; $connector = New-FakeComConnector $FakeFile }
        else { $connector = New-Object -ComObject V83.COMConnector }
        $connection = $null
        try {
            try { $connection = $connector.Connect($Line) }
            catch {
                $connectError = $_.Exception
                while ($null -ne $connectError.InnerException) { $connectError = $connectError.InnerException }
                throw ([string]$connectError.Message)
            }
            # Свойства - поздним связыванием (IDispatch), мимо PowerShell: у объектов 1С нет описания типов, и PowerShell
            # их свойства иногда не видит - отдаёт $null без ошибки (20.11.2026 так пришли пустые имя и версия типовой).
            # Подставной COM тестов - обычные объекты PowerShell.
            $get = {
                param($Object, [string]$Name)
                if ($null -eq $Object) { throw ("нет объекта, у которого брать «{0}»" -f $Name) }
                if (-not [Runtime.InteropServices.Marshal]::IsComObject($Object)) { return , ($Object.$Name) }
                $comType = [type]::GetType('System.__ComObject')
                if ($null -eq $comType) { $comType = $Object.GetType() }
                try { return , ($comType.InvokeMember($Name, [System.Reflection.BindingFlags]::GetProperty, $null, $Object, $null)) }
                catch {
                    $memberError = $_.Exception
                    while ($null -ne $memberError.InnerException) { $memberError = $memberError.InnerException }
                    throw ("{0}: {1}" -f $Name, [string]$memberError.Message)
                }
            }
            $metadata = & $get $connection 'Metadata'
            # Массивом: Invoke-UiBackground берёт у результата .PSObject.BaseObject, а у одиночного pscustomobject
            # там голый объект без свойств.
            return , @([pscustomobject]@{ Name = [string](& $get $metadata 'Name'); Synonym = [string](& $get $metadata 'Synonym'); Version = [string](& $get $metadata 'Version') })
        }
        finally {
            foreach ($comObject in @($connection, $connector)) {
                if ($null -ne $comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
            }
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
        }
    }
    $call = Invoke-UiBackground -Script $reader -Arguments @((Get-ComConnectionLine $BaseName $User $Password), $script:FakeComScript, [string]$env:CI_FAKE_COM) `
        -Title ("Версия конфигурации {0}" -f $BaseName) -TimeoutSec $comTimeoutSec
    $message = $call.Error
    if ($Password -and $message) { $message = $message.Replace($Password, '***') }
    if (-not $call.Ok -or $null -eq $call.Result) {
        if (-not $message) { $message = 'внешнее соединение ничего не вернуло' }
        return [pscustomobject]@{ Ok = $false; Error = $message; Name = ''; Synonym = ''; Version = '' }
    }
    $info = @($call.Result)[0]
    $name = [string]$info.Name
    $version = [string]$info.Version
    # Пустые имя или версия - не прочитал, а не «версия пустая»: с пустой версией сравнение «та же, что в прошлый раз»
    # совпало бы и после обновления типовой.
    if (-not $name -or -not $version) {
        return [pscustomobject]@{ Ok = $false; Error = ("внешнее соединение вернуло пустые имя или версию конфигурации (имя «{0}», версия «{1}»)" -f $name, $version); Name = ''; Synonym = ''; Version = '' }
    }
    return [pscustomobject]@{ Ok = $true; Error = ''; Name = $name; Synonym = [string]$info.Synonym; Version = $version }
}

function Update-TypicalDump {
    # Основная конфигурация temp в файлы (без -Extension): есть прежняя выгрузка - только изменения (-update),
    # не вышло или нет её - целиком.
    param([string]$Dir)
    $timeout = 60 * [int](Get-Setting $cfg 'TypicalDumpTimeoutMin' 180)
    $hasDump = Test-Path -LiteralPath (Join-Path $Dir 'ConfigDumpInfo.xml')
    $command = @('/DumpConfigToFiles', ('"{0}"' -f $Dir))
    if ($hasDump) { $command += '-update' }
    else {
        if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force }
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $result = Invoke-Designer -BaseName $script:TempBase -Command $command -LogName 'dump_typical.log' -TimeoutSec $timeout -Title ("Выгрузить типовую {0} в файлы" -f $script:TempBase)
    if ($result.ExitCode -ne 0 -and $hasDump -and -not $result.TimedOut) {
        Remove-Item -LiteralPath $Dir -Recurse -Force
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $result = Invoke-Designer -BaseName $script:TempBase -Command @('/DumpConfigToFiles', ('"{0}"' -f $Dir)) -LogName 'dump_typical.log' -TimeoutSec $timeout -Title ("Выгрузить типовую {0} в файлы целиком" -f $script:TempBase)
    }
    if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $Dir 'Configuration.xml'))) {
        throw ("типовая {0} в файлы не выгрузилась (код {1}): {2}" -f $script:TempBase, $result.ExitCode, $result.Text)
    }
}

function Get-TypicalReadme {
    param($Info, [string[]]$Big, [string]$ExtensionsRepo)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('# Типовая конфигурация {0} ({1}), версия {2}' -f $Info.Synonym, $Info.Name, $Info.Version))
    $lines.Add('')
    $lines.Add(('Выгрузка основной конфигурации тестовой базы {0} в файлы (конфигуратор, «Выгрузить конфигурацию в файлы»). Пишет только гейт:' -f $script:TempBase))
    $lines.Add('при «Выгрузить temp в git», когда версия конфигурации в тестовой базе изменилась (после обновления типовой).')
    $lines.Add('')
    $where = 'в расширениях'
    if ($ExtensionsRepo) { $where = 'в расширениях (репозиторий `{0}`)' -f $ExtensionsRepo }
    $lines.Add(('**Только для чтения.** Типовую не меняем: правки - {0}. Отсюда в базу ничего не загружается: типовая обновляется' -f $where))
    $lines.Add('файлом обновления от 1С (.cfu). Pull request сюда не принимаются.')
    $lines.Add('')
    $lines.Add('- `ConfigDumpInfo.xml` не хранится.')
    if (@($Big).Count -gt 0) {
        $lines.Add('- Файлы больше 50 МБ не хранятся (ограничение GitHub):')
        foreach ($path in @($Big)) { $lines.Add(('  - `{0}`' -f $path)) }
    }
    else { $lines.Add('- Файлов больше 50 МБ нет: выгрузка целиком.') }
    $lines.Add('')
    $lines.Add('История версий - история коммитов: разница двух коммитов - что поменялось в типовой при обновлении.')
    return ($lines -join "`n") + "`n"
}

function Invoke-GitTypical {
    # Типовая temp - в репозиторий TypicalRepo портативным git (через REST сотня тысяч файлов не пролезает). Версия
    # та же, что в прошлый раз, - ничего не делает; иначе вопрос, выгрузка в файлы, коммит поверх ветки, push.
    # Репозиторий git - отдельно от выгрузки (repo.git): конфигуратор может стереть выгрузку и выгрузить заново.
    $repo = [string](Get-Setting $cfg 'TypicalRepo' '')
    if (-not $repo) { return }
    if ($repo -eq [string](Get-Setting $cfg 'ExtensionsRepo' '')) { throw 'TypicalRepo совпадает с ExtensionsRepo. Для выгрузки типовой нужен отдельный репозиторий.' }
    $branch = [string](Get-Setting $cfg 'TypicalBranch' 'main')
    if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw ("TypicalRepo «{0}» - не в виде владелец/имя" -f $repo) }
    $typicalRoot = Join-Path (Resolve-RootPath ([string](Get-Setting $cfg 'GitDir' 'git'))) ($repo.Split('/')[1])
    New-Item -ItemType Directory -Path $typicalRoot -Force | Out-Null
    $statePath = Join-Path $typicalRoot 'typical.json'
    $state = [ordered]@{ repo = $repo; name = ''; version = ''; commit = ''; time = '' }
    if (Test-Path -LiteralPath $statePath) {
        try {
            $read = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            foreach ($name in @($state.Keys)) { if ($null -ne $read.PSObject.Properties[$name]) { $state[$name] = [string]$read.$name } }
        }
        catch { Write-RunLog ("git: {0} не прочитан: {1}" -f $statePath, $_.Exception.Message) }
    }
    if ($state['repo'] -ne $repo) { $state['version'] = ''; $state['commit'] = ''; $state['repo'] = $repo }
    Write-Host ''
    Write-Line ("Типовая {0} - в {1}: смотрю версию" -f $script:TempBase, $repo) 'Cyan'
    $info = Get-ComConfigInfo -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword
    if (-not $info.Ok) { Write-Line ("  версию конфигурации {0} не прочитал: {1}. Типовую не выгружаю." -f $script:TempBase, $info.Error) 'Yellow'; return }
    $title = '{0} ({1}) {2}' -f $info.Synonym, $info.Name, $info.Version
    if (-not $state['version'] -and $state['commit']) {
        # Коммит есть, а версии при нём нет: до 20.11.2026 версия могла прочитаться пустой (свойства COM 1С), выгрузка
        # и коммит при этом прошли. Версию того коммита - из его Configuration.xml (repo.git цел, даже если выгрузку
        # удалили): та же, что в temp, - дописываю её, выгрузку не повторяю. Другая или не прочиталась (temp могли
        # обновить после того запуска) - обычный путь: вопрос и выгрузка.
        $committed = ''
        $gitDir = Join-Path $typicalRoot 'repo.git'
        if (Test-Path -LiteralPath (Join-Path $gitDir 'HEAD')) {
            $git = Get-PortableGit -ToolsDir (Resolve-RootPath 'tools') -Exe ([string](Get-Setting $cfg 'GitExe' ''))
            $show = Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $typicalRoot -Arguments @('show', ($state['commit'] + ':Configuration.xml')) -AllowFail
            if ($show.ExitCode -eq 0 -and $show.Output -match '<Version>([^<]*)</Version>') { $committed = $Matches[1].Trim() }
        }
        if ($committed -and $committed -eq $info.Version) {
            $state['name'] = $info.Name
            $state['version'] = $info.Version
            $state['time'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            [System.IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $state), $Utf8Bom)
            Write-Line ("  типовая {0}: в {1} коммит {2} записан без версии, в нём та же версия - дописал её, выгружать нечего." -f $title, $repo, (Get-GitShort $state['commit'])) 'Green'
            return
        }
        $seen = $committed
        if (-not $seen) { $seen = 'не прочитал' }
        Write-Line ("  в {0} коммит {1} записан без версии; версия в нём - {2}, в {3} - {4}: выгружаю как новую." -f $repo, (Get-GitShort $state['commit']), $seen, $script:TempBase, $info.Version) 'Yellow'
    }
    if ($state['version'] -eq $info.Version -and $state['commit']) {
        Write-Line ("  типовая {0} уже в {1} (коммит {2}): выгружать нечего." -f $title, $repo, (Get-GitShort $state['commit'])) 'Green'
        return
    }
    $question = "Выгрузить и типовую {0} в {1} (только для чтения агентами)? Первый раз долго: выгрузка в файлы и отправка около гигабайта, порядка часа." -f $title, $repo
    if ($state['version']) { $question = "Типовая в {0} обновилась: {1} -> {2}. Выгрузить новую версию в {3}?" -f $script:TempBase, $state['version'], $info.Version, $repo }
    $answer = Confirm-Ui -Question $question -Yes 'Выгрузить' -No 'Не сейчас'
    if (-not $answer) { Write-Line '  типовую не выгружаю: спрошу в следующий раз.'; return }
    # Токен - до выгрузки: выгрузка в файлы идёт долго, и без токена она пропала бы зря.
    $tokenFile = [string](Get-Setting $cfg 'GitHubTokenPassFile' '')
    if (-not $tokenFile) { throw 'нет токена GitHub: «Настройки - Обновление гейта и git», GitHubTokenPassFile' }
    $token = ([string](Get-PlainPassword $tokenFile)).Trim()
    $url = 'https://github.com/{0}.git' -f $repo
    if ($env:CI_FAKE_GIT_REMOTE) { $url = [string]$env:CI_FAKE_GIT_REMOTE; $token = '' }
    $git = Get-PortableGit -ToolsDir (Resolve-RootPath 'tools') -Exe ([string](Get-Setting $cfg 'GitExe' ''))
    Write-Line ("  git: {0}" -f $git)
    $dump = Join-Path $typicalRoot 'dump'
    # Место: выгрузка ERP в файлы - гигабайты и сотня тысяч файлов, плюс объекты git. Не хватит - не начинаю, иначе
    # кончится место на диске машины гейта (было: выгрузка вручную съела диск целиком).
    $hasDump = Test-Path -LiteralPath (Join-Path $dump 'ConfigDumpInfo.xml')
    $needGb = [double](Get-Setting $cfg 'TypicalMinFreeGB' 12)
    if ($hasDump) { $needGb = [Math]::Max(2, $needGb / 4) }
    $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($typicalRoot)))
    $freeGb = [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    if ($freeGb -lt $needGb) {
        Write-Line ("  на диске {0} свободно {1} ГБ, а выгрузке типовой нужно не меньше {2} ГБ (настройка TypicalMinFreeGB): не выгружаю. Освободи место или перенеси GitDir на другой диск." -f $drive.Name, $freeGb, $needGb) 'Yellow'
        return
    }
    Write-Line ("  выгружаю типовую {0} в файлы: {1} (первый раз - надолго; на диске {2} свободно {3} ГБ)" -f $script:TempBase, $dump, $drive.Name, $freeGb)
    # Колонка шагов ci.exe: весь путь типовой виден заранее. Названия - заголовки операций ниже; шаг, которого не
    # было (коммит уже сделан прошлым запуском), останется «не выполнялся».
    Send-UiPlan -Operations -StepNames @(
        ('Выгрузить типовую {0} в файлы' -f $script:TempBase), 'Типовая: git fetch (что сейчас в GitHub)', 'Типовая: git add (файлы - в pack)',
        'Типовая: git commit', 'Типовая: git repack (сжать объекты перед отправкой)', 'Типовая: git push (отправка в GitHub)')
    Update-TypicalDump -Dir $dump
    # Конфигуратор может оставить повреждённый XML даже при наличии Configuration.xml.
    # Прочитать потоками до записи git-индекса. Пути с # и % передавать как файлы, а не URI.
    $xmlSettings = New-Object System.Xml.XmlReaderSettings
    $xmlSettings.XmlResolver = $null
    try {
        Get-ChildItem -LiteralPath $dump -Filter '*.xml' -Recurse -File -ErrorAction Stop | ForEach-Object {
            $xmlFile = $_.FullName
            $stream = [System.IO.File]::OpenRead($xmlFile)
            $reader = $null
            try {
                $reader = [System.Xml.XmlReader]::Create($stream, $xmlSettings)
                while ($reader.Read()) { }
            }
            catch { throw ("Не удалось прочитать XML выгрузки типовой {0}: {1}" -f $xmlFile, $_.Exception.Message) }
            finally {
                if ($null -ne $reader) { $reader.Dispose() }
                $stream.Dispose()
            }
        }
    }
    catch {
        $marker = Join-Path $dump 'ConfigDumpInfo.xml'
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction Stop }
        throw
    }
    # Больше 50 МБ GitHub не любит (больше 100 МБ - не примет): такие файлы - мимо git, их список - в README.
    $dumpFull = [System.IO.Path]::GetFullPath($dump).TrimEnd('\', '/')
    $big = @(Get-ChildItem -LiteralPath $dump -Recurse -File | Where-Object { $_.Length -gt 50MB } | ForEach-Object { $_.FullName.Substring($dumpFull.Length + 1).Replace('\', '/') } | Sort-Object)
    [System.IO.File]::WriteAllText((Join-Path $dump 'README.md'), (Get-TypicalReadme -Info $info -Big $big -ExtensionsRepo ([string](Get-Setting $cfg 'ExtensionsRepo' ''))), (New-Object System.Text.UTF8Encoding($false)))
    $gitDir = Join-Path $typicalRoot 'repo.git'
    if (-not (Test-Path -LiteralPath (Join-Path $gitDir 'HEAD'))) { $null = Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments @('init', '--quiet') }
    $exclude = Join-Path (Join-Path $gitDir 'info') 'exclude'
    New-Item -ItemType Directory -Path (Split-Path -Parent $exclude) -Force | Out-Null
    [System.IO.File]::WriteAllText($exclude, ((@('# Пишет гейт: служебный файл конфигуратора и файлы больше 50 МБ.', '/ConfigDumpInfo.xml') + @($big | ForEach-Object { '/' + $_ })) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
    # Коммит - поверх того, что сейчас в ветке на GitHub (её могли двигать не отсюда); пустой репозиторий - первый коммит.
    $fetch = Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments @('fetch', '--depth', '1', '--no-tags', $url, $branch) -Token $token -TimeoutSec 3600 -AllowFail -Title 'Типовая: git fetch (что сейчас в GitHub)'
    if ($fetch.ExitCode -eq 0) {
        $remoteSha = (Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments @('rev-parse', 'FETCH_HEAD')).Output.Trim()
        $null = Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments @('update-ref', 'HEAD', $remoteSha)
    }
    elseif ($fetch.Output -notmatch "couldn't find remote ref") { throw ("git fetch из {0}: {1}" -f $repo, (@($fetch.Output -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 2) -join ' | ')) }
    # index.lock от оборванного git (таймаут, остановка, снятый процесс): с ним «git add» не начинается. Убирается,
    # только если с этим репозиторием сейчас не работает другой git.
    $indexLock = Join-Path $gitDir 'index.lock'
    if (Test-Path -LiteralPath $indexLock) {
        $busy = @()
        try { $busy = @(Get-CimInstance Win32_Process -Filter "name='git.exe'" -ErrorAction Stop | Where-Object { ([string]$_.CommandLine).Contains($gitDir) }) } catch { $busy = @() }
        if ($busy.Count -gt 0) { throw ("с репозиторием типовой уже работает другой git (процесс {0}): дождись его или сними" -f $busy[0].ProcessId) }
        Remove-Item -LiteralPath $indexLock -Force
        Write-Line '  убрал index.lock от прошлого оборванного запуска'
    }
    # Файлы - сразу в один pack, а не объект на файл (core.bigFileThreshold=1: «большим» считается любой файл, такие
    # git пишет в pack потоком). Объект на файл - это двести тысяч мелких файлов в repo.git, и каждый проверяет
    # антивирус при записи и при чтении: первая выгрузка 19.11.2026 упаковывала их часами. В таком pack нет
    # дельта-сжатия - его делает пережатие перед первой отправкой (ниже), уже из одного файла.
    Write-Line '  складываю в git: сотня тысяч файлов - в первый раз десятки минут'
    $null = Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments @('add', '-A') -TimeoutSec 14400 -Title 'Типовая: git add (файлы - в pack)' -Config @('core.bigFileThreshold=1')
    $staged = Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments @('diff', '--cached', '--quiet') -AllowFail
    $hasHead = ((Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD') -AllowFail).ExitCode -eq 0)
    if ($staged.ExitCode -eq 0 -and $fetch.ExitCode -eq 0) {
        $state['commit'] = (Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments @('rev-parse', 'HEAD')).Output.Trim()
        Write-Line ("  в {0} уже ровно это: коммит {1}" -f $repo, (Get-GitShort $state['commit'])) 'Green'
    }
    else {
        if ($staged.ExitCode -eq 0 -and $hasHead) {
            # Коммит сделан прошлым запуском, который оборвался до отправки (таймаут, остановка): второй раз
            # коммитить нечего («nothing to commit»), остаётся отправить.
            Write-Line '  коммит уже сделан прошлым запуском: остаётся отправить'
        }
        else {
            $messageFile = Join-Path $typicalRoot 'commit-message.txt'
            [System.IO.File]::WriteAllText($messageFile, ("Типовая {0} из {1}`n`nВыгрузка в файлы конфигуратором, {2}. Файлов больше 50 МБ мимо git: {3}.`n" -f $title, $script:TempBase, (Get-Date).ToString('dd.MM.yyyy HH:mm'), @($big).Count), (New-Object System.Text.UTF8Encoding($false)))
            $null = Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments @('commit', '--quiet', '--no-verify', '-F', $messageFile) -TimeoutSec 7200 -Title 'Типовая: git commit'
        }
        # Упаковка - до отправки: всё в один pack, отправка берёт его готовым. Первая отправка (в хранилище ещё пусто) -
        # с пересчётом дельта-сжатия (-f): после add оно не делалось, без него pack втрое больше. Дальше - без -f:
        # пересчитывать всю типовую ради нескольких тысяч изменённых файлов незачем. Не вышло - отправка упакует сама.
        $repackArgs = @('repack', '-a', '-d', '-q')
        if ($fetch.ExitCode -ne 0) { $repackArgs = @('repack', '-a', '-d', '-f', '-q') }
        $null = Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments $repackArgs -TimeoutSec 14400 -AllowFail -Title 'Типовая: git repack (сжать объекты перед отправкой)'
        Write-Line ("  отправляю в {0} (ветка {1}; первый раз - надолго)" -f $repo, $branch)
        $null = Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments @('push', '--no-verify', $url, ('HEAD:refs/heads/' + $branch)) -Token $token -TimeoutSec 14400 -Title 'Типовая: git push (отправка в GitHub)'
        $state['commit'] = (Invoke-GitCli -Git $git -GitDir $gitDir -WorkTree $dump -Arguments @('rev-parse', 'HEAD')).Output.Trim()
        Write-Line ("Типовая {0} - в {1}: коммит {2}, https://github.com/{1}" -f $title, $repo, (Get-GitShort $state['commit'])) 'Green'
    }
    if (@($big).Count -gt 0) { Write-Line ("  мимо git (больше 50 МБ): {0}" -f (@($big) -join ', ')) 'Yellow' }
    # Место после: выгрузку - долой, если не держим (объекты git уже сжаты перед отправкой).
    if (-not [bool](Get-Setting $cfg 'TypicalKeepDump' $false)) {
        Remove-Item -LiteralPath $dump -Recurse -Force -ErrorAction SilentlyContinue
        Write-Line '  выгрузку в файлы удалил (TypicalKeepDump выключен): следующая версия выгрузится целиком'
    }
    $state['name'] = $info.Name
    $state['version'] = $info.Version
    $state['time'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    [System.IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $state), $Utf8Bom)
}

function Set-GitLoaded {
    # Temp соответствует коммиту Commit; pull request с правками temp, если он уже в main, больше не ждём.
    param($Setup, $State, [string]$Commit, [string]$Run)
    $State['commit'] = $Commit
    $State['how'] = 'load'
    $State['run'] = $Run
    if ([string]$State['pendingCommit'] -and (Test-GhContains -Gh $Setup.Gh -Branch '' -Head $Commit -Commit ([string]$State['pendingCommit']))) {
        foreach ($name in @('pendingBranch', 'pendingUrl', 'pendingCommit')) { $State[$name] = '' }
        $State['pendingNumber'] = 0
    }
    Save-GitState $Setup $State
}

if ($Delivery) {
    # Приёмка поставок (раздел 5.26): свой файл, подключается точкой - пользуется функциями git этого скрипта.
    if (-not $DeliveryUnattended -and -not (Test-UiCanAsk)) { throw 'приёмку поставок с вопросами - из консоли или ci.exe; без человека - deploy.ps1 -Delivery -DeliveryUnattended' }
    . (Join-Path $Root 'github.ps1')
    . (Join-Path $Root 'delivery.ps1')
    $deliveryCode = Invoke-Delivery -Unattended:$DeliveryUnattended -OnlyId $DeliveryId
    exit $deliveryCode
}

if ($GitExport -or $GitImport -or $GitProd -or $GitTypical) {
    if (-not $GitUnattended -and -not (Test-UiCanAsk)) { throw 'выгрузить в git и загрузить из git можно только из консоли или ci.exe (без человека - deploy.ps1 -GitImport -GitUnattended)' }
    if ($GitUnattended -and ($GitProd -or $GitTypical)) { throw 'снимок рабочей и типовую в git без человека пока не выгружаю: запусти из меню' }
    if ($GitUnattended -and $GitExport) { throw 'выгрузка в git без человека не бывает: первую выгрузку и выбор делает человек' }
    . (Join-Path $Root 'github.ps1')
    if ($GitTypical) {
        Invoke-GitTypical
        exit 0
    }
    $gitSetup = Get-GitSetup
    $gitState = Read-GitState $gitSetup
    Write-Host ''
    if ($GitProd) {
        Write-Host ("СНИМОК ВНЕШНИХ ОБРАБОТОК {0} В GIT ({1}, ветка {2})" -f $script:ProdBase, $gitSetup.Repo, [string](Get-Setting $cfg 'ExtensionsProdBranch' 'prod')) -ForegroundColor Cyan
        Invoke-GitProdSnapshot -Setup $gitSetup
        exit 0
    }
    if ($GitExport) {
        Write-Host ("ВЫГРУЗИТЬ {0} В GIT ({1}, {2})" -f $script:TempBase, $gitSetup.Repo, $gitSetup.Branch) -ForegroundColor Cyan
        Invoke-GitExport -Setup $gitSetup -State $gitState
        # Типовая - туда же, если задан TypicalRepo и её версия изменилась (после обновления типовой).
        Invoke-GitTypical
        exit 0
    }
    Write-Host ("ЗАГРУЗИТЬ ИЗ GIT В {0} ({1}, {2})" -f $script:TempBase, $gitSetup.Repo, $gitSetup.Branch) -ForegroundColor Cyan
    $gitCode = Invoke-GitImport -Setup $gitSetup -State $gitState -Unattended:$GitUnattended -ExpectCommit $GitCommit
    exit $gitCode
}

#endregion

#region Подготовленное обновление рабочей

# Обновление в два приёма. «Подготовить» (-Prepare): резервные копии, взять из temp и загрузить новые версии
# расширений в конфигурацию рабочей базы - без обновления конфигурации БД, без блокировок и без завершения сеансов:
# пользователи работают на прежних, применённых версиях. «Обновить подготовленным» (-ApplyPrepared): сеансы,
# блокировки, обновление конфигурации БД, внешние обработки, проверки, отчёт. «Отменить подготовку»
# (-CancelPrepared): конфигурации расширений рабочей возвращаются к применённым. Что подготовлено - в
# deploy\prepared.json (пути полные); файлы - в папке запуска подготовки. Пока подготовка есть, одним проходом
# и откатом рабочую не трогаем: резервная копия сняла бы загруженную, а не применённую версию.
if (@(@($Prepare, $ApplyPrepared, $CancelPrepared, $Rollback) | Where-Object { $_ }).Count -gt 1) { throw 'ключи -Prepare, -ApplyPrepared, -CancelPrepared и -Rollback - по одному за запуск' }
$preparedPath = Join-Path $deployRoot 'prepared.json'
$preparedRunId = ''
$preparedWhen = ''

function Read-PreparedState {
    # Подготовленное обновление рабочей или $null, если его нет.
    if (-not (Test-Path -LiteralPath $preparedPath)) { return $null }
    try {
        $state = [System.IO.File]::ReadAllText($preparedPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
        if (-not $state -or -not $state.PSObject.Properties['base']) { throw 'отсутствует запись о базе' }
        return $state
    }
    catch { throw ("подготовленное обновление не читается ({0}): {1}" -f $preparedPath, $_.Exception.Message) }
}

function Get-PreparedItems {
    # Расширения подготовки для отмены: Name, Status, Backup (полный путь или пусто).
    param($State)
    foreach ($item in @(Get-JsonValue $State 'extensions' @())) {
        [pscustomobject]@{ Name = [string](Get-JsonValue $item 'name' ''); Status = [string](Get-JsonValue $item 'status' ''); Backup = [string](Get-JsonValue $item 'backup' '') }
    }
}

function Get-PreparedText {
    # «Адаптация (1.0 -> 2.0), Доработки (3 -> 4)»
    param($State)
    $parts = @(foreach ($item in @(Get-JsonValue $State 'extensions' @())) {
            '{0} ({1} -> {2})' -f (Get-JsonValue $item 'name' ''), (Get-NonEmpty ([string](Get-JsonValue $item 'oldVersion' '')) 'нет'), (Get-NonEmpty ([string](Get-JsonValue $item 'newVersion' '')) '?')
        })
    return ($parts -join ', ')
}

function Get-PreparedRollbackFailedText {
    # Применение подготовки откатилось не полностью (#10): что вернулось, что нет и что делать. Пусто - не было.
    param($State)
    $failure = Get-JsonValue $State 'rollbackFailed' $null
    if ($null -eq $failure) { return '' }
    $items = @(Get-JsonValue $failure 'items' @()) -join '; '
    if (-not $items) { $items = 'по элементам - в журнале запуска' }
    return ("откат обновления подготовленным {0} (запуск {1}) прошёл не полностью: {2}. Рабочая частично на новых версиях, новые изменения не начинаю. Восстановить - «Откатить рабочую базу» (вернутся объекты с копией), журнал - deploy\{1}" -f $script:ProdBase, (Get-JsonValue $failure 'run' '?'), $items)
}

function Set-PreparedRollbackFailed {
    # Неполный откат обновления подготовленным: prepared.json остаётся и получает отметку с итогом по элементам.
    param([string[]]$Items)
    $state = Read-PreparedState
    if ($null -eq $state) { return }
    $state | Add-Member -NotePropertyName rollbackFailed -NotePropertyValue ([ordered]@{ run = (Split-Path -Leaf $script:RunDir); at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); items = @($Items) }) -Force
    $next = $preparedPath + '.tmp'
    [System.IO.File]::WriteAllText($next, (ConvertTo-Json -InputObject $state -Depth 6), $Utf8Bom)
    [System.IO.File]::Replace($next, $preparedPath, [System.Management.Automation.Language.NullString]::Value)
    Write-RunLog ("Подготовка отмечена: откат прошёл не полностью ({0})" -f (@($Items) -join '; '))
}

function Get-PreparedBusyText {
    param([string]$What, $State)
    $failedText = Get-PreparedRollbackFailedText $State
    if ($failedText) { return ("{0} сейчас нельзя: {1}" -f $What, $failedText) }
    return ("{0} сейчас нельзя: есть подготовленное обновление от {1} ({2}) - в конфигурацию {3} загружены новые версии, не применённые. Сначала «Обновить рабочую подготовленным» или «Отменить подготовку»." -f $What, (Get-JsonValue $State 'timeText' '?'), (Get-PreparedText $State), $script:ProdBase)
}

function Save-PreparedState {
    # deploy\prepared.json: что загружено в конфигурацию рабочей и не применено. Хеш рабочей читается после
    # загрузки: по нему «Обновить подготовленным» увидит, что рабочую с тех пор меняли.
    param([object[]]$Entries, [bool]$Partial, $TempStates, [string]$GateRun, [bool]$ReadProd = $true)
    # ReadProd = $false - не читать: до загрузки хеш ещё не тот, а когда внешнее соединение не отвечает,
    # каждая попытка - минута ожидания впустую.
    $prodNow = $null
    if ($ReadProd) { $prodNow = Get-ExtensionStates -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword }
    $items = @(foreach ($entry in $Entries) {
            $oldVersion = [string]$entry.ProdVersion
            if (-not $oldVersion -and $entry.OldDir -and (Test-Path -LiteralPath $entry.OldDir)) { $oldVersion = [string](Get-ExtensionVersion $entry.OldDir) }
            $newVersion = [string]$entry.TempVersion
            if (-not $newVersion -and $entry.NewDir -and (Test-Path -LiteralPath $entry.NewDir)) { $newVersion = [string](Get-ExtensionVersion $entry.NewDir) }
            $tempHash = ''
            if ($null -ne $TempStates -and $TempStates.Ok -and $TempStates.Items.ContainsKey($entry.Name)) { $tempHash = [string]$TempStates.Items[$entry.Name].Hash }
            $prodHash = ''
            if ($null -ne $prodNow -and $prodNow.Ok -and $prodNow.Items.ContainsKey($entry.Name)) { $prodHash = [string]$prodNow.Items[$entry.Name].Hash }
            [ordered]@{ name = [string]$entry.Name; status = [string]$entry.Status; oldVersion = $oldVersion; newVersion = $newVersion
                backup = [string]$entry.Backup; newFile = [string]$entry.NewFile; oldDir = [string]$entry.OldDir; newDir = [string]$entry.NewDir
                tempHash = $tempHash; prodHash = $prodHash }
        })
    $state = [ordered]@{
        runId      = $runId
        timeText   = (Get-Date).ToString('dd.MM.yyyy HH:mm')
        base       = $script:ProdBase
        target     = $deployTarget.Identity
        tempBase   = $script:TempBase
        user       = $env:USERNAME
        partial    = $Partial
        gate       = $GateRun
        extensions = $items
    }
    $next = $preparedPath + '.tmp'
    [System.IO.File]::WriteAllText($next, (ConvertTo-Json -InputObject $state -Depth 5), $Utf8Bom)
    if ([System.IO.File]::Exists($preparedPath)) { [System.IO.File]::Replace($next, $preparedPath, [System.Management.Automation.Language.NullString]::Value) }
    else { [System.IO.File]::Move($next, $preparedPath) }
    Write-RunLog ("Подготовка записана: {0}" -f $preparedPath)
}

function Undo-PreparedExtensions {
    # Возвращает конфигурации расширений рабочей к применённым версиям, в обратном порядке: загружается резервная
    # копия, снятая до загрузки (она и есть применённая версия). Новое расширение (в рабочей его не было)
    # удаляется по имени. Конфигурация БД не обновляется, блокировки и сеансы не трогаются. Items - записи
    # с Name, Status, Backup. Команды - только те, что и при обновлении: «возврат к конфигурации БД»
    # (/RollbackCfg) для расширения на рабочей не проверен и здесь не используется.
    param([object[]]$Items)
    $ok = $true
    $list = @($Items)
    [array]::Reverse($list)
    foreach ($item in $list) {
        $name = [string]$item.Name
        $backup = [string]$item.Backup
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/LoadCfg', ('"{0}"' -f $backup), '-Extension', $name) `
                -LogName ("unprepare_load_{0}.log" -f $name) -TimeoutSec $timeoutLoadSec -Title ("Отмена подготовки: вернуть {0} из резервной копии" -f $name)
        }
        elseif ([string]$item.Status -eq 'new' -and -not $backup) {
            # Удаляется одно расширение по имени. Ключа -AllExtensions здесь нет.
            $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/DeleteCfg', '-Extension', $name) `
                -LogName ("unprepare_delete_{0}.log" -f $name) -TimeoutSec $timeoutLoadSec -Title ("Отмена подготовки: удалить новое {0}" -f $name)
            if ($result.ExitCode -ne 0) {
                # Загрузка могла не успеть: расширения в рабочей нет - удалять нечего.
                $existing = Get-ExtensionStates -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
                if ($existing.Ok -and -not $existing.Items.ContainsKey($name)) {
                    Write-Line ("  {0}: в {1} его нет - удалять нечего" -f $name, $script:ProdBase) 'Green'
                    continue
                }
            }
        }
        else {
            Write-Line ("  {0}: резервной копии нет ({1}) - вернуть нечем" -f $name, $backup) 'Red'
            $ok = $false
            continue
        }
        if ($result.ExitCode -eq 0 -and -not $backup) { Write-Line ("  {0}: удалено - до подготовки его в рабочей не было" -f $name) 'Green' }
        elseif ($result.ExitCode -eq 0) { Write-Line ("  {0}: возвращено к применённой версии" -f $name) 'Green' }
        else { Write-Line ("  {0}: вернуть не получилось - {1}" -f $name, $result.Text) 'Red'; $ok = $false }
    }
    return $ok
}

function Assert-DeployRecordTarget {
    param($Record, [string]$Identity, [string]$Path)
    if ([string](Get-JsonValue $Record 'base' '') -ine $script:ProdBase) {
        throw ("Другая база: запись {0} не соответствует ProdBase текущего профиля." -f $Path)
    }
    $saved = [string](Get-JsonValue $Record 'target' '')
    if (-not $saved) {
        # Запись сделал гейт прежней версии: идентификатора кластера и ИБ в ней нет, сверить можно только имя базы.
        # Отказ сделал бы недоступным штатный откат всех прежних обновлений, поэтому решает человек; без человека -
        # отказ, как и был.
        $sure = $null
        if (Test-UiCanAsk) {
            $sure = Confirm-Ui -Question ("В записи {0} нет идентификатора кластера и базы: её сделал гейт прежней версии. Она относится к {1}\{2}?" -f $Path, $script:Server, $script:ProdBase) -Yes 'Да, к этой базе' -No 'Нет, выйти'
        }
        if ($sure -ne $true) {
            throw ("В записи {0} нет идентификатора кластера и ИБ, и подтверждения, что она относится к {1}\{2}, нет. Ничего не менял." -f $Path, $script:Server, $script:ProdBase)
        }
        Write-RunLog ("Запись {0} без идентификатора цели: человек подтвердил, что она относится к {1}\{2}" -f $Path, $script:Server, $script:ProdBase)
        return
    }
    if ($saved -cne $Identity) { throw ("Кластер или ИБ текущего профиля не совпадает с целью в {0}." -f $Path) }
}

$writeRun = (-not $StatusOnly -or $Prepare -or $ApplyPrepared -or $CancelPrepared -or $Rollback)
$deployGuard = $null
if ($writeRun) {
    try { $deployGuard = [System.IO.File]::Open((Join-Path $deployRoot 'deploy.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw ("Не получил исключительный доступ к каталогу обновлений {0}. Проверь права и другие запуски deploy." -f $deployRoot) }
}
try {
$prepared = Read-PreparedState
$deployTarget = $null
if ($writeRun -and (-not $CancelPrepared -or $null -ne $prepared)) {
    $deployLink = Connect-ClusterAgent
    $deployTarget = Get-BaseInfo $deployLink $script:ProdBase $script:ProdUser $script:ProdPassword
    if ($null -ne $prepared) { Assert-DeployRecordTarget $prepared $deployTarget.Identity $preparedPath }
    if (-not $CancelPrepared) { $null = Get-BaseInfo $deployLink $script:TempBase $script:TempUser $script:TempPassword }
}

if ($CancelPrepared) {
    if (-not (Test-UiCanAsk)) { throw 'отмена подготовки только из консоли или ci.exe' }
    if ($null -eq $prepared) { Write-Line ("Подготовленного обновления {0} нет: отменять нечего." -f $script:ProdBase); exit 0 }
    # Отмена грузит копии в конфигурацию без обновления БД: после неполного отката это не восстановление (#10).
    $failedText = Get-PreparedRollbackFailedText $prepared
    if ($failedText) { throw $failedText }
    Write-Host ''
    Write-Line ("ОТМЕНА ПОДГОТОВКИ {0}" -f $script:ProdBase) 'Cyan'
    Write-Line ("  подготовлено {0}: {1}" -f (Get-JsonValue $prepared 'timeText' '?'), (Get-PreparedText $prepared))
    $sure = Confirm-Ui -Question ("Вернуть расширения {0} к применённым версиям? В конфигурацию рабочей загрузятся резервные копии, снятые до подготовки; база данных, блокировки и сеансы не затрагиваются." -f $script:ProdBase) -Yes 'Да, отменить подготовку' -No 'Нет, выйти'
    if ($sure -ne $true) { Write-Host 'Выход, ничего не менял.'; exit 0 }
    if (Undo-PreparedExtensions -Items @(Get-PreparedItems $prepared)) {
        Remove-Item -LiteralPath $preparedPath -Force
        Write-Line ("ИТОГ: подготовка отменена, расширения {0} - как применены." -f $script:ProdBase) 'Green'
        exit 0
    }
    Write-Line ("ИТОГ: подготовка отменена не полностью (см. выше). {0} оставлен: повтори отмену." -f $preparedPath) 'Red'
    exit 1
}

# ** Хлебников С.Ю. 20261120 Журнал обновления (#29). deploy.json пишется с outcome = inProgress до первой записи
# в рабочую и переписывается после каждого шага объекта (stage: pending, backup, loading, loaded, applying, applied;
# у обработок writing, written) - заменой файла целиком, так что на диске всегда целый JSON. Процесс погиб
# (окно закрыли, машина перезагрузилась) - при следующем запуске deploy журнал разбирается: что успело, сверка
# рабочей по хеш-суммам (только чтение), запись становится «прервано» и попадает в список откатов.
function Save-DeployJournalFile {
    param([string]$Path, $Record)
    $temp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Record -Depth 6), $Utf8Bom)
    # [NullString]::Value - без резервной копии: $null PowerShell передал бы пустой строкой.
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [System.IO.File]::Move($temp, $Path) }
}

function Save-DeployJournal {
    # Журнал этого запуска: что выбрано, стадия каждого объекта, резервные копии, хеш-суммы до и после.
    param([string]$Step = '')
    if (-not $script:JournalOn) { return $true }
    $journal = [ordered]@{
        runId = $runId; time = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); base = $script:ProdBase; tempBase = $script:TempBase
        user = $env:USERNAME; mode = $mode; outcome = 'inProgress'; step = $Step; rollbackOf = $rollbackOf
        pid = $PID; processStart = $script:JournalProcessStart
        gate = $script:JournalGate; riskAccepted = $riskAccepted; risks = @($gateRisks); riskReason = $riskReason
        extensions = @(foreach ($journalEntry in $selected) {
                $journalBackup = ''
                if ($journalEntry.Backup) { $journalBackup = 'before\' + (Split-Path -Leaf $journalEntry.Backup) }
                [ordered]@{ name = $journalEntry.Name; status = $journalEntry.Status; backup = $journalBackup; oldVersion = $journalEntry.ProdVersion; newVersion = $journalEntry.TempVersion
                    stage = [string]$journalEntry.Stage; oldHash = [string]$journalEntry.OldHash; newHash = [string]$journalEntry.NewHash }
            })
        processings = @(foreach ($journalProc in $selectedProcessings) {
                $journalProcBackup = ''
                if ((Get-JsonValue $journalProc 'Backup' '')) { $journalProcBackup = 'before\processings\' + (Split-Path -Leaf ([string]$journalProc.Backup)) }
                # Снятая обработка (unregister): её файл - для отката, как в итоговой записи.
                $journalProcFile = ''
                if ((Get-JsonValue $journalProc 'RemovedFile' '')) { $journalProcFile = 'before\processings\' + (Split-Path -Leaf ([string]$journalProc.RemovedFile)) }
                [ordered]@{ name = $journalProc.ObjName; fileName = [string](Get-JsonValue $journalProc 'FileName' ''); action = [string](Get-JsonValue $journalProc 'Action' '')
                    ref = [string](Get-JsonValue $journalProc 'Ref' ''); isNew = [string](Get-JsonValue $journalProc 'IsNew' ''); backup = $journalProcBackup; file = $journalProcFile
                    oldVersion = [string](Get-JsonValue $journalProc 'ProdVersion' ''); newVersion = [string](Get-JsonValue $journalProc 'TempVersion' ''); stage = [string](Get-JsonValue $journalProc 'Stage' 'pending') }
            })
        light = @(); article = ''
    }
    try { Save-DeployJournalFile -Path (Join-Path $script:RunDir 'deploy.json') -Record $journal; return $true }
    catch {
        # Без записанного журнала следующий шаг в рабочую не начинается: после обрыва восстановление его не увидит.
        Write-Line ('[FAIL] Журнал обновления не записался: ' + $_.Exception.Message) 'Red'
        Write-RunLog ('Журнал обновления не записался: ' + $_.Exception.Message)
        return $false
    }
}

function Set-DeployStage {
    # $false - журнал не записался: следующий шаг в рабочую делать нельзя.
    param($Item, [string]$Stage)
    $Item | Add-Member -NotePropertyName Stage -NotePropertyValue $Stage -Force
    return (Save-DeployJournal -Step $Stage)
}

function Resolve-InterruptedDeploys {
    # Журналы inProgress, чей процесс уже не живёт: разбор, сверка рабочей (только чтение), outcome = interrupted.
    # Возвращает, сколько нашлось.
    if (-not (Test-Path -LiteralPath $deployRoot)) { return 0 }
    $found = 0
    foreach ($dir in @(Get-ChildItem -LiteralPath $deployRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name)) {
        $jsonFile = Join-Path $dir.FullName 'deploy.json'
        if (-not (Test-Path -LiteralPath $jsonFile)) { continue }
        $record = $null
        try { $record = (Get-Content -LiteralPath $jsonFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { continue }
        if ([string](Get-JsonValue $record 'outcome' '') -ne 'inProgress') { continue }
        if ([string](Get-JsonValue $record 'base' '') -ne $script:ProdBase) { continue }
        $journalPid = [int](Get-JsonValue $record 'pid' 0)
        $alive = $null
        if ($journalPid -gt 0) { $alive = Get-Process -Id $journalPid -ErrorAction SilentlyContinue }
        if ($null -ne $alive) {
            $startText = ''
            try { $startText = $alive.StartTime.ToString('yyyy-MM-ddTHH:mm:ss') } catch { $startText = '' }
            if (-not $startText -or $startText -eq [string](Get-JsonValue $record 'processStart' '')) {
                throw ("обновление {0} {1} ещё идёт (процесс {2}): дождись его конца" -f $script:ProdBase, $dir.Name, $journalPid)
            }
        }
        $found++
        $lines = New-Object System.Collections.Generic.List[string]
        $prodNow = Get-ExtensionStates -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
        $stageNames = @{ pending = 'не начиналось'; backup = 'резервная копия снята, загрузки не было'; loading = 'шла загрузка'; loaded = 'загружено'; applying = 'шло обновление конфигурации БД'; applied = 'применено'; writing = 'шла запись'; written = 'записана' }
        foreach ($item in @(Get-JsonValue $record 'extensions' @())) {
            $stage = [string](Get-JsonValue $item 'stage' 'pending')
            $stageText = $stage
            if ($stageNames.ContainsKey($stage)) { $stageText = $stageNames[$stage] }
            $nowText = 'сверить не удалось: хеш-сумма рабочей не прочитана'
            if ($prodNow.Ok -and $prodNow.Items.ContainsKey([string]$item.name)) {
                $nowHash = [string]$prodNow.Items[[string]$item.name].Hash
                if ($nowHash -and $nowHash -eq [string](Get-JsonValue $item 'newHash' '')) { $nowText = 'в конфигурации рабочей новая версия (применена ли к БД - по журналу)' }
                elseif ($nowHash -and $nowHash -eq [string](Get-JsonValue $item 'oldHash' '')) { $nowText = 'в рабочей прежняя версия' }
                else { $nowText = 'исход неизвестен: хеш-сумма ни прежняя, ни новая' }
            }
            elseif ($prodNow.Ok) { $nowText = 'в рабочей его нет' }
            $backupText = 'копии нет - откатом не вернуть'
            if ([string](Get-JsonValue $item 'backup' '') -and (Test-Path -LiteralPath (Join-Path $dir.FullName ([string]$item.backup)))) { $backupText = 'копия есть' }
            $lines.Add(("{0}: {1}; {2}; {3}" -f $item.name, $stageText, $nowText, $backupText))
        }
        foreach ($item in @(Get-JsonValue $record 'processings' @())) {
            $stage = [string](Get-JsonValue $item 'stage' 'pending')
            $stageText = $stage
            if ($stageNames.ContainsKey($stage)) { $stageText = $stageNames[$stage] }
            # Запись оборвалась: прежняя версия обработка «Выполнить после обновления» сохраняет в epf\<имя>\old.b64
            # до изменения справочника - она и есть копия для отката.
            if ($stage -eq 'writing' -and -not [string](Get-JsonValue $item 'backup' '')) {
                $sessionOld = Join-Path (Join-Path (Join-Path $dir.FullName 'epf') ([string]$item.name)) 'old.b64'
                if (Test-Path -LiteralPath $sessionOld) {
                    $recoveredDir = Join-Path $dir.FullName 'before\processings'
                    New-Item -ItemType Directory -Path $recoveredDir -Force | Out-Null
                    Copy-Item -LiteralPath $sessionOld -Destination (Join-Path $recoveredDir ([string]$item.name + '.b64')) -Force
                    $item | Add-Member -NotePropertyName backup -NotePropertyValue ('before\processings\' + [string]$item.name + '.b64') -Force
                }
            }
            $backupText = 'копии нет - откатом не вернуть, проверить карточку руками'
            if ([string](Get-JsonValue $item 'backup' '')) { $backupText = 'копия есть' }
            if ($stage -eq 'writing') { $stageText = 'исход неизвестен (запись шла)' }
            $lines.Add(("обработка {0}: {1}; {2}" -f $item.name, $stageText, $backupText))
        }
        $record.outcome = 'interrupted'
        $record | Add-Member -NotePropertyName interruptCheck -NotePropertyValue @($lines.ToArray()) -Force
        $record | Add-Member -NotePropertyName interruptFoundAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')) -Force
        Save-DeployJournalFile -Path $jsonFile -Record $record
        Write-RunLog ("Прерванное обновление {0}: {1}" -f $dir.Name, ($lines -join ' | '))
        $more = @($lines.ToArray()) + @(
            'Блокировки, которые ставил этот запуск, - выше, отдельным вопросом; остальные - «Состояние баз» и консоль кластера.',
            'Откатить то, что успело, - «Откатить рабочую базу»: это обновление в списке с пометкой ПРЕРВАНО (вернутся только объекты с копией).',
            'Проверить рабочую - «Проверить рабочую базу (только читает)».')
        Show-UiTitle -Text ("Обновление {0} {1} прервано (процесс не закончил)" -f $script:ProdBase, $dir.Name) -Kind 'bad' -More $more
    }
    return $found
}
# ** Хлебников С.Ю. 20261120 конец

if (-not $Prepare -and -not $CancelPrepared) {
    $lockedBefore = Resolve-InterruptedLocks -ReadOnly:(-not $writeRun)
    $interrupted = Resolve-InterruptedDeploys
    if (($interrupted -gt 0 -or $lockedBefore -gt 0) -and -not $Rollback) {
        Write-Line 'Сначала - разобраться с прерванным обновлением (см. выше). Выход, ничего не менял.' 'Yellow'
        exit 0
    }
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
    # После неполного отката обновления подготовленным откат - и есть восстановление: он разрешён (#10).
    if ($null -ne $prepared -and -not (Get-PreparedRollbackFailedText $prepared)) { throw (Get-PreparedBusyText 'Откат' $prepared) }
    $ciLines = New-Object System.Collections.Generic.List[string]
    $advice = New-Object System.Collections.Generic.List[object]
    $gateRisks = New-Object System.Collections.Generic.List[string]
    $gateRedItems = New-Object System.Collections.Generic.List[string]
    $lastRun = $null
    $lastVerdict = $null
    $riskAccepted = $false
    $gateRed = $false
    $riskReason = ''
    $checkedNote = ''

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

    Assert-DeployRecordTarget $target $deployTarget.Identity $target.Dir

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
                $candidateVerdict = (Get-Content -LiteralPath $verdictFile -Raw -Encoding UTF8) | ConvertFrom-Json
                # Каталог прогонов общий на несколько тестовых баз: прогон другой базы - не про этот temp (#7).
                $candidateBase = [string](Get-JsonValue $candidateVerdict 'baseKey' '')
                if ($candidateBase -and $script:TempBase -and $candidateBase -ine $script:TempBase) {
                    Write-RunLog ("Прогон {0} - базы {1}, а temp - {2}: не берётся" -f $candidate.Name, $candidateBase, $script:TempBase)
                    continue
                }
                $lastRun = $candidate
                $lastVerdict = $candidateVerdict
                break
            }
        }
    }
    # ** Хлебников С.Ю. 20261120 «Обновить подготовленным» - по прогону, с которым готовили (prepared.gate), а не по
    # последнему: подготовили красный A, потом прошёл зелёный B - применяется A, и вердикт - его.
    $preparedGateMissing = ''
    if ($ApplyPrepared -and $null -ne $prepared) {
        $preparedGateName = [string](Get-JsonValue $prepared 'gate' '')
        if ($preparedGateName) {
            $preparedGateDir = Join-Path $runsRoot $preparedGateName
            $preparedVerdictFile = Join-Path $preparedGateDir 'verdict.json'
            if (Test-Path -LiteralPath $preparedVerdictFile) {
                $lastRun = Get-Item -LiteralPath $preparedGateDir
                $lastVerdict = (Get-Content -LiteralPath $preparedVerdictFile -Raw -Encoding UTF8) | ConvertFrom-Json
            }
            else { $lastRun = $null; $lastVerdict = $null; $preparedGateMissing = $preparedGateName }
        }
    }
    # ** Хлебников С.Ю. 20261120 конец

    $ciLines = New-Object System.Collections.Generic.List[string]     # для отчёта
    $advice = New-Object System.Collections.Generic.List[object]      # рекомендации: Kind = do / dont / note
    # Итог гейта - справочно: обновлять или нет, решает человек. Но если гейта нет, он красный или его комплект
    # откатили - перед обновлением переспросить, а красное из гейта унести в отчёт с пометкой «проверить».
    $gateRisks = New-Object System.Collections.Generic.List[string]
    $gateRedItems = New-Object System.Collections.Generic.List[string]
    $gateRed = $false
    $riskReason = ''

    Write-Host ''
    Write-Host 'ПОСЛЕДНИЙ ПРОГОН ГЕЙТА' -ForegroundColor Cyan
    if ($null -eq $lastRun -and $preparedGateMissing) {
        Write-Line ("  прогона подготовки {0} нет в папке прогонов" -f $preparedGateMissing) 'Yellow'
        $ciLines.Add(("Прогона подготовки {0} нет." -f $preparedGateMissing))
        $gateRisks.Add(("прогона {0}, с которым готовили обновление, нет" -f $preparedGateMissing))
    }
    elseif ($null -eq $lastRun) {
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
        # Принятие в эталон вердикт этого прогона не меняет (он уже записан), но говорит: новое разобрано и признано
        # допустимым. Зелёным станет следующий прогон, который сравнится с этим эталоном.
        $acceptedFile = Join-Path $lastRun.FullName 'accepted.txt'
        $gateAccepted = (Test-Path -LiteralPath $acceptedFile)
        if ($gateAccepted) {
            $acceptedAt = ([string](@([System.IO.File]::ReadAllLines($acceptedFile, [System.Text.Encoding]::UTF8)) | Select-Object -First 1)) -replace '^time=', ''
            Write-Line ("  новое этого прогона принято в эталон {0}: разобрано и признано допустимым; зелёным будет следующий прогон" -f $acceptedAt) 'Green'
            $ciLines.Add(("Новое этого прогона принято в эталон {0}." -f $acceptedAt))
        }

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
        if ($verdict -eq 'RED') { $gateRisks.Add(("гейт {0} красный" -f $lastRun.Name)); $gateRed = $true }
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
        elseif ($verdict -eq 'YELLOW' -and $gateAccepted) {
            $advice.Add([pscustomobject]@{ Kind = 'do'; Text = 'гейт жёлтый, его новое принято в эталон (разобрано): можно обновлять' })
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
    $advice.Add([pscustomobject]@{ Kind = 'dont'; Text = ("обновлять {0} только {1} (DeployDeniedFrom/To): обновлению нужен монопольный доступ" -f $script:ProdBase, (Get-DeployWindowText)) })

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
    Assert-ProdOpen $prodStates
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
            if (-not $savedHash) { $entry.ProdText = 'менялась ли рабочая помимо гейта, не узнать: снимка после прошлого обновления нет' }
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
    # Прошлый откат подготовленного прошёл не полностью: ни новой подготовки, ни обновления - сначала восстановление (#10).
    if ($null -ne $prepared -and (Get-PreparedRollbackFailedText $prepared)) { throw (Get-PreparedRollbackFailedText $prepared) }
    if ($null -ne $prepared -and -not $Prepare -and -not $ApplyPrepared) { throw (Get-PreparedBusyText 'Обновление одним проходом' $prepared) }

    # Кнопки - всегда, что бы ни показал гейт и сравнение: решает человек.
    # «Все» - все необновлённые (изменённые в temp, новые, несравнённые); если таких нет - все из temp заново.
    # «Выбранные» - список необновленных, галочки ставит человек. Замечания гейта после «Обновить все»
    # сбрасываются (принимаются в эталон): они либо исправлены, либо неважны.
    $allTargets = @($pending)
    if ($allTargets.Count -eq 0) { $allTargets = @($fromTemp) }
    $mode = ''
    if ($ApplyPrepared) {
        # Обновить подготовленным: что загружено при подготовке, то и применяется. Сверка: temp и рабочая с тех пор
        # не менялись (по хеш-суммам через внешнее соединение, если они читаются).
        if ($null -eq $prepared) { throw 'подготовленного обновления нет: сначала «Подготовить обновление рабочей»' }
        $failedText = Get-PreparedRollbackFailedText $prepared
        if ($failedText) { throw $failedText }
        if ([bool](Get-JsonValue $prepared 'partial' $false)) { throw 'подготовка не закончена (часть расширений не загрузилась): «Отменить подготовку рабочей» или «Подготовить обновление рабочей» заново' }
        if ([string](Get-JsonValue $prepared 'base' '') -ne $script:ProdBase) { throw ("подготовлено для базы {0}, а рабочая сейчас {1}" -f (Get-JsonValue $prepared 'base' '?'), $script:ProdBase) }
        $preparedRunId = [string](Get-JsonValue $prepared 'runId' '')
        $preparedWhen = [string](Get-JsonValue $prepared 'timeText' '')
        Write-Host ''
        Write-Host 'ПОДГОТОВЛЕННОЕ ОБНОВЛЕНИЕ' -ForegroundColor Cyan
        Write-Line ("  подготовлено {0}: {1}" -f $preparedWhen, (Get-PreparedText $prepared))
        $preparedByName = @{}
        $preparedSelected = @()
        $preparedChanged = New-Object System.Collections.Generic.List[string]
        $preparedCompared = 0
        foreach ($item in @(Get-JsonValue $prepared 'extensions' @())) {
            $name = [string](Get-JsonValue $item 'name' '')
            $match = @($extensions | Where-Object { $_.Name -eq $name })
            if ($match.Count -eq 0) { throw ("в подготовленном обновлении есть {0}, а в DeployExtensions его нет" -f $name) }
            $backupPath = [string](Get-JsonValue $item 'backup' '')
            if ($backupPath -and -not (Test-Path -LiteralPath $backupPath)) { throw ("нет резервной копии подготовки {0}: «Отменить подготовку» и подготовить заново" -f $backupPath) }
            $preparedByName[$name] = $item
            $preparedSelected += $match[0]
            $tempThen = [string](Get-JsonValue $item 'tempHash' '')
            if ($tempThen -and $tempStates.Ok -and $tempStates.Items.ContainsKey($name) -and $tempStates.Items[$name].Hash) {
                $preparedCompared++
                if ($tempStates.Items[$name].Hash -ne $tempThen) { $preparedChanged.Add(("{0}: в {1} после подготовки изменено - в рабочую загружена версия на момент подготовки, не нынешняя" -f $name, $script:TempBase)) }
            }
            $prodThen = [string](Get-JsonValue $item 'prodHash' '')
            if ($prodThen -and $prodStates.Ok -and $prodStates.Items.ContainsKey($name) -and $prodStates.Items[$name].Hash) {
                $preparedCompared++
                if ($prodStates.Items[$name].Hash -ne $prodThen) { $preparedChanged.Add(("{0}: в {1} после подготовки что-то меняли (хеш расширения другой)" -f $name, $script:ProdBase)) }
            }
        }
        if ($preparedChanged.Count -gt 0) {
            foreach ($line in $preparedChanged) { Write-Line ('  ' + $line) 'Yellow' }
            # ** Хлебников С.Ю. 20261120 Изменения после подготовки - риск, как красный гейт: вопрос один, ответ «да» -
            # riskAccepted, и они уходят в отчёт и deploy.json. Надёжнее - «Подготовить обновление рабочей» заново.
            foreach ($line in $preparedChanged) { $gateRisks.Add(('после подготовки изменено - ' + $line)) }
            Write-RunLog ('Обновление подготовленным несмотря на: ' + ($preparedChanged -join '; '))
        }
        elseif ($preparedCompared -gt 0) { Write-Line ("  с подготовки {0} и {1} не менялись" -f $script:TempBase, $script:ProdBase) 'Green' }
        else { Write-Line '  сверить с подготовкой не удалось: хеш-суммы расширений через внешнее соединение не прочитаны' 'Yellow' }
        $mode = 'prepared'
    }
    if (-not $ApplyPrepared) {
    $modeMenu = New-Object System.Collections.Generic.List[object]
    $modeMenu.Add([pscustomobject]@{ Key = '1'; Label = ("Обновить все расширения из {0} в {1} ({2})" -f $script:TempBase, $script:ProdBase, (@($allTargets | ForEach-Object { $_.Name }) -join ', ')) })
    $modeMenu.Add([pscustomobject]@{ Key = '2'; Label = 'Обновить выбранные расширения' })
    if ($processingsPending.Count -gt 0) {
        $modeMenu.Add([pscustomobject]@{ Key = 'epf'; Label = ("Обновить только внешние обработки ({0}): без блокировок рабочей и обновления конфигурации БД" -f $processingsPending.Count) })
    }
    $modeMenu.Add([pscustomobject]@{ Key = 'asis'; Label = 'Обновить как есть: ничего не загружать, только обновить конфигурацию БД (изменения уже загружены руками)' })
    $modeMenu.Add([pscustomobject]@{ Key = 'exit'; Label = 'Выход' })
    $modeNotes = @()
    if ($pending.Count -eq 0 -and $fromTemp.Count -gt 0) { $modeNotes += 'необновлённых нет: в рабочей всё как в temp. «Обновить все» загрузит их заново' }
    if ($fromTemp.Count -eq 0) { $modeNotes += 'в temp нет ни одного расширения из DeployExtensions: загружать из temp неоткуда' }
    $modeHeader = ("Обновление {0}" -f $script:ProdBase)
    if ($Prepare) {
        # Подготовка: только расширения из temp. Внешние обработки записываются при обновлении; «как есть» здесь не нужно.
        $modeMenu = New-Object System.Collections.Generic.List[object]
        $modeMenu.Add([pscustomobject]@{ Key = '1'; Label = ("Подготовить все расширения из {0} в {1} ({2})" -f $script:TempBase, $script:ProdBase, (@($allTargets | ForEach-Object { $_.Name }) -join ', ')) })
        $modeMenu.Add([pscustomobject]@{ Key = '2'; Label = 'Подготовить выбранные расширения' })
        $modeMenu.Add([pscustomobject]@{ Key = 'exit'; Label = 'Выход' })
        $modeHeader = ("Подготовка обновления {0}" -f $script:ProdBase)
    }
    $modeIndex = Select-UiOne -Header $modeHeader -Items @($modeMenu | ForEach-Object { $_.Label }) -Notes $modeNotes
    if ($modeIndex -lt 0 -or $modeMenu[$modeIndex].Key -eq 'exit') { Write-Host 'Выход, ничего не обновлял.'; exit 0 }
    $mode = $modeMenu[$modeIndex].Key
    if (($mode -eq '1' -or $mode -eq '2') -and $fromTemp.Count -eq 0 -and $processingsPending.Count -eq 0) { Write-Host 'В temp нечего брать: выход, ничего не обновлял.'; exit 0 }
    }

    $selected = @()
    if ($mode -eq '1') {
        $selected = @($allTargets)
    }
    elseif ($mode -eq 'prepared') {
        # Обновить подготовленным: ровно то, что загружено при подготовке.
        $selected = @($preparedSelected)
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
    # «Выбранные» и «подготовленным» - ни одной (подготовка касалась только расширений). В «как есть» обработки
    # не трогаются. Enter без отметок - не записывать ни одной и идти дальше с расширениями: раньше пустой выбор
    # не принимался, а Esc выходил из обновления - обновить расширения, не трогая обработки, было нельзя
    # (рабочая 19.11: в списке были обработки, которые в рабочей новее, чем в temp).
    if ($mode -ne 'asis' -and -not $Prepare -and $processingsPending.Count -gt 0) {
        $procLabels = @($processingsPending | ForEach-Object { '{0} ({1})  {2}' -f $_.ObjName, $_.Title, $_.Text })
        $procPreselected = @()
        if ($mode -eq '1' -or $mode -eq 'epf') { $procPreselected = @(0..($processingsPending.Count - 1)) }
        $procNotes = @(('Отмеченное запишется в {0} поверх того, что там есть: «изменена» значит «отличается», в рабочей версия может быть новее - сверь версии.' -f $script:ProdBase),
            'Enter без отметок - обработки не трогать.')
        $procPicked = Select-UiMany -Header ("Какие внешние обработки записать в {0}" -f $script:ProdBase) -Items $procLabels -Preselected $procPreselected -Notes $procNotes -AllowEmpty
        if ($null -eq $procPicked) { Write-Host 'Выход, ничего не обновлял.'; exit 0 }
        if (@($procPicked).Count -eq 0) { Write-Line '  внешние обработки: не отмечено ни одной - не трогаю' }
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

    if ($mode -eq 'prepared') {
        # Что было и что стало - из подготовки: версии, резервная копия (снята до загрузки), выгрузки для отчёта.
        foreach ($entry in $selected) {
            $item = $preparedByName[$entry.Name]
            $entry.Status = [string](Get-JsonValue $item 'status' 'changed')
            $entry.ProdVersion = [string](Get-JsonValue $item 'oldVersion' '')
            $entry.TempVersion = [string](Get-JsonValue $item 'newVersion' '')
            $entry.ProdPresent = ($entry.Status -ne 'new')
            $entry.Backup = [string](Get-JsonValue $item 'backup' '')
            $entry.NewFile = [string](Get-JsonValue $item 'newFile' '')
            $entry.Loaded = $true
            $entry.OldDir = ''
            $entry.NewDir = ''
            $keptDir = [string](Get-JsonValue $item 'oldDir' '')
            if ($keptDir -and (Test-Path -LiteralPath $keptDir)) { $entry.OldDir = $keptDir }
            $keptDir = [string](Get-JsonValue $item 'newDir' '')
            if ($keptDir -and (Test-Path -LiteralPath $keptDir)) { $entry.NewDir = $keptDir }
        }
    }
    # Порядок - как в DeployExtensions (нижний слой первым).
    Write-Host ''
    if ($mode -eq 'asis') { Write-Line ("Обновляю конфигурацию БД {0} как есть: {1}" -f $script:ProdBase, (@($selected | ForEach-Object { $_.Name }) -join ', ')) 'Cyan' }
    elseif ($Prepare) { Write-Line ("Готовлю обновление {0} (загрузка в конфигурацию без применения): {1}" -f $script:ProdBase, (@($selected | ForEach-Object { $_.Name }) -join ', ')) 'Cyan' }
    elseif ($mode -eq 'prepared') { Write-Line ("Обновляю {0} подготовленным: {1}" -f $script:ProdBase, (@($selected | ForEach-Object { $_.Name }) -join ', ')) 'Cyan' }
    elseif ($selected.Count -gt 0) { Write-Line ("Обновляю в {0}: {1}" -f $script:ProdBase, (@($selected | ForEach-Object { $_.Name }) -join ', ')) 'Cyan' }
    if ($selectedProcessings.Count -gt 0) { Write-Line ("Внешние обработки в {0}: {1}" -f $script:ProdBase, (@($selectedProcessings | ForEach-Object { $_.ObjName }) -join ', ')) 'Cyan' }

    # ** Хлебников С.Ю. 20261120 Что проверил прогон (#27): хеш-суммы temp на конец его проверок (checkedState в
    # verdict.json) против того, что сейчас уходит в рабочую. Разошлось - это другой комплект: риск, вопрос заново.
    # Снимка нет (старый прогон, «как есть», COM не прочитался) - честная отметка, не риск.
    $checkedNote = ''
    if ($null -ne $lastRun -and $mode -ne 'asis') {
        $checked = Get-JsonValue $lastVerdict 'checkedState' $null
        # Снимка нет или он не снялся - что проверено, видно по сведениям самопроверки «после» этого прогона (#7).
        if ($null -eq $checked -or -not [bool](Get-JsonValue $checked 'ok' $false)) {
            $evidence = Get-SelfCheckEvidence $lastRun.FullName
            if ($null -ne $evidence) { $checked = $evidence; Write-RunLog ("Что проверил прогон {0} - по сведениям самопроверки «после»" -f $lastRun.Name) }
        }
        if ($null -eq $checked) { $checkedNote = ("проверка этого состава не подтверждена: в прогоне {0} нет снимка temp" -f $lastRun.Name) }
        elseif (-not [bool](Get-JsonValue $checked 'ok' $false)) { $checkedNote = ("проверка этого состава не подтверждена: снимок temp прогона {0} не снялся ({1})" -f $lastRun.Name, [string](Get-JsonValue $checked 'error' '')) }
        else {
            $checkedExt = Get-JsonValue $checked 'extensions' $null
            $checkedProc = Get-JsonValue $checked 'processings' $null
            $fromSelfCheck = [bool](Get-JsonValue $checked 'fromSelfCheck' $false)
            $mismatch = New-Object System.Collections.Generic.List[string]
            $unconfirmed = New-Object System.Collections.Generic.List[string]
            $checkedBase = [string](Get-JsonValue $checked 'base' '')
            if ($checkedBase -and $script:TempBase -and $checkedBase -ine $script:TempBase -and $checkedBase -notlike ('*\' + $script:TempBase)) {
                $mismatch.Add(("прогон проверял другую базу ({0})" -f $checkedBase))
            }
            foreach ($checkEntry in $selected) {
                $nowHash = ''
                if ($mode -eq 'prepared') { $nowHash = [string](Get-JsonValue $preparedByName[$checkEntry.Name] 'tempHash' '') }
                elseif ($tempStates.Ok -and $tempStates.Items.ContainsKey($checkEntry.Name)) { $nowHash = [string]$tempStates.Items[$checkEntry.Name].Hash }
                $thenItem = $null
                if ($null -ne $checkedExt) { $thenItem = Get-JsonValue $checkedExt $checkEntry.Name $null }
                if ($null -eq $thenItem) { $mismatch.Add(("{0}: прогон его не проверял" -f $checkEntry.Name)); continue }
                $thenHash = [string](Get-JsonValue $thenItem 'hash' '')
                if (-not $nowHash -or -not $thenHash) { $unconfirmed.Add([string]$checkEntry.Name); continue }
                if ($nowHash -ne $thenHash) { $mismatch.Add(("{0}: в temp не то, что проверял прогон" -f $checkEntry.Name)) }
            }
            foreach ($checkProc in $selectedProcessings) {
                # Сведения самопроверки обработок не содержат: совпадение не установлено, но и не расхождение.
                if ($fromSelfCheck) { $unconfirmed.Add([string]$checkProc.ObjName); continue }
                $nowItem = @($tempProcExport.Items | Where-Object { $_.ObjName -eq $checkProc.ObjName } | Select-Object -First 1)
                $thenItem = $null
                if ($null -ne $checkedProc) { $thenItem = Get-JsonValue $checkedProc $checkProc.ObjName $null }
                if ($null -eq $thenItem) { $mismatch.Add(("{0}: прогон эту обработку не проверял" -f $checkProc.ObjName)); continue }
                if ($nowItem.Count -eq 0 -or -not [string]$nowItem[0].Hash) { $unconfirmed.Add([string]$checkProc.ObjName); continue }
                if ([string]$nowItem[0].Hash -ne [string](Get-JsonValue $thenItem 'hash' '')) { $mismatch.Add(("{0}: в temp не та обработка, что проверял прогон" -f $checkProc.ObjName)) }
            }
            if ($mismatch.Count -gt 0) {
                $gateRisks.Add(("состав расходится с проверенным прогоном {0}: {1}" -f $lastRun.Name, ($mismatch -join '; ')))
                foreach ($line in $mismatch) { Write-Line ('  ' + $line) 'Yellow' }
            }
            if ($unconfirmed.Count -gt 0) { $checkedNote = ("совпадение с проверенным не установлено (хеш не прочитан): {0}" -f ($unconfirmed -join ', ')) }
            elseif ($mismatch.Count -eq 0 -and ($selected.Count + @($selectedProcessings).Count) -gt 0) { Write-Line ("  состав совпадает с проверенным прогоном {0}" -f $lastRun.Name) 'Green' }
        }
        if ($checkedNote) { Write-Line ('  ' + $checkedNote) 'Yellow'; $ciLines.Add(($checkedNote + '.')) }
    }
    # ** Хлебников С.Ю. 20261120 конец

    # Гейт красный, его нет или комплект откатили: переспросить. Да - едем, красное гейта уходит в отчёт.
    $riskAccepted = $false
    if ($gateRisks.Count -gt 0) {
        $question = "Обновить {0}, хотя {1}? Красное из гейта попадёт в отчёт с пометкой «проверить работоспособность»." -f $script:ProdBase, ($gateRisks -join '; ')
        if ($Prepare) { $question = "Готовить обновление {0}, хотя {1}? Новые версии загрузятся в конфигурацию рабочей (без применения)." -f $script:ProdBase, ($gateRisks -join '; ') }
        $sure = Confirm-Ui -Question $question -Yes 'Да, обновлять' -No 'Нет, выйти'
        if ($sure -ne $true) { Write-Host 'Выход, ничего не обновлял.'; exit 0 }
        $riskAccepted = $true
        Write-RunLog ('Обновление несмотря на: ' + ($gateRisks -join '; '))
        Write-Line ("  Обновляю, несмотря на: {0}" -f ($gateRisks -join '; ')) 'Yellow'
        # ** Хлебников С.Ю. 20261120 Выпуск с красным гейтом - с причиной одной строкой: она уходит в deploy.json,
        # отчёт, статью и отметку released.txt прогона. Прогон остаётся красным, в эталон он сам не принимается.
        if ($gateRed) {
            for ($attempt = 1; $attempt -le 3 -and -not $riskReason; $attempt++) {
                $typedReason = Read-UiText -Prompt 'Причина выпуска с красным гейтом (одной строкой, попадёт в отчёт)' -CancelAsNull
                if ($null -eq $typedReason) { Write-Host 'Выход, ничего не обновлял.'; exit 0 }
                $riskReason = ([string]$typedReason).Trim()
                if (-not $riskReason) { Write-Line '  Без причины красный комплект не выпускаю: напиши её одной строкой (Esc - выйти).' 'Yellow' }
            }
            if (-not $riskReason) { Write-Host 'Причина не указана - выход, ничего не обновлял.'; exit 0 }
            Write-RunLog ('Причина выпуска с красным гейтом: ' + $riskReason)
            Write-Line ("  Причина: {0}" -f $riskReason) 'Yellow'
            $ciLines.Add(("Выпуск с красным гейтом, причина: {0}." -f $riskReason))
        }
        # ** Хлебников С.Ю. 20261120 конец
    }
}

if ((Test-DeployHourDenied (Get-Date)) -and -not $Prepare) { throw ("сейчас {0} - обновлять рабочую в это время запрещено (DeployDeniedFrom/To): рабочую базу обновляем только {1}" -f (Get-Date -Format 'HH:mm'), (Get-DeployWindowText)) }

# ** Хлебников С.Ю. 20261120 Сводка прямо перед вводом имени: цель, операция, что было и что станет, обработки
# (и ноль), гейт и причина выпуска - всё, что выше могло уехать за край экрана.
$confirmLines = New-Object System.Collections.Generic.List[string]
$operationNames = @{ '1' = 'обновление одним проходом (все из temp)'; '2' = 'обновление одним проходом (выбранные из temp)'; 'epf' = 'только внешние обработки'; 'asis' = 'обновление конфигурации БД как есть'; 'rollback' = 'откат'; 'prepared' = 'применение подготовленного' }
$operationText = 'обновление'
if ($operationNames.ContainsKey([string]$mode)) { $operationText = $operationNames[[string]$mode] }
if ($Prepare) { $operationText = 'подготовка: загрузка в конфигурацию без применения, пользователи работают' }
$confirmLines.Add(("Операция: {0}" -f $operationText))
foreach ($confirmEntry in $selected) {
    $fromText = [string]$confirmEntry.ProdVersion
    if (-not $confirmEntry.ProdPresent) { $fromText = 'нет' } elseif (-not $fromText) { $fromText = '?' }
    $toText = [string]$confirmEntry.TempVersion
    if ($mode -eq 'rollback') { $toText = 'резервная копия' } elseif ($mode -eq 'asis') { $toText = 'как загружено' } elseif (-not $toText) { $toText = '?' }
    $confirmLines.Add(("  {0}: {1} -> {2}" -f $confirmEntry.Name, $fromText, $toText))
}
if ($selected.Count -eq 0) { $confirmLines.Add('  расширений: 0') }
$confirmLines.Add(("Внешние обработки: {0}" -f @($selectedProcessings).Count))
foreach ($confirmProc in $selectedProcessings) { $confirmLines.Add(("  {0}" -f $confirmProc.ObjName)) }
if ($null -ne $lastRun) { $confirmLines.Add(("Гейт: прогон {0}, вердикт {1}" -f $lastRun.Name, [string](Get-JsonValue $lastVerdict 'verdict' ''))) }
elseif ($mode -ne 'rollback') { $confirmLines.Add('Гейт: прогонов нет') }
if ($riskReason) { $confirmLines.Add(("Выпуск с красным гейтом, причина: {0}" -f $riskReason)) }
if ($mode -ne 'rollback' -and $checkedNote) { $confirmLines.Add(("Проверка: {0}" -f $checkedNote)) }
if (-not $Prepare) { $confirmLines.Add(("Окно обновления: {0}" -f (Get-DeployWindowText))) }
Show-UiTitle -Text ("Перед записью в {0}" -f $script:ProdBase) -Kind 'warn' -More $confirmLines.ToArray()
Write-RunLog ('Сводка перед подтверждением: ' + ($confirmLines -join ' | '))
# ** Хлебников С.Ю. 20261120 конец

Write-Host ("  Это рабочая база. Чтобы продолжить, набери её имя ({0}) и Enter:" -f $script:ProdBase) -ForegroundColor Yellow
$typedName = Read-UiText -Prompt ("Это рабочая база. Чтобы продолжить, набери её имя ({0})" -f $script:ProdBase)
if ($typedName -cne $script:ProdBase) { throw 'имя базы набрано не так: обновление отменено' }
Write-RunLog 'Подтверждено именем базы'
# ** Хлебников С.Ю. 20261120 Пока ждали ввода имени, могло наступить запретное время: сверка ещё раз перед первой записью.
if ((Test-DeployHourDenied (Get-Date)) -and -not $Prepare) { throw ("пока ждал подтверждения, наступило {0} - обновлять рабочую в это время запрещено (DeployDeniedFrom/To): рабочую базу обновляем только {1}. В рабочую ничего не записано" -f (Get-Date -Format 'HH:mm'), (Get-DeployWindowText)) }

#endregion

#region Подготовка рабочей базы

# План обновления для ci.exe: шаги, которые пойдут, если ничего не упадёт.
$planSteps = New-Object System.Collections.Generic.List[string]
if ($selected.Count -gt 0 -and -not $Prepare) { $planSteps.Add('Подготовка рабочей базы') }
foreach ($planEntry in @($selected | Where-Object { $mode -ne 'prepared' })) {
    $planSteps.Add(("Выгрузить {0} из {1}" -f $planEntry.Name, $script:ProdBase))
    if ($mode -ne 'asis' -and $mode -ne 'rollback') { $planSteps.Add(("Выгрузить {0} из {1}" -f $planEntry.Name, $script:TempBase)) }
}
if ($mode -ne 'asis' -and $mode -ne 'prepared') {
    foreach ($planEntry in $selected) {
        if ($planEntry.ProdPresent) { $planSteps.Add(("Резервная копия {0}" -f $planEntry.Name)) }
        if ($mode -ne 'rollback') { $planSteps.Add(("Взять {0} из {1}" -f $planEntry.Name, $script:TempBase)) }
    }
    foreach ($planEntry in $selected) { $planSteps.Add(("Загрузить {0} в {1}" -f $planEntry.Name, $script:ProdBase)) }
}
if (-not $Prepare) {
foreach ($planEntry in $selected) { $planSteps.Add(("Обновить конфигурацию БД {0}" -f $planEntry.Name)) }
foreach ($planProc in $selectedProcessings) { $planSteps.Add((Get-ProcessingStepTitle $planProc)) }
if ($selected.Count -gt 0) {
    $planSteps.Add('Проверка применимости')
    $planSteps.Add('Канареечный вход')
    $planSteps.Add('Самопроверка на чтение')
    # После снятия блокировок (#2). Блокировку сеансов запуск мог и не ставить - тогда шаг останется непройденным.
    if ($plainLoginTimeoutSec -gt 0) { $planSteps.Add('Вход без кода разрешения') }
}
$planSteps.Add('Статья в базу знаний')
}
Send-UiPlan -StepNames $planSteps.ToArray()

# ** Хлебников С.Ю. 20261120 Прогноз длительности против конца окна: до первой записи, остановиться ещё можно.
if (-not $Prepare) {
    $forecastSeconds = 0.0
    foreach ($planTitle in $planSteps) { $forecastSeconds += [double](Get-StatPlan -Title $planTitle) }
    $windowEnd = Get-DeployWindowEnd (Get-Date)
    if ($forecastSeconds -gt 0 -and $null -ne $windowEnd) {
        $finishAt = (Get-Date).AddSeconds($forecastSeconds)
        if ($finishAt -gt $windowEnd) {
            $goOn = Confirm-Ui -Question ("По прогнозу обновление займёт ~{0} мин и закончится около {1:HH:mm}, а окно обновления - до {2:HH:mm}. Начинать?" -f [Math]::Ceiling($forecastSeconds / 60), $finishAt, $windowEnd) -Yes 'Да, начинать' -No 'Нет, выйти'
            if ($goOn -ne $true) { Write-Host 'Выход, в рабочую ничего не записано.'; exit 0 }
            Write-RunLog ("Начато, хотя прогноз выходит за окно: до {0:HH:mm}, окно до {1:HH:mm}" -f $finishAt, $windowEnd)
        }
    }
}
# ** Хлебников С.Ю. 20261120 конец

# Только обновлению расширений нужен монопольный доступ. Свои изменения возвращаем через finally.
$needExclusive = ($selected.Count -gt 0 -and -not $Prepare)
if ($needExclusive) { $script:ProdLockState = New-GateLockState }
try {

if ($needExclusive) {
    Write-Host ''
    Write-Host 'Подготовка рабочей базы:'
    $prepLink = Connect-ClusterAgent
    $prepTarget = Get-BaseInfo -Link $prepLink -BaseName $script:ProdBase -User $script:ProdUser -Password $script:ProdPassword
    try {
        # Запись прошла, а чтение-подтверждение упало: JobsSet уже true - в locks.json это должно попасть и так.
        try { $jobsLocked = Set-GateJobsLock $script:ProdLockState $prepTarget { param($t) Read-BaseInfoAgain $t $script:ProdBase } }
        finally { Save-ProdLockFile }
        if ($jobsLocked) {
            Write-Line '  поставил блокировку регламентных заданий на время обновления; в конце сниму' 'Green'
        }
        else { Write-Line '  блокировка регламентных заданий уже стоит, оставляю её' }
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

    # Открытый конфигуратор temp: выгрузки расширений из temp (что ставить и отчёт об изменениях) с ним падают
    # «Ошибка блокировки информационной базы для конфигурирования». Закрыть до начала, а не узнать посреди.
    $tempSessions = @(Get-BaseSessions $prepLink $script:TempBase)
    foreach ($entry in @($tempSessions | Where-Object { $_.IsError })) { Write-Line ('  сеансы {0} проверить не смог: {1}' -f $script:TempBase, $entry.Text) 'Yellow' }
    $tempDesigners = @($tempSessions | Where-Object { -not $_.IsError -and $_.IsDesigner })
    if ($tempDesigners.Count -gt 0) {
        Write-Line ("  открыт конфигуратор {0}: выгрузки из него с ним не пройдут" -f $script:TempBase) 'Yellow'
        foreach ($entry in $tempDesigners) { Write-Line ('    ' + $entry.Text) 'Yellow' }
        $answer = Read-UiChoice -Header ("Открыт конфигуратор {0}. Закрой его сам - скрипт увидит и продолжит, или:" -f $script:TempBase) `
            -Keys @('1', '2') -Labels @('Закрыть отсюда (сеанс прерывается, несохранённые правки в нём пропадут)', 'Отмена') -CancelKey '2' -Poll {
            $now = @(Get-BaseSessions $prepLink $script:TempBase)
            if (@($now | Where-Object { $_.IsError }).Count -eq 0 -and @($now | Where-Object { $_.IsDesigner }).Count -eq 0) { return 'closed' }
            return ''
        }
        if ($answer -eq '2') { throw ("открыт конфигуратор {0}, отмена по ответу" -f $script:TempBase) }
        if ($answer -eq '1') {
            foreach ($line in @(Stop-BaseSessions -Link $prepLink -BaseName $script:TempBase -Designers)) { Write-Line ('  ' + $line) }
            $left = @()
            for ($wait = 0; $wait -lt 10; $wait++) {
                Start-Sleep -Seconds 3
                $left = @(Get-BaseSessions $prepLink $script:TempBase | Where-Object { -not $_.IsError -and $_.IsDesigner })
                if ($left.Count -eq 0) { break }
            }
            if ($left.Count -gt 0) { throw ("конфигуратор {0} за 30 секунд не закрылся" -f $script:TempBase) }
        }
        Write-Line ("  конфигуратор {0} закрыт" -f $script:TempBase) 'Green'
    }

    function Set-ProdSessionLock {
        # Блокировка начала сеансов рабочей. StartAt - начало в будущем (предупреждение пользователям): до него
        # сеансы пускаются, клиенты БСП раз в минуту видят блокировку, показывают предупреждение со временем
        # и в это время закрываются сами; оставшихся перед загрузкой завершает Wait-ProdWarnLock. Без StartAt -
        # сразу (начало на 30 минут назад: часы сервера и этой машины могут расходиться).
        param($Target, $StartAt = $null)
        if ($null -eq $Target) { Write-Line '  блокировку начала сеансов поставить не смог (нет входа в свойства базы): сеансы могут вернуться' 'Yellow'; return }
        $infoBase = Read-BaseInfoAgain $Target $script:ProdBase
        if ([bool]$infoBase.SessionsDenied) {
            $existing = [string]$infoBase.PermissionCode
            if ($existing -cne $script:UnlockCode) {
                throw ("в {0} уже стоит чужая блокировка сеансов с другим кодом: впиши его в UnlockCode или сними блокировку" -f $script:ProdBase)
            }
            $now = Get-Date
            if (($null -ne $infoBase.DeniedFrom -and [datetime]$infoBase.DeniedFrom -gt $now) -or
                ($null -ne $infoBase.DeniedTo -and ([datetime]$infoBase.DeniedTo).Year -ge 1900 -and [datetime]$infoBase.DeniedTo -lt $now)) {
                throw 'в свойствах уже стоит блокировка начала сеансов с другим периодом, оставляю её расписание'
            }
            Write-Line '  блокировка начала сеансов уже стоит (код тот же), оставляю её'
            $script:SessionLockKept = $true
            if ($null -ne $StartAt) {
                Write-Line '  предупреждать не буду: блокировка уже стоит; оставшиеся сеансы завершу перед загрузкой'
                $script:WarnLockAt = Get-Date
            }
            return
        }
        if ([string]::IsNullOrEmpty($script:UnlockCode)) { $script:UnlockCode = '123'; Write-Line '  UnlockCode пустой: на этот запуск взят код разрешения входа по умолчанию. Задай свой: Настройки, Базы, UnlockCode.' }
        $start = Get-Date
        if ($null -ne $StartAt) { $start = [datetime]$StartAt }
        $until = $start.AddHours($sessionLockHours)
        $from = $start
        if ($null -eq $StartAt) {
            $from = $start.AddMinutes(-30)
            $message = "Идёт обновление расширений, база заблокирована до {0}" -f $until.ToString('HH:mm')
        }
        else {
            $message = "Обновление программы: в {0} база закрывается (не дольше чем до {1}). Сохраните работу и выйдите из программы до {0}." -f $start.ToString('HH:mm'), $until.ToString('HH:mm')
        }
        try { Set-GateSessionLock $script:ProdLockState $Target $from $until $script:UnlockCode $message { param($t) Read-BaseInfoAgain $t $script:ProdBase } }
        finally { Save-ProdLockFile }
        if ($null -eq $StartAt) {
            $script:ProdClosedAt = Get-Date
            Write-Line ("  поставил блокировку начала сеансов до {0}; сниму в конце" -f $until.ToString('HH:mm')) 'Green'
            return
        }
        $script:WarnLockAt = $start
        $script:WarnLockUntil = $until
        Write-Line ("  поставил блокировку начала сеансов с {0} до {1}: пользователи видят предупреждение, в {0} их программы закроются сами; сниму в конце" -f $start.ToString('HH:mm'), $until.ToString('HH:mm')) 'Green'
        Write-Line '  пока они сохраняются - выгрузки и резервные копии; загрузка в рабочую - после закрытия'
        Write-RunLog ("Предупреждение пользователей: блокировка начала сеансов с {0}" -f $start.ToString('HH:mm:ss'))
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
        $sessionKeys = @('1', '2', '3')
        $sessionLabels = @(
            'Продолжить так (обновление БД может упереться в монопольную блокировку)',
            'Выйти',
            ("Поставить блокировку начала сеансов на {0} ч, завершить сеансы и продолжить" -f $sessionLockHours))
        $sessionDefault = ''
        if ($deployWarnMinutes -gt 0) {
            $sessionKeys += '4'
            $sessionLabels += ("Предупредить пользователей и закрыть базу через {0} мин; пока они сохраняются - выгрузки и резервные копии, оставшиеся сеансы завершить перед загрузкой" -f $deployWarnMinutes)
            $sessionDefault = '4'
        }
        $answer = Read-UiChoice -Header ("В {0} есть сеансы: {1}. Можно дождаться, пока закончатся сами, или:" -f $script:ProdBase, $others.Count) `
            -Keys $sessionKeys -CancelKey '2' -DefaultKey $sessionDefault -Labels $sessionLabels -Poll {
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
        if ($answer -eq '4') {
            if ($null -eq $prepTarget) {
                Write-Line '  предупредить пользователей не могу (нет входа в свойства базы): оставшиеся сеансы завершу перед загрузкой' 'Yellow'
                $script:WarnLockAt = Get-Date
            }
            else { Set-ProdSessionLock $prepTarget -StartAt ((Get-Date).AddSeconds($deployWarnMinutes * 60)) }
        }
        if ($answer -eq '1') { Write-Line '  продолжаю с сеансами в базе' }
    }
}
else {
    Write-Host ''
    if ($Prepare) { Write-Line ("Подготовка: блокировки {0} не ставятся, сеансы не завершаются - пользователи работают дальше на применённых версиях." -f $script:ProdBase) }
    else { Write-Line ("Только внешние обработки: блокировки {0} не нужны, пользователи работают дальше." -f $script:ProdBase) }
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

if ($Prepare -and $null -ne $prepared) {
    # Повторная подготовка: в конфигурации рабочей лежат загруженные, не применённые версии прошлой подготовки.
    # Резервная копия и выгрузка сняли бы их, а не применённые, поэтому сначала прошлая подготовка отменяется.
    Write-Host ''
    Write-Line ("Прошлая подготовка от {0} ({1}): отменяю её, потом готовлю заново" -f (Get-JsonValue $prepared 'timeText' '?'), (Get-PreparedText $prepared)) 'Cyan'
    if (-not (Undo-PreparedExtensions -Items @(Get-PreparedItems $prepared))) { throw ("прошлую подготовку отменить не удалось (см. выше): новая не начата, {0} оставлен" -f $preparedPath) }
    Remove-Item -LiteralPath $preparedPath -Force
    $prepared = $null
}
if ($mode -eq 'prepared') {
    # Резервные копии подготовки - в папку этого запуска: по его deploy.json работает откат обновления.
    foreach ($entry in $selected) {
        if ($entry.Backup) {
            $backupCopy = Join-Path $beforeDir (Split-Path -Leaf $entry.Backup)
            Copy-Item -LiteralPath $entry.Backup -Destination $backupCopy -Force
            $entry.Backup = $backupCopy
        }
        $touched.Add($entry)
    }
    Write-Line ("  загрузки нет: новые версии загружены в конфигурацию {0} при подготовке {1}; обновляю конфигурацию БД" -f $script:ProdBase, $preparedWhen)
}

# Выгрузки в файлы для отчёта об изменениях и для отката «как есть». Конфигуратору рабочей никто не мешает
# (открытый закрыт выше), пользователи - нет: монопольный доступ выгрузкам и резервным копиям не нужен, поэтому
# при предупреждении пользователей они идут, пока те сохраняются. Не выгрузилось - не беда: отчёт будет без
# разницы по объектам.
if ($selected.Count -gt 0 -and $mode -ne 'prepared') {
    Write-Host ''
    Write-Host 'Выгрузки для отчёта об изменениях:'
}
$snapshotRoot = Join-Path $script:RunDir 'prod-before'
foreach ($entry in @($selected | Where-Object { $mode -ne 'prepared' })) {
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
    # Выгрузка рабочей - точный ответ, есть ли расширение в ней. Сравнение через COM могло не пройти
    # (Status = unknown), и тогда без этого резервной копии перед загрузкой не делалось бы - отката не было бы.
    if ($dump.Ok) { $entry.ProdPresent = $true }
    elseif ($dump.Absent) { $entry.ProdPresent = $false }
    # Подготовка: в рабочей его нет - значит, новое (сравнение через внешнее соединение могло сказать иначе);
    # отмена подготовки такое удаляет по имени.
    if ($Prepare -and $dump.Absent) { $entry.Status = 'new' }
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
foreach ($entry in @($selected | Where-Object { $mode -ne 'asis' -and $mode -ne 'prepared' })) {
    if (-not $entry.ProdPresent -and $entry.Status -eq 'unknown' -and $mode -ne 'rollback') {
        # Есть ли расширение в рабочей - неизвестно (ни COM, ни выгрузка не ответили). Грузить без резервной
        # копии нельзя: откатить будет не к чему.
        Write-Line ("[FAIL] Резервная копия {0}: неизвестно, есть ли оно в рабочей (сравнение и выгрузка не прошли) - без копии не гружу" -f $entry.Name) 'Red'
        $failed = $true; break
    }
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

if ($Prepare -and -not $failed) {
    # Выгрузки «было» и «стало» - в папку подготовки: к обновлению зеркала могут уйти вперёд, а отчёт об изменениях
    # и версии строятся по ним. Не скопировалось - остаётся путь к зеркалу, подготовке это не мешает.
    foreach ($entry in $selected) {
        try {
            if ($entry.OldDir -and (Test-Path -LiteralPath $entry.OldDir)) {
                $keptRoot = Join-Path $script:RunDir 'prod-before'
                New-Item -ItemType Directory -Path $keptRoot -Force | Out-Null
                Copy-Item -LiteralPath $entry.OldDir -Destination (Join-Path $keptRoot $entry.Name) -Recurse -Force
                $entry.OldDir = Join-Path $keptRoot $entry.Name
            }
            if ($entry.NewDir -and (Test-Path -LiteralPath $entry.NewDir)) {
                $keptRoot = Join-Path $script:RunDir 'temp-new'
                New-Item -ItemType Directory -Path $keptRoot -Force | Out-Null
                Copy-Item -LiteralPath $entry.NewDir -Destination (Join-Path $keptRoot $entry.Name) -Recurse -Force
                $entry.NewDir = Join-Path $keptRoot $entry.Name
            }
        }
        catch { Write-Line ("  выгрузки {0} в папку подготовки не скопировались: {1}; отчёт возьмёт зеркало" -f $entry.Name, $_.Exception.Message) 'Yellow' }
    }
}
if ($Prepare -and -not $failed) {
    # Записывается до первой загрузки, как незаконченная: оборвётся посреди загрузки (окно закрыли, питание) -
    # «Обновить одним проходом» и откат не пойдут, пока подготовку не отменят или не повторят.
    $preparedGate = ''
    if ($null -ne $lastRun) { $preparedGate = [string]$lastRun.Name }
    Save-PreparedState -Entries $selected -Partial $true -TempStates $tempStates -GateRun $preparedGate -ReadProd $false
}
# Дальше рабочая меняется: при предупреждении пользователей - дождаться закрытия базы.
if (-not $failed -and $null -ne $script:WarnLockAt) { Wait-ProdWarnLock }
# ** Хлебников С.Ю. 20261120 Пока шли вопросы и выгрузки, temp могли поменять: хеш-суммы - ещё раз, после того как
# расширения взяты из temp. Не совпали с теми, по которым сверялся проверенный прогон, - в рабочую не грузим.
if (-not $failed -and @('1', '2') -contains [string]$mode -and $selected.Count -gt 0 -and (Get-Variable -Name tempStates -ErrorAction SilentlyContinue) -and $null -ne $tempStates -and $tempStates.Ok) {
    $tempAfterTake = Get-ExtensionStates -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword
    $movedInTemp = New-Object System.Collections.Generic.List[string]
    foreach ($takenEntry in $selected) {
        $hashBefore = ''
        if ($tempStates.Items.ContainsKey($takenEntry.Name)) { $hashBefore = [string]$tempStates.Items[$takenEntry.Name].Hash }
        $hashAfter = ''
        if ($tempAfterTake.Ok -and $tempAfterTake.Items.ContainsKey($takenEntry.Name)) { $hashAfter = [string]$tempAfterTake.Items[$takenEntry.Name].Hash }
        if (-not $tempAfterTake.Ok) { continue }
        if ($hashBefore -ne $hashAfter) { $movedInTemp.Add([string]$takenEntry.Name) }
    }
    if (-not $tempAfterTake.Ok) { Write-Line ("  хеш-суммы {0} после выгрузки не перечитаны: {1}" -f $script:TempBase, $tempAfterTake.Error) 'Yellow' }
    if ($movedInTemp.Count -gt 0) {
        Write-Line ("[FAIL] {0} изменили в {1} во время обновления (хеш-сумма другая, чем при сверке): {2}. В рабочую не гружу - запусти обновление заново." -f ($movedInTemp -join ', '), $script:TempBase, $script:ProdBase) 'Red'
        Write-RunLog ('temp изменён во время обновления: ' + ($movedInTemp -join ', '))
        $failed = $true
    }
}
# ** Хлебников С.Ю. 20261120 конец
# ** Хлебников С.Ю. 20261120 Журнал обновления - до первой записи в рабочую (не при подготовке: у неё prepared.json).
$script:JournalOn = $false
if (-not $failed -and -not $Prepare -and ($selected.Count + @($selectedProcessings).Count) -gt 0) {
    $script:JournalOn = $true
    try { $script:JournalProcessStart = (Get-Process -Id $PID).StartTime.ToString('yyyy-MM-ddTHH:mm:ss') } catch { $script:JournalProcessStart = '' }
    $script:JournalGate = $null
    if ($null -ne $lastRun) { $script:JournalGate = [ordered]@{ run = $lastRun.Name; verdict = [string](Get-JsonValue $lastVerdict 'verdict' '') } }
    foreach ($journalEntry in $selected) {
        $oldHashNow = ''
        $newHashNow = ''
        if ($mode -ne 'rollback' -and $mode -ne 'asis') {
            if ((Get-Variable -Name prodStates -ErrorAction SilentlyContinue) -and $null -ne $prodStates -and $prodStates.Ok -and $prodStates.Items.ContainsKey($journalEntry.Name)) { $oldHashNow = [string]$prodStates.Items[$journalEntry.Name].Hash }
            if ($mode -eq 'prepared') { $newHashNow = [string](Get-JsonValue $preparedByName[$journalEntry.Name] 'tempHash' '') }
            elseif ((Get-Variable -Name tempStates -ErrorAction SilentlyContinue) -and $null -ne $tempStates -and $tempStates.Ok -and $tempStates.Items.ContainsKey($journalEntry.Name)) { $newHashNow = [string]$tempStates.Items[$journalEntry.Name].Hash }
        }
        $journalEntry | Add-Member -NotePropertyName OldHash -NotePropertyValue $oldHashNow -Force
        $journalEntry | Add-Member -NotePropertyName NewHash -NotePropertyValue $newHashNow -Force
        $startStage = 'pending'
        if ($journalEntry.Backup) { $startStage = 'backup' }
        if ($mode -eq 'prepared') { $startStage = 'loaded' }
        $journalEntry | Add-Member -NotePropertyName Stage -NotePropertyValue $startStage -Force
    }
    foreach ($journalProc in $selectedProcessings) { $journalProc | Add-Member -NotePropertyName Stage -NotePropertyValue 'pending' -Force }
    if (-not (Save-DeployJournal -Step 'start')) { $failed = $true }
}
# ** Хлебников С.Ю. 20261120 конец

if (-not $failed -and $mode -ne 'asis' -and $mode -ne 'prepared') {
    foreach ($entry in $selected) {
        if (-not (Set-DeployStage $entry 'loading')) { $failed = $true; break }
        $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/LoadCfg', ('"{0}"' -f $entry.NewFile), '-Extension', $entry.Name) `
            -LogName ("load_{0}.log" -f $entry.Name) -TimeoutSec $timeoutLoadSec -Title ("Загрузить {0} в {1}" -f $entry.Name, $script:ProdBase)
        if ($result.ExitCode -eq 0 -or $result.TimedOut) { $entry.Loaded = $true; $touched.Add($entry) }
        if ($result.ExitCode -eq 0 -and -not (Set-DeployStage $entry 'loaded')) { $failed = $true; break }
        if ($result.ExitCode -ne 0) {
            Write-Line ("[FAIL] Загрузить {0} в {1}: {2}" -f $entry.Name, $script:ProdBase, $result.Text) 'Red'
            $failed = $true; break
        }
        Write-Line ("[OK]   Загрузить {0} в {1}: {2} с" -f $entry.Name, $script:ProdBase, $result.Seconds) 'Green'
    }
}

if ($Prepare) {
    # Подготовка кончается здесь: новые версии в конфигурации рабочей, конфигурация БД не обновлялась. Дальше -
    # «Обновить подготовленным» или «Отменить подготовку»; блокировок не было - снимать нечего.
    Write-Host ''
    if ($failed) {
        if (Test-Path -LiteralPath $preparedPath) {
            # Загрузка начиналась: что-то из выбранного уже в конфигурации рабочей (не применено).
            Write-Line ("Подготовка не прошла, а в конфигурацию {0} уже загружалось (не применено): {1}" -f $script:ProdBase, (@($selected | ForEach-Object { $_.Name }) -join ', ')) 'Red'
            # Без ответа дальше не идём: решение важное.
            $undoNow = $null
            while ($null -eq $undoNow) {
                $undoNow = Confirm-Ui -Question 'Вернуть расширения к применённым версиям? (Нет - оставить загруженным, не применяя)' -Yes 'Вернуть' -No 'Оставить'
            }
            if ($undoNow -and (Undo-PreparedExtensions -Items $selected)) {
                Remove-Item -LiteralPath $preparedPath -Force
                Write-Line ("ИТОГ: подготовка не прошла, расширения {0} возвращены к применённым версиям." -f $script:ProdBase) 'Red'
            }
            else { Write-Line ("ИТОГ: подготовка не закончена. В конфигурации {0} остались загруженные, не применённые версии: «Отменить подготовку рабочей» или «Подготовить обновление рабочей» заново." -f $script:ProdBase) 'Red' }
        }
        else { Write-Line ("ИТОГ: подготовка не прошла, в конфигурации {0} ничего не изменено." -f $script:ProdBase) 'Red' }
        exit 1
    }
    Save-PreparedState -Entries $selected -Partial $false -TempStates $tempStates -GateRun $preparedGate -ReadProd ([bool]$prodStates.Ok)
    Write-Line ("ИТОГ: подготовлено. В конфигурацию {0} загружены, но не применены: {1}." -f $script:ProdBase, (@($selected | ForEach-Object { $_.Name }) -join ', ')) 'Green'
    Write-Line '  Пользователи работают на прежних версиях. Дальше - «Обновить рабочую подготовленным» (в разрешённые часы) или «Отменить подготовку».'
    Write-Line ("  До обновления не нажимать «Обновить конфигурацию базы данных» в конфигураторе {0}: подготовленное применится сразу." -f $script:ProdBase) 'Yellow'
    Write-Line ("  Резервные копии: {0}" -f $beforeDir)
    exit 0
}
# Конфигурация БД обновляется после загрузки всех расширений.
if (-not $failed) {
    foreach ($entry in $selected) {
        $attempt = 0
        if ($script:JournalOn -and -not (Set-DeployStage $entry 'applying')) { $failed = $true; break }
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
        if ($script:JournalOn -and -not (Set-DeployStage $entry 'applied')) { $failed = $true; break }
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
            if (-not (Set-DeployStage $proc 'writing')) { $failed = $true; break }
            $session = Invoke-ProdProcessing -Mode 'unregepf' -OutDir $procDir -Name $proc.ObjName -Ref $proc.Ref -Title $title
            if (-not $session.Done -or $session.Status -ne 'done') {
                Write-Line ("[FAIL] {0}: {1}" -f $title, $session.Message) 'Red'
                $failed = $true; break
            }
            $touchedProcessings.Add($proc)
            $null = Set-DeployStage $proc 'written'
            Write-Line ("[OK]   {0}: публикация «Отключена», пометка удаления" -f $title) 'Green'
            continue
        }

        if (-not (Set-DeployStage $proc 'writing')) { $failed = $true; break }
        $session = Invoke-ProdProcessing -Mode 'regepf' -OutDir $procDir -File $proc.Source -TextFile $proc.SourceB64 -Name $proc.FileName -Title $title
        $values = $session.Values
        $proc.Ref = [string](Get-Setting $values 'ref' '')
        if ([string](Get-Setting $values 'objversion' '')) { $proc.NewVersion = [string](Get-Setting $values 'objversion' '') }
        if ([string](Get-Setting $values 'oldversion' '')) { $proc.OldVersion = [string](Get-Setting $values 'oldversion' '') }
        $isNewText = [string](Get-Setting $values 'isnew' '')
        if ($isNewText -eq '1') { $proc.IsNew = 'yes' } elseif ($isNewText -eq '0') { $proc.IsNew = 'no' }
        if ($session.OldB64) { $proc.Backup = Write-ProcessingBackup -Proc $proc -OldB64 $session.OldB64 }
        if ($session.Done -and ($session.Status -eq 'done' -or $proc.Ref)) { $null = Set-DeployStage $proc 'written' } else { $null = Save-DeployJournal -Step 'writing' }
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
    # снятая - записывается снова. Итог по каждому - в $script:RollbackResults.
    $ok = $true
    $script:RollbackResults = New-Object System.Collections.Generic.List[string]
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
            $script:RollbackResults.Add(("обработка {0}: не возвращена - откатывать не к чему" -f $proc.ObjName))
            $ok = $false
            continue
        }
        if ($session.Done -and $session.Status -eq 'done') { Write-Line ("  откат {0}: готово" -f $proc.ObjName) 'Green'; $script:RollbackResults.Add(("обработка {0}: возвращена" -f $proc.ObjName)) }
        else { Write-Line ("  откат {0} не прошёл: {1}" -f $proc.ObjName, $session.Message) 'Red'; $script:RollbackResults.Add(("обработка {0}: не возвращена - {1}" -f $proc.ObjName, $session.Message)); $ok = $false }
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
            $script:RollbackResults.Add(("{0}: не возвращено - копии нет" -f $entry.Name))
            $ok = $false
            continue
        }
        else {
            # Удаляется одно расширение по имени. Ключа -AllExtensions здесь нет.
            $result = Invoke-Designer -BaseName $script:ProdBase -Command @('/DeleteCfg', '-Extension', $entry.Name) `
                -LogName ("rollback_delete_{0}.log" -f $entry.Name) -TimeoutSec $timeoutLoadSec -Title ("Откат: удалить новое {0}" -f $entry.Name)
        }
        if ($result.ExitCode -eq 0) { Write-Line ("  откат {0}: готово" -f $entry.Name) 'Green'; $script:RollbackResults.Add(("{0}: возвращено" -f $entry.Name)) }
        else { Write-Line ("  откат {0} не прошёл: {1}" -f $entry.Name, $result.Text) 'Red'; $script:RollbackResults.Add(("{0}: не возвращено - {1}" -f $entry.Name, $result.Text)); $ok = $false }
    }
    return $ok
}
$script:RollbackResults = New-Object System.Collections.Generic.List[string]

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
            $rollbackNow = Confirm-Ui -Question 'Откатить? (к резервным копиям, а при «как есть» - к прежней выгрузке рабочей; Нет - оставить как есть)' -Yes 'Откатить' -No 'Оставить' -DangerYes
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
        # Код 0 ещё не «замечаний нет»: на рабочей 18.11 конфигуратор вернул 0 и написал в журнал, что у
        # расширения не найдены методы из аннотаций. Смотрим и на строки журнала.
        if ($result.ExitCode -eq 0 -and $applyLines.Count -eq 0) { Add-Light 'OK' 'Проверка применимости' 'замечаний нет' }
        elseif ($result.ExitCode -eq 0) { Add-Light 'WARN' 'Проверка применимости' ("замечаний {0} (код 0), первое: {1}" -f $applyLines.Count, ($applyLines | Select-Object -First 1)) }
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
                $extensionError = @($content | Where-Object { $_ -like 'exterror=*' } | Select-Object -First 1)
                if ($status.Count -eq 0 -or ([string]$status[0]).Substring(7).Trim() -ne 'ok') { Add-Light 'FAIL' 'Канареечный вход' ($content -join ' | ') }
                elseif ($notApplied.Count -gt 0) { Add-Light 'FAIL' 'Канареечный вход' ("не применились в сеансе: {0}" -f ($notApplied -join ', ')) }
                elseif ($extensionError.Count -gt 0) {
                    # Вход удался, а применились ли расширения, неизвестно: список не прочитан (#17).
                    Add-Light 'WARN' 'Канареечный вход' ("вошёл за {0} с, но применение расширений не проверено: состав расширений не прочитан ({1})" -f $client.Seconds, ([string]$extensionError[0]).Substring(9).Trim())
                }
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
        # Решение - после всех проверок, и итог их - перед глазами: сводка здесь, вопрос в ci.exe - кнопками
        # внизу экрана (журнал над ним листается). Отчёт об изменениях и статья в базу знаний - после ответа:
        # в них пишется, оставлено обновление или откачено.
        Write-Host ''
        Write-Line 'ИТОГ ПРОВЕРОК ПОСЛЕ ОБНОВЛЕНИЯ' 'Cyan'
        foreach ($item in $light) {
            $itemColor = 'Green'
            if ($item.Status -eq 'FAIL') { $itemColor = 'Red' } elseif ($item.Status -eq 'WARN') { $itemColor = 'Yellow' }
            Write-Line ("  [{0}] {1}: {2}" -f $item.Status, $item.Name, $item.Text) $itemColor
        }
        Write-Line 'Лёгкий прогон нашёл проблемы.' 'Red'
        $keepUpdate = $null
        if ($deployKeepTimeoutMin -eq 0) {
            $keepUpdate = $true
            Write-Line '  DeployKeepTimeoutMin = 0: не спрашиваю, обновление оставлено' 'Yellow'
        }
        $keepDeadline = (Get-Date).AddMinutes($deployKeepTimeoutMin)
        while ($null -eq $keepUpdate) {
            $leftMin = [Math]::Max(1, [int][Math]::Ceiling(($keepDeadline - (Get-Date)).TotalMinutes))
            $picked = Read-UiChoice -Header ("Проверки нашли проблемы. Оставить обновление в {0}?" -f $script:ProdBase) -Keys @('1', '2') `
                -Labels @('Оставить', 'Откатить к резервным копиям') -DefaultKey '1' -Dock `
                -Notes @(("Итог проверок - над вопросом, журнал листается. Без ответа ещё ~{0} мин - обновление остаётся (DeployKeepTimeoutMin)." -f $leftMin)) `
                -Poll { if ((Get-Date) -ge $keepDeadline) { return 'timeout' } return '' }
            if ($picked -eq '1') { $keepUpdate = $true }
            elseif ($picked -eq '2') { $keepUpdate = $false }
            elseif ($picked -eq 'timeout' -or (Get-Date) -ge $keepDeadline) {
                $keepUpdate = $true
                Write-Line ("  ответа нет {0} мин: обновление оставлено" -f $deployKeepTimeoutMin) 'Yellow'
                Write-RunLog ("Ответа на «оставить или откатить» нет {0} мин: обновление оставлено" -f $deployKeepTimeoutMin)
            }
        }
        if (-not $keepUpdate) {
            if (Invoke-ProdRollback) { $outcome = 'rolledBack' } else { $outcome = 'rollbackFailed' }
        }
    }
}

#endregion

# ** Хлебников С.Ю. 20261120 Блокировки рабочей снимаются здесь, а не в самом конце (#24). Закрытая база нужна до
# конца обновления конфигурации БД и на время отката - к этой строке и то и другое позади, при любом исходе.
# Отчёт, статья в базу знаний, выгрузки рабочей в файлы и хеш-суммы пользователям не мешают: идут при открытой
# базе. В конце скрипта и в trap снятие вызывается ещё раз - повторный вызов ничего не делает.
Clear-ProdLocks
# Вход без кода разрешения (#2) - сразу после снятия, до отчёта и статьи: только если базу закрывал этот запуск.
$plainLogin = $null
if ($null -ne $script:ProdClosedAt -or $script:SessionLockKept) {
    $plainLogin = Test-ProdPlainLogin
    $plainColor = 'Green'
    if ($plainLogin.Status -eq 'FAIL') { $plainColor = 'Red' } elseif ($plainLogin.Status -ne 'OK') { $plainColor = 'Yellow' }
    Write-Line ("[{0}] Вход без кода разрешения: {1}" -f $plainLogin.Status, $plainLogin.Text) $plainColor
}
# ** Хлебников С.Ю. 20261120 конец

#region Отчёт об изменениях

$reportTitle = "Обновление расширений {0} от {1}" -f $script:ProdBase, (Get-Date -Format 'dd.MM.yyyy HH:mm')
if ($mode -eq 'asis') { $reportTitle = "Обновление конфигурации БД {0} как есть от {1}" -f $script:ProdBase, (Get-Date -Format 'dd.MM.yyyy HH:mm') }
if ($mode -eq 'epf') { $reportTitle = "Обновление внешних обработок {0} от {1}" -f $script:ProdBase, (Get-Date -Format 'dd.MM.yyyy HH:mm') }
if ($mode -eq 'prepared') { $reportTitle = "Обновление расширений {0} подготовленным от {1}" -f $script:ProdBase, (Get-Date -Format 'dd.MM.yyyy HH:mm') }
if ($mode -eq 'rollback') { $reportTitle = "Откат расширений {0} к состоянию до обновления {1}, от {2}" -f $script:ProdBase, $rollbackOf, (Get-Date -Format 'dd.MM.yyyy HH:mm') }
$outcomeNames = @{ updated = 'обновлено'; failed = 'обновление не прошло'; rolledBack = 'обновление откачено'; rollbackFailed = 'откат прошёл не полностью' }
$html = New-Object System.Text.StringBuilder
[void]$html.Append('<html><head><meta charset="utf-8"></head><body>')
[void]$html.Append(('<h1>{0}</h1>' -f (ConvertTo-Html $reportTitle)))
if ($mode -eq 'prepared') { [void]$html.Append(('<p>{0}</p>' -f (ConvertTo-Html ("Новые версии загружены в конфигурацию рабочей базы при подготовке {0} (пользователи при этом работали); сейчас обновлена конфигурация базы данных." -f $preparedWhen)))) }
if ($mode -eq 'asis') { [void]$html.Append('<p>Расширения загружены в конфигурацию рабочей базы руками; скрипт только обновил конфигурацию базы данных и проверил.</p>') }
[void]$html.Append(('<p>Из {0} в {1}. Итог: <b>{2}</b>. Выполнил: {3}. Папка запуска: {4}.</p>' -f (ConvertTo-Html $script:TempBase), (ConvertTo-Html $script:ProdBase), (ConvertTo-Html $outcomeNames[$outcome]), (ConvertTo-Html $env:USERNAME), (ConvertTo-Html $script:RunDir)))
if ($riskAccepted) {
    [void]$html.Append('<div style="border:2px solid #c0392b;padding:8px 12px;margin:10px 0;background:#fdecea">')
    [void]$html.Append(('<h2 style="color:#c0392b;margin-top:0">Обновлено несмотря на гейт: проверить работоспособность</h2><p>{0}.</p>' -f (ConvertTo-Html ($gateRisks -join '; '))))
    if ($riskReason) { [void]$html.Append(('<p>Причина выпуска: {0}</p>' -f (ConvertTo-Html $riskReason))) }
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
$downtimeReport = Get-ProdDowntimeText
if ($downtimeReport) { [void]$html.Append(('<p>{0}.</p>' -f (ConvertTo-Html $downtimeReport))) }
if ($null -ne $plainLogin) { [void]$html.Append(('<p>Вход без кода разрешения после снятия блокировок: [{0}] {1}.</p>' -f $plainLogin.Status, (ConvertTo-Html $plainLogin.Text))) }
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
    # ** Хлебников С.Ю. 20261120 База уже открыта (#24): сбой выгрузки или чтения хеш-сумм исход обновления не меняет.
    try {
        if ($mode -ne 'asis') { foreach ($entry in $selected) { $null = Update-Mirror -BaseName $script:ProdBase -Extension $entry.Name } }
        # Хеш-суммы рабочей после обновления: следующий запуск по ним увидит ручную загрузку («как есть»).
        if ($selected.Count -gt 0) { Save-MirrorHashes -Names @($selected | ForEach-Object { $_.Name }) }
    }
    catch {
        Write-Line ("[WARN] Выгрузка {0} после обновления не получилась: {1}. Обновление остаётся; следующее сравнение выгрузит рабочую заново." -f $script:ProdBase, $_.Exception.Message) 'Yellow'
    }
    # ** Хлебников С.Ю. 20261120 конец
}

# Обновили подготовленным или откатили его - подготовки больше нет. Не прошло и не откатывали - остаётся:
# «Обновить подготовленным» можно повторить, подготовку - отменить.
# Откат прошёл не полностью - подготовка остаётся с отметкой: следующий запуск покажет, что рабочую надо восстановить (#10).
if ($mode -eq 'prepared' -and $outcome -eq 'rollbackFailed' -and (Test-Path -LiteralPath $preparedPath)) { Set-PreparedRollbackFailed -Items @($script:RollbackResults) }
if ($mode -eq 'prepared' -and $outcome -ne 'failed' -and $outcome -ne 'rollbackFailed' -and (Test-Path -LiteralPath $preparedPath)) { Remove-Item -LiteralPath $preparedPath -Force }
# Восстановление после неполного отката подготовленного прошло: подготовки больше нет.
if ($mode -eq 'rollback' -and $outcome -eq 'updated' -and $null -ne $prepared -and (Get-PreparedRollbackFailedText $prepared) -and (Test-Path -LiteralPath $preparedPath)) {
    Remove-Item -LiteralPath $preparedPath -Force
    Write-Line ("  подготовка {0} после восстановления снята" -f $script:ProdBase) 'DarkGray'
}

Clear-ProdLocks

if ($outcome -eq 'updated') {
    # ** Хлебников С.Ю. 20261120 «Обновить все» больше не принимает прогон в эталон молча (после снятия блокировок:
    # вопрос может ждать ответа долго, а пользователи и регламентные задания ждать не должны). Выпуск несмотря на гейт -
    # эталон не трогается: падения останутся новыми, пока их не исправят или не примут вручную. Жёлтый, ещё не
    # принятый - вопрос, по умолчанию «не принимать». Зелёный - как раньше (нового в нём нет).
    if ($mode -eq '1' -and $null -ne $lastRun) {
        $lastVerdictText = [string](Get-JsonValue $lastVerdict 'verdict' '')
        $lastAccepted = Test-Path -LiteralPath (Join-Path $lastRun.FullName 'accepted.txt')
        if ($riskAccepted) {
            Write-Line ("Эталон не тронут: обновлено несмотря на гейт, новое прогона {0} останется новым, пока его не исправят или не примут вручную (меню гейта)." -f $lastRun.Name) 'Yellow'
        }
        elseif ($lastVerdictText -eq 'YELLOW' -and -not $lastAccepted) {
            $acceptNow = Confirm-Ui -Question ("Принять новое прогона {0} (жёлтый) в эталон? Тогда следующий прогон будет считать его известным. Что внутри - report.txt прогона." -f $lastRun.Name) -Yes 'Принять в эталон' -No 'Не принимать' -DefaultNo
            if ($acceptNow -eq $true) {
                Write-Line ("Принимаю новое прогона {0} в эталон." -f $lastRun.Name)
                & (Join-Path $Root 'run.ps1') -AcceptBaseline $lastRun.FullName @childConfig
            }
            else { Write-Line ("Эталон не тронут: новое прогона {0} останется новым." -f $lastRun.Name) }
        }
        elseif ($lastVerdictText -eq 'GREEN' -and -not $lastAccepted) {
            & (Join-Path $Root 'run.ps1') -AcceptBaseline $lastRun.FullName @childConfig
        }
    }
    # Отметка в папке прогона: его комплект выпущен в рабочую этим обновлением (вердикт прогона не меняется).
    if ($null -ne $lastRun -and $mode -ne 'rollback') {
        $releasedLine = ("time={0}`tdeploy={1}`tbase={2}`tmode={3}`tuser={4}`triskAccepted={5}`treason={6}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $runId, $script:ProdBase, $mode, $env:USERNAME, [int][bool]$riskAccepted, ($riskReason -replace '[\t\r\n]+', ' '))
        try { [System.IO.File]::AppendAllText((Join-Path $lastRun.FullName 'released.txt'), $releasedLine + "`r`n", $Utf8Bom) }
        catch { Write-Line ("Отметка выпуска в прогоне {0} не записалась: {1}" -f $lastRun.Name, $_.Exception.Message) 'Yellow' }
        # Разбор прогона - заново: в шапке report.txt появится строка выпуска.
        try { & (Join-Path $Root 'report.ps1') -RunDir $lastRun.FullName -Quiet | Out-Null }
        catch { Write-RunLog ('report.txt прогона не пересобран: ' + $_.Exception.Message) }
    }
    # ** Хлебников С.Ю. 20261120 конец
}

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add($reportTitle)
$summary.Add(('Итог: ' + $outcomeNames[$outcome]))
if ($riskAccepted) { $summary.Add(('Несмотря на гейт: ' + ($gateRisks -join '; '))) }
if ($riskReason) { $summary.Add(('Причина выпуска: ' + $riskReason)) }
$summary.Add(('Расширения: ' + (@($selected | ForEach-Object { $_.Name }) -join ', ')))
if ($selectedProcessings.Count -gt 0) { $summary.Add(('Внешние обработки: ' + (@($touchedProcessings | ForEach-Object { $_.ObjName }) -join ', '))) }
foreach ($item in $light) { $summary.Add(('[{0}] {1}: {2}' -f $item.Status, $item.Name, $item.Text)) }
$downtimeLine = Get-ProdDowntimeText
if ($downtimeLine) { $summary.Add($downtimeLine) }
if ($null -ne $plainLogin) { $summary.Add(('[{0}] Вход без кода разрешения: {1}' -f $plainLogin.Status, $plainLogin.Text)) }
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
if ($null -ne $lastRun) {
    # ** Хлебников С.Ю. 20261120 Связь «вход - прогон - установка»: откуда комплект (полный коммит), что проверено, что выпущено.
    $recordGate = [ordered]@{ run = $lastRun.Name; verdict = [string](Get-JsonValue $lastVerdict 'verdict' ''); kitSource = [string](Get-JsonValue $lastVerdict 'kitSource' ''); checkedNote = $checkedNote
        installed = @(foreach ($entry in $selected) { $installedHash = ''; if ($mode -eq 'asis') { $installedHash = '' } elseif ($mode -eq 'prepared') { $installedHash = [string](Get-JsonValue $preparedByName[$entry.Name] 'tempHash' '') } elseif ($null -ne $tempStates -and $tempStates.Ok -and $tempStates.Items.ContainsKey($entry.Name)) { $installedHash = [string]$tempStates.Items[$entry.Name].Hash }; [ordered]@{ name = $entry.Name; hash = $installedHash } }) }
}
$record = [ordered]@{
    runId        = $runId
    time         = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    base         = $script:ProdBase
    target       = $deployTarget.Identity
    tempBase     = $script:TempBase
    user         = $env:USERNAME
    mode         = $mode
    outcome      = $outcome
    rollbackOf   = $rollbackOf
    preparedRun  = $preparedRunId
    gate         = $recordGate
    riskAccepted = $riskAccepted
    risks        = @($gateRisks)
    riskReason   = $riskReason
    extensions   = $recordExtensions
    processings  = $recordProcessings
    light        = @(foreach ($item in $light) { [ordered]@{ status = $item.Status; name = $item.Name; text = $item.Text } })
    article      = $articleFile
}
# ** Хлебников С.Ю. 20261120 Простой и вход без кода разрешения (#24, #2) - в запись об обновлении.
if ($null -ne $script:ProdClosedAt -and $null -ne $script:ProdOpenedAt) {
    $record['closedAt'] = ([datetime]$script:ProdClosedAt).ToString('yyyy-MM-ddTHH:mm:ss')
    $record['openedAt'] = ([datetime]$script:ProdOpenedAt).ToString('yyyy-MM-ddTHH:mm:ss')
    $record['downtimeSec'] = [int][Math]::Max(0, ([datetime]$script:ProdOpenedAt - [datetime]$script:ProdClosedAt).TotalSeconds)
}
if ($null -ne $plainLogin) { $record['plainLogin'] = [ordered]@{ status = $plainLogin.Status; text = $plainLogin.Text } }
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
if ($null -ne $plainLogin -and $plainLogin.Status -eq 'FAIL') {
    Write-Line ("ВХОД В {0} БЕЗ КОДА РАЗРЕШЕНИЯ НЕ ПРОШЁЛ: {1}." -f $script:ProdBase, $plainLogin.Text) 'Red'
}
if ($riskAccepted -and $outcome -eq 'updated') {
    Write-Line ("ПРОВЕРИТЬ РАБОТОСПОСОБНОСТЬ: обновлено, хотя {0}." -f ($gateRisks -join '; ')) 'Red'
    if ($riskReason) { Write-Line ("  причина выпуска: {0}" -f $riskReason) 'Red' }
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
        if ($UiChannel) { & (Join-Path $Root 'run.ps1') -Kit $kitDir -UiChannel $UiChannel @childConfig } else { & (Join-Path $Root 'run.ps1') -Kit $kitDir @childConfig }
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
}
finally { if ($null -ne $deployGuard) { $deployGuard.Dispose() } }
