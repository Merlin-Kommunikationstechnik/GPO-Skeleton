Set-StrictMode -Version 3.0

$script:SkeletonLogDirectory = $null
$script:SkeletonLogPath = $null
$script:SkeletonCentralLogPath = $null
$script:SkeletonCentralLogWriteFailed = $false
$script:SkeletonMaxLogFiles = 50

function ConvertTo-SkeletonSafeName {
    param([Parameter(Mandatory = $true)][string]$Value)

    $safe = $Value -replace '[^A-Za-z0-9_.-]+', ''
    if ([string]::IsNullOrWhiteSpace($safe)) {
        throw "ProjectName '$Value' does not contain any usable characters for generated names."
    }

    return $safe
}

function ConvertTo-SkeletonXmlText {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return [System.Security.SecurityElement]::Escape($Value)
}

function ConvertTo-SkeletonDomainDistinguishedName {
    param([Parameter(Mandatory = $true)][string]$Domain)

    return (($Domain -split '\.') | ForEach-Object { "DC=$_" }) -join ','
}

function Resolve-SkeletonDomainName {
    param([string]$DomainName)

    if (-not [string]::IsNullOrWhiteSpace($DomainName)) {
        return $DomainName
    }

    if ($env:USERDNSDOMAIN) {
        return $env:USERDNSDOMAIN.ToLowerInvariant()
    }

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        return (Get-ADDomain).DNSRoot
    } catch {
        throw 'DomainName could not be detected. Run on a domain-joined admin host or pass -DomainName.'
    }
}

function Import-SkeletonGroupPolicy {
    if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
        throw "PowerShell module 'GroupPolicy' is missing. Install Group Policy Management tools or RSAT Group Policy Management Tools."
    }

    Import-Module GroupPolicy -ErrorAction Stop
}

function Get-SkeletonSysvolDomainPath {
    param([Parameter(Mandatory = $true)][string]$Domain)

    $uncPath = "\\$Domain\SYSVOL\$Domain"
    if (Test-Path -LiteralPath $uncPath) {
        return $uncPath
    }

    $localPath = Join-Path $env:SystemRoot 'SYSVOL\domain'
    if (Test-Path -LiteralPath $localPath) {
        return $localPath
    }

    throw "SYSVOL path was not found via '$uncPath' or '$localPath'. Run on a DC or on an admin host with SYSVOL access."
}

function Set-SkeletonGpoScheduledTasksExtension {
    param(
        [Parameter(Mandatory = $true)][guid]$GpoId,
        [Parameter(Mandatory = $true)][string]$Domain
    )

    $domainDn = ConvertTo-SkeletonDomainDistinguishedName -Domain $Domain
    $gpoPath = "LDAP://CN={$($GpoId.Guid)},CN=Policies,CN=System,$domainDn"
    $gpoAdsi = [ADSI]$gpoPath

    $scheduledTasksExtension = '[{AADCED64-746C-4633-A97C-D61349046527}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}]'
    $machineExtensions = [string]$gpoAdsi.Properties['gPCMachineExtensionNames'].Value
    if ($machineExtensions -notmatch [regex]::Escape('{AADCED64-746C-4633-A97C-D61349046527}')) {
        $gpoAdsi.Properties['gPCMachineExtensionNames'].Value = "$machineExtensions$scheduledTasksExtension"
    }

    $currentVersion = 0
    if ($null -ne $gpoAdsi.Properties['versionNumber'].Value) {
        $currentVersion = [int]$gpoAdsi.Properties['versionNumber'].Value
    }

    $newVersion = $currentVersion + 1
    $gpoAdsi.Properties['versionNumber'].Value = $newVersion
    $gpoAdsi.CommitChanges()

    return $newVersion
}

function Set-SkeletonGptIniVersion {
    param(
        [Parameter(Mandatory = $true)][string]$SysvolDomainPath,
        [Parameter(Mandatory = $true)][guid]$GpoId,
        [Parameter(Mandatory = $true)][int]$Version
    )

    $gptPath = Join-Path $SysvolDomainPath "Policies\{$($GpoId.Guid)}\GPT.INI"
    $content = if (Test-Path -LiteralPath $gptPath) {
        Get-Content -LiteralPath $gptPath -Raw
    } else {
        "[General]`r`n"
    }

    if ($content -match '(?im)^Version=') {
        $content = $content -replace '(?im)^Version=.*$', "Version=$Version"
    } else {
        if ($content -notmatch '(?im)^\[General\]') {
            $content = "[General]`r`n$content"
        }
        $content = $content.TrimEnd() + "`r`nVersion=$Version`r`n"
    }

    [System.IO.File]::WriteAllText($gptPath, $content, [System.Text.Encoding]::ASCII)
}

