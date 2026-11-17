#requires -Version 5.1
<#
.SYNOPSIS
    Настройки гейта и обновления рабочей базы: просмотр и правка config.psd1 из меню.
.DESCRIPTION
    Версия 00000000.000000.
    Пункт «Настройки» в меню гейта (ci, .\run.cmd без ключей) или отдельно: .\settings.cmd.
    Настройки сгруппированы, у каждой - описание. Правка меняет в config.psd1 только значение в строке
    настройки, комментарии и порядок остаются. Перед первой правкой - копия config.psd1.bak, после правки
    файл читается заново; не читается - возвращается прежний.
    Пароли не пишутся в config.psd1: вводятся скрыто и сохраняются в файл, зашифрованный для текущего
    пользователя Windows (DPAPI), в настройку - путь к файлу.
    Списки из нескольких строк (CanaryUsers) и ForbiddenBases (страховка рабочей базы) здесь только видны:
    правятся в файле руками.
#>
[CmdletBinding()]
param([string]$UiChannel = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($UiChannel) {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $ProgressPreference = 'SilentlyContinue'
}

$Root = $PSScriptRoot
$configPath = Join-Path $Root 'config.psd1'

. (Join-Path $Root 'ui.ps1')
Initialize-Ui -Channel $UiChannel

if (-not (Test-UiCanAsk)) { throw 'настройки правятся только из консоли или ci.exe' }
if (-not (Test-Path -LiteralPath $configPath)) {
    $example = Join-Path $Root 'config.example.psd1'
    if (-not (Test-Path -LiteralPath $example)) { throw "нет ни config.psd1, ни config.example.psd1 в $Root" }
    Copy-Item -LiteralPath $example -Destination $configPath
    Write-Host 'config.psd1 не было: создан из config.example.psd1.'
}

# Каталог настроек: группа, ключ, тип, описание, значение по умолчанию (как его берут run.ps1 и deploy.ps1, текстом
# для config.psd1). Типы: str, int, bool, list, enum, pass (файл пароля), ro (только видно, без умолчания).
$catalog = @(
    @('Базы', 'Server', 'str', 'сервер кластера 1С', ''''''),
    @('Базы', 'Base', 'str', 'тестовая база гейта (temp)', ''''''),
    @('Базы', 'File', 'str', 'файловая база вместо Server/Base: каталог базы; пусто - серверная', ''''''),
    @('Базы', 'ProdBase', 'str', 'рабочая база для обновления (deploy)', ''''''),
    @('Базы', 'ForbiddenBases', 'ro', 'базы, куда гейт не ходит никогда: страховка, правится в файле руками'),
    @('Базы', 'UnlockCode', 'str', 'код разрешения входа при блокировке сеансов (пусто - 0)', '''0'''),
    @('Пользователи и пароли', 'AdminUser', 'str', 'пользователь 1С для temp; пусто - вход под пользователем Windows', ''''''),
    @('Пользователи и пароли', 'AdminPassFile', 'pass', 'пароль AdminUser (файл, зашифрован для пользователя Windows)', ''''''),
    @('Пользователи и пароли', 'ProdAdminUser', 'str', 'пользователь 1С для рабочей; пусто - как AdminUser', ''''''),
    @('Пользователи и пароли', 'ProdAdminPassFile', 'pass', 'пароль ProdAdminUser; пусто - как AdminPassFile', ''''''),
    @('Пользователи и пароли', 'ClusterAgent', 'str', 'адрес агента кластера; пусто - tcp://<Server>', ''''''),
    @('Пользователи и пароли', 'ClusterAdmin', 'str', 'администратор кластера; пусто - без него', ''''''),
    @('Пользователи и пароли', 'ClusterAdminPassFile', 'pass', 'пароль администратора кластера', ''''''),
    @('Пользователи и пароли', 'CanaryUsers', 'ro', 'пользователи канареечного входа: список, правится в файле руками'),
    @('Подготовка базы', 'ReleaseJobsLock', 'bool', 'снимать блокировку регламентных заданий temp в конце гейта', '$false'),
    @('Подготовка базы', 'OnSessions', 'enum:Ask,Continue,Exit,Terminate', 'что делать, если в temp есть сеансы', '''Ask'''),
    @('Подготовка базы', 'SessionLockHours', 'int', 'на сколько часов ставить блокировку сеансов temp', '2'),
    @('Подготовка базы', 'OnNotGreen', 'enum:Ask,Keep,Rollback', 'что делать с комплектом при красном или жёлтом вердикте', '''Ask'''),
    @('Расширения и проверки', 'Extensions', 'list', 'расширения гейта, через запятую, нижний слой первым', '@()'),
    @('Расширения и проверки', 'CheckOnly', 'list', 'проверять только эти расширения; пусто - все', '@()'),
    @('Расширения и проверки', 'ContractorExtensions', 'list', 'расширения подрядчиков: правило R4 ищет в них правки без пометки автора', '@()'),
    @('Расширения и проверки', 'RunCheckConfig', 'bool', 'проверка конфигурации конфигуратором', '$true'),
    @('Расширения и проверки', 'ParallelCheckConfig', 'bool', 'проверка конфигурации параллельно с канарейкой и самопроверкой', '$true'),
    @('Расширения и проверки', 'CheckConfigFlags', 'str', 'ключи проверки конфигурации', '''-ConfigLogIntegrity -IncorrectReferences -ThinClient -Server -ExternalConnection -ExtendedModulesCheck'''),
    @('Расширения и проверки', 'RunCheckModules', 'bool', 'отдельный синтаксис-контроль (обычно не нужен: те же ошибки)', '$false'),
    @('Расширения и проверки', 'CheckModulesFlags', 'str', 'ключи синтаксис-контроля', '''-ThinClient -Server -ExternalConnection'''),
    @('Расширения и проверки', 'RunCheckCanApply', 'bool', 'проверка применимости расширений', '$true'),
    @('Канарейка', 'CanaryEpf', 'str', 'обработка канарейки', '''tools\Канарейка.epf'''),
    @('Канарейка', 'CanaryWaitSec', 'int', 'сколько секунд клиент живёт после старта', '10'),
    @('Канарейка', 'CanaryTimeoutSec', 'int', 'сколько ждать результата, секунд', '300'),
    @('Самопроверка', 'RunSelfCheck', 'bool', 'самопроверка обработкой «Выполнить после обновления»', '$true'),
    @('Самопроверка', 'Coverage', 'bool', 'карта покрытия после самопроверки: что из доработок чем задето', '$true'),
    @('Самопроверка', 'NightlyAt', 'str', 'время ночного прогона для nightly.cmd -Install (не с 22:00 до 02:00)', '''03:30'''),
    @('Самопроверка', 'MetricSlowFactor', 'str', 'во сколько раз дольше обычного операция считается медленной', '1.5'),
    @('Самопроверка', 'MetricMinDeltaMs', 'int', 'и насколько миллисекунд дольше', '500'),
    @('Самопроверка', 'MetricMinHistory', 'int', 'сколько замеров нужно в истории, чтобы сравнивать', '3'),
    @('Самопроверка', 'ExchangeMode', 'str', 'шаг «Обмены»: Full - пакет, очередь узла и срезы; Light - только объекты пакета', '''Full'''),
    @('Самопроверка', 'ExchangeQueuePerType', 'int', 'шаг «Обмены»: сколько объектов очереди узла брать на вид', '5'),
    @('Самопроверка', 'ExchangeQueueTotal', 'int', 'шаг «Обмены»: сколько объектов очереди узла брать всего', '50'),
    @('Самопроверка', 'ExchangeRules', 'bool', 'проверка правил обмена по выгрузке расширений (R1-R4), без 1С', '$true'),
    @('Самопроверка', 'SelfCheckEpf', 'str', 'обработка самопроверки', '''tools\ВыполнитьПослеОбновления.epf'''),
    @('Самопроверка', 'SelfCheckDocs', 'int', 'документов каждого вида, 1-50', '3'),
    @('Самопроверка', 'SelfCheckForms', 'bool', 'проверять формы расширений', '$true'),
    @('Самопроверка', 'SelfCheckPost', 'bool', 'проводить документы (в транзакции, всё отменяется)', '$true'),
    @('Самопроверка', 'SelfCheckSkipDocs', 'str', 'виды документов, которые не проводить, через запятую', ''''''),
    @('Самопроверка', 'SelfCheckNotOlder', 'str', 'документы не старше, ГГГГММДД; пусто - решает обработка', ''''''),
    @('Самопроверка', 'SelfCheckStartTimeoutSec', 'int', 'сколько ждать, пока обработка откроется, секунд', '300'),
    @('Самопроверка', 'ProcessingTimeoutSec', 'int', 'запись внешней обработки в справочник: сколько ждать итога, секунд', '600'),
    @('Самопроверка', 'SelfCheckStallMin', 'int', 'нет новых заданий дольше - перезапуск, минут', '20'),
    @('Самопроверка', 'SelfCheckRestarts', 'int', 'сколько раз перезапускать за прогон', '2'),
    @('Самопроверка', 'SelfCheckTimeoutMin', 'int', 'предел на один сеанс обработки, минут', '120'),
    @('Обновление рабочей', 'DeployExtensions', 'list', 'расширения для обновления рабочей; пусто - как Extensions', '@()'),
    @('Обновление рабочей', 'DeployDeniedFrom', 'int', 'с этого часа рабочую не обновлять', '22'),
    @('Обновление рабочей', 'DeployDeniedTo', 'int', 'до этого часа рабочую не обновлять', '2'),
    @('Обновление рабочей', 'ProdSelfCheckForms', 'bool', 'самопроверка на рабочей проверяет формы', '$false'),
    @('Обновление рабочей', 'ProdSelfCheckTimeoutMin', 'int', 'предел самопроверки на рабочей, минут', '60'),
    @('Обновление рабочей', 'DeployDir', 'str', 'папка запусков обновления', '''deploy'''),
    @('Обновление рабочей', 'ComTimeoutSec', 'int', 'сколько ждать ответа внешнего соединения при чтении расширений, секунд', '300'),
    @('Таймауты', 'TimeoutLoadMin', 'int', 'загрузка и выгрузка расширения, минут', '30'),
    @('Таймауты', 'TimeoutUpdateMin', 'int', 'обновление конфигурации БД, минут', '120'),
    @('Таймауты', 'TimeoutCheckMin', 'int', 'проверки конфигуратором, минут', '120'),
    @('Папки и интерфейс', 'InboxDir', 'str', 'папка с обновлениями для меню гейта', '''inbox'''),
    @('Папки и интерфейс', 'RunsDir', 'str', 'папка прогонов гейта', '''runs'''),
    @('Папки и интерфейс', 'StatsDir', 'str', 'папка статистики длительностей', '''stats'''),
    @('Папки и интерфейс', 'StatsDays', 'int', 'за сколько дней брать статистику для прогноза', '120')
)

$script:SettingsBackupDone = $false

function Read-SettingsConfig {
    return Import-PowerShellDataFile -LiteralPath $configPath
}

function Format-SettingValue {
    param($Value, [string]$Type)
    if ($null -eq $Value) { return '(нет в файле: по умолчанию)' }
    if ($Type -eq 'pass') {
        if (-not [string]$Value) { return '(пусто)' }
        $path = [string]$Value
        if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Root $path }
        if (Test-Path -LiteralPath $path) { return ("{0} (файл есть)" -f $Value) }
        return ("{0} (ФАЙЛА НЕТ)" -f $Value)
    }
    if ($Value -is [bool]) { if ($Value) { return 'да' } else { return 'нет' } }
    if ($Value -is [array]) {
        $parts = @($Value | ForEach-Object {
                $item = $_
                if ($item -is [hashtable]) { '{' + (@($item.Keys | Sort-Object | ForEach-Object { "{0}={1}" -f $_, $item[$_] }) -join '; ') + '}' }
                else { [string]$item }
            })
        if ($parts.Count -eq 0) { return '(пусто)' }
        return ($parts -join ', ')
    }
    $text = [string]$Value
    if (-not $text) { return '(пусто)' }
    return $text
}

