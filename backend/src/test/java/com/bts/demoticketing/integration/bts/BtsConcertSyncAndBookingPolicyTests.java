package com.bts.demoticketing.integration.bts;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import java.net.InetSocketAddress;
import java.time.LocalDateTime;
import java.util.*;

import org.junit.jupiter.api.Test;
import com.sun.net.httpserver.HttpServer;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

import com.bts.demoticketing.booking.policy.BookingPolicyGuard;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;
import com.bts.demoticketing.concert.entity.Concert;
import com.bts.demoticketing.concert.repository.ConcertRepository;
import com.bts.demoticketing.integration.bts.PolicyDecisionClient.Action;
import com.bts.demoticketing.user.entity.DemoUser;

class BtsConcertSyncAndBookingPolicyTests {
    private final JsonMapper json = JsonMapper.builder().build();
    private final DemoUser user = new DemoUser(1, "u-1", "service", "ext-1", null);

    private static void reply(com.sun.net.httpserver.HttpExchange e, int status, byte[] body) throws java.io.IOException {
        e.sendResponseHeaders(status, body.length); e.getResponseBody().write(body); e.close();
    }

    private Concert concert(String id, String title) {
        Concert concert = mock(Concert.class);
        when(concert.getPublicId()).thenReturn(id);
        when(concert.getTitle()).thenReturn(title);
        when(concert.getVenue()).thenReturn("Seoul Hall");
        when(concert.getStartAt()).thenReturn(LocalDateTime.of(2026, 12, 1, 10, 0, 0, 500_000));
        when(concert.getEndAt()).thenReturn(LocalDateTime.of(2026, 12, 1, 12, 0));
        return concert;
    }

    @Test
    void upsertConcertSendsIdempotentPutWithSecondPrecisionUtcTimes() throws Exception {
        var server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        List<Map<String, Object>> received = new ArrayList<>();
        server.createContext("/api/v1/concerts/", e -> {
            assertEquals("PUT", e.getRequestMethod());
            assertEquals("/api/v1/concerts/concert-1", e.getRequestURI().getPath());
            assertEquals("test-only", e.getRequestHeaders().getFirst("X-API-Key"));
            Map<String, Object> body = json.readValue(e.getRequestBody().readAllBytes(), new TypeReference<Map<String, Object>>() {});
            received.add(body);
            Map<String, Object> data = new LinkedHashMap<>(body);
            data.put("serviceId", "service"); data.put("concertId", "concert-1");
            reply(e, 200, json.writeValueAsBytes(Map.of("success", true, "code", "COMMON_200", "data", data)));
        });
        server.start();
        try {
            var client = new BtsClient(new BtsSettings(true, "http://127.0.0.1:" + server.getAddress().getPort(), "service", "test-only"), json);
            client.upsertConcert("concert-1", "Demo Concert", LocalDateTime.of(2026, 12, 1, 10, 0, 0, 500_000),
                    LocalDateTime.of(2026, 12, 1, 12, 0), "Seoul Hall");
            assertEquals(Map.of("name", "Demo Concert", "venue", "Seoul Hall",
                    "startsAt", "2026-12-01T10:00:00Z", "endsAt", "2026-12-01T12:00:00Z"), received.get(0));
            assertThrows(BtsClient.DeliveryFailure.class,
                    () -> client.upsertConcert("bad id", "x", LocalDateTime.now(), LocalDateTime.now().plusHours(1), "v"));
        } finally { server.stop(0); }
    }

    @Test
    void bookingPolicyUsesBookingAttemptContext() throws Exception {
        var server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        String uuid = UUID.randomUUID().toString();
        List<Object> contexts = new ArrayList<>();
        server.createContext("/api/v1/users/" + uuid + "/policy-decisions", e -> {
            contexts.add(json.readValue(e.getRequestBody().readAllBytes(), Map.class).get("context"));
            reply(e, 200, json.writeValueAsBytes(Map.of("success", true, "code", "COMMON_200", "data", Map.of("action", "RESTRICT"))));
        });
        server.start();
        try {
            var client = new BtsClient(new BtsSettings(true, "http://127.0.0.1:" + server.getAddress().getPort(), "service", "test-only"), json);
            assertEquals(Action.RESTRICT, client.policy(uuid, "BOOKING_ATTEMPT"));
            assertEquals(Action.RESTRICT, client.policy(uuid));
            assertEquals(List.of("BOOKING_ATTEMPT", "QUEUE_JOIN"), contexts);
            assertThrows(IllegalArgumentException.class, () -> client.policy(uuid, "OTHER"));
        } finally { server.stop(0); }
    }

