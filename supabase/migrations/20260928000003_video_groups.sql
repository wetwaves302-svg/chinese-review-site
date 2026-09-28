-- =====================================================================
-- 技高國文複習站｜影片分區與影片長度
-- 國立花蓮高工｜貞伊老師製作
--
--   group_name：課程頁分區名稱，留空者歸在「影片」區，例如「統測神助攻」另成一區
--   duration_seconds：影片長度（秒），學生端顯示於標題旁
-- =====================================================================

alter table public.course_videos
  add column if not exists group_name text check (group_name is null or length(trim(group_name)) > 0),
  add column if not exists duration_seconds integer check (duration_seconds is null or duration_seconds > 0);

comment on column public.course_videos.group_name is '課程頁分區名稱；留空歸在「影片」區';
comment on column public.course_videos.duration_seconds is '影片長度（秒），學生端顯示於標題旁';

-- 課程頁：影片多回傳分區與長度
create or replace function public.student_course(p_token text, p_course_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_course  public.courses%rowtype;
begin
  v_student := private.require_student(p_token);

  select * into v_course
  from public.courses
  where id = p_course_id and published;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'course', jsonb_build_object(
      'id',           v_course.id,
      'grade',        v_course.grade,
      'title',        v_course.title,
      'author',       v_course.author,
      'genre',        v_course.genre,
      'is_core14',    v_course.is_core14,
      'intro',        v_course.intro,
      'teacher_note', v_course.teacher_note,
      'materials', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id',        m.id,
                 'title',     m.title,
                 'drive_url', m.drive_url,
                 'viewed',    v.student_id is not null)
               order by m.position, m.title)
        from public.course_materials m
        left join public.material_views v on v.material_id = m.id and v.student_id = v_student
        where m.course_id = v_course.id), '[]'::jsonb),
      'videos', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id',        d.id,
                 'title',     d.title,
                 'video_url', d.video_url,
                 'group_name',       d.group_name,
                 'duration_seconds', d.duration_seconds,
                 'watched',   v.student_id is not null)
               order by d.position, d.title)
        from public.course_videos d
        left join public.video_views v on v.video_id = d.id and v.student_id = v_student
        where d.course_id = v_course.id), '[]'::jsonb)));
end;
$$;

revoke execute on function public.student_course(text, uuid) from public, anon, authenticated;
grant  execute on function public.student_course(text, uuid) to anon, authenticated;
