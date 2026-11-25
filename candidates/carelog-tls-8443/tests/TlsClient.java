// Core-like client for the transition tests. Uses the JDK HttpClient, the derived truststore (cacerts produced by
// trust-init) and explicit HTTPS endpoint identification, so a SAN or hostname mismatch fails like it would in Core.
// Usage: java TlsClient.java <METHOD> <URL> <truststore|-> <expected-status> [headers as Name=Value ...]
// Prints "STATUS <code> <first 120 chars of body>" and exits 0 when the status matches, 1 otherwise, 2 on TLS/transport error.
// Secrets in headers are test values only. TLSCLIENT_PROXY=host:port (optional env) uses an HTTP CONNECT proxy.
import java.io.FileInputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.KeyStore;
import java.time.Duration;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.TrustManagerFactory;

public class TlsClient {
    public static void main(String[] args) throws Exception {
        String method = args[0];
        URI uri = URI.create(args[1]);
        String trust = args[2];
        int expected = Integer.parseInt(args[3]);

        HttpClient.Builder builder = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10));
        // Optional: TLSCLIENT_PROXY=host:port routes the request through an HTTP CONNECT proxy (external-host measurement only).
        String proxy = System.getenv("TLSCLIENT_PROXY");
        if (proxy != null && !proxy.isEmpty()) {
            int colon = proxy.lastIndexOf(':');
            builder.proxy(java.net.ProxySelector.of(new java.net.InetSocketAddress(
                proxy.substring(0, colon), Integer.parseInt(proxy.substring(colon + 1)))));
        }
        if (uri.getScheme().equals("https")) {
            SSLContext ctx;
            if (trust.equals("-")) {
                ctx = SSLContext.getDefault();
            } else {
                KeyStore ks = KeyStore.getInstance("JKS");
                try (FileInputStream in = new FileInputStream(trust)) {
                    ks.load(in, "changeit".toCharArray());
                }
                TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
                tmf.init(ks);
                ctx = SSLContext.getInstance("TLS");
                ctx.init(null, tmf.getTrustManagers(), null);
            }
            SSLParameters params = new SSLParameters();
            params.setEndpointIdentificationAlgorithm("HTTPS");
            builder.sslContext(ctx).sslParameters(params);
        }

        HttpRequest.Builder req = HttpRequest.newBuilder(uri).timeout(Duration.ofSeconds(15));
        for (int i = 4; i < args.length; i++) {
            int eq = args[i].indexOf('=');
            req.header(args[i].substring(0, eq), args[i].substring(eq + 1));
        }
        if (method.equals("PUT")) {
            req.header("Content-Type", "application/json").PUT(HttpRequest.BodyPublishers.ofString("{}"));
        } else {
            req.GET();
        }

        try {
            HttpResponse<String> resp = builder.build().send(req.build(), HttpResponse.BodyHandlers.ofString());
            String body = resp.body().replace('\n', ' ');
            System.out.println("STATUS " + resp.statusCode() + " " + body.substring(0, Math.min(120, body.length())));
            System.exit(resp.statusCode() == expected ? 0 : 1);
        } catch (java.io.IOException e) {
            System.out.println("TRANSPORT " + e.getClass().getSimpleName() + ": " + e.getMessage());
            System.exit(2);
        }
    }
}
