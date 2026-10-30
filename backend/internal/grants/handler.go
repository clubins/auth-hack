package grants

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// maxBodyBytes bounds request-body reads; grant requests carry a single
// optional TTL field, so anything larger is abuse.
const maxBodyBytes = 1 << 20

// Handler serves the grants REST surface. Creation trusts the Principal in
// the request context: the server wiring bridges the OIDC guard's principal
// into the grants slot, so a management route without an authenticated
// caller fails with 401 here.
type Handler struct {
	service *Service
	logger  *slog.Logger
}

// NewHandler returns a handler backed by store. A nil logger falls back to
// slog.Default.
func NewHandler(store Store, logger *slog.Logger) *Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return &Handler{service: NewService(store), logger: logger}
}

// Register mounts the grant routes on mux.
func (h *Handler) Register(mux *http.ServeMux) {
	h.RegisterCreate(mux)
	h.RegisterList(mux)
	h.RegisterRevoke(mux)
}

// RegisterCreate mounts POST /venues/{id}/grants. Split out of Register so
// the server can wrap each route with its own scope check.
func (h *Handler) RegisterCreate(mux *http.ServeMux) {
	mux.HandleFunc("POST /venues/{id}/grants", h.create)
}

// RegisterList mounts GET /venues/{id}/grants.
func (h *Handler) RegisterList(mux *http.ServeMux) {
	mux.HandleFunc("GET /venues/{id}/grants", h.list)
}

// RegisterRevoke mounts DELETE /grants/{id}.
func (h *Handler) RegisterRevoke(mux *http.ServeMux) {
	mux.HandleFunc("DELETE /grants/{id}", h.revoke)
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	if p == nil {
		writeError(w, http.StatusUnauthorized, "authentication required")
		return
	}

	ttl, err := decodeTTL(w, r)
	if err != nil {
		return // decodeTTL already wrote the response
	}

	g, err := h.service.Create(r.Context(), CreateInput{
		VenueID: r.PathValue("id"),
		Subject: p.Subject(),
		TTL:     ttl,
	}, time.Now().UTC())
	switch {
	case errors.Is(err, ErrInvalidTTL):
		writeError(w, http.StatusUnprocessableEntity, fmt.Sprintf("ttl out of bounds (want between %s and %s)", MinTTL, MaxTTL))
	case err != nil:
		h.logger.Error("create grant", slog.Any("err", err))
		writeError(w, http.StatusInternalServerError, "internal error")
	default:
		w.Header().Set("Location", "/grants/"+g.ID)
		writeJSON(w, http.StatusCreated, g)
	}
}

