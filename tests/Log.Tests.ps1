#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.0" }

BeforeAll {
    # Use a temp directory so tests do not require admin or touch ProgramData
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "BarakaLogTests-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    $script:LogFile = Join-Path $script:TestRoot "deploy.log"

    # Import the module under test — path relative to tests/ directory
    $modulePath = Join-Path $PSScriptRoot "..\lib\Log.psm1"
    Import-Module $modulePath -Force
}

AfterAll {
    Remove-Module Log -ErrorAction SilentlyContinue
    Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "Initialize-Log" {
    BeforeEach {
        # Use a fresh sub-directory for each test to isolate file state
        $script:SubDir = Join-Path $script:TestRoot ([System.Guid]::NewGuid().ToString('N'))
        $script:TestLogFile = Join-Path $script:SubDir "test.log"
        Import-Module (Join-Path $PSScriptRoot "..\lib\Log.psm1") -Force
    }

    It "Test 1: Creates the log directory if it does not exist" {
        $script:SubDir | Should -Not -Exist
        Initialize-Log -Path $script:TestLogFile
        $script:SubDir | Should -Exist
    }

    It "Test 2: Sets the module-scoped log path so Write-Log can write to it" {
        Initialize-Log -Path $script:TestLogFile
        # After initialization, Write-Log should succeed (writes to the set path)
        { Write-Log -Message "probe" } | Should -Not -Throw
        $script:TestLogFile | Should -Exist
    }
}

Describe "Write-Log" {
    BeforeAll {
        # One shared log file for Write-Log tests
        $script:WriteLogDir = Join-Path $script:TestRoot "write-log-tests"
        $script:WriteLogFile = Join-Path $script:WriteLogDir "test.log"
        Import-Module (Join-Path $PSScriptRoot "..\lib\Log.psm1") -Force
        Initialize-Log -Path $script:WriteLogFile
    }

    It "Test 3: Writes a line matching the expected timestamp/level pattern" {
        Write-Log -Level "INFO" -Message "pattern check"
        $lines = Get-Content -Path $script:WriteLogFile -Encoding UTF8
        $lastLine = $lines | Where-Object { $_ -match "pattern check" } | Select-Object -Last 1
        $lastLine | Should -Match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[(INFO|WARN|ERROR|DEBUG)\] .+'
    }

    It "Test 4: Appends to the log on successive calls (does not overwrite)" {
        Write-Log -Message "first line"
        Write-Log -Message "second line"
        $content = Get-Content -Path $script:WriteLogFile -Raw
        $content | Should -Match "first line"
        $content | Should -Match "second line"
        # Both lines present means appending occurred
        (Get-Content -Path $script:WriteLogFile).Count | Should -BeGreaterThan 1
    }

    It "Test 5: Includes [ERROR] in output when Level is ERROR" {
        Write-Log -Level "ERROR" -Message "error message test"
        $lines = Get-Content -Path $script:WriteLogFile -Encoding UTF8
        $match = $lines | Where-Object { $_ -match "error message test" } | Select-Object -Last 1
        $match | Should -Match '\[ERROR\]'
    }

    It "Test 6: Includes [WARN] in output when Level is WARN" {
        Write-Log -Level "WARN" -Message "warn message test"
        $lines = Get-Content -Path $script:WriteLogFile -Encoding UTF8
        $match = $lines | Where-Object { $_ -match "warn message test" } | Select-Object -Last 1
        $match | Should -Match '\[WARN\]'
    }

    It "Test 7: Defaults to INFO level when Level is not specified" {
        Write-Log -Message "default level test"
        $lines = Get-Content -Path $script:WriteLogFile -Encoding UTF8
        $match = $lines | Where-Object { $_ -match "default level test" } | Select-Object -Last 1
        $match | Should -Match '\[INFO\]'
    }
}
