-- =====================================================================
-- 技高國文複習站｜第五步：三卷與歷屆試題作答
-- 國立花蓮高工｜貞伊老師製作
--
--   paper_sessions：每次作答一張卷，記下抽到的題目；基礎、進階、挑戰卷各最多三次，
--                   歷屆試題不限次數；未寫完的卷下次回來繼續寫，不重新抽題
--   session_answers：卷內每題的作答，選了就不能改
--   attempts（第一步已有）：每位學生每題第一次作答，供錯題本與分類分析使用
--   規則見 CLAUDE.md 第五節：須先完成基礎卷才開放進階卷、挑戰卷與歷屆試題；
--   基礎、進階卷 10 題每題 10 分，挑戰卷 5 題每題 20 分；歷屆試題每次 3～5 題，
--   題組總數不超過 6 題，只供練習不計分
-- =====================================================================

create table if not exists public.paper_sessions (
  id            uuid primary key default gen_random_uuid(),
  student_id    uuid not null references public.students(id) on delete cascade,
  course_id     uuid not null references public.courses(id) on delete restrict,
  class_id      uuid not null references public.classes(id),
  paper         text not null check (paper in ('basic', 'advanced', 'challenge', 'past')),
  attempt_no    smallint not null check (attempt_no >= 1),
  question_ids  uuid[] not null check (cardinality(question_ids) > 0),
  started_at    timestamptz not null default now(),
  submitted_at  timestamptz,
  correct_count smallint,
  score         numeric(5, 1),
  unique (student_id, course_id, paper, attempt_no)
);
comment on table public.paper_sessions is '每次作答一張卷；未寫完的卷下次回來繼續寫。score 為該卷得分（歷屆試題為 null，不計分）。';
create index if not exists paper_sessions_course_paper_idx on public.paper_sessions (course_id, paper);
create index if not exists paper_sessions_student_idx on public.paper_sessions (student_id, course_id);

