package com.bts.demoticketing.ticket;

import java.time.LocalDateTime;
import java.util.*;
import org.springframework.jdbc.core.*;
import org.springframework.stereotype.Repository;

@Repository
public class TicketRepository {
    private final JdbcTemplate jdbc;
    public TicketRepository(JdbcTemplate jdbc){this.jdbc=jdbc;}

    /** admission_tickets 한 행과 예매 snapshot. 좌석·공연 정보는 예매 당시 값을 쓴다. */
    public record Ticket(long id,String publicId,long bookingId,String bookingPublicId,long userId,String concertId,
            String seatCode,String status,LocalDateTime checkedInAt,String bookingStatus,String title,
            LocalDateTime startAt,LocalDateTime endAt){}
    /** secret은 암호화된 값이다. 복호화는 검표 시점에만 한다. */
    public record Binding(long id,String publicId,long ticketId,int generation,byte[] publicKey,byte[] secret,LocalDateTime createdAt){}
    public record Challenge(long id,String challenge,long ticketId,long userId,LocalDateTime expiresAt){}
    /** 검표 챌린지(ticket_checkin_challenges). status는 PENDING/COMPLETED/REJECTED/SUPERSEDED이며 만료는 expiresAt으로 판단한다. */
    public record GateChallenge(long id,String publicId,long ticketId,long bindingId,String challenge,String status,LocalDateTime expiresAt){}

    private static final String TICKET_SQL="""
            SELECT t.id,t.public_id,t.status,t.checked_in_at,b.id AS booking_id,b.public_id AS booking_public_id,
              b.user_id,b.status AS booking_status,b.concert_title_snapshot,b.start_at_snapshot,b.end_at_snapshot,
              c.public_id AS concert_public_id,s.seat_code_snapshot
            FROM admission_tickets t JOIN bookings b ON b.id=t.booking_id JOIN concerts c ON c.id=b.concert_id
            JOIN booking_seats s ON s.booking_id=t.booking_id AND s.concert_seat_id=t.concert_seat_id
            """;
    private final RowMapper<Ticket> ticket=(r,n)->new Ticket(r.getLong("id"),r.getString("public_id"),r.getLong("booking_id"),
            r.getString("booking_public_id"),r.getLong("user_id"),r.getString("concert_public_id"),r.getString("seat_code_snapshot"),
            r.getString("status"),r.getObject("checked_in_at",LocalDateTime.class),r.getString("booking_status"),
            r.getString("concert_title_snapshot"),r.getObject("start_at_snapshot",LocalDateTime.class),
            r.getObject("end_at_snapshot",LocalDateTime.class));
    private final RowMapper<Binding> binding=(r,n)->new Binding(r.getLong("id"),r.getString("public_id"),r.getLong("ticket_id"),
            r.getInt("generation"),r.getBytes("public_key"),r.getBytes("totp_secret_enc"),r.getObject("created_at",LocalDateTime.class));

    public Optional<Ticket> ticket(long id){return jdbc.query(TICKET_SQL+" WHERE t.id=?",ticket,id).stream().findFirst();}
    public Optional<Ticket> ticket(String publicId){return jdbc.query(TICKET_SQL+" WHERE t.public_id=?",ticket,publicId).stream().findFirst();}
    public List<Ticket> bookingTickets(long bookingId){return jdbc.query(TICKET_SQL+" WHERE b.id=? ORDER BY s.seat_code_snapshot",ticket,bookingId);}
    /** 같은 예매의 취소·기기 변경·검표를 직렬화한다. 취소 경로(좌석→예매)와 잠금 순서가 충돌하지 않는다. */
    public void lockBooking(long bookingId){jdbc.queryForObject("SELECT id FROM bookings WHERE id=? FOR UPDATE",Long.class,bookingId);}

