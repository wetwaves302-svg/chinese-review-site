import { supabase } from '../lib/supabase.js';
import { esc, SIGNATURE, appBar } from '../lib/ui.js';
import {
  TEST_NAME, PAPER_KEYS, buildRecords, studentBonus, classCourses, courseComplete, summarize, exportRows, toCsv,
} from './stats-core.js';

// 教師統計：依學期與班級看每位學生的作答狀況與期末加分，並匯出總檔
const GRADES = ['高一', '高二', '高三'];
const PAPER_NAMES = { basic: '基礎卷', advanced: '進階卷', challenge: '挑戰卷' };
const PAGE = 1000;

const fmt = (value) => (value == null ? '—' : Number(value).toString());

// 資料庫一次最多回傳 1000 列，分頁讀完
async function fetchAll(build) {
  const rows = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await build().range(from, from + PAGE - 1);
    if (error) throw error;
    rows.push(...data);
    if (data.length < PAGE) return rows;
  }
}

async function loadData() {
  const one = async (query) => {
    const { data, error } = await query;
    if (error) throw error;
    return data;
  };
  const [semesters, classes, students, courses, sessions] = await Promise.all([
    one(supabase.from('semesters').select('id, name, starts_on, ends_on').order('starts_on')),
    one(supabase.from('classes').select('id, school_year, name, grade').eq('active', true).order('grade').order('name')),
    fetchAll(() => supabase.from('students').select('id, class_id, seat, display_name').eq('active', true).order('seat').order('id')),
    one(supabase.from('courses').select('id, title, grade, semester_id, position').eq('published', true)
      .order('grade').order('position').order('title')),
    fetchAll(() => supabase.from('paper_sessions').select('id, student_id, course_id, paper, score, submitted_at')
      .not('submitted_at', 'is', null).order('id')),
  ]);
  const testers = students.filter((s) => s.display_name === TEST_NAME);
  return {
    semesters, classes, courses,
    students: students.filter((s) => s.display_name !== TEST_NAME),
    testerCount: testers.length,
    records: buildRecords({ sessions, semesters }),
  };
}

function currentSemesterId(semesters) {
  const today = new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Taipei' }).format(new Date());
  return semesters.find((t) => t.starts_on <= today && (!t.ends_on || today <= t.ends_on))?.id ?? semesters.at(-1)?.id ?? null;
}

const who = (s) => `<td class="num">${esc(s.seat)}</td><td>${esc(s.display_name ?? '')}</td>`;

