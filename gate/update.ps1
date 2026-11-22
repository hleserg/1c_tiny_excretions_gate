#requires -Version 5.1
<#
Обновление гейта из релизов GitHub: комплекты собирает CI репозитория площадки после зелёных тестов и выкладывает
релизом (тег <UpdateTagPrefix><версия>, файл ci-gate_<версия>.zip). Git на машине гейта не нужен: только HTTPS
до api.github.com и токен (файл GitHubTokenPassFile, зашифрован DPAPI под учёткой Windows). Версия 00000000.000000.

  .\update.ps1              список релизов, выбрать и поставить (новее, тот же или старее - откат)
  .\update.ps1 -Latest      без вопросов: последний релиз, если он новее установленного
  .\update.ps1 -Tag <тег>   поставить этот релиз
  .\update.ps1 -List        только показать релизы
Ставит install.ps1 из скачанного комплекта (без вопросов): свои данные (config.psd1, runs, baseline, secrets ...)
не трогаются. Работающий ci.exe переименовывается в ci.exe.old - после обновления ci нужно перезапустить (из меню
гейта - кнопкой «Перезапустить ci»).
#>
[CmdletBinding()]
param(
    [string]$Tag = '',
    [switch]$Latest,
    [switch]$Startup,
    [switch]$List,
    [string]$Config = '',
    [string]$UiChannel = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($UiChannel) {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $ProgressPreference = 'SilentlyContinue'
}
$Root = $PSScriptRoot
. (Join-Path $Root 'ui.ps1')
Initialize-Ui -Channel $UiChannel

#region Настройки и токен

function Read-UpdateConfig {
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

function Get-UpdateSetting {
    param([hashtable]$Settings, [string]$Key, $Default)
    if ($Settings.ContainsKey($Key) -and $null -ne $Settings[$Key] -and [string]$Settings[$Key] -ne '') { return $Settings[$Key] }
    return $Default
}

function Get-UpdateToken {
    # Токен GitHub из файла DPAPI (как пароли гейта). В вывод и журналы не попадает.
    param([string]$PassFile)
    if (-not $PassFile) { return '' }
    $path = $PassFile
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Root $path }
    if (-not (Test-Path -LiteralPath $path)) {
        throw ("нет файла токена {0}: введи токен в «Настройки - Обновление гейта и git» (GitHubTokenPassFile)" -f $path)
    }
    $encrypted = (Get-Content -LiteralPath $path -Raw).Trim()
    $credential = New-Object System.Management.Automation.PSCredential('token', (ConvertTo-SecureString -String $encrypted))
    # Пробел или перевод строки по краям (скопировали со страницы вместе с ним) - GitHub ответит 401.
    return $credential.GetNetworkCredential().Password.Trim()
}

#endregion

#region HTTP

function Invoke-UpdateHttp {
    # GET: строка ответа или файл (OutFile). Переадресации - вручную: токен уходит только на исходный адрес
    # (скачивание файла релиза переадресует на хранилище GitHub, туда токен не нужен и не передаётся).
    # Подставной GitHub для тестов: переменная CI_FAKE_HTTP - папка, ответ на адрес - файл с именем адреса
    # (не буквы и цифры - «_»), «REDIRECT <адрес>» в файле - переадресация; запросы пишутся в requests.log.
    param([string]$Url, [string]$Accept = 'application/vnd.github+json', [string]$Token = '', [string]$OutFile = '')
    $current = $Url
    $sendToken = [bool]$Token
    for ($hop = 0; $hop -lt 6; $hop++) {
        if ($env:CI_FAKE_HTTP) {
            $name = [regex]::Replace($current, '[^A-Za-z0-9.\-]', '_')
            $file = Join-Path $env:CI_FAKE_HTTP $name
            $auth = 'нет'
            if ($sendToken) { $auth = 'да' }
            [System.IO.File]::AppendAllText((Join-Path $env:CI_FAKE_HTTP 'requests.log'), ("GET {0} токен={1} accept={2}`r`n" -f $current, $auth, $Accept), (New-Object System.Text.UTF8Encoding($false)))
            if (-not (Test-Path -LiteralPath $file)) { throw ("GitHub ответил 404 на {0}" -f $current) }
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $head = [System.Text.Encoding]::UTF8.GetString($bytes, 0, [Math]::Min(9, $bytes.Length))
            if ($head -eq 'REDIRECT ') {
                $current = ([System.Text.Encoding]::UTF8.GetString($bytes)).Substring(9).Trim()
                $sendToken = $false
                continue
            }
            if ($OutFile) { [System.IO.File]::WriteAllBytes($OutFile, $bytes); return $OutFile }
            return [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
        }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $request = [System.Net.HttpWebRequest]::Create($current)
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'ci-gate'
        $request.Accept = $Accept
        if ($Startup -and -not $OutFile) {
            $request.Timeout = 4000
            $request.ReadWriteTimeout = 4000
        } else {
            $request.Timeout = 60000
            $request.ReadWriteTimeout = 300000
        }
        if ($null -ne $request.Proxy) { $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
        if ($sendToken) {
            $request.Headers['Authorization'] = 'Bearer ' + $Token
            $request.Headers['X-GitHub-Api-Version'] = '2022-11-28'
        }
        $response = $null
        try { $response = $request.GetResponse() }
        catch {
            $exception = $_.Exception
            while ($null -ne $exception -and -not ($exception -is [System.Net.WebException])) { $exception = $exception.InnerException }
            if ($null -eq $exception -or $null -eq $exception.Response) { throw ("нет связи с {0}: {1}" -f ([uri]$current).Host, $_.Exception.Message) }
            $response = $exception.Response
        }
        try {
            $code = [int]$response.StatusCode
            if ($code -ge 300 -and $code -lt 400) {
                $next = $response.Headers['Location']
                if (-not $next) { throw ("GitHub ответил {0} без адреса переадресации" -f $code) }
                if (([uri]$next).Host -ne ([uri]$current).Host) { $sendToken = $false }
                $current = $next
                continue
            }
            $stream = $response.GetResponseStream()
            if ($code -ge 400) {
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $message = $body
                try { $message = [string](ConvertFrom-Json $body).message } catch { $message = $body }
                $hint = ''
                if ($code -eq 401) { $hint = ': токен не подходит или истёк' }
                elseif ($code -eq 404) { $hint = ': нет такого репозитория или у токена нет к нему доступа' }
                throw ("GitHub ответил {0}{1} ({2})" -f $code, $hint, $message)
            }
            if ($OutFile) {
                $target = [System.IO.File]::Create($OutFile)
                try { $stream.CopyTo($target) } finally { $target.Dispose() }
                return $OutFile
            }
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            return $reader.ReadToEnd()
        }
        finally { $response.Close() }
    }
    throw ("слишком много переадресаций: {0}" -f $Url)
}

#endregion

#region Релизы

function Get-InstalledVersion {
    # Версия установленного гейта - из заголовка run.ps1 («Версия ГГГГММДД.ЧЧММСС.»).
    $runScript = Join-Path $Root 'run.ps1'
    if (-not (Test-Path -LiteralPath $runScript)) { return '' }
    $head = @(Get-Content -LiteralPath $runScript -Encoding UTF8 -TotalCount 80) -join "`n"
    $found = [regex]::Match($head, 'Версия (\d{8}\.\d{6})\.')
    if ($found.Success) { return $found.Groups[1].Value }
    return ''
}

function Get-GateReleases {
    # Релизы гейта (не черновики) с файлом ci-gate_*.zip, новые первыми: Tag, Version, Date, Notes, Asset.
    param([string]$Api, [string]$Repo, [string]$Prefix, [string]$Token)
    $text = Invoke-UpdateHttp -Url ('{0}/repos/{1}/releases?per_page=30' -f $Api.TrimEnd('/'), $Repo) -Token $Token
    $result = New-Object System.Collections.Generic.List[object]
    # Без @() вокруг ConvertFrom-Json: в PowerShell 5.1 массив JSON выходит одним объектом - получился бы массив в массиве.
    $parsed = ConvertFrom-Json $text
    foreach ($release in @($parsed)) {
        if ($release.draft) { continue }
        if ($Startup -and (($release.PSObject.Properties['prerelease'] -and $release.prerelease) -or
                ([string]$release.tag_name -notmatch ('^' + [regex]::Escape($Prefix) + '\d{8}\.\d{6}$')))) { continue }
        $tagName = [string]$release.tag_name
        if (-not $tagName.StartsWith($Prefix)) { continue }
        $asset = $null
        foreach ($candidate in @($release.assets)) { if ([string]$candidate.name -like 'ci-gate_*.zip') { $asset = $candidate; break } }
        if ($null -eq $asset) { continue }
        $digest = ''
        if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest) { $digest = [string]$asset.digest }
        $notes = ''
        if ($release.PSObject.Properties.Name -contains 'body' -and $release.body) { $notes = [string]$release.body }
        $result.Add([pscustomobject]@{
                Tag = $tagName; Version = $tagName.Substring($Prefix.Length); Date = [string]$release.published_at; Notes = $notes
                AssetUrl = [string]$asset.url; AssetName = [string]$asset.name; Digest = $digest; Size = [long]$asset.size
            })
    }
    return , @($result.ToArray() | Sort-Object Version -Descending)
}

function Get-FileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose(); $sha.Dispose() }
    return (-join @($hash | ForEach-Object { $_.ToString('x2') }))
}

