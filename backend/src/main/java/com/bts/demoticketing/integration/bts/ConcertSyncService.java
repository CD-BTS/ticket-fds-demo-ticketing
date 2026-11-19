package com.bts.demoticketing.integration.bts;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import com.bts.demoticketing.concert.entity.Concert;
import com.bts.demoticketing.concert.repository.ConcertRepository;

/**
 * Demo 공연을 BTS에 등록·갱신한다 (#46, ticket-fds-admin docs/concert-integration.md).
 * BTS PUT은 멱등이므로 전체 공연을 주기적으로 다시 보내도 중복이 생기지 않는다.
 * 실패는 공연 단위로 격리하고 다음 주기에 재시도하며, 이벤트 전송·예매 흐름을 막지 않는다.
 */
@Service
public class ConcertSyncService {
    private static final Logger log = LoggerFactory.getLogger(ConcertSyncService.class);
    private final ConcertRepository concerts;
    private final BtsClient bts;
    private final BtsSettings settings;

    public ConcertSyncService(ConcertRepository concerts, BtsClient bts, BtsSettings settings) {
        this.concerts = concerts; this.bts = bts; this.settings = settings;
    }

    /** @return BTS에 반영한 공연 수 (BTS 비활성이면 0) */
    public int syncAll() {
        if (!settings.enabled) return 0;
        int synced = 0;
        for (Concert concert : concerts.findAllByOrderByStartAtAscPublicIdAsc()) {
            try {
                bts.upsertConcert(concert.getPublicId(), concert.getTitle(), concert.getStartAt(), concert.getEndAt(), concert.getVenue());
                synced++;
            } catch (RuntimeException e) {
                String code = e instanceof BtsClient.DeliveryFailure failure ? failure.code : e.getClass().getSimpleName();
                log.warn("Concert sync to BTS failed; will retry (concertId={}, code={})", concert.getPublicId(), code);
            }
        }
        return synced;
    }
}
