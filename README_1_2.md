# CPUManager_v40 — README

Kompletna dokumentacja i opis funkcji skryptu `CPUManager_v40.ps1`.

## Spis treści
- **Opis projektu**
- **Wymagania**
- **Instalacja i uruchomienie**
- **Konfiguracja**
- **Logi i diagnostyka**
- **AI i uczenie**
- **Bezpieczeństwo TDP**
- **Referencja funkcji (grupowana)**
- **Przykłady użycia**
- **Rozwiązywanie problemów**

## Opis projektu
`CPUManager_v40.ps1` to zaawansowany engine do zarządzania trybami zasilania i TDP CPU w systemie Windows. Integruje detekcję CPU/GPU/sensorów, mechanizmy bezpieczeństwa (TDP limits), wielowątkowe logowanie, zbieranie metryk, oraz zestaw AI (Prophet, Q-Learning, Ensemble, NeuralBrain i inne) do adaptacyjnego ustawiania profili energetycznych.

Skrypt obsługuje również integrację z `ryzenadj`, obsługę trybu GPU-bound (inteligentne obniżanie TDP przy wysokim obciążeniu GPU), tryby tray/UI, automatyczną copy-into-C:\CPUManager, backupy i atomowe zapisy konfiguracji.

## Wymagania
- Windows 10/11
- PowerShell 7 lub Windows PowerShell (skrypt kompatybilny z Cim/WMI)
- Uprawnienia administratora dla operacji zmiany TDP/ryzenadj i rejestrowania w C:\CPUManager
- (opcjonalnie) ryzenadj.exe w `C:\CPUManager\ryzenadj\ryzenadj.exe` dla AMD tuning

## Instalacja i uruchomienie
1. Skopiuj folder do `C:\CPUManager` lub uruchom Install_CPUManager.bat jako admin — skrypt sam spróbuje skopiować do tej ścieżki.
2. Uruchom jako administrator: `powershell -ExecutionPolicy Bypass -File C:\CPUManager\CPUManager_v40.ps1`.
3. Opcjonalnie utwórz zadanie w Harmonogramie — skrypt zawiera funkcje `Register-CPUManagerTask` oraz `Test-CPUManagerTaskExists`.

## Konfiguracja
- Pliki konfiguracyjne i dane są zapisywane w `C:\CPUManager` (np. `WidgetData.json`, `StorageMode.json`, `TDPLearning.json`, `AIEngines.json`).
- `Initialize-ConfigJson` tworzy domyślny szablon konfiguracyjny.
- `Load-ExternalConfig` umożliwia wczytanie zewnętrznego configu.

## Logi i diagnostyka
- `Write-DebugLog` — logi debug/GPU-bound do `C:\Temp\CPUManager_GPU-Debug.log` (można wyłączyć).
- `Write-ErrorLog` — zapisuje błędy do `C:\CPUManager\bledy.txt` oraz dodatkowo do debug loga jeśli włączony.
- `Rotate-ErrorLog` — mechanizm rotacji logów błędów.
- `Initialize-DebugLog` — inicjalizuje plik debug.

## AI i uczenie
- Skrypt wspiera wiele silników AI: Prophet, Q-Learning, Ensemble, NeuralBrain, Bandit, Genetic, LoadPredictor, AnomalyDetector i inne.
- `Load-AIEnginesConfig`, `Save-AIEnginesConfig`, `Test-AIEngine` — zarządzanie konfiguracją AI.
- Flagi pomocnicze: `Is-EnsembleEnabled`, `Is-NeuralBrainEnabled`, `Is-ProphetEnabled`, `Is-QLearningEnabled`, itd.
- `Update-TDPLearning`, `Load-TDPLearning`, `Get-OptimalTDPProfile` — mechanizmy uczenia profili TDP i wyboru optymalnego profilu.

