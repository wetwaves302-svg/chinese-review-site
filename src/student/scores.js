import { esc } from '../lib/ui.js';
import { PAPERS } from './quiz.js';

const GRADES = ['高一', '高二', '高三'];
const MIN_FOR_CURVE = 20;
const WEAK_RATE = 0.6;   // 首次作答答對率低於 60%
const WEAK_MIN = 3;      // 且至少寫過 3 題，才標示「需要加強」

const fmt = (value) => (value == null ? '—' : Number(value).toString());

// ---------------------------------------------------------------------
// 我的成績：各學期期末加分與全勤進度、寫過的各課分數
// ---------------------------------------------------------------------

function attendanceRow(c) {
  const chip = (done, label) => `<span class="chip${done ? ' on' : ''}">${done ? '✓' : '○'} ${label}</span>`;
  return `
    <div class="att-row">
      <a href="#/course/${esc(c.id)}">${esc(c.title)}</a>
      <div class="chips">${chip(c.basic, '基礎')}${chip(c.advanced, '進階')}${chip(c.challenge, '挑戰')}${chip(c.past, '歷屆')}</div>
    </div>`;
}

function termCard(term) {
  const att = term.attendance;
  const done = att.courses.filter((c) => c.basic && c.advanced && c.challenge && c.past).length;
  const attendance = att.total
    ? `
      <div class="term-line">
        <span>學期全勤（${GRADES[att.grade - 1]}本學期 ${att.total} 課）</span>
        <b class="${term.attendance_bonus ? 'ok' : ''}">${term.attendance_bonus ? '+3 分・已達成' : `${done}／${att.total} 課`}</b>
      </div>
      <div class="bar"><i style="width:${Math.round((done / att.total) * 100)}%"></i></div>
      <p class="hint">每一課的基礎卷、進階卷、挑戰卷與歷屆試題都至少完成一次，學期總成績加 3 分。</p>
      <div class="att-list">${att.courses.map(attendanceRow).join('')}</div>`
    : `<p class="hint">${GRADES[att.grade - 1]}本學期的課程還沒有上架，全勤進度之後會顯示在這裡。</p>`;

  return `
    <section class="card term">
      <div class="term-head">
        <h2>${esc(term.name)}${term.current ? '<span class="tag">本學期</span>' : ''}</h2>
        <div class="term-total"><small>期末加分累計</small><b class="num">+${fmt(term.total_bonus)}</b><small>分</small></div>
      </div>
      <div class="term-line">
        <span>歷屆試題練習加分（每課 0.5 分）</span>
        <b>+${fmt(term.past_bonus)} 分</b>
      </div>
      ${attendance}
    </section>`;
}

function courseScoreCard(c) {
  const papers = ['basic', 'advanced', 'challenge'].map((p) => `
    <div class="sc-paper">
      <small>${PAPERS[p].name}</small>
      <b class="num">${fmt(c[p[0]])}</b>
      <small>${c.done[p] ? `寫了 ${c.done[p]} 次` : '尚未作答'}</small>
    </div>`).join('');
  return `
    <section class="card score-card">
      <div class="sc-head">
        <div>
          <div class="grade-line">${GRADES[c.grade - 1]}</div>
          <h3>${esc(c.title)}</h3>
        </div>
        <div class="challenge-score"><span>本課挑戰積分</span><b class="num">${fmt(c.challenge_score)}</b><small>／135</small></div>
      </div>
      <div class="sc-papers">${papers}</div>
      <div class="sc-past">
        歷屆試題 ${c.done.past ? `練習 ${c.done.past} 次・<b>期末總成績 +0.5 分</b>` : '尚未練習（完成一次即可加 0.5 分）'}
      </div>
      <div class="sc-links">
        <a href="#/course/${esc(c.id)}">回課程作答</a>
        <a href="#/course/${esc(c.id)}/analysis">看本課分析 ›</a>
      </div>
    </section>`;
}

