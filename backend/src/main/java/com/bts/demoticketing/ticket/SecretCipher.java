package com.bts.demoticketing.ticket;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** TOTP 비밀키 저장용 AES-256-GCM. 저장 형식은 IV(12) || 암호문 || tag(16)이다. */
public final class SecretCipher {
    private static final int IV_BYTES=12,TAG_BITS=128;
    private static final SecureRandom RANDOM=new SecureRandom();
    private SecretCipher(){}
    /** context(티켓·기기 ID)는 AAD로 묶여 다른 행으로 옮긴 암호문은 복호화되지 않는다. */
    public static byte[] encrypt(byte[] key,byte[] secret,String context){
        try{
            byte[] iv=new byte[IV_BYTES];RANDOM.nextBytes(iv);
            byte[] sealed=cipher(Cipher.ENCRYPT_MODE,key,iv,context).doFinal(secret);
            byte[] out=Arrays.copyOf(iv,IV_BYTES+sealed.length);
            System.arraycopy(sealed,0,out,IV_BYTES,sealed.length);
            return out;
        }catch(GeneralSecurityException e){throw new IllegalStateException("Secret encryption failed");}
    }
    public static byte[] decrypt(byte[] key,byte[] stored,String context){
        try{
            if(stored==null||stored.length<=IV_BYTES+TAG_BITS/8)throw new GeneralSecurityException();
            return cipher(Cipher.DECRYPT_MODE,key,Arrays.copyOf(stored,IV_BYTES),context)
                    .doFinal(stored,IV_BYTES,stored.length-IV_BYTES);
        }catch(GeneralSecurityException e){throw new IllegalStateException("Secret decryption failed");}
    }
    private static Cipher cipher(int mode,byte[] key,byte[] iv,String context)throws GeneralSecurityException{
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(mode,new SecretKeySpec(key,"AES"),new GCMParameterSpec(TAG_BITS,iv));
        cipher.updateAAD(context.getBytes(StandardCharsets.UTF_8));
        return cipher;
    }
}
