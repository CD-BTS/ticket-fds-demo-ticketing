# Start-E2E.ps1로 띄운 백엔드 프로세스와 e2e DB 컨테이너를 정리한다. 기존 개발용 컨테이너는 건드리지 않는다.
# -Only bts: 장애 시나리오용으로 BTS 프로세스만 종료 (컨테이너 유지)
param([switch]$KeepContainers, [ValidateSet('all', 'bts', 'demo')][string]$Only = 'all')
$run = Join-Path $PSScriptRoot '.run'
foreach ($name in @('demo', 'bts') | Where-Object { $Only -eq 'all' -or $_ -eq $Only }) {
    $pidFile = Join-Path $run "$name.pid"
    if (Test-Path $pidFile) {
        $id = [int](Get-Content $pidFile)
        # gradlew.bat이 띄운 Java 자식 프로세스까지 함께 종료한다.
        & taskkill.exe /PID $id /T /F 2>$null | Out-Null
        Remove-Item $pidFile
        Write-Output "$name 종료 (pid $id)"
    }
}
if (-not $KeepContainers -and $Only -eq 'all') {
    $ErrorActionPreference = 'Continue'
    docker compose -f (Join-Path $PSScriptRoot 'compose.yaml') down 2>&1 | Out-Host
}
