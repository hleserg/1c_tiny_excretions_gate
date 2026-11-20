package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Классы единиц. Решение принимает человек только в conflict, removed, revived, clash, identity, binary.
const (
	clSame          = "same"           // одинаково
	clOursOnly      = "ours-only"      // в поставке нет: остаётся наше
	clTheirsNew     = "theirs-new"     // новое в поставке, в истории нет: берём
	clTheirsChanged = "theirs-changed" // у нас - версия этого же подрядчика, в поставке новая: берём
	clStale         = "stale"          // в поставке прежняя версия, известная по истории: оставляем наше
	clRejected      = "rejected-again" // в поставке версия, отклонённая раньше: оставляем наше
	clDecided       = "decided"        // решил человек
	clPending       = "pending"        // ждёт решения
	clVersion       = "version"        // версия расширения: новый штамп
)

// Origin - откуда известна версия: "main@<коммит>", "temp@<время>", "delivery:<номер поставки>".
type historyEntry struct {
	Path   string `json:"path"`
	Blob   string `json:"blob"`
	Origin string `json:"origin"`
}

func isDeliveryOrigin(origin string) bool { return strings.HasPrefix(origin, "delivery:") }

// unitHistory - версии одной единицы: отпечаток -> источники.
type unitHistory map[string][]string

// fileHistory - версии файла, разобранные на единицы: ключ -> версии.
type fileHistory struct {
	Units      map[string]unitHistory
	OurFile    bool // файл бывал у нас (main, temp)
	Delivered  bool // файл приходил в прежних поставках
	FileHashes unitHistory
}

type rejectedUnit struct {
	Path     string `json:"path"`
	Unit     string `json:"unit"`
	Hash     string `json:"hash"`
	Delivery string `json:"delivery"`
	Decision string `json:"decision"`
}

// Decision - вопрос оператору: один выбор из двух.
type Decision struct {
	ID           string `json:"id"`
	Object       string `json:"object"`
	File         string `json:"file"`
	Unit         string `json:"unit"`
	Title        string `json:"title"`
	Kind         string `json:"kind"`
	Ours         string `json:"ours"`
	Theirs       string `json:"theirs"`
	Diff         string `json:"diff"`
	Consequences string `json:"consequences"`
	Recommended  string `json:"recommended"`
	Why          string `json:"why"`
	Critical     bool   `json:"critical"`
	Chosen       string `json:"chosen"`
	OursHash     string `json:"oursHash"`
	TheirsHash   string `json:"theirsHash"`
}

// Change - что стало с единицей, которая в поставке не такая, как у нас.
type Change struct {
	File       string `json:"file"`
	Unit       string `json:"unit"`
	Title      string `json:"title"`
	Class      string `json:"class"`
	Result     string `json:"result"` // ours, theirs, absent
	Evidence   string `json:"evidence"`
	OursHash   string `json:"oursHash,omitempty"`
	TheirsHash string `json:"theirsHash,omitempty"`
	Decision   string `json:"decision,omitempty"`
}

type objectSpec struct {
	Kind         string `json:"kind"` // extension, processing
	Name         string `json:"name"`
	Title        string `json:"title"`
	RepoPath     string `json:"repoPath"`
	Ours         string `json:"ours"`
	Theirs       string `json:"theirs"`
	Out          string `json:"out"`
	First        *bool  `json:"first"`
	Opaque       bool   `json:"opaque"`
	OpaqueReason string `json:"opaqueReason"`
	TheirsFile   string `json:"theirsFile"`
	TheirsSHA256 string `json:"theirsSha256"`
	OursSHA256   string `json:"oursSha256"`
}

type ObjectResult struct {
	Kind      string         `json:"kind"`
	Name      string         `json:"name"`
	Title     string         `json:"title"`
	RepoPath  string         `json:"repoPath"`
	Status    string         `json:"status"` // unchanged, changed, new, pending, opaque
	First     bool           `json:"first"`
	Counts    map[string]int `json:"counts"`
	Changes   []Change       `json:"changes"`
	Decisions []*Decision    `json:"decisions"`
	Accepted  []Change       `json:"accepted"`
	Rejected  []rejectedUnit `json:"rejected"`
	Problems  []string       `json:"problems"`
	Files     []string       `json:"files"` // изменённые файлы результата (пути от корня объекта)
	Binary    string         `json:"binary,omitempty"`
}

type merger struct {
	delivery  string
	stamp     string
	history   map[string][]historyEntry // путь в репозитории -> версии
	blobDir   string
	rejected  map[string]rejectedUnit // путь|единица|отпечаток
	decisions map[string]string
	cache     map[string]*fileHistory
	warnings  []string
}

func decisionID(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "|")))
	return hex.EncodeToString(sum[:6])
}

// own - версия из этой же поставки (гейт кладёт разобранную поставку в историю заранее): в сравнении не участвует.
func (m *merger) own(origin string) bool {
	return m.delivery != "" && origin == "delivery:"+m.delivery
}

