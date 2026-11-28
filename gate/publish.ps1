#requires -Version 5.1
<#
Итог прогона гейта - в GitHub. Гейт шлёт событие repository_dispatch «gate-run» в репозиторий RunReportRepo,
а комментарий в issue «Прогоны гейта» пишет workflow этого репозитория (бот GitHub Actions) и упоминает
владельца: о своих же действиях GitHub не уведомляет, а гейт ходит с токеном человека. Пример workflow -
docs/gate-runs.workflow.yml. Версия 00000000.000000.

Файлы прогона (настройка RunFilesRepo) - в отдельную ветку RunFilesBranch этого репозитория, папка runs/<прогон>:
все текстовые файлы папки прогона целиком (журналы самопроверки, report.txt, summary.txt, run.log и прочие), без
двоичных; файл, в котором нашёлся секрет (токен, пароль, код разрешения), не выкладывается. Ссылка на папку - в
итоге. Ветка-сирота: main с его PR и проверками не трогается.

  .\publish.ps1 -RunDir <папка прогона> -Stage verdict|final|crash [-Message <причина>]
        verdict - вердикт есть, ждём решения по комплекту; final - прогон закончен; crash - скрипт остановился
  .\publish.ps1 -Pending
        отправить то, что не ушло: прогон оборвался (процесс сняли, окно закрыли - «broken») или не было связи

Что хотели отправить и что ушло - publish.json в папке прогона; живой ли процесс прогона - pid.txt.
Сбой отправки прогон не портит: итог уйдёт при следующем запуске гейта (run.ps1 и nightly.ps1 зовут -Pending).
Токен - GitHubTokenPassFile, право Contents: write на RunReportRepo (и на RunFilesRepo). Уходит только в api.github.com.
#>
[CmdletBinding()]
param(
    [string]$RunDir = '',
    [ValidateSet('verdict', 'final', 'crash')]
    [string]$Stage = 'final',
    [string]$Message = '',
    [string]$OperationDir = '',
    [switch]$OperationHelpersLoaded,
    [switch]$Pending,
    [switch]$WatchProgress,
    [switch]$WatchOperations, # ** Хлебников С.Ю. 20261124
    [string]$Config = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
# Предел события GitHub - 64 КБ на всё тело запроса; берём с запасом.
$PayloadLimitBytes = 60000
# Файлы прогона в git (RunFilesRepo): какие берём и пределы. Двоичные (комплект, сохранённые расширения,
# обработки) не берём: им место в папке прогона, в git они раздувают историю.
$RunFilesExtensions = @('.txt', '.log', '.json', '.jsonl', '.md', '.csv', '.tsv')
$RunFilesSkipDirs = @('kit', 'inbox', 'before', 'reference', 'epf', 'dispatch')
$RunFilesMaxFileBytes = 20MB
$RunFilesMaxTotalBytes = 100MB
$RunFilesMaxCount = 1000
# Клиент GitHub: голова ветки, коммит, ветка; подставной GitHub для тестов - CI_FAKE_GITHUB.
if (-not $OperationHelpersLoaded) {
    . (Join-Path $Root 'github.ps1')
    . (Join-Path $Root 'operation-report.ps1')
}

#region Настройки и токен

function Get-PublishToken {
    # Токен GitHub из файла DPAPI (как пароли гейта). В вывод и журналы не попадает.
    param([string]$PassFile)
    if (-not $PassFile) { throw 'нет токена GitHub: «Настройки - Обновление гейта и git», GitHubTokenPassFile' }
    $path = $PassFile
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Root $path }
    return (Read-GateTokenFile $path)
}

#endregion

#region Состояние прогона

function Read-TextFile {
    # Текст файла (UTF-8, с BOM или без); нет файла - пусто.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
}

function Get-PublishState {
    # Что хотели отправить (wanted) и что ушло (sent): verdict, final, crash, broken; message - причина остановки.
    # filesWanted, filesSent, filesError - то же для файлов прогона в git (RunFilesRepo).
    param([string]$Dir)
    $state = [ordered]@{ wanted = ''; sent = ''; message = ''; error = ''; time = ''; filesWanted = ''; filesSent = ''; filesError = ''; sentPart = 0 }
    $text = Read-TextFile (Join-Path $Dir 'publish.json')
    if ($text) {
        try {
            $read = $text | ConvertFrom-Json
            foreach ($name in @('wanted', 'sent', 'message', 'error', 'time', 'filesWanted', 'filesSent', 'filesError', 'sentPart')) {
                if ($null -ne $read.PSObject.Properties[$name]) { $state[$name] = [string]$read.$name }
            }
        }
        catch { }
    }
    return $state
}

function Save-PublishState {
    param([string]$Dir, $State)
    $State['time'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Save-GateReportJson (Join-Path $Dir 'publish.json') $State
}

function Test-RunAlive {
    # Жив ли процесс прогона: pid.txt - «номер|время старта процесса». Номер мог достаться другому процессу -
    # тогда время старта не совпадёт.
    param([string]$Dir)
    $text = (Read-TextFile (Join-Path $Dir 'pid.txt')).Trim()
    if (-not $text) { return $false }
    $parts = $text.Split('|')
    $processId = 0
    if (-not [int]::TryParse($parts[0], [ref]$processId) -or $processId -le 0) { return $false }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    if ($parts.Count -lt 2) { return $true }
    try {
        if ($process.StartTime.ToString('o') -eq $parts[1]) { return $true }
        # В .NET на Unix время рождения процесса восстанавливается по часам ядра и слегка
        # различается у двух читателей. На Windows сохраняем точное сравнение, как раньше.
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Unix) { return $false }
        $expected = [datetimeoffset]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
        return [Math]::Abs(($process.StartTime.ToUniversalTime() - $expected.UtcDateTime).TotalMilliseconds) -lt 50
    } catch { return $true }
}