function Convert-SkeletonSomPathToTarget {
    param(
        [Parameter(Mandatory = $true)][string]$SomPath,
        [Parameter(Mandatory = $true)][string]$Domain
    )

    if ($SomPath -ieq $Domain) {
        return ConvertTo-SkeletonDomainDistinguishedName -Domain $Domain
    }

    if ($SomPath.StartsWith("$Domain/")) {
        $relative = $SomPath.Substring($Domain.Length + 1)
        $domainDn = ConvertTo-SkeletonDomainDistinguishedName -Domain $Domain
        $ouParts = @($relative -split '/' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        [array]::Reverse($ouParts)
        return (($ouParts | ForEach-Object { "OU=$_" }) -join ',') + ",$domainDn"
    }

    return $SomPath
}

function Get-SkeletonGpoLinkTargets {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Domain,
        [switch]$EnabledOnly
    )

    try {
        [xml]$report = Get-GPOReport -Name $Name -Domain $Domain -ReportType Xml -ErrorAction Stop
    } catch {
        return @()
    }

    foreach ($link in @($report.GPO.LinksTo)) {
        if (-not $link.SOMPath) {
            continue
        }

        if ($EnabledOnly -and -not ($link.Enabled -eq 'true' -or $link.Enabled -eq $true)) {
            continue
        }

        [pscustomobject]@{
            SOMPath = [string]$link.SOMPath
            NoOverride = [string]$link.NoOverride
            Enabled = [string]$link.Enabled
        }
    }
}

function Disable-SkeletonCleanupGpoLinks {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Domain
    )

    $cleanupGpo = Get-GPO -Name $Name -Domain $Domain -ErrorAction SilentlyContinue
    if (-not $cleanupGpo) {
        return
    }

    foreach ($link in @(Get-SkeletonGpoLinkTargets -Name $Name -Domain $Domain)) {
        $target = Convert-SkeletonSomPathToTarget -SomPath $link.SOMPath -Domain $Domain
        Write-Verbose "Removing cleanup GPO link from: $target"
        Remove-GPLink -Name $Name -Target $target -Domain $Domain -ErrorAction SilentlyContinue | Out-Null
    }
}

function Initialize-SkeletonCentralLogShare {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ShareName
    )

    $writers = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-11').Translate([System.Security.Principal.NTAccount]).Value
    $administrators = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([System.Security.Principal.NTAccount]).Value
    $systemAccount = 'NT AUTHORITY\SYSTEM'

    New-Item -Path $Path -ItemType Directory -Force | Out-Null
    $logFolder = Get-Item -LiteralPath $Path -Force
    $logFolder.Attributes = $logFolder.Attributes -bor [System.IO.FileAttributes]::Hidden

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }

    $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($writers, 'Modify', $inheritanceFlags, $propagationFlags, 'Allow')))
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($administrators, 'FullControl', $inheritanceFlags, $propagationFlags, 'Allow')))
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($systemAccount, 'FullControl', $inheritanceFlags, $propagationFlags, 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl

    $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if (-not $share) {
        New-SmbShare -Name $ShareName -Path $Path -ChangeAccess $writers -FullAccess $administrators | Out-Null
    } else {
        if ($share.Path -ne $Path) {
            throw "SMB share '$ShareName' already exists with a different path: $($share.Path)"
        }

        Grant-SmbShareAccess -Name $ShareName -AccountName $writers -AccessRight Change -Force | Out-Null
        Grant-SmbShareAccess -Name $ShareName -AccountName $administrators -AccessRight Full -Force | Out-Null
    }

    return "\\$env:COMPUTERNAME\$ShareName"
}

function Format-SkeletonPowerShellArgumentValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return '$null'
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return '$true'
        }
        return '$false'
    }

    $text = [string]$Value
    return "'" + ($text -replace "'", "''") + "'"
}

function New-SkeletonScriptArgument {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptUncPath,
        [hashtable]$ClientScriptParameters
    )

    $parts = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        (Format-SkeletonPowerShellArgumentValue -Value $ScriptUncPath)
    )

    if ($ClientScriptParameters) {
        foreach ($key in @($ClientScriptParameters.Keys | Sort-Object)) {
            if ([string]::IsNullOrWhiteSpace([string]$key)) {
                continue
            }

            $parts += "-$key"
            $value = $ClientScriptParameters[$key]
            if ($value -is [switch] -or $value -is [bool]) {
                if ($value) {
                    continue
                }
            }

            $parts += (Format-SkeletonPowerShellArgumentValue -Value $value)
        }
    }

    return ($parts -join ' ')
}

function New-SkeletonTargetArgumentLiteral {
    param([hashtable]$TargetScriptParameters)

    $items = @()
    if ($TargetScriptParameters) {
        foreach ($key in @($TargetScriptParameters.Keys | Sort-Object)) {
            if ([string]::IsNullOrWhiteSpace([string]$key)) {
                continue
            }

            $value = $TargetScriptParameters[$key]
            if ($value -is [switch] -or $value -is [bool]) {
                if ($value) {
                    $items += "'-$key'"
                }
                continue
            }

            $items += "'-$key'"
            $items += (Format-SkeletonPowerShellArgumentValue -Value $value)
        }
    }

    return '@(' + ($items -join ', ') + ')'
}

