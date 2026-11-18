#requires -Version 5.1
<#
.SYNOPSIS
    Гейт комплекта расширений 1С:
    загрузка в тестовую базу, проверки конфигуратором, канареечный вход,
    самопроверка (автозапуск обработки «Выполнить после обновления», сравнение до и после), вердикт.

.DESCRIPTION
    .\run.ps1
        Проверить базу как есть, без загрузки. С этого начинаем: получаем эталон «до».

    .\run.ps1 -Kit D:\ci\inbox\20261114
        Загрузить комплект и проверить. В папке комплекта лежат файлы .cfe
        (в имени файла есть имя расширения) и/или каталоги выгрузки в файлы.
        Вместо папки можно указать архив .zip, один файл .cfe или сам каталог выгрузки.

    .\run.ps1 -AcceptBaseline runs\20261114-120000
        Принять замечания этого прогона как известные. Дальше красным будет только новое.

    .\run.ps1 -SkipChecks
        Без проверок конфигуратором.

    .\run.ps1 -SkipSelfCheck
        Без самопроверки.

    .\run.ps1 -Kit D:\ci\inbox\20261114 -FreshBefore
        Снять состояние «до загрузки» заново, даже если база не менялась после прошлого прогона.

    .\run.ps1 -Kit D:\ci\inbox\20261114 -OnNotGreen Rollback
        Если вердикт красный или жёлтый с замечаниями, откатить комплект без вопроса.
        Keep - оставить без вопроса, Ask - спросить (так по умолчанию).

    .\run.ps1 -Kit D:\ci\inbox\20261114 -OnSessions Terminate
        Если в базе перед началом есть сеансы: Ask - спросить (так по умолчанию), Continue - работать
        как есть, Exit - выйти, Terminate - поставить блокировку сеансов и завершить их.

    .\run.ps1 -Kit D:\ci\inbox\20261114 -ReleaseJobsLock
        Блокировку регламентных заданий, которую гейт поставил в начале, в конце снять.
        Без ключа она остаётся (или настройка ReleaseJobsLock = $true).

    .\run.ps1 -SavePassword secrets\robot.txt
        Сохранить пароль. Файл шифруется под текущей учёткой Windows на этой машине.

    Код возврата: 0 зелёный, 2 жёлтый (посмотреть глазами), 1 красный.

.NOTES
    Версия 00000000.000000.
    Проверки конфигуратором, канареечный вход, /DumpCfg, /LoadCfg и /UpdateDBCfg с -Extension
    подтверждены прогонами на temp 14-15.11.2026.
    Самопроверка без комплекта выполнена на temp 16.11.2026 (прогон 20261116-092723);
    с комплектом (сравнение до и после) ещё не выполнялась.
    Вопрос про комплект после вердикта и откат (возврат из before, /DeleteCfg -Extension для нового
    расширения) на деле ещё не выполнялись. /LoadConfigFromFiles с -Extension тоже.
    Распаковка архива комплекта и поиск выгрузки в подпапках на деле тоже ещё не выполнялись.
    Загрузка из каталога выгрузки (/LoadConfigFromFiles -Extension) выполнена 17.11.2026, прогон 20261117-002249.
    После вердикта гейт вызывает разбор прогона report.ps1 (report.txt в папке прогона).
    Опрос сеансов при монопольной блокировке (канарейка 20261117 и новее) на деле ещё не выполнялся.
    Чтение сеансов erp_temp через V83.COMConnector проверено 17.11.2026; завершение (TerminateSession) ещё нет.
    Подготовка базы перед прогоном (блокировка регламентных заданий, проверка сеансов, блокировка
    начала сеансов на время прогона) на деле ещё не выполнялась.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run', Position = 0)]
    [string]$Kit = '',

    [Parameter(ParameterSetName = 'Run')]
    [string]$Config = '',

    [Parameter(ParameterSetName = 'Run')]
    [switch]$SkipChecks,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$SkipCanary,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$SkipSelfCheck,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$FreshBefore,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('Ask', 'Keep', 'Rollback')]
    [string]$OnNotGreen = '',

    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('Ask', 'Continue', 'Exit', 'Terminate')]
    [string]$OnSessions = '',

    [Parameter(ParameterSetName = 'Run')]
    [switch]$ReleaseJobsLock,

    # Папка канала интерфейса ci.exe: его задаёт сам ci.exe, руками не нужен.
    [Parameter(ParameterSetName = 'Run')]
    [string]$UiChannel = '',

    [Parameter(ParameterSetName = 'Accept', Mandatory = $true)]
    [string]$AcceptBaseline,

    [Parameter(ParameterSetName = 'Password', Mandatory = $true)]
    [string]$SavePassword
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Из ci.exe вывод читается программой: только UTF-8, иначе русский текст придёт в кодировке 866.
if ($UiChannel) {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    # Полосы Write-Progress PowerShell рисует прямо в консоли, поверх экрана ci.exe.
    $ProgressPreference = 'SilentlyContinue'
}

# Блокировку начала сеансов на время прогона ставит гейт (ответ «завершить и продолжить» перед началом).
# Снимает её в конце прогона и при остановке; если скрипт оборвали, она кончится сама через SessionLockHours.
$script:SessionLockSet = $false
$script:SessionLockCode = ''
# Блокировку регламентных заданий гейт ставит в начале и обычно оставляет. С ключом -ReleaseJobsLock
# (или настройкой ReleaseJobsLock) снимает в конце, но только если поставил её сам.
$script:JobsLockSet = $false
$script:JobsLockRelease = $false
# Проверка конфигурации, которая идёт параллельно с остальными шагами, и ожидаемые длительности шагов плана
# (для оценки, сколько осталось всего прогона).
$script:BackgroundCheck = $null
$script:RunPlanExpected = [ordered]@{}

# Скрипт остановился: причина одной строкой. Место в скрипте показывается только для неожиданной
# ошибки. У остановки по throw с текстом оно ничего не объясняет; отличить её можно по тому,
# что идентификатор ошибки совпадает с её текстом.
trap {
    Write-Host ''
    Write-Host ("Остановлено: {0}" -f $_.Exception.Message) -ForegroundColor Red
    # Проверка конфигурации, запущенная параллельно (ParallelCheckConfig), не должна пережить скрипт.
    if ($null -ne $script:BackgroundCheck) { try { Stop-Process -Id $script:BackgroundCheck.Process.Id -Force -ErrorAction Stop } catch { } }
    if ([string]$_.FullyQualifiedErrorId -ne [string]$_.Exception.Message -and $null -ne $_.InvocationInfo) {
        Write-Host ("  {0}" -f ($_.InvocationInfo.PositionMessage -split "`r?`n")[0]) -ForegroundColor DarkGray
    }
    if ($script:SessionLockSet -or ($script:JobsLockSet -and $script:JobsLockRelease)) {
        try { Clear-TestBaseLocks } catch { Write-Host ("Блокировки снять не получилось: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
    }
    exit 1
}

$Root = $PSScriptRoot
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)

# Имя базы должно быть похоже на тестовую. То же правило, что в обработке «Выполнить после обновления».
$TestBasePattern = 'temp|test|copy|tmp|dev|sandbox|stand|тест|копи|стенд|песочниц'

#region Общие функции

function Resolve-RootPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $Root $Path)
}

function Get-Setting {
    param([hashtable]$Table, [string]$Key, $Default)
    if ($Table.ContainsKey($Key) -and $null -ne $Table[$Key]) { return $Table[$Key] }
    return $Default
}

function Write-RunLog {
    param([string]$Text)
    $stamp = Get-Date -Format 'HH:mm:ss'
    [System.IO.File]::AppendAllText($script:RunLogPath, ("{0} {1}`r`n" -f $stamp, $Text), $Utf8Bom)
}

function Get-PlainPassword {
    param([string]$PassFile)
    if ([string]::IsNullOrWhiteSpace($PassFile)) { return '' }
    $path = Resolve-RootPath $PassFile
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Нет файла пароля: $path. Создай его: .\run.ps1 -SavePassword `"$PassFile`""
    }
    $encrypted = (Get-Content -LiteralPath $path -Raw).Trim()
    $secure = ConvertTo-SecureString -String $encrypted
    $credential = New-Object System.Management.Automation.PSCredential('user', $secure)
    return $credential.GetNetworkCredential().Password
}

function Get-ConnectionArgs {
    param([string]$User, [string]$Password)
    $list = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($script:FileBase)) {
        $list.Add(('/F"{0}"' -f $script:FileBase))
    }
    else {
        $list.Add(('/S"{0}\{1}"' -f $script:Server, $script:Base))
    }
    if (-not [string]::IsNullOrEmpty($script:UnlockCode)) {
        $list.Add(('/UC"{0}"' -f $script:UnlockCode))
    }
    # Пустое имя = авторизация текущим пользователем Windows.
    if (-not [string]::IsNullOrEmpty($User)) {
        $list.Add(('/N"{0}"' -f $User))
        if (-not [string]::IsNullOrEmpty($Password)) {
            $list.Add(('/P"{0}"' -f $Password))
        }
    }
    return $list.ToArray()
}

$script:StepMedians = $null

function Get-ExpectedStepSeconds {
    # Сколько шаг обычно идёт: медиана по последним 15 прогонам, где шаг с этим именем прошёл.
    # Нет таких прогонов - 0, тогда строка хода без полосы.
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return 0 }
    # Сначала прогноз по статистике (stats.ps1): размер, время суток, калибровка. Нет записей - медиана, как раньше.
    $statPlan = Get-StatPlan $Name
    if ($statPlan -gt 0) { return $statPlan }
    if ($null -eq $script:StepMedians) {
        $script:StepMedians = @{}
        $samples = @{}
        $runsFolder = Resolve-RootPath ([string](Get-Setting $cfg 'RunsDir' 'runs'))
        if (Test-Path -LiteralPath $runsFolder) {
            foreach ($run in @(Get-ChildItem -LiteralPath $runsFolder -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending | Select-Object -First 15)) {
                $file = Join-Path $run.FullName 'verdict.json'
                if (-not (Test-Path -LiteralPath $file)) { continue }
                try { $saved = (Get-Content -LiteralPath $file -Raw -Encoding UTF8) | ConvertFrom-Json } catch { continue }
                foreach ($step in @($saved.steps)) {
                    if ($null -eq $step -or [string]$step.status -ne 'OK' -or [int]$step.seconds -le 0) { continue }
                    $key = [string]$step.name
                    if (-not $samples.ContainsKey($key)) { $samples[$key] = New-Object System.Collections.Generic.List[int] }
                    $samples[$key].Add([int]$step.seconds)
                }
            }
        }
        foreach ($key in $samples.Keys) {
            $sorted = @($samples[$key] | Sort-Object)
            $script:StepMedians[$key] = $sorted[[int][Math]::Floor($sorted.Count / 2)]
        }
    }
    if ($script:StepMedians.ContainsKey($Name)) { return [double]$script:StepMedians[$Name] }
    return 0
}

function Invoke-V8 {
    # Запускает 1С и ждёт завершения не дольше таймаута. По таймауту процесс снимается.
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec, [string]$Title = '')

    $argLine = $Arguments -join ' '
    $shown = [regex]::Replace([regex]::Replace($argLine, '/P"[^"]*"', '/P"***"'), '/UC"[^"]*"', '/UC"***"')
    Write-RunLog ("> {0} {1}" -f (Split-Path -Leaf $Exe), $shown)

    if ($Title) {
        Write-Host ("  ...  {0}: начато в {1}, жду не дольше {2} мин" -f $Title, (Get-Date -Format 'HH:mm:ss'), [int]($TimeoutSec / 60)) -ForegroundColor DarkGray
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $Exe -ArgumentList $argLine -PassThru
    $null = $process.Handle   # без этого ExitCode после ожидания может оказаться пустым

    # Строка хода: полоса по времени прошлых прогонов этого шага или бегающий блок (ui.ps1).
    $finished = Wait-UiProcess -Process $process -Watch $watch -TimeoutSec $TimeoutSec -Title $Title -Expected (Get-ExpectedStepSeconds $Title)
    $exitCode = $null
    if ($finished) {
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    else {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
    }
    $watch.Stop()

    $seconds = [int]$watch.Elapsed.TotalSeconds
    Write-RunLog ("  код={0} таймаут={1} секунд={2}" -f $exitCode, (-not $finished), $seconds)
    if ($Title) {
        $statStatus = 'FAIL'
        if (-not $finished) { $statStatus = 'TIMEOUT' } elseif ($exitCode -eq 0) { $statStatus = 'OK' }
        Add-StatFact -Title $Title -Seconds $watch.Elapsed.TotalSeconds -Status $statStatus
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = (-not $finished)
        Seconds  = $seconds
    }
}

function Read-V8Log {
    # Лог 1С бывает и в UTF-8, и в cp1251: определяем по содержимому.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return @() }

    $text = $null
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
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

function ConvertTo-CheckRecords {
    # Превращает лог проверки в набор записей для сравнения с эталоном.
    # Ошибка компиляции занимает две строки (заголовок и строка кода с меткой <<?>>): склеиваем их в одну запись.
    # Номера строк и версии расширений убираем, иначе известное замечание после любой правки выглядит новым.
    param([string[]]$Lines)
    $set = New-Object 'System.Collections.Generic.SortedSet[string]' ([System.StringComparer]::Ordinal)
    $count = 0
    if ($null -ne $Lines) { $count = $Lines.Length }
    $index = 0
    while ($index -lt $count) {
        $line = $Lines[$index]
        $index++
        if ($null -eq $line) { continue }
        $record = $line.Trim().Trim([char]0xFEFF)
        if ($record.Length -eq 0) { continue }
        if ($record.StartsWith('{')) {
            $record = $record -replace '\(\d+\s*,\s*\d+\)\}', '()}'
            if ($index -lt $count -and $null -ne $Lines[$index] -and $Lines[$index].Contains('<<?>>')) {
                $record = $record + ' :: ' + $Lines[$index].Trim()
                $index++
            }
        }
        else {
            # "Расширение (1.2.3.4): текст" -> "Расширение: текст"
            $record = $record -replace '^(\S+) \([^)]*\): ', '$1: '
        }
        [void]$set.Add($record)
    }
    return @($set)
}

function Get-RecordKind {
    # Вид замечания и его вес. Красные блокируют выкладку, жёлтые нужно посмотреть глазами.
    param([string]$Record)
    if ($Record.StartsWith('{')) { return [pscustomobject]@{ Kind = 'ошибка компиляции'; Red = $true } }
    if ($Record.Contains('Неразрешимые ссылки')) { return [pscustomobject]@{ Kind = 'неразрешимые ссылки'; Red = $true } }
    if ($Record.Contains('Возможно ошибочн')) { return [pscustomobject]@{ Kind = 'возможно ошибочное обращение'; Red = $false } }
    if ($Record.Contains('Отсутствует обработчик')) { return [pscustomobject]@{ Kind = 'отсутствует обработчик'; Red = $false } }
    return [pscustomobject]@{ Kind = 'прочее'; Red = $true }
}

function Test-DesignerBusy {
    # Пакетный конфигуратор не подключился: конфигурация этой базы открыта в другом конфигураторе.
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ($null -eq $line) { continue }
        if ($line.Contains('уже работает конфигуратор') -or $line.Contains('уже открыта Конфигуратором') -or $line.Contains('Ошибка блокировки информационной базы для конфигурирования')) { return $true }
    }
    return $false
}

function Compare-WithBaseline {
    param([string[]]$Current, [string]$BaselineFile)
    $hasBaseline = Test-Path -LiteralPath $BaselineFile
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($hasBaseline) {
        foreach ($line in [System.IO.File]::ReadAllLines($BaselineFile, [System.Text.Encoding]::UTF8)) {
            [void]$known.Add($line)
        }
    }
    $new = New-Object System.Collections.Generic.List[string]
    $present = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($line in $Current) {
        [void]$present.Add($line)
        if (-not $known.Contains($line)) { $new.Add($line) }
    }
    $goneCount = 0
    foreach ($line in $known) {
        if (-not $present.Contains($line)) { $goneCount++ }
    }
    return [pscustomobject]@{
        HasBaseline = $hasBaseline
        NewLines    = $new.ToArray()
        KnownCount  = $known.Count
        GoneCount   = $goneCount
    }
}

function Get-LogTail {
    param([string[]]$Lines, [int]$Count = 4)
    $meaningful = @($Lines | Where-Object { $null -ne $_ -and $_.Trim().Length -gt 0 })
    if ($meaningful.Count -eq 0) { return 'лог пуст' }
    $tail = @($meaningful | Select-Object -Last $Count)
    return ($tail -join ' | ')
}

function Add-StepResult {
    param(
        [string]$Name,
        [ValidateSet('OK', 'WARN', 'FAIL', 'SKIP')][string]$Status,
        [string]$Detail = '',
        [string]$Log = '',
        [int]$Seconds = 0
    )
    $script:Steps.Add([pscustomobject]@{
            name    = $Name
            status  = $Status
            detail  = $Detail
            log     = $Log
            seconds = $Seconds
        })
    $color = 'Gray'
    if ($Status -eq 'OK') { $color = 'Green' }
    if ($Status -eq 'WARN') { $color = 'Yellow' }
    if ($Status -eq 'FAIL') { $color = 'Red' }
    Write-Host ("[{0,-4}] {1}" -f $Status, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("       {0}" -f $Detail) }
    Write-RunLog ("[{0}] {1}: {2}" -f $Status, $Name, $Detail)
}

$script:WinApiReady = $false

function Initialize-WinApi {
    # Функции Windows для перечисления и съёмки окон процесса. Если не собрались, прогон идёт дальше без снимков.
    if ($script:WinApiReady) { return $true }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        Add-Type -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public static class CiWindows
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static IntPtr[] VisibleWindows(int processId)
    {
        List<IntPtr> found = new List<IntPtr>();
        EnumWindowsProc callback = delegate(IntPtr hWnd, IntPtr lParam)
        {
            uint windowProcessId;
            GetWindowThreadProcessId(hWnd, out windowProcessId);
            if (windowProcessId == (uint)processId && IsWindowVisible(hWnd))
            {
                found.Add(hWnd);
            }
            return true;
        };
        EnumWindows(callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        return found.ToArray();
    }

    public static string Describe(IntPtr hWnd)
    {
        StringBuilder title = new StringBuilder(512);
        StringBuilder className = new StringBuilder(256);
        GetWindowText(hWnd, title, title.Capacity);
        GetClassName(hWnd, className, className.Capacity);
        RECT rect;
        GetWindowRect(hWnd, out rect);
        return string.Format("\"{0}\" [{1}, {2}x{3}]", title, className, rect.Right - rect.Left, rect.Bottom - rect.Top);
    }

    public static bool Capture(IntPtr hWnd, string path)
    {
        RECT rect;
        if (!GetWindowRect(hWnd, out rect))
        {
            return false;
        }
        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;
        if (width < 50 || height < 30)
        {
            return false;
        }
        bool printed;
        using (Bitmap bitmap = new Bitmap(width, height))
        {
            using (Graphics graphics = Graphics.FromImage(bitmap))
            {
                IntPtr hdc = graphics.GetHdc();
                printed = PrintWindow(hWnd, hdc, 2);
                graphics.ReleaseHdc(hdc);
            }
            bitmap.Save(path, ImageFormat.Png);
        }
        return printed;
    }
}
'@
        $script:WinApiReady = $true
    }
    catch {
        Write-RunLog ("Не удалось подготовить съёмку окон: {0}" -f $_.Exception.Message)
    }
    return $script:WinApiReady
}

function Save-ProcessWindows {
    # Заголовки и снимки видимых окон процесса. Снимается только сам клиент, остальной экран в кадр не попадает.
    param([int]$ProcessId, [string]$FilePrefix)
    $descriptions = New-Object System.Collections.Generic.List[string]
    if (-not (Initialize-WinApi)) {
        $descriptions.Add('окна перечислить не удалось')
        return $descriptions.ToArray()
    }
    try {
        $number = 0
        foreach ($handle in [CiWindows]::VisibleWindows($ProcessId)) {
            $number++
            $description = [CiWindows]::Describe($handle)
            $shotName = ''
            try {
                $shotPath = "{0}_window{1}.png" -f $FilePrefix, $number
                if ([CiWindows]::Capture($handle, $shotPath)) { $shotName = Split-Path -Leaf $shotPath }
            }
            catch { }
            if ($shotName) { $description = "{0} снимок {1}" -f $description, $shotName }
            $descriptions.Add($description)
        }
        if ($number -eq 0) { $descriptions.Add('видимых окон у клиента нет') }
    }
    catch {
        $descriptions.Add(("окна перечислить не удалось: {0}" -f $_.Exception.Message))
    }
    return $descriptions.ToArray()
}

#endregion

#region Самопроверка: разбор файлов обработки «Выполнить после обновления»

# Строка журнала самопроверки с записью: «ЧЧ:мм:сс [ВИД] текст». Продолжение записи идёт с отступом в 20 пробелов.
$SelfCheckLineRegex = New-Object System.Text.RegularExpressions.Regex('^\d\d:\d\d:\d\d \[(ОК|ОШИБКА|ВНИМАНИЕ|ПРОПУСК|ИНФО)\]\s*(.*)$')
$SelfCheckIndent = '                    '
$SelfCheckBrokenTask = 'задание не завершилось: клиент 1С завис или закрылся, результата нет'

function Read-KeyValueFile {
    # Файл из строк «ключ=значение» -> таблица. Файла нет или он ещё пишется - таблица пустая.
    param([string]$Path)
    $table = @{}
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return $table }
    $lines = @()
    try { $lines = @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) }
    catch { return $table }
    foreach ($line in $lines) {
        if ($null -eq $line) { continue }
        $clean = $line.TrimStart([char]0xFEFF)
        $position = $clean.IndexOf('=')
        if ($position -le 0) { continue }
        $table[$clean.Substring(0, $position).Trim()] = $clean.Substring($position + 1)
    }
    return $table
}

function Read-SelfCheckPiece {
    # Часть журнала: заголовок из строк «@@имя=значение» до строки «@@journal», дальше строки журнала.
    param([string]$Path)
    # После строк журнала могут идти снимки шагов: строка «@@snapshots», дальше блоки
    # «@@snap <ключ>», строки текста с «|» в начале, «@@snap-end». В журнал и записи они не идут.
    $header = @{}
    $blocks = New-Object System.Collections.Generic.List[string]
    $body = New-Object System.Collections.Generic.List[string]
    $snapshots = [ordered]@{}
    $inBody = $false
    $inSnapshots = $false
    $snapKey = $null
    $snapLines = $null
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($null -eq $line) { continue }
        if ($inSnapshots) {
            if ($line.StartsWith('@@snap ', [System.StringComparison]::Ordinal)) {
                $snapKey = $line.Substring(7).Trim()
                $snapLines = New-Object System.Collections.Generic.List[string]
            }
            elseif ($line -eq '@@snap-end') {
                if ($null -ne $snapKey -and $snapKey.Length -gt 0) { $snapshots[$snapKey] = $snapLines.ToArray() }
                $snapKey = $null
                $snapLines = $null
            }
            elseif ($null -ne $snapLines -and $line.StartsWith('|', [System.StringComparison]::Ordinal)) {
                $snapLines.Add($line.Substring(1))
            }
            continue
        }
        if ($inBody) {
            if ($line -eq '@@snapshots') { $inSnapshots = $true; continue }
            $body.Add($line)
            continue
        }
        $clean = $line.TrimStart([char]0xFEFF)
        if ($clean -eq '@@journal') { $inBody = $true; continue }
        if ($clean.StartsWith('@@')) {
            $position = $clean.IndexOf('=')
            if ($position -le 2) { continue }
            $key = $clean.Substring(2, $position - 2)
            # Шаги самопроверки (@@block, по строке на шаг) - списком: по ним ci.exe рисует второй трубопровод.
            if ($key -eq 'block') { $blocks.Add($clean.Substring($position + 1)); continue }
            $header[$key] = $clean.Substring($position + 1)
        }
    }
    return [pscustomobject]@{ Header = $header; Blocks = $blocks.ToArray(); Body = $body.ToArray(); Snapshots = $snapshots; Complete = $inBody }
}

function Get-SelfCheckPieceFiles {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $Dir -Filter 'p*.txt' -File | Where-Object { $_.Name -match '^p\d{6}\.txt$' } | Sort-Object Name)
}

function Format-SelfCheckText {
    # Убирает из текста записи то, что меняется от прогона к прогону само по себе.
    param([string]$Text)
    $result = [regex]::Replace($Text, '\(\d+(\s*,\s*\d+)?\)\}', '()}')     # номера строк модулей в текстах ошибок
    $result = [regex]::Replace($result, '\d+ мс', 'N мс')                   # длительности
    $result = [regex]::Replace($result, '\d{8}\.\d{6}', '<сборка>')         # версии вида ГГГГММДД.ЧЧММСС
    $result = [regex]::Replace($result, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<guid>')
    # Даты, время и числа: счётчики запусков, записей, «последний запуск в ...» меняются между «до» и «после»
    # сами по себе. Прогон 20261117-002249: запись об ошибке регламентного задания подрядчика содержала число
    # запусков и время последнего, и без этой замены каждый прогон давал бы её как новую ошибку.
    $result = [regex]::Replace($result, '\d{1,2}\.\d{1,2}\.\d{4}(\s+\d{1,2}:\d{2}(:\d{2})?)?', '<дата>')
    $result = [regex]::Replace($result, '\d{1,2}:\d{2}:\d{2}', '<время>')
    $result = [regex]::Replace($result, '\b\d+\b', 'N')
    return $result
}

function ConvertTo-SelfCheckRecords {
    # Строки журнала одного задания -> записи «[ВИД] ключ задания :: текст». Записи ИНФО в сравнение не идут.
    param([string]$Key, [string[]]$Lines)
    $records = New-Object System.Collections.Generic.List[string]
    $current = $null
    foreach ($line in $Lines) {
        if ($null -eq $line) { continue }
        $found = $SelfCheckLineRegex.Match($line)
        if ($found.Success) {
            if ($null -ne $current) { $records.Add($current) }
            $current = $null
            $kind = $found.Groups[1].Value
            if ($kind -cne 'ИНФО') {
                $text = Format-SelfCheckText $found.Groups[2].Value.Trim()
                $current = '[{0}] {1} :: {2}' -f $kind, $Key, $text
            }
            continue
        }
        if ($line.StartsWith($SelfCheckIndent, [System.StringComparison]::Ordinal)) {
            # Продолжение записи. Продолжение записи ИНФО пропускается вместе с ней.
            if ($null -ne $current) {
                $part = Format-SelfCheckText $line.Trim()
                if ($part.Length -gt 0) { $current = $current + ' || ' + $part }
            }
            continue
        }
        # Заголовок шага, итог шага, пустая строка: запись закончилась.
        if ($null -ne $current) { $records.Add($current) }
        $current = $null
    }
    if ($null -ne $current) { $records.Add($current) }
    return $records.ToArray()
}

function Compare-SelfCheck {
    # Сравнивает записи самопроверки с эталоном. Новое - то, чего в эталоне нет.
    param([string[]]$Current, [string]$ReferenceFile)
    $hasReference = Test-Path -LiteralPath $ReferenceFile
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($hasReference) {
        foreach ($line in [System.IO.File]::ReadAllLines($ReferenceFile, [System.Text.Encoding]::UTF8)) {
            # Эталон, снятый прежней версией гейта, приводится к нынешнему виду: замены в Format-SelfCheckText
            # только добавлялись, повторное применение к уже приведённой записи ничего не меняет.
            if ($null -ne $line) { [void]$known.Add((Format-SelfCheckText $line.TrimStart([char]0xFEFF))) }
        }
    }
    $present = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $newErrors = New-Object System.Collections.Generic.List[string]
    $newWarnings = New-Object System.Collections.Generic.List[string]
    $newSkips = New-Object System.Collections.Generic.List[string]
    $errorsTotal = 0
    foreach ($currentRecord in $Current) {
        $record = Format-SelfCheckText $currentRecord
        if (-not $present.Add($record)) { continue }
        $isError = $record.StartsWith('[ОШИБКА]', [System.StringComparison]::Ordinal)
        if ($isError) { $errorsTotal++ }
        if ($known.Contains($record)) { continue }
        if ($isError) { $newErrors.Add($record) }
        elseif ($record.StartsWith('[ВНИМАНИЕ]', [System.StringComparison]::Ordinal)) { $newWarnings.Add($record) }
        elseif ($record.StartsWith('[ПРОПУСК]', [System.StringComparison]::Ordinal)) { $newSkips.Add($record) }
    }
    $fixedErrors = 0
    $goneOk = 0
    foreach ($record in $known) {
        if ($present.Contains($record)) { continue }
        if ($record.StartsWith('[ОШИБКА]', [System.StringComparison]::Ordinal)) { $fixedErrors++ }
        elseif ($record.StartsWith('[ОК]', [System.StringComparison]::Ordinal)) { $goneOk++ }
    }
    return [pscustomobject]@{
        HasReference = $hasReference
        NewErrors    = $newErrors.ToArray()
        NewWarnings  = $newWarnings.ToArray()
        NewSkips     = $newSkips.ToArray()
        ErrorsTotal  = $errorsTotal
        FixedErrors  = $fixedErrors
        GoneOk       = $goneOk
    }
}

function Format-SelfCheckSnapshot {
    # Текст снимка -> строки для сравнения. XML (сообщение обмена) разбирается и раскладывается по строкам
    # с отступами, из него убираются поля заголовка, которые меняются при каждой выгрузке сами по себе:
    # дата создания и номера сообщений. Не XML - строки как есть, без хвостовых пробелов.
    param([string[]]$Lines)
    $text = ($Lines -join "`n").Trim()
    if ($text.StartsWith('<')) {
        try {
            $document = New-Object System.Xml.XmlDocument
            $document.PreserveWhitespace = $false
            $document.LoadXml($text)
            # Объявление XML (кодировка) убирается: при записи в строку оно мешает и сравнивать в нём нечего.
            foreach ($child in @($document.ChildNodes)) { if ($child -is [System.Xml.XmlDeclaration]) { [void]$document.RemoveChild($child) } }
            $volatile = @($document.SelectNodes("//*[local-name()='CreationDate' or local-name()='MessageNo' or local-name()='ReceivedNo']"))
            foreach ($node in $volatile) { [void]$node.ParentNode.RemoveChild($node) }
            $settings = New-Object System.Xml.XmlWriterSettings
            $settings.Indent = $true
            $settings.IndentChars = '  '
            $settings.OmitXmlDeclaration = $true
            $settings.NewLineChars = "`n"
            $builder = New-Object System.Text.StringBuilder
            $writer = [System.Xml.XmlWriter]::Create($builder, $settings)
            $document.Save($writer)
            $writer.Close()
            return , @($builder.ToString().Split("`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_.Length -gt 0 })
        }
        catch { }
    }
    return , @($Lines | ForEach-Object { $_.TrimEnd() })
}

function Write-SelfCheckSnapshots {
    # Снимки -> файл: блоки «@@snap <ключ>», строки с «|» в начале, «@@snap-end». Ключи по порядку.
    param($Snapshots, [string]$Path)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($Snapshots.Keys | Sort-Object)) {
        $lines.Add('@@snap ' + $key)
        foreach ($line in @($Snapshots[$key])) { $lines.Add('|' + $line) }
        $lines.Add('@@snap-end')
    }
    [System.IO.File]::WriteAllLines($Path, $lines.ToArray(), $Utf8Bom)
}

function Read-SelfCheckSnapshots {
    # Файл снимков -> таблица «ключ -> строки». Файла нет - таблица пустая.
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $key = $null
    $lines = $null
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($null -eq $line) { continue }
        $clean = $line.TrimStart([char]0xFEFF)
        if ($clean.StartsWith('@@snap ', [System.StringComparison]::Ordinal)) {
            $key = $clean.Substring(7).Trim()
            $lines = New-Object System.Collections.Generic.List[string]
        }
        elseif ($clean -eq '@@snap-end') {
            if ($null -ne $key) { $result[$key] = $lines.ToArray() }
            $key = $null
            $lines = $null
        }
        elseif ($null -ne $lines -and $clean.StartsWith('|', [System.StringComparison]::Ordinal)) {
            $lines.Add($clean.Substring(1))
        }
    }
    return $result
}

#region Обмены: итоги пробной выгрузки «до» и «после»

function Write-ExchangeResults {
    # Итоги выгрузки -> файл «состояние<TAB>узел|объект|УИД<TAB>описание ошибки», ключи по порядку.
    param($Results, [string]$Path)
    $lines = @($Results.Keys | Sort-Object | ForEach-Object { '{0}{1}{2}{1}{3}' -f $Results[$_].State, "`t", $_, $Results[$_].Text })
    [System.IO.File]::WriteAllLines($Path, [string[]]$lines, $Utf8Bom)
}

function Read-ExchangeResults {
    # Файл итогов выгрузки -> таблица «ключ -> State, Text». Файла нет - $null.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $table = [ordered]@{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $parts = $line.TrimStart([char]0xFEFF).Split("`t")
        if ($parts.Count -lt 2 -or -not $parts[1]) { continue }
        $text = ''
        if ($parts.Count -ge 3) { $text = $parts[2] }
        $table[$parts[1]] = [pscustomobject]@{ State = $parts[0]; Text = $text }
    }
    return $table
}

function Write-ExchangeSetFile {
    # Набор объектов прогона «до» для «после»: строки «узел<TAB>полное имя<TAB>УИД» (параметр exch= обработки).
    param($Results, [string]$Path)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($Results.Keys | Sort-Object)) {
        $parts = ([string]$key).Split('|')
        if ($parts.Count -lt 3) { continue }
        $lines.Add(('{0}{1}{2}{1}{3}' -f $parts[0], "`t", $parts[1], $parts[2]))
    }
    [System.IO.File]::WriteAllLines($Path, $lines.ToArray(), $Utf8Bom)
}

function Format-ExchangeKey {
    # «узел|Документ.Х|УИД» -> «узел: Документ.Х <УИД>» для текстов шага.
    param([string]$Key)
    $parts = $Key.Split('|')
    if ($parts.Count -ge 3) { return ('{0}: {1} {2}' -f $parts[0], $parts[1], $parts[2]) }
    return $Key
}

function Compare-ExchangeResults {
    # Итоги выгрузки «до» и «после» по одному набору объектов:
    # Broken - выгрузился до, упал после (комплект сломал обмен); StillBroken - упал и до, и после
    # (обмен сломан ещё до загрузки комплекта); Fixed - упал до, выгрузился после; NewFailed - объекта в «до» нет,
    # после упал; Gone - объект был в «до», после его нет (не выгружался).
    param($Before, $After)
    $broken = New-Object System.Collections.Generic.List[string]
    $still = New-Object System.Collections.Generic.List[string]
    $fixed = New-Object System.Collections.Generic.List[string]
    $newFailed = New-Object System.Collections.Generic.List[string]
    $gone = New-Object System.Collections.Generic.List[string]
    $okAfter = 0
    foreach ($key in @($After.Keys)) {
        $now = $After[$key]
        if ($now.State -eq 'ok') { $okAfter++ }
        $was = $null
        if ($null -ne $Before -and $Before.Contains($key)) { $was = $Before[$key] }
        $label = Format-ExchangeKey $key
        if ($now.State -ne 'ok') { $label += (': ' + $now.Text) }
        if ($null -eq $was) {
            if ($now.State -ne 'ok') { $newFailed.Add($label) }
            continue
        }
        if ($was.State -eq 'ok' -and $now.State -ne 'ok') { $broken.Add($label) }
        elseif ($was.State -ne 'ok' -and $now.State -ne 'ok') { $still.Add($label) }
        elseif ($was.State -ne 'ok' -and $now.State -eq 'ok') { $fixed.Add(((Format-ExchangeKey $key) + ' (было: ' + $was.Text + ')')) }
    }
    if ($null -ne $Before) {
        foreach ($key in @($Before.Keys)) { if (-not $After.Contains($key)) { $gone.Add((Format-ExchangeKey $key)) } }
    }
    return [pscustomobject]@{
        Total = @($After.Keys).Count; OkAfter = $okAfter
        Broken = $broken.ToArray(); StillBroken = $still.ToArray(); Fixed = $fixed.ToArray()
        NewFailed = $newFailed.ToArray(); Gone = $gone.ToArray()
    }
}

