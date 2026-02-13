# ═══════════════════════════════════════════════════════════════════════════════
# CPU Manager AI - Mini Widget v34.2
# Kompaktowy widget z regulacją głośności, trybami pracy i wyborem silników AI
# NOWE: Kontrolki aktywności dysku (LED Read/Write)
# ═══════════════════════════════════════════════════════════════════════════════

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

# === WIN32 API (ukrycie konsoli + fullscreen + detekcja) ===
Add-Type -Name Win32 -Namespace MiniWidget -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

[StructLayout(LayoutKind.Sequential)]
public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
public const uint SWP_NOMOVE = 0x0002;
public const uint SWP_NOSIZE = 0x0001;
public const uint SWP_NOACTIVATE = 0x0010;
public const int GWL_STYLE = -16;
public const int GWL_EXSTYLE = -20;
'@ -ErrorAction SilentlyContinue

# Ukryj konsolę
try { [MiniWidget.Win32]::ShowWindow([MiniWidget.Win32]::GetConsoleWindow(), 0) | Out-Null } catch {}

# === ŚCIEŻKI ===
$Script:BaseDir = "C:\CPUManager"
$Script:DataFile = "$Script:BaseDir\WidgetData.json"
$Script:CommandFile = "$Script:BaseDir\WidgetCommand.txt"
$Script:MiniCommandFile = "$Script:BaseDir\MiniWidgetCommand.txt"
$Script:SettingsFile = "$Script:BaseDir\MiniWidgetSettings.json"
$Script:AIEnginesFile = "$Script:BaseDir\AIEngines.json"
$Script:HelpFile = "$Script:BaseDir\INSTRUKCJA.txt"
$Script:PidFile = "$Script:BaseDir\MiniWidget.pid"

# Utwórz folder jeśli nie istnieje
if (-not (Test-Path $Script:BaseDir)) { New-Item -Path $Script:BaseDir -ItemType Directory -Force | Out-Null }

# Zapisz PID
$PID | Set-Content $Script:PidFile -Force -ErrorAction SilentlyContinue

# === STAN APLIKACJI ===
$Script:IsMuted = $false
$Script:Opacity = 0.95
$Script:IsTopMost = $true
$Script:PosX = -1
$Script:PosY = 5
$Script:CurrentMode = "---"
$Script:AIStatus = "OFF"
$Script:GPULoadOHM = 0
$Script:IsFullscreenActive = $false
$Script:LastMode = "---"
$Script:EnableSoundAlerts = $true
$Script:EnableTrayAlerts = $true
$Script:LastCpuHigh = $false
$Script:LastTempHigh = $false

# === STAN AKTYWNOŚCI DYSKU ===
$Script:DiskReadActiveUntil = [DateTime]::MinValue
$Script:DiskWriteActiveUntil = [DateTime]::MinValue
$Script:ReadLedBlinkState = $false
$Script:WriteLedBlinkState = $false

# === INICJALIZACJA PERFORMANCE COUNTERS DLA DYSKU ===
try {
    $Script:perfDiskRead = New-Object System.Diagnostics.PerformanceCounter("PhysicalDisk", "Disk Read Bytes/sec", "_Total")
    $Script:perfDiskWrite = New-Object System.Diagnostics.PerformanceCounter("PhysicalDisk", "Disk Write Bytes/sec", "_Total")
    # Pierwsze odczyty (inicjalizacja)
    $Script:perfDiskRead.NextValue() | Out-Null
    $Script:perfDiskWrite.NextValue() | Out-Null
    $Script:DiskCountersAvailable = $true
} catch {
    $Script:DiskCountersAvailable = $false
}

# === FUNKCJA WYKRYWANIA EXCLUSIVE FULLSCREEN ===
function Test-ExclusiveFullscreen {
    try {
        $fgWnd = [MiniWidget.Win32]::GetForegroundWindow()
        if ($fgWnd -eq [IntPtr]::Zero) { return $false }
        
        # Pobierz rozmiar okna
        $rect = New-Object MiniWidget.Win32+RECT
        [MiniWidget.Win32]::GetWindowRect($fgWnd, [ref]$rect) | Out-Null
        
        # Pobierz rozmiar ekranu
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        
        # Sprawdź czy okno pokrywa cały ekran
        $coversScreen = ($rect.Left -le 0 -and $rect.Top -le 0 -and 
                        $rect.Right -ge $screen.Width -and $rect.Bottom -ge $screen.Height)
        
        if (-not $coversScreen) { return $false }
        
        # Sprawdź styl okna
        $style = [MiniWidget.Win32]::GetWindowLong($fgWnd, -16)  # GWL_STYLE
        $hasCaption = ($style -band 0x00C00000) -ne 0  # WS_CAPTION
        $hasBorder = ($style -band 0x00800000) -ne 0   # WS_BORDER
        
        # Jeśli okno nie ma ramki i pokrywa ekran = prawdopodobnie exclusive fullscreen
        # Ale musimy odróżnić od borderless windowed
        
        # Pobierz proces
        $processId = 0
        [MiniWidget.Win32]::GetWindowThreadProcessId($fgWnd, [ref]$processId) | Out-Null
        
        if ($processId -gt 0) {
            try {
                $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($proc) {
                    # Lista znanych gier/aplikacji exclusive fullscreen
                    $exclusiveApps = @("game", "csgo", "valorant", "dota2", "league", "fortnite", 
                                       "pubg", "apex", "overwatch", "cod", "battlefield", "gta")
                    $procName = $proc.ProcessName.ToLower()
                    
                    foreach ($app in $exclusiveApps) {
                        if ($procName -match $app) {
                            return (-not $hasCaption -and -not $hasBorder)
                        }
                    }
                }
            } catch {}
        }
        
        # Domyślnie zakładamy borderless windowed jeśli nie rozpoznano
        return $false
    } catch {
        return $false
    }
}

# === FUNKCJA POWIADOMIEŃ DŹWIĘKOWYCH ===
function Play-AlertSound {
    param([string]$Type)
    
    if (-not $Script:EnableSoundAlerts) { return }
    
    try {
        switch ($Type) {
            "ModeChange" {
                [System.Media.SystemSounds]::Asterisk.Play()
            }
            "Warning" {
                [System.Media.SystemSounds]::Exclamation.Play()
            }
            "Critical" {
                [System.Media.SystemSounds]::Hand.Play()
            }
        }
    } catch {}
}

# === FUNKCJA ODCZYTU GPU Z OPEN HARDWARE MONITOR ===
function Get-GPULoadFromOHM {
    try {
        $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
        
        $gpuLoad = $sensors | Where-Object { 
            $_.SensorType -eq "Load" -and 
            ($_.Name -match "GPU Core" -or $_.Name -match "GPU" -or $_.Identifier -match "gpu")
        } | Select-Object -First 1
        
        if ($gpuLoad -and $gpuLoad.Value) {
            return [int]$gpuLoad.Value
        }
        
        $gpuLoad = $sensors | Where-Object { 
            $_.Identifier -match "/gpu" -and $_.SensorType -eq "Load"
        } | Select-Object -First 1
        
        if ($gpuLoad -and $gpuLoad.Value) {
            return [int]$gpuLoad.Value
        }
        
        return 0
    } catch {
        return -1
    }
}

# === WYKRYWANIE PROCESORA ===
$Script:CPUType = "Unknown"
$Script:CPUName = "Unknown"
$Script:CPUConfigFile = "$Script:BaseDir\CPUConfig.json"

