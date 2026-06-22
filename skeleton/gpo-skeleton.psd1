@{
    RootModule = 'gpo-skeleton.psm1'
    ModuleVersion = '0.0.1'
    GUID = 'b6f8c603-6d7f-4c9d-9e0a-250db4c38676'
    Author = 'Uefi-sentinal'
    CompanyName = 'Unknown'
    Copyright = '(c) 2026. All rights reserved.'
    Description = 'Reusable GPO deployment skeleton for PowerShell client scripts.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Initialize-SkeletonLogging',
        'Log-Skeleton',
        'Get-SkeletonProjectDefaults',
        'Install-SkeletonGpo',
        'Remove-SkeletonGpo'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('GPO', 'GroupPolicy', 'ScheduledTask', 'Deployment', 'Logging')
            ProjectUri = ''
            ReleaseNotes = 'Initial reusable GPO skeleton module.'
        }
    }
}
