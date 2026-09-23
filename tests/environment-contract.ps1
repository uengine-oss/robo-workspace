$ErrorActionPreference='Stop'
$WorkspaceRoot=(Resolve-Path(Join-Path $PSScriptRoot '..')).Path
$names=@(
  'ROBO_WORKSPACE_TEST_MODE',
  'ROBO_NEO4J_URI','ROBO_NEO4J_USER','ROBO_NEO4J_PASSWORD','ROBO_NEO4J_DATABASE',
  'NEO4J_URI','NEO4J_USER','NEO4J_PASSWORD','NEO4J_DATABASE',
  'ANALYZER_NEO4J_DATABASE','ROBO_DATA_DIR'
)
$previous=@{}
$fixture=Join-Path $PSScriptRoot 'fixtures\workspace.env'
$invalidFixture=Join-Path $PSScriptRoot 'fixtures\workspace-invalid.env'
$systemFixture=Join-Path $PSScriptRoot 'fixtures\workspace-system.env'
$releaseEnvRoot=Join-Path $WorkspaceRoot '_runs\release-environment-contract'
$releaseFixture=Join-Path $PSScriptRoot 'fixtures\release.env'
$internalEndpointFixture=Join-Path $PSScriptRoot 'fixtures\release-internal-endpoint.env'
$originalWorkspaceEnvPath=$null

