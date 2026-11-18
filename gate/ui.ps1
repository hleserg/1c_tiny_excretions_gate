#requires -Version 5.1
# Меню и вопросы для run.ps1, deploy.ps1 и settings.ps1. Из ci.exe их рисует ci.exe (канал ниже), без него -
# меню консоли, клавишами. Скрипты подключают файл так: . (Join-Path $PSScriptRoot 'ui.ps1')
#
# Канал интерфейса ci.exe (ключ -UiChannel <папка>). Скрипт запущен из ci.exe, его вывод читает ci.exe.
# Всё, что надо показать особо, скрипт пишет строками «@@ui:{json}»: ход шага (progress, progress-end),
# заголовок в рамке (title), вопрос (one, many, confirm, text, view) с номером id. Ответ ci.exe кладёт
# в папку канала файлом a-<id>.json: {"cancel":..,"index":..,"indexes":[..],"yes":..,"text":".."}.
# Если вопрос ждёт события (закроют конфигуратор, уйдут сеансы) и оно случилось, скрипт пишет
# {"kind":"cancel","id":..} и идёт дальше. Файл stop в папке канала - просьба остановиться: скрипт
# останавливается через свою обычную обработку ошибки (trap, finally), со снятием блокировок.

$script:UiChannelDir = ''
$script:UiQuestionId = 0
$script:UiSubPlanSent = ''
$script:UiProgressSent = $null
$script:UiKeys = @('1', '2', '3', '4', '5', '6', '7', '8', '9') + @([char[]]'abcdefghijklmnopqrstuvwxyz' | ForEach-Object { [string]$_ })

