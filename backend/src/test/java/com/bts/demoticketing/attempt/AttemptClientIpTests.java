package com.bts.demoticketing.attempt;

import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;
import com.bts.demoticketing.common.web.ClientIpResolver;
import com.bts.demoticketing.user.entity.DemoUser;
import com.bts.demoticketing.user.service.DemoAuthService;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * #68: 예매 시도 API가 예매 확정과 같은 ClientIpResolver 기준으로 IP를 넘기는지.
 * 해석 규칙 자체(신뢰 프록시 체인, IPv6 등)는 ClientIpResolverTests가 검증한다.
 */
class AttemptClientIpTests {
    final String id=UUID.randomUUID().toString(),transition=UUID.randomUUID().toString();
    final DemoUser user=new DemoUser(1,"alice","service","alice",null);
    final AttemptService service=mock(AttemptService.class);
    final DemoAuthService auth=mock(DemoAuthService.class);
    final AttemptService.Snapshot snapshot=new AttemptService.Snapshot(id,"c1","STARTED","ENTERED",1,null,null);

    private AttemptController controller(ClientIpResolver resolver){
        when(auth.require(any())).thenReturn(user);
        when(service.start(any(),any(),any(),any(),any())).thenReturn(snapshot);
        when(service.client(any(),any(),any(),any(),any(),any())).thenReturn(snapshot);
        return new AttemptController(service,auth,resolver);
    }
    private static MockHttpServletRequest request(String peer,String... forwardedFor){
        var request=new MockHttpServletRequest();request.setRemoteAddr(peer);
        for(String value:forwardedFor)request.addHeader("X-Forwarded-For",value);
        request.addHeader("Authorization","Bearer secret-session-token");
        return request;
    }
    private void startAndTransition(AttemptController controller,MockHttpServletRequest request,String expectedIp){
        assertEquals(snapshot,controller.start("c1",id,new AttemptController.Start(null),request).data());
        assertEquals(snapshot,controller.transition(id,new AttemptController.Transition(transition,"SEAT_SELECTION","ENTERED"),request).data());
        verify(service).start("c1",id,user,null,expectedIp);
        verify(service).client(id,user,transition,"SEAT_SELECTION","ENTERED",expectedIp);
    }

    @Test void directRequestUsesTheConnectingPeerAndIgnoresForwardedHeaders(){
        startAndTransition(controller(new ClientIpResolver("")),request("198.51.100.20","203.0.113.7"),"198.51.100.20");
    }
    @Test void trustedProxyRequestUsesTheForwardedClient(){
        startAndTransition(controller(new ClientIpResolver("172.18.0.0/16")),request("172.18.0.5","1.1.1.1, 203.0.113.7"),"203.0.113.7");
    }
    @Test void untrustedPeerCannotSpoofTheRecordedIp(){
        startAndTransition(controller(new ClientIpResolver("172.18.0.0/16")),request("198.51.100.20","203.0.113.7"),"198.51.100.20");
    }
    @Test void unresolvableAddressKeepsTheAttemptAndOnlyOmitsTheIp(){
        // 주소를 해석하지 못해도 시도와 단계 보고는 그대로 기록한다. ipAddress만 없다.
        startAndTransition(controller(new ClientIpResolver("")),request("not-an-ip"),null);
    }
    @Test void onlyTheAddressResolutionFailureIsTolerated(){
        var resolver=mock(ClientIpResolver.class);
        when(resolver.resolve(any())).thenThrow(new ApiException(ResponseCode.SERVICE_UNAVAILABLE));
        var controller=controller(resolver);
        assertEquals(ResponseCode.SERVICE_UNAVAILABLE,assertThrows(ApiException.class,
                ()->controller.start("c1",id,new AttemptController.Start(null),request("198.51.100.20"))).getResponseCode());
        doThrow(new IllegalStateException("unexpected")).when(resolver).resolve(any());
        assertThrows(IllegalStateException.class,
                ()->controller.transition(id,new AttemptController.Transition(transition,"SEAT_SELECTION","ENTERED"),request("198.51.100.20")));
        verify(service,never()).start(any(),any(),any(),any(),any());
        verify(service,never()).client(any(),any(),any(),any(),any(),any());
    }
    @Test void unauthenticatedRequestsAreRejectedBeforeAnyIpHandling(){
        var resolver=mock(ClientIpResolver.class);
        var controller=controller(resolver);
        when(auth.require(any())).thenThrow(new ApiException(ResponseCode.UNAUTHORIZED));
        assertThrows(ApiException.class,()->controller.start("c1",id,new AttemptController.Start(null),request("198.51.100.20")));
        verifyNoInteractions(resolver,service);
    }
}
