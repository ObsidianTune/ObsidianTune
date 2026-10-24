#requires -Version 5.1
# ObsidianTune - a single-file, Windows-only WPF performance settings console.
# All toggles are opt-in action selectors. Selecting one runs that action once;
# toggles do not pretend to report the current Windows setting.
# Persistent changes are written to Windows itself and survive closing this app;
# one-time cleanup/cache actions run once. No background service is installed.
# Review each description and keep the default restore-point option enabled.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $env:OS -or $env:OS -ne 'Windows_NT') {
    throw 'ObsidianTune runs on Windows only.'
}

# A saved .ps1 launched with "Run with PowerShell" is normally a standard-user
# process. Relaunch it through the normal Windows UAC flow so users do not need
# to open an administrator PowerShell window themselves. The packaged EXE has a
# requireAdministrator manifest, so its embedded stdin-hosted script is already
# elevated before this point.
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $script:IsAdmin) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or -not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
        $message = 'No settings were changed. Run the saved ObsidianTune.ps1 file or launch ObsidianTune.exe so Windows can request administrator approval.'
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            [System.Windows.Forms.MessageBox]::Show($message, 'Administrator access required', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } catch {
            Write-Warning $message
        }
        exit 1
    }

    try {
        $elevatedPowerShell = Join-Path $PSHOME 'powershell.exe'
        $quotedScriptPath = '"' + $PSCommandPath + '"'
        $elevatedArguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File ' + $quotedScriptPath
        Start-Process -FilePath $elevatedPowerShell -ArgumentList $elevatedArguments -WorkingDirectory (Split-Path -Parent $PSCommandPath) -Verb RunAs -ErrorAction Stop | Out-Null
        exit 0
    } catch {
        $message = if ($_.Exception.HResult -eq -2147023673) {
            'Administrator approval was cancelled. No settings were changed.'
        } else {
            'Windows could not start ObsidianTune with administrator access. No settings were changed.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message
        }
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            [System.Windows.Forms.MessageBox]::Show($message, 'Administrator access required', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } catch {
            Write-Warning $message
        }
        exit 1
    }
}

# WPF requires STA. Do not silently relaunch another PowerShell process.
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Host 'ObsidianTune needs Windows PowerShell in STA mode. No settings were changed.' -ForegroundColor Yellow
    Write-Host 'Open Windows PowerShell and run: powershell.exe -STA -File "<path to ObsidianTune.ps1>"' -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
    exit 1
}

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:Tweaks = @(
    [pscustomobject]@{ Id='nagle'; Category='Windows OS & Gaming Latency'; Name='Disable Nagle algorithm'; Risk='Moderate'; Description='Sets TcpNoDelay=1 on active TCP/IP interfaces. Can help some latency-sensitive workloads; may increase packet count.' }
    [pscustomobject]@{ Id='hags'; Category='Windows OS & Gaming Latency'; Name='Enable Hardware-Accelerated GPU Scheduling'; Risk='Moderate'; Description='Requests HAGS through GraphicsDrivers\HwSchMode=2. Driver and GPU support vary; reboot is normally required.' }
    [pscustomobject]@{ Id='mmcss'; Category='Windows OS & Gaming Latency'; Name='Tune MMCSS Games task priorities'; Risk='Moderate'; Description='Sets GPU Priority=8 and Priority=6 for the Games task. Affects applications that register with MMCSS; workload dependent.' }
    [pscustomobject]@{ Id='gamedvr'; Category='Windows OS & Gaming Latency'; Name='Disable Game DVR and Game Bar capture'; Risk='Low'; Description='Turns off Windows background capture and Game Bar policy for this machine/user.' }
    [pscustomobject]@{ Id='gpu_preference'; Category='Windows OS & Gaming Latency'; Name='Set an app to High Performance GPU'; Risk='Low'; Description='Choose an executable; stores the documented per-app Windows GPU preference. Hybrid-GPU systems only.' }
    [pscustomobject]@{ Id='thread_sched'; Category='Windows OS & Gaming Latency'; Name='Set Games thread scheduling category to High'; Risk='Moderate'; Description='Sets MMCSS Games task Scheduling Category and SFIO Priority to High. Affects registered game workloads and can change background I/O scheduling.' }
    [pscustomobject]@{ Id='hibernate'; Category='Windows OS & Gaming Latency'; Name='Disable hibernation'; Risk='High'; Description='Runs powercfg /hibernate off. Removes hiberfil.sys and disables Hibernate and Fast Startup.' }
    [pscustomobject]@{ Id='telemetry'; Category='Windows OS & Gaming Latency'; Name='Set diagnostic data to the minimum'; Risk='Moderate'; Description='Sets AllowTelemetry=0. Windows edition and policy can limit or override this setting; some diagnostics may stop.' }
    [pscustomobject]@{ Id='cortana'; Category='Windows OS & Gaming Latency'; Name='Disable Cortana policy'; Risk='Moderate'; Description='Sets the legacy AllowCortana policy. Modern Windows Search behavior varies by Windows build.' }
    [pscustomobject]@{ Id='ntfs_cache'; Category='Windows OS & Gaming Latency'; Name='Increase NTFS memory usage'; Risk='Moderate'; Description='Sets NtfsMemoryUsage=2 (maximum cache preference). Can consume more kernel memory; workload dependent.' }
    [pscustomobject]@{ Id='startup_delay'; Category='Windows OS & Gaming Latency'; Name='Reduce startup app impact at sign-in'; Risk='Low'; Description='Adds a 10-second delay to current-user startup apps so they do not all compete immediately after sign-in.' }
    [pscustomobject]@{ Id='visual_effects'; Category='Windows OS & Gaming Latency'; Name='Prefer performance over visual effects'; Risk='Moderate'; Description='Selects the Windows best-performance visual-effects preset for the current user.' }
    [pscustomobject]@{ Id='admin_shares'; Category='Windows OS & Gaming Latency'; Name='Disable administrative file shares'; Risk='High'; Description='Disables automatic ADMIN$/C$ shares on workstations. May break remote management and deployment tools.' }
    [pscustomobject]@{ Id='background_apps'; Category='Windows OS & Gaming Latency'; Name='Disable background app access'; Risk='Moderate'; Description='Sets the legacy global background-app policy for the current user. Some apps may stop receiving background updates.' }
    [pscustomobject]@{ Id='responsiveness'; Category='Windows OS & Gaming Latency'; Name='Adjust MMCSS system responsiveness'; Risk='Moderate'; Description='Sets SystemResponsiveness=10. This changes the CPU share reserved for low-priority MMCSS work; it is not a universal latency improvement.' }

    [pscustomobject]@{ Id='tcp_window'; Category='Network & Ping'; Name='Use normal TCP receive-window auto-tuning'; Risk='Low'; Description='Sets TCP receive-window auto-tuning to normal using netsh. Windows manages the window dynamically.' }
    [pscustomobject]@{ Id='ack_frequency'; Category='Network & Ping'; Name='Set TCP ACK frequency to 1'; Risk='Moderate'; Description='Sets TcpAckFrequency=1 for active IPv4 interfaces. May increase ACK traffic and does not improve every connection.' }
    [pscustomobject]@{ Id='chimney'; Category='Network & Ping'; Name='Disable deprecated TCP Chimney Offload'; Risk='Low'; Description='Sets the legacy Chimney Offload switch to disabled. Current Windows versions already deprecate this feature.' }
    [pscustomobject]@{ Id='dns_cache'; Category='Network & Ping'; Name='Refresh DNS client cache'; Risk='Low'; Description='Flushes the Windows DNS resolver cache; entries repopulate as needed.' }
    [pscustomobject]@{ Id='netbios'; Category='Network & Ping'; Name='Disable NetBIOS over TCP/IP'; Risk='Moderate'; Description='Disables NetBIOS on enabled IPv4 adapters. Legacy discovery and name-resolution environments may depend on it.' }
    [pscustomobject]@{ Id='throttle_index'; Category='Network & Ping'; Name='Remove multimedia network throttling'; Risk='Moderate'; Description='Sets NetworkThrottlingIndex=0xFFFFFFFF. This legacy setting is workload dependent and may affect multimedia/network scheduling.' }
    [pscustomobject]@{ Id='rss'; Category='Network & Ping'; Name='Enable Receive Side Scaling'; Risk='Low'; Description='Enables RSS on adapters that expose the feature. Adapter driver support varies.' }
    [pscustomobject]@{ Id='lso'; Category='Network & Ping'; Name='Enable Large Send Offload'; Risk='Low'; Description='Enables IPv4/IPv6 LSO on adapters that support it. Microsoft generally recommends supported offloads; faulty drivers may behave differently.' }
    [pscustomobject]@{ Id='qos'; Category='Network & Ping'; Name='Set QoS non-best-effort limit to zero'; Risk='Moderate'; Description='Sets the policy value NonBestEffortLimit=0. This does not reserve bandwidth for every application and may be ignored without policy support.' }
    [pscustomobject]@{ Id='arp'; Category='Network & Ping'; Name='Clear the ARP cache'; Risk='Low'; Description='Runs arp -d *. Existing neighbor entries are relearned; the next local connection may pause briefly.' }

    [pscustomobject]@{ Id='standby'; Category='Memory & CPU'; Name='Purge the standby memory list'; Risk='High'; Description='Uses the native undocumented NT memory-list API. Windows will rebuild cached pages; this can cause extra disk I/O and stutter. Use only for diagnosis.' }
    [pscustomobject]@{ Id='pagefile'; Category='Memory & CPU'; Name='Let Windows manage pagefile size'; Risk='Low'; Description='Enables AutomaticManagedPagefile through the native WMI provider. Requires a restart to fully take effect.' }
    [pscustomobject]@{ Id='ultimate'; Category='Memory & CPU'; Name='Activate Ultimate Performance power plan'; Risk='Moderate'; Description='Creates the built-in plan if needed and activates it. Higher power draw, heat, fan noise, and reduced battery life are possible.' }
    [pscustomobject]@{ Id='core_parking'; Category='Memory & CPU'; Name='Disable processor core parking'; Risk='Moderate'; Description='Sets current-plan AC/DC minimum parked-core policy to 100%. Higher idle power and heat are possible.' }
    [pscustomobject]@{ Id='cache_keys'; Category='Memory & CPU'; Name='Set NTFS L2/L3 cache hints from detected cache'; Risk='Moderate'; Description='Reads WMI cache sizes and writes legacy SecondLevelDataCache/ThirdLevelDataCache hints only when each level is unambiguous. Windows normally detects these automatically.' }
    [pscustomobject]@{ Id='wer'; Category='Memory & CPU'; Name='Disable Windows Error Reporting'; Risk='Moderate'; Description='Disables and stops WerSvc. Crash reports and some troubleshooting data will no longer be collected.' }
    [pscustomobject]@{ Id='sysmain'; Category='Memory & CPU'; Name='Disable SysMain'; Risk='Moderate'; Description='Disables and stops SysMain. This can worsen application launch or memory behavior; test on your own workload.' }
    [pscustomobject]@{ Id='telemetry_services'; Category='Memory & CPU'; Name='Disable diagnostic tracking services'; Risk='Moderate'; Description='Disables and stops DiagTrack and dmwappushservice when present. Windows updates may restore service configuration.' }
    [pscustomobject]@{ Id='programs_priority'; Category='Memory & CPU'; Name='Prefer programs in processor scheduling'; Risk='Moderate'; Description='Sets the legacy Win32PrioritySeparation foreground-program policy to 0x26; background work can receive less CPU time.' }
    [pscustomobject]@{ Id='spectre'; Category='Memory & CPU'; Name='Disable Spectre/Meltdown mitigations'; Risk='Critical'; Description='Removes CPU side-channel protections using Microsoft-documented override values. This exposes the machine to security vulnerabilities and requires reboot. Only for isolated, controlled benchmarking.' }

    [pscustomobject]@{ Id='clean_temp'; Category='Storage & Disk Cleanup'; Name='Clean Temp and Prefetch files'; Risk='Moderate'; Description='Removes files in current-user Temp, Windows Temp, and Prefetch. Locked files are skipped; clearing Prefetch may slow later app launches.' }
    [pscustomobject]@{ Id='update_cache'; Category='Storage & Disk Cleanup'; Name='Clear downloaded Windows Update cache'; Risk='Moderate'; Description='Stops update services, removes SoftwareDistribution\Download contents, and restores services that were running. Windows may need to download updates again.' }
    [pscustomobject]@{ Id='trim'; Category='Storage & Disk Cleanup'; Name='Run Windows storage optimization'; Risk='Low'; Description='Runs Optimize-Volume for fixed volumes. Windows chooses ReTrim or an appropriate optimization for each volume type.' }
    [pscustomobject]@{ Id='short_names'; Category='Storage & Disk Cleanup'; Name='Disable NTFS 8.3 short-name creation'; Risk='Moderate'; Description='Sets the system-wide fsutil behavior to disable creation of new 8.3 names. Legacy applications may require short names.' }
    [pscustomobject]@{ Id='last_access'; Category='Storage & Disk Cleanup'; Name='Disable NTFS last-access updates'; Risk='Low'; Description='Sets the system-wide NTFS last-access behavior to disabled. Backup and file-management software may use timestamps.' }
    [pscustomobject]@{ Id='dumps'; Category='Storage & Disk Cleanup'; Name='Delete system crash dump files'; Risk='High'; Description='Permanently deletes MEMORY.DMP and minidump files. This removes evidence needed to diagnose crashes.' }
    [pscustomobject]@{ Id='delivery_limits'; Category='Storage & Disk Cleanup'; Name='Limit Delivery Optimization cache'; Risk='Low'; Description='Sets policy cache size to 5% and maximum age to 3 days. Delivery Optimization policy support varies by Windows edition.' }
    [pscustomobject]@{ Id='delivery_cache'; Category='Storage & Disk Cleanup'; Name='Clear Delivery Optimization cache'; Risk='Low'; Description='Runs the native Delete-DeliveryOptimizationCache cmdlet where available; downloaded content may be fetched again.' }
    [pscustomobject]@{ Id='search_indexer'; Category='Storage & Disk Cleanup'; Name='Delay Windows Search indexer after boot'; Risk='Low'; Description='Sets WSearch to Automatic (Delayed Start) to reduce startup contention; searches may take longer until indexing starts.' }
    [pscustomobject]@{ Id='recycle'; Category='Storage & Disk Cleanup'; Name='Empty the Recycle Bin'; Risk='High'; Description='Permanently deletes current-user Recycle Bin contents. Recovery through the Recycle Bin will no longer be available.' }

    [pscustomobject]@{ Id='telemetry_tasks'; Category='Privacy & Bloatware'; Name='Disable selected telemetry scheduled tasks'; Risk='Moderate'; Description='Disables selected Application Experience tasks when present. Windows servicing may recreate or re-enable them.' }
    [pscustomobject]@{ Id='uwp'; Category='Privacy & Bloatware'; Name='Remove selected inbox UWP apps for this user'; Risk='High'; Description='Removes a small allow-list of consumer apps from the current user only. App data is removed; Xbox, Store, and system packages are not targeted.' }
    [pscustomobject]@{ Id='consumer'; Category='Privacy & Bloatware'; Name='Disable Windows consumer experiences'; Risk='Low'; Description='Sets DisableWindowsConsumerFeatures policy to reduce suggested consumer app installs on supported editions.' }
    [pscustomobject]@{ Id='hosts'; Category='Privacy & Bloatware'; Name='Block selected Microsoft telemetry hosts'; Risk='Moderate'; Description='Backs up the hosts file, appends a small fixed block list, then flushes DNS. Hosts entries can be bypassed and may disrupt diagnostics.' }
    [pscustomobject]@{ Id='cloud_sync'; Category='Privacy & Bloatware'; Name='Disable OneDrive sync policy'; Risk='High'; Description='Stops OneDrive and sets the machine policy that disables file sync. Ensure files are available locally before applying.' }
)

