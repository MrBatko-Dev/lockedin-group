-- Update 30: each member can set a break-even value, and their group sees their P&L calendar with it.
-- Run ONCE in Supabase > SQL Editor > New query > paste > Run (after update 29). Then push the website.
-- Safe to run again.
--
-- A day with a P&L from $0 up to (not including) the value counts as break even in that member's calendar.
-- The value lives on the member's name row (public.members), which the whole group can already read.
-- Only the member changes it, through set_be_limit(). Group owners can still rename people, but the
-- trigger below keeps them from setting or changing anyone else's break-even value.

alter table public.members add column if not exists be_limit numeric;
alter table public.members drop constraint if exists members_be_limit_check;
alter table public.members add constraint members_be_limit_check check (be_limit is null or (be_limit >= 0 and be_limit <= 100000));

-- The value only changes from inside set_be_limit() (or by the app owner). A new name never comes with one,
-- so a group owner can't add a name with a value and then approve someone onto it.
create or replace function public.protect_be_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() and coalesce(current_setting('lockedin.set_be', true), '') <> 'on' then
    if tg_op = 'INSERT' then new.be_limit := null;
    elsif new.be_limit is distinct from old.be_limit then new.be_limit := old.be_limit;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists members_protect_be on public.members;
create trigger members_protect_be before insert or update on public.members
  for each row execute function public.protect_be_limit();
revoke all on function public.protect_be_limit() from public, anon, authenticated;

-- Sets your break-even value on every name you hold (one per group you are approved in).
-- null switches it off.
create or replace function public.set_be_limit(v numeric) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if v is not null and (v < 0 or v > 100000) then raise exception 'The break-even value must be between 0 and 100,000'; end if;
  perform set_config('lockedin.set_be', 'on', true);
  update public.members m set be_limit = v
  where m.key in (select ms.member_key from public.memberships ms
                  where ms.user_id = auth.uid() and ms.status = 'approved' and ms.member_key is not null);
  perform set_config('lockedin.set_be', '', true);
end;
$$;
revoke all on function public.set_be_limit(numeric) from public, anon;
grant execute on function public.set_be_limit(numeric) to authenticated;

select 'Update 30 done: members can set a break-even value.' as result;
