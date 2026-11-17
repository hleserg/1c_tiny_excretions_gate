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
    param([string]$Sandbox, [string]$Script = 'run.ps1', [string]$Arguments = '', [hashtable]$Fake = @{}, $Answers = @())
    $channel = Join-Path $Sandbox 'chan'
    New-Item -ItemType Directory -Path $channel -Force | Out-Null
    $scenarioFile = Join-Path $Sandbox 'fake\scenario.json'
    [System.IO.File]::WriteAllText($scenarioFile, (ConvertTo-Json -InputObject $Fake -Depth 10), $utf8)
    $callsFile = Join-Path $Sandbox 'fake\calls.log'

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
    return [pscustomobject]@{
        Sandbox = $Sandbox; ExitCode = $exitCode; TimedOut = $timedOut; Output = $lines.ToArray(); Stderr = $stderr
        Questions = $questions.ToArray(); Unexpected = $unexpected.ToArray(); UnusedAnswers = ($rules.Count - $used.Count)
        Calls = $calls; RunDir = $runDir; Verdict = $verdict; Seconds = [int]$watch.Elapsed.TotalSeconds
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
    return @($Result.Calls | Where-Object { $call = $_; @($Words | Where-Object { -not $call.Line.Contains($_) }).Count -eq 0 })
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
            $load = @(Get-Calls $r @('/LoadCfg'))
            $reg = @(Get-Calls $r @('/Cregepf'))
            Check ($load.Count -eq 1 -and $reg.Count -eq 1 -and [array]::IndexOf($r.Calls, $load[0]) -lt [array]::IndexOf($r.Calls, $reg[0])) 'обработка записана не после загрузки расширения'
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
