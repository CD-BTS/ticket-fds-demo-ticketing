package com.bts.demoticketing.ticket;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
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
import com.bts.demoticketing.outbox.EventTimes;
import com.bts.demoticketing.outbox.OutboxRepository;
import com.bts.demoticketing.ticket.TicketRepository.*;
import com.bts.demoticketing.user.entity.DemoUser;
import com.bts.demoticketing.user.repository.DemoUserRepository;

/**
 * 2단계 검표.
 * 1) scan: 검표기가 보낸 QR의 기기 서명·TOTP·티켓 상태·입장 시간을 검증하고 일회성 챌린지만 발급한다. 입장 처리는 하지 않는다.
 * 2) confirm: 등록 기기가 그 챌린지에 개인키로 서명해 제출하면 등록된 공개키로 검증한 뒤 최초 1회만 CHECKED_IN으로 바꾼다.
 * QR 속 서명은 "과거에 등록 기기가 만들었다"는 것만 증명하므로, 캡처본만 가진 사람은 2)를 수행할 수 없어 입장하지 못한다.
 * 상태 변경과 CHECK_IN Outbox 저장은 같은 트랜잭션이다. QR 원문·챌린지·서명은 로그에 남기지 않는다.
 */
@Service
public class CheckInService {
    private static final Logger log=LoggerFactory.getLogger(CheckInService.class);
    private static final SecureRandom RANDOM=new SecureRandom();
    private static final Base64.Encoder B64=Base64.getUrlEncoder().withoutPadding();
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
    /** 검표기가 보는 검표 요청. status는 PENDING/COMPLETED/REJECTED/SUPERSEDED/EXPIRED다. checkedInAt은 COMPLETED일 때만 있다. */
    public record Scan(String checkInId,String status,String ticketId,String concertTitle,String seatId,
            OffsetDateTime expiresAt,OffsetDateTime checkedInAt){}
    /** 등록 기기가 서명할 챌린지. */
    public record DeviceChallenge(String checkInId,String deviceId,String challenge,OffsetDateTime expiresAt){}
    /** 실패도 commit해야 하는 경우(챌린지 소비)가 있어 트랜잭션은 예외 대신 결과를 돌려준다. */
    private record Outcome(Result result,ResponseCode failure){}

    private static ApiException fail(ResponseCode code){return new ApiException(code);}
    private static OffsetDateTime utc(LocalDateTime time){return time==null?null:time.atOffset(ZoneOffset.UTC);}
    private LocalDateTime now(){return LocalDateTime.ofInstant(clock.instant(),ZoneOffset.UTC).truncatedTo(ChronoUnit.MICROS);}
    /** 등록 기기가 서명하는 문자열. 목적·티켓·기기·검표 요청·일회성 챌린지를 모두 묶는다. */
    static String proofMessage(String ticketId,String deviceId,String checkInId,String challenge){
        return "BTS-CHECKIN."+ticketId+"."+deviceId+"."+checkInId+"."+challenge;
    }

    /** 1단계(검표기): QR을 검증하고 등록 기기용 챌린지를 발급한다. 같은 티켓의 이전 미완료 챌린지는 무효가 된다. */
    public Scan scan(String qr){
        settings.requireEnabled();
        String text=qr==null?"":qr.trim();
        var parsed=QR.matcher(text);
        if(!parsed.matches())throw fail(ResponseCode.QR_INVALID);
        String ticketId=parsed.group(1);
        try{
            Scan scan=transactions.run(()->issue(ticketId,parsed.group(2),Long.parseLong(parsed.group(3)),parsed.group(4),
                    Base64.getUrlDecoder().decode(parsed.group(5)),text.substring(0,text.lastIndexOf('.'))));
            log.info("검표 챌린지 발급: ticket={} checkIn={}",ticketId,scan.checkInId());
            return scan;
        }catch(ApiException e){
            log.warn("검표 거부: ticket={} code={}",ticketId,e.getResponseCode().getCode());
            throw e;
        }
    }

    private Scan issue(String ticketId,String deviceId,long timestamp,String code,byte[] signature,String signed){
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
        LocalDateTime now=LocalDateTime.ofInstant(instant,ZoneOffset.UTC).truncatedTo(ChronoUnit.MICROS);
        ResponseCode blocked=admittable(ticket,now);
        if(blocked!=null)throw fail(blocked);
        byte[] nonce=new byte[32];RANDOM.nextBytes(nonce);
        String id=UUID.randomUUID().toString();
        LocalDateTime expiry=now.plus(settings.gateChallengeTtl);
        tickets.createGateChallenge(id,ticket.id(),binding.id(),B64.encodeToString(nonce),now,expiry);
        return new Scan(id,"PENDING",ticket.publicId(),ticket.title(),ticket.seatCode(),utc(expiry),null);
    }

    /** 티켓 상태와 입장 시간. 스캔 시점과 확정 시점에 모두 확인한다. */
    private ResponseCode admittable(Ticket ticket,LocalDateTime now){
        if(ticket.status().equals("CHECKED_IN"))return ResponseCode.TICKET_ALREADY_CHECKED_IN;
        if(!ticket.status().equals("ISSUED")||!ticket.bookingStatus().equals("CONFIRMED"))return ResponseCode.TICKET_NOT_ADMITTABLE;
        if(now.isBefore(ticket.startAt().minus(settings.opensBefore))||!now.isBefore(ticket.endAt()))return ResponseCode.CHECKIN_NOT_OPEN;
        return null;
    }

