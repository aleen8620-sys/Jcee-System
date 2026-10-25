-- ============================================================
--  نظام تسجيل الزوار والتذاكر — الإعداد الكامل
--  مشروع جديد: الصق هذا الملف كاملاً في SQL Editor واضغط Run.
--
--  قبل التشغيل: أنشئ حسابك من Authentication ← Users ← Add user
--  مع تفعيل Auto Confirm User، ثم شغّل هذا الملف.
-- ============================================================

-- غيّر هذا السطر إن أردت بريداً آخر مالكاً للنظام
-- (يُستخدم في القسم الأخير)

-- ============================================================
--  1 · الجداول
-- ============================================================

create table if not exists public.events (
  id         uuid primary key default gen_random_uuid(),
  slug       text unique not null,
  name_ar    text not null,
  name_en    text,
  note_ar    text,
  note_en    text,
  logo_url   text,
  accent     text default '#0d5a92',
  opens_at   timestamptz,
  closes_at  timestamptz,
  is_open    boolean not null default true,
  badge      jsonb not null default
    '{"company":true,"title":true,"country":false,"logo":true,
      "phrase_ar":"","phrase_en":"","show_code":true}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.ticket_types (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events(id) on delete cascade,
  code        text not null,
  name_ar     text not null,
  name_en     text,
  price       integer not null default 0 check (price >= 0),  -- بالهللات
  currency    text not null default 'SAR',
  perks_ar    text,
  perks_en    text,
  color       text default '#0d5a92',
  capacity    integer,                                        -- null = بلا حد
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (event_id, code)
);

create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  event_id       uuid not null references public.events(id) on delete cascade,
  ticket_type_id uuid not null references public.ticket_types(id),
  qty            integer not null default 1 check (qty between 1 and 10),
  amount         integer not null check (amount >= 0),
  currency       text    not null default 'SAR',
  status         text    not null default 'pending'
                 check (status in ('pending','paid','failed','refunded','free')),
  buyer_name     text not null,
  buyer_phone    text not null,
  buyer_email    text,
  buyer_company  text,
  buyer_title    text,
  buyer_country  text,
  provider       text default 'moyasar',
  provider_ref   text,
  fail_reason    text,
  created_at     timestamptz not null default now(),
  paid_at        timestamptz
);

create table if not exists public.visitors (
  id             uuid primary key default gen_random_uuid(),
  event_id       uuid not null references public.events(id) on delete cascade,
  code           text unique not null,           -- ٨ أرقام — رمز البوابة
  name           text not null,
  phone          text not null,                  -- 5xxxxxxxx بلا مفتاح الدولة
  email          text,
  company        text,
  job_title      text,
  country        text,
  category       text not null default 'visitor'
                 check (category in ('visitor','exhibitor','media','vip')),
  source         text not null default 'online'
                 check (source in ('online','onsite')),
  order_id       uuid references public.orders(id),
  ticket_type_id uuid references public.ticket_types(id),
  checked_in_at  timestamptz,
  created_at     timestamptz not null default now(),
  -- هذا السطر وحده يمنع التسجيل المكرر في نفس المعرض
  unique (event_id, phone)
);

create table if not exists public.staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  full_name  text,
  role       text not null default 'staff'
             check (role in ('owner','admin','staff','gate')),
  perms      jsonb not null default '{}'::jsonb,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists idx_vis_event_phone on public.visitors(event_id, phone);
create index if not exists idx_vis_code        on public.visitors(code);
create index if not exists idx_vis_created     on public.visitors(event_id, created_at desc);
create index if not exists idx_tt_event        on public.ticket_types(event_id);
create index if not exists idx_ord_event       on public.orders(event_id);
create index if not exists idx_ord_status      on public.orders(status);
create unique index if not exists idx_ord_ref
  on public.orders(provider, provider_ref) where provider_ref is not null;

-- ============================================================
--  2 · من هو الموظف ومن هو المالك
-- ============================================================

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff
                  where user_id = auth.uid() and is_active);
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff
                  where user_id = auth.uid() and is_active
                    and role in ('owner','admin'));
$$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff
                  where user_id = auth.uid() and is_active and role = 'owner');
$$;

create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff s
    where s.user_id = auth.uid() and s.is_active
      and ( s.role in ('owner','admin')
            or coalesce((s.perms ->> p)::boolean, false) )
  );
$$;

