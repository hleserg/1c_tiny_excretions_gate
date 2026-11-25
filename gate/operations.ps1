#requires -Version 5.1
# ** Хлебников С.Ю. 20261124 Журнал операций. Основной процесс пишет только на диск, GitHub обслуживает publish.ps1.
function Get-OperationRoot {
    param([hashtable]$Settings)
    $deploy = [string]$Settings['DeployDir']
    if (-not $deploy) { $deploy = 'deploy' }
    if (-not [IO.Path]::IsPathRooted($deploy)) { $deploy = Join-Path $PSScriptRoot $deploy }
    return (Join-Path $deploy 'operations')
}

function Start-OperationSender {
    param([hashtable]$Settings, [string]$ConfigPath)
    if (-not $Settings['PublishOperations'] -or -not $Settings['RunFilesRepo']) { return }
    try {
        $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
        $scriptFile = Join-Path $PSScriptRoot 'publish.ps1'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -WatchOperations -Config "{1}"' -f $scriptFile, $ConfigPath
        Start-Process -FilePath powershell.exe -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop
    } catch { Write-Warning 'Не удалось запустить отправку журнала операций. Записи останутся на диске.' }
}

function Write-OperationEvent {
    param($Operation, [string]$Event, [hashtable]$Fields = @{})
    if ($null -eq $Operation) { return }
    try {
        $data = [ordered]@{ operation = $Operation.Name; event = $Event; time = [DateTimeOffset]::Now.ToString('o') }
        foreach ($key in $Fields.Keys) { $data[$key] = $Fields[$key] }
        $text = ConvertTo-Json -InputObject $data -Depth 5 -Compress
        $leaf = '{0:D5}-{1}.json' -f $Operation.Next, $Event
        $Operation.Next++
        $source = Join-Path $Operation.Dir ([guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($source, $text, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($source, (Join-Path $Operation.Dir $leaf))
    } catch { Write-Warning 'Не удалось записать событие в локальный журнал операций.' }
}

function Start-GateOperation {
    param([hashtable]$Settings, [string]$ConfigPath, [string]$Name)
    if (-not $Settings['PublishOperations'] -or -not $Settings['RunFilesRepo']) { return }
    try {
        $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
        $dir = Join-Path (Get-OperationRoot $Settings) $id
        $null = [IO.Directory]::CreateDirectory($dir)
        $op = [pscustomobject]@{ Dir = $dir; Name = $Name; Next = 0; LastTitle = ''; FinalStatus = '' }
        [IO.File]::WriteAllText((Join-Path $dir 'pid.txt'), ('{0}|{1:o}' -f $PID, (Get-Process -Id $PID).StartTime))
        Write-OperationEvent $op 'start'
        Start-OperationSender $Settings $ConfigPath
        return $op
    } catch { Write-Warning 'Не удалось открыть локальный журнал операций.' }
}

function Send-OperationBatch {
    # Файлы событий неизменяемы. Подтверждаем доставку только после перемещения ссылки Git.
    param($Gh, [string]$Branch, $Batch)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $head = Get-GhHead -Gh $Gh -Branch $Branch
        if ($head.Empty) { throw 'Репозиторий журнала пуст' }
        $commit = New-GhCommit -Gh $Gh -Parent $head.Sha -Changes @($Batch | ForEach-Object { $_.Change }) -Message 'Журнал заводских операций'
        try {
            if ($head.Sha) { Set-GhBranch -Gh $Gh -Branch $Branch -Sha $commit }
            else { Set-GhBranch -Gh $Gh -Branch $Branch -Sha $commit -Create }
            break
        } catch { if ($attempt -eq 3) { throw } }
    }
    foreach ($entry in $Batch) { [IO.File]::Move($entry.File, $entry.File + '.sent') }
}

# ** Хлебников С.Ю. 20261124 Для старого выпуска тоже читаем результат действий из его собственного каталога.
function Get-OperationActionDetail {
    param($Record, [string]$Directory, [string[]]$Secrets = @())
    $detail = [ordered]@{ run = [IO.Path]::GetFileName($Directory); outcome = $Record.outcome; report = 'missing' }
    $result = Join-Path $Directory 'actions\result.txt'
    $reason = ''
    if ([IO.File]::Exists($result)) {
        $detail.report = 'present'
        $rows = foreach ($line in [IO.File]::ReadLines($result, [Text.Encoding]::UTF8)) {
            if ($line -cmatch '^user=(.{1,150})$') { $detail.user = $Matches[1] }
            elseif ($line -cmatch '^error=(.+)$') { $reason = $Matches[1] }
            elseif ($line -cmatch '^action=([\p{L}0-9_-]{1,150})\|(done|already|notrun|failed)(?:\|(.*))?$') {
                $id = $Matches[1]; $state = $Matches[2]; $message = $Matches[3]
                if ($Record.actions.ids -ccontains $id) {
                    [ordered]@{ id = $id; status = $state }
                    if ($state -eq 'failed' -and $message) { $reason = $message }
                }
            }
        }
        $detail.actions = @($rows | Where-Object { $_ })
    }
    if (-not $reason -and $Record.outcome -eq 'actionsFailed' -and $Record.PSObject.Properties['light']) {
        $failure = $Record.light | Where-Object { $_.name -eq 'Действия после обновления' -and $_.status -eq 'FAIL' } | Select-Object -First 1
        if ($failure -and $failure.PSObject.Properties['text']) { $reason = [string]$failure.text }
    }
    if ($reason) {
        $detail.reason = Get-ActionErrorSummary $reason $Secrets
    }
    return $detail
}
# ** Хлебников С.Ю. 20261124 конец

function Get-OperationHistory {
    # Формируется и для выпуска, который прошёл на предыдущей версии гейта.
    param([string]$Spool, [string[]]$Secrets = @())
    $root = Split-Path -Parent $Spool
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -match '^\d{8}-\d{6}$')) {
        $source = Join-Path $dir.FullName 'deploy.json'
        $out = Join-Path $Spool ('history-' + $dir.Name)
        $file = Join-Path $out '00000-release.json'
        # ** Хлебников С.Ю. 20261124 Подробности действий досылаются отдельно от неизменяемого итога выпуска.
        $haveRelease = [IO.File]::Exists($file) -or [IO.File]::Exists($file + '.sent')
        $detailFile = Join-Path $out '00001-result.json'
        $needDetail = [IO.Directory]::Exists((Join-Path $dir.FullName 'actions')) -and
            -not ([IO.File]::Exists($detailFile) -or [IO.File]::Exists($detailFile + '.sent'))
        if ($haveRelease -and -not $needDetail) { continue }
        # ** Хлебников С.Ю. 20261124 конец
        try {
            if (-not [IO.File]::Exists($source)) {
                if ($haveRelease) { continue } # ** Хлебников С.Ю. 20261124
                $logPath = Join-Path $dir.FullName 'run.log'
                if (-not [IO.File]::Exists($logPath)) { continue }
                $tail = @(Get-Content -LiteralPath $logPath -Encoding UTF8 -Tail 12 | Where-Object { $_ -match '^\d\d:\d\d:\d\d ИТОГ: подготов' })
                if (-not $tail.Count) { continue }
                $status = if ($tail[-1] -match 'ИТОГ: подготовлено\.') { 'prepared' } else { 'failed' }
                $content = [ordered]@{operation='Prepare';event='release';run=$dir.Name;outcome=$status}
            } else {
                $record = (Read-TextFile $source) | ConvertFrom-Json
                if ($record.outcome -notin @('updated','failed','rolledBack','rollbackFailed','actionsFailed')) { continue }
                # ** Хлебников С.Ю. 20261124 В т.ч. для выпуска, уже отправленного прежней версией.
                if ($needDetail -and $record.PSObject.Properties['actions'] -and $record.actions -and $record.actions.PSObject.Properties['ids']) {
                    $null = [IO.Directory]::CreateDirectory($out)
                    $detail = Get-OperationActionDetail $record $dir.FullName $Secrets
                    Write-OperationEvent ([pscustomobject]@{Dir=$out;Name='deploy';Next=1}) 'result' $detail
                }
                if ($haveRelease) { continue }
                # ** Хлебников С.Ю. 20261124 конец
                $content = [ordered]@{ operation='deploy'; event='release'; run=$dir.Name; outcome=$record.outcome; mode=$record.mode; time=$record.time; base=$record.base }
                if ($record.PSObject.Properties['gate'] -and $record.gate) {
                    $content.gate = $record.gate | Select-Object run,verdict,kitSource
                }
                foreach ($key in 'preparedRun','rollbackOf','riskAccepted') {
                    if ($record.PSObject.Properties[$key]) { $content[$key] = $record.$key }
                }
                if ($record.PSObject.Properties['light']) { $content.checks = @($record.light | Select-Object name,status) }
                foreach ($key in 'extensions','processings') {
                    if ($record.PSObject.Properties[$key]) { $content[$key] = @($record.$key | Select-Object name,oldVersion,newVersion,status) }
                }
            }
            $null = [IO.Directory]::CreateDirectory($out)
            $temporary = Join-Path $out ([guid]::NewGuid().ToString('N') + '.tmp')
            [IO.File]::WriteAllText($temporary, (ConvertTo-Json $content -Depth 5), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($temporary, $file)
        } catch { continue }
    }
}

function Watch-GateOperations {
    param([hashtable]$Settings)
    $repo = [string]$Settings['RunFilesRepo']
    $branch = [string](Get-PublishSetting $Settings 'RunFilesBranch' 'gate-runs')
    if (-not $Settings['PublishOperations'] -or -not $repo -or -not $branch -or $branch -in @('main','master','prod')) { return }
    $spoolPath = Get-OperationRoot $Settings
    $null = [IO.Directory]::CreateDirectory($spoolPath)
    try { $lock = [IO.File]::Open((Join-Path $spoolPath 'sender.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch [IO.IOException] { return }
    try {
        $token = Get-PublishToken ([string]$Settings['GitHubTokenPassFile'])
        $gh = New-GhContext -Repo $repo -Token $token
        if (-not $gh.FakeDir) {
            $info = (Invoke-GhApi -Gh $gh -Method GET -Path ('/repos/' + $repo)).Text | ConvertFrom-Json
            if (-not $info.private -or $info.default_branch -eq $branch) { throw 'Журналу нужна отдельная ветка закрытого репозитория' }
        }
        $secretPatterns = New-Object System.Collections.Generic.List[string]
        foreach ($secret in (Get-PublishSecrets -Settings $Settings -Token $token)) {
            $plain = [string]$secret.Value
            $secretPatterns.Add($plain)
            $quoted = ConvertTo-Json -InputObject $plain -Compress
            $encoded = $quoted.Substring(1, $quoted.Length - 2)
            if ($encoded -cne $plain) { $secretPatterns.Add($encoded) }
        }
        do {
            Get-OperationHistory $spoolPath $secretPatterns.ToArray()
            $active = $false
            $batch = New-Object System.Collections.Generic.List[object]
            foreach ($dir in @(Get-ChildItem -LiteralPath $spoolPath -Directory | Where-Object Name -match '^(?:\d{8}-\d{6}-[0-9a-f]{32}|history-\d{8}-\d{6})$')) {
                if (-not $dir.Name.StartsWith('history-') -and -not @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*-finish.json*').Count) {
                    if (Test-RunAlive $dir.FullName) { $active = $true }
                    elseif ([IO.File]::Exists((Join-Path $dir.FullName 'pid.txt'))) {
                        $start = Get-ChildItem -LiteralPath $dir.FullName -Filter '*-start.json*' | Select-Object -First 1
                        if ($start) {
                            $name = ((Read-TextFile $start.FullName) | ConvertFrom-Json).operation
                            Write-OperationEvent ([pscustomobject]@{Dir=$dir.FullName;Name=$name;Next=99999}) 'finish' @{status='interrupted'}
                        }
                    }
                }
                foreach ($file in @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.json' | Where-Object Name -match '^\d{5}-(start|step|result|finish|release)\.json$' | Sort-Object Name)) {
                    $value = Read-TextFile $file.FullName
                    foreach ($pattern in $secretPatterns) {
                        if ($value.Contains($pattern)) {
                            $value = '{"event":"redacted"}'
                            break
                        }
                    }
                    $change = [pscustomobject]@{Path=('operations/{0}/{1}' -f $dir.Name,$file.Name); Bytes=$Utf8NoBom.GetBytes($value)}
                    $batch.Add([pscustomobject]@{File=$file.FullName;Change=$change})
                    if ($batch.Count -ge 100) { break }
                }
                if ($batch.Count -ge 100) { break }
            }
            if ($batch.Count) { Send-OperationBatch -Gh $gh -Branch $branch -Batch $batch.ToArray() }
            if ($batch.Count -ge 100) { continue }
            if ($active) { Start-Sleep -Seconds 10 }
        } while ($active -or $batch.Count -gt 0)
    } finally { $lock.Dispose() }
}
# ** Хлебников С.Ю. 20261124 конец
