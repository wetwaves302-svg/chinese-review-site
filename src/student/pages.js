import { isSessionError } from '../lib/supabase.js';
import { esc, SIGNATURE, NETWORK_ERROR, brand, errorBox, appBar } from '../lib/ui.js';
import { drivePreviewUrl, videoEmbedUrl } from '../lib/media.js';

const GRADES = ['高一', '高二', '高三'];
const CORE14_LABEL = '★ 部定 14 篇古文・重點學習';

const ICONS = {
  material: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M6 3h9l4 4v14H6z"/><path d="M14 3v5h5"/></svg>',
  video: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg>',
};

const HOME = { href: '#/', label: '首頁' };

// 各頁共用的外框：上方列（返回、標題、首頁）、內容、署名
function shell(ctx, { back, title = '', body }) {
  ctx.app.innerHTML = `
    ${appBar({ back, title, home: back && back.href !== HOME.href ? HOME : null, extra: `<span class="who">${esc(ctx.student.class_name)} ${esc(ctx.student.seat)} 號</span>` })}
    <div class="page app">
      <main class="content">${body}</main>
      ${SIGNATURE}
    </div>`;
}

// 先顯示外框與「載入中」，資料回來且仍停在本頁時才畫內容
async function load(ctx, frame, fetcher) {
  shell(ctx, { ...frame, body: '<p class="muted center">載入中…</p>' });
  try {
    const data = await fetcher();
    return ctx.isCurrent() ? data : null;
  } catch (error) {
    ctx.fail(error);
    return null;
  }
}

function notFound(ctx, message) {
  shell(ctx, {
    back: { href: '#/', label: '首頁' },
    body: `<div class="card center"><p>${esc(message)}</p><a class="btn ghost" href="#/">回首頁</a></div>`,
  });
}

function markLabel(done, text) {
  return done ? `<span class="done">✓ ${text}</span>` : '<span class="todo">未標記</span>';
}

// 已閱讀／已看完 的切換按鈕
function bindMark(ctx, button, { rpcName, idKey, flagKey, id, done, labels }) {
  const paint = (text) => {
    button.textContent = text ?? (done ? labels.on : labels.off);
    button.classList.toggle('ghost', done);
    button.setAttribute('aria-pressed', String(done));
  };
  paint();
  button.addEventListener('click', async () => {
    button.disabled = true;
    try {
      const result = await ctx.call(rpcName, { [idKey]: id, [flagKey]: !done });
      if (result.ok) done = !done;
      paint();
    } catch (error) {
      if (isSessionError(error)) return ctx.fail(error);
      paint('連線失敗，請再點一次');
    } finally {
      button.disabled = false;
    }
  });
}

const DATE_FORMAT = new Intl.DateTimeFormat('zh-TW', {
  timeZone: 'Asia/Taipei', year: 'numeric', month: 'long', day: 'numeric', weekday: 'long',
});
const TIME_FORMAT = new Intl.DateTimeFormat('zh-TW', {
  timeZone: 'Asia/Taipei', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
});

