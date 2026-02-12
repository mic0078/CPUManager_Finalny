# ═══════════════════════════════════════════════════════════════════
# CPU Manager AI - Widget v39 (OHM + COMMAND FILE)
# Bezpośredni odczyt z Open Hardware Monitor
# Przyciski sterują główną aplikacją przez WidgetCommand.txt
# ═══════════════════════════════════════════════════════════════════

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Ukryj konsolę
Add-Type -Name ConsoleUtils -Namespace Win32 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue
[Win32.ConsoleUtils]::ShowWindow([Win32.ConsoleUtils]::GetConsoleWindow(), 0) | Out-Null

# ═══════════════════════════════════════════════════════════════════
# === TOPMOST HELPER API ===
# ═══════════════════════════════════════════════════════════════════
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class TopMostHelper {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);
    
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
    
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOPMOST = 0x00000008;
    
    public static void ForceTopMost(IntPtr hWnd) {
        SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, 
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        int exStyle = GetWindowLong(hWnd, GWL_EXSTYLE);
        SetWindowLong(hWnd, GWL_EXSTYLE, exStyle | WS_EX_TOPMOST);
    }
    
    public static void ForceTopMostAggressive(IntPtr hWnd) {
        SetWindowPos(hWnd, HWND_NOTOPMOST, 0, 0, 0, 0, 
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, 
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        int exStyle = GetWindowLong(hWnd, GWL_EXSTYLE);
        SetWindowLong(hWnd, GWL_EXSTYLE, exStyle | WS_EX_TOPMOST);
        BringWindowToTop(hWnd);
    }
    
    public static void RemoveTopMost(IntPtr hWnd) {
        SetWindowPos(hWnd, HWND_NOTOPMOST, 0, 0, 0, 0, 
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        int exStyle = GetWindowLong(hWnd, GWL_EXSTYLE);
        SetWindowLong(hWnd, GWL_EXSTYLE, exStyle & ~WS_EX_TOPMOST);
    }
}
'@ -ErrorAction SilentlyContinue

# === AUDIO CONTROL API ===
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class AudioControl {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    
    private const byte VK_VOLUME_MUTE = 0xAD;
    private const byte VK_VOLUME_DOWN = 0xAE;
    private const byte VK_VOLUME_UP = 0xAF;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    
    public static void VolumeUp() {
        keybd_event(VK_VOLUME_UP, 0, 0, UIntPtr.Zero);
        keybd_event(VK_VOLUME_UP, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
    
    public static void VolumeDown() {
        keybd_event(VK_VOLUME_DOWN, 0, 0, UIntPtr.Zero);
        keybd_event(VK_VOLUME_DOWN, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
    
    public static void VolumeMute() {
        keybd_event(VK_VOLUME_MUTE, 0, 0, UIntPtr.Zero);
        keybd_event(VK_VOLUME_MUTE, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
'@ -ErrorAction SilentlyContinue

# === MEMORY TRIM API ===
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

public class MemoryTrimmer {
    [DllImport("psapi.dll")]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
    
    [DllImport("kernel32.dll")]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);
    
    private const uint PROCESS_SET_QUOTA = 0x0100;
    private const uint PROCESS_QUERY_INFORMATION = 0x0400;
    
    public static int TrimAllProcesses() {
        int count = 0;
        foreach (Process p in Process.GetProcesses()) {
            try {
                IntPtr handle = OpenProcess(PROCESS_SET_QUOTA | PROCESS_QUERY_INFORMATION, false, p.Id);
                if (handle != IntPtr.Zero) {
                    if (EmptyWorkingSet(handle)) count++;
                    CloseHandle(handle);
                }
            } catch { }
        }
        return count;
    }
}
'@ -ErrorAction SilentlyContinue

# Konfigurowalne katalogi i ścieżki (użyj $Script:ConfigDir jeśli dostępne)
if (-not $Script:ConfigDir) { $Script:ConfigDir = "C:\CPUManager" }
if (-not (Test-Path $Script:ConfigDir)) { New-Item -Path $Script:ConfigDir -ItemType Directory -Force | Out-Null }

$Script:DataFile = Join-Path $Script:ConfigDir 'WidgetData.json'
$Script:SettingsFile = Join-Path $Script:ConfigDir 'WidgetSettings.json'
$Script:CommandFile = Join-Path $Script:ConfigDir 'WidgetCommand.txt'
$Script:NetworkStatsFile = Join-Path $Script:ConfigDir 'NetworkStats.json'
$Script:PidFile = Join-Path $Script:ConfigDir 'Widget.pid'

$PID | Set-Content -Path $Script:PidFile -Force

# ═══════════════════════════════════════════════════════════════════
# === OPEN HARDWARE MONITOR - WMI DATA READER ===
# ═══════════════════════════════════════════════════════════════════
$Script:OHM_Available = $false
$Script:OHM_LastCheck = [DateTime]::MinValue
$Script:OHM_CheckInterval = 5

function Test-OHMAvailable {
    try {
        $test = Get-WmiObject -Namespace "root\OpenHardwareMonitor" -Class Sensor -ErrorAction Stop | Select-Object -First 1
        return ($null -ne $test)
    } catch {
        return $false
    }
}

function Get-OHMData {
    $now = [DateTime]::Now
    if (($now - $Script:OHM_LastCheck).TotalSeconds -ge $Script:OHM_CheckInterval) {
        $Script:OHM_Available = Test-OHMAvailable
        $Script:OHM_LastCheck = $now
    }
    
    if (-not $Script:OHM_Available) {
        return $null
    }
    
    try {
        $sensors = Get-WmiObject -Namespace "root\OpenHardwareMonitor" -Class Sensor -ErrorAction Stop
        
        $data = @{
            CPULoad = 0
            CPUTemp = 0
            CPUClock = 0
            CPUPower = 0
            GPULoad = 0
            GPUTemp = 0
            GPUClock = 0
            GPUMemLoad = 0
        }
        
        foreach ($sensor in $sensors) {
            $name = $sensor.Name
            $value = [math]::Round($sensor.Value, 1)
            $type = $sensor.SensorType
            $parent = $sensor.Parent
            $identifier = $sensor.Identifier
            
            # === CPU ===
            if ($identifier -like "*/cpu/*" -or $parent -like "*cpu*") {
                switch ($type) {
                    "Load" {
                        if ($name -eq "CPU Total" -or $name -like "*Total*") {
                            $data.CPULoad = [int]$value
                        }
                    }
                    "Temperature" {
                        if ($name -like "*Package*" -or $name -like "*CPU*" -or $name -like "*Core*") {
                            if ($value -gt $data.CPUTemp) {
                                $data.CPUTemp = [int]$value
                            }
                        }
                    }
                    "Clock" {
                        if ($name -like "*Core #1*" -or ($name -like "*Core*" -and $data.CPUClock -eq 0)) {
                            $data.CPUClock = [int]$value
                        }
                    }
                    "Power" {
                        if ($name -like "*Package*" -or $name -like "*CPU*") {
                            $data.CPUPower = [int]$value
                        }
                    }
                }
            }
            
            # === GPU (NVIDIA / AMD / Intel) ===
            if ($identifier -like "*/gpu/*" -or $identifier -like "*/nvidiagpu/*" -or $identifier -like "*/atigpu/*" -or $identifier -like "*/intelgpu/*") {
                switch ($type) {
                    "Load" {
                        if ($name -like "*GPU Core*" -or $name -eq "GPU Core") {
                            $data.GPULoad = [int]$value
                        }
                        elseif ($name -like "*GPU Memory*" -or $name -like "*Memory Controller*") {
                            $data.GPUMemLoad = [int]$value
                        }
                    }
                    "Temperature" {
                        if ($name -like "*GPU Core*" -or $name -eq "GPU Core" -or $name -like "*GPU*") {
                            if ($value -gt $data.GPUTemp) {
                                $data.GPUTemp = [int]$value
                            }
                        }
                    }
                    "Clock" {
                        if ($name -like "*GPU Core*" -or $name -eq "GPU Core") {
                            $data.GPUClock = [int]$value
                        }
                    }
                }
            }
        }
        
        return $data
        
    } catch {
        $Script:OHM_Available = $false
        return $null
    }
}

# ═══════════════════════════════════════════════════════════════════
# === DISK I/O - PERFORMANCE COUNTERS ===
# ═══════════════════════════════════════════════════════════════════
$Script:LastDiskRead = 0
$Script:LastDiskWrite = 0
$Script:DiskReadActiveUntil = [DateTime]::MinValue
$Script:DiskWriteActiveUntil = [DateTime]::MinValue
$Script:ReadLedBlinkState = $false
$Script:WriteLedBlinkState = $false

try {
    $Script:perfDiskRead = New-Object System.Diagnostics.PerformanceCounter("PhysicalDisk", "Disk Read Bytes/sec", "_Total")
    $Script:perfDiskWrite = New-Object System.Diagnostics.PerformanceCounter("PhysicalDisk", "Disk Write Bytes/sec", "_Total")
    $null = $Script:perfDiskRead.NextValue()
    $null = $Script:perfDiskWrite.NextValue()
} catch {
    Write-Host "Błąd inicjalizacji liczników dysku: $_"
}

# === NETWORK USAGE TRACKING (SYNC WITH MAIN SCRIPT) ===
$Script:TotalDownload = 0
$Script:TotalUpload = 0
$Script:LastSaveTime = Get-Date
$Script:SaveInterval = 10
$Script:LastFileModTime = [DateTime]::MinValue

# === NETWORK REALTIME USAGE (Get-NetAdapterStatistics) ===
$Script:LastNetDL = 0
$Script:LastNetUL = 0
$Script:_PrevNetStats = $null

function Load-NetworkUsage {
    # Wczytaj ze wspólnego pliku NetworkStats.json
    if (Test-Path $Script:NetworkStatsFile) {
        try {
            $json = [System.IO.File]::ReadAllText($Script:NetworkStatsFile)
            $data = $json | ConvertFrom-Json
            $Script:TotalDownload = if ($data.TotalDownloaded -ne $null) { [long]$data.TotalDownloaded } elseif ($data.TotalDownload -ne $null) { [long]$data.TotalDownload } elseif ($data.TotalDL -ne $null) { [long]$data.TotalDL } else { 0 }
            $Script:TotalUpload = if ($data.TotalUploaded -ne $null) { [long]$data.TotalUploaded } elseif ($data.TotalUpload -ne $null) { [long]$data.TotalUpload } elseif ($data.TotalUL -ne $null) { [long]$data.TotalUL } else { 0 }
            $Script:LastFileModTime = (Get-Item $Script:NetworkStatsFile).LastWriteTime
        } catch {
            $Script:TotalDownload = 0
            $Script:TotalUpload = 0
        }
    }
}

function Sync-NetworkUsage {
    # Sprawdź czy główny skrypt zaktualizował plik
    if (Test-Path $Script:NetworkStatsFile) {
        try {
            $fileModTime = (Get-Item $Script:NetworkStatsFile).LastWriteTime
            if ($fileModTime -gt $Script:LastFileModTime) {
                # Plik został zmieniony przez główny skrypt - wczytaj nowsze dane
                $json = [System.IO.File]::ReadAllText($Script:NetworkStatsFile)
                $data = $json | ConvertFrom-Json
                $fileDL = if ($data.TotalDownloaded -ne $null) { [long]$data.TotalDownloaded } elseif ($data.TotalDownload -ne $null) { [long]$data.TotalDownload } elseif ($data.TotalDL -ne $null) { [long]$data.TotalDL } else { 0 }
                $fileUL = if ($data.TotalUploaded -ne $null) { [long]$data.TotalUploaded } elseif ($data.TotalUpload -ne $null) { [long]$data.TotalUpload } elseif ($data.TotalUL -ne $null) { [long]$data.TotalUL } else { 0 }
                
                # Użyj większej wartości (główny skrypt mógł dodać więcej)
                if ($fileDL -gt $Script:TotalDownload) { $Script:TotalDownload = $fileDL }
                if ($fileUL -gt $Script:TotalUpload) { $Script:TotalUpload = $fileUL }
                
                $Script:LastFileModTime = $fileModTime
            }
        } catch { }
    }
}

function Save-NetworkUsage {
    # Najpierw zsynchronizuj z głównym skryptem
    Sync-NetworkUsage
    
    try {
        # Uwaga: widget nie powinien nadpisywać głównego pliku NetworkStats.json
        # (to zadanie głównego procesu). Zapisujemy lokalną kopię/backup tylko
        # dla widżetu, żeby nie nadpisać authoritative totals.
        $backup = Join-Path $Script:BaseDir 'NetworkStats.Widget.json'
        @{ 
            TotalDownloaded = $Script:TotalDownload
            TotalUploaded = $Script:TotalUpload
            LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Source = "Widget-Local"
            TotalDownloadGB = [Math]::Round($Script:TotalDownload / 1GB, 2)
            TotalUploadGB = [Math]::Round($Script:TotalUpload / 1GB, 2)
        } | ConvertTo-Json | Set-Content $backup -Force
        $Script:LastFileModTime = (Get-Item $backup).LastWriteTime
    } catch {}
}

function Reset-NetworkUsage {
    $Script:TotalDownload = 0
    $Script:TotalUpload = 0
    Save-NetworkUsage
}

function Format-TotalBytes($bytes) {
    if ($bytes -ge 1TB) { return "{0:N2} TB" -f ($bytes/1TB) }
    elseif ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes/1GB) }
    elseif ($bytes -ge 1MB) { return "{0:N1} MB" -f ($bytes/1MB) }
    elseif ($bytes -ge 1KB) { return "{0:N0} KB" -f ($bytes/1KB) }
    else { return "{0:N0} B" -f $bytes }
}

Load-NetworkUsage

# === USTAWIENIA ===
$script:widgetOpacity = 0.95
$script:isTopMost = $false
$Script:LastLeft = -1
$Script:LastTop = -1
$Script:LastMode = "BIG"
$Script:TopMostCycleCounter = 0

if (Test-Path $Script:SettingsFile) {
    try {
        $json = [System.IO.File]::ReadAllText($Script:SettingsFile)
        $s = $json | ConvertFrom-Json
        if ($null -ne $s.Opacity) { $script:widgetOpacity = $s.Opacity }
        if ($null -ne $s.TopMost) { $script:isTopMost = $s.TopMost }
        if ($null -ne $s.Left) { $Script:LastLeft = $s.Left }
        if ($null -ne $s.Top) { $Script:LastTop = $s.Top }
        if ($null -ne $s.Mode) { $Script:LastMode = $s.Mode }
    } catch { }
}

$Script:CurrentMode = $Script:LastMode

function Save-Settings {
    @{
        Opacity = $script:widgetOpacity
        TopMost = $script:isTopMost
        Left = $form.Left
        Top = $form.Top
        Mode = $Script:CurrentMode
    } | ConvertTo-Json | Set-Content $Script:SettingsFile -Force
}

# ═══════════════════════════════════════════════════════════════════
# === FUNKCJA WYMUSZANIA TOPMOST ===
# ═══════════════════════════════════════════════════════════════════
function Force-WidgetTopMost {
    if ($script:isTopMost -and $form -and $form.Visible -and $form.Handle -ne [IntPtr]::Zero) {
        try {
            $Script:TopMostCycleCounter++
            if ($Script:TopMostCycleCounter -ge 5) {
                [TopMostHelper]::ForceTopMostAggressive($form.Handle)
                $Script:TopMostCycleCounter = 0
            } else {
                [TopMostHelper]::ForceTopMost($form.Handle)
            }
        } catch {}
    }
}

# === FUNKCJA ZMIANY TRYBU WIDGETU ===
function Set-WidgetMode {
    param([string]$Mode)
    
    if ($Mode -eq $Script:CurrentMode) { return }
    
    $Script:CurrentMode = $Mode
    
    $HEIGHT_DIFFERENCE = $Script:BigSize.Height - $Script:SmallSize.Height
    $GLOBAL_SHIFT = 170 
    
    if ($Mode -eq "BIG") {
        $form.Top = $form.Top - $HEIGHT_DIFFERENCE
    } else { 
        $form.Top = $form.Top + $HEIGHT_DIFFERENCE
    }
    
    $isBig = $Mode -eq "BIG"
    $shift = if ($isBig) { 0 } else { $GLOBAL_SHIFT }
    
    if ($isBig) {
        $btnModeToggle.Text = "MINI"
        $btnModeToggle.ForeColor = [System.Drawing.Color]::FromArgb(150, 200, 255)
    } else {
        $btnModeToggle.Text = "MAXI"
        $btnModeToggle.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 80)
    }
    
    $lblCpu.Visible = $isBig
    $lblGpu.Visible = $isBig
    $lblMode.Visible = $isBig
    $lblRam.Visible = $isBig
    $lblNet.Visible = $isBig
    $lblCtx.Visible = $isBig
    $lblApp.Visible = $isBig
    $sep0.Visible = $isBig
    
    # Hide the static "VOLUME" label to avoid covering the volume buttons
    $lblVolume.Visible = $false
    $btnVolDown.Visible = $true
    $btnVolUp.Visible = $true
    $btnMute.Visible = $true
    $btnTrimRam.Visible = $true
    $btnWeather.Visible = $true
    
    $lblVolume.Location = New-Object System.Drawing.Point(10, (200 - $shift))
    $btnVolDown.Location = New-Object System.Drawing.Point(10, (218 - $shift))
    $btnVolUp.Location = New-Object System.Drawing.Point(50, (218 - $shift))
    $btnMute.Location = New-Object System.Drawing.Point(90, (218 - $shift))
    $btnTrimRam.Location = New-Object System.Drawing.Point(150, (218 - $shift))
    $btnWeather.Location = New-Object System.Drawing.Point(220, (218 - $shift))

    $sep1.Visible = $true
    $lblProf.Visible = $true
    $btnSilent.Visible = $true
    $btnBalanced.Visible = $true
    $btnTurbo.Visible = $true
    $btnAI.Visible = $true
    
    $sep1.Location = New-Object System.Drawing.Point(10, (255 - $shift))
    $lblProf.Location = New-Object System.Drawing.Point(10, (262 - $shift))
    $btnSilent.Location = New-Object System.Drawing.Point(10, (280 - $shift))
    $btnBalanced.Location = New-Object System.Drawing.Point(80, (280 - $shift))
    $btnTurbo.Location = New-Object System.Drawing.Point(165, (280 - $shift))
    $btnAI.Location = New-Object System.Drawing.Point(235, (280 - $shift))
    
    $sep2.Visible = $true
    $sep2.Location = New-Object System.Drawing.Point(10, (315 - $shift))
    
    $lblTime.Visible = $true
    $lblDate.Visible = $true
    $lblTime.Location = New-Object System.Drawing.Point(10, (325 - $shift))
    $lblDate.Location = New-Object System.Drawing.Point(10, (352 - $shift))

    $lblTotalNet.Visible = $true
    $lblTotalDL.Visible = $true
    $lblTotalUL.Visible = $true
    $btnNetToggle.Visible = $true
    $btnResetNet.Visible = $true
    $lblTotalNet.Location = New-Object System.Drawing.Point(140, (320 - $shift))
    $lblTotalDL.Location = New-Object System.Drawing.Point(140, (334 - $shift))
    $lblTotalUL.Location = New-Object System.Drawing.Point(140, (350 - $shift))
    $btnNetToggle.Location = New-Object System.Drawing.Point(216, (405 - $shift))
    $btnResetNet.Location = New-Object System.Drawing.Point(266, (405 - $shift))

    $lblOpacity.Visible = $true
    $lblOpVal.Visible = $true
    $btnOpMinus.Visible = $true
    $btnOpPlus.Visible = $true
    $lblTopMost.Visible = $true
    $btnTopMostToggle.Visible = $true
    $lblOpacity.Location = New-Object System.Drawing.Point(10, (378 - $shift))
    $lblOpVal.Location = New-Object System.Drawing.Point(65, (378 - $shift))
    $btnOpMinus.Location = New-Object System.Drawing.Point(105, (375 - $shift))
    $btnOpPlus.Location = New-Object System.Drawing.Point(140, (375 - $shift))
    $lblTopMost.Location = New-Object System.Drawing.Point(210, (378 - $shift))
    $btnTopMostToggle.Location = New-Object System.Drawing.Point(268, (375 - $shift))
    
    $bottomLine.Location = New-Object System.Drawing.Point(0, (400 - $shift))
    
    $form.Size = if ($isBig) { $Script:BigSize } else { $Script:SmallSize }
    
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($Script:LastLeft -lt 0 -or $Script:LastTop -lt 0) {
        $form.Location = if ($isBig) { 
            New-Object System.Drawing.Point(10, ($scr.Height - $Script:BigSize.Height - 10)) 
        } else {
            New-Object System.Drawing.Point(10, ($scr.Height - $Script:SmallSize.Height - 10))
        }
    }
    
    Save-Settings
    Force-WidgetTopMost
}

# === GŁÓWNE OKNO ===
$form = New-Object System.Windows.Forms.Form
$form.Text = "CPU Widget v39"
$form.FormBorderStyle = 'None'
$form.BackColor = [System.Drawing.Color]::FromArgb(20, 22, 28)
$form.TopMost = $script:isTopMost
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.Opacity = $script:widgetOpacity

$script:drag = $false
$script:dragX = 0
$script:dragY = 0

$Script:BigSize = New-Object System.Drawing.Size(300, 430)
$Script:SmallSize = New-Object System.Drawing.Size(300, 240)

if ($Script:CurrentMode -eq "SMALL") {
    $form.Size = $Script:SmallSize
} else {
    $form.Size = $Script:BigSize
}

$scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($Script:LastLeft -ge 0 -and $Script:LastTop -ge 0) {
    $form.Location = New-Object System.Drawing.Point($Script:LastLeft, $Script:LastTop)
} else {
    if ($Script:CurrentMode -eq "SMALL") {
        $form.Location = New-Object System.Drawing.Point(10, ($scr.Height - $Script:SmallSize.Height - 10))
    } else {
        $form.Location = New-Object System.Drawing.Point(10, ($scr.Height - $Script:BigSize.Height - 10))
    }
}

# === OBSŁUGA ZDARZEŃ OKNA DLA TOPMOST ===
$form.Add_Shown({
    if ($script:isTopMost) {
        Start-Sleep -Milliseconds 100
        Force-WidgetTopMost
    }
})

$form.Add_Activated({ Force-WidgetTopMost })

$form.Add_Deactivate({
    if ($script:isTopMost) {
        [System.Windows.Forms.Application]::DoEvents()
        Force-WidgetTopMost
    }
})

$form.Add_VisibleChanged({
    if ($form.Visible -and $script:isTopMost) {
        Force-WidgetTopMost
    }
})

# === TRAY ICON ===
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = "CPU Widget v39"
$tray.Visible = $true

$bmp = New-Object System.Drawing.Bitmap(16, 16)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.Clear([System.Drawing.Color]::FromArgb(30, 120, 220))
$g.DrawString("W", (New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, 1, 0)
$g.Dispose()
$tray.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

# === FUNKCJE POMOCNICZE DLA KONSOLI GLOWNEGO PROGRAMU ===
function Show-MainConsole {
    try {
        $cmdFile = $Script:CommandFile
        [System.IO.File]::WriteAllText($cmdFile, "SHOW_CONSOLE")
    } catch {
        "SHOW_CONSOLE" | Out-File $Script:CommandFile -Force -Encoding ascii
    }
}
function Hide-MainConsole {
    try {
        $cmdFile = $Script:CommandFile
        [System.IO.File]::WriteAllText($cmdFile, "HIDE_CONSOLE")
    } catch {
        "HIDE_CONSOLE" | Out-File $Script:CommandFile -Force -Encoding ascii
    }
}

function Update-TopMostButtons {
    if ($script:isTopMost) {
        $btnTopMostToggle.BackColor = [System.Drawing.Color]::FromArgb(40, 60, 40)
        $btnTopMostToggle.ForeColor = [System.Drawing.Color]::FromArgb(100, 255, 100)
        $tooltip.SetToolTip($btnTopMostToggle, "Zawsze na wierzchu: WŁĄCZONE")
    } else {
        $btnTopMostToggle.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 50)
        $btnTopMostToggle.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 160)
        $tooltip.SetToolTip($btnTopMostToggle, "Zawsze na wierzchu: WYŁĄCZONE")
    }
}

function Toggle-TopMost {
    $script:isTopMost = -not $script:isTopMost
    $form.TopMost = $script:isTopMost
    $miTopMost.Checked = $script:isTopMost
    
    if ($script:isTopMost) {
        [TopMostHelper]::ForceTopMostAggressive($form.Handle)
    } else {
        [TopMostHelper]::RemoveTopMost($form.Handle)
    }
    
    Update-TopMostButtons
    Save-Settings
}

# Funkcja pomocnicza do włączania/wyłączania adapterów sieciowych z potwierdzeniem
function Set-NetworkStateGlobal {
    param([string]$State)
    $msg = if ($State -eq 'Enable') { 'Czy na pewno chcesz WŁĄCZYĆ internet?' } else { 'Czy na pewno chcesz WYŁĄCZYĆ internet?' }
    $res = [System.Windows.Forms.MessageBox]::Show($msg, 'Potwierdź', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($res -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        if ($State -eq 'Enable') {
            Get-NetAdapter | Enable-NetAdapter -Confirm:$false -ErrorAction Stop
            [System.Windows.Forms.MessageBox]::Show('Wszystkie karty sieciowe zostały włączone.', 'Sukces')
        } else {
            Get-NetAdapter | Disable-NetAdapter -Confirm:$false -ErrorAction Stop
            [System.Windows.Forms.MessageBox]::Show('Wszystkie karty sieciowe zostały wyłączone.', 'Sukces')
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show('Błąd! Uruchom skrypt jako Administrator lub sprawdź uprawnienia.', 'Błąd')
    }
}

$miShow = New-Object System.Windows.Forms.ToolStripMenuItem
$miShow.Text = "Pokaż Widget"
$miShow.Add_Click({ 
    $form.Show()
    $form.WindowState = 'Normal'
    Force-WidgetTopMost
})
$trayMenu.Items.Add($miShow)

$miHide = New-Object System.Windows.Forms.ToolStripMenuItem
$miHide.Text = "Ukryj Widget"
$miHide.Add_Click({ $form.Hide() })
$trayMenu.Items.Add($miHide)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# --- Internet control in tray menu ---
$miNetEnable = New-Object System.Windows.Forms.ToolStripMenuItem
$miNetEnable.Text = "Włącz internet"
$miNetEnable.Add_Click({ Set-NetworkStateGlobal -State 'Enable' })
$trayMenu.Items.Add($miNetEnable)

$miNetDisable = New-Object System.Windows.Forms.ToolStripMenuItem
$miNetDisable.Text = "Wyłącz internet"
$miNetDisable.Add_Click({ Set-NetworkStateGlobal -State 'Disable' })
$trayMenu.Items.Add($miNetDisable)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miTopMost = New-Object System.Windows.Forms.ToolStripMenuItem
$miTopMost.Text = "Zawsze na wierzchu (FORCE)"
$miTopMost.CheckOnClick = $true
$miTopMost.Checked = $script:isTopMost
$miTopMost.Add_Click({ Toggle-TopMost })
$trayMenu.Items.Add($miTopMost)

$miForceNow = New-Object System.Windows.Forms.ToolStripMenuItem
$miForceNow.Text = "Wymuś na wierzch TERAZ"
$miForceNow.Add_Click({ 
    [TopMostHelper]::ForceTopMostAggressive($form.Handle)
})
$trayMenu.Items.Add($miForceNow)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem
$miExit.Text = "Zamknij Widget"
$miExit.Add_Click({ Save-NetworkUsage; $tray.Visible = $false; $form.Close() })
$trayMenu.Items.Add($miExit)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# === KONSOLA GŁÓWNEGO PROGRAMU ===
$miConsole = New-Object System.Windows.Forms.ToolStripMenuItem
$miConsole.Text = "Konsola CPUManager"

$miShowConsole = New-Object System.Windows.Forms.ToolStripMenuItem
$miShowConsole.Text = "Pokaż konsolę"
$miShowConsole.Add_Click({ Show-MainConsole })
$miConsole.DropDownItems.Add($miShowConsole)

$miHideConsole = New-Object System.Windows.Forms.ToolStripMenuItem
$miHideConsole.Text = "Ukryj konsolę"
$miHideConsole.Add_Click({ Hide-MainConsole })
$miConsole.DropDownItems.Add($miHideConsole)

$trayMenu.Items.Add($miConsole)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# === TRYBY PRACY ===
$miModes = New-Object System.Windows.Forms.ToolStripMenuItem
$miModes.Text = "Tryb pracy"

$miSilent = New-Object System.Windows.Forms.ToolStripMenuItem
$miSilent.Text = "Silent (auto-switch)"
$miSilent.Add_Click({ "SILENT" | Set-Content -Path $Script:CommandFile -Force })
$miModes.DropDownItems.Add($miSilent)

$miSilentLock = New-Object System.Windows.Forms.ToolStripMenuItem
$miSilentLock.Text = "Silent LOCK (totalna cisza)"
$miSilentLock.Add_Click({ "SILENT_LOCK" | Set-Content -Path $Script:CommandFile -Force })
$miModes.DropDownItems.Add($miSilentLock)

$miBal = New-Object System.Windows.Forms.ToolStripMenuItem
$miBal.Text = "Balanced (zrównoważony)"
$miBal.Add_Click({ "BALANCED" | Set-Content -Path $Script:CommandFile -Force })
$miModes.DropDownItems.Add($miBal)

$miTurbo = New-Object System.Windows.Forms.ToolStripMenuItem
$miTurbo.Text = "Turbo (wydajność)"
$miTurbo.Add_Click({ "TURBO" | Set-Content -Path $Script:CommandFile -Force })
$miModes.DropDownItems.Add($miTurbo)

$miExtreme = New-Object System.Windows.Forms.ToolStripMenuItem
$miExtreme.Text = "Extreme (max)"
$miExtreme.Add_Click({ "EXTREME" | Set-Content -Path $Script:CommandFile -Force })
$miModes.DropDownItems.Add($miExtreme)

$miModes.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miAI = New-Object System.Windows.Forms.ToolStripMenuItem
$miAI.Text = "Toggle AI"
$miAI.Add_Click({ "AI" | Set-Content -Path $Script:CommandFile -Force })
$miModes.DropDownItems.Add($miAI)

$trayMenu.Items.Add($miModes)



# === PROCESOR ===
$script:CPUTypeWidget = "AMD"
$cpuConfigPath = "C:\CPUManager\CPUConfig.json"
if (Test-Path $cpuConfigPath) {
    try { $cfg = Get-Content $cpuConfigPath -Raw | ConvertFrom-Json; if ($cfg.CPUType) { $script:CPUTypeWidget = $cfg.CPUType } } catch {}
}

$miProc = New-Object System.Windows.Forms.ToolStripMenuItem
$miProc.Text = "Procesor [$($script:CPUTypeWidget)]"

$miAMD = New-Object System.Windows.Forms.ToolStripMenuItem
$miAMD.Text = "AMD Ryzen"
$miAMD.Checked = ($script:CPUTypeWidget -eq "AMD")
$miAMD.Add_Click({ 
    $script:CPUTypeWidget = "AMD"
    @{CPUType="AMD"} | ConvertTo-Json | Set-Content "C:\CPUManager\CPUConfig.json" -Force
    "CPU_AMD" | Set-Content -Path $Script:CommandFile -Force -Encoding ASCII
    $miAMD.Checked = $true; $miIntel.Checked = $false
    $miProc.Text = "Procesor [AMD]"
})
$miProc.DropDownItems.Add($miAMD)

$miIntel = New-Object System.Windows.Forms.ToolStripMenuItem
$miIntel.Text = "Intel Core"
$miIntel.Checked = ($script:CPUTypeWidget -eq "Intel")
$miIntel.Add_Click({ 
    $script:CPUTypeWidget = "Intel"
    @{CPUType="Intel"} | ConvertTo-Json | Set-Content "C:\CPUManager\CPUConfig.json" -Force
    "CPU_INTEL" | Set-Content -Path $Script:CommandFile -Force -Encoding ASCII
    $miIntel.Checked = $true; $miAMD.Checked = $false
    $miProc.Text = "Procesor [Intel]"
})
$miProc.DropDownItems.Add($miIntel)

$trayMenu.Items.Add($miProc)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# === SILNIKI AI ===
$miEngines = New-Object System.Windows.Forms.ToolStripMenuItem
$miEngines.Text = "Silniki AI"

$miEnableCore = New-Object System.Windows.Forms.ToolStripMenuItem
$miEnableCore.Text = "Wlacz CORE (zalecane)"
$miEnableCore.Add_Click({
    $core = @{ QLearning=$true; Ensemble=$false; Prophet=$true; NeuralBrain=$false; AnomalyDetector=$true; SelfTuner=$true; ChainPredictor=$true; LoadPredictor=$true }
    $core | ConvertTo-Json | Set-Content "C:\CPUManager\AIEngines.json" -Force
})
$miEngines.DropDownItems.Add($miEnableCore)

$miEnableAllEngines = New-Object System.Windows.Forms.ToolStripMenuItem
$miEnableAllEngines.Text = "Wlacz WSZYSTKIE"
$miEnableAllEngines.Add_Click({
    $all = @{ QLearning=$true; Ensemble=$true; Prophet=$true; NeuralBrain=$true; AnomalyDetector=$true; SelfTuner=$true; ChainPredictor=$true; LoadPredictor=$true }
    $all | ConvertTo-Json | Set-Content "C:\CPUManager\AIEngines.json" -Force
})
$miEngines.DropDownItems.Add($miEnableAllEngines)

$miDisableAllEngines = New-Object System.Windows.Forms.ToolStripMenuItem
$miDisableAllEngines.Text = "Wylacz WSZYSTKIE"
$miDisableAllEngines.Add_Click({
    $off = @{ QLearning=$false; Ensemble=$false; Prophet=$false; NeuralBrain=$false; AnomalyDetector=$false; SelfTuner=$false; ChainPredictor=$false; LoadPredictor=$false }
    $off | ConvertTo-Json | Set-Content "C:\CPUManager\AIEngines.json" -Force
})
$miEngines.DropDownItems.Add($miDisableAllEngines)

$trayMenu.Items.Add($miEngines)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# === URUCHOM KOMPONENTY ===
$miComponents = New-Object System.Windows.Forms.ToolStripMenuItem
$miComponents.Text = "Uruchom komponenty"

$miMiniWidget = New-Object System.Windows.Forms.ToolStripMenuItem
$miMiniWidget.Text = "Mini Widget"
$miMiniWidget.Add_Click({ 
    $mw = "C:\CPUManager\MiniWidget_v39.ps1"
    if (Test-Path $mw) { Start-Process pwsh.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$mw -WindowStyle Hidden }
})
$miComponents.DropDownItems.Add($miMiniWidget)

$miConfig = New-Object System.Windows.Forms.ToolStripMenuItem
$miConfig.Text = "Konfigurator"
$miConfig.Add_Click({ 
    $cfg = "C:\CPUManager\CPUManager_Configurator_v39.ps1"
    if (Test-Path $cfg) { Start-Process pwsh.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$cfg -WindowStyle Hidden }
})
$miComponents.DropDownItems.Add($miConfig)

$miComponents.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miDatabase = New-Object System.Windows.Forms.ToolStripMenuItem
$miDatabase.Text = "🗃️ Baza Danych (Prophet)"
$miDatabase.Add_Click({ 
    # Utwórz sygnał dla konfiguratora aby otworzył zakładkę Baza Danych
    @{ OpenTab = "BazaDanych"; Timestamp = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content "C:\CPUManager\ConfiguratorSignal.json" -Force
    $cfg = "C:\CPUManager\CPUManager_Configurator_v39.ps1"
    if (Test-Path $cfg) { Start-Process pwsh.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$cfg -WindowStyle Hidden }
})
$miComponents.DropDownItems.Add($miDatabase)

# === DASHBOARD WEB ===
$miDashboard = New-Object System.Windows.Forms.ToolStripMenuItem
$miDashboard.Text = "📊 Dashboard Web"
$miDashboard.Add_Click({ Start-Process "http://localhost:8080" })
$miComponents.DropDownItems.Add($miDashboard)

$trayMenu.Items.Add($miComponents)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# === INSTRUKCJA ===
$miHelp = New-Object System.Windows.Forms.ToolStripMenuItem
$miHelp.Text = "Instrukcja"
$miHelp.Add_Click({ 
    $helpPath = "C:\CPUManager\INSTRUKCJA.txt"
    if (Test-Path $helpPath) { Start-Process notepad.exe -ArgumentList $helpPath }
})
$trayMenu.Items.Add($miHelp)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# === KILL ALL ===
$miKillAll = New-Object System.Windows.Forms.ToolStripMenuItem
$miKillAll.Text = "☠ KILL ALL"
$miKillAll.BackColor = [System.Drawing.Color]::FromArgb(100, 30, 30)
$miKillAll.ForeColor = [System.Drawing.Color]::Red
$miKillAll.Add_Click({
    Get-Process -Name pwsh, powershell -ErrorAction SilentlyContinue | Where-Object {
        $_.Id -ne $PID -and ($_.MainWindowTitle -match "CPUManager|Widget" -or $_.CommandLine -match "CPUManager|Widget|MiniWidget")
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    $tray.Visible = $false
    $form.Close()
})
$trayMenu.Items.Add($miKillAll)

$tray.ContextMenuStrip = $trayMenu
$tray.Add_MouseClick({
    if ($_.Button -eq 'Left') { 
        $form.Visible = -not $form.Visible 
        if ($form.Visible) {
            Force-WidgetTopMost
        }
    }
})

# === KONTROLKI UI ===

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "CPU Manager AI"
$lblTitle.ForeColor = [System.Drawing.Color]::DodgerBlue
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object System.Drawing.Point(10, 8)
$lblTitle.Size = New-Object System.Drawing.Size(170, 22)

# DIODA ODCZYTU - ZIELONA
$lblDiskReadLED = New-Object System.Windows.Forms.Label
$lblDiskReadLED.Text = "●"
$lblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$lblDiskReadLED.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$lblDiskReadLED.Location = New-Object System.Drawing.Point(182, 2)
$lblDiskReadLED.Size = New-Object System.Drawing.Size(14, 14)
$lblDiskReadLED.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

# DIODA ZAPISU - BURSZTYNOWA
$lblDiskWriteLED = New-Object System.Windows.Forms.Label
$lblDiskWriteLED.Text = "●"
$lblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$lblDiskWriteLED.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$lblDiskWriteLED.Location = New-Object System.Drawing.Point(182, 15)
$lblDiskWriteLED.Size = New-Object System.Drawing.Size(14, 14)
$lblDiskWriteLED.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "X"
$btnClose.Size = New-Object System.Drawing.Size(24, 24)
$btnClose.Location = New-Object System.Drawing.Point(268, 5)
$btnClose.FlatStyle = 'Flat'
$btnClose.FlatAppearance.BorderSize = 0
$btnClose.BackColor = [System.Drawing.Color]::FromArgb(150, 40, 40)
$btnClose.ForeColor = [System.Drawing.Color]::White
$btnClose.Add_Click({ Save-NetworkUsage; $tray.Visible = $false; $form.Close() })

$btnMin = New-Object System.Windows.Forms.Button
$btnMin.Text = "_"
$btnMin.Size = New-Object System.Drawing.Size(24, 24)
$btnMin.Location = New-Object System.Drawing.Point(242, 5)
$btnMin.FlatStyle = 'Flat'
$btnMin.FlatAppearance.BorderSize = 0
$btnMin.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$btnMin.ForeColor = [System.Drawing.Color]::White
$btnMin.Add_Click({ $form.Hide() })

$btnModeToggle = New-Object System.Windows.Forms.Button
$btnModeToggle.Text = "MINI"
$btnModeToggle.Size = New-Object System.Drawing.Size(38, 24)
$btnModeToggle.Location = New-Object System.Drawing.Point(200, 5) 
$btnModeToggle.FlatStyle = 'Flat'
$btnModeToggle.FlatAppearance.BorderSize = 0
$btnModeToggle.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$btnModeToggle.ForeColor = [System.Drawing.Color]::FromArgb(150, 200, 255)
$btnModeToggle.Add_Click({
    if ($Script:CurrentMode -eq "BIG") {
        Set-WidgetMode "SMALL"
    } else {
        Set-WidgetMode "BIG"
    }
})

$lblCpu = New-Object System.Windows.Forms.Label
$lblCpu.Text = "CPU: --% | --°C | -- GHz"
$lblCpu.ForeColor = [System.Drawing.Color]::White
$lblCpu.Font = New-Object System.Drawing.Font("Consolas", 10)
$lblCpu.Location = New-Object System.Drawing.Point(10, 40)
$lblCpu.Size = New-Object System.Drawing.Size(280, 20)

$lblGpu = New-Object System.Windows.Forms.Label
$lblGpu.Text = "GPU: --% | --°C"
$lblGpu.ForeColor = [System.Drawing.Color]::FromArgb(100, 200, 255)
$lblGpu.Font = New-Object System.Drawing.Font("Consolas", 10)
$lblGpu.Location = New-Object System.Drawing.Point(10, 62)
$lblGpu.Size = New-Object System.Drawing.Size(280, 20)

$lblMode = New-Object System.Windows.Forms.Label
$lblMode.Text = "Mode: -- | AI: --"
$lblMode.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 80)
$lblMode.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblMode.Location = New-Object System.Drawing.Point(10, 84)
$lblMode.Size = New-Object System.Drawing.Size(280, 22)

$lblRam = New-Object System.Windows.Forms.Label
$lblRam.Text = "RAM: --% | R:-- W:-- MB/s"
$lblRam.ForeColor = [System.Drawing.Color]::FromArgb(180, 140, 255)
$lblRam.Font = New-Object System.Drawing.Font("Consolas", 10)
$lblRam.Location = New-Object System.Drawing.Point(10, 108)
$lblRam.Size = New-Object System.Drawing.Size(280, 20)

$lblNet = New-Object System.Windows.Forms.Label
$lblNet.Text = "Net: D -- | U --"
$lblNet.ForeColor = [System.Drawing.Color]::FromArgb(100, 220, 180)
$lblNet.Font = New-Object System.Drawing.Font("Consolas", 9)
$lblNet.Location = New-Object System.Drawing.Point(10, 130)
$lblNet.Size = New-Object System.Drawing.Size(280, 18)

$lblCtx = New-Object System.Windows.Forms.Label
$lblCtx.Text = "Context: --"
$lblCtx.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 160)
$lblCtx.Font = New-Object System.Drawing.Font("Consolas", 9)
$lblCtx.Location = New-Object System.Drawing.Point(10, 150)
$lblCtx.Size = New-Object System.Drawing.Size(280, 18)

$lblApp = New-Object System.Windows.Forms.Label
$lblApp.Text = "App: --"
$lblApp.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)
$lblApp.Font = New-Object System.Drawing.Font("Consolas", 9)
$lblApp.Location = New-Object System.Drawing.Point(10, 170)
$lblApp.Size = New-Object System.Drawing.Size(280, 18)

$sep0 = New-Object System.Windows.Forms.Label
$sep0.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 60)
$sep0.Location = New-Object System.Drawing.Point(10, 193)
$sep0.Size = New-Object System.Drawing.Size(280, 1)

$lblVolume = New-Object System.Windows.Forms.Label
$lblVolume.Text = "VOLUME"
$lblVolume.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
$lblVolume.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$lblVolume.Location = New-Object System.Drawing.Point(10, 200)
$lblVolume.Size = New-Object System.Drawing.Size(60, 16)

$btnVolDown = New-Object System.Windows.Forms.Button
$btnVolDown.Text = "−"
$btnVolDown.Size = New-Object System.Drawing.Size(35, 28)
$btnVolDown.Location = New-Object System.Drawing.Point(10, 218)
$btnVolDown.FlatStyle = 'Flat'
$btnVolDown.FlatAppearance.BorderSize = 1
$btnVolDown.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$btnVolDown.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 50)
$btnVolDown.ForeColor = [System.Drawing.Color]::FromArgb(150, 200, 255)
$btnVolDown.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$btnVolDown.Add_Click({ 
    [AudioControl]::VolumeDown()
    [AudioControl]::VolumeDown()
})

$btnVolUp = New-Object System.Windows.Forms.Button
$btnVolUp.Text = "+"
$btnVolUp.Size = New-Object System.Drawing.Size(35, 28)
$btnVolUp.Location = New-Object System.Drawing.Point(50, 218)
$btnVolUp.FlatStyle = 'Flat'
$btnVolUp.FlatAppearance.BorderSize = 1
$btnVolUp.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$btnVolUp.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 50)
$btnVolUp.ForeColor = [System.Drawing.Color]::FromArgb(150, 255, 150)
$btnVolUp.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$btnVolUp.Add_Click({ 
    [AudioControl]::VolumeUp()
    [AudioControl]::VolumeUp()
})

$btnMute = New-Object System.Windows.Forms.Button
$btnMute.Text = "MUTE"
$btnMute.Size = New-Object System.Drawing.Size(50, 28)
$btnMute.Location = New-Object System.Drawing.Point(90, 218)
$btnMute.FlatStyle = 'Flat'
$btnMute.FlatAppearance.BorderSize = 1
$btnMute.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$btnMute.BackColor = [System.Drawing.Color]::FromArgb(60, 40, 40)
$btnMute.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
$btnMute.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$btnMute.Add_Click({ [AudioControl]::VolumeMute() })

$btnTrimRam = New-Object System.Windows.Forms.Button
$btnTrimRam.Text = "TrimRAM"
$btnTrimRam.Size = New-Object System.Drawing.Size(65, 28)
$btnTrimRam.Location = New-Object System.Drawing.Point(150, 218)
$btnTrimRam.FlatStyle = 'Flat'
$btnTrimRam.FlatAppearance.BorderSize = 1
$btnTrimRam.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$btnTrimRam.BackColor = [System.Drawing.Color]::FromArgb(40, 50, 60)
$btnTrimRam.ForeColor = [System.Drawing.Color]::FromArgb(180, 140, 255)
$btnTrimRam.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$btnTrimRam.Add_Click({ 
    $btnTrimRam.Enabled = $false
    $btnTrimRam.Text = "..."
    $form.Refresh()
    $count = [MemoryTrimmer]::TrimAllProcesses()
    $btnTrimRam.Text = "OK!"
    $form.Refresh()
    Start-Sleep -Milliseconds 500
    $btnTrimRam.Text = "TrimRAM"
    $btnTrimRam.Enabled = $true
})

$btnWeather = New-Object System.Windows.Forms.Button
$btnWeather.Text = "☀Weather"
$btnWeather.Size = New-Object System.Drawing.Size(70, 28)
$btnWeather.Location = New-Object System.Drawing.Point(220, 218)
$btnWeather.FlatStyle = 'Flat'
$btnWeather.FlatAppearance.BorderSize = 1
$btnWeather.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$btnWeather.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 30)
$btnWeather.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 80)
$btnWeather.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$btnWeather.Add_Click({ Start-Process "bingweather:" })

