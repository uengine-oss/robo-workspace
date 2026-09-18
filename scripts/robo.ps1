[CmdletBinding()]
param(
  [Parameter(Position=0)][ValidateSet('help','setup','sync','doctor','env','up','restart','status','logs','down','build','release')][string]$Command = 'help',
  [Parameter(Position=1)][ValidateSet('analyzer','architect-web','architect-electron','all')][string]$Profile = 'analyzer',
  [Parameter(Position=2)][ValidateSet('unpacked','installer')][string]$Variant = 'unpacked',
  [Alias('Service')][string]$ServiceId,
  [switch]$Build,
  [switch]$SkipBuild,
  [switch]$SkipFrontend,
  [switch]$NoElectron,
  [switch]$ForcePorts
)

$ErrorActionPreference = 'Stop'
$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ProjectRoot = if ($env:ROBO_PROJECT_ROOT) { $env:ROBO_PROJECT_ROOT } else { Join-Path (Split-Path $WorkspaceRoot -Parent) 'project' }
$RuntimeRoot = if($env:ROBO_WORKSPACE_RUNTIME){[IO.Path]::GetFullPath($env:ROBO_WORKSPACE_RUNTIME)}else{Join-Path $WorkspaceRoot '.robo'}
$LogRoot = Join-Path $RuntimeRoot "logs\$Profile"
$StatePath = Join-Path $RuntimeRoot "$Profile-state.json"
$WorkspaceEnvPath = if($env:ROBO_WORKSPACE_ENV){[IO.Path]::GetFullPath($env:ROBO_WORKSPACE_ENV)}else{Join-Path $WorkspaceRoot '.env'}
$WorkspaceConfigPath = if($env:ROBO_WORKSPACE_CONFIG){[IO.Path]::GetFullPath($env:ROBO_WORKSPACE_CONFIG)}else{Join-Path $WorkspaceRoot 'workspace.json'}
$ReleaseEnvironmentConfigPath = Join-Path $WorkspaceRoot 'release-environment.json'
$Config = Get-Content -Raw -Encoding UTF8 $WorkspaceConfigPath | ConvertFrom-Json

function Read-EnvironmentFile([string]$Path) {
  $values=@{}
  if (-not (Test-Path $Path)) { return $values }
  foreach ($line in Get-Content -Encoding UTF8 $Path) {
    if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+)=(.*)$') { continue }
    $name=$Matches[1].Trim(); $value=$Matches[2].Trim()
    $values[$name]=$value
  }
  return $values
}

function Import-WorkspaceEnvironment([string]$Path=$WorkspaceEnvPath) {
  $values=Read-EnvironmentFile $Path
  foreach($name in $values.Keys){
    if(-not [Environment]::GetEnvironmentVariable($name,'Process')){
      [Environment]::SetEnvironmentVariable($name,$values[$name],'Process')
    }
  }

  # Shared Neo4j is a Workspace-owned contract. Repository .env files and
  # inherited shell values must not split integrated services across databases.
  foreach($suffix in @('URI','USER','PASSWORD','DATABASE')){
    $workspaceName="ROBO_NEO4J_$suffix"
    if(-not $values.ContainsKey($workspaceName)){continue}
    $value=[string]$values[$workspaceName]
    [Environment]::SetEnvironmentVariable($workspaceName,$value,'Process')
    [Environment]::SetEnvironmentVariable("NEO4J_$suffix",$value,'Process')
  }
  if($values.ContainsKey('ROBO_NEO4J_DATABASE')-and
     [string]$values['ROBO_NEO4J_DATABASE']-ieq'system'){
    throw 'ROBO_NEO4J_DATABASE must not be system'
  }
  if($values.ContainsKey('ROBO_NEO4J_DATABASE')){
    [Environment]::SetEnvironmentVariable('ANALYZER_NEO4J_DATABASE',[string]$values['ROBO_NEO4J_DATABASE'],'Process')
  }
}
Import-WorkspaceEnvironment

if($Profile-eq'all'-and$Command-ne'down'){
  throw "'all' is not an execution profile. Use analyzer, architect-web, or architect-electron. Only 'robo.cmd down all' is supported."
}

function Get-WorkspaceNeo4jConfigurationErrors([string]$Path=$WorkspaceEnvPath) {
  if(-not(Test-Path $Path)){return @("Workspace environment file missing: $Path")}
  $values=Read-EnvironmentFile $Path
  $errors=@()
  foreach($suffix in @('URI','USER','PASSWORD','DATABASE')){
    $name="ROBO_NEO4J_$suffix"
    if(-not $values.ContainsKey($name)-or[String]::IsNullOrWhiteSpace([string]$values[$name])){
      $errors+="$name is missing or empty in $Path"
    }
  }
  if($values.ContainsKey('ROBO_NEO4J_DATABASE')-and
     [string]$values['ROBO_NEO4J_DATABASE']-ieq'system'){
    $errors+='ROBO_NEO4J_DATABASE must not be system'
  }
  return @($errors)
}

function Assert-WorkspaceNeo4jConfiguration {
  $errors=@(Get-WorkspaceNeo4jConfigurationErrors)
  if($errors.Count-gt 0){throw ($errors-join '; ')}
}

function Get-ReleaseEnvironmentContract {
  if(-not(Test-Path -LiteralPath $ReleaseEnvironmentConfigPath)){
    throw "Release environment contract missing: $ReleaseEnvironmentConfigPath"
  }
  $contract=Get-Content -LiteralPath $ReleaseEnvironmentConfigPath -Raw -Encoding UTF8|ConvertFrom-Json
  if($contract.schemaVersion-ne1-or-not$contract.scopes){
    throw 'Unsupported release environment contract'
  }
  return $contract
}

