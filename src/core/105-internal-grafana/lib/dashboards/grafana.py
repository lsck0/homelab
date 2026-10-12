"""Grafana dashboard building blocks: datasources, targets, panels and the flowing grid layout.

Shared by energy.py, homelab.py and service.py, run by nix at build time (105-internal-grafana). Pure
functions returning plain dicts; nothing is global, so a generator is a list of sections passed to `dashboard`.

Overview:
    PROMETHEUS, LOKI                         datasource refs
    target(expr, legend, instant, ...)       one query; refIds are assigned by the panel, A, B, C, ...
    thresholds(*steps)                       [(value or None, color)] -> grafana's step list
    stat, gauge, bar_gauge, series, bar_chart, table, geomap, state_timeline, logs
    loki(uid), tempo(uid), pyroscope(uid)    datasource refs of one tenant
    traces, service_map, flamegraph          tempo and pyroscope panels
    section(title, *items)                   a row: a title and (panel, width, height) items
    layout(sections)                         every panel positioned, left to right, wrapping at GRID_COLUMNS
    dashboard(title, uid, sections, ...)     the board, schema GRAFANA_SCHEMA_VERSION
    dashboard_write(board, path)

Example:
    board = dashboard("Example", "example", [
        section("Now", (stat("Up", [target("count(up == 1)", instant=True)], "short"), 4, 4)),
    ])
    dashboard_write(board, sys.argv[1])

Rejected alternative: each generator carried its own copy of place/row and mutated module globals (`y`,
`x_cursor`, `row_h`) as an import side effect, so the copies drifted and no layout could be tested alone.
"""
import json

# ---- constants ----------------------------------------------------------------------------------

PROMETHEUS = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
# one datasource per tenant (an app), so their refs are built from the uid: tempo(uid), pyroscope(uid)
TEMPO_TYPE = "tempo"
PYROSCOPE_TYPE = "grafana-pyroscope-datasource"

# grafana's grid is 24 columns wide; a row header is one unit tall
GRID_COLUMNS = 24
ROW_HEIGHT = 1
# the dashboard json schema these panels are written for (grafana 12)
GRAFANA_SCHEMA_VERSION = 41
REF_IDS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

REDUCE_LAST = {"calcs": ["lastNotNull"], "fields": "", "values": False}


# ---- targets ------------------------------------------------------------------------------------

def target(expr, legend="", instant=False, datasource=PROMETHEUS, interval=None):
    """One query of a panel; the panel assigns its refId."""
    t = {"datasource": datasource, "expr": expr, "legendFormat": legend or "__auto",
         "instant": instant, "range": not instant}
    if datasource["type"] == LOKI["type"]:
        t["queryType"] = "instant" if instant else "range"
    if interval:
        t["interval"] = interval
    return t


def targets_with_refs(targets):
    assert 0 < len(targets) <= len(REF_IDS), len(targets)
    return [dict(t, refId=REF_IDS[i]) for i, t in enumerate(targets)]


def thresholds(*steps):
    """[(value, color)] with value None for the base step."""
    assert steps and steps[0][0] is None, steps
    return {"mode": "absolute", "steps": [{"color": color, "value": value} for value, color in steps]}


def color_overrides(colors):
    return [{"matcher": {"id": "byName", "options": name},
             "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": color}}]}
            for name, color in (colors or {}).items()]


def panel(kind, title, targets, datasource=PROMETHEUS, description=None, time_from=None, interval=None, **fields):
    """The fields every panel shares; `fields` are the kind's own (fieldConfig, options, transformations)."""
    p = {"type": kind, "title": title, "datasource": datasource, "targets": targets_with_refs(targets)}
    p.update(fields)
    if description:
        p["description"] = description
    if time_from:
        p["timeFrom"] = time_from
    if interval:
        p["interval"] = interval
    return p


# ---- panels -------------------------------------------------------------------------------------

def stat(title, targets, unit, decimals=None, color="blue", steps=None, graph=False, no_value="-",
         mappings=None, datasource=PROMETHEUS, text_mode="value", **kw):
    defaults = {"unit": unit, "color": {"mode": "thresholds"}, "noValue": no_value,
                "thresholds": thresholds(*(steps or [(None, color)])), "mappings": mappings or []}
    if decimals is not None:
        defaults["decimals"] = decimals
    return panel("stat", title, targets, datasource,
                 fieldConfig={"defaults": defaults, "overrides": []},
                 options={"colorMode": "background", "graphMode": "area" if graph else "none",
                          "justifyMode": "center", "textMode": text_mode, "wideLayout": True,
                          "reduceOptions": REDUCE_LAST}, **kw)


def gauge(title, targets, unit, minimum, maximum, steps, decimals=None, **kw):
    defaults = {"unit": unit, "min": minimum, "max": maximum, "color": {"mode": "thresholds"},
                "thresholds": thresholds(*steps)}
    if decimals is not None:
        defaults["decimals"] = decimals
    return panel("gauge", title, targets,
                 fieldConfig={"defaults": defaults, "overrides": []},
                 options={"showThresholdLabels": False, "showThresholdMarkers": True, "reduceOptions": REDUCE_LAST},
                 **kw)


