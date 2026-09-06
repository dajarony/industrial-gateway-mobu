param(
    [Parameter(Position=0)]
    [ValidateSet("start", "stop", "status")]
    [string]$Action = "start"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Logs = Join-Path $Root "logs"
$StateFile = Join-Path $Root ".run-state.json"
New-Item -ItemType Directory -Force -Path $Logs | Out-Null

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Falta '$Name'. Instálalo antes de arrancar Auralis Industrial."
    }
}

function Start-LoggedProcess([string]$File, [string[]]$Arguments, [string]$Name) {
    $out = Join-Path $Logs "$Name.out.log"
    $err = Join-Path $Logs "$Name.err.log"
    Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError $err
    return $p
}

function Wait-Port([int]$Port, [int]$Seconds = 30) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $c = New-Object Net.Sockets.TcpClient
            $async = $c.BeginConnect("127.0.0.1", $Port, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(500) -and $c.Connected) { $c.Close(); return $true }
            $c.Close()
        } catch {}
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Wait-Http([string]$Url, [int]$Seconds = 30) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 3
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Stop-Tree([int]$Pid) {
    if ($Pid -gt 0) {
        cmd /c "taskkill /PID $Pid /T /F" 2>$null | Out-Null
    }
}

if ($Action -eq "stop") {
    if (Test-Path $StateFile) {
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json
        foreach ($name in @("cloudflared", "guard", "mcpo", "modbus")) {
            $pidValue = [int]$state.$name
            Stop-Tree $pidValue
        }
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Auralis Industrial detenido."
    exit 0
}

if ($Action -eq "status") {
    if (-not (Test-Path $StateFile)) {
        Write-Host "Auralis Industrial: detenido"
        exit 0
    }
    $state = Get-Content $StateFile -Raw | ConvertFrom-Json
    Write-Host "Auralis Industrial: estado guardado"
    Write-Host "  Modbus PID:     $($state.modbus)"
    Write-Host "  MCPO PID:       $($state.mcpo)"
    Write-Host "  Guard PID:      $($state.guard)"
    Write-Host "  Cloudflare PID: $($state.cloudflared)"
    Write-Host "  Public URL:     $($state.url)"
    Write-Host "  OpenAPI:        $($state.url)/openapi.json"
    exit 0
}

Require-Command "uvx"
Require-Command "uv"
Require-Command "cloudflared"

if (Test-Path $StateFile) {
    Write-Host "Ya existe un estado previo. Ejecuta '.\auralis-industrial.ps1 stop' si quieres reiniciar."
    exit 1
}

Write-Host "[1/4] Arrancando Modbus MCP..."
$modbus = Start-LoggedProcess "uvx" @(
    "--from", "modbus-mcp==0.3.3",
    "--with", "fastmcp==3.4.6",
    "modbus-mcp"
) "modbus"
if (-not (Wait-Port 8000 40)) { Stop-Tree $modbus.Id; throw "Modbus MCP no abrió el puerto 8000. Revisa logs/modbus.err.log" }

Write-Host "[2/4] Arrancando MCPO..."
$mcpo = Start-LoggedProcess "uvx" @(
    "--from", "mcpo==0.0.20",
    "--with", "mcp==1.29.1",
    "mcpo", "--port", "8001",
    "--server-type", "streamable-http",
    "--", "http://127.0.0.1:8000/mcp"
) "mcpo"
if (-not (Wait-Http "http://127.0.0.1:8001/openapi.json" 45)) {
    Stop-Tree $mcpo.Id; Stop-Tree $modbus.Id
    throw "MCPO no respondió en 8001. Revisa logs/mcpo.err.log"
}

Write-Host "[3/4] Arrancando Auralis Guard (read-only)..."
$guard = Start-LoggedProcess "uv" @("run", (Join-Path $Root "gateway\app.py")) "guard"
if (-not (Wait-Http "http://127.0.0.1:8002/health" 45)) {
    Stop-Tree $guard.Id; Stop-Tree $mcpo.Id; Stop-Tree $modbus.Id
    throw "Auralis Guard no respondió en 8002. Revisa logs/guard.err.log"
}

Write-Host "[4/4] Arrancando Cloudflare Quick Tunnel..."
$cloud = Start-LoggedProcess "cloudflared" @("tunnel", "--url", "http://127.0.0.1:8002") "cloudflared"
$cloudOut = Join-Path $Logs "cloudflared.out.log"
$cloudErr = Join-Path $Logs "cloudflared.err.log"
$url = $null
$deadline = (Get-Date).AddSeconds(35)
while ((Get-Date) -lt $deadline -and -not $url) {
    foreach ($f in @($cloudOut, $cloudErr)) {
        if (Test-Path $f) {
            $text = Get-Content $f -Raw -ErrorAction SilentlyContinue
            $m = [regex]::Match($text, "https://[a-z0-9-]+\.trycloudflare\.com")
            if ($m.Success) { $url = $m.Value; break }
        }
    }
    if (-not $url) { Start-Sleep -Milliseconds 500 }
}

if (-not $url) {
    Stop-Tree $cloud.Id; Stop-Tree $guard.Id; Stop-Tree $mcpo.Id; Stop-Tree $modbus.Id
    throw "Cloudflare no devolvió una URL. Revisa logs/cloudflared.err.log"
}

$state = [ordered]@{
    modbus = $modbus.Id
    mcpo = $mcpo.Id
    guard = $guard.Id
    cloudflared = $cloud.Id
    url = $url
    started_at = (Get-Date).ToString("o")
}
$state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8

Write-Host ""
Write-Host "Auralis Industrial LISTO" -ForegroundColor Green
Write-Host "  Public URL: $url"
Write-Host "  OpenAPI:    $url/openapi.json"
Write-Host "  Guard mode: READ-ONLY"
Write-Host "  Logs:       $Logs"
