/* Shared helpers for Dynamic Island AI content scripts. */
(function (global) {
  const STAGES = [
    "crystallizing", "reckoning", "thinking", "thoughts", "researching",
    "searching", "analyzing", "writing", "crafting", "planning", "working",
    "generating", "reasoning", "reading", "browsing", "synthesizing",
    "reflecting", "compiling", "drafting", "connecting", "considering"
  ];

  function isStopLabel(s) {
    s = (s || "").toLowerCase();
    if (!s) return false;
    if (
      s.indexOf("dictation") !== -1 ||
      s.indexOf("recording") !== -1 ||
      s.indexOf("listening") !== -1 ||
      s.indexOf("playback") !== -1 ||
      s.indexOf("scroll") !== -1
    ) {
      return false;
    }
    // Prefer explicit stop-response labels; bare "Stop" alone is too noisy on Claude.
    if (/stop (generating|response|output|streaming)/.test(s)) return true;
    if (/(^|[^a-z])stop([^a-z]|$)/.test(s) && s.length < 24) return true;
    return false;
  }

  function scanGenerating(root, depth) {
    if (!root || depth > 5) return false;
    try {
      if (!root.querySelector) return false;
      if (
        root.querySelector(
          '[data-testid="stop-button"],[data-testid="composer-stop-button"],[data-testid="stop-button"],.result-streaming,[data-is-streaming="true"],button[aria-label="Stop streaming"],button[aria-label="Stop response"],button[aria-label="Stop generating"]'
        )
      ) {
        return true;
      }
      const list = root.querySelectorAll('button,[role="button"]');
      for (let i = 0; i < list.length; i++) {
        const label =
          (list[i].getAttribute("aria-label") || "") +
          " " +
          (list[i].getAttribute("data-testid") || "") +
          " " +
          (list[i].innerText || "");
        if (isStopLabel(label)) return true;
      }
      const hosts = root.querySelectorAll(
        "rich-textarea,gem-icon-button,mat-icon-button,speech-dictation-mic-button"
      );
      for (let j = 0; j < hosts.length; j++) {
        if (hosts[j].shadowRoot && scanGenerating(hosts[j].shadowRoot, depth + 1)) {
          return true;
        }
      }
    } catch (e) {}
    return false;
  }

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
      .replace(/Claude responded:\s*/gi, "")
      .replace(/ChatGPT said:\s*/gi, "")
      .replace(/ChatGPT responded:\s*/gi, "")
      .replace(/Gemini said:\s*/gi, "")
      .replace(/You said:\s*/gi, "")
      .replace(/\bjust now\b/gi, " ")
      .replace(/\b\d+\s*(second|minute|hour|day|week|month|year)s?\s+ago\b/gi, " ")
      .replace(/\byesterday\b/gi, " ")
      .replace(/[\uE000-\uF8FF]/g, " ")
      .replace(/\s+/g, " ")
      .trim();
  }

  function makeFingerprint(t) {
    const s = cleanText(t);
    if (!s) return "";
    return s.length + "#" + s.slice(0, 200);
  }

  function previewWords(text) {
    const cleaned = cleanText(text);
    if (!cleaned || isProcessOnly(cleaned)) return "";
    return cleaned.split(/\s+/).filter(Boolean).slice(0, 40).join(" ");
  }

  function emitReplyReady(provider, payload) {
    const preview = (payload.preview || "").trim();
    if (preview.length < 8 || isProcessOnly(preview)) return;
    try {
      chrome.runtime.sendMessage({
        type: "replyReady",
        provider: provider,
        preview: preview,
        textLength: payload.textLength || preview.length,
        assistantCount: payload.assistantCount || 1,
        latestUserPrompt: payload.latestUserPrompt || "",
        latestUserFingerprint: payload.latestUserFingerprint || "",
        replyFingerprint: payload.replyFingerprint || makeFingerprint(preview),
        replyAnchoredToLatestUser: !!payload.replyAnchoredToLatestUser,
        pageVisible: document.visibilityState === "visible" && document.hidden === false
      });
    } catch (e) {}
  }

  /**
   * Watch generating → idle and fire once per finished reply.
   * Uses Stop UI when available, and reply-text growth as a fallback
   * (Claude/ChatGPT often hide Stop from simple selectors).
   */
  function watchReplyCompletion(provider, getState) {
    let wasGenerating = false;
    let lastEmittedFingerprint = "";
    let lastPreviewWhileGenerating = "";
    let lastLen = 0;
    let lastFp = "";
    let sawGrowth = false;
    let stableTicks = 0;
    let bootstrapped = false;

    function tick() {
      let state;
      try {
        state = getState() || {};
      } catch (e) {
        return;
      }
      const uiGenerating = !!state.generating;
      const preview = (state.preview || "").trim();
      const len = state.textLength || preview.length || 0;
      const fp = state.replyFingerprint || (preview ? makeFingerprint(preview) : "");

      if (!bootstrapped) {
        bootstrapped = true;
        lastLen = len;
        lastFp = fp;
        // Do not treat the already-loaded transcript as an in-flight reply.
        return;
      }

      const grew =
        (len > lastLen + 12) ||
        (!!fp && !!lastFp && fp !== lastFp && len >= lastLen && preview.length >= 8);

      if (grew && preview.length >= 8 && !isProcessOnly(preview)) {
        sawGrowth = true;
        stableTicks = 0;
        lastPreviewWhileGenerating = preview;
      } else if (sawGrowth && !uiGenerating) {
        stableTicks += 1;
      }

      // Still "generating" while Stop is up, or reply text is still settling.
      const generating = uiGenerating || (sawGrowth && stableTicks < 3);

      if (generating) {
        wasGenerating = true;
        if (preview.length >= 8 && !isProcessOnly(preview)) {
          lastPreviewWhileGenerating = preview;
        }
        lastLen = Math.max(lastLen, len);
        if (fp) lastFp = fp;
        return;
      }

      if (!wasGenerating && !sawGrowth) {
        lastLen = len;
        if (fp) lastFp = fp;
        return;
      }

      wasGenerating = false;
      sawGrowth = false;
      stableTicks = 0;

      let finalPreview = preview;
      if (finalPreview.length < 8 || isProcessOnly(finalPreview)) {
        finalPreview = lastPreviewWhileGenerating;
      }
      lastPreviewWhileGenerating = "";
      lastLen = Math.max(lastLen, len);
      if (fp) lastFp = fp;

      if (!finalPreview || finalPreview.length < 8 || isProcessOnly(finalPreview)) return;

      const emitFp = state.replyFingerprint || makeFingerprint(finalPreview);
      if (!emitFp || emitFp === lastEmittedFingerprint) return;
      lastEmittedFingerprint = emitFp;

      emitReplyReady(provider, {
        preview: finalPreview,
        textLength: state.textLength || finalPreview.length,
        assistantCount: state.assistantCount || 1,
        latestUserPrompt: state.latestUserPrompt || "",
        latestUserFingerprint: state.latestUserFingerprint || "",
        replyFingerprint: emitFp,
        replyAnchoredToLatestUser: !!state.replyAnchoredToLatestUser
      });
    }

    tick();
    setInterval(tick, 180);
    try {
      const obs = new MutationObserver(() => tick());
      obs.observe(document.documentElement || document.body, {
        childList: true,
        subtree: true,
        characterData: true,
        attributes: true
      });
    } catch (e) {}
    return tick;
  }

  global.IslandAI = {
    isStopLabel,
    scanGenerating,
    isProcessOnly,
    cleanText,
    makeFingerprint,
    previewWords,
    emitReplyReady,
    watchReplyCompletion
  };
})(typeof globalThis !== "undefined" ? globalThis : window);
