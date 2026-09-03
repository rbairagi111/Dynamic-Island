const NATIVE_HOST = "com.dynamicisland.chrome";

let nativePort = null;
let reconnectTimer = null;

function connectNative() {
  if (nativePort) return;
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
  } catch (e) {
    nativePort = null;
    scheduleReconnect();
    return;
  }

  nativePort.onMessage.addListener(() => {});

  nativePort.onDisconnect.addListener(() => {
    nativePort = null;
    scheduleReconnect();
  });

  try {
    nativePort.postMessage({ type: "hello", source: "extension", ts: Date.now() });
  } catch (e) {
    nativePort = null;
    scheduleReconnect();
  }
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNative();
  }, 2500);
}

function postToNative(message) {
  connectNative();
  if (!nativePort) {
    try {
      chrome.runtime.sendNativeMessage(NATIVE_HOST, message);
    } catch (e) {}
    return;
  }
  try {
    nativePort.postMessage(message);
  } catch (e) {
    nativePort = null;
    scheduleReconnect();
    try {
      chrome.runtime.sendNativeMessage(NATIVE_HOST, message);
    } catch (e2) {}
  }
}

const geminiCompletedRequests = new Set();
const geminiCompletionAtByTab = new Map();
const geminiArmedUntilByTab = new Map();
const geminiPromptByTab = new Map();
const geminiTabByRequest = new Map();
const geminiPendingRequestsByTab = new Map();
const geminiCompletionTimerByTab = new Map();

function sendGeminiCompletion(tabId, requestId) {
  if (geminiCompletionAtByTab.has(tabId)) return;
  chrome.tabs.get(tabId, (tab) => {
    if (chrome.runtime.lastError || !tab) return;
    if (geminiCompletionAtByTab.has(tabId)) return;
    const preview = "Gemini response ready";
    geminiCompletionAtByTab.set(tabId, Date.now());
    postToNative({
      type: "replyReady",
      provider: "gemini",
      preview,
      textLength: preview.length,
      assistantCount: 1,
      latestUserPrompt: "",
      latestUserFingerprint: "",
      replyFingerprint: "gemini-request#" + requestId,
      replyAnchoredToLatestUser: true,
      networkCompletionToken: "webRequest#" + requestId,
      chromeTabId: tabId,
      url: tab.url || "",
      tabActive: !!tab.active,
      pageVisible: false,
      windowFocused: false,
      ts: Date.now()
    });
  });
}

function isGeminiGenerationRequest(url) {
  const value = String(url || "").toLowerCase();
  return (
    value.indexOf("streamgenerate") !== -1 ||
    value.indexOf("generatefreeformstreamed") !== -1 ||
    value.indexOf("generatecontent") !== -1
  );
}

function isGeminiBatchRequest(url) {
  return String(url || "").toLowerCase().indexOf("/data/batchexecute") !== -1;
}

function geminiRequestBody(details) {
  const body = details.requestBody;
  if (!body) return "";
  if (body.formData) {
    return Object.values(body.formData).flat().join(" ");
  }
  if (body.raw) {
    return body.raw
      .map((part) => {
        try {
          return part.bytes ? new TextDecoder().decode(part.bytes) : "";
        } catch (e) {
          return "";
        }
      })
      .join(" ");
  }
  return "";
}

function trackGeminiRequest(details) {
  const tabId = details.tabId;
  if (tabId < 0) return;
  const explicitlyGeneration = isGeminiGenerationRequest(details.url);
  const submittedRecently = (geminiArmedUntilByTab.get(tabId) || 0) >= Date.now();
  const prompt = geminiPromptByTab.get(tabId) || "";
  const promptNeedle = prompt.slice(0, 24);
  if (!submittedRecently && !promptNeedle) {
    return;
  }
  let requestText = geminiRequestBody(details).replace(/\+/g, " ");
  try {
    requestText = decodeURIComponent(requestText);
  } catch (e) {}
  const matchesPrompt = !!promptNeedle && requestText.indexOf(promptNeedle) !== -1;
  if (
    !explicitlyGeneration &&
    !(submittedRecently && isGeminiBatchRequest(details.url) && matchesPrompt)
  ) {
    return;
  }
  geminiTabByRequest.set(details.requestId, tabId);
  let pending = geminiPendingRequestsByTab.get(tabId);
  if (!pending) {
    pending = new Set();
    geminiPendingRequestsByTab.set(tabId, pending);
  }
  pending.add(details.requestId);
  const timer = geminiCompletionTimerByTab.get(tabId);
  if (timer) {
    clearTimeout(timer);
    geminiCompletionTimerByTab.delete(tabId);
  }
}

