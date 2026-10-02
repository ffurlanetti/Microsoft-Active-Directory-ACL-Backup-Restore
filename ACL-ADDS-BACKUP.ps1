<#
.SYNOPSIS
  ACL-ADDS - Backup, Restore and Change Log of Active Directory ACLs (DACL).

.DESCRIPTION
  Interactive menu:
    1) Backup     READ-ONLY. Saves the security descriptor (SDDL) of the domain root and of
                  every OU of the chosen domain(s) to CSV files.
    2) Restore    MODIFIES AD. Restores the DACL of ONE object (domain root or OU) from a
                  backup, with a preview of what will change, an undo file and verification.
                  Inherited differences are traced to the parent OU where they were made.
    3) Change log READ-ONLY. Compares consecutive backups of a domain and shows what changed,
                  where (explicit / inherited and the parent of origin), and which restores
                  were run by this script. Optional self-contained HTML report.

  Unattended backup (scheduled task):
    .\ACL-ADDS-BACKUP.ps1 -Mode Backup -AllDomains [-Label Monthly]

  WORKFLOW (the change log depends on it):
    Backup BEFORE changing ACLs -> make the changes -> Backup AFTER -> Change log.
    The change log compares two backups; a change made after the latest backup is not shown.

  CONFIGURATION: edit the CONFIGURATION block below ($BackupFolder, $DefaultDomains and,
  optionally, $NetworkFolder).
  Full documentation: README.md

  Requires Windows PowerShell 5.1 (or PowerShell 7 on Windows) in FullLanguage mode.
  No RSAT, no ActiveDirectory module and no AD: drive are needed.

.PARAMETER WhatIfMode
  Restore shows what would be changed and writes nothing to AD.

.PARAMETER ShowFull
  Restore also prints the full CURRENT and BACKUP explicit entries.

.PARAMETER Mode
  Interactive (default) or Backup (unattended, no menus, exit code for the scheduler).

.PARAMETER AllDomains
  With -Mode Backup: $DefaultDomains + every domain of the current forest.

.PARAMETER Domain
  With -Mode Backup: specific domain(s) to back up. Can be combined with -AllDomains.

.PARAMETER Label
  Saves the backup set to a subfolder (e.g. Monthly) of $BackupFolder (and of $NetworkFolder).

.NOTES
  Project : ADDS ACL Backup & Restore (ADDS-ACL-Backup-Restore)
  Author  : Fabio Furlanetti - https://www.linkedin.com/in/fabiofurlanetti/

  Exit codes (-Mode Backup): 0 = OK, 1 = partial (a domain failed, had read errors, or the
                             network copy failed),
                             2 = failed / invalid parameters.
#>
[CmdletBinding()]
param(
    [switch]$WhatIfMode,
    [switch]$ShowFull,

    # Unattended mode (scheduled task): -Mode Backup -AllDomains -Label Monthly
    [ValidateSet('Interactive', 'Backup')]
    [string]$Mode = 'Interactive',

    # Default domains + every domain of the current forest
    [switch]$AllDomains,

    # Specific domain(s) for -Mode Backup (can be combined with -AllDomains)
    [Alias('Domain')]
    [string[]]$BackupDomain,

    # Subfolder for this backup set (e.g. Monthly): <BackupFolder>\Monthly
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')]
    [string]$Label = ''
)

# ============================================================================
#  CONFIGURATION - edit for your environment (re-sign the script after editing)
# ============================================================================

# Folder for backups, operations log, reports and transcripts.
# Protect it: the files describe the whole permission structure of your AD.
$BackupFolder = 'C:\ACL-ADDS\Backups'

# Domains (FQDN) listed in the Backup menu, used by "[A] All domains" and by -AllDomains.
# Example:
#   $DefaultDomains = @('contoso.com', 'emea.contoso.com', 'fabrikam.local')
$DefaultDomains = @()

# OPTIONAL second copy on a network share (UNC path). '' = disabled.
# Every file created (backups, undo files, reports, transcripts) is also copied there,
# and each operations log line is appended to the share's OPERATIONS_LOG.csv.
# Example:
#   $NetworkFolder = '\\fileserver.contoso.com\ADBackups\ACL'
$NetworkFolder = ''

# ============================================================================

# The script needs FullLanguage mode (AppLocker / WDAC run unapproved scripts in
# ConstrainedLanguage, where ACLs cannot be decoded or restored safely).
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Warning ("PowerShell is running in {0} mode on this machine (application control policy)." -f $ExecutionContext.SessionState.LanguageMode)
    Write-Warning 'This script needs FullLanguage to decode, compare and restore ACLs. Nothing was done.'
    exit 2
}

# ----------------------------------------------------------------------------
# Menu look & feel (visual helpers only - no effect on the script logic)
$UiWidth = 66
$BoxTL = [string][char]0x2554; $BoxTR = [string][char]0x2557
$BoxBL = [string][char]0x255A; $BoxBR = [string][char]0x255D
$BoxH  = [string][char]0x2550; $BoxV  = [string][char]0x2551
$BoxLine = [string][char]0x2500

function Format-Centered {
    param([string]$Text, [int]$Width)
    $pad  = [Math]::Max(0, $Width - $Text.Length)
    $left = [int][Math]::Floor($pad / 2)
    (' ' * $left) + $Text + (' ' * ($pad - $left))
}

function Write-Banner {
    param([string]$Title, [string]$Subtitle)
    $inner = $UiWidth - 2
    Write-Host ''
    Write-Host ($BoxTL + ($BoxH * $inner) + $BoxTR) -ForegroundColor Cyan
    Write-Host $BoxV -NoNewline -ForegroundColor Cyan
    Write-Host (Format-Centered $Title $inner) -NoNewline -ForegroundColor White
    Write-Host $BoxV -ForegroundColor Cyan
    if ($Subtitle) {
        Write-Host $BoxV -NoNewline -ForegroundColor Cyan
        Write-Host (Format-Centered $Subtitle $inner) -NoNewline -ForegroundColor Gray
        Write-Host $BoxV -ForegroundColor Cyan
    }
    Write-Host ($BoxBL + ($BoxH * $inner) + $BoxBR) -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    $fill = $BoxLine * [Math]::Max(3, ($UiWidth - $Title.Length - 6))
    Write-Host ''
    Write-Host ("  {0}{0} " -f $BoxLine) -NoNewline -ForegroundColor DarkCyan
    Write-Host $Title -NoNewline -ForegroundColor White
    Write-Host (' ' + $fill) -ForegroundColor DarkCyan
}

function Write-MenuOption {
    param(
        [string]$Key,
        [string]$Text,
        [string]$Note,
        [int]$KeyWidth = 1,
        [int]$TextWidth = 0,
        [ConsoleColor]$NoteColor = 'DarkGray'
    )
    Write-Host '   [' -NoNewline -ForegroundColor DarkGray
    Write-Host $Key.PadLeft($KeyWidth) -NoNewline -ForegroundColor Yellow
    Write-Host '] ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Text.PadRight($TextWidth) -NoNewline -ForegroundColor White
    if ($Note) { Write-Host ('  ' + $Note) -ForegroundColor $NoteColor } else { Write-Host '' }
}

function Read-Menu {
    param([string]$Text)
    Write-Host ('  > {0}: ' -f $Text) -NoNewline -ForegroundColor Green
    Read-Host
}

# ----------------------------------------------------------------------------
function Get-DomainFromDN {
    param([string]$DN)
    (($DN -split ',') | Where-Object { $_ -like 'DC=*' } | ForEach-Object { $_.Substring(3) }) -join '.'
}

# ----------------------------------------------------------------------------
# Optional second copy on the network share ($NetworkFolder)
$script:NetworkAvailable = $null   # $null = not tested yet; after a failure it is not retried in this session

function Test-NetworkFolder {
    if (-not $NetworkFolder) { return $false }
    if ($null -ne $script:NetworkAvailable) { return $script:NetworkAvailable }
    try {
        New-Item -ItemType Directory -Path $NetworkFolder -Force -ErrorAction Stop | Out-Null
        $script:NetworkAvailable = $true
    }
    catch {
        Write-Warning "Network folder unavailable ($NetworkFolder): $($_.Exception.Message)"
        Write-Warning 'Files are kept only in the local folder for this session.'
        $script:NetworkAvailable = $false
    }
    $script:NetworkAvailable
}

# Copies local files to the share. Returns 'OK', 'FAILED' or 'DISABLED' (never throws).
function Copy-ToNetwork {
    param([string[]]$Path, [string]$SubFolder = '')
    if (-not $NetworkFolder) { return 'DISABLED' }
    if (-not (Test-NetworkFolder)) { return 'FAILED' }
    $Dest = $NetworkFolder
    if ($SubFolder) {
        $Dest = Join-Path $NetworkFolder $SubFolder
        try { New-Item -ItemType Directory -Path $Dest -Force -ErrorAction Stop | Out-Null }
        catch { Write-Warning "Could not create ${Dest}: $($_.Exception.Message)"; return 'FAILED' }
    }
    $Status = 'OK'
    foreach ($p in $Path) {
        if (-not $p -or -not (Test-Path $p)) { continue }
        try { Copy-Item -Path $p -Destination $Dest -Force -ErrorAction Stop }
        catch {
            Write-Warning "Could not copy $(Split-Path $p -Leaf) to the network folder: $($_.Exception.Message)"
            $Status = 'FAILED'
        }
    }
    if ($Status -eq 'OK') { Write-Host "Network copy saved to $Dest" -ForegroundColor DarkGray }
    $Status
}

# ----------------------------------------------------------------------------
# Operations log: who ran each backup / restore (account of the session)
$OperationsLog = Join-Path $BackupFolder 'OPERATIONS_LOG.csv'

# Results of each domain backup in this run (used by the unattended mode for the exit code)
$script:BackupRuns = New-Object System.Collections.Generic.List[object]