function Initialize-Ui {
    # Channel - папка канала ci.exe: тогда меню и вопросы рисует ci.exe. Без него - меню консоли, клавишами.
    param([string]$Channel = '')
    if ($Channel) {
        $script:UiChannelDir = $Channel
        $script:UiAnimate = $false
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
}

function Send-UiEvent {
    # Одна строка «@@ui:{json}» в вывод скрипта: её читает ci.exe.
    param([hashtable]$Data)
    $json = ConvertTo-Json -InputObject $Data -Compress -Depth 6
    [Console]::Out.WriteLine('@@ui:' + $json)
    [Console]::Out.Flush()
}

function Send-UiPlan {
    # План прогона для ci.exe: имена шагов в том порядке, в каком они пойдут. ci.exe рисует их серым
    # и отмечает по строкам [OK]/[WARN]/[FAIL]/[SKIP]. Без ci.exe ничего не делает.
    param([string[]]$StepNames)
    if (-not $script:UiChannelDir) { return }
    Send-UiEvent @{ kind = 'plan'; steps = @($StepNames) }
}

function Send-UiSubPlan {
    # Шаги внутри длинного шага (самопроверка): ci.exe рисует их вторым трубопроводом рядом с первым.
    # Blocks - строки «сделано/всего/ОК/ошибок/внимание/пропусков|имя» (заголовок части журнала, @@block).
    # Шлётся только когда что-то поменялось. Без ci.exe ничего не делает.
    param([string]$Title, [string]$Current, [string]$Task, [string[]]$Blocks)
    if (-not $script:UiChannelDir) { return }
    $signature = $Title + '#' + $Current + '#' + $Task + '#' + ($Blocks -join ';')
    if ($signature -eq $script:UiSubPlanSent) { return }
    $script:UiSubPlanSent = $signature
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($line in $Blocks) {
        $bar = $line.IndexOf('|')
        if ($bar -lt 0) { continue }
        $numbers = @($line.Substring(0, $bar) -split '/' | ForEach-Object { $value = 0; [void][int]::TryParse($_, [ref]$value); $value })
        while ($numbers.Count -lt 6) { $numbers += 0 }
        $list.Add(@{ name = $line.Substring($bar + 1); done = $numbers[0]; total = $numbers[1]; ok = $numbers[2]; err = $numbers[3]; warn = $numbers[4]; skip = $numbers[5] })
    }
    Send-UiEvent @{ kind = 'subplan'; title = $Title; current = $Current; text = $Task; blocks = @($list.ToArray()) }
}

function Get-UiField {
    # Поле ответа ci.exe; если его нет - значение по умолчанию (StrictMode не даёт читать отсутствующее).
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Test-UiStop {
    # Просьба остановиться из ci.exe: файл stop в папке канала. Остановка - исключением, дальше trap и finally.
    if (-not $script:UiChannelDir) { return }
    $stopFile = Join-Path $script:UiChannelDir 'stop'
    if (Test-Path -LiteralPath $stopFile) {
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
        throw 'остановлено из интерфейса ci.exe'
    }
}

function Test-UiCanAsk {
    # Можно ли спросить человека: из ci.exe - всегда, иначе - если есть консоль.
    if ($script:UiChannelDir) { return $true }
    $canAsk = $false
    try { $canAsk = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected } catch { $canAsk = $false }
    return $canAsk
}

function Request-UiAnswer {
    # Вопрос в ci.exe и ожидание ответа. Poll - проверка раз в 3 секунды: вернула непустое - вопрос снимается,
    # ответ - объект с полем polled.
    param([hashtable]$Question, [scriptblock]$Poll = $null)
    $script:UiQuestionId++
    $id = $script:UiQuestionId
    $Question['id'] = $id
    $Question['poll'] = ($null -ne $Poll)
    $answerFile = Join-Path $script:UiChannelDir ("a-{0}.json" -f $id)
    if (Test-Path -LiteralPath $answerFile) { Remove-Item -LiteralPath $answerFile -Force }
    Send-UiEvent $Question
    $nextPoll = (Get-Date).AddSeconds(3)
    while ($true) {
        if (Test-Path -LiteralPath $answerFile) {
            Start-Sleep -Milliseconds 50
            $text = [System.IO.File]::ReadAllText($answerFile, [System.Text.Encoding]::UTF8)
            Remove-Item -LiteralPath $answerFile -Force -ErrorAction SilentlyContinue
            return ($text | ConvertFrom-Json)
        }
        Test-UiStop
        if ($null -ne $Poll -and (Get-Date) -ge $nextPoll) {
            $nextPoll = (Get-Date).AddSeconds(3)
            $polled = ''
            try { $polled = [string](& $Poll) } catch { $polled = '' }
            if ($polled) {
                Send-UiEvent @{ kind = 'cancel'; id = $id }
                return [pscustomobject]@{ polled = $polled }
            }
        }
        Start-Sleep -Milliseconds 200
    }
}

function Read-UiChoice {
    # Вопрос с вариантами-клавишами. Keys и Labels - параллельные массивы. Poll - как у Request-UiAnswer:
    # вернула непустое - это и есть ответ. Esc в ci.exe - CancelKey.
    # Dock - в ci.exe кнопками внизу экрана, а не окном поверх (журнал над вопросом виден); DefaultKey - на каком
    # варианте стоит выбор сразу. Danger - номера опасных вариантов (откат): в ci.exe щелчок мышью по ним
    # срабатывает только со второго раза.
    param([string]$Header, [string[]]$Keys, [string[]]$Labels, [scriptblock]$Poll = $null, [string]$CancelKey = '', [string[]]$Notes = @(),
        [switch]$Dock, [string]$DefaultKey = '', [int[]]$Danger = @())
    if ($script:UiChannelDir) {
        $question = @{ kind = 'one'; header = $Header; items = @($Labels); notes = @($Notes) }
        if ($Dock) { $question['style'] = 'dock' }
        if ($Danger.Count -gt 0) { $question['danger'] = @($Danger) }
        if ($DefaultKey) { $question['preselected'] = @([array]::IndexOf($Keys, $DefaultKey)) }
        $answer = Request-UiAnswer -Question $question -Poll $Poll
        $polled = [string](Get-UiField $answer 'polled' '')
        if ($polled) { return $polled }
        if ([bool](Get-UiField $answer 'cancel' $false)) { return $CancelKey }
        $index = [int](Get-UiField $answer 'index' -1)
        if ($index -ge 0 -and $index -lt $Keys.Count) { return $Keys[$index] }
        return $CancelKey
    }
    Write-Host ('  ' + $Header)
    foreach ($note in $Notes) { if ($note) { Write-Host ('  ' + $note) -ForegroundColor DarkGray } }
    for ($i = 0; $i -lt $Keys.Count; $i++) { Write-Host ("  {0} - {1}" -f $Keys[$i], $Labels[$i]) }
    Write-Host -NoNewline ('  Что сделать ({0}): ' -f ($Keys -join ', '))
    $nextCheck = (Get-Date).AddSeconds(3)
    while ($true) {
        if ([Console]::KeyAvailable) {
            $typed = [string]([Console]::ReadKey($true)).KeyChar
            if ($Keys -contains $typed) { Write-Host $typed; return $typed }
            continue
        }
        if ($null -ne $Poll -and (Get-Date) -ge $nextCheck) {
            $nextCheck = (Get-Date).AddSeconds(3)
            $polled = ''
            try { $polled = [string](& $Poll) } catch { $polled = '' }
            if ($polled) { Write-Host ''; return $polled }
        }
        Start-Sleep -Milliseconds 200
    }
}

function Read-UiText {
    # Строка текста. В ci.exe - поле ввода; Esc - пустая строка ($null с -CancelAsNull).
    # Default - что уже стоит в поле; Secret - ввод пароля, символы не видны.
    param([string]$Prompt, [string]$Default = '', [switch]$Secret, [switch]$CancelAsNull)
    if ($script:UiChannelDir) {
        $answer = Request-UiAnswer -Question @{ kind = 'text'; header = $Prompt; value = $Default; secret = [bool]$Secret }
        if ([bool](Get-UiField $answer 'cancel' $false)) { if ($CancelAsNull) { return $null } else { return '' } }
        return [string](Get-UiField $answer 'text' '')
    }
    if ($Secret) {
        $secure = Read-Host ('  ' + $Prompt) -AsSecureString
        return (New-Object System.Management.Automation.PSCredential('user', $secure)).GetNetworkCredential().Password
    }
    $shownPrompt = $Prompt
    if ($Default) { $shownPrompt = "{0} [Enter - оставить «{1}», - - очистить]" -f $Prompt, $Default }
    $typed = [string](Read-Host ('  ' + $shownPrompt))
    if ($Default -and $typed -eq '') { return $Default }
    if ($Default -and $typed -eq '-') { return '' }
    return $typed
}

function Show-UiTitle {
    # Заголовок в рамке. Kind: info, ok, warn, bad.
    param([string]$Text, [string]$Kind = 'info', [string[]]$More = @())
    if ($script:UiChannelDir) { Send-UiEvent @{ kind = 'title'; style = $Kind; text = $Text; more = @($More | Where-Object { $_ }) }; return }
    $hostColors = @{ info = 'Cyan'; ok = 'Green'; warn = 'Yellow'; bad = 'Red' }
    Write-Host ''
    Write-Host $Text -ForegroundColor $hostColors[$Kind]
    foreach ($line in $More) { if ($line) { Write-Host ('  ' + $line) } }
}

function Get-UiKeyIndex {
    # Номер пункта по нажатой клавише (1-9, потом a-z); -1 - не клавиша пункта. В русской раскладке
    # буква берётся по самой клавише (ф - это a), как в ci.exe.
    param([System.ConsoleKeyInfo]$KeyInfo)
    $index = [array]::IndexOf($script:UiKeys, ([string]$KeyInfo.KeyChar).ToLowerInvariant())
    if ($index -lt 0) {
        $keyName = ([string]$KeyInfo.Key).ToLowerInvariant()
        if ($keyName.Length -eq 1) { $index = [array]::IndexOf($script:UiKeys, $keyName) }
    }
    return $index
}

function Select-UiOne {
    # Один пункт из списка. Возвращает номер пункта (с нуля) или -1, если выбор отменили (Esc, 0).
    # Danger - номера опасных пунктов (откат рабочей): в ci.exe они в красной рамке с ▲!, в консоли - красные, с «!!!».
    param([string]$Header, [string[]]$Items, [string[]]$Notes = @(), [int[]]$Danger = @())
    if ($Items.Count -eq 0) { return -1 }
    if ($script:UiChannelDir) {
        $answer = Request-UiAnswer -Question @{ kind = 'one'; header = $Header; items = @($Items); notes = @($Notes | Where-Object { $_ }); danger = @($Danger) }
        if ([bool](Get-UiField $answer 'cancel' $false)) { return -1 }
        $index = [int](Get-UiField $answer 'index' -1)
        if ($index -ge 0 -and $index -lt $Items.Count) { return $index }
        return -1
    }
    $shownItems = @(for ($i = 0; $i -lt $Items.Count; $i++) { if ($Danger -contains $i) { '!!! ' + $Items[$i] + ' !!!' } else { $Items[$i] } })
    Write-Host ''
    Write-Host ('  ' + $Header)
    foreach ($note in $Notes) { if ($note) { Write-Host ('  ' + $note) -ForegroundColor DarkGray } }
    $shown = [Math]::Min($Items.Count, $script:UiKeys.Count)
    for ($i = 0; $i -lt $shown; $i++) {
        if ($Danger -contains $i) { Write-Host ("    {0} - {1}" -f $script:UiKeys[$i], $shownItems[$i]) -ForegroundColor Red }
        else { Write-Host ("    {0} - {1}" -f $script:UiKeys[$i], $shownItems[$i]) }
    }
    Write-Host '    0 - отмена'
    Write-Host -NoNewline '  Выбор: '
    while ($true) {
        $keyInfo = [Console]::ReadKey($true)
        if ([string]$keyInfo.KeyChar -eq '0') { Write-Host '0'; return -1 }
        $index = Get-UiKeyIndex $keyInfo
        if ($index -ge 0 -and $index -lt $shown) { Write-Host $script:UiKeys[$index]; return $index }
    }
}

function Select-UiMany {
    # Несколько пунктов. Возвращает номера отмеченных (с нуля); $null - отмена. Пустой выбор не принимается.
    # Groups - на каждый пункт имена расширений через «|»: пункты с общим именем взаимоисключающие, отметка
    # одного снимает отметку с другого (в ci.exe и в консоли).
    param([string]$Header, [string[]]$Items, [int[]]$Preselected = @(), [string[]]$Notes = @(), [string[]]$Groups = @())
    if ($Items.Count -eq 0) { return $null }
    if ($script:UiChannelDir) {
        $question = @{ kind = 'many'; header = $Header; items = @($Items); preselected = @($Preselected); notes = @($Notes | Where-Object { $_ }) }
        if ($Groups.Count -eq $Items.Count) { $question['groups'] = @($Groups) }
        $answer = Request-UiAnswer -Question $question
        if ([bool](Get-UiField $answer 'cancel' $false)) { return $null }
        $picked = @(@(Get-UiField $answer 'indexes' @()) | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 0 -and $_ -lt $Items.Count } | Sort-Object -Unique)
        if ($picked.Count -eq 0) { return $null }
        return [int[]]$picked
    }
    $shown = [Math]::Min($Items.Count, $script:UiKeys.Count)
    $marks = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($index in $Preselected) { if ($index -ge 0 -and $index -lt $shown) { $null = $marks.Add($index) } }
    while ($true) {
        Write-Host ''
        Write-Host ('  ' + $Header)
        foreach ($note in $Notes) { if ($note) { Write-Host ('  ' + $note) -ForegroundColor DarkGray } }
        Write-Host '  Клавиша ставит и снимает отметку, Enter - старт, 0 - отмена:'
        for ($i = 0; $i -lt $shown; $i++) {
            $box = '[ ]'
            if ($marks.Contains($i)) { $box = '[x]' }
            Write-Host ("    {0} {1} {2}" -f $script:UiKeys[$i], $box, $Items[$i])
        }
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) {
            if ($marks.Count -gt 0) { return [int[]]@($marks | Sort-Object) }
            Write-Host '  Ничего не отмечено.' -ForegroundColor Yellow
            continue
        }
        if ([string]$key.KeyChar -eq '0') { return $null }
        $index = Get-UiKeyIndex $key
        if ($index -lt 0 -or $index -ge $shown) { continue }
        if ($marks.Contains($index)) { $null = $marks.Remove($index); continue }
        if ($Groups.Count -eq $Items.Count -and $Groups[$index]) {
            $mine = @($Groups[$index] -split '\|' | Where-Object { $_ })
            foreach ($other in @($marks)) {
                $theirs = @($Groups[$other] -split '\|' | Where-Object { $_ })
                if (@($mine | Where-Object { $theirs -contains $_ }).Count -gt 0) {
                    $null = $marks.Remove($other)
                    Write-Host ("  снято: {0} - у расширения одно обновление" -f $Items[$other]) -ForegroundColor DarkYellow
                }
            }
        }
        $null = $marks.Add($index)
    }
}

