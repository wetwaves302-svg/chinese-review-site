-- =====================================================================
-- 技高國文複習站｜第五步：錯題本、收藏、錯題重做
-- 國立花蓮高工｜貞伊老師製作
--
--   錯題本：attempts.first_correct = false 的題目（第一次作答答錯）
--   錯題重做：寫入 attempts.retry_*，只影響「目前掌握度」，不改變任何分數；
--             attempts.first_* 由第一步的觸發器保護，不會被改動
--   收藏：favorites，只能收藏自己作答過的題目
--   目前掌握度：錯題中最近一次重做答對的比例
-- =====================================================================

-- 單題內容（不含答案）：題幹、選項、原圖、題組、歷屆年份題號
create or replace function private.question_payload(p_question_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id',          q.id,
    'stem',        q.stem,
    'options',     jsonb_build_array(q.option_a, q.option_b, q.option_c, q.option_d),
    'group_id',    q.group_id,
    'past_year',   q.past_year,
    'past_exam',   q.past_exam,
    'past_number', q.past_number,
    'image',       case when i.question_id is not null
                        then 'data:' || i.mime_type || ';base64,' || i.data_base64 end)
  from public.questions q
  left join public.question_images i on i.question_id = q.id
  where q.id = p_question_id;
$$;

-- 題組文章
create or replace function private.group_payload(p_group_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('title', g.title, 'source', g.source, 'passage', g.passage)
  from public.question_groups g
  where g.id = p_group_id;
$$;

-- 讀取一張卷（改寫：共用 question_payload，並附上是否已收藏）
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
      select jsonb_agg(private.question_payload(t.question_id) || jsonb_build_object(
               'result',   case when a.question_id is not null
                                then private.answer_result(t.question_id, a.answer, a.correct) end,
               'favorite', exists (select 1 from public.favorites f
                                   where f.student_id = v_student and f.question_id = t.question_id))
             order by t.ord)
      from unnest(v_session.question_ids) with ordinality as t(question_id, ord)
      left join public.session_answers a on a.session_id = v_session.id and a.question_id = t.question_id),
    'groups', coalesce((
      select jsonb_object_agg(g.id::text, private.group_payload(g.id))
      from public.question_groups g
      where g.id in (select q.group_id from public.questions q where q.id = any(v_session.question_ids))), '{}'::jsonb));
end;
$$;

-- 課程頁入口的題數：錯題、已重做答對、收藏
create or replace function public.student_review_summary(p_token text, p_course_id uuid)
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
    'mistakes',  (select count(*) from public.attempts
                  where student_id = v_student and course_id = p_course_id and not first_correct),
    'mastered',  (select count(*) from public.attempts
                  where student_id = v_student and course_id = p_course_id and not first_correct and retry_correct),
    'favorites', (select count(*) from public.favorites
                  where student_id = v_student and course_id = p_course_id));
end;
$$;

-- 錯題本或收藏清單
create or replace function public.student_review_list(p_token text, p_course_id uuid, p_kind text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
begin
  v_student := private.require_student(p_token);
  if p_kind is null or p_kind not in ('mistakes', 'favorites') then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'course_title', (select title from public.courses where id = p_course_id),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'question_id',   a.question_id,
               'stem',          q.stem,
               'has_image',     exists (select 1 from public.question_images i where i.question_id = q.id),
               'paper',         a.paper,
               'past_year',     q.past_year,
               'past_number',   q.past_number,
               'first_correct', a.first_correct,
               'retry_count',   a.retry_count,
               'retry_correct', a.retry_correct,
               'favorite',      f.question_id is not null)
             order by coalesce(f.created_at, a.first_at) desc)
      from public.attempts a
      join public.questions q on q.id = a.question_id
      left join public.favorites f on f.student_id = a.student_id and f.question_id = a.question_id
      where a.student_id = v_student and a.course_id = p_course_id
        and case p_kind when 'mistakes' then not a.first_correct else f.question_id is not null end), '[]'::jsonb));
end;
$$;

