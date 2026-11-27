#requires -Version 5.1
<#
.SYNOPSIS
    Ночная проверка тестовой базы: с изменениями из Git или в текущем состоянии.
.DESCRIPTION
    Версия 00000000.000000.

    .\nightly.ps1 -Install [-At 03:30]
        Задание планировщика Windows ci-gate-nightly: каждый день в At (или NightlyAt из config.psd1,
        по умолчанию 03:30) запускать этот скрипт. Время в часы NightlyDeniedFrom..To (по умолчанию 22:00-02:00) не принимается: в это окно
        ставят обновления. Задание - от текущего пользователя (его файлы паролей DPAPI), только пока
        он вошёл в систему; «выполнять для всех пользователей» - в планировщике руками, с паролем.

    .\nightly.ps1 -Uninstall      снять задание.
    .\nightly.ps1 -Status         задание (следующий запуск, итог прошлого) и итог последнего прогона.

    .\nightly.ps1
        Сам ночной прогон: run.ps1 «как есть» без вопросов (-OnNotGreen Keep -OnSessions Continue).
        Задан репозиторий расширений (ExtensionsRepo) - сначала «Загрузить из git» без человека (deploy.ps1
        -GitImport -GitUnattended, раздел 5.23): правки temp уходят веткой и pull request, temp не трогается;
        правок нет, а main ушёл вперёд - прогон гейта с ним, он и есть ночной. Иначе - «как есть».
        Вывод - в nightly\<время>.log, итог - в nightly\last.json и строкой в nightly\history.txt.
        Утром итог виден в меню гейта (ci, .\run.cmd).
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [string]$At = '',
    # Задаёт ci.exe; ночному прогону канал не нужен: вопросов нет.
    [string]$UiChannel = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$TaskName = 'ci-gate-nightly'
$nightlyDir = Join-Path $Root 'nightly'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

$cfg = @{}
$configPath = Join-Path $Root 'config.psd1'
if (Test-Path -LiteralPath $configPath) { $cfg = Import-PowerShellDataFile -LiteralPath $configPath }
# Настройки площадки (config.site.psd1) - как в run.ps1: ключа нет в config.psd1 или он там пустой - оттуда.
$siteConfigPath = Join-Path $Root 'config.site.psd1'
if (Test-Path -LiteralPath $siteConfigPath) {
    $siteConfig = Import-PowerShellDataFile -LiteralPath $siteConfigPath
    foreach ($siteKey in @($siteConfig.Keys)) {
        $ownEmpty = $false
        if ($cfg.ContainsKey($siteKey)) {
            $own = $cfg[$siteKey]
            $ownEmpty = ($null -eq $own) -or (($own -is [array]) -and @($own).Count -eq 0) -or (($own -is [string]) -and $own -eq '')
        }
        if (-not $cfg.ContainsKey($siteKey) -or $ownEmpty) { $cfg[$siteKey] = $siteConfig[$siteKey] }
    }
}

function Get-NightlySetting {
    param([string]$Key, $Default)
    if ($cfg.ContainsKey($Key) -and $null -ne $cfg[$Key]) { return $cfg[$Key] }
    return $Default
}

function ConvertTo-NightlyTime {
    # «ЧЧ:ММ» -> DateTime сегодня в это время. Не время или запретные часы (NightlyDeniedFrom..To) - исключение.
    param([string]$Text)
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Text.Trim(), 'H:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        throw ("время «{0}» не в виде ЧЧ:ММ" -f $Text)
    }
    # ** Хлебников С.Ю. 20261120 Запретные часы ночного прогона - из настроек (по умолчанию 22-02, как было).
    if (Test-NightlyDenied $parsed) {
        throw ("время {0} попадает в часы {1} (NightlyDeniedFrom/To): в них бэкап и обновление рабочей, ночной прогон там мешает" -f $parsed.ToString('HH:mm'), (Get-NightlyDeniedText))
    }
    # ** Хлебников С.Ю. 20261120 конец
    return $parsed
}

function Test-NightlyDenied {
    # Попадает ли время в запретные часы ночного прогона (NightlyDeniedFrom..To, по умолчанию 22-02).
    param([datetime]$At)
    $nightFrom = [int](Get-NightlySetting 'NightlyDeniedFrom' 22)
    $nightTo = [int](Get-NightlySetting 'NightlyDeniedTo' 2)
    if ($nightFrom -gt $nightTo) { return ($At.Hour -ge $nightFrom -or $At.Hour -lt $nightTo) }
    if ($nightFrom -lt $nightTo) { return ($At.Hour -ge $nightFrom -and $At.Hour -lt $nightTo) }
    return $false
}