function Wait-UiAcknowledge {
    # Результат действия выведен - ждать, пока человек его посмотрит, и только потом снова меню. Общее правило:
    # после вывода меню не открывается само. В ci.exe - кнопка внизу экрана (журнал над ней листается),
    # в консоли - любая клавиша. Без человека (ночной запуск) - не ждать.
    param([string]$Label = 'Вернуться в меню')
    if (-not (Test-UiCanAsk)) { return }
    if ($script:UiChannelDir) {
        $null = Read-UiChoice -Header 'Результат - выше, журнал листается. Посмотрел?' -Keys @('1') -Labels @($Label) -CancelKey '1' -Dock
        return
    }
    Write-Host ''
    Write-Host ('  -- любая клавиша: {0} --' -f $Label.ToLower()) -ForegroundColor DarkGray
    $null = [Console]::ReadKey($true)
}

function Confirm-Ui {
    # Да или нет. Возвращает $true, $false или $null (отмена: Esc в ci.exe).
    # DangerYes - «да» опасно (откат): в ci.exe щелчок мышью по нему срабатывает только со второго раза.
    param([string]$Question, [string]$Yes = 'Да', [string]$No = 'Нет', [switch]$DangerYes)
    if ($script:UiChannelDir) {
        $question = @{ kind = 'confirm'; header = $Question; yes = $Yes; no = $No }
        if ($DangerYes) { $question['danger'] = @(0) }
        $answer = Request-UiAnswer -Question $question
        if ([bool](Get-UiField $answer 'cancel' $false)) { return $null }
        return [bool](Get-UiField $answer 'yes' $false)
    }
    Write-Host ''
    Write-Host ('  ' + $Question)
    Write-Host ("    1 - {0}" -f $Yes)
    Write-Host ("    2 - {0}" -f $No)
    Write-Host -NoNewline '  Выбор: '
    while ($true) {
        $typed = [string]([Console]::ReadKey($true)).KeyChar
        if ($typed -eq '1') { Write-Host '1'; return $true }
        if ($typed -eq '2') { Write-Host '2'; return $false }
    }
}

