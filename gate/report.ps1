#requires -Version 5.1
<#
.SYNOPSIS
    Разбор прогона гейта: где и какая ошибка, почему и что делать. Только по файлам папки прогона, без 1С.

.DESCRIPTION
    .\report.cmd runs\20261117-021500
        Разобрать прогон и записать report.txt в его папку. Гейт вызывает разбор сам после вердикта.

    Что разбирается:
    - шаги, которые не прошли: загрузка, обновление БД, вход, самопроверка - причина по тексту лога;
    - новые записи проверок конфигуратором: группы по модулю и виду ошибки, номера строк, режимы проверки,
      сверка с самопроверкой (подтверждена ли ошибка в настоящем сеансе), встречалась ли запись раньше;
    - новые записи самопроверки: группы по месту ошибки и причине;
    - что исправлено относительно эталона;
    - какие расширения изменились в базе между самопроверками до и после загрузки;
    - шаги, которые шли заметно дольше, чем в прежних прогонах.

.NOTES
    Версия 00000000.000000.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$RunDir,

    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# При сбое показать место: строку, её текст и стек (и отдельным запуском report.cmd, и из гейта).
trap {
    Write-Host ("Сбой разбора: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($null -ne $_.InvocationInfo) { Write-Host ("  строка {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, ([string]$_.InvocationInfo.Line).Trim()) -ForegroundColor Red }
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    break
}

$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
if (-not [System.IO.Path]::IsPathRooted($RunDir)) { $RunDir = Join-Path $PSScriptRoot $RunDir }
$RunDir = $RunDir.TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath (Join-Path $RunDir 'verdict.json'))) { throw "В папке $RunDir нет verdict.json: это не папка прогона гейта." }

# Клиентские методы платформы: в режимах «Сервер» и «Внешнее соединение» их нет.
$ClientOnly = @('ОткрытьФорму', 'ОткрытьФормуМодально', 'ПолучитьФорму', 'ПоказатьОповещениеПользователя', 'ПоказатьПредупреждение',
    'Предупреждение', 'ПоказатьВопрос', 'Вопрос', 'ПоказатьЗначение', 'ОткрытьЗначение', 'ПоказатьВводЗначения',
    'ПоказатьВводСтроки', 'ПоказатьВводЧисла', 'ПоказатьВводДаты', 'Состояние', 'ПодключитьОбработчикОжидания',
    'ОтключитьОбработчикОжидания', 'ОповеститьОбИзменении', 'Оповестить', 'НачатьПомещениеФайла', 'ЗапуститьПриложение',
    'ОткрытьСправку', 'ПерейтиПоНавигационнойСсылке', 'ПолучитьОкна', 'АктивноеОкно')

#region Чтение файлов

function Read-TextLines {
    # Лог 1С бывает и в UTF-8, и в cp1251.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return @() }
    $text = $null
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    else {
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $strictUtf8.GetString($bytes)
        }
        catch {
            $text = [System.Text.Encoding]::GetEncoding(1251).GetString($bytes)
        }
    }
    return @($text -split "`r?`n")
}

function Read-RecordSet {
    param([string]$Path)
    return @(Read-TextLines $Path | ForEach-Object { $_.TrimStart([char]0xFEFF) } | Where-Object { $_.Trim().Length -gt 0 })
}

function Read-InfoValues {
    # Файл «ключ=значение», ключ может повторяться (ext=). Возвращает значения одного ключа.
    param([string]$Path, [string]$Key)
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Read-TextLines $Path)) {
        $clean = $line.TrimStart([char]0xFEFF)
        if ($clean.StartsWith($Key + '=', [System.StringComparison]::Ordinal)) { $values.Add($clean.Substring($Key.Length + 1)) }
    }
    return $values.ToArray()
}

