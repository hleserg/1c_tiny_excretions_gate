#requires -Version 5.1

# Свойства одного запрета начала сеансов, включая параметры выключенного запрета.
function Get-GateSessionSettings {
    param($InfoBase)
    return @{
        SessionsDenied = [bool]$InfoBase.SessionsDenied
        PermissionCode = [string]$InfoBase.PermissionCode
        DeniedMessage = [string]$InfoBase.DeniedMessage
        DeniedFrom = $InfoBase.DeniedFrom
        DeniedTo = $InfoBase.DeniedTo
    }
}

function New-GateLockState {
    return @{
        JobsSet = $false
        Before = $null
        Expected = @()
        Marker = [guid]::NewGuid().ToString('N')
    }
}

function Test-GateSessionSettings {
    param($Settings, $InfoBase)
    return ($Settings.SessionsDenied -eq [bool]$InfoBase.SessionsDenied -and
        $Settings.PermissionCode -ceq [string]$InfoBase.PermissionCode -and
        $Settings.DeniedMessage -ceq [string]$InfoBase.DeniedMessage -and
        $Settings.DeniedFrom -eq $InfoBase.DeniedFrom -and $Settings.DeniedTo -eq $InfoBase.DeniedTo)
}

function Test-GateSessionLock {
    param($State, $InfoBase)
    foreach ($settings in $State.Expected) {
        if (Test-GateSessionSettings $settings $InfoBase) { return $true }
    }
    return $false
}

function Set-GateJobsLock {
    param($State, $Target, [scriptblock]$ReadAgain)
    $infoBase = & $ReadAgain $Target
    if ([bool]$infoBase.ScheduledJobsDenied) { return $false }
    $infoBase.ScheduledJobsDenied = $true
    $null = $Target.Process.UpdateInfoBase($infoBase)
    # У флага нет кода владельца. Если сервер не ответил на запись, право снять его не присваиваем.
    $State.JobsSet = $true
    $check = & $ReadAgain $Target
    if (-not [bool]$check.ScheduledJobsDenied) {
        $State.JobsSet = $false
        throw 'запрет регламентных заданий не записался'
    }
    return $true
}

function Set-GateSessionLock {
    param($State, $Target, [datetime]$From, [datetime]$Until, [string]$Code, [string]$Message, [scriptblock]$ReadAgain)
    $infoBase = & $ReadAgain $Target
    if ($State.Expected.Count) {
        if (-not (Test-GateSessionLock $State $InfoBase)) { throw 'блокировка начала сеансов изменилась во время обновления' }
    }
    else {
        if ([bool]$InfoBase.SessionsDenied) { throw 'блокировка начала сеансов уже установлена' }
        $State.Before = Get-GateSessionSettings $InfoBase
    }

    # Кластер хранит время с точностью до секунды. Метка отличает два запуска с одним кодом разрешения.
    $InfoBase.DeniedFrom = $From.AddTicks(-($From.Ticks % [timespan]::TicksPerSecond))
    $InfoBase.DeniedTo = $Until.AddTicks(-($Until.Ticks % [timespan]::TicksPerSecond))
    $InfoBase.PermissionCode = $Code
    $InfoBase.DeniedMessage = "$Message [гейт $($State.Marker)]"
    $InfoBase.SessionsDenied = $true
    $next = Get-GateSessionSettings $InfoBase
    # При потере ответа на перенос начала блокировки в кластере может остаться любая из двух наших записей.
    $State.Expected = @($State.Expected) + @($next)
    $null = $Target.Process.UpdateInfoBase($InfoBase)
    $check = & $ReadAgain $Target
    if (-not (Test-GateSessionSettings $next $check)) { throw 'запись блокировки начала сеансов не подтверждена' }
    $State.Expected = @($next)
}

function Restore-GateLocks {
    param($State, $Target, [bool]$ReleaseJobs, [scriptblock]$ReadAgain)
    $infoBase = & $ReadAgain $Target
    $changes = New-Object System.Collections.Generic.List[string]
    if ($State.Expected.Count) {
        if (Test-GateSessionLock $State $infoBase) {
            foreach ($key in $State.Before.Keys) { $infoBase.$key = $State.Before[$key] }
            $changes.Add('блокировку начала сеансов')
        }
        else {
            $State.Expected = @()
            Write-Warning 'Блокировку начала сеансов изменили или сняли. Оставляю её текущие параметры.'
        }
    }
    $jobs = ($ReleaseJobs -and $State.JobsSet -and [bool]$infoBase.ScheduledJobsDenied)
    if ($jobs) {
        $infoBase.ScheduledJobsDenied = $false
        $changes.Add('блокировку регламентных заданий')
    }
    # Даже при потере ответа на снятие нельзя сбросить повторно включённый кем-то запрет регламентных.
    $State.JobsSet = $false
    if (-not $changes.Count) { return }
    try {
        $null = $Target.Process.UpdateInfoBase($infoBase)
        $check = & $ReadAgain $Target
    }
    catch {
        if ($jobs) { Write-Warning 'Снятие запрета регламентных заданий не подтверждено. Проверь свойства базы в консоли кластера.' }
        throw
    }
    if ($State.Expected.Count -and (Test-GateSessionLock $State $check)) { throw 'после записи всё ещё стоит наша блокировка начала сеансов' }
    if ($State.Expected.Count -and -not (Test-GateSessionSettings $State.Before $check)) {
        Write-Warning 'Исходные параметры запрета сеансов не подтверждены. Проверь свойства базы в консоли кластера.'
    }
    $State.Expected = @()
    if ($jobs -and [bool]$check.ScheduledJobsDenied) { throw 'запрет регламентных заданий по-прежнему включён, проверьте его в консоли кластера' }
    return ($changes -join ' и ')
}
