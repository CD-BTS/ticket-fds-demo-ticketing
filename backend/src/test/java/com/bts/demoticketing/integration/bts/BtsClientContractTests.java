package com.bts.demoticketing.integration.bts;

import java.io.IOException;
import java.net.*;
import java.util.*;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.core.type.TypeReference;
import com.bts.demoticketing.user.entity.DemoUser;
import static org.junit.jupiter.api.Assertions.*;

class BtsClientContractTests {
    private final JsonMapper json=JsonMapper.builder().build();
    @Test void attemptEventDoesNotNeedAFabricatedBookingIdAndPolicyUsesServerKey()throws Exception{
        var server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        String uuid=UUID.randomUUID().toString();
        server.createContext("/api/v1/events",e->{
            Map<String,Object> data=new LinkedHashMap<>(json.readValue(e.getRequestBody().readAllBytes(),new TypeReference<Map<String,Object>>() {}));
            assertFalse(data.containsKey("bookingId"));data.put("eventId",7);
            byte[] body=json.writeValueAsBytes(Map.of("success",true,"code","COMMON_201","data",data));
            e.sendResponseHeaders(201,body.length);e.getResponseBody().write(body);e.close();
        });
        server.createContext("/api/v1/users/"+uuid+"/policy-decisions",e->{
            assertEquals("test-only",e.getRequestHeaders().getFirst("X-API-Key"));
            assertEquals("QUEUE_JOIN",json.readValue(e.getRequestBody().readAllBytes(),Map.class).get("context"));
            byte[] body=json.writeValueAsBytes(Map.of("success",true,"code","COMMON_200","data",Map.of("action","REQUIRE_CAPTCHA")));
            e.sendResponseHeaders(200,body.length);e.getResponseBody().write(body);e.close();
        });
        server.start();
        try{
            var client=new BtsClient(new BtsSettings(true,"http://127.0.0.1:"+server.getAddress().getPort(),"service","test-only"),json);
            assertEquals(7,client.send(json.writeValueAsString(Map.of("serviceId","service","externalEventId","e1","userId",uuid,"eventType","BOOKING_ATTEMPT"))));
            assertEquals(PolicyDecisionClient.Action.REQUIRE_CAPTCHA,client.policy(uuid));
        }finally{server.stop(0);}
    }

    @Test void policyDecisionCarriesConcertIdAndReturnsDecisionId()throws Exception{
        var server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        String uuid=UUID.randomUUID().toString();
        List<Map<String,Object>> requests=new ArrayList<>();
        server.createContext("/api/v1/users/"+uuid+"/policy-decisions",e->{
            Map<String,Object> request=json.readValue(e.getRequestBody().readAllBytes(),new TypeReference<Map<String,Object>>() {});
            requests.add(request);
            Map<String,Object> data=new LinkedHashMap<>(Map.of("action","DELAY","userId",uuid));
            // 공연 ID 없이 온 요청에는 이전 BTS처럼 decisionId가 없는 응답을 돌려준다
            if(request.containsKey("concertId")){data.put("decisionId",123);data.put("concertId",request.get("concertId"));}
            byte[] body=json.writeValueAsBytes(Map.of("success",true,"code","COMMON_201","data",data));
            e.sendResponseHeaders(201,body.length);e.getResponseBody().write(body);e.close();
        });
        server.start();
        try{
            var client=new BtsClient(new BtsSettings(true,"http://127.0.0.1:"+server.getAddress().getPort(),"service","test-only"),json);
            assertEquals(new PolicyDecisionClient.Decision(PolicyDecisionClient.Action.DELAY,123L),client.decision(uuid,"QUEUE_JOIN","c1"));
            assertEquals(Map.of("context","QUEUE_JOIN","concertId","c1"),requests.get(0));
            assertEquals(new PolicyDecisionClient.Decision(PolicyDecisionClient.Action.DELAY,null),client.decision(uuid,"BOOKING_ATTEMPT",null));
            assertEquals(Map.of("context","BOOKING_ATTEMPT"),requests.get(1));
        }finally{server.stop(0);}
    }

