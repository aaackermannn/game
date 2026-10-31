param(
    [string]$BinDir = "$PSScriptRoot/../../build/pr2/Release",
    [string]$Python = "python",
    [string]$OutputDir = "$PSScriptRoot/../docs"
)
$ErrorActionPreference = 'Stop'
& $Python "$PSScriptRoot/run_experiments.py" --bin-dir $BinDir --output-dir $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Experiment failed' }