// decodeTTL reads the optional {"ttl": "..."} body and returns the request's
// TTL, or DefaultTTL for an empty body. Status-code mapping:
// malformed JSON or an unparseable duration is a syntax problem (400);
// a parseable duration outside the bounds is a semantic one (422).
func decodeTTL(w http.ResponseWriter, r *http.Request) (time.Duration, error) {
	var body struct {
		TTL string `json:"ttl"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return 0, err
	}
	if body.TTL == "" {
		return DefaultTTL, nil
	}
	ttl, err := time.ParseDuration(body.TTL)
	if err != nil {
		writeError(w, http.StatusBadRequest, "ttl must be a duration string such as \"8h\"")
		return 0, err
	}
	if ttl < MinTTL || ttl > MaxTTL {
		writeError(w, http.StatusUnprocessableEntity, fmt.Sprintf("ttl out of bounds (want between %s and %s)", MinTTL, MaxTTL))
		return 0, fmt.Errorf("%w: %s", ErrInvalidTTL, ttl)
	}
	return ttl, nil
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	gs, err := h.service.ListForVenue(r.Context(), r.PathValue("id"))
	if err != nil {
		h.logger.Error("list grants", slog.Any("err", err))
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	if gs == nil {
		gs = []Grant{}
	}
	views := make([]grantView, len(gs))
	for i, g := range gs {
		views[i] = g.view()
	}
	writeJSON(w, http.StatusOK, views)
}

func (h *Handler) revoke(w http.ResponseWriter, r *http.Request) {
	g, err := h.service.Revoke(r.Context(), r.PathValue("id"), time.Now().UTC())
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, "grant not found")
	case err != nil:
		h.logger.Error("revoke grant", slog.Any("err", err))
		writeError(w, http.StatusInternalServerError, "internal error")
	default:
		writeJSON(w, http.StatusOK, g.view())
	}
}

// grantView is the management-surface projection of a grant: everything
// except its bearer token. The token is delivered exactly once, in the 201
// create response, and never again — not in lists (a venue-read-scoped
// caller must not be able to impersonate renters) and not on revoke (the
// caller only needs the revocation stamp).
type grantView struct {
	ID        string     `json:"id"`
	VenueID   string     `json:"venueId"`
	Subject   string     `json:"subject"`
	ExpiresAt time.Time  `json:"expiresAt"`
	CreatedAt time.Time  `json:"createdAt"`
	RevokedAt *time.Time `json:"revokedAt,omitempty"`
}

// view returns g without its token.
func (g Grant) view() grantView {
	return grantView{
		ID:        g.ID,
		VenueID:   g.VenueID,
		Subject:   g.Subject,
		ExpiresAt: g.ExpiresAt,
		CreatedAt: g.CreatedAt,
		RevokedAt: g.RevokedAt,
	}
}

// Resolve lets the handler act as the venue-read guard's Resolver. It hides
// nothing: the same policy-checked resolution the guard needs.
func (h *Handler) Resolve(ctx context.Context, token string, now time.Time) (Grant, error) {
	return h.service.Resolve(ctx, token, now)
}

// venueReadPath matches the venue-read routes the guard adds access to:
// GET /venues/{id} and its readings view GET /venues/{id}/readings — the
// read surface a venue grant buys — and nothing else, notably none of the
// grant management routes.
var venueReadPath = regexp.MustCompile(`^/venues/([^/]+)(?:/readings)?$`)

// Resolver is the policy-checked token lookup the venue-read guard needs.
type Resolver interface {
	Resolve(ctx context.Context, token string, now time.Time) (Grant, error)
}

var _ Resolver = (*Handler)(nil)

// VenueReadGuard authorizes the venue-read routes (GET /venues/{id} and
// GET /venues/{id}/readings) for holders of a valid grant token. It sits
// OUTSIDE the OIDC guard on those routes: a grant token is opaque and could
// never verify as a Logto JWT, so requests it authorizes must never reach
// that verification. Everything it does not answer — no bearer header, or a
// token that resolves to no grant (Logto JWTs among them) — falls through to
// the OIDC credential path.
type VenueReadGuard struct {
	resolver Resolver
	// venueRead is served when a grant authorizes the read.
	venueRead http.Handler
	logger    *slog.Logger
}

// NewVenueReadGuard returns a guard that serves a venue read through
// venueRead when the request's bearer token resolves as a grant authorizing
// exactly that venue. A nil logger falls back to slog.Default.
func NewVenueReadGuard(resolver Resolver, venueRead http.Handler, logger *slog.Logger) *VenueReadGuard {
	if logger == nil {
		logger = slog.Default()
	}
	return &VenueReadGuard{resolver: resolver, venueRead: venueRead, logger: logger}
}

// HandleGrant serves the venue read when the bearer token resolves as a
// grant authorizing exactly this venue. Status mapping, chosen and
// documented here because the grant token is a bearer credential:
//
//	no Bearer Authorization header -> not handled
//	token that resolves to no grant -> not handled (the OIDC guard owns
//	  rejecting non-grant tokens on the fall-through path)
//	expired grant -> 403 (credential understood, no longer honored)
//	revoked grant -> 410 (credential explicitly withdrawn)
//	valid grant, different venue -> 403 (outside the grant's scope)
//	valid grant, this venue -> 200 via venueRead, with the grant's subject
//	  in the context principal slot
//
// HandleGrant reports whether it answered the request.
func (g *VenueReadGuard) HandleGrant(w http.ResponseWriter, r *http.Request) bool {
	m := venueReadPath.FindStringSubmatch(r.URL.Path)
	if m == nil {
		return false
	}
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return false
	}

	grant, err := g.resolver.Resolve(r.Context(), token, time.Now().UTC())
	switch {
	case errors.Is(err, ErrNotFound):
		return false
	case errors.Is(err, ErrRevoked):
		writeError(w, http.StatusGone, "grant revoked")
	case errors.Is(err, ErrExpired):
		writeError(w, http.StatusForbidden, "grant expired")
	case err != nil:
		g.logger.Error("resolve grant token", slog.Any("err", err))
		writeError(w, http.StatusInternalServerError, "internal error")
	case grant.VenueID != m[1]:
		writeError(w, http.StatusForbidden, "grant is not valid for this venue")
	default:
		ctx := WithPrincipal(r.Context(), NewPrincipal(grant.Subject))
		g.venueRead.ServeHTTP(w, r.WithContext(ctx))
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	b, err := json.Marshal(body)
	if err != nil {
		// Marshaling our own response types cannot fail; if it does, that is
		// a bug and the client gets a plain error instead of a corrupt body.
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"internal error"}`))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	// A failed write here means the client disconnected after the status was
	// committed; the request log already records the aborted exchange.
	_, _ = w.Write(b)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