## Bezpieczeństwo TDP
- `Validate-TDP` — waliduje i poprawia profil TDP względem `TDP_HARD_LIMITS` (STAPM, Fast, Slow, Tctl). Koryguje wartości poza zakresami, loguje ostrzeżenia i zwraca strukturę `{ Safe, Warnings, Profile }`.
- `TDP_HARD_LIMITS` w skrypcie zawiera krytyczne wartości bezpieczeństwa (np. MaxSTAPM, MaxFast, MaxSlow, MaxTctl, MinSTAPM, MinTctl).

## Referencja funkcji (grupowana)
Poniżej krótki opis wszystkich istotnych funkcji pogrupowanych tematycznie. Opis każdej funkcji zawiera jej cel i istotne zachowania.

- **TDP & RyzenAdj**
  - `Validate-TDP` — waliduje profil TDP (STAPM, Fast, Slow, Tctl), koryguje wartości poza limitami, loguje ostrzeżenia.
  - `Load-TDPConfig` — ładuje konfigurację TDP z plików konfiguracyjnych.
  - `Initialize-RyzenAdj` — inicjalizuje integrację z `ryzenadj` (ścieżki, dostępność).
  - `Get-RyzenAdjInfo` — pobiera informacje z `ryzenadj` (jeśli dostępny).
  - `Start-RyzenAdjInfoRefresh` — odświeżanie info z ryzenadj w tle.
  - `Start-RyzenAdjSetTDP` / `Set-RyzenAdjTDP` / `Set-RyzenAdjMode` — wysyłanie ustawień TDP do `ryzenadj`.
  - `Get-RyzenAdjCachedInfo` — zwraca ostatnio pobrane informacje z ryzenadj.

- **Detekcja sprzętu i sensorów**
  - `Detect-CPU` — wykrywa producenta, generację, liczbę rdzeni/threads, P/E cores dla Intela, ustawia globalne zmienne (`IsHybridCPU`, `PCoreCount`, `ECoreCount`, `CPUVendor`, `CPUModel`, `CPUGeneration`).
  - `Detect-HybridCPU` — alias do `Detect-CPU`.
  - `Detect-GPU` — wykrywa i klasyfikuje GPU (iGPU/dGPU), ustawia `HasiGPU`, `HasdGPU`, `PrimaryGPU`, `iGPUName`, `dGPUName`, rozpoznaje Intel/AMD/NVIDIA.
  - `Detect-DataSources`, `Populate-DetectedSensors`, `Detect-AvailableMetrics` — wykrywanie dostępnych źródeł metryk (LHMonitor, OpenHardwareMonitor, ACPI, Performance Counters itp.).
  - `Get-LHMSensorsCached`, `Get-OHMSensorsCached`, `Get-ACPIThermalCached`, `Get-CPUInfoCached`, `Get-ProcessorPerfCached`, `Get-DiskCounterCached`, `Get-DiskPerfCached`, `Get-OSCached` — zestawy funkcji do zwracania cache’owanych danych sensorów.

- **Logowanie i diagnostyka**
  - `Write-DebugLog` — append do debug loga z timestampem.
  - `Write-ErrorLog` — zapis błędów, dodatkowo loguje do debug loga jeśli włączony.
  - `Initialize-DebugLog` — tworzy nagłówek sesji i przygotowuje plik logów.
  - `Write-Log`, `Add-Log` — syslog/console-wrapper wykorzystywany w wielu miejscach do normalizowanego logowania.
  - `Rotate-ErrorLog`, `Write-SessionSummary` — rotacja i podsumowanie sesji.

- **Startup / Boost / Power**
  - `Start-StartupBoost` — uruchamia jednorazowy boost przy starcie systemu/aplikacji.
  - `Update-StartupBoostState` — aktualizuje stan startup boost (trwałość, warunki).
  - `Show-BoostNotification` — wyskakujące powiadomienie o przyznanym boost.
  - `Get-PowerStates` — pobiera dostępne stany mocy i profile systemowe.
  - `Set-PowerMode` — zmienia systemowy power mode (np. Balanced/Turbo/Silent integration).

