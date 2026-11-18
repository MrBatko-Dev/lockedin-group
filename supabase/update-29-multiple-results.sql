-- Update 29: a day can have more than one result, like a loss and a break even trade on the same day.
-- Run ONCE in Supabase > SQL Editor > New query > paste > Run (after update 28). Then push the website.
-- Safe to run again.
--
-- The result column keeps its name and type. It now holds one result or several, joined by commas in a fixed
-- order: win, loss, breakeven, gamble. So "loss,breakeven" is allowed, "breakeven,loss" and "win,win" are not
-- (the website always saves them in that order). No trade still stands alone. No saved result changes.
-- Who may change a result stays exactly as before: your own row, while the day is open.
-- The weekly and monthly Discord rankings now count a day with a win and a loss as 1W and 1L.

alter table public.ticks drop constraint if exists ticks_result_check;
alter table public.ticks add constraint ticks_result_check
  check (result ~ '^(win(,loss)?(,breakeven)?(,gamble)?|loss(,breakeven)?(,gamble)?|breakeven(,gamble)?|gamble)$');

-- ================================================================ Discord rankings
-- Same function as update 24. Only the two win and loss counts change, from "result = 'win'"
-- to "win is one of the day's results".
create or replace function public.due_recaps(at_time timestamptz default now())
returns table (group_id text, url text, kind text, content text)
language plpgsql volatile security definer set search_path = public as $$
declare
  gd record; d date; lc date; closes timestamptz; mins int; mon date;
  total int; done int; todo text; lines text; n int; body text;
  sd record; ms date; nd date; lc_first date; all_closed timestamptz;
