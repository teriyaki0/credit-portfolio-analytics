// Отрисовка спеков Vega-Lite и общие помощники обеих страниц.
// Цвета данных — только здесь; проверены на различимость при дальтонизме и контраст к фону:
// последний срез #3D62A8, прошлый #97AACC, NPL #D9652E, тепловая карта #E3ECFA → #13366B.

const COLORS = {
  ink: "#0F1B2D", ink2: "#475467", muted: "#8A94A6", grid: "#E6E9EF", axis: "#C9CFD9", tile: "#F3F5F8",
  current: "#3D62A8", previous: "#97AACC", risk: "#D9652E", heatLow: "#E3ECFA", heatHigh: "#13366B",
  good: "#1E7B4F", bad: "#C2410C",
};

// Русская локаль d3-format: «10,01%», «484,7».
const FORMAT_LOCALE = {decimal: ",", thousands: " ", grouping: [3], currency: ["", " ₸"]};

// Спеки ссылаются на именованные стили ("style": "kpi-value") и шкалы — цветов в самих спеках нет.
function vegaConfig() {
  const c = COLORS;
  const text = (color, size, weight) => ({color, fontSize: size, fontWeight: weight || 400});
  vega.scheme("perf-npl", [c.current, c.risk]);
  return {
    background: null, font: "system-ui, -apple-system, 'Segoe UI', sans-serif", padding: 2, view: {stroke: null},
    title: {anchor: "start", color: c.ink, fontSize: 15, fontWeight: 600, subtitleColor: c.ink2, subtitleFontSize: 13, offset: 14},
    axis: {domainColor: c.axis, tickColor: c.axis, gridColor: c.grid, labelColor: c.ink2, labelFontSize: 12,
           titleColor: c.muted, titleFontSize: 11, titleFontWeight: 400, labelLimit: 220},
    legend: {orient: "top", direction: "horizontal", labelColor: c.ink2, titleColor: c.muted, labelFontSize: 12,
             titleFontSize: 11, titleFontWeight: 400, symbolType: "circle"},
    range: {ordinal: [c.previous, c.current], heatmap: [c.heatLow, c.heatHigh]},
    bar: {color: c.current, size: 18, cornerRadiusEnd: 4},
    point: {filled: true, size: 90, stroke: "#FFFFFF", strokeWidth: 2, opacity: 1},
    style: {
      "kpi-tile": {color: c.tile, cornerRadius: 10},
      "kpi-label": text(c.ink2, 13, 500), "kpi-value": text(c.ink, 26, 600), "kpi-prev": text(c.muted, 12),
      "delta-good": text(c.good, 13, 600), "delta-bad": text(c.bad, 13, 600), "delta-neutral": text(c.ink2, 13),
      "value-label": text(c.ink2, 12), "value-label-strong": text(c.ink, 12, 600),
      "cell-label": text(c.ink, 12), "cell-label-strong": text("#FFFFFF", 12, 600),
      "dumbbell-link": {color: c.axis, strokeWidth: 2},   // у линий цвет через color: stroke в style не применяется
      "reference": {color: c.muted, strokeWidth: 1},
    },
  };
}

// Плитки KPI: три в ряд на всю ширину карточки.
function fitKpiTiles(spec, width) {
  const param = (name) => spec.params.find((p) => p.name === name);
  const gap = param("gap").value;
  const tile = Math.max(200, Math.floor((width - 2 * gap - 4) / 3));
  param("tile_w").value = tile;
  spec.width = 3 * tile + 2 * gap;
}

async function renderCharts(specs) {
  const options = {config: vegaConfig(), formatLocale: FORMAT_LOCALE, renderer: "svg",
                   actions: {export: true, source: true, compiled: false, editor: false}};
  for (const [id, url] of specs) {
    const el = document.getElementById(id);
    try {
      const spec = await (await fetch(url)).json();
      const opts = {...options, actions: id === "kpi" ? false : options.actions};
      if (id === "kpi") fitKpiTiles(spec, el.clientWidth);
      await vegaEmbed(el, spec, opts);
      // Разрезы из нескольких панелей: ширину подписей заранее не знаем, поэтому после первой
      // отрисовки делим оставшееся место между панелями (доли — в usermeta спека) и рисуем заново.
      const shares = spec.hconcat && spec.usermeta && spec.usermeta.panelShares;
      if (shares) {
        const available = el.clientWidth - parseFloat(getComputedStyle(el).paddingRight || 0);
        const diff = Math.floor(available - el.querySelector("svg").getBoundingClientRect().width);
        spec.hconcat.forEach((panel, i) => { panel.width = Math.max(120, panel.width + Math.floor(diff * shares[i])); });
        await vegaEmbed(el, spec, opts);
      }
    } catch (e) {
      el.innerHTML = `<p class="error">Не удалось отрисовать ${esc(url)}: ${esc(e.message)}</p>`;
    }
  }
}

const nf = (digits) => new Intl.NumberFormat("ru-RU", {minimumFractionDigits: digits, maximumFractionDigits: digits});
const bn = (x) => nf(1).format(x / 1e9);
const pct = (x) => nf(2).format(x * 100) + "%";
const ruDate = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7) + "." + iso.slice(0, 4);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}[c]));

async function json(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(url + ": " + r.status);
  return r.json();
}

// columns: [{title, value(row), num?, html?, width?}]
function table(rows, columns) {
  const fixed = columns.some((c) => c.width);
  const head = columns.map((c) =>
    `<th class="${c.num ? "num" : ""}"${c.width ? ` style="width: ${c.width}"` : ""}>${esc(c.title)}</th>`).join("");
  const body = rows.map((r) => "<tr>" + columns.map((c) =>
    `<td class="${c.num ? "num" : ""}">${c.html ? c.value(r) : esc(c.value(r))}</td>`).join("") + "</tr>").join("");
  return `<table class="${fixed ? "fixed" : ""}"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function lastDates(metrics) {
  const dates = metrics.map((m) => m.report_date).sort();
  return {last: dates[dates.length - 1], prev: dates[dates.length - 2] || dates[dates.length - 1]};
}
const reportTitle = (metrics) => `Риск-сводка портфеля на ${ruDate(lastDates(metrics).last)}`;
const periodText = (metrics) =>
  `Изменение к ${ruDate(lastDates(metrics).prev)} · суммы в тенге по курсу на дату среза, без списанных кредитов`;