function Detect-CPU {
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $Script:CPUName = $cpu.Name
        if ($cpu.Name -match "AMD|Ryzen|EPYC|Athlon|Threadripper") {
            $Script:CPUType = "AMD"
        } elseif ($cpu.Name -match "Intel|Core|Xeon|Pentium|Celeron") {
            $Script:CPUType = "Intel"
        }
    } catch {}
    if (Test-Path $Script:CPUConfigFile) {
        try {
            $cfg = Get-Content $Script:CPUConfigFile -Raw | ConvertFrom-Json
            if ($cfg.CPUType) { $Script:CPUType = $cfg.CPUType }
        } catch {}
    }
}

function Save-CPUConfig {
    try { @{ CPUType = $Script:CPUType; CPUName = $Script:CPUName } | ConvertTo-Json | Set-Content $Script:CPUConfigFile -Force } catch {}
}

function Set-CPUType {
    param([string]$Type)
    $Script:CPUType = $Type
    Save-CPUConfig
    Send-Command "CPU_$Type"
}

Detect-CPU

# === DOMYŚLNE SILNIKI AI ===
$Script:DefaultAIEngines = @{
    QLearning = $true
    Ensemble = $true
    Prophet = $true
    NeuralBrain = $true
    AnomalyDetector = $true
    SelfTuner = $true
    ChainPredictor = $true
    LoadPredictor = $true
}

# === FUNKCJE ZAPISU/ODCZYTU ===
function Load-Settings {
    if (Test-Path $Script:SettingsFile) {
        try {
            $s = Get-Content $Script:SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -ne $s.Opacity) { $Script:Opacity = $s.Opacity }
            if ($null -ne $s.TopMost) { $Script:IsTopMost = $s.TopMost }
            if ($null -ne $s.PosX) { $Script:PosX = $s.PosX }
            if ($null -ne $s.PosY) { $Script:PosY = $s.PosY }
            if ($null -ne $s.IsMuted) { $Script:IsMuted = $s.IsMuted }
            if ($null -ne $s.EnableSoundAlerts) { $Script:EnableSoundAlerts = $s.EnableSoundAlerts }
            if ($null -ne $s.EnableTrayAlerts) { $Script:EnableTrayAlerts = $s.EnableTrayAlerts }
        } catch {}
    }
}

function Save-Settings {
    try {
        @{
            Opacity = $Script:Opacity
            TopMost = $Script:IsTopMost
            PosX = $Script:Form.Location.X
            PosY = $Script:Form.Location.Y
            IsMuted = $Script:IsMuted
            EnableSoundAlerts = $Script:EnableSoundAlerts
            EnableTrayAlerts = $Script:EnableTrayAlerts
        } | ConvertTo-Json | Set-Content $Script:SettingsFile -Force
    } catch {}
}

