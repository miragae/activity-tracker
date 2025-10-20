<#
.SYNOPSIS
    Simple HTTP server for Activity Dashboard
.DESCRIPTION
    Serves dashboard files and handles CORS for local file access
#>

param(
    [int]$Port = 8080
)

$BASE_PATH = $PSScriptRoot

# Create HTTP listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")

try {
    $listener.Start()
    Write-Host "Dashboard server started at http://localhost:$Port" -ForegroundColor Green
    Write-Host "Open http://localhost:$Port/dashboard.html in your browser" -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to stop the server" -ForegroundColor Yellow
    Write-Host ""

    while ($listener.IsListening) {
        # Wait for request (with timeout to allow clean exit)
        $contextTask = $listener.GetContextAsync()
        
        while (-not $contextTask.AsyncWaitHandle.WaitOne(200)) {
            # Check if we should stop (allows Ctrl+C to work)
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'C' -and $key.Modifiers -eq 'Control') {
                    throw "User interrupt"
                }
            }
        }
        
        $context = $contextTask.GetAwaiter().GetResult()
        $request = $context.Request
        $response = $context.Response
        
        $requestPath = $request.Url.LocalPath
        if ($requestPath -eq '/') {
            $requestPath = '/dashboard.html'
        }
        
        # Clean path and prevent directory traversal
        $requestPath = $requestPath.TrimStart('/')
        $requestPath = $requestPath -replace '\.\.', ''
        
        $filePath = Join-Path $BASE_PATH $requestPath
        
        Write-Host "$(Get-Date -Format 'HH:mm:ss') - Request: $requestPath" -ForegroundColor Gray
        
        try {
            if (Test-Path $filePath -PathType Leaf) {
                # Determine content type
                $contentType = switch ([System.IO.Path]::GetExtension($filePath)) {
                    '.html' { 'text/html; charset=utf-8' }
                    '.js'   { 'application/javascript; charset=utf-8' }
                    '.json' { 'application/json; charset=utf-8' }
                    '.css'  { 'text/css; charset=utf-8' }
                    '.csv'  { 'text/csv; charset=utf-8' }
                    '.txt'  { 'text/plain; charset=utf-8' }
                    default { 'application/octet-stream' }
                }
                
                # Read and serve file
                $content = [System.IO.File]::ReadAllBytes($filePath)
                $response.ContentType = $contentType
                $response.ContentLength64 = $content.Length
                $response.StatusCode = 200
                $response.OutputStream.Write($content, 0, $content.Length)
                
            } else {
                # 404 Not Found
                $response.StatusCode = 404
                $message = [System.Text.Encoding]::UTF8.GetBytes("404 - File not found: $requestPath")
                $response.ContentLength64 = $message.Length
                $response.OutputStream.Write($message, 0, $message.Length)
                Write-Host "  -> 404 Not Found" -ForegroundColor Red
            }
            
        } catch {
            # 500 Internal Server Error
            $response.StatusCode = 500
            $message = [System.Text.Encoding]::UTF8.GetBytes("500 - Internal Server Error: $_")
            $response.ContentLength64 = $message.Length
            $response.OutputStream.Write($message, 0, $message.Length)
            Write-Host "  -> Error: $_" -ForegroundColor Red
        }
        
        $response.Close()
    }
    
} catch {
    Write-Host "`nServer stopped: $_" -ForegroundColor Yellow
} finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
    Write-Host "Server shut down." -ForegroundColor Yellow
}
