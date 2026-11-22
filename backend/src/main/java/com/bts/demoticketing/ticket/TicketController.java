package com.bts.demoticketing.ticket;

import java.util.List;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import com.bts.demoticketing.common.response.*;
import com.bts.demoticketing.ticket.TicketDeviceService.*;
import com.bts.demoticketing.user.service.DemoAuthService;

@RestController
@RequestMapping("/api/v1")
public class TicketController {
    private final DemoAuthService auth;
    private final TicketDeviceService devices;
    private final CheckInService checkIns;
    private final GateAuth gate;
    public TicketController(DemoAuthService auth,TicketDeviceService devices,CheckInService checkIns,GateAuth gate){
        this.auth=auth;this.devices=devices;this.checkIns=checkIns;this.gate=gate;
    }
    public record DeviceRequest(@NotBlank @Size(max=36) String challengeId,@NotBlank @Size(max=200) String publicKey,
            @NotBlank @Size(max=100) String proof){}
    public record CheckInRequest(@NotBlank @Size(max=400) String qr){}
    public record CheckInProofRequest(@NotBlank @Size(max=36) String checkInId,@NotBlank @Size(max=100) String proof){}

    @GetMapping("/bookings/{bookingId}/tickets")
    public ApiResponse<List<TicketView>> tickets(@PathVariable @NotBlank @Size(max=100) String bookingId,HttpServletRequest request){
        return ApiResponse.success(devices.tickets(bookingId,auth.require(request)));
    }
    @PostMapping("/tickets/{ticketId}/device-challenges")
    public ResponseEntity<ApiResponse<ChallengeView>> challenge(@PathVariable @NotBlank @Size(max=100) String ticketId,HttpServletRequest request){
        return ResponseEntity.status(201).body(ApiResponse.success(ResponseCode.CREATED,devices.challenge(ticketId,auth.require(request))));
    }
    /** 최초 기기 등록. 이미 등록된 티켓은 409/DEVICE_ALREADY_REGISTERED다. */
    @PostMapping("/tickets/{ticketId}/device")
    public ResponseEntity<ApiResponse<Enrollment>> register(@PathVariable @NotBlank @Size(max=100) String ticketId,
            @Valid @RequestBody DeviceRequest body,HttpServletRequest request){
        Enrollment result=devices.enroll(ticketId,auth.require(request),body.challengeId(),body.publicKey(),body.proof(),false);
        return ResponseEntity.status(201).body(ApiResponse.success(ResponseCode.CREATED,result));
    }
    /** 기기 변경. 기존 바인딩과 TOTP 비밀키를 폐기하고 변경 횟수를 차감한다. */
    @PostMapping("/tickets/{ticketId}/device/change")
    public ApiResponse<Enrollment> change(@PathVariable @NotBlank @Size(max=100) String ticketId,
            @Valid @RequestBody DeviceRequest body,HttpServletRequest request){
        return ApiResponse.success(devices.enroll(ticketId,auth.require(request),body.challengeId(),body.publicKey(),body.proof(),true));
    }
    /** 검표 1단계(검표기 전용, X-Gate-Key). QR을 검증하고 등록 기기가 서명할 일회성 챌린지를 발급한다. 입장 처리는 하지 않는다. */
    @PostMapping("/check-ins")
    public ResponseEntity<ApiResponse<CheckInService.Scan>> scan(@Valid @RequestBody CheckInRequest body,HttpServletRequest request){
        gate.require(request);
        return ResponseEntity.status(201).body(ApiResponse.success(ResponseCode.CREATED,checkIns.scan(body.qr())));
    }
    /** 검표기 전용. 등록 기기의 응답 결과를 조회한다. */
    @GetMapping("/check-ins/{checkInId}")
    public ApiResponse<CheckInService.Scan> scanStatus(@PathVariable @NotBlank @Size(max=36) String checkInId,HttpServletRequest request){
        gate.require(request);
        return ApiResponse.success(checkIns.status(checkInId));
    }
    /** 등록 기기가 QR을 표시하는 동안 조회한다. 대기 중인 챌린지가 없으면 data는 null이다. */
    @GetMapping("/tickets/{ticketId}/check-in-challenge")
    public ApiResponse<CheckInService.DeviceChallenge> checkInChallenge(@PathVariable @NotBlank @Size(max=100) String ticketId,HttpServletRequest request){
        return ApiResponse.success(checkIns.pending(ticketId,auth.require(request)));
    }
    /** 검표 2단계. 등록 기기의 개인키 서명이 맞을 때만 입장이 확정된다. */
    @PostMapping("/tickets/{ticketId}/check-in-proofs")
    public ApiResponse<CheckInService.Result> checkInProof(@PathVariable @NotBlank @Size(max=100) String ticketId,
            @Valid @RequestBody CheckInProofRequest body,HttpServletRequest request){
        return ApiResponse.success(checkIns.confirm(ticketId,auth.require(request),body.checkInId(),body.proof()));
    }
}