function Load-AIEngines {
    if (Test-Path $Script:AIEnginesFile) {
        try {
            return Get-Content $Script:AIEnginesFile -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {}
    }
    return $Script:DefaultAIEngines
}

function Save-AIEngines {
    param([hashtable]$Engines)
    try {
        $Engines | ConvertTo-Json | Set-Content $Script:AIEnginesFile -Force
    } catch {}
}

function Send-Command {
    param([string]$Cmd)
    try { 
        $Cmd | Set-Content $Script:CommandFile -Force 
        
        # Powiadomienia - ważne gdy widget niewidoczny!
        $notify = $true
        $title = ""
        $text = ""
        
        switch ($Cmd) {
            "AI" { $title = "Tryb AI"; $text = "Przełączono sterowanie AI" }
            "SILENT" { $title = "Tryb SILENT"; $text = "Cichy tryb aktywny" }
            "BALANCED" { $title = "Tryb BALANCED"; $text = "Zrównoważony tryb aktywny" }
            "TURBO" { $title = "Tryb TURBO"; $text = "Maksymalna wydajność" }
            "PROFILE_GAMING" { $title = "Profil GAMING"; $text = "Turbo + szybkie AI" }
            "PROFILE_WORK" { $title = "Profil WORK"; $text = "Balanced + wszystkie AI" }
            "PROFILE_MOVIE" { $title = "Profil MOVIE"; $text = "Silent + minimalne AI" }
            default { $notify = $false }
        }
        
        if ($notify) {
            Show-Balloon $title $text
            Play-AlertSound "ModeChange"
        }
    } catch {}
}

function Show-Balloon {
    param([string]$Title, [string]$Text)
    
    if (-not $Script:EnableTrayAlerts) { return }
    
    try {
        $Script:Tray.BalloonTipTitle = $Title
        $Script:Tray.BalloonTipText = $Text
        $Script:Tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $Script:Tray.ShowBalloonTip(3000)
    } catch {}
}

# === FUNKCJE AUDIO ===
function Toggle-Mute {
    try {
        [AudioAPI]::keybd_event([AudioAPI]::VK_VOLUME_MUTE, 0, 0, 0)
        [AudioAPI]::keybd_event([AudioAPI]::VK_VOLUME_MUTE, 0, 2, 0)
        $Script:IsMuted = -not $Script:IsMuted
        Update-MuteButton
        Save-Settings
    } catch {}
}

function Volume-Up {
    try {
        for ($i = 0; $i -lt 2; $i++) {
            [AudioAPI]::keybd_event([AudioAPI]::VK_VOLUME_UP, 0, 0, 0)
            [AudioAPI]::keybd_event([AudioAPI]::VK_VOLUME_UP, 0, 2, 0)
        }
    } catch {}
}

function Volume-Down {
    try {
        for ($i = 0; $i -lt 2; $i++) {
            [AudioAPI]::keybd_event([AudioAPI]::VK_VOLUME_DOWN, 0, 0, 0)
            [AudioAPI]::keybd_event([AudioAPI]::VK_VOLUME_DOWN, 0, 2, 0)
        }
    } catch {}
}

function Update-MuteButton {
    if ($Script:IsMuted) {
        $Script:BtnMute.Text = "MUTE"
        $Script:BtnMute.BackColor = [System.Drawing.Color]::FromArgb(100, 40, 40)
        $Script:BtnMute.ForeColor = [System.Drawing.Color]::FromArgb(255, 150, 150)
    } else {
        $Script:BtnMute.Text = "VOL"
        $Script:BtnMute.BackColor = [System.Drawing.Color]::FromArgb(40, 70, 50)
        $Script:BtnMute.ForeColor = [System.Drawing.Color]::FromArgb(150, 255, 180)
    }
}

# === FUNKCJA KILL ALL ===
function Kill-All {
    $Script:Tray.Visible = $false
    Get-Process powershell,pwsh,powershell_ise -ErrorAction SilentlyContinue | Stop-Process -Force
}

# === INSTRUKCJA ===
function Show-Help {
    $helpContent = @"
================================================================================
                    CPU MANAGER v34.2 - INSTRUKCJA / MANUAL
================================================================================

========================= POLSKI / POLISH =========================

MINI WIDGET - PRZYCISKI:
-------------------------
SIL     - Tryb SILENT (cichy, energooszczędny)        [Ctrl+Alt+1]
BAL     - Tryb BALANCED (zrównoważony)                [Ctrl+Alt+2]
TUR     - Tryb TURBO (maksymalna wydajność)           [Ctrl+Alt+3]
AI      - Włącz/Wyłącz sterowanie AI                  [Ctrl+Alt+A]

VOL-    - Zmniejsz głośność
VOL     - Wycisz/Odcisz (MUTE)                        [Ctrl+Alt+M]
VOL+    - Zwiększ głośność

PIN     - Przypnij na wierzchu (nad fullscreen)
-/+     - Zmniejsz/Zwiększ przezroczystość
?       - Ta instrukcja
_       - Ukryj (dostępny w tray)                     [Ctrl+Alt+W]
X       - Zamknij mini widget
KILL    - Zabij WSZYSTKIE procesy CPU Manager

KONTROLKI AKTYWNOŚCI DYSKU (obok zegarka):
------------------------------------------
● (zielona/jasna)  - Odczyt z dysku (R - Read)
● (pomarańczowa)   - Zapis na dysk (W - Write)

  Diody migają gdy aktywność dysku > 1MB/s
  Ciemnoszare = brak aktywności

GPU     - Pobierane z Open Hardware Monitor (musi być uruchomiony!)

⚠️ UWAGA - TRYB FULLSCREEN W GRACH:
------------------------------------
Widget jest widoczny nad grami w trybie:
✅ Fullscreen Windowed (Borderless) - ZALECANE!
✅ Windowed (okno)

Widget NIE jest widoczny w trybie:
❌ Exclusive Fullscreen - ograniczenie Windows

W trybie Exclusive Fullscreen otrzymasz powiadomienia przez:
🔔 Ikona tray (balloon notifications)
🔊 Dźwięki systemowe (można wyłączyć w menu tray)

ZALECENIE: Ustaw gry w tryb "Borderless Windowed" lub "Fullscreen Windowed"

SKRÓTY KLAWISZOWE (GLOBALNE):
-----------------------------
Ctrl+Alt+1  - Tryb SILENT
Ctrl+Alt+2  - Tryb BALANCED
Ctrl+Alt+3  - Tryb TURBO
Ctrl+Alt+A  - Toggle AI (włącz/wyłącz)
Ctrl+Alt+M  - Mute/Unmute (wycisz/odcisz)
Ctrl+Alt+W  - Pokaż/Ukryj Mini Widget

Ctrl+Alt+G  - Profil GAMING
Ctrl+Alt+B  - Profil WORK (Business)
Ctrl+Alt+V  - Profil MOVIE (Video)

PROFILE (menu w tray):
----------------------
GAMING  - Turbo + szybkie silniki AI (dla gier)
WORK    - Balanced + wszystkie silniki AI (dla pracy)
MOVIE   - Silent + minimalne AI (dla filmów)

WYŚWIETLANE DANE:
-----------------
HH:MM:SS  - Aktualna godzina (zielony)
●●        - Aktywność dysku (Read/Write LED)
CPU:XX%   - Użycie procesora
XXC       - Temperatura CPU
X.XGHz    - Częstotliwość CPU
RAM:XX%   - Użycie pamięci RAM
GPU:XX%   - Użycie karty graficznej (z Open Hardware Monitor)

POWIADOMIENIA (menu tray):
--------------------------
🔔 Powiadomienia Tray  - Balloon tips przy zmianach
🔊 Dźwięki alertów     - Dźwięki przy zmianach trybu/alertach

================================================================================
                         CPU Manager v34.2 by AI
================================================================================
"@
    $helpContent | Set-Content $Script:HelpFile -Force -Encoding UTF8
    Start-Process notepad.exe -ArgumentList $Script:HelpFile
}

# === WCZYTAJ USTAWIENIA ===
Load-Settings

# === GŁÓWNE OKNO ===
$Script:Form = New-Object System.Windows.Forms.Form
$Script:Form.Text = "MiniWidget v34.2"
$Script:Form.FormBorderStyle = 'None'
$Script:Form.BackColor = [System.Drawing.Color]::FromArgb(25, 28, 35)
$Script:Form.TopMost = $Script:IsTopMost
$Script:Form.ShowInTaskbar = $false
$Script:Form.StartPosition = 'Manual'
$Script:Form.Size = New-Object System.Drawing.Size(1150, 45)
$Script:Form.Opacity = $Script:Opacity

# Pozycja
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($Script:PosX -lt 0) { $Script:PosX = [int](($screen.Width - 1150) / 2) }
$Script:Form.Location = New-Object System.Drawing.Point($Script:PosX, $Script:PosY)

# === TOOLTIP ===
$Script:ToolTip = New-Object System.Windows.Forms.ToolTip
$Script:ToolTip.InitialDelay = 200
$Script:ToolTip.ShowAlways = $true
$Script:ToolTip.BackColor = [System.Drawing.Color]::FromArgb(40, 44, 52)
$Script:ToolTip.ForeColor = [System.Drawing.Color]::White

# === HELPER: TWORZENIE PRZYCISKU ===
function New-Button {
    param($Text, $X, $Width, $FG, $BG, $Tip, $Action)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point($X, 9)
    $btn.Size = New-Object System.Drawing.Size($Width, 27)
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 1
    $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 65, 80)
    $btn.BackColor = $BG
    $btn.ForeColor = $FG
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Add_Click($Action)
    $Script:ToolTip.SetToolTip($btn, $Tip)
    return $btn
}

# === HELPER: TWORZENIE LABELA ===
function New-DataLabel {
    param($Text, $X, $Width, $Color, $Tip)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, 13)
    $lbl.Size = New-Object System.Drawing.Size($Width, 20)
    $lbl.ForeColor = $Color
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
    $Script:ToolTip.SetToolTip($lbl, $Tip)
    return $lbl
}

# === KONTROLKI ===
$xPos = 8

# Status bar (pionowy pasek)
$Script:StatusBar = New-Object System.Windows.Forms.Panel
$Script:StatusBar.Location = New-Object System.Drawing.Point($xPos, 6)
$Script:StatusBar.Size = New-Object System.Drawing.Size(4, 33)
$Script:StatusBar.BackColor = [System.Drawing.Color]::Gray
$Script:Form.Controls.Add($Script:StatusBar)
$xPos += 10

# === GODZINA - delikatny zielony ===
$Script:LblTime = New-DataLabel "00:00:00" $xPos 70 ([System.Drawing.Color]::FromArgb(120, 200, 140)) "Aktualna godzina"
$Script:Form.Controls.Add($Script:LblTime)
$xPos += 73

# === KONTROLKI LED DYSKU (obok zegarka) ===
# LED Read (odczyt) - zielona
$Script:LblDiskReadLED = New-Object System.Windows.Forms.Label
$Script:LblDiskReadLED.Text = "●"
$Script:LblDiskReadLED.Location = New-Object System.Drawing.Point($xPos, 11)
$Script:LblDiskReadLED.Size = New-Object System.Drawing.Size(14, 18)
$Script:LblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(35, 45, 35)  # Ciemnoszara-zielona (off)
$Script:LblDiskReadLED.BackColor = [System.Drawing.Color]::Transparent
$Script:LblDiskReadLED.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$Script:ToolTip.SetToolTip($Script:LblDiskReadLED, "Disk Read LED (odczyt z dysku)")
$Script:Form.Controls.Add($Script:LblDiskReadLED)
$xPos += 14

