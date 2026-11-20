#requires -Version 5.1
# Модульные тесты YAxUnit для гейта: каталог тестов из выгрузки тестового расширения в файлы, проверка
# описаний (шапок), заготовки модулей и тестов, разбор отчёта jUnit и сравнение с эталоном.
# Подключается точкой из run.ps1 и unittests-cli.ps1: . (Join-Path $PSScriptRoot 'unittests.ps1')
# Здесь только функции (имена Ut...) и переменные $script:Ut...: подключение ничего не запускает.
#
# Шапка теста - комментарий прямо над процедурой теста (строки, которые начинаются с «//»):
#   // @Тест <что проверяет тест, одной фразой: это же представление теста в регистрации и отчёте>
#   // @Проверяет <объект и метод: CommonModule.ОбщийСервер.ПлановаяДата, Document.ЗаказКлиента.ОбработкаПроведения>
#   // @Как <как проверяем: данные, вызов, что сравниваем; можно в несколько строк>
#   // @Зачем <зачем тест: какая ошибка была, какое требование, номер ТЗ или письма>
#   // @Автор <Фамилия И.О. ГГГГММДД - кто написал и когда>
#   // @Теги <через запятую, необязательно>
#   // @Выключен <причина, необязательно: тест не запускается, пока строка есть>
#   Процедура ИмяТеста() Экспорт
# Строка без «@» продолжает предыдущее поле. Обязательные поля: @Тест, @Проверяет, @Как, @Зачем, @Автор.

$script:UtFields = @('Тест', 'Проверяет', 'Как', 'Зачем', 'Автор', 'Теги', 'Выключен')
$script:UtRequired = @('Тест', 'Проверяет', 'Как', 'Зачем', 'Автор')
$script:UtProblemText = @{
    noheader     = 'нет шапки-описания над процедурой теста'
    field        = 'в шапке нет поля'
    author       = 'в @Автор нет даты ГГГГММДД'
    notregistered = 'процедура с шапкой @Тест не зарегистрирована в ИсполняемыеСценарии'
    nomethod     = 'в ИсполняемыеСценарии зарегистрирован метод, которого в модуле нет'
    notexport    = 'процедура теста не экспортная: YAxUnit её не вызовет'
    presentation = 'представление в регистрации не совпадает с @Тест'
    noscenarios  = 'в модуле нет процедуры ИсполняемыеСценарии: YAxUnit не найдёт его тесты'
    nosubsystem  = 'модуль не входит ни в одну подсистему тестового расширения'
    nofile       = 'модуль есть в Configuration.xml, а файла модуля нет'
}

function Get-UtText {
    # Текст файла без BOM, переводы строк - LF.
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return $text.TrimStart([char]0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-UtXml {
    param([string]$Path)
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.LoadXml((Get-UtText $Path))
    return $xml
}

function Get-UtFiles {
    # Файлы папки с подпапками: Rel - путь от папки через «/», по именам (не вычитанием строк: Windows отдаёт
    # FullName то в коротком виде 8.3 - RUNNER~1, то в длинном, и длины корня не совпадают), Full - полный путь.
    param([string]$Dir, [string]$Prefix = '')
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force)) {
        $relative = $item.Name
        if ($Prefix) { $relative = $Prefix + '/' + $item.Name }
        if ($item.PSIsContainer) { Get-UtFiles -Dir $item.FullName -Prefix $relative }
        else { [pscustomobject]@{ Rel = $relative; Full = $item.FullName } }
    }
}

function Get-UtDirHash {
    # Хеш содержимого папки выгрузки: пути и тексты файлов, без ConfigDumpInfo.xml (служебный файл выгрузки,
    # в нём версии объектов). Тексты (.xml, .bsl, .txt, .html, .json) - без BOM, с переводами строк LF: выгрузка
    # конфигуратора пишет CRLF, файлы из git бывают с LF. Остальное - как есть.
    # Пустая строка - папки нет или в ней нет Configuration.xml.
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path -LiteralPath (Join-Path $Dir 'Configuration.xml'))) { return '' }
    $byRelative = @{}
    foreach ($file in @(Get-UtFiles $Dir | Where-Object { $_.Rel -ne 'ConfigDumpInfo.xml' })) { $byRelative[$file.Rel] = $file.Full }
    $names = [string[]]@($byRelative.Keys)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    $textKinds = @('.xml', '.bsl', '.txt', '.html', '.htm', '.json', '.md')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $buffer = New-Object System.IO.MemoryStream
    foreach ($name in $names) {
        $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($name + "`n")
        $buffer.Write($nameBytes, 0, $nameBytes.Length)
        $full = $byRelative[$name]
        if ($textKinds -contains [System.IO.Path]::GetExtension($full).ToLowerInvariant()) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-UtText $full))
        }
        else { $bytes = [System.IO.File]::ReadAllBytes($full) }
        $buffer.Write($bytes, 0, $bytes.Length)
        $buffer.WriteByte(0)
    }
    $hash = $sha.ComputeHash($buffer.ToArray())
    $sha.Dispose()
    return (-join @($hash | ForEach-Object { $_.ToString('x2') }))
}

function Remove-UtComment {
    # Строка BSL без комментария «//»: «//» внутри строкового литерала (в кавычках) комментарием не считается.
    param([string]$Line)
    $inString = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $char = $Line[$i]
        if ($char -eq '"') { $inString = -not $inString; continue }
        if (-not $inString -and $char -eq '/' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '/') { return $Line.Substring(0, $i) }
    }
    return $Line
}

function ConvertFrom-UtHeader {
    # Строки комментария над процедурой -> поля шапки (ordered: имя поля -> текст). Строки без поля в начале
    # (до первого «@») - поле «Описание».
    param([string[]]$Lines)
    $fields = [ordered]@{}
    $current = ''
    foreach ($raw in $Lines) {
        $line = $raw.Trim()
        if ($line.StartsWith('//')) { $line = $line.Substring(2) }
        if ($line.StartsWith(' ')) { $line = $line.Substring(1) }
        $line = $line.TrimEnd()
        $found = [regex]::Match($line, '^@([\w]+)\s*(.*)$')
        if ($found.Success) {
            $name = $found.Groups[1].Value
            foreach ($known in $script:UtFields) { if ($known -ieq $name) { $name = $known } }
            $current = $name
            $value = $found.Groups[2].Value.Trim()
            if ($fields.Contains($name)) { $fields[$name] = ($fields[$name] + "`n" + $value).Trim() } else { $fields[$name] = $value }
            continue
        }
        if (-not $current) { $current = 'Описание'; if (-not $fields.Contains($current)) { $fields[$current] = '' } }
        if ($line.Length -eq 0) { continue }
        if ($fields[$current]) { $fields[$current] = $fields[$current] + "`n" + $line.Trim() } else { $fields[$current] = $line.Trim() }
    }
    return $fields
}

