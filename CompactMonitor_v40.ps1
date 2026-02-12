# ═══════════════════════════════════════════════════════════════════════════════
# CompactMonitor v40
# © 2026 Wszelkie prawa zastrzeżone. All Rights Reserved.
# Autor: Michał | Data utworzenia: 2026-01-23
# ═══════════════════════════════════════════════════════════════════════════════

# Ustawienia kodowania UTF-8 dla konsoli i domyślnych cmdletów
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
$PSDefaultParameterValues['Set-Content:Encoding'] = 'utf8'
$PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8'

# =====================================================================
# CPU Manager AI - Compact Monitor v4.3
# Zoptymalizowany widget z GPU z OHM/LHM
# NOWE: Tray icon, TRIM RAM, KILL ALL PowerShell, Half Mode (H)
# =====================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# === AUDIO API ===
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class AudioAPI {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);
    public const byte VK_VOLUME_MUTE = 0xAD;
    public const byte VK_VOLUME_DOWN = 0xAE;
    public const byte VK_VOLUME_UP = 0xAF;
}
"@ -ErrorAction SilentlyContinue

# === WIN32 API ===
Add-Type -Name Win32 -Namespace CompactMon -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
public const uint SWP_NOMOVE = 0x0002;
public const uint SWP_NOSIZE = 0x0001;
public const uint SWP_NOACTIVATE = 0x0010;
'@ -ErrorAction SilentlyContinue

# === MEMORY API (dla TRIM RAM) ===
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

public class MemoryAPI {
    [DllImport("kernel32.dll")]
    public static extern bool SetProcessWorkingSetSize(IntPtr proc, int min, int max);
    
    [DllImport("psapi.dll")]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
    
    public static void TrimProcessMemory(Process process) {
        try {
            EmptyWorkingSet(process.Handle);
        } catch { }
    }
    
    public static void TrimAllProcesses() {
        foreach (Process proc in Process.GetProcesses()) {
            try {
                EmptyWorkingSet(proc.Handle);
            } catch { }
        }
    }
}
"@ -ErrorAction SilentlyContinue

# Ukryj konsolę
try { [CompactMon.Win32]::ShowWindow([CompactMon.Win32]::GetConsoleWindow(), 0) | Out-Null } catch {}

# === ŚCIEŻKI ===
$Script:BaseDir = "C:\CPUManager"
$Script:DataFile = "$Script:BaseDir\WidgetData.json"
$Script:PidFile = "$Script:BaseDir\CompactMonitor.pid"
$Script:SettingsFile = "$Script:BaseDir\CompactMonitor_Settings.json"

# Utwórz folder jeśli nie istnieje
if (-not (Test-Path $Script:BaseDir)) { New-Item -Path $Script:BaseDir -ItemType Directory -Force | Out-Null }

# Zapisz PID
$PID | Set-Content $Script:PidFile -Force -ErrorAction SilentlyContinue

# === STAN APLIKACJI ===
$Script:Opacity = 0.90
$Script:IsTopMost = $true
$Script:PosX = -1
$Script:PosY = 5
$Script:EngineMode = "---"
$Script:EngineAI = "OFF"
$Script:LastEngineMode = "---"
$Script:StatusBarColor = [System.Drawing.Color]::Gray
$Script:IsHalfMode = $false
$Script:FullHeight = 100
$Script:HalfHeight = 58

# === PRZECIĄGANIE OKNA ===
$Script:FormDragging = $false
$Script:FormDragStart = $null
$Script:FormOriginalLocation = $null

# === OHM/LHM ===
$Script:OHM_Available = $false
$Script:LHM_Available = $false
$Script:OHM_LastCheck = [DateTime]::MinValue
$Script:OHM_CheckInterval = 5

# === INICJALIZACJA NETWORK COUNTERS ===
# Używamy Get-CimInstance dla kompatybilności ze wszystkimi językami Windows
try {
    # Inicjalizuj zmienne do śledzenia ruchu sieciowego
    $Script:LastNetworkCheck = [DateTime]::Now
    $Script:LastBytesReceived = 0
    $Script:LastBytesSent = 0
    $Script:NetworkCountersAvailable = $true
    $Script:LastAdapterName = $null
    
    # Pobierz początkowe wartości - użyj liczników kumulatywnych (BytesReceivedPerSec to zła nazwa, to są kumulatywne bajty)
    $adapters = Get-CimInstance -ClassName Win32_PerfRawData_Tcpip_NetworkInterface | 
                Where-Object { $_.Name -notmatch 'Loopback|isatap|Teredo|6to4' -and $_.BytesReceivedPersec -gt 100 } |
                Sort-Object BytesReceivedPersec -Descending |
                Select-Object -First 1
    
    if ($adapters) {
        $Script:LastBytesReceived = [int64]$adapters.BytesReceivedPersec
        $Script:LastBytesSent = [int64]$adapters.BytesSentPersec
        $Script:LastAdapterName = $adapters.Name
    }
} catch {
    $Script:NetworkCountersAvailable = $false
}

# === INICJALIZACJA CPU COUNTER ===
try {
    $Script:perfCPU = New-Object System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total")
    $Script:perfCPU.NextValue() | Out-Null
    $Script:CPUCounterAvailable = $true
} catch {
    $Script:CPUCounterAvailable = $false
}

# === INICJALIZACJA DISK COUNTERS ===
$Script:DiskReadActiveUntil = [DateTime]::MinValue
$Script:DiskWriteActiveUntil = [DateTime]::MinValue
$Script:ReadLedBlinkState = $false
$Script:WriteLedBlinkState = $false

try {
    $Script:perfDiskRead = New-Object System.Diagnostics.PerformanceCounter("PhysicalDisk", "Disk Read Bytes/sec", "_Total")
    $Script:perfDiskWrite = New-Object System.Diagnostics.PerformanceCounter("PhysicalDisk", "Disk Write Bytes/sec", "_Total")
    $Script:perfDiskRead.NextValue() | Out-Null
    $Script:perfDiskWrite.NextValue() | Out-Null
    $Script:DiskCountersAvailable = $true
} catch {
    $Script:DiskCountersAvailable = $false
}

# === FUNKCJA TWORZENIA IKONY TRAY ===
function Create-TrayIcon {
    $iconSize = 32
    $bitmap = New-Object System.Drawing.Bitmap($iconSize, $iconSize)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    
    # Tło - zaokrąglony kwadrat ciemnoniebieski
    $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 41, 128, 185))
    $rect = New-Object System.Drawing.Rectangle(2, 2, 28, 28)
    $graphics.FillEllipse($bgBrush, $rect)
    
    # Litera "C" - biała, pogrubiona
    $font = New-Object System.Drawing.Font("Consolas", 16, [System.Drawing.FontStyle]::Bold)
    $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $textRect = New-Object System.Drawing.RectangleF(0, 0, $iconSize, $iconSize)
    $graphics.DrawString("C", $font, $textBrush, $textRect, $sf)
    
    # Mały pasek CPU na dole (zielony)
    $cpuBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 46, 204, 113))
    $graphics.FillRectangle($cpuBrush, 6, 26, 20, 3)
    
    $graphics.Dispose()
    $font.Dispose()
    $textBrush.Dispose()
    $bgBrush.Dispose()
    $cpuBrush.Dispose()
    
    $icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
    return $icon
}

# === FUNKCJA TRIM RAM ===
function Invoke-TrimRAM {
    $trimmedCount = 0
    $freedMB = 0
    
    try {
        # Pobierz użycie RAM przed
        $before = (Get-WmiObject Win32_OperatingSystem).FreePhysicalMemory
        
        # Trimuj wszystkie procesy
        $processes = Get-Process | Where-Object { $_.WorkingSet64 -gt 10MB }
        foreach ($proc in $processes) {
            try {
                [MemoryAPI]::TrimProcessMemory($proc)
                $trimmedCount++
            } catch {}
        }
        
        # Wywołaj garbage collector
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
        
        Start-Sleep -Milliseconds 500
        
        # Pobierz użycie RAM po
        $after = (Get-WmiObject Win32_OperatingSystem).FreePhysicalMemory
        $freedMB = [math]::Round(($after - $before) / 1024, 1)
        
        # Pokaż powiadomienie
        if ($freedMB -gt 0) {
            $Script:Tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $Script:Tray.BalloonTipTitle = "TRIM RAM"
            $Script:Tray.BalloonTipText = "Zwolniono: $freedMB MB`nProcesów: $trimmedCount"
            $Script:Tray.ShowBalloonTip(3000)
        } else {
            $Script:Tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $Script:Tray.BalloonTipTitle = "TRIM RAM"
            $Script:Tray.BalloonTipText = "Pamięć zoptymalizowana`nProcesów: $trimmedCount"
            $Script:Tray.ShowBalloonTip(3000)
        }
    } catch {
        $Script:Tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
        $Script:Tray.BalloonTipTitle = "TRIM RAM"
        $Script:Tray.BalloonTipText = "Błąd podczas optymalizacji pamięci"
        $Script:Tray.ShowBalloonTip(3000)
    }
}

