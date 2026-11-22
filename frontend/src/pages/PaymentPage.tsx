import { useEffect, useMemo, useRef, useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { cardsApi, CARD_DIGITS, type PaymentCard } from '../api/cards'
import { ApiError, sleep } from '../api/client'
import { DEFAULT_TEST_CARD_ID, TEST_CARDS, paymentIdentifierFor } from '../api/paymentId'
import { ticketing } from '../api/ticketing'
import { queueApi } from '../api/queue'
import type { Booking, Concert, Seat, SeatHold } from '../api/types'
import { useAuth } from '../auth/AuthContext'
import CardNumberField, { CardHelp } from '../components/CardNumberField'
import { dateTime, seatLabel, won } from '../components/format'
import { useBehavior } from '../hooks/useBehavior'
import { recordRequest, recordStay } from '../risk/signals'
import { clearAttempt, getAttempt, reportStage } from '../api/bookingAttempts'

const PAY_DELAY_MS = 1200

/** 결제 수단: 저장된 테스트 카드(기본)·마이페이지에서 등록해 둔 카드 중 선택하거나, 카드번호를 직접 입력 */
interface PayCard { id: string; nickname: string; last4: string; paymentIdentifier: string }
const DIRECT = 'direct'

export default function PaymentPage() {
  const { id = '' } = useParams()
  const location = useLocation()
  const nav = useNavigate()
  const { userId } = useAuth()
  const track = useBehavior()
  const [hold, setHold] = useState<SeatHold | undefined>((location.state as { hold?: SeatHold } | null)?.hold)
  const [stageReady, setStageReady] = useState(false)
  const [restoring, setRestoring] = useState(!hold)
  const paymentLock = useRef(false)

  const [concert, setConcert] = useState<Concert | null>(null)
  const [seats, setSeats] = useState<Seat[]>([])
  const [cards, setCards] = useState<PaymentCard[] | null>(null)
  const [selectedId, setSelectedId] = useState<string>(DEFAULT_TEST_CARD_ID) // 기본 테스트 카드가 자동 선택된다
  const [digits, setDigits] = useState('') // 직접 입력한 번호(숫자만). 저장·전송하지 않고 화면 state 로만 쓴다.
  const [phase, setPhase] = useState<'form' | 'paying' | 'done'>('form')
  const [paidWith, setPaidWith] = useState('')
  const [booking, setBooking] = useState<Booking | null>(null)
  const [error, setError] = useState('')
  const [leaving, setLeaving] = useState(false)
  const [remaining, setRemaining] = useState(() => (hold ? secondsLeft(hold.expiresAt) : 0))
  const mountedAt = useRef(Date.now())

  useEffect(() => {
    if (!userId) return
    let alive = true
    getAttempt(userId, id).then(async a => {
      if (a?.bookingId) {
        const mine = await ticketing.listMyBookings(userId)
        const existing = mine.find(b => b.id === a.bookingId)
        if (alive && existing) { setBooking(existing);setPhase('done');setHold({ holdId: a.holdId ?? '', concertId: id, seatIds: existing.seatIds, expiresAt: existing.createdAt }) }
      } else if (a?.holdId && !hold) {
        const snapshot = await ticketing.getHold(a.holdId)
        if (alive) setHold(snapshot)
      }
    }).catch(e => { if (alive) setError((e as Error).message) }).finally(() => { if (alive) setRestoring(false) })
    return () => { alive = false }
  }, [userId, id])

  useEffect(() => {
    if (!hold || !userId || phase === 'done') return
    let alive = true
    let timer: ReturnType<typeof setTimeout>
    const record = async () => {
      try { await reportStage(userId, id, 'PAYMENT');if (alive) setStageReady(true) }
      catch (e) { if (alive) { setError((e as Error).message);timer = setTimeout(record, 2000) } }
    }
    setStageReady(false);record()
    return () => { alive = false;clearTimeout(timer) }
  }, [hold, userId, id, phase === 'done'])

  // 결제 화면 체류 시간(step_stay_time)
  useEffect(() => {
    mountedAt.current = Date.now()
    if (!userId) return
    return () => {
      const sec = (Date.now() - mountedAt.current) / 1000
      if (sec >= 0.2) recordStay(userId, 'payment', sec)
    }
  }, [userId])

  useEffect(() => {
    if (!userId || !hold) return
    Promise.all([ticketing.getConcert(id), ticketing.listSeats(id, userId)])
      .then(([c, list]) => {
        setConcert(c)
        setSeats(list)
        track('ENTER_PAYMENT', { concertId: id, seatIds: hold.seatIds })
      })
      .catch((e: Error) => setError(e.message))
    cardsApi
      .list(userId)
      .then(setCards)
      .catch(() => setCards([])) // 등록 카드 목록을 못 불러와도 테스트 카드로 결제할 수 있다
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, userId, hold])

  useEffect(() => {
    if (!hold || phase === 'done') return
    setRemaining(secondsLeft(hold.expiresAt))
    const t = setInterval(() => setRemaining(secondsLeft(hold.expiresAt)), 1000)
    return () => clearInterval(t)
  }, [hold, phase])

  const mySeats = useMemo(() => seats.filter((s) => hold?.seatIds.includes(s.id)), [seats, hold])
  const total = mySeats.reduce((sum, s) => sum + s.price, 0)
  const expired = phase !== 'done' && remaining <= 0
  const ready = mySeats.length > 0 // 좌석·금액 정보가 로딩된 뒤에만 결제 가능
  const paying = phase === 'paying'
  const locked = !stageReady || paying || expired || !ready || leaving // 결제 버튼 비활성 조건
  const payCards = useMemo<PayCard[]>(
    () => [...TEST_CARDS, ...(cards ?? []).map((c) => ({ id: c.id, nickname: c.nickname, last4: c.last4, paymentIdentifier: paymentIdentifierFor(c.last4) }))],
    [cards],
  )
  const direct = selectedId === DIRECT
  // 직접 입력은 끝 4자리로 테스트 결제 식별자를 정한다 (같은 번호면 항상 같은 식별자)
  const selected: PayCard = direct
    ? { id: DIRECT, nickname: '직접 입력 카드', last4: digits.slice(-4), paymentIdentifier: paymentIdentifierFor(digits.slice(-4)) }
    : payCards.find((c) => c.id === selectedId) ?? payCards[0]
  const payable = !locked && (!direct || digits.length === CARD_DIGITS)

  if (restoring) return <p role="status">예매 진행 상태를 확인하고 있습니다.</p>
  if (!hold || !userId) return <section className="card"><p>{error || '선점 정보를 찾지 못했습니다.'}</p><Link to={`/concerts/${id}`}>공연으로 돌아가기</Link></section>

  const goBack = async () => {
    setLeaving(true)
    track('BOOKING_CANCEL', { concertId: id, stage: 'PAYMENT', seatIds: hold.seatIds })
    try {
      await ticketing.releaseHold(hold.holdId, userId)
      await reportStage(userId, id, 'PAYMENT', 'ABANDONED')
      clearAttempt(userId, id)
    } catch {
      setError('선점 해제 상태를 확인하지 못했습니다. 다시 시도해 주세요.')
      setLeaving(false)
      return
    }
    nav(`/concerts/${id}`)
  }

  const pay = async (card: PayCard) => {
    if (!payable || paymentLock.current) return
    paymentLock.current = true
    setPhase('paying')
    setError('')
    recordRequest(userId, 'pay')
    try {
      await sleep(PAY_DELAY_MS) // 결제 시연용 지연. 카드번호는 서버로 전송하지 않는다.
      const b = await ticketing.confirmBooking(hold.holdId, userId, card.paymentIdentifier)
      track('BOOKING_CONFIRM', {
        concertId: id,
        bookingId: b.id,
        seatIds: b.seatIds,
        paymentMethod: card.id === DIRECT ? 'DIRECT_INPUT' : 'SAVED_CARD', // 카드번호 자체는 기록하지 않는다
      })
      // 예매가 끝났으니 대기열 입장 기록을 지운다. 다음 예매 시도에서 보안 확인(캡차)이 다시 나온다.
      queueApi.leave(id).catch(() => { })
      setPaidWith(`${card.nickname} ···· ${card.last4}`)
      setDigits('')
      setBooking(b)
      setPhase('done')
    } catch (e) {
      setError(e instanceof ApiError ? e.message : '결제에 실패했습니다. 다시 시도해 주세요.')
      setPhase('form')
    } finally {
      paymentLock.current = false
    }
  }

  if (phase === 'done' && booking) {
    return (
      <div className="pay-wrap">
        <div className="card pay-card pay-done">
          <span className="badge badge-confirmed">결제 완료</span>
          <h1>예매가 완료되었습니다</h1>
          <p className="meta">{booking.concertTitle}</p>
          <p className="meta">{dateTime(booking.startAt)} · {booking.venue}</p>
          <p className="meta">좌석 {seatLabel(booking.seatIds)}</p>
          <p className="price">{won(booking.totalPrice)}</p>
          <p className="meta">결제 카드 {paidWith}</p>
          <p className="meta small">예매번호 {booking.id}</p>
          <div className="pay-actions">
            <button className="btn btn-primary" onClick={() => nav('/my', { state: { justBooked: booking.id } })}>
              예매 내역 보기
            </button>
            <Link className="btn btn-ghost" to="/">공연 목록으로</Link>
          </div>
        </div>
      </div>
    )
  }

  const mm = String(Math.floor(remaining / 60)).padStart(2, '0')
  const ss = String(remaining % 60).padStart(2, '0')

  return (
    <div className="pay-wrap">
      <h1 className="page-title">결제</h1>
      <div className="pay-grid">
        <section className="card pay-card">
          <h2>예매 정보</h2>
          {concert ? (
            <>
              <p className="pay-concert">{concert.title}</p>
              <p className="meta">{dateTime(concert.startAt)} · {concert.venue}</p>
            </>
          ) : (
            <p className="muted">불러오는 중…</p>
          )}
          <ul className="picked">
            {mySeats.map((s) => (
              <li key={s.id}>
                <span><b>{s.id}</b> · {s.grade}석</span>
                <span>{won(s.price)}</span>
              </li>
            ))}
          </ul>
          <div className="total">
            <span>결제 금액</span>
            <b>{won(total)}</b>
          </div>
        </section>

        <section className="card pay-card">
          <h2>결제 수단</h2>
          <div className="timer" role="status">
            {expired ? '선점 시간이 만료되었습니다' : <>좌석 선점 유지 시간 <b>{mm}:{ss}</b></>}
          </div>
          <p className="small muted pay-hint">테스트 카드를 선택하거나 카드번호를 직접 입력하세요. 실제 결제는 일어나지 않습니다.</p>

          <ul className="card-list" role="radiogroup" aria-label="결제 카드">
            {payCards.map((c) => (
              <li key={c.id}>
                <label className={`card-row card-row-select ${c.id === selected.id ? 'is-selected' : ''}`}>
                  <span className="card-row-main">
                    <input
                      type="radio"
                      name="pay-card"
                      value={c.id}
                      checked={c.id === selected.id}
                      disabled={paying || expired || leaving}
                      onChange={() => setSelectedId(c.id)}
                    />
                    <b>{c.nickname}</b>
                    <span className="masked">···· {c.last4}</span>
                  </span>
                  {c.id === DEFAULT_TEST_CARD_ID && <span className="card-row-act">기본</span>}
                </label>
              </li>
            ))}
            <li>
              <label className={`card-row card-row-select card-row-direct ${direct ? 'is-selected' : ''}`}>
                <span className="card-row-main">
                  <input
                    type="radio"
                    name="pay-card"
                    value={DIRECT}
                    checked={direct}
                    disabled={paying || expired || leaving}
                    onChange={() => setSelectedId(DIRECT)}
                  />
                  <b>카드번호 직접 입력</b>
                </span>
              </label>
              {direct && (
                <div className="direct-form">
                  <CardNumberField value={digits} onChange={setDigits} disabled={locked} autoFocus />
                  <CardHelp count={digits.length} />
                </div>
              )}
            </li>
          </ul>

          <button className="btn btn-primary btn-block pay-submit" disabled={!payable} onClick={() => pay(selected)}>
            {paying ? '결제 처리 중…' : `${won(total)} 결제하기`}
          </button>

          {error && <p className="error" role="alert">{error}</p>}

          <button className="btn btn-ghost btn-block" disabled={paying || leaving} onClick={goBack}>
            {expired ? '좌석 다시 선택' : '이전으로 (좌석 다시 선택)'}
          </button>
        </section>
      </div>
    </div>
  )
}

function secondsLeft(expiresAt: string) {
  return Math.max(0, Math.floor((new Date(expiresAt).getTime() - Date.now()) / 1000))
}
