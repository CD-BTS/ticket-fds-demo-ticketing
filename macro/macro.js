/*
 * 티켓팅 데모 사이트용 예매 매크로 (부정 사용자 데이터 생성용)
 *
 * 우리가 직접 운영하는 데모 사이트에서만 사용한다.
 * 브라우저를 실제로 조작하므로 프론트의 행동 수집 코드(체류 시간, 좌석 선택 시간 등)가
 * 사람이 쓸 때와 같은 경로로 동작한다.
 *
 * 사용 예:
 *   node macro.js --user macro01 --mode fast
 *   node macro.js --user macro01 --mode jitter --runs 10 --seats 2
 *   node macro.js --user macro01 --mode human --runs 5 --headless
 */
const { chromium } = require('playwright')
const fs = require('fs')

// ---------- 옵션 ----------
function parseArgs(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (!a.startsWith('--')) continue
    const key = a.slice(2)
    const next = argv[i + 1]
    if (next === undefined || next.startsWith('--')) out[key] = true
    else { out[key] = next; i++ }
  }
  return out
}

const args = parseArgs(process.argv.slice(2))
const BASE = String(args.base || 'http://localhost:5173').replace(/\/$/, '')
const MODE = String(args.mode || 'fast')          // fast | jitter | human
const RUNS = Number(args.runs || 1)
const SEATS = Math.min(4, Math.max(1, Number(args.seats || 2)))
const CONCERT = args.concert === undefined ? 0 : args.concert   // 숫자=목록 순서(0부터), 문자열=공연 ID
const HEADLESS = !!args.headless
const OUT = String(args.out || 'macro-results.csv')
const CARD = String(args.card || '123456789012345').replace(/\D/g, '').slice(0, 15).padEnd(15, '0')
const PAY = String(args.pay || 'direct')          // direct | saved
const BASE_USER = String(args.user || 'macro01')
const TIMEOUT = Number(args.timeout || 60) * 1000 // 한 번의 예매에 허용하는 최대 시간(초)
const CANCEL = !!args.cancel                        // 예매가 끝나면 마이페이지에서 바로 취소해 좌석을 되돌린다
const CANCEL_ALL = !!args['cancel-all']             // 예매는 하지 않고 계정들의 확정 예매만 모두 취소한다
const DEBUG = !!args.debug                         // 단계·브라우저 오류를 화면에 출력

// 속도 프로파일 (단위 ms). [최소, 최대] 범위에서 무작위로 쉰다.
const PROFILES = {
  // 단순 매크로: 기다림 없이 최대한 빠르게
  fast:   { pause: [0, 20],      type: 0,        seatGap: [0, 20],       random: false, solveCaptcha: true, captchaThink: [0, 50] },
  // 지연을 섞은 매크로: 요청 간격에 무작위 지연
  jitter: { pause: [120, 600],   type: [15, 60], seatGap: [100, 400],    random: true,  solveCaptcha: true, captchaThink: [300, 900] },
  // 사람 흉내: 사람 범위에 가깝게 느리게 (경계 사례)
  human:  { pause: [900, 2600],  type: [80, 220], seatGap: [700, 2000],  random: true,  solveCaptcha: true, captchaThink: [1500, 4000] },
}
if (!PROFILES[MODE]) {
  console.error(`--mode 는 fast | jitter | human 중 하나여야 합니다. (입력: ${MODE})`)
  process.exit(1)
}
const P = PROFILES[MODE]

// ---------- 유틸 ----------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rand = (min, max) => Math.floor(min + Math.random() * (max - min + 1))
const pick = (range) => (Array.isArray(range) ? rand(range[0], range[1]) : range)
const pause = (range) => sleep(pick(range))

function userFor(index) {
  if (RUNS === 1) return BASE_USER
  const m = BASE_USER.match(/^(.*?)(\d+)$/)
  if (!m) return `${BASE_USER}${String(index + 1).padStart(2, '0')}`
  const n = String(Number(m[2]) + index).padStart(m[2].length, '0')
  return `${m[1]}${n}`
}

async function typeInto(locator, text) {
  if (!P.type) { await locator.fill(text); return }
  await locator.click()
  await locator.pressSequentially(text, { delay: pick(P.type) })
}

