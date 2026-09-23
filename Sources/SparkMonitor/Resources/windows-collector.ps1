# Spark Manager: Windows-native, SSH-owned sampler. Native declarations are prepended by the client.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[SparkNative]::ExitWithSSHSession()
$counter = [SparkCounters]::new()
$paths = @{
 cpu='\Processor Information(*)\% Processor Time'; user='\Processor Information(*)\% User Time'; system='\Processor Information(*)\% Privileged Time'
 frequency='\Processor Information(_Total)\Processor Frequency'; performance='\Processor Information(_Total)\% Processor Performance'
 standbyCore='\Memory\Standby Cache Core Bytes'; standbyNormal='\Memory\Standby Cache Normal Priority Bytes'; standbyReserve='\Memory\Standby Cache Reserve Bytes'
 modified='\Memory\Modified Page List Bytes'; free='\Memory\Free & Zero Page List Bytes'
 diskIdle='\PhysicalDisk(*)\% Idle Time'; diskRead='\PhysicalDisk(*)\Disk Read Bytes/sec'; diskWrite='\PhysicalDisk(*)\Disk Write Bytes/sec'; diskLatency='\PhysicalDisk(*)\Avg. Disk sec/Transfer'
 engines='\GPU Engine(*)\Utilization Percentage'; gpuDedicated='\GPU Adapter Memory(*)\Dedicated Usage'; gpuShared='\GPU Adapter Memory(*)\Shared Usage'
}
foreach ($entry in $paths.GetEnumerator()) { $counter.Add($entry.Key,$entry.Value) }