# === FUNKCJA KILL ALL POWERSHELL ===
function Invoke-KillAllPowerShell {
    $killedCount = 0
    $myPID = $PID
    
    try {
        # Lista nazw procesów PowerShell (od najstarszych do najnowszych)
        $psProcessNames = @(
            "powershell",      # Windows PowerShell 1.0-5.x
            "powershell_ise",  # PowerShell ISE
            "pwsh"             # PowerShell Core 6.x / PowerShell 7.x
        )
        
        foreach ($procName in $psProcessNames) {
            $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
            foreach ($proc in $procs) {
                # Nie zabijaj siebie
                if ($proc.Id -ne $myPID) {
                    try {
                        $proc.Kill()
                        $killedCount++
                    } catch {}
                }
            }
        }
        
        # Pokaż powiadomienie
        $Script:Tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $Script:Tray.BalloonTipTitle = "KILL ALL PowerShell"
        $Script:Tray.BalloonTipText = "Zamknięto procesów: $killedCount"
        $Script:Tray.ShowBalloonTip(3000)
        
    } catch {
        $Script:Tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
        $Script:Tray.BalloonTipTitle = "KILL ALL PowerShell"
        $Script:Tray.BalloonTipText = "Błąd podczas zamykania procesów"
        $Script:Tray.ShowBalloonTip(3000)
    }
}

# === FUNKCJE OHM/LHM ===
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
    
    # Sprawdź dostępność co 5 sekund
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
    
    if (-not $namespace) { return $null }
    
    try {
        $sensors = Get-WmiObject -Namespace $namespace -Class Sensor -ErrorAction Stop
        $result = @{ 
            CpuLoad = 0
            Temp = 0
            CpuMHz = 0
            CpuPower = 0
            GPULoad = 0
            GPUTemp = 0
            GPUClock = 0
            RAMUsed = 0
            RAMTotal = 0
        }
        
        foreach ($sensor in $sensors) {
            $name = $sensor.Name
            $value = [math]::Round($sensor.Value, 1)
            $type = $sensor.SensorType
            $parent = $sensor.Parent
            $identifier = $sensor.Identifier

            # CPU
            if ($identifier -like "*/cpu/*" -or $parent -like "*cpu*") {
                switch ($type) {
                    "Load" {
                        if ($name -eq "CPU Total" -or $name -like "*Total*") {
                            $result.CpuLoad = [int]$value
                        }
                    }
                    "Temperature" {
                        if ($name -like "*Package*" -or $name -like "*CPU*" -or $name -like "*Core*") {
                            if ($value -gt $result.Temp) { $result.Temp = [int]$value }
                        }
                    }
                    "Clock" {
                        if ($name -like "*Core #1*" -or ($name -like "*Core*" -and $result.CpuMHz -eq 0)) {
                            $result.CpuMHz = [int]$value
                        }
                    }
                    "Power" {
                        if ($name -like "*Package*" -or $name -like "*CPU*" -or $name -like "*Total*") {
                            if ($value -gt $result.CpuPower) { $result.CpuPower = [int]$value }
                        }
                    }
                }
            }
            
            # GPU - obsługa różnych formatów identifier: /gpu/, /gpu-amd/, /nvidiagpu/, /atigpu/, /intelgpu/, /amdgpu/
            if ($identifier -like "*/gpu/*" -or $identifier -like "*/gpu-*" -or $identifier -like "*/nvidiagpu/*" -or $identifier -like "*/atigpu/*" -or $identifier -like "*/intelgpu/*" -or $identifier -like "*/amdgpu/*") {
                switch ($type) {
                    "Load" {
                        if ($name -like "*GPU Core*" -or $name -eq "GPU Core" -or $name -like "*D3D 3D*") {
                            $result.GPULoad = [int]$value
                        }
                    }
                    "Temperature" {
                        if ($name -like "*GPU*" -or $name -like "*Core*" -or $name -like "*Junction*" -or $name -like "*Memory*" -or $name -eq "Temperature") {
                            if ($value -gt $result.GPUTemp) { $result.GPUTemp = [int]$value }
                        }
                    }
                    "Clock" {
                        if ($name -like "*GPU Core*" -or $name -eq "GPU Core" -or ($name -like "*Core*" -and $result.GPUClock -eq 0)) {
                            $result.GPUClock = [int]$value
                        }
                    }
                }
            }
            
            # RAM - Data type (GB)
            if ($type -eq "Data") {
                if ($name -like "*Used*" -and $name -like "*Memory*") {
                    $result.RAMUsed = [math]::Round($value, 1)
                }
                if ($name -like "*Available*" -and $name -like "*Memory*") {
                    $result.RAMTotal = [math]::Round($value, 1)
                }
            }
        }
        
        return $result
    } catch {
        return $null
    }
}

# === FUNKCJA GRADIENT COLOR ===
function Get-GradientColor {
    param([double]$percent)
    
    # Clamp percent between 0 and 100
    $percent = [Math]::Max(0, [Math]::Min(100, $percent))
    
    # Define colors
    $green = @{ R = 46; G = 204; B = 113 }
    $yellow = @{ R = 241; G = 196; B = 15 }
    $orange = @{ R = 230; G = 126; B = 34 }
    $red = @{ R = 231; G = 76; B = 60 }
    
    if ($percent -le 33) {
        # Green to Yellow
        $ratio = $percent / 33
        $r = [int]($green.R + ($yellow.R - $green.R) * $ratio)
        $g = [int]($green.G + ($yellow.G - $green.G) * $ratio)
        $b = [int]($green.B + ($yellow.B - $green.B) * $ratio)
    }
    elseif ($percent -le 66) {
        # Yellow to Orange
        $ratio = ($percent - 33) / 33
        $r = [int]($yellow.R + ($orange.R - $yellow.R) * $ratio)
        $g = [int]($yellow.G + ($orange.G - $yellow.G) * $ratio)
        $b = [int]($yellow.B + ($orange.B - $yellow.B) * $ratio)
    }
    else {
        # Orange to Red
        $ratio = ($percent - 66) / 34
        $r = [int]($orange.R + ($red.R - $orange.R) * $ratio)
        $g = [int]($orange.G + ($red.G - $orange.G) * $ratio)
        $b = [int]($orange.B + ($red.B - $orange.B) * $ratio)
    }
    
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

# === FUNKCJA GET RAM INFO ===
function Get-RAMInfo {
    try {
        $os = Get-WmiObject Win32_OperatingSystem
        $totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $freeRAM = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $usedRAM = [math]::Round($totalRAM - $freeRAM, 1)
        
        return @{
            Total = $totalRAM
            Free = $freeRAM
            Used = $usedRAM
        }
    } catch {
        return @{
            Total = 0
            Free = 0
            Used = 0
        }
    }
}

# === FUNKCJA FORMAT NETWORK SPEED ===
function Format-NetworkSpeed {
    param([double]$bytes)
    
    if ($bytes -lt 1MB) {
        # Zawsze zaokrąglaj do całych KB/s
        return "$([Math]::Round($bytes / 1KB, 0))KB/s"
    } else {
        # Zawsze zaokrąglaj do 1 miejsca po przecinku MB/s
        return "$([Math]::Round($bytes / 1MB, 1))MB/s"
    }
}

# === LOAD/SAVE SETTINGS ===
function Load-Settings {
    if (Test-Path $Script:SettingsFile) {
        try {
            $settings = Get-Content $Script:SettingsFile -Raw | ConvertFrom-Json
            $Script:Opacity = if ($settings.Opacity) { $settings.Opacity } else { 0.90 }
            $Script:IsTopMost = if ($null -ne $settings.TopMost) { $settings.TopMost } else { $true }
            $Script:PosX = if ($null -ne $settings.PosX) { $settings.PosX } else { -1 }
            $Script:PosY = if ($null -ne $settings.PosY) { $settings.PosY } else { 5 }
            $Script:IsHalfMode = if ($null -ne $settings.HalfMode) { $settings.HalfMode } else { $false }
        } catch {
            # Domyślne wartości
            $Script:Opacity = 0.90
            $Script:IsTopMost = $true
            $Script:PosX = -1
            $Script:PosY = 5
            $Script:IsHalfMode = $false
        }
    }
}

function Save-Settings {
    try {
        $settings = @{
            Opacity = $Script:Opacity
            TopMost = $Script:IsTopMost
            PosX = $Script:Form.Location.X
            PosY = $Script:Form.Location.Y
            HalfMode = $Script:IsHalfMode
        }
        $settings | ConvertTo-Json | Set-Content $Script:SettingsFile -Force
    } catch {}
}

# Wczytaj ustawienia
Load-Settings

# === FUNKCJE AUDIO ===
function Set-VolumeDown { [AudioAPI]::keybd_event([AudioAPI]::VK_VOLUME_DOWN, 0, 0, 0) }
function Set-VolumeUp { [AudioAPI]::keybd_event([AudioAPI]::VK_VOLUME_UP, 0, 0, 0) }
function Set-VolumeMute { [AudioAPI]::keybd_event([AudioAPI]::VK_VOLUME_MUTE, 0, 0, 0) }



# === DRAG & DROP ===
function Start-FormDrag {
    $Script:FormDragging = $true
    $Script:FormDragStart = [System.Windows.Forms.Cursor]::Position
    $Script:FormOriginalLocation = $Script:Form.Location
}

function Update-FormDrag {
    if ($Script:FormDragging -and $Script:FormDragStart) {
        $current = [System.Windows.Forms.Cursor]::Position
        $deltaX = $current.X - $Script:FormDragStart.X
        $deltaY = $current.Y - $Script:FormDragStart.Y
        $Script:Form.Location = New-Object System.Drawing.Point(
            ($Script:FormOriginalLocation.X + $deltaX),
            ($Script:FormOriginalLocation.Y + $deltaY)
        )
    }
}

function Stop-FormDrag {
    $Script:FormDragging = $false
    Save-Settings
}

# === FORM ===
$Script:Form = New-Object System.Windows.Forms.Form
$Script:Form.Text = "CPU Manager - Compact Monitor"
$Script:Form.Size = New-Object System.Drawing.Size(280, $Script:FullHeight)
$Script:Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$Script:Form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35)
$Script:Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$Script:Form.TopMost = $Script:IsTopMost
$Script:Form.Opacity = $Script:Opacity
$Script:Form.ShowInTaskbar = $false

