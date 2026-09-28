import '../styles.css';
import { supabase } from '../lib/supabase.js';
import { esc, SIGNATURE, NETWORK_ERROR, brand, errorBox, showError, withBusy } from '../lib/ui.js';

const app = document.getElementById('app');

function setRoute(hash) {
  if (location.hash !== hash) history.replaceState(null, '', hash);
}

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

async function enter(session) {
  try {
    const { data: isTeacher, error } = await supabase.rpc('is_teacher');
    if (error) throw error;
    if (!isTeacher) {
      await supabase.auth.signOut();
      return renderLogin('這個帳號沒有教師權限。');
    }

    const { data: classes, error: classError } = await supabase
      .from('classes')
      .select('id, school_year, name, grade, students(count)')
      .eq('active', true)
      .eq('students.active', true)
      .order('grade')
      .order('name');
    if (classError) throw classError;

    renderHome(session.user.email, classes);
  } catch {
    renderOffline(session);
  }
}

function renderHome(email, classes) {
  setRoute('#/');
  const rows = classes.map((k) => `
    <tr>
      <td>${esc(k.school_year)}</td>
      <td>${esc(k.name)}</td>
      <td>高${'一二三'[k.grade - 1]}</td>
      <td class="num">${esc(k.students[0]?.count ?? 0)}</td>
    </tr>`).join('');

  app.innerHTML = `
    <div class="page wide">
      <header class="app-bar">
        <span class="title">教師後台</span>
        <span class="who">${esc(email)}</span>
      </header>
      <main class="content">
        <div class="card">
          <h2>班級名冊</h2>
          ${classes.length ? `
            <table class="table">
              <thead><tr><th>學年</th><th>班級</th><th>年級</th><th class="num">學生人數</th></tr></thead>
              <tbody>${rows}</tbody>
            </table>` : '<p class="muted">目前沒有啟用中的班級。</p>'}
        </div>
        <div class="card">
          <button class="btn ghost" type="button" data-logout>登出</button>
        </div>
      </main>
      ${SIGNATURE}
    </div>`;

  app.querySelector('[data-logout]').addEventListener('click', async () => {
    await supabase.auth.signOut();
    renderLogin();
  });
}

function renderOffline(session) {
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
  app.querySelector('[data-retry]').addEventListener('click', () => enter(session));
}

supabase.auth.getSession().then(({ data: { session } }) => (session ? enter(session) : renderLogin()));
