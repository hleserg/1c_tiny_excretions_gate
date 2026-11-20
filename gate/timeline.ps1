#requires -Version 5.1
<#
.SYNOPSIS
    Разбор времени прогона гейта: куда ушли минуты от старта до вердикта. Только по файлам папки прогона, без 1С.

.DESCRIPTION
    .\timeline.cmd runs\20261120-153149
        Записать timeline.txt и selfcheck-groups.txt в папку прогона и показать их.
    .\timeline.cmd
        То же для последнего прогона в runs.

    Что считается (по отметкам времени run.log, шагам verdict.json и частям журнала самопроверки):
    - путь от старта до вердикта: каждая секунда - в одну строку, по старшинству: ожидание оператора,
      конфигуратор, самопроверка, другой клиент 1С (канарейка, тесты), ожидание параллельной проверки
      конфигурации, подготовка базы (сеансы, блокировки), остальное - сам гейт;
    - параллельная проверка конфигурации: сколько шла и сколько из этого основной ход её ждал;
    - шаги прогона по порядку: начало, конец, секунд;
    - самопроверка по группам заданий (шагам обработки): сколько заданий, сколько секунд, самые долгие,
      вид заданий (формы и клиентские модули - клиент, остальное - сервер).

    Перекрывающиеся интервалы считаются один раз. Оценки помечены «≈»: так бывает, когда run.log записан гейтом,
    который ещё не писал «Вердикт:» и «ждали=» (до сборки 20261120.180000).

.NOTES
    Версия 00000000.000000.
