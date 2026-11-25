package com.bts.demoticketing.outbox;

import static org.junit.jupiter.api.Assertions.*;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.*;
import com.sun.net.httpserver.*;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient.Action;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient.Decision;
import com.bts.demoticketing.user.entity.DemoUser;
import com.bts.demoticketing.user.repository.DemoUserRepository;
import com.bts.demoticketing.user.service.DemoAuthService;

/**
 * #67: 정책 적용 기록의 Outbox 적재·전송. 실제 MySQL과 가짜 BTS(HTTP)로 검증한다.
 * db/09-policy-application-outbox.sql이 적용된 DB가 필요하다. 이 테스트 전용 serviceId의 행만 만들고 지운다.
 */
@Tag("mysql")
@SpringBootTest(properties={"demo.jobs.enabled=false","bts.enabled=true","bts.service-id=it-policy-app","bts.api-key=integration-only-key",
        "demo.policy.mode=disabled","demo.captcha.mode=disabled"})
class PolicyApplicationOutboxMySqlTests {
    static final Remote BTS=new Remote();
    @DynamicPropertySource static void remote(DynamicPropertyRegistry r){
        r.add("bts.base-url",()->BTS.url());
        r.add("demo.queue.key-prefix",()->"demo-ticketing:queue:policy-app-test:"+UUID.randomUUID());
    }
    @Autowired PolicyApplicationRecorder recorder;
    @Autowired OutboxDeliveryService delivery;
    @Autowired DemoAuthService auth;
    @Autowired DemoUserRepository users;
    @Autowired JdbcTemplate jdbc;
    @Autowired JsonMapper json;
    DemoUser user;
    long decision;

    @BeforeEach void setup(){
        assertEquals("demo_ticketing_db",jdbc.queryForObject("SELECT DATABASE()",String.class));
        BTS.reset();
        var login=auth.login("it_"+UUID.randomUUID().toString().substring(0,20));
        user=users.find(jdbc.queryForObject("SELECT id FROM demo_users WHERE public_user_id=?",Long.class,login.userId())).orElseThrow();
        // 다른 실행이 남긴 행과 멱등 키가 겹치지 않도록 실행마다 다른 결정 ID를 쓴다
        decision=ThreadLocalRandom.current().nextLong(1_000_000_000L,9_000_000_000L);
    }
    @AfterEach void cleanup(){
        jdbc.update("DELETE FROM outbox_events WHERE user_id=?",user.id());
        jdbc.update("DELETE FROM demo_sessions WHERE user_id=?",user.id());
        jdbc.update("DELETE FROM demo_users WHERE id=?",user.id());
    }
    private List<Map<String,Object>> rows(){return jdbc.queryForList("SELECT * FROM outbox_events WHERE user_id=? ORDER BY id",user.id());}
    private void due(){jdbc.update("UPDATE outbox_events SET next_attempt_at=created_at WHERE user_id=?",user.id());}

    @Test void sameApplicationIsStoredOnceAndRepeatedApplicationsAreSeparateRows(){
        recorder.record(user,"c1",new Decision(Action.REQUIRE_CAPTCHA,decision),"CHALLENGED");
        recorder.record(user,"c1",new Decision(Action.REQUIRE_CAPTCHA,decision),"CHALLENGED"); // 중복 요청
        recorder.record(user,"c1",new Decision(Action.REQUIRE_CAPTCHA,decision),"FAILED");
        recorder.record(user,"c1",new Decision(Action.REQUIRE_CAPTCHA,decision),"FAILED");     // 같은 challenge의 반복 실패
        recorder.record(user,"c1",new Decision(Action.REQUIRE_CAPTCHA,decision),"PASSED");
        recorder.record(user,"c2",new Decision(Action.REQUIRE_CAPTCHA,decision+1),"CHALLENGED"); // 새 결정 = 실제 반복 적용
        recorder.record(user,"c1",new Decision(Action.ALLOW,decision+2),"BLOCKED");
        var rows=rows();
        assertEquals(List.of("pa-"+decision+"-CHALLENGED","pa-"+decision+"-FAILED","pa-"+decision+"-PASSED","pa-"+(decision+1)+"-CHALLENGED"),
                rows.stream().map(r->r.get("external_event_id")).toList());
        assertTrue(rows.stream().allMatch(r->r.get("event_type").equals("POLICY_APPLICATION")&&r.get("delivery_status").equals("PENDING")));
    }

