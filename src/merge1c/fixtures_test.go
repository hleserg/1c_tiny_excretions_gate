package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Тексты - как у конфигуратора: BOM, CRLF, табуляции. Имена условные (публичный репозиторий).

func dump(s string) string {
	return "\ufeff" + strings.ReplaceAll(strings.TrimPrefix(s, "\n"), "\n", "\r\n")
}

const xmlHead = `<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.20">
`

func configXML(name, uuid, version string, children ...string) string {
	var kids strings.Builder
	for _, c := range children {
		kids.WriteString("\t\t\t" + c + "\n")
	}
	return dump("\n" + xmlHead + `	<Configuration uuid="` + uuid + `">
		<InternalInfo>
			<xr:ContainedObject>
				<xr:ClassId>9cd510cd-abfc-11d4-9434-004095e12fc7</xr:ClassId>
				<xr:ObjectId>11111111-0000-0000-0000-000000000001</xr:ObjectId>
			</xr:ContainedObject>
		</InternalInfo>
		<Properties>
			<ObjectBelonging>Adopted</ObjectBelonging>
			<Name>` + name + `</Name>
			<Comment/>
			<NamePrefix>Пр_</NamePrefix>
			<Version>` + version + `</Version>
		</Properties>
		<ChildObjects>
` + kids.String() + `		</ChildObjects>
	</Configuration>
</MetaDataObject>
`)
}

func attrXML(uuid, name, typ string) string {
	return `			<Attribute uuid="` + uuid + `">
				<Properties>
					<Name>` + name + `</Name>
					<Synonym>
						<v8:item>
							<v8:lang>ru</v8:lang>
							<v8:content>` + name + `</v8:content>
						</v8:item>
					</Synonym>
					<Type>
						<v8:Type>` + typ + `</v8:Type>
					</Type>
				</Properties>
			</Attribute>
`
}

func docXML(uuid, name, comment string, attrs ...string) string {
	return dump("\n" + xmlHead + `	<Document uuid="` + uuid + `">
		<InternalInfo>
			<xr:GeneratedType name="DocumentObject.` + name + `" category="Object">
				<xr:TypeId>22222222-0000-0000-0000-000000000001</xr:TypeId>
				<xr:ValueId>22222222-0000-0000-0000-000000000002</xr:ValueId>
			</xr:GeneratedType>
		</InternalInfo>
		<Properties>
			<ObjectBelonging>Adopted</ObjectBelonging>
			<Name>` + name + `</Name>
			<Comment>` + comment + `</Comment>
			<ExtendedConfigurationObject>33333333-0000-0000-0000-000000000001</ExtendedConfigurationObject>
		</Properties>
		<ChildObjects>
` + strings.Join(attrs, "") + `			<Form>ФормаДокумента</Form>
		</ChildObjects>
	</Document>
</MetaDataObject>
`)
}

const modBase = `
#Область ОбработчикиСобытий

&После("ОбработкаПроведения")
Процедура Пр_ОбработкаПроведения(Отказ, РежимПроведения)
	Пр_Пересчитать();
КонецПроцедуры

#КонецОбласти

#Область СлужебныеПроцедурыИФункции

// Пересчитывает суммы документа.
Процедура Пр_Пересчитать()
	Для Каждого СтрокаТЧ Из Товары Цикл
		СтрокаТЧ.Сумма = Окр(СтрокаТЧ.Цена * СтрокаТЧ.Количество, 2);
	КонецЦикла;
КонецПроцедуры

Функция Пр_Скидка(Сумма)
	Возврат 0;
КонецФункции

#КонецОбласти
`

func mod(base string, edits ...[2]string) string {
	s := base
	for _, e := range edits {
		if !strings.Contains(s, e[0]) {
			panic("нет текста для правки: " + e[0])
		}
		s = strings.Replace(s, e[0], e[1], 1)
	}
	return dump(s)
}

// tree - папка объекта: путь от корня -> текст.
type tree map[string]string

func writeTree(t *testing.T, dir string, files tree) string {
	t.Helper()
	for rel, text := range files {
		p := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// env - история, блобы и задание для одного прогона объединения.
type env struct {
	t       *testing.T
	dir     string
	history []historyEntry
	ledgers []string
}

func newEnv(t *testing.T) *env {
	dir := t.TempDir()
	_ = os.MkdirAll(filepath.Join(dir, "blobs"), 0o755)
	return &env{t: t, dir: dir}
}

// remember - версия дерева объекта в истории (origin: main@..., delivery:...).
func (e *env) remember(repoPath, origin string, files tree) {
	for rel, text := range files {
		sha := gitBlobSHA([]byte(text))
		_ = os.WriteFile(filepath.Join(e.dir, "blobs", sha), []byte(text), 0o644)
		e.history = append(e.history, historyEntry{Path: repoPath + "/" + rel, Blob: sha, Origin: origin})
	}
}

func (e *env) ledger(name string, rejected []rejectedUnit) {
	p := filepath.Join(e.dir, name)
	data, _ := json.Marshal(map[string]interface{}{"rejected": rejected})
	_ = os.WriteFile(p, data, 0o644)
	e.ledgers = append(e.ledgers, p)
}

func (e *env) run(delivery string, decisions map[string]string, objects ...objectSpec) *result {
	e.t.Helper()
	var lines []string
	for _, h := range e.history {
		data, _ := json.Marshal(h)
		lines = append(lines, string(data))
	}
	hist := filepath.Join(e.dir, "history.jsonl")
	_ = os.WriteFile(hist, []byte(strings.Join(lines, "\n")+"\n"), 0o644)
	dec := filepath.Join(e.dir, "decisions-"+delivery+".json")
	data, _ := json.Marshal(decisions)
	_ = os.WriteFile(dec, data, 0o644)
	sp := spec{Delivery: delivery, Stamp: "20261120.150000", HistoryIndex: hist, BlobDir: filepath.Join(e.dir, "blobs"),
		Ledgers: e.ledgers, Decisions: dec, Objects: objects,
		Result: filepath.Join(e.dir, "result-"+delivery+".json"), Report: filepath.Join(e.dir, "report-"+delivery+".md")}
	specPath := filepath.Join(e.dir, "spec-"+delivery+".json")
	data, _ = json.Marshal(sp)
	_ = os.WriteFile(specPath, data, 0o644)
	res, err := runMerge(specPath)
	if err != nil {
		e.t.Fatal(err)
	}
	return res
}

func (e *env) object(kind, name, repo string, ours, theirs tree, tag string) objectSpec {
	o := ""
	if ours != nil {
		o = writeTree(e.t, filepath.Join(e.dir, tag, "ours"), ours)
	}
	th := writeTree(e.t, filepath.Join(e.dir, tag, "theirs"), theirs)
	return objectSpec{Kind: kind, Name: name, Title: name, RepoPath: repo, Ours: o, Theirs: th, Out: filepath.Join(e.dir, tag, "out")}
}

func readOut(t *testing.T, sp objectSpec, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(sp.Out, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatalf("нет файла результата %s: %v", rel, err)
	}
	return string(data)
}

func changeOf(obj *ObjectResult, unitSuffix string) *Change {
	for i := range obj.Changes {
		if strings.HasSuffix(obj.Changes[i].Unit, unitSuffix) {
			return &obj.Changes[i]
		}
	}
	return nil
}