function Invoke-ExchangeCompareStep {
    # Шаг «Обмены: до и после». Красный - выгрузка, которая была целой до загрузки комплекта (или в эталоне), упала
    # после, либо упал объект, которого в «до» не было. Жёлтый - обмен сломан ещё до загрузки комплекта: в эталоне
    # это не прячется, строка идёт и в начало report.txt. Починившаяся выгрузка - сведения. Правила обмена изменены
    # (R3), а выгрузок нет - жёлтый: обмен не проверен. Строки для report.txt - в exchange-compare.txt.
    param($After, $BeforeFile, [bool]$WithKit)
    $stepName = 'Обмены: до и после'
    $before = Read-ExchangeResults $BeforeFile
    $changed = @($script:ExchangeRulesChanged)
    if ($After.Count -eq 0) {
        if ($changed.Count -gt 0) {
            $detail = "правила обмена изменены, а обмен не проверен: шаг «Обмены» самопроверки ни одного объекта не выгрузил (нет узлов, нет объектов или запись запрещена - причина в журнале самопроверки). Изменения: {0}" -f ((@($changed | Select-Object -First 3)) -join ' | ')
            [System.IO.File]::WriteAllLines((Join-Path $RunDir 'exchange-compare.txt'), [string[]]@(('ВНИМАНИЕ' + "`t" + $detail)), $Utf8Bom)
            Add-StepResult -Name $stepName -Status 'WARN' -Detail $detail
        }
        return
    }
    $comparison = Compare-ExchangeResults -Before $before -After $After
    $whenBefore = 'до загрузки комплекта'
    if (-not $WithKit) { $whenBefore = 'в эталоне (прошлый принятый прогон)' }
    $parts = New-Object System.Collections.Generic.List[string]
    $reportLines = New-Object System.Collections.Generic.List[string]
    $parts.Add(("выгружено объектов {0}, без ошибок {1}" -f $comparison.Total, $comparison.OkAfter))
    if ($null -eq $before) { $parts.Add('итогов «до» нет: сравнивать не с чем, упавшая выгрузка считается новой') }
    if ($comparison.Broken.Count -gt 0) {
        $text = "выгрузка упала, а {0} проходила: {1}" -f $whenBefore, ((@($comparison.Broken | Select-Object -First 3)) -join ' | ')
        $parts.Add($text); $reportLines.Add(('ОШИБКА' + "`t" + $text))
    }
    if ($comparison.NewFailed.Count -gt 0) {
        $text = "выгрузка упала, объекта {0} не было: {1}" -f $whenBefore, ((@($comparison.NewFailed | Select-Object -First 3)) -join ' | ')
        $parts.Add($text); $reportLines.Add(('ОШИБКА' + "`t" + $text))
    }
    if ($comparison.StillBroken.Count -gt 0) {
        $text = "обмен сломан ещё {0}: {1}" -f $whenBefore, ((@($comparison.StillBroken | Select-Object -First 3)) -join ' | ')
        if ($comparison.StillBroken.Count -gt 3) { $text += (" и ещё {0}" -f ($comparison.StillBroken.Count - 3)) }
        $parts.Add($text); $reportLines.Add(('ВНИМАНИЕ' + "`t" + $text))
    }
    if ($comparison.Fixed.Count -gt 0) {
        $text = "выгрузка починилась: {0}" -f ((@($comparison.Fixed | Select-Object -First 3)) -join ' | ')
        $parts.Add($text); $reportLines.Add(('ИНФО' + "`t" + $text))
    }
    if ($comparison.Gone.Count -gt 0) { $parts.Add(("объектов из «до», которые после не выгружались: {0}" -f $comparison.Gone.Count)) }
    if ($changed.Count -gt 0) { $parts.Add(("правила обмена изменены: {0}" -f ((@($changed | Select-Object -First 3)) -join ' | '))) }
    $status = 'OK'
    if ($comparison.StillBroken.Count -gt 0) { $status = 'WARN' }
    if ($comparison.Broken.Count -gt 0 -or $comparison.NewFailed.Count -gt 0) { $status = 'FAIL' }
    [System.IO.File]::WriteAllLines((Join-Path $RunDir 'exchange-compare.txt'), $reportLines.ToArray(), $Utf8Bom)
    Add-StepResult -Name $stepName -Status $status -Detail ($parts -join '; ') -Log (Join-Path $RunDir 'selfcheck-after.exchange.txt')
}

#endregion

#region Карта покрытия

# Папки выгрузки расширения -> вид объекта метаданных, как он пишется в полном имени (Документ.Х).
$CoverageTypeNames = @{
    Catalogs = 'Справочник'; Documents = 'Документ'; CommonModules = 'ОбщийМодуль'; DataProcessors = 'Обработка'
    Reports = 'Отчет'; InformationRegisters = 'РегистрСведений'; AccumulationRegisters = 'РегистрНакопления'
    AccountingRegisters = 'РегистрБухгалтерии'; CalculationRegisters = 'РегистрРасчета'; Enums = 'Перечисление'
    CommonForms = 'ОбщаяФорма'; Constants = 'Константа'; ChartsOfCharacteristicTypes = 'ПланВидовХарактеристик'
    ChartsOfAccounts = 'ПланСчетов'; ExchangePlans = 'ПланОбмена'; BusinessProcesses = 'БизнесПроцесс'; Tasks = 'Задача'
    DocumentJournals = 'ЖурналДокументов'; CommonCommands = 'ОбщаяКоманда'; HTTPServices = 'HTTPСервис'; WebServices = 'WebСервис'
}
# Тип источника подписки (DocumentObject.Х) -> вид объекта.
$CoverageSourceTypes = @{
    DocumentObject = 'Документ'; CatalogObject = 'Справочник'; InformationRegisterRecordSet = 'РегистрСведений'
    AccumulationRegisterRecordSet = 'РегистрНакопления'; AccountingRegisterRecordSet = 'РегистрБухгалтерии'
    ChartOfCharacteristicTypesObject = 'ПланВидовХарактеристик'; ExchangePlanObject = 'ПланОбмена'
    BusinessProcessObject = 'БизнесПроцесс'; TaskObject = 'Задача'; DocumentManager = 'Документ'; CatalogManager = 'Справочник'
}
$CoverageObjectRegex = New-Object System.Text.RegularExpressions.Regex('(Документ|Справочник|РегистрСведений|РегистрНакопления|РегистрБухгалтерии|ПланВидовХарактеристик|ПланОбмена|БизнесПроцесс|Задача|Обработка|Отчет)\.[\wА-Яа-яЁё]+')

function Get-CoverageItems {
    # Что добавило расширение - по его выгрузке в файлы. Элемент: Key (для сравнения прогонов), Kind, Text,
    # Objects (объекты метаданных, через которые его можно задеть), Module (общий модуль: только компиляция).
    # Перехваты методов (&Перед, &После, &Вместо, &ИзменениеИКонтроль) - по тексту модулей; формы - модуль формы;
    # подписки на события и регламентные задания - по описанию; свои (не заимствованные) документы и справочники.
    param([string]$Dir, [string]$Extension)
    $items = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Dir)) { return , $items.ToArray() }
    $prefixLength = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\', '/').Length + 1
    $annotationRegex = New-Object System.Text.RegularExpressions.Regex('^\s*&(Перед|После|Вместо|ИзменениеИКонтроль)\s*\(\s*"([^"]+)"')
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Recurse -File)) {
        $relative = $file.FullName.Substring($prefixLength).Replace('\', '/')
        $parts = $relative.Split('/')
        if ($parts.Count -lt 2 -or -not $CoverageTypeNames.ContainsKey($parts[0])) { continue }
        $typeName = $CoverageTypeNames[$parts[0]]
        $name = $parts[1]
        if ($name.EndsWith('.xml')) { $name = $name.Substring(0, $name.Length - 4) }
        $object = '{0}.{1}' -f $typeName, $name
        $rest = ''
        if ($parts.Count -gt 2) { $rest = ($parts[2..($parts.Count - 1)] -join '/') }

        if ($relative.EndsWith('.bsl')) {
            $part = $rest
            $formName = ''
            if ($rest -eq 'Ext/ObjectModule.bsl') { $part = 'модуль объекта' }
            elseif ($rest -eq 'Ext/ManagerModule.bsl') { $part = 'модуль менеджера' }
            elseif ($rest -eq 'Ext/RecordSetModule.bsl') { $part = 'модуль набора записей' }
            elseif ($rest -eq 'Ext/Module.bsl') { $part = 'модуль' }
            elseif ($rest -match '^Forms/([^/]+)/Ext/Form/Module\.bsl$') { $formName = $Matches[1]; $part = 'форма ' + $formName }
            elseif ($rest -match '^Ext/Form/Module\.bsl$') { $formName = $name; $part = 'форма' }
            $module = ''
            if ($typeName -eq 'ОбщийМодуль') { $module = $name }
            $lines = @([System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8))
            $intercepts = 0
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $found = $annotationRegex.Match($lines[$i])
                if (-not $found.Success) { continue }
                $intercepts++
                $items.Add([pscustomobject]@{
                        Key = ('перехват|{0}|{1}|{2}|{3}' -f $Extension, $object, $part, $found.Groups[2].Value)
                        Kind = 'перехват'; Text = ('{0}, {1}: &{2}("{3}")' -f $object, $part, $found.Groups[1].Value, $found.Groups[2].Value)
                        Objects = @($object); Module = $module
                        ExchangeRule = (Test-ExchangeRuleMethod -Module $name -Target $found.Groups[2].Value -TypeName $typeName)
                    })
            }
            if ($formName -and $intercepts -eq 0) {
                # Модуль формы без перехватов: свои обработчики событий формы.
                $items.Add([pscustomobject]@{
                        Key = ('форма|{0}|{1}|{2}' -f $Extension, $object, $formName); Kind = 'форма'
                        Text = ('{0}, {1}: свои обработчики' -f $object, $part); Objects = @($object); Module = ''
                    })
            }
            continue
        }
        if ($rest -ne '') { continue }
        # Файл описания объекта (<Вид>/<Имя>.xml).
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        if ($parts[0] -eq 'Documents' -or $parts[0] -eq 'Catalogs' -or $parts[0] -like '*Registers') {
            if ($text -notmatch '<ObjectBelonging>\s*Adopted\s*</ObjectBelonging>') {
                $items.Add([pscustomobject]@{
                        Key = ('объект|{0}|{1}' -f $Extension, $object); Kind = 'объект'
                        Text = ('{0}: новый объект расширения' -f $object); Objects = @($object); Module = ''
                    })
            }
        }
    }
    # Подписки на события и регламентные задания: в выгрузке это EventSubscriptions/<Имя>.xml и ScheduledJobs/<Имя>.xml.
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Dir 'EventSubscriptions') -Filter '*.xml' -File -ErrorAction SilentlyContinue)) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $sources = New-Object System.Collections.Generic.List[string]
        foreach ($match in [regex]::Matches($text, '<v8:Type>\s*(?:cfg:)?(\w+)\.([\wА-Яа-яЁё]+)\s*</v8:Type>')) {
            $kind = $match.Groups[1].Value
            if ($CoverageSourceTypes.ContainsKey($kind)) { $sources.Add(('{0}.{1}' -f $CoverageSourceTypes[$kind], $match.Groups[2].Value)) }
        }
        $handler = [regex]::Match($text, '<Handler>\s*([^<]+?)\s*</Handler>').Groups[1].Value
        $subscription = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $sourceText = 'источники: все объекты'
        if ($sources.Count -gt 0) { $sourceText = 'источники: ' + (@($sources | Select-Object -First 5) -join ', ') }
        $items.Add([pscustomobject]@{
                Key = ('подписка|{0}|{1}' -f $Extension, $subscription); Kind = 'подписка'
                Text = ('Подписка {0} -> {1}, {2}' -f $subscription, $handler, $sourceText); Objects = $sources.ToArray(); Module = ''
            })
    }
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Dir 'ScheduledJobs') -Filter '*.xml' -File -ErrorAction SilentlyContinue)) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $method = [regex]::Match($text, '<MethodName>\s*([^<]+?)\s*</MethodName>').Groups[1].Value
        $job = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $items.Add([pscustomobject]@{
                Key = ('регламентное|{0}|{1}' -f $Extension, $job); Kind = 'регламентное'
                Text = ('Регламентное задание {0} -> {1}: самопроверка регламентные задания не выполняет' -f $job, $method); Objects = @(); Module = ''
            })
    }
    return , $items.ToArray()
}

function Measure-Coverage {
    # Чем задета каждая доработка в самопроверке. Уровни: covered - объект побывал в задании самопроверки, кроме
    # компиляции (операции, перепроведение, формы, обмены...); compiled - общий модуль только компилируется;
    # none - ничем не задета. Records - записи самопроверки «[ВИД] ключ :: текст».
    # Перехват правил обмена (ExchangeRule) задет, только если шаг «Обмены» что-то выгрузил: ExchangeRan.
    param([object[]]$Items, [string[]]$Records, [bool]$ExchangeRan = $false)
    $exercised = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $compiled = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $Records) {
        $keyMatch = [regex]::Match($record, '^\[[^\]]+\] (.*?) :: ')
        $key = $keyMatch.Groups[1].Value
        if ($key.StartsWith('КомпиляцияМодулей|')) {
            foreach ($piece in $key.Split('|')) { if ($piece) { [void]$compiled.Add($piece) } }
            foreach ($match in $CoverageObjectRegex.Matches($record)) { [void]$compiled.Add($match.Value) }
            continue
        }
        foreach ($match in $CoverageObjectRegex.Matches($record)) { [void]$exercised.Add($match.Value) }
    }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Items) {
        $level = 'none'
        $isExchangeRule = ($null -ne $item.PSObject.Properties['ExchangeRule'] -and [bool]$item.ExchangeRule)
        if ($isExchangeRule -and $ExchangeRan) { $level = 'covered' }
        foreach ($object in @($item.Objects)) { if ($level -eq 'none' -and -not $isExchangeRule -and $exercised.Contains([string]$object)) { $level = 'covered'; break } }
        if ($level -eq 'none' -and $item.Module -and $compiled.Contains([string]$item.Module)) { $level = 'compiled' }
        if ($level -eq 'none') { foreach ($object in @($item.Objects)) { if ($compiled.Contains([string]$object)) { $level = 'compiled'; break } } }
        $result.Add([pscustomobject]@{ Key = $item.Key; Kind = $item.Kind; Text = $item.Text; Level = $level })
    }
    return , $result.ToArray()
}

function Read-CoverageFile {
    # Карта покрытия из файла «уровень<TAB>ключ<TAB>текст» -> таблица «ключ -> уровень». Файла нет - $null.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $table = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $parts = $line.TrimStart([char]0xFEFF).Split("`t")
        if ($parts.Count -ge 2) { $table[$parts[1]] = $parts[0] }
    }
    return $table
}

function Write-CoverageFile {
    param([object[]]$Items, [string]$Path)
    $lines = @($Items | Sort-Object Key | ForEach-Object { '{0}{1}{2}{1}{3}' -f $_.Level, "`t", $_.Key, $_.Text })
    [System.IO.File]::WriteAllLines($Path, [string[]]$lines, $Utf8Bom)
}

function Invoke-ExtensionDumps {
    # Расширения из Extensions выгружаются в файлы: постоянная папка baseline\<база>\dump, повторно - только изменения
    # (-update). Выгрузку берут карта покрытия и проверка правил обмена. Итог: Dirs - расширение -> папка
    # (только выгрузившиеся), Problems - что не выгрузилось. Расширения, которого в базе нет, просто нет в Dirs.
    $dumpRoot = Join-Path $baselineDir 'dump'
    $dirs = [ordered]@{}
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($extension in $knownExtensions) {
        $extension = [string]$extension
        $dir = Join-Path $dumpRoot $extension
        $hasDump = Test-Path -LiteralPath (Join-Path $dir 'ConfigDumpInfo.xml')
        $command = @('/DumpConfigToFiles', ('"{0}"' -f $dir), '-Extension', $extension)
        if ($hasDump) { $command += '-update' } else { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $result = Invoke-Designer -Command $command -LogName ("dump_{0}.log" -f $extension) -TimeoutSec $timeoutLoadSec -Title ("Выгрузить {0} в файлы" -f $extension)
        if ($result.ExitCode -ne 0 -and $hasDump -and -not $result.TimedOut) {
            # Выгрузка с -update бывает недовольна прежней: заново целиком.
            Remove-Item -LiteralPath $dir -Recurse -Force
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $result = Invoke-Designer -Command @('/DumpConfigToFiles', ('"{0}"' -f $dir), '-Extension', $extension) `
                -LogName ("dump_{0}_full.log" -f $extension) -TimeoutSec $timeoutLoadSec -Title ("Выгрузить {0} в файлы целиком" -f $extension)
        }
        if ($result.ExitCode -ne 0) {
            $logText = (@($result.Lines | Where-Object { $_ }) -join ' ')
            if ($logText -match 'не найден') { continue }
            $problems.Add(("{0} не выгрузилось: {1}" -f $extension, $logText))
            continue
        }
        $dirs[$extension] = $dir
    }
    return [pscustomobject]@{ Dirs = $dirs; Problems = $problems.ToArray() }
}

function Invoke-CoverageStep {
    # Шаг «Карта покрытия»: из выгрузки расширений (Invoke-ExtensionDumps) - что они добавили, против записей
    # самопроверки - чем это задето. Новое непокрытое (его не было в эталоне карты или там оно было покрыто) - жёлтое.
    # Эталон карты двигается сам, когда нового непокрытого нет, или ключом -AcceptBaseline.
    # Перехваты правил обмена считаются покрытыми шагом «Обмены», только если он что-то выгрузил (ExchangeRan).
    param([string[]]$Records, [bool]$ExchangeRan = $false)
    $stepName = 'Карта покрытия'
    $allItems = New-Object System.Collections.Generic.List[object]
    $problems = New-Object System.Collections.Generic.List[string]
    if ($null -eq $script:ExtensionDumps) { $script:ExtensionDumps = Invoke-ExtensionDumps }
    foreach ($problem in @($script:ExtensionDumps.Problems)) { $problems.Add($problem) }
    foreach ($extension in @($script:ExtensionDumps.Dirs.Keys)) {
        foreach ($item in (Get-CoverageItems -Dir $script:ExtensionDumps.Dirs[$extension] -Extension $extension)) { $allItems.Add($item) }
    }
    $measured = Measure-Coverage -Items $allItems.ToArray() -Records $Records -ExchangeRan $ExchangeRan
    $coverageFile = Join-Path $RunDir 'coverage.txt'
    Write-CoverageFile -Items $measured -Path $coverageFile
    $reference = Read-CoverageFile $coverageReferenceFile
    $newUncovered = New-Object System.Collections.Generic.List[object]
    if ($null -ne $reference) {
        foreach ($item in $measured) {
            if ($item.Level -eq 'covered') { continue }
            if (-not $reference.ContainsKey($item.Key) -or $reference[$item.Key] -eq 'covered') { $newUncovered.Add($item) }
        }
    }
    [System.IO.File]::WriteAllLines((Join-Path $RunDir 'coverage.new.txt'), [string[]]@($newUncovered | ForEach-Object { '{0}{1}{2}{1}{3}' -f $_.Level, "`t", $_.Key, $_.Text }), $Utf8Bom)

    $covered = @($measured | Where-Object { $_.Level -eq 'covered' }).Count
    $compiledOnly = @($measured | Where-Object { $_.Level -eq 'compiled' }).Count
    $none = @($measured | Where-Object { $_.Level -eq 'none' }).Count
    $detail = "доработок {0}: проверяется {1}, только компиляция {2}, не покрыто {3}" -f $measured.Count, $covered, $compiledOnly, $none
    if ($null -eq $reference) { $detail += '; эталона карты ещё нет, этот прогон станет им' }
    else { $detail += ("; нового непокрытого {0}" -f $newUncovered.Count) }
    if ($newUncovered.Count -gt 0) { $detail += ('. Новое непокрытое: ' + (@($newUncovered | Select-Object -First 3 | ForEach-Object { $_.Text }) -join ' | ')) }
    $detail += '; карта - coverage.txt'
    if ($problems.Count -gt 0) { $detail += ('. ' + ($problems -join ' | ')) }

    $status = 'OK'
    if ($newUncovered.Count -gt 0 -or $problems.Count -gt 0) { $status = 'WARN' }
    if ($status -eq 'OK') { Copy-Item -LiteralPath $coverageFile -Destination $coverageReferenceFile -Force }
    Add-StepResult -Name $stepName -Status $status -Detail $detail -Log $coverageFile
}

#endregion

#region Правила обмена: проверка по выгрузке расширений, без 1С

# Методы правил обмена: конвертация объектов (ПКО), обработка данных (ПОД) и их заполнение в менеджере обмена.
$ExchangeRuleTargetRegex = New-Object System.Text.RegularExpressions.Regex('^(ДобавитьПКО_|ПКО_|ДобавитьПОД_|ПОД_)|^(ЗаполнитьПравилаКонвертацииОбъектов|ЗаполнитьПравилаОбработкиДанных)$')
$BslAnnotationRegex = New-Object System.Text.RegularExpressions.Regex('^\s*&(Перед|После|Вместо|ИзменениеИКонтроль)\s*\(\s*"([^"]+)"')
$BslMethodRegex = New-Object System.Text.RegularExpressions.Regex('^\s*(?:Асинх\s+)?(Процедура|Функция)\s+([\wА-Яа-яЁё]+)\s*\(', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$BslMethodEndRegex = New-Object System.Text.RegularExpressions.Regex('^\s*(КонецПроцедуры|КонецФункции)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$BslMarkRegex = New-Object System.Text.RegularExpressions.Regex('//.*[А-Яа-яЁёA-Za-z]{2,}.*(\b\d{8}\b|\b\d{1,2}\.\d{1,2}\.\d{2,4}\b)|//.*(\b\d{8}\b|\b\d{1,2}\.\d{1,2}\.\d{2,4}\b).*[А-Яа-яЁёA-Za-z]{2,}')

function Test-ExchangeRuleMethod {
    # Перехват относится к правилам обмена: метод ПКО/ПОД или их заполнения, любой перехват в менеджере обмена
    # через универсальный формат и в ОбменДаннымиXDTOСервер.
    param([string]$Module, [string]$Target, [string]$TypeName = 'ОбщийМодуль')
    if ($ExchangeRuleTargetRegex.IsMatch($Target)) { return $true }
    if ($TypeName -eq 'ОбщийМодуль' -and ($Module -like 'МенеджерОбменаЧерезУниверсальныйФормат*' -or $Module -eq 'ОбменДаннымиXDTOСервер')) { return $true }
    return $false
}

function ConvertTo-BslCodeLines {
    # Строки модуля без комментариев: «//» вне строковых литералов и всё после. Литералы остаются, многострочные
    # литералы («|» в начале строки) учитываются.
    param([string[]]$Lines)
    $result = New-Object System.Collections.Generic.List[string]
    $inString = $false
    foreach ($line in $Lines) {
        if ($null -eq $line) { $result.Add(''); continue }
        $builder = New-Object System.Text.StringBuilder
        $index = 0
        $length = $line.Length
        while ($index -lt $length) {
            $char = $line[$index]
            if ($inString) {
                [void]$builder.Append($char)
                if ($char -eq '"') { $inString = $false }
                $index++
                continue
            }
            if ($char -eq '"') { $inString = $true; [void]$builder.Append($char); $index++; continue }
            if ($char -eq '/' -and $index + 1 -lt $length -and $line[$index + 1] -eq '/') { break }
            [void]$builder.Append($char)
            $index++
        }
        $result.Add($builder.ToString())
    }
    return , $result.ToArray()
}

function Get-BslMethods {
    # Методы модуля: имя, перехват (вид и метод), первая и последняя строка (с 1), признак строк в #Удаление.
    param([string[]]$Lines)
    $methods = New-Object System.Collections.Generic.List[object]
    $annotationKind = ''
    $annotationTarget = ''
    $annotationLine = 0
    $current = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($null -eq $current) {
            $found = $BslAnnotationRegex.Match($line)
            if ($found.Success) { $annotationKind = $found.Groups[1].Value; $annotationTarget = $found.Groups[2].Value; $annotationLine = $i + 1; continue }
            $declaration = $BslMethodRegex.Match($line)
            if ($declaration.Success) {
                $current = [pscustomobject]@{
                    Name = $declaration.Groups[2].Value; Kind = $annotationKind; Target = $annotationTarget
                    AnnotationLine = $annotationLine; Start = $i + 1; End = $Lines.Count
                }
                $annotationKind = ''; $annotationTarget = ''; $annotationLine = 0
                continue
            }
            $trimmed = $line.Trim()
            # Директивы компиляции и пустые строки между аннотацией и объявлением аннотацию не сбрасывают.
            if ($trimmed -ne '' -and -not $trimmed.StartsWith('&') -and -not $trimmed.StartsWith('//')) { $annotationKind = ''; $annotationTarget = ''; $annotationLine = 0 }
            continue
        }
        if ($BslMethodEndRegex.IsMatch($line)) { $current.End = $i + 1; $methods.Add($current); $current = $null }
    }
    if ($null -ne $current) { $methods.Add($current) }
    return , $methods.ToArray()
}

function Get-BslDeletedLines {
    # Номера строк (с 1) внутри #Удаление ... #КонецУдаления: этого кода в перехвате нет.
    param([string[]]$Lines)
    $deleted = New-Object 'System.Collections.Generic.HashSet[int]'
    $inDeletion = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $trimmed = ([string]$Lines[$i]).Trim()
        if ($trimmed -match '^#Удаление\b') { $inDeletion = $true; [void]$deleted.Add($i + 1); continue }
        if ($trimmed -match '^#КонецУдаления\b') { $inDeletion = $false; [void]$deleted.Add($i + 1); continue }
        if ($inDeletion) { [void]$deleted.Add($i + 1) }
    }
    return , $deleted
}

function Get-BslInsertedLines {
    # Номера строк (с 1) внутри #Вставка ... #КонецВставки.
    param([string[]]$Lines)
    $inserted = New-Object 'System.Collections.Generic.HashSet[int]'
    $inInsertion = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $trimmed = ([string]$Lines[$i]).Trim()
        if ($trimmed -match '^#Вставка\b') { $inInsertion = $true; continue }
        if ($trimmed -match '^#КонецВставки\b') { $inInsertion = $false; continue }
        if ($inInsertion) { [void]$inserted.Add($i + 1) }
    }
    return , $inserted
}

function Get-BslCalls {
    # Вызовы метода (ДобавитьПКС и т.п.) в строках кода без комментариев: строка вызова и аргументы верхнего
    # уровня как текст. FromLine, ToLine - диапазон строк (с 1).
    param([string[]]$CodeLines, [string]$MethodName, [int]$FromLine, [int]$ToLine)
    $calls = New-Object System.Collections.Generic.List[object]
    $callRegex = New-Object System.Text.RegularExpressions.Regex(('(?<![\wА-Яа-яЁё.])' + [regex]::Escape($MethodName) + '\s*\('))
    $lineStarts = New-Object System.Collections.Generic.List[int]
    $builder = New-Object System.Text.StringBuilder
    for ($i = $FromLine; $i -le $ToLine -and $i -le $CodeLines.Count; $i++) {
        $lineStarts.Add($builder.Length)
        [void]$builder.Append($CodeLines[$i - 1]).Append("`n")
    }
    $text = $builder.ToString()
    foreach ($match in $callRegex.Matches($text)) {
        $position = $match.Index + $match.Length
        $depth = 1
        $inString = $false
        $arguments = New-Object System.Collections.Generic.List[string]
        $argument = New-Object System.Text.StringBuilder
        while ($position -lt $text.Length -and $depth -gt 0) {
            $char = $text[$position]
            if ($inString) {
                if ($char -eq '"') { $inString = $false }
                [void]$argument.Append($char)
            }
            elseif ($char -eq '"') { $inString = $true; [void]$argument.Append($char) }
            elseif ($char -eq '(') { $depth++; [void]$argument.Append($char) }
            elseif ($char -eq ')') {
                $depth--
                if ($depth -gt 0) { [void]$argument.Append($char) }
            }
            elseif ($char -eq ',' -and $depth -eq 1) { $arguments.Add($argument.ToString()); $argument = New-Object System.Text.StringBuilder }
            elseif ($char -eq "`n") { [void]$argument.Append(' ') }
            else { [void]$argument.Append($char) }
            $position++
        }
        $arguments.Add($argument.ToString())
        # Строка вызова: последняя начавшаяся до позиции совпадения.
        $lineIndex = 0
        for ($k = 0; $k -lt $lineStarts.Count; $k++) { if ($lineStarts[$k] -le $match.Index) { $lineIndex = $k } else { break } }
        $calls.Add([pscustomobject]@{ Line = $FromLine + $lineIndex; Arguments = @($arguments | ForEach-Object { $_.Trim() }) })
    }
    return , $calls.ToArray()
}

function Get-BslLiteral {
    # Текст аргумента -> значение строкового литерала; не литерал - $null.
    param([string]$Argument)
    $value = $Argument.Trim()
    if ($value -match '^"((?:[^"]|"")*)"$') { return $Matches[1].Replace('""', '"') }
    return $null
}

function Get-ExchangeRuleModules {
    # Модули выгрузок расширений, которые нужно разобрать: где есть перехваты или ДобавитьПКС/ДобавитьПКТЧ.
    # Заодно все перехваты всех модулей (для исключений R1: есть ли перехват, который гарантирует ключ).
    param($Dumps)
    $modules = New-Object System.Collections.Generic.List[object]
    $intercepts = New-Object System.Collections.Generic.List[object]
    foreach ($extension in @($Dumps.Dirs.Keys)) {
        $dir = [string]$Dumps.Dirs[$extension]
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $prefixLength = (Resolve-Path -LiteralPath $dir).ProviderPath.TrimEnd('\', '/').Length + 1
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.bsl')) {
            $relative = $file.FullName.Substring($prefixLength).Replace('\', '/')
            $parts = $relative.Split('/')
            if ($parts.Count -lt 2 -or -not $CoverageTypeNames.ContainsKey($parts[0])) { continue }
            $typeName = $CoverageTypeNames[$parts[0]]
            $name = $parts[1]
            $lines = @([System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8))
            $hasInterest = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $found = $BslAnnotationRegex.Match($lines[$i])
                if ($found.Success) {
                    $intercepts.Add([pscustomobject]@{ Extension = $extension; Object = ('{0}.{1}' -f $typeName, $name); Target = $found.Groups[2].Value })
                    if (Test-ExchangeRuleMethod -Module $name -Target $found.Groups[2].Value -TypeName $typeName) { $hasInterest = $true }
                }
                elseif (-not $hasInterest -and ($lines[$i].Contains('ДобавитьПКС') -or $lines[$i].Contains('ДобавитьПКТЧ') -or $lines[$i].Contains('ПриОтправкеДанных'))) { $hasInterest = $true }
            }
            $isContractor = (@($contractorExtensions | Where-Object { [string]$_ -eq $extension }).Count -gt 0)
            if (-not $hasInterest -and -not $isContractor) { continue }
            $modules.Add([pscustomobject]@{
                    Extension = $extension; TypeName = $typeName; Name = $name; Object = ('{0}.{1}' -f $typeName, $name)
                    Part = $relative; Lines = $lines; Interest = $hasInterest; Contractor = $isContractor
                })
        }
    }
    return [pscustomobject]@{ Modules = $modules.ToArray(); Intercepts = $intercepts.ToArray() }
}

function Get-ExchangeRuleFindings {
    # Правила R1-R4 по выгрузкам расширений. Замечание: Rule, Level (ОШИБКА, ВНИМАНИЕ, ИНФО), Key (без номеров
    # строк - для эталона), Text. State - перехваты правил обмена: ключ -> хеш тела и текст (для R3).
    param($Dumps, [object[]]$Exceptions)
    $parsed = Get-ExchangeRuleModules $Dumps
    $findings = New-Object System.Collections.Generic.List[object]
    $state = [ordered]@{}
    $handlers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $structureRegex = New-Object System.Text.RegularExpressions.Regex('ОбъектДанных\s*=\s*Неопределено(?![\wА-Яа-яЁё])')
    $byNameRegex = New-Object System.Text.RegularExpressions.Regex('ИзСтруктуры|Из_Структуры')
    $ruleNameRegex = New-Object System.Text.RegularExpressions.Regex('ИмяПКО\s*=\s*"([^"]+)"')
    $handlerRegex = New-Object System.Text.RegularExpressions.Regex('ПриОтправкеДанных\s*=\s*"([^"]+)"')
    # Начало участка правила в методе заполнения: правило добавляют в таблицу правил или находят в ней.
    $segmentStartRegex = New-Object System.Text.RegularExpressions.Regex('Правила[\wА-Яа-яЁё]*\s*\.\s*(Добавить|Найти)\s*\(', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    # Имя правила участка: ИмяПКО = "..." или Найти("...", ...).
    $segmentRuleRegex = New-Object System.Text.RegularExpressions.Regex('(?:ИмяПКО\s*=\s*|Найти\s*\(\s*)"([^"]+)"')
    # Источник - объект метаданных: у такого правила структуры нет.
    $objectSourceRegex = New-Object System.Text.RegularExpressions.Regex('ОбъектДанных\s*=\s*Метаданные')

    foreach ($module in $parsed.Modules) {
        if (-not $module.Interest) { continue }
        $code = ConvertTo-BslCodeLines $module.Lines
        $deleted = Get-BslDeletedLines $module.Lines
        foreach ($method in (Get-BslMethods $module.Lines)) {
            # Свои функции правил (ДобавитьПКО_... без перехвата) тоже разбираются: правило со структурой может быть
            # и новым, но признак структуры у них - только ОбъектДанных = Неопределено.
            $ownRule = (-not $method.Target -and $method.Name -match 'ДобавитьПКО_')
            if (-not $method.Target -and -not $ownRule) { continue }
            if ($method.Target -and -not (Test-ExchangeRuleMethod -Module $module.Name -Target $method.Target -TypeName $module.TypeName)) { continue }
            $place = '{0}, {1}, {2}' -f $module.Extension, $module.Object, $method.Name
            if ($method.Target) {
                $place = '{0}, {1}, {2} (&{3}("{4}"))' -f $module.Extension, $module.Object, $method.Name, $method.Kind, $method.Target
                # R3: состояние перехвата - хеш тела.
                $bodyLines = @($module.Lines[($method.AnnotationLine - 1)..($method.End - 1)] | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
                $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($bodyLines -join "`n")))
                $state[('{0}|{1}|{2}|{3}' -f $module.Extension, $module.Object, $method.Kind, $method.Target)] = [pscustomobject]@{
                    Hash = ([System.BitConverter]::ToString($hashBytes).Replace('-', '')); Text = $place
                }
            }
            if ($method.Kind -eq 'Перед') { continue }

            $liveText = (@($method.Start..$method.End | Where-Object { -not $deleted.Contains($_) } | ForEach-Object { $code[$_ - 1] })) -join "`n"
            $isStructureMethod = $structureRegex.IsMatch($liveText) -or ($method.Target -and $byNameRegex.IsMatch($method.Target))
            if ($isStructureMethod) { foreach ($handlerMatch in $handlerRegex.Matches($liveText)) { [void]$handlers.Add($handlerMatch.Groups[1].Value) } }

            # Участки правил: метод одного правила (ДобавитьПКО_..., ИзменениеИКонтроль) - одним участком; в остальных
            # (заполнение правил и т.п.) участок начинается там, где правило добавляют или находят в таблице правил.
            $segments = New-Object System.Collections.Generic.List[object]
            $singleRule = ($ownRule -or $method.Kind -eq 'ИзменениеИКонтроль' -or $method.Target.StartsWith('ДобавитьПКО_'))
            if ($singleRule) {
                $ruleName = ''
                $ruleMatch = $ruleNameRegex.Match($liveText)
                if ($ruleMatch.Success) { $ruleName = $ruleMatch.Groups[1].Value }
                elseif ($method.Target.StartsWith('ДобавитьПКО_')) { $ruleName = $method.Target.Substring(12) }
                elseif ($ownRule) { $ruleName = $method.Name }
                $isStructure = $structureRegex.IsMatch($liveText)
                $byName = $false
                if (-not $isStructure -and $method.Kind -ne 'ИзменениеИКонтроль' -and $method.Target -and $byNameRegex.IsMatch($method.Target)) { $isStructure = $true; $byName = $true }
                $segments.Add([pscustomobject]@{ From = $method.Start; To = $method.End; Rule = $ruleName; Structure = $isStructure; ByName = $byName })
            }
            else {
                $starts = New-Object System.Collections.Generic.List[int]
                for ($n = $method.Start; $n -le $method.End; $n++) {
                    if ($deleted.Contains($n)) { continue }
                    if ($segmentStartRegex.IsMatch($code[$n - 1])) { $starts.Add($n) }
                }
                for ($s = 0; $s -lt $starts.Count; $s++) {
                    $from = $starts[$s]
                    $to = $method.End
                    if ($s + 1 -lt $starts.Count) { $to = $starts[$s + 1] - 1 }
                    $segmentText = (@($from..$to | Where-Object { -not $deleted.Contains($_) } | ForEach-Object { $code[$_ - 1] })) -join "`n"
                    $isStructure = $structureRegex.IsMatch($segmentText)
                    $byName = $false
                    $ruleName = ''
                    $named = $segmentRuleRegex.Match($segmentText)
                    if ($named.Success) { $ruleName = $named.Groups[1].Value }
                    if (-not $isStructure -and $named.Success -and $byNameRegex.IsMatch($ruleName) -and -not $objectSourceRegex.IsMatch($segmentText)) { $isStructure = $true; $byName = $true }
                    $segments.Add([pscustomobject]@{ From = $from; To = $to; Rule = $ruleName; Structure = $isStructure; ByName = $byName })
                }
            }

            foreach ($segment in $segments) {
            if (-not $segment.Structure) { continue }
            $ruleName = $segment.Rule
            $byName = $segment.ByName
            foreach ($callName in @('ДобавитьПКС', 'ДобавитьПКТЧ')) {
                foreach ($call in (Get-BslCalls -CodeLines $code -MethodName $callName -FromLine $segment.From -ToLine $segment.To)) {
                    if ($deleted.Contains($call.Line)) { continue }
                    if ($call.Arguments.Count -lt 2) { continue }
                    $second = [string]$call.Arguments[1]
                    $formatProperty = ''
                    if ($call.Arguments.Count -ge 3) {
                        $formatLiteral = Get-BslLiteral ([string]$call.Arguments[2])
                        if ($null -ne $formatLiteral) { $formatProperty = $formatLiteral } else { $formatProperty = [string]$call.Arguments[2] }
                    }
                    $literal = Get-BslLiteral $second
                    if ($second -eq '' -or ($null -ne $literal -and $literal -eq '')) { continue }
                    $how = ''
                    if ($byName) { $how = ' Правило со структурой определено по имени.' }
                    $why = ('{0} собирает источник структурой, ВыгрузитьСвойство прочитает ДанныеИБ[свойство] и упадёт, если в структуре нет такого ключа; в типовой так не делает ни одно правило со структурой. Исправить: пустое свойство конфигурации, значение - ключом структуры с именем свойства формата.' -f ('правило ' + $ruleName))
                    if ($null -eq $literal) {
                        $findings.Add([pscustomobject]@{
                                Rule = 'R1'; Level = 'ВНИМАНИЕ'
                                Key = ('R1|{0}|{1}|{2}|{3}|{4}' -f $module.Extension, $module.Object, $method.Name, $callName, $second)
                                Text = ('R1 {0}, строка {1}: {2} со свойством конфигурации из выражения «{3}» (формат «{4}»): проверь, что оно пустое. {5}{6}' -f $place, $call.Line, $callName, $second, $formatProperty, $why, $how)
                            })
                        continue
                    }
                    $text = ('R1 {0}, строка {1}: {2} задаёт свойство конфигурации «{3}» (свойство формата «{4}»), а {5}{6}' -f $place, $call.Line, $callName, $literal, $formatProperty, $why, $how)
                    $level = 'ОШИБКА'
                    foreach ($exception in $Exceptions) {
                        $exRule = [string](Get-Setting $exception 'Rule' '')
                        $exProperty = [string](Get-Setting $exception 'Property' '')
                        if ($exRule -ne $ruleName -or $exProperty -ne $literal) { continue }
                        # Перехватов-гарантий может быть несколько (структуру собирают разные функции): нужны все.
                        $guardExtension = [string](Get-Setting $exception 'GuardExtension' '')
                        $guardMethods = @(Get-Setting $exception 'GuardMethod' @() | Where-Object { $_ } | ForEach-Object { [string]$_ })
                        $reason = [string](Get-Setting $exception 'Reason' '')
                        $missing = @($guardMethods | Where-Object { $method0 = $_; @($parsed.Intercepts | Where-Object { $_.Extension -eq $guardExtension -and $_.Target -eq $method0 }).Count -eq 0 })
                        if ($guardMethods.Count -gt 0 -and $missing.Count -eq 0) {
                            $level = 'ИНФО'
                            $text = ('R1 {0}, строка {1}: {2} «{3}» снято исключением: {4}. Ключ в структуре гарантирует перехват {5} / {6}.' -f $place, $call.Line, $callName, $literal, $reason, $guardExtension, ($guardMethods -join ', '))
                        }
                        else {
                            $text += (' Исключение площадки для этого правила есть, но перехвата {0} / {1} в выгрузке нет: оно не действует.' -f $guardExtension, $(if ($guardMethods.Count -eq 0) { '(в исключении не указан GuardMethod)' } else { $missing -join ', ' }))
                        }
                    }
                    $findings.Add([pscustomobject]@{
                            Rule = 'R1'; Level = $level
                            Key = ('R1|{0}|{1}|{2}|{3}|{4}' -f $module.Extension, $module.Object, $method.Name, $callName, $literal)
                            Text = $text
                        })
                }
            }
            }
        }
    }

    # R2: обработчики ПриОтправкеДанных правил со структурой обращаются к ДанныеИБ без Свойство().
    $fieldRegex = New-Object System.Text.RegularExpressions.Regex('ДанныеИБ\s*(\.\s*([\wА-Яа-яЁё]+)|\[)')
    foreach ($module in $parsed.Modules) {
        if (-not $module.Interest) { continue }
        $code = $null
        foreach ($method in (Get-BslMethods $module.Lines)) {
            $handlerName = $method.Name
            if ($method.Target) { $handlerName = $method.Target }
            $isHandler = $handlers.Contains($handlerName) -or ($handlerName -match '(ИзСтруктуры|Из_Структуры).*ПриОтправкеДанных$')
            if (-not $isHandler) { continue }
            if ($null -eq $code) { $code = ConvertTo-BslCodeLines $module.Lines }
            $inserted = $null
            if ($method.Kind -eq 'ИзменениеИКонтроль') { $inserted = Get-BslInsertedLines $module.Lines }
            $deleted = Get-BslDeletedLines $module.Lines
            $fields = New-Object System.Collections.Generic.List[string]
            $safe = $false
            for ($n = $method.Start; $n -le $method.End; $n++) {
                if ($deleted.Contains($n)) { continue }
                if ($null -ne $inserted -and -not $inserted.Contains($n)) { continue }
                $lineCode = $code[$n - 1]
                if ($lineCode -match 'ДанныеИБ\s*\.\s*Свойство\s*\(') { $safe = $true }
                foreach ($fieldMatch in $fieldRegex.Matches($lineCode)) {
                    $field = $fieldMatch.Groups[2].Value
                    if ($field -eq 'Свойство') { continue }
                    if (-not $field) { $field = '[...]' }
                    $fields.Add(('{0} (строка {1})' -f $field, $n))
                }
            }
            if ($fields.Count -eq 0 -or $safe) { continue }
            $place = '{0}, {1}, {2}' -f $module.Extension, $module.Object, $method.Name
            if ($method.Target) { $place += (' (&{0}("{1}"))' -f $method.Kind, $method.Target) }
            $findings.Add([pscustomobject]@{
                    Rule = 'R2'; Level = 'ВНИМАНИЕ'
                    Key = ('R2|{0}|{1}|{2}' -f $module.Extension, $module.Object, $method.Name)
                    Text = ('R2 {0}: обработчик ПриОтправкеДанных правила со структурой обращается к ДанныеИБ без Свойство(): {1}. В структуре такого ключа может не быть. Эвристика, не блокирует.' -f $place, ((@($fields | Select-Object -First 5)) -join ', '))
                })
        }
    }

    # R4: в расширениях подрядчиков #Вставка, #Удаление и перехваты без пометки автора с датой рядом.
    foreach ($module in $parsed.Modules) {
        if (-not $module.Contractor) { continue }
        $methods = Get-BslMethods $module.Lines
        $counter = @{}
        for ($i = 0; $i -lt $module.Lines.Count; $i++) {
            $line = [string]$module.Lines[$i]
            $kind = ''
            if ($line -match '^\s*#(Вставка|Удаление)\b') { $kind = '#' + $Matches[1] }
            elseif ($BslAnnotationRegex.IsMatch($line)) { $kind = 'перехват' }
            if (-not $kind) { continue }
            $marked = $false
            for ($k = [Math]::Max(0, $i - 3); $k -le [Math]::Min($module.Lines.Count - 1, $i + 1); $k++) {
                if ($BslMarkRegex.IsMatch([string]$module.Lines[$k])) { $marked = $true; break }
            }
            if ($marked) { continue }
            $methodName = '(вне метода)'
            foreach ($method in $methods) {
                if (($i + 1) -ge $method.Start -and ($i + 1) -le $method.End) { $methodName = $method.Name; break }
                if ($kind -eq 'перехват' -and $method.AnnotationLine -eq ($i + 1)) { $methodName = $method.Name; break }
            }
            $counterKey = '{0}|{1}' -f $methodName, $kind
            if (-not $counter.ContainsKey($counterKey)) { $counter[$counterKey] = 0 }
            $counter[$counterKey]++
            $findings.Add([pscustomobject]@{
                    Rule = 'R4'; Level = 'ВНИМАНИЕ'
                    Key = ('R4|{0}|{1}|{2}|{3}|{4}' -f $module.Extension, $module.Object, $methodName, $kind, $counter[$counterKey])
                    Text = ('R4 {0}, {1}, {2}, строка {3}: {4} без пометки автора с датой рядом (регламент: «// ** Фамилия И.О. ГГГГММДД что и зачем»). Только сообщение, в чужой код гейт не пишет.' -f $module.Extension, $module.Object, $methodName, ($i + 1), $kind)
                })
        }
    }
    $sha.Dispose()
    return [pscustomobject]@{ Findings = $findings.ToArray(); State = $state; Modules = $parsed.Modules.Count }
}

function Read-ExchangeRuleState {
    # Эталон перехватов правил обмена: «ключ<TAB>хеш<TAB>текст» -> таблица. Файла нет - $null.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $table = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $parts = $line.TrimStart([char]0xFEFF).Split("`t")
        if ($parts.Count -ge 2) { $table[$parts[0]] = $parts[1] }
    }
    return $table
}

function Invoke-ExchangeRulesStep {
    # Шаг «Правила обмена»: R1 (ОШИБКА, эталоном не снимается; снимает только исключение площадки с живым
    # перехватом-гарантией), R2 и R4 (ВНИМАНИЕ: жёлтое только новое против эталона), R3 (без цвета: что изменилось
    # в перехватах правил обмена против эталона - в отчёт и в шаг «Обмены: до и после»).
    param($Dumps)
    $stepName = 'Правила обмена'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($null -eq $Dumps -or @($Dumps.Dirs.Keys).Count -eq 0) {
        $detail = 'выгрузки расширений нет, проверять нечего'
        if ($null -ne $Dumps -and @($Dumps.Problems).Count -gt 0) { $detail += ('. ' + (@($Dumps.Problems) -join ' | ')) }
        Add-StepResult -Name $stepName -Status 'WARN' -Detail $detail
        return
    }
    $result = Get-ExchangeRuleFindings -Dumps $Dumps -Exceptions $exchangeRuleExceptions

    # R3: перехваты правил обмена против эталона.
    $reference = Read-ExchangeRuleState $exchangeRulesStateFile
    $changes = New-Object System.Collections.Generic.List[string]
    if ($null -ne $reference) {
        foreach ($key in @($result.State.Keys)) {
            if (-not $reference.ContainsKey($key)) { $changes.Add(('новый перехват: ' + $result.State[$key].Text)) }
            elseif ($reference[$key] -ne $result.State[$key].Hash) { $changes.Add(('изменён перехват: ' + $result.State[$key].Text)) }
        }
        foreach ($key in @($reference.Keys)) { if (-not $result.State.Contains($key)) { $changes.Add(('перехвата больше нет: ' + $key)) } }
    }
    $script:ExchangeRulesChanged = $changes.ToArray()
    $stateFile = Join-Path $RunDir 'exchange-rules.state.txt'
    [System.IO.File]::WriteAllLines($stateFile, [string[]]@($result.State.Keys | Sort-Object | ForEach-Object { '{0}{1}{2}{1}{3}' -f $_, "`t", $result.State[$_].Hash, $result.State[$_].Text }), $Utf8Bom)
    [System.IO.File]::WriteAllLines((Join-Path $RunDir 'exchange-rules.changes.txt'), $changes.ToArray(), $Utf8Bom)

    # Замечания: все - в exchange-rules.txt, ключи - в exchange-rules.findings.txt (эталон R2/R4).
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $hasFindingsReference = Test-Path -LiteralPath $exchangeRulesFindingsFile
    if ($hasFindingsReference) { foreach ($line in [System.IO.File]::ReadAllLines($exchangeRulesFindingsFile, [System.Text.Encoding]::UTF8)) { [void]$known.Add($line.TrimStart([char]0xFEFF)) } }
    $errors = @($result.Findings | Where-Object { $_.Level -eq 'ОШИБКА' })
    $warnings = @($result.Findings | Where-Object { $_.Level -eq 'ВНИМАНИЕ' })
    $infos = @($result.Findings | Where-Object { $_.Level -eq 'ИНФО' })
    $newWarnings = @($warnings | Where-Object { -not $known.Contains($_.Key) })
    $logFile = Join-Path $RunDir 'exchange-rules.txt'
    [System.IO.File]::WriteAllLines($logFile, [string[]]@($result.Findings | ForEach-Object { '[{0}] {1}' -f $_.Level, $_.Text }), $Utf8Bom)
    [System.IO.File]::WriteAllLines((Join-Path $RunDir 'exchange-rules.findings.txt'), [string[]]@($warnings | ForEach-Object { $_.Key } | Sort-Object -Unique), $Utf8Bom)
    $newFile = Join-Path $RunDir 'exchange-rules.new.txt'
    [System.IO.File]::WriteAllLines($newFile, [string[]]@((@($errors) + @($newWarnings)) | ForEach-Object { '[{0}] {1}' -f $_.Level, $_.Text }), $Utf8Bom)

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add(("перехватов правил обмена {0}, модулей разобрано {1}" -f $result.State.Count, $result.Modules))
    $parts.Add(("R1: ошибок {0}, снято исключением {1}" -f $errors.Count, $infos.Count))
    $parts.Add(("R2/R4 и R1 по выражению: замечаний {0}, новых {1}" -f $warnings.Count, $newWarnings.Count))
    if ($null -eq $reference) { $parts.Add('эталона перехватов ещё нет, этот прогон станет им') }
    else { $parts.Add(("R3: изменений в перехватах правил обмена {0}" -f $changes.Count)) }
    if (@($contractorExtensions).Count -eq 0) { $parts.Add('R4 не проверялось: ContractorExtensions пустой') }
    if (@($Dumps.Problems).Count -gt 0) { $parts.Add((@($Dumps.Problems) -join ' | ')) }
    $sample = @((@($errors) + @($newWarnings)) | Select-Object -First 2 | ForEach-Object { if ($_.Text.Length -gt 260) { $_.Text.Substring(0, 260) + '...' } else { $_.Text } })
    $detail = ($parts -join '; ') + '; всё - в exchange-rules.txt'
    if ($sample.Count -gt 0) { $detail += ('. Начало: ' + ($sample -join ' | ')) }

    $status = 'OK'
    if ($newWarnings.Count -gt 0 -or @($Dumps.Problems).Count -gt 0) { $status = 'WARN' }
    if ($errors.Count -gt 0) { $status = 'FAIL' }
    # Эталон перехватов и замечаний двигается сам, только когда шаг зелёный.
    if ($status -eq 'OK') {
        if (-not (Test-Path -LiteralPath $baselineDir)) { New-Item -ItemType Directory -Path $baselineDir -Force | Out-Null }
        Copy-Item -LiteralPath $stateFile -Destination $exchangeRulesStateFile -Force
        Copy-Item -LiteralPath (Join-Path $RunDir 'exchange-rules.findings.txt') -Destination $exchangeRulesFindingsFile -Force
    }
    $watch.Stop()
    Add-StepResult -Name $stepName -Status $status -Detail $detail -Log $logFile -Seconds ([int]$watch.Elapsed.TotalSeconds)
}

#endregion

#region Время ключевых операций

function Read-MetricsHistory {
    # История замеров базы: stats\metrics.csv, строки «время<TAB>база<TAB>прогон<TAB>метка<TAB>ключ<TAB>мс».
    # Возвращает таблицу «ключ -> список мс» по порядку записи.
    param([string]$Path, [string]$Base)
    $table = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $table }
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $parts = $line.TrimStart([char]0xFEFF).Split("`t")
        if ($parts.Count -lt 6 -or $parts[1] -ne $Base) { continue }
        $ms = 0
        if (-not [int]::TryParse($parts[5], [ref]$ms)) { continue }
        if (-not $table.ContainsKey($parts[4])) { $table[$parts[4]] = New-Object System.Collections.Generic.List[int] }
        $table[$parts[4]].Add($ms)
    }
    return $table
}