func (m *merger) blob(sha string) ([]byte, bool) {
	data, err := os.ReadFile(filepath.Join(m.blobDir, sha))
	if err != nil {
		return nil, false
	}
	return data, true
}

// fileUnits - единицы файла по его виду: BSL - процедуры, XML объекта и прав - узлы; иначе - файл целиком.
func fileUnits(path string, data []byte) map[string]string {
	if !isText(data) {
		return map[string]string{"file": string(data)}
	}
	switch strings.ToLower(filepath.Ext(path)) {
	case ".bsl":
		mod := parseBSL(data)
		if mod.Err == "" {
			units, _, _ := bslUnits(mod)
			return units
		}
	case ".xml":
		doc := parseXMLDoc(data)
		if doc.Kind != ckLeaf {
			units := flatten(doc)
			units["root"] = rootIdentity(doc)
			return units
		}
	}
	return map[string]string{"file": string(data)}
}

func rootIdentity(doc *xmlDoc) string {
	if doc.Kind == ckObject {
		return doc.Top.Name + " " + doc.Top.Attrs["uuid"]
	}
	return doc.Root.Name
}

// fileHistoryOf - версии файла из истории, разобранные на единицы.
func (m *merger) fileHistoryOf(repoPath string) *fileHistory {
	if h, ok := m.cache[repoPath]; ok {
		return h
	}
	h := &fileHistory{Units: map[string]unitHistory{}, FileHashes: unitHistory{}}
	for _, entry := range m.history[repoPath] {
		if m.own(entry.Origin) {
			continue
		}
		if isDeliveryOrigin(entry.Origin) {
			h.Delivered = true
		} else {
			h.OurFile = true
		}
		data, ok := m.blob(entry.Blob)
		if !ok {
			m.warnings = append(m.warnings, fmt.Sprintf("нет содержимого версии %s файла %s (%s): в сравнении не участвует", entry.Blob, repoPath, entry.Origin))
			continue
		}
		fh := unitHash(data)
		h.FileHashes[fh] = append(h.FileHashes[fh], entry.Origin)
		for key, text := range fileUnits(repoPath, data) {
			hash := unitHash([]byte(text))
			if h.Units[key] == nil {
				h.Units[key] = unitHistory{}
			}
			h.Units[key][hash] = append(h.Units[key][hash], entry.Origin)
		}
	}
	m.cache[repoPath] = h
	return h
}

// side - версия единицы с одной стороны.
type side struct {
	Present bool
	Text    string
	Hash    string
}

func mkSide(text string, present bool) side {
	if !present {
		return side{}
	}
	return side{Present: true, Text: text, Hash: unitHash([]byte(text))}
}

type verdict struct {
	Class    string
	Take     string // ours, theirs, absent
	Evidence string
	Decision *Decision
}

func originsText(origins []string) string {
	uniq := map[string]bool{}
	var list []string
	for _, o := range origins {
		if !uniq[o] {
			uniq[o] = true
			list = append(list, o)
		}
	}
	sort.Strings(list)
	if len(list) > 3 {
		return strings.Join(list[:3], ", ") + fmt.Sprintf(" и ещё %d", len(list)-3)
	}
	return strings.Join(list, ", ")
}

// unitCtx - всё, что нужно правилам про одну единицу.
type unitCtx struct {
	Object, File, RepoFile, Key, Title string
	First                              bool
	Hist                               unitHistory
	// Delivered - единица бывала в прежних поставках; OursKnown - бывала у нас.
	Delivered, OursKnown bool
	Critical             bool
}

func (c unitCtx) contractorHas(hash string) bool {
	for _, o := range c.Hist[hash] {
		if isDeliveryOrigin(o) {
			return true
		}
	}
	return false
}

func (c unitCtx) oursOnlyVersions() []string {
	var out []string
	for hash, origins := range c.Hist {
		for _, o := range origins {
			if !isDeliveryOrigin(o) {
				out = append(out, hash)
				break
			}
		}
	}
	return out
}

