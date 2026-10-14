# Fits jchan_core alone (all ports virtual pins, `jchan_fit` revision) and runs the timing analysis for the slow 100 C / -40 C and the fast models.
#   powershell -File run_fit.ps1 [-Quartus C:\intelFPGA_lite\17.0\quartus\bin64]
# Results: out\jchan_fit.fit.summary, out\jchan_fit.sta.summary, the reports in out\; the logs are fit_map.log / fit_fit.log / fit_sta.log (UTF-16).
param([string]$Quartus = 'C:\intelFPGA_lite\17.0\quartus\bin64')
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
& (Join-Path $Quartus 'quartus_map.exe') jchan_core --rev=jchan_fit --read_settings_files=on *> fit_map.log
& (Join-Path $Quartus 'quartus_fit.exe') jchan_core --rev=jchan_fit --read_settings_files=on *> fit_fit.log
& (Join-Path $Quartus 'quartus_sta.exe') jchan_core --rev=jchan_fit *> fit_sta.log
Get-Content out\jchan_fit.fit.summary
Get-Content out\jchan_fit.sta.summary
