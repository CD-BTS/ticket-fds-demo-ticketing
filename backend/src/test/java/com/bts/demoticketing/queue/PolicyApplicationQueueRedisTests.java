package com.bts.demoticketing.queue;

import java.util.*;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.test.context.*;
import org.springframework.test.context.bean.override.mockito.*;
import org.springframework.test.web.servlet.*;
import tools.jackson.databind.json.JsonMapper;
import com.bts.demoticketing.concert.service.ConcertService;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient.Decision;
import com.bts.demoticketing.outbox.OutboxRepository;
import com.bts.demoticketing.user.entity.DemoUser;
import com.bts.demoticketing.user.service.DemoAuthService;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * #67: 실제 Redis(Lua)에서 정책이 적용된 시점에만, 그 적용을 만든 결정의 ID로 기록이 적재되는지.
 * 정책 결정은 요청마다 새 decisionId를 받도록 흉내 내고(BTS와 같다), Outbox 저장은 호출만 확인한다.
 */
@Tag("redis")
@SpringBootTest(properties={"demo.jobs.enabled=false","bts.enabled=false","demo.queue.capacity=1",
        "demo.policy.mode=mock","demo.captcha.mode=mock",
        "demo.policy.mock-actions={\"u2\":\"REQUIRE_CAPTCHA\",\"u3\":\"DELAY\",\"u4\":\"RESTRICT\",\"u6\":\"REQUIRE_CAPTCHA\"}"})
@AutoConfigureMockMvc
class PolicyApplicationQueueRedisTests {
    static final String PREFIX="demo-ticketing:queue:policy-application-test:"+UUID.randomUUID();
    @DynamicPropertySource static void config(DynamicPropertyRegistry r){r.add("demo.queue.key-prefix",()->PREFIX);}
    @Autowired MockMvc mvc;
    @Autowired JsonMapper json;
    @Autowired StringRedisTemplate redis;
    @MockitoBean DemoAuthService auth;
    @MockitoBean ConcertService concerts;
    @MockitoBean OutboxRepository outbox;
    @MockitoSpyBean PolicyDecisionClient policies;
    final AtomicLong decisions=new AtomicLong(100);
    final List<String> requested=Collections.synchronizedList(new ArrayList<>());
    static DemoUser user(long id){return new DemoUser(id,"u"+id,"demo","u"+id,null);}
    @BeforeEach void setup(){
        when(auth.require(any())).thenAnswer(i->user(Long.parseLong(((jakarta.servlet.http.HttpServletRequest)i.getArgument(0)).getHeader("Test-User"))));
        doAnswer(i->{
            requested.add(i.getArgument(1));
            return new Decision(policies.decide(i.getArgument(0)),decisions.incrementAndGet());
        }).when(policies).decideFor(any(),any());
    }
    @AfterEach void cleanup(){var keys=redis.keys(PREFIX+":*");if(keys!=null&&!keys.isEmpty())redis.delete(keys);}

    String path(String concert){return "/api/v1/concerts/"+concert+"/queue";}
    Map<String,Object> data(MvcResult result)throws Exception{return json.convertValue(json.readTree(result.getResponse().getContentAsString()).get("data"),new tools.jackson.core.type.TypeReference<Map<String,Object>>() {});}
    ResultActions join(String concert,long id,String token)throws Exception{
        var request=post(path(concert)).header("Test-User",id);
        if(token!=null)request.header("X-Captcha-Token",token);
        return mvc.perform(request);
    }
    Map<String,Object> challenge(String concert,long id)throws Exception{
        return data(mvc.perform(post(path(concert)+"/captcha-challenges").header("Test-User",id)).andExpect(status().isOk()).andReturn());
    }
    String answer(Map<String,Object> challenge){
        String[] numbers=challenge.get("question").toString().split(" ");
        return Integer.toString(Integer.parseInt(numbers[0])+Integer.parseInt(numbers[2]));
    }
    ResultActions submit(String concert,long id,Map<String,Object> c,String answer)throws Exception{
        return mvc.perform(post(path(concert)+"/captcha-verifications").header("Test-User",id).contentType("application/json")
                .content(json.writeValueAsString(Map.of("challengeId",c.get("challengeId"),"answer",answer))));
    }
    void recorded(long user,long decision,String result){
        verify(outbox).appendPolicyApplication(eq(user),eq("demo"),eq(decision),eq(result),any(),any(),any());
    }
    void recordedTimes(int times){verify(outbox,times(times)).appendPolicyApplication(anyLong(),any(),anyLong(),any(),any(),any(),any());}

    @Test void captchaResultsStayOnTheDecisionThatIssuedTheChallenge()throws Exception{
        // 결정만 받고(101) 입장이 CAPTCHA_REQUIRED로 거부된 것은 아직 CAPTCHA 제시가 아니다
        join("c",2,null).andExpect(jsonPath("$.code").value("CAPTCHA_REQUIRED"));
        recordedTimes(0);
        var c=challenge("c",2);                                         // 결정 102로 challenge 발급
        recorded(2,102,"CHALLENGED");
        submit("c",2,c,"wrong").andExpect(status().isForbidden());        // 검증 요청의 결정은 103이지만 기록은 102
        submit("c",2,c,"wrong").andExpect(status().isForbidden());        // 같은 challenge의 반복 실패도 같은 키로 적재
        verify(outbox,times(2)).appendPolicyApplication(eq(2L),eq("demo"),eq(102L),eq("FAILED"),any(),any(),any());
        String token=data(submit("c",2,c,answer(c)).andExpect(status().isOk()).andReturn()).get("captchaToken").toString();
        recorded(2,102,"PASSED");
        // CAPTCHA를 통과한 뒤의 입장 자체는 추가 적용이 아니다
        join("c",2,token).andExpect(status().isCreated());
        recordedTimes(4);
        assertTrue(requested.stream().allMatch("c"::equals),requested.toString()); // 모든 정책 요청에 공연 ID
    }

