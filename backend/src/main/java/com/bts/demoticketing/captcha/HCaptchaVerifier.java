package com.bts.demoticketing.captcha;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Duration;
import java.util.HexFormat;
import java.util.regex.Pattern;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;

/**
 * hCaptcha 서버 검증.
 * 문제는 화면의 hCaptcha 위젯이 내고, 서버는 위젯이 만든 토큰을 hCaptcha 서버에 보내 통과 여부만 확인한다.
 * 시도 횟수·만료·재사용 방지는 기존 Redis 흐름(captcha.lua)이 그대로 맡는다.
 */
public final class HCaptchaVerifier implements CaptchaVerifier {
    private static final Pattern SUCCESS=Pattern.compile("\"success\"\\s*:\\s*true");
    private final String siteKey,secret;
    private final URI verifyUrl;
    private final HttpClient http=HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3)).build();

    public HCaptchaVerifier(String siteKey,String secret,String verifyUrl){
        if(siteKey==null||siteKey.isBlank()||secret==null||secret.isBlank())
            throw new IllegalArgumentException("HCAPTCHA_SITE_KEY and HCAPTCHA_SECRET are required when CAPTCHA_MODE=hcaptcha");
        this.siteKey=siteKey.trim();this.secret=secret.trim();this.verifyUrl=URI.create(verifyUrl.trim());
    }
    @Override public String provider(){return "hcaptcha";}
    @Override public String siteKey(){return siteKey;}
    @Override public Problem create(){
        // 서버가 낼 문제는 없다. 정답 자리에는 추측할 수 없는 값을 넣어 두고, 실제 통과 여부는 verify()가 정한다.
        byte[] bytes=new byte[32];new SecureRandom().nextBytes(bytes);
        return new Problem("hcaptcha",HexFormat.of().formatHex(bytes));
    }
    @Override public boolean verify(String expectedDigest,String answer){
        if(answer==null||answer.isBlank())return false;
        String form=encode("secret",secret)+"&"+encode("response",answer)+"&"+encode("sitekey",siteKey);
        try{
            var request=HttpRequest.newBuilder(verifyUrl).timeout(Duration.ofSeconds(5))
                    .header("Content-Type","application/x-www-form-urlencoded").POST(HttpRequest.BodyPublishers.ofString(form)).build();
            var response=http.send(request,HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            // 설정 오류나 hCaptcha 장애를 "사용자가 틀림"으로 오해하지 않도록 서비스 불가로 알린다.
            if(response.statusCode()/100!=2)throw new ApiException(ResponseCode.SERVICE_UNAVAILABLE);
            return SUCCESS.matcher(response.body()).find();
        }catch(IOException e){throw new ApiException(ResponseCode.SERVICE_UNAVAILABLE);}
        catch(InterruptedException e){Thread.currentThread().interrupt();throw new ApiException(ResponseCode.SERVICE_UNAVAILABLE);}
    }
    private static String encode(String key,String value){return key+"="+URLEncoder.encode(value,StandardCharsets.UTF_8);}
}
