param(
  [Parameter(Mandatory=$true)][int]$Port,
  [Parameter(Mandatory=$true)][string]$ChildScript
)

$child=Start-Process powershell.exe -ArgumentList @(
  '-NoProfile','-ExecutionPolicy','Bypass','-File',$ChildScript,'-Port',$Port
) -WindowStyle Hidden -PassThru
try {
  Wait-Process -Id $child.Id
} finally {
  if(Get-Process -Id $child.Id -ErrorAction SilentlyContinue){
    Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
  }
}
