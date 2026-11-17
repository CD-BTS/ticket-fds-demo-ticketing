// ---- 공통 응답 envelope (API 명세서 2. 공통 응답 구조) ----
export interface ApiEnvelope<T> {
  success: boolean
  code: string
  message: string
  data: T
}

// ---- BTS API ----
export interface BtsUser {
  userId: string
  // 명세서에 응답 필드가 없어 최소 필드만 정의. 백엔드 확정 후 보완.
  [key: string]: unknown
}

/**
 * POST /api/v1/events 요청 body.
 * ⚠️ 명세서에 필드 정의가 없음 → 서연(BE)에게 확인 필요. 아래는 가정.
 */
export type BehaviorEventType =
  | 'JOIN_QUEUE'
  | 'VIEW_CONCERT'
  | 'VIEW_SEATS'
  | 'SELECT_SEAT'
  | 'HOLD_SEAT'
  | 'HOLD_FAILED'
  | 'ENTER_PAYMENT'
  | 'BOOKING_CONFIRM'
  | 'BOOKING_CANCEL'

export interface BehaviorEventPayload {
  userId: string
  eventType: BehaviorEventType
  occurredAt: string // ISO 8601
  deviceId: string
  metadata?: Record<string, unknown>
}

// ---- 티켓팅 서비스 (명세서에 없음 → 서연 2차에서 정의 예정, 현재는 mock) ----
export interface Concert {
  id: string
  title: string
  artist: string
  venue: string
  startAt: string
  priceFrom: number
  tagline: string
  hue: number // 포스터 색상용
}

export type SeatStatus = 'AVAILABLE' | 'HELD' | 'BOOKED'
export type SeatGrade = 'VIP' | 'R' | 'S'

export interface Seat {
  id: string // e.g. "A-05"
  row: string
  number: number
  grade: SeatGrade
  price: number
  status: SeatStatus
  heldByMe?: boolean
}

export interface SeatHold {
  holdId: string
  concertId: string
  seatIds: string[]
  expiresAt: string
}

export type BookingStatus = 'CONFIRMED' | 'CANCELLED'

export interface Booking {
  id: string
  concertId: string
  concertTitle: string
  venue: string
  startAt: string
  seatIds: string[]
  totalPrice: number
  status: BookingStatus
  createdAt: string
}

// ---- 입장용 QR ----
/**
 * 예매 건별 입장 QR 데이터. 백엔드(인영) QR API 확정 후 필드 보완.
 * 지금은 정적 QR이지만 추후 동적 QR(15초마다 갱신)로 바뀔 예정:
 *  - token: QR에 담길 문자열(검표 서버가 검증)
 *  - refreshIntervalSec: 있으면 그 주기(15)로 다시 받아와 QR 교체
 */
export interface TicketQr {
  token: string
  expiresAt?: string
  refreshIntervalSec?: number
}

// ---- 티켓별 동적 QR · 기기 바인딩 (docs/api-spec.md "티켓과 동적 QR") ----
export type TicketStatus = 'ISSUED' | 'CHECKED_IN' | 'CANCELLED'

export interface TicketDevice {
  deviceId: string
  registeredAt: string
  /** 남은 기기 변경 횟수(티켓당 최대 3회) */
  changesRemaining: number
}

/** 예매 좌석 1개 = 티켓 1장. device 가 null 이면 아직 입장 기기를 등록하지 않은 티켓 */
export interface Ticket {
  ticketId: string
  seatId: string
  status: TicketStatus
  checkedInAt: string | null
  device: TicketDevice | null
}

export interface DeviceChallenge {
  challengeId: string
  challenge: string
  expiresAt: string
}

/** 기기 등록·변경 응답. totp.secret 은 이 응답에서 한 번만 내려온다. */
export interface DeviceEnrollment {
  ticketId: string
  deviceId: string
  totp: { secret: string; algorithm: 'SHA1'; digits: number; period: number }
  registeredAt: string
  serverTime: string
  changesRemaining: number
}

export interface CheckInResult {
  ticketId: string
  concertTitle: string
  seatId: string
  checkedInAt: string
}

// ---- 계정 등급 / 의심 점수 (산식: src/risk/credit.ts, Feature: src/risk/features.ts) ----
import type { AppliedStanding, CreditResult } from '../risk/credit'
import type { BehaviorFeatures } from '../risk/features'
/**
 * CreditResult 는 브라우저 참고 산정, applied 는 화면에 표시할 최종 등급(서버 정책 우선).
 * 서버와 연동 중인데 정책을 받아오지 못하면 applied 는 null 이다(참고값을 실제 등급처럼 보이지 않게 한다).
 */
export type AccountRisk = CreditResult & { features: BehaviorFeatures; applied: AppliedStanding | null }
