package com.bts.demoticketing.captcha;

import java.nio.charset.StandardCharsets;
import java.security.*;
import java.time.*;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.core.io.ClassPathResource;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.script.RedisScript;
import org.springframework.dao.DataAccessException;
import jakarta.validation.constraints.*;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;
import com.bts.demoticketing.queue.QueueStore;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient;

@Service
public class CaptchaService {
    public record Verification(@NotBlank @Pattern(regexp="[a-f0-9]{64}") String challengeId,
            @NotBlank @Size(max=8192) String answer) {}
    public record Challenge(String challengeId,String question,Instant expiresAt,String provider,String siteKey) {}
    public record Grant(String captchaToken,Instant expiresAt) {}
    private final StringRedisTemplate redis;
    private final QueueStore queues;
    private final CaptchaVerifier verifier;
    private final long challengeTtl,grantTtl;
    private final int attempts;
    private final RedisScript<?> script=RedisScript.of(new ClassPathResource("captcha.lua"),List.class);
    public CaptchaService(StringRedisTemplate redis,QueueStore queues,org.springframework.beans.factory.ObjectProvider<CaptchaVerifier> providers,
            @Value("${demo.captcha.mode:disabled}") String mode,
            @Value("${demo.captcha.challenge-ttl:PT2M}") Duration challengeTtl,
            @Value("${demo.captcha.grant-ttl:PT2M}") Duration grantTtl,
            @Value("${demo.captcha.max-attempts:5}") int attempts){
        if(!Set.of("disabled","mock","hcaptcha").contains(mode)||challengeTtl.toMillis()<1||grantTtl.toMillis()<1||attempts<1)
            throw new IllegalArgumentException("Invalid CAPTCHA configuration; mode must be disabled, mock or hcaptcha");
        this.redis=redis;this.queues=queues;this.verifier=providers.getIfAvailable();
        this.challengeTtl=challengeTtl.toMillis();this.grantTtl=grantTtl.toMillis();this.attempts=attempts;
    }
    public static String digest(String value){
        try{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));}
        catch(NoSuchAlgorithmException e){throw new IllegalStateException(e);}
    }
    private static String nonce(){byte[] bytes=new byte[32];new SecureRandom().nextBytes(bytes);return HexFormat.of().formatHex(bytes);}
    private void enabled(){if(verifier==null)throw new ApiException(ResponseCode.SERVICE_UNAVAILABLE);}
    private List<?> call(List<String> keys,String... args){
        try{var result=redis.execute(script,keys,(Object[])args);if(!(result instanceof List<?> values))throw new IllegalStateException("Invalid CAPTCHA response");return values;}
        catch(DataAccessException e){throw new ApiException(ResponseCode.SERVICE_UNAVAILABLE);}
    }
    public Challenge challenge(String concert,long user,PolicyDecisionClient.Action action){
        return challenge(concert,user,action,null);
    }
    /** decisionId: 이 CAPTCHA를 요구한 BTS 정책 결정 (#67). challenge에 함께 저장해 검증 결과 기록까지 유지한다. */
    public Challenge challenge(String concert,long user,PolicyDecisionClient.Action action,Long decisionId){
        enabled();String id=nonce();var problem=verifier.create();
        var result=call(List.of(queues.base(concert)+"captcha-challenge:"+id),"create",Long.toString(user),action.name(),
                digest(problem.answer()),Long.toString(challengeTtl),Integer.toString(attempts),decisionId==null?"":decisionId.toString());
        return new Challenge(id,problem.question(),Instant.ofEpochMilli(Long.parseLong(result.get(0).toString())),verifier.provider(),verifier.siteKey());
    }
    /**
     * 검증 결과 (#67). grant가 null이면 CAPTCHA_INVALID다.
     * decisionId는 이 요청이 REQUIRE_CAPTCHA challenge의 답을 실제로 판정받았을 때만(통과 또는 오답) 그 challenge를 발급한 정책 결정이다.
     * 판정과 같은 Lua 실행에서 정해지므로, 다른 사용자의 challenge·만료·이미 소비된 challenge(동시 중복 제출 포함)·재전송 응답·
     * DELAY의 CAPTCHA(현재 BTS 계약에 기록할 결과가 없다)는 null이다.
     */
    public record Outcome(Grant grant,Long decisionId){}
    public Grant verify(String concert,long user,Verification body){
        return verify(concert,user,body,null);
    }
    public Grant verify(String concert,long user,Verification body,String transition){
        var outcome=attempt(concert,user,body,transition);
        if(outcome.grant()==null)throw new ApiException(ResponseCode.CAPTCHA_INVALID);
        return outcome.grant();
    }
    public Outcome attempt(String concert,long user,Verification body,String transition){
        enabled();String token=nonce();String key=queues.base(concert)+"captcha-challenge:"+body.challengeId();
        // The provider comparison is separate; attempts, expiry and single successful
        // verification are checked again atomically in Lua against the expected digest.
        String expected;
        try{expected=(String)redis.opsForHash().get(key,"answer");}
        catch(DataAccessException e){throw new ApiException(ResponseCode.SERVICE_UNAVAILABLE);}
        boolean valid=expected!=null&&verifier.verify(expected,body.answer());
        String replay=queues.base(concert)+"captcha-replay:"+user+":"+(transition==null?nonce():transition);
        var result=call(List.of(key,queues.base(concert)+"captcha-grant:"+digest(token),replay),"verify",Long.toString(user),
                valid?expected:"invalid",Long.toString(grantTtl),digest(body.challengeId()+":"+body.answer()),token);
        if(result.get(0).toString().equals("CONFLICT"))throw new ApiException(ResponseCode.DATA_CONFLICT);
        Long decision=null;
        if(result.size()>3){
            try{long id=Long.parseLong(result.get(3).toString());if(id>0)decision=id;}catch(NumberFormatException ignored){/* no BTS decision */}
        }
        if(!result.get(0).toString().equals("OK"))return new Outcome(null,decision);
        return new Outcome(new Grant(result.size()>2?result.get(2).toString():token,Instant.ofEpochMilli(Long.parseLong(result.get(1).toString()))),decision);
    }
}