// classify - правила единицы. Совпадение номера версии, имени файла или похожесть дерева тут не участвуют:
// только тождество текста с версией, которую мы знаем (история git, прежние поставки, отклонённые правки).
func (m *merger) classify(c unitCtx, o, t side) verdict {
	if o.Present == t.Present && (!o.Present || o.Hash == t.Hash) {
		return verdict{Class: clSame, Take: "ours"}
	}
	rejectedHash := "absent"
	if t.Present {
		rejectedHash = t.Hash
	}
	if r, ok := m.rejected[c.RepoFile+"|"+c.Key+"|"+rejectedHash]; ok {
		what := "эту версию"
		if !t.Present {
			what = "удаление этой части"
		}
		return verdict{Class: clRejected, Take: takeOurs(o), Evidence: fmt.Sprintf("%s отклонили в поставке %s (решение %s)", what, r.Delivery, r.Decision)}
	}
	switch {
	case !t.Present:
		// В поставке нет. Первая поставка или единица наша (подрядчик её не поставлял) - ничего не удаляем.
		if c.First || !c.Delivered {
			why := "в поставке нет; единица наша, подрядчик её не поставлял - остаётся"
			if c.First {
				why = "в поставке нет; первая поставка ничего не удаляет - остаётся"
			}
			return verdict{Class: clOursOnly, Take: "ours", Evidence: why}
		}
		d := m.decision(c, "removed", o, t)
		d.Consequences = "удалить: " + c.Title + " исчезнет, проверь, кто её вызывает; оставить: останется как сейчас, в следующих поставках отсутствие не будет вопросом"
		if c.contractorHas(o.Hash) {
			d.Recommended, d.Why = "theirs", "у нас ровно та версия, что подрядчик поставлял раньше: удаление - его решение по его коду"
		} else {
			d.Recommended, d.Why = "ours", "у нас эта часть менялась после поставки: удаление потеряло бы нашу правку"
		}
		return m.decided(c, d, o, t)
	case !o.Present:
		if hist, ok := c.Hist[t.Hash]; ok && c.OursKnown {
			return verdict{Class: clStale, Take: "absent", Evidence: "у нас эту часть удалили; в поставке прежняя версия (" + originsText(hist) + ") - не возвращаем"}
		}
		if c.OursKnown {
			d := m.decision(c, "revived", o, t)
			d.Consequences = "вернуть: часть, которую у нас удалили, появится снова в версии подрядчика; не брать: останется удалённой"
			d.Recommended, d.Why = "ours", "у нас её удалили сознательно, а подрядчик менял старую копию"
			return m.decided(c, d, o, t)
		}
		return verdict{Class: clTheirsNew, Take: "theirs", Evidence: "новое в поставке, в нашей истории этого нет"}
	}
	if hist, ok := c.Hist[t.Hash]; ok {
		return verdict{Class: clStale, Take: "ours", Evidence: "в поставке прежняя версия, известная по истории (" + originsText(hist) + "); у нас она изменена позже - оставлено наше"}
	}
	if c.contractorHas(o.Hash) {
		return verdict{Class: clTheirsChanged, Take: "theirs", Evidence: "у нас эта часть - как в прежней поставке (" + originsText(c.Hist[o.Hash]) + "), в поставке новая правка подрядчика - берём"}
	}
	kind := "conflict"
	if c.Critical {
		kind = "clash"
	}
	d := m.decision(c, kind, o, t)
	d.Consequences = "оставить наше: правка поставки в этой части не попадёт в git и в следующих поставках будет считаться отклонённой; взять поставку: наша версия заменится версией подрядчика"
	ours := c.oursOnlyVersions()
	if !c.Critical && len(ours) == 1 && ours[0] == o.Hash {
		d.Recommended, d.Why = "theirs", "у нас эта часть не менялась за всю известную историю - правка, скорее всего, подрядчика"
	} else {
		d.Recommended, d.Why = "ours", "у нас эта часть менялась: без известной общей версии намерение подрядчика не определить"
	}
	if c.Critical {
		d.Recommended, d.Why = "ours", "затронута идентичность объекта: замена версии - новый объект для платформы"
	}
	return m.decided(c, d, o, t)
}

func takeOurs(o side) string {
	if o.Present {
		return "ours"
	}
	return "absent"
}

func (m *merger) decision(c unitCtx, kind string, o, t side) *Decision {
	d := &Decision{
		ID: decisionID(c.Object, c.File, c.Key, o.Hash, t.Hash), Object: c.Object, File: c.File, Unit: c.Key,
		Title: c.Title, Kind: kind, Critical: c.Critical, OursHash: o.Hash, TheirsHash: t.Hash,
	}
	if o.Present {
		d.Ours = shortText(normalize([]byte(o.Text)), 12)
	} else {
		d.Ours = "(нет)"
	}
	if t.Present {
		d.Theirs = shortText(normalize([]byte(t.Text)), 12)
	} else {
		d.Theirs = "(нет)"
	}
	d.Diff = unifiedDiff(normalize([]byte(o.Text)), normalize([]byte(t.Text)), 2, 60)
	return d
}

// decided - решение уже есть (файл решений) или ждёт человека.
func (m *merger) decided(c unitCtx, d *Decision, o, t side) verdict {
	choice := m.decisions[d.ID]
	if choice == "ours" || choice == "theirs" {
		d.Chosen = choice
		take := "ours"
		if choice == "theirs" {
			take = "theirs"
			if !t.Present {
				take = "absent"
			}
		} else if !o.Present {
			take = "absent"
		}
		return verdict{Class: clDecided, Take: take, Evidence: "решение " + d.ID + ": " + choiceText(choice), Decision: d}
	}
	return verdict{Class: clPending, Take: takeOurs(o), Evidence: "ждёт решения " + d.ID, Decision: d}
}