function Add-MetricsHistory {
    param([string]$Path, [string]$Base, [string]$Label, $Metrics)
    if ($Metrics.Count -eq 0) { return }
    $folder = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $lines = @($Metrics.Keys | Sort-Object | ForEach-Object { '{0}{1}{2}{1}{3}{1}{4}{1}{5}{1}{6}' -f $stamp, "`t", $Base, $runId, $Label, $_, $Metrics[$_] })
    [System.IO.File]::AppendAllText($Path, (($lines -join "`r`n") + "`r`n"), $Utf8Bom)
}

function Invoke-MetricsStep {
    # Шаг «Время ключевых операций»: замеры самопроверки (проведение, печать, отчёты, сценарии) против истории
    # по той же базе и тому же ключу. Заметно медленнее - дольше медианы последних MetricHistory замеров в
    # MetricSlowFactor раз и на MetricMinDeltaMs мс; замеров в истории меньше MetricMinHistory - не сравнивается.
    # Замеры «до» (старый код) пишутся в историю первыми: с ними и сравниваются замеры «после».
    param($Before, $After)
    $stepName = 'Время ключевых операций'
    $historyFile = Join-Path (Resolve-RootPath ([string](Get-Setting $cfg 'StatsDir' 'stats'))) 'metrics.csv'
    $factor = [double](Get-Setting $cfg 'MetricSlowFactor' 1.5)
    $minDelta = [int](Get-Setting $cfg 'MetricMinDeltaMs' 500)
    $minHistory = [int](Get-Setting $cfg 'MetricMinHistory' 3)
    $depth = [int](Get-Setting $cfg 'MetricHistory' 10)

    Add-MetricsHistory -Path $historyFile -Base $baseKey -Label 'before' -Metrics $Before
    $history = Read-MetricsHistory -Path $historyFile -Base $baseKey
    $slow = New-Object System.Collections.Generic.List[object]
    $compared = 0
    foreach ($key in @($After.Keys | Sort-Object)) {
        if (-not $history.ContainsKey($key)) { continue }
        $values = @($history[$key] | ForEach-Object { $_ })
        if ($values.Count -gt $depth) { $values = @($values | Select-Object -Last $depth) }
        if ($values.Count -lt $minHistory) { continue }
        $compared++
        $sorted = @($values | Sort-Object)
        $median = [double]$sorted[[int][Math]::Floor(($sorted.Count - 1) / 2)]
        if ($sorted.Count % 2 -eq 0) { $median = ([double]$sorted[$sorted.Count / 2 - 1] + [double]$sorted[$sorted.Count / 2]) / 2 }
        $now = [int]$After[$key]
        if ($now -gt $median * $factor -and ($now - $median) -ge $minDelta) {
            $slow.Add([pscustomobject]@{ Key = $key; Now = $now; Median = [int]$median; Ratio = ($now / [Math]::Max($median, 1)) })
        }
    }
    Add-MetricsHistory -Path $historyFile -Base $baseKey -Label 'after' -Metrics $After

    $slowLines = @($slow | Sort-Object Ratio -Descending | ForEach-Object { '{0} мс, обычно {1} мс (в {2:0.0} раза): {3}' -f $_.Now, $_.Median, $_.Ratio, $_.Key })
    [System.IO.File]::WriteAllLines((Join-Path $RunDir 'metrics-slow.txt'), [string[]]$slowLines, $Utf8Bom)
    $detail = "замеров {0}, сравнено с историей {1}, заметно медленнее {2}" -f $After.Count, $compared, $slow.Count
    if ($compared -eq 0) { $detail += ("; истории пока мало (нужно замеров: {0}), прогон её пополнил" -f $minHistory) }
    if ($slow.Count -gt 0) { $detail += ('. ' + (@($slowLines | Select-Object -First 3) -join ' | ') + '; все - metrics-slow.txt') }
    $status = 'OK'
    if ($slow.Count -gt 0) { $status = 'WARN' }
    Add-StepResult -Name $stepName -Status $status -Detail $detail -Log (Join-Path $RunDir 'metrics-slow.txt')
}

#endregion

function Get-MaskedSnapshotLine {
    # Строка снимка без того, что меняется само при каждом прогоне (см. SnapshotMasks).
    param([string]$Line, [string[]]$Masks)
    foreach ($mask in $Masks) { $Line = [regex]::Replace($Line, $mask, '*') }
    return $Line
}

function Compare-SelfCheckSnapshots {
    # Снимки прогона против эталонных. Изменился снимок с тем же ключом - это замечание: тот же объект
    # выгрузился по-другому. Новый ключ или пропавший - только сведения: объект для снимка выбирается
    # в базе заново («последний проведённый документ») и может смениться сам по себе.
    # Разница по изменённым снимкам пишется в DiffPath: строки, которые ушли («-») и появились («+»).
    # SnapshotMasks - регулярные выражения: что они находят в строке снимка, заменяется на «*» с обеих сторон
    # (дата создания сообщения обмена, идентификаторы, которые 1С создаёт заново при каждом проведении).
    param($Current, [string]$ReferenceFile, [string]$DiffPath)
    $reference = Read-SelfCheckSnapshots $ReferenceFile
    # По умолчанию - поля заголовка сообщения обмена: XML-снимок, который не разобрался (обрезан), ими не отличается.
    $masks = @(Get-Setting $cfg 'SnapshotMasks' @('(?<=<(?:\w+:)?(?:CreationDate|MessageNo|ReceivedNo)>)[^<]*') | Where-Object { $_ })
    $changed = New-Object System.Collections.Generic.List[string]
    $added = New-Object System.Collections.Generic.List[string]
    $diff = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($Current.Keys | Sort-Object)) {
        if (-not $reference.ContainsKey($key)) { $added.Add($key); continue }
        $was = @(@($reference[$key]) | ForEach-Object { Get-MaskedSnapshotLine -Line ([string]$_) -Masks $masks })
        $now = @(@($Current[$key]) | ForEach-Object { Get-MaskedSnapshotLine -Line ([string]$_) -Masks $masks })
        if (($was -join "`n") -ceq ($now -join "`n")) { continue }
        $changed.Add($key)
        # Разница по строкам с учётом повторов: сколько раз строка была и сколько стала.
        $counts = @{}
        foreach ($line in $was) { if ($counts.ContainsKey($line)) { $counts[$line]-- } else { $counts[$line] = -1 } }
        foreach ($line in $now) { if ($counts.ContainsKey($line)) { $counts[$line]++ } else { $counts[$line] = 1 } }
        $diff.Add('### ' + $key)
        foreach ($line in $was) { if ($counts[$line] -lt 0) { $diff.Add('- ' + $line); $counts[$line]++ } }
        foreach ($line in $now) { if ($counts[$line] -gt 0) { $diff.Add('+ ' + $line); $counts[$line]-- } }
        if ($diff[$diff.Count - 1] -ceq ('### ' + $key)) { $diff.Add('  (те же строки, другой порядок)') }
        $diff.Add('')
    }
    $gone = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($reference.Keys | Sort-Object)) { if (-not $Current.Contains($key)) { $gone.Add($key) } }
    if ($changed.Count -gt 0 -and $DiffPath) { [System.IO.File]::WriteAllLines($DiffPath, $diff.ToArray(), $Utf8Bom) }
    return [pscustomobject]@{
        HasReference = (Test-Path -LiteralPath $ReferenceFile)
        Total        = @($Current.Keys).Count
        Changed      = $changed.ToArray()
        Added        = $added.ToArray()
        Gone         = $gone.ToArray()
    }
}

#endregion

#region Режимы без прогона

if ($PSCmdlet.ParameterSetName -eq 'Password') {
    $target = Resolve-RootPath $SavePassword
    $targetDir = Split-Path -Parent $target
    if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir | Out-Null
    }
    $secure = Read-Host -AsSecureString -Prompt 'Пароль (на экране не виден)'
    $secure | ConvertFrom-SecureString | Set-Content -LiteralPath $target -Encoding ASCII
    Write-Host "Сохранено: $target"
    Write-Host 'Расшифровать файл можно только под этой учёткой Windows и только на этой машине.'
    exit 0
}

