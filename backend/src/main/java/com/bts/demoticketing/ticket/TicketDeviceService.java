package com.bts.demoticketing.ticket;

import java.security.SecureRandom;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import com.bts.demoticketing.booking.repository.ReservationRepository;
import com.bts.demoticketing.booking.service.ReservationTransactions;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;
import com.bts.demoticketing.ticket.TicketRepository.*;
import com.bts.demoticketing.user.entity.DemoUser;

/** 티켓 소유자의 기기 등록(최초)과 기기 변경. 비밀키·서명·챌린지 값은 로그에 남기지 않는다. */
@Service
public class TicketDeviceService {
    private static final Logger log=LoggerFactory.getLogger(TicketDeviceService.class);
    private static final SecureRandom RANDOM=new SecureRandom();
    private static final Base64.Encoder B64=Base64.getUrlEncoder().withoutPadding();
    private final TicketRepository tickets;
    private final ReservationRepository reservations;
    private final ReservationTransactions transactions;
    private final CheckInSettings settings;
    private final Clock clock;
    public TicketDeviceService(TicketRepository tickets,ReservationRepository reservations,ReservationTransactions transactions,
            CheckInSettings settings,Clock clock){
        this.tickets=tickets;this.reservations=reservations;this.transactions=transactions;this.settings=settings;this.clock=clock;
    }

    public record DeviceView(String deviceId,OffsetDateTime registeredAt,int changesRemaining){}
    public record TicketView(String ticketId,String seatId,String status,OffsetDateTime checkedInAt,DeviceView device){}
    public record ChallengeView(String challengeId,String challenge,OffsetDateTime expiresAt){}
    public record TotpView(String secret,String algorithm,int digits,int period){}
    public record Enrollment(String ticketId,String deviceId,TotpView totp,OffsetDateTime registeredAt,
            OffsetDateTime serverTime,int changesRemaining){}

    private LocalDateTime now(){return LocalDateTime.ofInstant(clock.instant(),ZoneOffset.UTC).truncatedTo(ChronoUnit.MICROS);}
    private static ApiException fail(ResponseCode code){return new ApiException(code);}
    private static OffsetDateTime utc(LocalDateTime time){return time==null?null:time.atOffset(ZoneOffset.UTC);}
    private int remaining(int generation){return Math.max(0,settings.maxDeviceChanges-(generation-1));}
    static String context(String ticketId,String deviceId){return ticketId+":"+deviceId;}
    /** 클라이언트가 서명하는 문자열. 목적·티켓·일회성 챌린지·공개키를 모두 묶는다. */
    static String proofMessage(boolean change,String ticketId,String challenge,String publicKey){
        return (change?"BTS-DEVICE-CHANGE":"BTS-DEVICE-REGISTER")+"."+ticketId+"."+challenge+"."+publicKey;
    }

    public List<TicketView> tickets(String bookingId,DemoUser user){
        settings.requireEnabled();
        return transactions.run(()->{
            var booking=reservations.booking(bookingId).orElseThrow(()->fail(ResponseCode.BOOKING_NOT_FOUND));
            if(booking.userId()!=user.id())throw fail(ResponseCode.FORBIDDEN);
            return tickets.bookingTickets(booking.id()).stream().map(t->new TicketView(t.publicId(),t.seatCode(),t.status(),
                    utc(t.checkedInAt()),tickets.activeBinding(t.id())
                            .map(b->new DeviceView(b.publicId(),utc(b.createdAt()),remaining(b.generation()))).orElse(null))).toList();
        });
    }

    public ChallengeView challenge(String ticketId,DemoUser user){
        settings.requireEnabled();
        return transactions.run(()->{
            Ticket ticket=owned(ticketId,user);
            tickets.lockBooking(ticket.bookingId());
            usable(tickets.ticket(ticketId).orElseThrow());
            byte[] nonce=new byte[32];RANDOM.nextBytes(nonce);
            String id=UUID.randomUUID().toString(),value=B64.encodeToString(nonce);
            LocalDateTime expiry=now().plus(settings.challengeTtl);
            tickets.replaceChallenge(id,ticket.id(),user.id(),value,expiry);
            return new ChallengeView(id,value,utc(expiry));
        });
    }

