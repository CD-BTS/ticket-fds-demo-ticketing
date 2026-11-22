import { ApiError, request, USE_MOCK_TICKETING } from './client'

export interface Attempt {
  attemptId: string; concertId: string; stage: string; status: string; sequence: number
  holdId: string | null; bookingId: string | null
}
interface Pending { transitionId: string; stage: string; status: string }
interface LocalAttempt { attemptId: string; clientOccurredAt: string; transitions: Record<string, string>; pending?: Pending[] }
const key = (user: string, concert: string) => `fds.attempt.v1.${user}.${concert}`
export function localAttempt(user: string, concert: string): LocalAttempt | null {
  try { return JSON.parse(sessionStorage.getItem(key(user, concert)) ?? 'null') } catch { return null }
}
// COMPLETED 또는 FAILED/ABANDONED/EXPIRED 로 끝난 시도. 서버는 이후 새 전이를 받지 않으므로 다음 예매는 새 attemptId 로 시작해야 한다.
export const isTerminal = (a: Pick<Attempt, 'stage' | 'status'>) => a.stage === 'COMPLETED' || ['FAILED', 'ABANDONED', 'EXPIRED'].includes(a.status)
export function clearAttempt(user: string, concert: string) { sessionStorage.removeItem(key(user, concert)) }
export function operationTransition(user: string, concert: string, operation: string): string | undefined {
  const local = localAttempt(user, concert)
  if (!local) return undefined
  local.transitions[operation] ??= crypto.randomUUID()
  sessionStorage.setItem(key(user, concert), JSON.stringify(local))
  return local.transitions[operation]
}
export async function startAttempt(user: string, concert: string): Promise<Attempt> {
  let local = localAttempt(user, concert)
  if (!local) {
    local = { attemptId: crypto.randomUUID(), clientOccurredAt: new Date().toISOString(), transitions: {} }
    sessionStorage.setItem(key(user, concert), JSON.stringify(local))
  }
  if (USE_MOCK_TICKETING) return { attemptId: local.attemptId, concertId: concert, stage: 'STARTED', status: 'ENTERED', sequence: 1, holdId: null, bookingId: null }
  return request('PUT', `/concerts/${concert}/booking-attempts/${local.attemptId}`, { clientOccurredAt: local.clientOccurredAt })
}
export async function getAttempt(user: string, concert: string): Promise<Attempt | null> {
  const local = localAttempt(user, concert)
  if (!local) return null
  if (USE_MOCK_TICKETING) return startAttempt(user, concert)
  try { await flushStages(user, concert) } catch (error) {
    // 409: 서버가 남은 단계를 받지 않는다. 서버 상태를 확인해 시도가 이미 끝났을 때만 그 단계를 정리한다.
    // (끝난 시도에는 새 전이를 기록할 수 없다. 이대로 두면 같은 탭의 다음 예매가 계속 막힌다.)
    if (!(error instanceof ApiError) || error.status !== 409) throw error
    const server = await request<Attempt>('GET', `/booking-attempts/${local.attemptId}`)
    if (!isTerminal(server)) throw error
    const latest = localAttempt(user, concert)
    if (latest?.attemptId === local.attemptId) { latest.pending = [];sessionStorage.setItem(key(user, concert), JSON.stringify(latest)) }
    return server
  }
  return request('GET', `/booking-attempts/${local.attemptId}`)
}
export async function reportStage(user: string, concert: string, stage: string, status = 'ENTERED'): Promise<void> {
  const local = localAttempt(user, concert)
  if (!local || USE_MOCK_TICKETING) return
  // Persist before sending; reload and lost-response retries use the same body.
  const identity = `${stage}:${status}`
  local.transitions[identity] ??= crypto.randomUUID()
  const transitionId = local.transitions[identity]
  local.pending ??= []
  if (!local.pending.some(p => p.transitionId === transitionId)) local.pending.push({ transitionId, stage, status })
  sessionStorage.setItem(key(user, concert), JSON.stringify(local))
  await flushStages(user, concert)
}

// A failed capability lookup is an error, never permission to bypass recording.
export async function attemptsEnabled(): Promise<boolean> {
  if (USE_MOCK_TICKETING) return false
  return (await request<{ enabled: boolean }>('GET', '/booking-attempts/capabilities')).enabled
}
export async function retryTransient<T>(work: () => Promise<T>): Promise<T> {
  for (let n = 0; ; n++) {
    try { return await work() } catch (error) {
      if (n >= 2 || (error instanceof ApiError && error.status < 500 && error.status !== 429)) throw error
      await new Promise(resolve => setTimeout(resolve, 100 * 2 ** n))
    }
  }
}
// 저장된 미전송 단계를 순서대로 보낸다. 응답을 확인한 단계만 저장소에서 지운다.
async function drain(user: string, concert: string): Promise<void> {
  const storageKey = key(user, concert)
  for (;;) {
    const local = localAttempt(user, concert)
    const next = local?.pending?.[0]
    if (!local || !next || USE_MOCK_TICKETING) return
    await retryTransient(() => request('POST', `/booking-attempts/${local.attemptId}/transitions`, next))
    const latest = localAttempt(user, concert)
    if (!latest || latest.attemptId !== local.attemptId) return
    latest.pending = latest.pending?.filter(p => p.transitionId !== next.transitionId)
    sessionStorage.setItem(storageKey, JSON.stringify(latest))
  }
}
// 같은 시도의 전송은 한 번에 하나씩 이어서 실행한다.
// 진행 중인 전송에 편승해 그대로 돌아오면, 그 전송이 저장소를 읽은 뒤에 추가된 단계는 보내지지 않은 채 "전송 완료"로 보고된다.
// (결제 화면이 열릴 때 상태 조회와 PAYMENT 기록이 동시에 시작되어 PAYMENT/ENTERED 가 누락되던 원인)
// 그래서 호출마다 앞선 전송이 끝난 뒤 저장소를 다시 읽어 남은 단계를 보낸다.
const flushing = new Map<string, Promise<void>>()
export function flushStages(user: string, concert: string): Promise<void> {
  const storageKey = key(user, concert)
  const previous = flushing.get(storageKey) ?? Promise.resolve()
  const work = previous.catch(() => { }).then(() => drain(user, concert))
  flushing.set(storageKey, work)
  const release = () => { if (flushing.get(storageKey) === work) flushing.delete(storageKey) }
  work.then(release, release)
  return work
}

// Store only a digest of the CAPTCHA input, including when attempts are disabled.
export async function captchaTransition(user: string, concert: string, challenge: string, answer: string): Promise<string> {
  const bytes = new TextEncoder().encode(`${challenge}:${answer}`)
  const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), b => b.toString(16).padStart(2, '0')).join('')
  const storageKey = `fds.captcha.v1.${user}.${concert}.${digest}`
  let identity = sessionStorage.getItem(storageKey)
  if (!identity) { identity = crypto.randomUUID();sessionStorage.setItem(storageKey, identity) }
  return identity
}
