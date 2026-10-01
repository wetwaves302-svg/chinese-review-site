import { isSessionError } from '../lib/supabase.js';
import { esc } from '../lib/ui.js';

// 基礎理解測驗：一頁一個題組；交卷前可修改，交卷後才顯示答案與解析（只能交卷一次）
const LETTERS = ['A', 'B', 'C', 'D', 'E', 'F'];
const fmt = (value) => Number(value).toString();

// 同一位學生在同一課換頁時不重抓（存答案時會同步更新這份資料）
let cached = null;

async function loadReading(ctx, courseId) {
  const owner = `${ctx.student.id}:${courseId}`;
  if (cached?.owner === owner) return cached.data;
  const data = await ctx.call('student_reading', { p_course_id: courseId });
  cached = data.ok ? { owner, data } : null;
  return data;
}

const isAnswered = (item) => Boolean(item.answer);
const blockDone = (block) => block.items.every(isAnswered);

function progressBar(courseId, data, current) {
  const dots = data.blocks.map((b, i) => {
    let state = blockDone(b) ? 'answered' : '';
    if (data.submitted) {
      const earned = b.items.reduce((sum, item) => sum + Number(item.earned), 0);
      const points = b.items.reduce((sum, item) => sum + Number(item.points), 0);
      state = earned === points ? 'right' : 'wrong';
    }
    return `<a class="dot ${state}${i === current ? ' now' : ''}" href="#/course/${esc(courseId)}/reading/${i + 1}"
      aria-label="第 ${i + 1} 頁">${i + 1}</a>`;
  }).join('');
  const items = data.blocks.flatMap((b) => b.items);
  const answered = items.filter(isAnswered).length;
  return `
    <div class="q-progress">
      <div class="dots">${dots}</div>
      <div class="q-count">${data.submitted ? `得分 ${fmt(data.score)} 分` : `已作答 ${answered}／${items.length} 項`}</div>
    </div>`;
}

// 複選題提示共有幾個答案（交卷前不透露是哪幾個）
function multiTag(item) {
  return `<span class="tag">複選${item.answer_count ? `・共 ${item.answer_count} 個答案` : ''}</span>`;
}

function optionLabel(item, i) {
  return item.kind === 'select' ? `(${LETTERS[i]}) ${item.options[i]}` : item.options[i];
}

function verdict(item) {
  const earned = Number(item.earned);
  const points = Number(item.points);
  const state = earned === points ? 'right' : earned > 0 ? 'part' : 'wrong';
  const text = { right: '✓ 答對', part: '△ 部分答對', wrong: '✕ 這題要再留意' }[state];
  const key = item.key.split('').map((l) => `(${l})`).join('');
  return `
    <div class="r-verdict ${state}">${text}<span>得 ${fmt(earned)}／${fmt(points)} 分・正確答案 ${key}</span></div>
    <p class="r-explain">${esc(item.explanation)}</p>`;
}

function itemBody(item, n, submitted) {
  const chosen = item.answer ?? '';
  let control;
  if (item.kind === 'select') {
    const options = item.options.map((_, i) => `<option value="${LETTERS[i]}"${chosen === LETTERS[i] ? ' selected' : ''}>${esc(optionLabel(item, i))}</option>`).join('');
    control = `
      <select class="r-select" data-item="${esc(item.id)}" ${submitted ? 'disabled' : ''}>
        <option value="">請選擇</option>${options}
      </select>`;
  } else {
    const multi = item.kind === 'multi';
    control = `<div class="options${multi ? ' multi' : ''}">${item.options.map((text, i) => {
      const letter = LETTERS[i];
      const classes = ['opt'];
      if (chosen.includes(letter)) classes.push('chosen');
      if (submitted && item.key.includes(letter)) classes.push(multi && !chosen.includes(letter) ? 'right missed' : 'right');
      if (submitted && chosen.includes(letter) && !item.key.includes(letter)) classes.push('wrong');
      return `<button type="button" class="${classes.join(' ')}" role="${multi ? 'checkbox' : 'radio'}"
        aria-checked="${chosen.includes(letter)}" data-item="${esc(item.id)}" data-letter="${letter}" ${submitted ? 'disabled' : ''}>
        <span class="box" aria-hidden="true"></span><span class="k">(${letter})</span><span>${esc(text)}</span></button>`;
    }).join('')}</div>`;
  }
  return `
    <div class="r-item">
      ${item.quote ? `<blockquote class="r-quote">${esc(item.quote)}</blockquote>` : ''}
      ${item.label || n ? `<p class="r-label">${n ? `(${n}) ` : ''}${esc(item.label)}${item.kind === 'multi' ? multiTag(item) : ''}</p>` : ''}
      ${!item.label && !n && item.kind === 'multi' ? `<p class="r-label">${multiTag(item)}</p>` : ''}
      ${control}
      ${submitted ? verdict(item) : ''}
    </div>`;
}

