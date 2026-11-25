package com.bts.demoticketing.attempt;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.*;
import com.bts.demoticketing.common.exception.ApiException;
import com.bts.demoticketing.common.response.ApiResponse;
import com.bts.demoticketing.common.response.ResponseCode;
import com.bts.demoticketing.common.web.ClientIpResolver;
import com.bts.demoticketing.user.service.DemoAuthService;

@RestController
@RequestMapping("/api/v1")
public class AttemptController {
    private static final Logger log=LoggerFactory.getLogger(AttemptController.class);
    private final AttemptService service;private final DemoAuthService auth;private final ClientIpResolver clientIp;
    public AttemptController(AttemptService service,DemoAuthService auth,ClientIpResolver clientIp){this.service=service;this.auth=auth;this.clientIp=clientIp;}
    public record Start(@Size(max=40) String clientOccurredAt){}
    public record Transition(@NotBlank String transitionId,@NotBlank String stage,@NotBlank String status){}
    public record Capabilities(boolean enabled){}
    /**
     * 예매 시도 이벤트에 실을 클라이언트 IP (#68). 예매 확정(BOOKING)과 같은 ClientIpResolver 기준을 쓴다.
     * 주소를 해석하지 못하면 예매 시도를 막지 않고 ipAddress만 뺀다(BTS는 IP 없는 시도로 감점 판단을 하지 않는다).
     * 예매 확정은 지금처럼 해석 실패를 400으로 거부한다.
     */
    private String clientIp(HttpServletRequest request){
        try{return clientIp.resolve(request);}
        catch(ApiException e){
            // ClientIpResolver가 주소 해석 실패에 쓰는 코드만 넘어간다. 다른 오류는 숨기지 않는다.
            if(e.getResponseCode()!=ResponseCode.INVALID_REQUEST)throw e;
            log.warn("Client IP not resolved for booking attempt; ipAddress omitted");
            return null;
        }
    }
    @GetMapping("/booking-attempts/capabilities")
    public ApiResponse<Capabilities> capabilities(){return ApiResponse.success(new Capabilities(service.enabled()));}
    @PutMapping("/concerts/{concertId}/booking-attempts/{attemptId}")
    public ApiResponse<AttemptService.Snapshot> start(@PathVariable @Size(max=50) String concertId,@PathVariable String attemptId,
            @Valid @RequestBody Start body,HttpServletRequest request){
        var user=auth.require(request);
        return ApiResponse.success(service.start(concertId,attemptId,user,body.clientOccurredAt(),clientIp(request)));
    }
    @GetMapping("/booking-attempts/{attemptId}")
    public ApiResponse<AttemptService.Snapshot> get(@PathVariable String attemptId,HttpServletRequest request){
        return ApiResponse.success(service.get(attemptId,auth.require(request)));
    }
    @PostMapping("/booking-attempts/{attemptId}/transitions")
    public ApiResponse<AttemptService.Snapshot> transition(@PathVariable String attemptId,@Valid @RequestBody Transition body,HttpServletRequest request){
        var user=auth.require(request);
        return ApiResponse.success(service.client(attemptId,user,body.transitionId(),body.stage(),body.status(),clientIp(request)));
    }
}
