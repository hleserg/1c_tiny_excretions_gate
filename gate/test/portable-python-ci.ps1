#requires -Version 5.1
# Только для временной Windows-машины CI. Сам установщик и проверка исполняются без токена администратора.
param([Parameter(Mandatory)][string]$Bundle)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Этот тест предназначен для временной Windows-машины GitHub. Вручную запустите portable-python.ps1.'
}
$task = 'gate-python-' + [guid]::NewGuid().ToString('N')
$dir = Join-Path $env:ProgramData $task
$registered = $false
try {
    $null = New-Item -ItemType Directory -Path $dir
    Copy-Item -LiteralPath $Bundle -Destination (Join-Path $dir 'kit.zip')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'portable-python.ps1') -Destination (Join-Path $dir 'probe.ps1')
    # LocalService имеет собственный профиль и не входит в локальные администраторы.
    & icacls.exe $dir /grant '*S-1-5-19:(OI)(CI)M' | Out-Null
    if ($LASTEXITCODE) { throw 'Не удалось открыть временную папку для Limited-проверки' }
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-19' -LogonType ServiceAccount -RunLevel Limited
    $command = @'
Start-Transcript -LiteralPath '.\probe.log'
try {
    & '.\probe.ps1' -Bundle (Resolve-Path '.\kit.zip').Path -RequireStandardUser
    exit 0
} catch {
    Write-Host ($_ | Out-String)
    exit 1
} finally {
    Stop-Transcript
}
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -WorkingDirectory $dir -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + $encoded)
    $null = Register-ScheduledTask -TaskName $task -Principal $principal -Action $action
    $registered = $true
    Start-ScheduledTask -TaskName $task
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 1
        $info = Get-ScheduledTaskInfo -TaskName $task
        $state = (Get-ScheduledTask -TaskName $task).State
        if ($info.LastRunTime.Year -gt 2000 -and $state -eq 'Ready') {
            if ($info.LastTaskResult -ne 0) { throw ("Проверка завершилась с кодом {0}" -f $info.LastTaskResult) }
            if (-not (Test-Path -LiteralPath (Join-Path $dir 'probe.log'))) { throw 'Проверка не оставила журнал' }
            return
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Проверка установщика без прав администратора не завершилась за пять минут'
} finally {
    if ($registered) {
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }
    $log = Join-Path $dir 'probe.log'
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
}
