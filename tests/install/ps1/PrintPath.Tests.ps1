#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Stdout/stderr discipline for pwsh/install.ps1. Mirrors ../print-path.bats.
#
# The load-bearing contract (see CLAUDE.md / .claude/rules/installers.md):
#   * All informational/warning/error output goes to STDERR.
#   * STDOUT is silent on success unless OCX_INSTALL_PRINT_PATH=1 (or
#     -PrintPath), in which case the FINAL stdout line is the absolute bin dir.
# This is what lets a wrapper do `$bin = (... | Select-Object -Last 1)`.
#
# To separate the two streams we run the installer in a child pwsh with
# `2>$errFile`, so $out is pure stdout and $errFile is pure stderr.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Fixture.psm1') -Force
    $script:InstallPs1 = Join-Path $PSScriptRoot '..\..\..\pwsh\install.ps1'
    $script:Target = Get-FixtureTarget

    $script:FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-pp-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    $fixture = New-OcxFixture -Root $FixtureRoot
    $script:Server = Start-FixtureServer -SrvRoot $fixture.SrvRoot
}

AfterAll {
    Stop-FixtureServer -Server $Server
    if (Test-Path $FixtureRoot) {
        Remove-Item -Recurse -Force $FixtureRoot -ErrorAction SilentlyContinue
    }
}

Describe 'install.ps1 stdout/stderr discipline' {
    BeforeEach {
        $script:OcxHome = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-pp-home-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:ErrFile = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-pp-err-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).log"
        $env:OCX_HOME = $OcxHome
        $env:OCX_NO_MODIFY_PATH = '1'
        $env:OCX_INSTALL_SKIP_SELF_INIT = '1'
        $env:OCX_INSTALL_NO_BIN_SMOKETEST = '1'
        $env:OCX_INSTALL_BASE_URL = $Server.BaseUrl
        $env:OCX_INSTALL_API_URL = $Server.ApiUrl
        Remove-Item Env:GITHUB_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_FORMAT_URL -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_CHECKSUM_FORMAT_URL -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_PRINT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_QUIET -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_FORCE -ErrorAction SilentlyContinue
    }

    AfterEach {
        if (Test-Path $OcxHome) { Remove-Item -Recurse -Force $OcxHome -ErrorAction SilentlyContinue }
        if (Test-Path $ErrFile) { Remove-Item -Force $ErrFile -ErrorAction SilentlyContinue }
    }

    # Mirrors print-path.bats: "stdout is empty on default success".
    It 'stdout is empty on default success' {
        $out = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$ErrFile
        $LASTEXITCODE | Should -Be 0
        ($out | Where-Object { $_ -ne '' }) | Should -BeNullOrEmpty
    }

    # Mirrors print-path.bats:
    #   "OCX_INSTALL_PRINT_PATH=1 prints the bin dir as the final stdout line".
    It 'OCX_INSTALL_PRINT_PATH=1 prints the bin dir as the final stdout line' {
        $env:OCX_INSTALL_PRINT_PATH = '1'
        $out = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$ErrFile
        $LASTEXITCODE | Should -Be 0
        ($out | Select-Object -Last 1) | Should -Be (Get-ExpectedBinDir -OcxHome $OcxHome)
    }

    # Mirrors print-path.bats:
    #   "stderr carries the informational banner even with PRINT_PATH set".
    # In skip-self-init mode the success banner is intentionally suppressed, but
    # the progress lines ("Detected platform", "Installing", "Installed to")
    # still go to stderr — assert at least one is present.
    It 'stderr carries informational lines even with PRINT_PATH set' {
        $env:OCX_INSTALL_PRINT_PATH = '1'
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$ErrFile 1>$null
        $LASTEXITCODE | Should -Be 0
        $stderr = if (Test-Path $ErrFile) { Get-Content $ErrFile -Raw } else { '' }
        $stderr | Should -Match 'Detected platform|Installing|Installed to|Checksum'
    }

    # Mirrors print-path.bats:
    #   "OCX_INSTALL_QUIET=1 silences stderr informational lines".
    It 'OCX_INSTALL_QUIET=1 silences stderr informational lines' {
        $env:OCX_INSTALL_QUIET = '1'
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$ErrFile 1>$null
        $LASTEXITCODE | Should -Be 0
        $stderr = if (Test-Path $ErrFile) { Get-Content $ErrFile -Raw } else { '' }
        $stderr | Should -Not -Match 'Detected platform|Installing'
    }

    # Mirrors print-path.bats: "error messages always go to stderr (exit 2 path)".
    # Invalid version is the exit-2 trigger that runs entirely in-script (unlike
    # an unknown flag, which fails param binding before the script body). stdout
    # must stay clean; the error text must land on stderr.
    It 'error messages always go to stderr (exit 2 path)' {
        $out = & pwsh -NoProfile -File $InstallPs1 -Version 'foo;rm' 2>$ErrFile
        $LASTEXITCODE | Should -Be 2
        ($out | Where-Object { $_ -ne '' }) | Should -BeNullOrEmpty
        $stderr = if (Test-Path $ErrFile) { Get-Content $ErrFile -Raw } else { '' }
        $stderr | Should -Match 'error|Invalid version'
    }
}
