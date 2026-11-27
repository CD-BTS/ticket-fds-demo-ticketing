#!/usr/bin/env python3
"""#71 Showcase 시연 데이터 생성기 (표준 라이브러리만 사용).

- 공연 10개(좌석 수·참여 규모·진행 상태가 다름)와 사용자 9개 행동 유형의 최근 28일 행동 이력을 결정적으로 만든다.
- 이력은 BTS의 기존 행동 이벤트 API(POST /api/v1/events)로만 넣는다. AI 점수·Credit·정책은 만들지 않는다.
- 이벤트 형식은 demo-ticketing이 실제로 보내는 것과 같다(OutboxDeliveryService·AttemptService·ReservationService).
- 같은 seed·기준 시각이면 사용자 ID·이벤트 ID·시각이 모두 같으므로, 재실행하면 BTS가 200(재전송)으로 처리해 중복이 생기지 않는다.

행동 유형과 파라미터는 ticket-fds-ai의 v4 합성 데이터 정의
(experiments/issue17-event-based-dummy/config/scenarios_v3.json·v4.json, generate_events_v3/v4.py)를 참고했고,
학습(2026)·검증(100~109)·#17(0~9, 42)에 쓰인 seed와 겹치지 않는 seed(기본 7171)를 쓴다. 학습 데이터 파일은 읽지 않는다.
사용자 유형은 데이터 생성 시나리오일 뿐이며 실제 AI 탐지 결과와 같다고 가정하지 않는다.
"""
from __future__ import annotations

import argparse
import hashlib
import heapq
import pickle
import http.client
import json
import math
import os
import random
import subprocess
import sys
import threading
import time
import uuid
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone

DEFAULT_SEED = 7171
SERVICE_ID = 'demo-ticketing'
HOLD_SECONDS = 300          # demo.hold-duration 기본값(PT5M)
HISTORY_DAYS = 28

# ------------------------------------------------------------------ 공연
# open_day/show_day: 기준 시각(anchor) 날짜로부터의 일수. 예매 오픈 20:00 KST(11:00Z), 공연 19:00 KST(10:00Z) 시작·3시간.
# rush: 오픈 직후 몰리는 참여자 비율, macro: 매크로 유형 비율(인기 공연일수록 높다).
CONCERTS = [
    dict(id='sc01', title='인디 아티스트 단독 공연', artist='Moss & Window', venue='홍대 롤링홀', seats=200, cols=20,
         participants=300, open_day=-27, show_day=-18, rush=0.45, macro=0.03, hue=150, tagline='작은 공간을 채우는 첫 단독 무대'),
    dict(id='sc02', title='어쿠스틱 라이브 콘서트', artist='Lumen Folk', venue='예스24 라이브홀', seats=350, cols=25,
         participants=450, open_day=-26, show_day=-14, rush=0.5, macro=0.04, hue=40, tagline='기타 한 대로 채우는 저녁'),
    dict(id='sc03', title='뮤지컬 갈라 콘서트', artist='Stage Ensemble', venue='블루스퀘어 신한카드홀', seats=600, cols=30,
         participants=800, open_day=-25, show_day=-10, rush=0.55, macro=0.05, hue=330, tagline='명장면 넘버를 한 무대에서'),
    dict(id='sc04', title='재즈 뮤직 페스티벌', artist='Blue Hour Quintet 외', venue='올림픽공원 88잔디마당', seats=700, cols=28,
         participants=1000, open_day=-24, show_day=-6, rush=0.6, macro=0.06, hue=210, tagline='잔디 위의 스윙과 블루스'),
    dict(id='sc05', title='가을 음악 축제', artist='Various Artists', venue='난지 한강공원', seats=1000, cols=40,
         participants=1500, open_day=-22, show_day=-3, rush=0.7, macro=0.07, hue=25, tagline='강바람과 함께하는 이틀'),
    dict(id='sc06', title='밴드 전국 투어 — 서울', artist='The Hollow Birds', venue='인스파이어 아레나', seats=1500, cols=50,
         participants=3000, open_day=-12, show_day=10, rush=0.75, macro=0.08, hue=0, tagline='전국 투어의 서울 공연'),
    dict(id='sc07', title='연말 스페셜 콘서트', artist='Nova Lane', venue='KSPO DOME', seats=2000, cols=50,
         participants=5000, open_day=-7, show_day=25, rush=0.8, macro=0.10, hue=265, tagline='한 해를 마무리하는 스페셜 셋리스트'),
    dict(id='sc08', title='인기 아이돌 단독 콘서트', artist='STARLIGHT', venue='고척스카이돔', seats=3000, cols=60,
         participants=10000, open_day=-2, show_day=18, rush=0.88, macro=0.12, hue=300, tagline='매진 예상, 오픈 즉시 대기열'),
    dict(id='sc09', title='클래식 오케스트라 공연', artist='Seoul Civic Orchestra', venue='예술의전당 콘서트홀', seats=800, cols=32,
         participants=0, open_day=5, show_day=40, rush=0.5, macro=0.0, hue=45, tagline='신년을 여는 교향곡'),
    dict(id='sc10', title='신년 뮤직 페스티벌', artist='Various Artists', venue='킨텍스 제1전시장', seats=2500, cols=50,
         participants=0, open_day=8, show_day=36, rush=0.8, macro=0.0, hue=120, tagline='새해 첫 주말의 페스티벌'),
]
GRADE_PRICE = {'VIP': 154000, 'R': 132000, 'S': 99000}   # backend/db/seed.sql과 같은 가격표

