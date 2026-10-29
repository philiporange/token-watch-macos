"use strict";

const providerNames = {claude: "Claude", codex: "Codex", gemini: "Gemini", zai: "Z.ai", muse: "Muse", alicloud: "AliCloud", commandcode: "Command Code"};
const rangeOptions = {"24h": "24h", "7d": "7d", "30d": "30d", "90d": "90d", "365d": "1y", all: "All"};
let selectedRange = "7d";
let selectedProvider = "";
let requestNumber = 0;
const content = document.querySelector("#history-content");
const status = document.querySelector("#history-status");
const errorBox = document.querySelector("#history-error");
const reload = document.querySelector("#reload");
const percent = value => `${Number(value).toFixed(1).replace(/\.0$/, "")}%`;
const rate = value => `${Number(value).toFixed(2).replace(/\.?0+$/, "")}%/h`;
const date = value => new Date(value).toLocaleString(undefined, {weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit"});
const shortDate = value => new Date(value).toLocaleString(undefined, {month: "short", day: "numeric", hour: "2-digit", minute: "2-digit"});

function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

function svgElement(tag, attributes, text) {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
  Object.entries(attributes).forEach(([key, value]) => node.setAttribute(key, value));
  if (text !== undefined) node.textContent = text;
  return node;
}

function controls() {
  const ranges = document.querySelector("#ranges");
  const providers = document.querySelector("#providers");
  ranges.replaceChildren();
  providers.replaceChildren();
  function chip(parent, key, label, active, select) {
    const button = element("button", label);
    button.type = "button";
    button.setAttribute("aria-pressed", String(active));
    button.addEventListener("click", () => { select(key); controls(); load(); });
    parent.append(button);
  }
  Object.entries(rangeOptions).forEach(([key, label]) => chip(ranges, key, label, selectedRange === key, key => { selectedRange = key; }));
  Object.entries({"": "All providers", ...providerNames}).forEach(([key, label]) => chip(providers, key, label, selectedProvider === key, key => { selectedProvider = key; }));
}

function chart(series, data) {
  const card = element("article", undefined, "history-chart");
  card.append(element("h3", `${series.label} · ${percent(series.current.used)}`));
  const plot = [...series.points];
  if (!plot.length || new Date(series.current.t) > new Date(plot[plot.length - 1].t)) plot.push(series.current);
  const now = new Date(data.generated_at).getTime();
  const start = data.since ? new Date(data.since).getTime() : new Date(plot[0].t).getTime();
  // A single all-time reading still needs a visible time domain.
  const span = now > start ? now - start : 3600000;
  const end = now + span * 0.25;
  const compact = window.innerWidth <= 500;
  const width = compact ? 400 : 800;
  const left = 46, right = width - 22, top = 28, bottom = 232;
  const x = t => left + (new Date(t).getTime() - start) / (end - start) * (right - left);
  const clippedProjections = series.projections.map(projection => {
    const fromTime = new Date(projection.from.t).getTime();
    const toTime = new Date(projection.to.t).getTime();
    const clippedTime = Math.min(toTime, end);
    const fraction = toTime > fromTime ? (clippedTime - fromTime) / (toTime - fromTime) : 0;
    return {...projection, clipped: {t: clippedTime, used: projection.from.used + fraction * (projection.to.used - projection.from.used)}};
  });
  const maximum = clippedProjections.reduce((max, p) => Math.max(max, p.clipped.used),
    plot.reduce((max, p) => Math.max(max, p.used), 100));
  const y = value => bottom - value / maximum * (bottom - top);
  const svg = svgElement("svg", {viewBox: `0 0 ${width} 274`, role: "img", "aria-label": `${series.provider_name} ${series.label} quota usage over time`});
  [0, 50, 100, ...(maximum > 100 ? [maximum] : [])].forEach(value => {
    svg.append(svgElement("line", {x1: left, x2: right, y1: y(value), y2: y(value), class: value === 100 ? "limit" : "grid"}));
    svg.append(svgElement("text", {x: left - 7, y: y(value) + 4, "text-anchor": "end"}, `${Math.round(value)}%`));
  });
  const ticks = compact ? [start, end] : [start, start + (end - start) / 2, end];
  ticks.forEach((t, i) => {
    svg.append(svgElement("text", {x: x(t), y: 259, "text-anchor": i === 0 ? "start" : i === ticks.length - 1 ? "end" : "middle"}, shortDate(t)));
  });
  const reset = series.current.resets_at && new Date(series.current.resets_at).getTime();
  if (reset && reset >= start && reset <= end) {
    svg.append(svgElement("line", {x1: x(reset), x2: x(reset), y1: top, y2: bottom, class: "reset"}));
    svg.append(svgElement("text", {x: x(reset), y: 17, "text-anchor": "middle"}, "Reset"));
  }
  svg.append(svgElement("polyline", {points: plot.map(p => `${x(p.t)},${y(p.used)}`).join(" "), class: "usage"}));
  clippedProjections.forEach(p => {
    svg.append(svgElement("line", {x1: x(p.from.t), x2: x(p.clipped.t), y1: y(p.from.used), y2: y(p.clipped.used), class: p.method}));
  });
  const tooltip = element("p", "Hover, focus or tap a point for its time and usage.", "chart-tooltip");
  tooltip.setAttribute("aria-live", "polite");
  // Dense series get one tracking marker instead of a marker per sample.
  if ((right - left) / Math.max(plot.length, 1) < 8) {
    const marker = svgElement("circle", {r: 4, class: "point", visibility: "hidden"});
    const area = svgElement("rect", {x: left, y: top, width: right - left, height: bottom - top, fill: "transparent"});
    const track = event => {
      const box = svg.getBoundingClientRect();
      const time = start + ((event.clientX - box.left) / box.width * width - left) / (right - left) * (end - start);
      const nearest = plot.reduce((best, p) =>
        Math.abs(new Date(p.t) - time) < Math.abs(new Date(best.t) - time) ? p : best);
      marker.setAttribute("cx", x(nearest.t));
      marker.setAttribute("cy", y(nearest.used));
      marker.setAttribute("visibility", "visible");
      tooltip.textContent = `${date(nearest.t)} · ${percent(nearest.used)}`;
    };
    ["pointermove", "click"].forEach(event => area.addEventListener(event, track));
    svg.append(area, marker);
  } else plot.forEach(p => {
    const description = `${date(p.t)} · ${percent(p.used)}`;
    const point = svgElement("circle", {cx: x(p.t), cy: y(p.used), r: 4, class: "point", tabindex: 0, role: "button", "aria-label": description});
    point.append(svgElement("title", {}, description));
    ["pointerenter", "click", "focus"].forEach(event => point.addEventListener(event, () => { tooltip.textContent = description; }));
    // A larger transparent target makes markers practical on touch screens.
    const target = svgElement("circle", {cx: x(p.t), cy: y(p.used), r: 12, fill: "transparent", "aria-hidden": "true"});
    ["pointerenter", "click"].forEach(event => target.addEventListener(event, () => { tooltip.textContent = description; }));
    svg.append(point, target);
  });
  const legend = element("div", undefined, "chart-legend");
  legend.append(element("span", "Usage", "usage"));
  series.projections.forEach(p => legend.append(element("span", p.method === "average" ? "Average pace" : "Trend", p.method)));
  card.append(svg, legend, tooltip);
  if (!series.projections.length) {
    card.append(element("p", series.current.resets_at ? "Not enough history yet" : "No reset time", "projection-summary"));
  }
  series.projections.forEach(p => {
    const lookback = series.kind === "5h" ? "1 h" : series.kind === "Month" ? "3 d" : "24 h";
    const label = p.method === "average" ? "Average pace" : `${lookback} trend`;
    const outcome = p.limit_at ? `reaches 100% ${date(p.limit_at)}` : `${percent(p.at_reset)} at reset ${date(series.current.resets_at)}`;
    card.append(element("p", `${label} ${rate(p.rate_per_hour)} · ${outcome}`, "projection-summary"));
  });
  return card;
}

function summaryTable(series) {
  const wrapper = element("div", undefined, "history-table-wrap");
  wrapper.tabIndex = 0;
  wrapper.setAttribute("aria-label", "Provider summary; scroll horizontally for all columns");
  const table = element("table", undefined, "history-table");
  table.append(element("caption", "Pace summary"));
  const header = element("tr");
  ["Series", "Current %", "Average %/h", "Trend %/h", "At reset", "Reaches 100 %"].forEach(label => {
    const th = element("th", label); th.scope = "col"; header.append(th);
  });
  const head = element("thead"); head.append(header); table.append(head);
  const body = element("tbody");
  series.forEach(s => {
    const average = s.projections.find(p => p.method === "average");
    const trend = s.projections.find(p => p.method === "trend");
    const reset = s.projections.map(p => `${p.method === "average" ? "Avg" : "Trend"}: ${percent(p.at_reset)}`).join(" · ") || "—";
    const limit = s.projections.map(p => `${p.method === "average" ? "Avg" : "Trend"}: ${p.limit_at ? date(p.limit_at) : "—"}`).join(" · ") || "—";
    const row = element("tr");
    [s.label, percent(s.current.used), average ? rate(average.rate_per_hour) : "—", trend ? rate(trend.rate_per_hour) : "—", reset, limit].forEach(value => row.append(element("td", value)));
    body.append(row);
  });
  table.append(body); wrapper.append(table); return wrapper;
}

function render(data) {
  content.replaceChildren();
  if (!data.series.length) {
    content.append(element("p", "No history in this range. Fresh successful readings appear as providers are refreshed.", "history-status"));
  }
  Object.entries(providerNames).forEach(([key, name]) => {
    const series = data.series.filter(s => s.provider === key);
    if (!series.length) return;
    const section = element("section", undefined, "history-provider");
    section.append(element("h2", name));
    series.forEach(s => section.append(chart(s, data)));
    section.append(summaryTable(series));
    content.append(section);
  });
  status.textContent = `Updated ${date(data.generated_at)} · Stored hourly or when usage changes by at least 1 percentage point.`;
}

async function load() {
  const request = ++requestNumber;
  reload.disabled = true;
  status.textContent = "Loading history…";
  try {
    const params = new URLSearchParams({range: selectedRange});
    if (selectedProvider) params.set("provider", selectedProvider);
    const response = await fetch(`/history?${params}`);
    if (!response.ok) throw new Error(`Server returned ${response.status}`);
    const data = await response.json();
    if (request !== requestNumber) return;
    render(data);
    errorBox.classList.remove("is-visible");
  } catch (error) {
    if (request !== requestNumber) return;
    errorBox.textContent = `Could not load history: ${error.message}. Use Reload to try again.`;
    errorBox.classList.add("is-visible");
    status.textContent = content.childElementCount ? "Showing the last loaded history." : "History unavailable.";
  } finally {
    if (request === requestNumber) reload.disabled = false;
  }
}

reload.addEventListener("click", load);
controls();
load();
setInterval(load, 5 * 60 * 1000);
