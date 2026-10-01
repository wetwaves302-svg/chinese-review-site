-- =====================================================================
-- 技高國文複習站｜基礎理解測驗（取自「基礎閱讀力」的課文勾選題）
-- 國立花蓮高工｜貞伊老師製作
--
--   2026-10-01 貞伊老師定案：
--   基礎卷之前的必做測驗，獨立計分（滿分 100，不計入本課挑戰積分）；
--   完成（交卷）後才開放基礎卷；只能寫一次，交卷後才顯示答案與解析；
--   原學習單的勾選題依題意改為單選或複選，配對、排序改為下拉選單，填空改為單選；
--   分數 ＝ 得分 ÷ 原學習單配分總和 × 100（不含最後的閱讀測驗）；
--   複選題依統測多選題方式給部分分：每錯一個選項扣該題五分之二，扣完為止，未作答 0 分；
--   有基礎理解測驗的課程，學期全勤須一併完成
--
--   reading_blocks：一頁一個題組（段落標題、題目說明、引文）
--   reading_items：題組內的作答項目（單選、複選、下拉）
--   reading_keys：答案與解析，學生無法直接讀取
--   reading_sessions／reading_answers：每位學生每課一張，交卷前可修改答案
-- =====================================================================

create table if not exists public.reading_blocks (
  id        uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  position  integer not null,
  section   text not null,
  title     text not null,
  context   text not null default ''
);
create index if not exists reading_blocks_course_idx on public.reading_blocks (course_id, position);

create table if not exists public.reading_items (
  id       uuid primary key default gen_random_uuid(),
  block_id uuid not null references public.reading_blocks(id) on delete cascade,
  position integer not null,
  label    text not null default '',
  quote    text not null default '',
  kind     text not null check (kind in ('single', 'multi', 'select')),
  options  text[] not null check (cardinality(options) between 2 and 6),
  points   numeric(4, 1) not null check (points > 0)
);
create index if not exists reading_items_block_idx on public.reading_items (block_id, position);

create table if not exists public.reading_keys (
  item_id     uuid primary key references public.reading_items(id) on delete cascade,
  answer      text not null check (answer ~ '^[A-F]+$'),
  explanation text not null
);
comment on table public.reading_keys is '基礎理解測驗的答案與解析。學生無法直接讀取，只在交卷後由安全函式回傳。';

create table if not exists public.reading_sessions (
  id           uuid primary key default gen_random_uuid(),
  student_id   uuid not null references public.students(id) on delete cascade,
  course_id    uuid not null references public.courses(id) on delete restrict,
  class_id     uuid not null references public.classes(id),
  started_at   timestamptz not null default now(),
  submitted_at timestamptz,
  score        numeric(5, 1),
  unique (student_id, course_id)
);
comment on table public.reading_sessions is '基礎理解測驗：每位學生每課一張，只能交卷一次；score 為滿分 100 的換算分數。';
create index if not exists reading_sessions_course_idx on public.reading_sessions (course_id);

create table if not exists public.reading_answers (
  session_id uuid not null references public.reading_sessions(id) on delete cascade,
  item_id    uuid not null references public.reading_items(id) on delete restrict,
  answer     text not null check (answer ~ '^[A-F]+$'),
  updated_at timestamptz not null default now(),
  primary key (session_id, item_id)
);

alter table public.reading_blocks   enable row level security;
alter table public.reading_items    enable row level security;
alter table public.reading_keys     enable row level security;
alter table public.reading_sessions enable row level security;
alter table public.reading_answers  enable row level security;
drop policy if exists teacher_all on public.reading_blocks;
drop policy if exists teacher_all on public.reading_items;
drop policy if exists teacher_all on public.reading_keys;
drop policy if exists teacher_read on public.reading_sessions;
drop policy if exists teacher_read on public.reading_answers;
create policy teacher_all on public.reading_blocks for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.reading_items  for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.reading_keys   for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_read on public.reading_sessions for select to authenticated using (public.is_teacher());
create policy teacher_read on public.reading_answers  for select to authenticated using (public.is_teacher());
revoke all on public.reading_blocks   from anon;
revoke all on public.reading_items    from anon;
revoke all on public.reading_keys     from anon;
revoke all on public.reading_sessions from anon;
revoke all on public.reading_answers  from anon;

