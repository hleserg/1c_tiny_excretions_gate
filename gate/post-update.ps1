#requires -Version 5.1
# Протокол общей обработки действий в тестовой и рабочей базах.
# ** Хлебников С.Ю. 20261124 Основная ошибка и её причина. Полный стек остаётся в исходном файле 1С.
function Get-ActionErrorSummary {
    param([string]$Reason)
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
                throw ('действие {0}: {1}' -f $Matches[1], (Get-ActionErrorSummary $Matches[2]))
            }
        }
        # ** Хлебников С.Ю. 20261124 конец
        $reason = @($Lines | Where-Object { $_ -match '^(error=|action=.*\|failed\||done-register=|status=)' })
        throw ('действия не подтверждены: ' + ($reason -join '; '))
    }
    $rows = @($Lines | Where-Object { $_.StartsWith('action=') })
    if ($rows.Count -ne $Ids.Count) { throw 'число результатов отличается от числа действий' }
    for ($i = 0; $i -lt $Ids.Count; $i++) {
        $parts = $rows[$i].Substring(7).Split([char[]]@('|'), 3)
        if ($parts.Count -lt 2 -or $parts[0] -cne $Ids[$i] -or $parts[1] -cnotin @('done', 'already')) {
            throw ('нет подтверждения для действия ' + $Ids[$i])
        }
    }
}

function Copy-VerifiedActionEpf {
    param([string]$RunDirectory, [string]$Destination, [string]$Hash)
    $source = Join-Path $RunDirectory 'actions\ДействияПослеОбновления.epf'
    Copy-Item -LiteralPath $source -Destination $Destination -Force -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ine $Hash) {
        throw 'обработка действий отличается от проверенной в тестовой базе'
    }
}