function bonusTable(students, data, klass, termId) {
  const rows = students.map((s) => {
    const b = studentBonus(data.records[s.id], { grade: klass.grade, termId, courses: data.courses });
    return `
      <tr>
        ${who(s)}
        <td class="num">${b.pastCourses}</td>
        <td class="num">${fmt(b.past)}</td>
        <td class="num">${b.required ? `${b.complete}／${b.required}` : '—'}</td>
        <td class="num">${b.attendance ? '<b class="ok">3</b>' : '0'}</td>
        <td class="num"><b>${fmt(b.total)}</b></td>
      </tr>`;
  }).join('');
  return `
    <div class="table-scroll">
      <table class="table stats">
        <thead><tr><th class="num">座號</th><th>名稱</th><th class="num">歷屆完成課數</th><th class="num">歷屆加分</th>
          <th class="num">全勤進度</th><th class="num">全勤加分</th><th class="num">期末加分合計</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;
}

function courseCard(course, students, data, required) {
  const rec = (s) => data.records[s.id]?.[course.id];
  const stat = (label, values) => {
    const { count, mean } = summarize(values);
    return `<span>${label} <b>${count}</b> 人${mean == null ? '' : `・平均 ${fmt(mean)}`}</span>`;
  };
  const summary = [
    ...PAPER_KEYS.map((p) => stat(PAPER_NAMES[p], students.map((s) => rec(s)?.best[p]))),
    `<span>歷屆練習 <b>${students.filter((s) => rec(s)?.done.past > 0).length}</b> 人</span>`,
    `<span>全部完成 <b>${students.filter((s) => courseComplete(rec(s))).length}</b> 人</span>`,
  ].join('');

  const cell = (r, p) => (r?.done[p] ? `${fmt(r.best[p])}<small>（${r.done[p]} 次）</small>` : '—');
  const rows = students.map((s) => {
    const r = rec(s);
    return `
      <tr${r ? '' : ' class="idle"'}>
        ${who(s)}
        ${PAPER_KEYS.map((p) => `<td class="num">${cell(r, p)}</td>`).join('')}
        <td class="num"><b>${fmt(r?.challengeScore)}</b></td>
        <td class="num">${r?.done.past ?? 0}</td>
      </tr>`;
  }).join('');

  return `
    <section class="card">
      <h2>${esc(course.title)}<span class="tag">${GRADES[course.grade - 1]}・${esc(course.semester_id ?? '')}</span>${required ? '' : '<span class="tag">非本班本學期課程</span>'}</h2>
      <div class="stat-line">${summary}</div>
      <div class="table-scroll">
        <table class="table stats">
          <thead><tr><th class="num">座號</th><th>名稱</th>
            <th class="num">基礎卷最高</th><th class="num">進階卷最高</th><th class="num">挑戰卷最高</th>
            <th class="num">本課挑戰積分</th><th class="num">歷屆次數</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
    </section>`;
}

function download(name, rows) {
  const url = URL.createObjectURL(new Blob([toCsv(rows)], { type: 'text/csv;charset=utf-8' }));
  const link = Object.assign(document.createElement('a'), { href: url, download: name });
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

export async function statsPage(ctx) {
  const frame = { back: { href: '#/', label: '教師後台' }, title: '成績統計' };
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
    data = await loadData();
  } catch (error) {
    return ctx.fail(error, '讀取成績統計');
  }
  if (!ctx.isCurrent()) return;
  if (!data.classes.length) return shell('<div class="card center muted">目前沒有啟用中的班級。</div>');

  const state = { termId: currentSemesterId(data.semesters), classId: data.classes[0].id };

  const render = () => {
    const klass = data.classes.find((k) => k.id === state.classId);
    const students = data.students.filter((s) => s.class_id === klass.id);
    const courses = classCourses({ students, records: data.records, courses: data.courses, grade: klass.grade, termId: state.termId });
    const started = students.filter((s) => data.records[s.id]).length;
    const full = students.filter((s) => studentBonus(data.records[s.id], {
      grade: klass.grade, termId: state.termId, courses: data.courses,
    }).attendance).length;

    shell(`
      <div class="card">
        <div class="form-grid">
          <div class="field">
            <label for="term">學期</label>
            <select id="term" class="input">${data.semesters.map((t) =>
              `<option value="${esc(t.id)}"${t.id === state.termId ? ' selected' : ''}>${esc(t.name)}</option>`).join('')}</select>
          </div>
          <div class="field">
            <label for="klass">班級</label>
            <select id="klass" class="input">${data.classes.map((k) =>
              `<option value="${esc(k.id)}"${k.id === state.classId ? ' selected' : ''}>${esc(k.name)}（${GRADES[k.grade - 1]}）</option>`).join('')}</select>
          </div>
        </div>
        <div class="stat-line">
          <span>班級人數 <b>${students.length}</b> 人</span>
          <span>已有作答紀錄 <b>${started}</b> 人</span>
          <span>學期全勤 <b>${full}</b> 人</span>
        </div>
        <div class="viewer-actions">
          <button class="btn" type="button" data-export="class">匯出本班（Excel 可開啟的 CSV）</button>
          <button class="btn ghost" type="button" data-export="all">匯出全部班級總檔</button>
        </div>
        <p class="hint">分數為各卷三次中的最高分。${data.testerCount ? `名稱為「${TEST_NAME}」的 ${data.testerCount} 個帳號不列入統計與匯出。` : ''}重新整理頁面可取得最新資料。</p>
      </div>
      <section class="card">
        <h2>期末加分</h2>
        <p class="hint">歷屆練習每課完成一次加 0.5 分（計入第一次完成時的學期）；本學期本年級每一課的三卷與歷屆都完成，學期全勤加 3 分。</p>
        ${bonusTable(students, data, klass, state.termId)}
      </section>
      ${courses.length
        ? courses.map((c) => courseCard(c, students, data, c.grade === klass.grade && c.semester_id === state.termId)).join('')
        : '<div class="card center muted">這個班級在這個學期沒有課程，也沒有作答紀錄。</div>'}`);

    ctx.app.querySelector('#term').addEventListener('change', (event) => { state.termId = event.target.value; render(); });
    ctx.app.querySelector('#klass').addEventListener('change', (event) => { state.classId = event.target.value; render(); });
    for (const button of ctx.app.querySelectorAll('[data-export]')) {
      button.addEventListener('click', () => {
        const all = button.dataset.export === 'all';
        const classIds = new Set(all ? data.classes.map((k) => k.id) : [klass.id]);
        const order = new Map(data.classes.map((k, i) => [k.id, i]));
        const list = data.students.filter((s) => classIds.has(s.class_id))
          .sort((a, b) => order.get(a.class_id) - order.get(b.class_id) || a.seat - b.seat);
        const rows = exportRows({ classes: data.classes, students: list, records: data.records,
          courses: data.courses, termId: state.termId });
        download(`國文複習站成績_${state.termId}_${all ? '全部班級' : klass.name}.csv`, rows);
      });
    }
  };
  render();
}
