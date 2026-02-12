# CPUManager v40 - Zaawansowany System Zarządzania Procesorem z AI

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6.svg)](https://www.microsoft.com/windows)
[![License](https://img.shields.io/badge/License-Proprietary-red.svg)](#licencja)
[![Version](https://img.shields.io/badge/Version-40%20(43.9)-green.svg)](#changelog)

## 📋 Spis Treści

- [Wprowadzenie](#wprowadzenie)
- [Architektura Systemu](#architektura-systemu)
- [18+ Silników AI](#18-silników-ai)
- [Hierarchia Decyzji](#hierarchia-decyzji)
- [Konfigurator GUI](#konfigurator-gui)
- [Instalacja](#instalacja)
- [Konfiguracja](#konfiguracja)
- [Dokumentacja Techniczna](#dokumentacja-techniczna)
- [FAQ](#faq)
- [Changelog](#changelog)
- [Licencja](#licencja)

---

## 🎯 Wprowadzenie

**CPUManager v40** to najbardziej zaawansowany darmowy system optymalizacji procesora dla Windows, wykorzystujący **18+ algorytmów sztucznej inteligencji** do dynamicznej kontroli wydajności, temperatury i zużycia energii w czasie rzeczywistym.

### ⚠️ Zalecane Narzędzia Pomocnicze

Dla optymalnego działania systemu **zaleca się** (ale nie jest wymagane) zainstalowanie jednego z poniższych narzędzi do monitorowania sprzętu:

#### **Monitoring Sprzętu (zalecane, opcjonalne):**
- ✅ **OpenHardwareMonitor (OHM)** - https://openhardwaremonitor.org/
  - Lekki, open-source
  - Wspiera AMD, Intel, NVIDIA, AMD GPU
  - Dostarcza dokładne odczyty temperatury, obciążenia, częstotliwości
  
- ✅ **LibreHardwareMonitor (LHM)** - https://github.com/LibreHardwareMonitor/LibreHardwareMonitor
  - Fork OHM z aktywnym rozwojem
  - Lepsze wsparcie dla nowszych CPU (Ryzen 7000/9000, Intel 13th/14th gen)
  - Zalecany dla najnowszego sprzętu

**Uwaga:** CPUManager działa także bez tych narzędzi, ale monitoring temperatury/obciążenia GPU będzie ograniczony do danych systemowych Windows (mniej precyzyjne).

#### **Kontrola TDP dla AMD Ryzen (wbudowane, ale można zaktualizować):**
- ✅ **RyzenAdj** - https://github.com/FlyGoat/RyzenAdj
  - **Wbudowany** w CPUManager (plik `RyzenAdj.exe`)
  - Pozwala na kontrolę TDP/PBO/Temperature Limits
  - Dla AMD Ryzen 3000-9000 series + APU
  - **Opcjonalnie** możesz pobrać najnowszą wersję z GitHub

**Uwaga dla Intel:** Kontrola TDP odbywa się przez PowerShell (wbudowane w Windows lecz z pominięciem ograniczen Windowsa - potrafi zbić procesor nawet do 400MHz :-) chociaż to krytycznie niskie !), RyzenAdj nie jest potrzebny.

### Kluczowe Cechy

- ✅ **18+ silników AI** - Q-Learning, Prophet Memory, Neural Brain, Ensemble Voting, GPU-Bound Detector, Thompson Sampling Bandit, Genetic Optimizer, Chain Predictor, Load Predictor, Self Tuner, Anomaly Detector, Context Detector, Network AI, Energy Optimizer, Process Watcher, AI Coordinator, Storage Mode Manager, HardLock System
- ✅ **Kompatybilność AMD/Intel** - Ryzen 3000-9000 (Zen 2-5), Intel 10-14 gen (Hybrid P+E cores)
- ✅ **GPU-Bound Detection** - Pierwszy w Polsce system wykrywający scenariusze Low CPU + High GPU
- ✅ **Graficzny konfigurator** - 7,533 linii kodu, 6 głównych zakładek
- ✅ **HardLock System** - Pełna kontrola użytkownika nad trybami CPU dla wybranych aplikacji
- ✅ **Transfer wiedzy AI** - Aktywny transfer między silnikami (Ensemble ↔ Q-Learning ↔ Prophet ↔ Brain)

### Statystyki Projektu

| Komponent | Linie Kodu | Język | Funkcja |
|-----------|------------|-------|---------|
| **ENGINE** | 17,529 | PowerShell | Główny silnik AI + TDP control |
| **CONFIGURATOR** | 7,533 | PowerShell + .NET | Graficzny interfejs użytkownika |
| **RAZEM** | **25,062** | PowerShell | Kompletny system |

---

## 🏗️ Architektura Systemu

### Struktura Plików

```
C:\CPUManager\
│
├── 📄 CPUManager_v40.ps1                ← ENGINE (główny silnik)
├── 📄 CPUManager_Configurator_v40.ps1   ← GUI (konfigurator)
├── 📄 RyzenAdj.exe                      ← AMD TDP control (ryzenadj)
│
├── 📁 AI Data Files (JSON)
│   ├── QLearning.json                   ← Q-Learning state (170+ stanów)
│   ├── ProphetMemory.json               ← Prophet apps database
│   ├── BrainState.json                  ← Neural Brain weights
│   ├── EnsembleWeights.json             ← Ensemble voting state
│   ├── ChainPredictor.json              ← Markov chains
│   ├── LoadPredictor.json               ← Time series patterns
│   ├── NetworkAI.json                   ← Network optimization
│   ├── GeneticThresholds.json           ← Genetic algorithm
│   ├── BanditState.json                 ← Thompson Sampling
│   ├── SelfTunerState.json              ← Adaptive tuner
│   ├── AnomalyDetector.json             ← Anomaly detection
│   └── AICoordinator.json               ← Master coordinator
│
├── 📁 Configuration Files
│   ├── CPUConfig.json                   ← Konfiguracja główna
│   ├── AIEngines.json                   ← Status silników AI (ON/OFF)
│   └── AppCategories.json               ← Kategorie aplikacji + HardLock
│
├── 📁 Runtime Data
│   ├── WidgetData.json                  ← Real-time widget data
│   └── bledy.txt                        ← Error log (ENGINE + CONFIGURATOR)
│
└── 📁 Backup & Cache
    ├── TransferCache.json               ← AI knowledge transfer cache
    └── NetworkStats.Console.json        ← Network usage backup
```

### Komponenty Główne

#### 1. **ENGINE (CPUManager_v40.ps1)**

Główny silnik systemu odpowiedzialny za:
- ✅ Dynamiczną kontrolę TDP przez RyzenAdj (AMD) lub Intel Speed Shift
- ✅ Koordynację 18+ silników AI
- ✅ Monitorowanie CPU, GPU, RAM, I/O, Temperatury
- ✅ Hierarchię decyzji 8-poziomową
- ✅ Auto-learning i adaptację do wzorców użytkownika

**Główne moduły:**

```powershell
# 1. Detekcja sprzętu (CPU/GPU)
Detect-CPU           # AMD Ryzen / Intel 10-14 gen
Detect-GPU           # iGPU / dGPU (Intel/AMD/NVIDIA)

# 2. RAMManager - Ultra-fast MMF storage
[RAMManager]::new("MainEngine")  # Lock-free double-buffering

# 3. Silniki AI (18+ komponentów)
[QLearningAgent]     # Reinforcement learning
[ProphetMemory]      # App categorization
[NeuralBrain]        # Deep neural analysis
[EnsembleVoting]     # Consensus intelligence
[GPUBoundDetector]   # GPU-bound scenarios

# 4. Główna pętla decyzyjna
while ($true) {
    # Zbierz metryki
    $metrics = Get-SystemMetrics
    
    # AI Decision
    $mode = AI-Decision-Hierarchy($metrics)
    
    # Zastosuj TDP
    Set-RyzenAdjMode -Mode $mode
    
    # Zapisz stan
    Save-State -AllEngines
    
    Start-Sleep -Milliseconds 2000
}
```

#### 2. **CONFIGURATOR (CPUManager_Configurator_v40.ps1)**

Graficzny interfejs użytkownika z 6 zakładkami:

```powershell
# Windows Forms GUI
[System.Windows.Forms.Application]::EnableVisualStyles()

$mainForm = New-Object System.Windows.Forms.Form
$mainForm.Text = "CPUManager Configurator v40"
$mainForm.Size = [System.Drawing.Size]::new(1200, 900)

# 6 głównych zakładek
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Tabs.Add("Dashboard")      # Real-time monitoring
$tabControl.Tabs.Add("Database")       # Prophet Memory viewer
$tabControl.Tabs.Add("Settings AMD")   # TDP profiles editor
$tabControl.Tabs.Add("AI Engines")     # AI control panel
$tabControl.Tabs.Add("App Categories") # Manual categorization
$tabControl.Tabs.Add("Advanced")       # Expert settings
```

---

## 🧠 18+ Silników AI

### 1. **Q-Learning Agent** - Reinforcement Learning

**Typ:** Uczenie przez wzmacnianie  
**Algorytm:** Q-Learning z exploration/exploitation  
**Plik:** `QLearning.json`

```powershell
class QLearningAgent {
    [hashtable] $QTable        # State-Action values
    [double] $LearningRate     # α = 0.1 (domyślnie)
    [double] $DiscountFactor   # γ = 0.9
    [double] $Epsilon          # ε = 0.2 (exploration rate)
    
    [string] GetBestAction([string]$state) {
        # Epsilon-greedy policy
        if ([Math]::Rand() < $this.Epsilon) {
            return $this.RandomAction()  # Explore
        }
        return $this.MaxAction($state)   # Exploit
    }
    
    [void] Update([string]$state, [string]$action, [double]$reward) {
        # Q(s,a) ← Q(s,a) + α[r + γ·max_a'Q(s',a') - Q(s,a)]
        $oldValue = $this.QTable["$state-$action"]
        $nextMax = $this.GetMaxQ($nextState)
        $newValue = $oldValue + $this.LearningRate * ($reward + $this.DiscountFactor * $nextMax - $oldValue)
        $this.QTable["$state-$action"] = $newValue
    }
}
```

**Stany (170+):**
- Format: `C{CPU/20}G{GPU/25}` → np. `C2G1` = CPU 40-60%, GPU 25-50%
- CPU bins: C0 (0-20%), C1 (20-40%), C2 (40-60%), C3 (60-80%), C4 (80-100%)
- GPU bins: G0 (0-25%), G1 (25-50%), G2 (50-75%), G3 (75-100%)

**Akcje:** `Silent`, `Balanced`, `Turbo`

**Nagroda:**
```powershell
# Prawidłowy tryb dla obciążenia = +1.0
if ($mode -eq "Turbo" -and $cpu -gt 50) { $reward = 1.0 }
elseif ($mode -eq "Silent" -and $cpu -lt 30) { $reward = 1.0 }
elseif ($mode -eq "Balanced" -and $cpu -ge 30 -and $cpu -le 60) { $reward = 1.0 }
else { $reward = 0.3 }  # Suboptymalne
```

---

### 2. **Prophet Memory** - Application Learning

**Typ:** Supervised learning z kategoryzacją  
**Algorytm:** Confidence-based classification  
**Plik:** `ProphetMemory.json`

```powershell
class ProphetMemory {
    [hashtable] $Apps          # { AppName -> AppInfo }
    [int] $MinConfidenceSamples = 30  # Potrzebne próbki do CONF
    
    class AppInfo {
        [string] $Category        # HEAVY / MEDIUM / LIGHT / LEARNING_*
        [int] $Samples            # Liczba próbek
        [double] $AvgCPU          # Średnie CPU
        [double] $AvgIO           # Średnie I/O
        [DateTime] $LastSeen
    }
    
    [void] RecordLaunch([string]$app, [double]$cpu, [double]$io, [string]$displayName) {
        if (-not $this.Apps.ContainsKey($app)) {
            $this.Apps[$app] = [AppInfo]@{
                Category = "LEARNING_NEW"
                Samples = 0
                AvgCPU = 0
                AvgIO = 0
                LastSeen = Get-Date
            }
        }
        
        $info = $this.Apps[$app]
        $info.Samples++
        $info.AvgCPU = ($info.AvgCPU * ($info.Samples - 1) + $cpu) / $info.Samples
        $info.AvgIO = ($info.AvgIO * ($info.Samples - 1) + $io) / $info.Samples
        $info.LastSeen = Get-Date
        
        # Auto-categorization po MinConfidenceSamples
        if ($info.Samples -ge $this.MinConfidenceSamples) {
            $info.Category = $this.CategorizeApp($info.AvgCPU, $info.AvgIO)
        }
    }
    
    [string] CategorizeApp([double]$cpu, [double]$io) {
        $score = $cpu + ($io * 2)
        if ($score -gt 80 -or $cpu -gt 60) { return "HEAVY" }
        elseif ($score -gt 40 -or $cpu -gt 30) { return "MEDIUM" }
        else { return "LIGHT" }
    }
    
    [bool] IsCategoryConfident([string]$app) {
        if (-not $this.Apps.ContainsKey($app)) { return $false }
        $info = $this.Apps[$app]
        return $info.Samples -ge $this.MinConfidenceSamples -and 
               $info.Category -notmatch "^LEARNING_"
    }
}
```

**Kategorie:**
- `HEAVY` - Gry, rendering (> 80 score lub > 60% CPU)
- `MEDIUM` - Przeglądarki, IDE (40-80 score)
- `LIGHT` - Edytory tekstu, multimedia (< 40 score)
- `LEARNING_NEW` - Nowa aplikacja (< 30 próbek)
- `LEARNING_LIGHT/MEDIUM/HEAVY` - Uczenie się (< 30 próbek)

**Ciągłe uczenie (UpdateRunning):**
```powershell
[void] UpdateRunning([string]$app, [double]$cpu, [double]$io) {
    # Aktualizuj dane co ~10s podczas pracy aplikacji
    if ($this.Apps.ContainsKey($app)) {
        $info = $this.Apps[$app]
        $info.Samples++
        $info.AvgCPU = ($info.AvgCPU * 0.95) + ($cpu * 0.05)  # EMA
        $info.AvgIO = ($info.AvgIO * 0.95) + ($io * 0.05)
        
        # Re-kategoryzuj jeśli confident
        if ($info.Samples -ge $this.MinConfidenceSamples) {
            $info.Category = $this.CategorizeApp($info.AvgCPU, $info.AvgIO)
        }
    }
}
```

---

### 3. **Neural Brain** - Deep Neural Analysis

**Typ:** Neural network inspired  
**Algorytm:** Weight-based decision with bias evolution  
**Plik:** `BrainState.json`

```powershell
class NeuralBrain {
    [hashtable] $Weights           # { ProcessName -> Weight (0.0-1.0) }
    [double] $AggressionBias       # -0.5 to +0.5 (ewolucja)
    [double] $ReactivityBias       # -0.5 to +0.5
    [double] $RAMWeight            # 0.1 to 1.0 (waga RAM spike)
    
    [string] Train([string]$process, [string]$displayName, [double]$cpu, [double]$io, $prophet) {
        $score = $cpu + ($io * 2)
        $weight = 0.3  # Domyślna waga
        
        if ($score -gt 50 -or $cpu -gt 40) { $weight = 1.0 }  # Heavy
        elseif ($score -gt 20) { $weight = 0.6 }              # Medium
        
        $this.Weights[$process] = $weight
        
        # Synchronizuj z Prophet
        if ($prophet.Apps.ContainsKey($process)) {
            $category = $prophet.Apps[$process].Category
            return "UPD [$category] CPU:$([int]$cpu)% IO:$([int]$io)"
        }
        return "NEW CPU:$([int]$cpu)% IO:$([int]$io)"
    }
    
    [hashtable] Decide([double]$cpu, [double]$io, [double]$trend, $prophet, [double]$ram, [bool]$ramSpike) {
        # Bazowe ciśnienie
        $ioMultiplier = 0.5 + ($this.ReactivityBias * 0.2)
        $pressure = $cpu * 0.7 + [Math]::Min(40, $io * $ioMultiplier)
        
        # RAM spike bonus
        if ($ramSpike) {
            $pressure += 30 * $this.RAMWeight
        } elseif ($ram -gt 80) {
            $pressure += 20 * $this.RAMWeight
        }
        
        # Known apps boost
        if ($prophet.LastActiveApp -and $this.Weights.ContainsKey($prophet.LastActiveApp)) {
            $weight = $this.Weights[$prophet.LastActiveApp]
            if ($weight -ge 0.8) { $pressure += 15 }
            elseif ($weight -ge 0.5) { $pressure += 5 }
        }
        
        # AggressionBias
        $pressure += ($this.AggressionBias * 5)
        $pressure = [Math]::Clamp($pressure, 0, 100)
        
        # Sugestia trybu (nie wymuszenie!)
        $suggestion = if ($pressure -gt 75) { "Turbo" } 
                     elseif ($pressure -lt 30) { "Silent" } 
                     else { "Balanced" }
        
        return @{ 
            Score = [Math]::Round($pressure, 1)
            Suggestion = $suggestion
            Reason = "Neural: pressure=$([int]$pressure)"
            Trend = $trend
        }
    }
    
    [void] Evolve([string]$action) {
        # Ewolucja bias na podstawie akcji
        switch ($action) {
            "Turbo" { 
                $this.AggressionBias = [Math]::Min(0.5, $this.AggressionBias + 0.08)
                $this.ReactivityBias = [Math]::Min(0.5, $this.ReactivityBias + 0.05)
            }
            "Silent" { 
                $this.AggressionBias = [Math]::Max(-0.5, $this.AggressionBias - 0.08)
                $this.ReactivityBias = [Math]::Max(-0.5, $this.ReactivityBias - 0.05)
            }
            "Balanced" { 
                $this.AggressionBias *= 0.9  # Decay
                $this.ReactivityBias *= 0.95
            }
        }
    }
}
```

---

### 4. **Ensemble Voting** - Consensus Intelligence

**Typ:** Ensemble method  
**Algorytm:** Weighted majority voting  
**Plik:** `EnsembleWeights.json`

```powershell
class EnsembleVoting {
    [hashtable] $ModelWeights      # { ModelName -> Weight }
    [int] $TotalVotes
    
    [string] Vote([hashtable]$modelDecisions, [double]$ram, [bool]$ramSpike) {
        # Zbierz głosy z wszystkich modeli
        $votes = @{
            "Turbo" = 0.0
            "Balanced" = 0.0
            "Silent" = 0.0
        }
        
        foreach ($model in $modelDecisions.Keys) {
            $decision = $modelDecisions[$model]
            $weight = if ($this.ModelWeights.ContainsKey($model)) { 
                $this.ModelWeights[$model] 
            } else { 1.0 }
            
            $votes[$decision] += $weight
        }
        
        # RAM spike bonus dla Turbo
        if ($ramSpike) {
            $votes["Turbo"] += 2.0
        }
        
        # Wybierz tryb z najwyższym score
        $winner = $votes.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1
        $this.TotalVotes++
        
        return $winner.Key
    }
    
    [void] UpdateWeights([string]$model, [bool]$wasSuccessful) {
        if (-not $this.ModelWeights.ContainsKey($model)) {
            $this.ModelWeights[$model] = 1.0
        }
        
        # Zwiększ wagę jeśli sukces, zmniejsz jeśli porażka
        if ($wasSuccessful) {
            $this.ModelWeights[$model] = [Math]::Min(2.0, $this.ModelWeights[$model] + 0.1)
        } else {
            $this.ModelWeights[$model] = [Math]::Max(0.1, $this.ModelWeights[$model] - 0.05)
        }
    }
}
```

**Transfer wiedzy (v43.8):**
```powershell
# AICoordinator zarządza transferem wiedzy
class AICoordinator {
    [void] IntegrateProphetData() {
        # Prophet → TransferData
        foreach ($app in $prophet.Apps.Keys) {
            $info = $prophet.Apps[$app]
            $this.TransferData.AppPatterns[$app] = @{
                Category = $info.Category
                AvgCPU = $info.AvgCPU
                Samples = $info.Samples
            }
        }
    }
    
    [void] ApplyEnrichedToEnsemble() {
        # TransferData → Ensemble weights
        # Blend 70/30: 70% TransferData, 30% Prophet
        $ensemble.ModelWeights["Prophet"] = 0.3
        $ensemble.ModelWeights["QLearning"] = 0.7
    }
    
    [void] TransferBackFromEnsemble() {
        # Ensemble OFF → oddaj wiedzę
        $qLearning.ImportData($this.TransferData)
        $prophet.ImportData($this.TransferData)
    }
}
```

---

### 5. **GPU-Bound Detector** - Innovation v42.4

**Typ:** Heuristic detection + Timer-based hysteresis  
**Algorytm:** Multi-condition check with confidence  
**Plik:** Wbudowany w ENGINE (brak osobnego pliku)

```powershell
class GPUBoundDetector {
    [bool] $IsConfident
    [int] $Confidence
    [DateTime] $ExitPendingStart
    [int] $ExitTimerSeconds = 3
    
    [hashtable] Detect([double]$cpu, [double]$gpu, [bool]$hasGPU, [string]$gpuType) {
        # Entry conditions (instant)
        $isGPUBound = $cpu -lt 50 -and $gpu -gt 75 -and $hasGPU
        
        if ($isGPUBound) {
            if (-not $this.IsConfident) {
                $this.Confidence = [Math]::Min(100, $this.Confidence + 20)
                if ($this.Confidence -ge 100) {
                    $this.IsConfident = $true
                }
            }
            $this.ExitPendingStart = [DateTime]::MinValue  # Reset exit timer
        }
        # Exit conditions (timer-based)
        else {
            if ($this.IsConfident -and $cpu -gt 50) {
                # Start exit timer
                if ($this.ExitPendingStart -eq [DateTime]::MinValue) {
                    $this.ExitPendingStart = Get-Date
                }
                
                # Check if timer expired
                $elapsed = ([DateTime]::Now - $this.ExitPendingStart).TotalSeconds
                if ($elapsed -ge $this.ExitTimerSeconds) {
                    # Exit confirmed
                    $this.IsConfident = $false
                    $this.Confidence = 0
                    $isGPUBound = $false
                } else {
                    # Stay GPU-bound (timer pending)
                    $isGPUBound = $true
                }
            }
        }
        
        # Intelligent CPU TDP reduction
        $cpuReduction = 0
        if ($isGPUBound) {
            if ($cpu -lt 30) { $cpuReduction = 15 }      # -15W
            elseif ($cpu -lt 40) { $cpuReduction = 10 }  # -10W
            else { $cpuReduction = 5 }                   # -5W
        }
        
        return @{
            IsGPUBound = $isGPUBound
            SuggestedMode = if ($isGPUBound) { "Balanced" } else { "Turbo" }
            CPUReduction = $cpuReduction
            Confidence = $this.Confidence
            Reason = if ($isGPUBound) { 
                "GPU-BOUND: CPU=$([int]$cpu)% GPU=$([int]$gpu)% (TDP -${cpuReduction}W)" 
            } else { 
                "Not GPU-bound" 
            }
        }
    }
}
```

**Efekty GPU-Bound:**
- ✅ Redukcja TDP CPU: 5-15W (inteligentna, zależna od obciążenia)
- ✅ Temperatura CPU: -10-15°C (lepsza termika)
- ✅ Temperatura GPU: -4-7°C (więcej headroom dla GPU boost)
- ✅ GPU Clock: +50-100MHz (lepsze warunki termalne)
- ✅ FPS: +2-5% (przy mniejszym zużyciu energii!)
- ✅ Stabilność: Timer-based exit (brak ping-pong Silent Hill 40-55% CPU)

**Przykład działania (Silent Hill):**
```
CPU 30-55% zmienne, GPU 95%:
[t=0s]  CPU=45%, GPU=95% → GPU-BOUND entry ✅ (instant)
[t=2s]  CPU=52%, GPU=95% → EXIT pending 0/3s (stay GPU-bound) ✅
[t=3s]  CPU=48%, GPU=95% → EXIT cancelled (stay GPU-bound) ✅
[t=5s]  CPU=54%, GPU=95% → EXIT pending 0/3s (stay GPU-bound) ✅
[t=8s]  CPU=56%, GPU=95% → EXIT pending 3/3s → TURBO ✅

Rezultat: Mode stabilny przez 8 sekund! (było: ping-pong co 2s)
```

---

### 6-18. Pozostałe Silniki AI (Skrócona Dokumentacja)

#### **Thompson Sampling Bandit**
- **Typ:** Multi-armed bandit
- **Algorytm:** Beta distribution (α, β)
- **Plik:** `BanditState.json`
- **Funkcja:** Eksploracja vs eksploatacja trybów CPU

#### **Genetic Optimizer**
- **Typ:** Evolutionary algorithm
- **Algorytm:** Mutation + Crossover
- **Plik:** `GeneticThresholds.json`
- **Funkcja:** Ewolucyjne progi dla CPU/IO/Temp

#### **Chain Predictor**
- **Typ:** Markov chains
- **Algorytm:** Transition graph
- **Plik:** `ChainPredictor.json`
- **Funkcja:** Przewiduje kolejną aplikację

#### **Load Predictor**
- **Typ:** Time series forecasting
- **Algorytm:** Hourly patterns + day-of-week
- **Plik:** `LoadPredictor.json`
- **Funkcja:** Wyprzedza optymalizacje

#### **Self Tuner**
- **Typ:** Adaptive learning
- **Algorytm:** Dynamic threshold adjustment
- **Plik:** `SelfTunerState.json`
- **Funkcja:** Auto-dostrajanie progów

#### **Anomaly Detector**
- **Typ:** Statistical outlier detection
- **Algorytm:** Z-score analysis
- **Plik:** `AnomalyDetector.json`
- **Funkcja:** Wykrywa crypto miners, memory leaks

#### **Context Detector**
- **Typ:** Multi-context classification
- **Algorytm:** Pattern matching + Priority
- **Plik:** `ContextPatterns.json`
- **Funkcja:** Gaming/Audio/Rendering/Coding/Multimedia/Office

#### **Network AI**
- **Typ:** Network pattern learning
- **Algorytm:** Q-Table dla scenariuszy sieciowych
- **Plik:** `NetworkAI.json`
- **Funkcja:** Optymalizacja sieciowa

#### **Energy Optimizer**
- **Typ:** Power efficiency tracker
- **Algorytm:** Balance performance vs wattage
- **Plik:** `EnergyState.json`
- **Funkcja:** Monitoruje zużycie energii

#### **Process Watcher**
- **Typ:** Activity-based monitoring
- **Algorytm:** Blacklist (500+) + Peak tracking
- **Plik:** Wbudowany w ENGINE
- **Funkcja:** Auto-boost nowych aplikacji (10s)

#### **AI Coordinator**
- **Typ:** Master orchestrator
- **Algorytm:** Transfer wiedzy między silnikami
- **Plik:** `AICoordinator.json`
- **Funkcja:** Koordynuje wszystkie silniki AI

#### **Storage Mode Manager**
- **Typ:** Hybrid persistence
- **Algorytm:** Lock-free double-buffering
- **Plik:** Wbudowany (RAM + JSON)
- **Funkcja:** 3 tryby: JSON | RAM | BOTH

#### **HardLock System**
- **Typ:** User control override
- **Algorytm:** Priority-based enforcement
- **Plik:** `AppCategories.json`
- **Funkcja:** Wymusza tryb CPU dla aplikacji

---

## ⚖️ Hierarchia Decyzji

### 8-Poziomowa Hierarchia (v42.5)

```powershell
# HIERARCHIA DECYZJI - od najwyższego priorytetu:

# 0. HARDLOCK (NAJWYŻSZY PRIORYTET)
if ($app.HardLock) {
    $mode = $app.ForcedMode  # Silent / Balanced / Turbo
    return "HARDLOCK: User enforced"
}

# 1. THERMAL (>90°C)
if ($temp -gt 90) {
    return "Silent"  # Zawsze, nawet gdy GPU-bound!
}

# 2. LOADING (I/O>80 + aktywność)
if ($io -gt 80 -and ($cpu -gt 25 -or $gpu -gt 25)) {
    if ($io -gt 150 -and $cpu -gt 50) {
        return "Turbo"     # Heavy I/O
    } else {
        return "Balanced"  # Moderate I/O (quiet)
    }
}

# 3. HIGH LOAD (>70%) + GPU-BOUND CHECK
if ($cpu -gt 70 -or $gpu -gt 70) {
    # GPU-bound scenario?
    if ($cpu -lt 50 -and $gpu -gt 75) {
        $result = $gpuBound.Detect($cpu, $gpu, $hasGPU, $gpuType)
        if ($result.IsGPUBound) {
            return $result.SuggestedMode  # Usually "Balanced" (reduce CPU TDP)
        }
    }
    return "Turbo"  # Normal high load
}

# 4. HOLD TURBO (hysteresis)
if ($prevMode -eq "Turbo" -and $cpu -gt $turboExitThreshold) {
    return "Turbo"  # Stay in Turbo (avoid ping-pong)
}

# 5. HOLD SILENT (hysteresis)
if ($prevMode -eq "Silent" -and $cpu -lt $silentExitThreshold) {
    return "Silent"  # Stay in Silent
}

# 6. PROPHET (znana aplikacja)
if ($prophet.IsCategoryConfident($app)) {
    $category = $prophet.GetCategory($app)
    switch ($category) {
        "HEAVY" { 
            if ($cpu -gt 30 -or $gpu -gt 30) { return "Turbo" }
            elseif ($cpu -gt 15) { return "Balanced" }
            else { return "Silent" }  # Heavy app ale idle
        }
        "LIGHT" { 
            if ($cpu -gt 50 -or $gpu -gt 50) { return "Balanced" }
            else { return "Silent" }
        }
        "MEDIUM" { return "Balanced" }
    }
}

# 7. LOW (<20%)
if ($cpu -lt 20 -and $gpu -lt 20 -and $temp -lt 60) {
    return "Silent"
}

# 8. ENSEMBLE / Q-LEARNING (default)
if ((Is-EnsembleEnabled)) {
    return $ensemble.Vote($modelDecisions)
} else {
    return $qLearning.GetBestAction($state)
}
```

### Kluczowe Mechanizmy Stabilności

#### **Hysteresis Anti-Ping-Pong (v42.5)**

```powershell
# PROBLEM v42.4:
# Silent Hill: CPU 40-55% → Mode ping-pong co 5 sekund
# Wentylator: 2500 RPM ↔ 4000 RPM → IRYTUJĄCE!

# ROZWIĄZANIE v42.5:
# ✅ Entry: CPU < 50% (wyższy próg, łatwiejsze wejście)
# ✅ Exit: CPU > 50% przez 3+ sekund (timer-based!)
# ✅ CPU spike 52% na 1s → ignoruj (timer nie upłynął)
# ✅ CPU 52% przez 5s → exit GPU-bound (confirmed)

# Implementacja:
if ($cpu -gt 50 -and $this.IsConfident) {
    if ($this.ExitPendingStart -eq [DateTime]::MinValue) {
        $this.ExitPendingStart = Get-Date  # Start timer
    }
    
    $elapsed = ([DateTime]::Now - $this.ExitPendingStart).TotalSeconds
    if ($elapsed -ge 3) {
        # Exit confirmed po 3+ sekundach
        $this.IsConfident = $false
        return "Turbo"
    } else {
        # Stay GPU-bound (timer pending)
        return "Balanced"
    }
}
```

---

## 🖥️ Konfigurator GUI

### 6 Głównych Zakładek

#### **1. DASHBOARD - Monitorowanie w Czasie Rzeczywistym**

```
┌─────────────────────────────────────────────────────────────┐
│ CPUManager Dashboard - Real-time Monitoring                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ 📊 CPU Usage: ████████░░ 78%     🌡️ Temp: 67°C           │
│ 🎮 GPU Load:  ██████████ 95%     💾 RAM:  56%             │
│                                                             │
│ ⚡ Current Mode: [TURBO]          🤖 AI: ACTIVE            │
│                                                             │
│ 📱 Active App: Silent Hill 2 Remake                        │
│                                                             │
│ 📈 Live Charts:                                             │
│    ┌─ CPU History (60s) ────────────────────────────┐     │
│    │  100%│                          ██              │     │
│    │   75%│              ████████████████████        │     │
│    │   50%│  ████████████████████████████████████    │     │
│    │   25%│                                          │     │
│    │    0%└────────────────────────────────────────┘│     │
│    └──────────────────────────────────────────────────┘     │
│                                                             │
│ 🔔 AI Activity Log (Last 50 events):                       │
│    [15:32:45] GPU-BOUND detected: CPU=45% GPU=95%          │
│    [15:32:47] Mode: Balanced (TDP -10W for GPU headroom)   │
│    [15:32:52] CPU spike to 52% - EXIT pending 0/3s         │
│    [15:32:55] CPU stable at 48% - EXIT cancelled           │
│    [15:33:10] Prophet: Silent Hill 2 = HEAVY (CONF)        │
│                                                             │
│ 📊 Telemetry:                                               │
│    • GPU-Bound Events: 23                                  │
│    • Boost Count: 156                                      │
│    • Mode Changes: 487                                     │
│    • Uptime: 2h 15m                                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Funkcje:**
- ✅ Real-time CPU/GPU/RAM/Temp monitoring
- ✅ Live charts (60s history)
- ✅ AI Activity log (ostatnie 50 zdarzeń)
- ✅ Telemetria (GPU-Bound events, Boost count, Mode changes)
- ✅ DisplayName detection (automatyczne nazwy aplikacji)

---

#### **2. DATABASE - Przeglądarka Pamięci Prophet**

```
┌─────────────────────────────────────────────────────────────┐
│ Prophet Memory Database - Learned Applications             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ 🔍 Search: [____________] [Refresh] [Export to CSV]        │
│                                                             │
│ Filter: [All] [HEAVY] [MEDIUM] [LIGHT] [LEARNING]          │
│                                                             │
│ ┌───────────────────────────────────────────────────────┐ │
│ │ Application        │ Category │ Samples │ Last Seen   │ │
│ ├───────────────────────────────────────────────────────┤ │
│ │ Cyberpunk 2077     │ HEAVY    │ 147     │ 2m ago      │ │
│ │ Cubase 13          │ HEAVY    │ 89      │ 15m ago     │ │
│ │ Google Chrome      │ MEDIUM   │ 523     │ Now         │ │
│ │ Notepad++          │ LIGHT    │ 234     │ 5m ago      │ │
│ │ Discord            │ LIGHT    │ 178     │ 1m ago      │ │
│ │ Blender            │ HEAVY    │ 45      │ 1h ago      │ │
│ │ Visual Studio Code │ MEDIUM   │ 312     │ 3m ago      │ │
│ │ New App            │ LEARNING │ 12/30   │ Just now    │ │
│ └───────────────────────────────────────────────────────┘ │
│                                                             │
│ ℹ️ Total Apps: 247 | HEAVY: 67 | MEDIUM: 102 | LIGHT: 78  │
│                                                             │
│ 🛠️ Actions:                                                │
│    [Edit Selected] [Delete Selected] [Reset Category]      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Funkcje:**
- ✅ Lista wszystkich poznanych aplikacji
- ✅ Kategorie: HEAVY / MEDIUM / LIGHT / LEARNING_*
- ✅ Samples count (mechanizm confidence)
- ✅ Last Seen timestamp
- ✅ Manual override: zmiana kategorii przez użytkownika
- ✅ Export do CSV

---

#### **3. SETTINGS AMD/INTEL - Edytor Profili TDP**

```
┌─────────────────────────────────────────────────────────────┐
│ TDP Profiles Editor - AMD Ryzen 7 5800H                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ Profile: [Silent ▼] [Balanced] [Turbo] [Extreme]           │
│                                                             │
│ ┌─ Silent Profile ──────────────────────────────────────┐ │
│ │                                                         │ │
│ │ STAPM Limit (W):  [12] ─────●───────── [15-25]         │ │
│ │ Fast Boost (W):   [18] ─────●───────── [20-35]         │ │
│ │ Slow Boost (W):   [15] ─────●───────── [18-30]         │ │
│ │ Tctl Temp (°C):   [75] ─────●───────── [65-90]         │ │
│ │                                                         │ │
│ │ Min/Max CPU (%):  [50] ─●── [85] ─●──── [0-100]        │ │
│ │                                                         │ │
│ └─────────────────────────────────────────────────────────┘ │
│                                                             │
│ ⚠️ Safety Limits:                                           │
│    • Max STAPM: 28W (Extreme profile)                      │
│    • Max Fast: 40W                                         │
│    • Max Tctl: 92°C                                        │
│                                                             │
│ 📊 Live Preview:                                            │
│    Current: Balanced (18W / 30W / 25W / 85°C)              │
│    If changed to Silent: 12W / 18W / 15W / 75°C            │
│    Estimated temp drop: -8-12°C                            │
│                                                             │
│ [Validate TDP] [Save Profile] [Reset to Defaults]          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Funkcje:**
- ✅ 4 profile: Silent | Balanced | Turbo | Extreme
- ✅ Edycja STAPM / Fast / Slow / Tctl dla każdego trybu
- ✅ Validate-TDP: automatyczne bezpieczniki przed zapisem
- ✅ Live preview zmian
- ✅ Slidery z zakresami (15-25W, 20-35W, etc.)

---

#### **4. AI ENGINES - Kontrola Silników**

```
┌─────────────────────────────────────────────────────────────┐
│ AI Engines Control Panel                                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ ┌─ Core AI Engines ────────────────────────────────────┐  │
│ │ [✓] Q-Learning Agent       (170 states learned)      │  │
│ │ [✓] Prophet Memory         (247 apps known)          │  │
│ │ [✓] Neural Brain           (1,523 decisions)         │  │
│ │ [✓] Ensemble Voting        (456 votes cast)          │  │
│ │ [✓] GPU-Bound Detector     (23 events detected)      │  │
│ └──────────────────────────────────────────────────────┘  │
│                                                             │
│ ┌─ Advanced AI Engines ────────────────────────────────┐  │
│ │ [✓] Thompson Sampling Bandit                         │  │
│ │ [✓] Genetic Optimizer                                │  │
│ │ [✓] Chain Predictor        (89 chains learned)       │  │
│ │ [✓] Load Predictor         (24h patterns)            │  │
│ │ [✓] Self Tuner             (auto-adjusting)          │  │
│ │ [✓] Anomaly Detector       (2 alerts)                │  │
│ │ [✓] Context Detector       (Gaming mode)             │  │
│ │ [✓] Network AI                                        │  │
│ │ [✓] Energy Optimizer                                  │  │
│ │ [✓] Process Watcher                                   │  │
│ │ [✓] AI Coordinator         (master)                   │  │
│ │ [✓] Storage Mode Manager   (BOTH mode)               │  │
│ │ [✓] HardLock System        (12 apps locked)          │  │
│ └──────────────────────────────────────────────────────┘  │
│                                                             │
│ 🔧 Batch Operations:                                        │
│    [Enable ALL] [Disable ALL] [Reset to Defaults]          │
│                                                             │
│ 💾 [Save AI Engines] → AIEngines.json                      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Funkcje:**
- ✅ Enable/Disable dla każdego z 18+ silników
- ✅ Counters: Apps (Prophet), Decisions (Brain), Chains (ChainPredictor)
- ✅ Enable ALL / Disable ALL (batch operations)
- ✅ Save AI Engines → AIEngines.json
- ✅ Real-time status każdego silnika

---

#### **5. APP CATEGORIES - Ręczna Kategoryzacja**

```
┌─────────────────────────────────────────────────────────────┐
│ Application Categories & HardLock                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ 🔍 Search: [____________] [Add New App]                     │
│                                                             │
│ ┌───────────────────────────────────────────────────────┐ │
│ │ App Name          │ Category    │ Lock │ Actions     │ │
│ ├───────────────────────────────────────────────────────┤ │
│ │ Cyberpunk 2077    │ [HEAVY ▼]   │ [✓]  │ [Edit] [❌] │ │
│ │ Google Chrome     │ [MEDIUM ▼]  │ [ ]  │ [Edit] [❌] │ │
│ │ Notepad++         │ [LIGHT ▼]   │ [ ]  │ [Edit] [❌] │ │
│ │ Cubase 13         │ [HEAVY ▼]   │ [✓]  │ [Edit] [❌] │ │
│ │ Discord           │ [AUTO ▼]    │ [ ]  │ [Edit] [❌] │ │
│ └───────────────────────────────────────────────────────┘ │
│                                                             │
│ ℹ️ HardLock: Wymusza tryb CPU dla aplikacji (blokuje AI)   │
│    • HEAVY → Turbo                                          │
│    • MEDIUM → Balanced                                      │
│    • LIGHT → Silent                                         │
│    • AUTO → AI decyduje                                     │
│                                                             │
│ 🛠️ Batch Operations:                                        │
│    [Set All to HEAVY] [Set All to LIGHT] [Clear All Locks] │
│                                                             │
│ 💾 [Save Categories] → AppCategories.json                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Funkcje:**
- ✅ Lista aplikacji z dropdown: HEAVY / MEDIUM / LIGHT / AUTO
- ✅ HardLock checkbox (wymuszenie trybu, blokuje AI)
- ✅ Batch selection: Set All to HEAVY/LIGHT
- ✅ Delete selected apps
- ✅ Add new app manually

---

#### **6. ADVANCED - Ustawienia Eksperckie**

```
┌─────────────────────────────────────────────────────────────┐
│ Advanced Settings - Expert Configuration                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ ┌─ Hysteresis & Stability ──────────────────────────────┐ │
│ │ Silent Hold Seconds:  [3] ───●─────── [1-10]          │ │
│ │ Turbo Hold Seconds:   [5] ───●─────── [1-10]          │ │
│ │ GPU-Bound Exit Timer: [3] ───●─────── [1-10]          │ │
│ └────────────────────────────────────────────────────────┘ │
│                                                             │
│ ┌─ CPU Thresholds ──────────────────────────────────────┐ │
│ │ Silent CPU (%):       [20] ──●────── [10-40]           │ │
│ │ Balanced CPU (%):     [35] ──●────── [20-60]           │ │
│ │ Turbo CPU (%):        [70] ──●────── [50-90]           │ │
│ │ High CPU (%):         [70] ──●────── [60-95]           │ │
│ └────────────────────────────────────────────────────────┘ │
│                                                             │
│ ┌─ Temperature Limits ───────────────────────────────────┐ │
│ │ Force Silent Temp:    [90] ──●────── [75-95]           │ │
│ │ Warning Temp:         [85] ──●────── [70-90]           │ │
│ └────────────────────────────────────────────────────────┘ │
│                                                             │
│ ┌─ AI Parameters ───────────────────────────────────────┐ │
│ │ Confidence Threshold: [70] ──●────── [50-90]           │ │
│ │ Learning Rate:        [0.1] ─●────── [0.01-0.5]        │ │
│ │ Exploration Rate:     [0.2] ─●────── [0.0-0.5]         │ │
│ └────────────────────────────────────────────────────────┘ │
│                                                             │
│ ┌─ Storage Mode ────────────────────────────────────────┐ │
│ │ Mode: ⦿ JSON   ○ RAM   ○ BOTH (Hybrid)                │ │
│ │ Auto-Backup Interval: [150] iterations (~5 min)        │ │
│ └────────────────────────────────────────────────────────┘ │
│                                                             │
│ [Validate Settings] [Save All] [Reset to Defaults]         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Funkcje:**
- ✅ Hysteresis timing (SilentHoldSeconds, TurboHoldSeconds, GPU-Bound Exit Timer)
- ✅ CPU thresholds (SilentCPU, BalancedCPU, TurboCPU, HighCPU)
- ✅ Temperature limits (ForceSilentTemp, WarningTemp)
- ✅ AI parameters (ConfidenceThreshold, LearningRate, ExplorationRate)
- ✅ Storage Mode: JSON | RAM | BOTH (Hybrid)
- ✅ Auto-Backup Interval (150 iteracji = ~5 minut)

---

## 🚀 Instalacja

### Wymagania Systemowe

#### **Obsługiwane Procesory:**
- ✅ **AMD Ryzen 3000-9000 series** (Zen 2, Zen 3, Zen 4, Zen 5)
  - Ryzen 3000: Zen 2 (Matisse, Renoir)
  - Ryzen 5000: Zen 3 (Vermeer, Cezanne)
  - Ryzen 7000: Zen 4 (Raphael, Phoenix)
  - Ryzen 9000: Zen 5 (Granite Ridge)
- ✅ **AMD Ryzen APU** (Vega, RDNA2, RDNA3 zintegrowane)
- ✅ **Intel 10-14 generacji**
  - 10th Gen: Comet Lake
  - 11th Gen: Rocket Lake
  - 12th Gen: Alder Lake (Hybrid P+E cores)
  - 13th Gen: Raptor Lake (Hybrid P+E cores)
  - 14th Gen: Raptor Lake Refresh (Hybrid P+E cores)
- ✅ **Intel Hybrid CPU** (P-cores + E-cores): auto-wykrywanie

#### **System:**
- Windows 10 (x64) lub Windows 11 (x64)
- PowerShell 5.1+ lub PowerShell Core 7+
- .NET Framework 4.7.2+ (dla GUI)
- Uprawnienia administratora (do kontroli TDP/PowerShell)

#### **GPU (opcjonalnie):**
- Intel UHD/Iris (iGPU)
- AMD Radeon Vega/680M/780M (APU)
- NVIDIA GeForce (dGPU)
- AMD Radeon RX (dGPU)

#### **Narzędzia Pomocnicze (zalecane, opcjonalne):**

**Monitoring Sprzętu (poprawia dokładność odczytów):**
- ⭐ **OpenHardwareMonitor (OHM)** lub **LibreHardwareMonitor (LHM)**
  - Pobierz: https://openhardwaremonitor.org/ lub https://github.com/LibreHardwareMonitor/LibreHardwareMonitor
  - Uruchom przed CPUManager dla lepszego monitoringu temperatury/GPU
  - **Opcjonalne** - system działa także bez tego

**Kontrola TDP dla AMD (wbudowane, ale można zaktualizować):**
- ⭐ **RyzenAdj** - wbudowany w CPUManager jako `RyzenAdj.exe`
  - Najnowsza wersja: https://github.com/FlyGoat/RyzenAdj/releases
  - Zamień `RyzenAdj.exe` w folderze `C:\CPUManager\` jeśli chcesz zaktualizować
  - **Wymagane tylko dla AMD Ryzen** - Intel nie potrzebuje

### Kroki Instalacji

#### **0. (Opcjonalnie) Zainstaluj Narzędzia Pomocnicze**

**Dla lepszego monitoringu (zalecane, ale nie wymagane):**

```powershell
# Pobierz i zainstaluj OpenHardwareMonitor LUB LibreHardwareMonitor

# OpenHardwareMonitor:
# 1. Pobierz: https://openhardwaremonitor.org/downloads/
# 2. Rozpakuj gdziekolwiek (np. C:\Tools\OpenHardwareMonitor\)
# 3. Uruchom OpenHardwareMonitor.exe jako Administrator
# 4. Zostaw włączone w tle (minimalizuj do tray)

# LibreHardwareMonitor (zalecany dla Ryzen 7000/9000, Intel 13th/14th gen):
# 1. Pobierz: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases
# 2. Rozpakuj gdziekolwiek (np. C:\Tools\LibreHardwareMonitor\)
# 3. Uruchom LibreHardwareMonitor.exe jako Administrator
# 4. Zostaw włączone w tle (minimalizuj do tray)

# CPUManager automatycznie wykryje działające narzędzie i użyje jego danych
# Bez narzędzia: system użyje wbudowanych API Windows (mniej dokładne)
```

**Dla AMD Ryzen - Aktualizacja RyzenAdj (opcjonalnie):**

```powershell
# RyzenAdj jest już wbudowany w CPUManager
# Ale możesz zaktualizować do najnowszej wersji:

# 1. Pobierz: https://github.com/FlyGoat/RyzenAdj/releases
# 2. Rozpakuj archiwum
# 3. Skopiuj ryzenadj.exe do C:\CPUManager\RyzenAdj.exe (zastąp stary)

# Uwaga: Tylko dla AMD Ryzen! Intel nie potrzebuje RyzenAdj.
```

#### **1. Pobierz i Rozpakuj**

```powershell
# 1. Pobierz archiwum CPUManager_v40.zip
# 2. Rozpakuj do C:\CPUManager\
# 3. Struktura powinna wyglądać tak:

C:\CPUManager\
├── CPUManager_v40.ps1
├── CPUManager_Configurator_v40.ps1
├── RyzenAdj.exe
└── (pliki konfiguracyjne zostaną utworzone przy pierwszym uruchomieniu)
```

#### **2. Uruchom jako Administrator**

```powershell
# Otwórz PowerShell jako Administrator
# Prawy przycisk myszy na PowerShell → "Uruchom jako administrator"

# Przejdź do folderu
cd C:\CPUManager

# Zezwól na wykonywanie skryptów (jednorazowo)
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Uruchom ENGINE
.\CPUManager_v40.ps1
```

#### **3. (Opcjonalnie) Uruchom GUI**

```powershell
# W osobnym oknie PowerShell (jako Administrator)
cd C:\CPUManager
.\CPUManager_Configurator_v40.ps1
```

#### **4. Automatyczne Uruchamianie (opcjonalnie)**

**Metoda 1: Task Scheduler**
```powershell
# Utwórz zaplanowane zadanie
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\CPUManager\CPUManager_v40.ps1"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName "CPUManager" -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings
```

**Metoda 2: Skrót w Autostart**
```powershell
# Skrypt tworzy automatycznie skrót na pulpicie przy pierwszym uruchomieniu
# Przenieś go do folderu Autostart:
# C:\Users\{USER}\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\
```

---

## ⚙️ Konfiguracja

### Pliki Konfiguracyjne

#### **CPUConfig.json** - Główna Konfiguracja

```json
{
  "CPUType": "AMD",
  "SilentThreshold": 20,
  "BalancedThreshold": 35,
  "TurboThreshold": 70,
  "HighCPU": 70,
  "ForceSilentTemp": 90,
  "SilentHoldSeconds": 3,
  "TurboHoldSeconds": 5,
  "ConfidenceThreshold": 70,
  "LearningRate": 0.1,
  "ExplorationRate": 0.2,
  "UseJSON": true,
  "UseRAM": false,
  "BackupInterval": 150,
  "ForceMode": "",
  "SilentLock": false,
  "BalancedLock": false
}
```

#### **AIEngines.json** - Status Silników AI

```json
{
  "QLearning": true,
  "Prophet": true,
  "NeuralBrain": true,
  "Ensemble": true,
  "GPUBound": true,
  "Bandit": true,
  "Genetic": true,
  "ChainPredictor": true,
  "LoadPredictor": true,
  "SelfTuner": true,
  "AnomalyDetector": true,
  "ContextDetector": true,
  "NetworkAI": true,
  "EnergyOptimizer": true,
  "ProcessWatcher": true,
  "AICoordinator": true,
  "StorageModeManager": true,
  "HardLockSystem": true
}
```

#### **AppCategories.json** - Kategorie + HardLock

```json
{
  "Applications": {
    "Cyberpunk2077": {
      "Category": "HEAVY",
      "Bias": 1.0,
      "HardLock": true
    },
    "chrome": {
      "Category": "MEDIUM",
      "Bias": 0.5,
      "HardLock": false
    },
    "notepad++": {
      "Category": "LIGHT",
      "Bias": 0.2,
      "HardLock": false
    }
  }
}
```

### Profile TDP

#### **AMD Ryzen - RyzenAdj**

```powershell
# Silent (12W / 18W / 15W / 75°C)
ryzenadj.exe --stapm-limit=12000 --fast-limit=18000 --slow-limit=15000 --tctl-temp=75 --min=50 --max=85

# Balanced (18W / 30W / 25W / 85°C)
ryzenadj.exe --stapm-limit=18000 --fast-limit=30000 --slow-limit=25000 --tctl-temp=85 --min=70 --max=99

# Turbo (22W / 35W / 30W / 90°C)
ryzenadj.exe --stapm-limit=22000 --fast-limit=35000 --slow-limit=30000 --tctl-temp=90 --min=85 --max=100

# Extreme (28W / 40W / 35W / 92°C)
ryzenadj.exe --stapm-limit=28000 --fast-limit=40000 --slow-limit=35000 --tctl-temp=92 --min=100 --max=100
```

#### **Intel - Speed Shift**

```powershell
# Silent (Min 50%, Max 85%)
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 50
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 85

# Balanced (Min 70%, Max 99%)
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 70
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 99

# Turbo (Min 85%, Max 100%)
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 85
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100

# Extreme (Min 100%, Max 100%)
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100

# Zastosuj zmiany
powercfg /setactive SCHEME_CURRENT
```

---

## 📚 Dokumentacja Techniczna

### RAMManager - Lock-Free Double-Buffering

```powershell
class RAMManager {
    # Struktura MMF (2MB):
    # [0-3]    Global Header: Int32 ActiveSlot (0 lub 1)
    # [4-...]  Slot 0: [0-7] Int64 Version | [8-11] Int32 Length | [12-...] Data
    # [...]    Slot 1: [0-7] Int64 Version | [8-11] Int32 Length | [12-...] Data
    
    [string] ReadRaw() {
        # Lock-free read z retry mechanism
        for ($retry = 0; $retry -lt 5; $retry++) {
            $active = $this.Accessor.ReadInt32(0)  # Aktywny slot
            $base = 4 + ($active * $slotSize)
            
            # Double-read version check
            $ver1 = $this.Accessor.ReadInt64($base)
            $length = $this.Accessor.ReadInt32($base + 8)
            $bytes = New-Object byte[] $length
            $this.Accessor.ReadArray($base + 12, $bytes, 0, $length)
            $ver2 = $this.Accessor.ReadInt64($base)
            
            if ($ver1 -eq $ver2) {
                # Success - no writer collision
                return [System.Text.Encoding]::UTF8.GetString($bytes)
            }
            
            # Writer collision - retry
            Start-Sleep -Milliseconds 5
        }
        
        # All retries failed - return cached
        return $this.GetCachedJson()
    }
    
    [void] WriteRaw([string]$json) {
        # Non-blocking write via queue
        if ($this.WriteQueue.Count -ge $this.MaxQueue) {
            $this.QueueDrops++
            return  # Drop if queue full
        }
        $this.WriteQueue.Enqueue($json)
    }
    
    # Background writer task
    [void] BackgroundWriterLoop() {
        while (-not $this.WriterCTS.IsCancellationRequested) {
            if ($this.WriteQueue.TryDequeue([ref]$item)) {
                $active = $this.Accessor.ReadInt32(0)
                $slot = 1 - $active  # Write to inactive slot
                $base = 4 + ($slot * $slotSize)
                
                # Write data
                $ver = [DateTime]::UtcNow.Ticks
                $this.Accessor.Write($base, [Int64]$ver)
                $this.Accessor.Write($base + 8, [int]$bytes.Length)
                $this.Accessor.WriteArray($base + 12, $bytes, 0, $bytes.Length)
                
                # Publish atomically
                $this.Accessor.Write(0, [int]$slot)
                $this.BackgroundWrites++
            }
            Start-Sleep -Milliseconds 50
        }
    }
}
```

**Zalety:**
- ✅ Zero-contention read/write
- ✅ Non-blocking dla ENGINE i CONFIGURATOR
- ✅ Retry mechanism przy writer collision
- ✅ Queue dla burst writes
- ✅ Cached fallback przy failures

---

### Storage Mode Manager

```powershell
class StorageModeManager {
    [string]$Mode  # "JSON" | "RAM" | "BOTH"
    
    [void] SetMode([string]$mode) {
        switch ($mode) {
            "JSON" {
                # Tylko dysk (bezpieczne, wolniejsze)
                $this.UseJSON = $true
                $this.UseRAM = $false
                $this.BackupIntervalSeconds = 30
            }
            "RAM" {
                # Tylko RAM (szybkie, ryzykowne)
                $this.UseJSON = $false
                $this.UseRAM = $true
                $this.BackupIntervalSeconds = [int]::MaxValue
            }
            "BOTH" {
                # Hybrid (szybkość + trwałość)
                $this.UseJSON = $true
                $this.UseRAM = $true
                $this.BackupIntervalSeconds = 150  # ~5 minut
            }
        }
    }
    
    [void] Write([string]$key, $value) {
        if ($this.UseRAM) {
            $this.RAM.Write($key, $value)  # Szybki zapis do MMF
        }
        
        if ($this.UseJSON) {
            # Auto-backup co BackupIntervalSeconds
            $elapsed = ([DateTime]::Now - $this.LastBackup).TotalSeconds
            if ($elapsed -ge $this.BackupIntervalSeconds) {
                $this.RAM.BackupToJSON($this.JSONPath)
                $this.LastBackup = [DateTime]::Now
            }
        }
    }
}
```

---

## ❓ FAQ

### Pytania Ogólne

**Q: Czy CPUManager jest bezpieczny dla mojego procesora?**  
A: Tak! System ma wbudowane bezpieczniki:
- Max STAPM: 28W (Extreme profile)
- Max Fast: 40W
- Max Tctl: 92°C
- Validate-TDP sprawdza każde ustawienie przed zapisem

**Q: Czy działa na laptopach?**  
A: Tak! System został przetestowany na:
- Laptopy AMD Ryzen 4000-7000 series
- Laptopy Intel 10-14 gen (w tym Hybrid P+E)
- Desktop AMD/Intel

**Q: Czy mogę używać z MSI Afterburner / Ryzen Master?**  
A: Tak, ale:
- RyzenAdj (CPUManager) + Ryzen Master = konflikt! Wybierz jeden.
- MSI Afterburner (GPU) + CPUManager (CPU) = OK ✅

**Q: Czy muszę instalować OpenHardwareMonitor / LibreHardwareMonitor?**  
A: Nie, to opcjonalne! Ale zalecane dla:
- ✅ Dokładniejszych odczytów temperatury CPU/GPU
- ✅ Lepszego monitoringu obciążenia GPU (dGPU/iGPU)
- ✅ Poprawnego działania GPU-Bound Detection
- ❌ Bez OHM/LHM: system użyje API Windows (działa, ale mniej precyzyjnie)

**Q: Który wybrać: OpenHardwareMonitor czy LibreHardwareMonitor?**  
A: 
- **OpenHardwareMonitor (OHM)** - stabilny, sprawdzony, dobry dla starszego sprzętu
- **LibreHardwareMonitor (LHM)** - nowszy, lepsze wsparcie dla Ryzen 7000/9000, Intel 13th/14th gen
- **Zalecenie:** LHM dla nowego sprzętu (2022+), OHM dla starszego

**Q: Czy silniki AI zbierają dane online?**  
A: Nie! Wszystkie dane są przechowywane lokalnie w `C:\CPUManager\*.json`. Zero telemetrii.

### Problemy Techniczne

**Q: "RyzenAdj.exe nie znaleziono"**  
A: Upewnij się że:
1. RyzenAdj.exe jest w folderze `C:\CPUManager\`
2. Nie został zablokowany przez antywirus (dodaj do wyjątków)
3. Uruchamiasz PowerShell jako Administrator

**Q: "Access Denied" przy uruchomieniu**  
A: PowerShell musi być uruchomiony jako Administrator:
1. Prawy przycisk myszy na PowerShell
2. "Uruchom jako administrator"
3. Ponownie uruchom skrypt

**Q: Konfigurator nie widzi ENGINE**  
A: Sprawdź:
1. Czy ENGINE działa? (okno PowerShell otwarte)
2. Czy pliki JSON są tworzone w `C:\CPUManager\`?
3. Czy oba skrypty mają uprawnienia administratora?

**Q: GPU-Bound nie działa**  
A: Wymagania:
1. GPU musi być wykryte (iGPU lub dGPU)
2. Obciążenie GPU > 75%
3. Obciążenie CPU < 50%
4. Silnik GPUBound włączony w AIEngines.json
5. **Zalecane:** OpenHardwareMonitor/LibreHardwareMonitor dla dokładnych odczytów GPU

**Q: Temperatura CPU/GPU jest niepoprawna**  
A: 
1. Zainstaluj OpenHardwareMonitor lub LibreHardwareMonitor
2. Uruchom jako Administrator i zostaw w tle
3. CPUManager automatycznie wykryje i użyje ich danych
4. Bez OHM/LHM: system użyje WMI (Windows API) - może być mniej dokładne

**Q: System nie widzi mojego GPU**  
A:
1. Sprawdź Device Manager (Win+X → Device Manager → Display adapters)
2. Zainstaluj aktualne sterowniki GPU (NVIDIA/AMD/Intel)
3. Uruchom LibreHardwareMonitor (lepsze wykrywanie niż OHM)
4. Restart CPUManager

**Q: RyzenAdj błąd "SMU not responding"**  
A:
1. Zaktualizuj BIOS do najnowszej wersji
2. Pobierz najnowszy RyzenAdj z GitHub
3. Wyłącz Secure Boot w BIOS (czasami blokuje RyzenAdj)
4. Upewnij się że Ryzen Master nie działa w tle (konflikt)

---

## 🔄 Changelog

### v40 (v43.9 ENGINE, v43.2 CONFIGURATOR) - 2026-02-02

#### **ENGINE v43.9 - CRITICAL FIX**
- ✅ **FIX:** Naprawiono funkcję `Show-Database` (brakowało ciała ForEach-Object + zamknięć)
- ✅ **FIX:** Naprawiono nadmiarowy `}` w bloku AIEngines config check
- ✅ **VALIDATED:** Plik przechodzi walidację składni PowerShell

#### **ENGINE v43.8 - AI KNOWLEDGE TRANSFER**
- ✅ **FEATURE:** Wykorzystuje istniejący AICoordinator zamiast nowych funkcji
- ✅ **FEATURE:** Dodano metody do AICoordinator:
  - `IntegrateProphetData()` - profile aplikacji do transferData
  - `IntegrateGPUBoundData()` - scenariusze GPU-bound do transferData
  - `IntegrateBanditData()` - Thompson Sampling stats do transferData
  - `IntegrateGeneticData()` - ewolucyjne progi do transferData
  - `ApplyEnrichedToEnsemble()` - aplikuj rozszerzony transferData do Ensemble
  - `TransferBackFromEnsemble()` - oddaj wiedzę z Ensemble do Q-Learning/Prophet
  - `TransferBackFromBrain()` - oddaj wiedzę z Brain do Q-Learning
- ✅ **LOGIC:** Ensemble ON: pobiera wiedzę z QLearning+Prophet+GPUBound+Bandit+Genetic
- ✅ **LOGIC:** Ensemble OFF: oddaje wiedzę do Q-Learning i Prophet
- ✅ **LOGIC:** Brain ON: pobiera wiedzę z QLearning+Prophet
- ✅ **LOGIC:** Brain OFF: oddaje AggressionBias boost do Q-Learning
- ✅ **OPTIMIZE:** Blend 70/30 zachowany (optimal balance)

#### **ENGINE v43.3 - CRITICAL FIX**
- ✅ **FIX:** `$neuralBrainEnabledUser` i `$ensembleEnabledUser` przeniesione PRZED hashtable
- ✅ **FIX:** Poprzednia wersja miała te zmienne WEWNĄTRZ @{} co crashowało ENGINE
- ✅ **FIX:** WidgetData zapisuje się poprawnie do WidgetData.json
- ✅ **FIX:** Komunikacja ENGINE <-> CONFIGURATOR przywrócona

#### **ENGINE v42.5 - TIMER-BASED HYSTERESIS**
- ✅ **FEATURE:** Timer-based exit dla GPU-Bound (3+ sekundy CPU > 50%)
- ✅ **FIX:** Silent Hill ping-pong rozwiązany (CPU 40-55% stabilny)
- ✅ **OPTIMIZE:** Entry: CPU < 50% (instant), Exit: CPU > 50% przez 3s (timer)

#### **ENGINE v42.4 - GPU-BOUND DETECTION**
- ✅ **FEATURE:** GPUBoundDetector - wykrywa scenariusze Low CPU + High GPU
- ✅ **FEATURE:** Inteligentna redukcja TDP: 5-10-15W based on CPU usage
- ✅ **OPTIMIZE:** -10-15°C CPU, -4-7°C GPU, +50-100MHz GPU boost, +2-5% FPS
- ✅ **SUPPORT:** Kompatybilność AMD APU + Intel iGPU + dGPU (NVIDIA/AMD)

#### **CONFIGURATOR v43.2 - PROPHET MEMORY COMPATIBILITY**
- ✅ **FEATURE:** Zakładka Database wyświetla Samples z Prophet Memory
- ✅ **FEATURE:** Pokazuje ile próbek zebrano dla każdej aplikacji (uczenie)
- ✅ **OPTIMIZE:** Pełna kompatybilność z ENGINE v43.4

#### **CONFIGURATOR v43.1 - UI FIX**
- ✅ **FIX:** Przyciski na dole Settings AMD nie nachodzą na siebie
- ✅ **UI:** Rząd 1 (Y=810): SAVE AI ENGINES, Enable CORE, Enable ALL, Disable ALL
- ✅ **UI:** Rząd 2 (Y=860): SAVE ALL SETTINGS, Reset to Defaults

---

## 📄 Licencja

**© 2026 Michał - Wszelkie prawa zastrzeżone**

### Warunki Użytkowania

- ✅ **Dozwolone:** Użytek osobisty (non-commercial)
- ✅ **Dozwolone:** Modyfikacje dla własnych potrzeb
- ✅ **Dozwolone:** Dzielenie się z przyjaciółmi (non-profit)

- ❌ **Zabronione:** Dystrybucja komercyjna
- ❌ **Zabronione:** Sprzedaż lub monetyzacja
- ❌ **Zabronione:** Usuwanie informacji o autorze
- ❌ **Zabronione:** Reverse engineering w celach komercyjnych

### Wyłączenie Odpowiedzialności

CPUManager jest dostarczany "TAK JAK JEST" bez jakichkolwiek gwarancji. Autor nie ponosi odpowiedzialności za:
- Uszkodzenia sprzętu wynikające z nieprawidłowej konfiguracji
- Utratę danych
- Problemy z kompatybilnością
- Inne szkody bezpośrednie lub pośrednie

**Używaj na własną odpowiedzialność!**

---

## 🤝 Kontakt i Wsparcie

### Zgłaszanie Błędów

1. Sprawdź `C:\CPUManager\bledy.txt`
2. Sprawdź `C:\Temp\CPUManager_GPU-Debug.log`
3. Dołącz:
   - Wersję systemu (Windows 10/11)
   - Model procesora (AMD/Intel)
   - Treść błędu z logów
   - Kroki do odtworzenia problemu

### Feature Requests

Masz pomysł na nową funkcję? Opisz:
- Co chcesz osiągnąć?
- Dlaczego to jest ważne?
- Jak to powinno działać?

---

## 🙏 Podziękowania

- **Ryzenadj Team** - za narzędzie do kontroli TDP AMD
- **OpenHardwareMonitor** - za biblioteki monitorowania sprzętu
- **Społeczność PowerShell** - za wsparcie i porady

---

## 📊 Statystyki

```
┌─────────────────────────────────────────────────────────────┐
│ CPUManager v40 - Project Statistics                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ 📁 Files:                                                   │
│    • ENGINE: CPUManager_v40.ps1 (17,529 lines)             │
│    • CONFIGURATOR: CPUManager_Configurator_v40.ps1 (7,533) │
│    • Total Code: 25,062 lines                              │
│                                                             │
│ 🧠 AI Engines: 18+                                          │
│    • Q-Learning Agent                                       │
│    • Prophet Memory                                         │
│    • Neural Brain                                           │
│    • Ensemble Voting                                        │
│    • GPU-Bound Detector                                     │
│    • Thompson Sampling Bandit                               │
│    • Genetic Optimizer                                      │
│    • Chain Predictor                                        │
│    • Load Predictor                                         │
│    • Self Tuner                                             │
│    • Anomaly Detector                                       │
│    • Context Detector                                       │
│    • Network AI                                             │
│    • Energy Optimizer                                       │
│    • Process Watcher                                        │
│    • AI Coordinator                                         │
│    • Storage Mode Manager                                   │
│    • HardLock System                                        │
│                                                             │
│ 🎯 Features:                                                │
│    • TDP Profiles: 4 (Silent/Balanced/Turbo/Extreme)       │
│    • GUI Tabs: 6 (Dashboard/Database/Settings/AI/Apps/Adv) │
│    • Blacklist: 500+ system processes                       │
│    • Recognized Apps: 200+ (production)                     │
│    • ARTURIA V COLLECTION: 45+ VST instruments              │
│                                                             │
│ 💾 Configuration Files: 15+                                 │
│    • QLearning.json (170+ states)                           │
│    • ProphetMemory.json (247+ apps)                         │
│    • BrainState.json (1,523+ decisions)                     │
│    • EnsembleWeights.json (456+ votes)                      │
│    • ... i więcej                                           │
│                                                             │
│ 📅 Development:                                             │
│    • Start: 2025                                            │
│    • Current Version: v40 (v43.9 ENGINE, v43.2 CONF)        │
│    • Release Date: 2026-02-02                               │
│    • Language: PowerShell + .NET (Windows Forms)            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

**🎯 CPUManager v40 - Inteligentne zarządzanie procesorem dla wymagających użytkowników!**

---

Made with ❤️ by Michał | Poland 🇵🇱 | 2026