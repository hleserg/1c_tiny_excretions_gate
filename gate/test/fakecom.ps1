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
        "processings": [ { "objName": "...", "title": "...", "version": "...", "kind": "...", "content": "..." } ]
      }
    },
    "sessions": [ { "id": 1, "base": "<имя базы>", "app": "1CV8C", "user": "...", "host": "..." } ],
    "failConnect": [ "<имя базы>" ]      - внешнее соединение к этой базе падает
    "lockedConnect": [ "<имя базы>" ]    - в базе чужая блокировка начала сеансов (техработы)
  }

Что умеет - то, чем пользуется deploy.ps1:
  агент: ConnectAgent, GetClusters, Authenticate, GetSessions, TerminateSession, GetWorkingProcesses;
  рабочий процесс: ConnectWorkingProcess, AuthenticateAdmin, AddAuthentication, GetInfoBases, UpdateInfoBase;
  внешнее соединение: Connect, ConfigurationExtensions.Get, ConfigurationExtensionsSource, Base64String,
  расширение.GetData().Write, NewObject('Query') - запрос к справочнику обработок (Execute, Select, Next,
  Storage.Get().Write).
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
    $agent | Add-Member -MemberType ScriptMethod -Name GetClusters -Value { return , @([pscustomobject]@{ HostName = 'fake'; MainPort = 1541 }) }
    $agent | Add-Member -MemberType ScriptMethod -Name Authenticate -Value { param($Cluster, $User, $Password) }
    $agent | Add-Member -MemberType ScriptMethod -Name GetWorkingProcesses -Value { param($Cluster) return , @([pscustomobject]@{ Running = 1; HostName = 'fake'; MainPort = 1560 }) }
    $agent | Add-Member -MemberType ScriptMethod -Name GetSessions -Value {
        param($Cluster)
        $state = Read-FakeComState $this.StateFile
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($session in (Get-FakeComList $state 'sessions')) {
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
            $list.Add([pscustomobject]@{
                    Name = $property.Name; ScheduledJobsDenied = [bool]$base.scheduledJobsDenied; SessionsDenied = [bool]$base.sessionsDenied
                    PermissionCode = [string]$base.permissionCode; DeniedMessage = [string]$base.deniedMessage; DeniedFrom = $null; DeniedTo = $null
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
        Save-FakeComState $this.StateFile $state
        Write-FakeComLog $this.StateFile ("UpdateInfoBase {0} scheduledJobsDenied={1} sessionsDenied={2}" -f $InfoBase.Name, [int][bool]$InfoBase.ScheduledJobsDenied, [int][bool]$InfoBase.SessionsDenied)
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
    $connection | Add-Member -MemberType ScriptMethod -Name Base64String -Value { param($Value) return [string]$Value }
    $connection | Add-Member -MemberType ScriptMethod -Name NewObject -Value {
        param($TypeName)
        if ([string]$TypeName -ne 'Query') { return [pscustomobject]@{ TypeName = [string]$TypeName } }
        $query = [pscustomobject]@{ StateFile = $this.StateFile; Base = $this.Base; Text = '' }
        $query | Add-Member -MemberType ScriptMethod -Name Execute -Value {
            # Запрос один - к справочнику обработок, его текст не разбирается.
            $state = Read-FakeComState $this.StateFile
            $rows = Get-FakeComList (Get-FakeComBase $state $this.Base) 'processings'
            $result = [pscustomobject]@{ Rows = $rows }
            $result | Add-Member -MemberType ScriptMethod -Name Select -Value {
                $selection = [pscustomobject]@{ Rows = $this.Rows; Index = -1; Title = ''; ObjName = ''; Version = ''; Kind = ''; Storage = $null }
                $selection | Add-Member -MemberType ScriptMethod -Name Next -Value {
                    $this.Index++
                    if ($this.Index -ge @($this.Rows).Count) { return $false }
                    $row = @($this.Rows)[$this.Index]
                    $this.Title = [string]$row.title
                    $this.ObjName = [string]$row.objName
                    $this.Version = [string]$row.version
                    $this.Kind = [string]$row.kind
                    $storage = [pscustomobject]@{ Content = [string]$row.content }
                    $storage | Add-Member -MemberType ScriptMethod -Name Get -Value { return (New-FakeComData ([System.Text.Encoding]::UTF8.GetBytes($this.Content))) }
                    $this.Storage = $storage
                    return $true
                }
                return $selection
            }
            return $result
        }
        return $query
    }
    return $connection
}