$sep1 = New-Object System.Windows.Forms.Label
$sep1.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 60)
$sep1.Location = New-Object System.Drawing.Point(10, 255)
$sep1.Size = New-Object System.Drawing.Size(280, 1)

$lblProf = New-Object System.Windows.Forms.Label
$lblProf.Text = "PROFIL ZASILANIA"
$lblProf.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
$lblProf.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$lblProf.Location = New-Object System.Drawing.Point(10, 262)
$lblProf.Size = New-Object System.Drawing.Size(150, 16)

# ═══════════════════════════════════════════════════════════════════
# === PRZYCISKI STERUJĄCE GŁÓWNĄ APLIKACJĄ (przez WidgetCommand.txt) ===
# ═══════════════════════════════════════════════════════════════════

$btnSilent = New-Object System.Windows.Forms.Button
$btnSilent.Text = "SILENT"
$btnSilent.Size = New-Object System.Drawing.Size(65, 28)
$btnSilent.Location = New-Object System.Drawing.Point(10, 280)
$btnSilent.FlatStyle = 'Flat'
$btnSilent.FlatAppearance.BorderSize = 1
$btnSilent.BackColor = [System.Drawing.Color]::FromArgb(30, 50, 35)
$btnSilent.ForeColor = [System.Drawing.Color]::FromArgb(100, 255, 100)
$btnSilent.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$btnSilent.Add_Click({ 
    "SILENT" | Set-Content $Script:CommandFile -Force -Encoding ASCII
})

