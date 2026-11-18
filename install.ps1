#requires -Version 5.1
<#
Установка гейта расширений 1С на машину, где он будет работать (рядом с кластером и тестовой базой).

Запуск: install.cmd из распакованного архива ci-gate_<версия>.zip (рядом с install.cmd лежит папка ci).
Что делает:
  1. копирует гейт в папку установки (по умолчанию C:\ci). Свои данные не трогает: config.psd1, runs, baseline, nightly,
     stats, inbox, secrets, deploy и собранные обработки в tools остаются как были;
  2. если config.psd1 ещё нет - спрашивает главное (платформа, тестовая база, рабочая база, расширения,
     под кем запускать конфигуратор) и пишет config.psd1 из образца config.example.psd1;
  3. по желанию собирает обработки «Выполнить после обновления» и «Канарейка» в tools конфигуратором тестовой базы;
  4. добавляет папку установки в PATH пользователя (без прав администратора) и проверяет скрипты (check.ps1).
Ключи: -Target <папка>, -Unattended (без вопросов: копирование, PATH и проверка; настройки - образцом).
#>
param(
    [string]$Target = '',
    [switch]$Unattended
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'ci'
if (-not (Test-Path -LiteralPath (Join-Path $source 'run.ps1'))) {
    throw "Рядом с install.ps1 нет папки ci с гейтом. Запускай из распакованного архива ci-gate_<версия>.zip."
}
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Read-Answer {
    # Вопрос с ответом по умолчанию (Enter - согласиться).
    param([string]$Question, [string]$Default = '')
    if ($Unattended) { return $Default }
    $hint = ''
    if ($Default) { $hint = " [$Default]" }
    $answer = Read-Host ("{0}{1}" -f $Question, $hint)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Read-YesNo {
    param([string]$Question, [bool]$Default = $true)
    if ($Unattended) { return $Default }
    $hint = 'Д/н'
    if (-not $Default) { $hint = 'д/Н' }
    while ($true) {
        $answer = Read-Host ("{0} ({1})" -f $Question, $hint)
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($answer -match '^(д|y|да|yes)$') { return $true }
        if ($answer -match '^(н|n|нет|no)$') { return $false }
    }
}

function ConvertTo-Literal {
    # Значение для config.psd1: строка в одинарных кавычках.
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Set-ConfigValue {
    # Меняет значение настройки в тексте config.psd1, комментарии не трогает. Шаблон - в одинарных кавычках:
    # в двойных PowerShell принял бы $(...) за вставку выражения.
    param([string]$Text, [string]$Key, [string]$Literal)
    $valuePattern = '(?:''(?:[^'']|'''')*''|\$(?:true|false)|-?\d+|@\([^()\r\n]*\))'
    $pattern = '(?m)^(?<lead>[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[ \t]*)' + $valuePattern
    $found = [regex]::Matches($Text, $pattern)
    if ($found.Count -ne 1) { throw "в образце настроек $Key найдено $($found.Count) раз" }
    $match = $found[0]
    return $Text.Substring(0, $match.Index) + $match.Groups['lead'].Value + $Literal + $Text.Substring($match.Index + $match.Length)
}

function Find-Platform {
    # Каталог bin самой новой платформы 1С на этой машине.
    $roots = @(${env:ProgramFiles}, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { Join-Path $_ '1cv8' }
    $found = @()
    foreach ($rootDir in $roots) {
        if (-not (Test-Path -LiteralPath $rootDir)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $rootDir -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' })) {
            $bin = Join-Path $dir.FullName 'bin'
            if (Test-Path -LiteralPath (Join-Path $bin '1cv8.exe')) { $found += [pscustomobject]@{ Version = [version]$dir.Name; Bin = $bin } }
        }
    }
    if ($found.Count -eq 0) { return '' }
    return @($found | Sort-Object Version -Descending)[0].Bin
}

Write-Host 'Установка гейта расширений 1С' -ForegroundColor Cyan
Write-Host ''

# 1. Папка установки и копирование.
if (-not $Target) { $Target = Read-Answer 'Папка установки' 'C:\ci' }
$Target = [System.IO.Path]::GetFullPath($Target)
New-Item -ItemType Directory -Path $Target -Force | Out-Null
# Своё: не затирается никогда. Остальное в папке установки - файлы гейта, их заменяет новая версия.
$keep = @('config.psd1', 'config.psd1.bak', 'runs', 'baseline', 'stats', 'inbox', 'secrets', 'deploy', 'kit', 'nightly', 'state', 'out', 'tests-runs')
# Файлы тестовых расширений (tests\<имя>) из поставки заменяют прежние целиком: удалённый в поставке модуль не должен
# остаться. Прежняя папка (могла быть забрана из temp и ещё не отправлена) - в tests\.old\<имя>_<время>.
$kitTests = Join-Path $source 'tests'
if (Test-Path -LiteralPath $kitTests) {
    foreach ($testDir in @(Get-ChildItem -LiteralPath $kitTests -Directory)) {
        $current = Join-Path (Join-Path $Target 'tests') $testDir.Name
        if (-not (Test-Path -LiteralPath $current)) { continue }
        $oldRoot = Join-Path (Join-Path $Target 'tests') '.old'
        New-Item -ItemType Directory -Path $oldRoot -Force | Out-Null
        $saved = Join-Path $oldRoot ('{0}_{1}' -f $testDir.Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $current -Destination $saved -Force
        Write-Host ("Прежние файлы тестов {0} - в {1}" -f $testDir.Name, $saved) -ForegroundColor DarkGray
    }
}
$copied = 0
foreach ($item in @(Get-ChildItem -LiteralPath $source -Recurse -File)) {
    $relative = $item.FullName.Substring($source.Length + 1)
    $top = $relative.Split('\')[0]
    if ($keep -contains $top) { continue }
    $destination = Join-Path $Target $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $item.FullName -Destination $destination -Force
    $copied++
}
foreach ($dir in @('tools', 'inbox', 'secrets')) { New-Item -ItemType Directory -Path (Join-Path $Target $dir) -Force | Out-Null }
Write-Host ("Скопировано файлов: {0} -> {1}" -f $copied, $Target) -ForegroundColor Green

# Настройки площадки (config.site.psd1, есть в заводской сборке): гейт берёт из них ключи, которых нет в config.psd1.
$sitePath = Join-Path $Target 'config.site.psd1'
if (Test-Path -LiteralPath (Join-Path $source 'config.site.psd1')) {
    $site = Import-PowerShellDataFile -LiteralPath $sitePath
    Write-Host ("Настройки площадки (config.site.psd1): {0}" -f (@($site.Keys | Sort-Object) -join ', ')) -ForegroundColor Green
    if (Test-Path -LiteralPath (Join-Path $Target 'config.psd1')) {
        $own = Import-PowerShellDataFile -LiteralPath (Join-Path $Target 'config.psd1')
        $shadowed = @($site.Keys | Where-Object { $own.ContainsKey($_) } | Sort-Object)
        if ($shadowed.Count -gt 0) {
            Write-Host ("  В config.psd1 уже есть {0} - действует значение оттуда. Чтобы брать из поставки, удали ключ из config.psd1." -f ($shadowed -join ', ')) -ForegroundColor Yellow
        }
    }
}

# 2. Настройки: только при первой установке.
$configPath = Join-Path $Target 'config.psd1'
$configFresh = $false
if (Test-Path -LiteralPath $configPath) {
    Write-Host 'config.psd1 уже есть - оставлен как был. Поменять настройки: settings.cmd (или ci -> Настройки).'
}
else {
    $configFresh = $true
    $text = [System.IO.File]::ReadAllText((Join-Path $Target 'config.example.psd1'), [System.Text.Encoding]::UTF8)
    Write-Host ''
    Write-Host 'Первичные настройки. Enter - значение в скобках. Всё можно поменять потом в settings.cmd.' -ForegroundColor Cyan

    $bin = Read-Answer 'Каталог bin платформы 1С' (Find-Platform)
    if ($bin -and -not (Test-Path -LiteralPath (Join-Path $bin '1cv8.exe'))) { Write-Host ("  В {0} нет 1cv8.exe - проверь путь потом в настройках." -f $bin) -ForegroundColor Yellow }
    $text = Set-ConfigValue $text 'V8Bin' (ConvertTo-Literal $bin)

    $fileBase = Read-YesNo 'Тестовая база файловая?' $false
    if ($fileBase) {
        $path = Read-Answer 'Каталог файловой тестовой базы' ''
        $text = Set-ConfigValue $text 'File' (ConvertTo-Literal $path)
        $testName = Split-Path -Leaf $path
    }
    else {
        $server = Read-Answer 'Сервер кластера 1С' 'srv-1c'
        $testName = Read-Answer 'Тестовая база в кластере (в имени должно быть temp, test, copy или stand)' 'erp_temp'
        $text = Set-ConfigValue $text 'Server' (ConvertTo-Literal $server)
        $text = Set-ConfigValue $text 'Base' (ConvertTo-Literal $testName)
    }
    if ($testName -notmatch '(?i)temp|test|copy|stand|тест|копи') {
        Write-Host ("  Имя «{0}» не похоже на тестовую базу: гейт с ней работать откажется." -f $testName) -ForegroundColor Yellow
    }

    $prod = Read-Answer 'Рабочая база (её обновляет deploy.cmd, гейт к ней не подходит; пусто - не задавать)' ''
    $text = Set-ConfigValue $text 'ProdBase' (ConvertTo-Literal $prod)
    $forbidden = @()
    if ($prod) { $forbidden = @($prod) }
    $text = Set-ConfigValue $text 'ForbiddenBases' ('@(' + (@($forbidden | ForEach-Object { ConvertTo-Literal $_ }) -join ', ') + ')')

    $extensionsText = Read-Answer 'Расширения, которые приходят комплектами, через запятую, нижний слой первым' ''
    $extensions = @($extensionsText -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $text = Set-ConfigValue $text 'Extensions' ('@(' + (@($extensions | ForEach-Object { ConvertTo-Literal $_ }) -join ', ') + ')')

    $admin = Read-Answer 'Пользователь 1С для конфигуратора (пусто - текущий пользователь Windows)' ''
    $text = Set-ConfigValue $text 'AdminUser' (ConvertTo-Literal $admin)
    if ($admin) {
        $secure = Read-Host ("Пароль пользователя {0} (хранится зашифрованным под твоей учёткой Windows)" -f $admin) -AsSecureString
        $passFile = 'secrets\admin.txt'
        [System.IO.File]::WriteAllText((Join-Path $Target $passFile), (ConvertFrom-SecureString -SecureString $secure), $utf8Bom)
        $text = Set-ConfigValue $text 'AdminPassFile' (ConvertTo-Literal $passFile)
    }
    [System.IO.File]::WriteAllText($configPath, $text, $utf8Bom)
    try { $null = Import-PowerShellDataFile -LiteralPath $configPath }
    catch { throw ("config.psd1 после записи не читается: {0}. Образец - config.example.psd1." -f $_.Exception.Message) }
    Write-Host ("Записал {0}" -f $configPath) -ForegroundColor Green
}

# 3. Обработки: выгрузки в файлы лежат в epf рядом с install.cmd, собирает их конфигуратор тестовой базы.
$epfSource = Join-Path $PSScriptRoot 'epf'
$tools = Join-Path $Target 'tools'
$processors = @(
    @{ Xml = 'ВыполнитьПослеОбновления.xml'; Epf = 'ВыполнитьПослеОбновления.epf' },
    @{ Xml = 'Канарейка.xml'; Epf = 'Канарейка.epf' })
if ((Test-Path -LiteralPath $epfSource) -and -not $Unattended) {
    $build = Read-YesNo 'Собрать обработки самопроверки и канарейки в tools конфигуратором тестовой базы сейчас?' $true
    if ($build) {
        $cfg = Import-PowerShellDataFile -LiteralPath $configPath
        $v8 = Join-Path ([string]$cfg['V8Bin']) '1cv8.exe'
        if (-not (Test-Path -LiteralPath $v8)) { Write-Host "Нет $v8 - обработки не собраны. Собери позже: install.cmd ещё раз или руками в конфигураторе." -ForegroundColor Yellow }
        else {
            $connection = @()
            if ([string]$cfg['File']) { $connection += ('/F"{0}"' -f $cfg['File']) } else { $connection += ('/S"{0}\{1}"' -f $cfg['Server'], $cfg['Base']) }
            if ([string]$cfg['AdminUser']) {
                $connection += ('/N"{0}"' -f $cfg['AdminUser'])
                if ([string]$cfg['AdminPassFile']) {
                    $encrypted = (Get-Content -LiteralPath (Join-Path $Target $cfg['AdminPassFile']) -Raw).Trim()
                    $credential = New-Object System.Management.Automation.PSCredential('user', (ConvertTo-SecureString -String $encrypted))
                    $connection += ('/P"{0}"' -f $credential.GetNetworkCredential().Password)
                }
            }
            foreach ($processor in $processors) {
                $xml = Join-Path $epfSource $processor.Xml
                $epf = Join-Path $tools $processor.Epf
                $log = Join-Path $env:TEMP ('ci-install-' + $processor.Epf + '.log')
                $arguments = @('DESIGNER') + $connection + @('/DisableStartupDialogs', '/DisableStartupMessages',
                    '/LoadExternalDataProcessorOrReportFromFiles', ('"{0}"' -f $xml), ('"{0}"' -f $epf), '/Out', ('"{0}"' -f $log))
                $process = Start-Process -FilePath $v8 -ArgumentList ($arguments -join ' ') -PassThru -Wait
                if ($process.ExitCode -eq 0 -and (Test-Path -LiteralPath $epf)) { Write-Host ("Собрана {0}" -f $epf) -ForegroundColor Green }
                else { Write-Host ("Не собралась {0} (код {1}), лог: {2}" -f $processor.Epf, $process.ExitCode, $log) -ForegroundColor Yellow }
            }
        }
    }
}

# 4. PATH пользователя и проверка скриптов.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (@($userPath -split ';' | Where-Object { $_.TrimEnd('\') -ieq $Target.TrimEnd('\') }).Count -eq 0) {
    [Environment]::SetEnvironmentVariable('Path', (($userPath + ';' + $Target).TrimStart(';')), 'User')
    Write-Host ("Добавил {0} в PATH пользователя: в новом окне PowerShell работают ci, gate, deploy, report." -f $Target) -ForegroundColor Green
}
& (Join-Path $Target 'check.ps1')

Write-Host ''
Write-Host 'Готово.' -ForegroundColor Green
if ($configFresh) { Write-Host '  Остальные настройки (канарейка, самопроверка, таймауты): settings.cmd или ci -> Настройки.' }
Write-Host '  Проверить гейт без 1С: test.cmd. Начать работу: ci (экран) или gate (консоль).'
Write-Host ("  Руководство: {0}" -f (Join-Path $Target 'readme.txt'))
