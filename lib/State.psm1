# State.psm1 — Registry state persistence helpers for Baraka deployment toolkit
# CORE-01: ErrorActionPreference set at module scope to catch all errors
$ErrorActionPreference = "Stop"

# Module-scoped registry base path; overridable via Set-RegistryBase for testing
$script:RegBase = "HKLM:\SOFTWARE\Baraka\Deploy"

<#
.SYNOPSIS
    Overrides the registry base path used by Get-DeployState and Set-DeployState.
    Intended for test isolation (e.g. use HKCU during unit tests to avoid requiring admin).

.PARAMETER Path
    The full registry path to use as the base (e.g. "HKCU:\SOFTWARE\BarakaTest").
#>
function Set-RegistryBase {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $script:RegBase = $Path
}

<#
.SYNOPSIS
    Reads a deployment state flag from the registry.

.PARAMETER Name
    Property name to read (e.g. "Preflight-Done").

.OUTPUTS
    The stored value, or $null if the property does not exist.
#>
function Get-DeployState {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-Path $script:RegBase)) {
        return $null
    }

    $prop = Get-ItemProperty -Path $script:RegBase -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $prop) {
        return $null
    }
    return $prop.$Name
}

<#
.SYNOPSIS
    Writes a deployment state flag to the registry.
    Creates the registry key path if it does not exist.

.PARAMETER Name
    Property name to write (e.g. "Preflight-Done").

.PARAMETER Value
    Value to store (typically 1 for a done flag).
#>
function Set-DeployState {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        $Value
    )

    if (-not (Test-Path $script:RegBase)) {
        New-Item -Path $script:RegBase -Force | Out-Null
    }

    Set-ItemProperty -Path $script:RegBase -Name $Name -Value $Value -Force
}

Export-ModuleMember -Function Get-DeployState, Set-DeployState, Set-RegistryBase