def bar_gauge(title, targets, unit, steps, minimum=0, maximum=None, decimals=0, color_mode="thresholds", **kw):
    """Horizontal bars, one per series, named by the legend."""
    return panel("bargauge", title, targets,
                 fieldConfig={"defaults": {"unit": unit, "min": minimum, "max": maximum, "decimals": decimals,
                                           "color": {"mode": color_mode}, "thresholds": thresholds(*steps)},
                              "overrides": []},
                 options={"orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True,
                          "valueMode": "color", "namePlacement": "left", "sizing": "manual",
                          "minVizHeight": 16, "maxVizHeight": 20, "reduceOptions": REDUCE_LAST}, **kw)


def series(title, targets, unit, stack=False, fill=10, bars=False, decimals=None, colors=None, minimum=None,
           maximum=None, legend_calcs=None, legend_right=False, legend_sort=None, smooth=False, line_width=1,
           datasource=PROMETHEUS, **kw):
    """A time series; legend_calcs turns the legend into a table, legend_right moves it beside the graph."""
    custom = {"drawStyle": "bars" if bars else "line", "lineWidth": line_width,
              "fillOpacity": 80 if bars else fill, "showPoints": "never", "spanNulls": smooth,
              "lineInterpolation": "smooth" if smooth else "linear",
              "stacking": {"mode": "normal" if stack else "none", "group": "A"}}
    if smooth:
        custom["gradientMode"] = "opacity"
    defaults = {"unit": unit, "custom": custom, "color": {"mode": "palette-classic"}}
    for key, value in (("decimals", decimals), ("min", minimum), ("max", maximum)):
        if value is not None:
            defaults[key] = value
    legend = {"displayMode": "table" if legend_calcs else "list", "placement": "right" if legend_right else "bottom",
              "calcs": legend_calcs or [], "showLegend": True}
    if legend_sort:
        legend["sortBy"], legend["sortDesc"] = legend_sort, True
    return panel("timeseries", title, targets, datasource,
                 fieldConfig={"defaults": defaults, "overrides": color_overrides(colors)},
                 options={"legend": legend, "tooltip": {"mode": "multi", "sort": "desc"}}, **kw)