function Get-UtMethods {
    # Процедуры и функции модуля: имя, экспорт, номер строки (с 1) и строки комментария прямо над ней.
    param([string[]]$Lines)
    $methods = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $Lines.Length; $index++) {
        $found = [regex]::Match($Lines[$index], '^\s*(Процедура|Функция)\s+([\w]+)\s*\(([^)]*)\)\s*(Экспорт)?', 'IgnoreCase')
        if (-not $found.Success) { continue }
        $comment = New-Object System.Collections.Generic.List[string]
        $up = $index - 1
        while ($up -ge 0 -and $Lines[$up].Trim().StartsWith('//')) { $comment.Insert(0, $Lines[$up]); $up-- }
        # Конец процедуры - для текста ИсполняемыеСценарии.
        $end = $index
        while ($end + 1 -lt $Lines.Length -and -not ($Lines[$end] -match '^\s*Конец(Процедуры|Функции)\b')) { $end++ }
        $methods.Add([pscustomobject]@{
                Name = $found.Groups[2].Value; Export = $found.Groups[4].Success; Line = $index + 1
                Comment = $comment.ToArray(); BodyFrom = $index; BodyTo = $end
            })
    }
    return , $methods.ToArray()
}

function Get-UtRegistrations {
    # Регистрации тестов в ИсполняемыеСценарии: ДобавитьТест, ДобавитьСерверныйТест, ДобавитьКлиентскийТест
    # с литералами имени, представления и тегов, и цепочки .Представление("...") и .Теги/.Тег("...") после них.
    # Регистрации с переменными вместо литералов не разбираются (их видно как «зарегистрирован неизвестно что»).
    param([string[]]$BodyLines)
    $text = (@($BodyLines | ForEach-Object { Remove-UtComment $_ }) -join ' ')
    $calls = [regex]::Matches($text, '\.\s*(ДобавитьТест|ДобавитьСерверныйТест|ДобавитьКлиентскийТест|ДобавитьТестовыйНабор)\s*\(', 'IgnoreCase')
    $result = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $calls.Count; $i++) {
        $call = $calls[$i]
        $start = $call.Index + $call.Length
        $stop = $text.Length
        if ($i + 1 -lt $calls.Count) { $stop = $calls[$i + 1].Index }
        $chunk = $text.Substring($start, $stop - $start)
        if ($call.Groups[1].Value -ieq 'ДобавитьТестовыйНабор') { continue }
        $literals = [regex]::Matches($chunk, '^\s*"((?:[^"]|"")*)"(?:\s*,\s*"((?:[^"]|"")*)")?(?:\s*,\s*"((?:[^"]|"")*)")?')
        $name = ''; $presentation = ''; $tags = ''
        if ($literals.Count -gt 0) {
            $name = $literals[0].Groups[1].Value.Replace('""', '"')
            if ($literals[0].Groups[2].Success) { $presentation = $literals[0].Groups[2].Value.Replace('""', '"') }
            if ($literals[0].Groups[3].Success) { $tags = $literals[0].Groups[3].Value.Replace('""', '"') }
        }
        $chained = [regex]::Match($chunk, '\.\s*Представление\s*\(\s*"((?:[^"]|"")*)"', 'IgnoreCase')
        if ($chained.Success) { $presentation = $chained.Groups[1].Value.Replace('""', '"') }
        foreach ($tag in [regex]::Matches($chunk, '\.\s*Теги?\s*\(\s*"((?:[^"]|"")*)"', 'IgnoreCase')) {
            if ($tags) { $tags += ', ' }
            $tags += $tag.Groups[1].Value.Replace('""', '"')
        }
        $result.Add([pscustomobject]@{ Name = $name; Presentation = $presentation; Tags = $tags; Kind = $call.Groups[1].Value })
    }
    return , $result.ToArray()
}

function Get-UtSubsystemMap {
    # Модуль -> подсистема (путь «Родитель/Дочерняя»; синоним, если есть). Подсистемы ищутся во всех Subsystems\ выгрузки.
    param([string]$Dir)
    $map = @{}
    $root = Join-Path $Dir 'Subsystems'
    if (-not (Test-Path -LiteralPath $root)) { return $map }
    foreach ($file in @(Get-UtFiles $root | Where-Object { $_.Rel -like '*.xml' })) {
        # Subsystems\А.xml -> А; Subsystems\А\Subsystems\Б.xml -> А/Б. Ext\CommandInterface.xml - не подсистема.
        $parts = @($file.Rel.Split('/') | Where-Object { $_ -and $_ -ne 'Subsystems' })
        if ($parts -contains 'Ext') { continue }
        $path = (@($parts | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) }) -join '/')
        try { $xml = Get-UtXml $file.Full } catch { continue }
        $synonym = ''
        $content = @()
        foreach ($node in @($xml.GetElementsByTagName('Content'))) {
            foreach ($item in @($node.ChildNodes)) { if ($item.NodeType -eq 'Element') { $content += ([string]$item.InnerText).Trim() } }
        }
        foreach ($node in @($xml.GetElementsByTagName('Synonym'))) {
            foreach ($text in @($node.GetElementsByTagName('v8:content'))) { if (-not $synonym) { $synonym = ([string]$text.InnerText).Trim() } }
            break
        }
        foreach ($ref in $content) {
            if ($ref -match '^CommonModule\.(.+)$') {
                $module = $Matches[1]
                if (-not $map.ContainsKey($module)) { $map[$module] = [pscustomobject]@{ Path = $path; Synonym = $synonym } }
            }
        }
    }
    return $map
}

