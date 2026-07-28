$ErrorActionPreference = 'Stop'

$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$projectRoot = if ($env:ROBO_PROJECT_ROOT) {
  [IO.Path]::GetFullPath($env:ROBO_PROJECT_ROOT)
} else {
  Join-Path (Split-Path $workspaceRoot -Parent) 'project'
}
$templatePath = Join-Path $workspaceRoot '.env.example'
$contractPath = Join-Path $workspaceRoot 'release-environment.json'

function Get-TemplateKeys {
  $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($line in Get-Content -LiteralPath $templatePath -Encoding UTF8) {
    if ($line -match '^\s*#?\s*([A-Z][A-Z0-9_]*)=') {
      [void]$keys.Add($Matches[1])
    }
  }
  return $keys
}

function Get-LiteralKeys(
  [string[]]$Files,
  [string[]]$Prefixes
) {
  $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($file in $Files) {
    if (-not (Test-Path -LiteralPath $file)) { continue }
    $source = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    if ($null -eq $source) { continue }
    foreach ($match in [regex]::Matches($source, '["'']([A-Z][A-Z0-9_]{2,})["'']')) {
      $name = $match.Groups[1].Value
      if (@($Prefixes | Where-Object { $name.StartsWith($_, [StringComparison]::Ordinal) }).Count) {
        [void]$keys.Add($name)
      }
    }
  }
  return $keys
}

function Get-PlaceholderKeys([string]$File, [string[]]$Prefixes) {
  $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  if (-not (Test-Path -LiteralPath $File)) { return $keys }
  $source = Get-Content -LiteralPath $File -Raw -Encoding UTF8
  foreach ($match in [regex]::Matches($source, '\$\{([A-Z][A-Z0-9_]+)(?::[^}]*)?\}')) {
    $name = $match.Groups[1].Value
    if (@($Prefixes | Where-Object { $name.StartsWith($_, [StringComparison]::Ordinal) }).Count) {
      [void]$keys.Add($name)
    }
  }
  return $keys
}

function Get-CodeFiles([string]$Root, [string]$Filter) {
  if (-not (Test-Path -LiteralPath $Root)) { return @() }
  return @(
    Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Filter |
      Where-Object {
        $_.FullName -notmatch '[\\/](tests?|__pycache__|node_modules|dist|out|target|\.venv)[\\/]'
      } |
      Select-Object -ExpandProperty FullName
  )
}

function Test-ScopeKey([string]$Name, $Scope) {
  if (@($Scope.excludeNames) -contains $Name) { return $false }
  if (@($Scope.names) -contains $Name) { return $true }
  foreach ($prefix in @($Scope.prefixes)) {
    if ($Name.StartsWith([string]$prefix, [StringComparison]::Ordinal)) { return $true }
  }
  return $false
}

$templateKeys = Get-TemplateKeys
$contract = Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8 | ConvertFrom-Json

$sourceSets = [ordered]@{}

$analyzerRoot = Join-Path $projectRoot 'robo-data-analyzer'
$sourceSets.analyzer = Get-LiteralKeys @(
  (Join-Path $analyzerRoot 'shared\config\settings.py'),
  (Join-Path $analyzerRoot 'search\config.py'),
  (Join-Path $analyzerRoot 'search\query\rewrite.py'),
  (Join-Path $analyzerRoot 'search\ranking\rerank.py'),
  (Join-Path $analyzerRoot 'search\query\judge.py')
) @('ROBO_')

$catalogRoot = Join-Path $projectRoot 'robo-data-catalog'
$sourceSets.catalog = Get-LiteralKeys @(
  (Join-Path $catalogRoot 'shared\config\settings.py')
) @('CATALOG_', 'DATA_FABRIC_', 'EMBEDDING_', 'FK_', 'LLM_', 'METADATA_', 'NEO4J_', 'OPENAI_')

$fabricRoot = Join-Path $projectRoot 'robo-data-fabric'
$sourceSets.fabric = Get-LiteralKeys @(
  (Join-Path $fabricRoot 'shared\config\settings.py')
) @('DATA_FABRIC_', 'MINDSDB_', 'NEO4J_')

$parserRoot = Join-Path $projectRoot 'antlr-code-parser'
$sourceSets.parser = Get-LiteralKeys @(
  (Join-Path $parserRoot 'src\main\java\legacymodernizer\parser\intake\ParserWorkspace.java'),
  (Join-Path $parserRoot 'src\main\java\legacymodernizer\parser\recovery\source\VerifiedSourceRepairApplier.java'),
  (Join-Path $parserRoot 'src\main\java\legacymodernizer\parser\recovery\repair\StructuredRepairAgent.java')
) @(
  'PARSER_', 'ROBO_DATA_', 'DOCKER_COMPOSE_'
)

