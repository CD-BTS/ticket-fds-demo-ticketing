package com.bts.demoticketing.ticket;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Collections;
import java.util.List;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.stereotype.Component;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;

/** 검표 담당자 인증. Demo 사용자 세션과 별개인 서버 설정 키(X-Gate-Key)를 상수 시간으로 비교한다. */
@Component
public class GateAuth {
    private final CheckInSettings settings;
    public GateAuth(CheckInSettings settings){this.settings=settings;}
    public void require(HttpServletRequest request){
        settings.requireEnabled();
        List<String> headers=Collections.list(request.getHeaders("X-Gate-Key"));
        if(headers.size()!=1||!MessageDigest.isEqual(digest(headers.get(0)),digest(settings.gateKey())))
            throw new ApiException(ResponseCode.UNAUTHORIZED);
    }
    private static byte[] digest(String value){
        try{return MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));}
        catch(NoSuchAlgorithmException e){throw new IllegalStateException(e);}
    }
}
