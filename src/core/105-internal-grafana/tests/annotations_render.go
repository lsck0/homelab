// Renders every provisioned annotation the way Grafana 12 expands it (pkg/services/ngalert/state/template), once
// with a value for query A and once without one, as an evaluation that errors or finds no data has none. Grafana
// keeps an annotation it cannot expand as the raw template, which then reaches telegram and ntfy verbatim.
//
// Usage: go run annotations_render.go <rules.json>
//
// The functions are stubs with the signature and the failure of Prometheus' template functions: a value they cannot
// read as a number is an error. A function no stub covers fails the parse, so a new one is added here first.
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"text/template"
)

// -----------------------------------------------------------------------------
// TYPES
// -----------------------------------------------------------------------------

type Value struct {
	Labels map[string]string
	Value  float64
}

func (v Value) String() string { return strconv.FormatFloat(v.Value, 'f', -1, 64) }

type Data struct {
	Labels map[string]string
	Values map[string]Value
	Value  any
}

type Rule struct {
	UID         string            `json:"uid"`
	Annotations map[string]string `json:"annotations"`
}

type Group struct {
	Rules []Rule `json:"rules"`
}

// -----------------------------------------------------------------------------
// INTERNAL
// -----------------------------------------------------------------------------

// grafana's prefix: the variables a rule's template reads
const templatePrefix = "{{- $labels := .Labels -}}{{- $values := .Values -}}{{- $value := .Value -}}"

func number(v any) (float64, error) {
	switch n := v.(type) {
	case float64:
		return n, nil
	case int:
		return float64(n), nil
	case string:
		return strconv.ParseFloat(n, 64)
	}
	return math.NaN(), fmt.Errorf("can't convert %v to float", v)
}

func numeric(v any) (string, error) {
	n, err := number(v)
	if err != nil {
		return "", err
	}
	return strconv.FormatFloat(n, 'f', -1, 64), nil
}

var funcs = template.FuncMap{
	"humanize":           numeric,
	"humanize1024":       numeric,
	"humanizePercentage": numeric,
	"humanizeDuration":   numeric,
}

func render(text string, data Data) (string, error) {
	parsed, err := template.New("annotation").Option("missingkey=invalid").Funcs(funcs).Parse(templatePrefix + text)
	if err != nil {
		return "", err
	}
	var out strings.Builder
	err = parsed.Execute(&out, data)
	return out.String(), err
}

// -----------------------------------------------------------------------------
// FUNCTIONS
// -----------------------------------------------------------------------------

func main() {
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	var groups []Group
	if err := json.Unmarshal(raw, &groups); err != nil {
		panic(err)
	}
	cases := map[string]Data{
		"a value":  {Labels: map[string]string{}, Values: map[string]Value{"A": {Value: 1}}, Value: 1.0},
		"no value": {Labels: map[string]string{}, Values: map[string]Value{}, Value: ""},
	}
	failures := 0
	rendered := 0
	for _, group := range groups {
		for _, rule := range group.Rules {
			for key, text := range rule.Annotations {
				for name, data := range cases {
					rendered++
					if _, err := render(text, data); err != nil {
						failures++
						fmt.Printf("%s %s with %s: %v\n", rule.UID, key, name, err)
					}
				}
			}
		}
	}
	if rendered == 0 {
		fmt.Println("no annotations rendered")
		os.Exit(1)
	}
	if failures > 0 {
		os.Exit(1)
	}
	fmt.Printf("%d annotation renders expand\n", rendered)
}
