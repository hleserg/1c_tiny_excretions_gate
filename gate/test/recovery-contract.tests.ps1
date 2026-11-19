#requires -Version 5.1

# Обёртка меняет только результат Get-Date в процессе теста. Оператор отвечает через обычный канал UI.
function New-RecoveryClockFixture {
    param([string]$Sandbox)
    $launcher = @'
param([ValidateSet('Prepare','Deploy','ApplyPrepared','Nightly')][string]$Mode, [string]$UiChannel)
$clockFile = Join-Path $PSScriptRoot 'fake\clock.txt'
function Get-Date {
    param([string]$Format)
    $clock = [datetime]::ParseExact([IO.File]::ReadAllText($clockFile), 'HH:mm', [cultureinfo]::InvariantCulture)
    if ($PSBoundParameters.ContainsKey('Format')) { return $clock.ToString($Format, [cultureinfo]::InvariantCulture) }
    return $clock
}
if ($Mode -eq 'Nightly') { & (Join-Path $PSScriptRoot 'nightly.ps1') -UiChannel $UiChannel }
else {
    $options = @{ UiChannel = $UiChannel }
    if ($Mode -ne 'Deploy') { $options[$Mode] = $true }
    & (Join-Path $PSScriptRoot 'deploy.ps1') @options
}
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText((Join-Path $Sandbox 'clock-entry.ps1'), $launcher, $utf8Bom)
}

