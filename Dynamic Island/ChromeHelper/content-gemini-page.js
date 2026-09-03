/* Runs in the Gemini PAGE world at document_start so fetch/XHR wrapping
   happens before Gemini binds its own fetch. Isolated content scripts cannot
   see those requests, which is why background-tab replies never bannered
   until the tab was opened. */
(function () {
  if (window.__islandGeminiFetchHooked) return;
  window.__islandGeminiFetchHooked = true;

  const STAGES = [
    "thinking", "thoughts", "researching", "searching", "analyzing",
    "writing", "crafting", "planning", "working", "generating",
    "reasoning", "reading", "browsing", "synthesizing", "reflecting",
    "compiling", "drafting", "connecting", "considering"
  ];

  try {
    Object.defineProperty(document, "hidden", {
      get: function () { return false; },
      configurable: true
    });
    Object.defineProperty(document, "visibilityState", {
      get: function () { return "visible"; },
      configurable: true
    });
    try {
      Object.defineProperty(document, "webkitHidden", {
        get: function () { return false; },
        configurable: true
      });
    } catch (e0) {}
    window.__islandGeminiVisibilityVersion = 2;
    document.addEventListener(
      "visibilitychange",
      function (e) {
        try {
          e.stopImmediatePropagation();
        } catch (e1) {}
      },
      true
    );
  } catch (e2) {}

  function isProcessOnly(t) {
    const s = (t || "").toLowerCase().replace(/\s+/g, " ").trim();
    if (!s) return true;
    const tokens = s.split(/[^a-z]+/).filter(Boolean);
    if (!tokens.length) return true;
    if (tokens.every((w) => STAGES.indexOf(w) !== -1)) return true;
    if (tokens.length <= 4 && STAGES.indexOf(tokens[0]) !== -1) return true;
    return false;
  }

  function cleanText(t) {
    return (t || "")
      .replace(/Show message actions for /gi, "")
      .replace(/Gemini said:?\s*/gi, "")
      .replace(/You said:?\s*/gi, "")
      .replace(/\bjust now\b/gi, " ")
      .replace(/\b\d+\s*(second|minute|hour|day|week|month|year)s?\s+ago\b/gi, " ")
      .replace(/\byesterday\b/gi, " ")
      .replace(/[\uE000-\uF8FF]/g, " ")
      .replace(/\s+/g, " ")
      .trim();
  }

  function isStreamURL(u) {
    u = String(u || "").toLowerCase();
    return (
      u.indexOf("streamgenerate") !== -1 ||
      u.indexOf("bardfrontendservice") !== -1 ||
      u.indexOf("assistant.lamda") !== -1 ||
      u.indexOf("batchexecute") !== -1 ||
      u.indexOf("bardchatui") !== -1 ||
      u.indexOf("/_/bard") !== -1 ||
      u.indexOf("generatefreeformstreamed") !== -1 ||
      u.indexOf("generatecontent") !== -1
    );
  }

  window.__islandGeminiIsStreamURL = isStreamURL;

  const net = { v: 24, pending: 0, token: "", preview: "" };
  window.__islandGeminiNet = net;
  window.__islandGeminiCaptureVersion = 24;

  function considerProse(raw, best) {
    let t = String(raw || "")
      .replace(/\\n/g, " ")
      .replace(/\\"/g, '"')
      .replace(/\\u003c/g, "<");
    t = cleanText(t);
    if (t.length <= best.length) return best;
    if (t.indexOf("http") === 0) return best;
    if (/^(null|undefined)$/i.test(t)) return best;
    if (/type\.googleapis\.com|wrb\.fr|boq_assistant|rpcids=/i.test(t)) return best;
    if (/^[A-Za-z0-9+/_=-]{48,}$/.test(t)) return best;
    if (t.charAt(0) === "{" || t.charAt(0) === "[") return best;
    if (isProcessOnly(t)) return best;
    const words = t.split(/\s+/).filter(Boolean);
    if (words.length < 2 && t.length < 48) return best;
    return t;
  }

  function walkStrings(value, best, depth) {
    if (depth > 8 || value == null) return best;
    if (typeof value === "string") {
      if (value.length > 12 && (value.charAt(0) === "[" || value.charAt(0) === "{")) {
        try {
          return walkStrings(JSON.parse(value), best, depth + 1);
        } catch (e) {}
      }
      best = considerProse(value, best);
      return best;
    }
    if (typeof value !== "object") return best;
    if (Array.isArray(value)) {
      for (let i = 0; i < value.length; i++) {
        best = walkStrings(value[i], best, depth + 1);
      }
      return best;
    }
    for (const key in value) {
      if (Object.prototype.hasOwnProperty.call(value, key)) {
        best = walkStrings(value[key], best, depth + 1);
      }
    }
    return best;
  }

  function extractStreamText(body) {
    const s = String(body || "");
    let best = "";
    try {
      let rest = s.replace(/^\)\]\}'\s*/, "");
      let i = 0;
      while (i < rest.length) {
        while (
          i < rest.length &&
          (rest.charAt(i) === "\n" || rest.charAt(i) === "\r" || rest.charAt(i) === " ")
        ) {
          i++;
        }
        let n = "";
        while (i < rest.length && rest.charAt(i) >= "0" && rest.charAt(i) <= "9") {
          n += rest.charAt(i);
          i++;
        }
        if (!n) break;
        if (rest.charAt(i) === "\n" || rest.charAt(i) === "\r") i++;
        const len = parseInt(n, 10);
        if (!(len > 0) || i + len > rest.length + 32) break;
        const frame = rest.substr(i, len);
        i += len;
        try {
          best = walkStrings(JSON.parse(frame), best, 0);
        } catch (e0) {
          best = considerProse(frame, best);
        }
      }
    } catch (e1) {}
    if (!best) {
      const quoted = /"text"\s*:\s*"((?:\\.|[^"\\]){8,})"/g;
      let m;
      while ((m = quoted.exec(s))) best = considerProse(m[1], best);
    }
    return best.slice(0, 800);
  }

  function publish() {
    try {
      window.postMessage(
        {
          source: "island-gemini-net",
          pending: net.pending,
          token: net.token,
          preview: net.preview
        },
        "*"
      );
    } catch (e) {}
  }

  window.addEventListener("message", function (event) {
    if (event.source !== window) return;
    const data = event.data;
    if (!data || data.source !== "island-gemini-net-hello") return;
    publish();
  });

  function noteStart(u) {
    if (!isStreamURL(u)) return;
    net.pending++;
    publish();
  }

  function noteEnd(u, body) {
    const matched = isStreamURL(u);
    if (matched) net.pending = Math.max(0, net.pending - 1);
    const text = extractStreamText(body);
    if (text.length >= 8) {
      net.preview = text;
      net.token = String(Date.now()) + ":" + text.length;
      publish();
    } else if (matched) {
      if (!net.token) net.token = String(Date.now()) + ":end";
      publish();
    }
  }

  const XO = XMLHttpRequest.prototype.open;
  const XS = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    try {
      this.__islandU = url;
    } catch (e) {}
    return XO.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    const u = this.__islandU || "";
    noteStart(u);
    try {
      this.addEventListener("progress", function () {
        try {
          const t = extractStreamText(this.responseText);
          if (t.length >= 8) {
            net.preview = t;
            publish();
          }
        } catch (e0) {}
      });
      this.addEventListener("loadend", function () {
        try {
          noteEnd(u, this.responseText);
        } catch (e1) {
          noteEnd(u, "");
        }
      });
    } catch (e2) {}
    return XS.apply(this, arguments);
  };

  const OF = window.fetch;
  if (typeof OF === "function") {
    window.fetch = function (input, init) {
      const u = typeof input === "string" ? input : (input && input.url) || "";
      noteStart(u);
      return OF.apply(this, arguments)
        .then(function (res) {
          if (isStreamURL(u) || (res && res.url && isStreamURL(res.url))) {
            try {
              res
                .clone()
                .text()
                .then(function (t) {
                  noteEnd(u || (res && res.url) || "", t);
                })
                .catch(function () {
                  noteEnd(u, "");
                });
            } catch (e) {
              noteEnd(u, "");
            }
          }
          return res;
        })
        .catch(function (err) {
          if (isStreamURL(u)) noteEnd(u, "");
          throw err;
        });
    };
  }

  try {
    const NativeWS = window.WebSocket;
    if (typeof NativeWS === "function") {
      window.WebSocket = function (url, protocols) {
        const ws = protocols !== undefined ? new NativeWS(url, protocols) : new NativeWS(url);
        try {
          if (isStreamURL(url)) noteStart(url);
          ws.addEventListener("message", function (ev) {
            try {
              const t = extractStreamText(typeof ev.data === "string" ? ev.data : "");
              if (t.length >= 8) {
                net.preview = t;
                publish();
              }
            } catch (e0) {}
          });
          ws.addEventListener("close", function () {
            noteEnd(url, net.preview || "");
          });
        } catch (e1) {}
        return ws;
      };
      window.WebSocket.prototype = NativeWS.prototype;
      window.WebSocket.CONNECTING = NativeWS.CONNECTING;
      window.WebSocket.OPEN = NativeWS.OPEN;
      window.WebSocket.CLOSING = NativeWS.CLOSING;
      window.WebSocket.CLOSED = NativeWS.CLOSED;
    }
  } catch (e3) {}
})();
