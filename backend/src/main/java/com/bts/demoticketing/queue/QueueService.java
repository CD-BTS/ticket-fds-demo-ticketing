package com.bts.demoticketing.queue;

import org.springframework.stereotype.Service;
import com.bts.demoticketing.concert.service.ConcertService;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient;
import com.bts.demoticketing.outbox.PolicyApplicationRecorder;
import com.bts.demoticketing.user.entity.DemoUser;
import com.bts.demoticketing.user.repository.DemoUserRepository;

@Service
public class QueueService {
    private final ConcertService concerts;
    private final QueueStore store;
    private final PolicyDecisionClient policies;
    private final DemoUserRepository users;
    private final PolicyApplicationRecorder applications;
    public QueueService(ConcertService concerts, QueueStore store,PolicyDecisionClient policies,DemoUserRepository users,
            PolicyApplicationRecorder applications){
        this.concerts=concerts;this.store=store;this.policies=policies;this.users=users;this.applications=applications;
    }
    public QueueStore.Result execute(String concert, long user, String operation){
        if(operation.equals("join"))return join(concert,users.find(user).orElseThrow(()->new ApiException(ResponseCode.UNAUTHORIZED)),null);
        concerts.get(concert);
        return store.execute(concert,user,operation);
    }
    private static boolean active(QueueStore.Result result){return result.snapshot().status().equals("WAITING")||result.snapshot().status().equals("ADMITTED");}
    /** 이 공연에 대한 대기열 정책 결정. BTS 모드에서는 요청에 공연 ID가 실리고 decisionId가 함께 온다 (#67). */
    public PolicyDecisionClient.Decision decision(DemoUser user,String concert){
        try{
            var decision=policies.decideFor(user,concert);
            if(decision==null||decision.action()==null)throw new IllegalStateException("Missing action");
            return decision;
        }catch(RuntimeException e){throw new ApiException(ResponseCode.SERVICE_UNAVAILABLE);}
    }
    public QueueStore.Result join(String concert,DemoUser user,String captchaToken){
        concerts.get(concert);
        var current=store.execute(concert,user.id(),"status");
        if(active(current))return current;
        PolicyDecisionClient.Decision decision;
        try{decision=decision(user,concert);}
        catch(ApiException failure){
            // Another concurrent request may already have admitted/registered this user.
            var raced=store.execute(concert,user.id(),"status");
            if(active(raced))return raced;
            throw failure;
        }
        // 적용 기록은 Lua가 정책을 실제로 적용한 결과로만 남긴다 (#67). 이미 등록된 사용자에게는 정책을
        // 다시 적용하지 않으므로(created=false) 기록도 없다. CAPTCHA 요구·결과는 CAPTCHA 발급·검증 시점에 남긴다.
        QueueStore.Result result;
        try{result=store.join(concert,user.id(),decision.action().name(),captchaToken);}
        catch(ApiException rejected){
            if(rejected.getResponseCode()==ResponseCode.QUEUE_RESTRICTED)applications.record(user,concert,decision,"BLOCKED");
            throw rejected;
        }
        if(result.created()&&QueueJoinPolicy.forAction(decision.action()).delayed())applications.record(user,concert,decision,"DELAYED");
        return result;
    }
    public PolicyDecisionClient.Decision captchaAction(String concert,DemoUser user){
        concerts.get(concert);
        var decision=decision(user,concert);
        var policy=QueueJoinPolicy.forAction(decision.action());
        if(policy.restricted())throw new ApiException(ResponseCode.QUEUE_RESTRICTED);
        if(!policy.captchaRequired())throw new ApiException(ResponseCode.INVALID_REQUEST);
        return decision;
    }
    public void requireAdmitted(String concert, long user){
        // The existing Lua status operation expires stale admissions and promotes FIFO waiters
        // using Redis TIME. Never authorize from a cached status or a separate ZSET lookup.
        if(!"ADMITTED".equals(execute(concert,user,"status").snapshot().status()))
            throw new ApiException(ResponseCode.QUEUE_NOT_ADMITTED);
    }
}