export async function readingPage(ctx, shell, courseId, indexParam) {
  const frame = { back: { href: `#/course/${courseId}`, label: '回課程' }, title: '基礎理解測驗' };
  shell(ctx, { ...frame, body: '<p class="muted center">載入中…</p>' });
  let data;
  try {
    data = await loadReading(ctx, courseId);
  } catch (error) {
    return ctx.fail(error);
  }
  if (!ctx.isCurrent()) return;
  if (!data.ok) return shell(ctx, { ...frame, body: '<div class="card center"><p>這一課沒有基礎理解測驗。</p></div>' });

  const base = `#/course/${courseId}/reading`;
  if (indexParam === 'submit') return submitPage(ctx, shell, courseId, data);
  let index = indexParam ? Number(indexParam) - 1 : null;
  if (index == null || !(index >= 0 && index < data.blocks.length)) {
    if (data.submitted) return resultPage(ctx, shell, courseId, data);
    index = Math.max(data.blocks.findIndex((b) => !blockDone(b)), 0);
    history.replaceState(null, '', `${base}/${index + 1}`);
  }

  const block = data.blocks[index];
  const numbered = block.items.length > 1;
  const prev = index > 0 ? `${base}/${index}` : null;
  const next = index < data.blocks.length - 1 ? `${base}/${index + 2}` : null;
  const last = data.submitted ? `<a class="btn" href="${base}">看成績 ›</a>` : `<a class="btn" href="${base}/submit">準備交卷 ›</a>`;

  shell(ctx, {
    back: { href: `#/course/${courseId}`, label: data.course.title },
    title: '基礎理解測驗',
    body: `
      ${progressBar(courseId, data, index)}
      <div class="card question reading">
        <div class="q-meta">${esc(block.section)}</div>
        <p class="q-stem">${esc(block.title)}</p>
        ${block.context ? `<blockquote class="r-quote">${esc(block.context)}</blockquote>` : ''}
        ${block.items.map((item, i) => itemBody(item, numbered ? i + 1 : 0, data.submitted)).join('')}
        ${data.submitted ? '' : '<p class="hint center" data-save-state>選好就會自動儲存，交卷前都可以修改。</p>'}
      </div>
      <div class="q-foot">
        ${prev ? `<a class="btn ghost" href="${prev}">‹ 上一頁</a>` : '<span></span>'}
        ${next ? `<a class="btn" href="${next}">下一頁 ›</a>` : last}
      </div>`,
  });
  if (!data.submitted) bindInputs(ctx, shell, courseId, data, index);
}

function bindInputs(ctx, shell, courseId, data, index) {
  const items = new Map(data.blocks[index].items.map((item) => [item.id, item]));
  const state = ctx.app.querySelector('[data-save-state]');

  // 畫面先更新；送出依序排隊，避免連續點選時回應順序錯亂
  let queue = Promise.resolve();
  const save = (item, answer) => {
    const before = item.answer;
    item.answer = answer || null;
    paint(item);
    state.textContent = '儲存中…';
    queue = queue.then(() => send(item, answer, before));
  };
  const send = async (item, answer, before) => {
    try {
      const res = await ctx.call('student_reading_save', { p_course_id: courseId, p_item_id: item.id, p_answer: answer });
      if (!ctx.isCurrent()) return;
      if (!res.ok) {
        item.answer = before;
        paint(item);
        if (res.error === 'submitted') { cached = null; return readingPage(ctx, shell, courseId); }
        state.textContent = '無法儲存，請再選一次。';
        return;
      }
      state.textContent = '✓ 已儲存';
      ctx.app.querySelector('.q-progress').outerHTML = progressBar(courseId, data, index);
    } catch (error) {
      if (isSessionError(error)) return ctx.fail(error);
      item.answer = before;
      paint(item);
      state.textContent = '連線失敗，請再選一次。';
    }
  };

  const paint = (item) => {
    for (const button of ctx.app.querySelectorAll(`button[data-item="${item.id}"]`)) {
      const on = (item.answer ?? '').includes(button.dataset.letter);
      button.classList.toggle('chosen', on);
      button.setAttribute('aria-checked', String(on));
    }
    const select = ctx.app.querySelector(`select[data-item="${item.id}"]`);
    if (select) select.value = item.answer ?? '';
  };

  for (const button of ctx.app.querySelectorAll('button[data-item]')) {
    button.addEventListener('click', () => {
      const item = items.get(button.dataset.item);
      const letter = button.dataset.letter;
      const current = item.answer ?? '';
      let answer = letter;
      if (item.kind === 'multi') {
        answer = current.includes(letter) ? current.replace(letter, '') : current + letter;
        answer = answer.split('').sort().join('');
      }
      save(item, answer);
    });
  }
  for (const select of ctx.app.querySelectorAll('select[data-item]')) {
    select.addEventListener('change', () => save(items.get(select.dataset.item), select.value));
  }
}

