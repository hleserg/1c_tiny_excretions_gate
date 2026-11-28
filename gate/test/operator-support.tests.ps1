#requires -Version 5.1

@(
    @{
        Name = 'operator-support-update'
        Text = 'Обновление указывает этап и способ исправить ошибку комплекта или файла токена.'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ UpdateRepo = 'owner/repo'; GitHubTokenPassFile = 'secrets\github.txt' }
            $release = New-FakeGateRelease -Sandbox $sb -Name $Name
            $bad = Invoke-Script -Sandbox $sb -Script 'update.ps1' -Arguments '-Tag gate-20000101.000000'
            $message = $bad.Output -join "`n"
            Check ($bad.ExitCode -eq 1 -and $message -match 'SHA-256' -and $message -match 'скачай|скачайте|скачать|скачивание' -and $message -match 'установщик') 'при неверной сумме неясно, началась ли установка и как повторить скачивание'
            $token = Join-Path $sb 'secrets\github.txt'
            [IO.File]::WriteAllText($token, 'broken-secret-marker')
            $bad = Invoke-Script -Sandbox $sb -Script 'update.ps1' -Arguments '-List'
            $message = (@($bad.Output) + @($bad.Stderr)) -join "`n"
            Check ($bad.ExitCode -eq 1 -and $message.Contains($token) -and $message -match 'Windows' -and $message -match 'Настройки') 'при нечитаемом токене нет файла и способа записать токен заново'
            Check (-not $message.Contains('broken-secret-marker')) 'содержимое файла токена попало на экран'
        }
    }
    @{
        Name = 'operator-support-maintenance'
        Text = 'Ошибки расписания, локального журнала и блокировки показывают место проверки и дальнейшее действие.'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $night = Invoke-Script -Sandbox $sb -Script nightly.ps1 -Arguments '-Install -At 25:99'
            Check ($night.ExitCode -eq 1 -and ($night.Output -join '|') -match 'NightlyAt|-At\s+ЧЧ:ММ') 'некорректное время расписания: нет указания, где исправить'
            . (Join-Path $sb 'operations.ps1')
            $absent = Join-Path $sb 'missing-dir'
            $record = [pscustomobject]@{Dir=$absent; Name='sample'; Next=0}
            $warning = [string](Write-OperationEvent $record 'finish' 3>&1)
            Check ($warning.Contains($absent) -and $warning -match 'finish' -and $warning -match 'проверьте') 'предупреждение о недоступном журнале не называет папку, событие и действие'
            . (Join-Path $sb 'locks.ps1')
            $reason = try { Set-GateSessionLock (New-GateLockState) $null (Get-Date) (Get-Date) 'sample-code' '' { @{SessionsDenied=$true} }; '' } catch { $_.Exception.Message }
            Check ($reason -match 'уже установлена' -and $reason -match 'консоли кластера' -and $reason -match 'владельц') 'при чужой блокировке нет указания, как проверить её владельца'
            Check (-not $reason.Contains('sample-code')) 'код блокировки попал в предупреждение'
        }
    }
    @{
        Name = 'operator-support-worker'
        Text = 'Исполнитель приёмки различает успешный выход без журнала и ошибку процесса.'
        Run = {
            param($Name)
            . (Join-Path $ciRoot 'delivery-designer.ps1')
            $work = Join-Path $workRoot $Name
            [void][IO.Directory]::CreateDirectory($work)
            $log = Join-Path $work 'dump.log'
            $profile = @{ Designer='fake.exe'; Server='localhost'; Base='worker_test'; User='reader'; Password='worker-password-marker' }
            $fake = [pscustomobject]@{ ExitCode=0; Handle=0 }
            Add-Member -InputObject $fake -MemberType ScriptMethod -Name WaitForExit -Value { return $true }
            Add-Member -InputObject $fake -MemberType ScriptMethod -Name Dispose -Value {}
            function Start-Process { $fake }
            $reason = try { Invoke-WorkerDesigner $profile @('/DumpCfg') $log; '' } catch { $_.Exception.Message }
            Check ($reason.Contains('/DumpCfg') -and $reason.Contains($log) -and $reason -match 'не создал журнал|журнал не создан' -and $reason -match 'запис') 'код 0 без файла журнала выглядит как ошибка Конфигуратора с кодом 0'
            [IO.File]::WriteAllText($log, 'детали')
            $fake.ExitCode = 7
            $reason = try { Invoke-WorkerDesigner $profile @('/DumpCfg') $log; '' } catch { $_.Exception.Message }
            Check ($reason -match 'кодом 7' -and $reason.Contains('/DumpCfg') -and $reason.Contains($log) -and $reason -match 'открой|прочитай') 'при коде ошибки нет операции, действия или пути к журналу'
            Check (-not $reason.Contains($profile.Password)) 'пароль попал в сообщение Конфигуратора'
        }
    }
)
