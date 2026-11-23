#requires -Version 5.1
# Приёмка поставок подрядчика (раздел 5.26): от «Входящих» до вердикта гейта - подставная 1С (техническая база,
# разбор .cfe/.epf/.erf архивами выгрузки), подставной GitHub (PR, CI, слияние по точному merge SHA), подставной COM
# (сеансы и блокировка temp, карточки справочника). Подключается точкой из tests.ps1 и возвращает массив тестов.

$script:DExtUuid = 'aaaaaaaa-0000-0000-0000-0000000000e1'
$script:DDocUuid = 'bbbbbbbb-0000-0000-0000-0000000000d1'
$script:DAttrUuid = @{ 'Организация' = 'cccccccc-0000-0000-0000-0000000000c1'; 'Склад' = 'cccccccc-0000-0000-0000-0000000000c2' }

function New-DText {
    # Текст выгрузки: строки через `n (подставная 1С сама пишет BOM и CRLF).
    param([string[]]$Lines)
    return (($Lines -join "`n") + "`n")
}

function New-DExtConfig {
    param([string]$Version = '1.0.0.1')
    return (New-DText @(
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" version="2.20">',
            ("`t<Configuration uuid=""{0}"">" -f $script:DExtUuid),
            "`t`t<Properties>",
            "`t`t`t<Name>Доработки</Name>",
            "`t`t`t<NamePrefix>Д_</NamePrefix>",
            ("`t`t`t<Version>{0}</Version>" -f $Version),
            "`t`t</Properties>",
            "`t`t<ChildObjects>",
            "`t`t`t<Document>Заказ</Document>",
            "`t`t</ChildObjects>",
            "`t</Configuration>",
            '</MetaDataObject>'))
}

function New-DDocXml {
    param([string[]]$Attributes = @('Организация'))
    $lines = @('<?xml version="1.0" encoding="UTF-8"?>', '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" version="2.20">',
        ("`t<Document uuid=""{0}"">" -f $script:DDocUuid), "`t`t<Properties>", "`t`t`t<Name>Заказ</Name>", "`t`t</Properties>", "`t`t<ChildObjects>")
    foreach ($name in $Attributes) {
        $lines += @(("`t`t`t<Attribute uuid=""{0}"">" -f $script:DAttrUuid[$name]), "`t`t`t`t<Properties>", ("`t`t`t`t`t<Name>{0}</Name>" -f $name), "`t`t`t`t</Properties>", "`t`t`t</Attribute>")
    }
    $lines += @("`t`t</ChildObjects>", "`t</Document>", '</MetaDataObject>')
    return (New-DText $lines)
}

function New-DModule {
    # Модуль документа: округление (Digits), скидка (Discount) и, если задано, новая функция поставки.
    param([string]$Digits = '2', [string]$Discount = '0', [string]$Extra = '')
    $lines = @('#Область СлужебныеПроцедурыИФункции', '', 'Процедура Пересчитать()', ("`tСумма = Окр(Цена * Количество, {0});" -f $Digits), 'КонецПроцедуры', '',
        'Функция Скидка(Сумма)', ("`tВозврат {0};" -f $Discount), 'КонецФункции')
    if ($Extra) { $lines += @('', 'Функция Наценка(Сумма)', ("`tВозврат {0};" -f $Extra), 'КонецФункции') }
    $lines += @('', '#КонецОбласти')
    return (New-DText $lines)
}

function New-DExtFiles {
    param([string[]]$Attributes = @('Организация'), [string]$Module = '', [string]$Version = '1.0.0.1')
    if (-not $Module) { $Module = New-DModule }
    return @{ 'Configuration.xml' = (New-DExtConfig $Version); 'Documents/Заказ.xml' = (New-DDocXml $Attributes); 'Documents/Заказ/Ext/ObjectModule.bsl' = $Module }
}

function New-DDumps {
    # Выгрузки temp для подставной 1С: Адаптация как в остальных тестах git, Доработки - документ с модулем.
    param($Ext = $null, [hashtable]$Extra = @{})
    if ($null -eq $Ext) { $Ext = New-DExtFiles }
    $dumps = @{ 'Адаптация' = @{ 'CommonModules/АГБ_Общий/Ext/Module.bsl' = 'Процедура Старая() КонецПроцедуры' }; 'Доработки' = $Ext }
    foreach ($key in @($Extra.Keys)) { $dumps[$key] = $Extra[$key] }
    return $dumps
}

