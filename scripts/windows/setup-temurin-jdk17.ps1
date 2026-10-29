[CmdletBinding()]
param(
  [switch]$Build
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Find-Temurin17Home {
  $searchRoots = @(
    (Join-Path $env:ProgramFiles "Eclipse Adoptium")
  )

  $programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
  if ($programFilesX86) {
    $searchRoots += Join-Path $programFilesX86 "Eclipse Adoptium"
  }

  $candidates = foreach ($root in $searchRoots | Select-Object -Unique) {
    if (Test-Path -LiteralPath $root) {
      Get-ChildItem -LiteralPath $root -Directory -Filter "jdk-17*" -ErrorAction SilentlyContinue
    }
  }

  foreach ($candidate in $candidates | Sort-Object LastWriteTime -Descending) {
    $javaExe = Join-Path $candidate.FullName "bin\java.exe"
    if (Test-Path -LiteralPath $javaExe) {
      $versionText = (& $javaExe -version 2>&1 | Select-Object -First 1).ToString()
      if ($versionText -match 'version "17(\.|\")') {
        return $candidate.FullName
      }
    }
  }

  return $null
}

$jdkHome = Find-Temurin17Home
if (-not $jdkHome) {
  $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
  if (-not $winget) {
    throw "winget was not found. Install Microsoft App Installer and run this script again."
  }

  Write-Host "Installing Eclipse Temurin JDK 17..." -ForegroundColor Cyan
  & $winget.Source install `
    --id EclipseAdoptium.Temurin.17.JDK `
    --exact `
    --source winget `
    --scope machine `
    --silent `
    --accept-package-agreements `
    --accept-source-agreements `
    --disable-interactivity

  if ($LASTEXITCODE -ne 0) {
    throw "winget installation failed. Exit code: $LASTEXITCODE"
  }

  $jdkHome = Find-Temurin17Home
}

if (-not $jdkHome) {
  throw "Temurin JDK 17 was installed, but its installation directory was not found."
}

$jdkBin = Join-Path $jdkHome "bin"

# Persistent user variables are stored under HKCU\Environment.
[Environment]::SetEnvironmentVariable(
  "JAVA_HOME",
  $jdkHome,
  [EnvironmentVariableTarget]::User
)

$userPath = [Environment]::GetEnvironmentVariable(
  "Path",
  [EnvironmentVariableTarget]::User
)

$userPathEntries = @(
  $userPath -split ";" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ }
)

$normalizedJdkBin = $jdkBin.TrimEnd("\")
$userPathEntries = @(
  $userPathEntries |
    Where-Object {
      $_.TrimEnd("\") -ine $normalizedJdkBin -and
      $_.TrimEnd("\") -ine "%JAVA_HOME%\bin"
    }
)

$newUserPath = (@($jdkBin) + $userPathEntries) -join ";"
[Environment]::SetEnvironmentVariable(
  "Path",
  $newUserPath,
  [EnvironmentVariableTarget]::User
)

# Update this PowerShell process so Java is available immediately.
$env:JAVA_HOME = $jdkHome
$currentPathEntries = @(
  $env:Path -split ";" |
    Where-Object { $_ -and $_.TrimEnd("\") -ine $normalizedJdkBin }
)
$env:Path = (@($jdkBin) + $currentPathEntries) -join ";"

Write-Host "JAVA_HOME=$jdkHome" -ForegroundColor Green
& (Join-Path $jdkBin "java.exe") -version
if ($LASTEXITCODE -ne 0) {
  throw "Java verification failed."
}

if ($Build) {
  $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
  $gradleRoot = Join-Path $repoRoot "apps\multiplatform"
  $gradleWrapper = Join-Path $gradleRoot "gradlew.bat"

  if (-not (Test-Path -LiteralPath $gradleWrapper)) {
    throw "Gradle wrapper was not found: $gradleWrapper"
  }

  Write-Host "Building the Paranode debug APK..." -ForegroundColor Cyan
  Push-Location $gradleRoot
  try {
    & $gradleWrapper assembleDebug
    if ($LASTEXITCODE -ne 0) {
      throw "Gradle assembleDebug failed. Exit code: $LASTEXITCODE"
    }
  }
  finally {
    Pop-Location
  }

  Write-Host "assembleDebug completed successfully." -ForegroundColor Green
}
else {
  Write-Host "Persistent settings are complete. New terminals will inherit JAVA_HOME automatically." -ForegroundColor Green
  Write-Host "Run this script with -Build to install, configure, and build in one step."
}