if ($Script:PosX -eq -1) {
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $centerX = $workArea.X + [int](($workArea.Width - $Script:Form.Width) / 2)
    $bottomY = $workArea.Y + $workArea.Height - $Script:Form.Height - 5
    $Script:Form.Location = New-Object System.Drawing.Point($centerX, $bottomY)
} else {
    $Script:Form.Location = New-Object System.Drawing.Point($Script:PosX, $Script:PosY)
}

# === TRAY ICON ===
$Script:Tray = New-Object System.Windows.Forms.NotifyIcon
$Script:Tray.Icon = Create-TrayIcon
$Script:Tray.Text = "CPU Manager"
$Script:Tray.Visible = $true

# === TRAY MENU ===
$Script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip

# Separator style
$menuFont = New-Object System.Drawing.Font("Consolas", 9)
$menuFontBold = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)

# --- Nagłówek ---
$miHeader = New-Object System.Windows.Forms.ToolStripMenuItem
$miHeader.Text = "⚡ CPU Manager"
$miHeader.Font = $menuFontBold
$miHeader.Enabled = $false
$Script:TrayMenu.Items.Add($miHeader) | Out-Null

$Script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# --- Pokaż/Ukryj ---
$miShow = New-Object System.Windows.Forms.ToolStripMenuItem
$miShow.Text = "👁 Pokaż Widget"
$miShow.Font = $menuFont
$miShow.Add_Click({
    $Script:Form.Show()
    $Script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $Script:Form.Activate()
})
$Script:TrayMenu.Items.Add($miShow) | Out-Null

$miHide = New-Object System.Windows.Forms.ToolStripMenuItem
$miHide.Text = "🙈 Ukryj Widget"
$miHide.Font = $menuFont
$miHide.Add_Click({
    $Script:Form.Hide()
})
$Script:TrayMenu.Items.Add($miHide) | Out-Null

$Script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# --- TRIM RAM ---
$miTrimRAM = New-Object System.Windows.Forms.ToolStripMenuItem
$miTrimRAM.Text = "🧹 TRIM RAM"
$miTrimRAM.Font = $menuFontBold
$miTrimRAM.ForeColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
$miTrimRAM.Add_Click({ Invoke-TrimRAM })
$Script:TrayMenu.Items.Add($miTrimRAM) | Out-Null

# --- KILL ALL PowerShell ---
$miKillPS = New-Object System.Windows.Forms.ToolStripMenuItem
$miKillPS.Text = "💀 KILL ALL PowerShell"
$miKillPS.Font = $menuFontBold
$miKillPS.ForeColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
$miKillPS.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Czy na pewno chcesz zamknąć WSZYSTKIE procesy PowerShell?`n`n(Ten widget zostanie zachowany)",
        "Potwierdzenie",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Invoke-KillAllPowerShell
    }
})
$Script:TrayMenu.Items.Add($miKillPS) | Out-Null

$Script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# --- Zamknij ---
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem
$miExit.Text = "❌ Zamknij"
$miExit.Font = $menuFont
$miExit.Add_Click({
    $Script:Tray.Visible = $false
    $Script:Form.Close()
})
$Script:TrayMenu.Items.Add($miExit) | Out-Null

$Script:Tray.ContextMenuStrip = $Script:TrayMenu

# === TRAY EVENTS ===
$Script:Tray.Add_DoubleClick({
    if ($Script:Form.Visible) {
        $Script:Form.Hide()
    } else {
        $Script:Form.Show()
        $Script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $Script:Form.Activate()
    }
})

# === MINIMALIZACJA DO TRAY ===
$Script:Form.Add_Resize({
    if ($Script:Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $Script:Form.Hide()
        $Script:Tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $Script:Tray.BalloonTipTitle = "CPU Manager"
        $Script:Tray.BalloonTipText = "Widget zminimalizowany do tray"
        $Script:Tray.ShowBalloonTip(2000)
    }
})

# === FONT ===
$fontBold = New-Object System.Drawing.Font("Consolas", 8, [System.Drawing.FontStyle]::Bold)
$fontNormal = New-Object System.Drawing.Font("Consolas", 9.5, [System.Drawing.FontStyle]::Regular)
$fontSmall = New-Object System.Drawing.Font("Consolas", 6.5, [System.Drawing.FontStyle]::Regular)
$fontData = New-Object System.Drawing.Font("Consolas", 8.5, [System.Drawing.FontStyle]::Regular)



# === PRZYCISKI OKNA ===
$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Size = New-Object System.Drawing.Size(16, 16)
$btnClose.Location = New-Object System.Drawing.Point(262, 5)
$btnClose.Text = "x"
$btnClose.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
$btnClose.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
$btnClose.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35)
$btnClose.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnClose.FlatAppearance.BorderSize = 0
$btnClose.Add_Click({
    Save-Settings
    $Script:Tray.Visible = $false
    $Script:Form.Close()
})
$btnClose.Add_MouseEnter({ $btnClose.BackColor = [System.Drawing.Color]::FromArgb(192, 57, 43) })
$btnClose.Add_MouseLeave({ $btnClose.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35) })
$Script:Form.Controls.Add($btnClose)

$btnMinimize = New-Object System.Windows.Forms.Button
$btnMinimize.Size = New-Object System.Drawing.Size(16, 16)
$btnMinimize.Location = New-Object System.Drawing.Point(244, 5)
$btnMinimize.Text = "M"
$btnMinimize.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
$btnMinimize.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
$btnMinimize.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35)
$btnMinimize.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnMinimize.FlatAppearance.BorderSize = 0
$btnMinimize.Add_Click({ 
    $Script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
})
$btnMinimize.Add_MouseEnter({ $btnMinimize.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94) })
$btnMinimize.Add_MouseLeave({ $btnMinimize.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35) })
$Script:Form.Controls.Add($btnMinimize)

