package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	studyDocumentStatusPrefix = "frank:study:document:"
	studyPageStatusSuffix     = ":status"
	studyPageLayoutSuffix     = ":layout"
	studyDocumentTTL          = 24 * time.Hour
	maxStudyPages             = 500
)

var studyDocumentIDRe = regexp.MustCompile(`^[a-f0-9]{32}$`)

type studyDocumentStatus struct {
	DocumentID     string `json:"document_id"`
	Status         string `json:"status"`
	PageCount      int    `json:"page_count"`
	CompletedPages int    `json:"completed_pages"`
	InitialPage    int    `json:"initial_page"`
	Error          string `json:"error,omitempty"`
}

func studyDocumentKey(id string) string {
	return studyDocumentStatusPrefix + id
}

func studyPageKey(id string, page int, suffix string) string {
	return studyDocumentStatusPrefix + id + ":page:" + strconv.Itoa(page) + suffix
}

func (s *Server) studyPDFPath(id string) string {
	return filepath.Join(s.cache.dir, "study", "incoming", id+".pdf")
}

func newStudyDocumentID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}

// handleUploadStudyDocument stages one PDF in the shared cache volume and
// queues its page layouts. The Python worker removes the source PDF when all
// page tasks finish; only structured page layouts remain in Redis temporarily.
func (s *Server) handleUploadStudyDocument(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, s.maxStudyUploadSize)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		statusCode := http.StatusBadRequest
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			statusCode = http.StatusRequestEntityTooLarge
		}
		jsonError(w, "invalid or oversized multipart form", statusCode)
		return
	}
	if r.MultipartForm != nil {
		defer r.MultipartForm.RemoveAll()
	}

	file, _, err := r.FormFile("document")
	if err != nil {
		jsonError(w, "missing 'document' PDF field", http.StatusBadRequest)
		return
	}
	defer file.Close()

	initialPage := 1
	if raw := r.FormValue("priority_page"); raw != "" {
		initialPage, err = strconv.Atoi(raw)
		if err != nil || initialPage < 1 || initialPage > maxStudyPages {
			jsonError(w, "priority_page must be between 1 and 500", http.StatusBadRequest)
			return
		}
	}

	var signature [5]byte
	if _, err := io.ReadFull(file, signature[:]); err != nil || string(signature[:]) != "%PDF-" {
		jsonError(w, "uploaded document is not a PDF", http.StatusBadRequest)
		return
	}

	id, err := newStudyDocumentID()
	if err != nil {
		log.Printf("ERROR creating study document id: %v", err)
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	path := s.studyPDFPath(id)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		log.Printf("ERROR creating study upload directory: %v", err)
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	dst, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		log.Printf("ERROR creating staged study PDF: %v", err)
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	_, copyErr := dst.Write(signature[:])
	if copyErr == nil {
		_, copyErr = io.Copy(dst, file)
	}
	if copyErr == nil {
		copyErr = dst.Sync()
	}
	closeErr := dst.Close()
	if copyErr != nil || closeErr != nil {
		_ = os.Remove(path)
		log.Printf("ERROR staging study PDF: copy=%v close=%v", copyErr, closeErr)
		jsonError(w, "reading PDF upload", http.StatusBadRequest)
		return
	}

	status := studyDocumentStatus{
		DocumentID:  id,
		Status:      "queued",
		InitialPage: initialPage,
	}
	encoded, err := json.Marshal(status)
	if err != nil {
		_ = os.Remove(path)
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	ctx := r.Context()
	if err := s.rdb.Set(ctx, studyDocumentKey(id), encoded, studyDocumentTTL).Err(); err != nil {
		_ = os.Remove(path)
		log.Printf("ERROR storing study document status: %v", err)
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if err := s.queue.SubmitStudyTask(ctx, "study_ingest", id, initialPage, "high"); err != nil {
		_ = os.Remove(path)
		_ = s.rdb.Del(ctx, studyDocumentKey(id)).Err()
		log.Printf("ERROR queueing study document: %v", err)
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	if err := json.NewEncoder(w).Encode(status); err != nil {
		log.Printf("WARN: study upload response encode: %v", err)
	}
}

func (s *Server) handleGetStudyDocument(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !studyDocumentIDRe.MatchString(id) {
		jsonError(w, "invalid document id", http.StatusBadRequest)
		return
	}
	data, err := s.rdb.Get(r.Context(), studyDocumentKey(id)).Bytes()
	if err == redis.Nil {
		jsonError(w, "study document not found or expired", http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("ERROR reading study document status: %v", err)
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if _, err := w.Write(data); err != nil {
		log.Printf("WARN: study status response write: %v", err)
	}
}

func (s *Server) handleGetStudyPage(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	page, ok := parseStudyPageNumber(r.PathValue("page"))
	if !studyDocumentIDRe.MatchString(id) || !ok {
		jsonError(w, "invalid document id or page number", http.StatusBadRequest)
		return
	}
	data, err := s.rdb.Get(r.Context(), studyDocumentKey(id)).Bytes()
	if err == redis.Nil {
		jsonError(w, "study document not found or expired", http.StatusNotFound)
		return
	}
	if err != nil {
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	var status studyDocumentStatus
	if err := json.Unmarshal(data, &status); err != nil {
		jsonError(w, "study document status unavailable", http.StatusInternalServerError)
		return
	}
	if status.PageCount > 0 && page > status.PageCount {
		jsonError(w, "page number is outside the document", http.StatusBadRequest)
		return
	}
	if status.Status == "failed" {
		jsonError(w, status.Error, http.StatusConflict)
		return
	}

	data, err = s.rdb.Get(r.Context(), studyPageKey(id, page, studyPageLayoutSuffix)).Bytes()
	if err == redis.Nil {
		if status.Status == "completed" {
			jsonError(w, "study page layout expired; upload the PDF again", http.StatusGone)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "processing"})
		return
	}
	if err != nil {
		log.Printf("ERROR reading study page layout: %v", err)
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if _, err := w.Write(data); err != nil {
		log.Printf("WARN: study page response write: %v", err)
	}
}

func (s *Server) handlePrioritizeStudyPage(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	page, ok := parseStudyPageNumber(r.PathValue("page"))
	if !studyDocumentIDRe.MatchString(id) || !ok {
		jsonError(w, "invalid document id or page number", http.StatusBadRequest)
		return
	}
	var status studyDocumentStatus
	data, err := s.rdb.Get(r.Context(), studyDocumentKey(id)).Bytes()
	if err == redis.Nil {
		jsonError(w, "study document not found or expired", http.StatusNotFound)
		return
	}
	if err != nil || json.Unmarshal(data, &status) != nil {
		jsonError(w, "study document status unavailable", http.StatusInternalServerError)
		return
	}
	if status.PageCount > 0 && page > status.PageCount {
		jsonError(w, "page number is outside the document", http.StatusBadRequest)
		return
	}
	if status.Status == "failed" {
		jsonError(w, "study document processing failed", http.StatusConflict)
		return
	}
	if _, err := s.rdb.Get(r.Context(), studyPageKey(id, page, studyPageLayoutSuffix)).Result(); err == nil {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "completed"})
		return
	} else if err != redis.Nil {
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if status.Status == "completed" {
		jsonError(w, "study page layout expired; upload the PDF again", http.StatusGone)
		return
	}
	if err := s.queue.SubmitStudyTask(r.Context(), "study_page", id, page, "high"); err != nil {
		log.Printf("ERROR prioritizing study page %s/%d: %v", id, page, err)
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "queued"})
}

func parseStudyPageNumber(raw string) (int, bool) {
	page, err := strconv.Atoi(raw)
	return page, err == nil && page >= 1 && page <= maxStudyPages
}
