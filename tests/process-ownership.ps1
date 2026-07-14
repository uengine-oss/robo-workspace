$ErrorActionPreference='Stop'
$WorkspaceRoot=(Resolve-Path(Join-Path $PSScriptRoot '..')).Path
$Fixture=Join-Path $PSScriptRoot 'fixtures\tcp-listener.ps1'
$ParentFixture=Join-Path $PSScriptRoot 'fixtures\tcp-listener-parent.ps1'
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

function Start-TestListenerTree {
  $port=Get-FreePort
  $root=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ParentFixture,'-Port',$port,'-ChildScript',$Fixture) -WindowStyle Hidden -PassThru
  $script:children+=$root
  $deadline=(Get-Date).AddSeconds(10)
  $owner=$null
  while((Get-Date)-lt $deadline -and -not $owner){
    $owner=Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue|Select-Object -First 1 -ExpandProperty OwningProcess
    if(-not $owner){Start-Sleep -Milliseconds 100}
  }
  Assert-True ([bool]$owner) "listener tree did not open port $port"
  $listener=Get-Process -Id $owner -ErrorAction Stop
  $script:children+=$listener
  return [pscustomobject]@{Port=$port;Root=$root;Listener=$listener}
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

  $Profile='all'
  Assert-True (@(Repositories).Count-eq 7) 'all profile did not include every local web repository'
  Assert-True (@(Services).Count-eq 9) 'all profile did not include the expected nine local web services'
  Assert-True (@(Services|Where-Object id -eq 'architect-electron').Count-eq 0) 'all profile unexpectedly included Electron'
  $Profile='analyzer'

  $originalConfig=$Config
  $originalProjectRoot=$ProjectRoot
  $servicePort=Get-FreePort
  $Config=[pscustomobject]@{
    repositories=@([pscustomobject]@{id='workspace';path='robo-workspace';profiles=@('analyzer')})
    services=@([pscustomobject]@{id='test-service';repo='workspace';cwd='.';file='powershell.exe';args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Fixture,'-Port',$servicePort);port=$servicePort;readyDelay=1;profiles=@('analyzer')})
  }
  $ProjectRoot=Split-Path $WorkspaceRoot -Parent
  $ServiceId='test-service'
  $LogRoot=Join-Path $TestRuntime 'logs\analyzer'
  Start-SelectedService
  $firstEntry=@(Load-State|Where-Object id -eq 'test-service')[0]
  Assert-True ([bool](Get-OwnedProcess $firstEntry)) 'selected service did not start'
  Restart-SelectedService
  $secondEntry=@(Load-State|Where-Object id -eq 'test-service')[0]
  Assert-True ([bool](Get-OwnedProcess $secondEntry)) 'selected service did not restart'
  Assert-True ($firstEntry.rootPid-ne$secondEntry.rootPid) 'selected service restart reused the old launcher'
  Stop-SelectedService
  Assert-True (-not(Test-Port $servicePort)) 'selected service down left its port open'
  Assert-True (-not(Test-Path $StatePath)) 'selected service down left an empty state file'
  $Config=$originalConfig
  $ProjectRoot=$originalProjectRoot
  $ServiceId=$null

  $tree=Start-TestListenerTree
  $rootStartedAt=$tree.Root.StartTime.ToString('o')
  $listenerStartedAt=$tree.Listener.StartTime.ToString('o')
  Save-State @([pscustomobject]@{id='owned-tree';pid=$tree.Listener.Id;rootPid=$tree.Root.Id;startedAt=$rootStartedAt;rootStartedAt=$rootStartedAt;listenerPid=$tree.Listener.Id;listenerStartedAt=$listenerStartedAt;port=$tree.Port})
  Stop-Owned
  Assert-Exited $tree.Root 'owned launcher survived tree cleanup'
  Assert-Exited $tree.Listener 'owned listener survived tree cleanup'

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

  $allListeners=@()
  foreach($name in @('analyzer','architect-web','architect-electron','all')){
    $listener=Start-TestListener
    $allListeners+=$listener
    Set-ProfileContext $name
    $startedAt=$listener.Process.StartTime.ToString('o')
    Save-State @([pscustomobject]@{id="$name-test";pid=$listener.Process.Id;rootPid=$listener.Process.Id;startedAt=$startedAt;rootStartedAt=$startedAt;listenerPid=$listener.Process.Id;listenerStartedAt=$startedAt;port=$listener.Port})
  }
  Stop-AllProfiles
  foreach($listener in $allListeners){Assert-Exited $listener.Process 'down all left an owned profile process running'}
  foreach($name in @('analyzer','architect-web','architect-electron','all')){
    Assert-True (-not(Test-Path(Join-Path $RuntimeRoot "$name-state.json"))) "down all left $name state behind"
  }

  Write-Output 'process ownership tests passed'
} finally {
  foreach($child in $children){if(Get-Process -Id $child.Id -ErrorAction SilentlyContinue){Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue}}
  if(Test-Path $TestRuntime){Remove-Item -LiteralPath $TestRuntime -Recurse -Force}
  $env:ROBO_WORKSPACE_TEST_MODE=$previousTestMode
}
