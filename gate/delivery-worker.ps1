#requires -Version 5.1
# ** Хлебников С.Ю. 20261123 Два прохода общей локальной папки: сеть отдельно от Конфигуратора.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Sync','Work')][string]$Mode,
      [Parameter(Mandatory)][string]$Config, [switch]$Watch)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. "$PSScriptRoot\github.ps1"
. "$PSScriptRoot\delivery-parcel.ps1"
. "$PSScriptRoot\delivery-designer.ps1"
$settings = Import-PowerShellDataFile -LiteralPath $Config
$spool = [IO.Path]::GetFullPath($settings.Spool)
[void][IO.Directory]::CreateDirectory($spool)

function Read-WorkerSecret([string]$Path) {
    $secure = ConvertTo-SecureString ([IO.File]::ReadAllText($Path))
    try { return [Net.NetworkCredential]::new('',$secure).Password }
    finally { $secure.Dispose() }
}

function Sync-WorkerQueue($Gh) {
    Assert-ParcelRepo $Gh
    $queue = Read-ParcelQueue $Gh
    foreach ($path in @($queue.Files.Keys | Sort-Object)) {
        if ($path -cnotmatch '^jobs/([a-f0-9]{64})/job\.json$') { continue }
        $key = $Matches[1]
        if ($queue.Files.ContainsKey("jobs/$key/result.json")) { continue }
        $job = Get-ParcelJson $Gh $queue $path
        if ((Get-ParcelId $job) -cne $key) { throw 'Идентификатор задания не совпал с манифестом' }
        $dir = Join-Path $spool $key
        [void][IO.Directory]::CreateDirectory($dir)
        $ready = Join-Path $dir 'job.json'
        if (-not [IO.File]::Exists($ready)) {
            [IO.File]::WriteAllBytes((Join-Path $dir 'job.bin'),(Read-ParcelPayload $Gh $queue "jobs/$key/job.bin" $job.input))
            [IO.File]::WriteAllText("$ready.tmp",($job | ConvertTo-Json -Compress))
            [IO.File]::Move("$ready.tmp",$ready)
        }
        $problem = Join-Path $dir 'problem.json'
        if ([IO.File]::Exists($problem) -and -not $queue.Files.ContainsKey("jobs/$key/problem.json")) {
            $notice = @{version=1; job=$key; input=$job.input; note='Ошибка исполнителя. Проверьте журнал на стенде и повторите задание.'}
            Publish-Parcel $Gh $queue $key problem $notice @()
            $queue = Read-ParcelQueue $Gh
        }
        $done = Join-Path $dir 'result.json'
        if ([IO.File]::Exists($done)) {
            $result = [IO.File]::ReadAllText($done) | ConvertFrom-Json
            if ($result.job -cne $key -or $result.input -cne $job.input) { throw 'Локальный ответ от другого задания' }
            $payload = [IO.File]::ReadAllBytes((Join-Path $dir 'result.bin'))
            if ((Get-ParcelHash $payload) -cne $result.output) { throw 'Повреждён локальный результат' }
            Publish-Parcel $Gh $queue $key result $result $payload
            $queue = Read-ParcelQueue $Gh
        }
    }
}

