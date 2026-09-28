import '../styles.css';
import { supabase } from '../lib/supabase.js';
import { pages } from './courses.js';
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

async function enter(session) {
  try {
    const { data: isTeacher, error } = await supabase.rpc('is_teacher');
    if (error) throw error;
    if (!isTeacher) {
      await supabase.auth.signOut();
      return renderLogin('這個帳號沒有教師權限。');
    }
    email = session.user.email;
    route();
  } catch {
    renderOffline(() => enter(session));
  }
}

const ROUTES = [
  [/^#\/$/, pages.home],
  [/^#\/course\/new\/([123])$/, pages.newCourse],
  [/^#\/course\/([\w-]+)$/, pages.editCourse],
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
  await supabase.auth.signOut();
  email = '';
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
        </div>
      </main>
      ${SIGNATURE}
    </div>`;
  app.querySelector('[data-retry]').addEventListener('click', retry);
}

window.addEventListener('hashchange', route);

supabase.auth.getSession().then(({ data: { session } }) => (session ? enter(session) : renderLogin()));