// ---------- 마이페이지에서 확정된 예매를 모두 취소 (좌석 되돌리기) ----------
async function cancelAllOnMyPage(page) {
  page.on('dialog', (d) => d.accept()) // '예매를 취소할까요?' 확인창
  await page.getByRole('link', { name: /마이\s?페이지/ }).click()
  await page.getByRole('heading', { name: /마이\s?페이지/ }).waitFor()
  await sleep(800) // 예매 내역을 불러오는 시간
  const cancelBtn = page.getByRole('button', { name: '예매 취소' })
  let n = 0
  for (let guard = 0; guard < 30; guard++) {
    const left = await cancelBtn.count()
    if (!left) break
    await cancelBtn.first().click()
    n++
    // 취소가 반영되어 버튼이 하나 줄 때까지 기다린다
    await page.waitForFunction(
      (c) => [...document.querySelectorAll('button')].filter((b) => b.textContent.trim() === '예매 취소').length < c,
      left,
      { timeout: 10000 },
    ).catch(() => {})
    await pause(P.pause)
  }
  return n
}

async function cancelAllFor(browser, user) {
  const ctx = await browser.newContext()
  const page = await ctx.newPage()
  page.setDefaultTimeout(15000)
  try {
    await page.goto(BASE)
    await page.getByLabel('사용자 ID').waitFor()
    await page.getByLabel('사용자 ID').fill(user)
    await page.getByRole('button', { name: '시작하기' }).click()
    await page.locator('a.concert-card').first().waitFor()
    return { n: await cancelAllOnMyPage(page), error: '' }
  } catch (e) {
    return { n: 0, error: String(e.message || e).split('\n')[0] }
  } finally {
    await ctx.close()
  }
}

