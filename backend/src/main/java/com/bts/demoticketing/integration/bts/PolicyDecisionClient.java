package com.bts.demoticketing.integration.bts;

import com.bts.demoticketing.user.entity.DemoUser;

public interface PolicyDecisionClient {
    enum Action { ALLOW, REQUIRE_CAPTCHA, DELAY, RESTRICT }
    /** 대기열 입장 시점(QUEUE_JOIN) 정책. */
    Action decide(DemoUser user);
    /** 좌석 선점 시점(BOOKING_ATTEMPT) 정책. BTS 모드가 아니면 대기열 정책과 같은 결과를 쓴다. */
    default Action decideBooking(DemoUser user){return decide(user);}
}
