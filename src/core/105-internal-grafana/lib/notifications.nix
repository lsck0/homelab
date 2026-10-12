# How one alert reads wherever it lands: telegram (a grafana notification template on vm-105), ntfy (vm-203 renders
# grafana's webhook body with its own go templates) and vm-105's export of the firing alerts. tests/monitoring.nix
# renders the telegram template in grafana, tests/ntfy-alerts.nix the ntfy query on vm-203.
#
# An alert's summary annotation is a go template over its series. Grafana keeps that raw text where it has not expanded
# it: a restart restores every state with the rule's own annotations and expands them only when an evaluation returns
# the series again, so a series gone by then (a guest powered off, a label renamed) resolves with its raw summary.
# Every renderer therefore names such an alert by its rule and the labels of its series instead. A resolved alert's
# summary still says what was wrong, so its line reads as over: struck through, or prefixed.
{ lib }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # vm-105's rules label every alert with these (main.nix ruleOf)
  ruleLabels = [ "severity" "category" "notify" ];
  # what grafana adds: the rule's title, its folder, and the metric name of a bare selector
  grafanaLabels = [ "alertname" "grafana_folder" "__name__" ];
  # the labels every alert carries; the rest name its series
  sharedLabels = grafanaLabels ++ ruleLabels;
  # a summary holding a template action is the rule's text, not its expansion; a regex in go, jq and grafana alike
  rawPattern = "[{][{]";
  resolvedPrefix = "resolved: ";

  quoted = separator: names: lib.concatMapStringsSep separator (n: "\"${n}\"") names;

  # -----------------------------------------------------------------------------
  # RENDERERS
  # -----------------------------------------------------------------------------

  # grafana: alertmanager's template data; html-escaped, telegram rejects a whole message over one unescaped "<id>"
  telegramTemplateName = "homelab.telegram";
  telegramTemplate = ''
    {{ define "homelab.telegram.alert" -}}
    {{ if and .Annotations.summary (not (match "${rawPattern}" .Annotations.summary)) }}{{ .Annotations.summary | html }}
    {{- else }}{{ .Labels.alertname | html }}:
    {{- range (.Labels.Remove (stringSlice ${quoted " " sharedLabels})).SortedPairs }} {{ .Name | html }}={{ .Value | html }}{{ end }}
    {{- end }}
    {{- end }}
    {{ define "${telegramTemplateName}" }}{{ if .Alerts.Firing }}🔴 <b>{{ .CommonAnnotations.firing | html }}</b>
    {{ range .Alerts.Firing }}• {{ template "homelab.telegram.alert" . }}
    {{ end }}{{ end }}{{ if .Alerts.Resolved }}✅ <b>{{ .CommonAnnotations.resolved | html }}</b>
    {{ range .Alerts.Resolved }}• <s>{{ template "homelab.telegram.alert" . }}</s>
    {{ end }}{{ end }}{{ end }}
  '';

  # ntfy: grafana's webhook json as is, sprig functions; a group mixes firing and resolved alerts, so each line says
  ntfyTitle = lib.concatStrings [
    "{{if eq .status \"firing\"}}FIRING: {{.commonAnnotations.firing}}"
    "{{else}}RESOLVED: {{.commonAnnotations.resolved}}{{end}}"
  ];
  ntfyMessage = lib.concatStrings [
    "{{range .alerts}}{{if eq .status \"resolved\"}}${resolvedPrefix}{{end}}"
    "{{if and .annotations.summary (not (regexMatch \"${rawPattern}\" .annotations.summary))}}{{.annotations.summary}}"
    "{{else}}{{.labels.alertname}}:{{range $name, $value := omit .labels ${quoted " " sharedLabels}}} {{$name}}={{$value}}{{end}}"
    "{{end}}\n{{end}}"
  ];
  ntfyQuery = lib.concatStringsSep "&" [
    "template=yes"
    "title=${lib.escapeURL ntfyTitle}"
    "message=${lib.escapeURL ntfyMessage}"
    "tags=${lib.escapeURL "rotating_light"}"
  ];

  # jq over one alert of grafana's alertmanager api
  exportSummaryJq = ''
    (.annotations.summary // "") as $summary
    | if $summary != "" and ($summary | test("${rawPattern}") | not) then $summary
      else "\(.labels.alertname):" + (.labels | with_entries(select(.key | IN(${quoted ", " sharedLabels}) | not))
        | to_entries | sort_by(.key) | map(" \(.key)=\(.value)") | add // "")
      end'';
in {
  inherit ruleLabels resolvedPrefix telegramTemplateName telegramTemplate ntfyQuery exportSummaryJq;
}
