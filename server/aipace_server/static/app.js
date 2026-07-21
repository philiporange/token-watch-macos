const refreshButton = document.querySelector("#refresh");
const otherModelsToggle = document.querySelector("#show-other-models");
const OTHER_MODELS_KEY = "showOtherModels";
let lastData = null;
const notice = document.querySelector("#notice");
const cacheStatus = document.querySelector("#cache-status");

const providers = {
  claude: document.querySelector("#claude-card"),
  codex: document.querySelector("#codex-card"),
  gemini: document.querySelector("#gemini-card"),
  zai: document.querySelector("#zai-card"),
};

function formatPercent(value) {
  return Number.isInteger(value) ? `${value}%` : `${value.toFixed(1)}%`;
}

function formatReset(value) {
  if (!value) return "Reset time unavailable";
  const date = new Date(value);
  return `Resets ${new Intl.DateTimeFormat(undefined, {
    weekday: "short",
    hour: "numeric",
    minute: "2-digit",
  }).format(date)}`;
}

function formatCached(value) {
  const date = new Date(value);
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "medium",
  }).format(date);
}

function makeWindow(label, windowData) {
  const wrapper = document.createElement("section");
  wrapper.className = "window";

  const head = document.createElement("div");
  head.className = "window-head";
  const title = document.createElement("span");
  title.className = "window-label";
  title.textContent = label;
  const value = document.createElement("span");
  value.className = "window-value";
  head.append(title, value);

  const track = document.createElement("div");
  track.className = "track";
  const fill = document.createElement("div");
  fill.className = "track-fill";
  track.append(fill);

  const meta = document.createElement("p");
  meta.className = "window-meta";

  if (windowData.used_percentage == null) {
    wrapper.classList.add("is-error");
    value.textContent = "—";
    meta.textContent = windowData.message || "Usage unavailable";
  } else {
    const percent = Math.max(0, Math.min(100, windowData.used_percentage));
    value.textContent = formatPercent(windowData.used_percentage);
    fill.style.width = `${percent}%`;
    meta.textContent = formatReset(windowData.resets_at);
  }

  wrapper.append(head, track, meta);
  return wrapper;
}

function renderProvider(key, data) {
  const card = providers[key];
  card.querySelector(".provider-detail").textContent = data.detail || "Local credentials";

  const windows = card.querySelector("[data-windows]");
  windows.replaceChildren(
    makeWindow("Five-hour window", data.five_hour),
    makeWindow(data.weekly.kind === "Month" ? "Monthly MCP usage" : "Weekly window", data.weekly),
  );

  const models = card.querySelector("[data-models]");
  models.replaceChildren();
  const modelWindows =
    key === "gemini" && !otherModelsToggle.checked ? [] : data.model_windows;
  modelWindows.forEach((model) => {
    const chip = document.createElement("span");
    chip.className = "model-chip";
    const percent = model.window.used_percentage;
    chip.textContent = `${model.model_name} · ${percent == null ? "—" : formatPercent(percent)}`;
    models.append(chip);
  });

  card.querySelector("[data-cache]").textContent = `Cached ${formatCached(data.cached_at)}`;
}

function render(data) {
  lastData = data;
  renderProvider("claude", data.claude);
  renderProvider("codex", data.codex);
  renderProvider("gemini", data.gemini);
  renderProvider("zai", data.zai);
  const cachedAt = new Date(data.claude.cached_at);
  cacheStatus.textContent = `Cached ${new Intl.RelativeTimeFormat(undefined, {
    numeric: "auto",
  }).format(Math.round((cachedAt - Date.now()) / 60000), "minute")}`;
  notice.classList.remove("is-visible");
}

async function load(method = "GET") {
  refreshButton.disabled = true;
  refreshButton.classList.toggle("is-loading", method === "POST");
  try {
    const response = await fetch(method === "POST" ? "/refresh" : "/usage", { method });
    if (!response.ok) throw new Error(`Server returned ${response.status}`);
    render(await response.json());
  } catch (error) {
    notice.textContent = `Could not load usage: ${error.message}`;
    notice.classList.add("is-visible");
  } finally {
    refreshButton.disabled = false;
    refreshButton.classList.remove("is-loading");
  }
}

refreshButton.addEventListener("click", () => load("POST"));
otherModelsToggle.checked = localStorage.getItem(OTHER_MODELS_KEY) === "true";
otherModelsToggle.addEventListener("change", () => {
  localStorage.setItem(OTHER_MODELS_KEY, otherModelsToggle.checked);
  if (lastData) render(lastData);
});
load();
