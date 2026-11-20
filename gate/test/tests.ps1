#requires -Version 5.1
<#
Тесты гейта без 1С. Версия 00000000.000000.

Каждый тест - отдельная песочница в %TEMP%\ci-tests\<время>\<тест>: копия скриптов гейта, свой config.psd1,
свой inbox. Вместо 1cv8.exe и 1cv8c.exe - подставная 1С (fake1c.exe): она отвечает так, как велит сценарий
теста, и записывает каждый вызов. Тест запускает run.ps1 так же, как ci.exe (ключ -UiChannel), и сам
отвечает на вопросы скрипта. Потом сверяет код возврата, verdict.json, шаги, файлы и вызовы 1С.

Запуск:  powershell -ExecutionPolicy Bypass -File test\tests.ps1
         ... -Only epf      только тесты, в имени которых есть «epf»
         ... -Keep          не удалять песочницы (для разбора)
         ... -Extra <файл>  добавить тесты площадки (приватный репозиторий)
Итог - в консоли и в test\last-run.txt: его и присылать.
#>
param(
    [string]$Only = '',
    [switch]$Keep,
    [int]$TimeoutSec = 300,
    # Тесты площадки из приватного репозитория: файл, который возвращает массив тестов в том же виде.
    [string]$Extra = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$ciRoot = Split-Path -Parent $here
$fakeExe = Join-Path $here 'fake1c.exe'
if (-not (Test-Path -LiteralPath $fakeExe)) { throw "Нет подставной 1С: $fakeExe" }
$workRoot = Join-Path $env:TEMP ('ci-tests\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$report = New-Object System.Collections.Generic.List[string]

#region Песочница

function ConvertTo-Psd1 {
    # Значение для config.psd1: строки, числа, логические, массивы и таблицы.
    param($Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
    if ($Value -is [hashtable]) {
        $parts = @($Value.Keys | ForEach-Object { '{0} = {1}' -f $_, (ConvertTo-Psd1 $Value[$_]) })
        return '@{ ' + ($parts -join '; ') + ' }'
    }
    if ($Value -is [array]) { return '@(' + (@($Value | ForEach-Object { ConvertTo-Psd1 $_ }) -join ', ') + ')' }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function New-Sandbox {
    # Папка теста: скрипты гейта, подставная 1С в bin, пустые обработки в tools, inbox, config.psd1.
    param([string]$Name, [hashtable]$Config = @{})
    $dir = Join-Path $workRoot $Name
    foreach ($sub in @('bin', 'tools', 'inbox', 'fake')) { New-Item -ItemType Directory -Path (Join-Path $dir $sub) -Force | Out-Null }
    foreach ($script in @('run.ps1', 'ui.ps1', 'stats.ps1', 'report.ps1', 'deploy.ps1', 'settings.ps1', 'nightly.ps1', 'unittests.ps1', 'unittests-cli.ps1', 'update.ps1', 'publish.ps1', 'github.ps1', 'delivery.ps1', 'cluster-target.ps1', 'locks.ps1')) {
        Copy-Item -LiteralPath (Join-Path $ciRoot $script) -Destination $dir
    }
    # Объединение поставок (раздел 5.25): merge1c.exe рядом с fake1c.exe (собирает CI).
    foreach ($mergeExe in @((Join-Path $here 'merge1c.exe'), (Join-Path $ciRoot 'merge1c.exe'))) {
        if (Test-Path -LiteralPath $mergeExe) { Copy-Item -LiteralPath $mergeExe -Destination $dir; break }
    }
    # Подставной COM для deploy.ps1: скрипт берёт его из test\ рядом с собой, когда задан CI_FAKE_COM.
    New-Item -ItemType Directory -Path (Join-Path $dir 'test') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $here 'fakecom.ps1') -Destination (Join-Path $dir 'test')
    Copy-Item -LiteralPath $fakeExe -Destination (Join-Path $dir 'bin\1cv8.exe')
    Copy-Item -LiteralPath $fakeExe -Destination (Join-Path $dir 'bin\1cv8c.exe')
    # Гейт проверяет только, что файлы обработок есть: открывает их подставная 1С, ей всё равно.
    [System.IO.File]::WriteAllText((Join-Path $dir 'tools\ВыполнитьПослеОбновления.epf'), 'fake', $utf8)
    [System.IO.File]::WriteAllText((Join-Path $dir 'tools\Канарейка.epf'), 'fake', $utf8)

    $settings = [ordered]@{
        File = (Join-Path $dir 'erp_temp_test')
        V8Bin = (Join-Path $dir 'bin')
        Extensions = @('Адаптация', 'Доработки')
        ForbiddenBases = @('erp_base')
        CanaryUsers = @(@{ Name = '' })
        CanaryWaitSec = 0
        CanaryTimeoutSec = 30
        SelfCheckStartTimeoutSec = 30
        SelfCheckStallMin = 1
        SelfCheckTimeoutMin = 3
        ProcessingTimeoutSec = 30
        TimeoutLoadMin = 2
        TimeoutUpdateMin = 2
        TimeoutCheckMin = 2
    }
    foreach ($key in $Config.Keys) { $settings[$key] = $Config[$key] }
    $lines = @('@{') + @($settings.Keys | ForEach-Object { '    {0} = {1}' -f $_, (ConvertTo-Psd1 $settings[$_]) }) + @('}')
    [System.IO.File]::WriteAllLines((Join-Path $dir 'config.psd1'), [string[]]$lines, $utf8Bom)
    New-Item -ItemType Directory -Path (Join-Path $dir 'erp_temp_test') -Force | Out-Null
    return $dir
}

function Add-InboxFile {
    # Файл обновления в inbox песочницы. Содержимое гейту не важно: грузит его подставная 1С.
    param([string]$Sandbox, [string]$Name, [string]$Text = 'fake')
    $path = Join-Path (Join-Path $Sandbox 'inbox') $Name
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $Text, $utf8Bom)
    return $path
}

function Reset-FakeState {
    # Между прогонами одной песочницы: счётчики сценария подставной 1С и журнал её вызовов - с нуля.
    param([string]$Sandbox)
    foreach ($name in @('fake1c-state.json', 'calls.log')) {
        $path = Join-Path (Join-Path $Sandbox 'fake') $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

#endregion

#region Запуск скрипта и ответы на вопросы

function Find-Answer {
    # Ответ на вопрос скрипта: первое неиспользованное правило с тем же видом и подходящим заголовком.
    # Правило: Kind, Header (регулярное выражение), и одно из Item (номер первого пункта, подходящего
    # под выражение), Index, Indexes, Yes, Text, Cancel. Wait - не отвечать: вопрос с проверкой (Poll)
    # снимет сам скрипт.
    param($Question, $Rules, $Used)
    for ($i = 0; $i -lt $Rules.Count; $i++) {
        if ($Used.Contains($i)) { continue }
        $rule = $Rules[$i]
        if ($rule.Kind -ne $Question.kind) { continue }
        if ($rule.ContainsKey('Header') -and ([string]$Question.header) -notmatch $rule.Header) { continue }
        [void]$Used.Add($i)
        $answer = @{}
        if ($rule.ContainsKey('Wait')) { return @{ wait = $true } }
        if ($rule.ContainsKey('Cancel')) { $answer['cancel'] = $true }
        if ($rule.ContainsKey('Item')) {
            $items = @($Question.items)
            $answer['index'] = -1
            for ($k = 0; $k -lt $items.Count; $k++) { if ([string]$items[$k] -match $rule.Item) { $answer['index'] = $k; break } }
        }
        if ($rule.ContainsKey('Index')) { $answer['index'] = $rule.Index }
        if ($rule.ContainsKey('Indexes')) { $answer['indexes'] = @($rule.Indexes) }
        if ($rule.ContainsKey('Yes')) { $answer['yes'] = [bool]$rule.Yes }
        if ($rule.ContainsKey('Text')) { $answer['text'] = [string]$rule.Text }
        return $answer
    }
    return $null
}

function Invoke-Script {
    # Запускает скрипт гейта в песочнице, как ci.exe: вывод читается построчно, на вопросы @@ui отвечают правила.
    # Com - состояние подставного COM (test\fakecom.ps1) для deploy.ps1; $null - без него. Состояние после
    # прогона и строки com.log - в ответе (ComState, ComLog); повторный запуск с $null продолжает то же состояние.
    param([string]$Sandbox, [string]$Script = 'run.ps1', [string]$Arguments = '', [hashtable]$Fake = @{}, $Answers = @(), $Com = $null)
    $channel = Join-Path $Sandbox 'chan'
    New-Item -ItemType Directory -Path $channel -Force | Out-Null
    $scenarioFile = Join-Path $Sandbox 'fake\scenario.json'
    [System.IO.File]::WriteAllText($scenarioFile, (ConvertTo-Json -InputObject $Fake -Depth 10), $utf8)
    $callsFile = Join-Path $Sandbox 'fake\calls.log'
    $comFile = Join-Path $Sandbox 'fake\com.json'
    if ($null -ne $Com) { [System.IO.File]::WriteAllText($comFile, (ConvertTo-Json -InputObject $Com -Depth 10), $utf8) }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = 'powershell.exe'
    $info.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" {1} -UiChannel "{2}"' -f (Join-Path $Sandbox $Script), $Arguments, $channel)
    $info.WorkingDirectory = $Sandbox
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    $info.EnvironmentVariables['CI_FAKE_SCENARIO'] = $scenarioFile
    $info.EnvironmentVariables['CI_FAKE_LOG'] = $callsFile
    if (Test-Path -LiteralPath $comFile) { $info.EnvironmentVariables['CI_FAKE_COM'] = $comFile }
    # Подставной GitHub для update.ps1: папка fake-http песочницы (ответы - файлами по адресам).
    $httpDir = Join-Path $Sandbox 'fake-http'
    if (Test-Path -LiteralPath $httpDir) { $info.EnvironmentVariables['CI_FAKE_HTTP'] = $httpDir }
    # Подставной GitHub для репозитория расширений (github.ps1): папка fake-github песочницы.
    $githubDir = Join-Path $Sandbox 'fake-github'
    if (Test-Path -LiteralPath $githubDir) { $info.EnvironmentVariables['CI_FAKE_GITHUB'] = $githubDir }
    $process = [System.Diagnostics.Process]::Start($info)
    $errorTask = $process.StandardError.ReadToEndAsync()

    $lines = New-Object System.Collections.Generic.List[string]
    $questions = New-Object System.Collections.Generic.List[string]
    $unexpected = New-Object System.Collections.Generic.List[string]
    $used = New-Object System.Collections.Generic.HashSet[int]
    $rules = @($Answers)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    while ($true) {
        $read = $process.StandardOutput.ReadLineAsync()
        while (-not $read.Wait(500)) {
            if ($watch.Elapsed.TotalSeconds -gt $TimeoutSec) { $timedOut = $true; break }
        }
        if ($timedOut) { break }
        $line = $read.Result
        if ($null -eq $line) { break }
        $lines.Add($line)
        if (-not $line.StartsWith('@@ui:')) { continue }
        $message = $null
        try { $message = $line.Substring(5) | ConvertFrom-Json } catch { continue }
        if (@('one', 'many', 'confirm', 'text', 'view') -notcontains [string]$message.kind) { continue }
        $questions.Add(('{0}: {1}' -f $message.kind, $message.header))
        $answer = $null
        if ($message.kind -eq 'view') { $answer = @{} }
        else { $answer = Find-Answer -Question $message -Rules $rules -Used $used }
        if ($null -eq $answer) {
            $unexpected.Add(('{0}: {1}' -f $message.kind, $message.header))
            $answer = @{ cancel = $true }
        }
        if ($answer.ContainsKey('wait')) { continue }
        $answerFile = Join-Path $channel ('a-{0}.json' -f $message.id)
        [System.IO.File]::WriteAllText($answerFile + '.tmp', (ConvertTo-Json -InputObject $answer -Compress), $utf8)
        Move-Item -LiteralPath ($answerFile + '.tmp') -Destination $answerFile -Force
    }
    if ($timedOut) {
        try { $process.Kill() } catch { }
        # Подставная 1С могла остаться висеть.
        Get-Process -Name '1cv8', '1cv8c' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Sandbox) } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    $process.WaitForExit(30000) | Out-Null
    $stderr = ''
    if ($errorTask.Wait(5000)) { $stderr = $errorTask.Result }
    [System.IO.File]::WriteAllLines((Join-Path $Sandbox 'output.txt'), $lines.ToArray(), $utf8Bom)

    $calls = @()
    if (Test-Path -LiteralPath $callsFile) {
        $calls = @([System.IO.File]::ReadAllLines($callsFile, $utf8) | ForEach-Object {
                $parts = $_.Split("`t")
                # Time - когда вызов закончился (подставная 1С пишет строку перед выходом), ЧЧ:мм:сс.мс.
                [pscustomobject]@{ Time = $parts[0]; Mode = $parts[1]; Code = [int]$parts[2]; Line = $parts[3] }
            })
    }
    $runDir = ''
    $verdict = $null
    $runs = Join-Path $Sandbox 'runs'
    if (Test-Path -LiteralPath $runs) {
        $last = @(Get-ChildItem -LiteralPath $runs -Directory | Sort-Object Name | Select-Object -Last 1)
        if ($last.Count -gt 0) {
            $runDir = $last[0].FullName
            $verdictFile = Join-Path $runDir 'verdict.json'
            if (Test-Path -LiteralPath $verdictFile) { $verdict = [System.IO.File]::ReadAllText($verdictFile, $utf8) | ConvertFrom-Json }
        }
    }
    $exitCode = $null
    if ($process.HasExited) { $exitCode = $process.ExitCode }
    $comState = $null
    $comLog = @()
    if (Test-Path -LiteralPath $comFile) { $comState = [System.IO.File]::ReadAllText($comFile, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json }
    $comLogFile = Join-Path $Sandbox 'fake\com.log'
    if (Test-Path -LiteralPath $comLogFile) { $comLog = @([System.IO.File]::ReadAllLines($comLogFile, $utf8)) }
    return [pscustomobject]@{
        Sandbox = $Sandbox; ExitCode = $exitCode; TimedOut = $timedOut; Output = $lines.ToArray(); Stderr = $stderr
        Questions = $questions.ToArray(); Unexpected = $unexpected.ToArray(); UnusedAnswers = ($rules.Count - $used.Count)
        Calls = $calls; RunDir = $runDir; Verdict = $verdict; Seconds = [int]$watch.Elapsed.TotalSeconds
        ComState = $comState; ComLog = $comLog
    }
}

#endregion

#region Проверки

$script:Failures = New-Object System.Collections.Generic.List[string]

function Check {
    param([bool]$Condition, [string]$Text)
    if (-not $Condition) { $script:Failures.Add($Text) }
}

function Get-Step {
    # Шаг из verdict.json по началу имени.
    param($Result, [string]$Name)
    if ($null -eq $Result.Verdict) { return $null }
    return @($Result.Verdict.steps | Where-Object { ([string]$_.name).StartsWith($Name) } | Select-Object -First 1)[0]
}

function Check-Step {
    param($Result, [string]$Name, [string]$Status)
    $step = Get-Step $Result $Name
    if ($null -eq $step) { Check $false ("нет шага «{0}»" -f $Name); return }
    Check ($step.status -eq $Status) ("шаг «{0}»: {1}, ждали {2} ({3})" -f $Name, $step.status, $Status, $step.detail)
}

function Get-Calls {
    # Вызовы подставной 1С, в строке которых есть все слова.
    param($Result, [string[]]$Words)
    # Запятая: иначе PowerShell развернёт массив из одного вызова в сам вызов, и .Count под StrictMode упадёт.
    return , @($Result.Calls | Where-Object { $call = $_; @($Words | Where-Object { -not $call.Line.Contains($_) }).Count -eq 0 })
}

function Check-Common {
    # То, что верно для любого прогона: дошёл до конца, не упал, не задал вопросов, которых тест не ждал,
    # разбор прогона получился, удаление расширений - только по одному имени.
    param($Result)
    Check (-not $Result.TimedOut) ("не уложился в {0} с" -f $TimeoutSec)
    Check ($Result.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($Result.Unexpected -join ' | '))
    Check ($Result.UnusedAnswers -eq 0) ("тест ждал вопросов, а их не было: {0}" -f $Result.UnusedAnswers)
    # Авария скрипта: run.ps1 и deploy.ps1 пишут «Остановлено: <текст>» из trap; разбор прогона - свою строку.
    $crash = @($Result.Output | Where-Object { $_ -match '^Остановлено: |Разбор прогона не получился|ParserError' })
    Check ($crash.Count -eq 0) ("в выводе ошибка скрипта: " + (($crash | Select-Object -First 3) -join ' | '))
    Check ([string]::IsNullOrWhiteSpace($Result.Stderr)) ("stderr: " + ([string]$Result.Stderr).Trim())
    $deleteAll = @($Result.Calls | Where-Object { $_.Line.Contains('/DeleteCfg') -and $_.Line.Contains('-AllExtensions') })
    Check ($deleteAll.Count -eq 0) 'удаление всех расширений (-AllExtensions) - так нельзя никогда'
    $prod = @($Result.Calls | Where-Object { $_.Line -match 'erp_base(?!_)' })
    Check ($prod.Count -eq 0) 'гейт обратился к рабочей базе erp_base'
    if ($Result.RunDir) { Check (Test-Path -LiteralPath (Join-Path $Result.RunDir 'report.txt')) 'нет report.txt' }
}

function Check-DeployCommon {
    # То, что верно для любого запуска deploy.ps1: дошёл до конца, не упал, вопросы - только ожидаемые,
    # удаление расширений - только по имени, блокировки рабочей в конце сняты (если их ставил скрипт).
    param($Result, [bool]$LocksExpected = $true)
    Check (-not $Result.TimedOut) ("не уложился в {0} с" -f $TimeoutSec)
    Check ($Result.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($Result.Unexpected -join ' | '))
    Check ($Result.UnusedAnswers -eq 0) ("тест ждал вопросов, а их не было: {0}" -f $Result.UnusedAnswers)
    $crash = @($Result.Output | Where-Object { $_ -match '^Остановлено: |ParserError' })
    Check ($crash.Count -eq 0) ("в выводе ошибка скрипта: " + (($crash | Select-Object -First 3) -join ' | '))
    Check ([string]::IsNullOrWhiteSpace($Result.Stderr)) ("stderr: " + ([string]$Result.Stderr).Trim())
    $deleteAll = @($Result.Calls | Where-Object { $_.Line.Contains('/DeleteCfg') -and $_.Line.Contains('-AllExtensions') })
    Check ($deleteAll.Count -eq 0) 'удаление всех расширений (-AllExtensions) - так нельзя никогда'
    # Подставной COM отвечает всегда: «не прочитал» и «не выгрузил» - ошибка в самом скрипте или в подставном COM.
    $comErrors = @($Result.Output | Where-Object { $_ -match ': не прочитал - |: не выгрузил - ' })
    Check ($comErrors.Count -eq 0) ("внешнее соединение не сработало: " + (($comErrors | Select-Object -First 2) -join ' | '))
    if ($LocksExpected -and $null -ne $Result.ComState) {
        $prod = $Result.ComState.bases.erp_base
        Check (-not [bool]$prod.scheduledJobsDenied) 'в конце осталась блокировка регламентных заданий рабочей'
        Check (-not [bool]$prod.sessionsDenied) 'в конце осталась блокировка начала сеансов рабочей'
    }
}

function Get-DeployRecord {
    # deploy.json последнего запуска deploy.ps1 в песочнице.
    param([string]$Sandbox)
    $root = Join-Path $Sandbox 'deploy'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending)) {
        $file = Join-Path $dir.FullName 'deploy.json'
        if (Test-Path -LiteralPath $file) {
            $record = [System.IO.File]::ReadAllText($file, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            $record | Add-Member -NotePropertyName Dir -NotePropertyValue $dir.FullName -Force
            return $record
        }
    }
    return $null
}

function Check-Verdict {
    param($Result, [string]$Verdict, [int]$ExitCode)
    if ($null -eq $Result.Verdict) { Check $false 'нет verdict.json'; return }
    Check ($Result.Verdict.verdict -eq $Verdict) ("вердикт {0}, ждали {1}" -f $Result.Verdict.verdict, $Verdict)
    Check ($Result.ExitCode -eq $ExitCode) ("код возврата {0}, ждали {1}" -f $Result.ExitCode, $ExitCode)
}

#endregion

#region Сценарии

$cfeName = 'erp_temp_Адаптация_20261117.cfe'
$errorTasks = @(
    @{ key = 'Окружение'; title = 'Окружение и расширения'; step = 'Окружение'; lines = @('[ОК] Обработка запущена под полными правами') },
    @{ key = 'КомпиляцияМодулей/ОбщийМодуль|Адаптация_ОбщийСервер'; title = 'ОбщийМодуль.Адаптация_ОбщийСервер'; step = 'КомпиляцияМодулей'; lines = @('[ОШИБКА] ОбщийМодуль.Адаптация_ОбщийСервер: не компилируется: тест') }
)
$epfDump = '<?xml version="1.0" encoding="UTF-8"?><MetaDataObject><ExternalDataProcessor uuid="1"><Properties><Name>Печать</Name></Properties></ExternalDataProcessor></MetaDataObject>'

# Сообщение обмена для снимка: заголовок с полями, которые меняются при каждой выгрузке, и тело.
function New-ExchangeMessage {
    param([string]$Created, [int]$Number, [string]$Sum)
    return ('<Message xmlns:msg="http://www.1c.ru/SSL/Exchange/Message"><msg:Header><msg:Format>EnterpriseData/1.8</msg:Format>' +
        '<msg:CreationDate>{0}</msg:CreationDate><msg:MessageNo>{1}</msg:MessageNo><msg:ReceivedNo>{2}</msg:ReceivedNo></msg:Header>' +
        '<Body xmlns="EnterpriseData/1.8"><Документ.РеализацияТоваровУслуг><Сумма>{3}</Сумма><Номер>АА-1</Номер></Документ.РеализацияТоваровУслуг></Body></Message>') -f $Created, $Number, ($Number - 1), $Sum
}
function New-ExchangeTasks {
    param([string]$Message)
    return @(
        @{ key = 'Окружение'; title = 'Окружение и расширения'; step = 'Окружение'; lines = @('[ОК] Обработка запущена под полными правами') },
        @{ key = 'Обмены'; title = 'Обмены'; step = 'Обмены'; lines = @('[ОК] Бухгалтерия: Документ.РеализацияТоваровУслуг выгружается');
            snapshots = @{ 'обмен|Бухгалтерия|Документ.РеализацияТоваровУслуг|11111111-2222-3333-4444-555555555555' = $Message } }
    )
}

# Карта покрытия: выгрузка Адаптация (заимствованные документы с перехватами) и самопроверка, задевающая ЗаказКлиента.
function New-AdoptedDocument {
    param([string]$Name)
    return ('<MetaDataObject><Document><Properties><ObjectBelonging>Adopted</ObjectBelonging><Name>{0}</Name></Properties></Document></MetaDataObject>' -f $Name)
}
$coverageTasks = @(
    @{ key = 'Окружение'; title = 'Окружение и расширения'; step = 'Окружение'; lines = @('[ОК] Обработка запущена под полными правами') },
    @{ key = 'ОперацииСДокументами|Документ.ЗаказКлиента'; title = 'Операции: ЗаказКлиента'; step = 'ОперацииСДокументами'; lines = @('[ОК] Документ.ЗаказКлиента: новый, проверка заполнения, запись копии') }
)
$coverageDumpFirst = @{
    'Documents/ЗаказКлиента.xml' = (New-AdoptedDocument 'ЗаказКлиента')
    'Documents/ЗаказКлиента/Ext/ObjectModule.bsl' = "&После(`"ОбработкаПроведения`")`nПроцедура Адаптация_ОбработкаПроведения(Отказ, РежимПроведения)`nКонецПроцедуры"
}
$coverageDumpSecond = @{
    'Documents/ЗаказКлиента.xml' = (New-AdoptedDocument 'ЗаказКлиента')
    'Documents/ЗаказКлиента/Ext/ObjectModule.bsl' = "&После(`"ОбработкаПроведения`")`nПроцедура Адаптация_ОбработкаПроведения(Отказ, РежимПроведения)`nКонецПроцедуры"
    'Documents/РеализацияТоваровУслуг.xml' = (New-AdoptedDocument 'РеализацияТоваровУслуг')
    'Documents/РеализацияТоваровУслуг/Ext/ObjectModule.bsl' = "&Вместо(`"ПередЗаписью`")`nПроцедура Адаптация_ПередЗаписью(Отказ, РежимЗаписи, РежимПроведения)`nКонецПроцедуры"
    'ScheduledJobs/Адаптация_Чистка.xml' = '<MetaDataObject><ScheduledJob><Properties><Name>Адаптация_Чистка</Name><MethodName>CommonModule.Адаптация_Сервер.Чистка</MethodName></Properties></ScheduledJob></MetaDataObject>'
}

# Модульные тесты YAxUnit: выгрузка тестового расширения «Тесты» в файлах (папка tests\Тесты песочницы или любая).
$unitModuleClean = @(
    '#Область СлужебныйПрограммныйИнтерфейс', '',
    'Процедура ИсполняемыеСценарии() Экспорт', '',
    '	ЮТТесты',
    '		.ДобавитьТест("Сложение", "Сложение двух чисел", "быстрый")',
    '		.ДобавитьТест("Вычитание", "Вычитание");', '',
    'КонецПроцедуры', '',
    '#КонецОбласти', '',
    '#Область Тесты', '',
    '// @Тест Сложение двух чисел',
    '// @Проверяет CommonModule.Пример.Сложить',
    '// @Как складываем 2 и 2,',
    '//   сравниваем с 4',
    '// @Зачем арифметика должна работать',
    '// @Автор Тестов А.Б. 20261118',
    '// @Теги быстрый',
    'Процедура Сложение() Экспорт',
    '	ЮТест.ОжидаетЧто(2 + 2).Равно(4); // «//» в строке "http://x" - не комментарий',
    'КонецПроцедуры', '',
    '// @Тест Вычитание',
    '// @Проверяет CommonModule.Пример.Вычесть',
    '// @Как вычитаем',
    '// @Зачем чтобы было',
    '// @Автор Тестов А.Б. 20261118',
    'Процедура Вычитание() Экспорт',
    '	ЮТест.ОжидаетЧто(4 - 2).Равно(2);',
    'КонецПроцедуры', '',
    '#КонецОбласти') -join "`r`n"

function Add-UnitTestSource {
    # Выгрузка расширения «Тесты» в файлах: подсистема Тесты_Общие, модуль ОМ_Пример. Dir - корень (tests песочницы).
    param([string]$Dir, [string]$Module = $unitModuleClean)
    $root = Join-Path $Dir 'Тесты'
    $ns = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.20"'
    $files = @{
        'Configuration.xml' = ('<?xml version="1.0" encoding="UTF-8"?>' + "`r`n" + '<MetaDataObject ' + $ns + '>' + "`r`n" + '	<Configuration uuid="00000000-0000-0000-0000-000000000001">' + "`r`n" +
            '		<Properties>' + "`r`n" + '			<Name>Тесты</Name>' + "`r`n" + '		</Properties>' + "`r`n" + '		<ChildObjects>' + "`r`n" + '			<Language>Русский</Language>' + "`r`n" +
            '			<Subsystem>Тесты_Общие</Subsystem>' + "`r`n" + '			<CommonModule>ОМ_Пример</CommonModule>' + "`r`n" + '		</ChildObjects>' + "`r`n" + '	</Configuration>' + "`r`n" + '</MetaDataObject>')
        'Subsystems\Тесты_Общие.xml' = ('<?xml version="1.0" encoding="UTF-8"?>' + "`r`n" + '<MetaDataObject ' + $ns + '>' + "`r`n" + '	<Subsystem uuid="00000000-0000-0000-0000-000000000002">' + "`r`n" +
            '		<Properties>' + "`r`n" + '			<Name>Тесты_Общие</Name>' + "`r`n" + '			<Synonym><v8:item><v8:lang>ru</v8:lang><v8:content>Общие</v8:content></v8:item></Synonym>' + "`r`n" +
            '			<Content>' + "`r`n" + '				<xr:Item xsi:type="xr:MDObjectRef">CommonModule.ОМ_Пример</xr:Item>' + "`r`n" + '			</Content>' + "`r`n" +
            '		</Properties>' + "`r`n" + '		<ChildObjects/>' + "`r`n" + '	</Subsystem>' + "`r`n" + '</MetaDataObject>')
        'CommonModules\ОМ_Пример.xml' = ('<?xml version="1.0" encoding="UTF-8"?>' + "`r`n" + '<MetaDataObject ' + $ns + '><CommonModule uuid="00000000-0000-0000-0000-000000000003"><Properties><Name>ОМ_Пример</Name><Server>true</Server></Properties></CommonModule></MetaDataObject>')
        'CommonModules\ОМ_Пример\Ext\Module.bsl' = $Module
    }
    foreach ($relative in $files.Keys) {
        $path = Join-Path $root $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, $files[$relative], $utf8Bom)
    }
    return $root
}

# Ответы YAxUnit подставной 1С: оба теста модуля ОМ_Пример прошли / Вычитание упало.
$unitAllOk = @{ cases = @(@{ module = 'ОМ_Пример'; method = 'Сложение'; name = 'Сложение двух чисел'; status = 'ok' }, @{ module = 'ОМ_Пример'; method = 'Вычитание'; name = 'Вычитание'; status = 'ok' }) }
$unitMinusFails = @{ cases = @(@{ module = 'ОМ_Пример'; method = 'Сложение'; name = 'Сложение двух чисел'; status = 'ok' }, @{ module = 'ОМ_Пример'; method = 'Вычитание'; name = 'Вычитание'; status = 'fail'; message = 'ожидали 2, а было 3' }) }
$unitConfig = @{ UnitTestExtensions = @('Тесты') }

# deploy.ps1: базы кластера (подставной COM), рабочая - erp_base, запретных часов нет.
$deployConfig = @{ File = ''; Server = 'fake'; Base = 'erp_temp_test'; ProdBase = 'erp_base'; DeployDeniedFrom = 0; DeployDeniedTo = 0; ComTimeoutSec = 60 }
$printOld = "Процедура Печать()`nКонецПроцедуры"
$printNew = "Процедура Печать()`nКонецПроцедуры`n`nПроцедура НоваяПроцедура()`nКонецПроцедуры"

function New-ComBase {
    # База «кластера» подставного COM: расширения Адаптация (хеш задаётся) и Доработки, обработки.
    param([string]$AdaptHash, $Processings = @(), [bool]$JobsDenied = $false)
    return @{
        scheduledJobsDenied = $JobsDenied; sessionsDenied = $false; permissionCode = ''; deniedMessage = ''
        extensions = @(@{ name = 'Адаптация'; version = '1.0.0.' + $AdaptHash; hash = $AdaptHash }, @{ name = 'Доработки'; version = '1.0.0.1'; hash = 'hd' })
        processings = @($Processings)
    }
}

function New-ComState {
    # Temp и рабочая: по умолчанию Адаптация изменена в temp, Доработки одинаковые, обработок нет.
    param([string]$TempHash = 'h2', [string]$ProdHash = 'h1', $TempProcessings = @(), $ProdProcessings = @(), $Sessions = @(), [bool]$ProdJobsDenied = $false)
    return @{
        bases = @{
            erp_temp_test = (New-ComBase -AdaptHash $TempHash -Processings $TempProcessings)
            erp_base = (New-ComBase -AdaptHash $ProdHash -Processings $ProdProcessings -JobsDenied $ProdJobsDenied)
        }
        sessions = @($Sessions)
    }
}

# Идентификатор цели erp_base подставного кластера (кластер, имя, ИБ, СУБД) - как его пишет deploy в deploy.json.
$script:ProdTargetId = '[["fake",1541,""],"erp_base","","[\"MSSQLServer\",\"fixture-db\",\"erp_base\"]"]'

function New-InterruptedLockCom {
    # Рабочая после обрыва deploy: стоит блокировка начала сеансов с кодом по умолчанию и запрет регламентных.
    param([string]$Message)
    $com = New-ComState -ProdJobsDenied $true
    $prod = $com.bases.erp_base
    $prod.sessionsDenied = $true; $prod.permissionCode = '0'; $prod.deniedMessage = $Message
    $prod.deniedFrom = '2026-11-17T22:30:00'; $prod.deniedTo = '2026-11-18T01:00:00'
    return $com
}

function Write-InterruptedLockFile {
    # locks.json запуска 20261117-230000, чей процесс уже не живёт: до него запрета не было.
    param([string]$Sandbox, [string]$Marker, [bool]$JobsSet, [string]$Target = $script:ProdTargetId)
    $dir = Join-Path $Sandbox 'deploy\20261117-230000'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $record = @{ base = 'erp_base'; target = $Target; pid = 999999; processStart = '2026-11-17T23:00:00'; marker = $Marker; jobsSet = $JobsSet
        before = @{ SessionsDenied = $false; PermissionCode = ''; DeniedMessage = ''; DeniedFrom = $null; DeniedTo = $null }
        expected = @(@{ SessionsDenied = $true; PermissionCode = '0'; DeniedMessage = ('Обновление [{0}]' -f $Marker); DeniedFrom = '2026-11-17T22:30:00.0000000'; DeniedTo = '2026-11-18T01:00:00.0000000' }) }
    [System.IO.File]::WriteAllText((Join-Path $dir 'locks.json'), (ConvertTo-Json -InputObject $record -Depth 6), $utf8)
}

function New-PrintProcessing {
    param([string]$Version, [string]$Content)
    return @{ objName = 'Печать'; title = 'Печать актов'; version = $Version; kind = 'Печатная форма'; content = $Content }
}

# Репозиторий расширений (раздел 5.23): подставной GitHub - папка fake-github песочницы, читается и
# заполняется теми же функциями github.ps1.
. (Join-Path $ciRoot 'github.ps1')

function New-GitSandbox {
    param([string]$Name, [hashtable]$Extra = @{}, [switch]$Empty)
    $config = $deployConfig.Clone()
    $config['ExtensionsRepo'] = 'owner/ext'
    foreach ($key in @($Extra.Keys)) { $config[$key] = $Extra[$key] }
    $config['GitHubTokenPassFile'] = 'secrets\github.txt'
    $sb = New-Sandbox $Name -Config $config
    New-Item -ItemType Directory -Path (Join-Path $sb 'secrets') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $sb 'secrets\github.txt'), (ConvertFrom-SecureString -SecureString (ConvertTo-SecureString 'tok-git' -AsPlainText -Force)))
    New-Item -ItemType Directory -Path (Join-Path $sb 'fake-github') -Force | Out-Null
    if (-not $Empty) {
        $gh = Get-FakeGh $sb
        $file = [pscustomobject]@{ Path = 'README.md'; Bytes = $utf8.GetBytes('Начальный коммит владельца') }
        $seed = New-GhCommit -Gh $gh -Parent '' -Changes @($file) -Message 'Репозиторий для теста'
        Set-GhBranch -Gh $gh -Branch 'main' -Sha $seed -Create
    }
    return $sb
}

function Get-FakeGh {
    param([string]$Sandbox)
    $env:CI_FAKE_GITHUB = Join-Path $Sandbox 'fake-github'
    try { return New-GhContext -Repo 'owner/ext' -Token '' } finally { Remove-Item -Path 'env:CI_FAKE_GITHUB' }
}

function Read-GitStateFile {
    param([string]$Sandbox)
    return ([System.IO.File]::ReadAllText((Join-Path $Sandbox 'git\ext\state.json'), $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json)
}

function New-GitDumps {
    # Выгрузки подставной 1С: модуль Адаптации и модуль Доработок.
    param([string]$Adapt = 'Процедура Старая() КонецПроцедуры', [string]$Extra = 'Процедура Д() КонецПроцедуры')
    return @{ 'Адаптация' = @{ 'CommonModules/АГБ_Общий/Ext/Module.bsl' = $Adapt }; 'Доработки' = @{ 'CommonModules/Д/Ext/Module.bsl' = $Extra } }
}

$gitBootstrapAnswers = @(
    @{ Kind = 'many'; Header = 'Первая выгрузка в owner/ext'; Indexes = @(0, 1) },
    @{ Kind = 'confirm'; Header = 'Вести в git и внешние обработки'; Yes = $true },
    @{ Kind = 'confirm'; Header = 'веткой temp/'; Yes = $true })

# Заглушка run.ps1 для «Загрузить из git»: записывает, с каким комплектом её позвали, и итог прогона - всё загрузилось.
$gitRunStub = @'
param([string]$Kit = '', [string]$KitSource = '', [string]$KitBranch = '', [string]$ActionsDir = '', [string]$Config = '', [string]$UiChannel = '', [string]$OnNotGreen = '', [string]$OnSessions = '')
$dir = Join-Path $PSScriptRoot ('runs\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$lines = @(('Kit=' + $Kit), ('KitSource=' + $KitSource), ('KitBranch=' + $KitBranch), ('ActionsDir=' + $ActionsDir), ('OnNotGreen=' + $OnNotGreen), ('OnSessions=' + $OnSessions))
$items = @()
if ($Kit) {
    foreach ($sub in @(Get-ChildItem -LiteralPath $Kit -Directory | Sort-Object Name)) { $lines += ('dir=' + $sub.Name) }
    foreach ($file in @(Get-ChildItem -LiteralPath $Kit -Recurse -File)) { $lines += ('file=' + $file.FullName.Substring($Kit.TrimEnd('\').Length + 1).Replace('\', '/')) }
    $items = @(Get-ChildItem -LiteralPath $Kit -Directory | Where-Object { $_.Name -ne 'actions' } | ForEach-Object { @{ name = $_.Name; loadTried = $true; touched = $true } })
}
# Действия после обновления: как обработка гейта - каждое выполнено, кроме тех, где в тексте «УПАДИ».
$actions = $ActionsDir
if (-not $actions -and $Kit -and (Test-Path -LiteralPath (Join-Path $Kit 'actions'))) { $actions = Join-Path $Kit 'actions' }
if ($actions) {
    $result = @('actions=00000000.000000', 'done-register=ok')
    $status = 'ok'
    foreach ($file in @(Get-ChildItem -LiteralPath $actions -Filter '*.bsl' -File | Sort-Object Name)) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $lines += ('actionfile=' + $id)
        if ($status -ne 'ok') { $result += ('action=' + $id + '|notrun'); continue }
        if ([System.IO.File]::ReadAllText($file.FullName) -match 'УПАДИ') { $result += ('action=' + $id + '|failed|Деление на 0'); $status = 'failed' }
        else { $result += ('action=' + $id + '|done|5') }
    }
    $result += ('status=' + $status)
    [System.IO.File]::WriteAllLines((Join-Path $dir 'actions.txt'), [string[]]$result, (New-Object System.Text.UTF8Encoding($true)))
}
[System.IO.File]::WriteAllLines((Join-Path $dir 'stub.txt'), [string[]]$lines, (New-Object System.Text.UTF8Encoding($true)))
$verdict = @{ verdict = 'GREEN'; kitDecision = ''; kitItems = $items; kitProcessings = @() }
[System.IO.File]::WriteAllText((Join-Path $dir 'verdict.json'), (ConvertTo-Json -InputObject $verdict -Depth 4), (New-Object System.Text.UTF8Encoding($true)))
Write-Host 'заглушка гейта: прогон записан'
exit 0
'@

# Ответы обычного обновления: гейта нет (переспрос «хотя прогонов гейта нет»), имя рабочей базы.
$deployRiskAnswer = @{ Kind = 'confirm'; Header = 'хотя прогонов гейта нет'; Yes = $true }
$deployNameAnswer = @{ Kind = 'text'; Header = 'Это рабочая база'; Text = 'erp_base' }

# Обмены, итоги выгрузки: один объект узла «Бухгалтерия», выгрузился (ok) или упал (fail) - как пишет обработка.
$exchangeUid = 'aaaaaaaa-1111-2222-3333-444444444444'
function New-ExchangeResultTasks {
    param([string]$State)
    $presentation = 'Обмены, Бухгалтерия: Документ.СписаниеДС «Списание ДС 00-000001 от 01.11.2026 12:00:00»'
    $line = '[ОК] {0}: сообщение обмена сформировано без ошибок' -f $presentation
    $value = 'ok'
    if ($State -ne 'ok') {
        $error1 = 'Поле объекта не обнаружено (ГосКонтракт) (Событие: Отправка. Объект: Списание ДС 00-000001 от 01.11.2026 12:00:00)'
        $line = '[ОШИБКА] {0}: выгрузка упала: {1}' -f $presentation, $error1
        $value = "fail`n" + $error1
    }
    return @(
        @{ key = 'Окружение'; title = 'Окружение и расширения'; step = 'Окружение'; lines = @('[ОК] Обработка запущена под полными правами') },
        @{ key = 'Обмены'; title = 'Обмены'; step = 'Обмены'; lines = @($line); snapshots = @{ ('выгрузка|Бухгалтерия|Документ.СписаниеДС|' + $exchangeUid) = $value } }
    )
}

# Правила обмена: модуль менеджера обмена из выгрузки расширения подрядчика (имена выдуманные).
# Правило со структурой (ОбъектДанных = Неопределено) и ПКС со свойством конфигурации во #Вставка - R1;
# такая же вставка в правило с объектом - без замечания; ПКС в #Удаление - без замечания;
# &После правила «...ИзСтруктуры» с ПКС - R1 по имени; у этого перехвата пометка автора - без R4.
$rulesControlLines = @(
    '&ИзменениеИКонтроль("ДобавитьПКО_Справочник_Склады_ИзСтруктуры")',
    'Процедура Доработки_ДобавитьПКО_Справочник_Склады_ИзСтруктуры(ПравилаКонвертации)',
    '	ПравилоКонвертации = ПравилаКонвертации.Добавить();',
    '	ПравилоКонвертации.ИмяПКО = "Справочник_Склады_ИзСтруктуры";',
    '	ПравилоКонвертации.ОбъектДанных      = Неопределено; // источник - структура',
    '	СвойстваШапки = ПравилоКонвертации.Свойства;',
    '	ДобавитьПКС(СвойстваШапки, "", "Наименование");',
    '	#Вставка',
    '	ДобавитьПКС(СвойстваШапки, "Ответственный", "ОтветственныйЛицо", 1,',
    '		"Справочник_Сотрудники");',
    '	#КонецВставки',
    '	#Удаление',
    '	ДобавитьПКС(СвойстваШапки, "Старое", "Старое");',
    '	#КонецУдаления',
    'КонецПроцедуры',
    '',
    '&ИзменениеИКонтроль("ДобавитьПКО_Справочник_Склады")',
    'Процедура Доработки_ДобавитьПКО_Справочник_Склады(ПравилаКонвертации)',
    '	ПравилоКонвертации = ПравилаКонвертации.Добавить();',
    '	ПравилоКонвертации.ИмяПКО = "Справочник_Склады";',
    '	ПравилоКонвертации.ОбъектДанных = Метаданные.Справочники.Склады;',
    '	СвойстваШапки = ПравилоКонвертации.Свойства;',
    '	#Вставка',
    '	ДобавитьПКС(СвойстваШапки, "Ответственный", "ОтветственныйЛицо", 1, "Справочник_Сотрудники");',
    '	#КонецВставки',
    'КонецПроцедуры')
$rulesInsertLine = 9
$rulesAfterLines = @(
    '',
    '// ** Тестов А.Б. 20261117 валюта кассы в обмене',
    '&После("ДобавитьПКО_Справочник_Кассы_ИзСтруктуры")',
    'Процедура Доработки_ДобавитьПКО_Справочник_Кассы_ИзСтруктуры(ПравилаКонвертации)',
    '	ПравилоКонвертации = ПравилаКонвертации[ПравилаКонвертации.Количество() - 1];',
    '	ДобавитьПКС(ПравилоКонвертации.Свойства, "Валюта", "Валюта"); // в «http://» комментарий не мешает',
    'КонецПроцедуры')
$rulesModuleControlOnly = $rulesControlLines -join "`n"
$rulesModule = (@($rulesControlLines) + @($rulesAfterLines)) -join "`n"

function New-FakeGateRelease {
    # Подставной GitHub с релизами гейта для update.ps1 в песочнице: токен файлом DPAPI, прежний ci.exe, комплект-заглушка
    # (install.ps1 пишет, куда и как её позвали, и ci\run.ps1), ответы на адреса - в fake-http: релиз 20991231.000000 с
    # верной суммой, 20000101.000000 - с неверной, чужой тег. Возвращает токен и папку ответов.
    param([string]$Sandbox, [string]$Name)
    New-Item -ItemType Directory -Path (Join-Path $Sandbox 'secrets') -Force | Out-Null
    $secret = 'tok-секрет-123'
    [System.IO.File]::WriteAllText((Join-Path $Sandbox 'secrets\github.txt'), (ConvertFrom-SecureString -SecureString (ConvertTo-SecureString $secret -AsPlainText -Force)))
    [System.IO.File]::WriteAllText((Join-Path $Sandbox 'ci.exe'), 'старый ci.exe')
    # Комплект: install.ps1-заглушка (пишет, куда и как её позвали) и ci\run.ps1.
    $kit = Join-Path $workRoot ($Name + '-kit')
    New-Item -ItemType Directory -Path (Join-Path $kit 'ci') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $kit 'install.ps1'), ('param([string]$Target, [switch]$Unattended)' + "`r`n" + '[System.IO.File]::WriteAllText((Join-Path $Target "installed-marker.txt"), ("target=" + $Target + " unattended=" + [bool]$Unattended))'), $utf8Bom)
    [System.IO.File]::WriteAllText((Join-Path $kit 'ci\run.ps1'), '# Версия 20991231.000000.', $utf8Bom)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path $workRoot ($Name + '.zip')
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($kit, $zip)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $digest = -join @($sha.ComputeHash([System.IO.File]::ReadAllBytes($zip)) | ForEach-Object { $_.ToString('x2') })
    $http = Join-Path $Sandbox 'fake-http'
    New-Item -ItemType Directory -Path $http -Force | Out-Null
    $put = {
        param([string]$Url, $Content)
        $file = Join-Path $http ([regex]::Replace($Url, '[^A-Za-z0-9.\-]', '_'))
        if ($Content -is [byte[]]) { [System.IO.File]::WriteAllBytes($file, $Content) } else { [System.IO.File]::WriteAllText($file, [string]$Content, $utf8) }
    }
    $releases = @(
        @{ tag_name = 'gate-20991231.000000'; draft = $false; published_at = '2099-12-31T10:00:00Z'; body = "- модульные тесты`n- обновление из GitHub"
            assets = @(@{ name = 'ci-gate_20991231.000000.zip'; url = 'https://api.github.com/repos/owner/repo/releases/assets/1'; size = 1000; digest = ('sha256:' + $digest) }) },
        @{ tag_name = 'gate-20000101.000000'; draft = $false; published_at = '2000-01-01T10:00:00Z'; body = 'старый'
            assets = @(@{ name = 'ci-gate_20000101.000000.zip'; url = 'https://api.github.com/repos/owner/repo/releases/assets/2'; size = 1000; digest = ('sha256:' + ('0' * 64)) }) },
        @{ tag_name = 'other-1'; draft = $false; published_at = '2099-01-01T10:00:00Z'; body = ''; assets = @() })
    & $put 'https://api.github.com/repos/owner/repo/releases?per_page=30' (ConvertTo-Json -InputObject $releases -Depth 6)
    & $put 'https://api.github.com/repos/owner/repo/releases/assets/1' 'REDIRECT https://objects.example.com/new.zip'
    & $put 'https://api.github.com/repos/owner/repo/releases/assets/2' 'REDIRECT https://objects.example.com/old.zip'
    & $put 'https://objects.example.com/new.zip' ([System.IO.File]::ReadAllBytes($zip))
    & $put 'https://objects.example.com/old.zip' ([System.IO.File]::ReadAllBytes($zip))
    return [pscustomobject]@{ Secret = $secret; Http = $http }
}

$tests = @(
    @{
        Name = 'gate-asis-green'
        Text = 'прогон на том, что есть в базе: всё зелёное'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep'
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Самопроверка' 'OK'
            Check-Step $r 'Канареечный вход' 'OK'
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0) 'без комплекта гейт что-то загружал'
        }
    },
    @{
        Name = 'gate-tools-build'
        Text = 'обработки гейта из поставки (tools\src): собраны не из неё - прогон сам собирает самопроверку и канарейку конфигуратором до первого шага, прежние - в .old, отпечаток - в .source.txt; второй прогон не собирает; поменялись исходники самопроверки - собирается только она'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $src = Join-Path $sb 'tools\src'
            foreach ($toolName in @('ВыполнитьПослеОбновления', 'Канарейка')) {
                New-Item -ItemType Directory -Path (Join-Path $src ($toolName + '\Ext')) -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $src ($toolName + '.xml')), ('<MetaDataObject><ExternalDataProcessor><Properties><Name>' + $toolName + '</Name></Properties></ExternalDataProcessor></MetaDataObject>'), $utf8)
                [System.IO.File]::WriteAllText((Join-Path $src ($toolName + '\Ext\ObjectModule.bsl')), 'Процедура А() КонецПроцедуры', $utf8)
            }
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep'
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check ((Get-Calls $r @('/LoadExternalDataProcessorOrReportFromFiles')).Count -eq 2) ("сборок обработок гейта {0}, ждали 2" -f (Get-Calls $r @('/LoadExternalDataProcessorOrReportFromFiles')).Count)
            foreach ($toolName in @('ВыполнитьПослеОбновления', 'Канарейка')) {
                $epf = Join-Path $sb ('tools\' + $toolName + '.epf')
                Check ((Test-Path -LiteralPath $epf) -and ([System.IO.File]::ReadAllText($epf) -match '^FAKEEPF')) ("{0}.epf не собрана из поставки" -f $toolName)
                Check ((Test-Path -LiteralPath ($epf + '.old')) -and ([System.IO.File]::ReadAllText($epf + '.old', $utf8) -eq 'fake')) ("прежняя {0}.epf не сохранена в .old" -f $toolName)
                Check (Test-Path -LiteralPath ($epf + '.source.txt')) ("нет отпечатка исходников {0}" -f $toolName)
            }
            Reset-FakeState $sb
            $again = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep'
            Check-Common $again; Check-Verdict $again 'GREEN' 0
            Check ((Get-Calls $again @('/LoadExternalDataProcessorOrReportFromFiles')).Count -eq 0) 'второй прогон снова собирал обработки гейта'
            [System.IO.File]::WriteAllText((Join-Path $src 'ВыполнитьПослеОбновления\Ext\ObjectModule.bsl'), 'Процедура Б() КонецПроцедуры', $utf8)
            Reset-FakeState $sb
            $changed = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep'
            Check-Common $changed; Check-Verdict $changed 'GREEN' 0
            # Без @(): Get-Calls отдаёт массив запятой, @() завернул бы его ещё раз.
            $builds = Get-Calls $changed @('/LoadExternalDataProcessorOrReportFromFiles')
            Check ($builds.Count -eq 1 -and $builds[0].Line -match 'ВыполнитьПослеОбновления') ("после правки исходников самопроверки собиралось: " + (@($builds | ForEach-Object { $_.Line }) -join ' | '))
        }
    },
    @{
        Name = 'gate-menu-kit-green'
        Text = 'меню: прогон с обновлением из inbox, отметить .cfe, зелёный; обновление уходит из inbox в папку прогона'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $r = Invoke-Script -Sandbox $sb -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = 'Прогон с обновлением' },
                @{ Kind = 'many'; Header = 'Что грузим'; Indexes = @(0) })
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Загрузить Адаптация' 'OK'
            Check-Step $r 'Обновить конфигурацию БД Адаптация' 'OK'
            Check ((Get-Calls $r @('/LoadCfg', $cfeName, '-Extension Адаптация')).Count -eq 1) 'нет загрузки .cfe с -Extension Адаптация'
            Check ((Get-Calls $r @('/DumpCfg', '-Extension Адаптация')).Count -eq 1) 'нет сохранения прежней версии'
            Check (-not (Test-Path -LiteralPath $file)) 'обновление осталось в inbox'
            if ($r.RunDir) { Check (Test-Path -LiteralPath (Join-Path $r.RunDir ('inbox\' + $cfeName))) 'обновления нет в папке прогона' }
        }
    },
    @{
        Name = 'gate-kit-requires-backups'
        Text = 'в комплекте два расширения, для второго ошибка DumpCfg или код 0 без файла: гейт не грузит ни одно'
        Run = {
            param($Name)
            foreach ($noDump in @($false, $true)) {
                $sb = New-Sandbox ("{0}-{1}" -f $Name, $noDump)
                $kit = Join-Path $sb 'inbox'
                $null = Add-InboxFile $sb $cfeName
                $null = Add-InboxFile $sb 'Доработки.cfe'
                $rule = @{ match = @('/DumpCfg', '-Extension Доработки'); noDump = $noDump }
                if (-not $noDump) { $rule.exit = 1; $rule.log = 'Ошибка записи копии' }
                $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $kit) -Fake @{ designer = @($rule) }
                Check-Common $r
                Check-Verdict $r 'RED' 1
                Check-Step $r 'Сохранить текущее Доработки' 'FAIL'
                Check ((Get-Calls $r @('/DumpCfg', '-Extension Доработки')).Count -eq 1) 'не проверена выгрузка второго расширения'
                foreach ($command in @('/LoadCfg', '/LoadConfigFromFiles', '/UpdateDBCfg')) {
                    Check ((Get-Calls $r @($command)).Count -eq 0) ("без копии вызвана команда {0}" -f $command)
                }
                if ($r.RunDir) {
                    $state = Get-Content -LiteralPath (Join-Path $r.RunDir 'resume.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                    Check ($state.phases.backup.state -eq 'failed') 'этап резервирования можно взять готовым при продолжении'
                }
            }
        }
    },
    @{
        Name = 'gate-update-fail-rollback'
        Text = 'обновление конфигурации БД падает: красный, откат прежней версией, обновление остаётся в inbox'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ designer = @(@{ match = @('/UpdateDBCfg', 'Адаптация'); exit = 1; log = 'Ошибка обновления: тест'; times = 1 }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Rollback' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'RED' 1
            Check-Step $r 'Обновить конфигурацию БД Адаптация' 'FAIL'
            Check ($null -ne $r.Verdict -and $r.Verdict.kitDecision -eq 'rolledBack') 'откат не выполнен'
            Check ((Get-Calls $r @('/LoadCfg', '\before\', '-Extension Адаптация')).Count -eq 1) 'откат не загружал прежнюю версию из before'
            Check (Test-Path -LiteralPath $file) 'откаченное обновление ушло из inbox'
        }
    },
    @{
        Name = 'gate-new-extension-delete'
        Text = 'расширения в базе не было: при откате оно удаляется, и только по имени'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{
                designer = @(
                    @{ match = @('/DumpCfg', 'Адаптация'); exit = 1; log = 'Расширение не найдено' },
                    @{ match = @('/UpdateDBCfg', 'Адаптация'); exit = 1; log = 'Ошибка обновления: тест'; times = 1 })
                selfcheck = @(@{ ext = @('Доработки|1|active|hashB') })
            }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Rollback' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'RED' 1
            Check ((Get-Calls $r @('/DeleteCfg', '-Extension Адаптация')).Count -eq 1) 'новое расширение не удалено при откате'
        }
    },
    @{
        Name = 'gate-designer-busy-retry'
        Text = 'конфигуратор temp занят посреди прогона («Ошибка блокировки ... для конфигурирования»): вопрос, «закрыть отсюда» - команда повторяется, прогон идёт дальше'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $busy = 'Ошибка блокировки информационной базы для конфигурирования. Возможно, информационная база уже открыта Конфигуратором. С этой информационной базой уже работает конфигуратор: компьютер: pc1, сеанс: 5'
            $fake = @{ designer = @(@{ match = @('/LoadCfg', 'Адаптация'); exit = 1; log = $busy; times = 1 }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake -Answers @(
                @{ Kind = 'one'; Header = 'Открыт конфигуратор'; Item = '^Закрыть отсюда' })
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check ((Get-Calls $r @('/LoadCfg', 'Адаптация')).Count -eq 2) 'загрузка не повторилась после закрытия конфигуратора'
        }
    },
    @{
        Name = 'gate-checkconfig-busy-retry'
        Text = 'параллельная проверка конфигурации стартует после проверки применимости; упала на «конфигуратор занят» - повторяется перед вердиктом, без «исправлено» в разборе'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $busy = 'Ошибка блокировки информационной базы для конфигурирования. Возможно, информационная база уже открыта Конфигуратором. С этой информационной базой уже работает конфигуратор: компьютер: pc1, сеанс: 1'
            $fake = @{ designer = @(@{ match = @('/CheckConfig'); exit = 1; log = $busy; times = 1 }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Проверка конфигурации' 'OK'
            Check ((Get-Calls $r @('/CheckConfig')).Count -eq 2) 'проверка конфигурации не повторилась после «конфигуратор занят»'
            $lines = @($r.Calls | ForEach-Object { $_.Line })
            $canApplyAt = -1
            $checkAt = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($canApplyAt -lt 0 -and $lines[$i].Contains('/CheckCanApplyConfigurationExtensions')) { $canApplyAt = $i }
                if ($checkAt -lt 0 -and $lines[$i].Contains('/CheckConfig ')) { $checkAt = $i }
            }
            Check ($canApplyAt -ge 0 -and $checkAt -gt $canApplyAt) ("проверка конфигурации запущена не после проверки применимости ({0}, {1})" -f $canApplyAt, $checkAt)
            if ($r.RunDir) {
                $report = Join-Path $r.RunDir 'report.txt'
                if (Test-Path -LiteralPath $report) { Check (-not ([System.IO.File]::ReadAllText($report, $utf8) -match 'Проверка конфигурации \(all\): новых \d+ \(блокирующих \d+\), исправлено')) 'в разборе «исправлено» по проверке конфигурации' }
            }
        }
    },
    @{
        Name = 'gate-designer-busy-cancel'
        Text = 'конфигуратор temp занят, на вопрос - «Отмена»: прогон завершается, в run.log - «отменено пользователем»'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $busy = 'Ошибка блокировки информационной базы для конфигурирования. С этой информационной базой уже работает конфигуратор: компьютер: pc1, сеанс: 5'
            $fake = @{ designer = @(@{ match = @('/LoadCfg', 'Адаптация'); exit = 1; log = $busy; times = 1 }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake -Answers @(
                @{ Kind = 'one'; Header = 'Открыт конфигуратор'; Item = '^Отмена' })
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check ($r.ExitCode -ne 0) 'прогон не завершился после отмены'
            Check (@($r.Output | Where-Object { $_ -match 'отменено пользователем' }).Count -gt 0) 'нет «отменено пользователем» в выводе'
            if ($r.RunDir) { Check ([System.IO.File]::ReadAllText((Join-Path $r.RunDir 'run.log'), $utf8) -match 'Отменено пользователем: открыт конфигуратор') 'нет записи об отмене в run.log' }
            Check ((Get-Calls $r @('/LoadCfg', 'Адаптация')).Count -eq 1) 'после отмены загрузка повторялась'
        }
    },
    @{
        Name = 'gate-selfcheck-new-error-keep'
        Text = 'самопроверка после загрузки нашла новую ошибку: красный; на вопрос «оставить?» - оставить'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ selfcheck = @(@{ }, @{ tasks = $errorTasks; fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake -Answers @(
                @{ Kind = 'one'; Header = 'оставить или откатить'; Item = '^Оставить$' })
            Check-Common $r; Check-Verdict $r 'RED' 1
            Check-Step $r 'Самопроверка после загрузки' 'FAIL'
            Check ($null -ne $r.Verdict -and $r.Verdict.kitDecision -eq 'kept') 'комплект не оставлен, хотя ответили «Оставить»'
        }
    },
    @{
        Name = 'gate-kit-keep-accept'
        Text = 'после вердикта кнопка «Оставить и принять новое в эталон»: комплект оставлен, новое в эталоне, прогон отмечен'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ selfcheck = @(@{ }, @{ tasks = $errorTasks; fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake -Answers @(
                @{ Kind = 'one'; Header = 'оставить или откатить'; Item = '^Оставить и принять новое в эталон' })
            Check-Common $r; Check-Verdict $r 'RED' 1
            Check ($null -ne $r.Verdict -and $r.Verdict.kitDecision -eq 'kept') 'комплект не оставлен'
            if ($r.RunDir) { Check (Test-Path -LiteralPath (Join-Path $r.RunDir 'accepted.txt')) 'прогон не отмечен принятым' }
            $norm = Join-Path $sb 'baseline\erp_temp_test\selfcheck.norm.txt'
            Check ((Test-Path -LiteralPath $norm) -and ([System.IO.File]::ReadAllText($norm, $utf8) -match 'не компилируется')) 'новая ошибка не попала в эталон'
            $question = @($r.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('оставить или откатить') })
            Check ($question.Count -eq 1 -and $question[0].Contains('"dock"')) 'вопрос после вердикта не помечен для показа внизу экрана'
        }
    },
    @{
        Name = 'gate-checked-state'
        Text = 'прогон с настроенной рабочей: снимок temp (хеш-суммы расширений) в verdict.json до вопроса про комплект; без ProdBase снимка нет'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $file = Add-InboxFile $sb $cfeName
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Com (New-ComState)
            Check-Common $r
            if ($null -eq $r.Verdict) { Check $false 'нет verdict.json'; return }
            $checked = $r.Verdict.checkedState
            Check ($null -ne $checked -and [bool]$checked.ok) ("снимок temp не снялся: {0}" -f $(if ($null -ne $checked) { $checked.error } else { 'нет checkedState' }))
            if ($null -ne $checked -and [bool]$checked.ok) { Check ([string]$checked.extensions.'Адаптация'.hash -eq 'h2') ("хеш Адаптация в снимке: {0}" -f $checked.extensions.'Адаптация'.hash) }
            $plain = New-Sandbox ($Name + '-noprod')
            $file2 = Add-InboxFile $plain $cfeName
            $r2 = Invoke-Script -Sandbox $plain -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file2)
            if ($r2.RunDir) { Check (-not (Test-Path -LiteralPath (Join-Path $r2.RunDir 'checked-state.json'))) 'снимок temp без настроенной рабочей' }
        }
    },
    @{
        Name = 'gate-selfcheck-known-tiles'
        Text = 'экран хода самопроверки: предупреждение, которое уже есть в эталоне, уходит в «известные» своего шага (сверка по тексту), новая ошибка - нет; параллельная проверка конфигурации названа в плане; сеансам «до» и «после» переданы свои заголовок и пояснение экрана'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            # Задания идут с паузой: гейт смотрит части журнала раз в три секунды и должен успеть их разобрать.
            $tasks = {
                param([string[]]$RightsLines)
                return @(
                    @{ key = 'Окружение'; title = 'Окружение и расширения'; step = 'Окружение'; lines = @('[ОК] Обработка запущена под полными правами') },
                    @{ key = 'Права'; title = 'Метаданные и права'; step = 'Метаданные и права'; lines = $RightsLines },
                    @{ key = 'Узлы'; title = 'Узлы обмена'; step = 'Узлы обмена'; lines = @('[ОК] Узлы опознаны') },
                    @{ key = 'Настройки'; title = 'Регистр настроек'; step = 'Регистр настроек'; lines = @('[ОК] Настройки читаются') },
                    @{ key = 'Конец'; title = 'Блокировки'; step = 'Блокировки'; lines = @('[ОК] Блокировки проверены') }
                )
            }
            $knownLine = '[ВНИМАНИЕ] Роль подрядчика без права чтения: 3 объекта'
            $fake = @{ selfcheck = @(
                    @{ tasks = (& $tasks @('[ОК] Права проверены', $knownLine)); sleep = 3 },
                    @{ tasks = (& $tasks @('[ОК] Права проверены', '[ВНИМАНИЕ] Роль подрядчика без права чтения: 4 объекта', '[ОШИБКА] Роль без права записи нового регистра')); sleep = 3; fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake
            Check (-not $r.TimedOut) ("не уложился в {0} с" -f $TimeoutSec)
            Check (@($r.Output | Where-Object { $_ -match '^Остановлено: |Разбор прогона не получился|ParserError' }).Count -eq 0) 'скрипт упал'
            $events = @(foreach ($line in @($r.Output | Where-Object { $_.StartsWith('@@ui:') })) {
                    $uiEvent = $null
                    try { $uiEvent = $line.Substring(5) | ConvertFrom-Json } catch { $uiEvent = $null }
                    if ($null -ne $uiEvent) { $uiEvent }
                })
            $plans = @($events | Where-Object { [string]$_.kind -eq 'plan' })
            Check ($plans.Count -ge 1) 'нет события plan'
            if ($plans.Count -ge 1) { Check (@($plans[0].parallel) -contains 'Проверка конфигурации (all)') ("параллельная проверка конфигурации не названа в плане: {0}" -f (@($plans[0].parallel) -join ', ')) }
            # «После»: предупреждение из эталона («до» записало его; число в тексте другое - приведение то же) - известное,
            # ошибки в эталоне нет - она новая.
            $after = @($events | Where-Object { [string]$_.kind -eq 'subplan' -and ([string]$_.title).StartsWith('Самопроверка после загрузки') })
            Check ($after.Count -gt 0) 'нет событий subplan самопроверки после загрузки'
            $seen = @(foreach ($item in $after) { foreach ($block in @($item.blocks)) { if ([string]$block.name -eq 'Метаданные и права' -and [int]$block.knownWarn -gt 0) { $block } } })
            Check ($seen.Count -gt 0) 'известное предупреждение шага «Метаданные и права» до экрана не дошло'
            if ($seen.Count -gt 0) {
                $last = $seen[$seen.Count - 1]
                Check ([int]$last.knownWarn -eq 1 -and [int]$last.knownErr -eq 0) ("известных у шага: предупреждений {0}, ошибок {1}; ждали 1 и 0" -f $last.knownWarn, $last.knownErr)
            }
            $other = @(foreach ($item in $after) { foreach ($block in @($item.blocks)) { if ([string]$block.name -ne 'Метаданные и права' -and ([int]$block.knownWarn + [int]$block.knownErr + [int]$block.knownSkip) -gt 0) { $block } } })
            Check ($other.Count -eq 0) 'известное приписано чужому шагу'
            # Обработке - то же файлом known.txt в папке сеанса «после»; читать его просит часть tiles=1 параметра запуска.
            $tilesCalls = Get-Calls $r @('ENTERPRISE', 'selfcheck', 'tiles=1')
            Check ($tilesCalls.Count -ge 1) 'обработку не попросили читать known.txt (tiles=1)'
            # Шапка экрана в окне 1С: гейт называет сеанс и зачем он (caption=, why=) - «до» и «после» по-разному.
            $captionBefore = Get-Calls $r @('ENTERPRISE', 'selfcheck', 'caption=Самопроверка до загрузки комплекта;why=Комплект ещё не загружен')
            Check ($captionBefore.Count -ge 1) 'сеансу «до» не переданы заголовок и пояснение экрана (caption=, why=)'
            $captionAfter = Get-Calls $r @('ENTERPRISE', 'selfcheck', 'caption=Самопроверка после загрузки комплекта;why=Комплект загружен')
            Check ($captionAfter.Count -ge 1) 'сеансу «после» не переданы заголовок и пояснение экрана (caption=, why=)'
            $knownFiles = @(Get-ChildItem -LiteralPath $r.RunDir -Recurse -Filter 'known.txt' -File | Where-Object { ([System.IO.File]::ReadAllText($_.FullName, $utf8)).Contains('0/1/0|Метаданные и права') })
            Check ($knownFiles.Count -ge 1) 'в known.txt нет строки «0/1/0|Метаданные и права»'
        }
    },
    @{
        Name = 'gate-exchange-snapshot-lastupdate'
        Text = 'обмены: в сообщениях сдвинулись только даты LastUpdate (в разобранном XML и в обрезанном) - зелёный, разницы снимков нет'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $tasks = {
                param([string]$Date)
                $whole = '<Message xmlns:msg="http://www.1c.ru/SSL/Exchange/Message"><msg:Header><msg:Format>EnterpriseData/1.8</msg:Format>' +
                    '<msg:Info><msg:Item><msg:Name>А</msg:Name><msg:LastUpdate>' + $Date + ':41</msg:LastUpdate></msg:Item>' +
                    '<msg:Item><msg:Name>Б</msg:Name><msg:LastUpdate>' + $Date + ':43</msg:LastUpdate></msg:Item></msg:Info></msg:Header>' +
                    '<Body xmlns="EnterpriseData/1.8"><Сумма>100</Сумма></Body></Message>'
                # Обрезанное сообщение как XML не разбирается: сравнивается строками, дату закрывает маска по умолчанию.
                $cut = '<Message xmlns:msg="http://www.1c.ru/SSL/Exchange/Message"><msg:Header>' + "`n`t`t<msg:LastUpdate>" + $Date + ":41</msg:LastUpdate>`n`t`t<msg:LastUpdate>" + $Date + ":43</msg:LastUpdate>`n<Body><Сумма>100"
                return @(
                    @{ key = 'Окружение'; title = 'Окружение и расширения'; step = 'Окружение'; lines = @('[ОК] Обработка запущена под полными правами') },
                    @{ key = 'Обмены'; title = 'Обмены'; step = 'Обмены'; lines = @('[ОК] Бухгалтерия: Документ.РеализацияТоваровУслуг выгружается')
                        snapshots = @{ 'обмен|Бухгалтерия|Документ.РеализацияТоваровУслуг|11111111-2222-3333-4444-555555555555' = $whole
                            'обмен|ЗУП|Справочник.Организации|22222222-3333-4444-5555-666666666666' = $cut } }
                )
            }
            $fake = @{ selfcheck = @(
                    @{ tasks = (& $tasks '2026-11-18T17:42') },
                    @{ tasks = (& $tasks '2026-11-19T09:05'); fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Самопроверка после загрузки' 'OK'
            $step = Get-Step $r 'Самопроверка после загрузки'
            if ($null -ne $step) { Check ([string]$step.detail -match 'снимков 2, изменились 0') ("в итоге шага нет сведений о снимках: {0}" -f $step.detail) }
            if ($r.RunDir) { Check (-not (Test-Path -LiteralPath (Join-Path $r.RunDir 'selfcheck-after.snapshots.diff.txt'))) 'файл разницы есть, хотя сдвинулись только даты LastUpdate' }
        }
    },
    @{
        Name = 'gate-snapshot-masks'
        Text = 'снимки отличаются только тем, что закрыто SnapshotMasks (идентификатор, дата в обрезанном XML): зелёный'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ SnapshotMasks = @('(?<=<(?:\w+:)?CreationDate>)[^<]*', '(?<=Идентификатор=)[0-9a-f-]{36}') }
            $file = Add-InboxFile $sb $cfeName
            $before = "Регистр | Период=1; Идентификатор=11111111-2222-3333-4444-555555555555`n<msg:CreationDate>2026-11-17T10:00:00</msg:CreationDate>"
            $after = "Регистр | Период=1; Идентификатор=99999999-8888-7777-6666-555555555555`n<msg:CreationDate>2026-11-17T11:30:00</msg:CreationDate>"
            $fake = @{ selfcheck = @(@{ tasks = (New-ExchangeTasks $before) }, @{ tasks = (New-ExchangeTasks $after); fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            if ($r.RunDir) { Check (-not (Test-Path -LiteralPath (Join-Path $r.RunDir 'selfcheck-after.snapshots.diff.txt'))) 'есть разница снимков, хотя менялось только закрытое масками' }
        }
    },
    @{
        Name = 'gate-checkconfig-new-record'
        Text = 'проверка конфигурации нашла новое замечание: красный, обновление в базе остаётся по ответу'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ designer = @(@{ match = @('/CheckConfig'); exit = 101; log = '{CommonModule.Адаптация_ОбщийСервер.Module(12,5)}: Переменная не определена (Тест)' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'RED' 1
            Check-Step $r 'Проверка конфигурации' 'FAIL'
            Check ($null -ne $r.Verdict -and $r.Verdict.kitDecision -eq 'kept') 'комплект не оставлен при -OnNotGreen Keep'
        }
    },
    @{
        Name = 'gate-checkconfig-101-without-diagnostics'
        Text = 'CheckConfig вернул 101 с пустым журналом или без /Out: красный с эталоном и без него'
        Run = {
            param($Name)
            foreach ($withBaseline in @($false, $true)) {
                foreach ($noLog in @($false, $true)) {
                    $sb = New-Sandbox ("{0}-{1}-{2}" -f $Name, $withBaseline, $noLog) -Config @{ ParallelCheckConfig = $withBaseline }
                    $baseline = Join-Path $sb 'baseline\erp_temp_test\checkconfig_all.norm.txt'
                    if ($withBaseline) {
                        New-Item -ItemType Directory -Path (Split-Path -Parent $baseline) -Force | Out-Null
                        [System.IO.File]::WriteAllText($baseline, 'Известное замечание', $utf8Bom)
                    }
                    $fake = @{ designer = @(@{ match = @('/CheckConfig'); exit = 101; noLog = $noLog }) }
                    $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
                    Check-Common $r
                    Check-Verdict $r 'RED' 1
                    Check-Step $r 'Проверка конфигурации' 'FAIL'
                    Check ((Get-Calls $r @('/CheckConfig')).Count -eq 1) 'CheckConfig должен выполниться один раз'
                    if ($r.RunDir) {
                        Check ((Test-Path -LiteralPath (Join-Path $r.RunDir 'checkconfig_all.log')) -eq (-not $noLog)) 'подставная 1С создала другой вариант журнала'
                        Check (-not (Test-Path -LiteralPath (Join-Path $r.RunDir 'checkconfig_all.norm.txt'))) 'неполный результат опубликован для сравнения'
                        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sb 'run.ps1') -AcceptBaseline $r.RunDir | Out-Null
                        Check ($LASTEXITCODE -eq 0) 'не выполнена команда принятия эталона'
                    }
                    if ($withBaseline) {
                        Check (([System.IO.File]::ReadAllText($baseline, $utf8)) -eq 'Известное замечание') 'принятие неполного прогона изменило эталон'
                    } else { Check (-not (Test-Path -LiteralPath $baseline)) 'из неполного прогона создан эталон' }
                }
            }
        }
    },
    @{
        Name = 'gate-epf-new-green'
        Text = 'внешняя обработка, новая: запись в справочник, комплект из одних обработок - без проверок конфигуратором'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb 'Печать.epf'
            $fake = @{ regepf = @(@{ status = 'done'; isnew = '1'; objversion = '1.0' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Записать в справочник Печать' 'OK'
            Check-Step $r 'Проверки конфигуратором, канарейка, самопроверка' 'OK'
            Check ((Get-Calls $r @('/Cregepf', 'name=Печать.epf')).Count -eq 1) 'нет вызова regepf с именем файла'
            Check ((Get-Calls $r @('DESIGNER')).Count -eq 0) 'для одних обработок запускался конфигуратор'
            Check ($null -ne $r.Verdict -and @($r.Verdict.kitProcessings).Count -eq 1 -and $r.Verdict.kitProcessings[0].isNew -eq 'yes') 'в verdict.json нет обработки или она не новая'
        }
    },
    @{
        Name = 'gate-epf-form-error-unregister'
        Text = 'новая обработка, форма не создаётся: красный, откат снимает её из справочника по имени и ссылке'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb 'Печать.epf'
            $fake = @{ regepf = @(@{ status = 'done'; isnew = '1'; ref = '11111111-2222-3333-4444-555555555555'; formerror = @('ВнешняяОбработка.Печать.Форма.Форма: тест') }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Rollback' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'RED' 1
            Check-Step $r 'Записать в справочник Печать' 'FAIL'
            Check ((Get-Calls $r @('/Cunregepf', 'name=Печать', 'ref=11111111-2222-3333-4444-555555555555')).Count -eq 1) 'новая обработка не снята по имени и ссылке'
            Check ($null -ne $r.Verdict -and $r.Verdict.kitDecision -eq 'rolledBack') 'откат не выполнен'
        }
    },
    @{
        Name = 'gate-epf-update-restore'
        Text = 'обработка обновлена и сломалась: откат записывает прежнюю версию из old.b64'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb 'Печать.epf'
            $fake = @{ regepf = @(
                    @{ status = 'done'; isnew = '0'; old = 'ПРЕЖНЯЯ'; oldversion = '1.0'; objversion = '1.1'; check = 'error'; checkerror = 'не подключилась: тест' },
                    @{ status = 'done'; isnew = '0' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Rollback' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'RED' 1
            Check ((Get-Calls $r @('/Cregepf')).Count -eq 2) 'нет второго regepf - отката прежней версией'
            if ($r.RunDir) {
                $restored = Join-Path $r.RunDir 'epf\Печать\rollback\new.b64'
                $text = ''
                if (Test-Path -LiteralPath $restored) { $text = $utf8.GetString([Convert]::FromBase64String([System.IO.File]::ReadAllText($restored).Trim())) }
                Check ($text -eq 'ПРЕЖНЯЯ') ("при откате записана не прежняя версия: «{0}»" -f $text)
                Check (Test-Path -LiteralPath (Join-Path $r.RunDir 'epf\Печать\прежняя_Печать.epf')) 'прежняя версия не сохранена файлом'
            }
        }
    },
    @{
        Name = 'gate-epfdir-build'
        Text = 'выгрузка обработки в файлы: конфигуратор собирает .epf, потом запись в справочник'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $xml = Add-InboxFile $sb 'Печать_выгрузка\Печать.xml' $epfDump
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f (Split-Path -Parent $xml))
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Собрать Печать из файлов' 'OK'
            Check-Step $r 'Записать в справочник Печать' 'OK'
            Check ((Get-Calls $r @('/LoadExternalDataProcessorOrReportFromFiles', 'Печать.xml', 'Печать.epf')).Count -eq 1) 'нет сборки обработки конфигуратором'
        }
    },
    @{
        Name = 'gate-mixed-kit'
        Text = 'расширение и обработка вместе: расширение грузится, обработка записывается после него, проверки идут'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            Add-InboxFile $sb ('20261117\' + $cfeName) | Out-Null
            Add-InboxFile $sb '20261117\Печать.epf' | Out-Null
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f (Join-Path $sb 'inbox\20261117'))
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Загрузить Адаптация' 'OK'
            Check-Step $r 'Записать в справочник Печать' 'OK'
            Check-Step $r 'Проверка конфигурации' 'OK'
            # Порядок вызовов - по номерам строк журнала подставной 1С.
            $loadAt = -1
            $regAt = -1
            for ($i = 0; $i -lt $r.Calls.Count; $i++) {
                if ($loadAt -lt 0 -and $r.Calls[$i].Line.Contains('/LoadCfg')) { $loadAt = $i }
                if ($regAt -lt 0 -and $r.Calls[$i].Line.Contains('/Cregepf')) { $regAt = $i }
            }
            Check ($loadAt -ge 0 -and $regAt -gt $loadAt) ("обработка записана не после загрузки расширения (загрузка - вызов {0}, запись - {1})" -f $loadAt, $regAt)
        }
    },
    @{
        Name = 'gate-exchange-snapshot-changed'
        Text = 'обмены: тот же документ выгрузился в сообщение по-другому - жёлтый, разница в файле, эталон снимков не сдвигается'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ selfcheck = @(
                    @{ tasks = (New-ExchangeTasks (New-ExchangeMessage '2026-11-17T10:00:00' 5 '100')) },
                    @{ tasks = (New-ExchangeTasks (New-ExchangeMessage '2026-11-17T11:30:00' 6 '120')); fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'YELLOW' 2
            Check-Step $r 'Самопроверка после загрузки' 'WARN'
            if ($r.RunDir) {
                $diffFile = Join-Path $r.RunDir 'selfcheck-after.snapshots.diff.txt'
                Check (Test-Path -LiteralPath $diffFile) 'нет файла разницы снимков'
                if (Test-Path -LiteralPath $diffFile) {
                    $diff = [System.IO.File]::ReadAllText($diffFile, $utf8)
                    # Строки разницы - с отступами разложенного XML: «-       <Сумма>100</Сумма>».
                    Check ($diff -match '(?m)^- +<Сумма>100</Сумма>' -and $diff -match '(?m)^\+ +<Сумма>120</Сумма>') ("в разнице нет изменённой суммы: {0}" -f $diff)
                    Check (-not $diff.Contains('CreationDate') -and -not $diff.Contains('MessageNo')) 'в разнице поля заголовка, которые меняются сами по себе'
                }
                $reference = @(Get-ChildItem -LiteralPath (Join-Path $sb 'baseline') -Recurse -Filter 'selfcheck.snapshots.txt' -File)
                Check ($reference.Count -eq 1) 'нет эталонных снимков'
                if ($reference.Count -eq 1) { Check ([System.IO.File]::ReadAllText($reference[0].FullName, $utf8).Contains('<Сумма>100</Сумма>')) 'эталон снимков сдвинулся на изменённый' }
            }
        }
    },
    @{
        Name = 'gate-exchange-snapshot-same'
        Text = 'обмены: сообщения отличаются только датой и номерами в заголовке - зелёный'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ selfcheck = @(
                    @{ tasks = (New-ExchangeTasks (New-ExchangeMessage '2026-11-17T10:00:00' 5 '100')) },
                    @{ tasks = (New-ExchangeTasks (New-ExchangeMessage '2026-11-17T11:30:00' 6 '100')); fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Самопроверка после загрузки' 'OK'
            $step = Get-Step $r 'Самопроверка после загрузки'
            if ($null -ne $step) { Check ([string]$step.detail -match 'снимков 1, изменились 0') ("в итоге шага нет сведений о снимках: {0}" -f $step.detail) }
            if ($r.RunDir) { Check (-not (Test-Path -LiteralPath (Join-Path $r.RunDir 'selfcheck-after.snapshots.diff.txt'))) 'файл разницы есть, хотя менялся только заголовок' }
        }
    },
    @{
        Name = 'gate-coverage-new-uncovered'
        Text = 'карта покрытия: первый прогон - эталон, во втором новый перехват без проверки и регламентное задание - жёлтый'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ selfcheck = @(@{ tasks = $coverageTasks }, @{ tasks = $coverageTasks; fingerprint = 'после' }); dumps = @{ 'Адаптация' = $coverageDumpFirst } }
            $first = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake
            Check-Common $first; Check-Verdict $first 'GREEN' 0
            Check-Step $first 'Карта покрытия' 'OK'
            if ($first.RunDir) {
                $map = [System.IO.File]::ReadAllText((Join-Path $first.RunDir 'coverage.txt'), $utf8)
                Check ($map.Contains("covered`tперехват|Адаптация|Документ.ЗаказКлиента|модуль объекта|ОбработкаПроведения")) ("перехват ЗаказКлиента не покрыт: {0}" -f $map)
            }
            Start-Sleep -Seconds 2
            Remove-Item -LiteralPath (Join-Path $sb 'fake\fake1c-state.json') -Force -ErrorAction SilentlyContinue
            # Комплект после зелёного прогона ушёл из inbox: кладём его снова.
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ selfcheck = @(@{ tasks = $coverageTasks; fingerprint = 'после' }, @{ tasks = $coverageTasks; fingerprint = 'после2' }); dumps = @{ 'Адаптация' = $coverageDumpSecond } }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'YELLOW' 2
            Check-Step $r 'Карта покрытия' 'WARN'
            if ($r.RunDir) {
                $new = @([System.IO.File]::ReadAllLines((Join-Path $r.RunDir 'coverage.new.txt'), $utf8) | Where-Object { $_ })
                Check ($new.Count -eq 2) ("нового непокрытого {0}, ждали 2: {1}" -f $new.Count, ($new -join ' | '))
                Check (@($new | Where-Object { $_ -match 'РеализацияТоваровУслуг' -and $_ -match 'ПередЗаписью' }).Count -eq 1) 'новый перехват РеализацияТоваровУслуг не в новом непокрытом'
                Check (@($new | Where-Object { $_ -match 'регламентное\|Адаптация\|Адаптация_Чистка' }).Count -eq 1) 'регламентное задание не в новом непокрытом'
                Check (@($new | Where-Object { $_ -match 'ЗаказКлиента' }).Count -eq 0) 'покрытый перехват попал в новое непокрытое'
            }
        }
    },
    @{
        Name = 'gate-coverage-sources'
        Text = 'карта покрытия: компиляция в настоящем формате ключей (КомпиляцияМодулей/ОбщийМодуль|Имя, .../Менеджер|Документы.Имя) - compiled; свой общий модуль - в карте (вызван шагом - covered, только компилируется - compiled, ничем - none); перехват правил обмена на отправку - covered выгрузкой, на загрузку - нет, но covered указанием «покрывает:»; подписка на все документы и подписка без источников - covered; изменён перехват на загрузку без проверки - жёлтый'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $adopted = { param([string]$Kind, [string]$ObjectName) ('<MetaDataObject><{0}><Properties><ObjectBelonging>Adopted</ObjectBelonging><Name>{1}</Name></Properties></{0}></MetaDataObject>' -f $Kind, $ObjectName) }
            $own = { param([string]$ObjectName) ('<MetaDataObject><CommonModule><Properties><Name>{0}</Name></Properties></CommonModule></MetaDataObject>' -f $ObjectName) }
            $exchangeModule = "&После(`"ПКО_Документ_РеализацияТоваровУслуг_Отправка_ПриКонвертацииДанныхXDTO`")`nПроцедура А1()`nКонецПроцедуры`n" +
                "&После(`"ПКО_Документ_ПоступлениеТоваров_Получение_ПриКонвертацииДанныхXDTO`")`nПроцедура А2()`nКонецПроцедуры`n" +
                "&После(`"ПОД_Справочник_Номенклатура_Получение_ПриОбработке`")`nПроцедура А3()`nКонецПроцедуры"
            $dump = @{
                'CommonModules/Адаптация_Свой.xml' = (& $own 'Адаптация_Свой'); 'CommonModules/Адаптация_Свой/Ext/Module.bsl' = 'Процедура А() Экспорт КонецПроцедуры'
                'CommonModules/Адаптация_Вызываемый.xml' = (& $own 'Адаптация_Вызываемый'); 'CommonModules/Адаптация_Вызываемый/Ext/Module.bsl' = 'Функция ЗначениеНастройки() Экспорт КонецФункции'
                'CommonModules/Адаптация_Ничей.xml' = (& $own 'Адаптация_Ничей'); 'CommonModules/Адаптация_Ничей/Ext/Module.bsl' = 'Процедура Б() Экспорт КонецПроцедуры'
                'CommonModules/ОбщегоНазначенияСервер.xml' = (& $adopted 'CommonModule' 'ОбщегоНазначенияСервер')
                'CommonModules/ОбщегоНазначенияСервер/Ext/Module.bsl' = "&После(`"ЗаписатьНастройку`")`nПроцедура Адаптация_ЗаписатьНастройку()`nКонецПроцедуры"
                'Documents/ЗаказКлиента.xml' = (& $adopted 'Document' 'ЗаказКлиента')
                'Documents/ЗаказКлиента/Ext/ManagerModule.bsl' = "&Перед(`"ПриОпределенииНастроек`")`nПроцедура Адаптация_ПриОпределенииНастроек()`nКонецПроцедуры"
                'CommonModules/МенеджерОбменаЧерезУниверсальныйФормат.xml' = (& $adopted 'CommonModule' 'МенеджерОбменаЧерезУниверсальныйФормат')
                'CommonModules/МенеджерОбменаЧерезУниверсальныйФормат/Ext/Module.bsl' = $exchangeModule
                'EventSubscriptions/Адаптация_ВсеДокументы.xml' = '<MetaDataObject><EventSubscription><Properties><Name>Адаптация_ВсеДокументы</Name><Source><v8:Type>cfg:DocumentObject</v8:Type></Source><Handler>CommonModule.Адаптация_Свой.ПередЗаписью</Handler></Properties></EventSubscription></MetaDataObject>'
                'EventSubscriptions/Адаптация_БезИсточников.xml' = '<MetaDataObject><EventSubscription><Properties><Name>Адаптация_БезИсточников</Name><Source/><Handler>CommonModule.Адаптация_Свой.ПриЗаписи</Handler></Properties></EventSubscription></MetaDataObject>'
            }
            $tasks = @(
                @{ key = 'Окружение'; title = 'Окружение и расширения'; step = 'Окружение'; lines = @('[ОК] Обработка запущена под полными правами') },
                @{ key = 'КомпиляцияМодулей/ОбщийМодуль|Адаптация_Свой'; title = 'ОбщийМодуль.Адаптация_Свой'; step = 'КомпиляцияМодулей'; lines = @('[ОК] ОбщийМодуль.Адаптация_Свой: компилируется') },
                @{ key = 'КомпиляцияМодулей/ОбщийМодуль|ОбщегоНазначенияСервер'; title = 'ОбщийМодуль.ОбщегоНазначенияСервер'; step = 'КомпиляцияМодулей'; lines = @('[ОК] ОбщийМодуль.ОбщегоНазначенияСервер: компилируется') },
                @{ key = 'КомпиляцияМодулей/Менеджер|Документы.ЗаказКлиента'; title = 'Документы.ЗаказКлиента, модуль менеджера'; step = 'КомпиляцияМодулей'; lines = @('[ОК] Документы.ЗаказКлиента, модуль менеджера: компилируется') },
                @{ key = 'ОперацииСДокументами|Документ.РеализацияТоваровУслуг'; title = 'Операции: РеализацияТоваровУслуг'; step = 'ОперацииСДокументами'; lines = @('[ОК] Документ.РеализацияТоваровУслуг: новый, проверка заполнения, запись копии') },
                @{ key = 'Настройки'; title = 'Настройки'; step = 'Настройки'; lines = @('[ОК] Адаптация_Вызываемый.ЗначениеНастройки: настройка читается') },
                @{ key = 'ЗащитаЗагрузки'; title = 'Защита загрузки'; step = 'ЗащитаЗагрузки'; lines = @('[ОК] Загрузка от узла прочитана без записи; покрывает: ОбщийМодуль.МенеджерОбменаЧерезУниверсальныйФормат.ПОД_Справочник_Номенклатура_Получение_ПриОбработке') },
                @{ key = 'Обмены'; title = 'Обмены'; step = 'Обмены'; lines = @('[ОК] Обмены, Бухгалтерия: Документ.СписаниеДС: сообщение обмена сформировано без ошибок'); snapshots = @{ ('выгрузка|Бухгалтерия|Документ.СписаниеДС|' + $exchangeUid) = 'ok' } })
            $first = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ selfcheck = @(@{ tasks = $tasks }); dumps = @{ 'Адаптация' = $dump } }
            Check-Common $first
            if (-not $first.RunDir) { return }
            $map = @{}
            foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $first.RunDir 'coverage.txt'), $utf8)) { $parts = $line.TrimStart([char]0xFEFF).Split("`t"); if ($parts.Count -ge 2) { $map[$parts[1]] = $parts[0] } }
            $expect = [ordered]@{
                'модуль|Адаптация|ОбщийМодуль.Адаптация_Свой' = 'compiled'
                'модуль|Адаптация|ОбщийМодуль.Адаптация_Вызываемый' = 'covered'
                'модуль|Адаптация|ОбщийМодуль.Адаптация_Ничей' = 'none'
                'перехват|Адаптация|ОбщийМодуль.ОбщегоНазначенияСервер|модуль|ЗаписатьНастройку' = 'compiled'
                'перехват|Адаптация|Документ.ЗаказКлиента|модуль менеджера|ПриОпределенииНастроек' = 'compiled'
                'перехват|Адаптация|ОбщийМодуль.МенеджерОбменаЧерезУниверсальныйФормат|модуль|ПКО_Документ_РеализацияТоваровУслуг_Отправка_ПриКонвертацииДанныхXDTO' = 'covered'
                'перехват|Адаптация|ОбщийМодуль.МенеджерОбменаЧерезУниверсальныйФормат|модуль|ПКО_Документ_ПоступлениеТоваров_Получение_ПриКонвертацииДанныхXDTO' = 'none'
                'перехват|Адаптация|ОбщийМодуль.МенеджерОбменаЧерезУниверсальныйФормат|модуль|ПОД_Справочник_Номенклатура_Получение_ПриОбработке' = 'covered'
                'подписка|Адаптация|Адаптация_ВсеДокументы' = 'covered'
                'подписка|Адаптация|Адаптация_БезИсточников' = 'covered'
            }
            foreach ($key in @($expect.Keys)) {
                $got = '(нет в карте)'
                if ($map.ContainsKey($key)) { $got = $map[$key] }
                Check ($got -eq $expect[$key]) ("{0}: {1}, ждали {2}" -f $key, $got, $expect[$key])
            }
            # Эталон перехватов правил обмена - этот прогон; во втором меняется перехват на загрузку, а загрузку никто не проверяет.
            $baseline = Join-Path $sb 'baseline\erp_temp_test'
            New-Item -ItemType Directory -Path $baseline -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $first.RunDir 'exchange-rules.state.txt') -Destination (Join-Path $baseline 'exchange-rules.state.txt') -Force
            Copy-Item -LiteralPath (Join-Path $first.RunDir 'exchange-rules.findings.txt') -Destination (Join-Path $baseline 'exchange-rules.findings.txt') -Force
            Copy-Item -LiteralPath (Join-Path $first.RunDir 'coverage.txt') -Destination (Join-Path $baseline 'coverage.txt') -Force
            $dump['CommonModules/МенеджерОбменаЧерезУниверсальныйФормат/Ext/Module.bsl'] = $exchangeModule.Replace("Процедура А2()`nКонецПроцедуры", "Процедура А2()`n	Сообщить(1);`nКонецПроцедуры")
            Start-Sleep -Seconds 2
            Reset-FakeState $sb
            $second = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ selfcheck = @(@{ tasks = $tasks; fingerprint = 'второй' }); dumps = @{ 'Адаптация' = $dump } }
            Check-Common $second
            $step = Get-Step $second 'Карта покрытия'
            Check ($null -ne $step -and $step.status -eq 'WARN' -and [string]$step.detail -match 'перехват правил обмена на загрузку, а загрузку ничто не проверяло.*ПоступлениеТоваров_Получение') ("карта покрытия: изменённый перехват на загрузку без проверки не жёлтый: " + $(if ($null -ne $step) { [string]$step.detail } else { 'шага нет' }))
        }
    },
    @{
        Name = 'gate-exchange-kit-broke'
        Text = 'обмены: до загрузки выгрузка проходила, после упала - красный; «после» выгружает набор «до» (exch=), строка в начале разбора'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ selfcheck = @(@{ tasks = (New-ExchangeResultTasks 'ok') }, @{ tasks = (New-ExchangeResultTasks 'fail'); fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'RED' 1
            Check-Step $r 'Обмены: до и после' 'FAIL'
            Check-Step $r 'Самопроверка после загрузки' 'FAIL'
            Check ((Get-Calls $r @('selfcheck', 'exch=')).Count -eq 1) 'набор объектов «до» (exch=) не передан в самопроверку «после» ровно один раз'
            if ($r.RunDir) {
                $setFile = Join-Path $r.RunDir 'exchange-set.txt'
                Check (Test-Path -LiteralPath $setFile) 'нет файла набора объектов exchange-set.txt'
                if (Test-Path -LiteralPath $setFile) {
                    Check ([System.IO.File]::ReadAllText($setFile, $utf8).Contains(("Бухгалтерия`tДокумент.СписаниеДС`t{0}" -f $exchangeUid))) 'в наборе нет объекта прогона «до»'
                }
                $reportText = [System.IO.File]::ReadAllText((Join-Path $r.RunDir 'report.txt'), $utf8)
                $top = $reportText.Substring(0, [Math]::Max(0, $reportText.IndexOf('КОРОТКО')))
                Check ($top.Contains('ОБМЕН СЛОМАН КОМПЛЕКТОМ')) ("в начале разбора нет строки о сломанном обмене: {0}" -f $top)
            }
        }
    },
    @{
        Name = 'gate-exchange-asis-broken'
        Text = 'обмены: прогон «как есть» (комплекта нет), выгрузка упала - красный, но в начале разбора не «сломан комплектом», а «не выгружается, сломано не им»'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $fake = @{ selfcheck = @(@{ tasks = (New-ExchangeResultTasks 'fail') }) }
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $r
            Check-Step $r 'Обмены: до и после' 'FAIL'
            if ($r.RunDir) {
                $reportText = [System.IO.File]::ReadAllText((Join-Path $r.RunDir 'report.txt'), $utf8)
                $top = $reportText.Substring(0, [Math]::Max(0, $reportText.IndexOf('КОРОТКО')))
                Check ($top.Contains('ОБМЕН НЕ ВЫГРУЖАЕТСЯ (комплекта не было')) ("в начале разбора нет строки «не выгружается, сломано не им»: {0}" -f $top)
                Check (-not $top.Contains('СЛОМАН КОМПЛЕКТОМ')) 'без комплекта написано «сломан комплектом»'
            }
        }
    },
    @{
        Name = 'gate-canapply-engine-ignored'
        Text = 'проверка применимости: замечание движка тестов (UnitTestEngine, «YAXUNIT: Не найден метод ...») не в счёт - его нет в рабочей; замечание своего расширения - в счёт'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $engineLine = 'YAXUNIT: Не найден метод "ErrorDisplayProcessing", указанный в аннотации метода "ЮТErrorDisplayProcessing".'
            $fake = @{ designer = @(@{ match = @('/CheckCanApplyConfigurationExtensions'); exit = 0; log = $engineLine }) }
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Проверка применимости' 'OK'
            $own = @{ designer = @(@{ match = @('/CheckCanApplyConfigurationExtensions'); exit = 0; log = ($engineLine + "`r`n" + 'Адаптация: Не найден метод "ПриЗаписи", указанный в аннотации метода "АГБ_ПриЗаписи".') }) }
            Reset-FakeState $sb
            $r2 = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $own
            Check-Common $r2
            Check-Step $r2 'Проверка применимости' 'FAIL'
        }
    },
    @{
        Name = 'gate-exchange-kit-still-broken'
        Text = 'обмены: выгрузка падает и до, и после загрузки - жёлтый «обмен сломан ещё до загрузки комплекта», в эталоне не прячется'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ selfcheck = @(@{ tasks = (New-ExchangeResultTasks 'fail') }, @{ tasks = (New-ExchangeResultTasks 'fail'); fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'YELLOW' 2
            Check-Step $r 'Обмены: до и после' 'WARN'
            Check-Step $r 'Самопроверка после загрузки' 'OK'
            $step = Get-Step $r 'Обмены: до и после'
            if ($null -ne $step) { Check ([string]$step.detail -match 'обмен сломан ещё до загрузки комплекта' -and [string]$step.detail -match 'ГосКонтракт') ("в шаге нет текста о сломанном до комплекта обмене: {0}" -f $step.detail) }
            if ($r.RunDir) {
                $reportText = [System.IO.File]::ReadAllText((Join-Path $r.RunDir 'report.txt'), $utf8)
                $top = $reportText.Substring(0, [Math]::Max(0, $reportText.IndexOf('КОРОТКО')))
                Check ($top.Contains('обмен сломан ещё до загрузки комплекта')) ("в начале разбора нет строки о сломанном обмене: {0}" -f $top)
            }
        }
    },
    @{
        Name = 'gate-exchange-kit-fixed'
        Text = 'обмены: до загрузки выгрузка падала, после проходит - зелёный, «выгрузка починилась»'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ selfcheck = @(@{ tasks = (New-ExchangeResultTasks 'fail') }, @{ tasks = (New-ExchangeResultTasks 'ok'); fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Обмены: до и после' 'OK'
            $step = Get-Step $r 'Обмены: до и после'
            if ($null -ne $step) { Check ([string]$step.detail -match 'выгрузка починилась') ("в шаге нет «выгрузка починилась»: {0}" -f $step.detail) }
        }
    },
    @{
        Name = 'gate-exchange-rules-r1'
        Text = 'правила обмена: ПКС со свойством конфигурации в правиле со структурой - красный (ИзменениеИКонтроль и &После по имени), правило с объектом и #Удаление - без замечаний, R4 по подрядчику'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ ContractorExtensions = @('Доработки') }
            $fake = @{ selfcheck = @(@{ tasks = (New-ExchangeResultTasks 'ok') }); dumps = @{ 'Доработки' = @{ 'CommonModules/МенеджерОбменаЧерезУниверсальныйФормат/Ext/Module.bsl' = $rulesModule } } }
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $r; Check-Verdict $r 'RED' 1
            Check-Step $r 'Правила обмена' 'FAIL'
            if ($r.RunDir) {
                $lines = @([System.IO.File]::ReadAllLines((Join-Path $r.RunDir 'exchange-rules.txt'), $utf8) | Where-Object { $_ })
                $r1 = @($lines | Where-Object { $_.StartsWith('[ОШИБКА] R1 ') })
                Check ($r1.Count -eq 2) ("ошибок R1 {0}, ждали 2: {1}" -f $r1.Count, ($lines -join ' | '))
                $control = @($r1 | Where-Object { $_ -match 'Склады_ИзСтруктуры' -and $_ -match ('строка {0}:' -f $rulesInsertLine) -and $_ -match '«Ответственный»' })
                Check ($control.Count -eq 1) ("нет R1 на строке {0} в правиле со структурой: {1}" -f $rulesInsertLine, ($r1 -join ' | '))
                Check (@($r1 | Where-Object { $_ -match 'Кассы_ИзСтруктуры' -and $_ -match 'определено по имени' }).Count -eq 1) 'нет R1 для &После по имени правила'
                Check (@($lines | Where-Object { $_ -match 'R1 ' -and $_ -match 'Доработки_ДобавитьПКО_Справочник_Склады \(' }).Count -eq 0) 'замечание на правило с объектом-источником'
                Check (@($lines | Where-Object { $_ -match '«Старое»' }).Count -eq 0) 'замечание на ПКС из #Удаление'
                $r4 = @($lines | Where-Object { $_.StartsWith('[ВНИМАНИЕ] R4 ') })
                Check ($r4.Count -gt 0) 'нет замечаний R4 по расширению подрядчика'
                Check (@($r4 | Where-Object { $_ -match 'Доработки_ДобавитьПКО_Справочник_Кассы_ИзСтруктуры' -and $_ -match 'перехват' }).Count -eq 0) 'R4 на перехват с пометкой автора'
            }
        }
    },
    @{
        Name = 'gate-exchange-rules-exception'
        Text = 'правила обмена: исключение площадки с живым перехватом-гарантией снимает R1 (ИНФО); перехват пропал - снова красный'
        Run = {
            param($Name)
            $exception = @{ Rule = 'Справочник_Склады_ИзСтруктуры'; Property = 'Ответственный'; Reason = 'ключ дописывает перехват'; GuardExtension = 'Адаптация'; GuardMethod = 'СтруктураКлючейСклада' }
            $sb = New-Sandbox $Name -Config @{ ExchangeRuleExceptions = @($exception) }
            $guard = "&Вместо(`"СтруктураКлючейСклада`")`nФункция Адаптация_СтруктураКлючейСклада()`n`tВозврат ПродолжитьВызов();`nКонецФункции"
            $fake = @{ selfcheck = @(@{ tasks = (New-ExchangeResultTasks 'ok') }); dumps = @{
                    'Доработки' = @{ 'CommonModules/МенеджерОбменаЧерезУниверсальныйФормат/Ext/Module.bsl' = $rulesModuleControlOnly }
                    'Адаптация' = @{ 'CommonModules/МенеджерОбменаЧерезУниверсальныйФормат/Ext/Module.bsl' = $guard } } }
            $first = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $first; Check-Verdict $first 'GREEN' 0
            Check-Step $first 'Правила обмена' 'OK'
            if ($first.RunDir) {
                $lines = @([System.IO.File]::ReadAllLines((Join-Path $first.RunDir 'exchange-rules.txt'), $utf8) | Where-Object { $_ })
                Check (@($lines | Where-Object { $_.StartsWith('[ИНФО] R1 ') -and $_ -match 'снято исключением' }).Count -eq 1) ("нет ИНФО «снято исключением»: {0}" -f ($lines -join ' | '))
            }
            Start-Sleep -Seconds 2
            Remove-Item -LiteralPath (Join-Path $sb 'fake\fake1c-state.json') -Force -ErrorAction SilentlyContinue
            $fake.dumps['Адаптация'] = @{ 'CommonModules/МенеджерОбменаЧерезУниверсальныйФормат/Ext/Module.bsl' = "Функция Адаптация_СтруктураКлючейСклада()`n`tВозврат Новый Структура;`nКонецФункции" }
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $r; Check-Verdict $r 'RED' 1
            Check-Step $r 'Правила обмена' 'FAIL'
            $step = Get-Step $r 'Правила обмена'
            if ($r.RunDir) {
                $lines = @([System.IO.File]::ReadAllLines((Join-Path $r.RunDir 'exchange-rules.txt'), $utf8) | Where-Object { $_ })
                Check (@($lines | Where-Object { $_.StartsWith('[ОШИБКА] R1 ') -and $_ -match 'оно не действует' }).Count -eq 1) ("нет R1 «исключение не действует»: {0}" -f ($lines -join ' | '))
            }
        }
    },
    @{
        Name = 'gate-exchange-rules-changed-skip'
        Text = 'правила обмена изменены (R3), а шаг «Обмены» ничего не выгрузил (пропуск) - не зелёный'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $skipTasks = @(
                @{ key = 'Окружение'; title = 'Окружение и расширения'; step = 'Окружение'; lines = @('[ОК] Обработка запущена под полными правами') },
                @{ key = 'Обмены'; title = 'Обмены'; step = 'Обмены'; lines = @('[ПРОПУСК] Обмены: пакет сценариев не назвал узлы обмена для снимков.') })
            $module = "&ИзменениеИКонтроль(`"ДобавитьПКО_Справочник_Склады`")`nПроцедура Доработки_ДобавитьПКО_Справочник_Склады(ПравилаКонвертации)`n`tПравилоКонвертации.ОбъектДанных = Метаданные.Справочники.Склады;`nКонецПроцедуры"
            $fake = @{ selfcheck = @(@{ tasks = $skipTasks }); dumps = @{ 'Доработки' = @{ 'CommonModules/МенеджерОбменаЧерезУниверсальныйФормат/Ext/Module.bsl' = $module } } }
            $first = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $first; Check-Verdict $first 'GREEN' 0
            Check-Step $first 'Правила обмена' 'OK'
            Check ($null -eq (Get-Step $first 'Обмены: до и после')) 'шаг «Обмены: до и после» в первом прогоне, хотя правила не менялись и выгрузок нет'
            Start-Sleep -Seconds 2
            Remove-Item -LiteralPath (Join-Path $sb 'fake\fake1c-state.json') -Force -ErrorAction SilentlyContinue
            $fake.dumps['Доработки'] = @{ 'CommonModules/МенеджерОбменаЧерезУниверсальныйФормат/Ext/Module.bsl' = ($module.Replace('КонецПроцедуры', "`tПравилоКонвертации.ИспользоватьКэш = Ложь;`nКонецПроцедуры")) }
            $fake.selfcheck = @(@{ tasks = $skipTasks; fingerprint = 'второй' })
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $r; Check-Verdict $r 'YELLOW' 2
            Check-Step $r 'Обмены: до и после' 'WARN'
            $step = Get-Step $r 'Обмены: до и после'
            if ($null -ne $step) { Check ([string]$step.detail -match 'правила обмена изменены, а обмен не проверен') ("нет текста «обмен не проверен»: {0}" -f $step.detail) }
            if ($r.RunDir) {
                $changes = @([System.IO.File]::ReadAllLines((Join-Path $r.RunDir 'exchange-rules.changes.txt'), $utf8) | Where-Object { $_ })
                Check ($changes.Count -eq 1 -and $changes[0] -match '^изменён перехват: ') ("изменения перехватов: {0}" -f ($changes -join ' | '))
            }
        }
    },
    @{
        Name = 'gate-parallel-checkconfig'
        Text = 'проверка конфигурации стартует после выгрузки расширений в файлы (ей нужен конфигуратор) и идёт параллельно с самопроверкой, итог - перед вердиктом; сообщения «конфигуратор занят» нет; ci.exe получает оценку, сколько осталось'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ designer = @(@{ match = @('/CheckConfig'); sleep = 6 }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Проверка конфигурации' 'OK'
            if ($null -ne $r.Verdict) {
                $names = @($r.Verdict.steps | ForEach-Object { [string]$_.name })
                $checkAt = [array]::IndexOf($names, 'Проверка конфигурации (all)')
                $selfAt = [array]::IndexOf($names, 'Самопроверка после загрузки')
                Check ($checkAt -gt $selfAt -and $selfAt -ge 0) ("итог проверки конфигурации не после самопроверки: {0}" -f ($names -join ' | '))
            }
            $checkCall = -1
            $selfCall = -1
            for ($i = 0; $i -lt $r.Calls.Count; $i++) {
                if ($checkCall -lt 0 -and $r.Calls[$i].Line.Contains('/CheckConfig')) { $checkCall = $i }
                if ($r.Calls[$i].Line.Contains('selfcheck')) { $selfCall = $i }
            }
            # Журнал подставной 1С пишется по завершении вызова: самопроверка «после» кончилась раньше проверки.
            Check ($selfCall -ge 0 -and $checkCall -gt $selfCall) ("проверка конфигурации кончилась не после самопроверки (вызовы {0} и {1})" -f $checkCall, $selfCall)
            # Старт - по строкам «начато»: после последней выгрузки расширения в файлы (конфигуратор у базы один,
            # раньше выгрузка упиралась в «конфигуратор занят» и ждала всю проверку) и до самопроверки «после».
            $outLines = @($r.Output | ForEach-Object { [string]$_ })
            $startAt = -1
            $lastDumpAt = -1
            $selfStartAt = -1
            for ($i = 0; $i -lt $outLines.Count; $i++) {
                if ($outLines[$i] -match 'Проверка конфигурации \(all\): начато .*идёт параллельно') { $startAt = $i }
                if ($outLines[$i] -match 'Выгрузить .+ в файлы: начато') { $lastDumpAt = $i }
                if ($selfStartAt -lt 0 -and $outLines[$i] -match 'Самопроверка после загрузки: начато') { $selfStartAt = $i }
            }
            Check ($lastDumpAt -ge 0) 'в прогоне не было выгрузки расширений в файлы: порядок старта проверки не проверен'
            Check ($startAt -gt $lastDumpAt -and $selfStartAt -gt $startAt) ("параллельная проверка конфигурации стартовала не между выгрузкой расширений в файлы и самопроверкой (строки {0}, {1}, {2})" -f $lastDumpAt, $startAt, $selfStartAt)
            Check (@($outLines | Where-Object { $_ -match 'конфигуратор занят' }).Count -eq 0) 'в обычном прогоне есть сообщение «конфигуратор занят»'
            $eta = @($r.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('"progress"') -and $_ -match '"remaining":\d+' })
            Check ($eta.Count -gt 0) 'в событиях хода нет оценки, сколько осталось (remaining)'
        }
    },
    @{
        Name = 'gate-accept-menu'
        Text = 'красный прогон, комплект оставлен: в меню пункт «Принять новое последнего прогона в эталон», после подтверждения новое в эталоне и пункт пропадает'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ selfcheck = @(@{ }, @{ tasks = $errorTasks; fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'RED' 1
            $runDir = $r.RunDir
            Check (@($r.Output | Where-Object { $_ -match 'пункт «Принять новое последнего прогона в эталон»' }).Count -eq 1) 'в конце прогона нет подсказки про пункт меню'
            $m = Invoke-Script -Sandbox $sb -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Принять новое последнего прогона в эталон' },
                @{ Kind = 'confirm'; Header = 'Принять новое прогона'; Yes = $true },
                @{ Kind = 'one'; Header = 'Посмотрел'; Item = '^Вернуться в меню' },
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            Check-Common $m
            Check (Test-Path -LiteralPath (Join-Path $runDir 'accepted.txt')) 'прогон не отмечен принятым (accepted.txt)'
            $norm = Join-Path $sb 'baseline\erp_temp_test\selfcheck.norm.txt'
            Check ((Test-Path -LiteralPath $norm) -and ([System.IO.File]::ReadAllText($norm, $utf8) -match 'не компилируется')) 'новая ошибка не попала в эталон самопроверки'
            $menus = @($m.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('Гейт расширений') })
            Check ($menus.Count -eq 2) ("меню показано {0} раз, ждали 2" -f $menus.Count)
            if ($menus.Count -eq 2) {
                Check ($menus[0].Contains('Принять новое последнего прогона')) 'в первом меню нет пункта принятия'
                Check (-not $menus[1].Contains('Принять новое последнего прогона')) 'после принятия пункт остался в меню'
            }
        }
    },
    @{
        Name = 'gate-site-config'
        Text = 'настройки площадки из config.site.psd1: ключа нет в config.psd1 - берётся из поставки (R4 по подрядчику)'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            [System.IO.File]::WriteAllLines((Join-Path $sb 'config.site.psd1'), [string[]]@('@{', "    ContractorExtensions = @('Доработки')", '}'), $utf8Bom)
            $fake = @{ selfcheck = @(@{ tasks = (New-ExchangeResultTasks 'ok') }); dumps = @{ 'Доработки' = @{ 'CommonModules/МенеджерОбменаЧерезУниверсальныйФормат/Ext/Module.bsl' = $rulesModule } } }
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $r
            if ($r.RunDir) {
                $lines = @([System.IO.File]::ReadAllLines((Join-Path $r.RunDir 'exchange-rules.txt'), $utf8))
                Check (@($lines | Where-Object { $_.StartsWith('[ВНИМАНИЕ] R4 ') }).Count -gt 0) 'R4 не сработал: ContractorExtensions из config.site.psd1 не подхватился'
                Check ([System.IO.File]::ReadAllText((Join-Path $r.RunDir 'run.log'), $utf8) -match 'config\.site\.psd1: ContractorExtensions') 'в run.log нет строки о настройках площадки'
            }
        }
    },
    @{
        Name = 'gate-metrics-slow'
        Text = 'время ключевых операций: проведение стало в 9 раз дольше истории - жёлтый; замер не попадает в снимки'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $statsDir = Join-Path $sb 'stats'
            New-Item -ItemType Directory -Path $statsDir -Force | Out-Null
            $metricKey = 'проведение|Документ.РеализацияТоваровУслуг|11111111-0000-0000-0000-000000000001'
            $history = @(
                ("2026-11-10 10:00:00`terp_temp_test`t20261110-100000`tafter`t{0}`t110" -f $metricKey),
                ("2026-11-11 10:00:00`terp_temp_test`t20261111-100000`tafter`t{0}`t95" -f $metricKey),
                ("2026-11-11 10:00:00`terp_temp_test`t20261111-100000`tafter`tпроведение|Документ.Другой|x`t5000" -f $metricKey))
            [System.IO.File]::WriteAllLines((Join-Path $statsDir 'metrics.csv'), [string[]]$history, $utf8Bom)
            $tasksWith = {
                param([string]$Ms)
                return @(
                    @{ key = 'Окружение'; title = 'Окружение и расширения'; step = 'Окружение'; lines = @('[ОК] Обработка запущена под полными правами') },
                    @{ key = 'ПерепроведениеДокументов|Документ|РеализацияТоваровУслуг'; title = 'Перепроведение'; step = 'ПерепроведениеДокументов'
                        lines = @('[ОК] Реализация 1: перепроведён, движений 4, как и было'); snapshots = @{ ('время|' + $metricKey) = $Ms } }
                )
            }
            $fake = @{ selfcheck = @(@{ tasks = (& $tasksWith '100') }, @{ tasks = (& $tasksWith '900'); fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake $fake
            Check-Common $r; Check-Verdict $r 'YELLOW' 2
            Check-Step $r 'Время ключевых операций' 'WARN'
            $step = Get-Step $r 'Время ключевых операций'
            if ($null -ne $step) { Check ([string]$step.detail -match '900 мс, обычно 100 мс') ("в шаге нет замера: {0}" -f $step.detail) }
            if ($r.RunDir) {
                Check (-not (Test-Path -LiteralPath (Join-Path $r.RunDir 'selfcheck-after.snapshots.txt'))) 'замер попал в снимки'
                $metricsFile = Join-Path $r.RunDir 'selfcheck-after.metrics.txt'
                Check ((Test-Path -LiteralPath $metricsFile) -and [System.IO.File]::ReadAllText($metricsFile, $utf8).Contains("900`t" + $metricKey)) 'нет файла замеров после'
            }
            $after = @([System.IO.File]::ReadAllLines((Join-Path $statsDir 'metrics.csv'), $utf8) | Where-Object { $_ -match [regex]::Escape($metricKey) })
            Check ($after.Count -eq 4) ("в истории {0} замеров ключа, ждали 4 (2 было, до и после)" -f $after.Count)
        }
    },
    @{
        Name = 'nightly-asis-and-menu'
        Text = 'ночной прогон: run.ps1 «как есть» без вопросов, итог в nightly\last.json, утром он в меню гейта'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $r = Invoke-Script -Sandbox $sb -Script 'nightly.ps1'
            Check (-not $r.TimedOut) 'ночной прогон не уложился'
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check ([string]::IsNullOrWhiteSpace($r.Stderr)) ("stderr: " + ([string]$r.Stderr).Trim())
            $lastFile = Join-Path $sb 'nightly\last.json'
            if (Test-Path -LiteralPath $lastFile) {
                $last = [System.IO.File]::ReadAllText($lastFile, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
                Check ($last.verdict -eq 'GREEN') ("вердикт ночного прогона {0}, ждали GREEN" -f $last.verdict)
                Check ($last.runId -match '^\d{8}-\d{6}$' -and (Test-Path -LiteralPath (Join-Path $sb ('runs\' + $last.runId + '\verdict.json')))) ("нет прогона {0}" -f $last.runId)
                Check (Test-Path -LiteralPath ([string]$last.log)) 'нет файла вывода ночного прогона'
            }
            else { Check $false 'нет nightly\last.json' }
            $menu = Invoke-Script -Sandbox $sb -Answers @(@{ Kind = 'one'; Header = '^Гейт расширений'; Item = '^Выход$' })
            Check ($menu.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($menu.Unexpected -join ' | '))
            Check (@($menu.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('ночной прогон') -and $_.Contains('ЗЕЛЁНЫЙ') }).Count -gt 0) 'в меню гейта нет итога ночного прогона'
        }
    },
    @{
        Name = 'nightly-install-denied-window'
        Text = 'ночной прогон: время из окна 22:00-02:00 не принимается, задание не создаётся'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $r = Invoke-Script -Sandbox $sb -Script 'nightly.ps1' -Arguments '-Install -At 23:15'
            Check ($r.ExitCode -eq 1) ("код возврата {0}, ждали 1" -f $r.ExitCode)
            Check (@($r.Output | Where-Object { $_ -match 'часы 22:00-02:00' }).Count -gt 0) 'нет объяснения про часы 22:00-02:00'
        }
    },
    @{
        Name = 'nightly-install-denied-custom'
        Text = 'ночной прогон: запретные часы из настроек (NightlyDeniedFrom/To), 03:00 при запрете 02-05 не принимается'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ NightlyDeniedFrom = 2; NightlyDeniedTo = 5 }
            $r = Invoke-Script -Sandbox $sb -Script 'nightly.ps1' -Arguments '-Install -At 03:00'
            Check ($r.ExitCode -eq 1) ("код возврата {0}, ждали 1" -f $r.ExitCode)
            Check (@($r.Output | Where-Object { $_ -match 'часы 02:00-05:00' }).Count -gt 0) 'нет объяснения про часы 02:00-05:00'
        }
    },
    @{
        Name = 'deploy-all-green'
        Text = 'обновление рабочей «все»: изменённое расширение и обработка, блокировки поставлены и сняты, отчёт с разницей по обработке'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState -TempProcessings @((New-PrintProcessing '2' $printNew)) -ProdProcessings @((New-PrintProcessing '1' $printOld))
            $fake = @{ regepf = @(@{ status = 'done'; old = 'прежняя печать'; objversion = '2'; oldversion = '1' }) }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Fake $fake -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить все' },
                @{ Kind = 'many'; Header = 'внешние обработки'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            $record = Get-DeployRecord $sb
            Check ($null -ne $record) 'нет deploy.json'
            if ($null -ne $record) {
                Check ($record.outcome -eq 'updated') ("итог {0}, ждали updated" -f $record.outcome)
                Check ((@($record.extensions | ForEach-Object { $_.name }) -join ',') -eq 'Адаптация') ("обновлены расширения: {0}" -f (@($record.extensions | ForEach-Object { $_.name }) -join ','))
                $proc = @($record.processings)
                Check ($proc.Count -eq 1 -and $proc[0].name -eq 'Печать') 'в deploy.json нет обработки Печать'
                if ($proc.Count -eq 1) {
                    Check ($proc[0].backup -and (Test-Path -LiteralPath (Join-Path $record.Dir $proc[0].backup))) ("нет резервной копии обработки: {0}" -f $proc[0].backup)
                    Check ($proc[0].oldVersion -eq '1' -and $proc[0].newVersion -eq '2') ("версии обработки {0} -> {1}" -f $proc[0].oldVersion, $proc[0].newVersion)
                }
                $article = Join-Path $record.Dir 'article.html'
                if (Test-Path -LiteralPath $article) { Check ([System.IO.File]::ReadAllText($article, $utf8).Contains('+ НоваяПроцедура')) 'в отчёте нет новой процедуры обработки' }
                else { Check $false 'нет article.html' }
            }
            Check ((Get-Calls $r @('/LoadCfg', '-Extension Адаптация', 'fake\erp_base')).Count -eq 1) 'Адаптация не загружена в рабочую ровно один раз'
            Check ((Get-Calls $r @('/LoadCfg', 'Доработки')).Count -eq 0) 'загружено неизменённое расширение Доработки'
            Check ((Get-Calls $r @('ENTERPRISE', 'regepf', 'name=Печать.epf')).Count -eq 1) 'обработка не записана в рабочую'
            Check (@($r.ComLog | Where-Object { $_ -match 'UpdateInfoBase erp_base scheduledJobsDenied=1' }).Count -gt 0) 'блокировку регламентных заданий не ставили'
        }
    },
    @{
        Name = 'deploy-sessions-lock'
        Text = 'обновление выбранных: в рабочей сеанс - блокировка начала сеансов, сеанс завершён, в конце блокировки сняты'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState -Sessions @(@{ id = 5; base = 'erp_base'; app = '1CV8C'; user = 'Пользователь'; host = 'pc1' }, @{ id = 6; base = 'erp_temp_test'; app = '1CV8C'; user = 'Тест'; host = 'pc2' })
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer,
                @{ Kind = 'one'; Header = 'В erp_base есть сеансы'; Item = 'Поставить блокировку' })
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check (@($r.ComLog | Where-Object { $_ -match 'TerminateSession 5$' }).Count -eq 1) 'сеанс рабочей не завершён'
            Check (@($r.ComLog | Where-Object { $_ -match 'TerminateSession 6$' }).Count -eq 0) 'завершён сеанс тестовой базы'
            Check (@($r.ComLog | Where-Object { $_ -match 'UpdateInfoBase erp_base .*sessionsDenied=1' }).Count -gt 0) 'блокировку начала сеансов не ставили'
            Check ((Get-Calls $r @('/UpdateDBCfg', '-Extension Адаптация', 'fake\erp_base')).Count -eq 1) 'конфигурация БД рабочей не обновлена'
        }
    },
    @{
        Name = 'deploy-sessions-warn'
        Text = 'обновление: в рабочей сеанс, «предупредить» - блокировка сеансов с будущего времени и сообщением, выгрузки до закрытия, потом сеанс завершён и загрузка'
        Run = {
            param($Name)
            $config = $deployConfig.Clone()
            $config['DeployWarnMinutes'] = 0.1
            $sb = New-Sandbox $Name -Config $config
            $com = New-ComState -Sessions @(@{ id = 5; base = 'erp_base'; app = '1CV8C'; user = 'Пользователь'; host = 'pc1' }, @{ id = 6; base = 'erp_temp_test'; app = '1CV8C'; user = 'Тест'; host = 'pc2' })
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer,
                @{ Kind = 'one'; Header = 'В erp_base есть сеансы'; Item = '^Предупредить пользователей' },
                @{ Kind = 'one'; Header = 'Пользователи erp_base предупреждены'; Wait = $true })
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            $lock = @($r.ComLog | Where-Object { $_ -match 'UpdateInfoBase erp_base .*sessionsDenied=1' } | Select-Object -First 1)
            Check ($lock.Count -eq 1) 'блокировку начала сеансов не ставили'
            if ($lock.Count -eq 1) {
                $fromSec = [int]([regex]::Match($lock[0], 'deniedFromSec=(-?\d+)').Groups[1].Value)
                Check ($fromSec -gt 0) ("блокировка начала сеансов не с будущего времени: начало через {0} с" -f $fromSec)
                Check ($lock[0] -match 'message=.*Сохраните работу') ("в блокировке нет предупреждения пользователям: {0}" -f $lock[0])
            }
            Check (@($r.Questions | Where-Object { $_ -match 'Пользователи erp_base предупреждены' }).Count -eq 1) 'не было ожидания закрытия базы'
            Check (@($r.ComLog | Where-Object { $_ -match 'TerminateSession 5$' }).Count -eq 1) 'сеанс рабочей не завершён после предупреждения'
            Check (@($r.ComLog | Where-Object { $_ -match 'TerminateSession 6$' }).Count -eq 0) 'завершён сеанс тестовой базы'
            Check ((Get-Calls $r @('/LoadCfg', '-Extension Адаптация', 'fake\erp_base')).Count -eq 1) 'Адаптация не загружена в рабочую'
            Check ((Get-Calls $r @('/UpdateDBCfg', '-Extension Адаптация', 'fake\erp_base')).Count -eq 1) 'конфигурация БД рабочей не обновлена'
            # Выгрузки и резервная копия - до завершения сеанса (пока пользователи сохраняются), загрузка - после.
            $text = @($r.Output) -join "`n"
            $backupAt = $text.IndexOf('[OK]   Резервная копия Адаптация')
            $closedAt = $text.IndexOf('Закрытие рабочей базы:')
            $loadAt = $text.IndexOf('[OK]   Загрузить Адаптация в erp_base')
            Check ($backupAt -ge 0 -and $closedAt -gt $backupAt) 'резервная копия не до закрытия базы'
            Check ($closedAt -ge 0 -and $loadAt -gt $closedAt) 'загрузка в рабочую не после закрытия базы'
            if ($null -ne $r.ComState) { Check (-not [bool]$r.ComState.bases.erp_base.sessionsDenied) 'блокировка начала сеансов осталась' }
        }
    },
    @{
        Name = 'deploy-sessions-warn-cancel'
        Text = 'обновление: отмена во время предупреждения пользователей - в рабочую ничего не загружено, блокировки сняты'
        Run = {
            param($Name)
            $config = $deployConfig.Clone()
            $config['DeployWarnMinutes'] = 5
            $sb = New-Sandbox $Name -Config $config
            $com = New-ComState -Sessions @(@{ id = 5; base = 'erp_base'; app = '1CV8C'; user = 'Пользователь'; host = 'pc1' })
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer,
                @{ Kind = 'one'; Header = 'В erp_base есть сеансы'; Item = '^Предупредить пользователей' },
                @{ Kind = 'one'; Header = 'Пользователи erp_base предупреждены'; Item = '^Отмена' })
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check ($r.ExitCode -eq 1) ("код возврата {0}, ждали 1" -f $r.ExitCode)
            Check ((Get-Calls $r @('/LoadCfg', 'fake\erp_base')).Count -eq 0) 'после отмены что-то загружено в рабочую'
            Check ((Get-Calls $r @('/UpdateDBCfg', 'fake\erp_base')).Count -eq 0) 'после отмены обновляли конфигурацию БД рабочей'
            Check (@($r.ComLog | Where-Object { $_ -match 'TerminateSession 5$' }).Count -eq 0) 'после отмены завершён сеанс пользователя'
            if ($null -ne $r.ComState) {
                Check (-not [bool]$r.ComState.bases.erp_base.sessionsDenied) 'после отмены осталась блокировка начала сеансов'
                Check (-not [bool]$r.ComState.bases.erp_base.scheduledJobsDenied) 'после отмены осталась блокировка регламентных заданий'
            }
        }
    },
    @{
        Name = 'deploy-temp-designer-closed'
        Text = 'обновление: открыт конфигуратор temp - вопрос до начала, ответ «закрыть» завершает только его сеанс, обновление идёт'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState -Sessions @(@{ id = 7; base = 'erp_temp_test'; app = 'Designer'; user = 'Разработчик'; host = 'pc3' })
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer,
                @{ Kind = 'one'; Header = 'Открыт конфигуратор erp_temp_test'; Item = '^Закрыть отсюда' })
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check (@($r.ComLog | Where-Object { $_ -match 'TerminateSession 7$' }).Count -eq 1) 'конфигуратор temp не закрыт'
            Check ((Get-Calls $r @('/UpdateDBCfg', '-Extension Адаптация', 'fake\erp_base')).Count -eq 1) 'конфигурация БД рабочей не обновлена'
            # Кавычки ключа /UC"0" подставная 1С получает уже разобранными: /UC0.
            Check ((Get-Calls $r @('/UC0')).Count -gt 0) 'конфигуратор запускался без кода разрешения 0 (UnlockCode по умолчанию)'
        }
    },
    @{
        Name = 'deploy-red-gate-cancel'
        Text = 'гейт красный, на переспрос «нет»: в рабочую ничего не грузится, блокировки не ставятся'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $runDir = Join-Path $sb 'runs\20261117-090000'
            New-Item -ItemType Directory -Path $runDir -Force | Out-Null
            $verdict = @{ verdict = 'RED'; kit = 'inbox\тест'; kitDecision = 'kept'; steps = @(@{ name = 'Самопроверка после загрузки'; status = 'FAIL'; detail = 'новые ошибки: 1' }) }
            [System.IO.File]::WriteAllText((Join-Path $runDir 'verdict.json'), (ConvertTo-Json -InputObject $verdict -Depth 5), $utf8)
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить все' },
                @{ Kind = 'confirm'; Header = 'красный'; Yes = $false })
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0) 'после «нет» что-то загружено'
            Check (@($r.ComLog | Where-Object { $_ -match 'UpdateInfoBase' }).Count -eq 0) 'после «нет» трогали свойства рабочей'
        }
    },
    @{
        Name = 'deploy-red-gate-reason'
        Text = 'гейт красный, выпуск с причиной: причина в deploy.json и отчёте, released.txt в прогоне, эталон не принят, прогон остаётся RED'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $runDir = Join-Path $sb 'runs\20261117-090000'
            New-Item -ItemType Directory -Path $runDir -Force | Out-Null
            $verdict = @{ verdict = 'RED'; kit = 'inbox\тест'; kitDecision = 'kept'; steps = @(@{ name = 'Модульные тесты'; status = 'FAIL'; detail = 'новых падений 2' }) }
            [System.IO.File]::WriteAllText((Join-Path $runDir 'verdict.json'), (ConvertTo-Json -InputObject $verdict -Depth 5), $utf8)
            [System.IO.File]::WriteAllLines((Join-Path $runDir 'unittests.txt'), [string[]]@("FAIL`tМодуль.Тест`tТаблица не найдена"), $utf8Bom)
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить все' },
                @{ Kind = 'confirm'; Header = 'красный'; Yes = $true },
                @{ Kind = 'text'; Header = 'Причина выпуска'; Text = '' },
                @{ Kind = 'text'; Header = 'Причина выпуска'; Text = 'тест упал в подготовке данных' },
                $deployNameAnswer)
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            $record = Get-DeployRecord $sb
            Check ($null -ne $record) 'нет deploy.json'
            if ($null -ne $record) {
                Check ($record.outcome -eq 'updated') ("итог {0}, ждали updated" -f $record.outcome)
                Check ([bool]$record.riskAccepted) 'riskAccepted не записан'
                Check ([string]$record.riskReason -eq 'тест упал в подготовке данных') ("причина в deploy.json: «{0}»" -f $record.riskReason)
                $article = Join-Path $record.Dir 'article.html'
                if (Test-Path -LiteralPath $article) { Check ([System.IO.File]::ReadAllText($article, $utf8).Contains('Причина выпуска: тест упал в подготовке данных')) 'в отчёте нет причины выпуска' }
            }
            $released = Join-Path $runDir 'released.txt'
            Check (Test-Path -LiteralPath $released) 'в прогоне нет released.txt'
            if (Test-Path -LiteralPath $released) {
                $text = [System.IO.File]::ReadAllText($released, $utf8)
                Check ($text -match 'riskAccepted=1' -and $text -match 'reason=тест упал в подготовке данных') ("released.txt: {0}" -f $text.Trim())
            }
            Check (-not (Test-Path -LiteralPath (Join-Path $runDir 'accepted.txt'))) 'красный прогон принят в эталон после выпуска'
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'baseline'))) 'после выпуска с красным гейтом появился эталон'
            $after = [System.IO.File]::ReadAllText((Join-Path $runDir 'verdict.json'), $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            Check ($after.verdict -eq 'RED') ("вердикт прогона после выпуска: {0}" -f $after.verdict)
            Check (@($r.Output | Where-Object { $_ -match 'Эталон не тронут' }).Count -gt 0) 'нет строки «эталон не тронут»'
            $runReport = Join-Path $runDir 'report.txt'
            Check ((Test-Path -LiteralPath $runReport) -and [System.IO.File]::ReadAllText($runReport, $utf8).Contains('с отклонением, причина: тест упал в подготовке данных')) 'в report.txt прогона нет строки выпуска с причиной'
        }
    },
    @{
        Name = 'deploy-red-gate-no-reason'
        Text = 'гейт красный, выпуск подтверждён, но причины нет (Esc): в рабочую ничего не грузится'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $runDir = Join-Path $sb 'runs\20261117-090000'
            New-Item -ItemType Directory -Path $runDir -Force | Out-Null
            $verdict = @{ verdict = 'RED'; kit = 'inbox\тест'; kitDecision = 'kept'; steps = @() }
            [System.IO.File]::WriteAllText((Join-Path $runDir 'verdict.json'), (ConvertTo-Json -InputObject $verdict -Depth 5), $utf8)
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить все' },
                @{ Kind = 'confirm'; Header = 'красный'; Yes = $true },
                @{ Kind = 'text'; Header = 'Причина выпуска'; Cancel = $true })
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0) 'без причины что-то загружено'
            Check (@($r.ComLog | Where-Object { $_ -match 'UpdateInfoBase' }).Count -eq 0) 'без причины трогали свойства рабочей'
            Check (-not (Test-Path -LiteralPath (Join-Path $runDir 'released.txt'))) 'без выпуска появился released.txt'
        }
    },
    @{
        Name = 'deploy-yellow-ask-accept'
        Text = '«Обновить все» с жёлтым прогоном: после обновления вопрос про эталон, «не принимать» - эталон не тронут, released.txt без риска'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $runDir = Join-Path $sb 'runs\20261117-090000'
            New-Item -ItemType Directory -Path $runDir -Force | Out-Null
            $verdict = @{ verdict = 'YELLOW'; kit = 'inbox\тест'; kitDecision = 'kept'; steps = @(@{ name = 'Самопроверка после загрузки'; status = 'WARN'; detail = 'новое: 1' }) }
            [System.IO.File]::WriteAllText((Join-Path $runDir 'verdict.json'), (ConvertTo-Json -InputObject $verdict -Depth 5), $utf8)
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить все' },
                $deployNameAnswer,
                @{ Kind = 'confirm'; Header = 'Принять новое прогона 20261117-090000'; Yes = $false })
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check (-not (Test-Path -LiteralPath (Join-Path $runDir 'accepted.txt'))) 'жёлтый принят в эталон, хотя ответили «не принимать»'
            # Вопрос про эталон - после снятия блокировок рабочей, и Enter в нём - «не принимать».
            $text = @($r.Output) -join "`n"
            $locksAt = $text.IndexOf('Снял с erp_base')
            if ($locksAt -lt 0) { $locksAt = $text.IndexOf('Блокировок на erp_base нет') }
            $questionLine = @($r.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('Принять новое прогона 20261117-090000') } | Select-Object -First 1)
            Check ($questionLine.Count -eq 1 -and $locksAt -ge 0 -and $text.IndexOf($questionLine[0]) -gt $locksAt) 'вопрос про эталон задан до снятия блокировок рабочей'
            if ($questionLine.Count -eq 1) { Check ($questionLine[0].Contains('"defaultNo":true')) 'в вопросе про эталон Enter не «не принимать»' }
            $released = Join-Path $runDir 'released.txt'
            Check (Test-Path -LiteralPath $released) 'в прогоне нет released.txt'
            if (Test-Path -LiteralPath $released) { Check ([System.IO.File]::ReadAllText($released, $utf8) -match 'riskAccepted=0') 'released.txt: выпуск жёлтого записан как риск' }
        }
    },
    @{
        Name = 'deploy-denied-hours'
        Text = 'обновление рабочей в запретные часы: остановка до записи, в тексте - окно из настроек'
        Run = {
            param($Name)
            $config = $deployConfig.Clone()
            $hourNow = (Get-Date).Hour
            $config['DeployDeniedFrom'] = $hourNow
            $config['DeployDeniedTo'] = ($hourNow + 2) % 24
            $sb = New-Sandbox $Name -Config $config
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                $deployRiskAnswer)
            Check ($r.ExitCode -ne 0) 'в запретные часы deploy не остановился'
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0) 'в запретные часы что-то загружено'
            $window = 'с {0:00}:00 до {1:00}:00' -f (($hourNow + 2) % 24), $hourNow
            Check (@($r.Output | Where-Object { $_.Contains('обновляем только ' + $window) }).Count -gt 0) ("нет объяснения с окном {0}" -f $window)
        }
    },
    @{
        Name = 'deploy-snapshot-temp'
        Text = 'снимок temp для прогона (deploy -SnapshotTemp): хеш-суммы расширений и обработок в файл, рабочую не трогает'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $file = Join-Path $sb 'snap.json'
            $com = New-ComState -TempProcessings @((New-PrintProcessing '2' $printNew))
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments ('-SnapshotTemp "{0}"' -f $file) -Com $com
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            if (-not (Test-Path -LiteralPath $file)) { Check $false 'нет файла снимка'; return }
            $snap = [System.IO.File]::ReadAllText($file, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            Check ([bool]$snap.ok) ("снимок не снялся: {0}" -f $snap.error)
            Check ([string]$snap.extensions.'Адаптация'.hash -eq 'h2') ("хеш Адаптация в снимке: {0}" -f $snap.extensions.'Адаптация'.hash)
            Check ($null -ne $snap.processings.'Печать' -and [string]$snap.processings.'Печать'.hash) 'в снимке нет обработки Печать'
            Check (@($r.ComLog | Where-Object { $_ -match 'erp_base' }).Count -eq 0) 'снимок temp обращался к рабочей'
        }
    },
    @{
        Name = 'deploy-checked-state'
        Text = 'зелёный прогон со снимком: совпало - обновление без вопроса про гейт; temp изменён после прогона - вопрос «состав расходится», «нет» - ничего не загружено'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $runDir = Join-Path $sb 'runs\20261117-090000'
            New-Item -ItemType Directory -Path $runDir -Force | Out-Null
            $checked = @{ ok = $true; extensions = @{ 'Адаптация' = @{ version = '1.0.0.h2'; hash = 'h2' }; 'Доработки' = @{ version = '1.0.0.1'; hash = 'hd' } }; processings = @{} }
            $verdict = @{ verdict = 'GREEN'; kit = 'inbox\тест'; kitDecision = 'kept'; kitSource = 'git owner/ext@0123456789abcdef0123456789abcdef01234567'; steps = @(); checkedState = $checked }
            [System.IO.File]::WriteAllText((Join-Path $runDir 'verdict.json'), (ConvertTo-Json -InputObject $verdict -Depth 6), $utf8)
            $same = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                $deployNameAnswer)
            Check-DeployCommon $same
            Check ($same.ExitCode -eq 0) ("совпало: код возврата {0}, ждали 0" -f $same.ExitCode)
            Check (@($same.Output | Where-Object { $_ -match 'состав совпадает с проверенным прогоном 20261117-090000' }).Count -gt 0) 'нет строки о совпадении с проверенным'
            $record = Get-DeployRecord $sb
            if ($null -ne $record) {
                Check ([string]$record.gate.kitSource -eq 'git owner/ext@0123456789abcdef0123456789abcdef01234567') ("kitSource в deploy.json: {0}" -f $record.gate.kitSource)
                Check (@($record.gate.installed | Where-Object { $_.name -eq 'Адаптация' -and $_.hash -eq 'h2' }).Count -eq 1) 'в deploy.json нет выпущенного хеша Адаптация'
            }
            else { Check $false 'нет deploy.json' }
            Start-Sleep -Seconds 2
            Reset-FakeState $sb
            $other = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com (New-ComState -TempHash 'h3') -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                @{ Kind = 'confirm'; Header = 'состав расходится с проверенным прогоном 20261117-090000: Адаптация: в temp не то'; Yes = $false })
            Check ($other.ExitCode -eq 0) ("расходится: код возврата {0}, ждали 0" -f $other.ExitCode)
            Check ($other.Unexpected.Count -eq 0 -and $other.UnusedAnswers -eq 0) ("temp изменён после прогона, а вопроса не было: " + ($other.Unexpected -join ' | '))
            Check ((Get-Calls $other @('/LoadCfg')).Count -eq 0) 'после «нет» что-то загружено'
        }
    },
    @{
        Name = 'deploy-prepared-uses-prepared-run'
        Text = 'подготовили с красным прогоном A, потом прошёл зелёный B: «подготовленным» показывает и спрашивает по A'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $runA = Join-Path $sb 'runs\20261117-090000'
            New-Item -ItemType Directory -Path $runA -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $runA 'verdict.json'), (ConvertTo-Json -InputObject @{ verdict = 'RED'; kit = 'A'; kitDecision = 'kept'; steps = @() } -Depth 5), $utf8)
            $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Prepare' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Подготовка обновления erp_base'; Item = '^Подготовить все' },
                @{ Kind = 'confirm'; Header = 'гейт 20261117-090000 красный'; Yes = $true },
                @{ Kind = 'text'; Header = 'Причина выпуска'; Text = 'дефект в неиспользуемом отчёте' },
                $deployNameAnswer)
            Check ($first.ExitCode -eq 0) ("подготовка: код возврата {0}, ждали 0" -f $first.ExitCode)
            $runB = Join-Path $sb 'runs\20261117-100000'
            New-Item -ItemType Directory -Path $runB -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $runB 'verdict.json'), (ConvertTo-Json -InputObject @{ verdict = 'GREEN'; kit = 'B'; kitDecision = 'kept'; steps = @() } -Depth 5), $utf8)
            Start-Sleep -Seconds 2
            Reset-FakeState $sb
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-ApplyPrepared' -Answers @(
                @{ Kind = 'confirm'; Header = 'гейт 20261117-090000 красный'; Yes = $false })
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check ($r.Unexpected.Count -eq 0 -and $r.UnusedAnswers -eq 0) ("«подготовленным» не спросил про красный A: " + ($r.Unexpected -join ' | '))
            Check ((Get-Calls $r @('/UpdateDBCfg')).Count -eq 0) 'после «нет» конфигурация БД обновлена'
        }
    },
    @{
        Name = 'deploy-journal-interrupted'
        Text = 'обновление оборвалось (журнал inProgress, процесса нет): deploy разбирает - что успело, сверка рабочей, «прервано»; откат видит его в списке'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $dir = Join-Path $sb 'deploy\20261117-230000'
            New-Item -ItemType Directory -Path (Join-Path $dir 'before') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dir 'before\erp_base_Адаптация_1.cfe'), 'старая', $utf8)
            $journal = @{ runId = '20261117-230000'; time = '2026-11-17T23:00:00'; base = 'erp_base'; tempBase = 'erp_temp_test'; user = 'u'; mode = '2'; outcome = 'inProgress'
                step = 'loading'; rollbackOf = ''; pid = 999999; processStart = '2026-11-17T23:00:00'; gate = $null; riskAccepted = $false; risks = @(); riskReason = ''
                extensions = @(@{ name = 'Адаптация'; status = 'changed'; backup = 'before\erp_base_Адаптация_1.cfe'; oldVersion = '1.0.0.h1'; newVersion = '1.0.0.h2'; stage = 'loading'; oldHash = 'h1'; newHash = 'h2' })
                processings = @(@{ name = 'Печать'; fileName = 'Печать.epf'; action = 'register'; ref = ''; isNew = ''; backup = ''; file = ''; oldVersion = '1'; newVersion = '2'; stage = 'writing' }); light = @(); article = '' }
            [System.IO.File]::WriteAllText((Join-Path $dir 'deploy.json'), (ConvertTo-Json -InputObject $journal -Depth 6), $utf8)
            # Сеанс записи обработки успел сохранить прежнюю версию (old.b64) и оборвался.
            New-Item -ItemType Directory -Path (Join-Path $dir 'epf\Печать') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dir 'epf\Печать\old.b64'), 'c3RhcmF5YQ==', $utf8)
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com (New-ComState -ProdHash 'h2')
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check ((Get-Calls $r @('fake\erp_base', '/LoadCfg')).Count -eq 0) 'при разборе прерванного что-то загружено в рабочую'
            $text = @($r.Output) -join "`n"
            Check ($text.Contains('прервано') -and $text.Contains('Адаптация: шла загрузка; в конфигурации рабочей новая версия')) 'разбор прерванного не показал, что успело'
            $after = [System.IO.File]::ReadAllText((Join-Path $dir 'deploy.json'), $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            Check ($after.outcome -eq 'interrupted') ("outcome после разбора: {0}" -f $after.outcome)
            $proc = @($after.processings)[0]
            Check ([string]$proc.backup -and (Test-Path -LiteralPath (Join-Path $dir ([string]$proc.backup)))) ("копия обработки из old.b64 не подхвачена: «{0}»" -f $proc.backup)
            Reset-FakeState $sb
            $rb = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Rollback' -Answers @(
                @{ Kind = 'one'; Header = 'Откат erp_base'; Cancel = $true })
            Check (@($rb.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('Откат erp_base') -and $_.Contains('ПРЕРВАНО') }).Count -ge 1) ("в списке отката нет прерванного: " + ($rb.Questions -join ' | '))
            Check ((Get-Calls $rb @('/LoadCfg')).Count -eq 0) 'отменённый откат что-то загрузил'
        }
    },
    @{
        Name = 'deploy-interrupted-locks-own'
        Text = 'оборвавшийся deploy оставил свою блокировку сеансов и запрет регламентных (locks.json): следующий запуск спрашивает и возвращает как было до него'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-InterruptedLockCom -Message 'Обновление [abc123]'
            Write-InterruptedLockFile $sb -Marker 'abc123' -JobsSet $true
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @(
                @{ Kind = 'confirm'; Header = 'оставленные прерванным обновлением'; Yes = $true })
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            $prod = $r.ComState.bases.erp_base
            Check (-not [bool]$prod.sessionsDenied) 'своя блокировка начала сеансов осталась'
            Check (-not [bool]$prod.scheduledJobsDenied) 'свой запрет регламентных остался'
            Check ([string]$prod.deniedMessage -eq '') ("сообщение не вернулось к прежнему: «{0}»" -f $prod.deniedMessage)
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'deploy\20261117-230000\locks.json'))) 'locks.json не убран после снятия'
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0) 'после разбора блокировок что-то загружено'
        }
    },
    @{
        Name = 'deploy-interrupted-locks-foreign'
        Text = 'после обрыва блокировку сеансов поменяли (не та метка): deploy её не трогает, запрет регламентных - только по «да»; ответ «нет» оставляет всё'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-InterruptedLockCom -Message 'Чужие работы [zzz999]'
            Write-InterruptedLockFile $sb -Marker 'abc123' -JobsSet $true
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @(
                @{ Kind = 'confirm'; Header = 'оставленные прерванным обновлением'; Yes = $false })
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            $prod = $r.ComState.bases.erp_base
            Check ([bool]$prod.sessionsDenied -and ([string]$prod.deniedMessage).Contains('zzz999')) 'чужая блокировка сеансов снята или изменена'
            Check ([bool]$prod.scheduledJobsDenied) 'запрет регламентных снят без согласия'
            Check (Test-Path -LiteralPath (Join-Path $sb 'deploy\20261117-230000\locks.json')) 'locks.json убран, хотя блокировки оставлены'
            $text = @($r.Output) -join "`n"
            Check ($text.Contains('не та, что ставил прерванный запуск')) 'не сказано, что блокировка сеансов чужая'
        }
    },
    @{
        Name = 'deploy-interrupted-locks-other-target'
        Text = 'locks.json записан для другого кластера с тем же именем базы: не сверяет и не снимает, файл остаётся'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-InterruptedLockCom -Message 'Обновление [abc123]'
            Write-InterruptedLockFile $sb -Marker 'abc123' -JobsSet $true -Target 'другой-кластер|erp_base'
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Cancel = $true })
            Check (@($r.Questions | Where-Object { $_.Contains('прерванным обновлением') }).Count -eq 0) 'спросил про блокировки чужой цели'
            $prod = $r.ComState.bases.erp_base
            Check ([bool]$prod.sessionsDenied -and [bool]$prod.scheduledJobsDenied) 'блокировки сняты по записи другой цели'
            Check (Test-Path -LiteralPath (Join-Path $sb 'deploy\20261117-230000\locks.json')) 'locks.json другой цели убран'
        }
    },
    @{
        Name = 'deploy-interrupted-locks-status-only'
        Text = '-StatusOnly при оставшихся своих блокировках: показывает, но не спрашивает и не снимает'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-InterruptedLockCom -Message 'Обновление [abc123]'
            Write-InterruptedLockFile $sb -Marker 'abc123' -JobsSet $true
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-StatusOnly' -Com $com
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            $prod = $r.ComState.bases.erp_base
            Check ([bool]$prod.sessionsDenied -and [bool]$prod.scheduledJobsDenied) 'просмотр снял блокировки'
            Check (Test-Path -LiteralPath (Join-Path $sb 'deploy\20261117-230000\locks.json')) 'просмотр убрал locks.json'
            Check ((@($r.Output) -join "`n").Contains('только просмотр: не снимаю')) 'просмотр не показал оставшиеся блокировки'
        }
    },
    @{
        Name = 'deploy-interrupted-locks-none'
        Text = 'locks.json от оборвавшегося запуска, а блокировок на рабочей уже нет: без вопросов убирает файл и идёт обычным путём'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            Write-InterruptedLockFile $sb -Marker 'abc123' -JobsSet $true
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $r
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'deploy\20261117-230000\locks.json'))) 'locks.json без блокировок не убран'
            Check (@($r.Questions | Where-Object { $_.Contains('прерванным обновлением') }).Count -eq 0) 'спросил про блокировки, которых нет'
        }
    },
    @{
        Name = 'deploy-journal-written'
        Text = 'обычное обновление: журнал deploy.json по ходу, в конце - updated без следов inProgress и .tmp'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $r
            $record = Get-DeployRecord $sb
            if ($null -eq $record) { Check $false 'нет deploy.json'; return }
            Check ($record.outcome -eq 'updated') ("итог {0}" -f $record.outcome)
            Check (-not (Test-Path -LiteralPath (Join-Path $record.Dir 'deploy.json.tmp'))) 'остался deploy.json.tmp'
            Check (-not (Test-Path -LiteralPath (Join-Path $record.Dir 'locks.json'))) 'после снятия блокировок остался locks.json'
            $comLog = Join-Path $sb 'fake\com.log'
            if (Test-Path -LiteralPath $comLog) { Check ([System.IO.File]::ReadAllText($comLog, $utf8).Contains('sessionsDenied=1')) 'обновление шло без блокировки сеансов - locks.json не проверен' }
            $log = Join-Path $record.Dir 'run.log'
            if (Test-Path -LiteralPath $log) { Check (-not ([System.IO.File]::ReadAllText($log, $utf8).Contains('Журнал обновления не записался'))) 'журнал обновления не записался' }
        }
    },
    @{
        Name = 'deploy-update-fail-rollback'
        Text = 'обновление БД рабочей не прошло: откат к резервной копии, итог rolledBack, блокировки сняты'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $fake = @{ designer = @(@{ match = @('/UpdateDBCfg', 'erp_base'); exit = 1; log = 'Ошибка обновления: тест'; times = 1 }) }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Fake $fake -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить все' },
                $deployRiskAnswer, $deployNameAnswer,
                @{ Kind = 'confirm'; Header = 'Откатить\?'; Yes = $true })
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 1) ("код возврата {0}, ждали 1" -f $r.ExitCode)
            $record = Get-DeployRecord $sb
            if ($null -ne $record) { Check ($record.outcome -eq 'rolledBack') ("итог {0}, ждали rolledBack" -f $record.outcome) } else { Check $false 'нет deploy.json' }
            $loads = (Get-Calls $r @('/LoadCfg', '-Extension Адаптация', 'fake\erp_base'))
            Check ($loads.Count -eq 2) ("загрузок Адаптация в рабочую {0}, ждали 2 (новая и резервная копия)" -f $loads.Count)
            if ($loads.Count -eq 2) { Check ($loads[1].Line.Contains('\before\erp_base_Адаптация_')) 'откат грузил не резервную копию' }
        }
    },
    @{
        Name = 'deploy-compare-failed-backup'
        Text = 'сравнить через COM с рабочей не удалось: есть ли расширение в рабочей - по её выгрузке, резервная копия делается, откат грузит её'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState
            $com['failConnect'] = @('erp_base')
            $fake = @{ designer = @(@{ match = @('/UpdateDBCfg', 'erp_base'); exit = 1; log = 'Ошибка обновления: тест'; times = 1 }) }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Fake $fake -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить все' },
                $deployRiskAnswer, $deployNameAnswer,
                @{ Kind = 'confirm'; Header = 'Откатить\?'; Yes = $true })
            Check (-not $r.TimedOut) 'не уложился во время'
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check (@($r.Output | Where-Object { $_ -match '^Остановлено: |ParserError' }).Count -eq 0) 'скрипт упал'
            $backups = (Get-Calls $r @('/DumpCfg', 'fake\erp_base', '\before\erp_base_Адаптация_'))
            Check ($backups.Count -eq 1) ("резервных копий Адаптация из рабочей {0}, ждали 1" -f $backups.Count)
            $loads = (Get-Calls $r @('/LoadCfg', '-Extension Адаптация', 'fake\erp_base'))
            Check ($loads.Count -eq 2) ("загрузок Адаптация в рабочую {0}, ждали 2 (новая и резервная копия)" -f $loads.Count)
            if ($loads.Count -eq 2) { Check ($loads[1].Line.Contains('\before\erp_base_Адаптация_')) 'откат грузил не резервную копию' }
        }
    },
    @{
        Name = 'deploy-canapply-code0-remarks'
        Text = 'проверка применимости вернула 0, но в журнале замечания: лёгкий прогон не пишет «замечаний нет»'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $fake = @{ designer = @(@{ match = @('/CheckCanApplyConfigurationExtensions', 'erp_base'); exit = 0; log = 'БазаЗнаний (1.0): Не найден метод "Тест", указанный в аннотации метода "БЗ_Тест".' }) }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Fake $fake -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить все' },
                $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $r
            Check (@($r.Output | Where-Object { $_ -match 'Проверка применимости' -and $_ -match 'замечаний 1 \(код 0\)' }).Count -gt 0) 'замечание проверки применимости при коде 0 не показано'
        }
    },
    @{
        Name = 'deploy-light-fail-keep-question'
        Text = 'проверки после обновления нашли проблему: сводка, вопрос кнопками внизу (оставить или откатить); «оставить» - обновлено, блокировки сняты'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $fake = @{ canary = @(@{ status = 'error' }) }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Fake $fake -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить все' },
                $deployRiskAnswer, $deployNameAnswer,
                @{ Kind = 'one'; Header = 'Оставить обновление в erp_base'; Item = '^Оставить$' })
            Check-DeployCommon $r
            Check (@($r.Output | Where-Object { $_ -match 'ИТОГ ПРОВЕРОК ПОСЛЕ ОБНОВЛЕНИЯ' }).Count -eq 1) 'нет сводки проверок перед вопросом'
            $question = @($r.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('Оставить обновление в erp_base') })
            Check ($question.Count -eq 1 -and $question[0].Contains('"dock"') -and $question[0].Contains('DeployKeepTimeoutMin')) 'вопрос не внизу экрана или без срока ожидания'
            $record = Get-DeployRecord $sb
            if ($null -ne $record) { Check ($record.outcome -eq 'updated') ("итог {0}, ждали updated" -f $record.outcome) } else { Check $false 'нет deploy.json' }
        }
    },
    @{
        Name = 'deploy-light-fail-no-wait'
        Text = 'DeployKeepTimeoutMin = 0: после проблемных проверок не спрашивает, обновление оставлено, блокировки сняты'
        Run = {
            param($Name)
            $config = @{}
            foreach ($key in $deployConfig.Keys) { $config[$key] = $deployConfig[$key] }
            $config['DeployKeepTimeoutMin'] = 0
            $sb = New-Sandbox $Name -Config $config
            $fake = @{ canary = @(@{ status = 'error' }) }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Fake $fake -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить все' },
                $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $r
            Check (@($r.Output | Where-Object { $_ -match 'не спрашиваю, обновление оставлено' }).Count -eq 1) 'нет строки об оставленном обновлении'
            $record = Get-DeployRecord $sb
            if ($null -ne $record) { Check ($record.outcome -eq 'updated') ("итог {0}, ждали updated" -f $record.outcome) } else { Check $false 'нет deploy.json' }
        }
    },
    @{
        Name = 'deploy-base-state'
        Text = '«Показать состояние баз»: блокировка сеансов (код тот же), сообщение, регламентные, конфигуратор; в базе ничего не меняется'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState -ProdJobsDenied $true -Sessions @(@{ id = 9; base = 'erp_base'; app = 'Designer'; user = 'Разработчик'; host = 'pc9' })
            $com.bases.erp_base.sessionsDenied = $true
            $com.bases.erp_base.permissionCode = '0'
            $com.bases.erp_base.deniedMessage = 'Идёт обновление'
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-BaseState' -Com $com
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            $text = $r.Output -join "`n"
            Check ($text -match 'Блокировка начала сеансов: ВКЛЮЧЕНА') 'нет блокировки сеансов рабочей'
            Check ($text -match 'код разрешения: тот же, что UnlockCode') 'нет строки о коде разрешения'
            Check ($text -match 'сообщение: Идёт обновление') 'нет сообщения блокировки'
            Check ($text -match 'Блокировка регламентных заданий: ВКЛЮЧЕНА') 'нет блокировки регламентных'
            Check ($text -match 'из них конфигураторов: 1') 'нет конфигуратора в сеансах'
            Check (@($r.ComLog | Where-Object { $_ -match '\tUpdateInfoBase |\tTerminateSession ' }).Count -eq 0) 'состояние баз что-то поменяло'
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'deploy\state\deploy.json'))) 'появился deploy.json'
            $runDirs = @(Get-ChildItem -LiteralPath (Join-Path $sb 'deploy') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}$' })
            Check ($runDirs.Count -eq 0) 'показ состояния создал папку запуска обновления'
        }
    },
    @{
        Name = 'deploy-com-check'
        Text = '«Проверка внешнего соединения»: по шагам, чем читаются расширения temp, и итог обычного чтения; только temp, конфигуратор не запускается, блокировки не трогаются'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-ComCheck' -Com (New-ComState)
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check (@($r.Output | Where-Object { $_ -cmatch 'ПРОВЕРКА ВНЕШНЕГО СОЕДИНЕНИЯ С erp_temp_test' }).Count -eq 1) 'нет заголовка проверки'
            Check (@($r.Output | Where-Object { $_ -match '\[есть\] менеджер, PowerShell: соединение\.ConfigurationExtensions' }).Count -eq 1) 'нет строки о менеджере расширений'
            Check (@($r.Output | Where-Object { $_ -match '\[есть\] хеш-сумма, PowerShell' }).Count -eq 1) 'нет строки о хеш-сумме'
            Check (@($r.Output | Where-Object { $_ -match 'Адаптация: версия 1\.0\.0\.h2, хеш-сумма есть' }).Count -eq 1) 'обычное чтение не показало расширение с версией'
            Check (@($r.Output | Where-Object { $_ -match 'ИТОГ: расширения erp_temp_test через внешнее соединение читаются: 2' }).Count -eq 1) 'нет итога проверки'
            Check (@($r.Calls).Count -eq 0) ("проверка запускала 1С: {0}" -f (@($r.Calls | ForEach-Object { $_.Line } | Select-Object -First 2) -join ' | '))
            Check (@($r.ComLog | Where-Object { $_ -match '\tUpdateInfoBase |\tTerminateSession ' }).Count -eq 0) 'проверка меняла блокировки или сеансы'
            Check (Test-Path -LiteralPath (Join-Path $sb 'deploy\comcheck\run.log')) 'нет журнала deploy\comcheck\run.log'
        }
    },
    @{
        Name = 'deploy-prod-precheck'
        Text = '«Проверка рабочей перед обновлением»: обработка самопроверки пересобрана из поставки конфигуратором temp, клиент рабочей в режиме precheck, журнал на экране и в файле, счёт ошибок и предупреждений; в рабочей ничего не меняется; второй раз обработка не пересобирается'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $src = Join-Path $sb 'tools\src'
            New-Item -ItemType Directory -Path (Join-Path $src 'ВыполнитьПослеОбновления\Ext') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $src 'ВыполнитьПослеОбновления.xml'), '<MetaDataObject><ExternalDataProcessor><Properties><Name>ВыполнитьПослеОбновления</Name></Properties></ExternalDataProcessor></MetaDataObject>', $utf8)
            [System.IO.File]::WriteAllText((Join-Path $src 'ВыполнитьПослеОбновления\Ext\ObjectModule.bsl'), 'Процедура А() КонецПроцедуры', $utf8)
            $journal = @(
                'Проверка перед обновлением (только чтение), сборка обработки 20261117.999999, 19.11.2026 18:00:00',
                '=== Перед обновлением: что изменит загрузка комплекта (только чтение) ===',
                '18:00:02 [ИНФО]     Кнопка «Создать настройки»: настройка будет создана',
                '18:00:02 [ВНИМАНИЕ] В регистре есть значения, которые очистит новый тип поля:',
                ((' ' * 20) + 'Документ.Пример: записей 3'),
                '18:00:03 [ОШИБКА]   Регистр: проверку выполнить не удалось')
            $fake = @{ precheck = @(@{ lines = $journal }) }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-ProdPreCheck' -Fake $fake -Com (New-ComState)
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            $text = $r.Output -join "`n"
            Check ($text -match 'ПРОВЕРКА erp_base ПЕРЕД ОБНОВЛЕНИЕМ') 'нет заголовка проверки'
            Check ($text -match 'настройка будет создана') 'журнала проверки нет на экране'
            Check ($text -match 'Документ\.Пример: записей 3') 'нет строки продолжения журнала'
            Check ($text -match 'ошибок 1, предупреждений 1, пропусков 0') 'нет итога «ошибок 1, предупреждений 1, пропусков 0»'
            # Обработку собирает конфигуратор temp; конфигуратор рабочей не открывается вообще.
            $builds = Get-Calls $r @('/LoadExternalDataProcessorOrReportFromFiles')
            Check ($builds.Count -eq 1 -and $builds[0].Line.Contains('fake\erp_temp_test')) ("сборок обработки самопроверки {0}, ждали одну конфигуратором temp" -f $builds.Count)
            Check (@($r.Calls | Where-Object { $_.Line.Contains('DESIGNER') -and $_.Line.Contains('fake\erp_base') }).Count -eq 0) 'проверка открывала конфигуратор рабочей'
            $epf = Join-Path $sb 'tools\ВыполнитьПослеОбновления.epf'
            Check (([System.IO.File]::ReadAllText($epf) -match '^FAKEEPF') -and (Test-Path -LiteralPath ($epf + '.source.txt'))) 'обработка самопроверки не собрана из поставки'
            Check ((Get-Calls $r @('ENTERPRISE', 'precheck', 'fake\erp_base')).Count -eq 1) 'клиент рабочей в режиме precheck не запускался'
            Check ((Get-Calls $r @('ENTERPRISE', 'selfcheck')).Count -eq 0) 'запускалась полная самопроверка'
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0 -and (Get-Calls $r @('/UpdateDBCfg')).Count -eq 0) 'проверка что-то загружала'
            Check (@($r.ComLog | Where-Object { $_ -match '\tUpdateInfoBase |\tTerminateSession ' }).Count -eq 0) 'проверка меняла блокировки или сеансы'
            Check (Test-Path -LiteralPath (Join-Path $sb 'deploy\precheck\precheck.txt')) 'нет журнала deploy\precheck\precheck.txt'
            $runDirs = @(Get-ChildItem -LiteralPath (Join-Path $sb 'deploy') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}$' })
            Check ($runDirs.Count -eq 0) 'проверка создала папку запуска обновления'
            Reset-FakeState $sb
            $again = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-ProdPreCheck' -Fake $fake -Com (New-ComState)
            Check-DeployCommon $again -LocksExpected $false
            Check ((Get-Calls $again @('/LoadExternalDataProcessorOrReportFromFiles')).Count -eq 0) 'вторая проверка снова собирала обработку'
            Check ((Get-Calls $again @('ENTERPRISE', 'precheck', 'fake\erp_base')).Count -eq 1) 'вторая проверка не запустила клиент рабочей'
            # Отпечаток исходников считают оба скрипта: функции должны совпадать слово в слово, иначе обработка
            # пересобиралась бы по кругу - то гейтом, то проверкой.
            $hashPattern = '(?s)function Get-ToolSourceHash \{.*?\n\}'
            $inRun = [regex]::Match([System.IO.File]::ReadAllText((Join-Path $sb 'run.ps1'), $utf8), $hashPattern).Value
            $inDeploy = [regex]::Match([System.IO.File]::ReadAllText((Join-Path $sb 'deploy.ps1'), $utf8), $hashPattern).Value
            Check ($inRun -and $inRun -eq $inDeploy) 'Get-ToolSourceHash в run.ps1 и deploy.ps1 разошлись: отпечаток обработок должен быть один'
        }
    },
    @{
        Name = 'deploy-prod-precheck-old-epf'
        Text = '«Проверка рабочей перед обновлением»: обработка режима не знает (отметки запуска нет) - до конца не ждёт, клиент снят, причина названа; в рабочей ничего не меняется'
        Run = {
            param($Name)
            $config = $deployConfig.Clone()
            $config['CanaryTimeoutSec'] = 5
            $sb = New-Sandbox $Name -Config $config
            $fake = @{ precheck = @(@{ nostart = $true }) }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-ProdPreCheck' -Fake $fake -Com (New-ComState)
            Check (-not $r.TimedOut) ("не уложился в {0} с" -f $TimeoutSec)
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check ($r.ExitCode -eq 1) ("код возврата {0}, ждали 1" -f $r.ExitCode)
            $text = $r.Output -join "`n"
            Check ($text -match 'не начала проверку за 5 с') 'нет причины «не начала проверку»'
            Check ($text -match 'пересоберёт её из поставки') 'нет подсказки про сборку обработки'
            Check ($r.Seconds -lt 90) ("ждал зависший клиент: {0} с" -f $r.Seconds)
            Check (@($r.ComLog | Where-Object { $_ -match '\tUpdateInfoBase |\tTerminateSession ' }).Count -eq 0) 'проверка меняла блокировки или сеансы'
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'deploy\precheck\precheck.txt'))) 'журнал проверки появился, хотя проверки не было'
        }
    },
    @{
        Name = 'menu-prod-precheck'
        Text = 'меню гейта: «Проверка рабочей перед обновлением» запускает проверку рабочей и возвращается в меню по кнопке'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $r = Invoke-Script -Sandbox $sb -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Проверка рабочей перед обновлением' },
                @{ Kind = 'one'; Header = 'Посмотрел'; Item = '^Вернуться в меню' },
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check ($r.UnusedAnswers -eq 0) ("тест ждал вопросов, а их не было: {0}" -f $r.UnusedAnswers)
            # -cmatch: без учёта регистра под выражение подходит и итоговая строка «Проверка ... перед обновлением: ошибок ...».
            Check (@($r.Output | Where-Object { $_ -cmatch 'ПРОВЕРКА erp_base ПЕРЕД ОБНОВЛЕНИЕМ' }).Count -eq 1) 'проверка из меню не запустилась'
            Check (@($r.Output | Where-Object { $_ -match 'В базе ничего не изменено' }).Count -eq 1) 'нет итога проверки'
            Check ((Get-Calls $r @('ENTERPRISE', 'precheck', 'fake\erp_base')).Count -eq 1) 'клиент рабочей в режиме precheck не запускался'
        }
    },
    @{
        Name = 'deploy-prepare-apply'
        Text = 'обновление в два приёма: подготовка - копии и загрузка без блокировок, сеансов и обновления БД; «подготовленным» - без загрузки, БД обновлена, блокировки сняты, подготовки больше нет'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState -Sessions @(@{ id = 5; base = 'erp_base'; app = '1CV8C'; user = 'Пользователь'; host = 'pc1' })
            $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Prepare' -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Подготовка обновления erp_base'; Item = '^Подготовить все' },
                $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $first -LocksExpected $false
            Check ($first.ExitCode -eq 0) ("подготовка: код возврата {0}, ждали 0" -f $first.ExitCode)
            $preparedFile = Join-Path $sb 'deploy\prepared.json'
            Check (Test-Path -LiteralPath $preparedFile) 'подготовка не записала deploy\prepared.json'
            Check ((Get-Calls $first @('/DumpCfg', 'fake\erp_base', '\before\erp_base_Адаптация_')).Count -eq 1) 'подготовка не сняла резервную копию Адаптация'
            Check ((Get-Calls $first @('/LoadCfg', '-Extension Адаптация', 'fake\erp_base')).Count -eq 1) 'подготовка не загрузила Адаптация в рабочую ровно один раз'
            Check ((Get-Calls $first @('/UpdateDBCfg')).Count -eq 0) 'подготовка обновила конфигурацию БД'
            Check (@($first.ComLog | Where-Object { $_ -match '\tUpdateInfoBase |\tTerminateSession ' }).Count -eq 0) 'подготовка меняла блокировки или завершала сеансы'
            Check ($null -eq (Get-DeployRecord $sb)) 'подготовка записала deploy.json: в истории обновлений её быть не должно'
            if (-not (Test-Path -LiteralPath $preparedFile)) { return }
            $state = [System.IO.File]::ReadAllText($preparedFile, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            Check (-not [bool]$state.partial) 'подготовка записана как незаконченная'
            $item = @($state.extensions)[0]
            Check ($item.name -eq 'Адаптация' -and $item.backup -and (Test-Path -LiteralPath $item.backup)) ("в prepared.json нет резервной копии Адаптация: {0}" -f $item.backup)
            Check ($item.tempHash -eq 'h2' -and $item.prodHash -eq 'h1') ("хеш-суммы подготовки {0} / {1}, ждали h2 / h1" -f $item.tempHash, $item.prodHash)

            Start-Sleep -Seconds 2
            Reset-FakeState $sb
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-ApplyPrepared' -Answers @(
                $deployRiskAnswer, $deployNameAnswer,
                @{ Kind = 'one'; Header = 'В erp_base есть сеансы'; Item = 'Поставить блокировку' })
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0) '«подготовленным» что-то загружало'
            Check ((Get-Calls $r @('/DumpCfg', 'fake\erp_base')).Count -eq 0) '«подготовленным» снимало резервную копию: она сняла бы загруженную версию'
            Check ((Get-Calls $r @('/UpdateDBCfg', '-Extension Адаптация', 'fake\erp_base')).Count -eq 1) 'конфигурация БД рабочей не обновлена'
            Check (@($r.ComLog | Where-Object { $_ -match 'TerminateSession 5$' }).Count -eq 1) 'сеанс рабочей не завершён'
            Check (@($r.ComLog | Where-Object { $_ -match 'UpdateInfoBase erp_base .*sessionsDenied=1' }).Count -gt 0) 'блокировку начала сеансов не ставили'
            Check (-not (Test-Path -LiteralPath $preparedFile)) 'после обновления подготовленным prepared.json остался'
            $record = Get-DeployRecord $sb
            if ($null -eq $record) { Check $false 'нет deploy.json'; return }
            Check ($record.mode -eq 'prepared' -and $record.outcome -eq 'updated') ("режим {0}, итог {1}, ждали prepared, updated" -f $record.mode, $record.outcome)
            Check ($record.preparedRun -eq $state.runId) ("подготовка в deploy.json {0}, ждали {1}" -f $record.preparedRun, $state.runId)
            $ext = @($record.extensions)
            Check ($ext.Count -eq 1 -and $ext[0].name -eq 'Адаптация') 'в deploy.json нет Адаптация'
            if ($ext.Count -eq 1) { Check ($ext[0].backup -and (Test-Path -LiteralPath (Join-Path $record.Dir $ext[0].backup))) ("резервной копии нет в папке запуска (откату нечем): {0}" -f $ext[0].backup) }
        }
    },
    @{
        Name = 'deploy-prepared-processings-none'
        Text = '«обновить подготовленным», а обработки temp и рабочей различаются: в вопросе ничего не отмечено и пустой выбор разрешён; Enter без отметок - расширение обновлено, ни одна обработка не записана'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState -TempProcessings @((New-PrintProcessing '2' $printNew)) -ProdProcessings @((New-PrintProcessing '1' $printOld))
            $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Prepare' -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Подготовка обновления erp_base'; Item = '^Подготовить все' },
                $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $first -LocksExpected $false
            Check ($first.ExitCode -eq 0) ("подготовка: код возврата {0}, ждали 0" -f $first.ExitCode)
            Check (Test-Path -LiteralPath (Join-Path $sb 'deploy\prepared.json')) 'подготовка не записала deploy\prepared.json'
            Start-Sleep -Seconds 2
            Reset-FakeState $sb
            # Пустой выбор обработок: Enter без отметок.
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-ApplyPrepared' -Com $com -Answers @(
                @{ Kind = 'many'; Header = 'Какие внешние обработки записать'; Indexes = @() },
                $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0: {1}" -f $r.ExitCode, (($r.Output | Select-Object -Last 3) -join ' | '))
            $asked = @(foreach ($line in @($r.Output | Where-Object { $_.StartsWith('@@ui:') })) {
                    $uiEvent = $null
                    try { $uiEvent = $line.Substring(5) | ConvertFrom-Json } catch { $uiEvent = $null }
                    if ($null -ne $uiEvent -and [string]$uiEvent.kind -eq 'many' -and ([string]$uiEvent.header).StartsWith('Какие внешние обработки записать')) { $uiEvent }
                })
            Check ($asked.Count -eq 1) ("вопрос об обработках задан {0} раз, ждали 1" -f $asked.Count)
            if ($asked.Count -eq 1) {
                Check (@($asked[0].preselected).Count -eq 0) 'в режиме «подготовленным» обработки отмечены заранее: подготовка их не касалась'
                Check ($null -ne $asked[0].PSObject.Properties['allowEmpty'] -and [bool]$asked[0].allowEmpty) 'вопрос об обработках не разрешает пустой выбор (allowEmpty)'
            }
            Check ((Get-Calls $r @('/UpdateDBCfg', '-Extension Адаптация', 'fake\erp_base')).Count -eq 1) 'конфигурация БД рабочей не обновлена'
            Check ((Get-Calls $r @('regepf')).Count -eq 0) 'при пустом выборе обработка записывалась в рабочую'
            Check (@($r.Output | Where-Object { $_ -match 'не отмечено ни одной - не трогаю' }).Count -eq 1) 'не сказано, что обработки не тронуты'
            $record = Get-DeployRecord $sb
            if ($null -eq $record) { Check $false 'нет deploy.json'; return }
            Check ($record.mode -eq 'prepared' -and $record.outcome -eq 'updated') ("режим {0}, итог {1}, ждали prepared, updated" -f $record.mode, $record.outcome)
            Check (@($record.extensions).Count -eq 1 -and @($record.extensions)[0].name -eq 'Адаптация') 'в deploy.json нет Адаптация'
            Check (@($record.processings).Count -eq 0) ("в deploy.json записаны обработки: {0}" -f (@($record.processings | ForEach-Object { $_.name }) -join ', '))
        }
    },
    @{
        Name = 'deploy-prepare-guard-cancel'
        Text = 'пока есть подготовка, одним проходом не обновляем; temp изменили - «подготовленным» переспрашивает; отмена подготовки грузит резервную копию без обновления БД и блокировок'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Prepare' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Подготовка обновления erp_base'; Item = '^Подготовить все' },
                $deployRiskAnswer, $deployNameAnswer)
            Check ($first.ExitCode -eq 0) ("подготовка: код возврата {0}, ждали 0" -f $first.ExitCode)
            $preparedFile = Join-Path $sb 'deploy\prepared.json'
            if (-not (Test-Path -LiteralPath $preparedFile)) { Check $false 'подготовка не записала deploy\prepared.json'; return }

            Start-Sleep -Seconds 2
            Reset-FakeState $sb
            $single = Invoke-Script -Sandbox $sb -Script 'deploy.ps1'
            Check ($single.ExitCode -eq 1) ("один проход при подготовке: код возврата {0}, ждали 1" -f $single.ExitCode)
            Check (@($single.Output | Where-Object { $_ -match '^Остановлено: Обновление одним проходом сейчас нельзя' }).Count -eq 1) 'один проход не объяснил, что мешает подготовка'
            Check ($single.Unexpected.Count -eq 0) ("один проход задал вопросы: " + ($single.Unexpected -join ' | '))
            Check ((Get-Calls $single @('fake\erp_base', '/DumpCfg')).Count -eq 0 -and (Get-Calls $single @('fake\erp_base', '/LoadCfg')).Count -eq 0) 'один проход при подготовке трогал рабочую'

            Start-Sleep -Seconds 2
            Reset-FakeState $sb
            $changed = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-ApplyPrepared' -Com (New-ComState -TempHash 'h3') -Answers @(
                @{ Kind = 'confirm'; Header = 'после подготовки изменено'; Yes = $false })
            Check ($changed.ExitCode -eq 0) ("отказ обновлять подготовленным: код возврата {0}, ждали 0" -f $changed.ExitCode)
            Check ($changed.Unexpected.Count -eq 0 -and $changed.UnusedAnswers -eq 0) 'temp изменён после подготовки, а вопроса не было'
            Check ((Get-Calls $changed @('/UpdateDBCfg')).Count -eq 0) 'после отказа конфигурация БД обновлена'
            Check (Test-Path -LiteralPath $preparedFile) 'после отказа подготовка пропала'

            Start-Sleep -Seconds 2
            Reset-FakeState $sb
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-CancelPrepared' -Answers @(
                @{ Kind = 'confirm'; Header = 'Вернуть расширения erp_base к применённым версиям'; Yes = $true })
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("отмена подготовки: код возврата {0}, ждали 0" -f $r.ExitCode)
            $loads = (Get-Calls $r @('/LoadCfg', '-Extension Адаптация', 'fake\erp_base'))
            Check ($loads.Count -eq 1) ("отмена: загрузок Адаптация в рабочую {0}, ждали 1 (резервная копия)" -f $loads.Count)
            if ($loads.Count -eq 1) { Check ($loads[0].Line.Contains('\before\erp_base_Адаптация_')) 'отмена грузила не резервную копию' }
            Check ((Get-Calls $r @('/UpdateDBCfg')).Count -eq 0) 'отмена подготовки обновила конфигурацию БД'
            Check ((Get-Calls $r @('/DeleteCfg')).Count -eq 0) 'отмена подготовки удаляла расширение'
            Check (@($r.ComLog | Where-Object { $_ -match '\tUpdateInfoBase |\tTerminateSession ' }).Count -eq 0) 'подготовка или её отмена меняли блокировки или завершали сеансы'
            Check (-not (Test-Path -LiteralPath $preparedFile)) 'после отмены prepared.json остался'
        }
    },
    @{
        Name = 'menu-prod-prepare'
        Text = 'меню гейта: перед выбранным действием - событие reset для ci.exe (шаги и вердикт прошлого прогона убираются); «Подготовить обновление рабочей» ведёт подготовку и возвращается в меню; там появляются «Обновить рабочую подготовленным» и «Отменить подготовку»'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $r = Invoke-Script -Sandbox $sb -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Подготовить обновление рабочей' },
                @{ Kind = 'one'; Header = 'Подготовка обновления erp_base'; Item = '^Подготовить все' },
                $deployRiskAnswer, $deployNameAnswer,
                @{ Kind = 'one'; Header = 'Посмотрел'; Item = '^Вернуться в меню' },
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Отменить подготовку рабочей' },
                @{ Kind = 'confirm'; Header = 'Вернуть расширения erp_base к применённым версиям'; Yes = $true },
                @{ Kind = 'one'; Header = 'Посмотрел'; Item = '^Вернуться в меню' },
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check ($r.UnusedAnswers -eq 0) ("тест ждал вопросов, а их не было: {0}" -f $r.UnusedAnswers)
            Check (@($r.Output | Where-Object { $_ -match '^Остановлено: |ParserError' }).Count -eq 0) 'скрипт упал'
            # Пункты меню - в вопросах «@@ui:»: после подготовки второе меню предлагает обновить подготовленным.
            $menus = @(foreach ($line in @($r.Output | Where-Object { $_.StartsWith('@@ui:') })) {
                    $uiEvent = $null
                    try { $uiEvent = $line.Substring(5) | ConvertFrom-Json } catch { $uiEvent = $null }
                    if ($null -ne $uiEvent -and [string]$uiEvent.kind -eq 'one' -and ([string]$uiEvent.header).StartsWith('Гейт расширений')) { , @($uiEvent.items | ForEach-Object { [string]$_ }) }
                })
            Check ($menus.Count -eq 3) ("меню гейта показано {0} раз, ждали 3" -f $menus.Count)
            $menuHints = @(foreach ($line in @($r.Output | Where-Object { $_.StartsWith('@@ui:') })) {
                    $uiEvent = $null
                    try { $uiEvent = $line.Substring(5) | ConvertFrom-Json } catch { $uiEvent = $null }
                    if ($null -ne $uiEvent -and [string]$uiEvent.kind -eq 'one' -and ([string]$uiEvent.header).StartsWith('Гейт расширений')) {
                        if (@($uiEvent.PSObject.Properties | ForEach-Object { $_.Name }) -contains 'hints') { , @($uiEvent.hints | ForEach-Object { [string]$_ }) } else { , @() }
                    }
                })
            Check ($menuHints.Count -eq 3) ("пояснений к меню {0}, ждали 3" -f $menuHints.Count)
            # Перед каждым выбранным действием меню просит ci.exe убрать шаги и вердикт прошлого (событие reset);
            # «Выход» - без него. Здесь действий два: подготовка и её отмена.
            $resets = @($r.Output | Where-Object { $_.StartsWith('@@ui:') -and $_ -match '"kind"\s*:\s*"reset"' })
            Check ($resets.Count -eq 2) ("событий reset для ci.exe {0}, ждали 2 (по одному на выбранное действие меню)" -f $resets.Count)
            if ($menus.Count -eq 3) {
                Check (@($menus[0] | Where-Object { $_.StartsWith('Обновить рабочую подготовленным') }).Count -eq 0) 'до подготовки меню предлагает обновить подготовленным'
                Check (@($menus[1] | Where-Object { $_ -eq 'Обновить рабочую подготовленным' }).Count -eq 1) 'после подготовки в меню нет «Обновить рабочую подготовленным»'
                # Подписи пунктов не меняются: что подготовлено и что подготовка будет заново - в пояснениях (hints).
                Check (@($menus[1] | Where-Object { $_ -eq 'Подготовить обновление рабочей' }).Count -eq 1) 'после подготовки в меню нет «Подготовить обновление рабочей»'
                Check (@($menuHints[1] | Where-Object { $_.StartsWith('Адаптация') -and $_.Contains('подготовлено') }).Count -eq 1) ('после подготовки в пояснениях нет состава и времени подготовки: ' + (@($menuHints[1] | Where-Object { $_ }) -join ' | '))
                Check (@($menuHints[1] | Where-Object { $_.StartsWith('заново') }).Count -eq 1) 'после подготовки у «Подготовить обновление рабочей» нет пояснения «заново»'
                Check (@($menuHints[0] | Where-Object { $_.StartsWith('заново') }).Count -eq 0) 'до подготовки у «Подготовить обновление рабочей» пояснение «заново»'
                Check (@($menus[2] | Where-Object { $_.StartsWith('Обновить рабочую подготовленным') }).Count -eq 0) 'после отмены подготовки меню предлагает обновить подготовленным'
            }
            Check ((Get-Calls $r @('/UpdateDBCfg')).Count -eq 0) 'подготовка и отмена из меню обновили конфигурацию БД'
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'deploy\prepared.json'))) 'после отмены из меню prepared.json остался'
        }
    },
    @{
        Name = 'deploy-compare-extensions'
        Text = '«Сравнить расширения»: одинаковые - по COM без выгрузки, отличающиеся - выгрузка обеих баз и разница по процедурам; в базах ничего не меняется'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $oldModule = "Процедура Старая() Экспорт`r`nКонецПроцедуры"
            $newModule = $oldModule + "`r`n`r`nПроцедура НоваяПроцедура() Экспорт`r`nКонецПроцедуры"
            $fake = @{ dumps = @{
                    'Адаптация@erp_temp_test' = @{ 'CommonModules/Тест/Ext/Module.bsl' = $newModule }
                    'Адаптация@erp_base' = @{ 'CommonModules/Тест/Ext/Module.bsl' = $oldModule } } }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-CompareExtensions' -Fake $fake -Com (New-ComState)
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            $text = $r.Output -join "`n"
            Check ($text -match 'Доработки: одинаковые') 'одинаковые Доработки не показаны одинаковыми'
            Check ($text -match '\+ НоваяПроцедура') 'нет новой процедуры в разнице Адаптация'
            Check ((Get-Calls $r @('/DumpConfigToFiles', '-Extension Доработки')).Count -eq 0) 'одинаковые Доработки выгружались'
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0 -and (Get-Calls $r @('/UpdateDBCfg')).Count -eq 0) 'сравнение что-то загружало'
            Check (Test-Path -LiteralPath (Join-Path $sb 'deploy\compare-ext\compare.html')) 'нет compare.html'
        }
    },
    @{
        Name = 'deploy-compare-processings'
        Text = '«Сравнить внешние обработки»: отличающаяся обработка - версии и разница по модулю; в базах ничего не меняется'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState -TempProcessings @((New-PrintProcessing '2' $printNew)) -ProdProcessings @((New-PrintProcessing '1' $printOld))
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-CompareProcessings' -Com $com
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            $text = $r.Output -join "`n"
            Check ($text -match 'Печать \(Печать актов\): отличается, temp 2, рабочая 1') 'нет строки об отличающейся обработке'
            Check ($text -match '\+ НоваяПроцедура') 'нет новой процедуры в разнице обработки'
            Check ((Get-Calls $r @('ENTERPRISE', 'regepf')).Count -eq 0) 'сравнение записывало обработку'
        }
    },
    @{
        Name = 'menu-result-wait'
        Text = 'меню гейта: после «Показать состояние баз» меню не открывается само - сначала кнопка «Вернуться в меню»'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $r = Invoke-Script -Sandbox $sb -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Показать состояние баз' },
                @{ Kind = 'one'; Header = 'Посмотрел'; Item = '^Вернуться в меню' },
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check ($r.UnusedAnswers -eq 0) ("тест ждал вопросов, а их не было: {0}" -f $r.UnusedAnswers)
            $order = @($r.Output | Where-Object { $_.StartsWith('@@ui:') -and ($_.Contains('Гейт расширений') -or $_.Contains('Посмотрел')) } | ForEach-Object { if ($_.Contains('Посмотрел')) { 'ждать' } else { 'меню' } })
            Check (($order -join ',') -eq 'меню,ждать,меню') ("порядок: {0}, ждали меню,ждать,меню" -f ($order -join ','))
            $stateLine = [array]::IndexOf(@($r.Output), @($r.Output | Where-Object { $_ -match 'СОСТОЯНИЕ БАЗ' } | Select-Object -First 1)[0])
            $waitLine = [array]::IndexOf(@($r.Output), @($r.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('Посмотрел') } | Select-Object -First 1)[0])
            Check ($stateLine -ge 0 -and $waitLine -gt $stateLine) 'кнопка «Вернуться в меню» не после вывода состояния'
        }
    },
    @{
        Name = 'menu-groups'
        Text = 'меню гейта: пункты по группам (заголовок - у первого пункта группы), у пункта своя клавиша, и она не меняется, когда появляется условный пункт («Прогон с обновлением из inbox»); подписи постоянные, переменное - в пояснениях (hints)'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            # Вопрос меню из вывода скрипта: пункты, заголовки групп и клавиши.
            $getMenu = {
                param($Result)
                foreach ($line in @($Result.Output | Where-Object { $_.StartsWith('@@ui:') })) {
                    $uiEvent = $null
                    try { $uiEvent = $line.Substring(5) | ConvertFrom-Json } catch { $uiEvent = $null }
                    if ($null -ne $uiEvent -and [string]$uiEvent.kind -eq 'one' -and ([string]$uiEvent.header).StartsWith('Гейт расширений')) { return $uiEvent }
                }
                return $null
            }
            $keyOf = {
                param($Menu, [string]$Pattern)
                $labels = @($Menu.items | ForEach-Object { [string]$_ })
                $keys = @($Menu.keys | ForEach-Object { [string]$_ })
                for ($i = 0; $i -lt $labels.Count; $i++) { if ($labels[$i] -match $Pattern) { return $keys[$i] } }
                return ''
            }
            $r = Invoke-Script -Sandbox $sb -Answers @(@{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check ($r.UnusedAnswers -eq 0) ("тест ждал вопросов, а их не было: {0}" -f $r.UnusedAnswers)
            Check (@($r.Output | Where-Object { $_ -match '^Остановлено: |ParserError' }).Count -eq 0) ('скрипт упал: ' + ((@($r.Output | Where-Object { $_ -match '^Остановлено: ' }) | Select-Object -First 1) -join ''))
            $menu = & $getMenu $r
            Check ($null -ne $menu) 'вопроса меню гейта нет'
            if ($null -ne $menu) {
                $labels = @($menu.items | ForEach-Object { [string]$_ })
                $names = @($menu.PSObject.Properties | ForEach-Object { $_.Name })
                Check (($names -contains 'sections') -and ($names -contains 'keys')) 'в вопросе меню нет заголовков групп или клавиш'
                if (($names -contains 'sections') -and ($names -contains 'keys')) {
                    $sections = @($menu.sections | ForEach-Object { [string]$_ })
                    $keys = @($menu.keys | ForEach-Object { [string]$_ })
                    Check ($sections.Count -eq $labels.Count -and $keys.Count -eq $labels.Count) ("пунктов {0}, заголовков {1}, клавиш {2} - должно быть поровну" -f $labels.Count, $sections.Count, $keys.Count)
                    Check ((@($sections | Where-Object { $_ }) -join ' | ') -eq 'Тестовая база | Рабочая база | Сравнить и забрать | Гейт') ("группы: {0}" -f (@($sections | Where-Object { $_ }) -join ' | '))
                    Check ($sections.Count -gt 0 -and [bool]$sections[0]) 'у первого пункта меню нет заголовка группы'
                    Check (@($keys | Sort-Object -Unique).Count -eq $keys.Count) ("клавиши повторяются: {0}" -f ($keys -join ''))
                    Check (@($keys | Where-Object { $_ -notmatch '^[1-9a-z]$' }).Count -eq 0) ("клавиши не из 1-9, a-z: {0}" -f ($keys -join ' '))
                    Check ($labels[$labels.Count - 1] -eq 'Выход') ("последний пункт - «{0}», ждали «Выход»" -f $labels[$labels.Count - 1])
                    Check ((& $keyOf $menu '^Прогон на том, что есть в базе$') -eq '2') ("«Прогон на том, что есть в базе»: клавиша «{0}», ждали «2»" -f (& $keyOf $menu '^Прогон на том, что есть в базе$'))
                    Check ((& $keyOf $menu '^Обновить рабочую базу$') -eq 'd') ("«Обновить рабочую базу»: клавиша «{0}», ждали «d»" -f (& $keyOf $menu '^Обновить рабочую базу$'))
                    Check ((& $keyOf $menu '^Откатить рабочую базу$') -eq 'e') ("«Откатить рабочую базу»: клавиша «{0}», ждали «e»" -f (& $keyOf $menu '^Откатить рабочую базу$'))
                    Check ((& $keyOf $menu '^Настройки гейта$') -eq 'l') ("«Настройки гейта»: клавиша «{0}», ждали «l»" -f (& $keyOf $menu '^Настройки гейта$'))
                    Check ((& $keyOf $menu '^Прогон с обновлением из inbox') -eq '') 'в пустом inbox есть пункт «Прогон с обновлением из inbox»'
                    # Подписи постоянные: без чисел, имён баз и версий; переменное и подробности - в пояснениях.
                    Check (@($labels | Where-Object { $_ -match '\d|\(|:' -and $_ -ne 'Проверка внешнего соединения (COM)' }).Count -eq 0) ("в подписях пунктов есть переменное или пояснение: {0}" -f (@($labels | Where-Object { $_ -match '\d|\(|:' -and $_ -ne 'Проверка внешнего соединения (COM)' }) -join ' | '))
                    Check ($names -contains 'hints') 'в вопросе меню нет пояснений (hints)'
                    if ($names -contains 'hints') {
                        $hints = @($menu.hints | ForEach-Object { [string]$_ })
                        Check ($hints.Count -eq $labels.Count) ("пунктов {0}, пояснений {1} - должно быть поровну" -f $labels.Count, $hints.Count)
                        if ($hints.Count -eq $labels.Count) {
                            Check ($hints[[array]::IndexOf($labels, 'Показать состояние баз')] -eq 'блокировки и сеансы') 'у «Показать состояние баз» не то пояснение'
                            Check ($hints[[array]::IndexOf($labels, 'Выход')] -eq '') 'у «Выход» есть пояснение'
                        }
                    }
                    # Группа «Рабочая база» идёт раньше «Сравнить и забрать»: проверка перед обновлением - выше сравнения.
                    $precheckAt = [array]::IndexOf($labels, @($labels | Where-Object { $_ -match '^Проверка рабочей перед обновлением' } | Select-Object -First 1)[0])
                    $compareAt = [array]::IndexOf($labels, @($labels | Where-Object { $_ -match '^Сравнить расширения' } | Select-Object -First 1)[0])
                    Check ($precheckAt -ge 0 -and $compareAt -gt $precheckAt) ("порядок: проверка рабочей {0}, сравнение {1}" -f $precheckAt, $compareAt)
                    if ($precheckAt -ge 0 -and $compareAt -ge 0) {
                        Check ($sections[$precheckAt] -eq 'Рабочая база') 'группа «Рабочая база» начинается не с проверки перед обновлением'
                        Check ($sections[$compareAt] -eq 'Сравнить и забрать') 'группа «Сравнить и забрать» начинается не со сравнения расширений'
                    }
                }
            }
            # В inbox появилось обновление: новый пункт - первым, со своей клавишей «1», остальные клавиши те же.
            $null = Add-InboxFile $sb $cfeName
            $k = Invoke-Script -Sandbox $sb -Answers @(@{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            Check ($k.Unexpected.Count -eq 0) ("с обновлением в inbox: неожиданные вопросы: " + ($k.Unexpected -join ' | '))
            $menuKit = & $getMenu $k
            Check ($null -ne $menuKit) 'с обновлением в inbox: вопроса меню гейта нет'
            $kitNames = @()
            if ($null -ne $menuKit) { $kitNames = @($menuKit.PSObject.Properties | ForEach-Object { $_.Name }) }
            Check (($kitNames -contains 'keys') -and ($kitNames -contains 'hints')) 'с обновлением в inbox: в вопросе меню нет клавиш или пояснений'
            if (($kitNames -contains 'keys') -and ($kitNames -contains 'hints')) {
                Check ((& $keyOf $menuKit '^Прогон с обновлением из inbox') -eq '1') ("«Прогон с обновлением из inbox»: клавиша «{0}», ждали «1»" -f (& $keyOf $menuKit '^Прогон с обновлением из inbox'))
                Check ([string]@($menuKit.items)[0] -eq 'Прогон с обновлением из inbox') ("первый пункт - «{0}»" -f [string]@($menuKit.items)[0])
                Check ([string]@($menuKit.hints)[0] -eq 'обновлений в inbox: 1') ("пояснение первого пункта - «{0}», ждали «обновлений в inbox: 1»" -f [string]@($menuKit.hints)[0])
                Check ([string]@($menuKit.sections)[0] -eq 'Тестовая база') 'заголовок группы не у первого показанного пункта'
                Check ((& $keyOf $menuKit '^Прогон на том, что есть в базе$') -eq '2') 'клавиша «Прогон на том, что есть в базе» сдвинулась, когда появился пункт inbox'
                Check ((& $keyOf $menuKit '^Обновить рабочую базу$') -eq 'd') 'клавиша «Обновить рабочую базу» сдвинулась, когда появился пункт inbox'
            }
        }
    },
    @{
        Name = 'deploy-designer-busy-retry'
        Text = 'deploy: конфигуратор рабочей занят на выгрузке - вопрос, «закрыть отсюда» завершает только конфигуратор рабочей, выгрузка повторяется'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $busy = 'Ошибка блокировки информационной базы для конфигурирования. С этой информационной базой уже работает конфигуратор: компьютер: pc9, сеанс: 9'
            $fake = @{ designer = @(@{ match = @('/DumpConfigToFiles', 'erp_base'); exit = 1; log = $busy; times = 1 }) }
            $com = New-ComState -Sessions @(@{ id = 9; base = 'erp_base'; app = 'Designer'; user = 'Разработчик'; host = 'pc9' }, @{ id = 10; base = 'erp_temp_test'; app = 'Designer'; user = 'Тест'; host = 'pc2' })
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-CompareExtensions' -Fake $fake -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Открыт конфигуратор erp_base'; Item = '^Закрыть отсюда' })
            Check-DeployCommon $r -LocksExpected $false
            Check (@($r.ComLog | Where-Object { $_ -match 'TerminateSession 9$' }).Count -eq 1) 'конфигуратор рабочей не закрыт'
            Check (@($r.ComLog | Where-Object { $_ -match 'TerminateSession 10$' }).Count -eq 0) 'закрыт конфигуратор temp, хотя занята рабочая'
            Check ((Get-Calls $r @('/DumpConfigToFiles', 'erp_base', '-Extension Адаптация')).Count -eq 2) 'выгрузка рабочей не повторилась'
            Check (@($r.Output | Where-Object { $_ -match 'НЕ СРАВНИЛИСЬ' }).Count -eq 0) 'после закрытия конфигуратора сравнение всё равно не прошло'
        }
    },
    @{
        Name = 'deploy-epf-only'
        Text = 'только внешние обработки: новая обработка записана, блокировок нет, чужая блокировка регламентных заданий не снята'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState -TempHash 'h1' -TempProcessings @((New-PrintProcessing '1' $printNew)) -ProdJobsDenied $true
            $fake = @{ regepf = @(@{ status = 'done'; isnew = '1'; ref = '11111111-0000-0000-0000-000000000009'; objversion = '1' }) }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Fake $fake -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = 'только внешние обработки' },
                @{ Kind = 'many'; Header = 'внешние обработки'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check (@($r.ComLog | Where-Object { $_ -match 'UpdateInfoBase|TerminateSession' }).Count -eq 0) 'при «только обработки» трогали свойства или сеансы рабочей'
            if ($null -ne $r.ComState) { Check ([bool]$r.ComState.bases.erp_base.scheduledJobsDenied) 'снята чужая блокировка регламентных заданий' }
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0) 'при «только обработки» грузились расширения'
            Check ((Get-Calls $r @('/UpdateDBCfg')).Count -eq 0) 'при «только обработки» обновлялась конфигурация БД'
            $record = Get-DeployRecord $sb
            if ($null -ne $record) {
                Check ($record.mode -eq 'epf') ("режим {0}, ждали epf" -f $record.mode)
                $proc = @($record.processings)
                Check ($proc.Count -eq 1 -and $proc[0].isNew -eq 'yes' -and $proc[0].ref) 'в deploy.json нет новой обработки со ссылкой'
            }
            else { Check $false 'нет deploy.json' }
        }
    },
    @{
        Name = 'deploy-rollback-last'
        Text = 'откат последних изменений: резервная копия расширения и прежняя версия обработки обратно, в temp не тянем'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState -TempProcessings @((New-PrintProcessing '2' $printNew)) -ProdProcessings @((New-PrintProcessing '1' $printOld))
            $fake = @{ regepf = @(@{ status = 'done'; old = 'прежняя печать'; objversion = '2'; oldversion = '1' }) }
            $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Fake $fake -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить все' },
                @{ Kind = 'many'; Header = 'внешние обработки'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer)
            Check ($first.ExitCode -eq 0) ("первое обновление: код {0}" -f $first.ExitCode)
            $firstRecord = Get-DeployRecord $sb
            if ($null -eq $firstRecord) { Check $false 'первое обновление не записало deploy.json'; return }
            Start-Sleep -Seconds 2
            Remove-Item -LiteralPath (Join-Path $sb 'fake\calls.log') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $sb 'fake\fake1c-state.json') -Force -ErrorAction SilentlyContinue
            $fake = @{ regepf = @(@{ status = 'done'; old = 'новая печать'; objversion = '1'; oldversion = '2' }) }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Rollback' -Fake $fake -Answers @(
                @{ Kind = 'one'; Header = 'Откат erp_base'; Index = 0 },
                @{ Kind = 'confirm'; Header = 'Точно откатить'; Yes = $true },
                $deployNameAnswer,
                @{ Kind = 'confirm'; Header = 'подтянуть изменения в темп'; Yes = $false })
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            $record = Get-DeployRecord $sb
            if ($null -ne $record) {
                Check ($record.mode -eq 'rollback' -and $record.rollbackOf -eq $firstRecord.runId) ("режим {0}, откат к {1}, ждали rollback к {2}" -f $record.mode, $record.rollbackOf, $firstRecord.runId)
                Check (@($record.processings).Count -eq 1) 'откат не вернул обработку'
            }
            else { Check $false 'нет deploy.json отката' }
            $loads = (Get-Calls $r @('/LoadCfg', '-Extension Адаптация', 'fake\erp_base'))
            Check ($loads.Count -eq 1 -and $loads[0].Line.Contains($firstRecord.runId + '\before\erp_base_Адаптация_')) 'откат грузил не резервную копию первого обновления'
            $reg = (Get-Calls $r @('ENTERPRISE', 'regepf', 'name=Печать.epf'))
            Check ($reg.Count -eq 1) 'прежняя версия обработки не записана обратно'
            if ($reg.Count -eq 1) {
                # regepf откату передаёт копию base64 из резервной копии первого обновления.
                $newB64 = [regex]::Match($reg[0].Line, 'file=([^;"]+)').Groups[1].Value
                $backupB64 = Join-Path $firstRecord.Dir (@($firstRecord.processings)[0].backup)
                if ($newB64 -and (Test-Path -LiteralPath $newB64) -and (Test-Path -LiteralPath $backupB64)) {
                    Check ([System.IO.File]::ReadAllText($newB64) -eq [System.IO.File]::ReadAllText($backupB64)) 'в справочник записана не прежняя версия'
                }
                else { Check $false ("нет файла записи {0} или резервной копии {1}" -f $newB64, $backupB64) }
            }
        }
    },
    @{
        Name = 'deploy-no-prodbase'
        Text = 'рабочая база не задана: скрипт спрашивает имя и пишет его в config.psd1 (-StatusOnly)'
        Run = {
            param($Name)
            $config = @{}
            foreach ($key in $deployConfig.Keys) { $config[$key] = $deployConfig[$key] }
            $config['ProdBase'] = ''
            $sb = New-Sandbox $Name -Config $config
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-StatusOnly' -Com (New-ComState) -Answers @(
                @{ Kind = 'text'; Header = 'Имя рабочей базы'; Text = 'erp_base' })
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            $text = [System.IO.File]::ReadAllText((Join-Path $sb 'config.psd1'), $utf8)
            Check ($text -match "ProdBase\s*=\s*'erp_base'") 'ProdBase не записан в config.psd1'
            Check (@($r.Output | Where-Object { $_ -match 'РАСШИРЕНИЯ: erp_temp_test ПРОТИВ erp_base' }).Count -eq 1) 'после записи ProdBase сравнения не было'
        }
    },
    @{
        Name = 'deploy-prod-locked-other-code'
        Text = 'в рабочей блокировка начала сеансов с другим кодом: deploy сразу останавливается с понятной причиной, обработки не выгружает'
        Run = {
            param($Name)
            $marker = 'ci-synthetic-unlock-marker'
            $settings = $deployConfig.Clone()
            $settings['UnlockCode'] = $marker
            $sb = New-Sandbox $Name -Config $settings
            $com = New-ComState
            $com['lockedConnect'] = @('erp_base')
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-StatusOnly' -Com $com
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -ne 0) 'deploy не остановился, хотя рабочая закрыта'
            Check (@($r.Output | Where-Object { $_ -match 'блокировка начала сеансов, и код разрешения у неё не тот' }).Count -gt 0) 'нет понятной причины остановки'
            Check (-not (($r.Output -join "`n").Contains($marker))) 'код разрешения попал в консоль'
            $logs = @(Get-ChildItem -LiteralPath (Join-Path $sb 'deploy') -Recurse -File -Filter run.log)
            Check ($logs.Count -gt 0) 'журнал deploy не найден'
            foreach ($log in $logs) {
                $text = [System.IO.File]::ReadAllText($log.FullName, $utf8)
                Check (-not $text.Contains($marker)) 'код разрешения попал в журнал deploy'
            }
            Check (@($r.Output | Where-Object { $_ -match 'ВНЕШНИЕ ОБРАБОТКИ' }).Count -eq 0) 'после закрытой рабочей deploy пошёл выгружать обработки'
        }
    },
    @{
        Name = 'deploy-unlockcode-hidden'
        Text = 'значение UnlockCode не попадает ни в вывод, ни в журналы: рабочая закрыта чужой блокировкой - сообщение называет настройку, а не её значение; обычный просмотр состояния - код в ключе /UC закрыт звёздочками'
        Run = {
            param($Name)
            $secretCode = 'Kod-Razblokirovki-9731'
            $config = @{} + $deployConfig
            $config['UnlockCode'] = $secretCode
            $sb = New-Sandbox $Name -Config $config
            # Всё, что скрипт записал в свою папку: настройки и файлы подставных 1С и COM - не в счёт.
            $findLeaks = {
                param([string]$Dir)
                $found = @(Get-ChildItem -LiteralPath $Dir -Recurse -File | Where-Object { $_.Name -ne 'config.psd1' -and $_.FullName -notmatch '\\(fake|chan|bin|test)\\' -and $_.Length -lt 5MB } | Where-Object { [System.IO.File]::ReadAllText($_.FullName, $utf8).Contains($secretCode) } | ForEach-Object { $_.FullName.Substring($Dir.Length) })
                return , $found
            }
            $com = New-ComState
            $com['lockedConnect'] = @('erp_base')
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-StatusOnly' -Com $com
            Check-DeployCommon $r -LocksExpected $false
            Check (@($r.Output | Where-Object { $_ -match 'код разрешения у неё не тот, что в UnlockCode' }).Count -gt 0) 'нет сообщения о чужой блокировке с именем настройки'
            $shown = @($r.Output | Where-Object { $_.Contains($secretCode) })
            Check ($shown.Count -eq 0) ('значение UnlockCode в выводе: ' + (($shown | Select-Object -First 2) -join ' | ').Replace($secretCode, '<код>'))
            $leaks = & $findLeaks $sb
            Check ($leaks.Count -eq 0) ('значение UnlockCode в файлах: ' + ($leaks -join ', '))
            # Рабочая открыта: «Показать состояние баз» идёт до конца, кода по-прежнему нигде нет.
            $s = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-BaseState' -Com (New-ComState)
            Check-DeployCommon $s -LocksExpected $false
            $shown = @($s.Output | Where-Object { $_.Contains($secretCode) })
            Check ($shown.Count -eq 0) ('состояние баз: значение UnlockCode в выводе: ' + (($shown | Select-Object -First 2) -join ' | ').Replace($secretCode, '<код>'))
            $leaks = & $findLeaks $sb
            Check ($leaks.Count -eq 0) ('состояние баз: значение UnlockCode в файлах: ' + ($leaks -join ', '))
        }
    },
    @{
        Name = 'settings-value-password'
        Text = 'настройки: значение сохраняется, пароль - файлом DPAPI, не целое число не сохраняется, умолчания дописаны'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $r = Invoke-Script -Sandbox $sb -Script 'settings.ps1' -Answers @(
                @{ Kind = 'one'; Header = '^Настройки: '; Item = '^Базы$' },
                @{ Kind = 'one'; Header = '^Настройки, Базы: '; Item = '^UnlockCode ' },
                @{ Kind = 'text'; Header = '^UnlockCode: '; Text = '777' },
                @{ Kind = 'one'; Header = '^Настройки, Базы: '; Item = '^Назад$' },
                @{ Kind = 'one'; Header = '^Настройки: '; Item = '^Пользователи и пароли$' },
                @{ Kind = 'one'; Header = '^Настройки, Пользователи и пароли: '; Item = '^AdminPassFile ' },
                @{ Kind = 'one'; Header = '^AdminPassFile: '; Item = '^Ввести пароль$' },
                @{ Kind = 'text'; Header = '^Пароль для AdminPassFile'; Text = 'тест-пароль' },
                @{ Kind = 'text'; Header = '^Ещё раз'; Text = 'тест-пароль' },
                @{ Kind = 'one'; Header = '^Настройки, Пользователи и пароли: '; Item = '^Назад$' },
                @{ Kind = 'one'; Header = '^Настройки: '; Item = '^Подготовка базы$' },
                @{ Kind = 'one'; Header = '^Настройки, Подготовка базы: '; Item = '^SessionLockHours ' },
                @{ Kind = 'text'; Header = '^SessionLockHours: '; Text = 'два' },
                @{ Kind = 'one'; Header = '^Настройки, Подготовка базы: '; Item = '^Назад$' },
                @{ Kind = 'one'; Header = '^Настройки: '; Item = '^Готово$' })
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            $config = Import-PowerShellDataFile -LiteralPath (Join-Path $sb 'config.psd1')
            Check ([string]$config['UnlockCode'] -eq '777') ("UnlockCode = {0}, ждали 777" -f $config['UnlockCode'])
            Check ([int]$config['SessionLockHours'] -eq 2) ("SessionLockHours = {0}: «два» не должно было сохраниться" -f $config['SessionLockHours'])
            Check ($config.ContainsKey('ReleaseJobsLock')) 'умолчания не дописаны в config.psd1'
            Check (Test-Path -LiteralPath (Join-Path $sb 'config.psd1.bak')) 'нет копии config.psd1.bak'
            $passFile = [string]$config['AdminPassFile']
            Check ($passFile -eq 'secrets\admin.txt') ("AdminPassFile = {0}" -f $passFile)
            $passPath = Join-Path $sb $passFile
            if (Test-Path -LiteralPath $passPath) {
                $stored = ([System.IO.File]::ReadAllText($passPath)).Trim()
                Check (-not $stored.Contains('тест-пароль')) 'пароль лежит в файле открытым текстом'
                $secure = ConvertTo-SecureString -String $stored
                $plain = (New-Object System.Management.Automation.PSCredential('user', $secure)).GetNetworkCredential().Password
                Check ($plain -eq 'тест-пароль') 'из файла DPAPI читается не тот пароль'
            }
            else { Check $false ("нет файла пароля {0}" -f $passPath) }
            Check (-not ([System.IO.File]::ReadAllText((Join-Path $sb 'config.psd1'), $utf8).Contains('тест-пароль'))) 'пароль попал в config.psd1'
        }
    },
    @{
        Name = 'unit-catalog'
        Text = 'модульные тесты без 1С: каталог и замечания к шапкам, jUnit, сравнение с эталоном, заготовки, выключение, хеш папки'
        Run = {
            param($Name)
            . (Join-Path $ciRoot 'unittests.ps1')
            $dir = Join-Path $workRoot $Name
            $bad = $unitModuleClean.Replace('// @Зачем чтобы было' + "`r`n", '').Replace('"Вычитание");', '"Вычитать");') + "`r`n`r`n// @Тест Без регистрации`r`nПроцедура БезРегистрации() Экспорт`r`nКонецПроцедуры`r`n"
            $root = Add-UnitTestSource -Dir $dir -Module $bad
            $catalog = Get-UtCatalog -Dir $root
            Check ($catalog.Extension -eq 'Тесты') ("имя расширения {0}" -f $catalog.Extension)
            Check (@($catalog.Tests).Count -eq 3) ("тестов {0}, ждали 3" -f @($catalog.Tests).Count)
            $plus = @($catalog.Tests | Where-Object { $_.Method -eq 'Сложение' })[0]
            Check ($plus.Subsystem -eq 'Тесты_Общие' -and $plus.SubsystemName -eq 'Общие') ("подсистема {0} / {1}" -f $plus.Subsystem, $plus.SubsystemName)
            Check ($plus.How -eq "складываем 2 и 2,`nсравниваем с 4") ("@Как с продолжением: «{0}»" -f $plus.How)
            Check (@($plus.Tags) -contains 'быстрый' -and @($plus.Problems).Count -eq 0) ("Сложение: теги {0}, замечания {1}" -f (@($plus.Tags) -join ','), (@($plus.Problems) -join ' | '))
            $kinds = @($catalog.Problems | ForEach-Object { '{0}:{1}' -f $_.Method, $_.Kind })
            foreach ($expected in @('Вычитание:field', 'Вычитание:presentation', 'БезРегистрации:notregistered', 'БезРегистрации:field')) {
                Check ($kinds -contains $expected) ("нет замечания {0}: {1}" -f $expected, ($kinds -join ', '))
            }
            Check ($kinds -notcontains 'Сложение:field') 'замечание к полной шапке'
            # Хеш: те же тексты с LF вместо CRLF и без BOM - тот же хеш; другой текст - другой.
            $hash = Get-UtDirHash $root
            $copy = Join-Path $dir 'копия'
            Copy-Item -LiteralPath $root -Destination $copy -Recurse
            $moduleCopy = Join-Path $copy 'CommonModules\ОМ_Пример\Ext\Module.bsl'
            [System.IO.File]::WriteAllText($moduleCopy, ([System.IO.File]::ReadAllText($moduleCopy, $utf8).TrimStart([char]0xFEFF).Replace("`r`n", "`n")), $utf8)
            Check ((Get-UtDirHash $copy) -eq $hash) 'хеш зависит от BOM и переводов строк'
            [System.IO.File]::AppendAllText($moduleCopy, "`n// правка", $utf8)
            Check ((Get-UtDirHash $copy) -ne $hash) 'хеш не заметил правку'
            # Заготовки: новый модуль и новый тест - без замечаний; выключить и включить.
            $null = New-UtModule -Dir $root -Name 'ОМ_Новый' -Subsystem 'Тесты_Общие' -Method 'Первый' -Presentation 'Первый тест' -Checks 'CommonModule.Новый.Метод' -How 'вызываем' -Why 'надо' -Author 'Тестов А.Б. 20261118'
            $null = Add-UtTest -Dir $root -Module 'ОМ_Новый' -Method 'Второй' -Presentation 'Второй тест' -Checks 'CommonModule.Новый.Другой' -How 'так' -Why 'потому' -Author 'Тестов А.Б. 20261118' -Tags 'медленный'
            $after = Get-UtCatalog -Dir $root
            $newTests = @($after.Tests | Where-Object { $_.Module -eq 'ОМ_Новый' })
            Check ($newTests.Count -eq 2) ("в новом модуле тестов {0}, ждали 2" -f $newTests.Count)
            Check (@($after.Problems | Where-Object { $_.Module -eq 'ОМ_Новый' }).Count -eq 0) ("замечания к заготовкам: " + (@($after.Problems | Where-Object { $_.Module -eq 'ОМ_Новый' } | ForEach-Object { Format-UtProblem $_ }) -join ' | '))
            Check (@($newTests | Where-Object { $_.Subsystem -eq 'Тесты_Общие' }).Count -eq 2) 'новый модуль не попал в подсистему'
            $null = Set-UtDisabled -Dir $root -Module 'ОМ_Новый' -Method 'Первый' -Reason 'ломается на пустой базе'
            $off = @((Get-UtCatalog -Dir $root).Tests | Where-Object { $_.Key -eq 'ОМ_Новый.Первый' })[0]
            Check ($off.Disabled -eq 'ломается на пустой базе') ("выключение: «{0}»" -f $off.Disabled)
            $null = Set-UtDisabled -Dir $root -Module 'ОМ_Новый' -Method 'Первый' -Reason ''
            $on = @((Get-UtCatalog -Dir $root).Tests | Where-Object { $_.Key -eq 'ОМ_Новый.Первый' })[0]
            Check (-not $on.Disabled -and @($on.Problems).Count -eq 0) ("включение: «{0}», замечания {1}" -f $on.Disabled, (@($on.Problems) -join ' | '))
            # jUnit YAxUnit и сравнение с эталоном.
            $junit = Join-Path $dir 'junit.xml'
            [System.IO.File]::WriteAllText($junit, ('<?xml version="1.0" encoding="UTF-8"?><testsuites><testsuite classname="ОМ_Пример" context="Сервер" name="ОМ_Пример [Сервер]">' +
                    '<testcase name="Сложение двух чисел" classname="ОМ_Пример.Сложение" context="Сервер" time="0.5"/>' +
                    '<testcase name="Вычитание" classname="ОМ_Пример.Вычитание" context="Сервер" time="0.1"><failure message="ожидали 2, а было 3"/></testcase>' +
                    '<testcase name="Вычитание" classname="ОМ_Пример.Вычитание" context="Сервер" time="0.1"/>' +
                    '</testsuite><testsuite classname="ОМ_Сломан" context="Сервер" name="ОМ_Сломан [Сервер]"><error message="модуль не компилируется"/></testsuite></testsuites>'), $utf8)
            $results = Read-UtJUnit $junit
            $keys = @($results | ForEach-Object { '{0}={1}' -f $_.Key, $_.Status })
            foreach ($expected in @('ОМ_Пример.Сложение [Сервер]=OK', 'ОМ_Пример.Вычитание [Сервер]=FAIL', 'ОМ_Пример.Вычитание [Сервер] #2=OK', 'ОМ_Сломан [Сервер] набор=ERROR')) {
                Check ($keys -contains $expected) ("в разборе jUnit нет {0}: {1}" -f $expected, ($keys -join ', '))
            }
            $baselineFile = Join-Path $dir 'baseline.txt'
            [System.IO.File]::WriteAllLines($baselineFile, [string[]]@("OK`tОМ_Пример.Сложение [Сервер]`t", "FAIL`tОМ_Сломан [Сервер] набор`tстарое", "OK`tОМ_Пропал.Тест [Сервер]`t"), $utf8Bom)
            $comparison = Compare-UtResults -Current $results -BaselineFile $baselineFile
            $newKeys = (@($comparison.NewFailed | ForEach-Object { $_.Key }) -join ',')
            Check ($newKeys -eq 'ОМ_Пример.Вычитание [Сервер]') ("новые падения: " + $newKeys)
            Check (@($comparison.KnownFailed).Count -eq 1 -and @($comparison.Gone) -contains 'ОМ_Пропал.Тест [Сервер]') 'известное падение или пропавший тест не опознаны'
            # Причина падения известного теста: ERROR «модуль не компилируется» против эталонного FAIL «старое» - по-другому.
            Check (@($comparison.ReasonChanged).Count -eq 1) ("известных, что падают по-другому: {0}, ждали 1" -f @($comparison.ReasonChanged).Count)
            # Номер строки, GUID, длительность - не меняют причину; код ошибки меняет.
            Check ((ConvertTo-UtReasonKey 'FAIL' '{ОбщийМодуль.А.Модуль(12,3)}: строка 5: HTTP 403 за 2 с') -eq (ConvertTo-UtReasonKey 'FAIL' '{ОбщийМодуль.А.Модуль(80,1)}: строка 9: HTTP 403 за 15 с')) 'смена номера строки или длительности поменяла причину'
            Check ((ConvertTo-UtReasonKey 'FAIL' 'HTTP 403') -ne (ConvertTo-UtReasonKey 'FAIL' 'HTTP 503')) 'смена кода ошибки не поменяла причину'
            Check ((ConvertTo-UtReasonKey 'FAIL' '{ОбщийМодуль.ПроверкаДоступа.Модуль(12)}: Доступ запрещен') -ne (ConvertTo-UtReasonKey 'FAIL' '{ОбщийМодуль.ОбменДанными.Модуль(80)}: Доступ запрещен')) 'другой модуль с тем же текстом - одна причина'
            Check ((ConvertTo-UtReasonKey 'FAIL' 'нет таблицы') -ne (ConvertTo-UtReasonKey 'ERROR' 'нет таблицы')) 'FAIL и ERROR с одним текстом - одна причина'
            Check ((Get-UtStatusTitle 'ERROR') -eq 'ERROR - ошибка выполнения' -and (Get-UtStatusTitle 'FAIL') -eq 'FAIL - не прошло утверждение') 'подписи ERROR/FAIL не те'
            # Эталон без полного принятия: OK из прогона, у падений и пропавших - прежние записи, новое падение не заносится.
            $merged = @(Merge-UtBaseline -Current $results -BaselineFile $baselineFile)
            Check (@($merged | Where-Object { $_ -match '^OK\tОМ_Пример\.Сложение' }).Count -eq 1) 'прошедший тест не в эталоне'
            Check (@($merged | Where-Object { $_ -match '^FAIL\tОМ_Сломан \[Сервер\] набор\tстарое$' }).Count -eq 1) 'известное падение не сохранило прежнюю запись'
            Check (@($merged | Where-Object { $_ -match 'ОМ_Пропал\.Тест' }).Count -eq 1) 'пропавший тест выпал из эталона'
            Check (@($merged | Where-Object { $_ -match '^FAIL\tОМ_Пример\.Вычитание \[Сервер\]\t' }).Count -eq 0) 'новое падение попало в эталон'
        }
    },
    @{
        Name = 'gate-unittests-first-load'
        Text = 'модульные тесты: тестовое расширение из файлов грузится в temp (его там не было), YAxUnit прогоняет, эталон записан; второй прогон не грузит заново; замечания проверки конфигурации по модулям тестов не в счёт'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $unitConfig
            $null = Add-UnitTestSource -Dir (Join-Path $sb 'tests')
            $checkLog = '{ОбщийМодуль.ОМ_Пример.Модуль(5,2)}: Переменная не определена (ЮТТесты)'
            $fake = @{ absent = @('Тесты'); unittests = @($unitAllOk); designer = @(@{ match = @('/CheckConfig'); exit = 101; log = $checkLog }) }
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Тесты: загрузить Тесты' 'OK'
            Check-Step $r 'Модульные тесты' 'OK'
            Check-Step $r 'Проверка конфигурации' 'OK'
            Check ((Get-Calls $r @('/LoadConfigFromFiles', '-Extension Тесты')).Count -eq 1) 'тесты не загружены из файлов'
            Check ((Get-Calls $r @('/UpdateDBCfg', '-Extension Тесты')).Count -eq 1) 'конфигурация БД тестового расширения не обновлена'
            Check ((Get-Calls $r @('RunUnitTests=')).Count -eq 1) 'YAxUnit не запускался'
            Check (Test-Path -LiteralPath (Join-Path $sb 'baseline\erp_temp_test\unittests.txt')) 'эталон модульных тестов не записан'
            Check (Test-Path -LiteralPath (Join-Path $sb 'state\unittests\Тесты.state.txt')) 'нет состояния тестового расширения'
            if ($r.RunDir) {
                Check (Test-Path -LiteralPath (Join-Path $r.RunDir 'unittests-Тесты.catalog.txt')) 'нет каталога тестов в папке прогона'
                $json = [System.IO.File]::ReadAllText((Join-Path $r.RunDir 'unittests\yaxunit.json'), $utf8) | ConvertFrom-Json
                Check (@($json.filter.extensions) -contains 'Тесты' -and $json.closeAfterTests -eq $true -and $json.reportFormat -eq 'jUnit') 'настройки YAxUnit не те'
            }
            $second = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $second; Check-Verdict $second 'GREEN' 0
            Check ((Get-Calls $second @('/LoadConfigFromFiles', '-Extension Тесты')).Count -eq 1) 'файлы не менялись, а тесты загружены второй раз'
            Check ($null -eq (Get-Step $second 'Тесты: загрузить')) 'шаг загрузки тестов во втором прогоне'
        }
    },
    @{
        Name = 'gate-unittests-no-exitcode'
        Text = 'модульные тесты: YAxUnit записал отчёт jUnit, но не код возврата и висит - итог по отчёту, клиент снят, шаг не красный'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $unitConfig
            $null = Add-UnitTestSource -Dir (Join-Path $sb 'tests')
            $hung = $unitAllOk.Clone()
            $hung['noexitcode'] = $true
            $hung['hang'] = 300
            $fake = @{ absent = @('Тесты'); unittests = @($hung) }
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check-Step $r 'Модульные тесты' 'OK'
            $step = Get-Step $r 'Модульные тесты'
            if ($null -ne $step) { Check ([string]$step.detail -match 'кода возврата YAxUnit нет') ("в шаге нет пометки об итоге по отчёту: {0}" -f $step.detail) }
            Check ($r.Seconds -lt 250) ("гейт ждал зависший клиент: {0} с" -f $r.Seconds)
        }
    },
    @{
        Name = 'gate-unittests-incomplete-report'
        Text = 'пустой, потерянный или частичный jUnit и противоречивый код YAxUnit дают красный и сохраняют прежний эталон побайтно'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $unitConfig
            $null = Add-UnitTestSource -Dir (Join-Path $sb 'tests')
            $baseline = Join-Path $sb 'baseline\erp_temp_test\unittests.txt'
            New-Item -ItemType Directory -Path (Split-Path -Parent $baseline) -Force | Out-Null
            [System.IO.File]::WriteAllLines($baseline, [string[]]@("OK`tОМ_Пример.Сложение [Сервер]`tпрежний прогон", "OK`tОМ_Пример.Вычитание [Сервер]`t"), $utf8Bom)
            $hash = (Get-FileHash -LiteralPath $baseline).Hash
            $variants = [ordered]@{
                'пустой отчёт' = @{ cases = @() }
                'частичный отчёт' = @{ cases = @($unitAllOk.cases[0]) }
                'код 1 при успехе' = @{ cases = $unitAllOk.cases; code = '1' }
                'код 0 при падении' = @{ cases = $unitMinusFails.cases; code = '0' }
                'нет отчёта' = @{ cases = $unitAllOk.cases; noReport = $true }
            }
            foreach ($variant in $variants.Keys) {
                $fake = @{ absent = @('Тесты'); unittests = @($variants[$variant]) }
                $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
                Check-Common $r
                Check-Verdict $r 'RED' 1
                Check-Step $r 'Модульные тесты' 'FAIL'
                Check ((Get-FileHash -LiteralPath $baseline).Hash -eq $hash) ("{0}: эталон модульных тестов изменился" -f $variant)
                if ($r.RunDir) {
                    Check (-not (Test-Path -LiteralPath (Join-Path $r.RunDir 'unittests.txt'))) ("{0}: результат можно принять в эталон через меню" -f $variant)
                }
            }
        }
    },
    @{
        Name = 'gate-unittests-new-failure-accept'
        Text = 'модульные тесты: новое падение - красный, unittests.new.txt; принять в эталон - то же падение потом известное, зелёный'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $unitConfig
            $null = Add-UnitTestSource -Dir (Join-Path $sb 'tests')
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ absent = @('Тесты'); unittests = @($unitAllOk) }
            Check-Verdict $r 'GREEN' 0
            $red = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ unittests = @($unitMinusFails) }
            Check-Common $red; Check-Verdict $red 'RED' 1
            Check-Step $red 'Модульные тесты' 'FAIL'
            if ($red.RunDir) {
                $new = Join-Path $red.RunDir 'unittests.new.txt'
                Check ((Test-Path -LiteralPath $new) -and ([System.IO.File]::ReadAllText($new, $utf8) -match 'ОМ_Пример\.Вычитание \[Сервер\]')) 'новое падение не в unittests.new.txt'
            }
            $accept = Invoke-Script -Sandbox $sb -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Принять новое последнего прогона в эталон' },
                @{ Kind = 'confirm'; Header = 'Принять новое прогона'; Yes = $true },
                @{ Kind = 'confirm'; Header = 'падают модульные тесты'; Yes = $true },
                @{ Kind = 'one'; Header = 'Посмотрел'; Item = '^Вернуться в меню' },
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            Check-Common $accept
            Check (@($accept.Output | Where-Object { $_ -match 'Принято как известное: результаты модульных тестов' }).Count -eq 1) 'результаты модульных тестов не приняты в эталон'
            $known = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ unittests = @($unitMinusFails) }
            Check-Common $known; Check-Verdict $known 'GREEN' 0
            $step = Get-Step $known 'Модульные тесты'
            Check ($null -ne $step -and [string]$step.detail -match 'известных 1') ("после принятия: {0}" -f $(if ($null -ne $step) { $step.detail } else { 'шага нет' }))
        }
    },
    @{
        Name = 'gate-unittests-accept-keep-failures'
        Text = 'модульные тесты: принять в эталон «кроме падений» - падение остаётся новым (красный), accepted.txt scope=partial'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $unitConfig
            $null = Add-UnitTestSource -Dir (Join-Path $sb 'tests')
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ absent = @('Тесты'); unittests = @($unitAllOk) }
            Check-Verdict $r 'GREEN' 0
            $red = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ unittests = @($unitMinusFails) }
            Check-Verdict $red 'RED' 1
            $accept = Invoke-Script -Sandbox $sb -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Принять новое последнего прогона в эталон' },
                @{ Kind = 'confirm'; Header = 'Принять новое прогона'; Yes = $true },
                @{ Kind = 'confirm'; Header = 'падают модульные тесты'; Yes = $false },
                @{ Kind = 'one'; Header = 'Посмотрел'; Item = '^Вернуться в меню' },
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            Check-Common $accept
            Check (@($accept.Output | Where-Object { $_ -match 'падения \(1\) не приняты' }).Count -eq 1) 'нет строки о непринятых падениях'
            if ($red.RunDir) {
                $acceptedFile = Join-Path $red.RunDir 'accepted.txt'
                Check ((Test-Path -LiteralPath $acceptedFile) -and [System.IO.File]::ReadAllText($acceptedFile, $utf8).Contains('scope=partial')) 'accepted.txt без scope=partial'
                $runReport = Join-Path $red.RunDir 'report.txt'
                if (Test-Path -LiteralPath $runReport) { Check ([System.IO.File]::ReadAllText($runReport, $utf8).Contains('FAIL - не прошло утверждение')) 'в report.txt нет подписи вида падения' }
            }
            $again = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ unittests = @($unitMinusFails) }
            Check-Common $again; Check-Verdict $again 'RED' 1
            Check-Step $again 'Модульные тесты' 'FAIL'
        }
    },
    @{
        Name = 'gate-unittests-keep-accept-failures'
        Text = 'модульные тесты: после вердикта «Оставить и принять» - тот же вопрос про падения, «нет» - падение остаётся новым, scope=partial'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $unitConfig
            $null = Add-UnitTestSource -Dir (Join-Path $sb 'tests')
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ absent = @('Тесты'); unittests = @($unitAllOk) }
            Check-Verdict $r 'GREEN' 0
            $file = Add-InboxFile $sb $cfeName
            $red = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Ask' -f $file) -Fake @{ unittests = @($unitMinusFails) } -Answers @(
                @{ Kind = 'one'; Header = 'оставить или откатить'; Item = '^Оставить и принять новое в эталон' },
                @{ Kind = 'confirm'; Header = 'падают модульные тесты'; Yes = $false })
            Check-Common $red; Check-Verdict $red 'RED' 1
            if ($red.RunDir) {
                $acceptedFile = Join-Path $red.RunDir 'accepted.txt'
                Check ((Test-Path -LiteralPath $acceptedFile) -and [System.IO.File]::ReadAllText($acceptedFile, $utf8).Contains('scope=partial')) 'после «Оставить и принять» без падений нет scope=partial'
            }
            $again = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ unittests = @($unitMinusFails) }
            Check-Common $again; Check-Verdict $again 'RED' 1
        }
    },
    @{
        Name = 'gate-unittests-gone-empty'
        Text = 'модульные тесты: тест пропал из отчёта и пустой отчёт - красный (сверка с запланированными), эталон тестов не теряет записи'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $unitConfig
            $null = Add-UnitTestSource -Dir (Join-Path $sb 'tests')
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ absent = @('Тесты'); unittests = @($unitAllOk) }
            Check-Verdict $r 'GREEN' 0
            $baselineFile = Join-Path $sb 'baseline\erp_temp_test\unittests.txt'
            $onlyOne = @{ cases = @(@{ module = 'ОМ_Пример'; method = 'Сложение'; name = 'Сложение двух чисел'; status = 'ok' }) }
            $gone = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ unittests = @($onlyOne) }
            Check-Common $gone
            Check-Step $gone 'Модульные тесты' 'FAIL'
            Check ([System.IO.File]::ReadAllText($baselineFile, $utf8).Contains('ОМ_Пример.Вычитание')) 'пропавший из отчёта тест выпал из эталона'
            $empty = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ unittests = @(@{ cases = @() }) }
            Check-Common $empty
            Check-Step $empty 'Модульные тесты' 'FAIL'
            Check ([System.IO.File]::ReadAllText($baselineFile, $utf8).Contains('ОМ_Пример.Сложение')) 'после пустого отчёта эталон тестов потерял записи'
        }
    },
    @{
        Name = 'gate-unittests-edited-in-temp'
        Text = 'модульные тесты: в temp правили в конфигураторе, а файлы новые - вопрос; «Забрать из temp» кладёт правку в файлы и архив, загрузки нет; дальше без вопросов'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $unitConfig
            $source = Add-UnitTestSource -Dir (Join-Path $sb 'tests')
            $fake = @{ absent = @('Тесты'); unittests = @($unitAllOk) }
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Verdict $r 'GREEN' 0
            # Правка в «конфигураторе temp» - в базе подставной 1С; и новые файлы тестов (новый комплект).
            $stored = Join-Path $sb 'fake\ext\Тесты\CommonModules\ОМ_Пример\Ext\Module.bsl'
            [System.IO.File]::AppendAllText($stored, "`r`n// правка в конфигураторе", $utf8)
            [System.IO.File]::AppendAllText((Join-Path $source 'CommonModules\ОМ_Пример\Ext\Module.bsl'), "`r`n// правка в файлах", $utf8)
            $q = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake -Answers @(
                @{ Kind = 'one'; Header = 'правили в конфигураторе'; Item = '^Забрать тесты' })
            Check-Common $q; Check-Verdict $q 'GREEN' 0
            Check ((Get-Calls $q @('/LoadConfigFromFiles', '-Extension Тесты')).Count -eq 1) 'после «Забрать» тесты всё равно загружены из файлов'
            $text = [System.IO.File]::ReadAllText((Join-Path $source 'CommonModules\ОМ_Пример\Ext\Module.bsl'), $utf8)
            Check ($text.Contains('правка в конфигураторе') -and -not $text.Contains('правка в файлах')) 'в файлах тестов не то, что в temp'
            Check (@(Get-ChildItem -LiteralPath (Join-Path $sb 'out') -Filter 'Тесты_*.zip' -ErrorAction SilentlyContinue).Count -eq 1) 'нет архива для отправки в out'
            Check (@(Get-ChildItem -LiteralPath (Join-Path $sb 'tests\.old') -Directory -ErrorAction SilentlyContinue).Count -eq 1) 'прежние файлы тестов не сохранены в tests\.old'
            if ($q.RunDir) { Check (Test-Path -LiteralPath (Join-Path $q.RunDir 'unittests\Тесты-temp-before')) 'нет копии тестов temp в папке прогона' }
            $third = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $third; Check-Verdict $third 'GREEN' 0
            Check ($null -eq (Get-Step $third 'Тесты: загрузить')) 'после «Забрать» снова шаг загрузки тестов'
        }
    },
    @{
        Name = 'menu-unittests-new-take-run'
        Text = 'меню «Тесты»: новый тест по шаблону в файлах, проверка описаний, прогон одного теста из карточки, забрать из temp'
        Run = {
            param($Name)
            $config = @{ UnitTestExtensions = @('Тесты'); UnitTestAuthor = 'Тестов А.Б.' }
            $sb = New-Sandbox $Name -Config $config
            $source = Add-UnitTestSource -Dir (Join-Path $sb 'tests')
            $fake = @{ absent = @('Тесты'); unittests = @($unitAllOk) }
            $r = Invoke-Script -Sandbox $sb -Fake $fake -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Модульные тесты' },
                @{ Kind = 'one'; Header = 'Модульные тесты \(YAxUnit\)'; Item = '^Новый тест' },
                @{ Kind = 'one'; Header = 'в какой модуль'; Item = '^ОМ_Пример' },
                @{ Kind = 'text'; Header = 'Имя процедуры теста'; Text = 'Умножение' },
                @{ Kind = 'text'; Header = '^@Тест'; Text = 'Умножение двух чисел' },
                @{ Kind = 'text'; Header = '^@Проверяет'; Text = 'CommonModule.Пример.Умножить' },
                @{ Kind = 'text'; Header = '^@Как'; Text = 'умножаем 2 на 3' },
                @{ Kind = 'text'; Header = '^@Зачем'; Text = 'проверка меню' },
                @{ Kind = 'text'; Header = '^@Теги'; Text = '' },
                @{ Kind = 'one'; Header = 'Посмотрел'; Item = '^Вернуться к тестам' },
                @{ Kind = 'one'; Header = 'Модульные тесты \(YAxUnit\)'; Item = '^Проверить описания' },
                @{ Kind = 'one'; Header = 'Модульные тесты \(YAxUnit\)'; Item = '^Список тестов' },
                @{ Kind = 'one'; Header = '^Тесты \('; Item = 'ОМ_Пример\.Сложение' },
                @{ Kind = 'one'; Header = 'Сложение двух чисел'; Item = '^Прогнать только этот' },
                @{ Kind = 'one'; Header = 'Посмотрел'; Item = '^Вернуться к тестам' },
                @{ Kind = 'one'; Header = '^Тесты \('; Cancel = $true },
                @{ Kind = 'one'; Header = 'Модульные тесты \(YAxUnit\)'; Item = '^Забрать тесты' },
                @{ Kind = 'one'; Header = 'Посмотрел'; Item = '^Вернуться к тестам' },
                @{ Kind = 'one'; Header = 'Модульные тесты \(YAxUnit\)'; Item = '^Назад' },
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check ($r.UnusedAnswers -eq 0) ("тест ждал вопросов, а их не было: {0}" -f $r.UnusedAnswers)
            $crash = @($r.Output | Where-Object { $_ -match '^Остановлено: |ParserError|Не получилось' })
            Check ($crash.Count -eq 0) ("ошибка: " + (($crash | Select-Object -First 3) -join ' | '))
            # Прогон одного теста: фильтр YAxUnit - только он; загрузились файлы с новым тестом (его в temp не было).
            $runs = @(Get-ChildItem -LiteralPath (Join-Path $sb 'tests-runs') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*-run' })
            Check ($runs.Count -eq 1) ("служебных прогонов тестов {0}, ждали 1" -f $runs.Count)
            if ($runs.Count -eq 1) {
                $json = [System.IO.File]::ReadAllText((Join-Path $runs[0].FullName 'unittests\yaxunit.json'), $utf8) | ConvertFrom-Json
                Check ((@($json.filter.tests) -join ',') -eq 'ОМ_Пример.Сложение') ("фильтр одного теста: {0}" -f (@($json.filter.tests) -join ','))
                Check ($json.filter.tests -is [array] -and $json.filter.extensions -is [array]) 'filter.tests и filter.extensions в настройках YAxUnit - не массивы JSON'
            }
            Check ((Get-Calls $r @('/LoadConfigFromFiles', '-Extension Тесты')).Count -eq 1) 'новые файлы тестов не загружены перед прогоном'
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'baseline\erp_temp_test\unittests.txt'))) 'прогон одного теста записал эталон'
            # Забрали из temp: в файлах - то, что загружено (с новым тестом), в out - архив.
            $text = [System.IO.File]::ReadAllText((Join-Path $source 'CommonModules\ОМ_Пример\Ext\Module.bsl'), $utf8)
            Check ($text.Contains('// @Тест Умножение двух чисел') -and $text.Contains('.ДобавитьТест("Умножение", "Умножение двух чисел");')) 'новый тест не в файлах'
            Check ($text -match '// @Автор Тестов А\.Б\. \d{8}') 'автор нового теста без даты'
            Check (@(Get-ChildItem -LiteralPath (Join-Path $sb 'out') -Filter 'Тесты_*.zip' -ErrorAction SilentlyContinue).Count -eq 1) 'нет архива «Забрать тесты»'
        }
    },
    @{
        Name = 'deploy-unittest-extension-guard'
        Text = 'deploy: тестовое расширение в DeployExtensions - отказ, в рабочую тесты не уходят'
        Run = {
            param($Name)
            $config = @{}
            foreach ($key in $deployConfig.Keys) { $config[$key] = $deployConfig[$key] }
            $config['DeployExtensions'] = @('Адаптация', 'Тесты')
            $sb = New-Sandbox $Name -Config $config
            [System.IO.File]::WriteAllLines((Join-Path $sb 'config.site.psd1'), [string[]]@('@{', "    UnitTestExtensions = @('Тесты')", '}'), $utf8Bom)
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-StatusOnly' -Com (New-ComState)
            Check ($r.ExitCode -ne 0) 'deploy с тестовым расширением в DeployExtensions не остановился'
            Check (@($r.Output | Where-Object { $_ -match 'тестовое расширение' }).Count -gt 0) 'нет объяснения про тестовое расширение'
            Check (@($r.Calls | Where-Object { $_.Line.Contains('/LoadCfg') }).Count -eq 0) 'deploy что-то загружал'
        }
    },
    @{
        Name = 'settings-site-not-shadowed'
        Text = 'настройки: пустое значение в config.psd1 не закрывает config.site.psd1 (убирается), умолчание для ключа площадки не дописывается; гейт берёт значение площадки'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ ContractorExtensions = @() }
            [System.IO.File]::WriteAllLines((Join-Path $sb 'config.site.psd1'), [string[]]@('@{', "    ContractorExtensions = @('Доработки')", "    UnitTestAuthor = 'Тестов А.Б.'", '}'), $utf8Bom)
            $r = Invoke-Script -Sandbox $sb -Script 'settings.ps1' -Answers @(@{ Kind = 'one'; Header = '^Настройки: '; Item = '^Готово$' })
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            $config = Import-PowerShellDataFile -LiteralPath (Join-Path $sb 'config.psd1')
            Check (-not $config.ContainsKey('ContractorExtensions')) 'пустой ContractorExtensions остался в config.psd1 и закрывает настройку площадки'
            Check (-not $config.ContainsKey('UnitTestAuthor')) 'умолчание UnitTestAuthor дописано поверх настройки площадки'
            Check ($config.ContainsKey('ReleaseJobsLock')) 'обычные умолчания не дописаны'
        }
    },
    @{
        Name = 'gate-publish-run-report'
        Text = 'итог прогона в GitHub (RunReportRepo): зелёный - событие gate-run «final» с итогом, токен только в заголовке; нет связи - прогон не портится, итог уходит при следующем запуске'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ RunReportRepo = 'owner/repo'; GitHubTokenPassFile = 'secrets\github.txt' }
            New-Item -ItemType Directory -Path (Join-Path $sb 'secrets') -Force | Out-Null
            $secret = 'tok-секрет-456'
            [System.IO.File]::WriteAllText((Join-Path $sb 'secrets\github.txt'), (ConvertFrom-SecureString -SecureString (ConvertTo-SecureString $secret -AsPlainText -Force)))
            $http = Join-Path $sb 'fake-http'
            New-Item -ItemType Directory -Path $http -Force | Out-Null
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep'
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            $sent = @(Get-ChildItem -LiteralPath $http -Filter 'dispatch-*.json' | Sort-Object Name)
            Check ($sent.Count -eq 1) ("событий {0}, ждали 1" -f $sent.Count)
            if ($sent.Count -ge 1) {
                $raw = [System.IO.File]::ReadAllText($sent[0].FullName, $utf8)
                $dispatchEvent = $raw | ConvertFrom-Json
                Check ($dispatchEvent.event_type -eq 'gate-run') ("событие {0}, ждали gate-run" -f $dispatchEvent.event_type)
                Check ($dispatchEvent.client_payload.stage -eq 'final' -and $dispatchEvent.client_payload.verdict -eq 'GREEN') ("этап {0}, вердикт {1}" -f $dispatchEvent.client_payload.stage, $dispatchEvent.client_payload.verdict)
                if ($r.RunDir) { Check ($dispatchEvent.client_payload.run -eq (Split-Path -Leaf $r.RunDir)) 'в событии не тот прогон' }
                Check (([string]$dispatchEvent.client_payload.body) -match 'ЗЕЛЁНЫЙ' -and ([string]$dispatchEvent.client_payload.body) -match 'summary\.txt' -and ([string]$dispatchEvent.client_payload.body) -match 'Самопроверка') 'в тексте нет вердикта или итога'
                Check (-not $raw.Contains($secret)) 'токен в теле события'
            }
            $requests = [System.IO.File]::ReadAllText((Join-Path $http 'requests.log'), $utf8)
            Check ($requests -match 'POST https://api\.github\.com/repos/owner/repo/dispatches токен=да') 'событие ушло не туда или без токена'
            Check (@($r.Output | Where-Object { $_ -match [regex]::Escape($secret) }).Count -eq 0) 'токен в выводе'
            if ($r.RunDir) {
                $state = [System.IO.File]::ReadAllText((Join-Path $r.RunDir 'publish.json'), $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
                Check ($state.sent -eq 'final') 'publish.json: не отмечено, что итог ушёл'
            }
            # Нет связи: прогон тот же зелёный, итог не ушёл - и уходит при следующем запуске.
            [System.IO.File]::WriteAllText((Join-Path $http 'dispatch-fail.txt'), 'x')
            Reset-FakeState $sb
            $offline = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep'
            Check-Common $offline; Check-Verdict $offline 'GREEN' 0
            Check (@($offline.Output | Where-Object { $_ -match 'в GitHub не ушёл' }).Count -gt 0) 'не сказано, что итог не ушёл'
            Remove-Item -LiteralPath (Join-Path $http 'dispatch-fail.txt') -Force
            Reset-FakeState $sb
            $next = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep'
            Check-Common $next
            $runsSent = @(Get-ChildItem -LiteralPath $http -Filter 'dispatch-*.json' | ForEach-Object { [string](([System.IO.File]::ReadAllText($_.FullName, $utf8) | ConvertFrom-Json).client_payload.run) })
            if ($offline.RunDir) { Check ($runsSent -contains (Split-Path -Leaf $offline.RunDir)) 'итог прогона без связи не ушёл при следующем запуске' }
            if ($next.RunDir) { Check ($runsSent -contains (Split-Path -Leaf $next.RunDir)) 'итог следующего прогона не ушёл' }
        }
    },
    @{
        Name = 'gate-publish-crash-broken'
        Text = 'итог в GitHub при любом исходе: прогон остановлен (отмена на вопросе) - событие «crash» с причиной и шагами; прогон оборвался (процесса нет, итог не ушёл) - при следующем запуске событие «broken»'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ RunReportRepo = 'owner/repo'; GitHubTokenPassFile = 'secrets\github.txt' }
            New-Item -ItemType Directory -Path (Join-Path $sb 'secrets') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $sb 'secrets\github.txt'), (ConvertFrom-SecureString -SecureString (ConvertTo-SecureString 'tok-789' -AsPlainText -Force)))
            $http = Join-Path $sb 'fake-http'
            New-Item -ItemType Directory -Path $http -Force | Out-Null
            # Прогон, который оборвался после вердикта: процесса с таким номером и временем старта нет.
            $broken = Join-Path $sb 'runs\20000101-000000'
            New-Item -ItemType Directory -Path $broken -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $broken 'pid.txt'), '999999|2000-01-01T00:00:00.0000000+03:00')
            [System.IO.File]::WriteAllText((Join-Path $broken 'publish.json'), '{"wanted":"verdict","sent":"verdict","message":""}')
            [System.IO.File]::WriteAllText((Join-Path $broken 'run.log'), "00:00:01 загрузка`r`n", $utf8Bom)
            # Прогон без pid.txt (до включения отправки) - его не трогаем.
            New-Item -ItemType Directory -Path (Join-Path $sb 'runs\19990101-000000') -Force | Out-Null
            $file = Add-InboxFile $sb $cfeName
            $busy = 'Ошибка блокировки информационной базы для конфигурирования. С этой информационной базой уже работает конфигуратор: компьютер: pc1, сеанс: 5'
            $fake = @{ designer = @(@{ match = @('/LoadCfg', 'Адаптация'); exit = 1; log = $busy; times = 1 }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake -Answers @(
                @{ Kind = 'one'; Header = 'Открыт конфигуратор'; Item = '^Отмена' })
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check ($r.ExitCode -ne 0) 'прогон не завершился после отмены'
            $events = @(Get-ChildItem -LiteralPath $http -Filter 'dispatch-*.json' | Sort-Object Name | ForEach-Object { ([System.IO.File]::ReadAllText($_.FullName, $utf8) | ConvertFrom-Json).client_payload })
            $brokenEvents = @($events | Where-Object { [string]$_.run -eq '20000101-000000' })
            Check ($brokenEvents.Count -eq 1 -and [string]$brokenEvents[0].stage -eq 'broken' -and ([string]$brokenEvents[0].body) -match 'ОБОРВАЛСЯ') 'оборвавшийся прогон не ушёл как «broken»'
            Check (@($events | Where-Object { [string]$_.run -eq '19990101-000000' }).Count -eq 0) 'ушёл прогон без pid.txt (до включения отправки)'
            $crashEvents = @($events | Where-Object { [string]$_.stage -eq 'crash' })
            Check ($crashEvents.Count -eq 1) ("событий crash {0}, ждали 1" -f $crashEvents.Count)
            if ($crashEvents.Count -eq 1) {
                $body = [string]$crashEvents[0].body
                Check ($body -match 'ОСТАНОВЛЕН' -and $body -match 'Причина:.*отменено пользователем') 'в событии нет причины остановки'
                Check ($body -match 'run\.log') 'в событии нет конца run.log'
                if ($r.RunDir) { Check ([string]$crashEvents[0].run -eq (Split-Path -Leaf $r.RunDir)) 'crash не того прогона' }
            }
        }
    },
    @{
        Name = 'git-export'
        Text = '«Выгрузить temp в git»: первый снимок и следующая правка в отдельных PR, основная ветка сохраняет исходный коммит. Состав снимка, state.json и повтор без изменений.'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name
            $gh = Get-FakeGh $sb
            $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
            $seed = (Get-GhHead -Gh $gh -Branch 'main').Sha
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers $gitBootstrapAnswers
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("код {0}, ждали 0: {1}" -f $r.ExitCode, (($r.Output | Select-Object -Last 3) -join ' | '))
            $head = (Get-GhHead -Gh $gh -Branch 'main').Sha
            Check ($head -eq $seed) 'первая выгрузка двинула main'
            $first = Read-GitStateFile $sb
            Check ($first.pendingNumber -eq 1 -and $first.pendingBranch -like 'temp/*') 'у первого снимка нет PR'
            Check ($first.commit -eq $first.pendingCommit -and $first.commit -ne $seed) 'коммит первого снимка не отмечен как pending'
            Check ((Get-GhHead -Gh $gh -Branch $first.pendingBranch).Sha -eq $first.commit) 'в PR первого снимка другой коммит'
            if ($first.commit) {
                $files = Get-GhFiles -Gh $gh -Commit $first.commit
                foreach ($path in @('README.md', '.gitattributes', 'extensions/Адаптация/Configuration.xml', 'extensions/Адаптация/CommonModules/АГБ_Общий/Ext/Module.bsl',
                        'extensions/Доработки/Configuration.xml', 'processings/Печать/Печать.xml', 'processings/Печать/Печать/Ext/ObjectModule.bsl', 'processings/manifest.json')) {
                    Check ($files.ContainsKey($path)) ("в первом снимке нет {0}" -f $path)
                }
                Check (@($files.Keys | Where-Object { $_ -match 'ConfigDumpInfo' }).Count -eq 0) 'ConfigDumpInfo.xml попал в git'
                Check ($files['README.md'] -eq (Get-GhFiles -Gh $gh -Commit $seed)['README.md']) 'гейт заменил README владельца'
            }
            # Владелец принял первый PR после CI. Следующая выгрузка идёт от принятого снимка.
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $first.commit
            $head = $first.commit
            Reset-FakeState $sb
            $same = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com
            Check-DeployCommon $same -LocksExpected $false
            Check (@($same.Output | Where-Object { $_ -match 'выгружать нечего' }).Count -eq 1) 'без правок не сказано «выгружать нечего»'
            Reset-FakeState $sb
            $pr = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps -Adapt 'Процедура Новая() КонецПроцедуры') } -Com $com -Answers @(
                @{ Kind = 'confirm'; Header = 'веткой temp/'; Yes = $true })
            Check-DeployCommon $pr -LocksExpected $false
            Check ((Get-GhHead -Gh $gh -Branch 'main').Sha -eq $head) 'выгрузка правок двинула main'
            $pulls = Join-Path $sb 'fake-github\pulls.txt'
            Check ((Test-Path -LiteralPath $pulls) -and ([System.IO.File]::ReadAllText($pulls, $utf8) -match "2`ttemp/\d{8}-\d{6}(-\d+)?`tmain`t")) 'нет pull request из temp/<время> в main'
            $state = Read-GitStateFile $sb
            Check ([int]$state.pendingNumber -eq 2 -and $state.commit -and $state.commit -ne $head) 'state.json: нет неслитого pull request с правками temp'
            if ($state.commit -and $head) {
                $path = 'extensions/Адаптация/CommonModules/АГБ_Общий/Ext/Module.bsl'
                Check ((Get-GhFiles -Gh $gh -Commit $state.commit)[$path] -ne (Get-GhFiles -Gh $gh -Commit $head)[$path]) 'в ветке temp правки нет'
            }
        }
    },
    @{
        Name = 'git-export-guards'
        Text = 'Выгрузка в пустой репозиторий и ошибка создания PR останавливаются без записи в main и без принятого состояния.'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name -Empty
            $gh = Get-FakeGh $sb
            $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com
            Check ($r.ExitCode -ne 0 -and $r.Unexpected.Count -eq 0) 'пустой репозиторий не отклонён до выгрузки'
            Check (@($r.Output | Where-Object { $_ -match 'начальным коммитом' }).Count -eq 1) 'нет инструкции по созданию основной ветки'
            Check ((Get-GhHead -Gh $gh -Branch 'main').Empty) 'пустой репозиторий изменился'

            $file = [pscustomobject]@{ Path = 'README.md'; Bytes = $utf8.GetBytes('Начальный коммит владельца') }
            $seed = New-GhCommit -Gh $gh -Parent '' -Changes @($file) -Message 'Основная ветка'
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $seed -Create
            # Файл журнала PR подставного GitHub недоступен для записи.
            New-Item -ItemType Directory -Path (Join-Path $sb 'fake-github\pulls.txt') | Out-Null
            Reset-FakeState $sb
            $fail = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers $gitBootstrapAnswers
            Check ($fail.ExitCode -ne 0 -and $fail.Unexpected.Count -eq 0) 'ошибка создания PR не остановила выгрузку'
            Check (@($fail.Output | Where-Object { $_ -match 'Снимок [a-f0-9]{40} в ветке temp/.+не подтверждено' }).Count -ge 1) 'нет ветки и SHA для восстановления PR'
            Check ((Get-GhHead -Gh $gh -Branch 'main').Sha -eq $seed) 'ошибка создания PR изменила main'
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'git\ext\state.json'))) 'ошибка создания PR отмечена как успешная выгрузка'
        }
    },
    @{
        Name = 'git-import'
        Text = '«Загрузить из git»: temp правили после загрузки - вопрос и файлы правок на экране, «Отмена» ничего не трогает; правок нет - так и сказано, названо, что изменит загрузка, прогон гейта только с тем, что изменилось в main (-KitSource с коммитом), после прогона state.json - на main'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name
            $gh = Get-FakeGh $sb
            $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
            $boot = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers $gitBootstrapAnswers
            Check-DeployCommon $boot -LocksExpected $false
            # Владелец принял первый снимок.
            Set-GhBranch -Gh $gh -Branch 'main' -Sha (Read-GitStateFile $sb).pendingCommit
            $head = (Get-GhHead -Gh $gh -Branch 'main').Sha
            Check ([bool]$head) 'в тестовом репозитории отсутствует принятый снимок'
            if (-not $head) { return }
            # В main слили правку Доработок (как после pull request агента).
            $change = [pscustomobject]@{ Path = 'extensions/Доработки/CommonModules/Д/Ext/Module.bsl'; Bytes = $utf8.GetBytes('Процедура Д2() КонецПроцедуры') }
            $merged = New-GhCommit -Gh $gh -Parent $head -Changes @($change) -Message 'слитый pull request'
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $merged
            [System.IO.File]::WriteAllText((Join-Path $sb 'run.ps1'), $gitRunStub, $utf8Bom)
            Reset-FakeState $sb
            $drift = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = (New-GitDumps -Adapt 'Процедура ПравкаВTemp() КонецПроцедуры') } -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'правки после прошлой загрузки'; Item = '^Отмена' })
            Check-DeployCommon $drift -LocksExpected $false
            Check (@($drift.Output | Where-Object { $_ -match 'есть правки, которых нет в git' }).Count -eq 1) 'правки temp не замечены'
            Check (@($drift.Output | Where-Object { $_.Contains('~ extensions/Адаптация/CommonModules/АГБ_Общий/Ext/Module.bsl') }).Count -eq 1) 'не назван файл, который правили в temp'
            Check (@($drift.Output | Where-Object { $_ -match 'правок нет' }).Count -eq 0) 'при правках в temp сказано «правок нет»'
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'runs'))) 'после «Отмена» гейт запускался'
            Check ((Read-GitStateFile $sb).commit -eq $head) 'после «Отмена» state.json поменялся'
            Reset-FakeState $sb
            $load = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers @(
                @{ Kind = 'confirm'; Header = 'Загрузить в erp_temp_test из main'; Yes = $true })
            Check-DeployCommon $load -LocksExpected $false
            Check ($load.ExitCode -eq 0) ("код {0}, ждали 0: {1}" -f $load.ExitCode, (($load.Output | Select-Object -Last 3) -join ' | '))
            # Итог сверки и то, что изменит загрузка, - на экране: вопрос после ответа с экрана уходит.
            Check (@($load.Output | Where-Object { $_ -match 'правок нет: erp_temp_test совпадает с коммитом' }).Count -eq 1) 'не сказано, что правок в temp нет'
            Check (@($load.Output | Where-Object { $_ -match 'Загрузка изменит в erp_temp_test' }).Count -eq 1) 'не сказано, что изменит загрузка'
            Check (@($load.Output | Where-Object { $_.Contains('~ extensions/Доработки/CommonModules/Д/Ext/Module.bsl') }).Count -eq 1) 'не назван файл, который изменит загрузка'
            Check (@($load.Output | Where-Object { $_ -match '^\s*[~+-] extensions/Адаптация' }).Count -eq 0) 'в том, что изменит загрузка, названо расширение, которое не менялось'
            $stubFile = @(Get-ChildItem -LiteralPath (Join-Path $sb 'runs') -Recurse -Filter 'stub.txt' -ErrorAction SilentlyContinue)
            Check ($stubFile.Count -eq 1) 'гейт не запускался'
            if ($stubFile.Count -eq 1) {
                $stub = [System.IO.File]::ReadAllText($stubFile[0].FullName, $utf8)
                Check ($stub -match ('KitSource=git owner/ext@' + $merged.Substring(0, 7))) 'в -KitSource нет коммита main'
                Check ($stub -match 'dir=Доработки' -and $stub -notmatch 'dir=Адаптация' -and $stub -notmatch 'dir=Печать') ("в комплекте не только изменившееся: " + $stub)
                Check ($stub -match 'file=Доработки/Configuration\.xml' -and $stub -match 'file=Доработки/CommonModules/Д/Ext/Module\.bsl') 'в комплекте нет выгрузки Доработок целиком'
            }
            Check ((Read-GitStateFile $sb).commit -eq $merged) 'после прогона state.json не на main'
            Check (@($load.Output | Where-Object { $_ -match 'теперь на main' }).Count -eq 1) 'не сказано, что temp на main'
        }
    },
    @{
        Name = 'git-import-actions'
        Text = '«Загрузить из git» и действия после обновления (actions/*.bsl в main): только новые действия - прогон без комплекта с -ActionsDir и -KitBranch, выполненные - в state.json, повтор - «загружать нечего»; с правкой расширения - действия папкой actions в комплекте, все; упавшее не записано выполненным и запускается следующей загрузкой'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name
            $gh = Get-FakeGh $sb
            $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
            $boot = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers $gitBootstrapAnswers
            Check-DeployCommon $boot -LocksExpected $false
            Set-GhBranch -Gh $gh -Branch 'main' -Sha (Read-GitStateFile $sb).pendingCommit
            $head = (Get-GhHead -Gh $gh -Branch 'main').Sha
            if (-not $head) { Check $false 'в тестовом репозитории отсутствует принятый снимок'; return }
            $action = { param([string]$Title, [string]$Body) $utf8.GetBytes(("// @Действие {0}`r`n// @Зачем для теста`r`n// @Автор Тест`r`n// @Задача 1`r`n{1}`r`n" -f $Title, $Body)) }
            $first = '20261120-01-Первое'
            $second = '20261120-02-Второе'
            $third = '20261121-01-Падает'
            $withActions = New-GhCommit -Gh $gh -Parent $head -Changes @(
                [pscustomobject]@{ Path = ('actions/{0}.bsl' -f $first); Bytes = (& $action 'Первое' 'Журнал.Добавить("1");') },
                [pscustomobject]@{ Path = ('actions/{0}.bsl' -f $second); Bytes = (& $action 'Второе' 'Журнал.Добавить("2");') },
                [pscustomobject]@{ Path = 'actions/README.md'; Bytes = $utf8.GetBytes('Действия после обновления') }) -Message 'действия'
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $withActions
            [System.IO.File]::WriteAllText((Join-Path $sb 'run.ps1'), $gitRunStub, $utf8Bom)
            $stubs = { @(Get-ChildItem -LiteralPath (Join-Path $sb 'runs') -Recurse -Filter 'stub.txt' -ErrorAction SilentlyContinue | Sort-Object { $_.Directory.Name }) }

            # Только действия: расширения temp на main, прогон без комплекта.
            Reset-FakeState $sb
            $only = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers @(
                @{ Kind = 'confirm'; Header = 'Загрузить в erp_temp_test из main'; Yes = $true })
            Check-DeployCommon $only -LocksExpected $false
            Check ($only.ExitCode -eq 0) ("код {0}, ждали 0: {1}" -f $only.ExitCode, (($only.Output | Select-Object -Last 3) -join ' | '))
            Check (@($only.Questions | Where-Object { $_ -match 'действия после обновления \(2\)' }).Count -eq 1) ('в вопросе не сказано, что загрузятся два новых действия: ' + ($only.Questions -join ' | '))
            Check (@($only.Output | Where-Object { $_.Contains(('+ actions/{0}.bsl' -f $first)) }).Count -eq 1) 'новое действие не названо в том, что изменит загрузка'
            $found = & $stubs
            Check ($found.Count -eq 1) ("прогонов {0}, ждали один" -f $found.Count)
            if ($found.Count -ge 1) {
                $stub = [System.IO.File]::ReadAllText($found[0].FullName, $utf8)
                Check ($stub -match '(?m)^Kit=\s*$' -and $stub -match '(?m)^ActionsDir=.*actions-') ("прогон только действий не без комплекта: " + $stub)
                Check ($stub -match '(?m)^KitBranch=main\s*$' -and $stub -match ('KitSource=git owner/ext@' + $withActions.Substring(0, 7))) ("в прогон не переданы ветка и коммит: " + $stub)
                Check ($stub -match ('actionfile=' + $first) -and $stub -match ('actionfile=' + $second)) ("в папке действий не оба действия: " + $stub)
            }
            $state = Read-GitStateFile $sb
            Check ((@($state.actionsDone) -contains $first) -and (@($state.actionsDone) -contains $second)) ('state.json: выполненные действия не записаны: ' + (@($state.actionsDone) -join ', '))
            Check ($state.commit -eq $withActions) 'после прогона действий state.json не на main'
            Check (@($only.Output | Where-Object { $_ -match 'действия после обновления выполнены' }).Count -eq 1) 'не сказано, что действия выполнены'

            # Повтор: всё выполнено - прогона нет.
            Reset-FakeState $sb
            $same = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = (New-GitDumps) } -Com $com
            Check-DeployCommon $same -LocksExpected $false
            Check ($same.Unexpected.Count -eq 0) ("при повторе вопросы: " + ($same.Unexpected -join ' | '))
            Check (@($same.Output | Where-Object { $_ -match 'загружать нечего' }).Count -eq 1) 'при выполненных действиях не сказано «загружать нечего»'
            Check ((& $stubs).Count -eq 1) 'выполненные действия запускались снова'

            # Правка расширения и новое действие, которое падает: комплект с папкой actions, в ней все действия.
            $mixed = New-GhCommit -Gh $gh -Parent $withActions -Changes @(
                [pscustomobject]@{ Path = 'extensions/Доработки/CommonModules/Д/Ext/Module.bsl'; Bytes = $utf8.GetBytes('Процедура Д3() КонецПроцедуры') },
                [pscustomobject]@{ Path = ('actions/{0}.bsl' -f $third); Bytes = (& $action 'Падает' 'ВызватьИсключение "УПАДИ";') }) -Message 'расширение и действие'
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $mixed
            Reset-FakeState $sb
            $kit = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers @(
                @{ Kind = 'confirm'; Header = 'Загрузить в erp_temp_test из main'; Yes = $true })
            Check-DeployCommon $kit -LocksExpected $false
            $found = & $stubs
            Check ($found.Count -eq 2) ("прогонов {0}, ждали два" -f $found.Count)
            if ($found.Count -ge 2) {
                $stub = [System.IO.File]::ReadAllText($found[1].FullName, $utf8)
                Check ($stub -match '(?m)^Kit=.*kit-' -and $stub -match '(?m)^ActionsDir=\s*$') ("с правкой расширения не комплект: " + $stub)
                Check ($stub -match 'dir=Доработки' -and $stub -match 'dir=actions' -and $stub -notmatch 'dir=Адаптация') ("в комплекте не то: " + $stub)
                Check ($stub -match ('actionfile=' + $first) -and $stub -match ('actionfile=' + $third) -and $stub -notmatch 'actionfile=README') ("в комплекте не все действия или лишнее: " + $stub)
                Check ($stub -match '(?m)^KitBranch=main\s*$') 'в прогон с комплектом не передана ветка'
            }
            $state = Read-GitStateFile $sb
            Check (-not (@($state.actionsDone) -contains $third)) 'упавшее действие записано выполненным'
            Check ($state.commit -eq $mixed) 'после зелёного прогона комплекта state.json не на main'
            Check (@($kit.Output | Where-Object { $_ -match ('не выполнены: ' + $third) }).Count -eq 1) 'не сказано, что упавшее действие не выполнено'

            # Следующая загрузка запускает упавшее снова - прогоном только действий.
            Reset-FakeState $sb
            $again = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = (New-GitDumps -Extra 'Процедура Д3() КонецПроцедуры') } -Com $com -Answers @(
                @{ Kind = 'confirm'; Header = 'Загрузить в erp_temp_test из main'; Yes = $true })
            Check-DeployCommon $again -LocksExpected $false
            $found = & $stubs
            Check ($found.Count -eq 3) ("после упавшего действия прогонов {0}, ждали три" -f $found.Count)
            if ($found.Count -ge 3) {
                $stub = [System.IO.File]::ReadAllText($found[2].FullName, $utf8)
                Check ($stub -match '(?m)^Kit=\s*$' -and $stub -match ('actionfile=' + $third)) ("упавшее действие не запущено снова без комплекта: " + $stub)
            }
        }
    },
    @{
        Name = 'git-processings-all'
        Text = 'обработки в git - все элементы справочника: два элемента с одним именем объекта - основной в <имя>/, помеченный на удаление в <имя>~<ссылка>/, элемент без файла - только в manifest.json (вид, публикация, безопасный режим, пометка, ссылка, хеш, назначение); повторная выгрузка - без конфигуратора; загрузка: правка в <имя>~<ссылка> не грузится, другой manifest в temp - не правка temp'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name
            $gh = Get-FakeGh $sb
            $procs = @(
                @{ objName = 'Печать'; title = 'Печать актов'; version = '2'; kind = 'Печатная форма'; content = $printOld; ref = 'bbbbbbbb-0000-0000-0000-000000000002'; targets = @('Документ.Акт', 'Документ.Акт') },
                @{ objName = 'Печать'; title = 'Печать актов (старая)'; version = '1'; kind = 'Печатная форма'; content = 'Процедура Старая() КонецПроцедуры'; deleted = $true; use = 'Отключена'; ref = 'aaaaaaaa-0000-0000-0000-000000000001' },
                @{ objName = 'Отчет'; title = 'Отчёт по складу'; version = '1'; kind = 'Дополнительный отчет'; content = 'Процедура О() КонецПроцедуры'; use = 'Отключена'; safeMode = $false; ref = 'cccccccc-0000-0000-0000-000000000003' },
                @{ objName = 'Пустая'; title = 'Без файла'; version = '1'; kind = 'Дополнительная обработка'; ref = 'dddddddd-0000-0000-0000-000000000004' })
            $com = New-ComState -TempProcessings $procs
            $boot = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers $gitBootstrapAnswers
            Check-DeployCommon $boot -LocksExpected $false
            # Владелец принял первый снимок.
            Set-GhBranch -Gh $gh -Branch 'main' -Sha (Read-GitStateFile $sb).pendingCommit
            Check ($boot.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($boot.Unexpected -join ' | '))
            $head = (Get-GhHead -Gh $gh -Branch 'main').Sha
            if (-not $head) { Check $false 'в тестовом репозитории отсутствует принятый снимок'; return }
            $files = Get-GhFiles -Gh $gh -Commit $head
            foreach ($path in @('processings/Печать/Печать.xml', 'processings/Печать/Печать/Ext/ObjectModule.bsl', 'processings/Печать~aaaaaaaa/Печать.xml', 'processings/Отчет/Отчет.xml', 'processings/manifest.json')) {
                Check ($files.ContainsKey($path)) ("в main нет {0}" -f $path)
            }
            Check (@($files.Keys | Where-Object { $_ -like 'processings/Пустая*' }).Count -eq 0) 'у элемента без файла появилась папка'
            if ($files.ContainsKey('processings/manifest.json')) {
                # ConvertFrom-Json в PowerShell 5.1 отдаёт массив JSON одним объектом: @() вокруг конвейера завернул бы его ещё раз.
                $parsed = [System.IO.File]::ReadAllText((Join-Path $sb ('fake-github\blobs\' + $files['processings/manifest.json'])), $utf8) | ConvertFrom-Json
                $manifest = @($parsed | ForEach-Object { $_ })
                $byRef = @{}
                foreach ($entry in $manifest) { $byRef[[string]$entry.ref] = $entry }
                Check ($manifest.Count -eq 4) ("в manifest.json элементов {0}, ждали 4" -f $manifest.Count)
                $main = $byRef['bbbbbbbb-0000-0000-0000-000000000002']
                Check ($null -ne $main -and $main.folder -eq 'Печать' -and -not $main.deleted -and $main.use -eq 'Используется' -and $main.kind -eq 'Печатная форма' -and $main.fileHash -match '^sha256:[0-9a-f]{64}$' -and (@($main.targets) -join ',') -eq 'Документ.Акт') 'manifest.json: основной элемент Печать описан не так'
                $old = $byRef['aaaaaaaa-0000-0000-0000-000000000001']
                Check ($null -ne $old -and $old.folder -eq 'Печать~aaaaaaaa' -and $old.deleted -and $old.use -eq 'Отключена') 'manifest.json: помеченный на удаление элемент описан не так'
                $report = $byRef['cccccccc-0000-0000-0000-000000000003']
                Check ($null -ne $report -and $report.folder -eq 'Отчет' -and $report.file -eq 'Отчет.erf' -and $report.safeMode -eq $false) 'manifest.json: отчёт описан не так'
                $empty = $byRef['dddddddd-0000-0000-0000-000000000004']
                Check ($null -ne $empty -and $null -eq $empty.folder -and $null -eq $empty.file) 'manifest.json: элемент без файла описан не так'
            }
            # Повторная выгрузка без правок: файлы те же - конфигуратор обработки не выгружает.
            Reset-FakeState $sb
            $same = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com
            Check-DeployCommon $same -LocksExpected $false
            Check (@($same.Output | Where-Object { $_ -match 'выгружать нечего' }).Count -eq 1) 'без правок не сказано «выгружать нечего»'
            $calls = Join-Path $sb 'fake\calls.log'
            $dumpCalls = 0
            if (Test-Path -LiteralPath $calls) { $dumpCalls = @([System.IO.File]::ReadAllLines($calls, $utf8) | Where-Object { $_ -match 'DumpExternalDataProcessorOrReportToFiles' }).Count }
            Check ($dumpCalls -eq 0) ("повторная выгрузка без правок звала конфигуратор для обработок {0} раз" -f $dumpCalls)
            # В main правят и основную Печать, и помеченную на удаление; в temp поменялось только наименование (manifest).
            $changed = New-GhCommit -Gh $gh -Parent $head -Changes @(
                [pscustomobject]@{ Path = 'processings/Печать/Печать/Ext/ObjectModule.bsl'; Bytes = $utf8.GetBytes('Процедура Печать2() КонецПроцедуры') },
                [pscustomobject]@{ Path = 'processings/Печать~aaaaaaaa/Печать/Ext/ObjectModule.bsl'; Bytes = $utf8.GetBytes('Процедура СтараяПравка() КонецПроцедуры') }) -Message 'pull request агента'
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $changed
            $procs[0]['title'] = 'Печать актов, новое наименование'
            $com2 = New-ComState -TempProcessings $procs
            [System.IO.File]::WriteAllText((Join-Path $sb 'run.ps1'), $gitRunStub, $utf8Bom)
            Reset-FakeState $sb
            $imp = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = (New-GitDumps) } -Com $com2 -Answers @(
                @{ Kind = 'confirm'; Header = 'Загрузить в erp_temp_test из main'; Yes = $true })
            Check-DeployCommon $imp -LocksExpected $false
            Check ($imp.Unexpected.Count -eq 0) ("при загрузке неожиданные вопросы (manifest.json - правка temp?): " + ($imp.Unexpected -join ' | '))
            Check (@($imp.Output | Where-Object { $_ -match 'Печать~aaaaaaaa.*не основной элемент' }).Count -eq 1) 'не сказано, что правка не основного элемента не грузится'
            $stubs = @(Get-ChildItem -LiteralPath (Join-Path $sb 'runs') -Recurse -Filter 'stub.txt' -ErrorAction SilentlyContinue)
            Check ($stubs.Count -eq 1) 'загрузки не было'
            if ($stubs.Count -eq 1) {
                $text = [System.IO.File]::ReadAllText($stubs[0].FullName, $utf8)
                Check ($text -match '(?m)^dir=Печать\s*$' -and $text -notmatch 'dir=[^\r\n]*~' -and $text -notmatch 'dir=Отчет') ("в комплекте не только основная Печать: " + $text)
            }
        }
    },
    @{
        Name = 'git-prod-processings'
        Text = '«Снимок внешних обработок рабочей в git» (deploy.ps1 -GitProd): первый раз - ветка prod от main без расширений, обработки рабочей (только чтение: блокировок и сеансов не трогает), PROD.md, main не тронут; без изменений - «записывать нечего» без вопросов; обработку в рабочей поменяли - новый коммит в prod поверх прежнего'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name
            $gh = Get-FakeGh $sb
            $prodProcs = @(
                @{ objName = 'Печать'; title = 'Печать актов'; version = '2'; kind = 'Печатная форма'; content = $printNew; ref = 'eeeeeeee-0000-0000-0000-000000000005' },
                @{ objName = 'ТолькоВРабочей'; title = 'Обработка рабочей'; version = '1'; kind = 'Дополнительная обработка'; content = 'Процедура Р() КонецПроцедуры'; ref = 'ffffffff-0000-0000-0000-000000000006' })
            $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld)) -ProdProcessings $prodProcs
            $boot = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers $gitBootstrapAnswers
            Check-DeployCommon $boot -LocksExpected $false
            # Владелец принял первый снимок.
            Set-GhBranch -Gh $gh -Branch 'main' -Sha (Read-GitStateFile $sb).pendingCommit
            $main = (Get-GhHead -Gh $gh -Branch 'main').Sha
            if (-not $main) { Check $false 'в тестовом репозитории отсутствует принятый снимок'; return }
            Reset-FakeState $sb
            $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitProd' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers @(
                @{ Kind = 'confirm'; Header = 'Записать снимок обработок erp_base'; Yes = $true })
            Check-DeployCommon $first -LocksExpected $false
            Check ($first.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($first.Unexpected -join ' | '))
            Check ((Get-GhHead -Gh $gh -Branch 'main').Sha -eq $main) 'снимок рабочей тронул main'
            $prod = (Get-GhHead -Gh $gh -Branch 'prod').Sha
            Check ([bool]$prod) 'нет ветки prod'
            if ($prod) {
                $files = Get-GhFiles -Gh $gh -Commit $prod
                foreach ($path in @('PROD.md', 'README.md', 'processings/manifest.json', 'processings/Печать/Печать/Ext/ObjectModule.bsl', 'processings/ТолькоВРабочей/ТолькоВРабочей.xml')) {
                    Check ($files.ContainsKey($path)) ("в prod нет {0}" -f $path)
                }
                Check (@($files.Keys | Where-Object { $_ -like 'extensions/*' }).Count -eq 0) 'в prod попали расширения из main'
                # Подставная 1С выгружает модуль с BOM и CRLF.
                $expected = [byte[]](@([byte]0xEF, [byte]0xBB, [byte]0xBF) + @($utf8.GetBytes($printNew.Replace("`n", "`r`n"))))
                Check ($files['processings/Печать/Печать/Ext/ObjectModule.bsl'] -eq (Get-GitBlobSha $expected)) 'в prod не та Печать, что в рабочей'
                Check ((Read-GhFakeCommit -Gh $gh -Sha $prod).Parents -contains $main) 'первый снимок prod не от main'
            }
            $comLog = Join-Path $sb 'fake\com.log'
            if (Test-Path -LiteralPath $comLog) {
                $changesInCluster = @([System.IO.File]::ReadAllLines($comLog, $utf8) | Where-Object { $_ -match 'UpdateInfoBase|TerminateSession' })
                Check ($changesInCluster.Count -eq 0) ("снимок рабочей менял кластер: " + ($changesInCluster -join ' | '))
            }
            Reset-FakeState $sb
            $same = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitProd' -Fake @{ dumps = (New-GitDumps) } -Com $com
            Check-DeployCommon $same -LocksExpected $false
            Check (@($same.Output | Where-Object { $_ -match 'записывать нечего' }).Count -eq 1) 'без изменений в рабочей не сказано «записывать нечего»'
            Check ($same.Unexpected.Count -eq 0) ("без изменений были вопросы: " + ($same.Unexpected -join ' | '))
            $prodProcs[0]['content'] = 'Процедура НоваяВРабочей() КонецПроцедуры'
            $com2 = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld)) -ProdProcessings $prodProcs
            Reset-FakeState $sb
            $next = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitProd' -Fake @{ dumps = (New-GitDumps) } -Com $com2 -Answers @(
                @{ Kind = 'confirm'; Header = 'Записать снимок обработок erp_base'; Yes = $true })
            Check-DeployCommon $next -LocksExpected $false
            $prod2 = (Get-GhHead -Gh $gh -Branch 'prod').Sha
            Check ($prod2 -and $prod2 -ne $prod -and (Read-GhFakeCommit -Gh $gh -Sha $prod2).Parents -contains $prod) 'второй снимок не лёг коммитом поверх прежнего prod'
            Check ((Get-GhHead -Gh $gh -Branch 'main').Sha -eq $main) 'второй снимок рабочей тронул main'
        }
    },
    @{
        Name = 'git-typical'
        Text = 'типовая в git (TypicalRepo, портативный git; в тесте - git из PATH и bare-репозиторий вместо GitHub): в конце «Выгрузить temp в git» - вопрос, выгрузка основной конфигурации без -Extension, коммит с README.md без ConfigDumpInfo.xml, push; та же версия - «уже в», без вопросов; новая версия - вопрос «обновилась», выгрузка с -update, коммит поверх прежнего'
        Run = {
            param($Name)
            $gitCommand = Get-Command git -ErrorAction SilentlyContinue
            if ($null -eq $gitCommand) { Write-Host '       пропущен: нет git в PATH'; return }
            $gitExe = $gitCommand.Source
            $sb = New-GitSandbox $Name -Extra @{ TypicalRepo = 'owner/typical'; TypicalKeepDump = $true; TypicalMinFreeGB = 1 }
            $bare = Join-Path $sb 'typical-remote.git'
            $null = & $gitExe init --bare --quiet $bare 2>&1
            $env:CI_FAKE_GIT_EXE = $gitExe
            $env:CI_FAKE_GIT_REMOTE = $bare
            try {
                $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
                $com.bases.erp_temp_test['config'] = @{ name = 'ERP'; synonym = 'ERP завода'; version = '2.5.22.149' }
                $dumps = New-GitDumps
                $dumps['@config'] = @{ 'Catalogs/Items.xml' = '<Items/>'; 'CommonModules/Common/Ext/Module.bsl' = 'Процедура А() КонецПроцедуры' }
                $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = $dumps } -Com $com -Answers ($gitBootstrapAnswers + @(@{ Kind = 'confirm'; Header = 'Выгрузить и типовую'; Yes = $true }))
                Check-DeployCommon $first -LocksExpected $false
                Check ($first.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($first.Unexpected -join ' | '))
                # Итог каждой долгой операции - строкой под её «начато» и событием step для колонки шагов ci.exe.
                Check (@($first.Output | Where-Object { $_ -match '^\s+готово за \d+:\d\d$' }).Count -gt 0) 'у долгих операций нет строки итога «готово за ...»'
                $stepEvents = @($first.Output | Where-Object { $_.StartsWith('@@ui:') -and $_ -match '"kind"\s*:\s*"step"' })
                Check (@($stepEvents | Where-Object { $_ -match 'git add' -and $_ -match '"status"\s*:\s*"OK"' }).Count -eq 1) ('события step с итогом git add для колонки шагов: ' + @($stepEvents | Where-Object { $_ -match 'git add' }).Count)
                # Будущие шаги видны заранее: план операций (ops) - выгрузки расширений, потом весь путь типовой.
                $opsPlans = @($first.Output | Where-Object { $_.StartsWith('@@ui:') -and $_ -match '"kind"\s*:\s*"plan"' -and $_ -match '"ops"\s*:\s*true' })
                Check (@($opsPlans | Where-Object { $_ -match 'Типовая: git push' -and $_ -match 'Типовая: git add' -and $_ -match 'Выгрузить типовую' }).Count -eq 1) ('планов операций типовой для колонки шагов: ' + @($opsPlans | Where-Object { $_ -match 'git push' }).Count)
                Check (@($opsPlans | Where-Object { $_ -match 'Выгрузить .+ из erp_temp_test' -and $_ -notmatch 'git push' }).Count -eq 1) ('планов выгрузки расширений для колонки шагов: ' + @($opsPlans | Where-Object { $_ -notmatch 'git push' }).Count)
                $tree = @(& $gitExe --git-dir=$bare ls-tree -r --name-only main 2>&1 | ForEach-Object { [string]$_ })
                foreach ($path in @('README.md', 'Configuration.xml', 'Catalogs/Items.xml', 'CommonModules/Common/Ext/Module.bsl')) { Check ($tree -contains $path) ("в репозитории типовой нет {0}: {1}" -f $path, ($tree -join ' ')) }
                Check ($tree -notcontains 'ConfigDumpInfo.xml') 'ConfigDumpInfo.xml попал в репозиторий типовой'
                $firstSha = [string](& $gitExe --git-dir=$bare rev-parse main 2>&1)
                # Объекты - в одном pack: отдельных объектов (файл на объект) после выгрузки не остаётся.
                $objectStats = @(& $gitExe ("--git-dir=" + (Join-Path $sb 'git\typical\repo.git')) count-objects -v 2>&1 | ForEach-Object { [string]$_ })
                Check (($objectStats -contains 'count: 0') -and ($objectStats -contains 'packs: 1')) ("объекты типовой не в одном pack: " + ($objectStats -join '; '))
                # Get-Calls отдаёт массив запятой: сначала в переменную, потом в конвейер (иначе в Where-Object придёт весь массив разом).
                $firstDumps = Get-Calls $first @('/DumpConfigToFiles')
                $dumpCalls = @($firstDumps | Where-Object { -not $_.Line.Contains('-Extension') })
                Check ($dumpCalls.Count -eq 1 -and -not $dumpCalls[0].Line.Contains('-update')) ("выгрузка типовой: " + (@($dumpCalls | ForEach-Object { $_.Line }) -join ' | '))
                $stateFile = Join-Path $sb 'git\typical\typical.json'
                Check ((Test-Path -LiteralPath $stateFile) -and (([System.IO.File]::ReadAllText($stateFile, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json).version -eq '2.5.22.149')) 'typical.json без версии типовой'
                Reset-FakeState $sb
                $same = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = $dumps } -Com $com
                Check-DeployCommon $same -LocksExpected $false
                Check ($same.Unexpected.Count -eq 0) ("та же версия типовой - а вопросы: " + ($same.Unexpected -join ' | '))
                Check (@($same.Output | Where-Object { $_ -match 'типовая .*уже в owner/typical' }).Count -eq 1) 'та же версия типовой: не сказано «уже в»'
                $sameDumps = Get-Calls $same @('/DumpConfigToFiles')
                Check (@($sameDumps | Where-Object { -not $_.Line.Contains('-Extension') }).Count -eq 0) 'та же версия типовой: выгружалась заново'
                $com.bases.erp_temp_test['config']['version'] = '2.5.23.10'
                $dumps['@config']['CommonModules/Common/Ext/Module.bsl'] = 'Процедура Б() КонецПроцедуры'
                Reset-FakeState $sb
                $next = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = $dumps } -Com $com -Answers @(@{ Kind = 'confirm'; Header = 'обновилась: 2\.5\.22\.149 -> 2\.5\.23\.10'; Yes = $true })
                Check-DeployCommon $next -LocksExpected $false
                Check ($next.Unexpected.Count -eq 0) ("новая версия типовой - неожиданные вопросы: " + ($next.Unexpected -join ' | '))
                $nextSha = [string](& $gitExe --git-dir=$bare rev-parse main 2>&1)
                $parent = [string](& $gitExe --git-dir=$bare rev-parse 'main~1' 2>&1)
                Check ($nextSha -ne $firstSha -and $parent -eq $firstSha) ("новая версия типовой не легла коммитом поверх прежнего: {0} -> {1}, родитель {2}" -f $firstSha, $nextSha, $parent)
                $nextDumps = Get-Calls $next @('/DumpConfigToFiles', '-update')
                $updateCalls = @($nextDumps | Where-Object { -not $_.Line.Contains('-Extension') })
                Check ($updateCalls.Count -eq 1) 'новая версия типовой выгружалась не с -update'
                $com.bases.erp_temp_test['config']['version'] = '2.5.23.11'
                $dumps['@config']['Catalogs/Items.xml'] = '<Items>'
                Reset-FakeState $sb
                $broken = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitTypical' -Fake @{ dumps = $dumps } -Com $com -Answers @(@{ Kind = 'confirm'; Header = 'обновилась'; Yes = $true })
                Check ($broken.ExitCode -ne 0) 'повреждённый XML не остановил выгрузку'
                Check (($broken.Output -join "`n") -match 'XML выгрузки типовой .*Items.xml') 'в ошибке нет пути повреждённого XML'
                $after = [string](& $gitExe --git-dir=$bare rev-parse main 2>&1)
                Check ($after -eq $nextSha) 'выгрузка с повреждённым XML попала в репозиторий'
                $saved = [System.IO.File]::ReadAllText($stateFile, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
                Check ($saved.version -eq '2.5.23.10') 'сохранена версия повреждённой выгрузки'
                Check (-not (Test-Path -LiteralPath (Join-Path $sb 'git\typical\dump\ConfigDumpInfo.xml'))) 'повреждённая выгрузка отмечена для инкрементального повтора'
            }
            finally {
                Remove-Item -Path 'env:CI_FAKE_GIT_EXE' -ErrorAction SilentlyContinue
                Remove-Item -Path 'env:CI_FAKE_GIT_REMOTE' -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = 'git-typical-resume'
        Text = 'типовая в git: отправка не прошла уже после коммита - повтор не коммитит заново (было бы «nothing to commit»), а отправляет готовый коммит'
        Run = {
            param($Name)
            $gitCommand = Get-Command git -ErrorAction SilentlyContinue
            if ($null -eq $gitCommand) { Write-Host '       пропущен: нет git в PATH'; return }
            $gitExe = $gitCommand.Source
            $sb = New-GitSandbox $Name -Extra @{ TypicalRepo = 'owner/typical'; TypicalKeepDump = $true; TypicalMinFreeGB = 1 }
            $bare = Join-Path $sb 'typical-remote.git'
            $null = & $gitExe init --bare --quiet $bare 2>&1
            # Ветку в хранилище не записать (чужой файл блокировки ссылки): отправка отклоняется - как обрыв после коммита.
            $refLock = Join-Path $bare 'refs\heads\main.lock'
            New-Item -ItemType Directory -Path (Split-Path -Parent $refLock) -Force | Out-Null
            [System.IO.File]::WriteAllText($refLock, '')
            $env:CI_FAKE_GIT_EXE = $gitExe
            $env:CI_FAKE_GIT_REMOTE = $bare
            try {
                $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
                $com.bases.erp_temp_test['config'] = @{ name = 'ERP'; synonym = 'ERP завода'; version = '2.5.22.149' }
                $dumps = New-GitDumps
                $dumps['@config'] = @{ 'Catalogs/Items.xml' = '<Items/>' }
                $typicalAnswer = @{ Kind = 'confirm'; Header = 'Выгрузить и типовую'; Yes = $true }
                $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = $dumps } -Com $com -Answers ($gitBootstrapAnswers + @($typicalAnswer))
                Check (@($first.Output | Where-Object { $_ -match '^Остановлено: git push' }).Count -eq 1) ("первая отправка должна была не пройти: " + (@($first.Output | Select-Object -Last 3) -join ' | '))
                Check ($first.ExitCode -eq 1) ("первый запуск: код возврата {0}, ждали 1" -f $first.ExitCode)
                Remove-Item -LiteralPath $refLock -Force
                Reset-FakeState $sb
                $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = $dumps } -Com $com -Answers @($typicalAnswer)
                Check-DeployCommon $r -LocksExpected $false
                Check (@($r.Output | Where-Object { $_ -match 'коммит уже сделан прошлым запуском' }).Count -eq 1) 'повтор не сказал, что коммит уже есть'
                $tree = @(& $gitExe --git-dir=$bare ls-tree -r --name-only main 2>&1 | ForEach-Object { [string]$_ })
                Check ($tree -contains 'Catalogs/Items.xml') ("после повтора типовой в хранилище нет: {0}" -f ($tree -join ', '))
                $commits = ([string](& $gitExe --git-dir=$bare rev-list --count main 2>&1)).Trim()
                Check ($commits -eq '1') ("коммитов в хранилище {0}, ждали 1" -f $commits)
                $stateFile = Join-Path $sb 'git\typical\typical.json'
                Check (Test-Path -LiteralPath $stateFile) 'после повтора нет typical.json'
            }
            finally {
                Remove-Item -Path 'env:CI_FAKE_GIT_EXE' -ErrorAction SilentlyContinue
                Remove-Item -Path 'env:CI_FAKE_GIT_REMOTE' -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = 'git-typical-noversion'
        Text = 'типовая в git: в typical.json коммит без версии (до 20.11.2026 версия читалась пустой - свойства COM 1С) - версия коммита из его Configuration.xml; та же, что в temp, - дописывается, без вопроса и без выгрузки; другая - вопрос и выгрузка'
        Run = {
            param($Name)
            $gitCommand = Get-Command git -ErrorAction SilentlyContinue
            if ($null -eq $gitCommand) { Write-Host '       пропущен: нет git в PATH'; return }
            $gitExe = $gitCommand.Source
            $sb = New-GitSandbox $Name -Extra @{ TypicalRepo = 'owner/typical'; TypicalMinFreeGB = 1 }
            $bare = Join-Path $sb 'typical-remote.git'
            $null = & $gitExe init --bare --quiet $bare 2>&1
            $env:CI_FAKE_GIT_EXE = $gitExe
            $env:CI_FAKE_GIT_REMOTE = $bare
            try {
                $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
                $com.bases.erp_temp_test['config'] = @{ name = 'ERP'; synonym = 'ERP завода'; version = '2.5.22.149' }
                $dumps = New-GitDumps
                $dumps['@config'] = @{ 'Configuration.xml' = '<MetaDataObject><Configuration><Properties><Name>ERP</Name><Version>2.5.22.149</Version></Properties></Configuration></MetaDataObject>'; 'Catalogs/Items.xml' = '<Items/>' }
                $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = $dumps } -Com $com -Answers ($gitBootstrapAnswers + @(@{ Kind = 'confirm'; Header = 'Выгрузить и типовую'; Yes = $true }))
                Check-DeployCommon $first -LocksExpected $false
                $sha = ([string](& $gitExe --git-dir=$bare rev-parse main 2>&1)).Trim()
                $stateFile = Join-Path $sb 'git\typical\typical.json'
                $blank = { [System.IO.File]::WriteAllText($stateFile, (ConvertTo-Json -InputObject ([ordered]@{ repo = 'owner/typical'; name = ''; version = ''; commit = $sha; time = '2026-11-20 02:10:00' })), $utf8) }
                # Та же версия в temp: дописать, не выгружать.
                & $blank
                Reset-FakeState $sb
                $same = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = $dumps } -Com $com
                Check-DeployCommon $same -LocksExpected $false
                Check ($same.Unexpected.Count -eq 0) ("коммит без версии, та же версия - а вопросы: " + ($same.Unexpected -join ' | '))
                Check (@($same.Output | Where-Object { $_ -match 'без версии, в нём та же версия - дописал' }).Count -eq 1) 'не сказано, что версия дописана'
                $sameDumps = Get-Calls $same @('/DumpConfigToFiles')
                Check (@($sameDumps | Where-Object { -not $_.Line.Contains('-Extension') }).Count -eq 0) 'коммит без версии, та же версия: типовая выгружалась заново'
                $state = [System.IO.File]::ReadAllText($stateFile, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
                Check ($state.version -eq '2.5.22.149' -and $state.name -eq 'ERP' -and $state.commit -eq $sha) ("typical.json после дописывания: версия «{0}», имя «{1}», коммит «{2}»" -f $state.version, $state.name, $state.commit)
                # temp обновили после того запуска: версию не приписывать, а выгрузить.
                & $blank
                $com.bases.erp_temp_test['config']['version'] = '2.5.23.10'
                $dumps['@config']['Configuration.xml'] = '<MetaDataObject><Configuration><Properties><Name>ERP</Name><Version>2.5.23.10</Version></Properties></Configuration></MetaDataObject>'
                Reset-FakeState $sb
                $next = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = $dumps } -Com $com -Answers @(@{ Kind = 'confirm'; Header = 'Выгрузить и типовую'; Yes = $true })
                Check-DeployCommon $next -LocksExpected $false
                Check ($next.Unexpected.Count -eq 0) ("коммит без версии, другая версия - неожиданные вопросы: " + ($next.Unexpected -join ' | '))
                Check (@($next.Output | Where-Object { $_ -match 'без версии; версия в нём - 2\.5\.22\.149, .* - 2\.5\.23\.10: выгружаю как новую' }).Count -eq 1) 'не сказано, что версия в коммите другая'
                $nextDumps = Get-Calls $next @('/DumpConfigToFiles')
                Check (@($nextDumps | Where-Object { -not $_.Line.Contains('-Extension') }).Count -eq 1) 'коммит без версии, другая версия: типовая не выгружалась'
                $state = [System.IO.File]::ReadAllText($stateFile, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
                Check ($state.version -eq '2.5.23.10' -and $state.commit -ne $sha) ("typical.json после выгрузки новой: версия «{0}», коммит «{1}»" -f $state.version, $state.commit)
            }
            finally {
                Remove-Item -Path 'env:CI_FAKE_GIT_EXE' -ErrorAction SilentlyContinue
                Remove-Item -Path 'env:CI_FAKE_GIT_REMOTE' -ErrorAction SilentlyContinue
            }
        }
    },
    @{
        Name = 'git-portable-download'
        Text = 'портативный git: нет tools\git - последний MinGit 64 бита (не busybox) из релизов git-for-windows, сверка sha256 с digest релиза, распаковка в tools\git; второй раз не скачивает; не та сумма - отказ, tools\git не появляется'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $http = Join-Path $sb 'http'
            New-Item -ItemType Directory -Path $http -Force | Out-Null
            $put = { param([string]$Url, $Content) $file = Join-Path $http ([regex]::Replace($Url, '[^A-Za-z0-9.\-]', '_')); if ($Content -is [byte[]]) { [System.IO.File]::WriteAllBytes($file, $Content) } else { [System.IO.File]::WriteAllText($file, [string]$Content, $utf8) } }
            $source = Join-Path $sb 'mingit-src'
            New-Item -ItemType Directory -Path (Join-Path $source 'cmd') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $source 'cmd\git.exe'), 'MZ fake git', $utf8)
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = Join-Path $sb 'mingit.zip'
            [System.IO.Compression.ZipFile]::CreateFromDirectory($source, $zip)
            $zipBytes = [System.IO.File]::ReadAllBytes($zip)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $digest = -join @($sha.ComputeHash($zipBytes) | ForEach-Object { $_.ToString('x2') })
            $release = @{ tag_name = 'v2.47.1.windows.1'; assets = @(
                    @{ name = 'MinGit-2.47.1-busybox-64-bit.zip'; url = 'https://api.github.com/repos/git-for-windows/git/releases/assets/9'; digest = ('sha256:' + ('0' * 64)) },
                    @{ name = 'MinGit-2.47.1-64-bit.zip'; url = 'https://api.github.com/repos/git-for-windows/git/releases/assets/10'; digest = ('sha256:' + $digest) }) }
            & $put 'https://api.github.com/repos/git-for-windows/git/releases/latest' (ConvertTo-Json -InputObject $release -Depth 5)
            & $put 'https://api.github.com/repos/git-for-windows/git/releases/assets/10' 'REDIRECT https://objects.example.com/mingit.zip'
            & $put 'https://objects.example.com/mingit.zip' $zipBytes
            $env:CI_FAKE_HTTP = $http
            Remove-Item -Path 'env:CI_FAKE_GIT_EXE' -ErrorAction SilentlyContinue
            try {
                $tools = Join-Path $sb 'tools-git'
                $exe = Get-PortableGit -ToolsDir $tools
                Check ($exe -eq (Join-Path $tools 'git\cmd\git.exe') -and (Test-Path -LiteralPath $exe)) ("git не распакован в tools\git: {0}" -f $exe)
                $log = [System.IO.File]::ReadAllText((Join-Path $http 'requests.log'), $utf8)
                Check ($log -match 'assets/10' -and $log -notmatch 'assets/9') 'скачан не тот файл релиза (нужен MinGit 64 бита, не busybox)'
                $before = @([System.IO.File]::ReadAllLines((Join-Path $http 'requests.log'))).Count
                $again = Get-PortableGit -ToolsDir $tools
                Check ($again -eq $exe -and @([System.IO.File]::ReadAllLines((Join-Path $http 'requests.log'))).Count -eq $before) 'второй раз git скачивался снова'
                $release.assets[1].digest = 'sha256:' + ('1' * 64)
                & $put 'https://api.github.com/repos/git-for-windows/git/releases/latest' (ConvertTo-Json -InputObject $release -Depth 5)
                $badTools = Join-Path $sb 'tools-bad'
                $failed = $false
                try { $null = Get-PortableGit -ToolsDir $badTools } catch { $failed = $_.Exception.Message -match 'контрольная сумма' }
                Check $failed 'не та контрольная сумма - а git поставлен'
                Check (-not (Test-Path -LiteralPath (Join-Path $badTools 'git'))) 'не та контрольная сумма - а tools\git появился'
            }
            finally { Remove-Item -Path 'env:CI_FAKE_HTTP' -ErrorAction SilentlyContinue }
        }
    },
    @{
        Name = 'git-import-review'
        Text = 'Ручной импорт при расхождении открывает PR и возвращается. Ночной импорт ждёт открытый PR. После ручного слияния загружается только изменившееся в main.'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name
            $gh = Get-FakeGh $sb
            $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
            $boot = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers $gitBootstrapAnswers
            Check-DeployCommon $boot -LocksExpected $false
            # Владелец принял первый снимок.
            Set-GhBranch -Gh $gh -Branch 'main' -Sha (Read-GitStateFile $sb).pendingCommit
            $head = (Get-GhHead -Gh $gh -Branch 'main').Sha
            if (-not $head) { Check $false 'в тестовом репозитории отсутствует принятый снимок'; return }
            $adaptPath = 'extensions/Адаптация/CommonModules/АГБ_Общий/Ext/Module.bsl'
            $extraPath = 'extensions/Доработки/CommonModules/Д/Ext/Module.bsl'
            $merged = New-GhCommit -Gh $gh -Parent $head -Changes @([pscustomobject]@{ Path = $extraPath; Bytes = $utf8.GetBytes('Процедура Д2() КонецПроцедуры') }) -Message 'pull request агента'
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $merged
            [System.IO.File]::WriteAllText((Join-Path $sb 'run.ps1'), $gitRunStub, $utf8Bom)
            Reset-FakeState $sb
            $dumps = New-GitDumps -Adapt 'Процедура ПравкаВTemp() КонецПроцедуры'
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = $dumps } -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'правки после прошлой загрузки'; Item = '^Выгрузить правки' })
            Check-DeployCommon $r -LocksExpected $false
            $state = Read-GitStateFile $sb
            Check ((Get-GhHead -Gh $gh -Branch 'main').Sha -eq $merged) 'ручной импорт с правками двинул main'
            Check ($state.pendingNumber -eq 2 -and $state.pendingCommit -eq $state.commit) 'нет ожидающего проверки PR'
            Check ((Get-GhHead -Gh $gh -Branch $state.pendingBranch).Sha -eq $state.commit) 'ветка снимка указывает на другой коммит'
            $files = Get-GhFiles -Gh $gh -Commit $state.commit
            $dumpPath = Join-Path (Join-Path $sb 'git\ext\work') $adaptPath
            $dumpBytes = [System.IO.File]::ReadAllBytes($dumpPath)
            $expectedText = $dumps['Адаптация']['CommonModules/АГБ_Общий/Ext/Module.bsl']
            Check ([System.IO.File]::ReadAllText($dumpPath, $utf8) -ceq $expectedText) 'выгружен другой текст модуля temp'
            Check ($files[$adaptPath] -eq (Get-GitBlobSha $dumpBytes)) 'байты модуля в PR отличаются от выгрузки temp'
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'runs'))) 'гейт начал загрузку до слияния'
            Reset-FakeState $sb
            $wait = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport -GitUnattended' -Fake @{ dumps = $dumps } -Com $com
            Check-DeployCommon $wait -LocksExpected $false
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'runs'))) 'ночной импорт не дождался слияния'
            Check ((Read-GitStateFile $sb).pendingCommit -eq $state.commit) 'ночной импорт потерял ожидающий PR'

            # Владелец слил две правки после CI. Родители коммита соответствуют двум веткам.
            $acceptedFiles = Get-GhFiles -Gh $gh -Commit $merged
            $acceptedFiles[$adaptPath] = $files[$adaptPath]
            $accepted = New-GhFakeCommit -Gh $gh -Parent ($merged + ' ' + $state.commit) -Files $acceptedFiles -Message 'Принят проверенный PR'
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $accepted
            Reset-FakeState $sb
            $load = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = $dumps } -Com $com -Answers @(
                @{ Kind = 'confirm'; Header = 'Загрузить в erp_temp_test из main'; Yes = $true })
            Check-DeployCommon $load -LocksExpected $false
            $stub = @(Get-ChildItem -LiteralPath (Join-Path $sb 'runs') -Recurse -Filter 'stub.txt' -ErrorAction SilentlyContinue)
            Check ($stub.Count -eq 1) 'после слияния ожидалась одна загрузка'
            if ($stub.Count -eq 1) {
                $text = [System.IO.File]::ReadAllText($stub[0].FullName, $utf8)
                Check ($text -match 'dir=Доработки' -and $text -notmatch 'dir=Адаптация') ('неверный состав комплекта: ' + $text)
            }
            $loaded = Read-GitStateFile $sb
            Check ($loaded.commit -eq $accepted -and -not $loaded.pendingCommit) 'после загрузки state.json не на принятом коммите'
        }
    },
    @{
        Name = 'git-nightly'
        Text = 'ночной прогон с ExtensionsRepo: сначала «Загрузить из git» без человека - main ушёл вперёд, правок temp нет - прогон гейта с ним без вопросов (-OnNotGreen Keep), он и есть ночной (второго «как есть» нет), итог в nightly\last.json; следующей ночью temp правили - ветка и pull request «выгружено ночью», main не тронут и не грузится, прогон «как есть»'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name
            $gh = Get-FakeGh $sb
            $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
            $boot = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers $gitBootstrapAnswers
            Check-DeployCommon $boot -LocksExpected $false
            # Владелец принял первый снимок.
            Set-GhBranch -Gh $gh -Branch 'main' -Sha (Read-GitStateFile $sb).pendingCommit
            $head = (Get-GhHead -Gh $gh -Branch 'main').Sha
            if (-not $head) { Check $false 'в тестовом репозитории отсутствует принятый снимок'; return }
            $merged = New-GhCommit -Gh $gh -Parent $head -Changes @([pscustomobject]@{ Path = 'extensions/Доработки/CommonModules/Д/Ext/Module.bsl'; Bytes = $utf8.GetBytes('Процедура Д2() КонецПроцедуры') }) -Message 'pull request агента'
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $merged
            [System.IO.File]::WriteAllText((Join-Path $sb 'run.ps1'), $gitRunStub, $utf8Bom)
            Reset-FakeState $sb
            $r = Invoke-Script -Sandbox $sb -Script 'nightly.ps1' -Fake @{ dumps = (New-GitDumps) } -Com $com
            Check (-not $r.TimedOut) 'ночной прогон не уложился'
            Check ($r.Unexpected.Count -eq 0) ("ночью были вопросы: " + ($r.Unexpected -join ' | '))
            $runs = @(Get-ChildItem -LiteralPath (Join-Path $sb 'runs') -Directory -ErrorAction SilentlyContinue)
            Check ($runs.Count -eq 1) ("прогонов {0}, ждали один (из git, без второго «как есть»)" -f $runs.Count)
            if ($runs.Count -ge 1) {
                $stub = [System.IO.File]::ReadAllText((Join-Path $runs[0].FullName 'stub.txt'), $utf8)
                Check ($stub -match 'dir=Доработки' -and $stub -match ('KitSource=git owner/ext@' + $merged.Substring(0, 7))) ("ночью гейт загружал не то: " + $stub)
                Check ($stub -match 'OnNotGreen=Keep' -and $stub -match 'OnSessions=Continue') ("ночной прогон из git не без вопросов: " + $stub)
            }
            $lastFile = Join-Path $sb 'nightly\last.json'
            Check (Test-Path -LiteralPath $lastFile) 'нет nightly\last.json'
            if ((Test-Path -LiteralPath $lastFile) -and $runs.Count -ge 1) {
                $last = [System.IO.File]::ReadAllText($lastFile, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
                Check ($last.runId -eq $runs[0].Name -and $last.verdict -eq 'GREEN') ("ночной итог: прогон {0}, вердикт {1}" -f $last.runId, $last.verdict)
            }
            Check ((Read-GitStateFile $sb).commit -eq $merged) 'после ночного прогона state.json не на main'
            # Следующая ночь: temp правили руками - правки веткой и pull request, main не трогается и не грузится, прогон «как есть».
            Start-Sleep -Seconds 1
            Reset-FakeState $sb
            $n2 = Invoke-Script -Sandbox $sb -Script 'nightly.ps1' -Fake @{ dumps = (New-GitDumps -Adapt 'Процедура НочнаяПравка() КонецПроцедуры' -Extra 'Процедура Д2() КонецПроцедуры') } -Com $com
            Check (-not $n2.TimedOut) 'вторая ночь не уложилась'
            Check ($n2.Unexpected.Count -eq 0) ("второй ночью были вопросы: " + ($n2.Unexpected -join ' | '))
            Check ((Get-GhHead -Gh $gh -Branch 'main').Sha -eq $merged) 'ночью main тронут'
            $pullsFile = Join-Path $sb 'fake-github\pulls.txt'
            Check ((Test-Path -LiteralPath $pullsFile) -and ([System.IO.File]::ReadAllText($pullsFile, $utf8) -match 'выгружено ночью')) 'ночные правки temp не ушли pull request'
            $runs2 = @(Get-ChildItem -LiteralPath (Join-Path $sb 'runs') -Directory | Sort-Object Name)
            Check ($runs2.Count -eq 2) ("прогонов после второй ночи {0}, ждали два" -f $runs2.Count)
            if ($runs2.Count -eq 2) {
                $stub2 = [System.IO.File]::ReadAllText((Join-Path $runs2[1].FullName 'stub.txt'), $utf8)
                Check ($stub2 -match '(?m)^Kit=\s*$' -and $stub2 -notmatch 'dir=') ("второй ночью грузился комплект, ждали «как есть»: " + $stub2)
            }
            $importFile = Join-Path $sb 'git\ext\last-import.json'
            if (Test-Path -LiteralPath $importFile) {
                $import = [System.IO.File]::ReadAllText($importFile, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
                Check ((-not $import.ran) -and [string]$import.note -match 'pull request') ("last-import.json второй ночи: " + [string]$import.note)
            }
            else { Check $false 'нет git\ext\last-import.json' }
            $nightState = Read-GitStateFile $sb
            Check ($nightState.commit -ne $merged -and $nightState.commit -eq $nightState.pendingCommit -and $nightState.pendingNumber) 'после ночной выгрузки state.json не на ветке с правками temp (pending)'
        }
    },
    @{
        Name = 'update-from-release'
        Text = 'обновление гейта из релиза GitHub: выбор новее, скачивание по переадресации (токен только в API), сумма, установщик комплекта без вопросов, ci.exe -> ci.exe.old, код 10; не та сумма - отказ'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ UpdateRepo = 'owner/repo'; GitHubTokenPassFile = 'secrets\github.txt' }
            $release = New-FakeGateRelease -Sandbox $sb -Name $Name
            $secret = $release.Secret
            $http = $release.Http
            $r = Invoke-Script -Sandbox $sb -Script 'update.ps1' -Answers @(
                @{ Kind = 'one'; Header = 'Обновление гейта из owner/repo'; Item = '^20991231\.000000 .*новее' },
                @{ Kind = 'confirm'; Header = 'Поставить 20991231\.000000\?'; Yes = $true })
            Check ($r.ExitCode -eq 10) ("код {0}, ждали 10 (поставлен): {1}" -f $r.ExitCode, (($r.Output | Select-Object -Last 5) -join ' | '))
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            $marker = Join-Path $sb 'installed-marker.txt'
            Check ((Test-Path -LiteralPath $marker) -and ([System.IO.File]::ReadAllText($marker) -match 'unattended=True')) 'установщик комплекта не запускался без вопросов'
            Check ((Test-Path -LiteralPath (Join-Path $sb 'ci.exe.old')) -and -not (Test-Path -LiteralPath (Join-Path $sb 'ci.exe'))) 'ci.exe не переименован в ci.exe.old'
            $requests = [System.IO.File]::ReadAllText((Join-Path $http 'requests.log'), $utf8)
            Check ($requests -match 'releases\?per_page=30 токен=да') 'список релизов без токена'
            Check ($requests -match 'assets/1 токен=да accept=application/octet-stream') 'файл релиза запрошен не так'
            Check ($requests -match 'objects\.example\.com/new\.zip токен=нет') 'токен ушёл на адрес переадресации'
            Check (@($r.Output | Where-Object { $_ -match [regex]::Escape($secret) }).Count -eq 0) 'токен в выводе'
            Check ([System.IO.File]::ReadAllText((Join-Path $sb 'updates\installed.txt'), $utf8) -match 'gate-20991231\.000000') 'нет записи в updates\installed.txt'
            Check (@($r.Output | Where-Object { $_ -match 'Контрольная сумма совпала' }).Count -eq 1) 'сумма не проверялась'
            # Старый релиз с неверной суммой - отказ, установщик не зовётся.
            Remove-Item -LiteralPath $marker -Force
            $bad = Invoke-Script -Sandbox $sb -Script 'update.ps1' -Arguments '-Tag gate-20000101.000000'
            Check ($bad.ExitCode -eq 1) ("не та сумма: код {0}, ждали 1" -f $bad.ExitCode)
            Check (@($bad.Output | Where-Object { $_ -match 'контрольная сумма' }).Count -gt 0) 'нет объяснения про контрольную сумму'
            Check (-not (Test-Path -LiteralPath $marker)) 'установщик запущен при неверной сумме'
        }
    },
    @{
        Name = 'menu-update-restart'
        Text = 'меню гейта: после «Обновить гейт из GitHub» - не «Вернуться в меню», а «Перезапустить ci» или «Закрыть ci»; ci.exe получает событие close (restart - по выбору), меню второй раз не открывается'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ UpdateRepo = 'owner/repo'; GitHubTokenPassFile = 'secrets\github.txt' }
            $null = New-FakeGateRelease -Sandbox $sb -Name $Name
            # События close для ci.exe из вывода скрипта.
            $getCloses = {
                param($Result)
                $found = @(foreach ($line in @($Result.Output | Where-Object { $_.StartsWith('@@ui:') })) {
                        $uiEvent = $null
                        try { $uiEvent = $line.Substring(5) | ConvertFrom-Json } catch { $uiEvent = $null }
                        if ($null -ne $uiEvent -and [string]$uiEvent.kind -eq 'close') { $uiEvent }
                    })
                return , $found
            }
            $r = Invoke-Script -Sandbox $sb -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Обновить гейт из GitHub' },
                @{ Kind = 'one'; Header = 'Обновление гейта из owner/repo'; Item = '^20991231\.000000 ' },
                @{ Kind = 'confirm'; Header = 'Поставить 20991231\.000000\?'; Yes = $true },
                @{ Kind = 'one'; Header = 'Гейт обновлён'; Item = '^Перезапустить ci' })
            Check ($r.ExitCode -eq 0) ("код {0}, ждали 0: {1}" -f $r.ExitCode, (($r.Output | Select-Object -Last 5) -join ' | '))
            Check ($r.Unexpected.Count -eq 0) ("неожиданные вопросы: " + ($r.Unexpected -join ' | '))
            Check ($r.UnusedAnswers -eq 0) ("тест ждал вопросов, а их не было: {0}" -f $r.UnusedAnswers)
            Check (@($r.Output | Where-Object { $_ -match '^Остановлено: |ParserError' }).Count -eq 0) 'скрипт упал'
            Check (Test-Path -LiteralPath (Join-Path $sb 'installed-marker.txt')) 'установщик комплекта не запускался'
            $closes = & $getCloses $r
            Check ($closes.Count -eq 1) ("событий close для ci.exe {0}, ждали 1" -f $closes.Count)
            if ($closes.Count -eq 1) { Check ([bool]$closes[0].restart) '«Перезапустить ci»: событие close без restart' }
            $menus = @($r.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('Гейт расширений') })
            Check ($menus.Count -eq 1) ("меню гейта показано {0} раз, ждали 1: после обновления оно не открывается" -f $menus.Count)
            Check (@($r.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('Вернуться в меню') }).Count -eq 0) 'после обновления предложено «Вернуться в меню»'
            # Ещё раз тот же релиз, ответ «Закрыть ci»: событие close без restart.
            $c = Invoke-Script -Sandbox $sb -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Обновить гейт из GitHub' },
                @{ Kind = 'one'; Header = 'Обновление гейта из owner/repo'; Item = '^20991231\.000000 ' },
                @{ Kind = 'confirm'; Header = 'Поставить 20991231\.000000\?'; Yes = $true },
                @{ Kind = 'one'; Header = 'Гейт обновлён'; Item = '^Закрыть ci' })
            Check ($c.ExitCode -eq 0) ("«Закрыть ci»: код {0}, ждали 0: {1}" -f $c.ExitCode, (($c.Output | Select-Object -Last 5) -join ' | '))
            Check ($c.Unexpected.Count -eq 0) ("«Закрыть ci»: неожиданные вопросы: " + ($c.Unexpected -join ' | '))
            Check ($c.UnusedAnswers -eq 0) ("«Закрыть ci»: тест ждал вопросов, а их не было: {0}" -f $c.UnusedAnswers)
            $closes = & $getCloses $c
            Check ($closes.Count -eq 1) ("«Закрыть ci»: событий close {0}, ждали 1" -f $closes.Count)
            if ($closes.Count -eq 1) { Check (-not [bool]$closes[0].restart) '«Закрыть ci»: событие close с restart' }
        }
    },
    @{
        Name = 'gate-resume-selfcheck'
        Text = 'продолжение с упавшего шага: самопроверка после загрузки упала, -Resume last - сеанс проверки базы (та же), загрузка, проверки и канарейка взяты готовыми, самопроверка заново - зелёный'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $first = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake @{ selfcheck = @(@{ }, @{ tasks = $errorTasks; fingerprint = 'после' }) }
            Check-Common $first; Check-Verdict $first 'RED' 1
            Check (@($first.Output | Where-Object { $_ -match 'Продолжить с упавшего шага' }).Count -eq 1) 'в конце красного прогона нет подсказки про продолжение'
            $firstName = Split-Path -Leaf $first.RunDir
            Reset-FakeState $sb
            $r = Invoke-Script -Sandbox $sb -Arguments '-Resume last' -Fake @{ selfcheck = @(@{ fingerprint = 'проверка' }, @{ fingerprint = 'после2' }) }
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            Check ($r.RunDir -and $r.RunDir -ne $first.RunDir) 'продолжение не завело свою папку прогона'
            Check ($null -ne $r.Verdict -and $null -ne $r.Verdict.resume -and $r.Verdict.resume.from -eq $firstName -and $r.Verdict.resume.start -eq 'selfcheck') 'в verdict.json нет resume (из какого прогона, с какого этапа)'
            Check-Step $r 'Проверка базы перед продолжением' 'OK'
            foreach ($stepName in @('Самопроверка до загрузки', 'Загрузить Адаптация', 'Проверка конфигурации', 'Канареечный вход')) {
                $step = Get-Step $r $stepName
                Check ($null -ne $step -and $step.from -eq $firstName) ("шаг «{0}» не взят готовым из прогона {1}" -f $stepName, $firstName)
            }
            $after = Get-Step $r 'Самопроверка после загрузки'
            Check ($null -ne $after -and $after.status -eq 'OK' -and -not $after.from) 'самопроверка после загрузки не выполнена заново'
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0) 'продолжение загружало комплект заново'
            Check ((Get-Calls $r @('/DumpCfg')).Count -eq 0) 'продолжение снимало резервную копию заново'
            Check ((Get-Calls $r @('/CheckConfig')).Count -eq 0) 'продолжение повторяло проверку конфигурации'
            Check ((Get-Calls $r @('canary;')).Count -eq 0) 'продолжение повторяло канареечный вход'
            Check ((Get-Calls $r @('selfcheck;', 'start=999999')).Count -eq 1) 'нет сеанса проверки базы (самопроверка без заданий)'
            if ($r.RunDir) {
                Check (Test-Path -LiteralPath (Join-Path $r.RunDir 'checkconfig_all.norm.txt')) 'файлы проверки конфигурации не скопированы в папку продолжения'
                $summaryFile = Join-Path $r.RunDir 'summary.txt'
                Check ((Test-Path -LiteralPath $summaryFile) -and ([System.IO.File]::ReadAllText($summaryFile, $utf8) -match ('Загрузить Адаптация \(из прогона {0}\)' -f $firstName))) 'в summary.txt нет пометки «из прогона»'
            }
        }
    },
    @{
        Name = 'gate-resume-base-changed'
        Text = 'продолжение: после прогона расширение в temp изменилось (другая хеш-сумма) - вопрос, «продолжить с проверок»: загрузка взята готовой, проверки, канарейка и самопроверка заново'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $first = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake @{ selfcheck = @(@{ }, @{ tasks = $errorTasks; fingerprint = 'после' }) }
            Check-Verdict $first 'RED' 1
            $firstName = Split-Path -Leaf $first.RunDir
            Reset-FakeState $sb
            $changed = @('Адаптация|1|active|hashПравка', 'Доработки|1|active|hashB')
            $r = Invoke-Script -Sandbox $sb -Arguments '-Resume last' -Fake @{ selfcheck = @(@{ ext = $changed }, @{ ext = $changed; fingerprint = 'после2' }) } -Answers @(
                @{ Kind = 'one'; Header = 'База изменилась после прогона'; Item = '^Продолжить с «Проверки конфигуратором»' })
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            $check = Get-Step $r 'Проверка базы перед продолжением'
            $checkText = 'шага нет'
            if ($null -ne $check) { $checkText = [string]$check.detail }
            Check ($null -ne $check -and $check.status -eq 'OK' -and $checkText -match 'Адаптация: изменено') ('проверка базы не показала, что изменилось: ' + $checkText)
            Check ($null -ne $r.Verdict -and $r.Verdict.resume.start -eq 'checks') 'начало не перенесено на проверки'
            $load = Get-Step $r 'Загрузить Адаптация'
            Check ($null -ne $load -and $load.from -eq $firstName) 'загрузка не взята готовой'
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0) 'продолжение загружало комплект поверх правки в temp'
            Check ((Get-Calls $r @('/CheckConfig')).Count -eq 1) 'проверка конфигурации не выполнена заново'
            Check ((Get-Calls $r @('canary;')).Count -eq 1) 'канареечный вход не выполнен заново'
        }
    },
    @{
        Name = 'gate-resume-new-file-menu'
        Text = 'продолжение из меню: обновление БД упало, комплект оставлен; в inbox исправленный файл - «Продолжить прогон», начать с «до» нельзя, грузится новый файл без новой резервной копии, «до» и прежние версии - из первого прогона'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $first = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake @{ designer = @(@{ match = @('/UpdateDBCfg', 'Адаптация'); exit = 1; log = 'Ошибка обновления: тест'; times = 1 }) }
            Check-Common $first; Check-Verdict $first 'RED' 1
            Check ($null -ne $first.Verdict -and $first.Verdict.kitDecision -eq 'kept') 'комплект первого прогона не оставлен'
            $firstName = Split-Path -Leaf $first.RunDir
            Reset-FakeState $sb
            $fixedName = 'erp_temp_Адаптация_20261118_исправлено.cfe'
            $fixed = Add-InboxFile $sb $fixedName 'fake-исправлено'
            $r = Invoke-Script -Sandbox $sb -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Продолжить прогон' },
                @{ Kind = 'one'; Header = 'с какого шага'; Item = '^Загрузка комплекта' },
                @{ Kind = 'confirm'; Header = '^Продолжить прогон\?'; Yes = $true })
            Check-Common $r; Check-Verdict $r 'GREEN' 0
            $menu = @($r.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('с какого шага') })
            Check ($menu.Count -eq 1 -and $menu[0].Contains('нельзя: в базе стоит комплект')) 'в меню продолжения начать с «до» не запрещено'
            Check ((Get-Calls $r @('/LoadCfg', $fixedName)).Count -eq 1) 'не загружен исправленный файл из inbox'
            Check ((Get-Calls $r @('/DumpCfg')).Count -eq 0) 'резервная копия снята заново, хотя в базе уже комплект'
            $before = Get-Step $r 'Самопроверка до загрузки'
            Check ($null -ne $before -and $before.from -eq $firstName) 'самопроверка до загрузки не взята из первого прогона'
            Check (-not (Test-Path -LiteralPath $fixed)) 'исправленный файл остался в inbox'
            if ($r.RunDir) {
                Check (Test-Path -LiteralPath (Join-Path $r.RunDir ('inbox\' + $fixedName))) 'исправленного файла нет в папке продолжения'
                $stateFile = Join-Path $r.RunDir 'resume.json'
                $backup = 'нет resume.json'
                if (Test-Path -LiteralPath $stateFile) {
                    $state = [System.IO.File]::ReadAllText($stateFile, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
                    $backup = [string]@($state.kit.items)[0].backup
                }
                Check ($backup -like ('*\' + $firstName + '\before\*')) ('прежняя версия - не из первого прогона: ' + $backup)
            }
        }
    },
    @{
        Name = 'gate-resume-canary-unverified'
        Text = 'продолжение после упавшей канарейки: самопроверки «после» не было - проверить базу не с чем, вопрос «не меняли?», проверки взяты готовыми, канарейка и самопроверка заново; шаг проверки базы жёлтый'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $first = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake @{ canary = @(@{ status = 'fail' }) }
            Check-Common $first; Check-Verdict $first 'RED' 1
            Check-Step $first 'Канареечный вход' 'FAIL'
            Reset-FakeState $sb
            $r = Invoke-Script -Sandbox $sb -Arguments '-Resume last -OnNotGreen Keep' -Answers @(
                @{ Kind = 'confirm'; Header = 'Проверить базу не с чем'; Yes = $true })
            Check-Common $r; Check-Verdict $r 'YELLOW' 2
            Check-Step $r 'Проверка базы перед продолжением' 'WARN'
            Check-Step $r 'Канареечный вход' 'OK'
            Check-Step $r 'Самопроверка после загрузки' 'OK'
            Check ($null -ne $r.Verdict -and $r.Verdict.resume.start -eq 'canary') 'продолжение не с канарейки'
            Check ((Get-Calls $r @('/CheckConfig')).Count -eq 0) 'проверка конфигурации повторялась'
            Check ((Get-Calls $r @('start=999999')).Count -eq 0) 'был сеанс проверки базы, хотя сравнивать не с чем'
        }
    },
    @{
        Name = 'gate-resume-refused-green'
        Text = 'после зелёного прогона продолжать нечего: -Resume last отказывается до начала прогона, новой папки нет; пункта «Продолжить прогон» в меню нет'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $first = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep'
            Check-Verdict $first 'GREEN' 0
            $r = Invoke-Script -Sandbox $sb -Arguments '-Resume last'
            Check ($r.ExitCode -eq 1) ("код {0}, ждали 1" -f $r.ExitCode)
            Check (@($r.Output | Where-Object { $_ -match 'продолжать нечего' }).Count -gt 0) 'нет объяснения, почему продолжать нельзя'
            Check ($r.RunDir -eq $first.RunDir) 'отказ завёл новую папку прогона'
            $m = Invoke-Script -Sandbox $sb -Answers @(@{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            $menus = @($m.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('Гейт расширений') })
            Check ($menus.Count -eq 1 -and -not $menus[0].Contains('Продолжить прогон')) 'в меню после зелёного прогона есть «Продолжить прогон»'
        }
    }
)

#endregion

#region Прогон тестов

# Тесты площадки (приватный репозиторий): файл подключается точкой и возвращает массив тестов; ему доступны
# песочница, запуск скрипта и проверки отсюда.
$tests = @($tests) + @(. (Join-Path $here 'deploy-contract.tests.ps1'))
# Приёмка поставок подрядчика (раздел 5.25).
$tests = @($tests) + @(. (Join-Path $here 'delivery.tests.ps1'))
if ($Extra) { $tests = @($tests) + @(. $Extra) }

$selected = @($tests | Where-Object { -not $Only -or $_.Name -like "*$Only*" })
$report.Add(('Тесты гейта без 1С, {0}, тестов {1}' -f (Get-Date -Format 'dd.MM.yyyy HH:mm'), $selected.Count))
$report.Add(('Песочницы: {0}' -f $workRoot))
$report.Add('')
$passed = 0
foreach ($test in $selected) {
    $script:Failures = New-Object System.Collections.Generic.List[string]
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ('{0} ... ' -f $test.Name) -NoNewline
    try { & $test.Run $test.Name }
    catch { $script:Failures.Add(('тест упал: {0} (строка {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)) }
    $seconds = [int]$watch.Elapsed.TotalSeconds
    if ($script:Failures.Count -eq 0) {
        $passed++
        Write-Host ('OK ({0} с)' -f $seconds) -ForegroundColor Green
        $report.Add(('[OK  ] {0} ({1} с) - {2}' -f $test.Name, $seconds, $test.Text))
    }
    else {
        Write-Host ('FAIL ({0} с)' -f $seconds) -ForegroundColor Red
        $report.Add(('[FAIL] {0} ({1} с) - {2}' -f $test.Name, $seconds, $test.Text))
        foreach ($failure in $script:Failures) {
            Write-Host ('       ' + $failure) -ForegroundColor Red
            $report.Add(('       ' + $failure))
        }
        # Хвост вывода скрипта - чтобы разобрать без песочницы.
        $output = Join-Path (Join-Path $workRoot $test.Name) 'output.txt'
        if (Test-Path -LiteralPath $output) {
            $report.Add('       --- последние строки вывода:')
            foreach ($line in @([System.IO.File]::ReadAllLines($output, $utf8) | Where-Object { -not $_.StartsWith('@@ui:{"kind":"progress') } | Select-Object -Last 25)) {
                $report.Add(('       | ' + $line))
            }
        }
    }
}
$report.Add('')
$report.Add(('Итог: прошло {0} из {1}' -f $passed, $selected.Count))
[System.IO.File]::WriteAllLines((Join-Path $here 'last-run.txt'), $report.ToArray(), $utf8Bom)
Write-Host ''
Write-Host ('Итог: прошло {0} из {1}. Отчёт: {2}' -f $passed, $selected.Count, (Join-Path $here 'last-run.txt'))
if (-not $Keep -and $passed -eq $selected.Count) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($passed -ne $selected.Count) { exit 1 }
exit 0

#endregion
