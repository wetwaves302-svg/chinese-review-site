-- =====================================================================
-- 技高國文複習站｜觀念提醒與圖片題選項換位
-- 國立花蓮高工｜貞伊老師製作
--
--   2026-11-14 貞伊老師提出兩件事：
--   一、圖片題重做時選項位置不變：原圖多半連 (A)～(D) 選項一起印在圖裡，前端只好不換位。
--       題目原圖新增 options_in_image（圖內是否印有選項）。重新裁切、只留題幹與表格／圖表的原圖
--       設為 false，學生端改以文字選項按鈕作答，選項位置就能每次重做都換。
--   二、觀念提醒：同一位學生在同一題、同一個錯誤選項選太多次（目前為 3 次，含各卷作答與錯題重做），
--       就在首頁與該單元醒目提醒，直到他之後再作答這一題答對為止。
--       為了計算次數，錯題重做的每一次作答改為逐筆記錄（retry_answers）；
--       之前只留下最後一次重做，先依現有紀錄補上一筆。
--       錯題重做也開放給「第一次答對、之後卻一再選同一個錯誤選項」的題目，讓學生能從提醒直接重做。
--   成績與分布一律仍以第一次作答計算，不受影響。重複執行不會出錯。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 一、圖片題：圖內是否印有選項
-- ---------------------------------------------------------------------
alter table public.question_images
  add column if not exists options_in_image boolean not null default true;
comment on column public.question_images.options_in_image is
  'true：原圖含 (A)～(D) 選項，學生端顯示圖片與代號按鈕，選項不換位；false：原圖只有題幹與表格／圖表，學生端顯示文字選項並每次換位。';

create or replace function private.question_payload(p_question_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id',            q.id,
    'stem',          q.stem,
    'options',       jsonb_build_array(q.option_a, q.option_b, q.option_c, q.option_d),
    'group_id',      q.group_id,
    'past_year',     q.past_year,
    'past_exam',     q.past_exam,
    'past_number',   q.past_number,
    'image',         case when i.question_id is not null
                          then 'data:' || i.mime_type || ';base64,' || i.data_base64 end,
    'image_options', i.options_in_image)
  from public.questions q
  left join public.question_images i on i.question_id = q.id
  where q.id = p_question_id;
$$;

-- ---------------------------------------------------------------------
-- 二、錯題重做逐筆紀錄
-- ---------------------------------------------------------------------
create table if not exists public.retry_answers (
  id          bigint generated always as identity primary key,
  student_id  uuid not null references public.students(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete restrict,
  answer      char(1) not null check (answer in ('A', 'B', 'C', 'D')),
  correct     boolean not null,
  answered_at timestamptz not null default now()
);
comment on table public.retry_answers is '錯題重做的每一次作答，寫入後不修改；只用於觀念提醒與掌握度，不影響分數。';
create index if not exists retry_answers_student_question_idx on public.retry_answers (student_id, question_id);

alter table public.retry_answers enable row level security;
drop policy if exists teacher_read on public.retry_answers;
create policy teacher_read on public.retry_answers for select to authenticated using (public.is_teacher());
revoke all on public.retry_answers from anon, authenticated;
grant select on public.retry_answers to authenticated;

-- 之前只保留最後一次重做：每筆有重做紀錄的題目先補一筆（只在表內還沒有資料時補）
insert into public.retry_answers (student_id, question_id, answer, correct, answered_at)
select a.student_id, a.question_id, a.retry_answer, a.retry_correct, a.retry_at
from public.attempts a
where a.retry_answer is not null and a.retry_correct is not null and a.retry_at is not null
  and not exists (select 1 from public.retry_answers);

-- ---------------------------------------------------------------------
-- 三、觀念提醒的計算
-- ---------------------------------------------------------------------
-- 同一題同一個錯誤選項選了幾次算「太多」
create or replace function private.concept_threshold()
returns integer
language sql
immutable
set search_path = ''
as $$ select 3 $$;

-- 一位學生的所有作答（各卷＋錯題重做）
create or replace function private.student_answer_log(p_student uuid)
returns table (question_id uuid, answer char(1), correct boolean, answered_at timestamptz)
language sql
stable
set search_path = ''
as $$
  select a.question_id, a.answer, a.correct, a.answered_at
  from public.session_answers a
  join public.paper_sessions s on s.id = a.session_id
  where s.student_id = p_student
  union all
  select r.question_id, r.answer, r.correct, r.answered_at
  from public.retry_answers r
  where r.student_id = p_student;
$$;

-- 這一題這個選項，目前一共選錯幾次（含剛剛這一次）
create or replace function private.wrong_repeat(p_student uuid, p_question_id uuid, p_answer char(1))
returns integer
language sql
stable
set search_path = ''
as $$
  select count(*)::integer
  from private.student_answer_log(p_student) l
  where l.question_id = p_question_id and l.answer = p_answer and not l.correct;
$$;

-- 尚未解除的觀念提醒：錯誤選項次數達門檻，且最後一次選它之後還沒有再答對這一題
create or replace function private.concept_alerts(p_student uuid, p_course_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with log as (
    select * from private.student_answer_log(p_student)
  ), wrong as (
    select l.question_id, l.answer, count(*)::integer as times, max(l.answered_at) as last_at
    from log l
    where not l.correct
    group by l.question_id, l.answer
    having count(*) >= private.concept_threshold()
  ), open as (
    select w.*
    from wrong w
    where not exists (select 1 from log l
                      where l.question_id = w.question_id and l.correct and l.answered_at > w.last_at)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'question_id', o.question_id,
           'course_id',   a.course_id,
           'course_title', c.title,
           'grade',       c.grade,
           'stem',        q.stem,
           'has_image',   exists (select 1 from public.question_images i where i.question_id = q.id),
           'answer',      o.answer,
           'option',      case o.answer when 'A' then q.option_a when 'B' then q.option_b
                                        when 'C' then q.option_c else q.option_d end,
           'explain',     case o.answer when 'A' then k.explain_a when 'B' then k.explain_b
                                        when 'C' then k.explain_c else k.explain_d end,
           'category',    cat.name,
           'tags',        q.tags,
           'times',       o.times,
           'last_at',     o.last_at)
         order by c.grade, c.position, o.times desc, o.last_at desc), '[]'::jsonb)
  from open o
  join public.attempts a on a.student_id = p_student and a.question_id = o.question_id
  join public.courses c on c.id = a.course_id and c.published
  join public.questions q on q.id = o.question_id
  join public.question_keys k on k.question_id = q.id
  left join public.question_categories cat on cat.code = q.category_code
  where p_course_id is null or a.course_id = p_course_id;