# LED Write (zapis) - pomarańczowa
$Script:LblDiskWriteLED = New-Object System.Windows.Forms.Label
$Script:LblDiskWriteLED.Text = "●"
$Script:LblDiskWriteLED.Location = New-Object System.Drawing.Point($xPos, 11)
$Script:LblDiskWriteLED.Size = New-Object System.Drawing.Size(14, 18)
$Script:LblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(45, 40, 30)  # Ciemnoszara-pomarańczowa (off)
$Script:LblDiskWriteLED.BackColor = [System.Drawing.Color]::Transparent
$Script:LblDiskWriteLED.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$Script:ToolTip.SetToolTip($Script:LblDiskWriteLED, "Disk Write LED (zapis na dysk)")
$Script:Form.Controls.Add($Script:LblDiskWriteLED)
$xPos += 18

# Separator
$sepTime = New-Object System.Windows.Forms.Label
$sepTime.Text = "|"
$sepTime.Location = New-Object System.Drawing.Point($xPos, 10)
$sepTime.Size = New-Object System.Drawing.Size(8, 25)
$sepTime.ForeColor = [System.Drawing.Color]::FromArgb(60, 65, 80)
$sepTime.Font = New-Object System.Drawing.Font("Consolas", 10)
$Script:Form.Controls.Add($sepTime)
$xPos += 12

# Etykiety danych
$Script:LblMode = New-DataLabel "---" $xPos 65 ([System.Drawing.Color]::White) "Aktualny tryb pracy"
$Script:Form.Controls.Add($Script:LblMode)
$xPos += 68

$Script:LblCpu = New-DataLabel "CPU:--%" $xPos 70 ([System.Drawing.Color]::Lime) "Użycie procesora"
$Script:Form.Controls.Add($Script:LblCpu)
$xPos += 73

$Script:LblTemp = New-DataLabel "--C" $xPos 38 ([System.Drawing.Color]::Gold) "Temperatura CPU"
$Script:Form.Controls.Add($Script:LblTemp)
$xPos += 41

$Script:LblGhz = New-DataLabel "--GHz" $xPos 55 ([System.Drawing.Color]::DeepSkyBlue) "Częstotliwość CPU"
$Script:Form.Controls.Add($Script:LblGhz)
$xPos += 58

$Script:LblRam = New-DataLabel "RAM:--%" $xPos 70 ([System.Drawing.Color]::Magenta) "Użycie pamięci RAM"
$Script:Form.Controls.Add($Script:LblRam)
$xPos += 73

$Script:LblGpu = New-DataLabel "GPU:--%" $xPos 70 ([System.Drawing.Color]::Cyan) "Użycie GPU (Open Hardware Monitor)"
$Script:Form.Controls.Add($Script:LblGpu)
$xPos += 75

# Separator
$sep1 = New-Object System.Windows.Forms.Label
$sep1.Text = "|"
$sep1.Location = New-Object System.Drawing.Point($xPos, 10)
$sep1.Size = New-Object System.Drawing.Size(8, 25)
$sep1.ForeColor = [System.Drawing.Color]::FromArgb(60, 65, 80)
$sep1.Font = New-Object System.Drawing.Font("Consolas", 10)
$Script:Form.Controls.Add($sep1)
$xPos += 12

# === PRZYCISKI TRYBÓW ===
$Script:BtnSilent = New-Button "SIL" $xPos 36 ([System.Drawing.Color]::LimeGreen) ([System.Drawing.Color]::FromArgb(35, 55, 40)) "Tryb SILENT - cichy, energooszczędny (Ctrl+Alt+1)" { Send-Command "SILENT" }
$Script:Form.Controls.Add($Script:BtnSilent)
$xPos += 38

$Script:BtnBalanced = New-Button "BAL" $xPos 36 ([System.Drawing.Color]::Gold) ([System.Drawing.Color]::FromArgb(55, 50, 35)) "Tryb BALANCED - zrównoważony (Ctrl+Alt+2)" { Send-Command "BALANCED" }
$Script:Form.Controls.Add($Script:BtnBalanced)
$xPos += 38

$Script:BtnTurbo = New-Button "TUR" $xPos 36 ([System.Drawing.Color]::OrangeRed) ([System.Drawing.Color]::FromArgb(55, 35, 35)) "Tryb TURBO - maksymalna wydajność (Ctrl+Alt+3)" { Send-Command "TURBO" }
$Script:Form.Controls.Add($Script:BtnTurbo)
$xPos += 38

$Script:BtnAI = New-Button "AI" $xPos 30 ([System.Drawing.Color]::DeepSkyBlue) ([System.Drawing.Color]::FromArgb(35, 50, 65)) "Włącz/Wyłącz sterowanie AI (Ctrl+Alt+A)" { Send-Command "AI" }
$Script:Form.Controls.Add($Script:BtnAI)
$xPos += 34

# Separator
$sep2 = New-Object System.Windows.Forms.Label
$sep2.Text = "|"
$sep2.Location = New-Object System.Drawing.Point($xPos, 10)
$sep2.Size = New-Object System.Drawing.Size(8, 25)
$sep2.ForeColor = [System.Drawing.Color]::FromArgb(60, 65, 80)
$sep2.Font = New-Object System.Drawing.Font("Consolas", 10)
$Script:Form.Controls.Add($sep2)
$xPos += 12

# === GŁOŚNOŚĆ ===
$Script:BtnVolDown = New-Button "-" $xPos 24 ([System.Drawing.Color]::White) ([System.Drawing.Color]::FromArgb(50, 50, 60)) "Zmniejsz głośność" { Volume-Down }
$Script:Form.Controls.Add($Script:BtnVolDown)
$xPos += 26

$Script:BtnMute = New-Button "VOL" $xPos 40 ([System.Drawing.Color]::FromArgb(150, 255, 180)) ([System.Drawing.Color]::FromArgb(40, 70, 50)) "Wycisz/Odcisz (Ctrl+Alt+M)" { Toggle-Mute }
$Script:Form.Controls.Add($Script:BtnMute)
$xPos += 42

$Script:BtnVolUp = New-Button "+" $xPos 24 ([System.Drawing.Color]::White) ([System.Drawing.Color]::FromArgb(50, 50, 60)) "Zwiększ głośność" { Volume-Up }
$Script:Form.Controls.Add($Script:BtnVolUp)
$xPos += 28

# Separator
$sep3 = New-Object System.Windows.Forms.Label
$sep3.Text = "|"
$sep3.Location = New-Object System.Drawing.Point($xPos, 10)
$sep3.Size = New-Object System.Drawing.Size(8, 25)
$sep3.ForeColor = [System.Drawing.Color]::FromArgb(60, 65, 80)
$sep3.Font = New-Object System.Drawing.Font("Consolas", 10)
$Script:Form.Controls.Add($sep3)
$xPos += 12

# === KONTROLKI WIDGETU ===
$Script:BtnPin = New-Button "PIN" $xPos 32 ([System.Drawing.Color]::Cyan) ([System.Drawing.Color]::FromArgb(40, 55, 65)) "Przypnij na wierzchu (nad fullscreen windowed)" {
    $Script:IsTopMost = -not $Script:IsTopMost
    $Script:Form.TopMost = $Script:IsTopMost
    $Script:BtnPin.ForeColor = if ($Script:IsTopMost) { [System.Drawing.Color]::Cyan } else { [System.Drawing.Color]::Gray }
    Save-Settings
}
$Script:BtnPin.ForeColor = if ($Script:IsTopMost) { [System.Drawing.Color]::Cyan } else { [System.Drawing.Color]::Gray }
$Script:Form.Controls.Add($Script:BtnPin)
$xPos += 34

