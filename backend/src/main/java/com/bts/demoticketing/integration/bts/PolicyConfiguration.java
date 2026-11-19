package com.bts.demoticketing.integration.bts;

import java.util.HashMap;
import java.util.Map;
import tools.jackson.core.type.TypeReference;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.*;
import tools.jackson.databind.json.JsonMapper;
import com.bts.demoticketing.user.entity.DemoUser;

@Configuration
public class PolicyConfiguration {
    @Bean PolicyDecisionClient configuredPolicyDecisionClient(
            @Value("${demo.policy.mode:disabled}") String mode,
            @Value("${demo.policy.mock-actions:{}}") String actions,JsonMapper json,
            org.springframework.beans.factory.ObjectProvider<BtsClient> clients,
            org.springframework.beans.factory.ObjectProvider<com.bts.demoticketing.user.repository.DemoUserRepository> repositories){
        if(!mode.equals("bts"))return policyDecisionClient(mode,actions,json);
        return new PolicyDecisionClient(){
            @Override public Action decide(DemoUser user){return decide(user,"QUEUE_JOIN");}
            @Override public Action decideBooking(DemoUser user){return decide(user,"BOOKING_ATTEMPT");}
            private Action decide(DemoUser user,String context){
                var users=repositories.getObject();var bts=clients.getObject();
                String uuid=users.find(user.id()).orElseThrow().btsUserId();
                if(uuid==null){uuid=bts.register(user);users.mapBtsUser(user.id(),uuid);}
                return bts.policy(uuid,context);
            }
        };
    }
    PolicyDecisionClient policyDecisionClient(String mode,String actions,JsonMapper json){
        if(mode.equals("disabled"))return user->PolicyDecisionClient.Action.ALLOW;
        if(!mode.equals("mock"))throw new IllegalArgumentException("Policy mode must be disabled, mock or bts");
        var configured=json.readValue(actions,new TypeReference<Map<String,Object>>() {});
        var result=new HashMap<String,PolicyDecisionClient.Action>();
        configured.forEach((key,value)->result.put(key,PolicyDecisionClient.Action.valueOf((String)value)));
        return new MockPolicyDecisionClient(result);
    }
}
