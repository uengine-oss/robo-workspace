[CmdletBinding()]
param(
  [Parameter(Position=0)][ValidateSet('setup','sync','doctor','up','status','logs','down')][string]$Command = 'status',
  [Parameter(Position=1)][ValidateSet('analyzer')][string]$Profile = 'analyzer'
)

$ErrorActionPreference = 'Stop'
$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ProjectRoot = if ($env:ROBO_PROJECT_ROOT) { $env:ROBO_PROJECT_ROOT } else { Join-Path (Split-Path $WorkspaceRoot -Parent) 'project' }
$RuntimeRoot = Join-Path $WorkspaceRoot '.robo'
$LogRoot = Join-Path $RuntimeRoot 'logs'
$StatePath = Join-Path $RuntimeRoot "$Profile-state.json"
$Config = Get-Content -Raw -Encoding UTF8 (Join-Path $WorkspaceRoot 'workspace.json') | ConvertFrom-Json

function Import-WorkspaceEnvironment {
  $envPath = Join-Path $WorkspaceRoot '.env'
  if (-not (Test-Path $envPath)) { return }
  foreach ($line in Get-Content -Encoding UTF8 $envPath) {
    if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+)=(.*)$') { continue }
    $name=$Matches[1].Trim(); $value=$Matches[2].Trim()
    if (-not [Environment]::GetEnvironmentVariable($name,'Process')) { [Environment]::SetEnvironmentVariable($name,$value,'Process') }
  }
  foreach ($name in @('URI','USER','PASSWORD','DATABASE')) {
    $source=[Environment]::GetEnvironmentVariable("ROBO_NEO4J_$name",'Process')
    if ($source -and -not [Environment]::GetEnvironmentVariable("NEO4J_$name",'Process')) { [Environment]::SetEnvironmentVariable("NEO4J_$name",$source,'Process') }
  }
}
Import-WorkspaceEnvironment

function Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Pass([string]$Message) { Write-Host "[ OK ] $Message" -ForegroundColor Green }
function Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Fail([string]$Message) { Write-Host "[FAIL] $Message" -ForegroundColor Red }
function Has-Profile($Item) { return @($Item.profiles) -contains $Profile }
function Repositories { return @($Config.repositories | Where-Object { Has-Profile $_ }) }
function Services { return @($Config.services | Where-Object { Has-Profile $_ }) }
function Repo-Path($Repo) { return Join-Path $ProjectRoot $Repo.path }
function Find-Repo([string]$Id) { return $Config.repositories | Where-Object id -eq $Id | Select-Object -First 1 }

function Invoke-Checked([string]$File, [string[]]$Arguments, [string]$WorkingDirectory) {
  Push-Location $WorkingDirectory
  try { & $File @Arguments; if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE" } }
  finally { Pop-Location }
}

function Setup-Python([string]$Directory, [string]$Requirements) {
  $python = Join-Path $Directory '.venv\Scripts\python.exe'
  if (-not (Test-Path $python)) { Info "creating venv: $Directory"; Invoke-Checked 'python' @('-m','venv','.venv') $Directory }
  Info "installing Python dependencies: $Directory"
  Invoke-Checked $python @('-m','pip','install','-r',$Requirements) $Directory
}

function Setup-Workspace {
  New-Item -ItemType Directory -Force -Path $ProjectRoot | Out-Null
  foreach ($repo in Repositories) {
    $path = Repo-Path $repo
    if (-not (Test-Path (Join-Path $path '.git'))) {
      Info "cloning $($repo.id)"
      Invoke-Checked 'git' @('clone','--branch',$repo.branch,$repo.url,$path) $ProjectRoot
    } else { Pass "$($repo.id) already exists" }
  }
  Setup-Python (Repo-Path (Find-Repo 'analyzer')) 'requirements.txt'
  Setup-Python (Repo-Path (Find-Repo 'catalog')) 'requirements.txt'
  Setup-Python (Join-Path (Repo-Path (Find-Repo 'fabric')) 'backend') 'requirements.txt'
  $frontend = Repo-Path (Find-Repo 'frontend')
  Info 'installing frontend dependencies'
  $npmAction = if (Test-Path (Join-Path $frontend 'package-lock.json')) { 'ci' } else { 'install' }
  Invoke-Checked 'npm.cmd' @($npmAction) $frontend
  $envPath=Join-Path $WorkspaceRoot '.env'
  if (-not (Test-Path $envPath)) { Copy-Item (Join-Path $WorkspaceRoot '.env.example') $envPath; Warn '.env created; fill the secret values before analysis' }
  Pass 'setup complete'; Write-Host 'Next: robo.cmd doctor analyzer'
}

function Sync-Workspace {
  foreach ($repo in Repositories) {
    $path = Repo-Path $repo
    if (-not (Test-Path (Join-Path $path '.git'))) { Warn "$($repo.id): missing; run setup"; continue }
    $dirty = git -C $path status --porcelain
    $branch = git -C $path branch --show-current
    if ($dirty) { Warn "$($repo.id): DIRTY, skipped"; continue }
    if ($branch -ne $repo.branch) { Warn "$($repo.id): branch=$branch, skipped"; continue }
    Info "syncing $($repo.id)"
    Invoke-Checked 'git' @('-C',$path,'fetch','origin',$repo.branch) $WorkspaceRoot
    Invoke-Checked 'git' @('-C',$path,'pull','--ff-only','origin',$repo.branch) $WorkspaceRoot
    Pass "$($repo.id): synced"
  }
}

function Test-Port([int]$Port) {
  try { return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop) } catch { return $false }
}

