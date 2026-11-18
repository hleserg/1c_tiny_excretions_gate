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
    foreach ($script in @('run.ps1', 'ui.ps1', 'stats.ps1', 'report.ps1', 'deploy.ps1', 'settings.ps1', 'nightly.ps1', 'unittests.ps1', 'unittests-cli.ps1', 'update.ps1', 'publish.ps1', 'github.ps1')) {
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

function New-PrintProcessing {
    param([string]$Version, [string]$Content)
    return @{ objName = 'Печать'; title = 'Печать актов'; version = $Version; kind = 'Печатная форма'; content = $Content }
}

# Репозиторий расширений (раздел 5.23): подставной GitHub - папка fake-github песочницы, читается и
# заполняется теми же функциями github.ps1.
. (Join-Path $ciRoot 'github.ps1')

function New-GitSandbox {
    param([string]$Name)
    $config = $deployConfig.Clone()
    $config['ExtensionsRepo'] = 'owner/ext'
    $config['GitHubTokenPassFile'] = 'secrets\github.txt'
    $sb = New-Sandbox $Name -Config $config
    New-Item -ItemType Directory -Path (Join-Path $sb 'secrets') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $sb 'secrets\github.txt'), (ConvertFrom-SecureString -SecureString (ConvertTo-SecureString 'tok-git' -AsPlainText -Force)))
    New-Item -ItemType Directory -Path (Join-Path $sb 'fake-github') -Force | Out-Null
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
    @{ Kind = 'many'; Header = 'Какие внешние обработки'; Indexes = @(0) },
    @{ Kind = 'confirm'; Header = 'первым коммитом'; Yes = $true })

