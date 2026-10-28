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
      .replace(/\n{3,}/g, "\n\n")
      .trim();

  const normRole = (r) => {
    r = (r || "").toLowerCase();
    if (r === "user" || r === "human") return "user";
    if (r === "assistant" || r === "ai" || r === "bot") return "assistant";
    return "";
  };

  // ---- الطريقة 1: العناصر التي تحمل دور الكاتب مباشرة
  function byAuthorRole() {
    return [...document.querySelectorAll("[data-message-author-role]")].map((n, i) => ({
      node: n,
      role: normRole(n.getAttribute("data-message-author-role")),
      id: n.getAttribute("data-message-id") || "m" + i,
    }));
  }

  // ---- الطريقة 2: "أدوار" المحادثة (article / conversation-turn / data-turn)
  function byTurns() {
    const SEL = 'article[data-turn], [data-testid^="conversation-turn"], article';
    // نتجاهل العنصر المتداخل داخل عنصر آخر مطابق، حتى لا تتكرر الرسالة
    const turns = [...document.querySelectorAll(SEL)].filter(
      (t) => !(t.parentElement && t.parentElement.closest(SEL))
    );
    return turns.map((t, i) => {
      let role = normRole(t.getAttribute("data-turn"));
      if (!role) {
        const inner = t.querySelector("[data-message-author-role]");
        if (inner) role = normRole(inner.getAttribute("data-message-author-role"));
      }
      if (!role) {
        const h = (t.querySelector("h5, h6, .sr-only") || {}).textContent || "";
        if (/you said|قلت/i.test(h)) role = "user";
        else if (/chatgpt said|قال/i.test(h)) role = "assistant";
      }
      const body =
        t.querySelector(".markdown, [class*='markdown'], .whitespace-pre-wrap") || t;
      return { node: body, role, id: t.getAttribute("data-testid") || "t" + i };
    });
  }

  // ---- الطريقة 3: ردود ChatGPT فقط (نصوص markdown)
  function byMarkdown() {
    return [...document.querySelectorAll(".markdown, [class*='markdown']")]
      .filter((n) => !n.parentElement.closest(".markdown, [class*='markdown']"))
      .map((n, i) => ({ node: n, role: "assistant", id: "md" + i }));
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
    let messages = toMessages(byAuthorRole());
    if (!messages.length) messages = toMessages(byTurns());
    if (!messages.length) messages = toMessages(byMarkdown());

    const streaming = !!document.querySelector(
      '[data-testid="stop-button"], button[aria-label*="Stop"], button[aria-label*="إيقاف"]'
    );
    const title = clean(document.title).replace(/\s*[-|–]\s*ChatGPT\s*$/i, "");
    return { title, streaming, messages, path: location.pathname };
  }

  // وصف مختصر لما في الصفحة، يظهر على الساعة إذا لم نجد الرسائل
  function diagnose() {
    const count = (sel) => document.querySelectorAll(sel).length;
    const attrs = new Set();
    document.querySelectorAll("main *").forEach((el) => {
      for (const a of el.attributes) if (a.name.startsWith("data-")) attrs.add(a.name);
    });
    return [
      "⚠️ لم أجد الرسائل. صوّر هذه الشاشة وأرسلها:",
      "article: " + count("article"),
      "data-turn: " + count("[data-turn]"),
      "conv-turn: " + count('[data-testid^="conversation-turn"]'),
      "markdown: " + count("[class*='markdown']"),
      "pre-wrap: " + count(".whitespace-pre-wrap"),
      "main: " + count("main"),
      "attrs: " + [...attrs].slice(0, 20).join(" "),
    ].join("\n");
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
