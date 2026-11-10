package graphiql

import (
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func get(t *testing.T, router *gin.Engine, path string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	router.ServeHTTP(w, req)
	return w
}

func mounted() *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	Mount(router)
	return router
}

func TestPage(t *testing.T) {
	w := get(t, mounted(), "/graphiql")
	if w.Code != http.StatusOK {
		t.Fatalf("GET /graphiql = %d, want 200", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Errorf("Content-Type = %q, want text/html", ct)
	}
	body := w.Body.String()
	if !strings.Contains(body, `GraphiQL.createFetcher({ url: "/graphql" })`) {
		t.Error("page does not post to /graphql")
	}
	// Everything the page loads comes from the API itself.
	for _, m := range regexp.MustCompile(`(?:src|href)="([^"]+)"`).FindAllStringSubmatch(body, -1) {
		if !strings.HasPrefix(m[1], "/graphiql/static/") {
			t.Errorf("page loads %q, want only /graphiql/static/… (no third parties)", m[1])
		}
	}
	// No key in the page: the only bearer value is the placeholder the user replaces.
	for _, m := range regexp.MustCompile(`Bearer ([^"\\]+)`).FindAllStringSubmatch(body, -1) {
		if m[1] != "paste-your-api-key-here" {
			t.Errorf("page contains a bearer value %q, want only the placeholder", m[1])
		}
	}
}

func TestAssets(t *testing.T) {
	router := mounted()
	for path, ct := range map[string]string{
		"/graphiql/static/graphiql.min.css":            "text/css",
		"/graphiql/static/graphiql.min.js":             "text/javascript",
		"/graphiql/static/react.production.min.js":     "text/javascript",
		"/graphiql/static/react-dom.production.min.js": "text/javascript",
	} {
		w := get(t, router, path)
		if w.Code != http.StatusOK {
			t.Errorf("GET %s = %d, want 200", path, w.Code)
			continue
		}
		if got := w.Header().Get("Content-Type"); !strings.HasPrefix(got, ct) {
			t.Errorf("GET %s Content-Type = %q, want %s", path, got, ct)
		}
		if w.Body.Len() == 0 {
			t.Errorf("GET %s is empty", path)
		}
	}
}

// Without Mount (GRAPHIQL_ENABLED=false), the paths 404 like any unknown route.
func TestNotMounted(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	for _, path := range []string{"/graphiql", "/graphiql/static/graphiql.min.js"} {
		if w := get(t, router, path); w.Code != http.StatusNotFound {
			t.Errorf("GET %s without Mount = %d, want 404", path, w.Code)
		}
	}
}