# === PRZYCISK HALF MODE ===
$Script:BtnHalf = New-Object System.Windows.Forms.Button
$Script:BtnHalf.Size = New-Object System.Drawing.Size(16, 16)
$Script:BtnHalf.Location = New-Object System.Drawing.Point(226, 5)
$Script:BtnHalf.Text = "H"
$Script:BtnHalf.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
$Script:BtnHalf.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
$Script:BtnHalf.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35)
$Script:BtnHalf.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$Script:BtnHalf.FlatAppearance.BorderSize = 0
$Script:BtnHalf.Add_Click({
    $Script:IsHalfMode = -not $Script:IsHalfMode
    
    if ($Script:IsHalfMode) {
        # Tryb HALF - ukryj dolną część, pokaż tylko Free RAM
        $Script:Form.Size = New-Object System.Drawing.Size(280, $Script:HalfHeight)
        $Script:LblGPU.Visible = $false
        $Script:LblGPUTemp.Visible = $false
        $Script:LblGPUClock.Visible = $false
        # W trybie HALF pokazujemy RAM-F (wolne), ukrywamy RAM-U
        $Script:LblRAMTotal.Visible = $true
        $Script:LblRAMUsed.Visible = $false
        $btnVolDown.Visible = $false
        $btnMute.Visible = $false
        $btnVolUp.Visible = $false
        $sep1.Visible = $false
        $btnOpacityDown.Visible = $false
        $lblOpacityVal.Visible = $false
        $btnOpacityUp.Visible = $false
        $sep2.Visible = $false
        $Script:BtnTopMost.Visible = $false
        $Script:BtnHalf.BackColor = [System.Drawing.Color]::FromArgb(155, 89, 182)
    } else {
        # Tryb FULL - pokaż wszystko
        $Script:Form.Size = New-Object System.Drawing.Size(280, $Script:FullHeight)
        $Script:LblGPU.Visible = $true
        $Script:LblGPUTemp.Visible = $true
        $Script:LblGPUClock.Visible = $true
        # W trybie FULL pokaż oba wskaźniki RAM
        $Script:LblRAMTotal.Visible = $true
        $Script:LblRAMUsed.Visible = $true
        $btnVolDown.Visible = $true
        $btnMute.Visible = $true
        $btnVolUp.Visible = $true
        $sep1.Visible = $true
        $btnOpacityDown.Visible = $true
        $lblOpacityVal.Visible = $true
        $btnOpacityUp.Visible = $true
        $sep2.Visible = $true
        $Script:BtnTopMost.Visible = $true
        $Script:BtnHalf.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35)
    }
    Save-Settings
})
$Script:BtnHalf.Add_MouseEnter({ 
    if (-not $Script:IsHalfMode) { $Script:BtnHalf.BackColor = [System.Drawing.Color]::FromArgb(155, 89, 182) }
})
$Script:BtnHalf.Add_MouseLeave({ 
    if (-not $Script:IsHalfMode) { $Script:BtnHalf.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35) }
})
$Script:Form.Controls.Add($Script:BtnHalf)

# === STATUS ENGINE ===
$Script:LblEngineStatus = New-Object System.Windows.Forms.Label
$Script:LblEngineStatus.Size = New-Object System.Drawing.Size(95, 16)
$Script:LblEngineStatus.Location = New-Object System.Drawing.Point(3, 5)
$Script:LblEngineStatus.Text = "---"
$Script:LblEngineStatus.Font = $fontBold
$Script:LblEngineStatus.ForeColor = [System.Drawing.Color]::FromArgb(149, 165, 166)
$Script:LblEngineStatus.BackColor = [System.Drawing.Color]::Transparent
$Script:LblEngineStatus.Add_MouseDown({ Start-FormDrag })
$Script:LblEngineStatus.Add_MouseMove({ Update-FormDrag })
$Script:LblEngineStatus.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblEngineStatus)

# === DISK LED (Read) ===
$Script:LblDiskReadLED = New-Object System.Windows.Forms.Label
$Script:LblDiskReadLED.Text = "●"
$Script:LblDiskReadLED.Location = New-Object System.Drawing.Point(120, 3)
$Script:LblDiskReadLED.Size = New-Object System.Drawing.Size(12, 16)
$Script:LblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(35, 45, 35)
$Script:LblDiskReadLED.BackColor = [System.Drawing.Color]::Transparent
$Script:LblDiskReadLED.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
$Script:LblDiskReadLED.Add_MouseDown({ Start-FormDrag })
$Script:LblDiskReadLED.Add_MouseMove({ Update-FormDrag })
$Script:LblDiskReadLED.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblDiskReadLED)

# === DISK LED (Write) ===
$Script:LblDiskWriteLED = New-Object System.Windows.Forms.Label
$Script:LblDiskWriteLED.Text = "●"
$Script:LblDiskWriteLED.Location = New-Object System.Drawing.Point(135, 3)
$Script:LblDiskWriteLED.Size = New-Object System.Drawing.Size(12, 16)
$Script:LblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(45, 40, 30)
$Script:LblDiskWriteLED.BackColor = [System.Drawing.Color]::Transparent
$Script:LblDiskWriteLED.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
$Script:LblDiskWriteLED.Add_MouseDown({ Start-FormDrag })
$Script:LblDiskWriteLED.Add_MouseMove({ Update-FormDrag })
$Script:LblDiskWriteLED.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblDiskWriteLED)

# === TOOLTIP ===
$Script:ToolTip = New-Object System.Windows.Forms.ToolTip
$Script:ToolTip.SetToolTip($Script:LblDiskReadLED, "Disk Read: 0 MB/s")
$Script:ToolTip.SetToolTip($Script:LblDiskWriteLED, "Disk Write: 0 MB/s")

# Obsługa zmiany przezroczystości rolką myszy, gdy okno jest zawsze na wierzchu
$Script:Form.Add_MouseWheel({
    if ($Script:IsTopMost) {
        $delta = $_.Delta
        if ($delta -gt 0) {
            $Script:Opacity = [Math]::Min($Script:Opacity + 0.05, 1.0)
        } elseif ($delta -lt 0) {
            $Script:Opacity = [Math]::Max($Script:Opacity - 0.05, 0.3)
        }
        $Script:Form.Opacity = $Script:Opacity
    }
})
$Script:ToolTip.SetToolTip($Script:Form, "Rolka myszy: zmiana przezroczystości (tylko gdy zawsze na wierzchu)")

# === ZEGAR ===
$Script:LblClock = New-Object System.Windows.Forms.Label
$Script:LblClock.Size = New-Object System.Drawing.Size(100, 16)
$Script:LblClock.Location = New-Object System.Drawing.Point(155, 5)
$Script:LblClock.Text = "00:00:00"
$Script:LblClock.Font = $fontNormal
$Script:LblClock.ForeColor = [System.Drawing.Color]::White
$Script:LblClock.BackColor = [System.Drawing.Color]::Transparent
$Script:LblClock.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$Script:LblClock.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Start-Process "ms-clock:"
    } else {
        Start-FormDrag
    }
})
$Script:LblClock.Add_MouseMove({ Update-FormDrag })
$Script:LblClock.Add_MouseUp({ Stop-FormDrag })
$Script:ToolTip.SetToolTip($Script:LblClock, "Kliknij, aby otworzyć Zegar i Alarmy Windows")
$Script:Form.Controls.Add($Script:LblClock)

# === INTERNET (Download/Upload) - zawsze delikatna biel ===
$Script:LblNetwork = New-Object System.Windows.Forms.Label
$Script:LblNetwork.Size = New-Object System.Drawing.Size(275, 14)
$Script:LblNetwork.Location = New-Object System.Drawing.Point(3, 24)
$Script:LblNetwork.Text = "↓0KB/s  ↑0KB/s"
$Script:LblNetwork.Font = $fontNormal
$Script:LblNetwork.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
$Script:LblNetwork.BackColor = [System.Drawing.Color]::Transparent
$Script:LblNetwork.Add_MouseDown({ Start-FormDrag })
$Script:LblNetwork.Add_MouseMove({ Update-FormDrag })
$Script:LblNetwork.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblNetwork)

# === CPU LOAD + TEMP + MHz + POWER + TOTAL RAM ===
$Script:LblCPU = New-Object System.Windows.Forms.Label
$Script:LblCPU.Size = New-Object System.Drawing.Size(58, 14)
$Script:LblCPU.Location = New-Object System.Drawing.Point(3, 40)
$Script:LblCPU.Text = "CPU: 0%"
$Script:LblCPU.Font = $fontData
$Script:LblCPU.ForeColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
$Script:LblCPU.BackColor = [System.Drawing.Color]::Transparent
$Script:LblCPU.Add_MouseDown({ Start-FormDrag })
$Script:LblCPU.Add_MouseMove({ Update-FormDrag })
$Script:LblCPU.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblCPU)

$Script:LblCPUTemp = New-Object System.Windows.Forms.Label
$Script:LblCPUTemp.Size = New-Object System.Drawing.Size(36, 14)
$Script:LblCPUTemp.Location = New-Object System.Drawing.Point(62, 40)
$Script:LblCPUTemp.Text = "0°C"
$Script:LblCPUTemp.Font = $fontData
$Script:LblCPUTemp.ForeColor = [System.Drawing.Color]::FromArgb(241, 196, 15)
$Script:LblCPUTemp.BackColor = [System.Drawing.Color]::Transparent
$Script:LblCPUTemp.Add_MouseDown({ Start-FormDrag })
$Script:LblCPUTemp.Add_MouseMove({ Update-FormDrag })
$Script:LblCPUTemp.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblCPUTemp)