function Get-RunAsUser {
    # DOMAIN\user of the account running the script (works with "Run as different user" too)
    try   { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
    catch { '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME }
}

function Write-OperationLog {
    param(
        [string]$Operation,
        [string]$Domain,
        [string]$Target  = '',
        [string]$File    = '',
        [string]$Result  = '',
        [string]$Details = ''
    )
    $Line = $null
    try {
        New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null
        $Line = [pscustomobject]@{
            Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Operation = $Operation
            User      = (Get-RunAsUser)
            Computer  = $env:COMPUTERNAME
            Domain    = $Domain
            Target    = $Target
            File      = $File
            Result    = $Result
            Details   = $Details
        }
        $Line | Export-Csv -Path $OperationsLog -Append -NoTypeInformation -Encoding UTF8
    }
    catch {
        Write-Warning "Could not write to the operations log: $($_.Exception.Message)"
    }

    # Same line appended to the log on the share (appended, never overwritten: other
    # machines may write there too)
    if ($Line -and (Test-NetworkFolder)) {
        try { $Line | Export-Csv -Path (Join-Path $NetworkFolder 'OPERATIONS_LOG.csv') -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop }
        catch { Write-Warning "Could not write to the network operations log: $($_.Exception.Message)" }
    }
}

function Get-OperationLog {
    # Local log + network log (if configured); the same line in both is listed once
    $Paths = @($OperationsLog)
    if ($NetworkFolder -and (Test-NetworkFolder)) { $Paths += (Join-Path $NetworkFolder 'OPERATIONS_LOG.csv') }
    $Inv  = [System.Globalization.CultureInfo]::InvariantCulture
    $Seen = @{}
    foreach ($p in $Paths) {
        if (-not (Test-Path $p)) { continue }
        foreach ($r in @(Import-Csv -Path $p)) {
            $k = '{0}|{1}|{2}|{3}|{4}|{5}' -f $r.Timestamp, $r.Operation, $r.User, $r.Computer, $r.Target, $r.File
            if ($Seen.ContainsKey($k)) { continue }
            $Seen[$k] = $true
            $When = [datetime]::MinValue
            if ([datetime]::TryParseExact($r.Timestamp, 'yyyy-MM-dd HH:mm:ss', $Inv, [System.Globalization.DateTimeStyles]::None, [ref]$When)) {
                $r | Add-Member -NotePropertyName When -NotePropertyValue $When -PassThru
            }
        }
    }
}

# ----------------------------------------------------------------------------
# Friendly names for well-known GUIDs used in delegations
$KnownGuids = @{
    '00000000-0000-0000-0000-000000000000' = '(all)'
    'bf967a0a-0de6-11d0-a285-00aa003049e2' = 'pwdLastSet'
    '00299570-246d-11d0-a768-00aa006e0529' = 'Reset Password'
    '28630ebf-41d5-11d1-a9c1-0000f80367c1' = 'lockoutTime'
    'bf967aba-0de6-11d0-a285-00aa003049e2' = 'user'
    'bf967a86-0de6-11d0-a285-00aa003049e2' = 'computer'
    'bf967a9c-0de6-11d0-a285-00aa003049e2' = 'group'
    'bf967aa5-0de6-11d0-a285-00aa003049e2' = 'organizationalUnit'
}
$SidNameCache = @{}

function Format-Guid {
    param($Guid)
    $k = ([string]$Guid).ToLower()
    if ($KnownGuids.ContainsKey($k)) { $KnownGuids[$k] } else { $k }
}

# Decodes an SDDL string into a list of readable ACEs (plus the inheritance-blocked flag)
function Get-AceList {
    param([string]$Sddl)

    $Sec = New-Object System.DirectoryServices.ActiveDirectorySecurity
    $Sec.SetSecurityDescriptorSddlForm($Sddl, [System.Security.AccessControl.AccessControlSections]::Access)

    $List = New-Object System.Collections.Generic.List[object]
    foreach ($Ace in $Sec.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        $Sid = $Ace.IdentityReference.Value
        if (-not $SidNameCache.ContainsKey($Sid)) {
            try   { $SidNameCache[$Sid] = $Ace.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value }
            catch { $SidNameCache[$Sid] = $Sid }
        }
        $List.Add([pscustomobject]@{
            Identity  = $SidNameCache[$Sid]
            Type      = [string]$Ace.AccessControlType
            Rights    = [string]$Ace.ActiveDirectoryRights
            Object    = (Format-Guid $Ace.ObjectType)
            OnClass   = (Format-Guid $Ace.InheritedObjectType)
            AppliesTo = [string]$Ace.InheritanceType
            Inherited = $Ace.IsInherited
            Key       = ('{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $Sid, $Ace.AccessControlType, $Ace.ActiveDirectoryRights, $Ace.ObjectType, $Ace.InheritedObjectType, $Ace.InheritanceType, $Ace.IsInherited)
            # Same permission regardless of inheritance flags: matches an explicit entry on a parent
            # with the inherited copy it produces on the children
            LooseKey  = ('{0}|{1}|{2}|{3}|{4}' -f $Sid, $Ace.AccessControlType, $Ace.ActiveDirectoryRights, $Ace.ObjectType, $Ace.InheritedObjectType)
        })
    }
    [pscustomobject]@{ Aces = $List; Blocked = $Sec.AreAccessRulesProtected }
}

function Show-AceTable {
    param($Aces)
    if (@($Aces).Count -eq 0) { Write-Host '  (none)'; return }
    ($Aces | Select-Object Identity, Type, Rights, Object, OnClass, AppliesTo, Inherited | Format-Table -AutoSize | Out-String -Width 250).Trim() | Write-Host
}

# ----------------------------------------------------------------------------
function Invoke-DomainBackup {
    # SetLabel = subfolder of the backup set ('' = main folder). Defaults to -Label.
    # (A separate variable is used because -Label has a validation attribute that
    #  rejects '' if the script variable itself is reassigned.)
    param([string]$Domain, [string]$SetLabel = $Label)

    $Stamp = Get-Date -Format 'yyyyMMdd_HHmm'
    $OutFolder = $BackupFolder
    if ($SetLabel) { $OutFolder = Join-Path $BackupFolder $SetLabel }
    Write-Host ''
    Write-Host "Collecting ACLs from ${Domain} ..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $OutFolder -Force | Out-Null

    # Domain root DN (e.g. emea.contoso.com -> DC=emea,DC=contoso,DC=com)
    $Base = 'DC=' + ($Domain -replace '\.', ',DC=')

    $Dns = New-Object System.Collections.Generic.List[string]
    try {
        # List the root + all OUs (LDAP query, read-only)
        $Root   = [ADSI]"LDAP://$Domain/$Base"
        $Search = New-Object System.DirectoryServices.DirectorySearcher($Root)
        $Search.Filter      = '(objectClass=organizationalUnit)'
        $Search.SearchScope = 'Subtree'
        $Search.PageSize    = 1000
        [void]$Search.PropertiesToLoad.Add('distinguishedName')

        $Dns.Add($Base)
        foreach ($r in $Search.FindAll()) { $Dns.Add([string]$r.Properties['distinguishedname'][0]) }
    }
    catch {
        Write-Warning "Could not query ${Domain}: $($_.Exception.Message)"
        Write-OperationLog -Operation 'Backup' -Domain $Domain -Result 'FAILED' -Details ($_.Exception.Message + $(if ($SetLabel) { "; label: $SetLabel" }))
        $script:BackupRuns.Add([pscustomobject]@{ Domain = $Domain; Result = 'FAILED'; Network = '-'; Objects = 0; Errors = 0 })
        return
    }

    $Acls   = New-Object System.Collections.Generic.List[object]
    $Sddls  = New-Object System.Collections.Generic.List[object]
    $Errors = New-Object System.Collections.Generic.List[object]

    foreach ($Dn in $Dns) {
        try {
            $Entry = [ADSI]"LDAP://$Domain/$Dn"
            $Sec   = $Entry.psbase.ObjectSecurity

            $Sddls.Add([pscustomobject]@{
                DN   = $Dn
                SDDL = $Sec.GetSecurityDescriptorSddlForm('Owner,Group,Access')
            })

            foreach ($Ace in $Sec.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])) {
                $Acls.Add([pscustomobject]@{
                    Object              = $Dn
                    Identity            = $Ace.IdentityReference.Value
                    Type                = $Ace.AccessControlType
                    Rights              = $Ace.ActiveDirectoryRights
                    ObjectType          = $Ace.ObjectType
                    InheritedObjectType = $Ace.InheritedObjectType
                    Inheritance         = $Ace.InheritanceType
                    IsInherited         = $Ace.IsInherited
                })
            }
        }
        catch {
            $Errors.Add([pscustomobject]@{ DN = $Dn; Error = $_.Exception.Message })
        }
    }

    $AclFile  = Join-Path $OutFolder "ACL_${Domain}_$Stamp.csv"
    $SddlFile = Join-Path $OutFolder "SDDL_${Domain}_$Stamp.csv"
    $ErrFile  = Join-Path $OutFolder "ERRORS_${Domain}_$Stamp.csv"
    $Acls  | Export-Csv $AclFile  -NoTypeInformation -Encoding UTF8
    $Sddls | Export-Csv $SddlFile -NoTypeInformation -Encoding UTF8
    $Created = @($AclFile, $SddlFile)
    if ($Errors.Count -gt 0) {
        $Errors | Export-Csv $ErrFile -NoTypeInformation -Encoding UTF8
        $Created += $ErrFile
    }
    $NetStatus = Copy-ToNetwork -Path $Created -SubFolder $SetLabel

    $BkResult = 'OK'
    if ($Errors.Count -gt 0) { $BkResult = 'OK WITH ERRORS' }
    $SetLabelNote = ''
    if ($SetLabel) { $SetLabelNote = "; label: $SetLabel" }
    Write-OperationLog -Operation 'Backup' -Domain $Domain -File "SDDL_${Domain}_$Stamp.csv" -Result $BkResult `
        -Details ('{0} objects read, {1} with errors; network copy: {2}{3}' -f $Sddls.Count, $Errors.Count, $NetStatus, $SetLabelNote)
    $script:BackupRuns.Add([pscustomobject]@{ Domain = $Domain; Result = $BkResult; Network = $NetStatus; Objects = $Sddls.Count; Errors = $Errors.Count })

    Write-Host ("{0}: {1} objects read (root + OUs), {2} with errors." -f $Domain, $Sddls.Count, $Errors.Count) -ForegroundColor Green
    Write-Host "Files saved to $OutFolder (suffix $Stamp)"

    # Workflow reminder: the change log compares two backups (before / after the change)
    if ($Mode -eq 'Interactive') {
        $Previous = @(Get-ChildItem -Path $OutFolder -Filter "SDDL_${Domain}_*.csv" -File -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -ne "SDDL_${Domain}_$Stamp.csv" } | Sort-Object Name -Descending)
        Write-Host ''
        if ($Previous.Count -eq 0) {
            Write-Host "[!] This is the FIRST backup of $Domain in this set." -ForegroundColor Yellow
            Write-Host '    After you change ACLs, run Backup again: the Change log compares two backups' -ForegroundColor Yellow
            Write-Host '    (before / after) and cannot show changes without the second one.' -ForegroundColor Yellow
        }
        else {
            Write-Host ("[i] Previous backup of {0}: {1}. The Change log can now compare it with this one." -f $Domain, $Previous[0].Name) -ForegroundColor Cyan
            Write-Host '    Making ACL changes now? Run Backup again AFTER them to record the new state.' -ForegroundColor Cyan
        }
    }
}

# ----------------------------------------------------------------------------
function Invoke-Backup {
    while ($true) {
        Write-Section 'Backup - select the domain'
        if ($DefaultDomains.Count -eq 0) {
            Write-Host '   No domains configured. Edit $DefaultDomains in the CONFIGURATION block' -ForegroundColor Yellow
            Write-Host '   of the script, or use [C] to type a domain now.' -ForegroundColor Yellow
        }
        for ($i = 0; $i -lt $DefaultDomains.Count; $i++) { Write-MenuOption -Key ($i + 1) -Text $DefaultDomains[$i] }
        if ($DefaultDomains.Count -gt 0) { Write-MenuOption -Key 'A' -Text 'All domains' }
        Write-MenuOption -Key 'C' -Text 'Custom domain'
        Write-MenuOption -Key '0' -Text 'Back'
        Write-Host ''
        $Choice = (Read-Menu 'Select an option').Trim()

        if ($Choice -eq '0') { return }
        if ($Choice -match '^[aA]$' -and $DefaultDomains.Count -gt 0) {
            foreach ($d in $DefaultDomains) { Invoke-DomainBackup -Domain $d }
            return
        }
        if ($Choice -match '^[cC]$') {
            $Custom = (Read-Menu 'Enter the domain FQDN (e.g. contoso.com)').Trim()
            if ($Custom) { Invoke-DomainBackup -Domain $Custom; return }
            continue
        }
        if ($Choice -match '^\d+$' -and [int]$Choice -ge 1 -and [int]$Choice -le $DefaultDomains.Count) {
            Invoke-DomainBackup -Domain $DefaultDomains[[int]$Choice - 1]
            return
        }
        Write-Warning 'Invalid option.'
    }
}

# ----------------------------------------------------------------------------
# Backup sets: the main folder (regular backups) and each labeled subfolder created
# with -Label (e.g. Monthly). The chosen set is used by Restore and Change log.
function Get-BackupSets {
    $Sets = New-Object System.Collections.Generic.List[object]
    $Sets.Add([pscustomobject]@{ Name = 'Default'; Path = $BackupFolder; Label = '' })
    if (Test-Path $BackupFolder) {
        foreach ($d in @(Get-ChildItem -Path $BackupFolder -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if (@(Get-ChildItem -Path $d.FullName -Filter 'SDDL_*.csv' -File -ErrorAction SilentlyContinue).Count -gt 0) {
                $Sets.Add([pscustomobject]@{ Name = $d.Name; Path = $d.FullName; Label = $d.Name })
            }
        }
    }
    # Network copy (listed after the local sets: local has priority)
    if ($NetworkFolder -and (Test-NetworkFolder)) {
        $Sets.Add([pscustomobject]@{ Name = 'Network'; Path = $NetworkFolder; Label = '' })
        foreach ($d in @(Get-ChildItem -Path $NetworkFolder -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if (@(Get-ChildItem -Path $d.FullName -Filter 'SDDL_*.csv' -File -ErrorAction SilentlyContinue).Count -gt 0) {
                $Sets.Add([pscustomobject]@{ Name = "Network\$($d.Name)"; Path = $d.FullName; Label = $d.Name })
            }
        }
    }
    $Sets
}

function Select-BackupSource {
    param([string]$Purpose)
    $Sets = @(Get-BackupSets)
    if ($Sets.Count -eq 1) { return $Sets[0] }
    Write-Section "$Purpose - backup set"
    $Width = ($Sets | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    for ($i = 0; $i -lt $Sets.Count; $i++) { Write-MenuOption -Key ($i + 1) -Text $Sets[$i].Name -TextWidth $Width -Note $Sets[$i].Path }
    Write-MenuOption -Key '0' -Text 'Back'
    Write-Host ''
    $c = (Read-Menu 'Select the backup set (ENTER = 1 Default)').Trim()
    if (-not $c) { return $Sets[0] }
    if ($c -eq '0') { return $null }
    if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $Sets.Count) { return $Sets[[int]$c - 1] }
    Write-Warning 'Invalid option.'
    $null
}

# SDDL_*.csv files of the chosen set. Each item: Name, FullName, LastWriteTime, Origin
function Get-SnapshotFiles {
    param($Source)
    if (-not (Test-Path $Source.Path)) { Write-Warning "Folder not found: $($Source.Path)"; return }
    foreach ($i in @(Get-ChildItem -Path $Source.Path -Filter 'SDDL_*.csv' -File -ErrorAction SilentlyContinue)) {
        [pscustomobject]@{ Name = $i.Name; FullName = $i.FullName; LastWriteTime = $i.LastWriteTime; Origin = $Source.Name }
    }
}

# ----------------------------------------------------------------------------
# Parent chain of a DN up to the root of ITS domain, nearest first.
#   OU=Workstations,OU=Sites,DC=emea,DC=contoso,DC=com ->
#     OU=Sites,DC=emea,DC=contoso,DC=com
#     DC=emea,DC=contoso,DC=com
function Get-AncestorDNs {
    param([string]$DN)
    $Parts = [regex]::Split($DN, '(?<!\\),')          # keeps escaped commas (\,) inside names
    if ($Parts[0] -like 'DC=*') { return }              # already the domain root
    for ($i = 1; $i -lt $Parts.Count; $i++) {
        $Parts[$i..($Parts.Count - 1)] -join ','
        if ($Parts[$i] -like 'DC=*') { return }         # stop at the root of THIS domain
    }
}

function Get-CurrentDacl {
    param([string]$Domain, [string]$DN)
    $Entry = [ADSI]"LDAP://$Domain/$DN"
    $Entry.psbase.Options.SecurityMasks = [System.DirectoryServices.SecurityMasks]::Dacl
    $Entry.psbase.ObjectSecurity.GetSecurityDescriptorSddlForm('Access')
}

# CURRENT vs BACKUP, split into explicit and inherited differences
function Compare-Dacl {
    param([string]$Current, [string]$Backup)
    $Cur = Get-AceList -Sddl $Current
    $Bak = Get-AceList -Sddl $Backup
    $CurKeys = @{}; foreach ($a in $Cur.Aces) { $CurKeys[$a.Key] = $true }
    $BakKeys = @{}; foreach ($a in $Bak.Aces) { $BakKeys[$a.Key] = $true }
    $ToRemove = @($Cur.Aces | Where-Object { -not $BakKeys.ContainsKey($_.Key) })
    $ToAdd    = @($Bak.Aces | Where-Object { -not $CurKeys.ContainsKey($_.Key) })
    [pscustomobject]@{
        Cur       = $Cur
        Bak       = $Bak
        ToRemove  = $ToRemove
        ToAdd     = $ToAdd
        Same      = $Cur.Aces.Count - $ToRemove.Count
        ExpRemove = @($ToRemove | Where-Object { -not $_.Inherited })
        ExpAdd    = @($ToAdd    | Where-Object { -not $_.Inherited })
        InhRemove = @($ToRemove | Where-Object { $_.Inherited })
        InhAdd    = @($ToAdd    | Where-Object { $_.Inherited })
    }
}

# Walks UP the OU chain looking for where the inherited differences were originally made:
# a parent whose EXPLICIT entries changed the same way (same identity/type/rights/object),
# or whose "inheritance blocked" flag changed. Returns the matches, nearest first.
function Find-ChangeOrigin {
    param([string]$DN, [string]$Domain, $RowIndex, $Diff)
    foreach ($Anc in @(Get-AncestorDNs -DN $DN)) {
        if (-not $RowIndex.ContainsKey($Anc)) { continue }   # e.g. a CN= container (not in the backup)
        try   { $CurA = Get-CurrentDacl -Domain $Domain -DN $Anc }
        catch { Write-Warning "Could not read ${Anc}: $($_.Exception.Message)"; continue }
        $BakA = [regex]::Match($RowIndex[$Anc].SDDL, 'D:.*$').Value
        if ($CurA -eq $BakA) { continue }

        $c = Compare-Dacl -Current $CurA -Backup $BakA
        $RemKeys = @{}; foreach ($a in $c.ExpRemove) { $RemKeys[$a.LooseKey] = $true }
        $AddKeys = @{}; foreach ($a in $c.ExpAdd)    { $AddKeys[$a.LooseKey] = $true }
        $Explained = @($Diff.InhRemove | Where-Object { $RemKeys.ContainsKey($_.LooseKey) }) +
                     @($Diff.InhAdd    | Where-Object { $AddKeys.ContainsKey($_.LooseKey) })
        $BlockedChanged = ($c.Cur.Blocked -ne $c.Bak.Blocked)

        if ($Explained.Count -gt 0 -or $BlockedChanged) {
            [pscustomobject]@{ DN = $Anc; Row = $RowIndex[$Anc]; Diff = $c; Explained = $Explained; BlockedChanged = $BlockedChanged }
        }
    }
}

# ----------------------------------------------------------------------------
function Invoke-OuRestore {
    param($Item, $RowIndex, $File, [string]$RequestedFrom = '')

    $Domain = Get-DomainFromDN -DN $Item.DN
    try   { $Current = Get-CurrentDacl -Domain $Domain -DN $Item.DN }
    catch { Write-Warning "Could not read the current OU: $($_.Exception.Message)"; return }
    $Backup = [regex]::Match($Item.SDDL, 'D:.*$').Value

    Write-Host ''
    Write-Host "OU     : $($Item.DN)"
    Write-Host "Domain : $Domain"
    Write-Host ("Backup : {0}  [{1}]" -f $File.Name, $File.Origin)
    if ($RequestedFrom) { Write-Host "Reason : origin of the inherited differences found in $RequestedFrom" -ForegroundColor Magenta }

    if ($Current -eq $Backup) {
        Write-Host 'The current DACL is already identical to the backup. Nothing to do.' -ForegroundColor Green
        return
    }
    Write-Host 'The current DACL DIFFERS from the backup.' -ForegroundColor Yellow

    $Diff = $null
    try {
        $Diff = Compare-Dacl -Current $Current -Backup $Backup

        if ($ShowFull) {
            $CurExplicit = @($Diff.Cur.Aces | Where-Object { -not $_.Inherited })
            $BakExplicit = @($Diff.Bak.Aces | Where-Object { -not $_.Inherited })
            Write-Host ''
            Write-Host ("=== CURRENT (in AD now): {0} explicit entries (+{1} inherited, not shown) | inheritance blocked: {2}" -f $CurExplicit.Count, ($Diff.Cur.Aces.Count - $CurExplicit.Count), $Diff.Cur.Blocked) -ForegroundColor Cyan
            Show-AceTable -Aces $CurExplicit
            Write-Host ''
            Write-Host ("=== BACKUP (will be applied): {0} explicit entries (+{1} inherited, not shown) | inheritance blocked: {2}" -f $BakExplicit.Count, ($Diff.Bak.Aces.Count - $BakExplicit.Count), $Diff.Bak.Blocked) -ForegroundColor Cyan
            Show-AceTable -Aces $BakExplicit
        }

        Write-Host ''
        Write-Host "=== WHAT THE RESTORE WILL CHANGE in $($Item.DN) ===" -ForegroundColor Yellow
        Write-Host ("[-] REMOVED explicit (in current, not in backup): {0}" -f $Diff.ExpRemove.Count) -ForegroundColor Red
        Show-AceTable -Aces $Diff.ExpRemove
        Write-Host ("[+] ADDED explicit (in backup, not in current): {0}" -f $Diff.ExpAdd.Count) -ForegroundColor Green
        Show-AceTable -Aces $Diff.ExpAdd
        Write-Host ("[=] Unchanged: {0}" -f $Diff.Same)
        if ($Diff.Cur.Blocked -ne $Diff.Bak.Blocked) {
            Write-Host ("[!] Inheritance blocked flag changes: {0} -> {1}" -f $Diff.Cur.Blocked, $Diff.Bak.Blocked) -ForegroundColor Yellow
        }
        if (($Diff.InhRemove.Count + $Diff.InhAdd.Count) -gt 0) {
            Write-Host ''
            Write-Host ("[~] INHERITED differences: {0} only in current, {1} only in backup" -f $Diff.InhRemove.Count, $Diff.InhAdd.Count) -ForegroundColor Magenta
            Write-Host '    These come from a parent and are NOT changed by restoring this OU (AD rebuilds them from the parent).' -ForegroundColor Magenta
            if ($Diff.InhRemove.Count -gt 0) { Write-Host '    Only in current:' -ForegroundColor Red;   Show-AceTable -Aces $Diff.InhRemove }
            if ($Diff.InhAdd.Count -gt 0)    { Write-Host '    Only in backup:'  -ForegroundColor Green; Show-AceTable -Aces $Diff.InhAdd }
        }
    }
    catch {
        Write-Warning "Could not decode the ACEs ($($_.Exception.Message)). Showing the raw SDDL instead."
        Write-Host "CURRENT : $Current"
        Write-Host "BACKUP  : $Backup"
    }

    # Inherited differences -> find where the change was originally made and offer to restore there
    if ($Diff -and ($Diff.InhRemove.Count + $Diff.InhAdd.Count) -gt 0) {
        Write-Section 'Origin of the inherited differences'
        $Origins = @(Find-ChangeOrigin -DN $Item.DN -Domain $Domain -RowIndex $RowIndex -Diff $Diff)

        $ExplainedKeys = @{}
        foreach ($o in $Origins) { foreach ($a in $o.Explained) { $ExplainedKeys[$a.Key] = $true } }
        $Unexplained = @(@($Diff.InhRemove) + @($Diff.InhAdd) | Where-Object { -not $ExplainedKeys.ContainsKey($_.Key) })

        if ($Origins.Count -eq 0) {
            Write-Warning 'No parent OU in this backup explains the inherited differences.'
            Write-Host '   Possible causes: the change was made in a CN= container (not in the backup), it was already' -ForegroundColor DarkGray
            Write-Host '   reverted in the parent, or the backup is from a different point in time than the parent change.' -ForegroundColor DarkGray
        }
        else {
            for ($i = 0; $i -lt $Origins.Count; $i++) {
                $o   = $Origins[$i]
                $Tag = ''
                if ($i -eq $Origins.Count - 1) { $Tag = '  <- topmost (recommended)' }
                Write-Host ''
                Write-Host ('   [{0}] {1}{2}' -f ($i + 1), $o.DN, $Tag) -ForegroundColor Yellow
                Write-Host ('       explains {0} of the {1} inherited difference(s) of this OU' -f $o.Explained.Count, ($Diff.InhRemove.Count + $Diff.InhAdd.Count))
                Write-Host ('       explicit entries changed there: -{0} +{1} (restoring it reverts ALL of them)' -f $o.Diff.ExpRemove.Count, $o.Diff.ExpAdd.Count)
                if ($o.BlockedChanged) {
                    Write-Host ('       [!] inheritance blocked flag changed there: {0} -> {1}' -f $o.Diff.Bak.Blocked, $o.Diff.Cur.Blocked) -ForegroundColor Yellow
                }
            }
        }
        if ($Unexplained.Count -gt 0 -and $Origins.Count -gt 0) {
            Write-Warning ('{0} inherited difference(s) could not be traced to a parent in this backup.' -f $Unexplained.Count)
        }

        $HasExplicit = (($Diff.ExpRemove.Count + $Diff.ExpAdd.Count) -gt 0) -or ($Diff.Cur.Blocked -ne $Diff.Bak.Blocked)

        Write-Section 'What do you want to restore?'
        for ($i = 0; $i -lt $Origins.Count; $i++) {
            Write-MenuOption -Key ($i + 1) -Text ('Restore the origin: ' + $Origins[$i].DN)
        }
        if ($HasExplicit) {
            Write-MenuOption -Key 'T' -Text 'Restore only THIS OU' -Note '(explicit entries only - inherited ones stay as they are)'
        }
        Write-MenuOption -Key '0' -Text 'Cancel'
        Write-Host ''
        $Pick = (Read-Menu 'Select an option').Trim()

        if ($Pick -match '^\d+$' -and [int]$Pick -ge 1 -and [int]$Pick -le $Origins.Count) {
            Invoke-OuRestore -Item $Origins[[int]$Pick - 1].Row -RowIndex $RowIndex -File $File -RequestedFrom $Item.DN
            return
        }
        if (-not ($HasExplicit -and $Pick -match '^[tT]$')) {
            if (-not $HasExplicit -and $Pick -match '^[tT]$') { Write-Host 'This OU has no explicit differences - restoring it would change nothing.' }
            Write-Host 'Canceled. Nothing was changed.'
            return
        }
    }

    if ($WhatIfMode) {
        Write-Host '[WHAT-IF] Nothing was written. Without -WhatIfMode, the backup DACL would be applied.' -ForegroundColor Yellow
        return
    }

    $Answer = Read-Menu "Confirm the restore of $($Item.DN)? (Y/N)"
    if ($Answer -notmatch '^[yY]') { Write-Host 'Canceled. Nothing was changed.'; return }

    # Save the current state, restore and verify
    $Reason = ''
    if ($RequestedFrom) { $Reason = "; origin of inherited changes in $RequestedFrom" }
    try {
        $OuName = ($Item.DN -replace '[^\w\-]', '_')
        if ($OuName.Length -gt 100) { $OuName = $OuName.Substring(0, 100) }
        $BeforeFile = Join-Path $BackupFolder ("BEFORE_RESTORE_{0}_{1}.txt" -f $OuName, (Get-Date -Format 'yyyyMMdd_HHmm'))
        New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null
        $Current | Out-File -FilePath $BeforeFile -Encoding UTF8
        Write-Host "Current state saved to: $BeforeFile"
        $NetStatus = Copy-ToNetwork -Path $BeforeFile   # undo file on the share BEFORE touching AD

        $Entry = [ADSI]"LDAP://$Domain/$($Item.DN)"
        $Entry.psbase.Options.SecurityMasks = [System.DirectoryServices.SecurityMasks]::Dacl
        $Sec = $Entry.psbase.ObjectSecurity
        $Sec.SetSecurityDescriptorSddlForm($Item.SDDL, [System.Security.AccessControl.AccessControlSections]::Access)
        $Entry.psbase.ObjectSecurity = $Sec
        $Entry.psbase.CommitChanges()

        $After      = Get-CurrentDacl -Domain $Domain -DN $Item.DN
        $BeforeName = Split-Path $BeforeFile -Leaf
        $Details    = "Undo file: $BeforeName; backup set: $($File.Origin); network copy: $NetStatus$Reason"

        $Result = 'WRITTEN - DIFFERS FROM BACKUP'
        if ($After -eq $Backup) {
            $Result = 'OK'
            Write-Host 'OK - DACL restored and verified against the backup.' -ForegroundColor Green
        }
        else {
            $ExplicitOk = $false
            try {
                $v = Compare-Dacl -Current $After -Backup $Backup
                $ExplicitOk = (($v.ExpRemove.Count + $v.ExpAdd.Count) -eq 0) -and ($v.Cur.Blocked -eq $v.Bak.Blocked)
            } catch { }
            if ($ExplicitOk) {
                $Result = 'OK - INHERITED DIFFER'
                Write-Host 'OK - explicit entries restored. Remaining differences are INHERITED (they come from a parent).' -ForegroundColor Green
            }
            else {
                Write-Warning 'DACL was written but differs from the backup. Please verify manually.'
            }
        }
        if ($RequestedFrom) {
            Write-Host "Child OUs (like $RequestedFrom) receive the change by inheritance. AD propagation can take" -ForegroundColor DarkGray
            Write-Host 'a few minutes - run Restore with -WhatIfMode on the child later to confirm.' -ForegroundColor DarkGray
        }
        Write-OperationLog -Operation 'Restore' -Domain $Domain -Target $Item.DN -File $File.Name -Result $Result -Details $Details
        Write-Host "Logged in $OperationsLog as $(Get-RunAsUser)" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host "[!] Run Backup of $Domain now so the Change log records the state AFTER this restore." -ForegroundColor Yellow
    }
    catch {
        Write-Warning "Restore failed: $($_.Exception.Message)"
        Write-Warning 'Check that the account is allowed to change permissions on this OU.'
        Write-OperationLog -Operation 'Restore' -Domain $Domain -Target $Item.DN -File $File.Name -Result 'FAILED' -Details ($_.Exception.Message + $Reason)
    }
}

# ----------------------------------------------------------------------------
function Invoke-Restore {
    # 1) Pick the source and the SDDL file
    $Source = Select-BackupSource -Purpose 'Restore'
    if (-not $Source) { return }

    $Files = @(Get-SnapshotFiles -Source $Source | Sort-Object LastWriteTime -Descending)
    if ($Files.Count -eq 0) {
        Write-Warning "No SDDL_*.csv files found in the selected backup set ($($Source.Name))."
        return
    }

    Write-Section "Restore - available SDDL files (newest first) - set: $($Source.Name)"
    $KeyWidth  = "$($Files.Count)".Length
    $TextWidth = ($Files | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    for ($i = 0; $i -lt $Files.Count; $i++) {
        Write-MenuOption -Key ($i + 1) -KeyWidth $KeyWidth -Text $Files[$i].Name -TextWidth $TextWidth -Note ('{0:yyyy-MM-dd HH:mm}  [{1}]' -f $Files[$i].LastWriteTime, $Files[$i].Origin)
    }
    Write-Host ''
    $Number = (Read-Menu 'File number (press ENTER to cancel)').Trim()
    if (-not $Number) { Write-Host 'Canceled.'; return }
    if ($Number -notmatch '^\d+$' -or [int]$Number -lt 1 -or [int]$Number -gt $Files.Count) { Write-Warning 'Invalid option.'; return }
    $File = $Files[[int]$Number - 1]

    # 2) Import the file
    $Rows = @(Import-Csv -Path $File.FullName)
    if ($Rows.Count -eq 0 -or -not ($Rows[0].PSObject.Properties.Name -contains 'DN') -or -not ($Rows[0].PSObject.Properties.Name -contains 'SDDL')) {
        Write-Warning 'Invalid file: the CSV must have the DN and SDDL columns.'
        return
    }
    $RowIndex = @{}; foreach ($r in $Rows) { $RowIndex[$r.DN] = $r }

    $Sorted = @($Rows | Sort-Object DN)
    $View   = $Sorted

    # 3) Pick the OU by number (typing text filters the list)
    $Item = $null
    while (-not $Item) {
        Write-Section "Restore - OUs available in $($File.Name)"
        $OuKeyWidth = "$($View.Count)".Length
        for ($i = 0; $i -lt $View.Count; $i++) { Write-MenuOption -Key ($i + 1) -KeyWidth $OuKeyWidth -Text $View[$i].DN }
        Write-Host ''

        $Selection = (Read-Menu 'Enter the OU number (or text to filter the list; press ENTER to cancel)').Trim()
        if (-not $Selection) { Write-Host 'Canceled.'; return }

        if ($Selection -match '^\d+$') {
            if ([int]$Selection -ge 1 -and [int]$Selection -le $View.Count) { $Item = $View[[int]$Selection - 1] }
            else { Write-Warning 'Invalid number.' }
            continue
        }

        $Filtered = @($Sorted | Where-Object { $_.DN.IndexOf($Selection, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($Filtered.Count -eq 0) { Write-Warning 'No OU matches that text.'; $View = $Sorted }
        else { $View = $Filtered }
    }

    # 4) Compare, trace inherited changes to their origin, restore
    Invoke-OuRestore -Item $Item -RowIndex $RowIndex -File $File
}

# ----------------------------------------------------------------------------
function Format-AceLine {
    param($Ace)
    $Target = $Ace.Object
    if ($Ace.OnClass -and $Ace.OnClass -ne '(all)') { $Target = '{0} on {1}' -f $Ace.Object, $Ace.OnClass }
    $Line = '{0,-5} {1} | {2} | {3} | {4}' -f $Ace.Type, $Ace.Identity, $Ace.Rights, $Target, $Ace.AppliesTo
    if ($Ace.Inherited) { $Line += ' (inherited)' }
    $Line
}

# Compares two SDDL snapshots of the same domain and prints the OUs that changed
function Get-BackupAuthor {
    param($OpLog, [string]$FileName)
    $e = @($OpLog | Where-Object { $_.Operation -eq 'Backup' -and $_.File -eq $FileName }) | Select-Object -Last 1
    if ($e) { '{0} on {1}' -f $e.User, $e.Computer } else { '(unknown - not in operations log)' }
}

function Show-SnapshotChanges {
    param($Old, $New, $OpLog = @())

    # Restores done by this script between the two backups (same domain)
    $Restores = @($OpLog | Where-Object {
        $_.Operation -eq 'Restore' -and $_.Domain -eq $New.Domain -and $_.When -gt $Old.When -and $_.When -le $New.When
    } | Sort-Object When)

    $OldMap = @{}; foreach ($r in @(Import-Csv -Path $Old.File.FullName)) { $OldMap[$r.DN] = $r.SDDL }
    $NewMap = @{}; foreach ($r in @(Import-Csv -Path $New.File.FullName)) { $NewMap[$r.DN] = $r.SDDL }

    $Changed    = New-Object System.Collections.Generic.List[object]
    $NewOus     = New-Object System.Collections.Generic.List[string]
    $RemovedOus = New-Object System.Collections.Generic.List[string]

    foreach ($Dn in ($NewMap.Keys | Sort-Object)) {
        if (-not $OldMap.ContainsKey($Dn)) { $NewOus.Add($Dn); continue }

        $OldDacl = [regex]::Match($OldMap[$Dn], 'D:.*$').Value
        $NewDacl = [regex]::Match($NewMap[$Dn], 'D:.*$').Value
        if ($OldDacl -eq $NewDacl) { continue }

        try {
            $A = Get-AceList -Sddl $OldDacl
            $B = Get-AceList -Sddl $NewDacl
            $AKeys = @{}; foreach ($x in $A.Aces) { $AKeys[$x.Key] = $true }
            $BKeys = @{}; foreach ($x in $B.Aces) { $BKeys[$x.Key] = $true }
            $Removed = @($A.Aces | Where-Object { -not $BKeys.ContainsKey($_.Key) })
            $Added   = @($B.Aces | Where-Object { -not $AKeys.ContainsKey($_.Key) })

            if ($Removed.Count -gt 0 -or $Added.Count -gt 0 -or $A.Blocked -ne $B.Blocked) {
                $Changed.Add([pscustomobject]@{ DN = $Dn; Removed = $Removed; Added = $Added; BlockedOld = $A.Blocked; BlockedNew = $B.Blocked; Note = '' })
            }
        }
        catch {
            $Changed.Add([pscustomobject]@{ DN = $Dn; Removed = @(); Added = @(); BlockedOld = $null; BlockedNew = $null; Note = ('DACL changed (could not decode the entries: {0})' -f $_.Exception.Message) })
        }
    }
    foreach ($Dn in ($OldMap.Keys | Sort-Object)) { if (-not $NewMap.ContainsKey($Dn)) { $RemovedOus.Add($Dn) } }
    $ByDn = @{}; foreach ($c in $Changed) { $ByDn[$c.DN] = $c }

    # Per OU: restores done on it, and where its inherited changes came from
    foreach ($c in $Changed) {
        $Dn = $c.DN
        $c | Add-Member -NotePropertyName Restores -NotePropertyValue @($Restores | Where-Object { $_.Target -eq $Dn })
        $Inh = @(@($c.Removed) + @($c.Added) | Where-Object { $_.Inherited })
        $Origin = $null
        if ($Inh.Count -gt 0) {
            foreach ($Anc in @(Get-AncestorDNs -DN $c.DN)) {
                if (-not $ByDn.ContainsKey($Anc)) { continue }
                $p = $ByDn[$Anc]
                $RemK = @{}; foreach ($x in @($p.Removed | Where-Object { -not $_.Inherited })) { $RemK[$x.LooseKey] = $true }
                $AddK = @{}; foreach ($x in @($p.Added   | Where-Object { -not $_.Inherited })) { $AddK[$x.LooseKey] = $true }
                $Hits = @($c.Removed | Where-Object { $_.Inherited -and $RemK.ContainsKey($_.LooseKey) }).Count +
                        @($c.Added   | Where-Object { $_.Inherited -and $AddK.ContainsKey($_.LooseKey) }).Count
                if ($Hits -gt 0) { $Origin = $Anc }   # keep going up: the topmost match is the origin
            }
        }
        $c | Add-Member -NotePropertyName InheritedCount -NotePropertyValue $Inh.Count
        $c | Add-Member -NotePropertyName Origin -NotePropertyValue $Origin
    }

    $OldAuthor = Get-BackupAuthor -OpLog $OpLog -FileName $Old.File.Name
    $NewAuthor = Get-BackupAuthor -OpLog $OpLog -FileName $New.File.Name
    $HasChanges = ($Changed.Count + $NewOus.Count + $RemovedOus.Count) -gt 0
    # Windows PowerShell 5.1 fails ("Argument types do not match") when @(<generic List>) is used
    # inside a [pscustomobject]@{...} literal, so the values are converted to arrays first.
    $Props = [ordered]@{}
    $Props['OldWhen']    = $Old.When
    $Props['NewWhen']    = $New.When
    $Props['OldFile']    = [string]$Old.File.Name
    $Props['NewFile']    = [string]$New.File.Name
    $Props['OldAuthor']  = [string]$OldAuthor
    $Props['NewAuthor']  = [string]$NewAuthor
    $Props['Restores']   = [object[]]$Restores
    $Props['Changed']    = [object[]]$Changed.ToArray()
    $Props['NewOus']     = [string[]]$NewOus.ToArray()
    $Props['RemovedOus'] = [string[]]$RemovedOus.ToArray()
    $Props['HasChanges'] = [bool]$HasChanges
    $Result = New-Object -TypeName PSObject -Property $Props

    Write-Section ('{0:yyyy-MM-dd HH:mm}  >>  {1:yyyy-MM-dd HH:mm}' -f $Old.When, $New.When)
    Write-Host ('   {0}  >>  {1}' -f $Old.File.Name, $New.File.Name) -ForegroundColor DarkGray
    Write-Host ('   Backups run by: {0}  >>  {1}' -f $OldAuthor, $NewAuthor) -ForegroundColor DarkGray

    if ($Restores.Count -gt 0) {
        Write-Host ('   Restores executed by this script in this period: {0}' -f $Restores.Count) -ForegroundColor Magenta
        foreach ($r in $Restores) {
            Write-Host ('     [R] {0:yyyy-MM-dd HH:mm:ss}  {1}  {2}  ({3})' -f $r.When, $r.User, $r.Target, $r.Result) -ForegroundColor Magenta
        }
    }

    if ($Changed.Count -eq 0 -and $NewOus.Count -eq 0 -and $RemovedOus.Count -eq 0) {
        Write-Host '   No permission changes detected between these two backups.' -ForegroundColor Green
        return $Result
    }
    Write-Host ('   {0} OU(s) with changed permissions, {1} new OU(s), {2} OU(s) no longer present' -f $Changed.Count, $NewOus.Count, $RemovedOus.Count) -ForegroundColor White

    foreach ($c in $Changed) {
        Write-Host ''
        Write-Host ('   [~] ' + $c.DN) -ForegroundColor Yellow
        if ($c.Note) { Write-Host ('        ' + $c.Note) -ForegroundColor DarkGray }
        foreach ($r in @($c.Restores)) {
            Write-Host ('        [R] Restored by {0} at {1:yyyy-MM-dd HH:mm:ss} from {2} ({3})' -f $r.User, $r.When, $r.File, $r.Result) -ForegroundColor Magenta
        }
        foreach ($a in $c.Removed) { Write-Host ('        [-] ' + (Format-AceLine -Ace $a)) -ForegroundColor Red }
        foreach ($a in $c.Added)   { Write-Host ('        [+] ' + (Format-AceLine -Ace $a)) -ForegroundColor Green }

        if ($c.InheritedCount -gt 0) {
            if ($c.Origin) { Write-Host ('        [^] {0} inherited change(s) - originated in: {1}' -f $c.InheritedCount, $c.Origin) -ForegroundColor Cyan }
            else           { Write-Host ('        [^] {0} inherited change(s) - origin not found in this backup' -f $c.InheritedCount) -ForegroundColor DarkGray }
        }
        if ($null -ne $c.BlockedOld -and $c.BlockedOld -ne $c.BlockedNew) {
            Write-Host ('        [!] Inheritance blocked: {0} -> {1}' -f $c.BlockedOld, $c.BlockedNew) -ForegroundColor Yellow
        }
    }
    foreach ($Dn in $NewOus)     { Write-Host ''; Write-Host ('   [+] OU present only in the newer backup: ' + $Dn) -ForegroundColor Green }
    foreach ($Dn in $RemovedOus) { Write-Host ''; Write-Host ('   [-] OU present only in the older backup: ' + $Dn) -ForegroundColor Red }
    $Result
}

# ----------------------------------------------------------------------------
# HTML report of the change log (self-contained file: no internet, no external scripts)
function Test-SensitiveAce {
    # Rights that allow taking control of the object (or replicating secrets)
    param($Ace)
    if ($Ace.Type -ne 'Allow') { return $false }
    if ($Ace.Rights -match 'GenericAll|WriteDacl|WriteOwner|GenericWrite') { return $true }
    if ($Ace.Rights -match 'ExtendedRight' -and ($Ace.Object -eq '(all)' -or $Ace.Object -match 'Replicat|Password')) { return $true }
    $false
}

function Export-ChangeLogHtml {
    param([string]$Domain, [string]$Source, $Results)

    function Enc { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }

    function AceRow {
        param($Ace, [string]$Change)
        $Cls = 'add'; $Sign = '+'
        if ($Change -eq '-') { $Cls = 'rem'; $Sign = '&minus;' }
        $Tags = ''
        if ($Ace.Type -eq 'Deny')                    { $Tags += '<span class="tag deny">Deny</span> ' }
        if ($Change -eq '+' -and (Test-SensitiveAce $Ace)) { $Tags += '<span class="tag risk">sensitive right</span> ' }
        $Obj = $Ace.Object
        if ($Ace.OnClass -and $Ace.OnClass -ne '(all)') { $Obj = '{0} on {1}' -f $Ace.Object, $Ace.OnClass }
        $Inh = 'explicit'
        if ($Ace.Inherited) { $Inh = '<span class="tag inh">inherited</span>' }
        $TypeText = Enc $Ace.Type
        if ($Ace.Type -eq 'Deny') { $TypeText = '' }   # already shown by the Deny tag
        '<tr class="{0}"><td class="sign">{1}</td><td>{2}{3}</td><td class="id">{4}</td><td>{5}</td><td>{6}</td><td>{7}</td><td>{8}</td></tr>' -f `
            $Cls, $Sign, $Tags, $TypeText, (Enc $Ace.Identity), (Enc $Ace.Rights), (Enc $Obj), (Enc $Ace.AppliesTo), $Inh
    }

    $Res = @($Results | Where-Object { $null -ne $_ -and $_.PSObject.Properties['OldWhen'] })
    if ($Res.Count -eq 0) { throw 'No comparison data to export (the comparisons above failed).' }
    $TotOus = 0; $TotRem = 0; $TotAdd = 0; $TotRes = 0; $TotSens = 0; $WithChanges = 0
    foreach ($r in $Res) {
        $TotOus += $r.Changed.Count; $TotRes += $r.Restores.Count
        if ($r.HasChanges) { $WithChanges++ }
        foreach ($c in $r.Changed) {
            $TotRem += @($c.Removed).Count; $TotAdd += @($c.Added).Count
            $TotSens += @($c.Added | Where-Object { Test-SensitiveAce $_ }).Count
        }
    }
    $First = ($Res | Sort-Object OldWhen | Select-Object -First 1).OldWhen
    $Last  = ($Res | Sort-Object NewWhen -Descending | Select-Object -First 1).NewWhen

    $Out = New-Object System.Collections.Generic.List[string]
    $Out.Add('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">')
    $Out.Add('<meta name="viewport" content="width=device-width, initial-scale=1">')
    $Out.Add('<title>ACL change log - ' + (Enc $Domain) + '</title>')
    $Out.Add(@'
<style>
:root{--bg:#f6f7f9;--card:#fff;--text:#1d232b;--muted:#5f6b7a;--line:#e3e7ec;--accent:#2f5d8a;
--add:#1f7a43;--addbg:#e9f6ee;--rem:#b3261e;--rembg:#fcecea;--warn:#8a5a00;--warnbg:#fff4dc;--inh:#5b3fa0;--inhbg:#efeafb}
@media (prefers-color-scheme:dark){:root{--bg:#14171c;--card:#1c2027;--text:#e6e9ee;--muted:#9aa5b3;--line:#2c323b;--accent:#7fb0e0;
--add:#6fd39a;--addbg:#16301f;--rem:#ff8a80;--rembg:#3a1a18;--warn:#f5c26b;--warnbg:#3a2c10;--inh:#b9a3ff;--inhbg:#2a2342}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 "Segoe UI",system-ui,-apple-system,Arial,sans-serif}
header{background:var(--card);border-bottom:1px solid var(--line);padding:20px 28px}
h1{margin:0 0 4px;font-size:22px}h1 small{color:var(--muted);font-weight:400;font-size:15px}
.meta{color:var(--muted);font-size:13px}main{max-width:1280px;margin:0 auto;padding:20px 28px 40px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.card b{display:block;font-size:24px}.card span{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.card.risk b{color:var(--rem)}
.tools{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-bottom:16px}
.tools input[type=search]{flex:1;min-width:240px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text)}
.tools button{padding:7px 12px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text);cursor:pointer}
details.cmp{background:var(--card);border:1px solid var(--line);border-radius:10px;margin-bottom:12px}
details.cmp>summary{cursor:pointer;padding:12px 16px;font-weight:600;display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.body{padding:0 16px 14px}.sub{color:var(--muted);font-size:12.5px;margin:2px 0}
.ou{border-top:1px solid var(--line);padding:12px 0}.dn{font-family:Consolas,"Cascadia Mono",monospace;font-size:13px;word-break:break-all;font-weight:600}
.note{margin:6px 0;padding:6px 10px;border-radius:6px;font-size:13px}
.note.r{background:var(--inhbg);color:var(--inh)}.note.o{background:var(--warnbg);color:var(--warn)}.note.g{color:var(--muted)}
.tbl{overflow-x:auto}table{border-collapse:collapse;width:100%;margin-top:6px;font-size:13px}
th,td{text-align:left;padding:5px 8px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600}
tr.add td{background:var(--addbg)}tr.rem td{background:var(--rembg)}td.sign{font-weight:700;width:22px;text-align:center}
tr.add td.sign{color:var(--add)}tr.rem td.sign{color:var(--rem)}td.id{font-weight:600}
.tag{display:inline-block;font-size:11px;padding:1px 7px;border-radius:999px;font-weight:600;white-space:nowrap}
.tag.add{background:var(--addbg);color:var(--add)}.tag.rem{background:var(--rembg);color:var(--rem)}
.tag.inh{background:var(--inhbg);color:var(--inh)}.tag.deny,.tag.risk{background:var(--rembg);color:var(--rem)}
.tag.warn{background:var(--warnbg);color:var(--warn)}.tag.ok{color:var(--muted);border:1px solid var(--line)}
ul.plain{margin:6px 0;padding-left:18px}footer{color:var(--muted);font-size:12px;text-align:center;padding:20px}
@media print{.tools{display:none}details.cmp{break-inside:avoid}}
</style></head><body>
'@)

    $Out.Add('<header><h1>ACL change log <small>' + (Enc $Domain) + '</small></h1>')
    $Out.Add(('<div class="meta">Period: {0:yyyy-MM-dd HH:mm} to {1:yyyy-MM-dd HH:mm} &middot; Backup set: {2} &middot; Generated {3:yyyy-MM-dd HH:mm} by {4} on {5}</div></header>' -f `
        $First, $Last, (Enc $Source), (Get-Date), (Enc (Get-RunAsUser)), (Enc $env:COMPUTERNAME)))

    $Out.Add('<main><div class="cards">')
    $Out.Add(('<div class="card"><b>{0}</b><span>comparisons</span></div>' -f $Res.Count))
    $Out.Add(('<div class="card"><b>{0}</b><span>with changes</span></div>' -f $WithChanges))
    $Out.Add(('<div class="card"><b>{0}</b><span>OUs changed</span></div>' -f $TotOus))
    $Out.Add(('<div class="card"><b>{0}</b><span>entries removed</span></div>' -f $TotRem))
    $Out.Add(('<div class="card"><b>{0}</b><span>entries added</span></div>' -f $TotAdd))
    $Cls = 'card'; if ($TotSens -gt 0) { $Cls = 'card risk' }
    $Out.Add(('<div class="{0}"><b>{1}</b><span>sensitive rights added</span></div>' -f $Cls, $TotSens))
    $Out.Add(('<div class="card"><b>{0}</b><span>restores by script</span></div>' -f $TotRes))
    $Out.Add('</div>')

    $Out.Add('<div class="tools"><input type="search" id="q" placeholder="Filter by OU or identity (e.g. Workstations, helpdesk)">')
    $Out.Add('<label><input type="checkbox" id="only" checked> only comparisons with changes</label>')
    $Out.Add('<button onclick="tog(true)">Expand all</button><button onclick="tog(false)">Collapse all</button></div>')

    foreach ($r in $Res) {
        $Open = ''; if ($r.HasChanges) { $Open = ' open' }
        $Out.Add(('<details class="cmp" data-changes="{0}"{1}><summary>{2:yyyy-MM-dd HH:mm} &rarr; {3:yyyy-MM-dd HH:mm}' -f [int]$r.HasChanges, $Open, $r.OldWhen, $r.NewWhen))
        if ($r.HasChanges) {
            $Out.Add(('<span class="tag warn">{0} OU(s) changed</span>' -f $r.Changed.Count))
            if ($r.NewOus.Count)     { $Out.Add(('<span class="tag add">{0} new OU(s)</span>' -f $r.NewOus.Count)) }
            if ($r.RemovedOus.Count) { $Out.Add(('<span class="tag rem">{0} OU(s) gone</span>' -f $r.RemovedOus.Count)) }
        } else { $Out.Add('<span class="tag ok">no changes</span>') }
        if ($r.Restores.Count) { $Out.Add(('<span class="tag inh">{0} restore(s)</span>' -f $r.Restores.Count)) }
        $Out.Add('</summary><div class="body">')
        $Out.Add(('<p class="sub">{0} &rarr; {1}</p><p class="sub">Backups run by: {2} &rarr; {3}</p>' -f (Enc $r.OldFile), (Enc $r.NewFile), (Enc $r.OldAuthor), (Enc $r.NewAuthor)))

        if ($r.Restores.Count) {
            $Out.Add('<div class="tbl"><table><tr><th>Restore (by this script)</th><th>User</th><th>OU</th><th>Result</th></tr>')
            foreach ($x in $r.Restores) {
                $Out.Add(('<tr><td>{0:yyyy-MM-dd HH:mm:ss}</td><td>{1}</td><td class="dn">{2}</td><td>{3}</td></tr>' -f $x.When, (Enc $x.User), (Enc $x.Target), (Enc $x.Result)))
            }
            $Out.Add('</table></div>')
        }

        foreach ($c in $r.Changed) {
            $Ids = (@($c.Removed) + @($c.Added) | ForEach-Object { $_.Identity }) -join ' '
            $Search = ($c.DN + ' ' + $Ids).ToLower()
            $Out.Add(('<div class="ou" data-s="{0}"><div class="dn">{1}</div>' -f (Enc $Search), (Enc $c.DN)))
            if ($c.Note) { $Out.Add(('<div class="note g">{0}</div>' -f (Enc $c.Note))) }
            foreach ($x in @($c.Restores)) {
                $Out.Add(('<div class="note r">Restored by <b>{0}</b> at {1:yyyy-MM-dd HH:mm:ss} from {2} ({3})</div>' -f (Enc $x.User), $x.When, (Enc $x.File), (Enc $x.Result)))
            }
            if ($c.InheritedCount -gt 0) {
                if ($c.Origin) { $Out.Add(('<div class="note o">{0} inherited change(s) &mdash; originated in <span class="dn">{1}</span></div>' -f $c.InheritedCount, (Enc $c.Origin))) }
                else           { $Out.Add(('<div class="note g">{0} inherited change(s) &mdash; origin not found in this backup</div>' -f $c.InheritedCount)) }
            }
            if ($null -ne $c.BlockedOld -and $c.BlockedOld -ne $c.BlockedNew) {
                $Out.Add(('<div class="note o">Inheritance blocked: {0} &rarr; {1}</div>' -f $c.BlockedOld, $c.BlockedNew))
            }
            if (@($c.Removed).Count + @($c.Added).Count -gt 0) {
                $Out.Add('<div class="tbl"><table><tr><th></th><th>Type</th><th>Identity</th><th>Rights</th><th>Object</th><th>Applies to</th><th>Source</th></tr>')
                foreach ($a in @($c.Removed)) { $Out.Add((AceRow -Ace $a -Change '-')) }
                foreach ($a in @($c.Added))   { $Out.Add((AceRow -Ace $a -Change '+')) }
                $Out.Add('</table></div>')
            }
            $Out.Add('</div>')
        }
        if ($r.NewOus.Count) {
            $Out.Add('<div class="ou" data-s="' + (Enc (($r.NewOus -join ' ').ToLower())) + '"><b>OUs present only in the newer backup</b><ul class="plain">')
            foreach ($d in $r.NewOus) { $Out.Add('<li class="dn">' + (Enc $d) + '</li>') }
            $Out.Add('</ul></div>')
        }
        if ($r.RemovedOus.Count) {
            $Out.Add('<div class="ou" data-s="' + (Enc (($r.RemovedOus -join ' ').ToLower())) + '"><b>OUs present only in the older backup</b><ul class="plain">')
            foreach ($d in $r.RemovedOus) { $Out.Add('<li class="dn">' + (Enc $d) + '</li>') }
            $Out.Add('</ul></div>')
        }
        $Out.Add('</div></details>')
    }

    $Out.Add(@'
<p class="sub">Dates are the dates of the backups: a change happened between the two dates shown. "Restores by script"
show who RAN this script; who changed a permission directly in AD is only in the AD audit (event 5136).</p>
</main><footer>CONFIDENTIAL &middot; contains the permission structure of Active Directory</footer>
<script>
var q=document.getElementById('q'),only=document.getElementById('only');
function apply(){var t=q.value.trim().toLowerCase();
document.querySelectorAll('details.cmp').forEach(function(c){var vis=0;
c.querySelectorAll('.ou').forEach(function(o){var m=!t||o.getAttribute('data-s').indexOf(t)>=0;o.hidden=!m;if(m)vis++;});
c.hidden=(only.checked&&c.getAttribute('data-changes')==='0')||(t!==''&&vis===0);if(t&&vis)c.open=true;});}
function tog(o){document.querySelectorAll('details.cmp').forEach(function(c){if(!c.hidden)c.open=o;});}
q.addEventListener('input',apply);only.addEventListener('change',apply);apply();
</script></body></html>
'@)

    $ReportFolder = Join-Path $BackupFolder 'Reports'
    New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
    $Path = Join-Path $ReportFolder ('CHANGELOG_{0}_{1}.html' -f $Domain, (Get-Date -Format 'yyyyMMdd_HHmm'))
    ($Out -join "`r`n") | Out-File -FilePath $Path -Encoding UTF8
    $Path
}

# Snapshots = SDDL_<domain>_<yyyyMMdd_HHmm>.csv of a backup set
function Get-Snapshots {
    param($Source)
    foreach ($f in @(Get-SnapshotFiles -Source $Source)) {
        if ($f.Name -match '^SDDL_(?<dom>.+)_(?<stamp>\d{8}_\d{4})\.csv$') {
            $When = [datetime]::ParseExact($Matches['stamp'], 'yyyyMMdd_HHmm', [System.Globalization.CultureInfo]::InvariantCulture)
            [pscustomobject]@{ Domain = $Matches['dom']; When = $When; File = $f }
        }
    }
}

function Invoke-ChangeLog {
    $Source = Select-BackupSource -Purpose 'Change log'
    if (-not $Source) { return }

    $Snaps = @(Get-Snapshots -Source $Source)
    if ($Snaps.Count -eq 0) {
        Write-Warning "No SDDL_<domain>_<date>.csv backups found in the selected backup set ($($Source.Name))."
        return
    }

    # 1) Pick the domain (only domains that have backups)
    $Groups = @($Snaps | Group-Object Domain | Sort-Object Name)
    Write-Section 'Change log - select the domain'
    $KeyWidth  = "$($Groups.Count)".Length
    $TextWidth = ($Groups | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    for ($i = 0; $i -lt $Groups.Count; $i++) {
        $Latest = ($Groups[$i].Group | Sort-Object When -Descending | Select-Object -First 1).When
        Write-MenuOption -Key ($i + 1) -KeyWidth $KeyWidth -Text $Groups[$i].Name -TextWidth $TextWidth -Note ('{0} backup(s), latest {1:yyyy-MM-dd HH:mm}' -f $Groups[$i].Count, $Latest)
    }
    Write-Host ''
    $Number = (Read-Menu 'Domain number (press ENTER to cancel)').Trim()
    if (-not $Number) { Write-Host 'Canceled.'; return }
    if ($Number -notmatch '^\d+$' -or [int]$Number -lt 1 -or [int]$Number -gt $Groups.Count) { Write-Warning 'Invalid option.'; return }
    $Group = $Groups[[int]$Number - 1]

    $Set = @($Group.Group | Sort-Object When)

    # Workflow check: changes made after the latest backup are not in any backup yet
    $Latest = $Set[-1].When
    $Age    = (Get-Date) - $Latest
    $AgeText = '{0:N0} minute(s)' -f $Age.TotalMinutes
    if ($Age.TotalHours -ge 48)    { $AgeText = '{0:N0} day(s)' -f $Age.TotalDays }
    elseif ($Age.TotalMinutes -ge 120) { $AgeText = '{0:N0} hour(s)' -f $Age.TotalHours }
    Write-Host ''
    Write-Host ("[!] Latest backup of {0}: {1:yyyy-MM-dd HH:mm} ({2} ago)." -f $Group.Name, $Latest, $AgeText) -ForegroundColor Yellow
    Write-Host '    ACL changes made AFTER it are not in any backup and will NOT appear in this change log.' -ForegroundColor Yellow
    $Answer = (Read-Menu "Run a new backup of $($Group.Name) now, to include the current state? (Y/N, ENTER = N)").Trim()
    if ($Answer -match '^[yY]') {
        Invoke-DomainBackup -Domain $Group.Name -SetLabel $Source.Label   # same set: main folder or its labeled subfolder
        $Set = @(Get-Snapshots -Source $Source | Where-Object { $_.Domain -eq $Group.Name } | Sort-Object When)
    }

    if ($Set.Count -lt 2) {
        Write-Warning "Only $($Set.Count) backup found for $($Group.Name). At least two are needed to compare."
        Write-Host '   Workflow: [1] Backup BEFORE changing ACLs -> make the changes -> [1] Backup AFTER -> [3] Change log.' -ForegroundColor Yellow
        return
    }

    # 2) How many comparisons to show
    $Max    = $Set.Count - 1
    $Answer = (Read-Menu ('How many recent comparisons to show (ENTER = 5, max {0})' -f $Max)).Trim()
    $Count  = 5
    if ($Answer -match '^\d+$' -and [int]$Answer -ge 1) { $Count = [int]$Answer }
    if ($Count -gt $Max) { $Count = $Max }

    # 3) Show the newest comparison first
    Write-Host ''
    Write-Host ('Change log for {0} - last {1} comparison(s) - set: {2}' -f $Group.Name, $Count, $Source.Name) -ForegroundColor Cyan
    Write-Host 'Dates are the dates of the backups: a change happened between the two dates shown.' -ForegroundColor DarkGray
    Write-Host '[R] = restores executed by this script (who ran it) | [^] = inherited change and the parent OU where it was made' -ForegroundColor DarkGray
    $OpLog = @(Get-OperationLog)
    $Results = @(for ($k = $Set.Count - 1; $k -ge ($Set.Count - $Count); $k--) {
        Show-SnapshotChanges -Old $Set[$k - 1] -New $Set[$k] -OpLog $OpLog
    })
    Write-Host ''

    # 4) Optional HTML report (same comparisons shown above)
    $Answer = (Read-Menu 'Export these comparisons to an HTML report? (Y/N, ENTER = N)').Trim()
    if ($Answer -match '^[yY]') {
        try {
            $Html = Export-ChangeLogHtml -Domain $Group.Name -Source $Source.Name -Results $Results
            Write-Host "HTML report saved to: $Html" -ForegroundColor Green
            $null = Copy-ToNetwork -Path $Html -SubFolder 'Reports'
            if ((Read-Menu 'Open the report now? (Y/N, ENTER = N)').Trim() -match '^[yY]') { Invoke-Item -Path $Html }
        }
        catch { Write-Warning "Could not create the HTML report: $($_.Exception.Message)" }
    }
}

# ----------------------------------------------------------------------------
# Unattended mode: -Mode Backup (no menus, no questions, exit code for the scheduler)
function Get-BackupTargets {
    $List = New-Object System.Collections.Generic.List[string]
    if ($AllDomains) {
        foreach ($d in $DefaultDomains) { $n = $d.ToLower(); if (-not $List.Contains($n)) { $List.Add($n) } }
        try {
            foreach ($d in [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().Domains) {
                $n = $d.Name.ToLower(); if (-not $List.Contains($n)) { $List.Add($n) }
            }
        }
        catch { Write-Warning "Could not list the forest domains ($($_.Exception.Message)). Using the default list only." }
    }
    foreach ($d in @($BackupDomain)) {
        if ($d) { $n = $d.Trim().ToLower(); if ($n -and -not $List.Contains($n)) { $List.Add($n) } }
    }
    $List
}

if ($Mode -eq 'Backup') {
    $RunStamp   = Get-Date -Format 'yyyyMMdd_HHmm'
    $LogDir     = Join-Path $BackupFolder 'Logs'
    $LabelPart  = ''
    if ($Label) { $LabelPart = "_$Label" }
    $Transcript = Join-Path $LogDir ("TRANSCRIPT_Backup{0}_{1}.txt" -f $LabelPart, $RunStamp)
    try {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        Start-Transcript -Path $Transcript -Force | Out-Null
    }
    catch { Write-Warning "Could not start the transcript: $($_.Exception.Message)"; $Transcript = $null }

    $ExitCode = 0
    $Targets  = @(Get-BackupTargets)
    Write-Host ("ACL-ADDS unattended backup - {0:yyyy-MM-dd HH:mm} - user {1} on {2}" -f (Get-Date), (Get-RunAsUser), $env:COMPUTERNAME)
    Write-Host ("Label: {0} | Folder: {1} | Network: {2}" -f $(if ($Label) { $Label } else { '(none)' }), $BackupFolder, $(if ($NetworkFolder) { $NetworkFolder } else { '(disabled)' }))

    if ($Targets.Count -eq 0) {
        Write-Warning 'No domain to back up. Configure $DefaultDomains in the script and/or use -AllDomains / -Domain <fqdn>.'
        $ExitCode = 2
    }
    else {
        Write-Host ('Domains: ' + ($Targets -join ', '))
        foreach ($d in $Targets) { Invoke-DomainBackup -Domain $d }

        $Runs = @($script:BackupRuns)
        $Ok   = @($Runs | Where-Object { $_.Result -eq 'OK' -and $_.Network -ne 'FAILED' })
        $Fail = @($Runs | Where-Object { $_.Result -eq 'FAILED' })
        if ($Runs.Count -eq 0 -or $Fail.Count -eq $Runs.Count) { $ExitCode = 2 }
        elseif ($Ok.Count -ne $Runs.Count)                      { $ExitCode = 1 }

        Write-Host ''
        Write-Host 'Summary:'
        ($Runs | Format-Table Domain, Result, Network, Objects, Errors -AutoSize | Out-String).Trim() | Write-Host
    }

    $Status = @{ 0 = 'OK'; 1 = 'PARTIAL'; 2 = 'FAILED' }[$ExitCode]
    Write-OperationLog -Operation 'BackupRun' -Domain 'ALL' -Result $Status `
        -Details ('mode: unattended; label: {0}; domains: {1}; exit code: {2}' -f $Label, ($Targets -join ' '), $ExitCode)
    Write-Host "Finished: $Status (exit code $ExitCode)"

    if ($Transcript) {
        try { Stop-Transcript | Out-Null } catch { }
        $null = Copy-ToNetwork -Path $Transcript -SubFolder 'Logs'
    }
    exit $ExitCode
}

# ----------------------------------------------------------------------------
# Main menu
do {
    Write-Banner -Title 'ACL-ADDS' -Subtitle 'Active Directory ACL Backup / Restore / Change Log'
    if ($WhatIfMode) { Write-Host (Format-Centered '*** WHAT-IF MODE: restore will not write anything ***' $UiWidth) -ForegroundColor Yellow }
    Write-Section 'Main menu'
    Write-MenuOption -Key '1' -Text 'Backup'  -TextWidth 10 -Note 'read-only'   -NoteColor Green
    Write-MenuOption -Key '2' -Text 'Restore' -TextWidth 10 -Note 'MODIFIES AD' -NoteColor Red
    Write-MenuOption -Key '3' -Text 'Change log' -TextWidth 10 -Note 'read-only' -NoteColor Green
    Write-MenuOption -Key '0' -Text 'Exit'
    Write-Host ''
    Write-Host '   Workflow: [1] Backup BEFORE changing ACLs > make the changes > [1] Backup AFTER > [3] Change log' -ForegroundColor DarkGray
    if ($NetworkFolder) { Write-Host "   Network copy: $NetworkFolder" -ForegroundColor DarkGray }
    Write-Host ''
    $Option = (Read-Menu 'Select an option').Trim()

    switch ($Option) {
        '1'     { Invoke-Backup }
        '2'     { Invoke-Restore }
        '3'     { Invoke-ChangeLog }
        '0'     { }
        default { Write-Warning 'Invalid option.' }
    }
} while ($Option -ne '0')