function Get-NightlyDeniedText {
    return ('{0:00}:00-{1:00}:00' -f [int](Get-NightlySetting 'NightlyDeniedFrom' 22), [int](Get-NightlySetting 'NightlyDeniedTo' 2))
}

if ($Install) {
    $timeText = $At
    if (-not $timeText) { $timeText = [string](Get-NightlySetting 'NightlyAt' '03:30') }
    try { $time = ConvertTo-NightlyTime $timeText }
    catch { Write-Host ("Задание не создано: {0}" -f $_.Exception.Message) -ForegroundColor Red; exit 1 }
    $script = Join-Path $Root 'nightly.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script) -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -Daily -At $time
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force `
        -Description 'Гейт 1С проверяет тестовую базу. При настроенном репозитории сначала сверяет Git и при необходимости загружает изменения. Иначе проверяет текущее состояние базы.' | Out-Null
    Write-Host ("Задание {0}: каждый день в {1}, от пользователя {2}, пока он в системе." -f $TaskName, $time.ToString('HH:mm'), $env:USERNAME) -ForegroundColor Green
    Write-Host 'Итог - nightly\last.json, утром он виден в меню гейта.'
    exit 0
}

if ($Uninstall) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { Write-Host ("Задания {0} нет." -f $TaskName); exit 0 }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host ("Задание {0} снято." -f $TaskName) -ForegroundColor Green
    exit 0
}

if ($Status) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { Write-Host ("Задания {0} нет: поставить - .\nightly.ps1 -Install" -f $TaskName) }
    else {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host ("Задание {0}: {1}; следующий запуск {2}; прошлый {3}, код {4}" -f $TaskName, $task.State, $info.NextRunTime, $info.LastRunTime, $info.LastTaskResult)
    }
    $lastFile = Join-Path $nightlyDir 'last.json'
    if (Test-Path -LiteralPath $lastFile) {
        $last = [System.IO.File]::ReadAllText($lastFile, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $description = ''
        if ($last.PSObject.Properties['mode']) { $description = ' · ' + $last.mode }
        if ($last.PSObject.Properties['commit'] -and $last.commit) { $description += ' · ' + $last.commit }
        Write-Host ("Последний ночной прогон: {0}{4}, вердикт {1}, прогон {2}, вывод {3}" -f $last.time, $last.verdict, $last.runId, $last.log, $description)
    }
    else { Write-Host 'Ночных прогонов ещё не было.' }
    exit 0
}

# Ночной прогон.
New-Item -ItemType Directory -Path $nightlyDir -Force | Out-Null
$started = Get-Date
$stamp = $started.ToString('yyyyMMdd-HHmmss')
$logFile = Join-Path $nightlyDir ($stamp + '.log')
# Задание стартует и с опозданием (компьютер спал - StartWhenAvailable): по расписанию время разрешённое, а на деле
# уже запретные часы. Тогда ни загрузки из git, ни прогона (#11).
if (Test-NightlyDenied $started) {
    $note = ('ночной прогон не запущен: фактический старт {0} - в запретные часы {1} (NightlyDeniedFrom/To), в них бэкап и обновление рабочей' -f $started.ToString('HH:mm'), (Get-NightlyDeniedText))
    [System.IO.File]::WriteAllLines($logFile, [string[]]@($note), $utf8Bom)
    $record = [ordered]@{ time = $started.ToString('yyyy-MM-dd HH:mm:ss'); finished = $started.ToString('yyyy-MM-dd HH:mm:ss'); runId = ''; verdict = 'NONE'; exitCode = 0; log = $logFile; note = $note; mode = 'Запуск пропущен'; commit = '' }
    [System.IO.File]::WriteAllText((Join-Path $nightlyDir 'last.json'), (ConvertTo-Json -InputObject $record), $utf8Bom)
    [System.IO.File]::AppendAllText((Join-Path $nightlyDir 'history.txt'), ("{0}`t{1}`t{2}`t{3}`r`n" -f $record.time, 'NONE', '', 0), $utf8Bom)
    Write-Host $note
    exit 0
}
$runsRoot = Join-Path $Root ([string](Get-NightlySetting 'RunsDir' 'runs'))
if ([System.IO.Path]::IsPathRooted([string](Get-NightlySetting 'RunsDir' 'runs'))) { $runsRoot = [string](Get-NightlySetting 'RunsDir' 'runs') }
$known = @{}
if (Test-Path -LiteralPath $runsRoot) { foreach ($dir in @(Get-ChildItem -LiteralPath $runsRoot -Directory)) { $known[$dir.Name] = $true } }