- **UI / Tray / Procesy**
  - `Main` — główna pętla / entrypoint GUI / engine (render, decision loop).
  - `Render-UI`, `Draw-ProgressBar` — funkcje konsolowego/tekstowego renderowania UI.
  - `Show-Database` — interaktywne wyświetlenie bazy danych (naprawiona w v43.9).
  - `Start-BackgroundWrite`, `New-TrackedPowerShell` — pomocnicze do uruchamiania procesów background/tray.
  - `Send-TrayCommand`, `Request-Shutdown` — komunikacja z tray/em i zamykanie.
  - `Load-TrayAIEngines`, `Save-TrayAIEngines`, `Set-TrayCPUType` — zarządzanie ustawieniami widżetu/tray.
  - `Stop-AllProcesses` — zatrzymuje powiązane procesy (widget, configurator, CPUManagerAI).

- **Konfiguracja i stan**
  - `Get-DefaultConfigTemplate` — zwraca domyślny JSON config.
  - `Initialize-ConfigJson` — tworzy i inicjuje plik konfiguracyjny.
  - `Load-ExternalConfig`, `Apply-ConfiguratorSettings`, `Check-ConfigReload` — obsługa dynamicznego przeładowania konfiguracji.
  - `Save-State`, `Load-State` — serializacja / deserializacja stanu całego engine i AI.

- **AI / Machine Learning helpers**
  - `Load-AIEnginesConfig`, `Save-AIEnginesConfig`, `Acquire-FileLock`, `Release-FileLock` — zarządzanie zapisem configów AI w sposób bezpieczny.
  - `Test-AIEngine` — sanity-check dla wybranego silnika AI.
  - Helpery typów: `Is-EnsembleEnabled`, `Is-NeuralBrainEnabled`, `Is-ProphetEnabled`, `Is-QLearningEnabled`, `Is-SelfTunerEnabled`, `Is-ChainEnabled`, `Is-LoadPredictorEnabled`, `Is-AnomalyEnabled`, `Is-BanditEnabled`, `Is-GeneticEnabled`, `Is-EnergyEnabled` — szybkie sprawdzenie flag konfiguracyjnych.

- **TDPLearning i adaptacja**
  - `Update-TDPLearning`, `Load-TDPLearning`, `Get-OptimalTDPProfile` — mechanizmy zbierania doświadczeń i rekomendacji TDP dla aplikacji.

- **Monitoring aktywności użytkownika / procesów**
  - `Get-IdleTimeSeconds`, `Update-ActivityStatus`, `Get-UserActivityStatus`, `Get-ForegroundProcessName`, `Get-ForegroundWindowTitle`, `Get-ProcessDisplayName`, `Get-FriendlyAppName` — funkcje detekcji aktywności i kontekstu użytkownika do podejmowania decyzji boost/silent.
  - `Read-ManualBoostData`, `Get-LearnedPreferenceForApp` — manualne i wyuczone preferencje aplikacji.

- **Pomocnicze / plikowe / atomowe**
  - `Ensure-FileExists`, `Ensure-DirectoryExists`, `Find-FirstExistingPath`, `Remove-ExistingFiles`, `Remove-FilesIfExist` — pomoc przy plikach/katalogach.
  - `Save-JsonAtomic` — bezpieczny, atomowy zapis JSON (zapobiega uszkodzeniu pliku podczas zapisu).

- **Scheduler / Task**
  - `Register-CPUManagerTask`, `Test-CPUManagerTaskExists` — rejestracja w Harmonogramie zadań Windows.