function Get-UtCatalog {
    # Каталог тестов выгрузки тестового расширения: модули, тесты, шапки, замечания.
    # Тест - зарегистрированный метод или процедура с шапкой @Тест. Key - «Модуль.Метод» (как classname в jUnit).
    param([string]$Dir, [string]$Extension = '')
    $modules = New-Object System.Collections.Generic.List[object]
    $tests = New-Object System.Collections.Generic.List[object]
    $problems = New-Object System.Collections.Generic.List[object]
    $configFile = Join-Path $Dir 'Configuration.xml'
    if (-not (Test-Path -LiteralPath $configFile)) {
        return [pscustomobject]@{ Extension = $Extension; Dir = $Dir; Ok = $false; Error = 'нет Configuration.xml'; Modules = @(); Tests = @(); Problems = @() }
    }
    $config = Get-UtXml $configFile
    if (-not $Extension) {
        foreach ($node in @($config.GetElementsByTagName('Name'))) { $Extension = ([string]$node.InnerText).Trim(); break }
    }
    $names = @()
    foreach ($node in @($config.GetElementsByTagName('CommonModule'))) {
        # В Configuration.xml в ChildObjects - <CommonModule>Имя</CommonModule>; в файлах модулей это корневой элемент с uuid.
        if ($node.ParentNode -and $node.ParentNode.LocalName -eq 'ChildObjects') { $names += ([string]$node.InnerText).Trim() }
    }
    $subsystems = Get-UtSubsystemMap $Dir
    foreach ($name in $names) {
        $moduleFile = Join-Path $Dir ("CommonModules\{0}\Ext\Module.bsl" -f $name)
        $subsystem = ''
        $subsystemName = ''
        if ($subsystems.ContainsKey($name)) { $subsystem = $subsystems[$name].Path; $subsystemName = $subsystems[$name].Synonym }
        $relative = ("CommonModules/{0}/Ext/Module.bsl" -f $name)
        if (-not (Test-Path -LiteralPath $moduleFile)) {
            $problems.Add([pscustomobject]@{ Kind = 'nofile'; Module = $name; Method = ''; Line = 0; Text = $script:UtProblemText['nofile'] })
            continue
        }
        $lines = @((Get-UtText $moduleFile).Split("`n"))
        $methods = Get-UtMethods $lines
        $byName = @{}
        foreach ($method in $methods) { $byName[$method.Name.ToLowerInvariant()] = $method }
        $scenarios = $null
        if ($byName.ContainsKey('исполняемыесценарии')) { $scenarios = $byName['исполняемыесценарии'] }
        $registered = @()
        if ($null -ne $scenarios) { $registered = Get-UtRegistrations ($lines[$scenarios.BodyFrom..$scenarios.BodyTo]) }
        $moduleTests = New-Object System.Collections.Generic.List[object]
        if ($null -eq $scenarios) {
            # Модуль без ИсполняемыеСценарии - не тестовый (служебный общий модуль тестов): замечание, только если в нём есть шапки @Тест.
            $withHeader = @($methods | Where-Object { (ConvertFrom-UtHeader $_.Comment).Contains('Тест') })
            if ($withHeader.Count -gt 0) {
                $problems.Add([pscustomobject]@{ Kind = 'noscenarios'; Module = $name; Method = ''; Line = 0; Text = $script:UtProblemText['noscenarios'] })
            }
            else {
                $modules.Add([pscustomobject]@{ Name = $name; Subsystem = $subsystem; SubsystemName = $subsystemName; File = $relative; Tests = 0; Helper = $true })
                continue
            }
        }
        if (-not $subsystem) { $problems.Add([pscustomobject]@{ Kind = 'nosubsystem'; Module = $name; Method = ''; Line = 0; Text = $script:UtProblemText['nosubsystem'] }) }
        $seen = @{}
        foreach ($registration in $registered) {
            if (-not $registration.Name) { continue }
            $key = $registration.Name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $method = $null
            if ($byName.ContainsKey($key)) { $method = $byName[$key] }
            $header = [ordered]@{}
            $line = 0
            $methodName = $registration.Name
            if ($null -ne $method) { $header = ConvertFrom-UtHeader $method.Comment; $line = $method.Line; $methodName = $method.Name }
            $moduleTests.Add([pscustomobject]@{ Method = $methodName; Registration = $registration; MethodInfo = $method; Header = $header; Line = $line })
        }
        # Процедуры с шапкой @Тест без регистрации - тоже тесты (их YAxUnit не запустит - замечание).
        foreach ($method in $methods) {
            if ($seen.ContainsKey($method.Name.ToLowerInvariant())) { continue }
            $header = ConvertFrom-UtHeader $method.Comment
            if (-not $header.Contains('Тест')) { continue }
            $moduleTests.Add([pscustomobject]@{ Method = $method.Name; Registration = $null; MethodInfo = $method; Header = $header; Line = $method.Line })
        }
        foreach ($item in $moduleTests) {
            $header = $item.Header
            $itemProblems = New-Object System.Collections.Generic.List[string]
            $add = {
                param([string]$Kind, [string]$Extra)
                $text = $script:UtProblemText[$Kind]
                if ($Extra) { $text = $text + ' ' + $Extra }
                $problems.Add([pscustomobject]@{ Kind = $Kind; Module = $name; Method = $item.Method; Line = $item.Line; Text = $text })
                $itemProblems.Add($text)
            }
            if ($null -eq $item.MethodInfo) { & $add 'nomethod' '' }
            else {
                if (-not $item.MethodInfo.Export) { & $add 'notexport' '' }
                if (-not $header.Contains('Тест')) { & $add 'noheader' '' }
                else {
                    foreach ($field in $script:UtRequired) {
                        if (-not $header.Contains($field) -or -not ([string]$header[$field]).Trim()) { & $add 'field' ('@' + $field) }
                    }
                    if ($header.Contains('Автор') -and ([string]$header['Автор']) -notmatch '\b\d{8}\b') { & $add 'author' '' }
                }
            }
            if ($null -eq $item.Registration) { & $add 'notregistered' '' }
            elseif ($header.Contains('Тест') -and ([string]$header['Тест']).Trim() -and $item.Registration.Presentation.Trim() -ne ([string]$header['Тест']).Trim()) {
                $shown = $item.Registration.Presentation
                if (-not $shown) { $shown = 'представления нет, в отчёте будет имя метода' }
                & $add 'presentation' ('(' + $shown + ')')
            }
            $presentation = ''
            if ($header.Contains('Тест')) { $presentation = ([string]$header['Тест']).Trim() }
            if (-not $presentation -and $null -ne $item.Registration) { $presentation = $item.Registration.Presentation }
            if (-not $presentation) { $presentation = $item.Method }
            $tags = @()
            $tagText = ''
            if ($header.Contains('Теги')) { $tagText = [string]$header['Теги'] }
            if ($null -ne $item.Registration -and $item.Registration.Tags) { $tagText = $tagText + ',' + $item.Registration.Tags }
            foreach ($tag in $tagText.Split(',')) { $clean = $tag.Trim(); if ($clean -and $tags -notcontains $clean) { $tags += $clean } }
            $disabled = ''
            if ($header.Contains('Выключен')) { $disabled = ([string]$header['Выключен']).Trim(); if (-not $disabled) { $disabled = 'причина не указана' } }
            $fieldValue = {
                param([string]$Field)
                if ($header.Contains($Field)) { return ([string]$header[$Field]).Trim() }
                return ''
            }
            $tests.Add([pscustomobject]@{
                    Key = ('{0}.{1}' -f $name, $item.Method); Module = $name; Method = $item.Method; Line = $item.Line; File = $relative
                    Subsystem = $subsystem; SubsystemName = $subsystemName; Presentation = $presentation; Tags = $tags
                    Checks = (& $fieldValue 'Проверяет'); How = (& $fieldValue 'Как'); Why = (& $fieldValue 'Зачем'); Author = (& $fieldValue 'Автор')
                    Description = (& $fieldValue 'Описание'); Disabled = $disabled; Registered = ($null -ne $item.Registration)
                    Problems = $itemProblems.ToArray()
                })
        }
        $modules.Add([pscustomobject]@{ Name = $name; Subsystem = $subsystem; SubsystemName = $subsystemName; File = $relative; Tests = $moduleTests.Count; Helper = $false })
    }
    return [pscustomobject]@{
        Extension = $Extension; Dir = $Dir; Ok = $true; Error = ''
        Modules = $modules.ToArray(); Tests = $tests.ToArray(); Problems = $problems.ToArray()
    }
}

