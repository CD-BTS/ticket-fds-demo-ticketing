package com.bts.demoticketing.attempt;

import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import com.bts.demoticketing.booking.service.ReservationService;
import com.bts.demoticketing.queue.QueueService;
import com.bts.demoticketing.user.entity.DemoUser;
import com.bts.demoticketing.user.repository.DemoUserRepository;
import static org.junit.jupiter.api.Assertions.*;

/** Requires the booking-attempt schema in an isolated DB; never changes schema. */
@Tag("mysql")
@SpringBootTest(properties={"demo.jobs.enabled=false","demo.attempts.enabled=true","bts.enabled=false","bts.service-id=issue28-test"})
class AttemptMySqlTests {
    @Autowired JdbcTemplate jdbc;
    @Autowired DemoUserRepository users;
    @Autowired AttemptService attempts;
    @Autowired ReservationService reservations;
    @MockitoBean QueueService queue;
    DemoUser user;String concert;long concertId;
    @BeforeEach void setup(){
        assertEquals("demo_ticketing_db",jdbc.queryForObject("SELECT DATABASE()",String.class));
        assertEquals(2,jdbc.queryForObject("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name IN ('booking_attempts','booking_attempt_events')",Integer.class),"Review/apply migration in the isolated test database first");
        concert="i28-"+UUID.randomUUID();
        jdbc.update("INSERT INTO concerts(public_id,title,artist,venue,start_at,end_at,price_from,tagline,hue) VALUES(?,'test','test','test','2027-01-01 00:00:00','2027-01-01 03:00:00',100,'test',0)",concert);
        concertId=jdbc.queryForObject("SELECT id FROM concerts WHERE public_id=?",Long.class,concert);
        jdbc.update("INSERT INTO concert_seats(concert_id,seat_code,row_label,seat_number,grade,price,state) VALUES(?,'A-01','A',1,'VIP',100,'AVAILABLE')",concertId);
        user=users.createOrGet("i28-"+UUID.randomUUID(),"issue28-test",java.time.LocalDateTime.now(java.time.ZoneOffset.UTC));
    }
    @AfterEach void cleanup(){
        if(user==null)return;
        jdbc.update("DELETE FROM booking_attempt_events WHERE attempt_id IN (SELECT attempt_id FROM booking_attempts WHERE concert_id=?)",concertId);
        jdbc.update("DELETE FROM booking_attempts WHERE concert_id=?",concertId);
        jdbc.update("DELETE FROM outbox_events WHERE user_id=?",user.id());
        jdbc.update("UPDATE concert_seats SET state='AVAILABLE',active_hold_id=NULL,active_booking_id=NULL WHERE concert_id=?",concertId);
        jdbc.update("DELETE FROM admission_tickets WHERE booking_id IN (SELECT id FROM bookings WHERE concert_id=?)",concertId);
        jdbc.update("DELETE FROM booking_seats WHERE booking_id IN (SELECT id FROM bookings WHERE concert_id=?)",concertId);
        jdbc.update("DELETE FROM bookings WHERE concert_id=?",concertId);
        jdbc.update("DELETE FROM seat_hold_items WHERE hold_id IN (SELECT id FROM seat_holds WHERE concert_id=?)",concertId);
        jdbc.update("DELETE FROM seat_holds WHERE concert_id=?",concertId);
        jdbc.update("DELETE FROM reservation_user_concert_guards WHERE concert_id=?",concertId);
        jdbc.update("DELETE FROM concert_seats WHERE concert_id=?",concertId);
        jdbc.update("DELETE FROM concerts WHERE id=?",concertId);
        jdbc.update("DELETE FROM demo_users WHERE id=?",user.id());
    }
    @Test void duplicateStartAndBookingRetriesKeepOneAttemptAndExistingBusinessEvents(){
        String id=UUID.randomUUID().toString();
        attempts.start(concert,id,user,"2026-11-08T00:00:00Z");
        attempts.start(concert,id,user,"2026-11-08T00:00:00Z");
        assertEquals(1,jdbc.queryForObject("SELECT COUNT(*) FROM booking_attempt_events WHERE attempt_id=?",Integer.class,id));
        var hold=reservations.hold(concert,user,List.of("A-01"),id);
        attempts.client(id,user,UUID.randomUUID().toString(),"PAYMENT","ENTERED");
        var booking=reservations.confirm(hold.holdId(),"test-pay-shared-01","127.0.0.1",user).booking();
        assertFalse(reservations.confirm(hold.holdId(),"test-pay-shared-01","127.0.0.1",user).created());
        reservations.cancel(booking.id(),user);reservations.cancel(booking.id(),user);
        assertEquals("COMPLETED",attempts.get(id,user).stage());
        assertEquals(id,jdbc.queryForObject("SELECT JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.attemptId')) FROM outbox_events WHERE aggregate_id=? AND event_type='BOOKING'",String.class,booking.id()));
        assertEquals(2,jdbc.queryForObject("SELECT COUNT(*) FROM outbox_events WHERE aggregate_id=?",Integer.class,booking.id()));
        attempts.materialize();attempts.materialize();
        assertEquals(4,jdbc.queryForObject("SELECT COUNT(*) FROM outbox_events WHERE user_id=? AND event_type='BOOKING_ATTEMPT'",Integer.class,user.id()));
    }
    private String ip(String table,String id,String stage){
        return jdbc.queryForObject("SELECT JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.ipAddress')) FROM "+table+" WHERE JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.attemptId'))=?"
                +" AND JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.stage'))=?",String.class,id,stage);
    }
    /** #68: 클라이언트 요청 전이에만 IP가 실리고, 재요청은 최초 IP를 유지하며, Outbox로 그대로 옮겨진다. */
    @Test void clientIpIsRecordedOnceForClientTransitionsAndCarriedToTheOutbox(){
        String id=UUID.randomUUID().toString(),payment=UUID.randomUUID().toString();
        attempts.start(concert,id,user,"2026-11-08T00:00:00Z","203.0.113.7");
        // 같은 시작 요청을 다른 네트워크에서 다시 보냄: 새 이벤트 없음, 409 없음, 최초 IP 유지
        attempts.start(concert,id,user,"2026-11-08T00:00:00Z","198.51.100.9");
        attempts.start(concert,id,user,"2026-11-08T00:00:00Z",null);
        assertEquals(1,jdbc.queryForObject("SELECT COUNT(*) FROM booking_attempt_events WHERE attempt_id=?",Integer.class,id));
        assertEquals("203.0.113.7",ip("booking_attempt_events",id,"STARTED"));
        // 요청 내용이 실제로 바뀌면 지금처럼 409다
        assertEquals("DATA_CONFLICT",assertThrows(com.bts.demoticketing.common.exception.ApiException.class,
                ()->attempts.start(concert,id,user,"2026-11-08T00:00:09Z","203.0.113.7")).getResponseCode().getCode());

        reservations.hold(concert,user,List.of("A-01"),id);                                  // 서버 관측 전이: IP 없음
        attempts.client(id,user,payment,"PAYMENT","ENTERED","198.51.100.9");                 // 단계 보고는 그 요청의 IP
        attempts.client(id,user,payment,"PAYMENT","ENTERED","192.0.2.44");                   // 재전송
        assertEquals("DATA_CONFLICT",assertThrows(com.bts.demoticketing.common.exception.ApiException.class,
                ()->attempts.client(id,user,payment,"PAYMENT","ABANDONED","198.51.100.9")).getResponseCode().getCode());
        assertEquals(3,jdbc.queryForObject("SELECT COUNT(*) FROM booking_attempt_events WHERE attempt_id=?",Integer.class,id));
        assertEquals("198.51.100.9",ip("booking_attempt_events",id,"PAYMENT"));
        assertNull(ip("booking_attempt_events",id,"SEAT_HOLD"));

        attempts.materialize();attempts.materialize();
        assertEquals(3,jdbc.queryForObject("SELECT COUNT(*) FROM outbox_events WHERE user_id=? AND event_type='BOOKING_ATTEMPT'",Integer.class,user.id()));
        assertEquals("203.0.113.7",ip("outbox_events",id,"STARTED"));
        assertEquals("198.51.100.9",ip("outbox_events",id,"PAYMENT"));
        assertNull(ip("outbox_events",id,"SEAT_HOLD"));
    }
}
