-- =====================================================================
-- 技高國文複習站｜課程所屬學期
-- 國立花蓮高工｜貞伊老師製作
--
--   學期全勤加分依「該年級當學期所有課程」判定，因此每課須標記學期。
--   既有課程皆為 115-1 建立，一併補上。
-- =====================================================================

alter table public.courses
  add column semester_id text references public.semesters(id);

comment on column public.courses.semester_id is '課程所屬學期；學期全勤加分以該年級當學期的課程判定';

update public.courses
set semester_id = '115-1'
where semester_id is null;

create index courses_semester_grade_idx on public.courses (semester_id, grade);