function New-SkeletonClientWrapperScript {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [Parameter(Mandatory = $true)][string]$TargetScriptFileName,
        [hashtable]$TargetScriptParameters,
        [ValidateRange(1, 10000)][int]$MaxLogFiles = 50
    )

    $projectLiteral = Format-SkeletonPowerShellArgumentValue -Value $ProjectName
    $targetLiteral = Format-SkeletonPowerShellArgumentValue -Value $TargetScriptFileName
    $targetArgumentsLiteral = New-SkeletonTargetArgumentLiteral -TargetScriptParameters $TargetScriptParameters

    return @"
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]`$ProjectName = $projectLiteral,
    [string]`$CentralLogDirectory,
    [string]`$LogDirectory
)

Set-StrictMode -Version 3.0
`$ErrorActionPreference = 'Stop'

`$localModule = Join-Path `$PSScriptRoot 'gpo-skeleton\gpo-skeleton.psd1'
if (Test-Path -LiteralPath `$localModule) {
    Import-Module `$localModule -ErrorAction Stop
} else {
    Import-Module gpo-skeleton -ErrorAction Stop
}
Initialize-SkeletonLogging -ProjectName `$ProjectName -CentralLogDirectory `$CentralLogDirectory -LogDirectory `$LogDirectory -MaxLogFiles $MaxLogFiles | Out-Null

`$targetScript = Join-Path `$PSScriptRoot $targetLiteral
`$targetArguments = $targetArgumentsLiteral

if (-not (Test-Path -LiteralPath `$targetScript)) {
    Log-Skeleton "Target script was not found: `$targetScript" 'ERROR'
    exit 2
}

`$runId = [guid]::NewGuid().ToString('N')
`$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "gpo-skeleton-`$runId"
`$stdoutPath = Join-Path `$tempRoot 'stdout.log'
`$stderrPath = Join-Path `$tempRoot 'stderr.log'

try {
    New-Item -Path `$tempRoot -ItemType Directory -Force | Out-Null
    Log-Skeleton "Starting target script: `$targetScript"

    `$argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', `$targetScript) + `$targetArguments
    `$process = Start-Process -FilePath 'powershell.exe' -ArgumentList `$argumentList -RedirectStandardOutput `$stdoutPath -RedirectStandardError `$stderrPath -Wait -PassThru -WindowStyle Hidden

    if (Test-Path -LiteralPath `$stdoutPath) {
        foreach (`$line in @(Get-Content -LiteralPath `$stdoutPath -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace(`$line)) {
                Log-Skeleton "[target:stdout] `$line"
            }
        }
    }

    if (Test-Path -LiteralPath `$stderrPath) {
        foreach (`$line in @(Get-Content -LiteralPath `$stderrPath -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace(`$line)) {
                Log-Skeleton "[target:stderr] `$line" 'ERROR'
            }
        }
    }

    if (`$process.ExitCode -eq 0) {
        Log-Skeleton "Target script completed with exit code 0." 'OK'
    } else {
        Log-Skeleton "Target script failed with exit code `$(`$process.ExitCode)." 'ERROR'
    }

    exit `$process.ExitCode
} catch {
    Log-Skeleton "Wrapper failed: `$(`$_.Exception.Message)" 'ERROR'
    exit 1
} finally {
    if (Test-Path -LiteralPath `$tempRoot) {
        Remove-Item -LiteralPath `$tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
"@
}

function New-SkeletonGppScheduledTaskXml {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ScriptUncPath,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][int]$BootDelayMinutes,
        [Parameter(Mandatory = $true)][string]$DailyTime,
        [Parameter(Mandatory = $true)][int]$RandomMinutes,
        [hashtable]$ClientScriptParameters,
        [int]$ExecutionTimeLimitMinutes = 30,
        [string]$Author = 'gpo-skeleton'
    )

    $uid = [guid]::NewGuid().ToString('B').ToUpperInvariant()
    $changed = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $safeName = ConvertTo-SkeletonXmlText $Name
    $safeDescription = ConvertTo-SkeletonXmlText $Description
    $argument = ConvertTo-SkeletonXmlText (New-SkeletonScriptArgument -ScriptUncPath $ScriptUncPath -ClientScriptParameters $ClientScriptParameters)
    $startBoundary = '{0}T{1}:00' -f (Get-Date -Format 'yyyy-MM-dd'), $DailyTime
    $randomDelay = if ($RandomMinutes -gt 0) { "<RandomDelay>PT${RandomMinutes}M</RandomDelay>" } else { '' }
    $executionLimit = "PT${ExecutionTimeLimitMinutes}M"
    $safeAuthor = ConvertTo-SkeletonXmlText $Author

    return @"
<?xml version="1.0" encoding="utf-8"?>
<ScheduledTasks clsid="{CC63F200-7309-4ba0-B154-A71CD118DBCC}">
  <TaskV2 clsid="{D8896631-B747-47a7-84A6-C155337F3BC8}" name="$safeName" image="2" changed="$changed" uid="$uid" userContext="0" removePolicy="0">
    <Properties action="U" name="$safeName" runAs="NT AUTHORITY\System" logonType="S4U">
      <Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
        <RegistrationInfo>
          <Author>$safeAuthor</Author>
          <Description>$safeDescription</Description>
        </RegistrationInfo>
        <Triggers>
          <RegistrationTrigger>
            <Enabled>true</Enabled>
            <Delay>PT2M</Delay>
          </RegistrationTrigger>
          <BootTrigger>
            <Enabled>true</Enabled>
            <Delay>PT${BootDelayMinutes}M</Delay>
          </BootTrigger>
          <CalendarTrigger>
            <StartBoundary>$startBoundary</StartBoundary>
            <Enabled>true</Enabled>
            <ScheduleByDay>
              <DaysInterval>1</DaysInterval>
            </ScheduleByDay>
            $randomDelay
          </CalendarTrigger>
        </Triggers>
        <Principals>
          <Principal id="Author">
            <UserId>S-1-5-18</UserId>
            <RunLevel>HighestAvailable</RunLevel>
          </Principal>
        </Principals>
        <Settings>
          <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
          <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
          <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
          <AllowHardTerminate>true</AllowHardTerminate>
          <StartWhenAvailable>true</StartWhenAvailable>
          <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
          <IdleSettings>
            <StopOnIdleEnd>false</StopOnIdleEnd>
            <RestartOnIdle>false</RestartOnIdle>
          </IdleSettings>
          <AllowStartOnDemand>true</AllowStartOnDemand>
          <Enabled>true</Enabled>
          <Hidden>false</Hidden>
          <RunOnlyIfIdle>false</RunOnlyIfIdle>
          <WakeToRun>false</WakeToRun>
          <ExecutionTimeLimit>$executionLimit</ExecutionTimeLimit>
          <Priority>7</Priority>
        </Settings>
        <Actions Context="Author">
          <Exec>
            <Command>powershell.exe</Command>
            <Arguments>$argument</Arguments>
          </Exec>
        </Actions>
      </Task>
    </Properties>
  </TaskV2>
</ScheduledTasks>
"@
}

