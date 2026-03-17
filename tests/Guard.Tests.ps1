#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.0" }

BeforeAll {
    # Set up a temp log file for Write-Log calls
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "BarakaGuardTests-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    $script:LogFile = Join-Path $script:TestRoot "deploy.log"

    $libDir = Join-Path $PSScriptRoot "..\lib"
    Import-Module (Join-Path $libDir "Log.psm1")   -Force
    Import-Module (Join-Path $libDir "State.psm1") -Force
    Import-Module (Join-Path $libDir "Guard.psm1") -Force

    Initialize-Log -Path $script:LogFile
}

AfterAll {
    Remove-Module Guard -ErrorAction SilentlyContinue
    Remove-Module State -ErrorAction SilentlyContinue
    Remove-Module Log   -ErrorAction SilentlyContinue
    Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "Invoke-Step" {
    BeforeEach {
        $script:StepName = "TestStep-$([System.Guid]::NewGuid().ToString('N'))"
        $script:BodyRan  = $false

        # In-memory registry store — keyed by property name
        $script:FakeStore = @{}
        $script:FakePathExists = $false

        # Mock registry operations in the State module scope
        Mock -ModuleName State Test-Path {
            param([string]$Path)
            return $script:FakePathExists
        }
        Mock -ModuleName State New-Item {
            param([string]$Path)
            $script:FakePathExists = $true
        }
        Mock -ModuleName State Get-ItemProperty {
            param([string]$Path, [string]$Name)
            if ($script:FakeStore.ContainsKey($Name)) {
                $obj = [PSCustomObject]@{ $Name = $script:FakeStore[$Name] }
                return $obj
            }
            return $null
        }
        Mock -ModuleName State Set-ItemProperty {
            param([string]$Path, [string]$Name, $Value)
            $script:FakePathExists = $true
            $script:FakeStore[$Name] = $Value
        }
    }

    It "Test 1: Executes the body scriptblock when no registry flag exists" {
        Invoke-Step -StepName $script:StepName -Body { $script:BodyRan = $true }
        $script:BodyRan | Should -BeTrue
    }

    It "Test 2: Sets the registry flag to 1 after successful body execution" {
        Invoke-Step -StepName $script:StepName -Body { }
        $script:FakeStore["$($script:StepName)-Done"] | Should -Be 1
    }

    It "Test 3: Skips the body when the registry flag is already set to 1" {
        # Pre-set the flag in the fake store
        $script:FakePathExists = $true
        $script:FakeStore["$($script:StepName)-Done"] = 1
        $runCount = 0
        Invoke-Step -StepName $script:StepName -Body { $runCount++ }
        $runCount | Should -Be 0
    }

    It "Test 4: Does NOT set the flag if the body throws an error" {
        $threw = $false
        try {
            Invoke-Step -StepName $script:StepName -Body { throw "deliberate failure" }
        } catch {
            $threw = $true
        }
        $threw | Should -BeTrue
        $script:FakeStore.ContainsKey("$($script:StepName)-Done") | Should -BeFalse
    }

    It "Test 5: Creates the registry key path if it does not exist" {
        $script:FakePathExists = $false
        Invoke-Step -StepName $script:StepName -Body { }
        # After a successful run the path should have been created (Set-ItemProperty mock sets it)
        $script:FakePathExists | Should -BeTrue
    }

    It "Test 6: Calls Write-Log with 'Already complete' message when skipping" {
        $script:FakePathExists = $true
        $script:FakeStore["$($script:StepName)-Done"] = 1
        Invoke-Step -StepName $script:StepName -Body { }
        $logContent = Get-Content -Path $script:LogFile -Raw
        $logContent | Should -Match "Already complete"
    }

    It "Test 7: Calls Write-Log with 'Starting' and 'Done' when executing" {
        Invoke-Step -StepName $script:StepName -Body { }
        $logContent = Get-Content -Path $script:LogFile -Raw
        $logContent | Should -Match "Starting"
        $logContent | Should -Match "Done"
    }
}
