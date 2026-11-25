package com.bts.demoticketing.outbox;

import java.util.*;
import org.springframework.stereotype.Service;
import tools.jackson.databind.json.JsonMapper;
import com.bts.demoticketing.integration.bts.*;
import com.bts.demoticketing.user.entity.DemoUser;
import com.bts.demoticketing.user.repository.DemoUserRepository;

@Service
public class OutboxDeliveryService {
    private final OutboxTransactions tx;
    private final DemoUserRepository users;
    private final BtsClient bts;
    private final BtsSettings settings;
    private final JsonMapper json;
    public OutboxDeliveryService(OutboxTransactions tx,DemoUserRepository users,BtsClient bts,BtsSettings settings,JsonMapper json){
        this.tx=tx;this.users=users;this.bts=bts;this.settings=settings;this.json=json;
    }
    // Network I/O is deliberately outside every local DB transaction/booking lock.
    public boolean deliverNext(){
        if(!settings.enabled)return false;
        var claimed=tx.claim();
        if(claimed.isEmpty())return false;
        var m=claimed.get();
        boolean policy=m.eventType().equals(PolicyApplicationRecorder.EVENT_TYPE);
        try {
            String payload=m.payload();
            if(payload==null){
                DemoUser user=users.find(m.userId()).orElseThrow();
                if(!m.serviceId().equals(settings.serviceId)||!m.serviceId().equals(user.serviceId()))
                    throw new BtsClient.DeliveryFailure("SERVICE_MAPPING_MISMATCH",false);
                String uuid=user.btsUserId();
                if(uuid==null){uuid=bts.register(user);tx.mapUser(user.id(),uuid);}
                Map<String,Object> body=new LinkedHashMap<>();
                Map<String,Object> metadata=new LinkedHashMap<>();
                json.readValue(m.metadata(),Map.class).forEach((key,value)->metadata.put(String.valueOf(key),value));
                if(policy){
                    // 정책 적용 기록은 행동 이벤트가 아니다 (#67). 전용 API의 본문으로 만든다.
                    body.put("serviceId",m.serviceId());body.put("externalApplicationId",m.externalId());
                    body.put("userId",uuid);body.put("decisionId",metadata.get("decisionId"));
                    body.put("concertId",metadata.get("concertId"));body.put("action",metadata.get("action"));
                    body.put("result",metadata.get("result"));body.put("appliedAt",EventTimes.format(m.occurredAt()));
                }else{
                    body.put("serviceId",m.serviceId());body.put("externalEventId",m.externalId());
                    body.put("userId",uuid);body.put("eventType",m.eventType());
                    if(!m.eventType().equals("BOOKING_ATTEMPT"))body.put("bookingId",m.aggregateId());
                    // BTS는 CHECK_IN에 top-level ticketId를 요구한다. 원천 metadata에서 옮겨 싣는다.
                    if(m.eventType().equals("CHECK_IN"))body.put("ticketId",metadata.remove("ticketId"));
                    body.put("occurredAt",EventTimes.format(m.occurredAt()));
                    body.put("metadata",metadata);
                }
                payload=json.writeValueAsString(body);
                tx.freeze(m,payload);
            }
            // bts_event_id에는 행동 이벤트의 eventId 또는 정책 적용 기록의 applicationId를 저장한다.
            long remoteId=policy?bts.sendPolicyApplication(payload):bts.send(payload);
            tx.sent(m,remoteId);
        }catch(BtsClient.DeliveryFailure e){tx.failed(m,e.code,e.retryable);}
        catch(RuntimeException e){tx.failed(m,"LOCAL_DELIVERY_ERROR",true);}
        return true;
    }
}