    @Test void policyApplicationUsesItsOwnEndpointAndValidatesTheEchoedRecord()throws Exception{
        var server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        String uuid=UUID.randomUUID().toString();
        List<String> paths=new ArrayList<>();Set<Object> stored=new HashSet<>();
        server.createContext("/api/v1/",e->{
            paths.add(e.getRequestMethod()+" "+e.getRequestURI().getPath()+" "+e.getRequestHeaders().getFirst("X-API-Key"));
            Map<String,Object> data=new LinkedHashMap<>(json.readValue(e.getRequestBody().readAllBytes(),new TypeReference<Map<String,Object>>() {}));
            boolean created=stored.add(data.get("externalApplicationId"));
            data.put("applicationId",55);
            if("pa-mismatch".equals(data.get("externalApplicationId")))data.put("decisionId",999);
            byte[] body=json.writeValueAsBytes(Map.of("success",true,"code",created?"COMMON_201":"COMMON_200","data",data));
            e.sendResponseHeaders(created?201:200,body.length);e.getResponseBody().write(body);e.close();
        });
        server.start();
        try{
            var client=new BtsClient(new BtsSettings(true,"http://127.0.0.1:"+server.getAddress().getPort(),"service","test-only"),json);
            Map<String,Object> record=new LinkedHashMap<>(Map.of("serviceId","service","externalApplicationId","pa-123-CHALLENGED","userId",uuid,
                    "decisionId",123,"concertId","c1","action","REQUIRE_CAPTCHA","result","CHALLENGED","appliedAt","2026-11-24T13:07:12.123Z"));
            assertEquals(55,client.sendPolicyApplication(json.writeValueAsString(record)));
            // 같은 payload 재전송은 BTS가 200으로 기존 기록을 돌려주고, Demo는 그것도 성공으로 본다
            assertEquals(55,client.sendPolicyApplication(json.writeValueAsString(record)));
            assertEquals(List.of("POST /api/v1/policy-applications test-only","POST /api/v1/policy-applications test-only"),paths);
            record.put("externalApplicationId","pa-mismatch");
            var error=assertThrows(BtsClient.DeliveryFailure.class,()->client.sendPolicyApplication(json.writeValueAsString(record)));
            assertEquals("INVALID_BTS_RESPONSE",error.code);assertFalse(error.retryable);
        }finally{server.stop(0);}
    }

    @Test void checkInEventCarriesTicketIdAndRejectsAResponseForAnotherTicket()throws Exception{
        var server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        String uuid=UUID.randomUUID().toString();
        List<Map<String,Object>> received=new ArrayList<>();
        server.createContext("/api/v1/events",e->{
            Map<String,Object> data=new LinkedHashMap<>(json.readValue(e.getRequestBody().readAllBytes(),new TypeReference<Map<String,Object>>() {}));
            received.add(new LinkedHashMap<>(data));data.put("eventId",9);
            if("e-mismatch".equals(data.get("externalEventId")))data.put("ticketId","another-ticket");
            byte[] body=json.writeValueAsBytes(Map.of("success",true,"code","COMMON_201","data",data));
            e.sendResponseHeaders(201,body.length);e.getResponseBody().write(body);e.close();
        });
        server.start();
        try{
            var client=new BtsClient(new BtsSettings(true,"http://127.0.0.1:"+server.getAddress().getPort(),"service","test-only"),json);
            Map<String,Object> event=new LinkedHashMap<>(Map.of("serviceId","service","externalEventId","e1","userId",uuid,
                    "eventType","CHECK_IN","bookingId","b1","ticketId","t1"));
            assertEquals(9,client.send(json.writeValueAsString(event)));
            assertEquals("t1",received.get(0).get("ticketId"));assertEquals("b1",received.get(0).get("bookingId"));
            event.put("externalEventId","e-mismatch");
            var error=assertThrows(BtsClient.DeliveryFailure.class,()->client.send(json.writeValueAsString(event)));
            assertEquals("INVALID_BTS_RESPONSE",error.code);assertFalse(error.retryable);
        }finally{server.stop(0);}
    }

