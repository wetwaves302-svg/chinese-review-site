-- =====================================================================
-- 技高國文複習站｜沒有歷屆題的課，學期全勤只看三卷（2026-11-22 貞伊老師決定）
--   〈便利商店〉的學習講義沒有「統測怎麼考」，題庫沒有歷屆題；原本全勤要求每課歷屆至少完成一次，
--   會讓該年級整學期都拿不到全勤。改為：該課題庫有歷屆題才要求完成歷屆。
--   student_scores 的全勤課程清單多回傳 has_past，前端據此不顯示「歷屆」標記。
--   另確保教師帳號可讀 course_questions（教師統計用來判斷各課有沒有歷屆題；仍受 RLS 限制只有教師可讀）。
--   只重新定義一個函式與補一項讀取權限，不動任何資料；重複執行不會出錯。
-- =====================================================================

grant select on public.course_questions to authenticated;

create or replace function public.student_scores(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_grade   smallint;
  v_current text;
  v_courses jsonb;
  v_terms   jsonb;
begin
  v_student := private.require_student(p_token);
  select k.grade into v_grade
  from public.students s join public.classes k on k.id = s.class_id
  where s.id = v_student;
  v_current := private.semester_of(now());

  -- 每課一列：三卷最高分、完成次數、歷屆練習次數與第一次完成的學期
  drop table if exists pg_temp.my_courses;
  create temporary table pg_temp.my_courses (
    course_id uuid, title text, grade smallint, semester_id text, is_core14 boolean, position integer,
    a numeric, b numeric, c numeric, done_basic integer, done_advanced integer, done_challenge integer,
    past_done integer, past_term text, has_past boolean) on commit drop;

  insert into pg_temp.my_courses
  select c.id, c.title, c.grade, c.semester_id, c.is_core14, c.position,
         max(s.score) filter (where s.paper = 'basic'),
         max(s.score) filter (where s.paper = 'advanced'),
         max(s.score) filter (where s.paper = 'challenge'),
         count(*) filter (where s.paper = 'basic'),
         count(*) filter (where s.paper = 'advanced'),
         count(*) filter (where s.paper = 'challenge'),
         count(*) filter (where s.paper = 'past'),
         private.semester_of(min(s.submitted_at) filter (where s.paper = 'past')),
         exists (select 1 from public.course_questions q where q.course_id = c.id and q.paper = 'past')
  from public.courses c
  left join public.paper_sessions s
    on s.course_id = c.id and s.student_id = v_student and s.submitted_at is not null
  where c.published
  group by c.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.course_id, 'title', m.title, 'grade', m.grade, 'semester_id', m.semester_id,
           'is_core14', m.is_core14,
           'a', m.a, 'b', m.b, 'c', m.c,
           'done', jsonb_build_object('basic', m.done_basic, 'advanced', m.done_advanced,
                                      'challenge', m.done_challenge, 'past', m.past_done),
           'challenge_score', case when m.a is null then null
                                   else round(m.a + coalesce(m.b, 0) * 0.25 + coalesce(m.c, 0) * 0.10, 1) end,
           'past_bonus', case when m.past_done > 0 then 0.5 else 0 end,
           'past_term', m.past_term)
         order by m.grade, m.position, m.title), '[]'::jsonb)
  into v_courses
  from pg_temp.my_courses m
  where m.done_basic + m.done_advanced + m.done_challenge + m.past_done > 0;

  -- 學期：目前學期，加上有歷屆加分的學期；全勤以自己年級、該學期上架的課程判定
  -- 沒有歷屆題的課（has_past = false）只看三卷
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'name', t.name, 'current', t.id = v_current,
           'past_bonus', t.past_bonus,
           'attendance', t.attendance,
           'attendance_bonus', case when t.total > 0 and t.total = t.complete then 3 else 0 end,
           'total_bonus', t.past_bonus + case when t.total > 0 and t.total = t.complete then 3 else 0 end)
         order by t.starts_on desc), '[]'::jsonb)
  into v_terms
  from (
    select sem.id, sem.name, sem.starts_on,
           (select count(*) * 0.5 from pg_temp.my_courses m where m.past_term = sem.id) as past_bonus,
           (select count(*) from pg_temp.my_courses m where m.grade = v_grade and m.semester_id = sem.id) as total,
           (select count(*) from pg_temp.my_courses m where m.grade = v_grade and m.semester_id = sem.id
              and m.done_basic > 0 and m.done_advanced > 0 and m.done_challenge > 0
              and (m.past_done > 0 or not m.has_past)) as complete,
           jsonb_build_object(
             'grade', v_grade,
             'total', (select count(*) from pg_temp.my_courses m where m.grade = v_grade and m.semester_id = sem.id),
             'courses', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', m.course_id, 'title', m.title,
                        'basic', m.done_basic > 0, 'advanced', m.done_advanced > 0,
                        'challenge', m.done_challenge > 0, 'past', m.past_done > 0,
                        'has_past', m.has_past)
                      order by m.position, m.title)
               from pg_temp.my_courses m where m.grade = v_grade and m.semester_id = sem.id), '[]'::jsonb)) as attendance
    from public.semesters sem
    where sem.id = v_current or exists (select 1 from pg_temp.my_courses m where m.past_term = sem.id)
  ) t;

  return jsonb_build_object('ok', true, 'grade', v_grade, 'current_term', v_current,
                            'courses', v_courses, 'terms', v_terms);
end;
$$;

-- 檢查：列出沒有歷屆題的已上架課程（全勤只看三卷）
select c.grade as 年級, c.title as 沒有歷屆題的課程
from public.courses c
where c.published
  and not exists (select 1 from public.course_questions q where q.course_id = c.id and q.paper = 'past')
order by c.grade, c.position;