function Format-UtProblem {
    param($Problem)
    $where = $Problem.Module
    if ($Problem.Method) { $where = '{0}.{1}' -f $Problem.Module, $Problem.Method }
    if ($Problem.Line -gt 0) { $where = '{0} (строка {1})' -f $where, $Problem.Line }
    return ('{0}: {1}' -f $where, $Problem.Text)
}

function Write-UtCatalog {
    # Каталог в папку: tests.json (для ci.exe и вики) и catalog.txt (читать глазами).
    param($Catalog, [string]$Dir, [string]$Prefix = 'unittests')
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $data = [ordered]@{
        extension = $Catalog.Extension
        tests = @($Catalog.Tests | ForEach-Object {
                [ordered]@{ key = $_.Key; module = $_.Module; method = $_.Method; line = $_.Line; file = $_.File; subsystem = $_.Subsystem
                    subsystemName = $_.SubsystemName; presentation = $_.Presentation; tags = @($_.Tags); checks = $_.Checks; how = $_.How; why = $_.Why
                    author = $_.Author; disabled = $_.Disabled; registered = $_.Registered; problems = @($_.Problems) }
            })
        problems = @($Catalog.Problems | ForEach-Object { Format-UtProblem $_ })
    }
    [System.IO.File]::WriteAllText((Join-Path $Dir ($Prefix + '.catalog.json')), (ConvertTo-Json -InputObject $data -Depth 6), $utf8Bom)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('Тесты {0}: {1}, модулей {2}, замечаний к описаниям {3}' -f $Catalog.Extension, @($Catalog.Tests).Count, @($Catalog.Modules | Where-Object { -not $_.Helper }).Count, @($Catalog.Problems).Count))
    foreach ($group in @($Catalog.Tests | Group-Object { $_.Subsystem } | Sort-Object Name)) {
        $lines.Add('')
        $title = $group.Name
        if (-not $title) { $title = '(без подсистемы)' }
        $lines.Add($title)
        foreach ($test in @($group.Group | Sort-Object Key)) {
            $mark = ''
            if ($test.Disabled) { $mark = ' [выключен: ' + $test.Disabled + ']' }
            $lines.Add(('  {0} - {1}{2}' -f $test.Key, $test.Presentation, $mark))
            if ($test.Checks) { $lines.Add(('      проверяет: {0}' -f ($test.Checks -replace "`n", ' '))) }
            if ($test.Author) { $lines.Add(('      автор: {0}' -f $test.Author)) }
            foreach ($problem in @($test.Problems)) { $lines.Add(('      ! {0}' -f $problem)) }
        }
    }
    $moduleProblems = @($Catalog.Problems | Where-Object { -not $_.Method })
    if ($moduleProblems.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Замечания к модулям:')
        foreach ($problem in $moduleProblems) { $lines.Add('  ' + (Format-UtProblem $problem)) }
    }
    [System.IO.File]::WriteAllLines((Join-Path $Dir ($Prefix + '.catalog.txt')), [string[]]$lines.ToArray(), $utf8Bom)
}

function Read-UtJUnit {
    # Отчёт jUnit YAxUnit -> результаты: Key «Модуль.Метод [контекст]» (повтор с параметрами - «#2», «#3»),
    # Status OK | FAIL (упал на проверке) | ERROR (сломался: исключение, модуль не загрузился) | SKIP, Message, Seconds.
    param([string]$Path)
    $results = New-Object System.Collections.Generic.List[object]
    $xml = New-Object System.Xml.XmlDocument
    $xml.LoadXml((Get-UtText $Path))
    $counts = @{}
    foreach ($suite in @($xml.GetElementsByTagName('testsuite'))) {
        $module = [string]$suite.GetAttribute('classname')
        $context = [string]$suite.GetAttribute('context')
        foreach ($child in @($suite.ChildNodes)) {
            if ($child.NodeType -ne 'Element') { continue }
            if ($child.LocalName -eq 'error') {
                # Ошибка набора: модуль не загрузился, ИсполняемыеСценарии упал, обработчик события набора.
                $message = [string]$child.GetAttribute('message')
                if (-not $message) { $message = ([string]$child.InnerText).Trim() }
                $results.Add([pscustomobject]@{ Key = ('{0} [{1}] набор' -f $module, $context); Module = $module; Method = ''; Context = $context
                        Name = [string]$suite.GetAttribute('name'); Status = 'ERROR'; Message = $message; Seconds = 0.0 })
                continue
            }
            if ($child.LocalName -ne 'testcase') { continue }
            $classname = [string]$child.GetAttribute('classname')
            $caseContext = [string]$child.GetAttribute('context')
            if (-not $caseContext) { $caseContext = $context }
            $baseKey = '{0} [{1}]' -f $classname, $caseContext
            $n = 1
            if ($counts.ContainsKey($baseKey)) { $n = $counts[$baseKey] + 1 }
            $counts[$baseKey] = $n
            $key = $baseKey
            if ($n -gt 1) { $key = '{0} #{1}' -f $baseKey, $n }
            $status = 'OK'
            $messages = New-Object System.Collections.Generic.List[string]
            foreach ($result in @($child.ChildNodes)) {
                if ($result.NodeType -ne 'Element') { continue }
                $kind = $result.LocalName
                if (@('failure', 'error', 'skipped') -notcontains $kind) { continue }
                $text = [string]$result.GetAttribute('message')
                if ($text) { $messages.Add($text.Trim()) }
                if ($kind -eq 'error') { $status = 'ERROR' }
                elseif ($kind -eq 'failure' -and $status -ne 'ERROR') { $status = 'FAIL' }
                elseif ($kind -eq 'skipped' -and $status -eq 'OK') { $status = 'SKIP' }
            }
            $seconds = 0.0
            [void][double]::TryParse([string]$child.GetAttribute('time'), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)
            $method = $classname
            if ($classname.Contains('.')) { $method = $classname.Substring($classname.IndexOf('.') + 1) }
            $results.Add([pscustomobject]@{ Key = $key; Module = $module; Method = $method; Context = $caseContext; Name = [string]$child.GetAttribute('name')
                    Status = $status; Message = ($messages.ToArray() -join ' | '); Seconds = $seconds })
        }
    }
    return , $results.ToArray()
}

