<div align="center">
    <img src="./assets/logo.png" height="400">
    <h1>GPO Skeleton</h1>
</div>

# Skeleton

`gpo-skeleton` ist ein wiederverwendbares PowerShell-Modul fuer GPO-basierte Deployments von bestehenden PowerShell-Skripten.
Das Zielskript muss fuer Logging nicht angepasst werden: das Modul kopiert es unveraendert nach SYSVOL und erzeugt daneben einen Wrapper, der das Zielskript startet und stdout/stderr inklusive `Write-Host` in lokale und zentrale Logs schreibt.

- GPO erstellen oder aktualisieren
- Zielskript unveraendert nach SYSVOL kopieren
- Wrapper-Skript fuer Logging und Ausfuehrung erzeugen
- das Modul optional mit nach SYSVOL kopieren
- Scheduled Task per Group Policy Preferences schreiben
- GPO-Version und Scheduled-Tasks-Extension setzen
- optional zentrale Logfreigabe erstellen
- optional deaktivierte GPO-Links fuer Pilot-OUs anlegen
- Cleanup-GPO erzeugen, die den Client-Task wieder entfernt
- lokales und zentrales Client-Logging ohne Aenderung am Zielskript

## Struktur

```text
skeleton/
  gpo-skeleton/
    gpo-skeleton.psd1
    gpo-skeleton.psm1
  skeleton-skills.md
  .github/
    workflows/
      release.yml
```

## Admin: Deployment-GPO erstellen

PowerShell als Administrator auf einem DC oder einem Admin-Host mit GPMC/RSAT starten.

```powershell
Import-Module .\gpo-skeleton\gpo-skeleton.psd1

Install-SkeletonGpo `
  -ProjectName 'UefiSentinalSecureBoot2023' `
  -DomainName 'example.local' `
  -TargetScriptPath '.\my-target-script.ps1'
```

Das erzeugt standardmaessig:

```text
GPO:                 UefiSentinalSecureBoot2023-Deploy
Cleanup-GPO:         UefiSentinalSecureBoot2023-Cleanup
Scheduled Task:      UefiSentinalSecureBoot2023-Deploy
SYSVOL script folder UefiSentinalSecureBoot2023
Wrapper script:       Invoke-GpoSkeletonTarget.ps1
Client logs:         C:\ProgramData\UefiSentinalSecureBoot2023
Central logs:        C:\ProgramData\.UefiSentinalSecureBoot2023\GpoCentralLogs
SMB share:           .UefiSentinalSecureBoot2023GpoLogs$
```

Eine deaktivierte Verknuepfung fuer eine Pilot-OU anlegen:

```powershell
Install-SkeletonGpo `
  -ProjectName 'MyProject' `
  -DomainName 'example.local' `
  -TargetScriptPath '.\my-target-script.ps1' `
  -TargetDn 'OU=Clients,DC=example,DC=local' `
  -CreateDisabledLink
```

Zusatzparameter an das Zielskript uebergeben:

```powershell
Install-SkeletonGpo `
  -ProjectName 'MyProject' `
  -TargetScriptPath '.\my-target-script.ps1' `
  -TargetScriptParameters @{
    Mode = 'Audit'
    Force = $true
  }
```

Wenn zentrale Logs aktiv sind, wird automatisch `-CentralLogDirectory <UNC>` an den Wrapper uebergeben.
Das Zielskript bekommt diesen Parameter nicht, ausser du setzt ihn explizit in `-TargetScriptParameters`.

## Deploy-Skript

Die gewuenschte Arbeitsweise ist: Zielskript und `deploy.ps1` liegen im gleichen Ordner auf dem DC. Das Deploy-Skript referenziert das Zielskript und ruft das Modul auf.

```powershell
#requires -RunAsAdministrator

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$DomainName
)

Import-Module gpo-skeleton -ErrorAction Stop

Install-SkeletonGpo `
  -ProjectName 'MyProject' `
  -DomainName $DomainName `
  -TargetScriptPath (Join-Path $PSScriptRoot 'my-target-script.ps1')
```

Weitere Agent-Instruktionen stehen in `skeleton-skills.md`.

## GPO entfernen

```powershell
Import-Module .\gpo-skeleton\gpo-skeleton.psd1

Remove-SkeletonGpo -ProjectName 'MyProject' -DomainName 'example.local' -Confirm:$false
```

Der Remove-Befehl erstellt standardmaessig eine Cleanup-GPO und verlinkt sie dort, wo die Deploy-GPO aktiv verlinkt war.
Diese Cleanup-GPO sollte lange genug verlinkt bleiben, damit Clients den Scheduled Task entfernen.

Optionen:

```powershell
Remove-SkeletonGpo -ProjectName 'MyProject' -SkipCleanupGpo -Confirm:$false
Remove-SkeletonGpo -ProjectName 'MyProject' -KeepCentralLogs -Confirm:$false
```

## Release

Der Workflow `.github/workflows/release.yml` wird manuell gestartet und akzeptiert `patch`, `minor` oder `major`.
Er aktualisiert `ModuleVersion`, validiert das Manifest, committet die Version, taggt `v<version>`, publisht nach PowerShell Gallery und erzeugt ein GitHub Release.

Erwartetes GitHub Secret:

```text
PSGALLERY_API_KEY
```