HUMAN_TYPES = ['normal', 'fast_normal', 'shared_ip', 'frequent_cancel', 'no_show']
MACRO_TYPES = ['macro_fixed', 'macro_jitter', 'macro_multi', 'macro_hold_cancel']
TYPE_LABEL = {
    'normal': '일반 사용자', 'fast_normal': '빠른 정상 사용자', 'shared_ip': 'IP 공유 정상 사용자',
    'frequent_cancel': '잦은 취소 사용자', 'no_show': '미입장 사용자', 'macro_fixed': '고정 간격 매크로',
    'macro_jitter': '랜덤 지연 매크로', 'macro_multi': '다중 계정 매크로', 'macro_hold_cancel': '선점·취소 매크로',
    'newcomer': '신규 가입(행동 이력 없음)',
}
HUMAN_MIX = {'normal': 0.60, 'fast_normal': 0.12, 'shared_ip': 0.11, 'frequent_cancel': 0.08, 'no_show': 0.09}
MACRO_MIX = {'macro_fixed': 0.30, 'macro_jitter': 0.30, 'macro_multi': 0.25, 'macro_hold_cancel': 0.15}
# 사람 유형별 시도 결과 확률 (complete / abandon_seat / hold_left) — ai scenarios_v3.json의 값을 따름.
HUMAN_OUTCOME = {
    'normal': (0.80, 0.12, 0.08), 'fast_normal': (0.90, 0.07, 0.03), 'shared_ip': (0.80, 0.12, 0.08),
    'frequent_cancel': (0.85, 0.10, 0.05), 'no_show': (0.85, 0.10, 0.05),
}
REUSE_PROB = {'human': 0.38, 'macro': 0.55}
NEWCOMER_SHARE = 0.015   # 가입만 하고 행동 이력이 없는 사용자(AI 평가 이력 없음)