function Show-UiPager {
    # Длинный текст: в ci.exe - окно с прокруткой, в консоли - страницами.
    param([string[]]$Lines, [string]$Header = '')
    if ($script:UiChannelDir) { $null = Request-UiAnswer -Question @{ kind = 'view'; header = $Header; lines = @($Lines) }; return }
    $pageSize = 40
    try { $pageSize = [Math]::Max(10, [Console]::WindowHeight - 3) } catch { $pageSize = 40 }
    Write-Host ''
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        $color = 'Gray'
        if ($line.Contains('[КРАСН]')) { $color = 'Red' }
        elseif ($line.Contains('[ЖЁЛТ]') -or $line.Contains('[ВНИМ]')) { $color = 'Yellow' }
        elseif ($line -eq 'КОРОТКО' -or $line -match '^[А-ЯЁ ,()-]{6,}$') { $color = 'Cyan' }
        Write-Host $line -ForegroundColor $color
        if (($i + 1) % $pageSize -eq 0 -and $i + 1 -lt $Lines.Count) {
            Write-Host ("  -- строки {0} из {1}: любая клавиша - дальше, 0 - хватит --" -f ($i + 1), $Lines.Count) -ForegroundColor DarkGray
            if ([string]([Console]::ReadKey($true)).KeyChar -eq '0') { return }
        }
    }
    Write-Host '  -- конец, любая клавиша --' -ForegroundColor DarkGray
    $null = [Console]::ReadKey($true)
}

