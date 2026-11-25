#requires -Version 5.1
# ** Хлебников С.Ю. 20261123 Конфигуратор существующей тестовой базы. Имена расширений выбирает только этот процесс.
function Invoke-WorkerDesigner {
    param($Profile, [string[]]$Command, [string]$Log)
    $argList = @('DESIGNER', ('/S"{0}\{1}"' -f $Profile.Server,$Profile.Base),
        ('/N"{0}"' -f $Profile.User), ('/P"{0}"' -f $Profile.Password),
        '/DisableStartupDialogs', '/DisableStartupMessages') + $Command + @('/Out', ('"{0}"' -f $Log))
    $proc = Start-Process -FilePath $Profile.Designer -ArgumentList $argList -WindowStyle Hidden -PassThru
    try {
        $null = $proc.Handle
        if (-not $proc.WaitForExit(1200000)) {
            $proc.Kill()
            $proc.WaitForExit()
            throw "Таймаут Конфигуратора. Журнал $Log"
        }
        if ($proc.ExitCode -ne 0 -or -not [IO.File]::Exists($Log)) {
            throw ("Конфигуратор завершил {0} с кодом {1}. Журнал {2}" -f $Command[0],$proc.ExitCode,$Log)
        }
    }
    finally { $proc.Dispose() }
}

function Get-WorkerInventory {
    param($Profile, [string]$Log)
    Invoke-WorkerDesigner $Profile @('/DumpDBCfgList','-AllExtensions') $Log
    foreach ($line in [IO.File]::ReadAllLines($Log)) {
        if (-not $line.Trim()) { continue }
        if ($line -notmatch '^[\p{L}_][\p{L}\p{Nd}_]*$') { throw "Не удалось прочесть список расширений. Журнал $Log" }
        $line
    }
}

function Invoke-WorkerExtension {
    param($Profile, [ValidateSet('expand','build')][string]$Operation, [string]$Source, [string]$Output, [string]$Work)
    $slot = 'GateJob' + [Guid]::NewGuid().ToString('N')
    $guardPath = Join-Path $Profile.WorkRoot 'active-extension.json'
    if ([IO.File]::Exists($guardPath)) { throw "Есть незавершённая операция. Сверьте $guardPath с базой." }
    $before = @(Get-WorkerInventory $Profile (Join-Path $Work 'before.log'))
    if ($before -contains $slot) { throw "Служебное имя $slot уже занято" }
    $operationLog = Join-Path $Work 'load.log'
    $lease = @{ extension=$slot; server=$Profile.Server; base=$Profile.Base; work=$Work; before=$before }
    [IO.File]::WriteAllText($guardPath, ($lease | ConvertTo-Json))
    $owned = $false
    try {
        $load = '/LoadCfg'
        if ($Operation -eq 'build') { $load = '/LoadConfigFromFiles' }
        Invoke-WorkerDesigner $Profile @($load, ('"{0}"' -f $Source), '-Extension', $slot) $operationLog
        $after = @(Get-WorkerInventory $Profile (Join-Path $Work 'loaded.log'))
        $added = @($after | Where-Object { $before -notcontains $_ })
        if ($added.Count -ne 1 -or $added[0] -cne $slot -or $after.Count -ne $before.Count+1) {
            throw "Состав расширений изменился неожиданно. Проверьте $guardPath"
        }
        $owned = $true
        if ($Operation -eq 'expand') {
            [void][IO.Directory]::CreateDirectory($Output)
            Invoke-WorkerDesigner $Profile @('/DumpConfigToFiles', ('"{0}"' -f $Output), '-Extension', $slot) (Join-Path $Work 'dump.log')
            if (-not [IO.File]::Exists((Join-Path $Output 'Configuration.xml'))) { throw 'Не выгрузился Configuration.xml' }
            [IO.File]::Delete((Join-Path $Output 'ConfigDumpInfo.xml'))
        }
        else {
            Invoke-WorkerDesigner $Profile @('/DumpCfg', ('"{0}"' -f $Output), '-Extension', $slot) (Join-Path $Work 'build.log')
            if (-not [IO.File]::Exists($Output)) { throw 'Собранный CFE отсутствует' }
        }
    }
    finally {
        # После неясного исхода загрузки и при изменении состава оставляем свидетельство оператору.
        if ($owned) {
            $current = @(Get-WorkerInventory $Profile (Join-Path $Work 'cleanup-before.log'))
            if ((@($current | Sort-Object) -join '|') -cne (@($after | Sort-Object) -join '|')) { throw "Перед очисткой изменился список расширений. Проверьте $guardPath" }
            Invoke-WorkerDesigner $Profile @('/DeleteCfg','-Extension',$slot) (Join-Path $Work 'delete.log')
            $remaining = @(Get-WorkerInventory $Profile (Join-Path $Work 'cleanup-after.log'))
            if ((@($remaining | Sort-Object) -join '|') -cne (@($before | Sort-Object) -join '|')) { throw "После очистки изменился состав расширений. Проверьте $guardPath" }
            [IO.File]::Delete($guardPath)
        }
    }
    if ($Operation -eq 'build') {
        [xml]$xml = [IO.File]::ReadAllText((Join-Path $Source 'Configuration.xml'))
        $expected = $xml.SelectSingleNode("/*[local-name()='MetaDataObject']/*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Name']")
        if ($null -eq $expected -or (Get-WorkerMetadata $Profile $Output -Check) -cne $expected.InnerText) {
            throw 'Проверенный CFE не соответствует исходному расширению'
        }
    }
}
# ** Хлебников С.Ю. 20261123 конец
# ** Хлебников С.Ю. 20261123 Проверка кандидата в его настоящем месте в порядке расширений, до записи в базу.
function Get-WorkerMember {
    param($Object, [string]$Name, [object[]]$Arguments = $null)
    $flags = [Reflection.BindingFlags]::GetProperty
    if ($null -ne $Arguments) {
        $flags = [Reflection.BindingFlags]::InvokeMethod
        for ($i=0; $i -lt $Arguments.Count; $i++) { $Arguments[$i] = $Arguments[$i].PSObject.BaseObject }
    }
    return ,([type]::GetType('System.__ComObject').InvokeMember($Name,$flags,$null,$Object,$Arguments))
}

