#requires -Version 5.1
<#
Модульные тесты YAxUnit без 1С: проверка описаний тестов, каталог, заготовки модуля и теста. Работает с выгрузкой
тестового расширения в файлы (папка с Configuration.xml), в базу не ходит. Версия 00000000.000000.

  .\unittests-cli.ps1 -Check tests\<расширение>
      замечания к описаниям (шапкам) и регистрациям тестов; код возврата 1, если замечания есть.
  .\unittests-cli.ps1 -Catalog tests\<расширение> -Out <папка>
      каталог: <папка>\unittests.catalog.json и unittests.catalog.txt.
  .\unittests-cli.ps1 -Dir tests\<расширение> -NewModule ОМ_<модуль> -Subsystem <подсистема> -Method <тест> -Presentation "что проверяет" -Checks "CommonModule.<модуль>.<метод>" [-How "..."] [-Why "..."] [-Author "Фамилия И.О. ГГГГММДД"] [-Tags "a, b"] [-Client]
      новый модуль тестов: XML, Module.bsl с регистрацией и тестом, запись в Configuration.xml и в подсистему.
  .\unittests-cli.ps1 -Dir tests\<расширение> -Module ОМ_<модуль> -NewTest <тест> -Presentation "..." -Checks "..." [-How] [-Why] [-Author] [-Tags]
      новый тест в модуле: процедура с шапкой и строка регистрации.
Формат шапки - в начале unittests.ps1 и в readme.txt (раздел про модульные тесты).
#>
param(
    [string]$Check = '',
    [string]$Catalog = '',
    [string]$Out = '',
    [string]$Dir = '',
    [string]$NewModule = '',
    [string]$NewTest = '',
    [string]$Module = '',
    [string]$Subsystem = '',
    [string]$Method = '',
    [string]$Presentation = '',
    [string]$Checks = '',
    [string]$How = '',
    [string]$Why = '',
    [string]$Author = '',
    [string]$Tags = '',
    [switch]$Client
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'unittests.ps1')

try {
    if ($Check) {
        $found = Get-UtCatalog -Dir $Check
        if (-not $found.Ok) { Write-Host ("{0}: {1}" -f $Check, $found.Error) -ForegroundColor Red; exit 1 }
        Write-Host ("Тесты {0}: {1}, модулей {2}" -f $found.Extension, @($found.Tests).Count, @($found.Modules | Where-Object { -not $_.Helper }).Count)
        foreach ($problem in @($found.Problems)) { Write-Host ('  ' + (Format-UtProblem $problem)) -ForegroundColor Yellow }
        if (@($found.Problems).Count -gt 0) { Write-Host ("Замечаний к описаниям: {0}" -f @($found.Problems).Count) -ForegroundColor Yellow; exit 1 }
        Write-Host 'Замечаний к описаниям нет.' -ForegroundColor Green
        exit 0
    }
    if ($Catalog) {
        if (-not $Out) { throw 'нужен -Out: папка для каталога' }
        $found = Get-UtCatalog -Dir $Catalog
        if (-not $found.Ok) { throw $found.Error }
        Write-UtCatalog -Catalog $found -Dir $Out
        Write-Host ("Каталог: {0}" -f (Join-Path $Out 'unittests.catalog.txt'))
        exit 0
    }
    if ($NewModule) {
        if (-not $Dir -or -not $Subsystem -or -not $Method -or -not $Presentation -or -not $Checks) { throw 'для -NewModule нужны -Dir, -Subsystem, -Method, -Presentation, -Checks' }
        $path = New-UtModule -Dir $Dir -Name $NewModule -Subsystem $Subsystem -Method $Method -Presentation $Presentation -Checks $Checks -How $How -Why $Why -Author $Author -Tags $Tags -Client ([bool]$Client)
        Write-Host ("Создан модуль: {0}" -f $path) -ForegroundColor Green
        exit 0
    }
    if ($NewTest) {
        if (-not $Dir -or -not $Module -or -not $Presentation -or -not $Checks) { throw 'для -NewTest нужны -Dir, -Module, -Presentation, -Checks' }
        $path = Add-UtTest -Dir $Dir -Module $Module -Method $NewTest -Presentation $Presentation -Checks $Checks -How $How -Why $Why -Author $Author -Tags $Tags
        Write-Host ("Тест добавлен: {0}" -f $path) -ForegroundColor Green
        exit 0
    }
    Write-Host 'Ключи: -Check <папка>, -Catalog <папка> -Out <папка>, -NewModule, -NewTest (см. начало файла).'
    exit 2
}
catch {
    Write-Host ("Не получилось: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