# ---------------------------------------------------------------------------------------------------------------
# Строка хода длинной операции. Одна строка перерисовывается на месте (возврат каретки), раз в 250 мс:
#  - известно, сколько сделано (задания самопроверки) - настоящая полоса и процент;
#  - известно, сколько шаг шёл в прошлых прогонах - полоса по времени, со знаком «~»;
#  - ничего не известно или шаг идёт дольше обычного - бегающий блок туда-обратно.
# По полосе всё время бегает блик: даже когда процент не меняется, видно, что скрипт жив.
# Символы - блоки ░▒▓█: они есть в Consolas и в шрифтах консоли по умолчанию.
# Если вывод перенаправлен в файл, анимации нет: строка раз в минуту.

$script:UiTick = 0
$script:UiLastMinuteLine = -1
$script:UiAnimate = $true
try { $script:UiAnimate = -not [Console]::IsOutputRedirected } catch { $script:UiAnimate = $false }
$script:UiIdleCaptions = @('конфигуратор работает', 'SQL шуршит', 'сервер 1С занят делом', 'платформа думает', 'ещё немного')

function Format-UiDuration {
    param([double]$Seconds)
    $span = [TimeSpan]::FromSeconds([Math]::Max(0, [Math]::Round($Seconds)))
    if ($span.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds) }
    return ('{0}:{1:00}' -f $span.Minutes, $span.Seconds)
}