function Device($id,$kind,$name,$model,$visible,$metadata) {
    @{id=$id;kind=$kind;name=$name;model=$model;defaultVisible=[bool]$visible;metadata=$metadata}
}
function Clamp($v) { if ($null -eq $v) { return $null }; [Math]::Min(100.0,[Math]::Max(0.0,[double]$v)) }
function Bytes($v) { [double]$v.ToUInt64() }
function EngineGroups($readings,$gpu) {
    $result=@{}
    foreach ($pair in $readings.GetEnumerator()) {
        if ($pair.Key -match ([regex]::Escape($gpu.Tag)+'_phys_0_eng_(\d+)_engtype_(.+)$')) {
            $key='engine:'+$Matches[1]
            if (!$result.ContainsKey($key)) { $result[$key]=@{name=$Matches[2];value=0.0} }
            $result[$key].value += $pair.Value
        }
    }
    $result
}
# Slow storage/firmware queries run in a separate in-process runspace, so
# they cannot pause the one-second PDH stream.
$sensorScript = {
    param($physicalDisks)
    $global:ProgressPreference='SilentlyContinue'
    $diskTemps=@{}; $cpuSensors=@{}
    foreach ($pd in $physicalDisks) {
        $reading=$pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        if ($null -ne $reading.Temperature -and $reading.Temperature -gt 0) { $diskTemps[[string]$pd.DeviceId]=[double]$reading.Temperature }
    }
    foreach ($zone in @(Get-CimInstance -Namespace root/wmi MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue)) {
        if ($zone.InstanceName -match 'CPU' -and $zone.CurrentTemperature -gt 0) { $cpuSensors[[string]$zone.InstanceName]=[Math]::Round($zone.CurrentTemperature/10.0-273.15,1) }
    }
    @{disk=$diskTemps;cpu=$cpuSensors}
}
$script:diskTemps=@{}; $script:cpuSensors=@{}
function Discover {
    $devices=[Collections.Generic.List[object]]::new()
    $cpus=@(Get-CimInstance Win32_Processor)
    $cores=($cpus | Measure-Object NumberOfCores -Sum).Sum
    $logical=($cpus | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    $cpuMeta=@{platform='windows';cores=[string]$cores;logicalProcessors=[string]$logical;sockets=[string]$cpus.Count;baseFrequency=[string]$cpus[0].MaxClockSpeed;virtualization=[string]$cpus[0].VirtualizationFirmwareEnabled;temperatureSource='ACPI'}
    $allCaches=@(Get-CimInstance Win32_CacheMemory)
    foreach ($level in 1..3) {
        $cache=@($allCaches | Where-Object {$_.Level -eq ($level+2)})
        if ($cache.Count -gt 0) { $cpuMeta['cacheL'+$level]=[string](1024*($cache | Measure-Object InstalledSize -Sum).Sum) }
    }
    $devices.Add((Device 'cpu' 'cpu' 'CPU' $cpus[0].Name.Trim() $true $cpuMeta))
    $ram=@(Get-CimInstance Win32_PhysicalMemory)
    $script:installedMemory=[double]($ram | Measure-Object Capacity -Sum).Sum
    $types=@{20='DDR';21='DDR2';24='DDR3';26='DDR4';27='LPDDR';28='LPDDR2';29='LPDDR3';30='LPDDR4';34='DDR5';35='LPDDR5'}
    $type=$types[[int]$ram[0].SMBIOSMemoryType]; if (!$type) { $type='RAM' }
    $slots=(Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object MemoryDevices -Sum).Sum
    $form=@{8='DIMM';12='SODIMM'}[[int]$ram[0].FormFactor]; if (!$form) {$form='Other'}
    $devices.Add((Device 'memory' 'memory' 'Memory' $type $true @{platform='windows';installed=[string]$script:installedMemory;speed=[string]$ram[0].ConfiguredClockSpeed;slots=('{0}/{1}' -f $ram.Count,$slots);form=$form}))
    $script:disks=@(Get-Disk)
    $script:physicalDisks=@(Get-PhysicalDisk)
    $pageFiles=@(Get-CimInstance Win32_PageFileUsage)
    $script:diskVolumes=@{}
    foreach ($disk in $script:disks) {
        $partitions=@(Get-Partition -DiskNumber $disk.Number)
        $letters=@($partitions | Where-Object {$_.DriveLetter} | ForEach-Object { [string]$_.DriveLetter+':' })
        $volumes=@($partitions | Get-Volume -ErrorAction SilentlyContinue | Where-Object {$_.Size -gt 0})
        $script:diskVolumes[[string]$disk.Number]=$volumes
        $pd=$script:physicalDisks | Where-Object {$_.DeviceId -eq [string]$disk.Number} | Select-Object -First 1
        $type=if ($disk.BusType -eq 'NVMe') {'SSD (NVMe)'} elseif ($pd.MediaType -eq 'SSD') {'SSD'} elseif ($pd.MediaType -eq 'HDD') {'HDD'} else {[string]$disk.BusType}
        $page=@($pageFiles | Where-Object {$letters -contains $_.Name.Substring(0,2)}).Count -gt 0
        $devices.Add((Device ('disk:'+$disk.Number) 'disk' ([string]$disk.Number) $disk.FriendlyName $true @{platform='windows';index=[string]$disk.Number;letters=($letters -join ' ');type=$type;system=([string][bool]$disk.IsBoot).ToLower();pagefile=([string]$page).ToLower()}))
    }
    $script:nets=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {$_.NetworkInterfaceType -ne 'Loopback'})
    $adapters=@(Get-NetAdapter -IncludeHidden)
    foreach ($net in $script:nets) {
        $adapter=$adapters | Where-Object {([string]$_.InterfaceGuid).Trim('{}') -eq $net.Id.Trim('{}')} | Select-Object -First 1
        $wifi=$net.NetworkInterfaceType -eq 'Wireless80211'
        $ip=$net.GetIPProperties()
        $meta=@{platform='windows';type=$(if($wifi){'Wi-Fi'}else{'Ethernet'});interface=$net.Name;ipv4=(@($ip.UnicastAddresses | Where-Object {$_.Address.AddressFamily -eq 'InterNetwork'} | ForEach-Object {$_.Address.ToString()}) -join ', ');ipv6=(@($ip.UnicastAddresses | Where-Object {$_.Address.AddressFamily -eq 'InterNetworkV6'} | ForEach-Object {$_.Address.ToString()}) -join ', ');dns=(@($ip.DnsAddresses | ForEach-Object {$_.ToString()}) -join ', ');domain=[string]$ip.DnsSuffix;mac=$net.GetPhysicalAddress().ToString();signalUnit='%'}
        if ($wifi) { $wi=[SparkNative]::Wifi($net.Id); if($wi.ContainsKey('ssid')) { $meta.ssid=[string]$wi.ssid; $meta.protocol=[string]$wi.protocol } }
        $devices.Add((Device ('net:'+$net.Id) 'network' $net.Name $net.Description ($adapter.HardwareInterface -and $net.OperationalStatus -eq 'Up') $meta))
    }
    $engineValues=$counter.Values('engines')
    $script:gpus=@([SparkNative]::GPUs() | Where-Object {(EngineGroups $engineValues $_).Count -gt 0})
    $script:gpuIDs=@{}
    $video=@(Get-CimInstance Win32_VideoController)
    $engineValues=$counter.Values('engines')
    for ($i=0;$i -lt $script:gpus.Count;$i++) {
        $gpu=$script:gpus[$i]
        $driver=$video | Where-Object {$_.Name -eq $gpu.Name} | Select-Object -First 1
        $script:gpuIDs[$gpu.Tag]='gpu:'+[string]$driver.PNPDeviceID
        $meta=@{platform='windows';index=[string]$i;dedicatedTotal=[string]$gpu.Dedicated;sharedTotal=[string]$gpu.Shared;directX=[string]$gpu.DirectX;pci=[string]$gpu.PCI;driver=[string]$driver.DriverVersion;driverDate=$(if($driver.DriverDate){$driver.DriverDate.ToString('yyyy/M/d')}else{''})}
        foreach ($e in (EngineGroups $engineValues $gpu).GetEnumerator()) { $meta[$e.Key]=$e.Value.name }
        $devices.Add((Device $script:gpuIDs[$gpu.Tag] 'gpu' ('GPU '+$i) $gpu.Name ($gpu.Vendor -ne 0x1414) $meta))
    }
    $script:inventory=@{hostname=$env:COMPUTERNAME;platform='windows';devices=@($devices.ToArray())}
    [Console]::WriteLine((@{inventory=$script:inventory;samplerPid=$PID} | ConvertTo-Json -Depth 8 -Compress))
}

