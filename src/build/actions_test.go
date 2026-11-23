package main

import (
	"path/filepath"
	"regexp"
	"testing"
)

// ** Хлебников С.Ю. 20261123 В языке запросов 1С ЕСТЬ — ключевое слово.
func TestActionTemplateAvoidsReservedFieldAlias(t *testing.T) {
	oldRoot := root
	root, _ = filepath.Abs(filepath.Join("..", ".."))
	t.Cleanup(func() { root = oldRoot })
	badAlias := regexp.MustCompile(`(?i)(^|[^\p{L}\p{N}_])КАК\s+ЕСТЬ($|[^\p{L}\p{N}_])`)
	for _, file := range buildActions() {
		if file.Name == "ДействияПослеОбновления/Ext/ObjectModule.bsl" && badAlias.Match(file.Data) {
			t.Fatal("в шаблоне действий есть зарезервированный псевдоним поля")
		}
	}
}

// ** Хлебников С.Ю. 20261123 конец
