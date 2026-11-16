const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const { webcrypto } = require('node:crypto')
const ts = require('typescript')

// src/device/totp.ts 를 브라우저 전역만 주입해 그대로 실행한다(백엔드 Totp/CheckInService 와 같은 형식인지 검증).
function load() {
  const exports = {}
  const source = fs.readFileSync('src/device/totp.ts', 'utf8')
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText
  vm.runInNewContext(js, { exports, crypto: webcrypto, TextEncoder, Uint8Array, ArrayBuffer, DataView, btoa, atob, String, Math })
  return exports
}
const api = load()
const hmacKey = (bytes) => webcrypto.subtle.importKey('raw', bytes, { name: 'HMAC', hash: 'SHA-1' }, false, ['sign'])

test('TOTP matches RFC 6238 SHA-1 vectors (last six digits)', async () => {
  const key = await hmacKey(Buffer.from('12345678901234567890'))
  const vectors = [[59, '287082'], [1111111109, '081804'], [1111111111, '050471'], [1234567890, '005924'], [2000000000, '279037'], [20000000000, '353130']]
  for (const [time, code] of vectors) assert.equal(await api.totpCode(key, api.totpCounter(time)), code)
  assert.equal(api.totpCounter(59), 1)
  assert.equal(api.totpCounter(60), 2)
})

test('base64url round-trips without padding or URL-unsafe characters', () => {
  const bytes = Uint8Array.from([251, 255, 254, 0, 1, 2, 3])
  const text = api.b64url(bytes)
  assert.match(text, /^[A-Za-z0-9_-]+$/)
  assert.deepEqual([...api.fromB64url(text)], [...bytes])
})

test('QR carries ticket, device, time, TOTP and a P-256 signature over the preceding fields', async () => {
  const pair = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify'])
  const totpKey = await hmacKey(Buffer.from('12345678901234567890'))
  const device = { ticketId: '11111111-1111-4111-8111-111111111111', deviceId: '22222222-2222-4222-8222-222222222222', signKey: pair.privateKey, totpKey }
  const qr = await api.buildQr(device, 1111111109)
  // 서버 CheckInService 의 QR 정규식과 같은 형식.
  assert.match(qr, /^BTS1\.[0-9a-f-]{36}\.[0-9a-f-]{36}\.\d{1,12}\.\d{6}\.[A-Za-z0-9_-]{86}$/)
  const parts = qr.split('.')
  assert.deepEqual(parts.slice(0, 5), ['BTS1', device.ticketId, device.deviceId, '1111111109', '081804'])
  const signed = Buffer.from(parts.slice(0, 5).join('.'))
  const signature = Buffer.from(parts[5], 'base64url')
  assert.equal(signature.length, 64)
  assert.equal(await webcrypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pair.publicKey, signature, signed), true)
  assert.equal(await webcrypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pair.publicKey, signature, Buffer.from(signed.toString().replace('081804', '081805'))), false)
  // 키는 추출할 수 없다.
  assert.equal(pair.privateKey.extractable, false)
  await assert.rejects(webcrypto.subtle.exportKey('raw', totpKey))
})

test('registration and change proofs are distinct and bind ticket, challenge and key', () => {
  const register = api.proofMessage(false, 't', 'c', 'k')
  assert.equal(register, 'BTS-DEVICE-REGISTER.t.c.k')
  assert.equal(api.proofMessage(true, 't', 'c', 'k'), 'BTS-DEVICE-CHANGE.t.c.k')
})
