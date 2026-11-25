#requires -Version 5.1
# Проверки очереди на подставном GitHub. Отдельно от тестов самих операций в tests.ps1.

@(
    @{
        Name = 'operation-report-pending-parts'
        Text = 'сбой на второй части, досылка оставшихся в свой репозиторий, полный Unicode-текст и маскирование до записи'
        Run = {
            param($Name)
            $profile = @{
                RunReportRepo = 'owner/reports'; GitHubTokenPassFile = 'token.dat'; AdminPassFile = 'admin.dat'
                CanaryUsers = @(@{ Name = ''; PassFile = 'reader.dat' }); UnlockCode = 'u-7'
            }
            $sb = New-Sandbox $Name -Config $profile
            foreach ($entry in @(@('token.dat', 'token-marker'), @('admin.dat', 'k!'), @('reader.dat', 'read-marker'))) {
                $encoded = ConvertTo-SecureString $entry[1] -AsPlainText -Force | ConvertFrom-SecureString
                [IO.File]::WriteAllText((Join-Path $sb $entry[0]), $encoded)
            }
            . (Join-Path $sb 'operation-report.ps1')
            $oldHttp = $env:CI_FAKE_HTTP
            try {
                $http = (New-Item -ItemType Directory -Path (Join-Path $sb 'fake-http')).FullName
                $env:CI_FAKE_HTTP = $http
                $cfg = Join-Path $sb 'config.psd1'
                $op = Start-GateOperationReport -Operation 'compare-extensions' -Config $cfg
                $marker = ('строка "изменено" ' + [char]0x5C + [char]::ConvertFromUtf32(0x1F680) + "`r`n") * 6000 + 'КОНЕЦ РАЗНИЦЫ'
                Add-GateOperationLine $op $marker
                $extras = 'token-marker k! read-marker u-7 /P"unknown-one" UC="unknown-two"; Authorization: Bearer unknown-three'
                Add-GateOperationLine $op $extras
                $fail = Join-Path $http 'dispatch-fail-part.txt'
                [IO.File]::WriteAllText($fail, '2')
                Complete-GateOperation $op 'completed' 'Сравнение закончено.'
                $stateFile = Join-Path $op.Dir 'publish.json'
                $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
                Check ($state.wanted -eq 'final' -and -not $state.sent -and $state.sentPart -eq 1) 'не запомнилась принятая часть'
                $first = @(Get-ChildItem $http -Filter 'dispatch-*.json')
                Check ($first.Count -eq 1) 'до обрыва должна уйти только первая часть'
                Remove-Item -LiteralPath $fail
                $other = Join-Path $sb 'other.psd1'
                [IO.File]::WriteAllText($other, ([IO.File]::ReadAllText($cfg)).Replace('owner/reports', 'owner/other'), $utf8Bom)
                & (Join-Path $sb 'publish.ps1') -Pending -Config $other
                Check (@(Get-ChildItem $http -Filter 'dispatch-*.json').Count -eq 1) 'другой профиль дослал чужой отчёт'
                & (Join-Path $sb 'publish.ps1') -Pending -Config $cfg
                & (Join-Path $sb 'publish.ps1') -Pending -Config $cfg
                $chunks = @(Get-ChildItem $http -Filter 'dispatch-*.json' | ForEach-Object {
                    Check ($_.Length -le 60000) 'часть превышает предел тела события'
                    ([IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json).client_payload
                } | Sort-Object { [int]$_.part })
                Check ($chunks.Count -gt 1 -and $chunks.Count -eq $chunks[0].parts) 'досланы не все части либо есть повтор'
                $body = ($chunks | ForEach-Object { $_.body }) -join ''
                Check ($body.Contains($marker)) 'разница изменилась на границах частей'
                Check ($chunks[0].operation -eq 'compare-extensions' -and $chunks[0].outcome -eq 'completed') 'не тот вид или исход'
                Check ($chunks[0].launch.user -and $chunks[0].launch.gateVersion -and $chunks[0].launch.started) 'нет сведений запуска'
                $saved = [IO.File]::ReadAllText((Join-Path $op.Dir 'summary.txt')) + [IO.File]::ReadAllText((Join-Path $op.Dir 'dispatch\final.json'))
                foreach ($secret in @('token-marker','k!','read-marker','u-7','unknown-one','unknown-two','unknown-three')) {
                    Check (-not $body.Contains($secret) -and -not $saved.Contains($secret)) 'в итог или журнал попало чувствительное значение'
                }
            } finally { $env:CI_FAKE_HTTP = $oldHttp }
        }
    }
    @{
        Name = 'operation-report-broken'
        Text = 'отличает живой процесс от оборвавшегося, сохраняет его последние строки; при пустой настройке не заводит очередь'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            . (Join-Path $sb 'operation-report.ps1')
            $cfg = Join-Path $sb 'config.psd1'
            $empty = Start-GateOperationReport 'compare-processings' $cfg
            Check ($null -eq $empty -and -not (Test-Path (Join-Path $sb 'runs\operations'))) 'выключенная отправка завела очередь'
            $sb2 = New-Sandbox ($Name + '-enabled') -Config @{ RunReportRepo = 'owner/reports'; GitHubTokenPassFile = 'token.dat' }
            . (Join-Path $sb2 'operation-report.ps1')
            $cfg = Join-Path $sb2 'config.psd1'
            $encoded = ConvertTo-SecureString 'report-token' -AsPlainText -Force | ConvertFrom-SecureString
            [IO.File]::WriteAllText((Join-Path $sb2 'token.dat'), $encoded)
            $oldHttp = $env:CI_FAKE_HTTP
            try {
                $env:CI_FAKE_HTTP = (New-Item -ItemType Directory -Path (Join-Path $sb2 'fake-http')).FullName
                $op = Start-GateOperationReport 'compare-processings' $cfg
                Add-GateOperationLine $op 'До остановки сравнили две обработки.'
                & (Join-Path $sb2 'publish.ps1') -Pending -Config $cfg
                Check (@(Get-ChildItem $env:CI_FAKE_HTTP -Filter 'dispatch-*.json').Count -eq 0) 'живой процесс принят за оборвавшийся'
                [IO.File]::WriteAllText((Join-Path $op.Dir 'pid.txt'), '0|2000-01-01')
                & (Join-Path $sb2 'publish.ps1') -Pending -Config $cfg
                $event = ([IO.File]::ReadAllText((Join-Path $env:CI_FAKE_HTTP 'dispatch-01.json')) | ConvertFrom-Json).client_payload
                Check ($event.stage -eq 'broken' -and $event.outcome -eq 'broken' -and $event.body.Contains('две обработки')) 'не восстановлен исход обрыва'
            } finally { $env:CI_FAKE_HTTP = $oldHttp }
        }
    }
)

. (Join-Path $PSScriptRoot 'run-operation-report.tests.ps1')
. (Join-Path $PSScriptRoot 'deploy-operation-report.tests.ps1')
