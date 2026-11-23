#requires -Version 5.1
# Проверка скриптов гейта самим PowerShell: разбор без запуска. Ничего не запускает и в базы не ходит.
# Запуск: .\check.cmd в папке C:\ci после распаковки архива.
$ErrorActionPreference = 'Stop'
# ** Хлебников С.Ю. 20261123 Скрипты протокола и исполнителя входят в проверку сборки.
$failed = 0
foreach ($name in @('run.ps1', 'report.ps1', 'deploy.ps1', 'nightly.ps1', 'ui.ps1', 'stats.ps1', 'settings.ps1', 'unittests.ps1', 'unittests-cli.ps1', 'update.ps1', 'publish.ps1', 'github.ps1', 'delivery.ps1', 'delivery-parcel.ps1', 'delivery-worker.ps1', 'delivery-designer.ps1', 'delivery-git.ps1', 'cluster-target.ps1', 'canary-users.ps1', 'locks.ps1', 'post-update.ps1', 'timeline.ps1', 'selfcheck-compare.ps1', 'test\tests.ps1', 'test\fakecom.ps1', 'test\deploy-contract.tests.ps1', 'test\delivery.tests.ps1')) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path)) { Write-Host ("[----] {0}: нет файла" -f $name) -ForegroundColor Yellow; continue }
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -eq 0) { Write-Host ("[OK]   {0}" -f $name) -ForegroundColor Green; continue }
    $failed++
    Write-Host ("[FAIL] {0}: ошибок разбора {1}" -f $name, $errors.Count) -ForegroundColor Red
    foreach ($item in @($errors | Select-Object -First 5)) {
        Write-Host ("       строка {0}: {1}" -f $item.Extent.StartLineNumber, $item.Message)
    }
}
foreach ($name in @('config.psd1', 'config.example.psd1', 'config.site.psd1')) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path)) { continue }
    try { $null = Import-PowerShellDataFile -LiteralPath $path; Write-Host ("[OK]   {0}" -f $name) -ForegroundColor Green }
    catch { $failed++; Write-Host ("[FAIL] {0}: {1}" -f $name, $_.Exception.Message) -ForegroundColor Red }
}
$uiFile = Join-Path $PSScriptRoot 'ui.ps1'
if (Test-Path -LiteralPath $uiFile) {
    . $uiFile
    Initialize-Ui
    Write-Host '[OK]   ui.ps1 подключается' -ForegroundColor Green
}
$ciExe = Join-Path $PSScriptRoot 'ci.exe'
if (Test-Path -LiteralPath $ciExe) {
    $ciVersion = (& $ciExe -version 2>&1) -join ' '
    if ($LASTEXITCODE -eq 0) { Write-Host ("[OK]   {0}" -f $ciVersion) -ForegroundColor Green }
    else { $failed++; Write-Host ("[FAIL] ci.exe не запустился: {0}" -f $ciVersion) -ForegroundColor Red }
}
else { Write-Host '[----] ci.exe нет: экран ci недоступен, run.cmd и deploy.cmd работают' -ForegroundColor Yellow }
if ($failed -gt 0) { exit 1 }
exit 0