function Get-JsonProperty {
    param($Object, [string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Format-SelfCheckText {
    # То же, что в run.ps1: убирает то, что меняется от прогона к прогону само по себе.
    param([string]$Text)
    $result = [regex]::Replace($Text, '\(\d+(\s*,\s*\d+)?\)\}', '()}')
    $result = [regex]::Replace($result, '\d+ мс', 'N мс')
    $result = [regex]::Replace($result, '\d{8}\.\d{6}', '<сборка>')
    $result = [regex]::Replace($result, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<guid>')
    $result = [regex]::Replace($result, '\d{1,2}\.\d{1,2}\.\d{4}(\s+\d{1,2}:\d{2}(:\d{2})?)?', '<дата>')
    $result = [regex]::Replace($result, '\d{1,2}:\d{2}:\d{2}', '<время>')
    $result = [regex]::Replace($result, '\b\d+\b', 'N')
    return $result
}

function Get-CheckRecordLines {
    # Записи лога проверки (как в run.ps1) и номера строк модуля по каждой записи.
    param([string[]]$Lines)
    $where = @{}
    $count = $Lines.Length
    $index = 0
    while ($index -lt $count) {
        $line = $Lines[$index]
        $index++
        if ($null -eq $line) { continue }
        $record = $line.Trim().Trim([char]0xFEFF)
        if ($record.Length -eq 0) { continue }
        $position = ''
        if ($record.StartsWith('{')) {
            $found = [regex]::Match($record, '\((\d+)\s*,\s*\d+\)\}')
            if ($found.Success) { $position = $found.Groups[1].Value }
            $record = $record -replace '\(\d+\s*,\s*\d+\)\}', '()}'
            if ($index -lt $count -and $null -ne $Lines[$index] -and $Lines[$index].Contains('<<?>>')) {
                $record = $record + ' :: ' + $Lines[$index].Trim()
                $index++
            }
        }
        else {
            $record = $record -replace '^(\S+) \([^)]*\): ', '$1: '
        }
        if (-not $where.ContainsKey($record)) { $where[$record] = New-Object System.Collections.Generic.List[int] }
        if ($position -and -not $where[$record].Contains([int]$position)) { $where[$record].Add([int]$position) }
    }
    return $where
}

#endregion

#region Разбор записей

$KindTitle = @{
    var = 'Переменная не определена'; method = 'Метод не найден'; client = 'Клиентский метод в серверном режиме'
    type = 'Тип не определён'; syntax = 'Синтаксическая ошибка'; compile = 'Ошибка компиляции'
    maybe = 'Возможно ошибочное обращение'; refs = 'Неразрешимые ссылки'; annot = 'Перехват метода, которого нет'; other = 'Прочее'
}
$CheckWhy = @{
    var     = 'Имя «{0}» компилятор не нашёл. Обычно это реквизит или объект, который модуль использует, а расширение не заимствовало; реже опечатка или реквизит, удалённый из комплекта.'
    method  = 'Метода «{0}» нет там, откуда его вызывают: удалён, переименован, не помечен Экспорт или живёт в другом расширении, которого при проверке нет.'
    client  = '«{0}» - клиентский метод, а модуль проверялся в режиме «{1}». У общего модуля стоят лишние флажки («Внешнее соединение», «Сервер») или вызов стоит вне &НаКлиенте.'
    type    = 'Тип «{0}» не найден: объект не заимствован, удалён или назван иначе.'
    syntax  = 'Синтаксическая ошибка: модуль не скомпилируется ни в каком режиме.'
    compile = 'Ошибка компиляции.'
    maybe   = 'Имени нет среди метаданных, которые видит расширение. Если объект есть в типовой, а расширение его просто не заимствовало, в сеансе всё работает (ложная тревога). Если объекта нет вовсе - в сеансе будет ошибка.'
    refs    = 'В форме есть ссылки на {0}, которых нет в базе: объект удалён, не заимствован или форма скопирована из другой конфигурации.'
    annot   = 'Перехват в «{2}» ссылается на метод «{0}», которого нет в расширяемом модуле: после обновления типовой его переименовали или удалили, либо расширение написано под другую версию. Перехват не сработает, расширение может не примениться.'
    other   = 'Запись незнакомого вида: разбор её не классифицирует.'
}
$CheckTodo = @{
    var     = 'Найти «{0}» в модуле: если это реквизит типового объекта - заимствовать его в расширение; если свой - проверить, что он есть в комплекте; если опечатка - исправить.'
    method  = 'Найти, где объявлен «{0}». Если в типовой - сверить с её версией; если в своём модуле - проверить Экспорт и имя.'
    client  = 'В свойствах общего модуля оставить только «Клиент (управляемое приложение)», либо вынести вызов в клиентскую процедуру.'
    type    = 'Проверить имя типа и состав расширения.'
    syntax  = 'Исправить код по строке из лога.'
    compile = 'Открыть модуль на указанной строке.'
    maybe   = 'Проверить, есть ли имя в базе. Есть - можно принять в эталон. Нет - исправить имя или добавить объект.'
    refs    = 'Открыть форму в конфигураторе: такие реквизиты и элементы подсвечены. Убрать или поправить ссылки.'
    annot   = 'Найти «{0}» в типовой текущей версии; если переименован - поправить аннотацию, если удалён - переписать перехват.'
    other   = 'Посмотреть строку в логе шага.'
}

function ConvertFrom-CheckRecord {
    param([string]$Record)
    $result = [ordered]@{ Ext = ''; Place = ''; Kind = 'other'; Name = ''; Mode = ''; Red = $true }
    $found = [regex]::Match($Record, '^\{(\S+) (.+?)\(\)\}: (.*?)(?: :: (.*))?$')
    if ($found.Success) {
        $message = $found.Groups[3].Value
        $code = $found.Groups[4].Value
        $result.Ext = $found.Groups[1].Value
        $result.Place = $found.Groups[2].Value
        $modeMatch = [regex]::Match($code, '\(Проверка: ([^)]+)\)\s*$')
        if ($modeMatch.Success) { $result.Mode = $modeMatch.Groups[1].Value }
        $nameMatch = [regex]::Match($message, '\(([^()]+)\)\s*$')
        if ($nameMatch.Success) { $result.Name = $nameMatch.Groups[1].Value }
        if ($message.StartsWith('Переменная не определена')) { $result.Kind = 'var' }
        elseif ($message.StartsWith('Процедура или функция с указанным именем не определена')) {
            if (($ClientOnly -contains $result.Name) -and ($result.Mode -eq 'Сервер' -or $result.Mode -eq 'Внешнее соединение')) { $result.Kind = 'client' }
            else { $result.Kind = 'method' }
        }
        elseif ($message.StartsWith('Тип не определен')) { $result.Kind = 'type' }
        elseif ($message.StartsWith('Ожидается') -or $message.Contains('Синтаксическая')) { $result.Kind = 'syntax' }
        else { $result.Kind = 'compile' }
        return [pscustomobject]$result
    }
    $found = [regex]::Match($Record, '^(\S+)(?: (\S+))? Возможно ошибочн(?:ое|ый|ая) (свойство|параметр|метод): "?([^"]*)"?$')
    if ($found.Success) {
        if ($found.Groups[2].Success) { $result.Ext = $found.Groups[1].Value; $result.Place = $found.Groups[2].Value }
        else { $result.Place = $found.Groups[1].Value }
        $result.Kind = 'maybe'; $result.Name = $found.Groups[4].Value; $result.Mode = $found.Groups[3].Value; $result.Red = $false
        return [pscustomobject]$result
    }
    $found = [regex]::Match($Record, '^(\S+) Неразрешимые ссылки на (.+?) \((\d+)\)$')
    if ($found.Success) {
        $result.Place = $found.Groups[1].Value; $result.Kind = 'refs'; $result.Name = $found.Groups[2].Value; $result.Mode = $found.Groups[3].Value
        return [pscustomobject]$result
    }
    $found = [regex]::Match($Record, '^(\S+): Не найден метод "([^"]+)", указанный в аннотации метода "([^"]+)"')
    if ($found.Success) {
        $result.Ext = $found.Groups[1].Value; $result.Place = $found.Groups[3].Value; $result.Kind = 'annot'; $result.Name = $found.Groups[2].Value
        return [pscustomobject]$result
    }
    $found = [regex]::Match($Record, '^(\S+): (.*)$')
    if ($found.Success) { $result.Ext = $found.Groups[1].Value }
    return [pscustomobject]$result
}

function Get-CompileKey {
    # Модуль из лога проверки -> ключ задания компиляции в самопроверке.
    param([string]$Place)
    $parts = $Place.Split('.')
    if ($parts.Length -ge 2 -and $parts[0] -eq 'ОбщийМодуль') { return 'ОбщийМодуль|' + $parts[1] }
    if ($parts.Length -ge 2) { return 'Объект|' + $parts[0] + '.' + $parts[1] }
    return ''
}

$SelfCheckCauses = @(
    @{ Pattern = 'задание не завершилось'; Cause = 'hang' },
    @{ Pattern = 'Конфликт блокировок|максимальное время ожидания'; Cause = 'lock' },
    @{ Pattern = 'Поле объекта не обнаружено \(([^)]+)\)'; Cause = 'field' },
    @{ Pattern = 'Переменная не определена \(([^)]+)\)'; Cause = 'var' },
    @{ Pattern = 'Таблица не найдена "([^"]+)"'; Cause = 'table' },
    @{ Pattern = 'Синтаксическая ошибка'; Cause = 'query' },
    @{ Pattern = 'Недостаточно прав|Нарушение прав доступа'; Cause = 'rights' },
    @{ Pattern = 'Значение не является значением объектного типа \(([^)]+)\)'; Cause = 'undef' },
    @{ Pattern = 'Метод объекта не обнаружен \(([^)]+)\)'; Cause = 'objmethod' },
    @{ Pattern = 'не определен[аоы]? \(([^)]+)\)'; Cause = 'method' }
)
$SelfCheckWhy = @{
    hang      = 'Клиент 1С завис или закрылся на этом задании.'
    lock      = 'Конфликт блокировок: документ держал другой сеанс. Это не дефект комплекта, а помеха.'
    field     = 'У объекта нет реквизита «{0}»: код обращается к реквизиту, которого нет в базе или который не заимствован.'
    var       = 'Модуль не компилируется в настоящем сеансе: имя «{0}» не определено.'
    table     = 'Запрос обращается к таблице «{0}», которой нет в базе.'
    query     = 'Синтаксическая ошибка в тексте запроса (часто - значение перечисления или поле, которого нет).'
    rights    = 'Не хватает прав.'
    undef     = 'Обращение к «{0}» у значения Неопределено: не заполнена ссылка или не найден объект.'
    objmethod = 'У объекта нет метода «{0}».'
    method    = 'Не найден метод или переменная «{0}».'
    other     = ''
}
$SelfCheckTodo = @{
    hang      = 'Снимки окон клиента - в selfcheck-after\tryN\ (client_windows.txt, png). Окно с ошибкой - настоящая находка; долгое проведение - поднять SelfCheckStallMin или добавить вид документа в SelfCheckSkipDocs.'
    lock      = 'Проверить, что в erp_temp никто не работал и не висят старые сеансы, и повторить прогон.'
    field     = 'Проверить реквизит «{0}» в комплекте и в базе.'
    var       = 'Исправить модуль: это не ложная тревога.'
    table     = 'Исправить текст запроса.'
    query     = 'Исправить текст запроса.'
    rights    = 'Проверить роли на новые объекты (регламент: Чтение и ДобавлениеИзменение).'
    undef     = 'Проверить заполнение перед обращением.'
    objmethod = 'Проверить модуль объекта и экспорт метода.'
    method    = 'Проверить модуль по месту ошибки.'
    other     = 'Подробности - в журнале selfcheck-after.journal.txt.'
}

function ConvertFrom-SelfCheckRecord {
    param([string]$Record)
    $found = [regex]::Match($Record, '^\[(\S+)\] (.*?) :: (.*)$')
    if (-not $found.Success) { return $null }
    $key = $found.Groups[2].Value
    $text = $found.Groups[3].Value
    $location = ''
    $locationMatch = [regex]::Match($text, '\{([^}]*)\}')
    if ($locationMatch.Success -and $locationMatch.Groups[1].Value.Trim('(', ')').Length -gt 0) {
        $location = $locationMatch.Groups[1].Value -replace '\(\)$', ''
    }
    $cause = 'other'
    $name = ''
    foreach ($rule in $SelfCheckCauses) {
        $match = [regex]::Match($text, $rule.Pattern)
        if ($match.Success) {
            $cause = $rule.Cause
            if ($match.Groups.Count -gt 1) { $name = $match.Groups[1].Value }
            break
        }
    }
    $step = $key
    $object = ''
    $slash = $key.IndexOf('/')
    if ($slash -ge 0) { $step = $key.Substring(0, $slash); $object = $key.Substring($slash + 1) }
    return [pscustomobject]@{ Kind = $found.Groups[1].Value; Key = $key; Step = $step; Object = $object; Text = $text; Location = $location; Cause = $cause; Name = $name }
}

function Get-EarlierRuns {
    # Папки прогонов раньше этого, по имени.
    $me = Split-Path -Leaf $RunDir
    $parent = Split-Path -Parent $RunDir
    return @(Get-ChildItem -LiteralPath $parent -Directory | Where-Object { [string]::CompareOrdinal($_.Name, $me) -lt 0 } | Sort-Object Name)
}

function Get-SeenBefore {
    # В каких прежних прогонах запись уже была новой.
    param([string]$Record, [string]$FileName)
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($dir in $script:EarlierRuns) {
        $path = Join-Path $dir.FullName $FileName
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if (@(Read-RecordSet $path) -contains $Record) { $hits.Add($dir.Name) }
    }
    return $hits.ToArray()
}

function Format-Short {
    param([string]$Text, [int]$Max = 220)
    if ($Text.Length -gt $Max) { return $Text.Substring(0, $Max) + '...' }
    return $Text
}

#endregion

#region Разбор

$meta = Get-Content -LiteralPath (Join-Path $RunDir 'verdict.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$runId = [string](Get-JsonProperty $meta 'runId' (Split-Path -Leaf $RunDir))
$baseKey = [string](Get-JsonProperty $meta 'baseKey' '')
$kitText = [string](Get-JsonProperty $meta 'kit' '')
$steps = @(Get-JsonProperty $meta 'steps' @())
$kitItems = @(Get-JsonProperty $meta 'kitItems' @())
$kitDecision = [string](Get-JsonProperty $meta 'kitDecision' '')
$script:EarlierRuns = @(Get-EarlierRuns)

$referenceDir = Join-Path $RunDir 'reference'
$referenceNote = ''
if (-not (Test-Path -LiteralPath $referenceDir)) {
    $baselineName = $baseKey
    if (-not $baselineName) { $baselineName = '_' }
    $referenceDir = Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $RunDir)) 'baseline') $baselineName
    $referenceNote = 'Копии эталона на момент прогона в папке нет (прогон старой версии гейта): исправленное считается по нынешнему эталону базы.'
}

$summary = New-Object System.Collections.Generic.List[string]
$body = New-Object System.Collections.Generic.List[string]
$afterRecords = @(Read-RecordSet (Join-Path $RunDir 'selfcheck-after.norm.txt'))
$newSelfCheck = @(Read-RecordSet (Join-Path $RunDir 'selfcheck-after.new.txt'))
$selfCheckErrorText = (@($newSelfCheck | Where-Object { $_.StartsWith('[ОШИБКА]') }) -join "`n")
$checkNames = New-Object System.Collections.Generic.List[string]

# Шаги, которые не прошли и не разбираются ниже по своим записям.
foreach ($step in $steps) {
    $status = [string](Get-JsonProperty $step 'status' '')
    $name = [string](Get-JsonProperty $step 'name' '')
    $detail = [string](Get-JsonProperty $step 'detail' '')
    if ($status -eq 'OK' -or $status -eq '') { continue }
    $isCompared = ($name.StartsWith('Проверка') -or $name.StartsWith('Синтаксический') -or $name.StartsWith('Самопроверка после') -or $name -eq 'Самопроверка')
    if ($isCompared -and ($detail.Contains('новых') -or $detail.Contains('эталона нет'))) { continue }
    if ($status -eq 'SKIP') {
        $summary.Add(("[ПРОП] {0}: {1}" -f $name, $detail))
        continue
    }

    $logTail = ''
    $logPath = [string](Get-JsonProperty $step 'log' '')
    if ($logPath) {
        $localLog = Join-Path $RunDir (Split-Path -Leaf $logPath)
        $tailLines = @(Read-TextLines $localLog | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_.Trim().TrimStart([char]0xFEFF) })
        if ($tailLines.Count -gt 0) { $logTail = (@($tailLines | Select-Object -Last 3) -join ' | ') }
    }
    $why = $detail
    $todo = ''
    if ($logTail) { $todo = 'Последние строки лога: ' + $logTail }
    $lock = [regex]::Match($logTail, 'компьютер: ([^,]+), сеанс ?: ?(\d+), начат: ([^,]+), приложение: (.+)$')
    if (($detail + $logTail).Contains('исключительной блокировки')) {
        $why = 'Для обновления конфигурации БД нужен монопольный доступ к базе, а в ней были другие сеансы.'
        if ($lock.Success) {
            $why += (" Мешал сеанс {0} ({1}, компьютер {2}, начат {3})." -f $lock.Groups[2].Value, $lock.Groups[4].Value.Trim(), $lock.Groups[1].Value, $lock.Groups[3].Value.Trim())
            if ($lock.Groups[4].Value.Contains('Фонов')) {
                $why += ' Фоновое задание - это регламентные задания самой erp_temp: в копии рабочей базы они работают по тому же расписанию.'
            }
        }
        $todo = 'Расширение уже загружено в конфигурацию, но к базе не применено. Повторить прогон, когда в erp_temp нет сеансов, или включить для erp_temp блокировку регламентных заданий в консоли кластера.'
        $blockersAt = $detail.IndexOf('. Мешали: ')
        if ($blockersAt -ge 0) { $why += (' Опрос сеансов после отказа: ' + $detail.Substring($blockersAt + 10) + '.') }
    }
    elseif (($detail + $logTail) -match 'Начало сеанса .*запрещено|сеансов .*заблокирован|Установлена блокировка') {
        $why = 'В базе установлена блокировка начала сеансов, и запуск шёл без кода разрешения или с неверным кодом.'
        $todo = 'Вписать код разрешения в настройку UnlockCode в config.psd1 (тот, что указан при установке блокировки) и повторить прогон.'
    }
    elseif ($detail.Contains('открыт в другом сеансе') -or $logTail.Contains('уже открыта Конфигуратором')) {
        $why = 'Конфигурация erp_temp была открыта в конфигураторе, пакетный режим не смог её захватить.'
        $todo = 'Закрыть конфигуратор erp_temp (в логе названы компьютер и сеанс) и повторить прогон.'
    }
    elseif ($detail.Contains('таймаут')) {
        $why = 'Шаг не уложился в отведённое время, процесс 1С снят.'
        $todo = 'Посмотреть, не был ли занят сервер; при необходимости увеличить таймаут шага в config.psd1.'
    }
    elseif ($detail.Contains('NOT_APPLIED')) {
        $why = 'Расширение включено, но в сеансе не применилось: у нового расширения стоит безопасный режим или защита от опасных действий, либо оно не прошло проверку применимости.'
        $todo = 'В списке расширений erp_temp снять «Безопасный режим» и «Защита от опасных действий»; посмотреть шаг «Проверка применимости».'
    }
    elseif ($logTail -match 'не является|еверный формат') {
        $why = 'Файл комплекта не читается как расширение: битый файл или выгрузка конфигурации вместо расширения.'
        $todo = 'Попросить выгрузку заново (Конфигурация - Расширения конфигурации - Сохранить в файл).'
    }
    elseif ($name.StartsWith('Самопроверка')) {
        $todo = 'Подробности - в selfcheck-*\tryN\ (started.txt, result.txt, снимки окон).'
    }

    $mark = 'ЖЁЛТ'
    if ($status -eq 'FAIL') { $mark = 'КРАСН' }
    $summary.Add(("[{0}] {1}: {2}" -f $mark, $name, ($why.Split('.')[0])))
    $body.Add(("== {0} ({1})" -f $name, $status))
    $body.Add(('   Почему: ' + $why))
    if ($todo) { $body.Add(('   Что делать: ' + $todo)) }
    $body.Add('')
}

# Проверки конфигуратором.
$comparedSomething = $false
foreach ($logFile in @(Get-ChildItem -LiteralPath $RunDir -Filter 'check*.log' -File | Sort-Object Name)) {
    $fileKey = $logFile.BaseName
    $newRecords = @(Read-RecordSet (Join-Path $RunDir ($fileKey + '.new.txt')))
    $currentRecords = @(Read-RecordSet (Join-Path $RunDir ($fileKey + '.norm.txt')))
    $referenceRecords = @(Read-RecordSet (Join-Path $referenceDir ($fileKey + '.norm.txt')))
    $gone = @()
    if ($referenceRecords.Count -gt 0 -and $currentRecords.Count -gt 0) {
        $currentSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($record in $currentRecords) { [void]$currentSet.Add($record) }
        $gone = @($referenceRecords | Where-Object { -not $currentSet.Contains($_) } | Sort-Object -Unique)
    }
    if ($newRecords.Count -eq 0 -and $gone.Count -eq 0) { continue }
    $comparedSomething = $true

    $stepTitle = $fileKey
    if ($fileKey.StartsWith('checkconfig')) { $stepTitle = 'Проверка конфигурации' }
    elseif ($fileKey.StartsWith('checkcanapply')) { $stepTitle = 'Проверка применимости' }
    elseif ($fileKey.StartsWith('checkmodules')) { $stepTitle = 'Синтаксический контроль' }
    $underscore = $fileKey.IndexOf('_')
    if ($underscore -gt 0 -and -not $fileKey.StartsWith('checkcanapply')) { $stepTitle += (' ({0})' -f $fileKey.Substring($underscore + 1)) }

    $where = Get-CheckRecordLines @(Read-TextLines $logFile.FullName)
    $parsed = @($newRecords | ForEach-Object { [pscustomobject]@{ Record = $_; Info = (ConvertFrom-CheckRecord $_) } })
    $redCount = @($parsed | Where-Object { $_.Info.Red }).Count
    $body.Add(("== {0}: новых {1} (блокирующих {2}), исправлено {3}" -f $stepTitle, $newRecords.Count, $redCount, $gone.Count))
    if ($newRecords.Count -gt 0) {
        $mark = 'ЖЁЛТ'
        if ($redCount -gt 0) { $mark = 'КРАСН' }
        $summary.Add(("[{0}] {1}: новых замечаний {2}, блокирующих {3}" -f $mark, $stepTitle, $newRecords.Count, $redCount))
    }

    # Группы: расширение + модуль + вид + имя. «Возможно ошибочное» сводится по имени.
    $groups = [ordered]@{}
    $maybe = @{}
    foreach ($item in @($parsed | Sort-Object { -not $_.Info.Red }, { $_.Info.Ext }, { $_.Info.Place }, { $_.Info.Kind }, { $_.Info.Name })) {
        $info = $item.Info
        $place = ("{0} {1}" -f $info.Ext, $info.Place).Trim()
        if ($info.Kind -eq 'maybe') {
            if (-not $maybe.ContainsKey($info.Name)) { $maybe[$info.Name] = New-Object System.Collections.Generic.List[string] }
            if (-not $maybe[$info.Name].Contains($place)) { $maybe[$info.Name].Add($place) }
            continue
        }
        $groupKey = "{0}`t{1}`t{2}" -f $place, $info.Kind, $info.Name
        if (-not $groups.Contains($groupKey)) { $groups[$groupKey] = New-Object System.Collections.Generic.List[object] }
        $groups[$groupKey].Add($item)
    }

    $number = 0
    foreach ($groupKey in @($groups.Keys)) {
        # Не @($groups[$groupKey]): в PowerShell 5.1 @() над значением [ordered]-словаря (List[object]) падает
        # с «Argument types do not match» (ошибка привязки PSToObjectArrayBinder). Через конвейер - можно.
        $items = @($groups[$groupKey] | ForEach-Object { $_ })
        $info = $items[0].Info
        $number++
        $place = ("{0} {1}" -f $info.Ext, $info.Place).Trim()
        if (-not $place) { $place = '(без модуля)' }
        $headline = "  {0}. {1} - {2}" -f $number, $place, $KindTitle[$info.Kind]
        if ($info.Name) { $headline += (': ' + $info.Name) }
        $body.Add($headline)

        $lineNumbers = New-Object 'System.Collections.Generic.SortedSet[int]'
        $modes = New-Object 'System.Collections.Generic.SortedSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($item in $items) {
            if ($where.ContainsKey($item.Record)) { foreach ($position in $where[$item.Record]) { [void]$lineNumbers.Add($position) } }
            if ($item.Info.Mode) { [void]$modes.Add($item.Info.Mode) }
        }
        $facts = New-Object System.Collections.Generic.List[string]
        if ($lineNumbers.Count -gt 0) { $facts.Add(('строки ' + (@($lineNumbers) -join ', '))) }
        if ($modes.Count -gt 0 -and $info.Kind -ne 'refs') { $facts.Add(('режимы проверки: ' + (@($modes) -join ', '))) }
        if ($items.Count -gt 1) { $facts.Add(("записей {0}" -f $items.Count)) }
        if ($facts.Count -gt 0) { $body.Add(('     Где: ' + ($facts -join '; '))) }

        $modeText = (@($modes) -join ', ')
        if (-not $modeText) { $modeText = $info.Mode }
        $body.Add(('     Почему: ' + ($CheckWhy[$info.Kind] -f $info.Name, $modeText, $info.Place)))
        if ($info.Name) { $checkNames.Add($info.Name) }

        # Сверка с самопроверкой: подтвердилась ли ошибка в настоящем сеансе.
        if (@('var', 'method', 'type') -contains $info.Kind -and $afterRecords.Count -gt 0) {
            $compileKey = Get-CompileKey $info.Place
            if ($info.Name -and $selfCheckErrorText.Contains(('({0})' -f $info.Name))) {
                $body.Add('     Самопроверка: та же ошибка в настоящем сеансе - это не ложная тревога.')
            }
            elseif ($compileKey -and @($afterRecords | Where-Object { $_.StartsWith('[ОК] КомпиляцияМодулей/' + $compileKey + ' ') }).Count -gt 0) {
                $body.Add('     Самопроверка: в настоящем сеансе модуль компилируется - похоже на незаимствованный реквизит, в работе не мешает. Если так - принять в эталон.')
            }
            elseif ($compileKey -and @($afterRecords | Where-Object { $_.StartsWith('[ОШИБКА] КомпиляцияМодулей/' + $compileKey + ' ') }).Count -gt 0) {
                $body.Add('     Самопроверка: модуль не компилируется и в настоящем сеансе.')
            }
        }
        $body.Add(('     Что делать: ' + ($CheckTodo[$info.Kind] -f $info.Name)))
        $seen = @(Get-SeenBefore -Record $items[0].Record -FileName ($fileKey + '.new.txt'))
        if ($seen.Count -gt 0) { $body.Add(("     Уже было новым в прогонах: {0} - {1} ({2})" -f $seen[0], $seen[$seen.Count - 1], $seen.Count)) }
    }

    if ($maybe.Count -gt 0) {
        $number++
        $body.Add(("  {0}. Возможно ошибочные обращения (жёлтое), по именам:" -f $number))
        foreach ($name in @($maybe.Keys | Sort-Object)) {
            $places = @($maybe[$name] | Sort-Object)
            $placeText = (@($places | Select-Object -First 4) -join ', ')
            if ($places.Count -gt 4) { $placeText += (" и ещё {0}" -f ($places.Count - 4)) }
            $confirmed = ''
            if ($selfCheckErrorText.Contains(('({0})' -f $name))) { $confirmed = ' - в самопроверке ошибка с этим именем, проверить обязательно' }
            $body.Add(("     «{0}»: {1}{2}" -f $name, $placeText, $confirmed))
            $checkNames.Add($name)
        }
        $body.Add(('     Почему: ' + $CheckWhy['maybe']))
        $body.Add(('     Что делать: ' + $CheckTodo['maybe']))
    }

    if ($gone.Count -gt 0) {
        $body.Add(("  Исправлено (было в эталоне, теперь нет): {0}" -f $gone.Count))
        $goneGroups = [ordered]@{}
        foreach ($record in $gone) {
            $info = ConvertFrom-CheckRecord $record
            $groupKey = "{0} - {1}" -f ("{0} {1}" -f $info.Ext, $info.Place).Trim(), $KindTitle[$info.Kind]
            if (-not $goneGroups.Contains($groupKey)) { $goneGroups[$groupKey] = New-Object 'System.Collections.Generic.SortedSet[string]' ([System.StringComparer]::Ordinal) }
            if ($info.Name) { [void]$goneGroups[$groupKey].Add($info.Name) }
        }
        $shown = 0
        foreach ($groupKey in @($goneGroups.Keys | Sort-Object)) {
            $shown++
            if ($shown -gt 10) { break }
            $names = @($goneGroups[$groupKey] | ForEach-Object { $_ })   # не @(значение словаря), см. выше
            $line = '     ' + $groupKey
            if ($names.Count -gt 0) { $line += (': ' + ($names -join ', ')) }
            $body.Add($line)
        }
        if ($goneGroups.Count -gt 10) { $body.Add(("     и ещё групп: {0}" -f ($goneGroups.Count - 10))) }
    }
    $body.Add('')
}

