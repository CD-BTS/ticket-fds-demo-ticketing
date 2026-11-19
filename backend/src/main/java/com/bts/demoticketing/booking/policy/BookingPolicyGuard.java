package com.bts.demoticketing.booking.policy;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient.Action;
import com.bts.demoticketing.user.entity.DemoUser;

/**
 * 좌석 선점 직전에 BTS 정책(BOOKING_ATTEMPT)을 다시 확인한다 (#46).
 * CAPTCHA와 후순위 배치는 대기열 입장 시점에 이미 적용되므로 여기서는 RESTRICT만 차단한다.
 * 사용자는 이미 대기열 정책을 통과했으므로, BTS 장애나 응답 오류는 예매를 막지 않고 허용 후 로그만 남긴다.
 * 네트워크 호출이므로 DB 트랜잭션·좌석 잠금 밖에서 호출한다.
 */
@Component
public class BookingPolicyGuard {
    private static final Logger log = LoggerFactory.getLogger(BookingPolicyGuard.class);
    private final PolicyDecisionClient policies;

    public BookingPolicyGuard(PolicyDecisionClient policies) { this.policies = policies; }

    public void check(DemoUser user) {
        Action action;
        try {
            action = policies.decideBooking(user);
        } catch (RuntimeException e) {
            log.warn("Booking policy check unavailable; allowing seat hold (user={})", user.publicId());
            return;
        }
        if (action == Action.RESTRICT) throw new ApiException(ResponseCode.BOOKING_RESTRICTED);
    }
}
