#requires -Version 5.1

# Каждое новое административное соединение должно подтвердить ту же цель, что и первое.
$script:ClusterBasePins = @{}

function Get-OptionalClusterUuid {
    param($Item)
    # COM платформы не обязан предоставлять UUID. Если провайдер его отдаёт, учитываем и его.
    $property = $Item.PSObject.Properties['UUID']
    if ($null -eq $property) { return '' }
    $id = [guid]$property.Value
    if ($id -eq [guid]::Empty) { throw 'Агент вернул пустой UUID цели.' }
    return $id.ToString('D')
}

function Get-ClusterDatabaseKey {
    param($InfoBase)
    $id = Get-OptionalClusterUuid $InfoBase
    if ($id) { return $id }
    # Свойства IInfoBaseInfo. Комбинация различает и две физические БД, зарегистрированные под одним именем.
    $dbServer = [string]$InfoBase.dbServerName
    $dbName = [string]$InfoBase.dbName
    if (-not $dbServer -or -not $dbName) { throw 'Не удалось определить сервер СУБД и имя БД.' }
    return (ConvertTo-Json -InputObject @([string]$InfoBase.DBMS, $dbServer.ToLowerInvariant(), $dbName) -Compress)
}

function Assert-ClusterEndpoint {
    param([string]$Server, $Cluster)
    $endpoint = [uri]('tcp://' + $Server)
    $port = $endpoint.Port
    if ($port -lt 0) { $port = 1541 }
    $actualHost = [string]$Cluster.HostName
    $sameHost = $endpoint.DnsSafeHost -ieq $actualHost
    if (-not $sameHost) {
        # Например, в Server записано короткое имя, агент возвращает FQDN.
        try { $sameHost = [System.Net.Dns]::GetHostEntry($endpoint.DnsSafeHost).HostName -ieq [System.Net.Dns]::GetHostEntry($actualHost).HostName }
        catch { $sameHost = $false }
    }
    if (-not $sameHost -or $port -ne [int]$Cluster.MainPort) {
        throw ("Адрес кластера {0}:{1} не совпадает с Server {2}. Проверь Server и ClusterAgent." -f $actualHost, $Cluster.MainPort, $Server)
    }
}

function Resolve-ClusterBase {
    param($Link, [string]$BaseName, [string]$User, [string]$Password)
    if (-not $Link.PSObject.Properties['Targets']) { $Link | Add-Member -NotePropertyName Targets -NotePropertyValue @{} }
    if ($Link.Targets.ContainsKey($BaseName)) { return $Link.Targets[$BaseName] }
    if ($null -eq $Link.Agent -or @($Link.Errors).Count) {
        throw ("Не удалось однозначно определить базу {0}: {1}" -f $BaseName, (@($Link.Errors) -join '; '))
    }

    # Каталог агента содержит одну короткую запись на регистрацию ИБ независимо от числа рабочих процессов.
    # Именно этот IInfoBaseShort нужен GetInfoBaseSessions, а для изменения свойств нужен полный IInfoBaseInfo.
    $chosenCluster = $null
    $short = $null
    foreach ($cluster in $Link.Clusters) {
        foreach ($base in @($Link.Agent.GetInfoBases($cluster))) {
            if ([string]$base.Name -ine $BaseName) { continue }
            if ($null -ne $short) { throw ("Неоднозначная цель: нашёл несколько регистраций базы {0}." -f $BaseName) }
            $chosenCluster = $cluster
            $short = $base
        }
    }
    if ($null -eq $short) { throw ("В кластерах агента не нашёл базу {0}." -f $BaseName) }
    if ($Link.PSObject.Properties['Server']) { Assert-ClusterEndpoint $Link.Server $chosenCluster }

    $workers = @($Link.Agent.GetWorkingProcesses($chosenCluster) | Where-Object { [int]$_.Running -eq 1 })
    $lastError = ''
    foreach ($worker in $workers) {
        try {
            $process = $Link.Connector.ConnectWorkingProcess(("tcp://{0}:{1}" -f $worker.HostName, $worker.MainPort))
            $process.AuthenticateAdmin($Link.ClusterUser, $Link.ClusterPassword)
            $process.AddAuthentication($User, $Password)
            $full = @($process.GetInfoBases() | Where-Object { [string]$_.Name -ieq $BaseName })
        }
        catch { $lastError = $_.Exception.Message; continue }
        if ($full.Count -eq 0) { continue }
        if ($full.Count -ne 1) { throw ("Неоднозначная цель: рабочий процесс вернул несколько баз {0}." -f $BaseName) }
        $info = $full[0]
        $shortId = Get-OptionalClusterUuid $short
        $fullId = Get-OptionalClusterUuid $info
        if ($shortId -and $fullId -and $shortId -ne $fullId) { throw ("UUID базы {0} не совпадает у агента и рабочего процесса." -f $BaseName) }
        try { $dbKey = Get-ClusterDatabaseKey $info }
        catch { $lastError = $_.Exception.Message; continue }
        $clusterKey = @(([string]$chosenCluster.HostName).ToLowerInvariant(), [int]$chosenCluster.MainPort, (Get-OptionalClusterUuid $chosenCluster))
        $identity = ConvertTo-Json -InputObject @($clusterKey, $BaseName.ToLowerInvariant(), $shortId, $dbKey) -Depth 3 -Compress
        if ($script:ClusterBasePins.ContainsKey($BaseName) -and $script:ClusterBasePins[$BaseName] -cne $identity) {
            throw ("Цель {0} не совпадает с кластером и ИБ в начале запуска." -f $BaseName)
        }
        $script:ClusterBasePins[$BaseName] = $identity
        $target = [pscustomobject]@{ Cluster = $chosenCluster; ShortBase = $short; Process = $process; InfoBase = $info; DatabaseKey = $dbKey; Identity = $identity }
        $Link.Targets[$BaseName] = $target
        return $target
    }
    throw ("Не прочитал свойства базы {0} ни в одном рабочем процессе выбранного кластера. {1}" -f $BaseName, $lastError)
}

function Get-CurrentClusterBase {
    param($Link, [string]$BaseName, [string]$User, [string]$Password)
    if ($Link.PSObject.Properties['Targets'] -and $Link.Targets.ContainsKey($BaseName)) {
        $target = $Link.Targets[$BaseName]
        try {
            $target.InfoBase = Read-ClusterBaseAgain $target $BaseName
            return $target
        }
        catch {
            # Рабочий процесс мог перезапуститься. Новое разрешение обязано подтвердить исходную цель.
            $Link.Targets.Remove($BaseName)
        }
    }
    return (Resolve-ClusterBase $Link $BaseName $User $Password)
}

function Read-ClusterBaseAgain {
    param($Target, [string]$BaseName)
    $found = @($Target.Process.GetInfoBases() | Where-Object { [string]$_.Name -ieq $BaseName })
    if ($found.Count -ne 1 -or (Get-ClusterDatabaseKey $found[0]) -cne $Target.DatabaseKey) {
        throw ("База {0} пропала или изменилась после выбора." -f $BaseName)
    }
    return $found[0]
}
