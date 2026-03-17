# Log.psm1 — Structured logging module for Baraka deployment toolkit
# CORE-01: ErrorActionPreference set at module scope to catch all errors
$ErrorActionPreference = "Stop"

# Module-scoped variable holding the active log file path
$script:LogPath = $null

<#
.SYNOPSIS
    Initialises the log subsystem by creating the log directory and recording a startup banner.

.PARAMETER Path
    Absolute path to the log file (e.g. "$env:ProgramData\Baraka\deploy.log").
    The parent directory is created if it does not exist.
#>
function Initialize-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $script:LogPath = $Path

    $banner = "=== Baraka Deploy started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    Write-Log -Level "INFO" -Message $banner
}

<#
.SYNOPSIS
    Writes a timestamped, levelled log line to the log file and the console.

.PARAMETER Level
    Severity level: INFO (default), WARN, ERROR, or DEBUG.

.PARAMETER Message
    The message text to record.
#>
function Write-Log {
    param(
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",

        [Parameter(Mandatory)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    # Write to log file (UTF-8, append)
    Add-Content -Path $script:LogPath -Value $line -Encoding UTF8

    # Write to console with colour coding
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

Export-ModuleMember -Function Write-Log, Initialize-Log
