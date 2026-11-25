package com.bts.demoticketing.outbox;

import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.*;
import org.slf4j.*;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;
import tools.jackson.databind.json.JsonMapper;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient.Action;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient.Decision;
import com.bts.demoticketing.user.entity.DemoUser;

/**
 * 정책이 실제로 적용된 순간을 Outbox에 남긴다 (#67). 정책 결정을 받은 것만으로는 호출하지 않는다.
 * <ul>
 *   <li>호출자는 Redis/업무 결과로 적용이 확정된 뒤에만 부른다. 그래서 적용 없이 기록만 남는 일은 없다.</li>
 *   <li>적용 뒤 이 저장이 실패하면 기록만 빠진다(통계 누락). 대기열·CAPTCHA·예매 동작은 그대로 진행한다.</li>
 *   <li>같은 결정의 같은 결과는 한 번만 적재한다. 재전송·중복 요청은 무시되고, 실제 반복 적용은 새 결정이라 새 행이 된다.</li>
 * </ul>
 * BTS 모드가 아니어서 decisionId가 없으면 아무것도 하지 않는다.
 */
@Service
public class PolicyApplicationRecorder {
    public static final String EVENT_TYPE="POLICY_APPLICATION";
    /** BTS API가 받는 action/result 조합. 이 밖의 조합은 보내지 않는다. */
    private static final Map<Action,Set<String>> RESULTS=Map.of(
            Action.REQUIRE_CAPTCHA,Set.of("CHALLENGED","PASSED","FAILED"),
            Action.DELAY,Set.of("DELAYED"),
            Action.RESTRICT,Set.of("BLOCKED"));
    private static final Logger log=LoggerFactory.getLogger(PolicyApplicationRecorder.class);
    private final OutboxRepository outbox;
    private final JsonMapper json;
    private final Clock clock;
    private final TransactionTemplate tx;
    public PolicyApplicationRecorder(OutboxRepository outbox,JsonMapper json,Clock clock,PlatformTransactionManager manager){
        this.outbox=outbox;this.json=json;this.clock=clock;
        tx=new TransactionTemplate(manager);tx.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }
    public void record(DemoUser user,String concertId,Decision decision,String result){
        if(decision==null)return;
        record(user,concertId,decision.action(),decision.decisionId(),result);
    }
    public void record(DemoUser user,String concertId,Action action,Long decisionId,String result){
        if(decisionId==null||action==null||!RESULTS.getOrDefault(action,Set.of()).contains(result))return;
        try{
            LocalDateTime now=LocalDateTime.ofInstant(clock.instant(),ZoneOffset.UTC).truncatedTo(ChronoUnit.MICROS);
            Map<String,Object> metadata=new LinkedHashMap<>();
            metadata.put("decisionId",decisionId);metadata.put("concertId",concertId);
            metadata.put("action",action.name());metadata.put("result",result);
            String body=json.writeValueAsString(metadata);
            tx.executeWithoutResult(s->outbox.appendPolicyApplication(user.id(),user.serviceId(),decisionId,result,
                    EventTimes.occurredAt(now),body,now));
        }catch(RuntimeException e){
            log.warn("Policy application not recorded; policy stays applied (decision={}, result={})",decisionId,result);
        }
    }
}
