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

try{
  foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
  $env:ROBO_WORKSPACE_TEST_MODE='1'
  foreach($name in $names|Where-Object{$_-ne'ROBO_WORKSPACE_TEST_MODE'}){
    [Environment]::SetEnvironmentVariable($name,'conflicting-shell-value','Process')
  }

  . (Join-Path $WorkspaceRoot 'scripts\robo.ps1') help all
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
  $configurationErrors=@(Get-WorkspaceNeo4jConfigurationErrors $invalidFixture)
  if($configurationErrors.Count-ne 1-or$configurationErrors[0]-notmatch'ROBO_NEO4J_PASSWORD'){
    throw 'Invalid Workspace Neo4j configuration did not fail on its missing password'
  }
  Write-Output 'environment contract tests passed'
}finally{
  foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
}
