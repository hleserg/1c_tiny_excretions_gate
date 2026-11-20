// merge1c - объединение поставки подрядчика (расширение, внешняя обработка, отчёт) с нашей версией в git.
//
// Гейт разбирает бинарники подрядчика конфигуратором в технической базе (выгрузка в файлы - тот же формат, что в
// репозитории) и зовёт merge1c. Объединение идёт по единицам: процедуры и функции модулей, свойства и подчинённые
// объекты метаданных (по UUID), права роли по объектам; остальное - файл целиком. Правило выбора - только по
// тождеству текста с версиями, которые мы знаем (история main и temp, прежние поставки, отклонённые правки):
//   - одинаково - ничего;
//   - в поставке нет - остаётся наше (в первой поставке - всегда; в следующих - если подрядчик эту часть не поставлял);
//   - в поставке прежняя версия, известная по истории, - остаётся наше (подрядчик работал на старой копии);
//   - в поставке отклонённая раньше версия - остаётся наше;
//   - у нас ровно версия подрядчика из прежней поставки, в поставке новая - берём поставку;
//   - новое в поставке, в истории нет - берём;
//   - иначе - решение человека: одна единица, что у нас, что пришло, разница, последствия, рекомендация.
//
// Номер версии, имя файла и похожесть деревьев для выбора не используются.
//
// Команды:
//
//	merge1c merge -spec <spec.json>   - объединить объекты поставки, итог - result.json, report.md, папки out
//	merge1c paths -ours <папка> -theirs <папка>   - файлы, которые различаются (по ним гейт достаёт историю)
//	merge1c version
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const engineVersion = "merge1c 1"

type spec struct {
	Delivery     string       `json:"delivery"`
	Stamp        string       `json:"stamp"`
	HistoryIndex string       `json:"historyIndex"`
	BlobDir      string       `json:"blobDir"`
	Rejected     string       `json:"rejected"`
	Ledgers      []string     `json:"ledgers"`
	Decisions    string       `json:"decisions"`
	Objects      []objectSpec `json:"objects"`
	Result       string       `json:"result"`
	Report       string       `json:"report"`
}

type result struct {
	Engine   string          `json:"engine"`
	Delivery string          `json:"delivery"`
	Pending  int             `json:"pending"`
	Objects  []*ObjectResult `json:"objects"`
	Warnings []string        `json:"warnings"`
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "merge":
		fs := flag.NewFlagSet("merge", flag.ExitOnError)
		specPath := fs.String("spec", "", "файл задания")
		_ = fs.Parse(os.Args[2:])
		if *specPath == "" {
			usage()
		}
		res, err := runMerge(*specPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "merge1c: "+err.Error())
			os.Exit(2)
		}
		fmt.Printf("объектов %d, ждут решения %d\n", len(res.Objects), res.Pending)
		if res.Pending > 0 {
			os.Exit(3)
		}
	case "paths":
		fs := flag.NewFlagSet("paths", flag.ExitOnError)
		ours := fs.String("ours", "", "наша папка")
		theirs := fs.String("theirs", "", "папка поставки")
		_ = fs.Parse(os.Args[2:])
		out, _ := json.Marshal(diffPaths(*ours, *theirs))
		fmt.Println(string(out))
	case "version":
		fmt.Println(engineVersion)
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "merge1c merge -spec <файл> | paths -ours <папка> -theirs <папка> | version")
	os.Exit(1)
}

func readJSON(path string, v interface{}) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	data, _ = stripBOM(data)
	return json.Unmarshal(data, v)
}

func loadHistory(path string) (map[string][]historyEntry, error) {
	history := map[string][]historyEntry{}
	if path == "" {
		return history, nil
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return history, nil
		}
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(strings.TrimPrefix(sc.Text(), "\ufeff"))
		if line == "" {
			continue
		}
		var e historyEntry
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			return nil, fmt.Errorf("история %s: %v", path, err)
		}
		dup := false
		for _, x := range history[e.Path] {
			if x.Blob == e.Blob && x.Origin == e.Origin {
				dup = true
			}
		}
		if !dup {
			history[e.Path] = append(history[e.Path], e)
		}
	}
	return history, sc.Err()
}

func runMerge(specPath string) (*result, error) {
	var sp spec
	if err := readJSON(specPath, &sp); err != nil {
		return nil, fmt.Errorf("задание %s: %v", specPath, err)
	}
	history, err := loadHistory(sp.HistoryIndex)
	if err != nil {
		return nil, err
	}
	m := &merger{delivery: sp.Delivery, stamp: sp.Stamp, history: history, blobDir: sp.BlobDir, rejected: map[string]rejectedUnit{}, decisions: map[string]string{}, cache: map[string]*fileHistory{}}
	var rejected []rejectedUnit
	if sp.Rejected != "" {
		if err := readJSON(sp.Rejected, &rejected); err != nil && !os.IsNotExist(err) {
			return nil, fmt.Errorf("отклонённые правки %s: %v", sp.Rejected, err)
		}
	}
	for _, ledger := range sp.Ledgers {
		var l struct {
			Rejected []rejectedUnit `json:"rejected"`
		}
		if err := readJSON(ledger, &l); err != nil {
			m.warnings = append(m.warnings, "журнал поставки "+ledger+" не прочитан: "+err.Error())
			continue
		}
		rejected = append(rejected, l.Rejected...)
	}
	for _, r := range rejected {
		m.rejected[r.Path+"|"+r.Unit+"|"+r.Hash] = r
	}
	if sp.Decisions != "" {
		if err := readJSON(sp.Decisions, &m.decisions); err != nil && !os.IsNotExist(err) {
			return nil, fmt.Errorf("решения %s: %v", sp.Decisions, err)
		}
	}
	res := &result{Engine: engineVersion, Delivery: sp.Delivery}
	for _, obj := range sp.Objects {
		or := m.mergeObject(obj)
		for _, d := range or.Decisions {
			if d.Chosen == "" {
				res.Pending++
			}
		}
		res.Objects = append(res.Objects, or)
	}
	res.Warnings = m.warnings
	if sp.Result != "" {
		data, _ := json.MarshalIndent(res, "", "  ")
		if err := os.WriteFile(sp.Result, data, 0o644); err != nil {
			return nil, err
		}
	}
	if sp.Report != "" {
		if err := os.WriteFile(sp.Report, []byte(renderReport(res)), 0o644); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func diffPaths(ours, theirs string) []string {
	a := listFiles(ours)
	b := listFiles(theirs)
	set := map[string]bool{}
	for p, full := range a {
		other, ok := b[p]
		if !ok {
			set[p] = true
			continue
		}
		x, _ := os.ReadFile(full)
		y, _ := os.ReadFile(other)
		if string(x) != string(y) {
			set[p] = true
		}
	}
	for p := range b {
		if _, ok := a[p]; !ok {
			set[p] = true
		}
	}
	var out []string
	for p := range set {
		out = append(out, filepath.ToSlash(p))
	}
	sort.Strings(out)
	if out == nil {
		out = []string{}
	}
	return out
}