$Script:BtnOpDown = New-Button "-" $xPos 22 ([System.Drawing.Color]::Gray) ([System.Drawing.Color]::FromArgb(45, 45, 55)) "Zmniejsz przezroczystość" {
    $Script:Opacity = [Math]::Max(0.3, $Script:Opacity - 0.1)
    $Script:Form.Opacity = $Script:Opacity
    Save-Settings
}
$Script:Form.Controls.Add($Script:BtnOpDown)
$xPos += 24

$Script:BtnOpUp = New-Button "+" $xPos 22 ([System.Drawing.Color]::Gray) ([System.Drawing.Color]::FromArgb(45, 45, 55)) "Zwiększ przezroczystość" {
    $Script:Opacity = [Math]::Min(1.0, $Script:Opacity + 0.1)
    $Script:Form.Opacity = $Script:Opacity
    Save-Settings
}
$Script:Form.Controls.Add($Script:BtnOpUp)
$xPos += 26

# === HELP ===
$Script:BtnHelp = New-Button "?" $xPos 22 ([System.Drawing.Color]::Yellow) ([System.Drawing.Color]::FromArgb(55, 55, 40)) "Otwórz instrukcję (Notepad)" { Show-Help }
$Script:Form.Controls.Add($Script:BtnHelp)
$xPos += 26

# Separator
$sep4 = New-Object System.Windows.Forms.Label
$sep4.Text = "|"
$sep4.Location = New-Object System.Drawing.Point($xPos, 10)
$sep4.Size = New-Object System.Drawing.Size(8, 25)
$sep4.ForeColor = [System.Drawing.Color]::FromArgb(60, 65, 80)
$sep4.Font = New-Object System.Drawing.Font("Consolas", 10)
$Script:Form.Controls.Add($sep4)
$xPos += 12

# === MINIMIZE / CLOSE ===
$Script:BtnMin = New-Button "_" $xPos 22 ([System.Drawing.Color]::White) ([System.Drawing.Color]::FromArgb(50, 50, 60)) "Ukryj widget (dostępny w tray)" { $Script:Form.Hide() }
$Script:Form.Controls.Add($Script:BtnMin)
$xPos += 24

$Script:BtnClose = New-Button "X" $xPos 22 ([System.Drawing.Color]::White) ([System.Drawing.Color]::FromArgb(120, 50, 50)) "Zamknij mini widget" { $Script:Tray.Visible = $false; $Script:Form.Close() }
$Script:Form.Controls.Add($Script:BtnClose)
$xPos += 26

# === KILL ALL ===
$Script:BtnKill = New-Button "KILL" $xPos 42 ([System.Drawing.Color]::White) ([System.Drawing.Color]::FromArgb(130, 35, 35)) "☠ ZABIJ WSZYSTKIE procesy CPU Manager" { Kill-All }
$Script:BtnKill.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(180, 60, 60)
$Script:Form.Controls.Add($Script:BtnKill)

# === DOSTOSUJ SZEROKOŚĆ OKNA ===
$Script:Form.Width = $xPos + 50

# === TRAY ICON ===
$Script:Tray = New-Object System.Windows.Forms.NotifyIcon
$Script:Tray.Text = "Mini Widget v34.2"
$Script:Tray.Visible = $true

# Ikona tray
$bmp = New-Object System.Drawing.Bitmap(16, 16)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.Clear([System.Drawing.Color]::FromArgb(0, 180, 220))
$g.DrawString("M", (New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, 1, 0)
$g.Dispose()
$Script:Tray.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())

# Zachowaj oryginalną ikonę
$Script:OriginalIcon = $Script:Tray.Icon

