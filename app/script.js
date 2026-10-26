// STAGE and LAMBDA_URL are injected at deploy time via config.js (see docker-entrypoint.d).
// Guestbook entries are kept client-side so the app works in every environment. When a
// LAMBDA_URL is set the page also shows the backend's greeting ("beyond Kubernetes").
const LAMBDA_URL = (window.APP_CONFIG && window.APP_CONFIG.lambdaUrl) || "";
const STAGE = (window.APP_CONFIG && window.APP_CONFIG.stage) || "an environment";
const STORE_KEY = `guestbook:${STAGE}`;

document.getElementById("stage").textContent = STAGE;

const formEl = document.getElementById("entry-form");

// The broken release page has no guestbook, only the stage label above.
if (formEl) {
  const entriesEl = document.getElementById("entries");
  const statusEl = document.getElementById("status");
  const backendEl = document.getElementById("backend");

  const readEntries = () => {
    try {
      return JSON.parse(localStorage.getItem(STORE_KEY) || "[]");
    } catch (_) {
      return [];
    }
  };

  const setStatus = (msg, isError) => {
    statusEl.textContent = msg;
    statusEl.className = isError ? "error" : "muted";
  };

  const loadEntries = () => {
    const entries = readEntries();
    if (entries.length === 0) {
      entriesEl.innerHTML = '<li class="muted">No entries yet. Be the first!</li>';
      return;
    }
    entriesEl.innerHTML = "";
    for (const e of entries.slice().reverse()) {
      const li = document.createElement("li");
      const who = document.createElement("strong");
      who.textContent = e.name || "anonymous";
      li.appendChild(who);
      li.appendChild(document.createTextNode(`: ${e.message || ""}`));
      entriesEl.appendChild(li);
    }
  };

  const saveEntry = (entry) => {
    const entries = readEntries();
    entries.push(entry);
    localStorage.setItem(STORE_KEY, JSON.stringify(entries.slice(-50)));
  };

  // Show the backend greeting if a Function URL is configured; otherwise stay hidden.
  const pingBackend = async () => {
    if (!LAMBDA_URL) return;
    backendEl.hidden = false;
    backendEl.textContent = `Backend: ${LAMBDA_URL} …`;
    try {
      const res = await fetch(LAMBDA_URL, { method: "GET" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      backendEl.textContent = `Backend says: ${data.message || "(no message)"}`;
    } catch (err) {
      backendEl.className = "error";
      backendEl.textContent = `Backend unreachable: ${err.message}`;
    }
  };

  formEl.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const name = document.getElementById("name").value.trim();
    const message = document.getElementById("message").value.trim();
    if (!name || !message) return;
    saveEntry({ name, message });
    formEl.reset();
    loadEntries();
    setStatus("Saved!", false);
    // Best-effort: also tell the backend (echo only).
    if (LAMBDA_URL) {
      try {
        await fetch(LAMBDA_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name, message }),
        });
      } catch (_) {
        /* the entry is already saved client-side; ignore backend errors */
      }
    }
  });

  loadEntries();
  pingBackend();
}