async function home(ctx) {
  const frame = {};
  const data = await load(ctx, frame, () => ctx.call('student_courses'));
  if (!data) return;

  const name = ctx.student.display_name || `${ctx.student.seat} 號同學`;
  const grades = GRADES.map((label, i) => {
    const count = data.courses.filter((c) => c.grade === i + 1).length;
    const mine = ctx.student.grade === i + 1;
    return `
      <a class="item" href="#/grade/${i + 1}">
        <div class="ic grade">${label}</div>
        <div class="txt">${label}課程<small>${count ? `${count} 課` : '尚未上架'}</small></div>
        ${mine ? '<span class="mine">你的年級</span>' : ''}
        <span class="chev" aria-hidden="true">›</span>
      </a>`;
  }).join('');

  shell(ctx, {
    ...frame,
    body: `
      <div class="card hello">
        <div class="today" data-date></div>
        <div class="clock num" data-time></div>
        <p>歡迎，${esc(name)}</p>
      </div>
      <div class="section">
        <h3>選擇年級</h3>
        <div class="list grades">${grades}</div>
      </div>
      <div class="section">
        <button class="btn ghost" type="button" data-logout>登出</button>
        <p class="hint center">在公用電腦使用完畢，記得登出。</p>
      </div>`,
  });

  const dateEl = ctx.app.querySelector('[data-date]');
  const timeEl = ctx.app.querySelector('[data-time]');
  const tick = () => {
    const now = new Date();
    dateEl.textContent = DATE_FORMAT.format(now);
    timeEl.textContent = TIME_FORMAT.format(now);
  };
  tick();
  const timer = setInterval(tick, 1000);
  ctx.onCleanup(() => clearInterval(timer));
  ctx.app.querySelector('[data-logout]').addEventListener('click', ctx.logout);
}

async function grade(ctx, gradeParam) {
  const g = Number(gradeParam);
  const frame = { back: { href: '#/', label: '首頁' }, title: `${GRADES[g - 1]}課程` };
  const data = await load(ctx, frame, () => ctx.call('student_courses'));
  if (!data) return;

  const courses = data.courses.filter((c) => c.grade === g);
  const cards = courses.map((c) => `
    <a class="course-card${c.is_core14 ? ' core' : ''}" href="#/course/${esc(c.id)}">
      ${c.is_core14 ? `<div class="core14">${CORE14_LABEL}</div>` : ''}
      <div class="cc-title">${esc(c.title)}</div>
      <div class="cc-meta">${[c.author, c.genre].filter(Boolean).map(esc).join('・')}</div>
      <div class="cc-marks">
        ${c.materials ? `<span>${ICONS.material}講義 ${c.materials_viewed}/${c.materials}</span>` : ''}
        ${c.videos ? `<span>${ICONS.video}影片 ${c.videos_watched}/${c.videos}</span>` : ''}
      </div>
    </a>`).join('');

  shell(ctx, {
    ...frame,
    body: courses.length
      ? `<div class="course-list">${cards}</div>`
      : '<div class="card center muted">這個年級還沒有上架的課程。</div>',
  });
}

async function course(ctx, courseId) {
  const frame = { back: { href: '#/', label: '首頁' } };
  const data = await load(ctx, frame, () => ctx.call('student_course', { p_course_id: courseId }));
  if (!data) return;
  if (!data.ok) return notFound(ctx, '找不到這一課，可能已經下架。');

  const c = data.course;
  const materials = c.materials.map((m) => `
    <a class="item" href="#/course/${esc(c.id)}/material/${esc(m.id)}">
      <div class="ic">${ICONS.material}</div>
      <div class="txt">${esc(m.title)}</div>
      ${markLabel(m.viewed, '已閱讀')}
    </a>`).join('');
  const videos = c.videos.map((v) => `
    <a class="item" href="#/course/${esc(c.id)}/video/${esc(v.id)}">
      <div class="ic">${ICONS.video}</div>
      <div class="txt">${esc(v.title)}</div>
      ${markLabel(v.watched, '已看完')}
    </a>`).join('');

  shell(ctx, {
    back: { href: `#/grade/${c.grade}`, label: `${GRADES[c.grade - 1]}課程` },
    title: c.title,
    body: `
      <div class="lesson-head">
        <div class="grade-line">${GRADES[c.grade - 1]}</div>
        <h2>${esc(c.title)}</h2>
        ${c.author || c.genre ? `<div class="muted">${[c.author, c.genre].filter(Boolean).map(esc).join('・')}</div>` : ''}
      </div>
      ${c.is_core14 ? `<div class="core14-banner"><strong>${CORE14_LABEL}</strong>本課是教育部技術高中部定 14 篇古文之一，請務必重點學習！</div>` : ''}
      ${c.intro ? `<div class="card intro">${esc(c.intro)}</div>` : ''}
      ${c.teacher_note ? `<div class="note"><strong>貞伊老師提醒</strong>${esc(c.teacher_note)}</div>` : ''}
      <div class="course-sections">
        ${materials ? `<div class="section"><h3>講義</h3><div class="list">${materials}</div></div>` : ''}
        ${videos ? `<div class="section"><h3>影片</h3><div class="list">${videos}</div></div>` : ''}
      </div>
      ${materials || videos ? '' : '<div class="card center muted">這一課的講義與影片還在準備中。</div>'}`,
  });
}

