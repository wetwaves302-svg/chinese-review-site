-- =====================================================================
-- 技高國文複習站｜第一步：資料結構、RLS、登入 RPC
-- 國立花蓮高工｜貞伊老師製作
--
-- 設計要點
--   1. 學生不使用 Supabase Auth，也不建立 anonymous user；
--      學生一律經由 SECURITY DEFINER 函式登入，取得由資料庫簽發的
--      HMAC 工作階段憑證（token），之後所有學生操作都帶 token 呼叫 RPC。
--   2. 教師使用 Supabase Auth（Email＋密碼），名單在 public.teachers。
--   3. 所有機密（通行碼雜湊、PIN 雜湊、初始碼雜湊、token 簽章金鑰）
--      存放在 private schema，此 schema 不經 API 公開，anon / authenticated
--      沒有任何權限，只能由安全函式存取。
--   4. anon 角色對所有資料表沒有權限，只能呼叫明確授權的 RPC。
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public;

-- ---------------------------------------------------------------------
-- 一、網站設定與分類
-- ---------------------------------------------------------------------

create table public.site_settings (
  id          smallint primary key default 1 check (id = 1),
  site_title  text not null default '技高國文複習站',
  credit_line text not null default '國立花蓮高工｜貞伊老師製作',
  updated_at  timestamptz not null default now()
);
comment on table public.site_settings is '公開性網站設定（單列）。通行碼雜湊不在此表，存放於 private.app_secrets。';
insert into public.site_settings default values;

create table public.semesters (
  id        text primary key,
  name      text not null,
  starts_on date not null,
  ends_on   date,
  check (ends_on is null or ends_on >= starts_on)
);
comment on table public.semesters is '學期起訖，歷屆挑戰點數依此分學期累計。ends_on 未定時留空。';
insert into public.semesters (id, name, starts_on, ends_on) values
  ('115-1', '115學年度第一學期', '2026-08-01', '2027-01-20'),
  ('115-2', '115學年度第二學期', '2027-01-21', null);

create table public.question_categories (
  code     text primary key,
  name     text not null unique,
  position smallint not null
);
comment on table public.question_categories is '六個分析大類。弱點百分比只以大類計算。';
insert into public.question_categories (code, name, position) values
  ('word_basic',         '字詞基礎', 1),
  ('language_knowledge', '語文知識', 2),
  ('comprehension',      '文意理解', 3),
  ('structure',          '篇章分析', 4),
  ('literature_culture', '文學文化', 5),
  ('reading_literacy',   '閱讀素養', 6);

create table public.tag_catalog (
  name          text primary key,
  category_code text not null references public.question_categories(code),
  position      smallint not null
);
comment on table public.tag_catalog is '細標籤清單（教師可增補）。細標籤供教師深入分析與出題篩選，不直接計算學生弱點百分比。';
insert into public.tag_catalog (name, category_code, position) values
  ('字音',       'word_basic',         1),
  ('字形',       'word_basic',         2),
  ('字義',       'word_basic',         3),
  ('古今異義',   'word_basic',         4),
  ('通同字',     'word_basic',         5),
  ('詞性活用',   'word_basic',         6),
  ('虛詞',       'word_basic',         7),
  ('修辭',       'language_knowledge', 8),
  ('句式語法',   'language_knowledge', 9),
  ('文意判讀',   'comprehension',      10),
  ('人物形象',   'comprehension',      11),
  ('篇章結構',   'structure',          12),
  ('寫作手法',   'structure',          13),
  ('國學常識',   'literature_culture', 14),
  ('文化常識',   'literature_culture', 15),
  ('跨文本閱讀', 'reading_literacy',   16);

-- ---------------------------------------------------------------------
-- 二、班級、學生、教師
-- ---------------------------------------------------------------------

create table public.classes (
  id          uuid primary key default gen_random_uuid(),
  school_year smallint not null,
  name        text not null,
  grade       smallint not null check (grade between 1 and 3),
  active      boolean not null default true,
  unique (school_year, name)
);