function Get-UiRunRemaining {
    # Сколько осталось всего прогона, секунд (-1 - неизвестно), и сколько оставшихся шагов без статистики.
    # Считает скрипт, который подключил ui.ps1, своей функцией Get-RunRemainingSeconds; её нет - неизвестно.
    param([string]$Title, [double]$Elapsed, [double]$Expected)
    $unknownResult = [pscustomobject]@{ Seconds = -1; Unknown = 0 }
    if (-not (Get-Command -Name 'Get-RunRemainingSeconds' -CommandType Function -ErrorAction SilentlyContinue)) { return $unknownResult }
    try { return (Get-RunRemainingSeconds -Title $Title -Elapsed $Elapsed -Expected $Expected) } catch { return $unknownResult }
}

function Write-UiProgress {
    # Title - что идёт; Elapsed - секунд с начала; Expected - сколько шло обычно (0 - неизвестно);
    # Done и Total - сделано и всего (Total 0 - неизвестно); Detail - что именно сейчас.
    param([string]$Title, [double]$Elapsed, [double]$Expected = 0, [int]$Done = -1, [int]$Total = 0, [string]$Detail = '')
    if ($script:UiChannelDir) {
        Test-UiStop
        # ci.exe рисует сам; строка - не чаще раза в секунду или когда поменялись шаг, задание, пояснение.
        $now = Get-Date
        $key = '{0}|{1}|{2}' -f $Title, $Done, $Detail
        if ($null -eq $script:UiProgressSent -or $script:UiProgressSent.Key -ne $key -or ($now - $script:UiProgressSent.Time).TotalSeconds -ge 1) {
            # Сколько осталось всего прогона - считает скрипт, если умеет (run.ps1: Get-RunRemainingSeconds).
            $uiRemaining = Get-UiRunRemaining -Title $Title -Elapsed $Elapsed -Expected $Expected
            Send-UiEvent @{ kind = 'progress'; title = $Title; elapsed = [int]$Elapsed; expected = [int]$Expected; done = $Done; total = $Total; detail = $Detail
                remaining = [int]$uiRemaining.Seconds; remainingUnknown = [int]$uiRemaining.Unknown }
            $script:UiProgressSent = @{ Key = $key; Time = $now }
        }
        return
    }
    if (-not $script:UiAnimate) {
        $minute = [int][Math]::Floor($Elapsed / 60)
        if ($minute -gt $script:UiLastMinuteLine) {
            $script:UiLastMinuteLine = $minute
            $text = '       {0}: идёт {1}' -f $Title, (Format-UiDuration $Elapsed)
            if ($Total -gt 0 -and $Done -ge 0) { $text += (', {0} из {1}' -f $Done, $Total) }
            if ($Detail) { $text += (', ' + $Detail) }
            $uiRemaining = Get-UiRunRemaining -Title $Title -Elapsed $Elapsed -Expected $Expected
            if ($uiRemaining.Seconds -ge 0) { $text += ('; весь прогон - ещё ~{0}' -f (Format-UiDuration $uiRemaining.Seconds)) }
            Write-Host $text
        }
        return
    }
    $script:UiTick++
    $width = 24
    $cells = New-Object char[] $width
    $color = 'Cyan'
    $percent = '    '
    $timeText = Format-UiDuration $Elapsed
    $caption = $Detail

    if ($Total -gt 0 -and $Done -ge 0) {
        $fraction = [Math]::Min(1.0, [double]$Done / $Total)
        $filled = [int][Math]::Floor($fraction * $width)
        for ($i = 0; $i -lt $width; $i++) { if ($i -lt $filled) { $cells[$i] = [char]0x2588 } else { $cells[$i] = [char]0x2591 } }
        $percent = ('{0,3}%' -f [int][Math]::Floor($fraction * 100))
        $color = 'Green'
        if ($Expected -gt 0) { $timeText += (' / ~' + (Format-UiDuration $Expected)) }
    }
    elseif ($Expected -gt 0 -and $Elapsed -lt $Expected) {
        $fraction = [Math]::Min(0.99, $Elapsed / $Expected)
        $filled = [int][Math]::Floor($fraction * $width)
        for ($i = 0; $i -lt $width; $i++) { if ($i -lt $filled) { $cells[$i] = [char]0x2588 } else { $cells[$i] = [char]0x2591 } }
        $percent = ('~{0,2}%' -f [int][Math]::Floor($fraction * 100))
        $timeText += (' / ~' + (Format-UiDuration $Expected))
    }
    else {
        # Бегающий блок: ▒▓█▓▒ ходит по дорожке туда и обратно.
        for ($i = 0; $i -lt $width; $i++) { $cells[$i] = [char]0x2591 }
        $span = $width + 1
        $step = $script:UiTick % (2 * $span)
        $center = $step
        if ($step -gt $span) { $center = 2 * $span - $step }
        $center = $center - 1
        $shape = @([char]0x2592, [char]0x2593, [char]0x2588, [char]0x2593, [char]0x2592)
        for ($k = 0; $k -lt 5; $k++) {
            $position = $center - 2 + $k
            if ($position -ge 0 -and $position -lt $width) { $cells[$position] = $shape[$k] }
        }
        if ($Expected -gt 0) {
            $timeText += (', обычно ~' + (Format-UiDuration $Expected))
            $color = 'Yellow'
        }
        if (-not $caption) { $caption = $script:UiIdleCaptions[[int][Math]::Floor($script:UiTick / 40) % $script:UiIdleCaptions.Count] }
    }

    # Блик по заполненной части полосы: видно движение, даже когда процент стоит.
    $filledCount = 0
    for ($i = 0; $i -lt $width; $i++) { if ($cells[$i] -eq [char]0x2588) { $filledCount++ } }
    if ($filledCount -gt 0 -and $filledCount -lt $width -or ($Total -gt 0 -and $filledCount -gt 0)) {
        $glint = $script:UiTick % ($filledCount + 6)
        if ($glint -lt $filledCount) { $cells[$glint] = [char]0x2593 }
    }

    $line = '  [{0}] {1} {2}  {3}' -f (New-Object string($cells, 0, $width)), $percent, $Title, $timeText
    if ($caption) { $line += ('  ' + $caption) }
    $max = 119
    try { $max = [Math]::Max(40, [Console]::WindowWidth - 1) } catch { $max = 119 }
    if ($line.Length -gt $max) { $line = $line.Substring(0, $max) }
    Write-Host ("`r" + $line.PadRight($max)) -NoNewline -ForegroundColor $color
}