$gatewayRoot = Join-Path $projectRoot 'api-gateway'
$sourceSets.gateway = Get-PlaceholderKeys (
  Join-Path $gatewayRoot 'src\main\resources\application.yml'
) @('ROBO_')

$architectRoot = Join-Path $projectRoot 'robo-architect'
$sourceSets.architect = Get-LiteralKeys (Get-CodeFiles (Join-Path $architectRoot 'api') '*.py') @(
  'AI_AUDIT_',
  'ANTHROPIC_',
  'API_',
  'BC_SPEC_',
  'CHANGE_PROPAGATION_',
  'CHAT_',
  'GENERATION_',
  'GOOGLE_',
  'HYBRID_',
  'INGESTION_',
  'IS_SKIP_',
  'LLM_',
  'MODEL_',
  'OPENAI_',
  'PDF2BPMN_',
  'ROBO_CLUSTER_',
  'ROBO_SPEC_',
  'SMART_LOGGER_',
  'WIREFRAME_'
)

$mappedTopology = @(
  'DOCKER_COMPOSE_CONTEXT',
  'NEO4J_URI', 'NEO4J_USER', 'NEO4J_PASSWORD', 'NEO4J_DATABASE'
)
$missing = @()
foreach ($entry in $sourceSets.GetEnumerator()) {
  foreach ($name in @($entry.Value)) {
    if ($mappedTopology -contains $name) { continue }
    if (-not $templateKeys.Contains($name)) {
      $missing += "$($entry.Key):$name"
    }
  }
}
if ($missing.Count) {
  throw "Workspace .env.example is missing source-consumed keys: $($missing -join ', ')"
}

$criticalPackaged = [ordered]@{
  analyzer = @(
    'ROBO_LLM_CONFIG', 'ROBO_EMBED_MODEL', 'ROBO_SEARCH_DENSE_IMPL',
    'ROBO_PIPELINE_MAX_CONCURRENCY', 'ROBO_SEM_UNIFIED'
  )
  catalog = @(
    'LLM_API_BASE', 'LLM_MAX_COMPLETION_TOKENS', 'EMBEDDING_MODEL',
    'FK_INFERENCE_ENABLED', 'METADATA_TIMEOUT_REQUEST'
  )
  fabric = @('DATA_FABRIC_QUERY_TIMEOUT_SECONDS', 'MINDSDB_REPLACE_LOCALHOST')
  parser = @('PARSER_REPAIR_AGENT_ENABLED', 'PARSER_REPAIR_AGENT_TIMEOUT_SECONDS')
  architect = @(
    'LLM_PROVIDER', 'OPENAI_BASE_URL', 'CHANGE_PROPAGATION_ENABLED',
    'INGESTION_BATCH_SIZE', 'HYBRID_EMBED_TOP_K', 'WIREFRAME_LLM_CONCURRENCY',
    'AI_AUDIT_LOG_ENABLED', 'MODEL_MODIFIER_CONTEXT_CHARS_LIMIT',
    'BC_SPEC_SPLIT_LINE_THRESHOLD'
  )
}
foreach ($scopeName in $criticalPackaged.Keys) {
  $scope = $contract.scopes.$scopeName
  foreach ($name in $criticalPackaged[$scopeName]) {
    if (-not $templateKeys.Contains($name)) {
      throw "Critical packaged key is absent from .env.example: $name"
    }
    if (-not (Test-ScopeKey $name $scope)) {
      throw "Release scope '$scopeName' does not accept $name"
    }
  }
}

foreach ($name in @('MINDSDB_URL', 'MINDSDB_HOST', 'MINDSDB_API_PORT')) {
  if (Test-ScopeKey $name $contract.scopes.fabric) {
    throw "Fabric release scope must not capture app-owned topology: $name"
  }
}
foreach ($scopeProperty in $contract.scopes.PSObject.Properties) {
  foreach ($name in @('ROBO_NEO4J_URI', 'ROBO_NEO4J_PASSWORD', 'ROBO_DATA_DIR')) {
    if (Test-ScopeKey $name $scopeProperty.Value) {
      throw "Release scope '$($scopeProperty.Name)' captured runtime-owned topology: $name"
    }
  }
}

Write-Output (
  'environment catalog tests passed: {0} template keys, source audit={1}' -f
    $templateKeys.Count,
    (@($sourceSets.Values | ForEach-Object { $_.Count }) -join '/')
)
