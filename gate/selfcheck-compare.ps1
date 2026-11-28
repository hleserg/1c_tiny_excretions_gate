#requires -Version 5.1
<#
.SYNOPSIS
    Сравнение двух замеров одной группы самопроверки (run.cmd -SelfCheckGroup): время, задания, записи, снимки.
    Только по файлам папок замеров, без 1С.

.DESCRIPTION
    .\selfcheck-compare.cmd selfcheck-runs\20261121-101500 selfcheck-runs\20261121-103000
        Сравнить замеры и записать compare.txt в папку второго. Код возврата: 0 - результаты совпали,
        2 - различаются (что именно - в compare.txt), 1 - сбой.

    Совпадением считается: одна группа, одна обработка (хеш исходников) и одна база; тот же набор выполненных
    заданий, те же записи ОШИБКА, ВНИМАНИЕ, ПРОПУСК и ОК, те же снимки, ни один замер не неполный.
    Один совпавший цвет итога совпадением не считается.

.NOTES
    Версия 00000000.000000.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$First,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$Second
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
trap {
    Write-Host ("Сбой сравнения: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($null -ne $_.InvocationInfo) { Write-Host ("  строка {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, ([string]$_.InvocationInfo.Line).Trim()) -ForegroundColor Red }
    exit 1
}

$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$Invariant = [Globalization.CultureInfo]::InvariantCulture

function Resolve-Run {
    param([string]$Path)
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $candidate = Join-Path $PSScriptRoot $Path
        if (-not (Test-Path -LiteralPath $candidate)) { $candidate = Join-Path (Join-Path $PSScriptRoot 'selfcheck-runs') $Path }
        $Path = $candidate
    }
    $Path = $Path.TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'group-run.txt'))) { throw "В папке $Path нет group-run.txt. Выбери две папки замеров одной группы из selfcheck-runs. Замер создаёт run.cmd -SelfCheckGroup." }
    return $Path
}

function Read-Lines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8) | ForEach-Object { ([string]$_).TrimStart([char]0xFEFF) } | Where-Object { $_ -ne '' })
}

function Read-Run {
    # Всё, что сравнивается, из папки замера.
    param([string]$Dir)
    $info = @{}
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Read-Lines (Join-Path $Dir 'group-run.txt'))) {
        $position = $line.IndexOf('=')
        if ($position -le 0) { continue }
        $key = $line.Substring(0, $position)
        if ($key -eq 'problem') { $problems.Add($line.Substring($position + 1)); continue }
        $info[$key] = $line.Substring($position + 1)
    }
    $records = @(Read-Lines (Join-Path $Dir 'selfcheck-group.norm.txt'))
    # Снимки: «@@snap <ключ>», строки «|...», «@@snap-end».
    $snapshots = @{}
    $snapKey = $null
    $snapLines = $null
    foreach ($line in (Read-Lines (Join-Path $Dir 'selfcheck-group.snapshots.txt'))) {
        if ($line.StartsWith('@@snap ')) { $snapKey = $line.Substring(7).Trim(); $snapLines = New-Object System.Collections.Generic.List[string]; continue }
        if ($line -eq '@@snap-end') { if ($null -ne $snapKey) { $snapshots[$snapKey] = ($snapLines.ToArray() -join "`n") }; $snapKey = $null; continue }
        if ($null -ne $snapLines -and $line.StartsWith('|')) { $snapLines.Add($line.Substring(1)) }
    }
    # Выполненные задания: ключи из заголовков частей журнала всех сеансов, без ожидания второго исполнителя.
    $tasks = @{}
    $first = $null
    $last = $null
    $groupDir = Join-Path $Dir 'selfcheck-group'
    foreach ($piece in @(Get-ChildItem -LiteralPath $groupDir -Recurse -File -Filter 'p*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^p\d{6}\.txt$' })) {
        $header = @{}
        foreach ($line in [System.IO.File]::ReadAllLines($piece.FullName, [System.Text.Encoding]::UTF8)) {
            $clean = ([string]$line).TrimStart([char]0xFEFF)
            if ($clean -eq '@@journal') { break }
            if ($clean.StartsWith('@@') -and $clean.IndexOf('=') -gt 2) { $header[$clean.Substring(2, $clean.IndexOf('=') - 2)] = $clean.Substring($clean.IndexOf('=') + 1) }
        }
        if ($header.ContainsKey('time')) {
            $time = [datetime]::ParseExact($header['time'], 'yyyy-MM-dd HH:mm:ss', $Invariant)
            if ($null -eq $first -or $time -lt $first) { $first = $time }
            if ($null -eq $last -or $time -gt $last) { $last = $time }
        }
        if (-not $header.ContainsKey('n')) { continue }
        $key = [string]$header['key']
        if ($key.StartsWith('Ожидание/') -or ($header.ContainsKey('wait') -and $header['wait'] -eq '1')) { continue }
        if (-not $tasks.ContainsKey($key)) { $tasks[$key] = 0 }
        $tasks[$key]++
    }
    $work = 0
    if ($null -ne $first -and $null -ne $last) { $work = [int]($last - $first).TotalSeconds }
    $name = Split-Path -Leaf $Dir
    $started = $null
    if ($name -match '^\d{8}-\d{6}$') { $started = [datetime]::ParseExact($name, 'yyyyMMdd-HHmmss', $Invariant) }
    return [pscustomobject]@{ Dir = $Dir; Name = $name; Started = $started; Info = $info; Problems = $problems.ToArray(); Records = $records; Snapshots = $snapshots; Tasks = $tasks; Work = $work }
}

