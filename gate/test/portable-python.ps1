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
$target = Join-Path $work 'папка гейта'
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
} finally {
    $env:Path = $oldPath
    [Environment]::SetEnvironmentVariable('Path', $oldUserPath, 'User')
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
