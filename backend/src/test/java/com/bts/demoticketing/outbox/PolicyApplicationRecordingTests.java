package com.bts.demoticketing.outbox;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import java.time.*;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.PlatformTransactionManager;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;
import com.bts.demoticketing.concert.service.ConcertService;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient.Action;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient.Decision;
import com.bts.demoticketing.queue.QueueService;
import com.bts.demoticketing.queue.QueueStore;
import com.bts.demoticketing.user.entity.DemoUser;
import com.bts.demoticketing.user.repository.DemoUserRepository;

/** #67: 정책 결정을 받은 것과 정책이 실제로 적용된 것을 구분해 기록하는지 (DB·Redis 없이 검증). */
class PolicyApplicationRecordingTests {
    private final JsonMapper json=JsonMapper.builder().build();
    private final DemoUser user=new DemoUser(7,"u-7","demo-ticketing","u-7",null);
    private final Clock clock=Clock.fixed(Instant.parse("2026-11-24T13:07:12.123456Z"),ZoneOffset.UTC);

    private PolicyApplicationRecorder recorder(OutboxRepository outbox){
        return new PolicyApplicationRecorder(outbox,json,clock,mock(PlatformTransactionManager.class));
    }

    @Test void recordsOnlyCombinationsTheBtsContractAccepts(){
        var outbox=mock(OutboxRepository.class);var recorder=recorder(outbox);
        recorder.record(user,"c1",new Decision(Action.REQUIRE_CAPTCHA,10L),"CHALLENGED");
        var metadata=org.mockito.ArgumentCaptor.forClass(String.class);
        // 적용 시각은 BTS applied_at(DATETIME(3))에 맞춰 밀리초로 자른다
        verify(outbox).appendPolicyApplication(eq(7L),eq("demo-ticketing"),eq(10L),eq("CHALLENGED"),
                eq(LocalDateTime.of(2026,11,24,13,7,12,123_000_000)),metadata.capture(),eq(LocalDateTime.of(2026,11,24,13,7,12,123_456_000)));
        assertEquals(Map.of("decisionId",10,"concertId","c1","action","REQUIRE_CAPTCHA","result","CHALLENGED"),
                json.readValue(metadata.getValue(),new TypeReference<Map<String,Object>>() {}));

        recorder.record(user,"c1",new Decision(Action.REQUIRE_CAPTCHA,10L),"PASSED");
        recorder.record(user,"c1",new Decision(Action.REQUIRE_CAPTCHA,10L),"FAILED");
        recorder.record(user,"c1",new Decision(Action.DELAY,11L),"DELAYED");
        recorder.record(user,"c1",new Decision(Action.RESTRICT,12L),"BLOCKED");
        verify(outbox,times(5)).appendPolicyApplication(anyLong(),any(),anyLong(),any(),any(),any(),any());

        // ALLOW는 제재가 아니다. DELAY의 CAPTCHA 결과처럼 계약에 없는 조합도 보내지 않는다.
        recorder.record(user,"c1",new Decision(Action.ALLOW,13L),"CHALLENGED");
        recorder.record(user,"c1",new Decision(Action.DELAY,14L),"CHALLENGED");
        recorder.record(user,"c1",new Decision(Action.DELAY,14L),"PASSED");
        recorder.record(user,"c1",new Decision(Action.DELAY,14L),"FAILED");
        recorder.record(user,"c1",new Decision(Action.RESTRICT,15L),"DELAYED");
        // decisionId가 없으면(mock/disabled 모드, 이전 BTS) 어느 결정의 적용인지 알 수 없으므로 기록하지 않는다
        recorder.record(user,"c1",new Decision(Action.RESTRICT,null),"BLOCKED");
        recorder.record(user,"c1",Action.REQUIRE_CAPTCHA,null,"FAILED");
        recorder.record(user,"c1",(Decision)null,"BLOCKED");
        verifyNoMoreInteractions(outbox);
    }