    @Test void anotherUsersChallengeAndConsumedChallengesProduceNoRecord()throws Exception{
        var c=challenge("c",2);
        recorded(2,101,"CHALLENGED");
        // 다른 사용자가 이 challenge ID로 실패해도 원래 사용자의 결정에 FAILED가 붙지 않는다
        submit("c",6,c,"wrong").andExpect(status().isForbidden());
        submit("c",2,c,answer(c)).andExpect(status().isOk());
        recorded(2,101,"PASSED");
        // 이미 소비된 challenge에 대한 요청은 어느 결정의 실패인지 알 수 없으므로 기록하지 않는다
        submit("c",2,c,answer(c)).andExpect(status().isForbidden());
        recordedTimes(2);
    }

    @Test void concurrentDuplicateSubmissionsOfTheRightAnswerRecordOnePassAndNoFailure()throws Exception{
        var c=challenge("c",2);String right=answer(c);
        var pool=java.util.concurrent.Executors.newFixedThreadPool(8);
        try{
            List<java.util.concurrent.Callable<Integer>> work=new ArrayList<>();
            for(int i=0;i<16;i++)work.add(()->submit("c",2,c,right).andReturn().getResponse().getStatus());
            int ok=0;for(var r:pool.invokeAll(work))if(r.get()==200)ok++;
            assertEquals(1,ok);
        }finally{pool.shutdownNow();}
        // 뒤늦게 도착한 같은 제출은 403이지만 오답이 아니다: 이미 소비된 challenge라 FAILED로 기록하면 안 된다
        recorded(2,101,"PASSED");
        verify(outbox,never()).appendPolicyApplication(anyLong(),any(),anyLong(),eq("FAILED"),any(),any(),any());
        recordedTimes(2); // CHALLENGED + PASSED
    }

    @Test void replayedAndExpiredVerificationsAddNoRecord()throws Exception{
        var c=challenge("c",2);String transition=UUID.randomUUID().toString();
        ResultActions first=mvc.perform(post(path("c")+"/captcha-verifications").header("Test-User",2).header("X-Attempt-Transition",transition)
                .contentType("application/json").content(json.writeValueAsString(Map.of("challengeId",c.get("challengeId"),"answer","wrong"))));
        first.andExpect(status().isForbidden());
        recorded(2,101,"FAILED");
        // 같은 X-Attempt-Transition 재전송은 저장된 결과를 돌려줄 뿐 새로 판정하지 않는다: 기록도 다시 만들지 않는다
        mvc.perform(post(path("c")+"/captcha-verifications").header("Test-User",2).header("X-Attempt-Transition",transition)
                .contentType("application/json").content(json.writeValueAsString(Map.of("challengeId",c.get("challengeId"),"answer","wrong"))))
                .andExpect(status().isForbidden());
        recordedTimes(2); // CHALLENGED + FAILED
        // 만료된 challenge는 오답 판정이 아니다
        redis.opsForHash().put(PREFIX+":{"+java.util.Base64.getUrlEncoder().withoutPadding().encodeToString("c".getBytes())+"}:captcha-challenge:"+c.get("challengeId"),"expiry","1");
        submit("c",2,c,answer(c)).andExpect(status().isForbidden());
        recordedTimes(2);
    }

    @Test void delayRecordsOnlyThePlacementAndNeverACaptchaResult()throws Exception{
        var c=challenge("c",3);
        submit("c",3,c,"wrong").andExpect(status().isForbidden());
        String token=data(submit("c",3,c,answer(c)).andExpect(status().isOk()).andReturn()).get("captchaToken").toString();
        recordedTimes(0); // DELAY 결정의 CAPTCHA는 현재 BTS 계약에 기록할 result가 없다
        join("c",3,token).andExpect(status().isCreated());
        recorded(3,104,"DELAYED"); // 후순위 그룹에 배치한 그 요청의 결정
        join("c",3,null).andExpect(status().isOk()); // 이미 등록됨: 정책 재적용 없음
        recordedTimes(1);
    }

    @Test void restrictIsRecordedPerActualRejectionAndPerConcert()throws Exception{
        join("c",4,null).andExpect(jsonPath("$.code").value("QUEUE_RESTRICTED"));
        recorded(4,101,"BLOCKED");
        join("other",4,null).andExpect(jsonPath("$.code").value("QUEUE_RESTRICTED"));
        recorded(4,102,"BLOCKED"); // 다시 거부되면 새 결정의 새 적용이다
        assertEquals(List.of("c","other"),requested);
        // ALLOW 사용자는 입장해도 기록이 없다
        join("c",1,null).andExpect(status().isCreated());
        recordedTimes(2);
    }

    @Test void twoConcertsKeepTheirOwnDecisions()throws Exception{
        var first=challenge("c",2);var second=challenge("other",2);
        recorded(2,101,"CHALLENGED");recorded(2,102,"CHALLENGED");
        submit("other",2,second,answer(second)).andExpect(status().isOk());
        recorded(2,102,"PASSED");
        submit("c",2,first,"wrong").andExpect(status().isForbidden());
        recorded(2,101,"FAILED");
        // 다른 공연의 challenge ID를 섞어 보내면 그 공연에는 challenge가 없으므로 기록도 없다
        submit("other",2,first,answer(first)).andExpect(status().isForbidden());
        recordedTimes(4);
    }
}