@(
    @{
        Name = 'review-deploy-recovery-partial'
        Text = 'Неполный откат подготовленного обновления переживает перезапуск. Повторный запуск показывает причину и не начинает новое обновление.'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState
            $extensions = $com.bases[$deployConfig.Base].extensions
            $extensions[1].hash = 'fixture-second-new'
            $extensions[1].version = '2.0'
            $failedName = $extensions[0].name
            $restoredName = $extensions[1].name
            $prepare = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Prepare' -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Подготовка обновления'; Item = '^Подготовить все' }, $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $prepare -LocksExpected $false
            $manifest = Join-Path $sb 'deploy\prepared.json'
            if ($prepare.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $manifest)) { Check $false 'не создана исходная подготовка'; return }
            $before = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
            if (@($before.extensions).Count -ne 2) { Check $false 'для проверки нужны две резервные копии'; return }
            foreach ($item in $before.extensions) { Check (Test-Path -LiteralPath $item.backup -PathType Leaf) ('нет резервной копии ' + $item.name) }

            Start-Sleep -Seconds 2
            Reset-FakeState $sb
            $scenario = @{ designer = @(
                @{ match = @('/UpdateDBCfg', ('update_' + $restoredName + '_1.log')); exit = 1; log = 'Тестовая ошибка применения'; times = 1 },
                @{ match = @('/LoadCfg', ('rollback_load_' + $failedName + '.log')); exit = 1; log = 'Тестовая ошибка восстановления'; times = 1 }) }
            $failed = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-ApplyPrepared' -Fake $scenario -Answers @(
                $deployRiskAnswer, $deployNameAnswer, @{ Kind = 'confirm'; Header = '^Откатить\?'; Yes = $true })
            Check-DeployCommon $failed
            $bad = Get-Calls $failed @('/LoadCfg', ('rollback_load_' + $failedName + '.log'))
            $good = Get-Calls $failed @('/UpdateDBCfg', ('rollback_update_' + $restoredName + '.log'))
            Check ($bad.Count -eq 1 -and $bad[0].Code -ne 0) 'подставная 1С не отказала в восстановлении первого расширения'
            Check ($good.Count -eq 1 -and $good[0].Code -eq 0) 'восстановление второго расширения не дошло до обновления БД'
            $record = Get-DeployRecord $sb
            Check ($null -ne $record -and $record.outcome -eq 'rollbackFailed' -and $failed.ExitCode -ne 0) 'в истории нет итога неполного отката'
            Check (Test-Path -LiteralPath $manifest -PathType Leaf) 'после неполного отката потерян prepared.json'

            Reset-FakeState $sb
            $restart = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-ApplyPrepared'
            Check (-not $restart.TimedOut -and $restart.Unexpected.Count -eq 0) 'повтор потребовал подтверждение новой установки'
            Check (($restart.Output -join "`n") -match '(?i)(откат|восстановлен).*(непол|не полностью|не заверш|не удал|не прош|ошиб)|непол.*(откат|восстановлен)|rollbackFailed') 'при повторном запуске нет диагноза незаконченного отката'
            foreach ($cmd in @('/LoadCfg', '/UpdateDBCfg', '/DeleteCfg')) {
                Check ((Get-Calls $restart @($cmd)).Count -eq 0) ('повтор начал изменение ' + $cmd)
            }
        }
    },
    @{
        Name = 'review-deploy-recovery-denied-time'
        Text = 'Подготовка, обновление одним проходом и применение подготовки: правильное имя введено на границе окна, до первой записи уже 22:01.'
        Run = {
            param($Name)
            # Find-Answer вызывается самим тестовым драйвером. Пишем новое время перед передачей настоящего ответа.
            $answerFromHarness = (Get-Command Find-Answer -CommandType Function).ScriptBlock
            function Find-Answer {
                param($Question, $Rules, $Used)
                $answer = & $answerFromHarness $Question $Rules $Used
                if ($advanceClock -and $Question.kind -eq 'text' -and $Question.header -match 'Это рабочая база' -and $null -ne $answer -and $answer['text'] -ceq $deployConfig.ProdBase) {
                    [IO.File]::WriteAllText($clockPath, '22:01')
                }
                return $answer
            }
            foreach ($mode in @('Prepare', 'Deploy', 'ApplyPrepared')) {
                $profile = $deployConfig.Clone()
                $profile['DeployDeniedFrom'] = 22
                $profile['DeployDeniedTo'] = 2
                $sb = New-Sandbox ($Name + '-' + $mode) -Config $profile
                New-RecoveryClockFixture $sb
                $clockPath = Join-Path $sb 'fake\clock.txt'
                $advanceClock = $false
                $prepareChoice = @{ Kind = 'one'; Header = 'Подготовка обновления'; Item = '^Подготовить все' }
                $applyChoice = @{ Kind = 'one'; Header = '^Обновление '; Item = '^Обновить все' }
                if ($mode -eq 'ApplyPrepared') {
                    [IO.File]::WriteAllText($clockPath, '21:58')
                    $seed = Invoke-Script -Sandbox $sb -Script 'clock-entry.ps1' -Arguments '-Mode Prepare' -Com (New-ComState) -Answers @($prepareChoice, $deployRiskAnswer, $deployNameAnswer)
                    Check-DeployCommon $seed -LocksExpected $false
                    if (-not (Test-Path -LiteralPath (Join-Path $sb 'deploy\prepared.json'))) { Check $false 'контрольная подготовка в 21:58 не выполнена'; continue }
                    Reset-FakeState $sb
                }
                $answers = @($deployRiskAnswer, $deployNameAnswer)
                if ($mode -eq 'Prepare') { $answers = @($prepareChoice) + $answers }
                if ($mode -eq 'Deploy') { $answers = @($applyChoice) + $answers }
                $advanceClock = $true
                [IO.File]::WriteAllText($clockPath, '21:59')
                $result = Invoke-Script -Sandbox $sb -Script 'clock-entry.ps1' -Arguments ('-Mode ' + $mode) -Com (New-ComState) -Answers $answers
                Check (-not $result.TimedOut -and -not $result.Stderr -and $result.Unexpected.Count -eq 0 -and $result.UnusedAnswers -eq 0) ($mode + ': запуск не дошёл до подтверждения штатно')
                Check ([IO.File]::ReadAllText($clockPath) -eq '22:01') ($mode + ': контрольные часы не пересекли границу')
                foreach ($cmd in @('/LoadCfg', '/LoadConfigFromFiles', '/UpdateDBCfg', '/DeleteCfg')) {
                    Check ((Get-Calls $result @($cmd, $profile.ProdBase)).Count -eq 0) ($mode + ': начат ' + $cmd + ' внутри запретного окна')
                }
                Check (($result.Output -join "`n") -match '(?im)^.*(с 22:00 до|запретн|запрещ|вне разреш[её]н|нельзя.*22:|22:01.*не обновляем).*$') ($mode + ': нет объяснения остановки из-за времени')
            }
        }
    },
    @{
        Name = 'review-nightly-recovery-delayed-start'
        Text = 'Ночной сценарий при разрешённом времени расписания и фактическом старте в запретное окно не передаёт управление импорту или гейту.'
        Run = {
            param($Name)
            foreach ($time in @('21:59', '22:01')) {
                $sb = New-Sandbox ($Name + '-' + $time.Replace(':','')) -Config @{ NightlyAt = '21:30'; ExtensionsRepo = 'fixture/repository' }
                New-RecoveryClockFixture $sb
                [IO.File]::WriteAllText((Join-Path $sb 'fake\clock.txt'), $time)
                # Приёмники регистрируют запуск без репозитория и без обращений к базе.
                foreach ($child in @('deploy.ps1','run.ps1')) {
                    $probe = '[IO.File]::WriteAllText((Join-Path $PSScriptRoot ''fake\started-{0}''), ''started'')' -f $child
                    [IO.File]::WriteAllText((Join-Path $sb $child), $probe, $utf8Bom)
                }
                $result = Invoke-Script -Sandbox $sb -Script 'clock-entry.ps1' -Arguments '-Mode Nightly'
                Check (-not $result.TimedOut -and -not $result.Stderr -and $result.Unexpected.Count -eq 0) 'ошибка тестового окружения при запуске nightly'
                $imported = Test-Path -LiteralPath (Join-Path $sb 'fake\started-deploy.ps1')
                $ran = Test-Path -LiteralPath (Join-Path $sb 'fake\started-run.ps1')
                if ($time -eq '21:59') { Check ($imported -and $ran) 'в разрешённое время подставные импорт и прогон не вызывались' }
                else { Check (-not $imported -and -not $ran) 'отложенное задание запустило дочерний сценарий в 22:01' }
            }
        }
    },
    @{
        Name = 'review-deploy-recovery-rollback-profile'
        Text = 'Исторический откат передаёт дочернему гейту применённый профиль и возвращённый CFE. Приёмник читает профиль из аргументов фактического вызова.'
        Run = {
            param($Name)
            $profile = $deployConfig.Clone()
            $profile.Base = 'fixture_default_temp'
            $sb = New-Sandbox $Name -Config $profile
            $custom = Join-Path $sb 'profile-selected.psd1'
            $text = [IO.File]::ReadAllText((Join-Path $sb 'config.psd1'))
            $selected = 'fixture_selected_temp'
            [IO.File]::WriteAllText($custom, $text.Replace($profile.Base, $selected), $utf8Bom)
            $com = New-ComState
            $com.bases[$selected] = New-ComBase -AdaptHash 'selected'
            $com.bases[$profile.Base] = New-ComBase -AdaptHash 'other'
            $argsProfile = '-Config "{0}"' -f $custom
            $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments $argsProfile -Com $com -Answers @(
                @{ Kind = 'one'; Header = '^Обновление '; Item = '^Обновить все' }, $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $first
            $firstRecord = Get-DeployRecord $sb
            if ($null -eq $firstRecord -or $firstRecord.outcome -ne 'updated' -or $firstRecord.tempBase -ne $selected) { Check $false 'не создана история выбранного профиля'; return }
            # Серверный run.ps1 создаёт V83.COMConnector сам. Останавливаемся на границе вызова дочернего гейта.
            $receiver = @'
param([string]$Kit, [string]$UiChannel, [string]$Config)
$path = if ($Config) { (Resolve-Path -LiteralPath $Config).Path } else { Join-Path $PSScriptRoot 'config.psd1' }
$profile = Import-PowerShellDataFile -LiteralPath $path
$evidence = @{ path = $path; base = $profile.Base; files = @(Get-ChildItem -LiteralPath $Kit -Filter '*.cfe' -File | ForEach-Object { $_.Name }) }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'fake\child-profile.json'), (ConvertTo-Json -InputObject $evidence))
'@
            [IO.File]::WriteAllText((Join-Path $sb 'run.ps1'), $receiver, $utf8Bom)
            Start-Sleep -Seconds 2
            Reset-FakeState $sb
            $rollback = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments ($argsProfile + ' -Rollback') -Answers @(
                @{ Kind = 'one'; Header = '^Откат '; Index = 0 }, @{ Kind = 'confirm'; Header = 'Точно откатить'; Yes = $true },
                $deployNameAnswer, @{ Kind = 'confirm'; Header = 'подтянуть изменения в темп'; Yes = $true })
            Check-DeployCommon $rollback
            $record = Get-DeployRecord $sb
            Check ($null -ne $record -and $record.outcome -eq 'updated' -and $record.rollbackOf -eq $firstRecord.runId) 'исторический откат не завершился'
            $resultFile = Join-Path $sb 'fake\child-profile.json'
            if (-not (Test-Path -LiteralPath $resultFile)) { Check $false 'после согласия подтянуть изменения дочерний гейт не вызван'; return }
            $child = [IO.File]::ReadAllText($resultFile) | ConvertFrom-Json
            Check ($child.path -eq $custom -and $child.base -ceq $selected) ('дочерний гейт прочёл профиль ' + $child.path + ', база ' + $child.base)
            Check (@($child.files).Count -eq 1 -and $child.files[0] -like ('*_' + $firstRecord.extensions[0].name + '_*.cfe')) 'в дочерний гейт передан другой комплект расширений'
        }
    }
)
