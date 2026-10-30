// Command api serves the Clubins auth-hack reference API.
//
// Today it exposes the health check and the unauthenticated venues surface.
// The OIDC guard and renter grants land in later component tasks.
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

	"github.com/clubins/auth-hack/backend/internal/config"
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

	srv := &http.Server{
		Addr:              cfg.Addr(),
		Handler:           server.New(server.Options{Logger: logger, Store: store}),
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
