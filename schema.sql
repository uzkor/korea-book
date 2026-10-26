-- Korea_Book Challenge: Supabase schema (SQL Editor -> New query -> Run)
create table admins(email text primary key);
insert into admins values('shakhzod990509@gmail.com');

create or replace function is_admin() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from admins where lower(email)=lower(coalesce(auth.jwt()->>'email',''))) $$;

create table comp(id int primary key default 1 check(id=1), title text default 'Korea_Book Challenge', descr text default '', rules text default '',
 status text default 'upcoming' check(status in ('upcoming','live','paused','finished')), max_size int default 4 check(max_size between 1 and 20), any_member boolean default false, hidden boolean default true);
insert into comp(descr,rules) values('Jamoaviy koreys tili musobaqasi.','Har bir savolga jamoa bitta rasmiy javob yuboradi.');

create table teams(id uuid primary key default gen_random_uuid(), name text not null unique check(length(name) between 1 and 40), color text default '#1d4ed8', code text not null unique, cap uuid, created timestamptz default now());
create table members(id uuid primary key, name text not null, team_id uuid not null references teams(id) on delete cascade, joined timestamptz default now());
create unique index members_name on members(lower(name));

create or replace function my_team() returns uuid language sql stable security definer set search_path=public as $$ select team_id from members where id=auth.uid() $$;

create table questions(id uuid primary key default gen_random_uuid(), title text not null, descr text default '', ko text default '', qtype text default 'open',
 pts int not null check(pts>0), secs int not null check(secs>=10), status text default 'draft' check(status in ('draft','published','closed')),
 deadline timestamptz, paused boolean default false, left_ms int default 0, revealed boolean default false, ord bigint default (extract(epoch from now())*1000)::bigint);
create table question_keys(qid uuid primary key references questions(id) on delete cascade, answer text default '');
create table submissions(id uuid primary key default gen_random_uuid(), qid uuid references questions(id) on delete cascade, team_id uuid references teams(id) on delete cascade,
 body text not null check(length(body) between 1 and 1000), by_name text, at timestamptz default now(), unique(qid,team_id));
create table scores(qid uuid references questions(id) on delete cascade, team_id uuid references teams(id) on delete cascade, score numeric not null check(score>=0), fb text default '', published boolean default false, primary key(qid,team_id));
create table score_history(id uuid primary key default gen_random_uuid(), qid uuid, team_id uuid, old_score numeric, new_score numeric, at timestamptz default now());
create table messages(id uuid primary key default gen_random_uuid(), team_id uuid references teams(id) on delete cascade, uid uuid, name text, body text check(length(body) between 1 and 500), at timestamptz default now());

create or replace function check_score() returns trigger language plpgsql as $$
begin if new.score>(select pts from questions where id=new.qid) then raise exception 'Ball maksimaldan oshmasligi kerak'; end if; return new; end $$;
create trigger scores_chk before insert or update on scores for each row execute function check_score();

create view teams_pub as select t.id,t.name,t.color,t.cap,(select count(*) from members m where m.team_id=t.id)::int as n from teams t;
grant select on teams_pub to anon, authenticated;

alter table comp enable row level security; alter table teams enable row level security; alter table members enable row level security; alter table questions enable row level security;
alter table question_keys enable row level security; alter table submissions enable row level security; alter table scores enable row level security; alter table score_history enable row level security; alter table messages enable row level security; alter table admins enable row level security;

create policy comp_r on comp for select to authenticated using(true);
create policy comp_a on comp for all to authenticated using(is_admin()) with check(is_admin());
create policy teams_a on teams for all to authenticated using(is_admin()) with check(is_admin());
create policy members_r on members for select to authenticated using(is_admin() or team_id=my_team() or id=auth.uid());
create policy members_a on members for all to authenticated using(is_admin()) with check(is_admin());
create policy q_r on questions for select to authenticated using(status<>'draft' or is_admin());
create policy q_a on questions for all to authenticated using(is_admin()) with check(is_admin());
create policy k_r on question_keys for select to authenticated using(is_admin() or exists(select 1 from questions q where q.id=qid and q.revealed));
create policy k_a on question_keys for all to authenticated using(is_admin()) with check(is_admin());
create policy s_r on submissions for select to authenticated using(is_admin() or team_id=my_team());
create policy s_a on submissions for all to authenticated using(is_admin()) with check(is_admin());
create policy sc_r on scores for select to authenticated using(is_admin() or published);
create policy sc_a on scores for all to authenticated using(is_admin()) with check(is_admin());
create policy h_a on score_history for all to authenticated using(is_admin()) with check(is_admin());
create policy m_r on messages for select to authenticated using(is_admin() or team_id=my_team());
create policy m_i on messages for insert to authenticated with check(team_id=my_team() and uid=auth.uid());
create policy m_a on messages for delete to authenticated using(is_admin());