    @Test
    void concertSyncIsolatesFailuresPerConcertAndSkipsWhenDisabled() throws Exception {
        var server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        List<String> paths = new ArrayList<>();
        server.createContext("/api/v1/concerts/", e -> {
            String path = e.getRequestURI().getPath();
            paths.add(path);
            e.getRequestBody().readAllBytes();
            if (path.endsWith("/broken")) {
                reply(e, 500, json.writeValueAsBytes(Map.of("success", false, "code", "INTERNAL_SERVER_ERROR")));
                return;
            }
            String id = path.substring(path.lastIndexOf('/') + 1);
            reply(e, 200, json.writeValueAsBytes(Map.of("success", true, "code", "COMMON_200", "data", Map.of("concertId", id))));
        });
        server.start();
        try {
            ConcertRepository repository = mock(ConcertRepository.class);
            List<Concert> all = List.of(concert("c1", "A"), concert("broken", "B"), concert("c3", "C"));
            when(repository.findAllByOrderByStartAtAscPublicIdAsc()).thenReturn(all);
            String url = "http://127.0.0.1:" + server.getAddress().getPort();
            var enabled = new BtsSettings(true, url, "service", "test-only");

            assertEquals(2, new ConcertSyncService(repository, new BtsClient(enabled, json), enabled).syncAll());
            assertEquals(List.of("/api/v1/concerts/c1", "/api/v1/concerts/broken", "/api/v1/concerts/c3"), paths);

            var disabled = new BtsSettings(false, "", "service", "");
            assertEquals(0, new ConcertSyncService(repository, new BtsClient(disabled, json), disabled).syncAll());
            assertEquals(3, paths.size());
        } finally { server.stop(0); }
    }

    @Test
    void bookingGuardBlocksOnlyRestrictAndAllowsWhenPolicyUnavailable() {
        var recorder = mock(com.bts.demoticketing.outbox.PolicyApplicationRecorder.class);
        PolicyDecisionClient restricted = mock(PolicyDecisionClient.class);
        var blocked = new PolicyDecisionClient.Decision(Action.RESTRICT, 41L);
        when(restricted.decideBookingFor(user, "c1")).thenReturn(blocked);
        var error = assertThrows(ApiException.class, () -> new BookingPolicyGuard(restricted, recorder).check(user, "c1"));
        assertEquals(ResponseCode.BOOKING_RESTRICTED, error.getResponseCode());
        // 선점을 실제로 거부했을 때만, 그 거부를 만든 결정으로 BLOCKED를 남긴다 (#67)
        verify(recorder).record(user, "c1", blocked, "BLOCKED");

        for (Action action : List.of(Action.ALLOW, Action.REQUIRE_CAPTCHA, Action.DELAY)) {
            PolicyDecisionClient client = mock(PolicyDecisionClient.class);
            when(client.decideBookingFor(user, "c1")).thenReturn(new PolicyDecisionClient.Decision(action, 42L));
            assertDoesNotThrow(() -> new BookingPolicyGuard(client, recorder).check(user, "c1"));
        }

        PolicyDecisionClient failing = mock(PolicyDecisionClient.class);
        when(failing.decideBookingFor(user, "c1")).thenThrow(new BtsClient.DeliveryFailure("BTS_NETWORK", true));
        assertDoesNotThrow(() -> new BookingPolicyGuard(failing, recorder).check(user, "c1"));
        // 예매 단계에서 적용되지 않는 정책, 장애로 허용한 선점은 적용 기록이 없다
        verifyNoMoreInteractions(recorder);
    }

    @Test
    void nonBtsModesHaveNoDecisionIdSoNoApplicationCanBeRecorded() {
        PolicyDecisionClient mockMode = new MockPolicyDecisionClient(Map.of("u-1", Action.RESTRICT));
        assertEquals(new PolicyDecisionClient.Decision(Action.RESTRICT, null), mockMode.decideFor(user, "c1"));
        assertEquals(new PolicyDecisionClient.Decision(Action.RESTRICT, null), mockMode.decideBookingFor(user, "c1"));
    }

    @Test
    void nonBtsModesReuseQueueDecisionForBooking() {
        PolicyDecisionClient mockMode = new MockPolicyDecisionClient(Map.of("u-1", Action.RESTRICT));
        assertEquals(Action.RESTRICT, mockMode.decideBooking(user));
    }
}
