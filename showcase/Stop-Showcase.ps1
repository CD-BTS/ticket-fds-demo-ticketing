# Showcase 프로세스(백엔드·프론트엔드)를 종료하고 컨테이너를 멈춘다. 데이터(named volume)와 인증 정보(.run/secrets.json)는 그대로 둔다.
# 기존 Dev·E2E 컨테이너는 건드리지 않는다. 데이터까지 지우려면 Reset-Showcase.ps1을 쓴다.
param(
    [ValidateSet('all', 'bts', 'demo', 'web')][string]$Only = 'all',
    # 프로세스만 끄고 컨테이너(DB·Redis·AI)는 계속 실행
    [switch]$KeepContainers
)
. (Join-Path $PSScriptRoot 'Showcase-Common.ps1')
$names = switch ($Only) { 'all' { 'demo-web', 'admin-web', 'demo', 'bts' } 'web' { 'demo-web', 'admin-web' } default { $Only } }
foreach ($name in $names) {
    $pidFile = Join-Path $RunDir "$name.pid"
    if (Test-Path $pidFile) {
        $id = [int](Get-Content $pidFile)
        # gradlew.bat·npm이 띄운 Java·node 자식 프로세스까지 함께 종료한다.
        & taskkill.exe /PID $id /T /F 2>$null | Out-Null
        Remove-Item $pidFile
        Write-Output "$name 종료 (pid $id)"
    }
}
if (-not $KeepContainers -and $Only -eq 'all') {
    $ErrorActionPreference = 'Continue'
    # stop: 컨테이너만 멈춘다(down/-v를 쓰지 않으므로 볼륨이 남는다).
    docker compose -p $SC.Project -f (Join-Path $PSScriptRoot 'compose.yaml') stop 2>&1 | Out-Host
    Write-Output '컨테이너 중지 (데이터 볼륨 유지)'
}
