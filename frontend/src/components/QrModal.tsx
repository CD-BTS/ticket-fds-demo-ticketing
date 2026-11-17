import { QRCodeSVG } from 'qrcode.react'
import { useEffect, useState } from 'react'
import { USE_MOCK_TICKETING } from '../api/client'
import { ticketing } from '../api/ticketing'
import type { Booking, TicketQr as MockQr } from '../api/types'
import { seatLabel } from './format'
import TicketQr from './TicketQr'

interface Props {
  booking: Booking
  userId: string
  onClose: () => void
}

type State = { status: 'loading' } | { status: 'empty' } | { status: 'error'; message: string } | { status: 'ready'; qr: MockQr }

/**
 * 입장용 QR 모달.
 * - 실제 API 모드: 티켓별 기기 바인딩 + 동적 QR(TicketQr). QR은 등록된 기기가 직접 만든다.
 * - Mock 모드(VITE_USE_MOCK_TICKETING): 화면 확인용 정적 mock QR(VITE_MOCK_QR=true)만 보여준다.
 */
export default function QrModal({ booking, userId, onClose }: Props) {
  const [state, setState] = useState<State>({ status: 'loading' })

  useEffect(() => {
    if (!USE_MOCK_TICKETING) return
    let alive = true
    ticketing
      .getTicketQr(booking.id, userId)
      .then((qr) => alive && setState(qr ? { status: 'ready', qr } : { status: 'empty' }))
      .catch((e: Error) => alive && setState({ status: 'error', message: e.message }))
    return () => {
      alive = false
    }
  }, [booking.id, userId])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" role="dialog" aria-modal="true" aria-label="입장 QR" onClick={(e) => e.stopPropagation()}>
        <h2>입장 QR</h2>
        <p className="meta">{booking.concertTitle}</p>
        <p className="meta">좌석 {seatLabel(booking.seatIds)}</p>

        {USE_MOCK_TICKETING ? (
          <div className="qr-box">
            {state.status === 'loading' && <p className="muted">QR을 불러오는 중…</p>}
            {state.status === 'empty' && (
              <p className="muted">
                입장 QR이 아직 발급되지 않았습니다.
                <br />
                공연 입장 전에 다시 확인해 주세요.
              </p>
            )}
            {state.status === 'error' && <p className="error">{state.message}</p>}
            {state.status === 'ready' && (
              <QRCodeSVG value={state.qr.token} size={220} bgColor="#ffffff" fgColor="#000000" level="M" marginSize={2} />
            )}
          </div>
        ) : (
          <TicketQr booking={booking} userId={userId} />
        )}

        <button className="btn btn-primary btn-block" onClick={onClose}>닫기</button>
      </div>
    </div>
  )
}
