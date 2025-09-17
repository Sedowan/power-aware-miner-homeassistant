param(
  [string]$lhost   = '127.0.0.1',
  [int]$lport      = 10050,
  [string]$WsPath = $null   # optional: z.B. '/ws' wenn bekannt
)

# ---- Hilfsfunktion: Zahl aus JSON "mhs" finden ----
function Find-MhsValue($obj) {
  if ($null -eq $obj) { return $null }
  if ($obj -is [double] -or $obj -is [float] -or $obj -is [int]) { return $obj }
  if ($obj -is [string]) {
    if ($obj -match '^[0-9]+([\.,][0-9]+)?$') { return [double]($obj -replace ',', '.') }
    return $null
  }
  if ($obj.PSObject) {
    foreach($p in $obj.PSObject.Properties){
      $n = $p.Name.ToLower()
      if($n -match 'mhs$|mh_s$|mhps$|mh'){
        $v = Find-MhsValue $p.Value
        if($null -ne $v){ return $v }
      }
    }
    foreach($p in $obj.PSObject.Properties){
      $v = Find-MhsValue $p.Value
      if($null -ne $v){ return $v }
    }
  }
  if ($obj -is [System.Collections.IEnumerable]) {
    foreach($i in $obj){ $v = Find-MhsValue $i; if($null -ne $v){ return $v } }
  }
  return $null
}

$base = "http://$lhost`:$lport"
$mh = 0.0

# ---- 1) Versuche /api (JSON) ----
try {
  $r = Invoke-WebRequest -Uri "$base/api" -UseBasicParsing -TimeoutSec 4
  if ($r.StatusCode -eq 200 -and $r.Content) {
    try {
      $j = $r.Content | ConvertFrom-Json -ErrorAction Stop
      $cand = @($j.total_speed.mhs,$j.total_hashrate.mhs,$j.speed.mhs,$j.hashrate.mhs) |
              Where-Object { $_ -ne $null } | Select-Object -First 1
      if ($cand -ne $null) { $mh = [double]$cand }
      if ($mh -eq 0) {
        $any = Find-MhsValue $j
        if($any -ne $null){ $mh = [double]$any }
      }
    } catch {}
  }
} catch {}

# ---- 2) /stat (Text) ----
if ($mh -eq 0) {
  try {
    $t = Invoke-WebRequest -Uri "$base/stat" -UseBasicParsing -TimeoutSec 4
    if ($t.StatusCode -eq 200 -and $t.Content -match '(?i)(?:total[_\s]*speed|mhs)\D*([0-9\.,]+)') {
      $mh = [double](($matches[1] -replace ',', '.'))
    }
  } catch {}
}

# ---- 3) HTML (Total oder GPU0) ----
if ($mh -eq 0) {
  try {
    $h = Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 4
    if ($h.StatusCode -eq 200 -and $h.Content) {
      $c = $h.Content
      if ($c -match '(?i)Total\s*Speed[^\r\n]*?([0-9\.,]+)\s*M\s*H/?s') {
        $mh = [double](($matches[1] -replace ',', '.'))
      } elseif ($c -match '(?i)GPU\s*0[^\r\n]*?([0-9\.,]+)\s*M\s*H/?s') {
        $mh = [double](($matches[1] -replace ',', '.'))
      }
    }
  } catch {}
}

# ---- 4) WebSocket (PowerShell 7) ----
if ($mh -eq 0) {
  # a) WS-URL bestimmen
  $wsUrl = $null
  if ($WsPath) {
    $wsUrl = ($WsPath.StartsWith('ws') ? $WsPath : "ws://$lhost`:$lport$WsPath")
  } else {
    # aus script.js lesen
    try {
      $js = Invoke-WebRequest -Uri "$base/script.js" -UseBasicParsing -TimeoutSec 4
      $code = $js.Content
      $reNewWS = @'
(?i)new\s+WebSocket\s*\(\s*(['"])([^'"]+)\1
'@
      $m = [regex]::Matches($code, $reNewWS)
      if ($m.Count -gt 0) {
        $arg = $m[0].Groups[2].Value
        if     ($arg.StartsWith('ws')) { $wsUrl = $arg }
        elseif ($arg.StartsWith('/'))  { $wsUrl = "ws://$lhost`:$lport$arg" }
      }
      if (-not $wsUrl) {
        $reAbs = @'
(?i)wss?://[^\s'"()]+
'@
        $m2 = [regex]::Matches($code, $reAbs)
        if ($m2.Count -gt 0) { $wsUrl = $m2[0].Value }
      }
      if (-not $wsUrl) {
        $reConcat = @'
(?i)wss?://\s*\+\s*location\.host\s*\+\s*(['"])(/[^'"]+)\1
'@
        $m3 = [regex]::Matches($code, $reConcat)
        if ($m3.Count -gt 0) { $wsUrl = "ws://$lhost`:$lport" + $m3[0].Groups[2].Value }
      }
    } catch {}
    if (-not $wsUrl) {
      foreach($p in '/ws','/socket','/api/ws','/stats','/telemetry','/miner'){
        $wsUrl = "ws://$lhost`:$lport$p"; break
      }
    }
  }

  try {
    Add-Type -AssemblyName System.Net.WebSockets
    $cs  = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts = [System.Threading.CancellationTokenSource]::new()
    $cts.CancelAfter(4000)
    $cs.ConnectAsync([Uri]$wsUrl, $cts.Token).Wait()

    $rcs = [System.Threading.CancellationTokenSource]::new()
    $rcs.CancelAfter(4000)
    $buf = New-Object byte[] 65536
    $seg = [System.ArraySegment[byte]]::new($buf,0,$buf.Length)
    $sb  = [System.Text.StringBuilder]::new()

    do {
      $res = $cs.ReceiveAsync($seg, $rcs.Token).Result
      if ($res.Count -gt 0) {
        $chunk = [System.Text.Encoding]::UTF8.GetString($buf,0,$res.Count)
        [void]$sb.Append($chunk)
      }
    } while (-not $res.EndOfMessage)

    $text = $sb.ToString()

    # JSON probieren
    try {
      $trim = $text.TrimStart()
      if ($trim.StartsWith('{') -or $trim.StartsWith('[')) {
        $j = $text | ConvertFrom-Json -ErrorAction Stop
        $cand = @($j.total_speed.mhs,$j.total_hashrate.mhs,$j.speed.mhs,$j.hashrate.mhs) |
                Where-Object { $_ -ne $null } | Select-Object -First 1
        if ($cand -ne $null) { $mh = [double]$cand }
        if ($mh -eq 0) {
          $any = Find-MhsValue $j
          if($any -ne $null){ $mh = [double]$any }
        }
      }
    } catch {}

    # „MH/s“ im Text
    if ($mh -eq 0) {
      $mhs = [regex]::Matches($text, '(?i)([0-9\.,]+)\s*M\s*H/?s')
      if ($mhs.Count -gt 0) { $mh = [double](($mhs[$mhs.Count-1].Groups[1].Value -replace ',', '.')) }
    }
  } catch {}
}

# ---- Ausgabe ----
if ($mh -lt 0) { $mh = 0 }
[System.Globalization.CultureInfo]::CurrentCulture = 'en-US'
'{0:N2}' -f $mh