## Przykłady użycia
- Uruchomienie skryptu (admin):
```powershell
powershell -ExecutionPolicy Bypass -File C:\CPUManager\CPUManager_v40.ps1
```
- Włączenie/wyłączenie debug logów (w kodzie): ustaw `$Script:DebugLogEnabled = $true|$false`.
- Test integracji z ryzenadj: upewnij się, że `C:\CPUManager\ryzenadj\ryzenadj.exe` istnieje, a następnie użyj `Test-AIEngine` i `Initialize-RyzenAdj`.

## Rozwiązywanie problemów
- Skrypt loguje błędy do `C:\CPUManager\bledy.txt` — sprawdź ten plik przy awariach.
- Jeśli GUI/Widget nie widzi danych — upewnij się, że wykryto sensora (OpenHardwareMonitor/LHM) i że `Detect-DataSources` zwraca źródła.
- Problemy z zapisem plików: sprawdź uprawnienia do `C:\CPUManager` i czy nie ma blokad plików; `Acquire-FileLock`/`Release-FileLock` chronią przed równoczesnym zapisem.

## Dalsze kroki
- Możemy rozszerzyć README o:
  - szczegółowe przykłady konfiguracji JSON (konkretne pola),
  - diagramy decyzyjne (GPU-bound / Timer-Hysteresis),
  - testy integracyjne dla `ryzenadj`.

---
Plik główny skryptu: [CPUManager_v40.ps1](CPUManager_v40.ps1)

## Diagram decyzyjny — GPU-bound i Timer-based Hysteresis
Poniżej znajduje się diagram opisujący logikę wykrywania scenariuszy GPU-bound oraz mechanizm timer-based hysteresis używany przy wyjściu z trybu GPU-bound.

```mermaid
flowchart LR
    Start((Start))
    Thermal{Thermal > 90°C?}
    IO{I/O > 80%?}
    HighCPU{CPU > 70%?}
    GPUBoundEntry{CPU < 50% \nAND GPU > 75%?}
    LowCPU{CPU < 20%?}
    Silent[Silent Mode\n(HOLD SILENT)]
    Turbo[Turbo Mode\n(HOLD TURBO)]
    Balanced[Balanced Mode]
    GPUBound[GPU-BOUND Mode\n(Entry: instant, Exit: timer)]
    ExitCheck{CPU > 50%?}
    Timer3s[Start 3s timer]
    ExitToTurbo[Switch to Turbo]
    StayGPUBound[Remain GPU-BOUND]

    Start --> Thermal
    Thermal -- Yes --> Silent
    Thermal -- No --> IO
    IO -- Yes --> Turbo
    IO -- No --> HighCPU
    HighCPU -- Yes --> Turbo
    HighCPU -- No --> GPUBoundEntry
    GPUBoundEntry -- Yes --> GPUBound
    GPUBoundEntry -- No --> LowCPU
    LowCPU -- Yes --> Silent
    LowCPU -- No --> Balanced

    GPUBound --> ExitCheck
    ExitCheck -- Yes --> Timer3s
    ExitCheck -- No --> StayGPUBound
    Timer3s -- Sustained --> ExitToTurbo
    Timer3s -- Interrupted --> StayGPUBound

    classDef cond fill:#f9f,stroke:#333,stroke-width:1px;
    class Thermal,IO,HighCPU,GPUBoundEntry,ExitCheck,LowCPU cond;
```

Krótka notka:
- Wejście do GPU-bound: natychmiastowe, jeśli jednocześnie CPU jest niskie (<50%) i GPU wysokie (>75%).
- Wyjście z GPU-bound: wymaga, żeby CPU przekroczyło próg (np. >50%) i utrzymało się powyżej przez określony czas (domyślnie 3s) — timer-based hysteresis zapobiega ping-pongowi.
- Hierarchia decyzji: Thermal overrides everything (Silent), potem I/O/Turbo, potem High CPU → Turbo, potem GPU-bound check, potem Low CPU → Silent, w przeciwnym razie Balanced.

 
## Szczegółowa referencja funkcji
Poniżej znajduje się rozszerzona, alfabetyczna referencja wszystkich funkcji obecnych w `CPUManager_v40.ps1`. Dla każdej funkcji: krótki opis, kluczowe parametry (jeśli występują) i uwagi dotyczące działania.

