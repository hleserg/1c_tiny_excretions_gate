#requires -Version 5.1
<#
Подставной V83.COMConnector для тестов без 1С. Версия 00000000.000000.

deploy.ps1 берёт его вместо настоящего, когда задана переменная CI_FAKE_COM - путь к файлу состояния (JSON).
Только с подставной 1С: с настоящим 1cv8.exe deploy.ps1 откажется работать.

Состояние читается из файла при каждом вызове и пишется обратно при каждом изменении, поэтому один и тот же
файл видят и основной поток скрипта, и фоновый (чтение расширений), а тест после прогона проверяет, что
осталось в «кластере». Изменения ещё дописываются строками в com.log рядом с файлом состояния.

Файл состояния:
  {
    "bases": {
      "<имя базы>": {
        "scheduledJobsDenied": false, "sessionsDenied": false, "permissionCode": "", "deniedMessage": "",
        "extensions": [ { "name": "...", "version": "...", "hash": "..." } ],
        "processings": [ { "objName": "...", "title": "...", "version": "...", "kind": "...", "content": "...",
                           "deleted": false, "use": "Используется", "safeMode": true, "ref": "<УИД>", "targets": [ "Документ.X" ] } ]
      }
    },
    "sessions": [ { "id": 1, "base": "<имя базы>", "app": "1CV8C", "user": "...", "host": "..." } ],
    "failConnect": [ "<имя базы>" ]      - внешнее соединение к этой базе падает
    "lockedConnect": [ "<имя базы>" ]    - в базе чужая блокировка начала сеансов (техработы)
    "failSessions": [ "<имя базы>" ]     - список сеансов этой базы агент не отдаёт (ошибка)
  }

Что умеет - то, чем пользуется deploy.ps1:
  агент: ConnectAgent, GetClusters, Authenticate, GetInfoBases, GetInfoBaseSessions, TerminateSession, GetWorkingProcesses;
  рабочий процесс: ConnectWorkingProcess, AuthenticateAdmin, AddAuthentication, GetInfoBases, UpdateInfoBase;
  внешнее соединение: Connect, ConfigurationExtensions.Get, ConfigurationExtensionsSource, Base64String,
  расширение.GetData().Write, Metadata (Name, Synonym, Version - из «config» базы), NewObject('Query') - запрос к справочнику обработок (Execute, Select, Next,
  Storage.Get().Write; с «НЕ Спр.ПометкаУдаления» в тексте - без помеченных; ссылка.UUID(), String) и к его табличной
  части Назначение (в тексте «.Назначение»). Нет ref у обработки - УИД из её номера; нет content - файла нет.
#>

if (-not ('FakeComList' -as [type])) {
    Add-Type -TypeDefinition @'
public class FakeComList {
    private readonly object[] items;
    public FakeComList(object[] items) { this.items = items; }
    public int Count() { return items.Length; }
    public object Get(int index) { return items[index]; }
}
'@
}

