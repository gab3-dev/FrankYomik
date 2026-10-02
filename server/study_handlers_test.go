package main

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func makeStudyUploadRequest(t *testing.T, pdf []byte, fields map[string]string) *http.Request {
	t.Helper()
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	for key, value := range fields {
		if err := writer.WriteField(key, value); err != nil {
			t.Fatal(err)
		}
	}
	part, err := writer.CreateFormFile("document", "study.pdf")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(pdf); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("POST", "/api/v1/study/documents", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	return req
}

func TestUploadStudyDocumentStagesAndQueuesPDF(t *testing.T) {
	s, rdb := newTestServer(t)
	req := makeStudyUploadRequest(t, []byte("%PDF-1.7\nsource"), map[string]string{
		"priority_page": "2",
	})
	response := httptest.NewRecorder()
	s.handleUploadStudyDocument(response, req)
	if response.Code != http.StatusAccepted {
		t.Fatalf("got status %d, body=%s", response.Code, response.Body.String())
	}

	var status studyDocumentStatus
	if err := json.Unmarshal(response.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if !studyDocumentIDRe.MatchString(status.DocumentID) || status.InitialPage != 2 {
		t.Fatalf("unexpected upload response: %+v", status)
	}

	path := s.studyPDFPath(status.DocumentID)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("staged PDF missing: %v", err)
	}
	if string(data) != "%PDF-1.7\nsource" {
		t.Fatalf("staged PDF bytes changed: %q", data)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("staged PDF permissions = %o, want 600", got)
	}

	entries, err := rdb.XRange(req.Context(), streamHigh, "-", "+").Result()
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Values["task_type"] != "study_ingest" ||
		entries[0].Values["document_id"] != status.DocumentID ||
		entries[0].Values["initial_page"] != "2" {
		t.Fatalf("unexpected study stream entries: %#v", entries)
	}
}

func TestUploadStudyDocumentRejectsNonPDF(t *testing.T) {
	s, _ := newTestServer(t)
	req := makeStudyUploadRequest(t, []byte("not a pdf"), nil)
	response := httptest.NewRecorder()
	s.handleUploadStudyDocument(response, req)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "not a PDF") {
		t.Fatalf("got status %d, body=%s", response.Code, response.Body.String())
	}
}

func TestStudyPageLayoutWaitsUntilWorkerPublishesIt(t *testing.T) {
	s, rdb := newTestServer(t)
	const documentID = "0123456789abcdef0123456789abcdef"
	status := studyDocumentStatus{DocumentID: documentID, Status: "processing", PageCount: 2}
	data, _ := json.Marshal(status)
	if err := rdb.Set(t.Context(), studyDocumentKey(documentID), data, studyDocumentTTL).Err(); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("GET", "/api/v1/study/documents/"+documentID+"/pages/2", nil)
	req.SetPathValue("id", documentID)
	req.SetPathValue("page", "2")
	response := httptest.NewRecorder()
	s.handleGetStudyPage(response, req)
	if response.Code != http.StatusAccepted {
		t.Fatalf("got status %d, want 202: %s", response.Code, response.Body.String())
	}

	layout := `{"page_number":2,"text":"日本語","glyphs":[]}`
	if err := rdb.Set(t.Context(), studyPageKey(documentID, 2, studyPageLayoutSuffix), layout, studyDocumentTTL).Err(); err != nil {
		t.Fatal(err)
	}
	req = httptest.NewRequest("GET", "/api/v1/study/documents/"+documentID+"/pages/2", nil)
	req.SetPathValue("id", documentID)
	req.SetPathValue("page", "2")
	response = httptest.NewRecorder()
	s.handleGetStudyPage(response, req)
	if response.Code != http.StatusOK || response.Body.String() != layout {
		t.Fatalf("got status %d, body=%s", response.Code, response.Body.String())
	}
}
