package auth

import (
	"encoding/json"
	"testing"
)

// TestParseJWKS pins the strict-validation rules: every entry must be a
// fully usable, algorithm-pinned asymmetric signing key, and one bad entry
// fails the whole set so a degraded cache can never pass as complete.
func TestParseJWKS(t *testing.T) {
	tests := []struct {
		name     string
		raw      string         // when set, parsed directly
		doc      map[string]any // otherwise marshaled and parsed
		wantErr  bool
		wantKids []string
	}{
		{
			name:     "rsa and ec keys parse",
			doc:      map[string]any{"keys": []any{rsaJWK("rsa-1"), ecdsaJWK("ec-1")}},
			wantKids: []string{"rsa-1", "ec-1"},
		},
		{
			name:    "malformed json fails the fetch",
			raw:     "{not json",
			wantErr: true,
		},
		{
			name:    "key array missing fails",
			raw:     `{"issuer":"x"}`,
			wantErr: true,
		},
		{
			name:    "empty key set fails",
			doc:     map[string]any{"keys": []any{}},
			wantErr: true,
		},
		{
			name:    "symmetric key type fails the set",
			doc:     map[string]any{"keys": []any{rsaJWK("rsa-1"), map[string]any{"kty": "oct", "kid": "sym", "k": "AAAA"}}},
			wantErr: true,
		},
		{
			name:    "key without kid fails the set",
			doc:     map[string]any{"keys": []any{map[string]any{"kty": "RSA", "n": "AA", "e": "AQAB"}}},
			wantErr: true,
		},
		{
			name:    "rsa key without modulus fails",
			doc:     map[string]any{"keys": []any{map[string]any{"kty": "RSA", "kid": "k", "e": "AQAB"}}},
			wantErr: true,
		},
		{
			name:    "rsa key without exponent fails",
			doc:     map[string]any{"keys": []any{map[string]any{"kty": "RSA", "kid": "k", "n": "AA"}}},
			wantErr: true,
		},
		{
			name:    "bad base64 modulus fails",
			doc:     map[string]any{"keys": []any{map[string]any{"kty": "RSA", "kid": "k", "n": "!!!", "e": "AQAB"}}},
			wantErr: true,
		},
		{
			name:    "degenerate zero modulus fails",
			doc:     map[string]any{"keys": []any{map[string]any{"kty": "RSA", "kid": "k", "n": "AA", "e": "AQAB"}}},
			wantErr: true,
		},
		{
			name:    "rsa exponent below the minimum fails",
			doc:     map[string]any{"keys": []any{map[string]any{"kty": "RSA", "kid": "k", "n": "AQAB", "e": "Ag"}}},
			wantErr: true,
		},
		{
			name:    "ec key without curve fails",
			doc:     map[string]any{"keys": []any{map[string]any{"kty": "EC", "kid": "k", "x": "AA", "y": "AA"}}},
			wantErr: true,
		},
		{
			name:    "unsupported curve fails",
			doc:     map[string]any{"keys": []any{map[string]any{"kty": "EC", "kid": "k", "crv": "secp256k1", "x": "AA", "y": "AA"}}},
			wantErr: true,
		},
		{
			name:    "ec key without coordinates fails",
			doc:     map[string]any{"keys": []any{map[string]any{"kty": "EC", "kid": "k", "crv": "P-256"}}},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			raw := tt.raw
			if raw == "" {
				b, err := json.Marshal(tt.doc)
				if err != nil {
					t.Fatalf("marshal doc: %v", err)
				}
				raw = string(b)
			}
			keys, err := parseJWKS([]byte(raw))
			if (err != nil) != tt.wantErr {
				t.Fatalf("parseJWKS() error = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				return
			}
			for _, kid := range tt.wantKids {
				if _, ok := keys[kid]; !ok {
					t.Fatalf("parsed keys missing kid %q: %v", kid, keys)
				}
			}
		})
	}
}

// TestParseJWKSPinsAlgorithm verifies the stored algorithm pin that the
// keyfunc later enforces against the token header.
func TestParseJWKSPinsAlgorithm(t *testing.T) {
	doc, err := json.Marshal(map[string]any{"keys": []any{rsaJWK("rsa-1"), ecdsaJWK("ec-1")}})
	if err != nil {
		t.Fatalf("marshal doc: %v", err)
	}
	keys, err := parseJWKS(doc)
	if err != nil {
		t.Fatalf("parseJWKS: %v", err)
	}
	if keys["rsa-1"].alg != "RS256" {
		t.Fatalf("rsa key alg pin = %q, want RS256", keys["rsa-1"].alg)
	}
	if keys["ec-1"].alg != "ES256" {
		t.Fatalf("ec key alg pin = %q, want ES256", keys["ec-1"].alg)
	}
}
