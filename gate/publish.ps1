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
    [switch]$Pending,
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
$RunFilesSkipDirs = @('kit', 'inbox', 'before', 'reference', 'epf')
$RunFilesMaxFileBytes = 20MB
$RunFilesMaxTotalBytes = 100MB
$RunFilesMaxCount = 1000
# Секрет короче этого не ищем: короткие гейт сам прячет в журналах («***»), а короткая строка находится где попало.
$RunFilesMinSecretLength = 6

# Клиент GitHub: голова ветки, коммит, ветка; подставной GitHub для тестов - CI_FAKE_GITHUB.
. (Join-Path $Root 'github.ps1')

#region Настройки и токен

function Read-PublishConfig {
    # config.psd1 и config.site.psd1 - как в run.ps1: ключа нет в config.psd1 или он там пустой - из config.site.psd1.
    param([string]$Path)
    $read = Import-PowerShellDataFile -LiteralPath $Path
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

function Get-PublishSetting {
    param([hashtable]$Settings, [string]$Key, $Default)
    if ($Settings.ContainsKey($Key) -and $null -ne $Settings[$Key] -and [string]$Settings[$Key] -ne '') { return $Settings[$Key] }
    return $Default
}

function Get-PublishToken {
    # Токен GitHub из файла DPAPI (как пароли гейта). В вывод и журналы не попадает.
    param([string]$PassFile)
    if (-not $PassFile) { throw 'нет токена GitHub: «Настройки - Обновление гейта и git», GitHubTokenPassFile' }
    $path = $PassFile
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Root $path }
    if (-not (Test-Path -LiteralPath $path)) { throw ("нет файла токена {0}: «Настройки - Обновление гейта и git», GitHubTokenPassFile" -f $path) }
    $encrypted = (Get-Content -LiteralPath $path -Raw).Trim()
    $credential = New-Object System.Management.Automation.PSCredential('token', (ConvertTo-SecureString -String $encrypted))
    return $credential.GetNetworkCredential().Password.Trim()
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
    $state = [ordered]@{ wanted = ''; sent = ''; message = ''; error = ''; time = ''; filesWanted = ''; filesSent = ''; filesError = '' }
    $text = Read-TextFile (Join-Path $Dir 'publish.json')
    if ($text) {
        try {
            $read = $text | ConvertFrom-Json
            foreach ($name in @('wanted', 'sent', 'message', 'error', 'time', 'filesWanted', 'filesSent', 'filesError')) {
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
    [System.IO.File]::WriteAllText((Join-Path $Dir 'publish.json'), (ConvertTo-Json -InputObject $State), $Utf8Bom)
}

function Test-RunAlive {
    # Жив ли процесс прогона: pid.txt - «номер|время старта процесса». Номер мог достаться другому процессу -
    # тогда время старта не совпадёт.
    param([string]$Dir)
    $text = (Read-TextFile (Join-Path $Dir 'pid.txt')).Trim()
    if (-not $text) { return $false }
    $parts = $text.Split('|')
    $processId = 0
    if (-not [int]::TryParse($parts[0], [ref]$processId)) { return $false }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    if ($parts.Count -lt 2) { return $true }
    try { return ($process.StartTime.ToString('o') -eq $parts[1]) } catch { return $true }
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

function Get-TailText {
    param([string]$Text, [int]$Lines)
    $all = @($Text -split "`r?`n")
    if ($all.Count -le $Lines) { return $Text.TrimEnd() }
    return ((@('…') + @($all | Select-Object -Last $Lines)) -join "`n").TrimEnd()
}

function Limit-Text {
    # Не длиннее Chars символов; обрезанное - с пометкой, где полный текст.
    param([string]$Text, [int]$Chars, [string]$FileName)
    if ($Text.Length -le $Chars) { return $Text }
    return ($Text.Substring(0, [Math]::Max(0, $Chars)).TrimEnd() + ("`n… обрезано: полный {0} - в папке прогона" -f $FileName))
}

function New-RunReport {
    # Итог прогона для комментария: заголовок, сведения, summary.txt (или шаги, что успели), хвост run.log
    # (при остановке и обрыве), report.txt под катом. Limits - сколько символов оставить от длинных частей.
    # FilesLine - строка со ссылкой на файлы прогона в git (пусто - выкладка выключена): сразу под сведениями,
    # чтобы её не съело урезание длинных частей.
    param([string]$Dir, [string]$Kind, [string]$Reason, [hashtable]$Limits, [string]$FilesLine = '')
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
        $body.Add((Limit-Text $summary.TrimEnd() $Limits['summary'] 'summary.txt'))
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
            $body.Add((Limit-Text ($stepLines -join "`n") $Limits['summary'] 'steps.jsonl'))
            $body.Add('````')
        }
        else { $body.Add('Ни один шаг не успел закончиться.') }
    }

    if ($Kind -eq 'crash' -or $Kind -eq 'broken') {
        $log = Read-TextFile (Join-Path $Dir 'run.log')
        if ($log) {
            $body.Add('')
            $body.Add('<details><summary>Конец run.log</summary>')
            $body.Add('')
            $body.Add('````text')
            $body.Add((Limit-Text (Get-TailText $log 40) $Limits['log'] 'run.log'))
            $body.Add('````')
            $body.Add('</details>')
        }
    }

    $report = Read-TextFile (Join-Path $Dir 'report.txt')
    if ($report -and $Limits['report'] -gt 0) {
        $body.Add('')
        $body.Add('<details><summary>Разбор прогона (report.txt)</summary>')
        $body.Add('')
        $body.Add('````text')
        $body.Add((Limit-Text $report.TrimEnd() $Limits['report'] 'report.txt'))
        $body.Add('````')
        $body.Add('</details>')
    }
    elseif ($report) {
        $body.Add('')
        $body.Add('Разбор прогона (report.txt) не влез - он в папке прогона.')
    }
    $body.Add('')
    $body.Add(('Папка прогона: ' + (ConvertTo-InlineCode $Dir)))

    $verdictForEvent = $verdictCode
    if ($Kind -eq 'crash' -or $Kind -eq 'broken') { $verdictForEvent = $Kind.ToUpperInvariant() }
    return [pscustomobject]@{ Title = ('{0} · {1}' -f $title, $id); Verdict = $verdictForEvent; Body = ($body -join "`n") }
}

function New-RunPayload {
    # Тело события: укладываем в предел, урезая сначала report.txt, потом хвост журнала и итог.
    param([string]$Dir, [string]$Kind, [string]$Reason, [string]$FilesLine = '')
    $limits = @{ report = 40000; summary = 15000; log = 6000 }
    for ($try = 0; $try -lt 8; $try++) {
        $report = New-RunReport -Dir $Dir -Kind $Kind -Reason $Reason -Limits $limits -FilesLine $FilesLine
        $payload = [ordered]@{
            event_type     = 'gate-run'
            client_payload = [ordered]@{ run = (Split-Path -Leaf $Dir); stage = $Kind; verdict = $report.Verdict; title = $report.Title; body = $report.Body }
        }
        $json = ConvertTo-Json -InputObject $payload -Depth 4 -Compress
        $size = $Utf8NoBom.GetByteCount($json)
        if ($size -le $PayloadLimitBytes) { return $json }
        $ratio = [double]$PayloadLimitBytes / $size * 0.9
        if ($limits['report'] -gt 500) { $limits['report'] = [int]($limits['report'] * $ratio) - 500; if ($limits['report'] -lt 500) { $limits['report'] = 0 } }
        else { $limits['report'] = 0; $limits['summary'] = [int]($limits['summary'] * $ratio); $limits['log'] = [int]($limits['log'] * $ratio) }
    }
    throw 'итог прогона не уложился в предел события GitHub'
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

function Read-PublishSecretFile {
    # Пароль из файла DPAPI; не читается - пусто (секрет, которого гейт сам не прочтёт, в журнал не попадёт).
    param([string]$PassFile)
    $path = $PassFile
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Root $path }
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $encrypted = [string](Get-Content -LiteralPath $path -Raw)
        if (-not $encrypted.Trim()) { return '' }
        $credential = New-Object System.Management.Automation.PSCredential('secret', (ConvertTo-SecureString -String $encrypted.Trim()))
        return $credential.GetNetworkCredential().Password
    }
    catch { return '' }
}

function Get-PublishSecrets {
    # Чего не должно быть в выложенных файлах: токен GitHub, пароли из файлов *PassFile (и у пользователей вроде
    # CanaryUsers - PassFile в таблице), код разрешения входа UnlockCode. Name - имя настройки, значение не выводится.
    param([hashtable]$Settings, [string]$Token)
    $found = New-Object System.Collections.Generic.List[object]
    if ($Token) { $found.Add([pscustomobject]@{ Name = 'GitHubTokenPassFile'; Value = $Token }) }
    foreach ($key in @($Settings.Keys | Sort-Object)) {
        $value = $Settings[$key]
        if ($key -like '*PassFile' -and $key -ne 'GitHubTokenPassFile' -and $value -is [string] -and $value) {
            $found.Add([pscustomobject]@{ Name = $key; Value = (Read-PublishSecretFile $value) })
        }
        foreach ($item in @($value)) {
            if ($item -is [hashtable] -and $item.ContainsKey('PassFile') -and [string]$item['PassFile']) {
                $found.Add([pscustomobject]@{ Name = ('{0}.PassFile' -f $key); Value = (Read-PublishSecretFile ([string]$item['PassFile'])) })
            }
        }
    }
    $unlock = [string](Get-PublishSetting $Settings 'UnlockCode' '')
    if ($unlock) { $found.Add([pscustomobject]@{ Name = 'UnlockCode'; Value = $unlock }) }
    $long = New-Object System.Collections.Generic.List[object]
    foreach ($item in $found) { if (([string]$item.Value).Length -ge $RunFilesMinSecretLength) { $long.Add($item) } }
    # Запятая - чтобы пустой список или список из одного не развернулся при возврате.
    return , $long
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
    foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        if (-not $file.FullName.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $parts = @($file.FullName.Substring($rootFull.Length + 1) -split '[\\/]')
        $relative = $parts -join '/'
        # README.md папки в git пишет сам гейт (New-RunFilesReadme).
        if ($relative -eq 'README.md') { continue }
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
            if ($text.Contains([string]$secret.Value) -or $ansiText.Contains([string]$secret.Value)) {
                $leak = [string]$secret.Name
                break
            }
        }
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
    param([string]$Dir, [string]$Id, [string]$Kind, $List)
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
    return , $Utf8NoBom.GetBytes((($lines -join "`n") + "`n"))
}

function Publish-RunFiles {
    # Файлы прогона - в ветку Branch репозитория Repo, папка runs/<прогон>/, и runs/latest.txt - последний
    # прогон (по имени папки: повторная отправка старого прогона его не перебивает). Только изменённые файлы.
    # Ветки нет - создаётся сиротой (main не трогается). Ветку подвинули между чтением и записью - ещё раз от
    # новой головы. Возвращает Url, Changed (сколько файлов в коммите), Skipped, Secrets.
    param([string]$Dir, [string]$Kind, [string]$Repo, [string]$Branch, [string]$Token, [hashtable]$Settings)
    $id = Split-Path -Leaf $Dir
    $gh = New-GhContext -Repo $Repo -Token $Token
    $list = Get-RunFileList -Dir $Dir -Id $id -Secrets (Get-PublishSecrets -Settings $Settings -Token $Token)
    $readme = [pscustomobject]@{ Path = ('runs/{0}/README.md' -f $id); Bytes = (New-RunFilesReadme -Dir $Dir -Id $id -Kind $Kind -List $list) }
    $result = [pscustomobject]@{ Url = (Get-RunFilesUrl -Repo $Repo -Branch $Branch -Id $id); Changed = 0; Skipped = $list.Skipped.Count; Secrets = $list.Secrets }
    for ($try = 1; $try -le 2; $try++) {
        $head = Get-GhHead -Gh $gh -Branch $Branch
        if ($head.Empty) { throw ('в репозитории {0} ещё нет ни одного коммита - файлы прогона класть некуда' -f $Repo) }
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
        $State['filesError'] = $_.Exception.Message
        Write-Host ("Файлы прогона {0} в git не ушли: {1}. Уйдут при следующем запуске гейта." -f $id, $_.Exception.Message) -ForegroundColor Yellow
        Write-PublishLog $Dir ("Файлы прогона в git не ушли ({0}): {1}" -f $Kind, $_.Exception.Message)
        return ('**Файлы прогона в git не ушли:** {0}. Уйдут при следующем запуске гейта, сюда: {1}' -f $_.Exception.Message, $url)
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
    $url = 'https://api.github.com/repos/{0}/dispatches' -f $Repo
    if ($env:CI_FAKE_HTTP) {
        $auth = 'нет'
        if ($Token) { $auth = 'да' }
        [System.IO.File]::AppendAllText((Join-Path $env:CI_FAKE_HTTP 'requests.log'), ("POST {0} токен={1}`r`n" -f $url, $auth), $Utf8NoBom)
        if (Test-Path -LiteralPath (Join-Path $env:CI_FAKE_HTTP 'dispatch-fail.txt')) { throw 'нет связи с api.github.com: подставной сбой' }
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

function Publish-Run {
    # Отправить итог одного прогона. Возвращает $true, если ушло. Сбой - в выводе и в run.log, не исключением.
    # Файлы прогона (RunFilesRepo) уходят до события: ссылка на них - в тексте итога; их сбой событию не мешает.
    param([string]$Dir, [string]$Kind, [string]$Reason, [string]$Repo, [string]$TokenFile, [hashtable]$Settings = @{})
    $state = Get-PublishState $Dir
    $state['wanted'] = $Kind
    $state['message'] = $Reason
    Save-PublishState $Dir $state
    try {
        $token = Get-PublishToken $TokenFile
        $filesLine = ''
        if ([string](Get-PublishSetting $Settings 'RunFilesRepo' '')) {
            $filesLine = Invoke-RunFilesUpload -Dir $Dir -Kind $Kind -State $state -Settings $Settings -Token $token
            Save-PublishState $Dir $state
        }
        $json = New-RunPayload -Dir $Dir -Kind $Kind -Reason $Reason -FilesLine $filesLine
        Send-RunEvent -Repo $Repo -Token $token -Json $json
        $state['sent'] = $Kind
        $state['error'] = ''
        Save-PublishState $Dir $state
        Write-Host ("Итог прогона {0} ушёл в GitHub ({1})." -f (Split-Path -Leaf $Dir), $Repo) -ForegroundColor DarkGray
        Write-PublishLog $Dir ("Итог прогона ушёл в GitHub ({0}): {1}" -f $Repo, $Kind)
        return $true
    }
    catch {
        $state['error'] = $_.Exception.Message
        Save-PublishState $Dir $state
        Write-Host ("Итог прогона {0} в GitHub не ушёл: {1}. Уйдёт при следующем запуске гейта." -f (Split-Path -Leaf $Dir), $_.Exception.Message) -ForegroundColor Yellow
        Write-PublishLog $Dir ("Итог прогона в GitHub не ушёл ({0}): {1}" -f $Kind, $_.Exception.Message)
        return $false
    }
}

#endregion

$configFile = $Config
if ([string]::IsNullOrWhiteSpace($configFile)) { $configFile = Join-Path $Root 'config.psd1' }
if (-not (Test-Path -LiteralPath $configFile)) { return }
$cfg = Read-PublishConfig $configFile
$repoName = [string](Get-PublishSetting $cfg 'RunReportRepo' '')
if (-not $repoName) { return }
$tokenFile = [string](Get-PublishSetting $cfg 'GitHubTokenPassFile' '')

if ($Pending) {
    # Не ушедшее: прогоны с pid.txt (их запускал гейт с отправкой итогов), процесс которых уже не живёт, а итог
    # не отправлен до конца. Старше двух недель не трогаем. Первый сбой связи - дальше не пробуем.
    $runsSetting = [string](Get-PublishSetting $cfg 'RunsDir' 'runs')
    $runsRoot = $runsSetting
    if (-not [System.IO.Path]::IsPathRooted($runsRoot)) { $runsRoot = Join-Path $Root $runsRoot }
    if (-not (Test-Path -LiteralPath $runsRoot)) { return }
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
        $state = Get-PublishState $candidate.FullName
        $finished = @('final', 'crash', 'broken') -contains $state['wanted']
        $eventDone = $finished -and $state['sent'] -eq $state['wanted']
        $filesPending = $filesOn -and $state['filesWanted'] -and $state['filesSent'] -ne $state['filesWanted']
        if ($eventDone -and -not $filesPending) { continue }
        if (Test-RunAlive $candidate.FullName) { continue }
        if ($eventDone) {
            $filesSent = Publish-PendingRunFiles -Dir $candidate.FullName -TokenFile $tokenFile -Settings $cfg
            if (-not $filesSent) { break }
            continue
        }
        $kind = 'broken'
        if ($finished) { $kind = $state['wanted'] }
        $sent = Publish-Run -Dir $candidate.FullName -Kind $kind -Reason $state['message'] -Repo $repoName -TokenFile $tokenFile -Settings $cfg
        if (-not $sent) { break }
    }
    return
}

if (-not $RunDir -or -not (Test-Path -LiteralPath $RunDir)) { throw ("нет папки прогона: {0}" -f $RunDir) }
$null = Publish-Run -Dir $RunDir -Kind $Stage -Reason $Message -Repo $repoName -TokenFile $tokenFile -Settings $cfg