# Самопроверка.
if ($afterRecords.Count -gt 0 -or $newSelfCheck.Count -gt 0) {
    $referenceSelfCheck = @(Read-RecordSet (Join-Path $referenceDir 'selfcheck.norm.txt'))
    $fixed = @()
    if ($referenceSelfCheck.Count -gt 0 -and $afterRecords.Count -gt 0) {
        $currentSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($record in $afterRecords) { [void]$currentSet.Add((Format-SelfCheckText $record)) }
        $fixed = @($referenceSelfCheck | ForEach-Object { Format-SelfCheckText $_ } | Where-Object { $_.StartsWith('[ОШИБКА]') -and -not $currentSet.Contains($_) } | Sort-Object -Unique)
    }
    $errors = @($newSelfCheck | Where-Object { $_.StartsWith('[ОШИБКА]') })
    $others = @($newSelfCheck | Where-Object { -not $_.StartsWith('[ОШИБКА]') })
    if ($newSelfCheck.Count -gt 0 -or $fixed.Count -gt 0) {
        $comparedSomething = $true
        $body.Add(("== Самопроверка: новых ошибок {0}, новых предупреждений и пропусков {1}, исправлено ошибок {2}" -f $errors.Count, $others.Count, $fixed.Count))
        if ($newSelfCheck.Count -gt 0) {
            $mark = 'ЖЁЛТ'
            if ($errors.Count -gt 0) { $mark = 'КРАСН' }
            $summary.Add(("[{0}] Самопроверка: новых ошибок {1}, предупреждений и пропусков {2}" -f $mark, $errors.Count, $others.Count))
        }
        $groups = [ordered]@{}
        foreach ($record in $errors) {
            $info = ConvertFrom-SelfCheckRecord $record
            if ($null -eq $info) { continue }
            $location = $info.Location
            if ($info.Cause -eq 'lock' -or $info.Cause -eq 'hang') { $location = '' }
            if (-not $location -and $info.Cause -eq 'other') { $location = $info.Key }
            $groupKey = "{0}`t{1}`t{2}`t{3}" -f [int]($info.Cause -eq 'lock'), $info.Cause, $location, $info.Name
            if (-not $groups.Contains($groupKey)) { $groups[$groupKey] = New-Object System.Collections.Generic.List[object] }
            $groups[$groupKey].Add($info)
        }
        $number = 0
        foreach ($groupKey in @($groups.Keys | Sort-Object)) {
            # Не @($groups[$groupKey]): в PowerShell 5.1 @() над значением [ordered]-словаря (List[object]) падает
        # с «Argument types do not match» (ошибка привязки PSToObjectArrayBinder). Через конвейер - можно.
        $items = @($groups[$groupKey] | ForEach-Object { $_ })
            $info = $items[0]
            $number++
            $head = $info.Location
            if ($info.Cause -eq 'hang') { $head = 'Задание зависло' }
            elseif ($info.Cause -eq 'lock') { $head = 'Конфликт блокировок' }
            elseif (-not $head) { $head = $info.Key }
            $body.Add(("  {0}. {1}" -f $number, $head))
            $objects = @($items | ForEach-Object { if ($_.Object) { $_.Object } else { $_.Key } } | Sort-Object -Unique)
            $objectText = (@($objects | Select-Object -First 5) -join ', ')
            if ($objects.Count -gt 5) { $objectText += (" и ещё {0}" -f ($objects.Count - 5)) }
            $body.Add(('     Где: ' + $objectText))
            $documents = @($items | Where-Object { $_.Step -eq 'Проведение' }).Count
            if ($documents -gt 0) { $body.Add(("     Документов с ошибкой: {0}" -f $documents)) }
            $why = $SelfCheckWhy[$info.Cause] -f $info.Name
            if (-not $why) { $why = 'Текст: ' + (Format-Short $info.Text 300) }
            $body.Add(('     Почему: ' + $why))
            if ($info.Name -and $checkNames.Contains($info.Name)) { $body.Add('     Проверка конфигурации нашла то же имя - смотреть вместе с её разбором выше.') }
            $body.Add(('     Что делать: ' + ($SelfCheckTodo[$info.Cause] -f $info.Name)))
        }
        if ($others.Count -gt 0) {
            $body.Add('  Предупреждения и пропуски:')
            foreach ($record in @($others | Select-Object -First 10)) { $body.Add(('     ' + (Format-Short $record))) }
            if ($others.Count -gt 10) { $body.Add(("     и ещё {0} - в selfcheck-after.new.txt" -f ($others.Count - 10))) }
        }
        if ($fixed.Count -gt 0) {
            $body.Add('  Исправлено (ошибка была в эталоне, теперь нет):')
            foreach ($record in @($fixed | Select-Object -First 10)) {
                $info = ConvertFrom-SelfCheckRecord $record
                if ($null -eq $info) { $body.Add(('     ' + (Format-Short $record 200))) } else { $body.Add(('     ' + $info.Key)) }
            }
        }
        $body.Add('')
    }
}

