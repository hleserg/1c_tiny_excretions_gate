#requires -Version 5.1
@{
    Name = 'deploy-action-file-preflight'
    Text = 'Файл из принятого прогона должен быть установлен или выбран до закрытия рабочей базы.'
    Run = {
        param($Name)
        $config = $deployConfig.Clone()
        $config['ActionsRegister'] = 'ВыполненныеДействия'
        $config['HistoryRegister'] = 'ЖурналОбновлений'
        $sb = New-Sandbox $Name -Config $config
        $runDir = Join-Path $sb 'runs\20261117-090000'
        $actionDir = Join-Path $runDir 'actions'
        New-Item -ItemType Directory -Path $actionDir -Force | Out-Null
        $epf = Join-Path $actionDir 'ДействияПослеОбновления.epf'
        [IO.File]::WriteAllBytes($epf, [byte[]]@(65,66))
        $ids = @('20261117-01-Первое')
        $ref = '50000000-0000-0000-0000-000000000010'
        $current = New-PrintProcessing '17.1' $printNew
        $previous = New-PrintProcessing '16.1' $printOld
        $current.ref = $ref
        $previous.ref = $ref
        $com = New-ComState -ProdHash 'h2' -TempProcessings @($current) -ProdProcessings @($previous)
        $snapFile = Join-Path $sb 'snapshot.json'
        $snap = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments ('-SnapshotTemp "{0}"' -f $snapFile) -Com $com
        Check ($snap.ExitCode -eq 0) 'ошибка чтения тестового снимка'
        $snapshot = [IO.File]::ReadAllText($snapFile) | ConvertFrom-Json
        $verdict = @{ baseKey='erp_temp_test'; verdict='GREEN'; kit=''; steps=@(); kitDecision=''; gateVersion='test'
            requestedActionIds=$ids; verifiedActions=@{ ids=$ids; sha256=(Get-FileHash $epf).Hash; commit=''; branch=''; done=$config.ActionsRegister; history=$config.HistoryRegister }
            checkedState=$snapshot; kitProcessings=@(@{objectName='Печать';targetRef=$ref;newVersion='17.1'}) }
        [IO.File]::WriteAllText((Join-Path $runDir 'verdict.json'), ($verdict | ConvertTo-Json -Depth 8), $utf8)
        $modeAnswer = @{Kind='one'; Header='Обновление erp_base'; Item='^Выполнить только проверенные действия'}
        $old = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @($modeAnswer)
        $message = $old.Output -join ' '
        Check ($old.ExitCode -ne 0 -and $old.Unexpected.Count -eq 0) 'гейт запросил разрешение закрыть базу при заведомом расхождении'
        Check ($message -match 'Действия не запускались' -and $message -match '17.1' -and $message -match '16.1' -and $message -match 'Обновить только внешние обработки') 'нет состояния, обеих версий и способа исправления'
        Check (($old.ComLog -join ' ') -notmatch 'UpdateInfoBase|TerminateSession') 'проверка закрыла рабочую базу'
        Check (@($old.Calls | Where-Object { $_.Line -match 'actions;in=|/UpdateDBCfg|/LoadCfg' }).Count -eq 0) 'выпуск начал запись до сверки'
        $archived = New-PrintProcessing '10.0' $printOld
        $archived.ref = '50000000-0000-0000-0000-000000000020'
        $archived.use = 'Отключена'
        $previous.ref = '50000000-0000-0000-0000-000000000030'
        $com = New-ComState -ProdHash 'h2' -TempProcessings @($current,$archived) -ProdProcessings @($previous)
        $null = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments ('-SnapshotTemp "{0}"' -f $snapFile) -Com $com
        $verdict.checkedState = [IO.File]::ReadAllText($snapFile) | ConvertFrom-Json
        # Комплект без файла привязки хранит адрес, возвращённый регистрацией, в ref.
        $verdict.kitProcessings[0].targetRef = ''
        $verdict.kitProcessings[0].ref = $ref
        $verdict.checkedState.processings.Печать.hash = $verdict.checkedState.processingCards.($archived.ref).hash
        $cards = Get-Member -InputObject $verdict.checkedState.processingCards -MemberType NoteProperty
        Check (@($cards).Count -eq 2) 'снимок потерял одноимённую карточку'
        [IO.File]::WriteAllText((Join-Path $runDir 'verdict.json'), ($verdict | ConvertTo-Json -Depth 8), $utf8)
        $two = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @($modeAnswer)
        $why = $two.Output -join ' '
        Check ($two.ExitCode -ne 0 -and $two.Unexpected.Count -eq 0 -and $why -match 'разные ссылки' -and $why.Contains($previous.ref) -and $why.Contains($ref) -and $why -match 'Обновить из файла') 'при разных ссылках нет адресной инструкции для проверенной карточки'
        $manual = New-PrintProcessing '17.1' $printNew
        $manual.ref = $previous.ref
        $com = New-ComState -ProdHash 'h2' -TempProcessings @($current,$archived) -ProdProcessings @($manual)
        $ok = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @($modeAnswer,$deployNameAnswer)
        Check ($ok.ExitCode -eq 0 -and $ok.Unexpected.Count -eq 0) 'проверенный файл помешал выполнению действий'
        Check (@($ok.Calls | Where-Object { $_.Line -match 'actions;in=' }).Count -eq 1) 'проверенные действия не запустились'
        $manual.ref = $ref
        $manual.use = 'Используется'
        $other = New-PrintProcessing '10.0' $printOld
        $other.ref = $archived.ref
        $other.use = 'Отключена'
        $other.title = 'Архивная печать'
        $com = New-ComState -ProdHash 'h2' -TempProcessings @($current,$archived) -ProdProcessings @($manual,$other)
        $exact = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @($modeAnswer,$deployNameAnswer)
        Check ($exact.ExitCode -eq 0 -and $exact.Unexpected.Count -eq 0) 'отключённый дубль помешал выпуску проверенной активной карточки с тем же УИД'
        Check (@($exact.Calls | Select-Object -Skip $ok.Calls.Count | Where-Object { $_.Line -match 'actions;in=' }).Count -eq 1) 'после сверки активной карточки действия не запустились'

        $other.use = 'Используется'
        $com = New-ComState -ProdHash 'h2' -TempProcessings @($current,$archived) -ProdProcessings @($manual,$other)
        $twoActive = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @($modeAnswer)
        $why = $twoActive.Output -join ' '
        Check ($twoActive.ExitCode -ne 0 -and $twoActive.Unexpected.Count -eq 0 -and $why.Contains($ref) -and $why.Contains($other.ref) -and $why.Contains('Используется')) 'при двух действующих карточках должны быть названы обе ссылки и статусы публикации'
        Check ((($twoActive.ComLog | Select-Object -Skip $exact.ComLog.Count) -join ' ') -notmatch 'UpdateInfoBase|TerminateSession') 'гейт закрыл базу до разрешения неоднозначности двух активных карточек'

        $manual.use = 'Отключена'
        $com = New-ComState -ProdHash 'h2' -TempProcessings @($current,$archived) -ProdProcessings @($manual,$other)
        $inactive = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @($modeAnswer)
        $why = $inactive.Output -join ' '
        Check ($inactive.ExitCode -ne 0 -and $inactive.Unexpected.Count -eq 0 -and $why.Contains($ref) -and $why -match 'целевая карточка.*Отключена') 'отключённая цель должна быть названа с УИД и своим состоянием'
        Check (@($inactive.Calls | Select-Object -Skip $twoActive.Calls.Count | Where-Object { $_.Line -match 'actions;in=|/UpdateDBCfg|/LoadCfg' }).Count -eq 0) 'для отключённой целевой карточки началась запись'

    }
}
