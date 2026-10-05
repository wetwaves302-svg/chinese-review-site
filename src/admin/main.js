import '../styles.css';
import { supabase } from '../lib/supabase.js';
import { pages } from './courses.js';
import { statsPage } from './stats.js';
import { SIGNATURE, NETWORK_ERROR, brand, errorBox, showError, withBusy, setRoute } from '../lib/ui.js';

const app = document.getElementById('app');

function renderLogin(message = '') {
  setRoute('#/login');
  app.innerHTML = `
    <div class="page">
      ${brand()}
      <main class="content">
        <div class="card">
          <form novalidate>
            <h2>教師登入</h2>
            <div data-error>${errorBox(message)}</div>
            <div class="field">
              <label for="email">電子郵件</label>
              <input id="email" class="input" type="email" autocomplete="username" autofocus>
            </div>
            <div class="field">
              <label for="password">密碼</label>
              <input id="password" class="input" type="password" autocomplete="current-password">
            </div>
            <button class="btn" type="submit">登入</button>
          </form>
        </div>
        <div class="card center"><a href="./">回學生登入</a></div>
      </main>
      ${SIGNATURE}
    </div>`;

  const form = app.querySelector('form');
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const email = form.email.value.trim();
    const password = form.password.value;
    if (!email || !password) return showError(form, '請輸入電子郵件與密碼。');

    await withBusy(form.querySelector('[type=submit]'), '登入中…', async () => {
      const { data, error } = await supabase.auth.signInWithPassword({ email, password });
      if (error) {
        form.password.value = '';
        return showError(form, error.code === 'invalid_credentials' ? '電子郵件或密碼不正確。' : NETWORK_ERROR);
      }
      await enter(data.session);
    });
  });
}

let email = '';
let navId = 0;

// 登入狀態失效（過期或被撤銷）時資料庫回 401／403，這不是網路問題，要請老師重新登入
function isAuthError(error, status) {
  return status === 401 || status === 403
    || ['PGRST301', 'PGRST302', '42501'].includes(error?.code) || /jwt/i.test(error?.message ?? '');
}

// 只清掉這個瀏覽器存的登入狀態；即使連不上伺服器也能完成
async function forgetSession() {
  try {
    await supabase.auth.signOut({ scope: 'local' });
  } catch {
    // 清不掉也照樣回登入畫面
  }
  email = '';
}

async function enter(session) {
  let result;
  try {
    result = await supabase.rpc('is_teacher');
  } catch {
    return renderOffline(start);
  }
  const { data: isTeacher, error, status } = result;
  if (error) {
    if (isAuthError(error, status)) {
      await forgetSession();
      return renderLogin('登入已過期，請重新登入。');
    }
    return renderOffline(start);
  }
  if (!isTeacher) {
    await forgetSession();
    return renderLogin('這個帳號沒有教師權限。');
  }
  email = session.user.email;
  route();
}

const ROUTES = [
  [/^#\/$/, pages.home],
  [/^#\/course\/new\/([123])$/, pages.newCourse],
  [/^#\/course\/([\w-]+)$/, pages.editCourse],
  [/^#\/stats$/, statsPage],
];

function go(hash) {
  setRoute(hash);
  route();
}

function route() {
  if (!email) return;
  const id = ++navId;
  const ctx = {
    app,
    email,
    go,
    isCurrent: () => id === navId,
    fail() {
      if (id === navId) renderOffline(route);
    },
    logout,
  };
  for (const [pattern, page] of ROUTES) {
    const match = pattern.exec(location.hash);
    if (match) {
      window.scrollTo(0, 0);
      return page(ctx, ...match.slice(1));
    }
  }
  go('#/');
}

async function logout() {
  await forgetSession();
  renderLogin();
}

function renderOffline(retry) {
  app.innerHTML = `
    <div class="page">
      ${brand()}
      <main class="content">
        <div class="card center">
          ${errorBox(NETWORK_ERROR)}
          <button class="btn" type="button" data-retry>重新連線</button>
          <button class="btn ghost" type="button" data-relogin>重新登入</button>
        </div>
      </main>
      ${SIGNATURE}
    </div>`;
  app.querySelector('[data-retry]').addEventListener('click', retry);
  app.querySelector('[data-relogin]').addEventListener('click', async () => {
    await forgetSession();
    renderLogin();
  });
}

window.addEventListener('hashchange', route);

// 每次（含重新連線）都重新取得登入狀態，過期的會在這裡自動更新
async function start() {
  try {
    const { data: { session } } = await supabase.auth.getSession();
    return session ? enter(session) : renderLogin();
  } catch {
    renderOffline(start);
  }
}

start();
