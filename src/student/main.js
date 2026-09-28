import '../styles.css';
import { rpc } from '../lib/supabase.js';
import { esc, digits, SIGNATURE, NETWORK_ERROR, brand, errorBox, showError, withBusy } from '../lib/ui.js';

const TOKEN_KEY = 'review-site.token';
const app = document.getElementById('app');

// localStorage 只存 token；通行碼與初始碼只留在記憶體
const tokenStore = {
  get() { try { return localStorage.getItem(TOKEN_KEY); } catch { return null; } },
  set(token) { try { localStorage.setItem(TOKEN_KEY, token); } catch { /* 無法儲存時本次仍可使用 */ } },
  clear() { try { localStorage.removeItem(TOKEN_KEY); } catch { /* 同上 */ } },
};

const login = { passcode: '', classes: [], classId: '', seat: '', initialCode: '' };
let student = null;

const GATE_ERRORS = {
  bad_passcode: '通行碼不正確，請再確認一次。',
  gate_busy: '目前嘗試的人太多，請過五分鐘再試。',
  gate_not_configured: '網站尚未設定通行碼，請告訴貞伊老師。',
};

function loginError(result) {
  switch (result.error) {
    case 'bad_credentials':
      return result.attempts_left
        ? `座號或密碼不正確，還可以再試 ${result.attempts_left} 次。`
        : '座號或密碼不正確。';
    case 'locked':
      return `錯誤次數太多，請 ${Math.ceil(result.retry_after_seconds / 60)} 分鐘後再試。`;
    case 'invalid_pin_format':
      return 'PIN 必須是 4 至 6 位數字。';
    case 'already_activated':
      return '這個座號已經設定過 PIN，請直接用 PIN 登入。';
    default:
      return GATE_ERRORS[result.error] ?? '登入失敗，請再試一次。';
  }
}

// 通行碼失效（例如老師更換了通行碼）時必須回到第一段
function needsNewPasscode(result) {
  return result.error === 'bad_passcode' || result.error === 'gate_not_configured';
}

function restartWithPasscode(result) {
  login.passcode = '';
  renderPasscode(result.error === 'bad_passcode' ? '通行碼已經更換，請重新輸入。' : GATE_ERRORS[result.error]);
}

function setRoute(hash) {
  if (location.hash !== hash) history.replaceState(null, '', hash);
}

function loginPage(stepTwo, body) {
  setRoute('#/login');
  app.innerHTML = `
    <div class="page">
      ${brand()}
      <main class="content">
        <div class="card">
          <div class="steps">
            <span class="on">1 班級通行碼</span>
            <span class="${stepTwo ? 'on' : ''}">2 班級與座號</span>
          </div>
          ${body}
        </div>
        <div class="card center"><a href="./admin.html">教師登入</a></div>
      </main>
      ${SIGNATURE}
    </div>`;
  return app.querySelector('form');
}

function renderPasscode(message = '') {
  const form = loginPage(false, `
    <form novalidate>
      <div data-error>${errorBox(message)}</div>
      <div class="field">
        <label for="passcode">班級通行碼</label>
        <input id="passcode" class="input" type="password" autocomplete="off" autofocus>
        <div class="hint">通行碼由貞伊老師在課堂上公布。</div>
      </div>
      <button class="btn" type="submit">下一步</button>
    </form>`);

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const passcode = form.passcode.value.trim();
    if (!passcode) return showError(form, '請輸入通行碼。');

    await withBusy(form.querySelector('[type=submit]'), '確認中…', async () => {
      try {
        const result = await rpc('list_classes', { p_passcode: passcode });
        if (!result.ok) return showError(form, GATE_ERRORS[result.error] ?? '無法確認通行碼，請再試一次。');
        Object.assign(login, { passcode, classes: result.classes });
        renderSignIn();
      } catch {
        showError(form, NETWORK_ERROR);
      }
    });
  });
}

