#requires -Version 5.1

function New-EvidenceDocumentDump {
    param([string[]]$Names)
    $dump = @{}
    foreach ($name in $Names) {
        $dump["Documents/$name.xml"] = New-AdoptedDocument $name
        $dump["Documents/$name/Ext/ObjectModule.bsl"] = $coverageDumpFirst['Documents/ЗаказКлиента/Ext/ObjectModule.bsl']
    }
    return $dump
}

function Set-EvidenceCoverageReference {
    param([string]$Sandbox, [string]$Key)
    $config = Import-PowerShellDataFile -LiteralPath (Join-Path $Sandbox 'config.psd1')
    $dir = Join-Path (Join-Path $Sandbox 'baseline') (Split-Path -Leaf $config.File)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'coverage.txt'), ("covered`t{0}`tконтроль прошлого прогона`r`n" -f $Key), $utf8Bom)
}

function Check-EvidenceCoverage {
    param([string]$Dir, [string]$Key, [bool]$Covered)
    $path = Join-Path $Dir 'coverage.txt'
    $rows = @([System.IO.File]::ReadAllLines($path, $utf8) | ForEach-Object {
            $fields = $_ -split "`t", 3
            if ($fields.Count -eq 3 -and $fields[1] -ceq $Key) { $fields[0] }
        })
    Check ($rows.Count -eq 1) ("в карте ожидалась одна строка для {0}, найдено {1}" -f $Key, $rows.Count)
    if ($rows.Count -eq 1) {
        if ($Covered) { Check ($rows[0] -eq 'covered') ("выполнение {0} подтверждено, в карте {1}" -f $Key, $rows[0]) }
        else { Check ($rows[0] -and $rows[0] -ne 'covered') ("{0} получил покрытие без исполнения" -f $Key) }
    }
}

function New-UnreadableCanaryResult {
    # fake1c пишет значение status сразу после «status=». Передаём две строки штатного формата EPF.
    return @{ status = "ok`nexterror=Нет доступа к составу расширений" }
}

function Check-UnreadableCanaryResult {
    param([string]$Path)
    $lines = [System.IO.File]::ReadAllLines($Path, $utf8)
    Check (($lines -ccontains 'status=ok') -and ($lines -ccontains 'exterror=Нет доступа к составу расширений')) 'исходный результат канарейки не содержит успешного входа и отдельной ошибки чтения'
}

function Check-UnconfirmedCanary {
    param([string]$Status, [string]$Detail)
    Check ($Status -in @('WARN', 'FAIL')) ("неизвестное применение расширений получило статус {0}" -f $Status)
    Check ($Detail -match 'расширени|состав' -and $Detail -match 'недоступ|не прочит|не удал|не провер|не подтверж|неизвест|нет доступа|ошибк') ("в отчёте не объяснено, почему состав не подтверждён: {0}" -f $Detail)
    Check ($Detail -notmatch '(?:^|[,;:]\s*)расширения применились(?:[.!]|$)') ("отчёт подтвердил применение при ошибке чтения: {0}" -f $Detail)
}

