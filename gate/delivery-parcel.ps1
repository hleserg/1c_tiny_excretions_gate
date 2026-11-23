#requires -Version 5.1
# ** Хлебников С.Ю. 20261123 Протокол приёмки v1. Ветка содержит только данные, команд и настроек подключения в заданиях нет.
function Get-ParcelHash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ParcelId {
    param($Job)
    if ($Job.version -ne 1 -or $Job.delivery -cnotmatch '^\d{8}-\d{6}-[a-f0-9]{6}$' -or
        $Job.operation -cnotin @('expand-cfe','build-cfe','expand-epf','expand-erf','build-epf','build-erf') -or
        $Job.input -cnotmatch '^[a-f0-9]{64}$' -or $Job.index -notmatch '^[1-9]\d{0,5}$' -or
        -not $Job.config -or $Job.config -match '[\r\n|]') { throw 'Некорректное задание приёмки v1' }
    $key = @(1,$Job.delivery,$Job.index,$Job.operation,$Job.config,$Job.input) -join '|'
    return Get-ParcelHash ([Text.Encoding]::UTF8.GetBytes($key))
}

function New-ParcelArchive {
    # Времена файлов после повторной сборки другие. Для одного дерева ZIP должен быть побайтно одинаковым.
    param([string]$Dir, [string]$Target)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Dir).TrimEnd('\') + '\'
    $paths = [string[]]@([IO.Directory]::GetFiles($root,'*','AllDirectories'))
    [Array]::Sort($paths,[StringComparer]::Ordinal)
    $zip = [IO.Compression.ZipFile]::Open($Target,'Create')
    try {
        foreach ($path in $paths) {
            $entry = $zip.CreateEntry($path.Substring($root.Length).Replace('\','/'))
            $entry.LastWriteTime = [DateTimeOffset]::new(2000,1,1,0,0,0,[TimeSpan]::Zero)
            $writer = $entry.Open()
            try { $src = [IO.File]::OpenRead($path); try { $src.CopyTo($writer) } finally { $src.Dispose() } }
            finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Expand-ParcelArchive {
    # Только свежий каталог. Один обычный файл на путь, включая проверку имён устройств и потоков NTFS.
    param([string]$ZipPath, [string]$Dir)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if ([IO.Directory]::Exists($Dir)) { throw "Папка результата уже существует: $Dir" }
    [void][IO.Directory]::CreateDirectory($Dir)
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        [long]$size = 0
        foreach ($entry in $zip.Entries) {
            $size += $entry.Length
            if ($size -gt 2GB) { throw 'Распакованная поставка больше 2 ГиБ' }
            foreach ($part in $entry.FullName.Split('/')) {
                if (-not $part -or $part -match '[<>:"\\|?*\x00-\x1f]|[ .]$|^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(\.|$)') { throw 'Недопустимый путь в ZIP поставки' }
            }
            $path = Join-Path $Dir $entry.FullName
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$path,$false)
        }
    } finally { $zip.Dispose() }
}

function Assert-ParcelRepo {
    param($Gh)
    if ($Gh.PSObject.Properties['GitCache']) { Assert-PrivateWorkerGit $Gh; return }
    if ($Gh.FakeDir) { return }
    $repo = (Invoke-GhApi $Gh GET ('/repos/' + $Gh.Repo)).Text | ConvertFrom-Json
    if ($repo.private -ne $true -or $repo.full_name -ine $Gh.Repo) { throw 'Для обмена поставками нужен приватный репозиторий' }
}

function Read-ParcelQueue {
    param($Gh)
    if ($Gh.PSObject.Properties['GitCache']) { return Read-GitWorkerQueue $Gh }
    $head = (Get-GhHead $Gh 'gate-delivery-v1').Sha
    $files = @{}
    if ($head) { $files = Get-GhFiles $Gh $head }
    return @{ Head=$head; Files=$files }
}

function Get-ParcelBytes {
    param($Gh,[string]$Sha)
    if ($Gh.PSObject.Properties['GitCache']) { return ,(Get-GitWorkerBlob $Gh $Sha) }
    return ,(Get-GhBlob $Gh $Sha)
}

function Get-ParcelJson {
    param($Gh,$Queue,[string]$Path)
    $bytes = Get-ParcelBytes $Gh $Queue.Files[$Path]
    return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}

function Read-ParcelPayload {
    param($Gh,$Queue,[string]$Path,[string]$Hash)
    $bytes = Get-ParcelBytes $Gh $Queue.Files[$Path]
    if ((Get-ParcelHash $bytes) -cne $Hash) { throw "Не совпал SHA-256 $Path" }
    return ,$bytes
}

function Publish-Parcel {
    # JSON и файл становятся видны одним перемещением ветки вперёд. При гонке вызывающий перечитает очередь.
    param($Gh,$Queue,[string]$Key,[ValidateSet('job','result','problem')]$Type,$Data,[byte[]]$Bytes)
    if ($Key -cnotmatch '^[a-f0-9]{64}$') { throw 'Некорректный ключ задания' }
    $prefix = "jobs/$Key/$Type"
    $json = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Compress))
    $changes = @(@{ Path="$prefix.json"; Bytes=$json })
    if ($Bytes.Length -gt 0) {
        if ($Bytes.Length -gt 95MB) { throw 'Размер файла превышает лимит обмена GitHub (95 МиБ)' }
        $changes += @{ Path="$prefix.bin"; Bytes=$Bytes }
    }
    if ($Queue.Files.ContainsKey("$prefix.json")) { throw 'Запись очереди уже опубликована' }
    if ($Gh.PSObject.Properties['GitCache']) { Write-GitWorkerCommit $Gh $Queue.Head $changes "delivery v1 $Type $Key"; return }
    $sha = New-GhCommit $Gh $Queue.Head $changes ("delivery v1 $Type $Key")
    Set-GhBranch $Gh 'gate-delivery-v1' $sha -Create:(-not $Queue.Head)
}

function Invoke-ParcelRequest {
    param($D,$State,[int]$Index,[string]$Operation,[string]$Path)
    $gh = $D.Remote
    Assert-ParcelRepo $gh
    $cfgInfo = Get-ComConfigInfo -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword
    if (-not $cfgInfo.Ok -or -not $cfgInfo.Name -or -not $cfgInfo.Version) { throw 'Не удалось определить версию конфигурации temp' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $job = [ordered]@{version=1; delivery=$State.id; index=$Index; operation=$Operation; config=($cfgInfo.Name+' '+$cfgInfo.Version); input=(Get-ParcelHash $bytes)}
    if ($Operation.StartsWith('expand-') -and $job.input -ne $State.files[$Index-1].sha256) { throw 'Оригинал поставки изменился после приёма' }
    $key = Get-ParcelId $job
    $prefix = "jobs/$key"
    $queue = Read-ParcelQueue $gh
    if (-not $queue.Files.ContainsKey("$prefix/job.json")) {
        Publish-Parcel $gh $queue $key job $job $bytes
        $queue = Read-ParcelQueue $gh
    }
    $deadline = [DateTime]::UtcNow.AddMinutes($D.WorkerWaitMin)
    do {
        if ((Get-ParcelId (Get-ParcelJson $gh $queue "$prefix/job.json")) -cne $key) { throw 'Подмена задания в очереди' }
        if ($queue.Files.ContainsKey("$prefix/result.json")) {
            $result = Get-ParcelJson $gh $queue "$prefix/result.json"
            if ($result.version -ne 1 -or $result.job -cne $key -or $result.input -cne $job.input) { throw 'Ответ относится к другому заданию' }
            if ($result.status -ne 'ok') { throw "Исполнитель остановил задание $key. $($result.note)" }
            $output = Read-ParcelPayload $gh $queue "$prefix/result.bin" $result.output
            Write-DeliveryEvent $D $State 'worker' ("{0}: задание {1}, результат SHA-256 {2}" -f $Operation,$key,$result.output)
            return ,$output
        }
        if ($queue.Files.ContainsKey("$prefix/problem.json")) { throw "Исполнитель остановил задание $key. Подробности в problem.json на стенде." }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 15
        $queue = Read-ParcelQueue $gh
    } while ($true)
    $pending = [Exception]::new("Ждём исполнителя: $Operation, задание $key")
    $pending.Data['DeliveryPending'] = $true
    throw $pending
}
# ** Хлебников С.Ю. 20261123 конец
