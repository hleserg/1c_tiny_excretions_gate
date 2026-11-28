#requires -Version 5.1
@{
    Name = 'run-error-guidance'
    Text = 'сбой конфигуратора и неполный результат YAxUnit видны в окне, вердикте и разборе, успешный повтор проходит'
    Run = {
        param($Name)
        $sb = New-Sandbox $Name -Config $unitConfig
        $null = Add-UnitTestSource -Dir (Join-Path $sb 'tests')
        $fake = @{
            absent = @('Тесты')
            designer = @(@{ match = @('/CheckConfig'); exit = 17; log = 'Не удалось открыть словарь. Pwd=sample-password;' })
            unittests = @(@{ cases = $unitAllOk.cases; noReport = $true })
        }
        $run = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake $fake
        Check-Common $run
        Check-Verdict $run 'RED' 1
        $check = Get-Step $run 'Проверка конфигурации'
        $unit = Get-Step $run 'Модульные тесты'
        $console = $run.Output -join [Environment]::NewLine
        $reportText = [IO.File]::ReadAllText((Join-Path $run.RunDir 'report.txt'), $utf8)
        Check ($check.status -eq 'FAIL' -and $check.detail -match '17' -and $check.detail -match 'открыть словарь') 'на шаге конфигуратора пропали код и исходное сообщение'
        Check ($check.detail -match 'повтори' -and $console.Contains($check.log)) 'после сбоя конфигуратора оператору не показаны журнал и дальнейшее действие'
        Check ($unit.status -eq 'FAIL' -and $unit.detail -match 'junit\.xml' -and $unit.detail -match 'yaxunit\.log' -and $unit.detail -match 'повтори') 'потеря отчёта YAxUnit не объясняет, как проверить причину и повторить тесты'
        Check (-not $console.Contains('sample-password') -and -not $check.detail.Contains('sample-password') -and -not $reportText.Contains('sample-password')) 'в итоговую диагностику попал пароль из журнала 1С'
        Check ($reportText.Contains('открыть словарь') -and $reportText -match 'yaxunit\.log') 'в разборе потеряна причина или путь к диагностике'
        $green = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep' -Fake @{ absent = @('Тесты'); unittests = @($unitAllOk) }
        Check-Common $green
        Check-Verdict $green 'GREEN' 0
        Check-Step $green 'Модульные тесты' 'OK'
        Check-Step $green 'Проверка конфигурации' 'OK'
    }
}
@{
    Name = 'run-error-guidance-inputs'
    Text = 'до соединения с базой объясняется пустой V8Bin, а неполный протокол действий даёт числа и способ проверки'
    Run = {
        param($Name)
        $sb = New-Sandbox $Name -Config @{ V8Bin = '' }
        $run = Invoke-Script -Sandbox $sb -Arguments '-OnNotGreen Keep'
        $console = $run.Output -join [Environment]::NewLine
        Check ($run.ExitCode -ne 0 -and $run.Calls.Count -eq 0) 'пустой V8Bin должен остановить прогон до первого вызова платформы'
        Check ($console.Contains('V8Bin') -and $console.Contains('config.psd1') -and $console.Contains('1cv8.exe')) 'для пустого V8Bin не названы настройка, файл и ожидаемая программа'
        . (Join-Path $sb 'post-update.ps1')
        $why = ''
        try { Assert-ActionResult -Ids @('Первое', 'Второе') -Lines @('status=ok', 'done-register=ok', 'action=Первое|done') }
        catch { $why = $_.Exception.Message }
        Check ($why.Contains('2') -and $why.Contains('1') -and $why -match 'регистр') 'для неполного ответа обработки нужны ожидаемое и фактическое число действий и способ сверки'
        Assert-ActionResult -Ids @('Первое') -Lines @('status=ok', 'done-register=ok', 'action=Первое|already')
    }
}
@{
    Name = 'run-error-guidance-archived-secrets'
    Text = 'разбор архива маскирует реквизиты из jUnit, TSV и вердикта, сохраняя исходные файлы для сравнения'
    Run = {
        param($Name)
        $sb = New-Sandbox $Name
        $dir = Join-Path $sb 'runs\20260101-010101'
        $unitDir = (New-Item -Path (Join-Path $dir 'unittests') -ItemType Directory -Force).FullName
        $verdictFile = Join-Path $dir 'verdict.json'
        $inputs = @($verdictFile, (Join-Path $dir 'unittests.new.txt'), (Join-Path $unitDir 'junit.xml'))
        $verdict = @{ verdict = 'RED'; steps = @(
            @{name = 'Модульные тесты'; status = 'FAIL'; detail = 'Вход не удался Pwd=example-verdict;'}
            @{name = 'Проверить вход'; status = 'FAIL'; detail = 'Ошибка входа /P"example-cut.one". Проверь подключение.'}
        ) }
        [IO.File]::WriteAllText($verdictFile, ($verdict | ConvertTo-Json -Depth 4), $utf8Bom)
        $xml = '<testsuites><testsuite><testcase classname="ОМ.ИзXML" context="Сервер" name="Вход"><error message="Ошибка XML Pwd=example-xml;"/></testcase></testsuite></testsuites>'
        [IO.File]::WriteAllText($inputs[2], $xml, $utf8Bom)
        $tsv = @("ERROR`tОМ.ИзXML [Сервер]`tОшибка входа", "FAIL`tОМ.ИзTSV [Сервер]`tОшибка TSV /P`"example-tsv`"")
        [IO.File]::WriteAllLines($inputs[1], $tsv, $utf8Bom)
        $before = (Get-FileHash -LiteralPath $inputs).Hash -join ','
        $console = (& (Join-Path $sb 'report.ps1') -RunDir $dir 6>&1 | Out-String)
        $text = [IO.File]::ReadAllText((Join-Path $dir 'report.txt'))
        $export = [IO.File]::ReadAllText((Join-Path $dir 'junit.xml'))
        Check ($text.Contains('Ошибка XML') -and $text.Contains('Ошибка TSV')) 'в разборе потеряны причины из исходных XML и TSV'
        Check (($console + $text + $export) -notmatch 'example-(verdict|xml|tsv|cut)') 'реквизиты соединения из архивных файлов выведены в отчёт, сводку или экспорт'
        Check ($text.Contains('***') -and $export.Contains('***') -and $console.Contains('***')) 'маскировка не дошла до всех форм представления'
        Check (((Get-FileHash -LiteralPath $inputs).Hash -join ',') -ceq $before) 'разбор изменил исходные файлы, которые читает сравнение с эталоном'
    }
}
@{
    Name = 'run-error-guidance-action-timeout'
    Text = 'обработка отметила запуск без итогового файла, вывод предупреждает о частичном выполнении и показывает список для сверки'
    Run = {
        param($Name)
        $sb = New-Sandbox $Name -Config @{ ActionsRegister = 'ВыполненныеДействия'; ActionsTimeoutSec = 2 }
        New-ActionsTemplate $sb
        $kit = New-ActionsKit $sb 'kit' -Cfe -Actions @{
            '20260101-01-проверка' = (New-ActionText 'Проверка' 'Значение = 1;')
        }
        $run = Invoke-Script -Sandbox $sb -Arguments ('-Kit "{0}" -OnNotGreen Keep' -f $kit) -Fake @{ actions = @(@{ noresult = $true }) }
        Check-Common $run
        Check-Verdict $run 'RED' 1
        $step = Get-Step $run 'Действия после обновления'
        Check ($step.status -eq 'FAIL' -and $step.detail -match 'частично' -and $step.detail -match 'регистр') 'пропала отметка о запуске и риске частичного выполнения'
        Check ($step.log -eq (Join-Path $run.RunDir 'actions\params.txt') -and (Test-Path -LiteralPath $step.log)) 'оператору нужен существующий список идентификаторов действий для сверки'
        Check ($step.detail -notmatch 'закрылся сам') 'остановка по таймауту приписана самому клиенту'
    }
}
