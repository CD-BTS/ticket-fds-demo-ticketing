package com.bts.demoticketing.ticket;

import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.spec.ECGenParameterSpec;
import java.util.Base64;
import org.junit.jupiter.api.Test;
import com.bts.demoticketing.common.exception.ApiException;
import static org.junit.jupiter.api.Assertions.*;

class TicketCryptoTests {
    private static final byte[] RFC_SECRET="12345678901234567890".getBytes(StandardCharsets.US_ASCII);

    @Test void totpMatchesRfc6238Sha1VectorsTruncatedToSixDigits(){
        // RFC 6238 Appendix B의 8자리 값에서 뒤 6자리.
        assertEquals("287082",Totp.code(RFC_SECRET,Totp.counter(59)));
        assertEquals("081804",Totp.code(RFC_SECRET,Totp.counter(1111111109L)));
        assertEquals("050471",Totp.code(RFC_SECRET,Totp.counter(1111111111L)));
        assertEquals("005924",Totp.code(RFC_SECRET,Totp.counter(1234567890L)));
        assertEquals("279037",Totp.code(RFC_SECRET,Totp.counter(2000000000L)));
        assertEquals("353130",Totp.code(RFC_SECRET,Totp.counter(20000000000L)));
        assertEquals(1,Totp.counter(59));assertEquals(2,Totp.counter(60));
    }

    @Test void storedSecretIsBoundToItsKeyAndContextAndNeverEqualsPlaintext(){
        byte[] key=new byte[32],other=new byte[32];new SecureRandom().nextBytes(key);new SecureRandom().nextBytes(other);
        byte[] sealed=SecretCipher.encrypt(key,RFC_SECRET,"ticket:device");
        assertEquals(12+20+16,sealed.length);
        assertFalse(new String(sealed,StandardCharsets.ISO_8859_1).contains("12345678901234567890"));
        assertFalse(java.util.Arrays.equals(sealed,SecretCipher.encrypt(key,RFC_SECRET,"ticket:device")));
        assertArrayEquals(RFC_SECRET,SecretCipher.decrypt(key,sealed,"ticket:device"));
        assertThrows(IllegalStateException.class,()->SecretCipher.decrypt(key,sealed,"ticket:other-device"));
        assertThrows(IllegalStateException.class,()->SecretCipher.decrypt(other,sealed,"ticket:device"));
        sealed[20]^=1;
        assertThrows(IllegalStateException.class,()->SecretCipher.decrypt(key,sealed,"ticket:device"));
        assertThrows(IllegalStateException.class,()->SecretCipher.decrypt(key,null,"ticket:device"));
    }

    @Test void deviceSignatureAcceptsOnlyP256KeysAndWebCryptoFormatSignatures()throws Exception{
        KeyPair device=pair("secp256r1"),stranger=pair("secp256r1");
        byte[] spki=device.getPublic().getEncoded();
        assertTrue(DeviceSignature.validKey(spki));
        assertFalse(DeviceSignature.validKey(pair("secp384r1").getPublic().getEncoded()));
        assertFalse(DeviceSignature.validKey(new byte[91]));
        assertFalse(DeviceSignature.validKey(null));
        byte[] signature=sign(device.getPrivate(),"BTS1.message");
        assertEquals(64,signature.length);
        assertTrue(DeviceSignature.verify(spki,"BTS1.message",signature));
        assertFalse(DeviceSignature.verify(spki,"BTS1.other",signature));
        assertFalse(DeviceSignature.verify(stranger.getPublic().getEncoded(),"BTS1.message",signature));
        // DER 형식 서명과 길이가 다른 값은 검증하지 않는다.
        Signature der=Signature.getInstance("SHA256withECDSA");der.initSign(device.getPrivate());der.update("BTS1.message".getBytes(StandardCharsets.UTF_8));
        assertFalse(DeviceSignature.verify(spki,"BTS1.message",der.sign()));
        assertFalse(DeviceSignature.verify(spki,"BTS1.message",null));
    }

    @Test void settingsFailFastOnlyWhenEnabledAndDisabledFeatureIsUnavailable(){
        String key=Base64.getEncoder().encodeToString(new byte[32]);
        var disabled=new CheckInSettings(false,"","",java.time.Duration.ofHours(2),java.time.Duration.ofMinutes(2),java.time.Duration.ofSeconds(15),3);
        assertEquals("SERVICE_UNAVAILABLE",assertThrows(ApiException.class,disabled::requireEnabled).getResponseCode().getCode());
        assertDoesNotThrow(()->new CheckInSettings(true,key,"gate-key-0123456789",java.time.Duration.ofHours(2),java.time.Duration.ofMinutes(2),java.time.Duration.ofSeconds(15),3).requireEnabled());
        for(String bad:new String[]{"","not base64!",Base64.getEncoder().encodeToString(new byte[16])}){
            var error=assertThrows(IllegalArgumentException.class,()->new CheckInSettings(true,bad,"gate-key-0123456789",java.time.Duration.ofHours(2),java.time.Duration.ofMinutes(2),java.time.Duration.ofSeconds(15),3));
            assertFalse(!bad.isEmpty()&&error.getMessage().contains(bad));
        }
        assertThrows(IllegalArgumentException.class,()->new CheckInSettings(true,key,"short",java.time.Duration.ofHours(2),java.time.Duration.ofMinutes(2),java.time.Duration.ofSeconds(15),3));
    }

    static KeyPair pair(String curve)throws GeneralSecurityException{
        KeyPairGenerator generator=KeyPairGenerator.getInstance("EC");generator.initialize(new ECGenParameterSpec(curve));
        return generator.generateKeyPair();
    }
    static byte[] sign(PrivateKey key,String message)throws GeneralSecurityException{
        Signature signer=Signature.getInstance("SHA256withECDSAinP1363Format");signer.initSign(key);
        signer.update(message.getBytes(StandardCharsets.UTF_8));return signer.sign();
    }
}
