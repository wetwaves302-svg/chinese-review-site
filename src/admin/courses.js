import { supabase } from '../lib/supabase.js';
import { esc, SIGNATURE, errorBox, showError, withBusy, appBar } from '../lib/ui.js';
import { driveFileId, videoEmbedUrl } from '../lib/media.js';

const GRADES = ['高一', '高二', '高三'];

const ITEM_TYPES = {
  material: {
    table: 'course_materials',
    urlField: 'drive_url',
    noun: '上課筆記',
    placeholder: '標題，例如：老師上課筆記 第五冊 L01',
    urlPlaceholder: 'https://drive.google.com/file/d/…/view',
    hint: '貼上雲端硬碟檔案的分享連結。檔案請設為「知道連結的任何人都能檢視」，學生才打得開。',
    invalid: '這不是雲端硬碟的檔案連結，請在檔案上按「共用」→「複製連結」後貼上。',
    isValid: (url) => Boolean(driveFileId(url)),
  },
  video: {
    table: 'course_videos',
    urlField: 'video_url',
    noun: '影片',
    placeholder: '標題，例如：鴻門宴 第一段',
    urlPlaceholder: 'https://www.loom.com/share/… 或 YouTube 網址',
    hint: '貼上 Loom 或 YouTube 影片的分享連結，學生會依這裡的順序觀看。',
    invalid: '這不是 Loom 或 YouTube 的影片連結，請貼上 https://www.loom.com/share/ 或 YouTube 影片頁的網址。',
    isValid: (url) => Boolean(videoEmbedUrl(url)),
  },
};

function shell(ctx, { back, title, body }) {
  ctx.app.innerHTML = `
    ${appBar({ back, title, home: back && back.href !== '#/' ? { href: '#/', label: '後台首頁' } : null, extra: `<span class="who">${esc(ctx.email)}</span>` })}
    <div class="page app">
      <main class="content">${body}</main>
      ${SIGNATURE}
    </div>`;
}

function loading(ctx, frame) {
  shell(ctx, { ...frame, body: '<p class="muted center">載入中…</p>' });
}

// 學期清單與今天（台灣時間）所在的學期
async function loadSemesters() {
  const { data, error } = await supabase.from('semesters').select('id, name, starts_on, ends_on').order('starts_on');
  if (error) throw error;
  return data;
}

function currentSemesterId(semesters) {
  const today = new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Taipei' }).format(new Date());
  const current = semesters.find((t) => t.starts_on <= today && (!t.ends_on || today <= t.ends_on));
  return current?.id ?? semesters.at(-1)?.id ?? null;
}

function flash(el, text) {
  el.textContent = text;
  setTimeout(() => { if (el.textContent === text) el.textContent = ''; }, 2500);
}

// ---------------------------------------------------------------------
// 後台首頁：各年級課程與班級名冊
// ---------------------------------------------------------------------

