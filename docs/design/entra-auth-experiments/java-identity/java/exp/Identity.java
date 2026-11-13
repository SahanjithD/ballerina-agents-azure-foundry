package exp;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenCredential;
import com.azure.core.credential.TokenRequestContext;
import com.azure.core.http.HttpClient;
import com.azure.core.http.netty.NettyAsyncHttpClientBuilder;
import com.azure.identity.ClientSecretCredentialBuilder;
import com.azure.identity.ManagedIdentityCredentialBuilder;
import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BString;
import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslContextBuilder;

import java.io.File;
import java.time.OffsetDateTime;

/**
 * Proof glue: gets a token through Java azure-identity, optionally with an HTTP client that trusts a PEM CA
 * bundle (the SSL_CERT_FILE case). Returns only the token length and lifetime, never the token.
 */
public final class Identity {
    private Identity() {
    }

    // kind: "secret" (service principal against authorityHost) or "mi" (managed identity from env vars)
    public static Object token(BString kind, BString scope, BString caBundle, BString authorityHost) {
        try {
            HttpClient httpClient = caBundle.getValue().isEmpty() ? null : trustingClient(caBundle.getValue());
            TokenCredential credential;
            if ("secret".equals(kind.getValue())) {
                ClientSecretCredentialBuilder b = new ClientSecretCredentialBuilder()
                        .authorityHost(authorityHost.getValue())
                        .tenantId("fake-tenant").clientId("fake-client").clientSecret("fake-secret")
                        .disableInstanceDiscovery();
                if (httpClient != null) {
                    b.httpClient(httpClient);
                }
                credential = b.build();
            } else {
                ManagedIdentityCredentialBuilder b = new ManagedIdentityCredentialBuilder();
                if (httpClient != null) {
                    b.httpClient(httpClient);
                }
                credential = b.build();
            }
            AccessToken token = credential.getTokenSync(new TokenRequestContext().addScopes(scope.getValue()));
            long seconds = token.getExpiresAt().toEpochSecond() - OffsetDateTime.now().toEpochSecond();
            return StringUtils.fromString("ok: tokenLength=" + token.getToken().length() + " expiresIn~" + seconds + "s");
        } catch (Throwable e) {
            Throwable root = e;
            while (root.getCause() != null && root.getCause() != root) {
                root = root.getCause();
            }
            String msg = e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage())
                    + " | root: " + root.getClass().getSimpleName() + ": " + String.valueOf(root.getMessage());
            return ErrorCreator.createError(StringUtils.fromString(msg.length() > 400 ? msg.substring(0, 400) : msg));
        }
    }

    private static HttpClient trustingClient(String pemBundle) throws Exception {
        SslContext ssl = SslContextBuilder.forClient().trustManager(new File(pemBundle)).build();
        reactor.netty.http.client.HttpClient reactorClient =
                reactor.netty.http.client.HttpClient.create().secure(spec -> spec.sslContext(ssl));
        return new NettyAsyncHttpClientBuilder(reactorClient).build();
    }
}