function Test-UtFailed {
    param([string]$Status)
    return ($Status -eq 'FAIL' -or $Status -eq 'ERROR')
}

function Format-UtResultLine {
    # Строка файла результатов и эталона: «СТАТУС<tab>ключ<tab>сообщение» (сообщение - для человека, в сравнение не идёт).
    param($Result)
    $message = ([string]$Result.Message) -replace '\s+', ' '
    if ($message.Length -gt 400) { $message = $message.Substring(0, 400) + '...' }
    return ("{0}`t{1}`t{2}" -f $Result.Status, $Result.Key, $message)
}

function Read-UtResultFile {
    # Файл результатов (эталон) -> ключ -> статус. $null - файла нет.
    param([string]$Path)
    $full = Read-UtResultRecords $Path
    if ($null -eq $full) { return $null }
    $map = @{}
    foreach ($key in @($full.Keys)) { $map[$key] = $full[$key].Status }
    return $map
}

# ** Хлебников С.Ю. 20261120 Эталон тестов целиком (статус, сообщение, исходная строка) и причина падения для
# сравнения: вид (FAIL/ERROR) и текст, где закрыто только то, что меняется само (номер строки, GUID, ссылка,
# дата, время, путь, длительность). Остальные числа - коды ошибок, счётчики - сравниваются как есть.
function Read-UtResultRecords {
    # Файл результатов -> ключ -> @{ Status; Message; HasMessage; Line }. $null - файла нет.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $map = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $clean = ([string]$line).TrimStart([char]0xFEFF)
        if (-not $clean) { continue }
        $parts = $clean.Split("`t")
        if ($parts.Length -lt 2) { continue }
        $message = ''
        if ($parts.Length -ge 3) { $message = ($parts[2..($parts.Length - 1)] -join "`t") }
        $map[$parts[1]] = [pscustomobject]@{ Status = $parts[0]; Message = $message; HasMessage = ($parts.Length -ge 3); Line = $clean }
    }
    return $map
}

function ConvertTo-UtReasonKey {
    # Причина падения для сравнения: «СТАТУС|текст с закрытыми изменчивыми фрагментами».
    param([string]$Status, [string]$Message)
    # Обрезка - как в Format-UtResultLine: в эталоне сообщение уже обрезано до 400 знаков.
    $text = ([string]$Message) -replace '\s+', ' '
    if ($text.Length -gt 400) { $text = $text.Substring(0, 400) + '...' }
    $text = $text -replace '\{[^{}]*\(\d+(?:,\s*\d+)?\)\}', '{#}'
    $text = $text -replace '(?i)(строк[аеиу]?|line)\s*:?\s*\d+', '$1 #'
    $text = $text -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<guid>'
    $text = $text -replace 'e1cib/\S+', '<ссылка>'
    $text = $text -replace '\b\d{4}-\d{2}-\d{2}(?:[T ]\d{1,2}:\d{2}(?::\d{2}(?:\.\d+)?)?)?', '<дата>'
    $text = $text -replace '\b\d{1,2}\.\d{1,2}\.\d{2,4}(?: \d{1,2}:\d{2}(?::\d{2})?)?', '<дата>'
    $text = $text -replace '\b\d{1,2}:\d{2}:\d{2}\b', '<время>'
    $text = $text -replace '(?:[A-Za-z]:\\|\\\\)[^\s"''«»|]+', '<путь>'
    $text = $text -replace '(?i)\b\d+(?:[.,]\d+)?\s*(?:мс|ms|сек|с|s)\b', '<длит>'
    return ('{0}|{1}' -f $Status, $text.Trim())
}

function Get-UtStatusTitle {
    # Подпись вида падения - буквально, без догадок о стадии теста.
    param([string]$Status)
    if ($Status -eq 'ERROR') { return 'ERROR - ошибка выполнения' }
    if ($Status -eq 'FAIL') { return 'FAIL - не прошло утверждение' }
    return $Status
}

function Merge-UtBaseline {
    # Эталон после прогона без полного принятия: из прогона берутся только OK (и новые OK), у FAIL, ERROR, SKIP
    # и пропавших остаётся прежняя запись эталона, новое падение не заносится. Строки - для файла эталона.
    param([object[]]$Current, [string]$BaselineFile)
    $baseline = Read-UtResultRecords $BaselineFile
    if ($null -eq $baseline) { $baseline = @{} }
    $lines = New-Object System.Collections.Generic.List[string]
    $done = @{}
    foreach ($result in $Current) {
        $key = [string]$result.Key
        if ($done.ContainsKey($key)) { continue }
        $done[$key] = $true
        if ($result.Status -eq 'OK') { $lines.Add((Format-UtResultLine $result)) }
        elseif ($baseline.ContainsKey($key)) { $lines.Add([string]$baseline[$key].Line) }
    }
    foreach ($key in @($baseline.Keys | Sort-Object)) {
        if (-not $done.ContainsKey($key)) { $lines.Add([string]$baseline[$key].Line) }
    }
    return , $lines.ToArray()
}
# ** Хлебников С.Ю. 20261120 конец

