// 동적 QR 계산(순수 함수). 서버 구현: backend ticket/Totp.java, CheckInService.java 와 형식이 같아야 한다.
// 키는 모두 non-extractable CryptoKey 로만 다룬다. 이 파일은 비밀키 원문을 보관하지 않는다.

export const TOTP_PERIOD = 30

export function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  let text = ''
  for (const byte of view) text += String.fromCharCode(byte)
  return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function fromB64url(value: string): Uint8Array<ArrayBuffer> {
  const text = atob(value.replace(/-/g, '+').replace(/_/g, '/'))
  const bytes = new Uint8Array(new ArrayBuffer(text.length))
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i)
  return bytes
}

export const totpCounter = (epochSeconds: number) => Math.floor(epochSeconds / TOTP_PERIOD)

/** RFC 6238 (HMAC-SHA1, 6자리). key 는 HMAC/SHA-1 sign 용 CryptoKey. */
export async function totpCode(key: CryptoKey, counter: number): Promise<string> {
  const message = new DataView(new ArrayBuffer(8))
  message.setUint32(0, Math.floor(counter / 2 ** 32))
  message.setUint32(4, counter >>> 0)
  const hash = new Uint8Array(await crypto.subtle.sign('HMAC', key, message.buffer))
  const offset = hash[hash.length - 1] & 0x0f
  const binary =
    ((hash[offset] & 0x7f) * 2 ** 24) + (hash[offset + 1] << 16) + (hash[offset + 2] << 8) + hash[offset + 3]
  return String(binary % 1_000_000).padStart(6, '0')
}

/** 기기 개인키(ECDSA P-256) 서명. Web Crypto 는 r||s 64바이트를 돌려준다. */
export async function signText(key: CryptoKey, text: string): Promise<string> {
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(text))
  return b64url(signature)
}

/** 기기 등록·변경 시 서버 챌린지에 대한 개인키 소유 증명 대상 문자열. */
export function proofMessage(change: boolean, ticketId: string, challenge: string, publicKey: string): string {
  return `${change ? 'BTS-DEVICE-CHANGE' : 'BTS-DEVICE-REGISTER'}.${ticketId}.${challenge}.${publicKey}`
}

export interface QrKeys {
  ticketId: string
  deviceId: string
  signKey: CryptoKey
  totpKey: CryptoKey
}

/** QR 내용: BTS1.<ticketId>.<deviceId>.<epochSeconds>.<totp>.<signature> */
export async function buildQr(device: QrKeys, epochSeconds: number): Promise<string> {
  const code = await totpCode(device.totpKey, totpCounter(epochSeconds))
  const body = `BTS1.${device.ticketId}.${device.deviceId}.${epochSeconds}.${code}`
  return `${body}.${await signText(device.signKey, body)}`
}
