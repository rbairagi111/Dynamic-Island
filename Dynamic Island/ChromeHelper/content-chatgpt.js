(function () {
  const AI = globalThis.IslandAI;
  if (!AI) return;

  function isGenerating() {
    if (document.querySelector(".result-streaming,[data-is-streaming='true']")) return true;
    if (document.querySelector('[data-testid="stop-button"],[data-testid="composer-stop-button"]')) {
      return true;
    }
    if (
      document.querySelector(
        'button[aria-label="Stop"],button[aria-label="Stop streaming"],button[aria-label="Stop response"],button[aria-label="Stop generating"]'
      )
    ) {
      return true;
    }
    // ChatGPT often exposes a square stop glyph without "Stop generating" text.
    const buttons = document.querySelectorAll('button,[role="button"]');
    for (let i = 0; i < buttons.length; i++) {
      const el = buttons[i];
      const label = (
        (el.getAttribute("aria-label") || "") +
        " " +
        (el.getAttribute("data-testid") || "") +
        " " +
        (el.innerText || "")
      ).toLowerCase();
      if (AI.isStopLabel(label)) return true;
    }
    return AI.scanGenerating(document, 0);
  }

  function collectUsers() {
    const texts = [];
    const sels = [
      '[data-message-author-role="user"]',
      '[data-turn="user"]',
      '[data-role="user"]',
      'div[data-message-author-role="user"]'
    ];
    for (let s = 0; s < sels.length; s++) {
      document.querySelectorAll(sels[s]).forEach((n) => {
        const t = AI.cleanText(n.innerText || "");
        if (t && !AI.isProcessOnly(t)) texts.push(t);
      });
      if (texts.length) return texts;
    }
    return texts;
  }

  function collectAssistants() {
    const texts = [];
    const sels = [
      '[data-message-author-role="assistant"]',
      '[data-turn="assistant"]',
      '[data-role="assistant"]',
      '[data-message-author="assistant"]',
      ".agent-turn",
      'div[data-message-author-role="assistant"]'
    ];
    for (let s = 0; s < sels.length; s++) {
      document.querySelectorAll(sels[s]).forEach((n) => {
        const t = AI.cleanText(n.innerText || "");
        if (t && !AI.isProcessOnly(t)) texts.push(t);
      });
      if (texts.length) return texts;
    }
    return texts;
  }

  AI.watchReplyCompletion("chatgpt", () => {
    const generating = isGenerating();
    const users = collectUsers();
    const assistants = collectAssistants();
    const latestUser = users.length ? users[users.length - 1] : "";
    const latestAssistant = assistants.length
      ? assistants[assistants.length - 1]
      : "";
    const preview = AI.previewWords(latestAssistant);
    return {
      generating: generating || (!!preview && AI.isProcessOnly(preview)),
      preview,
      textLength: latestAssistant.length,
      assistantCount: assistants.length,
      latestUserPrompt: latestUser,
      latestUserFingerprint: latestUser ? AI.makeFingerprint(latestUser) : "",
      replyFingerprint: latestAssistant ? AI.makeFingerprint(latestAssistant) : "",
      replyAnchoredToLatestUser: !!(latestUser && preview)
    };
  });
})();