    /** 검표기 결과 조회. 만료된 PENDING은 EXPIRED로 보인다. */
    public Scan status(String checkInId){
        settings.requireEnabled();
        return transactions.run(()->{
            GateChallenge challenge=tickets.gateChallenge(checkInId).orElseThrow(()->fail(ResponseCode.CHECKIN_NOT_FOUND));
            Ticket ticket=tickets.ticket(challenge.ticketId()).orElseThrow();
            boolean done=challenge.status().equals("COMPLETED");
            String status=challenge.status().equals("PENDING")&&!challenge.expiresAt().isAfter(now())?"EXPIRED":challenge.status();
            return new Scan(challenge.publicId(),status,ticket.publicId(),ticket.title(),ticket.seatCode(),
                    utc(challenge.expiresAt()),done?utc(ticket.checkedInAt()):null);
        });
    }

    /** 등록 기기(티켓 소유자 세션)가 서명할 대기 중 챌린지. 없으면 null이다. */
    public DeviceChallenge pending(String ticketId,DemoUser user){
        settings.requireEnabled();
        return transactions.run(()->{
            Ticket ticket=owned(ticketId,user);
            var active=tickets.activeBinding(ticket.id());
            if(active.isEmpty())return null;
            return tickets.pendingGateChallenge(ticket.id(),now()).filter(c->c.bindingId()==active.get().id())
                    .map(c->new DeviceChallenge(c.publicId(),active.get().publicId(),c.challenge(),utc(c.expiresAt()))).orElse(null);
        });
    }

    /** 2단계(등록 기기): 챌린지 서명을 검증하고 입장을 확정한다. 챌린지는 성공·실패와 무관하게 한 번만 쓸 수 있다. */
    public Result confirm(String ticketId,DemoUser user,String checkInId,String proof){
        settings.requireEnabled();
        byte[] signature;
        try{signature=Base64.getUrlDecoder().decode(proof);}catch(IllegalArgumentException e){signature=null;}
        byte[] decoded=signature;
        Outcome outcome=transactions.run(()->verify(ticketId,user,checkInId,decoded));
        if(outcome.failure()!=null){
            log.warn("검표 확정 거부: ticket={} checkIn={} code={}",ticketId,checkInId,outcome.failure().getCode());
            throw fail(outcome.failure());
        }
        log.info("검표 성공: ticket={} checkIn={}",ticketId,checkInId);
        return outcome.result();
    }

    private Outcome verify(String ticketId,DemoUser user,String checkInId,byte[] signature){
        Ticket found=owned(ticketId,user);
        tickets.lockBooking(found.bookingId());
        Ticket ticket=tickets.ticket(ticketId).orElseThrow();
        if(ticket.status().equals("CHECKED_IN"))return new Outcome(null,ResponseCode.TICKET_ALREADY_CHECKED_IN);
        LocalDateTime now=now();
        // 다른 티켓용·이미 소비·대체·만료된 챌린지는 상태를 바꾸지 않고 거부한다.
        GateChallenge challenge=tickets.gateChallenge(checkInId)
                .filter(c->c.ticketId()==ticket.id()&&c.status().equals("PENDING")&&c.expiresAt().isAfter(now)).orElse(null);
        if(challenge==null)return new Outcome(null,ResponseCode.CHECKIN_PROOF_INVALID);
        // 여기서부터의 실패는 챌린지를 소비한다(REJECTED). 다시 검표하려면 QR을 새로 스캔해야 한다.
        Binding binding=tickets.activeBinding(ticket.id()).filter(b->b.id()==challenge.bindingId()).orElse(null);
        ResponseCode failure=binding==null||signature==null||!DeviceSignature.verify(binding.publicKey(),
                proofMessage(ticket.publicId(),binding.publicId(),challenge.publicId(),challenge.challenge()),signature)
                ?ResponseCode.CHECKIN_PROOF_INVALID:admittable(ticket,now);
        if(!tickets.resolveGateChallenge(challenge.id(),failure==null?"COMPLETED":"REJECTED",now))throw new ReservationTransactions.Retry();
        if(failure!=null)return new Outcome(null,failure);
        if(!tickets.checkIn(ticket.id(),now))throw new IllegalStateException("Ticket check-in invariant violated");
        Map<String,Object> metadata=new LinkedHashMap<>();
        metadata.put("ticketId",ticket.publicId());metadata.put("concertId",ticket.concertId());
        metadata.put("performanceStartsAt",ticket.startAt().toInstant(ZoneOffset.UTC).truncatedTo(ChronoUnit.SECONDS).toString());
        metadata.put("performanceEndsAt",ticket.endAt().toInstant(ZoneOffset.UTC).truncatedTo(ChronoUnit.SECONDS).toString());
        metadata.put("deviceChanged",binding.generation()>1);
        var owner=users.find(ticket.userId()).orElseThrow();
        outbox.appendCheckIn(owner.id(),owner.serviceId(),ticket.bookingPublicId(),ticket.publicId(),
                EventTimes.occurredAt(now),json.writeValueAsString(metadata),now);
        return new Outcome(new Result(ticket.publicId(),ticket.title(),ticket.seatCode(),now.atOffset(ZoneOffset.UTC)),null);
    }

    private Ticket owned(String ticketId,DemoUser user){
        Ticket ticket=tickets.ticket(ticketId).orElseThrow(()->fail(ResponseCode.TICKET_NOT_FOUND));
        if(ticket.userId()!=user.id())throw fail(ResponseCode.FORBIDDEN);
        return ticket;
    }
}
