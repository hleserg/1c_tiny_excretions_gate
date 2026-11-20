#requires -Version 5.1

# deploy.ps1 открывает только базы кластера, а run.ps1 умеет работать с файловой.
# Для дочернего прогона Git-импорта меняем только профиль. Настоящий run.ps1
# выполняет загрузку, оценку шагов и запись итогов на подставном конфигураторе.
function Set-RevisionFileGate {
    param([string]$Sandbox)
    $config = Import-PowerShellDataFile -LiteralPath (Join-Path $Sandbox 'config.psd1')
    $config['File'] = Join-Path $Sandbox 'erp_temp_test'
    $lines = @('@{') + @($config.Keys | ForEach-Object { '    {0} = {1}' -f $_, (ConvertTo-Psd1 $config[$_]) }) + @('}')
    [System.IO.File]::WriteAllLines((Join-Path $Sandbox 'gate-file.psd1'), [string[]]$lines, $utf8Bom)
    $entry = Join-Path $Sandbox 'run.ps1'
    Move-Item -LiteralPath $entry -Destination (Join-Path $Sandbox 'gate-under-test.ps1')
    $launcher = @'
param([string]$Kit, [string]$KitSource, [string]$KitBranch, [string]$ActionsDir, [string]$Config, [string]$UiChannel, [string]$OnNotGreen, [string]$OnSessions)
$PSBoundParameters['Config'] = Join-Path $PSScriptRoot 'gate-file.psd1'
& (Join-Path $PSScriptRoot 'gate-under-test.ps1') @PSBoundParameters
exit $LASTEXITCODE
'@
    [System.IO.File]::WriteAllText($entry, $launcher, $utf8Bom)
}

function Invoke-RevisionPartialImport {
    param([string]$Name, [switch]$Processing)
    $sb = New-GitSandbox $Name
    Set-RevisionFileGate $sb
    $gh = Get-FakeGh $sb
    if (-not $gh.FakeDir) { throw 'Тест импорта требует подставной GitHub' }
    $original = (Get-GhHead -Gh $gh -Branch 'main').Sha
    if (-not $original) {
        $seed = [pscustomobject]@{ Path = 'README.md'; Bytes = $utf8.GetBytes('Начало истории') }
        $original = New-GhCommit -Gh $gh -Parent '' -Changes @($seed) -Message 'Прежнее состояние'
        Set-GhBranch -Gh $gh -Branch 'main' -Sha $original -Create
    }
    $stateDir = Join-Path $sb 'git\ext'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $old = @{ repo = 'owner/ext'; commit = $original; how = 'loaded' }
    [System.IO.File]::WriteAllText((Join-Path $stateDir 'state.json'), (ConvertTo-Json $old), $utf8Bom)
    if ($Processing) {
        $changes = @([pscustomobject]@{ Path = 'processings/Печать/Печать.xml'; Bytes = $utf8.GetBytes('<MetaDataObject><ExternalDataProcessor><Properties><Name>Печать</Name></Properties></ExternalDataProcessor></MetaDataObject>') })
        $failure = @{ match = @('/LoadExternalDataProcessorOrReportFromFiles'); exit = 1; log = 'Ошибка сборки' }
    } else {
        $changes = @(foreach ($extension in @('Адаптация', 'Доработки')) {
            $xml = '<MetaDataObject><Configuration><Properties><Name>{0}</Name><Version>1</Version></Properties></Configuration></MetaDataObject>' -f $extension
            [pscustomobject]@{ Path = ('extensions/{0}/Configuration.xml' -f $extension); Bytes = $utf8.GetBytes($xml) }
        })
        $failure = @{ match = @('/UpdateDBCfg', '-Extension Адаптация'); exit = 1; log = 'Ошибка применения первого расширения' }
    }
    $candidate = New-GhCommit -Gh $gh -Parent $original -Changes $changes -Message 'Следующий комплект'
    Set-GhBranch -Gh $gh -Branch 'main' -Sha $candidate
    $result = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitImport -GitUnattended' -Com (New-ComState) -Fake @{ designer = @($failure) }
    Check-Common $result
    Check-Verdict $result 'RED' 1
    if ($null -eq $result.Verdict) { return }
    # С 20.11 (#36) «Загрузить из git» передаёт полный SHA.
    Check ($result.Verdict.kitSource -eq ('git owner/ext@' + $candidate)) ('гейт проверял другой коммит: ' + $result.Verdict.kitSource)
    if ($Processing) {
        Check-Step $result 'Собрать Печать из файлов' 'FAIL'
        Check ((Get-Calls $result @('/LoadExternalDataProcessorOrReportFromFiles')).Count -eq 1) 'конфигуратор не дошёл до сборки EPF'
        Check ((Get-Calls $result @('regepf;')).Count -eq 0) 'после ошибки сборки началась регистрация EPF'
    } else {
        Check-Step $result 'Обновить конфигурацию БД Адаптация' 'FAIL'
        Check-Step $result 'Загрузить Доработки' 'SKIP'
        Check ($result.Verdict.kitDecision -eq 'kept') 'частично загруженный комплект не был оставлен в temp'
        Check ((Get-Calls $result @('/LoadConfigFromFiles', '-Extension Адаптация')).Count -eq 1) 'первое расширение не загружено перед ошибкой'
        Check ((Get-Calls $result @('/LoadConfigFromFiles', '-Extension Доработки')).Count -eq 0) 'второе расширение было загружено'
    }
    Check ((Read-GitStateFile $sb).commit -eq $original) 'Git-импорт пометил неполный комплект установленным'
}

