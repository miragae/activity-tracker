<#
.SYNOPSIS
    Generates dashboard data from activity logs
.DESCRIPTION
    Processes CSV activity logs and generates JSON data files for the dashboard.
    Can generate current day, specific week, or all historical data.
.PARAMETER Current
    Generate current_day.js from today's CSV
.PARAMETER Week
    Generate weekly JS file. Use with -Date to specify which week.
.PARAMETER All
    Regenerate all weekly JS files from all CSV logs
.PARAMETER Date
    Date within the target week (used with -Week). Defaults to today.
.PARAMETER IdleClosingThreshold
    Seconds of idle time before closing an activity period (default: 120 = 2 minutes)
.PARAMETER IdleGapThreshold
    Seconds to detect long idle gaps that close periods (default: 600 = 10 minutes)
.EXAMPLE
    .\update.ps1 -Current
    Generate current day data
.EXAMPLE
    .\update.ps1 -Week
    Generate current week data
.EXAMPLE
    .\update.ps1 -Week -Date "2025-10-15"
    Generate week containing October 15, 2025
.EXAMPLE
    .\update.ps1 -All
    Regenerate all historical weeks
#>

param(
    [switch]$Current,
    [switch]$Week,
    [switch]$All,

    [DateTime]$Date = (Get-Date),

    [int]$IdleClosingThreshold = 120,  # seconds (2 minutes)
    [int]$IdleGapThreshold = 600       # seconds (10 minutes)
)

$BASE_PATH = $PSScriptRoot
$LOGS_PATH = Join-Path $BASE_PATH "logs"

# Ensure at least one mode is selected
if (-not ($Current -or $Week -or $All)) {
    Write-Host "Error: Please specify at least one mode: -Current, -Week, or -All" -ForegroundColor Red
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Cyan
    Write-Host "  .\update.ps1 -Current"
    Write-Host "  .\update.ps1 -Week"
    Write-Host "  .\update.ps1 -Week -Date '2025-10-15'"
    Write-Host "  .\update.ps1 -All"
    Write-Host "  .\update.ps1 -Current -Week    # Generate both"
    exit 1
}

#region Helper Functions

# Get Monday of the week
function Get-MondayOfWeek {
    param([DateTime]$Date)

    $dayOfWeek = [int]$Date.DayOfWeek
    if ($dayOfWeek -eq 0) { $dayOfWeek = 7 }  # Sunday = 7

    return $Date.AddDays(1 - $dayOfWeek).Date
}

# Process CSV and aggregate activity periods
function Get-ActivityPeriods {
    param([string]$CsvPath)

    if (-not (Test-Path $CsvPath)) {
        return @{}
    }

    $records = Import-Csv -Path $CsvPath

    if ($records.Count -eq 0) {
        return @{}
    }

    $periods = @()
    $currentPeriod = $null
    $lastActiveTime = $null
    $closingTime = $null

    foreach ($record in $records) {
        $timestamp = [DateTime]::Parse($record.timestamp)
        $isActive = $record.status -eq "active"
        $processDesc = $record.process_description

        if (-not $isActive) {
            if ($lastActiveTime -and $currentPeriod) {
                $totalIdleSeconds = ($timestamp - $lastActiveTime).TotalSeconds

                if ($totalIdleSeconds -gt $IdleClosingThreshold) {
                    # Short gap detected - saving closing time
                    if ($null -eq $closingTime) {
                        $closingTime = $timestamp
                    }
                }

                if ($totalIdleSeconds -gt $IdleGapThreshold) { #8:10
                    # Long gap detected - close period at IdleClosingThreshold
                    $currentPeriod.EndTime = $closingTime

                    $idleMinutesToRollback = [math]::Floor(($IdleGapThreshold - $IdleClosingThreshold) / 60)
                    $currentPeriod.Focus["idle"] -= $idleMinutesToRollback
                    $periods += $currentPeriod
                    $currentPeriod = $null
                } else {
                    # Idle within gap threshold - include in current period

                    if ($currentPeriod.Focus.ContainsKey("idle")) {
                        $currentPeriod.Focus["idle"] += 1
                    } else {
                        $currentPeriod.Focus["idle"] = 1
                    }
                }
            }
            continue
        }

        # Active record
        $lastActiveTime = $timestamp
        $closingTime = $null

        if ($null -eq $currentPeriod) {
            $currentPeriod = @{
                StartTime = $timestamp
                EndTime = $timestamp
                Focus = @{}
            }
        }

        $currentPeriod.EndTime = $timestamp

        if ($processDesc) {
            if ($currentPeriod.Focus.ContainsKey($processDesc)) {
                $currentPeriod.Focus[$processDesc] += 1
            } else {
                $currentPeriod.Focus[$processDesc] = 1
            }
        }
    }

    if ($currentPeriod) {
        $periods += $currentPeriod
    }

    # Group by date and format
    $result = @{}
    foreach ($period in $periods) {
        $dateKey = $period.StartTime.ToString("yyyy-MM-dd")
        $periodData = @{
            start = $period.StartTime.ToString("HH:mm")
            end = $period.EndTime.ToString("HH:mm")
            focus = $period.Focus
        }

        if (-not $result.ContainsKey($dateKey)) {
            $result[$dateKey] = @()
        }
        $result[$dateKey] += $periodData
    }

    return $result
}