function Invoke-WorkerJob($Profile,$Job,[string]$Key,[string]$Dir) {
    if ((Get-ParcelId $Job) -cne $Key) { throw 'Изменился манифест задания' }
    $file = Join-Path $Dir 'job.bin'
    $inputBytes = [IO.File]::ReadAllBytes($file)
    if ((Get-ParcelHash $inputBytes) -cne $Job.input) { throw 'Изменился входной файл' }
    if ((Get-WorkerMetadata $Profile) -cne $Job.config) { throw 'Имя или версия конфигурации отличаются от temp' }
    $attempt = Join-Path $Profile.WorkRoot ([Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($attempt)
    $type = $Job.operation.Split('-')[1]
    $tree = Join-Path $attempt 'tree'
    $binary = Join-Path $attempt ("object.$type")
    $archive = Join-Path $attempt 'tree.zip'
    if ($Job.operation.StartsWith('expand-')) {
        [IO.File]::WriteAllBytes($binary,$inputBytes)
        if ($type -eq 'cfe') { Invoke-WorkerExtension $Profile expand $binary $tree $attempt }
        else {
            [void][IO.Directory]::CreateDirectory($tree)
            Invoke-WorkerDesigner $Profile @('/DumpExternalDataProcessorOrReportToFiles',('"{0}\dump.xml"' -f $tree),('"{0}"' -f $binary)) (Join-Path $attempt 'dump.log')
        }
        New-ParcelArchive $tree $archive
        $output = $archive
    }
    else {
        [IO.File]::WriteAllBytes($archive,$inputBytes)
        Expand-ParcelArchive $archive $tree
        if ($type -eq 'cfe') { Invoke-WorkerExtension $Profile build $tree $binary $attempt }
        else {
            $roots = @([IO.Directory]::GetFiles($tree,'*.xml'))
            if ($roots.Count -ne 1) { throw 'Неоднозначный корень выгрузки обработки' }
            Invoke-WorkerDesigner $Profile @('/LoadExternalDataProcessorOrReportFromFiles',('"{0}"' -f $roots[0]),('"{0}"' -f $binary)) (Join-Path $attempt 'build.log')
        }
        $output = $binary
    }
    $payload = [IO.File]::ReadAllBytes($output)
    if (-not $payload.Length) { throw '1С вернула пустой файл' }
    $result = [ordered]@{version=1; job=$Key; input=$Job.input; status='ok'; output=(Get-ParcelHash $payload)}
    [IO.File]::WriteAllBytes((Join-Path $Dir 'result.bin'),$payload)
    $done = Join-Path $Dir 'result.json'
    [IO.File]::WriteAllText("$done.tmp",($result | ConvertTo-Json -Compress))
    [IO.File]::Move("$done.tmp",$done)
}

if ($Mode -eq 'Sync') {
    $gh = New-GhContext $settings.Repo (Read-WorkerSecret $settings.TokenFile)
    if ($settings.ContainsKey('GitCache')) {
        . "$PSScriptRoot\delivery-git.ps1"
        Initialize-WorkerGit $gh $settings
    }
    $guardDir = $spool
}
else {
    $db = Import-PowerShellDataFile -LiteralPath $settings.GateProfile
    if ($settings.Server -ine $db.Server -or $settings.Base -ine $db.Base -or $db.Base -eq $db.ProdBase -or
        ($db.Server.Split(':')[0] -notin @($env:COMPUTERNAME,'localhost','127.0.0.1')) -or
        $db.ForbiddenBases -contains $db.Base -or $db.Server -notmatch '^[\w.-]+(:\d+)?$' -or
        $db.Base -notmatch '^[\w]+$' -or $db.Base -notmatch 'temp|test|copy|tmp|dev|sandbox|stand|тест|копи|стенд|песочниц') {
        throw 'Цель исполнителя не совпала с разрешённой серверной тестовой базой'
    }
    $passFile = Join-Path (Split-Path -Parent $settings.GateProfile) $db.AdminPassFile
    $profile = @{Server=$db.Server; Base=$db.Base; Designer=(Join-Path $db.V8Bin '1cv8.exe'); User=$db.AdminUser
        Password=(Read-WorkerSecret $passFile); WorkRoot=[IO.Path]::GetFullPath($settings.WorkRoot)}
    if (($profile.Password + $profile.User) -match '["\r\n]' -or $profile.Password.EndsWith('\')) { throw 'Параметр входа нельзя безопасно передать Конфигуратору' }
    $guardDir = $profile.WorkRoot
    [void][IO.Directory]::CreateDirectory($guardDir)
}
$guard = [IO.File]::Open((Join-Path $guardDir ("delivery-$Mode.lock")),'OpenOrCreate','ReadWrite','None')
try {
    do {
        if ($Mode -eq 'Sync') { Sync-WorkerQueue $gh }
        else {
            foreach ($dir in @(Get-ChildItem -LiteralPath $spool -Directory | Where-Object Name -cmatch '^[a-f0-9]{64}$')) {
                $ready = Join-Path $dir.FullName 'job.json'
                if ([IO.File]::Exists($ready) -and -not [IO.File]::Exists((Join-Path $dir.FullName 'result.json'))) {
                    $problem = Join-Path $dir.FullName 'problem.json'
                    if ([IO.File]::Exists($problem)) { continue }
                    try { Invoke-WorkerJob $profile ([IO.File]::ReadAllText($ready) | ConvertFrom-Json) $dir.Name $dir.FullName }
                    catch {
                        [IO.File]::WriteAllText("$problem.tmp",(@{error=$_.Exception.Message} | ConvertTo-Json))
                        [IO.File]::Move("$problem.tmp",$problem)
                        throw
                    }
                }
            }
        }
        if ($Watch) { Start-Sleep -Seconds 15 }
    } while ($Watch)
} finally { $guard.Dispose() }
# ** Хлебников С.Ю. 20261123 конец
