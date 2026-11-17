package com.bts.demoticketing.ticket;

import java.time.Duration;
import java.util.Base64;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;

/** 동적 QR·검표 기능 설정. 비활성 상태에서는 키 없이 기동되며 관련 API는 503이다. */
@Component
public class CheckInSettings {
    public final boolean enabled;
    public final Duration opensBefore,challengeTtl;
    public final int maxDeviceChanges;
    private final byte[] secretKey;
    private final String gateKey;
    public CheckInSettings(@Value("${demo.checkin.enabled:false}") boolean enabled,
            @Value("${demo.checkin.secret-key:}") String secretKey,
            @Value("${demo.checkin.gate-key:}") String gateKey,
            @Value("${demo.checkin.opens-before:PT2H}") Duration opensBefore,
            @Value("${demo.checkin.challenge-ttl:PT2M}") Duration challengeTtl,
            @Value("${demo.checkin.max-device-changes:3}") int maxDeviceChanges) {
        this.enabled=enabled;this.opensBefore=opensBefore;this.challengeTtl=challengeTtl;
        this.maxDeviceChanges=maxDeviceChanges;this.gateKey=gateKey;
        byte[] key=null;
        if(enabled){
            // 설정 값 자체는 예외 메시지에 넣지 않는다.
            try{key=Base64.getDecoder().decode(secretKey.trim());}
            catch(IllegalArgumentException e){throw new IllegalArgumentException("TICKET_SECRET_KEY must be Base64");}
            if(key.length!=32)throw new IllegalArgumentException("TICKET_SECRET_KEY must decode to 32 bytes");
            if(gateKey.length()<16||gateKey.length()>200||!gateKey.matches("[\\x21-\\x7E]+"))
                throw new IllegalArgumentException("GATE_API_KEY must be 16-200 printable ASCII characters");
            if(opensBefore.isNegative()||challengeTtl.isNegative()||challengeTtl.isZero()||maxDeviceChanges<0)
                throw new IllegalArgumentException("Invalid check-in settings");
        }
        this.secretKey=key;
    }
    public void requireEnabled(){if(!enabled)throw new ApiException(ResponseCode.SERVICE_UNAVAILABLE);}
    byte[] secretKey(){return secretKey;}
    String gateKey(){return gateKey;}
}