function New-DZip {
    # Подставной бинарник поставки: архив выгрузки в файлы, тексты - как у конфигуратора (BOM, CRLF).
    param([string]$Path, [hashtable]$Files, [switch]$Protected)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $names = @($Files.Keys)
        if ($Protected) { $names += 'PROTECTED' }
        foreach ($name in $names) {
            $entry = $archive.CreateEntry($name)
            $stream = $entry.Open()
            try {
                $text = 'protected'
                if ($Files.ContainsKey($name)) { $text = ([string]$Files[$name]).Replace("`r`n", "`n").Replace("`n", "`r`n") }
                $bytes = $utf8Bom.GetPreamble() + $utf8.GetBytes($text)
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally { $stream.Dispose() }
        }
    }
    finally { $archive.Dispose() }
    # Время файла - в прошлом: приёмка берёт из «Входящих» только докопированное.
    (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddMinutes(-5)
    return $Path
}

function New-DReportFiles {
    param([string]$Name = 'ОтчётПродаж', [string]$Body = 'Отбор = Документ.Д_Склад;')
    $root = New-DText @('<?xml version="1.0" encoding="UTF-8"?>', '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" version="2.20">',
        ("`t<ExternalReport uuid=""eeeeeeee-0000-0000-0000-0000000000f1"">" -f $Name), "`t`t<Properties>", ("`t`t`t<Name>{0}</Name>" -f $Name), "`t`t</Properties>", "`t</ExternalReport>", '</MetaDataObject>')
    $module = New-DText @('Процедура ПриКомпоновкеРезультата(ДокументРезультат, ДанныеРасшифровки, СтандартнаяОбработка)', ("`t{0}" -f $Body), 'КонецПроцедуры')
    return @{ ($Name + '.xml') = $root; ($Name + '/Ext/ObjectModule.bsl') = $module }
}

function New-DProcFiles {
    # Выгрузка внешней обработки (архивом - подставной .epf с исходниками). Root - имя корневого файла (по умолчанию Name).
    param([string]$Name, [string]$Body = 'Процедура Открыть() КонецПроцедуры', [string]$Uuid = 'eeeeeeee-0000-0000-0000-0000000000f2', [string]$Root = '')
    if (-not $Root) { $Root = $Name }
    $xml = New-DText @('<?xml version="1.0" encoding="UTF-8"?>', '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" version="2.20">',
        ("`t<ExternalDataProcessor uuid=""{0}"">" -f $Uuid), "`t`t<Properties>", ("`t`t`t<Name>{0}</Name>" -f $Name), "`t`t</Properties>", "`t</ExternalDataProcessor>", '</MetaDataObject>')
    return @{ ($Root + '.xml') = $xml; ($Root + '/Ext/ObjectModule.bsl') = (New-DText @($Body)) }
}

function New-DeliverySandbox {
    # Песочница git (как у «Загрузить из git») и первая выгрузка temp, принятая владельцем.
    param([string]$Name, [hashtable]$Extra = @{}, $Com, $Dumps)
    $config = @{ DeliveryAutoMerge = $true; DeliveryCiWaitMin = 0; DeliverySettleSec = 0 }
    foreach ($key in @($Extra.Keys)) { $config[$key] = $Extra[$key] }
    $sb = New-GitSandbox $Name -Extra $config
    $gh = Get-FakeGh $sb
    [System.IO.File]::WriteAllText((Join-Path $sb 'fake-github\ci-default.txt'), "completed`tsuccess", $utf8)
    # Вопрос «Вести в git и внешние обработки» - только если в temp есть карточки справочника.
    $answers = $gitBootstrapAnswers
    if (@($Com['bases']['erp_temp_test']['processings']).Count -eq 0) { $answers = @($gitBootstrapAnswers | Where-Object { $_.Header -ne 'Вести в git и внешние обработки' }) }
    $boot = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-GitExport' -Fake @{ dumps = $Dumps } -Com $Com -Answers $answers
    Check-DeployCommon $boot -LocksExpected $false
    $state = Read-GitStateFile $sb
    if ($state.pendingCommit) { Set-GhBranch -Gh $gh -Branch 'main' -Sha $state.pendingCommit }
    [System.IO.File]::WriteAllText((Join-Path $sb 'run.ps1'), $script:DeliveryRunStub, $utf8Bom)
    Reset-FakeState $sb
    return $sb
}

# Заглушка гейта для приёмки: как у «Загрузить из git», плюс обработки комплекта (папки выгрузок и файлы целиком,
# ссылка карточки - из .gate.json) и режим из stub-mode.txt: GREEN (по умолчанию), RED, CRASH (прогон оборвался - без итога).
$script:DeliveryRunStub = @'
param([string]$Kit = '', [string]$KitSource = '', [string]$KitBranch = '', [string]$ActionsDir = '', [string]$Config = '', [string]$UiChannel = '', [string]$OnNotGreen = '', [string]$OnSessions = '')
$dir = Join-Path $PSScriptRoot ('runs\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$mode = 'GREEN'
$modeFile = Join-Path $PSScriptRoot 'stub-mode.txt'
if (Test-Path -LiteralPath $modeFile) { $mode = ([System.IO.File]::ReadAllText($modeFile)).Trim() }
$lines = @(('Kit=' + $Kit), ('KitSource=' + $KitSource), ('OnNotGreen=' + $OnNotGreen), ('OnSessions=' + $OnSessions), ('Mode=' + $mode))
$items = @()
$procs = @()
if ($Kit) {
    foreach ($sub in @(Get-ChildItem -LiteralPath $Kit -Directory | Sort-Object Name)) {
        $lines += ('dir=' + $sub.Name)
        if (Test-Path -LiteralPath (Join-Path $sub.FullName 'Configuration.xml')) { $items += @{ name = $sub.Name; loadTried = $true; touched = $true; loaded = $true; version = 'stub' }; continue }
        $ref = ''
        $side = $sub.FullName + '.gate.json'
        if (Test-Path -LiteralPath $side) { $ref = [string]([System.IO.File]::ReadAllText($side) | ConvertFrom-Json).ref }
        $root = @(Get-ChildItem -LiteralPath $sub.FullName -Filter '*.xml' -File | Select-Object -First 1)
        $name = $sub.Name
        if ($root.Count -gt 0) { $name = $root[0].BaseName }
        if (-not $ref) { $ref = '00000000-0000-0000-0000-00000000aaaa' }
        $procs += @{ name = $name; objectName = $name; ref = $ref; touched = $true; tried = $true; loaded = $true; targetRef = $ref; registration = 'назначение сохранено: 1' }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Kit -File | Where-Object { $_.Extension -eq '.epf' -or $_.Extension -eq '.erf' })) {
        $lines += ('binary=' + $file.Name)
        $side = Join-Path $Kit ($file.Name + '.gate.json')
        $sha = ''
        if (Test-Path -LiteralPath $side) { $sha = [string]([System.IO.File]::ReadAllText($side) | ConvertFrom-Json).sha256; $lines += ('sha256=' + $sha) }
        $procs += @{ name = $file.BaseName; objectName = $file.BaseName; ref = '00000000-0000-0000-0000-00000000bbbb'; touched = $true; tried = $true; loaded = $true; expectSha256 = $sha }
    }
}
[System.IO.File]::WriteAllLines((Join-Path $dir 'stub.txt'), [string[]]$lines, (New-Object System.Text.UTF8Encoding($true)))
if ($mode -eq 'CRASH') { Write-Host 'заглушка гейта: прогон оборвался'; exit 1 }
$verdict = @{ verdict = $mode; runId = (Split-Path -Leaf $dir); kitDecision = ''; kitItems = $items; kitProcessings = $procs }
[System.IO.File]::WriteAllText((Join-Path $dir 'verdict.json'), (ConvertTo-Json -InputObject $verdict -Depth 4), (New-Object System.Text.UTF8Encoding($true)))
Write-Host ('заглушка гейта: прогон записан, ' + $mode)
'@

function Get-DeliveryStates {
    param([string]$Sandbox)
    $root = Join-Path $Sandbox 'deliveries'
    $list = @()
    if (-not (Test-Path -LiteralPath $root)) { return $list }
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}-[0-9a-f]{6}$' } | Sort-Object Name)) {
        $file = Join-Path $dir.FullName 'state.json'
        if (Test-Path -LiteralPath $file) { $list += ([System.IO.File]::ReadAllText($file, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json) }
    }
    return $list
}

function Get-DPulls {
    param([string]$Sandbox)
    $file = Join-Path $Sandbox 'fake-github\pulls.txt'
    # Запятая: один PR - всё равно массив (.Count под StrictMode).
    if (-not (Test-Path -LiteralPath $file)) { return , @() }
    return , @([System.IO.File]::ReadAllLines($file, $utf8) | Where-Object { $_ })
}

function Get-DMainText {
    # Текст файла main подставного GitHub (без BOM, переводы строк - `n).
    param($Gh, [string]$Path)
    $files = Get-GhFiles -Gh $Gh -Commit (Get-GhHead -Gh $Gh -Branch 'main').Sha
    if (-not $files.ContainsKey($Path)) { return $null }
    return ($utf8.GetString((Get-GhBlob -Gh $Gh -Sha $files[$Path])).TrimStart([char]0xFEFF).Replace("`r`n", "`n"))
}

function Get-DMainExt {
    # Расширение Доработки из main - выгрузкой для подставной 1С (как будто temp на main).
    param($Gh)
    $files = Get-GhFiles -Gh $Gh -Commit (Get-GhHead -Gh $Gh -Branch 'main').Sha
    $ext = @{}
    foreach ($path in @($files.Keys | Where-Object { $_.StartsWith('extensions/Доработки/') })) {
        $ext[$path.Substring('extensions/Доработки/'.Length)] = $utf8.GetString((Get-GhBlob -Gh $Gh -Sha $files[$path])).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
    }
    return $ext
}

function Get-DStubs {
    param([string]$Sandbox)
    return , @(Get-ChildItem -LiteralPath (Join-Path $Sandbox 'runs') -Recurse -Filter 'stub.txt' -ErrorAction SilentlyContinue | Sort-Object { $_.Directory.Name } | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName, $utf8) })
}

function Check-DeliveryCommon {
    # Для каждого прохода приёмки: как у deploy, плюс блокировка temp снята и рабочая не тронута.
    param($Result)
    Check-DeployCommon $Result -LocksExpected $false
    if ($null -ne $Result.ComState) {
        $temp = $Result.ComState.bases.erp_temp_test
        Check (-not [bool]$temp.sessionsDenied) 'после приёмки осталась блокировка начала сеансов temp'
    }
    $prodCalls = @($Result.Calls | Where-Object { $_.Line -match 'erp_base(?!_)' })
    Check ($prodCalls.Count -eq 0) 'приёмка обратилась к рабочей базе'
}

