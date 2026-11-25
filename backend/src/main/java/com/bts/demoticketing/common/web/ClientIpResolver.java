package com.bts.demoticketing.common.web;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.regex.Pattern;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ResponseCode;

/**
 * 예매 이벤트에 기록할 클라이언트 IP를 정한다 (#64).
 *
 * <p>기본값(신뢰 프록시 없음)에서는 연결 peer 주소만 쓰고 Forwarded/X-Forwarded-For는 무시한다.
 * {@code demo.client-ip.trusted-proxies}(CIDR 목록)를 주면, 연결 peer가 그 목록에 있을 때만
 * X-Forwarded-For를 오른쪽(가장 가까운 hop)부터 읽어 신뢰 프록시가 아닌 첫 주소를 클라이언트로 쓴다.
 * 그래서 클라이언트가 보낸 X-Forwarded-For에 프록시가 주소를 덧붙여도(append) 앞쪽의 위조 값은 쓰이지 않는다.
 *
 * <p>Tomcat RemoteIpValve(server.forward-headers-strategy=native)를 쓰지 않는 이유: 기본 신뢰 범위가
 * 모든 사설 대역(10/8, 172.16/12, 192.168/16, 127/8)이라, 같은 사설망의 아무 호스트나 IP를 바꿀 수 있다.
 */
@Component
public class ClientIpResolver {

    private static final Pattern IPV4 = Pattern.compile(
            "(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)(\\.(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){3}");
    // ':'가 들어간 문자열은 InetAddress가 IPv6 리터럴로만 해석한다(DNS 조회 없음). zone(%), 대괄호, 포트는 받지 않는다.
    private static final Pattern IPV6 = Pattern.compile("[0-9a-fA-F:.]*:[0-9a-fA-F:.]*");
    private static final int MAX_FORWARDED_ENTRIES = 20;

    private final List<Cidr> trustedProxies;

    public ClientIpResolver(@Value("${demo.client-ip.trusted-proxies:}") String trustedProxies) {
        List<Cidr> parsed = new ArrayList<>();
        for (String raw : trustedProxies.split(",")) {
            String entry = raw.trim();
            if (!entry.isEmpty()) parsed.add(Cidr.parse(entry));
        }
        this.trustedProxies = Collections.unmodifiableList(parsed);
    }

    public String resolve(HttpServletRequest request) {
        InetAddress peer = parseLiteral(request.getRemoteAddr());
        if (peer == null) throw new ApiException(ResponseCode.INVALID_REQUEST);
        InetAddress client = peer;
        if (isTrusted(peer)) {
            List<String> hops = forwardedFor(request);
            for (int i = hops.size() - 1; i >= 0 && isTrusted(client); i--) {
                InetAddress hop = parseLiteral(hops.get(i));
                if (hop == null) break; // 형식이 잘못된 hop부터는 믿지 않는다. 마지막으로 확인한 신뢰 hop을 쓴다.
                client = hop;
            }
        }
        return client.getHostAddress();
    }

    private boolean isTrusted(InetAddress address) {
        for (Cidr cidr : trustedProxies) {
            if (cidr.contains(address)) return true;
        }
        return false;
    }

    private static List<String> forwardedFor(HttpServletRequest request) {
        List<String> hops = new ArrayList<>();
        for (String header : Collections.list(request.getHeaders("X-Forwarded-For"))) {
            for (String part : header.split(",")) {
                String hop = part.trim();
                if (!hop.isEmpty()) hops.add(hop);
            }
        }
        // 지나치게 긴 체인은 가장 가까운 hop들만 본다.
        return hops.size() > MAX_FORWARDED_ENTRIES ? hops.subList(hops.size() - MAX_FORWARDED_ENTRIES, hops.size()) : hops;
    }

    /** IP 리터럴만 받는다. 호스트 이름은 DNS 조회 없이 null을 돌려준다. */
    static InetAddress parseLiteral(String value) {
        if (value == null || value.isEmpty() || value.length() > 45) return null;
        if (!IPV4.matcher(value).matches() && !IPV6.matcher(value).matches()) return null;
        try {
            return InetAddress.getByName(value);
        } catch (UnknownHostException e) {
            return null;
        }
    }

    record Cidr(byte[] network, int prefix) {

        static Cidr parse(String text) {
            int slash = text.indexOf('/');
            InetAddress address = parseLiteral(slash < 0 ? text : text.substring(0, slash));
            if (address == null) throw new IllegalArgumentException("Invalid trusted proxy address: " + text);
            int bits = address.getAddress().length * 8;
            int prefix;
            try {
                prefix = slash < 0 ? bits : Integer.parseInt(text.substring(slash + 1));
            } catch (NumberFormatException e) {
                throw new IllegalArgumentException("Invalid trusted proxy prefix: " + text);
            }
            if (prefix < 1 || prefix > bits) {
                // /0은 모든 주소를 신뢰해 누구나 IP를 바꿀 수 있으므로 받지 않는다.
                throw new IllegalArgumentException("Trusted proxy prefix must be 1.." + bits + ": " + text);
            }
            return new Cidr(mask(address.getAddress(), prefix), prefix);
        }

        boolean contains(InetAddress address) {
            byte[] bytes = address.getAddress();
            return bytes.length == network.length && Arrays.equals(mask(bytes, prefix), network);
        }

        private static byte[] mask(byte[] bytes, int prefix) {
            byte[] masked = bytes.clone();
            for (int i = 0; i < masked.length; i++) {
                int keep = Math.max(0, Math.min(8, prefix - i * 8));
                masked[i] = (byte) (masked[i] & (0xFF << (8 - keep)));
            }
            return masked;
        }
    }
}