- `Acquire-FileLock(path)` — Próbuje uzyskać blokadę pliku dla bezpiecznego zapisu JSON/konfiguracji. Zwraca token/flagę sukcesu. Używane przed `Save-AIEnginesConfig` i innymi zapisem plików.
- `Add-Log(message, level)` — Normalizowane logowanie (wewnętrzny wrapper). Używane przez wiele modułów.
- `Apply-ConfiguratorSettings()` — Aplikuje ustawienia z pliku konfiguracji (dynamiczne dostosowanie runtime).
- `Detect-CPU()` — Wykrywa CPU przez `Get-CimInstance Win32_Processor`, ustawia: `CPUVendor`, `CPUModel`, `CPUGeneration`, `TotalCores`, `TotalThreads`, oraz flagi i liczby rdzeni hybrydowych (`IsHybridCPU`, `PCoreCount`, `ECoreCount`, `HybridArchitecture`). Zwraca `$true|$false`.
- `Detect-GPU()` — Wykrywa karty graficzne (`Win32_VideoController`), klasyfikuje jako iGPU/dGPU, ustawia `HasiGPU`, `HasdGPU`, `iGPUName`, `dGPUName`, `dGPUVendor`, `PrimaryGPU` i buduje listę `GPUList`.
- `Detect-DataSources()` — Wykrywa dostępne źródła telemetryczne (LHMonitor, OHM, ACPI, perf counters) i zapisuje dostępne opcje.
- `Detect-AvailableMetrics()` — Mapuje które metryki są dostępne do podejmowania decyzji (CPU%, temp, GPU%, I/O, RAM).
- `Detect-HybridCPU()` — Alias do `Detect-CPU` dla kompatybilności wstecznej.
- `Draw-ProgressBar()` — Tekstowa reprezentacja progressbara używana w konsolowym UI.
- `Ensure-DirectoryExists(path)` — Tworzy katalog jeśli nie istnieje.
- `Ensure-FileExists(path)` — Tworzy plik (pusty) jeśli nie istnieje, zachowując prawa dostępu.
- `Find-FirstExistingPath(paths[])` — Zwraca pierwszą istniejącą ścieżkę z listy.
- `Get-ACPIThermalCached()` — Zwraca cache danych ACPI thermal (jeśli dostępne).
- `Get-CPUInfoCached()` — Zwraca cache informacji o CPU (częstotliwości, CPUID itp.).
- `Get-DiskCounterCached()` — Cache counterów dysku.
- `Get-DiskPerfCached()` — Cache wyników wydajności dysku.
- `Get-ForegroundWindowTitle()` — Zwraca tytuł aktywnego okna (używane w rozpoznawaniu aplikacji).
- `Get-ForegroundProcessName()` — Zwraca nazwę procesu na pierwszym planie.
- `Get-LHMSensorsCached()` — Cache sensorów z LibreHardwareMonitor / LHM.
- `Get-OSCached()` — Cache podstawowych informacji o systemie operacyjnego.
- `Get-ProcessorPerfCached()` — Cache metryk wydajności procesora (Load, %).
- `Get-PowerStates()` — Pobiera listę dostępnych profili zasilania Windows i stanów.
- `Get-DefaultConfigTemplate()` — Zwraca przykładowy JSON z kompletem domyślnych pól konfiguracyjnych.
- `Get-LearnedPreferenceForApp(appName)` — Zwraca wyuczoną preferencję/boost dla danej aplikacji z TDPLearning / AI.
- `Get-OptimalTDPProfile(context)` — Na podstawie historycznych danych i TDPLearning zwraca rekomendowany profil TDP dla danego kontekstu (aplikacja / scenariusz).
- `Get-RyzenAdjCachedInfo()` — Zwraca ostatnio zbuforowane informacje od `ryzenadj`.
- `Get-RyzenAdjInfo()` — Wywołuje `ryzenadj` (jeśli obecny), parsuje wynik i zwraca strukturę parametrów (PPT/TDC/EDC/Tctl, etc.).
- `Get-SilentCPUThreshold()` — Zwraca skonfigurowany próg CPU dla wejścia w tryb Silent.
- `Get-SilentRAMThreshold()` — Zwraca próg RAM dla Silent.
- `Get-BalancedCPUThreshold()` — Zwraca próg CPU dla Balanced.
- `Get-ProcessDisplayName(pid|process)` — Friendly display name dla procesu (wyciąg z exe/metadata).
- `Get-FriendlyAppName(process)` — Mapuje nazwę procesu na przyjazną nazwę aplikacji (bazuje na AppCategories/Prophet memory).
- `Initialize-ConfigJson()` — Tworzy i inicjalizuje plik konfiguracyjny jeśli nie istnieje, używając `Get-DefaultConfigTemplate`.
- `Initialize-DebugLog()` — Tworzy folder/plik debug loga z nagłówkiem sesji.
- `Initialize-RyzenAdj()` — Weryfikuje, czy `ryzenadj` jest obecny w znanych ścieżkach, ustawia ścieżki i uprawnienia do użycia.
- `Is-*` helpery (np. `Is-EnsembleEnabled`, `Is-NeuralBrainEnabled`, `Is-ProphetEnabled`, `Is-QLearningEnabled`, `Is-SelfTunerEnabled`, `Is-ChainEnabled`, `Is-LoadPredictorEnabled`, `Is-AnomalyEnabled`, `Is-BanditEnabled`, `Is-GeneticEnabled`, `Is-EnergyEnabled`) — Proste funkcje zwracające bool na podstawie `Script:AIEngines` configu.
- `Load-AIEnginesConfig()` — Ładuje plik konfiguracyjny AI (np. AIEngines.json) i waliduje strukturę.
- `Load-AppCategories()` — Wczytuje mapowania aplikacji do kategorii używanych przez Prophet / TDPLearning.
- `Load-State()` — Wczytuje zapisany stan engine (AI, TDPLearning, widgetData) z dysku i przywraca obiekty.
- `Load-TDPConfig()` — Wczytuje plik konfiguracji TDP (profile Turbo/Balanced/Silent) i przygotowuje do użycia.
- `Load-TDPLearning()` — Wczytuje plik `TDPLearning.json` zawierający wyuczone profile/rezultaty dla aplikacji.
- `Load-TrayAIEngines()` — Wczytuje ustawienia AI specyficzne dla tray/widget.
- `Main()` — Główna pętla engine/UI: orchestruje detekcję sensorów, wybór trybu (Silent/Balanced/Turbo), integrację AI, aktualizacje TDP i zapis stanu. Zawiera też pomocnicze `Hide-Console` / `Show-Console` wewnątrz.
- `New-TrackedPowerShell()` — Tworzy nowy proces PowerShell uruchomiony jako tracked helper do background actions (np. configurator, widget).
- `Populate-DetectedSensors()` — Wypełnia strukturę `DetectedSensors` wynikami z `Detect-DataSources`.
- `Register-CPUManagerTask()` — Rejestruje zadanie w Harmonogramie Windows do uruchamiania CPUManager przy starcie lub według harmonogramu.
- `Remove-ExistingFiles()` / `Remove-FilesIfExist()` — Usuwa pliki jeśli istnieją (helpery cleanup).
- `Render-UI()` — Render konsolowy / tekstowy UI z danymi o trybach i metrykach.
- `Request-Shutdown()` — Bezpieczna procedura zamknięcia skryptu: zapis stanu, zatrzymanie podprocesów, logi.
- `Rotate-ErrorLog()` — Rotuje błędy/logi, utrzymuje historię i limit rozmiaru.
- `Save-AIEnginesConfig()` — Zapisuje konfigurację AI na dysk w sposób bezpieczny (używa `Acquire-FileLock` i `Save-JsonAtomic`).
- `Save-State()` — Serializuje i zapisuje stan engine (AI, TDPLearning, widgetData) — używane przy zamykaniu i auto-save.
- `Save-JsonAtomic()` — Zapisuje JSON atomowo (z backupem/rename), zapobiegając utracie danych przy crashu.
- `Save-TrayAIEngines()` — Zapisuje ustawienia tray/widget dla AI.
- `Set-RyzenAdjMode()` / `Set-RyzenAdjTDP()` — Funkcje wysyłające odpowiednie polecenia do `ryzenadj` w celu ustawienia limitów STAPM/Fast/Slow/Tctl.
- `Set-TrayCPUType()` — Ustawia typ CPU widoczny w tray (np. AMD/Intel) i synchronizuje dane z GUI.
- `Set-CPUTypeManual()` — Pozwala ręcznie wymusić typ CPU w konfiguracji (override detekcji automatycznej).
- `Show-BoostNotification()` — Wyświetla powiadomienie użytkownikowi o przyznanym boost/zmianie trybu.
- `Show-Database()` — Interaktywny widok bazy danych (TDPLearning/Prophet) w konsoli — naprawiony w v43.9.
- `Start-RyzenAdjInfoRefresh()` — Uruchamia cykliczne odświeżanie danych z `ryzenadj` (background timer).
- `Start-RyzenAdjSetTDP()` — Asynchroniczne wysłanie nowego profilu TDP do `ryzenadj`.
- `Start-StartupBoost()` — Mechanizm jednorazowego boostu na starcie systemu/aplikacji (dozwolone przez konfigurację).
- `Start-BackgroundWrite()` — Rozpoczyna background writer (perodic write do plików statusu dla tray/widget).
- `Test-AIEngine(engineName)` — Sprawdza działanie konkretnego silnika AI (sanity check), weryfikuje pliki i wymagane dane.
- `Test-IsSystemProcess(process)` — Zwraca true jeśli dany proces jest systemowy (pomija go przy uczeniu/app-categories).
- `Test-CPUManagerTaskExists()` — Weryfikuje czy zadanie w Harmonogramie już istnieje.
- `Update-StartupBoostState()` — Aktualizuje stan flags/konfiguracji startup boost (np. czy już przyznano).
- `Update-TDPLearning(appContext, tdpProfile)` — Aktualizuje TDPLearning zapisem nowych obserwacji związanych z aplikacją/warunkami.
- `Update-ActivityStatus()` — Aktualizuje status aktywności użytkownika (idle/active) na podstawie `Get-IdleTimeSeconds` i fokusów okien.
- `Write-DebugLog(message, type, source)` — Zapisuje linie z timestampem do debug loga GPU-bound / metrics.
- `Write-ErrorLog(component, errorMessage, details)` — Zapisuje szczegółowy wpis błędu do `bledy.txt` i (opcjonalnie) debug log.
- `Write-Log(message, level)` — Główny logger sesyjny używany w całym skrypcie.

