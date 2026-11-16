package com.bts.demoticketing.captcha;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.*;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;

@Configuration
public class CaptchaConfiguration {
    @Bean
    @ConditionalOnProperty(name="demo.captcha.mode",havingValue="mock")
    CaptchaVerifier mockCaptchaVerifier(){return new MockCaptchaVerifier();}

    @Bean
    @ConditionalOnProperty(name="demo.captcha.mode",havingValue="hcaptcha")
    CaptchaVerifier hcaptchaVerifier(@Value("${demo.captcha.hcaptcha.site-key:}") String siteKey,
            @Value("${demo.captcha.hcaptcha.secret:}") String secret,
            @Value("${demo.captcha.hcaptcha.verify-url:https://api.hcaptcha.com/siteverify}") String verifyUrl){
        return new HCaptchaVerifier(siteKey,secret,verifyUrl);
    }
}
