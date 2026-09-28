import { rpc } from '../lib/supabase.js';
import { esc, digits, SIGNATURE, NETWORK_ERROR, brand, errorBox, showError, withBusy, setRoute } from '../lib/ui.js';

// 通行碼與初始碼只留在記憶體，不寫入 localStorage
const login = { passcode: '', classes: [], classId: '', seat: '', initialCode: '' };
let app;
let onSignedIn;

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
  Object.assign(login, { passcode: '', classes: [], initialCode: '' });
  onSignedIn(result);
}

// 顯示登入第一段；登入成功時以資料庫回傳結果（含 token 與 student）呼叫 handleSignedIn
export function showLogin(root, handleSignedIn, message = '') {
  app = root;
  onSignedIn = handleSignedIn;
  Object.assign(login, { passcode: '', classes: [], classId: '', seat: '', initialCode: '' });
  renderPasscode(message);
}
