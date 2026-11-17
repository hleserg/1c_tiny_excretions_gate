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
Итог - в консоли и в test\last-run.txt: его и присылать.
#>
param(
    [string]$Only = '',
    [switch]$Keep,
    [int]$TimeoutSec = 300
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
    foreach ($script in @('run.ps1', 'ui.ps1', 'stats.ps1', 'report.ps1', 'deploy.ps1', 'settings.ps1')) {
        Copy-Item -LiteralPath (Join-Path $ciRoot $script) -Destination $dir
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

#endregion

#region Запуск скрипта и ответы на вопросы

function Find-Answer {
    # Ответ на вопрос скрипта: первое неиспользованное правило с тем же видом и подходящим заголовком.
    # Правило: Kind, Header (регулярное выражение), и одно из Item (номер первого пункта, подходящего
    # под выражение), Index, Indexes, Yes, Text, Cancel.
    param($Question, $Rules, $Used)
    for ($i = 0; $i -lt $Rules.Count; $i++) {
        if ($Used.Contains($i)) { continue }
        $rule = $Rules[$i]
        if ($rule.Kind -ne $Question.kind) { continue }
        if ($rule.ContainsKey('Header') -and ([string]$Question.header) -notmatch $rule.Header) { continue }
        [void]$Used.Add($i)
        $answer = @{}
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
                [pscustomobject]@{ Mode = $parts[1]; Code = [int]$parts[2]; Line = $parts[3] }
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
    @{ key = 'КомпиляцияМодулей|Общий|Адаптация_ОбщийСервер'; title = 'Компиляция Адаптация_ОбщийСервер'; step = 'КомпиляцияМодулей'; lines = @('[ОШИБКА] Адаптация_ОбщийСервер не компилируется: тест') }
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

function New-PrintProcessing {
    param([string]$Version, [string]$Content)
    return @{ objName = 'Печать'; title = 'Печать актов'; version = $Version; kind = 'Печатная форма'; content = $Content }
}

# Ответы обычного обновления: гейта нет (переспрос «хотя прогонов гейта нет»), имя рабочей базы.
$deployRiskAnswer = @{ Kind = 'confirm'; Header = 'хотя прогонов гейта нет'; Yes = $true }
$deployNameAnswer = @{ Kind = 'text'; Header = 'Это рабочая база'; Text = 'erp_base' }

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
        Name = 'gate-selfcheck-new-error-keep'
        Text = 'самопроверка после загрузки нашла новую ошибку: красный; на вопрос «оставить?» - оставить'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $fake = @{ selfcheck = @(@{ }, @{ tasks = $errorTasks; fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake -Answers @(
                @{ Kind = 'confirm'; Header = 'Оставить комплект'; Yes = $true })
            Check-Common $r; Check-Verdict $r 'RED' 1
            Check-Step $r 'Самопроверка после загрузки' 'FAIL'
            Check ($null -ne $r.Verdict -and $r.Verdict.kitDecision -eq 'kept') 'комплект не оставлен, хотя ответили «Оставить»'
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
    }
)

#endregion

#region Прогон тестов

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
