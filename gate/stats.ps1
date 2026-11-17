#requires -Version 5.1
# Версия 00000000.000000.
# Статистика длительностей шагов: план и факт. Общая для run.ps1 (гейт) и deploy.ps1 (обновление рабочей).
# Подключается точкой (. stats.ps1) в том же scope, что скрипт, поэтому имена переменных - только $script:Stat*.
#
# Журнал - stats\durations.csv (UTF-8, разделитель «;»), строка на каждый шаг с заголовком:
#   time; source (gate/deploy); base; run; kind; ext; title; plan; fact; status; size; hour; platform
# kind - вид шага (load, updatedb, save, checkconfig, ...), ext - расширение, size - размер того, что
# грузится, КБ (у самопроверки - число заданий), plan - сколько шаг должен был идти по прогнозу, fact - сколько шёл.
#
# Прогноз (план) шага - по записям того же вида, того же расширения и той же базы за StatsDays дней,
# не больше 30 последних, только успешные:
#   1. зависимость от размера: если размеры заметно разные (в 1.3 раза и больше) и записей не меньше четырёх -
#      прямая «время = a + b * размер» (наименьшие квадраты), иначе медиана «секунд на КБ» или медиана времени;
#   2. время суток: днём (8-20 ч) сервер занят пользователями. Если и днём, и ночью есть по три записи и больше,
#      прогноз умножается на поправку своей половины суток (медиана отклонений от прямой);
#   3. калибровка: медиана отклонений последних пяти записей от прямой. Так прогноз догоняет медленный рост
#      базы или смену сервера, не дожидаясь, пока старые записи выпадут из окна.
# Поправки ограничены (0.6-1.6 и 0.7-1.5), чтобы один странный прогон не ломал прогноз.
# Смена версии платформы - отдельная история: если записей на текущей версии не меньше трёх, берутся только они.

$script:StatFile = ''
$script:StatSource = ''
$script:StatBase = ''
$script:StatRun = ''
$script:StatDays = 120
$script:StatPlatform = ''
$script:StatSizes = @{}
$script:StatPlans = @{}
$script:StatRows = $null
$script:StatThisRun = New-Object System.Collections.Generic.List[object]

function Initialize-Stats {
    param([string]$Dir, [string]$Source, [string]$Base, [string]$Run, [int]$Days = 120, [string]$Platform = '')
    $script:StatSource = $Source
    $script:StatBase = $Base
    $script:StatRun = $Run
    $script:StatDays = [Math]::Max(7, $Days)
    $script:StatPlatform = $Platform
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        $script:StatFile = Join-Path $Dir 'durations.csv'
    }
    catch { $script:StatFile = '' }
}

function Set-StatRun {
    # Номер прогона для журнала: известен после Initialize-Stats.
    param([string]$Run)
    $script:StatRun = $Run
}

function Get-StatKind {
    # Вид шага и расширение - по заголовку шага (заголовки одинаковые в гейте и обновлении рабочей).
    param([string]$Title)
    $rules = @(
        @('^Сохранить текущее (.+)$', 'save'),
        @('^Резервная копия (.+)$', 'backup'),
        @('^Взять (.+?) из .+$', 'take'),
        @('^Загрузить (.+?) в .+$', 'load'),
        @('^Загрузить (.+)$', 'load'),
        @('^Обновить конфигурацию БД (.+)$', 'updatedb'),
        @('^Синтаксис-контроль \((.+)\)$', 'checkmodules'),
        @('^Проверка конфигурации \((.+)\)$', 'checkconfig'),
        @('^Проверка применимости', 'checkcanapply'),
        @('^Канареечный вход', 'canary'),
        @('^Самопроверка на чтение', 'selfcheck-read'),
        @('^Самопроверка', 'selfcheck'),
        @('^Статья в базу знаний', 'kbarticle'),
        @('^Откат', 'rollback'),
        @('^Собрать (.+) из файлов$', 'buildepf'),
        @('^Записать в справочник (.+)$', 'regepf'),
        @('^Вернуть в справочник прежнюю (.+)$', 'regepf'),
        @('^Снять из справочника (.+)$', 'unregepf'),
        @('^Прочитать расширения (.+)$', 'comread'),
        @('^Выгрузить (.+)$', 'dump')
    )
    foreach ($rule in $rules) {
        $found = [regex]::Match($Title, $rule[0])
        if ($found.Success) {
            $ext = ''
            if ($found.Groups.Count -gt 1) { $ext = $found.Groups[1].Value.Trim() }
            return [pscustomobject]@{ Kind = $rule[1]; Ext = $ext }
        }
    }
    return [pscustomobject]@{ Kind = 'other'; Ext = '' }
}

