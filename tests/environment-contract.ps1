$ErrorActionPreference='Stop'
$WorkspaceRoot=(Resolve-Path(Join-Path $PSScriptRoot '..')).Path
$names=@(
  'ROBO_WORKSPACE_TEST_MODE',
  'ROBO_NEO4J_URI','ROBO_NEO4J_USER','ROBO_NEO4J_PASSWORD','ROBO_NEO4J_DATABASE',
  'NEO4J_URI','NEO4J_USER','NEO4J_PASSWORD','NEO4J_DATABASE',
  'ANALYZER_NEO4J_DATABASE'
)
$previous=@{}
$fixture=Join-Path $PSScriptRoot 'fixtures\workspace.env'
$invalidFixture=Join-Path $PSScriptRoot 'fixtures\workspace-invalid.env'
$systemFixture=Join-Path $PSScriptRoot 'fixtures\workspace-system.env'

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
  $architectApi=$manifest.services|Where-Object id -eq 'architect-api'
  if($architectApi.env.API_PORT-ne'8501'-or$architectApi.env.ROBO_SPEC_BACKEND_URL-ne'http://127.0.0.1:8501'){
    throw 'Architect Code/MCP environment does not follow the actual web API port'
  }
  $mainAnalyzer=$manifest.repositories|Where-Object id -eq 'analyzer'
  if(@($mainAnalyzer.profiles).Count-ne 1-or$mainAnalyzer.profiles[0]-ne'analyzer'){
    throw 'Analyzer main repository must belong only to the analyzer profile'
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
     $architectCatalog[0].cwd-ne'robo-analyzer/robo-data-catalog'){
    throw 'Architect profiles must run the Architect-pinned Catalog submodule'
  }
  if($architectFabric.Count-ne1-or$architectFabric[0].repo-ne'architect'-or
     $architectFabric[0].cwd-ne'robo-analyzer/robo-data-fabric/backend'){
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
  foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
}