    public Optional<Binding> activeBinding(long ticketId){
        return jdbc.query("SELECT * FROM ticket_device_bindings WHERE active_ticket_id=?",binding,ticketId).stream().findFirst();
    }
    public void revoke(long bindingId,LocalDateTime now){
        if(jdbc.update("UPDATE ticket_device_bindings SET status='REVOKED',totp_secret_enc=NULL,revoked_at=? WHERE id=? AND status='ACTIVE'",now,bindingId)!=1)
            throw new IllegalStateException("Device binding revocation invariant violated");
    }
    public void createBinding(String publicId,long ticketId,long userId,int generation,byte[] publicKey,byte[] secret,LocalDateTime now){
        jdbc.update("""
                INSERT INTO ticket_device_bindings(public_id,ticket_id,user_id,status,generation,public_key,totp_secret_enc,created_at)
                VALUES(?,?,?,'ACTIVE',?,?,?,?)
                """,publicId,ticketId,userId,generation,publicKey,secret,now);
    }

    public void replaceChallenge(String publicId,long ticketId,long userId,String challenge,LocalDateTime expiry){
        jdbc.update("DELETE FROM ticket_device_challenges WHERE ticket_id=? AND user_id=?",ticketId,userId);
        jdbc.update("INSERT INTO ticket_device_challenges(public_id,ticket_id,user_id,challenge,expires_at) VALUES(?,?,?,?,?)",
                publicId,ticketId,userId,challenge,expiry);
    }
    public Optional<Challenge> challenge(String publicId){
        return jdbc.query("SELECT * FROM ticket_device_challenges WHERE public_id=?",(r,n)->new Challenge(r.getLong("id"),
                r.getString("challenge"),r.getLong("ticket_id"),r.getLong("user_id"),r.getObject("expires_at",LocalDateTime.class)),publicId)
                .stream().findFirst();
    }
    public boolean consumeChallenge(long id){return jdbc.update("DELETE FROM ticket_device_challenges WHERE id=?",id)==1;}

    private final RowMapper<GateChallenge> gateChallenge=(r,n)->new GateChallenge(r.getLong("id"),r.getString("public_id"),r.getLong("ticket_id"),
            r.getLong("binding_id"),r.getString("challenge"),r.getString("status"),r.getObject("expires_at",LocalDateTime.class));
    /** 새 스캔은 같은 티켓의 이전 PENDING을 무효화한다. 오래된 종료 행은 함께 정리한다. 예매 행 잠금 안에서 호출한다. */
    public void createGateChallenge(String publicId,long ticketId,long bindingId,String challenge,LocalDateTime now,LocalDateTime expiry){
        jdbc.update("UPDATE ticket_checkin_challenges SET status='SUPERSEDED',resolved_at=? WHERE pending_ticket_id=?",now,ticketId);
        jdbc.update("DELETE FROM ticket_checkin_challenges WHERE ticket_id=? AND status<>'PENDING' AND created_at<?",ticketId,now.minusHours(1));
        jdbc.update("INSERT INTO ticket_checkin_challenges(public_id,ticket_id,binding_id,challenge,status,created_at,expires_at) VALUES(?,?,?,?,'PENDING',?,?)",
                publicId,ticketId,bindingId,challenge,now,expiry);
    }
    public Optional<GateChallenge> gateChallenge(String publicId){
        return jdbc.query("SELECT * FROM ticket_checkin_challenges WHERE public_id=?",gateChallenge,publicId).stream().findFirst();
    }
    public Optional<GateChallenge> pendingGateChallenge(long ticketId,LocalDateTime now){
        return jdbc.query("SELECT * FROM ticket_checkin_challenges WHERE pending_ticket_id=? AND expires_at>?",gateChallenge,ticketId,now).stream().findFirst();
    }
    /** PENDING인 챌린지만 한 번 종료된다(일회성). 0이면 이미 소비·대체된 것이다. */
    public boolean resolveGateChallenge(long id,String status,LocalDateTime now){
        return jdbc.update("UPDATE ticket_checkin_challenges SET status=?,resolved_at=? WHERE id=? AND status='PENDING'",status,now,id)==1;
    }

    /** ISSUED인 티켓만 한 번 CHECKED_IN으로 바뀐다. 0이면 이미 다른 요청이 처리한 것이다. */
    public boolean checkIn(long ticketId,LocalDateTime now){
        return jdbc.update("UPDATE admission_tickets SET status='CHECKED_IN',checked_in_at=? WHERE id=? AND status='ISSUED'",now,ticketId)==1;
    }
}
