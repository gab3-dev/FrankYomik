package main

import "testing"

func TestNewStudyDocumentID(t *testing.T) {
	id, err := newStudyDocumentID()
	if err != nil {
		t.Fatalf("newStudyDocumentID: %v", err)
	}
	if !studyDocumentIDRe.MatchString(id) {
		t.Fatalf("generated invalid id %q", id)
	}
	other, err := newStudyDocumentID()
	if err != nil {
		t.Fatalf("second newStudyDocumentID: %v", err)
	}
	if id == other {
		t.Fatalf("generated duplicate ids %q", id)
	}
}

func TestParseStudyPageNumber(t *testing.T) {
	for _, tc := range []struct {
		input string
		want  int
		ok    bool
	}{
		{input: "1", want: 1, ok: true},
		{input: "500", want: 500, ok: true},
		{input: "0", ok: false},
		{input: "501", want: 501, ok: false},
		{input: "first", ok: false},
	} {
		got, ok := parseStudyPageNumber(tc.input)
		if got != tc.want || ok != tc.ok {
			t.Errorf("parseStudyPageNumber(%q) = (%d, %v), want (%d, %v)",
				tc.input, got, ok, tc.want, tc.ok)
		}
	}
}

func TestStudyPDFPathUsesDocumentIdBelowStudyCache(t *testing.T) {
	s := &Server{cache: NewCache("/cache")}
	got := s.studyPDFPath("0123456789abcdef0123456789abcdef")
	want := "/cache/study/incoming/0123456789abcdef0123456789abcdef.pdf"
	if got != want {
		t.Fatalf("studyPDFPath() = %q, want %q", got, want)
	}
}