# Write JSON data atomically
function Write-JsonData {
    param(
        [hashtable]$Data,
        [string]$OutputPath
    )

    $json = $Data | ConvertTo-Json -Depth 10 -Compress

    $tempFile = "$OutputPath.tmp"
    $json | Set-Content -Path $tempFile -Encoding UTF8 -NoNewline
    Move-Item -Path $tempFile -Destination $OutputPath -Force
}

#endregion

#region Mode: Current Day

if ($Current) {
    Write-Host "Generating current day data..." -ForegroundColor Cyan

    try {
        $dateStr = Get-Date -Format "yyyy-MM-dd"
        $monthFolder = Get-Date -Format "yyyy-MM"
        $csvPath = Join-Path $LOGS_PATH "$monthFolder\$dateStr.csv"
        $outputPath = Join-Path $LOGS_PATH "current_day.js"

        $data = Get-ActivityPeriods -CsvPath $csvPath
        Write-JsonData -Data $data -OutputPath $outputPath

        Write-Host "✓ Updated: current_day.js" -ForegroundColor Green
    } catch {
        Write-Host "✗ Error updating current_day.js: $_" -ForegroundColor Red
        exit 1
    }
}

#endregion

#region Mode: Week

if ($Week) {
    Write-Host "Generating weekly data..." -ForegroundColor Cyan

    try {
        $monday = Get-MondayOfWeek -Date $Date
        $mondayStr = $monday.ToString("yyyy-MM-dd")
        $monthFolder = $monday.ToString("yyyy-MM")

        Write-Host "  Week starting: $mondayStr" -ForegroundColor Gray

        # Process all 7 days of the week
        $weekData = @{}

        for ($i = 0; $i -lt 7; $i++) {
            $currentDay = $monday.AddDays($i)
            $dateStr = $currentDay.ToString("yyyy-MM-dd")
            $dayMonthFolder = $currentDay.ToString("yyyy-MM")
            $csvPath = Join-Path $LOGS_PATH "$dayMonthFolder\$dateStr.csv"

            if (Test-Path $csvPath) {
                $dayData = Get-ActivityPeriods -CsvPath $csvPath

                # Merge into week data
                foreach ($key in $dayData.Keys) {
                    $weekData[$key] = $dayData[$key]
                }
            }
        }

        # Determine output path (in Monday's month folder)
        $outputFolder = Join-Path $LOGS_PATH $monthFolder
        if (-not (Test-Path $outputFolder)) {
            New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null
        }

        $outputPath = Join-Path $outputFolder "$mondayStr.js"
        Write-JsonData -Data $weekData -OutputPath $outputPath

        Write-Host "✓ Generated: $mondayStr.js" -ForegroundColor Green
    } catch {
        Write-Host "✗ Error generating weekly file: $_" -ForegroundColor Red
        Write-Host "  Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Red
        exit 1
    }
}

#endregion

#region Mode: All

if ($All) {
    Write-Host "Regenerating all historical data..." -ForegroundColor Cyan
    Write-Host ""

    # Find all CSV files
    $csvFiles = Get-ChildItem -Path $LOGS_PATH -Filter "*.csv" -Recurse |
            Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}\.csv$' }

    if ($csvFiles.Count -eq 0) {
        Write-Host "No CSV files found." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Found $($csvFiles.Count) CSV files" -ForegroundColor Gray

    # Extract dates and group by week
    $weeks = @{}

    foreach ($file in $csvFiles) {
        $dateStr = $file.BaseName
        try {
            $fileDate = [DateTime]::ParseExact($dateStr, "yyyy-MM-dd", $null)
            $monday = Get-MondayOfWeek -Date $fileDate
            $mondayStr = $monday.ToString("yyyy-MM-dd")

            if (-not $weeks.ContainsKey($mondayStr)) {
                $weeks[$mondayStr] = $monday
            }
        } catch {
            Write-Host "⚠ Skipping invalid date: $dateStr" -ForegroundColor Yellow
        }
    }

    Write-Host "Processing $($weeks.Count) weeks..." -ForegroundColor Cyan
    Write-Host ""

    $processedCount = 0
    $sortedWeeks = $weeks.Keys | Sort-Object

    foreach ($mondayStr in $sortedWeeks) {
        $monday = $weeks[$mondayStr]
        $monthFolder = $monday.ToString("yyyy-MM")

        try {
            Write-Host "[$($processedCount + 1)/$($weeks.Count)] Week: $mondayStr" -ForegroundColor Gray

            # Process all 7 days of the week
            $weekData = @{}

            for ($i = 0; $i -lt 7; $i++) {
                $currentDay = $monday.AddDays($i)
                $dateStr = $currentDay.ToString("yyyy-MM-dd")
                $dayMonthFolder = $currentDay.ToString("yyyy-MM")
                $csvPath = Join-Path $LOGS_PATH "$dayMonthFolder\$dateStr.csv"

                if (Test-Path $csvPath) {
                    $dayData = Get-ActivityPeriods -CsvPath $csvPath

                    foreach ($key in $dayData.Keys) {
                        $weekData[$key] = $dayData[$key]
                    }
                }
            }

            # Output
            $outputFolder = Join-Path $LOGS_PATH $monthFolder
            if (-not (Test-Path $outputFolder)) {
                New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null
            }

            $outputPath = Join-Path $outputFolder "$mondayStr.js"
            Write-JsonData -Data $weekData -OutputPath $outputPath

            $processedCount++
        } catch {
            Write-Host "  ✗ Error processing week: $_" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "✓ Complete! Processed $processedCount/$($weeks.Count) weeks." -ForegroundColor Green
}

#endregion