function New-SkeletonGppDeleteScheduledTaskXml {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ProjectName
    )

    $uid = [guid]::NewGuid().ToString('B').ToUpperInvariant()
    $changed = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $safeName = ConvertTo-SkeletonXmlText $Name
    $safeProjectName = ConvertTo-SkeletonXmlText $ProjectName

    return @"
<?xml version="1.0" encoding="utf-8"?>
<ScheduledTasks clsid="{CC63F200-7309-4ba0-B154-A71CD118DBCC}">
  <TaskV2 clsid="{D8896631-B747-47a7-84A6-C155337F3BC8}" name="$safeName" image="2" changed="$changed" uid="$uid" userContext="0" removePolicy="0">
    <Properties action="D" name="$safeName" runAs="NT AUTHORITY\System" logonType="S4U">
      <Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
        <RegistrationInfo>
          <Author>gpo-skeleton cleanup</Author>
          <Description>Deletes the $safeProjectName scheduled task from clients.</Description>
        </RegistrationInfo>
        <Principals>
          <Principal id="Author">
            <UserId>S-1-5-18</UserId>
            <RunLevel>HighestAvailable</RunLevel>
          </Principal>
        </Principals>
        <Settings>
          <Enabled>true</Enabled>
        </Settings>
        <Actions Context="Author">
          <Exec>
            <Command>cmd.exe</Command>
            <Arguments>/c exit 0</Arguments>
          </Exec>
        </Actions>
      </Task>
    </Properties>
  </TaskV2>
</ScheduledTasks>
"@
}

function Publish-SkeletonClientScript {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$SysvolDomainPath,
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][string]$FolderName,
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [switch]$PublishModule,
        [switch]$RunTargetScriptDirectly,
        [string]$WrapperScriptName = 'Invoke-GpoSkeletonTarget.ps1',
        [hashtable]$TargetScriptParameters
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "Client script was not found: $SourcePath"
    }

    $targetFolder = Join-Path $SysvolDomainPath "Scripts\$FolderName"
    $targetScriptFileName = Split-Path -Leaf $SourcePath
    $targetPath = Join-Path $targetFolder $targetScriptFileName

    New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $targetPath -Force

    $wrapperPath = $null
    $wrapperUncPath = $null
    $scheduledScriptPath = $targetPath
    $scheduledUncPath = "\\$Domain\SYSVOL\$Domain\Scripts\$FolderName\$targetScriptFileName"

    if (-not $RunTargetScriptDirectly) {
        $wrapperPath = Join-Path $targetFolder $WrapperScriptName
        $wrapperScript = New-SkeletonClientWrapperScript -ProjectName $ProjectName -TargetScriptFileName $targetScriptFileName -TargetScriptParameters $TargetScriptParameters
        [System.IO.File]::WriteAllText($wrapperPath, $wrapperScript, (New-Object System.Text.UTF8Encoding($false)))
        $wrapperUncPath = "\\$Domain\SYSVOL\$Domain\Scripts\$FolderName\$WrapperScriptName"
        $scheduledScriptPath = $wrapperPath
        $scheduledUncPath = $wrapperUncPath
    }

    $moduleTargetPath = $null
    $moduleUncPath = $null
    if ($PublishModule) {
        $moduleRoot = $PSScriptRoot
        $moduleTargetPath = Join-Path $targetFolder 'gpo-skeleton'
        if (Test-Path -LiteralPath $moduleTargetPath) {
            Remove-Item -LiteralPath $moduleTargetPath -Recurse -Force
        }
        Copy-Item -LiteralPath $moduleRoot -Destination $moduleTargetPath -Recurse -Force
        $moduleUncPath = "\\$Domain\SYSVOL\$Domain\Scripts\$FolderName\gpo-skeleton\gpo-skeleton.psd1"
    }

    [pscustomobject]@{
        TargetFolder = $targetFolder
        TargetPath = $scheduledScriptPath
        UncPath = $scheduledUncPath
        TargetScriptPath = $targetPath
        TargetScriptUncPath = "\\$Domain\SYSVOL\$Domain\Scripts\$FolderName\$targetScriptFileName"
        WrapperPath = $wrapperPath
        WrapperUncPath = $wrapperUncPath
        ModuleTargetPath = $moduleTargetPath
        ModuleUncPath = $moduleUncPath
    }
}

