# OAuth2 Proxy and Istio Request Flow

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant DNS as Public DNS
    participant Gateway as Azure LB and Istio Gateway
    participant Authz as Envoy ext_authz
    participant Proxy as OAuth2 Proxy
    participant Entra as Microsoft Entra ID
    participant Store as AKS Store Front

    User->>DNS: Resolve demo.dcasati.net
    DNS-->>User: 20.118.183.185
    User->>Gateway: GET / over HTTPS
    Gateway->>Authz: Apply CUSTOM AuthorizationPolicy
    Authz->>Proxy: Authorization check with cookies and headers
    Proxy-->>Authz: 302 sign-in response and CSRF cookie
    Authz-->>Gateway: Deny request with redirect response
    Gateway-->>User: 302 to Microsoft Entra ID

    User->>Entra: Sign in and grant requested OIDC scopes
    Entra-->>User: 302 /oauth2/callback with authorization code
    User->>Gateway: GET /oauth2/callback
    Note over Gateway,Authz: /oauth2/* bypasses the CUSTOM policy
    Gateway->>Proxy: Route callback through HTTPRoute
    Proxy->>Entra: Exchange code, PKCE verifier, and federated assertion
    Entra-->>Proxy: ID and access tokens
    Proxy-->>User: Set secure session cookie and redirect to /

    User->>Gateway: GET / with session cookie
    Gateway->>Authz: Apply CUSTOM AuthorizationPolicy
    Authz->>Proxy: Validate session cookie
    Proxy-->>Authz: 202 allow with identity headers
    Authz-->>Gateway: Allow request
    Gateway->>Store: Route directly to store-front:80
    Store-->>Gateway: Application response
    Gateway-->>User: Authenticated application response
```

The ACME path `/.well-known/acme-challenge/*` also bypasses external authorization so cert-manager can issue and renew the TLS certificate for `demo.dcasati.net`.