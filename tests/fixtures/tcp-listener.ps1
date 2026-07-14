param([Parameter(Mandatory=$true)][int]$Port)

$listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$Port)
$listener.Start()
try {
  while($true){Start-Sleep -Seconds 1}
} finally {
  $listener.Stop()
}