$Script:LblCPUMHz = New-Object System.Windows.Forms.Label
$Script:LblCPUMHz.Size = New-Object System.Drawing.Size(55, 14)
$Script:LblCPUMHz.Location = New-Object System.Drawing.Point(99, 40)
$Script:LblCPUMHz.Text = "----MHz"
$Script:LblCPUMHz.Font = $fontData
$Script:LblCPUMHz.ForeColor = [System.Drawing.Color]::White
$Script:LblCPUMHz.BackColor = [System.Drawing.Color]::Transparent
$Script:LblCPUMHz.Add_MouseDown({ Start-FormDrag })
$Script:LblCPUMHz.Add_MouseMove({ Update-FormDrag })
$Script:LblCPUMHz.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblCPUMHz)

$Script:LblCPUPower = New-Object System.Windows.Forms.Label
$Script:LblCPUPower.Size = New-Object System.Drawing.Size(38, 14)
$Script:LblCPUPower.Location = New-Object System.Drawing.Point(155, 40)
$Script:LblCPUPower.Text = "--W"
$Script:LblCPUPower.Font = $fontData
$Script:LblCPUPower.ForeColor = [System.Drawing.Color]::FromArgb(230, 126, 34)
$Script:LblCPUPower.BackColor = [System.Drawing.Color]::Transparent
$Script:LblCPUPower.Add_MouseDown({ Start-FormDrag })
$Script:LblCPUPower.Add_MouseMove({ Update-FormDrag })
$Script:LblCPUPower.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblCPUPower)

$Script:LblRAMTotal = New-Object System.Windows.Forms.Label
$Script:LblRAMTotal.Size = New-Object System.Drawing.Size(82, 14)
$Script:LblRAMTotal.Location = New-Object System.Drawing.Point(194, 40)
$Script:LblRAMTotal.Text = "RAM-F:--GB"
$Script:LblRAMTotal.Font = $fontData
$Script:LblRAMTotal.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
$Script:LblRAMTotal.BackColor = [System.Drawing.Color]::Transparent
$Script:LblRAMTotal.Add_MouseDown({ Start-FormDrag })
$Script:LblRAMTotal.Add_MouseMove({ Update-FormDrag })
$Script:LblRAMTotal.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblRAMTotal)

# === GPU LOAD + TEMP + CLOCK + USED RAM ===
$Script:LblGPU = New-Object System.Windows.Forms.Label
$Script:LblGPU.Size = New-Object System.Drawing.Size(58, 14)
$Script:LblGPU.Location = New-Object System.Drawing.Point(3, 56)
$Script:LblGPU.Text = "GPU: --"
$Script:LblGPU.Font = $fontData
$Script:LblGPU.ForeColor = [System.Drawing.Color]::FromArgb(52, 152, 219)
$Script:LblGPU.BackColor = [System.Drawing.Color]::Transparent
$Script:LblGPU.Add_MouseDown({ Start-FormDrag })
$Script:LblGPU.Add_MouseMove({ Update-FormDrag })
$Script:LblGPU.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblGPU)

$Script:LblGPUTemp = New-Object System.Windows.Forms.Label
$Script:LblGPUTemp.Size = New-Object System.Drawing.Size(36, 14)
$Script:LblGPUTemp.Location = New-Object System.Drawing.Point(62, 56)
$Script:LblGPUTemp.Text = "--°C"
$Script:LblGPUTemp.Font = $fontData
$Script:LblGPUTemp.ForeColor = [System.Drawing.Color]::FromArgb(52, 152, 219)
$Script:LblGPUTemp.BackColor = [System.Drawing.Color]::Transparent
$Script:LblGPUTemp.Add_MouseDown({ Start-FormDrag })
$Script:LblGPUTemp.Add_MouseMove({ Update-FormDrag })
$Script:LblGPUTemp.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblGPUTemp)

$Script:LblGPUClock = New-Object System.Windows.Forms.Label
$Script:LblGPUClock.Size = New-Object System.Drawing.Size(55, 14)
$Script:LblGPUClock.Location = New-Object System.Drawing.Point(99, 56)
$Script:LblGPUClock.Text = "----MHz"
$Script:LblGPUClock.Font = $fontData
$Script:LblGPUClock.ForeColor = [System.Drawing.Color]::FromArgb(52, 152, 219)
$Script:LblGPUClock.BackColor = [System.Drawing.Color]::Transparent
$Script:LblGPUClock.Add_MouseDown({ Start-FormDrag })
$Script:LblGPUClock.Add_MouseMove({ Update-FormDrag })
$Script:LblGPUClock.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblGPUClock)

$Script:LblRAMUsed = New-Object System.Windows.Forms.Label
$Script:LblRAMUsed.Size = New-Object System.Drawing.Size(82, 14)
$Script:LblRAMUsed.Location = New-Object System.Drawing.Point(194, 56)
$Script:LblRAMUsed.Text = "RAM-U:--GB"
$Script:LblRAMUsed.Font = $fontData
$Script:LblRAMUsed.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
$Script:LblRAMUsed.BackColor = [System.Drawing.Color]::Transparent
$Script:LblRAMUsed.Add_MouseDown({ Start-FormDrag })
$Script:LblRAMUsed.Add_MouseMove({ Update-FormDrag })
$Script:LblRAMUsed.Add_MouseUp({ Stop-FormDrag })
$Script:Form.Controls.Add($Script:LblRAMUsed)

# === DODAJ OBSŁUGĘ KLIKNIĘCIA NA CPU I GPU ===
# TERAZ TO JEST W ODPOWIEDNIM MIEJSCU - PO UTWORZENIU KONTROLEK
$Script:ToolTip.SetToolTip($Script:LblCPU, "Kliknij, aby otworzyć Menedżer zadań Windows")
$Script:ToolTip.SetToolTip($Script:LblGPU, "Kliknij, aby otworzyć Menedżer zadań Windows")

$Script:LblCPU.Add_Click({
    try { Start-Process taskmgr } catch {}
})
$Script:LblGPU.Add_Click({
    try { Start-Process taskmgr } catch {}
})

# === KONTROLKI (Volume + Opacity + TopMost) ===
$yControl = 74

# Volume Down
$btnVolDown = New-Object System.Windows.Forms.Button
$btnVolDown.Size = New-Object System.Drawing.Size(35, 20)
$btnVolDown.Location = New-Object System.Drawing.Point(3, $yControl)
$btnVolDown.Text = "V-"
$btnVolDown.Font = $fontSmall
$btnVolDown.ForeColor = [System.Drawing.Color]::White
$btnVolDown.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
$btnVolDown.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnVolDown.FlatAppearance.BorderSize = 0
$btnVolDown.Add_Click({ Set-VolumeDown })
$btnVolDown.Add_MouseEnter({ $btnVolDown.BackColor = [System.Drawing.Color]::FromArgb(41, 128, 185) })
$btnVolDown.Add_MouseLeave({ $btnVolDown.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94) })
$Script:Form.Controls.Add($btnVolDown)

# Mute
$btnMute = New-Object System.Windows.Forms.Button
$btnMute.Size = New-Object System.Drawing.Size(35, 20)
$btnMute.Location = New-Object System.Drawing.Point(41, $yControl)
$btnMute.Text = "M"
$btnMute.Font = $fontSmall
$btnMute.ForeColor = [System.Drawing.Color]::White
$btnMute.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
$btnMute.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnMute.FlatAppearance.BorderSize = 0
$btnMute.Add_Click({ Set-VolumeMute })
$btnMute.Add_MouseEnter({ $btnMute.BackColor = [System.Drawing.Color]::FromArgb(41, 128, 185) })
$btnMute.Add_MouseLeave({ $btnMute.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94) })
$Script:Form.Controls.Add($btnMute)

# Volume Up
$btnVolUp = New-Object System.Windows.Forms.Button
$btnVolUp.Size = New-Object System.Drawing.Size(35, 20)
$btnVolUp.Location = New-Object System.Drawing.Point(79, $yControl)
$btnVolUp.Text = "V+"
$btnVolUp.Font = $fontSmall
$btnVolUp.ForeColor = [System.Drawing.Color]::White
$btnVolUp.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
$btnVolUp.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnVolUp.FlatAppearance.BorderSize = 0
$btnVolUp.Add_Click({ Set-VolumeUp })
$btnVolUp.Add_MouseEnter({ $btnVolUp.BackColor = [System.Drawing.Color]::FromArgb(41, 128, 185) })
$btnVolUp.Add_MouseLeave({ $btnVolUp.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94) })
$Script:Form.Controls.Add($btnVolUp)

