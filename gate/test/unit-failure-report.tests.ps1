#requires -Version 5.1
@{
    Name = 'unit-failure-report'
    Text = 'разбор падений по каталогу, jUnit и сохранённой разнице, в том числе без дополнительных файлов'
    Run = {
        param($Name)
        $sb = New-Sandbox $Name
        $dir = Join-Path $sb 'runs\20260101-010101'
        $unitDir = (New-Item -ItemType Directory -Path (Join-Path $dir 'unittests') -Force).FullName
        $verdictFile = Join-Path $dir 'verdict.json'
        $verdict = @{ verdict = 'RED'; steps = @(@{ name = 'Модульные тесты'; status = 'FAIL'; detail = "Проверено тестов: 3.`r`n       Проверка ожидала ошибку «таймаут»." }) }
        [IO.File]::WriteAllText($verdictFile, ($verdict | ConvertTo-Json -Depth 4), $utf8Bom)
        $key = 'ОМ_Проверки.Склад [Сервер]'
        $second = 'ОМ_Проверки.Цена [Клиент] #2'
        $newFile = Join-Path $dir 'unittests.new.txt'
        [IO.File]::WriteAllText($newFile, ("ERROR`t{0}`tОшибка при вызове метода контекста (Записать)" -f $key), $utf8Bom)
        [IO.File]::WriteAllText((Join-Path $dir 'unittests.changed.txt'), ("FAIL`t{0}`tбыло: FAIL Цена равна нулю`tстало: FAIL Цена ниже минимальной" -f $second), $utf8Bom)
        $catalogFile = Join-Path $dir 'unittests-Тесты.catalog.json'
        [IO.File]::WriteAllText($catalogFile, '{"tests":[{"key":"ОМ_Проверки.Склад","presentation":"Склад указан при записи заказа"}]}', $utf8Bom)
        $junitFile = Join-Path $unitDir 'junit.xml'
        $xml = @'
<testsuites><testsuite classname="ОМ_Проверки">
  <testcase classname="ОМ_Проверки.Склад" context="Сервер" name="Проверка склада"><error message="Ошибка при вызове метода контекста (Записать)&#10;по причине:&#10;Склад не заполнен."/></testcase>
  <testcase classname="ОМ_Проверки.Цена" context="Клиент" name="Цена первого товара"/>
  <testcase classname="ОМ_Проверки.Цена" context="Клиент" name="Цена второго товара"><failure message="Цена ниже минимальной"/></testcase>
</testsuite></testsuites>
'@
        [IO.File]::WriteAllText($junitFile, $xml, $utf8Bom)
        & (Join-Path $sb 'report.ps1') -RunDir $dir -Quiet
        $path = Join-Path $dir 'report.txt'
        $text = [IO.File]::ReadAllText($path, $utf8)
        Check ($text.Contains('Проверено тестов: 3') -and -not $text.Contains('Шаг не уложился')) 'чужой разбор таймаута заменил итог модульных тестов'
        Check ($text.Contains('Склад указан при записи заказа') -and -not $text.Contains('Проверка склада')) 'в отчёте ожидалось описание из каталога'
        Check ($text -match '(?m)^\s*Причина: Склад не заполнен\.') 'оператор не видит предметной причины отдельно от служебного вызова'
        Check ($text.Contains($key) -and $text.Contains('Ошибка при вызове метода контекста (Записать)')) 'в разборе потерялся ключ теста или исходная ошибка'
        Check ($text.Contains('Цена второго товара') -and -not $text.Contains('Цена первого товара')) 'повтор теста не сопоставлен с jUnit по полному ключу'
        Check ($text.Contains('Цена равна нулю') -and $text.Contains('Цена ниже минимальной')) 'для известного падения не видно прежнюю и новую причины'

        # Архив прогона с одними TSV и с повреждёнными необязательными файлами.
        foreach ($broken in @($false, $true)) {
            if ($broken) {
                [IO.File]::WriteAllText($catalogFile, '{', $utf8Bom)
                [IO.File]::WriteAllText($junitFile, '<testsuite', $utf8Bom)
            } else {
                Remove-Item -LiteralPath $catalogFile, $junitFile
            }
            & (Join-Path $sb 'report.ps1') -RunDir $dir -Quiet
            $text = [IO.File]::ReadAllText($path, $utf8)
            Check ($text.Contains($key) -and $text.Contains('Цена ниже минимальной') -and -not $text.Contains('Склад указан при записи заказа')) 'старый прогон должен читаться по TSV'
        }
        Remove-Item -LiteralPath $newFile, (Join-Path $dir 'unittests.changed.txt')
        [IO.File]::WriteAllText((Join-Path $dir 'unittests.txt'), "FAIL`tОМ_Проверки.Цена [Клиент]`tЦена равна нулю", $utf8Bom)
        $verdict.steps[0].status = 'OK'
        $verdict.verdict = 'GREEN'
        [IO.File]::WriteAllText($verdictFile, ($verdict | ConvertTo-Json -Depth 4), $utf8Bom)
        & (Join-Path $sb 'report.ps1') -RunDir $dir -Quiet
        $text = [IO.File]::ReadAllText($path, $utf8)
        Check ($text.Contains('известное падение') -and $text.Contains('Цена равна нулю') -and -not $text.Contains('новое падение')) 'в зелёном прогоне пропало известное падение'
    }
}