revoke all on function public.is_staff()     from public;
revoke all on function public.is_admin()     from public;
revoke all on function public.is_owner()     from public;
revoke all on function public.has_perm(text) from public;
grant execute on function public.is_staff()     to authenticated;
grant execute on function public.is_admin()     to authenticated;
grant execute on function public.is_owner()     to authenticated;
grant execute on function public.has_perm(text) to authenticated;

-- ============================================================
--  3 · حماية الصفوف (RLS)
-- ============================================================

alter table public.events       enable row level security;
alter table public.visitors     enable row level security;
alter table public.staff        enable row level security;
alter table public.ticket_types enable row level security;
alter table public.orders       enable row level security;

drop policy if exists events_staff_read     on public.events;
drop policy if exists visitors_staff_read   on public.visitors;
drop policy if exists visitors_staff_update on public.visitors;
drop policy if exists visitors_admin_delete on public.visitors;
drop policy if exists staff_self_read       on public.staff;
drop policy if exists tt_staff_read         on public.ticket_types;
drop policy if exists ord_staff_read        on public.orders;

create policy events_staff_read on public.events
  for select using (public.is_staff());

create policy visitors_staff_read on public.visitors
  for select using (public.is_staff());

create policy visitors_staff_update on public.visitors
  for update using (public.is_staff());

create policy visitors_admin_delete on public.visitors
  for delete using (public.is_admin());

create policy staff_self_read on public.staff
  for select using (user_id = auth.uid());

create policy tt_staff_read on public.ticket_types
  for select using (public.is_staff());

create policy ord_staff_read on public.orders
  for select using (public.is_staff());

grant usage on schema public to anon, authenticated;
grant select on public.events, public.visitors, public.staff,
                public.ticket_types, public.orders to authenticated;
grant update, delete on public.visitors to authenticated;

-- الزائر العام (anon) لا يملك أي صلاحية على الجداول إطلاقاً.
-- يصل عبر الدوال المصرّح بها فقط.

-- ============================================================
--  4 · توليد رمز فريد
-- ============================================================

create or replace function public.new_code()
returns text language plpgsql security definer set search_path = public as $$
declare c text; taken boolean; i int;
begin
  for i in 1..15 loop
    c := lpad((floor(random() * 100000000))::bigint::text, 8, '0');
    select exists (select 1 from public.visitors where code = c) into taken;
    exit when not taken;
    c := null;
  end loop;
  return c;
end;
$$;

revoke all on function public.new_code() from public;

-- ============================================================
--  5 · بيانات المعرض للصفحة العامة
-- ============================================================

create or replace function public.event_info(p_slug text)
returns json
language plpgsql stable security definer set search_path = public as $$
declare e public.events%rowtype; t json;
begin
  select * into e from public.events where slug = p_slug;
  if not found then
    return json_build_object('ok', false, 'error', 'no_event');
  end if;

  select coalesce(json_agg(x order by x.sort_order, x.price), '[]'::json) into t
  from (
    select tt.code, tt.name_ar, tt.name_en, tt.price, tt.currency,
           tt.perks_ar, tt.perks_en, tt.color, tt.sort_order,
           case
             when tt.capacity is null then null
             else greatest(tt.capacity - coalesce((
               select sum(o.qty) from public.orders o
               where o.ticket_type_id = tt.id
                 and ( o.status in ('paid','free')
                       or (o.status = 'pending'
                           and o.created_at > now() - interval '20 minutes') )
             ), 0), 0)
           end as remaining
    from public.ticket_types tt
    where tt.event_id = e.id and tt.is_active
  ) x;

  return json_build_object(
    'ok', true,
    'slug', e.slug, 'name_ar', e.name_ar, 'name_en', e.name_en,
    'note_ar', e.note_ar, 'note_en', e.note_en,
    'logo_url', e.logo_url, 'accent', coalesce(e.accent, '#0d5a92'),
    'open', (e.is_open
             and (e.opens_at  is null or now() >= e.opens_at)
             and (e.closes_at is null or now() <= e.closes_at)),
    'tickets', t
  );
end;
$$;

revoke all on function public.event_info(text) from public;
grant execute on function public.event_info(text) to anon, authenticated;

-- ============================================================
--  6 · تسجيل مجاني (معرض بلا تذاكر)
-- ============================================================