# Ikona alertu (czerwona)
$bmpAlert = New-Object System.Drawing.Bitmap(16, 16)
$gAlert = [System.Drawing.Graphics]::FromImage($bmpAlert)
$gAlert.SmoothingMode = 'AntiAlias'
$gAlert.Clear([System.Drawing.Color]::FromArgb(220, 60, 60))
$gAlert.DrawString("!", (New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, 3, 0)
$gAlert.Dispose()
$Script:AlertIcon = [System.Drawing.Icon]::FromHandle($bmpAlert.GetHicon())

# === TRAY MENU ===
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

# Pokaż/Ukryj
$miShow = New-Object System.Windows.Forms.ToolStripMenuItem
$miShow.Text = "Pokaż Mini Widget"
$miShow.Add_Click({ $Script:Form.Show(); $Script:Form.WindowState = 'Normal' })
$trayMenu.Items.Add($miShow)

$miHide = New-Object System.Windows.Forms.ToolStripMenuItem
$miHide.Text = "Ukryj Mini Widget"
$miHide.Add_Click({ $Script:Form.Hide() })
$trayMenu.Items.Add($miHide)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Tryby
$miModes = New-Object System.Windows.Forms.ToolStripMenuItem
$miModes.Text = "Tryb pracy"

$miSilent = New-Object System.Windows.Forms.ToolStripMenuItem
$miSilent.Text = "Silent (cichy)"
$miSilent.Add_Click({ Send-Command "SILENT" })
$miModes.DropDownItems.Add($miSilent)

$miBal = New-Object System.Windows.Forms.ToolStripMenuItem
$miBal.Text = "Balanced (zrównoważony)"
$miBal.Add_Click({ Send-Command "BALANCED" })
$miModes.DropDownItems.Add($miBal)

$miTurbo = New-Object System.Windows.Forms.ToolStripMenuItem
$miTurbo.Text = "Turbo (wydajność)"
$miTurbo.Add_Click({ Send-Command "TURBO" })
$miModes.DropDownItems.Add($miTurbo)

$miModes.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miAI = New-Object System.Windows.Forms.ToolStripMenuItem
$miAI.Text = "Toggle AI"
$miAI.Add_Click({ Send-Command "AI" })
$miModes.DropDownItems.Add($miAI)

$trayMenu.Items.Add($miModes)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# === PROFILE ===
$miProfiles = New-Object System.Windows.Forms.ToolStripMenuItem
$miProfiles.Text = "Profile"

$miGaming = New-Object System.Windows.Forms.ToolStripMenuItem
$miGaming.Text = "GAMING (Turbo + Fast AI)"
$miGaming.Add_Click({ Send-Command "PROFILE_GAMING" })
$miProfiles.DropDownItems.Add($miGaming)

$miWork = New-Object System.Windows.Forms.ToolStripMenuItem
$miWork.Text = "WORK (Balanced + All AI)"
$miWork.Add_Click({ Send-Command "PROFILE_WORK" })
$miProfiles.DropDownItems.Add($miWork)

$miMovie = New-Object System.Windows.Forms.ToolStripMenuItem
$miMovie.Text = "MOVIE (Silent + Min AI)"
$miMovie.Add_Click({ Send-Command "PROFILE_MOVIE" })
$miProfiles.DropDownItems.Add($miMovie)

$trayMenu.Items.Add($miProfiles)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# === POWIADOMIENIA ===
$miNotify = New-Object System.Windows.Forms.ToolStripMenuItem
$miNotify.Text = "Powiadomienia"

$miTrayAlerts = New-Object System.Windows.Forms.ToolStripMenuItem
$miTrayAlerts.Text = "🔔 Powiadomienia Tray"
$miTrayAlerts.CheckOnClick = $true
$miTrayAlerts.Checked = $Script:EnableTrayAlerts
$miTrayAlerts.Add_Click({
    $Script:EnableTrayAlerts = $miTrayAlerts.Checked
    Save-Settings
})
$miNotify.DropDownItems.Add($miTrayAlerts)

$miSoundAlerts = New-Object System.Windows.Forms.ToolStripMenuItem
$miSoundAlerts.Text = "🔊 Dźwięki alertów"
$miSoundAlerts.CheckOnClick = $true
$miSoundAlerts.Checked = $Script:EnableSoundAlerts
$miSoundAlerts.Add_Click({
    $Script:EnableSoundAlerts = $miSoundAlerts.Checked
    Save-Settings
})
$miNotify.DropDownItems.Add($miSoundAlerts)

$trayMenu.Items.Add($miNotify)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# === PROCESOR ===
$miProc = New-Object System.Windows.Forms.ToolStripMenuItem
$miProc.Text = "Procesor [$($Script:CPUType)]"

$miAMD = New-Object System.Windows.Forms.ToolStripMenuItem
$miAMD.Text = "AMD Ryzen"
$miAMD.Checked = ($Script:CPUType -eq "AMD")
$miAMD.Add_Click({ Set-CPUType "AMD"; $miAMD.Checked = $true; $miIntel.Checked = $false; $miProc.Text = "Procesor [AMD]" })
$miProc.DropDownItems.Add($miAMD)

$miIntel = New-Object System.Windows.Forms.ToolStripMenuItem
$miIntel.Text = "Intel Core"
$miIntel.Checked = ($Script:CPUType -eq "Intel")
$miIntel.Add_Click({ Set-CPUType "Intel"; $miIntel.Checked = $true; $miAMD.Checked = $false; $miProc.Text = "Procesor [Intel]" })
$miProc.DropDownItems.Add($miIntel)

$trayMenu.Items.Add($miProc)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# === SILNIKI AI ===
$miEngines = New-Object System.Windows.Forms.ToolStripMenuItem
$miEngines.Text = "Silniki AI"

$miEnableAll = New-Object System.Windows.Forms.ToolStripMenuItem
$miEnableAll.Text = "✓ Włącz WSZYSTKIE"
$miEnableAll.Add_Click({
    $allOn = @{
        QLearning = $true; Ensemble = $true; Prophet = $true; NeuralBrain = $true
        AnomalyDetector = $true; SelfTuner = $true; ChainPredictor = $true; LoadPredictor = $true
    }
    Save-AIEngines $allOn
    foreach ($key in $Script:AIEngineMenuItems.Keys) {
        $Script:AIEngineMenuItems[$key].Checked = $true
    }
    Show-Balloon "Silniki AI" "Wszystkie 8 silników WŁĄCZONE"
})
$miEngines.DropDownItems.Add($miEnableAll)

$miDisableAll = New-Object System.Windows.Forms.ToolStripMenuItem
$miDisableAll.Text = "✗ Wyłącz WSZYSTKIE"
$miDisableAll.Add_Click({
    $allOff = @{
        QLearning = $false; Ensemble = $false; Prophet = $false; NeuralBrain = $false
        AnomalyDetector = $false; SelfTuner = $false; ChainPredictor = $false; LoadPredictor = $false
    }
    Save-AIEngines $allOff
    foreach ($key in $Script:AIEngineMenuItems.Keys) {
        $Script:AIEngineMenuItems[$key].Checked = $false
    }
    Show-Balloon "Silniki AI" "Wszystkie silniki WYŁĄCZONE"
})
$miEngines.DropDownItems.Add($miDisableAll)

$miEngines.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$Script:AIEngineMenuItems = @{}
$engineNames = @(
    @{Key="QLearning"; Name="QLearning - uczenie"},
    @{Key="Ensemble"; Name="Ensemble - głosowanie"},
    @{Key="Prophet"; Name="Prophet - wzorce"},
    @{Key="NeuralBrain"; Name="NeuralBrain - sieć"},
    @{Key="AnomalyDetector"; Name="AnomalyDetector - anomalie"},
    @{Key="SelfTuner"; Name="SelfTuner - optymalizacja"},
    @{Key="ChainPredictor"; Name="ChainPredictor - sekwencje"},
    @{Key="LoadPredictor"; Name="LoadPredictor - obciążenie"}
)

$currentEngines = Load-AIEngines

foreach ($eng in $engineNames) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem
    $mi.Text = $eng.Name
    $mi.CheckOnClick = $true
    $mi.Checked = if ($currentEngines.($eng.Key) -eq $true) { $true } else { $false }
    $mi.Tag = $eng.Key
    $mi.Add_CheckedChanged({
        param($sender, $e)
        $engines = Load-AIEngines
        $key = $sender.Tag
        if ($engines -is [PSCustomObject]) {
            $engines = @{
                QLearning = $engines.QLearning
                Ensemble = $engines.Ensemble
                Prophet = $engines.Prophet
                NeuralBrain = $engines.NeuralBrain
                AnomalyDetector = $engines.AnomalyDetector
                SelfTuner = $engines.SelfTuner
                ChainPredictor = $engines.ChainPredictor
                LoadPredictor = $engines.LoadPredictor
            }
        }
        $engines[$key] = $sender.Checked
        Save-AIEngines $engines
    })
    $Script:AIEngineMenuItems[$eng.Key] = $mi
    $miEngines.DropDownItems.Add($mi)
}

$trayMenu.Items.Add($miEngines)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# === URUCHOM KOMPONENTY ===
$miOther = New-Object System.Windows.Forms.ToolStripMenuItem
$miOther.Text = "Uruchom komponenty"

$miWidget = New-Object System.Windows.Forms.ToolStripMenuItem
$miWidget.Text = "Widget Desktop"
$miWidget.Add_Click({
    $ws = "C:\CPUManager\Widget_v34.ps1"
    if (Test-Path $ws) { Start-Process pwsh.exe -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $ws -WindowStyle Hidden }
})
$miOther.DropDownItems.Add($miWidget)

$miConfig = New-Object System.Windows.Forms.ToolStripMenuItem
$miConfig.Text = "Konfigurator"
$miConfig.Add_Click({
    $cs = "C:\CPUManager\CPUManager_Configurator_v34.ps1"
    if (Test-Path $cs) { Start-Process pwsh.exe -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $cs -WindowStyle Hidden }
})
$miOther.DropDownItems.Add($miConfig)

$miMain = New-Object System.Windows.Forms.ToolStripMenuItem
$miMain.Text = "CPUManager (silnik)"
$miMain.Add_Click({
    $ms = "C:\CPUManager\CPUManager_v34.ps1"
    if (Test-Path $ms) { Start-Process pwsh.exe -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $ms -WindowStyle Hidden }
})
$miOther.DropDownItems.Add($miMain)

$trayMenu.Items.Add($miOther)

