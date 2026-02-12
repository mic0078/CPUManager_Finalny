try {
    $proc = Get-Process -Id $PID -ErrorAction Stop
    if ($proc.PriorityClass -ne 'Idle') { $proc.PriorityClass = 'Idle' }
} catch {}

# --- Funkcja pomocnicza do ustawiania HardLock dla aplikacji ---
function Set-AppHardLock {
    param([string]$appName, [bool]$HardLock)
    if (-not $Script:Config) { return $false }
    if (-not $Script:Config.HardLocks) { $Script:Config.HardLocks = @{} }
    $Script:Config.HardLocks[$appName] = $HardLock
    try { Save-Config $Script:Config; return $true } catch { return $false }
}
# --- Modyfikacja UI: Dodanie checkboxa HardLock przy kazdej aplikacji ---
function Add-HardLockCheckboxToAppRow {
    param([System.Windows.Forms.Control]$parent, [string]$appName, [int]$x = 420, [int]$y = 2)
    if (-not $parent -or -not $appName) { return $null }
    $isLocked = $false; if ($Script:Config.HardLocks -and $Script:Config.HardLocks.$appName) { $isLocked = $true }
    $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text = "Lock"; $chk.Location = [System.Drawing.Point]::new($x,$y)
    $chk.Size = [System.Drawing.Size]::new(55,20); $chk.Checked = $isLocked; $chk.Tag = $appName
    $chk.ForeColor = $Script:Colors.Text; $chk.BackColor = [System.Drawing.Color]::Transparent
    $chk.Add_CheckedChanged({ Set-AppHardLock -appName $this.Tag -HardLock $this.Checked })
    $parent.Controls.Add($chk); return $chk
}

function Save-NetworkUsage {
    try {
        $backup = Join-Path $Script:ConfigDir 'NetworkStats.Console.json'
        $payload = @{ 
            TotalDownloaded = $Script:TotalDownload
            TotalUploaded = $Script:TotalUpload
            LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        } | ConvertTo-Json -Depth 3
        $tmp = "$backup.tmp"
        $payload | Set-Content -Path $tmp -Encoding UTF8 -Force
        Move-Item -Path $tmp -Destination $backup -Force
        return $true
    } catch {
        return $false
    }
}
# RAMManager: non-blocking MMF access with background writer (mirrors ENGINE)
class RAMManager {
    [System.IO.MemoryMappedFiles.MemoryMappedFile]$MMF
    [System.IO.MemoryMappedFiles.MemoryMappedViewAccessor]$Accessor
    [System.Threading.Mutex]$Mutex
    [string]$MutexName
    [string]$MMFName
    [int]$TimeoutMs
    [int]$MaxSize
    [string]$ErrorLogPath
    [string]$CachedJson
    [object]$CachedLock  # v39 FIX: Lock dla CachedJson
    [System.Collections.Concurrent.ConcurrentQueue[string]]$WriteQueue
    [int]$MaxQueue
    [int]$QueueDrops
    [int]$BackgroundWrites
    [int]$BackgroundRetries
    [bool]$UseLockFree
    [System.Threading.CancellationTokenSource]$WriterCTS
    [bool]$IsInitialized  # v39 FIX: Flaga inicjalizacji
    static [int]$HEADER_ACTIVE_OFFSET = 0      # Int32 - aktywny slot (0 lub 1)
    static [int]$HEADER_SIZE = 4               # Rozmiar naglowka globalnego
    static [int]$SLOT_VER_OFFSET = 0           # Int64 - wersja w slocie
    static [int]$SLOT_LEN_OFFSET = 8           # Int32 - dlugosc danych w slocie
    static [int]$SLOT_DATA_OFFSET = 12         # Poczatek danych w slocie
    static [int]$MIN_MMF_SIZE = 4096           # Minimalny rozmiar MMF
    RAMManager([string]$name) {
        $this.MutexName = "Global\CPUManager_RAM_$name"
        $this.MMFName = "Global\CPUManager_MMF_$name"
        $this.TimeoutMs = 200
        $this.MaxSize = 2097152
        $this.ErrorLogPath = "C:\CPUManager\ErrorLog.txt"
        $this.CachedJson = "{}"
        $this.CachedLock = New-Object Object
        $this.IsInitialized = $false
        if ($this.MaxSize -lt [RAMManager]::MIN_MMF_SIZE) {
            $this.LogError("MMF size too small: $($this.MaxSize), minimum: $([RAMManager]::MIN_MMF_SIZE)")
            throw "MMF size too small"
        }
        try { 
            $this.Mutex = [System.Threading.Mutex]::OpenExisting($this.MutexName) 
        } catch { 
            try {
                $this.Mutex = [System.Threading.Mutex]::new($false, $this.MutexName) 
            } catch {
                $this.LogError("Mutex create failed: $_")
                throw
            }
        }
        try {
            $this.MMF = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($this.MMFName)
        } catch {
            try {
                $this.MMF = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($this.MMFName, $this.MaxSize, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
            } catch {
                $this.LogError("MMF create failed: $_")
                if ($this.Mutex) { try { $this.Mutex.Dispose() } catch {} }
                throw
            }
        }
        try {
            $this.Accessor = $this.MMF.CreateViewAccessor(0, $this.MaxSize)
        } catch {
            $this.LogError("Accessor create failed: $_")
            if ($this.MMF) { try { $this.MMF.Dispose() } catch {} }
            if ($this.Mutex) { try { $this.Mutex.Dispose() } catch {} }
            throw
        }
        $this.WriteQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $this.MaxQueue = 1000
        $this.QueueDrops = 0
        $this.BackgroundWrites = 0
        $this.BackgroundRetries = 0
        $this.UseLockFree = $true
        $this.WriterCTS = [System.Threading.CancellationTokenSource]::new()
        try {
            $slotSize = $this.GetSlotSize()
            if ($slotSize -lt [RAMManager]::SLOT_DATA_OFFSET + 10) {
                $this.LogError("Slot size too small: $slotSize")
            } else {
                $empty = [System.Text.Encoding]::UTF8.GetBytes("{}")
                if ($empty.Length -le ($slotSize - [RAMManager]::SLOT_DATA_OFFSET)) {
                    # Inicjalizuj slot 0
                    $base0 = [RAMManager]::HEADER_SIZE + (0 * $slotSize)
                    $ver0 = [Int64]([DateTime]::UtcNow.Ticks)
                    $this.Accessor.Write($base0 + [RAMManager]::SLOT_VER_OFFSET, [Int64]$ver0)
                    $this.Accessor.Write($base0 + [RAMManager]::SLOT_LEN_OFFSET, [int]$empty.Length)
                    $this.Accessor.WriteArray($base0 + [RAMManager]::SLOT_DATA_OFFSET, $empty, 0, $empty.Length)
                    # Inicjalizuj slot 1
                    $base1 = [RAMManager]::HEADER_SIZE + (1 * $slotSize)
                    $ver1 = [Int64]([DateTime]::UtcNow.Ticks)
                    $this.Accessor.Write($base1 + [RAMManager]::SLOT_VER_OFFSET, [Int64]$ver1)
                    $this.Accessor.Write($base1 + [RAMManager]::SLOT_LEN_OFFSET, [int]$empty.Length)
                    $this.Accessor.WriteArray($base1 + [RAMManager]::SLOT_DATA_OFFSET, $empty, 0, $empty.Length)
                    # Ustaw aktywny slot na 0
                    $this.Accessor.Write([RAMManager]::HEADER_ACTIVE_OFFSET, [int]0)
                    $this.SetCachedJson("{}")
                    $this.IsInitialized = $true
                }
            }
        } catch {
            $this.LogError("Slot init failed: $_")
        }
        # Background writer task with hang prevention
        $self = $this
        $cts = $this.WriterCTS
        $restartWriter = {
            if ($self.WriterCTS) {
                try { $self.WriterCTS.Cancel(); Start-Sleep -Milliseconds 100; $self.WriterCTS.Dispose() } catch {}
            }
            $self.WriterCTS = [System.Threading.CancellationTokenSource]::new()
            $cts = $self.WriterCTS
            [System.Threading.Tasks.Task]::Run([Action]{ $self.BackgroundWriterLoop($cts) }) | Out-Null
        }
        function global:RAMManager_BackgroundWriterLoop {
            param($self, $cts)
            $hangCounter = 0
            while (-not $cts.IsCancellationRequested) {
                $itemRef = [ref]$null
                if ($self.WriteQueue.TryDequeue([ref]$itemRef)) {
                    $jsonItem = $itemRef.Value
                    $written = $false
                    $retries = 0
                    while (-not $written -and $retries -lt 10) {
                        try {
                            if ($self.UseLockFree) {
                                $active = $self.Accessor.ReadInt32([RAMManager]::HEADER_ACTIVE_OFFSET)
                                if ($active -ne 0 -and $active -ne 1) { $active = 0 }
                                $slotSize = $self.GetSlotSize()
                                $slot = 1 - $active
                                $base = [RAMManager]::HEADER_SIZE + ($slot * $slotSize)
                                $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonItem)
                                $maxDataSize = $slotSize - [RAMManager]::SLOT_DATA_OFFSET
                                if ($bytes.Length -gt $maxDataSize) {
                                    $written = $true; break
                                }
                                $ver = [Int64]([DateTime]::UtcNow.Ticks)
                                $self.Accessor.Write($base + [RAMManager]::SLOT_VER_OFFSET, [Int64]$ver)
                                $self.Accessor.Write($base + [RAMManager]::SLOT_LEN_OFFSET, [int]$bytes.Length)
                                $self.Accessor.WriteArray($base + [RAMManager]::SLOT_DATA_OFFSET, $bytes, 0, $bytes.Length)
                                $self.Accessor.Write([RAMManager]::HEADER_ACTIVE_OFFSET, [int]$slot)
                                $self.SetCachedJson($jsonItem)
                                $self.BackgroundWrites++
                                $written = $true
                            } else {
                                if ($self.Mutex.WaitOne(500)) {
                                    try {
                                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonItem)
                                        if ($bytes.Length -le ($self.MaxSize - 12)) {
                                            $ver = [Int64]([DateTime]::UtcNow.Ticks)
                                            $self.Accessor.Write(0, [Int64]$ver)
                                            $self.Accessor.Write(8, [int]$bytes.Length)
                                            $self.Accessor.WriteArray(12, $bytes, 0, $bytes.Length)
                                            $self.SetCachedJson($jsonItem)
                                            $self.BackgroundWrites++
                                            $written = $true
                                        } else {
                                            $written = $true
                                        }
                                    } finally { $self.Mutex.ReleaseMutex() }
                                } else { $retries++; $self.BackgroundRetries++; Start-Sleep -Milliseconds (50 * $retries) }
                            }
                        } catch { $retries++; $self.BackgroundRetries++; Start-Sleep -Milliseconds (200 * $retries) }
                    }
                    $hangCounter = 0
                } else {
                    Start-Sleep -Milliseconds 50
                    $hangCounter++
                    if ($hangCounter -gt 400) {
                        # If queue is blocked for 20s, clear and restart writer
                        $self.WriteQueue.Clear()
                        $hangCounter = 0
                        & $restartWriter
                        return
                    }
                }
                if ($self.WriteQueue.Count -gt $self.MaxQueue) {
                    $self.WriteQueue.Clear()
                    & $restartWriter
                    return
                }
            }
        }
        $self.BackgroundWriterLoop = { param($cts) RAMManager_BackgroundWriterLoop $self $cts }
        [System.Threading.Tasks.Task]::Run([Action]{ $self.BackgroundWriterLoop($cts) }) | Out-Null
    }
    [int]GetSlotSize() {
        return [Math]::Floor(($this.MaxSize - [RAMManager]::HEADER_SIZE) / 2)
    }
    [void]SetCachedJson([string]$json) {
        [System.Threading.Monitor]::Enter($this.CachedLock)
        try { $this.CachedJson = $json }
        finally { [System.Threading.Monitor]::Exit($this.CachedLock) }
    }
    [string]GetCachedJson() {
        [System.Threading.Monitor]::Enter($this.CachedLock)
        try { return $this.CachedJson }
        finally { [System.Threading.Monitor]::Exit($this.CachedLock) }
    }
    [void]WriteRaw([string]$json) {
        try {
            if ($this.WriteQueue.Count -ge $this.MaxQueue) { $this.QueueDrops++; $this.LogError("WriteRaw: queue full, drop event"); return }
            $this.WriteQueue.Enqueue($json)
        } catch { $this.LogError("WriteRaw enqueue ERROR: $_") }
    }
    [string]ReadRaw() {
        try {
            if ($this.UseLockFree) {
                $slotSize = $this.GetSlotSize()
                $maxDataSize = $slotSize - [RAMManager]::SLOT_DATA_OFFSET
                for ($retry = 0; $retry -lt 5; $retry++) {
                    $active = $this.Accessor.ReadInt32([RAMManager]::HEADER_ACTIVE_OFFSET)
                    if ($active -ne 0 -and $active -ne 1) { 
                        Start-Sleep -Milliseconds 5
                        continue 
                    }
                    $base = [RAMManager]::HEADER_SIZE + ($active * $slotSize)
                    $ver1 = $this.Accessor.ReadInt64($base + [RAMManager]::SLOT_VER_OFFSET)
                    $length = $this.Accessor.ReadInt32($base + [RAMManager]::SLOT_LEN_OFFSET)
                    if ($length -le 0 -or $length -gt $maxDataSize) { 
                        Start-Sleep -Milliseconds 5
                        continue 
                    }
                    $bytes = New-Object byte[] $length
                    $this.Accessor.ReadArray($base + [RAMManager]::SLOT_DATA_OFFSET, $bytes, 0, $length)
                    $ver2 = $this.Accessor.ReadInt64($base + [RAMManager]::SLOT_VER_OFFSET)
                    if ($ver1 -ne $ver2) { 
                        # Writer collision - retry
                        Start-Sleep -Milliseconds 5
                        continue 
                    }
                    $result = [System.Text.Encoding]::UTF8.GetString($bytes)
                    $this.SetCachedJson($result)
                    return $result
                }
                # Po wszystkich retry - zwroc cached
                return $this.GetCachedJson()
            } else {
                if ($this.Mutex.WaitOne(50)) {
                    try {
                        $length = $this.Accessor.ReadInt32(8)
                        if ($length -le 0 -or $length -gt ($this.MaxSize - 12)) { return $this.GetCachedJson() }
                        $bytes = New-Object byte[] $length
                        $this.Accessor.ReadArray(12, $bytes, 0, $length)
                        $result = [System.Text.Encoding]::UTF8.GetString($bytes)
                        $this.SetCachedJson($result)
                        return $result
                    } finally { $this.Mutex.ReleaseMutex() }
                } else { return $this.GetCachedJson() }
            }
        } catch { $this.LogError("ReadRaw ERROR: $_"); return $this.GetCachedJson() }
    }
    [void]Write([string]$key, $value) {
        try {
            $json = $this.ReadRaw()
            $data = $null
            try { $data = $json | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
            if (-not $data) { $data = @{} }
            elseif ($data -is [System.Array]) { $data = @{ Items = $data } }
            if ($data -is [PSCustomObject]) { $data | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force } else { $data[$key] = $value }
            $newJson = $data | ConvertTo-Json -Depth 10 -Compress
            $this.WriteRaw($newJson)
        } catch { $this.LogError("Write($key) ERROR: $_") }
    }
    [object]Read([string]$key) {
        try { 
            $json = $this.ReadRaw()
            $data = $null
            try { $data = $json | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
            if (-not $data) { return $null }
            if ($data -is [System.Array]) { return $null }
            if ($data -is [PSCustomObject]) { return $data.PSObject.Properties[$key].Value } 
            else { return $data[$key] }
        } catch { $this.LogError("Read($key) ERROR: $_"); return $null }
    }
    [bool]Exists([string]$key) {
        try { 
            $json = $this.ReadRaw()
            $data = $null
            try { $data = $json | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
            if (-not $data) { return $false }
            if ($data -is [System.Array]) { return $false }
            if ($data -is [PSCustomObject]) { return $null -ne $data.PSObject.Properties[$key] } 
            else { return $data.ContainsKey($key) }
        } catch { $this.LogError("Exists($key) ERROR: $_"); return $false }
    }
    [void]Clear() {
        $this.WriteRaw("{}")
        $this.SetCachedJson("{}")
    }
    [bool]BackupToJSON([string]$filePath) {
        try { 
            $json = $this.ReadRaw()
            $tmpPath = "$filePath.tmp"
            $json | Set-Content $tmpPath -Encoding UTF8 -Force
            Move-Item $tmpPath $filePath -Force
            return $true 
        } catch { $this.LogError("BackupToJSON ERROR: $_"); return $false }
    }
    [bool]RestoreFromJSON([string]$filePath) {
        try { 
            if (-not (Test-Path $filePath)) { return $false }
            $json = Get-Content $filePath -Raw -Encoding UTF8
            try { $null = $json | ConvertFrom-Json -ErrorAction Stop } 
            catch { $this.LogError("RestoreFromJSON: Invalid JSON in $filePath"); return $false }
            $this.WriteRaw($json)
            return $true 
        } catch { $this.LogError("RestoreFromJSON ERROR: $_"); return $false }
    }
    [void]LogError([string]$message) {
        try { $logEntry = "$(Get-Date -Format 'HH:mm:ss') - RAMManager: $message"; Add-Content -Path $this.ErrorLogPath -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    }
    [hashtable]GetTelemetry() {
        return @{ QueueSize = $this.WriteQueue.Count; QueueDrops = $this.QueueDrops; BackgroundWrites = $this.BackgroundWrites; BackgroundRetries = $this.BackgroundRetries; IsInitialized = $this.IsInitialized }
    }
    [void]Dispose() {
        if ($this.WriterCTS) { 
            try { 
                $this.WriterCTS.Cancel()
                Start-Sleep -Milliseconds 200
                $this.WriterCTS.Dispose()
            } catch {} 
        }
        try { if ($this.Accessor) { $this.Accessor.Dispose() } } catch {}
        try { if ($this.MMF) { $this.MMF.Dispose() } } catch {}
        try { if ($this.Mutex) { $this.Mutex.Dispose() } } catch {}
    }
}
# STORAGE MODE MANAGER - Zarzadza trybami JSON/RAM/BOTH + Auto-Backup
# #
# STORAGE MODE FUNCTIONS - JSON, RAM, OBA
# #
$Script:SharedRAM = $null
function Get-StorageMode {
    try {
        if (Test-Path $Script:StorageModeConfigPath) {
            $config = Get-Content $Script:StorageModeConfigPath -Raw | ConvertFrom-Json
            if ($config.Mode) {
                # Nowy format ENGINE v39.8.0: { "Mode": "JSON/RAM/BOTH" }
                $useRAM = ($config.Mode -eq "RAM" -or $config.Mode -eq "BOTH")
                $useJSON = ($config.Mode -eq "JSON" -or $config.Mode -eq "BOTH")
                return @{
                    UseJSON = $useJSON
                    UseRAM = $useRAM
                    PreferJSON = if ($null -ne $config.PreferJSON) { $config.PreferJSON } else { $true }
                }
            } elseif ($null -ne $config.UseRAM) {
                # Stary format CONFIGURATOR: { "UseJSON": true, "UseRAM": false }
                return @{
                    UseJSON = $config.UseJSON
                    UseRAM = $config.UseRAM
                    PreferJSON = if ($null -ne $config.PreferJSON) { $config.PreferJSON } else { $false }
                }
            }
        }
    } catch { }
    # Default: JSON only
    return @{ UseJSON = $true; UseRAM = $false; PreferJSON = $true }
}
function Set-StorageMode {
    param(
        [bool]$UseJSON,
        [bool]$UseRAM
    )
    try {
        $mode = if ($UseJSON -and $UseRAM) { "BOTH" }
                elseif ($UseRAM) { "RAM" }
                else { "JSON" }
        @{ 
            Mode = $mode
            UseJSON = $UseJSON
            UseRAM = $UseRAM
            PreferJSON = ($Script:PreferJSONOverRAM -eq $true)
        } | ConvertTo-Json | Out-File -FilePath "C:\CPUManager\StorageMode.json" -Force -Encoding utf8
        $Script:UseJSONStorage = $UseJSON
        $Script:UseRAMStorage = $UseRAM
        if ($Script:lblStorageMode) {
            $labelText = if ($UseJSON -and $UseRAM) { "JSON + RAM" } elseif ($UseRAM) { "RAM only" } else { "JSON only" }
            $Script:lblStorageMode.Text = "Storage: $labelText"
            $Script:lblStorageMode.ForeColor = if ($UseRAM) { [System.Drawing.Color]::Cyan } else { [System.Drawing.Color]::Orange }
        }
        return $true
    } catch {
        return $false
    }
}
function Read-WidgetData {
    $dataJSON = $null
    $dataRAM = $null
    if ($Script:UseJSONStorage) {
        $path = $Script:DataPath
        if (Test-Path $path) {
            try {
                $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                $json = $reader.ReadToEnd()
                $reader.Dispose()
                $fs.Dispose()
                if (-not [string]::IsNullOrWhiteSpace($json)) {
                    try {
                        $dataJSON = $json | ConvertFrom-Json -ErrorAction Stop
                    } catch {
                        try {
                            $errorLog = "C:\CPUManager\ErrorLog.txt"
                            $msg = "$(Get-Date -Format 'HH:mm:ss') - Read-WidgetData: Invalid JSON in $path - $_"
                            Add-Content -Path $errorLog -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
                        } catch {}
                    }
                }
            } catch { 
                # File access error - silent fail
            }
        }
    }
    if ($Script:UseRAMStorage -and $Script:SharedRAM) {
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $dataRAM = $Script:SharedRAM.Read("WidgetData")
            $sw.Stop()
            if ($sw.ElapsedMilliseconds -gt 150) {
                try {
                    $errorLog = "C:\CPUManager\ErrorLog.txt"
                    $msg = "$(Get-Date -Format 'HH:mm:ss') - Read-WidgetData: Slow RAM read ($($sw.ElapsedMilliseconds)ms)"
                    Add-Content -Path $errorLog -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
                } catch {}
            }
        } catch { 
            # SharedRAM error - use JSON fallback
        }
    }
    # Zwroc dane: wybor priorytetu zaleznie od flagi PreferJSONOverRAM
    if ($Script:PreferJSONOverRAM) {
        if ($dataJSON) { return $dataJSON }
        if ($dataRAM) { return $dataRAM }
    } else {
        if ($dataRAM) { return $dataRAM }
        if ($dataJSON) { return $dataJSON }
    }
    return $null
}
# #
# POWERSHELL & WINDOWS FORMS INITIALIZATION
# #
#Requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# Ukryj konsole PowerShell + Win32 functions
Add-Type -Name Win32Console -Namespace Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("psapi.dll")] public static extern int EmptyWorkingSet(IntPtr hwProc);
'@ -ErrorAction SilentlyContinue
Add-Type -Name Win32 -Namespace Win32API -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
'@ -ErrorAction SilentlyContinue
try { [Console.Win32Console]::ShowWindow([Console.Win32Console]::GetConsoleWindow(), 0) | Out-Null } catch {}
# #
# KONFIGURACJA SCIEZEK
# #
$Script:ConfigDir = "C:\CPUManager"
$Script:DataPath = Join-Path $Script:ConfigDir "WidgetData.json"
$Script:CommandPath = Join-Path $Script:ConfigDir "WidgetCommand.txt"
$Script:ConfigJsonPath = Join-Path $Script:ConfigDir "config.json"
$Script:AIEnginesPath = Join-Path $Script:ConfigDir "AIEngines.json"
$Script:TDPConfigPath = Join-Path $Script:ConfigDir "TDPConfig.json"
$Script:ReloadSignalPath = Join-Path $Script:ConfigDir "reload.signal"
$Script:NetworkStatsPath = Join-Path $Script:ConfigDir "NetworkStats.json"
$Script:StorageModeConfigPath = Join-Path $Script:ConfigDir "StorageMode.json"  # V38 FIX: Dynamiczna sciezka
$Script:PersistentNetDL = [int64]0
$Script:PersistentNetUL = [int64]0
$Script:NetworkStatsLoaded = $false
# Throttle last write to NetworkStats.json from Console (seconds)
$Script:LastNetworkStatsWriteTime = Get-Date '1970-01-01'
$Script:LastReloadSignal = [datetime]::MinValue
$Script:ReloadThrottleMs = 500  # Minimum 500ms miedzy sygnalami
#  PERFORMANCE: Synchroniczny zapis reload.signal dla natychmiastowej detekcji przez ENGINE
function Send-ReloadSignal {
    param([hashtable]$SignalData = @{})
    $now = [datetime]::Now
    if (($now - $Script:LastReloadSignal).TotalMilliseconds -lt $Script:ReloadThrottleMs) {
        return  # Skip if too soon since last signal
    }
    try {
        $Script:LastReloadSignal = $now
        $defaultSignal = @{ 
            Timestamp = $now.ToString("o")  # ISO 8601 format dla ENGINE
            Source = "Configurator"
        }
        $signal = $defaultSignal + $SignalData
        $sigJson = $signal | ConvertTo-Json -Compress
        
        #  SYNC WRITE: reload.signal musi byc natychmiast widoczny dla ENGINE
        # Atomic write: tmp -> move (zapobiega race condition)
        $tmp = "$($Script:ReloadSignalPath).tmp"
        [System.IO.File]::WriteAllText($tmp, $sigJson, [System.Text.Encoding]::UTF8)
        Start-Sleep -Milliseconds 20  # Minimum delay dla ENGINE detection
        try { 
            [System.IO.File]::Move($tmp, $Script:ReloadSignalPath, $true) 
        } catch { 
            [System.IO.File]::Copy($tmp, $Script:ReloadSignalPath, $true)
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    } catch { 
        # Fallback - reset throttle on error
        $Script:LastReloadSignalTime = [datetime]::MinValue
        try {
            # Ultimate fallback - direct write
            $signal | ConvertTo-Json -Compress | Set-Content $Script:ReloadSignalPath -Encoding UTF8 -Force
        } catch { }
    }
}
$Script:ShutdownSignalPath = Join-Path $Script:ConfigDir "shutdown.signal"
function Send-ShutdownSignal {
    param([hashtable] $SignalData = @{})
    try {
        $defaultSignal = @{
            Timestamp = [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss.fff")
            Source = "CONFIGURATOR"
        }
        $signal = $defaultSignal + $SignalData
        $sigJson = $signal | ConvertTo-Json
        Start-BackgroundWrite $Script:ShutdownSignalPath $sigJson 'UTF8'
        Write-Host " Shutdown signal sent to ENGINE"
    } catch {
        Write-Host "- Shutdown signal error: $_"
    }
}
$Script:RyzenAdjPath = "C:\ryzenadj-win64\ryzenadj.exe"
$Script:SessionNetDL = [int64]0  # Bytes pobrane w tej sesji CONSOLE
$Script:SessionNetUL = [int64]0  # Bytes wyslane w tej sesji CONSOLE
$Script:BaselineTotalDL = [int64]0
$Script:BaselineTotalUL = [int64]0
$Script:BaselineInitialized = $false
$Script:LastNetTime = [DateTime]::Now  # Inicjalizacja na TERAZ
$Script:LastNetRecv = [int64]0
$Script:LastNetSent = [int64]0
$Script:LiveNetDL = [int64]0  # Aktualna predkosc pobierania (B/s)
$Script:LiveNetUL = [int64]0  # Aktualna predkosc wysylania (B/s)
$Script:LiveDiskReadMBs = 0.0  # Samodzielny odczyt I/O dysku (MB/s)
$Script:LiveDiskWriteMBs = 0.0  # Samodzielny zapis I/O dysku (MB/s)
$Script:NetAdapterCache = $null
$Script:NetAdapterCacheTime = [DateTime]::Now  # Inicjalizacja na TERAZ
$Script:NetStatsInitialized = $false  # Flaga pierwszego uruchomienia
$Script:RefreshInterval = 500  # v39 FIX: Zwiekszono z 250ms na 500ms dla stabilnosci
$Script:CPUHistory = [System.Collections.Generic.List[double]]::new()
# === OHM/LHM HARDWARE MONITORING ===
$Script:OHM_Available = $false
$Script:LHM_Available = $false
$Script:OHM_LastCheck = [DateTime]::MinValue
$Script:OHM_CheckInterval = 5
$Script:HWMonitorData = @{ GPUTemp = 0; GPULoad = 0; VRMTemp = 0; CPUPower = 0 }
# === JOB MANAGEMENT PROTECTION ===
$Script:ActiveJobs = @()
$Script:MaxConcurrentJobs = 3
function Add-ManagedJob {
    param($Job, $Description)
    # CLEANUP: Usun zakonczone job-y
    $Script:ActiveJobs = $Script:ActiveJobs | Where-Object { $_.State -eq 'Running' }
    # LIMIT: Max 3 concurrent jobs aby nie zawieszac systemu
    if ($Script:ActiveJobs.Count -ge $Script:MaxConcurrentJobs) {
        Write-Host "[WARN]  Too many jobs running ($($Script:ActiveJobs.Count)), waiting..."
        # Czekaj az najstarszy job sie skonczy
        if ($Script:ActiveJobs.Count -gt 0) {
            Wait-Job -Job $Script:ActiveJobs[0] -Timeout 3 | Out-Null
            Remove-Job -Job $Script:ActiveJobs[0] -Force -ErrorAction SilentlyContinue
        }
        # Refresh list
        $Script:ActiveJobs = $Script:ActiveJobs | Where-Object { $_.State -eq 'Running' }
    }
    $Script:ActiveJobs += $Job
    Write-Host " Started job: $Description (Active: $($Script:ActiveJobs.Count))"
}
function Remove-ManagedJob {
    param($Job)
    $Script:ActiveJobs = $Script:ActiveJobs | Where-Object { $_ -ne $Job }
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
}
$Script:CachedWidgetData = $null
$Script:CachedWidgetDataLock = [object]::new()
$Script:BackgroundRefreshTimer = $null
$Script:TempHistory = [System.Collections.Generic.List[double]]::new()
$Script:MaxHistory = 120
$Script:AppCategoryData = $null
$Script:selectedAppForCategory = $null
$Script:WorkingDir = "C:\CPUManager"
$Script:LastData = $null
$Script:ForceExit = $false
$Script:TDPRefreshCounter = 0
$Script:PreferJSONOverRAM = $true
if (-not (Test-Path $Script:ConfigDir)) { New-Item -ItemType Directory -Path $Script:ConfigDir -Force | Out-Null }
# #
# STORAGE MODE INITIALIZATION
# #
 $storageConfig = Get-StorageMode
 $Script:UseJSONStorage = $storageConfig.UseJSON
 $Script:UseRAMStorage = $storageConfig.UseRAM
 # Initialize preference flag from storage (default true)
 if ($null -ne $storageConfig.PreferJSON) { $Script:PreferJSONOverRAM = $storageConfig.PreferJSON } else { $Script:PreferJSONOverRAM = $true }
# Update checkbox state if UI element exists (script may have created it earlier)
try { if ($cbPreferJson) { $cbPreferJson.Checked = $Script:PreferJSONOverRAM } } catch {}
# Auto-enable RAM storage if an existing MMF from Engine is present
if (-not $Script:UseRAMStorage) {
    try {
        $mmfName = "Global\CPUManager_MMF_MainEngine"
        try { [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($mmfName) | Out-Null; $mmfExists = $true } catch { $mmfExists = $false }
        if ($mmfExists) {
            $Script:UseRAMStorage = $true
            Write-Host "[DEBUG] Console: detected existing MMF ($mmfName) - enabling RAM storage" -ForegroundColor Yellow
        }
    } catch { }
}
if ($Script:UseRAMStorage) {
    $Script:SharedRAM = [RAMManager]::new("MainEngine")
}
# ═══════════════════════════════════════════════════════════════════════════════
# #
# DOMYSLNA KONFIGURACJA
# #
$Script:DefaultConfig = @{
    ForceMode = ""
    #  SYNC v40: PowerModes dla AMD (RyzenStates) - zsynchronizowane z ENGINE
    PowerModes = @{
        Silent   = @{ Min = 50;  Max = 85  }   # AMD: Cichy ale responsywny
        Balanced = @{ Min = 70;  Max = 99  }   # AMD: Stabilne Balanced
        Turbo    = @{ Min = 85;  Max = 100 }   # AMD: Agresywny Turbo
        Extreme  = @{ Min = 100; Max = 100 }   # AMD: Pelna moc
    }
    #  SYNC v40: PowerModes dla Intel (IntelStates) - zsynchronizowane z ENGINE
    PowerModesIntel = @{
        Silent   = @{ Min = 50;  Max = 85  }   # Intel: Cichy tryb (responsywny)
        Balanced = @{ Min = 85;  Max = 99  }   # Intel: Praca biurowa (wysoka responsywnosc)
        Turbo    = @{ Min = 99;  Max = 100 }   # Intel: Gaming, kompilacja (pelna moc)
        Extreme  = @{ Min = 100; Max = 100 }   # Intel: Benchmark, rendering (max staly)
    }
    #  SYNC v40: AIThresholds - zsynchronizowane z ENGINE (poprawki efektywności energetycznej)
    AIThresholds = @{
        TurboThreshold = 72           # CPU% powyzej ktorego wlacza Turbo
        BalancedThreshold = 38        # CPU% powyzej ktorego wlacza Balanced
        ForceSilentCPU = 20           # CPU% ponizej ktorego wymusza Silent (bylo 10)
        ForceSilentCPUInactive = 25   # CPU% dla nieaktywnego uzytkownika (bylo 15)
    }
    BoostSettings = @{
        BoostDuration = 10000
        BoostCooldown = 20
        AppLaunchSensitivity = @{ CPUDelta = 12; CPUThreshold = 22 }
        AutoBoostEnabled = $true
        AutoBoostSampleMs = 350
        EnableBoostForAllAppsOnStart = $true
        StartupBoostDurationSeconds = 3
    }
    IOSettings = @{
        ReadThreshold = 80; WriteThreshold = 50; Sensitivity = 4    #  SYNC: zgodne z ENGINE
        CheckInterval = 1200; TurboThreshold = 150                   #  SYNC: 150 jak w ENGINE (bylo 50)
        OverrideForceMode = $false; ExtremeGraceSeconds = 8
    }
    OptimizationSettings = @{
        PreloadEnabled = $true
        CacheSize = 50
        PreBoostDuration = 15000
        PredictiveBoostEnabled = $true
    }
    SmartPreload = $true
    MemoryCompression = $false
    PowerBoost = $false
    PredictiveIO = $true
    CPUAgressiveness = 50
    MemoryAgressiveness = 30
    IOPriority = 3
    # ═══════════════════════════════════════════════════════════════════════════════
    # IDENTYCZNE wartości domyślne jak w ENGINE!
    # ═══════════════════════════════════════════════════════════════════════════════
    # Network Settings (domyślnie WŁĄCZONE - max wydajność sieci)
    Network = @{
        Enabled = $true              # Główny przełącznik Network Optimizer
        DisableNagle = $true         # Wyłącz Nagle Algorithm (niższy ping)
        OptimizeTCP = $true          # Optymalizuj TCP/ACK
        OptimizeDNS = $true          # Ustaw Cloudflare DNS (1.1.1.1)
        # ULTRA Network Settings - maksymalna przepustowość
        MaximizeTCPBuffers = $true   # Maksymalne bufory TCP/IP (64KB-16MB)
        EnableWindowScaling = $true  # TCP Window Scaling dla gigabit
        EnableRSS = $true            # RSS (Receive Side Scaling) multi-core
        EnableLSO = $true            # LSO (Large Send Offload) dla dużych transferów
        DisableChimney = $true       # Wyłącz TCP Chimney (problematyczny)
    }
    # Privacy Settings (domyślnie WŁĄCZONE - max prywatność)
    Privacy = @{
        Enabled = $true              # Główny przełącznik Privacy Shield
        BlockTelemetry = $true       # Blokuj telemetrię Microsoft
        DisableCortana = $true       # Wyłącz Cortanę
        DisableLocation = $true      # Wyłącz lokalizację
        DisableAds = $true           # Wyłącz reklamy
        DisableTimeline = $true      # Wyłącz oś czasu
    }
    # Performance Settings (domyślnie częściowo WŁĄCZONE)
    Performance = @{
        OptimizeMemory = $true       # Optymalizuj pamięć
        OptimizeFileSystem = $true   # Optymalizuj system plików (NTFS)
        OptimizeVisualEffects = $false  # Efekty wizualne (opcjonalne - może zmienić wygląd)
        OptimizeStartup = $true      # Optymalizuj startup
        OptimizeNetwork = $true      # Optymalizuj ustawienia sieciowe
    }
    # Services Settings (domyślnie WŁĄCZONE oprócz Search)
    Services = @{
        DisableFax = $true           # Wyłącz usługę faksów
        DisableRemoteAccess = $true  # Wyłącz zdalny dostęp (bezpieczeństwo!)
        DisableTablet = $true        # Wyłącz usługi tabletu (na PC desktop)
        DisableSearch = $false       # Windows Search (OSTROŻNIE - psuje wyszukiwanie!)
    }
    # End of config
}
$Script:DefaultTDP = @{
    #  SYNC v40: TDP profiles zsynchronizowane z ENGINE
    Silent = @{ STAPM = 12; Fast = 28; Slow = 15; Tctl = 75 }    # Zmienione z STAPM=10,Fast=15,Slow=12,Tctl=65
    Balanced = @{ STAPM = 15; Fast = 28; Slow = 22; Tctl = 80 }
    Turbo = @{ STAPM = 25; Fast = 35; Slow = 30; Tctl = 88 }
    Extreme = @{ STAPM = 28; Fast = 40; Slow = 35; Tctl = 92 }
}
# #
# PALETA KOLOROW
# #
$Script:Colors = @{
    Background = [System.Drawing.Color]::FromArgb(25, 28, 32)
    Panel      = [System.Drawing.Color]::FromArgb(35, 38, 45)
    Card       = [System.Drawing.Color]::FromArgb(45, 48, 55)
    Border     = [System.Drawing.Color]::FromArgb(60, 65, 75)
    Text       = [System.Drawing.Color]::FromArgb(220, 225, 230)
    TextDim    = [System.Drawing.Color]::FromArgb(140, 145, 155)
    TextBright = [System.Drawing.Color]::White
    Accent     = [System.Drawing.Color]::FromArgb(0, 170, 255)
    AccentDim  = [System.Drawing.Color]::FromArgb(0, 120, 180)
    AccentBright = [System.Drawing.Color]::FromArgb(100, 200, 255)
    Success    = [System.Drawing.Color]::FromArgb(80, 200, 120)
    Warning    = [System.Drawing.Color]::FromArgb(255, 180, 50)
    Danger     = [System.Drawing.Color]::FromArgb(220, 60, 60)
    Info       = [System.Drawing.Color]::FromArgb(100, 150, 255)
    Silent     = [System.Drawing.Color]::FromArgb(100, 200, 255)
    Balanced   = [System.Drawing.Color]::FromArgb(120, 220, 100)
    Turbo      = [System.Drawing.Color]::FromArgb(255, 100, 80)
    Extreme    = [System.Drawing.Color]::FromArgb(255, 60, 180)
    Purple     = [System.Drawing.Color]::FromArgb(180, 100, 255)
    Cyan       = [System.Drawing.Color]::FromArgb(0, 220, 220)
    ChartCPU   = [System.Drawing.Color]::FromArgb(0, 200, 255)
    ChartTemp  = [System.Drawing.Color]::FromArgb(255, 120, 80)
}
# #
# FUNKCJE POMOCNICZE - GUI
# #
function New-Label {
    param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width = 200, [int]$Height = 20,
          [string]$FontName = "Segoe UI", [int]$FontSize = 9, [System.Drawing.FontStyle]$FontStyle = [System.Drawing.FontStyle]::Regular,
          [System.Drawing.Color]$ForeColor = $Script:Colors.Text, [System.Drawing.ContentAlignment]$Align = [System.Drawing.ContentAlignment]::MiddleLeft)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text; $lbl.Location = New-Object System.Drawing.Point($X, $Y); $lbl.Size = New-Object System.Drawing.Size($Width, $Height)
    $lbl.Font = New-Object System.Drawing.Font($FontName, $FontSize, $FontStyle); $lbl.ForeColor = $ForeColor; $lbl.TextAlign = $Align
    if ($Parent) { $Parent.Controls.Add($lbl) }
    return $lbl
}
function New-Panel {
    param([System.Windows.Forms.Control]$Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height, [System.Drawing.Color]$BackColor = $Script:Colors.Card)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y); $panel.Size = New-Object System.Drawing.Size($Width, $Height); $panel.BackColor = $BackColor
    if ($Parent) { $Parent.Controls.Add($panel) }
    return $panel
}
function New-Button {
    param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width = 100, [int]$Height = 35,
          [System.Drawing.Color]$BackColor = $Script:Colors.Card, [System.Drawing.Color]$ForeColor = $Script:Colors.Text, [scriptblock]$OnClick)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text; $btn.Location = New-Object System.Drawing.Point($X, $Y); $btn.Size = New-Object System.Drawing.Size($Width, $Height)
    $btn.BackColor = $BackColor; $btn.ForeColor = $ForeColor; $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderColor = $Script:Colors.Border; $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($OnClick) { $btn.Add_Click($OnClick) }
    if ($Parent) { $Parent.Controls.Add($btn) }
    return $btn
}
function New-SectionLabel {
    param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y)
    return New-Label -Parent $Parent -Text $Text -X $X -Y $Y -Width 300 -Height 20 -FontSize 10 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
}
function New-GroupBox {
    param([System.Windows.Forms.Control]$Parent, [string]$Title, [int]$X, [int]$Y, [int]$Width, [int]$Height)
    $gb = New-Object System.Windows.Forms.GroupBox
    $gb.Text = $Title; $gb.Location = New-Object System.Drawing.Point($X, $Y); $gb.Size = New-Object System.Drawing.Size($Width, $Height)
    $gb.ForeColor = $Script:Colors.Accent; $gb.BackColor = $Script:Colors.Background; $gb.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    if ($Parent) { $Parent.Controls.Add($gb) }
    return $gb
}
function New-NumericUpDown {
    param([System.Windows.Forms.Control]$Parent, [int]$X, [int]$Y, [int]$Min, [int]$Max, [int]$Value, [int]$Width = 80, [int]$Increment = 1)
    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Location = New-Object System.Drawing.Point($X, $Y); $num.Size = New-Object System.Drawing.Size($Width, 25)
    $num.Minimum = $Min; $num.Maximum = $Max; $num.Value = [Math]::Max($Min, [Math]::Min($Max, $Value)); $num.Increment = $Increment
    $num.BackColor = $Script:Colors.Card; $num.ForeColor = $Script:Colors.Text
    if ($Parent) { $Parent.Controls.Add($num) }
    return $num
}
function New-CheckBox {
    param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [bool]$Checked = $false, [int]$Width = 300)
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $Text; $cb.Location = New-Object System.Drawing.Point($X, $Y); $cb.Size = New-Object System.Drawing.Size($Width, 25)
    $cb.Checked = $Checked; $cb.ForeColor = $Script:Colors.Text; $cb.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard; $cb.UseVisualStyleBackColor = $true
    if ($Parent) { $Parent.Controls.Add($cb) }
    return $cb
}
# #
# FUNKCJE OHM/LHM - HARDWARE MONITORING
# #
function Test-OHMAvailable {
    try {
        $test = Get-WmiObject -Namespace "root\OpenHardwareMonitor" -Class Sensor -ErrorAction Stop | Select-Object -First 1
        return ($null -ne $test)
    } catch {
        return $false
    }
}

function Test-LHMAvailable {
    try {
        $test = Get-WmiObject -Namespace "root\LibreHardwareMonitor" -Class Sensor -ErrorAction Stop | Select-Object -First 1
        return ($null -ne $test)
    } catch {
        return $false
    }
}

function Get-HardwareMonitorData {
    $now = [DateTime]::Now
    
    # Sprawdz dostepnosc co 5 sekund
    if (($now - $Script:OHM_LastCheck).TotalSeconds -ge $Script:OHM_CheckInterval) {
        if (-not $Script:LHM_Available) {
            $Script:LHM_Available = Test-LHMAvailable
        }
        if (-not $Script:LHM_Available -and -not $Script:OHM_Available) {
            $Script:OHM_Available = Test-OHMAvailable
        }
        $Script:OHM_LastCheck = $now
    }
    
    # Preferuj LHM, potem OHM
    $namespace = if ($Script:LHM_Available) { "root\LibreHardwareMonitor" } elseif ($Script:OHM_Available) { "root\OpenHardwareMonitor" } else { $null }
    
    if (-not $namespace) { 
        return @{ GPUTemp = 0; GPULoad = 0; VRMTemp = 0; CPUPower = 0 }
    }
    
    try {
        $sensors = Get-WmiObject -Namespace $namespace -Class Sensor -ErrorAction Stop
        $result = @{ 
            GPUTemp = 0
            GPULoad = 0
            VRMTemp = 0
            CPUPower = 0
        }
        
        foreach ($sensor in $sensors) {
            $name = $sensor.Name
            $value = [math]::Round($sensor.Value, 1)
            $type = $sensor.SensorType
            $identifier = $sensor.Identifier
            
            # CPU Power
            if ($identifier -like "*/cpu/*" -or $identifier -like "*cpu*") {
                if ($type -eq "Power") {
                    if ($name -like "*Package*" -or $name -like "*CPU*" -or $name -like "*Total*") {
                        if ($value -gt $result.CPUPower) { $result.CPUPower = [int]$value }
                    }
                }
                # VRM Temperature (CPU VRM/VCore)
                if ($type -eq "Temperature") {
                    if ($name -like "*VRM*" -or $name -like "*VCore*" -or $name -like "*Voltage Regulator*") {
                        if ($value -gt $result.VRMTemp) { $result.VRMTemp = [int]$value }
                    }
                }
            }
            
            # Motherboard VRM
            if ($identifier -like "*/lpc/*" -or $identifier -like "*/mainboard/*" -or $identifier -like "*motherboard*") {
                if ($type -eq "Temperature") {
                    if ($name -like "*VRM*" -or $name -like "*MOS*" -or $name -like "*Voltage Regulator*" -or $name -like "*System*") {
                        if ($value -gt $result.VRMTemp -and $value -lt 150) { $result.VRMTemp = [int]$value }
                    }
                }
            }
            
            # GPU
            if ($identifier -like "*/gpu/*" -or $identifier -like "*/nvidiagpu/*" -or $identifier -like "*/atigpu/*" -or $identifier -like "*/intelgpu/*" -or $identifier -like "*/amdgpu/*") {
                switch ($type) {
                    "Load" {
                        if ($name -like "*GPU Core*" -or $name -eq "GPU Core" -or $name -like "*D3D 3D*") {
                            $result.GPULoad = [int]$value
                        }
                    }
                    "Temperature" {
                        if ($name -like "*GPU*" -or $name -like "*Core*" -or $name -like "*Junction*" -or $name -eq "Temperature") {
                            if ($value -gt $result.GPUTemp) { $result.GPUTemp = [int]$value }
                        }
                    }
                }
            }
        }
        
        # Cache wynikow
        $Script:HWMonitorData = $result
        return $result
    } catch {
        return $Script:HWMonitorData
    }
}

# #
# FUNKCJE - ODCZYT/ZAPIS DANYCH
# #
$Script:LastValidData = $null
$Script:LastIteration = -1
function Get-WidgetData {
    # Cache jest aktualizowany przez background timer
    $data = $null
    $lockTaken = $false
    try {
        # Thread-safe read z cache - z timeout 100ms (zwiększony dla stabilności)
        $lockTaken = [System.Threading.Monitor]::TryEnter($Script:CachedWidgetDataLock, 100)
        if ($lockTaken) {
            $data = $Script:CachedWidgetData
        } else {
            # Timeout - spróbuj świeży odczyt z pliku jako fallback
            try {
                $data = Read-WidgetData
                if ($data -and $data.CPU) {
                    Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value "$(Get-Date -Format 'HH:mm:ss') - [WARN] Cache lock timeout - used direct file read" -Encoding UTF8 -ErrorAction SilentlyContinue
                }
            } catch {}
            # Jeśli nadal brak danych, zwróć ostatnie dobre
            if (-not $data) { return $Script:LastValidData }
        }
    } finally {
        if ($lockTaken) {
            [System.Threading.Monitor]::Exit($Script:CachedWidgetDataLock)
        }
    }
    if ($null -eq $data) { return $Script:LastValidData }
    # 1. Musi miec CPU
    if ($null -eq $data.CPU) { return $Script:LastValidData }
    # 3. Iteration - wykryj restart ENGINE (duży spadek = ENGINE zrestartowany)
    $newIter = if ($data.Iteration) { [int]$data.Iteration } else { 0 }
    if ($newIter -lt $Script:LastIteration) {
        # Sprawdz czy to restart ENGINE (spadek > 50% lub > 100 punktow)
        $drop = $Script:LastIteration - $newIter
        $dropPercent = if ($Script:LastIteration -gt 0) { ($drop / $Script:LastIteration) * 100 } else { 0 }
        if ($dropPercent -gt 50 -or $drop -gt 100) {
            # ENGINE zrestartowany - zaakceptuj nowe dane i zresetuj tracking
            $Script:LastIteration = $newIter
            $Script:LastValidData = $data
            return $data
        }
        # Maly spadek - moze byc chwilowy blad, uzyj poprzednich danych
        if ($Script:LastValidData) { return $Script:LastValidData }
    }
    # Dane kompletne i swieze - zapisz do cache
    $Script:LastValidData = $data
    $Script:LastIteration = $newIter
    return $data
}
function Get-NetworkStats {
    $Script:TotalDownload = 0; $Script:TotalUpload = 0
    $ok = $false
    if (Test-Path $Script:NetworkStatsPath) {
        try {
            $fs = New-Object System.IO.FileStream($Script:NetworkStatsPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $json = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
            $data = $json | ConvertFrom-Json
            $Script:TotalDownload = if ($null -ne $data.TotalDownloaded) { [long]$data.TotalDownloaded } elseif ($null -ne $data.TotalDownload) { [long]$data.TotalDownload } else { 0 }
            $Script:TotalUpload = if ($null -ne $data.TotalUploaded) { [long]$data.TotalUploaded } elseif ($null -ne $data.TotalUpload) { [long]$data.TotalUpload } else { 0 }
            $ok = $true
        } catch {}
    }
    if (-not $ok) {
        # Sprobuj backup Widgeta
        $widgetBackup = Join-Path $Script:ConfigDir 'NetworkStats.Widget.json'
        if (Test-Path $widgetBackup) {
            try {
                $wdata = Get-Content $widgetBackup -Raw | ConvertFrom-Json
                $Script:TotalDownload = if ($null -ne $wdata.TotalDownloaded) { [long]$wdata.TotalDownloaded } elseif ($null -ne $wdata.TotalDownload) { [long]$wdata.TotalDownload } else { 0 }
                $Script:TotalUpload = if ($null -ne $wdata.TotalUploaded) { [long]$wdata.TotalUploaded } elseif ($null -ne $wdata.TotalUpload) { [long]$wdata.TotalUpload } else { 0 }
                $ok = $true
            } catch {}
        }
    }
    if (-not $ok) {
        # Sprobuj backup Console
        $consoleBackup = Join-Path $Script:ConfigDir 'NetworkStats.Console.json'
        if (Test-Path $consoleBackup) {
            try {
                $cdata = Get-Content $consoleBackup -Raw | ConvertFrom-Json
                $Script:TotalDownload = if ($null -ne $cdata.TotalDownloaded) { [long]$cdata.TotalDownloaded } elseif ($null -ne $cdata.TotalDownload) { [long]$cdata.TotalDownload } else { 0 }
                $Script:TotalUpload = if ($null -ne $cdata.TotalUploaded) { [long]$cdata.TotalUploaded } elseif ($null -ne $cdata.TotalUpload) { [long]$cdata.TotalUpload } else { 0 }
            } catch {}
        }
    }
    $Script:PersistentNetDL = $Script:TotalDownload
    $Script:PersistentNetUL = $Script:TotalUpload
    $Script:NetworkStatsLoaded = $true
}
function Send-Command {
    param(
        [string]$Cmd,
        [switch]$Silent,
        [switch]$ShowConfirmation
    )
    $success = $false
    try {
        # Sprawdź czy ENGINE działa
        $engineRunning = Test-EngineRunning
        if (-not $engineRunning -and -not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                "ENGINE nie jest uruchomiony!`n`nKomenda '$Cmd' została zapisana, ale zostanie wykonana dopiero po uruchomieniu ENGINE.",
                "Ostrzeżenie - ENGINE offline",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }
        
        $ps = [powershell]::Create()
        $job = $ps.AddScript({ param($path, $txt)
            $tmp = "$path.tmp"
            Start-Sleep -Milliseconds 100
            [System.IO.File]::WriteAllText($tmp, $txt, [System.Text.Encoding]::ASCII)
            try { 
                Move-Item -Path $tmp -Destination $path -Force 
            } catch { 
                Copy-Item -Path $tmp -Destination $path -Force
                Start-Sleep -Milliseconds 50
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue 
            }
        }).AddArgument($Script:CommandPath).AddArgument($Cmd)
        $asyncResult = $ps.BeginInvoke()
        $null = [System.Threading.Timer]::new({
            param($ps)
            try {
                if ($ps.InvocationStateInfo.State -eq 'Completed' -or $ps.InvocationStateInfo.State -eq 'Failed') {
                    $ps.Dispose()
                }
            } catch { }
        }, $ps, 5000, [System.Threading.Timeout]::Infinite)
        $success = $true
    } catch {
        try { 
            Start-Sleep -Milliseconds 50
            $Cmd | Set-Content $Script:CommandPath -Force -Encoding ASCII 
            $success = $true
        } catch { 
            try {
                [System.IO.File]::WriteAllText($Script:CommandPath, $Cmd)
                $success = $true
            } catch {
                $success = $false
            }
        }
    }
    
    # Pokaż potwierdzenie jeśli żądane
    if ($ShowConfirmation -and -not $Silent) {
        if ($success) {
            Show-StatusNotification -Message "Komenda '$Cmd' wysłana do ENGINE" -Type "Success"
        } else {
            Show-StatusNotification -Message "BŁĄD: Nie udało się wysłać komendy '$Cmd'" -Type "Error"
        }
    }
    
    return $success
}

# Funkcja sprawdzająca czy ENGINE działa
function Test-EngineRunning {
    try {
        $engineProcess = Get-Process -Name "powershell", "pwsh" -ErrorAction SilentlyContinue | Where-Object {
            try {
                $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
                $cmdLine -match "CPUManager.*v40.*\.ps1|CPUManager_v40"
            } catch { $false }
        }
        return ($null -ne $engineProcess -and $engineProcess.Count -gt 0)
    } catch {
        # Fallback: sprawdź czy plik ustawień ENGINE jest aktualny (< 30s)
        try {
            $settingsPath = Join-Path $Script:ConfigDir "EngineSettings.json"
            if (Test-Path $settingsPath) {
                $lastWrite = (Get-Item $settingsPath).LastWriteTime
                return (([DateTime]::Now - $lastWrite).TotalSeconds -lt 30)
            }
        } catch { }
        return $false
    }
}

# Funkcja pokazująca notyfikację statusu (non-blocking)
function Show-StatusNotification {
    param(
        [string]$Message,
        [string]$Type = "Info",  # Info, Success, Warning, Error
        [int]$Duration = 2000
    )
    
    # Użyj ToolTip jako non-blocking notification
    if ($Script:StatusToolTip) {
        $icon = switch ($Type) {
            "Success" { "✓" }
            "Warning" { "⚠" }
            "Error" { "✗" }
            default { "ℹ" }
        }
        $Script:StatusToolTip.Show("$icon $Message", $Script:MainForm, 10, $Script:MainForm.Height - 50, $Duration)
    }
}
# Async atomic writer helper to avoid blocking UI when signaling other processes
function Start-BackgroundWrite {
    param(
        [string]$Path,
        [string]$Content,
        [string]$Encoding = 'UTF8'
    )
    try {
        $ps = [powershell]::Create()
        $job = $ps.AddScript({ param($p, $c, $enc)
            $tmp = "$p.tmp"
            Start-Sleep -Milliseconds 200  #  SYNC: Wieksze opoznienie dla synchronizacji z ENGINE
            $bytes = [System.Text.Encoding]::GetEncoding($enc).GetBytes($c)
            [System.IO.File]::WriteAllBytes($tmp, $bytes)
            try { 
                Move-Item -Path $tmp -Destination $p -Force 
            } catch { 
                Copy-Item -Path $tmp -Destination $p -Force
                Start-Sleep -Milliseconds 100
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue 
            }
        }).AddArgument($Path).AddArgument($Content).AddArgument($Encoding)
        $asyncResult = $ps.BeginInvoke()
        # Cleanup job po dluzszym czasie dla background operations
        $null = [System.Threading.Timer]::new({
            param($ps)
            try {
                if ($ps.InvocationStateInfo.State -eq 'Completed' -or $ps.InvocationStateInfo.State -eq 'Failed') {
                    $ps.Dispose()
                }
            } catch { }
        }, $ps, 10000, [System.Threading.Timeout]::Infinite)
    } catch { 
        try { 
            Start-Sleep -Milliseconds 100  # Opoznienie przed fallback
            $Content | Set-Content $Path -Encoding $Encoding -Force 
        } catch { }
    }
}
function Get-Config {
    if (Test-Path $Script:ConfigJsonPath) {
        try { 
            $config = Get-Content $Script:ConfigJsonPath -Raw | ConvertFrom-Json
            # Konwertuj do hashtable dla łatwiejszego modyfikowania
            return ConvertTo-Hashtable $config
        } catch { }
    }
    return $Script:DefaultConfig
}
function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $hash = @{}
            foreach ($key in $InputObject.Keys) {
                $hash[$key] = ConvertTo-Hashtable $InputObject[$key]
            }
            return $hash
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $collection = @()
            foreach ($item in $InputObject) {
                $collection += ConvertTo-Hashtable $item
            }
            return $collection
        }
        if ($InputObject -is [PSObject]) {
            $hash = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $hash[$property.Name] = ConvertTo-Hashtable $property.Value
            }
            return $hash
        }
        return $InputObject
    }
}
function Save-Config {
    param($Config)
    try {
        # Konwertuj PSObject do hashtable na samym początku
        if ($Config -is [PSCustomObject]) {
            $Config = ConvertTo-Hashtable $Config
        }
        
        if ($Script:chkSmartPreload) { $Config.SmartPreload = $Script:chkSmartPreload.Checked }
        if ($Script:chkMemoryCompression) { $Config.MemoryCompression = $Script:chkMemoryCompression.Checked }
        if ($Script:chkPowerBoost) { $Config.PowerBoost = $Script:chkPowerBoost.Checked }
        if ($Script:chkPredictiveIO) { $Config.PredictiveIO = $Script:chkPredictiveIO.Checked }
        if ($Script:trackCPUAggro) { $Config.CPUAgressiveness = $Script:trackCPUAggro.Value }
        if ($Script:trackMemoryAggro) { $Config.MemoryAgressiveness = $Script:trackMemoryAggro.Value }
        if ($Script:trackIOPriority) { $Config.IOPriority = $Script:trackIOPriority.Value }
        # ═══════════════════════════════════════════════════════════════════════════════
        # FIX v40.1: Zachowaj istniejące wartości z config.json, używaj DefaultConfig jako fallback
        # ENGINE odczyta te wartości i zastosuje do Windows
        # ═══════════════════════════════════════════════════════════════════════════════
        # Helper function do bezpiecznego pobierania wartości z fallback
        function Get-ConfigValue($obj, $section, $key, $default) {
            if ($obj -and $obj.$section -and $null -ne $obj.$section.$key) {
                return $obj.$section.$key
            }
            return $default
        }
        
        # Upewnij się że sekcje istnieją
        if (-not $Config.Network) { $Config.Network = @{} }
        if (-not $Config.Privacy) { $Config.Privacy = @{} }
        if (-not $Config.Performance) { $Config.Performance = @{} }
        if (-not $Config.Services) { $Config.Services = @{} }
        
        # Network - zachowaj istniejące wartości lub użyj DefaultConfig jako fallback
        # Podstawowe ustawienia - z checkboxów jeśli istnieją, inaczej z Config lub DefaultConfig
        if ($Script:chkNetworkEnabled) {
            $Config.Network.Enabled = $Script:chkNetworkEnabled.Checked
        } else {
            $Config.Network.Enabled = Get-ConfigValue $Config "Network" "Enabled" $Script:DefaultConfig.Network.Enabled
        }
        if ($Script:chkNetNagle) {
            $Config.Network.DisableNagle = $Script:chkNetNagle.Checked
        } else {
            $Config.Network.DisableNagle = Get-ConfigValue $Config "Network" "DisableNagle" $Script:DefaultConfig.Network.DisableNagle
        }
        if ($Script:chkNetTCP) {
            $Config.Network.OptimizeTCP = $Script:chkNetTCP.Checked
        } else {
            $Config.Network.OptimizeTCP = Get-ConfigValue $Config "Network" "OptimizeTCP" $Script:DefaultConfig.Network.OptimizeTCP
        }
        if ($Script:chkNetDNS) {
            $Config.Network.OptimizeDNS = $Script:chkNetDNS.Checked
        } else {
            $Config.Network.OptimizeDNS = Get-ConfigValue $Config "Network" "OptimizeDNS" $Script:DefaultConfig.Network.OptimizeDNS
        }
        # ULTRA Network Settings
        if ($Script:chkNetMaxBuffers) {
            $Config.Network.MaximizeTCPBuffers = $Script:chkNetMaxBuffers.Checked
        } else {
            $Config.Network.MaximizeTCPBuffers = Get-ConfigValue $Config "Network" "MaximizeTCPBuffers" $Script:DefaultConfig.Network.MaximizeTCPBuffers
        }
        if ($Script:chkNetWindowScaling) {
            $Config.Network.EnableWindowScaling = $Script:chkNetWindowScaling.Checked
        } else {
            $Config.Network.EnableWindowScaling = Get-ConfigValue $Config "Network" "EnableWindowScaling" $Script:DefaultConfig.Network.EnableWindowScaling
        }
        if ($Script:chkNetRSS) {
            $Config.Network.EnableRSS = $Script:chkNetRSS.Checked
        } else {
            $Config.Network.EnableRSS = Get-ConfigValue $Config "Network" "EnableRSS" $Script:DefaultConfig.Network.EnableRSS
        }
        if ($Script:chkNetLSO) {
            $Config.Network.EnableLSO = $Script:chkNetLSO.Checked
        } else {
            $Config.Network.EnableLSO = Get-ConfigValue $Config "Network" "EnableLSO" $Script:DefaultConfig.Network.EnableLSO
        }
        if ($Script:chkNetChimney) {
            $Config.Network.DisableChimney = $Script:chkNetChimney.Checked
        } else {
            $Config.Network.DisableChimney = Get-ConfigValue $Config "Network" "DisableChimney" $Script:DefaultConfig.Network.DisableChimney
        }
        
        # Privacy - zachowaj istniejące wartości lub użyj DefaultConfig
        if ($Script:chkPrivacyEnabled) {
            $Config.Privacy.Enabled = $Script:chkPrivacyEnabled.Checked
        } else {
            $Config.Privacy.Enabled = Get-ConfigValue $Config "Privacy" "Enabled" $Script:DefaultConfig.Privacy.Enabled
        }
        if ($Script:chkPrivacyTelemetry) {
            $Config.Privacy.BlockTelemetry = $Script:chkPrivacyTelemetry.Checked
        } else {
            $Config.Privacy.BlockTelemetry = Get-ConfigValue $Config "Privacy" "BlockTelemetry" $Script:DefaultConfig.Privacy.BlockTelemetry
        }
        if ($Script:chkPrivacyCortana) {
            $Config.Privacy.DisableCortana = $Script:chkPrivacyCortana.Checked
        } else {
            $Config.Privacy.DisableCortana = Get-ConfigValue $Config "Privacy" "DisableCortana" $Script:DefaultConfig.Privacy.DisableCortana
        }
        if ($Script:chkPrivacyLocation) {
            $Config.Privacy.DisableLocation = $Script:chkPrivacyLocation.Checked
        } else {
            $Config.Privacy.DisableLocation = Get-ConfigValue $Config "Privacy" "DisableLocation" $Script:DefaultConfig.Privacy.DisableLocation
        }
        if ($Script:chkPrivacyAds) {
            $Config.Privacy.DisableAds = $Script:chkPrivacyAds.Checked
        } else {
            $Config.Privacy.DisableAds = Get-ConfigValue $Config "Privacy" "DisableAds" $Script:DefaultConfig.Privacy.DisableAds
        }
        if ($Script:chkPrivacyTimeline) {
            $Config.Privacy.DisableTimeline = $Script:chkPrivacyTimeline.Checked
        } else {
            $Config.Privacy.DisableTimeline = Get-ConfigValue $Config "Privacy" "DisableTimeline" $Script:DefaultConfig.Privacy.DisableTimeline
        }
        
        # Performance - zachowaj istniejące wartości lub użyj DefaultConfig
        if ($Script:chkPerfMemory) {
            $Config.Performance.OptimizeMemory = $Script:chkPerfMemory.Checked
        } else {
            $Config.Performance.OptimizeMemory = Get-ConfigValue $Config "Performance" "OptimizeMemory" $Script:DefaultConfig.Performance.OptimizeMemory
        }
        if ($Script:chkPerfFileSystem) {
            $Config.Performance.OptimizeFileSystem = $Script:chkPerfFileSystem.Checked
        } else {
            $Config.Performance.OptimizeFileSystem = Get-ConfigValue $Config "Performance" "OptimizeFileSystem" $Script:DefaultConfig.Performance.OptimizeFileSystem
        }
        if ($Script:chkPerfVisual) {
            $Config.Performance.OptimizeVisualEffects = $Script:chkPerfVisual.Checked
        } else {
            $Config.Performance.OptimizeVisualEffects = Get-ConfigValue $Config "Performance" "OptimizeVisualEffects" $Script:DefaultConfig.Performance.OptimizeVisualEffects
        }
        if ($Script:chkPerfStartup) {
            $Config.Performance.OptimizeStartup = $Script:chkPerfStartup.Checked
        } else {
            $Config.Performance.OptimizeStartup = Get-ConfigValue $Config "Performance" "OptimizeStartup" $Script:DefaultConfig.Performance.OptimizeStartup
        }
        $Config.Performance.OptimizeNetwork = Get-ConfigValue $Config "Performance" "OptimizeNetwork" $Script:DefaultConfig.Performance.OptimizeNetwork
        
        # Services - zachowaj istniejące wartości lub użyj DefaultConfig
        if ($Script:chkSvcFax) {
            $Config.Services.DisableFax = $Script:chkSvcFax.Checked
        } else {
            $Config.Services.DisableFax = Get-ConfigValue $Config "Services" "DisableFax" $Script:DefaultConfig.Services.DisableFax
        }
        if ($Script:chkSvcRemote) {
            $Config.Services.DisableRemoteAccess = $Script:chkSvcRemote.Checked
        } else {
            $Config.Services.DisableRemoteAccess = Get-ConfigValue $Config "Services" "DisableRemoteAccess" $Script:DefaultConfig.Services.DisableRemoteAccess
        }
        if ($Script:chkSvcTablet) {
            $Config.Services.DisableTablet = $Script:chkSvcTablet.Checked
        } else {
            $Config.Services.DisableTablet = Get-ConfigValue $Config "Services" "DisableTablet" $Script:DefaultConfig.Services.DisableTablet
        }
        if ($Script:chkSvcSearch) {
            $Config.Services.DisableSearch = $Script:chkSvcSearch.Checked
        } else {
            $Config.Services.DisableSearch = Get-ConfigValue $Config "Services" "DisableSearch" $Script:DefaultConfig.Services.DisableSearch
        }
        
        # ATOMIC WRITE: tmp -> move (zapobiega "file in use")
        # Konwertuj PSObject do hashtable przed zapisem (fix dla Add-Member)
        $configHash = ConvertTo-Hashtable $Config
        $json = $configHash | ConvertTo-Json -Depth 10
        $tmp = "$($Script:ConfigJsonPath).tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
        try { [System.IO.File]::Move($tmp, $Script:ConfigJsonPath) } 
        catch { [System.IO.File]::Copy($tmp, $Script:ConfigJsonPath, $true); Remove-Item $tmp -Force -EA SilentlyContinue }
        Start-Sleep -Milliseconds 100  #  SYNC: Upewnij sie ze plik jest w pelni zapisany przed sygnalem
        Send-ReloadSignal @{ File = "Config" }
        return $true
    } catch { 
        try { Add-Content -Path "C:\CPUManager\ErrorLog.txt" -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [CONFIGURATOR] Save-Config ERROR: $($_.Exception.Message)" -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
        return $false 
    }
}
function Get-AIEngines {
    if (Test-Path $Script:AIEnginesPath) {
        try {
            $json = Get-Content $Script:AIEnginesPath -Raw | ConvertFrom-Json
            $result = @{}; $json.PSObject.Properties | ForEach-Object { $result[$_.Name] = $_.Value }
            return $result
        } catch { }
    }
    # v40: Pełna lista silników zsynchronizowana z ENGINE
    return @{ 
        QLearning=$true; Ensemble=$false; Prophet=$true; NeuralBrain=$false
        AnomalyDetector=$true; SelfTuner=$true; ChainPredictor=$true; LoadPredictor=$true
        Bandit=$true; Genetic=$true; Energy=$true
    }
}
function Save-AIEngines {
    param($Engines)
    try { 
        #  ATOMIC WRITE: Uzywaj tego samego wzorca dla spojnosci
        $json = $Engines | ConvertTo-Json
        $tmp = "$($Script:AIEnginesPath).tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
        try { [System.IO.File]::Move($tmp, $Script:AIEnginesPath) } 
        catch { [System.IO.File]::Copy($tmp, $Script:AIEnginesPath, $true); Remove-Item $tmp -Force -EA SilentlyContinue }
        Start-Sleep -Milliseconds 100  #  SYNC: Upewnij sie ze plik jest w pelni zapisany
        Send-ReloadSignal @{ File = "AIEngines" }
        return $true 
    } catch { return $false }
}
function Get-TDPConfig {
    if (Test-Path $Script:TDPConfigPath) {
        try {
            $json = Get-Content $Script:TDPConfigPath -Raw | ConvertFrom-Json
            $result = @{}
            foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
                if ($json.$mode) {
                    $result[$mode] = @{
                        STAPM = if ($json.$mode.STAPM) { $json.$mode.STAPM } else { 0 }
                        Fast = if ($json.$mode.Fast) { $json.$mode.Fast } else { 0 }
                        Slow = if ($json.$mode.Slow) { $json.$mode.Slow } else { 0 }
                        Tctl = if ($json.$mode.Tctl) { $json.$mode.Tctl } else { 0 }
                    }
                }
            }
            return $result
        } catch { }
    }
    return $Script:DefaultTDP
}
function Save-TDPConfig {
    param($TDPProfiles)
    try {
        #  ATOMIC WRITE: Uzywaj tego samego wzorca co Config dla spojnosci
        $json = $TDPProfiles | ConvertTo-Json -Depth 3
        $tmp = "$($Script:TDPConfigPath).tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
        try { [System.IO.File]::Move($tmp, $Script:TDPConfigPath) } 
        catch { [System.IO.File]::Copy($tmp, $Script:TDPConfigPath, $true); Remove-Item $tmp -Force -EA SilentlyContinue }
        Start-Sleep -Milliseconds 100  #  SYNC: Upewnij sie ze plik jest w pelni zapisany
        Send-ReloadSignal @{ File = "TDPConfig" }
        return $true
    } catch { return $false }
}
function Clear-RAM {
    $count = 0
    Get-Process | Where-Object { $_.WorkingSet64 -gt 50MB } | ForEach-Object {
        try { [Console.Win32Console]::EmptyWorkingSet($_.Handle) | Out-Null; $count++ } catch { }
    }
    [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
    return $count
}
# #
# SYSTEM OPTIMIZATION FUNCTIONS
# #
function Set-PrivacyOptimizations {
    param([hashtable]$Options)
    $results = @()
    $backupPath = Join-Path $Script:ConfigDir "privacy_backup.json"
    $backup = @{ Timestamp = (Get-Date).ToString('o') }
    try {
        if ($Options.DisableTelemetry) {
            # NAPRAWIONE: Disable telemetry services z timeoutem i job management
            $backup.DiagTrack = Get-ServiceSafe "DiagTrack"
            $backup.dmwappushservice = Get-ServiceSafe "dmwappushservice"
            # Safe Stop-Service z timeoutem i managed job
            $serviceJob = Start-Job -ScriptBlock {
                try {
                    Stop-Service "DiagTrack" -Force -ErrorAction SilentlyContinue
                    Set-Service "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue
                    Stop-Service "dmwappushservice" -Force -ErrorAction SilentlyContinue
                    Set-Service "dmwappushservice" -StartupType Disabled -ErrorAction SilentlyContinue
                } catch { }
            }
            Add-ManagedJob -Job $serviceJob -Description "Telemetry Services"
            $null = Wait-Job -Job $serviceJob -Timeout 3
            Remove-ManagedJob -Job $serviceJob
            # Registry telemetry disable
            $backup.AllowTelemetry = Get-RegistryValueSafe "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry"
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            $results += " Telemetry disabled (DiagTrack, Data Collection)"
        }
        if ($Options.DisableCortana) {
            $backup.AllowCortana = Get-RegistryValueSafe "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana"
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            $results += " Cortana tracking disabled"
        }
        if ($Options.DisableLocation) {
            $backup.DisableLocation = Get-RegistryValueSafe "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" "Value"
            Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Deny" -ErrorAction SilentlyContinue
            $results += " Location services disabled"
        }
        if ($Options.DisableAds) {
            $backup.AdvertisingId = Get-RegistryValueSafe "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled"
            Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            $results += " Advertising ID disabled"
        }
        if ($Options.DisableTimeline) {
            $backup.EnableActivityFeed = Get-RegistryValueSafe "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed"
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            $results += " Timeline & Activity History disabled"
        }
        # Save backup
        $backup | ConvertTo-Json | Set-Content $backupPath -Encoding UTF8 -Force
        $results += " Backup saved to privacy_backup.json"
    } catch {
        $results += "- Error: $($_.Exception.Message)"
    }
    return $results -join "`n"
}
function Set-PerformanceOptimizations {
    param([hashtable]$Options)
    $results = @()
    $backupPath = Join-Path $Script:ConfigDir "performance_backup.json"
    $backup = @{ Timestamp = (Get-Date).ToString('o') }
    try {
        if ($Options.OptimizeMemory) {
            # Memory management optimizations
            $backup.LargeSystemCache = Get-RegistryValueSafe "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "LargeSystemCache"
            $backup.DisablePagingExecutive = Get-RegistryValueSafe "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "DisablePagingExecutive"
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "LargeSystemCache" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "DisablePagingExecutive" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            $results += " Memory management optimized"
        }
        if ($Options.OptimizeFileSystem) {
            $backup.NtfsDisableLastAccessUpdate = Get-RegistryValueSafe "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "NtfsDisableLastAccessUpdate"
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "NtfsDisableLastAccessUpdate" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            $results += " File system optimized"
        }
        if ($Options.OptimizeVisual) {
            # Visual effects optimization
            $backup.UserPreferencesMask = Get-RegistryValueSafe "HKCU:\Control Panel\Desktop" "UserPreferencesMask"
            $backup.MenuShowDelay = Get-RegistryValueSafe "HKCU:\Control Panel\Desktop" "MenuShowDelay"
            Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value 0 -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "DragFullWindows" -Value 0 -ErrorAction SilentlyContinue
            $results += " Visual effects optimized"
        }
        if ($Options.OptimizeInput) {
            # Input latency optimization
            $backup.MouseSpeed = Get-RegistryValueSafe "HKCU:\Control Panel\Mouse" "MouseSpeed"
            $backup.MouseThreshold1 = Get-RegistryValueSafe "HKCU:\Control Panel\Mouse" "MouseThreshold1"
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value 0 -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value 0 -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value 0 -ErrorAction SilentlyContinue
            $results += " Input latency optimized"
        }
        if ($Options.OptimizeScheduling) {
            # CPU scheduling optimization
            $backup.Win32PrioritySeparation = Get-RegistryValueSafe "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation"
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name "Win32PrioritySeparation" -Value 38 -Type DWord -Force -ErrorAction SilentlyContinue
            $results += " CPU scheduling optimized"
        }
        # Save backup
        $backup | ConvertTo-Json | Set-Content $backupPath -Encoding UTF8 -Force
        $results += " Backup saved to performance_backup.json"
    } catch {
        $results += "- Error: $($_.Exception.Message)"
    }
    return $results -join "`n"
}
function Set-ServicesOptimizations {
    param([hashtable]$Options)
    $results = @()
    $backupPath = Join-Path $Script:ConfigDir "services_backup.json"
    $backup = @{ Timestamp = (Get-Date).ToString('o'); Services = @{} }
    try {
        if ($Options.DisableSearchIndexer) {
            $service = Get-Service "WSearch" -ErrorAction SilentlyContinue
            if ($service) {
                $backup.Services.WSearch = $service.StartType
                # NAPRAWIONE: Safe stop z timeoutem
                $searchJob = Start-Job -ScriptBlock {
                    try {
                        Stop-Service "WSearch" -Force -ErrorAction SilentlyContinue
                        Set-Service "WSearch" -StartupType Disabled -ErrorAction SilentlyContinue
                    } catch { }
                }
                $null = Wait-Job -Job $searchJob -Timeout 5
                Remove-Job -Job $searchJob -Force -ErrorAction SilentlyContinue
                $results += " Windows Search Indexer disabled"
            }
        }
        if ($Options.DisableFax) {
            $services = @("Fax", "Spooler")
            # NAPRAWIONE: Safe stop services z timeoutem
            $faxJob = Start-Job -ScriptBlock {
                param($ServiceNames)
                try {
                    foreach ($svcName in $ServiceNames) {
                        $service = Get-Service $svcName -ErrorAction SilentlyContinue
                        if ($service) {
                            Stop-Service $svcName -Force -ErrorAction SilentlyContinue
                            Set-Service $svcName -StartupType Disabled -ErrorAction SilentlyContinue
                        }
                    }
                } catch { }
            } -ArgumentList (,$services)
            $null = Wait-Job -Job $faxJob -Timeout 4
            Remove-Job -Job $faxJob -Force -ErrorAction SilentlyContinue
            foreach ($svcName in $services) {
                $service = Get-Service $svcName -ErrorAction SilentlyContinue
                if ($service) {
                    $backup.Services.$svcName = $service.StartType
                }
            }
            $results += " Fax & Print Spooler disabled"
        }
        if ($Options.DisableRemote) {
            $services = @("RemoteRegistry", "RemoteAccess", "RasMan")
            # NAPRAWIONE: Safe stop remote services z timeoutem
            $remoteJob = Start-Job -ScriptBlock {
                param($ServiceNames)
                try {
                    foreach ($svcName in $ServiceNames) {
                        $service = Get-Service $svcName -ErrorAction SilentlyContinue
                        if ($service) {
                            Stop-Service $svcName -Force -ErrorAction SilentlyContinue
                            Set-Service $svcName -StartupType Disabled -ErrorAction SilentlyContinue
                        }
                    }
                } catch { }
            } -ArgumentList (,$services)
            $null = Wait-Job -Job $remoteJob -Timeout 4
            Remove-Job -Job $remoteJob -Force -ErrorAction SilentlyContinue
            foreach ($svcName in $services) {
                $service = Get-Service $svcName -ErrorAction SilentlyContinue
                if ($service) {
                    $backup.Services.$svcName = $service.StartType
                }
            }
            $results += " Remote services disabled"
        }
        if ($Options.DisableTablet) {
            # NAPRAWIONE: Touch services z timeoutem
            $services = @("TabletInputService", "TouchKeyboard", "Wisvc")
            $touchJob = Start-Job -ScriptBlock {
                param($ServiceNames)
                try {
                    foreach ($svcName in $ServiceNames) {
                        $service = Get-Service $svcName -ErrorAction SilentlyContinue
                        if ($service) {
                            Stop-Service $svcName -Force -ErrorAction SilentlyContinue
                            Set-Service $svcName -StartupType Disabled -ErrorAction SilentlyContinue
                        }
                    }
                } catch { }
            } -ArgumentList (,$services)
            $null = Wait-Job -Job $touchJob -Timeout 4
            Remove-Job -Job $touchJob -Force -ErrorAction SilentlyContinue
            $results += " Tablet/Touch services disabled"
        }
        if ($Options.DisableCompat) {
            $service = Get-Service "PcaSvc" -ErrorAction SilentlyContinue
            if ($service) {
                $backup.Services.PcaSvc = $service.StartType
                # NAPRAWIONE: Safe stop z timeoutem
                $pcaJob = Start-Job -ScriptBlock {
                    try {
                        Stop-Service "PcaSvc" -Force -ErrorAction SilentlyContinue
                        Set-Service "PcaSvc" -StartupType Disabled -ErrorAction SilentlyContinue
                    } catch { }
                }
                $null = Wait-Job -Job $pcaJob -Timeout 3
                Remove-Job -Job $pcaJob -Force -ErrorAction SilentlyContinue
                $results += " Program Compatibility Assistant disabled"
            }
        }
        # Save backup
        $backup | ConvertTo-Json | Set-Content $backupPath -Encoding UTF8 -Force
        $results += " Backup saved to services_backup.json"
    } catch {
        $results += "- Error: $($_.Exception.Message)"
    }
    return $results -join "`n"
}
function Set-StorageOptimizations {
    param([hashtable]$Options)
    $results = @()
    # NAPRAWIONE: Dodanie ogolnego error handling
    try {
        if ($Options.CleanupTemp) {
            try {
                $tempFolders = @(
                    $env:TEMP,
                    "$env:LOCALAPPDATA\Temp",
                    "$env:WINDIR\Temp",
                    "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
                    "$env:APPDATA\Mozilla\Firefox\Profiles\*\cache*"
                )
                $totalCleaned = 0
                foreach ($folder in $tempFolders) {
                    if (Test-Path $folder) {
                        try {
                            $items = Get-ChildItem $folder -Recurse -File -ErrorAction SilentlyContinue
                            if ($items) {
                                $size = ($items | Measure-Object -Property Length -Sum).Sum / 1MB
                                Remove-Item "$folder\*" -Recurse -Force -ErrorAction SilentlyContinue
                                $totalCleaned += $size
                            }
                        } catch { 
                            # Skip folder if access denied
                        }
                    }
                }
                $results += " Temp files cleaned: $([Math]::Round($totalCleaned, 1)) MB"
            } catch {
                $results += "[WARN] Temp cleanup error: $($_.Exception.Message)"
            }
        }
        if ($Options.CleanupLogs) {
            try {
                $logPaths = @(
                    "$env:WINDIR\System32\winevt\Logs",
                    "$env:WINDIR\Logs"
                )
                # NAPRAWIONE: Safe log cleanup z lepszym error handling
                $logCleanupJob = Start-Job -ScriptBlock {
                    param($LogPaths)
                    $cleaned = 0
                    try {
                        foreach ($logPath in $LogPaths) {
                            if (Test-Path $logPath) {
                                try {
                                    $items = Get-ChildItem $logPath -ErrorAction SilentlyContinue | 
                                            Where-Object { $_.Name -notlike "*Error*" -and $_.Name -notlike "*Critical*" }
                                    foreach ($item in $items) {
                                        try {
                                            Remove-Item $item.FullName -Force -ErrorAction SilentlyContinue
                                            $cleaned++
                                        } catch { 
                                            # Skip file if access denied
                                        }
                                    }
                                } catch {
                                    # Skip folder if access denied
                                }
                            }
                        }
                    } catch { }
                    return $cleaned
                } -ArgumentList (,$logPaths)
                # NAPRAWIONE: Non-blocking wait z fallback
                $jobResult = $null
                try {
                    $jobResult = Wait-Job -Job $logCleanupJob -Timeout 6 -ErrorAction SilentlyContinue
                    if ($jobResult) {
                        $cleanedCount = Receive-Job -Job $logCleanupJob -ErrorAction SilentlyContinue
                        if ($cleanedCount -gt 0) {
                            $results += " Windows logs cleaned ($cleanedCount files, errors preserved)"
                        } else {
                            $results += " Windows logs checked (no files to clean)"
                        }
                    } else {
                        # Job timeout or blocked
                        $results += "[WARN] Log cleanup timeout (may need admin permissions)"
                    }
                } catch {
                    $results += "[WARN] Log cleanup skipped (access permissions)"
                } finally {
                    # ZAWSZE usun job
                    Remove-Job -Job $logCleanupJob -Force -ErrorAction SilentlyContinue
                }
            } catch {
                $results += "[WARN] Log cleanup error: $($_.Exception.Message)"
            }
        }
        if ($Options.CleanupUpdates) {
            try {
                $updatePaths = @(
                    "$env:WINDIR\SoftwareDistribution\Download",
                    "$env:WINDIR\System32\catroot2"
                )
                # NAPRAWIONE: Safe update cleanup z timeoutem
                $updateCleanupJob = Start-Job -ScriptBlock {
                    param($UpdatePaths)
                    try {
                        foreach ($updatePath in $UpdatePaths) {
                            if (Test-Path $updatePath) {
                                Remove-Item "$updatePath\*" -Recurse -Force -ErrorAction SilentlyContinue
                            }
                        }
                    } catch { }
                } -ArgumentList (,$updatePaths)
                $null = Wait-Job -Job $updateCleanupJob -Timeout 8
                Remove-Job -Job $updateCleanupJob -Force -ErrorAction SilentlyContinue
                $results += " Windows Update files cleaned"
            } catch {
                $results += "[WARN] Update cleanup error: $($_.Exception.Message)"
            }
        }
        if ($Options.RebuildCache) {
            try {
                # NAPRAWIONE: Bezpieczne przebudowanie cache bez zatrzymywania explorer
                Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
                # NAPRAWIONE: Font cache z timeout
                $fontCacheService = Get-Service "FontCache" -ErrorAction SilentlyContinue
                if ($fontCacheService -and $fontCacheService.Status -eq "Running") {
                    # Safe stop z timeoutem
                    $fontJob = Start-Job -ScriptBlock {
                        try {
                            Stop-Service "FontCache" -Force -ErrorAction SilentlyContinue
                            Start-Sleep 1
                            Remove-Item "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache\*" -Force -ErrorAction SilentlyContinue
                            Start-Service "FontCache" -ErrorAction SilentlyContinue
                        } catch { }
                    }
                    $null = Wait-Job -Job $fontJob -Timeout 5
                    Remove-Job -Job $fontJob -Force -ErrorAction SilentlyContinue
                }
                # NAPRAWIONE: Odswiezenie explorer bez restart
                # Uzywamy rundll32 zamiast kill explorer
                rundll32.exe user32.dll,UpdatePerUserSystemParameters
                $results += " Icon & Font cache rebuilt (safe method)"
            } catch {
                $results += "[WARN] Cache rebuild skipped: $($_.Exception.Message)"
            }
        }
        if ($Options.OptimizeSSD) {
            try {
                # NAPRAWIONE: Bezpieczna optymalizacja SSD z error handling
                # Enable TRIM - tylko jesli system obsluguje
                $trimResult = fsutil behavior query DisableDeleteNotify 2>$null
                if ($trimResult) {
                    fsutil behavior set DisableDeleteNotify 0 | Out-Null
                    $results += " SSD TRIM enabled"
                }
                # Disable defragmentation - bezpiecznie
                try {
                    $defragTask = schtasks /Query /TN "Microsoft\Windows\Defrag\ScheduledDefrag" 2>$null
                    if ($defragTask -and $LASTEXITCODE -eq 0) {
                        schtasks /Change /TN "Microsoft\Windows\Defrag\ScheduledDefrag" /Disable | Out-Null
                        $results += " Defrag disabled for SSD"
                    }
                } catch {
                    $results += "[WARN] Defrag task not found or already disabled"
                }
            } catch {
                $results += "[WARN] SSD optimization error: $($_.Exception.Message)"
            }
        }
    } catch {
        $results += "- Error: $($_.Exception.Message)"
    }
    return $results -join "`n"
}
# #
# FUNKCJE - BEZPIECZNY ODCZYT DANYCH (NULL-SAFE)
# #
function Get-SafeValue { param($Data, [string]$Property, $Default = $null)
    try { $val = $Data.PSObject.Properties[$Property]; if ($null -eq $val -or $null -eq $val.Value) { return $Default }; return $val.Value } catch { return $Default }
}
function Get-SafeInt { param($Data, [string]$Property, [int]$Default = 0)
    $val = Get-SafeValue -Data $Data -Property $Property -Default $Default; try { return [int]$val } catch { return $Default }
}
function Get-SafeInt64 { param($Data, [string]$Property, [int64]$Default = 0)
    $val = Get-SafeValue -Data $Data -Property $Property -Default $Default; try { return [int64]$val } catch { return $Default }
}
function Safe-GetDouble { param($Data, [string]$Property, [double]$Default = 0.0)
    $val = Get-SafeValue -Data $Data -Property $Property -Default $Default; try { return [double]$val } catch { return $Default }
}
function Get-SafeString { param($Data, [string]$Property, [string]$Default = "---")
    $val = Get-SafeValue -Data $Data -Property $Property -Default $Default; if ([string]::IsNullOrWhiteSpace($val)) { return $Default }; return $val.ToString()
}
function Get-SafeBool { param($Data, [string]$Property, [bool]$Default = $false)
    $val = Get-SafeValue -Data $Data -Property $Property -Default $Default; try { return [bool]$val } catch { return $Default }
}
# Funkcja pomocnicza do odczytywania plikow konfiguracyjnych z fallback
function Read-ConfigFile { param([string]$FileName)
    try {
        $path = Join-Path $Script:ConfigDir "$FileName.json"
        $fallbackPath = Join-Path $Script:ConfigDir $FileName
        if (Test-Path $path) {
            return Get-Content $path -Raw | ConvertFrom-Json
        } elseif (Test-Path $fallbackPath) {
            return Get-Content $fallbackPath -Raw | ConvertFrom-Json
        }
        return $null
    } catch {
        return $null
    }
}
# Funkcja pomocnicza do odczytywania klucza rejestru
function Get-RegistryValueSafe { param([string]$Path, [string]$Name)
    try {
        $regItem = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        return if ($regItem) { $regItem.$Name } else { $null }
    } catch {
        return $null
    }
}
# Funkcja pomocnicza do odczytywania uslugi
function Get-ServiceSafe { param([string]$ServiceName)
    try {
        $service = Get-Service $ServiceName -ErrorAction SilentlyContinue
        return if ($service) { $service.StartType } else { $null }
    } catch {
        return $null
    }
}
# #
# FUNKCJE - FORMATOWANIE
# #
function Format-Speed { param($BytesPerSec)
    if ($null -eq $BytesPerSec -or $BytesPerSec -eq 0) { return "0 B/s" }
    $val = [double]$BytesPerSec
    if ($val -ge 1MB) { return "{0:N1} MB/s" -f ($val / 1MB) }
    if ($val -ge 1KB) { return "{0:N0} KB/s" -f ($val / 1KB) }
    return "{0:N0} B/s" -f $val
}
function Format-Bytes { param($Bytes)
    if ($null -eq $Bytes -or $Bytes -eq 0) { return "0 B" }
    $val = [double]$Bytes
    if ($val -ge 1GB) { return "{0:N2} GB" -f ($val / 1GB) }
    if ($val -ge 1MB) { return "{0:N1} MB" -f ($val / 1MB) }
    if ($val -ge 1KB) { return "{0:N0} KB" -f ($val / 1KB) }
    return "{0:N0} B" -f $val
}
function Get-ModeColor { param([string]$Mode)
    switch ($Mode) { "Silent" { return $Script:Colors.Silent } "Balanced" { return $Script:Colors.Balanced } 
                     "Turbo" { return $Script:Colors.Turbo } "Extreme" { return $Script:Colors.Extreme } default { return $Script:Colors.Text } }
}
function Get-TempColor { param([int]$Temp)
    if ($Temp -gt 85) { return $Script:Colors.Danger } elseif ($Temp -gt 75) { return $Script:Colors.Warning }
    elseif ($Temp -gt 65) { return $Script:Colors.Balanced } else { return $Script:Colors.Success }
}
function Update-NetworkStats {
    # WMI jest wywolywane asynchronicznie w BackgroundWMIJob
    try {
        $currentTime = [DateTime]::Now
        $timeDiff = ($currentTime - $Script:LastNetTime).TotalSeconds
        # Dane sa juz w $Script:LiveNetDL i $Script:LiveNetUL (ustawiane przez BackgroundWMIJob)
        if ($Script:LiveNetDL -gt 0 -or $Script:LiveNetUL -gt 0) {
            $currentRecvRate = $Script:LiveNetDL
            $currentSentRate = $Script:LiveNetUL
            # Pierwsze wywolanie - tylko ustaw baseline, nie licz Session
            if (-not $Script:NetStatsInitialized) {
                $Script:NetStatsInitialized = $true
                $Script:LastNetTime = $currentTime
                return
            }
            # Sumuj do sesyjnego total (bytes = rate * time)
            # Tylko jesli timeDiff jest rozsadny (0.1s - 5s)
            if ($timeDiff -gt 0.1 -and $timeDiff -lt 5) {
                $bytesRecvThisInterval = [int64]($currentRecvRate * $timeDiff)
                $bytesSentThisInterval = [int64]($currentSentRate * $timeDiff)
                if ($bytesRecvThisInterval -gt 0) { $Script:SessionNetDL += $bytesRecvThisInterval }
                if ($bytesSentThisInterval -gt 0) { $Script:SessionNetUL += $bytesSentThisInterval }
            }
        }
        $Script:LastNetTime = $currentTime
    } catch {
        # Silent fail
    }
}
# #
# FUNKCJE - WYKRESY
# #
function Show-Chart {
    param([System.Windows.Forms.PictureBox]$PictureBox, [System.Collections.Generic.List[double]]$Data,
          [System.Drawing.Color]$LineColor, [int]$MinVal = 0, [int]$MaxVal = 100, [string]$Unit = "")
    if ($null -eq $PictureBox -or $Data.Count -lt 2) { return }
    $w = $PictureBox.Width; $h = $PictureBox.Height
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($Script:Colors.Panel)
    # Grid
    $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 255, 255, 255), 1)
    for ($i = 0; $i -le 4; $i++) { $y = [int]($h * $i / 4); $g.DrawLine($gridPen, 0, $y, $w, $y) }
    # Data line
    $pen = New-Object System.Drawing.Pen($LineColor, 2)
    $points = [System.Collections.Generic.List[System.Drawing.Point]]::new()
    $range = $MaxVal - $MinVal; if ($range -eq 0) { $range = 1 }
    for ($i = 0; $i -lt $Data.Count; $i++) {
        $x = [int]($w * $i / [Math]::Max(1, $Data.Count - 1))
        $y = [int]($h - ($h * ($Data[$i] - $MinVal) / $range))
        $y = [Math]::Max(0, [Math]::Min($h - 1, $y))
        $points.Add((New-Object System.Drawing.Point($x, $y)))
    }
    if ($points.Count -gt 1) { $g.DrawLines($pen, $points.ToArray()) }
    # Current value
    if ($Data.Count -gt 0) {
        $lastVal = $Data[$Data.Count - 1]
        $font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $g.DrawString("$([int]$lastVal)$Unit", $font, (New-Object System.Drawing.SolidBrush($LineColor)), 5, 5)
        $font.Dispose()
    }
    $pen.Dispose(); $gridPen.Dispose(); $g.Dispose()
    if ($PictureBox.Image) { $PictureBox.Image.Dispose() }
    $PictureBox.Image = $bmp
}
function Show-DualChart {
    param(
        [System.Windows.Forms.PictureBox]$PictureBox,
        [System.Collections.Generic.List[double]]$Data1,
        [System.Collections.Generic.List[double]]$Data2,
        [System.Drawing.Color]$Color1,
        [System.Drawing.Color]$Color2,
        [string]$Label1 = "",
        [string]$Label2 = "",
        [int]$MinVal = 0,
        [int]$MaxVal = 100,
        [string]$Unit = ""
    )
    if ($null -eq $PictureBox -or ($Data1.Count -lt 2 -and $Data2.Count -lt 2)) { return }
    $w = $PictureBox.Width; $h = $PictureBox.Height
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($Script:Colors.Panel)
    # Grid
    $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 255, 255, 255), 1)
    for ($i = 0; $i -le 4; $i++) { 
        $y = [int]($h * $i / 4)
        $g.DrawLine($gridPen, 0, $y, $w, $y)
    }
    # Helper function to draw line
    $drawLine = {
        param($data, $color)
        if ($data.Count -lt 2) { return }
        $pen = New-Object System.Drawing.Pen($color, 2)
        $points = [System.Collections.Generic.List[System.Drawing.Point]]::new()
        $range = $MaxVal - $MinVal; if ($range -eq 0) { $range = 1 }
        for ($i = 0; $i -lt $data.Count; $i++) {
            $x = [int]($w * $i / [Math]::Max(1, $data.Count - 1))
            $y = [int]($h - ($h * ($data[$i] - $MinVal) / $range))
            $y = [Math]::Max(0, [Math]::Min($h - 1, $y))
            $points.Add((New-Object System.Drawing.Point($x, $y)))
        }
        if ($points.Count -gt 1) { $g.DrawLines($pen, $points.ToArray()) }
        $pen.Dispose()
    }
    # Draw both lines
    & $drawLine $Data1 $Color1
    & $drawLine $Data2 $Color2
    # Legend with current values
    $font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $yOffset = 5
    if ($Data1.Count -gt 0) {
        $val1 = $Data1[$Data1.Count - 1]
        $text1 = "$Label1 $([Math]::Round($val1, 1))$Unit"
        $g.DrawString($text1, $font, (New-Object System.Drawing.SolidBrush($Color1)), 5, $yOffset)
        $yOffset += 18
    }
    if ($Data2.Count -gt 0) {
        $val2 = $Data2[$Data2.Count - 1]
        $text2 = "$Label2 $([Math]::Round($val2, 1))$Unit"
        $g.DrawString($text2, $font, (New-Object System.Drawing.SolidBrush($Color2)), 5, $yOffset)
    }
    $font.Dispose(); $gridPen.Dispose(); $g.Dispose()
    if ($PictureBox.Image) { $PictureBox.Image.Dispose() }
    $PictureBox.Image = $bmp
}
# #
# #
function Show-NetworkAIHourlyChart {
    param(
        [System.Windows.Forms.PictureBox]$PictureBox,
        [hashtable]$HourlyData
    )
    if ($null -eq $PictureBox) { return }
    $w = $PictureBox.Width
    $h = $PictureBox.Height
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($Script:Colors.Panel)
    # Margines dla etykiet
    $marginBottom = 18
    $marginLeft = 5
    $chartHeight = $h - $marginBottom - 5
    $chartWidth = $w - $marginLeft - 5
    $barWidth = [Math]::Floor($chartWidth / 24) - 1
    # Siatka pozioma (3 linie)
    $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 255, 255, 255), 1)
    for ($i = 1; $i -le 3; $i++) {
        $y = [int](5 + $chartHeight * $i / 4)
        $g.DrawLine($gridPen, $marginLeft, $y, $w - 5, $y)
    }
    # Rysuj slupki dla kazdej godziny
    $currentHour = (Get-Date).Hour
    for ($hour = 0; $hour -lt 24; $hour++) {
        $probability = 0
        # Pobierz prawdopodobienstwo gamingu dla tej godziny
        if ($HourlyData -and $HourlyData.ContainsKey($hour.ToString())) {
            $hourData = $HourlyData[$hour.ToString()]
            if ($hourData.GamingProbability) {
                $probability = [Math]::Min(1.0, [double]$hourData.GamingProbability)
            }
        }
        $x = $marginLeft + ($hour * ($barWidth + 1))
        $barHeight = [int]($chartHeight * $probability)
        $y = 5 + $chartHeight - $barHeight
        # Kolor slupka - gradient od zielonego (niski) do czerwonego (wysoki)
        if ($probability -gt 0.5) {
            $r = 255
            $green = [int](255 * (1 - ($probability - 0.5) * 2))
            $barColor = [System.Drawing.Color]::FromArgb(200, $r, $green, 50)
        } elseif ($probability -gt 0.2) {
            $green = [int](150 + 105 * ($probability / 0.5))
            $barColor = [System.Drawing.Color]::FromArgb(200, 100, $green, 50)
        } else {
            $barColor = [System.Drawing.Color]::FromArgb(100, 50, 150, 50)
        }
        # Podswietl aktualna godzine
        if ($hour -eq $currentHour) {
            $barColor = [System.Drawing.Color]::FromArgb(255, 0, 200, 255)
        }
        # Rysuj slupek
        if ($barHeight -gt 0) {
            $brush = New-Object System.Drawing.SolidBrush($barColor)
            $g.FillRectangle($brush, $x, $y, $barWidth, $barHeight)
            $brush.Dispose()
        }
        # Minimalna wysokosc dla widocznosci
        if ($barHeight -lt 2 -and $probability -gt 0) {
            $minBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(100, 100, 100, 100))
            $g.FillRectangle($minBrush, $x, 5 + $chartHeight - 2, $barWidth, 2)
            $minBrush.Dispose()
        }
    }
    # Etykiety godzin (co 4 godziny)
    $font = New-Object System.Drawing.Font("Segoe UI", 7)
    $fontBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 150, 150))
    for ($hour = 0; $hour -lt 24; $hour += 4) {
        $x = $marginLeft + ($hour * ($barWidth + 1))
        $g.DrawString($hour.ToString(), $font, $fontBrush, $x, $h - $marginBottom + 2)
    }
    # Ostatnia etykieta "24"
    $g.DrawString("24", $font, $fontBrush, $w - 15, $h - $marginBottom + 2)
    $font.Dispose()
    $fontBrush.Dispose()
    $gridPen.Dispose()
    $g.Dispose()
    if ($PictureBox.Image) { $PictureBox.Image.Dispose() }
    $PictureBox.Image = $bmp
}
# #
# #
function Update-NetworkAI {
    $networkAIPath = Join-Path $Script:ConfigDir "NetworkAI.json"
    try {
        if (Test-Path $networkAIPath) {
            $networkAI = Get-Content $networkAIPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            # Aktualizuj dane w pamieci
            $Script:NetworkAIData.AppsLearned = 0
            $Script:NetworkAIData.TotalPredictions = if ($networkAI.TotalPredictions) { $networkAI.TotalPredictions } else { 0 }
            $Script:NetworkAIData.QStates = 0
            # Policz nauczone aplikacje
            if ($networkAI.AppNetworkProfiles) {
                $Script:NetworkAIData.AppsLearned = ($networkAI.AppNetworkProfiles.PSObject.Properties | Measure-Object).Count
                $Script:NetworkAIData.AppProfiles = $networkAI.AppNetworkProfiles
            }
            # Policz Q-States
            if ($networkAI.NetworkQTable) {
                $Script:NetworkAIData.QStates = ($networkAI.NetworkQTable.PSObject.Properties | Measure-Object).Count
            }
            # Oblicz accuracy
            $correct = if ($networkAI.CorrectPredictions) { $networkAI.CorrectPredictions } else { 0 }
            $total = if ($networkAI.TotalPredictions) { $networkAI.TotalPredictions } else { 0 }
            $Script:NetworkAIData.Accuracy = if ($total -gt 0) { [Math]::Round(($correct / $total) * 100, 1) } else { 0 }
            # Zapisz wzorce godzinowe
            if ($networkAI.HourlyNetworkPatterns) {
                $Script:NetworkAIData.HourlyPatterns = @{}
                $networkAI.HourlyNetworkPatterns.PSObject.Properties | ForEach-Object {
                    $Script:NetworkAIData.HourlyPatterns[$_.Name] = $_.Value
                }
            }
            # Aktualizuj etykiety
            $Script:lblNetAIApps.Text = "Apps Learned:   $($Script:NetworkAIData.AppsLearned)"
            $Script:lblNetAIAccuracy.Text = "Accuracy:       $($Script:NetworkAIData.Accuracy)%"
            $Script:lblNetAIPredictions.Text = "Predictions:    $($Script:NetworkAIData.TotalPredictions)"
            $Script:lblNetAIQStates.Text = "Q-Table States: $($Script:NetworkAIData.QStates)"
            # Znajdz szczytowe godziny gamingu
            $peakHours = @()
            $maxProb = 0
            if ($Script:NetworkAIData.HourlyPatterns.Count -gt 0) {
                foreach ($hourKey in $Script:NetworkAIData.HourlyPatterns.Keys) {
                    $hourData = $Script:NetworkAIData.HourlyPatterns[$hourKey]
                    if ($hourData.GamingProbability -and [double]$hourData.GamingProbability -gt 0.3) {
                        $peakHours += [int]$hourKey
                        if ([double]$hourData.GamingProbability -gt $maxProb) {
                            $maxProb = [double]$hourData.GamingProbability
                        }
                    }
                }
            }
            if ($peakHours.Count -gt 0) {
                $peakHours = $peakHours | Sort-Object
                $peakStart = $peakHours[0]
                $peakEnd = $peakHours[-1]
                $Script:lblNetAIPeak.Text = "Peak Gaming: ${peakStart}:00-${peakEnd}:00 ($([Math]::Round($maxProb * 100))%)"
            } else {
                $Script:lblNetAIPeak.Text = "Peak: Learning..."
            }
            # Rysuj wykres hourly patterns
            Show-NetworkAIHourlyChart -PictureBox $Script:picNetAIHourly -HourlyData $Script:NetworkAIData.HourlyPatterns
            # Aktualizuj Top Apps
            Update-NetworkAITopApps
        } else {
            # Brak pliku - pokaz domyslne wartosci
            $Script:lblNetAIApps.Text = "Apps Learned:   0"
            $Script:lblNetAIAccuracy.Text = "Accuracy:       --%"
            $Script:lblNetAIPredictions.Text = "Predictions:    0"
            $Script:lblNetAIQStates.Text = "Q-Table States: 0"
            $Script:lblNetAIPeak.Text = "Peak: No data yet"
        }
    } catch {
        # Blad odczytu - zachowaj poprzednie wartosci
    }
    # Aktualizuj status z WidgetData.json (dane real-time)
    Update-NetworkAIStatus
}
function Update-NetworkAIStatus {
    # Odczytaj aktualny status z WidgetData.json lub NetworkOptimizer.json
    $networkOptPath = Join-Path $Script:ConfigDir "NetworkOptimizer.json"
    try {
        if (Test-Path $networkOptPath) {
            $netOpt = Get-Content $networkOptPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $mode = if ($netOpt.CurrentMode) { $netOpt.CurrentMode } else { "Normal" }
            $Script:lblNetAIMode.Text = "Current Mode:   $mode"
            # Ustaw kolor wedlug trybu
            $Script:lblNetAIMode.ForeColor = switch ($mode) {
                "Gaming" { [System.Drawing.Color]::FromArgb(255, 100, 100) }
                "Download" { [System.Drawing.Color]::FromArgb(100, 200, 255) }
                "Streaming" { [System.Drawing.Color]::FromArgb(200, 100, 255) }
                "VoIP" { [System.Drawing.Color]::FromArgb(255, 200, 100) }
                default { [System.Drawing.Color]::FromArgb(100, 255, 150) }
            }
            # Optymalizacje status
            $dnsOk = if ($netOpt.DNSOptimized) { "[OK]" } else { "[NO]" }
            $nagleOk = if ($netOpt.NagleDisabled) { "[OK]" } else { "[NO]" }
            $tcpOk = if ($netOpt.TCPOptimized) { "[OK]" } else { "[NO]" }
            $Script:lblNetAIPrediction.Text = "Optimizations:  DNS:$dnsOk Nagle:$nagleOk TCP:$tcpOk"
        }
    } catch { }
    # Aktualizuj confidence i app type z ostatniej aktywnej aplikacji
    try {
        if ($Script:NetworkAIData.AppProfiles -and ($Script:NetworkAIData.AppProfiles.PSObject.Properties | Measure-Object).Count -gt 0) {
            $lastApp = ""
            $lastType = "Unknown"
            $maxSessions = 0
            # Lista wykluczonych aplikacji
            $excludedApps = @("desktop", "explorer", "dwm", "csrss", "svchost", "system", "idle", "shellexperiencehost", "searchhost", "startmenuexperiencehost", "applicationframehost")
            foreach ($prop in $Script:NetworkAIData.AppProfiles.PSObject.Properties) {
                $appName = $prop.Name.ToLower()
                # Pomin wykluczone aplikacje
                if ($excludedApps -contains $appName) { continue }
                $app = $prop.Value
                if ($app.Sessions -and [int]$app.Sessions -gt $maxSessions) {
                    $maxSessions = [int]$app.Sessions
                    $lastApp = $prop.Name
                    $lastType = if ($app.Type) { $app.Type } else { "Unknown" }
                }
            }
            if ($lastApp) {
                $Script:lblNetAIAppType.Text = "Top App:        $lastApp ($lastType)"
                $Script:lblNetAIConfidence.Text = "Sessions:       $maxSessions"
            }
        }
    } catch { }
}
function Update-NetworkAITopApps {
    try {
        if ($Script:NetworkAIData.AppProfiles -and ($Script:NetworkAIData.AppProfiles.PSObject.Properties | Measure-Object).Count -gt 0) {
            $sortedApps = [System.Collections.Generic.List[hashtable]]::new()
            # Lista wykluczonych aplikacji (systemowe, zawsze aktywne)
            $excludedApps = @("desktop", "explorer", "dwm", "csrss", "svchost", "system", "idle", "shellexperiencehost", "searchhost", "startmenuexperiencehost", "applicationframehost")
            foreach ($prop in $Script:NetworkAIData.AppProfiles.PSObject.Properties) {
                $appName = $prop.Name.ToLower()
                # Pomin wykluczone aplikacje
                if ($excludedApps -contains $appName) { continue }
                $appData = @{
                    Name = $prop.Name
                    Type = if ($prop.Value.Type) { $prop.Value.Type } else { "Unknown" }
                    Sessions = if ($prop.Value.Sessions) { [int]$prop.Value.Sessions } else { 0 }
                }
                $sortedApps.Add($appData)
            }
            $sortedApps = $sortedApps | Sort-Object -Property Sessions -Descending | Select-Object -First 5
            $sortedArray = @($sortedApps)
            # Etykieta 1
            if ($sortedArray.Count -ge 1) {
                $Script:lblNetAIApp1.Text = "1. $($sortedArray[0].Name) ($($sortedArray[0].Sessions)) - $($sortedArray[0].Type)"
            } else {
                $Script:lblNetAIApp1.Text = "1. --"
            }
            # Etykieta 2
            if ($sortedArray.Count -ge 2) {
                $Script:lblNetAIApp2.Text = "2. $($sortedArray[1].Name) ($($sortedArray[1].Sessions)) - $($sortedArray[1].Type)"
            } else {
                $Script:lblNetAIApp2.Text = "2. --"
            }
            # Etykieta 3
            if ($sortedArray.Count -ge 3) {
                $Script:lblNetAIApp3.Text = "3. $($sortedArray[2].Name) ($($sortedArray[2].Sessions)) - $($sortedArray[2].Type)"
            } else {
                $Script:lblNetAIApp3.Text = "3. --"
            }
            # Etykieta 4
            if ($sortedArray.Count -ge 4) {
                $Script:lblNetAIApp4.Text = "4. $($sortedArray[3].Name) ($($sortedArray[3].Sessions)) - $($sortedArray[3].Type)"
            } else {
                $Script:lblNetAIApp4.Text = "4. --"
            }
            # Etykieta 5
            if ($sortedArray.Count -ge 5) {
                $Script:lblNetAIApp5.Text = "5. $($sortedArray[4].Name) ($($sortedArray[4].Sessions)) - $($sortedArray[4].Type)"
            } else {
                $Script:lblNetAIApp5.Text = "5. --"
            }
        } else {
            $Script:lblNetAIApp1.Text = "1. --"
            $Script:lblNetAIApp2.Text = "2. --"
            $Script:lblNetAIApp3.Text = "3. --"
            $Script:lblNetAIApp4.Text = "4. --"
            $Script:lblNetAIApp5.Text = "5. --"
        }
    } catch {
        try { "$((Get-Date).ToString('o')) - Update-NetworkAITopApps ERROR: $_" | Out-File -FilePath 'C:\CPUManager\ErrorLog.txt' -Append -Encoding utf8 } catch { }
    }
}
# #
# UPDATE PROCESSAI - v40: Wyswietla dane z ProcessAI.json
# #
function Update-ProcessAI {
    $processAIPath = Join-Path $Script:ConfigDir "ProcessAI.json"
    try {
        if (Test-Path $processAIPath) {
            $processAI = Get-Content $processAIPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            
            # Update stats
            $Script:ProcessAIData.AppsLearned = if ($processAI.ProcessProfiles) {
                ($processAI.ProcessProfiles.PSObject.Properties | Measure-Object).Count
            } else { 0 }
            
            $Script:ProcessAIData.Classified = if ($processAI.ProcessProfiles) {
                ($processAI.ProcessProfiles.PSObject.Properties | Where-Object {
                    $_.Value.Category -ne "Unknown"
                } | Measure-Object).Count
            } else { 0 }
            
            $Script:ProcessAIData.TotalSessions = if ($processAI.ProcessProfiles) {
                ($processAI.ProcessProfiles.PSObject.Properties | ForEach-Object {
                    $_.Value.Sessions
                } | Measure-Object -Sum).Sum
            } else { 0 }
            
            # Count by category
            $Script:ProcessAIData.WorkApps = if ($processAI.ProcessProfiles) {
                ($processAI.ProcessProfiles.PSObject.Properties | Where-Object {$_.Value.Category -eq "Work"} | Measure-Object).Count
            } else { 0 }
            
            $Script:ProcessAIData.GamingApps = if ($processAI.ProcessProfiles) {
                ($processAI.ProcessProfiles.PSObject.Properties | Where-Object {$_.Value.Category -eq "Gaming"} | Measure-Object).Count
            } else { 0 }
            
            $Script:ProcessAIData.BackgroundApps = if ($processAI.ProcessProfiles) {
                ($processAI.ProcessProfiles.PSObject.Properties | Where-Object {$_.Value.Category -eq "Background"} | Measure-Object).Count
            } else { 0 }
            
            # Average CPU
            $Script:ProcessAIData.AvgCPU = if ($processAI.ProcessProfiles -and $Script:ProcessAIData.AppsLearned -gt 0) {
                [math]::Round(($processAI.ProcessProfiles.PSObject.Properties | ForEach-Object {
                    $_.Value.AvgCPU
                } | Measure-Object -Average).Average, 1)
            } else { 0 }
            
            # Update UI
            $Script:lblProcAIApps.Text = "Apps Learned:   $($Script:ProcessAIData.AppsLearned)"
            $Script:lblProcAIClassified.Text = "Classified:     $($Script:ProcessAIData.Classified)"
            $Script:lblProcAISessions.Text = "Total Sessions: $($Script:ProcessAIData.TotalSessions)"
            $Script:lblProcAIWork.Text = "Work Apps:      $($Script:ProcessAIData.WorkApps)"
            $Script:lblProcAIGaming.Text = "Gaming Apps:    $($Script:ProcessAIData.GamingApps)"
            $Script:lblProcAIBg.Text = "Background:     $($Script:ProcessAIData.BackgroundApps)"
            $Script:lblProcAIAvgCPU.Text = "Avg CPU:        $($Script:ProcessAIData.AvgCPU)%"
            
            # Top 5 processes
            if ($processAI.ProcessProfiles) {
                $Script:ProcessAIData.ProcessProfiles = $processAI.ProcessProfiles
                $topApps = $processAI.ProcessProfiles.PSObject.Properties | 
                    Sort-Object {$_.Value.Sessions} -Descending | 
                    Select-Object -First 5
                
                for ($i = 0; $i -lt 5; $i++) {
                    $label = Get-Variable -Name "lblProcAIProc$($i+1)" -ValueOnly -Scope Script
                    if ($i -lt $topApps.Count) {
                        $app = $topApps[$i]
                        $cpu = [math]::Round($app.Value.AvgCPU, 1)
                        $ram = [math]::Round($app.Value.AvgRAM/1MB, 0)
                        $category = $app.Value.Category
                        $sessions = $app.Value.Sessions
                        $label.Text = "$($i+1). $($app.Name) - CPU:${cpu}% RAM:${ram}MB Cat:$category (${sessions}s)"
                    } else {
                        $label.Text = "$($i+1). --"
                    }
                }
            }
        } else {
            # No file
            $Script:lblProcAIApps.Text = "Apps Learned:   0"
            $Script:lblProcAIClassified.Text = "Classified:     0"
            $Script:lblProcAISessions.Text = "Total Sessions: 0"
            $Script:lblProcAIWork.Text = "Work Apps:      0"
            $Script:lblProcAIGaming.Text = "Gaming Apps:    0"
            $Script:lblProcAIBg.Text = "Background:     0"
            $Script:lblProcAIAvgCPU.Text = "Avg CPU:        0%"
        }
    } catch {
        Write-Warning "Update-ProcessAI error: $_"
    }
}
# #
# SAVE PROCESSAI - v40: Zapisuje zmiany do ProcessAI.json (bidirectional sync)
# #
function Save-ProcessAI {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$ProcessProfiles,
        [int]$TotalLearnings = 0,
        [int]$TotalThrottles = 0
    )
    try {
        $processAIPath = Join-Path $Script:ConfigDir "ProcessAI.json"
        $state = @{
            ProcessProfiles = $ProcessProfiles
            ThrottleHistory = @{}  # Preserve existing or empty
            TotalLearnings = $TotalLearnings
            TotalThrottles = $TotalThrottles
            LastSaved = (Get-Date).ToString("o")
        }
        
        # Load existing file to preserve ThrottleHistory
        if (Test-Path $processAIPath) {
            try {
                $existing = Get-Content $processAIPath -Raw | ConvertFrom-Json
                if ($existing.ThrottleHistory) {
                    $state.ThrottleHistory = $existing.ThrottleHistory
                }
                if ($TotalLearnings -eq 0 -and $existing.TotalLearnings) {
                    $state.TotalLearnings = $existing.TotalLearnings
                }
                if ($TotalThrottles -eq 0 -and $existing.TotalThrottles) {
                    $state.TotalThrottles = $existing.TotalThrottles
                }
            } catch { }
        }
        
        # Write to temp file then atomic rename
        $tmp = "$processAIPath.tmp"
        $json = $state | ConvertTo-Json -Depth 5 -Compress
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
        Move-Item -Path $tmp -Destination $processAIPath -Force
        
        return $true
    } catch {
        Write-Warning "Save-ProcessAI error: $_"
        return $false
    }
}
# #
# UPDATE GPUAI - v40: Wyswietla dane z GPUAI.json
# #
function Update-GPUAI {
    $gpuAIPath = Join-Path $Script:ConfigDir "GPUAI.json"
    try {
        if (Test-Path $gpuAIPath) {
            $gpuAI = Get-Content $gpuAIPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            
            # Update stats
            $Script:GPUAIData.GPUApps = if ($gpuAI.AppGPUProfiles) {
                ($gpuAI.AppGPUProfiles.PSObject.Properties | Measure-Object).Count
            } else { 0 }
            
            $Script:GPUAIData.Classified = if ($gpuAI.AppGPUProfiles) {
                ($gpuAI.AppGPUProfiles.PSObject.Properties | Where-Object {
                    $_.Value.PreferredGPU -ne "Auto"
                } | Measure-Object).Count
            } else { 0 }
            
            $Script:GPUAIData.iGPUPreferred = if ($gpuAI.AppGPUProfiles) {
                ($gpuAI.AppGPUProfiles.PSObject.Properties | Where-Object {
                    $_.Value.PreferredGPU -eq "iGPU"
                } | Measure-Object).Count
            } else { 0 }
            
            $Script:GPUAIData.dGPUPreferred = if ($gpuAI.AppGPUProfiles) {
                ($gpuAI.AppGPUProfiles.PSObject.Properties | Where-Object {
                    $_.Value.PreferredGPU -eq "dGPU"
                } | Measure-Object).Count
            } else { 0 }
            
            # GPU detection info
            if ($gpuAI.HasiGPU -ne $null) { $Script:GPUAIData.HasiGPU = $gpuAI.HasiGPU }
            if ($gpuAI.HasdGPU -ne $null) { $Script:GPUAIData.HasdGPU = $gpuAI.HasdGPU }
            if ($gpuAI.iGPUName) { $Script:GPUAIData.iGPUName = $gpuAI.iGPUName }
            if ($gpuAI.dGPUName) { $Script:GPUAIData.dGPUName = $gpuAI.dGPUName }
            if ($gpuAI.PrimaryGPU) { $Script:GPUAIData.PrimaryGPU = $gpuAI.PrimaryGPU }
            if ($gpuAI.dGPUVendor) { $Script:GPUAIData.dGPUVendor = $gpuAI.dGPUVendor }
            
            # Update UI
            $Script:lblGPUAIApps.Text = "GPU Apps:       $($Script:GPUAIData.GPUApps)"
            $Script:lblGPUAIClassified.Text = "Classified:     $($Script:GPUAIData.Classified)"
            $Script:lblGPUAIiGPU.Text = "iGPU Preferred: $($Script:GPUAIData.iGPUPreferred)"
            $Script:lblGPUAIdGPU.Text = "dGPU Preferred: $($Script:GPUAIData.dGPUPreferred)"
            
            # GPU detection display
            if ($Script:GPUAIData.HasiGPU) {
                $Script:lblGPUAIiGPUName.Text = "iGPU: $($Script:GPUAIData.iGPUName)"
                $Script:lblGPUAIiGPUName.ForeColor = $Script:Colors.Success
            } else {
                $Script:lblGPUAIiGPUName.Text = "iGPU: Not detected"
                $Script:lblGPUAIiGPUName.ForeColor = $Script:Colors.TextDim
            }
            
            if ($Script:GPUAIData.HasdGPU) {
                $Script:lblGPUAIdGPUName.Text = "dGPU: $($Script:GPUAIData.dGPUName)"
                $Script:lblGPUAIdGPUName.ForeColor = $Script:Colors.Success
            } else {
                $Script:lblGPUAIdGPUName.Text = "dGPU: Not detected"
                $Script:lblGPUAIdGPUName.ForeColor = $Script:Colors.TextDim
            }
            
            $Script:lblGPUAIPrimary.Text = "Primary: $($Script:GPUAIData.PrimaryGPU)"
            $Script:lblGPUAIVendor.Text = "Vendor: $($Script:GPUAIData.dGPUVendor)"
            
            # Top 5 GPU apps
            if ($gpuAI.AppGPUProfiles) {
                $Script:GPUAIData.AppGPUProfiles = $gpuAI.AppGPUProfiles
                $topApps = $gpuAI.AppGPUProfiles.PSObject.Properties | 
                    Sort-Object {$_.Value.Sessions} -Descending | 
                    Select-Object -First 5
                
                for ($i = 0; $i -lt 5; $i++) {
                    $label = Get-Variable -Name "lblGPUAIApp$($i+1)" -ValueOnly -Scope Script
                    if ($i -lt $topApps.Count) {
                        $app = $topApps[$i]
                        $load = [math]::Round($app.Value.AvgGPULoad, 1)
                        $pref = $app.Value.PreferredGPU
                        $sessions = $app.Value.Sessions
                        $label.Text = "$($i+1). $($app.Name) - Load:${load}% Preferred:$pref (${sessions}s)"
                    } else {
                        $label.Text = "$($i+1). --"
                    }
                }
            }
        } else {
            # No file
            $Script:lblGPUAIApps.Text = "GPU Apps:       0"
            $Script:lblGPUAIClassified.Text = "Classified:     0"
            $Script:lblGPUAIiGPU.Text = "iGPU Preferred: 0"
            $Script:lblGPUAIdGPU.Text = "dGPU Preferred: 0"
            $Script:lblGPUAIiGPUName.Text = "iGPU: Not detected"
            $Script:lblGPUAIdGPUName.Text = "dGPU: Not detected"
            $Script:lblGPUAIPrimary.Text = "Primary: ---"
            $Script:lblGPUAIVendor.Text = "Vendor: ---"
        }
    } catch {
        Write-Warning "Update-GPUAI error: $_"
    }
}
# #
# SAVE GPUAI - v40: Zapisuje zmiany do GPUAI.json (bidirectional sync)
# #
function Save-GPUAI {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$AppGPUProfiles,
        [int]$TotalSwitches = 0,
        [string]$CurrentMode = "Auto"
    )
    try {
        $gpuAIPath = Join-Path $Script:ConfigDir "GPUAI.json"
        $state = @{
            AppGPUProfiles = $AppGPUProfiles
            TotalSwitches = $TotalSwitches
            CurrentMode = $CurrentMode
            LastSaved = (Get-Date).ToString("o")
        }
        
        # Load existing file to preserve hardware detection data
        if (Test-Path $gpuAIPath) {
            try {
                $existing = Get-Content $gpuAIPath -Raw | ConvertFrom-Json
                # Preserve hardware info
                if ($existing.PSObject.Properties.Name -contains "HasiGPU") {
                    $state.HasiGPU = $existing.HasiGPU
                }
                if ($existing.PSObject.Properties.Name -contains "HasdGPU") {
                    $state.HasdGPU = $existing.HasdGPU
                }
                if ($existing.iGPUName) { $state.iGPUName = $existing.iGPUName }
                if ($existing.dGPUName) { $state.dGPUName = $existing.dGPUName }
                if ($existing.dGPUVendor) { $state.dGPUVendor = $existing.dGPUVendor }
                if ($existing.PrimaryGPU) { $state.PrimaryGPU = $existing.PrimaryGPU }
                
                # Preserve counters if not provided
                if ($TotalSwitches -eq 0 -and $existing.TotalSwitches) {
                    $state.TotalSwitches = $existing.TotalSwitches
                }
            } catch { }
        }
        
        # Write to temp file then atomic rename
        $tmp = "$gpuAIPath.tmp"
        $json = $state | ConvertTo-Json -Depth 5 -Compress
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
        Move-Item -Path $tmp -Destination $gpuAIPath -Force
        
        return $true
    } catch {
        Write-Warning "Save-GPUAI error: $_"
        return $false
    }
}
# #
# SHOW PROCESSAI EDITOR - v40: Dialog do edycji kategorii procesów
# #
function Show-ProcessAIEditor {
    if ($Script:ProcessAIData.ProcessProfiles.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No learned processes yet.", "Process AI", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "ProcessAI Editor - Change Categories"
    $form.Size = New-Object System.Drawing.Size(700, 500)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = $Script:Colors.BgDark
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    
    # ListView
    $listView = New-Object System.Windows.Forms.ListView
    $listView.Location = New-Object System.Drawing.Point(10, 10)
    $listView.Size = New-Object System.Drawing.Size(660, 350)
    $listView.View = [System.Windows.Forms.View]::Details
    $listView.FullRowSelect = $true
    $listView.GridLines = $true
    $listView.BackColor = $Script:Colors.Card
    $listView.ForeColor = $Script:Colors.Text
    [void]$listView.Columns.Add("Process", 200)
    [void]$listView.Columns.Add("Category", 100)
    [void]$listView.Columns.Add("Avg CPU %", 80)
    [void]$listView.Columns.Add("Sessions", 80)
    [void]$listView.Columns.Add("CanThrottle", 100)
    
    # Populate from ProcessProfiles
    $Script:ProcessAIData.ProcessProfiles.PSObject.Properties | ForEach-Object {
        $proc = $_.Name
        $profile = $_.Value
        $item = New-Object System.Windows.Forms.ListViewItem($proc)
        [void]$item.SubItems.Add($profile.Category)
        [void]$item.SubItems.Add([math]::Round($profile.AvgCPU, 1).ToString())
        [void]$item.SubItems.Add($profile.Sessions.ToString())
        $canThrottle = if ($profile.CanThrottle) { "Yes" } else { "No" }
        [void]$item.SubItems.Add($canThrottle)
        $item.Tag = $proc
        [void]$listView.Items.Add($item)
    }
    $form.Controls.Add($listView)
    
    # Category combo
    $lblCat = New-Label -Parent $form -Text "Change Category:" -X 10 -Y 370 -Width 120 -Height 20 -ForeColor $Script:Colors.Text
    $comboCat = New-Object System.Windows.Forms.ComboBox
    $comboCat.Location = New-Object System.Drawing.Point(130, 370)
    $comboCat.Size = New-Object System.Drawing.Size(120, 25)
    $comboCat.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $comboCat.Items.AddRange(@("Work", "Gaming", "Background", "Rendering", "Unknown"))
    $comboCat.SelectedIndex = 0
    $form.Controls.Add($comboCat)
    
    # Apply button
    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Location = New-Object System.Drawing.Point(260, 369)
    $btnApply.Size = New-Object System.Drawing.Size(80, 26)
    $btnApply.Text = "Apply"
    $btnApply.BackColor = $Script:Colors.Success
    $btnApply.ForeColor = [System.Drawing.Color]::White
    $btnApply.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnApply.Add_Click({
        if ($listView.SelectedItems.Count -eq 0) { return }
        $selected = $listView.SelectedItems[0]
        $procName = $selected.Tag
        $newCat = $comboCat.SelectedItem
        
        # Update in-memory
        $Script:ProcessAIData.ProcessProfiles.$procName.Category = $newCat
        $selected.SubItems[1].Text = $newCat
    })
    $form.Controls.Add($btnApply)
    
    # Save button
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Location = New-Object System.Drawing.Point(450, 410)
    $btnSave.Size = New-Object System.Drawing.Size(100, 30)
    $btnSave.Text = "Save to JSON"
    $btnSave.BackColor = $Script:Colors.Turbo
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSave.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnSave.Add_Click({
        # Convert to hashtable for Save function
        $profiles = @{}
        $Script:ProcessAIData.ProcessProfiles.PSObject.Properties | ForEach-Object {
            $profiles[$_.Name] = $_.Value
        }
        
        $result = Save-ProcessAI -ProcessProfiles $profiles
        if ($result) {
            [System.Windows.Forms.MessageBox]::Show("Saved successfully! ENGINE will load changes on next cycle.", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            $form.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show("Failed to save.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    $form.Controls.Add($btnSave)
    
    # Close button
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Location = New-Object System.Drawing.Point(560, 410)
    $btnClose.Size = New-Object System.Drawing.Size(100, 30)
    $btnClose.Text = "Close"
    $btnClose.BackColor = $Script:Colors.TextDim
    $btnClose.ForeColor = [System.Drawing.Color]::White
    $btnClose.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnClose.Add_Click({ $form.Close() })
    $form.Controls.Add($btnClose)
    
    $form.ShowDialog() | Out-Null
}
# #
# SHOW GPUAI EDITOR - v40: Dialog do edycji preferencji GPU
# #
function Show-GPUAIEditor {
    if ($Script:GPUAIData.AppGPUProfiles.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No GPU apps learned yet.", "GPU AI", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "GPUAI Editor - Set GPU Preferences"
    $form.Size = New-Object System.Drawing.Size(700, 500)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = $Script:Colors.BgDark
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    
    # ListView
    $listView = New-Object System.Windows.Forms.ListView
    $listView.Location = New-Object System.Drawing.Point(10, 10)
    $listView.Size = New-Object System.Drawing.Size(660, 350)
    $listView.View = [System.Windows.Forms.View]::Details
    $listView.FullRowSelect = $true
    $listView.GridLines = $true
    $listView.BackColor = $Script:Colors.Card
    $listView.ForeColor = $Script:Colors.Text
    [void]$listView.Columns.Add("Application", 250)
    [void]$listView.Columns.Add("Preferred GPU", 120)
    [void]$listView.Columns.Add("Avg Load %", 90)
    [void]$listView.Columns.Add("Sessions", 80)
    
    # Populate from AppGPUProfiles
    $Script:GPUAIData.AppGPUProfiles.PSObject.Properties | ForEach-Object {
        $app = $_.Name
        $profile = $_.Value
        $item = New-Object System.Windows.Forms.ListViewItem($app)
        $item.SubItems.Add($profile.PreferredGPU)
        $item.SubItems.Add([math]::Round($profile.AvgGPULoad, 1).ToString())
        $item.SubItems.Add($profile.Sessions.ToString())
        $item.Tag = $app
        [void]$listView.Items.Add($item)
    }
    $form.Controls.Add($listView)
    
    # GPU preference combo
    $lblGPU = New-Label -Parent $form -Text "Set Preferred GPU:" -X 10 -Y 370 -Width 120 -Height 20 -ForeColor $Script:Colors.Text
    $comboGPU = New-Object System.Windows.Forms.ComboBox
    $comboGPU.Location = New-Object System.Drawing.Point(130, 370)
    $comboGPU.Size = New-Object System.Drawing.Size(100, 25)
    $comboGPU.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $comboGPU.Items.AddRange(@("Auto", "iGPU", "dGPU"))
    $comboGPU.SelectedIndex = 0
    $form.Controls.Add($comboGPU)
    
    # Apply button
    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Location = New-Object System.Drawing.Point(240, 369)
    $btnApply.Size = New-Object System.Drawing.Size(80, 26)
    $btnApply.Text = "Apply"
    $btnApply.BackColor = $Script:Colors.Success
    $btnApply.ForeColor = [System.Drawing.Color]::White
    $btnApply.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnApply.Add_Click({
        if ($listView.SelectedItems.Count -eq 0) { return }
        $selected = $listView.SelectedItems[0]
        $appName = $selected.Tag
        $newGPU = $comboGPU.SelectedItem
        
        # Update in-memory
        $Script:GPUAIData.AppGPUProfiles.$appName.PreferredGPU = $newGPU
        $selected.SubItems[1].Text = $newGPU
    })
    $form.Controls.Add($btnApply)
    
    # Save button
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Location = New-Object System.Drawing.Point(450, 410)
    $btnSave.Size = New-Object System.Drawing.Size(100, 30)
    $btnSave.Text = "Save to JSON"
    $btnSave.BackColor = $Script:Colors.Turbo
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSave.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnSave.Add_Click({
        # Convert to hashtable for Save function
        $profiles = @{}
        $Script:GPUAIData.AppGPUProfiles.PSObject.Properties | ForEach-Object {
            $profiles[$_.Name] = $_.Value
        }
        
        $result = Save-GPUAI -AppGPUProfiles $profiles
        if ($result) {
            [System.Windows.Forms.MessageBox]::Show("Saved successfully! ENGINE will load changes on next cycle.", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            $form.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show("Failed to save.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    $form.Controls.Add($btnSave)
    
    # Close button
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Location = New-Object System.Drawing.Point(560, 410)
    $btnClose.Size = New-Object System.Drawing.Size(100, 30)
    $btnClose.Text = "Close"
    $btnClose.BackColor = $Script:Colors.TextDim
    $btnClose.ForeColor = [System.Drawing.Color]::White
    $btnClose.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnClose.Add_Click({ $form.Close() })
    $form.Controls.Add($btnClose)
    
    $form.ShowDialog() | Out-Null
}
# #
# FUNKCJE - RYZENADJ
# #
function Test-RyzenAdj {
    $paths = @("C:\ryzenadj-win64\ryzenadj.exe", "C:\CPUManager\ryzenadj\ryzenadj.exe")
    foreach ($path in $paths) { if (Test-Path $path) { $Script:RyzenAdjPath = $path; return $true } }
    return $false
}
function Get-RyzenAdjInfo {
    if (-not (Test-Path $Script:RyzenAdjPath)) { return $null }
    try {
        $output = & $Script:RyzenAdjPath --info 2>&1 | Out-String
        $info = @{ STAPM = 0; STAPMValue = 0; Fast = 0; FastValue = 0; Slow = 0; SlowValue = 0; Tctl = 0; TctlValue = 0 }
        if ($output -match "\|\s*STAPM LIMIT\s*\|\s*(\d+\.?\d*)\s*\|") { $info.STAPM = [Math]::Round([double]$Matches[1], 1) }
        if ($output -match "\|\s*STAPM VALUE\s*\|\s*(\d+\.?\d*)\s*\|") { $info.STAPMValue = [Math]::Round([double]$Matches[1], 1) }
        if ($output -match "\|\s*PPT LIMIT FAST\s*\|\s*(\d+\.?\d*)\s*\|") { $info.Fast = [Math]::Round([double]$Matches[1], 1) }
        if ($output -match "\|\s*PPT VALUE FAST\s*\|\s*(\d+\.?\d*)\s*\|") { $info.FastValue = [Math]::Round([double]$Matches[1], 1) }
        if ($output -match "\|\s*PPT LIMIT SLOW\s*\|\s*(\d+\.?\d*)\s*\|") { $info.Slow = [Math]::Round([double]$Matches[1], 1) }
        if ($output -match "\|\s*PPT VALUE SLOW\s*\|\s*(\d+\.?\d*)\s*\|") { $info.SlowValue = [Math]::Round([double]$Matches[1], 1) }
        if ($output -match "\|\s*THM LIMIT CORE\s*\|\s*(\d+\.?\d*)\s*\|") { $info.Tctl = [Math]::Round([double]$Matches[1], 0) }
        if ($output -match "\|\s*THM VALUE CORE\s*\|\s*(\d+\.?\d*)\s*\|") { $info.TctlValue = [Math]::Round([double]$Matches[1], 1) }
        return $info
    } catch { return $null }
}
function Set-RyzenAdjTDP {
    param([int]$STAPM, [int]$Fast, [int]$Slow, [int]$Tctl)
    if (-not (Test-Path $Script:RyzenAdjPath)) { return $false }
    try {
        $argList = "--stapm-limit=$($STAPM * 1000) --fast-limit=$($Fast * 1000) --slow-limit=$($Slow * 1000) --tctl-temp=$Tctl"
        Start-Process -FilePath $Script:RyzenAdjPath -ArgumentList $argList -NoNewWindow -Wait
        return $true
    } catch { return $false }
}
# #
# LADOWANIE KONFIGURACJI
# #
$Script:Config = Get-Config
$Script:Engines = Get-AIEngines
$Script:TDPConfig = Get-TDPConfig
# #
# GLOWNE OKNO
# #
$form = New-Object System.Windows.Forms.Form
$Script:MainForm = $form  # Referencja dla funkcji pomocniczych
$form.Text = "CPUManager v40 - Console + Configurator"
$form.Size = New-Object System.Drawing.Size(1200, 950)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 850)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = $Script:Colors.Background
$form.ForeColor = $Script:Colors.Text
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.ShowInTaskbar = $true
try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\perfmon.exe") } catch { }
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.InitialDelay = 500
$toolTip.ReshowDelay = 100
$toolTip.ShowAlways = $true
# Status ToolTip dla notyfikacji
$Script:StatusToolTip = New-Object System.Windows.Forms.ToolTip
$Script:StatusToolTip.IsBalloon = $true
$Script:StatusToolTip.InitialDelay = 0
$Script:StatusToolTip.ReshowDelay = 0
# #
# SYSTEM TRAY
# #
$Script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$Script:TrayIcon.Text = "CPU Manager Console"
$Script:TrayIcon.Visible = $true
try { $Script:TrayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\perfmon.exe") } catch { $Script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application }
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuShow = New-Object System.Windows.Forms.ToolStripMenuItem; $menuShow.Text = "Show Console"; $menuShow.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$menuShow.Add_Click({ $form.Show(); $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal; $form.Activate() })
$trayMenu.Items.Add($menuShow)
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
# #
# #
$menuModes = New-Object System.Windows.Forms.ToolStripMenuItem
$menuModes.Text = " Power Modes"
$menuModes.Add_DropDownOpening({
    # Lazy load menu items only when opened (v39.3 performance optimization)
    if ($menuModes.DropDownItems.Count -eq 0) {
        foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
            $mi = New-Object System.Windows.Forms.ToolStripMenuItem; $mi.Text = "$mode Mode"; $mi.Tag = $mode
            $mi.Add_Click({ Send-Command $this.Tag }); $menuModes.DropDownItems.Add($mi)
        }
    }
})
$trayMenu.Items.Add($menuModes)
#  AI Control
$menuAI = New-Object System.Windows.Forms.ToolStripMenuItem
$menuAI.Text = " AI Control"
$miToggleAI = New-Object System.Windows.Forms.ToolStripMenuItem; $miToggleAI.Text = "Toggle AI"
$miToggleAI.Add_Click({ Send-Command "AI" }); $menuAI.DropDownItems.Add($miToggleAI)
$miSilentLock = New-Object System.Windows.Forms.ToolStripMenuItem; $miSilentLock.Text = "Silent Lock"
$miSilentLock.Add_Click({ Send-Command "SILENT_LOCK" }); $menuAI.DropDownItems.Add($miSilentLock)
$trayMenu.Items.Add($menuAI)
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
# System Tools
$menuTools = New-Object System.Windows.Forms.ToolStripMenuItem
$menuTools.Text = "[TOOLS] System Tools"
# Trim RAM
$miTrimRAM = New-Object System.Windows.Forms.ToolStripMenuItem; $miTrimRAM.Text = "[RAM] Trim RAM"
$miTrimRAM.Add_Click({
    $count = Clear-RAM
    $Script:TrayIcon.ShowBalloonTip(2000, "RAM Trimmed", "Trimmed $count processes", [System.Windows.Forms.ToolTipIcon]::Info)
}); $menuTools.DropDownItems.Add($miTrimRAM)
# Reload Config
$miReload = New-Object System.Windows.Forms.ToolStripMenuItem; $miReload.Text = " Reload Config"
$miReload.Add_Click({
    try { 
        Send-ReloadSignal @{ Action = "ReloadConfig" } 
        $Script:TrayIcon.ShowBalloonTip(2000, "Config Reload", "Signal sent to ENGINE", [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
}); $menuTools.DropDownItems.Add($miReload)
$menuTools.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
# Open Config Folder
$miOpenFolder = New-Object System.Windows.Forms.ToolStripMenuItem; $miOpenFolder.Text = " Open Config Folder"
$miOpenFolder.Add_Click({
    try { Start-Process "explorer.exe" -ArgumentList $Script:ConfigDir } catch { }
}); $menuTools.DropDownItems.Add($miOpenFolder)
$trayMenu.Items.Add($menuTools)
# Info
$menuInfo = New-Object System.Windows.Forms.ToolStripMenuItem
$menuInfo.Text = "[INFO] Info"
# Storage Mode Info
$miStorage = New-Object System.Windows.Forms.ToolStripMenuItem; $miStorage.Text = "[DISK] Storage Mode"
$miStorage.Add_Click({
    $mode = if ($Script:UseRAMStorage -and $Script:UseJSONStorage) { "BOTH (RAM + JSON)" } 
            elseif ($Script:UseRAMStorage) { "RAM only" } 
            else { "JSON only" }
    [System.Windows.Forms.MessageBox]::Show("Current Storage Mode: $mode`n`nChange in Settings tab", "Storage Mode", "OK", "Information")
}); $menuInfo.DropDownItems.Add($miStorage)
# About
$miAbout = New-Object System.Windows.Forms.ToolStripMenuItem; $miAbout.Text = "i About"
$miAbout.Add_Click({
    [System.Windows.Forms.MessageBox]::Show("CPU Manager Console v40`n`nOptimized CPU power management with AI learning`n`nSelf-optimizing RAM usage`n`n(C) 2024-2025 Michal", "About", "OK", "Information")
}); $menuInfo.DropDownItems.Add($miAbout)
$trayMenu.Items.Add($menuInfo)
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem; $menuExit.Text = "Exit"; $menuExit.Add_Click({ $Script:ForceExit = $true; $form.Close() }); $trayMenu.Items.Add($menuExit)
# Exit and Kill All PowerShell - zabija wszystkie procesy PowerShell (stary i nowy)
$menuExitKill = New-Object System.Windows.Forms.ToolStripMenuItem
$menuExitKill.Text = "Exit and Kill All PowerShell"
$menuExitKill.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This will kill ALL PowerShell processes (ENGINE, scripts, etc.)`n`nAre you sure?",
        "Confirm Kill All",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $currentPID = $PID
        # Zabij stary PowerShell (powershell.exe)
        Get-Process -Name "powershell" -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $currentPID } | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        # Zabij nowy PowerShell Core (pwsh.exe)
        Get-Process -Name "pwsh" -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $currentPID } | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        # Zamknij CONFIGURATOR
        $Script:ForceExit = $true
        $form.Close()
        # Na koniec zabij siebie
        Start-Sleep -Milliseconds 500
        Stop-Process -Id $currentPID -Force -ErrorAction SilentlyContinue
    }
})
$trayMenu.Items.Add($menuExitKill)
$Script:TrayIcon.ContextMenuStrip = $trayMenu
$Script:TrayIcon.Add_DoubleClick({ $form.Show(); $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal; $form.Activate() })
$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.Hide()
        $Script:TrayIcon.ShowBalloonTip(1000, "CPU Manager", "Running in background", [System.Windows.Forms.ToolTipIcon]::Info)
    } elseif ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
        $form.Show()
        # Natychmiastowy odczyt wszystkich nowych zgloszen z glownego programu (ENGINE)
        try {
            if ($Script:BackgroundRefreshTimer) {
                $Script:BackgroundRefreshTimer.Start(); Write-Host "BackgroundRefreshTimer forced refresh (restored)"
            }
            if (Get-Command -Name Read-WidgetData -ErrorAction SilentlyContinue) {
                Read-WidgetData
                Write-Host "Read-WidgetData: zgloszenia odczytane po przywroceniu z tray"
            }
            # Dodaj tu inne natychmiastowe odczyty jesli potrzebne
        } catch { Write-Host "[ERROR] Data refresh failed: $_" }
    }
})
$form.Add_Move({
    # Save position when user moves window (throttled)
    if (-not $Script:MoveSaveTimer) {
        $Script:MoveSaveTimer = New-Object System.Windows.Forms.Timer
        $Script:MoveSaveTimer.Interval = 500
        $Script:MoveSaveTimer.Add_Tick({
            try {
                # Save window position to config
                if ($Script:Config) {
                    $Script:Config.WindowX = $form.Location.X
                    $Script:Config.WindowY = $form.Location.Y
                }
                $Script:MoveSaveTimer.Stop()
            } catch {}
        })
    }
    $Script:MoveSaveTimer.Stop()
    $Script:MoveSaveTimer.Start()
})
$form.Add_LocationChanged({
    # Prevent excessive updates during drag - only when drag complete
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
        # Window position changed, could be user drag
    }
})
# #
# GORNY PASEK STATUSU
# #
$topBar = New-Panel -Parent $form -X 0 -Y 0 -Width $form.ClientSize.Width -Height 55 -BackColor $Script:Colors.Panel
$topBar.Dock = [System.Windows.Forms.DockStyle]::Top
$lblTitle = New-Label -Parent $topBar -Text "CPUManager v40" -X 15 -Y 5 -Width 280 -Height 25 -FontSize 13 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
$lblSubtitle = New-Label -Parent $topBar -Text "Console + Configurator" -X 15 -Y 30 -Width 200 -Height 18 -FontSize 9 -ForeColor $Script:Colors.TextDim
$Script:lblStatusAI = New-Label -Parent $topBar -Text "[AI] Connecting..." -X 300 -Y 8 -Width 250 -Height 20 -FontSize 10 -ForeColor $Script:Colors.Warning
$Script:lblStatusMode = New-Label -Parent $topBar -Text "[MODE] ---" -X 300 -Y 30 -Width 250 -Height 20 -FontSize 10 -ForeColor $Script:Colors.Text
$Script:lblClock = New-Label -Parent $topBar -Text (Get-Date).ToString("HH:mm:ss") -X 900 -Y 8 -Width 100 -Height 25 -FontSize 12 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Success -Align ([System.Drawing.ContentAlignment]::MiddleRight)
$Script:lblStatusCPU = New-Label -Parent $topBar -Text "CPU: --% | Temp: --C" -X 700 -Y 30 -Width 300 -Height 20 -FontSize 10 -ForeColor $Script:Colors.ChartCPU -Align ([System.Drawing.ContentAlignment]::MiddleRight)
# Debug: Quick RAM read button
$btnDbgReadRAM = New-Button -Parent $topBar -Text "ReadRAM" -X 880 -Y 8 -Width 70 -Height 24 -BackColor $Script:Colors.Card -OnClick {
    try {
        if ($Script:SharedRAM) {
            $raw = $Script:SharedRAM.ReadRaw()
            $preview = if ($raw.Length -gt 2000) { $raw.Substring(0,2000) + "..." } else { $raw }
            [System.Windows.Forms.MessageBox]::Show($preview, "SharedRAM Snapshot")
        } else {
            [System.Windows.Forms.MessageBox]::Show("SharedRAM not available", "SharedRAM Snapshot")
        }
    } catch { [System.Windows.Forms.MessageBox]::Show("Error reading SharedRAM: $_", "SharedRAM Snapshot") }
}
$toolTip.SetToolTip($btnDbgReadRAM, "- Odczytuje i wyswietla aktualna zawartosc pamieci dzielonej RAM z ENGINE. Debug tool.")
# Storage Mode indicator
$storageMode = if ($Script:UseJSONStorage -and $Script:UseRAMStorage) { "JSON+RAM" } elseif ($Script:UseRAMStorage) { "RAM" } else { "JSON" }
$storageColor = if ($Script:UseRAMStorage) { [System.Drawing.Color]::Cyan } else { [System.Drawing.Color]::Orange }
$Script:lblStorageMode = New-Label -Parent $topBar -Text "Storage: $storageMode" -X 560 -Y 8 -Width 130 -Height 20 -FontSize 9 -ForeColor $storageColor
# Checkbox: prefer JSON over RAM
$cbPreferJson = New-CheckBox -Parent $topBar -Text "Prefer JSON over RAM" -X 700 -Y 8 -Width 180 -Checked $Script:PreferJSONOverRAM
$toolTip.SetToolTip($cbPreferJson, " Preferuje pliki JSON zamiast pamieci RAM dla komunikacji. Wolniejsze ale bardziej stabilne.")
$cbPreferJson.Add_CheckedChanged({
    try {
        $Script:PreferJSONOverRAM = $cbPreferJson.Checked
        # Persist preference into StorageMode.json alongside UseJSON/UseRAM
        $path = $Script:StorageModeConfigPath
        $cfg = @{ UseJSON = $Script:UseJSONStorage; UseRAM = $Script:UseRAMStorage; PreferJSON = $Script:PreferJSONOverRAM } | ConvertTo-Json
        $cfg | Set-Content $path -Encoding UTF8 -Force
    } catch { }
})
# #
# ZAKLADKI
# #
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(5, 60)
$tabs.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - 10), ($form.ClientSize.Height - 65))
$tabs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$tabs.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tabs.Padding = New-Object System.Drawing.Point(15, 5)
$tabs.ItemSize = New-Object System.Drawing.Size(110, 28)
$tabs.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed
$tabs.DrawMode = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed
$tabs.Add_DrawItem({
    param($sender, $e)
    $g = $e.Graphics; $tabPage = $sender.TabPages[$e.Index]; $bounds = $e.Bounds
    $isSelected = ($sender.SelectedIndex -eq $e.Index)
    $bgColor = if ($isSelected) { $Script:Colors.Card } else { $Script:Colors.Panel }
    $fgColor = if ($isSelected) { $Script:Colors.Accent } else { $Script:Colors.TextDim }
    $g.FillRectangle((New-Object System.Drawing.SolidBrush($bgColor)), $bounds)
    $font = New-Object System.Drawing.Font("Segoe UI", 9, $(if ($isSelected) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
    $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = [System.Drawing.StringAlignment]::Center; $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString($tabPage.Text, $font, (New-Object System.Drawing.SolidBrush($fgColor)), [System.Drawing.RectangleF]::op_Implicit($bounds), $sf)
})
$form.Controls.Add($tabs)
# #
# TAB 1: SENSORS
# #
$tabSensors = New-Object System.Windows.Forms.TabPage
$tabSensors.Text = "Sensors"
$tabSensors.BackColor = $Script:Colors.Background
$tabSensors.AutoScroll = $true  #  v39.5.1: Enable scroll
$tabs.TabPages.Add($tabSensors)
$lblSensorsTitle = New-SectionLabel -Parent $tabSensors -Text "[SYSTEM SENSORS]" -X 10 -Y 8
$Script:lblSensorsCPU = New-Label -Parent $tabSensors -Text "  CPU: [                    ] 0%" -X 10 -Y 32 -Width 600 -Height 22 -ForeColor $Script:Colors.ChartCPU
$Script:lblSensorsIO = New-Label -Parent $tabSensors -Text "  I/O: 0.0 MB/s | Temp: 0C | Trend: ->" -X 10 -Y 55 -Width 700 -Height 22
$lblAITitle = New-SectionLabel -Parent $tabSensors -Text "[AI ENGINE STATUS]" -X 10 -Y 85
$Script:lblAIPressure = New-Label -Parent $tabSensors -Text "  Pressure: [                    ] 0" -X 10 -Y 108 -Width 500 -Height 22 -ForeColor $Script:Colors.Purple
$Script:lblAdvancedInfo = New-Label -Parent $tabSensors -Text "  Ensemble: OFF | Neural Brain: ---" -X 10 -Y 131 -Width 700 -Height 22
$lblCoreTitle = New-SectionLabel -Parent $tabSensors -Text "[CORE AI COMPONENTS]" -X 10 -Y 161
$Script:lblCoreStats = New-Label -Parent $tabSensors -Text "  Prophet | QLearning | Bandit | Genetic | Energy | SelfTuner | Chain" -X 10 -Y 184 -Width 1100 -Height 22
$Script:lblCoreWhy = New-Label -Parent $tabSensors -Text "  Decision: ---" -X 10 -Y 207 -Width 1100 -Height 22 -ForeColor $Script:Colors.Cyan
$Script:lblOptimizationCache = New-Label -Parent $tabSensors -Text "  Optimization: Cache: 0 apps | FastBoot: 0 apps | History: 0 apps" -X 10 -Y 225 -Width 1100 -Height 22 -ForeColor $Script:Colors.Success
# Activity Log w zakladce Sensors
$lblLogTitle = New-SectionLabel -Parent $tabSensors -Text "[ACTIVITY LOG]" -X 10 -Y 250
$Script:txtActivityLog = New-Object System.Windows.Forms.RichTextBox
$Script:txtActivityLog.Location = New-Object System.Drawing.Point(10, 275)
$Script:txtActivityLog.Size = New-Object System.Drawing.Size(755, 130)
$Script:txtActivityLog.BackColor = $Script:Colors.Panel
$Script:txtActivityLog.ForeColor = $Script:Colors.Text
$Script:txtActivityLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$Script:txtActivityLog.ReadOnly = $true; $Script:txtActivityLog.ScrollBars = "Vertical"; $Script:txtActivityLog.WordWrap = $false
$tabSensors.Controls.Add($Script:txtActivityLog)
$btnClearLog = New-Button -Parent $tabSensors -Text "Clear" -X 680 -Y 245 -Width 70 -Height 25 -BackColor $Script:Colors.Card -OnClick { $Script:txtActivityLog.Clear(); $Script:LastLogs.Clear() }
$Script:lblLogCount = New-Label -Parent $tabSensors -Text "0" -X 755 -Y 275 -Width 30 -Height 20 -ForeColor $Script:Colors.TextDim
$lblRAMChartTitle = New-SectionLabel -Parent $tabSensors -Text "[RAM INTELLIGENCE HISTORY]" -X 10 -Y 410
# Wykres (lewa strona - 760px)
$Script:picRAMChart = New-Object System.Windows.Forms.PictureBox
$Script:picRAMChart.Location = New-Object System.Drawing.Point(10, 435)
$Script:picRAMChart.Size = New-Object System.Drawing.Size(760, 165)  # Zmniejszone z 1140
$Script:picRAMChart.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 26)  # #1A1A1A
$Script:picRAMChart.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$tabSensors.Controls.Add($Script:picRAMChart)
$pnlRAMMetrics = New-Object System.Windows.Forms.Panel
$pnlRAMMetrics.Location = New-Object System.Drawing.Point(770, 258)
$pnlRAMMetrics.Size = New-Object System.Drawing.Size(380, 365)
$pnlRAMMetrics.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$pnlRAMMetrics.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$tabSensors.Controls.Add($pnlRAMMetrics)
# Tytul panelu
$lblMetricsTitle = New-Object System.Windows.Forms.Label
$lblMetricsTitle.Location = New-Object System.Drawing.Point(10, 5)
$lblMetricsTitle.Size = New-Object System.Drawing.Size(350, 20)
$lblMetricsTitle.Text = "[LIVE METRICS]"
$lblMetricsTitle.ForeColor = $Script:Colors.Accent
$lblMetricsTitle.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$pnlRAMMetrics.Controls.Add($lblMetricsTitle)
# RAM Current Value
$Script:lblRAMValue = New-Object System.Windows.Forms.Label
$Script:lblRAMValue.Location = New-Object System.Drawing.Point(10, 28)
$Script:lblRAMValue.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblRAMValue.Text = "RAM: ---"
$Script:lblRAMValue.ForeColor = $Script:Colors.Text
$Script:lblRAMValue.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlRAMMetrics.Controls.Add($Script:lblRAMValue)
# Delta Value
$Script:lblDeltaValue = New-Object System.Windows.Forms.Label
$Script:lblDeltaValue.Location = New-Object System.Drawing.Point(10, 44)
$Script:lblDeltaValue.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblDeltaValue.Text = "Delta: ---"
$Script:lblDeltaValue.ForeColor = $Script:Colors.Text
$Script:lblDeltaValue.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlRAMMetrics.Controls.Add($Script:lblDeltaValue)
# Acceleration Value
$Script:lblAccelValue = New-Object System.Windows.Forms.Label
$Script:lblAccelValue.Location = New-Object System.Drawing.Point(10, 60)
$Script:lblAccelValue.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblAccelValue.Text = "Acceleration: ---"
$Script:lblAccelValue.ForeColor = $Script:Colors.Text
$Script:lblAccelValue.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlRAMMetrics.Controls.Add($Script:lblAccelValue)
# Trend Type
$Script:lblTrendTypeValue = New-Object System.Windows.Forms.Label
$Script:lblTrendTypeValue.Location = New-Object System.Drawing.Point(10, 76)
$Script:lblTrendTypeValue.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblTrendTypeValue.Text = "Trend Type: ---"
$Script:lblTrendTypeValue.ForeColor = $Script:Colors.Text
$Script:lblTrendTypeValue.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlRAMMetrics.Controls.Add($Script:lblTrendTypeValue)
# Separator 1
$lblSeparator1 = New-Object System.Windows.Forms.Label
$lblSeparator1.Location = New-Object System.Drawing.Point(10, 94)
$lblSeparator1.Size = New-Object System.Drawing.Size(350, 1)
$lblSeparator1.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$pnlRAMMetrics.Controls.Add($lblSeparator1)
# Threshold Section Header
$lblThresholdHeader = New-Object System.Windows.Forms.Label
$lblThresholdHeader.Location = New-Object System.Drawing.Point(10, 98)
$lblThresholdHeader.Size = New-Object System.Drawing.Size(350, 15)
$lblThresholdHeader.Text = "[THRESHOLD STATUS]"
$lblThresholdHeader.ForeColor = $Script:Colors.Accent
$lblThresholdHeader.Font = New-Object System.Drawing.Font("Consolas", 8, [System.Drawing.FontStyle]::Bold)
$pnlRAMMetrics.Controls.Add($lblThresholdHeader)
# Current Threshold
$Script:lblCurrentThreshold = New-Object System.Windows.Forms.Label
$Script:lblCurrentThreshold.Location = New-Object System.Drawing.Point(10, 114)
$Script:lblCurrentThreshold.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblCurrentThreshold.Text = "Current: 8.0% "
$Script:lblCurrentThreshold.ForeColor = $Script:Colors.Text
$Script:lblCurrentThreshold.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlRAMMetrics.Controls.Add($Script:lblCurrentThreshold)
# Threshold Reason
$Script:lblThresholdReason = New-Object System.Windows.Forms.Label
$Script:lblThresholdReason.Location = New-Object System.Drawing.Point(10, 130)
$Script:lblThresholdReason.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblThresholdReason.Text = "Normal CPU"
$Script:lblThresholdReason.ForeColor = $Script:Colors.TextDim
$Script:lblThresholdReason.Font = New-Object System.Drawing.Font("Consolas", 8)
$pnlRAMMetrics.Controls.Add($Script:lblThresholdReason)
# Separator 2
$lblSeparator2 = New-Object System.Windows.Forms.Label
$lblSeparator2.Location = New-Object System.Drawing.Point(10, 148)
$lblSeparator2.Size = New-Object System.Drawing.Size(350, 1)
$lblSeparator2.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$pnlRAMMetrics.Controls.Add($lblSeparator2)
# Detection Stats Header
$lblDetectionHeader = New-Object System.Windows.Forms.Label
$lblDetectionHeader.Location = New-Object System.Drawing.Point(10, 152)
$lblDetectionHeader.Size = New-Object System.Drawing.Size(350, 15)
$lblDetectionHeader.Text = "[DETECTION STATS]"
$lblDetectionHeader.ForeColor = $Script:Colors.Accent
$lblDetectionHeader.Font = New-Object System.Drawing.Font("Consolas", 8, [System.Drawing.FontStyle]::Bold)
$pnlRAMMetrics.Controls.Add($lblDetectionHeader)
# Current Status (Spike/Trend/Normal)
$Script:lblRAMStatus2 = New-Object System.Windows.Forms.Label
$Script:lblRAMStatus2.Location = New-Object System.Drawing.Point(10, 168)
$Script:lblRAMStatus2.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblRAMStatus2.Text = "Status: - Normal"
$Script:lblRAMStatus2.ForeColor = $Script:Colors.Success
$Script:lblRAMStatus2.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlRAMMetrics.Controls.Add($Script:lblRAMStatus2)
# Spikes / Trends / PreBoosts counts
$Script:lblRAMCounts = New-Object System.Windows.Forms.Label
$Script:lblRAMCounts.Location = New-Object System.Drawing.Point(10, 184)
$Script:lblRAMCounts.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblRAMCounts.Text = "Spikes: 0  |  Trends: 0  |  PreBoosts: 0"
$Script:lblRAMCounts.ForeColor = $Script:Colors.Text
$Script:lblRAMCounts.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlRAMMetrics.Controls.Add($Script:lblRAMCounts)
# Learned Apps
$Script:lblLearnedApps = New-Object System.Windows.Forms.Label
$Script:lblLearnedApps.Location = New-Object System.Drawing.Point(10, 200)
$Script:lblLearnedApps.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblLearnedApps.Text = "Learned Apps: 0 (need boost)"
$Script:lblLearnedApps.ForeColor = $Script:Colors.Text
$Script:lblLearnedApps.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlRAMMetrics.Controls.Add($Script:lblLearnedApps)
# Last Boost Reason
$Script:lblLastBoost = New-Object System.Windows.Forms.Label
$Script:lblLastBoost.Location = New-Object System.Drawing.Point(10, 216)
$Script:lblLastBoost.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblLastBoost.Text = "Last Boost: ---"
$Script:lblLastBoost.ForeColor = $Script:Colors.TextDim
$Script:lblLastBoost.Font = New-Object System.Drawing.Font("Consolas", 8)
$pnlRAMMetrics.Controls.Add($Script:lblLastBoost)
# Separator 3
$lblSeparator3 = New-Object System.Windows.Forms.Label
$lblSeparator3.Location = New-Object System.Drawing.Point(10, 234)
$lblSeparator3.Size = New-Object System.Drawing.Size(350, 1)
$lblSeparator3.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$pnlRAMMetrics.Controls.Add($lblSeparator3)
# AI Learning Header
$lblAILearningHeader = New-Object System.Windows.Forms.Label
$lblAILearningHeader.Location = New-Object System.Drawing.Point(10, 238)
$lblAILearningHeader.Size = New-Object System.Drawing.Size(350, 15)
$lblAILearningHeader.Text = "[AI LEARNING FROM RAM]"
$lblAILearningHeader.ForeColor = $Script:Colors.Accent
$lblAILearningHeader.Font = New-Object System.Drawing.Font("Consolas", 8, [System.Drawing.FontStyle]::Bold)
$pnlRAMMetrics.Controls.Add($lblAILearningHeader)
# AI Engines using RAM data
$Script:lblAIRAMUsage = New-Object System.Windows.Forms.Label
$Script:lblAIRAMUsage.Location = New-Object System.Drawing.Point(10, 254)
$Script:lblAIRAMUsage.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblAIRAMUsage.Text = "QLearning: RAM state | Brain: RAM weight"
$Script:lblAIRAMUsage.ForeColor = $Script:Colors.Text
$Script:lblAIRAMUsage.Font = New-Object System.Drawing.Font("Consolas", 8)
$pnlRAMMetrics.Controls.Add($Script:lblAIRAMUsage)
# AI Reward from RAM
$Script:lblAIRAMReward = New-Object System.Windows.Forms.Label
$Script:lblAIRAMReward.Location = New-Object System.Drawing.Point(10, 270)
$Script:lblAIRAMReward.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblAIRAMReward.Text = "Last Reward: --- | Source: ---"
$Script:lblAIRAMReward.ForeColor = $Script:Colors.TextDim
$Script:lblAIRAMReward.Font = New-Object System.Drawing.Font("Consolas", 8)
$pnlRAMMetrics.Controls.Add($Script:lblAIRAMReward)
# RAMManager telemetry label
$Script:lblRAMTelemetry = New-Object System.Windows.Forms.Label
$Script:lblRAMTelemetry.Location = New-Object System.Drawing.Point(10, 290)
$Script:lblRAMTelemetry.Size = New-Object System.Drawing.Size(350, 12)
$Script:lblRAMTelemetry.Text = "RAMMgr: Q=0 D=0 W=0 R=0"
$Script:lblRAMTelemetry.ForeColor = $Script:Colors.TextDim
$Script:lblRAMTelemetry.Font = New-Object System.Drawing.Font("Consolas", 7)
$pnlRAMMetrics.Controls.Add($Script:lblRAMTelemetry)
# Telemetry timer: update label periodically
$Script:tmrRAMTelemetry = New-Object System.Windows.Forms.Timer
$Script:tmrRAMTelemetry.Interval = 2000
$Script:tmrRAMTelemetry.Add_Tick({
    try {
        if ($Script:WidgetData -and $Script:WidgetData.RAMManagerStats) {
            $tele = $Script:WidgetData.RAMManagerStats
            $q = $tele.QueueSize; $d = $tele.QueueDrops; $w = $tele.BackgroundWrites; $r = $tele.BackgroundRetries
            $Script:lblRAMTelemetry.Text = "RAMMgr: Q=$q D=$d W=$w R=$r"
            $Script:lblRAMTelemetry.ForeColor = if ($w -gt 0 -or $q -gt 0) { $Script:Colors.Success } else { $Script:Colors.TextDim }
        } elseif ($Script:UseRAMStorage) {
            $Script:lblRAMTelemetry.Text = "RAMMgr: (waiting for data...)"
            $Script:lblRAMTelemetry.ForeColor = $Script:Colors.TextDim
        } else {
            $Script:lblRAMTelemetry.Text = "RAMMgr: (disabled)"
            $Script:lblRAMTelemetry.ForeColor = $Script:Colors.TextDim
        }
    } catch { }
})
$Script:tmrRAMTelemetry.Start()
# Paint event handler dla wykresu RAM
$Script:picRAMChart.Add_Paint({
    param($sender, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $width = $sender.Width
        $height = $sender.Height
        # Pobierz dane z widgetData
        if (-not $Script:WidgetData -or -not $Script:WidgetData.RAMIntelligenceHistory) {
            # Brak danych - narysuj placeholder
            $font = New-Object System.Drawing.Font("Consolas", 10)
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(100, 100, 100))
            $text = "Waiting for RAM Intelligence data..."
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rect = New-Object System.Drawing.RectangleF(0, 0, $width, $height)
            $g.DrawString($text, $font, $brush, $rect, $sf)
            $font.Dispose()
            $brush.Dispose()
            $sf.Dispose()
            return
        }
        $history = $Script:WidgetData.RAMIntelligenceHistory
        if ($history.Count -eq 0) { return }
        # Rysuj od prawej do lewej (najnowsze po prawej)
        $pointSpacing = 20  # Piksele miedzy punktami
        $marginLeft = 40
        $marginRight = 10
        $marginTop = 10
        $marginBottom = 20
        $chartWidth = $width - $marginLeft - $marginRight
        $chartHeight = $height - $marginTop - $marginBottom
        # Skala Y dla RAM (0-100%)
        $maxRAM = 100.0
        $scaleY = $chartHeight / $maxRAM
        # Kolory
        $colorBg = [System.Drawing.Color]::FromArgb(26, 26, 26)          # #1A1A1A
        $colorRAMLine = [System.Drawing.Color]::FromArgb(80, 80, 80)     # Szary dla linii RAM
        $colorRAMFill = [System.Drawing.Color]::FromArgb(60, 60, 60)     # Ciemniejszy dla wypelnienia
        $colorDelta = [System.Drawing.Color]::FromArgb(0, 255, 255)      # #00FFFF Cyan
        $colorSpike = [System.Drawing.Color]::FromArgb(255, 0, 255)      # #FF00FF Magenta
        $colorTrend = [System.Drawing.Color]::FromArgb(255, 140, 0)      # #FF8C00 Orange
        $colorBaseline = [System.Drawing.Color]::FromArgb(50, 205, 50)   # #32CD32 Lime Green
        # Tlo
        $g.Clear($colorBg)
        # Osie i siatka
        $penGrid = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 40, 40), 1)
        $penAxis = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, 80, 80), 1)
        # Linia bazowa (0%)
        $baselineY = $marginTop + $chartHeight
        $g.DrawLine($penAxis, $marginLeft, $baselineY, $width - $marginRight, $baselineY)
        # Siatka pozioma (co 25%)
        for ($i = 0; $i -le 100; $i += 25) {
            $y = $marginTop + $chartHeight - ($i * $scaleY)
            $g.DrawLine($penGrid, $marginLeft, $y, $width - $marginRight, $y)
            # Etykiety Y
            $font = New-Object System.Drawing.Font("Consolas", 8)
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 150, 150))
            $label = "$i%"
            $g.DrawString($label, $font, $brush, 5, $y - 8)
            $font.Dispose()
            $brush.Dispose()
        }
        # Rysuj dane od prawej do lewej
        $pointsRAM = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        $pointsDelta = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        $pointsTrend = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'  #  V37.8.5 FIX: Linia trendu
        $currentX = $width - $marginRight
        for ($i = 0; $i -lt [Math]::Min($history.Count, 60); $i++) {
            $point = $history[$i]
            # Wspolrzedne punktu
            $ramValue = [Math]::Max(0, [Math]::Min(100, $point.RAM))
            $y = $marginTop + $chartHeight - ($ramValue * $scaleY)
            # Dodaj do listy punktow RAM
            $pointsRAM.Add([System.Drawing.PointF]::new($currentX, $y))
            # Delta - skaluj do wykresu (zakladam max delta ?20%)
            $deltaValue = $point.Delta
            $deltaScaled = ($deltaValue + 20) / 40.0 * 100  # Mapuj [-20, +20] na [0, 100]
            $deltaY = $marginTop + $chartHeight - ($deltaScaled * $scaleY)
            $pointsDelta.Add([System.Drawing.PointF]::new($currentX, $deltaY))
            if ($point.Trend) {
                $pointsTrend.Add([System.Drawing.PointF]::new($currentX, $y))
            }
            # Markery Spike/Trend
            if ($point.Spike) {
                # Spike marker - magenta pionowa linia
                $penSpike = New-Object System.Drawing.Pen($colorSpike, 3)
                $g.DrawLine($penSpike, $currentX, $marginTop, $currentX, $marginTop + $chartHeight)
                $penSpike.Dispose()
            }
            if ($point.RewardGiven) {
                $colorReward = if ($point.RewardValue -gt 2.0) {
                    [System.Drawing.Color]::Gold        # Duza nagroda
                } elseif ($point.RewardValue -gt 0) {
                    [System.Drawing.Color]::Yellow      # Normalna nagroda
                } else {
                    [System.Drawing.Color]::Red         # Kara
                }
                # Rysuj kolko/gwiazdke nad wykresem
                $starSize = if ($point.RewardValue -gt 2.0) { 10 } else { 8 }
                $starX = $currentX - $starSize/2
                $starY = $marginTop - 15
                $brushStar = New-Object System.Drawing.SolidBrush($colorReward)
                $g.FillEllipse($brushStar, $starX, $starY, $starSize, $starSize)
                # Dodaj border dla lepszej widocznosci
                $penStar = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1)
                $g.DrawEllipse($penStar, $starX, $starY, $starSize, $starSize)
                $brushStar.Dispose()
                $penStar.Dispose()
            }
            $currentX -= $pointSpacing
            if ($currentX -lt $marginLeft) { break }
        }
        # Rysuj wypelnienie pod linia RAM
        if ($pointsRAM.Count -ge 2) {
            # Dodaj punkty do zamkniecia obszaru
            $fillPoints = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
            $fillPoints.AddRange($pointsRAM)
            $fillPoints.Add([System.Drawing.PointF]::new($pointsRAM[$pointsRAM.Count - 1].X, $baselineY))
            $fillPoints.Add([System.Drawing.PointF]::new($pointsRAM[0].X, $baselineY))
            $brushFill = New-Object System.Drawing.SolidBrush($colorRAMFill)
            $g.FillPolygon($brushFill, $fillPoints.ToArray())
            $brushFill.Dispose()
        }
        # Rysuj linie RAM
        if ($pointsRAM.Count -ge 2) {
            $penRAM = New-Object System.Drawing.Pen($colorRAMLine, 2)
            $g.DrawLines($penRAM, $pointsRAM.ToArray())
            $penRAM.Dispose()
        }
        # Rysuj linie Delta (neon cyan)
        if ($pointsDelta.Count -ge 2) {
            $penDelta = New-Object System.Drawing.Pen($colorDelta, 2)
            $g.DrawLines($penDelta, $pointsDelta.ToArray())
            $penDelta.Dispose()
        }
        if ($pointsTrend.Count -ge 2) {
            $penTrend = New-Object System.Drawing.Pen($colorTrend, 3)
            $penTrend.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
            $g.DrawLines($penTrend, $pointsTrend.ToArray())
            $penTrend.Dispose()
        }
        # Etykieta ostatniej aplikacji (najnowszy punkt)
        if ($history.Count -gt 0 -and $history[0].App) {
            $font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 200, 200))
            $appText = "App: $($history[0].App)"
            $g.DrawString($appText, $font, $brush, $width - $marginRight - 200, $marginTop + 5)
            $font.Dispose()
            $brush.Dispose()
        }
        # Legenda
        $legendY = $marginTop + 5
        $legendX = $marginLeft + 10
        $fontLegend = New-Object System.Drawing.Font("Consolas", 8)
        $brushWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        # RAM
        $brushLegend = New-Object System.Drawing.SolidBrush($colorRAMLine)
        $g.FillRectangle($brushLegend, $legendX, $legendY, 15, 10)
        $g.DrawString("RAM", $fontLegend, $brushWhite, $legendX + 20, $legendY - 2)
        $brushLegend.Dispose()
        # Delta
        $legendX += 80
        $brushLegend = New-Object System.Drawing.SolidBrush($colorDelta)
        $g.FillRectangle($brushLegend, $legendX, $legendY, 15, 10)
        $g.DrawString("Delta", $fontLegend, $brushWhite, $legendX + 20, $legendY - 2)
        $brushLegend.Dispose()
        # Spike
        $legendX += 80
        $brushLegend = New-Object System.Drawing.SolidBrush($colorSpike)
        $g.FillRectangle($brushLegend, $legendX, $legendY, 15, 10)
        $g.DrawString("Spike", $fontLegend, $brushWhite, $legendX + 20, $legendY - 2)
        $brushLegend.Dispose()
        # Trend
        $legendX += 80
        $penLegendTrend = New-Object System.Drawing.Pen($colorTrend, 2)
        $penLegendTrend.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $g.DrawLine($penLegendTrend, $legendX, $legendY + 5, $legendX + 15, $legendY + 5)
        $g.DrawString("Trend", $fontLegend, $brushWhite, $legendX + 20, $legendY - 2)
        $penLegendTrend.Dispose()
        # Reward Markers (kolka nad wykresem)
        $legendX += 80
        $colorRewardLegend = [System.Drawing.Color]::Yellow
        $brushReward = New-Object System.Drawing.SolidBrush($colorRewardLegend)
        $g.FillEllipse($brushReward, $legendX + 3, $legendY + 2, 8, 8)
        $penRewardBorder = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1)
        $g.DrawEllipse($penRewardBorder, $legendX + 3, $legendY + 2, 8, 8)
        $g.DrawString("Reward", $fontLegend, $brushWhite, $legendX + 20, $legendY - 2)
        $brushReward.Dispose()
        $penRewardBorder.Dispose()
        $brushWhite.Dispose()
        $fontLegend.Dispose()
        $penGrid.Dispose()
        $penAxis.Dispose()
    } catch {
        # Jesli blad rysowania, nic nie rob
    }
})
# #
# #
$lblProBalanceTitle = New-SectionLabel -Parent $tabSensors -Text "[PROBALANCE - CPU HOG RESTRAINT]" -X 10 -Y 605
$lblProBalanceTitle.ForeColor = [System.Drawing.Color]::FromArgb(255, 165, 0)
# ProBalance Chart (lewa strona)
$Script:picProBalanceChart = New-Object System.Windows.Forms.PictureBox
$Script:picProBalanceChart.Location = New-Object System.Drawing.Point(10, 630)
$Script:picProBalanceChart.Size = New-Object System.Drawing.Size(760, 165)
$Script:picProBalanceChart.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 26)
$Script:picProBalanceChart.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$tabSensors.Controls.Add($Script:picProBalanceChart)
# ProBalance Metrics Panel (prawa strona)
$pnlProBalanceMetrics = New-Object System.Windows.Forms.Panel
$pnlProBalanceMetrics.Location = New-Object System.Drawing.Point(780, 630)
$pnlProBalanceMetrics.Size = New-Object System.Drawing.Size(380, 165)
$pnlProBalanceMetrics.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$pnlProBalanceMetrics.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$tabSensors.Controls.Add($pnlProBalanceMetrics)
# ProBalance Panel Labels
$lblPBTitle = New-Object System.Windows.Forms.Label
$lblPBTitle.Location = New-Object System.Drawing.Point(10, 5)
$lblPBTitle.Size = New-Object System.Drawing.Size(350, 20)
$lblPBTitle.Text = "[PROBALANCE STATUS]"
$lblPBTitle.ForeColor = [System.Drawing.Color]::FromArgb(255, 165, 0)
$lblPBTitle.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$pnlProBalanceMetrics.Controls.Add($lblPBTitle)
$Script:lblPBEnabled = New-Object System.Windows.Forms.Label
$Script:lblPBEnabled.Location = New-Object System.Drawing.Point(10, 28)
$Script:lblPBEnabled.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblPBEnabled.Text = "Status: - Enabled"
$Script:lblPBEnabled.ForeColor = [System.Drawing.Color]::LimeGreen
$Script:lblPBEnabled.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlProBalanceMetrics.Controls.Add($Script:lblPBEnabled)
$Script:lblPBThrottled = New-Object System.Windows.Forms.Label
$Script:lblPBThrottled.Location = New-Object System.Drawing.Point(10, 44)
$Script:lblPBThrottled.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblPBThrottled.Text = "Currently Throttled: 0"
$Script:lblPBThrottled.ForeColor = [System.Drawing.Color]::White
$Script:lblPBThrottled.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlProBalanceMetrics.Controls.Add($Script:lblPBThrottled)
$Script:lblPBThreshold = New-Object System.Windows.Forms.Label
$Script:lblPBThreshold.Location = New-Object System.Drawing.Point(10, 60)
$Script:lblPBThreshold.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblPBThreshold.Text = "CPU Threshold: 80%"
$Script:lblPBThreshold.ForeColor = [System.Drawing.Color]::Gray
$Script:lblPBThreshold.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlProBalanceMetrics.Controls.Add($Script:lblPBThreshold)
$Script:lblPBTotals = New-Object System.Windows.Forms.Label
$Script:lblPBTotals.Location = New-Object System.Drawing.Point(10, 80)
$Script:lblPBTotals.Size = New-Object System.Drawing.Size(350, 15)
$Script:lblPBTotals.Text = "Throttles: 0  |  Restores: 0"
$Script:lblPBTotals.ForeColor = [System.Drawing.Color]::White
$Script:lblPBTotals.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlProBalanceMetrics.Controls.Add($Script:lblPBTotals)
$lblPBProcessesHeader = New-Object System.Windows.Forms.Label
$lblPBProcessesHeader.Location = New-Object System.Drawing.Point(10, 102)
$lblPBProcessesHeader.Size = New-Object System.Drawing.Size(350, 15)
$lblPBProcessesHeader.Text = "[THROTTLED PROCESSES]"
$lblPBProcessesHeader.ForeColor = [System.Drawing.Color]::FromArgb(255, 165, 0)
$lblPBProcessesHeader.Font = New-Object System.Drawing.Font("Consolas", 8, [System.Drawing.FontStyle]::Bold)
$pnlProBalanceMetrics.Controls.Add($lblPBProcessesHeader)
$Script:lblPBProcesses = New-Object System.Windows.Forms.Label
$Script:lblPBProcesses.Location = New-Object System.Drawing.Point(10, 118)
$Script:lblPBProcesses.Size = New-Object System.Drawing.Size(350, 25)
$Script:lblPBProcesses.Text = "(none)"
$Script:lblPBProcesses.ForeColor = [System.Drawing.Color]::Gray
$Script:lblPBProcesses.Font = New-Object System.Drawing.Font("Consolas", 8)
$pnlProBalanceMetrics.Controls.Add($Script:lblPBProcesses)
$lblPBCustomThreshold = New-Object System.Windows.Forms.Label
$lblPBCustomThreshold.Location = New-Object System.Drawing.Point(10, 145)
$lblPBCustomThreshold.Size = New-Object System.Drawing.Size(130, 15)
$lblPBCustomThreshold.Text = "Custom Threshold:"
$lblPBCustomThreshold.ForeColor = [System.Drawing.Color]::FromArgb(255, 165, 0)
$lblPBCustomThreshold.Font = New-Object System.Drawing.Font("Consolas", 8, [System.Drawing.FontStyle]::Bold)
$pnlProBalanceMetrics.Controls.Add($lblPBCustomThreshold)
$Script:numPBThreshold = New-Object System.Windows.Forms.NumericUpDown
$Script:numPBThreshold.Location = New-Object System.Drawing.Point(145, 143)
$Script:numPBThreshold.Size = New-Object System.Drawing.Size(60, 20)
$Script:numPBThreshold.Minimum = 20
$Script:numPBThreshold.Maximum = 90
$Script:numPBThreshold.Value = 70
$Script:numPBThreshold.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
$Script:numPBThreshold.ForeColor = [System.Drawing.Color]::White
$Script:numPBThreshold.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlProBalanceMetrics.Controls.Add($Script:numPBThreshold)
$lblPBPercent = New-Object System.Windows.Forms.Label
$lblPBPercent.Location = New-Object System.Drawing.Point(210, 145)
$lblPBPercent.Size = New-Object System.Drawing.Size(20, 15)
$lblPBPercent.Text = "%"
$lblPBPercent.ForeColor = [System.Drawing.Color]::White
$lblPBPercent.Font = New-Object System.Drawing.Font("Consolas", 9)
$pnlProBalanceMetrics.Controls.Add($lblPBPercent)
$Script:btnPBApply = New-Object System.Windows.Forms.Button
$Script:btnPBApply.Location = New-Object System.Drawing.Point(235, 141)
$Script:btnPBApply.Size = New-Object System.Drawing.Size(130, 22)
$Script:btnPBApply.Text = "Zapisz i zastosuj"
$Script:btnPBApply.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$Script:btnPBApply.ForeColor = [System.Drawing.Color]::White
$Script:btnPBApply.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$Script:btnPBApply.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(255, 165, 0)
$Script:btnPBApply.Font = New-Object System.Drawing.Font("Consolas", 8)
$Script:btnPBApply.Cursor = [System.Windows.Forms.Cursors]::Hand
$Script:btnPBApply.Add_Click({
    try {
        $newThreshold = [int]$Script:numPBThreshold.Value
        # Zapisz do pliku ProBalanceConfig.json
        $configPath = Join-Path $Script:ConfigDir "ProBalanceConfig.json"
        $config = @{
            ThrottleThreshold = $newThreshold
            LastModified = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        $json = $config | ConvertTo-Json -Depth 3 -Compress
        [System.IO.File]::WriteAllText($configPath, $json, [System.Text.Encoding]::UTF8)
        # Wyslij komende do ENGINE
        $commandPath = Join-Path $Script:ConfigDir "WidgetCommand.txt"
        $command = "ProBalanceThreshold:$newThreshold"
        [System.IO.File]::WriteAllText($commandPath, $command, [System.Text.Encoding]::UTF8)
        # Pokaz potwierdzenie
        $Script:btnPBApply.Text = "- Zastosowano!"
        $Script:btnPBApply.BackColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
        # Przywroc tekst po 2s
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 2000
        $timer.Add_Tick({
            $Script:btnPBApply.Text = "Zapisz i zastosuj"
            $Script:btnPBApply.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
            $this.Stop()
            $this.Dispose()
        })
        $timer.Start()
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Blad: $_", "ProBalance", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})
$pnlProBalanceMetrics.Controls.Add($Script:btnPBApply)
# ProBalance Chart Paint Handler
$Script:picProBalanceChart.Add_Paint({
    param($sender, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $width = $sender.Width
        $height = $sender.Height
        if (-not $Script:WidgetData -or -not $Script:WidgetData.ProBalanceHistory) {
            $font = New-Object System.Drawing.Font("Consolas", 10)
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(100, 100, 100))
            $text = "Waiting for ProBalance data..."
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rect = New-Object System.Drawing.RectangleF(0, 0, $width, $height)
            $g.DrawString($text, $font, $brush, $rect, $sf)
            $font.Dispose(); $brush.Dispose(); $sf.Dispose()
            return
        }
        $history = $Script:WidgetData.ProBalanceHistory
        if ($history.Count -eq 0) { return }
        $marginLeft = 50; $marginRight = 10; $marginTop = 25; $marginBottom = 20
        $chartWidth = $width - $marginLeft - $marginRight
        $chartHeight = $height - $marginTop - $marginBottom
        $colorBg = [System.Drawing.Color]::FromArgb(26, 26, 26)
        $colorThrottled = [System.Drawing.Color]::FromArgb(255, 165, 0)
        $colorCPU = [System.Drawing.Color]::FromArgb(0, 200, 255)
        $colorThreshold = [System.Drawing.Color]::FromArgb(255, 0, 0)
        $g.Clear($colorBg)
        $penGrid = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 40, 40), 1)
        $penAxis = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, 80, 80), 1)
        $baselineY = $marginTop + $chartHeight
        $g.DrawLine($penAxis, $marginLeft, $baselineY, $width - $marginRight, $baselineY)
        $maxThrottled = 5
        foreach ($point in $history) {
            if ($point.Throttled -gt $maxThrottled) { $maxThrottled = $point.Throttled + 2 }
        }
        $scaleYThrottled = $chartHeight / $maxThrottled
        $scaleYCPU = $chartHeight / 100
        # Threshold line (red dashed)
        $threshold = if ($history[0].Threshold) { $history[0].Threshold } else { 80 }
        $thresholdY = $marginTop + $chartHeight - ($threshold * $scaleYCPU)
        $penThreshold = New-Object System.Drawing.Pen($colorThreshold, 1)
        $penThreshold.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $g.DrawLine($penThreshold, $marginLeft, $thresholdY, $width - $marginRight, $thresholdY)
        $penThreshold.Dispose()
        # Draw data
        $pointsThrottled = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        $pointsCPU = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        $pointSpacing = 20
        $currentX = $width - $marginRight
        for ($i = 0; $i -lt $history.Count -and $currentX -gt $marginLeft; $i++) {
            $point = $history[$i]
            $throttled = if ($point.Throttled) { $point.Throttled } else { 0 }
            $yThrottled = $marginTop + $chartHeight - ($throttled * $scaleYThrottled)
            $pointsThrottled.Add([System.Drawing.PointF]::new($currentX, $yThrottled))
            $cpu = if ($point.CPU) { $point.CPU } else { 0 }
            $yCPU = $marginTop + $chartHeight - ($cpu * $scaleYCPU)
            $pointsCPU.Add([System.Drawing.PointF]::new($currentX, $yCPU))
            $currentX -= $pointSpacing
        }
        # Draw bars for throttled
        foreach ($pt in $pointsThrottled) {
            $barHeight = $baselineY - $pt.Y
            if ($barHeight -gt 1) {
                $brushBar = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 255, 165, 0))
                $g.FillRectangle($brushBar, $pt.X - 5, $pt.Y, 10, $barHeight)
                $brushBar.Dispose()
            }
        }
        # Draw CPU line
        if ($pointsCPU.Count -ge 2) {
            $penCPU = New-Object System.Drawing.Pen($colorCPU, 2)
            $g.DrawLines($penCPU, $pointsCPU.ToArray())
            $penCPU.Dispose()
        }
        # Legend
        $fontLegend = New-Object System.Drawing.Font("Consolas", 8)
        $brushWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $legendY = 5; $legendX = $marginLeft + 10
        $brushLegend = New-Object System.Drawing.SolidBrush($colorThrottled)
        $g.FillRectangle($brushLegend, $legendX, $legendY, 15, 10)
        $g.DrawString("Throttled", $fontLegend, $brushWhite, $legendX + 20, $legendY - 2)
        $brushLegend.Dispose()
        $legendX += 100
        $brushLegend = New-Object System.Drawing.SolidBrush($colorCPU)
        $g.FillRectangle($brushLegend, $legendX, $legendY, 15, 10)
        $g.DrawString("CPU%", $fontLegend, $brushWhite, $legendX + 20, $legendY - 2)
        $brushLegend.Dispose()
        $legendX += 80
        $brushLegend = New-Object System.Drawing.SolidBrush($colorThreshold)
        $g.FillRectangle($brushLegend, $legendX, $legendY, 15, 10)
        $g.DrawString("Threshold ($threshold%)", $fontLegend, $brushWhite, $legendX + 20, $legendY - 2)
        $brushLegend.Dispose()
        $brushWhite.Dispose(); $fontLegend.Dispose(); $penGrid.Dispose(); $penAxis.Dispose()
    } catch { }
})
# #
# TAB 2: AI DETAILS
# #
$tabAI = New-Object System.Windows.Forms.TabPage
$tabAI.Text = "AI Details"
$tabAI.BackColor = $Script:Colors.Background
$tabAI.AutoScroll = $true  #  v39.5.1: Enable scroll
$tabs.TabPages.Add($tabAI)
$aiComponents = @(
    @{ Name = "Neural Brain"; Key = "Brain" }, @{ Name = "Q-Learning"; Key = "QLearning" }, @{ Name = "Bandit"; Key = "Bandit" },
    @{ Name = "Genetic"; Key = "Genetic" }, @{ Name = "Ensemble"; Key = "Ensemble" }, @{ Name = "Energy"; Key = "Energy" },
    @{ Name = "Prophet"; Key = "Prophet" }, @{ Name = "SelfTuner"; Key = "SelfTuner" }, @{ Name = "Chain"; Key = "Chain" },
    @{ Name = "Anomaly"; Key = "Anomaly" }, @{ Name = "Thermal"; Key = "Thermal" }, @{ Name = "Patterns"; Key = "Patterns" }
)
$Script:AILabels = @{}; $aiX = 10; $aiY = 10; $aiCardW = 220; $aiCardH = 70
foreach ($comp in $aiComponents) {
    $panel = New-Panel -Parent $tabAI -X $aiX -Y $aiY -Width $aiCardW -Height $aiCardH -BackColor $Script:Colors.Card
    $null = New-Label -Parent $panel -Text $comp.Name -X 10 -Y 8 -Width 200 -Height 22 -FontSize 10 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
    $valueLbl = New-Label -Parent $panel -Text "---" -X 10 -Y 35 -Width 200 -Height 28 -FontSize 11 -ForeColor $Script:Colors.Text
    $Script:AILabels[$comp.Key] = $valueLbl
    $aiX += $aiCardW + 10; if ($aiX + $aiCardW -gt 1150) { $aiX = 10; $aiY += $aiCardH + 10 }
}
$lblDecisionTitle = New-SectionLabel -Parent $tabAI -Text "[DECISION INFO]" -X 10 -Y 260
$Script:lblDecisionReason = New-Label -Parent $tabAI -Text "  Current: ---" -X 10 -Y 285 -Width 1100 -Height 25 -FontSize 11 -ForeColor $Script:Colors.Cyan
$Script:lblDecisionStats = New-Label -Parent $tabAI -Text "  Decisions: 0 | Switches: 0 | Runtime: 0 min" -X 10 -Y 310 -Width 550 -Height 22 -ForeColor $Script:Colors.TextDim
$Script:lblCoordinatorStatus = New-Label -Parent $tabAI -Text "   Coordinator: QLearning | Transfers: 0" -X 570 -Y 310 -Width 550 -Height 22 -ForeColor $Script:Colors.Purple
# #
# #
$lblRAMTitle = New-SectionLabel -Parent $tabAI -Text "[RAM MONITOR]" -X 10 -Y 337
$Script:lblRAMStatus = New-Label -Parent $tabAI -Text "  RAM: [#] 0%  |  Delta: +0%  |  Status: - Normal  |  Learned: 0 apps  |  Spikes: 0" -X 10 -Y 360 -Width 700 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Success
# #
# #
$lblHistoryMapTitle = New-SectionLabel -Parent $tabAI -Text "[DECISION HISTORY MAP - Last 60s]" -X 10 -Y 390
# Panel dla wykresu
$panelHistoryMap = New-Panel -Parent $tabAI -X 10 -Y 420 -Width 1110 -Height 240 -BackColor $Script:Colors.Card
# PictureBox dla custom drawing
$Script:chartHistoryMap = New-Object System.Windows.Forms.PictureBox
$Script:chartHistoryMap.Location = New-Object System.Drawing.Point(10, 10)
$Script:chartHistoryMap.Size = New-Object System.Drawing.Size(1090, 180)
$Script:chartHistoryMap.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 30)
$panelHistoryMap.Controls.Add($Script:chartHistoryMap)
# Legenda
$lblLegend = New-Label -Parent $panelHistoryMap -Text " CPU Load   AI Response (Power)  - Prophet Prediction   Activity Boost" -X 10 -Y 195 -Width 900 -Height 20 -FontSize 9 -ForeColor $Script:Colors.TextDim
$Script:lblHistoryStats = New-Label -Parent $panelHistoryMap -Text "Data points: 0 | Prediction lead: 0s" -X 740 -Y 195 -Width 350 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Success -Align ([System.Drawing.ContentAlignment]::MiddleRight)
# Paint handler dla wykresu
$Script:chartHistoryMap.Add_Paint({
    param($sender, $e)
    if (-not $Script:DecisionHistoryData -or $Script:DecisionHistoryData.Count -eq 0) { return }
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $width = $sender.Width
    $height = $sender.Height
    $padding = 40
    $chartWidth = $width - (2 * $padding)
    $chartHeight = $height - (2 * $padding)
    # Background grid
    $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 40, 45), 1)
    for ($i = 0; $i -le 10; $i++) {
        $y = $padding + ($i * $chartHeight / 10)
        $g.DrawLine($gridPen, $padding, $y, $width - $padding, $y)
    }
    for ($i = 0; $i -le 12; $i++) {
        $x = $padding + ($i * $chartWidth / 12)
        $g.DrawLine($gridPen, $x, $padding, $x, $height - $padding)
    }
    $gridPen.Dispose()
    # Axis labels
    $font = New-Object System.Drawing.Font("Segoe UI", 8)
    $labelBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 150, 160))
    $g.DrawString("100%", $font, $labelBrush, 5, $padding - 8)
    $g.DrawString("50%", $font, $labelBrush, 10, $padding + $chartHeight/2 - 8)
    $g.DrawString("0%", $font, $labelBrush, 15, $height - $padding - 8)
    $g.DrawString("60s", $font, $labelBrush, $padding - 5, $height - $padding + 15)
    $g.DrawString("30s", $font, $labelBrush, $padding + $chartWidth/2 - 10, $height - $padding + 15)
    $g.DrawString("0s", $font, $labelBrush, $width - $padding - 10, $height - $padding + 15)
    $labelBrush.Dispose()
    $font.Dispose()
    # Draw lines
    $data = $Script:DecisionHistoryData
    $points = $data.Count
    if ($points -lt 2) { return }
    $xStep = $chartWidth / [Math]::Max(1, $points - 1)
    # Red line - CPU Load
    $cpuPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(220, 60, 60), 2)
    $cpuPoints = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
    for ($i = 0; $i -lt $points; $i++) {
        $x = $width - $padding - ($i * $xStep)
        $cpuPercent = [Math]::Min(100, [Math]::Max(0, [int]$data[$i].CPU))
        $y = $height - $padding - ($cpuPercent * $chartHeight / 100.0)
        $cpuPoints.Add((New-Object System.Drawing.PointF($x, $y)))
    }
    if ($cpuPoints.Count -gt 1) { $g.DrawLines($cpuPen, $cpuPoints.ToArray()) }
    $cpuPen.Dispose()
    # Green line - AI Power
    $powerPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 220, 60), 2)
    $powerPoints = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
    for ($i = 0; $i -lt $points; $i++) {
        $x = $width - $padding - ($i * $xStep)
        $powerPercent = [Math]::Min(100, [Math]::Max(0, [int]($data[$i].Power * 2)))  # Scale power to %
        $y = $height - $padding - ($powerPercent * $chartHeight / 100.0)
        $powerPoints.Add((New-Object System.Drawing.PointF($x, $y)))
    }
    if ($powerPoints.Count -gt 1) { $g.DrawLines($powerPen, $powerPoints.ToArray()) }
    $powerPen.Dispose()
    # Blue line - Prophet Prediction (if available)
    if ($data[0].Predicted -gt 0) {
        $predPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 150, 220), 2)
        $predPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $predPoints = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
        for ($i = 0; $i -lt $points; $i++) {
            $x = $width - $padding - ($i * $xStep)
            $predPercent = [Math]::Min(100, [Math]::Max(0, [int]$data[$i].Predicted))
            $y = $height - $padding - ($predPercent * $chartHeight / 100.0)
            $predPoints.Add((New-Object System.Drawing.PointF($x, $y)))
        }
        if ($predPoints.Count -gt 1) { $g.DrawLines($predPen, $predPoints.ToArray()) }
        $predPen.Dispose()
    }
    # Yellow line - Activity Boost (v40)
    $boostPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 200, 60), 2)
    $boostPoints = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
    for ($i = 0; $i -lt $points; $i++) {
        $x = $width - $padding - ($i * $xStep)
        # ActivityBoost: 0 = brak, 100 = aktywny boost
        $boostVal = if ($data[$i].ActivityBoost) { 100 } else { 0 }
        $y = $height - $padding - ($boostVal * $chartHeight / 100.0)
        $boostPoints.Add((New-Object System.Drawing.PointF($x, $y)))
    }
    if ($boostPoints.Count -gt 1) { $g.DrawLines($boostPen, $boostPoints.ToArray()) }
    $boostPen.Dispose()
})
# Initialize history data
$Script:DecisionHistoryData = @()
# #
# TAB 3: CONTROL
# #
$tabControl = New-Object System.Windows.Forms.TabPage
$tabControl.Text = "Control & TDP"
$tabControl.BackColor = $Script:Colors.Background
$tabControl.AutoScroll = $true  #  v39.5.1: Enable scroll
$tabs.TabPages.Add($tabControl)
$lblPowerTitle = New-SectionLabel -Parent $tabControl -Text "[POWER MODE] - zmiany natychmiastowe" -X 10 -Y 10
$btnSilent = New-Button -Parent $tabControl -Text "SILENT" -X 10 -Y 38 -Width 130 -Height 50 -BackColor $Script:Colors.Silent -ForeColor $Script:Colors.Background -OnClick { 
    if (Send-Command "SILENT") { 
        [System.Windows.Forms.MessageBox]::Show("✓ Tryb SILENT aktywowany`n`nAI nadal się uczy, ale wymuszono tryb cichy.", "Zmiana trybu", "OK", "Information")
    }
}
$btnSilentLock = New-Button -Parent $tabControl -Text "SILENT LOCK" -X 150 -Y 38 -Width 130 -Height 50 -BackColor ([System.Drawing.Color]::FromArgb(50,50,50)) -ForeColor $Script:Colors.Silent -OnClick { 
    if (Send-Command "SILENT_LOCK") { 
        [System.Windows.Forms.MessageBox]::Show("✓ Tryb SILENT LOCK aktywowany`n`nAI WYŁĄCZONE - całkowita cisza.`nWentylatory na minimum.", "Zmiana trybu", "OK", "Information")
    }
}
$btnBalanced = New-Button -Parent $tabControl -Text "BALANCED" -X 290 -Y 38 -Width 130 -Height 50 -BackColor $Script:Colors.Balanced -ForeColor $Script:Colors.Background -OnClick { 
    if (Send-Command "BALANCED") { 
        [System.Windows.Forms.MessageBox]::Show("✓ Tryb BALANCED aktywowany`n`nAI nadal się uczy, ale wymuszono tryb zrównoważony.", "Zmiana trybu", "OK", "Information")
    }
}
$btnTurbo = New-Button -Parent $tabControl -Text "TURBO" -X 430 -Y 38 -Width 130 -Height 50 -BackColor $Script:Colors.Turbo -ForeColor $Script:Colors.Background -OnClick { 
    if (Send-Command "TURBO") { 
        [System.Windows.Forms.MessageBox]::Show("✓ Tryb TURBO aktywowany`n`nAI nadal się uczy, ale wymuszono maksymalną wydajność.", "Zmiana trybu", "OK", "Information")
    }
}
$btnExtreme = New-Button -Parent $tabControl -Text "EXTREME" -X 570 -Y 38 -Width 130 -Height 50 -BackColor $Script:Colors.Extreme -ForeColor $Script:Colors.TextBright -OnClick { 
    if (Send-Command "EXTREME") { 
        [System.Windows.Forms.MessageBox]::Show("✓ Tryb EXTREME aktywowany`n`nAI WYŁĄCZONE - maksymalna moc!`nUWAGA: Wyższe temperatury i głośność.", "Zmiana trybu", "OK", "Warning")
    }
}
$lblAICtrl = New-SectionLabel -Parent $tabControl -Text "[AI CONTROL] - zmiany natychmiastowe" -X 10 -Y 100
$btnAIToggle = New-Button -Parent $tabControl -Text "AI ON/OFF" -X 10 -Y 128 -Width 130 -Height 45 -BackColor $Script:Colors.Purple -ForeColor $Script:Colors.TextBright -OnClick { 
    if (Send-Command "AI") { 
        [System.Windows.Forms.MessageBox]::Show("✓ AI przełączone`n`nSprawdź status w panelu po prawej.", "AI Control", "OK", "Information")
    }
}
$btnDebug = New-Button -Parent $tabControl -Text "DEBUG" -X 150 -Y 128 -Width 130 -Height 45 -BackColor $Script:Colors.Card -OnClick { 
    if (Send-Command "DEBUG") { 
        [System.Windows.Forms.MessageBox]::Show("✓ Tryb DEBUG przełączony`n`nSzczegółowe logi w Activity Log.", "Debug", "OK", "Information")
    }
}
$btnReset = New-Button -Parent $tabControl -Text "RESET AI" -X 290 -Y 128 -Width 130 -Height 45 -BackColor $Script:Colors.Card -OnClick { 
    $result = [System.Windows.Forms.MessageBox]::Show("Czy na pewno zresetować AI?`n`nTo usunie:`n- Nauczone progi godzinowe`n- Zatwierdzone boosty aplikacji`n`nNie usunie: ProphetMemory, Q-Learning", "Potwierdź reset AI", "YesNo", "Warning")
    if ($result -eq "Yes") {
        if (Send-Command "RESET") { 
            [System.Windows.Forms.MessageBox]::Show("✓ AI zresetowane`n`nSilniki AI zaczną się uczyć od nowa.", "Reset AI", "OK", "Information")
        }
    }
}
$Script:btnEcoMode = New-Button -Parent $tabControl -Text "○ ECO OFF" -X 430 -Y 128 -Width 130 -Height 45 -BackColor $Script:Colors.Card -OnClick { 
    if (Send-Command "ECO") { 
        [System.Windows.Forms.MessageBox]::Show("✓ EcoMode przełączony`n`nEcoMode ON = agresywny Silent, opóźniony Turbo`nEcoMode OFF = normalne progi", "EcoMode", "OK", "Information")
    }
}
$lblSysCtrl = New-SectionLabel -Parent $tabControl -Text "[SYSTEM] - zmiany natychmiastowe" -X 10 -Y 185
$btnSave = New-Button -Parent $tabControl -Text "SAVE STATE" -X 10 -Y 213 -Width 130 -Height 45 -BackColor $Script:Colors.Success -ForeColor $Script:Colors.Background -OnClick { 
    if (Send-Command "SAVE") { 
        [System.Windows.Forms.MessageBox]::Show("✓ Stan zapisany!`n`nZapisano:`n- Neural Brain`n- Prophet Memory`n- Anomaly Profiles`n- Load Patterns", "Zapis stanu", "OK", "Information")
    }
}
$toolTip.SetToolTip($btnSave, "✓ Zapisuje aktualny stan CPU i ustawienia optymalizacji. Pozwala szybko powrocic do tej konfiguracji.")
$btnTrimRAM = New-Button -Parent $tabControl -Text "TRIM RAM" -X 150 -Y 213 -Width 130 -Height 45 -BackColor ([System.Drawing.Color]::FromArgb(60,100,60)) -ForeColor $Script:Colors.TextBright -OnClick {
    $before = [Math]::Round((Get-Process | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    $count = Clear-RAM
    $after = [Math]::Round((Get-Process | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    $freed = $before - $after
    [System.Windows.Forms.MessageBox]::Show("✓ RAM wyczyszczony!`n`nProcesy: $count`nZwolniono: $freed MB`n`nPrzed: $before MB`nPo: $after MB", "Trim RAM - Sukces", "OK", "Information")
}
$btnExit = New-Button -Parent $tabControl -Text "EXIT ENGINE" -X 290 -Y 213 -Width 130 -Height 45 -BackColor $Script:Colors.Danger -ForeColor $Script:Colors.TextBright -OnClick {
    if ([System.Windows.Forms.MessageBox]::Show("Czy na pewno zatrzymać ENGINE?`n`nTo wyłączy całą optymalizację CPU!", "Potwierdź zamknięcie", "YesNo", "Warning") -eq "Yes") { 
        Send-Command "EXIT"
        [System.Windows.Forms.MessageBox]::Show("✓ Komenda EXIT wysłana`n`nENGINE powinien się zamknąć w ciągu kilku sekund.", "EXIT", "OK", "Information")
    }
}
# Status Panel
$panelStatus = New-Panel -Parent $tabControl -X 750 -Y 10 -Width 380 -Height 260 -BackColor $Script:Colors.Card
$lblStatusTitle = New-Label -Parent $panelStatus -Text "CURRENT STATUS" -X 10 -Y 10 -Width 360 -Height 30 -FontSize 12 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
$Script:lblCtrlMode = New-Label -Parent $panelStatus -Text "---" -X 10 -Y 50 -Width 360 -Height 50 -FontSize 22 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Balanced -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
$Script:lblCtrlAI = New-Label -Parent $panelStatus -Text "AI: ---" -X 10 -Y 105 -Width 360 -Height 30 -FontSize 13 -ForeColor $Script:Colors.Text -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
$Script:lblCtrlCPU = New-Label -Parent $panelStatus -Text "CPU: --% | Temp: --C" -X 10 -Y 145 -Width 360 -Height 25 -FontSize 11 -ForeColor $Script:Colors.ChartCPU -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
$Script:lblCtrlApp = New-Label -Parent $panelStatus -Text "App: ---" -X 10 -Y 175 -Width 360 -Height 22 -FontSize 9 -ForeColor $Script:Colors.TextDim -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
$Script:lblCtrlReason = New-Label -Parent $panelStatus -Text "---" -X 10 -Y 200 -Width 360 -Height 50 -FontSize 9 -ForeColor $Script:Colors.Cyan -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
# #
# TDP CONTROL (RyzenAdj) -  V37.8.5: Zintegrowane z zakladka Control
# #
$lblTDPTitle = New-SectionLabel -Parent $tabControl -Text "[TDP PROFILES (RYZENADJ)]" -X 10 -Y 280
$Script:lblTDPStatus = New-Label -Parent $tabControl -Text "RyzenAdj: Checking..." -X 10 -Y 308 -Width 600 -Height 22 -ForeColor $Script:Colors.Warning
$Script:lblTDPCurrent = New-Label -Parent $tabControl -Text "Current: ---" -X 10 -Y 333 -Width 800 -Height 22 -ForeColor $Script:Colors.Cyan
$Script:TDPControls = @{}
$tdpY = 365
foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
    $gb = New-GroupBox -Parent $tabControl -Title "$mode TDP Profile" -X 10 -Y $tdpY -Width 1100 -Height 70
    $tdpData = if ($Script:TDPConfig[$mode]) { $Script:TDPConfig[$mode] } else { $Script:DefaultTDP[$mode] }
    $null = New-Label -Parent $gb -Text "STAPM (W):" -X 15 -Y 28 -Width 90 -Height 22
    $numSTAPM = New-NumericUpDown -Parent $gb -X 110 -Y 25 -Min 5 -Max 65 -Value $tdpData.STAPM -Width 70
    $toolTip.SetToolTip($numSTAPM, " STAPM - podstawowy limit mocy procesora w watach. Kontroluje ciagle zuzycie energii CPU.")
    $null = New-Label -Parent $gb -Text "Fast (W):" -X 200 -Y 28 -Width 70 -Height 22
    $numFast = New-NumericUpDown -Parent $gb -X 275 -Y 25 -Min 5 -Max 65 -Value $tdpData.Fast -Width 70
    $toolTip.SetToolTip($numFast, " PPT Fast - krotkotrwale boosty mocy dla wydajnosci. Wyzsze wartosci = wiecej mocy na krotko.")
    $null = New-Label -Parent $gb -Text "Slow (W):" -X 365 -Y 28 -Width 70 -Height 22
    $numSlow = New-NumericUpDown -Parent $gb -X 440 -Y 25 -Min 5 -Max 65 -Value $tdpData.Slow -Width 70
    $toolTip.SetToolTip($numSlow, "- PPT Slow - dlugotrwaly limit mocy. Kontroluje stabilna moc podczas dluzszej pracy.")
    $null = New-Label -Parent $gb -Text "Tctl (degC):" -X 530 -Y 28 -Width 70 -Height 22
    $numTctl = New-NumericUpDown -Parent $gb -X 605 -Y 25 -Min 60 -Max 105 -Value $tdpData.Tctl -Width 70
    $toolTip.SetToolTip($numTctl, "- Tctl - maksymalna temperatura CPU. Gdy zostanie osiagnieta, procesor sie zaduszka.")
    $btnApply = New-Button -Parent $gb -Text "Apply Now" -X 700 -Y 22 -Width 100 -Height 30 -BackColor $Script:Colors.AccentDim -ForeColor $Script:Colors.TextBright
    $btnApply.Tag = $mode
    $toolTip.SetToolTip($btnApply, " Natychmiast stosuje profil TDP $mode do procesora przez RyzenAdj. Zmiana nastapi od razu!")
    $btnApply.Add_Click({
        $m = $this.Tag
        $s = [int]$Script:TDPControls[$m].STAPM.Value; $f = [int]$Script:TDPControls[$m].Fast.Value
        $sl = [int]$Script:TDPControls[$m].Slow.Value; $t = [int]$Script:TDPControls[$m].Tctl.Value
        if (Set-RyzenAdjTDP -STAPM $s -Fast $f -Slow $sl -Tctl $t) {
            [System.Windows.Forms.MessageBox]::Show("TDP applied: STAPM=${s}W Fast=${f}W Slow=${sl}W Tctl=${t}C", "Success", "OK", "Information")
        } else { [System.Windows.Forms.MessageBox]::Show("Failed to apply TDP!", "Error", "OK", "Error") }
    })
    $Script:TDPControls[$mode] = @{ STAPM = $numSTAPM; Fast = $numFast; Slow = $numSlow; Tctl = $numTctl }
    $tdpY += 80
}
$btnSaveTDP = New-Button -Parent $tabControl -Text "Save and Apply All Profiles" -X 10 -Y 695 -Width 250 -Height 45 -BackColor $Script:Colors.Success -ForeColor $Script:Colors.Background -OnClick {
$btnSaveTDP.Add_MouseHover({ $this.Cursor = [System.Windows.Forms.Cursors]::Hand })
$toolTip.SetToolTip($btnSaveTDP, "✓ Zapisuje profile TDP. ENGINE użyje tych wartości przy zmianie trybu.")
    $newTDP = @{}
    foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
        $newTDP[$mode] = @{
            STAPM = [int]$Script:TDPControls[$mode].STAPM.Value
            Fast = [int]$Script:TDPControls[$mode].Fast.Value
            Slow = [int]$Script:TDPControls[$mode].Slow.Value
            Tctl = [int]$Script:TDPControls[$mode].Tctl.Value
        }
    }
    if (Save-TDPConfig $newTDP) {
        $Script:TDPConfig = Get-TDPConfig
        # Wyślij sygnał reload
        try { Send-ReloadSignal @{ File = "TDPConfig" } } catch { }
        
        [System.Windows.Forms.MessageBox]::Show(
            "✓ TDP PROFILES ZAPISANE!`n`n═══ Zapisane wartości ═══`n`nSilent: $($newTDP.Silent.STAPM)W STAPM, $($newTDP.Silent.Fast)W Fast`nBalanced: $($newTDP.Balanced.STAPM)W STAPM, $($newTDP.Balanced.Fast)W Fast`nTurbo: $($newTDP.Turbo.STAPM)W STAPM, $($newTDP.Turbo.Fast)W Fast`nExtreme: $($newTDP.Extreme.STAPM)W STAPM, $($newTDP.Extreme.Fast)W Fast`n`n✓ ENGINE zastosuje te profile przy zmianie trybu.",
            "Zapis TDP - Sukces",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } else { 
        [System.Windows.Forms.MessageBox]::Show(
            "✗ BŁĄD ZAPISU TDP!`n`nSprawdź uprawnienia do pliku TDPConfig.json",
            "Błąd",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}
$btnResetTDP = New-Button -Parent $tabControl -Text "⟲ Reset Defaults" -X 270 -Y 695 -Width 150 -Height 45 -BackColor ([System.Drawing.Color]::FromArgb(80,60,40)) -ForeColor $Script:Colors.Text -OnClick {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Czy na pewno zresetować profile TDP do domyślnych?`n`nDomyślne wartości:`n• Silent: 15W STAPM`n• Balanced: 25W STAPM`n• Turbo: 35W STAPM`n• Extreme: 45W STAPM`n`n⚠ Kliknij 'Save and Apply' aby zapisać!",
        "Potwierdź reset TDP",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($result -eq "Yes") {
        foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
            $Script:TDPControls[$mode].STAPM.Value = $Script:DefaultTDP[$mode].STAPM
            $Script:TDPControls[$mode].Fast.Value = $Script:DefaultTDP[$mode].Fast
            $Script:TDPControls[$mode].Slow.Value = $Script:DefaultTDP[$mode].Slow
            $Script:TDPControls[$mode].Tctl.Value = $Script:DefaultTDP[$mode].Tctl
        }
        [System.Windows.Forms.MessageBox]::Show(
            "✓ Profile TDP zresetowane do domyślnych!`n`n⚠ Kliknij 'Save and Apply All Profiles' aby zapisać i zastosować.",
            "Reset TDP",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
}
# Check RyzenAdj
if (Test-RyzenAdj) { $Script:lblTDPStatus.Text = "RyzenAdj: Found at $Script:RyzenAdjPath"; $Script:lblTDPStatus.ForeColor = $Script:Colors.Success }
else { $Script:lblTDPStatus.Text = "RyzenAdj: NOT FOUND"; $Script:lblTDPStatus.ForeColor = $Script:Colors.Danger }
# #
# TAB 4: GPU & AI
# #
$tabGPU = New-Object System.Windows.Forms.TabPage
$tabGPU.Text = "GPU & AI"
$tabGPU.BackColor = $Script:Colors.Background
$tabGPU.AutoScroll = $true
$tabs.TabPages.Add($tabGPU)

# PROCESS AI SECTION
# #
$lblProcessAITitle = New-SectionLabel -Parent $tabGPU -Text "[PROCESS AI - CPU/RAM Learning]" -X 10 -Y 10
$panelProcessAI = New-Panel -Parent $tabGPU -X 10 -Y 40 -Width 540 -Height 150 -BackColor $Script:Colors.Card

# Status labels
$null = New-Label -Parent $panelProcessAI -Text "LEARNING STATUS" -X 15 -Y 8 -Width 150 -Height 18 -FontSize 9 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
$Script:lblProcAIApps = New-Label -Parent $panelProcessAI -Text "Apps Learned:   0" -X 15 -Y 32 -Width 250 -Height 22 -FontSize 10 -ForeColor ([System.Drawing.Color]::FromArgb(100, 200, 255))
$Script:lblProcAIClassified = New-Label -Parent $panelProcessAI -Text "Classified:     0" -X 15 -Y 54 -Width 250 -Height 22 -FontSize 10 -ForeColor ([System.Drawing.Color]::FromArgb(100, 255, 150))
$Script:lblProcAISessions = New-Label -Parent $panelProcessAI -Text "Total Sessions: 0" -X 15 -Y 76 -Width 250 -Height 22 -FontSize 10 -ForeColor ([System.Drawing.Color]::FromArgb(255, 200, 100))
$Script:lblProcAIProtected = New-Label -Parent $panelProcessAI -Text "Protected:      35 system processes" -X 15 -Y 98 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Success

# EDIT BUTTON - ProcessAI
$btnEditProcessAI = New-Object System.Windows.Forms.Button
$btnEditProcessAI.Location = New-Object System.Drawing.Point(15, 120)
$btnEditProcessAI.Size = New-Object System.Drawing.Size(100, 22)
$btnEditProcessAI.Text = "Edit Categories"
$btnEditProcessAI.BackColor = $Script:Colors.Accent
$btnEditProcessAI.ForeColor = [System.Drawing.Color]::White
$btnEditProcessAI.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnEditProcessAI.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnEditProcessAI.Add_Click({
    Show-ProcessAIEditor
})
$panelProcessAI.Controls.Add($btnEditProcessAI)

# Separator
$separatorProcAI = New-Object System.Windows.Forms.Panel
$separatorProcAI.Location = New-Object System.Drawing.Point(270, 30)
$separatorProcAI.Size = New-Object System.Drawing.Size(2, 110)
$separatorProcAI.BackColor = $Script:Colors.Border
$panelProcessAI.Controls.Add($separatorProcAI)

# Stats labels - prawa kolumna
$null = New-Label -Parent $panelProcessAI -Text "STATISTICS" -X 285 -Y 8 -Width 100 -Height 18 -FontSize 9 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
$Script:lblProcAIWork = New-Label -Parent $panelProcessAI -Text "Work Apps:      0" -X 285 -Y 32 -Width 240 -Height 22 -FontSize 9 -ForeColor ([System.Drawing.Color]::FromArgb(100, 200, 255))
$Script:lblProcAIGaming = New-Label -Parent $panelProcessAI -Text "Gaming Apps:    0" -X 285 -Y 54 -Width 240 -Height 22 -FontSize 9 -ForeColor ([System.Drawing.Color]::FromArgb(255, 100, 200))
$Script:lblProcAIBg = New-Label -Parent $panelProcessAI -Text "Background:     0" -X 285 -Y 76 -Width 240 -Height 22 -FontSize 9 -ForeColor ([System.Drawing.Color]::FromArgb(150, 150, 150))
$Script:lblProcAIAvgCPU = New-Label -Parent $panelProcessAI -Text "Avg CPU:        0%" -X 285 -Y 98 -Width 240 -Height 22 -FontSize 9 -ForeColor ([System.Drawing.Color]::FromArgb(200, 150, 255))

# GPU AI SECTION
# #
$lblGPUAITitle = New-SectionLabel -Parent $tabGPU -Text "[GPU AI - iGPU/dGPU Learning]" -X 10 -Y 200
$panelGPUAI = New-Panel -Parent $tabGPU -X 10 -Y 230 -Width 540 -Height 180 -BackColor $Script:Colors.Card

# Status labels
$null = New-Label -Parent $panelGPUAI -Text "LEARNING STATUS" -X 15 -Y 8 -Width 150 -Height 18 -FontSize 9 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
$Script:lblGPUAIApps = New-Label -Parent $panelGPUAI -Text "GPU Apps:       0" -X 15 -Y 32 -Width 250 -Height 22 -FontSize 10 -ForeColor ([System.Drawing.Color]::FromArgb(100, 200, 255))
$Script:lblGPUAIClassified = New-Label -Parent $panelGPUAI -Text "Classified:     0" -X 15 -Y 54 -Width 250 -Height 22 -FontSize 10 -ForeColor ([System.Drawing.Color]::FromArgb(100, 255, 150))
$Script:lblGPUAIiGPU = New-Label -Parent $panelGPUAI -Text "iGPU Preferred: 0" -X 15 -Y 76 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Silent
$Script:lblGPUAIdGPU = New-Label -Parent $panelGPUAI -Text "dGPU Preferred: 0" -X 15 -Y 98 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Turbo

# EDIT BUTTON - GPUAI
$btnEditGPUAI = New-Object System.Windows.Forms.Button
$btnEditGPUAI.Location = New-Object System.Drawing.Point(15, 120)
$btnEditGPUAI.Size = New-Object System.Drawing.Size(120, 22)
$btnEditGPUAI.Text = "Edit GPU Prefs"
$btnEditGPUAI.BackColor = $Script:Colors.Turbo
$btnEditGPUAI.ForeColor = [System.Drawing.Color]::White
$btnEditGPUAI.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnEditGPUAI.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnEditGPUAI.Add_Click({
    Show-GPUAIEditor
})
$panelGPUAI.Controls.Add($btnEditGPUAI)

# Separator
$separatorGPU = New-Object System.Windows.Forms.Panel
$separatorGPU.Location = New-Object System.Drawing.Point(270, 30)
$separatorGPU.Size = New-Object System.Drawing.Size(2, 140)
$separatorGPU.BackColor = $Script:Colors.Border
$panelGPUAI.Controls.Add($separatorGPU)

# GPU Detection - prawa kolumna
$null = New-Label -Parent $panelGPUAI -Text "HARDWARE DETECTED" -X 285 -Y 8 -Width 200 -Height 18 -FontSize 9 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
$Script:lblGPUAIiGPUName = New-Label -Parent $panelGPUAI -Text "iGPU: Not detected" -X 285 -Y 32 -Width 240 -Height 22 -FontSize 9 -ForeColor $Script:Colors.TextDim
$Script:lblGPUAIdGPUName = New-Label -Parent $panelGPUAI -Text "dGPU: Not detected" -X 285 -Y 54 -Width 240 -Height 22 -FontSize 9 -ForeColor $Script:Colors.TextDim
$Script:lblGPUAIPrimary = New-Label -Parent $panelGPUAI -Text "Primary: ---" -X 285 -Y 76 -Width 240 -Height 22 -FontSize 9 -ForeColor ([System.Drawing.Color]::FromArgb(255, 200, 100))
$Script:lblGPUAIVendor = New-Label -Parent $panelGPUAI -Text "Vendor: ---" -X 285 -Y 98 -Width 240 -Height 22 -FontSize 9 -ForeColor ([System.Drawing.Color]::FromArgb(150, 200, 255))

# Description
$lblGPUAIDesc = New-Label -Parent $panelGPUAI -Text "GPU AI learns which apps prefer iGPU (power saving) or dGPU (performance). Hybrid graphics automatically switches." -X 15 -Y 150 -Width 510 -Height 25 -FontSize 8 -ForeColor $Script:Colors.TextDim

# Top Processes Panel
$panelProcTop = New-Panel -Parent $tabGPU -X 560 -Y 40 -Width 550 -Height 150 -BackColor $Script:Colors.Card
$null = New-Label -Parent $panelProcTop -Text "TOP LEARNED PROCESSES" -X 10 -Y 5 -Width 200 -Height 18 -FontSize 9 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
$Script:lblProcAIProc1 = New-Label -Parent $panelProcTop -Text "1. --" -X 10 -Y 28 -Width 530 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Success
$Script:lblProcAIProc2 = New-Label -Parent $panelProcTop -Text "2. --" -X 10 -Y 50 -Width 530 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Balanced
$Script:lblProcAIProc3 = New-Label -Parent $panelProcTop -Text "3. --" -X 10 -Y 72 -Width 530 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Cyan
$Script:lblProcAIProc4 = New-Label -Parent $panelProcTop -Text "4. --" -X 10 -Y 94 -Width 530 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Silent
$Script:lblProcAIProc5 = New-Label -Parent $panelProcTop -Text "5. --" -X 10 -Y 116 -Width 530 -Height 20 -FontSize 9 -ForeColor $Script:Colors.TextDim

# Top GPU Apps Panel
$panelGPUTop = New-Panel -Parent $tabGPU -X 560 -Y 230 -Width 550 -Height 180 -BackColor $Script:Colors.Card
$null = New-Label -Parent $panelGPUTop -Text "TOP GPU APPS" -X 10 -Y 5 -Width 200 -Height 18 -FontSize 9 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
$Script:lblGPUAIApp1 = New-Label -Parent $panelGPUTop -Text "1. --" -X 10 -Y 28 -Width 530 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Success
$Script:lblGPUAIApp2 = New-Label -Parent $panelGPUTop -Text "2. --" -X 10 -Y 50 -Width 530 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Balanced
$Script:lblGPUAIApp3 = New-Label -Parent $panelGPUTop -Text "3. --" -X 10 -Y 72 -Width 530 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Cyan
$Script:lblGPUAIApp4 = New-Label -Parent $panelGPUTop -Text "4. --" -X 10 -Y 94 -Width 530 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Silent
$Script:lblGPUAIApp5 = New-Label -Parent $panelGPUTop -Text "5. --" -X 10 -Y 116 -Width 530 -Height 20 -FontSize 9 -ForeColor $Script:Colors.TextDim

# #
# TAB 5: NETWORK
# #
$tabNetwork = New-Object System.Windows.Forms.TabPage
$tabNetwork.Text = "Network"
$tabNetwork.BackColor = $Script:Colors.Background
$tabNetwork.AutoScroll = $true  #  v39.5.1: Enable scroll
$tabs.TabPages.Add($tabNetwork)
$lblNetTitle = New-SectionLabel -Parent $tabNetwork -Text "[NETWORK SPEED]" -X 10 -Y 10
$panelNetDL = New-Panel -Parent $tabNetwork -X 10 -Y 40 -Width 270 -Height 100 -BackColor $Script:Colors.Card
$null = New-Label -Parent $panelNetDL -Text "- DOWNLOAD" -X 10 -Y 8 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.TextDim
$Script:lblNetDLValue = New-Label -Parent $panelNetDL -Text "0 B/s" -X 10 -Y 35 -Width 250 -Height 35 -FontSize 18 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Success
$Script:lblNetDLTotal = New-Label -Parent $panelNetDL -Text "Session: 0 B" -X 10 -Y 75 -Width 250 -Height 20 -FontSize 9 -ForeColor $Script:Colors.TextDim
$panelNetUL = New-Panel -Parent $tabNetwork -X 290 -Y 40 -Width 270 -Height 100 -BackColor $Script:Colors.Card
$null = New-Label -Parent $panelNetUL -Text "- UPLOAD" -X 10 -Y 8 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.TextDim
$Script:lblNetULValue = New-Label -Parent $panelNetUL -Text "0 B/s" -X 10 -Y 35 -Width 250 -Height 35 -FontSize 18 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Warning
$Script:lblNetULTotal = New-Label -Parent $panelNetUL -Text "Session: 0 B" -X 10 -Y 75 -Width 250 -Height 20 -FontSize 9 -ForeColor $Script:Colors.TextDim
$lblTotalTitle = New-SectionLabel -Parent $tabNetwork -Text "[SESSION TOTALS]" -X 580 -Y 10
$panelTotalDL = New-Panel -Parent $tabNetwork -X 580 -Y 40 -Width 260 -Height 100 -BackColor $Script:Colors.Card
$null = New-Label -Parent $panelTotalDL -Text "TOTAL DOWNLOADED" -X 10 -Y 8 -Width 240 -Height 22 -FontSize 9 -ForeColor $Script:Colors.Success
$Script:lblTotalDLValue = New-Label -Parent $panelTotalDL -Text "0 B" -X 10 -Y 35 -Width 240 -Height 45 -FontSize 16 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Success -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
$panelTotalUL = New-Panel -Parent $tabNetwork -X 850 -Y 40 -Width 260 -Height 100 -BackColor $Script:Colors.Card
$null = New-Label -Parent $panelTotalUL -Text "TOTAL UPLOADED" -X 10 -Y 8 -Width 240 -Height 22 -FontSize 9 -ForeColor $Script:Colors.Warning
$Script:lblTotalULValue = New-Label -Parent $panelTotalUL -Text "0 B" -X 10 -Y 35 -Width 240 -Height 45 -FontSize 16 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Warning -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
# Initial load of authoritative totals so UI shows correct values on startup
try {
    Get-NetworkStats | Out-Null
    # Ustaw persistentne sumy na bazie autorytatywnego pliku
    $Script:PersistentNetDL = $Script:TotalDownload
    $Script:PersistentNetUL = $Script:TotalUpload
    # Total = Persistent (z pliku historycznego)
    $Script:lblTotalDLValue.Text = Format-Bytes $Script:PersistentNetDL
    $Script:lblTotalULValue.Text = Format-Bytes $Script:PersistentNetUL
    # Session CONSOLE = 0 na starcie
    $Script:lblNetDLTotal.Text = "Session: 0 B"
    $Script:lblNetULTotal.Text = "Session: 0 B"
} catch { }
$lblDiskTitle = New-SectionLabel -Parent $tabNetwork -Text "[DISK I/O]" -X 10 -Y 155
$panelDiskR = New-Panel -Parent $tabNetwork -X 10 -Y 185 -Width 270 -Height 100 -BackColor $Script:Colors.Card
$null = New-Label -Parent $panelDiskR -Text "- READ" -X 10 -Y 8 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.TextDim
$Script:lblDiskReadValue = New-Label -Parent $panelDiskR -Text "0 MB/s" -X 10 -Y 35 -Width 250 -Height 35 -FontSize 18 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.ChartCPU
$Script:lblDiskIOBoost = New-Label -Parent $panelDiskR -Text "I/O Boost: OFF" -X 10 -Y 75 -Width 250 -Height 20 -FontSize 9 -ForeColor $Script:Colors.TextDim
$panelDiskW = New-Panel -Parent $tabNetwork -X 290 -Y 185 -Width 270 -Height 100 -BackColor $Script:Colors.Card
$null = New-Label -Parent $panelDiskW -Text "- WRITE" -X 10 -Y 8 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.TextDim
$Script:lblDiskWriteValue = New-Label -Parent $panelDiskW -Text "0 MB/s" -X 10 -Y 35 -Width 250 -Height 35 -FontSize 18 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Turbo
$lblHWTitle = New-SectionLabel -Parent $tabNetwork -Text "[GPU / POWER]" -X 580 -Y 155
$panelHW = New-Panel -Parent $tabNetwork -X 580 -Y 185 -Width 530 -Height 100 -BackColor $Script:Colors.Card
$Script:lblGPUTemp = New-Label -Parent $panelHW -Text "GPU Temp: ---" -X 15 -Y 15 -Width 240 -Height 25 -FontSize 11
$Script:lblGPULoad = New-Label -Parent $panelHW -Text "GPU Load: ---" -X 270 -Y 15 -Width 240 -Height 25 -FontSize 11
$Script:lblVRMTemp = New-Label -Parent $panelHW -Text "VRM Temp: ---" -X 15 -Y 50 -Width 240 -Height 25 -FontSize 11
$Script:lblCPUPower = New-Label -Parent $panelHW -Text "CPU Power: ---" -X 270 -Y 50 -Width 240 -Height 25 -FontSize 11
$lblCPUInfoTitle = New-SectionLabel -Parent $tabNetwork -Text "[CPU DETECTION]" -X 10 -Y 470
$panelCPUInfo = New-Panel -Parent $tabNetwork -X 10 -Y 500 -Width 1100 -Height 60 -BackColor $Script:Colors.Card
$Script:lblCPUVendor = New-Label -Parent $panelCPUInfo -Text "Vendor: Unknown" -X 15 -Y 10 -Width 180 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Balanced
$Script:lblCPUModel = New-Label -Parent $panelCPUInfo -Text "Model: Unknown" -X 200 -Y 10 -Width 200 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Balanced
$Script:lblCPUGen = New-Label -Parent $panelCPUInfo -Text "Generation: Unknown" -X 405 -Y 10 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Balanced
$Script:lblCPUArch = New-Label -Parent $panelCPUInfo -Text "Architecture: Unknown" -X 660 -Y 10 -Width 430 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Balanced
$Script:lblCPUCores = New-Label -Parent $panelCPUInfo -Text "Cores: - | Threads: ?" -X 15 -Y 32 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Silent
$Script:lblCPUHybrid = New-Label -Parent $panelCPUInfo -Text "" -X 270 -Y 32 -Width 400 -Height 22 -FontSize 10 -ForeColor ([System.Drawing.Color]::Magenta)
# #
# #
$lblNetAITitle = New-SectionLabel -Parent $tabNetwork -Text "[NETWORK AI]" -X 10 -Y 570
# Panel 1: Network AI Status (lewy)
$panelNetAIStatus = New-Panel -Parent $tabNetwork -X 10 -Y 600 -Width 540 -Height 150 -BackColor $Script:Colors.Card
# Naglowek statusu
$null = New-Label -Parent $panelNetAIStatus -Text "STATUS" -X 15 -Y 8 -Width 100 -Height 18 -FontSize 9 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
# Status labels - lewa kolumna
$Script:lblNetAIMode = New-Label -Parent $panelNetAIStatus -Text "Current Mode:   Normal" -X 15 -Y 32 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Success
$Script:lblNetAIConfidence = New-Label -Parent $panelNetAIStatus -Text "Confidence:     --" -X 15 -Y 54 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Balanced
$Script:lblNetAIAppType = New-Label -Parent $panelNetAIStatus -Text "App Category:   Unknown" -X 15 -Y 76 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Cyan
$Script:lblNetAIPrediction = New-Label -Parent $panelNetAIStatus -Text "Prediction:     --" -X 15 -Y 98 -Width 250 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Silent
# Separator pionowy
$separatorNetAI = New-Object System.Windows.Forms.Panel
$separatorNetAI.Location = New-Object System.Drawing.Point(270, 30)
$separatorNetAI.Size = New-Object System.Drawing.Size(2, 110)
$separatorNetAI.BackColor = $Script:Colors.Border
$panelNetAIStatus.Controls.Add($separatorNetAI)
# Stats labels - prawa kolumna
$null = New-Label -Parent $panelNetAIStatus -Text "STATISTICS" -X 285 -Y 8 -Width 100 -Height 18 -FontSize 9 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
$Script:lblNetAIApps = New-Label -Parent $panelNetAIStatus -Text "Apps Learned:   0" -X 285 -Y 32 -Width 240 -Height 22 -FontSize 10 -ForeColor ([System.Drawing.Color]::FromArgb(100, 200, 255))
$Script:lblNetAIAccuracy = New-Label -Parent $panelNetAIStatus -Text "Accuracy:       0%" -X 285 -Y 54 -Width 240 -Height 22 -FontSize 10 -ForeColor ([System.Drawing.Color]::FromArgb(100, 255, 150))
$Script:lblNetAIPredictions = New-Label -Parent $panelNetAIStatus -Text "Predictions:    0" -X 285 -Y 76 -Width 240 -Height 22 -FontSize 10 -ForeColor ([System.Drawing.Color]::FromArgb(255, 200, 100))
$Script:lblNetAIQStates = New-Label -Parent $panelNetAIStatus -Text "Q-Table States: 0" -X 285 -Y 98 -Width 240 -Height 22 -FontSize 10 -ForeColor ([System.Drawing.Color]::FromArgb(200, 150, 255))
# Panel 2: Hourly Pattern Chart (prawy gorny)
$panelNetAIHourly = New-Panel -Parent $tabNetwork -X 560 -Y 600 -Width 280 -Height 150 -BackColor $Script:Colors.Card
$null = New-Label -Parent $panelNetAIHourly -Text "HOURLY GAMING PATTERN" -X 10 -Y 5 -Width 260 -Height 18 -FontSize 9 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
# PictureBox dla wykresu hourly patterns
$Script:picNetAIHourly = New-Object System.Windows.Forms.PictureBox
$Script:picNetAIHourly.Location = New-Object System.Drawing.Point(10, 28)
$Script:picNetAIHourly.Size = New-Object System.Drawing.Size(260, 85)
$Script:picNetAIHourly.BackColor = $Script:Colors.Panel
$panelNetAIHourly.Controls.Add($Script:picNetAIHourly)
$Script:lblNetAIPeak = New-Label -Parent $panelNetAIHourly -Text "Peak: --" -X 10 -Y 118 -Width 260 -Height 22 -FontSize 9 -ForeColor $Script:Colors.ChartCPU
# Panel 3: Top Apps (prawy dolny)
$panelNetAIApps = New-Panel -Parent $tabNetwork -X 850 -Y 600 -Width 260 -Height 150 -BackColor $Script:Colors.Card
$null = New-Label -Parent $panelNetAIApps -Text "TOP NETWORK APPS" -X 10 -Y 5 -Width 240 -Height 18 -FontSize 9 -FontStyle ([System.Drawing.FontStyle]::Bold) -ForeColor $Script:Colors.Accent
$Script:lblNetAIApp1 = New-Label -Parent $panelNetAIApps -Text "1. --" -X 10 -Y 28 -Width 240 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Success
$Script:lblNetAIApp2 = New-Label -Parent $panelNetAIApps -Text "2. --" -X 10 -Y 50 -Width 240 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Balanced
$Script:lblNetAIApp3 = New-Label -Parent $panelNetAIApps -Text "3. --" -X 10 -Y 72 -Width 240 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Cyan
$Script:lblNetAIApp4 = New-Label -Parent $panelNetAIApps -Text "4. --" -X 10 -Y 94 -Width 240 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Silent
$Script:lblNetAIApp5 = New-Label -Parent $panelNetAIApps -Text "5. --" -X 10 -Y 116 -Width 240 -Height 20 -FontSize 9 -ForeColor $Script:Colors.TextDim
# Initialize Network AI data storage
$Script:NetworkAIData = @{
    HourlyPatterns = @{}
    AppProfiles = @{}
    CurrentMode = "Normal"
    Confidence = 0
    AppsLearned = 0
    Accuracy = 0
    TotalPredictions = 0
    QStates = 0
}

# Initialize ProcessAI data
$Script:ProcessAIData = @{
    AppsLearned = 0
    Classified = 0
    TotalSessions = 0
    WorkApps = 0
    GamingApps = 0
    BackgroundApps = 0
    AvgCPU = 0
    AppProfiles = @{}
}

# Initialize GPUAI data
$Script:GPUAIData = @{
    GPUApps = 0
    Classified = 0
    iGPUPreferred = 0
    dGPUPreferred = 0
    HasiGPU = $false
    HasdGPU = $false
    iGPUName = ""
    dGPUName = ""
    PrimaryGPU = ""
    dGPUVendor = ""
    AppGPUProfiles = @{}
}

$lblChartsTitle = New-SectionLabel -Parent $tabNetwork -Text "[HISTORICAL CHARTS]" -X 10 -Y 295
# Chart 1: Network Speed (Download + Upload)
$lblChartNet = New-Label -Parent $tabNetwork -Text "NETWORK SPEED (KB/s)" -X 10 -Y 320 -Width 180 -Height 20 -FontSize 9 -ForeColor $Script:Colors.Success
$Script:picNetChart = New-Object System.Windows.Forms.PictureBox
$Script:picNetChart.Location = New-Object System.Drawing.Point(10, 340)
$Script:picNetChart.Size = New-Object System.Drawing.Size(360, 120)
$Script:picNetChart.BackColor = $Script:Colors.Panel
$tabNetwork.Controls.Add($Script:picNetChart)
# Chart 2: Disk I/O (Read + Write)
$lblChartDisk = New-Label -Parent $tabNetwork -Text "DISK I/O (MB/s)" -X 380 -Y 320 -Width 180 -Height 20 -FontSize 9 -ForeColor $Script:Colors.ChartCPU
$Script:picDiskChart = New-Object System.Windows.Forms.PictureBox
$Script:picDiskChart.Location = New-Object System.Drawing.Point(380, 340)
$Script:picDiskChart.Size = New-Object System.Drawing.Size(360, 120)
$Script:picDiskChart.BackColor = $Script:Colors.Panel
$tabNetwork.Controls.Add($Script:picDiskChart)
# Chart 3: GPU (Temp + Load)
$lblChartGPU = New-Label -Parent $tabNetwork -Text "GPU METRICS" -X 750 -Y 320 -Width 180 -Height 20 -FontSize 9 -ForeColor ([System.Drawing.Color]::Magenta)
$Script:picGPUChart = New-Object System.Windows.Forms.PictureBox
$Script:picGPUChart.Location = New-Object System.Drawing.Point(750, 340)
$Script:picGPUChart.Size = New-Object System.Drawing.Size(360, 120)
$Script:picGPUChart.BackColor = $Script:Colors.Panel
$tabNetwork.Controls.Add($Script:picGPUChart)
# Initialize history buffers for charts
$Script:NetDLHistory = [System.Collections.Generic.List[double]]::new()
$Script:NetULHistory = [System.Collections.Generic.List[double]]::new()
$Script:DiskReadHistory = [System.Collections.Generic.List[double]]::new()
$Script:DiskWriteHistory = [System.Collections.Generic.List[double]]::new()
$Script:GPUTempHistory = [System.Collections.Generic.List[double]]::new()
$Script:GPULoadHistory = [System.Collections.Generic.List[double]]::new()
$Script:ChartMaxPoints = 60  # 60 seconds of history
# #
# TAB 5: SETTINGS (Power Modes + Boost + I/O)
# #
$tabSettings = New-Object System.Windows.Forms.TabPage
$tabSettings.Text = "Settings AMD"
$tabSettings.BackColor = $Script:Colors.Background
$tabSettings.AutoScroll = $true
$tabs.TabPages.Add($tabSettings)

# ═══════════════════════════════════════════════════════════════════════════════
# TAB: SETTINGS INTEL - Osobna zakładka dla procesorów Intel
# ═══════════════════════════════════════════════════════════════════════════════
$tabSettingsIntel = New-Object System.Windows.Forms.TabPage
$tabSettingsIntel.Text = "Settings Intel"
$tabSettingsIntel.BackColor = $Script:Colors.Background
$tabSettingsIntel.AutoScroll = $true
$tabs.TabPages.Add($tabSettingsIntel)

# INTEL: Power Modes
$gbPowerIntel = New-GroupBox -Parent $tabSettingsIntel -Title "Power Modes INTEL - CPU % (Speed Shift + EPP)" -X 10 -Y 10 -Width 550 -Height 200
$modesIntel = @("Silent", "Balanced", "Turbo", "Extreme"); $yI = 25
$Script:PowerControlsIntel = @{}
foreach ($mode in $modesIntel) {
    $minVal = 50
    $maxVal = 100
    if ($Script:Config.PowerModesIntel -and $Script:Config.PowerModesIntel.$mode) { 
        $minVal = $Script:Config.PowerModesIntel.$mode.Min
        $maxVal = $Script:Config.PowerModesIntel.$mode.Max
    } elseif ($Script:DefaultConfig.PowerModesIntel -and $Script:DefaultConfig.PowerModesIntel.$mode) { 
        $minVal = $Script:DefaultConfig.PowerModesIntel.$mode.Min
        $maxVal = $Script:DefaultConfig.PowerModesIntel.$mode.Max
    }
    $null = New-Label -Parent $gbPowerIntel -Text "${mode}:" -X 15 -Y $yI -Width 80 -Height 22
    $null = New-Label -Parent $gbPowerIntel -Text "Min:" -X 100 -Y $yI -Width 35 -Height 22
    $numMinI = New-NumericUpDown -Parent $gbPowerIntel -X 140 -Y ($yI-2) -Min 0 -Max 100 -Value $minVal -Width 70
    $null = New-Label -Parent $gbPowerIntel -Text "Max:" -X 230 -Y $yI -Width 35 -Height 22
    $numMaxI = New-NumericUpDown -Parent $gbPowerIntel -X 270 -Y ($yI-2) -Min 0 -Max 100 -Value $maxVal -Width 70
    $Script:PowerControlsIntel[$mode] = @{ Min = $numMinI; Max = $numMaxI }
    $yI += 35
}
$lblIntelInfo = New-Label -Parent $gbPowerIntel -Text "Intel Speed Shift: Min=responsywnosc (jak szybko CPU reaguje), Max=limit wydajnosci" -X 15 -Y 168 -Width 520 -Height 22 -FontSize 8 -ForeColor $Script:Colors.TextDim

# INTEL: Opis technologii
$gbIntelTech = New-GroupBox -Parent $tabSettingsIntel -Title "Technologia Intel Speed Shift (HWP)" -X 580 -Y 10 -Width 530 -Height 200
$txtIntelDesc = New-Object System.Windows.Forms.TextBox
$txtIntelDesc.Location = New-Object System.Drawing.Point(15, 25)
$txtIntelDesc.Size = New-Object System.Drawing.Size(500, 160)
$txtIntelDesc.Multiline = $true
$txtIntelDesc.ReadOnly = $true
$txtIntelDesc.BackColor = $Script:Colors.Panel
$txtIntelDesc.ForeColor = $Script:Colors.Text
$txtIntelDesc.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtIntelDesc.Text = "Intel Speed Shift (Hardware P-States) to technologia`r`nzarzadzania energia wprowadzona w 6. generacji Intel Core.`r`n`r`n* Min CPU % - Jak szybko CPU reaguje na obciazenie`r`n  (nizsze = wolniejsza reakcja, oszczednosc energii)`r`n`r`n* Max CPU % - Maksymalna wydajnosc CPU`r`n  (nizsze = ogranicza predkosc, mniej ciepla)`r`n`r`nDomyslne wartosci sa zoptymalizowane dla laptopow.`r`nDla PC desktopow mozesz zwiekszyc Min w trybie Turbo."
$gbIntelTech.Controls.Add($txtIntelDesc)

# INTEL: Przyciski Save/Reset
$btnSaveIntel = New-Button -Parent $tabSettingsIntel -Text "SAVE INTEL SETTINGS" -X 10 -Y 220 -Width 250 -Height 50 -BackColor $Script:Colors.Success -ForeColor $Script:Colors.Background -OnClick {
    try {
        $config = Get-Config
        if (-not $config) { 
            [System.Windows.Forms.MessageBox]::Show("BLAD: Nie mozna zaladowac konfiguracji!", "Blad", "OK", "Error")
            return
        }
        # Konwertuj do hashtable jeśli jest PSObject
        if ($config -is [PSCustomObject]) {
            $config = ConvertTo-Hashtable $config
        }
        if (-not $config.PowerModesIntel) { 
            $config.PowerModesIntel = @{}
        }
        if (-not $Script:PowerControlsIntel) {
            [System.Windows.Forms.MessageBox]::Show("BLAD: Kontrolki Intel nie zostaly zainicjalizowane!", "Blad", "OK", "Error")
            return
        }
        foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
            if (-not $Script:PowerControlsIntel[$mode]) {
                [System.Windows.Forms.MessageBox]::Show("BLAD: Brak kontrolki dla trybu: $mode", "Blad", "OK", "Error")
                return
            }
            $config.PowerModesIntel[$mode] = @{
                Min = [int]$Script:PowerControlsIntel[$mode].Min.Value
                Max = [int]$Script:PowerControlsIntel[$mode].Max.Value
            }
        }
        if (Save-Config $config) {
            try { Send-ReloadSignal @{ File = "Config" } } catch { }
            [System.Windows.Forms.MessageBox]::Show(
                "INTEL SETTINGS ZAPISANE!`n`n=== Zapisane wartosci ===`n`nSilent: Min=$($config.PowerModesIntel.Silent.Min)%, Max=$($config.PowerModesIntel.Silent.Max)%`nBalanced: Min=$($config.PowerModesIntel.Balanced.Min)%, Max=$($config.PowerModesIntel.Balanced.Max)%`nTurbo: Min=$($config.PowerModesIntel.Turbo.Min)%, Max=$($config.PowerModesIntel.Turbo.Max)%`nExtreme: Min=$($config.PowerModesIntel.Extreme.Min)%, Max=$($config.PowerModesIntel.Extreme.Max)%`n`nSygnal RELOAD wyslany do ENGINE",
                "Zapis Intel - Sukces",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        } else {
            [System.Windows.Forms.MessageBox]::Show("BLAD ZAPISU!`n`nNie udalo sie zapisac pliku konfiguracji.`nSprawdz uprawnienia do katalogu C:\CPUManager", "Blad", "OK", "Error")
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("BLAD KRYTYCZNY!`n`n$($_.Exception.Message)`n`nStackTrace:`n$($_.ScriptStackTrace)", "Blad", "OK", "Error")
    }
}

$btnResetIntel = New-Button -Parent $tabSettingsIntel -Text "Reset Intel Defaults" -X 270 -Y 220 -Width 200 -Height 50 -BackColor ([System.Drawing.Color]::FromArgb(80,60,40)) -ForeColor $Script:Colors.Text -OnClick {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Przywrocic domyslne wartosci Intel?`n`n=== DOMYSLNE ===`nSilent: Min=50%, Max=85%`nBalanced: Min=85%, Max=99%`nTurbo: Min=99%, Max=100%`nExtreme: Min=100%, Max=100%",
        "Reset Intel",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($result -eq "Yes") {
        $Script:PowerControlsIntel["Silent"].Min.Value = 50
        $Script:PowerControlsIntel["Silent"].Max.Value = 85
        $Script:PowerControlsIntel["Balanced"].Min.Value = 85
        $Script:PowerControlsIntel["Balanced"].Max.Value = 99
        $Script:PowerControlsIntel["Turbo"].Min.Value = 99
        $Script:PowerControlsIntel["Turbo"].Max.Value = 100
        $Script:PowerControlsIntel["Extreme"].Min.Value = 100
        $Script:PowerControlsIntel["Extreme"].Max.Value = 100
        [System.Windows.Forms.MessageBox]::Show("Wartosci Intel zresetowane!`n`nKliknij 'SAVE INTEL SETTINGS' aby zapisac.", "Reset Intel", "OK", "Information")
    }
}

# INTEL: Presets
$gbIntelPresets = New-GroupBox -Parent $tabSettingsIntel -Title "Szybkie presety Intel" -X 10 -Y 280 -Width 550 -Height 120
$btnIntelLaptop = New-Button -Parent $gbIntelPresets -Text "Laptop (oszczednosc)" -X 15 -Y 30 -Width 160 -Height 35 -BackColor $Script:Colors.Silent -OnClick {
    $Script:PowerControlsIntel["Silent"].Min.Value = 30; $Script:PowerControlsIntel["Silent"].Max.Value = 70
    $Script:PowerControlsIntel["Balanced"].Min.Value = 20; $Script:PowerControlsIntel["Balanced"].Max.Value = 90
    $Script:PowerControlsIntel["Turbo"].Min.Value = 40; $Script:PowerControlsIntel["Turbo"].Max.Value = 100
    $Script:PowerControlsIntel["Extreme"].Min.Value = 80; $Script:PowerControlsIntel["Extreme"].Max.Value = 100
    [System.Windows.Forms.MessageBox]::Show("Preset LAPTOP zaladowany`n`nZoptymalizowany dla oszczednosci baterii.`nKliknij SAVE aby zapisac.", "Preset Laptop", "OK", "Information")
}
$btnIntelDesktop = New-Button -Parent $gbIntelPresets -Text "Desktop (wydajnosc)" -X 190 -Y 30 -Width 160 -Height 35 -BackColor $Script:Colors.Turbo -OnClick {
    $Script:PowerControlsIntel["Silent"].Min.Value = 50; $Script:PowerControlsIntel["Silent"].Max.Value = 90
    $Script:PowerControlsIntel["Balanced"].Min.Value = 50; $Script:PowerControlsIntel["Balanced"].Max.Value = 100
    $Script:PowerControlsIntel["Turbo"].Min.Value = 80; $Script:PowerControlsIntel["Turbo"].Max.Value = 100
    $Script:PowerControlsIntel["Extreme"].Min.Value = 100; $Script:PowerControlsIntel["Extreme"].Max.Value = 100
    [System.Windows.Forms.MessageBox]::Show("Preset DESKTOP zaladowany`n`nZoptymalizowany dla maksymalnej wydajnosci.`nKliknij SAVE aby zapisac.", "Preset Desktop", "OK", "Information")
}
$btnIntelQuiet = New-Button -Parent $gbIntelPresets -Text "Cichy (min halasu)" -X 365 -Y 30 -Width 160 -Height 35 -BackColor ([System.Drawing.Color]::FromArgb(60,60,80)) -OnClick {
    $Script:PowerControlsIntel["Silent"].Min.Value = 20; $Script:PowerControlsIntel["Silent"].Max.Value = 60
    $Script:PowerControlsIntel["Balanced"].Min.Value = 20; $Script:PowerControlsIntel["Balanced"].Max.Value = 80
    $Script:PowerControlsIntel["Turbo"].Min.Value = 30; $Script:PowerControlsIntel["Turbo"].Max.Value = 90
    $Script:PowerControlsIntel["Extreme"].Min.Value = 50; $Script:PowerControlsIntel["Extreme"].Max.Value = 100
    [System.Windows.Forms.MessageBox]::Show("Preset CICHY zaladowany`n`nZoptymalizowany dla minimalnego halasu wentylatora.`nKliknij SAVE aby zapisac.", "Preset Cichy", "OK", "Information")
}
$lblPresetInfo = New-Label -Parent $gbIntelPresets -Text "Presety automatycznie ustawiaja wartosci - kliknij SAVE INTEL SETTINGS aby zastosowac" -X 15 -Y 80 -Width 520 -Height 30 -FontSize 8 -ForeColor $Script:Colors.TextDim

# INTEL: Status wykrytego CPU
$gbIntelStatus = New-GroupBox -Parent $tabSettingsIntel -Title "Status procesora" -X 580 -Y 220 -Width 530 -Height 180
$Script:lblIntelCPUStatus = New-Label -Parent $gbIntelStatus -Text "Wykryty CPU: Sprawdzanie..." -X 15 -Y 30 -Width 500 -Height 25 -FontSize 11 -ForeColor $Script:Colors.Cyan
$Script:lblIntelGeneration = New-Label -Parent $gbIntelStatus -Text "Generacja: ---" -X 15 -Y 60 -Width 500 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Text
$Script:lblIntelCores = New-Label -Parent $gbIntelStatus -Text "Rdzenie: --- | Watki: ---" -X 15 -Y 85 -Width 500 -Height 22 -FontSize 10 -ForeColor $Script:Colors.Text
$Script:lblIntelHybrid = New-Label -Parent $gbIntelStatus -Text "" -X 15 -Y 110 -Width 500 -Height 22 -FontSize 10 -ForeColor ([System.Drawing.Color]::Magenta)
$lblIntelNote = New-Label -Parent $gbIntelStatus -Text "UWAGA: Te ustawienia dotycza TYLKO procesorow Intel.`nDla AMD Ryzen uzyj zakladki 'Settings AMD'." -X 15 -Y 140 -Width 500 -Height 35 -FontSize 9 -ForeColor $Script:Colors.Warning

# Aktualizacja statusu Intel przy starcie
try {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cpu) {
        $Script:lblIntelCPUStatus.Text = "Wykryty CPU: $($cpu.Name)"
        if ($cpu.Name -match "Intel") {
            $Script:lblIntelCPUStatus.ForeColor = $Script:Colors.Success
            
            # Wykrywanie generacji z nazwy procesora (np. i7-10750H -> 10. generacja)
            $generation = "NIEZNANA"
            if ($cpu.Name -match "i[3579]-(\d{1,2})\d{3,4}") {
                $genNumber = [int]$matches[1]
                if ($genNumber -ge 1 -and $genNumber -le 20) {
                    $generation = "$genNumber"
                }
            }
            $Script:lblIntelGeneration.Text = "Generacja: $generation"
            
            if ($cpu.Name -match "12th|13th|14th") {
                $Script:lblIntelHybrid.Text = "Procesor hybrydowy (P-cores + E-cores)"
            }
        } else {
            $Script:lblIntelCPUStatus.ForeColor = $Script:Colors.Warning
            $Script:lblIntelCPUStatus.Text += " (To NIE jest Intel!)"
            $Script:lblIntelGeneration.Text = "Generacja: N/A (to nie Intel)"
        }
        $Script:lblIntelCores.Text = "Rdzenie: $($cpu.NumberOfCores) | Watki: $($cpu.NumberOfLogicalProcessors)"
    }
} catch { }

# ═══════════════════════════════════════════════════════════════════════════════
# Powrót do TAB Settings AMD - Power Modes
# ═══════════════════════════════════════════════════════════════════════════════
# Power Modes - AMD (RyzenAdj)
$gbPower = New-GroupBox -Parent $tabSettings -Title "Power Modes AMD - CPU % (RyzenAdj)" -X 10 -Y 10 -Width 550 -Height 180
$modes = @("Silent", "Balanced", "Turbo", "Extreme"); $y = 25
$Script:PowerControls = @{}
foreach ($mode in $modes) {
    $minVal = if ($Script:Config.PowerModes.$mode) { $Script:Config.PowerModes.$mode.Min } else { $Script:DefaultConfig.PowerModes.$mode.Min }
    $maxVal = if ($Script:Config.PowerModes.$mode) { $Script:Config.PowerModes.$mode.Max } else { $Script:DefaultConfig.PowerModes.$mode.Max }
    $null = New-Label -Parent $gbPower -Text "${mode}:" -X 15 -Y $y -Width 80 -Height 22
    $null = New-Label -Parent $gbPower -Text "Min:" -X 100 -Y $y -Width 35 -Height 22
    $numMin = New-NumericUpDown -Parent $gbPower -X 140 -Y ($y-2) -Min 0 -Max 100 -Value $minVal -Width 70
    $null = New-Label -Parent $gbPower -Text "Max:" -X 230 -Y $y -Width 35 -Height 22
    $numMax = New-NumericUpDown -Parent $gbPower -X 270 -Y ($y-2) -Min 0 -Max 100 -Value $maxVal -Width 70
    $Script:PowerControls[$mode] = @{ Min = $numMin; Max = $numMax }
    $y += 35
}
# ForceMode
$null = New-Label -Parent $gbPower -Text "Force:" -X 360 -Y 25 -Width 50 -Height 22
$Script:cmbForceMode = New-Object System.Windows.Forms.ComboBox
$Script:cmbForceMode.Location = New-Object System.Drawing.Point(415, 22); $Script:cmbForceMode.Size = New-Object System.Drawing.Size(120, 25)
$Script:cmbForceMode.DropDownStyle = "DropDownList"; $Script:cmbForceMode.BackColor = $Script:Colors.Card; $Script:cmbForceMode.ForeColor = $Script:Colors.Text
$Script:cmbForceMode.Items.AddRange(@("(AI Auto)", "Silent", "Silent Lock", "Balanced Lock", "Balanced", "Turbo", "Extreme"))
$toolTip.SetToolTip($Script:cmbForceMode, "✓ Wymusza konkretny tryb pracy zamiast automatycznego AI.")
$selIdx = switch ($Script:Config.ForceMode) { "Silent" { 1 } "Silent Lock" { 2 } "Balanced Lock" { 3 } "Balanced" { 4 } "Turbo" { 5 } "Extreme" { 6 } default { 0 } }
$Script:cmbForceMode.SelectedIndex = $selIdx
$gbPower.Controls.Add($Script:cmbForceMode)

# Boost Settings
$gbBoost = New-GroupBox -Parent $tabSettings -Title "Boost Settings" -X 10 -Y 200 -Width 550 -Height 150
$boostDur = if ($Script:Config.BoostSettings.BoostDuration) { $Script:Config.BoostSettings.BoostDuration } else { 10000 }
$boostCool = if ($Script:Config.BoostSettings.BoostCooldown) { $Script:Config.BoostSettings.BoostCooldown } else { 20 }
$null = New-Label -Parent $gbBoost -Text "Duration (ms):" -X 15 -Y 28 -Width 120 -Height 22
$Script:numBoostDuration = New-NumericUpDown -Parent $gbBoost -X 140 -Y 25 -Min 5000 -Max 30000 -Value $boostDur -Width 100 -Increment 1000
$null = New-Label -Parent $gbBoost -Text "Cooldown (s):" -X 260 -Y 28 -Width 110 -Height 22
$Script:numBoostCooldown = New-NumericUpDown -Parent $gbBoost -X 375 -Y 25 -Min 10 -Max 60 -Value $boostCool -Width 80 -Increment 5
$autoBoost = if ($null -ne $Script:Config.BoostSettings.AutoBoostEnabled) { $Script:Config.BoostSettings.AutoBoostEnabled } else { $true }
$startupBoost = if ($null -ne $Script:Config.BoostSettings.EnableBoostForAllAppsOnStart) { $Script:Config.BoostSettings.EnableBoostForAllAppsOnStart } else { $true }
$activityBoost = if ($null -ne $Script:Config.BoostSettings.ActivityBasedBoost) { $Script:Config.BoostSettings.ActivityBasedBoost } else { $true }
$Script:chkAutoBoost = New-CheckBox -Parent $gbBoost -Text "AutoBoost (CPU sampling before boost)" -X 15 -Y 60 -Checked $autoBoost -Width 260
$toolTip.SetToolTip($Script:chkAutoBoost, " Automatyczny boost kiedy wykryje wysokie obciazenie CPU. Inteligentne zwiekszanie mocy w razie potrzeby.")
$Script:chkStartupBoost = New-CheckBox -Parent $gbBoost -Text "Startup Boost for new apps" -X 280 -Y 60 -Checked $startupBoost -Width 260
$toolTip.SetToolTip($Script:chkStartupBoost, " Zwieksza TDP podczas uruchamiania nowych aplikacji. Szybsze ladowanie programow.")
$Script:chkActivityBoost = New-CheckBox -Parent $gbBoost -Text "Activity-Based Boost (smart duration)" -X 15 -Y 90 -Checked $activityBoost -Width 400
$toolTip.SetToolTip($Script:chkActivityBoost, " v40: Boost trwa DOKLADNIE tyle ile aplikacja laduje, nie sztywny czas. Konczy sie gdy app przestaje byc aktywna.")
$null = New-Label -Parent $gbBoost -Text "Idle threshold:" -X 15 -Y 118 -Width 90 -Height 22 -FontSize 9
$actIdleThresh = if ($Script:Config.BoostSettings.ActivityIdleThreshold) { $Script:Config.BoostSettings.ActivityIdleThreshold } else { 5 }
$Script:numActivityIdleThreshold = New-NumericUpDown -Parent $gbBoost -X 105 -Y 115 -Min 1 -Max 20 -Value $actIdleThresh -Width 50 -Increment 1
$toolTip.SetToolTip($Script:numActivityIdleThreshold, " CPU% ponizej ktorego aplikacja = idle. Domyslnie 5%.")
$null = New-Label -Parent $gbBoost -Text "%" -X 158 -Y 118 -Width 20 -Height 22 -FontSize 9
$null = New-Label -Parent $gbBoost -Text "Max boost:" -X 200 -Y 118 -Width 70 -Height 22 -FontSize 9
$actMaxBoost = if ($Script:Config.BoostSettings.ActivityMaxBoostTime) { $Script:Config.BoostSettings.ActivityMaxBoostTime } else { 30 }
$Script:numActivityMaxBoost = New-NumericUpDown -Parent $gbBoost -X 275 -Y 115 -Min 10 -Max 120 -Value $actMaxBoost -Width 50 -Increment 5
$toolTip.SetToolTip($Script:numActivityMaxBoost, " Maksymalny czas boost (safety). Domyslnie 30s.")
$null = New-Label -Parent $gbBoost -Text "s" -X 328 -Y 118 -Width 15 -Height 22 -FontSize 9
$gbCore = New-GroupBox -Parent $tabSettings -Title "CORE Engines (Recommended ON)" -X 10 -Y 360 -Width 550 -Height 150
$Script:chkProphet = New-CheckBox -Parent $gbCore -Text "Prophet (App Learning)" -X 15 -Y 28 -Checked ($Script:Engines.Prophet -eq $true) -Width 250
$toolTip.SetToolTip($Script:chkProphet, " Uczy sie wzorcow uzywania aplikacji. Przewiduje jakie programy bedziesz uruchamiac i przygotowuje system.")
$Script:chkSelfTuner = New-CheckBox -Parent $gbCore -Text "SelfTuner (Auto-Calibration)" -X 280 -Y 28 -Checked ($Script:Engines.SelfTuner -eq $true) -Width 250
$toolTip.SetToolTip($Script:chkSelfTuner, " Auto-kalibruje parametry AI. Dostosowuje ustawienia optymalizacji na podstawie wynikow wydajnosci.")
$Script:chkAnomalyDetector = New-CheckBox -Parent $gbCore -Text "Anomaly Detector" -X 15 -Y 58 -Checked ($Script:Engines.AnomalyDetector -eq $true) -Width 250
$toolTip.SetToolTip($Script:chkAnomalyDetector, "- Wykrywa nietypowe zachowania procesow. Ochrona przed zlosliwym oprogramowaniem i anomaliami systemu.")
$Script:chkChainPredictor = New-CheckBox -Parent $gbCore -Text "Chain Predictor" -X 280 -Y 58 -Checked ($Script:Engines.ChainPredictor -eq $true) -Width 250
$toolTip.SetToolTip($Script:chkChainPredictor, "- Przewiduje sekwencje uruchamiania aplikacji. Jesli uruchomisz Word, przewiduje ze potem uruchomisz Excel.")
$Script:chkLoadPredictor = New-CheckBox -Parent $gbCore -Text "Load Predictor" -X 15 -Y 88 -Checked ($Script:Engines.LoadPredictor -eq $true) -Width 250
$toolTip.SetToolTip($Script:chkLoadPredictor, " Przewiduje przyszle obciazenie CPU. Przygotowuje system na nadchodzace wymagania wydajnosci.")
$gbAdvanced = New-GroupBox -Parent $tabSettings -Title "ADVANCED Engines (Optional)" -X 10 -Y 520 -Width 550 -Height 150
$Script:chkQLearning = New-CheckBox -Parent $gbAdvanced -Text "Q-Learning (Reinforcement)" -X 15 -Y 28 -Checked ($Script:Engines.QLearning -eq $true) -Width 250
$toolTip.SetToolTip($Script:chkQLearning, " Reinforcement Learning z 47 stanami systemowymi. Uczy sie optymalnych decyzji przez system nagrod i kar.")
$Script:chkNeuralBrain = New-CheckBox -Parent $gbAdvanced -Text "Neural Brain (Weights)" -X 280 -Y 28 -Checked ($Script:Engines.NeuralBrain -eq $true) -Width 250
$toolTip.SetToolTip($Script:chkNeuralBrain, " Siec neuronowa z wagami aplikacji. Gleboka analiza zachowan procesow i pamiec dlugoterminowa.")
$Script:chkEnsemble = New-CheckBox -Parent $gbAdvanced -Text "Ensemble (Voting)" -X 15 -Y 58 -Checked ($Script:Engines.Ensemble -eq $true) -Width 250
$toolTip.SetToolTip($Script:chkEnsemble, " Glosowanie wielu silnikow AI. Najstabilniejsze decyzje kosztem wydajnosci.")
# v43: Nowe checkboxy dla Bandit, Genetic, Energy
$Script:chkBandit = New-CheckBox -Parent $gbAdvanced -Text "Bandit (Thompson Sampling)" -X 280 -Y 58 -Checked ($(if ($Script:Engines.Bandit -eq $null) { $true } else { $Script:Engines.Bandit })) -Width 250
$toolTip.SetToolTip($Script:chkBandit, " Multi-Armed Bandit - adaptacyjny wybor trybu. Balansuje eksploracje i eksploatacje.")
$Script:chkGenetic = New-CheckBox -Parent $gbAdvanced -Text "Genetic (Evolution)" -X 15 -Y 88 -Checked ($(if ($Script:Engines.Genetic -eq $null) { $true } else { $Script:Engines.Genetic })) -Width 250
$toolTip.SetToolTip($Script:chkGenetic, " Algorytm genetyczny ewoluuje parametry. Samodoskonalenie progow i wag.")
$Script:chkEnergy = New-CheckBox -Parent $gbAdvanced -Text "Energy (Efficiency)" -X 280 -Y 88 -Checked ($(if ($Script:Engines.Energy -eq $null) { $true } else { $Script:Engines.Energy })) -Width 250
$toolTip.SetToolTip($Script:chkEnergy, " Tracker efektywnosci energetycznej. Optymalizuje zuzycie energii vs wydajnosc.")
# #
#  SYNC v43: AI THRESHOLDS - zsynchronizowane z ENGINE
# #
$gbAIThresholds = New-GroupBox -Parent $tabSettings -Title " AI Decision Thresholds (SYNC)" -X 10 -Y 680 -Width 550 -Height 120
$aiTurboThr = if ($Script:Config.AIThresholds.TurboThreshold) { $Script:Config.AIThresholds.TurboThreshold } else { 72 }
$aiBalancedThr = if ($Script:Config.AIThresholds.BalancedThreshold) { $Script:Config.AIThresholds.BalancedThreshold } else { 38 }
$aiForceSilent = if ($Script:Config.AIThresholds.ForceSilentCPU) { $Script:Config.AIThresholds.ForceSilentCPU } else { 20 }
$aiForceSilentInact = if ($Script:Config.AIThresholds.ForceSilentCPUInactive) { $Script:Config.AIThresholds.ForceSilentCPUInactive } else { 25 }
New-Label -Parent $gbAIThresholds -Text "Turbo CPU%:" -X 15 -Y 28 -Width 90 -Height 22
$Script:numAITurboThr = New-NumericUpDown -Parent $gbAIThresholds -X 110 -Y 25 -Min 50 -Max 95 -Value $aiTurboThr -Width 60
New-Label -Parent $gbAIThresholds -Text "Balanced CPU%:" -X 190 -Y 28 -Width 100 -Height 22
$Script:numAIBalancedThr = New-NumericUpDown -Parent $gbAIThresholds -X 295 -Y 25 -Min 20 -Max 70 -Value $aiBalancedThr -Width 60
New-Label -Parent $gbAIThresholds -Text "Silent CPU%:" -X 15 -Y 65 -Width 90 -Height 22
$Script:numAIForceSilent = New-NumericUpDown -Parent $gbAIThresholds -X 110 -Y 62 -Min 5 -Max 35 -Value $aiForceSilent -Width 60
New-Label -Parent $gbAIThresholds -Text "Silent Inactive%:" -X 190 -Y 65 -Width 100 -Height 22
$Script:numAIForceSilentInact = New-NumericUpDown -Parent $gbAIThresholds -X 295 -Y 62 -Min 5 -Max 45 -Value $aiForceSilentInact -Width 60
$toolTip.SetToolTip($Script:numAITurboThr, " CPU% powyzej ktorego AI wlacza TURBO (domyslnie 72%)")
$toolTip.SetToolTip($Script:numAIBalancedThr, " CPU% powyzej ktorego AI wlacza BALANCED (domyslnie 38%)")
$toolTip.SetToolTip($Script:numAIForceSilent, " CPU% ponizej ktorego AI wymusza SILENT (domyslnie 20%)")
$toolTip.SetToolTip($Script:numAIForceSilentInact, " CPU% dla nieaktywnego uzytkownika (domyslnie 25%)")
New-Label -Parent $gbAIThresholds -Text "Te progi kontroluja decyzje AI o zmianie trybow" -X 15 -Y 95 -Width 500 -Height 15 -ForeColor $Script:Colors.TextDim
$btnSaveEngines = New-Button -Parent $tabSettings -Text "SAVE AI ENGINES" -X 10 -Y 810 -Width 180 -Height 40 -BackColor $Script:Colors.Success -ForeColor $Script:Colors.Background -OnClick {
$toolTip.SetToolTip($btnSaveEngines, "✓ Zapisuje konfiguracje systemów AI. Zmiany zastosowane natychmiast.")
    # v43: Pełna lista silników zsynchronizowana z ENGINE
    $newEngines = @{
        Prophet = $Script:chkProphet.Checked; SelfTuner = $Script:chkSelfTuner.Checked
        AnomalyDetector = $Script:chkAnomalyDetector.Checked; ChainPredictor = $Script:chkChainPredictor.Checked
        LoadPredictor = $Script:chkLoadPredictor.Checked; QLearning = $Script:chkQLearning.Checked
        NeuralBrain = $Script:chkNeuralBrain.Checked; Ensemble = $Script:chkEnsemble.Checked
        Bandit = $Script:chkBandit.Checked; Genetic = $Script:chkGenetic.Checked; Energy = $Script:chkEnergy.Checked
    }
    
    # Policz włączone silniki
    $enabledCount = ($newEngines.Values | Where-Object { $_ -eq $true }).Count
    $engineList = @()
    if ($newEngines.Prophet) { $engineList += "Prophet" }
    if ($newEngines.SelfTuner) { $engineList += "SelfTuner" }
    if ($newEngines.AnomalyDetector) { $engineList += "Anomaly" }
    if ($newEngines.ChainPredictor) { $engineList += "Chain" }
    if ($newEngines.LoadPredictor) { $engineList += "LoadPred" }
    if ($newEngines.QLearning) { $engineList += "Q-Learning" }
    if ($newEngines.NeuralBrain) { $engineList += "NeuralBrain" }
    if ($newEngines.Ensemble) { $engineList += "Ensemble" }
    if ($newEngines.Bandit) { $engineList += "Bandit" }
    if ($newEngines.Genetic) { $engineList += "Genetic" }
    if ($newEngines.Energy) { $engineList += "Energy" }
    
    if (Save-AIEngines $newEngines) {
        $Script:Engines = Get-AIEngines
        # Wyślij sygnał reload
        try { Send-ReloadSignal @{ File = "AIEngines" } } catch { }
        
        [System.Windows.Forms.MessageBox]::Show(
            "✓ AI ENGINES ZAPISANE!`n`nWłączone silniki ($enabledCount/11):`n• $($engineList -join "`n• ")`n`n✓ Sygnał RELOAD wysłany do ENGINE`nZmiany aktywne natychmiast.",
            "Zapis AI Engines - Sukces",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } else { 
        [System.Windows.Forms.MessageBox]::Show(
            "✗ BŁĄD ZAPISU!`n`nNie udało się zapisać konfiguracji AI Engines.",
            "Błąd",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}
$btnEnableCore = New-Button -Parent $tabSettings -Text "Enable CORE" -X 200 -Y 810 -Width 110 -Height 40 -BackColor $Script:Colors.AccentDim -ForeColor $Script:Colors.TextBright -OnClick {
    $Script:chkProphet.Checked = $true; $Script:chkSelfTuner.Checked = $true; $Script:chkAnomalyDetector.Checked = $true
    $Script:chkChainPredictor.Checked = $true; $Script:chkLoadPredictor.Checked = $true
    $Script:chkQLearning.Checked = $true; $Script:chkNeuralBrain.Checked = $false; $Script:chkEnsemble.Checked = $false
    # v43: Nowe silniki - CORE includes Bandit, Genetic, Energy
    $Script:chkBandit.Checked = $true; $Script:chkGenetic.Checked = $true; $Script:chkEnergy.Checked = $true
    [System.Windows.Forms.MessageBox]::Show("✓ Zaznaczono CORE engines (9/11):`n• Prophet, SelfTuner, Anomaly, Chain`n• LoadPred, Q-Learning, Bandit`n• Genetic, Energy`n`n⚠ Kliknij 'SAVE AI ENGINES' aby zapisać!", "Enable CORE", "OK", "Information")
}
$btnEnableAll = New-Button -Parent $tabSettings -Text "Enable ALL" -X 320 -Y 810 -Width 100 -Height 40 -BackColor $Script:Colors.Purple -ForeColor $Script:Colors.TextBright -OnClick {
    $Script:chkProphet.Checked = $true; $Script:chkSelfTuner.Checked = $true; $Script:chkAnomalyDetector.Checked = $true
    $Script:chkChainPredictor.Checked = $true; $Script:chkLoadPredictor.Checked = $true
    $Script:chkQLearning.Checked = $true; $Script:chkNeuralBrain.Checked = $true; $Script:chkEnsemble.Checked = $true
    # v43: Nowe silniki
    $Script:chkBandit.Checked = $true; $Script:chkGenetic.Checked = $true; $Script:chkEnergy.Checked = $true
    [System.Windows.Forms.MessageBox]::Show("✓ Zaznaczono WSZYSTKIE engines (11/11)`n`nPełna moc AI!`n`n⚠ Kliknij 'SAVE AI ENGINES' aby zapisać!", "Enable ALL", "OK", "Information")
}
$btnDisableAll = New-Button -Parent $tabSettings -Text "Disable ALL" -X 430 -Y 810 -Width 100 -Height 40 -BackColor $Script:Colors.Danger -ForeColor $Script:Colors.TextBright -OnClick {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Czy na pewno wyłączyć WSZYSTKIE silniki AI?`n`nTo znacząco ograniczy inteligentne zarządzanie CPU!",
        "Potwierdź wyłączenie AI",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq "Yes") {
        $Script:chkProphet.Checked = $false; $Script:chkSelfTuner.Checked = $false; $Script:chkAnomalyDetector.Checked = $false
        $Script:chkChainPredictor.Checked = $false; $Script:chkLoadPredictor.Checked = $false
        $Script:chkQLearning.Checked = $false; $Script:chkNeuralBrain.Checked = $false; $Script:chkEnsemble.Checked = $false
        # v43: Nowe silniki
        $Script:chkBandit.Checked = $false; $Script:chkGenetic.Checked = $false; $Script:chkEnergy.Checked = $false
        [System.Windows.Forms.MessageBox]::Show("⚠ Odznaczono WSZYSTKIE engines (0/11)`n`nAI będzie działać w trybie podstawowym.`n`n⚠ Kliknij 'SAVE AI ENGINES' aby zapisać!", "Disable ALL", "OK", "Warning")
    }
}
$gbOptimization = New-GroupBox -Parent $tabSettings -Title "OPTIMIZATION Settings" -X 580 -Y 500 -Width 530 -Height 270
$preloadEnabled = if ($null -ne $Script:Config.OptimizationSettings.PreloadEnabled) { $Script:Config.OptimizationSettings.PreloadEnabled } else { $true }
$cacheSize = if ($Script:Config.OptimizationSettings.CacheSize) { $Script:Config.OptimizationSettings.CacheSize } else { 50 }
$preBoostDuration = if ($Script:Config.OptimizationSettings.PreBoostDuration) { $Script:Config.OptimizationSettings.PreBoostDuration } else { 15000 }
$predictiveBoostEnabled = if ($null -ne $Script:Config.OptimizationSettings.PredictiveBoostEnabled) { $Script:Config.OptimizationSettings.PredictiveBoostEnabled } else { $true }
$Script:chkPreloadEnabled = New-CheckBox -Parent $gbOptimization -Text " Enable Application Preloading" -X 15 -Y 28 -Checked $preloadEnabled -Width 400
$Script:chkPredictiveBoost = New-CheckBox -Parent $gbOptimization -Text " Predictive Boost for Known Apps" -X 15 -Y 58 -Checked $predictiveBoostEnabled -Width 400
$Script:chkSmartPreload = New-CheckBox -Parent $gbOptimization -Text " Smart Preload (AI Pattern)" -X 15 -Y 88 -Checked $true -Width 200
$Script:chkMemoryCompression = New-CheckBox -Parent $gbOptimization -Text " Memory Compression" -X 220 -Y 88 -Checked $false -Width 180
$Script:chkPowerBoost = New-CheckBox -Parent $gbOptimization -Text " Power Boost Mode" -X 15 -Y 118 -Checked $false -Width 160
$Script:chkPredictiveIO = New-CheckBox -Parent $gbOptimization -Text " Predictive I/O" -X 220 -Y 118 -Checked $true -Width 150
#  Tooltips for optimization controls
$toolTip.SetToolTip($Script:chkPreloadEnabled, " Laduje aplikacje do pamieci przed uruchomieniem. Przyspiesza start programow ale uzywa wiecej RAM.")
$toolTip.SetToolTip($Script:chkPredictiveBoost, " Automatycznie zwieksza priorytet znanych aplikacji przy uruchamianiu. AI przewiduje ktore programy beda uruchomione.")
$toolTip.SetToolTip($Script:chkSmartPreload, " AI analizuje wzorce uzytkowania i laduje aplikacje na podstawie prevoyowanych potrzeb uzytkownika.")
$toolTip.SetToolTip($Script:chkMemoryCompression, " Kompresuje nieaktywne strony pamieci dla lepszej wydajnosci RAM. Oszczedza pamiec ale uzywa CPU.")
$toolTip.SetToolTip($Script:chkPowerBoost, " Zwieksza limity mocy procesora dla lepszej wydajnosci. Moze powodowac wyzsze temperatury.")
$toolTip.SetToolTip($Script:chkPredictiveIO, " Przewiduje operacje dyskowe i optymalizuje dostep do plikow. Przyspiesza ladowanie danych.")
New-Label -Parent $gbOptimization -Text "Cache Size (apps):" -X 15 -Y 148 -Width 160 -Height 22
$Script:numCacheSize = New-NumericUpDown -Parent $gbOptimization -X 180 -Y 145 -Min 10 -Max 200 -Value $cacheSize -Width 80 -Increment 10
New-Label -Parent $gbOptimization -Text "Pre-Boost Duration (ms):" -X 15 -Y 178 -Width 160 -Height 22
$Script:numPreBoostDuration = New-NumericUpDown -Parent $gbOptimization -X 180 -Y 175 -Min 5000 -Max 30000 -Value $preBoostDuration -Width 80 -Increment 1000
#  Tooltips for numeric controls
$toolTip.SetToolTip($Script:numCacheSize, " Liczba aplikacji trzymanych w pamieci cache. Wiecej = szybsze uruchamianie, ale wiecej RAM.")
$toolTip.SetToolTip($Script:numPreBoostDuration, " Jak dlugo wzmocnienie wydajnosci jest aktywne (w milisekundach). 15000ms = 15 sekund.")
# Performance Sliders (compact)
New-Label -Parent $gbOptimization -Text "CPU Aggro:" -X 15 -Y 208 -Width 80 -Height 15
$Script:trackCPUAggro = New-Object System.Windows.Forms.TrackBar
$Script:trackCPUAggro.Location = New-Object System.Drawing.Point(95, 205)
$Script:trackCPUAggro.Size = New-Object System.Drawing.Size(100, 25)
$Script:trackCPUAggro.Minimum = 10; $Script:trackCPUAggro.Maximum = 100; $Script:trackCPUAggro.Value = 50
$gbOptimization.Controls.Add($Script:trackCPUAggro)
New-Label -Parent $gbOptimization -Text "Mem Aggro:" -X 200 -Y 208 -Width 80 -Height 15
$Script:trackMemoryAggro = New-Object System.Windows.Forms.TrackBar
$Script:trackMemoryAggro.Location = New-Object System.Drawing.Point(280, 205)
$Script:trackMemoryAggro.Size = New-Object System.Drawing.Size(100, 25)
$Script:trackMemoryAggro.Minimum = 10; $Script:trackMemoryAggro.Maximum = 80; $Script:trackMemoryAggro.Value = 30
$gbOptimization.Controls.Add($Script:trackMemoryAggro)
New-Label -Parent $gbOptimization -Text "I/O Priority:" -X 15 -Y 238 -Width 80 -Height 15
$Script:trackIOPriority = New-Object System.Windows.Forms.TrackBar
$Script:trackIOPriority.Location = New-Object System.Drawing.Point(95, 235)
$Script:trackIOPriority.Size = New-Object System.Drawing.Size(100, 25)
$Script:trackIOPriority.Minimum = 1; $Script:trackIOPriority.Maximum = 5; $Script:trackIOPriority.Value = 3
$gbOptimization.Controls.Add($Script:trackIOPriority)
#  Tooltips for slider controls
$toolTip.SetToolTip($Script:trackCPUAggro, " Agresywnosc optymalizacji CPU. Wyzsze = wiecej boostow ale wieksze zuzycie energii.")
$toolTip.SetToolTip($Script:trackMemoryAggro, " Agresywnosc zarzadzania pamiecia. Wyzsze = wiecej operacji na RAM, lepsze cache.")
$toolTip.SetToolTip($Script:trackIOPriority, " Priorytet operacji wejscia/wyjscia dysku. Wyzszy = szybszy dostep do plikow.")
New-Label -Parent $gbOptimization -Text "Intelligent optimization + caching" -X 15 -Y 255 -Width 400 -Height 15 -ForeColor $Script:Colors.TextDim
# I/O Settings
$gbIO = New-GroupBox -Parent $tabSettings -Title "I/O Settings (Disk)" -X 580 -Y 10 -Width 530 -Height 150
$ioRead = if ($Script:Config.IOSettings.ReadThreshold) { $Script:Config.IOSettings.ReadThreshold } else { 80 }
$ioWrite = if ($Script:Config.IOSettings.WriteThreshold) { $Script:Config.IOSettings.WriteThreshold } else { 50 }
$ioSens = if ($Script:Config.IOSettings.Sensitivity) { $Script:Config.IOSettings.Sensitivity } else { 4 }
$ioTurbo = if ($Script:Config.IOSettings.TurboThreshold) { $Script:Config.IOSettings.TurboThreshold } else { 150 }
$null = New-Label -Parent $gbIO -Text "Read (MB/s):" -X 15 -Y 28 -Width 100 -Height 22
$Script:numIORead = New-NumericUpDown -Parent $gbIO -X 120 -Y 25 -Min 1 -Max 500 -Value $ioRead -Width 80 -Increment 10
$null = New-Label -Parent $gbIO -Text "Write (MB/s):" -X 220 -Y 28 -Width 100 -Height 22
$Script:numIOWrite = New-NumericUpDown -Parent $gbIO -X 325 -Y 25 -Min 1 -Max 400 -Value $ioWrite -Width 80 -Increment 10
$null = New-Label -Parent $gbIO -Text "Sensitivity:" -X 15 -Y 65 -Width 100 -Height 22
$Script:numIOSensitivity = New-NumericUpDown -Parent $gbIO -X 120 -Y 62 -Min 1 -Max 10 -Value $ioSens -Width 80
$null = New-Label -Parent $gbIO -Text "Turbo IO:" -X 220 -Y 65 -Width 100 -Height 22
$Script:numIOTurbo = New-NumericUpDown -Parent $gbIO -X 325 -Y 62 -Min 1 -Max 800 -Value $ioTurbo -Width 80 -Increment 10
$ioOverride = if ($null -ne $Script:Config.IOSettings.OverrideForceMode) { $Script:Config.IOSettings.OverrideForceMode } else { $false }
$Script:chkIOOverride = New-CheckBox -Parent $gbIO -Text "I/O can override ForceMode" -X 15 -Y 100 -Checked $ioOverride -Width 300

# === ULTRA NETWORK SETTINGS ===
$gbNetworkUltra = New-GroupBox -Parent $tabSettings -Title "ULTRA Network Settings (Maximum Speed)" -X 580 -Y 300 -Width 530 -Height 195
$null = New-Label -Parent $gbNetworkUltra -Text "Zaawansowane optymalizacje sieci dla maksymalnej przepustowości" -X 15 -Y 25 -Width 500 -Height 20 -ForeColor $Script:Colors.TextDim

# Wczytaj aktualne wartości z istniejącego config.json (jeśli istnieje)
$currentConfig = Get-Config
# FIX v40: Użyj DefaultConfig jako fallback gdy config.json nie ma sekcji Network
$netMaxBuf = if ($null -ne $currentConfig.Network -and $null -ne $currentConfig.Network.MaximizeTCPBuffers) { $currentConfig.Network.MaximizeTCPBuffers } else { $Script:DefaultConfig.Network.MaximizeTCPBuffers }
$netWinScale = if ($null -ne $currentConfig.Network -and $null -ne $currentConfig.Network.EnableWindowScaling) { $currentConfig.Network.EnableWindowScaling } else { $Script:DefaultConfig.Network.EnableWindowScaling }
$netRSS = if ($null -ne $currentConfig.Network -and $null -ne $currentConfig.Network.EnableRSS) { $currentConfig.Network.EnableRSS } else { $Script:DefaultConfig.Network.EnableRSS }
$netLSO = if ($null -ne $currentConfig.Network -and $null -ne $currentConfig.Network.EnableLSO) { $currentConfig.Network.EnableLSO } else { $Script:DefaultConfig.Network.EnableLSO }
$netChimney = if ($null -ne $currentConfig.Network -and $null -ne $currentConfig.Network.DisableChimney) { $currentConfig.Network.DisableChimney } else { $Script:DefaultConfig.Network.DisableChimney }

# Checkboxy
$Script:chkNetMaxBuffers = New-CheckBox -Parent $gbNetworkUltra -Text " Maximize TCP Buffers (64KB-16MB)" -X 15 -Y 50 -Checked $netMaxBuf -Width 500
$toolTip.SetToolTip($Script:chkNetMaxBuffers, " Maksymalne bufory TCP/IP dla gigabitowych połączeń (TcpWindowSize=65535, GlobalMax=16MB)")

$Script:chkNetWindowScaling = New-CheckBox -Parent $gbNetworkUltra -Text " TCP Window Scaling (High Bandwidth)" -X 15 -Y 75 -Checked $netWinScale -Width 500
$toolTip.SetToolTip($Script:chkNetWindowScaling, " Włącz TCP Window Scaling dla wysokich przepustowości gigabit+ (Tcp1323Opts=3)")

$Script:chkNetRSS = New-CheckBox -Parent $gbNetworkUltra -Text " RSS - Receive Side Scaling (Multi-Core)" -X 15 -Y 100 -Checked $netRSS -Width 500
$toolTip.SetToolTip($Script:chkNetRSS, " Rozłóż przetwarzanie pakietów sieciowych na wiele rdzeni CPU")

$Script:chkNetLSO = New-CheckBox -Parent $gbNetworkUltra -Text " LSO - Large Send Offload (Big Transfers)" -X 15 -Y 125 -Checked $netLSO -Width 500
$toolTip.SetToolTip($Script:chkNetLSO, " Optymalizacja dla dużych transferów plików (download/upload)")

$Script:chkNetChimney = New-CheckBox -Parent $gbNetworkUltra -Text " Disable TCP Chimney (Stability)" -X 15 -Y 150 -Checked $netChimney -Width 500
$toolTip.SetToolTip($Script:chkNetChimney, " Wyłącz TCP Chimney Offload (może powodować problemy z stabilnością połączeń)")

$null = New-Label -Parent $gbNetworkUltra -Text "Wymaga RESTARTU ENGINE!" -X 15 -Y 175 -Width 200 -Height 20 -ForeColor $Script:Colors.Warning -FontStyle ([System.Drawing.FontStyle]::Bold)

# Przycisk RESET TO DEFAULTS
# Przycisk WIN DEFAULT - przywraca domyślne Windows
$btnRestoreNetworkDefaults = New-Button -Parent $gbNetworkUltra -Text "WIN DEFAULT" -X 220 -Y 170 -Width 110 -Height 25 -BackColor ([System.Drawing.Color]::FromArgb(100, 60, 60)) -ForeColor $Script:Colors.Text -OnClick {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Czy na pewno chcesz przywrocic DOMYSLNE ustawienia sieciowe Windows?`n`n" +
        "Ta operacja:`n" +
        "- Usunie optymalizacje TCP/IP`n" +
        "- Przywroci auto-tuning Windows`n" +
        "- Wlaczy TCP Chimney (automatic)`n" +
        "- Przywroci Network Throttling`n`n" +
        "Wymaga RESTARTU ENGINE!",
        "Przywroc domyslne Windows",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $Script:chkNetMaxBuffers.Checked = $false
        $Script:chkNetWindowScaling.Checked = $false
        $Script:chkNetRSS.Checked = $false
        $Script:chkNetLSO.Checked = $false
        $Script:chkNetChimney.Checked = $false
        
        try {
            $currentConfig = Get-Config
            $currentConfig.Network.MaximizeTCPBuffers = $false
            $currentConfig.Network.EnableWindowScaling = $false
            $currentConfig.Network.EnableRSS = $false
            $currentConfig.Network.EnableLSO = $false
            $currentConfig.Network.DisableChimney = $false
            Save-Config $currentConfig
        } catch { }
        
        try { Send-ReloadSignal @{ Type = "NetworkDefaults"; Action = "RestoreAll" } } catch { }
        
        [System.Windows.Forms.MessageBox]::Show(
            "Ustawienia zapisane!`n`nWAZNE: Zrestartuj ENGINE aby zmiany zostaly zastosowane.",
            "Gotowe", "OK", "Information"
        )
    }
}
$toolTip.SetToolTip($btnRestoreNetworkDefaults, "Przywroc DOMYSLNE ustawienia sieciowe Windows (wylacz wszystkie optymalizacje)")

# Przycisk RESET TO MAX
$btnResetNetworkUltra = New-Button -Parent $gbNetworkUltra -Text " RESET TO MAX" -X 340 -Y 170 -Width 130 -Height 25 -BackColor $Script:Colors.Accent -ForeColor $Script:Colors.Background -OnClick {
    # Przywróć wszystkie ULTRA settings do TRUE (maksymalna wydajność)
    $Script:chkNetMaxBuffers.Checked = $true
    $Script:chkNetWindowScaling.Checked = $true
    $Script:chkNetRSS.Checked = $true
    $Script:chkNetLSO.Checked = $true
    $Script:chkNetChimney.Checked = $true
    [System.Windows.Forms.MessageBox]::Show("Przywrócono ULTRA Network settings do wartości domyślnych (WSZYSTKO WŁĄCZONE).`n`nKliknij 'SAVE ALL SETTINGS' aby zapisać!", "Reset Complete", "OK", "Information")
}
$toolTip.SetToolTip($btnResetNetworkUltra, "Przywróć wszystkie ULTRA Network settings do domyślnych wartości (maksymalna wydajność)")

$gbStorage = New-GroupBox -Parent $tabSettings -Title "Storage Mode (Data Sharing)" -X 580 -Y 165 -Width 530 -Height 130
$null = New-Label -Parent $gbStorage -Text "Choose how data is shared between Engine and Console:" -X 15 -Y 25 -Width 500 -Height 20 -ForeColor $Script:Colors.TextDim
$Script:rbStorageJSON = New-Object System.Windows.Forms.RadioButton
$Script:rbStorageJSON.Location = New-Object System.Drawing.Point(15, 50)
$Script:rbStorageJSON.Size = New-Object System.Drawing.Size(180, 25)
$Script:rbStorageJSON.Text = " JSON only (safe)"
$Script:rbStorageJSON.ForeColor = $Script:Colors.Text
$Script:rbStorageJSON.Checked = ($Script:UseJSONStorage -and -not $Script:UseRAMStorage)
$gbStorage.Controls.Add($Script:rbStorageJSON)
$Script:rbStorageRAM = New-Object System.Windows.Forms.RadioButton
$Script:rbStorageRAM.Location = New-Object System.Drawing.Point(210, 50)
$Script:rbStorageRAM.Size = New-Object System.Drawing.Size(180, 25)
$Script:rbStorageRAM.Text = " RAM only (fast)"
$Script:rbStorageRAM.ForeColor = $Script:Colors.Text
$Script:rbStorageRAM.Checked = ($Script:UseRAMStorage -and -not $Script:UseJSONStorage)
$gbStorage.Controls.Add($Script:rbStorageRAM)
$Script:rbStorageBOTH = New-Object System.Windows.Forms.RadioButton
$Script:rbStorageBOTH.Location = New-Object System.Drawing.Point(400, 50)
$Script:rbStorageBOTH.Size = New-Object System.Drawing.Size(110, 25)
$Script:rbStorageBOTH.Text = " BOTH"
$Script:rbStorageBOTH.ForeColor = $Script:Colors.Text
$Script:rbStorageBOTH.Checked = ($Script:UseJSONStorage -and $Script:UseRAMStorage)
$gbStorage.Controls.Add($Script:rbStorageBOTH)
$btnApplyStorage = New-Button -Parent $gbStorage -Text " Save & Apply Storage" -X 15 -Y 85 -Width 200 -Height 35 -BackColor $Script:Colors.Accent -ForeColor $Script:Colors.Background -OnClick {
    $useJSON = $Script:rbStorageJSON.Checked -or $Script:rbStorageBOTH.Checked
    $useRAM = $Script:rbStorageRAM.Checked -or $Script:rbStorageBOTH.Checked
    if (Set-StorageMode -UseJSON $useJSON -UseRAM $useRAM) {
        $mode = if ($useJSON -and $useRAM) { "JSON + RAM (both)" } elseif ($useRAM) { "RAM only" } else { "JSON only" }
        [System.Windows.Forms.MessageBox]::Show("Storage mode changed to: $mode`n`nChanges applied immediately!", "Storage Mode", "OK", "Information")
        try { 
            $modeStr = if ($useJSON -and $useRAM) { "BOTH" } elseif ($useRAM) { "RAM" } else { "JSON" }
            Send-ReloadSignal @{ Type = "StorageMode"; Mode = $modeStr }
        } catch { }
    } else {
        [System.Windows.Forms.MessageBox]::Show("Failed to save storage mode!", "Error", "OK", "Error")
    }
}
# Save Button (Przesuniety ponizej Optimization)
$btnSaveSettings = New-Button -Parent $tabSettings -Text " SAVE ALL SETTINGS" -X 10 -Y 860 -Width 250 -Height 40 -BackColor $Script:Colors.Success -ForeColor $Script:Colors.Background -OnClick {
$toolTip.SetToolTip($btnSaveSettings, " Zapisuje wszystkie ustawienia CONFIGURATORA: kolory, preferencje, opcje AI. Globalne ustawienia programu.")
    # Walidacja
    $errors = @()
    foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
        if ($Script:PowerControls[$mode].Min.Value -gt $Script:PowerControls[$mode].Max.Value) { $errors += "$mode`: Min > Max" }
    }
    if ($errors.Count -gt 0) { [System.Windows.Forms.MessageBox]::Show("Validation errors:`n$($errors -join "`n")", "Error", "OK", "Warning"); return }
    # #
    # 1. POWER MODES + BOOST + I/O
    # #
    $newConfig = @{
        ForceMode = switch ($Script:cmbForceMode.SelectedIndex) { 1 { "Silent" } 2 { "Silent Lock" } 3 { "Balanced" } 4 { "Turbo" } 5 { "Extreme" } default { "" } }
        PowerModes = @{}
        BoostSettings = @{
            BoostDuration = [int]$Script:numBoostDuration.Value
            BoostCooldown = [int]$Script:numBoostCooldown.Value
            AutoBoostEnabled = $Script:chkAutoBoost.Checked
            EnableBoostForAllAppsOnStart = $Script:chkStartupBoost.Checked
            AppLaunchSensitivity = @{ CPUDelta = 12; CPUThreshold = 22 }
            AutoBoostSampleMs = 350; StartupBoostDurationSeconds = 3
            ActivityBasedBoost = $Script:chkActivityBoost.Checked
            ActivityIdleThreshold = [int]$Script:numActivityIdleThreshold.Value
            ActivityMaxBoostTime = [int]$Script:numActivityMaxBoost.Value
        }
        IOSettings = @{
            ReadThreshold = [int]$Script:numIORead.Value; WriteThreshold = [int]$Script:numIOWrite.Value
            Sensitivity = [int]$Script:numIOSensitivity.Value; TurboThreshold = [int]$Script:numIOTurbo.Value
            OverrideForceMode = $Script:chkIOOverride.Checked; CheckInterval = 1200; ExtremeGraceSeconds = 8
        }
        OptimizationSettings = @{
            PreloadEnabled = $Script:chkPreloadEnabled.Checked
            CacheSize = [int]$Script:numCacheSize.Value
            PreBoostDuration = [int]$Script:numPreBoostDuration.Value
            PredictiveBoostEnabled = $Script:chkPredictiveBoost.Checked
        }
        #  SYNC v40: AIThresholds - zsynchronizowane z ENGINE (efektywność energetyczna)
        AIThresholds = @{
            TurboThreshold = [int]$Script:numAITurboThr.Value
            BalancedThreshold = [int]$Script:numAIBalancedThr.Value
            ForceSilentCPU = [int]$Script:numAIForceSilent.Value
            ForceSilentCPUInactive = [int]$Script:numAIForceSilentInact.Value
        }
        LearningSettings = @{
            BiasInfluence = if ($Script:trackBiasInfluence) { [int]$Script:trackBiasInfluence.Value } else { 25 }
            ConfidenceThreshold = if ($Script:trackConfidenceThreshold) { [int]$Script:trackConfidenceThreshold.Value } else { 70 }
            LearningMode = if ($Script:cmbLearningMode -and $Script:cmbLearningMode.SelectedItem) { $Script:cmbLearningMode.SelectedItem.ToString() } else { "AUTO" }
        }
        # ULTRA Network Settings
        Network = @{
            Enabled = $true  # Zawsze włączone
            DisableNagle = $true  # Zawsze włączone
            OptimizeTCP = $true  # Zawsze włączone
            OptimizeDNS = $true  # Zawsze włączone
            # ULTRA settings (kontrolowane przez checkboxy)
            MaximizeTCPBuffers = if ($Script:chkNetMaxBuffers) { $Script:chkNetMaxBuffers.Checked } else { $true }
            EnableWindowScaling = if ($Script:chkNetWindowScaling) { $Script:chkNetWindowScaling.Checked } else { $true }
            EnableRSS = if ($Script:chkNetRSS) { $Script:chkNetRSS.Checked } else { $true }
            EnableLSO = if ($Script:chkNetLSO) { $Script:chkNetLSO.Checked } else { $true }
            DisableChimney = if ($Script:chkNetChimney) { $Script:chkNetChimney.Checked } else { $true }
        }
    }
    foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
        $newConfig.PowerModes[$mode] = @{ Min = [int]$Script:PowerControls[$mode].Min.Value; Max = [int]$Script:PowerControls[$mode].Max.Value }
    }
    #  SYNC v40: Zapisz PowerModesIntel (osobne wartosci dla Intel) - FIX: używamy wartości z GUI!
    $newConfig.PowerModesIntel = @{}
    foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
        $newConfig.PowerModesIntel[$mode] = @{ 
            Min = [int]$Script:PowerControlsIntel[$mode].Min.Value
            Max = [int]$Script:PowerControlsIntel[$mode].Max.Value 
        }
    }
    # #
    # 2. STORAGE MODE
    # #
    $useJSON = $Script:rbStorageJSON.Checked -or $Script:rbStorageBOTH.Checked
    $useRAM = $Script:rbStorageRAM.Checked -or $Script:rbStorageBOTH.Checked
    $storageOK = Set-StorageMode -UseJSON $useJSON -UseRAM $useRAM
    # #
    # 3. AI ENGINES
    # #
    $newEngines = @{
        Prophet = $Script:chkProphet.Checked; SelfTuner = $Script:chkSelfTuner.Checked
        AnomalyDetector = $Script:chkAnomalyDetector.Checked; ChainPredictor = $Script:chkChainPredictor.Checked
        LoadPredictor = $Script:chkLoadPredictor.Checked; QLearning = $Script:chkQLearning.Checked
        NeuralBrain = $Script:chkNeuralBrain.Checked; Ensemble = $Script:chkEnsemble.Checked
    }
    $enginesOK = Save-AIEngines $newEngines
    if ($enginesOK) { $Script:Engines = Get-AIEngines }
    # #
    # 4. TDP PROFILES (tylko jesli kontrolki TDP zostaly juz utworzone)
    # #
    $tdpOK = $false
    if ($Script:TDPControls -and $Script:TDPControls.Count -gt 0) {
        $newTDP = @{}
        foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
            if ($Script:TDPControls[$mode]) {
                $newTDP[$mode] = @{
                    STAPM = [int]$Script:TDPControls[$mode].STAPM.Value
                    Fast = [int]$Script:TDPControls[$mode].Fast.Value
                    Slow = [int]$Script:TDPControls[$mode].Slow.Value
                    Tctl = [int]$Script:TDPControls[$mode].Tctl.Value
                }
            }
        }
        if ($newTDP.Count -gt 0) {
            $tdpOK = Save-TDPConfig $newTDP
            if ($tdpOK) { $Script:TDPConfig = Get-TDPConfig }
        }
    }
    # #
    # 5. ZAPISZ CONFIG I POKAZ WYNIK
    # #
    if (Save-Config $newConfig) {
        $Script:Config = Get-Config
        if ($Script:chkSmartPreload) { $Script:chkSmartPreload.Checked = if ($null -ne $Script:Config.SmartPreload) { $Script:Config.SmartPreload } else { $true } }
        if ($Script:chkMemoryCompression) { $Script:chkMemoryCompression.Checked = if ($null -ne $Script:Config.MemoryCompression) { $Script:Config.MemoryCompression } else { $false } }
        if ($Script:chkPowerBoost) { $Script:chkPowerBoost.Checked = if ($null -ne $Script:Config.PowerBoost) { $Script:Config.PowerBoost } else { $false } }
        if ($Script:chkPredictiveIO) { $Script:chkPredictiveIO.Checked = if ($null -ne $Script:Config.PredictiveIO) { $Script:Config.PredictiveIO } else { $true } }
        if ($Script:trackCPUAggro) { $Script:trackCPUAggro.Value = if ($Script:Config.CPUAgressiveness) { $Script:Config.CPUAgressiveness } else { 50 } }
        if ($Script:trackMemoryAggro) { $Script:trackMemoryAggro.Value = if ($Script:Config.MemoryAgressiveness) { $Script:Config.MemoryAgressiveness } else { 30 } }
        if ($Script:trackIOPriority) { $Script:trackIOPriority.Value = if ($Script:Config.IOPriority) { $Script:Config.IOPriority } else { 3 } }
        
        # Podsumowanie zapisanych modulow
        $summary = @()
        $summary += "✓ Power Modes AMD (RyzenAdj)"
        $summary += "✓ Power Modes Intel (Speed Shift)"
        $summary += "✓ Boost Settings (Duration, Cooldown, Activity)"
        $summary += "✓ I/O Settings (Thresholds, Sensitivity)"
        $summary += "✓ AI Thresholds (Turbo: $([int]$Script:numAITurboThr.Value)%, Balanced: $([int]$Script:numAIBalancedThr.Value)%)"
        if ($storageOK) {
            $mode = if ($useJSON -and $useRAM) { "JSON+RAM" } elseif ($useRAM) { "RAM only" } else { "JSON only" }
            $summary += "✓ Storage Mode: $mode"
        }
        if ($enginesOK) { $summary += "✓ AI Engines (8 silników)" }
        if ($tdpOK) { $summary += "✓ TDP Profiles (RyzenAdj)" }
        
        # Sprawdź czy Network wymaga restartu
        $networkChanged = $false
        if ($Script:chkNetMaxBuffers -or $Script:chkNetWindowScaling -or $Script:chkNetRSS) {
            $summary += ""
            $summary += "⚠ Network Settings (wymaga RESTART ENGINE)"
        }
        
        # Wyslij sygnal reload do ENGINE
        $reloadSent = $false
        try { 
            Send-ReloadSignal @{ Action = "SaveAppsConfig"; File = "Config" }
            $reloadSent = $true
        } catch { }
        
        $statusMsg = if ($reloadSent) {
            "`n`n✓ Sygnał RELOAD wysłany do ENGINE`nZmiany zostaną zastosowane w ciągu 5 sekund."
        } else {
            "`n`n⚠ Nie udało się wysłać sygnału do ENGINE`nZmiany zostaną zastosowane przy następnym uruchomieniu."
        }
        
        [System.Windows.Forms.MessageBox]::Show(
            "═══ WSZYSTKIE USTAWIENIA ZAPISANE! ═══`n`n$($summary -join "`n")$statusMsg",
            "✓ Zapis zakończony pomyślnie",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "✗ BŁĄD ZAPISU!`n`nNie udało się zapisać ustawień do config.json.`n`nSprawdź:`n- Czy masz uprawnienia do zapisu`n- Czy folder C:\CPUManager istnieje`n- Czy dysk nie jest pełny",
            "Błąd zapisu",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}
$btnResetSettings = New-Button -Parent $tabSettings -Text "⟲ Reset to Defaults" -X 270 -Y 860 -Width 180 -Height 40 -BackColor ([System.Drawing.Color]::FromArgb(80,60,40)) -ForeColor $Script:Colors.Text -OnClick {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Czy na pewno zresetować WSZYSTKIE ustawienia do domyślnych?`n`nTo przywróci:`n- Power Modes (CPU %)`n- Boost Settings`n- I/O Settings`n- AI Thresholds`n- AI Engines`n- Storage Mode`n`nUWAGA: Zmiany nie zostaną zastosowane dopóki nie klikniesz 'SAVE ALL SETTINGS'!",
        "Potwierdź reset ustawień",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    
    if ($result -ne "Yes") { return }
    
    # Power Modes AMD
    $Script:cmbForceMode.SelectedIndex = 0
    foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
        $Script:PowerControls[$mode].Min.Value = $Script:DefaultConfig.PowerModes.$mode.Min
        $Script:PowerControls[$mode].Max.Value = $Script:DefaultConfig.PowerModes.$mode.Max
    }
    # Power Modes Intel - FIX: dodano reset dla Intel!
    foreach ($mode in @("Silent", "Balanced", "Turbo", "Extreme")) {
        $Script:PowerControlsIntel[$mode].Min.Value = $Script:DefaultConfig.PowerModesIntel.$mode.Min
        $Script:PowerControlsIntel[$mode].Max.Value = $Script:DefaultConfig.PowerModesIntel.$mode.Max
    }
    # Boost Settings
    $Script:numBoostDuration.Value = 10000; $Script:numBoostCooldown.Value = 20
    $Script:chkAutoBoost.Checked = $true; $Script:chkStartupBoost.Checked = $true
    $Script:chkActivityBoost.Checked = $true
    $Script:numActivityIdleThreshold.Value = 5; $Script:numActivityMaxBoost.Value = 30
    # I/O Settings
    $Script:numIORead.Value = 80; $Script:numIOWrite.Value = 50
    $Script:numIOSensitivity.Value = 4; $Script:numIOTurbo.Value = 150
    $Script:chkIOOverride.Checked = $false
    # OPTIMIZATION Settings
    $Script:chkPreloadEnabled.Checked = $true; $Script:chkPredictiveBoost.Checked = $true
    $Script:numCacheSize.Value = 50; $Script:numPreBoostDuration.Value = 15000
    $Script:chkSmartPreload.Checked = $true; $Script:chkMemoryCompression.Checked = $false
    $Script:chkPowerBoost.Checked = $false; $Script:chkPredictiveIO.Checked = $true
    $Script:trackCPUAggro.Value = 50; $Script:trackMemoryAggro.Value = 30; $Script:trackIOPriority.Value = 3
    # AI Decision Thresholds - POPRAWIONE WARTOŚCI DOMYŚLNE
    $Script:numAITurboThr.Value = 72; $Script:numAIBalancedThr.Value = 38
    $Script:numAIForceSilent.Value = 20; $Script:numAIForceSilentInact.Value = 25
    # AI Engines - CORE enabled
    $Script:chkProphet.Checked = $true; $Script:chkSelfTuner.Checked = $true
    $Script:chkAnomalyDetector.Checked = $true; $Script:chkChainPredictor.Checked = $true
    $Script:chkLoadPredictor.Checked = $true; $Script:chkQLearning.Checked = $true
    $Script:chkNeuralBrain.Checked = $true; $Script:chkEnsemble.Checked = $true
    # Storage Mode - BOTH
    $Script:rbStorageBOTH.Checked = $true
    # Network ULTRA - domyślne ON
    if ($Script:chkNetMaxBuffers) { $Script:chkNetMaxBuffers.Checked = $true }
    if ($Script:chkNetWindowScaling) { $Script:chkNetWindowScaling.Checked = $true }
    if ($Script:chkNetRSS) { $Script:chkNetRSS.Checked = $true }
    if ($Script:chkNetLSO) { $Script:chkNetLSO.Checked = $true }
    if ($Script:chkNetChimney) { $Script:chkNetChimney.Checked = $true }
    
    [System.Windows.Forms.MessageBox]::Show(
        "✓ Wszystkie ustawienia zresetowane do domyślnych!`n`n═══ DOMYŚLNE WARTOŚCI ═══`n`nAI Thresholds:`n• Turbo: 72% CPU`n• Balanced: 38% CPU`n• Silent: 20% CPU`n• Silent Inactive: 25% CPU`n`nPower Modes: Standardowe zakresy`nAI Engines: Wszystkie włączone (11/11)`nStorage: JSON + RAM`n`n⚠ WAŻNE: Kliknij 'SAVE ALL SETTINGS' aby zapisać i zastosować zmiany!",
        "Reset zakończony",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}
# #
# TAB 6: DATABASE (ProphetMemory)
# #
$tabDatabase = New-Object System.Windows.Forms.TabPage
$tabDatabase.Text = "Database"
$tabDatabase.BackColor = $Script:Colors.Background
$tabDatabase.AutoScroll = $true  #  v39.5.1: Enable scroll
$tabs.TabPages.Add($tabDatabase)
$gbDatabase = New-GroupBox -Parent $tabDatabase -Title "ProphetMemory - Learned Applications" -X 10 -Y 10 -Width 1100 -Height 380
$Script:txtDatabase = New-Object System.Windows.Forms.TextBox
$Script:txtDatabase.Location = New-Object System.Drawing.Point(15, 25)
$Script:txtDatabase.Size = New-Object System.Drawing.Size(1070, 280)
$Script:txtDatabase.Multiline = $true; $Script:txtDatabase.ScrollBars = "Vertical"; $Script:txtDatabase.ReadOnly = $true
$Script:txtDatabase.Font = New-Object System.Drawing.Font("Consolas", 9)
$Script:txtDatabase.BackColor = $Script:Colors.Panel; $Script:txtDatabase.ForeColor = $Script:Colors.Success
$gbDatabase.Controls.Add($Script:txtDatabase)
# #
# TAB 7: SYSTEM OPTIMIZATION (Privacy, Performance, Services)
# #
# #
# TAB 8: ENGINE MONITOR (Monitoring ulepszen V38.1)
# #
$tabEngineMonitor = New-Object System.Windows.Forms.TabPage
$tabEngineMonitor.Text = " Engine Monitor"
$tabEngineMonitor.BackColor = $Script:Colors.Background
$tabEngineMonitor.AutoScroll = $true
$tabs.TabPages.Add($tabEngineMonitor)
#  App Cache Status Section
$gbAppCache = New-GroupBox -Parent $tabEngineMonitor -Title " APPLICATION PRELOAD CACHE" -X 10 -Y 10 -Width 580 -Height 280
$Script:txtCacheStatus = New-Object System.Windows.Forms.RichTextBox
$Script:txtCacheStatus.Location = New-Object System.Drawing.Point(15, 25)
$Script:txtCacheStatus.Size = New-Object System.Drawing.Size(550, 200)
$Script:txtCacheStatus.BackColor = $Script:Colors.Panel
$Script:txtCacheStatus.ForeColor = $Script:Colors.Success
$Script:txtCacheStatus.Font = New-Object System.Drawing.Font("Consolas", 9)
$Script:txtCacheStatus.ReadOnly = $true
$Script:txtCacheStatus.Text = "Monitoring engine status...\nCache data will appear here when applications are launched."
$gbAppCache.Controls.Add($Script:txtCacheStatus)
$btnRefreshCache = New-Button -Parent $gbAppCache -Text " Refresh Cache" -X 15 -Y 240 -Width 120 -Height 30 -BackColor $Script:Colors.Accent
$toolTip.SetToolTip($btnRefreshCache, " Odswieza dane cache aplikacji z ENGINE. Pokazuje aktualne przedzialne aplikacje w pamieci.")
$btnClearCache = New-Button -Parent $gbAppCache -Text "- Clear Cache" -X 150 -Y 240 -Width 120 -Height 30 -BackColor $Script:Colors.Danger
$toolTip.SetToolTip($btnClearCache, "- Czysci caly cache aplikacji. Wymusza ponowne zaladowanie aplikacji do pamieci.")
$lblCacheInfo = New-Label -Parent $gbAppCache -Text "Cache: 0/50 | FastBoot: 0 apps" -X 290 -Y 245 -Width 270 -Height 20 -ForeColor $Script:Colors.Cyan
#  Predictive Boost Status Section  
$gbPredictive = New-GroupBox -Parent $tabEngineMonitor -Title " PREDICTIVE BOOST & CHAIN PREDICTOR" -X 600 -Y 10 -Width 580 -Height 280
$Script:txtPredictiveStatus = New-Object System.Windows.Forms.RichTextBox
$Script:txtPredictiveStatus.Location = New-Object System.Drawing.Point(15, 25)
$Script:txtPredictiveStatus.Size = New-Object System.Drawing.Size(550, 200)
$Script:txtPredictiveStatus.BackColor = $Script:Colors.Panel
$Script:txtPredictiveStatus.ForeColor = $Script:Colors.Purple
$Script:txtPredictiveStatus.Font = New-Object System.Drawing.Font("Consolas", 9)
$Script:txtPredictiveStatus.ReadOnly = $true
$Script:txtPredictiveStatus.Text = "Monitoring predictive systems...\nPrediction data will appear here when patterns are detected."
$gbPredictive.Controls.Add($Script:txtPredictiveStatus)
$btnRefreshPredictions = New-Button -Parent $gbPredictive -Text " Refresh Predictions" -X 15 -Y 240 -Width 140 -Height 30 -BackColor $Script:Colors.AccentDim
$toolTip.SetToolTip($btnRefreshPredictions, " Odswieza predykcje AI o przyszlych aplikacjach. Pokazuje co Chain Predictor przewiduje.")
$lblPredictionInfo = New-Label -Parent $gbPredictive -Text "Accuracy: --% | Transitions: 0" -X 170 -Y 245 -Width 270 -Height 20 -ForeColor $Script:Colors.Cyan
#  Launch History & Patterns Section
$gbLaunchHistory = New-GroupBox -Parent $tabEngineMonitor -Title " LAUNCH HISTORY & LEARNING PATTERNS" -X 10 -Y 300 -Width 580 -Height 280
$Script:txtHistoryStatus = New-Object System.Windows.Forms.RichTextBox
$Script:txtHistoryStatus.Location = New-Object System.Drawing.Point(15, 25)
$Script:txtHistoryStatus.Size = New-Object System.Drawing.Size(550, 200)
$Script:txtHistoryStatus.BackColor = $Script:Colors.Panel
$Script:txtHistoryStatus.ForeColor = $Script:Colors.Warning
$Script:txtHistoryStatus.Font = New-Object System.Drawing.Font("Consolas", 9)
$Script:txtHistoryStatus.ReadOnly = $true
$Script:txtHistoryStatus.Text = "Monitoring launch patterns...\nPattern data will appear here as applications are learned."
$gbLaunchHistory.Controls.Add($Script:txtHistoryStatus)
$btnRefreshHistory = New-Button -Parent $gbLaunchHistory -Text " Refresh History" -X 15 -Y 240 -Width 120 -Height 30 -BackColor $Script:Colors.Card
$toolTip.SetToolTip($btnRefreshHistory, "- Odswieza historie uruchamianych aplikacji. Pokazuje najnowsze wzorce uzywania.")
$btnExportHistory = New-Button -Parent $gbLaunchHistory -Text " Export Data" -X 150 -Y 240 -Width 120 -Height 30 -BackColor $Script:Colors.TextDim
$lblHistoryInfo = New-Label -Parent $gbLaunchHistory -Text "Apps tracked: 0 | Total launches: 0" -X 290 -Y 245 -Width 270 -Height 20 -ForeColor $Script:Colors.Cyan
#  Real-time Engine Status Section
$gbEngineStatus = New-GroupBox -Parent $tabEngineMonitor -Title " REAL-TIME ENGINE STATUS" -X 600 -Y 300 -Width 580 -Height 280
$Script:txtEngineStatus = New-Object System.Windows.Forms.RichTextBox
$Script:txtEngineStatus.Location = New-Object System.Drawing.Point(15, 25)
$Script:txtEngineStatus.Size = New-Object System.Drawing.Size(550, 200)
$Script:txtEngineStatus.BackColor = $Script:Colors.Panel
$Script:txtEngineStatus.ForeColor = $Script:Colors.TextBright
$Script:txtEngineStatus.Font = New-Object System.Drawing.Font("Consolas", 9)
$Script:txtEngineStatus.ReadOnly = $true
$Script:txtEngineStatus.Text = "Engine Status: Connecting...\nWaiting for engine data..."
$gbEngineStatus.Controls.Add($Script:txtEngineStatus)
$btnRefreshEngine = New-Button -Parent $gbEngineStatus -Text " Refresh Status" -X 15 -Y 240 -Width 120 -Height 30 -BackColor $Script:Colors.Success
$toolTip.SetToolTip($btnRefreshEngine, " Odswieza status ENGINE i systemow AI. Sprawdza czy wszystkie komponenty dzialaja.")
$btnStartEngine = New-Button -Parent $gbEngineStatus -Text " Start Engine" -X 150 -Y 240 -Width 120 -Height 30 -BackColor $Script:Colors.AccentDim
$btnStartEngine.Add_MouseHover({ $this.Cursor = [System.Windows.Forms.Cursors]::Hand })
$toolTip.SetToolTip($btnStartEngine, " Uruchamia ENGINE - glowny modul optymalizacji w czasie rzeczywistym. Zaawansowany AI do zarzadzania wydajnoscia.")
$lblEngineInfo = New-Label -Parent $gbEngineStatus -Text "Engine: Checking..." -X 290 -Y 245 -Width 270 -Height 20 -ForeColor $Script:Colors.Cyan
#  APP CATEGORIES TAB - Supervised Learning Interface
$tabAppCategories = New-Object System.Windows.Forms.TabPage
$tabAppCategories.Text = " App Categories"
$tabAppCategories.BackColor = $Script:Colors.Background
$tabs.TabPages.Add($tabAppCategories)
#  Manual Category Assignment Section
$gbManualCategories = New-GroupBox -Parent $tabAppCategories -Title " MANUAL APP CATEGORIZATION" -X 10 -Y 10 -Width 580 -Height 520
# Application List
$lblAppList = New-Label -Parent $gbManualCategories -Text "- Application List:" -X 15 -Y 25 -Width 120 -Height 20 -ForeColor $Script:Colors.TextBright
$Script:lstApplications = New-Object System.Windows.Forms.ListView
$Script:lstApplications.Location = New-Object System.Drawing.Point(15, 50)
$Script:lstApplications.Size = New-Object System.Drawing.Size(550, 300)
$Script:lstApplications.View = [System.Windows.Forms.View]::Details
$Script:lstApplications.FullRowSelect = $true
$Script:lstApplications.GridLines = $true
$Script:lstApplications.BackColor = $Script:Colors.Panel
$Script:lstApplications.ForeColor = $Script:Colors.TextBright
$Script:lstApplications.Font = New-Object System.Drawing.Font("Segoe UI", 9)
# Add columns
$Script:lstApplications.Columns.Add("Application", 200) | Out-Null
$Script:lstApplications.Columns.Add("Current Category", 120) | Out-Null
$Script:lstApplications.Columns.Add("AI Confidence", 100) | Out-Null
$Script:lstApplications.Columns.Add("User Overrides", 100) | Out-Null
$gbManualCategories.Controls.Add($Script:lstApplications)
# Category Assignment Buttons
$lblCategoryActions = New-Label -Parent $gbManualCategories -Text "- Set Category:" -X 15 -Y 360 -Width 100 -Height 20 -ForeColor $Script:Colors.TextBright
$btnSetSilent = New-Button -Parent $gbManualCategories -Text "- Silent" -X 15 -Y 385 -Width 80 -Height 35 -BackColor $Script:Colors.Silent
$toolTip.SetToolTip($btnSetSilent, " Przypisuje tryb SILENT z TWARDYM LOCKIEM - ENGINE zawsze uzyje tego trybu dla tej aplikacji (ignoruje AI)")
$btnSetBalanced = New-Button -Parent $gbManualCategories -Text "- Balanced" -X 110 -Y 385 -Width 80 -Height 35 -BackColor $Script:Colors.Balanced
$toolTip.SetToolTip($btnSetBalanced, " Przypisuje tryb BALANCED z TWARDYM LOCKIEM - ENGINE zawsze uzyje tego trybu dla tej aplikacji (ignoruje AI)")
$btnSetTurbo = New-Button -Parent $gbManualCategories -Text " Turbo" -X 205 -Y 385 -Width 80 -Height 35 -BackColor $Script:Colors.Turbo
$toolTip.SetToolTip($btnSetTurbo, " Przypisuje tryb TURBO z TWARDYM LOCKIEM - ENGINE zawsze uzyje tego trybu dla tej aplikacji (ignoruje AI)")
# Control Buttons
$btnRefreshApps = New-Button -Parent $gbManualCategories -Text " Refresh List" -X 320 -Y 385 -Width 100 -Height 35 -BackColor $Script:Colors.Success
$toolTip.SetToolTip($btnRefreshApps, "- Odswieza liste aplikacji dla kategoryzacji recznej. Skanuje nowe zainstalowane programy.")
$btnClearOverrides = New-Button -Parent $gbManualCategories -Text "- Clear Overrides" -X 435 -Y 385 -Width 110 -Height 35 -BackColor $Script:Colors.Warning
# Progress and Status
$lblLearningStatus = New-Label -Parent $gbManualCategories -Text " Status uczenia: 0 aplikacji (0 uruchomionych, 0 skategoryzowanych)" -X 15 -Y 435 -Width 400 -Height 20 -ForeColor $Script:Colors.Cyan
$Script:progressLearning = New-Object System.Windows.Forms.ProgressBar
$Script:progressLearning.Location = New-Object System.Drawing.Point(15, 460)
$Script:progressLearning.Size = New-Object System.Drawing.Size(350, 20)
$Script:progressLearning.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$toolTip.SetToolTip($Script:progressLearning, "- Pasek pokazuje postep uczenia AI na podstawie Twoich recznych kategoryzacji. Kazda nowa kategoria to +10%.")
$gbManualCategories.Controls.Add($Script:progressLearning)
$lblLearningInfo = New-Label -Parent $gbManualCategories -Text "PRZYCISKI Silent/Balanced/Turbo WYMUSZAJĄ tryb na stale (HardLock). Checkbox ponizej pozwala go wylaczyc." -X 15 -Y 485 -Width 550 -Height 20 -ForeColor $Script:Colors.Warning
#  Learning Configuration Section
$gbLearningConfig = New-GroupBox -Parent $tabAppCategories -Title " AI LEARNING CONFIGURATION" -X 600 -Y 10 -Width 580 -Height 280
# Learning Mode
$lblLearningMode = New-Label -Parent $gbLearningConfig -Text "- Learning Mode:" -X 15 -Y 25 -Width 120 -Height 20 -ForeColor $Script:Colors.TextBright
$Script:cmbLearningMode = New-Object System.Windows.Forms.ComboBox
$Script:cmbLearningMode.Location = New-Object System.Drawing.Point(15, 50)
$Script:cmbLearningMode.Size = New-Object System.Drawing.Size(200, 25)
$Script:cmbLearningMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$Script:cmbLearningMode.BackColor = $Script:Colors.Panel
$Script:cmbLearningMode.ForeColor = $Script:Colors.TextBright
$Script:cmbLearningMode.Items.AddRange(@("AUTO (AI + User Bias)", "MANUAL ONLY", "AI ONLY", "DISABLED"))
$toolTip.SetToolTip($Script:cmbLearningMode, "- Tryb uczenia AI: AUTO = AI + twoje preferencje, MANUAL = tylko twoje wybory, AI ONLY = tylko automatyka, DISABLED = brak uczenia.")
$Script:cmbLearningMode.SelectedIndex = 0
$gbLearningConfig.Controls.Add($Script:cmbLearningMode)
# User Bias Influence
$lblBiasInfluence = New-Label -Parent $gbLearningConfig -Text "- User Bias Influence: 25%" -X 15 -Y 85 -Width 200 -Height 20 -ForeColor $Script:Colors.TextBright
$toolTip.SetToolTip($lblBiasInfluence, "- Jak bardzo twoje reczne wybory wplywaja na decyzje AI. 0% = tylko AI, 40% = glownie twoje preferencje.")
$Script:trackBiasInfluence = New-Object System.Windows.Forms.TrackBar
$Script:trackBiasInfluence.Location = New-Object System.Drawing.Point(15, 110)
$Script:trackBiasInfluence.Size = New-Object System.Drawing.Size(300, 45)
$Script:trackBiasInfluence.Minimum = 0
$Script:trackBiasInfluence.Maximum = 40
$Script:trackBiasInfluence.Value = 25
$toolTip.SetToolTip($Script:trackBiasInfluence, " Ustaw wplyw twoich recznych kategoryzacji na AI. Wiecej = AI bedzie czesciej sluchac twoich preferencji.")
$Script:trackBiasInfluence.TickFrequency = 5
$Script:trackBiasInfluence.BackColor = $Script:Colors.Panel
$gbLearningConfig.Controls.Add($Script:trackBiasInfluence)
# Confidence Threshold
$lblConfidenceThreshold = New-Label -Parent $gbLearningConfig -Text " Confidence Threshold: 70%" -X 15 -Y 165 -Width 200 -Height 20 -ForeColor $Script:Colors.TextBright
$Script:trackConfidenceThreshold = New-Object System.Windows.Forms.TrackBar
$Script:trackConfidenceThreshold.Location = New-Object System.Drawing.Point(15, 190)
$Script:trackConfidenceThreshold.Size = New-Object System.Drawing.Size(300, 45)
$Script:trackConfidenceThreshold.Minimum = 50
$Script:trackConfidenceThreshold.Maximum = 95
$Script:trackConfidenceThreshold.Value = 70
$Script:trackConfidenceThreshold.TickFrequency = 5
$Script:trackConfidenceThreshold.BackColor = $Script:Colors.Panel
$gbLearningConfig.Controls.Add($Script:trackConfidenceThreshold)
# Reset and Apply Buttons
$btnResetLearning = New-Button -Parent $gbLearningConfig -Text " Reset Learning" -X 350 -Y 50 -Width 120 -Height 35 -BackColor $Script:Colors.Warning
$btnApplyLearning = New-Button -Parent $gbLearningConfig -Text " Apply Settings" -X 350 -Y 100 -Width 120 -Height 35 -BackColor $Script:Colors.Success
# Learning Statistics
$lblLearningStats = New-Label -Parent $gbLearningConfig -Text " Learning Statistics:" -X 350 -Y 150 -Width 150 -Height 20 -ForeColor $Script:Colors.TextBright
$Script:txtLearningStats = New-Object System.Windows.Forms.TextBox
$Script:txtLearningStats.Location = New-Object System.Drawing.Point(350, 175)
$Script:txtLearningStats.Size = New-Object System.Drawing.Size(200, 60)
$Script:txtLearningStats.Multiline = $true
$Script:txtLearningStats.ReadOnly = $true
$Script:txtLearningStats.BackColor = $Script:Colors.Panel
$Script:txtLearningStats.ForeColor = $Script:Colors.TextDim
$Script:txtLearningStats.Text = "Overrides: 0`nConfidence: 0%`nBias Applied: 0%"
$gbLearningConfig.Controls.Add($Script:txtLearningStats)
#  Data Management Section
$gbDataManagement = New-GroupBox -Parent $tabAppCategories -Title " DATA MANAGEMENT" -X 600 -Y 300 -Width 580 -Height 230
# Import/Export Controls
$lblDataActions = New-Label -Parent $gbDataManagement -Text " Category Data:" -X 15 -Y 25 -Width 120 -Height 20 -ForeColor $Script:Colors.TextBright
$btnExportCategories = New-Button -Parent $gbDataManagement -Text "- Export Categories" -X 15 -Y 50 -Width 130 -Height 35 -BackColor $Script:Colors.Info
$btnImportCategories = New-Button -Parent $gbDataManagement -Text "- Import Categories" -X 160 -Y 50 -Width 130 -Height 35 -BackColor $Script:Colors.AccentDim
$btnBackupData = New-Button -Parent $gbDataManagement -Text " Backup Data" -X 305 -Y 50 -Width 130 -Height 35 -BackColor $Script:Colors.Success
# Clear Data Controls
$lblClearActions = New-Label -Parent $gbDataManagement -Text "- Clear Data:" -X 15 -Y 105 -Width 120 -Height 20 -ForeColor $Script:Colors.TextBright
$btnClearUserData = New-Button -Parent $gbDataManagement -Text "- Clear User Overrides" -X 15 -Y 130 -Width 150 -Height 35 -BackColor $Script:Colors.Warning
$btnClearAIData = New-Button -Parent $gbDataManagement -Text " Clear AI Learning" -X 180 -Y 130 -Width 150 -Height 35 -BackColor $Script:Colors.Warning
$btnClearAllData = New-Button -Parent $gbDataManagement -Text "- Clear All Data" -X 345 -Y 130 -Width 150 -Height 35 -BackColor $Script:Colors.Danger
# SAVE AND APPLY button - triggers ENGINE reload
$btnSaveAndApply = New-Button -Parent $gbDataManagement -Text "ZAPISZ I ZASTOSUJ" -X 450 -Y 50 -Width 120 -Height 70 -BackColor $Script:Colors.Turbo
$btnSaveAndApply.ForeColor = [System.Drawing.Color]::White
$btnSaveAndApply.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$toolTip.SetToolTip($btnSaveAndApply, "Zapisuje zmiany i NATYCHMIAST wymusza przeladowanie przez ENGINE`n(tworzy plik sygnalizacyjny)")

# File Status
$lblFileStatus = New-Label -Parent $gbDataManagement -Text "- AppCategories.json: Not Found" -X 15 -Y 180 -Width 300 -Height 20 -ForeColor $Script:Colors.Warning
$lblFileSize = New-Label -Parent $gbDataManagement -Text " File Size: 0 KB" -X 15 -Y 200 -Width 200 -Height 20 -ForeColor $Script:Colors.TextDim
#  APP CATEGORIES EVENT HANDLERS
# Application list selection changed
$Script:lstApplications.add_SelectedIndexChanged({
    if ($Script:lstApplications.SelectedItems.Count -gt 0) {
        # Use Tag property which contains the actual app name (without emoji)
        $selectedApp = $Script:lstApplications.SelectedItems[0].Tag
        if (-not $selectedApp) {
            # Fallback to parsing the display name if Tag is not set
            $displayName = $Script:lstApplications.SelectedItems[0].Text
            $selectedApp = $displayName -replace '^[??]\s+', ''  # Remove emoji prefix
        }
        $Script:selectedAppForCategory = $selectedApp
        Update-CategoryButtonStates $selectedApp
        # Dodaj/odswiez checkbox HardLock w panelu szczegolow
        if ($Script:chkHardLock) {
            $gbManualCategories.Controls.Remove($Script:chkHardLock)
        }
        $isHardLocked = $false
        if ($Script:AppCategoryData.UserPreferences -and $Script:AppCategoryData.UserPreferences[$selectedApp] -and $Script:AppCategoryData.UserPreferences[$selectedApp].HardLock) {
            $isHardLocked = $Script:AppCategoryData.UserPreferences[$selectedApp].HardLock
        }
        $Script:chkHardLock = New-Object System.Windows.Forms.CheckBox
        $Script:chkHardLock.Location = New-Object System.Drawing.Point(380, 355)
        $Script:chkHardLock.Size = New-Object System.Drawing.Size(150, 22)
        $Script:chkHardLock.Text = "- Twardy Lock Trybu"
        $Script:chkHardLock.Checked = $isHardLocked
        $Script:chkHardLock.ForeColor = $Script:Colors.Warning
        $Script:chkHardLock.BackColor = $Script:Colors.Panel
        $Script:chkHardLock.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $toolTip.SetToolTip($Script:chkHardLock, " ZAZNACZONE = ENGINE WYMUSZA tryb (ignoruje AI)`n ODZNACZONE = ENGINE uwzglednia jako sugestie dla AI`n`n AUTO-ZAZNACZONE gdy klikasz Silent/Balanced/Turbo")
        $Script:chkHardLock.Add_CheckedChanged({
            if ($Script:selectedAppForCategory) {
                if (-not $Script:AppCategoryData.UserPreferences) { $Script:AppCategoryData.UserPreferences = @{} }
                if (-not $Script:AppCategoryData.UserPreferences[$Script:selectedAppForCategory]) {
                    $Script:AppCategoryData.UserPreferences[$Script:selectedAppForCategory] = @{ Bias = 0.5; Confidence = 0.7; Samples = 1; LastUsed = (Get-Date).ToString("o") }
                }
                $Script:AppCategoryData.UserPreferences[$Script:selectedAppForCategory].HardLock = $Script:chkHardLock.Checked
                Save-CategoryData
            }
        })
        $gbManualCategories.Controls.Add($Script:chkHardLock)
    } else {
        if ($Script:chkHardLock) {
            $gbManualCategories.Controls.Remove($Script:chkHardLock)
            $Script:chkHardLock = $null
        }
    }
})
# Category assignment buttons
$btnSetSilent.Add_Click({
    if ($Script:selectedAppForCategory) {
        Set-AppCategory $Script:selectedAppForCategory "Silent"
        Update-ApplicationList
        Update-LearningStats
    }
})
$btnSetBalanced.Add_Click({
    if ($Script:selectedAppForCategory) {
        Set-AppCategory $Script:selectedAppForCategory "Balanced"
        Update-ApplicationList
        Update-LearningStats
    }
})
$btnSetTurbo.Add_Click({
    if ($Script:selectedAppForCategory) {
        Set-AppCategory $Script:selectedAppForCategory "Turbo"
        Update-ApplicationList
        Update-LearningStats
    }
})

# SAVE AND APPLY button - saves and signals ENGINE to reload
$btnSaveAndApply.Add_Click({
    try {
        # 1. Save category data
        Save-CategoryData
        
        # 2. Create signal file for ENGINE to detect and reload
        $signalPath = "C:\CPUManager\ReloadCategories.signal"
        $signalData = @{
            Timestamp = (Get-Date).ToString("o")
            Source = "Configurator"
            Action = "ReloadAppCategories"
        } | ConvertTo-Json
        $signalData | Out-File $signalPath -Encoding UTF8 -Force
        
        Write-Host " Created reload signal for ENGINE at $signalPath" -ForegroundColor Green
        
        [System.Windows.Forms.MessageBox]::Show(
            "Zmiany zapisane!`n`nENGINE przeladuje dane kategorii przy nastepnej iteracji (max 5 sekund).`n`nJesli ENGINE nie dziala - uruchom go, a dane zostana automatycznie wczytane.",
            "Zapisano i Zastosowano",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        
        Update-FileStatus
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Blad podczas zapisywania: $($_.Exception.Message)",
            "Blad",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
})

# Control buttons
$btnRefreshApps.Add_Click({
    Update-ApplicationList
    Update-LearningStats
    Update-FileStatus
})
$btnClearOverrides.Add_Click({
    if ($Script:lstApplications.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Najpierw wybierz aplikacje z listy.",
            "Brak wyboru",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }
    $selectedApp = $Script:lstApplications.SelectedItems[0].Tag
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Czy na pewno chcesz zresetowac ustawienia dla aplikacji: $selectedApp?",
        "Resetuj ustawienia aplikacji",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        if ($Script:AppCategoryData.UserPreferences.ContainsKey($selectedApp)) {
            $Script:AppCategoryData.UserPreferences.Remove($selectedApp)
        }
        if ($Script:AppCategoryData.userOverrides.ContainsKey($selectedApp)) {
            $Script:AppCategoryData.userOverrides.Remove($selectedApp)
        }
        Save-CategoryData
        Update-ApplicationList
        Update-LearningStats
    }
})
# Learning configuration controls
$Script:trackBiasInfluence.Add_ValueChanged({
    $lblBiasInfluence.Text = "- User Bias Influence: $($Script:trackBiasInfluence.Value)%"
})
$Script:trackConfidenceThreshold.Add_ValueChanged({
    $lblConfidenceThreshold.Text = " Confidence Threshold: $($Script:trackConfidenceThreshold.Value)%"
})
$btnApplyLearning.Add_Click({
    Set-LearningSettings
    Update-LearningStats
    [System.Windows.Forms.MessageBox]::Show(
        "Learning settings applied successfully!",
        "Settings Applied",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
})
$btnResetLearning.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Are you sure you want to reset all learning data- This will clear both user overrides and AI learning patterns.",
        "Reset Learning Data",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Reset-AllLearningData
        Update-ApplicationList
        Update-LearningStats
    }
})
# Data management buttons
$btnExportCategories.Add_Click({
    Export-CategoryData
})
$btnImportCategories.Add_Click({
    Import-CategoryData
    Update-ApplicationList
    Update-LearningStats
})
$btnBackupData.Add_Click({
    Backup-CategoryData
})
$btnClearUserData.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Czy na pewno chcesz usunac WSZYSTKIE reczne ustawienia uzytkownika dla wszystkich aplikacji- (AI learning zostanie zachowany)",
        "Usun wszystkie ustawienia uzytkownika",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        if ($Script:AppCategoryData.UserPreferences) {
            $Script:AppCategoryData.UserPreferences.Clear()
        }
        if ($Script:AppCategoryData.userOverrides) {
            $Script:AppCategoryData.userOverrides.Clear()
        }
        Save-CategoryData
        Update-ApplicationList
        Update-LearningStats
    }
})
$btnClearAIData.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Clear all AI learning data- User overrides will be preserved.",
        "Clear AI Data",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Clear-AILearningData
        Update-LearningStats
    }
})
$btnClearAllData.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "WARNING: This will permanently delete ALL category data including user overrides and AI learning patterns. This action cannot be undone!",
        "Clear All Data",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Reset-AllLearningData
        Update-ApplicationList
        Update-LearningStats
    }
})
#  APP CATEGORIES HELPER FUNCTIONS
function Update-ApplicationList {
    $Script:lstApplications.Items.Clear()
    # Create a hashtable to track all apps (both running and previously categorized)
    $allApps = @{}
    # 1. Add currently running applications
    $processes = Get-Process | Where-Object { $_.MainWindowTitle -ne "" } | Sort-Object ProcessName
    foreach ($process in $processes) {
        $appName = $process.ProcessName
        if (-not $allApps.ContainsKey($appName)) {
            $allApps[$appName] = @{
                isRunning = $true
                hasWindow = $true
            }
        }
    }
    # 2. Add previously categorized applications (ENGINE format - UserPreferences)
    if ($Script:AppCategoryData -and $Script:AppCategoryData.UserPreferences) {
        foreach ($appName in $Script:AppCategoryData.UserPreferences.Keys) {
            if (-not $allApps.ContainsKey($appName)) {
                $allApps[$appName] = @{
                    isRunning = $false
                    hasWindow = $false
                }
            }
        }
    }
    # 3. Add applications from AI learning data (legacy compatibility)
    if ($Script:AppCategoryData -and $Script:AppCategoryData.aiLearning) {
        foreach ($appName in $Script:AppCategoryData.aiLearning.Keys) {
            if (-not $allApps.ContainsKey($appName)) {
                $allApps[$appName] = @{
                    isRunning = $false
                    hasWindow = $false
                }
            }
        }
    }
    # 4. Create ListView items for all applications
    foreach ($appName in ($allApps.Keys | Sort-Object)) {
        $appInfo = $allApps[$appName]
        $category = Get-AppCategory $appName
        $confidence = Get-AIConfidence $appName
        $overrideCount = Get-UserOverrideCount $appName
        # Create display name with status indicator
        $displayName = $appName
        if ($appInfo.isRunning) {
            $displayName = " $appName"  # Green circle for running
        } elseif ($overrideCount -gt 0) {
            $displayName = "- $appName"  # Note icon for previously categorized
        } else {
            $displayName = "- $appName"  # White circle for learned but not running
        }
        $listItem = New-Object System.Windows.Forms.ListViewItem($displayName)
        $listItem.SubItems.Add($category) | Out-Null
        $listItem.SubItems.Add("$confidence%") | Out-Null
        $listItem.SubItems.Add($overrideCount) | Out-Null
        # Store the actual app name for selection
        $listItem.Tag = $appName
        # Color code by category and status
        if (-not $appInfo.isRunning -and $overrideCount -gt 0) {
            # Previously categorized but not running - dimmed colors
            switch ($category) {
                "Silent" { $listItem.ForeColor = [System.Drawing.Color]::FromArgb(150, $Script:Colors.Silent.R, $Script:Colors.Silent.G, $Script:Colors.Silent.B) }
                "Balanced" { $listItem.ForeColor = [System.Drawing.Color]::FromArgb(150, $Script:Colors.Balanced.R, $Script:Colors.Balanced.G, $Script:Colors.Balanced.B) }
                "Turbo" { $listItem.ForeColor = [System.Drawing.Color]::FromArgb(150, $Script:Colors.Turbo.R, $Script:Colors.Turbo.G, $Script:Colors.Turbo.B) }
                default { $listItem.ForeColor = [System.Drawing.Color]::FromArgb(150, $Script:Colors.TextDim.R, $Script:Colors.TextDim.G, $Script:Colors.TextDim.B) }
            }
        } else {
            # Running applications - full colors
            switch ($category) {
                "Silent" { $listItem.ForeColor = $Script:Colors.Silent }
                "Balanced" { $listItem.ForeColor = $Script:Colors.Balanced }
                "Turbo" { $listItem.ForeColor = $Script:Colors.Turbo }
                default { $listItem.ForeColor = $Script:Colors.TextDim }
            }
        }
        $Script:lstApplications.Items.Add($listItem) | Out-Null
    }
    $totalApps = $allApps.Keys.Count
    $runningApps = ($allApps.Values | Where-Object { $_.isRunning }).Count
    $categorizedApps = if ($Script:AppCategoryData -and $Script:AppCategoryData.UserPreferences) { $Script:AppCategoryData.UserPreferences.Keys.Count } else { 0 }
    $lblLearningStatus.Text = " Status uczenia: $totalApps aplikacji ($runningApps uruchomionych, $categorizedApps skategoryzowanych)"
}
function Update-CategoryButtonStates($appName) {
    $currentCategory = Get-AppCategory $appName
    # Reset all button colors
    $btnSetSilent.BackColor = $Script:Colors.Silent
    $btnSetBalanced.BackColor = $Script:Colors.Balanced
    $btnSetTurbo.BackColor = $Script:Colors.Turbo
    # Highlight current category
    switch ($currentCategory) {
        "Silent" { $btnSetSilent.BackColor = $Script:Colors.AccentBright }
        "Balanced" { $btnSetBalanced.BackColor = $Script:Colors.AccentBright }
        "Turbo" { $btnSetTurbo.BackColor = $Script:Colors.AccentBright }
    }
}
function Set-AppCategory($appName, $category) {
    try {
        # Ensure AppCategoryData is initialized
        if (-not $Script:AppCategoryData) {
            Get-CategoryData
        }
        # Double-check initialization
        if (-not $Script:AppCategoryData) {
            $Script:AppCategoryData = @{
                Version = "38.2"
                UserPreferences = @{}
                SessionStats = @{
                    TotalCategorizations = 0
                    SessionStart = (Get-Date).ToString("o")
                }
            }
        }
        # Ensure UserPreferences hashtable exists
        if (-not $Script:AppCategoryData.UserPreferences) {
            $Script:AppCategoryData.UserPreferences = @{}
        }
        # Convert category to bias value for ENGINE compatibility
        $bias = switch ($category.ToLower()) {
            "silent" { 0.0 }
            "balanced" { 0.5 }
            "turbo" { 1.0 }
            default { 0.5 }
        }
        $timestamp = (Get-Date).ToString("o")
        # Record user preference in ENGINE format
        if ($Script:AppCategoryData.UserPreferences.ContainsKey($appName)) {
            $existing = $Script:AppCategoryData.UserPreferences[$appName]
            $Script:AppCategoryData.UserPreferences[$appName] = @{
                Bias = $bias
                Confidence = [Math]::Min(($existing.Confidence + 0.1), 1.0)  # Increase confidence
                Samples = $existing.Samples + 1
                LastUsed = $timestamp
                HardLock = $true  # v43.10: AUTO-ENABLE HardLock when user assigns category
            }
        } else {
            $Script:AppCategoryData.UserPreferences[$appName] = @{
                Bias = $bias
                Confidence = 0.7  # Start with good confidence
                Samples = 1
                LastUsed = $timestamp
                HardLock = $true  # v43.10: AUTO-ENABLE HardLock when user assigns category
            }
        }
        # Update session stats
        if (-not $Script:AppCategoryData.SessionStats) {
            $Script:AppCategoryData.SessionStats = @{
                TotalCategorizations = 0
                SessionStart = $timestamp
            }
        }
        $Script:AppCategoryData.SessionStats.TotalCategorizations++
        # Save to file
        Save-CategoryData
        
        # v43.10: Update checkbox in UI if it exists
        if ($Script:chkHardLock) {
            $Script:chkHardLock.Checked = $true
        }
        
        Write-Host " Set $appName to $category category (bias: $bias) [HARDLOCK ENABLED]" -ForegroundColor Green
    } catch {
        $errorMsg = $_.Exception.Message
        Write-Error "- Failed to set app category: $errorMsg"
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to set category: $errorMsg",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}
function Get-AppCategory($appName) {
    if (-not $Script:AppCategoryData) {
        Get-CategoryData
    }
    try {
        if ($Script:AppCategoryData -and $Script:AppCategoryData.UserPreferences -and $Script:AppCategoryData.UserPreferences[$appName]) {
            $pref = $Script:AppCategoryData.UserPreferences[$appName]
            # Convert bias back to category name
            $category = switch ($pref.Bias) {
                0.0 { "Silent" }
                1.0 { "Turbo" }
                default { "Balanced" }
            }
            return $category
        }
    } catch {
        Write-Warning "Error in Get-AppCategory: $_"
    }
    return "Auto"
}
function Get-AIConfidence($appName) {
    if (-not $Script:AppCategoryData) {
        Get-CategoryData
    }
    try {
        # Try ENGINE format first (UserPreferences)
        if ($Script:AppCategoryData -and $Script:AppCategoryData.UserPreferences -and $Script:AppCategoryData.UserPreferences[$appName]) {
            return [math]::Round($Script:AppCategoryData.UserPreferences[$appName].Confidence, 0)
        }
        # Fallback to legacy aiLearning format
        if ($Script:AppCategoryData -and $Script:AppCategoryData.aiLearning -and $Script:AppCategoryData.aiLearning[$appName]) {
            return [math]::Round($Script:AppCategoryData.aiLearning[$appName].confidence, 0)
        }
    } catch {
        Write-Warning "Error in Get-AIConfidence: $_"
    }
    return 0
}
function Get-UserOverrideCount($appName) {
    if (-not $Script:AppCategoryData) {
        Get-CategoryData
    }
    try {
        if ($Script:AppCategoryData -and $Script:AppCategoryData.UserPreferences -and $Script:AppCategoryData.UserPreferences[$appName]) {
            return $Script:AppCategoryData.UserPreferences[$appName].Samples
        }
    } catch {
        Write-Warning "Error in Get-UserOverrideCount: $_"
    }
    return 0
}
function Update-LearningStats {
    if (-not $Script:AppCategoryData) {
        Get-CategoryData
    }
    if ($Script:AppCategoryData) {
        # v43.10: Użyj UserPreferences zamiast userOverrides (to jest główne źródło danych)
        $overrideCount = if ($Script:AppCategoryData.UserPreferences) { 
            $Script:AppCategoryData.UserPreferences.Keys.Count 
        } else { 0 }
        
        # Policz aplikacje z HardLock
        $hardLockCount = 0
        if ($Script:AppCategoryData.UserPreferences) {
            foreach ($key in $Script:AppCategoryData.UserPreferences.Keys) {
                if ($Script:AppCategoryData.UserPreferences[$key].HardLock) {
                    $hardLockCount++
                }
            }
        }
        
        $avgConfidence = if ($Script:AppCategoryData.UserPreferences -and $Script:AppCategoryData.UserPreferences.Keys.Count -gt 0) {
            ($Script:AppCategoryData.UserPreferences.Values | ForEach-Object { if ($_.Confidence) { $_.Confidence * 100 } else { 70 } } | Measure-Object -Average).Average
        } else { 0 }
        
        $biasApplied = $Script:trackBiasInfluence.Value
        $Script:txtLearningStats.Text = "Kategoryzacji: $overrideCount`nHardLock: $hardLockCount`nŚr. Pewność: $([math]::Round($avgConfidence, 0))%"
        $Script:progressLearning.Value = [math]::Min(100, $overrideCount * 10)
    }
}
function Update-FileStatus {
    $categoriesPath = Join-Path $Script:WorkingDir "AppCategories.json"
    if (Test-Path $categoriesPath) {
        $fileSize = [math]::Round((Get-Item $categoriesPath).Length / 1KB, 2)
        $lblFileStatus.Text = "- AppCategories.json: Found"
        $lblFileStatus.ForeColor = $Script:Colors.Success
        $lblFileSize.Text = " File Size: $fileSize KB"
    } else {
        $lblFileStatus.Text = "- AppCategories.json: Not Found"
        $lblFileStatus.ForeColor = $Script:Colors.Warning
        $lblFileSize.Text = " File Size: 0 KB"
    }
}
function Get-CategoryData {
    $categoriesPath = Join-Path $Script:WorkingDir "AppCategories.json"
    if (Test-Path $categoriesPath) {
        try {
            $jsonContent = Get-Content $categoriesPath -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($jsonContent)) {
                Write-Warning "AppCategories.json is empty, initializing with defaults"
                Initialize-DefaultCategoryData
                return
            }
            $parsedData = $jsonContent | ConvertFrom-Json
            # Initialize with ENGINE-compatible structure
            $Script:AppCategoryData = @{
                UserPreferences = @{}
                SessionStats = @{
                    AppliedBias = 0
                    IgnoredBias = 0
                    NewApps = 0
                }
                Version = "38.2"
                LastModified = (Get-Date).ToString("o")
                # Backward compatibility fields for CONFIGURATOR UI
                userOverrides = @{}
                aiLearning = @{}
                settings = @{
                    biasInfluence = 25
                    confidenceThreshold = 70
                    learningMode = "AUTO"
                }
            }
            # Copy UserPreferences from ENGINE format
            if ($parsedData.UserPreferences) {
                $parsedData.UserPreferences.PSObject.Properties | ForEach-Object {
                    $appName = $_.Name
                    $pref = $_.Value
                    # Store in ENGINE format
                    $Script:AppCategoryData.UserPreferences[$appName] = @{
                        Bias = $pref.Bias
                        Confidence = $pref.Confidence
                        Samples = $pref.Samples
                        LastUsed = $pref.LastUsed
                        HardLock = if ($pref.HardLock -ne $null) { $pref.HardLock } else { $false }
                    }
                    # Also store in CONFIGURATOR format for UI compatibility
                    $Script:AppCategoryData.userOverrides[$appName] = @{
                        category = $pref.Bias
                        timestamp = $pref.LastUsed
                        count = $pref.Samples
                    }
                }
            }
            # Copy SessionStats
            if ($parsedData.SessionStats) {
                $Script:AppCategoryData.SessionStats = @{
                    AppliedBias = $parsedData.SessionStats.AppliedBias
                    IgnoredBias = $parsedData.SessionStats.IgnoredBias
                    NewApps = $parsedData.SessionStats.NewApps
                }
            }
            Write-Host " Loaded category data from $categoriesPath ($($Script:AppCategoryData.UserPreferences.Keys.Count) apps)" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to load category data: $_"
            Initialize-DefaultCategoryData
        }
    } else {
        Write-Host " AppCategories.json not found, creating new file" -ForegroundColor Yellow
        Initialize-DefaultCategoryData
        Save-CategoryData
    }
}
function Initialize-DefaultCategoryData {
    $Script:AppCategoryData = @{
        UserPreferences = @{}
        SessionStats = @{
            AppliedBias = 0
            IgnoredBias = 0
            NewApps = 0
        }
        Version = "38.2"
        LastModified = (Get-Date).ToString("o")
        # Backward compatibility
        userOverrides = @{}
        aiLearning = @{}
        settings = @{
            biasInfluence = 25
            confidenceThreshold = 70
            learningMode = "AUTO"
        }
    }
}
function Save-CategoryData {
    if (-not $Script:AppCategoryData) {
        Write-Warning "No category data to save!"
        return
    }
    $categoriesPath = Join-Path $Script:WorkingDir "AppCategories.json"
    try {
        # Ensure directory exists
        $directory = Split-Path $categoriesPath -Parent
        if (-not (Test-Path $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        # Prepare data in ENGINE-compatible format
        $data = @{
            Version = "38.2"
            LastModified = (Get-Date).ToString("o")
            UserPreferences = @{}
            SessionStats = $Script:AppCategoryData.SessionStats
        }
        # Convert UserPreferences to ENGINE format
        foreach ($app in $Script:AppCategoryData.UserPreferences.Keys) {
            $pref = $Script:AppCategoryData.UserPreferences[$app]
            $data.UserPreferences[$app] = @{
                Bias = $pref.Bias
                Confidence = $pref.Confidence
                Samples = $pref.Samples
                LastUsed = $pref.LastUsed
                HardLock = if ($pref.HardLock -ne $null) { $pref.HardLock } else { $false }
            }
        }
        # Convert to JSON with proper formatting
        $jsonData = $data | ConvertTo-Json -Depth 4
        $jsonData | Out-File $categoriesPath -Encoding UTF8 -Force
        Write-Host " Saved category data to $categoriesPath ($($data.UserPreferences.Keys.Count) apps)" -ForegroundColor Green
        Update-FileStatus
    } catch {
        $errorMsg = $_.Exception.Message
        Write-Error "- Failed to save category data: $errorMsg"
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to save category data: $errorMsg",
            "Save Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }
}
function Set-LearningSettings {
    if ($Script:AppCategoryData) {
        $Script:AppCategoryData.settings.biasInfluence = $Script:trackBiasInfluence.Value
        $Script:AppCategoryData.settings.confidenceThreshold = $Script:trackConfidenceThreshold.Value
        $Script:AppCategoryData.settings.learningMode = $Script:cmbLearningMode.SelectedItem.ToString()
        Save-CategoryData
    }
    try {
        $config = Get-Config
        if (-not $config.LearningSettings) { $config.LearningSettings = @{} }
        $config.LearningSettings.BiasInfluence = [int]$Script:trackBiasInfluence.Value
        $config.LearningSettings.ConfidenceThreshold = [int]$Script:trackConfidenceThreshold.Value
        $config.LearningSettings.LearningMode = $Script:cmbLearningMode.SelectedItem.ToString()
        Save-Config $config
    } catch { }
}
function Clear-UserOverrides {
    if ($Script:AppCategoryData) {
        $Script:AppCategoryData.userOverrides = @{}
        Save-CategoryData
        Write-Host "Cleared all user overrides" -ForegroundColor Yellow
    }
}
function Clear-AILearningData {
    if ($Script:AppCategoryData) {
        $Script:AppCategoryData.aiLearning = @{}
        Save-CategoryData
        Write-Host "Cleared AI learning data" -ForegroundColor Yellow
    }
}
function Reset-AllLearningData {
    $Script:AppCategoryData = @{
        userOverrides = @{}
        aiLearning = @{}
        settings = @{
            biasInfluence = 25
            confidenceThreshold = 70
            learningMode = "AUTO"
        }
    }
    Save-CategoryData
    Write-Host "Reset all learning data" -ForegroundColor Yellow
}
function Export-CategoryData {
    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
    $saveDialog.Title = "Export Category Data"
    $saveDialog.FileName = "AppCategories_Export_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $Script:AppCategoryData | ConvertTo-Json -Depth 4 | Out-File $saveDialog.FileName -Encoding UTF8
            [System.Windows.Forms.MessageBox]::Show(
                "Category data exported successfully to:`n$($saveDialog.FileName)",
                "Export Complete",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to export data: $($_.Exception.Message)",
                "Export Failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    }
}
function Import-CategoryData {
    $openDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openDialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
    $openDialog.Title = "Import Category Data"
    if ($openDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $importedData = Get-Content $openDialog.FileName -Raw | ConvertFrom-Json -AsHashtable
            $Script:AppCategoryData = $importedData
            Save-CategoryData
            # Update UI controls
            if ($Script:AppCategoryData.settings) {
                $Script:trackBiasInfluence.Value = $Script:AppCategoryData.settings.biasInfluence
                $Script:trackConfidenceThreshold.Value = $Script:AppCategoryData.settings.confidenceThreshold
                $Script:cmbLearningMode.SelectedIndex = switch ($Script:AppCategoryData.settings.learningMode) {
                    "MANUAL ONLY" { 1 }
                    "AI ONLY" { 2 }
                    "DISABLED" { 3 }
                    default { 0 }
                }
            }
            [System.Windows.Forms.MessageBox]::Show(
                "Category data imported successfully!",
                "Import Complete",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to import data: $($_.Exception.Message)",
                "Import Failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    }
}
function Backup-CategoryData {
    $backupDir = Join-Path $Script:WorkingDir "Backups"
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    $backupFile = Join-Path $backupDir "AppCategories_Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    try {
        $Script:AppCategoryData | ConvertTo-Json -Depth 4 | Out-File $backupFile -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show(
            "Backup created successfully:`n$backupFile",
            "Backup Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to create backup: $($_.Exception.Message)",
            "Backup Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}
# Initialize App Categories on form load
# Get-CategoryData - moved to end of main initialization
#  Privacy & Telemetry Section
$Script:lblDatabaseStatus = New-Label -Parent $gbDatabase -Text "Status: Waiting..." -X 15 -Y 315 -Width 400 -Height 22 -ForeColor $Script:Colors.TextDim
$btnRefreshDB = New-Button -Parent $gbDatabase -Text "Refresh" -X 900 -Y 310 -Width 90 -Height 30 -BackColor $Script:Colors.AccentDim -ForeColor $Script:Colors.TextBright -OnClick { Update-DatabaseView }
$btnExportDB = New-Button -Parent $gbDatabase -Text "Export" -X 995 -Y 310 -Width 90 -Height 30 -BackColor $Script:Colors.Success -ForeColor $Script:Colors.Background -OnClick {
    $exportPath = Join-Path $Script:ConfigDir "ProphetExport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    try {
        $Script:txtDatabase.Text | Set-Content $exportPath -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show("Exported to:`n$exportPath", "Export", "OK", "Information")
    } catch { [System.Windows.Forms.MessageBox]::Show("Export error: $_", "Error", "OK", "Error") }
}
function Update-DatabaseView {
    $prophetPath = Join-Path $Script:ConfigDir "ProphetMemory.json"
    if (Test-Path $prophetPath) {
        try {
            $prophet = Get-Content $prophetPath -Raw | ConvertFrom-Json
            $lines = @()
            $lines += "  APPLICATION               | AvgCPU | MaxCPU | Launches | Samples | Category"
            $lines += "  --------------------------+--------+--------+----------+---------+----------"
            if ($prophet.Apps) {
                $apps = @(); $prophet.Apps.PSObject.Properties | ForEach-Object { $apps += $_.Value }
                $apps | Sort-Object { $_.Launches } -Descending | ForEach-Object {
                    $name = if ($_.Name.Length -gt 25) { $_.Name.Substring(0,22) + "..." } else { $_.Name.PadRight(25) }
                    $avg = ([string][int]$_.AvgCPU).PadLeft(5)
                    $max = ([string][int]$_.MaxCPU).PadLeft(5)
                    $launches = ([string]$_.Launches).PadLeft(7)
                    $samples = if ($_.Samples) { ([string]$_.Samples).PadLeft(6) } else { "     0" }
                    $cat = if ($_.Category) { $_.Category } else { "Unknown" }
                    $lines += "  $name | $avg% | $max% | $launches | $samples | $cat"
                }
                $lines += "  --------------------------+--------+--------+----------+----------"
                $lines += "  Total: $($apps.Count) apps | Sessions: $($prophet.TotalSessions)"
            } else { $lines += "  No data - run CPUManager to collect app data" }
            $Script:txtDatabase.Text = $lines -join "`r`n"
            $appCount = if ($prophet.Apps) { ($prophet.Apps.PSObject.Properties | Measure-Object).Count } else { 0 }
            $Script:lblDatabaseStatus.Text = "Updated: $(Get-Date -Format 'HH:mm:ss') | Apps: $appCount"
            $Script:lblDatabaseStatus.ForeColor = $Script:Colors.Success
        } catch {
            $Script:txtDatabase.Text = "Error reading ProphetMemory.json: $_"
            $Script:lblDatabaseStatus.Text = "Status: Error"; $Script:lblDatabaseStatus.ForeColor = $Script:Colors.Danger
        }
    } else {
        $Script:txtDatabase.Text = "ProphetMemory.json not found.`r`nRun CPUManager to start collecting app data."
        $Script:lblDatabaseStatus.Text = "Status: No file"; $Script:lblDatabaseStatus.ForeColor = $Script:Colors.Warning
    }
}
# Initial load
Update-DatabaseView
# #
# ACTIVITY LOG - FUNKCJE POMOCNICZE (Activity Log jest teraz w zakladce Sensors)
# #
$Script:LastLogs = [System.Collections.Generic.HashSet[string]]::new()
$Script:LastBoringLogTime = @{}  # Throttling dla powtarzających się logów
function Add-ColoredLog {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    
    # Filtruj nudne, powtarzające się logi (Auto-save, Intel POWER itp.)
    # Pokazuj tylko znaczące zmiany stanu/akcje
    if ($Line -match "Auto-save|Intel POWER APPLIED|Knowledge Transfer #\d+") {
        # Dla tych logów sprawdź czy ostatni wpis był podobny (w ciągu 30s)
        if (-not $Script:LastBoringLogTime) { $Script:LastBoringLogTime = @{} }
        $logType = if ($Line -match "Auto-save") { "AutoSave" }
                   elseif ($Line -match "Intel POWER") { "IntelPower" }
                   else { "KnowledgeTransfer" }
        
        $now = [DateTime]::Now
        if ($Script:LastBoringLogTime.ContainsKey($logType)) {
            $elapsed = ($now - $Script:LastBoringLogTime[$logType]).TotalSeconds
            if ($elapsed -lt 30) { return }  # Pomiń jeśli był podobny wpis w ciągu 30s
        }
        $Script:LastBoringLogTime[$logType] = $now
    }
    
    # Sprawdź duplikaty tylko dla istotnych logów
    if ($Script:LastLogs.Contains($Line)) { return }
    
    if ($Script:LastLogs.Count -gt 300) { 
        # Usun najstarsze (pierwsze 150)
        $toRemove = @($Script:LastLogs | Select-Object -First 150)
        foreach ($item in $toRemove) { [void]$Script:LastLogs.Remove($item) }
    }
    [void]$Script:LastLogs.Add($Line)
    $color = $Script:Colors.Text
    if ($Line -match "TURBO|BOOST|🚀") { $color = $Script:Colors.Turbo }
    elseif ($Line -match "BALANCED|⚖") { $color = $Script:Colors.Balanced }
    elseif ($Line -match "SILENT|🔇") { $color = $Script:Colors.Silent }
    elseif ($Line -match "ERROR|BLAD") { $color = $Script:Colors.Danger }
    elseif ($Line -match "AI|🤖|Q-Learning") { $color = $Script:Colors.Purple }
    elseif ($Line -match "I/O|💾|Disk") { $color = $Script:Colors.Warning }
    # AppendText jest O(1), SelectionStart=0 + SelectedText jest O(n)
    try {
        $Script:txtActivityLog.SelectionStart = $Script:txtActivityLog.TextLength
        $Script:txtActivityLog.SelectionLength = 0
        $Script:txtActivityLog.SelectionColor = $color
        $Script:txtActivityLog.AppendText($Line + "`r`n")
        # Scroll do konca (najnowsze logi)
        $Script:txtActivityLog.SelectionStart = $Script:txtActivityLog.TextLength
        $Script:txtActivityLog.ScrollToCaret()
    } catch { }
    # Automatyczne czyszczenie starych logów - okno mieści ~10 linii, trzymamy max 20
    if ($Script:txtActivityLog.Lines.Count -gt 25) {
        try {
            # Zachowaj tylko 15 ostatnich linii (najnowsze aktywności)
            $lastLines = @($Script:txtActivityLog.Lines | Select-Object -Last 15)
            $Script:txtActivityLog.Clear()
            foreach ($ln in $lastLines) {
                # Re-apply color coding
                $lineColor = $Script:Colors.Text
                if ($ln -match "TURBO|BOOST|🚀") { $lineColor = $Script:Colors.Turbo }
                elseif ($ln -match "BALANCED|⚖") { $lineColor = $Script:Colors.Balanced }
                elseif ($ln -match "SILENT|🔇") { $lineColor = $Script:Colors.Silent }
                elseif ($ln -match "ERROR|BLAD") { $lineColor = $Script:Colors.Danger }
                elseif ($ln -match "AI|🤖|Q-Learning") { $lineColor = $Script:Colors.Purple }
                elseif ($ln -match "I/O|💾|Disk") { $lineColor = $Script:Colors.Warning }
                
                $Script:txtActivityLog.SelectionStart = $Script:txtActivityLog.TextLength
                $Script:txtActivityLog.SelectionLength = 0
                $Script:txtActivityLog.SelectionColor = $lineColor
                $Script:txtActivityLog.AppendText($ln + "`r`n")
            }
        } catch { }
    }
    $Script:lblLogCount.Text = "$($Script:txtActivityLog.Lines.Count)"
}
# #
# TIMER - REFRESH
# #
$Script:ClockTimer = New-Object System.Windows.Forms.Timer
$Script:ClockTimer.Interval = 1000  # Zegar co 1 sekunde
$Script:ClockTimer.Add_Tick({
    try { $Script:lblClock.Text = (Get-Date).ToString("HH:mm:ss") } catch { }
})
$Script:ClockTimer.Start()
# Timer glowny - odswiezanie danych
$Script:Timer = New-Object System.Windows.Forms.Timer
$Script:Timer.Interval = 2000  # v40: 2000ms dla responsywnosci
$Script:TimerRunning = $false
$Script:TimerTickCount = 0  # v40: Licznik dla samooptymalizacji RAM
$Script:LastRAMOptimize = [DateTime]::UtcNow
$Script:Timer.Add_Tick({
    if ($Script:TimerRunning) { return }
    $Script:TimerRunning = $true
    $Script:TimerTickCount++
    try {
        # === SELF-OPTIMIZING RAM v40 ===
        # Auto-optimize every 60 ticks (~2 min) or when memory > 100MB
        $shouldOptimize = $false
        if ($Script:TimerTickCount % 60 -eq 0) { $shouldOptimize = $true }
        $currentMemMB = [Math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 1)
        if ($currentMemMB -gt 100) { $shouldOptimize = $true }
        if ($shouldOptimize) {
            [System.GC]::Collect(2, [System.GCCollectionMode]::Optimized, $false)
            [System.GC]::WaitForPendingFinalizers()
            if ($currentMemMB -gt 150) {
                try {
                    $proc = [System.Diagnostics.Process]::GetCurrentProcess()
                    [Console.Win32Console]::EmptyWorkingSet($proc.Handle) | Out-Null
                } catch { }
            }
        }
        $data = Get-WidgetData
        $hasValidData = ($null -ne $data -and $null -ne $data.CPU)
        if ($hasValidData) {
        $Script:LastData = $data
        # Safe read - podstawowe metryki
        $cpuVal, $tempVal, $iterVal = $data.CPU, $data.Temp, $data.Iteration
        $modeVal = if ($data.Mode) { $data.Mode } else { "---" }
        $aiVal = if ($data.AI) { $data.AI } else { "OFF" }
        $reasonVal = if ($data.Reason) { $data.Reason } else { "---" }
        $appVal = if ($data.App) { $data.App } else { "---" }
        $diskVal = if ($data.Disk) { [double]$data.Disk } else { 0.0 }
        # AI data - kompaktowo
        $brainVal, $qLearningVal, $banditVal, $geneticVal = $data.Brain, $data.QLearning, $data.Bandit, $data.Genetic
        $energyVal, $prophetVal, $selfTunerVal, $chainVal = $data.Energy, $data.Prophet, $data.SelfTuner, $data.Chain
        $ensembleVal = if ($data.Ensemble) { $data.Ensemble } else { "OFF" }
        # Default "---" dla null - FIX v40: bez ForEach-Object pipeline (unika PipelineStoppedException)
        if ([string]::IsNullOrEmpty($brainVal)) { $brainVal = "---" }
        if ([string]::IsNullOrEmpty($qLearningVal)) { $qLearningVal = "---" }
        if ([string]::IsNullOrEmpty($banditVal)) { $banditVal = "---" }
        if ([string]::IsNullOrEmpty($geneticVal)) { $geneticVal = "---" }
        if ([string]::IsNullOrEmpty($energyVal)) { $energyVal = "---" }
        if ([string]::IsNullOrEmpty($prophetVal)) { $prophetVal = "---" }
        if ([string]::IsNullOrEmpty($selfTunerVal)) { $selfTunerVal = "---" }
        if ([string]::IsNullOrEmpty($chainVal)) { $chainVal = "---" }
        if ($prophetVal -match "pred" -and $prophetVal -notmatch "apps") {
            # Prophet contains wrong value (from Chain), try to swap
            $tempProphet = $prophetVal
            $prophetVal = $chainVal
            $chainVal = $tempProphet
            Add-Log "[WARN]  Configurator detected Prophet/Chain swap - fixed automatically" -Warning
        }
        # If Prophet is still empty or "---", try to get from ProphetLearnedApps count
        if ($prophetVal -eq "---" -or [string]::IsNullOrEmpty($prophetVal)) {
            $prophetCount = if ($data.ProphetLearnedApps) { $data.ProphetLearnedApps } else { 0 }
            if ($prophetCount -gt 0) {
                $prophetVal = "$prophetCount apps"
            }
        }
        $modeSwitchesVal = if ($data.ModeSwitches) { [int]$data.ModeSwitches } else { 0 }
        $runtimeVal = if ($data.Runtime) { [double]$data.Runtime } else { 0.0 }
        # Network stats z ENGINE
        $dlVal = if ($data.DL) { [int64]$data.DL } else { 0 }
        $ulVal = if ($data.UL) { [int64]$data.UL } else { 0 }
        # If local background measurement has non-zero live values, prefer them for real-time UI responsiveness
        if ($Script:LiveNetDL -gt 0) { $dlVal = [int64]$Script:LiveNetDL }
        if ($Script:LiveNetUL -gt 0) { $ulVal = [int64]$Script:LiveNetUL }
        # Total DL/UL z fallbackiem na NetworkStats.json
        $totalDLVal = if ($data.TotalDownloaded) { [int64]$data.TotalDownloaded } else { 0 }
        $totalULVal = if ($data.TotalUploaded) { [int64]$data.TotalUploaded } else { 0 }
        if ($totalDLVal -eq 0 -and $totalULVal -eq 0) { Get-NetworkStats | Out-Null; $totalDLVal, $totalULVal = $Script:PersistentNetDL, $Script:PersistentNetUL }
        # Session stats = Total - Baseline
        if (-not $Script:BaselineInitialized -and $totalDLVal -gt 0) { $Script:BaselineTotalDL, $Script:BaselineTotalUL, $Script:BaselineInitialized = $totalDLVal, $totalULVal, $true }
        # FIX: Użyj [int64] dla dużych wartości network stats (mogą przekroczyć Int32 max: 2.1GB)
        $Script:SessionNetDL = [Math]::Max([int64]0, [int64]($totalDLVal - $Script:BaselineTotalDL))
        $Script:SessionNetUL = [Math]::Max([int64]0, [int64]($totalULVal - $Script:BaselineTotalUL))
        # Disk I/O, GPU, VRM, CPU Info - kompaktowo
        $diskReadVal, $diskWriteVal = $Script:LiveDiskReadMBs, $Script:LiveDiskWriteMBs
        $ioBoostVal = [bool]$data.IOBoost
        # Pobierz dane GPU/VRM/Power bezposrednio z OHM/LHM (nie z Engine)
        $hwData = Get-HardwareMonitorData
        $gpuTempVal, $gpuLoadVal, $vrmTempVal, $cpuPowerVal = $hwData.GPUTemp, $hwData.GPULoad, $hwData.VRMTemp, $hwData.CPUPower
        $cpuVendorVal = if ($data.CPUVendor) { $data.CPUVendor } else { "Unknown" }
        $cpuModelVal = if ($data.CPUModel) { $data.CPUModel } else { "Unknown" }
        $cpuGenVal = if ($data.CPUGeneration) { $data.CPUGeneration } else { "Unknown" }
        $cpuArchVal = if ($data.CPUArchitecture) { $data.CPUArchitecture } else { "Unknown" }
        $cpuCoresVal, $cpuThreadsVal = $data.CPUCores, $data.CPUThreads
        $isHybridVal, $pCoreCountVal, $eCoreCountVal = [bool]$data.IsHybridCPU, $data.PCoreCount, $data.ECoreCount
        $userForcedModeVal = if ($data.UserForcedMode) { $data.UserForcedMode } else { "" }
        $autoRestoreInVal = if ($data.AutoRestoreIn) { $data.AutoRestoreIn } else { 0 }
        # Update tray
        $Script:TrayIcon.Text = "CPU: $cpuVal% | $modeVal | AI: $aiVal"
        # Top bar - show Auto-Restore countdown if active
        $aiText = if ($aiVal -eq "ON") { "AI ON" } else { "AI OFF" }
        if ($userForcedModeVal -and $autoRestoreInVal -gt 0) {
            $aiText = "Forced: $userForcedModeVal (AI in ${autoRestoreInVal}s)"
        }
        $aiColor = if ($aiVal -eq "ON") { $Script:Colors.Success } elseif ($userForcedModeVal) { $Script:Colors.Warning } else { $Script:Colors.Danger }
        $modeColor = Get-ModeColor $modeVal
        $Script:lblStatusAI.Text = "[AI] $aiText | Iter: $iterVal"; $Script:lblStatusAI.ForeColor = $aiColor
        $Script:lblStatusMode.Text = "[MODE] $modeVal - $reasonVal"; $Script:lblStatusMode.ForeColor = $modeColor
        $Script:lblStatusCPU.Text = "CPU: $cpuVal% | Temp: ${tempVal}C"
        # TAB: Sensors
        $cpuSafe = [Math]::Max(0, [Math]::Min(100, $cpuVal))
        $cpuBarFull = [int]($cpuSafe / 5); $cpuBar = ([char]9608).ToString() * $cpuBarFull + ([char]9617).ToString() * (20 - $cpuBarFull)
        $Script:lblSensorsCPU.Text = "  CPU: [$cpuBar] $cpuSafe%"
        $Script:lblSensorsCPU.ForeColor = if ($cpuSafe -gt 80) { $Script:Colors.Danger } elseif ($cpuSafe -gt 50) { $Script:Colors.Warning } else { $Script:Colors.ChartCPU }
        $Script:lblSensorsIO.Text = "  I/O: $diskVal MB/s | Temp: ${tempVal}C | Mode: $modeVal"
        $Script:lblSensorsIO.ForeColor = Get-TempColor $tempVal
        $pressureBar = ([char]9608).ToString() * [Math]::Min(20, [int]($cpuSafe/5)) + ([char]9617).ToString() * (20 - [Math]::Min(20, [int]($cpuSafe/5)))
        $Script:lblAIPressure.Text = "  Pressure: [$pressureBar] $([int]($cpuSafe/5))"
        $Script:lblAdvancedInfo.Text = "  Ensemble: $ensembleVal | Brain: $brainVal"
        $Script:lblCoreStats.Text = "  Prophet: $prophetVal | QL: $qLearningVal | Bandit: $banditVal | Genetic: $geneticVal | Energy: $energyVal | SelfTuner: $selfTunerVal | Chain: $chainVal"
        $Script:lblCoreWhy.Text = "  Decision: $reasonVal"
        $optimizationCacheSize = if ($data.OptimizationCacheSize) { $data.OptimizationCacheSize } else { 0 }
        $fastBootAppsCount = if ($data.FastBootAppsCount) { $data.FastBootAppsCount } else { 0 }
        $launchHistorySize = if ($data.LaunchHistorySize) { $data.LaunchHistorySize } else { 0 }
        $Script:lblOptimizationCache.Text = "  Optimization: Cache: $optimizationCacheSize apps | FastBoot: $fastBootAppsCount apps | History: $launchHistorySize apps"
        # TAB: AI Details
        if ($Script:AILabels["Brain"]) { $Script:AILabels["Brain"].Text = $brainVal }
        if ($Script:AILabels["QLearning"]) { $Script:AILabels["QLearning"].Text = $qLearningVal }
        if ($Script:AILabels["Bandit"]) { $Script:AILabels["Bandit"].Text = $banditVal }
        if ($Script:AILabels["Genetic"]) { $Script:AILabels["Genetic"].Text = $geneticVal }
        if ($Script:AILabels["Ensemble"]) { $Script:AILabels["Ensemble"].Text = $ensembleVal }
        if ($Script:AILabels["Energy"]) { $Script:AILabels["Energy"].Text = $energyVal }
        if ($Script:AILabels["Prophet"]) { $Script:AILabels["Prophet"].Text = $prophetVal }
        if ($Script:AILabels["SelfTuner"]) { $Script:AILabels["SelfTuner"].Text = $selfTunerVal }
        if ($Script:AILabels["Chain"]) { $Script:AILabels["Chain"].Text = $chainVal }
        if ($Script:AILabels["Anomaly"]) { 
            $anomalyVal = if ($data.Anomaly) { $data.Anomaly } else { "OK" }
            $Script:AILabels["Anomaly"].Text = $anomalyVal 
        }
        if ($Script:AILabels["Thermal"]) { $Script:AILabels["Thermal"].Text = "Pred: $([int]($tempVal+2))C" }
        if ($Script:AILabels["Patterns"]) { $Script:AILabels["Patterns"].Text = "Mode: $modeVal" }
        $Script:lblDecisionReason.Text = "  Current: $reasonVal"
        $Script:lblDecisionStats.Text = "  Decisions: $iterVal | Switches: $modeSwitchesVal | Runtime: $runtimeVal min"
        # AICoordinator Status - V41 z Load Stability
        $coordStatus = if ($data.CoordinatorStatus) { $data.CoordinatorStatus } else { "N/A" }
        $activeEngineData = if ($data.ActiveEngine) { $data.ActiveEngine } else { "QLearning" }
        $transferCountData = if ($data.TransferCount) { $data.TransferCount } else { 0 }
        # V41: Load Stability info
        $loadPhase = if ($data.LoadStabilityPhase) { $data.LoadStabilityPhase } else { "?" }
        $canSilent = if ($data.LoadStabilityCanSilent) { "Yes" } else { "No" }
        $Script:lblCoordinatorStatus.Text = "   Engine: $activeEngineData | Phase: $loadPhase | CanSilent: $canSilent | Xfer: $transferCountData"
        # Koloruj w zaleznosci od fazy obciążenia
        $engineColor = switch ($loadPhase) {
            "Loading" { $Script:Colors.Warning }       # Żółty - loading
            "Spike" { $Script:Colors.Error }           # Czerwony - spike
            "Active" { $Script:Colors.Cyan }           # Cyan - aktywne
            "Idle" { $Script:Colors.Success }          # Zielony - idle
            default { $Script:Colors.TextDim }
        }
        $Script:lblCoordinatorStatus.ForeColor = $engineColor
        # ??- RAM MONITOR UPDATE ???
        try {
            $ramUsage, $ramDelta = $data.RAMUsage, $data.RAMDelta
            $ramSpike, $ramTrend = [bool]$data.RAMSpike, [bool]$data.RAMTrend
            $prophetLearned = if ($data.ProphetLearnedApps) { $data.ProphetLearnedApps } else { 0 }
            $ramSpikesTotal = if ($data.RAMAnalyzerSpikes) { $data.RAMAnalyzerSpikes } else { 0 }
            # Fallback do starych nazw pol
            if ($prophetLearned -eq 0 -and $data.RAMLearnedApps) { $prophetLearned = $data.RAMLearnedApps }
            if ($ramSpikesTotal -eq 0 -and $data.RAMSpikesTotal) { $ramSpikesTotal = $data.RAMSpikesTotal }
            # Generuj slupek RAM
            $filled = [Math]::Min(10, [Math]::Max(0, [int]($ramUsage / 10)))
            $empty = 10 - $filled
            $ramBar = "[" + ("#" * $filled) + ("-" * $empty) + "]"
            # Status i kolor
            $ramStatus = "- Normal"
            $ramColor = $Script:Colors.Success
            if ($ramSpike) {
                $ramStatus = " SPIKE!"
                $ramColor = $Script:Colors.Turbo
            } elseif ($ramTrend) {
                $ramStatus = " TREND"
                $ramColor = $Script:Colors.Warning
            } elseif ($ramUsage -gt 85) {
                $ramStatus = "[WARN] High"
                $ramColor = $Script:Colors.Warning
            }
            # Delta ze znakiem
            $deltaSign = if ($ramDelta -ge 0) { "+" } else { "" }
            $Script:lblRAMStatus.Text = "  RAM: $ramBar $ramUsage%  |  Delta: $deltaSign$ramDelta%  |  Status: $ramStatus  |  Prophet Learned: $prophetLearned apps  |  Spikes: $ramSpikesTotal"
            $Script:lblRAMStatus.ForeColor = $ramColor
        } catch { }
        # TAB: Control
        $Script:lblCtrlMode.Text = $modeVal; $Script:lblCtrlMode.ForeColor = $modeColor
        $Script:lblCtrlAI.Text = "AI: $aiVal"; $Script:lblCtrlAI.ForeColor = $aiColor
        $Script:lblCtrlCPU.Text = "CPU: $cpuVal% | Temp: ${tempVal}C"
        $Script:lblCtrlApp.Text = "App: $appVal"; $Script:lblCtrlReason.Text = $reasonVal
        # - EcoMode button update
        $ecoMode = [bool]$data.EcoMode
        if ($ecoMode) {
            $Script:btnEcoMode.Text = "- ECO ON"
            $Script:btnEcoMode.BackColor = $Script:Colors.Success
            $Script:btnEcoMode.ForeColor = $Script:Colors.Background
        } else {
            $Script:btnEcoMode.Text = "- ECO OFF"
            $Script:btnEcoMode.BackColor = $Script:Colors.Card
            $Script:btnEcoMode.ForeColor = $Script:Colors.Text
        }
        # TAB: Network
        $Script:lblNetDLValue.Text = Format-Speed $dlVal; $Script:lblNetULValue.Text = Format-Speed $ulVal
        $Script:lblNetDLTotal.Text = "Session: $(Format-Bytes $Script:SessionNetDL)"; $Script:lblNetULTotal.Text = "Session: $(Format-Bytes $Script:SessionNetUL)"
        $Script:lblTotalDLValue.Text = Format-Bytes $totalDLVal; $Script:lblTotalULValue.Text = Format-Bytes $totalULVal
        $Script:lblDiskReadValue.Text = "$diskReadVal MB/s"; $Script:lblDiskWriteValue.Text = "$diskWriteVal MB/s"
        $Script:lblDiskIOBoost.Text = if ($ioBoostVal) { "I/O Boost: ON" } else { "I/O Boost: OFF" }
        $Script:lblDiskIOBoost.ForeColor = if ($ioBoostVal) { $Script:Colors.Success } else { $Script:Colors.TextDim }
        $Script:lblGPUTemp.Text = "GPU Temp: ${gpuTempVal}C"; $Script:lblGPULoad.Text = "GPU Load: $gpuLoadVal%"
        $Script:lblVRMTemp.Text = "VRM Temp: ${vrmTempVal}C"; $Script:lblCPUPower.Text = "CPU Power: ${cpuPowerVal}W"
        $Script:lblCPUVendor.Text = "Vendor: $cpuVendorVal"
        $Script:lblCPUModel.Text = "Model: $cpuModelVal"
        $Script:lblCPUGen.Text = "Generation: $cpuGenVal"
        $Script:lblCPUArch.Text = "Architecture: $cpuArchVal"
        $Script:lblCPUCores.Text = "Cores: $cpuCoresVal | Threads: $cpuThreadsVal"
        # Hybrid CPU info (tylko dla Intel)
        if ($isHybridVal) {
            $Script:lblCPUHybrid.Text = " Hybrid CPU: P-cores: $pCoreCountVal | E-cores: $eCoreCountVal"
            $Script:lblCPUHybrid.ForeColor = [System.Drawing.Color]::Cyan
        } else {
            $Script:lblCPUHybrid.Text = ""
        }
        # Kolor dla AMD X3D (specjalny)
        if ($cpuArchVal -match "X3D|3D V-Cache") {
            $Script:lblCPUArch.ForeColor = [System.Drawing.Color]::Magenta
        } else {
            $Script:lblCPUArch.ForeColor = $Script:Colors.Balanced
        }
        try {
            # Collect data (convert to KB/s for network)
            $dlKB = $dlVal / 1KB
            $ulKB = $ulVal / 1KB
            # Add to history
            $Script:NetDLHistory.Add($dlKB)
            $Script:NetULHistory.Add($ulKB)
            $Script:DiskReadHistory.Add($diskReadVal)
            $Script:DiskWriteHistory.Add($diskWriteVal)
            $Script:GPUTempHistory.Add([double]$gpuTempVal)
            $Script:GPULoadHistory.Add([double]$gpuLoadVal)
            # Limit history to max points
            if ($Script:NetDLHistory.Count -gt $Script:ChartMaxPoints) { $Script:NetDLHistory.RemoveAt(0) }
            if ($Script:NetULHistory.Count -gt $Script:ChartMaxPoints) { $Script:NetULHistory.RemoveAt(0) }
            if ($Script:DiskReadHistory.Count -gt $Script:ChartMaxPoints) { $Script:DiskReadHistory.RemoveAt(0) }
            if ($Script:DiskWriteHistory.Count -gt $Script:ChartMaxPoints) { $Script:DiskWriteHistory.RemoveAt(0) }
            if ($Script:GPUTempHistory.Count -gt $Script:ChartMaxPoints) { $Script:GPUTempHistory.RemoveAt(0) }
            if ($Script:GPULoadHistory.Count -gt $Script:ChartMaxPoints) { $Script:GPULoadHistory.RemoveAt(0) }
            # Draw charts (auto-scale) - use [double] for large values
            $maxNetSpeed = [Math]::Max([double]100, [Math]::Max([double](($Script:NetDLHistory | Measure-Object -Maximum).Maximum), [double](($Script:NetULHistory | Measure-Object -Maximum).Maximum)))
            Show-DualChart -PictureBox $Script:picNetChart `
                -Data1 $Script:NetDLHistory -Data2 $Script:NetULHistory `
                -Color1 $Script:Colors.Success -Color2 $Script:Colors.Warning `
                -Label1 "DL:" -Label2 "UL:" `
                -MinVal 0 -MaxVal $maxNetSpeed -Unit " KB/s"
            $maxDiskIO = [Math]::Max(10, [Math]::Max(($Script:DiskReadHistory | Measure-Object -Maximum).Maximum, ($Script:DiskWriteHistory | Measure-Object -Maximum).Maximum))
            Show-DualChart -PictureBox $Script:picDiskChart `
                -Data1 $Script:DiskReadHistory -Data2 $Script:DiskWriteHistory `
                -Color1 $Script:Colors.ChartCPU -Color2 $Script:Colors.Turbo `
                -Label1 "R:" -Label2 "W:" `
                -MinVal 0 -MaxVal $maxDiskIO -Unit " MB/s"
            $maxGPUTemp = 100
            $maxGPULoad = 100
            # Dual Y-axis: Temp (0-100degC) + Load (0-100%)
            Show-DualChart -PictureBox $Script:picGPUChart `
                -Data1 $Script:GPUTempHistory -Data2 $Script:GPULoadHistory `
                -Color1 $Script:Colors.ChartTemp -Color2 ([System.Drawing.Color]::Cyan) `
                -Label1 "T:" -Label2 "L:" `
                -MinVal 0 -MaxVal 100 -Unit ""
        } catch {
            # Ignore chart errors
        }
        try {
            Update-NetworkAI
        } catch {
            # Ignore NetworkAI errors
        }
        try {
            Update-ProcessAI
        } catch {
            # Ignore ProcessAI errors
        }
        try {
            Update-GPUAI
        } catch {
            # Ignore GPUAI errors
        }
        # Activity Log
        $actLog = Get-SafeValue -Data $data -Property "ActivityLog" -Default @()
        if ($actLog -and $actLog.Count -gt 0) { foreach ($entry in $actLog) { Add-ColoredLog $entry } }
        # - V37.8.5 FIX: Ustaw $Script:WidgetData GLOBALNIE dla wszystkich chartow (ProBalance, RAM, etc.)
        $Script:WidgetData = $data
        try {
            $historyData = Get-SafeValue -Data $data -Property "DecisionHistory" -Default @()
            if ($historyData -and $historyData.Count -gt 0) {
                $Script:DecisionHistoryData = $historyData
                # DEBUG: Log co 10s
                if ((Get-Date).Second % 10 -eq 0) {
                    Write-Host " Console received DecisionHistory: $($historyData.Count) points" -ForegroundColor Cyan
                }
                # Update stats label
                $dataPoints = $historyData.Count
                # Oblicz prediction lead - ile sekund AI wyprzedza obciazenie
                $predLead = 0
                if ($dataPoints -gt 5) {
                    # Porownaj power vs CPU - jesli power rosnie przed CPU = prediction lead
                    for ($i = 0; $i -lt ($dataPoints - 5); $i++) {
                        $currentCPU = [int]$historyData[$i].CPU
                        $futureCPU = [int]$historyData[$i + 5].CPU
                        $currentPower = [int]$historyData[$i].Power
                        # Jesli power wzroslo przed CPU
                        if ($currentPower -gt 20 -and $futureCPU -gt $currentCPU + 10) {
                            $predLead = 5
                            break
                        }
                    }
                }
                $Script:lblHistoryStats.Text = "Data points: $dataPoints | Prediction lead: ${predLead}s"
                $Script:lblHistoryStats.ForeColor = if ($predLead -gt 0) { $Script:Colors.Success } else { $Script:Colors.TextDim }
                # Refresh wykres
                $Script:chartHistoryMap.Invalidate()
                if ($Script:picRAMChart) {
                    $Script:picRAMChart.Invalidate()
                    if ($data.RAMIntelligenceHistory -and $data.RAMIntelligenceHistory.Count -gt 0) {
                        $latest = $data.RAMIntelligenceHistory[0]
                        # Update values
                        $Script:lblRAMValue.Text = "RAM:           $($latest.RAM)%"
                        $Script:lblDeltaValue.Text = "Delta:         $($latest.Delta)%"
                        $Script:lblAccelValue.Text = "Acceleration:  $($latest.Acceleration)%"
                        $Script:lblTrendTypeValue.Text = "Trend Type:    $($latest.TrendType)"
                        # Color delta based on value
                        $Script:lblDeltaValue.ForeColor = if ([double]$latest.Delta -gt 5) { $Script:Colors.Danger } `
                            elseif ([double]$latest.Delta -gt 2) { $Script:Colors.Warning } `
                            elseif ([double]$latest.Delta -lt -2) { $Script:Colors.Success } `
                            else { $Script:Colors.Text }
                        # Color trend type
                        $Script:lblTrendTypeValue.ForeColor = switch ($latest.TrendType) {
                            "EXPONENTIAL" { $Script:Colors.Danger }
                            "LINEAR" { $Script:Colors.Warning }
                            "DECEL" { $Script:Colors.Success }
                            default { $Script:Colors.Text }
                        }
                        # Update threshold info
                        $thresholdIcon = if ($latest.ThresholdIcon) { $latest.ThresholdIcon } else { "" }
                        $Script:lblCurrentThreshold.Text = "Current: $($latest.ThresholdValue)% $thresholdIcon"
                        $Script:lblThresholdReason.Text = if ($latest.ThresholdReason) { $latest.ThresholdReason } else { "Normal CPU" }
                        # Color code threshold based on zone
                        $Script:lblCurrentThreshold.ForeColor = switch ($latest.ThresholdZone) {
                            "COOL" { [System.Drawing.Color]::Cyan }
                            "WARM" { [System.Drawing.Color]::Yellow }
                            "HOT" { [System.Drawing.Color]::Red }
                            default { [System.Drawing.Color]::LimeGreen }
                        }
                        # Status (Spike/Trend/Normal)
                        if ($latest.Spike) {
                            $Script:lblRAMStatus2.Text = "Status:  SPIKE DETECTED!"
                            $Script:lblRAMStatus2.ForeColor = $Script:Colors.Turbo
                        } elseif ($latest.Trend) {
                            $Script:lblRAMStatus2.Text = "Status:  TREND RISING"
                            $Script:lblRAMStatus2.ForeColor = $Script:Colors.Warning
                        } else {
                            $Script:lblRAMStatus2.Text = "Status: - Normal"
                            $Script:lblRAMStatus2.ForeColor = $Script:Colors.Success
                        }
                        # AI Reward info
                        if ($latest.RewardGiven) {
                            $Script:lblAIRAMReward.Text = "Last Reward: +$($latest.RewardValue) | Source: $($latest.RewardSource)"
                            $Script:lblAIRAMReward.ForeColor = $Script:Colors.Success
                        } else {
                            $Script:lblAIRAMReward.Text = "Last Reward: --- | Source: ---"
                            $Script:lblAIRAMReward.ForeColor = $Script:Colors.TextDim
                        }
                        # Last Boost Reason (from recent history)
                        $recentBoost = $data.RAMIntelligenceHistory | Where-Object { $_.Spike -or $_.Trend } | Select-Object -First 1
                        if ($recentBoost) {
                            $boostType = if ($recentBoost.Spike) { "SPIKE" } else { "TREND" }
                            $Script:lblLastBoost.Text = "Last Boost: $boostType D$($recentBoost.Delta)% @ $($recentBoost.App)"
                        }
                    }
                    $spikesTotal, $trendsTotal = $data.RAMSpikesTotal, $data.RAMTrendsTotal
                    $preBoostsTotal, $learnedApps = $data.RAMPreBoostsTotal, $data.RAMLearnedApps
                    $appsNeedingBoost = if ($data.RAMAppsNeedingBoost) { $data.RAMAppsNeedingBoost } else { 0 }
                    $Script:lblRAMCounts.Text = "Spikes: $spikesTotal  |  Trends: $trendsTotal  |  PreBoosts: $preBoostsTotal"
                    $Script:lblLearnedApps.Text = "Learned Apps: $learnedApps tracked ($appsNeedingBoost need boost)"
                    # AI Learning info
                    $activeEngine = if ($data.ActiveEngine) { $data.ActiveEngine } else { "QLearning" }
                    $Script:lblAIRAMUsage.Text = "Engine: $activeEngine | RAM in state: YES"
                }
            }
        } catch {
            # Ignore history map errors
        }
        # - V37.8.5 FIX: Update ProBalance Chart and Metrics (POZA blokiem try-catch Decision History)
        try {
            if ($Script:picProBalanceChart) {
                $Script:picProBalanceChart.Invalidate()
                # Update metrics panel
                $pbEnabled, $pbThrottled, $pbThreshold = [bool]$data.ProBalanceEnabled, $data.ProBalanceThrottled, $data.ProBalanceThreshold
                $pbTotalThrottles, $pbTotalRestores = $data.ProBalanceTotalThrottles, $data.ProBalanceTotalRestores
                $pbProcesses = if ($data.ProBalanceThrottledList) { $data.ProBalanceThrottledList } else { @() }
                if ($pbEnabled) {
                    $Script:lblPBEnabled.Text = "Status: - Enabled"
                    $Script:lblPBEnabled.ForeColor = [System.Drawing.Color]::LimeGreen
                } else {
                    $Script:lblPBEnabled.Text = "Status: - Disabled"
                    $Script:lblPBEnabled.ForeColor = [System.Drawing.Color]::Gray
                }
                $Script:lblPBThrottled.Text = "Currently Throttled: $pbThrottled"
                $Script:lblPBThrottled.ForeColor = if ($pbThrottled -gt 0) { [System.Drawing.Color]::FromArgb(255, 165, 0) } else { [System.Drawing.Color]::White }
                $Script:lblPBThreshold.Text = "CPU Threshold: $pbThreshold%"
                $perfBoosts = if ($data.PerfBoosterPriorityBoosts) { $data.PerfBoosterPriorityBoosts } else { 0 }
                $perfPreempt = if ($data.PerfBoosterPreemptiveBoosts) { $data.PerfBoosterPreemptiveBoosts } else { 0 }
                $perfFrozen = if ($data.PerfBoosterCurrentlyFrozen) { $data.PerfBoosterCurrentlyFrozen } else { 0 }
                $perfCacheWarms = if ($data.PerfBoosterCacheWarms) { $data.PerfBoosterCacheWarms } else { 0 }
                $Script:lblPBTotals.Text = "Throttles: $pbTotalThrottles | Restores: $pbTotalRestores | PrioBoost: $perfBoosts | Preempt: $perfPreempt"
                if ($pbProcesses -and $pbProcesses.Count -gt 0) {
                    $procList = ($pbProcesses | Select-Object -First 3) -join "`n"
                    $Script:lblPBProcesses.Text = $procList
                    $Script:lblPBProcesses.ForeColor = [System.Drawing.Color]::FromArgb(255, 165, 0)
                } else {
                    $Script:lblPBProcesses.Text = "(none)"
                    $Script:lblPBProcesses.ForeColor = [System.Drawing.Color]::Gray
                }
            }
        } catch {
            try {
                $errorLog = "C:\CPUManager\ErrorLog.txt"
                $msg = "$(Get-Date -Format 'HH:mm:ss') - ProBalance update error: $_"
                Add-Content -Path $errorLog -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
            } catch {}
        }
        # TDP status (co 3s)
        $Script:TDPRefreshCounter++
        if ($Script:TDPRefreshCounter -ge 3) {
            $Script:TDPRefreshCounter = 0
            if (Test-Path $Script:RyzenAdjPath) {
                $info = Get-RyzenAdjInfo
                if ($info) {
                    $Script:lblTDPCurrent.Text = "Current: STAPM=$($info.STAPMValue)W (lim:$($info.STAPM)W) | Fast=$($info.FastValue)W | Slow=$($info.SlowValue)W | Temp=$($info.TctlValue)C"
                    $Script:lblTDPCurrent.ForeColor = if ($info.TctlValue -gt 85) { $Script:Colors.Danger } elseif ($info.TctlValue -gt 75) { $Script:Colors.Warning } else { $Script:Colors.Success }
                }
            }
        }
        if (-not $Script:DatabaseRefreshCounter) { $Script:DatabaseRefreshCounter = 0 }
        $Script:DatabaseRefreshCounter++
        if ($Script:DatabaseRefreshCounter -ge 10) {  # 10 ticks x ~1s = 10s
            $Script:DatabaseRefreshCounter = 0
            try { Update-DatabaseView } catch { }
        }
        if (-not $Script:RAMTrimCounter) { $Script:RAMTrimCounter = 0 }
        $Script:RAMTrimCounter++
        if ($Script:RAMTrimCounter -ge 300) {  # 300 ticks x 1s = 5 minut
            $Script:RAMTrimCounter = 0
            try {
                # V40 FIX: RAM trimming w background żeby nie blokować UI
                $ps = [powershell]::Create()
                $null = $ps.AddScript({
                    try {
                        $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
                        Add-Type -Name Win32Console -Namespace Console -MemberDefinition @'
[DllImport("psapi.dll")] public static extern int EmptyWorkingSet(IntPtr hwProc);
'@ -ErrorAction SilentlyContinue
                        [Console.Win32Console]::EmptyWorkingSet($currentProcess.Handle) | Out-Null
                        [System.GC]::Collect()
                        [System.GC]::Collect()
                    } catch { }
                })
                $null = $ps.BeginInvoke()
                # Cleanup po 5 sekundach
                $null = [System.Threading.Timer]::new({
                    param($ps)
                    try { $ps.Dispose() } catch { }
                }, $ps, 5000, [System.Threading.Timeout]::Infinite)
            } catch { }
        }
        if (-not $Script:CacheClearCounter) { $Script:CacheClearCounter = 0 }
        $Script:CacheClearCounter++
        if ($Script:CacheClearCounter -ge 120) {  # 120 ticks x 1s = 2 minuty
            $Script:CacheClearCounter = 0
            try {
                if ($Script:ProcessCache) { $Script:ProcessCache = @{} }
                if ($Script:AppListCache) { $Script:AppListCache = $null }
            } catch { }
        }
        if (-not $Script:AppListRefreshCounter) { $Script:AppListRefreshCounter = 0 }
        $Script:AppListRefreshCounter++
        if ($Script:AppListRefreshCounter -ge 5) {  # 5 ticks x ~1s = 5 sekund
            $Script:AppListRefreshCounter = 0
            try {
                # Odswiezaj liste aplikacji (zawsze - bez wzgledu na zakladke)
                Update-ApplicationList
            } catch { }
        }
        if (-not $Script:LastWatchdogIteration) { $Script:LastWatchdogIteration = 0 }
        if (-not $Script:WatchdogStuckCounter) { $Script:WatchdogStuckCounter = 0 }
        $currentIter = $Script:LastIteration
        if ($currentIter -eq $Script:LastWatchdogIteration) {
            $Script:WatchdogStuckCounter++
            if ($Script:WatchdogStuckCounter -ge 30) {  # 30 ticks = ~30s
                # Dane zamrozone - zresetuj cache lock i sprobuj zrestartowac timery
                $Script:WatchdogStuckCounter = 0
                try {
                    # Dodatkowy diagnostyczny odczyt
                    $fileCheck = $null
                    try {
                        $fileCheck = Read-WidgetData
                        $fileIter = if ($fileCheck) { $fileCheck.Iteration } else { "null" }
                    } catch { $fileIter = "error" }
                    $msg = "[SELF-HEAL] No new data (Iteration stuck at $currentIter) for 30s. File iter: $fileIter. Forcing cache/timer reset."
                    Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
                    # Resetuj cache i locki
                    $Script:CachedWidgetDataLock = New-Object Object
                    $Script:CachedWidgetData = $null
                    $Script:BackgroundRefreshTimerRunning = $false
                    # Wymuś świeży odczyt - zaakceptuj KAŻDE dane z pliku (ENGINE mógł się zrestartować)
                    if ($fileCheck -and $null -ne $fileCheck.Iteration) {
                        $Script:CachedWidgetData = $fileCheck
                        $Script:LastIteration = $fileCheck.Iteration
                        $Script:LastValidData = $fileCheck
                        Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value "[SELF-HEAL] ✓ Recovered data from file (iter: $($fileCheck.Iteration), was: $currentIter)" -Encoding UTF8 -ErrorAction SilentlyContinue
                    }
                    # Restart timerów
                    if ($Script:BackgroundRefreshTimer) { $Script:BackgroundRefreshTimer.Stop(); $Script:BackgroundRefreshTimer.Start() }
                    if ($Script:Timer) { $Script:Timer.Stop(); $Script:Timer.Start() }
                } catch {
                    $msg = "[SELF-HEAL ERROR] Exception during self-healing: $_"
                    Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
                }
            }
        } else {
            $Script:WatchdogStuckCounter = 0
            $Script:LastWatchdogIteration = $currentIter
        }
        } # V38 FIX: End of if ($hasValidData) block
    } catch {
        # V40 FIX: Log błędy timera zamiast cichego ignorowania
        try {
            $msg = "[TIMER ERROR] $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
            Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    } finally {
        $Script:TimerRunning = $false
    }
})
# #
# URUCHOMIENIE
# #
$form.Add_MouseWheel({
    param($sender, $e)
    # Przekaz scroll event do aktywnej zakladki
    $activeTab = $tabs.SelectedTab
    if ($activeTab -and $activeTab.AutoScroll) {
        # Oblicz nowa pozycje scroll
        $currentScroll = $activeTab.AutoScrollPosition.Y
        $delta = -$e.Delta / 3  # Delta jest zwykle 120, dzielimy dla plynniejszego scrollu
        # Ustaw nowa pozycje (musi byc ujemna wartosc)
        $newY = [Math]::Max($currentScroll + $delta, 0)
        $activeTab.AutoScrollPosition = New-Object System.Drawing.Point(0, $newY)
    }
})
$form.Add_Shown({ 
    try {
        $pbConfigPath = Join-Path $Script:ConfigDir "ProBalanceConfig.json"
        if (Test-Path $pbConfigPath) {
            $pbConfig = Get-Content $pbConfigPath -Raw | ConvertFrom-Json
            if ($pbConfig.ThrottleThreshold) {
                $Script:numPBThreshold.Value = [Math]::Max(20, [Math]::Min(90, $pbConfig.ThrottleThreshold))
            }
        }
    } catch { }
    # WinForms Timer dziala na watku UI - nawet 1s timeout blokuje cale UI!
    # Background job dla WMI operacji - NIE blokuje UI
    $Script:BackgroundWMIJob = $null
    $Script:LastDiskSampleTime = Get-Date '1970-01-01'
    # Lekki WinForms timer - sprawdza tylko wyniki z background job, NIE wywoluje WMI
    $Script:BackgroundRefreshTimer = New-Object System.Windows.Forms.Timer
    $Script:BackgroundRefreshTimer.Interval = 500  # v39.6: Szybki polling wynikow (bez blokowania!)
    $Script:BackgroundRefreshTimerRunning = $false
    $Script:BackgroundRefreshTimerRunningStartTime = $null  # v40 FIX: Tracking czasu blokady
    $Script:BackgroundWMIJobStartTime = $null
    $Script:BackgroundWMIJobWatchdogCounter = 0
    $Script:BackgroundRefreshTimerWatchdogCounter = 0
    $Script:BackgroundRefreshTimerLastTick = [DateTime]::UtcNow
    $Script:BackgroundRefreshTimer.Add_Tick({
        # Zabezpieczenie: jeśli flaga jest ustawiona dłużej niż 5s, wymuś reset
        if ($Script:BackgroundRefreshTimerRunning) {
            if (-not $Script:BackgroundRefreshTimerRunningStartTime) {
                $Script:BackgroundRefreshTimerRunningStartTime = [DateTime]::UtcNow
            }
            $runningFor = ([DateTime]::UtcNow - $Script:BackgroundRefreshTimerRunningStartTime).TotalSeconds
            if ($runningFor -gt 5) {
                $msg = "[WATCHDOG] BackgroundRefreshTimer stuck in running state for $([int]$runningFor)s - forcing reset"
                Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
                $Script:BackgroundRefreshTimerRunning = $false
                $Script:BackgroundRefreshTimerRunningStartTime = $null
            } else {
                return  # Nadal pracuje, nie próbuj uruchomić ponownie
            }
        }
        $Script:BackgroundRefreshTimerRunning = $true
        $Script:BackgroundRefreshTimerRunningStartTime = [DateTime]::UtcNow
        try {
            $Script:BackgroundRefreshTimerLastTick = [DateTime]::UtcNow
            $Script:BackgroundRefreshTimerLastTick = [DateTime]::UtcNow
            $now = Get-Date
            $diskSampleIntervalMs = 5000
            # Watchdog: jesli job trwa za dlugo (np. >10s), wymus usuniecie i loguj
            if ($Script:BackgroundWMIJob -and $Script:BackgroundWMIJobStartTime) {
                $jobAge = ($now - $Script:BackgroundWMIJobStartTime).TotalSeconds
                if ($jobAge -gt 10) {
                    try {
                        $jobState = try { $Script:BackgroundWMIJob.State } catch { "Unknown" }
                        $msg = "[WATCHDOG] BackgroundWMIJob killed after $([int]$jobAge)s (State: $jobState) - Counter: $($Script:BackgroundWMIJobWatchdogCounter)"
                        Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
                    } catch {}
                    try { 
                        Stop-Job -Job $Script:BackgroundWMIJob -ErrorAction SilentlyContinue
                        Remove-Job -Job $Script:BackgroundWMIJob -Force -ErrorAction SilentlyContinue 
                    } catch {}
                    $Script:BackgroundWMIJob = $null
                    $Script:BackgroundWMIJobStartTime = $null
                    $Script:BackgroundWMIJobWatchdogCounter++
                    # Jeśli watchdog często interweniuje (>5 razy), zwiększ interwał próbkowania
                    if ($Script:BackgroundWMIJobWatchdogCounter -gt 5) {
                        $diskSampleIntervalMs = 10000  # Zwiększ do 10s
                    }
                }
            }
            # Sprawdz wynik istniejacego job-a (non-blocking!)
            if ($Script:BackgroundWMIJob -and $Script:BackgroundWMIJob.State -eq 'Completed') {
                try {
                    $result = Receive-Job -Job $Script:BackgroundWMIJob -ErrorAction SilentlyContinue
                    if ($result) {
                        $Script:LiveDiskReadMBs = $result.ReadMBs
                        $Script:LiveDiskWriteMBs = $result.WriteMBs
                        if ($result.NetDL -ne $null) { $Script:LiveNetDL = $result.NetDL }
                        if ($result.NetUL -ne $null) { $Script:LiveNetUL = $result.NetUL }
                    }
                } catch { }
                try { Remove-Job -Job $Script:BackgroundWMIJob -Force -ErrorAction SilentlyContinue } catch {}
                $Script:BackgroundWMIJob = $null
                $Script:BackgroundWMIJobStartTime = $null
            }
            # Uruchom nowy job jesli minal interwal i nie ma aktywnego job-a
            if (-not $Script:BackgroundWMIJob -and (($now - $Script:LastDiskSampleTime).TotalMilliseconds -ge $diskSampleIntervalMs)) {
                $Script:LastDiskSampleTime = $now
                $Script:BackgroundWMIJob = Start-Job -ScriptBlock {
                    $out = @{ ReadMBs = 0; WriteMBs = 0; NetDL = $null; NetUL = $null }
                    try {
                        $disk = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue -OperationTimeoutSec 2
                        if ($disk) {
                            $out.ReadMBs = [Math]::Round([Math]::Max(0, [double]$disk.DiskReadBytesPersec) / 1MB, 1)
                            $out.WriteMBs = [Math]::Round([Math]::Max(0, [double]$disk.DiskWriteBytesPersec) / 1MB, 1)
                        }
                        $adapters = Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue -OperationTimeoutSec 2 |
                            Where-Object { $_.Name -notmatch 'isatap|Teredo|Loopback|WAN Miniport|QoS|Filter|Pseudo|6to4|Hyper-V|vEthernet|Virtual|VPN|TAP-' }
                        if ($adapters) {
                            $out.NetDL = [int64](($adapters | Measure-Object -Property BytesReceivedPersec -Sum).Sum)
                            $out.NetUL = [int64](($adapters | Measure-Object -Property BytesSentPersec -Sum).Sum)
                        }
                    } catch { }
                    return $out
                }
                $Script:BackgroundWMIJobStartTime = $now
            }
            $data = Read-WidgetData
            if ($data) {
                $lockTaken = $false
                try {
                    $lockTaken = [System.Threading.Monitor]::TryEnter($Script:CachedWidgetDataLock, 50)
                    if ($lockTaken) {
                        $Script:CachedWidgetData = $data
                    }
                } finally {
                    if ($lockTaken) {
                        [System.Threading.Monitor]::Exit($Script:CachedWidgetDataLock)
                    }
                }
                try {
                    $dl = $null; $ul = $null
                    if ($data.PSObject.Properties.Name -contains 'TotalDownloaded') { $dl = [int64](Get-SafeInt64 -Data $data -Property 'TotalDownloaded' -Default 0) }
                    if ($data.PSObject.Properties.Name -contains 'TotalUploaded') { $ul = [int64](Get-SafeInt64 -Data $data -Property 'TotalUploaded' -Default 0) }
                    if (($dl -and $dl -gt 0) -or ($ul -and $ul -gt 0)) {
                        $now = Get-Date
                        if (($now - $Script:LastNetworkStatsWriteTime).TotalSeconds -ge 5) {
                            $Script:LastNetworkStatsWriteTime = $now
                            try {
                                $payload = @{ TotalDownloaded = $dl; TotalUploaded = $ul; LastUpdate = $now.ToString('o') } | ConvertTo-Json -Depth 3
                                Start-BackgroundWrite $Script:NetworkStatsPath $payload 'UTF8'
                                if ($dl) { $Script:PersistentNetDL = $dl }
                                if ($ul) { $Script:PersistentNetUL = $ul }
                            } catch {}
                        }
                    }
                } catch {}
            }
            try { Update-NetworkStats } catch {}
        } catch {
            $msg = "[ERROR] Exception in BackgroundRefreshTimer: $_"
            Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
        } finally {
            $Script:BackgroundRefreshTimerRunning = $false
            $Script:BackgroundRefreshTimerRunningStartTime = $null
        }
    })
    $Script:BackgroundRefreshTimer.Start()
# --- Watchdog for BackgroundRefreshTimer ---
$Script:BackgroundRefreshTimerWatchdog = New-Object System.Windows.Forms.Timer
$Script:BackgroundRefreshTimerWatchdog.Interval = 5000  # Check every 5s
$Script:BackgroundRefreshTimerWatchdog.Add_Tick({
    try {
        $now = [DateTime]::UtcNow
        $elapsed = ($now - $Script:BackgroundRefreshTimerLastTick).TotalSeconds
        if ($elapsed -ge 10) {
            $Script:BackgroundRefreshTimerWatchdogCounter++
            $msg = "[WATCHDOG] BackgroundRefreshTimer not ticking for $([int]$elapsed)s. Restarting timer. (Count: $($Script:BackgroundRefreshTimerWatchdogCounter))"
            Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
            $Script:BackgroundRefreshTimerRunning = $false
            try { $Script:BackgroundRefreshTimer.Stop(); $Script:BackgroundRefreshTimer.Start() } catch {}
            $Script:BackgroundRefreshTimerLastTick = $now
        }
    } catch {
        $msg = "[WATCHDOG ERROR] Exception in BackgroundRefreshTimerWatchdog: $_"
        Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
    }
})
$Script:BackgroundRefreshTimerWatchdog.Start()
    # UI timer (bez I/O!)
    $Script:Timer.Start()
    try {
        # Zwolnij pamiec procesu PowerShell
        $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
        [Console.Win32Console]::EmptyWorkingSet($currentProcess.Handle) | Out-Null
        # Garbage collection
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
        # Log do debug
        $beforeMB = [Math]::Round($currentProcess.WorkingSet64 / 1MB, 1)
        $currentProcess.Refresh()
        $afterMB = [Math]::Round($currentProcess.WorkingSet64 / 1MB, 1)
        # Balloon tip z wynikiem (opcjonalne)
        # $Script:TrayIcon.ShowBalloonTip(2000, "RAM Optimized", "Freed $([Math]::Round($beforeMB - $afterMB, 1))MB", [System.Windows.Forms.ToolTipIcon]::Info)
    } catch {
        $msg = "[ERROR] Exception in Timer: $_"
        Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
    } finally {
        $Script:TimerRunning = $false
    }
})
$btnClearCache.Add_Click({
    try {
        # Wyslij sygnal do engine aby wyczyscil cache
        Send-ReloadSignal @{ Type = "ClearCache" }
        $Script:txtCacheStatus.Text = "Cache cleared! Waiting for confirmation from engine..."
        [System.Windows.Forms.MessageBox]::Show("Cache clear signal sent to engine!", "Cache", "OK", "Information")
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to clear cache: $($_.Exception.Message)", "Error", "OK", "Error")
    }
})
$btnRefreshPredictions.Add_Click({
    Update-PredictiveDisplay
})
$btnRefreshHistory.Add_Click({
    Update-HistoryDisplay  
})
$btnRefreshEngine.Add_Click({
    Update-EngineDisplay
})
$btnStartEngine.Add_Click({
    try {
        # Uzyj lokalizacji gdzie znajduje sie CONFIGURATOR script (nie current directory!)
        $currentDir = $PSScriptRoot
        if (-not $currentDir) {
            # Fallback dla starszych wersji PowerShell
            $currentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        }
        if (-not $currentDir) {
            $currentDir = "C:\CPUManager"
        }
        # Engine ZAWSZE w tej samej lokalizacji co configurator
        $enginePath = Join-Path $currentDir "CPUManager_v39.ps1"
        # Dane JSON ZAWSZE w C:\CPUManager (niezaleznie gdzie sa pliki .ps1)
        $dataFolder = "C:\CPUManager"
        # Upewnij sie ze folder danych istnieje
        if (-not (Test-Path $dataFolder)) {
            New-Item -Path $dataFolder -ItemType Directory -Force | Out-Null
        }
        if (Test-Path $enginePath) {
            # Uruchom engine z parametrem dla folderu danych
            $arguments = "-ExecutionPolicy Bypass -File `"$enginePath`" -ConfigDir `"$dataFolder`""
            try {
                Start-Process "powershell.exe" -ArgumentList $arguments -WindowStyle Normal
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Engine start error: $($_.Exception.Message)", "Error", "OK", "Error")
            }
            $Script:txtEngineStatus.Text = " ENGINE STARTED SUCCESSFULLY!`n`n" +
                "Engine file: $enginePath`n" +
                "Data folder: $dataFolder`n" +
                "Current dir: $currentDir`n" +
                "Engine should appear in separate window.`n" +
                "Wait 10-30 seconds, then refresh to see AI data."
        } else {
            $Script:txtEngineStatus.Text = "- ENGINE FILE NOT FOUND!`n`n" +
                "Looking for: $enginePath`n" +
                "Current folder: $currentDir`n`n" +
                "Please ensure CPUManager_v39.ps1 exists`n" +
                "in the same folder where you ran configurator.`n`n" +
                "Data will be stored in: $dataFolder"
            [System.Windows.Forms.MessageBox]::Show(
                "Engine file not found!`n`nLooking for: $enginePath`n`nPlease ensure both files are in the same folder.", 
                "Engine Not Found", "OK", "Error")
        }
    } catch {
        $Script:txtEngineStatus.Text = "- ERROR STARTING ENGINE: $($_.Exception.Message)`n`n" +
            "Current folder: $currentDir`n" +
            "Engine path: $enginePath`n" +
            "Data folder: $dataFolder"
        [System.Windows.Forms.MessageBox]::Show("Failed to start engine: $($_.Exception.Message)", "Error", "OK", "Error")
    }
})
$btnExportHistory.Add_Click({
    try {
        $exportData = @{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            CacheData = "Not available from configurator"
            LaunchHistory = "Not available from configurator" 
            EngineStatus = $Script:txtEngineStatus.Text
        }
        $exportPath = Join-Path $env:USERPROFILE "Desktop\CPUManager_EngineReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $exportData | ConvertTo-Json -Depth 3 | Set-Content $exportPath -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show("Report exported to:`n$exportPath", "Export Complete", "OK", "Information")
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Export failed: $($_.Exception.Message)", "Error", "OK", "Error")
    }
})
#  FUNKCJE MONITOROWANIA ENGINE
function Update-CacheDisplay {
    try {
        # Sprawdz czy engine dziala - podobnie jak Update-EngineDisplay
        $engineProcess = Get-Process | Where-Object {
            ($_.ProcessName -eq "powershell" -or $_.ProcessName -eq "pwsh") -and 
            ($_.MainWindowTitle -like "*CPU Manager*" -or $_.MainWindowTitle -like "*CPUManager*")
        }
        # Sprobuj odczytac dane z wlasciwych plikow AI engine
        $configDir = "C:\CPUManager"
        $prophetPath = Join-Path $configDir "ProphetMemory.json"
        $brainPath = Join-Path $configDir "BrainState.json"
        if ((Test-Path $prophetPath) -or (Test-Path $brainPath)) {
            try {
                $cacheText = if ($engineProcess) { " ENGINE RUNNING - AI Data Available:`n`n" } else { "[WARN] ENGINE DATA DETECTED:`n`n" }
                # Odczytaj Prophet Memory (historia aplikacji)
                if (Test-Path $prophetPath) {
                    $prophetData = Get-Content $prophetPath -Raw | ConvertFrom-Json
                    $cacheText += " PROPHET MEMORY (App History):`n"
                    if ($prophetData.Apps -and ($prophetData.Apps.PSObject.Properties | Measure-Object).Count -gt 0) {
                        $appCount = 0
                        foreach ($app in $prophetData.Apps.PSObject.Properties) {
                            if ($appCount -lt 10) {  # Pokaz top 10
                                $appData = $app.Value
                                $usage = if ($appData.Launches) { $appData.Launches } else { 0 }
                                $cacheText += "  o $($app.Name): $usage uses`n"
                                $appCount++
                            }
                        }
                        if (($prophetData.Apps.PSObject.Properties | Measure-Object).Count -gt 10) {
                            $remaining = ($prophetData.Apps.PSObject.Properties | Measure-Object).Count - 10
                            $cacheText += "  ... and $remaining more apps`n"
                        }
                    } else {
                        $cacheText += "  No applications learned yet.`n"
                    }
                } else {
                    $cacheText += " PROPHET MEMORY: File not found`n"
                }
                # Odczytaj Brain State (wagi aplikacji)
                $cacheText += "`n NEURAL BRAIN (App Weights):`n"
                if (Test-Path $brainPath) {
                    $brainData = Get-Content $brainPath -Raw | ConvertFrom-Json
                    if ($brainData.Weights -and ($brainData.Weights.PSObject.Properties | Measure-Object).Count -gt 0) {
                        $weightCount = 0
                        $sortedWeights = $brainData.Weights.PSObject.Properties | Sort-Object {$_.Value} -Descending
                        foreach ($weight in $sortedWeights) {
                            if ($weightCount -lt 5) {  # Top 5 weights
                                $cacheText += "  o $($weight.Name): weight $([Math]::Round($weight.Value, 2))`n"
                                $weightCount++
                            }
                        }
                    } else {
                        $cacheText += "  No neural weights learned yet.`n"
                    }
                } else {
                    $cacheText += "  Brain file not found.`n"
                }
                $Script:txtCacheStatus.Text = $cacheText
                # Policz aplikacje - NAPRAWIONE z Measure-Object
                $prophetCount = 0
                $brainCount = 0
                if (Test-Path $prophetPath) {
                    try {
                        $prophetData = Get-Content $prophetPath -Raw | ConvertFrom-Json
                        if ($prophetData.Apps -and $prophetData.Apps.PSObject.Properties) {
                            $prophetCount = ($prophetData.Apps.PSObject.Properties | Measure-Object).Count
                        }
                    } catch {
                        $prophetCount = "Error"
                    }
                }
                if (Test-Path $brainPath) {
                    try {
                        $brainData = Get-Content $brainPath -Raw | ConvertFrom-Json
                        if ($brainData.Weights -and $brainData.Weights.PSObject.Properties) {
                            $brainCount = ($brainData.Weights.PSObject.Properties | Measure-Object).Count
                        }
                    } catch {
                        $brainCount = "Error"
                    }
                }
                $Script:lblCacheInfo.Text = "Prophet: $prophetCount apps | Brain: $brainCount weights"
            } catch {
                $Script:txtCacheStatus.Text = "[WARN] Error reading AI data: $($_.Exception.Message)"
            }
        } else {
            $Script:txtCacheStatus.Text = "[WARN] AI Learning file not found.`nEngine may not be fully initialized yet."
        }
    } catch {
        $Script:txtCacheStatus.Text = "- Error monitoring cache: $($_.Exception.Message)"
    }
}
function Update-PredictiveDisplay {
    try {
        $chainData = Read-ConfigFile "ChainPredictor"
        $qData = Read-ConfigFile "QLearning"
        if ($chainData -or $qData) {
            try {
                $predText = " PREDICTIVE SYSTEMS STATUS:`n`n"
                # Chain Predictor
                if ($chainData) {
                    $predText += "- CHAIN PREDICTOR:`n"
                    $currentPred = Get-SafeString -Data $chainData -Property "CurrentPrediction" -Default "None"
                    $predText += "  o Current Prediction: $currentPred`n"
                    $confidence = Get-SafeValue -Data $chainData -Property "PredictionConfidence" -Default 0
                    $predText += "  o Confidence: $([Math]::Round($confidence * 100, 1))%`n"
                    $totalPred = Get-SafeInt -Data $chainData -Property "TotalPredictions" -Default 0
                    if ($totalPred -gt 0) {
                        $correctPred = Get-SafeInt -Data $chainData -Property "CorrectPredictions" -Default 0
                        $accuracy = [Math]::Round($correctPred / $totalPred * 100, 1)
                        $predText += "  o Accuracy: $accuracy% ($correctPred/$totalPred)`n"
                    } else {
                        $predText += "  o Accuracy: No predictions yet`n"
                    }
                    $transitions = if ($chainData.TransitionGraph) { ($chainData.TransitionGraph.PSObject.Properties | Measure-Object).Count } else { 0 }
                    $predText += "  o Transitions Learned: $transitions`n`n"
                } else {
                    $predText += "- CHAIN PREDICTOR: File not found`n`n"
                }
                # Q-Learning
                if ($qData) {
                    $predText += " Q-LEARNING SYSTEM:`n"
                    $states = Get-SafeInt -Data $qData -Property "States" -Default 0
                    if ($states -eq 0 -and $qData.QTable) {
                        $states = ($qData.QTable.PSObject.Properties | Measure-Object).Count
                    }
                    $predText += "  o States learned: $states`n"
                    $episodes = Get-SafeInt -Data $qData -Property "Episodes" -Default (Get-SafeInt -Data $qData -Property "TotalUpdates" -Default 0)
                    $predText += "  o Episodes: $episodes`n"
                    $exploration = Get-SafeValue -Data $qData -Property "Epsilon" -Default (Get-SafeValue -Data $qData -Property "ExplorationRate" -Default 0)
                    $predText += "  o Exploration: $([Math]::Round($exploration * 100, 1))%`n"
                } else {
                    $predText += " Q-LEARNING: File not found`n"
                }
                $Script:txtPredictiveStatus.Text = $predText
                # Update info label
                if ($chainData) {
                    $totalPred = Get-SafeInt -Data $chainData -Property "TotalPredictions" -Default 0
                    $accuracy = if ($totalPred -gt 0) {
                        $correctPred = Get-SafeInt -Data $chainData -Property "CorrectPredictions" -Default 0
                        [Math]::Round($correctPred / $totalPred * 100, 1)
                    } else { 0 }
                    $transitions = if ($chainData.TransitionGraph) { ($chainData.TransitionGraph.PSObject.Properties | Measure-Object).Count } else { 0 }
                    $Script:lblPredictionInfo.Text = "Accuracy: $accuracy% | Transitions: $transitions"
                } else {
                    $Script:lblPredictionInfo.Text = "Chain Predictor: Not Available"
                }
            } catch {
                $Script:txtPredictiveStatus.Text = "[WARN] Error reading prediction data: $($_.Exception.Message)"
            }
        } else {
            $Script:txtPredictiveStatus.Text = "[WARN] AI Learning file not found."
        }
    } catch {
        $Script:txtPredictiveStatus.Text = "- Error monitoring predictions: $($_.Exception.Message)"
    }
}
function Update-HistoryDisplay {
    try {
        $prophetData = Read-ConfigFile "ProphetMemory"
        $contextData = Read-ConfigFile "ContextPatterns"
        if ($prophetData -or $contextData) {
            try {
                $historyText = " LEARNING PATTERNS & HISTORY:`n`n"
                # Prophet Memory - historia aplikacji
                if ($prophetData) {
                    $historyText += " PROPHET MEMORY (Application History):`n"
                    if ($prophetData.Apps -and ($prophetData.Apps.PSObject.Properties | Measure-Object).Count -gt 0) {
                        $sortedApps = $prophetData.Apps.PSObject.Properties | Sort-Object {
                            Get-SafeInt -Data $_.Value -Property "Launches" -Default 0
                        } -Descending | Select-Object -First 8
                        foreach ($app in $sortedApps) {
                            $appData = $app.Value
                            $launches = Get-SafeInt -Data $appData -Property "Launches" -Default 0
                            $avgCPU = Get-SafeValue -Data $appData -Property "AvgCPU" -Default 0
                            $historyText += "  o $($app.Name): $launches uses, Avg CPU: $([Math]::Round($avgCPU, 1))%`n"
                        }
                    } else {
                        $historyText += "  No application history yet.`n"
                    }
                } else {
                    $historyText += " PROPHET MEMORY: File not found.`n"
                }
                # Context Patterns - wzorce behawioralne
                $historyText += "`n CONTEXT PATTERNS:`n"
                if ($contextData) {
                    if ($contextData.Patterns -and ($contextData.Patterns.PSObject.Properties | Measure-Object).Count -gt 0) {
                        $patternCount = 0
                        foreach ($pattern in $contextData.Patterns.PSObject.Properties) {
                            if ($patternCount -lt 5) {
                                $count = Get-SafeInt -Data $pattern.Value -Property "Count" -Default 0
                                $historyText += "  o Pattern '$($pattern.Name)': $count occurrences`n"
                                $patternCount++
                            }
                        }
                    } else {
                        $historyText += "  No context patterns learned yet.`n"
                    }
                } else {
                    $historyText += "  Context patterns file not found.`n"
                }
                $Script:txtHistoryStatus.Text = $historyText
                # Update counts - uzywamy juz wczytanych danych
                $totalApps = 0
                $totalLaunches = 0
                if ($prophetData -and $prophetData.Apps -and $prophetData.Apps.PSObject.Properties) {
                    $totalApps = ($prophetData.Apps.PSObject.Properties | Measure-Object).Count
                    foreach ($app in $prophetData.Apps.PSObject.Properties) {
                        $totalLaunches += Get-SafeInt -Data $app.Value -Property "Launches" -Default 0
                    }
                }
                $Script:lblHistoryInfo.Text = "Apps tracked: $totalApps | Total launches: $totalLaunches"
            } catch {
                $Script:txtHistoryStatus.Text = "[WARN] Error reading history data: $($_.Exception.Message)"
            }
        } else {
            $Script:txtHistoryStatus.Text = "[WARN] AI Learning file not found."
        }
    } catch {
        $Script:txtHistoryStatus.Text = "- Error monitoring history: $($_.Exception.Message)"
    }
}
function Update-EngineDisplay {
    try {
        # Sprawdz czy engine dziala - szukaj po tytule okna lub processie ktory uruchomil engine
        $engineProcess = Get-Process | Where-Object {
            ($_.ProcessName -eq "powershell" -or $_.ProcessName -eq "pwsh") -and 
            ($_.MainWindowTitle -like "*CPU Manager*" -or $_.MainWindowTitle -like "*CPUManager*" -or
             $_.CommandLine -like "*CPUManager*ENGINE*")
        }
        # Jesli nie znaleziono, sprawdz czy sa pliki danych (engine mogl byc uruchomiony)
        # Uzywamy ProphetMemory.json bo jest aktywnie zapisywany przez ENGINE
        $prophetPath = Join-Path $Script:ConfigDir "ProphetMemory.json"
        $engineDataExists = (Test-Path $prophetPath) -and ((Get-Item $prophetPath).Length -gt 10)
        $statusText = " REAL-TIME ENGINE STATUS:`n`n"
        if ($engineProcess) {
            $statusText += " ENGINE PROCESS DETECTED`n"
            foreach ($proc in $engineProcess) {
                $statusText += "  o Process: $($proc.ProcessName) (ID: $($proc.Id))`n"
                $statusText += "  o Title: $($proc.MainWindowTitle)`n"
                $statusText += "  o Memory: $([Math]::Round($proc.WorkingSet64 / 1MB, 1)) MB`n"
                $statusText += "  o Started: $($proc.StartTime)`n"
            }
            $statusText += "`n"
            $Script:lblEngineInfo.Text = "Engine: Running (PID $($engineProcess[0].Id))"
        } elseif ($engineDataExists) {
            $statusText += "[WARN] ENGINE DATA DETECTED (Process not visible)`n"
            $statusText += "Engine may be running but not detected in process list.`n`n"
            $Script:lblEngineInfo.Text = "Engine: Data Present (Process Hidden?)"
        } else {
            $statusText += "- ENGINE NOT RUNNING`n`n"
            $Script:lblEngineInfo.Text = "Engine: Not Running"
        }
        if ($engineProcess -or $engineDataExists) {
            # Sprawdz pliki konfiguracyjne - tylko te ktore ENGINE aktywnie zapisuje
            $configFiles = @(
                @{Name="ProphetMemory.json"; Fallback="ProphetMemory"; Desc="Prophet Memory"}
                @{Name="BrainState.json"; Fallback="BrainState"; Desc="Neural Brain"}
                @{Name="QLearning.json"; Fallback="QLearning"; Desc="Q-Learning AI"}
                @{Name="NetworkAI.json"; Fallback="NetworkAI"; Desc="Network AI"}
            )
            $statusText += " CONFIG FILES STATUS:`n"
            foreach ($file in $configFiles) {
                $path = Join-Path $Script:ConfigDir $file.Name
                $fallbackPath = Join-Path $Script:ConfigDir $file.Fallback
                if (Test-Path $path) {
                    $size = [Math]::Round((Get-Item $path).Length / 1KB, 1)
                    $modified = (Get-Item $path).LastWriteTime.ToString("HH:mm:ss")
                    $statusText += "   $($file.Desc): ${size}KB (Modified: $modified)`n"
                } elseif (Test-Path $fallbackPath) {
                    $size = [Math]::Round((Get-Item $fallbackPath).Length / 1KB, 1)
                    $modified = (Get-Item $fallbackPath).LastWriteTime.ToString("HH:mm:ss")
                    $statusText += "   $($file.Desc): ${size}KB (Modified: $modified) [$($file.Fallback)]`n"
                } else {
                    # Create empty file if it doesn't exist
                    try {
                        "{}" | Set-Content -Path $path -Encoding UTF8 -Force
                        $statusText += "   $($file.Desc): 0.0KB (Created now)`n"
                    } catch {
                        $statusText += "  - $($file.Desc): Not found`n"
                    }
                }
            }
            $Script:lblEngineInfo.Text = "Engine: Running (PID $($engineProcess.Id))"
        } else {
            $statusText += "- ENGINE NOT RUNNING`n"
            $statusText += "`nTo start the engine:`n"
            $statusText += "  1. Click 'Start Engine' button above`n"
            $statusText += "  2. Or manually run CPUManager_v39.ps1`n"
            $statusText += "`nEngine features (V38.1):`n"
            $statusText += "  o Application Preload Cache (50 apps)`n"
            $statusText += "  o FastBoot Detection (auto-learns frequent apps)`n"
            $statusText += "  o Predictive Boost (AI pattern recognition)`n"
            $statusText += "  o Chain Predictor (app sequence learning)`n"
            $statusText += "  o Launch History (temporal patterns)`n"
            $statusText += "  o I/O Optimization`n"
            $Script:lblEngineInfo.Text = "Engine: Not Running"
        }
        $Script:txtEngineStatus.Text = $statusText
    } catch {
        $Script:txtEngineStatus.Text = "- Error checking engine status: $($_.Exception.Message)"
        $Script:lblEngineInfo.Text = "Engine: Error"
    }
}
#  Auto-refresh Engine Monitor co 30 sekund
$Script:EngineMonitorTimer = New-Object System.Windows.Forms.Timer
$Script:EngineMonitorTimer.Interval = 30000  # 30 sekund
$Script:EngineMonitorTimer.Add_Tick({
    if ($tabs.SelectedTab -eq $tabEngineMonitor) {
        Update-EngineDisplay
        Update-CacheDisplay
        Update-PredictiveDisplay
        Update-HistoryDisplay
    }
})
$Script:EngineMonitorTimer.Start()
#  Inicjalna aktualizacja po zaladowaniu
$tabEngineMonitor.Add_Enter({
    Update-EngineDisplay
    Update-CacheDisplay  
    Update-PredictiveDisplay
    Update-HistoryDisplay
})
# ═══════════════════════════════════════════════════════════════════════════════
$form.Add_FormClosing({
    param($sender, $e)
    if (-not $Script:ForceExit) {
        $e.Cancel = $true
        $form.Hide()
        $Script:TrayIcon.ShowBalloonTip(1000, "CPU Manager", "Running in background", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        Send-ShutdownSignal @{ Reason = "CONFIGURATOR_EXIT" }
        Save-NetworkUsage | Out-Null
        try { $Script:Timer.Stop(); $Script:Timer.Dispose() } catch {}
        try { if ($Script:BackgroundRefreshTimer) { $Script:BackgroundRefreshTimer.Stop(); $Script:BackgroundRefreshTimer.Dispose() } } catch {}
        try { if ($Script:tmrRAMTelemetry) { $Script:tmrRAMTelemetry.Stop(); $Script:tmrRAMTelemetry.Dispose() } } catch {}
        try { if ($Script:EngineMonitorTimer) { $Script:EngineMonitorTimer.Stop(); $Script:EngineMonitorTimer.Dispose() } } catch {}
        try { if ($Script:MoveSaveTimer) { $Script:MoveSaveTimer.Stop(); $Script:MoveSaveTimer.Dispose() } } catch {}
        try { $Script:TrayIcon.Visible = $false; $Script:TrayIcon.Dispose() } catch {}
    }
})
if ($Script:chkSmartPreload) { 
    $Script:chkSmartPreload.Checked = if ($null -ne $Script:Config.SmartPreload) { $Script:Config.SmartPreload } else { $true } 
}
if ($Script:chkMemoryCompression) { 
    $Script:chkMemoryCompression.Checked = if ($null -ne $Script:Config.MemoryCompression) { $Script:Config.MemoryCompression } else { $false } 
}
if ($Script:chkPowerBoost) { 
    $Script:chkPowerBoost.Checked = if ($null -ne $Script:Config.PowerBoost) { $Script:Config.PowerBoost } else { $false } 
}
if ($Script:chkPredictiveIO) { 
    $Script:chkPredictiveIO.Checked = if ($null -ne $Script:Config.PredictiveIO) { $Script:Config.PredictiveIO } else { $true } 
}
if ($Script:trackCPUAggro) { 
    $Script:trackCPUAggro.Value = if ($Script:Config.CPUAgressiveness) { $Script:Config.CPUAgressiveness } else { 50 }
}
if ($Script:trackMemoryAggro) { 
    $Script:trackMemoryAggro.Value = if ($Script:Config.MemoryAgressiveness) { $Script:Config.MemoryAgressiveness } else { 30 }
}
if ($Script:trackIOPriority) { 
    $Script:trackIOPriority.Value = if ($Script:Config.IOPriority) { $Script:Config.IOPriority } else { 3 }
}
try {
    # Performance checkboxes (pozostale)
    if ($Script:chkOptimizeVisual) { $toolTip.SetToolTip($Script:chkOptimizeVisual, "- Wylacza zaawansowane efekty wizualne i animacje. Oszczedza zasoby GPU i CPU.") }
    if ($Script:chkOptimizeInput) { $toolTip.SetToolTip($Script:chkOptimizeInput, " Zmniejsza opoznienia myszy i klawiatury. Wazne dla gier i precyzyjnej pracy.") }
    if ($Script:chkOptimizeScheduling) { $toolTip.SetToolTip($Script:chkOptimizeScheduling, " Optymalizuje priorytety procesow i separacji zadania CPU. Lepsza responsywnosc systemu.") }
    # Services checkboxes
    if ($Script:chkDisableSearchIndexer) { $toolTip.SetToolTip($Script:chkDisableSearchIndexer, "- Wylacza Windows Search Indexer. Zuzywa duzo dysku/CPU. Uzyj Everything do szybkiego wyszukiwania.") }
    if ($Script:chkDisableFax) { $toolTip.SetToolTip($Script:chkDisableFax, "- Wylacza uslugi faksu i bufor druku jesli nie uzywasz drukarek. Oszczedza RAM.") }
    if ($Script:chkDisableRemote) { $toolTip.SetToolTip($Script:chkDisableRemote, "- Wylacza zdalny dostep do rejestru i uslugi zdalne. Zwieksza bezpieczenstwo.") }
    if ($Script:chkDisableTablet) { $toolTip.SetToolTip($Script:chkDisableTablet, "- Wylacza uslugi tabletu i dotyku na komputerach stacjonarnych. Niepotrzebne na PC.") }
    if ($Script:chkDisableCompat) { $toolTip.SetToolTip($Script:chkDisableCompat, " Wylacza asystenta kompatybilnosci programow. Moze ingerowac w dzialanie gier i aplikacji.") }
    # Storage checkboxes
    if ($Script:chkCleanupLogs) { $toolTip.SetToolTip($Script:chkCleanupLogs, "- Czysci logi Windows zachowujac tylko bledy. Odzyskuje miejsce na dysku.") }
    if ($Script:chkCleanupUpdates) { $toolTip.SetToolTip($Script:chkCleanupUpdates, "- Usuwa stare instalatory Windows Update. Moze odzyskac kilka GB miejsca.") }
    if ($Script:chkRebuildCache) { $toolTip.SetToolTip($Script:chkRebuildCache, " Odbudowuje cache ikon i czcionek. Przyspiesza interfejs uzytkownika.") }
    if ($Script:chkOptimizeSSD) { $toolTip.SetToolTip($Script:chkOptimizeSSD, "- Optymalizuje SSD przez TRIM i wylaczenie defragmentacji. Wydluza zywotnosc dysku.") }
    # Cortana (jesli jeszcze nie ma tooltip)
    if ($Script:chkDisableCortana) { $toolTip.SetToolTip($Script:chkDisableCortana, "- Wylacza sledzenie Cortany i telemetrie wyszukiwania. Zapobiega wyslaniu zapytan do Microsoft.") }
} catch {
    # Ciche ignorowanie bledow tooltipow
}
if (-not (Test-Path $Script:WorkingDir)) {
    New-Item -ItemType Directory -Path $Script:WorkingDir -Force | Out-Null
}
Get-CategoryData
Update-ApplicationList
Update-LearningStats
Update-FileStatus
[System.Windows.Forms.Application]::Run($form)