// ---------- 예매 1회 ----------
async function runOnce(browser, user) {
  const ctx = await browser.newContext()   // 실행마다 새 브라우저 상태(로컬 저장소 비움)
  const page = await ctx.newPage()
  const t = { start: Date.now() }
  const rel = (k) => (t[k] === undefined ? '' : t[k] - t.start)
  let result = 'OK'
  let error = ''
  let step = 'start'
  const at = (name) => { step = name; if (DEBUG) console.log(`   · ${user} ${name} (+${Date.now() - t.start}ms)`) }
  try {
    page.setDefaultTimeout(TIMEOUT)
    if (DEBUG) {
      page.on('console', (m) => { if (m.type() === 'error') console.log(`   ! 브라우저 오류: ${m.text().slice(0, 200)}`) })
      page.on('pageerror', (e) => console.log(`   ! 페이지 오류: ${String(e.message).slice(0, 200)}`))
      page.on('close', () => console.log(`   ! ${user} 페이지가 닫혔습니다 (단계: ${step})`))
      page.on('crash', () => console.log(`   ! ${user} 페이지가 비정상 종료했습니다 (단계: ${step})`))
    }

    // 1) 로그인
    at('login')
    await page.goto(BASE)
    await page.getByLabel('사용자 ID').waitFor()
    await pause(P.pause)
    await typeInto(page.getByLabel('사용자 ID'), user)
    await pause(P.pause)
    await page.getByRole('button', { name: '시작하기' }).click()
    await page.locator('a.concert-card').first().waitFor()
    t.login = Date.now()

    // 2) 공연 선택
    at('concert')
    await pause(P.pause)
    if (typeof CONCERT === 'string' && !/^\d+$/.test(CONCERT)) await page.goto(`${BASE}/concerts/${CONCERT}`)
    else await page.locator('a.concert-card').nth(Number(CONCERT)).click()
    t.concert = Date.now()

    // 3) 예매하기 → (보안 확인) → 대기 → 좌석 화면
    at('queue')
    const deadline = Date.now() + TIMEOUT
    let begun = false
    let lastSubmit = 0
    // 이 구간은 화면이 수시로 바뀌므로 동작마다 5초만 기다리고, 실패하면 상태를 다시 보고 이어간다
    page.setDefaultTimeout(5000)
    while (Date.now() < deadline) {
      try {
        if (await page.locator('button.seat').count()) break
        const begin = page.getByRole('button', { name: '예매하기', exact: true })
        if (!begun && (await begin.isVisible().catch(() => false))) {
          if (await begin.isEnabled().catch(() => false)) {
            await pause(P.pause)
            if (!t.begin) t.begin = Date.now()
            await begin.click()
            begun = true
          } else {
            await sleep(200) // 진행 상태 확인이 끝나면 버튼이 활성화된다
          }
          continue
        }
        // 산술(mock) 보안 확인: 제출 직후에는 결과를 기다리고 같은 답을 다시 제출하지 않는다
        const answer = page.getByLabel('보안 확인 답')
        if ((await answer.isVisible().catch(() => false)) && Date.now() - lastSubmit > 4000) {
          if (!P.solveCaptcha) { result = 'CAPTCHA_BLOCKED'; throw new Error('보안 확인에서 중단') }
          const text = await page.locator('.waiting p').first().innerText().catch(() => '')
          const q = text.match(/(\d+)\s*\+\s*(\d+)/)
          if (q) {
            await pause(P.captchaThink)
            await typeInto(answer, String(Number(q[1]) + Number(q[2])))
            await page.getByRole('button', { name: '확인', exact: true }).click()
            lastSubmit = Date.now()
            await sleep(300)
            continue
          }
        }
        // hCaptcha 위젯은 매크로가 풀 수 없다 → 여기서 막힌 것으로 기록
        if (await page.locator('.captcha-box').isVisible().catch(() => false)) {
          result = 'CAPTCHA_BLOCKED'
          throw new Error('hCaptcha 위젯에서 중단 (CAPTCHA_MODE 를 disabled/mock 으로 바꾸거나 이 계정을 일반 계정으로 쓰세요)')
        }
        await sleep(250)
      } catch (e) {
        if (page.isClosed() || result !== 'OK') throw e
        if (DEBUG) console.log(`   ! 대기 구간 재시도: ${String(e.message).split('\n')[0]}`)
        await sleep(250)
      }
    }
    page.setDefaultTimeout(TIMEOUT)
    if (!(await page.locator('button.seat').count())) { result = 'TIMEOUT'; throw new Error('좌석 화면에 들어가지 못함') }
    t.seatmap = Date.now()

    // 4) 좌석 선택 + 5) 선점
    // 다른 사람이 먼저 잡았거나 선점이 거절되면 다른 좌석으로 최대 5번까지 다시 시도한다
    let held = false
    for (let attempt = 1; attempt <= 5 && !held; attempt++) {
      at(`seats#${attempt}`)
      // 이전 시도에서 선택된 좌석이 남아 있으면 해제
      const selectedSeats = page.locator('button.seat.seat-selected')
      for (let k = 0; k < 6 && (await selectedSeats.count()); k++) {
        await selectedSeats.first().click({ timeout: 3000 }).catch(() => {})
      }
      // 클릭할 때마다 선택 가능 목록이 바뀌므로, 좌석 ID를 먼저 정해 두고 ID로 클릭한다
      const free = page.locator('button.seat.seat-available')
      const labels = await free.evaluateAll((els) => els.map((e) => e.getAttribute('aria-label') || ''))
      const ids = labels.map((l) => l.split(' ')[0]).filter(Boolean)
      if (ids.length < SEATS) { result = 'NO_SEATS'; throw new Error(`선택 가능한 좌석이 ${ids.length}석뿐`) }
      const chosen = []
      if (P.random) {
        while (chosen.length < SEATS) { const id = ids[rand(0, ids.length - 1)]; if (!chosen.includes(id)) chosen.push(id) }
      } else {
        chosen.push(...ids.slice(0, SEATS))
      }
      await pause(P.pause)
      for (const id of chosen) {
        // 이미 팔린 좌석이면 짧게 기다리다 포기하고 다음 시도에서 다른 좌석을 고른다
        await page.locator(`button.seat[aria-label^="${id} "]`).click({ timeout: 4000 }).catch(() => {})
        if (!t.firstSeat) t.firstSeat = Date.now()
        await pause(P.seatGap)
      }
      if ((await selectedSeats.count()) !== SEATS) { if (DEBUG) console.log(`   ! 좌석 ${SEATS}개를 못 골라 다시 시도`); continue }

      at(`hold#${attempt}`)
      await page.getByRole('button', { name: '선점 후 결제' }).click({ timeout: 4000 }).catch(() => {})
      held = await page.waitForURL(/\/payment/, { timeout: 15000 }).then(() => true).catch(() => false)
      if (!held && DEBUG) {
        const msg = await page.locator('.error[role="alert"]').first().innerText().catch(() => '')
        console.log(`   ! 선점 실패${msg ? ': ' + msg : ''} → 다른 좌석으로 재시도`)
      }
    }
    if (!held) { result = 'HOLD_FAILED'; throw new Error('좌석 선점에 5번 실패') }
    t.hold = Date.now()

    // 6) 결제
    at('payment')
    await pause(P.pause)
    const saved = page.locator('button.card-row:not(.card-row-direct)')
    if (PAY === 'saved' && (await saved.count())) {
      await saved.first().click()
    } else {
      await page.locator('button.card-row-direct').click()
      await pause(P.pause)
      await typeInto(page.locator('input[name="test-card-number"]'), CARD)
      await pause(P.pause)
      await page.getByRole('button', { name: /결제하기/ }).click()
    }
    await page.getByRole('heading', { name: '예매가 완료되었습니다' }).waitFor()
    t.paid = Date.now()
    at('done')
    if (CANCEL) {
      at('cancel')
      try { const n = await cancelAllOnMyPage(page); console.log(`   ↩ ${user} 예매 ${n}건 취소(좌석 반환)`) }
      catch (e) { console.log(`   ! ${user} 취소 실패: ${String(e.message).split('\n')[0]}`) }
    }
  } catch (e) {
    if (result === 'OK') result = 'ERROR'
    error = `[${step}] ` + String(e.message || e).split('\n')[0]
  } finally {
    await ctx.close()
  }
  return {
    time: new Date().toISOString(),
    user, mode: MODE, seats: SEATS, result, error,
    ms_login: rel('login'),
    ms_to_seatmap: rel('seatmap'),
    ms_first_seat: rel('firstSeat'),
    ms_hold: rel('hold'),
    ms_paid: rel('paid'),
    ms_total: t.paid ? t.paid - t.start : '',
    // 예매하기 클릭 → 결제 완료까지 (대기·보안 확인 포함, 로그인 제외)
    ms_booking: t.paid && t.begin ? t.paid - t.begin : (t.paid && t.concert ? t.paid - t.concert : ''),
  }
}

