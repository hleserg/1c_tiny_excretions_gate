#requires -Version 5.1

@(
    @{
        Name = 'report-accept-baseline'
        Text = 'принятие в эталон из меню: отказ и частичное принятие видны отдельно с исходом и счётом тестов'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ RunReportRepo = 'owner/reports'; GitHubTokenPassFile = 'secrets\github.txt' }
            $null = New-FakeGateRelease -Sandbox $sb -Name $Name
            $id = '20260101-010000'
            $previous = Join-Path (Join-Path $sb 'runs') $id
            New-Item -ItemType Directory -Path $previous -Force | Out-Null
            $verdict = @{ runId = $id; baseKey = 'erp_temp_test'; verdict = 'RED'; kit = ''; kitDecision = 'kept'; steps = @() }
            [IO.File]::WriteAllText((Join-Path $previous 'verdict.json'), (ConvertTo-Json $verdict), $utf8Bom)
            [IO.File]::WriteAllText((Join-Path $previous 'selfcheck-after.norm.txt'), 'известное замечание', $utf8Bom)
            [IO.File]::WriteAllLines((Join-Path $previous 'unittests.txt'), [string[]]@("OK`tТест.Работает", "FAIL`tТест.Падает"), $utf8Bom)
            $menu = @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Принять новое последнего прогона' }
            $back = @{ Kind = 'one'; Header = 'Посмотрел'; Index = 0 }
            $r = Invoke-Script -Sandbox $sb -Answers @(
                $menu, @{ Kind = 'confirm'; Header = 'Принять новое прогона'; Yes = $false }, $back,
                $menu, @{ Kind = 'confirm'; Header = 'Принять новое прогона'; Yes = $true },
                @{ Kind = 'confirm'; Header = 'падают модульные тесты'; Yes = $false }, $back,
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            Check ($r.ExitCode -eq 0 -and $r.Unexpected.Count -eq 0 -and $r.UnusedAnswers -eq 0) 'оператор не прошёл оба пути принятия в эталон'
            Check ([IO.File]::ReadAllText((Join-Path $previous 'accepted.txt')).Contains('scope=partial')) 'в эталон не приняты только прошедшие тесты'
            Check-OperationDispatch $sb 'accept-baseline' 'cancelled' @($id, 'отменено')
            Check-OperationDispatch $sb 'accept-baseline' 'accepted' @($id, 'падения \(1\) не приняты', 'самопроверка, записей 1')
        }
    }
    @{
        Name = 'report-resume'
        Text = 'продолжение: отмена в меню, единый отчёт законченного прогона и отдельный отказ до появления папки'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ RunReportRepo = 'owner/reports'; GitHubTokenPassFile = 'secrets\github.txt' }
            $null = New-FakeGateRelease -Sandbox $sb -Name $Name
            $file = Add-InboxFile $sb $cfeName
            $first = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Fake @{ selfcheck = @(@{}, @{ tasks = $errorTasks; fingerprint = 'после' }) }
            Check-Common $first
            Check-Verdict $first 'RED' 1
            $cancel = Invoke-Script -Sandbox $sb -Answers @(
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Продолжить прогон' },
                @{ Kind = 'one'; Header = 'с какого шага'; Cancel = $true },
                @{ Kind = 'one'; Header = 'Гейт расширений'; Item = '^Выход' })
            Check-Common $cancel
            Reset-FakeState $sb
            $r = Invoke-Script -Sandbox $sb -Arguments '-Resume last' -Fake @{ selfcheck = @(@{ fingerprint = 'проверка' }, @{ fingerprint = 'после2' }) }
            Check-Common $r
            Check-Verdict $r 'GREEN' 0
            # Следующий вызов проверяет очередь уже после завершения процесса успешного продолжения.
            $refused = Invoke-Script -Sandbox $sb -Arguments '-Resume missing-previous-run'
            Check ($refused.ExitCode -eq 1) 'запрос продолжения отсутствующего прогона не отклонён'
            Check-OperationDispatch $sb 'resume' 'failed' @('missing-previous-run')
            Check-OperationDispatch $sb 'resume' 'cancelled' @('Выбор шага')
            Check-OperationDispatch $sb 'resume' 'GREEN' @((Split-Path -Leaf $first.RunDir))
            $broken = @(Get-ChildItem -LiteralPath (Join-Path $sb 'fake-http') -Filter 'dispatch-*.json' | Where-Object {
                $event = [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json
                $event.client_payload.outcome -eq 'broken'
            })
            Check ($broken.Count -eq 0) 'передача из меню штатному прогону породила лишний отчёт об обрыве'
        }
    }
    @{
        Name = 'report-update-gate'
        Text = 'обновление гейта: отмена, успешная установка с исходной и целевой версиями, отказ по контрольной сумме'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ UpdateRepo = 'owner/repo'; RunReportRepo = 'owner/reports'; GitHubTokenPassFile = 'secrets\github.txt' }
            $release = New-FakeGateRelease -Sandbox $sb -Name $Name
            $head = @(Get-Content -LiteralPath (Join-Path $sb 'run.ps1') -Encoding UTF8 -TotalCount 80) -join "`n"
            $installed = [regex]::Match($head, 'Версия (\d{8}\.\d{6})\.').Groups[1].Value
            $cancel = Invoke-Script -Sandbox $sb -Script 'update.ps1' -Arguments '-Startup' -Answers @(
                @{ Kind = 'confirm'; Header = 'Доступен гейт'; Yes = $false })
            Check ($cancel.ExitCode -eq 0 -and $cancel.Unexpected.Count -eq 0 -and $cancel.UnusedAnswers -eq 0) 'не обработан отказ от предложенной версии'
            $good = Invoke-Script -Sandbox $sb -Script 'update.ps1' -Arguments '-Latest'
            Check ($good.ExitCode -eq 10) 'установка новой версии не вернула код 10'
            $bad = Invoke-Script -Sandbox $sb -Script 'update.ps1' -Arguments '-Tag gate-20000101.000000'
            Check ($bad.ExitCode -eq 1) 'неверная сумма комплекта не привела к отказу'
            Check-OperationDispatch $sb 'update-gate' 'cancelled' @('20991231\.000000', 'отменена')
            Check-OperationDispatch $sb 'update-gate' 'updated' @(([regex]::Escape($installed) + ' → 20991231\.000000'), 'Гейт обновлён')
            Check-OperationDispatch $sb 'update-gate' 'failed' @('20000101\.000000', 'контрольная сумма')
            foreach ($event in Get-ChildItem -LiteralPath $release.Http -Filter 'dispatch-*.json') {
                Check (-not [IO.File]::ReadAllText($event.FullName).Contains($release.Secret)) 'токен установки попал в опубликованный итог'
            }
        }
    }
)