async function home(ctx) {
  const frame = { title: '教師後台' };
  loading(ctx, frame);

  const [courses, classes] = await Promise.all([
    supabase
      .from('courses')
      .select('id, grade, title, author, semester_id, is_core14, published, course_materials(count), course_videos(count)')
      .order('grade').order('position').order('created_at'),
    supabase
      .from('classes')
      .select('id, school_year, name, grade, students(count)')
      .eq('active', true)
      .eq('students.active', true)
      .order('grade').order('name'),
  ]);
  if (!ctx.isCurrent()) return;
  if (courses.error || classes.error) return ctx.fail();

  const blocks = GRADES.map((label, i) => {
    const rows = courses.data.filter((c) => c.grade === i + 1).map((c) => `
      <a class="item" href="#/course/${esc(c.id)}">
        <div class="txt">${esc(c.title)}
          <small>${[c.semester_id, c.is_core14 ? '部定古文' : null, c.author, `上課筆記 ${c.course_materials[0]?.count ?? 0}`, `影片 ${c.course_videos[0]?.count ?? 0}`].filter(Boolean).map(esc).join('・')}</small>
        </div>
        <span class="status ${c.published ? 'on' : ''}">${c.published ? '已上架' : '未上架'}</span>
        <span class="chev" aria-hidden="true">›</span>
      </a>`).join('');
    return `
      <div class="grade-block">
        <div class="gb-head">
          <h3>${label}</h3>
          <a class="btn small ghost" href="#/course/new/${i + 1}">＋ 新增課程</a>
        </div>
        ${rows ? `<div class="list">${rows}</div>` : '<p class="muted">尚無課程</p>'}
      </div>`;
  }).join('');

  const roster = classes.data.map((k) => `
    <tr>
      <td>${esc(k.school_year)}</td>
      <td>${esc(k.name)}</td>
      <td>${GRADES[k.grade - 1]}</td>
      <td class="num">${esc(k.students[0]?.count ?? 0)}</td>
    </tr>`).join('');

  shell(ctx, {
    ...frame,
    body: `
      <div class="card">
        <h2>課程管理</h2>
        ${blocks}
      </div>
      <div class="card">
        <h2>班級名冊</h2>
        ${roster ? `
          <table class="table">
            <thead><tr><th>學年</th><th>班級</th><th>年級</th><th class="num">學生人數</th></tr></thead>
            <tbody>${roster}</tbody>
          </table>` : '<p class="muted">目前沒有啟用中的班級。</p>'}
      </div>
      <div class="card">
        <a class="btn ghost" href="./" target="_blank" rel="noopener">開啟學生端</a>
        <button class="btn ghost" type="button" data-logout>登出</button>
      </div>`,
  });
  ctx.app.querySelector('[data-logout]').addEventListener('click', ctx.logout);
}

// ---------------------------------------------------------------------
// 課程編輯：課程資訊、上課筆記、影片
// ---------------------------------------------------------------------

function courseForm(course, semesters) {
  const gradeOptions = GRADES.map((label, i) =>
    `<option value="${i + 1}" ${course.grade === i + 1 ? 'selected' : ''}>${label}</option>`).join('');
  const semesterOptions = semesters.map((t) =>
    `<option value="${esc(t.id)}" ${course.semester_id === t.id ? 'selected' : ''}>${esc(t.name)}</option>`).join('');
  return `
    <form class="card" data-course novalidate>
      <h2>課程資訊</h2>
      <div data-error></div>
      <div class="form-grid">
        <div class="field">
          <label for="title">課名</label>
          <input id="title" class="input" value="${esc(course.title)}" placeholder="例如：鴻門宴">
        </div>
        <div class="field">
          <label for="grade">年級</label>
          <select id="grade" class="input">${gradeOptions}</select>
        </div>
        <div class="field">
          <label for="semester_id">學期</label>
          <select id="semester_id" class="input">${semesterOptions}</select>
          <div class="hint">學期全勤加分依此判定該年級當學期的課程。</div>
        </div>
        <div class="field">
          <label for="author">作者</label>
          <input id="author" class="input" value="${esc(course.author)}" placeholder="例如：司馬遷">
        </div>
        <div class="field">
          <label for="genre">文體或出處</label>
          <input id="genre" class="input" value="${esc(course.genre)}" placeholder="例如：史記・項羽本紀">
        </div>
        <div class="field">
          <label for="position">排序</label>
          <input id="position" class="input" inputmode="numeric" value="${esc(course.position)}">
          <div class="hint">同年級中數字小的排在前面。</div>
        </div>
      </div>
      <div class="field">
        <label for="intro">課程簡介（選填）</label>
        <textarea id="intro" class="input" rows="3">${esc(course.intro)}</textarea>
      </div>
      <div class="field">
        <label for="teacher_note">貞伊老師提醒（選填）</label>
        <textarea id="teacher_note" class="input" rows="2">${esc(course.teacher_note)}</textarea>
      </div>
      <label class="check"><input id="is_core14" type="checkbox" ${course.is_core14 ? 'checked' : ''}> 教育部技術高中部定 14 篇古文（學生端會醒目標註）</label>
      <label class="check"><input id="published" type="checkbox" ${course.published ? 'checked' : ''}> 上架（學生看得到這一課）</label>
      <button class="btn" type="submit">儲存課程資訊</button>
      <p class="saved" data-saved role="status"></p>
    </form>`;
}

