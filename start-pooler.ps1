$ErrorActionPreference = "Stop"

$dockerExe = Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\resources\bin\docker.exe"
if (-not (Test-Path -LiteralPath $dockerExe)) {
    throw "Docker CLI not found at $dockerExe"
}

Push-Location $PSScriptRoot
try {
    & $dockerExe version | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Docker Engine is not available." }

    & $dockerExe compose pull
    if ($LASTEXITCODE -ne 0) { throw "docker compose pull failed." }

    & $dockerExe compose up -d
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed." }

    & $dockerExe compose ps | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "docker compose ps failed." }

    $deadline = (Get-Date).AddMinutes(3)
    do {
        try {
            $status = Invoke-RestMethod -Uri "http://127.0.0.1:4000/bootstrap/status" -TimeoutSec 5
            if ($status.status -eq "ok") {
                Write-Host "Codex Pooler is ready at http://127.0.0.1:4000" -ForegroundColor Green
                $status | ConvertTo-Json -Compress | Write-Host
                exit 0
            }
        } catch {
            Start-Sleep -Seconds 3
        }
    } while ((Get-Date) -lt $deadline)

    throw "Pooler did not become ready within three minutes. Run docker compose logs app for details."
} finally {
    Pop-Location
}
