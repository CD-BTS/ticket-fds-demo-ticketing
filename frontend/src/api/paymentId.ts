/**
 * 데모 백엔드가 허용하는 테스트 결제 식별자 (backend: demo.payment-identifiers).
 * 실제 카드번호나 그 해시를 보내지 않는다. 카드 끝 4자리로 3개 중 하나를 고정 선택하므로
 * 같은 카드를 쓰면 계정이 달라도 같은 식별자가 나가 card_reuse_count 실험이 가능하다.
 */
export const PAYMENT_IDENTIFIERS = ['test-pay-shared-01', 'test-pay-shared-02', 'test-pay-shared-03'] as const

/**
 * 결제 화면에 "이미 등록된 카드"처럼 보여 주는 저장된 테스트 카드.
 * 카드번호·CVV 는 없다. 화면 표시용 이름·마스킹 4자리와 테스트 결제 식별자만 가진다.
 * 카드 하나가 식별자 하나에 고정되므로 같은 카드를 고르면 계정·횟수와 무관하게 항상 같은 식별자가 전송된다.
 */
export interface TestCard {
  id: string
  nickname: string
  last4: string // 표시 전용 (식별자 번호와 맞춘 가짜 값)
  paymentIdentifier: (typeof PAYMENT_IDENTIFIERS)[number]
}

export const TEST_CARDS: readonly TestCard[] = [
  { id: 'test-card-01', nickname: '테스트 카드 A', last4: '0001', paymentIdentifier: 'test-pay-shared-01' },
  { id: 'test-card-02', nickname: '테스트 카드 B', last4: '0002', paymentIdentifier: 'test-pay-shared-02' },
]
export const DEFAULT_TEST_CARD_ID = TEST_CARDS[0].id

export function paymentIdentifierFor(last4: string): string {
  const n = parseInt(last4, 10)
  return PAYMENT_IDENTIFIERS[(Number.isNaN(n) ? 0 : n) % PAYMENT_IDENTIFIERS.length]
}
