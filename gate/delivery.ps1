#requires -Version 5.1
<#
Приёмка поставок подрядчика (раздел 5.25 руководства). Подключается точкой из deploy.ps1 (-Delivery): пользуется его
функциями temp и git (Get-TempSnapshot, Compare-GitSnapshot, New-GitTempBranch, Invoke-GitImport), конфигуратором
(Invoke-V8), агентом кластера и блокировками (locks.ps1).

Один сценарий: файл .cfe, .epf, .erf или папка комплекта во «Входящих» (DeliveryInboxDir) ->
  1. реестр: оригинал, SHA-256 каждого файла, повторная подача того же набора - та же поставка;
  2. разбор в технической базе (DeliveryTechBase: файловая база с основной конфигурацией temp) штатным
     конфигуратором: расширение - /LoadCfg и /DumpConfigToFiles, обработка и отчёт - /DumpExternalDataProcessorOrReportToFiles;
     фактический тип - по выгрузке, а не по расширению файла;
  3. сопоставление: расширение - по UUID и имени из Configuration.xml, обработка - по имени объекта, карточкам
     справочника temp и подтверждённым привязкам deliveries/bindings.json; две карточки - один вопрос, ответ запоминается;
  4. temp: правки после последней синхронизации с git - штатно веткой и PR (открытый PR выгрузки продолжается);
     при DeliveryAutoMerge - CI и слияние через merge_checked.py, дальше - поверх них;
  5. объединение merge1c поверх main: процедуры, объекты метаданных по UUID, права, формы; доказательства - история
     main и прежних поставок, отклонённые правки; спорное - вопрос с одним выбором;
  6. сборка и проверка применимости объединённого в технической базе;
  7. коммит в ветку delivery/<номер>, PR в main с отчётом (без дублей), журнал поставки deliveries/<номер>.json;
  8. CI для точного merge SHA; main сдвинулся - пересборка кандидата и новый CI;
  9. применение под блокировкой начала сеансов temp: нет конфигураторов, temp не менялся с основы, слияние
     merge_checked.py (DeliveryAutoMerge) или ожидание слияния человеком, «Загрузить из git» именно этого SHA, гейт;
 10. цепочка в журнале и отчёте: хеши -> изменения -> PR -> SHA -> загруженные объекты и карточки -> прогон и вердикт.
Каждый этап повторяем: перезапуск после сбоя начинает с проверки фактического состояния, PR и карточки не множатся.
Выпуск в рабочую - отдельно (deploy), здесь рабочая не трогается.
#>

#region Настройки, реестр, журнал

# Блокировка начала сеансов temp на время применения (Lock-DeliveryTemp); снимается в конце прохода в любом случае.
$script:DeliveryTempLock = $null

function Get-DeliverySetup {
    $root = Resolve-RootPath ([string](Get-Setting $cfg 'DeliveryDir' 'deliveries'))
    $inbox = Resolve-RootPath ([string](Get-Setting $cfg 'DeliveryInboxDir' 'Входящие'))
    $oldInbox = Resolve-RootPath ([string](Get-Setting $cfg 'InboxDir' 'inbox'))
    if ([System.IO.Path]::GetFullPath($inbox).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($oldInbox).TrimEnd('\')) {
        throw ("DeliveryInboxDir и InboxDir - одна папка ({0}): поставки для приёмки и обновления для прямой загрузки должны лежать отдельно" -f $inbox)
    }
    $tech = Resolve-RootPath ([string](Get-Setting $cfg 'DeliveryTechBase' 'deliveries\tech-stand'))
    $techName = Split-Path -Leaf $tech
    if ($techName -notmatch $TestBasePattern) { throw ("техническая база {0}: имя папки должно быть похоже на тестовую (stand, test, temp и т. п.)" -f $tech) }
    foreach ($name in @(Get-Setting $cfg 'ForbiddenBases' @() | Where-Object { $_ })) {
        if ($techName -ieq [string]$name) { throw ("техническая база {0} в списке запрещённых (ForbiddenBases)" -f $tech) }
    }
    foreach ($dir in @($root, $inbox, (Join-Path $root 'history\blobs'))) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return [pscustomobject]@{
        Root = $root; Inbox = $inbox; Tech = $tech
        Merge = (Resolve-RootPath ([string](Get-Setting $cfg 'DeliveryMergeExe' 'merge1c.exe')))
        AutoMerge = [bool](Get-Setting $cfg 'DeliveryAutoMerge' $false)
        Python = [string](Get-Setting $cfg 'DeliveryPython' 'python')
        MergeCheckedPath = [string](Get-Setting $cfg 'DeliveryMergeChecked' 'ci/merge_checked.py')
        MergeCheckedBlob = ([string](Get-Setting $cfg 'DeliveryMergeCheckedBlob' '')).ToLowerInvariant()
        Workflow = [string](Get-Setting $cfg 'DeliveryCiWorkflow' '.github/workflows/erp-static.yml')
        CiWaitSec = 60 * [int](Get-Setting $cfg 'DeliveryCiWaitMin' 30)
        SettleSec = [int](Get-Setting $cfg 'DeliverySettleSec' 15)
        HistoryCommits = [int](Get-Setting $cfg 'DeliveryHistoryCommits' 300)
        Journal = (Join-Path $root 'journal.jsonl')
        History = (Join-Path $root 'history\index.jsonl')
        Blobs = (Join-Path $root 'history\blobs')
    }
}

function ConvertTo-DeliveryData {
    # Объект из ConvertFrom-Json -> упорядоченные таблицы и массивы: с ними удобно и под StrictMode.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $table = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $table[$property.Name] = ConvertTo-DeliveryData $property.Value }
        return $table
    }
    if ($Value -is [System.Array]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$list.Add((ConvertTo-DeliveryData $item)) }
        return , $list.ToArray()
    }
    return $Value
}

function Read-DeliveryState {
    param($D, [string]$Id)
    $path = Join-Path (Join-Path $D.Root $Id) 'state.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    return (ConvertTo-DeliveryData (ConvertFrom-Json -InputObject $text))
}

