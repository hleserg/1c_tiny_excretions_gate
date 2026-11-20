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
        Name = 'deploy-contract-legacy-record'
        Text = 'подготовка без идентификатора цели (её записал гейт прежней версии): вопрос человеку; «нет» - ничего не меняется, «да» - отмена проходит как обычно'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $prepared = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Prepare' -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Подготовка обновления'; Item = '^Подготовить все' }, $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $prepared -LocksExpected $false
            $manifest = Join-Path $sb 'deploy\prepared.json'
            Check ($prepared.ExitCode -eq 0 -and (Test-Path -LiteralPath $manifest)) 'контрольная подготовка не создала манифест'
            if (-not (Test-Path -LiteralPath $manifest)) { return }
            # Запись прежней версии: поля target в ней нет.
            $state = [System.IO.File]::ReadAllText($manifest, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            Check ($null -ne $state.PSObject.Properties['target']) 'в манифесте подготовки нет идентификатора цели'
            $state.PSObject.Properties.Remove('target')
            [System.IO.File]::WriteAllText($manifest, (ConvertTo-Json -InputObject $state -Depth 5), $utf8Bom)
            $before = (Get-FileHash -LiteralPath $manifest).Hash
            $writes = @('/LoadCfg', '/DeleteCfg', '/UpdateDBCfg')
            # Журнал вызовов подставной 1С копится по песочнице: перед каждым запуском - с нуля.
            Reset-FakeState $sb
            $no = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-CancelPrepared' -Com (New-ComState) -Answers @(
                @{ Kind = 'confirm'; Header = 'нет идентификатора кластера и базы'; Yes = $false })
            Check ($no.ExitCode -ne 0 -and -not $no.TimedOut -and $no.Unexpected.Count -eq 0 -and $no.UnusedAnswers -eq 0) 'ответ «нет» по записи без идентификатора не остановил отмену'
            foreach ($command in $writes) { Check ((Get-Calls $no @($command)).Count -eq 0) ('после «нет» отправлена команда записи ' + $command) }
            Check (@($no.ComLog | Where-Object { $_ -match 'UpdateInfoBase|TerminateSession' }).Count -eq 0) 'после «нет» изменились свойства или сеансы'
            Check ((Test-Path -LiteralPath $manifest) -and (Get-FileHash -LiteralPath $manifest).Hash -eq $before) 'после «нет» манифест изменён или удалён'
            Reset-FakeState $sb
            $yes = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-CancelPrepared' -Com (New-ComState) -Answers @(
                @{ Kind = 'confirm'; Header = 'нет идентификатора кластера и базы'; Yes = $true },
                @{ Kind = 'confirm'; Header = 'Вернуть расширения'; Yes = $true })
            Check-DeployCommon $yes -LocksExpected $false
            Check ($yes.ExitCode -eq 0) ("после «да» отмена подготовки: код возврата {0}, ждали 0" -f $yes.ExitCode)
            Check ((Get-Calls $yes @('/LoadCfg', '-Extension Адаптация')).Count -eq 1) 'после «да» расширение не возвращено из резервной копии'
            Check (-not (Test-Path -LiteralPath $manifest)) 'после «да» и отмены манифест остался'
        }
    },
    @{
        Name = 'deploy-contract-gate-no-agent'
        Text = 'прогон гейта на серверной тестовой базе, агент сервера не ответил вовсе: прогон идёт до вердикта без блокировок и списка сеансов и говорит об этом'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $file = Add-InboxFile $sb $cfeName
            # В run.ps1 агент сервера - только настоящий COM, на машине тестов его нет: это и есть «агент не ответил».
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $file) -Com (New-ComState)
            Check-Common $r
            Check ($null -ne $r.Verdict) 'прогон без агента сервера не дошёл до вердикта'
            Check (@($r.Output | Where-Object { $_ -match 'блокировку регламентных заданий поставить не смог' }).Count -gt 0) 'нет строки о том, что блокировку заданий поставить не удалось'
            Check (@($r.Output | Where-Object { $_ -match 'сеансы проверить не смог' }).Count -gt 0) 'нет строки о том, что сеансы проверить не удалось'
        }
    },
    @{
        Name = 'gate-report-names'
        Text = 'разбор прогона называет поимённо то, что в итоге шагов стоит числом: новые и пропавшие снимки, пропущенные модульные тесты с причиной, известные ошибки, которых не было в прошлом прогоне'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $file = Add-InboxFile $sb $cfeName
            $tasks = {
                param([string]$Key)
                @(
                    @{ key = 'Окружение'; title = 'Окружение и расширения'; step = 'Окружение'; lines = @('[ОК] Обработка запущена под полными правами') },
                    @{ key = 'Обмены'; title = 'Обмены'; step = 'Обмены'; lines = @('[ОК] Бухгалтерия: документ выгружается'); snapshots = @{ $Key = 'Сумма=100' } }
                )
            }
            $oldKey = 'обмен|Бухгалтерия|Документ.Старый|11111111-2222-3333-4444-555555555555'
            $newKey = 'обмен|Бухгалтерия|Документ.Новый|99999999-8888-7777-6666-555555555555'
            $fake = @{ selfcheck = @(@{ tasks = (& $tasks $oldKey) }, @{ tasks = (& $tasks $newKey); fingerprint = 'после' }) }
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}"' -f $file) -Fake $fake
            Check-Common $r
            if (-not $r.RunDir) { Check $false 'нет папки прогона'; return }
            $keysFile = Join-Path $r.RunDir 'selfcheck-after.snapshots.keys.txt'
            Check (Test-Path -LiteralPath $keysFile) 'нет selfcheck-after.snapshots.keys.txt'
            $reportText = [System.IO.File]::ReadAllText((Join-Path $r.RunDir 'report.txt'), $utf8)
            Check ($reportText.Contains('== Снимки самопроверки: новых 1, пропало 1')) 'в разборе нет раздела о новых и пропавших снимках'
            Check ($reportText.Contains('новый: ' + $newKey) -and $reportText.Contains('пропал: ' + $oldKey)) 'в разборе нет ключей нового и пропавшего снимка'
            # Следующий прогон - из файлов: известная ошибка, которой в прошлом прогоне не было, и пропущенный тест.
            $next = Join-Path (Split-Path -Parent $r.RunDir) '99991231-235959'
            New-Item -ItemType Directory -Path $next -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $r.RunDir 'verdict.json') -Destination $next
            $normFile = Join-Path $r.RunDir 'selfcheck-after.norm.txt'
            if (-not (Test-Path -LiteralPath $normFile)) { Check $false 'в папке прогона нет selfcheck-after.norm.txt'; return }
            $knownOld = @([System.IO.File]::ReadAllLines($normFile, $utf8) | ForEach-Object { $_.TrimStart([char]0xFEFF) } | Where-Object { $_ })
            $firstSeen = '[ОШИБКА] ПроверкиДокументов :: Шаг прерван исключением: метод не обнаружен'
            $brandNew = '[ОШИБКА] Обмены :: Бухгалтерия: документ не выгружается'
            [System.IO.File]::WriteAllLines((Join-Path $next 'selfcheck-after.norm.txt'), [string[]](@($knownOld) + @($firstSeen, $brandNew)), $utf8Bom)
            [System.IO.File]::WriteAllLines((Join-Path $next 'selfcheck-after.new.txt'), [string[]]@($brandNew), $utf8Bom)
            [System.IO.File]::WriteAllLines((Join-Path $next 'unittests.txt'), [string[]]@("OK`tОМ_Пример.Сложение`t", "SKIP`tОМ_Пример.Остатки`tНет документа с остатком на складе"), $utf8Bom)
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sb 'report.ps1') -RunDir $next -Quiet
            $nextReport = Join-Path $next 'report.txt'
            if (-not (Test-Path -LiteralPath $nextReport)) { Check $false 'разбор второго прогона не записал report.txt'; return }
            $nextText = [System.IO.File]::ReadAllText($nextReport, $utf8)
            Check ($nextText.Contains('== Модульные тесты: пропущено 1') -and $nextText.Contains('ОМ_Пример.Остатки: Нет документа с остатком на складе')) 'в разборе нет пропущенного теста с причиной'
            Check ($nextText.Contains(('не было в прошлом прогоне ({0}): 1 из 1 известных' -f (Split-Path -Leaf $r.RunDir)))) 'в разборе нет раздела об известных ошибках, которых не было в прошлом прогоне'
            Check ($nextText.Contains('   ' + $firstSeen)) 'в разборе нет текста известной ошибки, которой не было в прошлом прогоне'
            Check (-not $nextText.Contains('   ' + $brandNew)) 'новая ошибка попала в раздел известных'
        }
    },
    @{
        Name = 'deploy-contract-open-early'
        Text = 'обновление с блокировкой сеансов: блокировки сняты до статьи в базу знаний и выгрузки рабочей, потом вход без кода разрешения; в итоге - простой (#24, #2)'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $deployConfig
            $com = New-ComState -Sessions @(@{ id = 5; base = 'erp_base'; app = '1CV8C'; user = 'Пользователь'; host = 'pc1' })
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer,
                @{ Kind = 'one'; Header = 'В erp_base есть сеансы'; Item = 'Поставить блокировку' })
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            $clock = { param([string]$Text) [timespan]::ParseExact($Text, 'hh\:mm\:ss\.fff', [System.Globalization.CultureInfo]::InvariantCulture) }
            $writes = @($r.ComLog | Where-Object { $_ -match 'UpdateInfoBase erp_base ' })
            $closed = @($writes | Where-Object { $_ -match 'sessionsDenied=1' })
            Check ($closed.Count -gt 0) 'блокировку начала сеансов не ставили'
            Check ($writes.Count -gt 0 -and $writes[-1] -match 'scheduledJobsDenied=0 sessionsDenied=0') 'последняя запись свойств рабочей - не снятие блокировок'
            $article = Get-Calls $r @('ENTERPRISE', 'kbarticle')
            $plain = Get-Calls $r @('ENTERPRISE', 'canary-plain')
            $coded = Get-Calls $r @('ENTERPRISE', 'canary.txt')
            $dumps = Get-Calls $r @('/DumpConfigToFiles', 'fake\erp_base', '-Extension Адаптация')
            Check ($article.Count -eq 1) ("статей в базу знаний: {0}, ждали одну" -f $article.Count)
            Check ($plain.Count -eq 1) ("входов без кода разрешения: {0}, ждали один" -f $plain.Count)
            Check ($coded.Count -eq 1 -and $coded[0].Line.Contains('/UC')) 'канареечный вход при закрытой базе шёл без кода разрешения'
            if ($plain.Count -eq 1) { Check (-not $plain[0].Line.Contains('/UC')) 'вход «без кода» запущен с ключом /UC' }
            if ($writes.Count -gt 0 -and $article.Count -eq 1 -and $plain.Count -eq 1 -and $dumps.Count -gt 0) {
                $opened = & $clock ($writes[-1].Split("`t")[0])
                Check ($opened -le (& $clock $plain[0].Time)) 'вход без кода разрешения шёл до снятия блокировок'
                Check ((& $clock $plain[0].Time) -le (& $clock $article[0].Time)) 'статья в базу знаний записана раньше входа без кода разрешения'
                Check ($opened -le (& $clock $article[0].Time)) 'статья в базу знаний записана при закрытой базе'
                Check ($opened -le (& $clock $dumps[-1].Time)) 'выгрузка рабочей после обновления шла при закрытой базе'
            }
            else { Check ($dumps.Count -gt 0) 'рабочая после обновления в файлы не выгружалась' }
            Check (@($r.Output | Where-Object { $_ -match 'Простой erp_base: \d+ мин \d\d с' }).Count -gt 0) 'нет строки о простое рабочей'
            Check (@($r.Output | Where-Object { $_ -match '\[OK\] Вход без кода разрешения: вошёл' }).Count -gt 0) 'нет строки о входе без кода разрешения'
            $record = Get-DeployRecord $sb
            Check ($null -ne $record) 'нет deploy.json'
            if ($null -ne $record) {
                Check ($record.outcome -eq 'updated') ("итог {0}, ждали updated" -f $record.outcome)
                Check ($null -ne $record.PSObject.Properties['downtimeSec'] -and $null -ne $record.PSObject.Properties['openedAt']) 'в deploy.json нет простоя'
                Check ($null -ne $record.PSObject.Properties['plainLogin'] -and $record.plainLogin.status -eq 'OK') 'в deploy.json нет входа без кода разрешения'
                $summaryText = [System.IO.File]::ReadAllText((Join-Path $record.Dir 'summary.txt'), $utf8)
                Check ($summaryText.Contains('Простой erp_base') -and $summaryText.Contains('Вход без кода разрешения')) 'в summary.txt нет простоя или входа без кода'
            }
        }
    },
    @{
        Name = 'deploy-contract-plain-login-fail'
        Text = 'после снятия блокировок без кода разрешения войти не удалось: красная строка, обновление остаётся, отката нет, скрипт дошёл до конца (#2)'
        Run = {
            param($Name)
            $config = @{ PlainLoginTimeoutSec = 3 }
            foreach ($key in $deployConfig.Keys) { $config[$key] = $deployConfig[$key] }
            $sb = New-Sandbox $Name -Config $config
            # Первый вход - канареечный, с кодом; второй - без кода: клиент висит, результата нет.
            $fake = @{ canary = @(@{ status = 'ok' }, @{ noresult = $true }) }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Fake $fake -Com (New-ComState) -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $r
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0: вход без кода исход обновления не меняет" -f $r.ExitCode)
            Check (@($r.Output | Where-Object { $_ -match '\[FAIL\] Вход без кода разрешения' }).Count -gt 0) 'нет красной строки о входе без кода разрешения'
            Check (@($r.Output | Where-Object { $_ -match 'ВХОД В erp_base БЕЗ КОДА РАЗРЕШЕНИЯ НЕ ПРОШЁЛ' }).Count -gt 0) 'в итоге нет строки о несостоявшемся входе'
            Check ((Get-Calls $r @('/LoadCfg', '-Extension Адаптация', 'fake\erp_base')).Count -eq 1) 'после несостоявшегося входа расширение загружали ещё раз (откат?)'
            $record = Get-DeployRecord $sb
            Check ($null -ne $record) 'нет deploy.json'
            if ($null -ne $record) {
                Check ($record.outcome -eq 'updated') ("итог {0}, ждали updated" -f $record.outcome)
                Check ($null -ne $record.PSObject.Properties['plainLogin'] -and $record.plainLogin.status -eq 'FAIL') 'в deploy.json вход без кода не отмечен как несостоявшийся'
                $runLog = Join-Path $record.Dir 'run.log'
                if (Test-Path -LiteralPath $runLog) {
                    $plainLines = @([System.IO.File]::ReadAllLines($runLog, $utf8) | Where-Object { $_.Contains('canary-plain') -and $_.Contains('1cv8c.exe') })
                    Check ($plainLines.Count -eq 1 -and -not $plainLines[0].Contains('/UC')) 'вход «без кода» запущен с ключом /UC или не запущен'
                }
                else { Check $false 'нет run.log обновления' }
            }
        }
    },
    @{
        Name = 'deploy-contract-plain-login-kept-lock'
        Text = 'блокировка начала сеансов стояла до обновления (код тот же) и оставлена: вход без кода не проверяется, об этом сказано; блокировка на месте (#2)'
        Run = {
            param($Name)
            $config = @{ UnlockCode = 'fixture-code' }
            foreach ($key in $deployConfig.Keys) { $config[$key] = $deployConfig[$key] }
            $sb = New-Sandbox $Name -Config $config
            $com = New-ComState
            $prod = $com.bases['erp_base']
            $prod.sessionsDenied = $true
            $prod.permissionCode = 'fixture-code'
            $prod.deniedMessage = 'Служебные работы'
            $prod.deniedFrom = (Get-Date).AddHours(-1).ToString('s')
            $prod.deniedTo = (Get-Date).AddDays(1).ToString('s')
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com $com -Answers @(
                @{ Kind = 'one'; Header = 'Обновление erp_base'; Item = '^Обновить выбранные' },
                @{ Kind = 'many'; Header = 'необновлённые расширения'; Indexes = @(0) },
                $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $r -LocksExpected $false
            Check ($r.ExitCode -eq 0) ("код возврата {0}, ждали 0" -f $r.ExitCode)
            Check ((Get-Calls $r @('ENTERPRISE', 'canary-plain')).Count -eq 0) 'вход без кода запускался при оставленной блокировке'
            Check (@($r.Output | Where-Object { $_ -match '\[SKIP\] Вход без кода разрешения' }).Count -gt 0) 'не сказано, что вход без кода не проверялся'
            Check (@($r.Output | Where-Object { $_ -match 'Простой erp_base' }).Count -eq 0) 'посчитан простой, хотя базу закрывал не этот запуск'
            if ($null -ne $r.ComState) {
                $after = $r.ComState.bases.erp_base
                Check ([bool]$after.sessionsDenied -and [string]$after.permissionCode -ceq 'fixture-code') 'блокировку начала сеансов, стоявшую до обновления, сняли или изменили'
                Check (-not [bool]$after.scheduledJobsDenied) 'в конце осталась блокировка регламентных заданий рабочей'
            }
            $record = Get-DeployRecord $sb
            if ($null -ne $record) { Check ($null -ne $record.PSObject.Properties['plainLogin'] -and $record.plainLogin.status -eq 'SKIP') 'в deploy.json нет отметки, что вход без кода пропущен' }
            else { Check $false 'нет deploy.json' }
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