function Complete-UiProgress {
    # Убирает строку хода: дальше скрипт печатает итог шага.
    if ($script:UiChannelDir) {
        if ($null -ne $script:UiProgressSent) { Send-UiEvent @{ kind = 'progress-end' } }
        $script:UiProgressSent = $null
        return
    }
    if (-not $script:UiAnimate) { $script:UiLastMinuteLine = -1; return }
    $max = 119
    try { $max = [Math]::Max(40, [Console]::WindowWidth - 1) } catch { $max = 119 }
    Write-Host ("`r" + (' ' * $max) + "`r") -NoNewline
    $script:UiLastMinuteLine = -1
}

function Wait-UiProcess {
    # Ждёт процесс до $TimeoutSec, рисуя строку хода. Возвращает $true, если процесс завершился сам.
    param($Process, [System.Diagnostics.Stopwatch]$Watch, [int]$TimeoutSec, [string]$Title, [double]$Expected = 0)
    while ($true) {
        if ($Process.WaitForExit(250)) { Complete-UiProgress; return $true }
        if ($Watch.Elapsed.TotalSeconds -ge $TimeoutSec) { Complete-UiProgress; return $false }
        if ($Title) { Write-UiProgress -Title $Title -Elapsed $Watch.Elapsed.TotalSeconds -Expected $Expected }
    }
}
