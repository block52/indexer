// Package graphiql serves the GraphiQL explorer page for POST /graphql
// (block52/indexer#18). The GraphiQL assets are embedded in the binary, so
// the page loads nothing from third parties and contains no key, secret or
// connection detail: the API key is typed by the user into the explorer's
// headers panel and sent straight to /graphql.
package graphiql

import (
	"embed"
	"io/fs"
	"net/http"

	"github.com/gin-gonic/gin"
)

//go:embed graphiql.html static
var content embed.FS

var page []byte

func init() {
	var err error
	page, err = content.ReadFile("graphiql.html")
	if err != nil {
		panic(err) // the file is embedded; this cannot fail at runtime
	}
}

// Mount adds GET /graphiql and its static assets to the router. The caller
// decides whether to mount at all (GRAPHIQL_ENABLED); unmounted, the paths
// 404 like any other unknown route.
func Mount(router *gin.Engine) {
	router.GET("/graphiql", func(c *gin.Context) {
		c.Data(http.StatusOK, "text/html; charset=utf-8", page)
	})
	static, err := fs.Sub(content, "static")
	if err != nil {
		panic(err) // the directory is embedded; this cannot fail at runtime
	}
	router.StaticFS("/graphiql/static", http.FS(static))
}
