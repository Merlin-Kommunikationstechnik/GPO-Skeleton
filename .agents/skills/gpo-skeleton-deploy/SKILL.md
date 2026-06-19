---
name: gpo-skeleton-deploy
description: Create or update deployment scripts for this repository's gpo-skeleton PowerShell module. Use when a user wants to turn an existing PowerShell target script into a GPO deployment, generate deploy.ps1, preserve the target script unchanged, document agent usage, or maintain the GPO wrapper/logging/release workflow.
---

# GPO Skeleton Deploy

Use this skill when working in the `GPO-Skeleton` repository or when generating a `deploy.ps1` for an existing PowerShell target script.

## Core Intent

Build around the user's existing script. Do not force the target script to import the module, change `Write-Host`, add logging calls, or accept framework-specific parameters unless the user explicitly asks for that.

The module owns the deployment mechanics:

- create or update the GPO
- create the central log folder and share
- copy the target script to SYSVOL unchanged
- publish the module to SYSVOL
- generate the wrapper script
- create the scheduled task through Group Policy Preferences
- run the scheduled task as `NT AUTHORITY\SYSTEM`
- capture stdout and stderr into local and central logs
- support cleanup through `Remove-SkeletonGpo`

## Generated Deploy Script Requirements

When asked to create a deployment for a target script, create a short `deploy.ps1` beside that target script.

The deploy script must:

- use `#requires -RunAsAdministrator`
- accept mandatory `-DomainName`
- set strict mode and `$ErrorActionPreference = 'Stop'`
- import `gpo-skeleton`
- build the target path with `$PSScriptRoot`
- call `Install-SkeletonGpo`
- use `-TargetScriptPath`, not `-ClientScriptPath`
- pass target parameters through `-TargetScriptParameters` only when needed

Use this shape:

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

## Project-Specific Rules

- Keep target scripts unchanged by default.
- Keep generated deploy scripts boring and project-specific.
- Avoid embedding OU links unless the user provides a target OU or asks for a pilot link.
- Use `-TargetDn` with `-CreateDisabledLink` for pilot links.
- Do not create an `examples` folder.
- Put agent-facing usage guidance in `skeleton-skills.md`.
- Preserve PowerShell 5.1 compatibility.
- Validate `gpo-skeleton.psm1` syntax and `gpo-skeleton.psd1` manifest after module changes.

## Release Workflow Rules

The release workflow must use `gpo-skeleton/gpo-skeleton.psd1` `ModuleVersion` as the source version.

Supported release types:

- `patch`
- `minor`
- `major`

The PowerShell Gallery token must be read from GitHub secret `PSGALLERY_API_KEY`.

The workflow should validate the module before publishing and should not create a git tag if publishing fails.