@(
    @{
        Name = 'review-revision-g05-changed-temp'
        Text = 'после зелёного прогона меняется хеш одного расширения в temp: прежний прогон не разрешает подготовку нового состава'
        Run = {
            param($Name)
            $source = New-Sandbox ($Name + '-gate')
            $kit = Add-InboxFile $source $cfeName
            $tested = New-ComState -TempHash 'checked'
            $extensions = @($tested.bases.erp_temp_test.extensions | ForEach-Object { '{0}|{1}|active|{2}' -f $_.name, $_.version, $_.hash })
            $initial = Invoke-Script -Sandbox $source -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $kit) -Fake @{ selfcheck = @(@{ ext = $extensions }, @{ ext = $extensions; fingerprint = 'после загрузки' }) }
            Check-Common $initial
            Check-Verdict $initial 'GREEN' 0
            if (-not $initial.RunDir) { return }
            $archive = Join-Path $initial.RunDir 'selfcheck-after\try1\info.txt'
            Check ((Get-Content -LiteralPath $archive -Encoding UTF8) -contains ('ext=' + $extensions[0])) 'в архиве отсутствует исходный хеш проверенного расширения'
            $profile = $deployConfig.Clone()
            $profile['RunsDir'] = Join-Path $source 'runs'
            $choice = @{ Kind = 'one'; Header = 'Подготовка обновления'; Item = '^Подготовить все' }

            # Контроль: те же база, состав, серверный профиль и ответы. Меняется только хеш Адаптации.
            foreach ($changed in @($false, $true)) {
                $sb = New-Sandbox ("{0}-{1}" -f $Name, $changed) -Config $profile
                $actual = New-ComState -TempHash 'checked'
                if ($changed) { $actual.bases.erp_temp_test.extensions[0].hash = 'changed' }
                $answers = @($choice, $deployNameAnswer)
                if ($changed) { $answers += @{ Kind = 'confirm'; Yes = $false } }
                $result = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Prepare' -Com $actual -Answers $answers
                Check (-not $result.TimedOut -and $result.Unexpected.Count -eq 0 -and -not $result.Stderr) 'подготовка завершилась с ошибкой интерфейса'
                $loads = Get-Calls $result @('/LoadCfg', '-Extension Адаптация', 'fake\erp_base')
                if ($changed) {
                    Check ($loads.Count -eq 0) 'после смены хеша прежний GREEN пропустил запись без согласия на непроверенную поставку'
                    Check (-not (Test-Path -LiteralPath (Join-Path $sb 'deploy\prepared.json'))) 'создан манифест подготовки для непроверенного состава'
                } else {
                    Check ($result.ExitCode -eq 0 -and $loads.Count -eq 1) 'контрольный комплект с прежним хешем не прошёл подготовку'
                    $prepared = Get-Content -LiteralPath (Join-Path $sb 'deploy\prepared.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                    Check ($prepared.gate -eq $initial.Verdict.runId) 'контрольная подготовка ссылается на другой прогон'
                }
            }
        }
    },
    @{
        Name = 'review-revision-g07-two-extensions'
        Text = 'Git-импорт: при отказе UpdateDBCfg первого расширения второе пропущено, прежний установленный SHA сохраняется'
        Run = { param($Name) Invoke-RevisionPartialImport -Name $Name }
    },
    @{
        Name = 'review-revision-g07-epf-build'
        Text = 'Git-импорт: единственная EPF не собралась, прежний установленный SHA сохраняется'
        Run = { param($Name) Invoke-RevisionPartialImport -Name $Name -Processing }
    },
    @{
        Name = 'review-revision-g11-typical-version'
        Text = 'возобновление после смены версии типовой при прежних расширениях заново вызывает CheckConfig'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $kit = Add-InboxFile $sb $cfeName
            $first = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $kit) -Fake @{ selfcheck = @(@{}, @{ tasks = $errorTasks; fingerprint = 'предыдущая версия' }) }
            Check-Common $first
            Check-Verdict $first 'RED' 1
            Check-Step $first 'Проверка конфигурации' 'OK'
            if (-not $first.RunDir) { return }
            # Подставная 1С всегда пишет один config=. Архивируем прежнюю версию в том же формате.
            $previous = Join-Path $first.RunDir 'selfcheck-after\try1\info.txt'
            $saved = [System.IO.File]::ReadAllLines($previous, $utf8)
            $currentConfig = @($saved | Where-Object { $_.StartsWith('config=') })
            if ($currentConfig.Count -ne 1) { throw 'в архиве самопроверки нет однозначной версии типовой' }
            $oldConfig = 'config=УправлениеПредприятием 2.4'
            if ($currentConfig[0] -eq $oldConfig) { throw 'версии типовой в сценарии совпали' }
            $oldLines = @(foreach ($line in $saved) { if ($line -eq $currentConfig[0]) { $oldConfig } else { $line } })
            [System.IO.File]::WriteAllLines($previous, [string[]]$oldLines, $utf8Bom)
            Reset-FakeState $sb
            $r = Invoke-Script -Sandbox $sb -Arguments '-Resume last' -Fake @{ selfcheck = @(@{ fingerprint = 'новая версия' }, @{ fingerprint = 'после повторной проверки' }) } -Answers @(
                @{ Kind = 'one'; Header = 'База изменилась после прогона'; Item = '^Продолжить с «Проверки конфигуратором»' })
            # Реализация может начать с проверок автоматически. В этом случае ответ останется неиспользованным.
            Check (-not $r.TimedOut -and $r.Unexpected.Count -eq 0 -and -not $r.Stderr) 'продолжение не завершилось штатно'
            Check-Verdict $r 'GREEN' 0
            $probeFile = Join-Path $r.RunDir 'resume-check\info.txt'
            if (-not (Test-Path -LiteralPath $probeFile)) {
                Check $false ('нет сеанса проверки базы; конец вывода: ' + ((@($r.Output) | Select-Object -Last 12) -join ' | '))
                return
            }
            $probe = Get-Content -LiteralPath $probeFile -Encoding UTF8
            Check ($probe -contains $currentConfig[0]) 'проверка базы не увидела новую версию типовой'
            $oldExt = @($oldLines | Where-Object { $_.StartsWith('ext=') } | Sort-Object)
            $newExt = @($probe | Where-Object { $_.StartsWith('ext=') } | Sort-Object)
            Check ($oldExt.Count -gt 0 -and ($oldExt -join '|') -eq ($newExt -join '|')) 'в сценарии изменились расширения'
            Check ((Get-Calls $r @('/CheckConfig')).Count -eq 1) 'с новой версией типовой CheckConfig не запущен'
            $step = Get-Step $r 'Проверка конфигурации'
            Check ($null -ne $step -and -not $step.from -and $step.status -eq 'OK') 'при смене типовой переиспользован старый шаг'
        }
    }
)
