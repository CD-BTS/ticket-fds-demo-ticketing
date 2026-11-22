import { QRCodeSVG } from 'qrcode.react'
import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiError } from '../api/client'
import { answerCheckIn, enrollDevice, listTickets, pendingCheckIn } from '../api/tickets'
import type { Booking, Ticket } from '../api/types'
import { loadDevice, type StoredDevice } from '../device/keystore'
import { buildQr, TOTP_PERIOD, totpCounter } from '../device/totp'
import { dateTime } from './format'

/** QR 표시 중 검표 챌린지 확인 주기. QR 생성·갱신과는 무관하다(QR은 계속 기기 안에서만 만든다). */
const CHECKIN_POLL_MS = 1000

interface Props {
  booking: Booking
  userId: string
}

/**
 * 티켓(좌석)별 동적 QR.
 * - 이 브라우저에 등록된 키가 있으면 재등록 없이 그 키로 30초마다 QR을 새로 만든다.
 * - 최초 등록(등록된 기기 없음)과 기기 변경(다른 기기에 등록됨 → 횟수 차감)은 버튼·문구를 분리한다.
 * - QR은 서버에서 받아오지 않는다. TOTP와 기기 서명 모두 이 기기 안에서 계산한다.
 * - QR이 보이는 동안 검표기가 발급한 챌린지를 확인해 기기 개인키로 자동 서명한다(관객 조작 없음).
 *   캡처본을 받은 다른 기기에는 개인키가 없어 이 응답을 만들 수 없으므로 입장이 확정되지 않는다.
 */