create or replace function server_now() returns timestamptz language sql stable as $$ select now() $$;

create or replace function join_team(p_code text,p_name text) returns text language plpgsql security definer set search_path=public as $$
declare t teams; m members; mx int; n int; nm text:=trim(p_name);
begin
 if auth.uid() is null then return 'Avval kiring'; end if;
 if length(nm) not between 1 and 40 then return 'Ism noto‘g‘ri'; end if;
 select * into t from teams where code=upper(trim(p_code)); if not found then return 'Kod noto‘g‘ri'; end if;
 perform 1 from teams where id=t.id for update;
 select max_size into mx from comp;
 select * into m from members where lower(name)=lower(nm);
 if found and m.id<>auth.uid() then
  if m.team_id<>t.id then return 'Bu ism boshqa jamoada band'; end if;
  delete from members where id=auth.uid();
  update teams set cap=auth.uid() where cap=m.id;
  update members set id=auth.uid() where id=m.id; return 'ok';
 end if;
 select count(*) into n from members where team_id=t.id and id<>auth.uid();
 if n>=mx then return 'Jamoa to‘lgan'; end if;
 insert into members(id,name,team_id) values(auth.uid(),nm,t.id) on conflict (id) do update set name=excluded.name, team_id=excluded.team_id;
 return 'ok';
end $$;

create or replace function submit_answer(p_qid uuid,p_text text) returns text language plpgsql security definer set search_path=public as $$
declare q questions; c comp; m members; t teams;
begin
 select * into m from members where id=auth.uid(); if not found then return 'Jamoa topilmadi'; end if;
 select * into c from comp; select * into q from questions where id=p_qid;
 if q.status<>'published' or c.status<>'live' or q.paused or q.deadline is null or now()>q.deadline then return 'Vaqt tugadi'; end if;
 select * into t from teams where id=m.team_id;
 if not (t.cap=auth.uid() or c.any_member) then return 'Faqat kapitan javob yuboradi'; end if;
 insert into submissions(qid,team_id,body,by_name) values(p_qid,m.team_id,left(trim(p_text),1000),m.name);
 return 'ok';
exception when unique_violation then return 'Allaqachon yuborilgan'; when check_violation then return 'Javob bo‘sh';
end $$;

create or replace function q_action(p_qid uuid,act text) returns text language plpgsql security definer set search_path=public as $$
declare c comp;
begin
 if not is_admin() then raise exception 'Ruxsat yo‘q'; end if;
 select * into c from comp;
 if act='publish' then
  if c.status<>'live' then return 'Avval musobaqani boshlang'; end if;
  update questions set status='closed',paused=false where status='published' and id<>p_qid;
  update questions set status='published',deadline=now()+make_interval(secs=>secs),paused=false,left_ms=0 where id=p_qid;
 elsif act='pause' then
  update questions set paused=true,left_ms=greatest(0,(extract(epoch from deadline-now())*1000)::int) where id=p_qid and status='published' and not paused;
 elsif act='resume' then
  update questions set paused=false,deadline=now()+make_interval(secs=>left_ms/1000.0) where id=p_qid and paused;
 elsif act='extend' then
  update questions set left_ms=left_ms+30000 where id=p_qid and paused;
  update questions set deadline=greatest(deadline,now())+interval '30 seconds' where id=p_qid and not paused and status='published';
 elsif act='close' then update questions set status='closed' where id=p_qid;
 end if;
 return 'ok';
end $$;

alter publication supabase_realtime add table comp, questions, submissions, scores, messages, members;
