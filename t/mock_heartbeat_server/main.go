package main

import (
	"fmt"
	"net/http"
)

func main() {
	// The "/" pattern matches all paths that aren't matched by other handlers
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"config":{"config_payload":{"apisix":{"data_encryption":{"enable":true,"keyring":["kzicgltttmmja3ohzx50xbgozpgxvuhd"]},"ssl":{"enable":true,"key_encrypt_salt":["kzicgltttmmja3ohzx50xbgozpgxvuhd"]}}},"config_version":999}}`)
	})

	fmt.Println("Server starting on port 6625...")

	// Listen on port 6625. The nil parameter tells it to use the default router.
	err := http.ListenAndServe(":6625", nil)
	if err != nil {
		fmt.Printf("Error starting server: %s\n", err)
	}
}
