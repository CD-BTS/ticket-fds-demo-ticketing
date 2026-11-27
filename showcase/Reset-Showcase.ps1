# Showcase 환경 초기화: 프로세스·컨테이너를 내리고 Showcase 볼륨(cdbts-showcase_*)과 시드 상태를 지운다.
# 명시적으로 확인한 경우에만 진행한다. 기존 Dev(fairticket-mysql, demo-ticketing-*)·E2E(cdbts-e2e) 볼륨은 대상이 아니다.
param(
    # 확인 문구 입력을 생략한다 (자동화용). 값은 반드시 프로젝트 이름과 같아야 한다.
    [string]$Confirm = '',
    # API 키·티켓 서명 키도 새로 만든다 (기본은 유지)
    [switch]$RotateKeys
)
. (Join-Path $PSScriptRoot 'Showcase-Common.ps1')
$project = $SC.Project
$volumes = @(docker volume ls --filter "label=com.docker.compose.project=$project" --format '{{.Name}}')
Write-Output "초기화 대상 (Docker 프로젝트 '$project'):"
Write-Output "  컨테이너: $((docker ps -a --filter "label=com.docker.compose.project=$project" --format '{{.Names}}') -join ', ')"
Write-Output "  볼륨    : $($volumes -join ', ')"
Write-Output "  시드 상태: $RunDir\seed-state.json, users.json, live-state.json, plan-cache.pkl$(if ($RotateKeys) { ', secrets.json' })"
if ($volumes | Where-Object { $_ -notlike "${project}_*" }) { throw "예상하지 못한 볼륨 이름이 있어 중단합니다: $($volumes -join ', ')" }
if ($Confirm -ne $project) {
    $answer = Read-Host "모든 Showcase 데이터를 삭제합니다. 계속하려면 '$project' 를 입력하세요"
    if ($answer -ne $project) { Write-Output '취소했습니다. 아무것도 삭제하지 않았습니다.'; return }
}
& (Join-Path $PSScriptRoot 'Stop-Showcase.ps1') -KeepContainers
$ErrorActionPreference = 'Continue'
docker compose -p $project -f (Join-Path $PSScriptRoot 'compose.yaml') down -v 2>&1 | Out-Host
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -ne 0) { throw 'Showcase 컨테이너·볼륨 삭제 실패. 시드 상태와 인증 정보는 유지합니다.' }
foreach ($p in @('seed-state.json', 'users.json', 'live-state.json', 'plan-cache.pkl', 'plan-summary.json', 'bts.mode')) {
    $f = Join-Path $RunDir $p; if (Test-Path $f) { Remove-Item -Recurse -Force $f }
}
if ($RotateKeys -and (Test-Path $SecretFile)) { Remove-Item $SecretFile }
Write-Output '초기화 완료. 다시 시작하려면 .\Start-Showcase.ps1 → .\Seed-Showcase.ps1'
