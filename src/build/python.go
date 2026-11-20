package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

// Официальный Windows embeddable package (64-bit), включая лицензию PSF и библиотеки TLS.
// https://www.python.org/downloads/release/python-31410/
const pythonVersion = "3.14.10"
const pythonSHA256 = "90905e64a840557d8c1bc4f5b74db3d7ee85e3ffb217611cac1c7813acea4159"

func embeddedPython() ([]entry, error) {
	var archive io.ReadCloser
	if path := os.Getenv("GATE_PYTHON_ZIP"); path != "" {
		file, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		archive = file
	} else {
		url := fmt.Sprintf("https://www.python.org/ftp/python/%s/python-%s-embed-amd64.zip", pythonVersion, pythonVersion)
		client := http.Client{Timeout: 2 * time.Minute}
		response, err := client.Get(url)
		if err != nil {
			return nil, err
		}
		archive = response.Body
		if response.StatusCode != http.StatusOK {
			archive.Close()
			return nil, fmt.Errorf("%s: %s", url, response.Status)
		}
	}
	defer archive.Close()
	data, err := io.ReadAll(io.LimitReader(archive, 32<<20))
	if err != nil {
		return nil, err
	}
	if fmt.Sprintf("%x", sha256.Sum256(data)) != pythonSHA256 {
		return nil, fmt.Errorf("архив Python %s: SHA-256 отличается от опубликованного", pythonVersion)
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, err
	}
	files := []entry{{"ci/runtime/python-version.txt", []byte(pythonVersion + "\n")}}
	for _, f := range reader.File {
		if f.FileInfo().IsDir() {
			continue
		}
		stream, err := f.Open()
		if err != nil {
			return nil, err
		}
		content, err := io.ReadAll(stream)
		stream.Close()
		if err != nil {
			return nil, err
		}
		files = append(files, entry{"ci/runtime/python-" + pythonVersion + "/" + f.Name, content})
	}
	return files, nil
}
