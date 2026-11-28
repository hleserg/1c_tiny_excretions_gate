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
        # Метка запуска в сообщении блокировки: его видят пользователи, поэтому она короткая.
        Marker = [guid]::NewGuid().ToString('N').Substring(0, 6)
    }
}

function Test-GateSameMoment {
    # Кластер хранит время с точностью до секунды и может вернуть его не знак в знак: допуск - секунда.
    param($Left, $Right)
    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    try { return ([Math]::Abs(([datetime]$Left - [datetime]$Right).TotalSeconds) -le 1) }
    catch { return ($Left -eq $Right) }
}

function Test-GateSessionSettings {
    # Те же параметры запрета сеансов? Код разрешения - знак в знак; сообщение - без крайних пробелов; даты - с
    # допуском в секунду: точное сравнение при малейшем расхождении посчитало бы свою блокировку чужой, и она
    # осталась бы на базе.
    param($Settings, $InfoBase)
    return ($Settings.SessionsDenied -eq [bool]$InfoBase.SessionsDenied -and
        $Settings.PermissionCode -ceq [string]$InfoBase.PermissionCode -and
        ([string]$Settings.DeniedMessage).Trim() -ceq ([string]$InfoBase.DeniedMessage).Trim() -and
        (Test-GateSameMoment $Settings.DeniedFrom $InfoBase.DeniedFrom) -and (Test-GateSameMoment $Settings.DeniedTo $InfoBase.DeniedTo))
}

function Test-GateOwnWrite {
    # Запись блокировки подтверждена: запрет стоит, код разрешения наш, в сообщении метка этого запуска. Даты и
    # точный текст кластер может вернуть иначе, чем их записали (точность, часовой пояс), поэтому «своей» дальше
    # считается то, что он вернул сам (Set-GateSessionLock запоминает прочитанное, а не записанное).
    param([string]$Code, [string]$Marker, $InfoBase)
    return ([bool]$InfoBase.SessionsDenied -and $Code -ceq [string]$InfoBase.PermissionCode -and
        ([string]$InfoBase.DeniedMessage).Contains(('[{0}]' -f $Marker)))
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
        throw 'Запрет регламентных заданий не записался. Проверьте свойства базы в консоли кластера и права пользователя на их изменение.'
    }
    return $true
}

function Set-GateSessionLock {
    param($State, $Target, [datetime]$From, [datetime]$Until, [string]$Code, [string]$Message, [scriptblock]$ReadAgain)
    $infoBase = & $ReadAgain $Target
    if ($State.Expected.Count) {
        if (-not (Test-GateSessionLock $State $InfoBase)) { throw 'Блокировка начала сеансов изменилась во время обновления. Сверьте срок и сообщение блокировки в консоли кластера и согласуйте продолжение с её владельцем.' }
    }
    else {
        if ([bool]$InfoBase.SessionsDenied) { throw 'Блокировка начала сеансов уже установлена. Проверьте срок и сообщение блокировки в консоли кластера. Согласуйте время повтора с её владельцем.' }
        $State.Before = Get-GateSessionSettings $InfoBase
    }

    # Кластер хранит время с точностью до секунды. Метка отличает два запуска с одним кодом разрешения.
    $InfoBase.DeniedFrom = $From.AddTicks(-($From.Ticks % [timespan]::TicksPerSecond))
    $InfoBase.DeniedTo = $Until.AddTicks(-($Until.Ticks % [timespan]::TicksPerSecond))
    $InfoBase.PermissionCode = $Code
    $InfoBase.DeniedMessage = '{0} [{1}]' -f $Message, $State.Marker
    $InfoBase.SessionsDenied = $true
    $next = Get-GateSessionSettings $InfoBase
    # При потере ответа на перенос начала блокировки в кластере может остаться любая из двух наших записей.
    $State.Expected = @($State.Expected) + @($next)
    $null = $Target.Process.UpdateInfoBase($InfoBase)
    $check = & $ReadAgain $Target
    if (-not (Test-GateOwnWrite $Code $State.Marker $check)) { throw 'Кластер не подтвердил запись блокировки начала сеансов. Проверьте фактический срок и сообщение блокировки в свойствах базы перед повтором.' }
    # Своя блокировка - в том виде, в каком её вернул кластер: с ним и сверяется перед переносом и снятием.
    $State.Expected = @(Get-GateSessionSettings $check)
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
    if ($State.Expected.Count -and (Test-GateSessionLock $State $check)) { throw 'После попытки снятия всё ещё стоит наша блокировка начала сеансов. Проверьте её срок и сообщение в свойствах базы в консоли кластера.' }
    if ($State.Expected.Count -and -not (Test-GateSessionSettings $State.Before $check)) {
        Write-Warning 'Исходные параметры запрета сеансов не подтверждены. Проверь свойства базы в консоли кластера.'
    }
    $State.Expected = @()
    if ($jobs -and [bool]$check.ScheduledJobsDenied) { throw 'запрет регламентных заданий по-прежнему включён, проверьте его в консоли кластера' }
    return ($changes -join ' и ')
}
