package com.bts.demoticketing.captcha;

public interface CaptchaVerifier {
    record Problem(String question,String answer) {}
    Problem create();
    boolean verify(String expectedDigest,String answer);
    /** 화면이 어떤 방식으로 캡차를 보여줄지 알려 주는 이름 (mock: 산술 문제, hcaptcha: hCaptcha 위젯). */
    default String provider(){return "mock";}
    /** 화면 위젯이 쓰는 공개 키. 서버가 직접 문제를 내는 방식이면 null. */
    default String siteKey(){return null;}
}