-- 讀取單題：p_mode = 'retry' 時不含答案（錯題重做）；'review' 時附上第一次作答的結果與解析
create or replace function public.student_question(p_token text, p_question_id uuid, p_mode text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_attempt public.attempts%rowtype;
  v_group   uuid;
begin
  v_student := private.require_student(p_token);

  select * into v_attempt from public.attempts
  where student_id = v_student and question_id = p_question_id;
  if not found or p_mode is null or p_mode not in ('retry', 'review') then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select group_id into v_group from public.questions where id = p_question_id;

  return jsonb_build_object(
    'ok', true,
    'course_id',    v_attempt.course_id,
    'course_title', (select title from public.courses where id = v_attempt.course_id),
    'paper',        v_attempt.paper,
    'question',     private.question_payload(p_question_id) || jsonb_build_object(
                      'favorite', exists (select 1 from public.favorites f
                                          where f.student_id = v_student and f.question_id = p_question_id)),
    'group',        case when v_group is not null then private.group_payload(v_group) end,
    'first',        jsonb_build_object('answer', v_attempt.first_answer, 'correct', v_attempt.first_correct),
    'retry',        jsonb_build_object('count', v_attempt.retry_count, 'correct', v_attempt.retry_correct),
    'result',       case when p_mode = 'review'
                         then private.answer_result(p_question_id, v_attempt.first_answer, v_attempt.first_correct) end);
end;
$$;

-- 錯題重做：只能重做第一次答錯的題目；不限次數，只影響目前掌握度
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
begin
  v_student := private.require_student(p_token);
  if p_answer is null or p_answer not in ('A', 'B', 'C', 'D') then
    return jsonb_build_object('ok', false, 'error', 'invalid_answer');
  end if;

  select answer into v_key from public.question_keys where question_id = p_question_id;
  v_correct := p_answer = v_key;

  update public.attempts
  set retry_answer = p_answer, retry_correct = v_correct, retry_at = now(), retry_count = retry_count + 1
  where student_id = v_student and question_id = p_question_id and not first_correct;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'result', private.answer_result(p_question_id, p_answer, v_correct));
end;
$$;

-- 收藏或取消收藏：只能收藏自己作答過的題目
create or replace function public.student_favorite(p_token text, p_question_id uuid, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_course  uuid;
begin
  v_student := private.require_student(p_token);

  select course_id into v_course from public.attempts
  where student_id = v_student and question_id = p_question_id;
  if v_course is null or p_on is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if p_on then
    insert into public.favorites (student_id, question_id, course_id)
    values (v_student, p_question_id, v_course)
    on conflict (student_id, question_id) do nothing;
  else
    delete from public.favorites where student_id = v_student and question_id = p_question_id;
  end if;

  return jsonb_build_object('ok', true, 'favorite', p_on);
end;
$$;

-- 權限：先全部收回，再逐一授權
revoke execute on function private.question_payload(uuid)                         from public, anon, authenticated;
revoke execute on function private.group_payload(uuid)                            from public, anon, authenticated;
revoke execute on function public.student_paper_session(text, uuid)               from public, anon, authenticated;
revoke execute on function public.student_review_summary(text, uuid)              from public, anon, authenticated;
revoke execute on function public.student_review_list(text, uuid, text)           from public, anon, authenticated;
revoke execute on function public.student_question(text, uuid, text)              from public, anon, authenticated;
revoke execute on function public.student_retry(text, uuid, text)                 from public, anon, authenticated;
revoke execute on function public.student_favorite(text, uuid, boolean)           from public, anon, authenticated;

grant execute on function public.student_paper_session(text, uuid)      to anon, authenticated;
grant execute on function public.student_review_summary(text, uuid)     to anon, authenticated;
grant execute on function public.student_review_list(text, uuid, text)  to anon, authenticated;
grant execute on function public.student_question(text, uuid, text)     to anon, authenticated;
grant execute on function public.student_retry(text, uuid, text)        to anon, authenticated;
grant execute on function public.student_favorite(text, uuid, boolean)  to anon, authenticated;