function finishGeminiRequest(details) {
  const tabId = geminiTabByRequest.get(details.requestId);
  if (typeof tabId !== "number") return;
  geminiTabByRequest.delete(details.requestId);
  const pending = geminiPendingRequestsByTab.get(tabId);
  if (!pending) return;
  pending.delete(details.requestId);
  if (pending.size) return;
  geminiPendingRequestsByTab.delete(tabId);
  geminiArmedUntilByTab.delete(tabId);
  geminiPromptByTab.delete(tabId);
  const timer = setTimeout(() => {
    geminiCompletionTimerByTab.delete(tabId);
    sendGeminiCompletion(tabId, details.requestId);
  }, 350);
  geminiCompletionTimerByTab.set(tabId, timer);
}

if (chrome.webRequest && chrome.webRequest.onBeforeRequest) {
  chrome.webRequest.onBeforeRequest.addListener(
    trackGeminiRequest,
    { urls: ["https://gemini.google.com/*"] },
    ["requestBody"]
  );
}

if (chrome.webRequest && chrome.webRequest.onCompleted) {
  chrome.webRequest.onCompleted.addListener(
    (details) => {
      if (!geminiTabByRequest.has(details.requestId)) return;
      if (geminiCompletedRequests.has(details.requestId)) return;
      geminiCompletedRequests.add(details.requestId);
      if (geminiCompletedRequests.size > 100) {
        const oldest = geminiCompletedRequests.values().next().value;
        geminiCompletedRequests.delete(oldest);
      }
      finishGeminiRequest(details);
    },
    { urls: ["https://gemini.google.com/*"] }
  );
}

if (chrome.webRequest && chrome.webRequest.onErrorOccurred) {
  chrome.webRequest.onErrorOccurred.addListener(
    finishGeminiRequest,
    { urls: ["https://gemini.google.com/*"] }
  );
}

function forwardReplyReady(message, sender, sendResponse) {
  const tab = sender.tab;
  if (
    message.provider === "gemini" &&
    tab &&
    geminiCompletionAtByTab.has(tab.id)
  ) {
    try {
      sendResponse({ ok: true, deduplicated: true });
    } catch (e) {}
    return false;
  }
  if (message.provider === "gemini" && tab && typeof tab.id === "number") {
    geminiCompletionAtByTab.set(tab.id, Date.now());
  }
  const base = {
    type: "replyReady",
    provider: message.provider || "claude",
    preview: message.preview || "",
    textLength: message.textLength || 0,
    assistantCount: message.assistantCount || 1,
    latestUserPrompt: message.latestUserPrompt || "",
    latestUserFingerprint: message.latestUserFingerprint || "",
    replyFingerprint: message.replyFingerprint || "",
    replyAnchoredToLatestUser: !!message.replyAnchoredToLatestUser,
    networkCompletionToken: message.networkCompletionToken || "",
    chromeTabId: tab && typeof tab.id === "number" ? tab.id : -1,
    url: (tab && tab.url) || "",
    tabActive: !!(tab && tab.active),
    ts: Date.now()
  };

  const finish = (windowFocused) => {
    // Only treat as "user is looking at this" when Chrome's window is focused
    // and this tab is active. Otherwise Claude/ChatGPT were wrongly suppressed
    // while the Mac focus was on another app (Gemini already allowed that case).
    const looking =
      !!windowFocused &&
      !!(tab && tab.active) &&
      !!message.pageVisible;
    postToNative(
      Object.assign({}, base, {
        pageVisible: looking,
        windowFocused: !!windowFocused
      })
    );
    try {
      sendResponse({ ok: true });
    } catch (e) {}
  };

  if (tab && typeof tab.windowId === "number") {
    try {
      chrome.windows.get(tab.windowId, (win) => {
        finish(!!(win && win.focused));
      });
      return true;
    } catch (e) {
      finish(false);
      return false;
    }
  }
  finish(false);
  return false;
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message) return false;
  if (message.type === "geminiPromptSubmitted") {
    const tabId = sender.tab && sender.tab.id;
    if (typeof tabId === "number") {
      geminiArmedUntilByTab.set(tabId, Date.now() + 5000);
      geminiPromptByTab.set(tabId, String(message.prompt || "").trim());
      geminiCompletionAtByTab.delete(tabId);
    }
    try {
      sendResponse({ ok: true });
    } catch (e) {}
    return false;
  }
  if (message.type !== "replyReady") {
    return false;
  }
  return forwardReplyReady(message, sender, sendResponse);
});

