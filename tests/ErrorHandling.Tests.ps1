#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.0" }

BeforeAll {
    $script:LibDir = Join-Path $PSScriptRoot "..\lib"
}

Describe "ErrorActionPreference — module scope" {
    It "Test 1: Log.psm1 has ErrorActionPreference = Stop at module scope" {
        $content = Get-Content (Join-Path $script:LibDir "Log.psm1") -Raw
        $content | Should -Match '\$ErrorActionPreference\s*=\s*"Stop"'
    }

    It "Test 2: Guard.psm1 has ErrorActionPreference = Stop at module scope" {
        $content = Get-Content (Join-Path $script:LibDir "Guard.psm1") -Raw
        $content | Should -Match '\$ErrorActionPreference\s*=\s*"Stop"'
    }

    It "Test 3: State.psm1 has ErrorActionPreference = Stop at module scope" {
        $content = Get-Content (Join-Path $script:LibDir "State.psm1") -Raw
        $content | Should -Match '\$ErrorActionPreference\s*=\s*"Stop"'
    }
}

Describe "Invoke-Step catch block — error logging" {
    BeforeAll {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "BarakaErrTests-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
        $script:LogFile = Join-Path $script:TestRoot "deploy.log"

        Import-Module (Join-Path $script:LibDir "Log.psm1")   -Force
        Import-Module (Join-Path $script:LibDir "State.psm1") -Force
        Import-Module (Join-Path $script:LibDir "Guard.psm1") -Force

        Initialize-Log -Path $script:LogFile
    }

    BeforeEach {
        # Mock registry operations in State scope to avoid HKLM/HKCU dependency on Linux
        $script:FakeStore = @{}
        $script:FakePathExists = $false

        Mock -ModuleName State Test-Path         { return $script:FakePathExists }
        Mock -ModuleName State New-Item          { $script:FakePathExists = $true }
        Mock -ModuleName State Get-ItemProperty  {
            param([string]$Path, [string]$Name)
            if ($script:FakeStore.ContainsKey($Name)) {
                return [PSCustomObject]@{ $Name = $script:FakeStore[$Name] }
            }
            return $null
        }
        Mock -ModuleName State Set-ItemProperty  {
            param([string]$Path, [string]$Name, $Value)
            $script:FakeStore[$Name] = $Value
        }
    }

    AfterAll {
        Remove-Module Guard -ErrorAction SilentlyContinue
        Remove-Module State -ErrorAction SilentlyContinue
        Remove-Module Log   -ErrorAction SilentlyContinue
        Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Test 4: Invoke-Step catch block calls Write-Log with ERROR level on body failure" {
        $stepName = "FailingStep-$([System.Guid]::NewGuid().ToString('N'))"
        try {
            Invoke-Step -StepName $stepName -Body { throw "intentional test error" }
        } catch {
            # Expected — the error is re-thrown after logging
        }
        $logContent = Get-Content -Path $script:LogFile -Raw
        $logContent | Should -Match '\[ERROR\]'
        $logContent | Should -Match "intentional test error"
    }
}
