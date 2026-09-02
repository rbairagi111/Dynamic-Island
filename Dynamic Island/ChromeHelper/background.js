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

function forwardReplyReady(message, sender, sendResponse) {
  const tab = sender.tab;
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
  if (!message || message.type !== "replyReady") {
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
  if (!tab || typeof tab.id !== "number" || tab.active) return;
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
