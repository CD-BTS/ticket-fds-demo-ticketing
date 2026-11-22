package com.bts.demoticketing.ticket;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.*;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.*;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;
import com.bts.demoticketing.booking.service.ReservationService;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.outbox.OutboxDeliveryService;
import com.bts.demoticketing.queue.QueueService;
import com.bts.demoticketing.user.entity.DemoUser;
import com.bts.demoticketing.user.repository.DemoUserRepository;
import com.bts.demoticketing.user.service.DemoAuthService;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** Requires db/05-ticket-device-binding.sql and db/07-checkin-challenges.sql in an isolated DB; never changes schema. Uses only test-owned rows. */
@Tag("mysql")
@SpringBootTest(properties={"demo.jobs.enabled=false","bts.enabled=true","bts.service-id=it-checkin","bts.api-key=integration-only-key",
        "demo.checkin.enabled=true","demo.checkin.secret-key=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
        "demo.checkin.gate-key=integration-gate-key","demo.checkin.opens-before=PT2H","demo.checkin.max-device-changes=3",
        "demo.checkin.gate-challenge-ttl=PT15S"})
@AutoConfigureMockMvc
@Import(TicketCheckInMySqlTests.TimeConfig.class)
class TicketCheckInMySqlTests {
    static final Instant TEST_NOW=Instant.now().truncatedTo(java.time.temporal.ChronoUnit.MICROS);
    static final List<Map<String,Object>> SENT=new CopyOnWriteArrayList<>();
    static final HttpServer BTS=remote();
    static final Base64.Encoder B64=Base64.getUrlEncoder().withoutPadding();
    @DynamicPropertySource static void remote(DynamicPropertyRegistry r){r.add("bts.base-url",()->"http://127.0.0.1:"+BTS.getAddress().getPort());}

    @Autowired JdbcTemplate jdbc;
    @Autowired DemoAuthService auth;
    @Autowired DemoUserRepository users;
    @Autowired ReservationService reservations;
    @Autowired TicketDeviceService devices;
    @Autowired CheckInService checkIns;
    @Autowired OutboxDeliveryService delivery;
    @Autowired MutableClock clock;
    @Autowired MockMvc mvc;
    @Autowired JsonMapper json;
    @MockitoBean QueueService queue;
    String concert,aliceToken,bobToken,booking;
    long concertId;
    DemoUser alice,bob;
    List<String> ticketIds;

    @TestConfiguration static class TimeConfig {
        @Bean @Primary MutableClock testClock(){return new MutableClock();}
    }
    static class MutableClock extends Clock {
        final AtomicReference<Instant> time=new AtomicReference<>(TEST_NOW);
        void advance(Duration d){time.updateAndGet(t->t.plus(d));}
        @Override public ZoneId getZone(){return ZoneOffset.UTC;}
        @Override public Clock withZone(ZoneId z){return this;}
        @Override public Instant instant(){return time.get();}
    }
    /** 테스트 기기: 브라우저의 non-extractable 키 쌍과 등록 응답으로 받은 TOTP 비밀키를 흉내 낸다. */
    class Device {
        final KeyPair keys;String deviceId;byte[] secret;
        Device()throws Exception{keys=TicketCryptoTests.pair("secp256r1");}
        String publicKey(){return B64.encodeToString(keys.getPublic().getEncoded());}
        String proof(boolean change,String ticket,String challenge)throws Exception{
            return B64.encodeToString(TicketCryptoTests.sign(keys.getPrivate(),TicketDeviceService.proofMessage(change,ticket,challenge,publicKey())));
        }
        TicketDeviceService.Enrollment enroll(String ticket,DemoUser user,boolean change)throws Exception{
            var challenge=devices.challenge(ticket,user);
            var result=devices.enroll(ticket,user,challenge.challengeId(),publicKey(),proof(change,ticket,challenge.challenge()),change);
            deviceId=result.deviceId();secret=Base64.getUrlDecoder().decode(result.totp().secret());
            return result;
        }
        String qr(String ticket)throws Exception{
            long ts=clock.instant().getEpochSecond();
            return qr(ticket,ts,Totp.code(secret,Totp.counter(ts)));
        }
        String qr(String ticket,long ts,String totp)throws Exception{
            String body="BTS1."+ticket+"."+deviceId+"."+ts+"."+totp;
            return body+"."+B64.encodeToString(TicketCryptoTests.sign(keys.getPrivate(),body));
        }
        /** 검표 챌린지에 대한 이 기기 개인키의 서명. */
        String checkInProof(String ticket,String checkInId,String challenge)throws Exception{
            return B64.encodeToString(TicketCryptoTests.sign(keys.getPrivate(),CheckInService.proofMessage(ticket,deviceId,checkInId,challenge)));
        }
        /** 브라우저의 자동 응답: 대기 중인 챌린지를 받아 서명해 제출한다. */
        CheckInService.Result respond(String ticket,DemoUser user)throws Exception{
            var pending=checkIns.pending(ticket,user);
            assertNotNull(pending,"no pending check-in challenge");
            return checkIns.confirm(ticket,user,pending.checkInId(),checkInProof(ticket,pending.checkInId(),pending.challenge()));
        }
        /** 정상 검표: 검표기 스캔 → 등록 기기 응답. */
        CheckInService.Result admit(String ticket,String qr)throws Exception{
            assertEquals("PENDING",checkIns.scan(qr).status());
            return respond(ticket,alice);
        }
        CheckInService.Result admit(String ticket)throws Exception{return admit(ticket,qr(ticket));}
    }

