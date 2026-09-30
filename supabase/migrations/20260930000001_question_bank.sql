-- =====================================================================
-- 技高國文複習站｜第四步：題庫結構（題組文章、題目原圖）
-- 國立花蓮高工｜貞伊老師製作
--
--   question_groups：閱讀測驗的共用文章，同一題組的題目抽題時一起抽出
--   question_images：題目原圖（原書或統測原卷），存於資料庫，只透過學生端
--                    RPC 提供給登入的學生，不放在公開的網站儲存庫
--   各卷題庫沿用 course_questions.paper（basic／advanced／challenge／past）
-- =====================================================================

create table if not exists public.question_groups (
  id         uuid primary key default gen_random_uuid(),
  course_id  uuid not null references public.courses(id) on delete cascade,
  title      text not null,
  source     text,
  passage    text not null,
  created_at timestamptz not null default now()
);
comment on table public.question_groups is '閱讀測驗題組的共用文章；同一題組的題目抽題時一起抽出。';
create index if not exists question_groups_course_idx on public.question_groups (course_id);

alter table public.questions
  add column if not exists group_id uuid references public.question_groups(id) on delete set null;
comment on column public.questions.group_id is '所屬題組（選填）；有值時作答頁先顯示題組文章';
create index if not exists questions_group_idx on public.questions (group_id);

create table if not exists public.question_images (
  question_id uuid primary key references public.questions(id) on delete cascade,
  mime_type   text not null check (mime_type in ('image/png', 'image/jpeg', 'image/webp')),
  data_base64 text not null,
  width       integer check (width > 0),
  height      integer check (height > 0),
  source      text
);
comment on table public.question_images is '題目原圖（含選項），學生端顯示圖片與 (A)～(D) 作答按鈕；選項文字仍存於 questions 供解析對照。';

alter table public.question_groups enable row level security;
alter table public.question_images enable row level security;

drop policy if exists teacher_all on public.question_groups;
drop policy if exists teacher_all on public.question_images;
create policy teacher_all on public.question_groups for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.question_images for all to authenticated using (public.is_teacher()) with check (public.is_teacher());

revoke all on public.question_groups from anon;
revoke all on public.question_images from anon;

-- 新增細標籤「成語」
insert into public.tag_catalog (name, category_code, position)
values ('成語', 'language_knowledge', 17)
on conflict (name) do nothing;