async function material(ctx, courseId, materialId) {
  const frame = { back: { href: `#/course/${courseId}`, label: '回課程' } };
  const data = await load(ctx, frame, () => ctx.call('student_course', { p_course_id: courseId }));
  if (!data) return;
  const m = data.ok && data.course.materials.find((x) => x.id === materialId);
  if (!m) return notFound(ctx, '找不到這份講義，可能已經下架。');

  const preview = drivePreviewUrl(m.drive_url);
  shell(ctx, {
    back: { href: `#/course/${courseId}`, label: data.course.title },
    title: m.title,
    body: `
      ${preview ? `<div class="doc-frame"><iframe src="${esc(preview)}" title="${esc(m.title)}" allow="autoplay"></iframe></div>` : ''}
      <div class="viewer-actions">
        <button class="btn" type="button" data-mark></button>
        <a class="btn ghost" href="${esc(m.drive_url)}" target="_blank" rel="noopener">在新分頁開啟</a>
      </div>
      <p class="hint center">講義顯示不出來或太小，請點「在新分頁開啟」。</p>`,
  });

  bindMark(ctx, ctx.app.querySelector('[data-mark]'), {
    rpcName: 'student_mark_material', idKey: 'p_material_id', flagKey: 'p_viewed',
    id: m.id, done: m.viewed, labels: { off: '標記為已閱讀', on: '✓ 已閱讀（再點一下取消）' },
  });
}

async function video(ctx, courseId, videoId) {
  const frame = { back: { href: `#/course/${courseId}`, label: '回課程' } };
  const data = await load(ctx, frame, () => ctx.call('student_course', { p_course_id: courseId }));
  if (!data) return;
  const videos = data.ok ? data.course.videos : [];
  const index = videos.findIndex((x) => x.id === videoId);
  if (index < 0) return notFound(ctx, '找不到這支影片，可能已經下架。');

  const v = videos[index];
  const next = videos[index + 1];
  const embed = videoEmbedUrl(v.video_url);
  shell(ctx, {
    back: { href: `#/course/${courseId}`, label: data.course.title },
    title: v.title,
    body: `
      ${embed
        ? `<div class="video-frame"><iframe src="${esc(embed)}" title="${esc(v.title)}" allow="fullscreen; picture-in-picture; encrypted-media" allowfullscreen></iframe></div>`
        : `<a class="btn ghost" href="${esc(v.video_url)}" target="_blank" rel="noopener">開啟影片</a>`}
      <div class="viewer-actions">
        <button class="btn" type="button" data-mark></button>
      </div>
      ${next ? `
        <div class="list">
          <a class="item" href="#/course/${esc(courseId)}/video/${esc(next.id)}">
            <div class="ic">${ICONS.video}</div>
            <div class="txt"><small>下一支</small>${esc(next.title)}</div>
            <span class="chev" aria-hidden="true">›</span>
          </a>
        </div>` : ''}`,
  });

  bindMark(ctx, ctx.app.querySelector('[data-mark]'), {
    rpcName: 'student_mark_video', idKey: 'p_video_id', flagKey: 'p_watched',
    id: v.id, done: v.watched, labels: { off: '標記為已看完', on: '✓ 已看完（再點一下取消）' },
  });
}

export const pages = { home, grade, course, material, video };

export function renderOffline(app, retry) {
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
