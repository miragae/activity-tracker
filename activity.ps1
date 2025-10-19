<#
.SYNOPSIS
    Activity Monitor - Tracks user activity and focused windows
.DESCRIPTION
    Monitors user activity every 60 seconds using Win32 API
    Logs activity to daily CSV files and generates dashboard data
#>

#Requires -Version 5.1

# Configuration
$SAMPLE_INTERVAL = 60        # seconds between samples
$IDLE_THRESHOLD = 600        # seconds (10 minutes) to consider gaps as continuous activity
$BASE_PATH = $PSScriptRoot
$LOGS_PATH = Join-Path $BASE_PATH "logs"

# Win32 API Definitions
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class Win32API {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
    
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
}
"@

# Initialize directories
function Initialize-Directories {
    if (-not (Test-Path $LOGS_PATH)) {
        New-Item -Path $LOGS_PATH -ItemType Directory -Force | Out-Null
        Write-Host "Created logs directory: $LOGS_PATH"
    }
}

# Get idle time in seconds
function Get-IdleTime {
    $lastInputInfo = New-Object Win32API+LASTINPUTINFO
    $lastInputInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lastInputInfo)
    
    if ([Win32API]::GetLastInputInfo([ref]$lastInputInfo)) {
        $tickCount = [Environment]::TickCount
        $idleTime = ($tickCount - $lastInputInfo.dwTime) / 1000
        return [math]::Floor($idleTime)
    }
    
    return 0
}

# Get active window information
function Get-ActiveWindow {
    $hwnd = [Win32API]::GetForegroundWindow()
    
    if ($hwnd -eq [IntPtr]::Zero) {
        return @{
            Title = "[No Window]"
            ProcessName = "Unknown"
            ProcessDescription = "Unknown"
        }
    }
    
    # Get window title
    $titleBuilder = New-Object System.Text.StringBuilder 256
    $length = [Win32API]::GetWindowText($hwnd, $titleBuilder, $titleBuilder.Capacity)
    $title = if ($length -gt 0) { $titleBuilder.ToString() } else { "[No Title]" }
    
    # Get process information
    $processId = 0
    [Win32API]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
    
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        $processName = $process.Name
        
        # Get file description from executable
        try {
            $processPath = $process.Path
            if ($processPath) {
                $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($processPath)
                $processDescription = if ($versionInfo.FileDescription) {
                    $versionInfo.FileDescription
                } else {
                    $processName
                }
            } else {
                $processDescription = $processName
            }
        } catch {
            $processDescription = $processName
        }
    } catch {
        $processName = "Unknown"
        $processDescription = "Unknown"
    }
    
    return @{
        Title = $title
        ProcessName = $processName
        ProcessDescription = $processDescription
    }
}

# Write activity log entry
function Write-ActivityLog {
    param(
        [string]$Status,
        [hashtable]$Window
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $date = Get-Date -Format "yyyy-MM-dd"
    $monthFolder = Get-Date -Format "yyyy-MM"
    
    $monthPath = Join-Path $LOGS_PATH $monthFolder
    if (-not (Test-Path $monthPath)) {
        New-Item -Path $monthPath -ItemType Directory -Force | Out-Null
    }
    
    $csvPath = Join-Path $monthPath "$date.csv"
    
    # Create CSV with headers if it doesn't exist
    if (-not (Test-Path $csvPath)) {
        "timestamp,status,window_title,process_name,process_description" | Set-Content -Path $csvPath -Encoding UTF8
    }
    
    # Escape CSV values
    $windowTitle = if ($Window) { $Window.Title -replace '"', '""' } else { "" }
    $processName = if ($Window) { $Window.ProcessName } else { "" }
    $processDescription = if ($Window) { $Window.ProcessDescription -replace '"', '""' } else { "" }
    
    $line = "$timestamp,$Status,`"$windowTitle`",$processName,`"$processDescription`""
    
    # Atomic append
    Add-Content -Path $csvPath -Value $line -Encoding UTF8
}

# Detect if new day started
function Test-NewDay {
    param([DateTime]$LastCheck)
    
    $now = Get-Date
    return $now.Date -gt $LastCheck.Date
}

# Main execution
function Start-ActivityMonitor {
    Write-Host "Activity Monitor Starting..." -ForegroundColor Green
    Write-Host "Sample Interval: $SAMPLE_INTERVAL seconds"
    Write-Host "Idle Threshold: $IDLE_THRESHOLD seconds"
    Write-Host "Logs Path: $LOGS_PATH"
    Write-Host ""
    
    Initialize-Directories
    
    # Generate initial current_day.js if it doesn't exist
    $currentDayJs = Join-Path $LOGS_PATH "current_day.js"
    if (-not (Test-Path $currentDayJs)) {
        & "$BASE_PATH\updateCurrent.ps1"
    }
    
    $lastCheckDate = Get-Date
    $sampleCount = 0
    
    Write-Host "Monitoring started. Press Ctrl+C to stop." -ForegroundColor Cyan
    Write-Host ""
    
    while ($true) {
        try {
            # Calculate next sample time (synchronized to minute boundary)
            $now = Get-Date
            $nextSample = $now.AddMinutes(1)
            $nextSample = Get-Date -Year $nextSample.Year -Month $nextSample.Month `
                                   -Day $nextSample.Day -Hour $nextSample.Hour `
                                   -Minute $nextSample.Minute -Second 0 -Millisecond 0
            
            # Perform sampling
            $idleSeconds = Get-IdleTime
            $isIdle = $idleSeconds -gt $SAMPLE_INTERVAL
            
            # Always get window information (even when idle)
            $window = Get-ActiveWindow
            
            # Determine status
            $status = if ($isIdle) { "idle" } else { "active" }
            
            # Log activity
            Write-ActivityLog -Status $status -Window $window
            
            $sampleCount++
            $timestamp = Get-Date -Format "HH:mm:ss"
            Write-Host "[$timestamp] Sample #$sampleCount - Status: $status - Window: $($window.ProcessDescription)" -ForegroundColor $(if ($isIdle) { "Yellow" } else { "Green" })
            
            # Update current day data
            & "$BASE_PATH\updateCurrent.ps1"
            
            # Check if new day started
            if (Test-NewDay -LastCheck $lastCheckDate) {
                Write-Host ""
                Write-Host "New day detected. Processing previous day..." -ForegroundColor Cyan
                
                $yesterday = $lastCheckDate.Date
                & "$BASE_PATH\updateWeekly.ps1" -Date $yesterday
                
                $lastCheckDate = Get-Date
                Write-Host "Day transition complete." -ForegroundColor Green
                Write-Host ""
            }
            
            # Sleep until next minute boundary
            $sleepMs = [math]::Max(0, ($nextSample - (Get-Date)).TotalMilliseconds)
            if ($sleepMs -gt 0) {
                Start-Sleep -Milliseconds $sleepMs
            }
            
        } catch {
            Write-Host "Error: $_" -ForegroundColor Red
            Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Red
            Start-Sleep -Seconds $SAMPLE_INTERVAL
        }
    }
}

# Start monitoring
Start-ActivityMonitor
