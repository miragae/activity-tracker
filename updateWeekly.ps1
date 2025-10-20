<#
.SYNOPSIS
    Generates weekly JS file from CSV logs
.DESCRIPTION
    Processes a week's worth of CSV files and generates the weekly dashboard data
.PARAMETER Date
    Any date within the target week (will find Monday of that week)
#>

param(
    [Parameter(Mandatory=$false)]
    [DateTime]$Date = (Get-Date),
    
    [int]$IdleThreshold = 600  # seconds (10 minutes)
)

$BASE_PATH = $PSScriptRoot
$LOGS_PATH = Join-Path $BASE_PATH "logs"

# Get Monday of the week
function Get-MondayOfWeek {
    param([DateTime]$Date)
    
    $dayOfWeek = [int]$Date.DayOfWeek
    if ($dayOfWeek -eq 0) { $dayOfWeek = 7 }  # Sunday = 7
    
    return $Date.AddDays(1 - $dayOfWeek).Date
}

# Process CSV and aggregate activity periods
function Get-ActivityPeriods {
    param(
        [string]$CsvPath,
        [int]$IdleThresholdSeconds
    )
    
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
    $idleMinutesInPeriod = 0
    
    foreach ($record in $records) {
        $timestamp = [DateTime]::Parse($record.timestamp)
        $isActive = $record.status -eq "active"
        $processDesc = $record.process_description
        
        if (-not $isActive) {
            if ($lastActiveTime) {
                $gapSeconds = ($timestamp - $lastActiveTime).TotalSeconds
                if ($gapSeconds -gt $IdleThresholdSeconds) {
                    # Close period
                    if ($currentPeriod) {
                        $periods += $currentPeriod
                        $currentPeriod = $null
                        $idleMinutesInPeriod = 0
                    }
                } else {
                    # Idle within threshold - extend period
                    if ($currentPeriod) {
                        $currentPeriod.EndTime = $timestamp
                        $idleMinutesInPeriod++
                        
                        # Track idle
                        if ($currentPeriod.Focus.ContainsKey("idle")) {
                            $currentPeriod.Focus["idle"] += 1
                        } else {
                            $currentPeriod.Focus["idle"] = 1
                        }
                    }
                }
            }
            continue
        }
        
        # Active record
        $lastActiveTime = $timestamp
        $idleMinutesInPeriod = 0
        
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
    
    # Group by date
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

# Main execution
try {
    $monday = Get-MondayOfWeek -Date $Date
    $mondayStr = $monday.ToString("yyyy-MM-dd")
    $monthFolder = $monday.ToString("yyyy-MM")
    
    Write-Host "Processing week starting: $mondayStr" -ForegroundColor Cyan
    
    # Process all 7 days of the week
    $weekData = @{}
    
    for ($i = 0; $i -lt 7; $i++) {
        $currentDay = $monday.AddDays($i)
        $dateStr = $currentDay.ToString("yyyy-MM-dd")
        $dayMonthFolder = $currentDay.ToString("yyyy-MM")
        $csvPath = Join-Path $LOGS_PATH "$dayMonthFolder\$dateStr.csv"
        
        if (Test-Path $csvPath) {
            Write-Host "  Processing: $dateStr" -ForegroundColor Gray
            $dayData = Get-ActivityPeriods -CsvPath $csvPath -IdleThresholdSeconds $IdleThreshold
            
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
    
    # Convert to JSON
    $json = $weekData | ConvertTo-Json -Depth 10 -Compress
    
    # Atomic write
    $tempFile = "$outputPath.tmp"
    $json | Set-Content -Path $tempFile -Encoding UTF8 -NoNewline
    Move-Item -Path $tempFile -Destination $outputPath -Force
    
    Write-Host "Generated: $outputPath" -ForegroundColor Green
    
} catch {
    Write-Host "Error generating weekly file: $_" -ForegroundColor Red
    Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Red
    exit 1
}
