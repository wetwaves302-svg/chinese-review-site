import '../styles.css';
import { rpc, isSessionError } from '../lib/supabase.js';
import { setRoute } from '../lib/ui.js';
import { showLogin } from './login.js';
import { pages, renderOffline } from './pages.js';

const TOKEN_KEY = 'review-site.token';
const app = document.getElementById('app');

// localStorage 只存 token
const tokenStore = {
  get() { try { return localStorage.getItem(TOKEN_KEY); } catch { return null; } },
  set(token) { try { localStorage.setItem(TOKEN_KEY, token); } catch { /* 無法儲存時本次仍可使用 */ } },
  clear() { try { localStorage.removeItem(TOKEN_KEY); } catch { /* 同上 */ } },
};

const ROUTES = [
  [/^#\/$/, pages.home],
  [/^#\/grade\/([123])$/, pages.grade],
  [/^#\/course\/([\w-]+)$/, pages.course],
  [/^#\/course\/([\w-]+)\/material\/([\w-]+)$/, pages.material],
  [/^#\/course\/([\w-]+)\/video\/([\w-]+)$/, pages.video],
  [/^#\/course\/([\w-]+)\/session\/([\w-]+)(?:\/(\d+))?$/, pages.session],
  [/^#\/course\/([\w-]+)\/sessions\/(basic|advanced|challenge|past)$/, pages.sessions],
];

let student = null;
let token = null;
let navId = 0;
let cleanup = () => {};

function leavePage() {
  cleanup();
  cleanup = () => {};
  return ++navId;
}

// 提供給各頁面的工具：帶 token 呼叫資料庫、確認仍停在本頁、錯誤處理
function context(id) {
  return {
    app,
    student,
    isCurrent: () => id === navId,
    onCleanup(fn) { cleanup = fn; },
    call: (name, params = {}) => rpc(name, { p_token: token, ...params }),
    fail(error) {
      if (id !== navId) return;
      if (isSessionError(error)) return expire();
      renderOffline(app, route);
    },
    logout: () => signOut(),
  };
}

function route() {
  const id = leavePage();
  if (!student) return showLogin(app, signedIn);
  for (const [pattern, page] of ROUTES) {
    const match = pattern.exec(location.hash);
    if (match) {
      window.scrollTo(0, 0);
      return page(context(id), ...match.slice(1));
    }
  }
  setRoute('#/');
  route();
}

function signedIn(result) {
  token = result.token;
  student = result.student;
  tokenStore.set(token);
  setRoute('#/');
  route();
}

function signOut(message) {
  leavePage();
  tokenStore.clear();
  token = null;
  student = null;
  showLogin(app, signedIn, message);
}

function expire() {
  signOut('登入已過期，請重新登入。');
}

async function start() {
  token = tokenStore.get();
  if (!token) return showLogin(app, signedIn);
  try {
    const result = await rpc('student_session', { p_token: token });
    if (!result.ok) return expire();
    student = result.student;
    route();
  } catch {
    renderOffline(app, start);
  }
}

window.addEventListener('hashchange', route);

start();
