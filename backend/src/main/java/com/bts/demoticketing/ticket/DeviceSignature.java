package com.bts.demoticketing.ticket;

import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.spec.X509EncodedKeySpec;
import java.util.Arrays;
import java.util.HexFormat;

/** 기기 공개키(ECDSA P-256 SPKI)와 Web Crypto 형식(r||s 64바이트) 서명 검증. */
public final class DeviceSignature {
    // P-256 비압축 공개키의 SPKI DER은 고정 26바이트 헤더 + 0x04||X||Y(65바이트)다.
    private static final byte[] P256_SPKI_PREFIX=HexFormat.of().parseHex("3059301306072a8648ce3d020106082a8648ce3d030107034200");
    private static final int SPKI_BYTES=91,SIGNATURE_BYTES=64;
    private DeviceSignature(){}
    public static boolean validKey(byte[] spki){
        if(spki==null||spki.length!=SPKI_BYTES||spki[P256_SPKI_PREFIX.length]!=0x04
                ||!Arrays.equals(spki,0,P256_SPKI_PREFIX.length,P256_SPKI_PREFIX,0,P256_SPKI_PREFIX.length))return false;
        try{key(spki);return true;}catch(GeneralSecurityException e){return false;}
    }
    public static boolean verify(byte[] spki,String message,byte[] signature){
        if(signature==null||signature.length!=SIGNATURE_BYTES)return false;
        try{
            Signature verifier=Signature.getInstance("SHA256withECDSAinP1363Format");
            verifier.initVerify(key(spki));
            verifier.update(message.getBytes(StandardCharsets.UTF_8));
            return verifier.verify(signature);
        }catch(GeneralSecurityException e){return false;}
    }
    private static PublicKey key(byte[] spki)throws GeneralSecurityException{
        return KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(spki));
    }
}