function Doctor-Workspace {
  $failed = $false
  foreach ($tool in @('git','python','java','node','npm.cmd')) {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { Pass "$tool available" } else { Fail "$tool missing"; $failed=$true }
  }
  foreach ($repo in Repositories) {
    if (Test-Path (Join-Path (Repo-Path $repo) '.git')) { Pass "$($repo.id) repository" } else { Fail "$($repo.id) missing [ACTION] robo.cmd setup $Profile"; $failed=$true }
  }
  foreach ($service in Services) {
    $repo = Find-Repo $service.repo; $cwd = Join-Path (Repo-Path $repo) $service.cwd; $file = Join-Path $cwd $service.file
    if (($service.file -match '[/\\]') -and -not (Test-Path $file)) { Fail "$($service.id) executable missing: $file"; $failed=$true }
    if (Test-Port $service.port) { Fail "$($service.id) port $($service.port) already in use"; $failed=$true }
  }
  if (-not (Test-Port 7687)) { Fail 'Neo4j port 7687 is not listening'; $failed=$true } else { Pass 'Neo4j port 7687' }
  if ($failed) { throw 'doctor found blocking problems' }
  Pass "$Profile is ready"
}

function Save-State($Processes) {
  New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
  @($Processes) | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $StatePath
}
function Load-State {
  if (-not (Test-Path $StatePath)) { return }
  $state = Get-Content -Raw -Encoding UTF8 $StatePath | ConvertFrom-Json
  $state | ForEach-Object { $_ }
}

function Stop-Owned {
  foreach ($entry in Load-State) {
    if (Get-Process -Id $entry.pid -ErrorAction SilentlyContinue) {
      Info "stopping $($entry.id) pid=$($entry.pid)"
      & taskkill.exe /PID $entry.pid /T /F | Out-Null
    }
  }
  Remove-Item $StatePath -ErrorAction SilentlyContinue
  Pass "$Profile stopped"
}

function Wait-Health($Service) {
  $deadline = (Get-Date).AddSeconds([int]$Service.timeout)
  while ((Get-Date) -lt $deadline) {
    try { $response=Invoke-WebRequest -UseBasicParsing -Uri $Service.health -TimeoutSec 3; if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) { return $true } } catch {}
    Start-Sleep -Seconds 2
  }
  return $false
}

function Get-PortOwner([int]$Port) {
  return Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty OwningProcess
}

function Start-Workspace {
  if (Test-Path $StatePath) { throw 'state already exists; run down or status first' }
  Doctor-Workspace
  New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
  $started=@()
  try {
    foreach ($service in Services) {
      $repo=Find-Repo $service.repo; $cwd=Join-Path (Repo-Path $repo) $service.cwd
      $file=if($service.file -match '[/\\]'){Join-Path $cwd $service.file}else{$service.file}
      if ($service.env) { foreach($property in $service.env.PSObject.Properties){[Environment]::SetEnvironmentVariable($property.Name,[string]$property.Value,'Process')} }
      $out=Join-Path $LogRoot "$($service.id).out.log"; $err=Join-Path $LogRoot "$($service.id).err.log"
      Info "starting $($service.id)"
      $process=Start-Process -FilePath $file -ArgumentList @($service.args) -WorkingDirectory $cwd -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
      if ($service.env) { foreach($property in $service.env.PSObject.Properties){[Environment]::SetEnvironmentVariable($property.Name,$null,'Process')} }
      $entry=[pscustomobject]@{id=$service.id;pid=$process.Id;startedAt=(Get-Date).ToString('o');health=$service.health}
      $started += $entry; Save-State $started
      if (-not (Wait-Health $service)) { throw "$($service.id) failed health check; see $err" }
      $owner = Get-PortOwner $service.port
      if ($owner) { $entry.pid = $owner; Save-State $started }
      Pass "$($service.id) healthy: $($service.health)"
    }
  } catch { Fail $_; Stop-Owned; throw }
  Pass "$Profile started"; Write-Host 'Open http://127.0.0.1:3000'
}

function Show-Status {
  $state=Load-State
  if ($state.Count -eq 0) { Warn "$Profile is not managed as running"; return }
  foreach($entry in $state){$process=Get-Process -Id $entry.pid -ErrorAction SilentlyContinue; if($process){Pass "$($entry.id) pid=$($entry.pid) running"}else{Fail "$($entry.id) pid=$($entry.pid) exited"}}
}
function Show-Logs { if(-not(Test-Path $LogRoot)){Warn 'no logs';return}; Write-Host "Logs: $LogRoot"; foreach($file in Get-ChildItem $LogRoot -File | Sort-Object Name){Write-Host "`n--- $($file.Name) ---"; Get-Content $file.FullName -Tail 20} }

switch ($Command) {
  'setup' { Setup-Workspace }
  'sync' { Sync-Workspace }
  'doctor' { Doctor-Workspace }
  'up' { Start-Workspace }
  'status' { Show-Status }
  'logs' { Show-Logs }
  'down' { Stop-Owned }
}