function readCourseForm(form) {
  const value = (id) => form.querySelector(`#${id}`).value.trim();
  const checked = (id) => form.querySelector(`#${id}`).checked;
  return {
    title: value('title'),
    grade: Number(value('grade')),
    semester_id: value('semester_id') || null,
    author: value('author') || null,
    genre: value('genre') || null,
    position: Number.parseInt(value('position'), 10) || 0,
    intro: value('intro') || null,
    teacher_note: value('teacher_note') || null,
    is_core14: checked('is_core14'),
    published: checked('published'),
  };
}

async function newCourse(ctx, gradeParam) {
  const grade = Number(gradeParam);
  const frame = { back: { href: '#/', label: '教師後台' }, title: '新增課程' };
  loading(ctx, frame);
  let semesters;
  try {
    semesters = await loadSemesters();
  } catch {
    return ctx.fail();
  }
  if (!ctx.isCurrent()) return;

  shell(ctx, {
    ...frame,
    body: courseForm({
      grade, semester_id: currentSemesterId(semesters), title: '', position: 0, is_core14: false, published: false,
    }, semesters),
  });

  const form = ctx.app.querySelector('[data-course]');
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const values = readCourseForm(form);
    if (!values.title) return showError(form, '請輸入課名。');
    await withBusy(form.querySelector('[type=submit]'), '儲存中…', async () => {
      const { data, error } = await supabase.from('courses').insert(values).select('id').single();
      if (error) return showError(form, '儲存失敗，請再試一次。');
      ctx.go(`#/course/${data.id}`);
    });
  });
}

async function editCourse(ctx, courseId) {
  const frame = { back: { href: '#/', label: '教師後台' }, title: '編輯課程' };
  loading(ctx, frame);

  let course;
  let semesters;
  try {
    const [courseResult, semesterList] = await Promise.all([
      supabase.from('courses').select('*').eq('id', courseId).maybeSingle(),
      loadSemesters(),
    ]);
    if (courseResult.error) throw courseResult.error;
    course = courseResult.data;
    semesters = semesterList;
  } catch {
    if (ctx.isCurrent()) ctx.fail();
    return;
  }
  if (!ctx.isCurrent()) return;
  if (!course) {
    return shell(ctx, { ...frame, body: '<div class="card center"><p>找不到這一課。</p><a class="btn ghost" href="#/">回教師後台</a></div>' });
  }

  shell(ctx, {
    ...frame,
    title: course.title,
    body: `
      ${courseForm(course, semesters)}
      <section class="card" data-items="material"></section>
      <section class="card" data-items="video"></section>`,
  });

  const form = ctx.app.querySelector('[data-course]');
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const values = readCourseForm(form);
    if (!values.title) return showError(form, '請輸入課名。');
    await withBusy(form.querySelector('[type=submit]'), '儲存中…', async () => {
      const { error: saveError } = await supabase.from('courses').update(values).eq('id', courseId);
      if (saveError) return showError(form, '儲存失敗，請再試一次。');
      showError(form, '');
      ctx.app.querySelector('.app-bar .title').textContent = values.title;
      flash(form.querySelector('[data-saved]'), values.published ? '已儲存，學生看得到這一課。' : '已儲存，這一課目前未上架。');
    });
  });

  for (const section of ctx.app.querySelectorAll('[data-items]')) {
    itemEditor(ctx, section, ITEM_TYPES[section.dataset.items], courseId);
  }
}

