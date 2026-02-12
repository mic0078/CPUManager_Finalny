powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100
powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5
powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5
powercfg /setactive SCHEME_CURRENT



# --- RESET WSZYSTKICH PLANÓW ZASILANIA DO FABRYCZNYCH ---

# Usuwa wszystkie istniejące profile zasilania
powercfg -RestoreDefaultSchemes

# Przywraca standardowe profile Microsoft
powercfg -duplicatescheme 381b4222-f694-41f0-9685-ff5bb260df2e  # Zrównoważony
powercfg -duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  # Wysoka wydajność
powercfg -duplicatescheme a1841308-3541-4fab-bc81-f71556f20b4a  # Oszczędzanie energii

# Ustawia Zrównoważony jako domyślny
powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e