func choiceText(choice string) string {
	if choice == "theirs" {
		return "взять поставку"
	}
	return "оставить наше"
}

// objectRun - объединение одного объекта.
type objectRun struct {
	m     *merger
	spec  objectSpec
	res   *ObjectResult
	first bool
}

func (m *merger) mergeObject(spec objectSpec) *ObjectResult {
	res := &ObjectResult{Kind: spec.Kind, Name: spec.Name, Title: spec.Title, RepoPath: spec.RepoPath, Counts: map[string]int{}}
	run := &objectRun{m: m, spec: spec, res: res}
	run.first = true
	prefix := strings.TrimSuffix(spec.RepoPath, "/") + "/"
	for path, entries := range m.history {
		if strings.HasPrefix(path, prefix) {
			for _, e := range entries {
				if isDeliveryOrigin(e.Origin) && !m.own(e.Origin) {
					run.first = false
				}
			}
		}
	}
	if spec.First != nil {
		run.first = *spec.First
	}
	res.First = run.first
	if spec.Opaque {
		run.mergeOpaque()
		return res
	}
	oursFiles := listFiles(spec.Ours)
	theirsFiles := listFiles(spec.Theirs)
	all := map[string]bool{}
	for p := range oursFiles {
		all[p] = true
	}
	for p := range theirsFiles {
		all[p] = true
	}
	var paths []string
	for p := range all {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	changed := false
	outputs := map[string][]byte{}
	for _, rel := range paths {
		oData, oOk := readIf(spec.Ours, rel, oursFiles)
		tData, tOk := readIf(spec.Theirs, rel, theirsFiles)
		data, present, fileChanged := run.mergeFile(rel, oData, oOk, tData, tOk)
		if present {
			outputs[rel] = data
		}
		if fileChanged {
			changed = true
			res.Files = append(res.Files, rel)
		}
	}
	// Версия расширения: при любой принятой правке - новый штамп (как у ручных правок, ГГГГММДД.ЧЧММСС).
	if spec.Kind == "extension" && changed && m.stamp != "" {
		if cfg, ok := outputs["Configuration.xml"]; ok {
			if next, did := setExtensionVersion(cfg, m.stamp); did {
				outputs["Configuration.xml"] = next
				res.Counts[clVersion]++
				if !contains(res.Files, "Configuration.xml") {
					res.Files = append(res.Files, "Configuration.xml")
				}
			}
		}
	}
	res.Problems = append(res.Problems, checkFormHandlers(outputs, res.Files)...)
	pending := 0
	for _, d := range res.Decisions {
		if d.Chosen == "" {
			pending++
		}
	}
	switch {
	case pending > 0:
		res.Status = "pending"
	case len(oursFiles) == 0 && len(theirsFiles) > 0:
		res.Status = "new"
	case changed:
		res.Status = "changed"
	default:
		res.Status = "unchanged"
	}
	if spec.Out != "" && pending == 0 {
		_ = os.RemoveAll(spec.Out)
		for rel, data := range outputs {
			target := filepath.Join(spec.Out, filepath.FromSlash(rel))
			_ = os.MkdirAll(filepath.Dir(target), 0o755)
			if err := os.WriteFile(target, data, 0o644); err != nil {
				res.Problems = append(res.Problems, "не записан "+rel+": "+err.Error())
			}
		}
	}
	return res
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

var reVersion = regexp.MustCompile(`(<Properties>[\s\S]*?<Version>)([^<]*)(</Version>)`)

func setExtensionVersion(data []byte, stamp string) ([]byte, bool) {
	loc := reVersion.FindSubmatchIndex(data)
	if loc == nil {
		return data, false
	}
	var out []byte
	out = append(out, data[:loc[4]]...)
	out = append(out, stamp...)
	out = append(out, data[loc[5]:]...)
	return out, true
}

func listFiles(dir string) map[string]string {
	files := map[string]string{}
	if dir == "" {
		return files
	}
	_ = filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(dir, path)
		rel = filepath.ToSlash(rel)
		if rel == "ConfigDumpInfo.xml" {
			return nil
		}
		files[rel] = path
		return nil
	})
	return files
}

