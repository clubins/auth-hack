package venues

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
)

// Handler serves the venues REST surface. The server mounts these routes
// behind the auth guard and scope middleware; handlers here stay free of
// identity logic and test against plain stores (stubbed or real).
type Handler struct {
	store    Store
	readings ReadingsStore
	logger   *slog.Logger
}

// NewHandler returns a handler backed by store and readings. A nil logger
// falls back to slog.Default.
func NewHandler(store Store, readings ReadingsStore, logger *slog.Logger) *Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return &Handler{store: store, readings: readings, logger: logger}
}

// Register mounts the venue routes on mux.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /venues", h.list)
	mux.HandleFunc("GET /venues/{id}", h.get)
	mux.HandleFunc("GET /venues/{id}/readings", h.listReadings)
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	vs, err := h.store.List(r.Context())
	if err != nil {
		h.logger.Error("list venues", slog.Any("err", err))
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	if vs == nil {
		vs = []Venue{}
	}
	writeJSON(w, http.StatusOK, vs)
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	v, err := h.store.Get(r.Context(), r.PathValue("id"))
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, "venue not found")
	case err != nil:
		h.logger.Error("get venue", slog.Any("err", err))
		writeError(w, http.StatusInternalServerError, "internal error")
	default:
		writeJSON(w, http.StatusOK, v)
	}
}

// listReadings serves the venue's temperature readings. Existence is decided
// by the venues store — an unknown venue is 404 exactly like the venue read,
// even though the readings store would list it as empty — so clients see
// one notion of which venues exist.
func (h *Handler) listReadings(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.store.Get(r.Context(), id); err != nil {
		if errors.Is(err, ErrNotFound) {
			writeError(w, http.StatusNotFound, "venue not found")
			return
		}
		h.logger.Error("get venue", slog.Any("err", err))
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	rs, err := h.readings.ListForVenue(r.Context(), id)
	if err != nil {
		h.logger.Error("list readings", slog.Any("err", err))
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	if rs == nil {
		rs = []Reading{}
	}
	writeJSON(w, http.StatusOK, rs)
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