# Instrukcja
$miHelp = New-Object System.Windows.Forms.ToolStripMenuItem
$miHelp.Text = "Instrukcja"
$miHelp.Add_Click({ Show-Help })
$trayMenu.Items.Add($miHelp)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Zawsze na wierzchu
$miTop = New-Object System.Windows.Forms.ToolStripMenuItem
$miTop.Text = "Zawsze na wierzchu"
$miTop.CheckOnClick = $true
$miTop.Checked = $Script:IsTopMost
$miTop.Add_Click({
    $Script:IsTopMost = $miTop.Checked
    $Script:Form.TopMost = $Script:IsTopMost
    $Script:BtnPin.ForeColor = if ($Script:IsTopMost) { [System.Drawing.Color]::Cyan } else { [System.Drawing.Color]::Gray }
    Save-Settings
})
$trayMenu.Items.Add($miTop)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Zamknij
$miClose = New-Object System.Windows.Forms.ToolStripMenuItem
$miClose.Text = "Zamknij Mini Widget"
$miClose.Add_Click({ $Script:Tray.Visible = $false; $Script:Form.Close() })
$trayMenu.Items.Add($miClose)

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# KILL ALL
$miKill = New-Object System.Windows.Forms.ToolStripMenuItem
$miKill.Text = "☠ KILL ALL"
$miKill.BackColor = [System.Drawing.Color]::FromArgb(100, 30, 30)
$miKill.ForeColor = [System.Drawing.Color]::Red
$miKill.Add_Click({ Kill-All })
$trayMenu.Items.Add($miKill)

$Script:Tray.ContextMenuStrip = $trayMenu
$Script:Tray.Add_DoubleClick({ if ($Script:Form.Visible) { $Script:Form.Hide() } else { $Script:Form.Show() } })

# === DRAG SUPPORT ===
$Script:Drag = $false
$Script:DragX = 0
$Script:DragY = 0

$dragDown = { param($s,$e); if ($e.Button -eq 'Left') { $Script:Drag = $true; $Script:DragX = $e.X; $Script:DragY = $e.Y } }
$dragMove = { param($s,$e); if ($Script:Drag) { $Script:Form.Left += $e.X - $Script:DragX; $Script:Form.Top += $e.Y - $Script:DragY } }
$dragUp = { $Script:Drag = $false; Save-Settings }

$Script:Form.Add_MouseDown($dragDown)
$Script:Form.Add_MouseMove($dragMove)
$Script:Form.Add_MouseUp($dragUp)

foreach ($ctrl in @($Script:StatusBar, $Script:LblTime, $Script:LblDiskReadLED, $Script:LblDiskWriteLED, $Script:LblMode, $Script:LblCpu, $Script:LblTemp, $Script:LblGhz, $Script:LblRam, $Script:LblGpu, $sepTime, $sep1, $sep2, $sep3, $sep4)) {
    $ctrl.Add_MouseDown($dragDown)
    $ctrl.Add_MouseMove($dragMove)
    $ctrl.Add_MouseUp($dragUp)
}

# === INIT MUTE BUTTON ===
Update-MuteButton

# === AKTUALIZACJA PRZYCISKÓW TRYBÓW ===
function Update-ModeButtons {
    $Script:BtnSilent.BackColor = [System.Drawing.Color]::FromArgb(35, 55, 40)
    $Script:BtnBalanced.BackColor = [System.Drawing.Color]::FromArgb(55, 50, 35)
    $Script:BtnTurbo.BackColor = [System.Drawing.Color]::FromArgb(55, 35, 35)
    $Script:BtnAI.BackColor = [System.Drawing.Color]::FromArgb(35, 50, 65)
    
    if ($Script:AIStatus -eq "ON") {
        $Script:BtnAI.BackColor = [System.Drawing.Color]::FromArgb(50, 100, 150)
        switch ($Script:CurrentMode) {
            "Silent" { $Script:StatusBar.BackColor = [System.Drawing.Color]::LimeGreen }
            "Balanced" { $Script:StatusBar.BackColor = [System.Drawing.Color]::Gold }
            "Turbo" { $Script:StatusBar.BackColor = [System.Drawing.Color]::OrangeRed }
            default { $Script:StatusBar.BackColor = [System.Drawing.Color]::DeepSkyBlue }
        }
    } else {
        switch ($Script:CurrentMode) {
            "Silent" {
                $Script:BtnSilent.BackColor = [System.Drawing.Color]::FromArgb(50, 90, 60)
                $Script:StatusBar.BackColor = [System.Drawing.Color]::LimeGreen
            }
            "Balanced" {
                $Script:BtnBalanced.BackColor = [System.Drawing.Color]::FromArgb(90, 80, 50)
                $Script:StatusBar.BackColor = [System.Drawing.Color]::Gold
            }
            "Turbo" {
                $Script:BtnTurbo.BackColor = [System.Drawing.Color]::FromArgb(90, 50, 50)
                $Script:StatusBar.BackColor = [System.Drawing.Color]::OrangeRed
            }
            default { $Script:StatusBar.BackColor = [System.Drawing.Color]::Gray }
        }
    }
}

# === LICZNIK DO MIGANIA IKONY ===
$Script:IconFlashCounter = 0