func readIf(dir, rel string, files map[string]string) ([]byte, bool) {
	path, ok := files[rel]
	if !ok {
		return nil, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	return data, true
}

func (r *objectRun) record(c unitCtx, o, t side, v verdict) {
	r.res.Counts[v.Class]++
	if v.Class == clSame {
		return
	}
	ch := Change{File: c.File, Unit: c.Key, Title: c.Title, Class: v.Class, Result: v.Take, Evidence: v.Evidence, OursHash: o.Hash, TheirsHash: t.Hash}
	if v.Decision != nil {
		ch.Decision = v.Decision.ID
		r.res.Decisions = append(r.res.Decisions, v.Decision)
	}
	r.res.Changes = append(r.res.Changes, ch)
	if v.Take == "theirs" || (v.Take == "absent" && o.Present && v.Class == clDecided) {
		r.res.Accepted = append(r.res.Accepted, ch)
	}
	if v.Class == clDecided && v.Decision.Chosen == "ours" {
		hash := "absent"
		if t.Present {
			hash = t.Hash
		}
		r.res.Rejected = append(r.res.Rejected, rejectedUnit{Path: c.RepoFile, Unit: c.Key, Hash: hash, Delivery: r.m.delivery, Decision: v.Decision.ID})
	}
}

func (r *objectRun) ctx(rel, key, title string, fh *fileHistory, critical bool) unitCtx {
	c := unitCtx{Object: r.spec.Name, File: rel, RepoFile: strings.TrimSuffix(r.spec.RepoPath, "/") + "/" + rel, Key: key, Title: title, First: r.first, Critical: critical}
	c.Hist = fh.Units[key]
	if c.Hist == nil {
		c.Hist = unitHistory{}
	}
	for _, origins := range c.Hist {
		for _, o := range origins {
			if isDeliveryOrigin(o) {
				c.Delivered = true
			} else {
				c.OursKnown = true
			}
		}
	}
	return c
}

// mergeFile - объединение одного файла объекта. Возвращает итог, есть ли файл и отличается ли он от нашего.
func (r *objectRun) mergeFile(rel string, oData []byte, oOk bool, tData []byte, tOk bool) ([]byte, bool, bool) {
	repoFile := strings.TrimSuffix(r.spec.RepoPath, "/") + "/" + rel
	fh := r.m.fileHistoryOf(repoFile)
	if oOk && tOk && string(oData) == string(tData) {
		r.res.Counts[clSame]++
		return oData, true, false
	}
	fileTitle := "файл " + rel
	// Файл целиком: нет с одной стороны, двоичный, не разобрался.
	wholeFile := func() ([]byte, bool, bool) {
		c := r.ctx(rel, "file", fileTitle, fh, false)
		// Для файла целиком история - по отпечаткам файлов.
		c.Hist = fh.FileHashes
		c.Delivered, c.OursKnown = fh.Delivered, fh.OurFile
		o := mkSide(string(oData), oOk)
		t := mkSide(string(tData), tOk)
		v := r.m.classify(c, o, t)
		if v.Decision != nil && (!isText(oData) || !isText(tData)) {
			v.Decision.Kind = "binary"
			v.Decision.Ours, v.Decision.Theirs, v.Decision.Diff = binaryLabel(oData, oOk), binaryLabel(tData, tOk), ""
			v.Decision.Consequences = "содержимое не сравнить построчно (двоичное): выбирается целая версия файла с фиксацией sha256; " + v.Decision.Consequences
		}
		r.record(c, o, t, v)
		switch v.Take {
		case "theirs":
			return tData, true, true
		case "absent":
			return nil, false, oOk
		}
		return oData, oOk, false
	}
	if !oOk || !tOk || !isText(oData) || !isText(tData) {
		return wholeFile()
	}
	switch strings.ToLower(filepath.Ext(rel)) {
	case ".bsl":
		om, tm := parseBSL(oData), parseBSL(tData)
		if om.Err != "" || tm.Err != "" {
			return wholeFile()
		}
		return r.mergeBSL(rel, fh, om, tm)
	case ".xml":
		od, td := parseXMLDoc(oData), parseXMLDoc(tData)
		if od.Kind == ckLeaf || td.Kind != od.Kind {
			return wholeFile()
		}
		if rootIdentity(od) != rootIdentity(td) {
			c := r.ctx(rel, "root", fileTitle+": "+describeRoot(od), fh, true)
			o, t := mkSide(rootIdentity(od), true), mkSide(rootIdentity(td), true)
			d := r.m.decision(c, "identity", o, t)
			d.Ours, d.Theirs = describeRoot(od), describeRoot(td)
			d.Consequences = "в поставке объект с другим UUID: для платформы это другой объект (данные и ссылки нашего потеряются при замене); оставить наше - объект поставки в этом файле не принимается"
			d.Recommended, d.Why = "ours", "UUID разошлись: подрядчик пересоздал объект или работал на другой основе"
			v := r.m.decided(c, d, o, t)
			r.record(c, o, t, v)
			if v.Take == "theirs" {
				return tData, true, true
			}
			return oData, true, false
		}
		return r.mergeXML(rel, fh, od, td)
	}
	return wholeFile()
}

func describeRoot(doc *xmlDoc) string {
	if doc.Kind == ckObject {
		name := propName(doc.Top)
		return fmt.Sprintf("%s %s (UUID %s)", doc.Top.Name, name, doc.Top.Attrs["uuid"])
	}
	return doc.Root.Name
}

func binaryLabel(data []byte, ok bool) string {
	if !ok {
		return "(нет)"
	}
	return fmt.Sprintf("двоичный файл, %d байт, sha256 %s", len(data), fileSHA256(data))
}

func (r *objectRun) mergeBSL(rel string, fh *fileHistory, om, tm *bslModule) ([]byte, bool, bool) {
	ou, oOrder, oTitles := bslUnits(om)
	tu, tOrder, tTitles := bslUnits(tm)
	results := map[string]bslResult{}
	keys := append([]string{}, oOrder...)
	for _, k := range tOrder {
		if _, ok := ou[k]; !ok {
			keys = append(keys, k)
		}
	}
	changed := false
	for _, key := range keys {
		ot, oOk := ou[key]
		tt, tOk := tu[key]
		title := oTitles[key]
		if title == "" {
			title = tTitles[key]
		}
		title = "модуль " + rel + ": " + title
		c := r.ctx(rel, key, title, fh, false)
		o, t := mkSide(ot, oOk), mkSide(tt, tOk)
		v := r.m.classify(c, o, t)
		r.record(c, o, t, v)
		switch v.Take {
		case "theirs":
			results[key] = bslResult{Present: true, Text: tt, FromT: true}
			if v.Class != clSame {
				changed = true
			}
		case "absent":
			results[key] = bslResult{Present: false}
			if oOk {
				changed = true
			}
		default:
			if oOk {
				results[key] = bslResult{Present: true, Text: ot}
			} else {
				results[key] = bslResult{Present: false}
			}
		}
	}
	if !changed {
		return []byte(strings.Join(om.Lines, "")), true, false
	}
	out := rebuildBSL(om, tm, results)
	if om.BOM {
		return []byte(out), true, true
	}
	return []byte(out), true, true
}

// mergeXML - объединение файла объекта метаданных или прав роли по узлам.
func (r *objectRun) mergeXML(rel string, fh *fileHistory, od, td *xmlDoc) ([]byte, bool, bool) {
	text, changed := r.mergeNode(rel, fh, od, td, od.Top, td.Top, od.Kind, "")
	if !changed {
		return od.Data, true, false
	}
	var out []byte
	out = append(out, od.Data[:od.Top.Start]...)
	out = append(out, text...)
	out = append(out, od.Data[od.Top.End:]...)
	return out, true, true
}

// mergeNode - текст объединённого элемента (o и t есть оба) и изменился ли он против нашего.
func (r *objectRun) mergeNode(rel string, fh *fileHistory, od, td *xmlDoc, o, t *xel, kind int, prefix string) (string, bool) {
	oText := string(od.Data[o.Start:o.End])
	tText := string(td.Data[t.Start:t.End])
	if oText == tText {
		return oText, false
	}
	oKids := keyedChildren(kind, o)
	tKids := keyedChildren(kind, t)
	oByKey := map[string]xkid{}
	for _, k := range oKids {
		oByKey[k.Key] = k
	}
	tByKey := map[string]xkid{}
	for _, k := range tKids {
		tByKey[k.Key] = k
	}
	// Одноимённые подчинённые объекты с разными UUID - один вопрос о паре.
	clash := map[string]string{} // ключ поставки -> ключ нашего
	if kind == ckChildren {
		names := map[string]string{}
		for _, k := range oKids {
			if _, ok := tByKey[k.Key]; !ok && k.Kind == ckObject {
				names[k.El.Name+"|"+strings.ToLower(propName(k.El))] = k.Key
			}
		}
		for _, k := range tKids {
			if _, ok := oByKey[k.Key]; !ok && k.Kind == ckObject {
				if ok2, found := names[k.El.Name+"|"+strings.ToLower(propName(k.El))]; found && propName(k.El) != "" {
					clash[k.Key] = ok2
				}
			}
		}
	}
	type kidResult struct {
		text    string // блок для вставки или замены
		present bool
		fromT   bool
		merged  string // объединённый текст элемента (рекурсия), если есть
	}
	results := map[string]kidResult{}
	changed := false
	full := func(key string) string {
		if prefix == "" {
			return key
		}
		return prefix + "/" + key
	}
	clashTheirs := map[string]bool{}
	for tKey, oKey := range clash {
		ok, tk := oByKey[oKey], tByKey[tKey]
		c := r.ctx(rel, full(oKey), "файл "+rel+": "+ok.Title, fh, true)
		o2 := mkSide(string(od.Data[ok.El.Start:ok.El.End]), true)
		t2 := mkSide(string(td.Data[tk.El.Start:tk.El.End]), true)
		d := r.m.decision(c, "clash", o2, t2)
		d.Title = "файл " + rel + ": " + ok.Title + " - в поставке одноимённый объект с другим UUID"
		d.Ours = "UUID " + ok.El.Attrs["uuid"]
		d.Theirs = "UUID " + tk.El.Attrs["uuid"]
		d.Consequences = "оставить наше: объект поставки с тем же именем не принимается; взять поставку: наш объект заменится новым (для платформы - удаление и создание: данные нашего в базе пропадут)"
		d.Recommended, d.Why = "ours", "данные в базе привязаны к UUID нашего объекта"
		v := r.m.decided(c, d, o2, t2)
		r.record(c, o2, t2, v)
		if v.Take == "theirs" {
			s, e := block(td.Data, tk.El)
			results[oKey] = kidResult{text: string(td.Data[s:e]), present: true, fromT: true}
			changed = true
		}
		clashTheirs[tKey] = true
	}
	for _, k := range oKids {
		if _, done := results[k.Key]; done {
			continue
		}
		tk, tOk := tByKey[k.Key]
		oBlockS, oBlockE := block(od.Data, k.El)
		oBlock := string(od.Data[oBlockS:oBlockE])
		if !tOk {
			if isClashTarget(clash, k.Key) {
				results[k.Key] = kidResult{text: oBlock, present: true}
				continue
			}
			c := r.ctx(rel, full(k.Key), "файл "+rel+": "+k.Title, fh, false)
			o2 := mkSide(string(od.Data[k.El.Start:k.El.End]), true)
			v := r.m.classify(c, o2, side{})
			r.record(c, o2, side{}, v)
			if v.Take == "absent" {
				results[k.Key] = kidResult{present: false}
				changed = true
			} else {
				results[k.Key] = kidResult{text: oBlock, present: true}
			}
			continue
		}
		oEl := string(od.Data[k.El.Start:k.El.End])
		tEl := string(td.Data[tk.El.Start:tk.El.End])
		if oEl == tEl {
			r.res.Counts[clSame]++
			results[k.Key] = kidResult{text: oBlock, present: true}
			continue
		}
		critical := k.Key == "prop:ExtendedConfigurationObject" || k.Key == "prop:ObjectBelonging" || k.Key == "internal"
		if k.Kind != ckLeaf && !critical {
			merged, did := r.mergeNode(rel, fh, od, td, k.El, tk.El, k.Kind, full(k.Key))
			if did {
				changed = true
				lead := string(od.Data[oBlockS:k.El.Start])
				tail := string(od.Data[k.El.End:oBlockE])
				results[k.Key] = kidResult{text: lead + merged + tail, present: true, merged: merged}
			} else {
				results[k.Key] = kidResult{text: oBlock, present: true}
			}
			continue
		}
		if kind == ckProps && k.Key == "prop:Version" && r.spec.Kind == "extension" && prefix == "props" && rel == "Configuration.xml" {
			// Версия расширения - не вопрос: при любой правке ставится новый штамп.
			results[k.Key] = kidResult{text: oBlock, present: true}
			continue
		}
		c := r.ctx(rel, full(k.Key), "файл "+rel+": "+k.Title, fh, critical)
		o2, t2 := mkSide(oEl, true), mkSide(tEl, true)
		v := r.m.classify(c, o2, t2)
		r.record(c, o2, t2, v)
		if v.Take == "theirs" {
			ts, te := block(td.Data, tk.El)
			results[k.Key] = kidResult{text: string(td.Data[ts:te]), present: true, fromT: true}
			changed = true
		} else {
			results[k.Key] = kidResult{text: oBlock, present: true}
		}
	}
	// Новое в поставке: после того же соседа, что у подрядчика.
	insertAfter := map[string][]string{} // ключ нашего соседа ("" - в начало) -> блоки
	prev := ""
	for _, k := range tKids {
		if _, ok := oByKey[k.Key]; ok {
			if res, ok2 := results[k.Key]; ok2 && res.present {
				prev = k.Key
			}
			continue
		}
		if clashTheirs[k.Key] {
			continue
		}
		c := r.ctx(rel, full(k.Key), "файл "+rel+": "+k.Title, fh, false)
		t2 := mkSide(string(td.Data[k.El.Start:k.El.End]), true)
		v := r.m.classify(c, side{}, t2)
		r.record(c, side{}, t2, v)
		if v.Take == "theirs" {
			s, e := block(td.Data, k.El)
			insertAfter[prev] = append(insertAfter[prev], string(td.Data[s:e]))
			changed = true
		}
	}
	if !changed {
		return oText, false
	}
	var sb strings.Builder
	if len(oKids) == 0 {
		// У нас пусто (<ChildObjects/> или без подчинённых): открывающий и закрывающий теги - как у поставки.
		blocks := insertAfter[""]
		if len(tKids) == 0 || len(blocks) == 0 {
			return oText, false
		}
		s0, _ := block(td.Data, tKids[0].El)
		_, e1 := block(td.Data, tKids[len(tKids)-1].El)
		sb.WriteString(string(td.Data[t.Start:s0]))
		for _, b := range blocks {
			sb.WriteString(b)
		}
		sb.WriteString(string(td.Data[e1:t.End]))
		return sb.String(), true
	}
	s0, _ := block(od.Data, oKids[0].El)
	_, e1 := block(od.Data, oKids[len(oKids)-1].El)
	sb.WriteString(string(od.Data[o.Start:s0]))
	for _, b := range insertAfter[""] {
		sb.WriteString(b)
	}
	for _, k := range oKids {
		res := results[k.Key]
		if res.present {
			sb.WriteString(res.text)
		}
		for _, b := range insertAfter[k.Key] {
			sb.WriteString(b)
		}
	}
	sb.WriteString(string(od.Data[e1:o.End]))
	return sb.String(), true
}

func isClashTarget(clash map[string]string, oKey string) bool {
	for _, v := range clash {
		if v == oKey {
			return true
		}
	}
	return false
}

// mergeOpaque - объект не разобрать (защищён, двоичный): выбор целой версии с фиксацией sha256.
func (r *objectRun) mergeOpaque() {
	spec := r.spec
	c := unitCtx{Object: spec.Name, File: "(файл целиком)", RepoFile: spec.RepoPath, Key: "binary", Title: spec.Title + ": файл целиком", First: r.first, Hist: unitHistory{}}
	for _, e := range r.m.history["binary:"+spec.RepoPath] {
		if r.m.own(e.Origin) {
			continue
		}
		c.Hist[e.Blob] = append(c.Hist[e.Blob], e.Origin)
		if isDeliveryOrigin(e.Origin) {
			c.Delivered = true
		} else {
			c.OursKnown = true
		}
	}
	o := side{Present: spec.OursSHA256 != "", Hash: spec.OursSHA256, Text: spec.OursSHA256}
	t := side{Present: spec.TheirsSHA256 != "", Hash: spec.TheirsSHA256, Text: spec.TheirsSHA256}
	r.res.Binary = spec.TheirsSHA256
	v := verdict{}
	if o.Present && o.Hash == t.Hash {
		v = verdict{Class: clSame, Take: "ours"}
	} else if hist, ok := c.Hist[t.Hash]; ok {
		v = verdict{Class: clStale, Take: takeOurs(o), Evidence: "этот файл уже приходил или стоял у нас (" + originsText(hist) + ")"}
	} else {
		d := r.m.decision(c, "binary", o, t)
		d.Ours = "нет"
		if o.Present {
			d.Ours = "sha256 " + o.Hash
		}
		d.Theirs = "sha256 " + t.Hash
		d.Diff = ""
		why := spec.OpaqueReason
		if why == "" {
			why = "исходники не выгружаются"
		}
		d.Consequences = "проверка исходников невозможна (" + why + "): принимается или отклоняется файл целиком; принятый файл хранится в закрытом git по sha256 и ставится в temp только с этим хешем"
		d.Recommended, d.Why = "theirs", "другого способа получить правку подрядчика нет; на temp проверяется подключение и формы"
		v = r.m.decided(c, d, o, t)
	}
	r.record(c, o, t, v)
	switch {
	case v.Class == clPending:
		r.res.Status = "pending"
	case v.Take == "theirs":
		r.res.Status = "opaque"
	default:
		r.res.Status = "unchanged"
	}
}

// checkFormHandlers - у каждого обработчика формы (Event, Action в Form.xml) есть метод в модуле формы.
func checkFormHandlers(outputs map[string][]byte, changed []string) []string {
	touched := map[string]bool{}
	for _, f := range changed {
		dir := f
		if strings.HasSuffix(f, "/Ext/Form.xml") {
			dir = strings.TrimSuffix(f, "/Ext/Form.xml")
		} else if strings.HasSuffix(f, "/Ext/Form/Module.bsl") {
			dir = strings.TrimSuffix(f, "/Ext/Form/Module.bsl")
		} else {
			continue
		}
		touched[dir] = true
	}
	var problems []string
	var dirs []string
	for d := range touched {
		dirs = append(dirs, d)
	}
	sort.Strings(dirs)
	for _, dir := range dirs {
		form, ok := outputs[dir+"/Ext/Form.xml"]
		if !ok {
			continue
		}
		declared := map[string]bool{}
		if module, ok := outputs[dir+"/Ext/Form/Module.bsl"]; ok {
			mod := parseBSL(module)
			for _, mm := range mod.Methods {
				declared[strings.ToLower(mm.Name)] = true
			}
		}
		root, err := parseXMLTree(form)
		if err != nil {
			problems = append(problems, dir+"/Ext/Form.xml не разбирается: "+err.Error())
			continue
		}
		var walk func(el *xel)
		walk = func(el *xel) {
			if (el.Name == "Event" || el.Name == "Action") && len(el.Children) == 0 && el.Text != "" && !strings.Contains(el.Text, ".") {
				if !declared[strings.ToLower(el.Text)] {
					problems = append(problems, fmt.Sprintf("%s: обработчик %s (%s) - нет метода в модуле формы", dir, el.Text, el.Attrs["name"]))
				}
			}
			for _, c := range el.Children {
				walk(c)
			}
		}
		walk(root)
	}
	return problems
}