def iso_ms(t: datetime) -> str:
    return t.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.') + f'{t.microsecond // 1000:03d}Z'


def iso_s(t: datetime) -> str:
    return t.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def ms(t: datetime) -> datetime:
    return t.replace(microsecond=(t.microsecond // 1000) * 1000)


def row_label(i: int) -> str:
    s = ''
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        s = chr(65 + r) + s
    return s


# ------------------------------------------------------------------ 계획(plan) 생성
class Plan:
    def __init__(self, seed: int, anchor: datetime):
        self.seed = seed
        self.anchor = anchor
        self.ns = uuid.uuid5(uuid.NAMESPACE_URL, f'https://bts.example/showcase/{seed}')
        self.rng = random.Random(seed)
        self.users: dict[str, dict] = {}       # externalUserId -> user
        self.units: list[dict] = []            # 함께 적재할 묶음(공유 IP·결제수단 그룹)
        self.events: dict[str, list] = defaultdict(list)
        self.concerts = []
        self.concert_stats: dict[str, Counter] = {}
        self.participants: dict[str, set] = defaultdict(set)
        self._ip_seq = 0
        self._card_seq = 0
        self._counter = Counter()
        self._build()

    # ---- 결정적 ID
    def uid(self, *parts) -> str:
        return str(uuid.uuid5(self.ns, '|'.join(map(str, parts))))

    def next_id(self, user: str, kind: str) -> str:
        self._counter[(user, kind)] += 1
        return self.uid(user, kind, self._counter[(user, kind)])

    def new_ip(self) -> str:
        self._ip_seq += 1
        i = self._ip_seq
        return f'100.{64 + (i >> 16) % 64}.{(i >> 8) % 256}.{i % 256 or 1}'

    def new_card(self) -> str:
        self._card_seq += 1
        return f'sc-pay-{self._card_seq:05d}'

    # ---- 공연 일정
    def _concert_times(self, c):
        day0 = self.anchor.replace(hour=0, minute=0, second=0, microsecond=0)
        opens = day0 + timedelta(days=c['open_day'], hours=11)
        starts = day0 + timedelta(days=c['show_day'], hours=10)
        ends = starts + timedelta(hours=3)
        if opens >= self.anchor:
            status = 'SCHEDULED'
        elif ends <= self.anchor:
            status = 'ENDED'
        else:
            status = 'ON_SALE'
        return opens, starts, ends, status

    # ---- 사용자·그룹
    def _new_unit(self, utype: str) -> dict:
        rng = self.rng
        if utype == 'shared_ip':
            size = rng.randint(4, 6)
        elif utype == 'macro_multi':
            size = rng.randint(5, 11)
        elif utype in ('macro_fixed', 'macro_jitter'):
            size = 1 if rng.random() < 0.6 else 2
        else:
            size = 1
        unit = {'id': len(self.units), 'type': utype, 'members': [], 'concerts': set()}
        shared_ip = self.new_ip() if size > 1 else None
        cards = []
        if utype == 'macro_multi':
            cards = [self.new_card()] * min(size, 7) + [self.new_card()] * max(0, size - 7)
            unit['tool'] = rng.choice(['fixed', 'jitter', 'human'])
        elif utype in ('macro_fixed', 'macro_jitter') and size == 2 and rng.random() < 0.5:
            card = self.new_card()
            cards = [card, card]
        for k in range(size):
            ext = f'sc-u{len(self.users) + 1:05d}'
            if utype in ('macro_fixed', 'macro_jitter', 'macro_hold_cancel'):
                speed = 1.0
            elif utype == 'fast_normal':
                speed = 10 ** rng.uniform(-1, -0.5)
            else:
                speed = min(1.0, max(0.1, math.exp(rng.gauss(math.log(0.45), 0.5))))
            cancel_p = {
                'normal': rng.betavariate(1, 9), 'fast_normal': rng.betavariate(1, 8), 'shared_ip': rng.betavariate(1, 9),
                'frequent_cancel': rng.uniform(0.5, 0.8), 'no_show': rng.betavariate(1, 12),
                'macro_fixed': rng.uniform(0.1, 0.4), 'macro_jitter': rng.uniform(0.1, 0.4),
                'macro_multi': rng.uniform(0.3, 0.7), 'macro_hold_cancel': rng.uniform(0.85, 1.0), 'newcomer': 0,
            }[utype]
            user = {
                'ext': ext, 'type': utype, 'unit': unit['id'], 'speed': speed, 'cancel_p': cancel_p,
                'ip': shared_ip or self.new_ip(), 'card': cards[k] if cards else self.new_card(),
                'pace': math.exp(rng.gauss(0, 0.25)),
            }
            self.users[ext] = user
            unit['members'].append(ext)
        self.units.append(unit)
        return unit

    def _pick_units(self, concert, utype: str, quota: int, pool: dict) -> list:
        """quota명을 채울 때까지 기존 그룹을 재사용하거나(같은 사용자가 여러 공연 참여) 새로 만든다."""
        rng = self.rng
        chosen, count = [], 0
        reuse = REUSE_PROB['macro' if utype.startswith('macro') else 'human']
        while count < quota:
            candidates = pool.get(utype, [])
            unit = None
            if candidates and rng.random() < reuse:
                for _ in range(4):
                    u = self.units[rng.choice(candidates)]
                    if concert['id'] not in u['concerts']:
                        unit = u
                        break
            if unit is None:
                if utype == 'no_show' and concert['status'] != 'ENDED':
                    utype_new = 'normal'          # 미입장 유형은 종료 공연에서 처음 생긴다
                else:
                    utype_new = utype
                unit = self._new_unit(utype_new)
                pool.setdefault(utype_new, []).append(unit['id'])
            unit['concerts'].add(concert['id'])
            chosen.append(unit)
            count += len(unit['members'])
        return chosen

    def _build(self):
        rng = self.rng
        pool: dict[str, list] = {}
        for c in CONCERTS:
            opens, starts, ends, status = self._concert_times(c)
            concert = dict(c, opens=opens, starts=starts, ends=ends, status=status)
            self.concerts.append(concert)
            self.concert_stats[c['id']] = Counter()
            if c['participants'] == 0 or status == 'SCHEDULED':
                continue
            n = c['participants']
            n_macro = round(n * c['macro'])
            quotas = {t: round(n_macro * w) for t, w in MACRO_MIX.items()}
            n_human = n - sum(quotas.values())
            hq = {t: round(n_human * w) for t, w in HUMAN_MIX.items()}
            hq['normal'] += n_human - sum(hq.values())
            quotas.update(hq)
            sessions = []
            for utype, q in quotas.items():
                if q <= 0:
                    continue
                for unit in self._pick_units(concert, utype, q, pool):
                    for ext in unit['members']:
                        sessions.append(ext)
            self._simulate(concert, sessions)
        # 가입만 한 신규 사용자
        for _ in range(max(1, round(len(self.users) * NEWCOMER_SHARE))):
            self._new_unit('newcomer')
        for ext in self.events:
            self.events[ext].sort(key=lambda e: (e['t'], e['n']))

    # ---- 이벤트 기록
    def emit(self, user: dict, etype: str, t: datetime, metadata: dict, booking=None, ticket=None):
        ev = {'n': self._counter['__events__'], 't': ms(t), 'type': etype, 'metadata': metadata,
              'id': self.next_id(user['ext'], 'event')}
        self._counter['__events__'] += 1
        if booking:
            ev['bookingId'] = booking
        if ticket:
            ev['ticketId'] = ticket
        self.events[user['ext']].append(ev)

    # ---- 공연 1개의 예매 경쟁 시뮬레이션 (좌석 수를 넘는 예매 성공이 생기지 않는다)
    def _simulate(self, concert, sessions):
        rng = random.Random(f'{self.seed}:{concert["id"]}')
        stats = self.concert_stats[concert['id']]
        seats = concert['seats']
        state = {'free': seats}
        releases = []          # (time, n) 좌석 반환 예정(선점 만료, 취소)
        heap = []
        seq = 0
        opens, starts, ends = concert['opens'], concert['starts'], concert['ends']
        sale_end = min(starts - timedelta(hours=2), self.anchor - timedelta(minutes=10))
        pressure = max(0.0, min(1.0, (len(sessions) / seats - 1) / 3))
        perf = {'performanceStartsAt': iso_s(starts), 'performanceEndsAt': iso_s(ends)}
        cid = concert['id']

        def collision(t):
            # 오픈 직후 같은 좌석을 동시에 고르는 충돌. 경쟁이 심한 공연일수록 크다.
            mins = (t - opens).total_seconds() / 60
            return 0.12 + 0.45 * pressure if mins < 10 else (0.05 + 0.1 * pressure if mins < 60 else 0.02)

        def free_at(t):
            while releases and releases[0][0] <= t:
                _, k = heapq.heappop(releases)
                state['free'] += k
            return state['free']

        def take(t, k):
            if free_at(t) >= k and rng.random() >= collision(t):
                state['free'] -= k
                return True
            return False

        for ext in sessions:
            user = self.users[ext]
            gen =self._session(concert, user, rng, take, releases, perf, sale_end, stats)
            try:
                first = next(gen)
            except StopIteration:
                continue
            heapq.heappush(heap, (first, seq, gen))
            seq += 1
        while heap:
            t, s, gen = heapq.heappop(heap)
            free_at(t)
            try:
                nxt = gen.send(t)
            except StopIteration:
                continue
            heapq.heappush(heap, (nxt, s, gen))
        stats['seats'] = seats
        stats['participants'] = len(self.participants[cid])

    def _arrival(self, concert, user, rng, sale_end):
        opens = concert['opens']
        ut = user['type']
        if ut in ('macro_fixed', 'macro_jitter'):
            return opens + timedelta(seconds=rng.uniform(0, 3))
        if ut in ('macro_multi', 'macro_hold_cancel'):
            return opens + timedelta(seconds=rng.uniform(0, 30))
        if rng.random() < concert['rush']:
            mean = 60 if ut == 'fast_normal' else 180
            return opens + timedelta(seconds=min(3600, rng.expovariate(1 / mean)))
        span = (sale_end - opens).total_seconds() - 600
        return opens + timedelta(seconds=600 + span * rng.betavariate(1, 2.2))

    def _session(self, concert, user, rng, take, releases, perf, sale_end, stats):
        """사용자 1명의 공연 1개 참여. yield로 다음 행동 시각을 알리고, 그 시각의 좌석 상태로 결과를 정한다."""
        ut = user['type']
        cid = concert['id']
        t = self._arrival(concert, user, rng, sale_end)
        if t >= sale_end:
            return
        macro = ut.startswith('macro')
        if ut in ('macro_fixed', 'macro_jitter'):
            n_attempts = int(math.exp(rng.uniform(math.log(6), math.log(32 if concert['rush'] > 0.7 else 18))))
            cap = rng.randint(1, 3)
        elif ut == 'macro_multi':
            n_attempts = int(math.exp(rng.uniform(math.log(3), math.log(20))))
            cap = rng.randint(1, 2)
        elif ut == 'macro_hold_cancel':
            n_attempts = rng.randint(10, 29)
            cap = 99
        else:
            n_attempts = 1 + min(6, int(rng.expovariate(1 / 1.5)))
            cap = 1 + (rng.random() < (0.3 if ut == 'fast_normal' else 0.15))
        booked = 0
        tool = None
        if ut == 'macro_multi':
            tool = self.units[user['unit']]['tool']
        speed = user['speed']
        u = 1 + math.log10(speed)   # 1=느림(사람 평균), 0=빠름

        def stage(fast, slow, sigma=0.3):
            med = fast + (slow - fast) * u if not macro else fast
            return max(0.03, med * math.exp(rng.gauss(0, sigma)) * user['pace'])

        for k in range(n_attempts):
            if t >= sale_end:
                break
            attempt = self.uid(user['ext'], cid, 'attempt', k)
            seqno = [0]
            base = {'attemptId': attempt, 'concertId': cid}
            extra = {}

            def step(when, stg, status, source, transition, more=None):
                seqno[0] += 1
                md = dict(more or {})
                md.update(extra)
                if source == 'CLIENT_REPORT':
                    md['ipAddress'] = user['ip']
                md.update(base)
                md.update({'transitionId': transition, 'stage': stg, 'status': status, 'sequence': seqno[0],
                           'source': source, 'recordedAt': iso_ms(ms(when)).replace('Z', '') + 'Z'})
                if status == 'ABANDONED':
                    md.setdefault('reasonCode', 'USER_CANCELLED')
                self.emit(user, 'BOOKING_ATTEMPT', when, md)

            stats['attempts'] += 1
            self.participants[cid].add(user['ext'])
            t0 = t
            step(t, 'STARTED', 'ENTERED', 'CLIENT_REPORT', 'start', {'clientOccurredAt': iso_ms(ms(t))})
            # 대기열: 오픈 직후 인기 공연은 대기(WAITING) 후 입장
            mins = (t - concert['opens']).total_seconds() / 60
            wait = 0.0
            if mins < 30 and not macro:
                wait = rng.uniform(5, 40) * (1 + 4 * concert['rush'] * max(0.0, 1 - mins / 30))
            tq = t + timedelta(seconds=0.05 + rng.random() * 0.05)
            if wait > 1:
                step(tq, 'QUEUE', 'ENTERED', 'SERVER', 'queue:WAITING:none')
                tq += timedelta(seconds=wait)
            admit = tq + timedelta(minutes=5)
            step(tq, 'QUEUE', 'SUCCEEDED', 'SERVER', f'queue:ADMITTED:{int(admit.timestamp() * 1000)}')
            ts = tq + timedelta(seconds=stage(0.058, 0.15))
            step(ts, 'SEAT_SELECTION', 'ENTERED', 'CLIENT_REPORT', self.uid(attempt, 'seat'))
            t_next = yield ts
            # 결과 정하기
            if macro:
                if booked >= cap:
                    outcome = 'abandon_seat'
                elif ut == 'macro_hold_cancel':
                    outcome = 'complete' if rng.random() < rng.uniform(0.05, 0.3) else 'hold_left'
                elif ut == 'macro_multi':
                    outcome = 'complete' if rng.random() < 0.9 else 'abandon_seat'
                else:
                    outcome = 'complete'
            else:
                p_c, p_a, _ = HUMAN_OUTCOME[ut]
                r = rng.random()
                outcome = 'complete' if r < p_c else ('abandon_seat' if r < p_c + p_a else 'hold_left')
            tickets_n = 1 if macro and ut != 'macro_multi' else (1 if rng.random() < 0.55 else 2)
            if ut in ('macro_fixed', 'macro_jitter'):
                tickets_n = rng.choice([1, 2, 2])
            th = ts + timedelta(seconds=stage(0.4 if macro else 2.058, 20))
            if outcome == 'abandon_seat':
                step(th, 'SEAT_SELECTION', 'ABANDONED', 'CLIENT_REPORT', self.uid(attempt, 'abandon'))
                stats['failed_attempts'] += 1
                t = th
            else:
                held = False
                tries = 1 if macro else 3
                for j in range(tries):
                    t_next = yield th
                    if take(th, tickets_n):
                        held = True
                        break
                    stats['hold_rejected'] += 1
                    step(th, 'SEAT_HOLD', 'REJECTED', 'SERVER', f'hold-rejected:{self.uid(attempt, "rej", j)}',
                         {'reasonCode': 'SEAT_ALREADY_TAKEN'})
                    th += timedelta(seconds=stage(0.3, 6))
                if not held:
                    if not macro:
                        step(th, 'SEAT_HOLD', 'ABANDONED', 'CLIENT_REPORT', self.uid(attempt, 'giveup'))
                    stats['failed_attempts'] += 1
                    t = th
                else:
                    hold = 'h_' + self.uid(attempt, 'hold')
                    extra['holdId'] = hold
                    step(th, 'SEAT_HOLD', 'SUCCEEDED', 'SERVER', f'hold:{hold}')
                    tp = th + timedelta(seconds=stage(0.07 if macro else 0.048, 1.5))
                    step(tp, 'PAYMENT', 'ENTERED', 'CLIENT_REPORT', self.uid(attempt, 'pay'))
                    if outcome == 'hold_left':
                        tx = th + timedelta(seconds=HOLD_SECONDS)
                        heapq.heappush(releases, (tx, tickets_n))
                        step(tx + timedelta(seconds=rng.uniform(0.2, 5)), 'SEAT_HOLD', 'EXPIRED', 'SERVER',
                             f'expired:{hold}', {'reasonCode': 'HOLD_EXPIRED'})
                        stats['failed_attempts'] += 1
                        t = tp + timedelta(seconds=stage(1.0, 8))
                    else:
                        tb = tp + timedelta(seconds=stage(1.3 if macro else 2.425, 15))
                        booking = 'b_' + self.uid(attempt, 'booking')
                        tickets = [self.uid(attempt, 'ticket', i) for i in range(tickets_n)]
                        bmd = {'concertId': cid, **perf, 'ticketIds': tickets, 'attemptId': attempt,
                               'bookingDurationSeconds': round((tb - th).total_seconds(), 6),
                               'paymentIdentifier': user['card'], 'ipAddress': user['ip']}
                        self.emit(user, 'BOOKING', tb, bmd, booking=booking)
                        extra['bookingId'] = booking
                        step(tb + timedelta(milliseconds=rng.randint(10, 60)), 'COMPLETED', 'SUCCEEDED', 'SERVER',
                             f'completed:{booking}')
                        stats['bookings'] += 1
                        stats['success_attempts'] += 1
                        stats['tickets'] += tickets_n
                        booked += 1
                        self._after_booking(concert, user, rng, booking, tickets, attempt, tb, perf, releases, stats)
                        t = tb
            # 다음 시도까지의 간격
            if macro:
                if ut == 'macro_fixed' or tool == 'fixed':
                    gap = rng.gauss(2.9, 0.06)
                elif ut == 'macro_jitter' or tool == 'jitter':
                    gap = rng.uniform(3.9, 6.3)
                elif ut == 'macro_hold_cancel':
                    gap = max(1.5, rng.gauss(5.0, 0.8))
                else:
                    gap = rng.uniform(10.0, 15.0)
                # 시도 시작 간격을 일정하게(고정)·불규칙하게(랜덤 지연) 유지하되, 직전 시도의 동기 처리(t)가 끝난 뒤에 시작한다.
                t = max(t0 + timedelta(seconds=gap), t + timedelta(seconds=0.1))
            else:
                if booked >= cap:
                    break
                if outcome != 'complete' and rng.random() > 0.7:
                    break
                t = t + timedelta(seconds=stage(3.2, 20))
                if rng.random() < 0.12:   # 다른 날 다시 시도
                    t += timedelta(hours=rng.uniform(6, 72))
            yield t

    def _after_booking(self, concert, user, rng, booking, tickets, attempt, tb, perf, releases, stats):
        ut = user['type']
        cid = concert['id']
        cancel_md = {'concertId': cid, **perf, 'ticketIds': tickets, 'attemptId': attempt}
        if rng.random() < user['cancel_p']:
            if ut == 'macro_hold_cancel':
                delay = math.exp(rng.gauss(math.log(1200), 1.0))
            elif ut.startswith('macro'):
                delay = math.exp(rng.gauss(math.log(86400), 1.0))
            else:
                delay = math.exp(rng.gauss(math.log(21600), 1.5))
            tc = tb + timedelta(seconds=max(60, delay))
            if tc < min(concert['starts'] - timedelta(hours=1), self.anchor - timedelta(minutes=5)):
                self.emit(user, 'CANCEL', tc, cancel_md, booking=booking)
                heapq.heappush(releases, (tc, len(tickets)))     # 취소 좌석은 재판매된다
                stats['cancels'] += 1
                stats['cancelled_tickets'] += len(tickets)
                return
        if concert['status'] != 'ENDED':
            return
        # 종료 공연: 입장(CHECK_IN) 또는 미입장. 미입장은 이벤트를 만들지 않고 BTS NoShowScheduler가 판정한다.
        p_attend = {'no_show': 0.1}.get(ut, 0.5 if ut.startswith('macro') else 0.96)
        if rng.random() < p_attend:
            t0 = concert['starts'] - timedelta(minutes=rng.uniform(5, 90))
            for i, ticket in enumerate(tickets):
                md = {'concertId': cid, **perf, 'deviceChanged': False}
                self.emit(user, 'CHECK_IN', t0 + timedelta(seconds=i * rng.uniform(3, 20)), md, booking=booking, ticket=ticket)
                stats['checkins'] += 1
        else:
            stats['noshow_tickets'] += len(tickets)

    # ---- 적재 순서: 첫 묶음에 모든 유형이 들어가도록 유형별로 번갈아 놓고, 그 뒤는 비율대로 섞는다.
    def load_order(self) -> list:
        by_type = defaultdict(list)
        for u in self.units:
            by_type[u['type']].append(u)
        rng = random.Random(f'{self.seed}:order')
        for lst in by_type.values():
            rng.shuffle(lst)
        order, first = [], []
        for t in HUMAN_TYPES + MACRO_TYPES + ['newcomer']:
            first.extend(by_type[t][:2] if t not in ('shared_ip', 'macro_multi') else by_type[t][:1])
        taken = {u['id'] for u in first}
        rest = [u for u in self.units if u['id'] not in taken]
        total = len(rest)
        keyed = []
        for t, lst in by_type.items():
            lst = [u for u in lst if u['id'] not in taken]
            for i, u in enumerate(lst):
                keyed.append(((i + rng.random()) / max(1, len(lst)), u['id'], u))
        keyed.sort(key=lambda x: (x[0], x[1]))
        order = first + [u for _, _, u in keyed]
        assert len(order) == len(self.units) and total == len(keyed)
        return order

    def units_for(self, limit: int | None) -> list:
        out, n = [], 0
        for u in self.load_order():
            if limit is not None and n >= limit:
                break
            out.append(u)
            n += len(u['members'])
        return out

    def summary(self, units=None) -> dict:
        members = set(m for u in (units or self.units) for m in u['members'])
        concerts = []
        for c in self.concerts:
            st = self.concert_stats[c['id']]
            part = [e for e in self.participants[c['id']] if e in members]
            concerts.append({
                'concertId': c['id'], 'title': c['title'], 'status': c['status'], 'seats': c['seats'],
                'opensAt': iso_s(c['opens']), 'startsAt': iso_s(c['starts']), 'endsAt': iso_s(c['ends']),
                'targetParticipants': c['participants'], 'participants': len(part),
                **{k: st[k] for k in ('attempts', 'success_attempts', 'failed_attempts', 'hold_rejected', 'bookings',
                                      'tickets', 'cancels', 'cancelled_tickets', 'checkins', 'noshow_tickets')},
            })
        types = Counter(self.users[m]['type'] for m in members)
        n_events = sum(len(self.events.get(m, [])) for m in members)
        return {'seed': self.seed, 'anchor': iso_s(self.anchor), 'users': len(members), 'usersByType': dict(types),
                'events': n_events, 'concerts': concerts,
                'multiConcertUsers': sum(1 for m in members if sum(m in self.participants[c['id']] for c in self.concerts) > 1)}


# ------------------------------------------------------------------ 입출력
class Bts:
    def __init__(self, base: str, key: str):
        u = base.rstrip('/').split('://', 1)[1]
        self.host, self.port = u.split(':')[0], int(u.split(':')[1]) if ':' in u else 80
        self.key = key
        self.local = threading.local()

    def call(self, method: str, path: str, body=None, retries=5):
        for attempt in range(retries):
            conn = getattr(self.local, 'conn', None)
            if conn is None:
                conn = self.local.conn = http.client.HTTPConnection(self.host, self.port, timeout=30)
            try:
                data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
                conn.request(method, path, body=data, headers={'X-API-Key': self.key, 'Content-Type': 'application/json'})
                r = conn.getresponse()
                text = r.read().decode('utf-8')
                return r.status, (json.loads(text) if text else None)
            except (ConnectionError, http.client.HTTPException, TimeoutError, OSError):
                self.local.conn = None
                time.sleep(0.5 * (attempt + 1))
        raise RuntimeError(f'BTS 요청 실패: {method} {path}')


def sql(db: dict, statement: str) -> list[dict]:
    cmd = ['docker', 'exec', '-i', '-e', f'MYSQL_PWD={db["password"]}', db['container'], 'mysql', f'-u{db["user"]}',
           db['db'], '--batch', '--default-character-set=utf8mb4']
    r = subprocess.run(cmd, input=statement, capture_output=True, text=True, encoding='utf-8')
    if r.returncode != 0:
        raise RuntimeError(f'SQL 실패: {r.stderr.strip()[:500]}')
    lines = [l for l in r.stdout.splitlines() if l]
    if not lines:
        return []
    head = lines[0].split('\t')
    return [dict(zip(head, l.split('\t'))) for l in lines[1:]]


def load_json(path, default):
    if os.path.exists(path):
        with open(path, encoding='utf-8-sig') as f:   # PowerShell 5.1이 쓴 파일은 BOM이 붙는다
            return json.load(f)
    return default


def save_json(path, value):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(value, f, ensure_ascii=False, indent=1)
    for attempt in range(10):   # Windows: 편집기·백신이 파일을 잠깐 잡고 있으면 교체가 거부된다
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            time.sleep(0.5 * (attempt + 1))
    os.replace(tmp, path)


def get_plan(args) -> Plan:
    state_path = os.path.join(args.run_dir, 'seed-state.json')
    state = load_json(state_path, {})
    if state.get('anchor'):
        if args.seed != state['seed']:
            raise SystemExit(f'이미 seed {state["seed"]}로 생성된 데이터가 있습니다. 다른 seed를 쓰려면 Reset-Showcase.ps1 후 다시 실행하세요.')
        anchor = datetime.fromisoformat(state['anchor'].replace('Z', '+00:00'))
    else:
        now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
        anchor = now - timedelta(minutes=5)
        state.update({'seed': args.seed, 'anchor': iso_s(anchor), 'createdAt': iso_s(now)})
        save_json(state_path, state)
    # 계획 생성(수십 초)을 명령마다 반복하지 않도록 캐시한다. 코드·seed·기준 시각이 같을 때만 재사용한다(결정적이므로 결과가 같다).
    with open(__file__, 'rb') as f:
        code_hash = hashlib.sha256(f.read()).hexdigest()[:16]
    key = f'{args.seed}-{iso_s(anchor)}-{code_hash}'
    cache = os.path.join(args.run_dir, 'plan-cache.pkl')
    if os.path.exists(cache):
        try:
            with open(cache, 'rb') as f:
                cached = pickle.load(f)
            if cached.get('key') == key:
                return cached['plan']
        except Exception:
            pass
    started = time.time()
    plan = Plan(args.seed, anchor)
    plan.build_seconds = round(time.time() - started, 1)
    with open(cache, 'wb') as f:
        pickle.dump({'key': key, 'plan': plan}, f, protocol=pickle.HIGHEST_PROTOCOL)
    return plan


# ------------------------------------------------------------------ 명령
def cmd_summary(args):
    plan = get_plan(args)
    units = plan.units_for(args.users)
    s = plan.summary(units)
    s['buildSeconds'] = plan.build_seconds
    s['fullPlanUsers'] = len(plan.users)
    s['fullPlanEvents'] = sum(len(v) for v in plan.events.values())
    print(json.dumps(s, ensure_ascii=False, indent=1))
    save_json(os.path.join(args.run_dir, 'plan-summary.json'), plan.summary())


def concert_sql(plan: Plan) -> str:
    out = ["SET NAMES utf8mb4;", "SET time_zone='+00:00';", "START TRANSACTION;"]
    for c in plan.concerts:
        esc = lambda s: s.replace("\\", "\\\\").replace("'", "''")
        fmt = lambda t: t.strftime('%Y-%m-%d %H:%M:%S')
        out.append(
            "INSERT INTO concerts (public_id,title,artist,venue,start_at,end_at,price_from,tagline,hue) "
            f"SELECT '{c['id']}','{esc(c['title'])}','{esc(c['artist'])}','{esc(c['venue'])}','{fmt(c['starts'])}','{fmt(c['ends'])}',"
            f"99000,'{esc(c['tagline'])}',{c['hue']} FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM concerts WHERE public_id='{c['id']}');")
        rows = c['seats'] // c['cols']
        labels = ' UNION ALL '.join(f"SELECT '{row_label(i)}' row_label, {i} r" for i in range(rows))
        vip, r_ = max(1, round(rows * 0.08)), max(1, round(rows * 0.2))
        out.append(
            "INSERT INTO concert_seats (concert_id,seat_code,row_label,seat_number,grade,price,state) "
            "SELECT c.id, CONCAT(x.row_label,'-',LPAD(n.num,2,'0')), x.row_label, n.num, "
            f"CASE WHEN x.r < {vip} THEN 'VIP' WHEN x.r < {vip + r_} THEN 'R' ELSE 'S' END, "
            f"CASE WHEN x.r < {vip} THEN 154000 WHEN x.r < {vip + r_} THEN 132000 ELSE 99000 END, 'AVAILABLE' "
            f"FROM concerts c CROSS JOIN ({labels}) x "
            f"CROSS JOIN (WITH RECURSIVE s(num) AS (SELECT 1 UNION ALL SELECT num+1 FROM s WHERE num < {c['cols']}) SELECT num FROM s) n "
            f"WHERE c.public_id='{c['id']}' AND NOT EXISTS (SELECT 1 FROM concert_seats cs WHERE cs.concert_id=c.id "
            "AND cs.seat_code=CONCAT(x.row_label,'-',LPAD(n.num,2,'0')));")
    out.append('COMMIT;')
    return '\n'.join(out)


def cmd_concerts(args):
    plan = get_plan(args)
    demo = json.loads(args.demo_db)
    sql(demo, concert_sql(plan))
    rows = sql(demo, "SELECT c.public_id, COUNT(s.id) seats FROM concerts c LEFT JOIN concert_seats s ON s.concert_id=c.id "
                     "WHERE c.public_id LIKE 'sc%' GROUP BY c.public_id ORDER BY c.public_id")
    bts = Bts(args.bts_url, args.service_key)
    for c in plan.concerts:
        # demo-ticketing의 공연 동기화(ConcertSyncService → PUT /api/v1/concerts/{id})와 같은 요청. Demo도 주기적으로 같은 값을 보낸다.
        st, body = bts.call('PUT', f'/api/v1/concerts/{c["id"]}', {
            'name': c['title'], 'venue': c['venue'], 'startsAt': iso_s(c['starts']), 'endsAt': iso_s(c['ends'])})
        if st != 200:
            raise SystemExit(f'공연 등록 실패 {c["id"]}: {st} {body}')
    save_json(os.path.join(args.run_dir, 'plan-summary.json'), plan.summary())
    print(json.dumps({'demoSeats': rows, 'btsConcerts': len(plan.concerts)}, ensure_ascii=False))


def event_payload(ev, user_id):
    p = {'serviceId': SERVICE_ID, 'externalEventId': ev['id'], 'userId': user_id, 'eventType': ev['type'],
         'occurredAt': iso_ms(ev['t']), 'metadata': ev['metadata']}
    if 'bookingId' in ev:
        p['bookingId'] = ev['bookingId']
    if 'ticketId' in ev:
        p['ticketId'] = ev['ticketId']
    return p


def cmd_load(args):
    plan = get_plan(args)
    units = plan.units_for(args.users)
    users_path = os.path.join(args.run_dir, 'users.json')
    store = load_json(users_path, {'users': {}, 'loaded': []})
    loaded = set(store['loaded'])
    todo = [m for u in units for m in u['members'] if m not in loaded or args.replay]
    if args.dry_run:
        print(json.dumps({'pendingUsers': len(todo), 'pendingEvents': sum(len(plan.events.get(m, [])) for m in todo)}))
        return
    bts = Bts(args.bts_url, args.service_key)
    lock = threading.Lock()
    counts = Counter()
    started = time.time()

    def work(ext):
        st, body = bts.call('POST', '/api/v1/users', {'serviceId': SERVICE_ID, 'externalUserId': ext, 'accountStatus': 'ACTIVE'})
        if st not in (200, 201):
            raise RuntimeError(f'사용자 등록 실패 {ext}: {st} {body}')
        uid = body['data']['userId']
        with lock:
            prev = store['users'].get(ext)
            if prev and prev != uid:
                raise RuntimeError(f'BTS 사용자 ID가 바뀌었습니다 {ext}: {prev} → {uid}')
            store['users'][ext] = uid
            counts['users_' + str(st)] += 1
        for ev in plan.events.get(ext, []):
            st, body = bts.call('POST', '/api/v1/events', event_payload(ev, uid))
            if st not in (200, 201):
                raise RuntimeError(f'이벤트 전송 실패 {ext} {ev["type"]} {ev["id"]}: {st} {body}')
            with lock:
                counts[str(st)] += 1
        with lock:
            loaded.add(ext)
            counts['done'] += 1
        return ext

    errors = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(work, ext) for ext in todo]
        last = time.time()
        for f in as_completed(futures):
            try:
                f.result()
            except Exception as e:      # 나머지는 계속하고 마지막에 보고한다
                errors.append(str(e))
            if time.time() - last > 15:
                last = time.time()
                with lock:
                    store['loaded'] = sorted(loaded)
                    save_json(users_path, store)
                el = time.time() - started
                sent = counts['200'] + counts['201']
                print(f'  진행 {counts["done"]}/{len(todo)}명, 이벤트 {sent}건 ({sent / max(el, 1):.0f}건/s, {el:.0f}s)', flush=True)
    store['loaded'] = sorted(loaded)
    save_json(users_path, store)
    el = time.time() - started
    result = {'users': len(todo), 'eventsCreated': counts['201'], 'eventsReplayed': counts['200'],
              'usersCreated': counts['users_201'], 'usersExisting': counts['users_200'], 'seconds': round(el, 1),
              'eventsPerSecond': round((counts['200'] + counts['201']) / max(el, 0.001), 1), 'errors': errors[:5],
              'errorCount': len(errors)}
    state_path = os.path.join(args.run_dir, 'seed-state.json')
    state = load_json(state_path, {})
    state.setdefault('loads', []).append({'at': iso_s(datetime.now(timezone.utc)), 'limit': args.users, **result})
    state['loadedUsers'] = len(loaded)
    save_json(state_path, state)
    print(json.dumps(result, ensure_ascii=False))
    if errors:
        sys.exit(1)


CANDIDATES_SQL = """
SELECT COUNT(*) pending, IFNULL(SUM(n.cnt),0) events FROM (
  SELECT e.user_id, COUNT(*) cnt FROM behavior_event e LEFT JOIN risk_assessment_cursor c ON c.user_id=e.user_id
  WHERE e.occurred_at <= CAST(DATE_FORMAT(UTC_TIMESTAMP(), '%Y-%m-%d %H:%i:%s') AS DATETIME(3))
    AND (e.event_id > COALESCE(c.last_event_id,0) OR e.occurred_at > c.checked_at)
  GROUP BY e.user_id) n
"""


def cmd_wait_eval(args):
    """평가 완료 판정: BTS 스케줄러의 평가 대상 조건(RiskAssessmentCursorRepository)과 같은 조건으로 남은 사용자가 0명인지,
    그리고 미입장 판정 대상(종료+유예 시간이 지난 BOOKED 티켓)이 0건인지 확인한다. 고정 시간 대기는 하지 않는다."""
    bts_db = json.loads(args.bts_db)
    started = time.time()
    first = None
    stable = 0
    while True:
        row = sql(bts_db, CANDIDATES_SQL)[0]
        pending = int(row['pending'])
        ns = int(sql(bts_db, "SELECT COUNT(*) n FROM booking_history WHERE status='BOOKED' AND event_ends_at IS NOT NULL "
                             "AND event_ends_at <= UTC_TIMESTAMP() - INTERVAL 1 HOUR")[0]['n'])
        att = sql(bts_db, "SELECT status, COUNT(*) n FROM risk_assessment_attempt GROUP BY status")
        if first is None:
            first = pending
        el = time.time() - started
        print(f'  평가 대기 사용자 {pending}명 (처음 {first}), 미입장 판정 대기 {ns}건, 평가 기록 '
              f'{",".join(a["status"] + "=" + a["n"] for a in att)} ({el:.0f}s)', flush=True)
        if pending == 0 and ns == 0:
            stable += 1
            if stable >= 2:
                break
        else:
            stable = 0
        if el > args.timeout:
            raise SystemExit(f'평가 완료 대기 시간 초과 ({args.timeout}s)')
        time.sleep(5)
    el = round(time.time() - started, 1)
    state_path = os.path.join(args.run_dir, 'seed-state.json')
    state = load_json(state_path, {})
    state.setdefault('evaluations', []).append({'at': iso_s(datetime.now(timezone.utc)), 'pendingAtStart': first, 'seconds': el})
    save_json(state_path, state)
    print(json.dumps({'pendingAtStart': first, 'seconds': el}))


def cmd_users(args):
    """대표 계정 선정용: 계획상 유형과 BTS 사용자 ID를 출력한다."""
    plan = get_plan(args)
    store = load_json(os.path.join(args.run_dir, 'users.json'), {'users': {}})
    out = []
    for ext in store.get('loaded', []):
        u = plan.users.get(ext)
        if u:
            out.append({'ext': ext, 'bts': store['users'].get(ext), 'type': u['type'], 'ip': u['ip'], 'card': u['card'],
                        'concerts': ','.join(c['id'] for c in plan.concerts if ext in plan.participants[c['id']])})
    print(json.dumps(out, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('command', choices=['summary', 'concerts', 'load', 'wait-eval', 'users'])
    ap.add_argument('--seed', type=int, default=DEFAULT_SEED)
    ap.add_argument('--run-dir', required=True)
    ap.add_argument('--users', type=int, default=None, help='앞에서부터 이 인원(그룹 단위)까지만 적재. 생략하면 전체')
    ap.add_argument('--bts-url', default='http://localhost:28080')
    ap.add_argument('--service-key', default=os.environ.get('SHOWCASE_SERVICE_KEY', ''))
    ap.add_argument('--demo-db', default=os.environ.get('SHOWCASE_DEMO_DB', ''))
    ap.add_argument('--bts-db', default=os.environ.get('SHOWCASE_BTS_DB', ''))
    ap.add_argument('--workers', type=int, default=16)
    ap.add_argument('--timeout', type=int, default=3600)
    ap.add_argument('--replay', action='store_true', help='이미 적재한 사용자도 다시 보낸다(중복 방지 확인용)')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()
    os.makedirs(args.run_dir, exist_ok=True)
    {'summary': cmd_summary, 'concerts': cmd_concerts, 'load': cmd_load, 'wait-eval': cmd_wait_eval,
     'users': cmd_users}[args.command](args)


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    main()
