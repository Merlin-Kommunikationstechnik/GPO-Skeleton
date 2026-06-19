# GPO Skeleton Project Rules

These rules describe the intent and non-negotiable design choices for this repository.

## Product Intent

`gpo-skeleton` is a reusable PowerShell module for turning an existing local PowerShell script into a domain GPO deployment with minimal project-specific code.

The desired operator flow is:

1. A target PowerShell script already exists locally.
2. An AI agent receives `skeleton-skills.md` or the repo skill.
3. The agent creates a small `deploy.ps1` beside the target script.
4. The operator copies `deploy.ps1` and the unchanged target script into the same folder on a DC or admin host.
5. The operator runs `.\deploy.ps1 -DomainName example.com`.
6. The module handles GPO creation, SYSVOL publishing, scheduled task creation, wrapper execution, local logging and central DC logging.

## User Values

- Keep the target script unchanged unless the user explicitly requests modifications.
- Build around existing scripts instead of forcing scripts to adopt a framework.
- Make the deployment script short, readable and easy to regenerate.
- Prefer defaults that work in a normal Active Directory environment.
- Keep the complete GPO deployment logic in the module, not in every generated deploy script.
- Logging must work automatically for legacy output such as `Write-Host`, stdout and stderr.
- The solution must be suitable for PowerShell Gallery publishing.
- Release automation must support patch, minor and major version bumps.
- Do not add an `examples` folder; usage patterns belong in `skeleton-skills.md` or the repo skill.

## Code Rules

- Prefer PowerShell 5.1 compatible code.
- Keep public commands stable: `Install-SkeletonGpo`, `Remove-SkeletonGpo`, `Initialize-SkeletonLogging`, `Log-Skeleton`, `Get-SkeletonProjectDefaults`.
- Prefer `-TargetScriptPath` in docs and generated deploy scripts. Keep `-ClientScriptPath` only for backward compatibility.
- Do not require the target script to import `gpo-skeleton`.
- Do not require the target script to accept logging parameters.
- The scheduled task should run the generated wrapper by default, not the target script directly.
- Keep GPO/SYSVOL/Group Policy Preferences behavior inside the module.
- Use structured PowerShell APIs for XML, manifests and paths where practical.
- Validate syntax and module manifest after changes.

## GPO Behavior Rules

- Create or update the deploy GPO.
- Publish the unchanged target script to SYSVOL.
- Publish the module to SYSVOL by default so clients can import it from beside the wrapper.
- Generate the wrapper script in SYSVOL.
- Create the central log folder and hidden SMB share unless central logging is disabled.
- Configure a machine scheduled task via Group Policy Preferences.
- Run the task as `NT AUTHORITY\SYSTEM`.
- Support startup, registration and daily execution triggers.
- Support cleanup through `Remove-SkeletonGpo` and a cleanup GPO.

## Logging Rules

- Local client logs go under `C:\ProgramData\<ProjectName>` by default.
- Central logs go to the generated hidden DC share by default.
- Capture target stdout and stderr.
- Treat target stderr and non-zero exit codes as errors in wrapper logs.
- Do not edit target scripts just to replace `Write-Host`.
- Keep log rotation bounded.

## Release Rules

- The source of truth for the module version is `gpo-skeleton/gpo-skeleton.psd1` `ModuleVersion`.
- GitHub Actions may bump `patch`, `minor` or `major`.
- The PowerShell Gallery token must come from the GitHub secret `PSGALLERY_API_KEY`.
- Validate the module before publishing.
- Do not tag a release unless publishing succeeded.