function NewOrUpdate-SkeletonScheduledTaskGpo {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][string]$SysvolDomainPath,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$ScriptUncPath,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][int]$StartupDelayMinutes,
        [Parameter(Mandatory = $true)][string]$DailyStartTime,
        [Parameter(Mandatory = $true)][int]$RandomDelayMinutes,
        [hashtable]$ClientScriptParameters,
        [int]$ExecutionTimeLimitMinutes = 30
    )

    $gpo = Get-GPO -Name $Name -Domain $Domain -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $Name -Domain $Domain -Comment $Description
    } else {
        Write-Verbose "Existing GPO found; updating SYSVOL contents: $Name"
    }

    if (-not $gpo) {
        throw "GPO object was not created: $Name"
    }

    $gpoGuid = $gpo.Id.ToString()
    $scheduledTaskFolder = Join-Path $SysvolDomainPath "Policies\{$gpoGuid}\Machine\Preferences\ScheduledTasks"
    $scheduledTaskXmlPath = Join-Path $scheduledTaskFolder 'ScheduledTasks.xml'
    $scheduledTaskXml = New-SkeletonGppScheduledTaskXml -Name $TaskName -ScriptUncPath $ScriptUncPath -Description $Description -BootDelayMinutes $StartupDelayMinutes -DailyTime $DailyStartTime -RandomMinutes $RandomDelayMinutes -ClientScriptParameters $ClientScriptParameters -ExecutionTimeLimitMinutes $ExecutionTimeLimitMinutes

    New-Item -Path $scheduledTaskFolder -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($scheduledTaskXmlPath, $scheduledTaskXml, (New-Object System.Text.UTF8Encoding($false)))

    $newVersion = Set-SkeletonGpoScheduledTasksExtension -GpoId $gpo.Id -Domain $Domain
    Set-SkeletonGptIniVersion -SysvolDomainPath $SysvolDomainPath -GpoId $gpo.Id -Version $newVersion

    [pscustomobject]@{
        Gpo = $gpo
        Version = $newVersion
        ScheduledTaskXmlPath = $scheduledTaskXmlPath
    }
}

function NewOrUpdate-SkeletonCleanupGpo {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [Parameter(Mandatory = $true)][string]$CleanupGpoName,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][string]$SysvolDomainPath,
        [object[]]$LinkTargets = @()
    )

    $cleanupGpo = Get-GPO -Name $CleanupGpoName -Domain $Domain -ErrorAction SilentlyContinue
    if (-not $cleanupGpo) {
        $cleanupGpo = New-GPO -Name $CleanupGpoName -Domain $Domain -Comment "Cleanup GPO that deletes the '$TaskName' scheduled task from clients."
    }

    $gpoGuid = $cleanupGpo.Id.ToString()
    $scheduledTaskFolder = Join-Path $SysvolDomainPath "Policies\{$gpoGuid}\Machine\Preferences\ScheduledTasks"
    $scheduledTaskXmlPath = Join-Path $scheduledTaskFolder 'ScheduledTasks.xml'
    New-Item -Path $scheduledTaskFolder -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText($scheduledTaskXmlPath, (New-SkeletonGppDeleteScheduledTaskXml -Name $TaskName -ProjectName $ProjectName), (New-Object System.Text.UTF8Encoding($false)))

    $newVersion = Set-SkeletonGpoScheduledTasksExtension -GpoId $cleanupGpo.Id -Domain $Domain
    Set-SkeletonGptIniVersion -SysvolDomainPath $SysvolDomainPath -GpoId $cleanupGpo.Id -Version $newVersion

    foreach ($linkTarget in @($LinkTargets)) {
        $targetDn = Convert-SkeletonSomPathToTarget -SomPath $linkTarget.SOMPath -Domain $Domain
        $existingLinks = @(Get-GPInheritance -Target $targetDn -Domain $Domain | Select-Object -ExpandProperty GpoLinks)
        $existingLink = $existingLinks | Where-Object { $_.GpoId -eq $cleanupGpo.Id }
        if (-not $existingLink) {
            New-GPLink -Name $CleanupGpoName -Target $targetDn -Domain $Domain -LinkEnabled Yes | Out-Null
        } else {
            Set-GPLink -Name $CleanupGpoName -Target $targetDn -Domain $Domain -LinkEnabled Yes | Out-Null
        }
    }

    [pscustomobject]@{
        Gpo = $cleanupGpo
        Version = $newVersion
        ScheduledTaskXmlPath = $scheduledTaskXmlPath
    }
}

