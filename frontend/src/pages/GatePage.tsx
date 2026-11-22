import jsQR from 'jsqr'
import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiError } from '../api/client'
import { sleep } from '../api/client'
import { scanQr, scanStatus } from '../api/tickets'
import type { CheckInScan } from '../api/types'
import { dateTime } from '../components/format'

const KEY_STORE = 'fds.gateKey'

type Outcome =
  | { ok: true; title: string; detail: string; at: number }
  | { ok: false; title: string; detail: string; at: number }

/** 등록 기기의 응답 확인 주기와, 서버 판정(EXPIRED)이 오지 않을 때의 안전 한도. */
const STATUS_POLL_MS = 500
const STATUS_WAIT_LIMIT_MS = 60_000

/** 스캔은 통과했지만 등록 기기의 실시간 응답으로 확정되지 않은 경우. */
const UNCONFIRMED: Record<string, string> = {
  EXPIRED: '등록 기기가 응답하지 않았습니다 — 캡처한 QR이거나 기기가 오프라인입니다. 예매자 기기의 QR 화면을 다시 제시',
  REJECTED: '등록 기기 확인 실패 — 등록된 기기가 아닙니다',
  SUPERSEDED: '같은 티켓이 다시 스캔되어 이 검표는 취소되었습니다',
  PENDING: '등록 기기의 응답을 확인하지 못했습니다. 다시 스캔해 주세요',
}

const REASONS: Record<string, string> = {
  UNAUTHORIZED: '검표 담당자 키가 올바르지 않습니다',
  QR_INVALID: '입장 QR이 아닙니다',
  QR_REJECTED: '유효하지 않은 QR (등록 기기 불일치 또는 위·변조)',
  QR_EXPIRED: '만료된 QR — 화면의 최신 QR을 다시 제시',
  CHECKIN_NOT_OPEN: '입장 가능 시간이 아닙니다',
  CHECKIN_NOT_FOUND: '검표 요청을 찾을 수 없습니다. 다시 스캔해 주세요',
  TICKET_NOT_FOUND: '존재하지 않는 티켓',
  TICKET_ALREADY_CHECKED_IN: '이미 입장 처리된 티켓',
  TICKET_NOT_ADMITTABLE: '취소되었거나 사용할 수 없는 티켓',
  SERVICE_UNAVAILABLE: '검표 기능이 비활성화되어 있습니다',
}

/**
 * 공연장 검표기 화면 (/gate).
 * Demo 사용자 로그인과 무관하며 검표 담당자 키(X-Gate-Key)로만 인증한다. 키는 탭을 닫으면 사라지는 sessionStorage 에 둔다.
 * QR 내용은 해석하지 않고 그대로 서버에 보내며, 판정은 전부 서버가 한다.
 * 검표는 2단계다: 스캔(QR 검증 + 챌린지 발급) → 등록 기기가 챌린지에 서명할 때까지 대기 → 결과 표시.
 * QR이 유효해도 등록 기기의 응답이 없으면(캡처본) 입장 불가로 끝난다.
 */