# These are deliberately labeled as one-time operations in the UI. Their effect
# does not depend on ObsidianTune remaining open, but they do not continuously
# tune the system after the operation finishes.
$script:OneTimeActionIds = @('dns_cache','standby','arp','clean_temp','update_cache','trim','dumps','delivery_cache','recycle')
$script:GameActionIds = @('nagle','hags','mmcss','gamedvr','gpu_preference','thread_sched','startup_delay','visual_effects','responsiveness','ultimate','core_parking','programs_priority')

$script:WorkerScript = @'
param([string]$PayloadJson, [System.Collections.Concurrent.ConcurrentQueue[string]]$LogQueue)
$ErrorActionPreference = 'Stop'
$payload = ConvertFrom-Json -InputObject $PayloadJson
$ids = @($payload.Ids)
function Log([string]$Text) { $LogQueue.Enqueue($Text) }
function Set-RegValue([string]$Path,[string]$Name,[object]$Value,[string]$Kind='DWord') {
    $key = $null
    try {
        $parts = $Path -split ':\\',2
        if ($parts.Count -ne 2) { throw "Invalid registry path: $Path" }
        $hive = switch ($parts[0]) { 'HKLM' { [Microsoft.Win32.RegistryHive]::LocalMachine } 'HKCU' { [Microsoft.Win32.RegistryHive]::CurrentUser } default { throw "Unsupported registry hive: $($parts[0])" } }
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,[Microsoft.Win32.RegistryView]::Registry64)
        try {
            $key = $base.CreateSubKey($parts[1],$true)
            if (-not $key) { throw "Could not open registry key $Path" }
            $valueKind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind],$Kind)
            $key.SetValue($Name,$Value,$valueKind)
            $actual = $key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -eq $actual -or [string]$actual -cne [string]$Value) { throw "Registry read-back did not match the requested value." }
        }
        finally { $base.Dispose() }
    } catch { throw "Registry write $Path\$Name failed: $($_.Exception.Message)" }
    finally { if ($key) { $key.Dispose() } }
}
function Invoke-Native([string]$File,[string[]]$Args) {
    try {
        $p = Start-Process -FilePath $File -ArgumentList $Args -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
        if ($p.ExitCode -ne 0) { throw "Exit code $($p.ExitCode)" }
    } catch { throw "Command '$File $($Args -join ' ')' failed: $($_.Exception.Message)" }
}
function Set-ServiceState([string]$Name,[ValidateSet('Automatic','Manual','Disabled')][string]$Startup,[bool]$Stop=$false) {
    try {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { Log "  $Name is not present; skipped."; return $false }
        Set-Service -Name $Name -StartupType $Startup -ErrorAction Stop
        $startValue=switch($Startup){'Automatic'{2};'Manual'{3};'Disabled'{4}}
        $serviceKey=Get-ItemProperty -Path ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}" -f $Name) -Name Start -ErrorAction Stop
        if([int]$serviceKey.Start -ne $startValue) { throw "Service $Name startup mode did not read back as $Startup." }
        if ($Stop -and $svc.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction Stop }
        if($Stop -and (Get-Service -Name $Name -ErrorAction Stop).Status -ne 'Stopped') { throw "Service $Name remained running." }
        return $true
    } catch { throw "Service $Name update failed: $($_.Exception.Message)" }
}
function Get-ActiveTcpInterfaceKeys {
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up')
        foreach ($a in $adapters) {
            $guid = ([string]$a.InterfaceGuid).Trim('{}')
            if ($guid) { "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{$guid}" }
        }
    } catch { throw "Could not enumerate active network interfaces: $($_.Exception.Message)" }
}
if ($payload.RestorePoint) {
    try {
        Checkpoint-Computer -Description ("ObsidianTune {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Log 'Restore point created.'
    } catch { Log "STOPPED: Restore point creation failed; no tweaks were run. $($_.Exception.Message)"; return }
} else { Log 'Restore point was explicitly skipped by the user.' }

foreach ($id in $ids) {
    try {
        switch ([string]$id) {
            'nagle' { foreach($p in @(Get-ActiveTcpInterfaceKeys)) { Set-RegValue $p 'TcpNoDelay' 1 }; Log 'Applied: Nagle disabled on active interfaces.' }
            'hags' { Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2; Log 'Applied: HAGS requested; restart may be required.' }
            'mmcss' { $p='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Set-RegValue $p 'GPU Priority' 8; Set-RegValue $p 'Priority' 6; Log 'Applied: MMCSS Games task priorities updated.' }
            'gamedvr' { Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0; Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'GameBarEnabled' 0; Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0; Log 'Applied: Game DVR/Game Bar capture disabled.' }
            'gpu_preference' { if (-not $payload.GpuExe) { throw 'No application executable was selected.' }; Set-RegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' ([string]$payload.GpuExe) 'GpuPreference=2;' 'String'; Log "Applied: High Performance GPU preference set for $($payload.GpuExe)." }
            'thread_sched' { $p='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Set-RegValue $p 'Scheduling Category' 'High' 'String'; Set-RegValue $p 'SFIO Priority' 'High' 'String'; Log 'Applied: MMCSS Games task scheduling/I/O category set to High.' }
            'hibernate' { Invoke-Native "$env:WINDIR\System32\powercfg.exe" @('/hibernate','off'); Log 'Applied: hibernation disabled.' }
            'telemetry' { Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0; Log 'Applied: minimum diagnostic-data policy requested; edition/policy may override it.' }
            'cortana' { Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0; Log 'Applied: legacy Cortana policy disabled.' }
            'ntfs_cache' { Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsMemoryUsage' 2; Log 'Applied: NTFS memory usage set to 2.' }
            'startup_delay' { Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 10000; Log 'Applied: current-user startup app delay set to 10 seconds.' }
            'visual_effects' { Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2; Log 'Applied: Windows best-performance visual-effects preset selected.' }
            'admin_shares' { Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'AutoShareWks' 0; Log 'Applied: automatic administrative shares disabled; server service restart may be required.' }
            'background_apps' { Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1; Log 'Applied: legacy background-app policy disabled.' }
            'responsiveness' { Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10; Log 'Applied: MMCSS SystemResponsiveness set to 10.' }
            'tcp_window' { Invoke-Native "$env:WINDIR\System32\netsh.exe" @('interface','tcp','set','global','autotuninglevel=normal'); Log 'Applied: TCP receive-window auto-tuning set to normal.' }
            'ack_frequency' { foreach($p in @(Get-ActiveTcpInterfaceKeys)) { Set-RegValue $p 'TcpAckFrequency' 1 }; Log 'Applied: TCP ACK frequency set to 1 on active interfaces.' }
            'chimney' { Invoke-Native "$env:WINDIR\System32\netsh.exe" @('interface','tcp','set','global','chimney=disabled'); Log 'Applied: TCP Chimney Offload disabled.' }
            'dns_cache' { Invoke-Native "$env:WINDIR\System32\ipconfig.exe" @('/flushdns'); Log 'Applied: DNS resolver cache flushed.' }
            'netbios' { $configs=@(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' -ErrorAction Stop); $changed=0; foreach($c in $configs) { try { $r=Invoke-CimMethod -InputObject $c -MethodName SetTcpipNetbios -Arguments @{TcpipNetbiosOptions=2} -ErrorAction Stop; if($r.ReturnValue -notin 0,1) { throw "WMI returned $($r.ReturnValue)" }; $changed++ } catch { Log "  NetBIOS update on $($c.Description) failed: $($_.Exception.Message)" } }; if($changed){Log "Applied: NetBIOS disable requested on $changed IPv4 adapter(s); a restart may be needed."}else{Log 'No IPv4 adapter confirmed a NetBIOS update.'} }
            'throttle_index' { Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' -1; Log 'Applied: legacy multimedia network throttle value set to 0xFFFFFFFF.' }
            'rss' {
                $a=@(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up'); $changed=0
                foreach($n in $a) {
                    try {
                        $before=@(Get-NetAdapterRss -Name $n.Name -ErrorAction Stop)
                        if(-not $before.Count) { Log "  RSS on $($n.Name): adapter does not expose RSS; skipped."; continue }
                        if($before[0].Enabled -ne $true) { Set-NetAdapterRss -Name $n.Name -Enabled $true -ErrorAction Stop }
                        $after=@(Get-NetAdapterRss -Name $n.Name -ErrorAction Stop)
                        if(-not $after.Count -or $after[0].Enabled -ne $true) { throw 'RSS did not report enabled after the change.' }
                        $changed++
                    } catch { Log "  FAILED RSS on $($n.Name): $($_.Exception.Message)" }
                }
                if(-not $changed) { Log 'No active physical adapter confirmed RSS enabled; unsupported adapters were skipped.' } else { Log "Verified: RSS enabled on $changed active physical adapter(s)." }
            }
            'lso' {
                $a=@(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up'); $changed=0
                foreach($n in $a) {
                    try {
                        $before=@(Get-NetAdapterLso -Name $n.Name -ErrorAction Stop)
                        if(-not $before.Count) { Log "  LSO on $($n.Name): adapter does not expose LSO; skipped."; continue }
                        $v4Property=$before[0].PSObject.Properties['IPv4Enabled']
                        $v6Property=$before[0].PSObject.Properties['IPv6Enabled']
                        if(-not $v4Property -and -not $v6Property) { Log "  LSO on $($n.Name): IPv4/IPv6 state is not exposed; skipped."; continue }
                        $setArgs=@{Name=$n.Name;NoRestart=$true;ErrorAction='Stop'}
                        if($v4Property) { $setArgs.IPv4Enabled=$true }
                        if($v6Property) { $setArgs.IPv6Enabled=$true }
                        Set-NetAdapterLso @setArgs
                        $after=@(Get-NetAdapterLso -Name $n.Name -ErrorAction Stop)
                        if(-not $after.Count) { throw 'Adapter returned no LSO state after the update.' }
                        if($v4Property -and $after[0].IPv4Enabled -ne $true) { throw 'IPv4 LSO did not report enabled after the change.' }
                        if($v6Property -and $after[0].IPv6Enabled -ne $true) { throw 'IPv6 LSO did not report enabled after the change.' }
                        $changed++
                    } catch { Log "  FAILED LSO on $($n.Name): $($_.Exception.Message)" }
                }
                if(-not $changed) { Log 'No active physical adapter confirmed LSO enabled; unsupported adapters were skipped.' } else { Log "Verified: supported LSO IPv4/IPv6 settings enabled on $changed active physical adapter(s)." }
            }
            'qos' { Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0; Log 'Applied: QoS NonBestEffortLimit policy set to zero.' }
            'arp' { Invoke-Native "$env:WINDIR\System32\arp.exe" @('-d','*'); Log 'Applied: ARP cache cleared.' }
            'standby' { if (-not ('ObsidianTuneStandbyNative' -as [type])) { Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class ObsidianTuneStandbyNative { [DllImport("ntdll.dll")] public static extern int NtSetSystemInformation(int SystemInformationClass, ref int SystemInformation, int SystemInformationLength); }' -ErrorAction Stop }; $purge=4; $status=[ObsidianTuneStandbyNative]::NtSetSystemInformation(80,[ref]$purge,[Runtime.InteropServices.Marshal]::SizeOf([type][int])); if($status -lt 0) { throw ('NtSetSystemInformation returned NTSTATUS 0x{0:X8}' -f ($status -band 0xffffffff)) }; Log 'Applied: standby list purge requested through NT native API.' }
            'pagefile' { $cs=Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop; $cs.AutomaticManagedPagefile=$true; Set-CimInstance -InputObject $cs -ErrorAction Stop | Out-Null; $check=Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop; if(-not $check.AutomaticManagedPagefile) { throw 'Windows did not confirm automatic pagefile management.' }; Log 'Verified: automatic pagefile management enabled; restart may be required.' }
            'ultimate' {
                $powercfg="$env:WINDIR\System32\powercfg.exe"; $knownPath='HKLM:\SOFTWARE\ObsidianTune'; $plan=''
                try { $saved=(Get-ItemProperty -Path $knownPath -Name UltimatePerformancePlan -ErrorAction Stop).UltimatePerformancePlan; if($saved -match '^[0-9a-fA-F-]{36}$') { $plans=@(& $powercfg /list 2>&1); if(($plans -join "`n") -match [regex]::Escape($saved)) { $plan=$saved } } } catch { }
                if(-not $plan) {
                    $out=@(& $powercfg /duplicatescheme 'e9a42b02-d5df-448d-aa00-03f14749eb61' 2>&1)
                    if($LASTEXITCODE -ne 0) { throw "Could not create the built-in Ultimate Performance plan: $($out -join ' ')" }
                    $matchesFound=[regex]::Matches(($out -join "`n"),'(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
                    if($matchesFound.Count -lt 1) { throw 'PowerCfg did not return the new plan GUID.' }
                    $plan=$matchesFound[$matchesFound.Count-1].Value
                    Set-RegValue $knownPath 'UltimatePerformancePlan' $plan 'String'
                }
                Invoke-Native $powercfg @('/setactive',$plan)
                $active=@(& $powercfg /getactivescheme 2>&1)
                if(($active -join "`n") -notmatch [regex]::Escape($plan)) { throw 'PowerCfg did not confirm the Ultimate Performance plan is active.' }
                Log 'Verified: Ultimate Performance plan activated. Higher power use and heat are expected.'
            }
            'core_parking' { $pc='0cc5b647-c1df-4637-891a-dec35c318583'; Invoke-Native "$env:WINDIR\System32\powercfg.exe" @('/setacvalueindex','SCHEME_CURRENT','SUB_PROCESSOR',$pc,'100'); Invoke-Native "$env:WINDIR\System32\powercfg.exe" @('/setdcvalueindex','SCHEME_CURRENT','SUB_PROCESSOR',$pc,'100'); Invoke-Native "$env:WINDIR\System32\powercfg.exe" @('/setactive','SCHEME_CURRENT'); Log 'Applied: current-plan AC/DC minimum unparked-core policy set to 100%.' }
            'cache_keys' {
                $c=@(Get-CimInstance -ClassName Win32_CacheMemory -ErrorAction Stop)
                $l2=@($c | Where-Object Level -eq 4 | Select-Object -ExpandProperty InstalledSize | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
                $l3=@($c | Where-Object Level -eq 5 | Select-Object -ExpandProperty InstalledSize | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
                $written=@()
                if($l2.Count -eq 1) { Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'SecondLevelDataCache' ([int]$l2[0]); $written+= 'L2' }
                if($l3.Count -eq 1) { Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'ThirdLevelDataCache' ([int]$l3[0]); $written+= 'L3' }
                if(-not $written.Count) { throw 'No unambiguous installed L2/L3 cache size was reported by WMI; no cache hint was written.' }
                Log "Applied: updated legacy cache hint(s) for $(($written -join ' and ')) using SMBIOS-reported installed sizes in KB. Windows may ignore these hints."
            }
            'wer' { if(Set-ServiceState 'WerSvc' 'Disabled' $true){Log 'Verified: Windows Error Reporting service disabled and stopped.'}else{Log 'Windows Error Reporting service is not installed; no change made.'} }
            'sysmain' { if(Set-ServiceState 'SysMain' 'Disabled' $true){Log 'Verified: SysMain disabled and stopped.'}else{Log 'SysMain service is not installed; no change made.'} }
            'telemetry_services' {
                $changed=0; $failed=0
                foreach($name in @('DiagTrack','dmwappushservice')) {
                    try { if(Set-ServiceState $name 'Disabled' $true) { $changed++ } }
                    catch { $failed++; Log ('  FAILED telemetry service {0}: {1}' -f $name,$_.Exception.Message) }
                }
                if(-not $changed -and $failed) { throw 'No diagnostic tracking service could be disabled.' }
                Log "Verified: $changed diagnostic tracking service(s) disabled and stopped where present."
            }
            'programs_priority' { Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38; Log 'Applied: foreground-program scheduling policy set to 0x26.' }
            'spectre' { $p='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; Set-RegValue $p 'FeatureSettingsOverride' 3; Set-RegValue $p 'FeatureSettingsOverrideMask' 3; Log 'Applied: Spectre/Meltdown mitigation overrides disabled; reboot required. SECURITY EXPOSURE.' }
            'clean_temp' { $script:removedCount=0; foreach($p in @((Join-Path $env:LOCALAPPDATA 'Temp'),(Join-Path $env:WINDIR 'Temp'),(Join-Path $env:WINDIR 'Prefetch'))) { if(Test-Path -LiteralPath $p -PathType Container) { Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | ForEach-Object { try { if($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { Log "  Skipped reparse point $($_.FullName)"; return }; Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction Stop; $script:removedCount++ } catch { Log "  Skipped $($_.FullName): $($_.Exception.Message)" } } } }; Log "Applied: temporary and Prefetch files removed where possible ($script:removedCount entries)." }
            'update_cache' { $services=@(); foreach($n in @('bits','wuauserv')) { $s=Get-Service -Name $n -ErrorAction SilentlyContinue; if($s) { $services+= [pscustomobject]@{Name=$n;WasRunning=($s.Status -eq 'Running')} } }; try { foreach($s in $services) { if($s.WasRunning) { Stop-Service -Name $s.Name -Force -ErrorAction Stop } }; $p=Join-Path $env:WINDIR 'SoftwareDistribution\Download'; if(Test-Path -LiteralPath $p) { Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction Stop } catch { Log "  Skipped update file $($_.FullName): $($_.Exception.Message)" } } } } finally { foreach($s in $services) { if($s.WasRunning) { try { Start-Service -Name $s.Name -ErrorAction Stop } catch { Log "  FAILED to restart $($s.Name): $($_.Exception.Message)" } } } }; Log 'Applied: downloaded Windows Update cache cleared where possible.' }
            'trim' { $vols=@(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }); $completed=0; foreach($v in $vols) { try { Optimize-Volume -DriveLetter $v.DriveLetter -ErrorAction Stop | Out-Null; $completed++ } catch { Log "  FAILED Optimize $($v.DriveLetter): $($_.Exception.Message)" } }; if($completed){Log "Applied: Windows storage optimization completed on $completed fixed volume(s)."}else{throw 'No fixed volume completed storage optimization.'} }
            'short_names' { Invoke-Native "$env:WINDIR\System32\fsutil.exe" @('behavior','set','disable8dot3','1'); Log 'Applied: 8.3 name creation disabled for new names.' }
            'last_access' { Invoke-Native "$env:WINDIR\System32\fsutil.exe" @('behavior','set','disablelastaccess','1'); Log 'Applied: NTFS last-access updates disabled.' }
            'dumps' { $paths=@((Join-Path $env:WINDIR 'MEMORY.DMP'),(Join-Path $env:WINDIR 'Minidump')); foreach($p in $paths) { if(Test-Path -LiteralPath $p) { try { Remove-Item -LiteralPath $p -Force -Recurse -ErrorAction Stop } catch { Log "  FAILED to delete ${p}: $($_.Exception.Message)" } } }; Log 'Applied: existing system crash dump files removed where possible.' }
            'delivery_limits' { $p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Set-RegValue $p 'DOMaxCacheSize' 5; Set-RegValue $p 'DOMaxCacheAge' 3; Log 'Applied: Delivery Optimization cache limits set (5 percent, 3 days).' }
            'delivery_cache' { $cmd=Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue; if(-not $cmd) { throw 'Delete-DeliveryOptimizationCache is unavailable on this Windows build.' }; Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; Log 'Applied: Delivery Optimization cache deleted.' }
            'search_indexer' { Set-Service -Name WSearch -StartupType Automatic -ErrorAction Stop; Invoke-Native "$env:WINDIR\System32\sc.exe" @('config','WSearch','start=','delayed-auto'); Log 'Applied: Windows Search service set to Automatic (Delayed Start).' }
            'recycle' { Clear-RecycleBin -Force -ErrorAction Stop; Log 'Applied: current-user Recycle Bin emptied.' }
            'telemetry_tasks' { $tasks=@(@{Path='\Microsoft\Windows\Application Experience\';Name='Microsoft Compatibility Appraiser'},@{Path='\Microsoft\Windows\Application Experience\';Name='ProgramDataUpdater'},@{Path='\Microsoft\Windows\Customer Experience Improvement Program\';Name='Consolidator'},@{Path='\Microsoft\Windows\Customer Experience Improvement Program\';Name='UsbCeip'}); $disabled=0; $alreadyDisabled=0; $failed=0; foreach($t in $tasks) { try { $task=Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue; if($task) { if($task.State -eq 'Disabled') { $alreadyDisabled++ } else { Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null; $check=Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop; if($check.State -ne 'Disabled') { throw 'Task did not report Disabled after the change.' }; $disabled++ } } } catch { $failed++; Log "  FAILED task $($t.Name): $($_.Exception.Message)" } }; if(($disabled + $alreadyDisabled) -eq 0 -and $failed) { throw 'No selected telemetry task could be disabled.' }; Log "Verified: $disabled telemetry task(s) disabled and $alreadyDisabled already disabled; $failed failed." }
            'uwp' { $names=@('Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.People','Microsoft.WindowsFeedbackHub','Microsoft.ZuneMusic','Microsoft.ZuneVideo'); $removed=0; foreach($n in $names) { try { $packages=@(Get-AppxPackage -Name $n -ErrorAction SilentlyContinue); foreach($package in $packages) { Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop; $removed++ } } catch { Log "  FAILED package ${n}: $($_.Exception.Message)" } }; Log "Applied: $removed allow-listed consumer UWP package(s) removed for current user where present." }
            'consumer' { Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1; Log 'Applied: consumer experiences policy disabled.' }
            'hosts' { $p=Join-Path $env:WINDIR 'System32\drivers\etc\hosts'; $marker='# ObsidianTune telemetry block'; $domains=@('v10.events.data.microsoft.com','v10.vortex-win.data.microsoft.com','settings-win.data.microsoft.com','watson.telemetry.microsoft.com','telemetry.microsoft.com'); $text=Get-Content -LiteralPath $p -Raw -ErrorAction Stop; if($text -notmatch [regex]::Escape($marker)) { $backup="$p.obsidiantune.bak"; if(-not(Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $p -Destination $backup -ErrorAction Stop }; $block="`r`n$marker`r`n" + (($domains | ForEach-Object { "0.0.0.0 $_" }) -join "`r`n") + "`r`n"; [IO.File]::AppendAllText($p,$block,[Text.Encoding]::ASCII) }; Invoke-Native "$env:WINDIR\System32\ipconfig.exe" @('/flushdns'); Log 'Applied: selected telemetry hosts blocked; original hosts file backed up if needed.' }
            'cloud_sync' { $one=Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'; if(Test-Path -LiteralPath $one) { try { Invoke-Native $one @('/shutdown') } catch { Log "  FAILED OneDrive stop: $($_.Exception.Message)" } }; Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1; Log 'Applied: OneDrive sync policy disabled.' }
            default { throw "Unknown tweak id: $id" }
        }
    } catch { Log "FAILED [$id]: $($_.Exception.Message)" }
}
'@

$script:HardwareScanScript = @'
param([System.Collections.Concurrent.ConcurrentQueue[string]]$ResultQueue)
$ErrorActionPreference = 'Stop'
try {
    $cs=$null; $cpu=$null; $os=$null; $battery=@(); $gpus=@(); $diskRows=[System.Collections.Generic.List[object]]::new(); $netRows=[System.Collections.Generic.List[object]]::new(); $recommendations=[System.Collections.Generic.List[object]]::new()
    try { $cs=Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $cpu=Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { }
    try { $os=Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $battery=@(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop) } catch { }
    try { $gpus=@(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop) } catch { }

    $osName='Windows'; $osBuild=[Environment]::OSVersion.Version.Build
    if($os) { $osName=([string]$os.Caption).Replace('Microsoft ',''); $osBuild=[string]$os.BuildNumber }
    else { try { $v=Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop; if($v.ProductName) { $osName=[string]$v.ProductName }; if($v.CurrentBuildNumber) { $osBuild=[string]$v.CurrentBuildNumber } } catch { } }
    $ramGB=$null; if($cs -and $cs.TotalPhysicalMemory) { $ramGB=[math]::Round(([double]$cs.TotalPhysicalMemory / 1GB),1) }
    $deviceKind='Unknown form factor'
    if($battery.Count -gt 0 -or ($cs -and $cs.PCSystemType -eq 2)) { $deviceKind='Laptop / mobile PC' }
    elseif($cs -and $cs.PCSystemType -eq 1) { $deviceKind='Desktop PC' }
    $model='Unavailable'; if($cs) { $model=('{0} {1}' -f [string]$cs.Manufacturer,[string]$cs.Model).Trim() }
    $cpuText='Unavailable'; if($cpu) { $cpuText=('{0}  /  {1} cores, {2} logical processors' -f [string]$cpu.Name,[string]$cpu.NumberOfCores,[string]$cpu.NumberOfLogicalProcessors) }
    $memoryText='Unavailable'; if($null -ne $ramGB) { $memoryText="$ramGB GB" }
    $gpuNames=@($gpus | ForEach-Object { if($_.Name) { [string]$_.Name } }); if(-not $gpuNames.Count) { $gpuNames=@('Unavailable') }

    $physicalDisks=@()
    try { $physicalDisks=@(Get-PhysicalDisk -ErrorAction Stop) } catch { }
    if($physicalDisks.Count) {
        foreach($d in $physicalDisks) {
            $size=''; if($d.Size) { $size=(' ({0:N0} GB)' -f ([double]$d.Size / 1GB)) }
            $media=[string]$d.MediaType; if(-not $media) { $media='Unspecified media' }
            $diskRows.Add([pscustomobject]@{Name=([string]$d.FriendlyName + $size);MediaType=$media;Health=[string]$d.HealthStatus})
        }
    } else {
        try {
            foreach($d in @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)) {
                $size=''; if($d.Size) { $size=(' ({0:N0} GB)' -f ([double]$d.Size / 1GB)) }
                $diskRows.Add([pscustomobject]@{Name=([string]$d.Model + $size);MediaType=[string]$d.MediaType;Health='Not reported'})
            }
        } catch { }
    }

    $physicalAdapters=@()
    try { $physicalAdapters=@(Get-NetAdapter -Physical -ErrorAction Stop) } catch { }
    foreach($a in $physicalAdapters) {
        $rssSupported=$false; $rssEnabled=$null; $lsoSupported=$false; $lsoIPv4Enabled=$null; $lsoIPv6Enabled=$null
        try { $r=@(Get-NetAdapterRss -Name $a.Name -ErrorAction Stop); if($r.Count -gt 0 -and $r[0].PSObject.Properties['Enabled']) { $rssSupported=$true; $rssEnabled=[bool]$r[0].Enabled } } catch { }
        try {
            $l=@(Get-NetAdapterLso -Name $a.Name -ErrorAction Stop)
            if($l.Count -gt 0) {
                if($l[0].PSObject.Properties['IPv4Enabled']) { $lsoSupported=$true; $lsoIPv4Enabled=[bool]$l[0].IPv4Enabled }
                if($l[0].PSObject.Properties['IPv6Enabled']) { $lsoSupported=$true; $lsoIPv6Enabled=[bool]$l[0].IPv6Enabled }
            }
        } catch { }
        $netRows.Add([pscustomobject]@{Name=[string]$a.Name;Description=[string]$a.InterfaceDescription;Status=[string]$a.Status;RssSupported=$rssSupported;RssEnabled=$rssEnabled;LsoSupported=$lsoSupported;LsoIPv4Enabled=$lsoIPv4Enabled;LsoIPv6Enabled=$lsoIPv6Enabled})
    }

    if($cs -and $cs.AutomaticManagedPagefile -eq $false) { $recommendations.Add([pscustomobject]@{Id='pagefile';Reason='Windows reports that pagefile sizing is manual. Enable Windows-managed sizing to let it adjust to memory pressure.'}) }
    foreach($n in $netRows) {
        if($n.Status -eq 'Up' -and $n.RssSupported -and $n.RssEnabled -eq $false) { $recommendations.Add([pscustomobject]@{Id='rss';Reason=("Receive Side Scaling is supported but disabled on {0}. Enabling it can spread network receive work across CPU cores; driver and workload determine the benefit." -f $n.Name)}); break }
    }
    foreach($n in $netRows) {
        if($n.Status -eq 'Up' -and $n.LsoSupported -and (($null -ne $n.LsoIPv4Enabled -and -not $n.LsoIPv4Enabled) -or ($null -ne $n.LsoIPv6Enabled -and -not $n.LsoIPv6Enabled))) { $recommendations.Add([pscustomobject]@{Id='lso';Reason=("At least one supported Large Send Offload protocol is disabled on {0}. Enabling supported IPv4/IPv6 offloads can move packet segmentation to the adapter; driver and workload determine the benefit." -f $n.Name)}); break }
    }
    if(@($diskRows | Where-Object { $_.MediaType -match '(?i)^SSD$' }).Count -gt 0) { $recommendations.Add([pscustomobject]@{Id='trim';Reason='A physical SSD was identified. Run Windows storage optimization so Windows can issue SSD retrim and the appropriate maintenance for fixed volumes.'}) }

    $activePlan='Unavailable'; try { $p=@(& "$env:WINDIR\System32\powercfg.exe" /getactivescheme 2>&1); if($LASTEXITCODE -eq 0) { $activePlan=($p -join ' ').Trim() } } catch { }
    $hags='Not queried (GPU driver capability is not reliably exposed by this inventory scan)'
    try { $h=Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction Stop; $hags="Registry request value $($h.HwSchMode); actual support/state still depends on the GPU and driver" } catch { }
    $diskText='Unavailable'; if($diskRows.Count) { $diskText=(($diskRows | ForEach-Object { '{0} — {1}, {2}' -f $_.Name,$_.MediaType,$_.Health }) -join "`n") }
    function Format-AdapterFeature([object]$value) { if($null -eq $value) { 'n/a' } elseif([bool]$value) { 'enabled' } else { 'disabled' } }
    $networkText='Unavailable'
    if($netRows.Count) {
        $networkLines=foreach($n in $netRows) {
            $rss=if($n.RssSupported) { 'RSS ' + (Format-AdapterFeature $n.RssEnabled) } else { 'RSS not exposed' }
            $lso=if($n.LsoSupported) { 'LSO IPv4 ' + (Format-AdapterFeature $n.LsoIPv4Enabled) + ', IPv6 ' + (Format-AdapterFeature $n.LsoIPv6Enabled) } else { 'LSO not exposed' }
            '{0} — {1}; {2}, {3}' -f $n.Name,$n.Status,$rss,$lso
        }
        $networkText=$networkLines -join [Environment]::NewLine
    }
    $pagefileText='Unavailable'; if($cs) { $pagefileText=if($cs.AutomaticManagedPagefile){'Windows-managed'}else{'Manual'} }
    $report=[ordered]@{
        Os=('{0}  /  build {1}' -f $osName,$osBuild)
        Model=$model; DeviceKind=$deviceKind; Cpu=$cpuText; Memory=$memoryText
        Gpus=($gpuNames -join "`n"); Disks=$diskText; Network=$networkText
        Pagefile=$pagefileText; PowerPlan=$activePlan; Hags=$hags
        RecommendationCount=$recommendations.Count; Recommendations=@($recommendations)
        Limitations='Read-only scan. Some hardware providers, drivers, or policies may hide inventory. HAGS capability is not inferred from the GPU name.'
    }
    $ResultQueue.Enqueue((ConvertTo-Json -InputObject $report -Depth 6 -Compress))
} catch {
    $ResultQueue.Enqueue((ConvertTo-Json -InputObject ([ordered]@{Error=$_.Exception.Message}) -Compress))
}
'@

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ObsidianTune" Height="820" Width="1320" MinHeight="700" MinWidth="1080"
        WindowStartupLocation="CenterScreen" Background="#0B0B0C" Foreground="#ECECF1" FontFamily="Segoe UI">
  <Window.Resources>
    <SolidColorBrush x:Key="Panel" Color="#131315"/><SolidColorBrush x:Key="Panel2" Color="#19191D"/>
    <SolidColorBrush x:Key="Accent" Color="#7C3AED"/><SolidColorBrush x:Key="Muted" Color="#A0A0AB"/>
    <Style TargetType="Button"><Setter Property="Foreground" Value="#F8F8FA"/><Setter Property="Background" Value="#19191D"/><Setter Property="BorderBrush" Value="#29292F"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="13,9"/><Setter Property="Margin" Value="0,4"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#ECECF1"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox"><StackPanel Orientation="Horizontal"><Border x:Name="Track" Width="38" Height="22" CornerRadius="11" Background="#34343B" Margin="0,0,10,0"><Ellipse x:Name="Knob" Width="16" Height="16" Fill="#B8B8C2" HorizontalAlignment="Left" Margin="3,0,0,0"/></Border><ContentPresenter VerticalAlignment="Center"/></StackPanel><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="Track" Property="Background" Value="#7C3AED"/><Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/><Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/><Setter TargetName="Knob" Property="Fill" Value="White"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  </Window.Resources>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="236"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border Grid.Column="0" Background="#101012" BorderBrush="#202024" BorderThickness="0,0,1,0">
      <DockPanel Margin="16">
        <StackPanel DockPanel.Dock="Top" Margin="4,12,4,28"><TextBlock Text="OBSIDIAN" FontSize="20" FontWeight="Bold"/><TextBlock Text="TUNE  /  WINDOWS" Foreground="#92929C" FontSize="10" Margin="1,4,0,0"/></StackPanel>
        <StackPanel x:Name="NavStack" DockPanel.Dock="Top">
          <Button x:Name="NavHome" Content="⌂   Home" HorizontalContentAlignment="Left"/>
          <Button x:Name="NavOptimizer" Content="◈   Optimizer" HorizontalContentAlignment="Left"/>
          <Button x:Name="NavCleaner" Content="▧   Cleaner" HorizontalContentAlignment="Left"/>
          <Button x:Name="NavGame" Content="◉   Game Boost" HorizontalContentAlignment="Left"/>
          <Button x:Name="NavNetwork" Content="⌁   Network" HorizontalContentAlignment="Left"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" Margin="4,0,4,10"><TextBlock Text="LOCAL ADMIN TOOL" Foreground="#74747E" FontSize="10"/><TextBlock Text="Changes can require a restart" Foreground="#A0A0AB" FontSize="11" Margin="0,5,0,0"/></StackPanel>
      </DockPanel>
    </Border>
    <Grid Grid.Column="1" Margin="26,22,26,20">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Grid Grid.Row="0" Margin="0,0,0,16"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="PageTitle" Text="System status" FontSize="25" FontWeight="SemiBold"/><TextBlock x:Name="PageSubtitle" Text="Review Windows actions before applying them." Foreground="#9999A3" Margin="0,4,0,0"/></StackPanel><Border Grid.Column="1" Background="#15151A" BorderBrush="#28282E" BorderThickness="1" CornerRadius="8" Padding="11,7" VerticalAlignment="Center"><TextBlock x:Name="AdminBadge" Text="ADMINISTRATOR" Foreground="#C4B5FD" FontSize="10" FontWeight="Bold"/></Border></Grid>
      <Grid Grid.Row="1">
        <ScrollViewer x:Name="HomeScroll" VerticalScrollBarVisibility="Auto"><StackPanel>
          <Border Background="#15131B" BorderBrush="#342554" BorderThickness="1" CornerRadius="12" Padding="22" Margin="0,0,0,14"><StackPanel><TextBlock Text="Tune with care." FontSize="24" FontWeight="SemiBold"/><TextBlock Text="50 Windows actions across gaming, network, memory, storage, and privacy. Persistent settings are written to Windows and remain after ObsidianTune closes; one-time cleanup and cache actions run once." TextWrapping="Wrap" Foreground="#B8B6C2" Margin="0,8,0,0"/><TextBlock Text="Nothing runs in the background after you close the app. Changes that need a restart remain pending until Windows restarts, and performance gains depend on the device and workload." TextWrapping="Wrap" Foreground="#D3C9E8" Margin="0,6,0,0"/><TextBlock Text="Restore points are enabled by default. Some changes are unsupported on certain builds, security-sensitive, irreversible, or may have no measurable benefit." TextWrapping="Wrap" Foreground="#D3C9E8" Margin="0,6,0,0"/></StackPanel></Border>
          <UniformGrid Columns="3" Margin="0,0,0,14"><Border Background="#131315" BorderBrush="#26262B" BorderThickness="1" CornerRadius="10" Padding="17" Margin="0,0,10,0"><StackPanel><TextBlock Text="ACTIONS" Foreground="#92929C" FontSize="10"/><TextBlock Text="50" FontSize="28" FontWeight="SemiBold" Margin="0,5,0,0"/></StackPanel></Border><Border Background="#131315" BorderBrush="#26262B" BorderThickness="1" CornerRadius="10" Padding="17" Margin="0,0,10,0"><StackPanel><TextBlock Text="WINDOWS" Foreground="#92929C" FontSize="10"/><TextBlock x:Name="OsVersion" Text="Detecting…" FontSize="16" FontWeight="SemiBold" Margin="0,9,0,0"/></StackPanel></Border><Border Background="#131315" BorderBrush="#26262B" BorderThickness="1" CornerRadius="10" Padding="17"><StackPanel><TextBlock Text="PRIVILEGE" Foreground="#92929C" FontSize="10"/><TextBlock x:Name="PrivilegeStatus" Text="Checking" FontSize="16" FontWeight="SemiBold" Margin="0,9,0,0"/></StackPanel></Border></UniformGrid>
          <Border Background="#131315" BorderBrush="#342554" BorderThickness="1" CornerRadius="10" Padding="18" Margin="0,0,0,14">
            <StackPanel>
              <DockPanel LastChildFill="False">
                <StackPanel DockPanel.Dock="Left"><TextBlock Text="Device-aware recommendations" FontSize="16" FontWeight="SemiBold"/><TextBlock Text="The scan reads hardware and current capabilities. It does not change Windows settings." Foreground="#A6A6B0" FontSize="11" Margin="0,4,14,0"/></StackPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center"><Button x:Name="ScanHardwareButton" Content="Scan hardware" Margin="8,0,8,0"/><Button x:Name="ApplyRecommendedButton" Content="Apply recommended settings" IsEnabled="False" Background="#7C3AED" BorderBrush="#7C3AED" FontWeight="SemiBold"/></StackPanel>
              </DockPanel>
              <Border Background="#101012" BorderBrush="#26262B" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,12,0,0"><TextBlock x:Name="HardwareReport" Text="No scan has run yet." Foreground="#C5C5CE" FontSize="11" TextWrapping="Wrap"/></Border>
              <TextBlock Text="Recommended actions" FontSize="13" FontWeight="SemiBold" Margin="0,12,0,4"/>
              <TextBlock x:Name="RecommendationSummary" Text="Run a scan to see whether any supported settings need attention." Foreground="#A6A6B0" FontSize="11" TextWrapping="Wrap"/>
            </StackPanel>
          </Border>
          <Border Background="#131315" BorderBrush="#26262B" BorderThickness="1" CornerRadius="10" Padding="18"><StackPanel><TextBlock Text="Categories" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,10"/><UniformGrid Columns="2"><Button x:Name="HomeOptimizer" Content="Open Optimizer  →" HorizontalContentAlignment="Left" Margin="0,0,10,8"/><Button x:Name="HomeCleaner" Content="Open Cleaner  →" HorizontalContentAlignment="Left" Margin="0,0,0,8"/><Button x:Name="HomeGame" Content="Open Game Boost  →" HorizontalContentAlignment="Left" Margin="0,0,10,0"/><Button x:Name="HomeNetwork" Content="Open Network  →" HorizontalContentAlignment="Left" Margin="0,0,0,0"/></UniformGrid></StackPanel></Border>
          <Border Background="#131315" BorderBrush="#26262B" BorderThickness="1" CornerRadius="10" Padding="18" Margin="0,14,0,0"><StackPanel><TextBlock Text="Safety notes" FontSize="16" FontWeight="SemiBold"/><TextBlock Text="• Create a restore point before applying is selected by default. Windows may refuse a new point if one was created within the last 24 hours, or if System Protection is unavailable; in that case the run stops." Foreground="#B7B7C1" TextWrapping="Wrap" Margin="0,9,0,0"/><TextBlock Text="• Restore points are a recovery aid, not a backup for personal files or every policy/service change. Keep backups of important data." Foreground="#B7B7C1" TextWrapping="Wrap" Margin="0,7,0,0"/><TextBlock Text="• Spectre/Meltdown mitigation changes require a typed confirmation and expose the computer to known security vulnerabilities." Foreground="#E7C7C7" TextWrapping="Wrap" Margin="0,7,0,0"/></StackPanel></Border>
        </StackPanel></ScrollViewer>
        <Grid x:Name="OptimizerPanel" Visibility="Collapsed">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="120"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Border Grid.Row="0" Background="#131315" BorderBrush="#26262B" BorderThickness="1" CornerRadius="9" Padding="13" Margin="0,0,0,12"><DockPanel><CheckBox x:Name="RestoreCheck" IsChecked="True" Content="Create a restore point before applying"/><TextBlock DockPanel.Dock="Right" Text="Persistent settings stay after close · ONE-TIME runs once" Foreground="#92929C" VerticalAlignment="Center"/></DockPanel></Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="TweakList"/></ScrollViewer>
          <TextBox x:Name="LogBox" Grid.Row="2" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#101012" Foreground="#B9B9C3" BorderBrush="#26262B" BorderThickness="1" Padding="10" FontSize="11" Margin="0,10,0,0"/>
          <Grid Grid.Row="3" Margin="0,12,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="SelectionCount" Text="0 selected" Foreground="#A0A0AB" VerticalAlignment="Center"/><Button x:Name="ApplyButton" Grid.Column="1" Content="Apply Selected Actions" Background="#7C3AED" BorderBrush="#7C3AED" FontWeight="SemiBold" Padding="18,11"/></Grid>
        </Grid>
      </Grid>
      <Border Grid.Row="2" Background="#101012" BorderBrush="#242429" BorderThickness="1" CornerRadius="8" Padding="10,7" Margin="0,14,0,0"><DockPanel><Ellipse x:Name="StatusDot" Width="7" Height="7" Fill="#43D19E" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock x:Name="StatusText" Text="Ready. Nothing has been changed." Foreground="#A9A9B3" FontSize="11"/><Button x:Name="ClearLogButton" DockPanel.Dock="Right" Content="Clear log" Padding="8,2" Margin="10,0,0,0" FontSize="10"/></DockPanel></Border>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)
function Find-Control([string]$Name) { $window.FindName($Name) }
$homeScroll = Find-Control 'HomeScroll'; $optimizerPanel = Find-Control 'OptimizerPanel'; $list = Find-Control 'TweakList'
$title = Find-Control 'PageTitle'; $subtitle = Find-Control 'PageSubtitle'; $statusText = Find-Control 'StatusText'; $statusDot = Find-Control 'StatusDot'
$applyButton = Find-Control 'ApplyButton'; $restoreCheck = Find-Control 'RestoreCheck'; $selectionCount = Find-Control 'SelectionCount'; $logBox = Find-Control 'LogBox'; $adminBadge=Find-Control 'AdminBadge'
$adminBadge.Text=if($script:IsAdmin){'ADMINISTRATOR'}else{'STANDARD USER'}
$privilegeStatus=Find-Control 'PrivilegeStatus'; $privilegeStatus.Text=if($script:IsAdmin){'Elevated'}else{'Standard user'}
$scanButton=Find-Control 'ScanHardwareButton'; $applyRecommendedButton=Find-Control 'ApplyRecommendedButton'; $hardwareReport=Find-Control 'HardwareReport'; $recommendationSummary=Find-Control 'RecommendationSummary'
$selectionBoxes = [System.Collections.Generic.List[object]]::new()
$script:CurrentFilter = 'All'; $script:Busy = $false; $script:Timer = $null; $script:PowerShell = $null; $script:Async = $null; $script:RunspacePool = $null; $script:Queue = $null
$script:Scanning=$false; $script:ScanTimer=$null; $script:ScanPowerShell=$null; $script:ScanAsync=$null; $script:ScanRunspacePool=$null; $script:ScanQueue=$null; $script:HardwareProfile=$null; $script:ScanRecommendations=@()
$script:SelectedIds=[System.Collections.Generic.HashSet[string]]::new()
$script:ApplyHadErrors=$false

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    (Find-Control 'OsVersion').Text = ('Windows {0}  /  build {1}' -f $os.Caption.Replace('Microsoft ',''),$os.BuildNumber)
} catch {
    # WMI/CIM can be restricted by policy or sandboxing; this display-only fallback needs no CIM access.
    $version = [Environment]::OSVersion.Version
    (Find-Control 'OsVersion').Text = ('Windows  /  build {0}' -f $version.Build)
}

function Set-Page([string]$Page) {
    $isHomePage = ($Page -eq 'Home')
    $homeScroll.Visibility = if($isHomePage){'Visible'}else{'Collapsed'}
    $optimizerPanel.Visibility = if($isHomePage){'Collapsed'}else{'Visible'}
    $target=if($isHomePage){$homeScroll}else{$optimizerPanel}
    $target.Opacity=0
    $fade=[System.Windows.Media.Animation.DoubleAnimation]::new(0.0,1.0,[TimeSpan]::FromMilliseconds(160))
    $target.BeginAnimation([System.Windows.UIElement]::OpacityProperty,$fade)
    switch($Page) {
        'Home' { $title.Text='System status'; $subtitle.Text='Review Windows actions before applying them.'; $script:CurrentFilter='All' }
        'Optimizer' { $title.Text='Optimizer'; $subtitle.Text='Select Windows actions to apply.'; $script:CurrentFilter='All' }
        'Cleaner' { $title.Text='Cleaner'; $subtitle.Text='Temporary files, update cache, storage maintenance, and cleanup.'; $script:CurrentFilter='Storage & Disk Cleanup' }
        'Game' { $title.Text='Game Boost'; $subtitle.Text='Gaming, graphics, power, and scheduling actions.'; $script:CurrentFilter='Game' }
        'Network' { $title.Text='Network'; $subtitle.Text='TCP, adapter, DNS, QoS, and local network actions.'; $script:CurrentFilter='Network & Ping' }
    }
    if(-not $isHomePage) { Render-Tweaks }
}
function Sync-Selection {
    foreach($entry in $selectionBoxes) {
        $id=[string]$entry.Tweak.Id
        if($entry.Box.IsChecked) { $null=$script:SelectedIds.Add($id) }
        else { $null=$script:SelectedIds.Remove($id) }
    }
}
function Update-SelectionCount {
    Sync-Selection
    $count=$script:SelectedIds.Count
    $selectionCount.Text="$count selected"
    $applyButton.IsEnabled=(-not $script:Busy -and -not $script:Scanning -and $count -gt 0)
}
function Render-Tweaks {
    Sync-Selection
    $list.Children.Clear(); $selectionBoxes.Clear()
    $items = @($script:Tweaks)
    if($script:CurrentFilter -eq 'Storage & Disk Cleanup') { $items=@($items | Where-Object Category -eq 'Storage & Disk Cleanup') }
    elseif($script:CurrentFilter -eq 'Network & Ping') { $items=@($items | Where-Object Category -eq 'Network & Ping') }
    elseif($script:CurrentFilter -eq 'Game') { $items=@($items | Where-Object { $script:GameActionIds -contains $_.Id }) }
    $last=''
    foreach($t in $items) {
        if($t.Category -ne $last) { $last=$t.Category; $heading=New-Object System.Windows.Controls.TextBlock; $heading.Text=$last.ToUpperInvariant(); $heading.Foreground=[System.Windows.Media.Brushes]::LightSlateGray; $heading.FontSize=10; $heading.FontWeight='Bold'; $heading.Margin='3,12,0,7'; $null=$list.Children.Add($heading) }
        $card=New-Object System.Windows.Controls.Border; $card.Background=[System.Windows.Media.BrushConverter]::new().ConvertFromString('#131315'); $card.BorderBrush=[System.Windows.Media.BrushConverter]::new().ConvertFromString('#26262B'); $card.BorderThickness='1'; $card.CornerRadius='8'; $card.Padding='13,10'; $card.Margin='0,0,0,7'
        $grid=New-Object System.Windows.Controls.Grid; $col1=New-Object System.Windows.Controls.ColumnDefinition; $col1.Width='*'; $col2=New-Object System.Windows.Controls.ColumnDefinition; $col2.Width='Auto'; $null=$grid.ColumnDefinitions.Add($col1); $null=$grid.ColumnDefinitions.Add($col2)
        $stack=New-Object System.Windows.Controls.StackPanel; $stack.Margin='0,0,14,0'
        $row=New-Object System.Windows.Controls.DockPanel; $row.LastChildFill=$false
        $name=New-Object System.Windows.Controls.TextBlock; $name.Text=$t.Name; $name.FontSize=14; $name.FontWeight='SemiBold'; $name.Foreground=[System.Windows.Media.Brushes]::White; [System.Windows.Controls.DockPanel]::SetDock($name,[System.Windows.Controls.Dock]::Left); $null=$row.Children.Add($name)
        $risk=New-Object System.Windows.Controls.TextBlock; $risk.Text=$t.Risk.ToUpperInvariant(); $risk.FontSize=9; $risk.Foreground=if($t.Risk -eq 'Critical' -or $t.Risk -eq 'High'){[System.Windows.Media.BrushConverter]::new().ConvertFromString('#F0A8A8')}else{[System.Windows.Media.BrushConverter]::new().ConvertFromString('#AAAAB4')}; $risk.Margin='12,2,0,0'; [System.Windows.Controls.DockPanel]::SetDock($risk,[System.Windows.Controls.Dock]::Right); $null=$row.Children.Add($risk)
        $scope=New-Object System.Windows.Controls.TextBlock; $scope.Text=if($script:OneTimeActionIds -contains $t.Id){'ONE-TIME'}else{'PERSISTS IN WINDOWS'}; $scope.FontSize=9; $scope.Foreground=if($script:OneTimeActionIds -contains $t.Id){[System.Windows.Media.BrushConverter]::new().ConvertFromString('#AAAAB4')}else{[System.Windows.Media.BrushConverter]::new().ConvertFromString('#C4B5FD')}; $scope.Margin='12,2,0,0'; [System.Windows.Controls.DockPanel]::SetDock($scope,[System.Windows.Controls.Dock]::Right); $null=$row.Children.Add($scope)
        $null=$stack.Children.Add($row)
        $desc=New-Object System.Windows.Controls.TextBlock; $desc.Text=$t.Description; $desc.Foreground=[System.Windows.Media.BrushConverter]::new().ConvertFromString('#A6A6B0'); $desc.FontSize=11; $desc.TextWrapping='Wrap'; $desc.Margin='0,5,0,0'; $null=$stack.Children.Add($desc)
        [System.Windows.Controls.Grid]::SetColumn($stack,0); $null=$grid.Children.Add($stack)
        $box=New-Object System.Windows.Controls.CheckBox; $box.Content=''; $box.Tag=$t.Id; $box.IsChecked=$script:SelectedIds.Contains([string]$t.Id); $box.IsEnabled=(-not $script:Busy -and -not $script:Scanning); $box.VerticalAlignment='Center'; $box.HorizontalAlignment='Right'; [System.Windows.Controls.Grid]::SetColumn($box,1); $null=$grid.Children.Add($box)
        $card.Child=$grid; $null=$list.Children.Add($card)
        $entry=[pscustomobject]@{Box=$box;Tweak=$t}; $selectionBoxes.Add($entry)
        $box.Add_Checked({ Update-SelectionCount }); $box.Add_Unchecked({ Update-SelectionCount })
    }
    Update-SelectionCount
}

function Add-Log([string]$Text) {
    $statusText.Text=$Text
    $logBox.AppendText($Text + [Environment]::NewLine); $logBox.ScrollToEnd()
    if($Text -match '(?i)\b(FAILED|STOPPED)\b' -or $Text -like 'Finished with errors*') {
        $script:ApplyHadErrors=$true
        $statusDot.Fill=[System.Windows.Media.BrushConverter]::new().ConvertFromString('#EF7F7F')
    } elseif($script:ApplyHadErrors) {
        $statusDot.Fill=[System.Windows.Media.BrushConverter]::new().ConvertFromString('#EF7F7F')
    } elseif($Text -like 'Applying selected actions*' -or $Text -like 'Scanning hardware*' -or $Text -like 'Scan warning:*' -or $Text -like 'Hardware scan finished without*') {
        $statusDot.Fill=[System.Windows.Media.BrushConverter]::new().ConvertFromString('#F0C36D')
    } else {
        $statusDot.Fill=[System.Windows.Media.BrushConverter]::new().ConvertFromString('#43D19E')
    }
}
function Confirm-Typed([string]$Prompt,[string]$RequiredText) {
    $w=New-Object System.Windows.Window; $w.Owner=$window; $w.WindowStartupLocation='CenterOwner'; $w.Width=530; $w.SizeToContent='Height'; $w.ResizeMode='NoResize'; $w.Title='Additional confirmation'; $w.Background=[System.Windows.Media.BrushConverter]::new().ConvertFromString('#131315'); $w.Foreground=[System.Windows.Media.Brushes]::White
    $p=New-Object System.Windows.Controls.StackPanel; $p.Margin='22'; $message=New-Object System.Windows.Controls.TextBlock; $message.Text=$Prompt; $message.TextWrapping='Wrap'; $message.Margin='0,0,0,14'; $null=$p.Children.Add($message)
    $hint=New-Object System.Windows.Controls.TextBlock; $hint.Text="Type $RequiredText to continue."; $hint.Foreground=[System.Windows.Media.BrushConverter]::new().ConvertFromString('#C4B5FD'); $hint.Margin='0,0,0,6'; $null=$p.Children.Add($hint)
    $entryBox=New-Object System.Windows.Controls.TextBox; $entryBox.Height=32; $entryBox.Padding='7'; $null=$p.Children.Add($entryBox)
    $buttons=New-Object System.Windows.Controls.StackPanel; $buttons.Orientation='Horizontal'; $buttons.HorizontalAlignment='Right'; $buttons.Margin='0,16,0,0'; $ok=New-Object System.Windows.Controls.Button; $ok.Content='Continue'; $ok.IsEnabled=$false; $ok.Margin='0,0,8,0'; $cancel=New-Object System.Windows.Controls.Button; $cancel.Content='Cancel'; $null=$buttons.Children.Add($ok); $null=$buttons.Children.Add($cancel); $null=$p.Children.Add($buttons); $w.Content=$p
    $entryBox.Add_TextChanged({$ok.IsEnabled=($entryBox.Text -ceq $RequiredText)})
    $ok.Add_Click({$w.DialogResult=$true; $w.Close()}); $cancel.Add_Click({$w.DialogResult=$false; $w.Close()})
    return [bool]$w.ShowDialog()
}
function Start-HardwareScan {
    if($script:Scanning -or $script:Busy) { return }
    $script:ApplyHadErrors=$false
    $script:ScanResultJson=$null
    $script:HardwareProfile=$null; $script:ScanRecommendations=@(); $applyRecommendedButton.IsEnabled=$false
    try {
        $script:ScanQueue=[System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $script:ScanRunspacePool=[RunspaceFactory]::CreateRunspacePool(1,1); $script:ScanRunspacePool.ApartmentState='MTA'; $script:ScanRunspacePool.Open()
        $script:ScanPowerShell=[PowerShell]::Create(); $script:ScanPowerShell.RunspacePool=$script:ScanRunspacePool
        $null=$script:ScanPowerShell.AddScript($script:HardwareScanScript).AddArgument($script:ScanQueue)
        $script:ScanAsync=$script:ScanPowerShell.BeginInvoke()
    } catch {
        $script:Scanning=$false; $scanButton.IsEnabled=$true
        if($script:ScanPowerShell) { try { $script:ScanPowerShell.Dispose() } catch { } }
        if($script:ScanRunspacePool) { try { $script:ScanRunspacePool.Close(); $script:ScanRunspacePool.Dispose() } catch { } }
        Add-Log "FAILED to start hardware scan: $($_.Exception.Message)"
        return
    }
    $script:Scanning=$true
    $scanButton.IsEnabled=$false; $applyRecommendedButton.IsEnabled=$false
    $applyButton.IsEnabled=$false; foreach($entry in $selectionBoxes) { $entry.Box.IsEnabled=$false }
    $hardwareReport.Text='Scanning hardware and current adapter capabilities… This read-only scan runs in the background.'
    $recommendationSummary.Text='Recommendations will appear when the scan completes.'
    Add-Log 'Scanning hardware in the background. No settings are being changed.'
    $script:ScanTimer=New-Object System.Windows.Threading.DispatcherTimer; $script:ScanTimer.Interval=[TimeSpan]::FromMilliseconds(200)
    $script:ScanTimer.Add_Tick({
        $json=$null; while($script:ScanQueue.TryDequeue([ref]$json)) { $script:ScanResultJson=$json; $json=$null }
        if($script:ScanAsync.IsCompleted) {
            try { $null=$script:ScanPowerShell.EndInvoke($script:ScanAsync); foreach($e in $script:ScanPowerShell.Streams.Error) { Add-Log "Scan warning: $($e.ToString())" } }
            catch { Add-Log "Scan warning: $($_.Exception.Message)" }
            $script:ScanTimer.Stop(); $script:ScanPowerShell.Dispose(); $script:ScanRunspacePool.Close(); $script:ScanRunspacePool.Dispose(); $script:Scanning=$false; $scanButton.IsEnabled=$true; foreach($entry in $selectionBoxes) { $entry.Box.IsEnabled=$true }; Update-SelectionCount
            if(-not $script:ScanResultJson) {
                $hardwareReport.Text='The scan returned no inventory. Windows hardware providers may be unavailable.'
                $recommendationSummary.Text='No recommendations were generated.'
                Add-Log 'Hardware scan finished without an inventory result.'
            } else {
                try {
                    $profile=ConvertFrom-Json -InputObject $script:ScanResultJson -ErrorAction Stop
                    if($profile.PSObject.Properties['Error'] -and $profile.Error) { throw ([string]$profile.Error) }
                    $script:HardwareProfile=$profile
                    $script:ScanRecommendations=@($profile.Recommendations)
                    $hardwareReport.Text=("Operating system: {0}`nDevice: {1} ({2})`nCPU: {3}`nMemory: {4}`nGraphics: {5}`nStorage:`n{6}`nNetwork adapters:`n{7}`nPagefile: {8}`nActive power plan: {9}`nHAGS: {10}`n`n{11}" -f $profile.Os,$profile.Model,$profile.DeviceKind,$profile.Cpu,$profile.Memory,$profile.Gpus,$profile.Disks,$profile.Network,$profile.Pagefile,$profile.PowerPlan,$profile.Hags,$profile.Limitations)
                    if($script:ScanRecommendations.Count) {
                        $lines=@(); foreach($rec in $script:ScanRecommendations) { $action=@($script:Tweaks | Where-Object Id -eq $rec.Id | Select-Object -First 1); if($action.Count) { $lines+=('• {0}: {1}' -f $action[0].Name,$rec.Reason) } }
                        $recommendationSummary.Text=$lines -join "`n"
                        $applyRecommendedButton.IsEnabled=($lines.Count -gt 0)
                    } else {
                        $recommendationSummary.Text='No supported changes were detected for the settings this tool can safely recommend. The scan will not enable latency tweaks or security-sensitive options based on guesses.'
                        $applyRecommendedButton.IsEnabled=$false
                    }
                    (Find-Control 'OsVersion').Text=[string]$profile.Os
                    Add-Log ("Hardware scan complete. {0} device-aware recommendation(s) found." -f $script:ScanRecommendations.Count)
                } catch {
                    $script:HardwareProfile=$null; $script:ScanRecommendations=@(); $applyRecommendedButton.IsEnabled=$false
                    $hardwareReport.Text="Hardware scan failed: $($_.Exception.Message)"
                    $recommendationSummary.Text='No recommendations were generated.'
                    Add-Log "FAILED to read hardware scan result: $($_.Exception.Message)"
                }
            }
        }
    }); $script:ScanTimer.Start()
}
function Apply-RecommendedSettings {
    if($script:Busy -or $script:Scanning) { return }
    if(-not $script:HardwareProfile) {
        [System.Windows.MessageBox]::Show('Run the hardware scan first. It only reads device details and does not change settings.','Hardware scan required',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    if(-not $script:ScanRecommendations.Count) {
        [System.Windows.MessageBox]::Show('The scan did not find a supported setting that needs changing. Nothing will be applied.','No recommended changes',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    $ids=@($script:ScanRecommendations | ForEach-Object { [string]$_.Id } | Select-Object -Unique)
    $selected=@($script:Tweaks | Where-Object { $ids -contains $_.Id })
    $detail=($selected | ForEach-Object {
        $item=$_; $reason=($script:ScanRecommendations | Where-Object Id -eq $item.Id | Select-Object -First 1).Reason
        '• ' + $item.Name + ': ' + $reason
    }) -join ([Environment]::NewLine + [Environment]::NewLine)
    $answer=[System.Windows.MessageBox]::Show("Review these device-aware actions. A restore point will be attempted first. If Windows cannot create it, no actions will run." + [Environment]::NewLine + [Environment]::NewLine + $detail + [Environment]::NewLine + [Environment]::NewLine + 'Apply these settings now?','Apply recommended settings',[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Question)
    if($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Set-Page 'Optimizer'
    $script:SelectedIds.Clear()
    foreach($entry in $selectionBoxes) { $entry.Box.IsChecked=($ids -contains $entry.Tweak.Id) }
    Update-SelectionCount
    Start-Apply
}
function Start-Apply {
    Sync-Selection
    $selected=@($script:Tweaks | Where-Object { $script:SelectedIds.Contains($_.Id) })
    if(-not $selected.Count -or $script:Busy -or $script:Scanning) { return }
    if(-not $script:IsAdmin) {
        $message='No settings were changed. Restart ObsidianTune and approve the Windows administrator prompt before applying actions.'
        [System.Windows.MessageBox]::Show($message,'Administrator access required',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Information) | Out-Null
        Add-Log $message
        return
    }
    $gpu=''
    if($selected.Id -contains 'gpu_preference') { $dlg=New-Object Microsoft.Win32.OpenFileDialog; $dlg.Filter='Applications (*.exe)|*.exe'; $dlg.Title='Choose an application for High Performance GPU'; if(-not $dlg.ShowDialog()) { return }; $gpu=$dlg.FileName }
    $high=@($selected | Where-Object { $_.Risk -eq 'High' -or $_.Risk -eq 'Critical' })
    if($high.Count) {
        $detail=($high | ForEach-Object { '• ' + $_.Name + ': ' + $_.Description }) -join "`n`n"
        $answer=[System.Windows.MessageBox]::Show("These selected actions may remove data, reduce system functionality, or create security exposure:`n`n$detail`n`nContinue?",'Review high-risk actions',[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Warning)
        if($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    if($selected.Id -contains 'spectre') {
        $text='Disabling these CPU mitigations exposes the device to known speculative-execution vulnerabilities. Microsoft documents that the change requires a restart. Do not use on a device that handles untrusted code or sensitive data.'
        if(-not (Confirm-Typed $text 'DISABLE SECURITY')) { return }
    }
    if(-not $restoreCheck.IsChecked) {
        $answer=[System.Windows.MessageBox]::Show('You turned off restore-point creation. Continue without that recovery point?','No restore point',[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Warning)
        if($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    $payload=[ordered]@{Ids=@($selected | ForEach-Object {$_.Id});GpuExe=$gpu;RestorePoint=[bool]$restoreCheck.IsChecked} | ConvertTo-Json -Compress
    $script:ApplyHadErrors=$false
    try {
        $script:Queue=[System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $script:RunspacePool=[RunspaceFactory]::CreateRunspacePool(1,1); $script:RunspacePool.ApartmentState='MTA'; $script:RunspacePool.Open()
        $script:PowerShell=[PowerShell]::Create(); $script:PowerShell.RunspacePool=$script:RunspacePool
        $null=$script:PowerShell.AddScript($script:WorkerScript).AddArgument($payload).AddArgument($script:Queue)
        $script:Async=$script:PowerShell.BeginInvoke()
    } catch {
        $script:Busy=$false; foreach($entry in $selectionBoxes) { $entry.Box.IsEnabled=$true }
        if($script:PowerShell) { try { $script:PowerShell.Dispose() } catch { } }
        if($script:RunspacePool) { try { $script:RunspacePool.Close(); $script:RunspacePool.Dispose() } catch { } }
        Add-Log "FAILED to start worker: $($_.Exception.Message)"; return
    }
    $script:Busy=$true; $applyButton.IsEnabled=$false; $scanButton.IsEnabled=$false; $applyRecommendedButton.IsEnabled=$false; foreach($entry in $selectionBoxes) { $entry.Box.IsEnabled=$false }; $statusDot.Fill=[System.Windows.Media.BrushConverter]::new().ConvertFromString('#F0C36D'); Add-Log 'Applying selected actions in the background…'
    $script:Timer=New-Object System.Windows.Threading.DispatcherTimer; $script:Timer.Interval=[TimeSpan]::FromMilliseconds(200)
    $script:Timer.Add_Tick({
        $msg=$null; while($script:Queue.TryDequeue([ref]$msg)) { Add-Log $msg; $msg=$null }
        if($script:Async.IsCompleted) {
            try { $null=$script:PowerShell.EndInvoke($script:Async); foreach($e in $script:PowerShell.Streams.Error) { Add-Log "FAILED: $($e.ToString())" } }
            catch { Add-Log "FAILED: $($_.Exception.Message)" }
            $script:Timer.Stop(); $script:PowerShell.Dispose(); $script:RunspacePool.Close(); $script:RunspacePool.Dispose(); $script:Busy=$false; $scanButton.IsEnabled=$true; $applyRecommendedButton.IsEnabled=($script:ScanRecommendations.Count -gt 0); foreach($entry in $selectionBoxes) { $entry.Box.IsEnabled=$true }; Update-SelectionCount; if($script:ApplyHadErrors){Add-Log 'Finished with errors. Some changes may already have applied; review the action log.'}else{Add-Log 'Finished successfully. Review the action log; some changes may need a restart.'}
        }
    }); $script:Timer.Start()
}

(Find-Control 'NavHome').Add_Click({Set-Page 'Home'})
(Find-Control 'NavOptimizer').Add_Click({Set-Page 'Optimizer'})
(Find-Control 'NavCleaner').Add_Click({Set-Page 'Cleaner'})
(Find-Control 'NavGame').Add_Click({Set-Page 'Game'})
(Find-Control 'NavNetwork').Add_Click({Set-Page 'Network'})
(Find-Control 'HomeOptimizer').Add_Click({Set-Page 'Optimizer'})
(Find-Control 'HomeCleaner').Add_Click({Set-Page 'Cleaner'})
(Find-Control 'HomeGame').Add_Click({Set-Page 'Game'})
(Find-Control 'HomeNetwork').Add_Click({Set-Page 'Network'})
$scanButton.Add_Click({Start-HardwareScan})
$applyRecommendedButton.Add_Click({Apply-RecommendedSettings})
$applyButton.Add_Click({Start-Apply})
(Find-Control 'ClearLogButton').Add_Click({$logBox.Clear(); Add-Log 'Ready. Nothing has been changed.'})
$window.Add_Closing({param($sender,$e) if($script:Busy -or $script:Scanning) { $e.Cancel=$true; [System.Windows.MessageBox]::Show('A background operation is still running. Wait for it to finish before closing.','Operation in progress',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Information) | Out-Null }})
Set-Page 'Home'
$null=$window.ShowDialog()

