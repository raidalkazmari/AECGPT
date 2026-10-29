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

  // يُبقي العناصر التي ليس لها أب من نفس المجموعة
  const outermostIn = (nodes) => {
    const set = new Set(nodes);
    return nodes.filter((n) => {
      for (let p = n.parentElement; p; p = p.parentElement) if (set.has(p)) return false;
      return true;
    });
  };

  // النص بدون كلمات الأزرار (نسخ، تعديل...) حتى لو كانت في نفس السطر
  const textWithoutButtons = (n) => {
    const labels = [
      ...new Set(
        [...n.querySelectorAll("button, [role='button']")]
          .map((b) => (b.innerText || "").trim())
          .filter(Boolean)
      ),
    ].sort((x, y) => y.length - x.length);
    return (n.innerText || "")
      .split("\n")
      .map((line) => {
        let t = line.trim();
        for (let changed = true; changed && t; ) {
          changed = false;
          for (const l of labels) {
            if (t === l) { t = ""; changed = true; break; }
            if (t.endsWith(l)) { t = t.slice(0, -l.length).trim(); changed = true; }
            if (t.startsWith(l)) { t = t.slice(l.length).trim(); changed = true; }
          }
        }
        return t;
      })
      .join("\n");
  };

  // ---- الطريقة 0: تصميم ChatGPT الجديد (app-shell، 2026)
  // رسائلك داخل data-user-message-bubble، والردود تحمل علامات النسخ والتحديد.
  const USER_SEL = "[data-user-message-bubble]";
  const ASSIST_SEL = [
    '[data-testid="chatgpt-writing-block"]',
    "[data-markdown-copy]",
    "[data-chatgpt-conversation-selection-target]",
    "[data-thread-find-target]",
    "pre", // رد فيه مربع كود/Plain text فقط
    ".markdown",
    "[class*='markdown']",
  ].join(", ");

  // ---- حصر القراءة في المحادثة المفتوحة فقط
  // ChatGPT يبقي المحادثات السابقة مخفية في الصفحة، فنختار المحادثة الحالية فقط.

  const conversationId = () => {
    const m = location.pathname.match(/\/c\/([^/?#]+)/);
    return m ? m[1] : "";
  };

  // عنصر يحمل رقم المحادثة الحالية (من الرابط) ويحتوي رسائل
  // نتيجة البحث تُحفظ، فلا نمسح الصفحة كلها في كل مرة (مهم أثناء كتابة الرد)
  let rootCache = { id: "", root: null, at: 0 };

  function conversationRoot() {
    const id = conversationId();
    if (!id || !document.body) return null;
    const c = rootCache;
    if (c.id === id && (c.root ? c.root.isConnected : Date.now() - c.at < 3000)) return c.root;
    const root = findConversationRoot(id);
    rootCache = { id, root, at: Date.now() };
    return root;
  }

  function findConversationRoot(id) {
    const hits = [];
    for (const el of document.body.getElementsByTagName("*")) {
      for (const a of el.attributes) {
        if (a.name !== "href" && a.value === id && el.querySelector(USER_SEL)) {
          hits.push(el);
          break;
        }
      }
    }
    if (!hits.length) return null;
    // أصغر غلاف يجمع كل أجزاء هذه المحادثة (قد تكون مقسّمة على عدة عناصر بنفس الرقم)
    let root = hits[0];
    while (root && !hits.every((h) => root.contains(h))) root = root.parentElement;
    return root;
  }

  // هل العنصر ظاهر فعلًا على الشاشة (وليس في محادثة مخفية)؟
  function isShown(el) {
    if (!el.getClientRects().length) return false;
    if (el.closest('[aria-hidden="true"], [inert], [hidden]')) return false;
    const r = el.getBoundingClientRect();
    const w = window.innerWidth || 10000;
    return r.width > 0 && r.right > 0 && r.left < w;
  }

  // أصغر غلاف يجمع أجزاء الرد، ثم نوسّعه لآخر حد قبل أن يشمل رسالة مستخدم
  function replyContainer(nodes, root) {
    const stop = root === document ? document.body : root;
    let c = nodes[0];
    while (c !== stop && !nodes.every((n) => c.contains(n))) c = c.parentElement;
    while (
      c !== stop &&
      c.parentElement &&
      c.parentElement !== stop &&
      !c.parentElement.querySelector(USER_SEL) &&
      !c.parentElement.matches("main, nav, header, form, body")
    ) {
      c = c.parentElement;
    }
    return c;
  }

  function byBubbles() {
    const root = conversationRoot() || document;
    const allUsers = outermost([...root.querySelectorAll(USER_SEL)], USER_SEL);
    const shownUsers = allUsers.filter(isShown);
    // إذا عرفنا الظاهر من المخفي، نطبّقه على الكل. وإلا نقرأ كل شيء
    const strict = shownUsers.length > 0;
    // الساعة تعرض آخر المحادثة فقط، فنقرأ آخر 40 سؤال وردودها (أخف على الجوال)
    const users = (strict ? shownUsers : allUsers).slice(-40);
    if (!users.length) return [];
    const first = users[0];
    const isAfterFirst = (n) =>
      first === n || !!(first.compareDocumentPosition(n) & Node.DOCUMENT_POSITION_FOLLOWING);

    const assistants = outermostIn(
      [...root.querySelectorAll(ASSIST_SEL)].filter(
        (n) =>
          isAfterFirst(n) &&
          (!strict || isShown(n)) &&
          !n.closest(USER_SEL) && // ليس داخل رسالة المستخدم
          !n.querySelector(USER_SEL) && // ولا يحتوي رسالة مستخدم (غلاف عام)
          !n.closest("button, nav, header, form, [data-app-shell-titlebar]")
      )
    );

    // نرتّب الكل حسب مكانه في الصفحة
    const items = [
      ...users.map((n) => ({ n, role: "user" })),
      ...assistants.map((n) => ({ n, role: "assistant" })),
    ].sort((a, b) =>
      a.n.compareDocumentPosition(b.n) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1
    );

    // أجزاء الرد المتتالية = رد واحد. نقرأ الغلاف الكامل لهذا الرد،
    // حتى يدخل كل شيء فيه: الفقرات ومربعات Plain text والكود والجداول.
    const groups = [];
    for (const it of items) {
      const last = groups[groups.length - 1];
      if (it.role === "assistant" && last && last.role === "assistant") last.nodes.push(it.n);
      else groups.push({ role: it.role, nodes: [it.n] });
    }

    const out = [];
    for (const g of groups) {
      let node;
      if (g.role === "user") {
        node = g.nodes[0].querySelector(".whitespace-pre-wrap") || g.nodes[0];
      } else {
        node = replyContainer(g.nodes, root);
      }
      const text = clean(textWithoutButtons(node));
      if (text) out.push({ role: g.role, text });
    }
    // رقم المحادثة جزء من المعرّف، حتى تعرف الساعة أنها محادثة مختلفة
    const cid = conversationId();
    let u = 0, a = 0;
    return out.map((m) => ({ ...m, id: cid + (m.role === "user" ? ":u" + u++ : ":a" + a++) }));
  }

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
    let messages = byBubbles();
    if (!messages.length) messages = toMessages(byRoleAttr());
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
      "⚠️ تشخيص 3 — صوّر كل الشاشة (مرر للأسفل):",
      "bubble:" + document.querySelectorAll(USER_SEL).length +
        " write:" + document.querySelectorAll('[data-testid="chatgpt-writing-block"]').length +
        " mdcopy:" + document.querySelectorAll("[data-markdown-copy]").length +
        " sel:" + document.querySelectorAll("[data-chatgpt-conversation-selection-target]").length +
        " find:" + document.querySelectorAll("[data-thread-find-target]").length,
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

  // إذا كانت الصفحة ثقيلة (محادثة طويلة) نقرأ بوتيرة أبطأ حتى لا يعلق الجوال
  let delay = 150;

  function flush() {
    timer = null;
    const started = performance.now();
    try {
      flushNow();
    } catch (e) {
      // خطأ غير متوقع في الصفحة: نتجاهله ونكمل في الدورة القادمة بدل أن يتوقف السكربت
    }
    const cost = performance.now() - started;
    delay = Math.min(1000, Math.max(150, cost * 6));
  }

  function flushNow() {
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
    if (!timer) timer = setTimeout(flush, delay);
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
