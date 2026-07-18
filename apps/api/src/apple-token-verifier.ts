import {
  createRemoteJWKSet,
  jwtVerify
} from "jose";

export const appleIdentityIssuer = "https://appleid.apple.com";

export interface VerifiedAppleIdentity {
  issuer: string;
  subject: string;
  nonce: string;
  email?: string;
}

export interface AppleIdentityTokenVerifier {
  verify(identityToken: string): Promise<VerifiedAppleIdentity>;
}

export class JoseAppleIdentityTokenVerifier implements AppleIdentityTokenVerifier {
  private readonly appleJwks = createRemoteJWKSet(
    new URL("https://appleid.apple.com/auth/keys")
  );

  constructor(private readonly audience: string) {}

  async verify(identityToken: string): Promise<VerifiedAppleIdentity> {
    const { payload } = await jwtVerify(identityToken, this.appleJwks, {
      algorithms: ["RS256"],
      issuer: appleIdentityIssuer,
      audience: this.audience,
      requiredClaims: ["sub", "nonce", "iat", "exp"],
      clockTolerance: 5,
      maxTokenAge: "10m"
    });

    if (
      typeof payload.iss !== "string" ||
      typeof payload.sub !== "string" ||
      typeof payload.nonce !== "string"
    ) {
      throw new Error("Apple identity token is missing required identity claims");
    }

    return {
      issuer: payload.iss,
      subject: payload.sub,
      nonce: payload.nonce,
      ...(typeof payload.email === "string" ? { email: payload.email } : {})
    };
  }
}
