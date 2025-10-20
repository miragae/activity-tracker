<#
.SYNOPSIS
    Updates current_day.js from today's CSV
.DESCRIPTION
    Processes today's activity log and generates current_day.js for dashboard
#>

param(
    [int]$IdleThreshold = 600  # seconds (10 minutes)
)

$BASE_PATH = $PSScriptRoot
$LOGS_PATH = Join-Path $BASE_PATH "logs"

# Get today's CSV path
$date = Get-Date -Format "yyyy-MM-dd"
$monthFolder = Get-Date -Format "yyyy-MM"
$csvPath = Join-Path $LOGS_PATH "$monthFolder\$date.csv"
$outputPath = Join-Path $LOGS_PATH "current_day.js"

# Process CSV and aggregate activity periods
function Get-ActivityPeriods {
    param(
        [string]$CsvPath,
        [int]$IdleThresholdSeconds
    )
    
    if (-not (Test-Path $CsvPath)) {
        return @{}
    }
    
    # Read CSV (skip header)
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
            # Idle record - check if gap exceeds threshold
            if ($lastActiveTime) {
                $gapSeconds = ($timestamp - $lastActiveTime).TotalSeconds
                if ($gapSeconds -gt $IdleThresholdSeconds) {
                    # Close current period (don't include this idle minute)
                    if ($currentPeriod) {
                        $periods += $currentPeriod
                        $currentPeriod = $null
                        $idleMinutesInPeriod = 0
                    }
                } else {
                    # Idle within threshold - extend period and count as idle
                    if ($currentPeriod) {
                        $currentPeriod.EndTime = $timestamp
                        $idleMinutesInPeriod++
                        
                        # Track idle as a focus "app"
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
        $idleMinutesInPeriod = 0  # Reset idle counter
        
        # Check if we should start a new period
        if ($null -eq $currentPeriod) {
            $currentPeriod = @{
                StartTime = $timestamp
                EndTime = $timestamp
                Focus = @{}
            }
        }
        
        # Update end time
        $currentPeriod.EndTime = $timestamp
        
        # Count focus time (1 minute per sample)
        if ($processDesc) {
            if ($currentPeriod.Focus.ContainsKey($processDesc)) {
                $currentPeriod.Focus[$processDesc] += 1
            } else {
                $currentPeriod.Focus[$processDesc] = 1
            }
        }
    }
    
    # Close final period
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

# Generate current_day.js
try {
    $data = Get-ActivityPeriods -CsvPath $csvPath -IdleThresholdSeconds $IdleThreshold
    
    # Convert to JSON
    $json = $data | ConvertTo-Json -Depth 10 -Compress
    
    # Atomic write via temp file
    $tempFile = "$outputPath.tmp"
    $json | Set-Content -Path $tempFile -Encoding UTF8 -NoNewline
    Move-Item -Path $tempFile -Destination $outputPath -Force
    
    Write-Host "Updated: current_day.js" -ForegroundColor Green
    
} catch {
    Write-Host "Error updating current_day.js: $_" -ForegroundColor Red
    exit 1
}
