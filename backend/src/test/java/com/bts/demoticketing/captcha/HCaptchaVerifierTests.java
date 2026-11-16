package com.bts.demoticketing.captcha;

import static org.junit.jupiter.api.Assertions.*;

import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class HCaptchaVerifierTests {
    private HttpServer server;
    private final AtomicReference<String> lastBody=new AtomicReference<>();
    private volatile int status=200;
    private volatile String reply="{\"success\":true}";

    @BeforeEach void start()throws Exception{
        server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        server.createContext("/siteverify",exchange->{
            lastBody.set(new String(exchange.getRequestBody().readAllBytes(),StandardCharsets.UTF_8));
            byte[] out=reply.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(status,out.length);
            try(var body=exchange.getResponseBody()){body.write(out);}
        });
        server.start();
    }
    @AfterEach void stop(){try{server.stop(0);}catch(RuntimeException ignored){}}
    private HCaptchaVerifier verifier(){return new HCaptchaVerifier("site-key","secret-key","http://127.0.0.1:"+server.getAddress().getPort()+"/siteverify");}

    @Test void successfulTokenPassesAndSendsSecretResponseAndSiteKey(){
        assertTrue(verifier().verify("ignored","token+/="));
        assertEquals("secret=secret-key&response=token%2B%2F%3D&sitekey=site-key",lastBody.get());
    }
    @Test void rejectedTokenFails(){
        reply="{\"success\":false,\"error-codes\":[\"invalid-or-already-seen-response\"]}";
        assertFalse(verifier().verify("ignored","token"));
    }
    @Test void blankTokenFailsWithoutCallingHcaptcha(){
        assertFalse(verifier().verify("ignored"," "));
        assertNull(lastBody.get());
    }
    @Test void providerErrorIsServiceUnavailableNotWrongAnswer(){
        status=500;reply="oops";
        var e=assertThrows(ApiException.class,()->verifier().verify("ignored","token"));
        assertEquals(ResponseCode.SERVICE_UNAVAILABLE,e.getResponseCode());
    }
    @Test void unreachableProviderIsServiceUnavailable(){
        int port=server.getAddress().getPort();server.stop(0);
        var v=new HCaptchaVerifier("site-key","secret-key","http://127.0.0.1:"+port+"/siteverify");
        assertEquals(ResponseCode.SERVICE_UNAVAILABLE,assertThrows(ApiException.class,()->v.verify("x","token")).getResponseCode());
    }
    @Test void createGivesUnguessableAnswerAndExposesProviderAndSiteKey(){
        var v=verifier();
        assertEquals("hcaptcha",v.provider());assertEquals("site-key",v.siteKey());
        var a=v.create();var b=v.create();
        assertEquals("hcaptcha",a.question());assertNotEquals(a.answer(),b.answer());assertEquals(64,a.answer().length());
    }
    @Test void missingKeysAreRejectedAtStartup(){
        assertThrows(IllegalArgumentException.class,()->new HCaptchaVerifier("","secret","http://x"));
        assertThrows(IllegalArgumentException.class,()->new HCaptchaVerifier("site"," ","http://x"));
    }
}
