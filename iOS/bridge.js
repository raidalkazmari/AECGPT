// يقرأ المحادثة المفتوحة في صفحة ChatGPT ويرسلها للتطبيق.
// قراءة فقط: لا يكتب في الصفحة ولا يضغط أي زر.
(() => {
  if (window.__aecgptBridge) return;
  window.__aecgptBridge = true;

  const JUNK_LINE = /^(Copy code|Copy|نسخ الرمز|نسخ)[ \t]*(\n|$)/gm;

  const clean = (s) =>
    (s || "")
      .replace(/​/g, "")
      .replace(JUNK_LINE, "")
      .replace(/\n{3,}/g, "\n\n")
      .trim();

  function collect() {
    const messages = [];
    document.querySelectorAll("[data-message-author-role]").forEach((node, i) => {
      const role = node.getAttribute("data-message-author-role");
      if (role !== "user" && role !== "assistant") return;
      const text = clean(node.innerText);
      if (!text) return;
      messages.push({
        id: node.getAttribute("data-message-id") || role + "-" + i,
        role,
        text,
      });
    });

    const streaming = !!document.querySelector(
      '[data-testid="stop-button"], button[aria-label*="Stop"], button[aria-label*="إيقاف"]'
    );
    const title = clean(document.title).replace(/\s*[-|–]\s*ChatGPT\s*$/i, "");

    return { title, streaming, messages, path: location.pathname };
  }

  let lastSignature = "";
  let timer = null;

  function flush() {
    timer = null;
    const snap = collect();

    // أثناء تحميل محادثة قديمة تكون الصفحة فاضية لحظيًا: لا نرسل شيئًا
    // حتى لا تُمسح الساعة. المسح يحدث فقط عند فتح محادثة جديدة فعلًا.
    if (snap.messages.length === 0 && snap.path !== "/") return;

    const signature = JSON.stringify(snap);
    if (signature === lastSignature) return;
    lastSignature = signature;

    try {
      window.webkit.messageHandlers.aecgpt.postMessage(snap);
    } catch (e) {}
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