$btnBalanced = New-Object System.Windows.Forms.Button
$btnBalanced.Text = "BALANCED"
$btnBalanced.Size = New-Object System.Drawing.Size(80, 28)
$btnBalanced.Location = New-Object System.Drawing.Point(80, 280)
$btnBalanced.FlatStyle = 'Flat'
$btnBalanced.FlatAppearance.BorderSize = 1
$btnBalanced.BackColor = [System.Drawing.Color]::FromArgb(50, 45, 30)
$btnBalanced.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 80)
$btnBalanced.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$btnBalanced.Add_Click({ 
    "BALANCED" | Set-Content $Script:CommandFile -Force -Encoding ASCII
})

$btnTurbo = New-Object System.Windows.Forms.Button
$btnTurbo.Text = "TURBO"
$btnTurbo.Size = New-Object System.Drawing.Size(65, 28)
$btnTurbo.Location = New-Object System.Drawing.Point(165, 280)
$btnTurbo.FlatStyle = 'Flat'
$btnTurbo.FlatAppearance.BorderSize = 1
$btnTurbo.BackColor = [System.Drawing.Color]::FromArgb(50, 30, 30)
$btnTurbo.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
$btnTurbo.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$btnTurbo.Add_Click({ 
    "TURBO" | Set-Content $Script:CommandFile -Force -Encoding ASCII
})

