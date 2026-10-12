#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.Core.psm1') -Force -PassThru -DisableNameChecking
$root = Join-Path ([IO.Path]::GetTempPath()) ('claude-desktop-switcher-test-' + [Guid]::NewGuid().ToString('N'))
$data = Join-Path $root 'desktop'
$null = [IO.Directory]::CreateDirectory((Join-Path $data 'Network'))
$ctx = New-SwitcherContext -DesktopDataDirectory $data -GlobalConfigPath (Join-Path $root '.claude.json') -StoreDirectory (Join-Path $root 'vault')
$script:checks = 0
$idA = '11111111-1111-1111-1111-111111111111'; $orgA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$idB = '22222222-2222-2222-2222-222222222222'; $orgB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
$idC = '33333333-3333-3333-3333-333333333333'; $orgC = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
function Assert { param([bool]$Ok,[string]$Message) if (-not $Ok) { throw "FAILED: $Message" }; $script:checks++; Write-Host "PASS $Message" }
function Assert-Throws { param([scriptblock]$Code,[string]$Match,[string]$Message) $ok=$false; try { & $Code } catch { $ok=$_.Exception.Message -like $Match }; Assert $ok $Message }
function Write-Json { param([string]$Path,$Object) [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null; [IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Object -Depth 100),(New-Object Text.UTF8Encoding($false))) }
function Get-Cookie {
    param([string]$Name)
    $rows = [ClaudeSwitcher.DesktopSqlite]::Query($ctx.CookiePath,"SELECT value FROM cookies WHERE name='$Name'")
    if ($rows.Count) { return $rows[0].Cells[0].Value }; $null
}
function Set-FakeLogin {
    param([string]$Id,[string]$Org,[string]$Token='initial')
    $cfg = Get-Content -LiteralPath $ctx.ConfigPath -Raw | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName lastKnownAccountUuid -NotePropertyValue $Id -Force
    $cfg | Add-Member -NotePropertyName 'oauth:tokenCacheV2' -NotePropertyValue "opaque-encrypted-cache-$Id-$Token" -Force
    $cfg | Add-Member -NotePropertyName 'oauth:tokenCache' -NotePropertyValue 'opaque-legacy' -Force
    Write-Json $ctx.ConfigPath $cfg
    $globalCfg = Get-Content -LiteralPath $ctx.GlobalConfigPath -Raw | ConvertFrom-Json
    $globalCfg | Add-Member -NotePropertyName oauthAccount -NotePropertyValue @{ accountUuid=$Id; organizationUuid=$Org; emailAddress='fake@example.invalid' } -Force
    Write-Json $ctx.GlobalConfigPath $globalCfg
    [ClaudeSwitcher.DesktopSqlite]::CreateTestDatabase($ctx.CookiePath,@(
        ('DELETE FROM cookies WHERE ' + [ClaudeSwitcher.DesktopSqlite]::AuthPredicate),
        "INSERT INTO cookies VALUES (123,'.claude.ai','sessionKey','fake-session-$Id-$Token',X'010002FF','/',99999999999999,1,1)",
        "INSERT INTO cookies VALUES (124,'.claude.ai','lastActiveOrg','$Org',X'','/',99999999999999,1,0)"
    ))
}
function Add-Session {
    param([string]$Id,[string]$Org,[string]$Session,[double]$Activity,[string]$Title,[switch]$Remote)
    $dir = Join-Path (Join-Path $ctx.SessionsPath $Id) $Org
    $record = @{ sessionId=$Session; cliSessionId='44444444-4444-4444-4444-444444444444'; cwd='C:\project with spaces'; originCwd='C:\project with spaces'; lastActivityAt=$Activity; title=$Title; futureField=@{ nested=@(1,2) } }
    if ($Remote) { $record.remoteTarget = @{ host='remote.example.invalid' } }
    $path = Join-Path $dir ($Session + '.json')
    Write-Json $path $record
    return $path
}
try {
    & $module { function script:Get-ClaudeProcesses { @() } }
    [ClaudeSwitcher.DesktopSqlite]::CreateTestDatabase($ctx.CookiePath,@(
        'CREATE TABLE cookies (creation_utc INTEGER,host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER,is_secure INTEGER,is_httponly INTEGER,UNIQUE(host_key,name,path))',
        "INSERT INTO cookies VALUES (1,'example.invalid','otherLogin','keep-other-cookie',X'ABCDEF','/',9,1,1)"
    ))
    Write-Json $ctx.ConfigPath @{ locale='en-US'; bootFrameLayout=@{ split=0.4 }; unknownFuturePreference=@{ items=@('one','two'); timestamp='2026-08-01T12:30:00.123456+02:00' } }
    Write-Json $ctx.LocalStatePath @{ os_crypt=@{ encrypted_key='fake-chromium-dpapi-key' }; browser=@{ version='test' } }
    Write-Json $ctx.GlobalConfigPath @{ projects=@{ 'C:\project with spaces'=@{ lastSessionId='same-transcript' } }; mcpServers=@{ local=@{ command='shared-helper' } }; userID='same-installation'; hasCompletedOnboarding=$true; simulatedLargeCache=('x' * 60000) }
    $transcript = Join-Path $root '.claude\projects\same\session.jsonl'
    $null = [IO.Directory]::CreateDirectory((Split-Path $transcript -Parent))
    [IO.File]::WriteAllText($transcript,'shared-transcript-bytes')
    $localStorage = Join-Path $data 'Local Storage\leveldb\000001.ldb'
    $null = [IO.Directory]::CreateDirectory((Split-Path $localStorage -Parent))
    [IO.File]::WriteAllText($localStorage,'shared-workspace-settings')
    $desktopConfig = Join-Path $data 'claude_desktop_config.json'
    Write-Json $desktopConfig @{ preferences=@{ desktop=$true }; mcpServers=@{ shared=@{ command='same-helper' } } }
    $preservedFiles = @($transcript,$localStorage,$desktopConfig,$ctx.LocalStatePath)
    $originalHashes = @($preservedFiles | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash })

    Set-FakeLogin $idA $orgA
    $configBefore = [IO.File]::ReadAllText($ctx.ConfigPath)
    Save-SwitcherAccount $ctx Personal
    Assert ((Get-SwitcherStatus $ctx).Active -eq 'Personal') 'Saved Desktop account is recognized'
    Assert ([IO.File]::ReadAllText($ctx.ConfigPath) -ceq $configBefore) 'Save does not rewrite Desktop preferences'
    Assert (-not [IO.File]::ReadAllText($ctx.VaultPath).Contains('fake-session')) 'Desktop session cookies are encrypted in the vault'
    Assert (-not [IO.File]::ReadAllText($ctx.VaultPath).Contains('opaque-encrypted')) 'Opaque OAuth cache is protected by the encrypted vault'
    Assert-Throws { Save-SwitcherAccount $ctx '' } '*account label*' 'Blank account label fails safely'

    $s1 = 'local_55555555-5555-5555-5555-555555555555'
    $s2 = 'local_66666666-6666-6666-6666-666666666666'
    $deleted = 'local_77777777-7777-7777-7777-777777777777'
    $remote = 'local_88888888-8888-8888-8888-888888888888'
    $source = Add-Session $idA $orgA $s1 100 'Latest title'
    $null = Add-Session $idB $orgB $s1 50 'Older title'
    $second = Add-Session $idB $orgB $s2 90 'Another local conversation'
    $null = Add-Session $idA $orgA $deleted 80 'Deleted by B'
    $null = Add-Session $idA $orgA $remote 80 'SSH conversation' -Remote
    $dirB = Join-Path (Join-Path $ctx.SessionsPath $idB) $orgB
    [IO.File]::WriteAllText((Join-Path $dirB 'deleted_77777777-7777-7777-7777-777777777777'),'tombstone')
    Write-Json (Join-Path $dirB 'scheduled-tasks.json') @{ scheduledTasks=@('do-not-copy') }
    Set-FakeLogin $idB $orgB
    Assert-Throws { Switch-ClaudeAccount $ctx Personal } '*Save the current*' 'Unsaved Desktop login cannot be overwritten'
    Assert-Throws { Save-SwitcherAccount $ctx Personal } '*different Desktop account*' 'A different account cannot overwrite a label'
    Save-SwitcherAccount $ctx Work
    Switch-ClaudeAccount $ctx Personal
    Assert ((Get-Cookie sessionKey) -eq "fake-session-$idA-initial") 'Switch restores Desktop web authentication cookie'
    Assert ((Get-Cookie otherLogin) -eq 'keep-other-cookie') 'Unrelated browser cookies survive switching'
    Assert ((Get-Cookie lastActiveOrg) -eq $orgA) 'Switch selects the saved Desktop organization'
    $cfg = Get-Content $ctx.ConfigPath -Raw | ConvertFrom-Json
    Assert ($cfg.'oauth:tokenCacheV2' -eq "opaque-encrypted-cache-$idA-initial") 'Switch restores opaque Desktop OAuth cache'
    Assert ($cfg.locale -eq 'en-US' -and $cfg.bootFrameLayout.split -eq 0.4 -and $cfg.unknownFuturePreference.items[1] -eq 'two') 'Known and unknown Desktop preferences survive switching'
    Assert ([IO.File]::ReadAllText($ctx.ConfigPath).Contains('2026-08-01T12:30:00.123456+02:00')) 'ISO timestamps in shared preferences retain their original string representation'
    $globalCfg = Get-Content $ctx.GlobalConfigPath -Raw | ConvertFrom-Json
    Assert ($globalCfg.oauthAccount.accountUuid -eq $idA) 'Global account identity follows Desktop authentication'
    Assert ($globalCfg.projects.'C:\project with spaces'.lastSessionId -eq 'same-transcript' -and $globalCfg.mcpServers.local.command -eq 'shared-helper') 'Shared projects and MCP configuration remain intact'
    Assert ($globalCfg.simulatedLargeCache.Length -eq 60000) 'Switch with a large shared config preserves its cached data'
    $dirA = Join-Path (Join-Path $ctx.SessionsPath $idA) $orgA
    Assert ((Test-Path (Join-Path $dirA ($s2 + '.json')))) 'Another account local session appears in the selected Desktop registry'
    Assert ([IO.File]::ReadAllText($source) -ceq [IO.File]::ReadAllText((Join-Path $dirA ($s1 + '.json')))) 'Session record IDs and project paths are preserved exactly'
    Assert (-not (Test-Path (Join-Path $dirA 'scheduled-tasks.json'))) 'Scheduled tasks are not shared'
    Switch-ClaudeAccount $ctx Work
    $synced = Get-Content (Join-Path $dirB ($s1 + '.json')) -Raw | ConvertFrom-Json
    Assert ($synced.title -eq 'Latest title' -and $synced.futureField.nested[1] -eq 2) 'Newest session metadata and unknown fields survive synchronization'
    Assert (-not (Test-Path (Join-Path $dirB ($deleted + '.json')))) 'Destination deletion tombstone is respected'
    Assert (-not (Test-Path (Join-Path $dirB ($remote + '.json')))) 'SSH session descriptors are excluded'
    $newHashes = @($preservedFiles | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash })
    Assert (($newHashes -join ',') -ceq ($originalHashes -join ',')) 'Transcripts, Local Storage, MCP settings and Chromium key stay byte-identical'

    Set-FakeLogin $idB $orgB refreshed
    Switch-ClaudeAccount $ctx Personal
    Switch-ClaudeAccount $ctx Work
    Assert ((Get-Cookie sessionKey) -eq "fake-session-$idB-refreshed") 'Refreshed outgoing Desktop cookies are captured and restored'
    Assert ((Get-Content $ctx.ConfigPath -Raw | ConvertFrom-Json).'oauth:tokenCacheV2' -eq "opaque-encrypted-cache-$idB-refreshed") 'Refreshed outgoing Desktop OAuth cache is retained'
    $beforeFailure = [IO.File]::ReadAllText($ctx.ConfigPath)
    & $module {
        $script:originalWrite = ${function:Write-AtomicText}; $script:failPath = $null
        function script:Write-AtomicText { param([string]$Path,[string]$Text) if ($Path -eq $script:failPath) { $script:failPath=$null; throw 'Injected failure' }; & $script:originalWrite $Path $Text }
    }
    & $module { param($p) $script:failPath=$p } $ctx.ConfigPath
    Assert-Throws { Switch-ClaudeAccount $ctx Personal } '*rolled back*' 'A write failure rolls back cookies and config together'
    Assert ([IO.File]::ReadAllText($ctx.ConfigPath) -ceq $beforeFailure -and (Get-Cookie sessionKey) -eq "fake-session-$idB-refreshed") 'Rollback restores the exact previous config and Desktop login'
    Assert (-not (Test-Path $ctx.JournalPath)) 'Successful rollback clears recovery journal'

    # Simulate termination between changing cookies and writing config; next operation must roll back.
    & $module {
        param($c)
        $vault = Read-Vault $c
        $target = @($vault.Accounts | Where-Object Name -eq Personal)[0]
        $files = @(Get-AuthFileChanges $c $target)
        $journal = [pscustomobject]@{ DataDirectory=$c.DataDirectory; GlobalConfigPath=$c.GlobalConfigPath; OldCookies=@(Get-AuthCookies $c); NewCookies=@($target.Cookies); Files=$files }
        Write-AtomicText $c.JournalPath (Protect-Data $journal)
        Set-AuthCookies $c $target.Cookies
    } $ctx
    Assert ((Get-SwitcherStatus $ctx).RecoveryPending) 'Interrupted cookie/config transaction is reported'
    $changedConfig = Get-Content $ctx.ConfigPath -Raw | ConvertFrom-Json
    $changedConfig | Add-Member -NotePropertyName newerPreference -NotePropertyValue 'preserve-me'
    Write-Json $ctx.ConfigPath $changedConfig
    $changedRaw = [IO.File]::ReadAllText($ctx.ConfigPath)
    Assert-Throws { Save-SwitcherAccount $ctx Work } '*changed after an interrupted*' 'Recovery refuses to overwrite newer Desktop changes'
    Assert ([IO.File]::ReadAllText($ctx.ConfigPath) -ceq $changedRaw -and (Test-Path $ctx.JournalPath)) 'Conflicting recovery preserves newer files and encrypted backup'
    [IO.File]::WriteAllText($ctx.ConfigPath,$beforeFailure)
    Save-SwitcherAccount $ctx Work
    Assert ((Get-Cookie sessionKey) -eq "fake-session-$idB-refreshed" -and -not (Test-Path $ctx.JournalPath)) 'Next operation recovers a crash between cookie and config writes'

    Start-SwitcherLogin $ctx Third
    Assert ([IO.File]::ReadAllText($ctx.GlobalConfigPath).Contains('simulatedLargeCache')) 'Add account handles recovery backup containing a 60,000-character shared config'
    Assert ((Get-SwitcherStatus $ctx).LoginPending) 'Registration has an encrypted pending-login backup'
    Assert ($null -eq (Get-Cookie sessionKey) -and (Get-Cookie otherLogin) -eq 'keep-other-cookie') 'Registration clears only local authentication cookies'
    $cfg = Get-Content $ctx.ConfigPath -Raw | ConvertFrom-Json
    Assert (-not $cfg.PSObject.Properties['oauth:tokenCacheV2'] -and $cfg.locale -eq 'en-US') 'Registration clears only local auth fields and retains preferences'
    Assert-Throws { Switch-ClaudeAccount $ctx Personal } '*pending account registration*' 'Switch is blocked during account registration'
    Assert-Throws { Complete-SwitcherLogin $ctx } '*No Desktop account*' 'Registration cannot finish before Desktop sign-in'
    Undo-SwitcherLogin $ctx
    Assert ((Get-Cookie sessionKey) -eq "fake-session-$idB-refreshed" -and -not (Get-SwitcherStatus $ctx).LoginPending) 'Cancelled registration restores the previous account'
    Start-SwitcherLogin $ctx Third
    Set-FakeLogin $idC $orgC
    Complete-SwitcherLogin $ctx
    Assert ((Get-SwitcherStatus $ctx).Active -eq 'Third' -and (Get-SwitcherStatus $ctx).Accounts.Count -eq 3) 'New Desktop account is saved after browser sign-in'
    $dirC = Join-Path (Join-Path $ctx.SessionsPath $idC) $orgC
    Assert ((Test-Path (Join-Path $dirC ($s1 + '.json'))) -and (Test-Path (Join-Path $dirC ($s2 + '.json')))) 'Completed registration shares the existing local Code conversations'
    Assert (-not (Get-SwitcherStatus $ctx).LoginPending) 'Successful registration clears its cancellation backup'
    Switch-ClaudeAccount $ctx Personal
    Assert ((Get-Cookie sessionKey) -eq "fake-session-$idA-initial") 'Original saved account still works after another registration'
    $blob = [ClaudeSwitcher.DesktopSqlite]::Query($ctx.CookiePath,"SELECT encrypted_value FROM cookies WHERE name='sessionKey'")
    Assert ($blob[0].Cells[0].Type -eq 4 -and $blob[0].Cells[0].Value -eq 'AQAC/w==') 'Chromium encrypted cookie bytes are restored without decryption or re-encoding'

    & $module { function script:Get-ClaudeProcesses { @([pscustomobject]@{Name='Claude.exe'}) } }
    Assert-Throws { Switch-ClaudeAccount $ctx Work } '*Close Claude Desktop*' 'Running Desktop blocks credential changes'
    & $module { function script:Get-ClaudeProcesses { @() } }
    $lock = [IO.File]::Open((Join-Path $ctx.DataDirectory '.desktop-switcher.lock'),'OpenOrCreate','ReadWrite','None')
    try { Assert-Throws { Switch-ClaudeAccount $ctx Work } '*Another operation*' 'Desktop profile lock prevents simultaneous switches' } finally { $lock.Dispose() }
    $stateBefore = [IO.File]::ReadAllText($ctx.LocalStatePath)
    Write-Json $ctx.LocalStatePath @{ os_crypt=@{encrypted_key='changed-key'} }
    Assert-Throws { Switch-ClaudeAccount $ctx Work } '*encryption key changed*' 'Changed Chromium encryption key blocks old snapshots'
    [IO.File]::WriteAllText($ctx.LocalStatePath,$stateBefore)
    Remove-SwitcherAccount $ctx Third
    Assert ((Get-SwitcherStatus $ctx).Accounts.Count -eq 2 -and (Get-Cookie sessionKey) -eq "fake-session-$idA-initial") 'Removing a saved copy leaves the live login in place'
    Assert-Throws { Switch-ClaudeAccount $ctx Missing } '*No saved Desktop*' 'Unknown account fails safely'
    $wrong = New-SwitcherContext -DesktopDataDirectory (Join-Path $root 'other') -GlobalConfigPath $ctx.GlobalConfigPath -StoreDirectory $ctx.StoreDirectory
    Assert-Throws { Get-SwitcherStatus $wrong } '*different Desktop profile*' 'Vault is bound to its original Desktop profile'
    [IO.File]::WriteAllText($ctx.VaultPath,'corrupt')
    Assert-Throws { Get-SwitcherStatus $ctx } '*Cannot read encrypted*' 'Corrupt encrypted storage fails without replacing it'
    Write-Host "All $script:checks Desktop checks passed using temporary fake data only."
} finally {
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($root); $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^claude-desktop-switcher-test-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