    /** change=false는 최초 등록(활성 기기가 없어야 함), true는 기기 변경(활성 기기를 폐기하고 횟수를 차감)이다. */
    public Enrollment enroll(String ticketId,DemoUser user,String challengeId,String publicKey,String proof,boolean change){
        settings.requireEnabled();
        byte[] spki=decode(publicKey);
        if(!DeviceSignature.validKey(spki))throw fail(ResponseCode.DEVICE_KEY_INVALID);
        byte[] signature=decode(proof);
        Enrollment result=transactions.run(()->{
            Ticket found=owned(ticketId,user);
            tickets.lockBooking(found.bookingId());
            Ticket ticket=tickets.ticket(ticketId).orElseThrow();
            usable(ticket);
            LocalDateTime now=now();
            Challenge challenge=tickets.challenge(challengeId)
                    .filter(c->c.ticketId()==ticket.id()&&c.userId()==user.id()&&c.expiresAt().isAfter(now))
                    .orElseThrow(()->fail(ResponseCode.DEVICE_PROOF_INVALID));
            // 정규화한 공개키 문자열로 검증해 패딩 등 표기 차이로 같은 증명이 재사용되지 않게 한다.
            if(signature==null||!DeviceSignature.verify(spki,proofMessage(change,ticket.publicId(),challenge.challenge(),B64.encodeToString(spki)),signature))
                throw fail(ResponseCode.DEVICE_PROOF_INVALID);
            if(!tickets.consumeChallenge(challenge.id()))throw new ReservationTransactions.Retry();
            var active=tickets.activeBinding(ticket.id());
            if(!change&&active.isPresent())throw fail(ResponseCode.DEVICE_ALREADY_REGISTERED);
            if(change&&active.isEmpty())throw fail(ResponseCode.DEVICE_NOT_REGISTERED);
            int generation=1;
            if(active.isPresent()){
                if(remaining(active.get().generation())<=0)throw fail(ResponseCode.DEVICE_CHANGE_LIMIT);
                // 폐기와 동시에 저장된 TOTP 비밀키도 지워진다. 이전 기기의 QR은 즉시 거부된다.
                tickets.revoke(active.get().id(),now);
                generation=active.get().generation()+1;
            }
            String deviceId=UUID.randomUUID().toString();
            byte[] secret=new byte[Totp.SECRET_BYTES];RANDOM.nextBytes(secret);
            tickets.createBinding(deviceId,ticket.id(),user.id(),generation,spki,
                    SecretCipher.encrypt(settings.secretKey(),secret,context(ticket.publicId(),deviceId)),now);
            return new Enrollment(ticket.publicId(),deviceId,new TotpView(B64.encodeToString(secret),"SHA1",Totp.DIGITS,Totp.PERIOD_SECONDS),
                    utc(now),utc(now),remaining(generation));
        });
        log.info("티켓 기기 {}: ticket={} device={}",change?"변경":"등록",result.ticketId(),result.deviceId());
        return result;
    }

    private Ticket owned(String ticketId,DemoUser user){
        Ticket ticket=tickets.ticket(ticketId).orElseThrow(()->fail(ResponseCode.TICKET_NOT_FOUND));
        if(ticket.userId()!=user.id())throw fail(ResponseCode.FORBIDDEN);
        return ticket;
    }
    private static void usable(Ticket ticket){
        if(!ticket.status().equals("ISSUED")||!ticket.bookingStatus().equals("CONFIRMED"))throw fail(ResponseCode.TICKET_NOT_ADMITTABLE);
    }
    private static byte[] decode(String value){
        try{return Base64.getUrlDecoder().decode(value);}catch(IllegalArgumentException e){return null;}
    }
}
