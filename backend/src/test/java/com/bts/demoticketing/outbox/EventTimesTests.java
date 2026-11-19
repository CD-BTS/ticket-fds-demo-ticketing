package com.bts.demoticketing.outbox;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.time.LocalDateTime;

import org.junit.jupiter.api.Test;

class EventTimesTests {

    @Test
    void keepsMillisecondsAndDropsFinerDigits() {
        LocalDateTime utc = LocalDateTime.of(2026, 11, 19, 5, 30, 0, 123_456_789);

        assertEquals(LocalDateTime.of(2026, 11, 19, 5, 30, 0, 123_000_000), EventTimes.occurredAt(utc));
        assertEquals("2026-11-19T05:30:00.123Z", EventTimes.format(utc));
    }

    @Test
    void formatsWholeSecondsWithoutFraction() {
        LocalDateTime utc = LocalDateTime.of(2026, 11, 19, 5, 30, 0, 999_999);

        assertEquals("2026-11-19T05:30:00Z", EventTimes.format(utc));
    }

    @Test
    void keepsSubSecondIntervalsBetweenEvents() {
        LocalDateTime first = LocalDateTime.of(2026, 11, 19, 5, 30, 1, 950_000_000);
        LocalDateTime second = LocalDateTime.of(2026, 11, 19, 5, 30, 2, 50_000_000);

        assertEquals(100, java.time.Duration.between(EventTimes.occurredAt(first), EventTimes.occurredAt(second)).toMillis());
    }
}
