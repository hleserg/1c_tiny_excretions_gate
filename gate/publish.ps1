#requires -Version 5.1
<#
Итог прогона гейта - в GitHub. Гейт шлёт событие repository_dispatch «gate-run» в репозиторий RunReportRepo,
а комментарий в issue «Прогоны гейта» пишет workflow этого репозитория (бот GitHub Actions) и упоминает
владельца: о своих же действиях GitHub не уведомляет, а гейт ходит с токеном человека. Пример workflow -
docs/gate-runs.workflow.yml. Версия 00000000.000000.

  .\publish.ps1 -RunDir <папка прогона> -Stage verdict|final|crash [-Message <причина>]
        verdict - вердикт есть, ждём решения по комплекту; final - прогон закончен; crash - скрипт остановился
  .\publish.ps1 -Pending
        отправить то, что не ушло: прогон оборвался (процесс сняли, окно закрыли - «broken») или не было связи

Что хотели отправить и что ушло - publish.json в папке прогона; живой ли процесс прогона - pid.txt.
Сбой отправки прогон не портит: итог уйдёт при следующем запуске гейта (run.ps1 и nightly.ps1 зовут -Pending).
Токен - GitHubTokenPassFile, право Contents: write на RunReportRepo. Уходит только в api.github.com.
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
    param([string]$Dir)
    $state = [ordered]@{ wanted = ''; sent = ''; message = ''; error = ''; time = '' }
    $text = Read-TextFile (Join-Path $Dir 'publish.json')
    if ($text) {
        try {
            $read = $text | ConvertFrom-Json
            foreach ($name in @('wanted', 'sent', 'message', 'error', 'time')) {
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
    param([string]$Dir, [string]$Kind, [string]$Reason, [hashtable]$Limits)
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
    param([string]$Dir, [string]$Kind, [string]$Reason)
    $limits = @{ report = 40000; summary = 15000; log = 6000 }
    for ($try = 0; $try -lt 8; $try++) {
        $report = New-RunReport -Dir $Dir -Kind $Kind -Reason $Reason -Limits $limits
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
    param([string]$Dir, [string]$Kind, [string]$Reason, [string]$Repo, [string]$TokenFile)
    $state = Get-PublishState $Dir
    $state['wanted'] = $Kind
    $state['message'] = $Reason
    Save-PublishState $Dir $state
    try {
        $token = Get-PublishToken $TokenFile
        $json = New-RunPayload -Dir $Dir -Kind $Kind -Reason $Reason
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
    foreach ($candidate in $candidates) {
        $state = Get-PublishState $candidate.FullName
        $finished = @('final', 'crash', 'broken') -contains $state['wanted']
        if ($finished -and $state['sent'] -eq $state['wanted']) { continue }
        if (Test-RunAlive $candidate.FullName) { continue }
        $kind = 'broken'
        if ($finished) { $kind = $state['wanted'] }
        $sent = Publish-Run -Dir $candidate.FullName -Kind $kind -Reason $state['message'] -Repo $repoName -TokenFile $tokenFile
        if (-not $sent) { break }
    }
    return
}

if (-not $RunDir -or -not (Test-Path -LiteralPath $RunDir)) { throw ("нет папки прогона: {0}" -f $RunDir) }
$null = Publish-Run -Dir $RunDir -Kind $Stage -Reason $Message -Repo $repoName -TokenFile $tokenFile
