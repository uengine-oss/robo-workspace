[CmdletBinding()]
param(
  [Parameter(Position=0)][ValidateSet('help','setup','sync','doctor','up','restart','status','logs','down','build')][string]$Command = 'help',
  [Parameter(Position=1)][ValidateSet('analyzer','architect-web','architect-electron')][string]$Profile = 'analyzer',
  [Parameter(Position=2)][ValidateSet('unpacked','installer')][string]$Variant = 'unpacked',
  [switch]$SkipBuild,
  [switch]$SkipFrontend,
  [switch]$NoElectron,
  [switch]$ForcePorts
)

$ErrorActionPreference = 'Stop'
$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ProjectRoot = if ($env:ROBO_PROJECT_ROOT) { $env:ROBO_PROJECT_ROOT } else { Join-Path (Split-Path $WorkspaceRoot -Parent) 'project' }
$RuntimeRoot = Join-Path $WorkspaceRoot '.robo'
$LogRoot = Join-Path $RuntimeRoot "logs\$Profile"
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
function Services {
  $items=@($Config.services | Where-Object { Has-Profile $_ })
  if ($NoElectron) { $items=@($items | Where-Object id -ne 'architect-electron') }
  return $items
}
function Repo-Path($Repo) { return Join-Path $ProjectRoot $Repo.path }
function Find-Repo([string]$Id) { return $Config.repositories | Where-Object id -eq $Id | Select-Object -First 1 }
function Is-ArchitectProfile { return $Profile -in @('architect-web','architect-electron') }