function Invoke-AcceptBaseline {
    # Принять замечания прогона как известные: записать их в эталон базы. Зовут ключ -AcceptBaseline
    # и пункт меню «Принять новое последнего прогона в эталон». Ошибка - исключением.
    param([string]$RunPath)
    $acceptDir = $RunPath
    $verdictFile = Join-Path $acceptDir 'verdict.json'
    if (-not (Test-Path -LiteralPath $verdictFile)) { throw "Не нашёл verdict.json в $acceptDir" }
    $acceptMeta = Get-Content -LiteralPath $verdictFile -Raw -Encoding UTF8 | ConvertFrom-Json
    # В итогах прогонов, сделанных до появления отката, этого поля нет.
    $kitDecisionProperty = $acceptMeta.PSObject.Properties['kitDecision']
    if ($null -ne $kitDecisionProperty -and @('rolledBack', 'rollbackFailed') -contains [string]$kitDecisionProperty.Value) {
        throw "Комплект прогона $($acceptMeta.runId) откатывали: его замечания принять как известные нельзя, в базе стоит не он."
    }
    $baselineTarget = Join-Path (Join-Path $Root 'baseline') $acceptMeta.baseKey
    if (-not (Test-Path -LiteralPath $baselineTarget)) {
        New-Item -ItemType Directory -Path $baselineTarget | Out-Null
    }
    $logFiles = @(Get-ChildItem -LiteralPath $acceptDir -Filter 'check*.log' -File)
    $acceptSelfCheck = Join-Path $acceptDir 'selfcheck-after.norm.txt'
    if ($logFiles.Count -eq 0 -and -not (Test-Path -LiteralPath $acceptSelfCheck)) {
        throw "В $acceptDir нет ни логов проверок (check*.log), ни записей самопроверки (selfcheck-after.norm.txt): принимать нечего."
    }
    foreach ($file in $logFiles) {
        $acceptLines = @(Read-V8Log $file.FullName)
        if (Test-DesignerBusy $acceptLines) {
            Write-Host ("Пропущено: {0} - в том прогоне конфигуратор был занят, проверка не выполнялась" -f $file.Name) -ForegroundColor Yellow
            continue
        }
        $acceptRecords = @(ConvertTo-CheckRecords $acceptLines)
        [System.IO.File]::WriteAllLines((Join-Path $baselineTarget ($file.BaseName + '.norm.txt')), [string[]]$acceptRecords, $Utf8Bom)
        Write-Host ("Принято как известное: {0}, записей {1}" -f $file.BaseName, $acceptRecords.Count)
    }
    if (Test-Path -LiteralPath $acceptSelfCheck) {
        # Состояние базы после того прогона становится эталоном самопроверки.
        $acceptRecords = @([System.IO.File]::ReadAllLines($acceptSelfCheck, [System.Text.Encoding]::UTF8))
        [System.IO.File]::WriteAllLines((Join-Path $baselineTarget 'selfcheck.norm.txt'), [string[]]$acceptRecords, $Utf8Bom)
        $acceptInfo = @(
            ("run={0}" -f $acceptMeta.runId),
            'label=accepted',
            'fingerprint=',
            ("time={0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        )
        [System.IO.File]::WriteAllLines((Join-Path $baselineTarget 'selfcheck.info.txt'), [string[]]$acceptInfo, $Utf8Bom)
        Write-Host ("Принято как известное: самопроверка, записей {0}" -f $acceptRecords.Count)
        # Снимки того прогона (сообщения обмена) становятся эталонными.
        # Карта покрытия того прогона становится эталоном: её непокрытое больше не новое.
        $acceptCoverage = Join-Path $acceptDir 'coverage.txt'
        if (Test-Path -LiteralPath $acceptCoverage) {
            Copy-Item -LiteralPath $acceptCoverage -Destination (Join-Path $baselineTarget 'coverage.txt') -Force
            Write-Host 'Принято как известное: карта покрытия'
        }
        $acceptSnapshots = Join-Path $acceptDir 'selfcheck-after.snapshots.txt'
        if (Test-Path -LiteralPath $acceptSnapshots) {
            Copy-Item -LiteralPath $acceptSnapshots -Destination (Join-Path $baselineTarget 'selfcheck.snapshots.txt') -Force
            Write-Host 'Принято как известное: снимки самопроверки'
        }
        # Итоги пробной выгрузки шага «Обмены» того прогона становятся эталонными.
        $acceptExchange = Join-Path $acceptDir 'selfcheck-after.exchange.txt'
        if (Test-Path -LiteralPath $acceptExchange) {
            Copy-Item -LiteralPath $acceptExchange -Destination (Join-Path $baselineTarget 'selfcheck.exchange.txt') -Force
            Write-Host 'Принято как известное: итоги выгрузки шага «Обмены»'
        }
    }
    # Проверка правил обмена того прогона: перехваты и замечания R2/R4 становятся известными (R1 эталоном не снимается).
    foreach ($acceptPair in @(@('exchange-rules.state.txt', 'exchange-rules.state.txt'), @('exchange-rules.findings.txt', 'exchange-rules.findings.txt'))) {
        $acceptFile = Join-Path $acceptDir $acceptPair[0]
        if (Test-Path -LiteralPath $acceptFile) {
            Copy-Item -LiteralPath $acceptFile -Destination (Join-Path $baselineTarget $acceptPair[1]) -Force
            Write-Host ("Принято как известное: {0}" -f $acceptPair[0])
        }
    }
    # Отметка в папке прогона: в списке прогонов он виден как принятый, второй раз его не предлагают.
    [System.IO.File]::WriteAllLines((Join-Path $acceptDir 'accepted.txt'), [string[]]@(('time={0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))), $Utf8Bom)
    Write-Host "Эталон базы «$($acceptMeta.baseKey)» обновлён: $baselineTarget"
}

if ($PSCmdlet.ParameterSetName -eq 'Accept') {
    Invoke-AcceptBaseline -RunPath (Resolve-RootPath $AcceptBaseline)
    exit 0
}

#endregion

#region Подготовка прогона

$configPath = $Config
if ([string]::IsNullOrWhiteSpace($configPath)) { $configPath = Join-Path $Root 'config.psd1' }
if (-not (Test-Path -LiteralPath $configPath)) { throw "Нет файла настроек: $configPath" }
$cfg = Import-PowerShellDataFile -LiteralPath $configPath
# Настройки площадки из поставки гейта (config.site.psd1 рядом с run.ps1, его кладёт установщик и заменяет
# при каждой установке): ключ, которого нет в config.psd1, берётся оттуда. Свой ключ в config.psd1 важнее.
$siteConfigPath = Join-Path $Root 'config.site.psd1'
$script:SiteSettingKeys = @()
if (Test-Path -LiteralPath $siteConfigPath) {
    $siteConfig = Import-PowerShellDataFile -LiteralPath $siteConfigPath
    foreach ($siteKey in @($siteConfig.Keys)) {
        if (-not $cfg.ContainsKey($siteKey)) { $cfg[$siteKey] = $siteConfig[$siteKey]; $script:SiteSettingKeys += [string]$siteKey }
    }
}

$script:Server = [string](Get-Setting $cfg 'Server' '')
$script:Base = [string](Get-Setting $cfg 'Base' '')
$script:FileBase = [string](Get-Setting $cfg 'File' '')
# Код разрешения входа (/UC): нужен, когда в базе установлена блокировка начала сеансов с кодом.
# Код разрешения входа: один и тот же для блокировки, которую ставит гейт, и для всех входов в базу. Пусто - 0.
$script:UnlockCode = [string](Get-Setting $cfg 'UnlockCode' '0')
if ([string]::IsNullOrWhiteSpace($script:UnlockCode)) { $script:UnlockCode = '0' }

if ([string]::IsNullOrEmpty($script:FileBase)) {
    if ([string]::IsNullOrEmpty($script:Server) -or [string]::IsNullOrEmpty($script:Base)) {
        throw 'В config.psd1 не заполнены Server и Base (или File для файловой базы).'
    }
    $baseKey = $script:Base
}
else {
    $baseKey = Split-Path -Leaf $script:FileBase
}

# Главная защита: этот скрипт загружает расширения и обновляет конфигурацию базы данных.
$baseNameToCheck = $baseKey
if ($baseNameToCheck -notmatch $TestBasePattern) {
    throw "База «$baseNameToCheck» не похожа на тестовую (в имени нет temp, test, copy, stand и т. п.). С рабочей базой скрипт не работает."
}
$forbidden = @(Get-Setting $cfg 'ForbiddenBases' @() | Where-Object { $_ })
foreach ($name in $forbidden) {
    if ($baseNameToCheck -ieq $name) { throw "База «$baseNameToCheck» в списке запрещённых (ForbiddenBases)." }
}

$binDir = [string](Get-Setting $cfg 'V8Bin' '')
$v8 = Join-Path $binDir '1cv8.exe'
$v8c = Join-Path $binDir '1cv8c.exe'
if (-not (Test-Path -LiteralPath $v8)) { throw "Не нашёл конфигуратор: $v8. Поправь V8Bin в config.psd1." }

$knownExtensions = @(Get-Setting $cfg 'Extensions' @() | Where-Object { $_ })

# Меню запуска без ключей: прогон на том, что есть, или прогон с обновлением из inbox.
# Обновления в inbox - каждое расширение (файл .cfe, каталог выгрузки, архив .zip) и каждая внешняя обработка
# (файл .epf или .erf, каталог выгрузки обработки). Обработки гейт пока только показывает.
$inboxDir = Resolve-RootPath ([string](Get-Setting $cfg 'InboxDir' 'inbox'))
# Меню и вопросы (ui.ps1): из ci.exe их рисует ci.exe, без него - консоль.
. (Join-Path $Root 'ui.ps1')
Initialize-Ui -Channel $UiChannel

# Статистика длительностей шагов: план и факт (stats.ps1, журнал stats\durations.csv).
. (Join-Path $Root 'stats.ps1')
Initialize-Stats -Dir (Resolve-RootPath ([string](Get-Setting $cfg 'StatsDir' 'stats'))) -Source 'gate' -Base $script:Base `
    -Days ([int](Get-Setting $cfg 'StatsDays' 120)) -Platform ([regex]::Match($binDir, '\d+\.\d+\.\d+\.\d+').Value)
$script:MenuItems = @()

function Get-ConfigurationName {
    # Имя расширения из Configuration.xml выгрузки. Через XPath: у узла XML есть своё свойство Name.
    param([string]$XmlText)
    try {
        [xml]$document = $XmlText
        $node = $document.SelectSingleNode("/*[local-name()='MetaDataObject']/*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Name']")
        if ($null -ne $node) { return [string]$node.InnerText }
    }
    catch { }
    return ''
}

function Get-ExtensionFromFileName {
    param([string]$FileName)
    $matched = @($knownExtensions | Where-Object { $FileName.IndexOf([string]$_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 } | Sort-Object { $_.Length } -Descending)
    if ($matched.Count -gt 0) { return [string]$matched[0] }
    return ''
}

function Test-ProcessorDump {
    # Каталог выгрузки внешней обработки или отчёта: в корне .xml с ExternalDataProcessor или ExternalReport.
    # Возвращает имя обработки или пустую строку.
    param([string]$Dir)
    $info = Get-ProcessorDumpInfo $Dir
    if ($null -eq $info) { return '' }
    return [string]$info.Name
}

function Get-ProcessorDumpInfo {
    # То же, подробно: корневой .xml, имя и отчёт ли это. Не выгрузка обработки - $null.
    param([string]$Dir)
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Filter '*.xml' -File)) {
        $head = ''
        try {
            $reader = New-Object System.IO.StreamReader($file.FullName, [System.Text.Encoding]::UTF8)
            $buffer = New-Object char[] 4096
            $count = $reader.Read($buffer, 0, $buffer.Length)
            $reader.Close()
            $head = New-Object string($buffer, 0, $count)
        }
        catch { continue }
        if ($head.Contains('<ExternalDataProcessor')) { return [pscustomobject]@{ Xml = $file.FullName; Name = $file.BaseName; IsReport = $false } }
        if ($head.Contains('<ExternalReport')) { return [pscustomobject]@{ Xml = $file.FullName; Name = $file.BaseName; IsReport = $true } }
    }
    return $null
}

function Get-ZipContentNames {
    # Что в архиве, без распаковки: имена расширений из Configuration.xml и из имён .cfe, обработки .epf и .erf.
    param([string]$ZipPath)
    $extensions = New-Object System.Collections.Generic.List[string]
    $processors = New-Object System.Collections.Generic.List[string]
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Read, [System.Text.Encoding]::GetEncoding(866))
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('\', '/')
            $depth = $entryName.Split('/').Count
            if ($entry.Name -eq 'Configuration.xml' -and $depth -le 4) {
                $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
                $name = Get-ConfigurationName $reader.ReadToEnd()
                $reader.Close()
                if ($name -and -not $extensions.Contains($name)) { $extensions.Add($name) }
            }
            elseif ($entry.Name -match '\.cfe$') {
                $name = Get-ExtensionFromFileName $entry.Name
                if (-not $name) { $name = $entry.Name + ' (расширение не опознано)' }
                if (-not $extensions.Contains($name)) { $extensions.Add($name) }
            }
            elseif ($entry.Name -match '\.(epf|erf)$') { $processors.Add($entry.Name) }
        }
    }
    catch { $extensions.Add(('архив не прочитан: ' + $_.Exception.Message)) }
    finally { if ($null -ne $archive) { $archive.Dispose() } }
    return [pscustomobject]@{ Extensions = $extensions.ToArray(); Processors = $processors.ToArray() }
}

function Add-InboxItems {
    # Обход inbox. Каталог выгрузки - одно обновление, внутрь него поиск не заходит.
    param([string]$Dir, [int]$Depth, $Items)
    foreach ($child in @(Get-ChildItem -LiteralPath $Dir | Sort-Object Name)) {
        $relative = $child.FullName.Substring($inboxDir.TrimEnd('\').Length + 1)
        if (-not $child.PSIsContainer) {
            $type = $child.Extension.ToLowerInvariant()
            if ($type -eq '.cfe') {
                $name = Get-ExtensionFromFileName $child.BaseName
                $Items.Add([pscustomobject]@{ Path = $child.FullName; Relative = $relative; Kind = 'cfe'; Names = @($name); Usable = [bool]$name
                        Note = $(if ($name) { "расширение $name" } else { 'не понял, какое расширение: в имени нет имени из Extensions' }) })
            }
            elseif ($type -eq '.zip') {
                $content = Get-ZipContentNames $child.FullName
                $note = 'архив: ' + ((@($content.Extensions) + @($content.Processors | ForEach-Object { 'обработка ' + $_ })) -join ', ')
                $usable = (@($content.Extensions | Where-Object { -not $_.StartsWith('архив не прочитан') }).Count + @($content.Processors).Count) -gt 0
                $Items.Add([pscustomobject]@{ Path = $child.FullName; Relative = $relative; Kind = 'zip'; Names = @(@($content.Extensions) + @($content.Processors)); Usable = $usable; Note = $note })
            }
            elseif ($type -eq '.epf' -or $type -eq '.erf') {
                $what = 'внешняя обработка'
                if ($type -eq '.erf') { $what = 'внешний отчёт' }
                $Items.Add([pscustomobject]@{ Path = $child.FullName; Relative = $relative; Kind = 'epf'; Names = @($child.BaseName); Usable = $true; Note = ("{0} {1}: запись в справочник «Дополнительные отчёты и обработки»" -f $what, $child.Name) })
            }
            continue
        }
        $configuration = Join-Path $child.FullName 'Configuration.xml'
        if (Test-Path -LiteralPath $configuration -PathType Leaf) {
            $name = Get-ConfigurationName (Get-Content -LiteralPath $configuration -Raw -Encoding UTF8)
            $Items.Add([pscustomobject]@{ Path = $child.FullName; Relative = $relative; Kind = 'files'; Names = @($name); Usable = [bool]$name
                    Note = $(if ($name) { "выгрузка в файлы, расширение $name" } else { 'выгрузка в файлы, имя расширения не прочиталось' }) })
            continue
        }
        $processor = Get-ProcessorDumpInfo $child.FullName
        if ($null -ne $processor) {
            $what = 'внешней обработки'
            if ($processor.IsReport) { $what = 'внешнего отчёта' }
            $Items.Add([pscustomobject]@{ Path = $child.FullName; Relative = $relative; Kind = 'epfdir'; Names = @($processor.Name); Usable = $true
                    Note = ("выгрузка {0} {1} в файлы: соберу и запишу в справочник" -f $what, $processor.Name) })
            continue
        }
        if ($Depth -lt 3) { Add-InboxItems -Dir $child.FullName -Depth ($Depth + 1) -Items $Items }
    }
}


function Copy-RunFiles {
    # Копирует файлы прогона в inbox\<папка>, чтобы их можно было прогнать или отдать. Возвращает папку.
    param([string[]]$Sources, [string]$FolderName)
    $target = Join-Path $inboxDir $FolderName
    if (Test-Path -LiteralPath $target) { $target = $target + '_' + (Get-Date -Format 'HHmmss') }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($source in $Sources) { Copy-Item -LiteralPath $source -Destination $target -Recurse -Force }
    return $target
}

function Get-RunUpdateFiles {
    # Файл обновления прогона: перенесённый из inbox (папка inbox прогона), иначе - пути комплекта из verdict.json,
    # если они ещё есть на диске (в том числе распакованные архивы в kit\).
    param([string]$RunPath, $Verdict)
    $moved = Join-Path $RunPath 'inbox'
    if (Test-Path -LiteralPath $moved) { return @(Get-ChildItem -LiteralPath $moved | ForEach-Object { $_.FullName }) }
    $paths = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Verdict -and $null -ne $Verdict.PSObject.Properties['kitItems']) {
        foreach ($item in @($Verdict.kitItems)) {
            $path = [string]$item.path
            if ($path -and (Test-Path -LiteralPath $path) -and -not $paths.Contains($path)) { $paths.Add($path) }
        }
    }
    if ($null -ne $Verdict -and $null -ne $Verdict.PSObject.Properties['kitProcessings']) {
        foreach ($item in @($Verdict.kitProcessings)) {
            $path = [string]$item.path
            if ($path -and (Test-Path -LiteralPath $path) -and -not $paths.Contains($path)) { $paths.Add($path) }
        }
    }
    return $paths.ToArray()
}

function Get-RunListText {
    # Строка прогона для списка: вердикт, комплект, решение по комплекту.
    param($Verdict)
    $verdictNames = @{ GREEN = 'зелёный'; YELLOW = 'жёлтый'; RED = 'красный' }
    $decisionNames = @{ kept = 'оставлен'; rolledBack = 'откачен'; rollbackFailed = 'откат не полностью' }
    if ($null -eq $Verdict) { return 'нет итога (остановился до вердикта)' }
    $code = [string]$Verdict.verdict
    $text = $code
    if ($verdictNames.ContainsKey($code)) { $text = $verdictNames[$code] }
    $kitText = [string]$Verdict.kit
    if ($kitText) { $text += ' / ' + $kitText } else { $text += ' / без комплекта' }
    if ($null -ne $Verdict.PSObject.Properties['kitDecision']) {
        $decision = [string]$Verdict.kitDecision
        if ($decision -and $decisionNames.ContainsKey($decision)) { $text += ' (' + $decisionNames[$decision] + ')' }
    }
    return $text
}

function Get-RunNewLines {
    # Что нового нашёл прогон: по файлу *.new.txt - имя шага и число записей.
    param([string]$RunPath)
    $result = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $RunPath -Filter '*.new.txt' -File | Sort-Object Name)) {
        $count = @([System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        if ($count -gt 0) { $result += ('{0}: {1}' -f ($file.Name -replace '\.new\.txt$', ''), $count) }
    }
    return , @($result)
}

function Get-AcceptableRun {
    # Последний прогон этой базы, новое которого можно принять в эталон: жёлтый или красный, комплект
    # не откатывали, ещё не принят, есть что принимать. Принимать можно только последний прогон: после него
    # база не менялась, и его записи - её нынешнее состояние. Возвращает @{ Dir; Verdict } или $null.
    $runsRootAccept = Resolve-RootPath ([string](Get-Setting $cfg 'RunsDir' 'runs'))
    if (-not (Test-Path -LiteralPath $runsRootAccept)) { return $null }
    $last = @(Get-ChildItem -LiteralPath $runsRootAccept -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending | Select-Object -First 1)
    if ($last.Count -eq 0) { return $null }
    $verdictFile = Join-Path $last[0].FullName 'verdict.json'
    if (-not (Test-Path -LiteralPath $verdictFile)) { return $null }
    try { $verdict = (Get-Content -LiteralPath $verdictFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { return $null }
    if ([string]$verdict.baseKey -ne $baseKey) { return $null }
    if (@('YELLOW', 'RED') -notcontains [string]$verdict.verdict) { return $null }
    $decision = $verdict.PSObject.Properties['kitDecision']
    if ($null -ne $decision -and @('rolledBack', 'rollbackFailed') -contains [string]$decision.Value) { return $null }
    if (Test-Path -LiteralPath (Join-Path $last[0].FullName 'accepted.txt')) { return $null }
    $hasLogs = @(Get-ChildItem -LiteralPath $last[0].FullName -Filter 'check*.log' -File).Count -gt 0
    if (-not $hasLogs -and -not (Test-Path -LiteralPath (Join-Path $last[0].FullName 'selfcheck-after.norm.txt'))) { return $null }
    return [pscustomobject]@{ Dir = $last[0]; Verdict = $verdict }
}

function Invoke-AcceptFromMenu {
    # Пункт меню: показать, что станет известным, переспросить и принять. $true - принято.
    param($Run)
    $runName = $Run.Dir.Name
    $red = ([string]$Run.Verdict.verdict -eq 'RED')
    $newLines = Get-RunNewLines -RunPath $Run.Dir.FullName
    $more = @('Станет известным и больше не будет красить прогоны:')
    if ($newLines.Count -gt 0) { $more += @($newLines | ForEach-Object { '  ' + $_ }) } else { $more += '  новых записей в файлах *.new.txt нет (принимается состояние базы после прогона)' }
    $more += 'Ошибку обмена R1 и «обмен сломан до загрузки» эталон не прячет.'
    $kind = 'warn'
    if ($red) {
        $kind = 'bad'
        $more += 'Прогон КРАСНЫЙ: принимай, только если разобрал ошибки и они допустимы (например, были в базе и раньше).'
    }
    Show-UiTitle -Text ('Принять новое прогона {0} ({1}) в эталон' -f $runName, (Get-RunListText $Run.Verdict)) -Kind $kind -More $more
    $yesText = 'Принять в эталон'
    if ($red) { $yesText = 'Принять, хотя прогон красный' }
    $sure = Confirm-Ui -Question ('Принять новое прогона {0} в эталон? Что внутри - report.txt и *.new.txt в папке прогона.' -f $runName) -Yes $yesText -No 'Не принимать'
    if ($sure -ne $true) { Write-Host '  Не принято.'; return $false }
    try {
        Invoke-AcceptBaseline -RunPath $Run.Dir.FullName
        Write-Host ('  Принято: новое прогона {0} теперь известное.' -f $runName) -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host ('  Не принято: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Show-RecentRuns {
    # Последние прогоны: вердикт, комплект, решение; по любому - итог, разбор, папка, файл обновления, прежние версии.
    $runsRootMenu = Resolve-RootPath ([string](Get-Setting $cfg 'RunsDir' 'runs'))
    while ($true) {
        $runs = @()
        if (Test-Path -LiteralPath $runsRootMenu) {
            $runs = @(Get-ChildItem -LiteralPath $runsRootMenu -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
                Sort-Object Name -Descending | Select-Object -First 30)
        }
        if ($runs.Count -eq 0) { Write-Host '  Прогонов нет.'; return }
        $rows = @()
        $labels = @()
        foreach ($run in $runs) {
            $verdict = $null
            $verdictFile = Join-Path $run.FullName 'verdict.json'
            if (Test-Path -LiteralPath $verdictFile) {
                try { $verdict = (Get-Content -LiteralPath $verdictFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { $verdict = $null }
            }
            $rows += [pscustomobject]@{ Dir = $run; Verdict = $verdict }
            $acceptedMark = ''
            if (Test-Path -LiteralPath (Join-Path $run.FullName 'accepted.txt')) { $acceptedMark = ' · принят в эталон' }
            $labels += ('{0}  {1}{2}' -f $run.Name, (Get-RunListText $verdict), $acceptedMark)
        }
        $index = Select-UiOne -Header 'Последние прогоны' -Items $labels
        if ($index -lt 0) { return }
        $row = $rows[$index]
        $runPath = $row.Dir.FullName

        while ($true) {
            $summaryFile = Join-Path $runPath 'summary.txt'
            $reportFile = Join-Path $runPath 'report.txt'
            $kind = 'info'
            if ($null -ne $row.Verdict) {
                $code = [string]$row.Verdict.verdict
                if ($code -eq 'GREEN') { $kind = 'ok' } elseif ($code -eq 'YELLOW') { $kind = 'warn' } elseif ($code -eq 'RED') { $kind = 'bad' }
            }
            $short = New-Object System.Collections.Generic.List[string]
            if (Test-Path -LiteralPath $reportFile) {
                $inShort = $false
                foreach ($line in @([System.IO.File]::ReadAllLines($reportFile, [System.Text.Encoding]::UTF8))) {
                    if ($line -eq 'КОРОТКО') { $inShort = $true; continue }
                    if ($inShort) { if ([string]::IsNullOrWhiteSpace($line)) { break }; $short.Add($line.Trim()) }
                }
            }
            Show-UiTitle -Text ('Прогон {0}: {1}' -f $row.Dir.Name, (Get-RunListText $row.Verdict)) -Kind $kind -More $short.ToArray()

            $updateFiles = @(Get-RunUpdateFiles -RunPath $runPath -Verdict $row.Verdict)
            $beforeFiles = @()
            $beforeDir = Join-Path $runPath 'before'
            if (Test-Path -LiteralPath $beforeDir) { $beforeFiles = @(Get-ChildItem -LiteralPath $beforeDir -Filter '*.cfe' -File | ForEach-Object { $_.FullName }) }
            $actions = New-Object System.Collections.Generic.List[object]
            $actions.Add([pscustomobject]@{ Key = 'summary'; Label = 'Итог по шагам (summary.txt)' })
            if (Test-Path -LiteralPath $reportFile) { $actions.Add([pscustomobject]@{ Key = 'report'; Label = 'Разбор целиком (report.txt)' }) }
            $actions.Add([pscustomobject]@{ Key = 'folder'; Label = 'Открыть папку прогона' })
            if ($updateFiles.Count -gt 0) { $actions.Add([pscustomobject]@{ Key = 'update'; Label = ('Вытащить файл обновления в inbox: ' + (@($updateFiles | ForEach-Object { Split-Path -Leaf $_ }) -join '; ')) }) }
            if ($beforeFiles.Count -gt 0) { $actions.Add([pscustomobject]@{ Key = 'before'; Label = ('Вытащить прежние версии в inbox: ' + (@($beforeFiles | ForEach-Object { Split-Path -Leaf $_ }) -join '; ')) }) }
            $acceptable = Get-AcceptableRun
            $canAccept = ($null -ne $acceptable -and $acceptable.Dir.FullName -eq $runPath)
            if ($canAccept) { $actions.Add([pscustomobject]@{ Key = 'accept'; Label = 'Принять новое этого прогона в эталон (станет известным)' }) }
            $actions.Add([pscustomobject]@{ Key = 'back'; Label = 'Назад к списку' })
            $notes = @()
            if (Test-Path -LiteralPath (Join-Path $runPath 'accepted.txt')) { $notes += 'новое этого прогона уже принято в эталон' }
            elseif (-not $canAccept -and $null -ne $row.Verdict -and @('YELLOW', 'RED') -contains [string]$row.Verdict.verdict) {
                $notes += 'в эталон принимается только последний прогон, комплект которого не откатывали'
            }
            if ($updateFiles.Count -eq 0) { $notes += 'файла обновления у прогона нет' }
            $picked = Select-UiOne -Header 'Что сделать' -Items @($actions | ForEach-Object { $_.Label }) -Notes $notes
            if ($picked -lt 0 -or $actions[$picked].Key -eq 'back') { break }
            switch ($actions[$picked].Key) {
                'summary' {
                    if (Test-Path -LiteralPath $summaryFile) { Show-UiPager -Lines @([System.IO.File]::ReadAllLines($summaryFile, [System.Text.Encoding]::UTF8)) -Header ('summary.txt, прогон ' + $row.Dir.Name) }
                    else { Write-Host '  summary.txt нет: прогон остановился до вердикта, смотри run.log.' -ForegroundColor Yellow }
                }
                'report' { Show-UiPager -Lines @([System.IO.File]::ReadAllLines($reportFile, [System.Text.Encoding]::UTF8)) -Header ('report.txt, прогон ' + $row.Dir.Name) }
                'folder' { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $runPath) }
                'accept' { $null = Invoke-AcceptFromMenu -Run $acceptable }
                'update' {
                    $target = Copy-RunFiles -Sources $updateFiles -FolderName ('из_прогона_' + $row.Dir.Name)
                    Write-Host ("  Скопировал в {0}" -f $target) -ForegroundColor Green
                }
                'before' {
                    $target = Copy-RunFiles -Sources $beforeFiles -FolderName ('прежние_из_прогона_' + $row.Dir.Name)
                    Write-Host ("  Скопировал в {0}" -f $target) -ForegroundColor Green
                }
            }
            # Действие что-то вывело (не окно просмотра и не папка) - сначала посмотреть, потом снова карточка.
            if (@('accept', 'update', 'before') -contains $actions[$picked].Key -or ($actions[$picked].Key -eq 'summary' -and -not (Test-Path -LiteralPath $summaryFile))) {
                Wait-UiAcknowledge -Label 'Вернуться к прогону'
            }
        }
    }
}

# Меню - при запуске без ключей (ключ -UiChannel от ci.exe не в счёт).
$menuKeys = @($PSBoundParameters.Keys | Where-Object { $_ -ne 'UiChannel' })
if ($PSCmdlet.ParameterSetName -eq 'Run' -and $menuKeys.Count -eq 0 -and (Test-UiCanAsk)) {
    $choice = ''
    while ($true) {
        # inbox - заново на каждом круге меню: «Подтянуть из рабочей» кладёт туда новое.
        $inboxList = New-Object System.Collections.Generic.List[object]
        if (Test-Path -LiteralPath $inboxDir) { Add-InboxItems -Dir $inboxDir -Depth 0 -Items $inboxList }
        $usable = @($inboxList | Where-Object { $_.Usable })
        $unusable = @($inboxList | Where-Object { -not $_.Usable })
        $menu = New-Object System.Collections.Generic.List[object]
        if ($usable.Count -gt 0) { $menu.Add([pscustomobject]@{ Key = 'kit'; Label = ("Прогон с обновлением из inbox ({0})" -f $usable.Count) }) }
        $menu.Add([pscustomobject]@{ Key = 'asis'; Label = 'Прогон на том, что есть в базе' })
        $acceptable = Get-AcceptableRun
        if ($null -ne $acceptable) {
            $menu.Add([pscustomobject]@{ Key = 'accept'; Label = ('Принять новое последнего прогона в эталон ({0}, {1})' -f $acceptable.Dir.Name, (Get-RunListText $acceptable.Verdict)) })
        }
        $menu.Add([pscustomobject]@{ Key = 'runs'; Label = 'Результаты последних прогонов' })
        $menu.Add([pscustomobject]@{ Key = 'stats'; Label = 'Статистика длительностей: план и факт' })
        $menu.Add([pscustomobject]@{ Key = 'settings'; Label = 'Настройки (config.psd1)' })
        if (Test-Path -LiteralPath (Join-Path $Root 'deploy.ps1')) {
            $menu.Add([pscustomobject]@{ Key = 'deploy'; Label = 'Обновить рабочую базу (deploy)' })
            $menu.Add([pscustomobject]@{ Key = 'basestate'; Label = 'Показать состояние баз: блокировки и сеансы' })
            $menu.Add([pscustomobject]@{ Key = 'cmpext'; Label = 'Сравнить расширения: рабочая и temp' })
            $menu.Add([pscustomobject]@{ Key = 'cmpepf'; Label = 'Сравнить внешние обработки: рабочая и temp' })
            $menu.Add([pscustomobject]@{ Key = 'rollback'; Label = 'Откатить рабочую базу' })
            $menu.Add([pscustomobject]@{ Key = 'pullext'; Label = 'Подтянуть расширения из рабочей (в inbox)' })
            $menu.Add([pscustomobject]@{ Key = 'pullepf'; Label = 'Подтянуть обработки из рабочей (в inbox)' })
        }
        $menu.Add([pscustomobject]@{ Key = 'exit'; Label = 'Выход' })
        $notes = @()
        # Итог ночного прогона (nightly.ps1) - первой строкой: его смотрят утром.
        $nightlyLast = Join-Path $Root 'nightly\last.json'
        if (Test-Path -LiteralPath $nightlyLast) {
            try {
                $nightly = [System.IO.File]::ReadAllText($nightlyLast, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
                $nightlyNames = @{ GREEN = 'ЗЕЛЁНЫЙ'; YELLOW = 'ЖЁЛТЫЙ'; RED = 'КРАСНЫЙ'; NONE = 'итога нет' }
                $nightlyVerdict = [string]$nightly.verdict
                if ($nightlyNames.ContainsKey($nightlyVerdict)) { $nightlyVerdict = $nightlyNames[$nightlyVerdict] }
                $nightlyNote = "ночной прогон {0}: {1}, прогон {2}" -f $nightly.time, $nightlyVerdict, $nightly.runId
                $nightlyTime = [datetime]::MinValue
                if ([datetime]::TryParseExact([string]$nightly.time, 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$nightlyTime) -and ((Get-Date) - $nightlyTime).TotalHours -gt 36) {
                    $nightlyNote += ' - давно: проверь задание (.\nightly.ps1 -Status)'
                }
                $notes += $nightlyNote
            }
            catch { $notes += 'ночной прогон: nightly\last.json не читается' }
        }
        if ($usable.Count -eq 0) { $notes += 'в inbox нет обновлений расширений и обработок: прогон с обновлением недоступен' }
        $picked = Select-UiOne -Header ("Гейт расширений: {0} на {1}" -f $script:Base, $script:Server) -Items @($menu | ForEach-Object { $_.Label }) -Notes $notes
        if ($picked -lt 0) { $choice = 'exit' } else { $choice = $menu[$picked].Key }
        if ($choice -eq 'exit') { Write-Host 'Выход.'; exit 0 }
        if ($choice -eq 'deploy') {
            if ($UiChannel) { & (Join-Path $Root 'deploy.ps1') -UiChannel $UiChannel } else { & (Join-Path $Root 'deploy.ps1') }
            exit $LASTEXITCODE
        }
        if ($choice -eq 'rollback') {
            if ($UiChannel) { & (Join-Path $Root 'deploy.ps1') -Rollback -UiChannel $UiChannel } else { & (Join-Path $Root 'deploy.ps1') -Rollback }
            exit $LASTEXITCODE
        }
        if ($choice -eq 'cmpext' -or $choice -eq 'cmpepf') {
            # Только чтение: разница temp и рабочей - и обратно в меню.
            $compareArgs = @{ CompareExtensions = ($choice -eq 'cmpext'); CompareProcessings = ($choice -eq 'cmpepf') }
            if ($UiChannel) { $compareArgs['UiChannel'] = $UiChannel }
            try { & (Join-Path $Root 'deploy.ps1') @compareArgs }
            catch { Write-Host ("Не получилось: {0}" -f $_.Exception.Message) -ForegroundColor Red }
            Wait-UiAcknowledge
            continue
        }
        if ($choice -eq 'basestate') {
            # Только чтение: блокировки и сеансы temp и рабочей - и обратно в меню.
            try {
                if ($UiChannel) { & (Join-Path $Root 'deploy.ps1') -BaseState -UiChannel $UiChannel } else { & (Join-Path $Root 'deploy.ps1') -BaseState }
            }
            catch { Write-Host ("Не получилось: {0}" -f $_.Exception.Message) -ForegroundColor Red }
            Wait-UiAcknowledge
            continue
        }
        if ($choice -eq 'pullext' -or $choice -eq 'pullepf') {
            # Взять из рабочей в inbox и вернуться в меню: новое уже в списке «Прогон с обновлением из inbox».
            $pullArgs = @{ PullExtensions = ($choice -eq 'pullext'); PullProcessings = ($choice -eq 'pullepf') }
            if ($UiChannel) { $pullArgs['UiChannel'] = $UiChannel }
            try { & (Join-Path $Root 'deploy.ps1') @pullArgs }
            catch { Write-Host ("Не получилось: {0}" -f $_.Exception.Message) -ForegroundColor Red }
            Wait-UiAcknowledge
            continue
        }
        if ($choice -eq 'settings') {
            # Настройки читаются при старте скрипта: после правки меню начинается заново.
            if ($UiChannel) { & (Join-Path $Root 'settings.ps1') -UiChannel $UiChannel } else { & (Join-Path $Root 'settings.ps1') }
            Write-Host 'Чтобы гейт взял новые настройки, запусти его заново (в ci - Enter).'
            exit 0
        }
        if ($choice -eq 'accept') {
            $null = Invoke-AcceptFromMenu -Run $acceptable
            Wait-UiAcknowledge
            continue
        }
        if ($choice -eq 'stats') {
            Show-UiPager -Lines @(Get-StatReportLines) -Header 'Статистика длительностей шагов'
            continue
        }
        if ($choice -ne 'runs') { break }
        Show-RecentRuns
    }

    if ($choice -eq 'kit') {
        # Отметить обновления. У одного расширения или обработки - одно обновление: два экземпляра в комплекте нельзя.
        $shown = @($usable)
        $labels = @($shown | ForEach-Object { '{0}  {1}' -f $_.Relative, $_.Note })
        $notes = @($unusable | ForEach-Object { 'недоступно: {0} - {1}' -f $_.Relative, $_.Note })
        $preselected = @()
        while ($true) {
            $kitGroups = @($shown | ForEach-Object { @($_.Names) -join '|' })
            $picked = Select-UiMany -Header 'Что грузим в erp_temp' -Items $labels -Preselected $preselected -Notes $notes -Groups $kitGroups
            if ($null -eq $picked) { Write-Host 'Отмена.'; exit 0 }
            $selectedItems = @($picked | ForEach-Object { $shown[$_] })
            $seen = @{}
            $clash = ''
            foreach ($item in $selectedItems) {
                foreach ($name in @($item.Names)) {
                    if ($seen.ContainsKey($name)) { $clash = $name }
                    $seen[$name] = $true
                }
            }
            if (-not $clash) { break }
            Write-Host ("  {0} отмечено дважды: оставь одно обновление." -f $clash) -ForegroundColor Yellow
            $preselected = @($picked)
        }
        $script:MenuItems = @($selectedItems)
    }
}
$checkOnly = @(Get-Setting $cfg 'CheckOnly' @() | Where-Object { $_ })

$timeoutLoadSec = 60 * [int](Get-Setting $cfg 'TimeoutLoadMin' 30)
$timeoutUpdateSec = 60 * [int](Get-Setting $cfg 'TimeoutUpdateMin' 120)
$timeoutCheckSec = 60 * [int](Get-Setting $cfg 'TimeoutCheckMin' 120)

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$runsRoot = Resolve-RootPath ([string](Get-Setting $cfg 'RunsDir' 'runs'))
$RunDir = Join-Path $runsRoot $runId
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
$script:RunLogPath = Join-Path $RunDir 'run.log'
$script:Steps = New-Object System.Collections.Generic.List[object]
if ($script:SiteSettingKeys.Count -gt 0) { Write-RunLog ("Настройки площадки из config.site.psd1: {0}" -f ($script:SiteSettingKeys -join ', ')) }
$baselineDir = Join-Path (Join-Path $Root 'baseline') $baseKey

$adminUser = [string](Get-Setting $cfg 'AdminUser' '')
$adminPassword = Get-PlainPassword ([string](Get-Setting $cfg 'AdminPassFile' ''))
$designerBase = @('DESIGNER') + @(Get-ConnectionArgs -User $adminUser -Password $adminPassword) +
    @('/DisableStartupDialogs', '/DisableStartupMessages')

# Самопроверка: обработка «Выполнить после обновления» в режиме автозапуска. Запускается под той же учёткой,
# что и конфигуратор: обработке нужны полные права.
$runSelfCheck = [bool](Get-Setting $cfg 'RunSelfCheck' $true)
$selfCheckEpf = Resolve-RootPath ([string](Get-Setting $cfg 'SelfCheckEpf' 'tools\ВыполнитьПослеОбновления.epf'))
$selfCheckDocs = [int](Get-Setting $cfg 'SelfCheckDocs' 3)
$selfCheckForms = [bool](Get-Setting $cfg 'SelfCheckForms' $true)
$selfCheckPost = [bool](Get-Setting $cfg 'SelfCheckPost' $true)
$selfCheckSkipDocs = ([string](Get-Setting $cfg 'SelfCheckSkipDocs' '')).Trim()
$selfCheckNotOlder = ([string](Get-Setting $cfg 'SelfCheckNotOlder' '')).Trim()
$selfCheckTimeoutSec = 60 * [int](Get-Setting $cfg 'SelfCheckTimeoutMin' 120)
$selfCheckStallSec = 60 * [int](Get-Setting $cfg 'SelfCheckStallMin' 20)
$selfCheckStartTimeoutSec = [int](Get-Setting $cfg 'SelfCheckStartTimeoutSec' 300)
$selfCheckRestarts = [int](Get-Setting $cfg 'SelfCheckRestarts' 2)
if (($selfCheckSkipDocs + $selfCheckNotOlder + $RunDir + $selfCheckEpf) -match '[;"]') {
    throw 'В SelfCheckSkipDocs, SelfCheckNotOlder, пути к обработке самопроверки и пути к папке прогонов не должно быть точки с запятой и кавычек.'
}

# Эталон самопроверки базы: записи последнего состояния, в котором не было ничего нового.
# В selfcheck.last.txt - отпечаток состояния базы после последней самопроверки гейта.
$selfCheckReferenceFile = Join-Path $baselineDir 'selfcheck.norm.txt'
$selfCheckReferenceInfoFile = Join-Path $baselineDir 'selfcheck.info.txt'
$selfCheckLastFile = Join-Path $baselineDir 'selfcheck.last.txt'
# Эталонные снимки шагов самопроверки (сообщения обмена): с ними сравниваются снимки «после».
$selfCheckSnapshotsFile = Join-Path $baselineDir 'selfcheck.snapshots.txt'
# Эталон карты покрытия (что из доработок чем задето) и включатель шага.
$coverageReferenceFile = Join-Path $baselineDir 'coverage.txt'
$runCoverage = [bool](Get-Setting $cfg 'Coverage' $true)
# Шаг «Обмены» самопроверки (раздел 5.17): Full - объекты пакета, очередь узла и срезы пакета; Light - только объекты
# пакета. Лимиты очереди узла: на вид и всего. Итоги выгрузки по объектам - эталон selfcheck.exchange.txt.
$exchangeMode = ([string](Get-Setting $cfg 'ExchangeMode' 'Full')).Trim()
if (@('Full', 'Light') -notcontains $exchangeMode) {
    throw "Настройка ExchangeMode в config.psd1: допустимо Full или Light, а стоит «$exchangeMode»."
}
$exchangeQueuePerType = [int](Get-Setting $cfg 'ExchangeQueuePerType' 5)
$exchangeQueueTotal = [int](Get-Setting $cfg 'ExchangeQueueTotal' 50)
$selfCheckExchangeFile = Join-Path $baselineDir 'selfcheck.exchange.txt'
if ($baselineDir -match '[;"]') { throw 'В пути к папке эталонов не должно быть точки с запятой и кавычек.' }
# Проверка правил обмена по выгрузке расширений, без 1С (раздел 5.18): правила R1-R4, исключения площадки,
# расширения подрядчиков для R4. Эталон: состояние перехватов правил обмена и принятые замечания.
$runExchangeRules = [bool](Get-Setting $cfg 'ExchangeRules' $true)
$exchangeRuleExceptions = @(Get-Setting $cfg 'ExchangeRuleExceptions' @() | Where-Object { $_ })
$contractorExtensions = @(Get-Setting $cfg 'ContractorExtensions' @() | Where-Object { $_ })
$exchangeRulesStateFile = Join-Path $baselineDir 'exchange-rules.state.txt'
$exchangeRulesFindingsFile = Join-Path $baselineDir 'exchange-rules.findings.txt'
# Что изменилось в перехватах правил обмена (R3) и выгрузки расширений этого прогона (общие для карты покрытия
# и проверки правил обмена).
$script:ExchangeRulesChanged = @()
$script:ExtensionDumps = $null

$selfCheckOff = ''
if ($SkipSelfCheck) { $selfCheckOff = 'отключено ключом -SkipSelfCheck' }
elseif (-not $runSelfCheck) { $selfCheckOff = 'выключено в config.psd1 (RunSelfCheck)' }
elseif (-not (Test-Path -LiteralPath $selfCheckEpf)) { $selfCheckOff = "нет обработки $selfCheckEpf (как собрать, см. readme.txt)" }
elseif (-not (Test-Path -LiteralPath $v8c)) { $selfCheckOff = "нет тонкого клиента $v8c" }

# Что делать с загруженным комплектом, если вердикт красный или жёлтый с замечаниями:
# Ask - спросить, Keep - оставить в базе, Rollback - откатить. Ключ запуска важнее настройки.
$kitPolicy = $OnNotGreen
if (-not $kitPolicy) { $kitPolicy = [string](Get-Setting $cfg 'OnNotGreen' 'Ask') }
if (@('Ask', 'Keep', 'Rollback') -notcontains $kitPolicy) {
    throw "Настройка OnNotGreen в config.psd1: допустимо Ask, Keep или Rollback, а стоит «$kitPolicy»."
}

# Что делать, если перед началом прогона в базе есть сеансы: Ask - спросить, Continue - работать как есть,
# Exit - выйти, Terminate - поставить блокировку начала сеансов и завершить сеансы. Ключ запуска важнее настройки.
$sessionPolicy = $OnSessions
if (-not $sessionPolicy) { $sessionPolicy = [string](Get-Setting $cfg 'OnSessions' 'Ask') }
if (@('Ask', 'Continue', 'Exit', 'Terminate') -notcontains $sessionPolicy) {
    throw "Настройка OnSessions в config.psd1: допустимо Ask, Continue, Exit или Terminate, а стоит «$sessionPolicy»."
}
$sessionLockHours = [int](Get-Setting $cfg 'SessionLockHours' 2)
$script:JobsLockRelease = ([bool]$ReleaseJobsLock -or [bool](Get-Setting $cfg 'ReleaseJobsLock' $false))
if ($sessionLockHours -lt 1) { $sessionLockHours = 1 }

# Сюда перед загрузкой копируется эталон самопроверки: откат комплекта возвращает и его.
$referenceSnapshotDir = Join-Path $RunDir 'before-selfcheck'

Write-Host ''
Write-Host ("Прогон {0}, база {1}" -f $runId, $baseKey) -ForegroundColor Cyan
Write-Host ("Папка прогона: {0}" -f $RunDir)
Write-RunLog ("Прогон {0}, база {1}, комплект: {2}" -f $runId, $baseKey, $Kit)

function Resolve-TestDesignerBusy {
    # Конфигуратор тестовой базы открыт в другом сеансе - дальше идти нельзя, пока он открыт. Сначала - не наша ли
    # это параллельная проверка конфигурации: её дождаться. Потом вопрос: закрыть отсюда (только конфигураторы этой
    # базы) или ждать, пока закроют сами. Отмена - прогон завершается с записью «отменено пользователем».
    # Без человека (ночной запуск) - $false: шаг падает, как раньше.
    param([string]$Title)
    if ($null -ne $script:BackgroundCheck) {
        Write-Host ("  {0}: конфигуратор занят - возможно, нашей же параллельной проверкой конфигурации; дождусь её" -f $Title) -ForegroundColor Yellow
        Write-RunLog ("Конфигуратор занят ({0}): жду параллельную проверку конфигурации" -f $Title)
        Complete-BackgroundCheck
        return $true
    }
    if (-not (Test-UiCanAsk)) { return $false }
    # Сеансы - через агент сервера; файловая база или агент не ответил - без списка и без «закрыть отсюда».
    $link = $null
    $designers = @()
    try {
        $link = Connect-TestBaseAgent
        $designers = @(Get-TestBaseSessions $link | Where-Object { -not $_.IsError -and $_.IsDesigner })
    }
    catch { $link = $null; Write-Host ("  сеансы базы не прочитал: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
    Write-Host ("  {0}: открыт конфигуратор {1} - дальше нельзя, пока он открыт" -f $Title, $script:Base) -ForegroundColor Yellow
    foreach ($entry in $designers) { Write-Host ('    ' + $entry.Text) -ForegroundColor Yellow }
    $answer = Read-UiChoice -Header ("Открыт конфигуратор {0}: «{1}» не может идти дальше. Закрой его сам - гейт увидит и продолжит, или:" -f $script:Base, $Title) `
        -Keys @('1', '2') -Labels @('Закрыть отсюда (сеанс прерывается, несохранённые правки в нём пропадут)', 'Отмена (прогон завершится)') -CancelKey '2' -Poll {
        if ($null -eq $link) { return '' }
        $nowSessions = @(Get-TestBaseSessions $link)
        if (@($nowSessions | Where-Object { $_.IsError }).Count -eq 0 -and @($nowSessions | Where-Object { $_.IsDesigner }).Count -eq 0) { return 'closed' }
        return ''
    }
    if ($answer -eq '2') {
        Write-RunLog ("Отменено пользователем: открыт конфигуратор {0} ({1})" -f $script:Base, $Title)
        throw ("отменено пользователем: открыт конфигуратор {0}, «{1}» не выполнено" -f $script:Base, $Title)
    }
    if ($answer -eq '1' -and $null -ne $link) {
        foreach ($line in @(Stop-TestBaseSessions -Link $link -Designers)) { Write-Host ('  ' + $line) }
        for ($wait = 0; $wait -lt 10; $wait++) {
            Start-Sleep -Seconds 3
            if (@(Get-TestBaseSessions $link | Where-Object { -not $_.IsError -and $_.IsDesigner }).Count -eq 0) { break }
        }
    }
    Write-Host ("  конфигуратор {0} закрыт, повторяю: {1}" -f $script:Base, $Title) -ForegroundColor Green
    Write-RunLog ("Конфигуратор {0} закрыт ({1}), повтор: {2}" -f $script:Base, $answer, $Title)
    return $true
}

function Invoke-Designer {
    # Пакетный конфигуратор тестовой базы. Она открыта в другом конфигураторе - вопрос (Resolve-TestDesignerBusy)
    # и повтор той же команды.
    param([string[]]$Command, [string]$LogName, [int]$TimeoutSec, [string]$Title = '')
    $logPath = Join-Path $RunDir $LogName
    $argList = $designerBase + $Command + @('/Out', ('"{0}"' -f $logPath))
    while ($true) {
        $result = Invoke-V8 -Exe $v8 -Arguments $argList -TimeoutSec $TimeoutSec -Title $Title
        $lines = @(Read-V8Log $logPath)
        if ($result.ExitCode -eq 0 -or $result.TimedOut -or -not (Test-DesignerBusy $lines)) { break }
        $busyTitle = $Title
        if (-not $busyTitle) { $busyTitle = $LogName }
        if (-not (Resolve-TestDesignerBusy -Title $busyTitle)) { break }
    }
    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        TimedOut = $result.TimedOut
        Seconds  = $result.Seconds
        Log      = $logPath
        Lines    = $lines
    }
}

function Start-DesignerBackground {
    # Конфигуратор с командой - без ожидания: процесс идёт параллельно со следующими шагами.
    # Итог берёт Complete-BackgroundCheck. Тот же журнал вызова и маскировка паролей, что у Invoke-V8.
    param([string[]]$Command, [string]$LogName, [int]$TimeoutSec, [string]$Title, [string]$FileKey)
    $logPath = Join-Path $RunDir $LogName
    $argLine = ($designerBase + $Command + @('/Out', ('"{0}"' -f $logPath))) -join ' '
    Write-RunLog ("> {0} {1} (параллельно)" -f (Split-Path -Leaf $v8), [regex]::Replace([regex]::Replace($argLine, '/P"[^"]*"', '/P"***"'), '/UC"[^"]*"', '/UC"***"'))
    Write-Host ("  ...  {0}: начато в {1}, идёт параллельно с остальными шагами, итог - перед вердиктом" -f $Title, (Get-Date -Format 'HH:mm:ss')) -ForegroundColor DarkGray
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $v8 -ArgumentList $argLine -PassThru
    $null = $process.Handle
    return [pscustomobject]@{
        Process = $process; Watch = $watch; Log = $logPath; TimeoutSec = $TimeoutSec; Title = $Title; FileKey = $FileKey
        Expected = [double](Get-ExpectedStepSeconds $Title)
    }
}

function Complete-BackgroundCheck {
    # Ждёт параллельную проверку конфигурации (в пределах её таймаута от начала) и оценивает её, как Add-CheckStep.
    $background = $script:BackgroundCheck
    $finished = Wait-UiProcess -Process $background.Process -Watch $background.Watch -TimeoutSec $background.TimeoutSec -Title $background.Title -Expected $background.Expected
    $exitCode = $null
    if ($finished) { $background.Process.WaitForExit(); $exitCode = $background.Process.ExitCode }
    else { try { Stop-Process -Id $background.Process.Id -Force -ErrorAction Stop } catch { } }
    $background.Watch.Stop()
    $seconds = [int]$background.Watch.Elapsed.TotalSeconds
    Write-RunLog ("  {0}: код={1} таймаут={2} секунд={3}" -f $background.Title, $exitCode, (-not $finished), $seconds)
    $statStatus = 'FAIL'
    if (-not $finished) { $statStatus = 'TIMEOUT' } elseif ($exitCode -eq 0 -or $exitCode -eq 101) { $statStatus = 'OK' }
    Add-StatFact -Title $background.Title -Seconds $background.Watch.Elapsed.TotalSeconds -Status $statStatus
    $script:BackgroundCheck = $null
    $result = [pscustomobject]@{ ExitCode = $exitCode; TimedOut = (-not $finished); Seconds = $seconds; Log = $background.Log; Lines = @(Read-V8Log $background.Log) }
    Add-CheckStep -Name $background.Title -Result $result -FileKey $background.FileKey -Blocking $true
}

function Get-RunRemainingSeconds {
    # Сколько ещё идти прогону: ожидаемое время шагов плана, которых ещё нет в итогах, минус то, что текущий шаг
    # уже прошёл. Параллельная проверка конфигурации считается отдельно: осталось - большее из двух.
    # Unknown - сколько оставшихся шагов без статистики (их время в оценку не входит).
    param([string]$Title, [double]$Elapsed, [double]$Expected)
    $doneNames = @($script:Steps | ForEach-Object { [string]$_.name })
    $sequential = 0.0
    $unknown = 0
    $currentSeen = $false
    $backgroundTitle = ''
    if ($null -ne $script:BackgroundCheck) { $backgroundTitle = [string]$script:BackgroundCheck.Title }
    foreach ($name in @($script:RunPlanExpected.Keys)) {
        if ($name -eq $backgroundTitle -or $name.StartsWith('Подготовка')) { continue }
        $isDone = $false
        foreach ($doneName in $doneNames) {
            if ($doneName.StartsWith($name, [System.StringComparison]::OrdinalIgnoreCase) -or $name.StartsWith($doneName, [System.StringComparison]::OrdinalIgnoreCase)) { $isDone = $true; break }
        }
        if ($isDone) { continue }
        $planned = [double]$script:RunPlanExpected[$name]
        if (-not $currentSeen -and $Title -and ($Title.StartsWith($name, [System.StringComparison]::OrdinalIgnoreCase) -or $name.StartsWith($Title, [System.StringComparison]::OrdinalIgnoreCase))) {
            $currentSeen = $true
            $currentExpected = [Math]::Max($planned, $Expected)
            if ($currentExpected -gt 0) { $sequential += [Math]::Max(0, $currentExpected - $Elapsed) } else { $unknown++ }
            continue
        }
        if ($planned -gt 0) { $sequential += $planned } else { $unknown++ }
    }
    $total = $sequential
    if ($null -ne $script:BackgroundCheck) {
        $backgroundLeft = [Math]::Max(0, $script:BackgroundCheck.Expected - $script:BackgroundCheck.Watch.Elapsed.TotalSeconds)
        if ($Title -eq $backgroundTitle) { $backgroundLeft = [Math]::Max(0, [Math]::Max($script:BackgroundCheck.Expected, $Expected) - $Elapsed) }
        $total = [Math]::Max($sequential, $backgroundLeft)
    }
    return [pscustomobject]@{ Seconds = [int]$total; Unknown = $unknown }
}

function Split-KitName {
    # Из имени вида <база>_<расширение>_<дата> достаёт базу-источник и метку выгрузки. Чего нет, то пустое.
    param([string]$ItemName, [string]$ExtensionName)
    $source = ''
    $label = ''
    $position = $ItemName.IndexOf($ExtensionName, [System.StringComparison]::OrdinalIgnoreCase)
    if ($position -ge 0) {
        $source = $ItemName.Substring(0, $position).Trim('_', ' ', '-')
        $label = $ItemName.Substring($position + $ExtensionName.Length).Trim('_', ' ', '-')
    }
    return [pscustomobject]@{ Source = $source; Label = $label }
}

function Add-SimpleStep {
    # Шаг «сделал или не сделал»: загрузка, обновление, выгрузка.
    param([string]$Name, $Result, [bool]$Blocking)
    $badStatus = 'WARN'
    if ($Blocking) { $badStatus = 'FAIL' }
    if ($Result.TimedOut) {
        Add-StepResult -Name $Name -Status $badStatus -Detail 'таймаут, процесс снят' -Log $Result.Log -Seconds $Result.Seconds
        return $false
    }
    if ($Result.ExitCode -eq 0) {
        Add-StepResult -Name $Name -Status 'OK' -Detail ("{0} с" -f $Result.Seconds) -Log $Result.Log -Seconds $Result.Seconds
        return $true
    }
    if (Test-DesignerBusy $Result.Lines) {
        $script:StopRun = $true
        $detail = "конфигуратор этой базы открыт в другом сеансе: закрой его и запусти прогон заново. {0}" -f (Get-LogTail $Result.Lines 2)
        Add-StepResult -Name $Name -Status 'FAIL' -Detail $detail -Log $Result.Log -Seconds $Result.Seconds
        return $false
    }
    $detail = "код {0}: {1}" -f $Result.ExitCode, (Get-LogTail $Result.Lines)
    Add-StepResult -Name $Name -Status $badStatus -Detail $detail -Log $Result.Log -Seconds $Result.Seconds
    return $false
}

function Add-CheckStep {
    # Шаг проверки. Оценивается не код возврата, а новые относительно эталона записи:
    # ошибки компиляции, неразрешимые ссылки и всё незнакомое блокируют, «возможно ошибочное» только предупреждает.
    param([string]$Name, $Result, [string]$FileKey, [bool]$Blocking)
    $badStatus = 'WARN'
    if ($Blocking) { $badStatus = 'FAIL' }

    $records = @(ConvertTo-CheckRecords $Result.Lines)
    [System.IO.File]::WriteAllLines((Join-Path $RunDir ($FileKey + '.norm.txt')), [string[]]$records, $Utf8Bom)

    if ($Result.TimedOut) {
        Add-StepResult -Name $Name -Status $badStatus -Detail 'таймаут, процесс снят' -Log $Result.Log -Seconds $Result.Seconds
        return
    }
    if (Test-DesignerBusy $Result.Lines) {
        $script:StopRun = $true
        $detail = "конфигуратор этой базы открыт в другом сеансе: закрой его и запусти прогон заново. {0}" -f (Get-LogTail $Result.Lines 2)
        Add-StepResult -Name $Name -Status 'FAIL' -Detail $detail -Log $Result.Log -Seconds $Result.Seconds
        return
    }
    # 0 - чисто, 101 - проверка выполнена и нашла замечания. Любой другой код - проверка не выполнилась.
    if ($Result.ExitCode -ne 0 -and $Result.ExitCode -ne 101) {
        $detail = "код {0}, проверка не выполнилась: {1}" -f $Result.ExitCode, (Get-LogTail $Result.Lines 3)
        Add-StepResult -Name $Name -Status $badStatus -Detail $detail -Log $Result.Log -Seconds $Result.Seconds
        return
    }

    $comparison = Compare-WithBaseline -Current $records -BaselineFile (Join-Path $baselineDir ($FileKey + '.norm.txt'))

    if (-not $comparison.HasBaseline) {
        if ($records.Count -eq 0) {
            Add-StepResult -Name $Name -Status 'OK' -Detail ("замечаний нет, {0} с" -f $Result.Seconds) -Log $Result.Log -Seconds $Result.Seconds
            return
        }
        $detail = "замечаний: {0}, эталона нет. Посмотри лог и прими эталон: дальше будет видно только новое" -f $records.Count
        Add-StepResult -Name $Name -Status $badStatus -Detail $detail -Log $Result.Log -Seconds $Result.Seconds
        return
    }

    $newRed = New-Object System.Collections.Generic.List[string]
    $newYellow = New-Object System.Collections.Generic.List[string]
    $kindCounts = [ordered]@{}
    foreach ($record in $comparison.NewLines) {
        $kind = Get-RecordKind $record
        if ($kind.Red) { $newRed.Add($record) } else { $newYellow.Add($record) }
        if ($kindCounts.Contains($kind.Kind)) { $kindCounts[$kind.Kind] = $kindCounts[$kind.Kind] + 1 } else { $kindCounts[$kind.Kind] = 1 }
    }
    $knownNow = $records.Count - $comparison.NewLines.Count
    $tail = "известных: {0}" -f $knownNow
    if ($comparison.GoneCount -gt 0) { $tail += (", ушло из эталона: {0}" -f $comparison.GoneCount) }

    if ($comparison.NewLines.Count -eq 0) {
        Add-StepResult -Name $Name -Status 'OK' -Detail ("новых замечаний нет, {0}, {1} с" -f $tail, $Result.Seconds) -Log $Result.Log -Seconds $Result.Seconds
        return
    }

    # Блокирующие в начале файла.
    $newOrdered = @($newRed.ToArray()) + @($newYellow.ToArray())
    [System.IO.File]::WriteAllLines((Join-Path $RunDir ($FileKey + '.new.txt')), [string[]]$newOrdered, $Utf8Bom)

    $kindText = (@($kindCounts.Keys | ForEach-Object { "{0}: {1}" -f $_, $kindCounts[$_] }) -join ', ')
    $sample = (@($newOrdered | Select-Object -First 3 | ForEach-Object { if ($_.Length -gt 220) { $_.Substring(0, 220) + '...' } else { $_ } }) -join ' | ')
    $detail = "новых замечаний: {0} ({1}), файл {2}.new.txt; {3}. {4}" -f $comparison.NewLines.Count, $kindText, $FileKey, $tail, $sample
    if ($newRed.Count -gt 0) {
        Add-StepResult -Name $Name -Status $badStatus -Detail $detail -Log $Result.Log -Seconds $Result.Seconds
    }
    else {
        Add-StepResult -Name $Name -Status 'WARN' -Detail $detail -Log $Result.Log -Seconds $Result.Seconds
    }
}

function Save-SelfCheckReference {
    # Записи прогона становятся эталоном самопроверки этой базы.
    # Снимки шагов становятся эталонными вместе с записями. Снимков нет - эталонных снимков тоже нет.
    # Итоги пробной выгрузки шага «Обмены» - тоже: с ними сравнивается следующий прогон, когда «до» не снимается.
    param([string[]]$Records, [string]$Label, [string]$Fingerprint, $Snapshots = $null, $Exchange = $null)
    if (-not (Test-Path -LiteralPath $baselineDir)) { New-Item -ItemType Directory -Path $baselineDir -Force | Out-Null }
    [System.IO.File]::WriteAllLines($selfCheckReferenceFile, [string[]]@($Records), $Utf8Bom)
    if ($null -ne $Snapshots -and $Snapshots.Count -gt 0) { Write-SelfCheckSnapshots -Snapshots $Snapshots -Path $selfCheckSnapshotsFile }
    elseif (Test-Path -LiteralPath $selfCheckSnapshotsFile) { Remove-Item -LiteralPath $selfCheckSnapshotsFile -Force }
    if ($null -ne $Exchange -and $Exchange.Count -gt 0) { Write-ExchangeResults -Results $Exchange -Path $selfCheckExchangeFile }
    elseif (Test-Path -LiteralPath $selfCheckExchangeFile) { Remove-Item -LiteralPath $selfCheckExchangeFile -Force }
    $info = @(
        ("run={0}" -f $runId),
        ("label={0}" -f $Label),
        ("fingerprint={0}" -f $Fingerprint),
        ("time={0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    )
    [System.IO.File]::WriteAllLines($selfCheckReferenceInfoFile, [string[]]$info, $Utf8Bom)
    Write-RunLog ("Эталон самопроверки обновлён: {0}, записей {1}" -f $Label, @($Records).Count)
}

function Save-SelfCheckLastState {
    # Отпечаток состояния базы после самопроверки гейта. Пока он не изменился, состояние «до загрузки»
    # заново не снимается. Пустой (ненадёжный) отпечаток стирает прежний: тогда «до» снимается каждый раз.
    param([string]$Fingerprint)
    if (-not (Test-Path -LiteralPath $baselineDir)) { New-Item -ItemType Directory -Path $baselineDir -Force | Out-Null }
    if ($Fingerprint) {
        $lastState = @(("fingerprint={0}" -f $Fingerprint), ("run={0}" -f $runId))
        [System.IO.File]::WriteAllLines($selfCheckLastFile, [string[]]$lastState, $Utf8Bom)
    }
    elseif (Test-Path -LiteralPath $selfCheckLastFile) {
        Remove-Item -LiteralPath $selfCheckLastFile -Force
    }
}

function Invoke-SelfCheckSession {
    # Один сеанс обработки «Выполнить после обновления» в режиме автозапуска.
    # Чем кончился: result - обработка записала итог; exited - клиент закрылся без итога;
    # nostart - обработка не открылась; stalled - новых частей журнала нет дольше SelfCheckStallMin;
    # timeout - сеанс идёт дольше SelfCheckTimeoutMin.
    param([string]$OutDir, [string]$Known, [int]$StartFrom, [string]$Title, [string]$ExchangeSetFile = '')

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

    $launch = New-Object System.Collections.Generic.List[string]
    $launch.Add('selfcheck')
    $launch.Add(("out={0}" -f $OutDir))
    $launch.Add(("docs={0}" -f $selfCheckDocs))
    if (-not $selfCheckForms) { $launch.Add('forms=0') }
    if (-not $selfCheckPost) { $launch.Add('post=0') }
    if ($selfCheckSkipDocs) { $launch.Add(("skip={0}" -f $selfCheckSkipDocs)) }
    if ($selfCheckNotOlder) { $launch.Add(("notolder={0}" -f $selfCheckNotOlder)) }
    if ($Known) { $launch.Add(("known={0}" -f $Known)) }
    if ($StartFrom -gt 0) { $launch.Add(("start={0}" -f $StartFrom)) }
    # Шаг «Обмены»: режим, лимиты очереди узла и набор объектов прогона «до» (тот же набор для «после»).
    if ($exchangeMode -eq 'Light') { $launch.Add('exchmode=light') }
    $launch.Add(("exchq={0}/{1}" -f $exchangeQueuePerType, $exchangeQueueTotal))
    if ($ExchangeSetFile) { $launch.Add(("exch={0}" -f $ExchangeSetFile)) }

    $argList = @('ENTERPRISE') + @(Get-ConnectionArgs -User $adminUser -Password $adminPassword) + @(
        '/DisableStartupDialogs',
        '/DisableStartupMessages',
        '/Execute', ('"{0}"' -f $selfCheckEpf),
        ('/C"{0}"' -f ($launch.ToArray() -join ';'))
    )
    $argLine = $argList -join ' '
    Write-RunLog ("> 1cv8c.exe {0}" -f ([regex]::Replace([regex]::Replace($argLine, '/P"[^"]*"', '/P"***"'), '/UC"[^"]*"', '/UC"***"')))

    $resultFile = Join-Path $OutDir 'result.txt'
    $startedFile = Join-Path $OutDir 'started.txt'

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $idle = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $v8c -ArgumentList $argLine -PassThru
    $null = $process.Handle

    $state = ''
    $started = $false
    $pieceCount = -1
    $progressShown = $false
    while ($true) {
        if (Test-Path -LiteralPath $resultFile) { $state = 'result'; break }
        if ($process.HasExited) {
            # Итог мог записаться в последний момент.
            Start-Sleep -Seconds 2
            if (Test-Path -LiteralPath $resultFile) { $state = 'result' } else { $state = 'exited' }
            break
        }
        if (-not $started) {
            if (Test-Path -LiteralPath $startedFile) { $started = $true; $idle.Restart() }
            elseif ($watch.Elapsed.TotalSeconds -ge $selfCheckStartTimeoutSec) { $state = 'nostart'; break }
        }
        else {
            $countNow = @(Get-SelfCheckPieceFiles $OutDir).Count
            if ($countNow -ne $pieceCount) { $pieceCount = $countNow; $idle.Restart() }
            elseif ($idle.Elapsed.TotalSeconds -ge $selfCheckStallSec) { $state = 'stalled'; break }
            if ($watch.Elapsed.TotalSeconds -ge $selfCheckTimeoutSec) { $state = 'timeout'; break }
        }

        # Ход: какое задание из скольких - по последней части журнала; полоса настоящая.
        $progress = 'клиент запускается'
        if ($started) { $progress = 'обработка открылась, готовит задания' }
        $done = -1
        $total = 0
        $files = @(Get-SelfCheckPieceFiles $OutDir)
        if ($files.Count -gt 0) {
            try {
                $lastPiece = Read-SelfCheckPiece $files[$files.Count - 1].FullName
                if ($lastPiece.Header.ContainsKey('n')) {
                    $done = [int]$lastPiece.Header['n']
                    $total = [int]$lastPiece.Header['total']
                    $progress = "задание {0} из {1}: {2}" -f ($done + 1), $total, $lastPiece.Header['title']
                }
                if ($lastPiece.Blocks.Count -gt 0) {
                    Send-UiSubPlan -Title $Title -Current ([string]$lastPiece.Header['step']) -Task ([string]$lastPiece.Header['title']) -Blocks $lastPiece.Blocks
                }
            }
            catch { }
        }
        # 3 секунды до следующей проверки файлов - анимация строки хода.
        for ($frame = 0; $frame -lt 12; $frame++) {
            Write-UiProgress -Title $Title -Elapsed $watch.Elapsed.TotalSeconds -Expected (Get-ExpectedStepSeconds $Title) -Done $done -Total $total -Detail $progress
            $progressShown = $true
            if ($process.HasExited -or (Test-Path -LiteralPath $resultFile)) { break }
            Start-Sleep -Milliseconds 250
        }
    }
    if ($progressShown) { Complete-UiProgress }

    $windows = @()
    if ($state -eq 'result') {
        # После записи итога обработка закрывает 1С сама.
        if (-not $process.WaitForExit(60000)) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
        }
    }
    elseif ($state -ne 'exited') {
        # Сначала снимаем окна клиента, потом закрываем его.
        $windows = @(Save-ProcessWindows -ProcessId $process.Id -FilePrefix (Join-Path $OutDir 'client'))
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
        [System.IO.File]::WriteAllLines((Join-Path $OutDir 'client_windows.txt'), [string[]]$windows, $Utf8Bom)
    }
    $watch.Stop()
    # Сеанс на сервере закрывается не мгновенно: следующий шаг не должен на него наткнуться.
    Start-Sleep -Seconds 5

    # Последняя целая часть журнала говорит, какое задание выполнялось.
    $lastN = -1
    $lastKey = ''
    $lastTitle = ''
    $total = 0
    $files = @(Get-SelfCheckPieceFiles $OutDir)
    for ($index = $files.Count - 1; $index -ge 0; $index--) {
        $piece = $null
        try { $piece = Read-SelfCheckPiece $files[$index].FullName } catch { continue }
        if (-not $piece.Complete) { continue }
        if ($piece.Header.ContainsKey('n')) {
            $lastN = [int]$piece.Header['n']
            $lastKey = [string](Get-Setting $piece.Header 'key' '')
            $lastTitle = [string](Get-Setting $piece.Header 'title' '')
            $total = [int](Get-Setting $piece.Header 'total' 0)
        }
        break
    }

    Write-RunLog ("  самопроверка: сеанс кончился как {0}, секунд {1}, частей журнала {2}, последнее задание {3}" -f $state, [int]$watch.Elapsed.TotalSeconds, $files.Count, $lastN)
    # Статистика: целый прогон самопроверки - OK, продолжение после остановки - PART (в прогноз не идёт),
    # «база та же, не запускалась» - SKIP. Размер - число заданий.
    $statStatus = 'FAIL'
    if ($state -eq 'result') {
        $statStatus = 'OK'
        if ($StartFrom -gt 0) { $statStatus = 'PART' }
        if ([string](Get-Setting (Read-KeyValueFile $resultFile) 'status' '') -ne 'done') { $statStatus = 'SKIP' }
    }
    Add-StatFact -Title $Title -Seconds $watch.Elapsed.TotalSeconds -Status $statStatus -Size $total

    return [pscustomobject]@{
        State      = $state
        Dir        = $OutDir
        Seconds    = [int]$watch.Elapsed.TotalSeconds
        Result     = (Read-KeyValueFile $resultFile)
        Info       = (Read-KeyValueFile (Join-Path $OutDir 'info.txt'))
        Windows    = $windows
        LastN      = $lastN
        LastKey    = $lastKey
        LastTitle  = $lastTitle
        Total      = $total
        PieceCount = $files.Count
    }
}

function Invoke-SelfCheck {
    # Самопроверка базы целиком: сеансы обработки с перезапуском после зависшего задания, сборка журнала
    # и записей для сравнения. Итог: done - выполнена; same - база не менялась, не запускалась;
    # incomplete - выполнена не до конца; nostart, refused, failed - не выполнялась.
    param([string]$Label, [string]$Known, [string]$Title, [string]$ExchangeSetFile = '')

    $baseDir = Join-Path $RunDir ("selfcheck-{0}" -f $Label)
    $sessions = New-Object System.Collections.Generic.List[object]
    $problems = New-Object System.Collections.Generic.List[string]
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $state = ''
    $startFrom = 0
    $attempt = 0

    Write-Host ("  ...  {0}: начато в {1}; сеанс не дольше {2} мин, без движения не дольше {3} мин" -f $Title, (Get-Date -Format 'HH:mm:ss'), [int]($selfCheckTimeoutSec / 60), [int]($selfCheckStallSec / 60)) -ForegroundColor DarkGray

    while ($true) {
        $attempt++
        $knownNow = ''
        if ($attempt -eq 1) { $knownNow = $Known }
        $session = Invoke-SelfCheckSession -OutDir (Join-Path $baseDir ("try{0}" -f $attempt)) -Known $knownNow -StartFrom $startFrom -Title $Title -ExchangeSetFile $ExchangeSetFile
        $sessions.Add($session)

        if ($session.State -eq 'result') {
            $state = [string](Get-Setting $session.Result 'status' 'failed')
            break
        }
        if ($session.State -eq 'nostart') { $state = 'nostart'; break }

        # Сеанс оборвался: завис, вышло время или клиент закрылся.
        $place = 'до первого задания'
        if ($session.LastN -ge 0) { $place = "на задании {0} из {1}: {2}" -f ($session.LastN + 1), $session.Total, $session.LastTitle }
        $what = 'клиент 1С закрылся без итога'
        if ($session.State -eq 'stalled') { $what = "нет движения {0} мин, клиент остановлен" -f [int]($selfCheckStallSec / 60) }
        if ($session.State -eq 'timeout') { $what = "сеанс идёт дольше {0} мин, клиент остановлен" -f [int]($selfCheckTimeoutSec / 60) }
        $problem = "сеанс {0}: {1} {2}" -f $attempt, $what, $place
        if ($session.Windows.Count -gt 0) { $problem += ("; окна клиента: {0}" -f ($session.Windows -join '; ')) }
        $problems.Add($problem)

        if ($session.State -eq 'timeout' -or $session.LastN -lt 0 -or $attempt -gt $selfCheckRestarts) { $state = 'incomplete'; break }
        $startFrom = $session.LastN + 1
        Write-Host ("       {0} {1}. Перезапускаю со следующего задания" -f $what, $place) -ForegroundColor Yellow
    }

    # Обработка открылась, но не дошла ни до одного задания: это не «неполный прогон», а «не выполнялась».
    if ($state -eq 'incomplete' -and $sessions.Count -eq 1 -and $sessions[0].LastN -lt 0) { $state = 'failed' }

    # Журнал и записи собираются из частей всех сеансов. Строки части относятся к заданию,
    # которое объявила предыдущая часть.
    $journal = New-Object System.Collections.Generic.List[string]
    $records = New-Object System.Collections.Generic.List[string]
    $snapshots = [ordered]@{}
    $metrics = @{}
    $exchange = [ordered]@{}
    $number = 0
    foreach ($session in $sessions) {
        $number++
        if ($sessions.Count -gt 1) { $journal.Add(("##### сеанс {0} #####" -f $number)) }
        $key = '(начало)'
        foreach ($file in @(Get-SelfCheckPieceFiles $session.Dir)) {
            $piece = $null
            try { $piece = Read-SelfCheckPiece $file.FullName }
            catch {
                $problems.Add(("сеанс {0}: часть журнала {1} не прочитана" -f $number, $file.Name))
                continue
            }
            foreach ($line in $piece.Body) { $journal.Add($line) }
            foreach ($record in @(ConvertTo-SelfCheckRecords -Key $key -Lines $piece.Body)) { $records.Add($record) }
            foreach ($snapKey in @($piece.Snapshots.Keys)) {
                # «время|...» - замер длительности операции: не снимок, а число миллисекунд (шаг «Время ключевых операций»).
                if ($snapKey.StartsWith('время|')) {
                    $msText = (@($piece.Snapshots[$snapKey]) -join '').Trim()
                    $msValue = 0
                    if ([int]::TryParse($msText, [ref]$msValue)) { $metrics[$snapKey.Substring(6)] = $msValue }
                    continue
                }
                # «выгрузка|<узел>|<объект>|<УИД>» - итог пробной выгрузки объекта в шаге «Обмены»: ok или fail
                # и описание ошибки. Не снимок: по этим итогам сравниваются «до» и «после» (Compare-ExchangeResults).
                if ($snapKey.StartsWith('выгрузка|')) {
                    $exchangeLines = @($piece.Snapshots[$snapKey] | Where-Object { $null -ne $_ })
                    $exchangeState = 'fail'
                    if ($exchangeLines.Count -gt 0 -and ([string]$exchangeLines[0]).Trim() -eq 'ok') { $exchangeState = 'ok' }
                    $exchangeText = ''
                    if ($exchangeLines.Count -gt 1) { $exchangeText = ((@($exchangeLines | Select-Object -Skip 1) -join ' ').Trim()) }
                    $exchange[$snapKey.Substring(9)] = [pscustomobject]@{ State = $exchangeState; Text = $exchangeText }
                    continue
                }
                $snapshots[$snapKey] = Format-SelfCheckSnapshot $piece.Snapshots[$snapKey]
            }
            if ($piece.Header.ContainsKey('key')) { $key = [string]$piece.Header['key'] }
            else { $key = '(конец)' }
        }
        if ($session.State -ne 'result' -and $session.LastN -ge 0) {
            # Задание, на котором сеанс оборвался, считается ошибкой этого задания.
            $records.Add(('[ОШИБКА] {0} :: {1}' -f $session.LastKey, $SelfCheckBrokenTask))
            $journal.Add(("{0} [ОШИБКА]   {1}: {2} (запись гейта)" -f (Get-Date -Format 'HH:mm:ss'), $session.LastTitle, $SelfCheckBrokenTask))
        }
        if ($session.State -eq 'result') {
            $writeErrors = [int](Get-Setting $session.Result 'writeerrors' 0)
            $declared = [int](Get-Setting $session.Result 'pieces' 0)
            if ($writeErrors -gt 0 -or $declared -ne $session.PieceCount) {
                $problems.Add(("сеанс {0}: журнал записан не полностью (частей по счёту обработки {1}, на диске {2}, ошибок записи {3})" -f $number, $declared, $session.PieceCount, $writeErrors))
            }
        }
    }

    $journalPath = Join-Path $RunDir ("selfcheck-{0}.journal.txt" -f $Label)
    [System.IO.File]::WriteAllLines($journalPath, $journal.ToArray(), $Utf8Bom)
    [System.IO.File]::WriteAllLines((Join-Path $RunDir ("selfcheck-{0}.norm.txt" -f $Label)), $records.ToArray(), $Utf8Bom)
    # Снимки шагов (сообщения обмена и т.п.) - уже приведённые к виду для сравнения. Файл пишется,
    # только если снимки есть: обработка прежней версии их не присылает.
    if ($snapshots.Count -gt 0) { Write-SelfCheckSnapshots -Snapshots $snapshots -Path (Join-Path $RunDir ("selfcheck-{0}.snapshots.txt" -f $Label)) }
    if ($exchange.Count -gt 0) { Write-ExchangeResults -Results $exchange -Path (Join-Path $RunDir ("selfcheck-{0}.exchange.txt" -f $Label)) }
    if ($metrics.Count -gt 0) {
        [System.IO.File]::WriteAllLines((Join-Path $RunDir ("selfcheck-{0}.metrics.txt" -f $Label)), [string[]]@($metrics.Keys | Sort-Object | ForEach-Object { '{0}{1}{2}' -f $metrics[$_], "`t", $_ }), $Utf8Bom)
    }

    # Отпечаток состояния базы на начало первого сеанса. Ненадёжный отпечаток не используется вовсе.
    $fingerprint = ''
    $firstInfo = $sessions[0].Info
    $candidate = [string](Get-Setting $firstInfo 'fingerprint' '')
    if ($candidate -match '^[0-9a-f]{64}$' -and [string](Get-Setting $firstInfo 'fingerprintreliable' '0') -eq '1') { $fingerprint = $candidate }

    $lastSession = $sessions[$sessions.Count - 1]
    $watch.Stop()
    return [pscustomobject]@{
        State       = $state
        Records     = $records.ToArray()
        Problems    = $problems.ToArray()
        Fingerprint = $fingerprint
        Seconds     = [int]$watch.Elapsed.TotalSeconds
        Journal     = $journalPath
        Snapshots   = $snapshots
        Metrics     = $metrics
        Exchange    = $exchange
        Message     = [string](Get-Setting $lastSession.Result 'message' '')
        Windows     = $lastSession.Windows
        Sessions    = $sessions.Count
    }
}

function Get-SelfCheckFailure {
    # Почему самопроверка не выполнялась вовсе: текст для вердикта.
    param($Run)
    if ($Run.State -eq 'nostart') {
        $text = "обработка не открылась за {0} с: нет файла started.txt (нет права открывать внешние обработки, включена защита от опасных действий, либо сеанс не стартовал)" -f $selfCheckStartTimeoutSec
        if ($Run.Windows.Count -gt 0) { $text += ("; окна клиента: {0}" -f ($Run.Windows -join '; ')) }
        return $text
    }
    if ($Run.State -eq 'refused') { return ("обработка отказалась работать: {0}" -f $Run.Message) }
    $reason = $Run.Message
    if ([string]::IsNullOrEmpty($reason)) { $reason = ($Run.Problems -join ' | ') }
    return ("обработка открылась, но тестирование не началось: {0}" -f $reason)
}

function Get-ExtensionNamesBefore {
    # Имена расширений, которые стояли в базе до загрузки: строки «ext=Имя|...» из сведений самопроверки «до».
    # $null - узнать не удалось: самопроверка до загрузки не выполнялась или обработка не открылась.
    param([string]$InfoFile)
    if (-not (Test-Path -LiteralPath $InfoFile)) { return $null }
    $lines = @()
    try { $lines = @([System.IO.File]::ReadAllLines($InfoFile, [System.Text.Encoding]::UTF8)) }
    catch { return $null }
    $complete = $false
    $names = @{}
    foreach ($line in $lines) {
        if ($null -eq $line) { continue }
        $clean = $line.TrimStart([char]0xFEFF)
        # Строка с отпечатком идёт после списка расширений: есть она - список записан целиком.
        if ($clean.StartsWith('fingerprint=', [System.StringComparison]::Ordinal)) { $complete = $true }
        if ($clean.StartsWith('ext=', [System.StringComparison]::Ordinal)) {
            $name = $clean.Substring(4).Split('|')[0].Trim()
            if ($name) { $names[$name] = $true }
        }
    }
    if (-not $complete) { return $null }
    return $names
}

function Invoke-KitRollback {
    # Возвращает расширения комплекта к состоянию до загрузки. Прежняя версия загружается из before\,
    # расширение, которого до загрузки в базе не было, удаляется. Удаление - только одного расширения
    # по имени (/DeleteCfg -Extension); ключ -AllExtensions здесь не используется никогда.
    param($Plan)
    $lines = New-Object System.Collections.Generic.List[string]
    $allDone = $true
    foreach ($entry in $Plan) {
        if ($entry.Action -eq 'skip' -or $entry.Action -eq 'none') {
            # skip - расширение не загружалось, в базе прежнее; none - загрузилось, а вернуть нечем.
            if ($entry.Action -eq 'none') { $allDone = $false }
            $lines.Add(("[----] {0}" -f $entry.Text))
            continue
        }
        if ([string]::IsNullOrWhiteSpace($entry.Name)) { throw 'Откат: пустое имя расширения.' }

        if ($entry.Action -eq 'epfrestore' -or $entry.Action -eq 'epfremove') {
            # Внешняя обработка: прежняя версия записывается в справочник тем же режимом regepf, новая
            # снимается режимом unregepf - по имени объекта и ссылке элемента вместе, чужой элемент не заденет.
            $proc = $entry.Processing
            $rollbackDir = Join-Path (Join-Path $processingsDir $proc.Name) 'rollback'
            if ($entry.Action -eq 'epfrestore') {
                $done = 'прежняя версия записана в справочник'
                $session = Invoke-ProcessingSession -Mode 'regepf' -OutDir $rollbackDir -TextFile $entry.Backup -Name $proc.FileName -Title ("Вернуть в справочник прежнюю {0}" -f $proc.Name)
            }
            else {
                $done = 'снята из справочника: публикация «Отключена», помечена на удаление'
                $session = Invoke-ProcessingSession -Mode 'unregepf' -OutDir $rollbackDir -Name $proc.ObjectName -Ref $proc.Ref -Title ("Снять из справочника {0}" -f $proc.Name)
            }
            if ($session.State -eq 'result' -and $session.Status -eq 'done') {
                $line = "[OK  ] {0}: {1}" -f $entry.Name, $done
                Write-Host $line -ForegroundColor Green
            }
            else {
                $allDone = $false
                $why = $session.Message
                if ($session.State -ne 'result') { $why = Get-ProcessingFailure $session }
                $line = "[FAIL] {0}: не откатилось - {1}. Итог: {2}" -f $entry.Name, $why, $session.ResultFile
                if ($entry.Action -eq 'epfrestore' -and $proc.OldFile) { $line += (". Прежняя версия файлом: {0}" -f $proc.OldFile) }
                Write-Host $line -ForegroundColor Red
            }
            Write-RunLog $line
            $lines.Add($line)
            continue
        }

        if ($entry.Action -eq 'delete') {
            $done = 'удалено из базы'
            $result = Invoke-Designer -Command @('/DeleteCfg', '-Extension', $entry.Name) `
                -LogName ("rollback_delete_{0}.log" -f $entry.Name) -TimeoutSec $timeoutUpdateSec -Title ("Удалить {0}" -f $entry.Name)
        }
        else {
            $done = 'прежняя версия загружена, конфигурация БД обновлена'
            $result = Invoke-Designer -Command @('/LoadCfg', ('"{0}"' -f $entry.Backup), '-Extension', $entry.Name) `
                -LogName ("rollback_load_{0}.log" -f $entry.Name) -TimeoutSec $timeoutLoadSec -Title ("Вернуть прежнее {0}" -f $entry.Name)
            if ($result.ExitCode -eq 0 -and -not $result.TimedOut) {
                $result = Invoke-Designer -Command @('/UpdateDBCfg', '-Extension', $entry.Name) `
                    -LogName ("rollback_update_{0}.log" -f $entry.Name) -TimeoutSec $timeoutUpdateSec -Title ("Обновить конфигурацию БД {0}" -f $entry.Name)
            }
        }

        if ($result.ExitCode -eq 0 -and -not $result.TimedOut) {
            $line = "[OK  ] {0}: {1}" -f $entry.Name, $done
            Write-Host $line -ForegroundColor Green
        }
        else {
            $allDone = $false
            $why = "код {0}: {1}" -f $result.ExitCode, (Get-LogTail $result.Lines)
            if ($result.TimedOut) { $why = 'таймаут, процесс снят' }
            elseif (Test-DesignerBusy $result.Lines) { $why = 'конфигуратор этой базы открыт в другом сеансе' }
            $line = "[FAIL] {0}: не откатилось - {1}. Лог: {2}" -f $entry.Name, $why, (Split-Path -Leaf $result.Log)
            Write-Host $line -ForegroundColor Red
        }
        Write-RunLog $line
        $lines.Add($line)
    }
    return [pscustomobject]@{ Done = $allDone; Lines = $lines.ToArray() }
}

function Get-SessionAppName {
    param([string]$App)
    switch ($App) {
        'BackgroundJob' { return 'фоновое задание' }
        '1CV8C' { return 'тонкий клиент' }
        '1CV8' { return 'толстый клиент' }
        'Designer' { return 'конфигуратор' }
        'WebClient' { return 'веб-клиент' }
        'COMConnection' { return 'COM-соединение' }
        'WSConnection' { return 'веб-сервис' }
        'HTTPServiceConnection' { return 'HTTP-сервис' }
        'SrvrConsole' { return 'консоль кластера' }
        default { return $App }
    }
}

function Connect-TestBaseAgent {
    # Агент сервера 1С (COM, V83.COMConnector) для тестовой базы. Имя базы проверяется ещё раз:
    # запрещённые и нетестовые базы отсечены при запуске, но здесь гейт трогает сеансы и свойства базы.
    # Возвращает Connector, Agent, кластеры, в которые пустило, и тексты ошибок.
    $targetBase = $script:Base
    if ($targetBase -notmatch $TestBasePattern) { throw "Агент сервера: база «$targetBase» не похожа на тестовую." }
    foreach ($name in @(Get-Setting $cfg 'ForbiddenBases' @() | Where-Object { $_ })) {
        if ($targetBase -ieq $name) { throw "Агент сервера: база «$targetBase» в списке запрещённых." }
    }
    $link = [pscustomobject]@{
        Connector       = $null
        Agent           = $null
        Clusters        = @()
        Errors          = @()
        ClusterUser     = [string](Get-Setting $cfg 'ClusterAdmin' '')
        ClusterPassword = [string](Get-PlainPassword ([string](Get-Setting $cfg 'ClusterAdminPassFile' '')))
    }
    $agentAddress = [string](Get-Setting $cfg 'ClusterAgent' '')
    if (-not $agentAddress) { $agentAddress = 'tcp://' + ($script:Server -split ':')[0] }
    try {
        $link.Connector = New-Object -ComObject V83.COMConnector
        $link.Agent = $link.Connector.ConnectAgent($agentAddress)
    }
    catch {
        $link.Errors = @(("не подключился к агенту сервера {0}: {1}" -f $agentAddress, $_.Exception.Message))
        return $link
    }
    $clusters = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($cluster in @($link.Agent.GetClusters())) {
        try {
            $link.Agent.Authenticate($cluster, $link.ClusterUser, $link.ClusterPassword)
            $clusters.Add($cluster)
        }
        catch {
            $errors.Add(("кластер {0}: не пустил ({1}); если у кластера есть администратор - заполни ClusterAdmin и ClusterAdminPassFile" -f $cluster.HostName, $_.Exception.Message))
        }
    }
    $link.Clusters = $clusters.ToArray()
    $link.Errors = $errors.ToArray()
    return $link
}

function Format-ClusterSession {
    param($Session)
    $text = "сеанс {0}: {1}, с {2}" -f $Session.SessionID, (Get-SessionAppName ([string]$Session.AppID)), $Session.StartedAt
    $user = ''
    $computer = ''
    try { $user = [string]$Session.userName } catch { $user = '' }
    try { $computer = [string]$Session.Host } catch { $computer = '' }
    if ($user) { $text += (", пользователь {0}" -f $user) }
    if ($computer) { $text += (", компьютер {0}" -f $computer) }
    return $text
}

function Get-TestBaseSessions {
    # Сеансы тестовой базы по данным агента сервера: имя базы сравнивается целиком.
    # Возвращает объекты: Text - для человека, IsDesigner - конфигуратор, IsError - не получилось прочитать.
    param($Link)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($message in @($Link.Errors)) { $list.Add([pscustomobject]@{ Text = $message; IsDesigner = $false; IsError = $true }) }
    foreach ($cluster in @($Link.Clusters)) {
        foreach ($session in @($Link.Agent.GetSessions($cluster))) {
            $sessionBase = ''
            try { $sessionBase = [string]$session.infoBase.Name } catch { continue }
            if ($sessionBase -ine $script:Base) { continue }
            $list.Add([pscustomobject]@{ Text = (Format-ClusterSession $session); IsDesigner = ([string]$session.AppID -eq 'Designer'); IsError = $false })
        }
    }
    return $list.ToArray()
}

function Get-TestBaseInfoBase {
    # Свойства тестовой базы в кластере через рабочий процесс. Менять их платформа даёт только со входом в саму
    # базу: пользователь и пароль - как у конфигуратора (AdminUser), пустое имя - вход текущим пользователем Windows.
    # Возвращает соединение с рабочим процессом (Process) и описание базы (InfoBase).
    param($Link)
    if ($null -eq $Link.Agent) { throw (@($Link.Errors) -join '; ') }
    foreach ($cluster in @($Link.Clusters)) {
        $processes = @($Link.Agent.GetWorkingProcesses($cluster) | Where-Object { [int]$_.Running -eq 1 })
        if ($processes.Count -eq 0) { continue }
        $process = $Link.Connector.ConnectWorkingProcess(("tcp://{0}:{1}" -f $processes[0].HostName, $processes[0].MainPort))
        $process.AuthenticateAdmin($Link.ClusterUser, $Link.ClusterPassword)
        $process.AddAuthentication($adminUser, $adminPassword)
        foreach ($infoBase in @($process.GetInfoBases())) {
            if ([string]$infoBase.Name -ieq $script:Base) {
                return [pscustomobject]@{ Process = $process; InfoBase = $infoBase }
            }
        }
    }
    throw ("в кластере не нашёл базу {0} или нет рабочего процесса" -f $script:Base)
}

function Read-TestBaseInfoBase {
    # Описание базы, прочитанное заново: после UpdateInfoBase проверяем, что изменение записалось.
    param($Target)
    foreach ($infoBase in @($Target.Process.GetInfoBases())) {
        if ([string]$infoBase.Name -ieq $script:Base) { return $infoBase }
    }
    throw ("база {0} пропала из списка баз кластера" -f $script:Base)
}

function Set-TestBaseSessionLock {
    # Блокировка начала сеансов тестовой базы на время прогона, с кодом разрешения входа.
    # Срок - SessionLockHours: если скрипт оборвут, блокировка кончится сама.
    # Чужую блокировку (стояла до гейта) не трогаем.
    param($Target, [string]$Code, [int]$Hours)
    $infoBase = $Target.InfoBase
    if ([bool]$infoBase.SessionsDenied) {
        $existing = [string]$infoBase.PermissionCode
        if ($existing -and $existing -ne $Code) {
            return ("блокировка сеансов уже стоит, не моя, код разрешения у неё другой: впиши его в UnlockCode, иначе гейт в базу не войдёт")
        }
        return 'блокировка сеансов уже стоит, не моя: не трогаю и в конце не снимаю'
    }
    $until = (Get-Date).AddHours($Hours)
    # С запасом назад: часы сервера 1С и этой машины могут расходиться на минуты.
    $infoBase.DeniedFrom = (Get-Date).AddMinutes(-30)
    $infoBase.DeniedTo = $until
    $infoBase.DeniedMessage = ("Идёт проверка расширений, база заблокирована до {0}" -f $until.ToString('HH:mm'))
    $infoBase.PermissionCode = $Code
    $infoBase.SessionsDenied = $true
    $Target.Process.UpdateInfoBase($infoBase)
    $check = Read-TestBaseInfoBase $Target
    if (-not [bool]$check.SessionsDenied) { throw 'блокировка сеансов не записалась' }
    $script:SessionLockSet = $true
    $script:SessionLockCode = $Code
    Write-RunLog ("Блокировка начала сеансов {0} поставлена до {1}" -f $script:Base, $until.ToString('yyyy-MM-dd HH:mm'))
    return ("поставил блокировку начала сеансов до {0} (код разрешения из UnlockCode); сниму в конце прогона" -f $until.ToString('HH:mm'))
}

function Clear-TestBaseLocks {
    # В конце прогона и при остановке. Снимает блокировку начала сеансов, которую поставил гейт: только если она
    # всё ещё наша (стоит, и код разрешения тот же). Блокировку регламентных заданий снимает, только если её
    # поставил гейт и задан ключ -ReleaseJobsLock или настройка ReleaseJobsLock.
    # Подключение новое: за время прогона старое могло отвалиться.
    $releaseSessions = $script:SessionLockSet
    $releaseJobs = ($script:JobsLockSet -and $script:JobsLockRelease)
    if (-not $releaseSessions -and -not $releaseJobs) { return }
    $script:SessionLockSet = $false
    $script:JobsLockSet = $false
    try {
        $target = Get-TestBaseInfoBase (Connect-TestBaseAgent)
        $infoBase = $target.InfoBase
        $changes = New-Object System.Collections.Generic.List[string]
        if ($releaseSessions) {
            if ([bool]$infoBase.SessionsDenied -and [string]$infoBase.PermissionCode -eq $script:SessionLockCode) {
                $infoBase.SessionsDenied = $false
                $infoBase.DeniedMessage = ''
                $infoBase.PermissionCode = ''
                $changes.Add('блокировку начала сеансов')
            }
            else {
                Write-Host ("Блокировка начала сеансов {0} уже снята или заменена чужой: не трогаю." -f $script:Base) -ForegroundColor DarkGray
                Write-RunLog 'Блокировка начала сеансов к концу прогона уже не наша, не трогаю'
            }
        }
        if ($releaseJobs -and [bool]$infoBase.ScheduledJobsDenied) {
            $infoBase.ScheduledJobsDenied = $false
            $changes.Add('блокировку регламентных заданий')
        }
        if ($changes.Count -gt 0) {
            $target.Process.UpdateInfoBase($infoBase)
            $text = "Снял у {0}: {1}." -f $script:Base, ($changes -join ' и ')
            Write-Host $text
            Write-RunLog $text
        }
    }
    catch {
        $text = "Блокировки {0} снять не получилось: {1}. Блокировка сеансов кончится сама в срок; снять руками - в консоли кластера, erp_temp - Свойства." -f $script:Base, $_.Exception.Message
        Write-Host $text -ForegroundColor Yellow
        Write-RunLog $text
    }
}

function Stop-TestBaseSessions {
    # Завершает сеансы тестовой базы через агент сервера 1С - так же, как кнопка «Завершить работу
    # пользователей» в БСП. Только сеансы базы $script:Base: имя сравнивается целиком.
    # Конфигураторы не трогаются: в них могут быть несохранённые правки. С -Designers наоборот: завершаются
    # только конфигураторы (ответ «закрыть отсюда» перед началом прогона).
    # Возвращает строки для человека.
    param($Link = $null, [switch]$Designers)
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($script:FileBase)) {
        $lines.Add('база файловая: завершать сеансы через агент сервера нечем')
        return $lines.ToArray()
    }
    if ($null -eq $Link) { $Link = Connect-TestBaseAgent }
    foreach ($message in @($Link.Errors)) { $lines.Add($message) }
    if ($null -eq $Link.Agent) { return $lines.ToArray() }

    $killed = 0
    foreach ($cluster in @($Link.Clusters)) {
        foreach ($session in @($Link.Agent.GetSessions($cluster))) {
            $sessionBase = ''
            try { $sessionBase = [string]$session.infoBase.Name } catch { continue }
            if ($sessionBase -ine $script:Base) { continue }
            $description = Format-ClusterSession $session
            $isDesigner = ([string]$session.AppID -eq 'Designer')
            if ($Designers -and -not $isDesigner) { continue }
            if ($isDesigner -and -not $Designers) {
                $lines.Add(("{0} - конфигуратор, не трогаю: закрой его сам" -f $description))
                continue
            }
            try {
                $Link.Agent.TerminateSession($cluster, $session)
                $killed++
                $lines.Add(("{0} - завершён" -f $description))
            }
            catch {
                $lines.Add(("{0} - не завершился: {1}" -f $description, $_.Exception.Message))
            }
        }
    }
    if ($killed -eq 0 -and $lines.Count -eq 0) {
        if ($Designers) { $lines.Add(("конфигураторов базы {0} не нашёл" -f $script:Base)) }
        else { $lines.Add(("сеансов базы {0} не нашёл" -f $script:Base)) }
    }
    foreach ($line in $lines) { Write-RunLog ('Завершение сеансов: ' + $line) }
    return $lines.ToArray()
}

function Get-BlockingSessions {
    # Кто сейчас сидит в базе: короткий вход канарейкой, она пишет чужие сеансы и активные фоновые задания
    # (строки session= и job=). Возвращает строки для человека; файл - в папке прогона.
    param([string]$FileName)
    $lines = New-Object System.Collections.Generic.List[string]
    $epf = Resolve-RootPath ([string](Get-Setting $cfg 'CanaryEpf' 'tools\Канарейка.epf'))
    if (-not (Test-Path -LiteralPath $epf) -or -not (Test-Path -LiteralPath $v8c)) {
        $lines.Add('кто мешает, узнать не получилось: нет обработки канарейки или тонкого клиента')
        return $lines.ToArray()
    }
    $outFile = Join-Path $RunDir $FileName
    $argList = @('ENTERPRISE') + @(Get-ConnectionArgs -User $adminUser -Password $adminPassword) + @(
        '/DisableStartupDialogs', '/DisableStartupMessages', '/Execute', ('"{0}"' -f $epf),
        ('/C"canary;out={0};wait=1"' -f $outFile))
    $argLine = $argList -join ' '
    Write-RunLog ("> 1cv8c.exe {0}" -f ([regex]::Replace([regex]::Replace($argLine, '/P"[^"]*"', '/P"***"'), '/UC"[^"]*"', '/UC"***"')))
    Write-Host ("  ...  Смотрю, кто сидит в базе: вход в {0}" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor DarkGray
    $timeoutSec = [int](Get-Setting $cfg 'CanaryTimeoutSec' 300)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $v8c -ArgumentList $argLine -PassThru
    $null = $process.Handle
    while ($watch.Elapsed.TotalSeconds -lt $timeoutSec -and -not (Test-Path -LiteralPath $outFile) -and -not $process.HasExited) {
        Write-UiProgress -Title 'Смотрю, кто сидит в базе' -Elapsed $watch.Elapsed.TotalSeconds
        Start-Sleep -Milliseconds 250
    }
    Complete-UiProgress
    if (-not (Test-Path -LiteralPath $outFile)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
        $lines.Add(("кто мешает, узнать не получилось: вход в базу за {0} с не удался" -f [int]$watch.Elapsed.TotalSeconds))
        return $lines.ToArray()
    }
    if (-not $process.WaitForExit(60000)) { try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { } }

    $content = @(Get-Content -LiteralPath $outFile -Encoding UTF8)
    $sessions = @($content | Where-Object { $_ -like 'session=*' })
    $jobs = @($content | Where-Object { $_ -like 'job=*' })
    $sessionError = @($content | Where-Object { $_ -like 'sessionserror=*' })
    if ($sessionError.Count -gt 0) {
        $lines.Add(('список сеансов недоступен: ' + $sessionError[0].Substring(14)))
        return $lines.ToArray()
    }
    if ($sessions.Count -eq 0 -and $jobs.Count -eq 0) {
        if (@($content | Where-Object { $_ -like 'canary=*' -and $_ -lt 'canary=20261117' }).Count -gt 0) {
            $lines.Add('обработка канарейки старая и сеансов не пишет: положи в tools сборку 20261117 или новее')
        }
        else {
            $lines.Add('сейчас в базе чужих сеансов и активных фоновых заданий нет: мешавший сеанс уже закрылся')
        }
        return $lines.ToArray()
    }
    foreach ($row in $sessions) {
        $parts = @($row.Substring(8).Split('|') + @('', '', '', '', '', ''))
        $text = "сеанс {0}: {1}, с {2}" -f $parts[0], (Get-SessionAppName $parts[1]), $parts[2]
        if ($parts[3]) { $text += (", пользователь {0}" -f $parts[3]) }
        if ($parts[4]) { $text += (", компьютер {0}" -f $parts[4]) }
        if ($parts[5]) {
            $job = @($parts[5].Split('/') + @('', '', '', ''))
            $text += (", задание «{0}»" -f $job[0])
            if ($job[3]) { $text += (" (регламентное {0})" -f $job[3]) }
        }
        $lines.Add($text)
    }
    foreach ($row in $jobs) {
        $job = @($row.Substring(4).Split('/') + @('', '', '', ''))
        $text = "фоновое задание «{0}», метод {1}, с {2}" -f $job[0], $job[1], $job[2]
        if ($job[3]) { $text += (", регламентное {0}" -f $job[3]) }
        $lines.Add($text)
    }
    return $lines.ToArray()
}

function Invoke-ProcessingSession {
    # Один сеанс «Выполнить после обновления» в режиме regepf или unregepf.
    # regepf - записать обработку в справочник «Дополнительные отчёты и обработки»: новую добавить,
    #   а если элемент с тем же именем объекта уже есть - обновить; прежняя версия ложится в old.b64.
    #   Файл обработки передаётся в base64: File - сам .epf/.erf, TextFile - файл, уже готовый в base64 (откат из old.b64).
    # unregepf - снять обработку, которую добавил гейт: по имени объекта и ссылке элемента вместе.
    # State: result - итог записан; exited - клиент закрылся без итога; nostart - обработка не открылась;
    # timeout - итога нет дольше ProcessingTimeoutSec.
    param([string]$Mode, [string]$OutDir, [string]$File = '', [string]$TextFile = '', [string]$Name, [string]$Ref = '', [string]$Title)

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $launch = New-Object System.Collections.Generic.List[string]
    $launch.Add($Mode)
    $launch.Add(("out={0}" -f $OutDir))
    $launch.Add(("name={0}" -f $Name))
    if ($Mode -eq 'regepf') {
        $newB64 = Join-Path $OutDir 'new.b64'
        if ($TextFile) { Copy-Item -LiteralPath $TextFile -Destination $newB64 -Force }
        else { [System.IO.File]::WriteAllText($newB64, [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($File)), [System.Text.Encoding]::ASCII) }
        $launch.Add(("file={0}" -f $newB64))
    }
    if ($Ref) { $launch.Add(("ref={0}" -f $Ref)) }

    $argList = @('ENTERPRISE') + @(Get-ConnectionArgs -User $adminUser -Password $adminPassword) + @(
        '/DisableStartupDialogs',
        '/DisableStartupMessages',
        '/Execute', ('"{0}"' -f $selfCheckEpf),
        ('/C"{0}"' -f ($launch.ToArray() -join ';'))
    )
    $argLine = $argList -join ' '
    Write-RunLog ("> 1cv8c.exe {0}" -f ([regex]::Replace([regex]::Replace($argLine, '/P"[^"]*"', '/P"***"'), '/UC"[^"]*"', '/UC"***"')))

    $resultFile = Join-Path $OutDir 'result.txt'
    $startedFile = Join-Path $OutDir 'started.txt'
    $oldFile = Join-Path $OutDir 'old.b64'
    $timeoutSec = [int](Get-Setting $cfg 'ProcessingTimeoutSec' 600)
    $expected = Get-ExpectedStepSeconds $Title

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $v8c -ArgumentList $argLine -PassThru
    $null = $process.Handle
    $state = ''
    while ($true) {
        if (Test-Path -LiteralPath $resultFile) { $state = 'result'; break }
        if ($process.HasExited) {
            Start-Sleep -Seconds 2
            if (Test-Path -LiteralPath $resultFile) { $state = 'result' } else { $state = 'exited' }
            break
        }
        $started = Test-Path -LiteralPath $startedFile
        if (-not $started -and $watch.Elapsed.TotalSeconds -ge $selfCheckStartTimeoutSec) { $state = 'nostart'; break }
        if ($watch.Elapsed.TotalSeconds -ge $timeoutSec) { $state = 'timeout'; break }
        $detail = 'клиент запускается'
        if (Test-Path -LiteralPath $oldFile) { $detail = 'прежняя версия сохранена, записываю новую и проверяю формы' }
        elseif ($started) { $detail = 'обработка открылась, работает со справочником' }
        Write-UiProgress -Title $Title -Elapsed $watch.Elapsed.TotalSeconds -Expected $expected -Detail $detail
        Start-Sleep -Milliseconds 250
    }
    Complete-UiProgress

    $windows = @()
    if ($state -eq 'result') {
        # Итог записан; клиент закрывается сам, файл дописан, когда процесс вышел.
        if (-not $process.WaitForExit(60000)) { try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { } }
    }
    elseif (-not $process.HasExited) {
        $windows = @(Save-ProcessWindows -ProcessId $process.Id -FilePrefix (Join-Path $OutDir 'client'))
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
    }

    $values = @{}
    $formErrors = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $resultFile) {
        foreach ($line in @([System.IO.File]::ReadAllLines($resultFile, [System.Text.Encoding]::UTF8))) {
            $clean = ([string]$line).TrimStart([char]0xFEFF)
            $position = $clean.IndexOf('=')
            if ($position -le 0) { continue }
            $key = $clean.Substring(0, $position).Trim()
            $value = $clean.Substring($position + 1)
            if ($key -eq 'formerror') { $formErrors.Add($value); continue }
            if (-not $values.ContainsKey($key)) { $values[$key] = $value }
        }
    }
    $started = [string](Get-Setting (Read-KeyValueFile $startedFile) 'started' '')
    $status = [string](Get-Setting $values 'status' '')
    $statStatus = 'FAIL'
    if ($status -eq 'done') { $statStatus = 'OK' }
    Add-StatFact -Title $Title -Seconds $watch.Elapsed.TotalSeconds -Status $statStatus

    $savedOld = ''
    if (Test-Path -LiteralPath $oldFile) { $savedOld = $oldFile }
    return [pscustomobject]@{
        State = $state; Status = $status; Message = [string](Get-Setting $values 'message' ''); Values = $values
        FormErrors = $formErrors.ToArray(); Seconds = [int]$watch.Elapsed.TotalSeconds; ResultFile = $resultFile
        OldB64 = $savedOld; Started = $started; Windows = $windows; ExitCode = $(if ($process.HasExited) { $process.ExitCode } else { '' })
    }
}

function Get-ProcessingFailure {
    # Почему сеанс regepf/unregepf не дал итога - одной строкой для шага.
    param($Session)
    switch ($Session.State) {
        'nostart' {
            return ("за {0} с обработка «Выполнить после обновления» не открылась: нет входа в базу, окно при запуске или старая сборка обработки (режимы regepf и unregepf - со сборки 20261117)" -f $Session.Seconds)
        }
        'exited' {
            if ($Session.Started) { return ("клиент закрылся без итога (код {0}); сборка обработки {1}: если она старше 20261117, режима regepf в ней нет" -f $Session.ExitCode, $Session.Started) }
            return ("клиент закрылся без итога (код {0}), обработка не отметила запуск" -f $Session.ExitCode)
        }
        'timeout' {
            return ("за {0} с итога нет, клиент снят. Окна клиента: {1}" -f $Session.Seconds, (@($Session.Windows) -join '; '))
        }
    }
    return $Session.Message
}

#endregion

#region Комплект: что грузим

function Get-KitDirect {
    # Что лежит прямо в папке. Если в ней самой есть Configuration.xml, она и есть каталог выгрузки в файлы.
    # Иначе это её файлы .cfe и подпапки, в корне которых есть Configuration.xml.
    # Внешние обработки и отчёты: файлы .epf и .erf и каталоги их выгрузки в файлы (Kind epf и epfdir).
    param([string]$Dir)
    $found = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath (Join-Path $Dir 'Configuration.xml') -PathType Leaf) {
        $found.Add([pscustomobject]@{ Kind = 'files'; Path = $Dir })
        return $found.ToArray()
    }
    if ($null -ne (Get-ProcessorDumpInfo $Dir)) {
        $found.Add([pscustomobject]@{ Kind = 'epfdir'; Path = $Dir })
        return $found.ToArray()
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -File)) {
        $type = $file.Extension.ToLowerInvariant()
        if ($type -eq '.cfe') { $found.Add([pscustomobject]@{ Kind = 'cfe'; Path = $file.FullName }) }
        elseif ($type -eq '.epf' -or $type -eq '.erf') { $found.Add([pscustomobject]@{ Kind = 'epf'; Path = $file.FullName }) }
    }
    foreach ($sub in @(Get-ChildItem -LiteralPath $Dir -Directory)) {
        if (Test-Path -LiteralPath (Join-Path $sub.FullName 'Configuration.xml') -PathType Leaf) {
            $found.Add([pscustomobject]@{ Kind = 'files'; Path = $sub.FullName })
        }
        elseif ($null -ne (Get-ProcessorDumpInfo $sub.FullName)) {
            $found.Add([pscustomobject]@{ Kind = 'epfdir'; Path = $sub.FullName })
        }
    }
    return $found.ToArray()
}

function Find-KitContent {
    # То же, но если прямо в папке ничего нет, смотрит в подпапки: так находится выгрузка, которую
    # при упаковке завернули в лишнюю папку. Внутрь каталога выгрузки поиск не заходит.
    param([string]$Dir, [int]$Depth)
    $found = @(Get-KitDirect $Dir)
    if ($found.Count -gt 0 -or $Depth -le 0) { return $found }
    foreach ($sub in @(Get-ChildItem -LiteralPath $Dir -Directory)) {
        $found += @(Find-KitContent -Dir $sub.FullName -Depth ($Depth - 1))
    }
    return $found
}

function Expand-KitArchive {
    # Распаковывает архив комплекта в папку прогона (kit\<имя архива>) и возвращает путь к распакованному.
    param([string]$ZipPath)
    $target = Join-Path (Join-Path $RunDir 'kit') ([System.IO.Path]::GetFileNameWithoutExtension($ZipPath))
    if (Test-Path -LiteralPath $target) { throw "В комплекте два архива с одним именем: $([System.IO.Path]::GetFileName($ZipPath))" }
    Write-Host ("Распаковываю {0}" -f $ZipPath) -ForegroundColor DarkGray
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        # Проводник и 7-Zip пишут русские имена файлов в кодировке 866. Имена в UTF-8 в архиве помечены
        # и читаются правильно при любой кодировке, указанной здесь.
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $target, [System.Text.Encoding]::GetEncoding(866))
    }
    catch {
        throw ("Не распаковался архив {0}. Распакуй его руками и укажи в -Kit папку. Причина: {1}" -f $ZipPath, $_.Exception.Message)
    }
    Write-RunLog ("Архив комплекта {0} распакован в {1}" -f $ZipPath, $target)
    return $target
}

function Get-EntryInboxItem {
    param($Entry)
    if ($null -ne $Entry.PSObject.Properties['InboxItem']) { return [string]$Entry.InboxItem }
    return ''
}

function New-KitProcessing {
    # Запись комплекта о внешней обработке или отчёте. Name - имя без расширения файла, так обработка
    # называется в шагах. FileName - имя файла, с которым она ляжет в справочник: по расширению .erf
    # БСП понимает, что это отчёт. File - файл, который пойдёт в справочник; у выгрузки в файлы он
    # появляется после сборки.
    param($Entry)
    $path = [string]$Entry.Path
    $xml = ''
    if ($Entry.Kind -eq 'epf') {
        $file = Get-Item -LiteralPath $path
        $isReport = ($file.Extension.ToLowerInvariant() -eq '.erf')
        $name = $file.BaseName
        $fileName = $file.Name
        $source = $file.FullName
    }
    else {
        $info = Get-ProcessorDumpInfo $path
        if ($null -eq $info) { throw "В $path нет корневого .xml внешней обработки или отчёта." }
        $isReport = [bool]$info.IsReport
        $name = [string]$info.Name
        $xml = [string]$info.Xml
        $fileName = $name + '.epf'
        if ($isReport) { $fileName = $name + '.erf' }
        $source = ''
    }
    $what = 'внешняя обработка'
    if ($isReport) { $what = 'внешний отчёт' }
    return [pscustomobject]@{
        Name = $name; Kind = [string]$Entry.Kind; Path = $path; Xml = $xml; FileName = $fileName; File = $source
        IsReport = $isReport; What = $what; Tried = $false; Touched = $false; IsNew = 'unknown'; Ref = ''; ObjectName = ''
        OldVersion = ''; NewVersion = ''; OldB64 = ''; OldFile = ''; InboxItem = (Get-EntryInboxItem $Entry)
    }
}

$kitItems = @()
$kitProcessings = @()
if ($script:MenuItems.Count -gt 0) {
    # Комплект из отмеченных в меню обновлений inbox. Каждая запись помнит, откуда она: после прогона
    # обновление, которое осталось в базе, переносится из inbox в папку прогона.
    $Kit = (@($script:MenuItems | ForEach-Object { $_.Relative }) -join ', ')
    $kitFound = @()
    foreach ($menuItem in $script:MenuItems) {
        $found = @()
        if ($menuItem.Kind -eq 'zip') { $found = @(Find-KitContent -Dir (Expand-KitArchive $menuItem.Path) -Depth 2) }
        else { $found = @([pscustomobject]@{ Kind = $menuItem.Kind; Path = $menuItem.Path }) }
        foreach ($entry in $found) { $entry | Add-Member -NotePropertyName InboxItem -NotePropertyValue $menuItem.Path -Force }
        $kitFound += $found
    }
    Write-RunLog ("Комплект из меню: {0}" -f $Kit)
}
if (-not [string]::IsNullOrWhiteSpace($Kit)) {
    if ($script:MenuItems.Count -eq 0) {
    $kitPath = Resolve-RootPath $Kit
    $kitFound = @()

    if (Test-Path -LiteralPath $kitPath -PathType Container) {
        $kitFound = @(Get-KitDirect $kitPath)
        $kitArchives = @(Get-ChildItem -LiteralPath $kitPath -Filter '*.zip' -File)
        if ($kitFound.Count -eq 0) {
            # Прямо в папке ничего нет: смотрим архивы в ней и подпапки.
            foreach ($archive in $kitArchives) {
                $kitFound += @(Find-KitContent -Dir (Expand-KitArchive $archive.FullName) -Depth 2)
            }
            foreach ($sub in @(Get-ChildItem -LiteralPath $kitPath -Directory)) {
                $kitFound += @(Find-KitContent -Dir $sub.FullName -Depth 1)
            }
        }
        elseif ($kitArchives.Count -gt 0) {
            $archiveNames = (@($kitArchives | ForEach-Object { $_.Name }) -join ', ')
            Write-Host ("Архивы в папке комплекта не разбираю ({0}): в ней уже лежат .cfe или каталог выгрузки." -f $archiveNames) -ForegroundColor DarkGray
        }
    }
    elseif (Test-Path -LiteralPath $kitPath -PathType Leaf) {
        $kitFileType = [System.IO.Path]::GetExtension($kitPath).ToLowerInvariant()
        if ($kitFileType -eq '.zip') {
            $kitFound = @(Find-KitContent -Dir (Expand-KitArchive $kitPath) -Depth 2)
        }
        elseif ($kitFileType -eq '.cfe') {
            $kitFound = @([pscustomobject]@{ Kind = 'cfe'; Path = $kitPath })
        }
        elseif ($kitFileType -eq '.epf' -or $kitFileType -eq '.erf') {
            $kitFound = @([pscustomobject]@{ Kind = 'epf'; Path = $kitPath })
        }
        else {
            throw "Комплект - это папка, архив .zip, файл .cfe или внешняя обработка .epf/.erf, а $kitPath - файл другого вида."
        }
    }
    else {
        throw "Нет такой папки или файла комплекта: $kitPath"
    }

    if ($kitFound.Count -eq 0) {
        throw "В комплекте $kitPath не нашёл ни файлов .cfe, ни каталога выгрузки в файлы (папки с Configuration.xml), ни внешних обработок (.epf, .erf, выгрузка обработки в файлы). Смотрел саму папку, архивы .zip в ней и подпапки."
    }
    # Комплект из inbox: после прогона он переносится в папку прогона, если остался в базе.
    $kitFull = [System.IO.Path]::GetFullPath($kitPath).TrimEnd('\')
    $inboxFull = [System.IO.Path]::GetFullPath($inboxDir).TrimEnd('\')
    if ($kitFull.StartsWith($inboxFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        foreach ($entry in $kitFound) { $entry | Add-Member -NotePropertyName InboxItem -NotePropertyValue $kitFull -Force }
    }
    }
    if ($kitFound.Count -eq 0) { throw 'В отмеченных обновлениях не нашёл ни файлов .cfe, ни каталога выгрузки в файлы, ни внешних обработок.' }

    foreach ($entry in $kitFound) {
        if ($entry.Kind -eq 'epf' -or $entry.Kind -eq 'epfdir') {
            # Внешняя обработка или отчёт: в базе это элемент справочника «Дополнительные отчёты и обработки».
            $kitProcessings += New-KitProcessing -Entry $entry
            continue
        }
        if ($entry.Kind -eq 'cfe') {
            $file = Get-Item -LiteralPath $entry.Path
            # Принятый формат имени выгрузки: <база>_<расширение>_<дата>.cfe. Годится и просто <расширение>....cfe.
            $matched = @($knownExtensions | Where-Object { $file.BaseName.IndexOf([string]$_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 } | Sort-Object { $_.Length } -Descending)
            if ($matched.Count -eq 0) {
                throw "Не понял, какое расширение лежит в файле $($file.Name). В имени файла должно быть имя расширения из списка Extensions в config.psd1, например erp_temp_Адаптация_20261115.cfe."
            }
            $extensionName = [string]$matched[0]
            $strangers = @($matched | Where-Object { $extensionName.IndexOf([string]$_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 })
            if ($strangers.Count -gt 0) {
                throw "В имени файла $($file.Name) встречаются имена двух расширений: $extensionName и $($strangers -join ', '). Переименуй файл."
            }
            $nameParts = Split-KitName -ItemName $file.BaseName -ExtensionName $extensionName
            $kitItems += [pscustomobject]@{ Name = $extensionName; Kind = 'cfe'; Path = $file.FullName; Version = ''; Source = $nameParts.Source; Label = $nameParts.Label; WasInBase = 'unknown'; Backup = ''; LoadTried = $false; Touched = $false; InboxItem = (Get-EntryInboxItem $entry) }
            continue
        }

        $dir = Get-Item -LiteralPath $entry.Path
        $configurationXml = Join-Path $dir.FullName 'Configuration.xml'
        $extensionName = ''
        $extensionVersion = ''
        try {
            # Через XPath, а не через точку: у узла XML есть собственное свойство Name, с ним легко перепутать.
            [xml]$document = Get-Content -LiteralPath $configurationXml -Raw -Encoding UTF8
            $propertiesPath = "/*[local-name()='MetaDataObject']/*[local-name()='Configuration']/*[local-name()='Properties']"
            $nameNode = $document.SelectSingleNode($propertiesPath + "/*[local-name()='Name']")
            $versionNode = $document.SelectSingleNode($propertiesPath + "/*[local-name()='Version']")
            if ($null -ne $nameNode) { $extensionName = [string]$nameNode.InnerText }
            if ($null -ne $versionNode) { $extensionVersion = [string]$versionNode.InnerText }
        }
        catch {
            throw "Не смог прочитать имя расширения из $configurationXml : $($_.Exception.Message)"
        }
        if ([string]::IsNullOrWhiteSpace($extensionName)) { throw "В $configurationXml пустое имя расширения." }
        $nameParts = Split-KitName -ItemName $dir.Name -ExtensionName $extensionName
        $kitItems += [pscustomobject]@{ Name = $extensionName; Kind = 'files'; Path = $dir.FullName; Version = $extensionVersion; Source = $nameParts.Source; Label = $nameParts.Label; WasInBase = 'unknown'; Backup = ''; LoadTried = $false; Touched = $false; InboxItem = (Get-EntryInboxItem $entry) }
    }

    $duplicates = @($kitItems | Group-Object -Property Name | Where-Object { $_.Count -gt 1 })
    if ($duplicates.Count -gt 0) {
        throw ("В комплекте расширение встречается дважды: {0}" -f (@($duplicates | ForEach-Object { $_.Name }) -join ', '))
    }
    $duplicates = @($kitProcessings | Group-Object -Property Name | Where-Object { $_.Count -gt 1 })
    if ($duplicates.Count -gt 0) {
        throw ("В комплекте внешняя обработка встречается дважды: {0}" -f (@($duplicates | ForEach-Object { $_.Name }) -join ', '))
    }

    # Порядок загрузки = порядок в списке Extensions (нижний слой первым); незнакомые расширения идут последними.
    $order = @{}
    $index = 0
    foreach ($name in $knownExtensions) { $order[$name] = $index; $index++ }
    $kitItems = @($kitItems | Sort-Object { if ($order.ContainsKey($_.Name)) { $order[$_.Name] } else { 1000 } })

    Write-Host 'Комплект:'
    foreach ($item in $kitItems) {
        $origin = ''
        if ($item.Source) { $origin += (" из базы {0}" -f $item.Source) }
        if ($item.Label) { $origin += (" метка {0}" -f $item.Label) }
        if ($item.Version) { $origin += (" версия {0}" -f $item.Version) }
        Write-Host ("  {0}  [{1}]{2}  {3}" -f $item.Name, $item.Kind, $origin, $item.Path)
    }
    foreach ($proc in $kitProcessings) {
        Write-Host ("  {0}  [{1}, {2}]  {3}" -f $proc.Name, $proc.Kind, $proc.What, $proc.Path)
    }
}
else {
    Write-Host 'Комплект не задан: проверяю базу как есть, ничего не загружаю.'
}

#endregion

#region Шаги

# Размеры того, что грузится: от них зависит длительность загрузки и обновления (stats.ps1).
foreach ($item in $kitItems) { Set-StatSize -Ext $item.Name -Path $item.Path }
foreach ($proc in $kitProcessings) { Set-StatSize -Ext $proc.Name -Path $proc.Path }
Set-StatRun $runId

# Комплект только из внешних обработок: конфигурация базы не меняется. Проверки конфигуратором, канарейка
# и самопроверка смотрят конфигурацию и расширения - им здесь проверять нечего. Обработку проверяет сам
# режим regepf: после записи она подключается, как её подключает БСП, создаются объект и формы.
$processingOnly = ($kitItems.Count -eq 0 -and $kitProcessings.Count -gt 0)
$processingOnlyText = 'комплект только из внешних обработок: конфигурация и расширения не менялись, обработку проверила запись в справочник'

# Проверка конфигурации одним проходом (без CheckOnly на несколько расширений) идёт параллельно с остальными
# шагами после загрузки: она самая долгая (около 27 минут на temp), а канарейка, самопроверка и выгрузка
# расширений от неё не зависят. Итог берётся перед вердиктом. $false - как раньше, по очереди.
$parallelCheckConfig = ([bool](Get-Setting $cfg 'ParallelCheckConfig' $true) -and $checkOnly.Count -le 1 -and [bool](Get-Setting $cfg 'RunCheckConfig' $true) -and -not [bool](Get-Setting $cfg 'RunCheckModules' $false))

# План прогона для ci.exe: шаги, которые пойдут, если ничего не упадёт.
$planSteps = New-Object System.Collections.Generic.List[string]
$planSteps.Add('Подготовка базы')
if ($kitItems.Count -gt 0 -and -not $selfCheckOff) { $planSteps.Add('Самопроверка до загрузки') }
foreach ($item in $kitItems) { $planSteps.Add(("Сохранить текущее {0}" -f $item.Name)) }
foreach ($item in $kitItems) {
    $planSteps.Add(("Загрузить {0}" -f $item.Name))
    $planSteps.Add(("Обновить конфигурацию БД {0}" -f $item.Name))
}
foreach ($proc in $kitProcessings) {
    if ($proc.Kind -eq 'epfdir') { $planSteps.Add(("Собрать {0} из файлов" -f $proc.Name)) }
    $planSteps.Add(("Записать в справочник {0}" -f $proc.Name))
}
if ($processingOnly) { $planSteps.Add('Проверки конфигуратором, канарейка, самопроверка') }
elseif (-not $SkipChecks) {
    $planKeys = @('all')
    if ($checkOnly.Count -gt 0) { $planKeys = @($checkOnly | ForEach-Object { [string]$_ }) }
    foreach ($planKey in $planKeys) {
        if ([bool](Get-Setting $cfg 'RunCheckModules' $false)) { $planSteps.Add(("Синтаксис-контроль ({0})" -f $planKey)) }
        if ([bool](Get-Setting $cfg 'RunCheckConfig' $true) -and -not $parallelCheckConfig) { $planSteps.Add(("Проверка конфигурации ({0})" -f $planKey)) }
    }
    if ([bool](Get-Setting $cfg 'RunCheckCanApply' $true)) { $planSteps.Add('Проверка применимости') }
}
$planCanary = @(Get-Setting $cfg 'CanaryUsers' @() | Where-Object { $_ })
if ($processingOnly) { Write-RunLog 'План: комплект только из внешних обработок, канарейки нет' }
elseif ($SkipCanary -or $planCanary.Count -eq 0) { $planSteps.Add('Канареечный вход') }
else {
    foreach ($planUser in $planCanary) {
        $planLabel = ''
        if ($planUser.ContainsKey('Name') -and $null -ne $planUser['Name']) { $planLabel = [string]$planUser['Name'] }
        if ([string]::IsNullOrEmpty($planLabel)) { $planLabel = 'текущий пользователь Windows' }
        $planSteps.Add("Канареечный вход: $planLabel")
    }
}
if ($processingOnly) { Write-RunLog 'План: комплект только из внешних обработок, самопроверки нет' }
if (-not $processingOnly -and $runExchangeRules) { $planSteps.Add('Правила обмена') }
elseif ($runSelfCheck -or $SkipSelfCheck) {
    if ($kitItems.Count -gt 0) { $planSteps.Add('Самопроверка после загрузки') } else { $planSteps.Add('Самопроверка') }
    if ($runCoverage -and -not $SkipSelfCheck) { $planSteps.Add('Карта покрытия') }
}
# Параллельная проверка конфигурации кончается последней - перед вердиктом.
if ($parallelCheckConfig -and -not $processingOnly -and -not $SkipChecks) {
    foreach ($planKey in @(@($checkOnly | ForEach-Object { [string]$_ }) + @('all') | Select-Object -First 1)) { $planSteps.Add(("Проверка конфигурации ({0})" -f $planKey)) }
}
foreach ($planName in $planSteps) { $script:RunPlanExpected[$planName] = [double](Get-ExpectedStepSeconds $planName) }
Send-UiPlan -StepNames $planSteps.ToArray()

# 0. Подготовка базы. Блокировка регламентных заданий ставится всегда и остаётся: у копии рабочей базы
# рабочее расписание (закрытие месяца ночью, обмены), и фоновое задание срывает обновление БД.
# Потом проверка, есть ли в базе сеансы: обновлению БД нужен монопольный доступ.
$script:PrepLines = New-Object System.Collections.Generic.List[string]
function Add-PrepLine {
    param([string]$Text, [string]$Color = 'Gray')
    $script:PrepLines.Add($Text)
    Write-Host ('  ' + $Text) -ForegroundColor $Color
    Write-RunLog ('Подготовка базы: ' + $Text)
}

Write-Host 'Подготовка базы:'
if (-not [string]::IsNullOrEmpty($script:FileBase)) {
    Add-PrepLine 'база файловая: блокировки ставятся через кластер, здесь их нет; сеансы не проверяю'
}
else {
    $prepLink = Connect-TestBaseAgent
    $prepTarget = $null
    try {
        $prepTarget = Get-TestBaseInfoBase $prepLink
        if ([bool]$prepTarget.InfoBase.ScheduledJobsDenied) {
            Add-PrepLine 'блокировка регламентных заданий уже стоит'
        }
        else {
            $prepTarget.InfoBase.ScheduledJobsDenied = $true
            $prepTarget.Process.UpdateInfoBase($prepTarget.InfoBase)
            if (-not [bool](Read-TestBaseInfoBase $prepTarget).ScheduledJobsDenied) { throw 'флажок не записался' }
            $script:JobsLockSet = $true
            if ($script:JobsLockRelease) { Add-PrepLine 'поставил блокировку регламентных заданий; в конце прогона сниму (-ReleaseJobsLock)' 'Green' }
            else { Add-PrepLine 'поставил блокировку регламентных заданий; она остаётся и после прогона' 'Green' }
        }
    }
    catch {
        $prepTarget = $null
        Add-PrepLine ("блокировку регламентных заданий поставить не смог: {0}. Поставь её в консоли кластера (erp_temp - Свойства) или задай AdminUser с паролем" -f $_.Exception.Message) 'Yellow'
    }

    $prepCanAsk = Test-UiCanAsk

    $prepSessions = @(Get-TestBaseSessions $prepLink)
    $prepErrors = @($prepSessions | Where-Object { $_.IsError })
    foreach ($entry in $prepErrors) { Add-PrepLine ('сеансы проверить не смог: ' + $entry.Text) 'Yellow' }

    # Открытый конфигуратор - первым делом: пока он открыт, пакетный конфигуратор гейта базу не получит.
    $prepDesigners = @($prepSessions | Where-Object { -not $_.IsError -and $_.IsDesigner })
    if ($prepDesigners.Count -gt 0) {
        Add-PrepLine ("открыт конфигуратор {0}: закрой его, чтобы продолжить" -f $script:Base) 'Yellow'
        foreach ($entry in $prepDesigners) { Add-PrepLine ('  ' + $entry.Text) 'Yellow' }
        $answer = ''
        if ($prepCanAsk) {
            # Пока ждём ответа, раз в 3 секунды смотрим сеансы: закрыл конфигуратор сам - гейт продолжает без ответа.
            $answer = Read-UiChoice -Header ("Открыт конфигуратор {0}. Закрой его сам - гейт увидит и продолжит, или:" -f $script:Base) `
                -Keys @('1', '2') -Labels @('Закрыть отсюда (сеанс прерывается, несохранённые правки в нём пропадут)', 'Отмена') -CancelKey '2' -Poll {
                $nowSessions = @(Get-TestBaseSessions $prepLink)
                # Список не прочитался - это не «закрыли», ждём дальше.
                if (@($nowSessions | Where-Object { $_.IsError }).Count -eq 0 -and @($nowSessions | Where-Object { $_.IsDesigner }).Count -eq 0) { return 'closed' }
                return ''
            }
        }
        if ($answer -eq 'closed') {
            Add-PrepLine 'конфигуратор закрыли, продолжаю' 'Green'
            Write-RunLog 'Конфигуратор закрыт вручную'
            $prepSessions = @(Get-TestBaseSessions $prepLink | Where-Object { -not $_.IsError })
        }
        elseif ($answer -eq '1') {
            foreach ($line in @(Stop-TestBaseSessions -Link $prepLink -Designers)) { Add-PrepLine $line }
            # Сеанс уходит не мгновенно: ждём до 30 секунд.
            $leftDesigners = @()
            for ($wait = 0; $wait -lt 10; $wait++) {
                Start-Sleep -Seconds 3
                $prepSessions = @(Get-TestBaseSessions $prepLink | Where-Object { -not $_.IsError })
                $leftDesigners = @($prepSessions | Where-Object { $_.IsDesigner })
                if ($leftDesigners.Count -eq 0) { break }
            }
            if ($leftDesigners.Count -gt 0) {
                foreach ($entry in $leftDesigners) { Add-PrepLine ('не закрылся: ' + $entry.Text) 'Red' }
                throw ("конфигуратор {0} за 30 секунд не закрылся. Закрой его сам или удали сеанс в консоли кластера и запусти заново" -f $script:Base)
            }
            Add-PrepLine 'конфигуратор закрыт' 'Green'
        }
        else {
            Write-RunLog 'Выход: открыт конфигуратор'
            if ($prepCanAsk) { throw ("открыт конфигуратор {0}, отмена по ответу" -f $script:Base) }
            throw ("открыт конфигуратор {0}, а спросить некого (запуск без консоли). Закрой его и запусти заново" -f $script:Base)
        }
    }

    $prepOthers = @($prepSessions | Where-Object { -not $_.IsError -and -not $_.IsDesigner })
    if ($prepErrors.Count -eq 0 -and $prepOthers.Count -eq 0) {
        Add-PrepLine ("в {0} других сеансов нет" -f $script:Base) 'Green'
    }
    elseif ($prepOthers.Count -gt 0 -and $processingOnly) {
        # Запись в справочник монопольного доступа не требует: сеансы пользователей обработкам не мешают.
        Add-PrepLine ("в {0} есть сеансы: {1}; комплекту из одних обработок они не мешают" -f $script:Base, $prepOthers.Count)
    }
    elseif ($prepOthers.Count -gt 0) {
        Add-PrepLine ("в {0} есть сеансы: {1}" -f $script:Base, $prepOthers.Count) 'Yellow'
        foreach ($entry in $prepOthers) { Add-PrepLine ('  ' + $entry.Text) 'Yellow' }

        $choice = $sessionPolicy
        if ($choice -eq 'Ask') {
            if ($prepCanAsk) {
                # Пока ждём ответа, раз в 3 секунды смотрим сеансы: ушли сами - блокировка и дальше без ответа.
                $script:PrepLastCount = $prepOthers.Count
                $answer = Read-UiChoice -Header ("В {0} есть сеансы: {1}. Можно дождаться, пока закончатся сами, или:" -f $script:Base, $prepOthers.Count) `
                    -Keys @('1', '2', '3') -CancelKey '2' -Labels @(
                    'Продолжить так',
                    'Выйти',
                    ("Поставить блокировку начала сеансов на {0} ч, завершить сеансы и продолжить" -f $sessionLockHours)) -Poll {
                    $nowSessions = @(Get-TestBaseSessions $prepLink)
                    # Список не прочитался - это не «никого нет», ждём дальше. Конфигуратор тоже считается.
                    if (@($nowSessions | Where-Object { $_.IsError }).Count -gt 0) { return '' }
                    if ($nowSessions.Count -eq 0) { return 'empty' }
                    if ($nowSessions.Count -ne $script:PrepLastCount) {
                        $script:PrepLastCount = $nowSessions.Count
                        Write-Host ("  сеансов осталось: {0}" -f $nowSessions.Count) -ForegroundColor DarkGray
                    }
                    return ''
                }
                $choice = @{ '1' = 'Continue'; '2' = 'Exit'; '3' = 'Terminate'; 'empty' = 'Emptied' }[$answer]
            }
            else {
                $choice = 'Continue'
                Add-PrepLine 'спросить некого, запуск без консоли: продолжаю так'
            }
        }
        else {
            Add-PrepLine ("ответ задан ключом -OnSessions или настройкой OnSessions: {0}" -f $choice)
        }

        if ($choice -eq 'Exit') {
            Write-RunLog 'Выход: в базе есть сеансы'
            throw ("в {0} есть сеансы, выход по ответу. Сеансы перечислены выше и в {1}" -f $script:Base, $script:RunLogPath)
        }
        if ($choice -eq 'Continue') {
            Add-PrepLine 'продолжаю с сеансами в базе: обновление БД может упереться в монопольную блокировку'
        }
        if ($choice -eq 'Emptied') {
            Add-PrepLine ("сеансы {0} закончились сами" -f $script:Base) 'Green'
            Write-RunLog 'Сеансы закончились, пока ждали ответа'
        }
        if ($choice -eq 'Terminate' -or $choice -eq 'Emptied') {
            $lockCode = $script:UnlockCode
            if ([string]::IsNullOrEmpty($lockCode)) {
                # Без кода гейт сам в заблокированную базу не войдёт. Код дальше используется во всех запусках.
                $lockCode = '123'
                $script:UnlockCode = $lockCode
                $designerBase = @('DESIGNER') + @(Get-ConnectionArgs -User $adminUser -Password $adminPassword) +
                    @('/DisableStartupDialogs', '/DisableStartupMessages')
                Add-PrepLine 'UnlockCode пустой: код разрешения входа на этот прогон - 123'
            }
            if ($null -eq $prepTarget) {
                Add-PrepLine 'блокировку начала сеансов поставить не смог (нет входа в свойства базы, см. выше): сеансы могут вернуться' 'Yellow'
            }
            else {
                try { Add-PrepLine (Set-TestBaseSessionLock -Target $prepTarget -Code $lockCode -Hours $sessionLockHours) 'Green' }
                catch { Add-PrepLine ("блокировку начала сеансов поставить не смог: {0}. Сеансы могут вернуться" -f $_.Exception.Message) 'Yellow' }
            }
            if ($choice -eq 'Terminate') {
                foreach ($line in @(Stop-TestBaseSessions -Link $prepLink)) { Add-PrepLine $line }
            }
            $leftSessions = @(Get-TestBaseSessions $prepLink | Where-Object { -not $_.IsError })
            if ($leftSessions.Count -eq 0) { Add-PrepLine ("в {0} сеансов больше нет" -f $script:Base) 'Green' }
            else {
                foreach ($entry in $leftSessions) { Add-PrepLine ('осталось: ' + $entry.Text) 'Yellow' }
            }
        }
    }
}

$proceed = $true

# Копия эталона на начало прогона: по ней разбор прогона (report.ps1) считает, что исправлено,
# даже если эталон потом сдвинется. Эталон самопроверки копируется ещё раз перед сравнением «после».
$referenceCopyDir = Join-Path $RunDir 'reference'
if (Test-Path -LiteralPath $baselineDir) {
    $referenceFiles = @(Get-ChildItem -LiteralPath $baselineDir -Filter '*.norm.txt' -File)
    if ($referenceFiles.Count -gt 0) {
        New-Item -ItemType Directory -Path $referenceCopyDir -Force | Out-Null
        foreach ($file in $referenceFiles) { Copy-Item -LiteralPath $file.FullName -Destination $referenceCopyDir -Force }
    }
}
$script:StopRun = $false

# Замеры самопроверки до загрузки (старый код): идут в историю раньше замеров после, см. Invoke-MetricsStep.
$beforeMetrics = @{}
# Итоги выгрузки шага «Обмены» до загрузки: файл прогона или эталон (если «до» не снималась). Из него же -
# набор объектов для «после» (exch=): «до» и «после» сравниваются на одном наборе.
$exchangeBeforeFile = ''
$exchangeSetFile = ''

# 1. Самопроверка до загрузки: состояние, с которым будет сравниваться состояние после.
# Заодно из её сведений известно, какие расширения стояли в базе до загрузки.
# Если база не менялась после прошлой самопроверки гейта, заново она не выполняется: эталон уже есть.
if ($kitItems.Count -gt 0 -and -not $selfCheckOff) {
    $stepName = 'Самопроверка до загрузки'
    $known = ''
    if (-not $FreshBefore -and (Test-Path -LiteralPath $selfCheckReferenceFile)) {
        $known = [string](Get-Setting (Read-KeyValueFile $selfCheckLastFile) 'fingerprint' '')
        if ($known -notmatch '^[0-9a-f]{64}$') { $known = '' }
    }
    $before = Invoke-SelfCheck -Label 'before' -Known $known -Title $stepName
    $errorsBefore = @($before.Records | Where-Object { $_.StartsWith('[ОШИБКА]') }).Count
    $minutes = [int][Math]::Ceiling($before.Seconds / 60)

    if ($before.State -eq 'same') {
        if (Test-Path -LiteralPath $selfCheckExchangeFile) { $exchangeBeforeFile = $selfCheckExchangeFile }
        $referenceInfo = Read-KeyValueFile $selfCheckReferenceInfoFile
        $detail = "не запускалась: расширения и параметры те же, что после прошлой самопроверки гейта. Сравнение будет с эталоном самопроверки от прогона {0}" -f (Get-Setting $referenceInfo 'run' 'неизвестно')
        Add-StepResult -Name $stepName -Status 'OK' -Detail $detail -Seconds $before.Seconds
    }
    elseif ($before.State -eq 'done' -or $before.State -eq 'incomplete') {
        Save-SelfCheckReference -Records $before.Records -Label 'before' -Fingerprint $before.Fingerprint -Snapshots $before.Snapshots -Exchange $before.Exchange
        Save-SelfCheckLastState -Fingerprint $before.Fingerprint
        $beforeMetrics = $before.Metrics
        if ($before.Exchange.Count -gt 0) { $exchangeBeforeFile = Join-Path $RunDir 'selfcheck-before.exchange.txt' }
        $detail = "состояние до загрузки снято и стало эталоном самопроверки: записей {0}, из них ошибок {1}; {2} мин" -f $before.Records.Count, $errorsBefore, $minutes
        if ($before.Problems.Count -gt 0) {
            $detail += ('. Прогон неполный: ' + ($before.Problems -join ' | '))
            Add-StepResult -Name $stepName -Status 'WARN' -Detail $detail -Log $before.Journal -Seconds $before.Seconds
        }
        else {
            Add-StepResult -Name $stepName -Status 'OK' -Detail $detail -Log $before.Journal -Seconds $before.Seconds
        }
    }
    else {
        $detail = "{0}. Состояние до загрузки не снято" -f (Get-SelfCheckFailure $before)
        if (Test-Path -LiteralPath $selfCheckReferenceFile) { $detail += ': сравнение будет с прежним эталоном самопроверки' }
        else { $detail += ': сравнивать будет не с чем' }
        Add-StepResult -Name $stepName -Status 'WARN' -Detail $detail -Log $before.Journal -Seconds $before.Seconds
    }
}

# 2. Сохраняем то, что стоит в базе сейчас, чтобы было куда откатиться.
if ($kitItems.Count -gt 0) {
    # Какие расширения были в базе до загрузки. Без самопроверки «до» это неизвестно; тогда про расширение
    # понятно только одно: если его удалось выгрузить, значит, оно было.
    $extensionsBefore = Get-ExtensionNamesBefore (Join-Path $RunDir 'selfcheck-before\try1\info.txt')

    New-Item -ItemType Directory -Path $referenceSnapshotDir -Force | Out-Null
    foreach ($file in @($selfCheckReferenceFile, $selfCheckReferenceInfoFile, $selfCheckLastFile, $selfCheckSnapshotsFile, $selfCheckExchangeFile, $coverageReferenceFile, $exchangeRulesStateFile, $exchangeRulesFindingsFile)) {
        if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination $referenceSnapshotDir -Force }
    }

    $beforeDir = Join-Path $RunDir 'before'
    New-Item -ItemType Directory -Path $beforeDir -Force | Out-Null
    foreach ($item in $kitItems) {
        $stepName = "Сохранить текущее {0}" -f $item.Name
        $listed = 'unknown'
        if ($null -ne $extensionsBefore) {
            if ($extensionsBefore.ContainsKey($item.Name)) { $listed = 'yes' } else { $listed = 'no' }
        }
        $backupFile = Join-Path $beforeDir ("{0}_{1}_{2}.cfe" -f $baseKey, $item.Name, (Get-Date -Format 'yyyyMMdd'))
        $result = Invoke-Designer -Command @('/DumpCfg', ('"{0}"' -f $backupFile), '-Extension', $item.Name) `
            -LogName ("backup_{0}.log" -f $item.Name) -TimeoutSec $timeoutLoadSec -Title $stepName
        $dumped = ($result.ExitCode -eq 0 -and -not $result.TimedOut -and (Test-Path -LiteralPath $backupFile))

        # Новым расширение считается, только когда сошлись оба признака: его нет в списке расширений
        # из самопроверки и конфигуратор его не выгрузил. От этого зависит, удалять ли его при откате.
        if ($listed -eq 'no' -and -not $dumped -and -not $result.TimedOut -and -not (Test-DesignerBusy $result.Lines)) {
            $item.WasInBase = 'no'
            Add-StepResult -Name $stepName -Status 'OK' -Detail 'расширения в базе ещё нет, оно новое: сохранять нечего' -Log $result.Log -Seconds $result.Seconds
            continue
        }
        $saved = Add-SimpleStep -Name $stepName -Result $result -Blocking $false
        if ($saved -and $dumped) {
            $item.Backup = $backupFile
            $item.WasInBase = 'yes'
        }
        elseif ($listed -eq 'yes') {
            $item.WasInBase = 'yes'
        }
    }
}

# 3. Загрузка и обновление конфигурации базы данных.
$script:UpdateBlockers = @()
foreach ($item in $kitItems) {
    if (-not $proceed) {
        Add-StepResult -Name ("Загрузить {0}" -f $item.Name) -Status 'SKIP' -Detail 'пропущено: предыдущий шаг не прошёл'
        continue
    }
    if ($item.Kind -eq 'cfe') {
        $command = @('/LoadCfg', ('"{0}"' -f $item.Path), '-Extension', $item.Name)
    }
    else {
        $command = @('/LoadConfigFromFiles', ('"{0}"' -f $item.Path), '-Extension', $item.Name)
    }
    $result = Invoke-Designer -Command $command -LogName ("load_{0}.log" -f $item.Name) -TimeoutSec $timeoutLoadSec -Title ("Загрузить {0}" -f $item.Name)
    $item.LoadTried = $true
    # С этого места расширение в базе уже не прежнее: при откате его надо возвращать.
    if ($result.ExitCode -eq 0 -or $result.TimedOut) { $item.Touched = $true }
    $proceed = Add-SimpleStep -Name ("Загрузить {0}" -f $item.Name) -Result $result -Blocking $true
    if (-not $proceed) { continue }

    $attempt = 0
    while ($true) {
        $attempt++
        $logName = "update_{0}.log" -f $item.Name
        if ($attempt -gt 1) { $logName = "update_{0}_{1}.log" -f $item.Name, $attempt }
        $result = Invoke-Designer -Command @('/UpdateDBCfg', '-Extension', $item.Name) `
            -LogName $logName -TimeoutSec $timeoutUpdateSec -Title ("Обновить конфигурацию БД {0}" -f $item.Name)
        $lockedOut = ($result.ExitCode -ne 0 -and -not $result.TimedOut -and (($result.Lines -join ' ').Contains('исключительной блокировки')))
        if (-not $lockedOut) { break }

        # Обновлению нужен монопольный доступ, а в базе кто-то есть. Выясняем кто и пишем, что с этим делать.
        $who = @(Get-BlockingSessions -FileName ("sessions_{0}_{1}.txt" -f $item.Name, $attempt))
        $hasJob = @($who | Where-Object { $_.Contains('фоновое задание') }).Count -gt 0
        Write-Host ("       Обновлению БД {0} мешают другие сеансы erp_temp:" -f $item.Name) -ForegroundColor Yellow
        foreach ($line in $who) { Write-Host ('         ' + $line) -ForegroundColor Yellow; Write-RunLog ('Мешает: ' + $line) }
        if ($hasJob) {
            Write-Host '       Фоновые задания - регламентные задания самой erp_temp (у копии рабочей базы рабочее расписание).' -ForegroundColor Yellow
            Write-Host '       Отменить: в erp_temp «Регламентные и фоновые задания» или удалить сеанс в консоли кластера.' -ForegroundColor Yellow
            Write-Host '       Чтобы не стартовали снова: в консоли кластера у erp_temp включить «Блокировка регламентных заданий».' -ForegroundColor Yellow
        }
        else {
            Write-Host '       Закрыть эти сеансы (или удалить их в консоли кластера) и повторить.' -ForegroundColor Yellow
        }
        $script:UpdateBlockers = $who

        if (-not (Test-UiCanAsk)) { break }
        $canTerminate = [string]::IsNullOrEmpty($script:FileBase)
        $lockKeys = @('1', '2')
        $lockLabels = @('Повторить обновление БД (сначала убери мешающие сеансы сам)', 'Не повторять, прогон дальше не идёт')
        if ($canTerminate) {
            $lockKeys += '3'
            $lockLabels += ("Завершить сеансы {0} (кроме конфигураторов) и сразу повторить" -f $script:Base)
        }
        $answer = Read-UiChoice -Header ("Обновлению БД {0} мешают другие сеансы {1}" -f $item.Name, $script:Base) -Keys $lockKeys -Labels $lockLabels -CancelKey '2'
        if ($answer -eq '3') {
            foreach ($line in @(Stop-TestBaseSessions)) { Write-Host ('         ' + $line) }
            continue
        }
        if ($answer -ne '1') { break }
    }
    $proceed = Add-SimpleStep -Name ("Обновить конфигурацию БД {0}" -f $item.Name) -Result $result -Blocking $true
    if (-not $proceed -and $null -ne $script:UpdateBlockers -and @($script:UpdateBlockers).Count -gt 0) {
        $lastStep = $script:Steps[$script:Steps.Count - 1]
        $lastStep.detail = $lastStep.detail + '. Мешали: ' + (@($script:UpdateBlockers) -join '; ')
    }
}

# 3а. Внешние обработки и отчёты: запись в справочник «Дополнительные отчёты и обработки». Выгрузку в файлы
# сначала собирает конфигуратор. Запись делает «Выполнить после обновления» (режим regepf) через БСП, как
# загрузка из файла в форме элемента; прежняя версия перед записью ложится в epf\<имя>\old.b64 - это откат.
$processingsDir = Join-Path $RunDir 'epf'
foreach ($proc in $kitProcessings) {
    $registerName = "Записать в справочник {0}" -f $proc.Name
    if (-not $proceed) {
        Add-StepResult -Name $registerName -Status 'SKIP' -Detail 'пропущено: предыдущий шаг не прошёл'
        continue
    }
    if ($selfCheckOff -and -not (Test-Path -LiteralPath $selfCheckEpf)) {
        Add-StepResult -Name $registerName -Status 'FAIL' -Detail ("записать некому: нет обработки {0}" -f $selfCheckEpf)
        $proceed = $false
        continue
    }
    if (-not (Test-Path -LiteralPath $v8c)) {
        Add-StepResult -Name $registerName -Status 'FAIL' -Detail ("записать некому: нет тонкого клиента {0}" -f $v8c)
        $proceed = $false
        continue
    }
    $procDir = Join-Path $processingsDir $proc.Name

    if ($proc.Kind -eq 'epfdir') {
        $buildName = "Собрать {0} из файлов" -f $proc.Name
        New-Item -ItemType Directory -Path $procDir -Force | Out-Null
        $builtFile = Join-Path $procDir $proc.FileName
        $result = Invoke-Designer -Command @('/LoadExternalDataProcessorOrReportFromFiles', ('"{0}"' -f $proc.Xml), ('"{0}"' -f $builtFile)) `
            -LogName ("build_{0}.log" -f $proc.Name) -TimeoutSec $timeoutLoadSec -Title $buildName
        if ($result.ExitCode -eq 0 -and -not $result.TimedOut -and -not (Test-Path -LiteralPath $builtFile)) {
            Add-StepResult -Name $buildName -Status 'FAIL' -Detail ("конфигуратор отработал без ошибки, а файла {0} нет" -f $proc.FileName) -Log $result.Log -Seconds $result.Seconds
            $proceed = $false
            continue
        }
        $proceed = Add-SimpleStep -Name $buildName -Result $result -Blocking $true
        if (-not $proceed) { continue }
        $proc.File = $builtFile
    }

    $proc.Tried = $true
    $session = Invoke-ProcessingSession -Mode 'regepf' -OutDir (Join-Path $procDir 'register') -File $proc.File -Name $proc.FileName -Title $registerName
    $values = $session.Values
    $proc.ObjectName = [string](Get-Setting $values 'objname' '')
    $proc.Ref = [string](Get-Setting $values 'ref' '')
    $proc.NewVersion = [string](Get-Setting $values 'objversion' '')
    $proc.OldVersion = [string](Get-Setting $values 'oldversion' '')
    if ($session.OldB64) {
        $proc.OldB64 = $session.OldB64
        # Прежняя версия - ещё и обычным файлом: его можно открыть или загрузить в форме элемента руками.
        try {
            $proc.OldFile = Join-Path $procDir ('прежняя_' + $proc.FileName)
            [System.IO.File]::WriteAllBytes($proc.OldFile, [Convert]::FromBase64String([System.IO.File]::ReadAllText($session.OldB64).Trim()))
        }
        catch { $proc.OldFile = ''; Write-RunLog ("Прежняя версия {0} не раскодировалась: {1}" -f $proc.Name, $_.Exception.Message) }
    }
    $isNewText = [string](Get-Setting $values 'isnew' '')
    if ($isNewText -eq '1') { $proc.IsNew = 'yes' } elseif ($isNewText -eq '0') { $proc.IsNew = 'no' }

    if ($session.State -ne 'result') {
        # Итога нет: записалась ли обработка, неизвестно. Если прежняя версия успела сохраниться, откат возможен.
        $proc.Touched = $true
        Add-StepResult -Name $registerName -Status 'FAIL' -Detail (Get-ProcessingFailure $session) -Log $session.ResultFile -Seconds $session.Seconds
        $proceed = $false
        continue
    }
    if ($session.Status -ne 'done' -and -not $proc.Ref) {
        # Не записана: справочник не менялся.
        Add-StepResult -Name $registerName -Status 'FAIL' -Detail ("не записана: {0}" -f $session.Message) -Log $session.ResultFile -Seconds $session.Seconds
        $proceed = $false
        continue
    }
    $proc.Touched = $true

    $what = 'обновлена'
    if ($proc.IsNew -eq 'yes') { $what = 'добавлена новым элементом' }
    $detail = "{0} {1} {2}" -f $proc.What, $proc.ObjectName, $what
    if ($proc.OldVersion -or $proc.NewVersion) { $detail += (", версия {0} -> {1}" -f $(if ($proc.OldVersion) { $proc.OldVersion } else { '-' }), $(if ($proc.NewVersion) { $proc.NewVersion } else { '-' })) }
    $detail += (", вид {0}, команд {1}, форм {2}" -f (Get-Setting $values 'kind' '?'), (Get-Setting $values 'commands' '?'), (Get-Setting $values 'forms' '?'))
    $problems = New-Object System.Collections.Generic.List[string]
    if ($session.Status -ne 'done') { $problems.Add($session.Message) }
    if ([string](Get-Setting $values 'check' '') -eq 'error') { $problems.Add(("не подключилась после записи: {0}" -f (Get-Setting $values 'checkerror' ''))) }
    foreach ($formError in $session.FormErrors) { $problems.Add(("форма не создаётся: {0}" -f $formError)) }
    if ($problems.Count -gt 0) {
        Add-StepResult -Name $registerName -Status 'FAIL' -Detail ($detail + '. ' + ($problems -join ' | ')) -Log $session.ResultFile -Seconds $session.Seconds
    }
    else {
        Add-StepResult -Name $registerName -Status 'OK' -Detail ($detail + '; подключается, объект и формы создаются') -Log $session.ResultFile -Seconds $session.Seconds
    }
}

# 4. Проверки конфигуратором.
if ($processingOnly) {
    # Один шаг вместо трёх пропусков: пропуск красит вердикт в жёлтый, а здесь проверять нечего.
    Add-StepResult -Name 'Проверки конфигуратором, канарейка, самопроверка' -Status 'OK' -Detail ("не нужны: {0}" -f $processingOnlyText)
}
elseif ($SkipChecks) {
    Add-StepResult -Name 'Проверки конфигуратором' -Status 'SKIP' -Detail 'отключено ключом -SkipChecks'
}
elseif (-not $proceed) {
    Add-StepResult -Name 'Проверки конфигуратором' -Status 'SKIP' -Detail 'пропущено: загрузка не прошла'
}
else {
    $targets = @()
    if ($checkOnly.Count -gt 0) {
        foreach ($name in $checkOnly) { $targets += [pscustomobject]@{ Key = [string]$name; Selector = @('-Extension', [string]$name) } }
    }
    else {
        $targets += [pscustomobject]@{ Key = 'all'; Selector = @('-AllExtensions') }
    }

    $checkModulesFlags = [string](Get-Setting $cfg 'CheckModulesFlags' '-ThinClient -Server -ExternalConnection')
    $checkConfigFlags = [string](Get-Setting $cfg 'CheckConfigFlags' '-ConfigLogIntegrity -IncorrectReferences -ThinClient -Server -ExternalConnection -ExtendedModulesCheck')
    # Прогон 14.11 показал: проверка конфигурации находит те же ошибки компиляции, что и синтаксис-контроль,
    # поэтому отдельный синтаксис-контроль по умолчанию выключен (минус 12 минут).
    $runCheckModules = [bool](Get-Setting $cfg 'RunCheckModules' $false)
    $runCheckConfig = [bool](Get-Setting $cfg 'RunCheckConfig' $true)

    foreach ($target in $targets) {
        if ($runCheckModules -and -not $script:StopRun) {
            $result = Invoke-Designer -Command (@('/CheckModules', $checkModulesFlags) + $target.Selector) `
                -LogName ("checkmodules_{0}.log" -f $target.Key) -TimeoutSec $timeoutCheckSec -Title ("Синтаксис-контроль ({0})" -f $target.Key)
            Add-CheckStep -Name ("Синтаксис-контроль ({0})" -f $target.Key) -Result $result `
                -FileKey ("checkmodules_{0}" -f $target.Key) -Blocking $true
        }

        if ($runCheckConfig -and -not $script:StopRun -and $parallelCheckConfig) {
            # Идёт параллельно: итог - в Complete-BackgroundCheck перед вердиктом.
            $script:BackgroundCheck = Start-DesignerBackground -Command (@('/CheckConfig', $checkConfigFlags) + $target.Selector) `
                -LogName ("checkconfig_{0}.log" -f $target.Key) -TimeoutSec $timeoutCheckSec -Title ("Проверка конфигурации ({0})" -f $target.Key) `
                -FileKey ("checkconfig_{0}" -f $target.Key)
        }
        elseif ($runCheckConfig -and -not $script:StopRun) {
            $result = Invoke-Designer -Command (@('/CheckConfig', $checkConfigFlags) + $target.Selector) `
                -LogName ("checkconfig_{0}.log" -f $target.Key) -TimeoutSec $timeoutCheckSec -Title ("Проверка конфигурации ({0})" -f $target.Key)
            Add-CheckStep -Name ("Проверка конфигурации ({0})" -f $target.Key) -Result $result `
                -FileKey ("checkconfig_{0}" -f $target.Key) -Blocking $true
        }
    }

    if ([bool](Get-Setting $cfg 'RunCheckCanApply' $true) -and -not $script:StopRun) {
        # Новая строка здесь - это, например, перехват метода, которого в типовой уже нет: блокирует.
        $result = Invoke-Designer -Command @('/CheckCanApplyConfigurationExtensions') `
            -LogName 'checkcanapply.log' -TimeoutSec $timeoutCheckSec -Title 'Проверка применимости'
        Add-CheckStep -Name 'Проверка применимости' -Result $result -FileKey 'checkcanapply' -Blocking $true
    }

    if ($script:StopRun) {
        Add-StepResult -Name 'Остальные проверки конфигуратором' -Status 'SKIP' -Detail 'пропущено: конфигуратор базы занят'
    }
}

# 5. Канареечный вход: сеанс стартует, сервер отвечает, расширения применились.
$canaryUsers = @(Get-Setting $cfg 'CanaryUsers' @() | Where-Object { $_ })
$canaryEpf = Resolve-RootPath ([string](Get-Setting $cfg 'CanaryEpf' 'tools\Канарейка.epf'))
$canaryWaitSec = [int](Get-Setting $cfg 'CanaryWaitSec' 10)
$canaryTimeoutSec = [int](Get-Setting $cfg 'CanaryTimeoutSec' 300)

if ($processingOnly) {
    Write-RunLog ('Канареечный вход не нужен: ' + $processingOnlyText)
}
elseif ($SkipCanary) {
    Add-StepResult -Name 'Канареечный вход' -Status 'SKIP' -Detail 'отключено ключом -SkipCanary'
}
elseif (-not $proceed) {
    Add-StepResult -Name 'Канареечный вход' -Status 'SKIP' -Detail 'пропущено: загрузка не прошла'
}
elseif ($canaryUsers.Count -eq 0) {
    Add-StepResult -Name 'Канареечный вход' -Status 'WARN' -Detail 'в config.psd1 пустой список CanaryUsers'
}
elseif (-not (Test-Path -LiteralPath $canaryEpf)) {
    Add-StepResult -Name 'Канареечный вход' -Status 'WARN' -Detail "нет обработки $canaryEpf (как собрать, см. README)"
}
elseif (-not (Test-Path -LiteralPath $v8c)) {
    Add-StepResult -Name 'Канареечный вход' -Status 'WARN' -Detail "нет тонкого клиента $v8c"
}
else {
    $userNumber = 0
    foreach ($user in $canaryUsers) {
        $userNumber++
        $userName = ''
        $userPassFile = ''
        if ($user.ContainsKey('Name') -and $null -ne $user['Name']) { $userName = [string]$user['Name'] }
        if ($user.ContainsKey('PassFile') -and $null -ne $user['PassFile']) { $userPassFile = [string]$user['PassFile'] }
        $label = $userName
        if ([string]::IsNullOrEmpty($label)) { $label = 'текущий пользователь Windows' }
        $stepName = "Канареечный вход: $label"

        $outFile = Join-Path $RunDir ("canary_{0}.txt" -f $userNumber)
        $userPassword = Get-PlainPassword $userPassFile
        $argList = @('ENTERPRISE') + @(Get-ConnectionArgs -User $userName -Password $userPassword) + @(
            '/DisableStartupDialogs',
            '/DisableStartupMessages',
            '/Execute', ('"{0}"' -f $canaryEpf),
            ('/C"canary;out={0};wait={1}"' -f $outFile, $canaryWaitSec)
        )
        $argLine = $argList -join ' '
        Write-RunLog ("> 1cv8c.exe {0}" -f ([regex]::Replace([regex]::Replace($argLine, '/P"[^"]*"', '/P"***"'), '/UC"[^"]*"', '/UC"***"')))

        Write-Host ("  ...  {0}: клиент запущен в {1}, жду не дольше {2} с" -f $stepName, (Get-Date -Format 'HH:mm:ss'), $canaryTimeoutSec) -ForegroundColor DarkGray
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $process = Start-Process -FilePath $v8c -ArgumentList $argLine -PassThru
        $null = $process.Handle

        # Ждём файл результата. Клиент после записи закрывается сам.
        $fileAppeared = $false
        while ($watch.Elapsed.TotalSeconds -lt $canaryTimeoutSec) {
            if (Test-Path -LiteralPath $outFile) { $fileAppeared = $true; break }
            if ($process.HasExited) { break }
            Write-UiProgress -Title $stepName -Elapsed $watch.Elapsed.TotalSeconds -Expected (Get-ExpectedStepSeconds $stepName)
            Start-Sleep -Milliseconds 250
        }
        Complete-UiProgress
        if (-not $fileAppeared -and (Test-Path -LiteralPath $outFile)) { $fileAppeared = $true }

        if ($fileAppeared) {
            if (-not $process.WaitForExit(60000)) {
                try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
            }
            $content = @(Get-Content -LiteralPath $outFile -Encoding UTF8)
            $statusLine = @($content | Where-Object { $_ -like 'status=*' } | Select-Object -First 1)
            $status = ''
            if ($statusLine.Count -gt 0) { $status = ([string]$statusLine[0]).Substring(7).Trim() }
            $notApplied = @($content | Where-Object { $_ -like 'ext=*|NOT_APPLIED' } | ForEach-Object { ($_.Substring(4) -split '\|')[0] })
            $activeCount = @($content | Where-Object { $_ -like 'ext=*|active' }).Count
            $extensionError = @($content | Where-Object { $_ -like 'exterror=*' } | Select-Object -First 1)
            $seconds = [int]$watch.Elapsed.TotalSeconds
            $canaryStat = 'FAIL'
            if ($status -eq 'ok') { $canaryStat = 'OK' }
            Add-StatFact -Title $stepName -Seconds $watch.Elapsed.TotalSeconds -Status $canaryStat

            if ($status -ne 'ok') {
                Add-StepResult -Name $stepName -Status 'FAIL' -Detail ("сеанс стартовал, но канарейка сообщила: {0}" -f ($content -join ' | ')) -Log $outFile -Seconds $seconds
            }
            elseif ($notApplied.Count -gt 0) {
                Add-StepResult -Name $stepName -Status 'FAIL' -Detail ("расширения есть в базе, но не применились в сеансе: {0}" -f ($notApplied -join ', ')) -Log $outFile -Seconds $seconds
            }
            elseif ($extensionError.Count -gt 0) {
                Add-StepResult -Name $stepName -Status 'OK' -Detail ("вошёл за {0} с; список расширений этому пользователю недоступен" -f $seconds) -Log $outFile -Seconds $seconds
            }
            else {
                Add-StepResult -Name $stepName -Status 'OK' -Detail ("вошёл за {0} с, расширений в сеансе: {1}" -f $seconds, $activeCount) -Log $outFile -Seconds $seconds
            }
        }
        elseif ($process.HasExited) {
            Add-StepResult -Name $stepName -Status 'FAIL' -Detail ("клиент закрылся сам, результата нет (код {0})" -f $process.ExitCode) -Seconds ([int]$watch.Elapsed.TotalSeconds)
        }
        else {
            # Сначала снимаем окна клиента, потом закрываем его.
            $windows = @(Save-ProcessWindows -ProcessId $process.Id -FilePrefix (Join-Path $RunDir ("canary_{0}" -f $userNumber)))
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
            [System.IO.File]::WriteAllLines((Join-Path $RunDir ("canary_{0}_windows.txt" -f $userNumber)), [string[]]$windows, $Utf8Bom)

            if (Test-Path -LiteralPath ($outFile + '.started')) {
                $stage = 'обработка открылась и разобрала параметр запуска, но результат не записала'
            }
            else {
                $stage = 'обработка не открылась, либо не сработал её обработчик ПриОткрытии, либо до неё не дошёл параметр запуска'
            }
            $detail = "за {0} с результата нет: {1}. Окна клиента: {2}" -f $canaryTimeoutSec, $stage, ($windows -join '; ')
            Add-StepResult -Name $stepName -Status 'FAIL' -Detail $detail -Seconds ([int]$watch.Elapsed.TotalSeconds)
        }
    }
}

# 5а. Выгрузка расширений в файлы и проверка правил обмена по ней (без 1С). Идёт до самопроверки «после»:
# что изменилось в правилах обмена (R3), нужно знать до её итогов. Та же выгрузка - для карты покрытия.
if (-not $processingOnly -and $proceed -and -not $script:StopRun -and (($runCoverage -and -not $SkipSelfCheck) -or $runExchangeRules)) {
    $script:ExtensionDumps = Invoke-ExtensionDumps
    if ($runExchangeRules) { Invoke-ExchangeRulesStep -Dumps $script:ExtensionDumps }
}

# Набор объектов для шага «Обмены» после загрузки - из прогона «до» (с комплектом). Без комплекта набор
# собирается заново: очередь узла и срезы - то, что уйдёт ближайшим обменом, - а итоги сравниваются с эталоном.
if ($kitItems.Count -gt 0 -and $exchangeBeforeFile) {
    $exchangeSetFile = Join-Path $RunDir 'exchange-set.txt'
    $beforeExchange = Read-ExchangeResults $exchangeBeforeFile
    if ($null -ne $beforeExchange -and $beforeExchange.Count -gt 0) { Write-ExchangeSetFile -Results $beforeExchange -Path $exchangeSetFile }
    else { $exchangeSetFile = '' }
}
if ($kitItems.Count -eq 0 -and (Test-Path -LiteralPath $selfCheckExchangeFile)) {
    $referenceExchangeCopy = Join-Path $referenceCopyDir 'selfcheck.exchange.txt'
    New-Item -ItemType Directory -Path $referenceCopyDir -Force | Out-Null
    Copy-Item -LiteralPath $selfCheckExchangeFile -Destination $referenceExchangeCopy -Force
    $exchangeBeforeFile = $referenceExchangeCopy
}

# 6. Самопроверка: автозапуск обработки «Выполнить после обновления». Красное - только то, чего нет в эталоне
# самопроверки: новые ошибки. Новые предупреждения и пропуски - жёлтое.
$afterName = 'Самопроверка'
if ($kitItems.Count -gt 0) { $afterName = 'Самопроверка после загрузки' }
$canaryFailed = (@($script:Steps | Where-Object { $_.name -like 'Канареечный вход*' -and $_.status -eq 'FAIL' }).Count -gt 0)

if ($processingOnly) {
    Write-RunLog ('Самопроверка не нужна: ' + $processingOnlyText)
}
elseif ($SkipSelfCheck) {
    Add-StepResult -Name $afterName -Status 'SKIP' -Detail $selfCheckOff
}
elseif (-not $runSelfCheck) {
    Write-RunLog 'Самопроверка выключена в config.psd1 (RunSelfCheck).'
}
elseif ($selfCheckOff) {
    Add-StepResult -Name $afterName -Status 'WARN' -Detail $selfCheckOff
}
elseif (-not $proceed) {
    Add-StepResult -Name $afterName -Status 'SKIP' -Detail 'пропущено: загрузка не прошла'
}
elseif ($canaryFailed) {
    Add-StepResult -Name $afterName -Status 'SKIP' -Detail 'пропущено: канареечный вход не прошёл, сеанс не запускается'
}
else {
    $after = Invoke-SelfCheck -Label 'after' -Known '' -Title $afterName -ExchangeSetFile $exchangeSetFile
    $minutes = [int][Math]::Ceiling($after.Seconds / 60)

    if ($after.State -ne 'done' -and $after.State -ne 'incomplete') {
        Add-StepResult -Name $afterName -Status 'FAIL' -Detail (Get-SelfCheckFailure $after) -Log $after.Journal -Seconds $after.Seconds
    }
    else {
        Save-SelfCheckLastState -Fingerprint $after.Fingerprint

        if (Test-Path -LiteralPath $selfCheckReferenceFile) {
            New-Item -ItemType Directory -Path $referenceCopyDir -Force | Out-Null
            Copy-Item -LiteralPath $selfCheckReferenceFile -Destination $referenceCopyDir -Force
        }
        $comparison = Compare-SelfCheck -Current $after.Records -ReferenceFile $selfCheckReferenceFile
        $newAll = @($comparison.NewErrors) + @($comparison.NewWarnings) + @($comparison.NewSkips)
        if ($newAll.Count -gt 0) {
            [System.IO.File]::WriteAllLines((Join-Path $RunDir 'selfcheck-after.new.txt'), [string[]]$newAll, $Utf8Bom)
        }

        $tail = "записей {0}, ошибок всего {1}; {2} мин; журнал selfcheck-after.journal.txt" -f $after.Records.Count, $comparison.ErrorsTotal, $minutes
        if ($after.Problems.Count -gt 0) { $tail += ('. Прогон неполный: ' + ($after.Problems -join ' | ')) }

        # Снимки шагов (сообщения обмена): тот же объект выгрузился по-другому - замечание (жёлтый).
        # Красным не делается: сообщение может измениться и по делу, решает человек, глядя на разницу.
        $snapshotChanged = 0
        if ($after.Snapshots.Count -gt 0 -or (Test-Path -LiteralPath $selfCheckSnapshotsFile)) {
            if (Test-Path -LiteralPath $selfCheckSnapshotsFile) {
                New-Item -ItemType Directory -Path $referenceCopyDir -Force | Out-Null
                Copy-Item -LiteralPath $selfCheckSnapshotsFile -Destination $referenceCopyDir -Force
            }
            $snapshotComparison = Compare-SelfCheckSnapshots -Current $after.Snapshots -ReferenceFile $selfCheckSnapshotsFile -DiffPath (Join-Path $RunDir 'selfcheck-after.snapshots.diff.txt')
            $snapshotChanged = $snapshotComparison.Changed.Count
            if (-not $snapshotComparison.HasReference) {
                $tail += ("; снимков {0}, эталонных снимков ещё нет" -f $snapshotComparison.Total)
            }
            else {
                $tail += ("; снимков {0}, изменились {1}, новых {2}, пропало {3}" -f $snapshotComparison.Total, $snapshotChanged, $snapshotComparison.Added.Count, $snapshotComparison.Gone.Count)
                if ($snapshotChanged -gt 0) {
                    $tail += (". Изменившиеся снимки: {0}; разница в selfcheck-after.snapshots.diff.txt" -f ((@($snapshotComparison.Changed | Select-Object -First 3)) -join ' | '))
                }
            }
            Write-RunLog ("Снимки самопроверки: всего {0}, изменились {1}, новых {2}, пропало {3}" -f $snapshotComparison.Total, $snapshotChanged, $snapshotComparison.Added.Count, $snapshotComparison.Gone.Count)
        }

        if (-not $comparison.HasReference) {
            if ($kitItems.Count -eq 0 -and $after.State -eq 'done') {
                Save-SelfCheckReference -Records $after.Records -Label 'after' -Fingerprint $after.Fingerprint -Snapshots $after.Snapshots -Exchange $after.Exchange
                $status = 'OK'
                if ($comparison.ErrorsTotal -gt 0 -or $after.Problems.Count -gt 0) { $status = 'WARN' }
                $detail = "эталона самопроверки не было: этот прогон стал эталоном, дальше красным будет только новое. Ошибки этого прогона посмотри в selfcheck-after.norm.txt. {0}" -f $tail
            }
            else {
                $status = 'WARN'
                if ($comparison.ErrorsTotal -gt 0) { $status = 'FAIL' }
                $detail = "сравнить не с чем: эталона самопроверки нет, а этот прогон эталоном стать не может (состояние до загрузки не снято либо прогон неполный). {0}" -f $tail
            }
        }
        else {
            $knownErrors = $comparison.ErrorsTotal - $comparison.NewErrors.Count
            $detail = "новых ошибок: {0}, новых предупреждений: {1}, новых пропусков: {2}; известных ошибок: {3}" -f $comparison.NewErrors.Count, $comparison.NewWarnings.Count, $comparison.NewSkips.Count, $knownErrors
            if ($comparison.FixedErrors -gt 0) { $detail += (", ошибок эталона, которых больше нет: {0}" -f $comparison.FixedErrors) }
            if ($comparison.GoneOk -gt 0) { $detail += (", проверок «ОК» из эталона, которых больше нет: {0}" -f $comparison.GoneOk) }
            $detail += ('; ' + $tail)
            if ($newAll.Count -gt 0) {
                $sample = (@($newAll | Select-Object -First 2 | ForEach-Object { if ($_.Length -gt 220) { $_.Substring(0, 220) + '...' } else { $_ } }) -join ' | ')
                $detail += (". Новое лежит в selfcheck-after.new.txt, начало: {0}" -f $sample)
            }

            if ($comparison.NewErrors.Count -gt 0) { $status = 'FAIL' }
            elseif ($newAll.Count -gt 0 -or $after.Problems.Count -gt 0 -or $snapshotChanged -gt 0) { $status = 'WARN' }
            else { $status = 'OK' }

            # Эталон двигается сам, только когда нового нет совсем. Иначе - после просмотра, ключом -AcceptBaseline.
            if ($status -eq 'OK' -and $after.State -eq 'done') {
                Save-SelfCheckReference -Records $after.Records -Label 'after' -Fingerprint $after.Fingerprint -Snapshots $after.Snapshots -Exchange $after.Exchange
            }
        }
        Add-StepResult -Name $afterName -Status $status -Detail $detail -Log $after.Journal -Seconds $after.Seconds
        # Обмены: итоги выгрузки «после» против «до» (с комплектом) или эталона (без комплекта).
        Invoke-ExchangeCompareStep -After $after.Exchange -BeforeFile $exchangeBeforeFile -WithKit ($kitItems.Count -gt 0)
        # Карта покрытия - по записям этой самопроверки; при неполном прогоне покрытие было бы занижено.
        if ($runCoverage -and $after.State -eq 'done' -and -not $script:StopRun) { Invoke-CoverageStep -Records $after.Records -ExchangeRan ($after.Exchange.Count -gt 0) }
        if ($after.Metrics.Count -gt 0 -or $beforeMetrics.Count -gt 0) { Invoke-MetricsStep -Before $beforeMetrics -After $after.Metrics }
    }
}

#endregion

# Проверка конфигурации, которая шла параллельно: дождаться и оценить, как обычно.
if ($null -ne $script:BackgroundCheck) { Complete-BackgroundCheck }

#region Вердикт

$failed = @($script:Steps | Where-Object { $_.status -eq 'FAIL' })
$warned = @($script:Steps | Where-Object { $_.status -eq 'WARN' })
$skipped = @($script:Steps | Where-Object { $_.status -eq 'SKIP' })

$verdict = 'GREEN'
$exitCode = 0
if ($warned.Count -gt 0 -or $skipped.Count -gt 0) { $verdict = 'YELLOW'; $exitCode = 2 }
if ($failed.Count -gt 0) { $verdict = 'RED'; $exitCode = 1 }

function Write-RunSummary {
    # Итог прогона: verdict.json для машины и summary.txt для человека. Если после вердикта решали,
    # что делать с комплектом, итог записывается второй раз, уже с этим решением.
    param([string]$KitDecision, [string[]]$Aftermath)
    $summary = [pscustomobject]@{
        runId       = $runId
        baseKey     = $baseKey
        kit         = $Kit
        kitItems    = @($kitItems | ForEach-Object { [pscustomobject]@{ name = $_.Name; kind = $_.Kind; version = $_.Version; source = $_.Source; label = $_.Label; path = $_.Path; wasInBase = $_.WasInBase } })
        kitProcessings = @($kitProcessings | ForEach-Object { [pscustomobject]@{ name = $_.Name; kind = $_.Kind; fileName = $_.FileName; isReport = $_.IsReport; path = $_.Path; file = $_.File; objectName = $_.ObjectName; ref = $_.Ref; isNew = $_.IsNew; oldVersion = $_.OldVersion; newVersion = $_.NewVersion; oldB64 = $_.OldB64; oldFile = $_.OldFile; touched = $_.Touched } })
        verdict     = $verdict
        failed      = $failed.Count
        warned      = $warned.Count
        skipped     = $skipped.Count
        steps       = $script:Steps.ToArray()
        kitDecision = $KitDecision
        aftermath   = @($Aftermath)
        preparation = @($script:PrepLines)
    }
    [System.IO.File]::WriteAllText((Join-Path $RunDir 'verdict.json'), ($summary | ConvertTo-Json -Depth 6), $Utf8Bom)

    $text = New-Object System.Collections.Generic.List[string]
    $text.Add(("Прогон {0}, база {1}" -f $runId, $baseKey))
    $text.Add(("Комплект: {0}" -f $Kit))
    $text.Add(("Вердикт: {0}" -f $verdict))
    $text.Add('')
    if ($script:PrepLines.Count -gt 0) {
        $text.Add('Подготовка базы:')
        foreach ($line in $script:PrepLines) { $text.Add(('  ' + $line)) }
        $text.Add('')
    }
    foreach ($step in $script:Steps) {
        $text.Add(("[{0,-4}] {1}" -f $step.status, $step.name))
        if ($step.detail) { $text.Add(("       {0}" -f $step.detail)) }
    }
    if (@($Aftermath).Count -gt 0) {
        $text.Add('')
        $text.Add('После вердикта:')
        foreach ($line in $Aftermath) { $text.Add(('  ' + $line)) }
    }
    [System.IO.File]::WriteAllLines((Join-Path $RunDir 'summary.txt'), $text.ToArray(), $Utf8Bom)
}

# Итог пишется сразу: вопрос про комплект может ждать ответа сколько угодно.
Write-RunSummary -KitDecision '' -Aftermath @()

function Invoke-RunReport {
    # Разбор прогона (report.ps1): где и какая ошибка, почему, что делать. Сбой разбора прогон не портит.
    param([bool]$Quiet)
    $reportScript = Join-Path $Root 'report.ps1'
    if (-not (Test-Path -LiteralPath $reportScript)) {
        if (-not $Quiet) { Write-Host 'Разбора прогона нет: рядом с run.ps1 нет report.ps1.' -ForegroundColor DarkGray }
        return
    }
    try {
        if ($Quiet) { & $reportScript -RunDir $RunDir -Quiet } else { & $reportScript -RunDir $RunDir }
    }
    catch {
        # Где именно упало: файл, строка и её текст - иначе по «Argument types do not match» не найти.
        $where = ''
        if ($null -ne $_.InvocationInfo) {
            $where = " ({0}, строка {1}: {2})" -f (Split-Path -Leaf ([string]$_.InvocationInfo.ScriptName)), $_.InvocationInfo.ScriptLineNumber, ([string]$_.InvocationInfo.Line).Trim()
        }
        Write-Host ("Разбор прогона не получился: {0}{1}. Запустить отдельно: .\report.cmd `"{2}`"" -f $_.Exception.Message, $where, $RunDir) -ForegroundColor Yellow
        Write-RunLog ("Разбор прогона не получился: {0}{1}`r`n{2}" -f $_.Exception.Message, $where, $_.ScriptStackTrace)
    }
}

# План и факт по шагам: насколько прогноз длительности совпал (stats.ps1).
$statLines = @(Get-StatRunLines)
if ($statLines.Count -gt 0) {
    Write-Host ''
    Write-Host 'Длительность шагов, факт и план:'
    foreach ($line in $statLines) { Write-Host $line -ForegroundColor DarkGray }
}

Write-Host ''
if ($verdict -eq 'GREEN') {
    Write-Host 'ВЕРДИКТ: ЗЕЛЁНЫЙ. Этот слой проверок пройден.' -ForegroundColor Green
}
elseif ($verdict -eq 'YELLOW') {
    Write-Host 'ВЕРДИКТ: ЖЁЛТЫЙ. Красного нет, но есть что посмотреть глазами или шаги были пропущены.' -ForegroundColor Yellow
}
else {
    Write-Host 'ВЕРДИКТ: КРАСНЫЙ. В рабочую этот комплект не ставим.' -ForegroundColor Red
}
Write-Host ("Итог и логи: {0}" -f $RunDir)
if ($verdict -ne 'GREEN') { Invoke-RunReport -Quiet $false } else { Invoke-RunReport -Quiet $true }

# Что делать с комплектом. Вопрос задаётся, когда комплект загружался, а вердикт красный или жёлтый
# с замечаниями. Жёлтый только из-за шагов, пропущенных ключами, вопроса не вызывает.
$tried = @($kitItems | Where-Object { $_.LoadTried })
$touched = @($tried | Where-Object { $_.Touched })
$triedProcessings = @($kitProcessings | Where-Object { $_.Tried })
$touchedProcessings = @($triedProcessings | Where-Object { $_.Touched })
$anyTouched = $touched.Count + $touchedProcessings.Count
$decision = ''

if (($kitItems.Count + $kitProcessings.Count) -gt 0 -and $anyTouched -eq 0) {
    Write-Host 'Ничего из комплекта в базу не загрузилось: откатывать нечего.'
}
elseif ($anyTouched -gt 0 -and ($failed.Count + $warned.Count) -eq 0) {
    if ($touched.Count -gt 0) { Write-Host ("Комплект остаётся в базе. Прежние версии расширений сохранены в {0}" -f (Join-Path $RunDir 'before')) }
    else { Write-Host 'Комплект остаётся в базе.' }
    if ($touchedProcessings.Count -gt 0) { Write-Host ("Прежние версии обработок (где они были) сохранены в {0}" -f $processingsDir) }
}
elseif ($anyTouched -gt 0) {
    # Откат идёт в порядке, обратном загрузке: сначала обработки (они записывались последними), потом расширения.
    [array]::Reverse($tried)
    [array]::Reverse($triedProcessings)
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($proc in $triedProcessings) {
        if (-not $proc.Touched) {
            $plan.Add([pscustomobject]@{ Name = $proc.Name; Action = 'skip'; Backup = ''; Processing = $proc
                    Text = ("{0}: в справочник не записана, откатывать нечего" -f $proc.Name) })
        }
        elseif ($proc.OldB64) {
            $plan.Add([pscustomobject]@{ Name = $proc.Name; Action = 'epfrestore'; Backup = $proc.OldB64; Processing = $proc
                    Text = ("{0}: вернуть в справочник прежнюю версию{1}" -f $proc.Name, $(if ($proc.OldVersion) { ' ' + $proc.OldVersion } else { '' })) })
        }
        elseif ($proc.IsNew -eq 'yes' -and $proc.Ref) {
            $plan.Add([pscustomobject]@{ Name = $proc.Name; Action = 'epfremove'; Backup = ''; Processing = $proc
                    Text = ("{0}: снять из справочника (публикация «Отключена», пометка удаления) - до записи её там не было" -f $proc.Name) })
        }
        else {
            $plan.Add([pscustomobject]@{ Name = $proc.Name; Action = 'none'; Backup = ''; Processing = $proc
                    Text = ("{0}: останется как есть - неизвестно, что было в справочнике до записи" -f $proc.Name) })
        }
    }
    foreach ($item in $tried) {
        if (-not $item.Touched) {
            $plan.Add([pscustomobject]@{ Name = $item.Name; Action = 'skip'; Backup = ''
                    Text = ("{0}: не загрузилось, откатывать нечего" -f $item.Name) })
        }
        elseif ($item.WasInBase -eq 'no') {
            $plan.Add([pscustomobject]@{ Name = $item.Name; Action = 'delete'; Backup = ''
                    Text = ("{0}: удалить из базы, до загрузки его там не было" -f $item.Name) })
        }
        elseif ($item.Backup) {
            $plan.Add([pscustomobject]@{ Name = $item.Name; Action = 'restore'; Backup = $item.Backup
                    Text = ("{0}: вернуть прежнюю версию из before\{1}" -f $item.Name, (Split-Path -Leaf $item.Backup)) })
        }
        else {
            $reason = 'прежняя версия не сохранена'
            if ($item.WasInBase -eq 'unknown') { $reason = 'неизвестно, было ли оно в базе до загрузки, и прежняя версия не сохранена' }
            $plan.Add([pscustomobject]@{ Name = $item.Name; Action = 'none'; Backup = ''
                    Text = ("{0}: останется как есть - {1}" -f $item.Name, $reason) })
        }
    }
    $actionable = @($plan | Where-Object { @('delete', 'restore', 'epfrestore', 'epfremove') -contains $_.Action })
    $aftermath = New-Object System.Collections.Generic.List[string]
    $decision = 'kept'
    $acceptAfterDecision = $false

    Write-Host ''
    if ($actionable.Count -eq 0) {
        Write-Host 'Комплект остался в базе, и откатить его скрипт не может:' -ForegroundColor Yellow
        $aftermath.Add('Комплект оставлен в базе: откатить нечем.')
        foreach ($entry in $plan) {
            Write-Host ('  ' + $entry.Text)
            $aftermath.Add($entry.Text)
        }
    }
    else {
        Write-Host ("Комплект загружен в {0}. Что сделает откат:" -f $baseKey)
        foreach ($entry in $plan) { Write-Host ('  ' + $entry.Text) }

        $rollback = $false
        if ($kitPolicy -eq 'Rollback') {
            $rollback = $true
            Write-Host 'Откатываю без вопроса: так задано ключом -OnNotGreen или настройкой OnNotGreen.'
        }
        elseif ($kitPolicy -eq 'Keep') {
            Write-Host 'Комплект оставлен в базе: так задано ключом -OnNotGreen или настройкой OnNotGreen.'
            $aftermath.Add('Комплект оставлен в базе: так задано ключом -OnNotGreen или настройкой OnNotGreen.')
        }
        else {
            $canAsk = Test-UiCanAsk
            $answer = ''
            if ($canAsk) {
                # В ci.exe - кнопками внизу: чтобы решить, итог прогона над вопросом должен быть виден.
                $acceptLabel = 'Оставить и принять новое в эталон'
                if ($verdict -eq 'RED') { $acceptLabel = 'Оставить и принять новое в эталон (прогон КРАСНЫЙ)' }
                $picked = Read-UiChoice -Header ("Комплект в {0}: оставить или откатить?" -f $baseKey) -Keys @('1', '2', '3') `
                    -Labels @('Оставить', $acceptLabel, 'Откатить') -DefaultKey '1' -Dock `
                    -Notes @('Новое этого прогона - в report.txt и *.new.txt. «Принять в эталон» - оно станет известным и больше не будет красить прогоны.')
                if ($picked -eq '1') { $answer = '1' }
                elseif ($picked -eq '2') { $answer = '1'; $acceptAfterDecision = $true }
                elseif ($picked -eq '3') { $answer = '2' }
            }
            if ($answer -eq '2') {
                $rollback = $true
            }
            elseif ($answer -eq '1') {
                $aftermath.Add('Комплект оставлен в базе: так решено после вердикта.')
            }
            elseif ($canAsk) {
                Write-Host 'Ответа нет (Esc): комплект оставлен в базе.'
                $aftermath.Add('Комплект оставлен в базе: на вопрос не ответили.')
            }
            else {
                Write-Host 'Спросить некого, запуск без консоли: комплект оставлен в базе.'
                $aftermath.Add('Комплект оставлен в базе: вопрос задать было некому.')
            }
        }

        if ($rollback) {
            $outcome = Invoke-KitRollback -Plan $plan.ToArray()
            if ($outcome.Done) {
                $decision = 'rolledBack'
                $aftermath.Add('Откат выполнен: комплект возвращён к состоянию до загрузки.')
                # Эталон самопроверки и отпечаток возвращаются к тем, что были перед загрузкой.
                foreach ($name in @('selfcheck.norm.txt', 'selfcheck.info.txt', 'selfcheck.last.txt', 'selfcheck.snapshots.txt', 'coverage.txt')) {
                    $savedFile = Join-Path $referenceSnapshotDir $name
                    $currentFile = Join-Path $baselineDir $name
                    if (Test-Path -LiteralPath $savedFile) { Copy-Item -LiteralPath $savedFile -Destination $currentFile -Force }
                    elseif (Test-Path -LiteralPath $currentFile) { Remove-Item -LiteralPath $currentFile -Force }
                }
                Write-Host 'Откат выполнен: комплект возвращён к состоянию до загрузки.' -ForegroundColor Green
                Write-Host 'Проверить базу после отката: .\run.cmd -SkipChecks (вход и самопроверка).'
            }
            else {
                $decision = 'rollbackFailed'
                $aftermath.Add('Откат выполнен не полностью: база в промежуточном состоянии.')
                # Отпечаток убирается: в следующем прогоне состояние «до загрузки» снимется заново.
                if (Test-Path -LiteralPath $selfCheckLastFile) { Remove-Item -LiteralPath $selfCheckLastFile -Force }
                Write-Host 'Откат выполнен не полностью: база в промежуточном состоянии. Что не получилось, видно выше и в логах rollback_*.log.' -ForegroundColor Red
                Write-Host ("Прежние версии лежат в {0}: закрой конфигуратор и загрузи их оттуда." -f (Join-Path $RunDir 'before'))
            }
            foreach ($line in $outcome.Lines) { $aftermath.Add($line) }
        }
    }
    if ($acceptAfterDecision -and $decision -eq 'kept') {
        try {
            Invoke-AcceptBaseline -RunPath $RunDir
            $aftermath.Add('Новое этого прогона принято в эталон.')
            Write-Host 'Новое этого прогона принято в эталон.' -ForegroundColor Green
        }
        catch {
            $aftermath.Add(('В эталон не принято: {0}' -f $_.Exception.Message))
            Write-Host ('В эталон не принято: {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
    }
    Write-RunLog ("Решение по комплекту после вердикта: {0}" -f $decision)
    Write-RunSummary -KitDecision $decision -Aftermath $aftermath.ToArray()
    Invoke-RunReport -Quiet $true
}

# После отката принимать замечания прогона незачем: в базе стоит уже не этот комплект.
if ($decision -ne 'rolledBack' -and $decision -ne 'rollbackFailed' -and $verdict -ne 'GREEN' -and -not (Test-Path -LiteralPath (Join-Path $RunDir 'accepted.txt'))) {
    if ($UiChannel) { Write-Host 'Принять новое этого прогона в эталон: Enter - в меню, пункт «Принять новое последнего прогона в эталон».' }
    else { Write-Host ("Принять новое этого прогона в эталон: .\run.cmd без ключей - пункт меню, или .\run.ps1 -AcceptBaseline `"{0}`"" -f $RunDir) }
}

# Обновления, которые остались в базе, переносятся из inbox в папку прогона: в inbox остаётся то, что ещё
# не стоит в erp_temp. Откаченный комплект остаётся в inbox.
if ($decision -ne 'rolledBack' -and $decision -ne 'rollbackFailed') {
    $movedFrom = @(@($kitItems) + @($kitProcessings) | Where-Object { $_.Touched -and $_.InboxItem } | ForEach-Object { $_.InboxItem } | Sort-Object -Unique)
    if ($movedFrom.Count -gt 0) {
        $movedDir = Join-Path $RunDir 'inbox'
        New-Item -ItemType Directory -Path $movedDir -Force | Out-Null
        $inboxFull = [System.IO.Path]::GetFullPath($inboxDir).TrimEnd('\')
        foreach ($source in $movedFrom) {
            if (-not (Test-Path -LiteralPath $source)) { continue }
            try {
                $parent = Split-Path -Parent $source
                Move-Item -LiteralPath $source -Destination $movedDir -Force
                Write-Host ("Перенёс из inbox в папку прогона: {0}" -f $source)
                Write-RunLog ("Перенесено из inbox: {0}" -f $source)
                # Опустевшие папки inbox (inbox\<дата>) убираются, сам inbox остаётся.
                while ($parent -and ([System.IO.Path]::GetFullPath($parent).TrimEnd('\')).Length -gt $inboxFull.Length -and
                    @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) {
                    $next = Split-Path -Parent $parent
                    Remove-Item -LiteralPath $parent -Force
                    $parent = $next
                }
            }
            catch {
                Write-Host ("Не перенёс {0}: {1}" -f $source, $_.Exception.Message) -ForegroundColor Yellow
                Write-RunLog ("Не перенесено из inbox: {0}: {1}" -f $source, $_.Exception.Message)
            }
        }
    }
}

Clear-TestBaseLocks

exit $exitCode

#endregion