function Read-FakeComState {
    param([string]$File)
    return ([System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json)
}

function Save-FakeComState {
    param([string]$File, $State)
    [System.IO.File]::WriteAllText($File, (ConvertTo-Json -InputObject $State -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
}

function Write-FakeComLog {
    param([string]$File, [string]$Text)
    $log = Join-Path (Split-Path -Parent $File) 'com.log'
    [System.IO.File]::AppendAllText($log, ("{0}`t{1}`r`n" -f (Get-Date -Format 'HH:mm:ss.fff'), $Text), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-FakeComBase {
    # Свойства базы из состояния; нет такой базы - $null.
    param($State, [string]$Name)
    foreach ($property in $State.bases.PSObject.Properties) {
        if ($property.Name -ieq $Name) { return $property.Value }
    }
    return $null
}

function Get-FakeComList {
    # Поле-массив состояния: нет поля - пустой массив. Вызывать без @(): запятая уже вернула массив целиком,
    # а @() вокруг вызова функции обернул бы его ещё раз.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return , @() }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return , @() }
    return , @($property.Value)
}

function New-FakeComData {
    # Двоичные данные 1С: Write(путь) пишет их в файл.
    param([byte[]]$Bytes)
    $data = [pscustomobject]@{ Bytes = $Bytes }
    $data | Add-Member -MemberType ScriptMethod -Name Write -Value { param($Path) [System.IO.File]::WriteAllBytes([string]$Path, $this.Bytes) }
    return $data
}

function New-FakeComConnector {
    param([string]$File)
    $connector = [pscustomobject]@{ StateFile = $File }
    $connector | Add-Member -MemberType ScriptMethod -Name ConnectAgent -Value { param($Address) return (New-FakeComAgent $this.StateFile) }
    $connector | Add-Member -MemberType ScriptMethod -Name ConnectWorkingProcess -Value { param($Address) return (New-FakeComProcess $this.StateFile) }
    $connector | Add-Member -MemberType ScriptMethod -Name Connect -Value {
        param($Line)
        $base = [regex]::Match([string]$Line, 'Ref="([^"]+)"').Groups[1].Value
        $state = Read-FakeComState $this.StateFile
        if ((Get-FakeComList $state 'lockedConnect') -contains $base) { throw "Начало сеанса с информационной базой запрещено. До 03:00 проводятся технологические работы" }
        if ((Get-FakeComList $state 'failConnect') -contains $base) { throw ("Ошибка при выполнении операции с информационной базой (подставной COM: соединение с {0} не разрешено сценарием)" -f $base) }
        if ($null -eq (Get-FakeComBase $state $base)) { throw ("Информационная база не обнаружена: {0}" -f $base) }
        return (New-FakeComConnection $this.StateFile $base)
    }
    return $connector
}

function New-FakeComAgent {
    param([string]$File)
    $agent = [pscustomobject]@{ StateFile = $File }
    $agent | Add-Member -MemberType ScriptMethod -Name GetClusters -Value {
        $state = Read-FakeComState $this.StateFile
        $clusterHost = 'fake'
        if ($state.PSObject.Properties['clusterHost']) { $clusterHost = $state.clusterHost }
        return , @([pscustomobject]@{ HostName = $clusterHost; MainPort = 1541 })
    }
    $agent | Add-Member -MemberType ScriptMethod -Name GetInfoBases -Value {
        param($Cluster)
        $state = Read-FakeComState $this.StateFile
        foreach ($base in $state.bases.PSObject.Properties) { [pscustomobject]@{ Name = $base.Name } }
    }
    $agent | Add-Member -MemberType ScriptMethod -Name Authenticate -Value { param($Cluster, $User, $Password) }
    $agent | Add-Member -MemberType ScriptMethod -Name GetWorkingProcesses -Value { param($Cluster) return , @([pscustomobject]@{ Running = 1; HostName = 'fake'; MainPort = 1560 }) }
    $agent | Add-Member -MemberType ScriptMethod -Name GetInfoBaseSessions -Value {
        param($Cluster, $ShortBase)
        $state = Read-FakeComState $this.StateFile
        if ((Get-FakeComList $state 'failSessions') -contains [string]$ShortBase.Name) { throw ("подставной COM: сеансы {0} не отдаются по сценарию" -f $ShortBase.Name) }
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($session in (Get-FakeComList $state 'sessions')) {
            if ($session.base -ine $ShortBase.Name) { continue }
            $list.Add([pscustomobject]@{
                    SessionID = [int]$session.id; AppID = [string]$session.app; StartedAt = '17.11.2026 10:00:00'
                    userName = [string]$session.user; Host = [string]$session.host; infoBase = [pscustomobject]@{ Name = [string]$session.base }
                })
        }
        return , $list.ToArray()
    }
    $agent | Add-Member -MemberType ScriptMethod -Name TerminateSession -Value {
        param($Cluster, $Session)
        $state = Read-FakeComState $this.StateFile
        $left = @((Get-FakeComList $state 'sessions') | Where-Object { [int]$_.id -ne [int]$Session.SessionID })
        $state | Add-Member -NotePropertyName sessions -NotePropertyValue $left -Force
        Save-FakeComState $this.StateFile $state
        Write-FakeComLog $this.StateFile ("TerminateSession {0}" -f $Session.SessionID)
    }
    return $agent
}

function New-FakeComProcess {
    param([string]$File)
    $process = [pscustomobject]@{ StateFile = $File }
    $process | Add-Member -MemberType ScriptMethod -Name AuthenticateAdmin -Value { param($User, $Password) }
    $process | Add-Member -MemberType ScriptMethod -Name AddAuthentication -Value { param($User, $Password) }
    $process | Add-Member -MemberType ScriptMethod -Name GetInfoBases -Value {
        $state = Read-FakeComState $this.StateFile
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($property in $state.bases.PSObject.Properties) {
            $base = $property.Value
            $from = $null
            $to = $null
            if ($base.PSObject.Properties['deniedFrom'] -and [string]$base.deniedFrom) { $from = [datetime]$base.deniedFrom }
            if ($base.PSObject.Properties['deniedTo'] -and [string]$base.deniedTo) { $to = [datetime]$base.deniedTo }
            $list.Add([pscustomobject]@{
                    DBMS = 'MSSQLServer'; dbServerName = 'fixture-db'; dbName = $property.Name
                    Name = $property.Name; ScheduledJobsDenied = [bool]$base.scheduledJobsDenied; SessionsDenied = [bool]$base.sessionsDenied
                    PermissionCode = [string]$base.permissionCode; DeniedMessage = [string]$base.deniedMessage; DeniedFrom = $from; DeniedTo = $to
                })
        }
        return , $list.ToArray()
    }
    $process | Add-Member -MemberType ScriptMethod -Name UpdateInfoBase -Value {
        param($InfoBase)
        $state = Read-FakeComState $this.StateFile
        $base = Get-FakeComBase $state ([string]$InfoBase.Name)
        if ($null -eq $base) { throw ("нет базы {0}" -f $InfoBase.Name) }
        $base | Add-Member -NotePropertyName scheduledJobsDenied -NotePropertyValue ([bool]$InfoBase.ScheduledJobsDenied) -Force
        $base | Add-Member -NotePropertyName sessionsDenied -NotePropertyValue ([bool]$InfoBase.SessionsDenied) -Force
        $base | Add-Member -NotePropertyName permissionCode -NotePropertyValue ([string]$InfoBase.PermissionCode) -Force
        $base | Add-Member -NotePropertyName deniedMessage -NotePropertyValue ([string]$InfoBase.DeniedMessage) -Force
        # Начало и конец блокировки сеансов: в состоянии - текстом, в журнале - начало в секундах от сейчас
        # (больше нуля - блокировка с будущего времени, предупреждение пользователям) и сообщение.
        $fromText = ''
        $toText = ''
        $fromSec = ''
        if ($null -ne $InfoBase.DeniedFrom) { $fromText = ([datetime]$InfoBase.DeniedFrom).ToString('s'); $fromSec = [string][int](([datetime]$InfoBase.DeniedFrom) - (Get-Date)).TotalSeconds }
        if ($null -ne $InfoBase.DeniedTo) { $toText = ([datetime]$InfoBase.DeniedTo).ToString('s') }
        $base | Add-Member -NotePropertyName deniedFrom -NotePropertyValue $fromText -Force
        $base | Add-Member -NotePropertyName deniedTo -NotePropertyValue $toText -Force
        Save-FakeComState $this.StateFile $state
        Write-FakeComLog $this.StateFile ("UpdateInfoBase {0} scheduledJobsDenied={1} sessionsDenied={2} deniedFromSec={3} message={4}" -f $InfoBase.Name, [int][bool]$InfoBase.ScheduledJobsDenied, [int][bool]$InfoBase.SessionsDenied, $fromSec, [string]$InfoBase.DeniedMessage)
    }
    return $process
}

function New-FakeComConnection {
    param([string]$File, [string]$Base)
    $connection = [pscustomobject]@{
        StateFile = $File; Base = $Base
        ConfigurationExtensionsSource = [pscustomobject]@{ Database = 'Database' }
        ConfigurationExtensions = $null
    }
    $extensions = [pscustomobject]@{ StateFile = $File; Base = $Base }
    $extensions | Add-Member -MemberType ScriptMethod -Name Get -Value {
        param($Filter, $Source)
        $state = Read-FakeComState $this.StateFile
        if ($state.PSObject.Properties['extensionsReadDelayMs']) {
            [IO.File]::WriteAllText(($this.StateFile + '.reading'), [string]$PID)
            # Не прерывается остановкой конвейера PowerShell, как синхронный вызов COM в 1С.
            [Threading.Thread]::Sleep([int]$state.extensionsReadDelayMs)
        }
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in (Get-FakeComList (Get-FakeComBase $state $this.Base) 'extensions')) {
            $extension = [pscustomobject]@{ Name = [string]$item.name; Version = [string]$item.version; HashSum = [string]$item.hash }
            $extension | Add-Member -MemberType ScriptMethod -Name GetData -Value { return (New-FakeComData ([System.Text.Encoding]::UTF8.GetBytes('FAKECFE ' + $this.Name))) }
            $items.Add($extension)
        }
        # Коллекция 1С: Count() - метод, а у объекта PowerShell Count - встроенное свойство, поэтому класс.
        return (New-Object FakeComList -ArgumentList (, [object[]]$items.ToArray()))
    }
    $connection.ConfigurationExtensions = $extensions
    # Метаданные основной конфигурации: из «config» базы (name, synonym, version), нет - условные.
    $metadata = [pscustomobject]@{ Name = 'Конфигурация'; Synonym = 'Конфигурация'; Version = '1.0.0.1' }
    $baseState = Get-FakeComBase (Read-FakeComState $File) $Base
    if ($null -ne $baseState -and $null -ne $baseState.PSObject.Properties['config'] -and $null -ne $baseState.config) {
        foreach ($field in @('Name', 'Synonym', 'Version')) {
            $property = $baseState.config.PSObject.Properties[$field.ToLowerInvariant()]
            if ($null -ne $property -and $property.Value) { $metadata.$field = [string]$property.Value }
        }
    }
    # ** Хлебников С.Ю. 20261124 Подставные регистр и выборка профилей до выпуска.
    $registers = [pscustomobject]@{}
    $registers | Add-Member ScriptMethod Find { param($Name) return $Name }
    $metadata | Add-Member -NotePropertyName InformationRegisters -NotePropertyValue $registers
    # ** Хлебников С.Ю. 20261124 конец
    $connection | Add-Member -NotePropertyName Metadata -NotePropertyValue $metadata
    $connection | Add-Member -MemberType ScriptMethod -Name Base64String -Value { param($Value) return [string]$Value }
    $connection | Add-Member -MemberType ScriptMethod -Name String -Value { param($Value) return [string]$Value }
    $connection | Add-Member ScriptMethod UnloadEventLog {
        param($Table, $Filter, $Columns, $File, $Limit)
        $state = Read-FakeComState $this.StateFile
        $events = Get-FakeComList (Get-FakeComBase $state $this.Base) 'processingEvents'
        $Table.Rows = @(foreach ($entry in $events | Select-Object -First $Limit) {
            if ($Filter.Values['Событие'] -notcontains $entry.event) { continue }
            $ref = [pscustomobject]@{ Id = $entry.ref }
            $ref | Add-Member ScriptMethod UUID { return $this.Id }
            $item = [pscustomobject]@{ Values = @([datetime]$entry.at, $entry.event, $ref, [string]$entry.comment) }
            $item | Add-Member ScriptMethod Get { param($Index) return $this.Values[$Index] }
            $item
        })
    }
    $connection | Add-Member -MemberType ScriptMethod -Name NewObject -Value {
        param($TypeName, $QueryText = '')
        # ** Хлебников С.Ю. 20261124 Минимальные коллекции для чтения журнала регистрации.
        if ($TypeName -eq 'Array') { return ,(New-Object System.Collections.ArrayList) }
        if ($TypeName -eq 'Structure') {
            $filter = [pscustomobject]@{ Values = @{} }
            $filter | Add-Member ScriptMethod Insert { param($Key,$Value) $this.Values[$Key] = $Value }
            return $filter
        }
        if ($TypeName -eq 'ValueTable') {
            $table = [pscustomobject]@{ Rows = @() }
            $table | Add-Member ScriptMethod Count { return $this.Rows.Length }
            $table | Add-Member ScriptMethod Get { param($Index) return $this.Rows[$Index] }
            return $table
        }
        if ([string]$TypeName -ne 'Query') { return [pscustomobject]@{ TypeName = [string]$TypeName } }
        $query = [pscustomobject]@{ StateFile = $this.StateFile; Base = $this.Base; QueryText = $QueryText; TextWrites = 0; Parameters = @{} }
        $query | Add-Member ScriptProperty Text { $this.QueryText } {
            param($Value)
            $this.QueryText = $Value
            $this.TextWrites++
        }
        $query | Add-Member ScriptMethod SetParameter { param($Key,$Value) $this.Parameters[$Key]=$Value } # ** Хлебников С.Ю. 20261124
        $query | Add-Member -MemberType ScriptMethod -Name Execute -Value {
            # Запросы к справочнику обработок: из текста смотрится только отбор помеченных и табличная часть Назначение.
            $state = Read-FakeComState $this.StateFile
            if ($state.PSObject.Properties['singleQueryTextWrite'] -and $state.singleQueryTextWrite -and $this.TextWrites -gt 1) {
                throw 'COM: повторная запись свойства Text перед выполнением запроса'
            }
            # ** Хлебников С.Ю. 20261124 Только читающие запросы проверки данных перед выпуском.
            $baseState = Get-FakeComBase $state $this.Base
            if ($this.Text -match 'Выполненные\.Действие = &Действие') {
                $done = Get-FakeComList $baseState 'doneActions'
                $result = [pscustomobject]@{ Empty = $done -cnotcontains $this.Parameters['Действие'] }
                $result | Add-Member ScriptMethod IsEmpty { return $this.Empty }
                return $result
            }
            if ($this.Text -match 'Цель\.Ссылка ИЗ Справочник\.') {
                $hits = 0
                foreach ($row in (Get-FakeComList $baseState 'actionTargets')) {
                    if ($row.deleted -or $row.folder) { continue }
                    if ($this.Parameters.ContainsKey('Папка') -and $row.parent -ine $this.Parameters['Папка']) { continue }
                    $name = [string]$this.Parameters['Имя']
                    if ($this.Text -match 'ПОДОБНО') {
                        if (([string]$row.name).IndexOf($name.Trim('%'),[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                    } elseif ($row.name -ine $name) { continue }
                    $hits++
                }
                $result = [pscustomobject]@{ CountRows=$hits }
                $result | Add-Member ScriptMethod Select {
                    $rows = [pscustomobject]@{ Left=$this.CountRows }
                    $rows | Add-Member ScriptMethod Next { $this.Left--; return $this.Left -ge 0 }
                    return $rows
                }
                return $result
            }
            # ** Хлебников С.Ю. 20261124 конец
            $all = Get-FakeComList $baseState 'processings'
            $numbered = New-Object System.Collections.Generic.List[object]
            for ($index = 0; $index -lt @($all).Count; $index++) {
                $row = @($all)[$index]
                $ref = ('00000000-0000-0000-0000-{0:d12}' -f ($index + 1))
                if ($null -ne $row.PSObject.Properties['ref'] -and $row.ref) { $ref = [string]$row.ref }
                $numbered.Add([pscustomobject]@{ Row = $row; Ref = $ref })
            }
            if ([string]$this.Text -match '\.Назначение|РегистрСведений\.ВерсииОбъектов') {
                $targetRows = New-Object System.Collections.Generic.List[object]
                foreach ($entry in $numbered) {
                    if ($this.Text -match 'РегистрСведений\.ВерсииОбъектов') {
                        if ($entry.Row.PSObject.Properties['cardDate']) { $targetRows.Add([pscustomobject]@{ Ref=$entry.Ref; Target=[datetime]$entry.Row.cardDate }) }
                        continue
                    }
                    if ($null -eq $entry.Row.PSObject.Properties['targets']) { continue }
                    foreach ($target in @($entry.Row.targets)) { $targetRows.Add([pscustomobject]@{ Ref = $entry.Ref; Target = [string]$target }) }
                }
                $targetResult = [pscustomobject]@{ Rows = $targetRows.ToArray() }
                $targetResult | Add-Member -MemberType ScriptMethod -Name Select -Value {
                    $targetSelection = [pscustomobject]@{ Rows = $this.Rows; Index = -1 }
                    $targetSelection | Add-Member -MemberType ScriptMethod -Name Next -Value { $this.Index++; return ($this.Index -lt @($this.Rows).Count) }
                    $targetSelection | Add-Member -MemberType ScriptMethod -Name Get -Value {
                        param([int]$Index)
                        $row = @($this.Rows)[$this.Index]
                        if ($Index -eq 0) { $refObject = [pscustomobject]@{ Id = $row.Ref }; $refObject | Add-Member -MemberType ScriptMethod -Name UUID -Value { return $this.Id }; return $refObject }
                        return $row.Target
                    }
                    return $targetSelection
                }
                return $targetResult
            }
            $skipDeleted = [string]$this.Text -match 'НЕ Спр\.ПометкаУдаления'
            $rows = @($numbered | Where-Object { -not ($skipDeleted -and $null -ne $_.Row.PSObject.Properties['deleted'] -and [bool]$_.Row.deleted) })
            $result = [pscustomobject]@{ Rows = $rows }
            $result | Add-Member -MemberType ScriptMethod -Name Select -Value {
                $selection = [pscustomobject]@{ Rows = $this.Rows; Index = -1; Title = ''; ObjName = ''; Version = ''; Kind = ''; Storage = $null; Deleted = $false; Use = ''; SafeMode = $false; Ref = $null }
                $selection | Add-Member -MemberType ScriptMethod -Name Next -Value {
                    $this.Index++
                    if ($this.Index -ge @($this.Rows).Count) { return $false }
                    $entry = @($this.Rows)[$this.Index]
                    $row = $entry.Row
                    $this.Title = [string]$row.title
                    $this.ObjName = [string]$row.objName
                    $this.Version = [string]$row.version
                    $this.Kind = [string]$row.kind
                    $this.Deleted = ($null -ne $row.PSObject.Properties['deleted'] -and [bool]$row.deleted)
                    $this.Use = 'Используется'
                    if ($null -ne $row.PSObject.Properties['use'] -and $row.use) { $this.Use = [string]$row.use }
                    $this.SafeMode = ($null -eq $row.PSObject.Properties['safeMode'] -or [bool]$row.safeMode)
                    $refObject = [pscustomobject]@{ Id = $entry.Ref }
                    $refObject | Add-Member -MemberType ScriptMethod -Name UUID -Value { return $this.Id }
                    $this.Ref = $refObject
                    $this.Storage = $null
                    if ($null -ne $row.PSObject.Properties['content'] -and $null -ne $row.content) {
                        $storage = [pscustomobject]@{ Content = [string]$row.content }
                        $storage | Add-Member -MemberType ScriptMethod -Name Get -Value { return (New-FakeComData ([System.Text.Encoding]::UTF8.GetBytes($this.Content))) }
                        $this.Storage = $storage
                    }
                    return $true
                }
                # Получить(Индекс): поля в порядке запроса - Наименование, ИмяОбъекта, Версия, Вид, Хранилище,
                # ПометкаУдаления, Публикация, БезопасныйРежим, Ссылка.
                $selection | Add-Member -MemberType ScriptMethod -Name Get -Value {
                    param([int]$Index)
                    switch ($Index) {
                        0 { return $this.Title } 1 { return $this.ObjName } 2 { return $this.Version } 3 { return $this.Kind } 4 { return $this.Storage }
                        5 { return $this.Deleted } 6 { return $this.Use } 7 { return $this.SafeMode } 8 { return $this.Ref }
                    }
                    return $null
                }
                return $selection
            }
            return $result
        }
        return $query
    }
    return $connection
}