function submitPage(ctx, shell, courseId, data) {
  const base = `#/course/${courseId}/reading`;
  if (data.submitted) return resultPage(ctx, shell, courseId, data);
  const missing = data.blocks
    .map((b, i) => ({ n: i + 1, left: b.items.filter((item) => !isAnswered(item)).length }))
    .filter((b) => b.left);
  const items = data.blocks.flatMap((b) => b.items);
  const answered = items.filter(isAnswered).length;
  const list = missing.length
    ? `<p>還有 ${items.length - answered} 項沒有作答，未作答的項目以 0 分計算：</p>
       <div class="dots">${missing.map((b) => `<a class="dot" href="${base}/${b.n}" aria-label="第 ${b.n} 頁">${b.n}</a>`).join('')}</div>`
    : '<p>全部項目都已作答。</p>';

  shell(ctx, {
    back: { href: `${base}/${data.blocks.length}`, label: '回到題目' },
    title: '基礎理解測驗・交卷',
    body: `
      <div class="card">
        <h2>確認交卷</h2>
        ${list}
        <p class="hint">基礎理解測驗只能交卷一次，交卷後不能再修改答案，並會立刻顯示分數、正確答案與解析。交卷後就會開放基礎卷。</p>
        <button class="btn" type="button" data-submit>確定交卷</button>
        <p class="hint" data-submit-error></p>
      </div>`,
  });

  const button = ctx.app.querySelector('[data-submit]');
  button.addEventListener('click', async () => {
    button.disabled = true;
    try {
      const res = await ctx.call('student_reading_submit', { p_course_id: courseId });
      if (!res.ok) throw new Error(res.error);
      cached = null;
      location.hash = base;
    } catch (error) {
      if (isSessionError(error)) return ctx.fail(error);
      ctx.app.querySelector('[data-submit-error]').textContent = '交卷失敗，請再試一次。';
      button.disabled = false;
    }
  });
}

function resultPage(ctx, shell, courseId, data) {
  const base = `#/course/${courseId}/reading`;
  const rows = data.blocks.map((b, i) => {
    const earned = b.items.reduce((sum, item) => sum + Number(item.earned), 0);
    const points = b.items.reduce((sum, item) => sum + Number(item.points), 0);
    const mark = earned === points ? 'right' : 'wrong';
    return `
      <a class="item" href="${base}/${i + 1}">
        <span class="mark ${mark}">${earned === points ? '✓' : '✕'}</span>
        <div class="txt">第 ${i + 1} 頁・${esc(b.section)}<small>${esc(b.title.length > 34 ? `${b.title.slice(0, 34)}…` : b.title)}</small></div>
        <span class="r-points">${fmt(earned)}／${fmt(points)}</span>
      </a>`;
  }).join('');

  shell(ctx, {
    back: { href: `#/course/${courseId}`, label: data.course.title },
    title: '基礎理解測驗・成績',
    body: `
      <div class="card center result-card">
        <div class="big-score"><b class="num">${fmt(data.score)}</b> 分</div>
        <p class="hint center">原學習單配分 ${fmt(data.total_points)} 分，換算成滿分 100 分。這個分數獨立計算，不列入本課挑戰積分。</p>
      </div>
      <div class="section"><h3>逐頁檢討（點進去看答案與解析）</h3><div class="list">${rows}</div></div>
      <div class="section"><a class="btn" href="#/course/${esc(courseId)}">回課程寫基礎卷</a></div>`,
  });
}