def bar_chart(title, targets, unit, x_label, group_label, decimals=None, colors=None, stack=True, **kw):
    """Bars over a label, not over time: series {x_label, group_label} pivoted to one bar per x, stacked by group.

    Built for gauges exported per local day or month (energy-sync's homelab_energy_*), which an epoch-aligned
    time axis cannot show.
    """
    defaults = {"unit": unit, "color": {"mode": "palette-classic"},
                "custom": {"fillOpacity": 80, "lineWidth": 0}}
    if decimals is not None:
        defaults["decimals"] = decimals
    return panel("barchart", title, targets,
                 transformations=[
                     {"id": "labelsToFields", "options": {"mode": "columns"}},
                     {"id": "merge", "options": {}},
                     {"id": "groupingToMatrix", "options": {"columnField": group_label, "rowField": x_label,
                                                            "valueField": "Value"}},
                     {"id": "sortBy", "options": {"sort": [{"field": f"{x_label}\\{group_label}"}]}}],
                 fieldConfig={"defaults": defaults, "overrides": color_overrides(colors)},
                 options={"xField": f"{x_label}\\{group_label}", "stacking": "normal" if stack else "none",
                          "orientation": "vertical", "showValue": "never", "groupWidth": 0.8, "barWidth": 0.9,
                          "legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                          "tooltip": {"mode": "multi", "sort": "none"}}, **kw)


def table(title, target_, label, label_title, value_title, datasource=PROMETHEUS, width=140, **kw):
    """One instant query as a two-column table, label and value, largest first."""
    return panel("table", title, [target_], datasource,
                 transformations=[
                     {"id": "labelsToFields", "options": {"mode": "columns"}},
                     {"id": "merge", "options": {}},
                     {"id": "organize", "options": {"excludeByName": {"Time": True},
                                                    "renameByName": {label: label_title, "Value": value_title},
                                                    "indexByName": {label: 0, "Value": 1}}},
                     {"id": "sortBy", "options": {"fields": {}, "sort": [{"field": value_title, "desc": True}]}}],
                 fieldConfig={"defaults": {"unit": "short", "custom": {"align": "auto", "cellOptions": {"type": "auto"}}},
                              "overrides": [{"matcher": {"id": "byName", "options": value_title},
                                             "properties": [{"id": "custom.cellOptions",
                                                             "value": {"type": "gauge", "mode": "gradient"}},
                                                            {"id": "custom.width", "value": width}]}]},
                 options={"showHeader": True, "cellHeight": "sm",
                          "footer": {"show": False, "reducer": ["sum"], "countRows": False, "fields": ""}}, **kw)


def geomap(title, target_, layer_name, datasource=LOKI, **kw):
    """Markers per country (a `country` label holding an iso code), sized and colored by the value."""
    return panel("geomap", title, [target_], datasource,
                 transformations=[{"id": "labelsToFields", "options": {"mode": "columns"}},
                                  {"id": "merge", "options": {}}],
                 fieldConfig={"defaults": {"unit": "short", "color": {"mode": "thresholds"},
                                           "thresholds": thresholds((None, "green"))},
                              "overrides": []},
                 options={"view": {"allLayers": True, "id": "zero", "lat": 0, "lon": 0, "zoom": 1},
                          "basemap": {"type": "carto", "name": "Basemap", "config": {"theme": "dark", "showLabels": False}},
                          "controls": {"mouseWheelZoom": True, "showZoom": True, "showAttribution": True},
                          "tooltip": {"mode": "details"},
                          "layers": [{"type": "markers", "name": layer_name, "tooltip": True,
                                      "location": {"mode": "lookup", "lookup": "country",
                                                   "gazetteer": "public/gazetteer/countries.json"},
                                      "config": {"showLegend": True, "style": {
                                          "size": {"field": "Value", "fixed": 5, "min": 2, "max": 15},
                                          "color": {"field": "Value"}, "opacity": 0.4,
                                          "symbol": {"fixed": "img/icons/marker/circle.svg", "mode": "fixed"},
                                          "text": {"field": "country", "mode": "field"}}}}]}, **kw)


def state_timeline(title, targets, value_texts, steps, **kw):
    """One lane per series; value_texts maps a value ("0", "1") to the word shown."""
    return panel("state-timeline", title, targets,
                 fieldConfig={"defaults": {"color": {"mode": "thresholds"}, "thresholds": thresholds(*steps),
                                           "mappings": [{"type": "value", "options": {
                                               value: {"text": text} for value, text in value_texts.items()}}]},
                              "overrides": []},
                 options={"showValue": "never", "rowHeight": 0.8, "mergeValues": True}, **kw)


def logs(title, expr, datasource=LOKI, **kw):
    return panel("logs", title, [target(expr, datasource=datasource)], datasource,
                 options={"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                          "enableLogDetails": True, "dedupStrategy": "exact"}, **kw)


# ---- traces and profiles ------------------------------------------------------------------------

def loki(uid):
    return {"type": LOKI["type"], "uid": uid}


def tempo(uid):
    return {"type": TEMPO_TYPE, "uid": uid}


def pyroscope(uid):
    return {"type": PYROSCOPE_TYPE, "uid": uid}


def traces(title, datasource, query, limit, **kw):
    """The traces a TraceQL query finds, newest first, each row opening the trace."""
    return panel("table", title, [{"datasource": datasource, "queryType": "traceql", "query": query, "limit": limit,
                                   "tableType": "traces"}], datasource, **kw)


def service_map(title, datasource, selector, **kw):
    """Tempo's service graph, read from the span metrics prometheus holds; selector narrows it to one tenant."""
    return panel("nodeGraph", title, [{"datasource": datasource, "queryType": "serviceMap",
                                       "serviceMapQuery": selector}], datasource, **kw)


def flamegraph(title, datasource, profile_type, selector="{}", **kw):
    return panel("flamegraph", title, [{"datasource": datasource, "queryType": "profile", "profileTypeId": profile_type,
                                        "labelSelector": selector, "groupBy": []}], datasource, **kw)


# ---- layout -------------------------------------------------------------------------------------

def section(title, *items):
    """A row header and its (panel, width, height) items, laid out in order."""
    for p, width, height in items:
        assert 0 < width <= GRID_COLUMNS and height > 0, (p.get("title"), width, height)
    return {"title": title, "items": list(items)}


def layout(sections):
    """Every panel with its gridPos: left to right, wrapping at GRID_COLUMNS, each section on a new row."""
    panels = []
    y = 0
    for s in sections:
        panels.append({"type": "row", "title": s["title"], "collapsed": False, "panels": [],
                       "gridPos": {"x": 0, "y": y, "w": GRID_COLUMNS, "h": ROW_HEIGHT}})
        y += ROW_HEIGHT
        x, line_height = 0, 0
        for p, width, height in s["items"]:
            if x + width > GRID_COLUMNS:
                y, x, line_height = y + line_height, 0, 0
            panels.append(dict(p, gridPos={"x": x, "y": y, "w": width, "h": height}))
            x += width
            line_height = max(line_height, height)
        y += line_height
    return panels


def dashboard(title, uid, sections, time_from="now-24h", time_to="now", refresh="30s", tags=(), variables=()):
    return {"title": title, "uid": uid, "tags": list(tags), "timezone": "browser", "editable": True,
            "graphTooltip": 1, "schemaVersion": GRAFANA_SCHEMA_VERSION,
            "time": {"from": time_from, "to": time_to}, "refresh": refresh,
            "templating": {"list": list(variables)}, "panels": layout(sections)}


def dashboard_write(board, path):
    with open(path, "w") as f:
        json.dump(board, f, indent=2, ensure_ascii=False)