function Invoke-SkeletonLogRotation {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [int]$Keep = 50
    )

    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            return
        }

        $logs = @(Get-ChildItem -LiteralPath $Directory -Filter '*.log' -File -ErrorAction Stop | Sort-Object LastWriteTime, Name)
        if ($logs.Count -le $Keep) {
            return
        }

        $removeCount = $logs.Count - $Keep
        $logs | Select-Object -First $removeCount | Remove-Item -Force -ErrorAction Stop
    } catch {
        if ($script:SkeletonLogPath -and (Test-Path -LiteralPath $script:SkeletonLogPath)) {
            Add-Content -LiteralPath $script:SkeletonLogPath -Value ('{0} [WARN] Log rotation failed for {1}: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Directory, $_.Exception.Message) -Encoding UTF8
        }
    }
}

function Get-SkeletonProjectDefaults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [string]$BaseProgramDataPath = $env:ProgramData
    )

    $safeName = ConvertTo-SkeletonSafeName -Value $ProjectName

    [pscustomobject]@{
        ProjectName = $ProjectName
        SafeName = $safeName
        GpoName = "$safeName-Deploy"
        CleanupGpoName = "$safeName-Cleanup"
        TaskName = "$safeName-Deploy"
        SysvolScriptFolderName = $safeName
        ClientLogDirectory = Join-Path $BaseProgramDataPath $safeName
        CentralLogPath = Join-Path $BaseProgramDataPath ".$safeName\GpoCentralLogs"
        CentralLogShareName = ".$safeName`GpoLogs$"
    }
}

function Initialize-SkeletonLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [string]$LogDirectory,
        [string]$CentralLogDirectory,
        [ValidateRange(1, 10000)][int]$MaxLogFiles = 50,
        [string]$LogFilePrefix
    )

    $defaults = Get-SkeletonProjectDefaults -ProjectName $ProjectName
    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = $defaults.ClientLogDirectory
    }

    if ([string]::IsNullOrWhiteSpace($LogFilePrefix)) {
        $LogFilePrefix = $defaults.SafeName
    }

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    $script:SkeletonLogDirectory = $LogDirectory
    $script:SkeletonMaxLogFiles = $MaxLogFiles
    $logFileName = '{0}-{1}-{2}.log' -f $LogFilePrefix, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $script:SkeletonLogPath = Join-Path $LogDirectory $logFileName
    $script:SkeletonCentralLogPath = $null
    $script:SkeletonCentralLogWriteFailed = $false

    if (-not [string]::IsNullOrWhiteSpace($CentralLogDirectory)) {
        try {
            if (-not (Test-Path -LiteralPath $CentralLogDirectory)) {
                New-Item -Path $CentralLogDirectory -ItemType Directory -Force | Out-Null
            }

            $centralComputerLogDirectory = Join-Path $CentralLogDirectory $env:COMPUTERNAME
            if (-not (Test-Path -LiteralPath $centralComputerLogDirectory)) {
                New-Item -Path $centralComputerLogDirectory -ItemType Directory -Force | Out-Null
            }

            $script:SkeletonCentralLogPath = Join-Path $centralComputerLogDirectory $logFileName
        } catch {
            $script:SkeletonCentralLogWriteFailed = $true
        }
    }

    Log-Skeleton -Message "Logging initialized. Computer=$env:COMPUTERNAME; User=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Level INFO

    [pscustomobject]@{
        LogPath = $script:SkeletonLogPath
        CentralLogPath = $script:SkeletonCentralLogPath
        LogDirectory = $script:SkeletonLogDirectory
    }
}

function Log-Skeleton {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
        [switch]$PassThru
    )

    if ([string]::IsNullOrWhiteSpace($script:SkeletonLogPath)) {
        throw 'Skeleton logging is not initialized. Call Initialize-SkeletonLogging first.'
    }

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:SkeletonLogPath -Value $line -Encoding UTF8
    Invoke-SkeletonLogRotation -Directory $script:SkeletonLogDirectory -Keep $script:SkeletonMaxLogFiles

    if ($script:SkeletonCentralLogPath -and -not $script:SkeletonCentralLogWriteFailed) {
        try {
            Add-Content -LiteralPath $script:SkeletonCentralLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
            Invoke-SkeletonLogRotation -Directory (Split-Path -Parent $script:SkeletonCentralLogPath) -Keep $script:SkeletonMaxLogFiles
        } catch {
            $script:SkeletonCentralLogWriteFailed = $true
            Add-Content -LiteralPath $script:SkeletonLogPath -Value ('{0} [WARN] Central log write failed: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) -Encoding UTF8
        }
    }

    if ($PassThru) {
        return $line
    }
}