Jeśli którejś funkcji brakuje w powyższej liście (występuje niestandardowa nazwa) — daj znać, dopiszę natychmiast. Plik [CPUManager_v40.ps1](CPUManager_v40.ps1) zawiera dodatkowe drobne helpery i aliasy; zostały one zgrupowane i opisane powyżej.

## Silniki AI użyte w projekcie
Skrypt definiuje zestaw przełączalnych silników AI w `AIEngines.json`. Domyślne silniki to:

- `QLearning` — Q-Learning agent (uczenie przez wzmacnianie)
- `Prophet` — wzorcowe prognozowanie zachowań aplikacji (time-series / pattern)
- `AnomalyDetector` — wykrywanie anomalii w metrykach
- `SelfTuner` — automatyczny tuner parametrów
- `ChainPredictor` — predykcja sekwencyjna / chain modeling
- `LoadPredictor` — przewidywanie wzorców obciążenia
- `Bandit` — Multi-Armed Bandit (Thompson Sampling / eksploracja)
- `Genetic` — Genetic optimizer (ewolucyjne dopasowanie progów)
- `Energy` — moduły optymalizacji energetycznej / śledzenia zużycia
- `Ensemble` — głosowanie/ensemble łączące wyniki wielu silników
- `NeuralBrain` — sieć neuronowa (neural brain)
- `NeuralBrain` — sieć neuronowa (neural brain)