# Заглушка run.ps1 для «Загрузить из git»: записывает, с каким комплектом её позвали, и итог прогона - всё загрузилось.
$gitRunStub = @'
param([string]$Kit = '', [string]$KitSource = '', [string]$Config = '', [string]$UiChannel = '', [string]$OnNotGreen = '', [string]$OnSessions = '')
$dir = Join-Path $PSScriptRoot ('runs\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$lines = @(('Kit=' + $Kit), ('KitSource=' + $KitSource), ('OnNotGreen=' + $OnNotGreen), ('OnSessions=' + $OnSessions))
$items = @()
if ($Kit) {
    foreach ($sub in @(Get-ChildItem -LiteralPath $Kit -Directory | Sort-Object Name)) { $lines += ('dir=' + $sub.Name) }
    foreach ($file in @(Get-ChildItem -LiteralPath $Kit -Recurse -File)) { $lines += ('file=' + $file.FullName.Substring($Kit.TrimEnd('\').Length + 1).Replace('\', '/')) }
    $items = @(Get-ChildItem -LiteralPath $Kit -Directory | ForEach-Object { @{ name = $_.Name; loadTried = $true; touched = $true } })
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
        Text = 'проверка конфигурации идёт параллельно с канарейкой и самопроверкой, итог - перед вердиктом; ci.exe получает оценку, сколько осталось'
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
            Check (@($r.Output | Where-Object { $_ -match 'окно 22:00-02:00' }).Count -gt 0) 'нет объяснения про окно 22:00-02:00'
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
            Check (@($r.ComLog | Where-Object { $_ -match '^UpdateInfoBase|TerminateSession' }).Count -eq 0) 'состояние баз что-то поменяло'
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'deploy\state\deploy.json'))) 'появился deploy.json'
            $runDirs = @(Get-ChildItem -LiteralPath (Join-Path $sb 'deploy') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}$' })
            Check ($runDirs.Count -eq 0) 'показ состояния создал папку запуска обновления'
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
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState
            $com['lockedConnect'] = @('erp_base')
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-StatusOnly' -Com $com
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -ne 0) 'deploy не остановился, хотя рабочая закрыта'
            Check (@($r.Output | Where-Object { $_ -match 'блокировка начала сеансов, и код разрешения у неё не тот' }).Count -gt 0) 'нет понятной причины остановки'
            Check (@($r.Output | Where-Object { $_ -match 'ВНЕШНИЕ ОБРАБОТКИ' }).Count -eq 0) 'после закрытой рабочей deploy пошёл выгружать обработки'
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
        Text = '«Выгрузить temp в git»: первый раз - выбор расширений и обработок, первый коммит в main (без ConfigDumpInfo.xml, с .gitattributes), state.json; без правок - «выгружать нечего»; правка в temp - ветка temp/<время> и pull request, main не тронут'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name
            $gh = Get-FakeGh $sb
            $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers $gitBootstrapAnswers
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("код {0}, ждали 0: {1}" -f $r.ExitCode, (($r.Output | Select-Object -Last 3) -join ' | '))
            $head = (Get-GhHead -Gh $gh -Branch 'main').Sha
            Check ([bool]$head) 'main не создан'
            if ($head) {
                $files = Get-GhFiles -Gh $gh -Commit $head
                foreach ($path in @('README.md', '.gitattributes', 'extensions/Адаптация/Configuration.xml', 'extensions/Адаптация/CommonModules/АГБ_Общий/Ext/Module.bsl',
                        'extensions/Доработки/Configuration.xml', 'processings/Печать/Печать.xml', 'processings/Печать/Печать/Ext/ObjectModule.bsl')) {
                    Check ($files.ContainsKey($path)) ("в main нет {0}" -f $path)
                }
                Check (@($files.Keys | Where-Object { $_ -match 'ConfigDumpInfo' }).Count -eq 0) 'ConfigDumpInfo.xml попал в git'
                Check ((Read-GitStateFile $sb).commit -eq $head) 'state.json: temp не на main после первой выгрузки'
            }
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
            Check ((Test-Path -LiteralPath $pulls) -and ([System.IO.File]::ReadAllText($pulls, $utf8) -match "1`ttemp/\d{8}-\d{6}`tmain`t")) 'нет pull request из temp/<время> в main'
            $state = Read-GitStateFile $sb
            Check ([int]$state.pendingNumber -eq 1 -and $state.commit -and $state.commit -ne $head) 'state.json: нет неслитого pull request с правками temp'
            if ($state.commit -and $head) {
                $path = 'extensions/Адаптация/CommonModules/АГБ_Общий/Ext/Module.bsl'
                Check ((Get-GhFiles -Gh $gh -Commit $state.commit)[$path] -ne (Get-GhFiles -Gh $gh -Commit $head)[$path]) 'в ветке temp правки нет'
            }
        }
    },
    @{
        Name = 'git-import'
        Text = '«Загрузить из git»: temp правили после загрузки - вопрос, «Отмена» ничего не трогает; правок нет - прогон гейта только с тем, что изменилось в main (-KitSource с коммитом), после прогона state.json - на main'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name
            $gh = Get-FakeGh $sb
            $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
            $boot = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers $gitBootstrapAnswers
            Check-DeployCommon $boot -LocksExpected $false
            $head = (Get-GhHead -Gh $gh -Branch 'main').Sha
            Check ([bool]$head) 'первая выгрузка не создала main'
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
            Check (-not (Test-Path -LiteralPath (Join-Path $sb 'runs'))) 'после «Отмена» гейт запускался'
            Check ((Read-GitStateFile $sb).commit -eq $head) 'после «Отмена» state.json поменялся'
            Reset-FakeState $sb
            $load = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers @(
                @{ Kind = 'confirm'; Header = 'Загрузить в erp_temp_test из main'; Yes = $true })
            Check-DeployCommon $load -LocksExpected $false
            Check ($load.ExitCode -eq 0) ("код {0}, ждали 0: {1}" -f $load.ExitCode, (($load.Output | Select-Object -Last 3) -join ' | '))
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
        Name = 'git-import-merge'
        Text = '«Загрузить из git»: правка в temp и другая правка в main - «Слить»: правки temp веткой temp/<время>, слияние с main (в main обе), загрузка только того, чего нет в temp; конфликт (одно и то же с двух сторон) - pull request, main и temp не тронуты'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name
            $gh = Get-FakeGh $sb
            $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
            $boot = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = (New-GitDumps) } -Com $com -Answers $gitBootstrapAnswers
            Check-DeployCommon $boot -LocksExpected $false
            $head = (Get-GhHead -Gh $gh -Branch 'main').Sha
            if (-not $head) { Check $false 'первая выгрузка не создала main'; return }
            $adaptPath = 'extensions/Адаптация/CommonModules/АГБ_Общий/Ext/Module.bsl'
            $extraPath = 'extensions/Доработки/CommonModules/Д/Ext/Module.bsl'
            $merged = New-GhCommit -Gh $gh -Parent $head -Changes @([pscustomobject]@{ Path = $extraPath; Bytes = $utf8.GetBytes('Процедура Д2() КонецПроцедуры') }) -Message 'pull request агента'
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $merged
            [System.IO.File]::WriteAllText((Join-Path $sb 'run.ps1'), $gitRunStub, $utf8Bom)
            Reset-FakeState $sb
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = (New-GitDumps -Adapt 'Процедура ПравкаВTemp() КонецПроцедуры') } -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'правки после прошлой загрузки'; Item = '^Слить' },
                @{ Kind = 'confirm'; Header = 'Загрузить в erp_temp_test из main'; Yes = $true })
            Check-DeployCommon $r -LocksExpected $false
            $main = (Get-GhHead -Gh $gh -Branch 'main').Sha
            $files = Get-GhFiles -Gh $gh -Commit $main
            $before = Get-GhFiles -Gh $gh -Commit $head
            Check ($files[$adaptPath] -ne $before[$adaptPath]) 'правка temp не попала в main'
            Check ($files[$extraPath] -eq (Get-GitBlobSha ($utf8.GetBytes('Процедура Д2() КонецПроцедуры')))) 'после слияния в main нет правки агента'
            $stub = @(Get-ChildItem -LiteralPath (Join-Path $sb 'runs') -Recurse -Filter 'stub.txt' -ErrorAction SilentlyContinue)
            Check ($stub.Count -eq 1) 'после слияния гейт не запускался'
            if ($stub.Count -eq 1) {
                $text = [System.IO.File]::ReadAllText($stub[0].FullName, $utf8)
                Check ($text -match 'dir=Доработки' -and $text -notmatch 'dir=Адаптация') ("грузилось не только то, чего нет в temp: " + $text)
            }
            Check ((Read-GitStateFile $sb).commit -eq $main) 'после слияния и прогона state.json не на main'
            # Конфликт: одно и то же место правят и в temp, и в main.
            $other = New-GhCommit -Gh $gh -Parent $main -Changes @([pscustomobject]@{ Path = $adaptPath; Bytes = $utf8.GetBytes('Процедура ИзMain() КонецПроцедуры') }) -Message 'ещё pull request'
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $other
            Reset-FakeState $sb
            $c = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport' -Fake @{ dumps = (New-GitDumps -Adapt 'Процедура ДругаяПравкаВTemp() КонецПроцедуры' -Extra 'Процедура Д2() КонецПроцедуры') } -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'правки после прошлой загрузки'; Item = '^Слить' })
            Check-DeployCommon $c -LocksExpected $false
            Check ((Get-GhHead -Gh $gh -Branch 'main').Sha -eq $other) 'при конфликте main тронут'
            Check (@(Get-ChildItem -LiteralPath (Join-Path $sb 'runs') -Recurse -Filter 'stub.txt').Count -eq 1) 'при конфликте гейт запускался'
            $pulls = [System.IO.File]::ReadAllText((Join-Path $sb 'fake-github\pulls.txt'), $utf8)
            Check ($pulls -match 'конфликт') 'при конфликте нет pull request'
            Check (@($c.Output | Where-Object { $_ -match 'слить без человека нельзя' }).Count -eq 1) 'не сказано про конфликт'
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
            $head = (Get-GhHead -Gh $gh -Branch 'main').Sha
            if (-not $head) { Check $false 'первая выгрузка не создала main'; return }
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
            New-Item -ItemType Directory -Path (Join-Path $sb 'secrets') -Force | Out-Null
            $secret = 'tok-секрет-123'
            [System.IO.File]::WriteAllText((Join-Path $sb 'secrets\github.txt'), (ConvertFrom-SecureString -SecureString (ConvertTo-SecureString $secret -AsPlainText -Force)))
            [System.IO.File]::WriteAllText((Join-Path $sb 'ci.exe'), 'старый ci.exe')
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
            $http = Join-Path $sb 'fake-http'
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