create table if not exists public.session_answers (
  session_id  uuid not null references public.paper_sessions(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete restrict,
  answer      char(1) not null check (answer in ('A', 'B', 'C', 'D')),
  correct     boolean not null,
  answered_at timestamptz not null default now(),
  primary key (session_id, question_id)
);
comment on table public.session_answers is '卷內每題的作答，寫入後不修改。';

alter table public.paper_sessions enable row level security;
alter table public.session_answers enable row level security;
drop policy if exists teacher_read on public.paper_sessions;
drop policy if exists teacher_read on public.session_answers;
create policy teacher_read on public.paper_sessions for select to authenticated using (public.is_teacher());
create policy teacher_read on public.session_answers for select to authenticated using (public.is_teacher());
revoke all on public.paper_sessions from anon;
revoke all on public.session_answers from anon;

-- ---------------------------------------------------------------------
-- 抽題：題組整組抽出；優先抽該生沒寫過的題目
--   p_target：想抽的題數；p_max：題數上限（題組不得使總數超過）
--   p_exact：是否必須剛好 p_target 題（計分卷為 true，最多重試 30 次）
-- ---------------------------------------------------------------------
create or replace function private.draw_questions(
  p_student uuid, p_course uuid, p_paper text, p_target integer, p_max integer, p_exact boolean)
returns uuid[]
language plpgsql
set search_path = ''
as $$
declare
  v_best   uuid[] := '{}';
  v_ids    uuid[];
  v_unit   record;
  v_try    integer;
begin
  for v_try in 1 .. case when p_exact then 30 else 1 end loop
    v_ids := '{}';
    for v_unit in
      select u.ids
      from (
        select array_agg(cq.question_id order by cq.position) as ids,
               bool_or(exists (select 1 from public.attempts a
                               where a.student_id = p_student and a.question_id = cq.question_id)) as seen
        from public.course_questions cq
        join public.questions q on q.id = cq.question_id
        where cq.course_id = p_course and cq.paper = p_paper and q.active
        group by coalesce(q.group_id, cq.question_id)
      ) u
      order by u.seen, random()
    loop
      exit when cardinality(v_ids) >= p_target;
      if cardinality(v_ids) + cardinality(v_unit.ids) <= p_max then
        v_ids := v_ids || v_unit.ids;
      end if;
    end loop;

    if cardinality(v_ids) > cardinality(v_best) then
      v_best := v_ids;
    end if;
    exit when cardinality(v_best) = p_target;
  end loop;
  return v_best;
end;
$$;

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

-- 單題已作答後的結果：答案、四選項解析、貞伊老師提醒、補救入口
create or replace function private.answer_result(p_question_id uuid, p_answer char(1), p_correct boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'answer',       p_answer,
    'correct',      p_correct,
    'key',          k.answer,
    'explains',     jsonb_build_array(k.explain_a, k.explain_b, k.explain_c, k.explain_d),
    'teacher_note', k.teacher_note,
    'review_video', case when v.id is not null then jsonb_build_object(
                      'id', v.id, 'course_id', v.course_id, 'title', v.title,
                      'timestamp', q.review_video_timestamp) end,
    'review_material', case when m.id is not null then jsonb_build_object(
                      'id', m.id, 'course_id', m.course_id, 'title', m.title,
                      'page', q.review_material_page) end)
  from public.questions q
  join public.question_keys k on k.question_id = q.id
  left join public.course_videos v on v.id = q.review_video_id
  left join public.course_materials m on m.id = q.review_material_id
  where q.id = p_question_id;
$$;

-- 讀取一張卷：題目、題組文章、原圖；已作答的題目附結果，未作答的不含答案
create or replace function public.student_paper_session(p_token text, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_session public.paper_sessions%rowtype;
begin
  v_student := private.require_student(p_token);

  select * into v_session from public.paper_sessions
  where id = p_session_id and student_id = v_student;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'session', jsonb_build_object(
      'id',            v_session.id,
      'course_id',     v_session.course_id,
      'course_title',  (select title from public.courses where id = v_session.course_id),
      'paper',         v_session.paper,
      'attempt_no',    v_session.attempt_no,
      'submitted',     v_session.submitted_at is not null,
      'correct_count', v_session.correct_count,
      'score',         v_session.score),
    'questions', (
      select jsonb_agg(jsonb_build_object(
               'id',       q.id,
               'stem',     q.stem,
               'options',  jsonb_build_array(q.option_a, q.option_b, q.option_c, q.option_d),
               'group_id', q.group_id,
               'past_year',   q.past_year,
               'past_exam',   q.past_exam,
               'past_number', q.past_number,
               'image',    case when i.question_id is not null
                                then 'data:' || i.mime_type || ';base64,' || i.data_base64 end,
               'result',   case when a.question_id is not null
                                then private.answer_result(q.id, a.answer, a.correct) end)
             order by t.ord)
      from unnest(v_session.question_ids) with ordinality as t(question_id, ord)
      join public.questions q on q.id = t.question_id
      left join public.question_images i on i.question_id = q.id
      left join public.session_answers a on a.session_id = v_session.id and a.question_id = q.id),
    'groups', coalesce((
      select jsonb_object_agg(g.id::text, jsonb_build_object('title', g.title, 'source', g.source, 'passage', g.passage))
      from public.question_groups g
      where g.id in (select q.group_id from public.questions q where q.id = any(v_session.question_ids))), '{}'::jsonb));
end;
$$;

-- 作答一題：選了就不能改；寫完最後一題即交卷並計分
create or replace function public.student_answer(p_token text, p_session_id uuid, p_question_id uuid, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student  uuid;
  v_session  public.paper_sessions%rowtype;
  v_key      char(1);
  v_saved    public.session_answers%rowtype;
  v_answered integer;
  v_correct  integer;
  v_total    integer;
begin
  v_student := private.require_student(p_token);

  select * into v_session from public.paper_sessions
  where id = p_session_id and student_id = v_student
  for update;
  if not found or not (p_question_id = any(v_session.question_ids)) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if p_answer is null or p_answer not in ('A', 'B', 'C', 'D') then
    return jsonb_build_object('ok', false, 'error', 'invalid_answer');
  end if;

  select answer into v_key from public.question_keys where question_id = p_question_id;

  insert into public.session_answers (session_id, question_id, answer, correct)
  values (v_session.id, p_question_id, p_answer, p_answer = v_key)
  on conflict (session_id, question_id) do nothing;

  select * into v_saved from public.session_answers
  where session_id = v_session.id and question_id = p_question_id;

  -- 每位學生每題第一次作答，供錯題本與分類分析
  insert into public.attempts (student_id, question_id, course_id, paper, class_id, category_code, first_answer, first_correct)
  select v_student, q.id, v_session.course_id, v_session.paper, v_session.class_id, q.category_code, v_saved.answer, v_saved.correct
  from public.questions q where q.id = p_question_id
  on conflict (student_id, question_id) do nothing;

  v_total := cardinality(v_session.question_ids);
  select count(*), count(*) filter (where correct) into v_answered, v_correct
  from public.session_answers where session_id = v_session.id;

  if v_session.submitted_at is null and v_answered = v_total then
    update public.paper_sessions
    set submitted_at  = now(),
        correct_count = v_correct,
        score         = case when paper = 'past' then null else round(v_correct * 100.0 / v_total, 1) end
    where id = v_session.id
    returning * into v_session;
  end if;

  return jsonb_build_object(
    'ok', true,
    'result', private.answer_result(p_question_id, v_saved.answer, v_saved.correct),
    'answered', v_answered,
    'total', v_total,
    'submitted', v_session.submitted_at is not null,
    'correct_count', v_session.correct_count,
    'score', v_session.score);
end;
$$;

-- 某一卷的歷次作答（課程頁「看作答紀錄」）
create or replace function public.student_paper_history(p_token text, p_course_id uuid, p_paper text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
begin
  v_student := private.require_student(p_token);
  return jsonb_build_object(
    'ok', true,
    'sessions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',            s.id,
               'attempt_no',    s.attempt_no,
               'submitted',     s.submitted_at is not null,
               'score',         s.score,
               'correct_count', s.correct_count,
               'total',         cardinality(s.question_ids))
             order by s.attempt_no)
      from public.paper_sessions s
      where s.student_id = v_student and s.course_id = p_course_id and s.paper = p_paper), '[]'::jsonb));
end;
$$;

-- 權限：先全部收回，再逐一授權
revoke execute on function private.draw_questions(uuid, uuid, text, integer, integer, boolean) from public, anon, authenticated;
revoke execute on function private.answer_result(uuid, char, boolean)                       from public, anon, authenticated;
revoke execute on function public.student_papers(text, uuid)                                 from public, anon, authenticated;
revoke execute on function public.student_start_paper(text, uuid, text)                      from public, anon, authenticated;
revoke execute on function public.student_paper_session(text, uuid)                          from public, anon, authenticated;
revoke execute on function public.student_answer(text, uuid, uuid, text)                     from public, anon, authenticated;
revoke execute on function public.student_paper_history(text, uuid, text)                    from public, anon, authenticated;

grant execute on function public.student_papers(text, uuid)             to anon, authenticated;
grant execute on function public.student_start_paper(text, uuid, text)  to anon, authenticated;
grant execute on function public.student_paper_session(text, uuid)      to anon, authenticated;
grant execute on function public.student_answer(text, uuid, uuid, text) to anon, authenticated;
grant execute on function public.student_paper_history(text, uuid, text) to anon, authenticated;