# Расширения между самопроверками до и после загрузки.
$extBefore = @(Read-InfoValues (Join-Path $RunDir 'selfcheck-before\try1\info.txt') 'ext')
$extAfter = @(Read-InfoValues (Join-Path $RunDir 'selfcheck-after\try1\info.txt') 'ext')
if ($extBefore.Count -gt 0 -and $extAfter.Count -gt 0) {
    $before = @{}
    $after = @{}
    foreach ($row in $extBefore) { $parts = @($row.Split('|') + @('', '', '', '')); $before[$parts[0]] = $parts }
    foreach ($row in $extAfter) { $parts = @($row.Split('|') + @('', '', '', '')); $after[$parts[0]] = $parts }
    $kitNames = @($kitItems | ForEach-Object { [string](Get-JsonProperty $_ 'name' '') })
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($name in @(@($before.Keys) + @($after.Keys) | Sort-Object -Unique)) {
        if (-not $before.ContainsKey($name)) { $changes.Add(@($name, ("появилось (версия {0})" -f $after[$name][1]))); continue }
        if (-not $after.ContainsKey($name)) { $changes.Add(@($name, 'исчезло')); continue }
        $b = $before[$name]
        $a = $after[$name]
        if ($b[1] -ne $a[1]) { $changes.Add(@($name, ("версия {0} -> {1}" -f $b[1], $a[1]))) }
        elseif ($b[3] -and $a[3] -and $b[3] -ne $a[3]) { $changes.Add(@($name, 'перезагружено без смены версии')) }
        if ($b[2] -ne $a[2]) { $changes.Add(@($name, ("{0} -> {1}" -f $b[2], $a[2]))) }
    }
    if ($changes.Count -gt 0) {
        $body.Add('== Расширения: что изменилось в базе между самопроверками')
        foreach ($change in $changes) {
            $line = "   {0}: {1}" -f $change[0], $change[1]
            if ($kitNames.Count -gt 0 -and $kitNames -notcontains $change[0]) {
                $line += '   <- не из комплекта!'
                $summary.Add(("[ВНИМ] Расширение {0} изменилось, хотя в комплекте его нет" -f $change[0]))
            }
            $body.Add($line)
        }
        $body.Add('')
    }
}

