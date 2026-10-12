#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Position=0)]
    [ValidateSet('Menu','List','Save','Switch','Add','PrepareLogin','FinishLogin','CancelLogin','SyncSessions','Remove','Doctor','Recover')]
    [string]$Action = 'Menu',
    [Parameter(Position=1)][string]$Name,
    [string]$DesktopDataDirectory,
    [string]$GlobalConfigPath,
    [string]$StoreDirectory,
    [string]$OrganizationId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ClaudeSwitcher.Core.psm1') -Force -DisableNameChecking
$context = New-SwitcherContext -DesktopDataDirectory $DesktopDataDirectory -GlobalConfigPath $GlobalConfigPath -StoreDirectory $StoreDirectory
$callerCmdlet = $PSCmdlet

function Show-Accounts {
    $status = Get-SwitcherStatus $context
    if ($status.Accounts.Count) { $status.Accounts | Format-Table Name,Active,SavedAt -AutoSize | Out-Host }
    else { Write-Host 'No saved Desktop accounts yet. Close Claude and save your current login first.' }
    if ($status.Active) { Write-Host "Current Desktop login: $($status.Active)" }
    else { Write-Host 'Current Desktop login is not saved or not yet identified.' }
    if ($status.LoginPending) { Write-Host 'Account registration is pending. Use FinishLogin after signing in, or CancelLogin to restore the previous account.' -ForegroundColor Yellow }
    if ($status.RecoveryPending) { Write-Host 'An interrupted operation needs recovery. Close Claude and run Recover.' -ForegroundColor Yellow }
}
function Invoke-Action {
    param([string]$SelectedAction,[string]$SelectedName)
    switch ($SelectedAction) {
        'List' { Show-Accounts }
        'Doctor' {
            Write-Host "Desktop profile: $($context.DataDirectory)"
            Write-Host "Shared config:   $($context.GlobalConfigPath)"
            Write-Host "Encrypted vault: $($context.VaultPath)"
            Write-Host "Cookie database: $(Test-Path -LiteralPath $context.CookiePath)"
            Write-Host 'Local Code session registries:'
            $registries = @()
            if (Test-Path -LiteralPath $context.SessionsPath) {
                foreach ($account in @(Get-ChildItem -LiteralPath $context.SessionsPath -Directory)) {
                    foreach ($org in @(Get-ChildItem -LiteralPath $account.FullName -Directory)) {
                        $registries += [pscustomobject]@{ Account=$account.Name; Organization=$org.Name; Sessions=@(Get-ChildItem -LiteralPath $org.FullName -File -Filter 'local_*.json').Count }
                    }
                }
            }
            $registries | Format-Table -AutoSize | Out-Host
            Show-Accounts
        }
        'Save' {
            if ($callerCmdlet.ShouldProcess($context.DataDirectory,"Save Desktop login as '$SelectedName'")) {
                Save-SwitcherAccount $context $SelectedName $OrganizationId
                Write-Host "Saved Desktop login '$SelectedName'. Credentials are encrypted for this Windows user."
            }
        }
        'Switch' {
            if ($callerCmdlet.ShouldProcess($context.DataDirectory,"Switch Desktop login to '$SelectedName' and share local Code sessions")) {
                Switch-ClaudeAccount $context $SelectedName
                Write-Host "Switched Desktop login to '$SelectedName'. Open Claude Desktop and resume your local Code session."
            }
        }
        'SyncSessions' {
            if ($callerCmdlet.ShouldProcess($context.SessionsPath,'Share local Code session records with the current saved account')) {
                $current = (Get-SwitcherStatus $context).Active
                if (-not $current) { throw 'Save the current Desktop login first.' }
                Switch-ClaudeAccount $context $current -SessionsOnly
                Write-Host 'Local Code session records synchronized. Open Claude Desktop to see them.'
            }
        }
        'PrepareLogin' {
            if ($callerCmdlet.ShouldProcess($context.DataDirectory,"Prepare Desktop registration for '$SelectedName' without revoking saved logins")) {
                Start-SwitcherLogin $context $SelectedName
                Write-Host "Registration prepared for '$SelectedName'."
                Write-Host 'Open Claude Desktop, sign into the new account, open the Code tab once, then quit the app completely.'
                Write-Host 'Run .\ClaudeSwitcher.ps1 FinishLogin afterwards, or CancelLogin to restore the previous account.'
            }
        }
        'Add' {
            if ($callerCmdlet.ShouldProcess($context.DataDirectory,"Register another Desktop account as '$SelectedName'")) {
                Start-SwitcherLogin $context $SelectedName
                Write-Host 'Open Claude Desktop and sign into the new account. Open its Code tab once, then quit Claude completely.' -ForegroundColor Cyan
                Write-Host 'The shared local session records will be added when registration finishes. Do not use the Desktop Logout button.'
                $answer = Read-Host 'Press Enter after quitting Claude to save the login, or type cancel to restore the previous account'
                if ($answer -eq 'cancel') { Undo-SwitcherLogin $context; Write-Host 'Previous Desktop login restored.' }
                else { Complete-SwitcherLogin $context $OrganizationId; Write-Host "Saved '$SelectedName' and shared your local Code sessions. Reopen Claude Desktop." }
            }
        }
        'FinishLogin' {
            if ($callerCmdlet.ShouldProcess($context.DataDirectory,'Capture the new Desktop account and share local Code sessions')) {
                Complete-SwitcherLogin $context $OrganizationId
                Write-Host 'New Desktop login saved. Shared local Code sessions are ready; reopen Claude Desktop.'
            }
        }
        'CancelLogin' {
            if ($callerCmdlet.ShouldProcess($context.DataDirectory,'Restore the Desktop login from before account registration')) {
                Undo-SwitcherLogin $context
                Write-Host 'Previous Desktop login restored.'
            }
        }
        'Remove' {
            if ($callerCmdlet.ShouldProcess($SelectedName,'Remove encrypted saved account copy (live login remains)')) {
                Remove-SwitcherAccount $context $SelectedName
                Write-Host "Removed saved copy '$SelectedName'."
            }
        }
        'Recover' {
            if ($callerCmdlet.ShouldProcess($context.DataDirectory,'Recover an interrupted Desktop operation')) {
                $module = Get-Module ClaudeSwitcher.Core
                & $module { param($c) Invoke-LockedOperation $c {} } $context
                Write-Host 'Recovery check complete.'
            }
        }
    }
}