function Set-StatSize {
    # Размер того, что грузится, КБ: файл .cfe или папка выгрузки в файлы.
    param([string]$Ext, [string]$Path)
    if ([string]::IsNullOrEmpty($Ext) -or [string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    try {
        $item = Get-Item -LiteralPath $Path
        $bytes = 0
        if ($item.PSIsContainer) {
            foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)) { $bytes += $file.Length }
        }
        else { $bytes = $item.Length }
        if ($bytes -gt 0) { $script:StatSizes[$Ext] = [int][Math]::Ceiling($bytes / 1024) }
    }
    catch { }
}

function Read-StatRows {
    if ($null -ne $script:StatRows) { return $script:StatRows }
    $script:StatRows = @()
    if ([string]::IsNullOrEmpty($script:StatFile) -or -not (Test-Path -LiteralPath $script:StatFile)) { return $script:StatRows }
    try {
        $since = (Get-Date).AddDays(-$script:StatDays)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($row in @(Import-Csv -LiteralPath $script:StatFile -Delimiter ';' -Encoding UTF8)) {
            $when = [datetime]::MinValue
            if (-not [datetime]::TryParseExact([string]$row.time, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when)) { continue }
            if ($when -lt $since) { continue }
            $rows.Add([pscustomobject]@{
                    Time = $when; Source = [string]$row.source; Base = [string]$row.base; Run = [string]$row.run
                    Kind = [string]$row.kind; Ext = [string]$row.ext; Title = [string]$row.title
                    Plan = (ConvertTo-StatNumber $row.plan); Fact = (ConvertTo-StatNumber $row.fact)
                    Status = [string]$row.status; Size = (ConvertTo-StatNumber $row.size)
                    Hour = [int](ConvertTo-StatNumber $row.hour); Platform = [string]$row.platform
                })
        }
        $script:StatRows = @($rows | Sort-Object Time)
    }
    catch { $script:StatRows = @() }
    return $script:StatRows
}

