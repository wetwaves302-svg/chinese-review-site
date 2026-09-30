import { isSessionError } from '../lib/supabase.js';
import { esc } from '../lib/ui.js';

export const PAPERS = {
  basic: { name: '基礎卷', tag: '必寫', tagClass: 'must' },
  advanced: { name: '進階卷', tag: '挑戰積分 25%' },
  challenge: { name: '挑戰卷', tag: '挑戰積分 10%' },
  past: { name: '歷屆試題', tag: '練習加分', tagClass: 'past' },
};

const LETTERS = ['A', 'B', 'C', 'D'];

const START_ERRORS = {
  locked: '完成基礎卷後才能寫這一卷。',
  no_attempts_left: '這一卷已經寫滿三次了。',
  no_questions: '這一卷還沒有題目。',
  not_found: '找不到這一課，可能已經下架。',
};

function formatScore(value) {
  return Number(value).toString();
}

// ---------------------------------------------------------------------
// 課程頁的「作答」區塊
// ---------------------------------------------------------------------

function paperStatus(p) {
  if (p.paper === 'past') {
    return p.completed ? `已練習 ${p.completed} 次` : '尚未練習';
  }
  if (!p.used) return '尚未作答';
  const best = p.best == null ? '' : `・最高 ${formatScore(p.best)} 分`;
  return `已寫 ${p.used}／${p.max_attempts} 次${best}`;
}

function paperAction(p) {
  if (!p.unlocked) return { label: '完成基礎卷後開放', disabled: true };
  if (p.open_session) return { label: '繼續作答' };
  if (p.max_attempts && p.used >= p.max_attempts) return { label: '已寫滿三次', disabled: true };
  if (p.paper === 'past') return { label: p.completed ? '再練習一次' : '開始練習' };
  return { label: p.used ? '再寫一次' : '開始作答' };
}

export function papersSection(courseId, data) {
  const papers = data.papers.filter((p) => p.pool > 0);
  if (!papers.length) return '';

  const cards = papers.map((p) => {
    const meta = PAPERS[p.paper];
    const action = paperAction(p);
    const reviewLatest = p.completed && !p.open_session && p.paper !== 'past';
    return `
      <div class="paper-card${p.unlocked ? '' : ' locked'}">
        <div class="pc-head">
          <h4>${meta.name}</h4>
          <span class="tag ${meta.tagClass ?? ''}">${meta.tag}</span>
        </div>
        <div class="pc-status">${paperStatus(p)}</div>
        ${p.paper === 'past' && p.completed ? '<div class="pc-bonus">期末總成績 +0.5 分（已取得）</div>' : ''}
        <button class="btn${action.disabled ? ' ghost' : ''}" type="button"
          data-start="${p.paper}" ${action.disabled ? 'disabled' : ''}>${action.label}</button>
        ${reviewLatest ? `<a class="pc-review" href="#/course/${esc(courseId)}/sessions/${p.paper}">看作答紀錄</a>` : ''}
      </div>`;
  }).join('');

  const score = data.challenge_score == null
    ? '<p class="muted">完成基礎卷後，這裡會顯示本課挑戰積分。</p>'
    : `<div class="challenge-score"><span>本課挑戰積分</span><b class="num">${formatScore(data.challenge_score)}</b><small>／135</small></div>
       <p class="hint">基礎卷最高分 ＋ 進階卷最高分 × 25% ＋ 挑戰卷最高分 × 10%</p>`;

  return `
    <section class="block quiz">
      <header class="block-head"><h3>作答</h3><span class="count">三卷各可寫三次，取最高分</span></header>
      <div class="quiz-body">
        ${score}
        <div class="paper-grid">${cards}</div>
        <p class="hint" data-start-error></p>
      </div>
    </section>`;
}

export function bindPapers(ctx, courseId) {
  for (const button of ctx.app.querySelectorAll('[data-start]')) {
    button.addEventListener('click', async () => {
      const errorEl = ctx.app.querySelector('[data-start-error]');
      button.disabled = true;
      try {
        const result = await ctx.call('student_start_paper', { p_course_id: courseId, p_paper: button.dataset.start });
        if (!result.ok) {
          errorEl.textContent = START_ERRORS[result.error] ?? '無法開始作答，請再試一次。';
          button.disabled = false;
          return;
        }
        location.hash = `#/course/${courseId}/session/${result.session_id}`;
      } catch (error) {
        if (isSessionError(error)) return ctx.fail(error);
        errorEl.textContent = '連線失敗，請再試一次。';
        button.disabled = false;
      }
    });
  }
}

// ---------------------------------------------------------------------
// 作答頁與成績頁
// ---------------------------------------------------------------------

// 同一張卷在換題時不重抓（含原圖，資料較大）
let cached = null;

async function loadSession(ctx, sessionId) {
  if (cached?.session.id === sessionId) return cached;
  const data = await ctx.call('student_paper_session', { p_session_id: sessionId });
  if (!data.ok) return data;
  cached = data;
  return data;
}

