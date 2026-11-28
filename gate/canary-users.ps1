#requires -Version 5.1

# Именные входы площадки одинаковы в гейте и при проверке обновления рабочей.
# Пароль читается отдельно, непосредственно перед запуском клиента.
function Get-GateCanaryProfiles {
    param([hashtable]$Config, [switch]$Deploy)

    $priority = @(Get-Setting $Config 'PriorityCanaryUsers' @())
    $seen = @{}
    foreach ($entry in $priority) {
        $name = ([string]$entry['Name']).Trim()
        if (-not $name -or $seen.ContainsKey($name)) { throw 'В PriorityCanaryUsers нужно уникальное непустое имя пользователя ИБ.' }
        $seen[$name] = $true
        $passFile = [string]$entry['PassFile']
        $windows = [string]$entry['WindowsAccount']
        $mode = 'Missing'
        if ($passFile -and (Test-Path -LiteralPath (Resolve-RootPath $passFile) -PathType Leaf)) { $mode = 'Password' }
        elseif ($windows -and [Security.Principal.WindowsIdentity]::GetCurrent().Name -ieq $windows) { $mode = 'Windows' }
        [pscustomobject]@{ Name = $name; Label = $name; PassFile = $passFile; Mode = $mode; Optional = [bool]$entry['Optional']; Expected = $name }
    }
    if ($priority.Count -gt 0 -and @($priority | Where-Object { -not [bool]$_['Optional'] }).Count -eq 0) {
        throw 'В PriorityCanaryUsers нужен хотя бы один обязательный вход. Для обязательного пользователя установите Optional = $false.'
    }
    if ($Deploy) {
        if ($priority.Count -eq 0) {
            [pscustomobject]@{ Name = ''; Label = ''; PassFile = ''; Mode = 'DeployAdmin'; Optional = $false; Expected = '' }
        }
        return
    }
    foreach ($entry in @(Get-Setting $Config 'CanaryUsers' @() | Where-Object { $_ })) {
        $name = [string]$entry['Name']
        if ($priority.Count -gt 0 -and (-not $name.Trim() -or $seen.ContainsKey($name))) { continue }
        $label = $name
        if (-not $label) { $label = 'текущий пользователь Windows' }
        [pscustomobject]@{ Name = $name; Label = $label; PassFile = [string]$entry['PassFile']; Mode = 'Legacy'; Optional = $false; Expected = '' }
    }
}

function Get-GateCanaryAuthArgs {
    param($Profile)
    trap {
        if ($Profile.PassFile) {
            throw ("Проверка входа пользователя {0} остановлена. Проверьте файл {1} под пользователем Windows, который запускает гейт. {2}" -f $Profile.Name, $Profile.PassFile, $_.Exception.Message)
        }
        throw ("Проверка входа пользователя {0} остановлена. Сверьте способ входа и доступность учётных данных для этого пользователя. {1}" -f $Profile.Name, $_.Exception.Message)
    }
    switch ($Profile.Mode) {
        'Missing' { throw ('Нет подходящей доменной учётки или файла пароля для {0}. Проверьте WindowsAccount и путь PassFile в PriorityCanaryUsers. Настроенный файл: {1}' -f $Profile.Name, $Profile.PassFile) }
        'Windows' { return '/WA+' }
        'DeployAdmin' { return }
    }
    if ($Profile.Mode -eq 'Password') { '/WA-' }
    if ($Profile.Name) {
        # Формат отдельных аргументов 1cv8c.exe при сборке строки для Start-Process.
        # Строки в кавычках экранируем по правилам командной строки Windows.
        '/N"' + (ConvertTo-CanaryQuotedValue $Profile.Name) + '"'
        $password = Get-PlainPassword $Profile.PassFile
        if ($Profile.Mode -eq 'Password' -and [string]::IsNullOrEmpty($password)) { throw 'Файл пароля пуст.' }
        if ($password) { '/P"' + (ConvertTo-CanaryQuotedValue $password) + '"' }
    }
}

function ConvertTo-CanaryQuotedValue {
    param([string]$Value)
    return (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1')
}

function Test-GateCanaryIdentity {
    param($Profile, [string[]]$Lines)
    if (-not $Profile.Expected) { return '' }
    $users = @($Lines | Where-Object { $_ -like 'user=*' })
    if ($users.Count -ne 1) { return ('Канарейка не подтвердила пользователя ИБ «{0}»: ожидалась одна строка user=.' -f $Profile.Expected) }
    $actual = $users[0].Substring(5)
    if (-not [string]::Equals($Profile.Expected, $actual, [StringComparison]::OrdinalIgnoreCase)) {
        return ('Ожидался пользователь ИБ «{0}», фактически вошёл «{1}».' -f $Profile.Expected, $actual)
    }
    return ''
}

# Маскируем аргумент целиком до соединения строки: пароль может сам содержать кавычки.
function Format-GateCanaryCommand {
    param([string[]]$Arguments)
    $safe = foreach ($arg in $Arguments) {
        if ($arg.StartsWith('/P"', [StringComparison]::OrdinalIgnoreCase)) { '/P"***"' } else { $arg }
    }
    return ($safe -join ' ')
}