function Get-ReleaseEnvironmentConfigurationErrors([string]$Path=$WorkspaceEnvPath) {
  if(-not(Test-Path -LiteralPath $Path)){return @("Workspace environment file missing: $Path")}
  $values=Read-EnvironmentFile $Path
  $contract=Get-ReleaseEnvironmentContract
  $errors=@()
  foreach($name in @($contract.required)){
    if(-not$values.ContainsKey([string]$name)-or
       [String]::IsNullOrWhiteSpace([string]$values[[string]$name])){
      $errors+="Required packaged runtime value is missing or empty: $name"
    }
  }
  foreach($name in @($contract.credentialNames)){
    if(-not$values.ContainsKey([string]$name)){continue}
    $value=[string]$values[[string]$name]
    if(@($contract.placeholderValues)-contains$value.ToLowerInvariant()){
      $errors+="Packaged runtime credential still uses a placeholder: $name"
    }
  }
  # 포장할 때는 "값이 있나" 만으로 부족하다 — "맞는 값인가" 도 본다.
  #
  # 비어 있는지와 placeholder 인지는 이미 본다. 그런데 **개발사 사내 주소가 그대로
  # 들어 있으면** 둘 다 통과한다 — 값이 있고 placeholder 도 아니기 때문이다. 그러면
  # 고객 환경에서 닿지 않는 엔드포인트가 납품 자산에 실려 나가고, 증상은 기동 시점이
  # 아니라 **첫 LLM 호출에서** 나온다.
  #
  # 포장되는 키만 본다(scope 에 안 잡히는 값은 안 나간다). 값은 출력하지 않는다 —
  # 여기 걸리는 키에는 자격증명도 섞인다.
  $scopedNames=New-Object System.Collections.Generic.HashSet[string]
  foreach($property in $contract.scopes.PSObject.Properties){
    foreach($key in @($values.Keys)){
      if(Test-ReleaseEnvironmentScopeKey ([string]$key) $property.Value){
        [void]$scopedNames.Add([string]$key)
      }
    }
  }
  foreach($entry in @($contract.forbiddenValuePatterns)){
    $pattern=[string]$entry.pattern
    if([String]::IsNullOrWhiteSpace($pattern)){continue}
    foreach($name in @($scopedNames|Sort-Object)){
      if([string]$values[$name] -match $pattern){
        $errors+=("Packaged runtime value points at a developer-internal target: "+
                  "$name (rule: $pattern — "+[string]$entry.reason+")")
      }
    }
  }
  return @($errors)
}

function Test-ReleaseEnvironmentScopeKey([string]$Name,$Scope) {
  if(@($Scope.excludeNames)-contains$Name){return $false}
  if(@($Scope.names)-contains$Name){return $true}
  foreach($prefix in @($Scope.prefixes)){
    if($Name.StartsWith([string]$prefix,[StringComparison]::Ordinal)){return $true}
  }
  return $false
}