function Install-GateRelease {
    # Скачать комплект релиза, проверить, распаковать в updates\<тег> и поставить его install.ps1 в эту папку.
    param($Release, [string]$Token)
    $updates = Join-Path $Root 'updates'
    $dir = Join-Path $updates $Release.Tag
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $zip = Join-Path $dir $Release.AssetName
    Write-Host ("Скачиваю {0} ({1:N1} МБ)..." -f $Release.AssetName, ($Release.Size / 1MB))
    $null = Invoke-UpdateHttp -Url $Release.AssetUrl -Accept 'application/octet-stream' -Token $Token -OutFile $zip
    if ($Release.Digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $expected = $Matches[1].ToLowerInvariant()
        $actual = Get-FileSha256 $zip
        if ($actual -ne $expected) { throw ("контрольная сумма {0} не та: {1}, в релизе {2}" -f $Release.AssetName, $actual, $expected) }
        Write-Host 'Контрольная сумма совпала.' -ForegroundColor Green
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $unpacked = Join-Path $dir 'kit'
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $unpacked, [System.Text.Encoding]::UTF8)
    $installer = Join-Path $unpacked 'install.ps1'
    if (-not (Test-Path -LiteralPath $installer) -or -not (Test-Path -LiteralPath (Join-Path $unpacked 'ci\run.ps1'))) {
        throw ("в {0} нет install.ps1 и ci\run.ps1 - это не комплект гейта" -f $Release.AssetName)
    }
    # Работающий ci.exe заменить нельзя, а переименовать - можно: новый ляжет рядом, старый уйдёт при следующем обновлении.
    $exe = Join-Path $Root 'ci.exe'
    if (Test-Path -LiteralPath $exe) {
        $old = Join-Path $Root 'ci.exe.old'
        if (Test-Path -LiteralPath $old) {
            try { Remove-Item -LiteralPath $old -Force } catch { $old = Join-Path $Root ('ci.exe.old-{0:yyyyMMddHHmmss}' -f (Get-Date)) }
        }
        Move-Item -LiteralPath $exe -Destination $old -Force
    }
    # Установщик - в этом же процессе: вывод идёт в ci.exe той же кодировкой (дочерний powershell писал бы в OEM).
    Write-Host ("Ставлю {0} в {1}..." -f $Release.Tag, $Root)
    & $installer -Target $Root -Unattended
    $record = "{0}`t{1:yyyy-MM-dd HH:mm:ss}`t{2}`r`n" -f $Release.Tag, (Get-Date), $env:USERNAME
    [System.IO.File]::AppendAllText((Join-Path $updates 'installed.txt'), $record, (New-Object System.Text.UTF8Encoding($true)))
}

