// Package config loads the API's environment-driven settings.
//
// Variables (all optional — defaults follow the build spec's local stack):
//
//	PORT       listen port (default 8080)
//	LOG_LEVEL  log level: debug|info|warn|error (default info)
//	ISSUER_URL OIDC issuer (default http://localhost:3301/oidc, local Logto)
//	AUDIENCE   expected access-token audience (default https://api.clubins.de)
//	JWKS_URL   optional JWKS override; empty means issuer discovery
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"strconv"
	"strings"
)

const (
	// DefaultPort is the listen port when PORT is unset.
	DefaultPort = 8080
	// DefaultIssuerURL is the local Logto issuer from the build spec's
	// compose stack; production overrides it with https://login.clubins.de.
	DefaultIssuerURL = "http://localhost:3301/oidc"
	// DefaultAudience is the access-token audience the API expects.
	DefaultAudience = "https://api.clubins.de"
)

// Config is the API's runtime configuration, validated at parse time.
type Config struct {
	Port      int
	LogLevel  slog.Level
	IssuerURL string
	Audience  string
	// JWKSURL optionally overrides the OIDC discovery JWKS location;
	// empty means derive it from IssuerURL when the guard lands.
	JWKSURL string
}

// FromEnv parses the process environment.
func FromEnv() (Config, error) {
	return parse(os.LookupEnv)
}

// Addr is the listen address, ":<port>".
func (c Config) Addr() string {
	return ":" + strconv.Itoa(c.Port)
}

func parse(lookup func(string) (string, bool)) (Config, error) {
	var cfg Config
	var problems []error

	if raw, ok := lookup("PORT"); ok && strings.TrimSpace(raw) != "" {
		port, err := strconv.Atoi(strings.TrimSpace(raw))
		if err != nil || port < 1 || port > 65535 {
			problems = append(problems, fmt.Errorf("PORT: invalid port %q", raw))
		} else {
			cfg.Port = port
		}
	} else {
		cfg.Port = DefaultPort
	}

	if raw, ok := lookup("LOG_LEVEL"); ok && strings.TrimSpace(raw) != "" {
		level, err := ParseLogLevel(raw)
		if err != nil {
			problems = append(problems, fmt.Errorf("LOG_LEVEL: %w", err))
		} else {
			cfg.LogLevel = level
		}
	} else {
		cfg.LogLevel = slog.LevelInfo
	}

	cfg.IssuerURL = DefaultIssuerURL
	if raw, ok := lookup("ISSUER_URL"); ok && strings.TrimSpace(raw) != "" {
		cfg.IssuerURL = strings.TrimSpace(raw)
	}
	cfg.Audience = DefaultAudience
	if raw, ok := lookup("AUDIENCE"); ok && strings.TrimSpace(raw) != "" {
		cfg.Audience = strings.TrimSpace(raw)
	}
	// JWKSURL stays empty unless set: discovery is the normal path.
	if raw, ok := lookup("JWKS_URL"); ok && strings.TrimSpace(raw) != "" {
		cfg.JWKSURL = strings.TrimSpace(raw)
	}

	for _, env := range []struct {
		name, value string
	}{
		{"ISSUER_URL", cfg.IssuerURL},
		{"AUDIENCE", cfg.Audience},
		{"JWKS_URL", cfg.JWKSURL},
	} {
		if env.value != "" && !isHTTPURL(env.value) {
			problems = append(problems, fmt.Errorf("%s: not a valid http(s) URL: %q", env.name, env.value))
		}
	}

	if len(problems) > 0 {
		return Config{}, errors.Join(problems...)
	}
	return cfg, nil
}

// ParseLogLevel maps a LOG_LEVEL value to a slog level.
func ParseLogLevel(s string) (slog.Level, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return slog.LevelDebug, nil
	case "info":
		return slog.LevelInfo, nil
	case "warn":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return 0, fmt.Errorf("unknown level %q (want debug, info, warn, or error)", s)
	}
}

func isHTTPURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != ""
}