// ---------- 실행 ----------
;(async () => {
  const browser = await chromium.launch({ headless: HEADLESS })
  if (CANCEL_ALL) {
    let total = 0
    for (let i = 0; i < RUNS; i++) {
      const user = userFor(i)
      const r = await cancelAllFor(browser, user)
      total += r.n
      console.log(`[${i + 1}/${RUNS}] ${user} 취소 ${r.n}건${r.error ? ' - ' + r.error : ''}`)
    }
    await browser.close()
    console.log(`끝: 총 ${total}건 취소`)
    return
  }
  const header = 'time,user,mode,seats,result,error,ms_login,ms_to_seatmap,ms_first_seat,ms_hold,ms_paid,ms_total,ms_booking\n'
  if (!fs.existsSync(OUT)) fs.writeFileSync(OUT, header, 'utf8')
  const csvCell = (v) => `"${String(v).replace(/"/g, '""')}"`
  let ok = 0
  for (let i = 0; i < RUNS; i++) {
    const user = userFor(i)
    const r = await runOnce(browser, user)
    if (r.result === 'OK') ok++
    fs.appendFileSync(OUT, Object.values(r).map(csvCell).join(',') + '\n', 'utf8')
    console.log(`[${i + 1}/${RUNS}] ${user} ${r.result}${r.error ? ' - ' + r.error : ''} (총 ${r.ms_total || '-'}ms)`)
    if (i < RUNS - 1) await pause(P.pause)
  }
  await browser.close()
  console.log(`끝: 성공 ${ok}/${RUNS}, 결과 파일 ${OUT}`)
})()