# Separator
$sep1 = New-Object System.Windows.Forms.Label
$sep1.Size = New-Object System.Drawing.Size(2, 20)
$sep1.Location = New-Object System.Drawing.Point(118, $yControl)
$sep1.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$Script:Form.Controls.Add($sep1)

# Opacity -
$btnOpacityDown = New-Object System.Windows.Forms.Button
$btnOpacityDown.Size = New-Object System.Drawing.Size(30, 20)
$btnOpacityDown.Location = New-Object System.Drawing.Point(123, $yControl)
$btnOpacityDown.Text = "O-"
$btnOpacityDown.Font = $fontSmall
$btnOpacityDown.ForeColor = [System.Drawing.Color]::White
$btnOpacityDown.BackColor = [System.Drawing.Color]::FromArgb(44, 62, 80)
$btnOpacityDown.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnOpacityDown.FlatAppearance.BorderSize = 0
$btnOpacityDown.Add_Click({
    $Script:Opacity = [Math]::Max(0.2, $Script:Opacity - 0.05)
    $Script:Form.Opacity = $Script:Opacity
    $lblOpacityVal.Text = "{0:P0}" -f $Script:Opacity
    Save-Settings
})
$btnOpacityDown.Add_MouseEnter({ $btnOpacityDown.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94) })
$btnOpacityDown.Add_MouseLeave({ $btnOpacityDown.BackColor = [System.Drawing.Color]::FromArgb(44, 62, 80) })
$Script:Form.Controls.Add($btnOpacityDown)

# Opacity Value Display
$lblOpacityVal = New-Object System.Windows.Forms.Label
$lblOpacityVal.Size = New-Object System.Drawing.Size(38, 20)
$lblOpacityVal.Location = New-Object System.Drawing.Point(155, $yControl)
$lblOpacityVal.Text = "{0:P0}" -f $Script:Opacity
$lblOpacityVal.Font = $fontSmall
$lblOpacityVal.ForeColor = [System.Drawing.Color]::FromArgb(189, 195, 199)
$lblOpacityVal.BackColor = [System.Drawing.Color]::Transparent
$lblOpacityVal.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$Script:Form.Controls.Add($lblOpacityVal)

# Opacity +
$btnOpacityUp = New-Object System.Windows.Forms.Button
$btnOpacityUp.Size = New-Object System.Drawing.Size(30, 20)
$btnOpacityUp.Location = New-Object System.Drawing.Point(195, $yControl)
$btnOpacityUp.Text = "O+"
$btnOpacityUp.Font = $fontSmall
$btnOpacityUp.ForeColor = [System.Drawing.Color]::White
$btnOpacityUp.BackColor = [System.Drawing.Color]::FromArgb(44, 62, 80)
$btnOpacityUp.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnOpacityUp.FlatAppearance.BorderSize = 0
$btnOpacityUp.Add_Click({
    $Script:Opacity = [Math]::Min(1.0, $Script:Opacity + 0.05)
    $Script:Form.Opacity = $Script:Opacity
    $lblOpacityVal.Text = "{0:P0}" -f $Script:Opacity
    Save-Settings
})
$btnOpacityUp.Add_MouseEnter({ $btnOpacityUp.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94) })
$btnOpacityUp.Add_MouseLeave({ $btnOpacityUp.BackColor = [System.Drawing.Color]::FromArgb(44, 62, 80) })
$Script:Form.Controls.Add($btnOpacityUp)

# Separator 2
$sep2 = New-Object System.Windows.Forms.Label
$sep2.Size = New-Object System.Drawing.Size(2, 20)
$sep2.Location = New-Object System.Drawing.Point(228, $yControl)
$sep2.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$Script:Form.Controls.Add($sep2)

# TopMost Toggle
$Script:BtnTopMost = New-Object System.Windows.Forms.Button
$Script:BtnTopMost.Size = New-Object System.Drawing.Size(45, 20)
$Script:BtnTopMost.Location = New-Object System.Drawing.Point(233, $yControl)
$Script:BtnTopMost.Text = if ($Script:IsTopMost) { "OP-ON" } else { "OP-OFF" }
$Script:BtnTopMost.Font = $fontSmall
$Script:BtnTopMost.ForeColor = [System.Drawing.Color]::White
$Script:BtnTopMost.BackColor = if ($Script:IsTopMost) { [System.Drawing.Color]::FromArgb(39, 174, 96) } else { [System.Drawing.Color]::FromArgb(127, 140, 141) }
$Script:BtnTopMost.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$Script:BtnTopMost.FlatAppearance.BorderSize = 0
$Script:BtnTopMost.Add_Click({
    $Script:IsTopMost = -not $Script:IsTopMost
    $Script:Form.TopMost = $Script:IsTopMost
    $Script:BtnTopMost.Text = if ($Script:IsTopMost) { "OP-ON" } else { "OP-OFF" }
    $Script:BtnTopMost.BackColor = if ($Script:IsTopMost) { [System.Drawing.Color]::FromArgb(39, 174, 96) } else { [System.Drawing.Color]::FromArgb(127, 140, 141) }
    Save-Settings
})
$Script:Form.Controls.Add($Script:BtnTopMost)

# === TIMER ===
$Script:Timer = New-Object System.Windows.Forms.Timer
$Script:Timer.Interval = 100  # 100ms dla płynnego migania LED dysków
$Script:TickCounter = 0

