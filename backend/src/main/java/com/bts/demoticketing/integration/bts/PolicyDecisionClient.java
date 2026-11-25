package com.bts.demoticketing.integration.bts;

import com.bts.demoticketing.user.entity.DemoUser;

public interface PolicyDecisionClient {
    enum Action { ALLOW, REQUIRE_CAPTCHA, DELAY, RESTRICT }
    /**
     * 정책 결정과 그 결정의 BTS ID (#67). decisionId는 실제 정책 적용 기록을 BTS에 보낼 때 쓴다.
     * BTS 모드가 아니면(disabled/mock) null이고, 그 경우 적용 기록을 만들지 않는다.
     */
    record Decision(Action action,Long decisionId){}
    /** 대기열 입장 시점(QUEUE_JOIN) 정책. */
    Action decide(DemoUser user);
    /** 좌석 선점 시점(BOOKING_ATTEMPT) 정책. BTS 모드가 아니면 대기열 정책과 같은 결과를 쓴다. */
    default Action decideBooking(DemoUser user){return decide(user);}
    /** 공연을 지정한 대기열 입장 정책. BTS 모드는 요청에 concertId를 싣고 decisionId를 돌려준다. */
    default Decision decideFor(DemoUser user,String concertId){return new Decision(decide(user),null);}
    /** 공연을 지정한 좌석 선점 정책. */
    default Decision decideBookingFor(DemoUser user,String concertId){return new Decision(decideBooking(user),null);}
}