begin
  for gd in
    select x.*, g.name as gname, g.boxes, g.status as gstatus
    from public.group_discord x join public.groups g on g.id = x.group_id
    where g.status = 'active'
    for update of x skip locked
  loop
    d := public.trading_day_at(gd.group_id, at_time);
    closes := public.day_closes_at(gd.group_id, d);

    -- daily: shortly before the day closes
    if gd.daily and at_time >= closes - make_interval(mins => gd.lead_minutes) and at_time < closes
       and gd.last_daily is distinct from d then
      select count(*) filter (where not coalesce(t.excused, false)),
             count(*) filter (where not coalesce(t.excused, false) and public.day_done(gd.boxes, t)),
             string_agg(public.discord_text(m.name), ', ' order by m.sort, m.name)
               filter (where not coalesce(t.excused, false) and not public.day_done(gd.boxes, t))
        into total, done, todo
      from public.members m
      left join public.ticks t on t.day = d and t.member_key = m.key
      where m.group_id = gd.group_id and m.active;
      if total > 0 then
        mins := greatest(1, ceil(extract(epoch from (closes - at_time)) / 60))::int;
        body := format(E'**%s** · %s\n%s/%s done · %s left\n%s',
          public.discord_text(gd.gname), to_char(d, 'Dy FMDD Mon'), done, total,
          case when mins >= 60 then (mins / 60) || 'h ' || lpad((mins % 60)::text, 2, '0') || 'm' else mins || ' min' end,
          case when todo is null then 'Everyone is done.' else 'Still to finish: ' || todo end);
        update public.group_discord x set last_daily = d where x.group_id = gd.group_id;
        group_id := gd.group_id; url := gd.webhook_url; kind := 'daily'; content := left(body, 1900);
        return next;
      end if;
    end if;

    -- weekly: right after the last trading day of a week closes
    lc := d - 1;
    while extract(isodow from lc) > 5 or exists (select 1 from public.holidays h where h.day = lc) loop
      lc := lc - 1;
    end loop;
    mon := lc - (extract(isodow from lc)::int - 1);
    if gd.weekly and mon <> d - (extract(isodow from d)::int - 1) and gd.last_weekly is distinct from mon
       and at_time < public.day_closes_at(gd.group_id, lc) + interval '1 day' then
      lines := null; n := 0;
      select string_agg(format('%s. %s · %s/%s days%s', rk, public.discord_text(nm), ok, possible,
                               case when wins + losses > 0 then format(' · %sW %sL', wins, losses) else '' end),
                        E'\n' order by rk)
        into lines
      from (
        select m.name as nm,
               count(*) filter (where public.day_done(gd.boxes, t)) as ok,
               count(*) filter (where not coalesce(t.excused, false)) as possible,
               count(*) filter (where 'win' = any(string_to_array(t.result, ','))) as wins,
               count(*) filter (where 'loss' = any(string_to_array(t.result, ','))) as losses,
               row_number() over (order by count(*) filter (where public.day_done(gd.boxes, t)) desc, m.sort, m.name) as rk
        from public.members m
        cross join generate_series(mon, lc, interval '1 day') as gs(dd)
        left join public.ticks t on t.day = gs.dd::date and t.member_key = m.key
        where m.group_id = gd.group_id and m.active
          and extract(isodow from gs.dd) <= 5 and not exists (select 1 from public.holidays h where h.day = gs.dd::date)
        group by m.key, m.name, m.sort
      ) s where rk <= 25;
      update public.group_discord x set last_weekly = mon where x.group_id = gd.group_id;
      if lines is not null then
        group_id := gd.group_id; url := gd.webhook_url; kind := 'weekly';
        content := left(format(E'**%s** · week of %s\n%s', public.discord_text(gd.gname), to_char(mon, 'FMDD Mon'), lines), 1900);
        return next;
      end if;
    end if;

    -- monthly: right after the last trading day of a month closes. Same counting as the weekly ranking.
    ms := date_trunc('month', lc)::date;
    if gd.monthly and ms <> date_trunc('month', d)::date and gd.last_monthly is distinct from ms
       and at_time < public.day_closes_at(gd.group_id, lc) + interval '1 day' then
      lines := null;
      select string_agg(format('%s. %s · %s/%s days%s', rk, public.discord_text(nm), ok, possible,
                               case when wins + losses > 0 then format(' · %sW %sL', wins, losses) else '' end),
                        E'\n' order by rk)
        into lines
      from (
        select m.name as nm,
               count(*) filter (where public.day_done(gd.boxes, t)) as ok,
               count(*) filter (where not coalesce(t.excused, false)) as possible,
               count(*) filter (where 'win' = any(string_to_array(t.result, ','))) as wins,
               count(*) filter (where 'loss' = any(string_to_array(t.result, ','))) as losses,
               row_number() over (order by count(*) filter (where public.day_done(gd.boxes, t)) desc, m.sort, m.name) as rk
        from public.members m
        cross join generate_series(ms, lc, interval '1 day') as gs(dd)
        left join public.ticks t on t.day = gs.dd::date and t.member_key = m.key
        where m.group_id = gd.group_id and m.active
          and extract(isodow from gs.dd) <= 5 and not exists (select 1 from public.holidays h where h.day = gs.dd::date)
        group by m.key, m.name, m.sort
      ) s where rk <= 25;
      update public.group_discord x set last_monthly = ms where x.group_id = gd.group_id;
      if lines is not null then
        group_id := gd.group_id; url := gd.webhook_url; kind := 'monthly';
        content := left(format(E'**%s** · %s\n%s', public.discord_text(gd.gname), to_char(ms, 'FMMonth YYYY'), lines), 1900);
        return next;
      end if;
    end if;
  end loop;

  -- mentor summaries: once the week (or month) has closed for every active group on the server.
  -- Groups can have different cutoffs and time zones, so this goes by the group that closes last:
  -- its last closed day and its open day are the earliest ones on the server.
  for sd in
    select x.*, s.name as sname
    from public.server_discord x join public.servers s on s.id = x.server_id
    for update of x skip locked
  loop
    select count(*), min(w.closed_day), min(w.open_day)
      into n, lc_first, nd
    from (
      select public.trading_day_at(g.id, at_time) as open_day, public.last_closed_day(g.id, at_time) as closed_day
      from public.server_groups sg join public.groups g on g.id = sg.group_id
      where sg.server_id = sd.server_id and g.status = 'active'
    ) w;
    continue when n = 0;
    -- the moment that day closed for the last group; a summary is never posted more than a day after it
    select max(public.day_closes_at(g.id, lc_first)) into all_closed
    from public.server_groups sg join public.groups g on g.id = sg.group_id
    where sg.server_id = sd.server_id and g.status = 'active';
    continue when at_time >= all_closed + interval '1 day';

    mon := lc_first - (extract(isodow from lc_first)::int - 1);
    if sd.weekly and mon <> nd - (extract(isodow from nd)::int - 1) and sd.last_weekly is distinct from mon then
      lines := public.server_summary_lines(sd.server_id, mon, lc_first);
      update public.server_discord x set last_weekly = mon where x.server_id = sd.server_id;
      if lines is not null then
        group_id := null; url := sd.webhook_url; kind := 'server-weekly';
        content := left(format(E'**%s** · week of %s\n%s', public.discord_plain(sd.sname), to_char(mon, 'FMDD Mon'), lines), 1900);
        return next;
      end if;
    end if;

    ms := date_trunc('month', lc_first)::date;
    if sd.monthly and ms <> date_trunc('month', nd)::date and sd.last_monthly is distinct from ms then
      lines := public.server_summary_lines(sd.server_id, ms, lc_first);
      update public.server_discord x set last_monthly = ms where x.server_id = sd.server_id;
      if lines is not null then
        group_id := null; url := sd.webhook_url; kind := 'server-monthly';
        content := left(format(E'**%s** · %s\n%s', public.discord_plain(sd.sname), to_char(ms, 'FMMonth YYYY'), lines), 1900);
        return next;
      end if;
    end if;
  end loop;
end;
$$;

-- Only the server can call it, as before.
revoke all on function public.due_recaps(timestamptz) from public, anon, authenticated;

select 'Update 29 done: a day can now have more than one result.' as result;
