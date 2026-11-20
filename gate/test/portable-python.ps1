#requires -Version 5.1
# Проверка поставляемого ZIP на Windows без Python и gh в PATH.
param([Parameter(Mandatory)][string]$Bundle, [switch]$RequireStandardUser)

$ErrorActionPreference = 'Stop'
if ($RequireStandardUser) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Проверка запущена с правами администратора' }
    Write-Host ("Windows PowerShell {0}, учётная запись {1}, токен без прав администратора" -f $PSVersionTable.PSVersion, $identity.Name)
}
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('gate-python-' + [guid]::NewGuid())
$kit = Join-Path $work 'комплект'
$target = Join-Path $work "папка гейта 'тест'"
$oldPath = $env:Path
$oldUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
try {
    Expand-Archive -LiteralPath $Bundle -DestinationPath $kit
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
    & (Join-Path $kit 'install.ps1') -Target $target -Unattended
    if ($LASTEXITCODE) { throw 'ошибка установки комплекта' }
    . (Join-Path $target 'delivery.ps1')
    function Write-RunLog { param([string]$Line) Write-Host $Line }
    $probe = Join-Path $work 'проверка приёмки.py'
    $source = @'
import argparse, dataclasses, json, os, re, ssl, subprocess, sys, urllib.error, urllib.request
ssl.create_default_context()
print(json.dumps({"ok": bool(sys.flags.isolated), "exe": sys.executable, "arg": sys.argv[1]}, ensure_ascii=False))
'@
    [IO.File]::WriteAllText($probe, $source, [Text.UTF8Encoding]::new($false))
    $expected = Get-DeliveryPython ''
    if (-not $expected.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Python вне папки установки' }
    foreach ($configured in @('', 'python', $expected)) {
        $result = Invoke-MergeCheckedScript -D @{Python=$configured} -Setup @{Gh=@{Token=''}} -Script $probe -Arguments @('проверка')
        if (-not $result.Ok -or $result.Data.exe -ine $expected -or $result.Data.arg -cne 'проверка') {
            throw ("не прошла проверка запуска из поставки: {0}" -f $result.Error)
        }
    }
    # Повторно ставим эту же версию с файлом, открытым без разрешения записи.
    $inUse = [IO.File]::Open($expected, 'Open', 'Read', 'Read')
    try {
        & (Join-Path $kit 'install.ps1') -Target $target -Unattended
        if ($LASTEXITCODE) { throw 'не удалось повторное обновление с занятым python.exe' }
    } finally { $inUse.Dispose() }

    # Новый каталог с неверной версией Python не должен стать активным.
    $versionFile = Join-Path $kit 'ci/runtime/python-version.txt'
    $current = [IO.File]::ReadAllText($versionFile).Trim()
    $kitRuntime = Split-Path -Parent $versionFile
    $invalid = '0.0.1'
    Copy-Item -LiteralPath (Join-Path $kitRuntime ('python-' + $current)) -Destination (Join-Path $kitRuntime ('python-' + $invalid)) -Recurse
    [IO.File]::WriteAllText($versionFile, $invalid)
    $rejected = $false
    try { & (Join-Path $kit 'install.ps1') -Target $target -Unattended }
    catch { if ($_.Exception.Message -notlike '*Не запустился комплектный Python*') { throw }; $rejected = $true }
    if (-not $rejected -or (Test-Path -LiteralPath (Join-Path $target ('runtime/python-' + $invalid)))) { throw 'неполный runtime принят' }
    if ((Get-DeliveryPython '') -cne $expected) { throw 'после ошибки изменился действующий Python' }
    Write-Host 'Занятый python.exe сохранился при обновлении, неисправная следующая версия отвергнута.'
    # Исполняем текст, который оператор копирует из журнала. Скрипт пробы только печатает свои аргументы.
    $savedPath = $env:Path
    Push-Location $work
    try {
        $env:Path = ''
        $manualScript = "проверка приёмки 'с кавычкой'.py"
        [IO.File]::WriteAllText((Join-Path $work $manualScript), 'import json, sys; print(json.dumps([sys.flags.isolated, sys.executable, sys.argv[1:]]))', [Text.UTF8Encoding]::new($false))
        $sha = '0123456789012345678901234567890123456789'
        $line = Format-DeliveryManualCommand -D @{Python='python'; MergeCheckedPath=$manualScript} -Number 23 -Merge $sha
        $start = $line.IndexOf("& '", [StringComparison]::Ordinal)
        if ($start -lt 0) { throw 'в журнале нет команды PowerShell' }
        $raw = & ([ScriptBlock]::Create($line.Substring($start)))
        if ($LASTEXITCODE) { throw 'команда из журнала не выполнилась' }
        $data = $raw | ConvertFrom-Json
        if ($data[0] -ne 1 -or $data[1] -ine $expected -or ($data[2] -join ',') -cne ("23,--merge," + $sha)) {
            throw 'команда из журнала потеряла интерпретатор, номер PR или ожидаемый SHA'
        }
        Write-Host 'Команда ручного слияния проверена с пустым PATH на скрипте без записи.'
    } finally {
        Pop-Location
        $env:Path = $savedPath
    }
} finally {
    $env:Path = $oldPath
    [Environment]::SetEnvironmentVariable('Path', $oldUserPath, 'User')
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