## **Diagram komunikacji (moduły)**

Poniżej sekwencyjny diagram komunikacji między głównymi modułami: `Configurator` (GUI), system plików (`C:\CPUManager`), `Engine` (`CPUManager_v40.ps1`), `Tray/Widget` oraz mechanizmy zapisu (`Save-JsonAtomic` / `Acquire-FileLock`). Diagram przedstawia typowy przepływ przy aktualizacji konfiguracji i synchronizacji stanu.

```mermaid
sequenceDiagram
  autonumber
  participant Configurator as Configurator (GUI)
  participant Tray as Tray / Launcher
  participant FS as Pliki (C:\CPUManager)
  participant FileLock as FileLock / AtomicWrite
  participant Engine as Engine (CPUManager_v40.ps1)
  participant Widget as Widget / MiniWidget

  Note over Configurator,FS: Użytkownik edytuje ustawienia w Configuratorze
  Configurator->>FileLock: Przygotuj JSON (zapis .tmp)
  FileLock->>FS: Zapis `AIEngines.json` / `config.json` (przeniesienie .tmp -> final)
  Configurator->>FS: Tworzy/aktualizuje `reload.signal` z payload {"File":"AIEngines"}
  Tray->>Configurator: (opcjonalnie) Uruchamia proces Configurator (pwsh)

  Note over FS,Engine: Engine monitoruje `reload.signal` i/lub timestamp plików
  Engine->>FS: Sprawdza `reload.signal` (LastWriteTime) lub polling `config.json`
  FS-->>Engine: Zwraca payload `reload.signal` (np. File=AIEngines)
  Engine->>Engine: Parsuje sygnał -> switch(File)
  Engine->>Engine: Wywołuje `Load-AIEnginesConfig` / `Load-ExternalConfig`
  Engine->>Engine: Resetuje flagi i (jeśli potrzebne) `Apply-ConfiguratorSettings -Force`

  Note over Engine,FS: Engine zapisuje stan runtime aby Configurator mógł go odczytać
  Engine->>FileLock: Save-State / Save-JsonAtomic (BrainState.json, ProphetMemory.json)
  FileLock->>FS: Zapis plików stanu (atomic)

  Note over Widget,FS: Widget odczytuje dane statusowe dla UI
  Widget->>FS: Czyta `WidgetData.json` / `BrainState.json`
  Widget-->>Engine: (opcjonalne) żądania przez pliki/sygnały

  Note over Engine,Configurator: Podsumowanie
  Configurator-->>Engine: Synchronizacja odbywa się przez pliki i sygnały (brak RPC)
  Engine-->>Configurator: Udostępnia runtime state (pliki), wykrywa sygnały i reaguje

  deactivate Configurator
  deactivate Engine
  deactivate Widget
```

Legenda:
- `FileLock / AtomicWrite` — pattern zapisu (`.tmp` → Move-Item) realizowany przez `Save-JsonAtomic`.
- `reload.signal` — główny mechanizm hot-reload: zawiera JSON z polem `File` wskazującym co przeladować.
- `LastWriteTime` / `$Script:LastReloadSignalTime` — mechanizm deduplikacji sygnałów po znaczniku czasu.