# Пакет сценариев самопроверки: какие проверки шли. Пакет сменился между «до» и «после» - сравнение ненадёжно.
$packBefore = @(Read-InfoValues (Join-Path $RunDir 'selfcheck-before\try1\info.txt') 'packname')
$packAfter = @(Read-InfoValues (Join-Path $RunDir 'selfcheck-after\try1\info.txt') 'packname')
$packReason = @(Read-InfoValues (Join-Path $RunDir 'selfcheck-after\try1\info.txt') 'packreason')
if ($packAfter.Count -gt 0) {
    $packLine = '== Пакет сценариев самопроверки: ' + $packAfter[0]
    if ($packReason.Count -gt 0 -and $packReason[0]) { $packLine += (' (' + $packReason[0] + ')') }
    $body.Add($packLine)
    if ($packBefore.Count -gt 0 -and $packBefore[0] -ne $packAfter[0]) {
        $body.Add(("   до загрузки был другой пакет: {0}. Записи шагов пакета сравнивать не с чем" -f $packBefore[0]))
        $summary.Add(("[ВНИМ] Пакет сценариев самопроверки сменился: {0} -> {1}" -f $packBefore[0], $packAfter[0]))
    }
    $body.Add('')
}

# Внешние обработки комплекта: что стало в справочнике «Дополнительные отчёты и обработки».
$kitProcessings = @(Get-JsonProperty $meta 'kitProcessings' @())
if ($kitProcessings.Count -gt 0) {
    $body.Add('== Внешние обработки: справочник «Дополнительные отчёты и обработки»')
    foreach ($proc in $kitProcessings) {
        $name = [string](Get-JsonProperty $proc 'name' '')
        $state = 'в справочник не записана'
        if ([bool](Get-JsonProperty $proc 'touched' $false)) {
            if ([string](Get-JsonProperty $proc 'isNew' '') -eq 'yes') { $state = 'добавлена новым элементом' } else { $state = 'обновлена' }
            $oldVersion = [string](Get-JsonProperty $proc 'oldVersion' '')
            $newVersion = [string](Get-JsonProperty $proc 'newVersion' '')
            if ($oldVersion -or $newVersion) { $state += (", версия {0} -> {1}" -f $(if ($oldVersion) { $oldVersion } else { '-' }), $(if ($newVersion) { $newVersion } else { '-' })) }
            $oldFile = [string](Get-JsonProperty $proc 'oldFile' '')
            if ($oldFile) { $state += ("; прежняя версия: {0}" -f $oldFile) }
        }
        $body.Add(("   {0} ({1}): {2}" -f $name, [string](Get-JsonProperty $proc 'fileName' ''), $state))
    }
    $body.Add('')
}

