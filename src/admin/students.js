import { supabase } from '../lib/supabase.js';
import { esc, SIGNATURE, appBar } from '../lib/ui.js';

// 重設學生登入：學生忘記 PIN 或被鎖定時，產生新的初始碼讓他重新設定 PIN
const GRADES = ['高一', '高二', '高三'];

async function loadRoster() {
  const [classes, students] = await Promise.all([
    supabase.from('classes').select('id, name, grade').eq('active', true).order('grade').order('name'),
    supabase.from('students').select('id, class_id, seat, display_name').eq('active', true).order('seat'),
  ]);
  if (classes.error) throw classes.error;
  if (students.error) throw students.error;
  return { classes: classes.data, students: students.data };
}

export async function studentsPage(ctx) {
  const frame = { back: { href: '#/', label: '教師後台' }, title: '重設學生登入' };
  const shell = (body) => {
    ctx.app.innerHTML = `
      ${appBar({ ...frame, home: null, extra: `<span class="who">${esc(ctx.email)}</span>` })}
      <div class="page app">
        <main class="content">${body}</main>
        ${SIGNATURE}
      </div>`;
  };
  shell('<p class="muted center">載入中…</p>');

  let data;
  try {
    data = await loadRoster();
  } catch (error) {
    return ctx.fail(error, '讀取班級名冊');
  }
  if (!ctx.isCurrent()) return;
  if (!data.classes.length) return shell('<div class="card center muted">目前沒有啟用中的班級。</div>');

  // confirmId：等待老師確認的學生；issued：剛產生的初始碼（只留在這個畫面，離開就消失）
  const state = { classId: data.classes[0].id, confirmId: null, busy: false, issued: null, error: '' };
  const who = (student, klass) => `${klass.name} ${student.seat} 號${student.display_name ? ` ${student.display_name}` : ''}`;

  const render = () => {
    const klass = data.classes.find((k) => k.id === state.classId);
    const students = data.students.filter((s) => s.class_id === klass.id);

    const rows = students.map((s) => {
      const confirming = state.confirmId === s.id;
      return `
        <tr class="${confirming ? 'confirming' : ''}">
          <td class="seat">${esc(s.seat)} 號</td>
          <td>${esc(s.display_name ?? '')}</td>
          <td class="act">${confirming ? `
            <span class="ask">確定重設 ${esc(s.seat)} 號？</span>
            <button class="btn small" type="button" data-do="${esc(s.id)}" ${state.busy ? 'disabled' : ''}>${state.busy ? '重設中…' : '確定重設'}</button>
            <button class="btn small ghost" type="button" data-cancel ${state.busy ? 'disabled' : ''}>取消</button>` : `
            <button class="btn small ghost" type="button" data-ask="${esc(s.id)}" ${state.busy ? 'disabled' : ''}>重設登入</button>`}
          </td>
        </tr>`;
    }).join('');

    shell(`
      ${state.issued ? `
        <div class="card reset-result" role="status">
          <h2>${esc(state.issued.who)} 已重設</h2>
          <p class="label">新的初始碼</p>
          <p class="code-big">${esc(state.issued.code)}</p>
          <p class="hint">請只交給學生本人。他用「通行碼 → 班級座號 → 這組初始碼」登入後，會被要求重新設定自己的 PIN。離開這個畫面後初始碼就不會再顯示，忘了記下來請再重設一次。</p>
          <button class="btn small ghost" type="button" data-dismiss>我記下來了，關閉</button>
        </div>` : ''}
      ${state.error ? `<div class="card"><div class="error" role="alert">${esc(state.error)}</div></div>` : ''}
      <div class="card">
        <p class="hint" style="margin-top:0">學生忘記 PIN 或錯太多次被鎖住時，在這裡按「重設登入」。重設會產生一組新的六位數初始碼、清除舊 PIN、解除鎖定，並讓他在其他裝置上的登入失效；作答紀錄、成績、錯題本與收藏都不受影響。</p>
        <div class="field">
          <label for="klass">班級</label>
          <select id="klass" class="input">
            ${data.classes.map((k) => `<option value="${esc(k.id)}" ${k.id === klass.id ? 'selected' : ''}>${esc(k.name)}（${GRADES[k.grade - 1]}）</option>`).join('')}
          </select>
        </div>
        ${rows ? `
          <table class="table reset">
            <thead><tr><th class="seat">座號</th><th>姓名</th><th></th></tr></thead>
            <tbody>${rows}</tbody>
          </table>` : '<p class="muted">這個班級目前沒有學生。</p>'}
      </div>`);

    const root = ctx.app;
    root.querySelector('#klass').addEventListener('change', (event) => {
      Object.assign(state, { classId: event.target.value, confirmId: null });
      render();
    });
    root.querySelector('[data-dismiss]')?.addEventListener('click', () => { state.issued = null; render(); });
    root.querySelector('[data-cancel]')?.addEventListener('click', () => { state.confirmId = null; render(); });
    root.querySelectorAll('[data-ask]').forEach((button) => button.addEventListener('click', () => {
      Object.assign(state, { confirmId: button.dataset.ask, error: '' });
      render();
    }));
    root.querySelector('[data-do]')?.addEventListener('click', () => reset(state.confirmId));
  };

  const reset = async (studentId) => {
    if (state.busy) return;
    const student = data.students.find((s) => s.id === studentId);
    const klass = data.classes.find((k) => k.id === student.class_id);
    state.busy = true;
    render();
    let failure = '';
    try {
      const { data: result, error } = await supabase.rpc('teacher_reset_student', { p_student_id: studentId });
      if (error || !result?.ok || !result.initial_code) failure = error?.message ?? '沒有取得初始碼';
      else state.issued = { who: who(student, klass), code: result.initial_code };
    } catch (error) {
      failure = error?.message ?? '連線失敗';
    }
    if (!ctx.isCurrent()) return;
    Object.assign(state, { busy: false, confirmId: null, error: failure ? `重設 ${who(student, klass)} 沒有成功，請再試一次。（${failure}）` : '' });
    render();
    if (!failure) window.scrollTo(0, 0);
  };

  render();
}