    @BeforeEach void setup(){
        assertEquals("demo_ticketing_db",jdbc.queryForObject("SELECT DATABASE()",String.class));
        assertEquals(3,jdbc.queryForObject("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name IN ('ticket_device_bindings','ticket_device_challenges','ticket_checkin_challenges')",Integer.class),"Review/apply db/05-ticket-device-binding.sql and db/07-checkin-challenges.sql in the isolated test database first");
        clock.time.set(TEST_NOW);SENT.clear();
        concert="it40_"+UUID.randomUUID();
        // 입장은 공연 시작 2시간 전부터다. 시작 1시간 전으로 두어 기본 상태를 입장 가능 시간으로 만든다.
        LocalDateTime start=LocalDateTime.ofInstant(TEST_NOW,ZoneOffset.UTC).plusHours(1);
        jdbc.update("""
                INSERT INTO concerts(public_id,title,artist,venue,start_at,end_at,price_from,tagline,hue)
                VALUES(?,'checkin test','test','test',?,?,99000,'test',10)
                """,concert,start,start.plusHours(3));
        concertId=jdbc.queryForObject("SELECT id FROM concerts WHERE public_id=?",Long.class,concert);
        for(int i=1;i<=2;i++)jdbc.update("""
                INSERT INTO concert_seats(concert_id,seat_code,row_label,seat_number,grade,price,state)
                VALUES(?,?,'A',?,'VIP',154000,'AVAILABLE')
                """,concertId,"A-0"+i,i);
        var a=auth.login("it40_"+UUID.randomUUID().toString().substring(0,20));
        aliceToken=a.token();alice=find(a.userId());
        var b=auth.login("it40_"+UUID.randomUUID().toString().substring(0,20));
        bobToken=b.token();bob=find(b.userId());
        var hold=reservations.hold(concert,alice,List.of("A-01","A-02"));
        booking=reservations.confirm(hold.holdId(),"test-pay-shared-01","192.0.2.10",alice).booking().id();
        ticketIds=devices.tickets(booking,alice).stream().map(TicketDeviceService.TicketView::ticketId).toList();
        assertEquals(2,ticketIds.size());
    }
    private DemoUser find(String publicId){return users.find(jdbc.queryForObject("SELECT id FROM demo_users WHERE public_user_id=?",Long.class,publicId)).orElseThrow();}

    @AfterEach void cleanup(){
        if(alice==null||bob==null)return;
        String tickets="(SELECT t.id FROM admission_tickets t JOIN bookings b ON b.id=t.booking_id WHERE b.concert_id=?)";
        jdbc.update("DELETE FROM ticket_checkin_challenges WHERE ticket_id IN "+tickets,concertId);
        jdbc.update("DELETE FROM ticket_device_challenges WHERE ticket_id IN "+tickets,concertId);
        jdbc.update("DELETE FROM ticket_device_bindings WHERE ticket_id IN "+tickets,concertId);
        jdbc.update("UPDATE concert_seats SET state='AVAILABLE',active_hold_id=NULL,active_booking_id=NULL WHERE concert_id=?",concertId);
        jdbc.update("DELETE FROM admission_tickets WHERE booking_id IN (SELECT id FROM bookings WHERE concert_id=?)",concertId);
        jdbc.update("DELETE FROM booking_seats WHERE booking_id IN (SELECT id FROM bookings WHERE concert_id=?)",concertId);
        jdbc.update("DELETE FROM bookings WHERE concert_id=?",concertId);
        jdbc.update("DELETE FROM seat_hold_items WHERE hold_id IN (SELECT id FROM seat_holds WHERE concert_id=?)",concertId);
        jdbc.update("DELETE FROM seat_holds WHERE concert_id=?",concertId);
        jdbc.update("DELETE FROM reservation_user_concert_guards WHERE concert_id=?",concertId);
        jdbc.update("DELETE FROM concert_seats WHERE concert_id=?",concertId);
        jdbc.update("DELETE FROM concerts WHERE id=?",concertId);
        for(DemoUser user:List.of(alice,bob)){
            jdbc.update("DELETE FROM outbox_events WHERE user_id=?",user.id());
            jdbc.update("DELETE FROM demo_sessions WHERE user_id=?",user.id());
            jdbc.update("DELETE FROM demo_users WHERE id=?",user.id());
        }
    }
    @AfterAll static void stop(){BTS.stop(0);}

    private interface Work{void run()throws Exception;}
    private String code(Work work){return assertThrows(ApiException.class,work::run).getResponseCode().getCode();}
    private String ticketStatus(String ticket){return jdbc.queryForObject("SELECT status FROM admission_tickets WHERE public_id=?",String.class,ticket);}
    private LocalDateTime checkedInAt(String ticket){return jdbc.queryForObject("SELECT checked_in_at FROM admission_tickets WHERE public_id=?",LocalDateTime.class,ticket);}
    private long checkInEvents(){return jdbc.queryForObject("SELECT COUNT(*) FROM outbox_events WHERE user_id=? AND event_type='CHECK_IN'",Long.class,alice.id());}
    private Map<String,Object> data(String body){
        return json.convertValue(json.readValue(body,new TypeReference<Map<String,Object>>() {}).get("data"),new TypeReference<Map<String,Object>>() {});
    }
    private String challengeStatus(String checkInId){return jdbc.queryForObject("SELECT status FROM ticket_checkin_challenges WHERE public_id=?",String.class,checkInId);}
    private org.springframework.test.web.servlet.ResultActions gateScan(Object body)throws Exception{
        return mvc.perform(post("/api/v1/check-ins").header("X-Gate-Key","integration-gate-key").contentType("application/json").content(json.writeValueAsString(body)));
    }
    private String send(String path,String token,Object body,int expected,String expectedCode)throws Exception{
        var request=post(path).contentType("application/json").content(json.writeValueAsString(body));
        if(token!=null)request.header("Authorization","Bearer "+token);
        return mvc.perform(request).andExpect(status().is(expected)).andExpect(jsonPath("$.code").value(expectedCode))
                .andReturn().getResponse().getContentAsString(StandardCharsets.UTF_8);
    }

