// Package server wires the API's routes and middleware. The OIDC guard and
// grant resolution from the build spec land here in later tasks; today the
// routes are unauthenticated and the middleware stack is request logging.
package server

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/clubins/auth-hack/backend/internal/venues"
)

// Options configures New.
type Options struct {
	// Logger receives request logs; nil falls back to slog.Default.
	Logger *slog.Logger
	// Store backs the venues routes; nil falls back to an empty MemStore.
	Store venues.Store
}

// New builds the API's root handler.
func New(opts Options) http.Handler {
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	if opts.Store == nil {
		opts.Store = venues.NewMemStore(nil)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	venues.NewHandler(opts.Store, opts.Logger).Register(mux)

	return withRequestLogging(opts.Logger, mux)
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]string{"status": "ok"}); err != nil {
		slog.Default().Error("write healthz response", slog.Any("err", err))
	}
}

// withRequestLogging logs method, path, status, and duration for every
// request. It deliberately never logs headers, query strings, or bodies, so
// bearer tokens and credentials cannot reach the log.
func withRequestLogging(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		logger.LogAttrs(r.Context(), slog.LevelInfo, "request",
			slog.String("method", r.Method),
			slog.String("path", r.URL.Path),
			slog.Int("status", sw.status),
			slog.Duration("duration", time.Since(start)),
		)
	})
}

// statusWriter captures the response status for the request log.
type statusWriter struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (w *statusWriter) WriteHeader(code int) {
	if !w.wrote {
		w.status = code
		w.wrote = true
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if !w.wrote {
		w.status = http.StatusOK
		w.wrote = true
	}
	return w.ResponseWriter.Write(b)
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
