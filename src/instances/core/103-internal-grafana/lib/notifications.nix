# how one alert reads wherever it lands: telegram, ntfy (vm-201's go templates) and vm-103's export of firing alerts
#
# contract: grafana keeps a summary it has not expanded raw (a restart expands it only when the series returns), so
# every renderer names such an alert by its rule and series labels instead. A resolved line reads as over; a firing
# one carries its description, the runbook, and a way to the rule in grafana.
{ lib, grafanaUrl }:
let
  # vm-103's rules label every alert with these (main.nix ruleOf)
  ruleLabels = [
    "severity"
    "category"
    "notify"
  ];
  # what grafana adds: the rule's title, its folder, and the metric name of a bare selector
  grafanaLabels = [
    "alertname"
    "grafana_folder"
    "__name__"
  ];
  # the rest name its series
  sharedLabels = grafanaLabels ++ ruleLabels;
  # an annotation holding a template action is the rule's text, not its expansion; a regex in go, jq and grafana alike
  rawPattern = "[{][{]";
  resolvedPrefix = "resolved: ";
  alertListUrl = "${grafanaUrl}/alerting/list";

  quoted = separator: names: lib.concatMapStringsSep separator (n: "\"${n}\"") names;

  # grafana: alertmanager's template data; html-escaped, telegram rejects a whole message over one unescaped "<id>"
  telegramTemplateName = "homelab.telegram";
  telegramTemplate = ''
    {{ define "homelab.telegram.alert" -}}
    {{ if and .Annotations.summary (not (match "${rawPattern}" .Annotations.summary)) }}{{ .Annotations.summary | html }}
    {{- else }}{{ .Labels.alertname | html }}:
    {{- range (.Labels.Remove (stringSlice ${quoted " " sharedLabels})).SortedPairs }} {{ .Name | html }}={{ .Value | html }}{{ end }}
    {{- end }}
    {{- end }}
    {{ define "homelab.telegram.runbook" -}}
    {{ if and .Annotations.description (not (match "${rawPattern}" .Annotations.description)) }}
    <i>{{ .Annotations.description | html }}</i>{{ end }} <a href="{{ .GeneratorURL | html }}">rule</a>
    {{- end }}
    {{ define "${telegramTemplateName}" }}{{ if .Alerts.Firing }}🔴 <b>{{ .CommonAnnotations.firing | html }}</b>
    {{ range .Alerts.Firing }}• {{ template "homelab.telegram.alert" . }}{{ template "homelab.telegram.runbook" . }}
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
    "{{end}}"
    "{{if and (eq .status \"firing\") .annotations.description (not (regexMatch \"${rawPattern}\" .annotations.description))}}"
    "\n{{.annotations.description}}{{end}}"
    "\n{{end}}"
  ];
  # the notification opens grafana's alert list, which links each alert's rule and board
  ntfyQuery = lib.concatStringsSep "&" [
    "template=yes"
    "title=${lib.escapeURL ntfyTitle}"
    "message=${lib.escapeURL ntfyMessage}"
    "tags=${lib.escapeURL "rotating_light"}"
    "click=${lib.escapeURL alertListUrl}"
  ];

  # jq over one alert of grafana's alertmanager api
  exportSummaryJq = ''
    (.annotations.summary // "") as $summary
    | if $summary != "" and ($summary | test("${rawPattern}") | not) then $summary
      else "\(.labels.alertname):" + (.labels | with_entries(select(.key | IN(${quoted ", " sharedLabels}) | not))
        | to_entries | sort_by(.key) | map(" \(.key)=\(.value)") | add // "")
      end'';
in
{
  inherit
    ruleLabels
    resolvedPrefix
    alertListUrl
    telegramTemplateName
    telegramTemplate
    ntfyQuery
    exportSummaryJq
    ;
}
