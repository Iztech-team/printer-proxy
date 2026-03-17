# Guard.psm1 — Idempotency wrapper for Baraka deployment steps
# CORE-01: ErrorActionPreference set at module scope to catch all errors
$ErrorActionPreference = "Stop"

# Note: Guard.psm1 depends on Log.psm1 (Write-Log) and State.psm1
# (Get-DeployState, Set-DeployState, Set-RegistryBase) being imported into the
# same session before Guard.psm1 is imported.

<#
.SYNOPSIS
    Executes a deployment step body with idempotency protection via registry guards.

    Behaviour:
      1. Ensures the registry base path exists.
      2. If "$StepName-Done" == 1 in registry: logs "Already complete" and returns.
      3. Logs "Starting", executes the body scriptblock.
      4. On failure: logs ERROR and re-throws (flag is NOT set).
      5. On success: sets "$StepName-Done" = 1 and logs "Done".

.PARAMETER StepName
    Unique name for this step. Used as the registry property prefix.

.PARAMETER Body
    Scriptblock containing the step's implementation.
#>
function Invoke-Step {
    param(
        [Parameter(Mandatory)]
        [string]$StepName,

        [Parameter(Mandatory)]
        [scriptblock]$Body
    )

    # Check idempotency guard
    $doneValue = Get-DeployState -Name "$StepName-Done"
    if ($doneValue -eq 1) {
        Write-Log -Level "INFO" -Message "[$StepName] Already complete -- skipping"
        return
    }

    Write-Log -Level "INFO" -Message "[$StepName] Starting"

    try {
        & $Body
    } catch {
        Write-Log -Level "ERROR" -Message "[$StepName] Failed: $($_.Exception.Message)"
        throw
    }

    Set-DeployState -Name "$StepName-Done" -Value 1
    Write-Log -Level "INFO" -Message "[$StepName] Done"
}

Export-ModuleMember -Function Invoke-Step