    @Test void disabledDeliveryNeverUsesAnEmptyKey(){
        var client=new BtsClient(new BtsSettings(false,"","service",""),json);
        var error=assertThrows(BtsClient.DeliveryFailure.class,()->client.send("{}"));
        assertEquals("BTS_DISABLED",error.code);assertTrue(error.retryable);
    }
    @Test void remotePlainHttpAndMissingKeyFailFast(){
        assertThrows(IllegalArgumentException.class,()->new BtsSettings(true,"http://example.com","service","key"));
        assertThrows(IllegalArgumentException.class,()->new BtsSettings(true,"http://127.0.0.1:9999","service",""));
    }
    @Test void connectionRefusedIsRetryable()throws IOException{
        int port;try(var socket=new java.net.ServerSocket(0,0,InetAddress.getByName("127.0.0.1"))){port=socket.getLocalPort();}
        var client=new BtsClient(new BtsSettings(true,"http://127.0.0.1:"+port,"service","test-only"),json);
        var error=assertThrows(BtsClient.DeliveryFailure.class,()->client.send("{}"));
        assertEquals("BTS_NETWORK",error.code);assertTrue(error.retryable);
    }
    @Test void registrationUsesServiceKeyAndCamelCaseContract()throws Exception{
        var server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        List<Map<?,?>> requests=new ArrayList<>();List<String> keys=new ArrayList<>();
        String uuid=UUID.randomUUID().toString();
        server.createContext("/api/v1/users",e->{
            requests.add(json.readValue(e.getRequestBody().readAllBytes(),Map.class));
            keys.add(e.getRequestHeaders().getFirst("X-API-Key"));
            byte[] body=json.writeValueAsBytes(Map.of("success",true,"code","COMMON_200","message","ok","data",
                    Map.of("userId",uuid,"serviceId","service","externalUserId","external")));
            e.getResponseHeaders().set("Content-Type","application/json");e.sendResponseHeaders(200,body.length);e.getResponseBody().write(body);e.close();
        });
        server.start();
        try{
            var client=new BtsClient(new BtsSettings(true,"http://127.0.0.1:"+server.getAddress().getPort(),"service","test-only"),json);
            assertEquals(uuid,client.register(new DemoUser(1,"local","service","external",null)));
            assertEquals(List.of("test-only"),keys);
            assertEquals(Set.of("serviceId","externalUserId","accountStatus"),requests.get(0).keySet());
            assertEquals("ACTIVE",requests.get(0).get("accountStatus"));
        }finally{server.stop(0);}
    }
    @Test void accountLookupIsAReadOnlyGetWithTheServiceKey()throws Exception{
        var server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        List<String> calls=new ArrayList<>();
        String uuid=UUID.randomUUID().toString();
        server.createContext("/api/v1/users/"+uuid,e->{
            calls.add(e.getRequestMethod()+" "+e.getRequestURI().getPath()+" "+e.getRequestHeaders().getFirst("X-API-Key"));
            Map<String,Object> data=new LinkedHashMap<>();
            data.put("userId",uuid);data.put("creditScore",30);data.put("tier","SUSPICIOUS");
            data.put("anomalyScore",null);data.put("latestAction","REQUIRE_CAPTCHA");
            byte[] body=json.writeValueAsBytes(Map.of("success",true,"code","COMMON_200","message","ok","data",data));
            e.sendResponseHeaders(200,body.length);e.getResponseBody().write(body);e.close();
        });
        server.start();
        try{
            var client=new BtsClient(new BtsSettings(true,"http://127.0.0.1:"+server.getAddress().getPort(),"service","test-only"),json);
            var account=client.account(uuid);
            assertEquals(30,account.creditScore());assertEquals("SUSPICIOUS",account.tier());
            assertNull(account.anomalyScore());assertEquals(PolicyDecisionClient.Action.REQUIRE_CAPTCHA,account.latestAction());
            assertEquals(List.of("GET /api/v1/users/"+uuid+" test-only"),calls);
        }finally{server.stop(0);}
    }
}