function paperTitle(session) {
  const meta = PAPERS[session.paper];
  return session.paper === 'past' ? `${meta.name} 第 ${session.attempt_no} 次練習` : `${meta.name} 第 ${session.attempt_no} 次`;
}

function progressBar(courseId, data, current) {
  const dots = data.questions.map((q, i) => {
    const state = q.result ? (q.result.correct ? 'right' : 'wrong') : '';
    return `<a class="dot ${state}${i === current ? ' now' : ''}" href="#/course/${esc(courseId)}/session/${esc(data.session.id)}/${i + 1}"
      aria-label="第 ${i + 1} 題${q.result ? (q.result.correct ? '，答對' : '，答錯') : '，未作答'}">${i + 1}</a>`;
  }).join('');
  const answered = data.questions.filter((q) => q.result).length;
  return `
    <div class="q-progress">
      <div class="dots">${dots}</div>
      <div class="q-count">已答 ${answered}／${data.questions.length} 題</div>
    </div>`;
}

// 歷屆試題標出年份與原卷題號，例如「110 年統測 第 4 題」
function pastLabel(q) {
  if (!q.past_year) return '';
  const number = q.past_number ? ` 第 ${q.past_number} 題` : '';
  return `<span class="past-tag">${q.past_year} 年${esc(q.past_exam ?? '統測')}${number}</span>`;
}

function passageCard(group) {
  return `
    <details class="card passage" open>
      <summary>閱讀文章${group.title ? `：${esc(group.title)}` : ''}</summary>
      <div class="passage-text">${esc(group.passage)}</div>
      ${group.source ? `<div class="passage-source">${esc(group.source)}</div>` : ''}
    </details>`;
}

function resultBlock(courseId, q) {
  const r = q.result;
  const explains = r.explains.map((text, i) => `
    <p class="${LETTERS[i] === r.key ? 'is-key' : ''}"><b>(${LETTERS[i]})</b>${esc(text)}</p>`).join('');
  const review = !r.correct && (r.review_video || r.review_material) ? `
    <div class="remedy">
      ${r.review_video ? `<a href="#/course/${esc(r.review_video.course_id)}/video/${esc(r.review_video.id)}">回看影片「${esc(r.review_video.title)}」${r.review_video.timestamp ? `<small>從 ${Math.floor(r.review_video.timestamp / 60)}:${String(r.review_video.timestamp % 60).padStart(2, '0')} 開始</small>` : ''}</a>` : ''}
      ${r.review_material ? `<a href="#/course/${esc(r.review_material.course_id)}/material/${esc(r.review_material.id)}">回看上課筆記「${esc(r.review_material.title)}」${r.review_material.page ? `<small>請翻到第 ${r.review_material.page} 頁</small>` : ''}</a>` : ''}
    </div>` : '';
  return `
    <div class="verdict ${r.correct ? 'right' : 'wrong'}">${r.correct ? '✓ 答對' : '✕ 這題要再留意'}<span>正確答案 (${r.key})</span></div>
    <div class="card explain">${explains}
      ${r.teacher_note ? `<div class="note"><strong>貞伊老師提醒</strong>${esc(r.teacher_note)}</div>` : ''}
    </div>
    ${review}`;
}

function questionBody(courseId, q) {
  const answered = Boolean(q.result);
  const options = LETTERS.map((letter, i) => {
    const classes = ['opt'];
    if (answered && letter === q.result.key) classes.push('right');
    if (answered && letter === q.result.answer && !q.result.correct) classes.push('wrong');
    if (answered && letter === q.result.answer) classes.push('chosen');
    const label = q.image ? `(${letter})` : `<span class="k">(${letter})</span><span>${esc(q.options[i])}</span>`;
    return `<button type="button" class="${classes.join(' ')}" data-answer="${letter}" ${answered ? 'disabled' : ''}>${label}</button>`;
  }).join('');
  return `
    ${q.image
      ? `<img class="q-image" src="${q.image}" alt="${esc(q.stem)}">`
      : `<p class="q-stem">${esc(q.stem)}</p>`}
    <div class="options${q.image ? ' letters' : ''}">${options}</div>
    ${answered ? resultBlock(courseId, q) : '<p class="hint center">選好答案就會立刻看到解析，選了就不能更改。</p>'}`;
}

