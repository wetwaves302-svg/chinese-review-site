-- ============================================================
-- 技高國文複習站｜取消基礎理解測驗
-- 決定整個取消：基礎卷不再需要先完成基礎理解測驗，成績與全勤計算也不再包含它。
--   1. 三個被改寫過的函式還原為改寫前的版本
--      student_papers / student_start_paper 同 20260930000002，student_scores 同 20261001000001
--   2. 移除基礎理解測驗專用的函式（reading_* 資料表已無資料，先保留為空表）
-- 重複執行不會出錯。
-- ============================================================

-- 本課各卷狀態：題庫題數、已寫次數、最高分、未寫完的卷、是否開放；另附本課挑戰積分與歷屆加分
create or replace function public.student_papers(p_token text, p_course_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_basic_done boolean;
  v_papers jsonb;
  v_a numeric; v_b numeric; v_c numeric;
  v_past_done integer;
begin
  v_student := private.require_student(p_token);

  if not exists (select 1 from public.courses where id = p_course_id and published) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  v_basic_done := exists (
    select 1 from public.paper_sessions
    where student_id = v_student and course_id = p_course_id and paper = 'basic' and submitted_at is not null);

  select jsonb_agg(jsonb_build_object(
           'paper',        p.paper,
           'pool',         (select count(*) from public.course_questions cq
                            join public.questions q on q.id = cq.question_id
                            where cq.course_id = p_course_id and cq.paper = p.paper and q.active),
           'used',         (select count(*) from public.paper_sessions s
                            where s.student_id = v_student and s.course_id = p_course_id and s.paper = p.paper),
           'completed',    (select count(*) from public.paper_sessions s
                            where s.student_id = v_student and s.course_id = p_course_id and s.paper = p.paper
                              and s.submitted_at is not null),
           'best',         (select max(s.score) from public.paper_sessions s
                            where s.student_id = v_student and s.course_id = p_course_id and s.paper = p.paper),
           'open_session', (select s.id from public.paper_sessions s
                            where s.student_id = v_student and s.course_id = p_course_id and s.paper = p.paper
                              and s.submitted_at is null
                            order by s.started_at desc limit 1),
           'max_attempts', case when p.paper = 'past' then null else 3 end,
           'unlocked',     p.paper = 'basic' or v_basic_done)
         order by p.ord)
  into v_papers
  from (values ('basic', 1), ('advanced', 2), ('challenge', 3), ('past', 4)) as p(paper, ord);

  select max(score) filter (where paper = 'basic'),
         max(score) filter (where paper = 'advanced'),
         max(score) filter (where paper = 'challenge'),
         count(*) filter (where paper = 'past' and submitted_at is not null)
  into v_a, v_b, v_c, v_past_done
  from public.paper_sessions
  where student_id = v_student and course_id = p_course_id;

  return jsonb_build_object(
    'ok', true,
    'papers', v_papers,
    'challenge_score', case when v_a is null then null
                            else round(v_a + coalesce(v_b, 0) * 0.25 + coalesce(v_c, 0) * 0.10, 1) end,
    'past_completed', v_past_done,
    'past_bonus', case when v_past_done > 0 then 0.5 else 0 end);
end;
$$;

-- 開始或繼續作答：有未寫完的卷就回傳該卷；否則檢查開放與次數後抽題建立新卷
create or replace function public.student_start_paper(p_token text, p_course_id uuid, p_paper text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_class   uuid;
  v_open    uuid;
  v_used    integer;
  v_target  integer;
  v_max     integer;
  v_ids     uuid[];
  v_id      uuid;
begin
  v_student := private.require_student(p_token);

  if p_paper is null or p_paper not in ('basic', 'advanced', 'challenge', 'past')
     or not exists (select 1 from public.courses where id = p_course_id and published) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select id into v_open
  from public.paper_sessions
  where student_id = v_student and course_id = p_course_id and paper = p_paper and submitted_at is null
  order by started_at desc limit 1;
  if v_open is not null then
    return jsonb_build_object('ok', true, 'session_id', v_open, 'resumed', true);
  end if;

  if p_paper <> 'basic' and not exists (
    select 1 from public.paper_sessions
    where student_id = v_student and course_id = p_course_id and paper = 'basic' and submitted_at is not null) then
    return jsonb_build_object('ok', false, 'error', 'locked');
  end if;

  select count(*) into v_used
  from public.paper_sessions
  where student_id = v_student and course_id = p_course_id and paper = p_paper;
  if p_paper <> 'past' and v_used >= 3 then
    return jsonb_build_object('ok', false, 'error', 'no_attempts_left');
  end if;

  if p_paper = 'past' then
    v_target := 3 + floor(random() * 3)::integer;
    v_max := 6;
  else
    v_target := case p_paper when 'challenge' then 5 else 10 end;
    v_max := v_target;
  end if;

  v_ids := private.draw_questions(v_student, p_course_id, p_paper, v_target, v_max, p_paper <> 'past');
  if cardinality(v_ids) = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_questions');
  end if;

  select class_id into v_class from public.students where id = v_student;

  insert into public.paper_sessions (student_id, course_id, class_id, paper, attempt_no, question_ids)
  values (v_student, p_course_id, v_class, p_paper, v_used + 1, v_ids)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'session_id', v_id, 'resumed', false);
end;
$$;

-- 個人成績：寫過的各課分數與歷屆加分，以及各學期的期末加分與全勤進度
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
    past_done integer, past_term text) on commit drop;

  insert into pg_temp.my_courses
  select c.id, c.title, c.grade, c.semester_id, c.is_core14, c.position,
         max(s.score) filter (where s.paper = 'basic'),
         max(s.score) filter (where s.paper = 'advanced'),
         max(s.score) filter (where s.paper = 'challenge'),
         count(*) filter (where s.paper = 'basic'),
         count(*) filter (where s.paper = 'advanced'),
         count(*) filter (where s.paper = 'challenge'),
         count(*) filter (where s.paper = 'past'),
         private.semester_of(min(s.submitted_at) filter (where s.paper = 'past'))
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
              and m.done_basic > 0 and m.done_advanced > 0 and m.done_challenge > 0 and m.past_done > 0) as complete,
           jsonb_build_object(
             'grade', v_grade,
             'total', (select count(*) from pg_temp.my_courses m where m.grade = v_grade and m.semester_id = sem.id),
             'courses', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', m.course_id, 'title', m.title,
                        'basic', m.done_basic > 0, 'advanced', m.done_advanced > 0,
                        'challenge', m.done_challenge > 0, 'past', m.past_done > 0)
                      order by m.position, m.title)
               from pg_temp.my_courses m where m.grade = v_grade and m.semester_id = sem.id), '[]'::jsonb)) as attendance
    from public.semesters sem
    where sem.id = v_current or exists (select 1 from pg_temp.my_courses m where m.past_term = sem.id)
  ) t;

  return jsonb_build_object('ok', true, 'grade', v_grade, 'current_term', v_current,
                            'courses', v_courses, 'terms', v_terms);
end;
$$;

revoke execute on function public.student_papers(text, uuid)            from public, anon, authenticated;
revoke execute on function public.student_start_paper(text, uuid, text) from public, anon, authenticated;
revoke execute on function public.student_scores(text)                  from public, anon, authenticated;

grant execute on function public.student_papers(text, uuid)            to anon, authenticated;
grant execute on function public.student_start_paper(text, uuid, text) to anon, authenticated;
grant execute on function public.student_scores(text)                  to anon, authenticated;

drop function if exists public.student_reading(text, uuid);
drop function if exists public.student_reading_save(text, uuid, uuid, text);
drop function if exists public.student_reading_submit(text, uuid);
drop function if exists private.reading_locks_basic(uuid, uuid);
drop function if exists private.has_reading(uuid);
drop function if exists private.reading_earned(text, text, text, numeric, integer);