export default function TicketQr({ booking, userId }: Props) {
  const [tickets, setTickets] = useState<Ticket[] | null>(null)
  const [index, setIndex] = useState(0)
  // undefined: 로컬 키 확인 중, null: 이 브라우저에 키 없음
  const [local, setLocal] = useState<StoredDevice | null | undefined>(undefined)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [qr, setQr] = useState('')
  const [remain, setRemain] = useState(TOTP_PERIOD)
  const [confirming, setConfirming] = useState(false)
  const [copied, setCopied] = useState(false)

  const refresh = useCallback(async () => setTickets(await listTickets(booking.id)), [booking.id])

  // 검표되면 화면이 '입장 완료'로 바뀌도록 주기적으로 상태를 다시 읽는다.
  useEffect(() => {
    let alive = true
    refresh().catch((e: Error) => alive && setError(e.message))
    const timer = window.setInterval(() => refresh().catch(() => undefined), 5000)
    return () => {
      alive = false
      window.clearInterval(timer)
    }
  }, [refresh])

  const ticket = tickets?.[index] ?? null
  const ticketId = ticket?.ticketId

  useEffect(() => {
    if (!ticketId) return
    let alive = true
    setLocal(undefined)
    loadDevice(ticketId, userId)
      .then((device) => alive && setLocal(device))
      .catch(() => alive && setLocal(null))
    return () => {
      alive = false
    }
  }, [ticketId, userId])

  const registeredHere = !!ticket?.device && !!local && local.deviceId === ticket.device.deviceId
  const showQr = ticket?.status === 'ISSUED' && registeredHere

  const counter = useRef(-1)
  useEffect(() => {
    if (!showQr || !local) return
    let alive = true
    counter.current = -1
    const tick = () => {
      const now = Math.floor((Date.now() + local.clockOffsetMs) / 1000)
      setRemain(TOTP_PERIOD - (now % TOTP_PERIOD))
      if (totpCounter(now) === counter.current) return
      counter.current = totpCounter(now)
      buildQr(local, now)
        .then((value) => alive && setQr(value))
        .catch(() => alive && setError('QR을 만들지 못했습니다. 기기 변경으로 다시 등록해 주세요.'))
    }
    tick()
    const timer = window.setInterval(tick, 500)
    return () => {
      alive = false
      window.clearInterval(timer)
      setQr('')
    }
  }, [showQr, local])

  // 검표 챌린지 자동 응답. 같은 챌린지에는 한 번만 응답한다(챌린지는 서버에서도 일회성이다).
  const answered = useRef('')
  useEffect(() => {
    if (!showQr || !local) return
    let alive = true
    let working = false
    const poll = async () => {
      if (working) return
      working = true
      try {
        const challenge = await pendingCheckIn(local.ticketId)
        if (!alive || !challenge || challenge.deviceId !== local.deviceId || answered.current === challenge.checkInId) return
        answered.current = challenge.checkInId
        setConfirming(true)
        setError('')
        try {
          await answerCheckIn(local, challenge)
        } catch (e) {
          // 만료·대체된 챌린지 등. 검표기에서 QR을 다시 스캔하면 새 챌린지로 재시도된다.
          if (alive && !(e instanceof ApiError && e.code === 'TICKET_ALREADY_CHECKED_IN'))
            setError('입장 확인에 실패했습니다. 검표기에 QR을 다시 보여 주세요.')
        }
        await refresh().catch(() => undefined)
      } catch {
        /* 일시적인 네트워크 오류는 다음 주기에 다시 시도한다 */
      } finally {
        working = false
        if (alive) setConfirming(false)
      }
    }
    void poll()
    const timer = window.setInterval(() => void poll(), CHECKIN_POLL_MS)
    return () => {
      alive = false
      window.clearInterval(timer)
      setConfirming(false)
    }
  }, [showQr, local, refresh])

  const enroll = async (change: boolean) => {
    if (!ticket) return
    if (
      change &&
      !window.confirm(
        `이 기기로 변경하면 기존 기기의 QR은 즉시 사용할 수 없게 됩니다.\n남은 변경 횟수: ${ticket.device?.changesRemaining ?? 0}회. 계속할까요?`,
      )
    )
      return
    setBusy(true)
    setError('')
    try {
      setLocal(await enrollDevice(ticket.ticketId, userId, change))
    } catch (e) {
      setError(e instanceof ApiError || e instanceof Error ? e.message : '기기 등록에 실패했습니다.')
    } finally {
      await refresh().catch(() => undefined)
      setBusy(false)
    }
  }

  if (!tickets) return <div className="qr-box">{error ? <p className="error">{error}</p> : <p className="muted">티켓을 불러오는 중…</p>}</div>

  return (
    <>
      {tickets.length > 1 && (
        <div className="qr-tabs" role="tablist" aria-label="좌석 선택">
          {tickets.map((t, i) => (
            <button key={t.ticketId} role="tab" aria-selected={i === index} className={i === index ? 'is-active' : ''} onClick={() => setIndex(i)}>
              {t.seatId}
            </button>
          ))}
        </div>
      )}

      <div className="qr-box">
        {!ticket || local === undefined ? (
          <p className="muted">확인 중…</p>
        ) : ticket.status === 'CHECKED_IN' ? (
          <p className="qr-done">
            입장 완료
            <span className="meta">{ticket.checkedInAt ? dateTime(ticket.checkedInAt) : ''}</span>
          </p>
        ) : ticket.status === 'CANCELLED' ? (
          <p className="muted">취소된 티켓입니다.</p>
        ) : showQr ? (
          confirming ? (
            <p className="muted">입장 확인 중…</p>
          ) : qr ? (
            <QRCodeSVG value={qr} size={230} bgColor="#ffffff" fgColor="#000000" level="L" marginSize={2} />
          ) : (
            <p className="muted">QR 생성 중…</p>
          )
        ) : !ticket.device ? (
          <div className="qr-action">
            <p className="muted">입장 QR은 등록한 기기 한 대에서만 표시됩니다.</p>
            <button className="btn btn-primary" disabled={busy} onClick={() => enroll(false)}>
              {busy ? '등록 중…' : '이 기기를 입장 기기로 등록'}
            </button>
          </div>
        ) : (
          <div className="qr-action">
            <p className="muted">
              이 티켓은 다른 기기(또는 저장소가 삭제되기 전의 이 브라우저)에 등록되어 있습니다.
              <br />
              남은 기기 변경 횟수 <b>{ticket.device.changesRemaining}회</b>
            </p>
            <button className="btn btn-ghost" disabled={busy || ticket.device.changesRemaining <= 0} onClick={() => enroll(true)}>
              {busy ? '변경 중…' : '이 기기로 변경'}
            </button>
            {ticket.device.changesRemaining <= 0 && <p className="small muted">변경 횟수를 모두 사용했습니다. 현장 안내 데스크에 문의해 주세요.</p>}
          </div>
        )}
      </div>

      {showQr && qr && (
        <p className="qr-timer" aria-live="off">
          좌석 {ticket.seatId} · <b>{remain}초</b> 후 새 QR로 바뀝니다
        </p>
      )}
      {/* 개발 서버 전용: 카메라 없이 /gate 의 "QR 문자열 직접 입력"으로 시험하기 위한 복사 버튼. 빌드 결과에는 포함되지 않는다. */}
      {import.meta.env.DEV && showQr && qr && (
        <button
          className="btn btn-ghost"
          onClick={() => {
            navigator.clipboard.writeText(qr).then(
              () => setCopied(true),
              () => window.prompt('QR 문자열', qr),
            )
            window.setTimeout(() => setCopied(false), 1500)
          }}
        >
          {copied ? '복사됨' : 'QR 문자열 복사 (개발용)'}
        </button>
      )}
      {showQr && <p className="small muted">검표 시 이 기기가 자동으로 본인 확인에 응답합니다. 화면 캡처만으로는 입장할 수 없으며, 입장 시 인터넷 연결이 필요합니다.</p>}
      {error && <p className="error" role="alert">{error}</p>}
    </>
  )
}
