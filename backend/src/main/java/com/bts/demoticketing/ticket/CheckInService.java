package com.bts.demoticketing.ticket;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.regex.Pattern;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import tools.jackson.databind.json.JsonMapper;
import com.bts.demoticketing.booking.service.ReservationTransactions;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;
import com.bts.demoticketing.outbox.OutboxRepository;
import com.bts.demoticketing.ticket.TicketRepository.*;
import com.bts.demoticketing.user.repository.DemoUserRepository;

/**
 * 검표: QR의 기기 서명·TOTP·티켓 상태·입장 시간을 검증하고 최초 1회만 CHECKED_IN으로 바꾼다.
 * 상태 변경과 CHECK_IN Outbox 저장은 같은 트랜잭션이다. QR 원문은 로그에 남기지 않는다.
 */
@Service
public class CheckInService {
    private static final Logger log=LoggerFactory.getLogger(CheckInService.class);
    private static final String UUID_RE="[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
    // BTS1.<ticketId>.<deviceId>.<epochSeconds>.<totp>.<signature>
    private static final Pattern QR=Pattern.compile("BTS1\\.("+UUID_RE+")\\.("+UUID_RE+")\\.(\\d{1,12})\\.(\\d{6})\\.([A-Za-z0-9_-]{86})");
    private final TicketRepository tickets;
    private final OutboxRepository outbox;
    private final DemoUserRepository users;
    private final ReservationTransactions transactions;
    private final CheckInSettings settings;
    private final JsonMapper json;
    private final Clock clock;
    public CheckInService(TicketRepository tickets,OutboxRepository outbox,DemoUserRepository users,
            ReservationTransactions transactions,CheckInSettings settings,JsonMapper json,Clock clock){
        this.tickets=tickets;this.outbox=outbox;this.users=users;this.transactions=transactions;
        this.settings=settings;this.json=json;this.clock=clock;
    }
    public record Result(String ticketId,String concertTitle,String seatId,OffsetDateTime checkedInAt){}
    private static ApiException fail(ResponseCode code){return new ApiException(code);}

    public Result checkIn(String qr){
        settings.requireEnabled();
        var parsed=QR.matcher(qr==null?"":qr.trim());
        if(!parsed.matches())throw fail(ResponseCode.QR_INVALID);
        String ticketId=parsed.group(1);
        try{
            Result result=transactions.run(()->verify(ticketId,parsed.group(2),Long.parseLong(parsed.group(3)),parsed.group(4),
                    Base64.getUrlDecoder().decode(parsed.group(5)),qr.trim().substring(0,qr.trim().lastIndexOf('.'))));
            log.info("검표 성공: ticket={}",ticketId);
            return result;
        }catch(ApiException e){
            log.warn("검표 거부: ticket={} code={}",ticketId,e.getResponseCode().getCode());
            throw e;
        }
    }

    private Result verify(String ticketId,String deviceId,long timestamp,String code,byte[] signature,String signed){
        Ticket found=tickets.ticket(ticketId).orElseThrow(()->fail(ResponseCode.TICKET_NOT_FOUND));
        tickets.lockBooking(found.bookingId());
        // 잠금 이후의 최신 상태로 판단한다(동시 취소·기기 변경·다른 검표기).
        Ticket ticket=tickets.ticket(ticketId).orElseThrow();
        Binding binding=tickets.activeBinding(ticket.id()).filter(b->b.publicId().equals(deviceId))
                .orElseThrow(()->fail(ResponseCode.QR_REJECTED));
        if(!DeviceSignature.verify(binding.publicKey(),signed,signature))throw fail(ResponseCode.QR_REJECTED);
        Instant instant=clock.instant();
        long counter=Totp.counter(timestamp);
        if(Math.abs(counter-Totp.counter(instant.getEpochSecond()))>1)throw fail(ResponseCode.QR_EXPIRED);
        byte[] secret=SecretCipher.decrypt(settings.secretKey(),binding.secret(),TicketDeviceService.context(ticket.publicId(),deviceId));
        if(!MessageDigest.isEqual(Totp.code(secret,counter).getBytes(StandardCharsets.US_ASCII),code.getBytes(StandardCharsets.US_ASCII)))
            throw fail(ResponseCode.QR_REJECTED);
        if(ticket.status().equals("CHECKED_IN"))throw fail(ResponseCode.TICKET_ALREADY_CHECKED_IN);
        if(!ticket.status().equals("ISSUED")||!ticket.bookingStatus().equals("CONFIRMED"))throw fail(ResponseCode.TICKET_NOT_ADMITTABLE);
        LocalDateTime now=LocalDateTime.ofInstant(instant,ZoneOffset.UTC).truncatedTo(ChronoUnit.MICROS);
        if(now.isBefore(ticket.startAt().minus(settings.opensBefore))||!now.isBefore(ticket.endAt()))throw fail(ResponseCode.CHECKIN_NOT_OPEN);
        if(!tickets.checkIn(ticket.id(),now))throw fail(ResponseCode.TICKET_ALREADY_CHECKED_IN);
        Map<String,Object> metadata=new LinkedHashMap<>();
        metadata.put("ticketId",ticket.publicId());metadata.put("concertId",ticket.concertId());
        metadata.put("performanceStartsAt",ticket.startAt().toInstant(ZoneOffset.UTC).truncatedTo(ChronoUnit.SECONDS).toString());
        metadata.put("performanceEndsAt",ticket.endAt().toInstant(ZoneOffset.UTC).truncatedTo(ChronoUnit.SECONDS).toString());
        metadata.put("deviceChanged",binding.generation()>1);
        var owner=users.find(ticket.userId()).orElseThrow();
        outbox.appendCheckIn(owner.id(),owner.serviceId(),ticket.bookingPublicId(),ticket.publicId(),
                now.truncatedTo(ChronoUnit.SECONDS),json.writeValueAsString(metadata),now);
        return new Result(ticket.publicId(),ticket.title(),ticket.seatCode(),now.atOffset(ZoneOffset.UTC));
    }
}