$btnAI = New-Object System.Windows.Forms.Button
$btnAI.Text = "AI"
$btnAI.Size = New-Object System.Drawing.Size(50, 28)
$btnAI.Location = New-Object System.Drawing.Point(235, 280)
$btnAI.FlatStyle = 'Flat'
$btnAI.FlatAppearance.BorderSize = 1
$btnAI.BackColor = [System.Drawing.Color]::FromArgb(30, 45, 55)
$btnAI.ForeColor = [System.Drawing.Color]::FromArgb(100, 180, 255)
$btnAI.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$btnAI.Add_Click({ 
    "AI" | Set-Content $Script:CommandFile -Force -Encoding ASCII
})

$sep2 = New-Object System.Windows.Forms.Label
$sep2.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 60)
$sep2.Location = New-Object System.Drawing.Point(10, 315)
$sep2.Size = New-Object System.Drawing.Size(280, 1)

$lblTime = New-Object System.Windows.Forms.Label
$lblTime.Text = (Get-Date).ToString("HH:mm:ss")
$lblTime.ForeColor = [System.Drawing.Color]::FromArgb(0, 200, 150)
$lblTime.Font = New-Object System.Drawing.Font("Consolas", 14, [System.Drawing.FontStyle]::Bold)
$lblTime.Location = New-Object System.Drawing.Point(10, 325)
$lblTime.Size = New-Object System.Drawing.Size(120, 25)

