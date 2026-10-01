-- =====================================================================
-- 技高國文複習站｜第六步：個人成績頁、本課分析、分布曲線
-- 國立花蓮高工｜貞伊老師製作
--
--   規則見 CLAUDE.md「計分」「歷屆試題」「學生個人成績頁」「分類與分析」：
--   本課挑戰積分 ＝ A ＋ B × 25% ＋ C × 10%（各卷三次中的最高分）
--   歷屆試題：每課完成至少一次練習，期末總成績加 0.5 分；計入第一次完成時所在的學期
--             （1 月 21 日起寒假作答計入 115-2）
--   學期全勤：完成自己年級當學期所有課程的三卷與歷屆試題，學期總成績加 3 分
--   本課分析：只以六大類計算首次作答答對率
--   分布曲線：按卷分開，以每位學生該卷最高分計算；完成人數未滿 20 人時不回傳曲線、平均與 PR，
--             學生只拿得到曲線、平均、人數與自己的位置，拿不到任何他人的分數
-- =====================================================================

-- 某個時間點屬於哪個學期（以台灣日期判定）
create or replace function private.semester_of(p_at timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select s.id
  from public.semesters s
  where (p_at at time zone 'Asia/Taipei')::date >= s.starts_on
    and (s.ends_on is null or (p_at at time zone 'Asia/Taipei')::date <= s.ends_on)
  order by s.starts_on desc
  limit 1;
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

-- 一卷的分布：每位學生該卷最高分；滿 20 人才回傳核密度曲線（0～100 分每 2 分一點）與 PR
create or replace function private.paper_distribution(p_course uuid, p_paper text, p_student uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_n      integer;
  v_mean   numeric;
  v_sd     numeric;
  v_mine   numeric;
  v_h      numeric;
  v_curve  jsonb;
  v_pr     integer;
begin
  drop table if exists pg_temp.best_scores;
  create temporary table pg_temp.best_scores (student_id uuid, score numeric) on commit drop;
  insert into pg_temp.best_scores
  select s.student_id, max(s.score)
  from public.paper_sessions s
  join public.students st on st.id = s.student_id and st.active
  where s.course_id = p_course and s.paper = p_paper and s.submitted_at is not null and s.score is not null
  group by s.student_id;

  select count(*), avg(score), stddev_samp(score) into v_n, v_mean, v_sd from pg_temp.best_scores;
  select score into v_mine from pg_temp.best_scores where student_id = p_student;

  if v_n >= 20 then
    -- Silverman 帶寬；分數集中時給最小 4 分，避免曲線過尖
    v_h := greatest(1.06 * coalesce(v_sd, 0) * power(v_n, -0.2), 4);
    select jsonb_agg(round(d.density::numeric, 6) order by d.x)
    into v_curve
    from (
      select x.x, sum(exp(-0.5 * power((x.x - b.score) / v_h, 2))) / (v_n * v_h * sqrt(2 * pi())) as density
      from generate_series(0, 100, 2) as x(x)
      cross join pg_temp.best_scores b
      group by x.x
    ) d;
    if v_mine is not null then
      select least(99, floor(100 * (count(*) filter (where score < v_mine)
                                     + 0.5 * count(*) filter (where score = v_mine)) / v_n))::integer
      into v_pr from pg_temp.best_scores;
    end if;
  end if;

  return jsonb_build_object(
    'paper', p_paper,
    'count', v_n,
    'mean', case when v_n >= 20 then round(v_mean, 1) end,
    'mine', v_mine,
    'pr', v_pr,
    'curve', v_curve);
end;
$$;

-- 本課分析：六大類首次作答答對率、錯題重做答對數，以及三卷的分布
create or replace function public.student_course_analysis(p_token text, p_course_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
begin
  v_student := private.require_student(p_token);

  if not exists (select 1 from public.courses where id = p_course_id and published) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'course', (select jsonb_build_object('id', c.id, 'title', c.title, 'grade', c.grade)
               from public.courses c where c.id = p_course_id),
    'categories', (
      select jsonb_agg(jsonb_build_object(
               'code', qc.code, 'name', qc.name,
               'answered', coalesce(a.answered, 0),
               'correct', coalesce(a.correct, 0),
               'mistakes', coalesce(a.answered - a.correct, 0),
               'mastered', coalesce(a.mastered, 0))
             order by qc.position)
      from public.question_categories qc
      left join (
        select category_code,
               count(*) as answered,
               count(*) filter (where first_correct) as correct,
               count(*) filter (where not first_correct and retry_correct) as mastered
        from public.attempts
        where student_id = v_student and course_id = p_course_id
        group by category_code
      ) a on a.category_code = qc.code),
    'papers', jsonb_build_array(
      private.paper_distribution(p_course_id, 'basic', v_student),
      private.paper_distribution(p_course_id, 'advanced', v_student),
      private.paper_distribution(p_course_id, 'challenge', v_student)));
end;
$$;

-- 權限：先全部收回，再逐一授權
revoke execute on function private.semester_of(timestamptz)                    from public, anon, authenticated;
revoke execute on function private.paper_distribution(uuid, text, uuid)        from public, anon, authenticated;
revoke execute on function public.student_scores(text)                         from public, anon, authenticated;
revoke execute on function public.student_course_analysis(text, uuid)          from public, anon, authenticated;

grant execute on function public.student_scores(text)                to anon, authenticated;
grant execute on function public.student_course_analysis(text, uuid) to anon, authenticated;
