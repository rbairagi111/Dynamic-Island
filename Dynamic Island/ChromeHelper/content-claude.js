(function () {
  const AI = globalThis.IslandAI;
  if (!AI) return;
  if (globalThis.__islandClaudeWatch) return;
  globalThis.__islandClaudeWatch = true;

  const USER_SELS = [
    '[data-testid="user-message"]',
    '[data-testid="human-message"]',
    '[data-testid="message-human"]',
    ".font-user-message",
    ".user-message"
  ];

  const ASSISTANT_SELS = [
    ".font-claude-response",
    ".font-claude-message",
    '[data-testid="ai-message"]',
    '[data-testid="message-assistant"]',
    '[data-testid="assistant-message"]',
    '[data-testid="assistant-turn"]',
    ".assistant-message",
    '[data-testid="message"]'
  ];

  function isActivelyStreaming() {
    const nodes = document.querySelectorAll("[data-is-streaming]");
    for (let i = 0; i < nodes.length; i++) {
      const v = (nodes[i].getAttribute("data-is-streaming") || "").toLowerCase();
      if (v === "true") return true;
    }
    return false;
  }

  function isGenerating() {
    if (isActivelyStreaming()) return true;
    if (document.querySelector('[data-testid="stop-button"]')) return true;
    if (document.querySelector('button[aria-label*="Stop generating" i]')) return true;
    if (document.querySelector('button[aria-label*="Stop response" i]')) return true;
    const send = document.querySelector(
      '[data-testid="chat-input-send"],[data-testid="send-button"],button[aria-label*="Send" i]'
    );
    if (send) {
      const aria = (send.getAttribute("aria-label") || "").toLowerCase();
      if (aria.indexOf("stop") !== -1) return true;
    }
    if (document.querySelector('[data-is-streaming="true"],.streaming,.is-streaming')) {
      return true;
    }
    if (AI.scanGenerating(document, 0)) return true;
    return false;
  }

  function pushUnique(list, text) {
    const t = AI.cleanText(text || "");
    if (!t || AI.isProcessOnly(t)) return;
    if (list.length && list[list.length - 1] === t) return;
    list.push(t);
  }

  function collectBySelectors(selectors) {
    const texts = [];
    for (let s = 0; s < selectors.length; s++) {
      const nodes = document.querySelectorAll(selectors[s]);
      for (let i = 0; i < nodes.length; i++) {
        if (nodes[i].querySelector && nodes[i].querySelector('[data-testid="user-message"],[data-testid="human-message"]')) {
          continue;
        }
        pushUnique(texts, nodes[i].innerText || nodes[i].textContent || "");
      }
      if (texts.length) return texts;
    }
    return texts;
  }

  function collectTurns() {
    const users = [];
    const assistants = [];
    const rows = document.querySelectorAll('[data-testid="transcript-row"]');
    if (rows.length) {
      rows.forEach((row) => {
        const text = AI.cleanText(row.innerText || "");
        if (!text || AI.isProcessOnly(text)) return;
        if (
          row.querySelector(
            '[data-testid="user-message"],[data-testid="human-message"]'
          )
        ) {
          users.push(text);
        } else {
          assistants.push(text);
        }
      });
      if (users.length || assistants.length) return { users, assistants };
    }

    USER_SELS.forEach((sel) => {
      document.querySelectorAll(sel).forEach((n) => {
        pushUnique(users, n.innerText || n.textContent || "");
      });
    });

    const fromClasses = collectBySelectors(ASSISTANT_SELS);
    fromClasses.forEach((t) => pushUnique(assistants, t));

    if (!assistants.length) {
      const bars = document.querySelectorAll('[data-testid="action-bar-copy"]');
      bars.forEach((bar) => {
        let el = bar.parentElement;
        let lastGood = el;
        for (let i = 0; i < 20 && el && el !== document.body; i++) {
          if (
            el.querySelector(
              '[data-testid="user-message"],[data-testid="human-message"]'
            )
          ) {
            break;
          }
          lastGood = el;
          el = el.parentElement;
        }
        pushUnique(
          assistants,
          lastGood && lastGood.innerText ? lastGood.innerText : ""
        );
      });
    }

    return { users, assistants };
  }

  AI.watchReplyCompletion("claude", () => {
    const generating = isGenerating();
    const turns = collectTurns();
    const latestUser = turns.users.length ? turns.users[turns.users.length - 1] : "";
    const latestAssistant = turns.assistants.length
      ? turns.assistants[turns.assistants.length - 1]
      : "";
    const preview = AI.previewWords(latestAssistant);
    return {
      generating: generating || (!!preview && AI.isProcessOnly(preview)),
      preview,
      textLength: latestAssistant.length,
      assistantCount: turns.assistants.length,
      latestUserPrompt: latestUser,
      latestUserFingerprint: latestUser ? AI.makeFingerprint(latestUser) : "",
      replyFingerprint: latestAssistant ? AI.makeFingerprint(latestAssistant) : "",
      replyAnchoredToLatestUser: !!(latestUser && preview)
    };
  });
})();