$$;

-- 學生端：觀念提醒（p_course_id 為 null 時回傳所有單元，供首頁使用）
create or replace function public.student_concept_alerts(p_token text, p_course_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
begin
  v_student := private.require_student(p_token);
  return jsonb_build_object('ok', true, 'threshold', private.concept_threshold(),
                            'alerts', private.concept_alerts(v_student, p_course_id));
end;
$$;

-- ---------------------------------------------------------------------
-- 四、作答與重做：回傳這個錯誤選項已選幾次，重做逐筆記錄
-- ---------------------------------------------------------------------
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
    'result', private.answer_result(p_question_id, v_saved.answer, v_saved.correct)
              || jsonb_build_object(
                   'repeat', case when v_saved.correct then 0
                                  else private.wrong_repeat(v_student, p_question_id, v_saved.answer) end,
                   'threshold', private.concept_threshold()),
    'answered', v_answered,
    'total', v_total,
    'submitted', v_session.submitted_at is not null,
    'correct_count', v_session.correct_count,
    'score', v_session.score);
end;
$$;

-- 錯題重做：第一次答錯的題目，或有觀念提醒（同一錯誤選項達門檻）的題目；不限次數，只影響掌握度
create or replace function public.student_retry(p_token text, p_question_id uuid, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_key     char(1);
  v_correct boolean;
  v_attempt public.attempts%rowtype;
begin
  v_student := private.require_student(p_token);
  if p_answer is null or p_answer not in ('A', 'B', 'C', 'D') then
    return jsonb_build_object('ok', false, 'error', 'invalid_answer');
  end if;

  select * into v_attempt from public.attempts
  where student_id = v_student and question_id = p_question_id
  for update;
  if not found or (v_attempt.first_correct and not exists (
        select 1 from private.student_answer_log(v_student) l
        where l.question_id = p_question_id and not l.correct
        group by l.answer having count(*) >= private.concept_threshold())) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select answer into v_key from public.question_keys where question_id = p_question_id;
  v_correct := p_answer = v_key;

  update public.attempts
  set retry_answer = p_answer, retry_correct = v_correct, retry_at = now(), retry_count = retry_count + 1
  where student_id = v_student and question_id = p_question_id;

  insert into public.retry_answers (student_id, question_id, answer, correct)
  values (v_student, p_question_id, p_answer, v_correct);

  return jsonb_build_object('ok', true,
    'result', private.answer_result(p_question_id, p_answer, v_correct)
              || jsonb_build_object(
                   'repeat', case when v_correct then 0 else private.wrong_repeat(v_student, p_question_id, p_answer) end,
                   'threshold', private.concept_threshold()));
end;
$$;

-- ---------------------------------------------------------------------
-- 權限：先全部收回，再逐一授權
-- ---------------------------------------------------------------------
revoke execute on function private.question_payload(uuid)                          from public, anon, authenticated;
revoke execute on function private.concept_threshold()                             from public, anon, authenticated;
revoke execute on function private.student_answer_log(uuid)                        from public, anon, authenticated;
revoke execute on function private.wrong_repeat(uuid, uuid, char)                  from public, anon, authenticated;
revoke execute on function private.concept_alerts(uuid, uuid)                      from public, anon, authenticated;
revoke execute on function public.student_concept_alerts(text, uuid)               from public, anon, authenticated;
revoke execute on function public.student_answer(text, uuid, uuid, text)           from public, anon, authenticated;
revoke execute on function public.student_retry(text, uuid, text)                  from public, anon, authenticated;

grant execute on function public.student_concept_alerts(text, uuid)       to anon, authenticated;
grant execute on function public.student_answer(text, uuid, uuid, text)   to anon, authenticated;
grant execute on function public.student_retry(text, uuid, text)          to anon, authenticated;

-- 檢查一：題目原圖多了 options_in_image 欄（應為 1）
select count(*) as 新欄位 from information_schema.columns
where table_schema = 'public' and table_name = 'question_images' and column_name = 'options_in_image';

-- 檢查二：錯題重做紀錄（補上的筆數）與觀念提醒門檻
select (select count(*) from public.retry_answers) as 重做紀錄筆數, private.concept_threshold() as 提醒門檻;
