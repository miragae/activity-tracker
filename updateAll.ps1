<#
.SYNOPSIS
    Rebuilds all weekly JS files from CSV logs
.DESCRIPTION
    Scans all CSV files and regenerates all weekly dashboard files
#>

param(
    [int]$IdleThreshold = 600  # seconds (10 minutes)
)

$BASE_PATH = $PSScriptRoot
$LOGS_PATH = Join-Path $BASE_PATH "logs"

# Get Monday of the week
function Get-MondayOfWeek {
    param([DateTime]$Date)
    
    $dayOfWeek = [int]$Date.DayOfWeek
    if ($dayOfWeek -eq 0) { $dayOfWeek = 7 }
    
    return $Date.AddDays(1 - $dayOfWeek).Date
}

Write-Host "Scanning for CSV files..." -ForegroundColor Cyan

# Find all CSV files
$csvFiles = Get-ChildItem -Path $LOGS_PATH -Filter "*.csv" -Recurse | 
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}\.csv$' }

if ($csvFiles.Count -eq 0) {
    Write-Host "No CSV files found." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($csvFiles.Count) CSV files" -ForegroundColor Green
Write-Host ""

# Extract dates and group by week
$weeks = @{}

foreach ($file in $csvFiles) {
    $dateStr = $file.BaseName
    try {
        $date = [DateTime]::ParseExact($dateStr, "yyyy-MM-dd", $null)
        $monday = Get-MondayOfWeek -Date $date
        $mondayStr = $monday.ToString("yyyy-MM-dd")
        
        if (-not $weeks.ContainsKey($mondayStr)) {
            $weeks[$mondayStr] = $monday
        }
    } catch {
        Write-Host "Skipping invalid date: $dateStr" -ForegroundColor Yellow
    }
}

Write-Host "Processing $($weeks.Count) weeks..." -ForegroundColor Cyan
Write-Host ""

$processedCount = 0
foreach ($mondayStr in ($weeks.Keys | Sort-Object)) {
    $monday = $weeks[$mondayStr]
    
    try {
        Write-Host "[$($processedCount + 1)/$($weeks.Count)] Week starting: $mondayStr"
        & "$BASE_PATH\updateWeekly.ps1" -Date $monday -IdleThreshold $IdleThreshold
        $processedCount++
    } catch {
        Write-Host "  Error processing week: $_" -ForegroundColor Red
    }
    
    Write-Host ""
}

Write-Host "Complete! Processed $processedCount weeks." -ForegroundColor Green
