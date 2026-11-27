#requires -Version 5.1
<#
Клиент GitHub для гейта: репозиторий без git на машине, только HTTPS до api.github.com (REST). Подключается
точкой (deploy.ps1). Функции принимают контекст New-GhContext: репозиторий, токен, подставной GitHub.

Что умеет: голова ветки (и пустой ли репозиторий), файлы коммита (путь -> git-хеш блоба), git-хеш файла локально,
коммит изменений поверх родителя (только изменённые файлы: текст - прямо
в дереве, двоичные - блобами), ветка, pull request, «содержит ли ветка коммит», скачивание файлов коммита
(архив zipball, токен - только в API: на адрес скачивания не уходит).

Подставной GitHub для тестов: переменная CI_FAKE_GITHUB - папка, репозиторий в ней файлами: refs.json (ветка ->
коммит), commits\<хеш>.txt (родитель, сообщение, строки «путь<TAB>хеш блоба»), blobs\<хеш>, pulls.txt
(номер, ветка, куда, заголовок), pulls\<номер>.md; каждое действие - строкой в requests.log.

Большие репозитории (выгрузка типовой конфигурации, десятки тысяч файлов) через REST не пролезают: для них -
портативный git (MinGit из релизов git-for-windows, скачивается в tools\git без установки и прав администратора)
и Invoke-GitCli. Токен - заголовком через переменные окружения GIT_CONFIG_*, не в командной строке.
Подставные: CI_FAKE_GIT_EXE - готовый git.exe (без скачивания), CI_FAKE_HTTP - ответы на адреса файлами (как у
update.ps1), CI_FAKE_GIT_REMOTE - адрес удалённого репозитория вместо github.com (папка bare-репозитория).
Версия 00000000.000000.
#>

#region Общее

function New-GhContext {
    param([string]$Repo, [string]$Token)
    if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw ("репозиторий GitHub «{0}» - не в виде владелец/имя" -f $Repo) }
    return [pscustomobject]@{ Repo = $Repo; Token = $Token; FakeDir = [string]$env:CI_FAKE_GITHUB }
}

function ConvertTo-GhJsonString {
    # Строка JSON с кавычками. Свой экранировщик: ConvertTo-Json в PowerShell 5.1 медленный на больших телах
    # и по-своему экранирует символы.
    param([string]$Text)
    if ($null -eq $Text) { return 'null' }
    # Встроенные замены строк, а не цикл по символам: на выгрузке расширения это мегабайты текста.
    $escaped = $Text.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    if ($escaped -match '[\x00-\x1f]') {
        $escaped = [regex]::Replace($escaped, '[\x00-\x1f]', { param($found) '\u{0:x4}' -f [int][char]$found.Value })
    }
    return '"' + $escaped + '"'
}

function ConvertFrom-GhJsonString {
    # Значение строки JSON (без кавычек): \" \\ \/ \b \f \n \r \t \uXXXX.
    param([string]$Text)
    if ($Text.IndexOf('\') -lt 0) { return $Text }
    $builder = New-Object System.Text.StringBuilder $Text.Length
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -ne '\' -or $i + 1 -ge $Text.Length) { [void]$builder.Append($ch); continue }
        $i++
        switch ($Text[$i]) {
            'n' { [void]$builder.Append("`n") }
            'r' { [void]$builder.Append("`r") }
            't' { [void]$builder.Append("`t") }
            'b' { [void]$builder.Append([char]8) }
            'f' { [void]$builder.Append([char]12) }
            'u' { [void]$builder.Append([char][Convert]::ToInt32($Text.Substring($i + 1, 4), 16)); $i += 4 }
            default { [void]$builder.Append($Text[$i]) }
        }
    }
    return $builder.ToString()
}

function Get-GitBlobSha {
    # Хеш, под которым git хранит содержимое файла: SHA-1 от «blob <длина>\0<байты>».
    param([byte[]]$Bytes)
    $header = [System.Text.Encoding]::ASCII.GetBytes(('blob {0}' -f $Bytes.Length) + [char]0)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        [void]$sha.TransformBlock($header, 0, $header.Length, $null, 0)
        [void]$sha.TransformFinalBlock($Bytes, 0, $Bytes.Length)
        return ([System.BitConverter]::ToString($sha.Hash).Replace('-', '').ToLowerInvariant())
    }
    finally { $sha.Dispose() }
}

function Test-GhTextBytes {
    # Текст в UTF-8 без нулевых байтов - его можно положить в дерево прямо строкой; иначе - блобом.
    param([byte[]]$Bytes)
    if ([Array]::IndexOf($Bytes, [byte]0) -ge 0) { return $false }
    try { [void](New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes); return $true } catch { return $false }
}

