$ErrorActionPreference='Stop'
$WorkspaceRoot=(Resolve-Path(Join-Path $PSScriptRoot '..')).Path
$names=@('ROBO_WORKSPACE_TEST_MODE','ROBO_NEO4J_DATABASE','ANALYZER_NEO4J_DATABASE')
$previous=@{}

try{
  foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
  $env:ROBO_WORKSPACE_TEST_MODE='1'
  $env:ROBO_NEO4J_DATABASE='workspace-shared-db-test'
  $env:ANALYZER_NEO4J_DATABASE='conflicting-repository-db-test'

  . (Join-Path $WorkspaceRoot 'scripts\robo.ps1') help all

  if($env:ANALYZER_NEO4J_DATABASE-ne$env:ROBO_NEO4J_DATABASE){
    throw 'Architect Analyzer database did not inherit the Workspace Analyzer database'
  }
  Write-Output 'environment contract tests passed'
}finally{
  foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
}