$lblDate = New-Object System.Windows.Forms.Label
$lblDate.Text = (Get-Date).ToString("dd.MM.yyyy")
$lblDate.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
$lblDate.Font = New-Object System.Drawing.Font("Consolas", 10)
$lblDate.Location = New-Object System.Drawing.Point(10, 352)
$lblDate.Size = New-Object System.Drawing.Size(120, 18)

$lblTotalNet = New-Object System.Windows.Forms.Label
$lblTotalNet.Text = "TOTAL NETWORK"
$lblTotalNet.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
$lblTotalNet.Font = New-Object System.Drawing.Font("Segoe UI", 7)
$lblTotalNet.Location = New-Object System.Drawing.Point(140, 320)
$lblTotalNet.Size = New-Object System.Drawing.Size(100, 14)

$lblTotalDL = New-Object System.Windows.Forms.Label
$lblTotalDL.Text = "↓ " + (Format-TotalBytes $Script:TotalDownload)
$lblTotalDL.ForeColor = [System.Drawing.Color]::FromArgb(80, 200, 120)
$lblTotalDL.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
$lblTotalDL.Location = New-Object System.Drawing.Point(140, 334)
$lblTotalDL.Size = New-Object System.Drawing.Size(100, 16)

$lblTotalUL = New-Object System.Windows.Forms.Label
$lblTotalUL.Text = "↑ " + (Format-TotalBytes $Script:TotalUpload)
$lblTotalUL.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 80)
$lblTotalUL.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
$lblTotalUL.Location = New-Object System.Drawing.Point(140, 350)
$lblTotalUL.Size = New-Object System.Drawing.Size(100, 16)