function renderSignIn(message = '') {
  const chips = login.classes.map((k) => `
    <label class="chip">
      <input type="radio" name="classId" value="${esc(k.id)}" ${k.id === login.classId ? 'checked' : ''}>
      <span>${esc(k.name)}<small>高${'一二三'[k.grade - 1]}</small></span>
    </label>`).join('');

  const form = loginPage(true, `
    <form novalidate>
      <fieldset class="field">
        <legend>班級</legend>
        ${login.classes.length ? `<div class="chips">${chips}</div>` : '<p class="muted">目前沒有開放的班級，請告訴貞伊老師。</p>'}
      </fieldset>
      <div class="field">
        <label for="seat">座號</label>
        <input id="seat" class="input" inputmode="numeric" autocomplete="off" maxlength="2" value="${esc(login.seat)}">
      </div>
      <div data-error>${errorBox(message)}</div>
      <div class="field">
        <label for="secret">PIN 密碼</label>
        <input id="secret" class="input code" type="password" inputmode="numeric" maxlength="6" autocomplete="current-password">
        <div class="hint">第一次登入請輸入貞伊老師發的六位數初始碼，接著會請你設定自己的 PIN（4 至 6 位數字）。</div>
      </div>
      <button class="btn" type="submit">登入</button>
      <button class="btn ghost" type="button" data-back>回上一步</button>
    </form>`);

  form.querySelector('[data-back]').addEventListener('click', () => {
    login.passcode = '';
    renderPasscode();
  });

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const classId = form.querySelector('[name=classId]:checked')?.value ?? '';
    const seat = digits(form.seat.value);
    const secret = digits(form.secret.value);
    Object.assign(login, { classId, seat });

    if (!classId) return showError(form, '請選擇班級。');
    if (!/^[1-9][0-9]?$/.test(seat)) return showError(form, '請輸入正確的座號。');
    if (!/^[0-9]{4,6}$/.test(secret)) return showError(form, '只能輸入數字：PIN 是 4 至 6 位數字，初始碼是 6 位數字。');

    await withBusy(form.querySelector('[type=submit]'), '登入中…', async () => {
      try {
        const result = await rpc('student_login', {
          p_passcode: login.passcode,
          p_class_id: classId,
          p_seat: Number(seat),
          p_secret: secret,
        });
        if (result.ok && result.status === 'signed_in') return signedIn(result);
        if (result.ok && result.status === 'set_pin') {
          login.initialCode = secret;
          return renderSetPin();
        }
        if (needsNewPasscode(result)) return restartWithPasscode(result);
        form.secret.value = '';
        showError(form, loginError(result));
      } catch {
        showError(form, NETWORK_ERROR);
      }
    });
  });
}

function renderSetPin(message = '') {
  const form = loginPage(true, `
    <form novalidate>
      <h2>設定自己的 PIN</h2>
      <p class="hint" style="margin-top:-6px">之後每次登入都用這組 PIN。請記好，忘記時請找貞伊老師重設。</p>
      <div data-error>${errorBox(message)}</div>
      <div class="field">
        <label for="pin">新的 PIN（4 至 6 位數字）</label>
        <input id="pin" class="input code" type="password" inputmode="numeric" maxlength="6" autocomplete="new-password" autofocus>
      </div>
      <div class="field">
        <label for="pin2">再輸入一次</label>
        <input id="pin2" class="input code" type="password" inputmode="numeric" maxlength="6" autocomplete="new-password">
      </div>
      <button class="btn" type="submit">設定並登入</button>
      <button class="btn ghost" type="button" data-back>回上一步</button>
    </form>`);

  form.querySelector('[data-back]').addEventListener('click', () => {
    login.initialCode = '';
    renderSignIn();
  });

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const pin = digits(form.pin.value);
    if (!/^[0-9]{4,6}$/.test(pin)) return showError(form, 'PIN 必須是 4 至 6 位數字。');
    if (pin !== digits(form.pin2.value)) return showError(form, '兩次輸入的 PIN 不一樣，請再輸入一次。');

    await withBusy(form.querySelector('[type=submit]'), '設定中…', async () => {
      try {
        const result = await rpc('student_activate', {
          p_passcode: login.passcode,
          p_class_id: login.classId,
          p_seat: Number(login.seat),
          p_initial_code: login.initialCode,
          p_new_pin: pin,
        });
        if (result.ok) return signedIn(result);
        if (result.error === 'invalid_pin_format') return showError(form, loginError(result));
        login.initialCode = '';
        if (needsNewPasscode(result)) return restartWithPasscode(result);
        renderSignIn(loginError(result));
      } catch {
        showError(form, NETWORK_ERROR);
      }
    });
  });
}

function signedIn(result) {
  tokenStore.set(result.token);
  Object.assign(login, { passcode: '', classes: [], initialCode: '' });
  showHome(result.student);
}

function showHome(profile) {
  student = profile;
  setRoute('#/');
  const name = student.display_name || `${student.seat} 號同學`;
  app.innerHTML = `
    <div class="page">
      <header class="app-bar">
        <span class="title">技高國文複習站</span>
        <span class="who">${esc(student.class_name)} ${esc(student.seat)} 號</span>
      </header>
      <main class="content">
        <div class="card">
          <h2>歡迎，${esc(name)}</h2>
          <p class="muted" style="margin:0">你已經登入。貞伊老師上架課程後，課程會列在這裡。</p>
        </div>
        <div class="card">
          <button class="btn ghost" type="button" data-logout>登出</button>
          <p class="hint center">在公用電腦使用完畢，記得登出。</p>
        </div>
      </main>
      ${SIGNATURE}
    </div>`;
  app.querySelector('[data-logout]').addEventListener('click', logout);
}

function logout() {
  tokenStore.clear();
  student = null;
  Object.assign(login, { passcode: '', classes: [], classId: '', seat: '', initialCode: '' });
  renderPasscode();
}

function renderOffline() {
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
  app.querySelector('[data-retry]').addEventListener('click', start);
}

async function start() {
  const token = tokenStore.get();
  if (!token) return renderPasscode();
  try {
    const result = await rpc('student_session', { p_token: token });
    if (result.ok) return showHome(result.student);
    tokenStore.clear();
    renderPasscode('登入已過期，請重新登入。');
  } catch {
    renderOffline();
  }
}

// 手動改網址時依登入狀態回到正確畫面
window.addEventListener('hashchange', () => (student ? showHome(student) : renderPasscode()));

start();