function Show-Help {
  Write-Host @'
Robo Workspace - setup and run the independent Robo repositories together

First-time setup:
  robo.cmd setup <profile>
  robo.cmd doctor <profile>

Run and stop:
  robo.cmd up <profile>
  robo.cmd restart <profile>
  robo.cmd status <profile>
  robo.cmd logs <profile>
  robo.cmd down <profile>

Port conflict recovery (also stops unrecorded listeners on profile ports):
  robo.cmd restart <profile> -SkipBuild -ForcePorts

Profiles:
  analyzer             Analyzer stack and UI (http://127.0.0.1:3000)
  architect-web        Architect stack and browser UI (http://127.0.0.1:5173)
  architect-electron   Architect stack and Electron desktop app

Electron packages:
  robo.cmd build architect-electron unpacked
  robo.cmd build architect-electron installer

Fast restart using existing build output:
  robo.cmd up architect-web -SkipBuild
  robo.cmd up architect-electron -SkipBuild

See README.md for explanations, a step-by-step tutorial, and troubleshooting.
'@
}

function Invoke-Checked([string]$File, [string[]]$Arguments, [string]$WorkingDirectory) {
  Push-Location $WorkingDirectory
  try { & $File @Arguments; if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE" } }
  finally { Pop-Location }
}

function Invoke-WithEnvironment([hashtable]$Variables, [scriptblock]$Action) {
  $original=@{}
  try {
    foreach ($name in $Variables.Keys) {
      $original[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
      [Environment]::SetEnvironmentVariable($name,$Variables[$name],'Process')
    }
    & $Action
  } finally {
    foreach ($name in $Variables.Keys) { [Environment]::SetEnvironmentVariable($name,$original[$name],'Process') }
  }
}

function Setup-Python([string]$Directory, [string]$Requirements) {
  $python = Join-Path $Directory '.venv\Scripts\python.exe'
  if (-not (Test-Path $python)) { Info "creating venv: $Directory"; Invoke-Checked 'python' @('-m','venv','.venv') $Directory }
  Info "installing Python dependencies: $Directory"
  Invoke-Checked $python @('-m','pip','install','-r',$Requirements) $Directory
}

function Setup-Node([string]$Directory) {
  Info "installing Node dependencies: $Directory"
  $action=if(Test-Path (Join-Path $Directory 'package-lock.json')){'ci'}else{'install'}
  Invoke-Checked 'npm.cmd' @($action) $Directory
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
  Setup-Node (Repo-Path (Find-Repo 'frontend'))
  if (Is-ArchitectProfile) {
    $architect=Repo-Path (Find-Repo 'architect')
    $openPencil=Join-Path $architect 'open-pencil'
    if(-not(Test-Path(Join-Path $openPencil '.git'))){
      Info 'initializing required Architect submodule: open-pencil'
      Invoke-Checked 'git' @('submodule','update','--init','--recursive','--','open-pencil') $architect
    }else{Pass 'open-pencil already initialized'}
    Info 'installing Architect Python dependencies'
    Invoke-Checked 'uv.exe' @('sync') $architect
    Setup-Node (Join-Path $architect 'frontend')
    Setup-Node (Join-Path $architect 'desktop')
  }
  $envPath=Join-Path $WorkspaceRoot '.env'
  if (-not (Test-Path $envPath)) { Copy-Item (Join-Path $WorkspaceRoot '.env.example') $envPath; Warn '.env created; fill the secret values before analysis' }
  Pass 'setup complete'; Write-Host "Next: robo.cmd doctor $Profile"
}

function Sync-Workspace {
  foreach ($repo in Repositories) {
    $path=Repo-Path $repo
    if (-not (Test-Path (Join-Path $path '.git'))) { Warn "$($repo.id): missing; run setup"; continue }
    $dirty=git -C $path status --porcelain; $branch=git -C $path branch --show-current
    if ($dirty) { Warn "$($repo.id): DIRTY, skipped"; continue }
    if ($branch -ne $repo.branch) { Warn "$($repo.id): branch=$branch, skipped"; continue }
    Info "syncing $($repo.id)"
    Invoke-Checked 'git' @('-C',$path,'fetch','origin',$repo.branch) $WorkspaceRoot
    Invoke-Checked 'git' @('-C',$path,'pull','--ff-only','origin',$repo.branch) $WorkspaceRoot
    Pass "$($repo.id): synced"
  }
  if(Is-ArchitectProfile){
    $openPencil=Join-Path(Repo-Path(Find-Repo 'architect'))'open-pencil\package.json'
    if(Test-Path $openPencil){Pass 'Architect open-pencil submodule'}else{Fail 'Architect open-pencil missing [ACTION] robo.cmd setup architect-electron';$failed=$true}
  }
}

function Test-Port([int]$Port) {
  try { return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop) } catch { return $false }
}

function Get-PortOwners([int]$Port) {
  return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique)
}

function Test-PortBindable([int]$Port) {
  $listener=$null
  try {
    $listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$Port)
    $listener.Start()
    return $true
  } catch { return $false }
  finally { if($listener){try{$listener.Stop()}catch{}} }
}

function Doctor-Workspace {
  $failed=$false
  $tools=@('git','python','java','node','npm.cmd')
  if (Is-ArchitectProfile) { $tools += 'uv.exe' }
  foreach ($tool in $tools | Select-Object -Unique) {
    if(Get-Command $tool -ErrorAction SilentlyContinue){Pass "$tool available"}else{Fail "$tool missing";$failed=$true}
  }
  foreach ($repo in Repositories) {
    if(Test-Path(Join-Path(Repo-Path $repo)'.git')){Pass "$($repo.id) repository"}else{Fail "$($repo.id) missing [ACTION] robo.cmd setup $Profile";$failed=$true}
  }
  foreach ($service in Services) {
    $repo=Find-Repo $service.repo; $cwd=Join-Path(Repo-Path $repo)$service.cwd
    if($service.file -match '[/\\]'){
      $file=Join-Path $cwd $service.file
      if(-not(Test-Path $file)){Fail "$($service.id) executable missing: $file";$failed=$true}
    }
    if($service.port){
      if(Test-Port([int]$service.port)){
        $owners=(Get-PortOwners([int]$service.port)) -join ','
        Fail "$($service.id) port $($service.port) already in use by pid=$owners [ACTION] robo.cmd restart $Profile -SkipBuild -ForcePorts"
        $failed=$true
      }
      elseif(-not(Test-PortBindable([int]$service.port))){Fail "$($service.id) port $($service.port) cannot be bound (possibly Windows-reserved)";$failed=$true}
    }
  }
  if(-not(Test-Port 7687)){Fail 'Neo4j port 7687 is not listening';$failed=$true}else{Pass 'Neo4j port 7687'}
  if($failed){throw 'doctor found blocking problems'}
  Pass "$Profile is ready"
}

function Build-AnalyzerRemote {
  $frontend=Repo-Path(Find-Repo 'frontend')
  Info 'building Analyzer federation remote'
  Invoke-Checked 'npm.cmd' @('run','build:docker') $frontend
}

function Build-CoLocatedFrontend {
  $architect=Repo-Path(Find-Repo 'architect'); $frontend=Repo-Path(Find-Repo 'frontend')
  Info 'building Architect host and co-locating Analyzer remote'
  Invoke-WithEnvironment @{ROBO_ANALYZER_FRONTEND_DIR=$frontend} {
    Invoke-Checked 'node.exe' @('scripts/build-desktop-frontend.mjs') $architect
  }
}

function Build-Desktop {
  if($Profile -ne 'architect-electron'){throw 'build is supported only for architect-electron'}
  $architect=Repo-Path(Find-Repo 'architect'); $desktop=Join-Path $architect 'desktop'
  if(-not $SkipFrontend){Build-CoLocatedFrontend}else{Warn 'frontend build skipped; existing frontend/dist will be packaged'}
  Info 'building Electron TypeScript'
  Invoke-Checked 'npm.cmd' @('run','build') $desktop
  Info "packaging Electron: $Variant"
  $args=if($Variant -eq 'installer'){@('electron-builder')}else{@('electron-builder','--dir')}
  Invoke-Checked 'npx.cmd' $args $desktop
  $artifact=if($Variant -eq 'installer'){
    Get-ChildItem (Join-Path $desktop 'out\dist') -Filter 'Robo-Architect-Setup-*.exe' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
  }else{Join-Path $desktop 'out\dist\win-unpacked\Robo-Architect.exe'}
  if(-not $artifact -or -not(Test-Path $artifact)){throw 'packager completed but the expected artifact was not found'}
  Pass "artifact: $artifact"
}

function Prepare-ProfileArtifacts {
  if($SkipBuild){Warn 'artifact build skipped; existing build output will be used';return}
  if($Profile -eq 'architect-web'){Build-AnalyzerRemote}
  if($Profile -eq 'architect-electron'){Build-Desktop}
}

function Save-State($Processes) {
  New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
  @($Processes)|ConvertTo-Json -Depth 5|Set-Content -Encoding UTF8 $StatePath
}
function Load-State {
  if(-not(Test-Path $StatePath)){return @()}
  $state=Get-Content -Raw -Encoding UTF8 $StatePath|ConvertFrom-Json
  $state|ForEach-Object{$_}
}

function Get-ProcessByIdentity([int]$ProcessId,[string]$StartedAt,[double]$ToleranceSeconds=0.01) {
  if(-not $ProcessId -or -not $StartedAt){return $null}
  $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if(-not $process){return $null}
  try{
    $expected=[DateTimeOffset]::Parse($StartedAt).LocalDateTime
    if([Math]::Abs(($process.StartTime-$expected).TotalSeconds)-le $ToleranceSeconds){return $process}
  }catch{}
  return $null
}

function Get-OwnedProcesses($Entry) {
  $owned=@()
  $rootStartedAt=if($Entry.rootStartedAt){[string]$Entry.rootStartedAt}else{[string]$Entry.startedAt}
  if($Entry.rootPid){
    $root=Get-ProcessByIdentity ([int]$Entry.rootPid) $rootStartedAt
    if($root){$owned+=$root}
  }

  if($Entry.listenerPid -and $Entry.listenerStartedAt){
    $listener=Get-ProcessByIdentity ([int]$Entry.listenerPid) ([string]$Entry.listenerStartedAt)
    if($listener -and @($owned|Where-Object Id -eq $listener.Id).Count-eq 0){$owned+=$listener}
  }
  return @($owned)
}

function Get-OwnedProcess($Entry) {
  $owned=@(Get-OwnedProcesses $Entry)
  if($owned.Count-gt 0){return $owned[0]}
  return $null
}

function Stop-VerifiedProcessTree([string]$EntryId,[int]$ProcessId,[string]$StartedAt) {
  if(-not(Get-ProcessByIdentity $ProcessId $StartedAt)){return}
  Info "stopping $EntryId tree pid=$ProcessId"
  $taskkillOutput=@(& taskkill.exe /PID $ProcessId /T /F 2>&1)
  $taskkillExit=$LASTEXITCODE
  $deadline=(Get-Date).AddSeconds(10)
  while((Get-Date)-lt $deadline -and (Get-ProcessByIdentity $ProcessId $StartedAt)){
    Start-Sleep -Milliseconds 100
  }
  if(Get-ProcessByIdentity $ProcessId $StartedAt){
    $detail=($taskkillOutput|ForEach-Object{"$_"}) -join ' '
    throw "$EntryId pid=$ProcessId remained after taskkill exit=$taskkillExit output=$detail"
  }
}

function Stop-Owned {
  $entries=@(Load-State)
  foreach($entry in $entries){
    $owned=@(Get-OwnedProcesses $entry)
    if($owned.Count-gt 0){
      $identities=@($owned|ForEach-Object{[pscustomobject]@{id=$_.Id;startedAt=$_.StartTime.ToString('o')}})
      foreach($identity in $identities){Stop-VerifiedProcessTree $entry.id $identity.id $identity.startedAt}
    }
    elseif($entry.pid){Warn "$($entry.id) already exited; stale pid was not touched"}
  }
  Remove-Item $StatePath -ErrorAction SilentlyContinue
  Pass "$Profile stopped"
}

function Wait-Service($Service,[System.Diagnostics.Process]$Process) {
  if($Service.health){
    $deadline=(Get-Date).AddSeconds([int]$Service.timeout)
    while((Get-Date)-lt$deadline){
      if($Process.HasExited){return $false}
      try{$response=Invoke-WebRequest -UseBasicParsing -Uri $Service.health -TimeoutSec 3;if($response.StatusCode-ge 200-and$response.StatusCode-lt 400){return $true}}catch{}
      Start-Sleep -Seconds 2
    }
    return $false
  }
  $delay=if($Service.readyDelay){[int]$Service.readyDelay}else{3}
  $deadline=(Get-Date).AddSeconds($delay)
  while((Get-Date)-lt$deadline){if($Process.HasExited){return $false};Start-Sleep -Milliseconds 500}
  return -not $Process.HasExited
}

function Get-PortOwner([int]$Port) {
  return Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue|Select-Object -First 1 -ExpandProperty OwningProcess
}

function Stop-ProfilePortListeners {
  foreach($service in Services|Where-Object{$_.port}){
    $port=[int]$service.port
    foreach($owner in @(Get-PortOwners $port)){
      $process=Get-Process -Id ([int]$owner) -ErrorAction SilentlyContinue
      $name=if($process){$process.ProcessName}else{'unknown'}
      Warn "force stopping $($service.id) port $port listener pid=$owner process=$name"
      & taskkill.exe /PID $owner /T /F|Out-Null
    }
    $deadline=(Get-Date).AddSeconds(10)
    while((Get-Date)-lt $deadline -and (Test-Port $port)){Start-Sleep -Milliseconds 200}
    if(Test-Port $port){throw "$($service.id) port $port remains in use after forced cleanup"}
  }
}

function Expand-ServiceValue([string]$Value) {
  $architect=if(Find-Repo 'architect'){Repo-Path(Find-Repo 'architect')}else{''}
  return $Value.Replace('${ARCHITECT_DIR}',$architect)
}

function Start-Workspace {
  if(Test-Path $StatePath){
    $existing=@(Load-State)
    $stale=@($existing|Where-Object{-not(Get-OwnedProcess $_)})
    if($existing.Count-gt 0-and$stale.Count-eq 0){
      Pass "$Profile is already running"
      Write-Host "Use: robo.cmd restart $Profile -SkipBuild"
      return
    }
    Warn "stale $Profile state detected ($($stale.Count) exited service); cleaning owned processes before restart"
    Stop-Owned
  }
  Doctor-Workspace
  Prepare-ProfileArtifacts
  New-Item -ItemType Directory -Force -Path $LogRoot|Out-Null
  $started=@()
  try{
    foreach($service in Services){
      $repo=Find-Repo $service.repo; $cwd=Join-Path(Repo-Path $repo)$service.cwd
      $file=if($service.file-match'[/\\]'){Join-Path $cwd $service.file}else{$service.file}
      $original=@{}
      if($service.env){foreach($property in $service.env.PSObject.Properties){$original[$property.Name]=[Environment]::GetEnvironmentVariable($property.Name,'Process');$value=Expand-ServiceValue([string]$property.Value);[Environment]::SetEnvironmentVariable($property.Name,$value,'Process')}}
      $out=Join-Path $LogRoot "$($service.id).out.log";$err=Join-Path $LogRoot "$($service.id).err.log"
      Info "starting $($service.id)"
      try{
        $windowStyle=if($service.windowStyle){[string]$service.windowStyle}else{'Hidden'}
        $startOptions=@{FilePath=$file;WorkingDirectory=$cwd;RedirectStandardOutput=$out;RedirectStandardError=$err;WindowStyle=$windowStyle;PassThru=$true}
        $serviceArgs=@($service.args|Where-Object{$_ -ne $null})
        if($serviceArgs.Count-gt 0){$startOptions.ArgumentList=$serviceArgs}
        $process=Start-Process @startOptions
      }
      finally{if($service.env){foreach($property in $service.env.PSObject.Properties){[Environment]::SetEnvironmentVariable($property.Name,$original[$property.Name],'Process')}}}
      $rootStartedAt=$process.StartTime.ToString('o')
      $entry=[pscustomobject]@{id=$service.id;pid=$process.Id;rootPid=$process.Id;startedAt=$rootStartedAt;rootStartedAt=$rootStartedAt;listenerPid=$null;listenerStartedAt=$null;health=$service.health;port=$service.port}
      $started+=$entry;Save-State $started
      if(-not(Wait-Service $service $process)){throw "$($service.id) failed readiness; see $err"}
      if($service.port){
        $owner=Get-PortOwner([int]$service.port)
        if($owner){
          $listener=Get-Process -Id ([int]$owner) -ErrorAction Stop
          $entry.pid=$owner
          $entry.listenerPid=$owner
          $entry.listenerStartedAt=$listener.StartTime.ToString('o')
          Save-State $started
        }
      }
      $ready=if($service.health){$service.health}else{"process pid=$($entry.pid)"}
      Pass "$($service.id) ready: $ready"
    }
  }catch{Fail $_;Stop-Owned;throw}
  Pass "$Profile started"
  if($Profile-eq'analyzer'){Write-Host 'Open http://127.0.0.1:3000'}
  elseif($Profile-eq'architect-web'){Write-Host 'Open http://127.0.0.1:5173'}
  elseif($NoElectron){Write-Host 'Shared backends are ready; run the packaged app or rerun without -NoElectron.'}
  else{Write-Host 'Electron is running. Use robo.cmd down architect-electron to stop the owned stack.'}
}

function Restart-Workspace {
  if(Test-Path $StatePath){Stop-Owned}
  if($ForcePorts){Stop-ProfilePortListeners}
  Start-Workspace
}

function Show-Status {
  $state=@(Load-State)
  if($state.Count-eq 0){Warn "$Profile is not managed as running";return}
  foreach($entry in $state){$process=Get-OwnedProcess $entry;if($process){Pass "$($entry.id) pid=$($process.Id) running"}else{Fail "$($entry.id) exited (stale state)"}}
}
function Show-Logs {
  if(-not(Test-Path $LogRoot)){Warn 'no logs';return}
  Write-Host "Logs: $LogRoot"
  foreach($file in Get-ChildItem $LogRoot -File|Sort-Object Name){Write-Host "`n--- $($file.Name) ---";Get-Content $file.FullName -Tail 20}
}

if($env:ROBO_WORKSPACE_TEST_MODE-ne'1'){
  switch($Command){
    'help'{Show-Help}
    'setup'{Setup-Workspace}
    'sync'{Sync-Workspace}
    'doctor'{Doctor-Workspace}
    'up'{Start-Workspace}
    'restart'{Restart-Workspace}
    'status'{Show-Status}
    'logs'{Show-Logs}
    'down'{Stop-Owned;if($ForcePorts){Stop-ProfilePortListeners}}
    'build'{Build-Desktop}
  }
}