# Шаги, которые шли заметно дольше прежних прогонов.
$history = @{}
foreach ($dir in $script:EarlierRuns) {
    $verdictPath = Join-Path $dir.FullName 'verdict.json'
    if (-not (Test-Path -LiteralPath $verdictPath)) { continue }
    try { $earlier = Get-Content -LiteralPath $verdictPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    foreach ($step in @(Get-JsonProperty $earlier 'steps' @())) {
        $seconds = [int](Get-JsonProperty $step 'seconds' 0)
        if ([string](Get-JsonProperty $step 'status' '') -ne 'OK' -or $seconds -le 0) { continue }
        $name = [string](Get-JsonProperty $step 'name' '')
        if (-not $history.ContainsKey($name)) { $history[$name] = New-Object System.Collections.Generic.List[int] }
        $history[$name].Add($seconds)
    }
}
$slow = New-Object System.Collections.Generic.List[string]
foreach ($step in $steps) {
    $name = [string](Get-JsonProperty $step 'name' '')
    $seconds = [int](Get-JsonProperty $step 'seconds' 0)
    if (-not $history.ContainsKey($name) -or $seconds -le 120) { continue }
    $values = @($history[$name] | Sort-Object)
    if ($values.Count -lt 2) { continue }
    $middle = [int][Math]::Floor($values.Count / 2)
    $median = $values[$middle]
    if ($values.Count % 2 -eq 0) { $median = [int](($values[$middle - 1] + $values[$middle]) / 2) }
    if ($seconds -gt 2 * $median) { $slow.Add(("{0}: {1} с, обычно {2} с (по {3} прогонам)" -f $name, $seconds, $median, $values.Count)) }
}
if ($slow.Count -gt 0) {
    $body.Add('== Шаги шли заметно дольше обычного')
    foreach ($line in $slow) { $body.Add(('   ' + $line)) }
    $body.Add('   Если ошибок в этих шагах нет, причина обычно в нагрузке на сервер: бэкап, техокно, чужие сеансы, регламентные задания.')
    $body.Add('')
    $summary.Add(('[ВНИМ] Дольше обычного: ' + (@($slow | ForEach-Object { $_.Split(':')[0] }) -join '; ')))
}

#endregion

#region Вывод

$report = New-Object System.Collections.Generic.List[string]
$report.Add(("РАЗБОР ПРОГОНА {0}, база {1}" -f $runId, $baseKey))
if ($kitText) { $report.Add(('Комплект: ' + $kitText)) } else { $report.Add('Комплект: не задан, проверялась база как есть') }
$report.Add(('Вердикт: ' + [string](Get-JsonProperty $meta 'verdict' '')))
$decisionText = @{ kept = 'оставлен в базе'; rolledBack = 'откачен'; rollbackFailed = 'откат прошёл не полностью' }
if ($kitDecision) {
    $text = $kitDecision
    if ($decisionText.ContainsKey($kitDecision)) { $text = $decisionText[$kitDecision] }
    $report.Add(('Комплект после вердикта: ' + $text))
}
if ($referenceNote -and $comparedSomething) { $report.Add($referenceNote) }
$report.Add('')
$report.Add('КОРОТКО')
if ($summary.Count -eq 0) { $report.Add('  Нового ничего нет.') }
foreach ($line in $summary) { $report.Add(('  ' + $line)) }
$report.Add('')
foreach ($line in $body) { $report.Add($line) }
$report.Add('Подробности: summary.txt, *.new.txt, selfcheck-after.journal.txt в папке прогона. Разбор строится только по файлам прогона, без 1С.')

$reportPath = Join-Path $RunDir 'report.txt'
[System.IO.File]::WriteAllLines($reportPath, $report.ToArray(), $Utf8Bom)

if (-not $Quiet) {
    Write-Host ''
    Write-Host 'РАЗБОР ПРОГОНА' -ForegroundColor Cyan
    if ($summary.Count -eq 0) { Write-Host '  Нового ничего нет.' }
    foreach ($line in $summary) {
        $color = 'Gray'
        if ($line.StartsWith('[КРАСН]')) { $color = 'Red' }
        elseif ($line.StartsWith('[ЖЁЛТ]') -or $line.StartsWith('[ВНИМ]')) { $color = 'Yellow' }
        Write-Host ('  ' + $line) -ForegroundColor $color
    }
    Write-Host ("Разбор целиком: {0}" -f $reportPath)
}

#endregion