function ConvertTo-PsdLiteral {
    param($Value, [string]$Type)
    if ($Type -eq 'bool') { if ($Value) { return '$true' } else { return '$false' } }
    if ($Type -eq 'int') { return ([string][int]$Value) }
    if ($Type -eq 'list') {
        $items = @($Value | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" })
        return '@(' + ($items -join ', ') + ')'
    }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Set-ConfigValue {
    # Меняет значение настройки в config.psd1, не трогая комментарии. Настройки нет - добавляет перед «}».
    param([string]$Key, [string]$Literal)
    $text = [System.IO.File]::ReadAllText($configPath)
    # Шаблон - в одинарных кавычках: в двойных PowerShell принял бы $(...) за вставку выражения и выполнил бы его.
    $valuePattern = '(?:''(?:[^'']|'''')*''|\$(?:true|false)|-?\d+|@\([^()\r\n]*\))'
    $pattern = '(?m)^(?<lead>[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[ \t]*)' + $valuePattern
    $found = [regex]::Matches($text, $pattern)
    if ($found.Count -gt 1) { throw "в config.psd1 настройка $Key встречается $($found.Count) раза: поправь файл руками" }
    if ($found.Count -eq 1) {
        $match = $found[0]
        $text = $text.Substring(0, $match.Index) + $match.Groups['lead'].Value + $Literal + $text.Substring($match.Index + $match.Length)
    }
    else {
        if ([regex]::IsMatch($text, '(?m)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=')) {
            throw "значение $Key в config.psd1 сложнее одной строки: поправь файл руками"
        }
        $end = $text.LastIndexOf('}')
        if ($end -lt 0) { throw 'config.psd1: не нашёл закрывающую скобку' }
        $text = $text.Substring(0, $end).TrimEnd() + "`r`n    $Key = $Literal`r`n" + $text.Substring($end)
    }
    if (-not $script:SettingsBackupDone) {
        Copy-Item -LiteralPath $configPath -Destination ($configPath + '.bak') -Force
        $script:SettingsBackupDone = $true
    }
    $previous = [System.IO.File]::ReadAllBytes($configPath)
    [System.IO.File]::WriteAllText($configPath, $text, (New-Object System.Text.UTF8Encoding($true)))
    try { $null = Read-SettingsConfig }
    catch {
        [System.IO.File]::WriteAllBytes($configPath, $previous)
        throw ("после правки config.psd1 не читается, вернул прежний: {0}" -f $_.Exception.Message)
    }
}

function Save-PasswordFile {
    # Пароль - в файл, зашифрованный для текущего пользователя Windows (DPAPI). Возвращает путь для настройки.
    param([string]$Key, [string]$Current)
    $relative = $Current
    if (-not $relative) { $relative = 'secrets\' + $Key.Replace('PassFile', '').ToLowerInvariant() + '.txt' }
    $first = Read-UiText -Prompt ("Пароль для {0} (не виден при вводе; Esc - отмена)" -f $Key) -Secret -CancelAsNull
    if ($null -eq $first) { return $null }
    $second = Read-UiText -Prompt 'Ещё раз тот же пароль' -Secret -CancelAsNull
    if ($null -eq $second) { return $null }
    if ($first -cne $second) { Show-UiTitle -Text 'Пароли не совпали: ничего не сохранил.' -Kind 'warn'; return $null }
    $path = $relative
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Root $path }
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $secure = ConvertTo-SecureString -String $first -AsPlainText -Force
    [System.IO.File]::WriteAllText($path, (ConvertFrom-SecureString -SecureString $secure))
    return $relative
}

function Edit-Setting {
    param([string]$Key, [string]$Type, [string]$Description, $Current)
    $shown = Format-SettingValue $Current $Type
    $header = "{0}: {1}. Сейчас: {2}" -f $Key, $Description, $shown
    if ($Type -eq 'ro') {
        Show-UiPager -Header $Key -Lines @($Description, '', ('Сейчас: ' + $shown), '', ("Правится в {0} руками." -f $configPath))
        return
    }
    $literal = $null
    switch -Regex ($Type) {
        '^bool$' {
            $index = Select-UiOne -Header $header -Items @('Да', 'Нет', 'Не менять')
            if ($index -eq 0) { $literal = ConvertTo-PsdLiteral $true 'bool' }
            elseif ($index -eq 1) { $literal = ConvertTo-PsdLiteral $false 'bool' }
        }
        '^enum:' {
            $values = @($Type.Substring(5) -split ',')
            $index = Select-UiOne -Header $header -Items (@($values) + @('Не менять'))
            if ($index -ge 0 -and $index -lt $values.Count) { $literal = ConvertTo-PsdLiteral $values[$index] 'str' }
        }
        '^int$' {
            $typed = Read-UiText -Prompt ($header + '. Новое значение (целое число)') -Default ([string]$Current) -CancelAsNull
            if ($null -ne $typed) {
                $number = 0
                if (-not [int]::TryParse($typed.Trim(), [ref]$number) -or $number -lt 0) { Show-UiTitle -Text ("«{0}» - не целое число: не сохранил." -f $typed) -Kind 'warn'; return }
                $literal = ConvertTo-PsdLiteral $number 'int'
            }
        }
        '^list$' {
            $now = ''
            if ($null -ne $Current) { $now = (@($Current) -join ', ') }
            $typed = Read-UiText -Prompt ($header + '. Через запятую; пусто - пустой список') -Default $now -CancelAsNull
            if ($null -ne $typed) { $literal = ConvertTo-PsdLiteral @($typed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) 'list' }
        }
        '^pass$' {
            $index = Select-UiOne -Header $header -Items @('Ввести пароль', 'Указать другой файл пароля', 'Очистить (без пароля)', 'Не менять')
            if ($index -eq 0) {
                $file = Save-PasswordFile -Key $Key -Current ([string]$Current)
                if ($null -ne $file) { $literal = ConvertTo-PsdLiteral $file 'str' }
            }
            elseif ($index -eq 1) {
                $typed = Read-UiText -Prompt 'Путь к файлу пароля (от папки гейта или полный)' -Default ([string]$Current) -CancelAsNull
                if ($null -ne $typed) { $literal = ConvertTo-PsdLiteral $typed.Trim() 'str' }
            }
            elseif ($index -eq 2) { $literal = ConvertTo-PsdLiteral '' 'str' }
        }
        default {
            $typed = Read-UiText -Prompt ($header + '. Новое значение') -Default ([string]$Current) -CancelAsNull
            # Код разрешения входа не бывает пустым: с пустым кодом гейт сам не войдёт в базу, которую заблокировал.
            if ($null -ne $typed -and $Key -eq 'UnlockCode' -and [string]::IsNullOrWhiteSpace($typed)) { $typed = '0' }
            if ($null -ne $typed) { $literal = ConvertTo-PsdLiteral $typed.Trim() 'str' }
        }
    }
    if ($null -eq $literal) { return }
    try {
        Set-ConfigValue -Key $Key -Literal $literal
        $after = Format-SettingValue ((Read-SettingsConfig)[$Key]) $Type
        Write-Host ("  {0} = {1}" -f $Key, $after)
        Show-UiTitle -Text ("Сохранено: {0} = {1}" -f $Key, $after) -Kind 'ok'
    }
    catch { Show-UiTitle -Text ("Не сохранил {0}: {1}" -f $Key, $_.Exception.Message) -Kind 'bad' }
}

function Show-Canary {
    # Временная кнопка: открыть канарейку в temp в режиме демонстрации, чтобы посмотреть её экран: успех или
    # провал выбирается случайно, сервер не вызывается, на гейт не влияет. 1С канарейка закрывает сама.
    $cfgNow = Read-SettingsConfig
    $binDir = [string]$cfgNow['V8Bin']
    $client = Join-Path $binDir '1cv8c.exe'
    if (-not $binDir -or -not (Test-Path -LiteralPath $client)) { Show-UiTitle -Text ("Нет тонкого клиента: {0} (настройка V8Bin)" -f $client) -Kind 'warn'; return }
    $epf = [string]$cfgNow['CanaryEpf']
    if (-not $epf) { $epf = 'tools\Канарейка.epf' }
    if (-not [System.IO.Path]::IsPathRooted($epf)) { $epf = Join-Path $Root $epf }
    if (-not (Test-Path -LiteralPath $epf)) { Show-UiTitle -Text ("Нет обработки канарейки: {0}" -f $epf) -Kind 'warn'; return }
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('ENTERPRISE')
    $arguments.Add(('/S"{0}\{1}"' -f $cfgNow['Server'], $cfgNow['Base']))
    $unlockNow = [string]$cfgNow['UnlockCode']
    if (-not $unlockNow) { $unlockNow = '0' }
    $arguments.Add(('/UC"{0}"' -f $unlockNow))
    $user = [string]$cfgNow['AdminUser']
    if ($user) {
        $arguments.Add(('/N"{0}"' -f $user))
        $passFile = [string]$cfgNow['AdminPassFile']
        if ($passFile) {
            if (-not [System.IO.Path]::IsPathRooted($passFile)) { $passFile = Join-Path $Root $passFile }
            if (Test-Path -LiteralPath $passFile) {
                $secure = ConvertTo-SecureString -String ((Get-Content -LiteralPath $passFile -Raw).Trim())
                $plain = (New-Object System.Management.Automation.PSCredential('user', $secure)).GetNetworkCredential().Password
                if ($plain) { $arguments.Add(('/P"{0}"' -f $plain)) }
            }
        }
    }
    $outFile = Join-Path $env:TEMP 'ci_show_canary.txt'
    Remove-Item -LiteralPath $outFile, ($outFile + '.started') -Force -ErrorAction SilentlyContinue
    $arguments.Add('/DisableStartupDialogs')
    $arguments.Add(('/Execute "{0}"' -f $epf))
    # demo: канарейка посидит, «проверит» и случайно покажет успех или провал; сервер не зовёт, файл не пишет.
    $arguments.Add(('/C"canary;demo;out={0};wait=6"' -f $outFile))
    $process = Start-Process -FilePath $client -ArgumentList ($arguments -join ' ') -PassThru
    # Ждём отметку «канарейка открылась» (файл .started): так видно, вошёл ли клиент в базу.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $false
    while ($watch.Elapsed.TotalSeconds -lt 180) {
        if (Test-Path -LiteralPath ($outFile + '.started')) { $started = $true; break }
        if ($process.HasExited) { break }
        Write-UiProgress -Title ("Канарейка входит в {0}" -f $cfgNow['Base']) -Elapsed $watch.Elapsed.TotalSeconds -Detail 'клиент 1С запускается'
        Start-Sleep -Milliseconds 250
    }
    Complete-UiProgress
    if ($started) {
        Show-UiTitle -Text ("Канарейка открылась в {0} за {1} с: смотри окно 1С. Посидит, «проверит» и случайно покажет успех (улетит) или провал, потом закроет 1С сама." -f $cfgNow['Base'], [int]$watch.Elapsed.TotalSeconds) -Kind 'ok'
    }
    elseif ($process.HasExited) {
        Show-UiTitle -Text ("1С закрылась, не открыв канарейку (код {0}): вход в {1} не прошёл." -f $process.ExitCode, $cfgNow['Base']) -Kind 'bad' `
            -More @('частая причина - блокировка начала сеансов: нужен её код в настройке UnlockCode (Базы)', 'или пароль AdminUser / AdminPassFile (Пользователи и пароли)')
    }
    else {
        Show-UiTitle -Text ("За {0} с канарейка так и не открылась: смотри окно 1С - там, скорее всего, вопрос или ошибка входа." -f [int]$watch.Elapsed.TotalSeconds) -Kind 'warn' `
            -More @('если это «начало сеансов запрещено» - задай код в настройке UnlockCode (Базы)')
    }
}

# Чего нет в config.psd1 - дописать со значением по умолчанию: в меню у каждой настройки видно, что стоит на деле.
$cfgStart = Read-SettingsConfig
$added = @()
foreach ($row in $catalog) {
    if ($row.Count -lt 5 -or $cfgStart.ContainsKey($row[1])) { continue }
    try { Set-ConfigValue -Key $row[1] -Literal $row[4]; $added += $row[1] }
    catch { Write-Host ("  {0}: умолчание не дописал - {1}" -f $row[1], $_.Exception.Message) -ForegroundColor Yellow }
}
if ($added.Count -gt 0) {
    Show-UiTitle -Text ("Дописал в config.psd1 настройки со значениями по умолчанию: {0}" -f $added.Count) -Kind 'info' -More @(($added -join ', '))
}

$groups = @($catalog | ForEach-Object { $_[0] } | Select-Object -Unique)
while ($true) {
    # «Показать канарейку» - временный пункт: посмотреть экран канарейки, ничего не меняет.
    $groupIndex = Select-UiOne -Header ("Настройки: {0}" -f $configPath) -Items (@($groups) + @('Показать канарейку (временно: открыть её в temp)', 'Готово'))
    if ($groupIndex -eq $groups.Count) { Show-Canary; continue }
    if ($groupIndex -lt 0 -or $groupIndex -ge $groups.Count) { break }
    $group = $groups[$groupIndex]
    while ($true) {
        $cfg = Read-SettingsConfig
        $rows = @($catalog | Where-Object { $_[0] -eq $group })
        $labels = @($rows | ForEach-Object {
                $value = $null
                if ($cfg.ContainsKey($_[1])) { $value = $cfg[$_[1]] }
                "{0} = {1}  - {2}" -f $_[1], (Format-SettingValue $value $_[2]), $_[3]
            })
        $index = Select-UiOne -Header ("Настройки, {0}: что поменять" -f $group) -Items (@($labels) + @('Назад'))
        if ($index -lt 0 -or $index -ge $rows.Count) { break }
        $row = $rows[$index]
        $current = $null
        if ($cfg.ContainsKey($row[1])) { $current = $cfg[$row[1]] }
        Edit-Setting -Key $row[1] -Type $row[2] -Description $row[3] -Current $current
    }
}
if ($script:SettingsBackupDone) { Write-Host ("Настройки сохранены в {0}, прежний файл - config.psd1.bak." -f $configPath) }
else { Write-Host 'Настройки не менялись.' }
