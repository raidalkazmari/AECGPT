// يقرأ المحادثة المفتوحة في صفحة ChatGPT ويرسلها للتطبيق.
// قراءة فقط: لا يكتب في الصفحة ولا يضغط أي زر.
// يجرب عدة طرق للعثور على الرسائل، لأن ChatGPT يغيّر تصميم صفحته من وقت لآخر.
(() => {
  if (window.__aecgptBridge) return;
  window.__aecgptBridge = true;

  const JUNK_LINE =
    /^(Copy code|Copy|Plain text|نسخ الرمز|نسخ|نص عادي|You said:?|ChatGPT said:?|قلت:?|قال ChatGPT:?)[ \t]*(\n|$)/gm;

  const clean = (s) =>
    (s || "")
      .replace(/​/g, "")
      .replace(JUNK_LINE, "")
      .replace(/^\s*(You said|ChatGPT said|قلت|قال ChatGPT)\s*:\s*/i, "")
      .replace(/\n{3,}/g, "\n\n")
      .trim();

  const normRole = (r) => {
    r = (r || "").toLowerCase();
    if (r === "user" || r === "human") return "user";
    if (r === "assistant" || r === "ai" || r === "bot") return "assistant";
    return "";
  };

  const BODY_SEL =
    ".markdown, [class*='markdown'], [class*='prose'], .whitespace-pre-wrap";
  const outermost = (nodes, sel) =>
    nodes.filter((n) => !(n.parentElement && n.parentElement.closest(sel)));

  // ---- الطريقة 1: يكتشف بنفسه أي خاصية قيمتها user أو assistant
  // (مثل data-message-author-role أو data-turn أو أي اسم جديد يضعه ChatGPT)
  let roleAttr = null;

  function discoverRoleAttr() {
    if (!document.body) return null;
    const found = new Map();
    for (const el of document.body.getElementsByTagName("*")) {
      for (const a of el.attributes) {
        if (/^(class|id|style|value|name|type|autocomplete|placeholder|href|src)$/.test(a.name)) continue;
        if (normRole(a.value)) found.set(a.name, (found.get(a.name) || 0) + 1);
      }
    }
    if (!found.size) return null;
    // نفضّل الأسماء التي توحي بالدور أو الكاتب
    const ranked = [...found.keys()].sort((x, y) => {
      const score = (n) => (/role|author|turn|message|sender/i.test(n) ? 1 : 0);
      return score(y) - score(x) || found.get(y) - found.get(x);
    });
    return ranked[0];
  }

  function byRoleAttr() {
    if (!roleAttr || !document.querySelector("[" + roleAttr + "]")) roleAttr = discoverRoleAttr();
    if (!roleAttr) return [];
    const sel = "[" + roleAttr + "]";
    const nodes = [...document.querySelectorAll(sel)].filter((n) =>
      normRole(n.getAttribute(roleAttr))
    );
    return outermost(nodes, sel).map((n, i) => ({
      node: n.querySelector(BODY_SEL) || n,
      role: normRole(n.getAttribute(roleAttr)),
      id:
        n.getAttribute("data-message-id") ||
        n.getAttribute("data-testid") ||
        n.getAttribute("data-test-id") ||
        "r" + i,
    }));
  }

  // ---- الطريقة 2: "أدوار" المحادثة (article / conversation-turn)
  function byTurns() {
    const SEL =
      'article, [data-testid^="conversation-turn"], [data-test-id^="conversation-turn"], [data-test-id*="turn"]';
    return outermost([...document.querySelectorAll(SEL)], SEL).map((t, i) => {
      let role = "";
      const h = (t.querySelector("h5, h6, .sr-only") || {}).textContent || "";
      if (/you said|قلت/i.test(h)) role = "user";
      else if (/chatgpt said|قال/i.test(h)) role = "assistant";
      return { node: t.querySelector(BODY_SEL) || t, role, id: "t" + i };
    });
  }

  // ---- الطريقة 3: ردود ChatGPT فقط (نصوص markdown)
  function byMarkdown() {
    const sel = ".markdown, [class*='markdown']";
    return outermost([...document.querySelectorAll(sel)], sel).map((n, i) => ({
      node: n,
      role: "assistant",
      id: "md" + i,
    }));
  }

  function toMessages(items) {
    const out = [];
    for (const it of items) {
      if (!it.role) continue;
      const text = clean(it.node.innerText);
      if (text) out.push({ id: it.id, role: it.role, text });
    }
    return out;
  }

  function collect() {
    let messages = toMessages(byRoleAttr());
    if (!messages.length) messages = toMessages(byTurns());
    if (!messages.length) messages = toMessages(byMarkdown());

    const streaming = !!document.querySelector(
      '[data-testid="stop-button"], [data-test-id="stop-button"], button[aria-label*="Stop"], button[aria-label*="إيقاف"]'
    );
    const title = clean(document.title).replace(/\s*[-|–]\s*ChatGPT\s*$/i, "");
    return { title, streaming, messages, path: location.pathname };
  }

  // وصف دقيق لما في الصفحة، يظهر على الساعة إذا لم نجد الرسائل
  function diagnose() {
    const short = (s, n) => (s.length > n ? s.slice(0, n) + "…" : s);
    const attrs = new Set();
    const testIds = new Set();
    for (const el of document.body.getElementsByTagName("*")) {
      for (const a of el.attributes) {
        if (a.name.startsWith("data-") && !a.name.startsWith("data-app-shell")) attrs.add(a.name);
      }
      const t = el.getAttribute("data-test-id") || el.getAttribute("data-testid");
      if (t) testIds.add(short(t.replace(/\d+/g, "#"), 28));
    }
    // سلسلة الآباء لأول نص مستخدم ظاهر
    let chain = "-";
    const pw = document.querySelector(".whitespace-pre-wrap");
    if (pw) {
      const parts = [];
      let el = pw;
      for (let k = 0; el && k < 7; k++, el = el.parentElement) {
        const d = [...el.attributes]
          .filter((a) => a.name.startsWith("data-"))
          .map((a) => a.name.replace("data-", "") + (a.value && a.value.length < 20 ? "=" + a.value : ""))
          .join(",");
        parts.push(el.tagName.toLowerCase() + (d ? "[" + d + "]" : ""));
      }
      chain = parts.join(" < ");
    }
    return [
      "⚠️ تشخيص 2 — صوّر كل الشاشة (مرر للأسفل):",
      "PARENTS: " + chain,
      "TESTIDS: " + [...testIds].slice(0, 25).join(" | "),
      "ATTRS: " + [...attrs].slice(0, 40).join(" "),
    ].join("\n\n");
  }

  let lastSignature = "";
  let timer = null;
  let currentPath = location.pathname;
  let pathSince = Date.now();
  let diagnosedPath = "";

  function post(payload) {
    try {
      window.webkit.messageHandlers.aecgpt.postMessage(payload);
    } catch (e) {}
  }

  function flush() {
    timer = null;
    if (location.pathname !== currentPath) {
      currentPath = location.pathname;
      pathSince = Date.now();
    }
    const snap = collect();

    if (snap.messages.length === 0 && snap.path !== "/") {
      // أثناء التحميل تكون الصفحة فاضية لحظيًا: لا نمسح الساعة.
      // إذا بقيت فاضية 6 ثوانٍ في محادثة مفتوحة، نرسل التشخيص مرة واحدة.
      if (
        snap.path.includes("/c/") &&
        Date.now() - pathSince > 6000 &&
        diagnosedPath !== snap.path
      ) {
        diagnosedPath = snap.path;
        post({ diagnostic: diagnose(), path: snap.path });
      }
      return;
    }

    const signature = JSON.stringify(snap);
    if (signature === lastSignature) return;
    lastSignature = signature;
    post(snap);
  }

  function schedule() {
    if (!timer) timer = setTimeout(flush, 150);
  }

  new MutationObserver(schedule).observe(document.documentElement, {
    childList: true,
    subtree: true,
    characterData: true,
  });

  window.addEventListener("popstate", schedule);
  setInterval(schedule, 1500); // احتياط لأي تغيير لم يُلتقط
  schedule();
})();
