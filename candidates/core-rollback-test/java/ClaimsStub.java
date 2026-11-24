import com.sun.net.httpserver.HttpServer;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

/**
 * Stub for the Carelog product-claims endpoint that Core calls during login, refresh and token rotation
 * (GET /api/v1/internal/identity/claims/{accountId}). Returns an eligible MANAGER claim for any account.
 * Test helper only: the identifiers are fixed, throwaway values and no credential is checked.
 */
public final class ClaimsStub {
    private static final String ORG = "22222222-2222-4222-8222-222222222222";
    private static final String PUBLIC_ID = "33333333-3333-4333-8333-333333333333";
    private static final String PREFIX = "/api/v1/internal/identity/claims/";

    public static void main(String[] args) throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress(Integer.parseInt(args[0])), 0);
        server.createContext("/", exchange -> {
            String path = exchange.getRequestURI().getPath();
            int status;
            String body;
            if ("/health".equals(path)) {
                status = 200;
                body = "{\"status\":\"ok\"}";
            } else if (path.startsWith(PREFIX)) {
                status = 200;
                body = "{\"organizationId\":\"" + ORG + "\",\"role\":\"MANAGER\",\"publicId\":\"" + PUBLIC_ID + "\"}";
            } else {
                status = 404;
                body = "{}";
            }
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(status, bytes.length);
            exchange.getResponseBody().write(bytes);
            exchange.close();
        });
        server.start();
    }
}