export async function sessionPage(ctx, shell, courseId, sessionId, indexParam) {
  const frame = { back: { href: `#/course/${courseId}`, label: '回課程' } };
  shell(ctx, { ...frame, body: '<p class="muted center">載入中…</p>' });

  let data;
  try {
    data = await loadSession(ctx, sessionId);
  } catch (error) {
    return ctx.fail(error);
  }
  if (!ctx.isCurrent()) return;
  if (!data.ok) {
    return shell(ctx, { ...frame, body: '<div class="card center"><p>找不到這次作答。</p></div>' });
  }

  const { session, questions } = data;
  const base = `#/course/${courseId}/session/${sessionId}`;
  let index = indexParam ? Number(indexParam) - 1 : null;
  if (index == null || !(index >= 0 && index < questions.length)) {
    if (session.submitted) return summaryPage(ctx, shell, courseId, data);
    index = Math.max(questions.findIndex((q) => !q.result), 0);
    history.replaceState(null, '', `${base}/${index + 1}`);
  }

  const q = questions[index];
  const group = q.group_id ? data.groups[q.group_id] : null;
  const prev = index > 0 ? `${base}/${index}` : null;
  const next = index < questions.length - 1 ? `${base}/${index + 2}` : null;

  shell(ctx, {
    back: { href: `#/course/${courseId}`, label: session.course_title },
    title: paperTitle(session),
    body: `
      ${progressBar(courseId, data, index)}
      ${group ? passageCard(group) : ''}
      <div class="card question">
        <div class="q-meta">第 ${index + 1} 題${pastLabel(q)}</div>
        <div data-question>${questionBody(courseId, q)}</div>
      </div>
      <div class="q-foot">
        ${prev ? `<a class="btn ghost" href="${prev}">‹ 上一題</a>` : '<span></span>'}
        ${next ? `<a class="btn" href="${next}">下一題 ›</a>`
               : session.submitted ? `<a class="btn" href="${base}">看成績 ›</a>` : '<span></span>'}
      </div>`,
  });

  for (const button of ctx.app.querySelectorAll('[data-answer]')) {
    button.addEventListener('click', () => answer(ctx, shell, courseId, data, index, button.dataset.answer));
  }
}

async function answer(ctx, shell, courseId, data, index, letter) {
  const q = data.questions[index];
  if (q.result) return;
  for (const button of ctx.app.querySelectorAll('[data-answer]')) button.disabled = true;
  try {
    const res = await ctx.call('student_answer', {
      p_session_id: data.session.id, p_question_id: q.id, p_answer: letter,
    });
    if (!res.ok) throw new Error(res.error);
    q.result = res.result;
    Object.assign(data.session, { submitted: res.submitted, score: res.score, correct_count: res.correct_count });
  } catch (error) {
    if (isSessionError(error)) return ctx.fail(error);
    for (const button of ctx.app.querySelectorAll('[data-answer]')) button.disabled = false;
    ctx.app.querySelector('[data-question]').insertAdjacentHTML('beforeend', '<p class="error">連線失敗，請再選一次。</p>');
    return;
  }
  sessionPage(ctx, shell, courseId, data.session.id, String(index + 1));
}

function summaryPage(ctx, shell, courseId, data) {
  const { session, questions } = data;
  const base = `#/course/${courseId}/session/${session.id}`;
  const right = questions.filter((q) => q.result?.correct).length;
  const rows = questions.map((q, i) => `
    <a class="item" href="${base}/${i + 1}">
      <span class="mark ${q.result?.correct ? 'right' : 'wrong'}">${q.result?.correct ? '✓' : '✕'}</span>
      <div class="txt">第 ${i + 1} 題<small>${esc(q.stem.length > 34 ? `${q.stem.slice(0, 34)}…` : q.stem)}</small></div>
      <span class="chev" aria-hidden="true">›</span>
    </a>`).join('');

  const headline = session.paper === 'past'
    ? `<div class="big-score">答對 <b class="num">${right}</b>／${questions.length} 題</div>
       <p class="hint center">歷屆試題只供練習、不計分；完成練習可獲期末總成績加分（每課上限 0.5 分）。</p>`
    : `<div class="big-score"><b class="num">${formatScore(session.score)}</b> 分</div>
       <p class="hint center">答對 ${right}／${questions.length} 題。三次作答取最高分。</p>`;

  shell(ctx, {
    back: { href: `#/course/${courseId}`, label: session.course_title },
    title: `${paperTitle(session)} 成績`,
    body: `
      <div class="card center result-card">${headline}</div>
      <div class="section"><h3>逐題檢討（點進去看解析）</h3><div class="list">${rows}</div></div>
      <div class="section"><a class="btn" href="#/course/${esc(courseId)}">回課程</a></div>`,
  });
}

// 從課程頁「看作答紀錄」進入：列出該卷各次成績
export async function sessionsPage(ctx, shell, courseId, paper) {
  const frame = { back: { href: `#/course/${courseId}`, label: '回課程' }, title: `${PAPERS[paper]?.name ?? ''}作答紀錄` };
  shell(ctx, { ...frame, body: '<p class="muted center">載入中…</p>' });
  let data;
  try {
    data = await ctx.call('student_paper_history', { p_course_id: courseId, p_paper: paper });
  } catch (error) {
    return ctx.fail(error);
  }
  if (!ctx.isCurrent()) return;
  const rows = (data.sessions ?? []).map((s) => `
    <a class="item" href="#/course/${esc(courseId)}/session/${esc(s.id)}">
      <div class="txt">第 ${s.attempt_no} 次<small>${s.submitted ? `${formatScore(s.score)} 分・答對 ${s.correct_count}／${s.total} 題` : '尚未寫完'}</small></div>
      <span class="chev" aria-hidden="true">›</span>
    </a>`).join('');
  shell(ctx, { ...frame, body: rows ? `<div class="list">${rows}</div>` : '<div class="card center muted">還沒有作答紀錄。</div>' });
}