    @Test void httpFlowRegistersDeviceChecksInOnceAndDeliversCheckInEvent()throws Exception{
        String ticket=ticketIds.get(0);
        mvc.perform(get("/api/v1/bookings/"+booking+"/tickets")).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/bookings/"+booking+"/tickets").header("Authorization","Bearer "+bobToken)).andExpect(status().isForbidden());
        mvc.perform(get("/api/v1/bookings/"+booking+"/tickets").header("Authorization","Bearer "+aliceToken)).andExpect(status().isOk())
                .andExpect(jsonPath("$.data.length()").value(2)).andExpect(jsonPath("$.data[0].ticketId").value(ticket))
                .andExpect(jsonPath("$.data[0].seatId").value("A-01")).andExpect(jsonPath("$.data[0].status").value("ISSUED"))
                .andExpect(jsonPath("$.data[0].device").doesNotExist());

        Device phone=new Device();
        send("/api/v1/tickets/"+ticket+"/device-challenges",null,Map.of(),401,"UNAUTHORIZED");
        send("/api/v1/tickets/"+ticket+"/device-challenges",bobToken,Map.of(),403,"FORBIDDEN");
        var challenge=data(send("/api/v1/tickets/"+ticket+"/device-challenges",aliceToken,Map.of(),201,"COMMON_201"));
        Map<String,Object> request=Map.of("challengeId",challenge.get("challengeId"),"publicKey",phone.publicKey(),
                "proof",phone.proof(false,ticket,challenge.get("challenge").toString()));
        send("/api/v1/tickets/"+ticket+"/device",bobToken,request,403,"FORBIDDEN");
        var enrolled=data(send("/api/v1/tickets/"+ticket+"/device",aliceToken,request,201,"COMMON_201"));
        phone.deviceId=enrolled.get("deviceId").toString();
        Map<?,?> totp=(Map<?,?>)enrolled.get("totp");
        phone.secret=Base64.getUrlDecoder().decode(totp.get("secret").toString());
        assertEquals(20,phone.secret.length);assertEquals("SHA1",totp.get("algorithm"));assertEquals(6,totp.get("digits"));assertEquals(30,totp.get("period"));
        assertEquals(3,enrolled.get("changesRemaining"));
        // 같은 요청의 재전송: 챌린지가 이미 소비되어 거부된다.
        send("/api/v1/tickets/"+ticket+"/device",aliceToken,request,403,"DEVICE_PROOF_INVALID");
        mvc.perform(get("/api/v1/bookings/"+booking+"/tickets").header("Authorization","Bearer "+aliceToken))
                .andExpect(jsonPath("$.data[0].device.deviceId").value(phone.deviceId))
                .andExpect(jsonPath("$.data[0].device.changesRemaining").value(3))
                .andExpect(jsonPath("$.data[0].device.secret").doesNotExist()).andExpect(jsonPath("$.data[1].device").doesNotExist());

        String qr=phone.qr(ticket);
        Map<String,Object> scan=Map.of("qr",qr);
        send("/api/v1/check-ins",null,scan,401,"UNAUTHORIZED");
        // 티켓 소유자의 사용자 세션은 검표 권한이 아니다.
        send("/api/v1/check-ins",aliceToken,scan,401,"UNAUTHORIZED");
        mvc.perform(post("/api/v1/check-ins").header("X-Gate-Key","wrong-gate-key-000000").contentType("application/json")
                .content(json.writeValueAsString(scan))).andExpect(status().isUnauthorized());
        assertEquals("ISSUED",ticketStatus(ticket));
        // 1단계: 스캔은 챌린지만 발급한다. 아직 입장 처리도 이벤트도 없다.
        var scanned=data(gateScan(scan).andExpect(status().isCreated()).andExpect(jsonPath("$.data.status").value("PENDING"))
                .andExpect(jsonPath("$.data.ticketId").value(ticket)).andExpect(jsonPath("$.data.seatId").value("A-01"))
                .andExpect(jsonPath("$.data.concertTitle").value("checkin test")).andExpect(jsonPath("$.data.checkedInAt").doesNotExist())
                .andReturn().getResponse().getContentAsString(StandardCharsets.UTF_8));
        String checkInId=scanned.get("checkInId").toString();
        assertFalse(scanned.containsKey("challenge"),"the gate never sees the device challenge");
        assertEquals("ISSUED",ticketStatus(ticket));assertEquals(0,checkInEvents());
        mvc.perform(get("/api/v1/check-ins/"+checkInId)).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/check-ins/"+checkInId).header("Authorization","Bearer "+aliceToken)).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/check-ins/"+UUID.randomUUID()).header("X-Gate-Key","integration-gate-key")).andExpect(status().isNotFound())
                .andExpect(jsonPath("$.code").value("CHECKIN_NOT_FOUND"));
        mvc.perform(get("/api/v1/check-ins/"+checkInId).header("X-Gate-Key","integration-gate-key")).andExpect(status().isOk())
                .andExpect(jsonPath("$.data.status").value("PENDING"));
        // 2단계: 등록 기기가 챌린지를 받아 서명한다. 소유자 세션이 필요하다.
        String challengePath="/api/v1/tickets/"+ticket+"/check-in-challenge",proofPath="/api/v1/tickets/"+ticket+"/check-in-proofs";
        mvc.perform(get(challengePath)).andExpect(status().isUnauthorized());
        mvc.perform(get(challengePath).header("Authorization","Bearer "+bobToken)).andExpect(status().isForbidden());
        mvc.perform(get("/api/v1/tickets/"+ticketIds.get(1)+"/check-in-challenge").header("Authorization","Bearer "+aliceToken))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data").doesNotExist());
        var pending=data(mvc.perform(get(challengePath).header("Authorization","Bearer "+aliceToken)).andExpect(status().isOk())
                .andExpect(jsonPath("$.data.checkInId").value(checkInId)).andExpect(jsonPath("$.data.deviceId").value(phone.deviceId))
                .andReturn().getResponse().getContentAsString(StandardCharsets.UTF_8));
        String nonce=pending.get("challenge").toString();
        Map<String,Object> answer=Map.of("checkInId",checkInId,"proof",phone.checkInProof(ticket,checkInId,nonce));
        send(proofPath,null,answer,401,"UNAUTHORIZED");
        send(proofPath,bobToken,answer,403,"FORBIDDEN");
        // 스캔·거부된 응답까지는 입장 시각이 기록되지 않는다.
        assertEquals("ISSUED",ticketStatus(ticket));assertNull(checkedInAt(ticket));
        var admitted=data(send(proofPath,aliceToken,answer,200,"COMMON_200"));
        assertEquals(ticket,admitted.get("ticketId"));assertEquals("A-01",admitted.get("seatId"));
        assertEquals("CHECKED_IN",ticketStatus(ticket));
        // checked_in_at은 확정 시각(서버 시계)이며 응답·Outbox 발생 시각과 같은 순간이다.
        LocalDateTime confirmedAt=LocalDateTime.ofInstant(TEST_NOW,ZoneOffset.UTC);
        assertEquals(confirmedAt,checkedInAt(ticket));
        assertEquals(TEST_NOW,OffsetDateTime.parse(admitted.get("checkedInAt").toString()).toInstant());
        assertEquals(confirmedAt.truncatedTo(java.time.temporal.ChronoUnit.MILLIS),jdbc.queryForObject(
                "SELECT occurred_at_utc FROM outbox_events WHERE user_id=? AND event_type='CHECK_IN'",LocalDateTime.class,alice.id()));
        assertNull(checkedInAt(ticketIds.get(1)),"the other seat of the same booking is untouched");
        mvc.perform(get("/api/v1/check-ins/"+checkInId).header("X-Gate-Key","integration-gate-key")).andExpect(status().isOk())
                .andExpect(jsonPath("$.data.status").value("COMPLETED")).andExpect(jsonPath("$.data.checkedInAt").exists());
        mvc.perform(get(challengePath).header("Authorization","Bearer "+aliceToken)).andExpect(status().isOk()).andExpect(jsonPath("$.data").doesNotExist());
        // 같은 응답의 재전송과 캡처한 같은 QR의 재사용.
        send(proofPath,aliceToken,answer,409,"TICKET_ALREADY_CHECKED_IN");
        gateScan(scan).andExpect(status().isConflict()).andExpect(jsonPath("$.code").value("TICKET_ALREADY_CHECKED_IN"));
        assertEquals(1,checkInEvents());
        assertEquals("ISSUED",ticketStatus(ticketIds.get(1)));
        // 입장 후에는 예매 취소·기기 변경이 불가하다.
        assertEquals("BOOKING_NOT_CANCELLABLE",code(()->reservations.cancel(booking,alice)));
        assertEquals("TICKET_NOT_ADMITTABLE",code(()->phone.enroll(ticket,alice,true)));

        // 같은 예매의 BOOKING이 먼저, 그 다음 CHECK_IN이 기존 Outbox로 전송된다.
        assertTrue(delivery.deliverNext());assertTrue(delivery.deliverNext());assertFalse(delivery.deliverNext());
        assertEquals(List.of("BOOKING","CHECK_IN"),SENT.stream().map(m->m.get("eventType")).toList());
        Map<String,Object> event=SENT.get(1);
        assertEquals(ticket,event.get("ticketId"));assertEquals(booking,event.get("bookingId"));
        assertTrue(event.get("occurredAt").toString().matches(".*T\\d{2}:\\d{2}:\\d{2}(\\.\\d{3})?Z"));
        Map<?,?> metadata=(Map<?,?>)event.get("metadata");
        assertEquals(Set.of("concertId","performanceStartsAt","performanceEndsAt","deviceChanged"),metadata.keySet());
        assertEquals(false,metadata.get("deviceChanged"));assertEquals(concert,metadata.get("concertId"));
        assertEquals("SENT",jdbc.queryForObject("SELECT delivery_status FROM outbox_events WHERE user_id=? AND event_type='CHECK_IN'",String.class,alice.id()));
        // 비밀키·서명·QR 원문은 이벤트에 실리지 않는다.
        String raw=json.writeValueAsString(event);
        assertFalse(raw.contains(totp.get("secret").toString()));assertFalse(raw.contains(qr.substring(qr.lastIndexOf('.')+1)));
        assertFalse(raw.contains(nonce));assertFalse(raw.contains(answer.get("proof").toString()));
    }

    @Test void registrationRequiresOwnerFreshChallengeAndPossessionOfThePrivateKey()throws Exception{
        String ticket=ticketIds.get(0);
        Device phone=new Device(),attacker=new Device();
        assertEquals("FORBIDDEN",code(()->devices.challenge(ticket,bob)));
        assertEquals("TICKET_NOT_FOUND",code(()->devices.challenge(UUID.randomUUID().toString(),alice)));
        assertEquals("FORBIDDEN",code(()->devices.tickets(booking,bob)));
        assertEquals("BOOKING_NOT_FOUND",code(()->devices.tickets("b_missing",alice)));
        var first=devices.challenge(ticket,alice);
        assertEquals("DEVICE_KEY_INVALID",code(()->devices.enroll(ticket,alice,first.challengeId(),"not-a-key","AAAA",false)));
        // 다른 키의 서명, 다른 목적(change)의 서명, 다른 티켓용 챌린지는 모두 거부된다.
        assertEquals("DEVICE_PROOF_INVALID",code(()->devices.enroll(ticket,alice,first.challengeId(),phone.publicKey(),attacker.proof(false,ticket,first.challenge()),false)));
        assertEquals("DEVICE_PROOF_INVALID",code(()->devices.enroll(ticket,alice,first.challengeId(),phone.publicKey(),phone.proof(true,ticket,first.challenge()),false)));
        assertEquals("DEVICE_PROOF_INVALID",code(()->devices.enroll(ticketIds.get(1),alice,first.challengeId(),phone.publicKey(),phone.proof(false,ticketIds.get(1),first.challenge()),false)));
        assertEquals("DEVICE_PROOF_INVALID",code(()->devices.enroll(ticket,alice,UUID.randomUUID().toString(),phone.publicKey(),phone.proof(false,ticket,first.challenge()),false)));
        assertEquals("DEVICE_NOT_REGISTERED",code(()->devices.enroll(ticket,alice,first.challengeId(),phone.publicKey(),phone.proof(true,ticket,first.challenge()),true)));
        // 새 챌린지를 발급하면 이전 챌린지는 무효다.
        var second=devices.challenge(ticket,alice);
        assertEquals("DEVICE_PROOF_INVALID",code(()->devices.enroll(ticket,alice,first.challengeId(),phone.publicKey(),phone.proof(false,ticket,first.challenge()),false)));
        clock.advance(Duration.ofMinutes(2));
        assertEquals("DEVICE_PROOF_INVALID",code(()->devices.enroll(ticket,alice,second.challengeId(),phone.publicKey(),phone.proof(false,ticket,second.challenge()),false)));
        assertEquals(0,jdbc.queryForObject("SELECT COUNT(*) FROM ticket_device_bindings WHERE user_id=?",Long.class,alice.id()));

        var enrolled=phone.enroll(ticket,alice,false);
        assertEquals(3,enrolled.changesRemaining());
        assertEquals("DEVICE_ALREADY_REGISTERED",code(()->attacker.enroll(ticket,alice,false)));
        assertEquals(0,jdbc.queryForObject("SELECT COUNT(*) FROM ticket_device_challenges WHERE user_id=?",Long.class,alice.id())
                -1,"only the unused challenge of the rejected attempt remains");
        // 저장된 비밀키는 암호문이다.
        byte[] stored=jdbc.queryForObject("SELECT totp_secret_enc FROM ticket_device_bindings WHERE public_id=?",byte[].class,phone.deviceId);
        assertEquals(48,stored.length);
        assertFalse(HexFormat.of().formatHex(stored).contains(HexFormat.of().formatHex(phone.secret)));
    }

    @Test void deviceChangeRevokesOldBindingAndIsLimitedToThreeTimes()throws Exception{
        String ticket=ticketIds.get(0);
        Device old=new Device();old.enroll(ticket,alice,false);
        Device current=new Device();
        assertEquals(2,current.enroll(ticket,alice,true).changesRemaining());
        assertFalse(Arrays.equals(old.secret,current.secret));
        // 이전 기기의 QR, 그리고 이전 기기 키 + 새 deviceId 조합은 거부된다.
        assertEquals("QR_REJECTED",code(()->checkIns.scan(old.qr(ticket))));
        old.deviceId=current.deviceId;
        assertEquals("QR_REJECTED",code(()->checkIns.scan(old.qr(ticket))));
        assertEquals(1,jdbc.queryForObject("SELECT COUNT(*) FROM ticket_device_bindings WHERE user_id=? AND status='REVOKED' AND totp_secret_enc IS NULL AND revoked_at IS NOT NULL",Long.class,alice.id()));
        for(int remaining=1;remaining>=0;remaining--){
            current=new Device();
            assertEquals(remaining,current.enroll(ticket,alice,true).changesRemaining());
        }
        Device fifth=new Device();
        assertEquals("DEVICE_CHANGE_LIMIT",code(()->fifth.enroll(ticket,alice,true)));
        assertEquals(1,jdbc.queryForObject("SELECT COUNT(*) FROM ticket_device_bindings WHERE user_id=? AND status='ACTIVE'",Long.class,alice.id()));
        assertEquals(4,jdbc.queryForObject("SELECT MAX(generation) FROM ticket_device_bindings WHERE user_id=?",Integer.class,alice.id()));
        // 한도에 도달해도 마지막으로 등록한 기기는 계속 유효하고 deviceChanged가 기록된다.
        assertEquals(ticket,current.admit(ticket).ticketId());
        assertTrue(jdbc.queryForObject("SELECT JSON_EXTRACT(metadata,'$.deviceChanged') FROM outbox_events WHERE user_id=? AND event_type='CHECK_IN'",String.class,alice.id()).contains("true"));
        // 다른 좌석 티켓의 변경 횟수는 독립적이다.
        Device second=new Device();
        assertEquals(3,second.enroll(ticketIds.get(1),alice,false).changesRemaining());
    }

    @Test void qrNeedsDeviceSignatureCurrentTotpValidTicketAndOpenAdmissionWindow()throws Exception{
        String ticket=ticketIds.get(0),otherTicket=ticketIds.get(1);
        Device phone=new Device();phone.enroll(ticket,alice,false);
        long ts=clock.instant().getEpochSecond();
        String valid=phone.qr(ticket);
        for(String bad:new String[]{"","hello","BTS2"+valid.substring(4),valid+"x",valid.replace("BTS1.","BTS1.."),valid.substring(0,valid.lastIndexOf('.'))})
            assertEquals("QR_INVALID",code(()->checkIns.scan(bad)));
        assertEquals("TICKET_NOT_FOUND",code(()->checkIns.scan(phone.qr(UUID.randomUUID().toString()))));
        // 서명 후 내용 변조.
        String otherCode=Totp.code(phone.secret,Totp.counter(ts)).equals("000000")?"000001":"000000";
        assertEquals("QR_REJECTED",code(()->checkIns.scan(valid.replaceFirst("\\.\\d{6}\\.","."+otherCode+"."))));
        // 기기 키는 맞지만 TOTP가 틀린 경우.
        assertEquals("QR_REJECTED",code(()->checkIns.scan(phone.qr(ticket,ts,otherCode))));
        // TOTP 비밀키와 deviceId만 복사한 다른 기기: 올바른 TOTP여도 서명이 맞지 않는다.
        Device copied=new Device();copied.secret=phone.secret;copied.deviceId=phone.deviceId;
        assertEquals("QR_REJECTED",code(()->checkIns.scan(copied.qr(ticket))));
        // 한 티켓의 기기로 다른 티켓 QR을 만들 수 없다.
        assertEquals("QR_REJECTED",code(()->checkIns.scan(phone.qr(otherTicket))));
        // 미래·과거 시각을 자기 서명해도 서버 시각 기준 ±1 step만 허용한다.
        assertEquals("QR_EXPIRED",code(()->checkIns.scan(phone.qr(ticket,ts+120,Totp.code(phone.secret,Totp.counter(ts+120))))));
        clock.advance(Duration.ofSeconds(90));
        assertEquals("QR_EXPIRED",code(()->checkIns.scan(valid)));
        assertEquals("ISSUED",ticketStatus(ticket));assertEquals(0,checkInEvents());

        // 입장 시간 이전(공연 시작 2시간 전보다 이름)과 공연 종료 이후.
        clock.time.set(TEST_NOW.minus(Duration.ofHours(2)));
        assertEquals("CHECKIN_NOT_OPEN",code(()->checkIns.scan(phone.qr(ticket))));
        clock.time.set(TEST_NOW.plus(Duration.ofHours(4)));
        assertEquals("CHECKIN_NOT_OPEN",code(()->checkIns.scan(phone.qr(ticket))));
        assertEquals("ISSUED",ticketStatus(ticket));

        // 직전 step의 QR은 허용한다(스캔 지연).
        clock.time.set(TEST_NOW);
        String previous=phone.qr(ticket);
        clock.advance(Duration.ofSeconds(30));
        assertEquals(ticket,phone.admit(ticket,previous).ticketId());
        assertEquals("TICKET_ALREADY_CHECKED_IN",code(()->checkIns.scan(phone.qr(ticket))));
    }

    @Test void cancelledBookingCannotCheckInOrRegister()throws Exception{
        String ticket=ticketIds.get(0);
        Device phone=new Device();phone.enroll(ticket,alice,false);
        reservations.cancel(booking,alice);
        assertEquals("CANCELLED",ticketStatus(ticket));
        assertEquals("TICKET_NOT_ADMITTABLE",code(()->checkIns.scan(phone.qr(ticket))));
        assertEquals("TICKET_NOT_ADMITTABLE",code(()->devices.challenge(ticket,alice)));
        assertEquals("TICKET_NOT_ADMITTABLE",code(()->devices.challenge(ticketIds.get(1),alice)));
        assertEquals(0,checkInEvents());
        assertEquals("CANCELLED",devices.tickets(booking,alice).get(0).status());
    }

    private List<String> race(int workers,Callable<String> work)throws Exception{
        ExecutorService pool=Executors.newFixedThreadPool(workers);
        CountDownLatch start=new CountDownLatch(1);
        List<Future<String>> results=new ArrayList<>();
        for(int i=0;i<workers;i++)results.add(pool.submit(()->{
            start.await();
            try{return work.call();}catch(ApiException e){return e.getResponseCode().getCode();}
        }));
        start.countDown();
        List<String> outcomes=new ArrayList<>();
        for(var result:results)outcomes.add(result.get(30,TimeUnit.SECONDS));
        pool.shutdown();
        return outcomes;
    }

    @Test void concurrentScansAndProofsOfOneTicketAdmitExactlyOnceAndEachSeatHasItsOwnEvent()throws Exception{
        String ticket=ticketIds.get(0);
        Device phone=new Device();phone.enroll(ticket,alice,false);
        String qr=phone.qr(ticket);
        int scanners=8;
        // 여러 검표기가 같은 QR을 동시에 스캔해도 유효한 챌린지는 마지막 1개뿐이다.
        List<String> scans=race(scanners,()->checkIns.scan(qr).checkInId());
        assertEquals(scanners,new HashSet<>(scans).size(),scans.toString());
        assertEquals(1,jdbc.queryForObject("SELECT COUNT(*) FROM ticket_checkin_challenges WHERE status='PENDING' AND ticket_id=(SELECT id FROM admission_tickets WHERE public_id=?)",Long.class,ticket));
        assertEquals(scanners-1,scans.stream().filter(id->challengeStatus(id).equals("SUPERSEDED")).count());
        assertEquals("ISSUED",ticketStatus(ticket));assertEquals(0,checkInEvents());
        // 같은 챌린지 응답이 동시에 여러 번 도착해도 한 번만 입장된다.
        var pending=checkIns.pending(ticket,alice);
        String proof=phone.checkInProof(ticket,pending.checkInId(),pending.challenge());
        List<String> outcomes=race(scanners,()->{checkIns.confirm(ticket,alice,pending.checkInId(),proof);return "OK";});
        assertEquals(1,Collections.frequency(outcomes,"OK"),outcomes.toString());
        assertEquals(scanners-1,Collections.frequency(outcomes,"TICKET_ALREADY_CHECKED_IN"),outcomes.toString());
        assertEquals(1,checkInEvents());
        assertEquals("COMPLETED",checkIns.status(pending.checkInId()).status());
        // 같은 예매의 다른 좌석은 별도 전이 ID로 한 번 더 기록된다.
        Device second=new Device();second.enroll(ticketIds.get(1),alice,false);
        second.admit(ticketIds.get(1));
        assertEquals(2,checkInEvents());
        assertEquals(2,jdbc.queryForObject("SELECT COUNT(DISTINCT business_transition_id) FROM outbox_events WHERE user_id=? AND event_type='CHECK_IN' AND aggregate_id=?",Long.class,alice.id(),booking));
    }

    @Test void capturedQrAloneCannotCheckInWithoutTheRegisteredDeviceKey()throws Exception{
        String ticket=ticketIds.get(0);
        Device phone=new Device();phone.enroll(ticket,alice,false);
        // 구매자는 판매자가 보낸 QR 캡처본만 갖고 있다. 유효 시간 안이라 스캔은 통과하지만 챌린지만 발급된다.
        String captured=phone.qr(ticket);
        var scan=checkIns.scan(captured);
        assertEquals("PENDING",scan.status());assertNull(scan.checkedInAt());
        assertEquals("ISSUED",ticketStatus(ticket));assertEquals(0,checkInEvents());
        // 구매자 세션으로는 챌린지를 볼 수도 응답할 수도 없다.
        assertEquals("FORBIDDEN",code(()->checkIns.pending(ticket,bob)));
        assertEquals("FORBIDDEN",code(()->checkIns.confirm(ticket,bob,scan.checkInId(),"AAAA")));
        assertEquals("PENDING",challengeStatus(scan.checkInId()));
        // 등록 기기의 응답이 없으면 챌린지는 만료되고 입장되지 않는다.
        clock.advance(Duration.ofSeconds(15));
        assertEquals("EXPIRED",checkIns.status(scan.checkInId()).status());
        assertNull(checkIns.pending(ticket,alice));
        assertEquals("ISSUED",ticketStatus(ticket));

        // 판매자 계정까지 넘겨받아도(Demo 로그인은 ID만 필요) 개인키가 없는 기기의 서명은 거부되고 챌린지는 소비된다.
        var second=checkIns.scan(phone.qr(ticket));
        var pending=checkIns.pending(ticket,alice);
        assertEquals(second.checkInId(),pending.checkInId());
        Device buyer=new Device();buyer.deviceId=phone.deviceId;buyer.secret=phone.secret;
        assertEquals("CHECKIN_PROOF_INVALID",code(()->checkIns.confirm(ticket,alice,pending.checkInId(),buyer.checkInProof(ticket,pending.checkInId(),pending.challenge()))));
        assertEquals("REJECTED",checkIns.status(second.checkInId()).status());
        // 소비된 챌린지에는 등록 기기의 올바른 서명도 통하지 않는다(일회성).
        assertEquals("CHECKIN_PROOF_INVALID",code(()->checkIns.confirm(ticket,alice,pending.checkInId(),phone.checkInProof(ticket,pending.checkInId(),pending.challenge()))));
        // QR에 들어 있던 서명을 응답으로 재사용할 수도 없다.
        var third=checkIns.scan(phone.qr(ticket));
        assertEquals("CHECKIN_PROOF_INVALID",code(()->checkIns.confirm(ticket,alice,third.checkInId(),captured.substring(captured.lastIndexOf('.')+1))));
        assertEquals("CHECKIN_PROOF_INVALID",code(()->checkIns.confirm(ticket,alice,UUID.randomUUID().toString(),"not base64!")));
        assertEquals("ISSUED",ticketStatus(ticket));assertNull(checkedInAt(ticket));assertEquals(0,checkInEvents());

        // 실패·만료 후에도 등록 기기는 새로 스캔해 정상 입장할 수 있다.
        assertEquals(ticket,phone.admit(ticket).ticketId());
        assertEquals("CHECKED_IN",ticketStatus(ticket));assertEquals(1,checkInEvents());
        LocalDateTime first=checkedInAt(ticket);
        assertNotNull(first);
        // 중복 검표 시도는 최초 입장 시각을 바꾸지 않는다.
        clock.advance(Duration.ofSeconds(5));
        assertEquals("TICKET_ALREADY_CHECKED_IN",code(()->checkIns.scan(phone.qr(ticket))));
        assertEquals(first,checkedInAt(ticket));assertEquals(1,checkInEvents());
        clock.advance(Duration.ofSeconds(-5));
        assertEquals("TICKET_ALREADY_CHECKED_IN",code(()->checkIns.scan(captured)));
    }

    @Test void checkInChallengeIsOneTimeShortLivedAndBoundToTicketDeviceAndScan()throws Exception{
        String ticket=ticketIds.get(0),otherTicket=ticketIds.get(1);
        Device phone=new Device();phone.enroll(ticket,alice,false);
        Device other=new Device();other.enroll(otherTicket,alice,false);
        assertNull(checkIns.pending(ticket,alice));
        // 새 스캔은 이전 챌린지를 무효화한다. 이전 챌린지에 대한 서명은 새 챌린지에 쓸 수 없다.
        var first=checkIns.scan(phone.qr(ticket));
        var firstChallenge=checkIns.pending(ticket,alice);
        var second=checkIns.scan(phone.qr(ticket));
        assertEquals("SUPERSEDED",checkIns.status(first.checkInId()).status());
        String stale=phone.checkInProof(ticket,first.checkInId(),firstChallenge.challenge());
        assertEquals("CHECKIN_PROOF_INVALID",code(()->checkIns.confirm(ticket,alice,first.checkInId(),stale)));
        assertEquals("PENDING",challengeStatus(second.checkInId()));
        assertEquals("CHECKIN_PROOF_INVALID",code(()->checkIns.confirm(ticket,alice,second.checkInId(),stale)));
        assertEquals("REJECTED",challengeStatus(second.checkInId()));

        // 한 티켓의 챌린지·기기로 다른 티켓을 입장시킬 수 없다.
        var third=checkIns.scan(phone.qr(ticket));
        var thirdChallenge=checkIns.pending(ticket,alice);
        assertEquals("CHECKIN_PROOF_INVALID",code(()->checkIns.confirm(otherTicket,alice,third.checkInId(),other.checkInProof(otherTicket,third.checkInId(),thirdChallenge.challenge()))));
        assertEquals("PENDING",challengeStatus(third.checkInId()));
        // 유효 시간(15초)이 지나면 올바른 서명도 거부된다.
        clock.advance(Duration.ofSeconds(15));
        assertEquals("CHECKIN_PROOF_INVALID",code(()->checkIns.confirm(ticket,alice,third.checkInId(),phone.checkInProof(ticket,third.checkInId(),thirdChallenge.challenge()))));
        assertEquals("ISSUED",ticketStatus(ticket));assertEquals("ISSUED",ticketStatus(otherTicket));assertEquals(0,checkInEvents());

        // 스캔 후 기기를 변경하면 이전 기기는 응답할 수 없고, 새 기기는 자기 QR을 다시 스캔해야 한다.
        var fourth=checkIns.scan(phone.qr(ticket));
        var fourthChallenge=checkIns.pending(ticket,alice);
        Device replaced=new Device();replaced.enroll(ticket,alice,true);
        assertNull(checkIns.pending(ticket,alice));
        assertEquals("CHECKIN_PROOF_INVALID",code(()->checkIns.confirm(ticket,alice,fourth.checkInId(),phone.checkInProof(ticket,fourth.checkInId(),fourthChallenge.challenge()))));
        var fifth=checkIns.scan(replaced.qr(ticket));
        var fifthChallenge=checkIns.pending(ticket,alice);
        // 스캔 후 예매가 취소되면 올바른 응답도 입장으로 이어지지 않는다.
        reservations.cancel(booking,alice);
        assertEquals("TICKET_NOT_ADMITTABLE",code(()->checkIns.confirm(ticket,alice,fifth.checkInId(),replaced.checkInProof(ticket,fifth.checkInId(),fifthChallenge.challenge()))));
        assertEquals("REJECTED",checkIns.status(fifth.checkInId()).status());
        assertEquals("CANCELLED",ticketStatus(ticket));assertEquals(0,checkInEvents());
    }

    private static HttpServer remote(){
        JsonMapper mapper=JsonMapper.builder().build();
        Map<String,String> registered=new ConcurrentHashMap<>();
        java.util.concurrent.atomic.AtomicLong sequence=new java.util.concurrent.atomic.AtomicLong();
        try{
            HttpServer server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
            server.createContext("/api/v1/",exchange->{
                Map<String,Object> body=mapper.readValue(exchange.getRequestBody().readAllBytes(),new TypeReference<Map<String,Object>>() {});
                Map<String,Object> data=new LinkedHashMap<>();
                if(exchange.getRequestURI().getPath().endsWith("/users")){
                    String external=body.get("externalUserId").toString();
                    data.put("userId",registered.computeIfAbsent(external,k->UUID.randomUUID().toString()));
                    data.put("serviceId",body.get("serviceId"));data.put("externalUserId",external);
                }else{
                    SENT.add(body);data.putAll(body);data.put("eventId",sequence.incrementAndGet());
                }
                Map<String,Object> envelope=new LinkedHashMap<>();
                envelope.put("success",true);envelope.put("code","COMMON_201");envelope.put("data",data);envelope.put("message","test");
                byte[] bytes=mapper.writeValueAsBytes(envelope);
                exchange.getResponseHeaders().set("Content-Type","application/json");
                exchange.sendResponseHeaders(201,bytes.length);exchange.getResponseBody().write(bytes);exchange.close();
            });
            server.start();return server;
        }catch(IOException e){throw new IllegalStateException(e);}
    }
}
