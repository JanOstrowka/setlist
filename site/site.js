// Site-specific glue for the hosted Setlist page. Loaded BEFORE app.js (the
// file shared verbatim with the local UI): it provides the two deployment
// seams app.js reads lazily — window.SETLIST_API_BASE (helper base URL) and
// window.SETLIST_SUBMIT_JOB (routes approved jobs through n8n when configured).
//
// This static site is generic: it ships no personal URLs or secrets. The
// helper URL defaults to localhost; the n8n webhook URL + token are entered
// once in Settings and live only in this browser's localStorage.

(function () {
  "use strict";

  const DEFAULT_HELPER_URL = "http://127.0.0.1:8765";
  const KEYS = {
    helperUrl: "setlist.helperUrl",
    n8nUrl: "setlist.n8nWebhookUrl",
    n8nToken: "setlist.n8nToken",
  };

  const settings = {
    get helperUrl() {
      return (localStorage.getItem(KEYS.helperUrl) || DEFAULT_HELPER_URL).replace(/\/+$/, "");
    },
    get n8nUrl() {
      return (localStorage.getItem(KEYS.n8nUrl) || "").trim();
    },
    get n8nToken() {
      return (localStorage.getItem(KEYS.n8nToken) || "").trim();
    },
    get n8nConfigured() {
      return !!(this.n8nUrl && this.n8nToken);
    },
  };

  window.SETLIST_API_BASE = settings.helperUrl;

  const $ = (id) => document.getElementById(id);

  // ---- helper detection ------------------------------------------------------
  // Ping GET /health (public, auth-exempt). Loopback fetches from an HTTPS page
  // are allowed in Chromium ("potentially trustworthy" origin); Safari blocks
  // them as mixed content, which we surface as a browser hint.
  let helperConnected = null; // null = unknown, true/false once pinged
  let pingTimer = null;

  function isLikelySafari() {
    const ua = navigator.userAgent;
    return /safari/i.test(ua) && !/chrome|chromium|crios|edg|opr|brave/i.test(ua);
  }

  async function pingHelper() {
    const ctrl = new AbortController();
    const timeout = setTimeout(() => ctrl.abort(), 3000);
    try {
      const res = await fetch(settings.helperUrl + "/health", {
        signal: ctrl.signal,
        cache: "no-store",
      });
      const data = await res.json();
      setHelperState(res.ok && data && data.status === "ok");
    } catch (_err) {
      setHelperState(false);
    } finally {
      clearTimeout(timeout);
    }
  }

  function setHelperState(connected) {
    const changed = connected !== helperConnected;
    helperConnected = connected;
    const pill = $("helperStatus");
    pill.classList.toggle("status-ok", connected);
    pill.classList.toggle("status-bad", !connected);
    pill.classList.remove("status-unknown");
    $("helperStatusText").textContent = connected ? "Helper connected" : "Helper not found";
    $("setupPanel").classList.toggle("hidden", connected);
    $("safariHint").classList.toggle("hidden", connected || !isLikelySafari());
    $("setupHelperUrl").textContent = settings.helperUrl;
    schedulePing();
    // Recents live on the helper; (re)load them as soon as it appears.
    if (changed && connected && typeof window.loadRecent === "function") window.loadRecent();
  }

  function schedulePing() {
    clearTimeout(pingTimer);
    pingTimer = setTimeout(pingHelper, helperConnected ? 30000 : 5000);
  }

  // ---- job submission (n8n orchestration or direct) --------------------------
  async function submitDirect({ endpoint, body }) {
    const res = await fetch(settings.helperUrl + endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({ detail: res.statusText }));
      throw new Error(err.detail || "Download request failed");
    }
    setOrchestrationNote("Running directly on the local helper (n8n not configured).");
    return res.json();
  }

  async function submitViaN8n({ endpoint, body }) {
    // The site-originated payload: the reviewed/edited job, already approved by
    // the human here in the UI — n8n validates the token, forwards to the
    // helper over the tunnel, and replies with the helper's job_id so this
    // page can attach to the local SSE stream for the live bar.
    const payload = Object.assign({}, body, { split: endpoint === "/download-split" });
    const res = await fetch(settings.n8nUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-N8N-Auth": settings.n8nToken,
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      throw new Error(
        "n8n webhook returned " + res.status +
        (detail ? " — " + detail.slice(0, 200) : "") +
        ". Check the webhook URL/token in Settings, and that the workflow is published."
      );
    }
    const data = await res.json().catch(() => ({}));
    if (!data.job_id) {
      throw new Error("n8n accepted the job but returned no job_id — is the workflow up to date and published?");
    }
    setOrchestrationNote(
      "Orchestrated via n8n (execution " + (data.execution_id || "?") + ") — audit trail in your n8n dashboard; live progress below comes from the local helper.",
      executionsUrl()
    );
    return data;
  }

  function executionsUrl() {
    try {
      return new URL(settings.n8nUrl).origin + "/home/executions";
    } catch (_err) {
      return "";
    }
  }

  function setOrchestrationNote(text, href) {
    const el = $("orchestration");
    if (!el) return;
    el.textContent = "";
    if (href) {
      const a = document.createElement("a");
      a.href = href;
      a.target = "_blank";
      a.rel = "noopener";
      a.textContent = text;
      el.appendChild(a);
    } else {
      el.textContent = text;
    }
  }

  window.SETLIST_SUBMIT_JOB = function (job) {
    return settings.n8nConfigured ? submitViaN8n(job) : submitDirect(job);
  };

  // ---- settings dialog --------------------------------------------------------
  function openSettings() {
    $("setHelperUrl").value = settings.helperUrl;
    $("setN8nUrl").value = settings.n8nUrl;
    $("setN8nToken").value = settings.n8nToken;
    $("settingsDialog").showModal();
  }

  function saveSettings() {
    const helperUrl = $("setHelperUrl").value.trim().replace(/\/+$/, "");
    localStorage.setItem(KEYS.helperUrl, helperUrl || DEFAULT_HELPER_URL);
    localStorage.setItem(KEYS.n8nUrl, $("setN8nUrl").value.trim());
    localStorage.setItem(KEYS.n8nToken, $("setN8nToken").value.trim());
    window.SETLIST_API_BASE = settings.helperUrl;
    helperConnected = null;
    pingHelper();
  }

  window.addEventListener("DOMContentLoaded", () => {
    $("helperStatus").addEventListener("click", openSettings);
    $("settingsBtn").addEventListener("click", openSettings);
    $("setupSettingsBtn").addEventListener("click", openSettings);
    $("settingsDialog").addEventListener("close", () => {
      if ($("settingsDialog").returnValue === "save") saveSettings();
    });
    pingHelper();
  });
})();
