#requires -Version 5.1
# Протокол общей обработки действий в тестовой и рабочей базах.
# ** Хлебников С.Ю. 20261124 Основная ошибка и её причина. Полный стек остаётся в исходном файле 1С.
function Get-ActionErrorSummary {
    param([string]$Reason, [string[]]$Secrets = @())
    foreach ($secret in $Secrets) { if ($secret) { $Reason = $Reason.Replace($secret, '***') } }
    if ($Reason -match '(?i)/(?:P|UC)\s*"|\b(?:PWD|PASSWORD|TOKEN|UC)\s*=') { return 'Подробности в локальном отчёте действий.' }
    $parts = $Reason -split '(?i)\s+по причине:\s*'
    $lines = foreach ($part in @($parts[0], $parts[-1]) | Select-Object -Unique) {
        $first = (($part -split '\s+\{|[\r\n]', 2)[0]).Trim()
        if ($first) { $first.Substring(0, [Math]::Min(350, $first.Length)) }
    }
    return ($lines -join ' / ')
}
# ** Хлебников С.Ю. 20261124 конец

function Assert-ActionResult {
    param([string[]]$Lines, [string[]]$Ids)
    $states = @($Lines | Where-Object { $_ -like 'status=*' })
    if ($states.Count -ne 1 -or $states[0] -cne 'status=ok' -or $Lines -cnotcontains 'done-register=ok') {
        # ** Хлебников С.Ю. 20261124 Показываем оператору действие и причину перед служебными статусами.
        foreach ($line in $Lines) {
            if ($line -cmatch '^action=([^|]+)\|failed\|(.+)$') {
                throw ('действие {0}: {1}. Перед повтором сверь идентификатор в регистре выполненных действий.' -f $Matches[1], (Get-ActionErrorSummary $Matches[2]))
            }
        }
        # ** Хлебников С.Ю. 20261124 конец
        $reason = @($Lines | Where-Object { $_ -match '^(error=|action=.*\|failed\||done-register=|status=)' })
        $detail = 'обработка не записала статус'
        if ($reason.Count) { $detail = Get-ActionErrorSummary ($reason -join '; ') }
        throw ("Действия не подтверждены: {0}. Перед повтором сверь протокол обработки с регистром выполненных действий." -f $detail)
    }
    $rows = @($Lines | Where-Object { $_.StartsWith('action=') })
    if ($rows.Count -ne $Ids.Count) { throw ('Обработка вернула результатов: {0}, ожидалось: {1}. Перед повтором сверь список запрошенных действий с протоколом обработки и регистром выполненных действий.' -f $rows.Count, $Ids.Count) }
    for ($i = 0; $i -lt $Ids.Count; $i++) {
        $parts = $rows[$i].Substring(7).Split([char[]]@('|'), 3)
        if ($parts.Count -lt 2 -or $parts[0] -cne $Ids[$i] -or $parts[1] -cnotin @('done', 'already')) {
            throw ('Нет подтверждения для действия {0} в строке результата {1}. Сверь порядок действий в протоколе и их отметки в регистре выполненных действий.' -f $Ids[$i], ($i + 1))
        }
    }
}

# ** Хлебников С.Ю. 20261124 Проверяем зависимость действия от существующих карточек до изменений в рабочей.
function Assert-GateActionTargets {
    param($Connection, [string]$Register, [hashtable]$Rules, [string[]]$Ids)
    if ($Register -cnotmatch '^[\p{L}_][\p{L}\p{Nd}_]*$') { throw 'Условия действий: неверное имя регистра выполненных действий.' }
    if ([Runtime.InteropServices.Marshal]::IsComObject($Connection)) {
        . (Join-Path $PSScriptRoot 'delivery-designer.ps1')
        $member = ${function:Get-WorkerMember}
    } else {
        $member = {
            param($Object, [string]$Name, [object[]]$Arguments = $null)
            if ($null -ne $Arguments) { return , ($Object.$Name.Invoke($Arguments)) }
            return , ($Object.$Name)
        }
    }
    $metadata = & $member $Connection 'Metadata'
    $registers = & $member $metadata 'InformationRegisters'
    $hasRegister = $null -ne (& $member $registers 'Find' @($Register))
    foreach ($id in $Ids) {
        if (-not $Rules.ContainsKey($id)) { continue }
        $rule = $Rules[$id]
        $catalog = [string]$rule['Catalog']
        $exact = [string]$rule['NameEquals']
        $contains = [string]$rule['NameContains']
        if ($catalog -cnotmatch '^[\p{L}_][\p{L}\p{Nd}_]*$' -or ([bool]$exact -eq [bool]$contains)) {
            throw ("Действие {0}: проверь Catalog и один отбор NameEquals или NameContains в DeployActionTargets." -f $id)
        }
        if ($hasRegister) {
            $text = "ВЫБРАТЬ ПЕРВЫЕ 1 Выполненные.Действие ИЗ РегистрСведений.$Register КАК Выполненные ГДЕ Выполненные.Действие = &Действие"
            $query = & $member $Connection 'NewObject' @('Query', $text)
            $null = & $member $query 'SetParameter' @('Действие', $id)
            $result = & $member $query 'Execute' @()
            if (-not (& $member $result 'IsEmpty' @())) { continue }
        }
        $filter = 'Цель.Наименование = &Имя'
        $value = $exact
        if ($contains) {
            $filter = 'ВРЕГ(Цель.Наименование) ПОДОБНО ВРЕГ(&Имя) СПЕЦСИМВОЛ "~"'
            $value = '%' + $contains.Replace('~','~~').Replace('%','~%').Replace('_','~_').Replace('[','~[').Replace(']','~]') + '%'
        }
        $text = "ВЫБРАТЬ ПЕРВЫЕ 2 Цель.Ссылка ИЗ Справочник.$catalog КАК Цель ГДЕ НЕ Цель.ЭтоГруппа И НЕ Цель.ПометкаУдаления И $filter"
        if ($rule['ParentName']) { $text += ' И Цель.Родитель.Наименование = &Папка' }
        $query = & $member $Connection 'NewObject' @('Query', $text)
        $null = & $member $query 'SetParameter' @('Имя', $value)
        if ($rule['ParentName']) { $null = & $member $query 'SetParameter' @('Папка', [string]$rule['ParentName']) }
        $result = & $member $query 'Execute' @()
        $rows = & $member $result 'Select' @()
        if (-not (& $member $rows 'Next' @())) { throw ("Действие {0}: в рабочей базе нет подходящих элементов справочника {1} (имя: {2}{3}, папка: {4})." -f $id,$catalog,$exact,$contains,$rule['ParentName']) }
        if ($rule['Unique'] -and (& $member $rows 'Next' @())) { throw ("Действие {0}: в справочнике {1} найдено несколько подходящих элементов вместо одного." -f $id,$catalog) }
    }
}
# ** Хлебников С.Ю. 20261124 конец

function Copy-VerifiedActionEpf {
    param([string]$RunDirectory, [string]$Destination, [string]$Hash)
    $source = Join-Path $RunDirectory 'actions\ДействияПослеОбновления.epf'
    Copy-Item -LiteralPath $source -Destination $Destination -Force -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ine $Hash) {
        throw ("Контрольная сумма {0} отличается от проверенной в тестовой базе. Сверь файл {1} с комплектом этого прогона и повтори проверку действий в тестовой базе." -f $Destination, $source)
    }
}
