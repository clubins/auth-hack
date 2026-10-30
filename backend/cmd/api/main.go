// Command api serves the Clubins auth-hack reference API.
//
// It exposes the health check, the venues surface (including per-venue
// readings), and the renter-grant surface, all guarded by Logto-issued
// access tokens with the venue scopes; venue reads also accept renter
// grant tokens.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/clubins/auth-hack/backend/internal/auth"
	"github.com/clubins/auth-hack/backend/internal/config"
	"github.com/clubins/auth-hack/backend/internal/grants"
	"github.com/clubins/auth-hack/backend/internal/server"
	"github.com/clubins/auth-hack/backend/internal/venues"
)

// shutdownTimeout bounds the graceful drain after SIGTERM/SIGINT.
const shutdownTimeout = 10 * time.Second

func main() {
	if err := run(os.Stdout); err != nil {
		slog.Error("api exited", slog.Any("err", err))
		os.Exit(1)
	}
}

func run(out io.Writer) error {
	cfg, err := config.FromEnv()
	if err != nil {
		return fmt.Errorf("config: %w", err)
	}

	logger := slog.New(slog.NewJSONHandler(out, &slog.HandlerOptions{Level: cfg.LogLevel}))
	slog.SetDefault(logger)

	store := venues.NewMemStore(venues.DefaultSeed())
	readingsStore := venues.NewReadingsMemStore(venues.DefaultReadingsSeed())
	grantStore := grants.NewMemStore()

	// Grant TTL bounds come from config (validated at parse time). The
	// default is the product's locked 8h–24h window; GRANT_MIN_TTL exists
	// for test/e2e environments that must prove expiry in seconds. The
	// default TTL tracks the minimum, as grants.DefaultTTL does.
	grantBounds := grants.Bounds{
		Min:     cfg.GrantMinTTL,
		Max:     cfg.GrantMaxTTL,
		Default: cfg.GrantMinTTL,
	}

	// The guard verifies Logto access tokens on every protected route.
	// Discovery and the first JWKS fetch run here so a broken IdP fails
	// the boot loudly instead of failing every request later.
	verifier, err := auth.NewTokenVerifier(context.Background(), auth.VerifierConfig{
		IssuerURL:    cfg.IssuerURL,
		Audience:     cfg.Audience,
		JWKSURL:      cfg.JWKSURL,
		JWKSCacheTTL: cfg.JWKSCacheTTL,
	})
	if err != nil {
		return fmt.Errorf("auth verifier: %w", err)
	}
	guard, err := auth.NewGuard(auth.GuardOptions{Verifier: verifier, Logger: logger})
	if err != nil {
		return fmt.Errorf("auth guard: %w", err)
	}

	srv := &http.Server{
		Addr: cfg.Addr(),
		Handler: server.New(server.Options{
			Logger:        logger,
			Store:         store,
			ReadingsStore: readingsStore,
			GrantStore:    grantStore,
			GrantBounds:   &grantBounds,
			Guard:         guard,
		}),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Serve until SIGTERM/SIGINT, then drain in-flight requests. Issuer and
	// audience are not secrets and pin the deployment's identity wiring.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	serveErr := make(chan error, 1)
	go func() {
		serveErr <- srv.ListenAndServe()
	}()

	logger.Info("listening",
		slog.String("addr", cfg.Addr()),
		slog.String("issuer_url", cfg.IssuerURL),
		slog.String("audience", cfg.Audience),
	)

	select {
	case err := <-serveErr:
		if !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("serve: %w", err)
		}
		return nil
	case <-ctx.Done():
	}

	logger.Info("shutdown signal received, draining")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	logger.Info("shutdown complete")
	return nil
}