@(
    @{
        Name = 'review-evidence-coverage-skipped-document'
        Text = 'ПРОПУСК печати не подтверждает выполнение перехвата документа и подписки на него'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name
            $key = 'перехват|Адаптация|Документ.ДокументБезДанных|модуль объекта|ОбработкаПроведения'
            Set-EvidenceCoverageReference $sb $key
            $dump = New-EvidenceDocumentDump @('ЗаказКлиента', 'ДокументБезДанных')
            $dump['EventSubscriptions/ПодпискаБезДанных.xml'] = '<MetaDataObject xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"><EventSubscription><Properties><Source><v8:Type>cfg:DocumentObject.ДокументБезДанных</v8:Type></Source><Handler>CommonModule.Проверка.ПриЗаписи</Handler></Properties></EventSubscription></MetaDataObject>'
            $tasks = @($coverageTasks) + @(@{ key = 'ПечатныеФормы|Документ.ДокументБезДанных'; title = 'Печать'; step = 'ПечатныеФормы'; lines = @('[ПРОПУСК] Документ.ДокументБезДанных: нет проведённых документов, печатать нечего.') })
            $fake = @{ selfcheck = @(@{ tasks = $tasks }, @{ tasks = $tasks; fingerprint = 'после' }); dumps = @{ 'Адаптация' = $dump } }
            $kit = Add-InboxFile $sb $cfeName
            $r = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $kit) -Fake $fake
            Check-Common $r
            $records = [System.IO.File]::ReadAllLines((Join-Path $r.RunDir 'selfcheck-after.norm.txt'), $utf8)
            $named = @($records | Where-Object { $_.Contains('Документ.ДокументБезДанных') })
            Check ($named.Count -eq 1 -and $named[0] -match '^\[ПРОПУСК\]') 'для пропущенного документа ожидалась единственная нормализованная запись ПРОПУСК'
            Check-EvidenceCoverage $r.RunDir 'перехват|Адаптация|Документ.ЗаказКлиента|модуль объекта|ОбработкаПроведения' $true
            Check-EvidenceCoverage $r.RunDir $key $false
            Check-Step $r 'Карта покрытия' 'WARN'
            Check-EvidenceCoverage $r.RunDir 'подписка|Адаптация|ПодпискаБезДанных' $false
        }
    },
    @{
        Name = 'review-evidence-coverage-unregistered-test'
        Text = 'из двух указаний @Проверяет покрытие получает цель зарегистрированного и выполненного теста'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config $unitConfig
            $key = 'перехват|Адаптация|Документ.УчебноеВычитание|модуль объекта|ОбработкаПроведения'
            Set-EvidenceCoverageReference $sb $key
            $module = $unitModuleClean -replace '\r?\n[ \t]*\.ДобавитьТест\("Вычитание", "Вычитание"\);', ';'
            $module = $module.Replace('CommonModule.Пример.Сложить', 'Document.УчебноеСложение.ОбработкаПроведения').Replace('CommonModule.Пример.Вычесть', 'Document.УчебноеВычитание.ОбработкаПроведения')
            $null = Add-UnitTestSource (Join-Path $sb 'tests') $module
            $dump = New-EvidenceDocumentDump @('УчебноеСложение', 'УчебноеВычитание')
            $fake = @{ absent = @('Тесты'); unittests = @(@{ cases = @($unitAllOk.cases[0]) }); dumps = @{ 'Адаптация' = $dump } }
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $r
            $catalog = [System.IO.File]::ReadAllText((Join-Path $r.RunDir 'unittests-Тесты.catalog.json'), $utf8) | ConvertFrom-Json
            $skipped = @($catalog.tests | Where-Object { $_.method -eq 'Вычитание' -and $_.checks -eq 'Document.УчебноеВычитание.ОбработкаПроведения' })
            Check ($skipped.Count -eq 1 -and -not $skipped[0].registered -and -not $skipped[0].disabled) 'контроль каталога: описание должно быть найдено без регистрации и без пометки выключения'
            $junit = [xml][System.IO.File]::ReadAllText((Join-Path $r.RunDir 'unittests\junit.xml'), $utf8)
            $cases = @($junit.SelectNodes('//testcase'))
            Check ($cases.Count -eq 1 -and $cases[0].GetAttribute('classname') -eq 'ОМ_Пример.Сложение' -and $null -eq $cases[0].SelectSingleNode('failure|error|skipped')) 'контроль JUnit: должен выполниться только тест Сложение'
            Check-EvidenceCoverage $r.RunDir 'перехват|Адаптация|Документ.УчебноеСложение|модуль объекта|ОбработкаПроведения' $true
            Check-EvidenceCoverage $r.RunDir $key $false
            Check-Step $r 'Карта покрытия' 'WARN'
        }
    },
    @{
        Name = 'review-evidence-canary-temp-unconfirmed'
        Text = 'два успешных входа: подтверждённый состав даёт OK, нечитаемый состав отмечается в вердикте'
        Run = {
            param($Name)
            $sb = New-Sandbox $Name -Config @{ CanaryUsers = @(@{ Name = 'Контроль' }, @{ Name = 'Читатель' }) }
            $fake = @{ canary = @(@{ status = 'ok'; ext = @('Пример|1|active') }, (New-UnreadableCanaryResult)) }
            $r = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
            Check-Common $r
            Check-Step $r 'Канареечный вход: Контроль' 'OK'
            Check-UnreadableCanaryResult (Join-Path $r.RunDir 'canary_2.txt')
            $step = Get-Step $r 'Канареечный вход: Читатель'
            Check ($null -ne $step) 'в вердикте нет второго канареечного входа'
            if ($null -ne $step) { Check-UnconfirmedCanary $step.status $step.detail }
            Check ($null -ne $r.Verdict -and $r.Verdict.verdict -in @('YELLOW', 'RED')) 'весь прогон остался зелёным при неподтверждённом применении'
        }
    },
    @{
        Name = 'review-evidence-canary-deploy-unconfirmed'
        Text = 'в протоколе deploy успешный вход и ошибка чтения состава не подтверждают применение расширений'
        Run = {
            param($Name)
            $config = $deployConfig.Clone()
            $config['DeployKeepTimeoutMin'] = 0
            $sb = New-Sandbox $Name -Config $config
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Com (New-ComState) -Fake @{ canary = @((New-UnreadableCanaryResult)) } -Answers @(
                @{ Kind = 'one'; Header = 'Обновление'; Item = '^Обновить все' }, $deployRiskAnswer, $deployNameAnswer)
            Check-DeployCommon $r
            $record = Get-DeployRecord $sb
            Check ($null -ne $record) 'не сформирован deploy.json'
            if ($null -eq $record) { return }
            Check-UnreadableCanaryResult (Join-Path $record.Dir 'canary.txt')
            $step = @($record.light | Where-Object { $_.name -eq 'Канареечный вход' })
            Check ($step.Count -eq 1) 'в deploy.json ожидался один результат канарейки'
            if ($step.Count -eq 1) { Check-UnconfirmedCanary $step[0].status $step[0].text }
        }
    }
)
