$ErrorActionPreference='Stop'
$WorkspaceRoot=(Resolve-Path(Join-Path $PSScriptRoot '..')).Path
$Fixture=Join-Path $PSScriptRoot 'fixtures\tcp-listener.ps1'
$TestRuntime=Join-Path $WorkspaceRoot '_runs\process-ownership'
$previousTestMode=$env:ROBO_WORKSPACE_TEST_MODE
$children=@()

function Assert-True([bool]$Condition,[string]$Message){
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}

function Get-FreePort {
  $probe=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,0)
  $probe.Start()
  try{return ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port}finally{$probe.Stop()}
}

function Start-TestListener {
  $port=Get-FreePort
  $process=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Fixture,'-Port',$port) -WindowStyle Hidden -PassThru
  $script:children+=$process
  $deadline=(Get-Date).AddSeconds(10)
  while((Get-Date)-lt $deadline -and -not(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)){Start-Sleep -Milliseconds 100}
  Assert-True ([bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) "listener did not open port $port"
  return [pscustomobject]@{Port=$port;Process=$process}
}

function Assert-Exited($Process,[string]$Message){
  $deadline=(Get-Date).AddSeconds(10)
  while((Get-Date)-lt $deadline -and (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue)){Start-Sleep -Milliseconds 100}
  Assert-True (-not [bool](Get-Process -Id $Process.Id -ErrorAction SilentlyContinue)) $Message
}

try {
  $env:ROBO_WORKSPACE_TEST_MODE='1'
  . (Join-Path $WorkspaceRoot 'scripts\robo.ps1') help analyzer
  $RuntimeRoot=$TestRuntime
  $StatePath=Join-Path $RuntimeRoot 'analyzer-state.json'
  $Profile='analyzer'
  New-Item -ItemType Directory -Force -Path $RuntimeRoot|Out-Null

  $owned=Start-TestListener
  $startedAt=$owned.Process.StartTime.ToString('o')
  Save-State @([pscustomobject]@{id='owned-listener';pid=$owned.Process.Id;rootPid=999999;startedAt=$startedAt;rootStartedAt=$startedAt;listenerPid=$owned.Process.Id;listenerStartedAt=$startedAt;port=$owned.Port})
  Stop-Owned
  Assert-Exited $owned.Process 'owned listener survived after its launcher identity was missing'

  $legacy=Start-TestListener
  Save-State @([pscustomobject]@{id='legacy-listener';pid=$legacy.Process.Id;rootPid=$legacy.Process.Id;startedAt=$legacy.Process.StartTime.ToString('o');port=$legacy.Port})
  Stop-Owned
  Assert-Exited $legacy.Process 'legacy launcher identity was not cleaned'

  $mismatch=Start-TestListener
  $wrongTime=$mismatch.Process.StartTime.AddHours(-1).ToString('o')
  $entry=[pscustomobject]@{id='reused-pid';pid=$mismatch.Process.Id;rootPid=$mismatch.Process.Id;startedAt=$wrongTime;rootStartedAt=$wrongTime;listenerPid=$mismatch.Process.Id;listenerStartedAt=$wrongTime;port=$mismatch.Port}
  Assert-True (@(Get-OwnedProcesses $entry).Count-eq 0) 'mismatched process start time was accepted as owned'
  Stop-Process -Id $mismatch.Process.Id -Force
  Assert-Exited $mismatch.Process 'mismatch test cleanup failed'

  $external=Start-TestListener
  Remove-Item $StatePath -ErrorAction SilentlyContinue
  Stop-Owned
  Assert-True ([bool](Get-Process -Id $external.Process.Id -ErrorAction SilentlyContinue)) 'normal down stopped an unrecorded listener'
  $Config=[pscustomobject]@{repositories=@();services=@([pscustomobject]@{id='external-test';port=$external.Port;profiles=@('analyzer')})}
  Stop-ProfilePortListeners
  Assert-Exited $external.Process 'forced profile-port cleanup did not stop the listener'

  Write-Output 'process ownership tests passed'
} finally {
  foreach($child in $children){if(Get-Process -Id $child.Id -ErrorAction SilentlyContinue){Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue}}
  if(Test-Path $TestRuntime){Remove-Item -LiteralPath $TestRuntime -Recurse -Force}
  $env:ROBO_WORKSPACE_TEST_MODE=$previousTestMode
}
