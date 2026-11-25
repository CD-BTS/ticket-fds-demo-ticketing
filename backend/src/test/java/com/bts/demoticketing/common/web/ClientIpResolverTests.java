package com.bts.demoticketing.common.web;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

import com.bts.demoticketing.common.exception.ApiException;

class ClientIpResolverTests {

    private static MockHttpServletRequest request(String peer, String... forwardedFor) {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setRemoteAddr(peer);
        for (String value : forwardedFor) request.addHeader("X-Forwarded-For", value);
        return request;
    }

    @Test
    void withoutTrustedProxiesForwardedHeadersAreIgnored() {
        ClientIpResolver resolver = new ClientIpResolver("");
        assertEquals("172.18.0.5", resolver.resolve(request("172.18.0.5", "203.0.113.7")));
    }

    @Test
    void trustedProxyForwardedClientIsUsed() {
        ClientIpResolver resolver = new ClientIpResolver("172.18.0.0/16");
        assertEquals("203.0.113.7", resolver.resolve(request("172.18.0.5", "203.0.113.7")));
    }

    @Test
    void untrustedPeerCannotSpoofForwardedFor() {
        ClientIpResolver resolver = new ClientIpResolver("172.18.0.0/16");
        assertEquals("198.51.100.20", resolver.resolve(request("198.51.100.20", "203.0.113.7")));
    }

    @Test
    void clientSuppliedEntriesBeforeTheProxyAppendedHopAreIgnored() {
        // 클라이언트가 X-Forwarded-For: 1.1.1.1 을 보내고 프록시가 실제 주소를 덧붙인 경우
        ClientIpResolver resolver = new ClientIpResolver("172.18.0.0/16");
        assertEquals("203.0.113.7", resolver.resolve(request("172.18.0.5", "1.1.1.1, 203.0.113.7")));
    }

    @Test
    void multipleTrustedHopsAreSkippedFromTheRight() {
        ClientIpResolver resolver = new ClientIpResolver("172.18.0.0/16, 10.0.0.1");
        assertEquals("203.0.113.7", resolver.resolve(request("172.18.0.5", "1.1.1.1, 203.0.113.7, 10.0.0.1")));
        assertEquals("203.0.113.7", resolver.resolve(request("172.18.0.5", "1.1.1.1, 203.0.113.7", "10.0.0.1")));
    }

    @Test
    void malformedHopStopsTheWalkAtTheLastTrustedAddress() {
        ClientIpResolver resolver = new ClientIpResolver("172.18.0.0/16, 10.0.0.1");
        assertEquals("10.0.0.1", resolver.resolve(request("172.18.0.5", "203.0.113.7, evil.example, 10.0.0.1")));
        assertEquals("172.18.0.5", resolver.resolve(request("172.18.0.5", "203.0.113.7:4321")));
        assertEquals("172.18.0.5", resolver.resolve(request("172.18.0.5")));
    }

    @Test
    void ipv6RangesAndNormalizationAreSupported() {
        ClientIpResolver resolver = new ClientIpResolver("fd00::/8");
        assertEquals("2001:db8:0:0:0:0:0:1", resolver.resolve(request("fd00::5", "2001:db8::1")));
        assertEquals("203.0.113.7", resolver.resolve(request("fd00::5", "::ffff:203.0.113.7")));
    }

    @Test
    void invalidPeerIsRejected() {
        ClientIpResolver resolver = new ClientIpResolver("");
        assertThrows(ApiException.class, () -> resolver.resolve(request("localhost")));
    }

    @Test
    void hostnamesAreNeverResolved() {
        assertNull(ClientIpResolver.parseLiteral("localhost"));
        assertNull(ClientIpResolver.parseLiteral("abc"));
        assertNull(ClientIpResolver.parseLiteral("fe80::1%eth0"));
        assertNull(ClientIpResolver.parseLiteral("1.2"));
    }

    @Test
    void invalidTrustedProxyConfigurationFailsAtStartup() {
        assertThrows(IllegalArgumentException.class, () -> new ClientIpResolver("0.0.0.0/0"));
        assertThrows(IllegalArgumentException.class, () -> new ClientIpResolver("::/0"));
        assertThrows(IllegalArgumentException.class, () -> new ClientIpResolver("10.0.0.0/33"));
        assertThrows(IllegalArgumentException.class, () -> new ClientIpResolver("proxy"));
        assertThrows(IllegalArgumentException.class, () -> new ClientIpResolver("10.0.0.0/x"));
    }
}