function Compare-UtResults {
    # Результаты прогона против эталона. Новое падение - тест падает, а в эталоне он проходил, пропускался или его не было.
    # ** Хлебников С.Ю. 20261120 ReasonChanged - известный тест падает по-другому (вид или текст причины, см.
    # ConvertTo-UtReasonKey); ReasonUnknown - у записи эталона нет сообщения, сравнить причину нельзя.
    param([object[]]$Current, [string]$BaselineFile)
    $baseline = Read-UtResultRecords $BaselineFile
    $newFailed = New-Object System.Collections.Generic.List[object]
    $knownFailed = New-Object System.Collections.Generic.List[object]
    $reasonChanged = New-Object System.Collections.Generic.List[object]
    $reasonUnknown = 0
    $fixed = New-Object System.Collections.Generic.List[string]
    $added = New-Object System.Collections.Generic.List[string]
    $present = @{}
    foreach ($result in $Current) {
        $present[$result.Key] = $true
        $before = $null
        if ($null -ne $baseline -and $baseline.ContainsKey($result.Key)) { $before = $baseline[$result.Key] } elseif ($null -ne $baseline) { $added.Add($result.Key) }
        if (Test-UtFailed $result.Status) {
            if ($null -ne $before -and (Test-UtFailed $before.Status)) {
                $knownFailed.Add($result)
                if (-not $before.HasMessage) { $reasonUnknown++ }
                elseif ((ConvertTo-UtReasonKey $result.Status $result.Message) -ne (ConvertTo-UtReasonKey $before.Status $before.Message)) {
                    $reasonChanged.Add([pscustomobject]@{ Result = $result; BeforeStatus = $before.Status; BeforeMessage = $before.Message })
                }
            }
            else { $newFailed.Add($result) }
        }
        elseif ($result.Status -eq 'OK' -and $null -ne $before -and (Test-UtFailed $before.Status)) { $fixed.Add($result.Key) }
    }
    $gone = New-Object System.Collections.Generic.List[string]
    if ($null -ne $baseline) { foreach ($key in $baseline.Keys) { if (-not $present.ContainsKey($key)) { $gone.Add($key) } } }
    return [pscustomobject]@{
        HasBaseline = ($null -ne $baseline); NewFailed = $newFailed.ToArray(); KnownFailed = $knownFailed.ToArray()
        ReasonChanged = $reasonChanged.ToArray(); ReasonUnknown = $reasonUnknown
        Fixed = $fixed.ToArray(); Added = $added.ToArray(); Gone = $gone.ToArray()
    }
}

#region Заготовки: новый модуль тестов и новый тест

function New-UtUuid { return [guid]::NewGuid().ToString() }

function ConvertTo-UtXmlText {
    param([string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

function Write-UtFile {
    # Файл выгрузки: UTF-8 с BOM, переводы строк CRLF (как пишет конфигуратор).
    param([string]$Path, [string]$Text)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8Bom)
}

function Get-UtXmlHeader {
    # Заголовок MetaDataObject: пространства имён и версия формата - из Configuration.xml той же выгрузки.
    param([string]$Dir)
    $text = Get-UtText (Join-Path $Dir 'Configuration.xml')
    $found = [regex]::Match($text, '<MetaDataObject[^>]*>')
    if (-not $found.Success) { throw 'в Configuration.xml нет MetaDataObject' }
    return $found.Value
}

function Get-UtModuleTemplate {
    # Текст нового модуля тестов: регистрация и один тест с шапкой.
    param([string]$Method, [string]$Presentation, [string]$Checks, [string]$How, [string]$Why, [string]$Author, [string]$Tags)
    $registration = '	ЮТТесты'
    $body = (Get-UtTestTemplate -Method $Method -Presentation $Presentation -Checks $Checks -How $How -Why $Why -Author $Author -Tags $Tags)
    # Всё экспортное - в области СлужебныйПрограммныйИнтерфейс (стандарт структуры модуля), тесты - во вложенной «Тесты».
    $lines = @(
        '#Область СлужебныйПрограммныйИнтерфейс',
        '',
        '// Регистрация тестов модуля: имя метода, представление (= @Тест из шапки), теги.',
        'Процедура ИсполняемыеСценарии() Экспорт',
        '',
        $registration,
        (Get-UtRegistrationLine -Method $Method -Presentation $Presentation -Tags $Tags -Last $true),
        '',
        'КонецПроцедуры',
        '',
        '#Область Тесты',
        '',
        $body,
        '#КонецОбласти',
        '',
        '#КонецОбласти',
        '')
    return ($lines -join "`n")
}

function ConvertTo-UtBslString {
    param([string]$Text)
    return '"' + $Text.Replace('"', '""') + '"'
}

function Get-UtRegistrationLine {
    param([string]$Method, [string]$Presentation, [string]$Tags, [bool]$Last)
    $arguments = @((ConvertTo-UtBslString $Method), (ConvertTo-UtBslString $Presentation))
    if ($Tags) { $arguments += (ConvertTo-UtBslString $Tags) }
    $line = '		.ДобавитьТест({0})' -f ($arguments -join ', ')
    if ($Last) { $line += ';' }
    return $line
}

function Get-UtTestTemplate {
    param([string]$Method, [string]$Presentation, [string]$Checks, [string]$How, [string]$Why, [string]$Author, [string]$Tags)
    $lines = New-Object System.Collections.Generic.List[string]
    $addField = {
        param([string]$Name, [string]$Value)
        $valueLines = @(([string]$Value).Replace("`r", '').Split("`n"))
        $lines.Add(('// @{0} {1}' -f $Name, $valueLines[0]).TrimEnd())
        for ($i = 1; $i -lt $valueLines.Count; $i++) { $lines.Add(('//   {0}' -f $valueLines[$i]).TrimEnd()) }
    }
    & $addField 'Тест' $Presentation
    & $addField 'Проверяет' $Checks
    & $addField 'Как' $How
    & $addField 'Зачем' $Why
    & $addField 'Автор' $Author
    if ($Tags) { & $addField 'Теги' $Tags }
    $lines.Add(('Процедура {0}() Экспорт' -f $Method))
    $lines.Add('')
    $lines.Add('	// Подготовка данных.')
    $lines.Add('')
    $lines.Add('	// Вызов проверяемого метода. Модули других расширений - через ОбщегоНазначения.ОбщийМодуль("Имя"):')
    $lines.Add('	// тестовое расширение их не видит при проверке конфигуратором.')
    $lines.Add('')
    $lines.Add('	// Проверка результата: ЮТест.ОжидаетЧто(Результат).Равно(Ожидаемое).')
    $lines.Add('	ЮТест.ОжидаетЧто(Истина).ЭтоИстина();')
    $lines.Add('')
    $lines.Add('КонецПроцедуры')
    $lines.Add('')
    return ($lines.ToArray() -join "`n")
}

function Add-UtChildObject {
    # Дописывает <Тип>Имя</Тип> в ChildObjects XML-текста: после последнего элемента того же типа, иначе - в конец.
    param([string]$Text, [string]$Type, [string]$Name)
    $item = '<{0}>{1}</{0}>' -f $Type, (ConvertTo-UtXmlText $Name)
    if ($Text.Contains($item)) { return $Text }
    $open = $Text.IndexOf('<ChildObjects>')
    $close = $Text.IndexOf('</ChildObjects>')
    if ($open -lt 0 -and $Text.Contains('<ChildObjects/>')) {
        $position = $Text.IndexOf('<ChildObjects/>')
        $indent = ''
        $lineStart = $Text.LastIndexOf("`n", $position)
        if ($lineStart -ge 0) { $indent = $Text.Substring($lineStart + 1, $position - $lineStart - 1) }
        return $Text.Substring(0, $position) + "<ChildObjects>`n" + $indent + "`t" + $item + "`n" + $indent + '</ChildObjects>' + $Text.Substring($position + '<ChildObjects/>'.Length)
    }
    if ($open -lt 0 -or $close -lt 0) { throw 'нет ChildObjects' }
    $section = $Text.Substring($open, $close - $open)
    $last = $section.LastIndexOf(('</{0}>' -f $Type))
    $lineStartClose = $Text.LastIndexOf("`n", $close)
    $indent = "`t`t`t"
    if ($lineStartClose -ge 0) { $indent = $Text.Substring($lineStartClose + 1, $close - $lineStartClose - 1) + "`t" }
    if ($last -ge 0) {
        $position = $open + $last + ('</{0}>' -f $Type).Length
        return $Text.Substring(0, $position) + "`n" + $indent + $item + $Text.Substring($position)
    }
    return $Text.Substring(0, $lineStartClose) + "`n" + $indent + $item + $Text.Substring($lineStartClose)
}

function Find-UtSubsystemFile {
    # Файл подсистемы по пути «А/Б» или по имени последней части.
    param([string]$Dir, [string]$Subsystem)
    $parts = @($Subsystem.Split('/') | Where-Object { $_ })
    $path = Join-Path $Dir 'Subsystems'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i -lt $parts.Count - 1) { $path = Join-Path (Join-Path $path $parts[$i]) 'Subsystems' }
        else { $path = Join-Path $path ($parts[$i] + '.xml') }
    }
    if (Test-Path -LiteralPath $path) { return $path }
    $byName = @(Get-ChildItem -LiteralPath (Join-Path $Dir 'Subsystems') -Recurse -Filter ($parts[$parts.Count - 1] + '.xml') -File -ErrorAction SilentlyContinue)
    if ($byName.Count -eq 1) { return $byName[0].FullName }
    return ''
}