function Write-Utf8NoBom([string]$Path,[string]$Content) {
  $parent=Split-Path $Path -Parent
  New-Item -ItemType Directory -Force -Path $parent|Out-Null
  [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}

function Write-ReleaseEnvironmentSnapshots([string]$RuntimeRoot) {
  $errors=@(Get-ReleaseEnvironmentConfigurationErrors)
  if($errors.Count){throw($errors-join'; ')}
  $values=Read-EnvironmentFile $WorkspaceEnvPath
  $contract=Get-ReleaseEnvironmentContract
  $snapshots=[ordered]@{}
  foreach($property in $contract.scopes.PSObject.Properties){
    $name=$property.Name
    $scope=$property.Value
    $relative=[string]$scope.file
    if([IO.Path]::IsPathRooted($relative)-or$relative.Contains('..')){
      throw "Release environment path must stay inside runtime: $relative"
    }
    $target=[IO.Path]::GetFullPath((Join-Path $RuntimeRoot $relative))
    # Same guard, spelled portably: hard-coding '\' makes this throw on every
    # non-Windows host, which is what kept the contract test Windows-only.
    $sep=[IO.Path]::DirectorySeparatorChar
    $runtimePrefix=[IO.Path]::GetFullPath($RuntimeRoot).TrimEnd($sep)+$sep
    if(-not$target.StartsWith($runtimePrefix,[StringComparison]::OrdinalIgnoreCase)){
      throw "Release environment path escapes runtime: $relative"
    }
    $lines=@()
    foreach($key in @($values.Keys|Sort-Object)){
      if($key-notmatch'^[A-Za-z_][A-Za-z0-9_]*$'){
        throw "Invalid environment variable name in $WorkspaceEnvPath"
      }
      if(Test-ReleaseEnvironmentScopeKey $key $scope){
        $value=[string]$values[$key]
        if($value.Contains("`r")-or$value.Contains("`n")){
          throw "Multiline environment value is not supported: $key"
        }
        $lines+="$key=$value"
      }
    }
    $content=if($lines.Count){"$($lines-join"`n")`n"}else{"# No configured values for this service.`n"}
    Write-Utf8NoBom $target $content
    $snapshots[$name]=[ordered]@{
      file=$relative.Replace('\','/')
      sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
  return $snapshots
}

function Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Pass([string]$Message) { Write-Host "[ OK ] $Message" -ForegroundColor Green }
function Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Fail([string]$Message) { Write-Host "[FAIL] $Message" -ForegroundColor Red }
function Has-Profile($Item) {
  $profiles=@($Item.profiles)
  if($Profile-eq'all'){return ($profiles -contains 'analyzer') -or ($profiles -contains 'architect-web')}
  return $profiles -contains $Profile
}
function Repositories { return @($Config.repositories | Where-Object { Has-Profile $_ }) }
function Services {
  $items=@($Config.services | Where-Object { Has-Profile $_ })
  if ($NoElectron) { $items=@($items | Where-Object id -ne 'architect-electron') }
  return $items
}
function Repo-Path($Repo) { return Join-Path $ProjectRoot $Repo.path }
function Find-Repo([string]$Id) { return $Config.repositories | Where-Object id -eq $Id | Select-Object -First 1 }
function Is-ArchitectProfile { return $Profile -in @('architect-web','architect-electron') }
function Analyzer-Root {
  if(Is-ArchitectProfile){return Join-Path(Repo-Path(Find-Repo 'architect'))'robo-analyzer\robo-data-analyzer'}
  return Repo-Path(Find-Repo 'analyzer')
}
function Catalog-Root {
  if(Is-ArchitectProfile){return Join-Path(Repo-Path(Find-Repo 'architect'))'robo-analyzer\robo-data-catalog'}
  return Repo-Path(Find-Repo 'catalog')
}
function Fabric-Root {
  if(Is-ArchitectProfile){return Join-Path(Repo-Path(Find-Repo 'architect'))'robo-analyzer\robo-data-fabric'}
  return Repo-Path(Find-Repo 'fabric')
}
function Analyzer-Frontend-Root {
  if(Is-ArchitectProfile){return Join-Path(Repo-Path(Find-Repo 'architect'))'robo-analyzer\robo-data-frontend'}
  return Repo-Path(Find-Repo 'frontend')
}

function Show-Help {
  Write-Host @'
Robo Workspace - setup, run, and package the independent Robo repositories on Windows

First-time setup:
  robo.cmd setup <profile>
  robo.cmd doctor <profile>

Run and stop:
  robo.cmd up <profile>
  robo.cmd restart <profile>
  robo.cmd status <profile>
  robo.cmd logs <profile>
  robo.cmd down <profile>
  robo.cmd down all

Control one service without touching the rest of the stack:
  robo.cmd restart analyzer -Service analyzer
  robo.cmd down architect-web -Service catalog
  robo.cmd up architect-web -Service catalog

Port conflict recovery (also stops unrecorded listeners on profile ports):
  robo.cmd restart <profile> -ForcePorts

Profiles:
  analyzer             Analyzer stack and UI (http://127.0.0.1:3000)
  architect-web        Architect stack and browser UI (http://127.0.0.1:15173)
  architect-electron   Architect stack and Electron desktop app
Electron packages:
  robo.cmd up architect-electron -Build
  robo.cmd build architect-electron unpacked
  robo.cmd build architect-electron unpacked -SkipFrontend
  robo.cmd build architect-electron installer
  robo.cmd release architect-electron

Development build output is reused by default. Build only when requested or missing:
  robo.cmd up architect-web
  robo.cmd up architect-web -Build

`build` creates a developer package. `release` bundles Docker images, the
Architect Python runtime, the frontend, the installer, manifest, and checksum.
The current launcher and release output are Windows-only; macOS packaging is
not yet implemented or verified.

See README.md and docs/environment.md for setup, environment, and release details.
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
  if(Test-Path (Join-Path $Directory 'package-lock.json')){
    try{Invoke-Checked 'npm.cmd' @('ci') $Directory}
    catch{
      Warn "npm ci could not replace an in-use dependency; restoring the lockfile-compatible tree with npm install"
      Invoke-Checked 'npm.cmd' @('install') $Directory
    }
  }else{Invoke-Checked 'npm.cmd' @('install') $Directory}
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
  if (Is-ArchitectProfile) {
    $architect=Repo-Path (Find-Repo 'architect')
    Info 'initializing Architect-pinned submodules: open-pencil and robo-analyzer'
    Invoke-Checked 'git' @('submodule','update','--init','--recursive','--','open-pencil','robo-analyzer/robo-data-analyzer','robo-analyzer/robo-data-catalog','robo-analyzer/robo-data-fabric','robo-analyzer/robo-data-frontend') $architect
    Setup-Python (Analyzer-Root) 'requirements.txt'
    Setup-Python (Catalog-Root) 'requirements.txt'
    Setup-Python (Fabric-Root) 'requirements.txt'
    Setup-Node (Analyzer-Frontend-Root)
    Info 'installing Architect Python dependencies'
    Invoke-Checked 'uv.exe' @('sync') $architect
    Setup-Node (Join-Path $architect 'frontend')
    Setup-Node (Join-Path $architect 'desktop')
  } else {
    Setup-Python (Analyzer-Root) 'requirements.txt'
    Setup-Python (Catalog-Root) 'requirements.txt'
    Setup-Python (Fabric-Root) 'requirements.txt'
    Setup-Node (Analyzer-Frontend-Root)
  }
  $envPath=Join-Path $WorkspaceRoot '.env'
  if (-not (Test-Path $envPath)) { Copy-Item (Join-Path $WorkspaceRoot '.env.example') $envPath; Warn '.env created; fill the secret values before analysis' }
  Pass 'setup complete'; Write-Host "Next: robo.cmd doctor $Profile"
}

function Prepare-ReleaseWorkspace {
  New-Item -ItemType Directory -Force -Path $ProjectRoot|Out-Null
  foreach($repo in Repositories){
    $path=Repo-Path $repo
    if(-not(Test-Path(Join-Path $path '.git'))){
      Info "cloning release source: $($repo.id)"
      Invoke-Checked 'git' @('clone','--branch',$repo.branch,$repo.url,$path) $ProjectRoot
      continue
    }
    $changes=@(& git -C $path status --porcelain --untracked-files=all)
    if($LASTEXITCODE-ne0-or$changes.Count){
      throw "release source must be clean before synchronization: $($repo.id)"
    }
    $branch=(& git -C $path branch --show-current).Trim()
    if($branch-ne$repo.branch){
      throw "release source must be on $($repo.branch): $($repo.id) is on $branch"
    }
    Info "synchronizing release source: $($repo.id)"
    Invoke-Checked 'git' @('-C',$path,'pull','--ff-only','origin',$repo.branch) $WorkspaceRoot
  }

  $architect=Repo-Path(Find-Repo 'architect')
  Info 'initializing Architect-pinned release submodules'
  Invoke-Checked 'git' @(
    'submodule','update','--init','--recursive','--',
    'open-pencil',
    'robo-analyzer/robo-data-analyzer',
    'robo-analyzer/robo-data-catalog',
    'robo-analyzer/robo-data-fabric',
    'robo-analyzer/robo-data-frontend'
  ) $architect

  if(-not(Test-Path -LiteralPath $WorkspaceEnvPath)){
    Copy-Item -LiteralPath (Join-Path $WorkspaceRoot '.env.example') -Destination $WorkspaceEnvPath
    Warn '.env created from internal release defaults'
  }

  foreach($nodeRoot in @(
    (Analyzer-Frontend-Root),
    (Join-Path $architect 'frontend'),
    (Join-Path $architect 'desktop')
  )){
    Setup-Node $nodeRoot
  }
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
    $architect=Repo-Path(Find-Repo 'architect')
    $submodules=@(
      'open-pencil',
      'robo-analyzer/robo-data-analyzer',
      'robo-analyzer/robo-data-catalog',
      'robo-analyzer/robo-data-fabric',
      'robo-analyzer/robo-data-frontend'
    )
    $missing=@($submodules|Where-Object{-not(Test-Path(Join-Path $architect "$_\.git"))})
    if($missing.Count){
      Warn "Architect submodules missing ($($missing-join ', ')); run setup $Profile"
    }else{
      Info 'updating Architect-pinned submodules to parent-recorded revisions'
      Invoke-Checked 'git' @('submodule','update','--init','--recursive','--') $architect
      Pass 'Architect pinned submodules synced'
    }
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

function Test-Neo4jAuthentication {
  foreach($name in @('NEO4J_URI','NEO4J_USER','NEO4J_PASSWORD')){
    if(-not[Environment]::GetEnvironmentVariable($name,'Process')){return $false}
  }
  $python=Join-Path(Analyzer-Root)'.venv\Scripts\python.exe'
  if(-not(Test-Path $python)){return $false}
  $probe="import os; from neo4j import GraphDatabase; d=GraphDatabase.driver(os.getenv('NEO4J_URI'), auth=(os.getenv('NEO4J_USER'), os.getenv('NEO4J_PASSWORD'))); d.verify_connectivity(); d.close()"
  & $python -c $probe 2>&1|Out-Null
  return $LASTEXITCODE-eq 0
}

function Show-SharedNeo4jTarget {
  $database=[Environment]::GetEnvironmentVariable('ROBO_NEO4J_DATABASE','Process')
  if($database){Pass "shared Neo4j database=$database (source=$WorkspaceEnvPath)"}
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
  if(Is-ArchitectProfile){
    $architect=Repo-Path(Find-Repo 'architect')
    foreach($relative in @('open-pencil','robo-analyzer\robo-data-analyzer','robo-analyzer\robo-data-catalog','robo-analyzer\robo-data-fabric','robo-analyzer\robo-data-frontend')){
      if(Test-Path(Join-Path $architect "$relative\.git")){Pass "Architect submodule $relative"}
      else{Fail "Architect submodule missing: $relative [ACTION] robo.cmd setup $Profile";$failed=$true}
    }
  }
  $neo4jConfigErrors=@(Get-WorkspaceNeo4jConfigurationErrors)
  foreach($errorMessage in $neo4jConfigErrors){Fail "$errorMessage [ACTION] configure robo-workspace\.env";$failed=$true}
  foreach ($service in Services) {
    $repo=Find-Repo $service.repo; $cwd=Join-Path(Repo-Path $repo)$service.cwd
    if($service.file -match '[/\\]'){
      $file=Join-Path $cwd $service.file
      if(-not(Test-Path $file)){Fail "$($service.id) executable missing: $file";$failed=$true}
    }
    if($service.port){
      if(Test-Port([int]$service.port)){
        $owners=(Get-PortOwners([int]$service.port)) -join ','
        Fail "$($service.id) port $($service.port) already in use by pid=$owners [ACTION] robo.cmd restart $Profile -ForcePorts"
        $failed=$true
      }
      elseif(-not(Test-PortBindable([int]$service.port))){Fail "$($service.id) port $($service.port) cannot be bound (possibly Windows-reserved)";$failed=$true}
    }
  }
  if(-not(Test-Port 7687)){Fail 'Neo4j port 7687 is not listening';$failed=$true}
  elseif($neo4jConfigErrors.Count-eq 0-and-not(Test-Neo4jAuthentication)){Fail 'Neo4j authentication failed [ACTION] verify ROBO_NEO4J_* in robo-workspace\.env';$failed=$true}
  elseif($neo4jConfigErrors.Count-eq 0){Pass 'Neo4j authentication'}
  if($failed){throw 'doctor found blocking problems'}
  Show-SharedNeo4jTarget
  Pass "$Profile is ready"
}

function Build-AnalyzerRemote {
  $frontend=Analyzer-Frontend-Root
  Info 'building Analyzer federation remote'
  Invoke-Checked 'npm.cmd' @('run','build:docker') $frontend
}

function Build-CoLocatedFrontend {
  $architect=Repo-Path(Find-Repo 'architect'); $frontend=Analyzer-Frontend-Root
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

function Get-GitCommit([string]$Directory) {
  $commit = (& git -C $Directory rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$') {
    throw "could not resolve Git commit: $Directory"
  }
  return $commit
}

function Assert-CleanReleaseRepository([string]$Label, [string]$Directory) {
  if (-not (Test-Path (Join-Path $Directory '.git'))) {
    throw "release repository missing: $Label ($Directory)"
  }
  $changes = @(& git -C $Directory status --porcelain --untracked-files=all)
  if ($LASTEXITCODE -ne 0) {
    throw "could not inspect release repository: $Label"
  }
  if ($changes.Count -gt 0) {
    throw "release requires a clean $Label repository; commit or remove generated files first"
  }
}

function Get-ReleaseSources {
  $architect = Repo-Path (Find-Repo 'architect')
  return [ordered]@{
    workspace  = $WorkspaceRoot
    architect  = $architect
    openPencil = Join-Path $architect 'open-pencil'
    analyzer   = Analyzer-Root
    catalog    = Catalog-Root
    fabric     = Fabric-Root
    frontend   = Analyzer-Frontend-Root
    parser     = Repo-Path (Find-Repo 'antlr')
    gateway    = Repo-Path (Find-Repo 'gateway')
    # 설치본의 graph 저장소. **개발 환경의 `ontological-dev` 컨테이너와 다른 것이다** —
    # 그쪽은 소스를 마운트해 컨테이너 안에서 빌드하고 엔트리포인트가 `sleep infinity` 라
    # 설치본에 못 쓴다. 여기서는 `docker/Dockerfile.runtime` 의 두 타깃을 굽는다.
    #
    # ⚠ 지금 이 저장소는 **fork**(`seongwonyang/ontological-db`)를 가리킨다.
    # `fix/neo4j-bolt-compat` 이 상류(`uengine-oss`)에 없고 푸시 권한도 없다(403 실측).
    # 상류 PR #2 가 병합되면 `workspace.json` 의 url 을 상류로 돌린다 — 납품 자산이
    # 개인 fork 에 의존하는 상태로 두지 않는다.
    ontological = Repo-Path (Find-Repo 'ontological')
  }
}

function Assert-ReleaseSourceState([System.Collections.IDictionary]$Sources) {
  foreach ($entry in $Sources.GetEnumerator()) {
    Assert-CleanReleaseRepository $entry.Key $entry.Value
  }

  $architect = [string]$Sources.architect
  $statusLines = @(& git -C $architect submodule status --recursive)
  if ($LASTEXITCODE -ne 0) {
    throw 'could not inspect Architect submodules'
  }
  $invalid = @($statusLines | Where-Object { $_ -notmatch '^ ' })
  if ($invalid.Count -gt 0) {
    throw "Architect submodules are not at parent-recorded commits: $($invalid -join '; ')"
  }
}

function Build-ReleaseTarget(
  [string]$Name,
  [string]$Tag,
  [string]$Context,
  [string]$Revision,
  [string]$Target
) {
  Info "building release image: $Name (target $Target)"
  Invoke-Checked 'docker.exe' @(
    'build',
    '--target', $Target,
    '--file', (Join-Path $Context 'docker\Dockerfile.runtime'),
    '--label', "org.opencontainers.image.revision=$Revision",
    '--label', "org.uengine.robo.component=$Name",
    '--tag', $Tag,
    $Context
  ) $WorkspaceRoot
}

function Build-ReleaseImage(
  [string]$Name,
  [string]$Tag,
  [string]$Context,
  [string]$Revision
) {
  Info "building release image: $Name"
  Invoke-Checked 'docker.exe' @(
    'build',
    '--label', "org.opencontainers.image.revision=$Revision",
    '--label', "org.uengine.robo.component=$Name",
    '--tag', $Tag,
    $Context
  ) $WorkspaceRoot
}

function Get-DockerImageId([string]$Tag) {
  $imageId = (& docker.exe image inspect $Tag --format '{{.Id}}').Trim()
  if ($LASTEXITCODE -ne 0 -or $imageId -notmatch '^sha256:[a-f0-9]{64}$') {
    throw "could not resolve Docker image identity: $Tag"
  }
  return $imageId
}

<#
.SYNOPSIS
  포장될 환경 값만 검사한다 — `release` 를 돌리기 전에.

.DESCRIPTION
  `doctor` 는 **개발 프로필**을 본다: 도구가 깔렸는지, 저장소가 있는지, Neo4j 가
  7687 에 떠 있는지. 설치본 릴리스에는 그중 마지막이 해당 없고(설치본은 자기
  컨테이너를 띄운다), 반대로 **"포장되는 값이 맞는가"** 는 `doctor` 가 보지 않는다.

  그 검사는 지금까지 `release` 안에만 있었다. 즉 **두 시간 걸리는 빌드를 시작한 뒤에야**
  환경 값이 틀린 것을 알았다. 이 명령은 그것만 따로 본다.

      robo.cmd env architect-electron
#>
function Check-ReleaseEnvironment {
  $errors=@(Get-ReleaseEnvironmentConfigurationErrors)
  foreach($message in $errors){Fail $message}
  if($errors.Count){throw 'release environment is not ready'}
  Pass 'packaged runtime environment is ready'
}

function Build-DesktopRelease {
  if ($Profile -ne 'architect-electron') {
    throw 'release is supported only for architect-electron'
  }

  Info 'preparing Workspace-only release inputs'
  Prepare-ReleaseWorkspace
  $environmentErrors=@(Get-ReleaseEnvironmentConfigurationErrors)
  if($environmentErrors.Count){throw($environmentErrors-join'; ')}

  Info 'checking immutable release inputs'
  $sources = Get-ReleaseSources
  Assert-ReleaseSourceState $sources
  Invoke-Checked 'docker.exe' @('info', '--format', '{{.ServerVersion}}') $WorkspaceRoot

  $commits = [ordered]@{}
  foreach ($entry in $sources.GetEnumerator()) {
    $commits[$entry.Key] = Get-GitCommit $entry.Value
  }
  $desktopPackage = Get-Content -Raw -Encoding UTF8 (Join-Path $sources.architect 'desktop\package.json') | ConvertFrom-Json
  $releaseId = '{0}-w{1}-a{2}' -f $desktopPackage.version, $commits.workspace.Substring(0, 8), $commits.architect.Substring(0, 8)
  $runtimeRoot = Join-Path $sources.architect 'desktop\resources\runtime'
  $releaseRoot = Join-Path $WorkspaceRoot "_releases\$releaseId"
  $imageArchive = Join-Path $runtimeRoot 'robo-images.tar'

  $images = [ordered]@{
    # graph 저장소는 **Ontological 이다. Neo4j 가 아니다.**
    # `neo4j:5.26.0` 은 Community 라 database 가 하나뿐이어서 설계 graph 와 분석 graph 를
    # 나눌 수 없었다(2026-09-17 실측: `CREATE DATABASE` 가 Unsupported). 분석은 대상
    # graph 를 비우고 다시 쓰므로, 나눌 수 없다는 것은 같은 graph 를 공유한다는 뜻이다.
    # 앱 코드는 안 바뀐다 — Bolt 게이트웨이가 Neo4j 프로토콜을 그대로 말한다.
    graphDb   = "uengine/ontological-db:$releaseId"
    graphBolt = "uengine/ontological-bolt:$releaseId"
    mindsdb = 'mindsdb/mindsdb:v26.1.0'
    analyzer = "uengine/robo-analyzer:$releaseId"
    catalog  = "uengine/robo-data-catalog:$releaseId"
    fabric   = "uengine/robo-data-fabric:$releaseId"
    parser   = "uengine/robo-antlr-parser:$releaseId"
    gateway  = "uengine/robo-api-gateway:$releaseId"
    # Document -> BPMN. Pinned upstream image (2.06 GB): we mount our own
    # facade.py over it, so the image itself never needs rebuilding. Without
    # it in the archive the customer site has no way to get it -- there is no
    # internet there. And its absence does NOT look like a failure: Architect
    # falls back and the screen still shows a BPM, so nobody notices that the
    # in-house service never ran.
    pdf2bpmn = 'ghcr.io/uengine-oss/process-gpt-bpmn-extractor:8156f77'
  }

  Info "release id: $releaseId"
  Invoke-Checked 'docker.exe' @('pull', $images.mindsdb) $WorkspaceRoot
  # amd64 only upstream; the runtime compose declares the same platform.
  Invoke-Checked 'docker.exe' @('pull', '--platform', 'linux/amd64', $images.pdf2bpmn) $WorkspaceRoot
  # graph 저장소는 다단계 빌드의 **두 타깃**이다. 하나로 묶지 않는다 — Bolt 는 상태가
  # 없고, 묶으면 공식 postgres 엔트리포인트를 우리가 다시 만들어야 하며, 무엇보다
  # **사람이 Bolt 를 띄우게 된다**(엔진을 다시 깔고 Bolt 를 안 띄워 psql 은 되는데 앱만
  # 죽는 상태를 이 저장소가 반복해 밟았다).
  # **파일이 있는지 먼저 본다.** `docker build --file <없는 경로>` 는 실패하지만,
  # 그 메시지가 "핀한 브랜치에 그 파일이 없다" 라고 말해 주지 않는다. 2026-09-18 에
  # 정확히 그 상태였다 — 브랜치는 fork 에만 있었고, 런타임 Dockerfile 은 어느
  # 브랜치에도 커밋돼 있지 않았다.
  $runtimeDockerfile = Join-Path $sources.ontological 'docker\Dockerfile.runtime'
  if (-not (Test-Path -LiteralPath $runtimeDockerfile)) {
    throw ("release.missing_ontological_runtime: $runtimeDockerfile " +
           "— workspace.json 의 ontological 핀(url·branch)이 이 파일을 담고 있는지 확인하라")
  }
  Build-ReleaseTarget 'graph-db' $images.graphDb $sources.ontological $commits.ontological 'runtime-db'
  Build-ReleaseTarget 'graph-bolt' $images.graphBolt $sources.ontological $commits.ontological 'runtime-bolt'
  Build-ReleaseImage 'analyzer' $images.analyzer $sources.analyzer $commits.analyzer
  Build-ReleaseImage 'catalog' $images.catalog $sources.catalog $commits.catalog
  Build-ReleaseImage 'fabric' $images.fabric $sources.fabric $commits.fabric
  Build-ReleaseImage 'parser' $images.parser $sources.parser $commits.parser
  Build-ReleaseImage 'gateway' $images.gateway $sources.gateway $commits.gateway

  Info 'building bundled Architect API runtime'
  Invoke-Checked 'powershell.exe' @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $sources.architect 'scripts\build-packaged-runtime.ps1'),
    '-OutputRoot', $runtimeRoot
  ) $sources.architect

  Copy-Item -LiteralPath (Join-Path $sources.architect 'desktop\runtime\compose.yml') -Destination (Join-Path $runtimeRoot 'compose.yml') -Force
  # The pdf2bpmn service mounts ./pdf2bpmn/facade.py. A bind mount whose source
  # is missing does not fail loudly -- Docker creates an empty DIRECTORY at that
  # path and uvicorn then starts with no app. Copy it, and fail here if absent.
  $facadeSource = Join-Path $sources.architect 'desktop\runtime\pdf2bpmn\facade.py'
  if (-not (Test-Path -LiteralPath $facadeSource)) {
    throw "release.missing_facade: $facadeSource"
  }
  $facadeTarget = Join-Path $runtimeRoot 'pdf2bpmn'
  New-Item -ItemType Directory -Force -Path $facadeTarget | Out-Null
  Copy-Item -LiteralPath $facadeSource -Destination (Join-Path $facadeTarget 'facade.py') -Force
  Info 'writing service-scoped packaged environment'
  $environmentSnapshots=Write-ReleaseEnvironmentSnapshots $runtimeRoot
  $imageList = @($images.Values)
  Info 'creating offline Docker image archive'
  Invoke-Checked 'docker.exe' (@('save', '--output', $imageArchive) + $imageList) $WorkspaceRoot
  $archiveSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $imageArchive).Hash.ToLowerInvariant()

  $templatePath = Join-Path $sources.architect 'desktop\runtime\runtime-manifest.template.json'
  $manifest = Get-Content -Raw -Encoding UTF8 $templatePath | ConvertFrom-Json
  $manifest.releaseId = $releaseId
  $manifest.imageArchiveSha256 = $archiveSha
  foreach ($name in $images.Keys) {
    $manifest.images.$name = $images[$name]
    $manifest.imageIds.$name = Get-DockerImageId $images[$name]
  }
  foreach ($name in $commits.Keys) {
    $manifest.source.$name = $commits[$name]
  }
  # `graphs` 는 템플릿의 기본값을 그대로 쓴다. 다만 **있는지와 서로 다른지**는 여기서
  # 본다 — 같으면 분석이 설계 graph 를 가리키게 되고, 그건 설치 뒤 첫 분석에서야
  # 드러난다. 앱도 기동에서 거부하지만 릴리스를 굽는 자리가 더 싸다.
  if (-not $manifest.graphs -or -not $manifest.graphs.design -or -not $manifest.graphs.analysis) {
    throw 'release.manifest_graphs_missing: runtime-manifest.template.json 에 graphs 가 없다'
  }
  if ($manifest.graphs.design -eq $manifest.graphs.analysis) {
    throw "release.manifest_graphs_same: 설계와 분석 graph 가 같다 ($($manifest.graphs.design))"
  }
  foreach($name in $environmentSnapshots.Keys){
    $manifest.environment.$name.file=$environmentSnapshots[$name].file
    $manifest.environment.$name.sha256=$environmentSnapshots[$name].sha256
  }
  $manifestPath = Join-Path $runtimeRoot 'runtime-manifest.json'
  $manifestJson = $manifest | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText(
    $manifestPath,
    "$manifestJson`n",
    (New-Object Text.UTF8Encoding($false))
  )

  Build-CoLocatedFrontend
  $desktop = Join-Path $sources.architect 'desktop'
  Invoke-Checked 'npm.cmd' @('run', 'build') $desktop
  Invoke-Checked 'npx.cmd' @('electron-builder') $desktop
  $installer = Get-ChildItem (Join-Path $desktop 'out\dist') -Filter 'Robo-Architect-Setup-*.exe' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $installer -or -not (Test-Path $installer)) {
    throw 'release packager completed but the installer was not found'
  }

  New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
  $releaseInstaller = Join-Path $releaseRoot "Robo-Architect-Setup-$releaseId.exe"
  Copy-Item -LiteralPath $installer -Destination $releaseInstaller -Force
  Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $releaseRoot 'runtime-manifest.json') -Force
  $installerSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseInstaller).Hash.ToLowerInvariant()
  "$installerSha  $(Split-Path $releaseInstaller -Leaf)" |
    Set-Content -LiteralPath (Join-Path $releaseRoot 'SHA256SUMS') -Encoding ascii

  Pass "release ready: $releaseRoot"
  Write-Host "Installer: $releaseInstaller"
  Write-Host "SHA256:    $installerSha"
}

function Prepare-ProfileArtifacts {
  if($SkipBuild){Warn '-SkipBuild is no longer needed; existing build output will be used';return}
  if($Profile -eq 'architect-web'){
    $remoteEntry=Join-Path(Analyzer-Frontend-Root)'dist\assets\remoteEntry.js'
    if($Build-or-not(Test-Path $remoteEntry)){Build-AnalyzerRemote}else{Pass 'reusing existing Analyzer remote build (use -Build to rebuild)'}
  }
  if($Profile -eq 'architect-electron'){
    $desktopExe=Join-Path(Repo-Path(Find-Repo 'architect'))'desktop\out\dist\win-unpacked\Robo-Architect.exe'
    if($Build-or-not(Test-Path $desktopExe)){Build-Desktop}else{Pass 'reusing existing Electron build (use -Build to rebuild)'}
  }
}

function Save-State($Processes) {
  New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
  $items=@($Processes)
  if($items.Count-eq 0){Remove-Item $StatePath -ErrorAction SilentlyContinue;return}
  ConvertTo-Json -InputObject $items -Depth 5|Set-Content -Encoding UTF8 $StatePath
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
  $taskkillOutput=@(& cmd.exe /d /c "taskkill.exe /PID $ProcessId /T /F >nul 2>&1")
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
  Stop-StateEntries $entries
  Remove-Item $StatePath -ErrorAction SilentlyContinue
  Pass "$Profile stopped"
}

function Stop-StateEntries($Entries) {
  foreach($entry in @($Entries)){
    $owned=@(Get-OwnedProcesses $entry)
    if($owned.Count-gt 0){
      $identities=@($owned|ForEach-Object{[pscustomobject]@{id=$_.Id;startedAt=$_.StartTime.ToString('o')}})
      foreach($identity in $identities){Stop-VerifiedProcessTree $entry.id $identity.id $identity.startedAt}
    }
    elseif($entry.pid){Warn "$($entry.id) already exited; stale pid was not touched"}
  }
}

function Set-ProfileContext([string]$Name) {
  $script:Profile=$Name
  $script:LogRoot=Join-Path $RuntimeRoot "logs\$Name"
  $script:StatePath=Join-Path $RuntimeRoot "$Name-state.json"
}

function Stop-AllProfiles {
  $originalProfile=$Profile
  $targets=@()
  $seen=@{}
  try {
    foreach($name in @('analyzer','architect-web','architect-electron','all')){
      Set-ProfileContext $name
      foreach($entry in @(Load-State)){
        foreach($process in @(Get-OwnedProcesses $entry)){
          $startedAt=$process.StartTime.ToString('o')
          $key="$($process.Id)|$startedAt"
          if(-not $seen.ContainsKey($key)){
            $seen[$key]=$true
            $targets+=[pscustomobject]@{entryId=$entry.id;processId=$process.Id;startedAt=$startedAt}
          }
        }
      }
    }
    foreach($target in $targets){
      Stop-VerifiedProcessTree $target.entryId $target.processId $target.startedAt
    }
    foreach($name in @('analyzer','architect-web','architect-electron','all')){
      Set-ProfileContext $name
      Remove-Item $StatePath -ErrorAction SilentlyContinue
    }
    if($ForcePorts){
      foreach($name in @('analyzer','architect-web','architect-electron','all')){
        Set-ProfileContext $name
        Stop-ProfilePortListeners
      }
    }
  } finally {
    Set-ProfileContext $originalProfile
  }
  Pass 'all profiles stopped'
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

function Stop-ServicePortListener($Service) {
  if(-not $Service.port){return}
  $port=[int]$Service.port
  foreach($owner in @(Get-PortOwners $port)){
    $process=Get-Process -Id ([int]$owner) -ErrorAction SilentlyContinue
    $name=if($process){$process.ProcessName}else{'unknown'}
    Warn "force stopping $($Service.id) port $port listener pid=$owner process=$name"
    & taskkill.exe /PID $owner /T /F|Out-Null
  }
  $deadline=(Get-Date).AddSeconds(10)
  while((Get-Date)-lt $deadline -and (Test-Port $port)){Start-Sleep -Milliseconds 200}
  if(Test-Port $port){throw "$($Service.id) port $port remains in use after forced cleanup"}
}

function Expand-ServiceValue([string]$Value) {
  $architect=if(Find-Repo 'architect'){Repo-Path(Find-Repo 'architect')}else{''}
  return $Value.
    Replace('${ARCHITECT_DIR}',$architect).
    Replace('${PROJECT_ROOT}',$ProjectRoot)
}

function Get-SelectedService {
  $match=@(Services|Where-Object id -eq $ServiceId)
  if($match.Count-eq 0){
    $available=(@(Services|ForEach-Object id)-join ', ')
    throw "service '$ServiceId' is not in profile '$Profile'. Available: $available"
  }
  return $match[0]
}

function Assert-ServiceCanStart($Service) {
  $repo=Find-Repo $Service.repo
  if(-not $repo-or-not(Test-Path(Join-Path(Repo-Path $repo)'.git'))){throw "$($Service.repo) repository missing [ACTION] robo.cmd setup $Profile"}
  $cwd=Join-Path(Repo-Path $repo)$Service.cwd
  if($Service.file-match'[/\\]'){
    $file=Join-Path $cwd $Service.file
    if(-not(Test-Path $file)){throw "$($Service.id) executable missing: $file"}
  }elseif(-not(Get-Command $Service.file -ErrorAction SilentlyContinue)){throw "$($Service.file) is not available"}
  if($Service.file-eq'cmd.exe'){
    $args=@($Service.args)
    $callIndex=[Array]::IndexOf($args,'call')
    if($callIndex-ge0-and$callIndex+1-lt$args.Count){
      $batch=[string]$args[$callIndex+1]
      if(-not[IO.Path]::IsPathRooted($batch)-and-not(Test-Path -LiteralPath(Join-Path $cwd $batch))){
        throw "$($Service.id) batch entrypoint missing: $(Join-Path $cwd $batch)"
      }
    }
  }
  if($Service.port-and(Test-Port([int]$Service.port))){
    $owners=(Get-PortOwners([int]$Service.port))-join ','
    throw "$($Service.id) port $($Service.port) already in use by pid=$owners"
  }
}

function Start-ConfiguredService($Service,$ExistingEntries) {
  $repo=Find-Repo $Service.repo; $cwd=Join-Path(Repo-Path $repo)$Service.cwd
  $file=if($Service.file-match'[/\\]'){Join-Path $cwd $Service.file}else{$Service.file}
  $original=@{}
  if($Service.env){foreach($property in $Service.env.PSObject.Properties){$original[$property.Name]=[Environment]::GetEnvironmentVariable($property.Name,'Process');$value=Expand-ServiceValue([string]$property.Value);[Environment]::SetEnvironmentVariable($property.Name,$value,'Process')}}
  New-Item -ItemType Directory -Force -Path $LogRoot|Out-Null
  $out=Join-Path $LogRoot "$($Service.id).out.log";$err=Join-Path $LogRoot "$($Service.id).err.log"
  Info "starting $($Service.id)"
  try{
    $windowStyle=if($Service.windowStyle){[string]$Service.windowStyle}else{'Hidden'}
    $startOptions=@{FilePath=$file;WorkingDirectory=$cwd;RedirectStandardOutput=$out;RedirectStandardError=$err;WindowStyle=$windowStyle;PassThru=$true}
    $serviceArgs=@($Service.args|Where-Object{$_ -ne $null})
    if($file-eq'cmd.exe'){
      $callIndex=[Array]::IndexOf($serviceArgs,'call')
      if($callIndex-ge0-and$callIndex+1-lt$serviceArgs.Count){
        $batch=[string]$serviceArgs[$callIndex+1]
        if(-not[IO.Path]::IsPathRooted($batch)){$serviceArgs[$callIndex+1]='"'+(Join-Path $cwd $batch)+'"'}
      }
    }
    if($serviceArgs.Count-gt 0){$startOptions.ArgumentList=$serviceArgs}
    $process=Start-Process @startOptions
  }
  finally{if($Service.env){foreach($property in $Service.env.PSObject.Properties){[Environment]::SetEnvironmentVariable($property.Name,$original[$property.Name],'Process')}}}
  $rootStartedAt=$process.StartTime.ToString('o')
  $entry=[pscustomobject]@{id=$Service.id;pid=$process.Id;rootPid=$process.Id;startedAt=$rootStartedAt;rootStartedAt=$rootStartedAt;listenerPid=$null;listenerStartedAt=$null;health=$Service.health;port=$Service.port}
  Save-State @(@($ExistingEntries)+$entry)
  if(-not(Wait-Service $Service $process)){throw "$($Service.id) failed readiness; see $err"}
  if($Service.port){
    $owner=Get-PortOwner([int]$Service.port)
    if($owner){
      $listener=Get-Process -Id ([int]$owner) -ErrorAction Stop
      $entry.pid=$owner;$entry.listenerPid=$owner;$entry.listenerStartedAt=$listener.StartTime.ToString('o')
      Save-State @(@($ExistingEntries)+$entry)
    }
  }
  $ready=if($Service.health){$Service.health}else{"process pid=$($entry.pid)"}
  Pass "$($Service.id) ready: $ready"
  return $entry
}

function Start-Workspace {
  if(Test-Path $StatePath){
    $existing=@(Load-State)
    $stale=@($existing|Where-Object{-not(Get-OwnedProcess $_)})
    if($existing.Count-gt 0-and$stale.Count-eq 0){
      Pass "$Profile is already running"
      Write-Host "Use: robo.cmd restart $Profile"
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
      Assert-ServiceCanStart $service
      $entry=Start-ConfiguredService $service $started
      $started+=@($entry)
    }
  }catch{Fail $_;Stop-Owned;throw}
  Pass "$Profile started"
  if($Profile-eq'analyzer'){
    $ui=Services|Where-Object id -eq 'frontend'|Select-Object -First 1
    Write-Host "Open $($ui.health)"
  }
  elseif($Profile-eq'architect-web'){
    $ui=Services|Where-Object id -eq 'architect-web'|Select-Object -First 1
    Write-Host "Open $($ui.health)"
  }
  elseif($NoElectron){Write-Host 'Shared backends are ready; run the packaged app or rerun without -NoElectron.'}
  else{Write-Host 'Electron is running. Use robo.cmd down architect-electron to stop the owned stack.'}
}

function Restart-Workspace {
  if(Test-Path $StatePath){Stop-Owned}
  if($ForcePorts){Stop-ProfilePortListeners}
  Start-Workspace
}

function Stop-SelectedService {
  $service=Get-SelectedService
  $entries=@(Load-State)
  $selected=@($entries|Where-Object id -eq $service.id)
  if($selected.Count-gt 0){Stop-StateEntries $selected}
  else{Warn "$($service.id) is not recorded as running in profile $Profile"}
  $remaining=@($entries|Where-Object id -ne $service.id)
  Save-State $remaining
  if($ForcePorts){Stop-ServicePortListener $service}
  Pass "$($service.id) stopped; other services were left running"
}

function Start-SelectedService {
  Assert-WorkspaceNeo4jConfiguration
  $service=Get-SelectedService
  $entries=@(Load-State)
  $selected=@($entries|Where-Object id -eq $service.id)
  if(@($selected|Where-Object{Get-OwnedProcess $_}).Count-gt 0){Pass "$($service.id) is already running";return}
  if($selected.Count-gt 0){Warn "removing stale $($service.id) state"}
  $remaining=@($entries|Where-Object id -ne $service.id)
  Save-State $remaining
  if($ForcePorts){Stop-ServicePortListener $service}
  Show-SharedNeo4jTarget
  Assert-ServiceCanStart $service
  try{[void](Start-ConfiguredService $service $remaining)}
  catch{
    $failed=@(Load-State|Where-Object id -eq $service.id)
    Stop-StateEntries $failed
    Save-State $remaining
    throw
  }
  Pass "$($service.id) started; other services were left running"
}

function Restart-SelectedService {
  Assert-WorkspaceNeo4jConfiguration
  Stop-SelectedService
  Start-SelectedService
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
    'up'{if($ServiceId){Start-SelectedService}else{Start-Workspace}}
    'restart'{if($ServiceId){Restart-SelectedService}else{Restart-Workspace}}
    'status'{Show-Status}
    'logs'{Show-Logs}
    'down'{if($ServiceId){Stop-SelectedService}elseif($Profile-eq'all'){Stop-AllProfiles}else{Stop-Owned;if($ForcePorts){Stop-ProfilePortListeners}}}
    'build'{Build-Desktop}
    'env'{Check-ReleaseEnvironment}
    'release'{Build-DesktopRelease}
  }
}