try {
    $counter.Collect()
    Start-Sleep -Milliseconds 1000
    $counter.Collect()
    Discover
    $sensorWorker=[PowerShell]::Create()
    [void]$sensorWorker.AddScript($sensorScript.ToString()).AddArgument($script:physicalDisks)
    $sensorTask=$sensorWorker.BeginInvoke()
    $lastSensor=[Diagnostics.Stopwatch]::StartNew()
    $lastNet=@{}; $lastTime=[Diagnostics.Stopwatch]::StartNew(); $tick=0
    while ($true) {
        $start=[Diagnostics.Stopwatch]::StartNew()
        $counter.Collect()
        if ($null -ne $sensorTask -and $sensorTask.IsCompleted) {
            $result=$sensorWorker.EndInvoke($sensorTask)
            if ($result.Count -gt 0) { $script:diskTemps=$result[0].disk; $script:cpuSensors=$result[0].cpu }
            $sensorTask=$null
        }
        if ($null -eq $sensorTask -and $lastSensor.Elapsed.TotalSeconds -ge 15) {
            $sensorTask=$sensorWorker.BeginInvoke(); $lastSensor.Restart()
        }
        $cpu=$counter.Values('cpu'); $user=$counter.Values('user'); $system=$counter.Values('system')
        $cores=@($cpu.Keys | Where-Object {$_ -match '^\d+,\d+$'} | Sort-Object {[int]($_.Split(',')[0])},{[int]($_.Split(',')[1])})
        $p=[SparkNative]::Memory(); $page=Bytes $p.PageSize
        $total=(Bytes $p.PhysicalTotal)*$page; $available=(Bytes $p.PhysicalAvailable)*$page
        $modified=$counter.Scalar('modified'); $standby=$counter.Scalar('standbyCore')+$counter.Scalar('standbyNormal')+$counter.Scalar('standbyReserve')
        $freq=$counter.Scalar('frequency'); $perf=$counter.Scalar('performance'); if ($null -ne $freq -and $null -ne $perf) {$freq=$freq*$perf/100.0}
        $cv=@{usage=(Clamp $cpu['_Total']);user=$user['_Total'];system=$system['_Total'];frequency=$freq;processes=[double]$p.Processes;threads=[double]$p.Threads;handles=[double]$p.Handles;temperature=$null}
        if ($script:cpuSensors.Count -gt 0) {$cv.temperature=($script:cpuSensors.Values | Measure-Object -Maximum).Maximum}
        $coreValues=@(for ($i=0;$i -lt $cores.Count;$i++) { $k=$cores[$i]; @{index=$i;usage=(Clamp $cpu[$k]);user=$user[$k];system=$system[$k]} })
        $used=$total-$available-$modified
        $metrics=@{cpu=@{values=$cv;cores=$coreValues;sensors=$script:cpuSensors};memory=@{values=@{total=$total;used=$used;available=$available;usage=$used*100/$total;committed=(Bytes $p.CommitTotal)*$page;commitLimit=(Bytes $p.CommitLimit)*$page;cached=$standby+$modified;paged=(Bytes $p.KernelPaged)*$page;nonpaged=(Bytes $p.KernelNonpaged)*$page;modified=$modified;standby=$standby;free=$counter.Scalar('free');reserved=$script:installedMemory-$total}}}
        $idle=$counter.Values('diskIdle'); $read=$counter.Values('diskRead'); $write=$counter.Values('diskWrite'); $latency=$counter.Values('diskLatency')
        foreach ($disk in $script:disks) {
            $index=[string]$disk.Number; $instance=$idle.Keys | Where-Object {($_ -split ' ')[0] -eq $index} | Select-Object -First 1
            $volumes=$script:diskVolumes[$index]
            $metrics['disk:'+$index]=@{values=@{usage=$(if($instance){Clamp (100-$idle[$instance])}else{$null});read=$(if($instance){$read[$instance]}else{$null});write=$(if($instance){$write[$instance]}else{$null});latency=$(if($instance){$latency[$instance]*1000}else{$null});capacity=[double]$disk.Size;total=($volumes | Measure-Object Size -Sum).Sum;free=($volumes | Measure-Object SizeRemaining -Sum).Sum;temperature=$script:diskTemps[$index]}}
        }
        $elapsed=$lastTime.Elapsed.TotalSeconds; $lastTime.Restart()
        foreach ($net in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($net.NetworkInterfaceType -eq 'Loopback') {continue}
            $n=$net.GetIPStatistics(); $old=$lastNet[$net.Id]; $rx=$null; $tx=$null
            if ($null -ne $old -and $elapsed -gt 0 -and $n.BytesReceived -ge $old[0] -and $n.BytesSent -ge $old[1]) { $rx=($n.BytesReceived-$old[0])/$elapsed; $tx=($n.BytesSent-$old[1])/$elapsed }
            $lastNet[$net.Id]=@($n.BytesReceived,$n.BytesSent)
            $values=@{receive=$rx;send=$tx;linkSpeed=$net.Speed/1e6;up=$(if($net.OperationalStatus -eq 'Up'){1}else{0});errors=$n.IncomingPacketsWithErrors+$n.OutgoingPacketsWithErrors;drops=$n.IncomingPacketsDiscarded+$n.OutgoingPacketsDiscarded}
            if ($net.NetworkInterfaceType -eq 'Wireless80211') { $wi=[SparkNative]::Wifi($net.Id); foreach ($k in @('signal','rxSpeed','txSpeed')) { $values[$k]=$wi[$k] } }
            $metrics['net:'+$net.Id]=@{values=$values}
        }
        $engineValues=$counter.Values('engines'); $dedicated=$counter.Values('gpuDedicated'); $shared=$counter.Values('gpuShared')
        foreach ($gpu in $script:gpus) {
            $engines=EngineGroups $engineValues $gpu
            $values=@{usage=$null;temperature=[SparkNative]::GPUTemperature($gpu);dedicatedTotal=[double]$gpu.Dedicated;sharedTotal=[double]$gpu.Shared;dedicatedUsed=$null;sharedUsed=$null}
            if ($engines.Count -gt 0) { $values.usage=Clamp (($engines.Values | ForEach-Object {$_['value']} | Measure-Object -Maximum).Maximum) }
            foreach ($e in $engines.GetEnumerator()) { $values[$e.Key]=Clamp $e.Value.value }
            $instance=$dedicated.Keys | Where-Object {$_ -like ($gpu.Tag+'_phys_0')} | Select-Object -First 1
            if ($instance) { $values.dedicatedUsed=$dedicated[$instance]; $values.sharedUsed=$shared[$instance] }
            $metrics[$script:gpuIDs[$gpu.Tag]]=@{values=$values}
        }
        $snapshot=@{timestamp=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0;uptime=[SparkNative]::GetTickCount64()/1000.0;devices=$metrics}
        [Console]::WriteLine((@{snapshot=$snapshot} | ConvertTo-Json -Depth 8 -Compress))
        $tick++
        $delay=[Math]::Max(0,1000-$start.ElapsedMilliseconds)
        if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
    }
} finally { if ($sensorWorker) { $sensorWorker.Stop(); $sensorWorker.Dispose() }; $counter.Dispose() }