# === TIMER ===
$Script:Timer = New-Object System.Windows.Forms.Timer
$Script:Timer.Interval = 100  # Zmienione na 100ms dla płynniejszego migania LED
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
                    $Script:LblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(35, 45, 35)  # Off - ciemnoszary
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
                    $Script:LblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(45, 40, 30)  # Off - ciemnoszary
                }
                
                # Aktualizuj tooltip z aktualnymi wartościami
                $readMB = [Math]::Round($readBytes / 1048576, 2)
                $writeMB = [Math]::Round($writeBytes / 1048576, 2)
                $Script:ToolTip.SetToolTip($Script:LblDiskReadLED, "Disk Read: $readMB MB/s")
                $Script:ToolTip.SetToolTip($Script:LblDiskWriteLED, "Disk Write: $writeMB MB/s")
                
            } catch {
                $Script:LblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(60, 30, 30)  # Błąd - czerwonawy
                $Script:LblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(60, 30, 30)
            }
        } else {
            # Performance counters niedostępne
            $Script:LblDiskReadLED.ForeColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
            $Script:LblDiskWriteLED.ForeColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
            $Script:ToolTip.SetToolTip($Script:LblDiskReadLED, "Disk Read: N/A")
            $Script:ToolTip.SetToolTip($Script:LblDiskWriteLED, "Disk Write: N/A")
        }
        
        # === RESZTA AKTUALIZACJI CO 1 SEKUNDĘ (co 10 ticków) ===
        if ($Script:TickCounter % 10 -ne 0) { return }
        
        # === AKTUALIZACJA GODZINY ===
        $Script:LblTime.Text = $now.ToString("HH:mm:ss")
        
        # === SPRAWDŹ CZY EXCLUSIVE FULLSCREEN ===
        $isExclusiveFS = Test-ExclusiveFullscreen
        
        if ($isExclusiveFS -and -not $Script:IsFullscreenActive) {
            # Właśnie weszliśmy w exclusive fullscreen
            $Script:IsFullscreenActive = $true
            Show-Balloon "Tryb Fullscreen" "Widget niewidoczny - użyj tray lub skrótów klawiszowych"
        } elseif (-not $isExclusiveFS -and $Script:IsFullscreenActive) {
            # Wyszliśmy z exclusive fullscreen
            $Script:IsFullscreenActive = $false
            $Script:Tray.Icon = $Script:OriginalIcon
        }
        
        # Wymuszenie TopMost nad fullscreen windowed
        if ($Script:IsTopMost -and $Script:Form.Visible -and -not $isExclusiveFS) {
            try {
                [MiniWidget.Win32]::SetWindowPos(
                    $Script:Form.Handle,
                    [MiniWidget.Win32]::HWND_TOPMOST,
                    0, 0, 0, 0,
                    [MiniWidget.Win32]::SWP_NOMOVE -bor [MiniWidget.Win32]::SWP_NOSIZE -bor [MiniWidget.Win32]::SWP_NOACTIVATE
                ) | Out-Null
            } catch {}
        }
        
        # Sprawdź komendy
        if (Test-Path $Script:MiniCommandFile) {
            $cmd = (Get-Content $Script:MiniCommandFile -Raw -ErrorAction SilentlyContinue).Trim()
            Remove-Item $Script:MiniCommandFile -Force -ErrorAction SilentlyContinue
            switch ($cmd) {
                "EXIT" { $Script:Tray.Visible = $false; $Script:Form.Close(); return }
                "HIDE" { $Script:Form.Hide() }
                "SHOW" { $Script:Form.Show() }
            }
        }
        
        # Synchronizuj CPUConfig
        if (Test-Path $Script:CPUConfigFile) {
            try {
                $cfg = Get-Content $Script:CPUConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($cfg.CPUType -and $cfg.CPUType -ne $Script:CPUType) {
                    $Script:CPUType = $cfg.CPUType
                    $miProc.Text = "Procesor [$($Script:CPUType)]"
                    $miAMD.Checked = ($Script:CPUType -eq "AMD")
                    $miIntel.Checked = ($Script:CPUType -eq "Intel")
                }
            } catch {}
        }
        
        # === POBIERZ GPU Z OPEN HARDWARE MONITOR ===
        $gpuLoadOHM = Get-GPULoadFromOHM
        
        # Odczytaj dane
        if (Test-Path $Script:DataFile) {
            try {
                $d = Get-Content $Script:DataFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            
                $Script:CurrentMode = if ($d.Mode) { $d.Mode } else { "---" }
                $Script:AIStatus = if ($d.AI) { $d.AI } else { "OFF" }
                
                # === WYKRYJ ZMIANĘ TRYBU - powiadom gdy w fullscreen ===
                if ($Script:CurrentMode -ne $Script:LastMode -and $Script:LastMode -ne "---") {
                    if ($Script:IsFullscreenActive) {
                        Show-Balloon "Zmiana trybu" "Nowy tryb: $($Script:CurrentMode)"
                        Play-AlertSound "ModeChange"
                    }
                }
                $Script:LastMode = $Script:CurrentMode
                
                if ($Script:AIStatus -eq "ON") {
                    $Script:LblMode.Text = "AI"
                } else {
                    $Script:LblMode.Text = "$($Script:CurrentMode)"
                }
                
                $cpu = if ($d.CPU) { [int]$d.CPU } else { 0 }
                $Script:LblCpu.Text = "CPU:$cpu%"
                $Script:LblCpu.ForeColor = if ($cpu -gt 80) { [System.Drawing.Color]::OrangeRed } elseif ($cpu -gt 50) { [System.Drawing.Color]::Orange } else { [System.Drawing.Color]::Lime }
                
                # Alert CPU gdy w fullscreen
                $cpuHigh = $cpu -gt 90
                if ($cpuHigh -and -not $Script:LastCpuHigh -and $Script:IsFullscreenActive) {
                    Show-Balloon "⚠️ Wysokie CPU" "Użycie CPU: $cpu%"
                    Play-AlertSound "Warning"
                }
                $Script:LastCpuHigh = $cpuHigh
                
                $temp = if ($d.Temp) { [int]$d.Temp } else { 0 }
                $Script:LblTemp.Text = "${temp}C"
                $Script:LblTemp.ForeColor = if ($temp -gt 80) { [System.Drawing.Color]::OrangeRed } elseif ($temp -gt 65) { [System.Drawing.Color]::Orange } else { [System.Drawing.Color]::Gold }
                
                # Alert temperatury gdy w fullscreen
                $tempHigh = $temp -gt 85
                if ($tempHigh -and -not $Script:LastTempHigh -and $Script:IsFullscreenActive) {
                    Show-Balloon "🔥 Wysoka temperatura!" "Temperatura CPU: ${temp}°C"
                    Play-AlertSound "Critical"
                }
                $Script:LastTempHigh = $tempHigh
                
                $ghz = if ($d.CpuMHz -gt 0) { "{0:N1}" -f ($d.CpuMHz/1000) } else { "--" }
                $Script:LblGhz.Text = "${ghz}GHz"
                
                $ram = if ($d.RAM) { [int]$d.RAM } else { 0 }
                $Script:LblRam.Text = "RAM:$ram%"
                $Script:LblRam.ForeColor = if ($ram -gt 85) { [System.Drawing.Color]::OrangeRed } elseif ($ram -gt 70) { [System.Drawing.Color]::Orange } else { [System.Drawing.Color]::Magenta }
                
                # === GPU Z OPEN HARDWARE MONITOR ===
                if ($gpuLoadOHM -ge 0) {
                    $Script:LblGpu.Text = "GPU:$gpuLoadOHM%"
                    $Script:LblGpu.ForeColor = if ($gpuLoadOHM -gt 80) { [System.Drawing.Color]::OrangeRed } elseif ($gpuLoadOHM -gt 50) { [System.Drawing.Color]::Orange } else { [System.Drawing.Color]::Cyan }
                    $Script:ToolTip.SetToolTip($Script:LblGpu, "GPU Load z Open Hardware Monitor: $gpuLoadOHM%")
                } else {
                    $Script:LblGpu.Text = "GPU:N/A"
                    $Script:LblGpu.ForeColor = [System.Drawing.Color]::Gray
                    $Script:ToolTip.SetToolTip($Script:LblGpu, "Open Hardware Monitor nie jest uruchomiony!")
                }
                
                Update-ModeButtons
                
                # === AKTUALIZUJ TRAY TEXT ===
                $modeText = if ($Script:AIStatus -eq "ON") { "AI" } else { $Script:CurrentMode }
                $fsText = if ($Script:IsFullscreenActive) { " [FS]" } else { "" }
                $Script:Tray.Text = "Mini | $modeText | CPU:$cpu%$fsText"
                
                # === MIGANIE IKONY GDY ALERT W FULLSCREEN ===
                if ($Script:IsFullscreenActive -and ($cpuHigh -or $tempHigh)) {
                    $Script:IconFlashCounter++
                    if ($Script:IconFlashCounter % 2 -eq 0) {
                        $Script:Tray.Icon = $Script:AlertIcon
                    } else {
                        $Script:Tray.Icon = $Script:OriginalIcon
                    }
                } else {
                    $Script:Tray.Icon = $Script:OriginalIcon
                    $Script:IconFlashCounter = 0
                }
                
            } catch {
                $Script:LblMode.Text = "ERR"
            }
        } else {
            $Script:LblMode.Text = "BRAK"
            $Script:StatusBar.BackColor = [System.Drawing.Color]::Red
        }
    } catch {
        $Script:LblMode.Text = "ERR"
    }
})
$Script:Timer.Start()

# === CLEANUP ===
$Script:Form.Add_FormClosing({
    $Script:Timer.Stop()
    $Script:Timer.Dispose()
    
    # Zwolnij performance counters
    if ($Script:DiskCountersAvailable) {
        try {
            $Script:perfDiskRead.Dispose()
            $Script:perfDiskWrite.Dispose()
        } catch {}
    }
    
    $Script:Tray.Visible = $false
    $Script:Tray.Dispose()
    if (Test-Path $Script:PidFile) { Remove-Item $Script:PidFile -Force -ErrorAction SilentlyContinue }
})

# === START ===
[System.Windows.Forms.Application]::Run($Script:Form)