function Get-Value {
    param($Run, [string]$Key)
    if ($Run.Info.ContainsKey($Key)) { return [string]$Run.Info[$Key] }
    return ''
}

function Compare-Multiset {
    # Строки, которых в одном наборе больше, чем в другом: OnlyA, OnlyB (с повторами).
    param([string[]]$A, [string[]]$B)
    $count = @{}
    foreach ($item in $A) { if (-not $count.ContainsKey($item)) { $count[$item] = 0 }; $count[$item]++ }
    foreach ($item in $B) { if (-not $count.ContainsKey($item)) { $count[$item] = 0 }; $count[$item]-- }
    $onlyA = New-Object System.Collections.Generic.List[string]
    $onlyB = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($count.Keys | Sort-Object)) {
        for ($i = 0; $i -lt $count[$item]; $i++) { $onlyA.Add($item) }
        for ($i = 0; $i -gt $count[$item]; $i--) { $onlyB.Add($item) }
    }
    return [pscustomobject]@{ OnlyA = $onlyA.ToArray(); OnlyB = $onlyB.ToArray() }
}

$runA = Read-Run (Resolve-Run $First)
$runB = Read-Run (Resolve-Run $Second)
$lines = New-Object System.Collections.Generic.List[string]
$differences = New-Object System.Collections.Generic.List[string]

$lines.Add(('СРАВНЕНИЕ ЗАМЕРОВ ГРУППЫ «{0}»' -f (Get-Value $runA 'group')))
foreach ($pair in @(@('A', $runA), @('B', $runB))) {
    $run = $pair[1]
    $lines.Add(('{0}: {1} - исполнителей {2}, {3} с (от первого задания до последнего {4} с), итог {5}, записей {6}: ошибок {7}, внимание {8}, пропусков {9}, ОК {10}' -f
            $pair[0], $run.Name, (Get-Value $run 'workers'), (Get-Value $run 'seconds'), $run.Work, (Get-Value $run 'state'), (Get-Value $run 'records'),
            (Get-Value $run 'errors'), (Get-Value $run 'warnings'), (Get-Value $run 'skipped'), (Get-Value $run 'ok')))
}

# Тот же ли состав: группа, база, код обработки.
foreach ($key in @('group', 'base', 'selfchecksrc')) {
    if ((Get-Value $runA $key) -ne (Get-Value $runB $key)) { $differences.Add(('разный состав: {0} - «{1}» и «{2}»' -f $key, (Get-Value $runA $key), (Get-Value $runB $key))) }
}
if ((Get-Value $runA 'gate') -ne (Get-Value $runB 'gate')) { $lines.Add(('Сборки гейта разные: {0} и {1} (код обработки сверяется по хешу исходников)' -f (Get-Value $runA 'gate'), (Get-Value $runB 'gate'))) }

# Порядок и прогрев.
if ($null -ne $runA.Started -and $null -ne $runB.Started) {
    $earlier = 'A'
    $later = 'B'
    if ($runB.Started -lt $runA.Started) { $earlier = 'B'; $later = 'A' }
    $gap = [int][Math]::Abs(($runB.Started - $runA.Started).TotalMinutes)
    $lines.Add(('Порядок: первым шёл {0}, через {1} мин - {2}. Второй запуск мог выиграть от прогрева: кэш данных СУБД и сервера 1С, скомпилированные модули. Чтобы отделить прогрев, повторить в обратном порядке.' -f $earlier, $gap, $later))
}

