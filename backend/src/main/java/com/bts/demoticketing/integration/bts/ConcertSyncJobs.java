package com.bts.demoticketing.integration.bts;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** 기동 직후와 이후 주기적으로 공연을 BTS에 동기화한다. 공연 생성 API가 없으므로 seed·DB 변경은 다음 주기에 반영된다. */
@Component
@ConditionalOnProperty(name="demo.jobs.enabled",havingValue="true",matchIfMissing=true)
public class ConcertSyncJobs {
    private final ConcertSyncService sync;
    public ConcertSyncJobs(ConcertSyncService sync){this.sync=sync;}
    @Scheduled(initialDelay=0,fixedDelayString="${bts.concert-sync-ms:600000}")
    public void syncConcerts(){
        try{sync.syncAll();}catch(RuntimeException e){org.slf4j.LoggerFactory.getLogger(ConcertSyncJobs.class).warn("Concert sync will retry");}
    }
}