export async function scoresPage(ctx, shell) {
  const frame = { back: { href: '#/', label: '首頁' }, title: '我的成績' };
  shell(ctx, { ...frame, body: '<p class="muted center">載入中…</p>' });
  let data;
  try {
    data = await ctx.call('student_scores');
  } catch (error) {
    return ctx.fail(error);
  }
  if (!ctx.isCurrent()) return;

  const courses = data.courses.length
    ? data.courses.map(courseScoreCard).join('')
    : '<div class="card center muted">還沒有完成任何一張卷。寫完基礎卷後，這裡就會出現本課挑戰積分。</div>';

  shell(ctx, {
    ...frame,
    body: `
      ${data.terms.map(termCard).join('')}
      <div class="section">
        <h3>各課成績</h3>
        <p class="hint">本課挑戰積分 ＝ 基礎卷最高分 ＋ 進階卷最高分 × 25% ＋ 挑戰卷最高分 × 10%（各卷三次取最高分）。</p>
        ${courses}
      </div>`,
  });
}

// ---------------------------------------------------------------------
// 本課分析：六大類答對率與三卷分布曲線
// ---------------------------------------------------------------------

function categoryRow(cat) {
  if (!cat.answered) {
    return `<div class="cat-row empty"><div class="cat-top"><span>${esc(cat.name)}</span><small>尚未作答</small></div></div>`;
  }
  const rate = cat.correct / cat.answered;
  const weak = rate < WEAK_RATE && cat.answered >= WEAK_MIN;
  return `
    <div class="cat-row${weak ? ' weak' : ''}">
      <div class="cat-top">
        <span>${esc(cat.name)}${weak ? '<span class="weak-tag">需要加強</span>' : ''}</span>
        <b class="num">${Math.round(rate * 100)}%</b>
      </div>
      <div class="bar"><i style="width:${Math.round(rate * 100)}%"></i></div>
      <small>答對 ${cat.correct}／${cat.answered} 題${cat.mistakes ? `・錯題重做答對 ${cat.mastered}／${cat.mistakes} 題` : ''}</small>
    </div>`;
}

// 分布曲線：x 軸 0～100 分；曲線由伺服器以核密度估計算好，每 2 分一點
function curveSvg(dist) {
  const W = 320; const H = 150; const left = 10; const right = 10; const top = 14; const bottom = 26;
  const x = (score) => left + (score / 100) * (W - left - right);
  const max = Math.max(...dist.curve);
  const y = (d) => top + (1 - d / max) * (H - top - bottom);
  const points = dist.curve.map((d, i) => `${x(i * 2).toFixed(1)},${y(d).toFixed(1)}`);
  const base = H - bottom;
  const area = `M${x(0)},${base} L${points.join(' L')} L${x(100)},${base} Z`;
  const ticks = [0, 20, 40, 60, 80, 100].map((s) => `
    <line x1="${x(s)}" y1="${base}" x2="${x(s)}" y2="${base + 4}" class="axis" />
    <text x="${x(s)}" y="${base + 16}" class="tick">${s}</text>`).join('');
  const mean = `
    <line x1="${x(dist.mean)}" y1="${top}" x2="${x(dist.mean)}" y2="${base}" class="mean" />
    <text x="${x(dist.mean)}" y="${top - 3}" class="mean-label">平均 ${fmt(dist.mean)}</text>`;
  const mine = dist.mine == null ? '' : `
    <line x1="${x(dist.mine)}" y1="${top + 8}" x2="${x(dist.mine)}" y2="${base}" class="me" />
    <circle cx="${x(dist.mine)}" cy="${base}" r="5" class="me-dot" />
    <text x="${x(dist.mine) + (dist.mine > 85 ? -6 : 6)}" y="${top + 20}" class="me-label" text-anchor="${dist.mine > 85 ? 'end' : 'start'}">你</text>`;
  return `
    <svg class="dist" viewBox="0 0 ${W} ${H}" role="img" aria-label="分數分布曲線，平均 ${fmt(dist.mean)} 分${dist.mine == null ? '' : `，你的最高分 ${fmt(dist.mine)} 分`}">
      <path d="${area}" class="area" />
      <polyline points="${points.join(' ')}" class="line" />
      <line x1="${left}" y1="${base}" x2="${W - right}" y2="${base}" class="axis" />
      ${ticks}${mean}${mine}
    </svg>`;
}