# Отдельный процесс: у run.ps1 свои trap и exit, ночной скрипт должен дожить до итога.
# Строки stderr при 2>&1 в PowerShell 5.1 становятся ошибками: при Stop они прервали бы ночной скрипт.
$output = @()
$exitCode = 0
$gitRan = $false
$mode = 'Текущее состояние базы'
$commit = ''
$importRun = ''
$extensionsRepo = [string](Get-NightlySetting 'ExtensionsRepo' '')
if ($extensionsRepo -and (Test-Path -LiteralPath (Join-Path $Root 'deploy.ps1')) -and (Test-Path -LiteralPath (Join-Path $Root 'github.ps1'))) {
    # Сначала - «Загрузить из git» без человека. Его итог - git\<репозиторий>\last-import.json: был ли прогон гейта.
    $gitDirSetting = [string](Get-NightlySetting 'GitDir' 'git')
    $gitRoot = $gitDirSetting
    if (-not [System.IO.Path]::IsPathRooted($gitRoot)) { $gitRoot = Join-Path $Root $gitRoot }
    $importFile = Join-Path (Join-Path $gitRoot ($extensionsRepo.Split('/')[-1])) 'last-import.json'
    if (Test-Path -LiteralPath $importFile) { Remove-Item -LiteralPath $importFile -Force }
    $ErrorActionPreference = 'Continue'
    $output += @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'deploy.ps1') -GitImport -GitUnattended 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if (Test-Path -LiteralPath $importFile) {
        try {
            $import = [System.IO.File]::ReadAllText($importFile, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            $gitRan = [bool]$import.ran
            if ($gitRan) {
                $mode = 'Прогон с изменениями из Git'
                if ($import.PSObject.Properties['commit']) { $commit = [string]$import.commit }
                if ($import.PSObject.Properties['run']) { $importRun = [string]$import.run }
            }
            $output += ('Загрузка из git: {0}' -f [string]$import.note)
        }
        catch { $output += ('Итог загрузки из git не прочитан: {0}' -f $_.Exception.Message) }
    }
    else { $output += 'Загрузка из git не дошла до итога (см. вывод выше): ночной прогон - «как есть».' }
}
if (-not $gitRan) {
    $ErrorActionPreference = 'Continue'
    $output += @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'run.ps1') -OnNotGreen Keep -OnSessions Continue 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
}
[System.IO.File]::WriteAllLines($logFile, [string[]]@($output | ForEach-Object { [string]$_ }), $utf8Bom)
# Прогон оборвался (упал процесс, его сняли) - итог в GitHub отправит publish.ps1 -Pending, если отправка включена.
$publishScript = Join-Path $Root 'publish.ps1'
if (Test-Path -LiteralPath $publishScript) {
    try { & $publishScript -Pending } catch { Write-Host ("Итог прогона в GitHub не ушёл: {0}" -f $_.Exception.Message) }
}

$runId = ''
$verdict = 'NONE'
if (Test-Path -LiteralPath $runsRoot) {
    $fresh = @(Get-ChildItem -LiteralPath $runsRoot -Directory | Where-Object { (-not $importRun -or $_.Name -eq $importRun) -and -not $known.ContainsKey($_.Name) -and $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name | Select-Object -Last 1)
    if ($fresh.Count -gt 0) {
        $runId = $fresh[0].Name
        $verdictFile = Join-Path $fresh[0].FullName 'verdict.json'
        if (Test-Path -LiteralPath $verdictFile) {
            $verdictData = [System.IO.File]::ReadAllText($verdictFile, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            $verdict = [string]$verdictData.verdict
        }
    }
}
$record = [ordered]@{
    time     = $started.ToString('yyyy-MM-dd HH:mm:ss')
    finished = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    runId    = $runId
    verdict  = $verdict
    mode     = $mode
    commit   = $commit
    exitCode = $exitCode
    log      = $logFile
}
[System.IO.File]::WriteAllText((Join-Path $nightlyDir 'last.json'), (ConvertTo-Json -InputObject $record), $utf8Bom)
[System.IO.File]::AppendAllText((Join-Path $nightlyDir 'history.txt'), ("{0}`t{1}`t{2}`t{3}`r`n" -f $record.time, $verdict, $runId, $exitCode), $utf8Bom)
$modeText = $mode
if ($commit) { $modeText += (' · ' + $commit) }
Write-Host ("Ночной прогон: {4}, вердикт {0}, прогон {1}, код {2}. Вывод - {3}" -f $verdict, $runId, $exitCode, $logFile, $modeText)
exit $exitCode
