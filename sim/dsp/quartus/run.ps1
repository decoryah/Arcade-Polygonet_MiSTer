# Standalone Quartus timing run for rtl/dsp56156: map, fit, STA at the slow 85C corner.
# Usage (PowerShell): sim\dsp\quartus\run.ps1   -> prints worst setup slack and top paths
$ErrorActionPreference = "Stop"
$q = "C:\intelFPGA_lite\17.0\quartus\bin64"
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force output | Out-Null
& "$q\quartus_map.exe" dsp56156_top > output\map.log; if ($LASTEXITCODE) { Get-Content output\map.log | Select-String "Error" | Select-Object -First 20; exit 1 }
& "$q\quartus_fit.exe" dsp56156_top > output\fit.log; if ($LASTEXITCODE) { Get-Content output\fit.log | Select-String "Error" | Select-Object -First 20; exit 1 }
& "$q\quartus_sta.exe" -t report.tcl > output\sta.log; if ($LASTEXITCODE) { Get-Content output\sta.log | Select-Object -Last 30; exit 1 }
Get-Content output\sta.log | Select-String "SLOW85"
Get-Content output\top_paths.txt | Select-Object -First 50
Get-Content output\dsp56156_top.fit.summary | Select-String "ALMs|registers|block memory|DSP"