# Время.
$secondsA = 0.0
$secondsB = 0.0
[void][double]::TryParse((Get-Value $runA 'seconds'), [ref]$secondsA)
[void][double]::TryParse((Get-Value $runB 'seconds'), [ref]$secondsB)
if ($secondsA -gt 0 -and $secondsB -gt 0) {
    $delta = [int][Math]::Round(100 * ($secondsB - $secondsA) / $secondsA)
    $sign = ''
    if ($delta -gt 0) { $sign = '+' }
    $lines.Add(('Время группы: A {0} с, B {1} с, разница {2}{3}% (B быстрее в {4:0.00} раза)' -f [int]$secondsA, [int]$secondsB, $sign, $delta, ($secondsA / $secondsB)))
}

# Задания.
$taskKeysA = @($runA.Tasks.Keys | ForEach-Object { for ($i = 0; $i -lt $runA.Tasks[$_]; $i++) { $_ } })
$taskKeysB = @($runB.Tasks.Keys | ForEach-Object { for ($i = 0; $i -lt $runB.Tasks[$_]; $i++) { $_ } })
$taskDiff = Compare-Multiset $taskKeysA $taskKeysB
$lines.Add(('Задания: в A {0}, в B {1}; только в A {2}, только в B {3}' -f $taskKeysA.Count, $taskKeysB.Count, $taskDiff.OnlyA.Count, $taskDiff.OnlyB.Count))
foreach ($item in @($taskDiff.OnlyA | Select-Object -First 20)) { $lines.Add(('  только в A: ' + $item)) }
foreach ($item in @($taskDiff.OnlyB | Select-Object -First 20)) { $lines.Add(('  только в B: ' + $item)) }
if ($taskDiff.OnlyA.Count + $taskDiff.OnlyB.Count -gt 0) { $differences.Add(('набор выполненных заданий разный ({0} и {1})' -f $taskDiff.OnlyA.Count, $taskDiff.OnlyB.Count)) }

# Записи.
$recordDiff = Compare-Multiset @($runA.Records) @($runB.Records)
$lines.Add(('Записи: в A {0}, в B {1}; только в A {2}, только в B {3}' -f @($runA.Records).Count, @($runB.Records).Count, $recordDiff.OnlyA.Count, $recordDiff.OnlyB.Count))
foreach ($item in @($recordDiff.OnlyA | Select-Object -First 30)) { $lines.Add(('  только в A: ' + $item)) }
foreach ($item in @($recordDiff.OnlyB | Select-Object -First 30)) { $lines.Add(('  только в B: ' + $item)) }
if ($recordDiff.OnlyA.Count + $recordDiff.OnlyB.Count -gt 0) { $differences.Add(('записи разные ({0} и {1})' -f $recordDiff.OnlyA.Count, $recordDiff.OnlyB.Count)) }

# Снимки.
$snapChanged = New-Object System.Collections.Generic.List[string]
foreach ($key in @(@($runA.Snapshots.Keys) + @($runB.Snapshots.Keys) | Sort-Object -Unique)) {
    if (-not $runA.Snapshots.ContainsKey($key)) { $snapChanged.Add(('только в B: ' + $key)); continue }
    if (-not $runB.Snapshots.ContainsKey($key)) { $snapChanged.Add(('только в A: ' + $key)); continue }
    if ($runA.Snapshots[$key] -ne $runB.Snapshots[$key]) { $snapChanged.Add(('различается: ' + $key)) }
}
$lines.Add(('Снимки: в A {0}, в B {1}; различий {2}' -f $runA.Snapshots.Count, $runB.Snapshots.Count, $snapChanged.Count))
foreach ($item in @($snapChanged | Select-Object -First 20)) { $lines.Add(('  ' + $item)) }
if ($snapChanged.Count -gt 0) { $differences.Add(('снимки разные ({0})' -f $snapChanged.Count)) }

# Неполнота: исполнитель упал или завис, задания не сверились.
foreach ($pair in @(@('A', $runA), @('B', $runB))) {
    foreach ($problem in $pair[1].Problems) { $lines.Add(('Неполный {0}: {1}' -f $pair[0], $problem)) }
    if ($pair[1].Problems.Count -gt 0 -or (Get-Value $pair[1] 'state') -ne 'done') { $differences.Add(('замер {0} неполный (итог {1})' -f $pair[0], (Get-Value $pair[1] 'state'))) }
}

$lines.Add('')
if ($differences.Count -eq 0) { $lines.Add('ИТОГ: результаты совпали - те же задания, записи и снимки, оба замера полные.') }
else {
    $lines.Add('ИТОГ: результаты НЕ совпали:')
    foreach ($item in $differences) { $lines.Add(('  - ' + $item)) }
}

$outFile = Join-Path $runB.Dir 'compare.txt'
[System.IO.File]::WriteAllLines($outFile, $lines.ToArray(), $Utf8Bom)
foreach ($line in $lines) { Write-Host $line }
Write-Host ('Записано: ' + $outFile)
if ($differences.Count -gt 0) { exit 2 }
exit 0