try{
  foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
  $env:ROBO_WORKSPACE_TEST_MODE='1'
  foreach($name in $names|Where-Object{$_-ne'ROBO_WORKSPACE_TEST_MODE'}){
    [Environment]::SetEnvironmentVariable($name,'conflicting-shell-value','Process')
  }

  . (Join-Path $WorkspaceRoot 'scripts\robo.ps1') help analyzer
  Import-WorkspaceEnvironment $fixture

  $expected=@{
    URI='bolt://workspace-fixture:7687'
    USER='workspace-user'
    PASSWORD='workspace-password'
    DATABASE='neo4j'
  }
  foreach($suffix in $expected.Keys){
    $robo=[Environment]::GetEnvironmentVariable("ROBO_NEO4J_$suffix",'Process')
    $standard=[Environment]::GetEnvironmentVariable("NEO4J_$suffix",'Process')
    if($robo-ne$expected[$suffix]-or$standard-ne$expected[$suffix]){
      throw "Workspace $suffix did not override conflicting inherited Neo4j values"
    }
  }
  if($env:ANALYZER_NEO4J_DATABASE-ne'neo4j'){
    throw 'Architect Analyzer database did not inherit the Workspace database'
  }
  $manifest=Get-Content -LiteralPath (Join-Path $WorkspaceRoot 'workspace.json') -Raw | ConvertFrom-Json
  if(-not(Get-Command Build-DesktopRelease -ErrorAction SilentlyContinue)){
    throw 'One-command Electron release entrypoint is missing'
  }
  if(-not(Get-Command Prepare-ReleaseWorkspace -ErrorAction SilentlyContinue)){
    throw 'Workspace-only release preparation entrypoint is missing'
  }
  $releaseTemplateErrors=@(Get-ReleaseEnvironmentConfigurationErrors(Join-Path $WorkspaceRoot '.env.example'))
  # **이 검사를 개수 검사보다 먼저 한다.** 개수를 먼저 보면 사내 주소가 하나 늘어난
  # 것도 "자격증명 개수가 안 맞는다" 로 보고돼, 원인을 엉뚱한 데서 찾게 된다.
  # 이 파일은 git 추적 대상이라 납품 자산에 그대로 실려 나간다.
  if(@($releaseTemplateErrors|Where-Object{$_-match'developer-internal target'}).Count-ne 0){
    throw 'Committed release template still points at a developer-internal target'
  }
  # **개수로 재지 않는다.** 예전에는 `.Count -ne 2` 였는데, 관문에 검사가
  # 하나 늘자(18a8a99 의 AUTH_ENFORCE/AUTH_JWT_SECRET) 템플릿은 그대로인데
  # 이 테스트만 빨개졌고 5일간 아무도 몰랐다. 개수는 "무엇이 틀렸나" 를
  # 말해 주지 않는다 — 있어야 할 것이 있는지를 이름으로 본다.
  if(@($releaseTemplateErrors|Where-Object{$_-match'ROBO_LLM_API_KEY'}).Count-ne1-or
     @($releaseTemplateErrors|Where-Object{$_-match'OPENAI_API_KEY'}).Count-ne1){
    throw 'Committed release template must require both LLM credentials'
  }
  # 템플릿은 자격증명을 비워 두는 것이 맞다. 다만 **값이 적혀 있으면** 안 된다 —
  # 이 파일은 git 추적 대상이라 그대로 납품 자산에 실려 나간다.
  $templateRaw=Get-Content -LiteralPath(Join-Path $WorkspaceRoot '.env.example')-Raw
  foreach($name in @('OPENAI_API_KEY','ROBO_LLM_API_KEY','LLM_API_KEY','AUTH_ROLE_SECRET')){
    if($templateRaw-match"(?m)^$name=.+$"){
      throw "Committed release template carries a credential value: $name"
    }
  }
  $releaseErrors=@(Get-ReleaseEnvironmentConfigurationErrors $releaseFixture)
  if($releaseErrors.Count){
    throw "Release environment fixture is incomplete: $($releaseErrors-join'; ')"
  }

  # 값이 **맞는지**도 본다. 비어 있지 않고 placeholder 도 아니면서 개발사 사내 주소가
  # 그대로 들어 있는 경우가 실제로 있었다 — 그러면 앞의 두 검사는 전부 통과하고,
  # 증상은 기동이 아니라 **첫 LLM 호출**에서 나온다.
  $internalErrors=@(Get-ReleaseEnvironmentConfigurationErrors $internalEndpointFixture)
  if(@($internalErrors|Where-Object{$_-match'developer-internal target'}).Count-lt 1){
    throw 'Release gate did not reject a developer-internal endpoint'
  }
  if(@($internalErrors|Where-Object{$_-match'LLM_API_BASE'}).Count-ne 1){
    throw 'Release gate did not name the offending key'
  }
  # 값은 메시지에 싣지 않는다 — 이 관문에 걸리는 키에는 자격증명도 섞인다.
  if(@($internalErrors|Where-Object{$_-match'fixture-internal-key'}).Count-ne 0){
    throw 'Release gate leaked a packaged value into its message'
  }
  $originalWorkspaceEnvPath=$WorkspaceEnvPath
  $WorkspaceEnvPath=$releaseFixture
  $releaseResult=Write-ReleaseEnvironmentSnapshots $releaseEnvRoot
  $snapshots=$releaseResult.snapshots
  $withheld=@($releaseResult.withheld)
  # ── 비밀은 굽지 않는다 ──────────────────────────────────────────────────
  # 2026-09-23 설치본 감사: 같은 OpenAI 키가 5개 파일 7개 이름으로 실려
  # 있었다. `credentialNames` 가 제외 목록이 아니라 검증 목록이었기 때문이다.
  # 그래서 여기서 재는 것은 "이름이 옮겨졌나" 가 아니라 **"값이 안 나갔나"** 다.
  foreach($name in @('ROBO_LLM_API_KEY','LLM_API_KEY','OPENAI_API_KEY')){
    if($withheld-notcontains$name){
      throw "Release did not withhold a credential it should have: $name"
    }
  }
  foreach($scope in @('analyzer','catalog','fabric','parser','gateway','pdf2bpmn','architect')){
    if(-not$snapshots.Contains($scope)){throw "Release environment snapshot missing scope: $scope"}
    $snapshotFile=Join-Path $releaseEnvRoot $snapshots[$scope].file
    if(-not(Test-Path -LiteralPath $snapshotFile)){throw "Release environment file missing: $scope"}
    $actualHash=(Get-FileHash -LiteralPath $snapshotFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actualHash-ne$snapshots[$scope].sha256){throw "Release environment hash mismatch: $scope"}
  }
  $analyzerEnv=Get-Content -LiteralPath(Join-Path $releaseEnvRoot $snapshots.analyzer.file)-Raw
  # **여기가 고정하는 것은 "어느 모델인가" 가 아니라 "scope 가 옮겨지는가" 다.**
  # 예전에는 개발사 사내 GPU 설정 이름을 기대값으로 박아 두어, 고객 값으로 바꾸면
  # 검사가 실패했다 — 검사가 내부 주소를 제자리에 못 박고 있었다.
  if($analyzerEnv-notmatch'(?m)^ROBO_LLM_CONFIG=gpt54_mini_openai$'){
    throw 'Analyzer packaged environment does not carry its LLM config scope'
  }
  # 키는 **이름조차** 파일에 남지 않는다. 이름만 남기면 나중에 누가 값을
  # 채워 넣기 좋은 빈 칸이 되고, 그 파일은 checksum 에 묶여 있어 채우는 순간
  # 앱이 안 뜬다 — 도움이 아니라 함정이다.
  if($analyzerEnv-match'(?m)^ROBO_LLM_API_KEY='){
    throw 'Analyzer packaged environment still carries a credential'
  }
  if($analyzerEnv-match'(?m)^ROBO_NEO4J_(URI|USER|PASSWORD|DATABASE)='-or
     $analyzerEnv-match'(?m)^ROBO_DATA_DIR='){
    throw 'Analyzer packaged environment captured runtime-owned topology'
  }
  $catalogEnv=Get-Content -LiteralPath(Join-Path $releaseEnvRoot $snapshots.catalog.file)-Raw
  $fabricEnv=Get-Content -LiteralPath(Join-Path $releaseEnvRoot $snapshots.fabric.file)-Raw
  $architectEnv=Get-Content -LiteralPath(Join-Path $releaseEnvRoot $snapshots.architect.file)-Raw
  if($catalogEnv-notmatch'(?m)^LLM_API_BASE=https://api\.openai\.com/v1$'-or
     $catalogEnv-notmatch'(?m)^LLM_MAX_COMPLETION_TOKENS=4096$'-or
     $architectEnv-notmatch'(?m)^OPENAI_BASE_URL=https://api\.openai\.com/v1$'){
    throw 'Catalog/Architect packaged endpoint mapping is incomplete'
  }
  if($architectEnv-notmatch'(?m)^HYBRID_EMBED_TOP_K=3$'-or
     $architectEnv-notmatch'(?m)^WIREFRAME_LLM_CONCURRENCY=4$'){
    throw 'Architect advanced runtime environment mapping is incomplete'
  }
  $parserEnv=Get-Content -LiteralPath(Join-Path $releaseEnvRoot $snapshots.parser.file)-Raw
  if($parserEnv-notmatch'(?m)^PARSER_REPAIR_AGENT_ENABLED=false$'){
    throw 'Parser runtime environment mapping is incomplete'
  }
  if($fabricEnv-match'(?m)^MINDSDB_(URL|HOST|API_PORT)='){
    throw 'Fabric packaged environment captured app-owned MindsDB topology'
  }
  if($fabricEnv-notmatch'(?m)^MINDSDB_REPLACE_LOCALHOST=host\.docker\.internal$'-or
     $fabricEnv-notmatch'(?m)^DATA_FABRIC_QUERY_TIMEOUT_SECONDS=30$'){
    throw 'Fabric runtime environment mapping is incomplete'
  }
  # 어느 파일에도 자격증명 **값**이 남지 않았는지 전수로 본다. 이름 하나를
  # 놓쳐도 여기서 걸린다 — 위의 개별 검사는 아는 이름만 보지만 이건 값을 본다.
  foreach($scope in @($snapshots.Keys)){
    $packaged=Get-Content -LiteralPath(Join-Path $releaseEnvRoot $snapshots[$scope].file)-Raw
    if($packaged-match'fixture-internal-key'){
      throw "Packaged environment leaked a credential value: $scope"
    }
  }
  $WorkspaceEnvPath=$originalWorkspaceEnvPath
  $architectRoot=Repo-Path(Find-Repo 'architect')
  foreach($relative in @(
    'desktop\runtime\compose.yml',
    'desktop\runtime\runtime-manifest.template.json',
    'scripts\build-packaged-runtime.ps1'
  )){
    if(-not(Test-Path(Join-Path $architectRoot $relative))){
      throw "Electron release input is missing: $relative"
    }
  }
  $manifestTemplate=Get-Content -LiteralPath(Join-Path $architectRoot 'desktop\runtime\runtime-manifest.template.json')-Raw|ConvertFrom-Json
  # **숫자를 여기 박지 않는다.** 예전에는 `-ne 3` 이었는데 a785ebf 가 스키마를
  # 4 로 올리면서 이 줄만 남아 테스트가 빨개졌다. 기대값의 임자는 앱이므로
  # 앱의 상수를 읽어 맞춘다 — 그래야 다음에 올릴 때 여기가 안 막는다.
  $dockerStackSource=Get-Content -LiteralPath(Join-Path $architectRoot 'desktop\src\main\docker-stack.ts')-Raw
  if($dockerStackSource-notmatch'(?m)^const MANIFEST_SCHEMA_VERSION\s*=\s*(\d+)'){
    throw 'Could not read MANIFEST_SCHEMA_VERSION from the app'
  }
  $expectedManifestSchema=[int]$Matches[1]
  if($manifestTemplate.schemaVersion-ne$expectedManifestSchema){
    throw ("Packaged runtime manifest schema disagrees with the app: " +
           "template=$($manifestTemplate.schemaVersion) app=$expectedManifestSchema")
  }
  if($manifestTemplate.images.mindsdb-ne'mindsdb/mindsdb:v26.1.0'-or
     $manifestTemplate.imageIds.mindsdb-notmatch'^sha256:IMAGE_ID_MINDSDB$'){
    throw 'Packaged runtime manifest must pin the app-owned MindsDB image'
  }
  foreach($scope in @('analyzer','catalog','fabric','parser','gateway','pdf2bpmn','architect')){
    if(-not$manifestTemplate.environment.$scope.file-or
       $manifestTemplate.environment.$scope.sha256-notmatch'^ENV_SHA256_'){
      throw "Runtime manifest environment declaration is incomplete: $scope"
    }
  }
  $composeSource=Get-Content -LiteralPath(Join-Path $architectRoot 'desktop\runtime\compose.yml')-Raw
  foreach($scope in @('analyzer','catalog','fabric','parser','gateway','pdf2bpmn')){
    if($composeSource-notmatch[regex]::Escape("./config/$scope.env")){
      throw "Compose does not load the scoped environment: $scope"
    }
  }
  if($composeSource-notmatch'(?m)^  mindsdb:$'-or
     $composeSource-notmatch'MINDSDB_URL: http://mindsdb:47334'-or
     $composeSource-notmatch'mindsdb_data:/mindsdb/var'){
    throw 'Compose does not own the MindsDB datasource runtime'
  }
  $stackSource=Get-Content -LiteralPath(Join-Path $architectRoot 'desktop\src\main\docker-stack.ts')-Raw
  if($stackSource-notmatch'ensureEnvironmentSnapshots'-or
     $stackSource-notmatch'runtime\.environment_checksum_mismatch'){
    throw 'Electron runtime does not verify packaged environment snapshots'
  }
  $architectApi=$manifest.services|Where-Object id -eq 'architect-api'
  if($architectApi.env.API_PORT-ne'8501'-or$architectApi.env.ROBO_SPEC_BACKEND_URL-ne'http://127.0.0.1:8501'){
    throw 'Architect Code/MCP environment does not follow the actual web API port'
  }
  $mainAnalyzer=$manifest.repositories|Where-Object id -eq 'analyzer'
  if(@($mainAnalyzer.profiles).Count-ne 1-or$mainAnalyzer.profiles[0]-ne'analyzer'){
    throw 'Analyzer main repository must belong only to the analyzer profile'
  }
  $mainAnalyzerService=@($manifest.services|Where-Object{$_.id-eq'analyzer'-and$_.profiles-contains'analyzer'})
  if($mainAnalyzerService.Count-ne1-or
     $mainAnalyzerService[0].env.ROBO_DATA_DIR-ne'${PROJECT_ROOT}/data'){
    throw 'Analyzer server must consume the shared upload workspace, not a CLI corpus path'
  }
  $antlrService=@($manifest.services|Where-Object id -eq 'antlr')
  if($antlrService.Count-ne1-or$antlrService[0].env.ROBO_DATA_DIR-ne'${PROJECT_ROOT}/data'){
    throw 'ANTLR and Analyzer must receive the same shared upload workspace'
  }
  $expandedDataDir=Expand-ServiceValue([string]$mainAnalyzerService[0].env.ROBO_DATA_DIR)
  $expandedAntlrDataDir=Expand-ServiceValue([string]$antlrService[0].env.ROBO_DATA_DIR)
  $expectedDataDir=Join-Path $ProjectRoot 'data'
  if([IO.Path]::GetFullPath($expandedDataDir)-ne[IO.Path]::GetFullPath($expectedDataDir)-or
     [IO.Path]::GetFullPath($expandedAntlrDataDir)-ne[IO.Path]::GetFullPath($expectedDataDir)){
    throw "Shared upload workspace expansion mismatch: analyzer=$expandedDataDir antlr=$expandedAntlrDataDir"
  }
  $mainCatalog=@($manifest.services|Where-Object{$_.id-eq'catalog'-and$_.profiles-contains'analyzer'})
  if($mainCatalog.Count-ne1-or$mainCatalog[0].repo-ne'catalog'-or$mainCatalog[0].cwd-ne'.'-or
     -not($mainCatalog[0].args-contains'main:app')){
    throw 'Analyzer profile must run the flattened main Catalog repository'
  }
  $mainFabric=@($manifest.services|Where-Object{$_.id-eq'fabric'-and$_.profiles-contains'analyzer'})
  if($mainFabric.Count-ne1-or$mainFabric[0].repo-ne'fabric'-or$mainFabric[0].cwd-ne'.'-or
     -not($mainFabric[0].args-contains'main:app')){
    throw 'Analyzer profile must run the flattened main Fabric repository'
  }
  $architectAnalyzer=@($manifest.services|Where-Object{$_.id-eq'analyzer'-and$_.profiles-contains'architect-web'})
  if($architectAnalyzer.Count-ne 1-or$architectAnalyzer[0].repo-ne'architect'-or$architectAnalyzer[0].cwd-ne'robo-analyzer/robo-data-analyzer'){
    throw 'Architect profiles must run the Architect-pinned Analyzer submodule'
  }
  $architectCatalog=@($manifest.services|Where-Object{$_.id-eq'catalog'-and$_.profiles-contains'architect-web'})
  $architectFabric=@($manifest.services|Where-Object{$_.id-eq'fabric'-and$_.profiles-contains'architect-web'})
  if($architectCatalog.Count-ne1-or$architectCatalog[0].repo-ne'architect'-or
     $architectCatalog[0].cwd-ne'robo-analyzer/robo-data-catalog'-or
     -not($architectCatalog[0].args-contains'main:app')-or
     $architectCatalog[0].args-contains'app.main:app'){
    throw 'Architect profiles must run the Architect-pinned Catalog submodule'
  }
  if($architectFabric.Count-ne1-or$architectFabric[0].repo-ne'architect'-or
     $architectFabric[0].cwd-ne'robo-analyzer/robo-data-fabric'-or
     -not($architectFabric[0].args-contains'main:app')-or
     $architectFabric[0].args-contains'app.main:app'){
    throw 'Architect profiles must run the Architect-pinned Fabric submodule'
  }
  $architectRemote=@($manifest.services|Where-Object id -eq 'analyzer-remote')
  if($architectRemote.Count-ne 1-or$architectRemote[0].repo-ne'architect'-or$architectRemote[0].cwd-ne'robo-analyzer/robo-data-frontend'){
    throw 'Architect web must serve the Architect-pinned Analyzer frontend submodule'
  }
  $architectWeb=@($manifest.services|Where-Object id -eq 'architect-web')
  if($architectWeb.Count-ne 1-or$architectWeb[0].env.ROBO_GATEWAY_URL-ne'http://127.0.0.1:9000'){
    throw 'Architect web must receive its Analyzer gateway target through the Workspace environment'
  }
  $configurationErrors=@(Get-WorkspaceNeo4jConfigurationErrors $invalidFixture)
  if($configurationErrors.Count-ne 1-or$configurationErrors[0]-notmatch'ROBO_NEO4J_PASSWORD'){
    throw 'Invalid Workspace Neo4j configuration did not fail on its missing password'
  }
  $systemErrors=@(Get-WorkspaceNeo4jConfigurationErrors $systemFixture)
  if($systemErrors.Count-ne1-or$systemErrors[0]-notmatch'must not be system'){
    throw 'Workspace system database prohibition is not fail-closed'
  }
  Write-Output 'environment contract tests passed'
}finally{
  if($originalWorkspaceEnvPath){$WorkspaceEnvPath=$originalWorkspaceEnvPath}
  if(Test-Path -LiteralPath $releaseEnvRoot){Remove-Item -LiteralPath $releaseEnvRoot -Recurse -Force}
  foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
}