if ($Action -ne 'Menu') {
    try { Invoke-Action $Action $Name }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
    exit 0
}

Write-Host 'Claude Desktop account switcher' -ForegroundColor Cyan
Write-Host 'Shared local Code sessions and configuration. No CLI login required.'
Write-Host "Profile: $($context.DataDirectory)"
while ($true) {
    Write-Host ''
    try { Show-Accounts } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    Write-Host ''
    Write-Host '1 Save current account    2 Add another account     3 Switch account'
    Write-Host '4 Sync local sessions     5 Finish pending login    6 Cancel pending login'
    Write-Host '7 Remove saved account    8 Diagnose                9 Recover interrupted switch'
    Write-Host 'Q Quit'
    $choice = Read-Host 'Choose'
    if ($choice -eq 'q') { break }
    try {
        switch ($choice) {
            '1' { Invoke-Action Save (Read-Host 'Label for current account') }
            '2' { Invoke-Action Add (Read-Host 'Label for new account') }
            '3' { Invoke-Action Switch (Read-Host 'Saved account label') }
            '4' { Invoke-Action SyncSessions '' }
            '5' { Invoke-Action FinishLogin '' }
            '6' { Invoke-Action CancelLogin '' }
            '7' { Invoke-Action Remove (Read-Host 'Saved account label to remove') }
            '8' { Invoke-Action Doctor '' }
            '9' { Invoke-Action Recover '' }
            default { Write-Host 'Choose a menu number or Q.' }
        }
    } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
}