#>
param(
    [Parameter(Position = 0)]
    [string]$RunDir = '',

    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
trap {
    Write-Host ("Сбой разбора времени: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($null -ne $_.InvocationInfo) { Write-Host ("  строка {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, ([string]$_.InvocationInfo.Line).Trim()) -ForegroundColor Red }
    break
}

$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$Invariant = [Globalization.CultureInfo]::InvariantCulture

if (-not $RunDir) {
    $runsRoot = Join-Path $PSScriptRoot 'runs'
    $last = @(Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending | Select-Object -First 1)
    if ($last.Count -eq 0) { throw "В $runsRoot нет папок прогонов." }
    $RunDir = $last[0].FullName
}
if (-not [System.IO.Path]::IsPathRooted($RunDir)) { $RunDir = Join-Path $PSScriptRoot $RunDir }
$RunDir = $RunDir.TrimEnd('\', '/')
$runLog = Join-Path $RunDir 'run.log'
if (-not (Test-Path -LiteralPath $runLog)) { throw "В папке $RunDir нет run.log: это не папка прогона гейта." }
$runName = Split-Path -Leaf $RunDir
if ($runName -notmatch '^\d{8}-\d{6}$') { throw "Имя папки $runName не похоже на прогон (ГГГГММДД-ЧЧММСС)." }
$runStartName = [datetime]::ParseExact($runName, 'yyyyMMdd-HHmmss', $Invariant)

function Format-Seconds {
    param([double]$Seconds)
    $total = [int][Math]::Round($Seconds)
    if ($total -lt 60) { return ('{0} с' -f $total) }
    $hours = [int][Math]::Floor($total / 3600)
    $minutes = [int][Math]::Floor(($total % 3600) / 60)
    $rest = $total % 60
    if ($hours -gt 0) { return ('{0}:{1:00}:{2:00}' -f $hours, $minutes, $rest) }
    return ('{0}:{1:00}' -f $minutes, $rest)
}

#region Строки run.log

# Строка «ЧЧ:ММ:СС текст» -> время и текст. Время без даты: дата - из имени папки, переход через полночь - по убыванию.
$events = New-Object System.Collections.Generic.List[object]
$dayShift = 0
$previous = $null
foreach ($line in [System.IO.File]::ReadAllLines($runLog, [System.Text.Encoding]::UTF8)) {
    if ($null -eq $line) { continue }
    $clean = $line.TrimStart([char]0xFEFF)
    $m = [regex]::Match($clean, '^(\d\d):(\d\d):(\d\d) (.*)$')
    if (-not $m.Success) { continue }
    $time = $runStartName.Date.AddDays($dayShift).AddHours([int]$m.Groups[1].Value).AddMinutes([int]$m.Groups[2].Value).AddSeconds([int]$m.Groups[3].Value)
    if ($null -ne $previous -and $time -lt $previous.AddHours(-1)) { $dayShift++; $time = $time.AddDays(1) }
    $previous = $time
    $events.Add([pscustomobject]@{ Time = $time; Text = $m.Groups[4].Value })
}
if ($events.Count -eq 0) { throw 'В run.log нет строк с отметкой времени.' }
$runStart = $events[0].Time
if ($runStartName -lt $runStart -and ($runStart - $runStartName).TotalMinutes -lt 10) { $runStart = $runStartName }

#endregion

#region Вердикт

$notes = New-Object System.Collections.Generic.List[string]
$verdictTime = $null
$verdictText = ''
foreach ($event in $events) {
    $vm = [regex]::Match($event.Text, '^Вердикт: (\S+)')
    if ($vm.Success) { $verdictTime = $event.Time; $verdictText = $vm.Groups[1].Value; break }
}
$verdictEstimated = $false
if ($null -eq $verdictTime) {
    # Гейт прежней версии не писал «Вердикт:»: последняя строка шага до решения по комплекту.
    $verdictEstimated = $true
    foreach ($event in $events) {
        if ($event.Text.StartsWith('Решение по комплекту после вердикта', [System.StringComparison]::Ordinal)) { break }
        if ($event.Text -match '^\[(OK|WARN|FAIL|SKIP)\] ') { $verdictTime = $event.Time }
    }
    if ($null -eq $verdictTime) { $verdictTime = $events[$events.Count - 1].Time }
    $notes.Add('≈ вердикт - по последнему шагу до решения по комплекту: этот гейт ещё не писал в run.log «Вердикт:».')
}

#endregion

#region Интервалы

# Kind - строка разбора (по старшинству, см. $Order), Title - что именно, Start/End.
$intervals = New-Object System.Collections.Generic.List[object]
function Add-Interval {
    param([string]$Kind, [string]$Title, [datetime]$Start, [datetime]$End, [bool]$Estimated = $false)
    if ($End -lt $Start) { $End = $Start }
    $intervals.Add([pscustomobject]@{ Kind = $Kind; Title = $Title; Start = $Start; End = $End; Estimated = $Estimated })
}

function Get-DesignerTitle {
    # Что делал конфигуратор: первая команда из известных.
    param([string]$Arguments)
    foreach ($command in @('/CheckConfig', '/CheckModules', '/CheckCanApplyConfigurationExtensions', '/UpdateDBCfg', '/LoadCfg', '/LoadConfigFromFiles',
            '/DumpConfigToFiles', '/DumpCfg', '/DeleteCfg', '/LoadExternalDataProcessorOrReportFromFiles', '/DumpExternalDataProcessorOrReportToFiles', '/ManageCfgSupport')) {
        if ($Arguments.IndexOf($command, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return ('конфигуратор ' + $command) }
    }
    return 'конфигуратор'
}

function Get-ClientTitle {
    # Что делал тонкий клиент: по первому слову параметра /C.
    param([string]$Arguments)
    $cm = [regex]::Match($Arguments, '/C"([^;"]*)')
    $mode = ''
    if ($cm.Success) { $mode = $cm.Groups[1].Value.Trim().ToLowerInvariant() }
    if ($mode -eq 'selfcheck') {
        $om = [regex]::Match($Arguments, 'out=([^;"]*)')
        $label = ''
        if ($om.Success) { $label = [regex]::Match($om.Groups[1].Value, 'selfcheck-([^\\/]+)').Groups[1].Value }
        $worker = ''
        $wm = [regex]::Match($Arguments, 'worker=(\d+)')
        if ($wm.Success) { $worker = ', исполнитель ' + $wm.Groups[1].Value }
        return ('самопроверка ' + $label + $worker).Trim()
    }
    if ($mode) { return ('клиент 1С: ' + $mode) }
    if ($Arguments -match 'RunUnitTests|yaxunit') { return 'клиент 1С: модульные тесты' }
    return 'клиент 1С'
}

$backgroundStart = $null
$backgroundTitle = ''
$openStart = $null
$openKind = ''
$openTitle = ''
$selfcheckOpen = @{}
$firstProcess = $null
$lastForegroundEnd = $runStart
$waitStart = $null
$backgroundSeconds = 0
$backgroundWaited = -1
for ($index = 0; $index -lt $events.Count; $index++) {
    $event = $events[$index]
    $text = $event.Text
    $pm = [regex]::Match($text, '^> (\S+) (.*)$')
    if ($pm.Success) {
        $exe = $pm.Groups[1].Value.ToLowerInvariant()
        $arguments = $pm.Groups[2].Value
        if ($null -eq $firstProcess) { $firstProcess = $event.Time }
        if ($arguments.EndsWith('(параллельно)')) { $backgroundStart = $event.Time; $backgroundTitle = Get-DesignerTitle $arguments; continue }
        if ($exe -like '1cv8c*') {
            $title = Get-ClientTitle $arguments
            if ($title.StartsWith('самопроверка')) { $selfcheckOpen[$title] = $event.Time; continue }
            # Клиент без строки окончания: до следующего события в журнале, которое не про него.
            if ($null -ne $openStart) { Add-Interval $openKind $openTitle $openStart $event.Time $true }
            $openStart = $event.Time; $openKind = 'client'; $openTitle = $title
            continue
        }
        if ($null -ne $openStart) { Add-Interval $openKind $openTitle $openStart $event.Time $true; $openStart = $null }
        $openStart = $event.Time; $openKind = 'designer'; $openTitle = Get-DesignerTitle $arguments
        continue
    }
    # Конец конфигуратора: «  код=N таймаут=... секунд=S» (Invoke-V8).
    $em = [regex]::Match($text, '^\s*код=\S* таймаут=\S+ секунд=(\d+)')
    if ($em.Success -and $null -ne $openStart -and $openKind -eq 'designer') {
        $seconds = [int]$em.Groups[1].Value
        $start = $event.Time.AddSeconds(-$seconds)
        if ($start -lt $openStart) { $start = $openStart }
        Add-Interval 'designer' $openTitle $start $event.Time
        $lastForegroundEnd = $event.Time
        $openStart = $null
        continue
    }
    # Сеанс самопроверки: «  самопроверка: сеанс кончился как X, секунд S, ...» (у двух исполнителей - с номером).
    $sm = [regex]::Match($text, '^\s*самопроверка(?: \(исполнитель (\d+)\))?: сеанс кончился как (\S+), секунд (\d+)')
    if ($sm.Success) {
        $seconds = [int]$sm.Groups[3].Value
        $key = $null
        foreach ($candidate in @($selfcheckOpen.Keys)) {
            if ($sm.Groups[1].Success) { if ($candidate -like ('*исполнитель ' + $sm.Groups[1].Value)) { $key = $candidate } }
            elseif ($null -eq $key -or $selfcheckOpen[$candidate] -lt $selfcheckOpen[$key]) { $key = $candidate }
        }
        $title = 'самопроверка'
        $start = $event.Time.AddSeconds(-$seconds)
        if ($null -ne $key) { $title = $key; $start = $selfcheckOpen[$key]; $selfcheckOpen.Remove($key) }
        Add-Interval 'selfcheck' $title $start $event.Time
        $lastForegroundEnd = $event.Time
        continue
    }
    # Параллельная проверка: начало ожидания и конец (ждали= - у гейта с 20261120.180000).
    if ($text -match '^\s*.+: жду её перед вердиктом') { $waitStart = $event.Time; continue }
    $bm = [regex]::Match($text, '^\s*(.+): код=\S* таймаут=\S+ секунд=(\d+)(?: ждали=(\d+))?$')
    if ($bm.Success -and $null -ne $backgroundStart) {
        $backgroundSeconds = [int]$bm.Groups[2].Value
        Add-Interval 'background' $backgroundTitle $backgroundStart $event.Time
        if ($bm.Groups[3].Success) {
            $backgroundWaited = [int]$bm.Groups[3].Value
            Add-Interval 'waitbg' ('ожидание: ' + $bm.Groups[1].Value) $event.Time.AddSeconds(-$backgroundWaited) $event.Time
        }
        else {
            # Прежний гейт: ждал от конца последнего шага на переднем плане до конца проверки.
            $from = $lastForegroundEnd
            if ($null -ne $waitStart) { $from = $waitStart }
            if ($from -lt $backgroundStart) { $from = $backgroundStart }
            $backgroundWaited = [int]($event.Time - $from).TotalSeconds
            Add-Interval 'waitbg' ('ожидание: ' + $bm.Groups[1].Value) $from $event.Time $true
            $notes.Add('≈ ожидание параллельной проверки - от конца последнего шага на переднем плане: этот гейт ещё не писал «ждали=».')
        }
        $backgroundStart = $null
        continue
    }
    # Оператор: «Вопрос оператору: ...» -> «Ответ оператора через N с» или «Вопрос снят без ответа через N с».
    $am = [regex]::Match($text, '^(?:Ответ оператора|Вопрос снят без ответа) через (\d+) с')
    if ($am.Success) {
        $seconds = [int]$am.Groups[1].Value
        Add-Interval 'operator' 'вопрос оператору' $event.Time.AddSeconds(-$seconds) $event.Time
        continue
    }
    if ($text -match '^\[(OK|WARN|FAIL|SKIP)\] ' -and $null -ne $openStart -and $openKind -eq 'client') {
        Add-Interval 'client' $openTitle $openStart $event.Time $true
        $lastForegroundEnd = $event.Time
        $openStart = $null
    }
}
if ($null -ne $openStart) { Add-Interval $openKind $openTitle $openStart $verdictTime $true }
if ($null -ne $firstProcess -and $firstProcess -gt $runStart) { Add-Interval 'prep' 'подготовка базы: сеансы, блокировки, сведения' $runStart $firstProcess }

#endregion

#region Путь до вердикта: каждая секунда - один раз

$Order = @('operator', 'designer', 'selfcheck', 'client', 'waitbg', 'prep')
$Names = @{
    operator = 'ожидание оператора'; designer = 'конфигуратор'; selfcheck = 'самопроверка'; client = 'другой клиент 1С (канарейка, тесты)'
    waitbg = 'ожидание параллельной проверки конфигурации'; prep = 'подготовка базы (сеансы, блокировки)'; gate = 'сам гейт (файлы, разбор, сравнения)'
}
$totals = @{}
foreach ($kind in @($Order + 'gate')) { $totals[$kind] = 0.0 }
$foreground = @($intervals | Where-Object { $_.Kind -ne 'background' })
$points = New-Object System.Collections.Generic.List[datetime]
$points.Add($runStart); $points.Add($verdictTime)
foreach ($item in $foreground) {
    foreach ($point in @($item.Start, $item.End)) { if ($point -gt $runStart -and $point -lt $verdictTime) { $points.Add($point) } }
}
$sorted = @($points | Sort-Object -Unique)
for ($i = 0; $i -lt $sorted.Count - 1; $i++) {
    $from = $sorted[$i]; $to = $sorted[$i + 1]
    $length = ($to - $from).TotalSeconds
    if ($length -le 0) { continue }
    $middle = $from.AddSeconds($length / 2)
    $winner = 'gate'
    foreach ($kind in $Order) {
        if (@($foreground | Where-Object { $_.Kind -eq $kind -and $_.Start -le $middle -and $_.End -ge $middle }).Count -gt 0) { $winner = $kind; break }
    }
    $totals[$winner] += $length
}
$wall = ($verdictTime - $runStart).TotalSeconds

#endregion

#region Шаги и самопроверка по группам

$stepsTimeline = New-Object System.Collections.Generic.List[string]
$verdictFile = Join-Path $RunDir 'verdict.json'
if (Test-Path -LiteralPath $verdictFile) {
    $saved = $null
    try { $saved = [System.IO.File]::ReadAllText($verdictFile, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $saved = $null }
    if ($null -ne $saved -and $null -ne $saved.PSObject.Properties['steps']) {
        foreach ($step in @($saved.steps)) {
            $name = [string]$step.name
            $seconds = [int]$step.seconds
            $end = $null
            foreach ($event in $events) {
                if ($event.Text.StartsWith(('[{0}] {1}' -f [string]$step.status, $name), [System.StringComparison]::Ordinal)) { $end = $event.Time; break }
            }
            $when = '        '
            if ($null -ne $end) { $when = ('{0:HH:mm:ss}-{1:HH:mm:ss}' -f $end.AddSeconds(-$seconds), $end) }
            $stepsTimeline.Add(('  {0}  {1,8}  [{2}] {3}' -f $when, (Format-Seconds $seconds), [string]$step.status, $name))
        }
    }
}

function Read-PieceHeader {
    # Заголовок части журнала (@@имя=значение до @@journal) и строки журнала после него.
    param([string]$Path)
    $header = @{}
    $body = New-Object System.Collections.Generic.List[string]
    $inBody = $false
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($null -eq $line) { continue }
        if ($inBody) { if ($line -eq '@@snapshots') { break }; $body.Add($line); continue }
        $clean = $line.TrimStart([char]0xFEFF)
        if ($clean -eq '@@journal') { $inBody = $true; continue }
        if ($clean.StartsWith('@@')) {
            $position = $clean.IndexOf('=')
            if ($position -gt 2 -and -not $header.ContainsKey($clean.Substring(2, $position - 2))) { $header[$clean.Substring(2, $position - 2)] = $clean.Substring($position + 1) }
        }
    }
    return [pscustomobject]@{ Header = $header; Body = $body.ToArray() }
}

function Get-TaskKind {
    param([string]$Key)
    if ($Key.StartsWith('Форма/')) { return 'клиент: форма' }
    if ($Key.StartsWith('КлиентскийМодуль/')) { return 'клиент: модуль' }
    if ($Key.StartsWith('Запись/')) { return 'запись журнала' }
    return 'сервер'
}

$groupLines = New-Object System.Collections.Generic.List[string]
$groupTable = New-Object System.Collections.Generic.List[string]
$groupTable.Add("label`tgroup`tkind`ttasks`tseconds`tstepms`tslowest")
foreach ($labelDir in @(Get-ChildItem -LiteralPath $RunDir -Directory -Filter 'selfcheck-*' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $label = $labelDir.Name.Substring(10)
    $groups = [ordered]@{}
    $stepMs = @{}
    $sessionDirs = @(Get-ChildItem -LiteralPath $labelDir.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(try|w\d+-try)\d+$' } | Sort-Object Name)
    foreach ($sessionDir in $sessionDirs) {
        $pieces = @(Get-ChildItem -LiteralPath $sessionDir.FullName -Filter 'p*.txt' -File | Where-Object { $_.Name -match '^p\d{6}\.txt$' } | Sort-Object Name)
        $parsed = @($pieces | ForEach-Object { Read-PieceHeader $_.FullName })
        $resultFile = Join-Path $sessionDir.FullName 'result.txt'
        $sessionEnd = $null
        if (Test-Path -LiteralPath $resultFile) { $sessionEnd = (Get-Item -LiteralPath $resultFile).LastWriteTime }
        $currentStep = ''
        for ($p = 0; $p -lt $parsed.Count; $p++) {
            # Шаги обработки и их «--- шаг занял N мс» - в строках журнала (относятся к заданию прошлой части).
            foreach ($bodyLine in $parsed[$p].Body) {
                $hm = [regex]::Match($bodyLine, '^=== (.+) ===$')
                if ($hm.Success) { $currentStep = $hm.Groups[1].Value; continue }
                $tm = [regex]::Match($bodyLine, '^--- шаг занял (\d+) мс')
                if ($tm.Success -and $currentStep) {
                    if (-not $stepMs.ContainsKey($currentStep)) { $stepMs[$currentStep] = 0 }
                    $stepMs[$currentStep] += [int]$tm.Groups[1].Value
                }
            }
            $header = $parsed[$p].Header
            if (-not $header.ContainsKey('n') -or -not $header.ContainsKey('time')) { continue }
            $begin = [datetime]::ParseExact($header['time'], 'yyyy-MM-dd HH:mm:ss', $Invariant)
            $finish = $null
            for ($q = $p + 1; $q -lt $parsed.Count; $q++) {
                if ($parsed[$q].Header.ContainsKey('time')) { $finish = [datetime]::ParseExact($parsed[$q].Header['time'], 'yyyy-MM-dd HH:mm:ss', $Invariant); break }
            }
            if ($null -eq $finish) { $finish = $sessionEnd }
            $key = [string]$header['key']
            $group = [string]$header['step']
            if (-not $group) { $group = $key.Split('/')[0] }
            if (-not $groups.Contains($group)) { $groups[$group] = [pscustomobject]@{ Tasks = 0; Seconds = 0.0; Kinds = @{}; Slowest = New-Object System.Collections.Generic.List[object]; Unfinished = 0 } }
            $entry = $groups[$group]
            $entry.Tasks++
            $entry.Kinds[(Get-TaskKind $key)] = $true
            if ($null -eq $finish) { $entry.Unfinished++; continue }
            $seconds = ($finish - $begin).TotalSeconds
            $entry.Seconds += $seconds
            $entry.Slowest.Add([pscustomobject]@{ Key = $key; Seconds = $seconds })
        }
    }
    if ($groups.Count -eq 0) { continue }
    $sum = 0.0
    foreach ($name in @($groups.Keys)) { $sum += $groups[$name].Seconds }
    $groupLines.Add(('Самопроверка {0}: по частям журнала {1}, сеансов {2}' -f $label, (Format-Seconds $sum), $sessionDirs.Count))
    $groupLines.Add(('  {0,8} {1,6} {2,6}  {3,-28} {4}' -f 'время', 'доля', 'заданий', 'вид', 'группа (шаг обработки); самые долгие задания'))
    foreach ($name in @($groups.Keys | Sort-Object { $groups[$_].Seconds } -Descending)) {
        $entry = $groups[$name]
        $share = 0
        if ($sum -gt 0) { $share = [int][Math]::Round(100 * $entry.Seconds / $sum) }
        $kinds = (@($entry.Kinds.Keys | Sort-Object) -join ', ')
        $slow = @($entry.Slowest | Sort-Object Seconds -Descending | Select-Object -First 3 | ForEach-Object { '{0} {1}' -f (Format-Seconds $_.Seconds), $_.Key })
        $unfinished = ''
        if ($entry.Unfinished -gt 0) { $unfinished = (' (не закончено: {0})' -f $entry.Unfinished) }
        $groupLines.Add(('  {0,8} {1,5}% {2,6}  {3,-28} {4}{5}' -f (Format-Seconds $entry.Seconds), $share, $entry.Tasks, $kinds, $name, $unfinished))
        if ($slow.Count -gt 0) { $groupLines.Add(('  {0,8} {1,6} {2,6}  {3,-28}   {4}' -f '', '', '', '', ($slow -join ' | '))) }
        $ms = 0
        if ($stepMs.ContainsKey($name)) { $ms = $stepMs[$name] }
        $groupTable.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $label, $name, $kinds, $entry.Tasks, [int][Math]::Round($entry.Seconds), $ms, ($slow -join ' | ')))
    }
    if ($stepMs.Count -gt 0) {
        $groupLines.Add('  по замеру обработки («--- шаг занял»):')
        foreach ($name in @($stepMs.Keys | Sort-Object { $stepMs[$_] } -Descending | Select-Object -First 12)) {
            $groupLines.Add(('  {0,8}  {1}' -f (Format-Seconds ($stepMs[$name] / 1000)), $name))
        }
    }
    $groupLines.Add('')
}

#endregion

#region Итог

$lines = New-Object System.Collections.Generic.List[string]
$verdictMark = ''
if ($verdictEstimated) { $verdictMark = '≈' }
$lines.Add(('РАЗБОР ВРЕМЕНИ ПРОГОНА {0}' -f $runName))
$lines.Add(('Старт {0:dd.MM HH:mm:ss}, вердикт {1}{2:dd.MM HH:mm:ss} {3}: {4}' -f $runStart, $verdictMark, $verdictTime, $verdictText, (Format-Seconds $wall)))
$lines.Add('')
$lines.Add('Путь от старта до вердикта (каждая секунда - один раз, по старшинству строк):')
foreach ($kind in @($Order + 'gate')) {
    if ($totals[$kind] -le 0) { continue }
    $share = [int][Math]::Round(100 * $totals[$kind] / [Math]::Max(1, $wall))
    $lines.Add(('  {0,8} {1,4}%  {2}' -f (Format-Seconds $totals[$kind]), $share, $Names[$kind]))
}
if ($backgroundSeconds -gt 0) {
    $hidden = [Math]::Max(0, $backgroundSeconds - [Math]::Max(0, $backgroundWaited))
    $lines.Add('')
    $lines.Add(('Параллельная проверка конфигурации: шла {0}, из них основной ход ждал её {1}, спрятано за другими шагами {2}' -f (Format-Seconds $backgroundSeconds), (Format-Seconds ([Math]::Max(0, $backgroundWaited))), (Format-Seconds $hidden)))
}
$lines.Add('')
$lines.Add('Что именно (интервалы на переднем плане):')
$byTitle = @{}
foreach ($item in $foreground) {
    if (-not $byTitle.ContainsKey($item.Title)) { $byTitle[$item.Title] = [pscustomobject]@{ Title = $item.Title; Seconds = 0.0; Count = 0; Estimated = $false } }
    $byTitle[$item.Title].Seconds += ($item.End - $item.Start).TotalSeconds
    $byTitle[$item.Title].Count++
    if ($item.Estimated) { $byTitle[$item.Title].Estimated = $true }
}
foreach ($row in @($byTitle.Values | Sort-Object Seconds -Descending)) {
    $mark = ''
    if ($row.Estimated) { $mark = '≈' }
    $lines.Add(('  {0,8}  {1}{2} ({3} раз)' -f (Format-Seconds $row.Seconds), $mark, $row.Title, $row.Count))
}
if ($stepsTimeline.Count -gt 0) {
    $lines.Add('')
    $lines.Add('Шаги прогона (verdict.json; время конца - по run.log):')
    foreach ($line in $stepsTimeline) { $lines.Add($line) }
}
if ($groupLines.Count -gt 0) {
    $lines.Add('')
    foreach ($line in $groupLines) { $lines.Add($line) }
}
if ($notes.Count -gt 0) {
    $lines.Add('')
    foreach ($note in @($notes | Select-Object -Unique)) { $lines.Add($note) }
}

[System.IO.File]::WriteAllLines((Join-Path $RunDir 'timeline.txt'), $lines.ToArray(), $Utf8Bom)
[System.IO.File]::WriteAllLines((Join-Path $RunDir 'selfcheck-groups.txt'), $groupTable.ToArray(), $Utf8Bom)
if (-not $Quiet) { foreach ($line in $lines) { Write-Host $line } }
exit 0

#endregion