function Get-WorkerMetadata {
    param($Profile,[string]$Cfe,[switch]$Check)
    $connector = New-Object -ComObject V83.COMConnector
    $connection = $null
    try {
        $line = 'Srvr="{0}";Ref="{1}";Usr="{2}";Pwd="{3}";' -f $Profile.Server,$Profile.Base,$Profile.User.Replace('"','""'),$Profile.Password.Replace('"','""')
        $connection = $connector.Connect($line)
        $meta = Get-WorkerMember $connection 'Metadata'
        $config = (Get-WorkerMember $meta 'Name') + ' ' + (Get-WorkerMember $meta 'Version')
        if (-not $Cfe) { return $config }
        $manager = Get-WorkerMember $connection 'ConfigurationExtensions'
        $data = Get-WorkerMember $connection 'Base64Value' @([Convert]::ToBase64String([IO.File]::ReadAllBytes($Cfe)))
        $preview = Get-WorkerMember $manager 'Create' @($data)
        $name = Get-WorkerMember $preview 'Name'
        if (-not $name) { throw '1С не вернула имя расширения из CFE' }
        if ($Check) {
            $source = Get-WorkerMember (Get-WorkerMember $connection 'ConfigurationExtensionsSource') 'Database'
            $list = Get-WorkerMember $manager 'Get' @((Get-WorkerMember $connection 'NewObject' @('Structure')),$source)
            $target = $preview
            for ($i=0; $i -lt (Get-WorkerMember $list 'Count' @()); $i++) {
                $ext = Get-WorkerMember $list 'Get' @($i)
                if ((Get-WorkerMember $ext 'Name') -ieq $name) { $target=$ext; break }
            }
            $issues = Get-WorkerMember $target 'CheckCanApply' @($data)
            $count = Get-WorkerMember $issues 'Count' @()
            if ($count -ne 0) { throw "1С вернула замечания применимости для $name ($count)" }
        }
        return $name
    }
    finally {
        if ($null -ne $connection) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($connection) }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($connector)
    }
}
# ** Хлебников С.Ю. 20261123 конец