    @Test void storageFailureNeverBreaksTheCallerBecauseThePolicyIsAlreadyApplied(){
        var outbox=mock(OutboxRepository.class);
        doThrow(new IllegalStateException("db down")).when(outbox).appendPolicyApplication(anyLong(),any(),anyLong(),any(),any(),any(),any());
        assertDoesNotThrow(()->recorder(outbox).record(user,"c1",new Decision(Action.RESTRICT,12L),"BLOCKED"));
    }

    private record Fixture(QueueService queue,QueueStore store,PolicyDecisionClient policies,PolicyApplicationRecorder recorder){}
    private Fixture queue(Decision decision){
        var store=mock(QueueStore.class);var policies=mock(PolicyDecisionClient.class);var recorder=mock(PolicyApplicationRecorder.class);
        when(store.execute("c1",7,"status")).thenReturn(result("NOT_JOINED",false));
        when(policies.decideFor(user,"c1")).thenReturn(decision);
        return new Fixture(new QueueService(mock(ConcertService.class),store,policies,mock(DemoUserRepository.class),recorder),store,policies,recorder);
    }
    private static QueueStore.Result result(String status,boolean created){return new QueueStore.Result(new QueueStore.Snapshot(status,null,null),created);}

    @Test void delayIsRecordedOnlyWhenTheUserWasActuallyPlacedInTheDelayedGroup(){
        var decision=new Decision(Action.DELAY,21L);
        var placed=queue(decision);
        when(placed.store().join("c1",7,"DELAY","grant")).thenReturn(result("WAITING",true));
        placed.queue().join("c1",user,"grant");
        verify(placed.recorder()).record(user,"c1",decision,"DELAYED");

        // 동시 요청이 먼저 등록해 Lua가 정책을 다시 적용하지 않은 경우: 결정은 받았지만 적용은 없다
        var raced=queue(decision);
        when(raced.store().join("c1",7,"DELAY","grant")).thenReturn(result("WAITING",false));
        raced.queue().join("c1",user,"grant");
        verifyNoInteractions(raced.recorder());

        // CAPTCHA 단계에서 막혀 대기열에 들어가지 못한 경우
        var unverified=queue(decision);
        when(unverified.store().join("c1",7,"DELAY",null)).thenThrow(new ApiException(ResponseCode.CAPTCHA_REQUIRED));
        assertThrows(ApiException.class,()->unverified.queue().join("c1",user,null));
        verifyNoInteractions(unverified.recorder());
    }

    @Test void restrictIsRecordedWhenTheJoinIsRejectedAndAllowOrCaptchaJoinsAreNot(){
        var blocked=new Decision(Action.RESTRICT,22L);
        var restricted=queue(blocked);
        when(restricted.store().join("c1",7,"RESTRICT",null)).thenThrow(new ApiException(ResponseCode.QUEUE_RESTRICTED));
        assertEquals(ResponseCode.QUEUE_RESTRICTED,assertThrows(ApiException.class,()->restricted.queue().join("c1",user,null)).getResponseCode());
        verify(restricted.recorder()).record(user,"c1",blocked,"BLOCKED");

        for(Action action:java.util.List.of(Action.ALLOW,Action.REQUIRE_CAPTCHA)){
            var joined=queue(new Decision(action,23L));
            when(joined.store().join("c1",7,action.name(),"grant")).thenReturn(result("ADMITTED",true));
            joined.queue().join("c1",user,"grant");
            verifyNoInteractions(joined.recorder());
        }
    }

    @Test void activeMembersAreNotReEvaluatedSoNothingIsDecidedOrRecorded(){
        var active=queue(new Decision(Action.RESTRICT,24L));
        when(active.store().execute("c1",7,"status")).thenReturn(result("ADMITTED",false));
        assertEquals("ADMITTED",active.queue().join("c1",user,null).snapshot().status());
        verifyNoInteractions(active.policies(),active.recorder());
    }
}
