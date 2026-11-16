package com.bts.demoticketing.ticket;

import java.security.GeneralSecurityException;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** RFC 6238 TOTP (HMAC-SHA1, 6자리, 30초 step). */
public final class Totp {
    public static final int PERIOD_SECONDS=30,DIGITS=6,SECRET_BYTES=20;
    private Totp(){}
    public static long counter(long epochSeconds){return Math.floorDiv(epochSeconds,PERIOD_SECONDS);}
    public static String code(byte[] secret,long counter){
        try{
            Mac mac=Mac.getInstance("HmacSHA1");
            mac.init(new SecretKeySpec(secret,"HmacSHA1"));
            byte[] message=new byte[8];
            for(int i=7;i>=0;i--){message[i]=(byte)counter;counter>>>=8;}
            byte[] hash=mac.doFinal(message);
            int offset=hash[hash.length-1]&0x0f;
            int binary=((hash[offset]&0x7f)<<24)|((hash[offset+1]&0xff)<<16)|((hash[offset+2]&0xff)<<8)|(hash[offset+3]&0xff);
            return String.format("%06d",binary%1_000_000);
        }catch(GeneralSecurityException e){throw new IllegalStateException("TOTP unavailable");}
    }
}