function New-UtModule {
    # Новый общий модуль тестов в выгрузке: XML модуля (серверный), Module.bsl с регистрацией и первым тестом,
    # запись в Configuration.xml и в состав подсистемы. Имя - по соглашению YAxUnit: ОМ_<общий модуль>,
    # Док_<документ>_МО и т.п. Ошибка - исключением.
    param([string]$Dir, [string]$Name, [string]$Subsystem, [string]$Method, [string]$Presentation, [string]$Checks,
        [string]$How = '', [string]$Why = '', [string]$Author = '', [string]$Tags = '', [bool]$Client = $false)
    if ($Name -notmatch '^[\w]+$') { throw ("имя модуля «{0}»: только буквы, цифры и подчёркивание" -f $Name) }
    if ($Method -notmatch '^[\w]+$') { throw ("имя теста «{0}»: только буквы, цифры и подчёркивание" -f $Method) }
    $moduleXml = Join-Path $Dir ("CommonModules\{0}.xml" -f $Name)
    if (Test-Path -LiteralPath $moduleXml) { throw ("модуль {0} уже есть" -f $Name) }
    $subsystemFile = Find-UtSubsystemFile -Dir $Dir -Subsystem $Subsystem
    if (-not $subsystemFile) { throw ("подсистемы «{0}» в выгрузке нет" -f $Subsystem) }
    $header = Get-UtXmlHeader $Dir
    $server = 'true'; $clientValue = 'false'
    if ($Client) { $server = 'false'; $clientValue = 'true' }
    $xmlText = @(
        '<?xml version="1.0" encoding="UTF-8"?>',
        $header,
        ('	<CommonModule uuid="{0}">' -f (New-UtUuid)),
        '		<Properties>',
        ('			<Name>{0}</Name>' -f $Name),
        '			<Synonym/>',
        '			<Comment/>',
        '			<Global>false</Global>',
        ('			<ClientManagedApplication>{0}</ClientManagedApplication>' -f $clientValue),
        ('			<Server>{0}</Server>' -f $server),
        '			<ExternalConnection>false</ExternalConnection>',
        '			<ClientOrdinaryApplication>false</ClientOrdinaryApplication>',
        '			<ServerCall>false</ServerCall>',
        '			<Privileged>false</Privileged>',
        '			<ReturnValuesReuse>DontUse</ReturnValuesReuse>',
        '		</Properties>',
        '	</CommonModule>',
        '</MetaDataObject>') -join "`n"
    Write-UtFile -Path $moduleXml -Text $xmlText
    Write-UtFile -Path (Join-Path $Dir ("CommonModules\{0}\Ext\Module.bsl" -f $Name)) -Text (Get-UtModuleTemplate -Method $Method -Presentation $Presentation -Checks $Checks -How $How -Why $Why -Author $Author -Tags $Tags)
    $configPath = Join-Path $Dir 'Configuration.xml'
    Write-UtFile -Path $configPath -Text (Add-UtChildObject -Text (Get-UtText $configPath) -Type 'CommonModule' -Name $Name)
    $subsystemText = Get-UtText $subsystemFile
    $item = '<xr:Item xsi:type="xr:MDObjectRef">CommonModule.{0}</xr:Item>' -f $Name
    if (-not $subsystemText.Contains($item)) {
        if ($subsystemText.Contains('<Content/>')) {
            $subsystemText = $subsystemText.Replace('<Content/>', ("<Content>`n`t`t`t`t{0}`n`t`t`t</Content>" -f $item))
        }
        else {
            $close = $subsystemText.IndexOf('</Content>')
            if ($close -lt 0) { throw ("в {0} нет Content" -f $subsystemFile) }
            $lineStart = $subsystemText.LastIndexOf("`n", $close)
            $subsystemText = $subsystemText.Substring(0, $lineStart) + "`n`t`t`t`t" + $item + $subsystemText.Substring($lineStart)
        }
        Write-UtFile -Path $subsystemFile -Text $subsystemText
    }
    return (Join-Path $Dir ("CommonModules\{0}\Ext\Module.bsl" -f $Name))
}

