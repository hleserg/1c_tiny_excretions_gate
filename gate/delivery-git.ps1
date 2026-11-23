#requires -Version 5.1
# ** Хлебников С.Ю. 20261123 Тот же протокол очереди через штатный Git для компьютера с доступом к github.com.
function Initialize-WorkerGit {
    param($Gh,$Settings)
    $exe = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $cache = [IO.Path]::GetFullPath($Settings.GitCache)
    $Gh | Add-Member GitCache $cache
    $Gh | Add-Member GitExe $exe
    $Gh | Add-Member GitUrl ('https://github.com/' + $Gh.Repo + '.git')
}

function Invoke-WorkerGit {
    param($Gh,[string[]]$ArgsList)
    return (Invoke-GitCli -Git $Gh.GitExe -GitDir (Join-Path $Gh.GitCache 'objects.git') -WorkTree $Gh.GitCache -Arguments $ArgsList -Token $Gh.Token -TimeoutSec 180 -Config @('core.hooksPath=NUL','http.followRedirects=false')).Output
}

function Assert-PrivateWorkerGit {
    param($Gh)
    # Один и тот же Git URL должен требовать входа анонимно и открываться с токеном. Не передавать токен в эту пробу.
    $request = [Net.HttpWebRequest]::Create($Gh.GitUrl + '/info/refs?service=git-upload-pack')
    $request.AllowAutoRedirect = $false
    $request.Timeout = 20000
    $request.UserAgent = 'ci-delivery'
    try {
        $response = $request.GetResponse()
        $response.Close()
        throw 'Анонимное чтение репозитория открыто. Обмен остановлен.'
    }
    catch [Net.WebException] {
        $response = $_.Exception.Response
        if ($null -eq $response) { throw }
        try {
            if ([int]$response.StatusCode -ne 401 -or $response.Headers['WWW-Authenticate'] -notmatch '^Basic realm="GitHub"$') { throw 'Не подтверждена приватность Git-репозитория очереди' }
        } finally { $response.Close() }
    }
    $marker = Join-Path $Gh.GitCache 'delivery-repo.txt'
    if (-not [IO.File]::Exists($marker)) {
        [void][IO.Directory]::CreateDirectory($Gh.GitCache)
        if (@([IO.Directory]::GetFileSystemEntries($Gh.GitCache)).Count) { throw 'Для кеша очереди нужна отдельная пустая папка' }
        [IO.File]::WriteAllText($marker,$Gh.Repo)
    }
    if ([IO.File]::ReadAllText($marker) -cne $Gh.Repo) { throw 'Кеш очереди принадлежит другому репозиторию' }
    if (-not [IO.File]::Exists((Join-Path $Gh.GitCache 'objects.git\HEAD'))) {
        $null = Invoke-WorkerGit $Gh @('init','--template=')
    }
}

function Read-GitWorkerQueue {
    param($Gh)
    $ref = 'refs/heads/gate-delivery-v1'
    $answer = Invoke-WorkerGit $Gh @('ls-remote','--heads',$Gh.GitUrl,$ref)
    $files = @{}
    if (-not $answer) { return @{Head='';Files=$files} }
    if ($answer -cnotmatch '^([0-9a-f]{40})\s+refs/heads/gate-delivery-v1$') { throw 'Не распознана ветка очереди' }
    # fetch берёт согласованный снимок, даже если ветка успела продвинуться после ls-remote.
    $null = Invoke-WorkerGit $Gh @('fetch','--no-tags','--depth=1',$Gh.GitUrl,$ref)
    $head = Invoke-WorkerGit $Gh @('rev-parse','--verify','FETCH_HEAD^{commit}')
    if ($head -cnotmatch '^[a-f0-9]{40}$') { throw 'Не распознан коммит очереди' }
    $tree = Invoke-WorkerGit $Gh @('ls-tree','-r',$head,'--','jobs')
    foreach ($row in ($tree -split "\r?\n")) {
        if ($row -cmatch '^100644 blob ([0-9a-f]{40})\t(jobs/[0-9a-f]{64}/(?:job|problem|result)\.(?:json|bin))$') { $files[$Matches[2]]=$Matches[1] }
    }
    return @{Head=$head;Files=$files}
}

function Get-GitWorkerBlob {
    param($Gh,[string]$Sha)
    if ($Sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Некорректный хеш файла очереди' }
    $size = [long](Invoke-WorkerGit $Gh @('cat-file','-s',$Sha))
    if ($size -lt 0 -or $size -gt 95MB) { throw 'Недопустимый размер файла очереди' }
    # Только локальное чтение объекта. Двоичный stdout не преобразуем в текст PowerShell.
    $info = [Diagnostics.ProcessStartInfo]::new($Gh.GitExe,('cat-file blob ' + $Sha))
    $info.WorkingDirectory = Join-Path $Gh.GitCache 'objects.git'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $proc = [Diagnostics.Process]::Start($info)
    $buffer = [IO.MemoryStream]::new()
    try {
        $proc.StandardOutput.BaseStream.CopyTo($buffer)
        $proc.WaitForExit()
        $bytes = $buffer.ToArray()
        if ($proc.ExitCode -ne 0 -or $bytes.Length -ne $size -or (Get-GitBlobSha $bytes) -cne $Sha) { throw 'Ошибка чтения объекта Git' }
        return ,$bytes
    } finally { $proc.Dispose(); $buffer.Dispose() }
}

function Write-GitWorkerCommit {
    param($Gh,[string]$Head,$Changes,[string]$Message)
    if ($Head -cnotmatch '^[a-f0-9]{40}$') { throw 'Исполнитель отвечает только в существующую очередь' }
    $null = Invoke-WorkerGit $Gh @('read-tree',$Head)
    $tmp = Join-Path $Gh.GitCache ([Guid]::NewGuid().ToString('N'))
    try {
        foreach ($change in $Changes) {
            if ($change.Path -cnotmatch '^jobs/[0-9a-f]{64}/(result\.(json|bin)|problem\.json)$') { throw 'Исполнитель может публиковать только ответ на задание' }
            [IO.File]::WriteAllBytes($tmp,$change.Bytes)
            $blob = Invoke-WorkerGit $Gh @('hash-object','-w','--no-filters','--',$tmp)
            if ($blob -cne (Get-GitBlobSha $change.Bytes)) { throw 'Содержимое файла изменилось при записи в Git' }
            $null = Invoke-WorkerGit $Gh @('update-index','--add','--cacheinfo',('100644,'+$blob+','+$change.Path))
        }
        $tree = Invoke-WorkerGit $Gh @('write-tree')
        $commit = Invoke-WorkerGit $Gh @('commit-tree',$tree,'-p',$Head,'-m',$Message)
        $null = Invoke-WorkerGit $Gh @('push',$Gh.GitUrl,($commit+':refs/heads/gate-delivery-v1'))
    } finally { [IO.File]::Delete($tmp) }
}
# ** Хлебников С.Ю. 20261123 конец
