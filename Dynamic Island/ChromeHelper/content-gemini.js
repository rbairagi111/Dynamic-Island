(function () {
  const AI = globalThis.IslandAI;
  if (!AI) return;
  if (globalThis.__islandGeminiWatch) return;
  globalThis.__islandGeminiWatch = true;

  function editableText(target) {
    if (!target) return "";
    return String(target.value || target.innerText || target.textContent || "").trim();
  }

  function signalPromptSubmitted(target) {
    let prompt = editableText(target);
    if (!prompt) {
      const editor = document.querySelector(
        'rich-textarea [contenteditable="true"], textarea, [contenteditable="true"]'
      );
      prompt = editableText(editor);
    }
    try {
      chrome.runtime.sendMessage({ type: "geminiPromptSubmitted", prompt });
    } catch (e) {}
  }

  document.addEventListener(
    "keydown",
    (event) => {
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
      const target = event.target;
      if (
        target &&
        (target.tagName === "TEXTAREA" ||
          target.tagName === "INPUT" ||
          target.isContentEditable ||
          target.closest('[contenteditable="true"]'))
      ) {
        signalPromptSubmitted(target);
      }
    },
    true
  );
  document.addEventListener(
    "click",
    (event) => {
      const button = event.target && event.target.closest("button");
      if (!button) return;
      const label = String(button.getAttribute("aria-label") || button.textContent || "");
      if (/\b(send|submit)\b/i.test(label)) signalPromptSubmitted(null);
    },
    true
  );

  let pageNet = { pending: 0, token: "", preview: "" };
  let havePageNet = false;
  let onPageNet = null;
  window.addEventListener("message", (event) => {
    if (event.source !== window) return;
    const data = event.data;
    if (!data || data.source !== "island-gemini-net") return;
    havePageNet = true;
    pageNet = {
      pending: data.pending || 0,
      token: data.token || "",
      preview: data.preview || ""
    };
    if (typeof onPageNet === "function") onPageNet();
  });
  try {
    window.postMessage({ source: "island-gemini-net-hello" }, "*");
  } catch (e) {}

  function isInDOM(node) {
    if (!node) return false;
    try {
      if (node.closest("[hidden],template")) return false;
      const style = window.getComputedStyle ? window.getComputedStyle(node) : null;
      if (style && (style.display === "none" || style.visibility === "hidden")) return false;
    } catch (e) {}
    return true;
  }

  function collectNodes(selectors, skipProcessOnly) {
    const entries = [];
    const seen = {};
    for (let s = 0; s < selectors.length; s++) {
      const nodes = document.querySelectorAll(selectors[s]);
      for (let i = 0; i < nodes.length; i++) {
        const node = nodes[i];
        if (!isInDOM(node)) continue;
        const t = AI.cleanText(node.innerText || node.textContent || "");
        if (!t) continue;
        if (skipProcessOnly && AI.isProcessOnly(t)) continue;
        const key = t.slice(0, 240);
        if (seen[key] !== undefined) {
          entries[seen[key]] = { text: t, node: node, order: seen[key] };
          continue;
        }
        seen[key] = entries.length;
        entries.push({ text: t, node: node, order: entries.length });
      }
    }
    return entries;
  }

  function collectUserAnchors() {
    return collectNodes(
      [
        "user-query",
        ".query-text",
        ".user-query",
        '[data-test-id="user-query"]',
        '[data-role="user"]',
        ".user-query-container",
        ".query-text-line"
      ],
      false
    );
  }

  function collectAssistantsAfter(latestUser) {
    const all = collectNodes(
      [
        "model-response",
        ".model-response-text",
        ".model-response",
        '[data-test-id="model-response"]',
        '[data-message-author="model"]',
        '[data-role="model"]',
        "message-content",
        ".markdown-main-panel",
        ".markdown-content",
        ".response-container"
      ],
      true
    );
    if (!all.length) return [];
    if (!latestUser || !latestUser.node) return [all[all.length - 1]];
    const following = all.filter((entry) => {
      try {
        return !!(
          latestUser.node.compareDocumentPosition(entry.node) &
          Node.DOCUMENT_POSITION_FOLLOWING
        );
      } catch (e) {
        return entry.order >= latestUser.order;
      }
    });
    // Frozen background tabs still contain the previous model-response, which
    // is BEFORE the new user-query. Do not treat that as the current reply.
    if (!following.length) return [];
    const pool = following;
    let best = pool[0];
    for (let i = 1; i < pool.length; i++) {
      if (pool[i].text.length >= best.text.length) best = pool[i];
    }
    return [best];
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

  function installStreamCapture() {
    window.__islandGeminiIsStreamURL = isStreamURL;
    let net = window.__islandGeminiNet;
    if (net && net.v >= 24) return net;
    net = { v: 24, pending: 0, token: "", preview: "" };
    function matches(u) {
      const fn = window.__islandGeminiIsStreamURL;
      return typeof fn === "function" ? fn(u) : isStreamURL(u);
    }
    function extractStreamText(body) {
      const s = String(body || "");
      let best = "";
      const re = /"((?:\\.|[^"\\]){32,})"/g;
      let m;
      while ((m = re.exec(s))) {
        let t = m[1]
          .replace(/\\n/g, " ")
          .replace(/\\"/g, '"')
          .replace(/\\u003c/g, "<");
        t = AI.cleanText(t);
        if (
          t.length > best.length &&
          t.indexOf("http") !== 0 &&
          t.indexOf("{") !== 0 &&
          !AI.isProcessOnly(t)
        ) {
          best = t;
        }
      }
      return best.slice(0, 800);
    }
    function noteStart(u) {
      if (!matches(u)) return;
      net.pending++;
    }
    function noteEnd(u, body) {
      if (!matches(u)) return;
      net.pending = Math.max(0, net.pending - 1);
      const text = extractStreamText(body);
      if (text.length >= 8) {
        net.preview = text;
        net.token = String(Date.now()) + ":" + text.length;
      } else if (!net.token) {
        net.token = String(Date.now()) + ":end";
      }
    }
    if (!window.__islandGeminiFetchHooked) {
      window.__islandGeminiFetchHooked = true;
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
          const u =
            typeof input === "string" ? input : (input && input.url) || "";
          noteStart(u);
          return OF.apply(this, arguments)
            .then(function (res) {
              if (matches(u)) {
                try {
                  res
                    .clone()
                    .text()
                    .then(function (t) {
                      noteEnd(u, t);
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
              if (matches(u)) noteEnd(u, "");
              throw err;
            });
        };
      }
    }
    window.__islandGeminiNet = net;
    return net;
  }

  const net = installStreamCapture();

  const tickGemini = AI.watchReplyCompletion("gemini", () => {
    const userEntries = collectUserAnchors();
    const latestUser = userEntries.length
      ? userEntries[userEntries.length - 1]
      : null;
    const assistantEntries = collectAssistantsAfter(latestUser);
    let text = assistantEntries.length ? assistantEntries[0].text : "";
    let preview = AI.previewWords(text);
    const netPreview = havePageNet ? pageNet.preview : ((net && net.preview) || "");
    const netToken = havePageNet ? pageNet.token : ((net && net.token) || "");
    const netPending = havePageNet ? (pageNet.pending || 0) : ((net && net.pending) || 0);
    // A response node after the latest user prompt is authoritative. Network
    // parsing exists only for frozen background DOM and must never replace a
    // valid rendered answer with Gemini RPC metadata.
    if (!assistantEntries.length && netPreview && (netToken || netPending > 0)) {
      const fromNet = AI.previewWords(netPreview);
      const netHead = fromNet ? fromNet.slice(0, Math.min(40, fromNet.length)) : "";
      const domHasNet = !!(preview && netHead && preview.indexOf(netHead) !== -1);
      if (
        fromNet &&
        (!preview || netPending > 0 || !domHasNet || fromNet.length >= preview.length || !assistantEntries.length)
      ) {
        text = netPreview;
        preview = fromNet;
      }
    }
    const generating =
      AI.scanGenerating(document, 0) ||
      (netPending > 0 && !netToken) ||
      (!!preview && AI.isProcessOnly(preview) && !preview);
    return {
      generating,
      preview,
      textLength: text.length,
      assistantCount: Math.max(assistantEntries.length, preview ? 1 : 0),
      latestUserPrompt: latestUser ? latestUser.text : "",
      latestUserFingerprint: latestUser
        ? AI.makeFingerprint(latestUser.text)
        : "",
      replyFingerprint: text ? AI.makeFingerprint(text) : "",
      replyAnchoredToLatestUser: !!(latestUser && preview && (assistantEntries.length || netToken)),
      networkCompletionToken: netToken
    };
  });
  onPageNet = typeof tickGemini === "function" ? tickGemini : null;
})();
