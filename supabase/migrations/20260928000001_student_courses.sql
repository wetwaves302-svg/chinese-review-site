-- =====================================================================
-- 技高國文複習站｜第三步：學生端課程瀏覽、講義與影片標記
-- 國立花蓮高工｜貞伊老師製作
--
--   學生只看得到已上架（published）的課程；講義與影片的「已閱讀」
--   「已看完」由學生自己標記，也可取消，不計入進度。
--   教師端直接讀寫 courses、course_materials、course_videos，
--   由第一步的 teacher_all 政策把關，本檔不需新增政策。
-- =====================================================================

-- 首頁與年級頁：所有已上架課程，附講義、影片數量與本人的標記數
create function public.student_courses(p_token text)
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
    'courses', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',               c.id,
               'grade',            c.grade,
               'title',            c.title,
               'author',           c.author,
               'genre',            c.genre,
               'is_core14',        c.is_core14,
               'materials',        (select count(*) from public.course_materials m where m.course_id = c.id),
               'materials_viewed', (select count(*)
                                    from public.course_materials m
                                    join public.material_views v on v.material_id = m.id
                                    where m.course_id = c.id and v.student_id = v_student),
               'videos',           (select count(*) from public.course_videos d where d.course_id = c.id),
               'videos_watched',   (select count(*)
                                    from public.course_videos d
                                    join public.video_views v on v.video_id = d.id
                                    where d.course_id = c.id and v.student_id = v_student))
             order by c.grade, c.position, c.created_at)
      from public.courses c
      where c.published), '[]'::jsonb));
end;
$$;

-- 課程頁：課程資訊、講義與影片清單，附本人的標記
create function public.student_course(p_token text, p_course_id uuid)
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
                 'watched',   v.student_id is not null)
               order by d.position, d.title)
        from public.course_videos d
        left join public.video_views v on v.video_id = d.id and v.student_id = v_student
        where d.course_id = v_course.id), '[]'::jsonb)));
end;
$$;

-- 學生自行標記或取消「已閱讀」
create function public.student_mark_material(p_token text, p_material_id uuid, p_viewed boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
begin
  v_student := private.require_student(p_token);

  if p_viewed is null or not exists (
    select 1
    from public.course_materials m
    join public.courses c on c.id = m.course_id
    where m.id = p_material_id and c.published
  ) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if p_viewed then
    insert into public.material_views (student_id, material_id)
    values (v_student, p_material_id)
    on conflict (student_id, material_id) do nothing;
  else
    delete from public.material_views
    where student_id = v_student and material_id = p_material_id;
  end if;

  return jsonb_build_object('ok', true, 'viewed', p_viewed);
end;
$$;

-- 學生自行標記或取消「已看完」
create function public.student_mark_video(p_token text, p_video_id uuid, p_watched boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
begin
  v_student := private.require_student(p_token);

  if p_watched is null or not exists (
    select 1
    from public.course_videos d
    join public.courses c on c.id = d.course_id
    where d.id = p_video_id and c.published
  ) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if p_watched then
    insert into public.video_views (student_id, video_id)
    values (v_student, p_video_id)
    on conflict (student_id, video_id) do nothing;
  else
    delete from public.video_views
    where student_id = v_student and video_id = p_video_id;
  end if;

  return jsonb_build_object('ok', true, 'watched', p_watched);
end;
$$;

-- 權限：先全部收回，再逐一授權
revoke execute on function public.student_courses(text)                       from public, anon, authenticated;
revoke execute on function public.student_course(text, uuid)                  from public, anon, authenticated;
revoke execute on function public.student_mark_material(text, uuid, boolean)  from public, anon, authenticated;
revoke execute on function public.student_mark_video(text, uuid, boolean)     from public, anon, authenticated;

grant execute on function public.student_courses(text)                        to anon, authenticated;
grant execute on function public.student_course(text, uuid)                   to anon, authenticated;
grant execute on function public.student_mark_material(text, uuid, boolean)   to anon, authenticated;
grant execute on function public.student_mark_video(text, uuid, boolean)      to anon, authenticated;