create table public.students (
  id           uuid primary key default gen_random_uuid(),
  class_id     uuid not null references public.classes(id),
  seat         smallint not null check (seat between 1 and 99),
  display_name text,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  unique (class_id, seat)
);
comment on table public.students is '學生身分與班級脫鉤：升級時只更新 class_id 與 seat，學習紀錄不受影響。';
create index students_class_idx on public.students (class_id);

create table public.teachers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email   text not null,
  name    text not null
);

-- ---------------------------------------------------------------------
-- 三、課程、教材、影片
-- ---------------------------------------------------------------------

create table public.courses (
  id           uuid primary key default gen_random_uuid(),
  grade        smallint not null check (grade between 1 and 3),
  title        text not null,
  author       text,
  genre        text,
  is_core14    boolean not null default false,
  intro        text,
  teacher_note text,
  published    boolean not null default false,
  position     integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on column public.courses.is_core14 is '教育部部定14篇古文';
comment on column public.courses.teacher_note is '貞伊老師提醒（選填）';

create table public.course_materials (
  id        uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  title     text not null,
  drive_url text not null check (drive_url ~ '^https://'),
  position  integer not null default 0
);
comment on table public.course_materials is '上課教材（雲端硬碟連結），學生自由閱讀，不計入進度。';
create index course_materials_course_idx on public.course_materials (course_id, position);

create table public.course_videos (
  id        uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  title     text not null,
  video_url text not null check (video_url ~ '^https://'),
  position  integer not null default 0
);
comment on table public.course_videos is '複習影片（Loom 等外部連結），學生自由觀看，不計入進度。';
create index course_videos_course_idx on public.course_videos (course_id, position);

-- ---------------------------------------------------------------------
-- 四、題庫
-- ---------------------------------------------------------------------

create table public.questions (
  id                     uuid primary key default gen_random_uuid(),
  stem                   text not null,
  option_a               text not null,
  option_b               text not null,
  option_c               text not null,
  option_d               text not null,
  category_code          text not null references public.question_categories(code),
  tags                   text[] not null default '{}',
  past_year              smallint,
  past_exam              text,
  past_number            smallint,
  source                 text,
  review_video_id        uuid references public.course_videos(id) on delete set null,
  review_video_timestamp integer check (review_video_timestamp >= 0),
  review_material_id     uuid references public.course_materials(id) on delete set null,
  review_material_page   integer check (review_material_page >= 1),
  active                 boolean not null default true,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
comment on column public.questions.category_code is '分析大類（六選一）';
comment on column public.questions.tags is '細標籤（可多個，對照 tag_catalog）';
comment on column public.questions.review_video_id is '錯題補救：回看哪一支影片（選填）';
comment on column public.questions.review_video_timestamp is '錯題補救：影片起播秒數（選填，須搭配 review_video_id）';
comment on column public.questions.review_material_id is '錯題補救：回看哪一份教材（選填）';
comment on column public.questions.review_material_page is '錯題補救：教材頁碼（選填，須搭配 review_material_id）';
comment on column public.questions.active is '停用題目請改為 false，勿刪除，以保留作答紀錄。';

create table public.question_keys (
  question_id  uuid primary key references public.questions(id) on delete cascade,
  answer       char(1) not null check (answer in ('A','B','C','D')),
  explain_a    text not null,
  explain_b    text not null,
  explain_c    text not null,
  explain_d    text not null,
  teacher_note text
);
comment on table public.question_keys is '正確答案與四選項解析。學生無法直接讀取，只在作答後由安全函式回傳。';

create table public.course_questions (
  course_id   uuid not null references public.courses(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete cascade,
  paper       text not null check (paper in ('basic','advanced','challenge','past')),
  position    integer not null default 0,
  primary key (course_id, question_id)
);
comment on column public.course_questions.paper is 'basic 基礎卷（必寫）／advanced 進階卷（挑戰積分 25%）／challenge 挑戰卷（挑戰積分 50%）／past 歷屆試題（歷屆挑戰點數）';
create index course_questions_paper_idx on public.course_questions (course_id, paper, position);

-- ---------------------------------------------------------------------
-- 五、學習紀錄
-- ---------------------------------------------------------------------

create table public.attempts (
  student_id     uuid not null references public.students(id) on delete cascade,
  question_id    uuid not null references public.questions(id) on delete restrict,
  course_id      uuid not null references public.courses(id) on delete restrict,
  paper          text not null check (paper in ('basic','advanced','challenge','past')),
  class_id       uuid not null references public.classes(id),
  category_code  text not null references public.question_categories(code),
  first_answer   char(1) not null check (first_answer in ('A','B','C','D')),
  first_correct  boolean not null,
  first_at       timestamptz not null default now(),
  retry_answer   char(1) check (retry_answer in ('A','B','C','D')),
  retry_correct  boolean,
  retry_at       timestamptz,
  retry_count    integer not null default 0,
  primary key (student_id, question_id)
);
comment on table public.attempts is '一人一題一列。首次作答（first_*）寫入後不可修改，分數與分布一律以首次作答計算；重做只影響掌握度。';
create index attempts_course_paper_idx on public.attempts (course_id, paper);
create index attempts_class_course_idx on public.attempts (class_id, course_id);

create table public.favorites (
  student_id  uuid not null references public.students(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete cascade,
  course_id   uuid not null references public.courses(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (student_id, question_id)
);

create table public.material_views (
  student_id  uuid not null references public.students(id) on delete cascade,
  material_id uuid not null references public.course_materials(id) on delete cascade,
  viewed_at   timestamptz not null default now(),
  primary key (student_id, material_id)
);

create table public.video_views (
  student_id uuid not null references public.students(id) on delete cascade,
  video_id   uuid not null references public.course_videos(id) on delete cascade,
  viewed_at  timestamptz not null default now(),
  primary key (student_id, video_id)
);

-- ---------------------------------------------------------------------
-- 六、private schema：機密與登入狀態
-- ---------------------------------------------------------------------

create table private.app_secrets (
  key   text primary key,
  value text not null
);
insert into private.app_secrets (key, value)
values ('token_secret', encode(extensions.gen_random_bytes(32), 'hex'));

create table private.student_credentials (
  student_id        uuid primary key references public.students(id) on delete cascade,
  pin_hash          text,
  initial_code_hash text,
  session_version   integer not null default 1,
  fail_count        smallint not null default 0,
  locked_until      timestamptz,
  pin_set_at        timestamptz,
  check (pin_hash is not null or initial_code_hash is not null)
);

create table private.gate_failures (
  id bigint generated always as identity primary key,
  at timestamptz not null default now()
);
create index gate_failures_at_idx on private.gate_failures (at);

-- ---------------------------------------------------------------------
-- 七、觸發器
-- ---------------------------------------------------------------------

create function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger courses_touch before update on public.courses
  for each row execute function private.touch_updated_at();
create trigger questions_touch before update on public.questions
  for each row execute function private.touch_updated_at();

create function private.guard_first_attempt()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.student_id, new.question_id, new.first_answer, new.first_correct, new.first_at)
     is distinct from
     (old.student_id, old.question_id, old.first_answer, old.first_correct, old.first_at) then
    raise exception using errcode = '42501', message = 'first_attempt_is_immutable';
  end if;
  return new;
end;
$$;

create trigger attempts_guard before update on public.attempts
  for each row execute function private.guard_first_attempt();

-- ---------------------------------------------------------------------
-- 八、private 函式：通行碼、憑證、驗證
--    （注意：會寫入失敗紀錄的函式一律以回傳值表示失敗，不 raise，
--      否則交易回滾會把失敗次數一併抹掉。）
-- ---------------------------------------------------------------------

create function private.set_passcode(p_new text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_new is null or length(p_new) < 4 then
    raise exception using errcode = '22023', message = 'passcode_too_short';
  end if;
  insert into private.app_secrets (key, value)
  values ('passcode_hash', extensions.crypt(p_new, extensions.gen_salt('bf', 8)))
  on conflict (key) do update set value = excluded.value;
end;
$$;

create function private.check_passcode(p_passcode text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_hash   text;
  v_recent integer;
begin
  delete from private.gate_failures where at < now() - interval '1 hour';

  select count(*) into v_recent
  from private.gate_failures
  where at > now() - interval '5 minutes';
  if v_recent >= 60 then
    return 'gate_busy';
  end if;

  select value into v_hash from private.app_secrets where key = 'passcode_hash';
  if v_hash is null then
    return 'gate_not_configured';
  end if;

  if p_passcode is not null and extensions.crypt(p_passcode, v_hash) = v_hash then
    return 'ok';
  end if;

  insert into private.gate_failures default values;
  return 'bad_passcode';
end;
$$;

create function private.sign(p_payload text)
returns text
language sql
stable
set search_path = ''
as $$
  select encode(
    extensions.hmac(
      p_payload,
      (select value from private.app_secrets where key = 'token_secret'),
      'sha256'),
    'hex');
$$;

create function private.issue_token(p_student_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_version integer;
  v_payload text;
begin
  select session_version into v_version
  from private.student_credentials
  where student_id = p_student_id;

  v_payload := p_student_id::text || '.' || v_version::text || '.'
               || extract(epoch from now() + interval '120 days')::bigint::text;
  return v_payload || '.' || private.sign(v_payload);
end;
$$;

create function private.student_from_token(p_token text)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_parts   text[];
  v_id      uuid;
  v_version integer;
begin
  if p_token is null then
    return null;
  end if;

  v_parts := string_to_array(p_token, '.');
  if coalesce(array_length(v_parts, 1), 0) <> 4 then
    return null;
  end if;

  if v_parts[4] <> private.sign(v_parts[1] || '.' || v_parts[2] || '.' || v_parts[3]) then
    return null;
  end if;

  -- 簽章通過代表內容由本資料庫簽發，轉型安全
  v_id      := v_parts[1]::uuid;
  v_version := v_parts[2]::integer;
  if v_parts[3]::bigint < extract(epoch from now())::bigint then
    return null;
  end if;

  if not exists (
    select 1
    from private.student_credentials c
    join public.students s on s.id = c.student_id
    join public.classes  k on k.id = s.class_id
    where c.student_id = v_id
      and c.session_version = v_version
      and s.active and k.active
  ) then
    return null;
  end if;

  return v_id;
end;
$$;

-- 後續步驟的學生端 RPC 以此取得身分；憑證無效時回傳 HTTP 401
create function private.require_student(p_token text)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_id uuid;
begin
  v_id := private.student_from_token(p_token);
  if v_id is null then
    raise exception using errcode = 'PT401', message = 'invalid_session';
  end if;
  return v_id;
end;
$$;

create function private.student_profile(p_student_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id',           s.id,
    'class_id',     k.id,
    'class_name',   k.name,
    'grade',        k.grade,
    'seat',         s.seat,
    'display_name', s.display_name)
  from public.students s
  join public.classes k on k.id = s.class_id
  where s.id = p_student_id;
$$;

create function private.new_initial_code()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_bytes bytea;
  v_code  text;
begin
  loop
    v_bytes := extensions.gen_random_bytes(4);
    v_code := (100000 + (
                 get_byte(v_bytes, 0)::bigint * 16777216
               + get_byte(v_bytes, 1)::bigint * 65536
               + get_byte(v_bytes, 2)::bigint * 256
               + get_byte(v_bytes, 3)::bigint) % 900000)::text;
    exit when (select count(distinct d) from regexp_split_to_table(v_code, '') as d) > 2
          and position(v_code in '0123456789') = 0
          and position(v_code in '9876543210') = 0;
  end loop;
  return v_code;
end;
$$;

-- 核心驗證：通行碼 → 班級座號 → PIN 或初始碼，含錯誤計數與鎖定
create function private.authenticate(
  p_passcode text,
  p_class_id uuid,
  p_seat     integer,
  p_secret   text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_gate    text;
  v_student uuid;
  v_cred    private.student_credentials%rowtype;
  v_match   text;
  v_fails   integer;
begin
  v_gate := private.check_passcode(p_passcode);
  if v_gate <> 'ok' then
    return jsonb_build_object('ok', false, 'error', v_gate);
  end if;

  select s.id into v_student
  from public.students s
  join public.classes k on k.id = s.class_id
  where s.class_id = p_class_id
    and s.seat = p_seat
    and s.active and k.active;

  if v_student is null then
    return jsonb_build_object('ok', false, 'error', 'bad_credentials');
  end if;

  select * into v_cred
  from private.student_credentials
  where student_id = v_student
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'bad_credentials');
  end if;

  if v_cred.locked_until is not null and v_cred.locked_until > now() then
    return jsonb_build_object(
      'ok', false,
      'error', 'locked',
      'retry_after_seconds', ceil(extract(epoch from v_cred.locked_until - now()))::integer);
  end if;

  if p_secret is not null then
    if v_cred.pin_hash is not null then
      if extensions.crypt(p_secret, v_cred.pin_hash) = v_cred.pin_hash then
        v_match := 'pin';
      end if;
    elsif extensions.crypt(p_secret, v_cred.initial_code_hash) = v_cred.initial_code_hash then
      v_match := 'initial_code';
    end if;
  end if;

  if v_match is null then
    v_fails := v_cred.fail_count + 1;
    if v_fails >= 5 then
      update private.student_credentials
      set fail_count = 0, locked_until = now() + interval '15 minutes'
      where student_id = v_student;
      return jsonb_build_object('ok', false, 'error', 'locked', 'retry_after_seconds', 900);
    end if;
    update private.student_credentials
    set fail_count = v_fails
    where student_id = v_student;
    return jsonb_build_object('ok', false, 'error', 'bad_credentials', 'attempts_left', 5 - v_fails);
  end if;

  update private.student_credentials
  set fail_count = 0, locked_until = null
  where student_id = v_student;

  return jsonb_build_object('ok', true, 'matched', v_match, 'student_id', v_student);
end;
$$;

create function private.require_teacher()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if not public.is_teacher() then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 九、public RPC：學生登入流程（anon 可呼叫）
-- ---------------------------------------------------------------------

create function public.is_teacher()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.teachers where user_id = auth.uid());
$$;

-- 第一畫面：驗證通行碼，正確才回傳班級清單
create function public.list_classes(p_passcode text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gate text;
begin
  v_gate := private.check_passcode(p_passcode);
  if v_gate <> 'ok' then
    return jsonb_build_object('ok', false, 'error', v_gate);
  end if;

  return jsonb_build_object(
    'ok', true,
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'grade', k.grade)
                       order by k.grade, k.name)
      from public.classes k
      where k.active), '[]'::jsonb));
end;
$$;

-- 第二畫面：班級＋座號＋（PIN 或 初始碼）
--   PIN 正確       → status = signed_in，附 token
--   初始碼正確     → status = set_pin，前端改顯示設定 PIN 欄位
create function public.student_login(
  p_passcode text,
  p_class_id uuid,
  p_seat     integer,
  p_secret   text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_id   uuid;
begin
  v_auth := private.authenticate(p_passcode, p_class_id, p_seat, p_secret);
  if not (v_auth ->> 'ok')::boolean then
    return v_auth;
  end if;

  if v_auth ->> 'matched' = 'initial_code' then
    return jsonb_build_object('ok', true, 'status', 'set_pin');
  end if;

  v_id := (v_auth ->> 'student_id')::uuid;
  return jsonb_build_object(
    'ok', true,
    'status', 'signed_in',
    'token', private.issue_token(v_id),
    'student', private.student_profile(v_id));
end;
$$;

-- 首次登入：以初始碼換成自己的 4～6 碼 PIN，初始碼隨即失效
create function public.student_activate(
  p_passcode     text,
  p_class_id     uuid,
  p_seat         integer,
  p_initial_code text,
  p_new_pin      text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_id   uuid;
begin
  if p_new_pin is null or p_new_pin !~ '^[0-9]{4,6}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin_format');
  end if;

  v_auth := private.authenticate(p_passcode, p_class_id, p_seat, p_initial_code);
  if not (v_auth ->> 'ok')::boolean then
    return v_auth;
  end if;

  if v_auth ->> 'matched' <> 'initial_code' then
    return jsonb_build_object('ok', false, 'error', 'already_activated');
  end if;

  v_id := (v_auth ->> 'student_id')::uuid;
  update private.student_credentials
  set pin_hash          = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 8)),
      initial_code_hash = null,
      pin_set_at        = now()
  where student_id = v_id;

  return jsonb_build_object(
    'ok', true,
    'status', 'signed_in',
    'token', private.issue_token(v_id),
    'student', private.student_profile(v_id));
end;
$$;

-- 開啟網站時確認手上的 token 是否仍有效
create function public.student_session(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  v_id := private.student_from_token(p_token);
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_session');
  end if;
  return jsonb_build_object('ok', true, 'student', private.student_profile(v_id));
end;
$$;

-- 健康檢查：供監測排程呼叫，執行一次真實查詢
create function public.health_check()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'ok', true,
    'checked_at', now(),
    'active_classes', (select count(*) from public.classes where active));
$$;

-- ---------------------------------------------------------------------
-- 十、public RPC：教師管理（authenticated 且在教師名單內）
-- ---------------------------------------------------------------------

-- 重設學生：產生新的初始碼、清除 PIN、使該生所有舊 token 失效
create function public.teacher_reset_student(p_student_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  perform private.require_teacher();

  if not exists (select 1 from public.students where id = p_student_id) then
    raise exception using errcode = '22023', message = 'student_not_found';
  end if;

  v_code := private.new_initial_code();

  insert into private.student_credentials (student_id, initial_code_hash)
  values (p_student_id, extensions.crypt(v_code, extensions.gen_salt('bf', 8)))
  on conflict (student_id) do update
  set initial_code_hash = excluded.initial_code_hash,
      pin_hash          = null,
      pin_set_at        = null,
      session_version   = private.student_credentials.session_version + 1,
      fail_count        = 0,
      locked_until      = null;

  return jsonb_build_object('ok', true, 'initial_code', v_code)
         || jsonb_build_object('student', private.student_profile(p_student_id));
end;
$$;

-- 名冊匯入（整批成功或整批失敗）
--   p_rows: [{ "school_year":115, "class_name":"電機三乙", "grade":3, "seat":1,
--              "display_name":"（選填）", "initial_code":"（選填，六位數字）" }, ...]
--   新學生若未提供初始碼，系統自動產生；回傳所有新建立憑證的初始碼供列印。
create function public.teacher_import_roster(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r         jsonb;
  v_class   uuid;
  v_student uuid;
  v_code    text;
  v_out     jsonb := '[]'::jsonb;
begin
  perform private.require_teacher();

  if jsonb_typeof(p_rows) <> 'array' then
    raise exception using errcode = '22023', message = 'rows_must_be_array';
  end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    insert into public.classes (school_year, name, grade)
    values ((r ->> 'school_year')::smallint, r ->> 'class_name', (r ->> 'grade')::smallint)
    on conflict (school_year, name) do update
      set grade = excluded.grade, active = true
    returning id into v_class;

    insert into public.students (class_id, seat, display_name)
    values (v_class, (r ->> 'seat')::smallint, nullif(r ->> 'display_name', ''))
    on conflict (class_id, seat) do update
      set display_name = coalesce(excluded.display_name, public.students.display_name),
          active = true
    returning id into v_student;

    if not exists (select 1 from private.student_credentials where student_id = v_student) then
      v_code := coalesce(nullif(r ->> 'initial_code', ''), private.new_initial_code());
      if v_code !~ '^[0-9]{6}$' then
        raise exception using errcode = '22023',
          message = format('invalid_initial_code: %s 座號 %s', r ->> 'class_name', r ->> 'seat');
      end if;
      insert into private.student_credentials (student_id, initial_code_hash)
      values (v_student, extensions.crypt(v_code, extensions.gen_salt('bf', 8)));
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'class_name', r ->> 'class_name',
        'seat', (r ->> 'seat')::integer,
        'initial_code', v_code));
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'new_credentials', v_out);
end;
$$;

-- 更換課程通行碼（建議每學期一次）
create function public.teacher_set_passcode(p_new text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_teacher();
  perform private.set_passcode(p_new);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 十一、RLS
--    anon：不開放任何資料表（學生只走 RPC）
--    authenticated：僅教師名單內的帳號可讀寫內容；學習紀錄教師唯讀
-- ---------------------------------------------------------------------

alter table public.site_settings       enable row level security;
alter table public.semesters           enable row level security;
alter table public.question_categories enable row level security;
alter table public.tag_catalog         enable row level security;
alter table public.classes             enable row level security;
alter table public.students            enable row level security;
alter table public.teachers            enable row level security;
alter table public.courses             enable row level security;
alter table public.course_materials    enable row level security;
alter table public.course_videos       enable row level security;
alter table public.questions           enable row level security;
alter table public.question_keys       enable row level security;
alter table public.course_questions    enable row level security;
alter table public.attempts            enable row level security;
alter table public.favorites           enable row level security;
alter table public.material_views      enable row level security;
alter table public.video_views         enable row level security;

create policy teacher_all on public.site_settings       for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.semesters           for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.question_categories for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.tag_catalog         for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.classes             for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.students            for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.courses             for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.course_materials    for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.course_videos       for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.questions           for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.question_keys       for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy teacher_all on public.course_questions    for all to authenticated using (public.is_teacher()) with check (public.is_teacher());

create policy teacher_read on public.teachers       for select to authenticated using (public.is_teacher());
create policy teacher_read on public.attempts       for select to authenticated using (public.is_teacher());
create policy teacher_read on public.favorites      for select to authenticated using (public.is_teacher());
create policy teacher_read on public.material_views for select to authenticated using (public.is_teacher());
create policy teacher_read on public.video_views    for select to authenticated using (public.is_teacher());

-- ---------------------------------------------------------------------
-- 十二、權限收斂
-- ---------------------------------------------------------------------

-- 資料表：anon 一律不可直接存取
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges for role postgres in schema public revoke all on tables    from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;

-- 函式：先全部收回，再逐一授權
revoke execute on all functions in schema public  from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;

grant execute on function public.list_classes(text)                             to anon, authenticated;
grant execute on function public.student_login(text, uuid, integer, text)       to anon, authenticated;
grant execute on function public.student_activate(text, uuid, integer, text, text) to anon, authenticated;
grant execute on function public.student_session(text)                          to anon, authenticated;
grant execute on function public.health_check()                                 to anon, authenticated;

grant execute on function public.is_teacher()                   to authenticated;
grant execute on function public.teacher_reset_student(uuid)    to authenticated;
grant execute on function public.teacher_import_roster(jsonb)   to authenticated;
grant execute on function public.teacher_set_passcode(text)     to authenticated;