@(
    # ** Хлебников С.Ю. 20261123 Отказы до публикации результата и владение служебным расширением.
    @{
        Name='delivery-worker-isolation'
        Text='Очистка только своего имени, остановка при подмене и отклонение путей вне ZIP'
        Run={
            param($Name)
            . (Join-Path $ciRoot 'delivery-designer.ps1')
            . (Join-Path $ciRoot 'delivery-parcel.ps1')
            $work = Join-Path $workRoot $Name
            [void][IO.Directory]::CreateDirectory($work)
            $profile = @{ WorkRoot=$work; Server='localhost'; Base='worker_test' }
            $inventory = [Collections.ArrayList]@('UserExt','Поставка1','Сборка1')
            $deleted = [Collections.ArrayList]@()
            function Get-WorkerInventory { param($Profile,$Log) foreach ($n in $inventory) { $n } }
            function Invoke-WorkerDesigner {
                param($Profile,$Command,$Log)
                $slot = $Command[-1]
                if ($slot -cnotmatch '^GateJob[a-f0-9]{32}$' -or $Command[-2] -cne '-Extension') { throw 'Недопустимая команда' }
                switch ($Command[0]) {
                    '/LoadCfg' { [void]$inventory.Add($slot); if ($ambiguous) { [void]$inventory.Add('Unexpected') } }
                    '/DumpConfigToFiles' { [IO.File]::WriteAllText((Join-Path $Command[1].Trim('"') 'Configuration.xml'),'<root/>') }
                    '/DeleteCfg' { $inventory.Remove($slot); [void]$deleted.Add($slot) }
                    default { throw 'Лишний вызов 1С' }
                }
            }
            $ambiguous = $false
            Invoke-WorkerExtension $profile expand 'sample.cfe' (Join-Path $work 'result') $work
            Check ($deleted.Count -eq 1 -and ($inventory -join '|') -eq 'UserExt|Поставка1|Сборка1') 'изменилось чужое расширение'
            $ambiguous = $true
            $stopped = try { Invoke-WorkerExtension $profile expand 'sample.cfe' (Join-Path $work 'result2') $work; $false } catch { $true }
            Check ($stopped -and $deleted.Count -eq 1 -and [IO.File]::Exists((Join-Path $work 'active-extension.json'))) 'после неоднозначной загрузки очистка должна остановиться'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $path = Join-Path $work 'bad.zip'
            $zip = [IO.Compression.ZipFile]::Open($path,'Create')
            try { [void]$zip.CreateEntry('../outside.bsl') } finally { $zip.Dispose() }
            $stopped = try { Expand-ParcelArchive $path (Join-Path $work 'tree'); $false } catch { $true }
            Check ($stopped -and -not [IO.File]::Exists((Join-Path $work 'outside.bsl'))) 'выход из каталога результата'
        }
    }
    # ** Хлебников С.Ю. 20261123 конец
    # ** Хлебников С.Ю. 20261123 Два удалённых задания, перезапуск между этапами и один PR кандидата.
    @{
        Name = 'delivery-remote'
        Text = 'Удалённая приёмка CFE: ожидание, проверка двух ответов, PR, CI и загрузка в temp'
        Run = {
            param($Name)
            . (Join-Path $ciRoot 'delivery-parcel.ps1')
            $dumps = New-DDumps
            $sb = New-DeliverySandbox $Name -Com (New-ComState) -Dumps $dumps -Extra @{DeliveryWorkerRepo='test/queue'; DeliveryWorkerWaitMin=0}
            $gh = Get-FakeGh $sb
            $inputFile = New-DZip -Path (Join-Path $sb 'Входящие\test.cfe') -Files (New-DExtFiles -Module (New-DModule -Extra '42'))
            $original = [IO.File]::ReadAllBytes($inputFile)
            foreach ($op in @('expand-cfe','build-cfe')) {
                $run = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{dumps=$dumps} -Com $null
                $state = @(Get-DeliveryStates $sb)[0]
                Check ($run.ExitCode -eq 0 -and $state.status -eq 'waiting-worker') ("нет ожидания $op : " + ($run.Output -join '|'))
                Check (@($run.Calls | Where-Object { $_.Line -match 'CREATEINFOBASE|/F"' }).Count -eq 0) 'задействована файловая база'
                $queue = Read-ParcelQueue $gh
                $pending = @($queue.Files.Keys | Where-Object { $_ -like 'jobs/*/job.json' -and -not $queue.Files.ContainsKey($_.Replace('job.json','result.json')) })
                Check ($pending.Count -eq 1) 'ожидали одно задание'
                $job = Get-ParcelJson $gh $queue $pending[0]
                $key = Get-ParcelId $job
                Check ($job.operation -eq $op -and $pending[0] -eq "jobs/$key/job.json") 'другая операция или ключ'
                $bytes = Read-ParcelPayload $gh $queue "jobs/$key/job.bin" $job.input
                $badHash = try { $null = Read-ParcelPayload $gh $queue "jobs/$key/job.bin" ('0'*64); $false } catch { $true }
                Check $badHash 'повреждение SHA-256 не обнаружено'
                if ($op -eq 'expand-cfe') { Check ((Get-ParcelHash $bytes) -eq (Get-ParcelHash $original)) 'отправлен другой оригинал' }
                $answer = @{version=1; job=$key; input=$job.input; status='ok'; output=(Get-ParcelHash $original)}
                Publish-Parcel $gh $queue $key result $answer $original
            }
            $run = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{dumps=$dumps} -Com $null
            Check-DeliveryCommon $run
            $state = @(Get-DeliveryStates $sb)[0]
            Check ($run.ExitCode -eq 0 -and $state.verdict -eq 'GREEN') ("загрузка после ответа: " + ($run.Output | Select-Object -Last 5))
            Check (@((Get-DPulls $sb) | Where-Object { $_ -match 'delivery/' }).Count -eq 1) 'должен быть один PR поставки'
            # Ответ GitHub дошёл, а локальная запись PR потеряна: продолжаем уже слитый PR.
            $saved = Join-Path $sb ('deliveries\' + $state.id + '\state.json')
            $state.status = 'received'
            $state.verdict = ''
            $state.pr = $null
            $state.ci = $null
            $state.merged = $null
            [IO.File]::WriteAllText($saved,($state | ConvertTo-Json -Depth 20),$utf8Bom)
            $dumps = New-DDumps -Ext (Get-DMainExt $gh)
            $resumed = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{dumps=$dumps} -Com $null
            $state = @(Get-DeliveryStates $sb)[0]
            Check ($resumed.ExitCode -eq 0 -and $state.verdict -eq 'GREEN') ('сбой восстановления: ' + ($resumed.Output | Select-Object -Last 5))
            Check (@((Get-DPulls $sb) | Where-Object { $_ -match 'delivery/' }).Count -eq 1) 'повторный PR после слияния'
        }
    }
    # ** Хлебников С.Ю. 20261123 конец
    @{
        Name = 'delivery-cfe-first'
        Text = 'Приёмка: первый CFE без истории. Правка temp (новый реквизит) - штатно PR и слиянием по CI; реквизит сохранён, замена процедуры - один вопрос с разницей, новая функция принята; кандидат - PR, CI, merge_checked по точному SHA, загрузка этого SHA, GREEN. Тот же файл под другим именем - повторная подача без PR; поставка из «Входящих» прямой загрузкой не берётся. Следующая поставка с другими процедурами - без вопросов: изменение подрядчика принято, отклонённое не вернулось, наш реквизит цел. Старый файл с другим номером версии - нового нет, без PR и загрузки.'
        Run = {
            param($Name)
            $com = New-ComState
            $sb = New-DeliverySandbox $Name -Com $com -Dumps (New-DDumps)
            $gh = Get-FakeGh $sb
            # Прямой загрузкой из «Входящих» - нельзя (старый сценарий не запускается).
            $inbox = Join-Path $sb 'Входящие'
            $cfe = New-DZip -Path (Join-Path $inbox 'erp_Доработки_v7.cfe') -Files (New-DExtFiles -Version '1.0.0.7' -Module (New-DModule -Digits '0' -Extra 'Сумма * 0.1'))
            $real = Join-Path $sb 'run-real.ps1'
            Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $here) 'run.ps1') -Destination $real
            $direct = Invoke-Script -Sandbox $sb -Script 'run-real.ps1' -Arguments ('-Kit "{0}"' -f $cfe)
            Check ($direct.ExitCode -ne 0 -and @($direct.Output | Where-Object { $_ -match 'приёмкой поставок' }).Count -gt 0) 'поставку из «Входящих» взяли прямой загрузкой'
            Check (@($direct.Calls | Where-Object { $_.Line.Contains('/LoadCfg') }).Count -eq 0) 'прямая загрузка дошла до конфигуратора'
            Reset-FakeState $sb
            # В temp новый реквизит Склад, которого нет ни в git, ни в поставке.
            $dumps = New-DDumps -Ext (New-DExtFiles -Attributes @('Организация', 'Склад'))
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = $dumps } -Com $null -Answers @(
                @{ Kind = 'one'; Header = 'процедура Пересчитать'; Item = '^Оставить наше' })
            Check-DeliveryCommon $r
            Check ($r.ExitCode -eq 0) ("код {0}: {1}" -f $r.ExitCode, (($r.Output | Select-Object -Last 3) -join ' | '))
            $states = @(Get-DeliveryStates $sb)
            Check ($states.Count -eq 1) ("поставок {0}, ждали 1" -f $states.Count)
            if ($states.Count -ne 1) { return }
            $state = $states[0]
            Check ([string]$state.status -eq 'done' -and [string]$state.verdict -eq 'GREEN') ("поставка: {0} {1} ({2})" -f $state.status, $state.verdict, $state.note)
            Check (-not (Test-Path -LiteralPath $cfe)) 'файл остался во «Входящих»'
            Check (Test-Path -LiteralPath (Join-Path $sb ('deliveries\{0}\original\erp_Доработки_v7.cfe' -f $state.id))) 'нет оригинала в реестре'
            Check ([string]$state.files[0].actualKind -eq 'extension' -and [string]$state.files[0].sha256 -match '^[0-9a-f]{64}$') 'тип или SHA-256 файла не записаны'
            $doc = Get-DMainText $gh 'extensions/Доработки/Documents/Заказ.xml'
            Check ($null -ne $doc -and $doc.Contains('<Name>Склад</Name>')) 'реквизит temp пропал'
            $module = Get-DMainText $gh 'extensions/Доработки/Documents/Заказ/Ext/ObjectModule.bsl'
            Check ($null -ne $module -and $module.Contains('Количество, 2)') -and -not $module.Contains('Количество, 0)')) 'отклонённая замена процедуры попала в main'
            Check ($null -ne $module -and $module.Contains('Функция Наценка(Сумма)')) 'новая функция поставки не попала в main'
            $config = Get-DMainText $gh 'extensions/Доработки/Configuration.xml'
            Check ($null -ne $config -and $config -match '<Version>\d{8}\.\d{6}</Version>') 'версия расширения не получила штамп'
            $ledger = Get-DMainText $gh ('deliveries/{0}.json' -f $state.id)
            Check ($null -ne $ledger) 'нет журнала поставки в git'
            if ($null -ne $ledger) {
                $journal = $ledger | ConvertFrom-Json
                Check (@($journal.rejected | Where-Object { [string]$_.unit -eq 'method:пересчитать' }).Count -eq 1) 'отклонённая правка не записана в журнал'
                Check ([string]$journal.files[0].sha256 -eq [string]$state.files[0].sha256) 'в журнале другой SHA-256'
            }
            $pulls = Get-DPulls $sb
            Check ($pulls.Count -eq 3) ("PR {0}, ждали 3: первая выгрузка, правки temp, поставка" -f $pulls.Count)
            Check (@($pulls | Where-Object { $_ -match "`ttemp/" }).Count -eq 2 -and @($pulls | Where-Object { $_ -match "`tdelivery/" }).Count -eq 1) ("ветки PR: " + ($pulls -join ' | '))
            $stubs = Get-DStubs $sb
            Check ($stubs.Count -eq 1) ("прогонов гейта {0}, ждали 1" -f $stubs.Count)
            if ($stubs.Count -eq 1) {
                $mainSha = (Get-GhHead -Gh $gh -Branch 'main').Sha
                Check ($stubs[0] -match ('KitSource=git owner/ext@' + $mainSha)) 'загружен не тот SHA, что в main после слияния'
                Check ($stubs[0] -match 'dir=Доработки' -and $stubs[0] -notmatch 'dir=Адаптация') ("комплект: " + $stubs[0])
            }
            Check ([string]$state.merged.sha -eq (Get-GhHead -Gh $gh -Branch 'main').Sha -and [string]$state.result.run) 'цепочка SHA -> прогон не записана'
            $report = Join-Path $sb ('deliveries\{0}\report.md' -f $state.id)
            Check ((Test-Path -LiteralPath $report) -and ([System.IO.File]::ReadAllText($report, $utf8)).Contains([string]$state.files[0].sha256)) 'в отчёте нет SHA-256 файла'
            $comments = Join-Path $sb ('fake-github\pulls\{0}.comments.md' -f $state.pr.number)
            Check ((Test-Path -LiteralPath $comments) -and ([System.IO.File]::ReadAllText($comments, $utf8)) -match 'GREEN') 'в PR поставки нет итога'
            # Тот же файл под другим именем - та же поставка: ни новой поставки, ни PR, ни прогона.
            Reset-FakeState $sb
            Copy-Item -LiteralPath (Join-Path $sb ('deliveries\{0}\original\erp_Доработки_v7.cfe' -f $state.id)) -Destination (Join-Path $inbox 'Доработки_новое_имя.cfe')
            (Get-Item -LiteralPath (Join-Path $inbox 'Доработки_новое_имя.cfe')).LastWriteTime = (Get-Date).AddMinutes(-5)
            $dumps2 = New-DDumps -Ext (Get-DMainExt $gh)
            $again = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = $dumps2 } -Com $null
            Check-DeliveryCommon $again
            Check (@(Get-DeliveryStates $sb).Count -eq 1) 'повторная подача создала новую поставку'
            Check ((Get-DPulls $sb).Count -eq 3) 'повторная подача создала PR'
            Check ((Get-DStubs $sb).Count -eq 1) 'повторная подача запустила гейт'
            Check (@($again.Output | Where-Object { $_ -match 'повторная подача' }).Count -gt 0) 'не сказано о повторной подаче'
            # Следующая поставка того же расширения - другие процедуры: Скидку подрядчик поменял (у нас она как в его
            # прошлой поставке) - берётся без вопроса; Пересчитать - та же, что отклонили, - молча остаётся наше;
            # реквизита Склад у подрядчика нет, но он его и не поставлял - не удаление.
            Reset-FakeState $sb
            $null = New-DZip -Path (Join-Path $inbox 'erp_Доработки_v8.cfe') -Files (New-DExtFiles -Version '1.0.0.8' -Module (New-DModule -Digits '0' -Discount 'Сумма * 0.05' -Extra 'Сумма * 0.1'))
            $next = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps -Ext (Get-DMainExt $gh)) } -Com $null
            Check-DeliveryCommon $next
            $second = @(Get-DeliveryStates $sb | Where-Object { $_.id -ne $state.id })
            Check ($second.Count -eq 1 -and [string]$second[0].verdict -eq 'GREEN') ("вторая поставка: " + (@($second | ForEach-Object { '{0} {1} {2}' -f $_.status, $_.verdict, $_.note }) -join '; '))
            $module = Get-DMainText $gh 'extensions/Доработки/Documents/Заказ/Ext/ObjectModule.bsl'
            Check ($null -ne $module -and $module.Contains('Возврат Сумма * 0.05;')) 'изменение подрядчика (Скидка) не принято'
            Check ($null -ne $module -and $module.Contains('Количество, 2)') -and -not $module.Contains('Количество, 0)')) 'отклонённая раньше замена вернулась'
            $doc = Get-DMainText $gh 'extensions/Доработки/Documents/Заказ.xml'
            Check ($null -ne $doc -and $doc.Contains('<Name>Склад</Name>')) 'наш реквизит удалён: подрядчик его не поставлял'
            Check ((Get-DPulls $sb).Count -eq 4) 'второй поставке нужен ровно один новый PR'
            # Старый файл под новым именем и со старым номером версии: всё в нём уже в истории - нового нет, PR и
            # загрузки нет. Номер версии доказательством не считается.
            Reset-FakeState $sb
            $null = New-DZip -Path (Join-Path $inbox 'Доработки_от_подрядчика_ещё_раз.cfe') -Files (New-DExtFiles -Version '1.0.0.6' -Module (New-DModule -Digits '0' -Extra 'Сумма * 0.1'))
            $stubsBefore = (Get-DStubs $sb).Count
            $old = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps -Ext (Get-DMainExt $gh)) } -Com $null
            Check-DeliveryCommon $old
            $third = @(Get-DeliveryStates $sb | Where-Object { $_.id -ne $state.id -and $_.id -ne $second[0].id })
            Check ($third.Count -eq 1 -and [string]$third[0].verdict -eq 'UNCHANGED' -and [string]$third[0].status -eq 'done') ("старый файл: " + (@($third | ForEach-Object { '{0} {1} {2}' -f $_.status, $_.verdict, $_.note }) -join '; '))
            Check ((Get-DPulls $sb).Count -eq 4) 'старый файл открыл PR'
            Check ((Get-DStubs $sb).Count -eq $stubsBefore) 'старый файл запустил гейт'
            $module = Get-DMainText $gh 'extensions/Доработки/Documents/Заказ/Ext/ObjectModule.bsl'
            Check ($null -ne $module -and $module.Contains('Возврат Сумма * 0.05;')) 'старый файл откатил принятое изменение'
        }
    },
    @{
        Name = 'delivery-set-crash'
        Text = 'Приёмка: CFE и зависящий от него ERF - один комплект, один PR, один прогон с обоими. Обрыв после первого объекта: итога нет - не GREEN; повтор видит, что расширение уже в temp, догружает только отчёт, второго PR нет, итог GREEN.'
        Run = {
            param($Name)
            $com = New-ComState
            $sb = New-DeliverySandbox $Name -Com $com -Dumps (New-DDumps)
            $gh = Get-FakeGh $sb
            $set = Join-Path $sb 'Входящие\комплект_склад'
            $null = New-DZip -Path (Join-Path $set 'Доработки.cfe') -Files (New-DExtFiles -Attributes @('Организация', 'Склад') -Version '1.0.0.8')
            $null = New-DZip -Path (Join-Path $set 'ОтчётПродаж.erf') -Files (New-DReportFiles)
            (Get-Item -LiteralPath $set).LastWriteTime = (Get-Date).AddMinutes(-5)
            [System.IO.File]::WriteAllText((Join-Path $sb 'stub-mode.txt'), 'CRASH')
            $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null
            Check-DeliveryCommon $first
            $states = @(Get-DeliveryStates $sb)
            Check ($states.Count -eq 1) ("поставок {0}, ждали 1" -f $states.Count)
            if ($states.Count -ne 1) { return }
            Check ([string]$states[0].verdict -ne 'GREEN') 'обрыв прогона дал GREEN'
            Check (@($states[0].files | Where-Object { [string]$_.actualKind -eq 'report' }).Count -eq 1 -and @($states[0].files | Where-Object { [string]$_.actualKind -eq 'extension' }).Count -eq 1) 'тип файлов комплекта не определён'
            $stubs = Get-DStubs $sb
            Check ($stubs.Count -eq 1 -and $stubs[0] -match 'dir=Доработки' -and $stubs[0] -match 'dir=ОтчётПродаж') ("первый прогон - не весь комплект: " + ($stubs -join ' / '))
            $pullCount = (Get-DPulls $sb).Count
            # Обрыв после первого объекта: расширение уже стоит в temp, отчёта ещё нет.
            Reset-FakeState $sb
            [System.IO.File]::WriteAllText((Join-Path $sb 'stub-mode.txt'), 'GREEN')
            $second = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps -Ext (Get-DMainExt $gh)) } -Com $null
            Check-DeliveryCommon $second
            $state = @(Get-DeliveryStates $sb)[0]
            Check ([string]$state.status -eq 'done' -and [string]$state.verdict -eq 'GREEN') ("после повтора: {0} {1} ({2})" -f $state.status, $state.verdict, $state.note)
            Check ((Get-DPulls $sb).Count -eq $pullCount) 'повтор после обрыва создал PR'
            $stubs = Get-DStubs $sb
            Check ($stubs.Count -eq 2 -and $stubs[1] -notmatch 'dir=Доработки' -and $stubs[1] -match 'dir=ОтчётПродаж') ("повтор загрузил не только недостающее: " + ($stubs -join ' / '))
            Check (@($second.Output | Where-Object { $_ -match 'повтор после обрыва' }).Count -gt 0) 'нет сверки фактического состояния перед повтором'
            Check (@($second.Output | Where-Object { $_ -match 'это не правки, догружаю' }).Count -gt 0) 'загруженное до обрыва приняли за правки temp'
        }
    },
    @{
        Name = 'delivery-epf-two-cards'
        Text = 'Приёмка: EPF для двух одноимённых карточек, одна отключена: вопрос с назначением и состоянием обеих, выбрана отключённая - объединение с её папкой, загрузка в неё (ref из manifest), привязка запомнена; следующая поставка того же объекта - без вопроса.'
        Run = {
            param($Name)
            $refMain = '11111111-1111-1111-1111-111111111111'
            $refOff = '22222222-2222-2222-2222-222222222222'
            $cards = @(
                @{ objName = 'Печать'; title = 'Печать актов'; version = '1'; kind = 'Печатная форма'; content = $printOld; ref = $refMain; use = 'Используется'; targets = @('Документ.Заказ') },
                @{ objName = 'Печать'; title = 'Печать актов (старая)'; version = '0'; kind = 'Печатная форма'; content = $printOld; ref = $refOff; use = 'Отключена'; targets = @('Документ.Счёт') })
            $com = New-ComState -TempProcessings $cards
            $sb = New-DeliverySandbox $Name -Com $com -Dumps (New-DDumps)
            $gh = Get-FakeGh $sb
            $files = Get-GhFiles -Gh $gh -Commit (Get-GhHead -Gh $gh -Branch 'main').Sha
            $offFolder = 'Печать~' + $refOff.Substring(0, 8)
            Check ($files.ContainsKey(('processings/{0}/Печать.xml' -f $offFolder))) ("в git нет папки отключённой карточки {0}" -f $offFolder)
            $root = $utf8.GetString((Get-GhBlob -Gh $gh -Sha $files[('processings/{0}/Печать.xml' -f $offFolder)])).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
            $null = New-DZip -Path (Join-Path $sb 'Входящие\Печать.epf') -Files @{ 'Печать.xml' = $root; 'Печать/Ext/ObjectModule.bsl' = $printNew }
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null -Answers @(
                @{ Kind = 'one'; Header = 'в какую карточку'; Item = 'Отключена' })
            Check-DeliveryCommon $r
            $question = @($r.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('в какую карточку') })
            Check ($question.Count -eq 1 -and $question[0].Contains('Документ.Счёт') -and $question[0].Contains('Документ.Заказ') -and $question[0].Contains('Отключена')) 'в вопросе нет назначений и состояния обеих карточек'
            $state = @(Get-DeliveryStates $sb)[0]
            Check ([string]$state.verdict -eq 'GREEN') ("итог {0}: {1}" -f $state.verdict, $state.note)
            Check ([string]$state.files[0].object.ref -eq $refOff -and [string]$state.files[0].object.repoPath -eq ('processings/' + $offFolder)) 'выбрана не та карточка'
            $module = Get-DMainText $gh ('processings/{0}/Печать/Ext/ObjectModule.bsl' -f $offFolder)
            Check ($null -ne $module -and $module.Contains('НоваяПроцедура')) 'правка не в папке выбранной карточки'
            $mainModule = Get-DMainText $gh 'processings/Печать/Печать/Ext/ObjectModule.bsl'
            Check ($null -ne $mainModule -and -not $mainModule.Contains('НоваяПроцедура')) 'задета папка другой карточки'
            $bindings = Get-DMainText $gh 'deliveries/bindings.json'
            Check ($null -ne $bindings -and $bindings.Contains($refOff)) 'привязка не запомнена'
            $stubs = Get-DStubs $sb
            Check ($stubs.Count -eq 1 -and $stubs[0].Contains('dir=' + $offFolder) -and $stubs[0] -notmatch 'dir=Печать\r?\n') ("комплект: " + ($stubs -join ' / '))
            $result = @($state.result.objects)
            Check ($result.Count -eq 1 -and [bool]$result[0].loaded -and ([string]$result[0].detail).Contains($refOff)) 'загружено не в выбранную карточку'
            # Следующая поставка того же объекта: та же карточка без вопроса. Заглушка гейта карточку не пишет - в
            # подставном COM она теперь такая, как в main (как после настоящей загрузки).
            $comFile = Join-Path $sb 'fake\com.json'
            $comState = [System.IO.File]::ReadAllText($comFile, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
            foreach ($card in @($comState.bases.erp_temp_test.processings)) { if ([string]$card.ref -eq $refOff) { $card.content = $module } }
            [System.IO.File]::WriteAllText($comFile, (ConvertTo-Json -InputObject $comState -Depth 10), $utf8)
            Reset-FakeState $sb
            $null = New-DZip -Path (Join-Path $sb 'Входящие\Печать_2.epf') -Files @{ 'Печать.xml' = $root; 'Печать/Ext/ObjectModule.bsl' = ($printNew + "`n`nПроцедура ЕщёОдна()`nКонецПроцедуры") }
            $next = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null
            Check-DeliveryCommon $next
            $second = @(Get-DeliveryStates $sb | Where-Object { $_.id -ne $state.id })
            Check ($second.Count -eq 1 -and [string]$second[0].files[0].object.ref -eq $refOff) 'вторая поставка - не в запомненную карточку'
        }
    },
    @{
        Name = 'delivery-protected-epf'
        Text = 'Приёмка: защищённая обработка (исходники не выгружаются) - решение о файле целиком с SHA-256; принятый файл - в binaries/ закрытого git с записью в manifest, загрузка ставит именно его (sha256 в комплекте), отчёт называет границу проверки.'
        Run = {
            param($Name)
            $com = New-ComState
            $sb = New-DeliverySandbox $Name -Com $com -Dumps (New-DDumps)
            $gh = Get-FakeGh $sb
            $file = New-DZip -Path (Join-Path $sb 'Входящие\Закрытая.epf') -Files @{ 'Закрытая.xml' = 'x' } -Protected
            $sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null -Answers @(
                @{ Kind = 'one'; Header = 'файл целиком'; Item = '^Взять поставку' })
            Check-DeliveryCommon $r
            $state = @(Get-DeliveryStates $sb)[0]
            Check ([bool]$state.files[0].opaque -and ([string]$state.files[0].opaqueReason) -match 'исходного текста') 'граница проверки (защищённый модуль) не записана'
            Check ([string]$state.verdict -eq 'GREEN') ("итог {0}: {1}" -f $state.verdict, $state.note)
            $manifest = Get-DMainText $gh 'binaries/manifest.json'
            Check ($null -ne $manifest -and $manifest.Contains($sha)) 'в binaries/manifest.json нет SHA-256 принятого файла'
            $files = Get-GhFiles -Gh $gh -Commit (Get-GhHead -Gh $gh -Branch 'main').Sha
            Check ($files.ContainsKey('binaries/Закрытая/Закрытая.epf')) 'файла целиком нет в git'
            $stubs = Get-DStubs $sb
            Check ($stubs.Count -eq 1 -and $stubs[0].Contains('binary=Закрытая.epf') -and $stubs[0].Contains('sha256=' + $sha)) ("загрузка не по записи в git: " + ($stubs -join ' / '))
            $report = [System.IO.File]::ReadAllText((Join-Path $sb ('deliveries\{0}\report.md' -f $state.id)), $utf8)
            Check ($report.Contains($sha) -and $report.Contains('не разбирается')) 'в отчёте нет хеша и границы проверки'
            # Та же обработка следующей поставкой уже с исходниками: запись binaries/ убирается, грузятся исходники.
            Reset-FakeState $sb
            $null = New-DZip -Path (Join-Path $sb 'Входящие\Закрытая_открытая.epf') -Files (New-DProcFiles -Name 'Закрытая')
            $open = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null
            Check-DeliveryCommon $open
            $second = @(Get-DeliveryStates $sb | Where-Object { $_.id -ne $state.id })
            Check ($second.Count -eq 1 -and [string]$second[0].verdict -eq 'GREEN') ("поставка исходниками: " + (@($second | ForEach-Object { '{0} {1} {2}' -f $_.status, $_.verdict, $_.note }) -join '; '))
            $files = Get-GhFiles -Gh $gh -Commit (Get-GhHead -Gh $gh -Branch 'main').Sha
            Check (-not $files.ContainsKey('binaries/Закрытая/Закрытая.epf') -and $files.ContainsKey('processings/Закрытая/Закрытая.xml')) 'файл целиком не заменён исходниками'
            $manifest = Get-DMainText $gh 'binaries/manifest.json'
            Check ($null -eq $manifest -or -not $manifest.Contains('Закрытая')) 'в binaries/manifest.json осталась прежняя запись'
            $stubs = Get-DStubs $sb
            Check ($stubs.Count -eq 2 -and $stubs[1].Contains('dir=Закрытая') -and -not $stubs[1].Contains('binary=Закрытая.epf')) ("вторая загрузка - не исходники: " + ($stubs -join ' / '))
        }
    },
    @{
        Name = 'delivery-epf-renamed'
        Text = 'Приёмка: обработка пришла под новым именем объекта, но с тем же UUID, что у папки в git, - вопрос «переименованная?» с карточкой; «обновить» - объединение с прежней папкой, загрузка в прежнюю карточку по ссылке, новой карточки нет; имя объекта в git - новое.'
        Run = {
            param($Name)
            $refPrint = '55555555-5555-5555-5555-555555555555'
            $uuid = 'ffffffff-0000-0000-0000-0000000000a1'
            $cards = @(@{ objName = 'Печать'; title = 'Печать актов'; version = '1'; kind = 'Печатная форма'; content = $printOld; ref = $refPrint; use = 'Используется'; targets = @('Документ.Заказ') })
            $com = New-ComState -TempProcessings $cards
            $sb = New-DeliverySandbox $Name -Com $com -Dumps (New-DDumps)
            $gh = Get-FakeGh $sb
            # В git - выгрузка конфигуратором (с UUID корня), как после настоящей «Выгрузить temp в git».
            $head = (Get-GhHead -Gh $gh -Branch 'main').Sha
            $git = New-DProcFiles -Name 'Печать' -Body $printOld -Uuid $uuid
            $withUuid = New-GhCommit -Gh $gh -Parent $head -Changes @(
                [pscustomobject]@{ Path = 'processings/Печать/Печать.xml'; Bytes = $utf8.GetBytes($git['Печать.xml']) },
                [pscustomobject]@{ Path = 'processings/Печать/Печать/Ext/ObjectModule.bsl'; Bytes = $utf8.GetBytes($git['Печать/Ext/ObjectModule.bsl']) }) -Message 'выгрузка с UUID'
            Set-GhBranch -Gh $gh -Branch 'main' -Sha $withUuid
            $null = New-DZip -Path (Join-Path $sb 'Входящие\ПечатьАктов.epf') -Files (New-DProcFiles -Name 'ПечатьАктов' -Body $printNew -Uuid $uuid)
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null -Answers @(
                @{ Kind = 'one'; Header = 'переименованная Печать'; Item = '^Обновить Печать' },
                @{ Kind = 'one'; Header = 'свойство Name'; Item = '^Взять поставку' })
            Check-DeliveryCommon $r
            $question = @($r.Output | Where-Object { $_.StartsWith('@@ui:') -and $_.Contains('переименованная') })
            Check ($question.Count -eq 1 -and $question[0].Contains('Печать актов') -and $question[0].Contains($uuid)) 'в вопросе о переименовании нет карточки и UUID'
            $state = @(Get-DeliveryStates $sb)[0]
            Check ([string]$state.verdict -eq 'GREEN') ("итог {0}: {1}" -f $state.verdict, $state.note)
            Check ([string]$state.files[0].object.ref -eq $refPrint -and [string]$state.files[0].object.repoPath -eq 'processings/Печать') ("сопоставлено не с прежней карточкой: {0} {1}" -f $state.files[0].object.repoPath, $state.files[0].object.ref)
            $root = Get-DMainText $gh 'processings/Печать/Печать.xml'
            Check ($null -ne $root -and $root.Contains('<Name>ПечатьАктов</Name>')) 'новое имя объекта не попало в git'
            $module = Get-DMainText $gh 'processings/Печать/Печать/Ext/ObjectModule.bsl'
            Check ($null -ne $module -and $module.Contains('НоваяПроцедура')) 'правка поставки не в прежней папке'
            $files = Get-GhFiles -Gh $gh -Commit (Get-GhHead -Gh $gh -Branch 'main').Sha
            Check (@($files.Keys | Where-Object { $_ -like 'processings/ПечатьАктов*' }).Count -eq 0) 'появилась папка новой карточки'
            $stubs = Get-DStubs $sb
            Check ($stubs.Count -eq 1 -and $stubs[0] -match 'dir=Печать\r?\n') ("комплект: " + ($stubs -join ' / '))
            $result = @($state.result.objects)
            Check ($result.Count -eq 1 -and ([string]$result[0].detail).Contains($refPrint)) 'загружено не в прежнюю карточку'
        }
    },
    @{
        Name = 'delivery-human-merge'
        Text = 'Приёмка без автослияния (DeliveryAutoMerge = $false): зелёный PR ждёт человека, в temp ничего; человек слил - следующий проход не пересобирает кандидат, а грузит main и проверяет: GREEN, слияние записано как ручное.'
        Run = {
            param($Name)
            $com = New-ComState
            $sb = New-DeliverySandbox $Name -Com $com -Dumps (New-DDumps) -Extra @{ DeliveryAutoMerge = $false }
            # Этот сценарий только печатает команду. Выполнение настоящего python.exe проверяет тест установленного ZIP.
            $runtime = Join-Path $sb 'runtime'
            $pyDir = Join-Path $runtime 'python-3.14.10'
            $null = New-Item -ItemType Directory -Path $pyDir -Force
            [IO.File]::WriteAllText((Join-Path $runtime 'python-version.txt'), '3.14.10')
            $expectedExe = Join-Path $pyDir 'python.exe'
            $fixtureId = [guid]::NewGuid().ToString()
            [IO.File]::WriteAllText($expectedExe, $fixtureId)
            $gh = Get-FakeGh $sb
            $null = New-DZip -Path (Join-Path $sb 'Входящие\Доработки.cfe') -Files (New-DExtFiles -Module (New-DModule -Extra 'Сумма * 0.3'))
            $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null
            Check-DeliveryCommon $first
            $state = @(Get-DeliveryStates $sb)[0]
            Check ([string]$state.status -eq 'waiting-merge') ("без автослияния статус {0} ({1})" -f $state.status, $state.note)
            Check ((Get-DStubs $sb).Count -eq 0) 'до слияния гейт запускался'
            $pull = Get-GhPull -Gh $gh -Number ([int]$state.pr.number)
            # %TEMP% может использовать короткое имя 8.3. Проверяем файл, который откроет команда из журнала.
            $entry = @($state.events | Where-Object { $_.event -eq 'wait-merge' })[-1].text
            $pattern = "& '(?<exe>(?:[^']|'')+)' -I -X utf8 'ci/merge_checked\.py' " + $state.pr.number + " --merge '" + [regex]::Escape($pull.Merge) + "'$"
            $found = [regex]::Match($entry, $pattern)
            Check $found.Success 'в журнале нет команды с точным номером PR и проверенным SHA'
            if ($found.Success) {
                $actualExe = $found.Groups['exe'].Value.Replace("''", "'")
                Check ((Test-Path -LiteralPath $actualExe -PathType Leaf) -and [IO.File]::ReadAllText($actualExe) -ceq $fixtureId) 'команда ссылается на другой интерпретатор'
                Check (@($first.Output | Where-Object { $_.Contains($found.Value) }).Count -gt 0) 'команда из журнала не показана оператору'
            }
            # Человек слил PR (здесь - main на коммит кандидата).
            Set-GhBranch -Gh $gh -Branch 'main' -Sha ([string]$state.pr.head)
            $pulls = (Get-DPulls $sb).Count
            Reset-FakeState $sb
            $second = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null
            Check-DeliveryCommon $second
            $state = @(Get-DeliveryStates $sb)[0]
            Check ([string]$state.status -eq 'done' -and [string]$state.verdict -eq 'GREEN') ("после ручного слияния: {0} {1} ({2})" -f $state.status, $state.verdict, $state.note)
            Check ([string]$state.merged.how -eq 'человек') 'слияние не записано как ручное'
            Check ((Get-DPulls $sb).Count -eq $pulls) 'после ручного слияния открыт новый PR'
            $stubs = Get-DStubs $sb
            Check ($stubs.Count -eq 1 -and $stubs[0] -match ('KitSource=git owner/ext@' + (Get-GhHead -Gh $gh -Branch 'main').Sha) -and $stubs[0] -match 'dir=Доработки') ("загрузка после ручного слияния: " + ($stubs -join ' / '))
            Check (@($second.Output | Where-Object { $_ -match 'уже в main: кандидат не пересобираю' }).Count -gt 0) 'кандидат пересобирали после слияния'
        }
    },
    @{
        Name = 'delivery-mixed-report'
        Text = 'Приёмка: смешанная поставка одной папкой - CFE (спорная процедура и новая функция), EPF для двух одноимённых карточек, новый ERF и защищённая EPF: три вопроса, один PR, один прогон со всеми объектами, GREEN; отчёт показывает каждый файл, решения, сборку, регистрацию в справочнике и цепочку до вердикта.'
        Run = {
            param($Name)
            $refMain = '33333333-3333-3333-3333-333333333333'
            $refOff = '44444444-4444-4444-4444-444444444444'
            $cards = @(
                @{ objName = 'Печать'; title = 'Печать актов'; version = '1'; kind = 'Печатная форма'; content = $printOld; ref = $refMain; use = 'Используется'; targets = @('Документ.Заказ') },
                @{ objName = 'Печать'; title = 'Печать актов (старая)'; version = '0'; kind = 'Печатная форма'; content = $printOld; ref = $refOff; use = 'Отключена'; targets = @('Документ.Счёт') })
            $com = New-ComState -TempProcessings $cards
            $sb = New-DeliverySandbox $Name -Com $com -Dumps (New-DDumps)
            $gh = Get-FakeGh $sb
            $files = Get-GhFiles -Gh $gh -Commit (Get-GhHead -Gh $gh -Branch 'main').Sha
            $root = $utf8.GetString((Get-GhBlob -Gh $gh -Sha $files['processings/Печать/Печать.xml'])).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
            $pullsBefore = (Get-DPulls $sb).Count
            $set = Join-Path $sb 'Входящие\поставка_склад_и_печать'
            $null = New-DZip -Path (Join-Path $set 'Доработки_v9.cfe') -Files (New-DExtFiles -Version '1.0.0.9' -Module (New-DModule -Digits '0' -Extra 'Сумма * 0.1'))
            $null = New-DZip -Path (Join-Path $set 'Печать.epf') -Files @{ 'Печать.xml' = $root; 'Печать/Ext/ObjectModule.bsl' = $printNew }
            $null = New-DZip -Path (Join-Path $set 'ОтчётПродаж.erf') -Files (New-DReportFiles)
            $closed = New-DZip -Path (Join-Path $set 'Закрытая.epf') -Files @{ 'Закрытая.xml' = 'x' } -Protected
            $closedSha = (Get-FileHash -LiteralPath $closed -Algorithm SHA256).Hash.ToLowerInvariant()
            (Get-Item -LiteralPath $set).LastWriteTime = (Get-Date).AddMinutes(-5)
            $r = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null -Answers @(
                @{ Kind = 'one'; Header = 'в какую карточку'; Item = 'Используется' },
                @{ Kind = 'one'; Header = 'процедура Пересчитать'; Item = '^Оставить наше' },
                @{ Kind = 'one'; Header = 'файл целиком'; Item = '^Взять поставку' })
            Check-DeliveryCommon $r
            $states = @(Get-DeliveryStates $sb)
            Check ($states.Count -eq 1) ("поставок {0}, ждали 1 (папка - один комплект)" -f $states.Count)
            if ($states.Count -ne 1) { return }
            $state = $states[0]
            Check ([string]$state.status -eq 'done' -and [string]$state.verdict -eq 'GREEN') ("поставка: {0} {1} ({2})" -f $state.status, $state.verdict, $state.note)
            $kinds = @($state.files | ForEach-Object { [string]$_.actualKind } | Sort-Object) -join ','
            Check ($kinds -eq 'extension,processing,processing,report') ("типы файлов: " + $kinds)
            Check ((Get-DPulls $sb).Count -eq $pullsBefore + 1) 'поставке нужен ровно один PR'
            $stubs = Get-DStubs $sb
            Check ($stubs.Count -eq 1 -and $stubs[0] -match 'dir=Доработки' -and $stubs[0] -match 'dir=Печать\r?\n' -and $stubs[0] -match 'dir=ОтчётПродаж' -and $stubs[0].Contains('binary=Закрытая.epf')) ("прогон - не весь комплект: " + ($stubs -join ' / '))
            $module = Get-DMainText $gh 'extensions/Доработки/Documents/Заказ/Ext/ObjectModule.bsl'
            Check ($null -ne $module -and $module.Contains('Окр(Цена * Количество, 2)') -and $module.Contains('Функция Наценка')) 'в main не наше решение по процедуре или нет новой функции'
            $print = Get-DMainText $gh 'processings/Печать/Печать/Ext/ObjectModule.bsl'
            Check ($null -ne $print -and $print.Contains('НоваяПроцедура')) 'обработка не в выбранной карточке'
            $report = [System.IO.File]::ReadAllText((Join-Path $sb ('deliveries\{0}\report.md' -f $state.id)), $utf8)
            foreach ($word in @('Доработки_v9.cfe', 'Печать.epf', 'ОтчётПродаж.erf', 'Закрытая.epf', $closedSha, 'Решено человеком', 'Регистрация в справочнике', 'Сборка в технической базе', 'Граница проверки', 'Цепочка', $refMain)) {
                Check ($report.Contains($word)) ("в отчёте нет «{0}»" -f $word)
            }
            Check (-not $report.Contains('Ждёт решения')) 'в отчёте GREEN-поставки есть неразобранные решения'
            [System.IO.File]::WriteAllText((Join-Path $sb 'mixed-report.md'), $report, $utf8)
        }
    },
    @{
        Name = 'delivery-drift-during-ci'
        Text = 'Приёмка: пока шёл CI, в temp сохранили новую правку. Перед записью temp проверен под блокировкой: правка ушла штатно в PR и слита, кандидат пересобран поверх нового main (то же решение, тот же PR, новый CI), в итоге в main и правка temp, и поставка.'
        Run = {
            param($Name)
            $com = New-ComState
            $sb = New-DeliverySandbox $Name -Com $com -Dumps (New-DDumps)
            $gh = Get-FakeGh $sb
            $null = New-DZip -Path (Join-Path $sb 'Входящие\Доработки.cfe') -Files (New-DExtFiles -Module (New-DModule -Extra 'Сумма * 0.2'))
            [System.IO.File]::WriteAllText((Join-Path $sb 'fake-github\ci-default.txt'), "in_progress`t", $utf8)
            $first = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null
            Check-DeliveryCommon $first
            $state = @(Get-DeliveryStates $sb)[0]
            Check ([string]$state.status -eq 'ci') ("пока CI идёт - статус {0}" -f $state.status)
            Check ((Get-DStubs $sb).Count -eq 0) 'загрузка до конца CI'
            $deliveryPull = [int]$state.pr.number
            # Разработчик сохранил правку в temp (скидка) - пока шёл CI.
            Reset-FakeState $sb
            [System.IO.File]::WriteAllText((Join-Path $sb 'fake-github\ci-default.txt'), "completed`tsuccess", $utf8)
            $dumps = New-DDumps -Ext (New-DExtFiles -Module (New-DModule -Discount 'Сумма * 0.03'))
            $second = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = $dumps } -Com $null
            Check-DeliveryCommon $second
            $state = @(Get-DeliveryStates $sb)[0]
            Check ([string]$state.verdict -eq 'GREEN') ("итог {0}: {1}" -f $state.verdict, $state.note)
            Check ([int]$state.pr.number -eq $deliveryPull) 'пересборка открыла новый PR поставки'
            $module = Get-DMainText $gh 'extensions/Доработки/Documents/Заказ/Ext/ObjectModule.bsl'
            Check ($null -ne $module -and $module.Contains('Возврат Сумма * 0.03;') -and $module.Contains('Возврат Сумма * 0.2;')) ("в main нет правки temp или поставки: " + $module)
            Check (@($second.Output | Where-Object { $_ -match 'правки после синхронизации с git' }).Count -gt 0) 'правка temp не замечена'
            $comments = Join-Path $sb ('fake-github\pulls\{0}.comments.md' -f $deliveryPull)
            Check ((Test-Path -LiteralPath $comments) -and ([System.IO.File]::ReadAllText($comments, $utf8)) -match 'пересобран') 'в PR не сказано о пересборке'
        }
    },
    @{
        Name = 'delivery-red'
        Text = 'Приёмка: CI красный - в temp ничего не грузится; гейт на temp красный - RED записан для загруженного SHA вместе с прогоном.'
        Run = {
            param($Name)
            $com = New-ComState
            $sb = New-DeliverySandbox $Name -Com $com -Dumps (New-DDumps)
            $gh = Get-FakeGh $sb
            $null = New-DZip -Path (Join-Path $sb 'Входящие\Доработки.cfe') -Files (New-DExtFiles -Module (New-DModule -Extra 'Сумма * 0.5'))
            [System.IO.File]::WriteAllText((Join-Path $sb 'fake-github\ci-default.txt'), "completed`tfailure", $utf8)
            $red = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null
            Check-DeliveryCommon $red
            $state = @(Get-DeliveryStates $sb)[0]
            Check ([string]$state.status -eq 'ci-red') ("при красном CI статус {0}" -f $state.status)
            Check ((Get-DStubs $sb).Count -eq 0) 'при красном CI гейт запускался'
            $mainBefore = (Get-GhHead -Gh $gh -Branch 'main').Sha
            Check ([string]$state.pr.base -eq $mainBefore) 'при красном CI main сдвинулся'
            Reset-FakeState $sb
            [System.IO.File]::WriteAllText((Join-Path $sb 'fake-github\ci-default.txt'), "completed`tsuccess", $utf8)
            [System.IO.File]::WriteAllText((Join-Path $sb 'stub-mode.txt'), 'RED')
            $gate = Invoke-Script -Sandbox $sb -Script 'deploy.ps1' -Arguments '-Delivery' -Fake @{ dumps = (New-DDumps) } -Com $null
            Check-DeliveryCommon $gate
            $state = @(Get-DeliveryStates $sb)[0]
            $main = (Get-GhHead -Gh $gh -Branch 'main').Sha
            Check ([string]$state.verdict -eq 'RED' -and [string]$state.result.commit -eq $main -and [string]$state.result.run) ("RED не записан для загруженного SHA: {0} {1} {2}" -f $state.verdict, $state.result.commit, $state.result.run)
        }
    }
)