function ConvertTo-StatNumber {
    param($Value)
    $number = 0.0
    if ([double]::TryParse(([string]$Value).Replace(',', '.'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $number }
    return 0.0
}

function Get-StatMedian {
    param([double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return 0.0 }
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Test-StatDayHour {
    param([int]$Hour)
    return ($Hour -ge 8 -and $Hour -lt 20)
}

function Get-StatSamples {
    # Записи для прогноза: вид, расширение, база, успешные, не больше 30 последних; версия платформы - если хватает.
    param([string]$Kind, [string]$Ext)
    # Проверки конфигуратором, нашедшие ошибки, кончаются с кодом не 0, но идут столько же: их время годится.
    $rows = @(Read-StatRows | Where-Object { $_.Kind -eq $Kind -and $_.Ext -eq $Ext -and $_.Base -eq $script:StatBase -and $_.Fact -gt 0 -and
            ($_.Status -eq 'OK' -or ($_.Status -eq 'FAIL' -and $_.Kind -like 'check*')) })
    if ($script:StatPlatform) {
        $samePlatform = @($rows | Where-Object { $_.Platform -eq $script:StatPlatform })
        if ($samePlatform.Count -ge 3) { $rows = $samePlatform }
    }
    if ($rows.Count -gt 30) { $rows = @($rows | Select-Object -Last 30) }
    return $rows
}

function Get-StatModel {
    # Модель «время от размера» по записям. Возвращает функцию (scriptblock) и её описание.
    param([object[]]$Samples)
    $sized = @($Samples | Where-Object { $_.Size -gt 0 })
    if ($sized.Count -ge 4) {
        $sizes = @($sized | ForEach-Object { [double]$_.Size })
        $min = ($sizes | Measure-Object -Minimum).Minimum
        $max = ($sizes | Measure-Object -Maximum).Maximum
        if ($min -gt 0 -and $max / $min -ge 1.3) {
            $n = $sized.Count
            $meanX = ($sizes | Measure-Object -Average).Average
            $meanY = (@($sized | ForEach-Object { [double]$_.Fact }) | Measure-Object -Average).Average
            $sxy = 0.0; $sxx = 0.0
            foreach ($row in $sized) { $sxy += ($row.Size - $meanX) * ($row.Fact - $meanY); $sxx += ($row.Size - $meanX) * ($row.Size - $meanX) }
            if ($sxx -gt 0) {
                $slope = $sxy / $sxx
                $intercept = $meanY - $slope * $meanX
                if ($slope -gt 0 -and $intercept -ge 0) {
                    $a = $intercept; $b = $slope
                    return [pscustomobject]@{ Text = ("{0:0} с + {1:0.###} с/КБ, по {2} записям" -f $a, $b, $n); Fn = { param($s) $a + $b * $s }.GetNewClosure() }
                }
            }
        }
    }
    if ($sized.Count -ge 2) {
        $rate = Get-StatMedian @($sized | ForEach-Object { $_.Fact / $_.Size })
        return [pscustomobject]@{ Text = ("{0:0.###} с/КБ, по {1} записям" -f $rate, $sized.Count); Fn = { param($s) if ($s -gt 0) { $rate * $s } else { 0 } }.GetNewClosure() }
    }
    $median = Get-StatMedian @($Samples | ForEach-Object { [double]$_.Fact })
    return [pscustomobject]@{ Text = ("медиана {0:0} с, по {1} записям" -f $median, $Samples.Count); Fn = { param($s) $median }.GetNewClosure() }
}

function Get-StatForecast {
    # Прогноз шага с поправками. Seconds = 0 - прогноза нет.
    param([string]$Kind, [string]$Ext, [double]$Size = 0, [int]$Hour = -1)
    $samples = @(Get-StatSamples -Kind $Kind -Ext $Ext)
    if ($samples.Count -eq 0) { return [pscustomobject]@{ Seconds = 0; Text = 'записей нет'; Size = $Size } }
    if ($Size -le 0) {
        $lastSized = @($samples | Where-Object { $_.Size -gt 0 } | Select-Object -Last 1)
        if ($lastSized.Count -gt 0) { $Size = $lastSized[0].Size }
    }
    if ($Hour -lt 0) { $Hour = (Get-Date).Hour }
    $model = Get-StatModel $samples
    $estimate = [double](& $model.Fn $Size)
    if ($estimate -le 0) { $estimate = Get-StatMedian @($samples | ForEach-Object { [double]$_.Fact }) }
    $text = $model.Text

    # Отклонения записей от модели: из них поправка на время суток и калибровка.
    $residuals = @()
    foreach ($row in $samples) {
        $fitted = [double](& $model.Fn $row.Size)
        if ($fitted -le 0) { continue }
        $residuals += [pscustomobject]@{ Ratio = $row.Fact / $fitted; Day = (Test-StatDayHour $row.Hour) }
    }
    $isDay = Test-StatDayHour $Hour
    $mine = @($residuals | Where-Object { $_.Day -eq $isDay })
    $other = @($residuals | Where-Object { $_.Day -ne $isDay })
    if ($mine.Count -ge 3 -and $other.Count -ge 3) {
        $all = Get-StatMedian @($residuals | ForEach-Object { $_.Ratio })
        if ($all -gt 0) {
            $factor = [Math]::Min(1.6, [Math]::Max(0.6, (Get-StatMedian @($mine | ForEach-Object { $_.Ratio })) / $all))
            $estimate = $estimate * $factor
            if ([Math]::Abs($factor - 1) -ge 0.05) {
                $band = 'ночью'
                if ($isDay) { $band = 'днём' }
                $text += ("; {0} x{1:0.00}" -f $band, $factor)
            }
        }
    }
    if ($residuals.Count -ge 5) {
        $recent = Get-StatMedian @($residuals | Select-Object -Last 5 | ForEach-Object { $_.Ratio })
        $calibration = [Math]::Min(1.5, [Math]::Max(0.7, $recent))
        $estimate = $estimate * $calibration
        if ([Math]::Abs($calibration - 1) -ge 0.05) { $text += ("; калибровка по последним x{0:0.00}" -f $calibration) }
    }
    return [pscustomobject]@{ Seconds = [Math]::Round($estimate); Text = $text; Size = $Size }
}

function Get-StatPlan {
    # План шага по заголовку, секунд; 0 - прогноза нет. Первый прогноз шага запоминается: он и пишется
    # в журнал как план, даже если строку хода спросят ещё сто раз.
    param([string]$Title, [double]$Size = 0)
    if ([string]::IsNullOrEmpty($Title)) { return 0 }
    if ($script:StatPlans.ContainsKey($Title)) { return [double]$script:StatPlans[$Title] }
    $plan = 0.0
    try {
        $kind = Get-StatKind $Title
        if ($Size -le 0 -and $kind.Ext -and $script:StatSizes.ContainsKey($kind.Ext)) { $Size = [double]$script:StatSizes[$kind.Ext] }
        $plan = [double](Get-StatForecast -Kind $kind.Kind -Ext $kind.Ext -Size $Size).Seconds
    }
    catch { $plan = 0.0 }
    $script:StatPlans[$Title] = $plan
    return $plan
}

function Add-StatFact {
    # Факт шага в журнал. Status: OK, FAIL, TIMEOUT. Size - если известен только после шага (самопроверка).
    param([string]$Title, [double]$Seconds, [string]$Status = 'OK', [double]$Size = 0)
    if ([string]::IsNullOrEmpty($Title) -or [string]::IsNullOrEmpty($script:StatFile)) { return }
    try {
        $kind = Get-StatKind $Title
        if ($Size -le 0 -and $kind.Ext -and $script:StatSizes.ContainsKey($kind.Ext)) { $Size = [double]$script:StatSizes[$kind.Ext] }
        $plan = 0.0
        if ($script:StatPlans.ContainsKey($Title)) { $plan = [double]$script:StatPlans[$Title] }
        $now = Get-Date
        $invariant = [Globalization.CultureInfo]::InvariantCulture
        $fields = @($now.ToString('yyyy-MM-dd HH:mm:ss', $invariant), $script:StatSource, $script:StatBase, $script:StatRun,
            $kind.Kind, $kind.Ext, $Title, $plan.ToString('0', $invariant), $Seconds.ToString('0', $invariant), $Status,
            $Size.ToString('0', $invariant), [string]$now.Hour, $script:StatPlatform)
        $line = (@($fields | ForEach-Object { ([string]$_) -replace '[;\r\n]', ' ' }) -join ';')
        if (-not (Test-Path -LiteralPath $script:StatFile)) {
            $header = 'time;source;base;run;kind;ext;title;plan;fact;status;size;hour;platform'
            [System.IO.File]::WriteAllText($script:StatFile, $header + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
        }
        [System.IO.File]::AppendAllText($script:StatFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $script:StatThisRun.Add([pscustomobject]@{ Title = $Title; Plan = $plan; Fact = $Seconds; Status = $Status })
        $script:StatRows = $null
    }
    catch { }
}

function Format-StatSeconds {
    param([double]$Seconds)
    $total = [int][Math]::Round([Math]::Max(0, $Seconds))
    if ($total -ge 3600) { return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($total / 3600), [int][Math]::Floor(($total % 3600) / 60), ($total % 60)) }
    return ('{0}:{1:00}' -f [int][Math]::Floor($total / 60), ($total % 60))
}

function Get-StatRunLines {
    # План и факт шагов этого прогона - для итога в конце.
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($row in $script:StatThisRun) {
        $planText = 'плана не было'
        if ($row.Plan -gt 0) {
            $delta = [int][Math]::Round(100 * ($row.Fact - $row.Plan) / $row.Plan)
            $sign = ''
            if ($delta -gt 0) { $sign = '+' }
            $planText = "план {0}, {1}{2}%" -f (Format-StatSeconds $row.Plan), $sign, $delta
        }
        $lines.Add(("  {0,-8} {1}: {2}" -f (Format-StatSeconds $row.Fact), $row.Title, $planText))
    }
    return $lines.ToArray()
}

function Get-StatReportLines {
    # Экран «Статистика длительностей»: по виду шага и расширению - записи, медиана, прогноз и его точность.
    $rows = @(Read-StatRows | Where-Object { $_.Base -eq $script:StatBase })
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("База {0}, записи за {1} дней, файл {2}" -f $script:StatBase, $script:StatDays, $script:StatFile))
    if ($rows.Count -eq 0) {
        $lines.Add('Записей пока нет: они появятся после первого прогона с этой версией гейта.')
        return $lines.ToArray()
    }
    $lines.Add('Точность - медиана отклонения факта от плана по последним 10 шагам, где план был.')
    $lines.Add('')
    $lines.Add(('{0,-14} {1,-22} {2,4} {3,8} {4,8} {5,9}  {6}' -f 'вид', 'расширение', 'раз', 'медиана', 'прогноз', 'точность', 'как считается'))
    foreach ($group in @($rows | Group-Object { $_.Kind + '|' + $_.Ext } | Sort-Object Name)) {
        $first = $group.Group[0]
        $ok = @($group.Group | Where-Object { $_.Status -eq 'OK' -and $_.Fact -gt 0 })
        $median = Get-StatMedian @($ok | ForEach-Object { [double]$_.Fact })
        $forecast = Get-StatForecast -Kind $first.Kind -Ext $first.Ext
        $planned = @($ok | Where-Object { $_.Plan -gt 0 } | Select-Object -Last 10)
        $accuracy = '-'
        if ($planned.Count -gt 0) {
            $accuracy = '±{0}%' -f [int][Math]::Round(100 * (Get-StatMedian @($planned | ForEach-Object { [Math]::Abs($_.Fact - $_.Plan) / $_.Fact })))
        }
        $failed = $group.Count - $ok.Count
        $countText = [string]$group.Count
        if ($failed -gt 0) { $countText = "{0}/{1}" -f $ok.Count, $group.Count }
        $ext = $first.Ext
        if (-not $ext) { $ext = '-' }
        if ($ext.Length -gt 22) { $ext = $ext.Substring(0, 21) + '…' }
        $lines.Add(('{0,-14} {1,-22} {2,4} {3,8} {4,8} {5,9}  {6}' -f $first.Kind, $ext, $countText, (Format-StatSeconds $median), (Format-StatSeconds $forecast.Seconds), $accuracy, $forecast.Text))
    }
    $lines.Add('')
    $lines.Add('Последние 15 шагов:')
    foreach ($row in @($rows | Select-Object -Last 15)) {
        $planText = '-'
        if ($row.Plan -gt 0) { $planText = Format-StatSeconds $row.Plan }
        $lines.Add(('  {0:dd.MM HH:mm}  {1,-6} {2,-8} план {3,-8} факт {4,-8} {5}' -f $row.Time, $row.Source, $row.Status, $planText, (Format-StatSeconds $row.Fact), $row.Title))
    }
    return $lines.ToArray()
}
