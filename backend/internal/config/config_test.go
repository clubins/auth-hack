package config

import (
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/clubins/auth-hack/backend/internal/grants"
)

func TestParse(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		want    Config
		wantErr bool
	}{
		{
			name: "defaults when env is empty",
			env:  nil,
			want: Config{
				Port:         DefaultPort,
				LogLevel:     slog.LevelInfo,
				IssuerURL:    DefaultIssuerURL,
				Audience:     DefaultAudience,
				JWKSCacheTTL: DefaultJWKSCacheTTL,
				GrantMinTTL:  DefaultGrantMinTTL,
				GrantMaxTTL:  DefaultGrantMaxTTL,
			},
		},
		{
			name: "blank values fall back to defaults",
			env:  map[string]string{"PORT": "  ", "LOG_LEVEL": "", "ISSUER_URL": "", "AUDIENCE": "", "JWKS_URL": "", "JWKS_CACHE_TTL": "", "GRANT_MIN_TTL": "", "GRANT_MAX_TTL": ""},
			want: Config{
				Port:         DefaultPort,
				LogLevel:     slog.LevelInfo,
				IssuerURL:    DefaultIssuerURL,
				Audience:     DefaultAudience,
				JWKSCacheTTL: DefaultJWKSCacheTTL,
				GrantMinTTL:  DefaultGrantMinTTL,
				GrantMaxTTL:  DefaultGrantMaxTTL,
			},
		},
		{
			name: "all variables set",
			env: map[string]string{
				"PORT":           "9000",
				"LOG_LEVEL":      "DEBUG",
				"ISSUER_URL":     "https://login.clubins.de",
				"AUDIENCE":       "https://api.clubins.de",
				"JWKS_URL":       "https://login.clubins.de/oidc/keys",
				"JWKS_CACHE_TTL": "30m",
				"GRANT_MIN_TTL":  "1s",
				"GRANT_MAX_TTL":  "2h",
			},
			want: Config{
				Port:         9000,
				LogLevel:     slog.LevelDebug,
				IssuerURL:    "https://login.clubins.de",
				Audience:     "https://api.clubins.de",
				JWKSURL:      "https://login.clubins.de/oidc/keys",
				JWKSCacheTTL: 30 * time.Minute,
				GrantMinTTL:  1 * time.Second,
				GrantMaxTTL:  2 * time.Hour,
			},
		},
		{
			name:    "port zero is rejected",
			env:     map[string]string{"PORT": "0"},
			wantErr: true,
		},
		{
			name:    "port above 65535 is rejected",
			env:     map[string]string{"PORT": "70000"},
			wantErr: true,
		},
		{
			name:    "non-numeric port is rejected",
			env:     map[string]string{"PORT": "eighty"},
			wantErr: true,
		},
		{
			name:    "unknown log level is rejected",
			env:     map[string]string{"LOG_LEVEL": "verbose"},
			wantErr: true,
		},
		{
			name:    "issuer without http scheme is rejected",
			env:     map[string]string{"ISSUER_URL": "ftp://login.clubins.de"},
			wantErr: true,
		},
		{
			name:    "issuer without host is rejected",
			env:     map[string]string{"ISSUER_URL": "https://"},
			wantErr: true,
		},
		{
			name:    "invalid audience is rejected",
			env:     map[string]string{"AUDIENCE": "not a url"},
			wantErr: true,
		},
		{
			name:    "invalid jwks url is rejected",
			env:     map[string]string{"JWKS_URL": "no-scheme.example"},
			wantErr: true,
		},
		{
			name:    "non-duration jwks cache ttl is rejected",
			env:     map[string]string{"JWKS_CACHE_TTL": "soon"},
			wantErr: true,
		},
		{
			name:    "zero jwks cache ttl is rejected",
			env:     map[string]string{"JWKS_CACHE_TTL": "0s"},
			wantErr: true,
		},
		{
			name:    "negative jwks cache ttl is rejected",
			env:     map[string]string{"JWKS_CACHE_TTL": "-5m"},
			wantErr: true,
		},
		{
			name:    "non-duration grant min ttl is rejected",
			env:     map[string]string{"GRANT_MIN_TTL": "soon"},
			wantErr: true,
		},
		{
			name:    "zero grant min ttl is rejected",
			env:     map[string]string{"GRANT_MIN_TTL": "0s"},
			wantErr: true,
		},
		{
			name:    "negative grant max ttl is rejected",
			env:     map[string]string{"GRANT_MAX_TTL": "-1h"},
			wantErr: true,
		},
		{
			name:    "grant min ttl above max is rejected",
			env:     map[string]string{"GRANT_MIN_TTL": "25h", "GRANT_MAX_TTL": "24h"},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			lookup := func(key string) (string, bool) {
				v, ok := tt.env[key]
				return v, ok
			}

			got, err := parse(lookup)
			if (err != nil) != tt.wantErr {
				t.Fatalf("parse() error = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				return
			}
			if got != tt.want {
				t.Fatalf("parse() = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestParseLogLevel(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		want    slog.Level
		wantErr bool
	}{
		{name: "debug", raw: "debug", want: slog.LevelDebug},
		{name: "info trimmed and case-insensitive", raw: "  INFO ", want: slog.LevelInfo},
		{name: "warn", raw: "warn", want: slog.LevelWarn},
		{name: "error", raw: "error", want: slog.LevelError},
		{name: "empty is not a level", raw: "", wantErr: true},
		{name: "typo is not a level", raw: "warning", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ParseLogLevel(tt.raw)
			if (err != nil) != tt.wantErr {
				t.Fatalf("ParseLogLevel(%q) error = %v, wantErr %v", tt.raw, err, tt.wantErr)
			}
			if !tt.wantErr && got != tt.want {
				t.Fatalf("ParseLogLevel(%q) = %v, want %v", tt.raw, got, tt.want)
			}
		})
	}
}

func TestVenueReadScope(t *testing.T) {
	// The scope is a public string constant derived from the audience, so
	// guard wiring and client configuration always agree on it.
	if got := VenueReadScope; got != "https://api.clubins.de/venues:read" {
		t.Fatalf("VenueReadScope = %q, want %q", got, "https://api.clubins.de/venues:read")
	}
}

// TestGrantTTLDefaultsAgree pins the config package's grant-TTL defaults to
// the grants package's: the two must move together or a config default and
// the enforced bound would silently diverge.
func TestGrantTTLDefaultsAgree(t *testing.T) {
	if DefaultGrantMinTTL != grants.MinTTL {
		t.Fatalf("DefaultGrantMinTTL = %s, grants.MinTTL = %s", DefaultGrantMinTTL, grants.MinTTL)
	}
	if DefaultGrantMaxTTL != grants.MaxTTL {
		t.Fatalf("DefaultGrantMaxTTL = %s, grants.MaxTTL = %s", DefaultGrantMaxTTL, grants.MaxTTL)
	}
}

func TestFromEnv(t *testing.T) {
	t.Setenv("PORT", "7000")
	t.Setenv("LOG_LEVEL", "warn")

	cfg, err := FromEnv()
	if err != nil {
		t.Fatalf("FromEnv() error = %v", err)
	}
	if cfg.Port != 7000 {
		t.Fatalf("Port = %d, want %d", cfg.Port, 7000)
	}
	if cfg.LogLevel != slog.LevelWarn {
		t.Fatalf("LogLevel = %v, want %v", cfg.LogLevel, slog.LevelWarn)
	}
}

func TestAddr(t *testing.T) {
	cfg := Config{Port: 8080}
	if got := cfg.Addr(); got != ":8080" {
		t.Fatalf("Addr() = %q, want %q", got, ":8080")
	}
	if !strings.HasPrefix(cfg.Addr(), ":") {
		t.Fatal("Addr() must start with a colon")
	}
}
