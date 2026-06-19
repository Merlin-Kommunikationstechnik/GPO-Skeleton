# GPO Skeleton Skill

Use this file as the instruction source for an AI agent when an existing PowerShell script should be deployed through Group Policy without changing the target script.

## Goal

Create a small `deploy.ps1` beside the existing target script. The deploy script imports the `gpo-skeleton` module and calls `Install-SkeletonGpo`. The target script is copied to SYSVOL unchanged. `gpo-skeleton` generates a wrapper script in SYSVOL that runs the target script as a child PowerShell process and writes target output to local client logs and central DC logs.

## User Intent And Values

The user wants a complete reusable GPO deployment solution, not one-off deployment code. The module should make it simple to deploy an already existing script to clients through Active Directory Group Policy.

Important values:

- keep the target script unchanged by default
- build a wrapper around the target script instead of rewriting it
- capture legacy output such as `Write-Host`, stdout and stderr automatically
- write logs locally on the client and centrally on the DC share
- keep `deploy.ps1` short enough that an AI agent can generate it reliably
- keep GPO creation, SYSVOL publishing, scheduled task creation, cleanup and logging inside the module
- make the project ready for PowerShell Gallery releases
- document usage here instead of creating an `examples` folder

## Required Output

Create only the deployment script and any project-specific notes that are needed. Do not rewrite the target script unless the user explicitly asks for that.

The deployment script should:

- accept `-DomainName`
- import `gpo-skeleton`
- reference the target script by relative path from the deploy script folder
- call `Install-SkeletonGpo`
- pass project-specific target parameters through `-TargetScriptParameters` when needed
- avoid embedding domain-specific OUs unless the user provides them

## Deployment Script Pattern

```powershell
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainName
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module gpo-skeleton -ErrorAction Stop

$targetScript = Join-Path $PSScriptRoot 'target-script.ps1'

Install-SkeletonGpo `
    -ProjectName 'ProjectNameHere' `
    -DomainName $DomainName `
    -TargetScriptPath $targetScript
```

## Pattern With Target Parameters

```powershell
Install-SkeletonGpo `
    -ProjectName 'ProjectNameHere' `
    -DomainName $DomainName `
    -TargetScriptPath $targetScript `
    -TargetScriptParameters @{
        Mode = 'Audit'
        Force = $true
    }
```

## Expected Operator Flow

The operator copies `deploy.ps1` and the unchanged target script into the same folder on a DC or admin host with GPMC/RSAT access, then runs:

```powershell
.\deploy.ps1 -DomainName example.com
```

## What The Module Handles

- creates or updates the deployment GPO
- creates the central log folder and hidden SMB share
- copies the unchanged target script to SYSVOL
- copies the module to SYSVOL for client-side logging
- generates the wrapper script that captures target stdout and stderr
- writes Group Policy Preferences Scheduled Task XML
- runs the task as `NT AUTHORITY\SYSTEM`
- configures startup, registration and daily triggers
- writes local logs under `C:\ProgramData\<ProjectName>`
- writes central logs under the generated DC log share
- creates a cleanup GPO through `Remove-SkeletonGpo`

## Release Expectations

The module version lives in `gpo-skeleton/gpo-skeleton.psd1` as `ModuleVersion`.

Release automation must support:

- `patch`
- `minor`
- `major`

The PowerShell Gallery token is expected in the GitHub secret `PSGALLERY_API_KEY`.

## Important Rules For The Agent

- Do not modify the target script just to add logging.
- Do not replace `Write-Host` in the target script.
- Do not require the target script to import `gpo-skeleton`.
- Prefer `-TargetScriptPath` over the legacy `-ClientScriptPath` name.
- Keep the generated deploy script short and project-specific.
- Use `-TargetDn` and `-CreateDisabledLink` only when the user asks for a pilot OU link.
