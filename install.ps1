# install.ps1 — relay-lite on Windows: make sure WSL2 + Ubuntu exist, then run
# the Linux installer inside it. Run from PowerShell in this folder:
#
#     Set-ExecutionPolicy -Scope Process Bypass; .\install.ps1
#
# If WSL was not installed, Windows needs a reboot after the first step; run
# this script again afterwards and it carries on. Everything else (the
# Cloudflare token prompt, the deploy, the service) happens in the Linux side.
$ErrorActionPreference = 'Stop'
$distro = 'Ubuntu'

function Have-Wsl { try { wsl.exe --status *> $null; return $LASTEXITCODE -eq 0 } catch { return $false } }

if (-not (Have-Wsl)) {
  Write-Host "==> Installing WSL2 with $distro (this needs a reboot when it finishes)"
  wsl.exe --install -d $distro
  Write-Host "Reboot, open $distro once to create your Linux user, then run this script again."
  exit 0
}
$list = (wsl.exe -l -q) -replace "`0", '' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($list -notcontains $distro) {
  Write-Host "==> Installing the $distro distro"
  wsl.exe --install -d $distro
  Write-Host "Open $distro once to create your Linux user, then run this script again."
  exit 0
}

# The one manual step happens in a browser: open the token page now so it is
# ready when the installer asks (skipped if install.conf already holds one).
if (-not (Test-Path (Join-Path (Get-Location).Path 'install.conf'))) {
  Write-Host "==> The installer will ask for a Cloudflare API token. Opening the page where you create it."
  Write-Host "    Custom token, three Account permissions: Workers Scripts Edit, D1 Edit, Account Settings Read."
  Write-Host "    Full steps: SETUP.md in this folder."
  Start-Process 'https://dash.cloudflare.com/profile/api-tokens'
}

# Where this folder is, as WSL sees it.
$here = (Get-Location).Path
$wslHere = (wsl.exe -d $distro -e wslpath -a ($here -replace '\\', '/')).Trim()
Write-Host "==> Running the installer inside $distro at $wslHere"
wsl.exe -d $distro -e bash -lc "cd '$wslHere' && chmod +x install.sh relay-lite.sh && ./install.sh"