function Install-SkeletonGpo {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [Parameter(Mandatory = $true)]
        [Alias('TargetScriptPath')]
        [string]$ClientScriptPath,
        [string]$DomainName,
        [string]$GpoName,
        [string]$CleanupGpoName,
        [string]$TaskName,
        [string]$SysvolScriptFolderName,
        [string]$Description,
        [string]$CentralLogPath,
        [string]$CentralLogShareName,
        [switch]$DisableCentralLogging,
        [switch]$KeepCleanupGpoLinks,
        [switch]$SkipModulePublish,
        [switch]$RunTargetScriptDirectly,
        [hashtable]$ClientScriptParameters,
        [hashtable]$TargetScriptParameters,
        [ValidateRange(1, 120)][int]$StartupDelayMinutes = 10,
        [ValidatePattern('^\d{2}:\d{2}$')][string]$DailyStartTime = '13:00',
        [ValidateRange(0, 1440)][int]$RandomDelayMinutes = 240,
        [ValidateRange(1, 1440)][int]$ExecutionTimeLimitMinutes = 30,
        [string[]]$TargetDn,
        [switch]$CreateDisabledLink
    )

    Import-SkeletonGroupPolicy
    $resolvedDomain = Resolve-SkeletonDomainName -DomainName $DomainName
    $defaults = Get-SkeletonProjectDefaults -ProjectName $ProjectName

    if ([string]::IsNullOrWhiteSpace($GpoName)) { $GpoName = $defaults.GpoName }
    if ([string]::IsNullOrWhiteSpace($CleanupGpoName)) { $CleanupGpoName = $defaults.CleanupGpoName }
    if ([string]::IsNullOrWhiteSpace($TaskName)) { $TaskName = $defaults.TaskName }
    if ([string]::IsNullOrWhiteSpace($SysvolScriptFolderName)) { $SysvolScriptFolderName = $defaults.SysvolScriptFolderName }
    if ([string]::IsNullOrWhiteSpace($Description)) { $Description = "Runs the $ProjectName client script through Group Policy." }
    if ([string]::IsNullOrWhiteSpace($CentralLogPath)) { $CentralLogPath = $defaults.CentralLogPath }
    if ([string]::IsNullOrWhiteSpace($CentralLogShareName)) { $CentralLogShareName = $defaults.CentralLogShareName }

    $sysvolDomainPath = Get-SkeletonSysvolDomainPath -Domain $resolvedDomain
    $centralLogUncPath = $null

    if ($PSCmdlet.ShouldProcess($GpoName, 'Create or update skeleton GPO deployment')) {
        if (-not $KeepCleanupGpoLinks) {
            Disable-SkeletonCleanupGpoLinks -Name $CleanupGpoName -Domain $resolvedDomain
        }

        if (-not $DisableCentralLogging) {
            $centralLogUncPath = Initialize-SkeletonCentralLogShare -Path $CentralLogPath -ShareName $CentralLogShareName
        }

        $effectiveParameters = @{}
        if ($ClientScriptParameters) {
            foreach ($key in $ClientScriptParameters.Keys) {
                $effectiveParameters[$key] = $ClientScriptParameters[$key]
            }
        }

        if ($centralLogUncPath -and -not $effectiveParameters.ContainsKey('CentralLogDirectory')) {
            $effectiveParameters['CentralLogDirectory'] = $centralLogUncPath
        }

        $publishedScript = Publish-SkeletonClientScript -SourcePath $ClientScriptPath -SysvolDomainPath $sysvolDomainPath -Domain $resolvedDomain -FolderName $SysvolScriptFolderName -ProjectName $ProjectName -PublishModule:(!$SkipModulePublish) -RunTargetScriptDirectly:$RunTargetScriptDirectly -TargetScriptParameters $TargetScriptParameters
        $gpoResult = NewOrUpdate-SkeletonScheduledTaskGpo -Name $GpoName -Domain $resolvedDomain -SysvolDomainPath $sysvolDomainPath -TaskName $TaskName -ScriptUncPath $publishedScript.UncPath -Description $Description -StartupDelayMinutes $StartupDelayMinutes -DailyStartTime $DailyStartTime -RandomDelayMinutes $RandomDelayMinutes -ClientScriptParameters $effectiveParameters -ExecutionTimeLimitMinutes $ExecutionTimeLimitMinutes

        if ($TargetDn -and $CreateDisabledLink) {
            foreach ($target in $TargetDn) {
                $existingLinks = @(Get-GPInheritance -Target $target -Domain $resolvedDomain | Select-Object -ExpandProperty GpoLinks)
                $existingLink = $existingLinks | Where-Object { $_.GpoId -eq $gpoResult.Gpo.Id }
                if (-not $existingLink) {
                    New-GPLink -Name $GpoName -Target $target -Domain $resolvedDomain -LinkEnabled No | Out-Null
                } else {
                    Set-GPLink -Name $GpoName -Target $target -Domain $resolvedDomain -LinkEnabled No | Out-Null
                }
            }
        } elseif ($TargetDn) {
            Write-Warning 'TargetDn was supplied, but no link was created because -CreateDisabledLink was not set.'
        }

        return [pscustomobject]@{
            ProjectName = $ProjectName
            Domain = $resolvedDomain
            GpoName = $GpoName
            CleanupGpoName = $CleanupGpoName
            TaskName = $TaskName
            ClientScript = $publishedScript.UncPath
            TargetScript = $publishedScript.TargetScriptUncPath
            WrapperScript = $publishedScript.WrapperUncPath
            PublishedModule = $publishedScript.ModuleUncPath
            CentralLogUncPath = $centralLogUncPath
            ScheduledTaskXmlPath = $gpoResult.ScheduledTaskXmlPath
            GpoVersion = $gpoResult.Version
        }
    }
}