    @Test void deliveryUsesThePolicyApplicationApiAndRetriesTheFrozenPayloadWithoutDuplicates(){
        recorder.record(user,"c1",new Decision(Action.DELAY,decision),"DELAYED");
        BTS.mode.set("STORE_THEN_503"); // BTS는 저장했지만 응답이 유실된 상황
        assertTrue(delivery.deliverNext());
        var row=rows().get(0);
        assertEquals("RETRY",row.get("delivery_status"));assertNotNull(row.get("payload"));
        assertFalse(delivery.deliverNext()); // 백오프 중
        due();
        assertTrue(delivery.deliverNext());
        row=rows().get(0);
        assertEquals("SENT",row.get("delivery_status"));
        assertEquals(BTS.applications.get("pa-"+decision+"-DELAYED").get("applicationId"),((Number)row.get("bts_event_id")).longValue());
        // 재시도는 같은 externalApplicationId와 같은 내용이고, BTS에는 한 번만 저장된다
        assertEquals(2,BTS.bodies.size());assertEquals(BTS.bodies.get(0),BTS.bodies.get(1));
        assertEquals(1,BTS.applications.size());
        Map<String,Object> sent=json.readValue(BTS.bodies.get(0),new TypeReference<Map<String,Object>>() {});
        assertEquals(Set.of("serviceId","externalApplicationId","userId","decisionId","concertId","action","result","appliedAt"),sent.keySet());
        assertEquals("it-policy-app",sent.get("serviceId"));assertEquals("pa-"+decision+"-DELAYED",sent.get("externalApplicationId"));
        assertEquals(decision,((Number)sent.get("decisionId")).longValue());assertEquals("c1",sent.get("concertId"));
        assertEquals("DELAY",sent.get("action"));assertEquals("DELAYED",sent.get("result"));
        assertTrue(sent.get("appliedAt").toString().matches("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d{1,3})?Z"),sent.get("appliedAt").toString());
        // 사용자의 BTS UUID는 기존 지연 등록으로 확보한다
        assertEquals(users.find(user.id()).orElseThrow().btsUserId(),sent.get("userId"));
        // 행동 이벤트 API로는 아무것도 가지 않는다 (behavior_event·AI 평가 대상 아님)
        assertEquals(0,BTS.eventCalls.get());
        assertFalse(delivery.deliverNext());
    }

    @Test void aRejectedApplicationIsIsolatedAndDoesNotBlockLaterOnes(){
        recorder.record(user,"c1",new Decision(Action.RESTRICT,decision),"BLOCKED");
        recorder.record(user,"c1",new Decision(Action.RESTRICT,decision+1),"BLOCKED");
        BTS.mode.set("CONFLICT"); // 예: BTS가 결정과 공연이 맞지 않는다고 거부
        assertTrue(delivery.deliverNext());
        BTS.mode.set("NORMAL");
        assertTrue(delivery.deliverNext());
        var rows=rows();
        assertEquals("FAILED",rows.get(0).get("delivery_status"));assertEquals("DATA_CONFLICT",rows.get(0).get("last_error_code"));
        assertEquals("SENT",rows.get(1).get("delivery_status")); // 앞 기록의 실패가 다음 기록을 막지 않는다
        due();assertFalse(delivery.deliverNext());              // 거부된 기록은 다시 보내지 않는다
    }

    static class Remote {
        final JsonMapper json=JsonMapper.builder().build();
        final HttpServer server;
        final AtomicReference<String> mode=new AtomicReference<>("NORMAL");
        final Map<String,String> users=new ConcurrentHashMap<>();
        final Map<String,Map<String,Object>> applications=new ConcurrentHashMap<>();
        final List<String> bodies=new CopyOnWriteArrayList<>();
        final AtomicLong sequence=new AtomicLong();
        final AtomicInteger eventCalls=new AtomicInteger();
        Remote(){
            try{server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);server.createContext("/api/v1/",this::handle);server.start();}
            catch(IOException e){throw new IllegalStateException(e);}
        }
        String url(){return "http://127.0.0.1:"+server.getAddress().getPort();}
        void reset(){mode.set("NORMAL");bodies.clear();applications.clear();users.clear();sequence.set(0);eventCalls.set(0);}
        void handle(HttpExchange exchange)throws IOException{
            try{
                String raw=new String(exchange.getRequestBody().readAllBytes(),StandardCharsets.UTF_8);
                Map<String,Object> body=json.readValue(raw,new TypeReference<Map<String,Object>>() {});
                String path=exchange.getRequestURI().getPath();
                if(path.endsWith("/users")){
                    String external=body.get("externalUserId").toString();
                    boolean exists=users.containsKey(external);String id=users.computeIfAbsent(external,k->UUID.randomUUID().toString());
                    reply(exchange,exists?200:201,exists?"COMMON_200":"COMMON_201",Map.of("userId",id,"serviceId","it-policy-app","externalUserId",external));return;
                }
                if(!path.endsWith("/policy-applications")){eventCalls.incrementAndGet();reply(exchange,404,"RESOURCE_NOT_FOUND",null);return;}
                bodies.add(raw);
                if(!users.containsValue(body.get("userId"))){reply(exchange,404,"USER_NOT_FOUND",null);return;}
                if(mode.get().equals("CONFLICT")){reply(exchange,409,"DATA_CONFLICT",null);return;}
                String id=body.get("externalApplicationId").toString();
                var old=applications.get(id);
                if(old==null){body.put("applicationId",sequence.incrementAndGet());applications.put(id,body);}
                if(mode.compareAndSet("STORE_THEN_503","NORMAL")){reply(exchange,503,"SERVICE_UNAVAILABLE",null);return;}
                reply(exchange,old==null?201:200,old==null?"COMMON_201":"COMMON_200",applications.get(id));
            }catch(RuntimeException e){reply(exchange,500,"INTERNAL_SERVER_ERROR",null);}
        }
        void reply(HttpExchange e,int status,String code,Object data)throws IOException{
            Map<String,Object> body=new LinkedHashMap<>();body.put("success",status<400);body.put("code",code);body.put("data",data);body.put("message","contract test");
            byte[] bytes=json.writeValueAsBytes(body);e.getResponseHeaders().set("Content-Type","application/json");e.sendResponseHeaders(status,bytes.length);e.getResponseBody().write(bytes);e.close();
        }
    }
}
