-- Update 28: a group owner can pick a custom color for their group, as well as the named colors.
-- Run ONCE in Supabase > SQL Editor > New query > paste > Run (after update 27). Then push the website.
-- Safe to run again.
--
-- Who can do what (unchanged, enforced here in the database, not just in the website):
--   * Group owner (and the admins they picked) .. change their own group's color, like every other setting.
--   * Members, other groups, signed-out visitors . can't change it.
--
-- What changes: the color column used to accept only the named colors (blue, violet, green, ...). Now it also
-- accepts a color code: "#" and exactly six digits or letters a to f, in small letters, like #3a7bd5.
-- Anything else (words, longer text, web code) is still refused, so a color can never sneak code into the page.

do $$
declare c record;
begin
  -- Remove the old rule, whatever name the database gave it.
  for c in
    select con.conname from pg_constraint con
    where con.conrelid = 'public.groups'::regclass and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%color%'
  loop
    execute format('alter table public.groups drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.groups add constraint groups_color_check check (
  color in ('blue', 'violet', 'green', 'orange', 'red', 'teal', 'pink', 'gold')
  or color ~ '^#[0-9a-f]{6}$'
);