function Add-UtTest {
    # Новый тест в существующем модуле: процедура с шапкой в конец области «Тесты» (или модуля) и строка
    # регистрации в конец цепочки ИсполняемыеСценарии. Ошибка - исключением.
    param([string]$Dir, [string]$Module, [string]$Method, [string]$Presentation, [string]$Checks,
        [string]$How = '', [string]$Why = '', [string]$Author = '', [string]$Tags = '')
    if ($Method -notmatch '^[\w]+$') { throw ("имя теста «{0}»: только буквы, цифры и подчёркивание" -f $Method) }
    $path = Join-Path $Dir ("CommonModules\{0}\Ext\Module.bsl" -f $Module)
    if (-not (Test-Path -LiteralPath $path)) { throw ("нет модуля {0}" -f $Module) }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-UtText $path).Split("`n")) { $lines.Add($line) }
    $methods = Get-UtMethods $lines.ToArray()
    if (@($methods | Where-Object { $_.Name -ieq $Method }).Count -gt 0) { throw ("в {0} уже есть метод {1}" -f $Module, $Method) }
    $scenarios = @($methods | Where-Object { $_.Name -ieq 'ИсполняемыеСценарии' })
    if ($scenarios.Count -eq 0) { throw ("в {0} нет ИсполняемыеСценарии" -f $Module) }
    # Регистрация: последняя строка цепочки с «;» перед КонецПроцедуры - снять «;», дописать новую строку с «;».
    $insertAt = -1
    for ($i = $scenarios[0].BodyTo - 1; $i -gt $scenarios[0].BodyFrom; $i--) {
        $code = (Remove-UtComment $lines[$i]).TrimEnd()
        if ($code.EndsWith(';') -and $code -match '\.\s*Добавить\w*Тест|\.\s*Представление|\.\s*Теги?|\.\s*ВТранзакции|\)\s*;$') {
            $comment = $lines[$i].Substring($code.Length)
            $lines[$i] = $code.Substring(0, $code.Length - 1) + $comment
            $insertAt = $i + 1
            break
        }
    }
    if ($insertAt -lt 0) { throw ("в ИсполняемыеСценарии {0} не нашёл конец цепочки регистраций («...;»): допиши регистрацию руками" -f $Module) }
    $lines.Insert($insertAt, (Get-UtRegistrationLine -Method $Method -Presentation $Presentation -Tags $Tags -Last $true))
    # Процедура: перед «#КонецОбласти» области «Тесты», иначе в конец модуля.
    $testsRegion = -1
    $regionEnd = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*#Область\s+Тесты\b') { $testsRegion = $i; continue }
        if ($testsRegion -ge 0 -and $lines[$i] -match '^\s*#КонецОбласти') { $regionEnd = $i; break }
    }
    $body = @((Get-UtTestTemplate -Method $Method -Presentation $Presentation -Checks $Checks -How $How -Why $Why -Author $Author -Tags $Tags).Split("`n"))
    if ($regionEnd -ge 0) { $lines.InsertRange($regionEnd, [string[]]$body) }
    else {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
        $lines.AddRange([string[]]$body)
    }
    Write-UtFile -Path $path -Text ($lines.ToArray() -join "`n")
    return $path
}

function Get-UtSubsystemList {
    # Подсистемы выгрузки: путь «Родитель/Дочерняя» и синоним - для выбора, куда положить новый модуль тестов.
    param([string]$Dir)
    $result = New-Object System.Collections.Generic.List[object]
    $root = Join-Path $Dir 'Subsystems'
    if (-not (Test-Path -LiteralPath $root)) { return , $result.ToArray() }
    foreach ($file in @(Get-UtFiles $root | Where-Object { $_.Rel -like '*.xml' } | Sort-Object Rel)) {
        $parts = @($file.Rel.Split('/') | Where-Object { $_ -and $_ -ne 'Subsystems' })
        if ($parts -contains 'Ext') { continue }
        $path = (@($parts | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) }) -join '/')
        $synonym = ''
        try {
            $xml = Get-UtXml $file.Full
            foreach ($node in @($xml.GetElementsByTagName('v8:content'))) { $synonym = ([string]$node.InnerText).Trim(); break }
        }
        catch { $synonym = '' }
        $result.Add([pscustomobject]@{ Path = $path; Synonym = $synonym })
    }
    return , $result.ToArray()
}

function Set-UtDisabled {
    # Выключить тест (строка «// @Выключен <причина>» в конце шапки) или включить (строки @Выключен убрать вместе
    # с их продолжением). Reason пустая - включить. Возвращает путь к модулю. Ошибка - исключением.
    param([string]$Dir, [string]$Module, [string]$Method, [string]$Reason = '')
    $path = Join-Path $Dir ("CommonModules\{0}\Ext\Module.bsl" -f $Module)
    if (-not (Test-Path -LiteralPath $path)) { throw ("в файлах нет модуля {0}" -f $Module) }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-UtText $path).Split("`n")) { $lines.Add($line) }
    $methods = Get-UtMethods $lines.ToArray()
    $target = @($methods | Where-Object { $_.Name -ieq $Method })
    if ($target.Count -eq 0) { throw ("в {0} нет метода {1}" -f $Module, $Method) }
    $procedureIndex = $target[0].Line - 1
    $first = $procedureIndex - $target[0].Comment.Count
    # Убрать прежние @Выключен (и продолжения - строки комментария без «@» после них).
    $index = $first
    $removing = $false
    while ($index -lt $procedureIndex) {
        $text = $lines[$index].Trim()
        if ($text -match '^//\s*@Выключен\b') { $removing = $true; $lines.RemoveAt($index); $procedureIndex--; continue }
        if ($removing -and $text -notmatch '^//\s*@') { $lines.RemoveAt($index); $procedureIndex--; continue }
        $removing = $false
        $index++
    }
    if ($Reason) { $lines.Insert($procedureIndex, ('// @Выключен {0}' -f ($Reason -replace '\s+', ' ').Trim())) }
    Write-UtFile -Path $path -Text ($lines.ToArray() -join "`n")
    return $path
}

#endregion

