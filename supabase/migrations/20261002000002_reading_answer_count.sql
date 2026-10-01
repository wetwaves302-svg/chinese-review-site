-- =====================================================================
-- 技高國文複習站｜基礎理解測驗：複選題提示共有幾個答案
-- 國立花蓮高工｜貞伊老師製作
--
--   2026-10-01 貞伊老師要求：複選題顯示「共 N 個答案」，讓學生比較有作答的勇氣
-- =====================================================================

-- 讀取本課的基礎理解測驗（同 20261002000001，另加複選題的正確答案個數，作答時提示學生）
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
                          'answer_count', case when i.kind = 'multi' then length(k.answer) end,
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

revoke execute on function public.student_reading(text, uuid) from public, anon, authenticated;
grant execute on function public.student_reading(text, uuid) to anon, authenticated;
