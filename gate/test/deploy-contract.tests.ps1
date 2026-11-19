#requires -Version 5.1

# Читаем определения функций без выполнения верхнего уровня deploy.ps1.
function Read-ContractDeployAst {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors[0].Message) }
    return $tree
}

function New-ContractDeployModule {
    $tree = Read-ContractDeployAst (Join-Path $ciRoot 'deploy.ps1')
    $definitions = @($tree.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text })
    return (New-Module -ArgumentList ($definitions -join "`n"), (Join-Path $ciRoot 'locks.ps1'), (Join-Path $ciRoot 'cluster-target.ps1') -ScriptBlock {
            param($Source, $LocksScript, $ClusterScript)
            . $ClusterScript
            . $LocksScript
            . ([scriptblock]::Create($Source))
            function New-V8Connector { throw 'Контрактный тест работает только с локальными объектами' }
            Export-ModuleMember -Function @()
        })
}

function New-ContractCatalogLink {
    # Одна регистрация ИБ видна двум рабочим процессам кластера. Завершение сеанса только пишет UUID в журнал.
    param([object[]]$Catalogs)
    $workers = @{}
    $clusters = @(foreach ($catalog in $Catalogs) {
            $worker = [pscustomobject]@{ Base = [pscustomobject]@{ Name = $catalog.Name; UUID = $catalog.BaseId } }
            $worker | Add-Member ScriptMethod AuthenticateAdmin { param($User, $Password) }
            $worker | Add-Member ScriptMethod AddAuthentication { param($User, $Password) }
            $worker | Add-Member ScriptMethod GetInfoBases { return @($this.Base) }
            $workers['tcp://' + $catalog.HostName + ':1560'] = $worker
            $workers['tcp://' + $catalog.HostName + ':1561'] = $worker
            [pscustomobject]@{ UUID = $catalog.ClusterId; HostName = $catalog.HostName; MainPort = 1541 }
        })
    $connector = [pscustomobject]@{ Workers = $workers }
    $connector | Add-Member ScriptMethod ConnectWorkingProcess { param($Address) return $this.Workers[$Address] }
    $agent = [pscustomobject]@{ Catalogs = $Catalogs; Closed = (New-Object System.Collections.Generic.List[string]) }
    $agent | Add-Member ScriptMethod GetInfoBases {
        param($Cluster)
        foreach ($catalog in $this.Catalogs) {
            if ($catalog.ClusterId -eq $Cluster.UUID) { [pscustomobject]@{ Name = $catalog.Name; UUID = $catalog.BaseId } }
        }
    }
    $agent | Add-Member ScriptMethod GetInfoBaseSessions {
        param($Cluster, $ShortBase)
        $catalog = @($this.Catalogs | Where-Object { $_.ClusterId -eq $Cluster.UUID -and $_.BaseId -eq $ShortBase.UUID })
        if ($catalog.Count -ne 1) { throw 'сеансы другой ИБ' }
        return [pscustomobject]@{ SessionID = 17; AppID = '1CV8C'; StartedAt = '11:00'; infoBase = $ShortBase }
    }
    $agent | Add-Member ScriptMethod TerminateSession {
        param($Cluster, $Session)
        $this.Closed.Add(('{0}/{1}' -f $Cluster.UUID, $Session.infoBase.UUID))
    }
    $agent | Add-Member ScriptMethod GetWorkingProcesses {
        param($Cluster)
        return @(
            [pscustomobject]@{ Running = 1; HostName = $Cluster.HostName; MainPort = 1560 }
            [pscustomobject]@{ Running = 1; HostName = $Cluster.HostName; MainPort = 1561 }
        )
    }
    return [pscustomobject]@{ Agent = $agent; Connector = $connector; Clusters = $clusters; Errors = @(); ClusterUser = ''; ClusterPassword = '' }
}

