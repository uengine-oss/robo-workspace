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

# open-pencil 의 LFS 원격은 .lfsconfig 에 자격증명이 박힌 R2 프록시다. 그 키는
# 인증에 실패한다고 보고됐고(윈도우 실측), smudge 가 켜져 있으면
# `git submodule update` 가 거기서 멈춘다 — 저장소 8개를 다 받아 놓고서.
#
# LFS 로 잡힌 파일은 open-pencil/tests/fixtures 의 5개(.fig 3 · .ttf 2)뿐이고
# 릴리스는 그것을 읽지 않는다. .gitattributes 3번째 줄이 canvaskit 의 *.wasm 도
# 잡지만 그 경로에 추적되는 파일은 없다 — 확인:
#   git -C <architect>/open-pencil ls-files '*.wasm'   → 0건
# 그래서 포인터 파일만 받아도 릴리스는 온전하다.
#
# 근본 수정(키 폐기 + 히스토리 정리)은 open-pencil 소유자 몫이다. 넘긴 항목 T089.
if (-not $env:GIT_LFS_SKIP_SMUDGE) { $env:GIT_LFS_SKIP_SMUDGE = '1' }

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

function Get-ReleaseAuthPosture([hashtable]$Values) {
  # 채널·인증 자세를 **한 곳에서** 정한다. 관문과 매니페스트가 따로 계산하면
  # 어긋나고, 어긋나면 "관문은 통과했는데 매니페스트는 꺼짐" 같은 상태가 된다.
  $channel=([string]$Values['ROBO_RELEASE_CHANNEL']).Trim().ToLowerInvariant()
  if([String]::IsNullOrWhiteSpace($channel)){$channel='delivery'}
  $provider=([string]$Values['AUTH_PROVIDER']).Trim().ToLowerInvariant()
  if([String]::IsNullOrWhiteSpace($provider)){$provider='none'}
  return [ordered]@{
    channel      = $channel
    authEnforced = ([string]$Values['AUTH_ENFORCE']).Trim().ToLowerInvariant() -in @('1','true','yes','on')
    authProvider = $provider
    providerIsNone = $provider -in @('none','off','disabled')
  }
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
  # 인증은 **납품 요구사항이다.** 끈 설치본이 조용히 나가서는 안 된다.
  #
  # 기본 꺼짐은 과도기 결정이었다. 그 커밋(robo-architect c369fb0, 2026-09-08)이
  # 이유를 적어 뒀다: "프런트에 로그인 화면이 붙기 전에 켜면 화면이 통째로 막힌다".
  # 로그인 화면은 **같은 날 붙었다**(deac617 `LoginView.vue`). 근거가 끝났는데
  # 기본값만 남아 있었고, 그래서 인증 없는 설치본이 만들어질 수 있었다.
  #
  # 다만 끄는 길을 아예 없애면 안 된다 — SWP SSO 는 사내망에서만 응답하므로,
  # 인증을 켠 설치본으로는 사내망 밖에서 화면을 밟을 수 없다. 그래서
  # **길은 두고 이름을 붙인다.** 문제는 끌 수 있다는 것이 아니라, 이름 없는
  # 예외가 납품으로 새는 것이었다.
  #
  #   ROBO_RELEASE_CHANNEL=internal-test   인증 꺼짐 허용 (경고 + 매니페스트에 기록)
  #   (비었거나 다른 값)                   납품 빌드 — 인증이 켜져 있어야 한다
  $posture = Get-ReleaseAuthPosture $values
  $channel = [string]$posture.channel
  $authOn = [bool]$posture.authEnforced
  $providerIsNone = [bool]$posture.providerIsNone
  if($channel -eq 'internal-test'){
    if(-not $authOn){
      Warn ('ROBO_RELEASE_CHANNEL=internal-test — AUTH_ENFORCE 가 꺼진 설치본을 만든다. ' +
            '납품에 쓰지 않는다. 매니페스트의 releaseChannel 로 남는다')
    }
  } else {
    if(-not $authOn){
      $errors+=("AUTH_ENFORCE must be on for a delivery release: " +
                "인증 없는 설치본은 납품할 수 없다. 내부 시험 빌드라면 " +
                "ROBO_RELEASE_CHANNEL=internal-test 를 명시하라")
    }
    if($authOn -and $providerIsNone){
      $errors+=("AUTH_PROVIDER must not be none for a delivery release: " +
                "AUTH_ENFORCE 만 켜면 세션을 얻을 길이 없다(swp · 별칭 posco). " +
                "내부 시험 빌드라면 ROBO_RELEASE_CHANNEL=internal-test 를 명시하라")
    }
  }

  # AUTH_ 는 평평한 `required` 로 다 표현할 수 없다 — **켰을 때만** 필요한 값이 있다.
  #
  # AUTH_ENFORCE=true 인데 AUTH_JWT_SECRET 이 비면 앱이 죽지 않는다. 임시 비밀로
  # 토큰을 발급하고 경고만 남긴다(`api/features/auth/tokens.py`). 그러면 **앱을 다시
  # 열 때마다 모든 세션이 끊기고**, AUTH_ROLE_SECRET 을 안 채운 경우 role 비밀번호가
  # 이 값에서 유도되므로 **graph 연결까지 함께 죽는다.** 증상은 기동이 아니라
  # "어제는 됐는데 오늘 로그인이 안 된다" 로 나온다.
  if($authOn){
    if([String]::IsNullOrWhiteSpace([string]$values['AUTH_JWT_SECRET'])){
      $errors+=("AUTH_ENFORCE is on but AUTH_JWT_SECRET is empty: " +
                "토큰이 임시 비밀로 발급되어 재기동마다 세션이 끊긴다")
    }
  }

  # 개발용 우회 로그인은 **납품 자산에 실려 나가면 안 된다.** id/password 로
  # 무조건 들어올 수 있는 문이고, 기본이 `test`/`test` 다.
  # 설치본에서 시험하려면 설치된 `architect/app/.env` 를 고친다 — 릴리스에 굽지 않는다.
  $devLogin=([string]$values['AUTH_DEV_LOGIN_ENABLED']).Trim().ToLowerInvariant()
  if($devLogin -in @('1','true','yes','on')){
    $errors+=("AUTH_DEV_LOGIN_ENABLED must not be packaged: " +
              "개발용 우회 로그인이 납품 자산에 실린다. 설치 후 " +
              "architect/app/.env 에서만 켠다")
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
    } else {
      # **"이미 있다" 로 넘기지 않는다.** 폴더가 핀과 다른 저장소·브랜치를 가리키고
      # 있으면 setup 은 조용히 통과하고, 증상은 release 중간의 "파일이 없다" 로
      # 나타난다. 2026-09-18 에 정확히 그 부류를 밟았다.
      $actualUrl=(git -C $path remote get-url origin 2>$null)
      $actualBranch=(git -C $path branch --show-current 2>$null)
      $mismatch=@()
      if($actualUrl -and $actualUrl.TrimEnd('/') -ne ([string]$repo.url).TrimEnd('/')){
        $mismatch += "url=$actualUrl (핀: $($repo.url))"
      }
      if($actualBranch -and $actualBranch -ne $repo.branch){
        $mismatch += "branch=$actualBranch (핀: $($repo.branch))"
      }
      if($mismatch.Count){
        Warn ("$($repo.id) already exists but does NOT match the pin: " +
              ($mismatch -join ' · ') +
              " [ACTION] 폴더를 옮기고 setup 을 다시 돌리거나 workspace.json 의 핀을 고쳐라")
      } else { Pass "$($repo.id) already exists (핀과 일치)" }
    }
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
  # **핀은 적는 게 아니라 받아 보는 것이다.** workspace.json 에 url·branch 를 써 넣고
  # 문법만 확인하면, 그 값으로 clone 이 되는지는 아무도 안 본다. 2026-09-18 에
  # `ontological` 핀의 url 이 상류를 가리키는데 그 브랜치는 fork 에만 있었고,
  # 증상은 `setup` 이 아니라 `release` 중간의 "파일이 없다" 로 나타났다.
  foreach($repo in Repositories){
    $hit=(git ls-remote --heads $repo.url $repo.branch 2>$null)
    if($hit){Pass "$($repo.id) pin reachable: $($repo.branch)"}
    else{
      Fail ("$($repo.id) pin NOT reachable: $($repo.branch) at $($repo.url) " +
            "[ACTION] workspace.json 의 url·branch 를 고치거나 그 브랜치를 올려라")
      $failed=$true
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
    # 2026-09-23: **개인 fork 의존을 끝냈다.** 그전에는
    # `seongwonyang/ontological-db` 의 `fix/neo4j-bolt-compat` 을 가리켰는데,
    # 그 커밋들이 상류(`uengine-oss/ontological-db`)에 없고 푸시 권한도 없었다
    # (403 실측). 상류 PR #2 는 3주간 리뷰 없이 닫혔다.
    #
    # 그래서 조직 소유의 별도 저장소 `uengine-oss/ontological-db-enterprise-custom`
    # 로 옮기고 그 `main` 을 가리킨다. **하드 포크다** — 상류가 고치는 것이 자동으로
    # 오지 않으므로, 필요하면 사람이 가져온다. 상류는 2026-08-24 이후 멈춰 있다.
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

function Assert-ManifestTemplateCovers(
  [object]$Node, [string]$NodeName, [string[]]$Required, [string]$TemplatePath
) {
  if ($null -eq $Node) {
    throw "release.manifest_template_missing_section: $TemplatePath 에 '$NodeName' 이 없다"
  }
  $have = @($Node.PSObject.Properties.Name)
  $missing = @($Required | Where-Object { $have -notcontains $_ })
  if ($missing.Count) {
    throw ("release.manifest_template_missing_keys: $TemplatePath 의 '$NodeName' 에 " +
           "$($missing -join ', ') 이(가) 없다 — 릴리스가 채우려는 키다. " +
           "템플릿에 그 키를 더하라(값은 자리표 문자열이면 된다).")
  }
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
    # 2026-09-23: 8156f77(2026-03-17) 에서 4.5개월 뒤처져 있어 올린다. main 과 같은
    # 다이제스트다. **오늘 본 증상(게이트웨이 빈약)의 원인은 아니었다** — 같은 문서로
    # 신·구를 A/B 했더니 둘 다 gateway 1 을 냈다. 위생 목적의 최신화다.
    pdf2bpmn = 'ghcr.io/uengine-oss/process-gpt-bpmn-extractor:c7992ce'
    # open-pencil 와이어프레임 렌더러. **없으면 와이어프레임이 조용히 빈다** —
    # `dev.sh` 는 Bun 으로 띄우지만 설치본에는 없었다. 부재가 오류로 안 보이고
    # (인제스천 경로가 `on_event=None`), 증상은 한참 뒤 Figma 싱크에서
    # "sceneGraph가 없습니다" 로 나온다. 2026-09-23 실측 0/27 → 29/29.
    wireframe = "uengine/open-pencil:$releaseId"
  }

  Info "release id: $releaseId"

  # 매니페스트 템플릿이 **릴리스가 채우려는 키를 다 갖고 있는지 여기서 본다.**
  # 아래(§아카이브 단계)의 쓰기는 `$manifest.source.$name = ...` 인데,
  # `ConvertFrom-Json` 이 낸 PSCustomObject 는 **없는 속성에 대입하면 예외**다.
  # 그 자리는 이미지 8종을 다 구운 뒤라서, 한 줄 불일치의 대가가 빌드 한 판(1~2시간)이다.
  #
  # 2026-09-18 Windows 실측으로 정확히 그 일이 났다. `Get-ReleaseSources` 에
  # `ontological` 을 더할 때 `runtime-manifest.template.json` 의 `source` 를 같이
  # 안 고쳤고, 오류 문구는 `"ontological" 속성을 찾을 수 없습니다` 뿐이었다 —
  # **어느 파일을 고쳐야 하는지 말해 주지 않는다.**
  #
  # 그래서 (가) 빌드 앞으로 옮기고 (나) 어느 템플릿의 어느 절에 무슨 키가 없는지
  # 이름으로 말한다. 서비스를 하나 더할 때 이 검사가 먼저 문다.
  $templatePath = Join-Path $sources.architect 'desktop\runtime\runtime-manifest.template.json'
  if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "release.manifest_template_missing: $templatePath"
  }
  $templateProbe = Get-Content -Raw -Encoding UTF8 $templatePath | ConvertFrom-Json
  Assert-ManifestTemplateCovers $templateProbe '(최상위)' `
    @('releaseId','releaseChannel','authEnforced','authProvider','imageArchiveSha256') $templatePath
  Assert-ManifestTemplateCovers $templateProbe.source   'source'   @($commits.Keys) $templatePath
  Assert-ManifestTemplateCovers $templateProbe.images   'images'   @($images.Keys)  $templatePath
  Assert-ManifestTemplateCovers $templateProbe.imageIds 'imageIds' @($images.Keys)  $templatePath
  Pass 'manifest template covers every key the release writes'

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
  Build-ReleaseImage 'wireframe' $images.wireframe $sources.openPencil $commits.openPencil

  Info 'building bundled Architect API runtime'
  # 지금 이 스크립트를 돌리는 호스트를 그대로 물려준다. 'powershell.exe' 를
  # 박아 두면, robo.cmd 가 pwsh 7 을 골랐어도 릴리스 중간의 이 한 단계만
  # 5.1 로 떨어진다 — 갈라진 지점이 로그에 안 남는다.
  $psHostPath = (Get-Process -Id $PID).Path
  if (-not $psHostPath) { $psHostPath = 'powershell.exe' }
  Info "packaged runtime host: $psHostPath"
  Invoke-Checked $psHostPath @(
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

  # $templatePath 는 위 게이트에서 이미 정해졌다 — 두 곳에서 정하지 않는다.
  $manifest = Get-Content -Raw -Encoding UTF8 $templatePath | ConvertFrom-Json
  $manifest.releaseId = $releaseId
  $manifest.imageArchiveSha256 = $archiveSha
  # **인증 자세를 설치본이 스스로 밝히게 한다.** 인증 꺼진 설치본이 만들어질 수
  # 있는 것 자체보다, 그것이 납품본과 구별되지 않는 것이 문제였다.
  $posture = Get-ReleaseAuthPosture (Read-EnvironmentFile $WorkspaceEnvPath)
  $manifest.releaseChannel = [string]$posture.channel
  $manifest.authEnforced = [bool]$posture.authEnforced
  $manifest.authProvider = [string]$posture.authProvider
  Info ("release channel: $($posture.channel) · auth enforced: " +
        "$($posture.authEnforced) · provider: $($posture.authProvider)")
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
  Assert-ManifestTemplateCovers $manifest.environment 'environment' @($environmentSnapshots.Keys) $templatePath
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