// 上課筆記與影片共用的清單編輯：修改、排序、刪除、新增
async function itemEditor(ctx, section, type, courseId) {
  let items = [];

  async function reload(message = '') {
    const { data, error } = await supabase
      .from(type.table)
      .select(`id, title, ${type.urlField}, position`)
      .eq('course_id', courseId)
      .order('position').order('title');
    if (!ctx.isCurrent()) return;
    if (error) return ctx.fail();
    items = data;
    render(message);
  }

  function render(message) {
    const rows = items.map((item, i) => `
      <div class="edit-row" data-id="${esc(item.id)}">
        <input class="input" name="title" value="${esc(item.title)}" aria-label="${type.noun}標題">
        <input class="input" name="url" value="${esc(item[type.urlField])}" aria-label="${type.noun}連結">
        <div class="row-actions">
          <button class="btn small" type="button" data-act="save">儲存</button>
          <button class="btn small ghost" type="button" data-act="up" aria-label="上移" ${i === 0 ? 'disabled' : ''}>↑</button>
          <button class="btn small ghost" type="button" data-act="down" aria-label="下移" ${i === items.length - 1 ? 'disabled' : ''}>↓</button>
          <button class="btn small ghost danger" type="button" data-act="delete">刪除</button>
        </div>
      </div>`).join('');

    section.innerHTML = `
      <h2>${type.noun}</h2>
      <p class="hint" style="margin-top:-6px">${type.hint}</p>
      <div data-error>${errorBox(message)}</div>
      ${rows || `<p class="muted">還沒有${type.noun}。</p>`}
      <form class="edit-row add" novalidate>
        <input class="input" name="title" placeholder="${esc(type.placeholder)}" aria-label="新${type.noun}標題">
        <input class="input" name="url" placeholder="${esc(type.urlPlaceholder)}" aria-label="新${type.noun}連結">
        <div class="row-actions"><button class="btn small" type="submit">＋ 新增${type.noun}</button></div>
      </form>
      <p class="saved" data-saved role="status"></p>`;
  }

  function readRow(row) {
    const title = row.querySelector('[name=title]').value.trim();
    const url = row.querySelector('[name=url]').value.trim();
    if (!title) return { problem: `請輸入${type.noun}標題。` };
    if (!type.isValid(url)) return { problem: type.invalid };
    return { values: { title, [type.urlField]: url } };
  }

  async function write(task, doneText) {
    const { error } = await task();
    if (error) return showError(section, '儲存失敗，請再試一次。');
    await reload();
    if (doneText) flash(section.querySelector('[data-saved]'), doneText);
  }

  // 依畫面順序重新編號，只更新位置有變的項目
  async function saveOrder(ordered) {
    const results = await Promise.all(ordered
      .map((item, position) => ({ item, position }))
      .filter(({ item, position }) => item.position !== position)
      .map(({ item, position }) => supabase.from(type.table).update({ position }).eq('id', item.id)));
    return { error: results.find((r) => r.error)?.error ?? null };
  }

  section.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-act]');
    if (!button) return;
    const row = button.closest('.edit-row');
    const index = items.findIndex((item) => item.id === row.dataset.id);
    const item = items[index];
    showError(section, '');

    if (button.dataset.act === 'save') {
      const { values, problem } = readRow(row);
      if (problem) return showError(section, problem);
      await withBusy(button, '儲存中…', () =>
        write(() => supabase.from(type.table).update(values).eq('id', item.id), `已儲存「${values.title}」。`));
    } else if (button.dataset.act === 'up' || button.dataset.act === 'down') {
      const target = button.dataset.act === 'up' ? index - 1 : index + 1;
      const ordered = [...items];
      [ordered[index], ordered[target]] = [ordered[target], ordered[index]];
      button.disabled = true;
      await write(() => saveOrder(ordered));
    } else if (button.dataset.act === 'delete') {
      if (!confirm(`確定要刪除「${item.title}」嗎？學生對它的標記會一併刪除，無法復原。`)) return;
      await withBusy(button, '刪除中…', () =>
        write(() => supabase.from(type.table).delete().eq('id', item.id), `已刪除「${item.title}」。`));
    }
  });

  section.addEventListener('submit', async (event) => {
    event.preventDefault();
    const form = event.target;
    const { values, problem } = readRow(form);
    if (problem) return showError(section, problem);
    const position = items.length ? Math.max(...items.map((item) => item.position)) + 1 : 0;
    await withBusy(form.querySelector('[type=submit]'), '新增中…', () =>
      write(() => supabase.from(type.table).insert({ ...values, course_id: courseId, position }), `已新增「${values.title}」。`));
  });

  section.innerHTML = '<p class="muted">載入中…</p>';
  await reload();
}

export const pages = { home, newCourse, editCourse };