function filesForUrl(url) {
  url = String(url || "");
  if (/claude\.ai|claude\.com/.test(url)) return { files: ["shared.js", "content-claude.js"] };
  if (/chatgpt\.com|chat\.openai\.com/.test(url)) return { files: ["shared.js", "content-chatgpt.js"] };
  if (/gemini\.google\.com/.test(url)) {
    return { files: ["shared.js", "content-gemini.js"], pageFiles: ["content-gemini-page.js"] };
  }
  return null;
}

function injectTab(tab) {
  if (!tab || typeof tab.id !== "number" || tab.id < 0) return;
  const spec = filesForUrl(tab.url);
  if (!spec || !chrome.scripting) return;
  if (spec.pageFiles) {
    chrome.scripting.executeScript(
      { target: { tabId: tab.id }, files: spec.pageFiles, world: "MAIN", injectImmediately: true },
      () => {
        void chrome.runtime.lastError;
      }
    );
  }
  chrome.scripting.executeScript({ target: { tabId: tab.id }, files: spec.files }, () => {
    void chrome.runtime.lastError;
  });
}

function injectOpenAITabs() {
  if (!chrome.tabs || !chrome.tabs.query) return;
  chrome.tabs.query(
    {
      url: [
        "https://claude.ai/*",
        "https://*.claude.ai/*",
        "https://claude.com/*",
        "https://chatgpt.com/*",
        "https://chat.openai.com/*",
        "https://gemini.google.com/*"
      ]
    },
    (tabs) => {
      if (!tabs) return;
      tabs.forEach(injectTab);
    }
  );
}

if (chrome.tabs && chrome.tabs.onUpdated) {
  chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    if (changeInfo.status === "loading" || changeInfo.status === "complete") {
      injectTab(tab);
    }
  });
}

chrome.runtime.onInstalled.addListener(injectOpenAITabs);
if (chrome.runtime.onStartup) {
  chrome.runtime.onStartup.addListener(injectOpenAITabs);
}

connectNative();
injectOpenAITabs();
setInterval(() => {
  postToNative({ type: "hello", source: "extension", ts: Date.now() });
}, 15000);

function republishGeminiNetwork(tab) {
  if (!tab || typeof tab.id !== "number") return;
  if (!chrome.scripting) return;
  chrome.scripting.executeScript(
    {
      target: { tabId: tab.id },
      world: "MAIN",
      injectImmediately: true,
      func: () => {
        try {
          const net = window.__islandGeminiNet;
          if (!net) return;
          window.postMessage(
            {
              source: "island-gemini-net",
              pending: net.pending || 0,
              token: net.token || "",
              preview: net.preview || ""
            },
            "*"
          );
        } catch (e) {}
      }
    },
    () => {
      void chrome.runtime.lastError;
    }
  );
}

setInterval(() => {
  if (!chrome.tabs || !chrome.tabs.query) return;
  chrome.tabs.query({ url: ["https://gemini.google.com/*"] }, (tabs) => {
    (tabs || []).forEach(republishGeminiNetwork);
  });
}, 1500);