@(
    @{
        Name = 'deploy-contract-prepared-profile'
        Text = 'чужой профиль не передаёт подготовку на отмену и сохраняет исходный манифест'
        Run = {
            param($Name)
            $first = New-Sandbox ($Name + '-a') -Config $deployConfig
            $prepared = Invoke-Script -Sandbox $first -Script 'deploy.ps1' -Arguments '-Prepare' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Подготовка обновления'; Item = '^Подготовить все' }, $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $prepared -LocksExpected $false
            $manifest = Join-Path $first 'deploy\prepared.json'
            Check ($prepared.ExitCode -eq 0 -and (Test-Path -LiteralPath $manifest)) 'контрольная подготовка не создала манифест'
            if (-not (Test-Path -LiteralPath $manifest)) { return }
            $before = (Get-FileHash -LiteralPath $manifest).Hash

            $config = $deployConfig.Clone()
            $config.ProdBase = 'fixture_other'
            $config['ForbiddenBases'] = @($deployConfig.ProdBase, $config.ProdBase)
            $config['DeployDir'] = Split-Path -Parent $manifest
            $second = New-Sandbox ($Name + '-b') -Config $config
            $com = New-ComState
            $com.bases[$config.ProdBase] = New-ComBase -AdaptHash 'other'
            # Подставной конфигуратор регистрирует запрос записи и отказывает до обработки команды.
            $writes = @('/LoadCfg', '/DeleteCfg', '/UpdateDBCfg')
            $fake = @{ designer = @(foreach ($command in $writes) { @{ match = @($command); exit = 1; log = 'Тестовый профиль доступен только для чтения' } }) }
            $result = Invoke-Script -Sandbox $second -Script 'deploy.ps1' -Arguments '-CancelPrepared' -Com $com -Fake $fake -Answers @(
                @{ Kind = 'confirm'; Header = 'Вернуть расширения'; Yes = $true })
            Check (-not $result.TimedOut -and $result.Unexpected.Count -eq 0 -and -not $result.Stderr) 'проверка чужого профиля не завершилась штатно'
            foreach ($command in $writes) { Check ((Get-Calls $result @($command)).Count -eq 0) 'чужой профиль получил запрос изменения конфигурации' }
            Check (@($result.ComLog | Where-Object { $_ -match 'UpdateInfoBase|TerminateSession' }).Count -eq 0) 'изменились свойства или сеансы чужого профиля'
            Check ((Test-Path -LiteralPath $manifest) -and (Get-FileHash -LiteralPath $manifest).Hash -eq $before) 'чужой манифест утрачен или изменён'
            Check (($result.Output -join "`n") -match '(?i)друг(ая|ой|ую|ом)|несовпад|не совпад|иной|не соответств') 'нет объяснения отказа по цели подготовки'

            # У двух профилей совпадает Ref, но различается сервер. Проверяем все входы до первого вопроса.
            $config = $deployConfig.Clone()
            $config.Server = 'fixture-other.invalid'
            $config['DeployDir'] = Split-Path -Parent $manifest
            $sameName = New-ComState
            $sameName['clusterHost'] = $config.Server
            foreach ($mode in @('-ApplyPrepared', '-CancelPrepared', '-Prepare')) {
                $other = New-Sandbox ($Name + $mode) -Config $config
                $result = Invoke-Script -Sandbox $other -Script 'deploy.ps1' -Arguments $mode -Com $sameName -Fake $fake
                Check ($result.ExitCode -ne 0 -and -not $result.TimedOut -and $result.Unexpected.Count -eq 0) ("{0}: не отказал до первого вопроса" -f $mode)
                Check (($result.Output -join "`n") -match 'не совпадает с целью') ("{0}: нет отказа по идентификатору цели" -f $mode)
                foreach ($command in $writes) { Check ((Get-Calls $result @($command)).Count -eq 0) ("{0}: отправлена команда записи" -f $mode) }
                Check (@($result.ComLog | Where-Object { $_ -match 'UpdateInfoBase|TerminateSession' }).Count -eq 0) ("{0}: изменились свойства или сеансы" -f $mode)
                Check ((Test-Path -LiteralPath $manifest) -and (Get-FileHash -LiteralPath $manifest).Hash -eq $before) ("{0}: манифест изменился" -f $mode)
            }
        }
    },
    @{
        Name = 'deploy-contract-existing-locks'
        Text = 'очистка без собственных изменений сохраняет исходные свойства ИБ в fakecom'
        Run = {
            param($Name)
            $dir = New-Sandbox $Name
            $file = Join-Path $dir 'fake\owned-locks.json'
            $com = New-ComState -ProdJobsDenied $true
            $baseName = $deployConfig.ProdBase
            $base = $com.bases[$baseName]
            $base.sessionsDenied = $true
            $base.permissionCode = 'fixture-owner'
            $base.deniedMessage = 'Служебные работы'
            $base.deniedFrom = (Get-Date).AddDays(1).ToString('s')
            $base.deniedTo = (Get-Date).AddDays(2).ToString('s')
            [System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $com -Depth 10), $utf8)
            $module = New-ContractDeployModule
            $cleanupLog = @(& $module {
                param($FakeComScript, $File, $BaseName)
                . $FakeComScript
                $script:ProdBase = $BaseName
                $script:ProdUser = ''
                $script:ProdPassword = ''
                $script:ProdLockState = New-GateLockState
                $connector = New-FakeComConnector $File
                $agent = New-FakeComAgent $File
                $link = [pscustomobject]@{ Agent = $agent; Connector = $connector; Clusters = @($agent.GetClusters()); Errors = @(); ClusterUser = ''; ClusterPassword = '' }
                function Connect-ClusterAgent { return $link }
                function Write-Line { param($Text, $Color) $Text }
                $control = Get-BaseInfo -Link (Connect-ClusterAgent) -BaseName $BaseName -User '' -Password ''
                if (-not $control.InfoBase.ScheduledJobsDenied -or -not $control.InfoBase.SessionsDenied) { throw 'В контрольном чтении fakecom нет исходных запретов' }
                Clear-ProdLocks
            } (Join-Path $here 'fakecom.ps1') $file $baseName)
            Check (-not (($cleanupLog -join ' ') -match 'НЕ СНЯЛ|не смог')) 'очистка завершилась ошибкой тестового окружения'
            $state = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
            $after = $state.bases.PSObject.Properties[$baseName].Value
            Check ([bool]$after.scheduledJobsDenied -and [bool]$after.sessionsDenied) 'очистка изменила исходные флаги'
            Check ($after.permissionCode -ceq $base.permissionCode -and $after.deniedMessage -ceq $base.deniedMessage) 'очистка изменила реквизиты ранее установленного запрета'
            Check ([datetime]$after.deniedFrom -eq [datetime]$base.deniedFrom -and [datetime]$after.deniedTo -eq [datetime]$base.deniedTo) 'очистка изменила расписание запрета'
            $log = Join-Path $dir 'fake\com.log'
            if (Test-Path -LiteralPath $log) { Check (-not ([System.IO.File]::ReadAllText($log) -match 'UpdateInfoBase')) 'очистка записывала исходные свойства' }
        }
    },
    @{
        Name = 'deploy-contract-scheduled-lock'
        Text = 'запланированный запрет с тем же кодом переживает остановку после установки запрета заданий'
        Run = {
            param($Name)
            $dir = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState
            $base = $com.bases[$deployConfig.ProdBase]
            $base.sessionsDenied = $true
            $base.permissionCode = '0'
            $base.deniedMessage = 'Плановое обслуживание'
            $base.deniedFrom = (Get-Date).AddDays(1).ToString('s')
            $base.deniedTo = (Get-Date).AddDays(2).ToString('s')
            $r = Invoke-Script -Sandbox $dir -Script 'deploy.ps1' -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление'; Item = '^Обновить все' }, $deployRiskAnswer, $deployNameAnswer)
            Check ($r.ExitCode -eq 1 -and -not $r.TimedOut -and -not $r.Stderr -and $r.Unexpected.Count -eq 0) 'остановка по расписанию не завершилась штатно'
            Check (($r.Output -join "`n") -match 'оставляю её расписание') 'нет объяснения остановки по расписанию'
            $after = $r.ComState.bases.PSObject.Properties[$deployConfig.ProdBase].Value
            Check ([bool]$after.sessionsDenied -and $after.permissionCode -ceq $base.permissionCode -and $after.deniedMessage -ceq $base.deniedMessage) 'изменился ранее поставленный запрет начала сеансов'
            Check ([datetime]$after.deniedFrom -eq [datetime]$base.deniedFrom -and [datetime]$after.deniedTo -eq [datetime]$base.deniedTo) 'изменились даты запрета'
            Check (@($r.ComLog | Where-Object { $_ -match 'scheduledJobsDenied=1' }).Count -gt 0 -and -not $after.scheduledJobsDenied) 'после частичной подготовки не снят свой запрет заданий'
            Check ((Get-Calls $r @('/LoadCfg')).Count -eq 0 -and (Get-Calls $r @('/UpdateDBCfg')).Count -eq 0) 'после отказа изменена конфигурация'
        }
    },
    @{
        Name = 'deploy-contract-lock-replacement'
        Text = 'возврат исходных реквизитов и сохранение перенесённой другим владельцем блокировки'
        Run = {
            param($Name)
            . (Join-Path $ciRoot 'locks.ps1')
            . (Join-Path $here 'fakecom.ps1')
            $dir = New-Sandbox $Name
            $file = Join-Path $dir 'fake\locks.json'
            $com = New-ComState -ProdJobsDenied $true
            $baseName = $deployConfig.ProdBase
            $base = $com.bases[$baseName]
            $now = Get-Date
            $base.permissionCode = 'previous'
            $base.deniedMessage = 'Сохранённые параметры'
            $base.deniedFrom = $now.AddDays(-3).ToString('s')
            $base.deniedTo = $now.AddDays(-2).ToString('s')
            [System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $com -Depth 10), $utf8)
            $process = New-FakeComProcess $file
            $read = { param($t) @($t.Process.GetInfoBases()) | Where-Object { $_.Name -eq $baseName } }
            $target = [pscustomobject]@{ Process = $process; InfoBase = $null }
            $state = New-GateLockState
            $target.InfoBase = & $read $target
            Check (-not (Set-GateJobsLock $state $target $read)) 'присвоен чужой запрет заданий'
            $counter = @{ Reads = 0 }
            $failConfirmation = {
                param($t)
                $counter.Reads++
                if ($counter.Reads -eq 2) { throw 'контрольное чтение недоступно' }
                & $read $t
            }
            $refusal = ''
            try { Set-GateSessionLock $state $target $now ($now.AddHours(1)) 'same' 'Работы' $failConfirmation }
            catch { $refusal = $_.Exception.Message }
            Check ($refusal -match 'контрольное чтение недоступно') 'не воспроизведена потеря подтверждения после успешной записи'
            $target.InfoBase = & $read $target
            $null = Restore-GateLocks $state $target $true $read
            $target.InfoBase = & $read $target
            Check ($target.InfoBase.ScheduledJobsDenied -and -not $target.InfoBase.SessionsDenied) 'неверные флаги после снятия своего запрета'
            Check ($target.InfoBase.PermissionCode -ceq $base.permissionCode -and $target.InfoBase.DeniedMessage -ceq $base.deniedMessage) 'потеряны исходные реквизиты выключенного запрета'
            Check ($target.InfoBase.DeniedFrom -eq [datetime]$base.deniedFrom -and $target.InfoBase.DeniedTo -eq [datetime]$base.deniedTo) 'потеряны исходные даты'
            Set-GateSessionLock $state $target $now ($now.AddHours(1)) 'same' 'Работы' $read
            $target.InfoBase = & $read $target
            $target.InfoBase.DeniedTo = $target.InfoBase.DeniedTo.AddDays(1)
            $target.Process.UpdateInfoBase($target.InfoBase)
            $changed = $target.InfoBase.DeniedTo
            $target.InfoBase = & $read $target
            $null = Restore-GateLocks $state $target $true $read
            $after = & $read $target
            Check ($after.SessionsDenied -and $after.ScheduledJobsDenied -and $after.PermissionCode -ceq 'same' -and $after.DeniedTo -eq $changed) 'снят запрет, время которого изменили до очистки'
        }
    },
    @{
        Name = 'deploy-contract-ambiguous-target'
        Text = 'чтение свойств по имени находит единственную ИБ и отклоняет две одноимённые ИБ'
        Run = {
            param($Name)
            $module = New-ContractDeployModule
            $a = @{ HostName = 'one.invalid'; ClusterId = [guid]::NewGuid(); Name = 'fixture'; BaseId = [guid]::NewGuid() }
            $b = @{ HostName = 'two.invalid'; ClusterId = [guid]::NewGuid(); Name = 'fixture'; BaseId = [guid]::NewGuid() }
            $read = { param($Link) Get-BaseInfo -Link $Link -BaseName 'fixture' -User '' -Password '' }
            $singleWorker = New-ContractCatalogLink @($a)
            $singleWorker.Connector.Workers.Remove('tcp://' + $a.HostName + ':1560')
            $single = & $module $read $singleWorker
            Check ($single.InfoBase.UUID -eq $a.BaseId) 'положительный контроль: прочитана не та ИБ'
            $refusal = ''
            try { $null = & $module $read (New-ContractCatalogLink @($a, $b)) }
            catch { $refusal = $_.Exception.Message }
            Check ($refusal -match '(?i)неоднознач|однознач|нескольк|двух|две|более одн|ambig') 'одно имя разрешилось в ИБ без явного выбора из двух кластеров'
            $stop = {
                param($Link)
                $script:ProdBase = 'fixture'
                $script:ProdUser = ''
                $script:ProdPassword = ''
                function Write-RunLog { param($Text) }
                Stop-BaseSessions $Link 'fixture'
            }
            $both = New-ContractCatalogLink @($a, $b)
            $denied = $false
            try { $null = & $module $stop $both } catch { $denied = $_.Exception.Message -match 'Неоднозначная цель' }
            Check ($denied -and $both.Agent.Closed.Count -eq 0) 'неоднозначный выбор допустил завершение сеанса'
            $b.Name = 'different'
            $singleLink = New-ContractCatalogLink @($a, $b)
            $null = & $module $stop $singleLink
            Check ($singleLink.Agent.Closed.Count -eq 1 -and $singleLink.Agent.Closed[0] -eq ('{0}/{1}' -f $a.ClusterId, $a.BaseId)) 'положительный контроль: ожидаемый сеанс не завершён или выбран другой UUID'

        }
    }
)
