$ErrorActionPreference = 'Stop'

$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runRoot = Join-Path $workspaceRoot '_runs\source-lifecycle'
$seedRoot = Join-Path $runRoot 'seed'
$projectRoot = Join-Path $runRoot 'project'
$runtimeRoot = Join-Path $runRoot 'runtime'
$configPath = Join-Path $runRoot 'workspace.json'
$envPath = Join-Path $runRoot 'workspace.env'

$trackedEnvironment = @(
  'ROBO_WORKSPACE_TEST_MODE',
  'ROBO_PROJECT_ROOT',
  'ROBO_WORKSPACE_RUNTIME',
  'ROBO_WORKSPACE_CONFIG',
  'ROBO_WORKSPACE_ENV'
)
$previous = @{}

function Invoke-Git([string[]]$Arguments, [string]$WorkingDirectory) {
  & git -C $WorkingDirectory @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git failed in $WorkingDirectory`: git $($Arguments -join ' ')"
  }
}

function Remove-TestDirectory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
    ForEach-Object {
      try { $_.Attributes = [IO.FileAttributes]::Normal } catch {}
    }
  [IO.Directory]::Delete([IO.Path]::GetFullPath($Path), $true)
}

try {
  foreach ($name in $trackedEnvironment) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
  }
  Remove-TestDirectory $runRoot
  New-Item -ItemType Directory -Force -Path $seedRoot, $projectRoot | Out-Null

  & git -C $seedRoot init --initial-branch=main
  if ($LASTEXITCODE -ne 0) { throw 'could not initialize local source fixture' }
  Invoke-Git @('config', 'user.name', 'Robo Workspace Contract') $seedRoot
  Invoke-Git @('config', 'user.email', 'workspace-contract@example.invalid') $seedRoot
  Set-Content -LiteralPath (Join-Path $seedRoot 'version.txt') -Value 'one' -Encoding ascii
  Invoke-Git @('add', 'version.txt') $seedRoot
  Invoke-Git @('commit', '-m', 'fixture: initial') $seedRoot

  $repositoryDefinitions = @(
    @{ id = 'antlr'; path = 'antlr-code-parser' },
    @{ id = 'gateway'; path = 'api-gateway' },
    @{ id = 'analyzer'; path = 'robo-data-analyzer' },
    @{ id = 'frontend'; path = 'robo-data-frontend' },
    @{ id = 'fabric'; path = 'robo-data-fabric' },
    @{ id = 'catalog'; path = 'robo-data-catalog' }
  )
  $config = [ordered]@{
    repositories = @(
      foreach ($repo in $repositoryDefinitions) {
        [ordered]@{
          id = $repo.id
          path = $repo.path
          url = $seedRoot
          branch = 'main'
          profiles = @('analyzer')
        }
      }
    )
    services = @()
  }
  $config | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $configPath -Encoding UTF8
  Set-Content -LiteralPath $envPath -Value @(
    'ROBO_NEO4J_URI=bolt://fixture:7687',
    'ROBO_NEO4J_USER=fixture',
    'ROBO_NEO4J_PASSWORD=fixture',
    'ROBO_NEO4J_DATABASE=neo4j'
  ) -Encoding ascii

  $env:ROBO_WORKSPACE_TEST_MODE = '1'
  $env:ROBO_PROJECT_ROOT = $projectRoot
  $env:ROBO_WORKSPACE_RUNTIME = $runtimeRoot
  $env:ROBO_WORKSPACE_CONFIG = $configPath
  $env:ROBO_WORKSPACE_ENV = $envPath

  . (Join-Path $workspaceRoot 'scripts\robo.ps1') setup analyzer

  function Setup-Python([string]$Directory, [string]$Requirements) {
    if (-not (Test-Path -LiteralPath $Directory)) {
      throw "Setup clone did not create Python repository: $Directory"
    }
  }
  function Setup-Node([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory)) {
      throw "Setup clone did not create Node repository: $Directory"
    }
  }

  Setup-Workspace
  $initialHead = (& git -C $seedRoot rev-parse HEAD).Trim()
  foreach ($repo in $repositoryDefinitions) {
    $checkout = Join-Path $projectRoot $repo.path
    if (-not (Test-Path -LiteralPath (Join-Path $checkout '.git'))) {
      throw "setup did not clone $($repo.id)"
    }
    $head = (& git -C $checkout rev-parse HEAD).Trim()
    $branch = (& git -C $checkout branch --show-current).Trim()
    if ($head -ne $initialHead -or $branch -ne 'main') {
      throw "setup cloned the wrong revision or branch: $($repo.id)"
    }
  }

  Set-Content -LiteralPath (Join-Path $seedRoot 'version.txt') -Value 'two' -Encoding ascii
  Invoke-Git @('add', 'version.txt') $seedRoot
  Invoke-Git @('commit', '-m', 'fixture: update') $seedRoot
  $updatedHead = (& git -C $seedRoot rev-parse HEAD).Trim()

  Sync-Workspace
  foreach ($repo in $repositoryDefinitions) {
    $checkout = Join-Path $projectRoot $repo.path
    $head = (& git -C $checkout rev-parse HEAD).Trim()
    if ($head -ne $updatedHead) {
      throw "sync did not fast-forward $($repo.id)"
    }
  }

  Write-Output 'source lifecycle tests passed: setup cloned 6 repositories; sync fast-forwarded all 6'
} finally {
  foreach ($name in $trackedEnvironment) {
    [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
  }
  Remove-TestDirectory $runRoot
}