#endregion

$configPath = $Config
if (-not $configPath) { $configPath = Join-Path $Root 'config.psd1' }
$exitCode = 0
try {
    if (-not (Test-Path -LiteralPath $configPath)) { throw "нет файла настроек: $configPath" }
    $cfg = Read-UpdateConfig -Path $configPath
    $repo = [string](Get-UpdateSetting $cfg 'UpdateRepo' '')
    if (-not $repo) { throw 'не задан UpdateRepo (владелец/репозиторий с релизами гейта): «Настройки - Обновление гейта и git»' }
    $api = [string](Get-UpdateSetting $cfg 'UpdateApi' 'https://api.github.com')
    $prefix = [string](Get-UpdateSetting $cfg 'UpdateTagPrefix' 'gate-')
    $token = Get-UpdateToken ([string](Get-UpdateSetting $cfg 'GitHubTokenPassFile' ''))
    $installed = Get-InstalledVersion
    $releases = Get-GateReleases -Api $api -Repo $repo -Prefix $prefix -Token $token
    if ($releases.Count -eq 0) { throw ("в {0} нет релизов {1}* с комплектом ci-gate_*.zip" -f $repo, $prefix) }
    $newest = $releases[0]
    $installedText = $installed
    if (-not $installedText) { $installedText = 'неизвестно' }
    Write-Host ("Гейт: установлен {0}, последний в {1} - {2}" -f $installedText, $repo, $newest.Version)

    $chosen = $null
    if ($Startup) {
        if ($installed -and $newest.Version -gt $installed -and
            (Confirm-Ui -Question ("Доступен гейт {0}, установлен {1}. Обновить сейчас?" -f $newest.Version, $installed) -Yes 'Обновить' -No 'Продолжить' -DefaultNo)) {
            $chosen = $newest
        }
    }
    elseif ($List) {
        foreach ($release in $releases) {
            $mark = ''
            if ($release.Version -eq $installed) { $mark = ' [установлен]' }
            Write-Host ('  {0}  {1}{2}' -f $release.Version, $release.Date, $mark)
        }
    }
    elseif ($Tag) {
        $chosen = @($releases | Where-Object { $_.Tag -eq $Tag -or $_.Version -eq $Tag }) | Select-Object -First 1
        if ($null -eq $chosen) { throw ("релиза {0} нет среди последних в {1}" -f $Tag, $repo) }
    }
    elseif ($Latest) {
        if ($installed -and $newest.Version -le $installed) { Write-Host ('Обновлять нечего: стоит {0}.' -f $installed) -ForegroundColor Green }
        else { $chosen = $newest }
    }
    else {
        $shown = @($releases | Select-Object -First 12)
        $labels = @($shown | ForEach-Object {
                $mark = ''
                if ($_.Version -eq $installed) { $mark = ' - установлен' }
                elseif ($installed -and $_.Version -gt $installed) { $mark = ' - новее' }
                elseif ($installed) { $mark = ' - старее (откат)' }
                $date = $_.Date
                if ($date.Length -ge 16) { $date = $date.Substring(0, 16).Replace('T', ' ') }
                '{0} ({1}){2}' -f $_.Version, $date, $mark
            }) + @('Отмена')
        $notes = @(('Установлен: {0}. Ставится установщиком комплекта без вопросов, свои данные остаются.' -f $installedText))
        $index = Select-UiOne -Header ('Обновление гейта из {0}' -f $repo) -Items $labels -Notes $notes
        if ($index -ge 0 -and $index -lt $shown.Count) {
            $candidate = $shown[$index]
            $lines = @(('{0}, опубликован {1}' -f $candidate.Tag, $candidate.Date), '') + @($candidate.Notes.Replace("`r", '').Split("`n"))
            Show-UiPager -Lines $lines -Header ('Что в {0}' -f $candidate.Version)
            $question = 'Поставить {0}?' -f $candidate.Version
            if ($installed -and $candidate.Version -lt $installed) { $question = 'Поставить более старый {0} вместо {1} (откат)?' -f $candidate.Version, $installed }
            if (Confirm-Ui -Question $question -Default $true) { $chosen = $candidate }
        }
    }
    if ($null -ne $chosen) {
        Install-GateRelease -Release $chosen -Token $token
        Write-Host ''
        Write-Host ("Гейт обновлён до {0}. Работает ещё прежний: новый - после перезапуска ci." -f $chosen.Version) -ForegroundColor Green
        $exitCode = 10
    }
}
catch {
    Write-Host ("Обновление не вышло: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $exitCode = 1
}
exit $exitCode
