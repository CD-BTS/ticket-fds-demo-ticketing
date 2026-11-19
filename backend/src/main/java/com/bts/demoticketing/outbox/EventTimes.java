package com.bts.demoticketing.outbox;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;

/**
 * BTS로 보내는 행동 이벤트 발생 시각(occurredAt)의 정밀도 규칙.
 * BTS behavior_event.occurred_at과 Demo outbox_events.occurred_at_utc가 DATETIME(3)이므로 밀리초까지 보존한다.
 * 1초 미만의 예매 시도 간격이 BTS AI Feature(간격 평균·분산)에 그대로 전달되어야 한다 (#44).
 */
public final class EventTimes {
    private EventTimes() {}

    /** UTC LocalDateTime을 저장·전송용 밀리초 정밀도로 자른다. */
    public static LocalDateTime occurredAt(LocalDateTime utc) {
        return utc.truncatedTo(ChronoUnit.MILLIS);
    }

    /** BTS 이벤트 API의 occurredAt 문자열. 예: 2026-11-19T05:30:00.123Z (밀리초가 0이면 소수 부분 생략) */
    public static String format(LocalDateTime utc) {
        return occurredAt(utc).toInstant(ZoneOffset.UTC).toString();
    }
}