-- ---------------------------------------------------------------------
-- 共用判斷
-- ---------------------------------------------------------------------

-- 這一課有沒有基礎理解測驗
create or replace function private.has_reading(p_course uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from public.reading_blocks where course_id = p_course);
$$;

-- 這位學生的基礎卷是否還沒開放（這一課有基礎理解測驗，而且還沒交卷）
create or replace function private.reading_locks_basic(p_student uuid, p_course uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select private.has_reading(p_course)
     and not exists (select 1 from public.reading_sessions
                     where student_id = p_student and course_id = p_course and submitted_at is not null);
$$;

-- 一個項目的得分：單選、下拉全對才給分；複選每錯一個選項扣五分之二，扣完為止，未作答 0 分
create or replace function private.reading_earned(p_kind text, p_answer text, p_key text, p_points numeric, p_options integer)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case
    when p_answer is null or p_answer = '' then 0
    when p_kind <> 'multi' then case when p_answer = p_key then p_points else 0 end
    else round(p_points * greatest(0, 1 - 0.4 * (
           select count(*) from generate_series(1, p_options) as g(n)
           where (strpos(p_answer, chr(64 + g.n)) > 0) <> (strpos(p_key, chr(64 + g.n)) > 0))), 1)
  end;
$$;

-- ---------------------------------------------------------------------
-- 學生端：讀取、存答案、交卷
-- ---------------------------------------------------------------------

-- 讀取本課的基礎理解測驗：題目與已存的答案；交卷後另附正確答案、解析、各項得分
create or replace function public.student_reading(p_token text, p_course_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_session public.reading_sessions%rowtype;
  v_done    boolean;
begin
  v_student := private.require_student(p_token);

  if not exists (select 1 from public.courses where id = p_course_id and published)
     or not private.has_reading(p_course_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select * into v_session from public.reading_sessions
  where student_id = v_student and course_id = p_course_id;
  v_done := v_session.submitted_at is not null;

  return jsonb_build_object(
    'ok', true,
    'course', (select jsonb_build_object('id', c.id, 'title', c.title, 'grade', c.grade)
               from public.courses c where c.id = p_course_id),
    'submitted', v_done,
    'score', v_session.score,
    'total_points', (select sum(i.points) from public.reading_items i
                     join public.reading_blocks b on b.id = i.block_id where b.course_id = p_course_id),
    'blocks', (
      select jsonb_agg(jsonb_build_object(
               'id', b.id, 'section', b.section, 'title', b.title, 'context', b.context,
               'items', (
                 select jsonb_agg(jsonb_build_object(
                          'id', i.id, 'label', i.label, 'quote', i.quote, 'kind', i.kind,
                          'options', to_jsonb(i.options), 'points', i.points,
                          'answer', a.answer,
                          'key', case when v_done then k.answer end,
                          'explanation', case when v_done then k.explanation end,
                          'earned', case when v_done then private.reading_earned(i.kind, a.answer, k.answer, i.points, cardinality(i.options)) end)
                        order by i.position)
                 from public.reading_items i
                 join public.reading_keys k on k.item_id = i.id
                 left join public.reading_answers a on a.session_id = v_session.id and a.item_id = i.id
                 where i.block_id = b.id))
             order by b.position)
      from public.reading_blocks b
      where b.course_id = p_course_id));
end;
$$;

-- 存一個項目的答案（交卷前可修改；空字串表示清除）
create or replace function public.student_reading_save(p_token text, p_course_id uuid, p_item_id uuid, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_item    public.reading_items%rowtype;
  v_session public.reading_sessions%rowtype;
  v_answer  text;
begin
  v_student := private.require_student(p_token);

  select i.* into v_item
  from public.reading_items i
  join public.reading_blocks b on b.id = i.block_id
  join public.courses c on c.id = b.course_id
  where i.id = p_item_id and b.course_id = p_course_id and c.published;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- 依字母排序、去除重複，只接受這一項有的選項
  select coalesce(string_agg(distinct l, '' order by l), '') into v_answer
  from regexp_split_to_table(upper(coalesce(p_answer, '')), '') as l
  where l <> '';
  if v_answer !~ '^[A-F]*$'
     or exists (select 1 from regexp_split_to_table(v_answer, '') as l where ascii(l) - 64 > cardinality(v_item.options))
     or (v_item.kind <> 'multi' and length(v_answer) > 1) then
    return jsonb_build_object('ok', false, 'error', 'invalid_answer');
  end if;

  insert into public.reading_sessions (student_id, course_id, class_id)
  select v_student, p_course_id, s.class_id from public.students s where s.id = v_student
  on conflict (student_id, course_id) do nothing;

  select * into v_session from public.reading_sessions
  where student_id = v_student and course_id = p_course_id
  for update;
  if v_session.submitted_at is not null then
    return jsonb_build_object('ok', false, 'error', 'submitted');
  end if;

  if v_answer = '' then
    delete from public.reading_answers where session_id = v_session.id and item_id = p_item_id;
  else
    insert into public.reading_answers (session_id, item_id, answer)
    values (v_session.id, p_item_id, v_answer)
    on conflict (session_id, item_id) do update set answer = excluded.answer, updated_at = now();
  end if;

  return jsonb_build_object('ok', true, 'answer', nullif(v_answer, ''));
end;
$$;

-- 交卷：計算換算分數，之後不能再改
create or replace function public.student_reading_submit(p_token text, p_course_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_session public.reading_sessions%rowtype;
  v_earned  numeric;
  v_total   numeric;
  v_score   numeric;
begin
  v_student := private.require_student(p_token);

  if not exists (select 1 from public.courses where id = p_course_id and published)
     or not private.has_reading(p_course_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  insert into public.reading_sessions (student_id, course_id, class_id)
  select v_student, p_course_id, s.class_id from public.students s where s.id = v_student
  on conflict (student_id, course_id) do nothing;

  select * into v_session from public.reading_sessions
  where student_id = v_student and course_id = p_course_id
  for update;
  if v_session.submitted_at is not null then
    return jsonb_build_object('ok', true, 'score', v_session.score, 'already', true);
  end if;

  select coalesce(sum(private.reading_earned(i.kind, a.answer, k.answer, i.points, cardinality(i.options))), 0),
         sum(i.points)
  into v_earned, v_total
  from public.reading_items i
  join public.reading_blocks b on b.id = i.block_id
  join public.reading_keys k on k.item_id = i.id
  left join public.reading_answers a on a.session_id = v_session.id and a.item_id = i.id
  where b.course_id = p_course_id;

  v_score := round(v_earned / v_total * 100, 1);
  update public.reading_sessions set submitted_at = now(), score = v_score where id = v_session.id;

  return jsonb_build_object('ok', true, 'score', v_score, 'already', false);
end;
$$;

-- ---------------------------------------------------------------------
-- 改寫既有函式：基礎卷須先完成基礎理解測驗；課程頁與成績頁加上基礎理解測驗
-- ---------------------------------------------------------------------

-- 本課各卷狀態（同 20260930000002，另加基礎理解測驗狀態與基礎卷開放條件）
create or replace function public.student_papers(p_token text, p_course_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_basic_done boolean;
  v_basic_locked boolean;
  v_papers jsonb;
  v_a numeric; v_b numeric; v_c numeric;
  v_past_done integer;
  v_reading jsonb;
begin
  v_student := private.require_student(p_token);

  if not exists (select 1 from public.courses where id = p_course_id and published) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  v_basic_done := exists (
    select 1 from public.paper_sessions
    where student_id = v_student and course_id = p_course_id and paper = 'basic' and submitted_at is not null);
  v_basic_locked := private.reading_locks_basic(v_student, p_course_id);

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
           'unlocked',     case when p.paper = 'basic' then not v_basic_locked else v_basic_done end)
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

  if private.has_reading(p_course_id) then
    select jsonb_build_object(
             'items', (select count(*) from public.reading_items i
                       join public.reading_blocks b on b.id = i.block_id where b.course_id = p_course_id),
             'answered', (select count(*) from public.reading_answers a where a.session_id = s.id),
             'submitted', s.submitted_at is not null,
             'score', s.score)
    into v_reading
    from (select 1) as one
    left join public.reading_sessions s on s.student_id = v_student and s.course_id = p_course_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'papers', v_papers,
    'reading', v_reading,
    'challenge_score', case when v_a is null then null
                            else round(v_a + coalesce(v_b, 0) * 0.25 + coalesce(v_c, 0) * 0.10, 1) end,
    'past_completed', v_past_done,
    'past_bonus', case when v_past_done > 0 then 0.5 else 0 end);
end;
$$;

-- 開始或繼續作答（同 20260930000002，另加：基礎卷須先完成基礎理解測驗）
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

  if p_paper = 'basic' and private.reading_locks_basic(v_student, p_course_id) then
    return jsonb_build_object('ok', false, 'error', 'reading_first');
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

-- 個人成績（同 20261001000001，另加各課基礎理解測驗分數；有基礎理解測驗的課程，全勤須一併完成）
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

  drop table if exists pg_temp.my_courses;
  create temporary table pg_temp.my_courses (
    course_id uuid, title text, grade smallint, semester_id text, is_core14 boolean, position integer,
    a numeric, b numeric, c numeric, done_basic integer, done_advanced integer, done_challenge integer,
    past_done integer, past_term text, has_reading boolean, reading_score numeric, reading_done boolean) on commit drop;

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
         private.has_reading(c.id),
         (select r.score from public.reading_sessions r
          where r.student_id = v_student and r.course_id = c.id and r.submitted_at is not null),
         exists (select 1 from public.reading_sessions r
                 where r.student_id = v_student and r.course_id = c.id and r.submitted_at is not null)
  from public.courses c
  left join public.paper_sessions s
    on s.course_id = c.id and s.student_id = v_student and s.submitted_at is not null
  where c.published
  group by c.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.course_id, 'title', m.title, 'grade', m.grade, 'semester_id', m.semester_id,
           'is_core14', m.is_core14,
           'a', m.a, 'b', m.b, 'c', m.c,
           'has_reading', m.has_reading, 'reading_score', m.reading_score,
           'done', jsonb_build_object('basic', m.done_basic, 'advanced', m.done_advanced,
                                      'challenge', m.done_challenge, 'past', m.past_done),
           'challenge_score', case when m.a is null then null
                                   else round(m.a + coalesce(m.b, 0) * 0.25 + coalesce(m.c, 0) * 0.10, 1) end,
           'past_bonus', case when m.past_done > 0 then 0.5 else 0 end,
           'past_term', m.past_term)
         order by m.grade, m.position, m.title), '[]'::jsonb)
  into v_courses
  from pg_temp.my_courses m
  where m.reading_done or m.done_basic + m.done_advanced + m.done_challenge + m.past_done > 0;

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
              and (m.reading_done or not m.has_reading)
              and m.done_basic > 0 and m.done_advanced > 0 and m.done_challenge > 0 and m.past_done > 0) as complete,
           jsonb_build_object(
             'grade', v_grade,
             'total', (select count(*) from pg_temp.my_courses m where m.grade = v_grade and m.semester_id = sem.id),
             'courses', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', m.course_id, 'title', m.title,
                        'reading', case when m.has_reading then m.reading_done end,
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

-- 權限：先全部收回，再逐一授權
revoke execute on function private.has_reading(uuid)                                    from public, anon, authenticated;
revoke execute on function private.reading_locks_basic(uuid, uuid)                      from public, anon, authenticated;
revoke execute on function private.reading_earned(text, text, text, numeric, integer)   from public, anon, authenticated;
revoke execute on function public.student_reading(text, uuid)                           from public, anon, authenticated;
revoke execute on function public.student_reading_save(text, uuid, uuid, text)          from public, anon, authenticated;
revoke execute on function public.student_reading_submit(text, uuid)                    from public, anon, authenticated;
revoke execute on function public.student_papers(text, uuid)                            from public, anon, authenticated;
revoke execute on function public.student_start_paper(text, uuid, text)                 from public, anon, authenticated;
revoke execute on function public.student_scores(text)                                  from public, anon, authenticated;

grant execute on function public.student_reading(text, uuid)                  to anon, authenticated;
grant execute on function public.student_reading_save(text, uuid, uuid, text) to anon, authenticated;
grant execute on function public.student_reading_submit(text, uuid)           to anon, authenticated;
grant execute on function public.student_papers(text, uuid)                   to anon, authenticated;
grant execute on function public.student_start_paper(text, uuid, text)        to anon, authenticated;
grant execute on function public.student_scores(text)                         to anon, authenticated;
