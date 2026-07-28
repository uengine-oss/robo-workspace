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
  if($releaseTemplateErrors.Count-ne2-or
     @($releaseTemplateErrors|Where-Object{$_-match'ROBO_LLM_API_KEY'}).Count-ne1-or
     @($releaseTemplateErrors|Where-Object{$_-match'OPENAI_API_KEY'}).Count-ne1){
    throw 'Committed release template must require both internal GPU credentials'
  }
  $releaseErrors=@(Get-ReleaseEnvironmentConfigurationErrors $releaseFixture)
  if($releaseErrors.Count){
    throw "Release environment fixture is incomplete: $($releaseErrors-join'; ')"
  }
  $originalWorkspaceEnvPath=$WorkspaceEnvPath
  $WorkspaceEnvPath=$releaseFixture
  $snapshots=Write-ReleaseEnvironmentSnapshots $releaseEnvRoot
  foreach($scope in @('analyzer','catalog','fabric','parser','gateway','architect')){
    if(-not$snapshots.Contains($scope)){throw "Release environment snapshot missing scope: $scope"}
    $snapshotFile=Join-Path $releaseEnvRoot $snapshots[$scope].file
    if(-not(Test-Path -LiteralPath $snapshotFile)){throw "Release environment file missing: $scope"}
    $actualHash=(Get-FileHash -LiteralPath $snapshotFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actualHash-ne$snapshots[$scope].sha256){throw "Release environment hash mismatch: $scope"}
  }
  $analyzerEnv=Get-Content -LiteralPath(Join-Path $releaseEnvRoot $snapshots.analyzer.file)-Raw
  if($analyzerEnv-notmatch'(?m)^ROBO_LLM_CONFIG=qwen36_sglang_local$'-or
     $analyzerEnv-notmatch'(?m)^ROBO_LLM_API_KEY=fixture-internal-key$'){
    throw 'Analyzer packaged environment does not select the internal GPU config'
  }
  if($analyzerEnv-match'(?m)^ROBO_NEO4J_(URI|USER|PASSWORD|DATABASE)='-or
     $analyzerEnv-match'(?m)^ROBO_DATA_DIR='){
    throw 'Analyzer packaged environment captured runtime-owned topology'
  }
  $catalogEnv=Get-Content -LiteralPath(Join-Path $releaseEnvRoot $snapshots.catalog.file)-Raw
  $fabricEnv=Get-Content -LiteralPath(Join-Path $releaseEnvRoot $snapshots.fabric.file)-Raw
  $architectEnv=Get-Content -LiteralPath(Join-Path $releaseEnvRoot $snapshots.architect.file)-Raw
  if($catalogEnv-notmatch'(?m)^LLM_API_BASE=http://ai-server\.dream-flow\.com:30000/v1$'-or
     $architectEnv-notmatch'(?m)^OPENAI_BASE_URL=http://ai-server\.dream-flow\.com:30000/v1$'){
    throw 'Catalog/Architect packaged GPU endpoint mapping is incomplete'
  }
  if($fabricEnv-match'(?m)^MINDSDB_(URL|HOST|API_PORT)='){
    throw 'Fabric packaged environment captured app-owned MindsDB topology'
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
  if($manifestTemplate.schemaVersion-ne3){
    throw 'Packaged runtime manifest must use the app-owned MindsDB schema'
  }
  if($manifestTemplate.images.mindsdb-ne'mindsdb/mindsdb:v26.1.0'-or
     $manifestTemplate.imageIds.mindsdb-notmatch'^sha256:IMAGE_ID_MINDSDB$'){
    throw 'Packaged runtime manifest must pin the app-owned MindsDB image'
  }
  foreach($scope in @('analyzer','catalog','fabric','parser','gateway','architect')){
    if(-not$manifestTemplate.environment.$scope.file-or
       $manifestTemplate.environment.$scope.sha256-notmatch'^ENV_SHA256_'){
      throw "Runtime manifest environment declaration is incomplete: $scope"
    }
  }
  $composeSource=Get-Content -LiteralPath(Join-Path $architectRoot 'desktop\runtime\compose.yml')-Raw
  foreach($scope in @('analyzer','catalog','fabric','parser','gateway')){
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
