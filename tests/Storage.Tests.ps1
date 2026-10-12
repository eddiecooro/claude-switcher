#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$module = Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.Core.psm1') -Force -PassThru -DisableNameChecking
$path = Join-Path ([IO.Path]::GetTempPath()) ('claude-storage-test-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
try {
    & $module {
        param($p)
        foreach ($length in @(65535,65536,65537,70000,300000)) {
            $payload = [pscustomobject]@{ SimulatedSharedConfig=('x' * $length) }
            $encoded = Protect-Data $payload
            if (-not $encoded.StartsWith('CCD-DPAPI-1:') -or $encoded.Contains('SimulatedSharedConfig')) { throw 'New storage format is not an encrypted envelope.' }
            [IO.File]::WriteAllText($p,$encoded)
            $decoded = Read-ProtectedData $p
            if ($decoded.SimulatedSharedConfig -cne $payload.SimulatedSharedConfig) { throw 'Recovery payload did not round-trip.' }
            Write-Host "PASS Encrypted payload of $length characters round-trips."
        }
        $legacy = ConvertTo-SecureString '{"Name":"Previously saved account"}' -AsPlainText -Force
        try { [IO.File]::WriteAllText($p,(ConvertFrom-SecureString $legacy)) } finally { $legacy.Dispose() }
        if ((Read-ProtectedData $p).Name -cne 'Previously saved account') { throw 'Legacy account format was not preserved.' }
        Write-Host 'PASS Original saved-account encryption format remains readable.'
        [IO.File]::WriteAllText($p,'CCD-DPAPI-1:corrupt')
        $rejected=$false
        try { $null=Read-ProtectedData $p } catch { $rejected=$_.Exception.Message -like '*Cannot read encrypted storage*' }
        if (-not $rejected) { throw 'Malformed new storage format was not rejected.' }
        Write-Host 'PASS Malformed encrypted envelope fails safely.'
    } $path
} finally {
    if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    Remove-Module $module.Name -Force
}