create or replace function public.register_visitor(
  p_event_slug text,
  p_name       text,
  p_phone      text,
  p_category   text default 'visitor',
  p_email      text default null,
  p_company    text default null,
  p_title      text default null,
  p_country    text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare
  e public.events%rowtype;
  v public.visitors%rowtype;
  v_phone text; v_code text;
begin
  v_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_phone := regexp_replace(v_phone, '^(966|0)+', '');

  if v_phone !~ '^5\d{8}$' then
    return json_build_object('ok', false, 'error', 'bad_phone');
  end if;
  if length(btrim(coalesce(p_name, ''))) < 2 then
    return json_build_object('ok', false, 'error', 'bad_name');
  end if;
  if p_category is null or p_category not in ('visitor','exhibitor','media','vip') then
    p_category := 'visitor';
  end if;

  select * into e from public.events where slug = p_event_slug;
  if not found then
    return json_build_object('ok', false, 'error', 'no_event');
  end if;
  if not e.is_open
     or (e.opens_at  is not null and now() <  e.opens_at)
     or (e.closes_at is not null and now() >  e.closes_at) then
    return json_build_object('ok', false, 'error', 'closed');
  end if;

  select * into v from public.visitors where event_id = e.id and phone = v_phone;
  if found then
    return json_build_object('ok', false, 'error', 'duplicate',
                             'code', v.code, 'name', v.name);
  end if;

  v_code := public.new_code();
  if v_code is null then
    return json_build_object('ok', false, 'error', 'code_fail');
  end if;

  insert into public.visitors
    (event_id, code, name, phone, email, company, job_title, country, category, source)
  values
    (e.id, v_code, btrim(p_name), v_phone,
     nullif(btrim(coalesce(p_email,   '')), ''),
     nullif(btrim(coalesce(p_company, '')), ''),
     nullif(btrim(coalesce(p_title,   '')), ''),
     nullif(btrim(coalesce(p_country, '')), ''),
     p_category, 'online');

  return json_build_object('ok', true, 'code', v_code, 'name', btrim(p_name));

exception when unique_violation then
  select * into v from public.visitors where event_id = e.id and phone = v_phone;
  if found then
    return json_build_object('ok', false, 'error', 'duplicate',
                             'code', v.code, 'name', v.name);
  end if;
  return json_build_object('ok', false, 'error', 'retry');
end;
$$;

revoke all on function public.register_visitor(text,text,text,text,text,text,text,text) from public;
grant execute on function public.register_visitor(text,text,text,text,text,text,text,text)
  to anon, authenticated;

-- ============================================================
--  7 · طلب تذكرة
--     المجانية تصدر رمزاً فوراً. المدفوعة تبقى pending
--     حتى يؤكد الخادم الدفع عبر confirm_payment.
-- ============================================================

create or replace function public.create_order(
  p_event_slug  text,
  p_ticket_code text,
  p_name        text,
  p_phone       text,
  p_email       text default null,
  p_company     text default null,
  p_title       text default null,
  p_country     text default null,
  p_qty         integer default 1
) returns json
language plpgsql security definer set search_path = public as $$
declare
  e public.events%rowtype;
  tt public.ticket_types%rowtype;
  v public.visitors%rowtype;
  v_phone text; v_sold integer; v_code text;
  v_order uuid; v_amount integer;
begin
  v_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_phone := regexp_replace(v_phone, '^(966|0)+', '');

  if v_phone !~ '^5\d{8}$' then
    return json_build_object('ok', false, 'error', 'bad_phone');
  end if;
  if length(btrim(coalesce(p_name, ''))) < 2 then
    return json_build_object('ok', false, 'error', 'bad_name');
  end if;
  if p_qty is null or p_qty < 1 or p_qty > 10 then p_qty := 1; end if;

  select * into e from public.events where slug = p_event_slug;
  if not found then
    return json_build_object('ok', false, 'error', 'no_event');
  end if;
  if not e.is_open
     or (e.opens_at  is not null and now() <  e.opens_at)
     or (e.closes_at is not null and now() >  e.closes_at) then
    return json_build_object('ok', false, 'error', 'closed');
  end if;

  -- قفل نوع التذكرة لمنع تجاوز السعة عند الطلبات المتزامنة
  select * into tt from public.ticket_types
   where event_id = e.id and code = p_ticket_code and is_active
   for update;
  if not found then
    return json_build_object('ok', false, 'error', 'no_ticket_type');
  end if;

  if tt.capacity is not null then
    select coalesce(sum(o.qty), 0) into v_sold
    from public.orders o
    where o.ticket_type_id = tt.id
      and ( o.status in ('paid','free')
            or (o.status = 'pending' and o.created_at > now() - interval '20 minutes') );
    if v_sold + p_qty > tt.capacity then
      return json_build_object('ok', false, 'error', 'sold_out',
                               'remaining', greatest(tt.capacity - v_sold, 0));
    end if;
  end if;

  select * into v from public.visitors where event_id = e.id and phone = v_phone;
  if found then
    return json_build_object('ok', false, 'error', 'duplicate',
                             'code', v.code, 'name', v.name);
  end if;

  v_amount := tt.price * p_qty;

  insert into public.orders
    (event_id, ticket_type_id, qty, amount, currency, status,
     buyer_name, buyer_phone, buyer_email, buyer_company, buyer_title, buyer_country)
  values
    (e.id, tt.id, p_qty, v_amount, tt.currency,
     case when v_amount = 0 then 'free' else 'pending' end,
     btrim(p_name), v_phone,
     nullif(btrim(coalesce(p_email,   '')), ''),
     nullif(btrim(coalesce(p_company, '')), ''),
     nullif(btrim(coalesce(p_title,   '')), ''),
     nullif(btrim(coalesce(p_country, '')), ''))
  returning id into v_order;

  if v_amount = 0 then
    v_code := public.new_code();
    if v_code is null then
      return json_build_object('ok', false, 'error', 'code_fail');
    end if;
    insert into public.visitors
      (event_id, code, name, phone, email, company, job_title, country,
       category, source, order_id, ticket_type_id)
    values
      (e.id, v_code, btrim(p_name), v_phone,
       nullif(btrim(coalesce(p_email,   '')), ''),
       nullif(btrim(coalesce(p_company, '')), ''),
       nullif(btrim(coalesce(p_title,   '')), ''),
       nullif(btrim(coalesce(p_country, '')), ''),
       'visitor', 'online', v_order, tt.id);
    update public.orders set paid_at = now() where id = v_order;

    return json_build_object('ok', true, 'paid', true, 'free', true,
                             'order_id', v_order, 'code', v_code,
                             'amount', 0, 'ticket', tt.name_ar);
  end if;

  return json_build_object('ok', true, 'paid', false, 'free', false,
                           'order_id', v_order, 'amount', v_amount,
                           'currency', tt.currency, 'ticket', tt.name_ar);

exception when unique_violation then
  select * into v from public.visitors where event_id = e.id and phone = v_phone;
  if found then
    return json_build_object('ok', false, 'error', 'duplicate',
                             'code', v.code, 'name', v.name);
  end if;
  return json_build_object('ok', false, 'error', 'retry');
end;
$$;

revoke all on function public.create_order(text,text,text,text,text,text,text,text,integer) from public;
grant execute on function public.create_order(text,text,text,text,text,text,text,text,integer)
  to anon, authenticated;

-- ============================================================
--  8 · تأكيد الدفع — للخادم وحده
--     تُستدعى من دالة Vercel بمفتاح service_role بعد التحقق من مُيسِّر.
--     لا grant لأحد: anon و authenticated لا يستطيعان تنفيذها.
-- ============================================================

create or replace function public.confirm_payment(
  p_order_id uuid,
  p_ref      text,
  p_status   text default 'paid',
  p_reason   text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare o public.orders%rowtype; v_code text;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found then
    return json_build_object('ok', false, 'error', 'no_order');
  end if;

  if p_status <> 'paid' then
    update public.orders
       set status = 'failed', provider_ref = p_ref, fail_reason = p_reason
     where id = o.id and status = 'pending';
    return json_build_object('ok', true, 'status', 'failed');
  end if;

  -- مدفوع سابقاً: أعد نفس الرمز بدل إصدار آخر
  if o.status in ('paid','free') then
    select code into v_code from public.visitors where order_id = o.id limit 1;
    return json_build_object('ok', true, 'status', 'paid',
                             'code', v_code, 'already', true);
  end if;

  v_code := public.new_code();
  if v_code is null then
    return json_build_object('ok', false, 'error', 'code_fail');
  end if;

  insert into public.visitors
    (event_id, code, name, phone, email, company, job_title, country,
     category, source, order_id, ticket_type_id)
  values
    (o.event_id, v_code, o.buyer_name, o.buyer_phone, o.buyer_email,
     o.buyer_company, o.buyer_title, o.buyer_country,
     'visitor', 'online', o.id, o.ticket_type_id);

  update public.orders
     set status = 'paid', provider_ref = p_ref, paid_at = now()
   where id = o.id;

  return json_build_object('ok', true, 'status', 'paid', 'code', v_code);
end;
$$;

revoke all on function public.confirm_payment(uuid,text,text,text) from public;

-- ============================================================
--  9 · حالة الطلب (بعد العودة من بوابة الدفع)
-- ============================================================

create or replace function public.order_status(p_order_id uuid)
returns json
language plpgsql stable security definer set search_path = public as $$
declare o public.orders%rowtype; v_code text;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    return json_build_object('ok', false, 'error', 'no_order');
  end if;
  select code into v_code from public.visitors where order_id = o.id limit 1;
  return json_build_object('ok', true, 'status', o.status, 'code', v_code,
                           'name', o.buyer_name, 'amount', o.amount);
end;
$$;

revoke all on function public.order_status(uuid) from public;
grant execute on function public.order_status(uuid) to anon, authenticated;

-- ============================================================
--  10 · البوابة والتسجيل السريع
-- ============================================================

create or replace function public.do_checkin(p_code text)
returns json
language plpgsql security definer set search_path = public as $$
declare v public.visitors%rowtype; v_code text; e public.events%rowtype;
begin
  if not public.is_staff() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;

  v_code := regexp_replace(coalesce(p_code, ''), '\D', '', 'g');
  if length(v_code) <> 8 then
    return json_build_object('ok', false, 'error', 'bad_code');
  end if;

  select * into v from public.visitors where visitors.code = v_code for update;
  if not found then
    return json_build_object('ok', false, 'error', 'not_found');
  end if;

  select * into e from public.events where id = v.event_id;

  if v.checked_in_at is not null then
    return json_build_object('ok', false, 'error', 'already',
                             'name', v.name, 'event', e.name_ar,
                             'at', v.checked_in_at);
  end if;

  update public.visitors set checked_in_at = now() where id = v.id;

  return json_build_object('ok', true, 'name', v.name, 'event', e.name_ar,
                           'category', v.category, 'company', v.company);
end;
$$;

revoke all on function public.do_checkin(text) from public;
grant execute on function public.do_checkin(text) to authenticated;


create or replace function public.quick_register(
  p_event_slug text, p_name text, p_phone text
) returns json
language plpgsql security definer set search_path = public as $$
declare r json;
begin
  if not public.is_staff() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  r := public.register_visitor(p_event_slug, p_name, p_phone, 'visitor');
  if (r->>'ok')::boolean then
    update public.visitors set source = 'onsite' where code = r->>'code';
  end if;
  return r;
end;
$$;

revoke all on function public.quick_register(text,text,text) from public;
grant execute on function public.quick_register(text,text,text) to authenticated;

-- ============================================================
--  11 · إدارة المعارض
-- ============================================================

create or replace function public.list_events()
returns json
language plpgsql stable security definer set search_path = public as $$
declare r json;
begin
  if not public.is_staff() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;

  select coalesce(json_agg(x order by x.created_at desc), '[]'::json) into r
  from (
    select e.id, e.slug, e.name_ar, e.name_en, e.opens_at, e.closes_at,
           e.is_open, e.logo_url, e.note_ar, e.note_en,
           coalesce(e.accent, '#0d5a92') as accent, e.badge, e.created_at,
           (select count(*) from public.visitors v where v.event_id = e.id) as registered,
           (select count(*) from public.visitors v
             where v.event_id = e.id and v.checked_in_at is not null) as attended
    from public.events e
  ) x;

  return json_build_object('ok', true, 'events', r);
end;
$$;

revoke all on function public.list_events() from public;
grant execute on function public.list_events() to authenticated;


create or replace function public.save_event(
  p_id uuid default null, p_slug text default null,
  p_name_ar text default null, p_name_en text default null,
  p_opens timestamptz default null, p_closes timestamptz default null,
  p_is_open boolean default true, p_logo text default null,
  p_note_ar text default null, p_note_en text default null,
  p_accent text default '#0d5a92', p_badge jsonb default null
) returns json
language plpgsql security definer set search_path = public as $$
declare v_slug text; v_id uuid;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  if length(btrim(coalesce(p_name_ar, ''))) < 2 then
    return json_build_object('ok', false, 'error', 'bad_name');
  end if;

  v_slug := lower(btrim(coalesce(p_slug, '')));
  v_slug := regexp_replace(v_slug, '[^a-z0-9\-]+', '-', 'g');
  v_slug := regexp_replace(v_slug, '(^-+|-+$)', '', 'g');
  if length(v_slug) < 2 then
    return json_build_object('ok', false, 'error', 'bad_slug');
  end if;

  if p_id is null then
    if exists (select 1 from public.events where slug = v_slug) then
      return json_build_object('ok', false, 'error', 'slug_taken');
    end if;
    insert into public.events
      (slug, name_ar, name_en, opens_at, closes_at, is_open,
       logo_url, note_ar, note_en, accent, badge)
    values
      (v_slug, btrim(p_name_ar), nullif(btrim(coalesce(p_name_en,'')),''),
       p_opens, p_closes, coalesce(p_is_open, true),
       nullif(btrim(coalesce(p_logo,'')),''),
       nullif(btrim(coalesce(p_note_ar,'')),''),
       nullif(btrim(coalesce(p_note_en,'')),''),
       coalesce(p_accent, '#0d5a92'),
       coalesce(p_badge, '{"company":true,"title":true,"country":false,"logo":true,
                           "phrase_ar":"","phrase_en":"","show_code":true}'::jsonb))
    returning id into v_id;
  else
    if exists (select 1 from public.events where slug = v_slug and id <> p_id) then
      return json_build_object('ok', false, 'error', 'slug_taken');
    end if;
    update public.events set
      slug = v_slug, name_ar = btrim(p_name_ar),
      name_en  = nullif(btrim(coalesce(p_name_en,'')),''),
      opens_at = p_opens, closes_at = p_closes,
      is_open  = coalesce(p_is_open, true),
      logo_url = nullif(btrim(coalesce(p_logo,'')),''),
      note_ar  = nullif(btrim(coalesce(p_note_ar,'')),''),
      note_en  = nullif(btrim(coalesce(p_note_en,'')),''),
      accent   = coalesce(p_accent, '#0d5a92'),
      badge    = coalesce(p_badge, badge)
    where id = p_id
    returning id into v_id;
    if v_id is null then
      return json_build_object('ok', false, 'error', 'not_found');
    end if;
  end if;

  return json_build_object('ok', true, 'id', v_id, 'slug', v_slug);
end;
$$;

revoke all on function public.save_event(uuid,text,text,text,timestamptz,timestamptz,boolean,text,text,text,text,jsonb) from public;
grant execute on function public.save_event(uuid,text,text,text,timestamptz,timestamptz,boolean,text,text,text,text,jsonb) to authenticated;


create or replace function public.delete_event(p_id uuid)
returns json
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  select count(*) into n from public.visitors where event_id = p_id;
  if n > 0 then
    return json_build_object('ok', false, 'error', 'has_visitors', 'count', n);
  end if;
  delete from public.events where id = p_id;
  return json_build_object('ok', true);
end;
$$;

revoke all on function public.delete_event(uuid) from public;
grant execute on function public.delete_event(uuid) to authenticated;

-- ============================================================
--  12 · إدارة أنواع التذاكر والمبيعات
-- ============================================================

create or replace function public.save_ticket_type(
  p_event_slug text, p_code text, p_name_ar text, p_price integer,
  p_name_en text default null, p_perks_ar text default null,
  p_color text default '#0d5a92', p_capacity integer default null,
  p_sort integer default 0, p_active boolean default true
) returns json
language plpgsql security definer set search_path = public as $$
declare e public.events%rowtype; v_id uuid; v_code text;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  if p_price is null or p_price < 0 then
    return json_build_object('ok', false, 'error', 'bad_price');
  end if;

  v_code := lower(regexp_replace(btrim(coalesce(p_code,'')), '[^a-z0-9\-]+', '-', 'g'));
  if length(v_code) < 2 then
    return json_build_object('ok', false, 'error', 'bad_code');
  end if;

  select * into e from public.events where slug = p_event_slug;
  if not found then
    return json_build_object('ok', false, 'error', 'no_event');
  end if;

  insert into public.ticket_types
    (event_id, code, name_ar, name_en, price, perks_ar, color,
     capacity, sort_order, is_active)
  values
    (e.id, v_code, btrim(p_name_ar),
     nullif(btrim(coalesce(p_name_en,'')),''), p_price,
     nullif(btrim(coalesce(p_perks_ar,'')),''),
     coalesce(p_color, '#0d5a92'), p_capacity,
     coalesce(p_sort, 0), coalesce(p_active, true))
  on conflict (event_id, code) do update set
     name_ar = excluded.name_ar, name_en = excluded.name_en,
     price = excluded.price, perks_ar = excluded.perks_ar,
     color = excluded.color, capacity = excluded.capacity,
     sort_order = excluded.sort_order, is_active = excluded.is_active
  returning id into v_id;

  return json_build_object('ok', true, 'id', v_id, 'code', v_code);
end;
$$;

revoke all on function public.save_ticket_type(text,text,text,integer,text,text,text,integer,integer,boolean) from public;
grant execute on function public.save_ticket_type(text,text,text,integer,text,text,text,integer,integer,boolean) to authenticated;


create or replace function public.sales_report(p_event_slug text)
returns json
language plpgsql stable security definer set search_path = public as $$
declare e public.events%rowtype; r json; tot json;
begin
  if not public.is_staff() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  select * into e from public.events where slug = p_event_slug;
  if not found then
    return json_build_object('ok', false, 'error', 'no_event');
  end if;

  select coalesce(json_agg(x order by x.sort_order), '[]'::json) into r
  from (
    select tt.name_ar, tt.price, tt.sort_order,
           count(o.id) filter (where o.status in ('paid','free')) as orders_count,
           coalesce(sum(o.qty)    filter (where o.status in ('paid','free')), 0) as tickets,
           coalesce(sum(o.amount) filter (where o.status = 'paid'), 0) as revenue
    from public.ticket_types tt
    left join public.orders o on o.ticket_type_id = tt.id
    where tt.event_id = e.id
    group by tt.id, tt.name_ar, tt.price, tt.sort_order
  ) x;

  select json_build_object(
    'tickets', coalesce(sum(qty) filter (where status in ('paid','free')), 0),
    'revenue', coalesce(sum(amount) filter (where status = 'paid'), 0),
    'pending', count(*) filter (where status = 'pending'),
    'failed',  count(*) filter (where status = 'failed')
  ) into tot
  from public.orders where event_id = e.id;

  return json_build_object('ok', true, 'by_type', r, 'totals', tot);
end;
$$;

revoke all on function public.sales_report(text) from public;
grant execute on function public.sales_report(text) to authenticated;

-- ============================================================
--  13 · الموظفون والصلاحيات — المالك وحده يضيف ويعدّل
-- ============================================================

create or replace function public.list_staff()
returns json
language plpgsql stable security definer set search_path = public as $$
declare r json;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  select coalesce(json_agg(x order by x.created_at), '[]'::json) into r
  from (
    select s.user_id, s.full_name, s.role, s.perms, s.is_active,
           u.email, s.created_at
    from public.staff s join auth.users u on u.id = s.user_id
  ) x;
  return json_build_object('ok', true, 'staff', r, 'am_owner', public.is_owner());
end;
$$;

revoke all on function public.list_staff() from public;
grant execute on function public.list_staff() to authenticated;


create or replace function public.set_staff(
  p_email text, p_name text default null, p_role text default 'staff',
  p_perms jsonb default '{}'::jsonb, p_active boolean default true
) returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
  if not public.is_owner() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  if p_role not in ('owner','admin','staff','gate') then
    return json_build_object('ok', false, 'error', 'bad_role');
  end if;

  select id into v_uid from auth.users where lower(email) = lower(btrim(p_email));
  if v_uid is null then
    return json_build_object('ok', false, 'error', 'no_user');
  end if;

  -- لا يُنزّل المالك نفسه إن كان المالك الوحيد
  if v_uid = auth.uid() and p_role <> 'owner' then
    if (select count(*) from public.staff where role = 'owner' and is_active) <= 1 then
      return json_build_object('ok', false, 'error', 'last_owner');
    end if;
  end if;

  insert into public.staff (user_id, full_name, role, perms, is_active)
  values (v_uid, coalesce(nullif(btrim(coalesce(p_name,'')),''), p_email),
          p_role, coalesce(p_perms, '{}'::jsonb), coalesce(p_active, true))
  on conflict (user_id) do update set
    full_name = coalesce(nullif(btrim(coalesce(excluded.full_name,'')),''),
                         public.staff.full_name),
    role = excluded.role, perms = excluded.perms, is_active = excluded.is_active;

  return json_build_object('ok', true);
end;
$$;

revoke all on function public.set_staff(text,text,text,jsonb,boolean) from public;
grant execute on function public.set_staff(text,text,text,jsonb,boolean) to authenticated;

-- ============================================================
--  14 · معرض تجريبي بثلاث فئات تذاكر
-- ============================================================

insert into public.events (slug, name_ar, name_en, note_ar, accent)
values ('demo-2027', 'معرض تجريبي', 'Demo Expo',
        'سجّل بياناتك ويصلك رمز الدخول فوراً', '#0d5a92')
on conflict (slug) do nothing;

insert into public.ticket_types (event_id, code, name_ar, price, perks_ar, color, sort_order)
select id, 'standard', 'تذكرة عادية', 0,
       'دخول المعرض في أيام العرض', '#0d5a92', 1
from public.events where slug = 'demo-2027'
on conflict (event_id, code) do nothing;

insert into public.ticket_types (event_id, code, name_ar, price, perks_ar, color, sort_order)
select id, 'fast', 'المسار السريع', 15000,
       'دخول من بوابة مخصصة بلا انتظار', '#8a5510', 2
from public.events where slug = 'demo-2027'
on conflict (event_id, code) do nothing;

insert into public.ticket_types (event_id, code, name_ar, price, perks_ar, color, capacity, sort_order)
select id, 'vip', 'كبار الشخصيات', 50000,
       'مسار خاص · مقعد محجوز · ضيافة', '#8a6410', 50, 3
from public.events where slug = 'demo-2027'
on conflict (event_id, code) do nothing;

-- ============================================================
--  15 · حساب المالك — يُنشأ تلقائياً
--
--     غيّر القيم الثلاث أدناه إن أردت، ثم شغّل الملف.
--     إعادة التشغيل لا تُنشئ حساباً مكرراً — تحدّث كلمة المرور فقط.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

do $$
declare
  -- ↓↓↓ بيانات المالك ↓↓↓
  v_email text := 'aleen8620@gmail.com';
  v_pass  text := 'Aleen#2027';
  v_name  text := 'Aleen';
  -- ↑↑↑ غيّرها هنا ↑↑↑

  v_uid     uuid;
  v_schema  text;
  v_hash    text;
  v_has_pid boolean;
begin
  -- أين تعيش دالة crypt في هذا المشروع
  select n.nspname into v_schema
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where p.proname = 'crypt'
  order by (n.nspname = 'extensions') desc
  limit 1;

  if v_schema is null then
    raise exception 'pgcrypto غير مفعّل';
  end if;

  execute format('select %I.crypt($1, %I.gen_salt(''bf''))', v_schema, v_schema)
    into v_hash using v_pass;

  select id into v_uid from auth.users where email = lower(v_email);

  if v_uid is null then
    v_uid := gen_random_uuid();

    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    ) values (
      '00000000-0000-0000-0000-000000000000', v_uid,
      'authenticated', 'authenticated', lower(v_email), v_hash,
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('full_name', v_name),
      now(), now()
    );

    -- جدول identities اختلف بين إصدارات Supabase — نتعامل مع الحالتين
    select exists (
      select 1 from information_schema.columns
      where table_schema = 'auth' and table_name = 'identities'
        and column_name = 'provider_id'
    ) into v_has_pid;

    if v_has_pid then
      execute format(
        'insert into auth.identities (id, user_id, identity_data, provider, provider_id,
           last_sign_in_at, created_at, updated_at)
         values (%L, %L, %L::jsonb, %L, %L, now(), now(), now())',
        gen_random_uuid(), v_uid,
        jsonb_build_object('sub', v_uid::text, 'email', lower(v_email))::text,
        'email', v_uid::text);
    else
      execute format(
        'insert into auth.identities (id, user_id, identity_data, provider,
           last_sign_in_at, created_at, updated_at)
         values (%L, %L, %L::jsonb, %L, now(), now(), now())',
        gen_random_uuid(), v_uid,
        jsonb_build_object('sub', v_uid::text, 'email', lower(v_email))::text,
        'email');
    end if;

    raise notice '>>> أُنشئ حساب المالك: %', v_email;
  else
    update auth.users
       set encrypted_password = v_hash,
           email_confirmed_at = coalesce(email_confirmed_at, now()),
           updated_at = now()
     where id = v_uid;
    raise notice '>>> الحساب موجود — حُدّثت كلمة المرور: %', v_email;
  end if;

  insert into public.staff (user_id, full_name, role, is_active)
  values (v_uid, v_name, 'owner', true)
  on conflict (user_id) do update
    set role = 'owner', full_name = excluded.full_name, is_active = true;
end $$;

-- ============================================================
--  16 · تحقق نهائي
-- ============================================================

select 'المعارض' as "النوع", count(*)::text as "العدد" from public.events
union all
select 'أنواع التذاكر', count(*)::text from public.ticket_types
union all
select 'الموظفون', count(*)::text from public.staff
union all
select 'المالك', coalesce(string_agg(u.email, ', '), '— لم يُعيَّن بعد')
  from public.staff s join auth.users u on u.id = s.user_id where s.role = 'owner';
