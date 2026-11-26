// 讀解析關卡（2026-11-26 貞伊老師要求：避免學生寫完就算、只記答案）
//   每題作答後至少停留幾秒才能到下一題：答對 4 秒、答錯 10 秒；
//   答錯時畫面提示看詳解、做筆記、確認自己學會。
//   「還沒讀完」的題目記在這台裝置上，重新整理或跳到別題都會被帶回來。

const KEY = 'review-site.unread';

function load() {
  try {
    return JSON.parse(localStorage.getItem(KEY)) ?? {};
  } catch {
    return {};
  }
}

function save(all) {
  try {
    localStorage.setItem(KEY, JSON.stringify(all));
  } catch { /* 無法儲存時只是少了重新整理後的保護 */ }
}

export const unread = {
  list: (sessionId) => load()[sessionId] ?? [],
  has: (sessionId, questionId) => unread.list(sessionId).includes(questionId),
  add(sessionId, questionId) {
    const all = load();
    all[sessionId] = [...new Set([...(all[sessionId] ?? []), questionId])];
    save(all);
  },
  clear(sessionId, questionId) {
    const all = load();
    const rest = (all[sessionId] ?? []).filter((id) => id !== questionId);
    if (rest.length) all[sessionId] = rest;
    else delete all[sessionId];
    save(all);
  },
};

// 最少停留秒數（2026-11-26 貞伊老師定）：答對 4 秒、答錯 10 秒
export const readSeconds = (result) => (result.correct ? 4 : 10);

// 在按鈕上倒數；畫面不在前景時不計時。倒數完才能按，按下後執行 onDone。
export function countdown(button, seconds, label, onDone) {
  let left = seconds;
  button.disabled = true;
  const show = () => { button.textContent = left > 0 ? `請先看詳解（${left}）` : label; };
  show();
  const timer = setInterval(() => {
    if (!button.isConnected) return clearInterval(timer);
    if (document.visibilityState !== 'visible') return;
    left -= 1;
    show();
    if (left <= 0) {
      clearInterval(timer);
      button.disabled = false;
    }
  }, 1000);
  button.addEventListener('click', () => { if (left <= 0) onDone(); });
}