function Remove-SkeletonGpo {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [string]$DomainName,
        [string]$GpoName,
        [string]$CleanupGpoName,
        [string]$TaskName,
        [string]$SysvolScriptFolderName,
        [string]$CentralLogPath,
        [string]$CentralLogShareName,
        [switch]$SkipCleanupGpo,
        [switch]$KeepCentralLogs
    )

    Import-SkeletonGroupPolicy
    $resolvedDomain = Resolve-SkeletonDomainName -DomainName $DomainName
    $defaults = Get-SkeletonProjectDefaults -ProjectName $ProjectName

    if ([string]::IsNullOrWhiteSpace($GpoName)) { $GpoName = $defaults.GpoName }
    if ([string]::IsNullOrWhiteSpace($CleanupGpoName)) { $CleanupGpoName = $defaults.CleanupGpoName }
    if ([string]::IsNullOrWhiteSpace($TaskName)) { $TaskName = $defaults.TaskName }
    if ([string]::IsNullOrWhiteSpace($SysvolScriptFolderName)) { $SysvolScriptFolderName = $defaults.SysvolScriptFolderName }
    if ([string]::IsNullOrWhiteSpace($CentralLogPath)) { $CentralLogPath = $defaults.CentralLogPath }
    if ([string]::IsNullOrWhiteSpace($CentralLogShareName)) { $CentralLogShareName = $defaults.CentralLogShareName }

    $sysvolDomainPath = Get-SkeletonSysvolDomainPath -Domain $resolvedDomain
    $linkTargets = @(Get-SkeletonGpoLinkTargets -Name $GpoName -Domain $resolvedDomain -EnabledOnly)
    $cleanupResult = $null

    if (-not $SkipCleanupGpo) {
        if ($PSCmdlet.ShouldProcess($CleanupGpoName, "Create/update cleanup GPO and link it where '$GpoName' is enabled")) {
            $cleanupResult = NewOrUpdate-SkeletonCleanupGpo -ProjectName $ProjectName -CleanupGpoName $CleanupGpoName -TaskName $TaskName -Domain $resolvedDomain -SysvolDomainPath $sysvolDomainPath -LinkTargets $linkTargets
        }
    }

    $gpo = Get-GPO -Name $GpoName -Domain $resolvedDomain -ErrorAction SilentlyContinue
    if ($gpo -and $PSCmdlet.ShouldProcess($GpoName, 'Remove deployment GPO from Active Directory')) {
        Remove-GPO -Name $GpoName -Domain $resolvedDomain
    }

    $sysvolScriptFolder = Join-Path $sysvolDomainPath "Scripts\$SysvolScriptFolderName"
    if ((Test-Path -LiteralPath $sysvolScriptFolder) -and $PSCmdlet.ShouldProcess($sysvolScriptFolder, 'Remove SYSVOL script folder')) {
        Remove-Item -LiteralPath $sysvolScriptFolder -Recurse -Force
    }

    if (-not $KeepCentralLogs) {
        $centralShare = Get-SmbShare -Name $CentralLogShareName -ErrorAction SilentlyContinue
        if ($centralShare -and $PSCmdlet.ShouldProcess($CentralLogShareName, 'Remove SMB central log share')) {
            Remove-SmbShare -Name $CentralLogShareName -Force
        }

        if ((Test-Path -LiteralPath $CentralLogPath) -and $PSCmdlet.ShouldProcess($CentralLogPath, 'Remove central log folder')) {
            try {
                $openFiles = @(Get-SmbOpenFile -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$CentralLogPath*" })
                foreach ($openFile in $openFiles) {
                    Close-SmbOpenFile -FileId $openFile.FileId -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Write-Warning "Could not enumerate or close SMB open files for '$CentralLogPath': $($_.Exception.Message)"
            }

            Remove-Item -LiteralPath $CentralLogPath -Recurse -Force
        }
    }

    [pscustomobject]@{
        ProjectName = $ProjectName
        Domain = $resolvedDomain
        RemovedGpoName = $GpoName
        CleanupGpoName = if ($cleanupResult) { $CleanupGpoName } else { $null }
        CleanupGpoVersion = if ($cleanupResult) { $cleanupResult.Version } else { $null }
        CleanupScheduledTaskXmlPath = if ($cleanupResult) { $cleanupResult.ScheduledTaskXmlPath } else { $null }
    }
}

Export-ModuleMember -Function Initialize-SkeletonLogging, Log-Skeleton, Get-SkeletonProjectDefaults, Install-SkeletonGpo, Remove-SkeletonGpo
