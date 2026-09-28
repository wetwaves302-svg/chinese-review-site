const ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

export function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ESCAPES[c]);
}

export const SIGNATURE = '<div class="sign">國立花蓮高工｜貞伊老師製作</div>';

// 注音等輸入法常打出全形數字與空白，一律轉成半形並去除空白
export function digits(value) {
  return value.replace(/[０-９]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xFEE0)).replace(/[\s　]/g, '');
}

// 換頁時只改網址不留下瀏覽紀錄，例如登入畫面與登入後的首頁
export function setRoute(hash) {
  if (location.hash !== hash) history.replaceState(null, '', hash);
}

export const NETWORK_ERROR = '連線失敗，請確認網路後再試一次。';

export function brand() {
  return `
    <div class="brand">
      <h1>技高國文複習站</h1>
      <p>讀講義、看影片、寫三卷，把每一課弄懂</p>
    </div>`;
}

const BACK_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg>';
const HOME_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><path d="M3 11l9-7 9 7"/><path d="M5 10v10h5v-6h4v6h5V10"/></svg>';

// 登入後各頁共用的上方列：左側「返回」按鈕、中間標題、右側「首頁」按鈕（首頁本身改顯示 extra）
export function appBar({ back, title = '', home, extra = '' }) {
  return `
    <header class="app-bar">
      <div class="bar-inner">
        ${back
          ? `<a class="nav-btn back" href="${back.href}">${BACK_ICON}<span>${esc(back.label)}</span></a>`
          : '<span class="bar-brand">技高國文複習站</span>'}
        <span class="title">${esc(title)}</span>
        ${home ? `<a class="nav-btn home" href="${home.href}">${HOME_ICON}<span>${esc(home.label)}</span></a>` : extra}
      </div>
    </header>`;
}

export function errorBox(message) {
  return message ? `<div class="error" role="alert">${esc(message)}</div>` : '';
}

// 在表單的 [data-error] 位置顯示或清除錯誤，保留使用者已輸入的內容
export function showError(root, message) {
  root.querySelector('[data-error]').innerHTML = errorBox(message);
}

// 送出期間停用按鈕並改顯示文字，結束後還原
export async function withBusy(button, busyText, task) {
  const original = button.textContent;
  button.disabled = true;
  button.textContent = busyText;
  try {
    return await task();
  } finally {
    button.disabled = false;
    button.textContent = original;
  }
}
