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
    return (New-Module -ArgumentList ($definitions -join "`n") -ScriptBlock {
            param($Source)
            . ([scriptblock]::Create($Source))
            function New-V8Connector { throw 'Контрактный тест работает только с локальными объектами' }
            Export-ModuleMember -Function @()
        })
}

function New-ContractCatalogLink {
    # Каждая запись - отдельный кластер, рабочий процесс и запись ИБ. У объектов есть только методы чтения.
    param([object[]]$Catalogs)
    $workers = @{}
    $clusters = @(foreach ($catalog in $Catalogs) {
            $worker = [pscustomobject]@{ Base = [pscustomobject]@{ Name = $catalog.Name; UUID = $catalog.BaseId } }
            $worker | Add-Member ScriptMethod AuthenticateAdmin { param($User, $Password) }
            $worker | Add-Member ScriptMethod AddAuthentication { param($User, $Password) }
            $worker | Add-Member ScriptMethod GetInfoBases { return @($this.Base) }
            $workers['tcp://' + $catalog.HostName + ':1560'] = $worker
            [pscustomobject]@{ UUID = $catalog.ClusterId; HostName = $catalog.HostName; MainPort = 1541 }
        })
    $connector = [pscustomobject]@{ Workers = $workers }
    $connector | Add-Member ScriptMethod ConnectWorkingProcess { param($Address) return $this.Workers[$Address] }
    $agent = [pscustomobject]@{}
    $agent | Add-Member ScriptMethod GetWorkingProcesses {
        param($Cluster)
        return @([pscustomobject]@{ Running = 1; HostName = $Cluster.HostName; MainPort = 1560 })
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
            [System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $com -Depth 10), $utf8)
            $module = New-ContractDeployModule
            $cleanupLog = @(& $module {
                param($FakeComScript, $File, $BaseName)
                . $FakeComScript
                $script:ProdBase = $BaseName
                $script:ProdUser = ''
                $script:ProdPassword = ''
                $script:ProdLocksArmed = $true
                $script:KeepForeignSessionLock = $false
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
            $log = Join-Path $dir 'fake\com.log'
            if (Test-Path -LiteralPath $log) { Check (-not ([System.IO.File]::ReadAllText($log) -match 'UpdateInfoBase')) 'очистка записывала исходные свойства' }
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
            $single = & $module $read (New-ContractCatalogLink @($a))
            Check ($single.InfoBase.UUID -eq $a.BaseId) 'положительный контроль: прочитана не та ИБ'
            $refusal = ''
            try { $null = & $module $read (New-ContractCatalogLink @($a, $b)) }
            catch { $refusal = $_.Exception.Message }
            Check ($refusal -match '(?i)неоднознач|однознач|нескольк|двух|две|более одн|ambig') 'одно имя разрешилось в ИБ без явного выбора из двух кластеров'
        }
    }
)
