// 教師統計的計算（不碰畫面與資料庫，規則與學生端 student_scores 相同）
//   本課挑戰積分 ＝ 基礎卷最高分 ＋ 進階卷最高分 × 25% ＋ 挑戰卷最高分 × 10%
//   歷屆練習加分：每課完成至少一次得 0.5 分，計入第一次完成時所在的學期
//   學期全勤：自己年級、該學期上架的課程，三卷與歷屆都至少完成一次，加 3 分

export const TEST_NAME = '測試帳號';
export const PAPER_KEYS = ['basic', 'advanced', 'challenge'];

const round1 = (value) => Math.round(value * 10) / 10;
const taipeiDate = (iso) => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Taipei' }).format(new Date(iso));

export function semesterOf(iso, semesters) {
  const day = taipeiDate(iso);
  return [...semesters].reverse().find((t) => t.starts_on <= day && (!t.ends_on || day <= t.ends_on))?.id ?? null;
}

// 每位學生每一課的紀錄：{ studentId: { courseId: record } }
export function buildRecords({ sessions, semesters }) {
  const records = {};
  const record = (studentId, courseId) => {
    records[studentId] ??= {};
    records[studentId][courseId] ??= {
      best: { basic: null, advanced: null, challenge: null },
      done: { basic: 0, advanced: 0, challenge: 0, past: 0 },
      firstPast: null,
    };
    return records[studentId][courseId];
  };
  for (const s of sessions) {
    const r = record(s.student_id, s.course_id);
    r.done[s.paper] += 1;
    if (s.paper === 'past') {
      if (!r.firstPast || s.submitted_at < r.firstPast) r.firstPast = s.submitted_at;
    } else if (s.score != null && (r.best[s.paper] == null || Number(s.score) > r.best[s.paper])) {
      r.best[s.paper] = Number(s.score);
    }
  }
  for (const byCourse of Object.values(records)) {
    for (const r of Object.values(byCourse)) {
      r.challengeScore = r.best.basic == null ? null
        : round1(r.best.basic + (r.best.advanced ?? 0) * 0.25 + (r.best.challenge ?? 0) * 0.10);
      r.pastTerm = r.firstPast ? semesterOf(r.firstPast, semesters) : null;
    }
  }
  return records;
}

export function courseComplete(record) {
  return Boolean(record)
    && record.done.basic > 0 && record.done.advanced > 0 && record.done.challenge > 0 && record.done.past > 0;
}

// 一位學生在某學期的期末加分
export function studentBonus(studentRecords, { grade, termId, courses }) {
  const required = courses.filter((c) => c.grade === grade && c.semester_id === termId);
  const complete = required.filter((c) => courseComplete(studentRecords?.[c.id])).length;
  const pastCourses = Object.values(studentRecords ?? {}).filter((r) => r.pastTerm === termId).length;
  const past = pastCourses * 0.5;
  const attendance = required.length > 0 && complete === required.length ? 3 : 0;
  return { required: required.length, complete, pastCourses, past, attendance, total: past + attendance };
}

// 一個班級要顯示的課程：該年級當學期的課程，加上班上學生寫過的其他課程
export function classCourses({ students, records, courses, grade, termId }) {
  const touched = new Set(students.flatMap((s) => Object.keys(records[s.id] ?? {})));
  return courses.filter((c) => (c.grade === grade && c.semester_id === termId) || touched.has(c.id));
}

// 完成人數與平均（只算有分數的學生）
export function summarize(values) {
  const list = values.filter((v) => v != null);
  return { count: list.length, mean: list.length ? round1(list.reduce((a, b) => a + b, 0) / list.length) : null };
}

// 匯出總檔的列（第一列為標題）；每位學生一列，課程依年級、排序展開
export function exportRows({ classes, students, records, courses, termId }) {
  const classById = new Map(classes.map((k) => [k.id, k]));
  const grades = new Set(students.map((s) => classById.get(s.class_id).grade));
  const used = courses.filter((c) => students.some((s) => records[s.id]?.[c.id])
    || (c.semester_id === termId && grades.has(c.grade)));
  const header = ['班級', '座號', '名稱'];
  for (const c of used) {
    const t = `〈${c.title}〉`;
    header.push(`${t}基礎卷最高分`, `${t}進階卷最高分`, `${t}挑戰卷最高分`, `${t}本課挑戰積分`, `${t}歷屆練習次數`, `${t}歷屆加分`);
  }
  header.push('歷屆練習加分合計', '全勤應完成課數', '全勤已完成課數', '學期全勤加分', '期末加分合計');

  const rows = [header];
  for (const s of students) {
    const k = classById.get(s.class_id);
    const mine = records[s.id] ?? {};
    const row = [k.name, s.seat, s.display_name ?? ''];
    for (const c of used) {
      const r = mine[c.id];
      row.push(r?.best.basic ?? '', r?.best.advanced ?? '', r?.best.challenge ?? '', r?.challengeScore ?? '',
        r?.done.past ?? 0, r?.pastTerm === termId ? 0.5 : 0);
    }
    const bonus = studentBonus(mine, { grade: k.grade, termId, courses });
    row.push(bonus.past, bonus.required, bonus.complete, bonus.attendance, bonus.total);
    rows.push(row);
  }
  return rows;
}

// CSV（含 BOM，Excel 可直接開啟）
export function toCsv(rows) {
  const cell = (value) => {
    const text = String(value ?? '');
    return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
  };
  return `﻿${rows.map((row) => row.map(cell).join(',')).join('\r\n')}\r\n`;
}