export default function GatePage() {
  const [gateKey, setGateKey] = useState(() => {
    try {
      return sessionStorage.getItem(KEY_STORE) ?? ''
    } catch {
      return ''
    }
  })
  const [manual, setManual] = useState('')
  const [scanning, setScanning] = useState(false)
  const [cameraError, setCameraError] = useState('')
  const [outcome, setOutcome] = useState<Outcome | null>(null)
  const [waiting, setWaiting] = useState<CheckInScan | null>(null)
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
    }
  }, [])
  const [history, setHistory] = useState<Outcome[]>([])
  const video = useRef<HTMLVideoElement>(null)
  const busy = useRef(false)
  const last = useRef({ text: '', at: 0 })

  const saveKey = (value: string) => {
    setGateKey(value)
    try {
      sessionStorage.setItem(KEY_STORE, value)
    } catch {
      /* ignore */
    }
  }

  const submit = useCallback(
    async (raw: string) => {
      const text = raw.trim()
      if (!text || busy.current) return
      // 카메라가 같은 QR을 연속으로 읽어도 한 번만 보낸다.
      if (last.current.text === text && Date.now() - last.current.at < 4000) return
      last.current = { text, at: Date.now() }
      busy.current = true
      let result: Outcome
      try {
        let scan = await scanQr(gateKey, text)
        if (mounted.current) {
          setOutcome(null)
          setWaiting(scan)
        }
        const startedAt = Date.now()
        while (scan.status === 'PENDING' && mounted.current && Date.now() - startedAt < STATUS_WAIT_LIMIT_MS) {
          await sleep(STATUS_POLL_MS)
          scan = await scanStatus(gateKey, scan.checkInId)
        }
        result =
          scan.status === 'COMPLETED'
            ? { ok: true, title: '입장 가능', detail: `${scan.concertTitle} · 좌석 ${scan.seatId} · ${scan.checkedInAt ? dateTime(scan.checkedInAt) : ''}`, at: Date.now() }
            : { ok: false, title: '입장 불가', detail: UNCONFIRMED[scan.status] ?? '검표를 확정하지 못했습니다', at: Date.now() }
      } catch (e) {
        const code = e instanceof ApiError ? e.code : 'NETWORK'
        result = { ok: false, title: '입장 불가', detail: REASONS[code] ?? (e instanceof ApiError ? e.message : '서버에 연결할 수 없습니다'), at: Date.now() }
      } finally {
        busy.current = false
        // 대기 시간만큼 지난 뒤에도 카메라 앞의 같은 QR을 곧바로 다시 보내지 않는다.
        last.current = { text, at: Date.now() }
      }
      if (!mounted.current) return
      setWaiting(null)
      setOutcome(result)
      setHistory((items) => [result, ...items].slice(0, 6))
    },
    [gateKey],
  )

  useEffect(() => {
    if (!scanning) return
    let stream: MediaStream | null = null
    let frame = 0
    let stopped = false
    let lastScan = 0
    const canvas = document.createElement('canvas')
    const context = canvas.getContext('2d', { willReadFrequently: true })

    const loop = (time: number) => {
      if (stopped) return
      const element = video.current
      if (element && context && element.readyState >= 2 && time - lastScan > 120) {
        lastScan = time
        const scale = Math.min(1, 640 / element.videoWidth)
        canvas.width = Math.round(element.videoWidth * scale)
        canvas.height = Math.round(element.videoHeight * scale)
        context.drawImage(element, 0, 0, canvas.width, canvas.height)
        const image = context.getImageData(0, 0, canvas.width, canvas.height)
        const code = jsQR(image.data, image.width, image.height, { inversionAttempts: 'dontInvert' })
        if (code?.data) void submit(code.data)
      }
      frame = requestAnimationFrame(loop)
    }

    setCameraError('')
    if (!navigator.mediaDevices?.getUserMedia) {
      setCameraError('카메라를 사용할 수 없습니다. HTTPS 또는 localhost 에서 접속하거나 아래에 QR 문자열을 입력해 주세요.')
      setScanning(false)
      return
    }
    navigator.mediaDevices
      .getUserMedia({ video: { facingMode: 'environment' }, audio: false })
      .then((media) => {
        if (stopped) {
          media.getTracks().forEach((track) => track.stop())
          return
        }
        stream = media
        if (video.current) {
          video.current.srcObject = media
          void video.current.play().catch(() => undefined)
        }
        frame = requestAnimationFrame(loop)
      })
      .catch(() => {
        setCameraError('카메라 권한이 없거나 사용할 수 없습니다. 아래에 QR 문자열을 입력해 주세요.')
        setScanning(false)
      })
    return () => {
      stopped = true
      cancelAnimationFrame(frame)
      stream?.getTracks().forEach((track) => track.stop())
    }
  }, [scanning, submit])

  return (
    <div className="gate">
      <h1 className="page-title">검표</h1>
      <p className="muted small">관객 화면의 동적 QR을 스캔하면 서버가 기기 서명·TOTP·티켓 상태·입장 시간을 검증한 뒤, 등록된 기기가 실시간으로 응답해야 입장이 확정됩니다. 캡처한 QR은 확정되지 않습니다.</p>

      <label className="gate-field">
        <span>검표 담당자 키</span>
        <input type="password" autoComplete="off" value={gateKey} onChange={(e) => saveKey(e.target.value)} placeholder="GATE_API_KEY" />
      </label>

      {waiting && (
        <div className="gate-result is-wait" role="status" aria-live="polite">
          <b>기기 확인 중…</b>
          <span>
            {waiting.concertTitle} · 좌석 {waiting.seatId} — 관객 기기의 응답을 기다리는 중입니다
          </span>
        </div>
      )}

      {!waiting && outcome && (
        <div className={`gate-result ${outcome.ok ? 'is-ok' : 'is-no'}`} role="status" aria-live="assertive" key={outcome.at}>
          <b>{outcome.title}</b>
          <span>{outcome.detail}</span>
        </div>
      )}

      <div className="gate-camera">
        {scanning ? <video ref={video} muted playsInline /> : <p className="muted">카메라가 꺼져 있습니다.</p>}
      </div>
      <button className="btn btn-primary btn-block" disabled={!gateKey} onClick={() => setScanning((on) => !on)}>
        {scanning ? '카메라 스캔 중지' : '카메라로 스캔'}
      </button>
      {cameraError && <p className="error" role="alert">{cameraError}</p>}

      <form
        className="gate-manual"
        onSubmit={(e) => {
          e.preventDefault()
          last.current = { text: '', at: 0 } // 직접 입력은 같은 값도 다시 검증한다
          void submit(manual)
        }}
      >
        <label className="gate-field">
          <span>QR 문자열 직접 입력</span>
          <textarea rows={3} value={manual} onChange={(e) => setManual(e.target.value)} placeholder="BTS1.…" spellCheck={false} />
        </label>
        <button className="btn btn-ghost btn-block" disabled={!gateKey || !manual.trim()}>입력한 QR 검표</button>
      </form>

      {history.length > 0 && (
        <ul className="gate-history">
          {history.map((item) => (
            <li key={item.at} className={item.ok ? 'is-ok' : 'is-no'}>
              <b>{item.title}</b> {item.detail}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
