package main

import (
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Хеш исходников в модуле объекта собранной обработки «Выполнить после обновления».
func builtSourceHash(t *testing.T, packs []pack, buildStamp string) string {
	t.Helper()
	saved := stamp
	stamp = buildStamp
	defer func() { stamp = saved }()
	for _, e := range buildProcessing(packs) {
		if e.Name != "ВыполнитьПослеОбновления/Ext/ObjectModule.bsl" {
			continue
		}
		text := string(e.Data)
		if strings.Contains(text, sourceHashMark) {
			t.Fatalf("метка хеша исходников осталась в модуле объекта")
		}
		m := regexp.MustCompile(`Функция ХешИсходников\(\) Экспорт\s+Возврат "([0-9a-f]{64})";`).FindStringSubmatch(text)
		if m == nil {
			t.Fatalf("в модуле объекта нет хеша исходников из 64 знаков")
		}
		return m[1]
	}
	t.Fatalf("в сборке нет модуля объекта")
	return ""
}

func repoPackages(t *testing.T) []pack {
	t.Helper()
	saved := root
	root, _ = filepath.Abs(filepath.Join("..", ".."))
	t.Cleanup(func() { root = saved })
	return loadPackages()
}

// Две сборки одного кода с разными штампами - один хеш: обновление гейта без правок обработки не заставляет
// гейт снимать «до загрузки» заново.
func TestSourceHashIgnoresBuildStamp(t *testing.T) {
	packs := repoPackages(t)
	first := builtSourceHash(t, packs, "20261120.065748")
	second := builtSourceHash(t, packs, "20261120.130631")
	if first != second {
		t.Fatalf("хеш исходников зависит от штампа сборки: %s и %s", first, second)
	}
}

// Повтор обязателен: изменился код пакета (так было между сборками 20261119.153024 и 20261119.174708) -
// хеш другой, отпечаток другой, «до загрузки» снимается заново.
func TestSourceHashChangesWithPackageCode(t *testing.T) {
	packs := repoPackages(t)
	if len(packs) == 0 {
		t.Skip("в репозитории нет пакетов")
	}
	before := builtSourceHash(t, packs, "20261120.065748")
	changed := make([]pack, len(packs))
	copy(changed, packs)
	files := map[string]string{}
	for k, v := range changed[0].Files {
		files[k] = v
	}
	files["ObjectModule.bsl"] = files["ObjectModule.bsl"] + "\n// новая проверка\n"
	changed[0].Files = files
	after := builtSourceHash(t, changed, "20261120.065748")
	if before == after {
		t.Fatalf("код пакета изменился, а хеш исходников тот же: %s", before)
	}
}

// Части разделены длинами: перенос текста из одного файла в соседний меняет хеш.
func TestProcessingSourceHashSeparatesParts(t *testing.T) {
	if processingSourceHash("ab", "c") == processingSourceHash("a", "bc") {
		t.Fatal("хеш не различает границы частей")
	}
	if processingSourceHash("a", "b") != processingSourceHash("a", "b") {
		t.Fatal("хеш не повторяется на тех же данных")
	}
}