$Script:Timer.Add_Tick({
    try {
        $Script:TickCounter++
        $now = [DateTime]::Now
        
        # === AKTUALIZACJA LED DYSKU (co 100ms dla płynnego migania) ===
        if ($Script:DiskCountersAvailable) {
            try {
                $readBytes = $Script:perfDiskRead.NextValue()
                $writeBytes = $Script:perfDiskWrite.NextValue()
                
                # Próg aktywności: 1MB/s = 1048576 bytes/sec
                $readThreshold = 1048576
                $writeThreshold = 1048576
                
                # Przedłuż czas aktywności jeśli przekroczono próg
                if ($readBytes -gt $readThreshold) {
                    $Script:DiskReadActiveUntil = $now.AddMilliseconds(350)
                }
                if ($writeBytes -gt $writeThreshold) {
                    $Script:DiskWriteActiveUntil = $now.AddMilliseconds(350)
                }
                
                # === READ LED - miganie zielone ===
                if ($now -lt $Script:DiskReadActiveUntil) {
                    $Script:ReadLedBlinkState = -not $Script:ReadLedBlinkState
                    if ($Script:ReadLedBlinkState) {
                        $Script:LblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(0, 255, 80)  # Jasny zielony
                    } else {
                        $Script:LblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 40)  # Ciemniejszy zielony
                    }
                } else {
                    $Script:LblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(35, 45, 35)  # Off
                }
                
                # === WRITE LED - miganie pomarańczowe ===
                if ($now -lt $Script:DiskWriteActiveUntil) {
                    $Script:WriteLedBlinkState = -not $Script:WriteLedBlinkState
                    if ($Script:WriteLedBlinkState) {
                        $Script:LblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(255, 165, 0)  # Pomarańczowy
                    } else {
                        $Script:LblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(140, 90, 0)  # Ciemniejszy pomarańczowy
                    }
                } else {
                    $Script:LblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(45, 40, 30)  # Off
                }
                
                # Aktualizuj tooltip z aktualnymi wartościami
                $readMB = [Math]::Round($readBytes / 1048576, 2)
                $writeMB = [Math]::Round($writeBytes / 1048576, 2)
                $Script:ToolTip.SetToolTip($Script:LblDiskReadLED, "Disk Read: $readMB MB/s")
                $Script:ToolTip.SetToolTip($Script:LblDiskWriteLED, "Disk Write: $writeMB MB/s")
                
            } catch {
                $Script:LblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(60, 30, 30)  # Błąd
                $Script:LblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(60, 30, 30)
            }
        }
        
        # === RESZTA AKTUALIZACJI CO 1 SEKUNDĘ (co 10 ticków) ===
        if ($Script:TickCounter % 10 -ne 0) { return }
        
        # Aktualizacja zegara
        $Script:LblClock.Text = $now.ToString("HH:mm:ss")
        
        # Pobierz dane z OHM/LHM
        $hmData = Get-HardwareMonitorData
        
        # Pobierz dane RAM z WMI
        $ramInfo = Get-RAMInfo
        
        # Aktualizuj tooltip ikony tray
        $Script:Tray.Text = "CPU Manager`nCPU: $($Script:LblCPU.Text)`nRAM: $($ramInfo.Used)/$($ramInfo.Total) GB"
        
        # Odczytaj dane ENGINE z WidgetData.json
        if (Test-Path $Script:DataFile) {
            try {
                $data = Get-Content $Script:DataFile -Raw -ErrorAction Stop | ConvertFrom-Json
                
                # Pobierz Mode i AI z danych ENGINE
                $newMode = if ($data.Mode) { $data.Mode } else { "---" }
                $newAI = if ($data.AI) { $data.AI } else { "OFF" }
                
                # Wykryj zmianę trybu
                if ($newMode -ne $Script:EngineMode -or $newAI -ne $Script:EngineAI) {
                    $Script:EngineMode = $newMode
                    $Script:EngineAI = $newAI

                }
                
                # Wyświetl status
                if ($Script:EngineAI -eq "ON") {
                    $Script:LblEngineStatus.Text = "$($Script:EngineMode) [AI]"
                } else {
                    $Script:LblEngineStatus.Text = $Script:EngineMode
                }
                
                # Kolor tekstu w zależności od trybu
                switch ($Script:EngineMode) {
                    "TURBO" { $Script:LblEngineStatus.ForeColor = [System.Drawing.Color]::FromArgb(231, 76, 60) }
                    "BALANCED" { $Script:LblEngineStatus.ForeColor = [System.Drawing.Color]::FromArgb(241, 196, 15) }
                    "SILENT" { $Script:LblEngineStatus.ForeColor = [System.Drawing.Color]::FromArgb(46, 204, 113) }
                    "ECO" { $Script:LblEngineStatus.ForeColor = [System.Drawing.Color]::FromArgb(26, 188, 156) }
                    default { $Script:LblEngineStatus.ForeColor = [System.Drawing.Color]::FromArgb(149, 165, 166) }
                }
                
                # CPU Temp - preferuj OHM/LHM, potem WidgetData
                if ($hmData -and $hmData.Temp -gt 0) {
                    $cpuTemp = [int]$hmData.Temp
                } else {
                    $cpuTemp = if ($data.Temp) { [int]$data.Temp } else { 0 }
                }
                
                if ($cpuTemp -gt 0) {
                    $Script:LblCPUTemp.Text = "${cpuTemp}°C"
                    $Script:LblCPUTemp.ForeColor = if ($cpuTemp -gt 80) { 
                        [System.Drawing.Color]::FromArgb(231, 76, 60) 
                    } elseif ($cpuTemp -gt 65) { 
                        [System.Drawing.Color]::FromArgb(230, 126, 34) 
                    } else { 
                        [System.Drawing.Color]::FromArgb(46, 204, 113) 
                    }
                } else {
                    $Script:LblCPUTemp.Text = "--°C"
                    $Script:LblCPUTemp.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
                }
                
            } catch {
                $Script:LblEngineStatus.Text = "ERROR"
                $Script:LblEngineStatus.ForeColor = [System.Drawing.Color]::FromArgb(231, 76, 60)

            }
        } else {
            $Script:LblEngineStatus.Text = "OFF"
            $Script:LblEngineStatus.ForeColor = [System.Drawing.Color]::FromArgb(149, 165, 166)

        }
        
        # CPU MHz z OHM/LHM
        if ($hmData -and $hmData.CpuMHz -gt 0) {
            $cpuMHz = [int]$hmData.CpuMHz
            $cpuGHz = [math]::Round($cpuMHz / 1000, 2)
            $Script:LblCPUMHz.Text = "${cpuGHz} GHz"
        } else {
            $Script:LblCPUMHz.Text = "---- GHz"
        }
        $Script:LblCPUMHz.ForeColor = [System.Drawing.Color]::White
        
        # CPU Power z OHM/LHM
        if ($hmData -and $hmData.CpuPower -gt 0) {
            $cpuPower = [int]$hmData.CpuPower
            $Script:LblCPUPower.Text = "${cpuPower}W"
            if ($cpuPower -gt 80) {
                $Script:LblCPUPower.ForeColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
            } elseif ($cpuPower -gt 45) {
                $Script:LblCPUPower.ForeColor = [System.Drawing.Color]::FromArgb(230, 126, 34)
            } else {
                $Script:LblCPUPower.ForeColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
            }
        } else {
            $Script:LblCPUPower.Text = "--W"
            $Script:LblCPUPower.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
        }
        
        # Free and Used RAM with gradient coloring
        $totalRam = $ramInfo.Total
        if ($totalRam -gt 0) {
            $freePct = [math]::Round(($ramInfo.Free / $totalRam) * 100, 1)
            $usedPct = [math]::Round(($ramInfo.Used / $totalRam) * 100, 1)

            if ($ramInfo.Free -gt 0) {
                $Script:LblRAMTotal.Text = "RAM-F:$($ramInfo.Free)GB"
            } else {
                $Script:LblRAMTotal.Text = "RAM-F:--GB"
            }

            if ($ramInfo.Used -gt 0) {
                $Script:LblRAMUsed.Text = "RAM-U:$($ramInfo.Used)GB"
            } else {
                $Script:LblRAMUsed.Text = "RAM-U:--GB"
            }

            # Dla Free RAM inwertujemy procent (im mniej wolnego, tym bardziej "zly")
            $freeBadness = 100.0 - $freePct
            $colorFree = Get-GradientColor $freeBadness
            $colorUsed = Get-GradientColor $usedPct

            $Script:LblRAMTotal.ForeColor = $colorFree
            $Script:LblRAMUsed.ForeColor = $colorUsed
        } else {
            $Script:LblRAMTotal.Text = "RAM-F:--GB"
            $Script:LblRAMTotal.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
            $Script:LblRAMUsed.Text = "RAM-U:--GB"
            $Script:LblRAMUsed.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
        }
        
        # GPU - sprawdź OHM/LHM najpierw, potem WMI fallback
        $gpuLoad = 0
        $gpuTemp = 0
        $gpuClock = 0
        $gpuDataAvailable = $false
        
        # Próba 1: OHM/LHM (priorytet) - jeśli $hmData istnieje, zawsze zawiera GPULoad/GPUTemp/GPUClock (minimum 0)
        if ($hmData) {
            $gpuLoad = [int]$hmData.GPULoad
            $gpuTemp = [int]$hmData.GPUTemp
            $gpuClock = [int]$hmData.GPUClock
            
            # Sprawdź czy mamy jakiekolwiek dane GPU (Load>0 lub Clock>0, Temp może być 0 dla niektórych GPU)
            if ($gpuLoad -gt 0 -or $gpuClock -gt 0 -or $gpuTemp -gt 0) {
                $gpuDataAvailable = $true
            }
        }
        
        # Próba 2: Fallback do WMI Win32_VideoController (jeśli OHM/LHM nie ma danych)
        if (-not $gpuDataAvailable) {
            try {
                $gpu = Get-WmiObject -Class Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($gpu) {
                    # WMI nie daje Load/Temp bezpośrednio, ale możemy użyć Win32_PerfFormattedData_GPUPerformanceCounters
                    try {
                        $gpuPerf = Get-Counter "\GPU Engine(*)\Utilization Percentage" -ErrorAction SilentlyContinue
                        if ($gpuPerf) {
                            $gpuLoad = [int]($gpuPerf.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum
                            $gpuDataAvailable = $true
                        }
                    } catch { }
                    
                    # Jeśli nadal brak danych ale GPU istnieje, oznacz jako dostępny
                    if (-not $gpuDataAvailable) {
                        $gpuDataAvailable = $true
                    }
                }
            } catch { }
        }
        
        # Wyświetl dane GPU
        if ($gpuDataAvailable) {
            # GPU Load
            $Script:LblGPU.Text = "GPU: $gpuLoad%"
            $Script:LblGPU.ForeColor = if ($gpuLoad -gt 80) { 
                [System.Drawing.Color]::FromArgb(231, 76, 60) 
            } elseif ($gpuLoad -gt 50) { 
                [System.Drawing.Color]::FromArgb(230, 126, 34) 
            } else { 
                [System.Drawing.Color]::FromArgb(52, 152, 219) 
            }
            
            # GPU Temp
            if ($gpuTemp -gt 0) {
                $Script:LblGPUTemp.Text = "${gpuTemp}°C"
                $Script:LblGPUTemp.ForeColor = if ($gpuTemp -gt 85) { 
                    [System.Drawing.Color]::FromArgb(231, 76, 60) 
                } elseif ($gpuTemp -gt 70) { 
                    [System.Drawing.Color]::FromArgb(230, 126, 34) 
                } else { 
                    [System.Drawing.Color]::FromArgb(52, 152, 219) 
                }
            } else {
                $Script:LblGPUTemp.Text = "--°C"
                $Script:LblGPUTemp.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
            }
            
            # GPU Clock
            if ($gpuClock -gt 0) {
                $Script:LblGPUClock.Text = "${gpuClock}MHz"
                $Script:LblGPUClock.ForeColor = [System.Drawing.Color]::FromArgb(52, 152, 219)
            } else {
                $Script:LblGPUClock.Text = "----MHz"
                $Script:LblGPUClock.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
            }
        } else {
            # Brak danych GPU
            $Script:LblGPU.Text = "GPU: N/A"
            $Script:LblGPU.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
            $Script:LblGPUTemp.Text = "N/A"
            $Script:LblGPUTemp.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
            $Script:LblGPUClock.Text = "N/A"
            $Script:LblGPUClock.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 110)
        }
        
        # Internet Speed - zawsze delikatna biel
        if ($Script:NetworkCountersAvailable) {
            try {
                # Pobierz aktualny ruch sieciowy z CIM
                $currentTime = [DateTime]::Now
                $timeDiff = ($currentTime - $Script:LastNetworkCheck).TotalSeconds
                
                if ($timeDiff -ge 1) {
                    # Znajdź ten sam adapter lub najbardziej aktywny
                    if ($Script:LastAdapterName) {
                        $adapters = Get-CimInstance -ClassName Win32_PerfRawData_Tcpip_NetworkInterface | 
                                    Where-Object { $_.Name -eq $Script:LastAdapterName } |
                                    Select-Object -First 1
                    }
                    
                    # Jeśli nie znaleziono tego samego adaptera, znajdź najbardziej aktywny
                    if (-not $adapters) {
                        $adapters = Get-CimInstance -ClassName Win32_PerfRawData_Tcpip_NetworkInterface | 
                                    Where-Object { $_.Name -notmatch 'Loopback|isatap|Teredo|6to4' } |
                                    Sort-Object BytesReceivedPersec -Descending |
                                    Select-Object -First 1
                        if ($adapters) {
                            $Script:LastAdapterName = $adapters.Name
                            $Script:LastBytesReceived = [int64]$adapters.BytesReceivedPersec
                            $Script:LastBytesSent = [int64]$adapters.BytesSentPersec
                            $Script:LastNetworkCheck = $currentTime
                        }
                    }
                    
                    if ($adapters) {
                        $currentBytesReceived = [int64]$adapters.BytesReceivedPersec
                        $currentBytesSent = [int64]$adapters.BytesSentPersec
                        
                        # Oblicz różnicę (bajty kumulatywne) i przelicz na prędkość per sekunda
                        $byteDiffReceived = $currentBytesReceived - $Script:LastBytesReceived
                        $byteDiffSent = $currentBytesSent - $Script:LastBytesSent
                        
                        # Zabezpieczenie przed ujemnymi wartościami (restart adaptera lub overflow)
                        if ($byteDiffReceived -lt 0 -or $byteDiffSent -lt 0) {
                            # Reset wartości po restarcie adaptera
                            $Script:LastBytesReceived = $currentBytesReceived
                            $Script:LastBytesSent = $currentBytesSent
                            $Script:LastNetworkCheck = $currentTime
                            $byteDiffReceived = 0
                            $byteDiffSent = 0
                        }
                        
                        # Przelicz na bajty per sekunda
                        $downloadBytes = $byteDiffReceived / $timeDiff
                        $uploadBytes = $byteDiffSent / $timeDiff
                        
                        $Script:LastBytesReceived = $currentBytesReceived
                        $Script:LastBytesSent = $currentBytesSent
                        $Script:LastNetworkCheck = $currentTime
                        
                        $dlSpeed = Format-NetworkSpeed $downloadBytes
                        $ulSpeed = Format-NetworkSpeed $uploadBytes
                    } else {
                        $dlSpeed = "0KB/s"
                        $ulSpeed = "0KB/s"
                    }
                } else {
                    # Użyj poprzednich wartości jeśli nie minęła sekunda
                    $dlSpeed = $Script:LblNetwork.Text -replace '.*↓([^ ]+).*', '$1'
                    $ulSpeed = $Script:LblNetwork.Text -replace '.*↑([^ ]+).*', '$1'
                    if (-not $dlSpeed) { $dlSpeed = "0KB/s" }
                    if (-not $ulSpeed) { $ulSpeed = "0KB/s" }
                }

                # Pobierz ping do 8.8.8.8 (Google DNS)
                try {
                    # Pobierz pierwszy aktywny adres DNS z systemu
                    $dnsServers = (Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses -and $_.ServerAddresses.Count -gt 0 }).ServerAddresses
                    $dnsToPing = $dnsServers | Where-Object { $_ -match '^(?!0+\.)' } | Select-Object -First 1
                    if (-not $dnsToPing) { $dnsToPing = '8.8.8.8' } # fallback
                    $pingSender = New-Object System.Net.NetworkInformation.Ping
                    $reply = $pingSender.Send($dnsToPing, 1000)
                    if ($reply.Status -eq 'Success') {
                        $pingMs = $reply.RoundtripTime
                    } else {
                        $pingMs = $null
                    }
                } catch { $pingMs = $null }

                if ($pingMs -ne $null) {
                    $Script:LblNetwork.Text = "↓$dlSpeed  ↑$ulSpeed  $pingMs ms"
                } else {
                    $Script:LblNetwork.Text = "↓$dlSpeed  ↑$ulSpeed  N/A ms"
                }
                $Script:LblNetwork.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
            } catch {
                $Script:LblNetwork.Text = "↓N/A  ↑N/A  N/A ms"
                $Script:LblNetwork.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
            }
        } else {
            $Script:LblNetwork.Text = "↓N/A  ↑N/A"
            $Script:LblNetwork.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 185)
        }
        
        # CPU Load z performance counter
        if ($Script:CPUCounterAvailable) {
            try {
                $cpuLoad = [Math]::Round($Script:perfCPU.NextValue(), 0)
                $Script:LblCPU.Text = "CPU: $cpuLoad%"
                
                if ($cpuLoad -gt 80) {
                    $Script:LblCPU.ForeColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
                } elseif ($cpuLoad -gt 50) {
                    $Script:LblCPU.ForeColor = [System.Drawing.Color]::FromArgb(230, 126, 34)
                } else {
                    $Script:LblCPU.ForeColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
                }
            } catch {
                $Script:LblCPU.Text = "CPU: N/A"
            }
        }
        
        # Wymuszenie TopMost
        if ($Script:IsTopMost) {
            try {
                [CompactMon.Win32]::SetWindowPos(
                    $Script:Form.Handle,
                    [CompactMon.Win32]::HWND_TOPMOST,
                    0, 0, 0, 0,
                    [CompactMon.Win32]::SWP_NOMOVE -bor [CompactMon.Win32]::SWP_NOSIZE -bor [CompactMon.Win32]::SWP_NOACTIVATE
                ) | Out-Null
            } catch {}
        }
        
    } catch {
        # Ignoruj błędy w timerze
    }
})