function Save-DeliveryState {
    param($D, $State)
    $State['updated'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $dir = Join-Path $D.Root ([string]$State['id'])
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir 'state.json'
    [System.IO.File]::WriteAllText($path + '.tmp', (ConvertTo-Json -InputObject $State -Depth 20), $Utf8Bom)
    Move-Item -LiteralPath ($path + '.tmp') -Destination $path -Force
}

function Write-DeliveryEvent {
    # Строка в журнал поставок (deliveries\journal.jsonl), в историю поставки и на экран.
    param($D, $State, [string]$Event, [string]$Text, [string]$Color = 'Gray')
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $record = [ordered]@{ time = $stamp; id = [string]$State['id']; event = $Event; text = $Text }
    [System.IO.File]::AppendAllText($D.Journal, ((ConvertTo-Json -InputObject $record -Compress) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    $events = @()
    if ($null -ne $State['events']) { $events = @($State['events']) }
    $events += [ordered]@{ time = $stamp; event = $Event; text = $Text }
    if ($events.Count -gt 300) { $events = @($events | Select-Object -Last 300) }
    $State['events'] = $events
    Write-Line ("  [{0}] {1}" -f [string]$State['id'], $Text) $Color
}

function Set-DeliveryStatus {
    # Статус поставки: received, waiting-temp, waiting-decision, merged, built, pr, ci, waiting-merge, loading,
    # done; итог - verdict (GREEN, YELLOW, RED, PARTIAL, UNCHANGED, FAILED).
    param($D, $State, [string]$Status, [string]$Note = '')
    $State['status'] = $Status
    $State['note'] = $Note
    Save-DeliveryState $D $State
    Update-DeliveryOpenList $D
}

function Update-DeliveryOpenList {
    # deliveries\open.txt - поставки в работе (для меню гейта).
    param($D)
    $open = New-Object System.Collections.Generic.List[string]
    foreach ($dir in @(Get-ChildItem -LiteralPath $D.Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}-[0-9a-f]{6}$' } | Sort-Object Name)) {
        $state = Read-DeliveryState $D $dir.Name
        if ($null -ne $state -and [string]$state['status'] -ne 'done') { $open.Add(("{0}`t{1}" -f $dir.Name, [string]$state['status'])) }
    }
    [System.IO.File]::WriteAllLines((Join-Path $D.Root 'open.txt'), [string[]]$open.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-DeliverySha256 {
    param([string]$Path)
    return (Get-GitFileSha256 $Path)
}

#endregion

#region «Входящие»: приём

function Get-DeliveryEntryFiles {
    # Файлы поставки в элементе «Входящих»: файл или все файлы папки (с подпапками). .zip распаковывается рядом
    # (в Expand). Rel - путь от элемента, Kind - по расширению файла (cfe, epf, erf, other).
    param([string]$Path, [string]$Expand)
    $list = New-Object System.Collections.Generic.List[object]
    $item = Get-Item -LiteralPath $Path
    $files = @()
    $base = ''
    if ($item.PSIsContainer) {
        $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName)
        $base = $item.FullName.TrimEnd('\')
    }
    else {
        $files = @($item)
        $base = $item.DirectoryName.TrimEnd('\')
    }
    foreach ($file in $files) {
        $rel = $file.FullName.Substring($base.Length + 1)
        $ext = $file.Extension.ToLowerInvariant()
        if ($ext -eq '.zip') {
            $target = Join-Path $Expand ([System.IO.Path]::GetFileNameWithoutExtension($file.Name))
            if (-not (Test-Path -LiteralPath $target)) {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($file.FullName, $target, [System.Text.Encoding]::GetEncoding(866))
            }
            foreach ($inner in @(Get-DeliveryEntryFiles -Path $target -Expand (Join-Path $Expand 'zip'))) {
                $inner.Rel = $rel + '!' + $inner.Rel
                $list.Add($inner)
            }
            continue
        }
        $kind = 'other'
        if ($ext -eq '.cfe') { $kind = 'cfe' } elseif ($ext -eq '.epf') { $kind = 'epf' } elseif ($ext -eq '.erf') { $kind = 'erf' }
        $list.Add([pscustomobject]@{ Rel = $rel; Full = $file.FullName; Kind = $kind; Size = [long]$file.Length; Sha = '' })
    }
    return $list.ToArray()
}

function Test-DeliverySettled {
    # Элемент «Входящих» докопирован: давно не менялся и файлы открываются без совместного доступа.
    param($D, $Item)
    $files = @($Item)
    if ($Item.PSIsContainer) { $files = @(Get-ChildItem -LiteralPath $Item.FullName -Recurse -File) }
    if ($files.Count -eq 0) { return $false }
    foreach ($file in $files) {
        if (((Get-Date) - $file.LastWriteTime).TotalSeconds -lt $D.SettleSec) { return $false }
        try { $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'None'); $stream.Dispose() }
        catch { return $false }
    }
    return $true
}

function Find-DeliveryBySet {
    param($D, [string]$SetHash)
    $index = Join-Path $D.Root 'sets.txt'
    if (-not (Test-Path -LiteralPath $index)) { return '' }
    foreach ($line in [System.IO.File]::ReadAllLines($index)) {
        $parts = $line.Split("`t")
        if ($parts.Count -ge 2 -and $parts[0] -eq $SetHash -and (Test-Path -LiteralPath (Join-Path (Join-Path $D.Root $parts[1]) 'state.json'))) { return $parts[1] }
    }
    return ''
}

function Receive-DeliveryEntry {
    # Элемент «Входящих» -> поставка в реестре. Тот же набор файлов (по SHA-256, имена не важны) - та же поставка:
    # копия уходит в её duplicates, новой поставки нет. Возвращает номер поставки или '' (ещё не докопировано).
    param($D, $Item)
    if (-not (Test-DeliverySettled $D $Item)) { Write-Line ("  {0}: ещё копируется, возьму в следующий раз" -f $Item.Name) 'DarkGray'; return '' }
    $scratch = Join-Path $D.Root ('incoming-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $files = @(Get-DeliveryEntryFiles -Path $Item.FullName -Expand $scratch)
    foreach ($file in $files) { $file.Sha = Get-DeliverySha256 $file.Full }
    $usable = @($files | Where-Object { $_.Kind -ne 'other' })
    $setHash = (Get-GitFileSha256Text (@($usable | ForEach-Object { $_.Sha } | Sort-Object) -join "`n"))
    if ($usable.Count -eq 0) {
        Write-Line ("  {0}: нет ни .cfe, ни .epf, ни .erf - не поставка; оставляю во «Входящих»" -f $Item.Name) 'Yellow'
        if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
        return ''
    }
    $existing = Find-DeliveryBySet $D $setHash
    if ($existing) {
        $state = Read-DeliveryState $D $existing
        $dupDir = Join-Path (Join-Path (Join-Path $D.Root $existing) 'duplicates') (Get-Date -Format 'yyyyMMdd-HHmmss')
        New-Item -ItemType Directory -Path $dupDir -Force | Out-Null
        Move-Item -LiteralPath $Item.FullName -Destination $dupDir
        if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
        Write-DeliveryEvent $D $state 'duplicate' ("повторная подача того же набора ({0}): это поставка {1}, статус {2}; новой поставки и PR нет" -f $Item.Name, $existing, [string]$state['status']) 'Yellow'
        Save-DeliveryState $D $state
        return $existing
    }
    $id = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $setHash.Substring(0, 6)
    $dir = Join-Path $D.Root $id
    $original = Join-Path $dir 'original'
    New-Item -ItemType Directory -Path $original -Force | Out-Null
    # Оригинал - копией с проверкой хешей, из «Входящих» - только после неё.
    Copy-Item -LiteralPath $Item.FullName -Destination $original -Recurse -Force
    $stored = Join-Path $original $Item.Name
    $storedFiles = @(Get-DeliveryEntryFiles -Path $stored -Expand (Join-Path $dir 'expanded'))
    foreach ($file in $storedFiles) { $file.Sha = Get-DeliverySha256 $file.Full }
    foreach ($file in $usable) {
        $copy = @($storedFiles | Where-Object { $_.Rel -eq $file.Rel }) | Select-Object -First 1
        if ($null -eq $copy -or $copy.Sha -ne $file.Sha) { throw ("копия {0} в реестре поставок не совпала по SHA-256: из «Входящих» не убираю" -f $file.Rel) }
    }
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
    $records = @()
    foreach ($file in @($storedFiles | Where-Object { $_.Kind -ne 'other' })) {
        $records += [ordered]@{
            name = (Split-Path -Leaf ($file.Rel -replace '!', '\')); rel = $file.Rel; path = $file.Full; sha256 = $file.Sha; size = $file.Size
            kind = $file.Kind; actualKind = ''; status = 'received'; object = $null; dump = ''; opaque = $false; opaqueReason = ''; identity = $null
        }
    }
    $other = @($storedFiles | Where-Object { $_.Kind -eq 'other' } | ForEach-Object { $_.Rel })
    $state = [ordered]@{
        id = $id; received = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); source = $Item.Name; setHash = $setHash
        status = 'received'; note = ''; verdict = ''; files = $records; other = $other; base = $null; drift = $null
        merge = $null; build = $null; pr = $null; ci = $null; merged = $null; load = $null; objects = @(); events = @(); decisions = [ordered]@{}
    }
    Save-DeliveryState $D $state
    [System.IO.File]::AppendAllText((Join-Path $D.Root 'sets.txt'), ("{0}`t{1}`r`n" -f $setHash, $id), (New-Object System.Text.UTF8Encoding($false)))
    $removed = $true
    try { Remove-Item -LiteralPath $Item.FullName -Recurse -Force }
    catch { $removed = $false; Write-RunLog ("Входящие: {0} не убран: {1}" -f $Item.FullName, $_.Exception.Message) }
    $list = @($records | ForEach-Object { '{0} (sha256 {1})' -f $_['name'], ([string]$_['sha256']).Substring(0, 12) }) -join ', '
    Write-DeliveryEvent $D $state 'received' ("получено из «Входящих» {0}: {1}" -f $Item.Name, $list) 'Cyan'
    if ($other.Count -gt 0) { Write-DeliveryEvent $D $state 'other' ("не поставка, сохранено как есть: {0}" -f ($other -join ', ')) 'Yellow' }
    if (-not $removed) { Write-DeliveryEvent $D $state 'inbox' 'из «Входящих» не убралось (занято): при следующем проходе это будет повторная подача' 'Yellow' }
    Save-DeliveryState $D $state
    Update-DeliveryOpenList $D
    return $id
}

function Get-GitFileSha256Text {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join @($sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}

#endregion

#region Техническая база

function Invoke-TechDesigner {
    # Пакетный конфигуратор технической базы (файловая, без пользователей).
    param($D, [string[]]$Command, [string]$LogName, [int]$TimeoutSec, [string]$Title = '')
    $logPath = Join-Path $script:RunDir $LogName
    if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }
    $argList = @('DESIGNER', ('/F"{0}"' -f $D.Tech), '/DisableStartupDialogs', '/DisableStartupMessages') + $Command + @('/Out', ('"{0}"' -f $logPath))
    $result = Invoke-V8 -Exe $script:V8 -Arguments $argList -TimeoutSec $TimeoutSec -Title $Title
    $lines = @(Read-V8Log $logPath)
    return [pscustomobject]@{ ExitCode = $result.ExitCode; TimedOut = $result.TimedOut; Log = $logPath; Text = (($lines | Where-Object { $_ }) -join ' ') }
}

function Initialize-TechBase {
    # Техническая база для разбора поставок: пустая файловая база с основной конфигурацией temp. Создаётся при первой
    # поставке и после обновления типовой (версия - в <база>.json). В temp не пишет: оттуда только /DumpCfg.
    param($D)
    $marker = $D.Tech.TrimEnd('\') + '.json'
    $info = Get-ComConfigInfo -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword
    $version = ''
    if ($info.Ok) { $version = '{0} {1}' -f $info.Name, $info.Version }
    if ((Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath $D.Tech)) {
        $known = ConvertTo-DeliveryData ([System.IO.File]::ReadAllText($marker, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json)
        if (-not $version -or [string]$known['config'] -eq $version) { return [pscustomobject]@{ Ok = $true; Note = ('техническая база готова: ' + [string]$known['config']) } }
        Write-Line ("  техническая база на {0}, а temp на {1}: пересоздаю" -f $known['config'], $version) 'Yellow'
    }
    if (Test-Path -LiteralPath $D.Tech) { Remove-Item -LiteralPath $D.Tech -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $D.Tech) -Force | Out-Null
    $cf = Join-Path $script:RunDir 'tech-config.cf'
    $dump = Invoke-Designer -BaseName $script:TempBase -Command @('/DumpCfg', ('"{0}"' -f $cf)) -LogName 'tech_dumpcfg.log' -TimeoutSec $timeoutLoadSec -Title ('Основная конфигурация {0} в файл' -f $script:TempBase)
    if ($dump.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $cf)) { return [pscustomobject]@{ Ok = $false; Note = ('основная конфигурация temp не выгрузилась: ' + $dump.Text) } }
    $createLog = Join-Path $script:RunDir 'tech_create.log'
    $created = Invoke-V8 -Exe $script:V8 -Arguments @('CREATEINFOBASE', ('File="{0}"' -f $D.Tech), '/Out', ('"{0}"' -f $createLog)) -TimeoutSec 600 -Title 'Создать техническую базу'
    if ($created.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Note = ('техническая база не создалась: ' + ((@(Read-V8Log $createLog) | Where-Object { $_ }) -join ' ')) } }
    $load = Invoke-TechDesigner -D $D -Command @('/LoadCfg', ('"{0}"' -f $cf)) -LogName 'tech_loadcfg.log' -TimeoutSec $timeoutLoadSec -Title 'Конфигурация в техническую базу'
    if ($load.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Note = ('конфигурация в техническую базу не загрузилась: ' + $load.Text) } }
    $update = Invoke-TechDesigner -D $D -Command @('/UpdateDBCfg') -LogName 'tech_updatedb.log' -TimeoutSec $timeoutUpdateSec -Title 'Обновить конфигурацию БД технической базы'
    if ($update.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Note = ('конфигурация БД технической базы не обновилась: ' + $update.Text) } }
    Remove-Item -LiteralPath $cf -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($marker, (ConvertTo-Json -InputObject ([ordered]@{ config = $version; created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') })), $Utf8Bom)
    return [pscustomobject]@{ Ok = $true; Note = ('техническая база создана: ' + $version) }
}

function Get-DumpIdentity {
    # Что выгрузилось: extension (Configuration.xml), processing или report (корневой XML внешнего объекта).
    # Name, Uuid, IsReport, RootXml, NamePrefix, Purpose.
    param([string]$Dir)
    $configuration = Join-Path $Dir 'Configuration.xml'
    if (Test-Path -LiteralPath $configuration) {
        [xml]$document = [System.IO.File]::ReadAllText($configuration, [System.Text.Encoding]::UTF8)
        $node = $document.SelectSingleNode("/*[local-name()='MetaDataObject']/*[local-name()='Configuration']")
        if ($null -eq $node) { return $null }
        $props = $node.SelectSingleNode("*[local-name()='Properties']")
        $get = { param($Name) $p = $props.SelectSingleNode("*[local-name()='$Name']"); if ($null -ne $p) { [string]$p.InnerText } else { '' } }
        return [pscustomobject]@{ Kind = 'extension'; Name = (& $get 'Name'); Uuid = [string]$node.GetAttribute('uuid'); IsReport = $false; RootXml = $configuration
            NamePrefix = (& $get 'NamePrefix'); Purpose = (& $get 'ConfigurationExtensionPurpose'); Version = (& $get 'Version') }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Filter '*.xml' -File)) {
        [xml]$document = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        foreach ($tag in @('ExternalDataProcessor', 'ExternalReport')) {
            $node = $document.SelectSingleNode(("/*[local-name()='MetaDataObject']/*[local-name()='{0}']" -f $tag))
            if ($null -eq $node) { continue }
            $nameNode = $node.SelectSingleNode("*[local-name()='Properties']/*[local-name()='Name']")
            $name = $file.BaseName
            if ($null -ne $nameNode) { $name = [string]$nameNode.InnerText }
            $kind = 'processing'
            if ($tag -eq 'ExternalReport') { $kind = 'report' }
            return [pscustomobject]@{ Kind = $kind; Name = $name; Uuid = [string]$node.GetAttribute('uuid'); IsReport = ($tag -eq 'ExternalReport'); RootXml = $file.FullName; NamePrefix = ''; Purpose = ''; Version = '' }
        }
    }
    return $null
}

function Expand-DeliveryFile {
    # Разбор файла поставки в технической базе. Фактический тип - по тому, что выгрузилось: сначала как в имени
    # файла, не вышло - другим способом. Не разбирается (защищён, повреждён) - opaque с причиной.
    param($D, $State, $File, [int]$Index)
    $dump = Join-Path (Join-Path (Join-Path $D.Root ([string]$State['id'])) 'theirs') ('{0:00}' -f $Index)
    if (Test-Path -LiteralPath $dump) { Remove-Item -LiteralPath $dump -Recurse -Force }
    New-Item -ItemType Directory -Path $dump -Force | Out-Null
    $tries = @('cfe', 'epf')
    if ([string]$File['kind'] -ne 'cfe') { $tries = @('epf', 'cfe') }
    $reasons = @()
    foreach ($try in $tries) {
        if ($try -eq 'cfe') {
            # Имя расширения в технической базе - служебное: настоящее - в выгрузке (Configuration.xml).
            $extName = 'Поставка{0}' -f $Index
            $null = Invoke-TechDesigner -D $D -Command @('/DeleteCfg', '-Extension', ('"{0}"' -f $extName)) -LogName ('tech_del_{0}.log' -f $Index) -TimeoutSec 600
            $load = Invoke-TechDesigner -D $D -Command @('/LoadCfg', ('"{0}"' -f $File['path']), '-Extension', ('"{0}"' -f $extName)) -LogName ('tech_load_{0}.log' -f $Index) -TimeoutSec $timeoutLoadSec -Title ('Разобрать {0}: загрузить в техническую базу' -f $File['name'])
            if ($load.ExitCode -ne 0) { $reasons += ('как расширение: ' + $load.Text); continue }
            $out = Invoke-TechDesigner -D $D -Command @('/DumpConfigToFiles', ('"{0}"' -f $dump), '-Extension', ('"{0}"' -f $extName)) -LogName ('tech_dump_{0}.log' -f $Index) -TimeoutSec $timeoutLoadSec -Title ('Разобрать {0}: выгрузить в файлы' -f $File['name'])
            $null = Invoke-TechDesigner -D $D -Command @('/DeleteCfg', '-Extension', ('"{0}"' -f $extName)) -LogName ('tech_del_{0}.log' -f $Index) -TimeoutSec 600
            $info = $null
            if ($out.ExitCode -eq 0) { $info = Get-DumpIdentity $dump }
            if ($null -eq $info) { $reasons += ('выгрузка расширения: ' + $out.Text); continue }
            $configDump = Join-Path $dump 'ConfigDumpInfo.xml'
            if (Test-Path -LiteralPath $configDump) { Remove-Item -LiteralPath $configDump -Force }
            return [pscustomobject]@{ Ok = $true; Kind = 'extension'; Dir = $dump; Identity = $info; Reason = '' }
        }
        $root = Join-Path $dump 'dump.xml'
        $out = Invoke-TechDesigner -D $D -Command @('/DumpExternalDataProcessorOrReportToFiles', ('"{0}"' -f $root), ('"{0}"' -f $File['path'])) -LogName ('tech_epf_{0}.log' -f $Index) -TimeoutSec $timeoutLoadSec -Title ('Разобрать {0}' -f $File['name'])
        if ($out.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $root)) { $reasons += ('как обработка: ' + $out.Text); continue }
        $info = Get-DumpIdentity $dump
        if ($null -eq $info) { $reasons += 'выгрузка обработки без корневого объекта'; continue }
        # Модуль без исходного текста - сборки из файлов не будет: такой объект только целиком.
        $modules = @(Get-ChildItem -LiteralPath $dump -Recurse -File | Where-Object { $_.Name -match '^(ObjectModule|Module)\.bin$' })
        if ($modules.Count -gt 0) { return [pscustomobject]@{ Ok = $false; Kind = $info.Kind; Dir = ''; Identity = $info; Reason = ('модуль без исходного текста: ' + (@($modules | ForEach-Object { $_.Name }) -join ', ')) } }
        return [pscustomobject]@{ Ok = $true; Kind = $info.Kind; Dir = $dump; Identity = $info; Reason = '' }
    }
    return [pscustomobject]@{ Ok = $false; Kind = ''; Dir = ''; Identity = $null; Reason = ($reasons -join '; ') }
}

function Rename-ProcessingDump {
    # Выгрузка обработки поставки - под именем корневого XML, как у нашей папки в git: <имя>.xml и <имя>/.
    param([string]$Dir, [string]$RootName)
    $rootXml = Join-Path $Dir 'dump.xml'
    if (-not (Test-Path -LiteralPath $rootXml)) { return }
    $sub = Join-Path $Dir 'dump'
    Move-Item -LiteralPath $rootXml -Destination (Join-Path $Dir ($RootName + '.xml'))
    if (Test-Path -LiteralPath $sub) { Move-Item -LiteralPath $sub -Destination (Join-Path $Dir $RootName) }
}

#endregion

#region Сопоставление с git и карточками

function Read-DeliveryJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    if (-not $text.Trim()) { return $null }
    return (ConvertTo-DeliveryData (ConvertFrom-Json -InputObject $text))
}

function Get-OursIdentity {
    # Идентичность нашего объекта в дереве git (папка с выгрузкой).
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $null }
    return (Get-DumpIdentity $Dir)
}

function Resolve-DeliveryTargets {
    # Каждый разобранный файл -> объект в git. Расширение - по имени и UUID, обработка - по имени объекта среди
    # карточек temp (manifest main и снимок справочника temp) и подтверждённой привязке. Неоднозначно - решение.
    # Возвращает $true, если всё сопоставлено.
    param($D, $State, $Setup, [hashtable]$HeadFiles, [string]$Ours, $Cards, [switch]$Unattended)
    $bindings = @(Read-DeliveryJsonFile (Join-Path $Ours 'deliveries\bindings.json'))
    if ($null -ne $State['bindings']) { $bindings += @($State['bindings']) }
    $manifest = @(Read-DeliveryJsonFile (Join-Path $Ours 'processings\manifest.json'))
    $ok = $true
    foreach ($file in @($State['files'])) {
        if ($null -ne $file['object'] -and [string]$file['object']['repoPath']) { continue }
        $identity = $file['identity']
        if ($null -eq $identity) { continue }
        if ([string]$identity['kind'] -eq 'extension') {
            $name = [string]$identity['name']
            $repo = 'extensions/' + $name
            $oursDir = Join-Path $Ours ('extensions\' + $name)
            $ours = Get-OursIdentity $oursDir
            $note = ''
            if ($null -eq $ours) {
                # По UUID - может, расширение переименовали.
                foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $Ours 'extensions') -Directory -ErrorAction SilentlyContinue)) {
                    $other = Get-OursIdentity $dir.FullName
                    if ($null -ne $other -and $other.Uuid -eq [string]$identity['uuid']) { $repo = 'extensions/' + $dir.Name; $ours = $other; $note = ('в git это расширение называется {0} (тот же UUID)' -f $dir.Name) }
                }
            }
            if ($null -eq $ours) {
                $key = 'newext:' + $name + ':' + [string]$identity['uuid']
                $choice = [string]$State['decisions'][$key]
                if (-not $choice) {
                    $choice = Request-DeliveryChoice -D $D -State $State -Key $key -Unattended:$Unattended -Header ("Поставка {0}: новое расширение {1} (UUID {2}) - в git его нет" -f $State['id'], $name, $identity['uuid']) `
                        -Notes @(("Файл {0}, sha256 {1}" -f $file['name'], $file['sha256']), 'Принять - в git появится extensions/' + $name + ', гейт будет грузить его в temp. Новое расширение подрядчика - по регламенту только по согласованию.', 'Рекомендую: принять, если расширение согласовано; иначе отклонить.') `
                        -Options @(@('theirs', 'Принять как новое расширение'), @('ours', 'Отклонить: в git не брать'))
                }
                if (-not $choice) { $ok = $false; continue }
                if ($choice -eq 'ours') { $file['status'] = 'rejected'; $file['object'] = [ordered]@{ kind = 'extension'; name = $name; repoPath = ''; title = $name; note = 'отклонено: новое расширение не принято' }; continue }
            }
            $file['object'] = [ordered]@{ kind = 'extension'; name = $name; repoPath = $repo; title = ('расширение ' + $name); folder = ($repo.Split('/')[1]); ref = ''; note = $note; isNew = ($null -eq $ours) }
            continue
        }
        # Обработка или отчёт.
        $objName = [string]$identity['name']
        # Помеченные на удаление карточки - не цель поставки (загрузка в них не пишет).
        $candidates = @($Cards | Where-Object { [string]$_.ObjName -eq $objName -and -not [bool]$_.Deleted })
        $deletedOnly = @($Cards | Where-Object { [string]$_.ObjName -eq $objName -and [bool]$_.Deleted }).Count
        $label = 'обработка'
        if ([bool]$identity['isReport']) { $label = 'отчёт' }
        if ($candidates.Count -eq 0) {
            $newNote = 'новый объект: такой карточки в temp нет'
            if ($deletedOnly -gt 0) { $newNote = ('новая карточка: в temp есть только помеченные на удаление карточки {0} ({1})' -f $objName, $deletedOnly) }
            $file['object'] = [ordered]@{ kind = 'processing'; name = $objName; repoPath = ('processings/' + $objName); title = ('{0} {1} (новая карточка)' -f $label, $objName); folder = $objName; ref = ''; note = $newNote; isNew = $true }
            continue
        }
        $picked = $null
        if ($candidates.Count -eq 1) { $picked = $candidates[0] }
        else {
            $bound = @($bindings | Where-Object { $null -ne $_ -and [string]$_['objectName'] -eq $objName -and [string]$_['uuid'] -eq [string]$identity['uuid'] })
            foreach ($binding in $bound) {
                $match = @($candidates | Where-Object { [string]$_.Ref -eq [string]$binding['ref'] })
                if ($match.Count -gt 0) { $picked = $match[0]; $file['bindingFrom'] = [string]$binding['confirmed'] }
            }
            if ($null -eq $picked) {
                $key = 'target:' + $objName + ':' + [string]$identity['uuid']
                $choice = [string]$State['decisions'][$key]
                if (-not $choice) {
                    $notes = @(("Файл {0} (sha256 {1}): {2} {3}. Карточек с этим именем объекта в temp: {4}." -f $file['name'], ([string]$file['sha256']).Substring(0, 12), $label, $objName, $candidates.Count))
                    $options = @()
                    foreach ($card in $candidates) {
                        $targets = (@($card.Targets) | Where-Object { $_ }) -join ', '
                        if (-not $targets) { $targets = 'нет' }
                        $cardState = [string]$card.Use
                        $notes += ("- «{0}», {1}, версия {2}, {3}; назначение: {4}; ссылка {5}" -f $card.Title, $card.Kind, $card.Version, $cardState, $targets, $card.Ref)
                        $options += , @([string]$card.Ref, ("«{0}» - {1}, назначение: {2}" -f $card.Title, $cardState, $targets))
                    }
                    $notes += 'Выбор запомню (deliveries/bindings.json): следующие поставки этого объекта пойдут в ту же карточку без вопроса.'
                    $choice = Request-DeliveryChoice -D $D -State $State -Key $key -Unattended:$Unattended -Header ("Поставка {0}: в какую карточку {1} {2}?" -f $State['id'], $label, $objName) -Notes $notes -Options $options
                }
                if (-not $choice) { $ok = $false; continue }
                $picked = @($candidates | Where-Object { [string]$_.Ref -eq $choice })[0]
                $bindingList = @()
                if ($null -ne $State['bindings']) { $bindingList = @($State['bindings']) }
                $bindingList += [ordered]@{ objectName = $objName; uuid = [string]$identity['uuid']; ref = $choice; confirmed = ('поставка ' + [string]$State['id']) }
                $State['bindings'] = $bindingList
            }
        }
        $folder = $objName
        foreach ($entry in $manifest) {
            if ($null -ne $entry -and [string]$entry['ref'] -eq [string]$picked.Ref -and [string]$entry['folder']) { $folder = [string]$entry['folder'] }
        }
        $what = 'обновление карточки'
        $previous = @($State['files'] | Where-Object { $_ -ne $file })
        $file['object'] = [ordered]@{
            kind = 'processing'; name = $objName; repoPath = ('processings/' + $folder); folder = $folder; ref = [string]$picked.Ref
            title = ('{0} {1} -> карточка «{2}» ({3})' -f $label, $objName, $picked.Title, $picked.Use); note = $what; isNew = $false
            cardUse = [string]$picked.Use; cardTargets = @($picked.Targets); cardFileHash = ([string]$picked.Hash).Replace('-', '').ToLowerInvariant()
        }
        if ([string]$file['sha256'] -eq [string]$file['object']['cardFileHash']) { $file['object']['note'] = 'повторная поставка: этот файл уже стоит в карточке' }
    }
    Save-DeliveryState $D $State
    return $ok
}

function Request-DeliveryChoice {
    # Вопрос оператору с одним выбором. Ответ - в решения поставки. Без человека - '' (поставка ждёт решения).
    param($D, $State, [string]$Key, [string]$Header, [string[]]$Notes, $Options, [switch]$Unattended)
    if ($Unattended -or -not (Test-UiCanAsk)) { return '' }
    $labels = @($Options | ForEach-Object { [string]$_[1] }) + @('Решить позже (поставка подождёт)')
    $picked = Select-UiOne -Header $Header -Items $labels -Notes $Notes
    if ($picked -lt 0 -or $picked -ge @($Options).Count) { return '' }
    $value = [string]@($Options)[$picked][0]
    $State['decisions'][$Key] = $value
    Write-DeliveryEvent $D $State 'decision' ("решение {0}: {1}" -f $Key, $labels[$picked])
    Save-DeliveryState $D $State
    return $value
}

#endregion

#region История версий

function Read-DeliveryHistoryIndex {
    param($D)
    $seen = @{}
    if (Test-Path -LiteralPath $D.History) {
        foreach ($line in [System.IO.File]::ReadAllLines($D.History, [System.Text.Encoding]::UTF8)) {
            $found = [regex]::Match($line, '"path":"((?:[^"\\]|\\.)*)","blob":"([^"]+)"')
            if ($found.Success) { $seen[(ConvertFrom-GhJsonString $found.Groups[1].Value) + '|' + $found.Groups[2].Value] = $true }
        }
    }
    return $seen
}

function Add-DeliveryHistory {
    # Версия файла - в индекс истории (deliveries\history\index.jsonl): путь в репозитории, хеш блоба git, откуда.
    param($D, [hashtable]$Seen, [string]$Path, [string]$Blob, [string]$Origin)
    $key = $Path + '|' + $Blob
    if ($Seen.ContainsKey($key)) { return }
    $Seen[$key] = $true
    $line = '{"path":' + (ConvertTo-GhJsonString $Path) + ',"blob":"' + $Blob + '","origin":' + (ConvertTo-GhJsonString $Origin) + '}'
    [System.IO.File]::AppendAllText($D.History, ($line + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Update-DeliveryHistory {
    # История main (и prod) - версии файлов extensions/, processings/, binaries/ по коммитам: с ними сверяется поставка
    # («это прежняя версия, известная по истории»). Обработанные коммиты помнятся, второй раз не читаются.
    param($D, $Setup, [string]$Head)
    $seen = Read-DeliveryHistoryIndex $D
    $doneFile = Join-Path $D.Root 'history\commits.txt'
    $done = @{}
    if (Test-Path -LiteralPath $doneFile) { foreach ($line in [System.IO.File]::ReadAllLines($doneFile)) { if ($line) { $done[$line] = $true } } }
    $heads = New-Object System.Collections.Generic.List[object]
    $heads.Add(@($Head, 'main'))
    $prodBranch = [string](Get-Setting $cfg 'ExtensionsProdBranch' 'prod')
    $prod = Get-GhHead -Gh $Setup.Gh -Branch $prodBranch
    if ($prod.Sha) { $heads.Add(@($prod.Sha, $prodBranch)) }
    $read = 0
    foreach ($pair in $heads) {
        foreach ($commit in @(Get-GhAncestors -Gh $Setup.Gh -Sha $pair[0] -Limit $D.HistoryCommits)) {
            if ($done.ContainsKey($commit)) { continue }
            $files = Get-GhFiles -Gh $Setup.Gh -Commit $commit
            foreach ($path in @($files.Keys)) {
                if ($path -match '^(extensions|processings|binaries)/') { Add-DeliveryHistory $D $seen $path ([string]$files[$path]) ('{0}@{1}' -f $pair[1], (Get-GitShort $commit)) }
            }
            $done[$commit] = $true
            [System.IO.File]::AppendAllText($doneFile, ($commit + "`r`n"))
            $read++
        }
    }
    if ($read -gt 0) { Write-RunLog ("приёмка: история - прочитано коммитов {0}" -f $read) }
    return $seen
}

function Save-DeliveryBlobs {
    # Содержимое версий нужных путей - в deliveries\history\blobs (merge1c разбирает их на единицы).
    param($D, $Setup, [string[]]$Paths)
    $wanted = @{}
    foreach ($path in $Paths) { $wanted[$path] = $true }
    if (-not (Test-Path -LiteralPath $D.History)) { return }
    foreach ($line in [System.IO.File]::ReadAllLines($D.History, [System.Text.Encoding]::UTF8)) {
        $found = [regex]::Match($line, '"path":"((?:[^"\\]|\\.)*)","blob":"([0-9a-f]{40})"')
        if (-not $found.Success) { continue }
        $path = ConvertFrom-GhJsonString $found.Groups[1].Value
        if (-not $wanted.ContainsKey($path)) { continue }
        $target = Join-Path $D.Blobs $found.Groups[2].Value
        if (Test-Path -LiteralPath $target) { continue }
        try { [System.IO.File]::WriteAllBytes($target, (Get-GhBlob -Gh $Setup.Gh -Sha $found.Groups[2].Value)) }
        catch { Write-RunLog ("приёмка: блоб {0} ({1}) не скачан: {2}" -f $found.Groups[2].Value, $path, $_.Exception.Message) }
    }
}

function Add-DeliveryTheirsHistory {
    # Разобранные файлы поставки - в историю с источником delivery:<номер>: следующая поставка сверяется и с ними.
    param($D, $State)
    $seen = Read-DeliveryHistoryIndex $D
    foreach ($file in @($State['files'])) {
        $object = $file['object']
        if ($null -eq $object -or -not [string]$object['repoPath']) { continue }
        $origin = 'delivery:' + [string]$State['id']
        if ([bool]$file['opaque']) {
            Add-DeliveryHistory $D $seen ('binary:' + [string]$object['repoPath']) ([string]$file['sha256']) $origin
            continue
        }
        $dump = [string]$file['dump']
        if (-not $dump -or -not (Test-Path -LiteralPath $dump)) { continue }
        $full = (Resolve-Path -LiteralPath $dump).ProviderPath.TrimEnd('\')
        foreach ($item in @(Get-ChildItem -LiteralPath $dump -Recurse -File)) {
            $rel = $item.FullName.Substring($full.Length + 1).Replace('\', '/')
            if ($rel -eq 'ConfigDumpInfo.xml') { continue }
            $bytes = [System.IO.File]::ReadAllBytes($item.FullName)
            $blob = Get-GitBlobSha $bytes
            $target = Join-Path $D.Blobs $blob
            if (-not (Test-Path -LiteralPath $target)) { [System.IO.File]::WriteAllBytes($target, $bytes) }
            Add-DeliveryHistory $D $seen ([string]$object['repoPath'] + '/' + $rel) $blob $origin
        }
    }
}

#endregion

#region temp: правки после синхронизации с git

function Get-DeliveryTempDrift {
    # Правки temp после последней синхронизации с git (state.json commit): выгрузка и сравнение, как у «Загрузить из
    # git». Совпадающее с main не считается (недогруженная прежняя загрузка). Возвращает Changes, Snapshot, Known.
    param($Setup, $GitState, [hashtable]$HeadFiles, [string]$Head)
    $known = [string]$GitState['commit']
    $knownFiles = $HeadFiles
    if ($known -and $known -ne $Head) {
        try { $knownFiles = Get-GhFiles -Gh $Setup.Gh -Commit $known }
        catch { $known = ''; $knownFiles = $HeadFiles }
    }
    if (-not $known) { $known = $Head }
    $tracked = Get-GitFolders $knownFiles
    $withProcessings = $tracked.HasProcessings -or (Get-GitFolders $HeadFiles).HasProcessings
    Initialize-GitBinaryShas -Setup $Setup -FileSets @($knownFiles, $HeadFiles)
    $snapshot = Get-TempSnapshot -Setup $Setup -Extensions $tracked.Extensions -WithProcessings:$withProcessings
    $skipped = Get-GitSkippedPaths $snapshot $knownFiles
    $drift = Compare-GitSnapshot -Local $snapshot.Files -Remote $knownFiles -Prefixes $snapshot.Prefixes -Ignore (@('processings/manifest.json') + @($skipped))
    if ($drift.Count -gt 0 -and $known -ne $Head) { $drift = @($drift | Where-Object { -not (Test-GitSameAsHead $_ $HeadFiles) }) }
    if ($drift.Count -gt 0) {
        $drift = Compare-GitSnapshot -Local $snapshot.Files -Remote $knownFiles -Prefixes $snapshot.Prefixes -Ignore $skipped
        if ($known -ne $Head) { $drift = @($drift | Where-Object { -not (Test-GitSameAsHead $_ $HeadFiles) }) }
    }
    return [pscustomobject]@{ Changes = @($drift); Snapshot = $snapshot; Known = $known }
}

function Sync-DeliveryTemp {
    # Наша актуальная версия = main + правки temp. Правки temp - штатно веткой и PR (открытый PR выгрузки
    # продолжается, второго нет). С DeliveryAutoMerge - CI и слияние merge_checked.py, иначе - ждём слияния
    # человеком. Возвращает Ready ($true - temp синхронизирован с main, можно собирать) и снимок справочника temp.
    param($D, $State, $Setup, $GitState, [switch]$Unattended)
    $head = (Get-GhHead -Gh $Setup.Gh -Branch $Setup.Branch).Sha
    $headFiles = Get-GhFiles -Gh $Setup.Gh -Commit $head
    # Неслитый PR выгрузки temp - сначала он.
    $pending = [int]$GitState['pendingNumber']
    if ($pending -gt 0 -and [string]$GitState['pendingCommit'] -and -not (Test-GhContains -Gh $Setup.Gh -Branch '' -Head $head -Commit ([string]$GitState['pendingCommit']))) {
        $merged = Complete-DeliveryPull -D $D -State $State -Setup $Setup -Number $pending -What 'выгрузки правок temp' -Unattended:$Unattended
        if (-not $merged) { return [pscustomobject]@{ Ready = $false; Cards = @() } }
        $head = (Get-GhHead -Gh $Setup.Gh -Branch $Setup.Branch).Sha
        $headFiles = Get-GhFiles -Gh $Setup.Gh -Commit $head
    }
    $drift = Get-DeliveryTempDrift -Setup $Setup -GitState $GitState -HeadFiles $headFiles -Head $head
    if (@($drift.Changes).Count -gt 0) {
        $lines = Get-GitChangeLines $drift.Changes
        Write-DeliveryEvent $D $State 'temp-drift' ("в {0} правки после синхронизации с git: {1} - сохраняю веткой и PR" -f $script:TempBase, ($lines -join '; ')) 'Yellow'
        $made = New-GitTempBranch -Setup $Setup -State $GitState -Base $drift.Known -Changes $drift.Changes -Note ('перед поставкой ' + [string]$State['id'])
        $State['drift'] = [ordered]@{ number = $made.Number; url = $made.Url; branch = $made.Branch; commit = $made.Sha; continued = [bool]$made.Continued }
        Save-DeliveryState $D $State
        $merged = Complete-DeliveryPull -D $D -State $State -Setup $Setup -Number $made.Number -What 'выгрузки правок temp' -Unattended:$Unattended
        if (-not $merged) { return [pscustomobject]@{ Ready = $false; Cards = @() } }
        $head = (Get-GhHead -Gh $Setup.Gh -Branch $Setup.Branch).Sha
    }
    return [pscustomobject]@{ Ready = $true; Cards = @($drift.Snapshot.Processings); Head = $head }
}

function Complete-DeliveryPull {
    # PR (выгрузки temp или поставки) до слияния: CI для текущего merge SHA, затем merge_checked.py с этим SHA
    # (DeliveryAutoMerge) или ожидание слияния человеком. $true - PR в main.
    param($D, $State, $Setup, [int]$Number, [string]$What, [switch]$Unattended)
    $pull = Get-GhPull -Gh $Setup.Gh -Number $Number
    if ($pull.Merged -or (Test-GhContains -Gh $Setup.Gh -Branch $Setup.Branch -Commit $pull.Head)) { return $true }
    if ($pull.State -ne 'open') { Write-DeliveryEvent $D $State 'pull-closed' ("PR #{0} {1} закрыт без слияния: поставка ждёт решения человека" -f $Number, $What) 'Red'; Set-DeliveryStatus $D $State 'waiting-merge' ("PR #{0} закрыт" -f $Number); return $false }
    $ci = Wait-DeliveryCi -D $D -State $State -Setup $Setup -Number $Number
    if ($ci.Result -ne 'success') {
        Set-DeliveryStatus $D $State 'waiting-merge' ("PR #{0} {1}: CI {2}" -f $Number, $What, $ci.Result)
        return $false
    }
    if (-not $D.AutoMerge) {
        Write-DeliveryEvent $D $State 'wait-merge' ("PR #{0} {1}: CI зелёный для merge {2}; слияние - за человеком (DeliveryAutoMerge выключен): python ci/merge_checked.py {0} --merge {2}" -f $Number, $What, $ci.Merge) 'Yellow'
        Set-DeliveryStatus $D $State 'waiting-merge' ("ждёт слияния PR #{0}" -f $Number)
        return $false
    }
    $check = Invoke-DeliveryMergeCheck -D $D -Setup $Setup -Number $Number -Merge $ci.Merge
    if (-not $check.Ok) {
        Write-DeliveryEvent $D $State 'merge-refused' ("PR #{0} {1}: merge_checked.py не подтвердил слияние: {2}" -f $Number, $What, $check.Error) 'Red'
        Set-DeliveryStatus $D $State 'waiting-merge' $check.Error
        return $false
    }
    Write-DeliveryEvent $D $State 'merged' ("PR #{0} {1} слит: main -> {2} (merge_checked.py, CI {3})" -f $Number, $What, $ci.Merge, $ci.Run) 'Green'
    return $true
}

#endregion

#region PR, CI, merge_checked

function Wait-DeliveryCi {
    # CI PR для его текущего merge SHA: ждём не дольше DeliveryCiWaitMin. Result: success, failure, pending,
    # conflict (GitHub не может слить), stale (последний прогон проверил прежний merge SHA - нужен новый коммит).
    param($D, $State, $Setup, [int]$Number, [switch]$NoWait)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $title = ("CI PR #{0}" -f $Number)
    $limit = $D.CiWaitSec
    if ($NoWait) { $limit = 0 }
    while ($true) {
        $pull = Get-GhPull -Gh $Setup.Gh -Number $Number
        $result = ''
        $run = $null
        if ($pull.Mergeable -eq $false) { $result = 'conflict' }
        elseif ($pull.Merge) {
            $run = Get-GhCiRun -Gh $Setup.Gh -Head $pull.Head -Workflow $D.Workflow -Merge $pull.Merge
            if ($run.Status -eq 'completed') {
                if ([string]$run.Title -ne ('ERP static ' + $pull.Merge)) { $result = 'stale' }
                elseif ($run.Conclusion -eq 'success') { $result = 'success' }
                else { $result = 'failure' }
            }
        }
        if ($result -or $watch.Elapsed.TotalSeconds -ge $limit) {
            Complete-UiProgress
            if (-not $result) { $result = 'pending' }
            $runId = ''
            if ($null -ne $run) { $runId = [string]$run.Id }
            $State['ci'] = [ordered]@{ number = $Number; head = $pull.Head; merge = $pull.Merge; result = $result; run = $runId; url = $(if ($null -ne $run) { [string]$run.Url } else { '' }); time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
            Save-DeliveryState $D $State
            $color = 'Green'
            if ($result -ne 'success') { $color = 'Yellow' }
            if ($result -eq 'failure') { $color = 'Red' }
            Write-DeliveryEvent $D $State 'ci' ("CI PR #{0}: {1} (head {2}, merge {3})" -f $Number, $result, (Get-GitShort $pull.Head), (Get-GitShort $pull.Merge)) $color
            return [pscustomobject]@{ Result = $result; Merge = $pull.Merge; Head = $pull.Head; Base = $pull.Base; Run = $runId }
        }
        Write-UiProgress -Title $title -Elapsed $watch.Elapsed.TotalSeconds -Expected $limit -Detail 'жду проверку ERP static для текущего merge SHA'
        Start-Sleep -Seconds 10
    }
}

function Invoke-DeliveryMergeCheck {
    # Слияние действующим механизмом: ci/merge_checked.py из main, только если его git-хеш совпадает с закреплённым
    # (DeliveryMergeCheckedBlob): изменённый CI сначала смотрит человек. Сначала проверка без записи, затем --merge
    # с точным SHA. Подставной GitHub - то же правило внутри (CI для этого merge SHA, база - текущий main).
    param($D, $Setup, [int]$Number, [string]$Merge)
    if ($Setup.Gh.FakeDir) {
        $pull = Get-GhPull -Gh $Setup.Gh -Number $Number
        $main = (Get-GhHead -Gh $Setup.Gh -Branch $Setup.Branch).Sha
        if ($pull.State -ne 'open' -or $pull.Base -ne $main -or $pull.Merge -ne $Merge) { return [pscustomobject]@{ Ok = $false; Error = 'PR или main изменился: merge SHA не тот' } }
        $run = Get-GhCiRun -Gh $Setup.Gh -Head $pull.Head -Workflow $D.Workflow -Merge $pull.Merge
        if ($run.Status -ne 'completed' -or $run.Conclusion -ne 'success') { return [pscustomobject]@{ Ok = $false; Error = 'нет успешного CI для этого merge SHA' } }
        Set-GhBranch -Gh $Setup.Gh -Branch $Setup.Branch -Sha $Merge
        Write-GhFakeLog $Setup.Gh ("merge-checked {0} {1}" -f $Number, $Merge)
        return [pscustomobject]@{ Ok = $true; Error = '' }
    }
    if (-not $D.MergeCheckedBlob) { return [pscustomobject]@{ Ok = $false; Error = 'не закреплён git-хеш доверенного ci/merge_checked.py (DeliveryMergeCheckedBlob в настройках площадки)' } }
    $mainSha = (Get-GhHead -Gh $Setup.Gh -Branch $Setup.Branch).Sha
    $mainFiles = Get-GhFiles -Gh $Setup.Gh -Commit $mainSha
    $blob = [string]$mainFiles[$D.MergeCheckedPath]
    if ($blob -ne $D.MergeCheckedBlob) { return [pscustomobject]@{ Ok = $false; Error = ("{0} в main ({1}) не тот, что закреплён ({2}): изменённый CI сначала смотрит человек и закрепляет новый хеш" -f $D.MergeCheckedPath, $blob, $D.MergeCheckedBlob) } }
    $toolDir = Join-Path $D.Root 'tools'
    New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
    $script = Join-Path $toolDir 'merge_checked.py'
    $bytes = Get-GhBlob -Gh $Setup.Gh -Sha $blob
    if ((Get-GitBlobSha $bytes) -ne $D.MergeCheckedBlob) { return [pscustomobject]@{ Ok = $false; Error = 'скачанный merge_checked.py не совпал с закреплённым хешем' } }
    [System.IO.File]::WriteAllBytes($script, $bytes)
    $readOnly = Invoke-MergeCheckedScript -D $D -Setup $Setup -Script $script -Arguments @([string]$Number, '--json')
    if (-not $readOnly.Ok) { return $readOnly }
    if ([string]$readOnly.Data.merge -ne $Merge) { return [pscustomobject]@{ Ok = $false; Error = ("merge SHA сейчас {0}, проверяли {1}" -f $readOnly.Data.merge, $Merge) } }
    $write = Invoke-MergeCheckedScript -D $D -Setup $Setup -Script $script -Arguments @([string]$Number, '--merge', $Merge, '--json')
    return $write
}

function Invoke-MergeCheckedScript {
    # python -I merge_checked.py ...: токен - переменной окружения процесса (не в командной строке и не в журнале).
    param($D, $Setup, [string]$Script, [string[]]$Arguments)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $D.Python
    $info.Arguments = (@('-I', ('"{0}"' -f $Script)) + $Arguments) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $info.EnvironmentVariables['MERGE_CHECKED_TOKEN'] = [string]$Setup.Gh.Token
    $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    Write-RunLog ("> {0} {1}" -f $D.Python, $info.Arguments)
    try { $process = [System.Diagnostics.Process]::Start($info) }
    catch { return [pscustomobject]@{ Ok = $false; Error = ("не запустился {0}: {1} (DeliveryPython)" -f $D.Python, $_.Exception.Message); Data = $null } }
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { try { $process.Kill() } catch { }; return [pscustomobject]@{ Ok = $false; Error = 'merge_checked.py не ответил за 5 минут'; Data = $null } }
    $out = [string]$outTask.Result
    $err = [string]$errTask.Result
    if ($Setup.Gh.Token) { $out = $out.Replace($Setup.Gh.Token, '***'); $err = $err.Replace($Setup.Gh.Token, '***') }
    Write-RunLog ("  код {0}: {1} {2}" -f $process.ExitCode, $out.Trim(), $err.Trim())
    $data = $null
    $last = @($out -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if ($last.Count -gt 0) { try { $data = $last[0] | ConvertFrom-Json } catch { $data = $null } }
    if ($process.ExitCode -ne 0 -or $null -eq $data -or -not [bool]$data.ok) {
        $text = $err.Trim()
        if ($null -ne $data -and $null -ne $data.PSObject.Properties['error']) { $text = [string]$data.error }
        if (-not $text) { $text = ('код {0}' -f $process.ExitCode) }
        return [pscustomobject]@{ Ok = $false; Error = $text; Data = $data }
    }
    return [pscustomobject]@{ Ok = $true; Error = ''; Data = $data }
}

#endregion

#region Объединение и кандидат

function Get-DeliveryObjects {
    # Объекты поставки, которые идут в объединение (сопоставлены и не отклонены).
    param($State)
    # Без запятой: вызывающие берут @(Get-DeliveryObjects ...) и перебирают по одному.
    return @(@($State['files']) | Where-Object { $null -ne $_['object'] -and [string]$_['object']['repoPath'] -and [string]$_['status'] -ne 'rejected' })
}

function Invoke-DeliveryMerge {
    # Объединение поверх main (Base): наше дерево - из GitHub, поставка - разобранная, история - индекс. Решения -
    # deliveries\<номер>\decisions.json (переживают пересборку: тот же вопрос - тот же номер). Возвращает результат
    # merge1c (Pending, Objects) или $null, если не запустился.
    param($D, $State, $Setup, [string]$Base, [switch]$Unattended)
    $dir = Join-Path $D.Root ([string]$State['id'])
    $oursRoot = Join-Path $dir 'ours'
    $outRoot = Join-Path $dir 'merged'
    foreach ($path in @($oursRoot, $outRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    $baseFiles = Get-GhFiles -Gh $Setup.Gh -Commit $Base
    $objects = @(Get-DeliveryObjects $State)
    $prefixes = @($objects | ForEach-Object { [string]$_['object']['repoPath'] + '/' }) + @('deliveries/', 'processings/manifest.json', 'binaries/manifest.json')
    $null = Save-GhFiles -Gh $Setup.Gh -Commit $Base -Prefixes $prefixes -Target $oursRoot -Expected $baseFiles
    $null = Update-DeliveryHistory -D $D -Setup $Setup -Head $Base
    Add-DeliveryTheirsHistory $D $State
    # Содержимое версий тех путей, что различаются.
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($file in $objects) {
        $repo = [string]$file['object']['repoPath']
        if ([bool]$file['opaque']) { continue }
        $oursDir = Join-Path $oursRoot $repo.Replace('/', '\')
        $diff = (& $D.Merge paths -ours $oursDir -theirs ([string]$file['dump'])) | Out-String
        # PowerShell 5.1: ConvertFrom-Json отдаёт массив одним объектом - в переменную, потом перебор.
        $rels = ConvertFrom-Json -InputObject $diff
        foreach ($rel in $rels) { $paths.Add(($repo + '/' + [string]$rel)) }
    }
    Save-DeliveryBlobs -D $D -Setup $Setup -Paths $paths.ToArray()
    $ledgers = @()
    $ledgerDir = Join-Path $oursRoot 'deliveries'
    if (Test-Path -LiteralPath $ledgerDir) { $ledgers = @(Get-ChildItem -LiteralPath $ledgerDir -Filter '*.json' -File | Where-Object { $_.Name -ne 'bindings.json' } | ForEach-Object { $_.FullName }) }
    $specObjects = @()
    foreach ($file in $objects) {
        $object = $file['object']
        $repo = [string]$object['repoPath']
        $oursDir = Join-Path $oursRoot $repo.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $oursDir)) { $oursDir = '' }
        $oursSha = ''
        if ([string]$object['kind'] -eq 'processing' -and $null -ne $object['cardFileHash']) { $oursSha = [string]$object['cardFileHash'] }
        $specObjects += [ordered]@{
            kind = [string]$object['kind']; name = [string]$object['name']; title = [string]$object['title']; repoPath = $repo
            ours = $oursDir; theirs = [string]$file['dump']; out = (Join-Path $outRoot $repo.Replace('/', '\'))
            opaque = [bool]$file['opaque']; opaqueReason = [string]$file['opaqueReason']; theirsFile = [string]$file['path']
            theirsSha256 = [string]$file['sha256']; oursSha256 = $oursSha
        }
    }
    $decisionsFile = Join-Path $dir 'decisions.json'
    $resultFile = Join-Path $dir 'merge-result.json'
    $reportFile = Join-Path $dir 'merge-report.md'
    $stamp = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'Russian Standard Time').ToString('yyyyMMdd.HHmmss')
    $spec = [ordered]@{
        delivery = [string]$State['id']; stamp = $stamp; historyIndex = $D.History; blobDir = $D.Blobs; ledgers = $ledgers
        decisions = $decisionsFile; objects = $specObjects; result = $resultFile; report = $reportFile
    }
    $specFile = Join-Path $dir 'merge-spec.json'
    while ($true) {
        if (-not (Test-Path -LiteralPath $decisionsFile)) { [System.IO.File]::WriteAllText($decisionsFile, '{}', (New-Object System.Text.UTF8Encoding($false))) }
        [System.IO.File]::WriteAllText($specFile, (ConvertTo-Json -InputObject $spec -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
        $output = (& $D.Merge merge -spec $specFile 2>&1) | Out-String
        $code = $LASTEXITCODE
        Write-RunLog ("merge1c: код {0}: {1}" -f $code, $output.Trim())
        if ($code -ne 0 -and $code -ne 3) { Write-DeliveryEvent $D $State 'merge-error' ("объединение не выполнилось: {0}" -f $output.Trim()) 'Red'; return $null }
        $result = ConvertTo-DeliveryData ([System.IO.File]::ReadAllText($resultFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
        if ([int]$result['pending'] -eq 0) { return $result }
        $decided = Request-MergeDecisions -D $D -State $State -Result $result -DecisionsFile $decisionsFile -Unattended:$Unattended
        if (-not $decided) { return $result }
    }
}

function Request-MergeDecisions {
    # Решения объединения по одному: что у нас, что пришло, разница, последствия, рекомендация. $false - человек
    # отложил или его нет: поставка ждёт.
    param($D, $State, $Result, [string]$DecisionsFile, [switch]$Unattended)
    if ($Unattended -or -not (Test-UiCanAsk)) { return $false }
    $decisions = [ordered]@{}
    $known = Read-DeliveryJsonFile $DecisionsFile
    if ($null -ne $known) { foreach ($key in @($known.Keys)) { $decisions[$key] = $known[$key] } }
    $asked = 0
    foreach ($object in @($Result['objects'])) {
        foreach ($decision in @($object['decisions'])) {
            if ($null -eq $decision -or [string]$decision['chosen']) { continue }
            $notes = New-Object System.Collections.Generic.List[string]
            $notes.Add(("Объект: {0}; файл {1}" -f $object['title'], $decision['file']))
            if ([string]$decision['diff']) {
                $notes.Add('Разница («-» у нас, «+» в поставке):')
                foreach ($line in @(([string]$decision['diff']) -split "`n" | Select-Object -First 30)) { $notes.Add(('  ' + $line)) }
            }
            else {
                $notes.Add(('Сейчас у нас: ' + [string]$decision['ours']))
                $notes.Add(('Пришло: ' + [string]$decision['theirs']))
            }
            $notes.Add(('Последствия: ' + [string]$decision['consequences']))
            $recommended = 'взять поставку'
            if ([string]$decision['recommended'] -eq 'ours') { $recommended = 'оставить наше' }
            $notes.Add(('Рекомендую: {0} - {1}' -f $recommended, [string]$decision['why']))
            $items = @('Взять поставку', 'Оставить наше', 'Решить позже (поставка подождёт)')
            if ([string]$decision['recommended'] -eq 'theirs') { $items[0] += ' (рекомендую)' } else { $items[1] += ' (рекомендую)' }
            $picked = Select-UiOne -Header ("Поставка {0}: {1}" -f $State['id'], $decision['title']) -Items $items -Notes $notes.ToArray()
            if ($picked -ne 0 -and $picked -ne 1) {
                [System.IO.File]::WriteAllText($DecisionsFile, (ConvertTo-Json -InputObject $decisions), (New-Object System.Text.UTF8Encoding($false)))
                return $false
            }
            $choice = 'theirs'
            if ($picked -eq 1) { $choice = 'ours' }
            $decisions[[string]$decision['id']] = $choice
            Write-DeliveryEvent $D $State 'decision' ("решение {0} ({1}): {2}" -f $decision['id'], $decision['title'], $items[$picked])
            $asked++
        }
    }
    [System.IO.File]::WriteAllText($DecisionsFile, (ConvertTo-Json -InputObject $decisions), (New-Object System.Text.UTF8Encoding($false)))
    return ($asked -gt 0)
}

function Test-DeliveryBuild {
    # Объединённое собирается: расширение грузится из файлов в техническую базу и проходит проверку применимости,
    # обработка собирается из файлов в .epf/.erf. В техническую базу - временно, потом удаляется по имени.
    param($D, $State, $Result)
    $outRoot = Join-Path (Join-Path $D.Root ([string]$State['id'])) 'merged'
    $notes = New-Object System.Collections.Generic.List[string]
    $ok = $true
    $index = 0
    foreach ($object in @($Result['objects'])) {
        $index++
        $status = [string]$object['status']
        if ($status -eq 'opaque') { $notes.Add(('{0}: файл целиком - из исходников не собирается, ставится как пришёл (проверка - открытие и регистрация после загрузки)' -f $object['name'])); continue }
        if ($status -ne 'changed' -and $status -ne 'new') { continue }
        $dir = Join-Path $outRoot ([string]$object['repoPath']).Replace('/', '\')
        if ([string]$object['kind'] -eq 'extension') {
            $name = [string]$object['name']
            $extName = 'Сборка{0}' -f $index
            $null = Invoke-TechDesigner -D $D -Command @('/DeleteCfg', '-Extension', ('"{0}"' -f $extName)) -LogName ('build_del_{0}.log' -f $index) -TimeoutSec 600
            $load = Invoke-TechDesigner -D $D -Command @('/LoadConfigFromFiles', ('"{0}"' -f $dir), '-Extension', ('"{0}"' -f $extName)) -LogName ('build_load_{0}.log' -f $index) -TimeoutSec $timeoutLoadSec -Title ('Собрать {0} из объединённых файлов' -f $name)
            if ($load.ExitCode -ne 0) { $ok = $false; $notes.Add(('{0}: не собралось из файлов: {1}' -f $name, $load.Text)); continue }
            $check = Invoke-TechDesigner -D $D -Command @('/CheckCanApplyConfigurationExtensions', '-Extension', ('"{0}"' -f $extName)) -LogName ('build_apply_{0}.log' -f $index) -TimeoutSec $timeoutLoadSec -Title ('Проверка применимости {0}' -f $name)
            $null = Invoke-TechDesigner -D $D -Command @('/DeleteCfg', '-Extension', ('"{0}"' -f $extName)) -LogName ('build_del_{0}.log' -f $index) -TimeoutSec 600
            if ($check.ExitCode -ne 0) { $ok = $false; $notes.Add(('{0}: проверка применимости не прошла: {1}' -f $name, $check.Text)); continue }
            $notes.Add(('{0}: собралось, проверка применимости в технической базе прошла' -f $name))
            continue
        }
        $root = @(Get-ChildItem -LiteralPath $dir -Filter '*.xml' -File | Select-Object -First 1)
        if ($root.Count -eq 0) { $ok = $false; $notes.Add(('{0}: в объединённом нет корневого XML' -f $object['name'])); continue }
        $info = Get-DumpIdentity $dir
        $ext = '.epf'
        if ($null -ne $info -and $info.IsReport) { $ext = '.erf' }
        $built = Join-Path (Join-Path (Join-Path $D.Root ([string]$State['id'])) 'built') ($root[0].BaseName + $ext)
        New-Item -ItemType Directory -Path (Split-Path -Parent $built) -Force | Out-Null
        $build = Invoke-TechDesigner -D $D -Command @('/LoadExternalDataProcessorOrReportFromFiles', ('"{0}"' -f $root[0].FullName), ('"{0}"' -f $built)) -LogName ('build_epf_{0}.log' -f $index) -TimeoutSec $timeoutLoadSec -Title ('Собрать {0} из объединённых файлов' -f $object['name'])
        if ($build.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $built)) { $ok = $false; $notes.Add(('{0}: не собралось: {1}' -f $object['name'], $build.Text)); continue }
        $notes.Add(('{0}: собрано {1}, sha256 {2}' -f $object['name'], (Split-Path -Leaf $built), (Get-DeliverySha256 $built)))
    }
    $State['build'] = [ordered]@{ ok = $ok; notes = $notes.ToArray(); time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    Save-DeliveryState $D $State
    foreach ($line in $notes) { Write-DeliveryEvent $D $State 'build' $line $(if ($ok) { 'Green' } else { 'Red' }) }
    return $ok
}

function Get-DeliveryChanges {
    # Изменения кандидата против нашего дерева: файлы объединённых объектов, журнал поставки, привязки, целые файлы.
    param($D, $State, $Result)
    $dir = Join-Path $D.Root ([string]$State['id'])
    $oursRoot = Join-Path $dir 'ours'
    $outRoot = Join-Path $dir 'merged'
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($object in @($Result['objects'])) {
        $repo = [string]$object['repoPath']
        $status = [string]$object['status']
        if ($status -eq 'opaque') { continue }
        if ($status -ne 'changed' -and $status -ne 'new') { continue }
        $local = @{}
        $outDir = Join-Path $outRoot $repo.Replace('/', '\')
        if (Test-Path -LiteralPath $outDir) { Add-GitSnapshotFiles -Files $local -Dir $outDir -Prefix ($repo + '/') }
        $remote = @{}
        $oursDir = Join-Path $oursRoot $repo.Replace('/', '\')
        if (Test-Path -LiteralPath $oursDir) {
            $oursFiles = @{}
            Add-GitSnapshotFiles -Files $oursFiles -Dir $oursDir -Prefix ($repo + '/')
            foreach ($path in @($oursFiles.Keys)) { $remote[$path] = Get-GitBlobSha ([System.IO.File]::ReadAllBytes($oursFiles[$path])) }
        }
        $compared = Compare-GitSnapshot -Local $local -Remote $remote -Prefixes @($repo + '/')
        foreach ($change in $compared) { $changes.Add($change) }
    }
    return , $changes
}

function Add-DeliveryTextChange {
    param($Changes, [string]$Dir, [string]$Path, [string]$Text, [hashtable]$BaseFiles)
    $file = Join-Path $Dir ($Path.Replace('/', '_'))
    [System.IO.File]::WriteAllText($file, $Text, (New-Object System.Text.UTF8Encoding($false)))
    $sha = Get-GitBlobSha ([System.IO.File]::ReadAllBytes($file))
    if ($BaseFiles.ContainsKey($Path) -and [string]$BaseFiles[$Path] -eq $sha) { return }
    $kind = 'add'
    if ($BaseFiles.ContainsKey($Path)) { $kind = 'change' }
    $Changes.Add([pscustomobject]@{ Path = $Path; Kind = $kind; File = $file; Sha = $sha })
}

function Publish-DeliveryCandidate {
    # Кандидат: коммит поверх Base в ветку delivery/<номер> (пересборка - та же ветка), PR в main (один на поставку).
    # В коммите - объединённые объекты, журнал поставки deliveries/<номер>.json, привязки, целые файлы binaries/.
    param($D, $State, $Setup, $Result, [string]$Base)
    $dir = Join-Path $D.Root ([string]$State['id'])
    $extra = Join-Path $dir 'commit-files'
    if (Test-Path -LiteralPath $extra) { Remove-Item -LiteralPath $extra -Recurse -Force }
    New-Item -ItemType Directory -Path $extra -Force | Out-Null
    $baseFiles = Get-GhFiles -Gh $Setup.Gh -Commit $Base
    $changes = Get-DeliveryChanges -D $D -State $State -Result $Result
    $business = $changes.Count
    # Целые файлы (защищённые, непрозрачные): binaries/<папка>/<файл> и запись в binaries/manifest.json.
    $binaries = @()
    $known = Read-DeliveryJsonFile (Join-Path (Join-Path $dir 'ours') 'binaries\manifest.json')
    foreach ($entry in @($known)) { if ($null -ne $entry) { $binaries += $entry } }
    $binaryChanged = $false
    foreach ($object in @($Result['objects'])) {
        if ([string]$object['status'] -ne 'opaque') { continue }
        $file = @(@($State['files']) | Where-Object { $null -ne $_['object'] -and [string]$_['object']['repoPath'] -eq [string]$object['repoPath'] })[0]
        $folder = [string]$file['object']['folder']
        $name = [string]$file['name']
        $path = 'binaries/' + $folder + '/' + $name
        $sha = Get-GitBlobSha ([System.IO.File]::ReadAllBytes([string]$file['path']))
        if (-not ($baseFiles.ContainsKey($path) -and [string]$baseFiles[$path] -eq $sha)) {
            $kind = 'add'
            if ($baseFiles.ContainsKey($path)) { $kind = 'change' }
            $changes.Add([pscustomobject]@{ Path = $path; Kind = $kind; File = [string]$file['path']; Sha = $sha })
        }
        $binaries = @($binaries | Where-Object { [string]$_['folder'] -ne $folder })
        $binaries += [ordered]@{ folder = $folder; objectName = [string]$file['object']['name']; file = $name; sha256 = [string]$file['sha256']; ref = [string]$file['object']['ref']; delivery = [string]$State['id'] }
        $binaryChanged = $true
    }
    if ($binaryChanged) { Add-DeliveryTextChange -Changes $changes -Dir $extra -Path 'binaries/manifest.json' -Text ((ConvertTo-Json -InputObject @($binaries | Sort-Object { [string]$_['folder'] }) -Depth 5) + "`n") -BaseFiles $baseFiles }
    if ($business -eq 0 -and -not $binaryChanged) { return $null }
    # Привязки: подтверждённые этой поставкой - к прежним.
    if ($null -ne $State['bindings'] -and @($State['bindings']).Count -gt 0) {
        $bindings = @()
        $knownBindings = Read-DeliveryJsonFile (Join-Path (Join-Path $dir 'ours') 'deliveries\bindings.json')
        foreach ($entry in @($knownBindings)) { if ($null -ne $entry) { $bindings += $entry } }
        foreach ($entry in @($State['bindings'])) {
            $bindings = @($bindings | Where-Object { -not ([string]$_['objectName'] -eq [string]$entry['objectName'] -and [string]$_['uuid'] -eq [string]$entry['uuid']) })
            $bindings += $entry
        }
        Add-DeliveryTextChange -Changes $changes -Dir $extra -Path 'deliveries/bindings.json' -Text ((ConvertTo-Json -InputObject @($bindings) -Depth 5) + "`n") -BaseFiles $baseFiles
    }
    Add-DeliveryTextChange -Changes $changes -Dir $extra -Path ('deliveries/{0}.json' -f $State['id']) -Text ((ConvertTo-Json -InputObject (Get-DeliveryLedger $State $Result $Base) -Depth 12) + "`n") -BaseFiles $baseFiles
    $objectsText = (@(Get-DeliveryObjects $State | ForEach-Object { [string]$_['object']['name'] } | Sort-Object -Unique) -join ', ')
    $sha = New-GitVerifiedCommit -Setup $Setup -Parent $Base -Changes $changes.ToArray() -Message ("Поставка подрядчика {0}: {1}" -f $State['id'], $objectsText)
    $branch = 'delivery/' + [string]$State['id']
    $existing = (Get-GhHead -Gh $Setup.Gh -Branch $branch).Sha
    if ($existing) { Set-GhBranch -Gh $Setup.Gh -Branch $branch -Sha $sha -Force } else { Set-GhBranch -Gh $Setup.Gh -Branch $branch -Sha $sha -Create }
    $body = Get-DeliveryReport -D $D -State $State -ForPull
    $number = Find-GhPull -Gh $Setup.Gh -Head $branch -Base $Setup.Branch
    $url = ''
    if ($number -gt 0) {
        Set-GhPullBody -Gh $Setup.Gh -Number $number -Body $body
        $url = ('https://github.com/{0}/pull/{1}' -f $Setup.Repo, $number)
        if ($existing -and $existing -ne $sha) { Add-GhComment -Gh $Setup.Gh -Number $number -Body ("Кандидат пересобран поверх main {0}: коммит {1}. Ждём CI для нового merge SHA." -f $Base, $sha) }
    }
    else {
        $pull = New-GhPull -Gh $Setup.Gh -Head $branch -Base $Setup.Branch -Title ("Поставка подрядчика {0}: {1}" -f $State['id'], $objectsText) -Body $body
        $number = $pull.Number
        $url = $pull.Url
    }
    $State['pr'] = [ordered]@{ number = $number; url = $url; branch = $branch; head = $sha; base = $Base; files = $changes.Count }
    Write-DeliveryEvent $D $State 'pr' ("кандидат: ветка {0}, коммит {1} поверх main {2}, PR #{3} {4}" -f $branch, (Get-GitShort $sha), (Get-GitShort $Base), $number, $url) 'Cyan'
    Save-DeliveryState $D $State
    return $State['pr']
}

function Get-DeliveryLedger {
    # Журнал поставки в git (deliveries/<номер>.json): что пришло (хеши), что принято и что отклонено (отпечатки
    # единиц - следующая поставка их не вернёт молча), решения, основа.
    param($State, $Result, [string]$Base)
    $files = @()
    foreach ($file in @($State['files'])) {
        $object = $file['object']
        $files += [ordered]@{
            name = [string]$file['name']; sha256 = [string]$file['sha256']; size = $file['size']; kind = [string]$file['kind']; actualKind = [string]$file['actualKind']
            object = $(if ($null -ne $object) { [string]$object['repoPath'] } else { '' }); ref = $(if ($null -ne $object) { [string]$object['ref'] } else { '' })
            opaque = [bool]$file['opaque']; status = [string]$file['status']
        }
    }
    $objects = @()
    $rejected = @()
    foreach ($object in @($Result['objects'])) {
        $accepted = @()
        foreach ($change in @($object['accepted'])) { if ($null -ne $change) { $accepted += [ordered]@{ file = [string]$change['file']; unit = [string]$change['unit']; title = [string]$change['title']; hash = [string]$change['theirsHash']; class = [string]$change['class'] } } }
        foreach ($item in @($object['rejected'])) { if ($null -ne $item) { $rejected += $item } }
        $decisions = @()
        foreach ($decision in @($object['decisions'])) { if ($null -ne $decision) { $decisions += [ordered]@{ id = [string]$decision['id']; title = [string]$decision['title']; kind = [string]$decision['kind']; chosen = [string]$decision['chosen'] } } }
        $objects += [ordered]@{ kind = [string]$object['kind']; name = [string]$object['name']; repoPath = [string]$object['repoPath']; status = [string]$object['status']; first = [bool]$object['first']; counts = $object['counts']; accepted = $accepted; decisions = $decisions }
    }
    return [ordered]@{ id = [string]$State['id']; received = [string]$State['received']; source = [string]$State['source']; base = $Base; engine = [string]$Result['engine']; files = $files; objects = $objects; rejected = $rejected }
}

#endregion

#region Применение в temp

function Lock-DeliveryTemp {
    # Блокировка начала сеансов temp на время сверки, слияния и загрузки, потом - ни одного конфигуратора: открытый
    # конфигуратор мог бы записать между проверкой и загрузкой, блокировка гейта от этого не спасает.
    $link = Connect-ClusterAgent
    if (@($link.Clusters).Count -eq 0) { return [pscustomobject]@{ Ok = $false; Why = ('агент кластера: ' + (@($link.Errors) -join '; ')); Own = $false } }
    $target = Get-BaseInfo -Link $link -BaseName $script:TempBase -User $script:TempUser -Password $script:TempPassword
    $info = Read-BaseInfoAgain $target $script:TempBase
    $lock = [pscustomobject]@{ Ok = $true; Why = ''; Own = $false; Link = $link; Target = $target; State = (New-GateLockState) }
    if ([bool]$info.SessionsDenied) {
        if ([string]$info.PermissionCode -cne $script:UnlockCode) { return [pscustomobject]@{ Ok = $false; Why = 'в temp чужая блокировка начала сеансов с другим кодом разрешения'; Own = $false } }
    }
    else {
        $until = (Get-Date).AddHours($sessionLockHours)
        Set-GateSessionLock $lock.State $target ((Get-Date).AddMinutes(-30)) $until $script:UnlockCode 'Идёт приёмка поставки в temp' { param($t) Read-BaseInfoAgain $t $script:TempBase }
        $lock.Own = $true
        $script:DeliveryTempLock = $lock
    }
    $designers = @(Get-BaseSessions $link $script:TempBase | Where-Object { $_.IsDesigner -or $_.IsError })
    if ($designers.Count -gt 0) {
        Unlock-DeliveryTemp $lock
        return [pscustomobject]@{ Ok = $false; Why = ('в temp открыт конфигуратор (или сеансы не прочитались): ' + (@($designers | ForEach-Object { $_.Text }) -join '; ') + ' - исключить параллельную запись нельзя'); Own = $false }
    }
    return $lock
}

function Unlock-DeliveryTemp {
    param($Lock)
    if ($null -eq $Lock -or -not $Lock.Own) { return }
    try { $null = Restore-GateLocks $Lock.State $Lock.Target $false { param($t) Read-BaseInfoAgain $t $script:TempBase } }
    catch { Write-Line ("Снятие блокировки {0} не подтверждено: {1}. Проверь свойства базы в консоли кластера." -f $script:TempBase, $_.Exception.Message) 'Yellow' }
    $Lock.Own = $false
    $script:DeliveryTempLock = $null
}

function Get-DeliveryObjectStates {
    # Фактическое состояние объектов поставки в temp против main: загружен (как в main) или нет - перед повтором
    # загрузки после обрыва и в итоге.
    param($Setup, $State, $Snapshot, [hashtable]$HeadFiles)
    $localShas = @{}
    foreach ($path in @($Snapshot.Files.Keys)) { $localShas[$path] = Get-GitBlobSha ([System.IO.File]::ReadAllBytes($Snapshot.Files[$path])) }
    $list = @()
    foreach ($file in @(Get-DeliveryObjects $State)) {
        $repo = [string]$file['object']['repoPath'] + '/'
        $same = ((Get-GitFolderPrint $HeadFiles $repo) -eq (Get-GitFolderPrint $localShas $repo))
        if ([bool]$file['opaque']) {
            $same = @($Snapshot.Processings | Where-Object { ([string]$_.Hash).Replace('-', '').ToLowerInvariant() -eq [string]$file['sha256'] }).Count -gt 0
        }
        $list += [ordered]@{ object = [string]$file['object']['repoPath']; loaded = $same }
    }
    return , $list
}

function Invoke-DeliveryApply {
    # Применение кандидата: блокировка temp и проверка конфигураторов, temp не менялся с основы, main не сдвинулся,
    # слияние PR (merge_checked.py или человек), «Загрузить из git» именно этого SHA, итог. Возвращает статус.
    param($D, $State, $Setup, $GitState, [switch]$Unattended)
    $pr = $State['pr']
    $lock = Lock-DeliveryTemp
    if (-not $lock.Ok) {
        Write-DeliveryEvent $D $State 'postponed' ("применение отложено: {0}" -f $lock.Why) 'Yellow'
        Set-DeliveryStatus $D $State 'ci' ('отложено: ' + $lock.Why)
        return 'postponed'
    }
    try {
        $head = (Get-GhHead -Gh $Setup.Gh -Branch $Setup.Branch).Sha
        $headFiles = Get-GhFiles -Gh $Setup.Gh -Commit $head
        $pull = Get-GhPull -Gh $Setup.Gh -Number ([int]$pr['number'])
        $alreadyMerged = ($pull.Merged -or (Test-GhContains -Gh $Setup.Gh -Branch '' -Head $head -Commit ([string]$pr['head'])))
        $drift = Get-DeliveryTempDrift -Setup $Setup -GitState $GitState -HeadFiles $headFiles -Head $head
        if ([string]$State['status'] -eq 'loading') {
            # Повтор после обрыва: сначала - что из поставки уже стоит в temp.
            $objectStates = Get-DeliveryObjectStates -Setup $Setup -State $State -Snapshot $drift.Snapshot -HeadFiles $headFiles
            $State['recovery'] = $objectStates
            Write-DeliveryEvent $D $State 'recovery' ("повтор после обрыва, в temp сейчас: {0}" -f (@($objectStates | ForEach-Object { '{0} - {1}' -f $_['object'], $(if ($_['loaded']) { 'как в main' } else { 'не загружен' }) }) -join '; ')) 'Yellow'
        }
        if (@($drift.Changes).Count -gt 0) {
            Unlock-DeliveryTemp $lock
            Write-DeliveryEvent $D $State 'temp-changed' ("temp изменился после сборки кандидата ({0}): применение отложено, правки - в git, кандидат будет пересобран" -f ((Get-GitChangeLines $drift.Changes) -join '; ')) 'Yellow'
            $made = New-GitTempBranch -Setup $Setup -State $GitState -Base $drift.Known -Changes $drift.Changes -Note ('во время поставки ' + [string]$State['id'])
            $State['drift'] = [ordered]@{ number = $made.Number; url = $made.Url; branch = $made.Branch; commit = $made.Sha; continued = [bool]$made.Continued }
            Set-DeliveryStatus $D $State 'waiting-temp' ('правки temp в PR #{0}' -f $made.Number)
            return 'waiting-temp'
        }
        if (-not $alreadyMerged) {
            if ($head -ne [string]$pr['base']) {
                Unlock-DeliveryTemp $lock
                Write-DeliveryEvent $D $State 'main-moved' ("main сдвинулся ({0} -> {1}): пересобираю кандидат и жду CI для нового SHA" -f (Get-GitShort ([string]$pr['base'])), (Get-GitShort $head)) 'Yellow'
                Set-DeliveryStatus $D $State 'rebuild' 'main сдвинулся'
                return 'rebuild'
            }
            # CI уже дождались без блокировки (Invoke-DeliveryStep); здесь - тот же ли ещё merge SHA и прогон.
            $ci = Wait-DeliveryCi -D $D -State $State -Setup $Setup -Number ([int]$pr['number']) -NoWait
            if ($ci.Result -eq 'stale' -or $ci.Result -eq 'conflict') { Unlock-DeliveryTemp $lock; Set-DeliveryStatus $D $State 'rebuild' ('CI: ' + $ci.Result); return 'rebuild' }
            if ($ci.Result -ne 'success') { Unlock-DeliveryTemp $lock; Set-DeliveryStatus $D $State 'ci' ('CI: ' + $ci.Result); return $ci.Result }
            if (-not $D.AutoMerge) {
                Unlock-DeliveryTemp $lock
                Write-DeliveryEvent $D $State 'wait-merge' ("CI зелёный для merge {0}. Слияние - за человеком: python ci/merge_checked.py {1} --merge {0}; дальше гейт загрузит сам" -f $ci.Merge, $pr['number']) 'Yellow'
                Set-DeliveryStatus $D $State 'waiting-merge' ('ждёт слияния PR #{0}' -f $pr['number'])
                return 'waiting-merge'
            }
            $check = Invoke-DeliveryMergeCheck -D $D -Setup $Setup -Number ([int]$pr['number']) -Merge $ci.Merge
            if (-not $check.Ok) {
                Unlock-DeliveryTemp $lock
                Write-DeliveryEvent $D $State 'merge-refused' ("merge_checked.py не подтвердил слияние: {0}" -f $check.Error) 'Red'
                Set-DeliveryStatus $D $State 'waiting-merge' $check.Error
                return 'waiting-merge'
            }
            $State['merged'] = [ordered]@{ sha = $ci.Merge; how = 'merge_checked.py'; ci = $ci.Run; time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
            Write-DeliveryEvent $D $State 'merged' ("PR #{0} слит: main -> {1} (merge_checked.py, CI {2})" -f $pr['number'], $ci.Merge, $ci.Run) 'Green'
            $head = $ci.Merge
        }
        elseif ($null -eq $State['merged']) {
            $State['merged'] = [ordered]@{ sha = $head; how = 'человек'; ci = [string]$State['ci']['run']; time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
            Write-DeliveryEvent $D $State 'merged' ("PR #{0} уже в main (слил человек): гружу main {1}" -f $pr['number'], $head) 'Green'
        }
        $State['load'] = [ordered]@{ commit = $head; started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); run = ''; outcome = '' }
        Set-DeliveryStatus $D $State 'loading' ('загрузка ' + (Get-GitShort $head))
        $script:GitImportLast = $null
        $null = Invoke-GitImport -Setup $Setup -State $GitState -Unattended -ExpectCommit $head
        $outcome = $script:GitImportLast
        if ($null -eq $outcome) { $outcome = [pscustomobject]@{ outcome = 'nostart'; run = ''; note = 'загрузка не дала итога' } }
        if ([string]$outcome.outcome -eq 'same' -and -not $outcome.run) {
            # Всё уже стоит (прежняя загрузка дошла, а прогон оборвался): проверка на temp всё равно нужна.
            $outcome = Invoke-DeliveryVerifyRun -D $D -State $State -Setup $Setup -Commit $head
        }
        $State['load']['run'] = [string]$outcome.run
        $State['load']['outcome'] = [string]$outcome.outcome
        $State['load']['note'] = [string]$outcome.note
        Save-DeliveryState $D $State
        return (Complete-DeliveryRun -D $D -State $State -Setup $Setup -Outcome $outcome -Commit $head)
    }
    finally { Unlock-DeliveryTemp $lock }
}

function Invoke-DeliveryVerifyRun {
    # Прогон гейта на temp как есть (всё уже загружено, итога нет): -KitSource - тот же коммит.
    param($D, $State, $Setup, [string]$Commit)
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $Root 'run.ps1')), '-KitSource', ('"git {0}@{1}"' -f $Setup.Repo, $Commit), '-KitBranch', ('"{0}"' -f $Setup.Branch), '-OnSessions', 'Continue')
    if ($Config) { $runArgs += @('-Config', ('"{0}"' -f $Config)) }
    if ($UiChannel) { $runArgs += @('-UiChannel', ('"{0}"' -f $UiChannel)) }
    $before = @{}
    if (Test-Path -LiteralPath $runsRoot) { foreach ($dir in @(Get-ChildItem -LiteralPath $runsRoot -Directory)) { $before[$dir.Name] = $true } }
    Write-DeliveryEvent $D $State 'verify' ("всё из {0} уже в temp, итога проверки нет: прогон гейта на temp как есть" -f (Get-GitShort $Commit)) 'Cyan'
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList ($runArgs -join ' ') -NoNewWindow -PassThru
    $null = $process.Handle
    $process.WaitForExit()
    $fresh = @()
    if (Test-Path -LiteralPath $runsRoot) { $fresh = @(Get-ChildItem -LiteralPath $runsRoot -Directory | Where-Object { -not $before.ContainsKey($_.Name) -and $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name | Select-Object -Last 1) }
    if ($fresh.Count -eq 0) { return [pscustomobject]@{ outcome = 'nostart'; run = ''; note = 'прогон проверки не начался' } }
    return [pscustomobject]@{ outcome = 'verified'; run = $fresh[0].Name; note = 'проверка temp как есть' }
}

function Complete-DeliveryRun {
    # Итог поставки по прогону гейта: вердикт для загруженного SHA, загружен ли каждый объект (и в ту ли карточку).
    # Частичное (что-то не загрузилось, откат, нет итога) - никогда не GREEN.
    param($D, $State, $Setup, $Outcome, [string]$Commit)
    $run = [string]$Outcome.run
    $kind = [string]$Outcome.outcome
    $verdict = $null
    if ($run) {
        $file = Join-Path (Join-Path $runsRoot $run) 'verdict.json'
        if (Test-Path -LiteralPath $file) { $verdict = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json }
    }
    $objects = @()
    $allLoaded = $true
    foreach ($item in @(Get-DeliveryObjects $State)) {
        $object = $item['object']
        $name = [string]$object['name']
        $folder = [string]$object['folder']
        $loaded = $false
        $detail = ''
        $registration = ''
        $cardRef = ''
        if ($null -ne $verdict) {
            if ([string]$object['kind'] -eq 'extension') {
                $entry = @(@($verdict.kitItems) | Where-Object { [string]$_.name -eq $name -or [string]$_.name -eq $folder }) | Select-Object -First 1
                if ($null -ne $entry) { $loaded = [bool](Get-UiField $entry 'touched' $false); $detail = ('загружено, версия {0}' -f (Get-UiField $entry 'version' '')) }
            }
            else {
                $entry = @(@($verdict.kitProcessings) | Where-Object { [string]$_.name -eq $name -or [string]$_.objectName -eq $name }) | Select-Object -First 1
                if ($null -ne $entry) {
                    $loaded = [bool](Get-UiField $entry 'touched' $false)
                    $ref = [string](Get-UiField $entry 'ref' '')
                    $wanted = [string]$object['ref']
                    if ($wanted -and $ref -and $ref -ne $wanted) { $loaded = $false; $detail = ('записано не в ту карточку: {0}, ждали {1}' -f $ref, $wanted) }
                    else {
                        $registration = [string](Get-UiField $entry 'registration' '')
                        $cardRef = $ref
                        $detail = ('карточка {0}' -f $ref)
                    }
                }
            }
        }
        # Объект, которого в комплекте не было, но в temp он уже как в main (загрузили раньше) - считается загруженным.
        if (-not $loaded -and $null -ne $State['recovery']) {
            foreach ($entry in @($State['recovery'])) { if ([string]$entry['object'] -eq [string]$object['repoPath'] -and [bool]$entry['loaded'] -and -not $detail) { $loaded = $true; $detail = 'уже был в temp (догрузка после обрыва)' } }
        }
        if ($kind -eq 'verified') { $loaded = $true; $detail = 'в temp как в main' }
        if (-not $loaded) { $allLoaded = $false; if (-not $detail) { $detail = 'не загружен' } }
        $objects += [ordered]@{ object = [string]$object['repoPath']; title = [string]$object['title']; kind = [string]$object['kind']; loaded = $loaded; detail = $detail; ref = $cardRef; registration = $registration }
        $item['status'] = $(if ($loaded) { 'loaded' } else { 'accepted' })
    }
    $gateVerdict = ''
    if ($null -ne $verdict) { $gateVerdict = [string]$verdict.verdict }
    $final = 'PARTIAL'
    $why = ''
    switch ($kind) {
        'moved' { $final = ''; $why = 'main сдвинулся перед загрузкой' }
        'drift' { $final = ''; $why = 'temp изменился перед загрузкой' }
        'pending' { $final = ''; $why = 'PR выгрузки temp не слит' }
        'nostart' { $final = 'PARTIAL'; $why = 'прогон гейта не начался' }
        'noverdict' { $final = 'PARTIAL'; $why = 'прогон гейта без итога' }
        'rolledback' { $final = 'RED'; $why = 'комплект откачен' }
        'partial' { $final = 'PARTIAL'; $why = ('загрузилось не всё: ' + [string]$Outcome.note) }
    }
    if ($kind -eq 'loaded' -or $kind -eq 'verified' -or $kind -eq 'ran') {
        if (-not $gateVerdict) { $final = 'PARTIAL'; $why = 'нет итога гейта' }
        elseif (-not $allLoaded) { $final = 'PARTIAL'; $why = 'не все объекты поставки загружены' }
        else { $final = $gateVerdict; $why = ('вердикт гейта ' + $gateVerdict) }
    }
    if (-not $final) {
        Write-DeliveryEvent $D $State 'load-skipped' ("загрузка не сделана: {0}" -f $why) 'Yellow'
        Set-DeliveryStatus $D $State 'rebuild' $why
        return 'rebuild'
    }
    $State['result'] = [ordered]@{ verdict = $final; why = $why; run = $run; gate = $gateVerdict; commit = $Commit; objects = $objects; time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    $State['verdict'] = $final
    if ($final -eq 'GREEN') { foreach ($item in @(Get-DeliveryObjects $State)) { $item['status'] = 'verified' } }
    $color = 'Green'
    if ($final -ne 'GREEN') { $color = 'Yellow' }
    if ($final -eq 'RED' -or $final -eq 'PARTIAL') { $color = 'Red' }
    Write-DeliveryEvent $D $State 'result' ("итог: {0} - {1}; SHA {2}, прогон {3}; объекты: {4}" -f $final, $why, (Get-GitShort $Commit), $run, (@($objects | ForEach-Object { '{0}: {1}' -f $_['object'], $_['detail'] }) -join '; ')) $color
    $status = 'done'
    if ($final -eq 'PARTIAL') { $status = 'loading' }
    Set-DeliveryStatus $D $State $status ('итог ' + $final)
    $report = Get-DeliveryReport -D $D -State $State
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $D.Root ([string]$State['id'])) 'report.md'), $report, (New-Object System.Text.UTF8Encoding($false)))
    if ($null -ne $State['pr'] -and [int]$State['pr']['number'] -gt 0) {
        try { Add-GhComment -Gh $Setup.Gh -Number ([int]$State['pr']['number']) -Body (Get-DeliveryChainText $State) }
        catch { Write-RunLog ("приёмка: комментарий к PR не записан: {0}" -f $_.Exception.Message) }
    }
    return $status
}

#endregion

#region Отчёт

function Get-DeliveryChainText {
    # Цепочка поставки одним блоком: хеши -> изменения -> PR -> SHA -> объекты и карточки -> прогон и вердикт.
    param($State)
    $lines = New-Object System.Collections.Generic.List[string]
    $result = $State['result']
    $verdictText = ''
    if ($null -ne $result) { $verdictText = [string]$result['verdict'] }
    $lines.Add(("**Поставка {0}: {1}**" -f $State['id'], $verdictText))
    $lines.Add('')
    $lines.Add('1. Пришло:')
    foreach ($file in @($State['files'])) { $lines.Add(('   - `{0}` - {1}, sha256 `{2}`' -f $file['name'], $(if ($file['actualKind']) { $file['actualKind'] } else { $file['kind'] }), $file['sha256'])) }
    if ($null -ne $State['mergeSummary']) { $lines.Add(('2. Изменения: ' + [string]$State['mergeSummary'])) }
    if ($null -ne $State['pr']) { $lines.Add(('3. PR #{0}, кандидат `{1}` поверх main `{2}`' -f $State['pr']['number'], $State['pr']['head'], $State['pr']['base'])) }
    if ($null -ne $State['ci']) { $lines.Add(('4. CI: {0} для merge `{1}` (прогон {2})' -f $State['ci']['result'], $State['ci']['merge'], $State['ci']['run'])) }
    if ($null -ne $State['merged']) { $lines.Add(('5. main -> `{0}` ({1})' -f $State['merged']['sha'], $State['merged']['how'])) }
    if ($null -ne $result) {
        $lines.Add(('6. Загружено в temp из `{0}`:' -f $result['commit']))
        foreach ($object in @($result['objects'])) { $lines.Add(('   - {0}: {1}' -f $object['title'], $object['detail'])) }
        $lines.Add(('7. Прогон гейта `{0}`: {1}; итог поставки - **{2}** ({3})' -f $result['run'], $result['gate'], $result['verdict'], $result['why']))
    }
    return ($lines -join "`n")
}

function Get-DeliveryReport {
    # Отчёт поставки (markdown): реестр, сопоставление, объединение (отчёт merge1c), сборка, PR, CI, загрузка, итог.
    param($D, $State, [switch]$ForPull)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("# Поставка подрядчика {0}" -f $State['id']))
    $lines.Add('')
    $lines.Add(('Получено {0} из «Входящих»: `{1}`. Статус: {2}{3}.' -f $State['received'], $State['source'], $State['status'], $(if ($State['note']) { ' - ' + $State['note'] } else { '' })))
    $lines.Add('')
    $lines.Add('| Файл | По расширению | По факту | SHA-256 | Объект в git | Карточка | Состояние |')
    $lines.Add('|---|---|---|---|---|---|---|')
    foreach ($file in @($State['files'])) {
        $object = $file['object']
        $repo = ''
        $card = ''
        if ($null -ne $object) { $repo = [string]$object['repoPath']; $card = [string]$object['ref'] }
        $statusText = @{ received = 'получен'; accepted = 'изменения приняты'; loaded = 'загружен в temp'; verified = 'проверен на temp'; rejected = 'отклонён'; unchanged = 'нового нет' }[[string]$file['status']]
        if (-not $statusText) { $statusText = [string]$file['status'] }
        $actual = [string]$file['actualKind']
        if ([bool]$file['opaque']) { $actual += ' (не разбирается: ' + [string]$file['opaqueReason'] + ')' }
        $lines.Add(('| {0} | {1} | {2} | `{3}` | {4} | {5} | {6} |' -f $file['name'], $file['kind'], $actual, $file['sha256'], $repo, $card, $statusText))
    }
    $lines.Add('')
    foreach ($file in @($State['files'])) {
        if ($null -ne $file['object'] -and [string]$file['object']['note']) { $lines.Add(('- {0}: {1}' -f $file['name'], $file['object']['note'])) }
    }
    if ($null -ne $State['drift']) { $lines.Add(('- Правки temp перед поставкой: PR #{0} {1}{2}' -f $State['drift']['number'], $State['drift']['url'], $(if ($State['drift']['continued']) { ' (продолжен открытый)' } else { '' }))) }
    $lines.Add('')
    $mergeReport = Join-Path (Join-Path $D.Root ([string]$State['id'])) 'merge-report.md'
    if (Test-Path -LiteralPath $mergeReport) { $lines.Add([System.IO.File]::ReadAllText($mergeReport, [System.Text.Encoding]::UTF8)) }
    if ($null -ne $State['build']) {
        $lines.Add('## Сборка в технической базе')
        $lines.Add('')
        foreach ($note in @($State['build']['notes'])) { $lines.Add(('- ' + $note)) }
        $lines.Add('')
    }
    # Граница проверки: что у файла целиком проверено, а что - нет.
    $opaqueFiles = @(@($State['files']) | Where-Object { [bool]$_['opaque'] -and [string]$_['status'] -ne 'rejected' })
    if ($opaqueFiles.Count -gt 0) {
        $lines.Add('## Граница проверки')
        $lines.Add('')
        foreach ($file in $opaqueFiles) {
            $lines.Add(('- `{0}` ({1}): исходники не выгружаются - {2}. Проверено: SHA-256 `{3}` совпадает с принятым в git (binaries/manifest.json), файл открывается и регистрируется в карточке. Не проверено: код, макеты и формы внутри файла.' -f $file['name'], $file['actualKind'], $file['opaqueReason'], $file['sha256']))
        }
        $lines.Add('')
    }
    # Регистрация в справочнике (команды, назначение, публикация) - отдельно от изменений кода.
    $registered = @()
    if ($null -ne $State['result']) { $registered = @(@($State['result']['objects']) | Where-Object { $null -ne $_ -and [string]$_['kind'] -eq 'processing' }) }
    if ($registered.Count -gt 0) {
        $lines.Add('## Регистрация в справочнике «Дополнительные отчёты и обработки»')
        $lines.Add('')
        foreach ($item in $registered) {
            $text = [string]$item['registration']
            if (-not $text) { $text = 'команды, назначение и публикация не менялись' }
            $refText = [string]$item['ref']
            if (-not $refText) { $refText = 'не записана' }
            $lines.Add(('- {0}: карточка `{1}`; {2}' -f $item['title'], $refText, $text))
        }
        $lines.Add('')
    }
    if (-not $ForPull) {
        $lines.Add('## Цепочка')
        $lines.Add('')
        $lines.Add((Get-DeliveryChainText $State))
        $lines.Add('')
    }
    else {
        $lines.Add('Перед слиянием - CI для текущего merge SHA (`python ci/merge_checked.py <номер>`); после слияния гейт загружает именно этот SHA в temp и пишет итог сюда комментарием.')
    }
    return ($lines -join "`n")
}

#endregion

#region Проход

function Invoke-DeliveryStep {
    # Одна поставка - от текущего статуса как можно дальше. Каждый шаг сверяет фактическое состояние.
    param($D, $Setup, $GitState, [string]$Id, [switch]$Unattended)
    $State = Read-DeliveryState $D $Id
    if ($null -eq $State) { return }
    if ([string]$State['status'] -eq 'done') { return }
    Write-Line ("Поставка {0}: {1}" -f $Id, [string]$State['status']) 'Cyan'
    # 1. Разбор - один раз (результат - в state.json).
    $needDump = @(@($State['files']) | Where-Object { -not [string]$_['actualKind'] -and -not [bool]$_['opaque'] })
    if ($needDump.Count -gt 0) {
        $tech = Initialize-TechBase $D
        Write-DeliveryEvent $D $State 'tech' $tech.Note
        if (-not $tech.Ok) { Set-DeliveryStatus $D $State 'received' ('техническая база: ' + $tech.Note); return }
        $index = 0
        foreach ($file in @($State['files'])) {
            $index++
            if ([string]$file['actualKind'] -or [bool]$file['opaque']) { continue }
            $expanded = Expand-DeliveryFile -D $D -State $State -File $file -Index $index
            if ($expanded.Ok) {
                $file['actualKind'] = $expanded.Kind
                $file['dump'] = $expanded.Dir
                $file['identity'] = [ordered]@{ kind = $expanded.Identity.Kind; name = $expanded.Identity.Name; uuid = $expanded.Identity.Uuid; isReport = [bool]$expanded.Identity.IsReport; namePrefix = $expanded.Identity.NamePrefix; purpose = $expanded.Identity.Purpose; version = $expanded.Identity.Version }
                $kindText = @{ extension = 'расширение'; processing = 'внешняя обработка'; report = 'внешний отчёт' }[$expanded.Kind]
                $mismatch = ''
                if (($file['kind'] -eq 'cfe' -and $expanded.Kind -ne 'extension') -or ($file['kind'] -eq 'epf' -and $expanded.Kind -ne 'processing') -or ($file['kind'] -eq 'erf' -and $expanded.Kind -ne 'report')) { $mismatch = (' (расширение файла .{0} не соответствует)' -f $file['kind']) }
                Write-DeliveryEvent $D $State 'dump' ("{0}: {1} {2}, UUID {3}{4}" -f $file['name'], $kindText, $expanded.Identity.Name, $expanded.Identity.Uuid, $mismatch)
            }
            else {
                $file['opaque'] = $true
                $file['opaqueReason'] = $expanded.Reason
                if ($null -ne $expanded.Identity) {
                    $file['actualKind'] = $expanded.Kind
                    $file['identity'] = [ordered]@{ kind = $expanded.Identity.Kind; name = $expanded.Identity.Name; uuid = $expanded.Identity.Uuid; isReport = [bool]$expanded.Identity.IsReport; namePrefix = ''; purpose = ''; version = '' }
                }
                elseif ($file['kind'] -ne 'cfe') {
                    # Не разобрался совсем: тип - по расширению, имя объекта - по имени файла (только для сопоставления карточки).
                    $file['actualKind'] = @{ epf = 'processing'; erf = 'report' }[[string]$file['kind']]
                    $file['identity'] = [ordered]@{ kind = $file['actualKind']; name = [System.IO.Path]::GetFileNameWithoutExtension([string]$file['name']); uuid = ''; isReport = ($file['kind'] -eq 'erf'); namePrefix = ''; purpose = ''; version = '' }
                }
                Write-DeliveryEvent $D $State 'opaque' ("{0}: исходники не выгружаются ({1}) - только выбор файла целиком" -f $file['name'], $expanded.Reason) 'Yellow'
            }
            Save-DeliveryState $D $State
        }
    }
    $cfeOpaque = @(@($State['files']) | Where-Object { [bool]$_['opaque'] -and $null -eq $_['identity'] })
    if ($cfeOpaque.Count -gt 0) {
        Write-DeliveryEvent $D $State 'failed' ("не разобралось ни как расширение, ни как обработка: {0} - поставка остановлена, файл сохранён в реестре" -f (@($cfeOpaque | ForEach-Object { '{0} ({1})' -f $_['name'], $_['opaqueReason'] }) -join '; ')) 'Red'
        $State['verdict'] = 'FAILED'
        Set-DeliveryStatus $D $State 'done' 'не разобралось'
        return
    }
    for ($round = 0; $round -lt 4; $round++) {
        # 2. temp и main: правки temp - в git, дальше - поверх них.
        $sync = Sync-DeliveryTemp -D $D -State $State -Setup $Setup -GitState $GitState -Unattended:$Unattended
        if (-not $sync.Ready) { return }
        $base = (Get-GhHead -Gh $Setup.Gh -Branch $Setup.Branch).Sha
        $ready = ($null -ne $State['pr'] -and [string]$State['pr']['base'] -eq $base -and @('rebuild', 'waiting-decision', 'waiting-temp', 'received') -notcontains [string]$State['status'])
        if ([string]$State['status'] -eq 'loading' -and $null -ne $State['load']) { $ready = $true }
        if (-not $ready) {
            # 3. Сопоставление (карточки - по справочнику temp, только что прочитанному).
            $oursProbe = Join-Path (Join-Path $D.Root $Id) 'ours-probe'
            if (Test-Path -LiteralPath $oursProbe) { Remove-Item -LiteralPath $oursProbe -Recurse -Force }
            $baseFiles = Get-GhFiles -Gh $Setup.Gh -Commit $base
            $null = Save-GhFiles -Gh $Setup.Gh -Commit $base -Prefixes @('extensions/', 'deliveries/bindings.json', 'processings/manifest.json') -Target $oursProbe -Expected $baseFiles
            # Корни обработок в git нужны для имён выгрузок: скачиваем только корневые XML.
            foreach ($path in @($baseFiles.Keys | Where-Object { $_ -match '^processings/[^/]+/[^/]+\.xml$' })) {
                $target = Join-Path $oursProbe $path.Replace('/', '\')
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                [System.IO.File]::WriteAllBytes($target, (Get-GhBlob -Gh $Setup.Gh -Sha ([string]$baseFiles[$path])))
            }
            $mapped = Resolve-DeliveryTargets -D $D -State $State -Setup $Setup -HeadFiles $baseFiles -Ours $oursProbe -Cards $sync.Cards -Unattended:$Unattended
            if (-not $mapped) { Set-DeliveryStatus $D $State 'waiting-decision' 'нужно выбрать цель'; return }
            foreach ($file in @(Get-DeliveryObjects $State)) {
                if ([string]$file['object']['kind'] -ne 'processing' -or [bool]$file['opaque'] -or -not [string]$file['dump']) { continue }
                $rootXml = @(Get-ChildItem -LiteralPath (Join-Path $oursProbe ([string]$file['object']['repoPath']).Replace('/', '\')) -Filter '*.xml' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
                $rootName = [string]$file['identity']['name']
                if ($rootXml.Count -gt 0) { $rootName = $rootXml[0].BaseName }
                Rename-ProcessingDump -Dir ([string]$file['dump']) -RootName $rootName
            }
            # 4. Объединение.
            $result = Invoke-DeliveryMerge -D $D -State $State -Setup $Setup -Base $base -Unattended:$Unattended
            if ($null -eq $result) { Set-DeliveryStatus $D $State 'received' 'объединение не выполнилось'; return }
            $counts = @{}
            foreach ($object in @($result['objects'])) { foreach ($key in @($object['counts'].Keys)) { $counts[$key] = [int]$counts[$key] + [int]$object['counts'][$key] } }
            $State['mergeSummary'] = ('принято из поставки {0}, оставлено наше {1}, решено человеком {2}, ждёт решения {3}' -f ([int]$counts['theirs-new'] + [int]$counts['theirs-changed']), ([int]$counts['ours-only'] + [int]$counts['stale'] + [int]$counts['rejected-again']), [int]$counts['decided'], [int]$result['pending'])
            Write-DeliveryEvent $D $State 'merge' ('объединение: ' + $State['mergeSummary'])
            if ([int]$result['pending'] -gt 0) {
                Set-DeliveryStatus $D $State 'waiting-decision' ('ждут решения: {0}' -f $result['pending'])
                [System.IO.File]::WriteAllText((Join-Path (Join-Path $D.Root $Id) 'report.md'), (Get-DeliveryReport -D $D -State $State), (New-Object System.Text.UTF8Encoding($false)))
                return
            }
            $changed = @(@($result['objects']) | Where-Object { @('changed', 'new', 'opaque') -contains [string]$_['status'] })
            if ($changed.Count -eq 0) {
                foreach ($file in @(Get-DeliveryObjects $State)) { $file['status'] = 'unchanged' }
                $State['verdict'] = 'UNCHANGED'
                Write-DeliveryEvent $D $State 'unchanged' 'нового нет: всё в поставке уже есть в истории или отклонено раньше - PR и загрузка не нужны' 'Green'
                Set-DeliveryStatus $D $State 'done' 'нового нет'
                [System.IO.File]::WriteAllText((Join-Path (Join-Path $D.Root $Id) 'report.md'), (Get-DeliveryReport -D $D -State $State), (New-Object System.Text.UTF8Encoding($false)))
                return
            }
            # 5. Сборка и применимость.
            if (-not (Test-DeliveryBuild -D $D -State $State -Result $result)) { Set-DeliveryStatus $D $State 'received' 'объединённое не собралось'; return }
            foreach ($file in @(Get-DeliveryObjects $State)) { $file['status'] = 'accepted' }
            # 6. Кандидат и PR.
            $pr = Publish-DeliveryCandidate -D $D -State $State -Setup $Setup -Result $result -Base $base
            if ($null -eq $pr) { Set-DeliveryStatus $D $State 'done' 'нечего коммитить'; return }
            Set-DeliveryStatus $D $State 'pr' ('PR #{0}' -f $pr['number'])
        }
        # 7. CI - без блокировки temp: ждать проверку, держа базу закрытой, нельзя.
        $pull = Get-GhPull -Gh $Setup.Gh -Number ([int]$State['pr']['number'])
        $inMain = ($pull.Merged -or (Test-GhContains -Gh $Setup.Gh -Branch $Setup.Branch -Commit ([string]$State['pr']['head'])))
        if (-not $inMain -and [string]$State['status'] -ne 'loading') {
            if ($pull.State -ne 'open') { Write-DeliveryEvent $D $State 'pull-closed' ("PR #{0} закрыт без слияния: поставка остановлена" -f $pull.Number) 'Red'; $State['verdict'] = 'FAILED'; Set-DeliveryStatus $D $State 'done' 'PR закрыт без слияния'; return }
            $ci = Wait-DeliveryCi -D $D -State $State -Setup $Setup -Number ([int]$State['pr']['number'])
            if ($ci.Result -eq 'stale' -or $ci.Result -eq 'conflict') {
                Write-DeliveryEvent $D $State 'rebuild' ("CI: {0} - пересобираю кандидат поверх текущего main" -f $ci.Result) 'Yellow'
                Set-DeliveryStatus $D $State 'rebuild' ('CI: ' + $ci.Result)
                continue
            }
            if ($ci.Result -eq 'failure') {
                Write-DeliveryEvent $D $State 'ci-red' ("CI красный для merge {0}: загрузка в temp не начинается. Разбор - в PR #{1}" -f $ci.Merge, $State['pr']['number']) 'Red'
                Set-DeliveryStatus $D $State 'ci-red' 'CI красный: в temp не грузилось'
                return
            }
            if ($ci.Result -ne 'success') { Set-DeliveryStatus $D $State 'ci' 'CI ещё идёт'; return }
        }
        # 8. Применение под блокировкой temp.
        $applied = Invoke-DeliveryApply -D $D -State $State -Setup $Setup -GitState $GitState -Unattended:$Unattended
        if ($applied -ne 'rebuild' -and $applied -ne 'waiting-temp') { return }
        $State = Read-DeliveryState $D $Id
        $GitState = Read-GitState $Setup
    }
}

function Invoke-Delivery {
    # Проход: новое во «Входящих» -> реестр; потом каждая незаконченная поставка - как можно дальше. Два прохода сразу
    # не идут (deliveries\pass.lock). Код: 0 - всё прошло или ждёт, 1 - ошибка.
    param([switch]$Unattended, [string]$OnlyId = '')
    $D = Get-DeliverySetup
    if (-not (Test-Path -LiteralPath $D.Merge)) { throw ("нет {0} (merge1c - объединение поставок): поставь гейт из релиза или задай DeliveryMergeExe" -f $D.Merge) }
    $passLock = Join-Path $D.Root 'pass.lock'
    if (Test-Path -LiteralPath $passLock) {
        $owner = ([System.IO.File]::ReadAllText($passLock)).Trim()
        $alive = $false
        try { $alive = $null -ne (Get-Process -Id ([int]$owner) -ErrorAction Stop) } catch { $alive = $false }
        if ($alive -and [int]$owner -ne $PID) { Write-Line ("Приёмка поставок уже идёт (процесс {0}): выхожу." -f $owner) 'Yellow'; return 0 }
    }
    [System.IO.File]::WriteAllText($passLock, [string]$PID)
    try {
        $setup = Get-GitSetup
        $gitState = Read-GitState $setup
        Write-Host ''
        Write-Host ("ПРИЁМКА ПОСТАВОК: «Входящие» {0} -> {1} ({2}) -> {3}" -f $D.Inbox, $setup.Repo, $setup.Branch, $script:TempBase) -ForegroundColor Cyan
        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($item in @(Get-ChildItem -LiteralPath $D.Inbox -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)) {
            $id = Receive-DeliveryEntry -D $D -Item $item
            if ($id -and -not $ids.Contains($id)) { $ids.Add($id) }
        }
        foreach ($dir in @(Get-ChildItem -LiteralPath $D.Root -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}-[0-9a-f]{6}$' } | Sort-Object Name)) {
            if (-not $ids.Contains($dir.Name)) { $ids.Add($dir.Name) }
        }
        if ($OnlyId) { $ids = New-Object System.Collections.Generic.List[string]; $ids.Add($OnlyId) }
        $worked = 0
        $failed = 0
        foreach ($id in $ids) {
            $state = Read-DeliveryState $D $id
            if ($null -eq $state -or [string]$state['status'] -eq 'done') { continue }
            $worked++
            try { Invoke-DeliveryStep -D $D -Setup $setup -GitState $gitState -Id $id -Unattended:$Unattended }
            catch {
                # Сбой этапа: причина и место - в журнал поставки; состояние остаётся как было, следующий проход
                # начинает с проверки фактического состояния.
                $failed++
                $where = ([string]$_.ScriptStackTrace -split "`r?`n" | Select-Object -First 3) -join ' <- '
                $state = Read-DeliveryState $D $id
                if ($null -ne $state) { Write-DeliveryEvent $D $state 'error' ("сбой: {0} ({1})" -f $_.Exception.Message, $where) 'Red' }
                else { Write-Line ("Поставка {0}: сбой: {1} ({2})" -f $id, $_.Exception.Message, $where) 'Red' }
                if ($null -ne $script:DeliveryTempLock) { Unlock-DeliveryTemp $script:DeliveryTempLock }
            }
            $gitState = Read-GitState $setup
            $state = Read-DeliveryState $D $id
            $report = Get-DeliveryReport -D $D -State $state
            [System.IO.File]::WriteAllText((Join-Path (Join-Path $D.Root $id) 'report.md'), $report, (New-Object System.Text.UTF8Encoding($false)))
            Write-Line ("Поставка {0}: {1} {2}. Отчёт: {3}" -f $id, [string]$state['status'], [string]$state['verdict'], (Join-Path (Join-Path $D.Root $id) 'report.md')) 'Cyan'
        }
        if ($worked -eq 0) { Write-Line 'Поставок в работе нет, во «Входящих» пусто.' 'Green' }
        Update-DeliveryOpenList $D
        if ($failed -gt 0) { return 1 }
        return 0
    }
    finally {
        if ($null -ne $script:DeliveryTempLock) { Unlock-DeliveryTemp $script:DeliveryTempLock }
        Remove-Item -LiteralPath $passLock -Force -ErrorAction SilentlyContinue
    }
}

#endregion