# --- Network toggle button (toggle internet on/off) ---
$Script:DisabledNetAdapters = @()
$Script:NetDisabled = $false

$btnNetToggle = New-Object System.Windows.Forms.Button
$btnNetToggle.Text = "NET"
$btnNetToggle.Size = New-Object System.Drawing.Size(38, 38)
$btnNetToggle.Location = New-Object System.Drawing.Point(216, 405)
$btnNetToggle.FlatStyle = 'Flat'
$btnNetToggle.FlatAppearance.BorderSize = 1
$btnNetToggle.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 90)
$btnNetToggle.BackColor = [System.Drawing.Color]::FromArgb(50, 35, 35)
$btnNetToggle.ForeColor = [System.Drawing.Color]::FromArgb(200, 220, 220)
$btnNetToggle.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$btnNetToggle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$btnNetToggle.Add_Click({
    function Set-NetworkState {
        param([string]$State)
        try {
            if ($State -eq 'Enable') {
                Get-NetAdapter | Enable-NetAdapter -Confirm:$false -ErrorAction Stop
                [System.Windows.Forms.MessageBox]::Show("Wszystkie karty sieciowe zostały włączone.", "Sukces")
            } else {
                Get-NetAdapter | Disable-NetAdapter -Confirm:$false -ErrorAction Stop
                [System.Windows.Forms.MessageBox]::Show("Wszystkie karty sieciowe zostały wyłączone.", "Sukces")
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Błąd! Upewnij się, że uruchomiłeś skrypt jako Administrator.", "Błąd")
        }
    }

    $netForm = New-Object System.Windows.Forms.Form
    $netForm.Text = "Menedżer Połączeń Internetowych"
    $netForm.Size = New-Object System.Drawing.Size(300, 200)
    $netForm.StartPosition = 'CenterParent'
    $netForm.FormBorderStyle = 'FixedDialog'
    $netForm.MaximizeBox = $false

    $btnEnable = New-Object System.Windows.Forms.Button
    $btnEnable.Location = New-Object System.Drawing.Point(50, 30)
    $btnEnable.Size = New-Object System.Drawing.Size(200, 40)
    $btnEnable.Text = "WŁĄCZ INTERNET"
    $btnEnable.BackColor = [System.Drawing.Color]::LightGreen
    $btnEnable.Add_Click({ Set-NetworkState -State 'Enable' })

    $btnDisable = New-Object System.Windows.Forms.Button
    $btnDisable.Location = New-Object System.Drawing.Point(50, 90)
    $btnDisable.Size = New-Object System.Drawing.Size(200, 40)
    $btnDisable.Text = "WYŁĄCZ INTERNET"
    $btnDisable.BackColor = [System.Drawing.Color]::LightCoral
    $btnDisable.Add_Click({ Set-NetworkState -State 'Disable' })

    $netForm.Controls.Add($btnEnable)
    $netForm.Controls.Add($btnDisable)

    $netForm.ShowDialog($form) | Out-Null
})

# --- Reset network button: move slightly right and make smaller ---
$btnResetNet = New-Object System.Windows.Forms.Button
$btnResetNet.Text = "RST"
$btnResetNet.Size = New-Object System.Drawing.Size(34, 34)
$btnResetNet.Location = New-Object System.Drawing.Point(266, 405)
$btnResetNet.FlatStyle = 'Flat'
$btnResetNet.FlatAppearance.BorderSize = 1
$btnResetNet.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 90)
$btnResetNet.BackColor = [System.Drawing.Color]::FromArgb(50, 35, 35)
$btnResetNet.ForeColor = [System.Drawing.Color]::FromArgb(255, 120, 100)
$btnResetNet.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$btnResetNet.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$btnResetNet.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Zresetować całkowite użycie sieci?`n`nTotal DL: $(Format-TotalBytes $Script:TotalDownload)`nTotal UL: $(Format-TotalBytes $Script:TotalUpload)", 
        "Reset Network Usage", 
        [System.Windows.Forms.MessageBoxButtons]::YesNo, 
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($result -eq 'Yes') {
        Reset-NetworkUsage
        $lblTotalDL.Text = "↓ " + (Format-TotalBytes $Script:TotalDownload)
        $lblTotalUL.Text = "↑ " + (Format-TotalBytes $Script:TotalUpload)
    }
})

$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.SetToolTip($btnResetNet, "Reset całkowitego użycia sieci")
$tooltip.SetToolTip($btnNetToggle, "Włącz/Wyłącz internet (wyłączenie adapterów sieciowych)")
$tooltip.SetToolTip($btnTrimRam, "Zwolnij nieużywaną pamięć RAM")
$tooltip.SetToolTip($btnWeather, "Otwórz aplikację Pogoda")
$tooltip.SetToolTip($btnMute, "Wycisz/Przywróć dźwięk")
$tooltip.SetToolTip($btnVolDown, "Zmniejsz głośność")
$tooltip.SetToolTip($btnVolUp, "Zwiększ głośność")
$tooltip.SetToolTip($btnModeToggle, "Przełącz tryb: Duży/Mały")
$tooltip.SetToolTip($lblDiskReadLED, "● Odczyt dysku (zielony)")
$tooltip.SetToolTip($lblDiskWriteLED, "● Zapis dysku (bursztynowy)")
$tooltip.SetToolTip($btnSilent, "Wyślij komendę SILENT do głównej aplikacji")
$tooltip.SetToolTip($btnBalanced, "Wyślij komendę BALANCED do głównej aplikacji")
$tooltip.SetToolTip($btnTurbo, "Wyślij komendę TURBO do głównej aplikacji")
$tooltip.SetToolTip($btnAI, "Wyślij komendę AI do głównej aplikacji")

$lblOpacity = New-Object System.Windows.Forms.Label
$lblOpacity.Text = "Opacity:"
$lblOpacity.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
$lblOpacity.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$lblOpacity.Location = New-Object System.Drawing.Point(10, 378)
$lblOpacity.Size = New-Object System.Drawing.Size(55, 16)

$lblOpVal = New-Object System.Windows.Forms.Label
$lblOpVal.Text = "95%"
$lblOpVal.ForeColor = [System.Drawing.Color]::White
$lblOpVal.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$lblOpVal.Location = New-Object System.Drawing.Point(65, 378)
$lblOpVal.Size = New-Object System.Drawing.Size(35, 16)

$btnOpMinus = New-Object System.Windows.Forms.Button
$btnOpMinus.Text = "-"
$btnOpMinus.Size = New-Object System.Drawing.Size(30, 22)
$btnOpMinus.Location = New-Object System.Drawing.Point(105, 375)
$btnOpMinus.FlatStyle = 'Flat'
$btnOpMinus.FlatAppearance.BorderSize = 0
$btnOpMinus.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 60)
$btnOpMinus.ForeColor = [System.Drawing.Color]::White
$btnOpMinus.Add_Click({
    $script:widgetOpacity = [Math]::Max(0.3, $script:widgetOpacity - 0.1)
    $form.Opacity = $script:widgetOpacity
    $lblOpVal.Text = "{0:N0}%" -f ($script:widgetOpacity * 100)
    Save-Settings
})

$btnOpPlus = New-Object System.Windows.Forms.Button
$btnOpPlus.Text = "+"
$btnOpPlus.Size = New-Object System.Drawing.Size(30, 22)
$btnOpPlus.Location = New-Object System.Drawing.Point(140, 375)
$btnOpPlus.FlatStyle = 'Flat'
$btnOpPlus.FlatAppearance.BorderSize = 0
$btnOpPlus.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 60)
$btnOpPlus.ForeColor = [System.Drawing.Color]::White
$btnOpPlus.Add_Click({
    $script:widgetOpacity = [Math]::Min(1.0, $script:widgetOpacity + 0.1)
    $form.Opacity = $script:widgetOpacity
    $lblOpVal.Text = "{0:N0}%" -f ($script:widgetOpacity * 100)
    Save-Settings
})

$lblTopMost = New-Object System.Windows.Forms.Label
$lblTopMost.Text = "On Top:"
$lblTopMost.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
$lblTopMost.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$lblTopMost.Location = New-Object System.Drawing.Point(210, 378)
$lblTopMost.Size = New-Object System.Drawing.Size(50, 16)

$btnTopMostToggle = New-Object System.Windows.Forms.Button
$btnTopMostToggle.Text = "📌"
$btnTopMostToggle.Size = New-Object System.Drawing.Size(24, 24)
$btnTopMostToggle.Location = New-Object System.Drawing.Point(268, 375)
$btnTopMostToggle.FlatStyle = 'Flat'
$btnTopMostToggle.FlatAppearance.BorderSize = 0
$btnTopMostToggle.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 10, [System.Drawing.FontStyle]::Bold)
$btnTopMostToggle.Add_Click({ Toggle-TopMost })

Update-TopMostButtons

$bottomLine = New-Object System.Windows.Forms.Panel
$bottomLine.BackColor = [System.Drawing.Color]::FromArgb(0, 170, 255)
$bottomLine.Location = New-Object System.Drawing.Point(0, 400)
$bottomLine.Size = New-Object System.Drawing.Size(300, 4)

# === DODANIE KONTROLEK DO FORMULARZA ===
$form.Controls.AddRange(@(
    $lblTitle, $lblDiskReadLED, $lblDiskWriteLED, $btnClose, $btnMin, $btnModeToggle,
    $lblCpu, $lblGpu, $lblMode, $lblRam, $lblNet, $lblCtx, $lblApp,
    $sep0, $lblVolume, $btnVolDown, $btnVolUp, $btnMute, $btnTrimRam, $btnWeather,
    $sep1, $lblProf, $btnSilent, $btnBalanced, $btnTurbo, $btnAI,
    $sep2, $lblTime, $lblDate,
    $lblTotalNet, $lblTotalDL, $lblTotalUL, $btnNetToggle, $btnResetNet,
    $lblOpacity, $lblOpVal, $btnOpMinus, $btnOpPlus,
    $lblTopMost, $btnTopMostToggle,
    $bottomLine
))

# === DRAG SUPPORT ===
$dragHandler = {
    param($eventSender, $e)
    if ($e.Button -eq 'Left') {
        $script:drag = $true
        $script:dragX = $e.X
        $script:dragY = $e.Y
    }
}
$moveHandler = {
    param($eventSender, $e)
    if ($script:drag) {
        $form.Left = $form.Left + $e.X - $script:dragX
        $form.Top = $form.Top + $e.Y - $script:dragY
    }
}
$upHandler = { 
    $script:drag = $false
    Save-Settings
}

$form.Add_MouseDown($dragHandler)
$form.Add_MouseMove($moveHandler)
$form.Add_MouseUp($upHandler)

foreach ($ctrl in @($lblTitle, $lblDiskReadLED, $lblDiskWriteLED, $lblCpu, $lblGpu, $lblMode, $lblRam, $lblNet, $lblCtx, $lblApp, $lblTime, $lblDate, $lblTotalNet, $lblVolume, $lblProf, $btnModeToggle)) {
    $ctrl.Add_MouseDown($dragHandler)
    $ctrl.Add_MouseMove($moveHandler)
    $ctrl.Add_MouseUp($upHandler)
}

function Format-Speed($bytes) {
    if ($bytes -ge 1MB) { return "{0:N1} MB/s" -f ($bytes/1MB) }
    elseif ($bytes -ge 1KB) { return "{0:N0} KB/s" -f ($bytes/1KB) }
    else { return "{0:N0} B/s" -f $bytes }
}

# ═══════════════════════════════════════════════════════════════════
# === TIMER WYMUSZANIA TOPMOST (500ms) ===
# ═══════════════════════════════════════════════════════════════════
$topMostTimer = New-Object System.Windows.Forms.Timer
$topMostTimer.Interval = 500
$topMostTimer.Add_Tick({
    # Nie wymuszaj TopMost gdy menu tray jest otwarte
    if (-not $trayMenu.Visible) {
        Force-WidgetTopMost
    }
})
$topMostTimer.Start()

# ═══════════════════════════════════════════════════════════════════
# === TIMER ANIMACJI DIOD (50ms) ===
# ═══════════════════════════════════════════════════════════════════
$diskLedTimer = New-Object System.Windows.Forms.Timer
$diskLedTimer.Interval = 50
$diskLedTimer.Add_Tick({
    $now = [DateTime]::Now
    
    if ($now -lt $Script:DiskReadActiveUntil) {
        $Script:ReadLedBlinkState = -not $Script:ReadLedBlinkState
        if ($Script:ReadLedBlinkState) {
            $lblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(0, 255, 80)
        } else {
            $lblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 40)
        }
    } else {
        $lblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    }
    
    if ($now -lt $Script:DiskWriteActiveUntil) {
        $Script:WriteLedBlinkState = -not $Script:WriteLedBlinkState
        if ($Script:WriteLedBlinkState) {
            $lblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(255, 180, 0)
        } else {
            $lblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(120, 80, 0)
        }
    } else {
        $lblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    }
})
$diskLedTimer.Start()

# ═══════════════════════════════════════════════════════════════════
# === TIMER MONITORINGU DYSKU (250ms) ===
# ═══════════════════════════════════════════════════════════════════
$diskMonitorTimer = New-Object System.Windows.Forms.Timer
$diskMonitorTimer.Interval = 500
$diskMonitorTimer.Add_Tick({
    try {
        if ($Script:perfDiskRead -and $Script:perfDiskWrite) {
            $readBytes = $Script:perfDiskRead.NextValue()
            $writeBytes = $Script:perfDiskWrite.NextValue()
        } else {
            $readBytes = 0
            $writeBytes = 0
        }

        $Script:LastDiskRead = [math]::Round($readBytes / 1MB, 1)
        $Script:LastDiskWrite = [math]::Round($writeBytes / 1MB, 1)
        
        if ($readBytes -gt 1048576) {
            $Script:DiskReadActiveUntil = [DateTime]::Now.AddMilliseconds(300)
        }
        
        if ($writeBytes -gt 1048576) {
            $Script:DiskWriteActiveUntil = [DateTime]::Now.AddMilliseconds(300)
        }
    } catch {}
})
$diskMonitorTimer.Start()

# === TIMER MONITORINGU SIECI (500ms, Get-NetAdapterStatistics) ===
$netMonitorTimer = New-Object System.Windows.Forms.Timer
$netMonitorTimer.Interval = 500
$netMonitorTimer.Add_Tick({
    try {
        $adapters = Get-NetAdapterStatistics | Where-Object { $_.ReceivedBytes -gt 0 -or $_.SentBytes -gt 0 }
        if ($adapters) {
            $rx = ($adapters | Measure-Object -Property ReceivedBytes -Sum).Sum
            $tx = ($adapters | Measure-Object -Property SentBytes -Sum).Sum
            if ($Script:_PrevNetStats) {
                $Script:LastNetDL = [math]::Max(0, [math]::Round(($rx - $Script:_PrevNetStats.Rx) / 0.5, 0))
                $Script:LastNetUL = [math]::Max(0, [math]::Round(($tx - $Script:_PrevNetStats.Tx) / 0.5, 0))
            }
            $Script:_PrevNetStats = @{ Rx = $rx; Tx = $tx }
        } else {
            $Script:LastNetDL = 0
            $Script:LastNetUL = 0
            $Script:_PrevNetStats = $null
        }
    } catch {
        $Script:LastNetDL = 0
        $Script:LastNetUL = 0
        $Script:_PrevNetStats = $null
    }
})
$netMonitorTimer.Start()

# ═══════════════════════════════════════════════════════════════════
# === GŁÓWNY TIMER (1000ms) - ODCZYT Z PLIKU JSON + OHM DLA GPU ===
# ═══════════════════════════════════════════════════════════════════
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        $lblTime.Text = (Get-Date).ToString("HH:mm:ss")
        $lblDate.Text = (Get-Date).ToString("dd.MM.yyyy")
        
        $diskRead = $Script:LastDiskRead
        $diskWrite = $Script:LastDiskWrite
        
        # === POBIERZ DANE Z OHM ===
        $ohmData = Get-OHMData
        
        # === CPU - PRIORYTET: OHM, fallback do WMI/system ===
        if ($ohmData -and ($ohmData.CPULoad -gt 0 -or $ohmData.CPUTemp -gt 0)) {
            $cpu = $ohmData.CPULoad
            $temp = $ohmData.CPUTemp
            $ghz = if ($ohmData.CPUClock -gt 0) { "{0:N2}" -f ($ohmData.CPUClock/1000) } else { "--" }
            $pwr = if ($ohmData.CPUPower -gt 0) { " | $($ohmData.CPUPower)W" } else { "" }
        } else {
            $cpu = (Get-CimInstance Win32_Processor).LoadPercentage
            $temp = 0
            $ghz = "{0:N2}" -f ((Get-CimInstance Win32_Processor).CurrentClockSpeed/1000)
            $pwr = ""
        }
        $lblCpu.Text = "CPU: $cpu% | ${temp}°C | $ghz GHz$pwr"
        $lblCpu.ForeColor = if ($cpu -gt 80) { [System.Drawing.Color]::FromArgb(255,100,100) } 
                           elseif ($cpu -gt 50) { [System.Drawing.Color]::FromArgb(255,200,100) } 
                           else { [System.Drawing.Color]::White }
        
        # === ODCZYTAJ DANE Z PLIKU JSON (tylko Mode, AI, Context) ===
        if (Test-Path $Script:DataFile) {
            $jsonContent = [System.IO.File]::ReadAllText($Script:DataFile)
            $d = $jsonContent | ConvertFrom-Json
            
            # GPU - PRIORYTET: OHM, fallback do pliku JSON
            if ($ohmData -and ($ohmData.GPULoad -gt 0 -or $ohmData.GPUTemp -gt 0)) {
                # Dane z OHM
                $gpuLoad = $ohmData.GPULoad
                $gpuTemp = $ohmData.GPUTemp
                $gpuClock = $ohmData.GPUClock
                
                $gpuText = "GPU: $gpuLoad%"
                if ($gpuTemp -gt 0) { $gpuText += " | ${gpuTemp}°C" }
                if ($gpuClock -gt 0) { $gpuText += " | $gpuClock MHz" }
                $lblGpu.Text = $gpuText
            } else {
                # Fallback do danych z pliku JSON
                $gpuLoad = if ($d.GPULoad) { [int]$d.GPULoad } else { 0 }
                $gpuTemp = if ($d.GPUTemp) { [int]$d.GPUTemp } else { 0 }
                $lblGpu.Text = "GPU: $gpuLoad% | ${gpuTemp}°C"
            }
            
            $lblGpu.ForeColor = if ($gpuTemp -gt 80) { [System.Drawing.Color]::FromArgb(255,100,100) }
                               elseif ($gpuTemp -gt 65) { [System.Drawing.Color]::FromArgb(255,200,100) }
                               else { [System.Drawing.Color]::FromArgb(100,200,255) }
            
            # Mode i AI - z pliku JSON
            $mode = if ($d.Mode) { $d.Mode } else { "--" }
            $ai = if ($d.AI) { $d.AI } else { "--" }
            $lblMode.Text = "Mode: $mode | AI: $ai"
            $lblMode.ForeColor = switch ($mode) {
                "Turbo" { [System.Drawing.Color]::FromArgb(255,100,100) }
                "Silent" { [System.Drawing.Color]::FromArgb(100,255,100) }
                default { [System.Drawing.Color]::FromArgb(255,200,80) }
            }
            
            # Podświetlenie przycisków według aktualnego trybu
            $btnSilent.BackColor = if ($mode -eq "Silent") { [System.Drawing.Color]::FromArgb(40, 70, 45) } else { [System.Drawing.Color]::FromArgb(30, 50, 35) }
            $btnBalanced.BackColor = if ($mode -eq "Balanced") { [System.Drawing.Color]::FromArgb(70, 60, 35) } else { [System.Drawing.Color]::FromArgb(50, 45, 30) }
            $btnTurbo.BackColor = if ($mode -eq "Turbo") { [System.Drawing.Color]::FromArgb(70, 40, 40) } else { [System.Drawing.Color]::FromArgb(50, 30, 30) }
            $btnAI.BackColor = if ($ai -eq "ON") { [System.Drawing.Color]::FromArgb(40, 60, 75) } else { [System.Drawing.Color]::FromArgb(30, 45, 55) }
            
            # RAM i Dysk
            $ram = if ($d.RAM) { [int]$d.RAM } else { 0 }
            $lblRam.Text = "RAM: $ram% | R:{0:N1} W:{1:N1} MB/s" -f $diskRead, $diskWrite
            

            # Sieć - realtime z PerformanceCounter, total z pliku
            $dl = Format-Speed $Script:LastNetDL
            $ul = Format-Speed $Script:LastNetUL
            $lblNet.Text = "Net: D $dl | U $ul"
            # Total download/upload tylko z pliku NetworkStats.json (nie sumujemy z d.DL/d.UL)
            $lblTotalDL.Text = "↓ " + (Format-TotalBytes $Script:TotalDownload)
            $lblTotalUL.Text = "↑ " + (Format-TotalBytes $Script:TotalUpload)
            
            $now = Get-Date
            if (($now - $Script:LastSaveTime).TotalSeconds -ge $Script:SaveInterval) {
                Save-NetworkUsage
                $Script:LastSaveTime = $now
            }
            
            # Context i App
            $ctx = if ($d.Context) { $d.Context } else { "--" }
            $act = if ($d.Activity) { $d.Activity } else { "--" }
            $lblCtx.Text = "Ctx: $ctx | $act"
            
            $app = if ($d.App) { $d.App } else { "--" }
            if ($app.Length -gt 35) { $app = $app.Substring(0, 32) + "..." }
            $lblApp.Text = "App: $app"
            
            # Dolna linia - kolor według trybu
            $bottomLine.BackColor = switch ($mode) {
                "Turbo" { [System.Drawing.Color]::FromArgb(255,60,60) }
                "Silent" { [System.Drawing.Color]::FromArgb(60,255,60) }
                "Balanced" { [System.Drawing.Color]::FromArgb(255, 200, 0) }
                default { [System.Drawing.Color]::FromArgb(0,170,255) }
            }
            
            $tray.Text = "CPU:$cpu% ${temp}°C | $mode | AI:$ai"
            
        } else {
            # Brak pliku JSON - dane Mode/AI niedostępne, ale CPU/GPU z OHM/system
            $lblMode.Text = "CZEKAM NA GŁÓWNĄ APLIKACJĘ..."
            $lblRam.Text = "RAM: --% | R:{0:N1} W:{1:N1} MB/s" -f $diskRead, $diskWrite
            $lblCtx.Text = "Ctx: --"
            $lblApp.Text = "App: --"
        }
    } catch {
        # Ignoruj błędy
    }
})
$timer.Start()

# === CLEANUP ===
$form.Add_FormClosing({
    $timer.Stop()
    $timer.Dispose()
    $diskMonitorTimer.Stop()
    $diskMonitorTimer.Dispose()
    $diskLedTimer.Stop()
    $diskLedTimer.Dispose()
    $topMostTimer.Stop()
    $topMostTimer.Dispose()
    
    if ($Script:perfDiskRead) { $Script:perfDiskRead.Dispose() }
    if ($Script:perfDiskWrite) { $Script:perfDiskWrite.Dispose() }
    
    Save-Settings
    Save-NetworkUsage
    $tray.Visible = $false
    $tray.Dispose()
    if (Test-Path $Script:PidFile) { Remove-Item $Script:PidFile -Force -ErrorAction SilentlyContinue }
})

$lblOpVal.Text = "{0:N0}%" -f ($script:widgetOpacity * 100)
Set-WidgetMode $Script:LastMode

[System.Windows.Forms.Application]::Run($form)