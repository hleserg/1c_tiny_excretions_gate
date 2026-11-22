#requires -Version 5.1

@(
    @{
        Name = 'operation-report-deploy-commands'
        Text = 'команды deploy с одним профилем: точный вид операции, полный итог, отмена выбора и отказ до записи'
        Run = {
            param($Name)
            $sb = New-ReportingDeploySandbox $Name
            $cases = @(
                @{ Args = '-CompareExtensions'; Kind = 'compare-extensions'; Outcome = 'completed'; Detail = 'Отличаются расширений' },
                @{ Args = '-CompareProcessings'; Kind = 'compare-processings'; Outcome = 'completed'; Detail = 'Обработок: одинаковых' },
                @{ Args = '-ComCheck'; Kind = 'com-check'; Outcome = 'completed'; Detail = 'через внешнее соединение читаются' },
                @{ Args = '-ProdPreCheck'; Kind = 'prod-precheck'; Outcome = 'failed'; Detail = 'подробность в последней строке'
                    Fake = @{ precheck = @(@{ lines = @('12:05:00 [ОШИБКА]   Проверка не прошла', ((' ' * 20) + 'подробность в последней строке')) }) } },
                @{ Args = '-PullExtensions'; Kind = 'pull-extensions'; Outcome = 'cancelled'; Detail = 'ничего не брал'
                    Answers = @(@{ Kind = 'many'; Header = 'Какие расширения'; Cancel = $true }) },
                @{ Args = '-PullProcessings'; Kind = 'pull-processings'; Outcome = 'unchanged'; Detail = 'подтягивать нечего' },
                @{ Args = '-Prepare'; Kind = 'prepare'; Outcome = 'cancelled'; Detail = 'ничего не обновлял'
                    Answers = @(@{ Kind = 'one'; Header = 'Подготовка обновления'; Item = '^Выход$' }) },
                @{ Args = '-ApplyPrepared'; Kind = 'apply-prepared'; Outcome = 'failed'; Detail = 'подготовленного обновления нет'; Code = 1 },
                @{ Args = '-CancelPrepared'; Kind = 'cancel-prepared'; Outcome = 'unchanged'; Detail = 'отменять нечего' },
                @{ Args = '-GitTypical'; Kind = 'git-typical'; Outcome = 'skipped'; Detail = 'не задан TypicalRepo' },
                @{ Args = '-GitProd -GitUnattended'; Kind = 'git-prod'; Outcome = 'failed'; Detail = 'без человека пока не выгружаю'; Code = 1 }
            )
            foreach ($case in $cases) {
                $argsForScript = @{ Sandbox = $sb; Script = 'deploy.ps1'; Arguments = $case.Args; Com = (New-ComState) }
                foreach ($key in @('Answers', 'Fake')) {
                    if ($case.ContainsKey($key)) { $argsForScript[$key] = $case[$key] }
                }
                $r = Invoke-Script @argsForScript
                Check (-not $r.TimedOut -and $r.Unexpected.Count -eq 0 -and $r.UnusedAnswers -eq 0) ("{0}: неожиданный запрос или таймаут" -f $case.Args)
                Check ($r.ExitCode -eq [int]$case['Code']) ("{0}: код {1}" -f $case.Args, $r.ExitCode)
                Check-OperationDispatch $sb $case.Kind $case.Outcome @($case.Detail)
            }
        }
    },
    @{
        Name = 'operation-report-git-choice'
        Text = 'выгрузка в git: отказ при выборе расширений, затем создание PR; загрузка при сдвинутом main завершается без прогона'
        Run = {
            param($Name)
            $sb = New-GitSandbox $Name -Extra @{ RunReportRepo = 'owner/reports' }
            New-Item -ItemType Directory -Path (Join-Path $sb 'fake-http') -Force | Out-Null
            $com = New-ComState -TempProcessings @((New-PrintProcessing '1' $printOld))
            $stop = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Com $com -Answers @(
                @{ Kind = 'many'; Cancel = $true })
            Check-DeployCommon $stop -LocksExpected $false
            Check-OperationDispatch $sb 'git-export' 'cancelled' @('ничего не выгружал')
            $save = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Com $com -Fake @{ dumps = (New-GitDumps) } -Answers $gitBootstrapAnswers
            Check-DeployCommon $save -LocksExpected $false
            Check-OperationDispatch $sb 'git-export' 'pull-request' @('pull request #', 'extensions/')
            $argsImport = '-GitImport -GitUnattended -GitCommit ' + ('1' * 40)
            $moved = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments $argsImport -Com $com
            Check-DeployCommon $moved -LocksExpected $false
            Check-OperationDispatch $sb 'git-import' 'moved' @('main', 'не гружу')
        }
    }
)
