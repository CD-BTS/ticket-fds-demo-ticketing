// 티켓·기기 바인딩·검표 API (docs/api-spec.md "티켓과 동적 QR")
import { API_BASE, ApiError, request } from './client'
import type { ApiEnvelope, CheckInChallenge, CheckInResult, CheckInScan, DeviceChallenge, DeviceEnrollment, Ticket } from './types'
import { ensureKeystore, saveDevice, type StoredDevice } from '../device/keystore'
import { b64url, checkInMessage, fromB64url, proofMessage, signText } from '../device/totp'

export const listTickets = (bookingId: string) => request<Ticket[]>('GET', `/bookings/${bookingId}/tickets`)

/**
 * 이 브라우저를 티켓의 입장 기기로 등록(change=false)하거나 기존 기기를 대체(change=true)한다.
 * 1) non-extractable ECDSA P-256 키 쌍 생성 → 2) 서버 일회성 챌린지에 서명해 개인키 소유 증명
 * 3) 응답으로 한 번만 오는 TOTP 비밀키를 즉시 non-extractable HMAC 키로 바꿔 IndexedDB 에 저장
 */
export async function enrollDevice(ticketId: string, userId: string, change: boolean): Promise<StoredDevice> {
  if (!globalThis.crypto?.subtle) {
    throw new Error('보안 연결(HTTPS 또는 localhost)에서만 입장 기기를 등록할 수 있습니다.')
  }
  await ensureKeystore()
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  const publicKey = b64url(await crypto.subtle.exportKey('spki', pair.publicKey))
  const challenge = await request<DeviceChallenge>('POST', `/tickets/${ticketId}/device-challenges`, {})
  const proof = await signText(pair.privateKey, proofMessage(change, ticketId, challenge.challenge, publicKey))
  const requestedAt = Date.now()
  const enrolled = await request<DeviceEnrollment>('POST', `/tickets/${ticketId}/device${change ? '/change' : ''}`, {
    challengeId: challenge.challengeId,
    publicKey,
    proof,
  })
  const respondedAt = Date.now()
  const secret = fromB64url(enrolled.totp.secret)
  const totpKey = await crypto.subtle.importKey('raw', secret, { name: 'HMAC', hash: 'SHA-1' }, false, ['sign'])
  secret.fill(0)
  const device: StoredDevice = {
    ticketId,
    userId,
    deviceId: enrolled.deviceId,
    signKey: pair.privateKey,
    totpKey,
    clockOffsetMs: new Date(enrolled.serverTime).getTime() - (requestedAt + respondedAt) / 2,
  }
  await saveDevice(device)
  return device
}

/** 등록 기기: 이 티켓에 대해 검표기가 방금 발급한 챌린지. 없으면 null. */
export const pendingCheckIn = (ticketId: string) => request<CheckInChallenge | null>('GET', `/tickets/${ticketId}/check-in-challenge`)

/** 등록 기기: 챌린지에 기기 개인키로 서명해 입장을 확정한다. 개인키는 기기 밖으로 나가지 않는다. */
export async function answerCheckIn(device: StoredDevice, challenge: CheckInChallenge): Promise<CheckInResult> {
  const proof = await signText(device.signKey, checkInMessage(device.ticketId, device.deviceId, challenge.checkInId, challenge.challenge))
  return request<CheckInResult>('POST', `/tickets/${device.ticketId}/check-in-proofs`, { checkInId: challenge.checkInId, proof })
}

/** 검표기 전용. 사용자 세션(Bearer)이 아니라 검표 담당자 키로 인증하므로 공용 request() 를 쓰지 않는다. */
async function gateRequest<T>(gateKey: string, method: 'GET' | 'POST', path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${API_BASE}/api/v1${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', 'X-Gate-Key': gateKey },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  let json: ApiEnvelope<T> | null = null
  try {
    json = (await res.json()) as ApiEnvelope<T>
  } catch {
    /* 본문이 JSON이 아닌 경우 */
  }
  if (!res.ok || !json || !json.success) {
    throw new ApiError(json?.code ?? `HTTP_${res.status}`, json?.message ?? '요청 처리 중 오류가 발생했습니다.', res.status)
  }
  return json.data
}

/** 검표 1단계: QR 검증 + 등록 기기용 챌린지 발급. 이 시점에는 아직 입장 처리되지 않는다. */
export const scanQr = (gateKey: string, qr: string) => gateRequest<CheckInScan>(gateKey, 'POST', '/check-ins', { qr })

/** 검표기: 등록 기기의 응답 결과 조회. */
export const scanStatus = (gateKey: string, checkInId: string) => gateRequest<CheckInScan>(gateKey, 'GET', `/check-ins/${checkInId}`)