$Script:Timer.Start()

# === INICJALIZACJA HALF MODE (jeśli zapisano) ===
if ($Script:IsHalfMode) {
    $Script:Form.Size = New-Object System.Drawing.Size(280, $Script:HalfHeight)
    $Script:LblGPU.Visible = $false
    $Script:LblGPUTemp.Visible = $false
    $Script:LblGPUClock.Visible = $false
    # Pokaż Free RAM w trybie HALF, ukryj Used
    $Script:LblRAMTotal.Visible = $true
    $Script:LblRAMUsed.Visible = $false
    $btnVolDown.Visible = $false
    $btnMute.Visible = $false
    $btnVolUp.Visible = $false
    $sep1.Visible = $false
    $btnOpacityDown.Visible = $false
    $lblOpacityVal.Visible = $false
    $btnOpacityUp.Visible = $false
    $sep2.Visible = $false
    $Script:BtnTopMost.Visible = $false
    $Script:BtnHalf.BackColor = [System.Drawing.Color]::FromArgb(155, 89, 182)
}

# === CLEANUP ===
$Script:Form.Add_FormClosing({
    try { $Script:Timer.Stop(); $Script:Timer.Dispose() } catch {}
    try { if ($Script:perfCPU) { $Script:perfCPU.Dispose() } } catch {}
    try { if ($Script:perfDiskRead) { $Script:perfDiskRead.Dispose() } } catch {}
    try { if ($Script:perfDiskWrite) { $Script:perfDiskWrite.Dispose() } } catch {}
    try { if ($Script:ToolTip) { $Script:ToolTip.Dispose() } } catch {}
    try { $Script:Tray.Visible = $false; $Script:Tray.Dispose() } catch {}
    Save-Settings
    if (Test-Path $Script:PidFile) { Remove-Item $Script:PidFile -Force -ErrorAction SilentlyContinue }
})

# Uruchom formę
[System.Windows.Forms.Application]::Run($Script:Form)
