// Step 5 helper: composite ML-DSA (RFC 10073) self-signed certificates with Bouncy Castle.
// Run: java -cp '/opt/bc/*' scripts/Composite.java <outdir> <alg>...
import java.io.FileWriter;
import java.math.BigInteger;
import java.nio.file.*;
import java.security.*;
import java.util.Date;
import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.asn1.x509.*;
import org.bouncycastle.cert.X509CertificateHolder;
import org.bouncycastle.cert.jcajce.*;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.bouncycastle.openssl.jcajce.JcaPEMWriter;
import org.bouncycastle.operator.jcajce.*;

public class Composite {
  public static void main(String[] args) throws Exception {
    Security.addProvider(new BouncyCastleProvider());
    Path out = Paths.get(args[0]);
    System.out.printf("%-28s %-22s %6s %6s %6s  %s%n", "alg", "OID", "pub", "sig", "cert", "BC verify");
    for (int i = 1; i < args.length; i++) {
      String alg = args[i];
      KeyPair kp = KeyPairGenerator.getInstance(alg, "BC").generateKeyPair();
      X500Name name = new X500Name("O=pqc-hsm-lab,CN=Composite Root " + alg);
      long now = System.currentTimeMillis();
      X509CertificateHolder cert = new JcaX509v3CertificateBuilder(name, BigInteger.valueOf(now), new Date(now),
              new Date(now + 3650L * 86400000L), name, kp.getPublic())
          .addExtension(Extension.basicConstraints, true, new BasicConstraints(true))
          .addExtension(Extension.keyUsage, true, new KeyUsage(KeyUsage.keyCertSign | KeyUsage.cRLSign))
          .build(new JcaContentSignerBuilder(alg).setProvider("BC").build(kp.getPrivate()));
      boolean ok = cert.isSignatureValid(new JcaContentVerifierProviderBuilder().setProvider("BC").build(kp.getPublic()));
      System.out.printf("%-28s %-22s %6d %6d %6d  %s%n", alg, cert.getSignatureAlgorithm().getAlgorithm(),
          cert.getSubjectPublicKeyInfo().getEncoded().length, cert.getSignature().length, cert.getEncoded().length,
          ok ? "OK" : "FAILED");
      try (JcaPEMWriter w = new JcaPEMWriter(new FileWriter(out.resolve(alg + ".crt").toFile()))) {
        w.writeObject(cert);
      }
    }
  }
}