function Write-GhFakeLog {
    param($Gh, [string]$Text)
    [System.IO.File]::AppendAllText((Join-Path $Gh.FakeDir 'requests.log'), ($Text + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

#endregion

#region HTTP

function Invoke-GhApi {
    # Запрос к api.github.com. Возвращает Status и Text (тело ответа). AllowStatus - коды, которые не ошибка
    # (404 - нет ветки, 409 - пустой репозиторий). Прокси - системный, с учёткой Windows.
    param($Gh, [string]$Method, [string]$Path, [string]$Body = '', [int[]]$AllowStatus = @())
    $url = 'https://api.github.com' + $Path
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = $Method
    $request.AllowAutoRedirect = $false
    $request.UserAgent = 'ci-gate'
    $request.Accept = 'application/vnd.github+json'
    $request.Timeout = 120000
    $request.ReadWriteTimeout = 300000
    if ($null -ne $request.Proxy) { $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
    if ($Gh.Token) { $request.Headers['Authorization'] = 'Bearer ' + $Gh.Token }
    $request.Headers['X-GitHub-Api-Version'] = '2022-11-28'
    $response = $null
    try {
        if ($Body) {
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Body)
            $request.ContentType = 'application/json; charset=utf-8'
            $request.ContentLength = $bytes.Length
            $stream = $request.GetRequestStream()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
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
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        if ($code -ge 300 -and $AllowStatus -notcontains $code) {
            $apiText = $text
            $found = [regex]::Match($text, '"message"\s*:\s*"((?:[^"\\]|\\.)*)"')
            if ($found.Success) { $apiText = ConvertFrom-GhJsonString $found.Groups[1].Value }
            $hint = ''
            if ($code -eq 401) { $hint = ': токен не подходит или истёк' }
            elseif ($code -eq 403 -or $code -eq 404) { $hint = (': у токена нет прав на {0} (нужны Contents и Pull requests: чтение и запись) или нет такого репозитория' -f $Gh.Repo) }
            throw ("GitHub ответил {0} на {1} {2}{3} ({4})" -f $code, $Method, $Path, $hint, $apiText)
        }
        return [pscustomobject]@{ Status = $code; Text = $text; Location = [string]$response.Headers['Location'] }
    }
    finally { $response.Close() }
}

function Get-GhJsonValue {
    # Первое значение «"ключ": "строка"» в тексте JSON (для коротких ответов, где ключ однозначен).
    param([string]$Text, [string]$Key)
    $found = [regex]::Match($Text, ('"{0}"\s*:\s*"((?:[^"\\]|\\.)*)"' -f [regex]::Escape($Key)))
    if (-not $found.Success) { return '' }
    return (ConvertFrom-GhJsonString $found.Groups[1].Value)
}

#endregion

#region Подставной GitHub

function Read-GhFakeRefs {
    param($Gh)
    $refs = @{}
    $path = Join-Path $Gh.FakeDir 'refs.json'
    if (Test-Path -LiteralPath $path) {
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            $parts = $line.Split("`t")
            if ($parts.Count -eq 2 -and $parts[0]) { $refs[$parts[0]] = $parts[1] }
        }
    }
    return $refs
}

function Save-GhFakeRefs {
    param($Gh, [hashtable]$Refs)
    $lines = @($Refs.Keys | Sort-Object | ForEach-Object { '{0}{1}{2}' -f $_, "`t", $Refs[$_] })
    [System.IO.File]::WriteAllLines((Join-Path $Gh.FakeDir 'refs.json'), [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-GhFakeCommit {
    param($Gh, [string]$Sha)
    $path = Join-Path (Join-Path $Gh.FakeDir 'commits') ($Sha + '.txt')
    if (-not (Test-Path -LiteralPath $path)) { throw ("подставной GitHub: нет коммита {0}" -f $Sha) }
    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
    $files = @{}
    for ($i = 2; $i -lt $lines.Count; $i++) {
        $parts = $lines[$i].Split("`t")
        if ($parts.Count -eq 2) { $files[$parts[0]] = $parts[1] }
    }
    $parents = @($lines[0].Split(' ') | Where-Object { $_ })
    $first = ''
    if ($parents.Count -gt 0) { $first = $parents[0] }
    return [pscustomobject]@{ Parent = $first; Parents = $parents; Message = $lines[1]; Files = $files }
}

function Get-GhFakeAncestors {
    # Все предки коммита (и он сам) по обоим родителям: хеш -> расстояние.
    param($Gh, [string]$Sha)
    $seen = @{}
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@($Sha, 0))
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if (-not $item[0] -or $seen.ContainsKey($item[0])) { continue }
        $seen[$item[0]] = $item[1]
        foreach ($parent in (Read-GhFakeCommit $Gh $item[0]).Parents) { $queue.Enqueue(@($parent, ($item[1] + 1))) }
    }
    return $seen
}

function New-GhFakeCommit {
    param($Gh, [string]$Parent, [string]$Message, [hashtable]$Files)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($Parent)
    $lines.Add(($Message -replace "`r?`n", ' '))
    foreach ($path in @($Files.Keys | Sort-Object)) { $lines.Add(('{0}{1}{2}' -f $path, "`t", $Files[$path])) }
    $text = ($lines -join "`n") + "`n" + [guid]::NewGuid().ToString()
    $sha = Get-GitBlobSha ([System.Text.Encoding]::UTF8.GetBytes($text))
    $dir = Join-Path $Gh.FakeDir 'commits'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllLines((Join-Path $dir ($sha + '.txt')), [string[]]$lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    return $sha
}

function Save-GhFakeBlob {
    param($Gh, [byte[]]$Bytes)
    $sha = Get-GitBlobSha $Bytes
    $dir = Join-Path $Gh.FakeDir 'blobs'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir $sha
    if (-not (Test-Path -LiteralPath $path)) { [System.IO.File]::WriteAllBytes($path, $Bytes) }
    return $sha
}

#endregion

#region Операции

function Get-GhHead {
    # Голова ветки: Sha ('' - ветки нет) и Empty (в репозитории ещё нет ни одного коммита).
    param($Gh, [string]$Branch)
    if ($Gh.FakeDir) {
        $refs = Read-GhFakeRefs $Gh
        Write-GhFakeLog $Gh ("head {0}" -f $Branch)
        $head = ''
        if ($refs.ContainsKey($Branch)) { $head = $refs[$Branch] }
        return [pscustomobject]@{ Sha = $head; Empty = ($refs.Count -eq 0) }
    }
    $answer = Invoke-GhApi -Gh $Gh -Method 'GET' -Path ('/repos/{0}/git/ref/heads/{1}' -f $Gh.Repo, $Branch) -AllowStatus @(404, 409)
    if ($answer.Status -eq 409) { return [pscustomobject]@{ Sha = ''; Empty = $true } }
    if ($answer.Status -eq 404) { return [pscustomobject]@{ Sha = ''; Empty = $false } }
    $found = [regex]::Match($answer.Text, '"object"\s*:\s*\{[^}]*"sha"\s*:\s*"([0-9a-f]{40})"')
    if (-not $found.Success) { throw ("GitHub: не понял ответ про ветку {0}" -f $Branch) }
    return [pscustomobject]@{ Sha = $found.Groups[1].Value; Empty = $false }
}

function Get-GhFiles {
    # Файлы коммита: путь (через /) -> git-хеш блоба. Дерево читается целиком одним запросом (recursive);
    # ответ разбирается без ConvertFrom-Json: на большом дереве он медленный и упирается в предел длины.
    param($Gh, [string]$Commit)
    if ($Gh.FakeDir) {
        Write-GhFakeLog $Gh ("files {0}" -f $Commit)
        return (Read-GhFakeCommit $Gh $Commit).Files
    }
    $answer = Invoke-GhApi -Gh $Gh -Method 'GET' -Path ('/repos/{0}/git/trees/{1}?recursive=1' -f $Gh.Repo, $Commit)
    if ($answer.Text -match '"truncated"\s*:\s*true') { throw 'GitHub отдал дерево не целиком (слишком большое)' }
    $files = @{}
    $entries = [regex]::Matches($answer.Text, '\{"path":"((?:[^"\\]|\\.)*)","mode":"(\d+)","type":"(\w+)","sha":"([0-9a-f]{40})"')
    foreach ($entry in $entries) {
        if ($entry.Groups[3].Value -ne 'blob') { continue }
        $files[(ConvertFrom-GhJsonString $entry.Groups[1].Value)] = $entry.Groups[4].Value
    }
    return $files
}

function Add-GhTreePortion {
    # Порция дерева поверх BaseTree (пусто - с нуля). Возвращает хеш нового дерева.
    param($Gh, [string]$BaseTree, $Entries)
    $body = '{'
    if ($BaseTree) { $body += '"base_tree":"' + $BaseTree + '",' }
    $body += '"tree":[' + (@($Entries) -join ',') + ']}'
    $answer = Invoke-GhApi -Gh $Gh -Method 'POST' -Path ('/repos/{0}/git/trees' -f $Gh.Repo) -Body $body
    $sha = Get-GhJsonValue $answer.Text 'sha'
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'GitHub: не понял ответ на дерево' }
    return $sha
}

function New-GhCommit {
    # Коммит поверх Parent: Changes - список Path (через /) и Bytes ($null - удалить файл). Ветки не двигает,
    # возвращает хеш коммита. Текст идёт прямо в дерево порциями (дерево поверх дерева), двоичное - блобами.
    param($Gh, [string]$Parent, $Changes, [string]$Message)
    if ($Gh.FakeDir) {
        $files = @{}
        if ($Parent) { $files = (Read-GhFakeCommit $Gh $Parent).Files }
        foreach ($change in $Changes) {
            if ($null -eq $change.Bytes) { $files.Remove($change.Path) }
            else { $files[$change.Path] = Save-GhFakeBlob $Gh ([byte[]]$change.Bytes) }
        }
        $sha = New-GhFakeCommit -Gh $Gh -Parent $Parent -Message $Message -Files $files
        Write-GhFakeLog $Gh ("commit {0} parent={1} changes={2}" -f $sha, $Parent, @($Changes).Count)
        return $sha
    }
    $treeSha = ''
    if ($Parent) {
        $answer = Invoke-GhApi -Gh $Gh -Method 'GET' -Path ('/repos/{0}/git/commits/{1}' -f $Gh.Repo, $Parent)
        $found = [regex]::Match($answer.Text, '"tree"\s*:\s*\{\s*"sha"\s*:\s*"([0-9a-f]{40})"')
        if (-not $found.Success) { throw ("GitHub: не нашёл дерево коммита {0}" -f $Parent) }
        $treeSha = $found.Groups[1].Value
    }
    $entries = New-Object System.Collections.Generic.List[string]
    $portion = 0
    foreach ($change in $Changes) {
        $pathJson = ConvertTo-GhJsonString $change.Path
        if ($null -eq $change.Bytes) {
            $entries.Add(('{"path":' + $pathJson + ',"mode":"100644","type":"blob","sha":null}'))
        }
        elseif (Test-GhTextBytes ([byte[]]$change.Bytes)) {
            $text = (New-Object System.Text.UTF8Encoding($false)).GetString([byte[]]$change.Bytes)
            $entries.Add(('{"path":' + $pathJson + ',"mode":"100644","type":"blob","content":' + (ConvertTo-GhJsonString $text) + '}'))
            $portion += $text.Length
        }
        else {
            $blobBody = '{"encoding":"base64","content":"' + [Convert]::ToBase64String([byte[]]$change.Bytes) + '"}'
            $blobAnswer = Invoke-GhApi -Gh $Gh -Method 'POST' -Path ('/repos/{0}/git/blobs' -f $Gh.Repo) -Body $blobBody
            $entries.Add(('{"path":' + $pathJson + ',"mode":"100644","type":"blob","sha":"' + (Get-GhJsonValue $blobAnswer.Text 'sha') + '"}'))
            $portion += 200
        }
        # Порция дерева - до ~4 МБ текста или 400 файлов: один большой запрос GitHub может не принять.
        if ($portion -gt 4000000 -or $entries.Count -ge 400) {
            $treeSha = Add-GhTreePortion -Gh $Gh -BaseTree $treeSha -Entries $entries.ToArray()
            $entries.Clear()
            $portion = 0
        }
    }
    if ($entries.Count -gt 0) { $treeSha = Add-GhTreePortion -Gh $Gh -BaseTree $treeSha -Entries $entries.ToArray() }
    if (-not $treeSha) { throw 'нечего коммитить: нет ни дерева родителя, ни изменений' }
    $parents = '[]'
    if ($Parent) { $parents = '["' + $Parent + '"]' }
    $commitBody = '{"message":' + (ConvertTo-GhJsonString $Message) + ',"tree":"' + $treeSha + '","parents":' + $parents + '}'
    $commit = Invoke-GhApi -Gh $Gh -Method 'POST' -Path ('/repos/{0}/git/commits' -f $Gh.Repo) -Body $commitBody
    $sha = Get-GhJsonValue $commit.Text 'sha'
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'GitHub: не понял ответ на коммит' }
    return $sha
}

function Set-GhBranch {
    # Ветку - на коммит. Create - новая ветка; иначе - перемотка вперёд (без force: чужие коммиты не теряются).
    # Force - перенос на любой коммит: только для своих веток (пересборка кандидата поставки поверх нового main).
    param($Gh, [string]$Branch, [string]$Sha, [switch]$Create, [switch]$Force)
    if ($Gh.FakeDir) {
        $refs = Read-GhFakeRefs $Gh
        if ($Create -and $refs.ContainsKey($Branch)) { throw ("подставной GitHub: ветка {0} уже есть" -f $Branch) }
        if (-not $Create -and -not $Force -and $refs.ContainsKey($Branch) -and -not (Test-GhContains -Gh $Gh -Branch '' -Commit $refs[$Branch] -Head $Sha)) {
            throw ("подставной GitHub: {0} не перематывается вперёд" -f $Branch)
        }
        $refs[$Branch] = $Sha
        Save-GhFakeRefs $Gh $refs
        Write-GhFakeLog $Gh ("ref {0} {1}" -f $Branch, $Sha)
        return
    }
    if ($Create) {
        $body = '{"ref":' + (ConvertTo-GhJsonString ('refs/heads/' + $Branch)) + ',"sha":"' + $Sha + '"}'
        [void](Invoke-GhApi -Gh $Gh -Method 'POST' -Path ('/repos/{0}/git/refs' -f $Gh.Repo) -Body $body)
        return
    }
    $forceText = 'false'
    if ($Force) { $forceText = 'true' }
    [void](Invoke-GhApi -Gh $Gh -Method 'PATCH' -Path ('/repos/{0}/git/refs/heads/{1}' -f $Gh.Repo, $Branch) -Body ('{"sha":"' + $Sha + '","force":' + $forceText + '}'))
}

function New-GhPull {
    # Pull request Head -> Base. Возвращает Number и Url.
    param($Gh, [string]$Head, [string]$Base, [string]$Title, [string]$Body)
    if ($Gh.FakeDir) {
        $list = Join-Path $Gh.FakeDir 'pulls.txt'
        $number = 1
        if (Test-Path -LiteralPath $list) { $number = @([System.IO.File]::ReadAllLines($list)).Count + 1 }
        [System.IO.File]::AppendAllText($list, ('{0}{1}{2}{1}{3}{1}{4}' -f $number, "`t", $Head, $Base, $Title) + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $dir = Join-Path $Gh.FakeDir 'pulls'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir ('{0}.md' -f $number)), $Body, (New-Object System.Text.UTF8Encoding($false)))
        Write-GhFakeLog $Gh ("pull {0} {1} -> {2}" -f $number, $Head, $Base)
        return [pscustomobject]@{ Number = $number; Url = ('https://github.com/{0}/pull/{1}' -f $Gh.Repo, $number) }
    }
    $body = '{"title":' + (ConvertTo-GhJsonString $Title) + ',"head":' + (ConvertTo-GhJsonString $Head) + ',"base":' + (ConvertTo-GhJsonString $Base) + ',"body":' + (ConvertTo-GhJsonString $Body) + '}'
    $answer = Invoke-GhApi -Gh $Gh -Method 'POST' -Path ('/repos/{0}/pulls' -f $Gh.Repo) -Body $body
    $number = [int](($answer.Text | ConvertFrom-Json).number)
    if ($number -lt 1) { throw 'GitHub не вернул номер созданного PR' }
    $url = ('https://github.com/{0}/pull/{1}' -f $Gh.Repo, $number)
    return [pscustomobject]@{ Number = [int]$number; Url = $url }
}

function Test-GhContains {
    # Есть ли коммит Commit в истории ветки Branch (или коммита Head). Слит ли PR - по этому.
    param($Gh, [string]$Branch, [string]$Commit, [string]$Head = '', [ref]$MergeBase)
    if ($Gh.FakeDir) {
        $current = $Head
        if (-not $current) {
            $refs = Read-GhFakeRefs $Gh
            if (-not $refs.ContainsKey($Branch)) { return $false }
            $current = $refs[$Branch]
        }
        $ancestors = Get-GhFakeAncestors $Gh $current
        if ($null -ne $MergeBase) {
            $from = Get-GhFakeAncestors $Gh $Commit
            $MergeBase.Value = $from.Keys | Where-Object { $ancestors.ContainsKey($_) } | Sort-Object { $from[$_] } | Select-Object -First 1
        }
        return $ancestors.ContainsKey($Commit)
    }
    $target = $Head
    if (-not $target) { $target = $Branch }
    $answer = Invoke-GhApi -Gh $Gh -Method 'GET' -Path ('/repos/{0}/compare/{1}...{2}?per_page=1' -f $Gh.Repo, $Commit, $target) -AllowStatus @(404)
    if ($answer.Status -eq 404) { return $false }
    if ($null -ne $MergeBase) {
        $common = [regex]::Match($answer.Text, '"merge_base_commit"\s*:\s*\{\s*"sha"\s*:\s*"([0-9a-f]{40})"')
        if ($common.Success) { $MergeBase.Value = $common.Groups[1].Value }
    }
    $found = [regex]::Match($answer.Text, '"status"\s*:\s*"(ahead|behind|identical|diverged)"\s*,\s*"ahead_by"')
    if (-not $found.Success) { throw 'GitHub: не понял ответ сравнения коммитов' }
    return (@('ahead', 'identical') -contains $found.Groups[1].Value)
}

function Get-GhBlobBytes {
    # Содержимое блоба байт в байт (Accept: raw) - когда файл из архива не совпал по хешу.
    param($Gh, [string]$Sha)
    $request = [System.Net.HttpWebRequest]::Create(('https://api.github.com/repos/{0}/git/blobs/{1}' -f $Gh.Repo, $Sha))
    $request.UserAgent = 'ci-gate'
    $request.Accept = 'application/vnd.github.raw'
    $request.Timeout = 120000
    $request.ReadWriteTimeout = 300000
    if ($null -ne $request.Proxy) { $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
    if ($Gh.Token) { $request.Headers['Authorization'] = 'Bearer ' + $Gh.Token }
    $request.Headers['X-GitHub-Api-Version'] = '2022-11-28'
    $response = $request.GetResponse()
    try {
        $memory = New-Object System.IO.MemoryStream
        $response.GetResponseStream().CopyTo($memory)
        return , $memory.ToArray()
    }
    finally { $response.Close() }
}

function Save-GhFiles {
    # Файлы коммита с путями, начинающимися на один из Prefixes, - в папку Target с той же раскладкой.
    # Настоящий GitHub - одним архивом (zipball): переадресация на codeload без токена. Архив GitHub собирает
    # с правилами .gitattributes (концы строк), поэтому каждый файл сверяется с хешем из дерева (Expected:
    # путь -> хеш, Get-GhFiles того же коммита); не совпал - берётся блобом байт в байт.
    param($Gh, [string]$Commit, [string[]]$Prefixes, [string]$Target, [hashtable]$Expected = @{})
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    $wanted = {
        param([string]$Path)
        foreach ($prefix in $Prefixes) { if ($Path.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return $true } }
        return $false
    }
    $saved = 0
    if ($Gh.FakeDir) {
        $files = (Read-GhFakeCommit $Gh $Commit).Files
        foreach ($path in @($files.Keys)) {
            if (-not (& $wanted $path)) { continue }
            $file = Join-Path $Target ($path.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            [System.IO.File]::WriteAllBytes($file, [System.IO.File]::ReadAllBytes((Join-Path (Join-Path $Gh.FakeDir 'blobs') $files[$path])))
            $saved++
        }
        Write-GhFakeLog $Gh ("download {0} files={1}" -f $Commit, $saved)
        return $saved
    }
    $answer = Invoke-GhApi -Gh $Gh -Method 'GET' -Path ('/repos/{0}/zipball/{1}' -f $Gh.Repo, $Commit) -AllowStatus @(302)
    if ($answer.Status -ne 302 -or -not $answer.Location) { throw 'GitHub не дал адрес архива коммита' }
    $zip = Join-Path $Target '..\commit.zip'
    $zip = [System.IO.Path]::GetFullPath($zip)
    $request = [System.Net.HttpWebRequest]::Create($answer.Location)
    $request.UserAgent = 'ci-gate'
    $request.Timeout = 120000
    $request.ReadWriteTimeout = 600000
    if ($null -ne $request.Proxy) { $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
    $response = $request.GetResponse()
    try {
        $out = [System.IO.File]::Create($zip)
        try { $response.GetResponseStream().CopyTo($out) } finally { $out.Dispose() }
    }
    finally { $response.Close() }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($item in $archive.Entries) {
            $slash = $item.FullName.IndexOf('/')
            if ($slash -lt 0 -or $item.FullName.EndsWith('/')) { continue }
            # В архиве всё лежит в папке «владелец-имя-хеш/».
            $path = $item.FullName.Substring($slash + 1)
            if (-not (& $wanted $path)) { continue }
            $file = Join-Path $Target ($path.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($item, $file, $true)
            if ($Expected.ContainsKey($path) -and (Get-GitBlobSha ([System.IO.File]::ReadAllBytes($file))) -ne $Expected[$path]) {
                [System.IO.File]::WriteAllBytes($file, (Get-GhBlobBytes -Gh $Gh -Sha $Expected[$path]))
            }
            $saved++
        }
    }
    finally { $archive.Dispose() }
    Remove-Item -LiteralPath $zip -Force
    return $saved
}

#endregion

#region Pull request, проверки, история (приёмка поставок, раздел 5.26)

# Подставной GitHub: pulls\<номер>.closed - PR закрыт без слияния; ci.txt - строки «<head>\t<status>\t<conclusion>»,
# ci-default.txt - то же для всех остальных head («completed\tsuccess», «in_progress\t», «completed\tfailure»);
# pulls\<номер>.merge - «<base> <head> <merge>»: пробное слияние, которое GitHub держит для PR.

function Read-GhFakePulls {
    param($Gh)
    $list = Join-Path $Gh.FakeDir 'pulls.txt'
    $pulls = @()
    if (Test-Path -LiteralPath $list) {
        foreach ($line in [System.IO.File]::ReadAllLines($list, [System.Text.Encoding]::UTF8)) {
            $parts = $line.Split("`t")
            if ($parts.Count -ge 4) { $pulls += [pscustomobject]@{ Number = [int]$parts[0]; Head = $parts[1]; Base = $parts[2]; Title = $parts[3] } }
        }
    }
    return $pulls
}

function Get-GhFakeMerge {
    # Пробное слияние PR в подставном GitHub: base - предок head - слияние без конфликтов, дерево как у head;
    # иначе - конфликт (сам подставной GitHub трёхстороннего слияния не умеет). Кешируется, как у GitHub.
    param($Gh, [int]$Number, [string]$Base, [string]$Head)
    $file = Join-Path (Join-Path $Gh.FakeDir 'pulls') ('{0}.merge' -f $Number)
    if (Test-Path -LiteralPath $file) {
        $parts = ([System.IO.File]::ReadAllText($file)).Trim().Split(' ')
        if ($parts.Count -eq 3 -and $parts[0] -eq $Base -and $parts[1] -eq $Head) { return $parts[2] }
    }
    $ancestors = Get-GhFakeAncestors $Gh $Head
    if (-not $ancestors.ContainsKey($Base)) { return '' }
    $files = (Read-GhFakeCommit $Gh $Head).Files
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(($Base + ' ' + $Head))
    $lines.Add(('Merge pull request #{0}' -f $Number))
    foreach ($path in @($files.Keys | Sort-Object)) { $lines.Add(('{0}{1}{2}' -f $path, "`t", $files[$path])) }
    $text = ($lines -join "`n") + "`n"
    $sha = Get-GitBlobSha ([System.Text.Encoding]::UTF8.GetBytes($text))
    $dir = Join-Path $Gh.FakeDir 'commits'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllLines((Join-Path $dir ($sha + '.txt')), [string[]]$lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
    [System.IO.File]::WriteAllText($file, ('{0} {1} {2}' -f $Base, $Head, $sha))
    return $sha
}

function Get-GhPull {
    # Состояние PR: State (open, closed), Merged, Head, HeadRef, Base (sha текущей базы), BaseRef, Merge (пробное
    # слияние, пусто - GitHub его ещё не посчитал или конфликт), Mergeable ($true, $false, $null - не посчитано), Url.
    param($Gh, [int]$Number)
    if ($Gh.FakeDir) {
        $pull = @(Read-GhFakePulls $Gh | Where-Object { $_.Number -eq $Number }) | Select-Object -First 1
        if ($null -eq $pull) { throw ("подставной GitHub: нет PR #{0}" -f $Number) }
        $refs = Read-GhFakeRefs $Gh
        $head = ''
        if ($refs.ContainsKey($pull.Head)) { $head = $refs[$pull.Head] }
        $base = ''
        if ($refs.ContainsKey($pull.Base)) { $base = $refs[$pull.Base] }
        $merged = ($head -and $base -and (Get-GhFakeAncestors $Gh $base).ContainsKey($head))
        $state = 'open'
        if ($merged -or (Test-Path -LiteralPath (Join-Path (Join-Path $Gh.FakeDir 'pulls') ('{0}.closed' -f $Number)))) { $state = 'closed' }
        $merge = ''
        $mergeable = $false
        if ($state -eq 'open' -and $head -and $base) {
            $merge = Get-GhFakeMerge -Gh $Gh -Number $Number -Base $base -Head $head
            $mergeable = [bool]$merge
        }
        Write-GhFakeLog $Gh ("pull-get {0}" -f $Number)
        return [pscustomobject]@{ Number = $Number; State = $state; Merged = [bool]$merged; Head = $head; HeadRef = $pull.Head; Base = $base; BaseRef = $pull.Base
            Merge = $merge; Mergeable = $mergeable; Url = ('https://github.com/{0}/pull/{1}' -f $Gh.Repo, $Number); Title = $pull.Title }
    }
    $answer = Invoke-GhApi -Gh $Gh -Method 'GET' -Path ('/repos/{0}/pulls/{1}' -f $Gh.Repo, $Number)
    $pull = $answer.Text | ConvertFrom-Json
    $mergeable = $null
    if ($null -ne $pull.mergeable) { $mergeable = [bool]$pull.mergeable }
    $merge = ''
    if ($null -ne $pull.merge_commit_sha -and -not [bool]$pull.merged) { $merge = [string]$pull.merge_commit_sha }
    return [pscustomobject]@{ Number = [int]$pull.number; State = [string]$pull.state; Merged = [bool]$pull.merged; Head = [string]$pull.head.sha; HeadRef = [string]$pull.head.ref
        Base = [string]$pull.base.sha; BaseRef = [string]$pull.base.ref; Merge = $merge; Mergeable = $mergeable; Url = [string]$pull.html_url; Title = [string]$pull.title }
}

function Find-GhPull {
    # ** Хлебников С.Ю. 20261123 Для восстановления поставки ищем также слитый или закрытый PR.
    param($Gh, [string]$Head, [string]$Base, [switch]$IncludeClosed)
    if ($Gh.FakeDir) {
        foreach ($pull in @(Read-GhFakePulls $Gh | Where-Object { $_.Head -eq $Head -and $_.Base -eq $Base } | Sort-Object Number -Descending)) {
            if ($IncludeClosed -or (Get-GhPull -Gh $Gh -Number $pull.Number).State -eq 'open') { return [int]$pull.Number }
        }
        return 0
    }
    $owner = $Gh.Repo.Split('/')[0]
    $stateFilter = 'open'
    if ($IncludeClosed) { $stateFilter = 'all' }
    $answer = Invoke-GhApi -Gh $Gh -Method 'GET' -Path ('/repos/{0}/pulls?state={3}&base={1}&head={2}' -f $Gh.Repo, [uri]::EscapeDataString($Base), [uri]::EscapeDataString($owner + ':' + $Head), $stateFilter)
    $list = ConvertFrom-Json -InputObject $answer.Text
    if ($list.Count -gt 0) { return [int]$list[0].number }
    return 0
}

function Set-GhPullBody {
    # Текст PR (описание) заново: отчёт приёмки меняется с каждой пересборкой.
    param($Gh, [int]$Number, [string]$Body)
    if ($Gh.FakeDir) {
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $Gh.FakeDir 'pulls') ('{0}.md' -f $Number)), $Body, (New-Object System.Text.UTF8Encoding($false)))
        Write-GhFakeLog $Gh ("pull-body {0}" -f $Number)
        return
    }
    [void](Invoke-GhApi -Gh $Gh -Method 'PATCH' -Path ('/repos/{0}/pulls/{1}' -f $Gh.Repo, $Number) -Body ('{"body":' + (ConvertTo-GhJsonString $Body) + '}'))
}

function Add-GhComment {
    # Комментарий к PR или issue.
    param($Gh, [int]$Number, [string]$Body)
    if ($Gh.FakeDir) {
        $file = Join-Path (Join-Path $Gh.FakeDir 'pulls') ('{0}.comments.md' -f $Number)
        New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
        [System.IO.File]::AppendAllText($file, ($Body + "`r`n---`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-GhFakeLog $Gh ("comment {0}" -f $Number)
        return
    }
    [void](Invoke-GhApi -Gh $Gh -Method 'POST' -Path ('/repos/{0}/issues/{1}/comments' -f $Gh.Repo, $Number) -Body ('{"body":' + (ConvertTo-GhJsonString $Body) + '}'))
}

function Get-GhCiRun {
    # Последний прогон проверки PR (workflow Workflow) для head: Status (queued, in_progress, completed, '' - нет),
    # Conclusion (success, failure, ...), Title (у ERP static - «ERP static <merge sha>»), Url.
    param($Gh, [string]$Head, [string]$Workflow, [string]$Merge = '')
    if ($Gh.FakeDir) {
        $status = ''
        $conclusion = ''
        $default = Join-Path $Gh.FakeDir 'ci-default.txt'
        if (Test-Path -LiteralPath $default) {
            $parts = ([System.IO.File]::ReadAllText($default)).Trim().Split("`t")
            $status = $parts[0]
            if ($parts.Count -gt 1) { $conclusion = $parts[1] }
        }
        $list = Join-Path $Gh.FakeDir 'ci.txt'
        if (Test-Path -LiteralPath $list) {
            foreach ($line in [System.IO.File]::ReadAllLines($list)) {
                $parts = $line.Split("`t")
                if ($parts.Count -ge 2 -and $parts[0] -eq $Head) { $status = $parts[1]; $conclusion = ''; if ($parts.Count -gt 2) { $conclusion = $parts[2] } }
            }
        }
        Write-GhFakeLog $Gh ("ci {0} {1}/{2}" -f $Head, $status, $conclusion)
        return [pscustomobject]@{ Status = $status; Conclusion = $conclusion; Title = ('ERP static ' + $Merge); Url = 'https://github.com/fake/actions'; Id = 1 }
    }
    $answer = Invoke-GhApi -Gh $Gh -Method 'GET' -Path ('/repos/{0}/actions/runs?event=pull_request&head_sha={1}&per_page=50' -f $Gh.Repo, $Head)
    $runs = @(($answer.Text | ConvertFrom-Json).workflow_runs | Where-Object { [string]$_.path -eq $Workflow } | Sort-Object { [string]$_.created_at } -Descending)
    if ($runs.Count -eq 0) { return [pscustomobject]@{ Status = ''; Conclusion = ''; Title = ''; Url = ''; Id = 0 } }
    $run = $runs[0]
    return [pscustomobject]@{ Status = [string]$run.status; Conclusion = [string]$run.conclusion; Title = [string]$run.display_title; Url = [string]$run.html_url; Id = [long]$run.id }
}

function Test-GhPathInRange {
    # Ищем точные байты по тому же пути в принятых коммитах после общей основы снимка и ветки.
    # Ограничиваем число запросов. Если подтверждения нет, гейт сохраняет расхождение для разбора.
    param($Gh, [string]$Known, [string]$Head, [string]$Path, [scriptblock]$MatchesRevision)
    $base = ''
    $null = Test-GhContains -Gh $Gh -Branch '' -Commit $Known -Head $Head -MergeBase ([ref]$base)
    if (-not $base -or $base -eq $Head) { return $false }
    if ($Gh.FakeDir) {
        $candidates = @(Get-GhAncestors $Gh $Head)
    }
    else {
        $encoded = [uri]::EscapeDataString($Path)
        $answer = Invoke-GhApi $Gh GET ('/repos/{0}/commits?sha={1}&path={2}&per_page=20' -f $Gh.Repo, $Head, $encoded)
        $candidates = @(($answer.Text | ConvertFrom-Json) | ForEach-Object { $_.sha })
    }
    foreach ($revision in $candidates) {
        if ($revision -eq $base) { break }
        if ((& $MatchesRevision $revision) -and (Test-GhContains -Gh $Gh -Branch '' -Commit $base -Head $revision)) { return $true }
    }
    return $false
}

function Get-GhFileAtRevision {
    param($Gh, [string]$Revision, [string]$Path)
    if ($Gh.FakeDir) { return (Read-GhFakeCommit $Gh $Revision).Files[$Path] }
    $urlPath = ($Path.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $file = Invoke-GhApi $Gh GET ('/repos/{0}/contents/{1}?ref={2}' -f $Gh.Repo, $urlPath, $Revision) -AllowStatus @(404)
    if ($file.Status -eq 404) { return '' }
    return ($file.Text | ConvertFrom-Json).sha
}

function Get-GhAncestors {
    # Коммиты истории ветки или коммита (сам и предки, не больше Limit) - от новых к старым.
    param($Gh, [string]$Sha, [int]$Limit = 300)
    if ($Gh.FakeDir) {
        $seen = Get-GhFakeAncestors $Gh $Sha
        return @($seen.Keys | Sort-Object { $seen[$_] } | Select-Object -First $Limit)
    }
    $list = New-Object System.Collections.Generic.List[string]
    for ($page = 1; $list.Count -lt $Limit; $page++) {
        $answer = Invoke-GhApi -Gh $Gh -Method 'GET' -Path ('/repos/{0}/commits?sha={1}&per_page=100&page={2}' -f $Gh.Repo, $Sha, $page)
        $found = [regex]::Matches($answer.Text, '\{"sha":"([0-9a-f]{40})","node_id"')
        if ($found.Count -eq 0) { break }
        foreach ($match in $found) { if ($list.Count -lt $Limit) { $list.Add($match.Groups[1].Value) } }
        if ($found.Count -lt 100) { break }
    }
    return $list.ToArray()
}

function Get-GhBlob {
    # Содержимое блоба по git-хешу: подставной - файл blobs\<хеш>, настоящий - Get-GhBlobBytes.
    param($Gh, [string]$Sha)
    if ($Gh.FakeDir) { return , [System.IO.File]::ReadAllBytes((Join-Path (Join-Path $Gh.FakeDir 'blobs') $Sha)) }
    return , (Get-GhBlobBytes -Gh $Gh -Sha $Sha)
}

#endregion

#region Портативный git

function Invoke-GhDownload {
    # GET без токена (публичные релизы): строка ответа или файл (OutFile). Переадресации - вручную. Подставной:
    # CI_FAKE_HTTP - папка, ответ на адрес - файл с именем адреса (не буквы и цифры - «_»), «REDIRECT <адрес>» -
    # переадресация, запросы - в requests.log.
    param([string]$Url, [string]$Accept = 'application/vnd.github+json', [string]$OutFile = '')
    $current = $Url
    for ($hop = 0; $hop -lt 6; $hop++) {
        if ($env:CI_FAKE_HTTP) {
            $file = Join-Path $env:CI_FAKE_HTTP ([regex]::Replace($current, '[^A-Za-z0-9.\-]', '_'))
            [System.IO.File]::AppendAllText((Join-Path $env:CI_FAKE_HTTP 'requests.log'), ("GET {0} accept={1}`r`n" -f $current, $Accept), (New-Object System.Text.UTF8Encoding($false)))
            if (-not (Test-Path -LiteralPath $file)) { throw ("GitHub ответил 404 на {0}" -f $current) }
            $bytes = [System.IO.File]::ReadAllBytes($file)
            if ([System.Text.Encoding]::UTF8.GetString($bytes, 0, [Math]::Min(9, $bytes.Length)) -eq 'REDIRECT ') {
                $current = ([System.Text.Encoding]::UTF8.GetString($bytes)).Substring(9).Trim()
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
        $request.Timeout = 60000
        $request.ReadWriteTimeout = 300000
        if ($null -ne $request.Proxy) { $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
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
                $current = $next
                continue
            }
            if ($code -ge 400) { throw ("GitHub ответил {0} на {1}" -f $code, $current) }
            $stream = $response.GetResponseStream()
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

function Get-PortableGit {
    # git.exe для больших репозиториев: CI_FAKE_GIT_EXE (тесты); Exe (настройка GitExe) - если есть; tools\git\cmd\git.exe;
    # иначе - последний MinGit (64 бита, не busybox) из релизов git-for-windows: скачать, сверить sha256 (digest
    # файла релиза; нет его - отказ), распаковать в tools\git. Ни установки, ни прав администратора.
    param([string]$ToolsDir, [string]$Exe = '')
    if ($env:CI_FAKE_GIT_EXE) { return [string]$env:CI_FAKE_GIT_EXE }
    if ($Exe -and (Test-Path -LiteralPath $Exe)) { return $Exe }
    $gitRoot = Join-Path $ToolsDir 'git'
    $gitExe = Join-Path (Join-Path $gitRoot 'cmd') 'git.exe'
    if (Test-Path -LiteralPath $gitExe) { return $gitExe }
    $text = Invoke-GhDownload -Url 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $release = $text | ConvertFrom-Json
    $asset = @($release.assets | Where-Object { [string]$_.name -match '^MinGit-[0-9.]+(\.windows\.\d+)?-64-bit\.zip$' }) | Select-Object -First 1
    if ($null -eq $asset) { throw ('в последнем релизе git-for-windows ({0}) нет MinGit 64 бита: положи распакованный MinGit в {1} руками' -f $release.tag_name, $gitRoot) }
    $digest = ''
    if ($null -ne $asset.PSObject.Properties['digest']) { $digest = [string]$asset.digest }
    $digestFound = [regex]::Match($digest, '^sha256:([0-9a-fA-F]{64})$')
    if (-not $digestFound.Success) { throw ('у {0} в релизе нет контрольной суммы: не ставлю непроверенное. Положи распакованный MinGit в {1} руками' -f $asset.name, $gitRoot) }
    $expected = $digestFound.Groups[1].Value.ToLowerInvariant()
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
    $zip = Join-Path $ToolsDir ([string]$asset.name)
    $null = Invoke-GhDownload -Url ([string]$asset.url) -Accept 'application/octet-stream' -OutFile $zip
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($zip)
    try { $actual = -join @($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) } finally { $stream.Dispose(); $sha.Dispose() }
    if ($actual -ne $expected) { Remove-Item -LiteralPath $zip -Force; throw ('контрольная сумма {0} не та: {1}, в релизе {2}' -f $asset.name, $actual, $expected) }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $unpacked = $gitRoot + '.new'
    if (Test-Path -LiteralPath $unpacked) { Remove-Item -LiteralPath $unpacked -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $unpacked)
    Remove-Item -LiteralPath $zip -Force
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $unpacked 'cmd') 'git.exe'))) { Remove-Item -LiteralPath $unpacked -Recurse -Force; throw ('в {0} нет cmd\git.exe - это не MinGit' -f $asset.name) }
    if (Test-Path -LiteralPath $gitRoot) { Remove-Item -LiteralPath $gitRoot -Recurse -Force }
    Move-Item -LiteralPath $unpacked -Destination $gitRoot
    return $gitExe
}

function Invoke-GitCli {
    # git с отдельной папкой репозитория (GitDir) и рабочей папкой (WorkTree): выгрузку конфигуратор может стереть
    # и выгрузить заново целиком, репозиторий при этом цел. Token - заголовком для github.com через GIT_CONFIG_*
    # (в командной строке и журнале его нет). Возвращает ExitCode и Output (stdout и stderr). AllowFail - не бросать.
    # Title - долгая команда: строка «начато в ..., жду не дольше ...» и строка хода со временем, как у вызовов 1С;
    # просьба остановиться из ci.exe снимает git. Без Title - тихо (короткие команды).
    # Config - настройки git только для этого вызова («ключ=значение»).
    param([string]$Git, [string]$GitDir, [string]$WorkTree, [string[]]$Arguments, [string]$Token = '', [int]$TimeoutSec = 3600, [switch]$AllowFail, [string]$Title = '', [string[]]$Config = @())
    $all = @(('--git-dir=' + $GitDir), ('--work-tree=' + $WorkTree)) + @($Arguments)
    $quoted = @($all | ForEach-Object { if ([string]$_ -match '[\s"]') { '"' + ([string]$_).Replace('"', '\"') + '"' } else { [string]$_ } }) -join ' '
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Git
    $info.Arguments = $quoted
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $settings = New-Object System.Collections.Generic.List[string[]]
    $settings.Add(@('core.quotepath', 'false'))
    $settings.Add(@('core.autocrlf', 'false'))
    $settings.Add(@('core.longpaths', 'true'))
    $settings.Add(@('core.safecrlf', 'false'))
    $settings.Add(@('http.postBuffer', '524288000'))
    $settings.Add(@('credential.helper', ''))
    # Автоматическую упаковку после команд (gc --auto, maintenance) git не запускает: после первого коммита типовой
    # она сжимала двести тысяч объектов, commit её ждал и упирался в таймаут. Упаковка - отдельным шагом (gc).
    $settings.Add(@('gc.auto', '0'))
    $settings.Add(@('maintenance.auto', 'false'))
    foreach ($pair in @($Config | Where-Object { $_ })) {
        $cut = ([string]$pair).IndexOf('=')
        if ($cut -gt 0) { $settings.Add(@(([string]$pair).Substring(0, $cut), ([string]$pair).Substring($cut + 1))) }
    }
    $settings.Add(@('user.name', 'ci-gate'))
    $settings.Add(@('user.email', 'ci-gate@users.noreply.github.com'))
    if ($Token) {
        $basic = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes('x-access-token:' + $Token))
        $settings.Add(@('http.https://github.com/.extraheader', ('AUTHORIZATION: basic ' + $basic)))
        # Прокси - системный, как у браузера (git сам его не видит).
        try {
            $proxy = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy([uri]'https://github.com')
            if ($proxy.Host -ne 'github.com') { $settings.Add(@('http.proxy', $proxy.AbsoluteUri)) }
        }
        catch { }
    }
    $info.EnvironmentVariables['GIT_CONFIG_COUNT'] = [string]$settings.Count
    for ($index = 0; $index -lt $settings.Count; $index++) {
        $info.EnvironmentVariables[('GIT_CONFIG_KEY_{0}' -f $index)] = $settings[$index][0]
        $info.EnvironmentVariables[('GIT_CONFIG_VALUE_{0}' -f $index)] = $settings[$index][1]
    }
    $info.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    # Сообщения git - по-английски: по ним гейт узнаёт пустой репозиторий («couldn't find remote ref»).
    $info.EnvironmentVariables['LC_ALL'] = 'C'
    $info.EnvironmentVariables['LANGUAGE'] = 'C'
    $info.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
    $process = [System.Diagnostics.Process]::Start($info)
    # Снять git целиком: cmd\git.exe портативного git - обёртка, настоящий git.exe и его помощники - дочерние
    # процессы; Kill() снял бы одну обёртку, а остальные работали бы дальше и держали репозиторий.
    $stopGit = {
        try { $null = & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $process.Id /T /F 2>&1 } catch { }
        try { if (-not $process.HasExited) { $process.Kill() } } catch { }
    }
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $showProgress = ($Title -and $null -ne (Get-Command Write-UiProgress -ErrorAction SilentlyContinue))
    # Итог долгой команды - строкой под «начато»: готово или нет, за сколько, и что ответил git.
    $showResult = ($Title -and $null -ne (Get-Command Write-UiOperationResult -ErrorAction SilentlyContinue))
    if ($Title) { Write-Host ("  ...  {0}: начато в {1}, жду не дольше {2} мин" -f $Title, (Get-Date -Format 'HH:mm:ss'), [int]($TimeoutSec / 60)) -ForegroundColor DarkGray }
    while (-not $process.WaitForExit(250)) {
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
            & $stopGit
            if ($showProgress) { Complete-UiProgress }
            if ($showResult) { Write-UiOperationResult -Title $Title -Status 'FAIL' -Seconds $watch.Elapsed.TotalSeconds -Problem ('не закончил за {0} мин, git снят' -f [int]($TimeoutSec / 60)) }
            throw ('git {0}: не закончил за {1} мин' -f $Arguments[0], [int]($TimeoutSec / 60))
        }
        if ($showProgress) {
            # Строка хода проверяет и просьбу остановиться (файл stop канала ci.exe): тогда git снимается.
            try { Write-UiProgress -Title $Title -Elapsed $watch.Elapsed.TotalSeconds }
            catch {
                & $stopGit
                Complete-UiProgress
                throw
            }
        }
    }
    if ($showProgress) { Complete-UiProgress }
    $process.WaitForExit()
    $output = ($outTask.Result + $errTask.Result).Trim()
    if ($Token) { $output = $output.Replace($Token, '***') }
    $code = $process.ExitCode
    if ($showResult) {
        $resultStatus = 'OK'
        $problem = ''
        if ($code -ne 0) {
            # Не ноль, но вызывающему это можно (AllowFail: ветки ещё нет и т. п.) - не ошибка, а пометка.
            $resultStatus = 'FAIL'
            if ($AllowFail) { $resultStatus = 'WARN' }
            $problem = 'код {0}: {1}' -f $code, (@($output -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 2) -join ' | ')
        }
        Write-UiOperationResult -Title $Title -Status $resultStatus -Seconds $watch.Elapsed.TotalSeconds -Problem $problem
    }
    if ($code -ne 0 -and -not $AllowFail) {
        $tail = @($output -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 3) -join ' | '
        throw ('git {0} - код {1}: {2}' -f $Arguments[0], $code, $tail)
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

#endregion