function Write-PublishLog {
    # Строка в run.log прогона - тем же видом, что пишет run.ps1.
    param([string]$Dir, [string]$Text)
    try { [System.IO.File]::AppendAllText((Join-Path $Dir 'run.log'), ("{0} {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $Text), $Utf8Bom) } catch { }
}

#endregion

#region Текст итога

function Get-VerdictTitle {
    param([string]$Verdict)
    switch ($Verdict) {
        'GREEN' { return '🟢 ЗЕЛЁНЫЙ' }
        'YELLOW' { return '🟡 ЖЁЛТЫЙ' }
        'RED' { return '🔴 КРАСНЫЙ' }
    }
    return '⚪ без вердикта'
}

function ConvertTo-InlineCode {
    param([string]$Text)
    return ('`' + ([string]$Text).Replace('`', "'") + '`')
}

function New-RunReport {
    # Итог прогона для комментария: заголовок, сведения, summary.txt (или шаги, что успели), run.log
    # (при остановке и обрыве), report.txt под катом.
    # FilesLine - строка со ссылкой на файлы прогона в git (пусто - выкладка выключена): сразу под сведениями,
    # до подробностей прогона.
    param([string]$Dir, [string]$Kind, [string]$Reason, [string]$FilesLine = '')
    $id = Split-Path -Leaf $Dir
    $verdictData = $null
    $verdictText = Read-TextFile (Join-Path $Dir 'verdict.json')
    if ($verdictText) { try { $verdictData = $verdictText | ConvertFrom-Json } catch { $verdictData = $null } }
    $resumeData = $null
    $resumeText = Read-TextFile (Join-Path $Dir 'resume.json')
    if ($resumeText) { try { $resumeData = $resumeText | ConvertFrom-Json } catch { $resumeData = $null } }

    $verdictCode = ''
    $baseKey = ''
    $kit = ''
    $gateVersion = ''
    $decision = ''
    if ($null -ne $verdictData) {
        $verdictCode = [string]$verdictData.verdict
        $baseKey = [string]$verdictData.baseKey
        $kit = [string]$verdictData.kit
        if ($null -ne $verdictData.PSObject.Properties['gateVersion']) { $gateVersion = [string]$verdictData.gateVersion }
        $decision = [string]$verdictData.kitDecision
    }
    elseif ($null -ne $resumeData) {
        $baseKey = [string]$resumeData.baseKey
        $gateVersion = [string]$resumeData.gateVersion
    }

    $title = ''
    $lead = New-Object System.Collections.Generic.List[string]
    switch ($Kind) {
        'crash' {
            $title = '⛔ ОСТАНОВЛЕН'
            if ($Reason) { $lead.Add(('**Причина:** {0}' -f $Reason)) }
            if ($verdictCode) { $lead.Add(('Вердикт к этому моменту уже был: {0}.' -f (Get-VerdictTitle $verdictCode))) }
        }
        'broken' {
            $title = '⚠️ ОБОРВАЛСЯ'
            $lead.Add('Итог не дописан: процесс прогона кончился раньше времени (окно закрыли, процесс сняли, перезагрузка). Ниже - что успело записаться.')
            if ($verdictCode) { $lead.Add(('Вердикт успел: {0}; решения по комплекту не было.' -f (Get-VerdictTitle $verdictCode))) }
        }
        'verdict' {
            $title = Get-VerdictTitle $verdictCode
            $lead.Add('Ждёт решения: оставить комплект или откатить. Когда ответят - здесь же допишется итог.')
        }
        default {
            $title = Get-VerdictTitle $verdictCode
            switch ($decision) {
                'kept' { $lead.Add('Комплект оставлен в базе.') }
                'rolledBack' { $lead.Add('Комплект откачен.') }
                'rollbackFailed' { $lead.Add('**Откат не удался** - базу смотреть руками.') }
            }
        }
    }

    $info = New-Object System.Collections.Generic.List[string]
    if ($baseKey) { $info.Add(('база ' + (ConvertTo-InlineCode $baseKey))) }
    if ($env:COMPUTERNAME) { $info.Add(('компьютер ' + (ConvertTo-InlineCode $env:COMPUTERNAME))) }
    if ($gateVersion) { $info.Add(('гейт ' + $gateVersion)) }
    if ($kit) { $info.Add(('комплект ' + (ConvertTo-InlineCode $kit))) } elseif ($null -ne $verdictData) { $info.Add('как есть, без комплекта') }
    $started = [datetime]::MinValue
    if ([datetime]::TryParseExact($id, 'yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$started)) {
        $ended = Get-Date
        $logFile = Join-Path $Dir 'run.log'
        if (Test-Path -LiteralPath $logFile) { $ended = (Get-Item -LiteralPath $logFile).LastWriteTime }
        $span = $ended - $started
        if ($span.TotalSeconds -ge 0) { $info.Add(('{0}:{1:mm}:{1:ss}' -f [int][Math]::Floor($span.TotalHours), $span)) }
    }

    $body = New-Object System.Collections.Generic.List[string]
    $body.Add(('### {0} · прогон {1}' -f $title, $id))
    $body.Add(($info -join ' · '))
    if ($null -ne $verdictData -and $null -ne $verdictData.PSObject.Properties['resume'] -and $null -ne $verdictData.resume) {
        $body.Add(('Продолжение прогона {0} с «{1}».' -f $verdictData.resume.from, $verdictData.resume.startTitle))
    }
    foreach ($line in $lead) { $body.Add(''); $body.Add($line) }
    if ($FilesLine) { $body.Add(''); $body.Add($FilesLine) }

    $summary = Read-TextFile (Join-Path $Dir 'summary.txt')
    if ($summary) {
        $body.Add('')
        $body.Add('**Итог** (summary.txt)')
        $body.Add('````text')
        $body.Add($summary.TrimEnd())
        $body.Add('````')
    }
    else {
        $stepsText = Read-TextFile (Join-Path $Dir 'steps.jsonl')
        $stepLines = New-Object System.Collections.Generic.List[string]
        foreach ($raw in @($stepsText -split "`r?`n")) {
            if (-not $raw.Trim()) { continue }
            try {
                $step = $raw | ConvertFrom-Json
                $stepLines.Add(('[{0,-4}] {1}' -f [string]$step.status, [string]$step.name))
                if ([string]$step.detail) { $stepLines.Add(('       ' + [string]$step.detail)) }
            }
            catch { }
        }
        $body.Add('')
        if ($stepLines.Count -gt 0) {
            $body.Add('**Шаги, которые успели пройти**')
            $body.Add('````text')
            $body.Add(($stepLines -join "`n"))
            $body.Add('````')
        }
        else { $body.Add('Ни один шаг не успел закончиться.') }
    }

    if ($Kind -eq 'crash' -or $Kind -eq 'broken') {
        $log = Read-TextFile (Join-Path $Dir 'run.log')
        if ($log) {
            $body.Add('')
            $body.Add('<details><summary>Журнал run.log</summary>')
            $body.Add('')
            $body.Add('````text')
            $body.Add($log.TrimEnd())
            $body.Add('````')
            $body.Add('</details>')
        }
    }

    $report = Read-TextFile (Join-Path $Dir 'report.txt')
    if ($report) {
        $body.Add('')
        $body.Add('<details><summary>Разбор прогона (report.txt)</summary>')
        $body.Add('')
        $body.Add('````text')
        $body.Add($report.TrimEnd())
        $body.Add('````')
        $body.Add('</details>')
    }
    $body.Add('')
    $body.Add(('Папка прогона: ' + (ConvertTo-InlineCode $Dir)))

    $verdictForEvent = $verdictCode
    if ($Kind -eq 'crash' -or $Kind -eq 'broken') { $verdictForEvent = $Kind.ToUpperInvariant() }
    return [pscustomobject]@{ Title = ('{0} · {1}' -f $title, $id); Verdict = $verdictForEvent; Body = ($body -join "`n") }
}

#endregion

#region Файлы прогона в git

function Get-RunFilesUrl {
    param([string]$Repo, [string]$Branch, [string]$Id)
    return ('https://github.com/{0}/tree/{1}/runs/{2}' -f $Repo, $Branch, $Id)
}

function Get-JsonText {
    # Строка свойства разобранного JSON; нет свойства - пусто (StrictMode не даёт читать отсутствующее).
    param($Object, [string]$Name)
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return '' }
    return [string]$Object.$Name
}

function Read-RunFileText {
    # Текст файла для поиска секретов: кодировка по BOM (UTF-8, UTF-16), без BOM - UTF-8.
    param([byte[]]$Bytes)
    $stream = [System.IO.MemoryStream]::new($Bytes)
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-RunFileList {
    # Что из папки прогона выкладывать: Files - путь в ветке (runs/<прогон>/...) и байты; Skipped - что не
    # выложено и почему (для README.md); Secrets - файлы, в которых нашёлся секрет; Other - сколько нетекстовых.
    param([string]$Dir, [string]$Id, $Secrets)
    $rootFull = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')
    $files = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[string]
    $secretHits = New-Object System.Collections.Generic.List[string]
    $other = 0
    $total = [long]0
    # ** Хлебников С.Ю. 20261124 При лимите файлов первыми сохраняем вердикт, проверенное состояние и итог.
    $keyFiles = @('verdict.json','checked-state.json','summary.txt','report.txt','timeline.txt','released.txt','publish.json')
    $rank = @{ Expression = { if ($_.DirectoryName -eq $rootFull -and $keyFiles -contains $_.Name) { 0 } else { 1 } } }
    foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object $rank, FullName)) {
        if (-not $file.FullName.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $parts = @($file.FullName.Substring($rootFull.Length + 1) -split '[\\/]')
        $relative = $parts -join '/'
        if ((Protect-GateReportText $relative $Secrets) -cne $relative) { $skipped.Add('Имя файла содержит секрет'); continue }
        # README.md папки в git пишет сам гейт (New-RunFilesReadme).
        if ($relative -in @('README.md', 'publish.json', 'run-launch.json')) { continue }
        if ($parts.Count -gt 1 -and $RunFilesSkipDirs -contains $parts[0]) { $other++; continue }
        if ($RunFilesExtensions -notcontains $file.Extension.ToLowerInvariant()) { $other++; continue }
        if ($file.Length -gt $RunFilesMaxFileBytes) {
            $skipped.Add(('{0}: больше {1} МБ ({2:N1} МБ)' -f $relative, ($RunFilesMaxFileBytes / 1MB), ($file.Length / 1MB)))
            continue
        }
        if ($files.Count -ge $RunFilesMaxCount -or $total + $file.Length -gt $RunFilesMaxTotalBytes) {
            $skipped.Add(('{0}: не влез в предел прогона ({1} файлов, {2} МБ)' -f $relative, $RunFilesMaxCount, ($RunFilesMaxTotalBytes / 1MB)))
            continue
        }
        $bytes = [byte[]]@()
        try { $bytes = [System.IO.File]::ReadAllBytes($file.FullName) }
        catch { $skipped.Add(('{0}: не прочитался ({1})' -f $relative, $_.Exception.Message)); continue }
        $text = Read-RunFileText $bytes
        # Конфигуратор пишет и в Windows-1251, иногда дописывает в уже созданный журнал.
        # Проверяем те же байты в обеих кодировках до передачи исходного файла.
        $ansiText = [System.Text.Encoding]::GetEncoding(1251).GetString($bytes)
        $leak = ''
        foreach ($secret in $Secrets) {
            if ($null -eq $secret) { continue }
            if ((Test-GateReportSecretValue $text $secret) -or (Test-GateReportSecretValue $ansiText $secret)) {
                $leak = [string]$secret.Name
                break
            }
        }
        if (-not $leak -and ((Protect-GateReportText $text $Secrets) -cne $text -or (Protect-GateReportText $ansiText $Secrets) -cne $ansiText)) { $leak = 'реквизиты подключения' }
        if ($leak) {
            $skipped.Add(('{0}: в тексте секрет (настройка {1}) - не выложен' -f $relative, $leak))
            $secretHits.Add(('{0} ({1})' -f $relative, $leak))
            continue
        }
        $total += $file.Length
        $files.Add([pscustomobject]@{ Path = ('runs/{0}/{1}' -f $Id, $relative); Bytes = $bytes })
    }
    return [pscustomobject]@{ Files = $files; Skipped = $skipped; Secrets = $secretHits; Other = $other }
}

function New-RunFilesReadme {
    # README.md папки прогона в git: что за прогон, с чего читать, что не выложено. Времени выкладки нет:
    # повтор без изменений не даёт нового коммита.
    param([string]$Dir, [string]$Id, [string]$Kind, $List, $Secrets)
    $data = $null
    $verdictText = Read-TextFile (Join-Path $Dir 'verdict.json')
    if ($verdictText) { try { $data = $verdictText | ConvertFrom-Json } catch { $data = $null } }
    $stage = $Kind
    switch ($Kind) {
        'verdict' { $stage = 'вердикт есть, ждёт решения по комплекту' }
        'final' { $stage = 'прогон закончен' }
        'crash' { $stage = 'скрипт остановился' }
        'broken' { $stage = 'прогон оборвался' }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('# Прогон {0}' -f $Id))
    $lines.Add('')
    $baseKey = Get-JsonText $data 'baseKey'
    $verdict = Get-JsonText $data 'verdict'
    $gateVersion = Get-JsonText $data 'gateVersion'
    $kit = Get-JsonText $data 'kit'
    if ($baseKey) { $lines.Add(('- база: {0}' -f (ConvertTo-InlineCode $baseKey))) }
    if ($verdict) { $lines.Add(('- вердикт: {0}' -f (Get-VerdictTitle $verdict))) }
    $lines.Add(('- этап: {0}' -f $stage))
    if ($gateVersion) { $lines.Add(('- гейт: {0}' -f $gateVersion)) }
    if ($kit) { $lines.Add(('- комплект: {0}' -f (ConvertTo-InlineCode $kit))) }
    $lines.Add('')
    $lines.Add('С чего читать: report.txt - разбор прогона, summary.txt - итог по шагам, selfcheck-*.journal.txt - журналы самопроверки, run.log - ход прогона.')
    if ($List.Skipped.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Не выложено')
        $lines.Add('')
        foreach ($item in $List.Skipped) { $lines.Add(('- ' + $item)) }
    }
    if ($List.Other -gt 0) {
        $lines.Add('')
        $lines.Add(('Нетекстовых файлов (комплект, сохранённые расширения, обработки, выгрузки) в папке прогона: {0}; в git они не выкладываются.' -f $List.Other))
    }
    # Запятая - чтобы массив байтов не развернулся при возврате.
    return , $Utf8NoBom.GetBytes((Protect-GateReportText (($lines -join "`n") + "`n") $Secrets))
}

function Publish-RunFiles {
    # Файлы прогона - в ветку Branch репозитория Repo, папка runs/<прогон>/, и runs/latest.txt - последний
    # прогон (по имени папки: повторная отправка старого прогона его не перебивает). Только изменённые файлы.
    # Ветки нет - создаётся сиротой (main не трогается). Ветку подвинули между чтением и записью - ещё раз от
    # новой головы. Возвращает Url, Changed (сколько файлов в коммите), Skipped, Secrets.
    param([string]$Dir, [string]$Kind, [string]$Repo, [string]$Branch, [string]$Token, [hashtable]$Settings)
    $id = Split-Path -Leaf $Dir
    $gh = New-GhContext -Repo $Repo -Token $Token
    $secrets = Get-PublishSecrets -Settings $Settings -Token $Token
    $list = Get-RunFileList -Dir $Dir -Id $id -Secrets $secrets
    $readme = [pscustomobject]@{ Path = ('runs/{0}/README.md' -f $id); Bytes = (New-RunFilesReadme -Dir $Dir -Id $id -Kind $Kind -List $list -Secrets $secrets) }
    $result = [pscustomobject]@{ Url = (Get-RunFilesUrl -Repo $Repo -Branch $Branch -Id $id); Changed = 0; Skipped = $list.Skipped.Count; Secrets = $list.Secrets }
    for ($try = 1; $try -le 2; $try++) {
        $head = Get-GhHead -Gh $gh -Branch $Branch
        if ($head.Empty) { throw ('В репозитории {0} ещё нет ни одного коммита. Создайте начальный коммит в основной ветке и повторите отправку файлов.' -f $Repo) }
        $existing = @{}
        if ($head.Sha) { $existing = Get-GhFiles -Gh $gh -Commit $head.Sha }
        $changes = New-Object System.Collections.Generic.List[object]
        $wanted = New-Object System.Collections.Generic.List[object]
        foreach ($file in $list.Files) { $wanted.Add($file) }
        $wanted.Add($readme)
        foreach ($file in $wanted) {
            $known = ''
            if ($existing.ContainsKey($file.Path)) { $known = [string]$existing[$file.Path] }
            if ($known -ne (Get-GitBlobSha ([byte[]]$file.Bytes))) { $changes.Add($file) }
        }
        $latest = $id
        foreach ($path in @($existing.Keys)) {
            $found = [regex]::Match([string]$path, '^runs/(\d{8}-\d{6})/')
            if ($found.Success -and [string]::CompareOrdinal($found.Groups[1].Value, $latest) -gt 0) { $latest = $found.Groups[1].Value }
        }
        if ($latest -eq $id) {
            $latestBytes = $Utf8NoBom.GetBytes($id + "`n")
            $known = ''
            if ($existing.ContainsKey('runs/latest.txt')) { $known = [string]$existing['runs/latest.txt'] }
            if ($known -ne (Get-GitBlobSha $latestBytes)) { $changes.Add([pscustomobject]@{ Path = 'runs/latest.txt'; Bytes = $latestBytes }) }
        }
        if ($changes.Count -eq 0) { return $result }
        $commit = New-GhCommit -Gh $gh -Parent $head.Sha -Changes $changes.ToArray() -Message ('Прогон {0}: файлы прогона ({1})' -f $id, $Kind)
        try {
            if ($head.Sha) { Set-GhBranch -Gh $gh -Branch $Branch -Sha $commit }
            else { Set-GhBranch -Gh $gh -Branch $Branch -Sha $commit -Create }
            $result.Changed = $changes.Count
            return $result
        }
        catch {
            if ($try -ge 2) { throw }
        }
    }
    return $result
}

function Invoke-RunFilesUpload {
    # Файлы прогона - в git (RunFilesRepo, RunFilesBranch). Сбой - не исключением: состояние в State
    # (filesWanted, filesSent, filesError; сохраняет вызывающий), в выводе и run.log. Возвращает строку для итога.
    param([string]$Dir, [string]$Kind, $State, [hashtable]$Settings, [string]$Token)
    $repo = [string](Get-PublishSetting $Settings 'RunFilesRepo' '')
    $branch = [string](Get-PublishSetting $Settings 'RunFilesBranch' 'gate-runs')
    $id = Split-Path -Leaf $Dir
    $url = Get-RunFilesUrl -Repo $repo -Branch $branch -Id $id
    $State['filesWanted'] = $Kind
    try {
        $result = Publish-RunFiles -Dir $Dir -Kind $Kind -Repo $repo -Branch $branch -Token $Token -Settings $Settings
        $State['filesSent'] = $Kind
        $State['filesError'] = ''
        foreach ($hit in $result.Secrets) {
            Write-Host ("В файле прогона нашёлся секрет, файл в git не выложен: {0}. Проверь, как он туда попал." -f $hit) -ForegroundColor Yellow
            Write-PublishLog $Dir ("Файл прогона с секретом в git не выложен: {0}" -f $hit)
        }
        Write-Host ("Файлы прогона {0} в git: {1}" -f $id, $url) -ForegroundColor DarkGray
        Write-PublishLog $Dir ("Файлы прогона ушли в git ({0}, ветка {1}, {2}): изменено файлов {3}, не выложено {4}" -f $repo, $branch, $Kind, $result.Changed, $result.Skipped)
        $note = ''
        if ($result.Skipped -gt 0) { $note = (' (не выложено: {0}, список - в README.md папки)' -f $result.Skipped) }
        return ('**Файлы прогона:** {0}{1}' -f $url, $note)
    }
    catch {
        $reason = Protect-GateReportText $_.Exception.Message (Get-PublishSecrets -Settings $Settings -Token $Token)
        $State['filesError'] = $reason
        Write-Host ("Не удалось выложить файлы прогона {0} в {1}, ветка {2}. {3}. После исправления запустите publish.ps1 -Pending с тем же профилем." -f $id, $repo, $branch, $reason) -ForegroundColor Yellow
        Write-PublishLog $Dir ("Файлы прогона в git не ушли ({0}): {1}" -f $Kind, $reason)
        return ('**Файлы прогона в git не ушли:** {0}. При следующем запуске гейт повторит отправку в {1}.' -f $reason, $url)
    }
}

function Publish-PendingRunFiles {
    # Итог прогона ушёл, а файлы - нет (не было связи с git): дослать только файлы. Возвращает $true, если ушли.
    param([string]$Dir, [string]$TokenFile, [hashtable]$Settings)
    $state = Get-PublishState $Dir
    $token = ''
    try { $token = Get-PublishToken $TokenFile }
    catch {
        Write-Host ("Файлы прогона {0} в git не ушли: {1}" -f (Split-Path -Leaf $Dir), $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
    $null = Invoke-RunFilesUpload -Dir $Dir -Kind $state['filesWanted'] -State $state -Settings $Settings -Token $token
    Save-PublishState $Dir $state
    return ($state['filesSent'] -eq $state['filesWanted'])
}

#endregion

#region Отправка

function Send-RunEvent {
    # POST repository_dispatch. Подставной GitHub для тестов: переменная CI_FAKE_HTTP - запрос пишется в
    # requests.log, тело - в dispatch-NN.json; файл dispatch-fail.txt в той же папке - «нет связи».
    param([string]$Repo, [string]$Token, [string]$Json)
    if ($Repo -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$') { throw 'RunReportRepo: требуется имя в виде владелец/репозиторий' }
    $url = 'https://api.github.com/repos/{0}/dispatches' -f $Repo
    if ($env:CI_FAKE_HTTP) {
        $auth = 'нет'
        if ($Token) { $auth = 'да' }
        [System.IO.File]::AppendAllText((Join-Path $env:CI_FAKE_HTTP 'requests.log'), ("POST {0} токен={1}`r`n" -f $url, $auth), $Utf8NoBom)
        if (Test-Path -LiteralPath (Join-Path $env:CI_FAKE_HTTP 'dispatch-fail.txt')) { throw 'нет связи с api.github.com: подставной сбой' }
        $nth = Join-Path $env:CI_FAKE_HTTP 'dispatch-fail-part.txt'
        if ([IO.File]::Exists($nth) -and ($Json | ConvertFrom-Json).client_payload.part -eq [int]([IO.File]::ReadAllText($nth))) { throw 'подставной сбой отправки части' }
        $number = @(Get-ChildItem -LiteralPath $env:CI_FAKE_HTTP -Filter 'dispatch-*.json').Count + 1
        [System.IO.File]::WriteAllText((Join-Path $env:CI_FAKE_HTTP ('dispatch-{0:D2}.json' -f $number)), $Json, $Utf8NoBom)
        return
    }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = 'POST'
    $request.AllowAutoRedirect = $false
    $request.UserAgent = 'ci-gate'
    $request.Accept = 'application/vnd.github+json'
    $request.ContentType = 'application/json; charset=utf-8'
    $request.Timeout = 20000
    $request.ReadWriteTimeout = 20000
    if ($null -ne $request.Proxy) { $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
    $request.Headers['Authorization'] = 'Bearer ' + $Token
    $request.Headers['X-GitHub-Api-Version'] = '2022-11-28'
    $bytes = $Utf8NoBom.GetBytes($Json)
    $request.ContentLength = $bytes.Length
    $response = $null
    try {
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        $response = $request.GetResponse()
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception -and -not ($exception -is [System.Net.WebException])) { $exception = $exception.InnerException }
        if ($null -eq $exception -or $null -eq $exception.Response) { throw ("нет связи с api.github.com: {0}" -f $_.Exception.Message) }
        $response = $exception.Response
    }
    try {
        $code = [int]$response.StatusCode
        if ($code -ge 300) {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $answer = $reader.ReadToEnd()
            $apiText = $answer
            try { $apiText = [string](ConvertFrom-Json $answer).message } catch { $apiText = $answer }
            $hint = ''
            if ($code -eq 401) { $hint = ': токен не подходит или истёк' }
            elseif ($code -eq 403 -or $code -eq 404) { $hint = (': у токена нет права Contents: write на {0} или нет такого репозитория' -f $Repo) }
            throw ("GitHub ответил {0}{1} ({2})" -f $code, $hint, $apiText)
        }
    }
    finally { $response.Close() }
}

function Get-ReportDate {
    param($Stamp)
    if ($Stamp -is [datetime]) { return $Stamp.ToUniversalTime() }
    return [datetimeoffset]::Parse($Stamp, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

function New-PublishPacket {
    # Неизменная копия итога. Досылка берёт те же части, даже если после обрыва дописали журнал или сменился пользователь.
    param([string]$Dir, [string]$Kind, [string]$Reason, [string]$FilesLine, $Secrets)
    $id = Split-Path -Leaf $Dir
    $isOperation = Test-Path -LiteralPath (Join-Path $Dir 'operation.json')
    if ($isOperation) {
        $launch = (Read-TextFile (Join-Path $Dir 'operation.json')) | ConvertFrom-Json
        $result = (Read-TextFile (Join-Path $Dir 'result.json')) | ConvertFrom-Json
        $outcome = [string]$result.outcome
        $ended = Get-ReportDate $result.ended
        $verdict = $outcome
        $title = '{0} · {1} · {2}' -f $launch.operation, $outcome, $id
        $detail = Read-TextFile (Join-Path $Dir 'summary.txt')
        if ($Kind -eq 'broken') { $detail += "`nПроцесс завершился до записи исхода. Время окончания — по последней записи." }
        $body = $detail
    } else {
        $launchText = Read-TextFile (Join-Path $Dir 'run-launch.json')
        if ($launchText) { $launch = $launchText | ConvertFrom-Json }
        else {
            # Старые прогоны не записывали пользователя. Не приписываем запуск тому, кто дослал отчёт.
            $startedAt = [datetime]::ParseExact($id, 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
            $launch = [pscustomobject]@{ operation = 'run'; started = $startedAt.ToString('o'); user = ''; gateVersion = '' }
        }
        $report = New-RunReport -Dir $Dir -Kind $Kind -Reason $Reason -FilesLine $FilesLine
        $title = $report.Title
        $body = $report.Body
        $verdict = $report.Verdict
        $outcome = $verdict
        if ($Kind -eq 'crash') {
            $outcome = 'failed'
            if ($Reason -match '(?i)отмен|cancel|остановлено из интерфейса|выход по ответу') { $outcome = 'cancelled' }
        }
        if ($Kind -eq 'broken') { $outcome = 'broken' }
        $ended = [DateTime]::UtcNow
        $log = Join-Path $Dir 'run.log'
        if (Test-Path -LiteralPath $log) { $ended = [IO.File]::GetLastWriteTimeUtc($log) }
    }
    $duration = [Math]::Max(0, [Math]::Round(($ended - (Get-ReportDate $launch.started)).TotalSeconds))
    $user = Protect-GateReportText $launch.user $Secrets
    $meta = [ordered]@{ started = (Get-ReportDate $launch.started).ToString('o'); user = $user; gateVersion = (Protect-GateReportText $launch.gateVersion $Secrets); durationSeconds = $duration }
    if ($isOperation) {
        $body = "### $title`n$($meta.started) · $user · гейт $($meta.gateVersion) · $duration с`n`n$body"
    }
    return [ordered]@{
        run = $id; stage = $Kind; verdict = $verdict; title = (Protect-GateReportText $title $Secrets)
        body = (Protect-GateReportText $body $Secrets); operation = $launch.operation; outcome = $outcome; launch = $meta
    }
}

function Send-ReportParts {
    param([string]$Dir, [string]$Kind, [string]$Reason, [string]$FilesLine, [string]$Repo, [string]$Token, $Secrets, $State)
    $outbox = Join-Path $Dir 'dispatch'
    [void][IO.Directory]::CreateDirectory($outbox)
    $path = Join-Path $outbox ($Kind + '.json')
    if (-not [IO.File]::Exists($path)) {
        $packet = New-PublishPacket $Dir $Kind $Reason $FilesLine $Secrets
        Save-GateReportJson $path $packet
    }
    $packet = (Read-TextFile $path) | ConvertFrom-Json
    $body = [string]$packet.body
    # Один символ UTF-16 в JSON занимает не более 6 байт. Запас оставлен под метаданные.
    # Короткие отчёты сначала пробуем целиком; длинные части не разрывают суррогатную пару.
    $parts = New-Object System.Collections.Generic.List[string]
    $whole = ConvertTo-Json -InputObject $packet -Compress -Depth 5
    if ($Utf8NoBom.GetByteCount($whole) -lt $PayloadLimitBytes - 1024 -and $body.Length -lt 62000) { $parts.Add($body) }
    else {
        for ($start = 0; $start -lt $body.Length;) {
            $length = [Math]::Min(8000, $body.Length - $start)
            if ($start + $length -lt $body.Length) {
                $newline = $body.LastIndexOf([char]10, $start + $length - 1, $length)
                if ($newline -ge $start + 4000) { $length = $newline - $start + 1 }
                if ([char]::IsHighSurrogate($body[$start + $length - 1])) { $length-- }
            }
            $parts.Add($body.Substring($start, $length))
            $start += $length
        }
    }
    $packet | Add-Member -NotePropertyName parts -NotePropertyValue $parts.Count
    $packet | Add-Member -NotePropertyName part -NotePropertyValue 0
    for ($i = [int]$State['sentPart']; $i -lt $parts.Count; $i++) {
        $packet.part = $i + 1
        $packet.body = $parts[$i]
        $json = ConvertTo-Json -InputObject @{ event_type = 'gate-run'; client_payload = $packet } -Compress -Depth 6
        if ($Utf8NoBom.GetByteCount($json) -gt $PayloadLimitBytes) { throw 'Размер части отчёта после упаковки превышает предел GitHub. Откройте локальный отчёт и передайте его номер разработчику гейта для проверки разбиения.' }
        Send-RunEvent -Repo $Repo -Token $Token -Json $json
        $State['sentPart'] = $i + 1
        Save-PublishState $Dir $State
    }
}

function Publish-Operation {
    param([string]$Dir, [string]$Repo, [string]$TokenFile, [hashtable]$Settings, [switch]$Recover)
    # Такой же вызов из -Pending может идти одновременно. Файловую блокировку отпустит и убитый процесс.
    $lease = $null
    $secrets = $null
    $token = ''
    try {
        try { $lease = [IO.File]::Open((Join-Path $Dir 'publish.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] { return $true }
        $launch = (Read-TextFile (Join-Path $Dir 'operation.json')) | ConvertFrom-Json
        if ($launch.repo -ne $Repo) { return $true }
        $state = Get-PublishState $Dir
        if ($state['sent'] -and $state['wanted'] -eq $state['sent']) { return $true }
        $resultPath = Join-Path $Dir 'result.json'
        if (-not [IO.File]::Exists($resultPath)) {
            if (-not $Recover -or (Test-RunAlive $Dir)) { return $true }
            $forward = Read-TextFile (Join-Path $Dir 'forward.json')
            if ($forward) {
                $runId = ($forward | ConvertFrom-Json).run
                if ($runId -match '^\d{8}-\d{6}$') {
                    $runPath = Join-Path (Get-GateReportRoot $Settings) $runId
                    $runLaunch = Read-TextFile (Join-Path $runPath 'run-launch.json')
                    if ([IO.File]::Exists((Join-Path $runPath 'pid.txt')) -and $runLaunch -and (Get-JsonText ($runLaunch | ConvertFrom-Json) 'origin') -eq (Split-Path -Leaf $Dir)) { return $true }
                }
            }
            $last = [IO.File]::GetLastWriteTimeUtc((Join-Path $Dir 'operation.json'))
            $summary = Join-Path $Dir 'summary.txt'
            if ([IO.File]::Exists($summary)) { $last = [IO.File]::GetLastWriteTimeUtc($summary) }
            Save-GateReportJson $resultPath @{ outcome = 'broken'; ended = $last.ToString('o') }
        }
        $result = (Read-TextFile $resultPath) | ConvertFrom-Json
        $kind = 'final'
        if ($result.outcome -in @('cancelled', 'failed')) { $kind = 'crash' }
        elseif ($result.outcome -eq 'broken') { $kind = 'broken' }
        $state['wanted'] = $kind
        Save-PublishState $Dir $state
        # До чтения токена фиксируем, что именно нужно дослать.
        $secrets = Get-PublishSecrets -Settings $Settings -Token ''
        $token = Get-PublishToken $TokenFile
        Send-ReportParts $Dir $kind '' '' $Repo $token $secrets $state
        $state['sent'] = $kind
        $state['error'] = ''
        Save-PublishState $Dir $state
        return $true
    } catch {
        $reason = $_.Exception.Message
        if ($null -eq $secrets) { $secrets = Get-PublishSecrets -Settings $Settings -Token '' }
        $message = 'Не удалось отправить итог операции {0} в {1}. {2}. После исправления запустите publish.ps1 -Pending с тем же профилем или дождитесь следующего запуска гейта.' -f (Split-Path -Leaf $Dir), $Repo, $reason
        $message = Protect-GateReportText $message $secrets -LiteralValues @($token)
        if ($null -ne (Get-Variable state -Scope Local -ErrorAction SilentlyContinue)) {
            $state['error'] = $message
            Save-PublishState $Dir $state
        }
        Write-Warning $message
        return $false
    } finally { if ($null -ne $lease) { $lease.Dispose() } }
}

function Publish-Run {
    # Отправить итог одного прогона. Возвращает $true, если ушло. Сбой - в выводе и в run.log, не исключением.
    # Файлы прогона (RunFilesRepo) уходят до события: ссылка на них - в тексте итога; их сбой событию не мешает.
    param([string]$Dir, [string]$Kind, [string]$Reason, [string]$Repo, [string]$TokenFile, [hashtable]$Settings = @{}, [switch]$Retry)
    try { $lease = [IO.File]::Open((Join-Path $Dir 'publish.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] {
        if (-not $Retry -and $Kind -in @('final', 'crash')) {
            # Другая отправка успела занять папку. Даже если процесс сейчас закончится,
            # досылка должна знать реальный исход, а не объявлять завершённый прогон оборванным.
            $masked = Protect-GateReportText $Reason (Get-PublishSecrets -Settings $Settings -Token '')
            Save-GateReportJson (Join-Path $Dir 'end.pending') @{ kind = $Kind; reason = $masked }
        }
        return $false
    }
    try {
        $state = Get-PublishState $Dir
        if ($Retry -and $state['wanted'] -eq $Kind -and $state['sent'] -eq $Kind) { return $true }
        if ($state['wanted'] -ne $Kind -or $state['sent'] -eq $Kind) { $state['sentPart'] = 0 }
        $secrets = Get-PublishSecrets -Settings $Settings -Token ''
        $Reason = Protect-GateReportText $Reason $secrets
        $state['wanted'] = $Kind
        $state['message'] = $Reason
        Save-PublishState $Dir $state
        $token = ''
        try {
            $token = Get-PublishToken $TokenFile
            $filesLine = ''
            if ([string](Get-PublishSetting $Settings 'RunFilesRepo' '')) {
                $filesLine = Invoke-RunFilesUpload -Dir $Dir -Kind $Kind -State $state -Settings $Settings -Token $token
                Save-PublishState $Dir $state
            }
            Send-ReportParts $Dir $Kind $Reason $filesLine $Repo $token $secrets $state
            $state['sent'] = $Kind
            $state['error'] = ''
            Save-PublishState $Dir $state
            Write-Host ("Итог прогона {0} ушёл в GitHub ({1})." -f (Split-Path -Leaf $Dir), $Repo) -ForegroundColor DarkGray
            Write-PublishLog $Dir ("Итог прогона ушёл в GitHub ({0}): {1}" -f $Repo, $Kind)
            return $true
        }
        catch {
            $state['error'] = Protect-GateReportText $_.Exception.Message $secrets -LiteralValues @($token)
            Save-PublishState $Dir $state
            Write-Host ("Итог прогона {0} в GitHub не ушёл: {1}. После исправления запустите publish.ps1 -Pending с тем же профилем. Гейт также повторит отправку при следующем запуске." -f (Split-Path -Leaf $Dir), $state['error']) -ForegroundColor Yellow
            Write-PublishLog $Dir ("Итог прогона в GitHub не ушёл ({0}): {1}" -f $Kind, $state['error'])
            return $false
        }
    } finally { $lease.Dispose() }
}

#endregion

function Watch-RunProgress {
    # Только один файл конкретного прогона. Итог и runs/latest.txt по-прежнему принадлежат штатной публикации.
    param([string]$Dir, [hashtable]$Settings)
    $repo = [string](Get-PublishSetting $Settings 'RunFilesRepo' '')
    $branch = [string](Get-PublishSetting $Settings 'RunFilesBranch' 'gate-runs')
    $id = Split-Path -Leaf $Dir
    if (-not $repo -or $branch -in @('main', 'master') -or $id -notmatch '^\d{8}-\d{6}$') { return }
    $previous = $null
    $failed = $false
    while ((Test-RunAlive $Dir) -and -not (Test-Path -LiteralPath (Join-Path $Dir 'verdict.json'))) {
        try {
            $log = Join-Path $Dir 'run.log'
            $lines = @('Промежуточный журнал прогона ' + $id)
            if (Test-Path -LiteralPath $log) {
                $lines += @(Get-Content -Encoding UTF8 -LiteralPath $log -Tail 20 -ErrorAction Stop | ForEach-Object { [string]$_ })
            }
            $content = $lines -join [Environment]::NewLine
            if ($content -cne $previous) {
                $token = Get-PublishToken ([string](Get-PublishSetting $Settings 'GitHubTokenPassFile' ''))
                $secrets = Get-PublishSecrets -Settings $Settings -Token $token
                # Убираем строку целиком до обрезки: в Git не попадёт даже начало найденного пароля.
                $safe = foreach ($line in $lines) {
                    $masked = Protect-GateReportText $line $secrets
                    if ($masked -cne $line) { '[строка скрыта]' } else { $line.Substring(0, [Math]::Min(512, $line.Length)) }
                }
                $gh = New-GhContext -Repo $repo -Token $token
                $head = Get-GhHead -Gh $gh -Branch $branch
                if ($head.Empty) { throw 'Репозиторий пуст' }
                $change = [pscustomobject]@{ Path = "live/$id.txt"; Bytes = $Utf8NoBom.GetBytes(($safe -join [Environment]::NewLine)) }
                $commit = New-GhCommit -Gh $gh -Parent $head.Sha -Changes @($change) -Message ("Ход прогона {0}" -f $id)
                if ($head.Sha) { Set-GhBranch -Gh $gh -Branch $branch -Sha $commit }
                else { Set-GhBranch -Gh $gh -Branch $branch -Sha $commit -Create }
                $previous = $content
                $failed = $false
            }
        } catch {
            if (-not $failed) { Write-PublishLog $Dir 'Промежуточный журнал не отправлен. При следующем опросе будет повтор.' }
            $failed = $true
        }
        Start-Sleep -Seconds 60
    }
}

$configFile = $Config
if ([string]::IsNullOrWhiteSpace($configFile)) { $configFile = Join-Path $Root 'config.psd1' }
if (-not (Test-Path -LiteralPath $configFile)) { return }
$cfg = Read-PublishConfig $configFile
# ** Хлебников С.Ю. 20261124 Отдельная ветка журнала операций работает и без issue для итогов.
if ($WatchOperations -or $Pending) {
    . (Join-Path $Root 'post-update.ps1') # ** Хлебников С.Ю. 20261124 Краткое описание ошибки действия.
    . (Join-Path $Root 'operations.ps1')
    if ($WatchOperations) { Watch-GateOperations $cfg; return }
    Start-OperationSender $cfg $configFile
}
# ** Хлебников С.Ю. 20261124 конец
$repoName = [string](Get-PublishSetting $cfg 'RunReportRepo' '')
if (-not $repoName) { return }
$tokenFile = [string](Get-PublishSetting $cfg 'GitHubTokenPassFile' '')

if ($OperationDir) { $null = Publish-Operation $OperationDir $repoName $tokenFile $cfg; return }

if ($WatchProgress) { Watch-RunProgress -Dir $RunDir -Settings $cfg; return }

if ($Pending) {
    # Не ушедшее: прогоны с pid.txt (их запускал гейт с отправкой итогов), процесс которых уже не живёт, а итог
    # не отправлен до конца. Старше двух недель не трогаем. Первый сбой связи - дальше не пробуем.
    $runsRoot = Get-GateReportRoot $cfg
    if (-not (Test-Path -LiteralPath $runsRoot)) { return }
    $operations = Join-Path $runsRoot 'operations'
    if (Test-Path -LiteralPath $operations) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $operations -Directory | Sort-Object Name)) {
            if (-not [IO.File]::Exists((Join-Path $dir.FullName 'operation.json'))) { continue }
            if (-not (Publish-Operation $dir.FullName $repoName $tokenFile $cfg -Recover)) { break }
        }
    }
    $border = (Get-Date).AddDays(-14)
    $candidates = @(Get-ChildItem -LiteralPath $runsRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
            Sort-Object Name | Select-Object -Last 30 | Where-Object {
                $pidFile = Join-Path $_.FullName 'pid.txt'
                (Test-Path -LiteralPath $pidFile) -and (Get-Item -LiteralPath $pidFile).LastWriteTime -ge $border
            })
    # Файлы прогона досылаются, только если их уже пробовали отправить (filesWanted): прогоны до включения
    # RunFilesRepo задним числом не выкладываются.
    $filesOn = [bool][string](Get-PublishSetting $cfg 'RunFilesRepo' '')
    foreach ($candidate in $candidates) {
        $launch = Read-TextFile (Join-Path $candidate.FullName 'run-launch.json')
        if ($launch) {
            $destination = Get-JsonText ($launch | ConvertFrom-Json) 'repo'
            if ($destination -and $destination -ne $repoName) { continue }
        }
        $state = Get-PublishState $candidate.FullName
        $wanted = $state['wanted']
        $reason = $state['message']
        $deferred = Read-TextFile (Join-Path $candidate.FullName 'end.pending')
        if ($deferred) {
            $saved = $deferred | ConvertFrom-Json
            $wanted = $saved.kind
            $reason = $saved.reason
        }
        $finished = @('final', 'crash', 'broken') -contains $wanted
        $eventDone = $finished -and $state['sent'] -eq $wanted
        $filesPending = $filesOn -and $state['filesWanted'] -and $state['filesSent'] -ne $state['filesWanted']
        if ($eventDone -and -not $filesPending) { continue }
        if (Test-RunAlive $candidate.FullName) { continue }
        if ($eventDone) {
            $filesSent = Publish-PendingRunFiles -Dir $candidate.FullName -TokenFile $tokenFile -Settings $cfg
            if (-not $filesSent) { break }
            continue
        }
        $kind = 'broken'
        if ($finished) { $kind = $wanted }
        $sent = Publish-Run -Dir $candidate.FullName -Kind $kind -Reason $reason -Repo $repoName -TokenFile $tokenFile -Settings $cfg -Retry
        if (-not $sent) { break }
    }
    return
}

if (-not $RunDir -or -not (Test-Path -LiteralPath $RunDir)) { throw ("Не найдена папка прогона {0}. Укажите в -RunDir существующую папку этого прогона." -f $RunDir) }
$null = Publish-Run -Dir $RunDir -Kind $Stage -Reason $Message -Repo $repoName -TokenFile $tokenFile -Settings $cfg
