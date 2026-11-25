package com.bts.demoticketing.integration.bts;

import java.io.IOException;
import java.math.BigInteger;
import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;
import java.net.http.*;
import java.time.Duration;
import java.util.*;
import org.springframework.stereotype.Component;
import tools.jackson.databind.json.JsonMapper;
import com.bts.demoticketing.user.entity.DemoUser;

@Component
public class BtsClient {
    private final BtsSettings settings;
    private final JsonMapper json;
    private final HttpClient http=HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2))
            .followRedirects(HttpClient.Redirect.NEVER).build();
    public BtsClient(BtsSettings settings,JsonMapper json){this.settings=settings;this.json=json;}
    public static class DeliveryFailure extends RuntimeException {
        public final boolean retryable;
        public final String code;
        public DeliveryFailure(String code,boolean retryable){super("BTS delivery failed: "+code);this.code=code;this.retryable=retryable;}
    }
    public String register(DemoUser user){
        if(!settings.serviceId.equals(user.serviceId()))throw new DeliveryFailure("SERVICE_MAPPING_MISMATCH",false);
        Map<?,?> data=post("/api/v1/users",json.writeValueAsString(Map.of(
                "serviceId",user.serviceId(),"externalUserId",user.externalId(),"accountStatus","ACTIVE")));
        String id=String.valueOf(data.get("userId"));
        try{UUID.fromString(id);}catch(IllegalArgumentException e){throw new DeliveryFailure("INVALID_BTS_RESPONSE",false);}
        if(!user.serviceId().equals(data.get("serviceId"))||!user.externalId().equals(data.get("externalUserId")))
            throw new DeliveryFailure("INVALID_BTS_RESPONSE",false);
        return id;
    }
    public long send(String payload){
        Map<?,?> data=post("/api/v1/events",payload);
        Map<?,?> sent=json.readValue(payload,Map.class);
        for(String key:List.of("serviceId","externalEventId","userId","eventType","bookingId","ticketId")){
            if(!Objects.equals(sent.get(key),data.get(key)))throw new DeliveryFailure("INVALID_BTS_RESPONSE",false);
        }
        try {
            long id=new BigInteger(String.valueOf(data.get("eventId"))).longValueExact();
            if(id<=0)throw new ArithmeticException();
            return id;
        }catch(RuntimeException e){throw new DeliveryFailure("INVALID_BTS_RESPONSE",false);}
    }
    public PolicyDecisionClient.Action policy(String uuid){return policy(uuid,"QUEUE_JOIN");}
    /** context: QUEUE_JOIN(대기열 입장) 또는 BOOKING_ATTEMPT(좌석 선점). BTS는 결정과 문맥을 policy_decision에 기록한다. */
    public PolicyDecisionClient.Action policy(String uuid,String context){return decision(uuid,context,null).action();}
    /**
     * 정책 결정 요청 (#67). concertId가 있으면 요청에 실어 BTS가 policy_decision.concert_id에 기록하게 한다.
     * 응답의 decisionId는 실제 정책 적용 기록에 필요하다. 응답에 없으면 null이고 적용 기록을 만들지 않는다.
     */
    public PolicyDecisionClient.Decision decision(String uuid,String context,String concertId){
        if(!List.of("QUEUE_JOIN","BOOKING_ATTEMPT").contains(context))throw new IllegalArgumentException("Unknown policy context");
        try{UUID.fromString(uuid);}catch(RuntimeException e){throw new DeliveryFailure("INVALID_BTS_USER",false);}
        Map<String,Object> request=new LinkedHashMap<>();
        request.put("context",context);
        if(concertId!=null)request.put("concertId",concertId);
        Map<?,?> data=post("/api/v1/users/"+uuid+"/policy-decisions",json.writeValueAsString(request));
        PolicyDecisionClient.Action action;
        try{action=PolicyDecisionClient.Action.valueOf(String.valueOf(data.get("action")));}
        catch(RuntimeException e){throw new DeliveryFailure("INVALID_BTS_POLICY",false);}
        return new PolicyDecisionClient.Decision(action,positive(data.get("decisionId")));
    }
    private static Long positive(Object value){
        try{long id=new BigInteger(String.valueOf(value)).longValueExact();return id>0?id:null;}
        catch(RuntimeException e){return null;}
    }
    /**
     * 실제 정책 적용 기록 전송 (#67, POST /api/v1/policy-applications). 행동 이벤트 API와 다른 endpoint이고
     * BTS는 behavior_event에 쓰지 않는다. (serviceId, externalApplicationId)가 멱등 키라 같은 payload 재전송은 200이다.
     */
    public long sendPolicyApplication(String payload){
        Map<?,?> data=post("/api/v1/policy-applications",payload);
        Map<?,?> sent=json.readValue(payload,Map.class);
        for(String key:List.of("serviceId","externalApplicationId","userId","concertId","action","result")){
            if(!Objects.equals(sent.get(key),data.get(key)))throw new DeliveryFailure("INVALID_BTS_RESPONSE",false);
        }
        Long decision=positive(data.get("decisionId")),id=positive(data.get("applicationId"));
        if(id==null||decision==null||!decision.equals(positive(sent.get("decisionId"))))
            throw new DeliveryFailure("INVALID_BTS_RESPONSE",false);
        return id;
    }
    /** 마이페이지 표시용 조회. 정책 결정(POST)과 달리 BTS에 아무것도 기록하지 않는다. */
    public record Account(Integer creditScore,String tier,Double anomalyScore,PolicyDecisionClient.Action latestAction){}
    public Account account(String uuid){
        try{UUID.fromString(uuid);}catch(RuntimeException e){throw new DeliveryFailure("INVALID_BTS_USER",false);}
        Map<?,?> data=exchange("/api/v1/users/"+uuid,null);
        PolicyDecisionClient.Action action=null;
        if(data.get("latestAction") instanceof String name){
            try{action=PolicyDecisionClient.Action.valueOf(name);}catch(IllegalArgumentException e){throw new DeliveryFailure("INVALID_BTS_POLICY",false);}
        }
        return new Account(data.get("creditScore") instanceof Number n?n.intValue():null,
                data.get("tier") instanceof String t?t:null,
                data.get("anomalyScore") instanceof Number a?a.doubleValue():null,action);
    }
    /**
     * 공연 정보를 BTS에 등록·갱신한다 (PUT /api/v1/concerts/{concertId}, 멱등).
     * concertId는 이벤트 metadata.concertId와 같은 공연 public_id이고, 시각은 초 단위 UTC ISO 8601이다.
     */
    public void upsertConcert(String concertId,String name,LocalDateTime startsAtUtc,LocalDateTime endsAtUtc,String venue){
        if(concertId==null||!concertId.matches("\\S{1,50}"))throw new DeliveryFailure("INVALID_CONCERT_ID",false);
        String body=json.writeValueAsString(Map.of("name",name,"venue",venue,
                "startsAt",startsAtUtc.toInstant(ZoneOffset.UTC).truncatedTo(ChronoUnit.SECONDS).toString(),
                "endsAt",endsAtUtc.toInstant(ZoneOffset.UTC).truncatedTo(ChronoUnit.SECONDS).toString()));
        Map<?,?> data=exchange("PUT","/api/v1/concerts/"+URLEncoder.encode(concertId,StandardCharsets.UTF_8),body);
        if(!concertId.equals(data.get("concertId")))throw new DeliveryFailure("INVALID_BTS_RESPONSE",false);
    }
    private Map<?,?> post(String path,String payload){return exchange("POST",path,payload);}
    private Map<?,?> exchange(String path,String payload){return exchange(payload==null?"GET":"POST",path,payload);}
    private Map<?,?> exchange(String method,String path,String payload){
        if(!settings.enabled)throw new DeliveryFailure("BTS_DISABLED",true);
        HttpRequest.Builder builder=HttpRequest.newBuilder(URI.create(settings.baseUrl.replaceAll("/+$","")+path))
                .timeout(Duration.ofSeconds(3)).header("X-API-Key",settings.apiKey);
        HttpRequest request=(payload==null?builder.GET()
                :builder.header("Content-Type","application/json").method(method,HttpRequest.BodyPublishers.ofString(payload))).build();
        HttpResponse<String> response;
        try{response=http.send(request,HttpResponse.BodyHandlers.ofString());}
        catch(InterruptedException e){Thread.currentThread().interrupt();throw new DeliveryFailure("BTS_INTERRUPTED",true);}
        catch(IOException e){throw new DeliveryFailure("BTS_NETWORK",true);}
        Map<?,?> body;
        try{body=json.readValue(response.body(),Map.class);}
        catch(RuntimeException e){throw new DeliveryFailure("INVALID_BTS_RESPONSE",response.statusCode()>=500);}
        if(body==null)throw new DeliveryFailure("INVALID_BTS_RESPONSE",response.statusCode()>=500);
        String code=String.valueOf(body.get("code"));
        if(!code.matches("[A-Z0-9_]{1,64}"))code="INVALID_BTS_RESPONSE";
        int status=response.statusCode();
        if((status!=200&&status!=201)||!Boolean.TRUE.equals(body.get("success")))
            throw new DeliveryFailure(code,status>=500);
        if(!code.equals(status==201?"COMMON_201":"COMMON_200")||!(body.get("data") instanceof Map<?,?> data))
            throw new DeliveryFailure("INVALID_BTS_RESPONSE",false);
        return data;
    }
}