function distributionCard(dist) {
  const meta = PAPERS[dist.paper];
  const mine = dist.mine == null ? '你還沒寫完這一卷' : `你的最高分 <b class="num">${fmt(dist.mine)}</b> 分`;
  const body = dist.curve
    ? `${curveSvg(dist)}
       <div class="dist-facts">
         <span>${mine}</span>
         <span>平均 ${fmt(dist.mean)} 分</span>
         <span>完成 ${dist.count} 人</span>
         ${dist.pr == null ? '' : `<span>PR <b class="num">${dist.pr}</b></span>`}
       </div>`
    : `<p class="dist-wait">目前完成作答人數尚少，累積更多資料後將顯示整體學習位置。</p>
       <div class="dist-facts"><span>${mine}</span><span>目前完成 ${dist.count} 人</span></div>`;
  return `
    <section class="card dist-card">
      <h3>${meta.name}</h3>
      ${body}
    </section>`;
}

export async function analysisPage(ctx, shell, courseId) {
  const frame = { back: { href: `#/course/${courseId}`, label: '回課程' }, title: '本課分析' };
  shell(ctx, { ...frame, body: '<p class="muted center">載入中…</p>' });
  let data;
  try {
    data = await ctx.call('student_course_analysis', { p_course_id: courseId });
  } catch (error) {
    return ctx.fail(error);
  }
  if (!ctx.isCurrent()) return;
  if (!data.ok) {
    return shell(ctx, { ...frame, body: '<div class="card center"><p>找不到這一課，可能已經下架。</p></div>' });
  }

  const answered = data.categories.reduce((sum, c) => sum + c.answered, 0);
  const weak = data.categories.filter((c) => c.answered >= WEAK_MIN && c.correct / c.answered < WEAK_RATE);
  const allGood = data.categories.every((c) => !c.answered || c.correct / c.answered >= WEAK_RATE);
  let summary;
  if (!answered) summary = '還沒有作答紀錄。寫完基礎卷後，這裡會依六大類整理你的答對率。';
  else if (weak.length) summary = `建議先加強：${weak.map((c) => `「${esc(c.name)}」`).join('、')}。可以到錯題本重做這些題目。`;
  else if (allGood) summary = '目前各類都在六成以上，繼續保持！';
  else summary = `有些類別目前寫過的題數還少（未滿 ${WEAK_MIN} 題），多寫幾卷後，分析會更準確。`;

  shell(ctx, {
    back: { href: `#/course/${courseId}`, label: data.course.title },
    title: '本課分析',
    body: `
      <div class="lesson-head">
        <div class="grade-line">${GRADES[data.course.grade - 1]}</div>
        <h2>${esc(data.course.title)}・本課分析</h2>
      </div>
      <section class="card">
        <h2>六大類答對率</h2>
        <p class="hint">以每一題第一次作答計算（含歷屆試題）；錯題重做只影響掌握度，不改變答對率。</p>
        <div class="cats">${data.categories.map(categoryRow).join('')}</div>
        <p class="cat-summary">${summary}</p>
        <a class="btn ghost" href="#/course/${esc(courseId)}/mistakes">到錯題本重做</a>
      </section>
      <div class="section">
        <h3>整體學習位置（各卷以每位同學三次中的最高分計算）</h3>
        <p class="hint">只顯示曲線、平均、完成人數與你自己的位置，看不到其他同學的成績。</p>
        <div class="dist-grid">${data.papers.map(distributionCard).join('')}</div>
      </div>`,
  });
}
