# Rebuilds the NiftyQuant database from scratch: schema, logic, then the real NSE data.
# Usage (from the NiftyQuant folder):   .\run_all.ps1
# Optional: .\run_all.ps1 -Password yourpassword -Psql "C:\path\to\psql.exe" -SkipFetch
# First time only:
#   python -m venv .venv; .venv\Scripts\pip install -r requirements.txt
#   .venv\Scripts\python -m ipykernel install --user --name niftyquant --display-name "NiftyQuant (.venv)"

param(
    [string]$Password = "postgres",
    [string]$Psql     = "C:\Program Files\PostgreSQL\18\bin\psql.exe",
    [string]$Database = "niftyquant",
    [switch]$SkipFetch
)

$ErrorActionPreference = "Stop"
$env:PGPASSWORD = $Password
$env:PGDATABASE = $Database
Set-Location $PSScriptRoot

if (-not $SkipFetch) {
    # Resumable: only files not already in data\raw are downloaded (first run ~1 hour)
    Write-Host "== data\fetch.py (NSE bhavcopy, weekend sessions, corporate actions, indices, lists)"
    & ".venv\Scripts\python.exe" data\fetch.py bhav weekend ca index list
    if ($LASTEXITCODE -ne 0) { throw "fetch failed (exit $LASTEXITCODE)" }
}

$exists = & $Psql -U postgres -h localhost -tAc "SELECT 1 FROM pg_database WHERE datname = '$Database'"
if (-not $exists) {
    & $Psql -U postgres -h localhost -c "CREATE DATABASE $Database"
}

foreach ($file in "02_ddl.sql", "03_logic.sql") {
    Write-Host "== $file"
    & $Psql -U postgres -h localhost -d $Database -q -v ON_ERROR_STOP=1 -f $file | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$file failed (exit $LASTEXITCODE)" }
}

Write-Host "== 04_load.py (one transaction: ~4,200 trading days, ~8M prices, then the research layer)"
& ".venv\Scripts\python.exe" 04_load.py
if ($LASTEXITCODE -ne 0) { throw "04_load.py failed (see above); nothing was committed" }

if (Test-Path "07_analytics.sql") {
    Write-Host "== 07_analytics.sql"
    & $Psql -U postgres -h localhost -d $Database -q -v ON_ERROR_STOP=1 -f 07_analytics.sql -o NUL
    if ($LASTEXITCODE -ne 0) { throw "07_analytics.sql failed (exit $LASTEXITCODE)" }
}

Write-Host "NiftyQuant rebuilt. Try:  psql -U postgres -h localhost -d $Database -f 05_queries.sql   (or 06_demo.sql)"
