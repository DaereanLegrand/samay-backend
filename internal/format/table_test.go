package format

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"
)

func captureStdout(fn func()) string {
	r, w, _ := os.Pipe()
	old := os.Stdout
	os.Stdout = w
	defer func() { os.Stdout = old }()

	outC := make(chan string)
	go func() {
		var buf bytes.Buffer
		io.Copy(&buf, r)
		outC <- buf.String()
	}()

	fn()
	w.Close()
	return <-outC
}

func TestRenderTable_ProducesOutput(t *testing.T) {
	out := captureStdout(func() {
		RenderTable([]string{"Name", "Value"}, [][]string{{"key1", "val1"}, {"key2", "val2"}})
	})

	if !strings.Contains(out, "NAME") {
		t.Errorf("expected 'NAME' in output, got: %s", out)
	}
	if !strings.Contains(out, "VALUE") {
		t.Errorf("expected 'VALUE' in output, got: %s", out)
	}
	if !strings.Contains(out, "key1") {
		t.Errorf("expected 'key1' in output, got: %s", out)
	}
	if !strings.Contains(out, "val2") {
		t.Errorf("expected 'val2' in output, got: %s", out)
	}
}

func TestRenderTable_EmptyRows(t *testing.T) {
	out := captureStdout(func() {
		RenderTable([]string{"Col1"}, [][]string{})
	})

	if !strings.Contains(out, "COL1") {
		t.Errorf("expected 'COL1' in output even with empty rows, got: %s", out)
	}
}

func TestRenderJSON_ProducesIndentedJSON(t *testing.T) {
	out := captureStdout(func() {
		RenderJSON(map[string]string{"key": "value"})
	})

	var result map[string]string
	if err := json.Unmarshal([]byte(out), &result); err != nil {
		t.Fatalf("expected valid JSON, got error: %v\noutput: %s", err, out)
	}
	if result["key"] != "value" {
		t.Errorf("expected key=value, got %s", result["key"])
	}
	if !strings.Contains(out, "\n") {
		t.Error("expected indented JSON with newlines")
	}
}

func TestRenderJSON_NilReturnsNull(t *testing.T) {
	out := captureStdout(func() {
		RenderJSON(nil)
	})

	trimmed := strings.TrimSpace(out)
	if trimmed != "null" {
		t.Errorf("expected 'null', got '%s'", trimmed)
	}
}

func TestRenderJSON_Slice(t *testing.T) {
	out := captureStdout(func() {
		RenderJSON([]int{1, 2, 3})
	})

	trimmed := strings.TrimSpace(out)
	if !strings.Contains(trimmed, "1") {
		t.Errorf("expected array containing 1, got: %s", trimmed)
	}
}

func TestRenderJSON_ErrorWritesToStderr(t *testing.T) {
	r, w, _ := os.Pipe()
	oldStderr := os.Stderr
	os.Stderr = w
	defer func() { os.Stderr = oldStderr }()

	outC := make(chan string)
	go func() {
		var buf bytes.Buffer
		io.Copy(&buf, r)
		outC <- buf.String()
	}()

	RenderJSON(make(chan int))

	w.Close()
	stderr := <-outC
	if !strings.Contains(stderr, "error marshaling JSON") {
		t.Errorf("expected 'error marshaling JSON' in stderr, got: %s", stderr)
	}
}

func TestOutput_JSONFlagTrue_RendersJSON(t *testing.T) {
	data := map[string]int{"a": 1}
	tableCalled := false

	out := captureStdout(func() {
		Output(data, true, func(d any) ([]string, [][]string) {
			tableCalled = true
			return nil, nil
		})
	})

	if tableCalled {
		t.Error("tableBuilder should NOT be called when jsonFlag=true")
	}
	var result map[string]int
	if err := json.Unmarshal([]byte(out), &result); err != nil {
		t.Fatalf("expected valid JSON output, got: %v", err)
	}
}

func TestOutput_JSONFlagFalse_CallsTableBuilder(t *testing.T) {
	data := map[string]int{"a": 1}
	tableCalled := false

	captureStdout(func() {
		Output(data, false, func(d any) ([]string, [][]string) {
			tableCalled = true
			return []string{"Key", "Value"}, [][]string{{"a", "1"}}
		})
	})

	if !tableCalled {
		t.Error("tableBuilder SHOULD be called when jsonFlag=false")
	}
}
